--!strict
local HttpService = game:GetService("HttpService")
local MemoryStoreService = game:GetService("MemoryStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RobloxTeleportService = game:GetService("TeleportService")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local Net = require(ReplicatedStorage.Shared.Net)
local Types = require(ReplicatedStorage.Shared.Types)
local DataService = require(ServerScriptService.Server.Services.DataService)
local LootService = require(ServerScriptService.Server.Services.LootService)
local SecurityService = require(ServerScriptService.Server.Services.SecurityService)

type TransferPayload = Types.TransferPayload
type TransferReceipt = Types.TransferReceipt
type TransferReason = Types.TransferReason

export type TransferRequestOptions = {
	TargetPlaceId: number,
	Reason: TransferReason,
	MapKey: string?,
	TargetBaseUserId: number?,
	ReservedServerAccessCode: string?,
	RaidMetadata: { [string]: any }?,
	TeleportData: { [string]: any }?,
	ZoneName: string?,
	TotalTime: number?,
	OnStatus: ((statusText: string) -> ())?,
	OnFailure: ((reason: string) -> ())?,
}

type PendingTransfer = {
	Nonce: string,
	Payload: TransferPayload,
	Options: TransferRequestOptions,
	TeleportOptions: TeleportOptions,
}

local TRANSFER_HASHMAP_NAME = "CrossPlaceTransfers"
local TRANSFER_TTL_SECONDS = 120
local CLAIMED_TOMBSTONE_TTL = 15
local SESSION_LOCK_RETRY_DELAYS: { number } = { 0.5, 1, 2, 4 }
local STUDIO_SIM_DELAY = 4

local transferHashMap: MemoryStoreHashMap? = nil
local studioFallbackMap: { [string]: TransferPayload } = {}
local pendingTransfers: { [Player]: PendingTransfer } = {}
local arrivingPlayers: { [Player]: boolean } = {}
local arrivedPayloads: { [Player]: TransferPayload } = {}
local lastReceipts: { [Player]: TransferReceipt } = {}
local isInitialized = false

local TeleportService = {}

local function getTransferHashMap(): MemoryStoreHashMap?
	if transferHashMap ~= nil then
		return transferHashMap
	end
	local ok, mapOrErr = pcall(function()
		return MemoryStoreService:GetHashMap(TRANSFER_HASHMAP_NAME)
	end)
	if ok and mapOrErr ~= nil then
		transferHashMap = mapOrErr
		return mapOrErr
	end
	return nil
end

local function clonePayload(src: TransferPayload): TransferPayload
	local copy: TransferPayload = {
		TransferId = src.TransferId,
		UserId = src.UserId,
		Reason = src.Reason,
		SourcePlaceId = src.SourcePlaceId,
		TargetPlaceId = src.TargetPlaceId,
		IssuedAt = src.IssuedAt,
		InventoryHash = src.InventoryHash,
		TargetBaseUserId = src.TargetBaseUserId,
		MapKey = src.MapKey,
		LootItems = src.LootItems,
		RaidMetadata = src.RaidMetadata,
		Consumed = src.Consumed,
		ConsumedAt = src.ConsumedAt,
		ConsumedByJobId = src.ConsumedByJobId,
	}
	return copy
end

local function writeTransferPayload(nonce: string, payload: TransferPayload): (boolean, string?)
	local hashMap = getTransferHashMap()
	if hashMap ~= nil then
		local ok, err = pcall(function()
			hashMap:SetAsync(nonce, payload, TRANSFER_TTL_SECONDS)
		end)
		if ok then
			return true, nil
		end
		if RunService:IsStudio() then
			studioFallbackMap[nonce] = clonePayload(payload)
			return true, nil
		end
		return false, tostring(err)
	end
	if RunService:IsStudio() then
		studioFallbackMap[nonce] = clonePayload(payload)
		return true, nil
	end
	return false, "CrossPlaceTransfers MemoryStoreHashMap unavailable"
end

local function removeTransferNonce(nonce: string)
	studioFallbackMap[nonce] = nil
	local hashMap = getTransferHashMap()
	if hashMap ~= nil then
		pcall(function()
			hashMap:RemoveAsync(nonce)
		end)
	end
end

local function claimAndDeleteTransferPayload(nonce: string): (TransferPayload?, string?)
	local hashMap = getTransferHashMap()
	if hashMap ~= nil then
		local ok, updatedOrErr = pcall(function()
			return hashMap:UpdateAsync(nonce, function(existing: any): any
				if type(existing) ~= "table" or existing.Consumed == true then
					return nil
				end
				local claimed = clonePayload(existing :: TransferPayload)
				claimed.Consumed = true
				claimed.ConsumedAt = os.time()
				claimed.ConsumedByJobId = game.JobId
				return claimed
			end, CLAIMED_TOMBSTONE_TTL)
		end)
		if ok then
			if type(updatedOrErr) == "table" and (updatedOrErr :: TransferPayload).Consumed == true then
				pcall(function()
					hashMap:RemoveAsync(nonce)
				end)
				return updatedOrErr :: TransferPayload, nil
			end
			return nil, "TransferNonce missing or already consumed"
		elseif not RunService:IsStudio() then
			return nil, string.format("MemoryStore UpdateAsync failed: %s", tostring(updatedOrErr))
		end
	end

	if RunService:IsStudio() then
		local fallback = studioFallbackMap[nonce]
		studioFallbackMap[nonce] = nil
		if fallback ~= nil and fallback.Consumed ~= true then
			fallback.Consumed = true
			fallback.ConsumedAt = os.time()
			fallback.ConsumedByJobId = game.JobId
			return fallback, nil
		end
		return nil, "TransferNonce missing in Studio fallback"
	end

	return nil, "MemoryStore unavailable"
end

local function notifyClientStatus(player: Player, options: TransferRequestOptions, active: boolean, statusText: string?)
	if player.Parent ~= Players then
		return
	end
	if active then
		if options.OnStatus ~= nil and statusText ~= nil then
			options.OnStatus(statusText)
			return
		end
	else
		if options.OnFailure ~= nil and statusText ~= nil then
			options.OnFailure(statusText)
			return
		end
	end
	if options.ZoneName ~= nil then
		Net.GetEvent(Net.Events.ExtractionStateSync):FireClient(player, {
			Active = active,
			ZoneName = options.ZoneName,
			TimeLeft = if active then 0 else (options.TotalTime or 0),
			TotalTime = options.TotalTime or 0,
			StatusText = statusText,
		})
	end
end

local function makeReceipt(
	transferId: string,
	userId: number,
	success: boolean,
	profileReleased: boolean,
	errMsg: string?
): TransferReceipt
	return {
		TransferId = transferId,
		UserId = userId,
		Success = success,
		ProfileReleased = profileReleased,
		ProcessedAt = os.time(),
		ErrorMessage = errMsg,
	}
end

local function rollbackFailedTransfer(player: Player, reasonText: string)
	local pending = pendingTransfers[player]
	if pending == nil then
		return
	end
	pendingTransfers[player] = nil

	removeTransferNonce(pending.Nonce)
	local restored = DataService.RestoreAfterFailedTeleport(player)
	if not restored then
		DataService.SetTransferLock(player, false)
	end

	lastReceipts[player] = makeReceipt(pending.Nonce, player.UserId, false, false, reasonText)
	notifyClientStatus(player, pending.Options, false, reasonText)
end

local function buildTeleportOptions(nonce: string, options: TransferRequestOptions): TeleportOptions
	local tpOptions = Instance.new("TeleportOptions")
	if options.ReservedServerAccessCode ~= nil and #options.ReservedServerAccessCode > 0 then
		tpOptions.ReservedServerAccessCode = options.ReservedServerAccessCode
	end

	local tpData: { [string]: any } = {}
	if type(options.TeleportData) == "table" then
		for k, v in options.TeleportData do
			tpData[k] = v
		end
	end
	tpData.TransferNonce = nonce
	tpData.FromPlaceId = game.PlaceId
	tpData.TargetPlaceId = options.TargetPlaceId
	tpData.Reason = options.Reason
	if options.MapKey ~= nil then
		tpData.TargetMapKey = options.MapKey
	end
	if options.TargetBaseUserId ~= nil then
		tpData.TargetBaseUserId = options.TargetBaseUserId
	end
	tpOptions:SetTeleportData(tpData)
	return tpOptions
end

function TeleportService.TransferPlayer(player: Player, options: TransferRequestOptions): TransferReceipt
	local userId = player.UserId
	if player.Parent ~= Players then
		return makeReceipt("", userId, false, false, "Player left server")
	end
	if
		pendingTransfers[player] ~= nil
		or DataService.IsTransferLocked(player)
		or SecurityService.IsTeleportLocked(player)
	then
		return makeReceipt("", userId, false, false, "Transfer already in progress")
	end
	if DataService.GetData(player) == nil then
		return makeReceipt("", userId, false, false, "Player profile not loaded")
	end

	-- Phase 1 (Lock): immediately lock inventory/craft/trade/container/loot mutations
	DataService.SetTransferLock(player, true)
	LootService.CloseContainerForPlayer(player, true)
	notifyClientStatus(player, options, true, "Saving data & preparing transfer...")

	-- Phase 2 (Commit & Nonce): flush unload hooks, compute deterministic inventory hash, write MemoryStore nonce, release ProfileStore lock
	DataService.FlushBeforeUnload(player)
	local inventoryHash = DataService.GetPlayerInventoryHash(player)
	if inventoryHash == nil then
		DataService.ResetUnloadFlag(player)
		DataService.SetTransferLock(player, false)
		local receipt = makeReceipt("", userId, false, false, "Failed to snapshot inventory hash")
		lastReceipts[player] = receipt
		notifyClientStatus(player, options, false, "Transfer failed: profile snapshot error")
		return receipt
	end

	local nonce = HttpService:GenerateGUID(false)
	local payload: TransferPayload = {
		TransferId = nonce,
		UserId = userId,
		Reason = options.Reason,
		SourcePlaceId = game.PlaceId,
		TargetPlaceId = options.TargetPlaceId,
		IssuedAt = os.time(),
		InventoryHash = inventoryHash,
		TargetBaseUserId = options.TargetBaseUserId,
		MapKey = options.MapKey,
		RaidMetadata = options.RaidMetadata,
	}

	local wroteOk, writeErr = writeTransferPayload(nonce, payload)
	if not wroteOk then
		warn(
			string.format(
				"[TeleportService] Failed to commit TransferNonce for %s (%d): %s",
				player.Name,
				userId,
				tostring(writeErr)
			)
		)
		DataService.ResetUnloadFlag(player)
		DataService.SetTransferLock(player, false)
		local receipt = makeReceipt(nonce, userId, false, false, writeErr)
		lastReceipts[player] = receipt
		notifyClientStatus(player, options, false, "Transfer failed: session commit error")
		return receipt
	end

	local released = DataService.ReleaseForTeleport(player)
	if not released then
		warn(string.format("[TeleportService] Failed to release ProfileStore lock for %s (%d)", player.Name, userId))
		removeTransferNonce(nonce)
		DataService.RestoreAfterFailedTeleport(player)
		local receipt = makeReceipt(nonce, userId, false, false, "Profile release timeout")
		lastReceipts[player] = receipt
		notifyClientStatus(player, options, false, "Transfer failed: save timeout")
		return receipt
	end

	if player.Parent ~= Players then
		removeTransferNonce(nonce)
		DataService.SetTransferLock(player, false)
		return makeReceipt(nonce, userId, false, true, "Player disconnected before TeleportAsync")
	end

	-- Phase 3 (Teleport & Rollback)
	if RunService:IsStudio() then
		notifyClientStatus(player, options, true, "Transfer committed (Studio Simulation)")
		local receipt = makeReceipt(nonce, userId, true, true, nil)
		lastReceipts[player] = receipt
		task.delay(STUDIO_SIM_DELAY, function()
			removeTransferNonce(nonce)
			if player.Parent == Players and pendingTransfers[player] == nil then
				DataService.RestoreAfterFailedTeleport(player)
				notifyClientStatus(player, options, false, "")
			end
		end)
		return receipt
	end

	local tpOptions = buildTeleportOptions(nonce, options)
	pendingTransfers[player] = {
		Nonce = nonce,
		Payload = payload,
		Options = options,
		TeleportOptions = tpOptions,
	}

	local ok, err = pcall(function()
		RobloxTeleportService:TeleportAsync(options.TargetPlaceId, { player }, tpOptions)
	end)
	if not ok then
		warn(string.format("[TeleportService] TeleportAsync error for %s (%d): %s", player.Name, userId, tostring(err)))
		rollbackFailedTransfer(player, string.format("Teleport failed: %s", tostring(err)))
		return lastReceipts[player] or makeReceipt(nonce, userId, false, false, tostring(err))
	end

	local receipt = makeReceipt(nonce, userId, true, true, nil)
	lastReceipts[player] = receipt
	return receipt
end

local function onTeleportInitFailed(
	player: Player,
	teleportResult: Enum.TeleportResult,
	errorMessage: string,
	_placeId: number,
	_teleportOptions: TeleportOptions
)
	if pendingTransfers[player] == nil then
		return
	end
	warn(
		string.format(
			"[TeleportService] TeleportInitFailed for %s (%d) [%s]: %s",
			player.Name,
			player.UserId,
			tostring(teleportResult),
			errorMessage
		)
	)
	rollbackFailedTransfer(player, string.format("Teleport failed: %s", errorMessage))
end

function TeleportService.OnPlayerArrived(player: Player)
	if arrivingPlayers[player] or player.Parent ~= Players then
		return
	end
	arrivingPlayers[player] = true

	local joinOk, joinData = pcall(function()
		return player:GetJoinData()
	end)
	local teleportData: { [string]: any }? = if joinOk
			and type(joinData) == "table"
			and type(joinData.TeleportData) == "table"
		then joinData.TeleportData
		else nil
	local sourcePlaceId: number = if joinOk
			and type(joinData) == "table"
			and type(joinData.SourcePlaceId) == "number"
		then joinData.SourcePlaceId
		else 0
	local rawNonce = if teleportData ~= nil then teleportData.TransferNonce else nil

	-- Safe first login on PlayerBase (or Studio direct test) without TransferNonce
	if rawNonce == nil then
		if sourcePlaceId == 0 or RunService:IsStudio() then
			player:SetAttribute("TransferValidated", true)
			DataService.LoadProfileForPlayer(player, {
				WaitForSessionRelease = false,
				RetryDelays = SESSION_LOCK_RETRY_DELAYS,
			})
			arrivingPlayers[player] = nil
			return
		end

		warn(
			string.format(
				"[TeleportService] Anti-dupe kick: %s (%d) arrived from place %d without TransferNonce",
				player.Name,
				player.UserId,
				sourcePlaceId
			)
		)
		arrivingPlayers[player] = nil
		player:Kick("Missing transfer verification token. Please rejoin.")
		return
	end

	if not Types.IsValidString(rawNonce, 1, 64) then
		warn(
			string.format(
				"[TeleportService] Anti-dupe kick: malformed TransferNonce for %s (%d)",
				player.Name,
				player.UserId
			)
		)
		arrivingPlayers[player] = nil
		player:Kick("Invalid transfer verification token.")
		return
	end

	local nonce = rawNonce :: string
	local claimedPayload, claimErr = claimAndDeleteTransferPayload(nonce)
	if claimedPayload == nil or not Types.IsValidTransferPayload(claimedPayload) then
		warn(
			string.format(
				"[TeleportService] Anti-dupe rejection for %s (%d), nonce=%s: %s",
				player.Name,
				player.UserId,
				nonce,
				tostring(claimErr)
			)
		)
		arrivingPlayers[player] = nil
		player:Kick("Transfer token invalid or already used.")
		return
	end

	if claimedPayload.UserId ~= player.UserId then
		warn(
			string.format(
				"[TeleportService] Anti-dupe user mismatch for %s (%d): payload belongs to %d",
				player.Name,
				player.UserId,
				claimedPayload.UserId
			)
		)
		arrivingPlayers[player] = nil
		player:Kick("Transfer token does not match account.")
		return
	end

	if not RunService:IsStudio() and claimedPayload.TargetPlaceId ~= game.PlaceId then
		warn(
			string.format(
				"[TeleportService] Anti-dupe target place mismatch for %s (%d): expected %d, got %d",
				player.Name,
				player.UserId,
				claimedPayload.TargetPlaceId,
				game.PlaceId
			)
		)
		arrivingPlayers[player] = nil
		player:Kick("Transfer target place mismatch.")
		return
	end

	arrivedPayloads[player] = claimedPayload
	player:SetAttribute("TransferValidated", true)

	DataService.LoadProfileForPlayer(player, {
		ExpectedInventoryHash = claimedPayload.InventoryHash,
		WaitForSessionRelease = true,
		RetryDelays = SESSION_LOCK_RETRY_DELAYS,
	})
	arrivingPlayers[player] = nil
end

function TeleportService.GetArrivedPayload(player: Player): TransferPayload?
	return arrivedPayloads[player]
end

function TeleportService.GetLastReceipt(player: Player): TransferReceipt?
	return lastReceipts[player]
end

function TeleportService.Init()
	if isInitialized then
		return
	end
	isInitialized = true

	Net.InitServer()
	DataService.SetArrivalHandler(TeleportService.OnPlayerArrived)
	RobloxTeleportService.TeleportInitFailed:Connect(onTeleportInitFailed)

	Players.PlayerRemoving:Connect(function(player: Player)
		pendingTransfers[player] = nil
		arrivingPlayers[player] = nil
		arrivedPayloads[player] = nil
		lastReceipts[player] = nil
	end)
end

return TeleportService
