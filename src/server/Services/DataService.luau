--!strict
local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Types = require(ReplicatedStorage.Shared.Types)
local Config = require(ReplicatedStorage.Shared.Config)
local Signal = require(ReplicatedStorage.Shared.Signal)
local BuildingConfig = require(ReplicatedStorage.Shared.configs.BuildingConfig)
local BuildingGeometry = require(ReplicatedStorage.Shared.BuildingGeometry)
local BaseSerializer = require(ReplicatedStorage.Shared.BaseSerializer)
local Recipes = require(ReplicatedStorage.Shared.configs.Recipes)
local ProfileStore = require(ServerScriptService.Server.Vendor.ProfileStore)
local SecurityService = require(ServerScriptService.Server.Services.SecurityService)

type PlayerData = Types.PlayerData
type Slot = Types.Slot
type InventorySlot = Types.InventorySlot
type EquipmentMap = Types.EquipmentMap
type NetResult<T> = Types.NetResult<T>
type SurvivalStats = Types.SurvivalStats
type BuildPieceType = Types.BuildPieceType
type BuildTier = Types.BuildTier
type SavedBuildPiece = Types.SavedBuildPiece
type BaseData = Types.BaseData
type DefenseMountSurface = Types.DefenseMountSurface
type RaidTargetInfo = Types.RaidTargetInfo
type RaidDefenseReport = Types.RaidDefenseReport
type DeathGhostPoint = Types.DeathGhostPoint
type DefenseLogEntry = Types.DefenseLogEntry
type BlueprintPieceEntry = Types.BlueprintPieceEntry
type BaseBlueprintSlot = Types.BaseBlueprintSlot

local CURRENT_SCHEMA_VERSION: number = Types.CURRENT_SCHEMA_VERSION
local PROFILE_STORE_NAME = "PlayerData_v1"
local RAIDABLE_BASES_STORE_NAME = "RaidableBases_v1"
local DEFENSE_REPORTS_STORE_NAME = "RaidDefenseReports_v1"
local TELEPORT_RELEASE_TIMEOUT = 8
local MOCK_RAID_TARGET_USER_ID = -1001
local MAX_NAME_CACHE_ENTRIES = 256
local MAX_SAVED_DEFENSE_REPORTS = 5

local PRESET_RAID_TARGETS: { { UserId: number, DisplayName: string, PieceCount: number, BaseTier: number } } = {
	{
		UserId = MOCK_RAID_TARGET_USER_ID,
		DisplayName = "Outpost Alpha (Tier 1)",
		PieceCount = 13,
		BaseTier = 1,
	},
	{
		UserId = -1011,
		DisplayName = "Timber Cabin (Tier 1)",
		PieceCount = 11,
		BaseTier = 1,
	},
	{
		UserId = -1021,
		DisplayName = "Quarry Watchpost (Tier 1)",
		PieceCount = 14,
		BaseTier = 1,
	},
	{
		UserId = -1002,
		DisplayName = "Steel Bunker (Tier 2)",
		PieceCount = 22,
		BaseTier = 2,
	},
	{
		UserId = -1012,
		DisplayName = "Scrap Compound (Tier 2)",
		PieceCount = 20,
		BaseTier = 2,
	},
	{
		UserId = -1022,
		DisplayName = "Iron Depot (Tier 2)",
		PieceCount = 24,
		BaseTier = 2,
	},
	{
		UserId = -1003,
		DisplayName = "Armored Citadel (Tier 3)",
		PieceCount = 24,
		BaseTier = 3,
	},
	{
		UserId = -1013,
		DisplayName = "Titan Bastion (Tier 3)",
		PieceCount = 26,
		BaseTier = 3,
	},
	{
		UserId = -1023,
		DisplayName = "Cobalt Vault (Tier 3)",
		PieceCount = 25,
		BaseTier = 3,
	},
}

local DATA_TEMPLATE = {
	SchemaVersion = CURRENT_SCHEMA_VERSION,
	DataVersion = CURRENT_SCHEMA_VERSION,
	Version = CURRENT_SCHEMA_VERSION,
	Inventory = {},
	Equipment = {},
	Stats = {
		Health = Types.MAX_HEALTH,
		Hunger = Types.MAX_HUNGER,
		Thirst = Types.MAX_THIRST,
		WellFedEndTime = 0,
		WellFedStaminaMult = 1.0,
	},
	Base = {
		Pieces = {},
		BaseTier = 0,
		LastUpkeepTimestamp = 0,
		SerializedBlocks = "",
		ContainerSidecar = {},
	},
	UnlockedBlueprints = {},
	DefenseLogs = {},
	BaseBlueprints = {},
	LastStarterKitAt = 0,
}

local PlayerStore = ProfileStore.New(PROFILE_STORE_NAME, DATA_TEMPLATE)

local Profiles: { [Player]: any } = {}
local RuntimeData: { [Player]: PlayerData } = {}
local unloadedByPlayer: { [Player]: boolean } = {}
local transferringPlayers: { [Player]: boolean } = {}
local releasingPlayers: { [Player]: boolean } = {}
local inBeforeUnload: { [Player]: boolean } = {}
local beforeUnloadCallbacks: { (player: Player, data: PlayerData) -> () } = {}
local nameCache: { [number]: string } = {}
local nameCacheCount = 0
local lastRegisteredPieceCount: { [number]: number } = {}
local registerInFlight: { [number]: boolean } = {}
local raidableBasesStore: OrderedDataStore? = nil
local defenseReportsStore: DataStore? = nil
local pendingDefenseReports: { [number]: { RaidDefenseReport } } = {}
local dataLoadedSignal: Signal.Signal<Player, PlayerData> = Signal.new()
local arrivalHandler: ((player: Player) -> ())? = nil
local isInitialized = false

local DEFAULT_SESSION_RETRY_DELAYS: { number } = { 0.5, 1, 2, 4 }

export type LoadProfileOptions = {
	ExpectedInventoryHash: string?,
	WaitForSessionRelease: boolean?,
	RetryDelays: { number }?,
}

local DataService = {
	CURRENT_SCHEMA_VERSION = CURRENT_SCHEMA_VERSION,
	DataLoaded = dataLoadedSignal,
	MOCK_RAID_TARGET_USER_ID = MOCK_RAID_TARGET_USER_ID,
}

local function runBeforeUnload(player: Player, data: PlayerData)
	if unloadedByPlayer[player] then
		return
	end
	unloadedByPlayer[player] = true
	inBeforeUnload[player] = true
	for _, callback in beforeUnloadCallbacks do
		local ok, err = pcall(callback, player, data)
		if not ok then
			warn(string.format("[DataService] OnBeforeUnload callback error: %s", tostring(err)))
		end
	end
	inBeforeUnload[player] = nil
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

local function deserializeEquipment(rawEquip: any): EquipmentMap
	local equip: EquipmentMap = {}
	if type(rawEquip) ~= "table" then
		return equip
	end
	for equipKey, v in rawEquip do
		if
			Types.IsValidString(equipKey, 1, 32)
			and type(v) == "table"
			and Types.IsValidString(v.Id, 1, 64)
			and Types.IsFiniteNumber(v.Count)
			and v.Count > 0
		then
			equip[equipKey :: string] = {
				Id = v.Id,
				Count = math.floor(v.Count),
			}
		end
	end
	return equip
end

local function serializeEquipment(equip: EquipmentMap?): { [string]: InventorySlot }
	local raw: { [string]: InventorySlot } = {}
	if type(equip) ~= "table" then
		return raw
	end
	for equipKey, slot in equip do
		if
			Types.IsValidString(equipKey, 1, 32)
			and slot ~= nil
			and Types.IsValidString(slot.Id, 1, 64)
			and Types.IsFiniteNumber(slot.Count)
			and slot.Count > 0
		then
			raw[equipKey] = {
				Id = slot.Id,
				Count = math.floor(slot.Count),
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

local function isValidFiniteInteger(val: any): boolean
	return type(val) == "number" and val == val and val % 1 == 0 and math.abs(val) ~= math.huge
end

local function deserializeStats(rawStats: any): SurvivalStats
	if type(rawStats) ~= "table" then
		return {
			Health = Types.MAX_HEALTH,
			Hunger = Types.MAX_HUNGER,
			Thirst = Types.MAX_THIRST,
			WellFedEndTime = 0,
			WellFedStaminaMult = 1.0,
		}
	end
	local wellFedEndTime = if isValidFiniteInteger(rawStats.WellFedEndTime)
			and (rawStats.WellFedEndTime :: number) >= 0
		then math.floor(rawStats.WellFedEndTime :: number)
		else 0
	return {
		Health = sanitizeStat(rawStats.Health, Types.MAX_HEALTH, 0, Types.MAX_HEALTH),
		Hunger = sanitizeStat(rawStats.Hunger, Types.MAX_HUNGER, 0, Types.MAX_HUNGER),
		Thirst = sanitizeStat(rawStats.Thirst, Types.MAX_THIRST, 0, Types.MAX_THIRST),
		WellFedEndTime = wellFedEndTime,
		WellFedStaminaMult = sanitizeStat(rawStats.WellFedStaminaMult, 1.0, 1.0, 2.0),
	}
end

local function serializeStats(stats: SurvivalStats): SurvivalStats
	local wellFedEndTime = if isValidFiniteInteger(stats.WellFedEndTime)
			and (stats.WellFedEndTime :: number) >= 0
		then math.floor(stats.WellFedEndTime :: number)
		else 0
	return {
		Health = sanitizeStat(stats.Health, Types.MAX_HEALTH, 0, Types.MAX_HEALTH),
		Hunger = sanitizeStat(stats.Hunger, Types.MAX_HUNGER, 0, Types.MAX_HUNGER),
		Thirst = sanitizeStat(stats.Thirst, Types.MAX_THIRST, 0, Types.MAX_THIRST),
		WellFedEndTime = wellFedEndTime,
		WellFedStaminaMult = sanitizeStat(stats.WellFedStaminaMult, 1.0, 1.0, 2.0),
	}
end

local function deserializeDeathPoints(rawPoints: any): { DeathGhostPoint }
	local points: { DeathGhostPoint } = {}
	if type(rawPoints) ~= "table" then
		return points
	end
	for _, rawPoint in rawPoints do
		if #points >= 12 then
			break
		end
		if
			type(rawPoint) == "table"
			and SecurityService.IsFiniteNumber(rawPoint.PosX)
			and SecurityService.IsFiniteNumber(rawPoint.PosY)
			and SecurityService.IsFiniteNumber(rawPoint.PosZ)
			and type(rawPoint.Cause) == "string"
			and type(rawPoint.RaiderName) == "string"
		then
			table.insert(points, {
				PosX = rawPoint.PosX,
				PosY = rawPoint.PosY,
				PosZ = rawPoint.PosZ,
				Cause = string.sub(rawPoint.Cause, 1, 96),
				RaiderName = string.sub(rawPoint.RaiderName, 1, 48),
			})
		end
	end
	return points
end

local function deserializeDefenseLogs(rawLogs: any): { DefenseLogEntry }
	local logs: { DefenseLogEntry } = {}
	if type(rawLogs) ~= "table" then
		return logs
	end
	for _, rawEntry in rawLogs do
		if type(rawEntry) == "table" and type(rawEntry.RaiderName) == "string" then
			local id = if type(rawEntry.Id) == "string" and #rawEntry.Id > 0
				then string.sub(rawEntry.Id, 1, 64)
				else string.format("log_%d_%d", os.time(), #logs + 1)
			local raiderUserId = if isValidFiniteInteger(rawEntry.RaiderUserId)
				then math.floor(rawEntry.RaiderUserId)
				else 0
			local targetTier = if isValidFiniteInteger(rawEntry.TargetTier)
				then math.clamp(math.floor(rawEntry.TargetTier), 1, 3)
				else 1
			local livesSpent = if isValidFiniteInteger(rawEntry.LivesSpent)
				then math.max(0, math.floor(rawEntry.LivesSpent))
				else 0
			local maxLives = if isValidFiniteInteger(rawEntry.MaxLives)
				then math.max(1, math.floor(rawEntry.MaxLives))
				else Config.Raid.MaxLives
			local rewardScrap = if isValidFiniteInteger(rawEntry.RewardScrap)
				then math.max(0, math.floor(rawEntry.RewardScrap))
				else 0
			local timestamp = if isValidFiniteInteger(rawEntry.Timestamp) and rawEntry.Timestamp >= 0
				then math.floor(rawEntry.Timestamp)
				else os.time()
			local summary = if type(rawEntry.Summary) == "string" then string.sub(rawEntry.Summary, 1, 140) else ""
			table.insert(logs, {
				Id = id,
				RaiderUserId = raiderUserId,
				RaiderName = string.sub(rawEntry.RaiderName, 1, 48),
				TargetTier = targetTier,
				Defended = rawEntry.Defended == true,
				LivesSpent = livesSpent,
				MaxLives = maxLives,
				RewardScrap = rewardScrap,
				Timestamp = timestamp,
				GhostsShown = rawEntry.GhostsShown == true,
				DeathPoints = deserializeDeathPoints(rawEntry.DeathPoints),
				Summary = summary,
			})
		end
	end
	while #logs > MAX_SAVED_DEFENSE_REPORTS do
		table.remove(logs, 1)
	end
	return logs
end

local function serializeDefenseLogs(logs: { DefenseLogEntry }?): { DefenseLogEntry }
	return deserializeDefenseLogs(logs)
end

local function deserializeBlueprints(rawBlueprints: any): { [string]: boolean }
	local unlocked: { [string]: boolean } = {}
	if type(rawBlueprints) ~= "table" then
		return unlocked
	end
	for k, v in rawBlueprints do
		if type(k) == "string" and v == true then
			local recipe = Recipes[k]
			if recipe ~= nil and recipe.RequiresBlueprint then
				unlocked[k] = true
			end
		end
	end
	return unlocked
end

local function serializeBlueprints(unlocked: { [string]: boolean }?): { [string]: boolean }
	return deserializeBlueprints(unlocked)
end

local MAX_BASE_BLUEPRINT_SLOTS = 2
local BLUEPRINT_TIER_SEQUENCE: { BuildTier } = { "wood", "stone", "metal", "armored" }

local function getBaseOrigin(): CFrame
	local attr = Workspace:GetAttribute("BaseOrigin")
	if typeof(attr) == "CFrame" then
		return attr :: CFrame
	end
	return BaseSerializer.DEFAULT_ORIGIN
end

local function computeBlueprintCostFromBlocks(blocks: { SavedBuildPiece }): { [string]: number }
	local costMap: { [string]: number } = {}
	for _, block in blocks do
		local canonical = BuildingGeometry.CanonicalPieceType(block.PieceType)
		local pieceCfg = BuildingConfig.Pieces[canonical]
		if canonical ~= "tool_cupboard" and pieceCfg ~= nil then
			for resId, amt in pieceCfg.Cost do
				if amt > 0 then
					costMap[resId] = (costMap[resId] or 0) + amt
				end
			end
			if pieceCfg.Upgradeable then
				local targetTierCfg = BuildingConfig.Tiers[block.Tier]
				local targetRank = if targetTierCfg ~= nil then targetTierCfg.Rank else 1
				for _, seqTier in BLUEPRINT_TIER_SEQUENCE do
					local seqCfg = BuildingConfig.Tiers[seqTier]
					if
						seqCfg ~= nil
						and seqCfg.Rank > 1
						and seqCfg.Rank <= targetRank
						and seqCfg.UpgradeCost ~= nil
					then
						for resId, amt in seqCfg.UpgradeCost do
							if amt > 0 then
								costMap[resId] = (costMap[resId] or 0) + amt
							end
						end
					end
				end
			end
		end
	end
	return costMap
end

local function sanitizeBlueprintCost(rawCost: any): { [string]: number }?
	if type(rawCost) ~= "table" then
		return nil
	end
	local cost: { [string]: number } = {}
	for resId, amt in rawCost do
		if Types.IsValidString(resId, 1, 64) and isValidFiniteInteger(amt) and (amt :: number) > 0 then
			cost[resId :: string] = math.floor(amt :: number)
		end
	end
	return cost
end

local function deserializeBaseBlueprints(rawMap: any): { [string]: BaseBlueprintSlot }
	local result: { [string]: BaseBlueprintSlot } = {}
	if type(rawMap) ~= "table" then
		return result
	end
	for slotIdx = 1, MAX_BASE_BLUEPRINT_SLOTS do
		local key = tostring(slotIdx)
		local rawSlot = rawMap[key]
		if type(rawSlot) ~= "table" then
			continue
		end

		local slotName = if type(rawSlot.Name) == "string" and #rawSlot.Name > 0
			then string.sub(rawSlot.Name, 1, 48)
			else string.format("Планировка #%d", slotIdx)
		local savedAt = if isValidFiniteInteger(rawSlot.SavedAt) and (rawSlot.SavedAt :: number) >= 0
			then math.floor(rawSlot.SavedAt :: number)
			else 0

		if type(rawSlot.EncodedBlocks) == "string" and #rawSlot.EncodedBlocks > 0 then
			local ok, decoded = BaseSerializer.DeserializeBase(rawSlot.EncodedBlocks, CFrame.identity)
			if ok and type(decoded) == "table" and #(decoded :: { SavedBuildPiece }) > 0 then
				local blocks = decoded :: { SavedBuildPiece }
				local cost = sanitizeBlueprintCost(rawSlot.Cost) or computeBlueprintCostFromBlocks(blocks)
				result[key] = {
					Id = string.format("slot_%d", slotIdx),
					Name = slotName,
					SavedAt = savedAt,
					EncodedBlocks = rawSlot.EncodedBlocks,
					PieceCount = #blocks,
					Cost = cost,
				}
				continue
			end
		end

		if type(rawSlot.Pieces) == "table" then
			local tempBlocks: { SavedBuildPiece } = {}
			for _, rawEntry in rawSlot.Pieces do
				if
					type(rawEntry) == "table"
					and type(rawEntry.PieceType) == "string"
					and SecurityService.IsFiniteNumber(rawEntry.RelX)
					and SecurityService.IsFiniteNumber(rawEntry.RelY)
					and SecurityService.IsFiniteNumber(rawEntry.RelZ)
				then
					local canonical = BuildingGeometry.CanonicalPieceType(rawEntry.PieceType)
					local pieceCfg = BuildingConfig.Pieces[canonical]
					if pieceCfg ~= nil then
						local tier: BuildTier = if type(rawEntry.Tier) == "string"
								and BuildingConfig.Tiers[rawEntry.Tier :: BuildTier] ~= nil
							then rawEntry.Tier :: BuildTier
							else "wood"
						local relRotY = if SecurityService.IsFiniteNumber(rawEntry.RelRotY)
							then BuildingGeometry.QuantizeYaw30(rawEntry.RelRotY :: number)
							else 0
						local mountSurface: DefenseMountSurface? = if rawEntry.MountSurface == "Floor"
								or rawEntry.MountSurface == "Wall"
								or rawEntry.MountSurface == "Ceiling"
							then rawEntry.MountSurface :: DefenseMountSurface
							else nil
						local maxHp = BuildingGeometry.ComputeMaxHp(canonical, tier)
						table.insert(tempBlocks, {
							Uid = string.format("bp_%d_%d", slotIdx, #tempBlocks + 1),
							PieceType = canonical,
							Tier = tier,
							PosX = rawEntry.RelX :: number,
							PosY = rawEntry.RelY :: number,
							PosZ = rawEntry.RelZ :: number,
							RotY = relRotY,
							MountSurface = mountSurface,
							Hp = maxHp,
						})
					end
				end
				if #tempBlocks >= BuildingConfig.MaxPiecesPerBase then
					break
				end
			end
			if #tempBlocks > 0 then
				local encoded = BaseSerializer.SerializeBase(tempBlocks, CFrame.identity)
				result[key] = {
					Id = string.format("slot_%d", slotIdx),
					Name = slotName,
					SavedAt = savedAt,
					EncodedBlocks = encoded,
					PieceCount = #tempBlocks,
					Cost = computeBlueprintCostFromBlocks(tempBlocks),
				}
			end
		end
	end
	return result
end

local function serializeBaseBlueprints(blueprints: { [string]: BaseBlueprintSlot }?): { [string]: BaseBlueprintSlot }
	return deserializeBaseBlueprints(blueprints)
end

local function isValidMountSurface(val: any): boolean
	return val == "Floor" or val == "Wall" or val == "Ceiling"
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
	if type(rawBase) ~= "table" then
		return {
			Pieces = pieces,
			BaseTier = 0,
			LastUpkeepTimestamp = 0,
			SerializedBlocks = "",
		}
	end

	local rawBaseTier = rawBase.BaseTier
	local baseTier = if isValidFiniteInteger(rawBaseTier)
		then math.clamp(math.floor(rawBaseTier :: number), 0, 3)
		else 0
	local rawTimestamp = rawBase.LastUpkeepTimestamp
	local lastUpkeepTimestamp = if isValidFiniteInteger(rawTimestamp) and (rawTimestamp :: number) >= 0
		then math.floor(rawTimestamp :: number)
		else 0

	if type(rawBase.SerializedBlocks) == "string" and #rawBase.SerializedBlocks > 0 then
		local ok, decodedOrErr = BaseSerializer.DeserializeBase(rawBase.SerializedBlocks, getBaseOrigin())
		if ok and type(decodedOrErr) == "table" then
			pieces = decodedOrErr :: { SavedBuildPiece }
			local sidecar = rawBase.ContainerSidecar
			if type(sidecar) == "table" then
				for idx, piece in pieces do
					local pieceCfg = BuildingConfig.Pieces[piece.PieceType]
					if pieceCfg ~= nil and pieceCfg.StorageSlots ~= nil then
						piece.Storage = deserializeStorage(sidecar[tostring(idx)], pieceCfg.StorageSlots)
					end
				end
			end
			return {
				Pieces = pieces,
				BaseTier = baseTier,
				LastUpkeepTimestamp = lastUpkeepTimestamp,
				SerializedBlocks = rawBase.SerializedBlocks,
			}
		else
			warn(
				string.format(
					"[DataService] Failed to deserialize Base.SerializedBlocks (%s); falling back to legacy Pieces",
					tostring(decodedOrErr)
				)
			)
		end
	end

	if type(rawBase.Pieces) ~= "table" then
		return {
			Pieces = pieces,
			BaseTier = baseTier,
			LastUpkeepTimestamp = lastUpkeepTimestamp,
			SerializedBlocks = "",
		}
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
		local rawPieceType = rawPiece.PieceType
		if type(uid) ~= "string" or #uid == 0 or #uid > 64 or seenUids[uid] then
			continue
		end
		if type(rawPieceType) ~= "string" then
			continue
		end

		local pieceType = BuildingGeometry.CanonicalPieceType(rawPieceType)
		local pieceConfig = BuildingConfig.Pieces[pieceType]
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
		local posX: number
		local posY: number
		local posZ: number
		local rotY: number

		if
			SecurityService.IsFiniteNumber(rawPiece.PosX)
			and SecurityService.IsFiniteNumber(rawPiece.PosY)
			and SecurityService.IsFiniteNumber(rawPiece.PosZ)
			and SecurityService.IsFiniteNumber(rawPiece.RotY)
		then
			local rx = rawPiece.PosX :: number
			local ry = rawPiece.PosY :: number
			local rz = rawPiece.PosZ :: number
			if math.abs(rx) > 2000 or math.abs(rz) > 2000 or ry < -50 or ry > 500 then
				continue
			end
			posX = rx
			posY = ry
			posZ = rz
			rotY = BuildingGeometry.QuantizeYaw30(rawPiece.RotY :: number)
		else
			local gridX = rawPiece.GridX
			local gridY = rawPiece.GridY
			local gridZ = rawPiece.GridZ
			local legacyRotY = rawPiece.RotY
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
				or not isValidFiniteInteger(legacyRotY)
				or BuildingConfig.ValidRotations[legacyRotY] ~= true
			then
				continue
			end
			local legacyCF = BuildingGeometry.ConvertLegacyGridPiece(
				pieceType,
				gridX :: number,
				gridY :: number,
				gridZ :: number,
				legacyRotY :: number
			)
			posX = legacyCF.Position.X
			posY = legacyCF.Position.Y
			posZ = legacyCF.Position.Z
			rotY = BuildingGeometry.QuantizeYaw30(BuildingGeometry.ExtractYawDegrees(legacyCF))
		end

		local rawParent = if SecurityService.IsValidString(rawPiece.ParentUid, 1, 64)
			then rawPiece.ParentUid :: string
			elseif SecurityService.IsValidString(rawPiece.AnchorUid, 1, 64) then rawPiece.AnchorUid :: string
			else nil
		local socketId: string? = if SecurityService.IsValidString(rawPiece.SocketId, 1, 32)
			then rawPiece.SocketId :: string
			else nil
		local lastDamagedAt: number? = if SecurityService.IsFiniteNumber(rawPiece.LastDamagedAt)
				and (rawPiece.LastDamagedAt :: number) >= 0
			then rawPiece.LastDamagedAt :: number
			else nil

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

		local mountSurface: DefenseMountSurface? = if isValidMountSurface(rawPiece.MountSurface)
			then rawPiece.MountSurface :: DefenseMountSurface
			else nil

		seenUids[uid] = true
		table.insert(pieces, {
			Uid = uid,
			PieceType = pieceType,
			Tier = tier,
			PosX = posX,
			PosY = posY,
			PosZ = posZ,
			RotY = rotY,
			ParentUid = rawParent,
			AnchorUid = rawParent,
			SocketId = socketId,
			MountSurface = mountSurface,
			Hp = hp,
			LastDamagedAt = lastDamagedAt,
			Storage = storage,
			HasCodeLock = if rawPiece.HasCodeLock == true then true else nil,
			IsDoorOpen = if rawPiece.IsDoorOpen == true then true else nil,
			LinkedHbhfSensor = if rawPiece.LinkedHbhfSensor == true then true else nil,
			HasDoor = if rawPiece.HasDoor == true then true else nil,
		})
	end

	local serializedBlocks = if #pieces > 0 then BaseSerializer.SerializeBase(pieces, getBaseOrigin()) else ""
	return {
		Pieces = pieces,
		BaseTier = baseTier,
		LastUpkeepTimestamp = lastUpkeepTimestamp,
		SerializedBlocks = serializedBlocks,
	}
end

local function serializeBase(baseData: BaseData): BaseData
	if type(baseData) ~= "table" then
		return {
			Pieces = {},
			BaseTier = 0,
			LastUpkeepTimestamp = 0,
			SerializedBlocks = "",
			ContainerSidecar = {},
		}
	end

	local baseTier = if isValidFiniteInteger(baseData.BaseTier)
		then math.clamp(math.floor(baseData.BaseTier), 0, 3)
		else 0
	local lastUpkeepTimestamp = if isValidFiniteInteger(baseData.LastUpkeepTimestamp)
			and baseData.LastUpkeepTimestamp >= 0
		then math.floor(baseData.LastUpkeepTimestamp)
		else 0

	local rawPieces = if type(baseData.Pieces) == "table" then baseData.Pieces else {}
	if #rawPieces == 0 and type(baseData.SerializedBlocks) == "string" and #baseData.SerializedBlocks > 0 then
		return {
			Pieces = {},
			BaseTier = baseTier,
			LastUpkeepTimestamp = lastUpkeepTimestamp,
			SerializedBlocks = baseData.SerializedBlocks,
			ContainerSidecar = if type(baseData.ContainerSidecar) == "table" then baseData.ContainerSidecar else {},
		}
	end

	local validPieces: { SavedBuildPiece } = {}
	local sidecar: { [string]: { [string]: Slot } } = {}

	for _, piece in rawPieces do
		if #validPieces >= BuildingConfig.MaxPiecesPerBase then
			break
		end
		if
			type(piece) == "table"
			and type(piece.PieceType) == "string"
			and SecurityService.IsFiniteNumber(piece.PosX)
			and SecurityService.IsFiniteNumber(piece.PosY)
			and SecurityService.IsFiniteNumber(piece.PosZ)
		then
			local canonicalType = BuildingGeometry.CanonicalPieceType(piece.PieceType)
			local pieceConfig = BuildingConfig.Pieces[canonicalType]
			if pieceConfig ~= nil then
				local parentUid = piece.ParentUid or piece.AnchorUid
				local mountSurface: DefenseMountSurface? = if isValidMountSurface(piece.MountSurface)
					then piece.MountSurface :: DefenseMountSurface
					else nil
				local normalizedPiece: SavedBuildPiece = {
					Uid = piece.Uid,
					PieceType = canonicalType,
					Tier = if BuildingConfig.Tiers[piece.Tier] ~= nil and pieceConfig.Upgradeable
						then piece.Tier
						else "wood",
					PosX = piece.PosX,
					PosY = piece.PosY,
					PosZ = piece.PosZ,
					RotY = if SecurityService.IsFiniteNumber(piece.RotY) then piece.RotY else 0,
					ParentUid = parentUid,
					AnchorUid = parentUid,
					SocketId = piece.SocketId,
					MountSurface = mountSurface,
					Hp = piece.Hp,
					LastDamagedAt = piece.LastDamagedAt,
					HasCodeLock = piece.HasCodeLock,
					IsDoorOpen = piece.IsDoorOpen,
					LinkedHbhfSensor = piece.LinkedHbhfSensor,
					HasDoor = piece.HasDoor,
				}
				table.insert(validPieces, normalizedPiece)
				if pieceConfig.StorageSlots ~= nil then
					local slotStorage = serializeStorage(piece.Storage, pieceConfig.StorageSlots)
					if next(slotStorage) ~= nil then
						sidecar[tostring(#validPieces)] = slotStorage
					end
				end
			end
		end
	end

	local serializedBlocks = if #validPieces > 0 then BaseSerializer.SerializeBase(validPieces, getBaseOrigin()) else ""
	return {
		Pieces = {},
		BaseTier = baseTier,
		LastUpkeepTimestamp = lastUpkeepTimestamp,
		SerializedBlocks = serializedBlocks,
		ContainerSidecar = sidecar,
	}
end

local function deepCloneValue(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local cloned: { [any]: any } = {}
	for k, v in value do
		cloned[deepCloneValue(k)] = deepCloneValue(v)
	end
	return cloned
end

local function resolveSchemaVersion(data: { [string]: any }): number
	if
		type(data.SchemaVersion) == "number"
		and SecurityService.IsFiniteNumber(data.SchemaVersion)
		and data.SchemaVersion >= 0
	then
		return math.floor(data.SchemaVersion)
	end
	if
		type(data.DataVersion) == "number"
		and SecurityService.IsFiniteNumber(data.DataVersion)
		and data.DataVersion >= 0
	then
		return math.floor(data.DataVersion)
	end
	if type(data.Version) == "number" and SecurityService.IsFiniteNumber(data.Version) and data.Version >= 1 then
		return math.floor(data.Version)
	end
	return 0
end

local Migrations: { [number]: (data: { [string]: any }) -> () } = {
	-- v0 -> v1: initial schema (Inventory, Stats, Base)
	[1] = function(data: { [string]: any })
		if type(data.Inventory) ~= "table" then
			data.Inventory = {}
		end
		if type(data.Stats) ~= "table" then
			data.Stats = {
				Health = Types.MAX_HEALTH,
				Hunger = Types.MAX_HUNGER,
				Thirst = Types.MAX_THIRST,
			}
		else
			if not SecurityService.IsFiniteNumber(data.Stats.Health) then
				data.Stats.Health = Types.MAX_HEALTH
			end
			if not SecurityService.IsFiniteNumber(data.Stats.Hunger) then
				data.Stats.Hunger = Types.MAX_HUNGER
			end
			if not SecurityService.IsFiniteNumber(data.Stats.Thirst) then
				data.Stats.Thirst = Types.MAX_THIRST
			end
		end
		if type(data.Base) ~= "table" then
			data.Base = { Pieces = {}, BaseTier = 0, LastUpkeepTimestamp = 0 }
		elseif type(data.Base.Pieces) ~= "table" then
			data.Base.Pieces = {}
		end
	end,

	-- v1 -> v2: GridX/GridY/GridZ -> PosX/PosY/PosZ, RotY 30-deg step, ParentUid, canonical piece types
	[2] = function(data: { [string]: any })
		if type(data.Base) == "table" and type(data.Base.Pieces) == "table" then
			for _, rawPiece in data.Base.Pieces do
				if type(rawPiece) == "table" and type(rawPiece.PieceType) == "string" then
					local canonicalType = BuildingGeometry.CanonicalPieceType(rawPiece.PieceType)
					rawPiece.PieceType = canonicalType

					local hasPos = SecurityService.IsFiniteNumber(rawPiece.PosX)
						and SecurityService.IsFiniteNumber(rawPiece.PosY)
						and SecurityService.IsFiniteNumber(rawPiece.PosZ)
					if not hasPos then
						local gx = if isValidFiniteInteger(rawPiece.GridX) then rawPiece.GridX :: number else 0
						local gy = if isValidFiniteInteger(rawPiece.GridY) then rawPiece.GridY :: number else 0
						local gz = if isValidFiniteInteger(rawPiece.GridZ) then rawPiece.GridZ :: number else 0
						local legacyRot = if SecurityService.IsFiniteNumber(rawPiece.RotY)
							then rawPiece.RotY :: number
							else 0
						local legacyCF = BuildingGeometry.ConvertLegacyGridPiece(canonicalType, gx, gy, gz, legacyRot)
						rawPiece.PosX = legacyCF.Position.X
						rawPiece.PosY = legacyCF.Position.Y
						rawPiece.PosZ = legacyCF.Position.Z
						rawPiece.RotY = BuildingGeometry.QuantizeYaw30(BuildingGeometry.ExtractYawDegrees(legacyCF))
					else
						local curRot = if SecurityService.IsFiniteNumber(rawPiece.RotY)
							then rawPiece.RotY :: number
							else 0
						rawPiece.RotY = BuildingGeometry.QuantizeYaw30(curRot)
					end

					rawPiece.GridX = nil
					rawPiece.GridY = nil
					rawPiece.GridZ = nil

					if rawPiece.ParentUid == nil and type(rawPiece.AnchorUid) == "string" then
						rawPiece.ParentUid = rawPiece.AnchorUid
					elseif rawPiece.AnchorUid == nil and type(rawPiece.ParentUid) == "string" then
						rawPiece.AnchorUid = rawPiece.ParentUid
					end
				end
			end
		end
	end,

	-- v2 -> v3: BaseTier and LastUpkeepTimestamp for Tool Cupboard & Decay
	[3] = function(data: { [string]: any })
		if type(data.Base) ~= "table" then
			data.Base = { Pieces = {}, BaseTier = 0, LastUpkeepTimestamp = os.time() }
		else
			if type(data.Base.Pieces) ~= "table" then
				data.Base.Pieces = {}
			end
			if not isValidFiniteInteger(data.Base.BaseTier) then
				data.Base.BaseTier = 0
			else
				data.Base.BaseTier = math.clamp(math.floor(data.Base.BaseTier :: number), 0, 3)
			end
			if
				not isValidFiniteInteger(data.Base.LastUpkeepTimestamp)
				or (data.Base.LastUpkeepTimestamp :: number) < 0
			then
				data.Base.LastUpkeepTimestamp = os.time()
			end
		end
	end,

	-- v3 -> v4: Defense system support (MountSurface + Defense ammo storage)
	[4] = function(data: { [string]: any })
		if type(data.Base) == "table" and type(data.Base.Pieces) == "table" then
			for _, rawPiece in data.Base.Pieces do
				if type(rawPiece) == "table" and type(rawPiece.PieceType) == "string" then
					local canonical = BuildingGeometry.CanonicalPieceType(rawPiece.PieceType)
					rawPiece.PieceType = canonical
					local pCfg = BuildingConfig.Pieces[canonical]
					if pCfg ~= nil and pCfg.IsDefense == true then
						if not isValidMountSurface(rawPiece.MountSurface) then
							rawPiece.MountSurface = if pCfg.AllowedMount == "WallOrCeiling" then "Wall" else "Floor"
						end
						if pCfg.StorageSlots ~= nil and type(rawPiece.Storage) ~= "table" then
							rawPiece.Storage = {}
						end
					end
				end
			end
		end
	end,

	-- v4 -> v5: Blueprint system (UnlockedBlueprints)
	[5] = function(data: { [string]: any })
		data.UnlockedBlueprints = deserializeBlueprints(data.UnlockedBlueprints)
	end,

	-- v5 -> v6: WellFed timer stats, DefenseLogs, LastStarterKitAt
	[6] = function(data: { [string]: any })
		if type(data.Stats) ~= "table" then
			data.Stats = {
				Health = Types.MAX_HEALTH,
				Hunger = Types.MAX_HUNGER,
				Thirst = Types.MAX_THIRST,
				WellFedEndTime = 0,
				WellFedStaminaMult = 1.0,
			}
		else
			if not isValidFiniteInteger(data.Stats.WellFedEndTime) or (data.Stats.WellFedEndTime :: number) < 0 then
				data.Stats.WellFedEndTime = 0
			end
			data.Stats.WellFedStaminaMult = sanitizeStat(data.Stats.WellFedStaminaMult, 1.0, 1.0, 2.0)
		end
		data.DefenseLogs = deserializeDefenseLogs(data.DefenseLogs)
		if not isValidFiniteInteger(data.LastStarterKitAt) or (data.LastStarterKitAt :: number) < 0 then
			data.LastStarterKitAt = 0
		else
			data.LastStarterKitAt = math.floor(data.LastStarterKitAt :: number)
		end
	end,

	-- v6 -> v7: BaseBlueprints, preserving existing Base.Pieces without loss
	[7] = function(data: { [string]: any })
		data.BaseBlueprints = deserializeBaseBlueprints(data.BaseBlueprints)
	end,

	-- v7 -> v8: Explicit SchemaVersion & Equipment map
	[8] = function(data: { [string]: any })
		data.Equipment = deserializeEquipment(data.Equipment)
	end,

	-- v8 -> v9: Binary buffer serialization for Base & BaseBlueprints
	[9] = function(data: { [string]: any })
		data.Base = serializeBase(deserializeBase(data.Base))
		data.BaseBlueprints = serializeBaseBlueprints(deserializeBaseBlueprints(data.BaseBlueprints))
	end,
}

DataService.Migrations = table.freeze(Migrations)

function DataService.MigrateProfileData(rawData: { [string]: any }): { [string]: any }
	local data: { [string]: any } = if type(rawData) == "table" then deepCloneValue(rawData) else {}

	local currentVersion = resolveSchemaVersion(data)
	if currentVersion > CURRENT_SCHEMA_VERSION then
		warn(
			string.format(
				"[DataService] Profile schema version %d is newer than CURRENT_SCHEMA_VERSION %d; skipping downgrade",
				currentVersion,
				CURRENT_SCHEMA_VERSION
			)
		)
		data.SchemaVersion = currentVersion
		data.DataVersion = currentVersion
		data.Version = currentVersion
		return data
	end

	for targetVersion = currentVersion + 1, CURRENT_SCHEMA_VERSION do
		local migrateFn = Migrations[targetVersion]
		if migrateFn ~= nil then
			migrateFn(data)
		end
		currentVersion = targetVersion
	end

	data.SchemaVersion = currentVersion
	data.DataVersion = currentVersion
	data.Version = currentVersion
	return data
end

local function syncRuntimeToProfile(profile: any, runtimePlayerData: PlayerData)
	profile.Data.SchemaVersion = runtimePlayerData.SchemaVersion
	profile.Data.DataVersion = runtimePlayerData.SchemaVersion
	profile.Data.Version = runtimePlayerData.SchemaVersion
	profile.Data.Inventory = serializeInventory(runtimePlayerData.Inventory)
	profile.Data.Equipment = serializeEquipment(runtimePlayerData.Equipment)
	profile.Data.Stats = serializeStats(runtimePlayerData.Stats)
	profile.Data.Base = serializeBase(runtimePlayerData.Base)
	profile.Data.UnlockedBlueprints = serializeBlueprints(runtimePlayerData.UnlockedBlueprints)
	profile.Data.DefenseLogs = serializeDefenseLogs(runtimePlayerData.DefenseLogs)
	profile.Data.BaseBlueprints = serializeBaseBlueprints(runtimePlayerData.BaseBlueprints)
	profile.Data.LastStarterKitAt = if isValidFiniteInteger(runtimePlayerData.LastStarterKitAt)
			and (runtimePlayerData.LastStarterKitAt :: number) >= 0
		then math.floor(runtimePlayerData.LastStarterKitAt :: number)
		else 0
end

local function getRaidableBasesStore(): OrderedDataStore?
	if raidableBasesStore ~= nil then
		return raidableBasesStore
	end
	local ok, store = pcall(function()
		return DataStoreService:GetOrderedDataStore(RAIDABLE_BASES_STORE_NAME)
	end)
	if ok and store ~= nil then
		raidableBasesStore = store
		return store
	end
	return nil
end

local function registerRaidableBaseByUserId(userId: number, pieceCount: number)
	if not isValidFiniteInteger(userId) or userId <= 0 then
		return
	end
	if not isValidFiniteInteger(pieceCount) or pieceCount <= 0 then
		return
	end
	local count = math.floor(pieceCount)
	if lastRegisteredPieceCount[userId] == count or registerInFlight[userId] then
		return
	end

	local store = getRaidableBasesStore()
	if store == nil then
		return
	end

	registerInFlight[userId] = true
	local ok, err = pcall(function()
		store:SetAsync(tostring(userId), count)
	end)
	registerInFlight[userId] = nil
	if ok then
		lastRegisteredPieceCount[userId] = count
	elseif not RunService:IsStudio() then
		warn(string.format("[DataService] Failed to register raidable base for %d: %s", userId, tostring(err)))
	end
end

local function cacheDisplayName(userId: number, displayName: string)
	if nameCache[userId] == nil then
		if nameCacheCount >= MAX_NAME_CACHE_ENTRIES then
			table.clear(nameCache)
			nameCacheCount = 0
		end
		nameCacheCount += 1
	end
	nameCache[userId] = displayName
end

local function resolveDisplayName(userId: number): string
	local cached = nameCache[userId]
	if cached ~= nil then
		return cached
	end

	local online = Players:GetPlayerByUserId(userId)
	if online ~= nil then
		cacheDisplayName(userId, online.DisplayName)
		return online.DisplayName
	end

	local ok, fetched = pcall(function()
		return Players:GetNameFromUserIdAsync(userId)
	end)
	if ok and type(fetched) == "string" and #fetched > 0 then
		cacheDisplayName(userId, fetched)
		return fetched
	end

	return string.format("Player_%d", userId)
end

local function computeFnv1a32(str: string): number
	local hash = 0x811c9dc5
	for i = 1, #str do
		hash = bit32.bxor(hash, string.byte(str, i))
		-- FNV-1a 32-bit prime: 16777619 = 0x01000193
		local low = bit32.band(hash, 0xFFFF) * 0x0193
		local high = (bit32.rshift(hash, 16) * 0x0193 + bit32.band(hash, 0xFFFF) * 0x0100) * 65536
		hash = bit32.band(low + high, 0xFFFFFFFF)
	end
	return hash
end

function DataService.ComputeInventoryHash(inventory: Types.Inventory, equipment: EquipmentMap?): string
	local parts: { string } = {}
	for i = 1, Types.INVENTORY_SIZE do
		local slot = inventory[i]
		if slot ~= nil and type(slot.Id) == "string" and type(slot.Count) == "number" and slot.Count > 0 then
			table.insert(parts, string.format("I:%d:%s:%d;", i, slot.Id, math.floor(slot.Count)))
		end
	end

	if type(equipment) == "table" then
		local equipKeys: { string } = {}
		for key, slot in equipment do
			if type(key) == "string" and slot ~= nil and type(slot.Id) == "string" and slot.Count > 0 then
				table.insert(equipKeys, key)
			end
		end
		table.sort(equipKeys)
		for _, key in equipKeys do
			local slot = equipment[key]
			if slot ~= nil then
				table.insert(parts, string.format("E:%s:%s:%d;", key, slot.Id, math.floor(slot.Count)))
			end
		end
	end

	local canonical = table.concat(parts)
	local crc32Val = BaseSerializer.ComputeCRC32(buffer.fromstring(canonical))
	local fnvVal = computeFnv1a32(canonical)
	return string.format("%08x%08x", crc32Val, fnvVal)
end

function DataService.GetPlayerInventoryHash(player: Player): string?
	local profile = Profiles[player]
	if profile == nil or not profile:IsActive() then
		return nil
	end
	local runtime = RuntimeData[player]
	if runtime == nil then
		return nil
	end
	return DataService.ComputeInventoryHash(runtime.Inventory, runtime.Equipment)
end

function DataService.FlushBeforeUnload(player: Player): boolean
	local profile = Profiles[player]
	local runtimePlayerData = RuntimeData[player]
	if profile == nil or not profile:IsActive() or runtimePlayerData == nil then
		return false
	end
	runBeforeUnload(player, runtimePlayerData)
	syncRuntimeToProfile(profile, runtimePlayerData)
	return true
end

function DataService.ResetUnloadFlag(player: Player)
	if Profiles[player] ~= nil then
		unloadedByPlayer[player] = false
	end
end

function DataService.SetArrivalHandler(handler: (player: Player) -> ())
	arrivalHandler = handler
end

local function waitForSessionRelease(player: Player, profileKey: string, retryDelays: { number })
	for attempt, delaySec in retryDelays do
		if player.Parent ~= Players then
			return
		end
		local ok, viewProfile = pcall(function()
			return PlayerStore:GetAsync(profileKey)
		end)
		if not ok or viewProfile == nil then
			return
		end
		local session = (viewProfile :: any).Session
		if session == nil or session.JobId == game.JobId then
			return
		end
		warn(
			string.format(
				"[DataService] SessionLock still held for %s (%d) by job %s; retrying in %.1fs (%d/%d)",
				player.Name,
				player.UserId,
				tostring(session.JobId),
				delaySec,
				attempt,
				#retryDelays
			)
		)
		task.wait(delaySec)
	end
end

function DataService.LoadProfileForPlayer(player: Player, options: LoadProfileOptions?): (boolean, PlayerData?)
	if player.Parent ~= Players then
		return false, nil
	end
	local existingProfile = Profiles[player]
	if existingProfile ~= nil and existingProfile:IsActive() then
		local existingData = RuntimeData[player]
		if existingData ~= nil then
			return true, existingData
		end
	end

	local profileKey = string.format("Player_%d", player.UserId)
	local retryDelays = if options ~= nil and options.RetryDelays ~= nil
		then options.RetryDelays
		else DEFAULT_SESSION_RETRY_DELAYS

	if options ~= nil and options.WaitForSessionRelease == true then
		waitForSessionRelease(player, profileKey, retryDelays)
	end

	local profile: any = nil
	local maxAttempts = #retryDelays + 1
	for attempt = 1, maxAttempts do
		if player.Parent ~= Players then
			return false, nil
		end
		profile = PlayerStore:StartSessionAsync(profileKey, {
			Cancel = function()
				return player.Parent ~= Players
			end,
		})
		if profile ~= nil then
			break
		end
		if attempt <= #retryDelays and player.Parent == Players then
			local delaySec = retryDelays[attempt]
			warn(
				string.format(
					"[DataService] StartSessionAsync returned nil for %s (%d); retrying in %.1fs (%d/%d)",
					player.Name,
					player.UserId,
					delaySec,
					attempt,
					#retryDelays
				)
			)
			task.wait(delaySec)
		end
	end

	if profile ~= nil then
		profile:AddUserId(player.UserId)
		profile.Data = DataService.MigrateProfileData(profile.Data)
		profile:Reconcile()

		local currentVersion = resolveSchemaVersion(profile.Data)
		if currentVersion <= 0 then
			currentVersion = CURRENT_SCHEMA_VERSION
		end
		profile.Data.SchemaVersion = currentVersion
		profile.Data.DataVersion = currentVersion
		profile.Data.Version = currentVersion

		local runtimePlayerData: PlayerData = {
			SchemaVersion = currentVersion,
			DataVersion = currentVersion,
			Version = currentVersion,
			Inventory = deserializeInventory(
				if type(profile.Data.Inventory) == "table" then profile.Data.Inventory else {}
			),
			Equipment = deserializeEquipment(profile.Data.Equipment),
			Stats = deserializeStats(profile.Data.Stats),
			Base = deserializeBase(profile.Data.Base),
			UnlockedBlueprints = deserializeBlueprints(profile.Data.UnlockedBlueprints),
			DefenseLogs = deserializeDefenseLogs(profile.Data.DefenseLogs),
			BaseBlueprints = deserializeBaseBlueprints(profile.Data.BaseBlueprints),
			LastStarterKitAt = if isValidFiniteInteger(profile.Data.LastStarterKitAt)
					and (profile.Data.LastStarterKitAt :: number) >= 0
				then math.floor(profile.Data.LastStarterKitAt :: number)
				else 0,
		}

		if options ~= nil and type(options.ExpectedInventoryHash) == "string" then
			local actualHash =
				DataService.ComputeInventoryHash(runtimePlayerData.Inventory, runtimePlayerData.Equipment)
			if actualHash ~= options.ExpectedInventoryHash then
				warn(
					string.format(
						"[DataService] Anti-dupe inventory hash mismatch for %s (%d): expected=%s actual=%s",
						player.Name,
						player.UserId,
						options.ExpectedInventoryHash,
						actualHash
					)
				)
				profile:EndSession()
				if player.Parent == Players then
					player:Kick("Transfer inventory integrity check failed. Please rejoin.")
				end
				return false, nil
			end
		end

		profile.OnSave:Connect(function()
			syncRuntimeToProfile(profile, runtimePlayerData)
			if #runtimePlayerData.Base.Pieces > 0 then
				task.spawn(registerRaidableBaseByUserId, player.UserId, #runtimePlayerData.Base.Pieces)
			end
		end)

		profile.OnLastSave:Connect(function()
			runBeforeUnload(player, runtimePlayerData)
			syncRuntimeToProfile(profile, runtimePlayerData)
			if #runtimePlayerData.Base.Pieces > 0 then
				task.spawn(registerRaidableBaseByUserId, player.UserId, #runtimePlayerData.Base.Pieces)
			end
		end)

		profile.OnSessionEnd:Connect(function()
			Profiles[player] = nil
			RuntimeData[player] = nil
			unloadedByPlayer[player] = nil
			if player.Parent == Players and not transferringPlayers[player] then
				SecurityService.SetTeleportLock(player, true)
				warn(
					string.format(
						"[DataService] Unexpected OnSessionEnd for %s (%d) - kicking to prevent double session",
						player.Name,
						player.UserId
					)
				)
				player:Kick("Profile session ended - please rejoin.")
			end
		end)

		if player.Parent == Players then
			transferringPlayers[player] = nil
			SecurityService.SetTeleportLock(player, false)
			unloadedByPlayer[player] = false
			Profiles[player] = profile
			RuntimeData[player] = runtimePlayerData
			dataLoadedSignal:Fire(player, runtimePlayerData)
			return true, runtimePlayerData
		else
			profile:EndSession()
			return false, nil
		end
	else
		if player.Parent == Players then
			player:Kick("Failed to load your player data. Please rejoin in a moment.")
		end
		return false, nil
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
	end
	Profiles[player] = nil
	RuntimeData[player] = nil
	unloadedByPlayer[player] = nil
	transferringPlayers[player] = nil
	releasingPlayers[player] = nil
	inBeforeUnload[player] = nil
	SecurityService.SetTeleportLock(player, false)
	if not registerInFlight[player.UserId] then
		lastRegisteredPieceCount[player.UserId] = nil
	end
end

function DataService.IsTransferring(player: Player): boolean
	return transferringPlayers[player] == true
end

function DataService.SetTransferring(player: Player, locked: boolean)
	if locked then
		transferringPlayers[player] = true
	else
		transferringPlayers[player] = nil
	end
	SecurityService.SetTeleportLock(player, locked)
end

function DataService.SetTransferLock(player: Player, locked: boolean)
	DataService.SetTransferring(player, locked)
end

function DataService.IsTransferLocked(player: Player): boolean
	return DataService.IsTransferring(player)
end

function DataService.IsTeleporting(player: Player): boolean
	return DataService.IsTransferring(player)
end

function DataService.ReleaseForTeleport(player: Player): boolean
	if releasingPlayers[player] then
		return false
	end
	local profile = Profiles[player]
	if profile == nil or not profile:IsActive() then
		return false
	end

	releasingPlayers[player] = true
	DataService.SetTransferring(player, true)

	local runtimePlayerData = RuntimeData[player]
	if runtimePlayerData ~= nil then
		runBeforeUnload(player, runtimePlayerData)
		syncRuntimeToProfile(profile, runtimePlayerData)
	end

	local lastSaveStarted = false
	local saveCompleted = false
	local lastSaveConn = profile.OnLastSave:Connect(function()
		lastSaveStarted = true
	end)
	local afterSaveConn = profile.OnAfterSave:Connect(function()
		if lastSaveStarted or not profile:IsActive() then
			saveCompleted = true
		end
	end)

	profile:EndSession()

	local deadline = os.clock() + TELEPORT_RELEASE_TIMEOUT
	while (profile:IsActive() or not saveCompleted) and os.clock() < deadline do
		task.wait(0.05)
	end

	lastSaveConn:Disconnect()
	afterSaveConn:Disconnect()
	releasingPlayers[player] = nil

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
	releasingPlayers[player] = nil
	inBeforeUnload[player] = nil

	if player.Parent ~= Players then
		DataService.SetTransferring(player, false)
		return false
	end

	local existingProfile = Profiles[player]
	if existingProfile ~= nil and existingProfile:IsActive() then
		DataService.SetTransferring(player, false)
		return true
	end

	transferringPlayers[player] = nil
	local loadedOk = DataService.LoadProfileForPlayer(player, nil)
	if loadedOk and DataService.GetData(player) ~= nil then
		DataService.SetTransferring(player, false)
		return true
	end

	return false
end

function DataService.GetData(player: Player): PlayerData?
	if transferringPlayers[player] and not inBeforeUnload[player] then
		return nil
	end
	local profile = Profiles[player]
	if profile ~= nil and profile:IsActive() then
		return RuntimeData[player]
	end
	return nil
end

function DataService.GetProfileSnapshot(player: Player): PlayerData?
	local profile = Profiles[player]
	if profile ~= nil and profile:IsActive() then
		local runtime = RuntimeData[player]
		if runtime ~= nil then
			return deepCloneValue(runtime) :: PlayerData
		end
	end
	return nil
end

function DataService.GetInventorySlot(player: Player, slotIndex: number): InventorySlot?
	if not Types.IsValidInteger(slotIndex, 1, Types.INVENTORY_SIZE) then
		return nil
	end
	local profile = Profiles[player]
	if profile == nil or not profile:IsActive() then
		return nil
	end
	local runtime = RuntimeData[player]
	if runtime == nil then
		return nil
	end
	local slot = runtime.Inventory[slotIndex]
	if slot == nil then
		return nil
	end
	return {
		Id = slot.Id,
		Count = slot.Count,
	}
end

function DataService.SetInventorySlot(
	player: Player,
	slotIndex: number,
	slot: InventorySlot?
): NetResult<InventorySlot?>
	if DataService.IsTransferring(player) and not inBeforeUnload[player] then
		return {
			Ok = false,
			ErrorCode = "TRANSFER_LOCKED",
			Message = "Cannot modify inventory while player transfer is in progress.",
		}
	end
	local data = DataService.GetData(player)
	if data == nil then
		return {
			Ok = false,
			ErrorCode = "PROFILE_NOT_LOADED",
			Message = "Player profile is not active.",
		}
	end
	if not Types.IsValidInteger(slotIndex, 1, Types.INVENTORY_SIZE) then
		return {
			Ok = false,
			ErrorCode = "INVALID_SLOT_INDEX",
			Message = string.format("Slot index must be between 1 and %d.", Types.INVENTORY_SIZE),
		}
	end
	if slot ~= nil and not Types.IsValidInventorySlot(slot) then
		return {
			Ok = false,
			ErrorCode = "INVALID_SLOT",
			Message = "Invalid inventory slot payload.",
		}
	end

	if slot == nil then
		data.Inventory[slotIndex] = nil
		return {
			Ok = true,
			Data = nil,
		}
	end

	local copy: InventorySlot = {
		Id = slot.Id,
		Count = math.floor(slot.Count),
	}
	data.Inventory[slotIndex] = copy
	return {
		Ok = true,
		Data = {
			Id = copy.Id,
			Count = copy.Count,
		},
	}
end

local READABLE_PROFILE_FIELDS: { [string]: boolean } = table.freeze({
	SchemaVersion = true,
	DataVersion = true,
	Version = true,
	Inventory = true,
	Equipment = true,
	Stats = true,
	Base = true,
	UnlockedBlueprints = true,
	DefenseLogs = true,
	BaseBlueprints = true,
	LastStarterKitAt = true,
})

local READONLY_PROFILE_FIELDS: { [string]: boolean } = table.freeze({
	SchemaVersion = true,
	DataVersion = true,
	Version = true,
})

local WRITABLE_PROFILE_FIELDS: { [string]: boolean } = table.freeze({
	Inventory = true,
	Equipment = true,
	Stats = true,
	Base = true,
	UnlockedBlueprints = true,
	DefenseLogs = true,
	BaseBlueprints = true,
	LastStarterKitAt = true,
})

function DataService.GetField(player: Player, fieldName: string): any
	if not READABLE_PROFILE_FIELDS[fieldName] then
		return nil
	end
	local profile = Profiles[player]
	if profile == nil or not profile:IsActive() then
		return nil
	end
	local runtime = RuntimeData[player]
	if runtime == nil then
		return nil
	end
	return deepCloneValue((runtime :: { [string]: any })[fieldName])
end

function DataService.SetField(player: Player, fieldName: string, value: any): NetResult<boolean>
	if DataService.IsTransferring(player) and not inBeforeUnload[player] then
		return {
			Ok = false,
			ErrorCode = "TRANSFER_LOCKED",
			Message = "Cannot modify profile while player transfer is in progress.",
		}
	end
	if READONLY_PROFILE_FIELDS[fieldName] then
		return {
			Ok = false,
			ErrorCode = "READONLY_FIELD",
			Message = string.format("Field '%s' is read-only.", fieldName),
		}
	end
	if not WRITABLE_PROFILE_FIELDS[fieldName] then
		return {
			Ok = false,
			ErrorCode = "INVALID_FIELD",
			Message = string.format("Unknown profile field '%s'.", tostring(fieldName)),
		}
	end
	local data = DataService.GetData(player)
	if data == nil then
		return {
			Ok = false,
			ErrorCode = "PROFILE_NOT_LOADED",
			Message = "Player profile is not active.",
		}
	end

	if fieldName == "LastStarterKitAt" then
		if value ~= nil and (not Types.IsFiniteNumber(value) or (value :: number) < 0) then
			return {
				Ok = false,
				ErrorCode = "INVALID_VALUE",
				Message = "LastStarterKitAt must be a non-negative finite number.",
			}
		end
		data.LastStarterKitAt = if value ~= nil then math.floor(value :: number) else 0
	else
		if type(value) ~= "table" then
			return {
				Ok = false,
				ErrorCode = "INVALID_VALUE",
				Message = string.format("Field '%s' must be a table.", fieldName),
			}
		end
		(data :: { [string]: any })[fieldName] = deepCloneValue(value)
	end

	return {
		Ok = true,
		Data = true,
	}
end

function DataService.UpdateProfile(player: Player, mutator: (data: PlayerData) -> ()): NetResult<boolean>
	if DataService.IsTransferring(player) and not inBeforeUnload[player] then
		return {
			Ok = false,
			ErrorCode = "TRANSFER_LOCKED",
			Message = "Cannot mutate profile while player transfer is in progress.",
		}
	end
	local data = DataService.GetData(player)
	if data == nil then
		return {
			Ok = false,
			ErrorCode = "PROFILE_NOT_LOADED",
			Message = "Player profile is not active.",
		}
	end
	local ok, err = pcall(mutator, data)
	if not ok then
		return {
			Ok = false,
			ErrorCode = "MUTATOR_ERROR",
			Message = tostring(err),
		}
	end
	return {
		Ok = true,
		Data = true,
	}
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

function DataService.RegisterRaidableBase(player: Player)
	local data = DataService.GetData(player)
	if data == nil or #data.Base.Pieces <= 0 then
		return
	end
	registerRaidableBaseByUserId(player.UserId, #data.Base.Pieces)
end

function DataService.GetPresetTier(targetUserId: number): number?
	for _, preset in PRESET_RAID_TARGETS do
		if preset.UserId == targetUserId then
			return preset.BaseTier
		end
	end
	return nil
end

function DataService.GetPresetDisplayName(targetUserId: number): string?
	for _, preset in PRESET_RAID_TARGETS do
		if preset.UserId == targetUserId then
			return preset.DisplayName
		end
	end
	return nil
end

function DataService.GetPresetTargets(): { { UserId: number, DisplayName: string, PieceCount: number, BaseTier: number } }
	return PRESET_RAID_TARGETS
end

function DataService.AppendDefenseLog(player: Player, entry: DefenseLogEntry)
	local data = DataService.GetData(player)
	if data == nil then
		return
	end
	if type(data.DefenseLogs) ~= "table" then
		data.DefenseLogs = {}
	end
	table.insert(data.DefenseLogs, entry)
	while #data.DefenseLogs > MAX_SAVED_DEFENSE_REPORTS do
		table.remove(data.DefenseLogs, 1)
	end
end

local function buildPresetTargetInfo(
	preset: { UserId: number, DisplayName: string, PieceCount: number, BaseTier: number }
): RaidTargetInfo
	local tierCfg = Config.Raid.Tiers[preset.BaseTier]
	return {
		UserId = preset.UserId,
		DisplayName = preset.DisplayName,
		PieceCount = preset.PieceCount,
		BaseTier = preset.BaseTier,
		DangerLabel = if tierCfg ~= nil then tierCfg.DangerLabel else "Unknown",
		RewardLabel = if tierCfg ~= nil then tierCfg.RewardLabel else "Loot",
		LaunchCost = if tierCfg ~= nil then tierCfg.LaunchCost else nil,
		IsPreset = true,
	}
end

local function getDefenseReportsStore(): DataStore?
	if defenseReportsStore ~= nil then
		return defenseReportsStore
	end
	local ok, store = pcall(function()
		return DataStoreService:GetDataStore(DEFENSE_REPORTS_STORE_NAME)
	end)
	if ok and store ~= nil then
		defenseReportsStore = store
		return store
	end
	return nil
end

function DataService.RecordRaidDefenseReport(targetUserId: number, report: RaidDefenseReport)
	if not isValidFiniteInteger(targetUserId) then
		return
	end
	local list = pendingDefenseReports[targetUserId]
	if list == nil then
		list = {}
		pendingDefenseReports[targetUserId] = list
	end
	table.insert(list, report)
	while #list > MAX_SAVED_DEFENSE_REPORTS do
		table.remove(list, 1)
	end

	if targetUserId > 0 and not RunService:IsStudio() then
		local store = getDefenseReportsStore()
		if store ~= nil then
			local key = string.format("Reports_%d", math.floor(targetUserId))
			pcall(function()
				store:UpdateAsync(key, function(currentAny: any)
					local current: { any } = if type(currentAny) == "table" then currentAny else {}
					table.insert(current, report)
					while #current > MAX_SAVED_DEFENSE_REPORTS do
						table.remove(current, 1)
					end
					return current
				end)
			end)
		end
	end
end

function DataService.ConsumeDefenseReports(player: Player): { RaidDefenseReport }
	local userId = player.UserId
	local collected: { RaidDefenseReport } = {}
	local memList = pendingDefenseReports[userId]
	if memList ~= nil then
		for _, r in memList do
			table.insert(collected, r)
		end
		pendingDefenseReports[userId] = nil
	end

	if userId > 0 and not RunService:IsStudio() then
		local store = getDefenseReportsStore()
		if store ~= nil then
			local key = string.format("Reports_%d", userId)
			local ok, storedAny = pcall(function()
				return store:GetAsync(key)
			end)
			if ok and type(storedAny) == "table" and #storedAny > 0 then
				for _, entry in storedAny do
					if type(entry) == "table" and type(entry.RaiderName) == "string" then
						table.insert(collected, entry :: RaidDefenseReport)
					end
				end
				pcall(function()
					store:RemoveAsync(key)
				end)
			end
		end
	end

	return collected
end

function DataService.GetRaidTargets(excludeUserId: number, limit: number): { RaidTargetInfo }
	local clampedLimit = if isValidFiniteInteger(limit) then math.clamp(math.floor(limit), 1, 20) else 10
	local targets: { RaidTargetInfo } = {}
	local tierCovered: { [number]: boolean } = {}

	local store = getRaidableBasesStore()
	if store ~= nil then
		local ok, pageEntries = pcall(function()
			local pages = store:GetSortedAsync(false, math.min(clampedLimit + 5, 50))
			return pages:GetCurrentPage()
		end)
		if ok and type(pageEntries) == "table" then
			for _, entry in pageEntries do
				if #targets >= clampedLimit then
					break
				end
				if type(entry) ~= "table" then
					continue
				end
				local userId = tonumber(entry.key)
				local pieceCount = entry.value
				if
					userId ~= nil
					and isValidFiniteInteger(userId)
					and userId > 0
					and userId ~= excludeUserId
					and isValidFiniteInteger(pieceCount)
					and pieceCount > 0
				then
					local intUserId = math.floor(userId)
					local onlineTarget = Players:GetPlayerByUserId(intUserId)
					local onlineData = if onlineTarget ~= nil then RuntimeData[onlineTarget] else nil
					local rawTier = if onlineData ~= nil then onlineData.Base.BaseTier else 1
					if onlineData == nil then
						local snap = DataService.LoadBaseSnapshot(intUserId)
						if snap ~= nil and snap.BaseTier > 0 then
							rawTier = snap.BaseTier
						end
					end
					local targetTier = math.clamp(math.floor(rawTier), 1, 3)
					local tierCfg = Config.Raid.Tiers[targetTier]
					tierCovered[targetTier] = true
					table.insert(targets, {
						UserId = intUserId,
						DisplayName = resolveDisplayName(intUserId),
						PieceCount = math.floor(pieceCount),
						BaseTier = targetTier,
						DangerLabel = if tierCfg ~= nil then tierCfg.DangerLabel else "Unknown",
						RewardLabel = if tierCfg ~= nil then tierCfg.RewardLabel else "Loot",
						LaunchCost = if tierCfg ~= nil then tierCfg.LaunchCost else nil,
						IsPreset = false,
					})
				end
			end
		end
	end

	for _, preset in PRESET_RAID_TARGETS do
		if #targets >= clampedLimit then
			break
		end
		if RunService:IsStudio() or not tierCovered[preset.BaseTier] then
			table.insert(targets, buildPresetTargetInfo(preset))
		end
	end

	return targets
end

function DataService.LoadBaseSnapshot(targetUserId: number): BaseData?
	if not isValidFiniteInteger(targetUserId) or targetUserId <= 0 then
		return nil
	end

	local profileKey = string.format("Player_%d", math.floor(targetUserId))
	local ok, viewProfile = pcall(function()
		return PlayerStore:GetAsync(profileKey)
	end)
	if not ok or viewProfile == nil then
		return nil
	end

	local rawData = (viewProfile :: any).Data
	if type(rawData) ~= "table" then
		return nil
	end

	local migrated = DataService.MigrateProfileData(rawData)
	return deserializeBase(migrated.Base)
end

local function handlePlayerAdded(player: Player)
	if arrivalHandler ~= nil then
		arrivalHandler(player)
	else
		DataService.LoadProfileForPlayer(player, nil)
	end
end

function DataService.Init()
	if isInitialized then
		return
	end
	isInitialized = true

	Players.PlayerAdded:Connect(handlePlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)

	for _, player in Players:GetPlayers() do
		task.spawn(handlePlayerAdded, player)
	end
end

return DataService
