--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Config = require(ReplicatedStorage.Shared.Config)
local Types = require(ReplicatedStorage.Shared.Types)
local BuildingConfig = require(ReplicatedStorage.Shared.configs.BuildingConfig)
local Defenses = require(ReplicatedStorage.Shared.configs.Defenses)
local BuildingGeometry = require(ReplicatedStorage.Shared.BuildingGeometry)
local BaseService = require(ServerScriptService.Server.Services.BaseService)
local BuildingValidator = require(ServerScriptService.Server.Services.BuildingValidator)
local DataService = require(ServerScriptService.Server.Services.DataService)
local InventoryService = require(ServerScriptService.Server.Services.InventoryService)
local SecurityService = require(ServerScriptService.Server.Services.SecurityService)

type Slot = Types.Slot
type ItemBatchEntry = Types.ItemBatchEntry
type BuildTier = Types.BuildTier
type SavedBuildPiece = Types.SavedBuildPiece
type BaseData = Types.BaseData
type RaidTargetInfo = Types.RaidTargetInfo
type RaidIntelPool = Types.RaidIntelPool

local intelPoolsByPlayer: { [Player]: { [number]: RaidIntelPool } } = {}

local RaidIntel = {}

function RaidIntel.ClearPlayerState(player: Player)
	intelPoolsByPlayer[player] = nil
end

function RaidIntel.ResolveTargetName(targetUserId: number): string
	local presetName = DataService.GetPresetDisplayName(targetUserId)
	if presetName ~= nil then
		return presetName
	end
	local presetTier = DataService.GetPresetTier(targetUserId)
	if presetTier ~= nil then
		return string.format("Outpost Tier %d", presetTier)
	end
	local online = Players:GetPlayerByUserId(targetUserId)
	if online ~= nil then
		return online.DisplayName
	end
	local ok, name = pcall(function()
		return Players:GetNameFromUserIdAsync(targetUserId)
	end)
	if ok and type(name) == "string" and #name > 0 then
		return name
	end
	return string.format("Player_%d", targetUserId)
end

local function buildStorageFromLootList(entries: { ItemBatchEntry }?): { [string]: Slot }
	local storage: { [string]: Slot } = {}
	if entries == nil then
		return storage
	end
	for idx, entry in entries do
		storage[tostring(idx)] = { Id = entry.Id, Count = entry.Count }
	end
	return storage
end

local function buildPresetRaidBase(tier: number): BaseData
	local clampedTier = math.clamp(math.floor(tier), 1, 3)
	if clampedTier == 1 then
		local tierCfg = Config.Raid.Tiers[1]
		local pieces: { SavedBuildPiece } = {
			{
				Uid = "preset1_foundation_1",
				PieceType = "foundation",
				Tier = "stone",
				PosX = 0,
				PosY = 0,
				PosZ = 0,
				RotY = 0,
				Hp = 500,
			},
			{
				Uid = "preset1_foundation_2",
				PieceType = "foundation",
				Tier = "stone",
				PosX = 0,
				PosY = 0,
				PosZ = -12,
				RotY = 0,
				Hp = 500,
			},
			{
				Uid = "preset1_wall_front",
				PieceType = "wall",
				Tier = "wood",
				PosX = 0,
				PosY = 1,
				PosZ = 6,
				RotY = 180,
				Hp = 250,
			},
			{
				Uid = "preset1_wall_west_1",
				PieceType = "wall",
				Tier = "stone",
				PosX = -6,
				PosY = 1,
				PosZ = 0,
				RotY = 90,
				Hp = 500,
			},
			{
				Uid = "preset1_wall_east_1",
				PieceType = "wall",
				Tier = "stone",
				PosX = 6,
				PosY = 1,
				PosZ = 0,
				RotY = 270,
				Hp = 500,
			},
			{
				Uid = "preset1_wall_west_2",
				PieceType = "wall",
				Tier = "stone",
				PosX = -6,
				PosY = 1,
				PosZ = -12,
				RotY = 90,
				Hp = 500,
			},
			{
				Uid = "preset1_wall_east_2",
				PieceType = "wall",
				Tier = "stone",
				PosX = 6,
				PosY = 1,
				PosZ = -12,
				RotY = 270,
				Hp = 500,
			},
			{
				Uid = "preset1_wall_north",
				PieceType = "wall",
				Tier = "stone",
				PosX = 0,
				PosY = 1,
				PosZ = -18,
				RotY = 0,
				Hp = 500,
			},
			{
				Uid = "preset1_doorway_inner",
				PieceType = "doorway",
				Tier = "stone",
				PosX = 0,
				PosY = 1,
				PosZ = -6,
				RotY = 0,
				Hp = 400,
			},
			{
				Uid = "preset1_roof_1",
				PieceType = "roof",
				Tier = "stone",
				PosX = 0,
				PosY = 10.2,
				PosZ = 0,
				RotY = 0,
				Hp = 400,
			},
			{
				Uid = "preset1_roof_2",
				PieceType = "roof",
				Tier = "stone",
				PosX = 0,
				PosY = 10.2,
				PosZ = -12,
				RotY = 0,
				Hp = 400,
			},
			{
				Uid = "preset1_tc",
				PieceType = "tool_cupboard",
				Tier = "wood",
				PosX = -3,
				PosY = 1,
				PosZ = -13,
				RotY = 0,
				Hp = 300,
				Storage = buildStorageFromLootList(if tierCfg ~= nil then tierCfg.PresetTcLoot else nil),
			},
			{
				Uid = "preset1_storage_1",
				PieceType = "storage_box",
				Tier = "wood",
				PosX = 3,
				PosY = 1,
				PosZ = -12,
				RotY = 0,
				Hp = 150,
				Storage = buildStorageFromLootList(if tierCfg ~= nil then tierCfg.PresetBoxLoot else nil),
			},
			{
				Uid = "preset1_spikes_1",
				PieceType = "floor_spikes",
				Tier = "wood",
				PosX = 0,
				PosY = 1,
				PosZ = -2,
				RotY = 0,
				MountSurface = "Floor",
				Hp = 100,
			},
			{
				Uid = "preset1_mine_1",
				PieceType = "landmine",
				Tier = "wood",
				PosX = 3,
				PosY = 1,
				PosZ = 2,
				RotY = 0,
				MountSurface = "Floor",
				Hp = 40,
			},
		}
		return {
			Pieces = pieces,
			BaseTier = 1,
			LastUpkeepTimestamp = 0,
		}
	elseif clampedTier == 2 then
		local pieces: { SavedBuildPiece } = {
			{
				Uid = "p2_f1",
				PieceType = "foundation",
				Tier = "metal",
				PosX = 0,
				PosY = 0,
				PosZ = 0,
				RotY = 0,
				Hp = 1000,
			},
			{
				Uid = "p2_f2",
				PieceType = "foundation",
				Tier = "metal",
				PosX = 12,
				PosY = 0,
				PosZ = 0,
				RotY = 0,
				Hp = 1000,
			},
			{
				Uid = "p2_f3",
				PieceType = "foundation",
				Tier = "metal",
				PosX = 0,
				PosY = 0,
				PosZ = -12,
				RotY = 0,
				Hp = 1000,
			},
			{
				Uid = "p2_f4",
				PieceType = "foundation",
				Tier = "metal",
				PosX = 12,
				PosY = 0,
				PosZ = -12,
				RotY = 0,
				Hp = 1000,
			},
			{ Uid = "p2_wf1", PieceType = "wall", Tier = "stone", PosX = 0, PosY = 1, PosZ = 6, RotY = 180, Hp = 500 },
			{
				Uid = "p2_wf2",
				PieceType = "wall",
				Tier = "metal",
				PosX = 12,
				PosY = 1,
				PosZ = 6,
				RotY = 180,
				Hp = 1000,
			},
			{ Uid = "p2_ww1", PieceType = "wall", Tier = "metal", PosX = -6, PosY = 1, PosZ = 0, RotY = 90, Hp = 1000 },
			{
				Uid = "p2_ww2",
				PieceType = "wall",
				Tier = "metal",
				PosX = -6,
				PosY = 1,
				PosZ = -12,
				RotY = 90,
				Hp = 1000,
			},
			{
				Uid = "p2_we1",
				PieceType = "wall",
				Tier = "metal",
				PosX = 18,
				PosY = 1,
				PosZ = 0,
				RotY = 270,
				Hp = 1000,
			},
			{
				Uid = "p2_we2",
				PieceType = "wall",
				Tier = "metal",
				PosX = 18,
				PosY = 1,
				PosZ = -12,
				RotY = 270,
				Hp = 1000,
			},
			{ Uid = "p2_wn1", PieceType = "wall", Tier = "metal", PosX = 0, PosY = 1, PosZ = -18, RotY = 0, Hp = 1000 },
			{
				Uid = "p2_wn2",
				PieceType = "wall",
				Tier = "metal",
				PosX = 12,
				PosY = 1,
				PosZ = -18,
				RotY = 0,
				Hp = 1000,
			},
			{
				Uid = "p2_dw1",
				PieceType = "doorway",
				Tier = "metal",
				PosX = 0,
				PosY = 1,
				PosZ = -6,
				RotY = 0,
				Hp = 800,
			},
			{
				Uid = "p2_dw2",
				PieceType = "doorway",
				Tier = "metal",
				PosX = 6,
				PosY = 1,
				PosZ = -12,
				RotY = 90,
				Hp = 800,
			},
			{ Uid = "p2_r1", PieceType = "roof", Tier = "metal", PosX = 0, PosY = 10.2, PosZ = 0, RotY = 0, Hp = 800 },
			{ Uid = "p2_r2", PieceType = "roof", Tier = "metal", PosX = 12, PosY = 10.2, PosZ = 0, RotY = 0, Hp = 800 },
			{
				Uid = "p2_r3",
				PieceType = "roof",
				Tier = "metal",
				PosX = 0,
				PosY = 10.2,
				PosZ = -12,
				RotY = 0,
				Hp = 800,
			},
			{
				Uid = "p2_r4",
				PieceType = "roof",
				Tier = "metal",
				PosX = 12,
				PosY = 10.2,
				PosZ = -12,
				RotY = 0,
				Hp = 800,
			},
			{
				Uid = "p2_tc",
				PieceType = "tool_cupboard",
				Tier = "wood",
				PosX = 12,
				PosY = 1,
				PosZ = -13,
				RotY = 0,
				Hp = 300,
				Storage = buildStorageFromLootList(
					if Config.Raid.Tiers[2] ~= nil then Config.Raid.Tiers[2].PresetTcLoot else nil
				),
			},
			{
				Uid = "p2_box1",
				PieceType = "storage_box",
				Tier = "wood",
				PosX = 10,
				PosY = 1,
				PosZ = -8,
				RotY = 90,
				Hp = 150,
				Storage = buildStorageFromLootList(
					if Config.Raid.Tiers[2] ~= nil then Config.Raid.Tiers[2].PresetBoxLoot else nil
				),
			},
			{
				Uid = "p2_spikes_1",
				PieceType = "floor_spikes",
				Tier = "wood",
				PosX = 0,
				PosY = 1,
				PosZ = -2,
				RotY = 0,
				MountSurface = "Floor",
				Hp = 100,
			},
			{
				Uid = "p2_shotgun_1",
				PieceType = "shotgun_trap",
				Tier = "wood",
				PosX = -5.6,
				PosY = 5.5,
				PosZ = -12,
				RotY = 270,
				MountSurface = "Wall",
				Hp = BuildingConfig.Pieces.shotgun_trap.BaseHp,
				Storage = {
					["1"] = { Id = "shotgun_shell", Count = 12 },
				},
			},
		}
		return {
			Pieces = pieces,
			BaseTier = 2,
			LastUpkeepTimestamp = 0,
		}
	end

	local pieces: { SavedBuildPiece } = {
		{
			Uid = "p3_f1",
			PieceType = "foundation",
			Tier = "armored",
			PosX = 0,
			PosY = 0,
			PosZ = 0,
			RotY = 0,
			Hp = 2000,
		},
		{
			Uid = "p3_f2",
			PieceType = "foundation",
			Tier = "armored",
			PosX = 12,
			PosY = 0,
			PosZ = 0,
			RotY = 0,
			Hp = 2000,
		},
		{
			Uid = "p3_f3",
			PieceType = "foundation",
			Tier = "armored",
			PosX = 0,
			PosY = 0,
			PosZ = -12,
			RotY = 0,
			Hp = 2000,
		},
		{
			Uid = "p3_f4",
			PieceType = "foundation",
			Tier = "armored",
			PosX = 12,
			PosY = 0,
			PosZ = -12,
			RotY = 0,
			Hp = 2000,
		},
		{ Uid = "p3_wf1", PieceType = "wall", Tier = "metal", PosX = 0, PosY = 1, PosZ = 6, RotY = 180, Hp = 1000 },
		{ Uid = "p3_wf2", PieceType = "wall", Tier = "armored", PosX = 12, PosY = 1, PosZ = 6, RotY = 180, Hp = 2000 },
		{ Uid = "p3_ww1", PieceType = "wall", Tier = "armored", PosX = -6, PosY = 1, PosZ = 0, RotY = 90, Hp = 2000 },
		{ Uid = "p3_ww2", PieceType = "wall", Tier = "armored", PosX = -6, PosY = 1, PosZ = -12, RotY = 90, Hp = 2000 },
		{ Uid = "p3_we1", PieceType = "wall", Tier = "armored", PosX = 18, PosY = 1, PosZ = 0, RotY = 270, Hp = 2000 },
		{
			Uid = "p3_we2",
			PieceType = "wall",
			Tier = "armored",
			PosX = 18,
			PosY = 1,
			PosZ = -12,
			RotY = 270,
			Hp = 2000,
		},
		{ Uid = "p3_wn1", PieceType = "wall", Tier = "armored", PosX = 0, PosY = 1, PosZ = -18, RotY = 0, Hp = 2000 },
		{ Uid = "p3_wn2", PieceType = "wall", Tier = "armored", PosX = 12, PosY = 1, PosZ = -18, RotY = 0, Hp = 2000 },
		{ Uid = "p3_dw1", PieceType = "doorway", Tier = "armored", PosX = 0, PosY = 1, PosZ = -6, RotY = 0, Hp = 1600 },
		{
			Uid = "p3_dw2",
			PieceType = "doorway",
			Tier = "armored",
			PosX = 6,
			PosY = 1,
			PosZ = -12,
			RotY = 90,
			Hp = 1600,
		},
		{ Uid = "p3_r1", PieceType = "roof", Tier = "armored", PosX = 0, PosY = 10.2, PosZ = 0, RotY = 0, Hp = 1600 },
		{ Uid = "p3_r2", PieceType = "roof", Tier = "armored", PosX = 12, PosY = 10.2, PosZ = 0, RotY = 0, Hp = 1600 },
		{ Uid = "p3_r3", PieceType = "roof", Tier = "armored", PosX = 0, PosY = 10.2, PosZ = -12, RotY = 0, Hp = 1600 },
		{
			Uid = "p3_r4",
			PieceType = "roof",
			Tier = "armored",
			PosX = 12,
			PosY = 10.2,
			PosZ = -12,
			RotY = 0,
			Hp = 1600,
		},
		{
			Uid = "p3_tc",
			PieceType = "tool_cupboard",
			Tier = "wood",
			PosX = 12,
			PosY = 1,
			PosZ = -13,
			RotY = 0,
			Hp = 300,
			Storage = buildStorageFromLootList(
				if Config.Raid.Tiers[3] ~= nil then Config.Raid.Tiers[3].PresetTcLoot else nil
			),
		},
		{
			Uid = "p3_box1",
			PieceType = "storage_box",
			Tier = "wood",
			PosX = 10,
			PosY = 1,
			PosZ = -8,
			RotY = 90,
			Hp = 150,
			Storage = buildStorageFromLootList(
				if Config.Raid.Tiers[3] ~= nil then Config.Raid.Tiers[3].PresetBoxLoot else nil
			),
		},
		{
			Uid = "p3_turret_1",
			PieceType = "auto_turret",
			Tier = "wood",
			PosX = 12,
			PosY = 1,
			PosZ = 0,
			RotY = 0,
			MountSurface = "Floor",
			Hp = BuildingConfig.Pieces.auto_turret.BaseHp,
			Storage = {
				["1"] = { Id = "pistol_ammo", Count = 48 },
			},
		},
		{
			Uid = "p3_mine_1",
			PieceType = "landmine",
			Tier = "wood",
			PosX = 0,
			PosY = 1,
			PosZ = -1,
			RotY = 0,
			MountSurface = "Floor",
			Hp = 40,
		},
		{
			Uid = "p3_shotgun_1",
			PieceType = "shotgun_trap",
			Tier = "wood",
			PosX = 0,
			PosY = 10.2,
			PosZ = -12,
			RotY = 180,
			MountSurface = "Ceiling",
			Hp = BuildingConfig.Pieces.shotgun_trap.BaseHp,
			Storage = {
				["1"] = { Id = "shotgun_shell", Count = 12 },
			},
		},
	}
	return {
		Pieces = pieces,
		BaseTier = 3,
		LastUpkeepTimestamp = 0,
	}
end

local function applyPresetVariantOverrides(baseData: BaseData, tier: number, presetUserId: number?): BaseData
	if presetUserId == nil then
		return baseData
	end
	local pieces = baseData.Pieces
	if presetUserId == -1011 then
		for _, p in pieces do
			local canonical = BuildingGeometry.CanonicalPieceType(p.PieceType)
			if canonical == "wall" or canonical == "doorway" or canonical == "roof" then
				p.Tier = "wood"
				p.Hp = BuildingGeometry.ComputeMaxHp(canonical, "wood")
			end
		end
		for i = #pieces, 1, -1 do
			if BuildingGeometry.CanonicalPieceType(pieces[i].PieceType) == "landmine" then
				table.remove(pieces, i)
			end
		end
	elseif presetUserId == -1021 then
		for _, p in pieces do
			local canonical = BuildingGeometry.CanonicalPieceType(p.PieceType)
			if BuildingConfig.Pieces[canonical] and BuildingConfig.Pieces[canonical].Upgradeable then
				p.Tier = "stone"
				p.Hp = BuildingGeometry.ComputeMaxHp(canonical, "stone")
			end
		end
		table.insert(pieces, {
			Uid = "preset1_shotgun_v3",
			PieceType = "shotgun_trap",
			Tier = "wood",
			PosX = 0,
			PosY = 10.2,
			PosZ = -12,
			RotY = 180,
			MountSurface = "Ceiling",
			Hp = BuildingConfig.Pieces.shotgun_trap.BaseHp,
			Storage = { ["1"] = { Id = "shotgun_shell", Count = 8 } },
		})
	elseif presetUserId == -1012 then
		for idx, p in pieces do
			local canonical = BuildingGeometry.CanonicalPieceType(p.PieceType)
			if canonical == "wall" and idx % 2 == 0 then
				p.Tier = "stone"
				p.Hp = BuildingGeometry.ComputeMaxHp(canonical, "stone")
			end
		end
		table.insert(pieces, {
			Uid = "p2_turret_v2",
			PieceType = "auto_turret",
			Tier = "wood",
			PosX = 12,
			PosY = 1,
			PosZ = 0,
			RotY = 0,
			MountSurface = "Floor",
			Hp = BuildingConfig.Pieces.auto_turret.BaseHp,
			Storage = { ["1"] = { Id = "pistol_ammo", Count = 32 } },
		})
	elseif presetUserId == -1022 then
		table.insert(pieces, {
			Uid = "p2_mine_v3",
			PieceType = "landmine",
			Tier = "wood",
			PosX = 6,
			PosY = 1,
			PosZ = -2,
			RotY = 0,
			MountSurface = "Floor",
			Hp = 40,
		})
	elseif presetUserId == -1013 then
		table.insert(pieces, {
			Uid = "p3_turret_v2",
			PieceType = "auto_turret",
			Tier = "wood",
			PosX = 0,
			PosY = 1,
			PosZ = -6,
			RotY = 0,
			MountSurface = "Floor",
			Hp = BuildingConfig.Pieces.auto_turret.BaseHp,
			Storage = { ["1"] = { Id = "pistol_ammo", Count = 48 } },
		})
	elseif presetUserId == -1023 then
		for _, p in pieces do
			local canonical = BuildingGeometry.CanonicalPieceType(p.PieceType)
			if BuildingConfig.Pieces[canonical] and BuildingConfig.Pieces[canonical].Upgradeable then
				p.Tier = "armored"
				p.Hp = BuildingGeometry.ComputeMaxHp(canonical, "armored")
			end
		end
		table.insert(pieces, {
			Uid = "p3_shotgun_v3",
			PieceType = "shotgun_trap",
			Tier = "wood",
			PosX = 12,
			PosY = 10.2,
			PosZ = -12,
			RotY = 180,
			MountSurface = "Ceiling",
			Hp = BuildingConfig.Pieces.shotgun_trap.BaseHp,
			Storage = { ["1"] = { Id = "shotgun_shell", Count = 12 } },
		})
	end
	baseData.BaseTier = math.clamp(math.floor(tier), 1, 3)
	return baseData
end

function RaidIntel.BuildPresetBaseForTarget(tier: number, presetUserId: number?): BaseData
	local baseData = buildPresetRaidBase(tier)
	return applyPresetVariantOverrides(baseData, tier, presetUserId)
end

function RaidIntel.ComputeBaseIntel(
	baseData: BaseData?,
	tier: number
): {
	DominantTier: BuildTier,
	UsedDefenseCapacity: number,
	MaxDefenseCapacity: number,
	TurretCount: number,
	TrapCount: number,
	LootCategory: string,
}
	local clampedTier = math.clamp(math.floor(tier), 1, 3)
	local defaultMat: BuildTier = if clampedTier >= 3 then "armored" elseif clampedTier == 2 then "metal" else "stone"
	local tierCfg = Config.Raid.Tiers[clampedTier]
	local defaultLootCat = if tierCfg ~= nil then tierCfg.RewardLabel else "Base Loot"

	if baseData == nil or #baseData.Pieces == 0 then
		return {
			DominantTier = defaultMat,
			UsedDefenseCapacity = 0,
			MaxDefenseCapacity = Defenses.GetCapacityLimit(clampedTier),
			TurretCount = 0,
			TrapCount = 0,
			LootCategory = defaultLootCat,
		}
	end

	local tierCounts: { [BuildTier]: number } = {
		wood = 0,
		stone = 0,
		metal = 0,
		armored = 0,
	}
	local turretCount = 0
	local trapCount = 0
	local hasHighTierLoot = false
	local hasMidTierLoot = false

	for _, piece in baseData.Pieces do
		local canonical = BuildingGeometry.CanonicalPieceType(piece.PieceType)
		local pCfg = BuildingConfig.Pieces[canonical]
		if pCfg ~= nil and pCfg.Upgradeable then
			local bTier: BuildTier = if tierCounts[piece.Tier] ~= nil then piece.Tier else "wood"
			tierCounts[bTier] += 1
		end
		if canonical == "auto_turret" then
			turretCount += 1
		elseif canonical == "shotgun_trap" or canonical == "landmine" or canonical == "floor_spikes" then
			trapCount += 1
		end
		if type(piece.Storage) == "table" then
			for _, slot in piece.Storage do
				if type(slot) == "table" and type(slot.Id) == "string" then
					if
						slot.Id == "high_quality_metal"
						or slot.Id == "c4_charge"
						or slot.Id == "rocket"
						or slot.Id == "bp_c4_charge"
					then
						hasHighTierLoot = true
					elseif slot.Id == "tech_parts" or slot.Id == "metal_ore" or slot.Id == "satchel_charge" then
						hasMidTierLoot = true
					end
				end
			end
		end
	end

	local bestTier: BuildTier = defaultMat
	local bestCount = -1
	for _, candidate in { "armored" :: BuildTier, "metal" :: BuildTier, "stone" :: BuildTier, "wood" :: BuildTier } do
		if tierCounts[candidate] > bestCount then
			bestCount = tierCounts[candidate]
			bestTier = candidate
		end
	end

	local usedCap, maxCap = BuildingValidator.ComputeDefenseCapacity(baseData.Pieces, clampedTier)
	local lootCategory = if hasHighTierLoot
		then "HQM, Tech & Heavy Explosives"
		elseif hasMidTierLoot then "Metal Ore, Tech & Munitions"
		else defaultLootCat

	return {
		DominantTier = bestTier,
		UsedDefenseCapacity = usedCap,
		MaxDefenseCapacity = maxCap,
		TurretCount = turretCount,
		TrapCount = trapCount,
		LootCategory = lootCategory,
	}
end

local function enrichTargetWithIntel(target: RaidTargetInfo, baseData: BaseData?, tier: number): RaidTargetInfo
	local intel = RaidIntel.ComputeBaseIntel(baseData, tier)
	target.DominantTier = intel.DominantTier
	target.UsedDefenseCapacity = intel.UsedDefenseCapacity
	target.MaxDefenseCapacity = intel.MaxDefenseCapacity
	target.TurretCount = intel.TurretCount
	target.TrapCount = intel.TrapCount
	target.LootCategory = intel.LootCategory
	return target
end

local function buildIntelCardsForTier(player: Player, tier: number, seedOffset: number?): { RaidTargetInfo }
	local clampedTier = math.clamp(math.floor(tier), 1, 3)
	local cardsCount = Config.Raid.IntelCardsCount
	local tierCfg = Config.Raid.Tiers[clampedTier]
	local rng = Random.new((seedOffset or os.time()) + math.abs(player.UserId) + clampedTier * 37)

	local realCandidates: { RaidTargetInfo } = {}
	for _, entry in DataService.GetRaidTargets(player.UserId, 30) do
		if not entry.IsPreset and (entry.BaseTier or 1) == clampedTier then
			local snap: BaseData? = nil
			local onlineTarget = Players:GetPlayerByUserId(entry.UserId)
			local onlineData = if onlineTarget ~= nil then DataService.GetData(onlineTarget) else nil
			if onlineData ~= nil then
				snap = onlineData.Base
			else
				snap = DataService.LoadBaseSnapshot(entry.UserId)
			end
			table.insert(realCandidates, enrichTargetWithIntel(entry, snap, clampedTier))
		end
	end

	for i = #realCandidates, 2, -1 do
		local j = rng:NextInteger(1, i)
		realCandidates[i], realCandidates[j] = realCandidates[j], realCandidates[i]
	end

	local selected: { RaidTargetInfo } = {}
	local usedIds: { [number]: boolean } = {}
	for _, candidate in realCandidates do
		if #selected >= cardsCount then
			break
		end
		usedIds[candidate.UserId] = true
		table.insert(selected, candidate)
	end

	if #selected < cardsCount then
		local presetCandidates: { RaidTargetInfo } = {}
		for _, preset in DataService.GetPresetTargets() do
			if preset.BaseTier == clampedTier and not usedIds[preset.UserId] then
				local presetBase = RaidIntel.BuildPresetBaseForTarget(clampedTier, preset.UserId)
				local info: RaidTargetInfo = {
					UserId = preset.UserId,
					DisplayName = preset.DisplayName,
					PieceCount = #presetBase.Pieces,
					BaseTier = clampedTier,
					DangerLabel = if tierCfg ~= nil then tierCfg.DangerLabel else "Unknown",
					RewardLabel = if tierCfg ~= nil then tierCfg.RewardLabel else "Loot",
					LaunchCost = if tierCfg ~= nil then tierCfg.LaunchCost else nil,
					IsPreset = true,
				}
				table.insert(presetCandidates, enrichTargetWithIntel(info, presetBase, clampedTier))
			end
		end
		for i = #presetCandidates, 2, -1 do
			local j = rng:NextInteger(1, i)
			presetCandidates[i], presetCandidates[j] = presetCandidates[j], presetCandidates[i]
		end
		for _, pCard in presetCandidates do
			if #selected >= cardsCount then
				break
			end
			table.insert(selected, pCard)
		end
	end

	return selected
end

function RaidIntel.GetIntelPool(player: Player, tier: number): RaidIntelPool
	local clampedTier = math.clamp(math.floor(tier), 1, 3)
	local byTier = intelPoolsByPlayer[player]
	if byTier == nil then
		byTier = {}
		intelPoolsByPlayer[player] = byTier
	end
	local existing = byTier[clampedTier]
	if existing ~= nil then
		return existing
	end
	local created: RaidIntelPool = {
		Tier = clampedTier,
		Targets = buildIntelCardsForTier(player, clampedTier, os.time()),
		FreeRefreshAt = os.time() + Config.Raid.IntelFreeRefreshCooldown,
		RefreshCostScrap = Config.Raid.IntelPaidRefreshScrap,
	}
	byTier[clampedTier] = created
	return created
end

function RaidIntel.RefreshIntelPool(player: Player, tier: number, paid: boolean): (boolean, string, RaidIntelPool?)
	local clampedTier = math.clamp(math.floor(tier), 1, 3)
	local pool = RaidIntel.GetIntelPool(player, clampedTier)
	local nowUnix = os.time()

	if not paid then
		if nowUnix < pool.FreeRefreshAt then
			local rem = pool.FreeRefreshAt - nowUnix
			return false, string.format("Free refresh ready in %02d:%02d", math.floor(rem / 60), rem % 60), pool
		end
		pool.Targets = buildIntelCardsForTier(player, clampedTier, nowUnix + math.random(1, 9999))
		pool.FreeRefreshAt = nowUnix + Config.Raid.IntelFreeRefreshCooldown
		return true, string.format("Scouted 3 new Tier %d targets (Free)", clampedTier), pool
	end

	local costScrap = Config.Raid.IntelPaidRefreshScrap
	local paidOk = false
	SecurityService.RunLocked(player, "RaidRefreshIntel", function()
		if DataService.GetData(player) == nil then
			return
		end
		local costBatch: { ItemBatchEntry } = { { Id = "scrap", Count = costScrap } }
		if InventoryService.HasItems(player, costBatch) and InventoryService.RemoveItems(player, costBatch) then
			paidOk = true
		end
	end)

	if not paidOk then
		return false, string.format("Need %d Scrap to refresh Tier %d intel", costScrap, clampedTier), pool
	end

	pool.Targets = buildIntelCardsForTier(player, clampedTier, nowUnix + math.random(1, 9999))
	return true, string.format("Scouted 3 new Tier %d targets (-%d Scrap)", clampedTier, costScrap), pool
end

function RaidIntel.ResolveTargetTier(targetUserId: number): number
	local presetTier = DataService.GetPresetTier(targetUserId)
	if presetTier ~= nil then
		return math.clamp(presetTier, 1, 3)
	end
	local targetBaseTier = 1
	if targetUserId > 0 then
		local onlineTarget = Players:GetPlayerByUserId(targetUserId)
		local onlineData = if onlineTarget ~= nil then DataService.GetData(onlineTarget) else nil
		if onlineData ~= nil then
			targetBaseTier = onlineData.Base.BaseTier
		else
			local snapshot = DataService.LoadBaseSnapshot(targetUserId)
			if snapshot ~= nil then
				local hasTc = false
				for _, p in snapshot.Pieces do
					if BuildingGeometry.CanonicalPieceType(p.PieceType) == "tool_cupboard" then
						hasTc = true
						break
					end
				end
				targetBaseTier = math.max(snapshot.BaseTier, BaseService.ComputeBaseTier(snapshot.Pieces, hasTc))
			end
		end
	end
	return math.clamp(math.floor(targetBaseTier), 1, 3)
end

return RaidIntel
