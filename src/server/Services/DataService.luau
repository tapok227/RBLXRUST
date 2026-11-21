--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Types = require(ReplicatedStorage.Shared.Types)
local Signal = require(ReplicatedStorage.Shared.Signal)
local ProfileStore = require(ServerScriptService.Server.Vendor.ProfileStore)

type PlayerData = Types.PlayerData
type Slot = Types.Slot

local PROFILE_STORE_NAME = "PlayerData_v1"

local DATA_TEMPLATE = {
	Version = 1,
	Inventory = {},
}

local PlayerStore = ProfileStore.New(PROFILE_STORE_NAME, DATA_TEMPLATE)

local Profiles: { [Player]: any } = {}
local RuntimeData: { [Player]: PlayerData } = {}
local unloadedByPlayer: { [Player]: boolean } = {}
local beforeUnloadCallbacks: { (player: Player, data: PlayerData) -> () } = {}
local dataLoadedSignal: Signal.Signal<Player, PlayerData> = Signal.new()
local isInitialized = false

local DataService = {
	DataLoaded = dataLoadedSignal,
}

local function runBeforeUnload(player: Player, data: PlayerData)
	if unloadedByPlayer[player] then
		return
	end
	unloadedByPlayer[player] = true
	for _, callback in beforeUnloadCallbacks do
		local ok, err = pcall(callback, player, data)
		if not ok then
			warn(string.format("[DataService] OnBeforeUnload callback error: %s", tostring(err)))
		end
	end
end

local function deserializeInventory(rawInv: { [any]: any }): Types.Inventory
	local inv: Types.Inventory = {}
	for k, v in rawInv do
		local slotIndex = tonumber(k)
		if
			slotIndex
			and slotIndex >= 1
			and slotIndex <= Types.INVENTORY_SIZE
			and slotIndex % 1 == 0
			and type(v) == "table"
			and type(v.Id) == "string"
			and type(v.Count) == "number"
			and v.Count > 0
		then
			inv[slotIndex] = {
				Id = v.Id,
				Count = math.floor(v.Count),
			}
		end
	end
	return inv
end

local function serializeInventory(inv: Types.Inventory): { [string]: Slot }
	local raw: { [string]: Slot } = {}
	for i = 1, Types.INVENTORY_SIZE do
		local slot = inv[i]
		if slot and slot.Count > 0 then
			raw[tostring(i)] = {
				Id = slot.Id,
				Count = slot.Count,
			}
		end
	end
	return raw
end

local function loadPlayerProfile(player: Player)
	local profileKey = string.format("Player_%d", player.UserId)
	local profile = PlayerStore:StartSessionAsync(profileKey, {
		Cancel = function()
			return player.Parent ~= Players
		end,
	})

	if profile ~= nil then
		profile:AddUserId(player.UserId)
		profile:Reconcile()

		local runtimePlayerData: PlayerData = {
			Version = if type(profile.Data.Version) == "number" then profile.Data.Version else 1,
			Inventory = deserializeInventory(
				if type(profile.Data.Inventory) == "table" then profile.Data.Inventory else {}
			),
		}

		profile.OnSave:Connect(function()
			profile.Data.Version = runtimePlayerData.Version
			profile.Data.Inventory = serializeInventory(runtimePlayerData.Inventory)
		end)

		profile.OnLastSave:Connect(function()
			runBeforeUnload(player, runtimePlayerData)
			profile.Data.Version = runtimePlayerData.Version
			profile.Data.Inventory = serializeInventory(runtimePlayerData.Inventory)
		end)

		profile.OnSessionEnd:Connect(function()
			Profiles[player] = nil
			RuntimeData[player] = nil
			unloadedByPlayer[player] = nil
			if player.Parent == Players then
				player:Kick("Profile session ended - please rejoin.")
			end
		end)

		if player.Parent == Players then
			unloadedByPlayer[player] = false
			Profiles[player] = profile
			RuntimeData[player] = runtimePlayerData
			dataLoadedSignal:Fire(player, runtimePlayerData)
		else
			profile:EndSession()
		end
	else
		if player.Parent == Players then
			player:Kick("Failed to load your player data. Please rejoin in a moment.")
		end
	end
end

local function onPlayerRemoving(player: Player)
	local profile = Profiles[player]
	if profile ~= nil then
		local runtimePlayerData = RuntimeData[player]
		if runtimePlayerData ~= nil then
			runBeforeUnload(player, runtimePlayerData)
			profile.Data.Version = runtimePlayerData.Version
			profile.Data.Inventory = serializeInventory(runtimePlayerData.Inventory)
		end
		profile:EndSession()
		Profiles[player] = nil
		RuntimeData[player] = nil
		unloadedByPlayer[player] = nil
	end
end

function DataService.GetData(player: Player): PlayerData?
	local profile = Profiles[player]
	if profile ~= nil and profile:IsActive() then
		return RuntimeData[player]
	end
	return nil
end

function DataService.OnDataLoaded(callback: (player: Player, data: PlayerData) -> ()): Signal.Connection
	local conn = dataLoadedSignal:Connect(callback)
	for player, profile in Profiles do
		if profile:IsActive() then
			local data = RuntimeData[player]
			if data ~= nil then
				task.spawn(callback, player, data)
			end
		end
	end
	return conn
end

function DataService.OnBeforeUnload(callback: (player: Player, data: PlayerData) -> ())
	table.insert(beforeUnloadCallbacks, callback)
end

function DataService.Init()
	if isInitialized then
		return
	end
	isInitialized = true

	Players.PlayerAdded:Connect(loadPlayerProfile)
	Players.PlayerRemoving:Connect(onPlayerRemoving)

	for _, player in Players:GetPlayers() do
		task.spawn(loadPlayerProfile, player)
	end
end

return DataService
