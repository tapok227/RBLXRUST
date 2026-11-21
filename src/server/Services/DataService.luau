--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Types = require(ReplicatedStorage.Shared.Types)
local Signal = require(ReplicatedStorage.Shared.Signal)
local BuildingConfig = require(ReplicatedStorage.Shared.configs.BuildingConfig)
local ProfileStore = require(ServerScriptService.Server.Vendor.ProfileStore)

type PlayerData = Types.PlayerData
type Slot = Types.Slot
type SurvivalStats = Types.SurvivalStats
type BuildPieceType = Types.BuildPieceType
type BuildTier = Types.BuildTier
type SavedBuildPiece = Types.SavedBuildPiece
type BaseData = Types.BaseData

local PROFILE_STORE_NAME = "PlayerData_v1"
local TELEPORT_RELEASE_TIMEOUT = 5

local DATA_TEMPLATE = {
	Version = 1,
	Inventory = {},
	Stats = {
		Health = Types.MAX_HEALTH,
		Hunger = Types.MAX_HUNGER,
		Thirst = Types.MAX_THIRST,
	},
	Base = {
		Pieces = {},
	},
}

local PlayerStore = ProfileStore.New(PROFILE_STORE_NAME, DATA_TEMPLATE)

local Profiles: { [Player]: any } = {}
local RuntimeData: { [Player]: PlayerData } = {}
local unloadedByPlayer: { [Player]: boolean } = {}
local teleportingPlayers: { [Player]: boolean } = {}
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

local function sanitizeStat(value: any, defaultValue: number, minValue: number, maxValue: number): number
	if type(value) == "number" and value == value and math.abs(value) ~= math.huge then
		return math.clamp(value, minValue, maxValue)
	end
	return defaultValue
end

local function deserializeStats(rawStats: any): SurvivalStats
	if type(rawStats) ~= "table" then
		return {
			Health = Types.MAX_HEALTH,
			Hunger = Types.MAX_HUNGER,
			Thirst = Types.MAX_THIRST,
		}
	end
	return {
		Health = sanitizeStat(rawStats.Health, Types.MAX_HEALTH, 0, Types.MAX_HEALTH),
		Hunger = sanitizeStat(rawStats.Hunger, Types.MAX_HUNGER, 0, Types.MAX_HUNGER),
		Thirst = sanitizeStat(rawStats.Thirst, Types.MAX_THIRST, 0, Types.MAX_THIRST),
	}
end

local function serializeStats(stats: SurvivalStats): SurvivalStats
	return {
		Health = sanitizeStat(stats.Health, Types.MAX_HEALTH, 0, Types.MAX_HEALTH),
		Hunger = sanitizeStat(stats.Hunger, Types.MAX_HUNGER, 0, Types.MAX_HUNGER),
		Thirst = sanitizeStat(stats.Thirst, Types.MAX_THIRST, 0, Types.MAX_THIRST),
	}
end

local function isValidFiniteInteger(val: any): boolean
	return type(val) == "number" and val == val and val % 1 == 0 and math.abs(val) ~= math.huge
end

local function deserializeStorage(rawStorage: any, maxSlots: number): { [string]: Slot }
	local storage: { [string]: Slot } = {}
	if type(rawStorage) ~= "table" then
		return storage
	end

	for k, v in rawStorage do
		local slotIndex = tonumber(k)
		if
			slotIndex ~= nil
			and slotIndex >= 1
			and slotIndex <= maxSlots
			and slotIndex % 1 == 0
			and type(v) == "table"
			and type(v.Id) == "string"
			and #v.Id > 0
			and type(v.Count) == "number"
			and v.Count == v.Count
			and math.abs(v.Count) ~= math.huge
			and v.Count > 0
		then
			storage[tostring(slotIndex)] = {
				Id = v.Id,
				Count = math.floor(v.Count),
			}
		end
	end

	return storage
end

local function serializeStorage(storage: { [string]: Slot }?, maxSlots: number): { [string]: Slot }
	local raw: { [string]: Slot } = {}
	if type(storage) ~= "table" then
		return raw
	end

	for k, v in storage do
		local slotIndex = tonumber(k)
		if
			slotIndex ~= nil
			and slotIndex >= 1
			and slotIndex <= maxSlots
			and slotIndex % 1 == 0
			and type(v) == "table"
			and type(v.Id) == "string"
			and #v.Id > 0
			and type(v.Count) == "number"
			and v.Count > 0
		then
			raw[tostring(slotIndex)] = {
				Id = v.Id,
				Count = math.floor(v.Count),
			}
		end
	end

	return raw
end

local function deserializeBase(rawBase: any): BaseData
	local pieces: { SavedBuildPiece } = {}
	if type(rawBase) ~= "table" or type(rawBase.Pieces) ~= "table" then
		return { Pieces = pieces }
	end

	local seenUids: { [string]: boolean } = {}
	for _, rawPiece in rawBase.Pieces do
		if #pieces >= BuildingConfig.MaxPiecesPerBase then
			break
		end
		if type(rawPiece) ~= "table" then
			continue
		end

		local uid = rawPiece.Uid
		local pieceType = rawPiece.PieceType
		if type(uid) ~= "string" or #uid == 0 or #uid > 64 or seenUids[uid] then
			continue
		end
		if type(pieceType) ~= "string" then
			continue
		end

		local pieceConfig = BuildingConfig.Pieces[pieceType :: BuildPieceType]
		if pieceConfig == nil then
			continue
		end

		local rawTier = rawPiece.Tier
		local tier: BuildTier = if type(rawTier) == "string"
				and BuildingConfig.Tiers[rawTier :: BuildTier] ~= nil
			then rawTier :: BuildTier
			else "wood"
		if not pieceConfig.Upgradeable then
			tier = "wood"
		end

		local tierConfig = BuildingConfig.Tiers[tier]
		local gridX = rawPiece.GridX
		local gridY = rawPiece.GridY
		local gridZ = rawPiece.GridZ
		local rotY = rawPiece.RotY
		if
			not isValidFiniteInteger(gridX)
			or gridX < BuildingConfig.GridMinXZ
			or gridX > BuildingConfig.GridMaxXZ
			or not isValidFiniteInteger(gridY)
			or gridY < BuildingConfig.GridMinY
			or gridY > BuildingConfig.GridMaxY
			or not isValidFiniteInteger(gridZ)
			or gridZ < BuildingConfig.GridMinXZ
			or gridZ > BuildingConfig.GridMaxXZ
			or not isValidFiniteInteger(rotY)
			or BuildingConfig.ValidRotations[rotY] ~= true
		then
			continue
		end

		local maxHp = math.floor(pieceConfig.BaseHp * tierConfig.HpMultiplier + 0.5)
		local rawHp = rawPiece.Hp
		local hp = if type(rawHp) == "number"
				and rawHp == rawHp
				and math.abs(rawHp) ~= math.huge
			then math.clamp(math.floor(rawHp + 0.5), 1, maxHp)
			else maxHp

		local storage: { [string]: Slot }? = nil
		if pieceConfig.StorageSlots ~= nil then
			storage = deserializeStorage(rawPiece.Storage, pieceConfig.StorageSlots)
		end

		seenUids[uid] = true
		table.insert(pieces, {
			Uid = uid,
			PieceType = pieceType :: BuildPieceType,
			Tier = tier,
			GridX = gridX,
			GridY = gridY,
			GridZ = gridZ,
			RotY = rotY,
			Hp = hp,
			Storage = storage,
		})
	end

	return {
		Pieces = pieces,
	}
end

local function serializeBase(baseData: BaseData): BaseData
	local pieces: { SavedBuildPiece } = {}
	if type(baseData) ~= "table" or type(baseData.Pieces) ~= "table" then
		return { Pieces = pieces }
	end

	for _, piece in baseData.Pieces do
		local pieceConfig = BuildingConfig.Pieces[piece.PieceType]
		if pieceConfig == nil then
			continue
		end

		local serializedPiece: SavedBuildPiece = {
			Uid = piece.Uid,
			PieceType = piece.PieceType,
			Tier = piece.Tier,
			GridX = piece.GridX,
			GridY = piece.GridY,
			GridZ = piece.GridZ,
			RotY = piece.RotY,
			Hp = piece.Hp,
			Storage = if pieceConfig.StorageSlots ~= nil
				then serializeStorage(piece.Storage, pieceConfig.StorageSlots)
				else nil,
		}
		table.insert(pieces, serializedPiece)
	end

	return {
		Pieces = pieces,
	}
end

local function syncRuntimeToProfile(profile: any, runtimePlayerData: PlayerData)
	profile.Data.Version = runtimePlayerData.Version
	profile.Data.Inventory = serializeInventory(runtimePlayerData.Inventory)
	profile.Data.Stats = serializeStats(runtimePlayerData.Stats)
	profile.Data.Base = serializeBase(runtimePlayerData.Base)
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
			Stats = deserializeStats(profile.Data.Stats),
			Base = deserializeBase(profile.Data.Base),
		}

		profile.OnSave:Connect(function()
			syncRuntimeToProfile(profile, runtimePlayerData)
		end)

		profile.OnLastSave:Connect(function()
			runBeforeUnload(player, runtimePlayerData)
			syncRuntimeToProfile(profile, runtimePlayerData)
		end)

		profile.OnSessionEnd:Connect(function()
			Profiles[player] = nil
			RuntimeData[player] = nil
			unloadedByPlayer[player] = nil
			if player.Parent == Players and not teleportingPlayers[player] then
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
			syncRuntimeToProfile(profile, runtimePlayerData)
		end
		profile:EndSession()
		Profiles[player] = nil
		RuntimeData[player] = nil
		unloadedByPlayer[player] = nil
	end
	teleportingPlayers[player] = nil
end

function DataService.IsTeleporting(player: Player): boolean
	return teleportingPlayers[player] == true
end

function DataService.ReleaseForTeleport(player: Player): boolean
	local profile = Profiles[player]
	if profile == nil or not profile:IsActive() then
		return false
	end

	teleportingPlayers[player] = true

	local runtimePlayerData = RuntimeData[player]
	if runtimePlayerData ~= nil then
		runBeforeUnload(player, runtimePlayerData)
		syncRuntimeToProfile(profile, runtimePlayerData)
	end

	local saveCompleted = false
	local afterSaveConn = profile.OnAfterSave:Connect(function()
		saveCompleted = true
	end)

	profile:EndSession()

	local deadline = os.clock() + TELEPORT_RELEASE_TIMEOUT
	while (profile:IsActive() or not saveCompleted) and os.clock() < deadline do
		task.wait(0.05)
	end

	afterSaveConn:Disconnect()

	if not profile:IsActive() then
		Profiles[player] = nil
		RuntimeData[player] = nil
		unloadedByPlayer[player] = nil
	end

	if not saveCompleted then
		warn(
			string.format(
				"[DataService] ReleaseForTeleport timed out for %s (IsActive=%s)",
				player.Name,
				tostring(profile:IsActive())
			)
		)
	end

	return not profile:IsActive() and saveCompleted
end

function DataService.RestoreAfterFailedTeleport(player: Player): boolean
	if player.Parent ~= Players then
		teleportingPlayers[player] = nil
		return false
	end

	local existingProfile = Profiles[player]
	if existingProfile ~= nil and existingProfile:IsActive() then
		teleportingPlayers[player] = nil
		return true
	end

	teleportingPlayers[player] = nil
	loadPlayerProfile(player)
	return DataService.GetData(player) ~= nil
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
