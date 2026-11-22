--!strict
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local TeleportService = game:GetService("TeleportService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)
local Types = require(ReplicatedStorage.Shared.Types)
local BuildingConfig = require(ReplicatedStorage.Shared.configs.BuildingConfig)
local BuildingGeometry = require(ReplicatedStorage.Shared.BuildingGeometry)
local Net = require(ReplicatedStorage.Shared.Net)
local BuildingValidator = require(ServerScriptService.Server.Services.BuildingValidator)
local DataService = require(ServerScriptService.Server.Services.DataService)
local InventoryService = require(ServerScriptService.Server.Services.InventoryService)
local LootService = require(ServerScriptService.Server.Services.LootService)
local CraftingService = require(ServerScriptService.Server.Services.CraftingService)
local SecurityService = require(ServerScriptService.Server.Services.SecurityService)

type Slot = Types.Slot
type Inventory = Types.Inventory
type ItemBatchEntry = Types.ItemBatchEntry
type BuildPieceType = Types.BuildPieceType
type BuildTier = Types.BuildTier
type SavedBuildPiece = Types.SavedBuildPiece

export type LivePieceRecord = {
	Owner: Player,
	Piece: SavedBuildPiece,
	Model: Model,
	CFrame: CFrame,
	ContainerId: string?,
	LastDamagedAt: number,
}

export type DamageKind = "Explosion" | "Tool" | "Bullet"

local STRUCTURES_FOLDER_NAME = "PlayerBaseStructures"
local STUDIO_SIM_BANNER_DURATION = 4
local BUILD_ACTION_COOLDOWN = 0.15

local spawnedByPlayer: { [Player]: { [string]: LivePieceRecord } } = {}
local recordsByUid: { [string]: LivePieceRecord } = {}
local occupiedSockets: { [string]: { [string]: string } } = {}
local occupiedWorldKeys: { [string]: string } = {}
local lastBuildActionTime: { [Player]: number } = {}
local teleportInProgress: { [Player]: boolean } = {}
local pendingTeleports: { [Player]: boolean } = {}
local isInitialized = false

local BaseService = {}

local function getOrCreateStructuresFolder(): Folder
	local existing = Workspace:FindFirstChild(STRUCTURES_FOLDER_NAME)
	if existing and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = STRUCTURES_FOLDER_NAME
	folder.Parent = Workspace
	return folder
end

local function storageMapToInventory(storage: { [string]: Slot }?, maxSlots: number): Inventory
	local inv: Inventory = {}
	if type(storage) ~= "table" then
		return inv
	end
	for k, v in storage do
		local idx = tonumber(k)
		if
			idx
			and idx >= 1
			and idx <= maxSlots
			and idx % 1 == 0
			and type(v) == "table"
			and type(v.Id) == "string"
			and type(v.Count) == "number"
			and v.Count > 0
		then
			inv[idx] = { Id = v.Id, Count = math.floor(v.Count) }
		end
	end
	return inv
end

local function inventoryToStorageMap(slots: Inventory, maxSlots: number): { [string]: Slot }
	local map: { [string]: Slot } = {}
	for i = 1, maxSlots do
		local slot = slots[i]
		if slot ~= nil and slot.Count > 0 then
			map[tostring(i)] = { Id = slot.Id, Count = slot.Count }
		end
	end
	return map
end

local function cleanupPieceRuntime(record: LivePieceRecord)
	recordsByUid[record.Piece.Uid] = nil
	BuildingValidator.UnregisterSocketsForPiece(record.Piece.Uid, occupiedSockets, occupiedWorldKeys)
	if record.ContainerId ~= nil then
		LootService.UnregisterContainer(record.ContainerId)
	end
	if BuildingGeometry.CanonicalPieceType(record.Piece.PieceType) == "workbench_1" then
		CraftingService.UnregisterStation(record.Piece.Uid)
	end
	if record.Model.Parent then
		record.Model:Destroy()
	end
end

local function createPieceModel(owner: Player, piece: SavedBuildPiece): (Model, CFrame)
	local canonicalType = BuildingGeometry.CanonicalPieceType(piece.PieceType)
	piece.PieceType = canonicalType
	local worldCF = BuildingGeometry.GetPieceWorldCFrame(piece)
	local modelName = string.format("%s_%s", canonicalType, string.sub(piece.Uid, 1, 8))
	local model = BuildingGeometry.CreateModel(canonicalType, worldCF, false, modelName)
	BuildingGeometry.ApplyTierVisuals(model, canonicalType, piece.Tier)

	local maxHp = BuildingGeometry.ComputeMaxHp(canonicalType, piece.Tier)
	model:SetAttribute("BuildUid", piece.Uid)
	model:SetAttribute("PieceType", canonicalType)
	model:SetAttribute("Tier", piece.Tier)
	model:SetAttribute("OwnerUserId", owner.UserId)
	model:SetAttribute("PosX", piece.PosX)
	model:SetAttribute("PosY", piece.PosY)
	model:SetAttribute("PosZ", piece.PosZ)
	model:SetAttribute("RotY", piece.RotY)
	model:SetAttribute("Health", piece.Hp)
	model:SetAttribute("Hp", piece.Hp)
	model:SetAttribute("MaxHealth", maxHp)
	model:SetAttribute("MaxHp", maxHp)
	model:SetAttribute("LastDamagedAt", piece.LastDamagedAt or 0)
	model:SetAttribute("LastDamagedServerTime", 0)
	return model, worldCF
end

local function spawnPieceForPlayer(player: Player, piece: SavedBuildPiece)
	local playerRecords = spawnedByPlayer[player]
	if playerRecords == nil then
		playerRecords = {}
		spawnedByPlayer[player] = playerRecords
	end
	if playerRecords[piece.Uid] ~= nil then
		cleanupPieceRuntime(playerRecords[piece.Uid])
		playerRecords[piece.Uid] = nil
	end

	local model, worldCF = createPieceModel(player, piece)
	model.Parent = getOrCreateStructuresFolder()

	local containerId: string? = nil
	local canonicalType = BuildingGeometry.CanonicalPieceType(piece.PieceType)
	local pieceConfig = BuildingConfig.Pieces[canonicalType]
	if canonicalType == "storage_box" then
		local storageSlots = (if pieceConfig then pieceConfig.StorageSlots else nil) or 18
		piece.Storage = piece.Storage or {}
		local registeredId = LootService.RegisterStorageContainer(
			model,
			"Storage Box",
			player.UserId,
			storageSlots,
			storageMapToInventory(piece.Storage, storageSlots),
			function(updatedSlots: Inventory)
				piece.Storage = inventoryToStorageMap(updatedSlots, storageSlots)
			end
		)
		if #registeredId > 0 then
			containerId = registeredId
		end
	elseif canonicalType == "workbench_1" and model.PrimaryPart then
		CraftingService.RegisterStation(piece.Uid, "workbench_1", model.PrimaryPart.Position)
	end

	local record: LivePieceRecord = {
		Owner = player,
		Piece = piece,
		Model = model,
		CFrame = worldCF,
		ContainerId = containerId,
		LastDamagedAt = piece.LastDamagedAt or 0,
	}
	playerRecords[piece.Uid] = record
	recordsByUid[piece.Uid] = record
	BuildingValidator.RegisterOccupationsForRecord(
		(record :: any) :: BuildingValidator.LivePieceEntry,
		(playerRecords :: any) :: { [string]: BuildingValidator.LivePieceEntry },
		occupiedSockets,
		occupiedWorldKeys
	)
end

local function despawnBaseForPlayer(player: Player)
	local playerRecords = spawnedByPlayer[player]
	if playerRecords == nil then
		return
	end
	spawnedByPlayer[player] = nil
	for _, record in playerRecords do
		cleanupPieceRuntime(record)
	end
end

local function syncBaseState(player: Player)
	if player.Parent ~= Players then
		return
	end
	local data = DataService.GetData(player)
	if data ~= nil then
		Net.GetEvent(Net.Events.BaseStateSync):FireClient(player, data.Base.Pieces)
	end
end

local function spawnBaseForPlayer(player: Player, data: Types.PlayerData)
	despawnBaseForPlayer(player)
	for _, piece in data.Base.Pieces do
		spawnPieceForPlayer(player, piece)
	end
	syncBaseState(player)
end

local function costMapToBatch(costMap: { [string]: number }): { ItemBatchEntry }
	local entries: { ItemBatchEntry } = {}
	for itemId, count in costMap do
		if count > 0 then
			table.insert(entries, { Id = itemId, Count = count })
		end
	end
	return entries
end

local function onBuildPlaceRequest(
	player: Player,
	pieceTypeAny: any,
	targetCFrameAny: any,
	parentUidAny: any,
	socketIdAny: any,
	rotStepAny: any
)
	if not SecurityService.CheckRateLimit(player, Net.Events.BuildPlaceRequest) then
		return
	end
	if
		not BaseService.CanBuild(player)
		or DataService.IsTeleporting(player)
		or SecurityService.IsTransactionLocked(player)
	then
		return
	end
	if not SecurityService.IsValidString(pieceTypeAny, 1, 32) then
		return
	end
	local pieceType = BuildingGeometry.CanonicalPieceType(pieceTypeAny :: string)
	local pieceConfig = BuildingConfig.Pieces[pieceType]
	if pieceConfig == nil or not SecurityService.IsValidCFrame(targetCFrameAny, 2000) then
		return
	end
	local requestedCF = targetCFrameAny :: CFrame

	local parentUid: string? = nil
	local socketId: string? = nil
	if parentUidAny ~= nil or socketIdAny ~= nil then
		if
			not SecurityService.IsValidString(parentUidAny, 1, 64)
			or not SecurityService.IsValidString(socketIdAny, 1, 32)
		then
			return
		end
		parentUid = parentUidAny :: string
		socketId = socketIdAny :: string
	end

	local explicitRotStep: number? = nil
	if rotStepAny ~= nil then
		if not SecurityService.IsValidInteger(rotStepAny, 0, 32) then
			return
		end
		explicitRotStep = rotStepAny :: number
	end

	local _, hrp = SecurityService.GetAliveCharacterRoot(player)
	if not hrp then
		return
	end

	SecurityService.RunLocked(player, "BuildPlace", function()
		if not BaseService.CanBuild(player) then
			return
		end
		local character, innerHrp = SecurityService.GetAliveCharacterRoot(player)
		if not innerHrp then
			return
		end

		local now = os.clock()
		local prevAction = lastBuildActionTime[player]
		if prevAction ~= nil and (now - prevAction) < BUILD_ACTION_COOLDOWN then
			return
		end

		local data = DataService.GetData(player)
		if data == nil or #data.Base.Pieces >= BuildingConfig.MaxPiecesPerBase then
			return
		end

		local playerRecords = spawnedByPlayer[player]
		if playerRecords == nil then
			playerRecords = {}
			spawnedByPlayer[player] = playerRecords
		end

		local validation = BuildingValidator.ValidatePlacement({
			Player = player,
			Character = character,
			HrpPosition = innerHrp.Position,
			PieceType = pieceType,
			RequestedCFrame = requestedCF,
			ParentUid = parentUid,
			SocketId = socketId,
			ExplicitRotStep = explicitRotStep,
			PlayerRecords = (playerRecords :: any) :: { [string]: BuildingValidator.LivePieceEntry },
			AllRecordsByUid = (recordsByUid :: any) :: { [string]: BuildingValidator.LivePieceEntry },
			OccupiedSockets = occupiedSockets,
			OccupiedWorldKeys = occupiedWorldKeys,
			BasePieces = data.Base.Pieces,
		})

		if not validation.Allowed or validation.AuthoritativeCFrame == nil then
			return
		end

		if not InventoryService.RemoveItems(player, costMapToBatch(pieceConfig.Cost)) then
			return
		end

		lastBuildActionTime[player] = now
		local pos = validation.AuthoritativeCFrame.Position
		local rotY = validation.RotY
			or BuildingGeometry.QuantizeYaw30(BuildingGeometry.ExtractYawDegrees(validation.AuthoritativeCFrame))

		local newPiece: SavedBuildPiece = {
			Uid = HttpService:GenerateGUID(false),
			PieceType = pieceType,
			Tier = "wood",
			PosX = pos.X,
			PosY = pos.Y,
			PosZ = pos.Z,
			RotY = rotY,
			ParentUid = validation.ResolvedParentUid,
			AnchorUid = validation.ResolvedParentUid,
			SocketId = validation.ResolvedSocketId,
			Hp = pieceConfig.BaseHp,
			LastDamagedAt = 0,
			Storage = if pieceConfig.StorageSlots ~= nil then {} else nil,
		}

		table.insert(data.Base.Pieces, newPiece)
		spawnPieceForPlayer(player, newPiece)
		syncBaseState(player)
	end)
end

local function onBuildUpgradeRequest(player: Player, uidAny: any, targetTierAny: any)
	if not SecurityService.CheckRateLimit(player, Net.Events.BuildUpgradeRequest) then
		return
	end
	if
		not BaseService.CanBuild(player)
		or DataService.IsTeleporting(player)
		or SecurityService.IsTransactionLocked(player)
	then
		return
	end
	if not SecurityService.IsValidString(uidAny, 1, 64) or not SecurityService.IsValidString(targetTierAny, 1, 32) then
		return
	end
	local targetTier = targetTierAny :: BuildTier
	local targetTierConfig = BuildingConfig.Tiers[targetTier]
	if targetTierConfig == nil then
		return
	end
	local uid = uidAny :: string
	if SecurityService.GetAliveCharacterRoot(player) == nil then
		return
	end

	SecurityService.RunLocked(player, "BuildUpgrade", function()
		if not BaseService.CanBuild(player) then
			return
		end
		local _, innerHrp = SecurityService.GetAliveCharacterRoot(player)
		if not innerHrp then
			return
		end

		local now = os.clock()
		local prevAction = lastBuildActionTime[player]
		if prevAction ~= nil and (now - prevAction) < BUILD_ACTION_COOLDOWN then
			return
		end

		local data = DataService.GetData(player)
		local record = recordsByUid[uid]
		if data == nil or record == nil or record.Owner ~= player or not record.Model.Parent then
			return
		end

		if
			(innerHrp.Position - record.CFrame.Position).Magnitude
			> BuildingConfig.MaxBuildDistance + Types.PING_DISTANCE_TOLERANCE
		then
			return
		end

		local targetPiece = record.Piece
		local pieceConfig = BuildingConfig.Pieces[targetPiece.PieceType]
		local currentTierConfig = BuildingConfig.Tiers[targetPiece.Tier]
		if pieceConfig == nil or not pieceConfig.Upgradeable or currentTierConfig == nil then
			return
		end

		if
			targetTierConfig.Rank <= currentTierConfig.Rank
			or BuildingConfig.GetNextTier(targetPiece.Tier) ~= targetTier
		then
			return
		end

		local attrDamaged = record.Model:GetAttribute("LastDamagedAt")
		local lastDamagedAt = math.max(
			targetPiece.LastDamagedAt or 0,
			record.LastDamagedAt or 0,
			if typeof(attrDamaged) == "number" then attrDamaged else 0
		)
		if lastDamagedAt > 0 and (now - lastDamagedAt) < BuildingConfig.UpgradeRaidBlockSeconds then
			return
		end

		if
			targetTierConfig.UpgradeCost == nil
			or not InventoryService.RemoveItems(player, costMapToBatch(targetTierConfig.UpgradeCost))
		then
			return
		end

		lastBuildActionTime[player] = now
		local maxHp = BuildingGeometry.ComputeMaxHp(targetPiece.PieceType, targetTier)
		targetPiece.Tier = targetTier
		targetPiece.Hp = maxHp

		BuildingGeometry.ApplyTierVisuals(record.Model, targetPiece.PieceType, targetTier)
		record.Model:SetAttribute("Tier", targetTier)
		record.Model:SetAttribute("Health", maxHp)
		record.Model:SetAttribute("Hp", maxHp)
		record.Model:SetAttribute("MaxHealth", maxHp)
		record.Model:SetAttribute("MaxHp", maxHp)

		syncBaseState(player)
	end)
end

local function onBuildDemolishRequest(player: Player, uidAny: any)
	if not SecurityService.CheckRateLimit(player, Net.Events.BuildDemolishRequest) then
		return
	end
	if
		not BaseService.CanBuild(player)
		or DataService.IsTeleporting(player)
		or SecurityService.IsTransactionLocked(player)
	then
		return
	end
	if not SecurityService.IsValidString(uidAny, 1, 64) or SecurityService.GetAliveCharacterRoot(player) == nil then
		return
	end
	local uid = uidAny :: string

	SecurityService.RunLocked(player, "BuildDemolish", function()
		if not BaseService.CanBuild(player) then
			return
		end
		local _, innerHrp = SecurityService.GetAliveCharacterRoot(player)
		if not innerHrp then
			return
		end

		local now = os.clock()
		local prevAction = lastBuildActionTime[player]
		if prevAction ~= nil and (now - prevAction) < BUILD_ACTION_COOLDOWN then
			return
		end

		local data = DataService.GetData(player)
		local record = recordsByUid[uid]
		if data == nil or record == nil or record.Owner ~= player then
			return
		end
		if
			(innerHrp.Position - record.CFrame.Position).Magnitude
			> BuildingConfig.MaxBuildDistance + Types.PING_DISTANCE_TOLERANCE
		then
			return
		end

		local targetIndex: number? = nil
		for index, piece in data.Base.Pieces do
			if piece.Uid == uid then
				targetIndex = index
				break
			end
		end
		if targetIndex == nil then
			return
		end

		lastBuildActionTime[player] = now
		local playerRecords = spawnedByPlayer[player]
		if playerRecords ~= nil then
			playerRecords[uid] = nil
		end
		cleanupPieceRuntime(record)
		table.remove(data.Base.Pieces, targetIndex)
		syncBaseState(player)
	end)
end

local function sendReturnBanner(player: Player, active: boolean, statusText: string?)
	if player.Parent == Players then
		Net.GetEvent(Net.Events.ExtractionStateSync):FireClient(player, {
			Active = active,
			ZoneName = "Base Portal",
			TimeLeft = 0,
			TotalTime = 1,
			StatusText = statusText,
		})
	end
end

local function onRequestReturnToMap(player: Player)
	if not SecurityService.CheckRateLimit(player, Net.Events.RequestReturnToMap) or not BaseService.IsBaseMode() then
		return
	end
	if teleportInProgress[player] or SecurityService.IsTeleportLocked(player) or DataService.GetData(player) == nil then
		return
	end
	if SecurityService.GetAliveCharacterRoot(player) == nil then
		return
	end

	teleportInProgress[player] = true
	SecurityService.SetTeleportLock(player, true)
	LootService.CloseContainerForPlayer(player, true)

	if RunService:IsStudio() then
		DataService.ReleaseForTeleport(player)
		sendReturnBanner(player, true, "Returning to PvP Map (Studio Simulation)")
		task.delay(STUDIO_SIM_BANNER_DURATION, function()
			if player.Parent == Players and pendingTeleports[player] == nil then
				sendReturnBanner(player, false, nil)
			end
		end)
		return
	end

	task.spawn(function()
		sendReturnBanner(player, true, "Saving base & deploying to PvP Map...")
		if not DataService.ReleaseForTeleport(player) then
			DataService.RestoreAfterFailedTeleport(player)
			teleportInProgress[player] = nil
			sendReturnBanner(player, false, nil)
			return
		end
		if player.Parent ~= Players then
			teleportInProgress[player] = nil
			SecurityService.SetTeleportLock(player, false)
			return
		end

		local options = Instance.new("TeleportOptions")
		options:SetTeleportData({ FromPlaceId = game.PlaceId, OwnerUserId = player.UserId, Mode = "Raid" })
		pendingTeleports[player] = true
		local ok = pcall(function()
			TeleportService:TeleportAsync(Config.Places.MainMap, { player }, options)
		end)
		if not ok then
			pendingTeleports[player] = nil
			teleportInProgress[player] = nil
			DataService.RestoreAfterFailedTeleport(player)
			sendReturnBanner(player, false, nil)
		end
	end)
end

local function onTeleportInitFailed(player: Player)
	if pendingTeleports[player] then
		pendingTeleports[player] = nil
		teleportInProgress[player] = nil
		DataService.RestoreAfterFailedTeleport(player)
		sendReturnBanner(player, false, nil)
	end
end

function BaseService.IsBaseMode(): boolean
	if Workspace:GetAttribute("RaidServerMode") == true then
		return false
	end
	if game.PlaceId == Config.Places.PlayerBase and game.PrivateServerId ~= "" and game.PrivateServerOwnerId == 0 then
		return false
	end
	return game.PlaceId == Config.Places.PlayerBase
		or (RunService:IsStudio() and Workspace:GetAttribute("ForceBaseMode") == true)
end

function BaseService.CanBuild(player: Player): boolean
	if player.Parent ~= Players then
		return false
	end
	if Workspace:GetAttribute("RaidServerMode") == true or player:GetAttribute("InRaid") == true then
		return false
	end
	return not DataService.IsTeleporting(player) and not SecurityService.IsTeleportLocked(player)
end

function BaseService.DamagePiece(
	uid: string,
	rawDamage: number,
	damageKind: DamageKind,
	_attacker: Player?
): (boolean, boolean)
	if not SecurityService.IsFiniteNumber(rawDamage) or rawDamage <= 0 then
		return false, false
	end
	local record = recordsByUid[uid]
	if record == nil or record.Model.Parent == nil then
		return false, false
	end

	local tierCfg = BuildingConfig.Tiers[record.Piece.Tier] or BuildingConfig.Tiers.wood
	local mult = if damageKind == "Explosion"
		then math.max(0.05, 1.0 - tierCfg.ExplosionResistance)
		else tierCfg.ToolDamageMultiplier
	local finalDamage = math.max(1, math.floor(rawDamage * mult + 0.5))

	local nowClock = os.clock()
	record.LastDamagedAt = nowClock
	record.Piece.LastDamagedAt = nowClock
	record.Model:SetAttribute("LastDamagedAt", nowClock)
	record.Model:SetAttribute("LastDamagedServerTime", Workspace:GetServerTimeNow())

	record.Piece.Hp -= finalDamage
	if record.Piece.Hp <= 0 then
		local owner = record.Owner
		local data = DataService.GetData(owner)
		local playerRecords = spawnedByPlayer[owner]
		if playerRecords ~= nil then
			playerRecords[uid] = nil
		end
		cleanupPieceRuntime(record)
		if data ~= nil then
			for index, piece in data.Base.Pieces do
				if piece.Uid == uid then
					table.remove(data.Base.Pieces, index)
					break
				end
			end
			syncBaseState(owner)
		end
		return true, true
	end

	record.Model:SetAttribute("Health", record.Piece.Hp)
	record.Model:SetAttribute("Hp", record.Piece.Hp)
	syncBaseState(record.Owner)
	return true, false
end

function BaseService.GetLivePieceModelsInRadius(origin: Vector3, radius: number): { { Uid: string, Model: Model } }
	local result: { { Uid: string, Model: Model } } = {}
	for uid, record in recordsByUid do
		if
			record.Model.Parent ~= nil
			and (record.CFrame.Position - origin).Magnitude <= radius + BuildingConfig.GridSize
		then
			table.insert(result, { Uid = uid, Model = record.Model })
		end
	end
	return result
end

function BaseService.GetPlayerPieces(player: Player): { SavedBuildPiece }
	local data = DataService.GetData(player)
	return if data ~= nil then table.clone(data.Base.Pieces) else {}
end

function BaseService.GetStorageContainerId(player: Player, uid: string): string?
	local playerRecords = spawnedByPlayer[player]
	local record = if playerRecords ~= nil then playerRecords[uid] else nil
	return if record ~= nil then record.ContainerId else nil
end

function BaseService.Init()
	if isInitialized then
		return
	end
	isInitialized = true

	Net.InitServer()
	getOrCreateStructuresFolder()

	Net.GetEvent(Net.Events.BuildPlaceRequest).OnServerEvent:Connect(onBuildPlaceRequest)
	Net.GetEvent(Net.Events.BuildUpgradeRequest).OnServerEvent:Connect(onBuildUpgradeRequest)
	Net.GetEvent(Net.Events.BuildDemolishRequest).OnServerEvent:Connect(onBuildDemolishRequest)
	Net.GetEvent(Net.Events.RequestReturnToMap).OnServerEvent:Connect(onRequestReturnToMap)
	TeleportService.TeleportInitFailed:Connect(onTeleportInitFailed)

	DataService.OnDataLoaded(function(player: Player, data: Types.PlayerData)
		local isRaidJoin = false
		local ok, joinData = pcall(function()
			return player:GetJoinData()
		end)
		if
			ok
			and type(joinData) == "table"
			and type(joinData.TeleportData) == "table"
			and joinData.TeleportData.Mode == "Raid"
		then
			isRaidJoin = true
		end
		local canSpawn = not isRaidJoin
			and Workspace:GetAttribute("RaidServerMode") ~= true
			and player:GetAttribute("InRaid") ~= true
			and (BaseService.IsBaseMode() or RunService:IsStudio())
		if canSpawn then
			spawnBaseForPlayer(player, data)
		end
	end)

	if RunService:IsStudio() then
		Workspace:GetAttributeChangedSignal("ForceBaseMode"):Connect(function()
			if BaseService.IsBaseMode() or RunService:IsStudio() then
				getOrCreateStructuresFolder()
				for _, player in Players:GetPlayers() do
					local data = DataService.GetData(player)
					if data ~= nil and spawnedByPlayer[player] == nil then
						spawnBaseForPlayer(player, data)
					end
				end
			else
				for _, player in Players:GetPlayers() do
					despawnBaseForPlayer(player)
				end
			end
		end)
	end

	Players.PlayerRemoving:Connect(function(player: Player)
		despawnBaseForPlayer(player)
		lastBuildActionTime[player] = nil
		teleportInProgress[player] = nil
		pendingTeleports[player] = nil
	end)
end

return BaseService
