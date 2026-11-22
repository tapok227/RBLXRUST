--!strict
local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local TeleportService = game:GetService("TeleportService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)
local Types = require(ReplicatedStorage.Shared.Types)
local Items = require(ReplicatedStorage.Shared.configs.Items)
local BuildingConfig = require(ReplicatedStorage.Shared.configs.BuildingConfig)
local Defenses = require(ReplicatedStorage.Shared.configs.Defenses)
local BuildingGeometry = require(ReplicatedStorage.Shared.BuildingGeometry)
local Explosives = require(ReplicatedStorage.Shared.configs.Explosives)
local Janitor = require(ReplicatedStorage.Shared.Janitor)
local Net = require(ReplicatedStorage.Shared.Net)
local BaseService = require(ServerScriptService.Server.Services.BaseService)
local BuildingValidator = require(ServerScriptService.Server.Services.BuildingValidator)
local CraftingService = require(ServerScriptService.Server.Services.CraftingService)
local DataService = require(ServerScriptService.Server.Services.DataService)
local DefenseService = require(ServerScriptService.Server.Services.DefenseService)
local InventoryService = require(ServerScriptService.Server.Services.InventoryService)
local LootService = require(ServerScriptService.Server.Services.LootService)
local SecurityService = require(ServerScriptService.Server.Services.SecurityService)

type Slot = Types.Slot
type Inventory = Types.Inventory
type ItemBatchEntry = Types.ItemBatchEntry
type BuildPieceType = Types.BuildPieceType
type BuildTier = Types.BuildTier
type SavedBuildPiece = Types.SavedBuildPiece
type BaseData = Types.BaseData
type RaidTargetInfo = Types.RaidTargetInfo
type RaidHudState = Types.RaidHudState
type RaidDefenseReport = Types.RaidDefenseReport
type ExplosionParams = Types.ExplosionParams
type ExplosionResult = Types.ExplosionResult

type RaidPieceRecord = {
	Piece: SavedBuildPiece,
	Model: Model,
	ContainerId: string?,
	MaxHp: number,
}

type RaiderPieceRecord = {
	Owner: Player,
	Piece: SavedBuildPiece,
	Model: Model,
	CFrame: CFrame,
}

type ActiveExplosiveRecord = {
	Part: Part,
	Label: TextLabel?,
	CancelFlag: boolean,
}

type RaidSession = {
	Raider: Player,
	TargetUserId: number,
	TargetName: string,
	TargetBaseTier: number,
	Origin: Vector3,
	OutpostOrigin: Vector3,
	IsStudioMock: boolean,
	StartTime: number,
	Duration: number,
	Pieces: { [string]: RaidPieceRecord },
	RaiderPieces: { [string]: RaiderPieceRecord },
	RaiderOccupiedSockets: { [string]: { [string]: string } },
	RaiderOccupiedWorldKeys: { [string]: string },
	OutpostZoneModel: Model?,
	OutpostWorkbenchId: string?,
	ExtractionStashContainerId: string?,
	ExtractionStashModel: Model?,
	ExtractionTerminalModel: Model?,
	ExtractionTerminalPrompt: ProximityPrompt?,
	ExtractionTerminalIndicator: BasePart?,
	ArenaGroundPart: BasePart?,
	RespawnPosition: Vector3,
	DroppedContainerIds: { string },
	ActiveExplosives: { ActiveExplosiveRecord },
	TcPieceUid: string?,
	TcCaptured: boolean,
	TcHackActive: boolean,
	TcHackStartTime: number,
	TcHackPrompt: ProximityPrompt?,
	LivesLeft: number,
	MaxLives: number,
	LastDamagedAt: number,
	Extracting: boolean,
	PendingReturnOnRespawn: boolean,
	ReturnPosition: Vector3?,
	Janitor: Janitor.Janitor,
}

type PendingTeleport = {
	TargetPlaceId: number,
	Options: TeleportOptions,
	IsReturningToMap: boolean,
	TargetName: string,
	LaunchCostBatch: { ItemBatchEntry }?,
}

local RAID_STRUCTURES_FOLDER_NAME = "RaidTargetStructures"
local RAID_OUTPOST_STRUCTURES_FOLDER_NAME = "RaidOutpostStructures"
local LOOT_CONTAINERS_FOLDER_NAME = "LootContainers"
local STUDIO_MOCK_RAID_ORIGIN = Vector3.new(300, 0, 300)
local RAID_DURATION = Types.RAID_DURATION
local LIST_COOLDOWN = 1.0
local EXPLOSIVE_PLACE_COOLDOWN = 0.5
local MAX_HIT_SURFACE_OFFSET = 4.0
local EXPLOSION_EFFECT_BROADCAST_RADIUS = 350
local MAX_OCCLUSION_RAY_PASSES = 8
local DEFAULT_MIN_FALLOFF_MULTIPLIER = 0.25

local activeSessions: { [Player]: RaidSession } = {}
local lastListRequest: { [Player]: number } = {}
local lastExplosivePlaceTime: { [Player]: number } = {}
local teleportInProgress: { [Player]: boolean } = {}
local pendingTeleports: { [Player]: PendingTeleport } = {}
local nextBagId = 0
local nextOutpostSeq = 0
local isInitialized = false

local RaidService = {}

local function getTerminalPosition(inst: Instance): Vector3?
	if inst:IsA("Model") then
		return if inst.PrimaryPart then inst.PrimaryPart.Position else inst:GetPivot().Position
	elseif inst:IsA("BasePart") then
		return inst.Position
	end
	return nil
end

local function isNearRaidTerminal(hrp: BasePart): boolean
	local candidates: { Instance } = {}
	local direct = Workspace:FindFirstChild("RaidTerminal")
	if direct ~= nil then
		table.insert(candidates, direct)
	end
	for _, tagged in CollectionService:GetTagged("RaidTerminal") do
		table.insert(candidates, tagged)
	end
	local deep = Workspace:FindFirstChild("RaidTerminal", true)
	if deep ~= nil then
		table.insert(candidates, deep)
	end

	if #candidates == 0 then
		return true
	end

	local maxDist = Types.MAX_RAID_TERMINAL_DISTANCE + Types.PING_DISTANCE_TOLERANCE
	local anyValidPos = false
	for _, inst in candidates do
		local pos = getTerminalPosition(inst)
		if pos ~= nil then
			anyValidPos = true
			if (hrp.Position - pos).Magnitude <= maxDist then
				return true
			end
		end
	end
	return not anyValidPos
end

local function hasAnySlots(inv: Inventory, maxSlots: number): boolean
	for i = 1, maxSlots do
		local slot = inv[i]
		if slot ~= nil and slot.Count > 0 then
			return true
		end
	end
	return false
end

local function getOrCreateFolder(name: string): Folder
	local existing = Workspace:FindFirstChild(name)
	if existing and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = Workspace
	return folder
end

local function getAliveCharacterParts(player: Player): (Model?, BasePart?, Humanoid?)
	return SecurityService.GetAliveCharacterRoot(player)
end

local function sendRaidHud(player: Player, state: RaidHudState)
	if player.Parent ~= Players then
		return
	end
	Net.GetEvent(Net.Events.RaidHudSync):FireClient(player, state)
end

local function resolveTargetName(targetUserId: number): string
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

local function buildPresetRaidBase(tier: number): BaseData
	local clampedTier = math.clamp(math.floor(tier), 1, 3)
	if clampedTier == 1 then
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
				Storage = {
					["1"] = { Id = "wood", Count = 200 },
					["2"] = { Id = "stone", Count = 120 },
					["3"] = { Id = "scrap", Count = 40 },
				},
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
				Storage = {
					["1"] = { Id = "scrap", Count = 120 },
					["2"] = { Id = "tech_parts", Count = 4 },
					["3"] = { Id = "metal_ore", Count = 80 },
					["4"] = { Id = "pistol_ammo", Count = 24 },
					["5"] = { Id = "cooked_meat", Count = 5 },
				},
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
				Storage = {
					["1"] = { Id = "metal_ore", Count = 150 },
					["2"] = { Id = "scrap", Count = 80 },
				},
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
				Storage = {
					["1"] = { Id = "scrap", Count = 220 },
					["2"] = { Id = "tech_parts", Count = 10 },
					["3"] = { Id = "metal_ore", Count = 160 },
					["4"] = { Id = "satchel_charge", Count = 2 },
					["5"] = { Id = "pistol_ammo", Count = 48 },
				},
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
				Hp = 180,
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
			Storage = {
				["1"] = { Id = "high_quality_metal", Count = 40 },
				["2"] = { Id = "scrap", Count = 150 },
			},
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
			Storage = {
				["1"] = { Id = "high_quality_metal", Count = 65 },
				["2"] = { Id = "tech_parts", Count = 18 },
				["3"] = { Id = "scrap", Count = 350 },
				["4"] = { Id = "c4_charge", Count = 2 },
				["5"] = { Id = "rocket", Count = 3 },
			},
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
			Hp = 350,
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
			Hp = 180,
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

local function createRaidPieceModel(piece: SavedBuildPiece, origin: Vector3): (Model, number)
	local canonicalType = BuildingGeometry.CanonicalPieceType(piece.PieceType)
	piece.PieceType = canonicalType
	local worldCF = BuildingGeometry.GetPieceWorldCFrame(piece, origin)
	local modelName = string.format("Raid_%s_%s", canonicalType, string.sub(piece.Uid, 1, 12))
	local model = BuildingGeometry.CreateModel(canonicalType, worldCF, false, modelName, piece.MountSurface)
	BuildingGeometry.ApplyTierVisuals(model, canonicalType, piece.Tier)

	local maxHp = BuildingGeometry.ComputeMaxHp(canonicalType, piece.Tier)

	model:SetAttribute("RaidPieceUid", piece.Uid)
	model:SetAttribute("BuildUid", piece.Uid)
	model:SetAttribute("PieceType", canonicalType)
	model:SetAttribute("Tier", piece.Tier)
	if piece.MountSurface ~= nil then
		model:SetAttribute("MountSurface", piece.MountSurface)
	end
	model:SetAttribute("Health", piece.Hp)
	model:SetAttribute("Hp", piece.Hp)
	model:SetAttribute("MaxHealth", maxHp)
	model:SetAttribute("MaxHp", maxHp)
	model:SetAttribute("LastDamagedAt", piece.LastDamagedAt or 0)
	model:SetAttribute("IsRaidTarget", true)

	return model, maxHp
end

local function storageMapToInventory(storage: { [string]: Slot }?, maxSlots: number): Inventory
	local inv: Inventory = {}
	if type(storage) ~= "table" then
		return inv
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

local function updatePieceDamageBillboard(record: RaidPieceRecord)
	local primary = record.Model.PrimaryPart
	if not primary then
		return
	end

	local existingGui = primary:FindFirstChild("DamageHpGui")
	local label: TextLabel? = nil

	if existingGui and existingGui:IsA("BillboardGui") then
		local found = existingGui:FindFirstChild("HpLabel")
		if found and found:IsA("TextLabel") then
			label = found
		end
	else
		local gui = Instance.new("BillboardGui")
		gui.Name = "DamageHpGui"
		gui.Size = UDim2.fromOffset(110, 26)
		gui.StudsOffset = Vector3.new(0, 2.5, 0)
		gui.AlwaysOnTop = true
		gui.MaxDistance = 45
		gui.Adornee = primary
		gui.Parent = primary

		local textLabel = Instance.new("TextLabel")
		textLabel.Name = "HpLabel"
		textLabel.Size = UDim2.fromScale(1, 1)
		textLabel.BackgroundColor3 = Color3.fromRGB(22, 16, 16)
		textLabel.BackgroundTransparency = 0.25
		textLabel.BorderSizePixel = 0
		textLabel.Font = Enum.Font.GothamBold
		textLabel.TextSize = 12
		textLabel.TextColor3 = Color3.fromRGB(255, 195, 130)
		textLabel.Parent = gui

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 4)
		corner.Parent = textLabel

		label = textLabel
	end

	if label then
		label.Text = string.format("%d / %d HP", math.max(0, math.floor(record.Piece.Hp)), record.MaxHp)
	end
end

local function closestPointOnModel(model: Model, point: Vector3): Vector3
	local bestPoint: Vector3? = nil
	local bestDistSq = math.huge

	for _, desc in model:GetDescendants() do
		if desc:IsA("BasePart") then
			local localPos = desc.CFrame:PointToObjectSpace(point)
			local half = desc.Size * 0.5
			local clamped = Vector3.new(
				math.clamp(localPos.X, -half.X, half.X),
				math.clamp(localPos.Y, -half.Y, half.Y),
				math.clamp(localPos.Z, -half.Z, half.Z)
			)
			local worldClosest = desc.CFrame:PointToWorldSpace(clamped)
			local delta = worldClosest - point
			local distSq = delta.X * delta.X + delta.Y * delta.Y + delta.Z * delta.Z
			if distSq < bestDistSq then
				bestDistSq = distSq
				bestPoint = worldClosest
			end
		end
	end

	if bestPoint ~= nil then
		return bestPoint
	end

	local cf, size = model:GetBoundingBox()
	local localPos = cf:PointToObjectSpace(point)
	local half = size * 0.5
	return cf:PointToWorldSpace(
		Vector3.new(
			math.clamp(localPos.X, -half.X, half.X),
			math.clamp(localPos.Y, -half.Y, half.Y),
			math.clamp(localPos.Z, -half.Z, half.Z)
		)
	)
end

local function spawnDroppedLootBag(session: RaidSession, position: Vector3, slots: Inventory)
	local folder = getOrCreateFolder(LOOT_CONTAINERS_FOLDER_NAME)
	nextBagId += 1

	local model = Instance.new("Model")
	model.Name = string.format("RaidLootBag_%d", nextBagId)

	local bag = Instance.new("Part")
	bag.Name = "LootBag"
	bag.Size = Vector3.new(2.4, 1.4, 1.8)
	bag.Position = Vector3.new(position.X, session.Origin.Y + 0.8, position.Z)
	bag.Anchored = true
	bag.CanCollide = true
	bag.Material = Enum.Material.Fabric
	bag.Color = Color3.fromRGB(115, 78, 45)
	bag.TopSurface = Enum.SurfaceType.Smooth
	bag.BottomSurface = Enum.SurfaceType.Smooth
	bag.Parent = model

	model.PrimaryPart = bag
	model.Parent = folder

	local containerId = LootService.RegisterSlotsContainer(
		model,
		string.format("%s's Loot Bag", session.TargetName),
		session.TargetName,
		slots,
		Types.LOOT_CONTAINER_LIFETIME
	)
	if #containerId > 0 then
		table.insert(session.DroppedContainerIds, containerId)
	elseif model.Parent then
		model:Destroy()
	end
end

local function costMapToBatch(costMap: { [string]: number }): { ItemBatchEntry }
	local batch: { ItemBatchEntry } = {}
	for itemId, count in costMap do
		if count > 0 then
			table.insert(batch, { Id = itemId, Count = count })
		end
	end
	return batch
end

local function countStashItems(session: RaidSession): number
	if session.ExtractionStashContainerId == nil then
		return 0
	end
	local state = LootService.GetContainerState(session.ExtractionStashContainerId)
	if state == nil then
		return 0
	end
	local total = 0
	for i = 1, Config.Raid.ExtractionStashSlots do
		local slot = state.Slots[i]
		if slot ~= nil and slot.Count > 0 then
			total += slot.Count
		end
	end
	return total
end

local function buildRaidHudState(session: RaidSession, statusText: string?): RaidHudState
	local elapsed = os.clock() - session.StartTime
	local timeLeft = math.max(0, math.ceil(session.Duration - elapsed))
	local hackProgress = 0
	if session.TcCaptured then
		hackProgress = 1
	elseif session.TcHackActive then
		hackProgress = math.clamp((os.clock() - session.TcHackStartTime) / Config.Raid.TcHackDuration, 0, 1)
	end
	return {
		Active = true,
		TargetName = session.TargetName,
		TargetBaseTier = session.TargetBaseTier,
		TimeLeft = timeLeft,
		StatusText = statusText,
		TcCaptured = session.TcCaptured,
		TcHackProgress = hackProgress,
		TcHackActive = session.TcHackActive,
		LivesLeft = session.LivesLeft,
		MaxLives = session.MaxLives,
		StashItemCount = countStashItems(session),
		CanExtract = session.TcCaptured,
	}
end

local function syncSessionHud(session: RaidSession, statusText: string?)
	sendRaidHud(session.Raider, buildRaidHudState(session, statusText))
end

local function sendBuildFeedback(player: Player, success: boolean, message: string)
	if player.Parent ~= Players then
		return
	end
	Net.GetEvent(Net.Events.BuildFeedback):FireClient(player, {
		Success = success,
		Message = message,
	})
end

local function deliverDefenseReports(player: Player)
	if player.Parent ~= Players or DataService.GetData(player) == nil then
		return
	end
	local reports = DataService.ConsumeDefenseReports(player)
	for _, report in reports do
		if report.BonusItems ~= nil then
			local batch = costMapToBatch(report.BonusItems)
			if #batch > 0 then
				BaseService.DepositItemsToPlayerBase(player, batch)
			end
		end
		Net.GetEvent(Net.Events.RaidReportNotify):FireClient(player, report)
	end
end

local function recordDefenseReport(session: RaidSession, defended: boolean, summaryText: string)
	if session.TargetUserId <= 0 then
		return
	end
	local tierCfg = Config.Raid.Tiers[session.TargetBaseTier]
	local bonus = if defended and tierCfg ~= nil then tierCfg.DefenseBonus else nil
	local report: RaidDefenseReport = {
		RaiderName = session.Raider.DisplayName,
		TargetTier = session.TargetBaseTier,
		Defended = defended,
		Timestamp = os.time(),
		BonusItems = bonus,
		Summary = summaryText,
	}
	DataService.RecordRaidDefenseReport(session.TargetUserId, report)
	local onlineDefender = Players:GetPlayerByUserId(session.TargetUserId)
	if onlineDefender ~= nil and onlineDefender ~= session.Raider then
		deliverDefenseReports(onlineDefender)
	end
end

local function cancelTcHack(session: RaidSession, reason: string?)
	if not session.TcHackActive then
		return
	end
	session.TcHackActive = false
	if session.TcHackPrompt ~= nil and session.TcHackPrompt.Parent ~= nil and not session.TcCaptured then
		session.TcHackPrompt.Enabled = true
		session.TcHackPrompt.ActionText = string.format("Hack / Capture TC (%ds)", Config.Raid.TcHackDuration)
	end
	if reason ~= nil and #reason > 0 then
		sendBuildFeedback(session.Raider, false, reason)
		syncSessionHud(session, reason)
	else
		syncSessionHud(session, nil)
	end
end

local function markTcCaptured(session: RaidSession, statusText: string)
	if session.TcCaptured then
		return
	end
	session.TcCaptured = true
	session.TcHackActive = false

	if session.TcHackPrompt ~= nil and session.TcHackPrompt.Parent ~= nil then
		session.TcHackPrompt:Destroy()
		session.TcHackPrompt = nil
	end

	if session.TcPieceUid ~= nil then
		local tcRecord = session.Pieces[session.TcPieceUid]
		if tcRecord ~= nil and tcRecord.Model.Parent ~= nil and tcRecord.ContainerId == nil then
			local tcCfg = BuildingConfig.Pieces.tool_cupboard
			local storageSlots = if tcCfg and tcCfg.StorageSlots
				then tcCfg.StorageSlots
				else Config.Upkeep.TcStorageSlots
			local initialSlots = storageMapToInventory(tcRecord.Piece.Storage, storageSlots)
			local regId = LootService.RegisterStorageContainer(
				tcRecord.Model,
				string.format("%s's Tool Cupboard", session.TargetName),
				nil,
				storageSlots,
				initialSlots,
				nil,
				false
			)
			if #regId > 0 then
				tcRecord.ContainerId = regId
			end
		end
	end

	if session.ExtractionTerminalPrompt ~= nil and session.ExtractionTerminalPrompt.Parent ~= nil then
		session.ExtractionTerminalPrompt.ActionText = "Extract Loot (TC Captured)"
	end
	if session.ExtractionTerminalIndicator ~= nil and session.ExtractionTerminalIndicator.Parent ~= nil then
		session.ExtractionTerminalIndicator.Color = Color3.fromRGB(60, 225, 110)
	end

	sendBuildFeedback(session.Raider, true, statusText)
	syncSessionHud(session, statusText)
end

local function startTcHack(session: RaidSession)
	if session.TcCaptured or session.TcHackActive or session.Extracting then
		return
	end
	local tcUid = session.TcPieceUid
	if tcUid == nil then
		markTcCaptured(session, "TC Captured — Extract Available")
		return
	end
	local tcRecord = session.Pieces[tcUid]
	if tcRecord == nil or tcRecord.Model.Parent == nil or tcRecord.Model.PrimaryPart == nil then
		markTcCaptured(session, "TC Captured — Extract Available")
		return
	end

	local _, hrp, humanoid = getAliveCharacterParts(session.Raider)
	if hrp == nil or humanoid == nil then
		return
	end
	local tcPos = tcRecord.Model.PrimaryPart.Position
	if (hrp.Position - tcPos).Magnitude > Config.Raid.TcHackMaxDistance + Types.PING_DISTANCE_TOLERANCE then
		sendBuildFeedback(
			session.Raider,
			false,
			"Подойдите ближе к вражескому TC для взлома"
		)
		return
	end

	session.TcHackActive = true
	session.TcHackStartTime = os.clock()
	if session.TcHackPrompt ~= nil and session.TcHackPrompt.Parent ~= nil then
		session.TcHackPrompt.Enabled = false
	end
	sendBuildFeedback(
		session.Raider,
		true,
		string.format("Взлом TC запущен (%d сек)...", Config.Raid.TcHackDuration)
	)
	syncSessionHud(session, nil)

	local hackStartedAt = session.TcHackStartTime
	task.spawn(function()
		while activeSessions[session.Raider] == session and session.TcHackActive and not session.TcCaptured do
			if session.Extracting then
				cancelTcHack(session, nil)
				break
			end
			if session.LastDamagedAt >= hackStartedAt then
				cancelTcHack(session, "Взлом TC прерван: получен урон")
				break
			end
			local curTc = session.Pieces[tcUid]
			if curTc == nil or curTc.Model.Parent == nil or curTc.Model.PrimaryPart == nil then
				markTcCaptured(session, "Enemy TC Destroyed — Extract Available")
				break
			end
			local _, innerHrp, innerHum = getAliveCharacterParts(session.Raider)
			if innerHrp == nil or innerHum == nil then
				cancelTcHack(session, "Взлом TC прерван: игрок погиб")
				break
			end
			if
				(innerHrp.Position - curTc.Model.PrimaryPart.Position).Magnitude
				> Config.Raid.TcHackMaxDistance + Types.PING_DISTANCE_TOLERANCE
			then
				cancelTcHack(session, "Взлом TC прерван: вы отошли от шкафа")
				break
			end
			local elapsed = os.clock() - hackStartedAt
			if elapsed >= Config.Raid.TcHackDuration then
				markTcCaptured(session, "TC Captured — Extract Available")
				break
			end
			syncSessionHud(session, nil)
			task.wait(0.25)
		end
	end)
end

local function destroyRaidPiece(session: RaidSession, uid: string, dropStorageLoot: boolean)
	local record = session.Pieces[uid]
	if record == nil then
		return
	end
	session.Pieces[uid] = nil
	DefenseService.UnregisterDefense(uid)

	local dropPos = if record.Model.PrimaryPart then record.Model.PrimaryPart.Position else session.Origin
	local canonical = BuildingGeometry.CanonicalPieceType(record.Piece.PieceType)

	if record.ContainerId ~= nil then
		local state = if dropStorageLoot then LootService.GetContainerState(record.ContainerId) else nil
		LootService.UnregisterContainer(record.ContainerId)
		if state ~= nil and hasAnySlots(state.Slots, Types.INVENTORY_SIZE) then
			spawnDroppedLootBag(session, dropPos, state.Slots)
		end
	elseif dropStorageLoot and record.Piece.Storage ~= nil then
		local fallbackSlots = storageMapToInventory(record.Piece.Storage, Config.Upkeep.TcStorageSlots)
		if hasAnySlots(fallbackSlots, Config.Upkeep.TcStorageSlots) then
			spawnDroppedLootBag(session, dropPos, fallbackSlots)
		end
	end

	if record.Model.Parent then
		record.Model:Destroy()
	end

	if dropStorageLoot and canonical == "tool_cupboard" and not session.TcCaptured then
		markTcCaptured(session, "Enemy TC Destroyed — Extract Available")
	end
end

local function cleanupSession(session: RaidSession)
	session.Janitor:Destroy()

	for _, explosive in session.ActiveExplosives do
		explosive.CancelFlag = true
		if explosive.Part.Parent then
			explosive.Part:Destroy()
		end
	end
	table.clear(session.ActiveExplosives)

	local uids: { string } = {}
	for uid in session.Pieces do
		table.insert(uids, uid)
	end
	for _, uid in uids do
		destroyRaidPiece(session, uid, false)
	end

	if session.ExtractionStashContainerId ~= nil then
		LootService.DestroyContainer(session.ExtractionStashContainerId)
		session.ExtractionStashContainerId = nil
	end
	if session.OutpostWorkbenchId ~= nil then
		CraftingService.UnregisterStation(session.OutpostWorkbenchId)
		session.OutpostWorkbenchId = nil
	end

	for _, rRecord in session.RaiderPieces do
		if rRecord.Model.Parent then
			rRecord.Model:Destroy()
		end
	end
	table.clear(session.RaiderPieces)
	table.clear(session.RaiderOccupiedSockets)
	table.clear(session.RaiderOccupiedWorldKeys)

	if session.ExtractionStashModel and session.ExtractionStashModel.Parent then
		session.ExtractionStashModel:Destroy()
		session.ExtractionStashModel = nil
	end
	if session.ExtractionTerminalModel and session.ExtractionTerminalModel.Parent then
		session.ExtractionTerminalModel:Destroy()
		session.ExtractionTerminalModel = nil
	end
	if session.OutpostZoneModel and session.OutpostZoneModel.Parent then
		session.OutpostZoneModel:Destroy()
		session.OutpostZoneModel = nil
	end
	if session.ArenaGroundPart and session.ArenaGroundPart.Parent then
		session.ArenaGroundPart:Destroy()
		session.ArenaGroundPart = nil
	end

	for _, containerId in session.DroppedContainerIds do
		LootService.DestroyContainer(containerId)
	end
	table.clear(session.DroppedContainerIds)
end

local function spawnRaidTargetBase(session: RaidSession, baseData: BaseData)
	local folder = getOrCreateFolder(RAID_STRUCTURES_FOLDER_NAME)
	local foundTcUid: string? = nil

	for _, savedPiece in baseData.Pieces do
		local pieceConfig = BuildingConfig.Pieces[savedPiece.PieceType]
		if pieceConfig == nil then
			continue
		end

		local copiedStorage: { [string]: Slot }? = nil
		if type(savedPiece.Storage) == "table" then
			copiedStorage = {}
			for k, s in savedPiece.Storage do
				if type(s) == "table" and type(s.Id) == "string" and type(s.Count) == "number" then
					(copiedStorage :: { [string]: Slot })[k] = { Id = s.Id, Count = s.Count }
				end
			end
		end

		local pieceCopy: SavedBuildPiece = {
			Uid = savedPiece.Uid,
			PieceType = savedPiece.PieceType,
			Tier = savedPiece.Tier,
			PosX = savedPiece.PosX,
			PosY = savedPiece.PosY,
			PosZ = savedPiece.PosZ,
			RotY = savedPiece.RotY,
			AnchorUid = savedPiece.AnchorUid,
			SocketId = savedPiece.SocketId,
			MountSurface = savedPiece.MountSurface,
			Hp = savedPiece.Hp,
			Storage = copiedStorage,
			GridX = savedPiece.GridX,
			GridY = savedPiece.GridY,
			GridZ = savedPiece.GridZ,
		}

		local model, maxHp = createRaidPieceModel(pieceCopy, session.Origin)
		model.Parent = folder

		local canonical = BuildingGeometry.CanonicalPieceType(pieceCopy.PieceType)
		local containerId: string? = nil
		if canonical == "storage_box" then
			local storageSlots = pieceConfig.StorageSlots or 18
			local initialSlots = storageMapToInventory(pieceCopy.Storage, storageSlots)
			local containerTitle = string.format("%s's Chest", session.TargetName)
			local registeredId =
				LootService.RegisterStorageContainer(model, containerTitle, nil, storageSlots, initialSlots, nil, false)
			if #registeredId > 0 then
				containerId = registeredId
			end
		elseif canonical == "tool_cupboard" then
			foundTcUid = pieceCopy.Uid
			local primary = model.PrimaryPart
			if primary then
				local hackPrompt = Instance.new("ProximityPrompt")
				hackPrompt.Name = "TcHackPrompt"
				hackPrompt.ActionText = string.format("Hack / Capture TC (%ds)", Config.Raid.TcHackDuration)
				hackPrompt.ObjectText = string.format("%s's Tool Cupboard", session.TargetName)
				hackPrompt.HoldDuration = 0
				hackPrompt.MaxActivationDistance = Config.Raid.TcHackMaxDistance
				hackPrompt.RequiresLineOfSight = false
				hackPrompt.Parent = primary
				session.TcHackPrompt = hackPrompt
				session.Janitor:Add(hackPrompt.Triggered:Connect(function(triggerPlayer: Player)
					if triggerPlayer == session.Raider then
						startTcHack(session)
					end
				end))
			end
		elseif Defenses.Get(canonical) ~= nil then
			local worldCF = BuildingGeometry.GetPieceWorldCFrame(pieceCopy, session.Origin)
			DefenseService.RegisterDefense({
				Uid = pieceCopy.Uid,
				PieceType = canonical,
				Model = model,
				BaseWorldCF = worldCF,
				OwnerUserId = session.TargetUserId,
				IsRaidInstance = true,
				IsQaTest = false,
				PieceRef = pieceCopy,
				Hp = pieceCopy.Hp,
				MaxHp = maxHp,
				OnSelfDamage = function(defUid: string, dmg: number)
					RaidService.DamageRaidPiece(defUid, dmg, "Tool", nil)
				end,
				OnSelfDestroy = function(defUid: string)
					destroyRaidPiece(session, defUid, false)
				end,
			})
		end

		session.Pieces[pieceCopy.Uid] = {
			Piece = pieceCopy,
			Model = model,
			ContainerId = containerId,
			MaxHp = maxHp,
		}
	end

	session.TcPieceUid = foundTcUid
	if foundTcUid == nil then
		session.TcCaptured = true
	end
end

local function teleportCharacterToPosition(player: Player, targetPos: Vector3)
	local character = player.Character
	if not character then
		return
	end
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if hrp and hrp:IsA("BasePart") then
		hrp.AssemblyLinearVelocity = Vector3.zero
		hrp.CFrame = CFrame.new(targetPos)
	else
		character:PivotTo(CFrame.new(targetPos))
	end
end

local function getDefaultSpawnPosition(): Vector3
	local spawnLoc = Workspace:FindFirstChildOfClass("SpawnLocation")
	if spawnLoc then
		return spawnLoc.Position + Vector3.new(0, 4, 0)
	end
	return Vector3.new(0, 6, 0)
end

local function createPrimitivePart(
	parent: Instance,
	name: string,
	size: Vector3,
	cf: CFrame,
	material: Enum.Material,
	color: Color3,
	canCollide: boolean
): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = cf
	part.Anchored = true
	part.CanCollide = canCollide
	part.Material = material
	part.Color = color
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

local function completeStudioReturn(player: Player, session: RaidSession, statusText: string?)
	local released = DataService.ReleaseForTeleport(player)
	print(
		string.format(
			"[RaidService] Studio raid ended for %s (Target=%s, ProfileSaved=%s)",
			player.Name,
			session.TargetName,
			tostring(released)
		)
	)
	DataService.RestoreAfterFailedTeleport(player)

	activeSessions[player] = nil
	cleanupSession(session)
	player:SetAttribute("InRaid", false)
	SecurityService.SetTeleportLock(player, false)

	local returnPos = session.ReturnPosition or getDefaultSpawnPosition()
	teleportCharacterToPosition(player, returnPos)

	sendRaidHud(player, {
		Active = false,
		TargetName = session.TargetName,
		TargetBaseTier = session.TargetBaseTier,
		TimeLeft = 0,
		StatusText = statusText,
	})
end

local function finishRaidSession(player: Player, statusText: string?, delayForRespawn: boolean?)
	local session = activeSessions[player]
	if session == nil or session.Extracting then
		return
	end
	session.Extracting = true
	cancelTcHack(session, nil)
	SecurityService.SetTeleportLock(player, true)
	LootService.CloseContainerForPlayer(player, true)

	if session.IsStudioMock then
		if delayForRespawn then
			session.PendingReturnOnRespawn = true
			sendRaidHud(player, {
				Active = true,
				TargetName = session.TargetName,
				TargetBaseTier = session.TargetBaseTier,
				TimeLeft = 0,
				StatusText = statusText or "Raid failed — returning to PlayerBase...",
				TcCaptured = session.TcCaptured,
				LivesLeft = session.LivesLeft,
				MaxLives = session.MaxLives,
				StashItemCount = 0,
				CanExtract = false,
			})
			task.delay(6.0, function()
				if activeSessions[player] == session and session.PendingReturnOnRespawn then
					session.PendingReturnOnRespawn = false
					completeStudioReturn(player, session, statusText)
				end
			end)
			return
		end
		completeStudioReturn(player, session, statusText)
		return
	end

	if teleportInProgress[player] then
		session.Extracting = false
		SecurityService.SetTeleportLock(player, false)
		return
	end
	teleportInProgress[player] = true

	sendRaidHud(player, {
		Active = true,
		TargetName = session.TargetName,
		TargetBaseTier = session.TargetBaseTier,
		TimeLeft = 0,
		StatusText = statusText or "Returning to PlayerBase...",
		TcCaptured = session.TcCaptured,
		LivesLeft = session.LivesLeft,
		MaxLives = session.MaxLives,
		StashItemCount = countStashItems(session),
		CanExtract = false,
	})

	local released = DataService.ReleaseForTeleport(player)
	if not released then
		warn(string.format("[RaidService] Failed to release profile after raid for %s", player.Name))
		DataService.RestoreAfterFailedTeleport(player)
		teleportInProgress[player] = nil
		session.Extracting = false
		SecurityService.SetTeleportLock(player, false)
		return
	end

	if player.Parent ~= Players then
		activeSessions[player] = nil
		cleanupSession(session)
		teleportInProgress[player] = nil
		SecurityService.SetTeleportLock(player, false)
		return
	end

	local options = Instance.new("TeleportOptions")
	options:SetTeleportData({
		FromPlaceId = game.PlaceId,
		OwnerUserId = player.UserId,
		RaiderUserId = player.UserId,
		Mode = "Base",
	})

	pendingTeleports[player] = {
		TargetPlaceId = Config.Places.PlayerBase,
		Options = options,
		IsReturningToMap = true,
		TargetName = session.TargetName,
	}

	local ok, err = pcall(function()
		TeleportService:TeleportAsync(Config.Places.PlayerBase, { player }, options)
	end)
	if not ok then
		warn(string.format("[RaidService] Return TeleportAsync error for %s: %s", player.Name, tostring(err)))
		pendingTeleports[player] = nil
		teleportInProgress[player] = nil
		session.Extracting = false
		SecurityService.SetTeleportLock(player, false)
		DataService.RestoreAfterFailedTeleport(player)
	end
end

local function failRaidSession(player: Player, reason: string, delayForRespawn: boolean?)
	local session = activeSessions[player]
	if session == nil or session.Extracting then
		return
	end
	recordDefenseReport(session, true, string.format("%s's raid failed (%s)", player.DisplayName, reason))
	finishRaidSession(player, reason, delayForRespawn)
end

local function collectStashBatch(session: RaidSession): ({ ItemBatchEntry }, number)
	local batch: { ItemBatchEntry } = {}
	local totalItems = 0
	if session.ExtractionStashContainerId == nil then
		return batch, 0
	end
	local state = LootService.GetContainerState(session.ExtractionStashContainerId)
	if state == nil then
		return batch, 0
	end
	for i = 1, Config.Raid.ExtractionStashSlots do
		local slot = state.Slots[i]
		if slot ~= nil and slot.Count > 0 then
			table.insert(batch, { Id = slot.Id, Count = slot.Count })
			totalItems += slot.Count
		end
	end
	return batch, totalItems
end

local function isRaiderInExtractionZone(session: RaidSession, hrp: BasePart): boolean
	if session.ExtractionTerminalModel and session.ExtractionTerminalModel.PrimaryPart then
		if (hrp.Position - session.ExtractionTerminalModel.PrimaryPart.Position).Magnitude <= 18 then
			return true
		end
	end
	local delta = hrp.Position - session.OutpostOrigin
	return math.abs(delta.X) <= Config.Raid.OutpostRadius + 4 and math.abs(delta.Z) <= Config.Raid.OutpostRadius + 4
end

local function tryExtractFromRaid(player: Player)
	local session = activeSessions[player]
	if session == nil or session.Extracting then
		return
	end
	if teleportInProgress[player] or SecurityService.IsTeleportLocked(player) then
		return
	end
	if DataService.GetData(player) == nil then
		return
	end
	local _, hrp = getAliveCharacterParts(player)
	if hrp == nil then
		return
	end
	if not session.TcCaptured then
		sendBuildFeedback(
			player,
			false,
			"Сначала захватите или уничтожьте вражеский TC!"
		)
		return
	end
	if not isRaiderInExtractionZone(session, hrp) then
		sendBuildFeedback(
			player,
			false,
			"Вернитесь к терминалу эвакуации в рейд-кибитке!"
		)
		return
	end

	local extractedItems, totalCount = collectStashBatch(session)
	if #extractedItems > 0 then
		BaseService.DepositItemsToPlayerBase(player, extractedItems)
	end
	recordDefenseReport(
		session,
		false,
		string.format("%s captured TC and extracted (%d stash items)", player.DisplayName, totalCount)
	)
	finishRaidSession(
		player,
		string.format("Extracted to PlayerBase! Saved %d items from ExtractionStash", totalCount),
		false
	)
end

local function spawnOutpostStructuralPiece(
	session: RaidSession,
	folder: Folder,
	uid: string,
	pieceType: BuildPieceType,
	worldCF: CFrame,
	parentUid: string?,
	socketId: string?
)
	local piece: SavedBuildPiece = {
		Uid = uid,
		PieceType = pieceType,
		Tier = "wood",
		PosX = worldCF.Position.X,
		PosY = worldCF.Position.Y,
		PosZ = worldCF.Position.Z,
		RotY = BuildingGeometry.QuantizeYaw30(BuildingGeometry.ExtractYawDegrees(worldCF)),
		ParentUid = parentUid,
		AnchorUid = parentUid,
		SocketId = socketId,
		Hp = BuildingGeometry.ComputeMaxHp(pieceType, "wood"),
	}
	local model = BuildingGeometry.CreateModel(pieceType, worldCF, false, string.format("Outpost_%s", uid))
	BuildingGeometry.ApplyTierVisuals(model, pieceType, "wood")
	model:SetAttribute("BuildUid", uid)
	model:SetAttribute("PieceType", pieceType)
	model:SetAttribute("Tier", "wood")
	model:SetAttribute("OwnerUserId", session.Raider.UserId)
	model:SetAttribute("IsRaidOutpostPiece", true)
	model.Parent = folder

	local record: RaiderPieceRecord = {
		Owner = session.Raider,
		Piece = piece,
		Model = model,
		CFrame = worldCF,
	}
	session.RaiderPieces[uid] = record
	BuildingValidator.RegisterOccupationsForRecord(
		(record :: any) :: BuildingValidator.LivePieceEntry,
		(session.RaiderPieces :: any) :: { [string]: BuildingValidator.LivePieceEntry },
		session.RaiderOccupiedSockets,
		session.RaiderOccupiedWorldKeys
	)
end

local function ensureArenaGround(session: RaidSession)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local hitOrigin = Workspace:Raycast(session.Origin + Vector3.new(0, 12, 0), Vector3.new(0, -30, 0), params)
	local hitOutpost = Workspace:Raycast(session.OutpostOrigin + Vector3.new(0, 12, 0), Vector3.new(0, -30, 0), params)
	if hitOrigin ~= nil and hitOutpost ~= nil then
		return
	end
	local ground = createPrimitivePart(
		Workspace,
		"Ground",
		Vector3.new(180, 2, 200),
		CFrame.new(session.Origin.X, session.Origin.Y - 1, session.Origin.Z + 18),
		Enum.Material.Grass,
		Color3.fromRGB(68, 94, 58),
		true
	)
	session.ArenaGroundPart = ground
end

local function spawnRaidOutpost(session: RaidSession)
	ensureArenaGround(session)

	local outpostOrigin = session.OutpostOrigin
	local radius = Config.Raid.OutpostRadius

	-- Zone volume for RaidOutpostZone detection
	local existingZone = Workspace:FindFirstChild("RaidOutpostZone")
	if existingZone ~= nil and existingZone:GetAttribute("IsDynamicRaidZone") == true then
		existingZone:Destroy()
	end
	local zoneModel = Instance.new("Model")
	zoneModel.Name = "RaidOutpostZone"
	zoneModel:SetAttribute("IsDynamicRaidZone", true)
	CollectionService:AddTag(zoneModel, "RaidOutpostZone")

	local zoneVolume = createPrimitivePart(
		zoneModel,
		"OutpostVolume",
		Vector3.new(radius * 2, 48, radius * 2),
		CFrame.new(outpostOrigin + Vector3.new(0, 22, 0)),
		Enum.Material.SmoothPlastic,
		Color3.fromRGB(55, 165, 225),
		false
	)
	zoneVolume.Transparency = 1
	zoneVolume.CanQuery = true
	zoneVolume.CanTouch = false

	local zonePad = createPrimitivePart(
		zoneModel,
		"OutpostPad",
		Vector3.new(radius * 2, 0.2, radius * 2),
		CFrame.new(outpostOrigin + Vector3.new(0, 0.1, 0)),
		Enum.Material.Neon,
		Color3.fromRGB(55, 165, 225),
		false
	)
	zonePad.Transparency = 0.84
	zonePad.CanQuery = false
	zonePad.CanTouch = false
	zoneModel.PrimaryPart = zoneVolume
	zoneModel.Parent = Workspace
	session.OutpostZoneModel = zoneModel

	local outpostFolder = getOrCreateFolder(RAID_OUTPOST_STRUCTURES_FOLDER_NAME)
	local baseCF = CFrame.new(outpostOrigin)
	spawnOutpostStructuralPiece(session, outpostFolder, "outpost_foundation", "foundation", baseCF, nil, nil)
	spawnOutpostStructuralPiece(
		session,
		outpostFolder,
		"outpost_wall_back",
		"wall",
		baseCF * CFrame.new(0, 1, 6),
		"outpost_foundation",
		"Edge_3"
	)
	spawnOutpostStructuralPiece(
		session,
		outpostFolder,
		"outpost_wall_left",
		"wall",
		baseCF * CFrame.new(-6, 1, 0) * CFrame.Angles(0, math.rad(90), 0),
		"outpost_foundation",
		"Edge_4"
	)
	spawnOutpostStructuralPiece(
		session,
		outpostFolder,
		"outpost_wall_right",
		"wall",
		baseCF * CFrame.new(6, 1, 0) * CFrame.Angles(0, math.rad(270), 0),
		"outpost_foundation",
		"Edge_2"
	)
	spawnOutpostStructuralPiece(
		session,
		outpostFolder,
		"outpost_doorway_front",
		"doorway",
		baseCF * CFrame.new(0, 1, -6) * CFrame.Angles(0, math.rad(180), 0),
		"outpost_foundation",
		"Edge_1"
	)
	spawnOutpostStructuralPiece(
		session,
		outpostFolder,
		"outpost_roof",
		"roof",
		baseCF * CFrame.new(0, 10.2, 0),
		"outpost_foundation",
		"Top"
	)

	-- Workbench inside shack
	nextOutpostSeq += 1
	local wbId = string.format("raid_outpost_wb_%d", nextOutpostSeq)
	local wbCF = baseCF * CFrame.new(-3.2, 1.0, -2.2) * CFrame.Angles(0, math.rad(90), 0)
	local wbModel = BuildingGeometry.CreateModel("workbench_1", wbCF, false, "OutpostWorkbench")
	BuildingGeometry.ApplyTierVisuals(wbModel, "workbench_1", "wood")
	wbModel:SetAttribute("BuildUid", "outpost_workbench")
	wbModel:SetAttribute("PieceType", "workbench_1")
	wbModel.Parent = outpostFolder
	session.RaiderPieces.outpost_workbench = {
		Owner = session.Raider,
		Piece = {
			Uid = "outpost_workbench",
			PieceType = "workbench_1",
			Tier = "wood",
			PosX = wbCF.Position.X,
			PosY = wbCF.Position.Y,
			PosZ = wbCF.Position.Z,
			RotY = 90,
			Hp = 200,
		},
		Model = wbModel,
		CFrame = wbCF,
	}
	CraftingService.RegisterStation(wbId, "workbench_1", wbCF.Position)
	session.OutpostWorkbenchId = wbId

	-- Respawn Pad (Sleeping Bag) inside shack
	local padModel = Instance.new("Model")
	padModel.Name = "OutpostRespawnPad"
	local mat = createPrimitivePart(
		padModel,
		"Mat",
		Vector3.new(3.2, 0.35, 5.2),
		baseCF * CFrame.new(-3.2, 1.18, 2.4),
		Enum.Material.Fabric,
		Color3.fromRGB(58, 125, 76),
		true
	)
	createPrimitivePart(
		padModel,
		"Pillow",
		Vector3.new(2.4, 0.4, 1.1),
		baseCF * CFrame.new(-3.2, 1.45, 4.1),
		Enum.Material.Fabric,
		Color3.fromRGB(220, 220, 210),
		true
	)
	padModel.PrimaryPart = mat
	padModel.Parent = outpostFolder
	session.RaiderPieces.outpost_respawn_pad = {
		Owner = session.Raider,
		Piece = {
			Uid = "outpost_respawn_pad",
			PieceType = "storage_box",
			Tier = "wood",
			PosX = mat.Position.X,
			PosY = mat.Position.Y,
			PosZ = mat.Position.Z,
			RotY = 0,
			Hp = 150,
		},
		Model = padModel,
		CFrame = mat.CFrame,
	}
	session.RespawnPosition = outpostOrigin + Vector3.new(-3.2, 4.2, 2.4)

	-- Extraction Stash crate inside shack
	local stashCF = baseCF * CFrame.new(3.2, 1.0, 2.5) * CFrame.Angles(0, math.rad(-90), 0)
	local stashModel = BuildingGeometry.CreateModel("storage_box", stashCF, false, "ExtractionStash")
	for _, desc in stashModel:GetDescendants() do
		if desc:IsA("BasePart") then
			desc.Material = Enum.Material.Metal
			desc.Color = if desc.Name == "ChestLid" then Color3.fromRGB(45, 145, 110) else Color3.fromRGB(52, 84, 78)
		end
	end
	stashModel.Parent = outpostFolder
	session.ExtractionStashModel = stashModel

	if stashModel.PrimaryPart then
		local stashGui = Instance.new("BillboardGui")
		stashGui.Size = UDim2.fromOffset(145, 28)
		stashGui.StudsOffset = Vector3.new(0, 2.6, 0)
		stashGui.AlwaysOnTop = true
		stashGui.MaxDistance = 40
		stashGui.Adornee = stashModel.PrimaryPart
		stashGui.Parent = stashModel.PrimaryPart
		local stashLbl = Instance.new("TextLabel")
		stashLbl.Size = UDim2.fromScale(1, 1)
		stashLbl.BackgroundColor3 = Color3.fromRGB(16, 42, 34)
		stashLbl.BackgroundTransparency = 0.2
		stashLbl.BorderSizePixel = 0
		stashLbl.Font = Enum.Font.GothamBold
		stashLbl.TextSize = 12
		stashLbl.TextColor3 = Color3.fromRGB(125, 245, 195)
		stashLbl.Text = "EXTRACTION STASH"
		stashLbl.Parent = stashGui
	end

	local stashId = LootService.RegisterStorageContainer(
		stashModel,
		"Extraction Stash",
		session.Raider.UserId,
		Config.Raid.ExtractionStashSlots,
		{},
		function()
			if activeSessions[session.Raider] == session then
				syncSessionHud(session, nil)
			end
		end,
		true
	)
	if #stashId > 0 then
		session.ExtractionStashContainerId = stashId
	end

	-- Extraction Terminal console inside shack
	local termModel = Instance.new("Model")
	termModel.Name = "ExtractionTerminal"
	local termBase = createPrimitivePart(
		termModel,
		"ConsoleBase",
		Vector3.new(2.2, 3.4, 1.6),
		baseCF * CFrame.new(3.5, 2.7, -3.0),
		Enum.Material.Metal,
		Color3.fromRGB(48, 54, 66),
		true
	)
	local screenPart = Instance.new("WedgePart")
	screenPart.Name = "ConsoleScreen"
	screenPart.Size = Vector3.new(2.0, 1.1, 1.2)
	screenPart.CFrame = baseCF * CFrame.new(3.5, 4.95, -2.9)
	screenPart.Anchored = true
	screenPart.CanCollide = true
	screenPart.Material = Enum.Material.SmoothPlastic
	screenPart.Color = Color3.fromRGB(28, 34, 42)
	screenPart.Parent = termModel

	local indicator = createPrimitivePart(
		termModel,
		"StatusLight",
		Vector3.new(1.8, 0.35, 0.35),
		baseCF * CFrame.new(3.5, 5.7, -3.0),
		Enum.Material.Neon,
		Color3.fromRGB(220, 140, 45),
		false
	)
	termModel.PrimaryPart = termBase
	termModel.Parent = outpostFolder
	session.ExtractionTerminalModel = termModel
	session.ExtractionTerminalIndicator = indicator

	local extractPrompt = Instance.new("ProximityPrompt")
	extractPrompt.Name = "ExtractPrompt"
	extractPrompt.ActionText = if session.TcCaptured then "Extract Loot (TC Captured)" else "Capture Enemy TC First"
	extractPrompt.ObjectText = "Extraction Terminal"
	extractPrompt.HoldDuration = 0.4
	extractPrompt.MaxActivationDistance = 10
	extractPrompt.RequiresLineOfSight = false
	extractPrompt.KeyboardKeyCode = Enum.KeyCode.E
	extractPrompt.Parent = termBase
	session.ExtractionTerminalPrompt = extractPrompt
	session.Janitor:Add(extractPrompt.Triggered:Connect(function(triggerPlayer: Player)
		if triggerPlayer == session.Raider then
			tryExtractFromRaid(triggerPlayer)
		end
	end))

	local abandonPrompt = Instance.new("ProximityPrompt")
	abandonPrompt.Name = "AbandonPrompt"
	abandonPrompt.ActionText = "Abandon Raid (Lose Stash)"
	abandonPrompt.ObjectText = "Extraction Terminal"
	abandonPrompt.HoldDuration = 1.5
	abandonPrompt.MaxActivationDistance = 10
	abandonPrompt.RequiresLineOfSight = false
	abandonPrompt.KeyboardKeyCode = Enum.KeyCode.F
	abandonPrompt.Parent = termBase
	session.Janitor:Add(abandonPrompt.Triggered:Connect(function(triggerPlayer: Player)
		if triggerPlayer == session.Raider then
			failRaidSession(triggerPlayer, "Raid abandoned — stash lost", false)
		end
	end))
end

local function bindRaiderCharacter(session: RaidSession, character: Model)
	if activeSessions[session.Raider] ~= session then
		return
	end
	if session.PendingReturnOnRespawn then
		session.PendingReturnOnRespawn = false
		task.defer(function()
			if activeSessions[session.Raider] == session then
				completeStudioReturn(session.Raider, session, "All raid lives lost — returned to PlayerBase")
			end
		end)
		return
	end

	local humanoidInst = character:WaitForChild("Humanoid", 5)
	if not humanoidInst or not humanoidInst:IsA("Humanoid") then
		return
	end
	local humanoid = humanoidInst :: Humanoid
	local prevHealth = humanoid.Health
	local diedHandled = false

	session.Janitor:Add(humanoid.HealthChanged:Connect(function(newHp: number)
		if activeSessions[session.Raider] ~= session then
			return
		end
		if newHp < prevHealth - 0.1 then
			session.LastDamagedAt = os.clock()
			cancelTcHack(session, "Взлом TC прерван: получен урон")
		end
		prevHealth = newHp
	end))

	session.Janitor:Add(humanoid.Died:Connect(function()
		if diedHandled or activeSessions[session.Raider] ~= session or session.Extracting then
			return
		end
		diedHandled = true
		cancelTcHack(session, nil)
		session.LivesLeft = math.max(0, session.LivesLeft - 1)
		if session.LivesLeft > 0 then
			local msg = string.format(
				"Погиб! Возрождение в кибитке (жизней: %d/%d)",
				session.LivesLeft,
				session.MaxLives
			)
			sendBuildFeedback(session.Raider, false, msg)
			syncSessionHud(session, msg)
		else
			failRaidSession(
				session.Raider,
				"Потрачены все жизни — лут в ExtractionStash сгорел",
				true
			)
		end
	end))
end

local function bindRaiderLifecycle(session: RaidSession)
	local player = session.Raider
	if player.Character ~= nil then
		task.spawn(bindRaiderCharacter, session, player.Character)
	end
	session.Janitor:Add(player.CharacterAdded:Connect(function(newChar: Model)
		if activeSessions[player] ~= session then
			return
		end
		task.spawn(bindRaiderCharacter, session, newChar)
		if not session.Extracting and session.LivesLeft > 0 then
			task.delay(0.15, function()
				if activeSessions[player] == session and not session.Extracting and player.Character == newChar then
					teleportCharacterToPosition(player, session.RespawnPosition)
					syncSessionHud(session, "Возрождение в рейд-кибитке")
				end
			end)
		end
	end))
end

local function startSessionTimerLoop(session: RaidSession)
	task.spawn(function()
		while activeSessions[session.Raider] == session and session.Raider.Parent == Players do
			if session.Extracting then
				break
			end
			local elapsed = os.clock() - session.StartTime
			syncSessionHud(session, nil)
			if elapsed >= session.Duration then
				failRaidSession(session.Raider, "Raid timer expired — Extraction Stash lost!", false)
				break
			end
			task.wait(1)
		end
	end)
end

local function createExplosiveVisual(position: Vector3, itemId: string): (Part, TextLabel)
	local folder = getOrCreateFolder(RAID_STRUCTURES_FOLDER_NAME)

	local part = Instance.new("Part")
	part.Name = string.format("ArmedExplosive_%s", itemId)
	part.Size = if itemId == "c4_charge" then Vector3.new(1.1, 0.5, 0.8) else Vector3.new(1.0, 0.7, 1.0)
	part.Position = position
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.Material = Enum.Material.Metal
	part.Color = if itemId == "c4_charge" then Color3.fromRGB(205, 50, 50) else Color3.fromRGB(160, 110, 55)
	part.Parent = folder

	local gui = Instance.new("BillboardGui")
	gui.Name = "FuseTimerGui"
	gui.Size = UDim2.fromOffset(110, 32)
	gui.StudsOffset = Vector3.new(0, 1.8, 0)
	gui.AlwaysOnTop = true
	gui.MaxDistance = 60
	gui.Adornee = part
	gui.Parent = part

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundColor3 = Color3.fromRGB(28, 12, 12)
	label.BackgroundTransparency = 0.2
	label.BorderSizePixel = 0
	label.Font = Enum.Font.GothamBold
	label.TextSize = 14
	label.TextColor3 = Color3.fromRGB(255, 110, 90)
	label.Text = ""
	label.Parent = gui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 5)
	corner.Parent = label

	return part, label
end

local function findHumanoidCharacter(inst: Instance): (Model?, Humanoid?)
	local current: Instance? = inst
	while current ~= nil and current ~= Workspace do
		if current:IsA("Model") then
			local humanoid = current:FindFirstChildOfClass("Humanoid")
			if humanoid ~= nil then
				return current, humanoid
			end
		end
		current = current.Parent
	end
	return nil, nil
end

local function getTargetControlPoints(targetModel: Model, isCharacterTarget: boolean): { Vector3 }
	local points: { Vector3 } = {}
	if isCharacterTarget then
		local hrp = targetModel:FindFirstChild("HumanoidRootPart")
		local head = targetModel:FindFirstChild("Head")
		if hrp and hrp:IsA("BasePart") then
			table.insert(points, hrp.Position)
			if head and head:IsA("BasePart") then
				table.insert(points, head.Position)
			end
			table.insert(points, hrp.Position - Vector3.new(0, 2.0, 0))
			return points
		end
	else
		local pieceAttr = targetModel:GetAttribute("PieceType")
		if pieceAttr == "doorway" then
			for _, partName in { "LeftPillar", "RightPillar", "TopLintel" } do
				local part = targetModel:FindFirstChild(partName)
				if part and part:IsA("BasePart") then
					table.insert(points, part.Position)
				end
			end
			if #points > 0 then
				return points
			end
		elseif pieceAttr == "window_wall" or pieceAttr == "WindowWall" then
			for _, partName in { "LeftPillar", "RightPillar", "BottomSill", "TopHeader" } do
				local part = targetModel:FindFirstChild(partName)
				if part and part:IsA("BasePart") then
					table.insert(points, part.Position)
				end
			end
			if #points > 0 then
				return points
			end
		end
	end

	local cf, size = targetModel:GetBoundingBox()
	if size.Y >= 3.0 then
		table.insert(points, cf.Position)
		table.insert(points, cf.Position + cf.UpVector * (size.Y * 0.35))
		table.insert(points, cf.Position - cf.UpVector * (size.Y * 0.35))
	elseif math.max(size.X, size.Z) >= 6.0 then
		table.insert(points, cf.Position)
		table.insert(points, cf.Position + cf.RightVector * (size.X * 0.3))
		table.insert(points, cf.Position - cf.RightVector * (size.X * 0.3))
	else
		table.insert(points, cf.Position)
		table.insert(points, cf.Position + Vector3.new(0, size.Y * 0.3, 0))
		table.insert(points, cf.Position - Vector3.new(0, size.Y * 0.3, 0))
	end

	return points
end

local function computeBlastFalloff(distance: number, radius: number, minMultiplier: number): number
	if distance <= 1.0 then
		return 1.0
	end
	local t = math.clamp((distance - 1.0) / math.max(0.01, radius - 1.0), 0, 1)
	local clampedMin = math.clamp(minMultiplier, 0, 1)
	return 1.0 - t * (1.0 - clampedMin)
end

local function broadcastExplosionEffect(
	origin: Vector3,
	radius: number,
	sourceId: string,
	projectileId: string?,
	attacker: Player?
)
	local effectEvent = Net.GetEvent(Net.Events.ExplosionEffect)
	for _, other in Players:GetPlayers() do
		if other == attacker then
			effectEvent:FireClient(other, origin, radius, sourceId, projectileId)
			continue
		end
		local char = other.Character
		local hrp = if char then char:FindFirstChild("HumanoidRootPart") else nil
		if hrp and hrp:IsA("BasePart") and (hrp.Position - origin).Magnitude <= EXPLOSION_EFFECT_BROADCAST_RADIUS then
			effectEvent:FireClient(other, origin, radius, sourceId, projectileId)
		end
	end
end

function RaidService.HasExplosionLineOfSight(
	blastOrigin: Vector3,
	targetModel: Model,
	excludeInstances: { Instance }?,
	isCharacterTarget: boolean?
): boolean
	local controlPoints = getTargetControlPoints(targetModel, isCharacterTarget == true)

	for _, targetPoint in controlPoints do
		local delta = targetPoint - blastOrigin
		if delta.Magnitude <= 0.1 then
			return true
		end

		local excludeList: { Instance } = { targetModel }
		if excludeInstances ~= nil then
			for _, inst in excludeInstances do
				table.insert(excludeList, inst)
			end
		end

		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.IgnoreWater = true
		params.FilterDescendantsInstances = excludeList

		local blocked = false
		for _ = 1, MAX_OCCLUSION_RAY_PASSES do
			local result = Workspace:Raycast(blastOrigin, delta, params)
			if result == nil then
				return true
			end

			if result.Instance:IsDescendantOf(targetModel) then
				return true
			end

			if result.Instance.CanCollide == false and not result.Instance:IsA("Terrain") then
				table.insert(excludeList, result.Instance)
				params.FilterDescendantsInstances = excludeList
				continue
			end

			local hitChar = findHumanoidCharacter(result.Instance)
			if hitChar ~= nil then
				table.insert(excludeList, hitChar)
				params.FilterDescendantsInstances = excludeList
				continue
			end

			blocked = true
			break
		end

		if not blocked then
			return true
		end
	end

	return false
end

function RaidService.TriggerExplosion(params: ExplosionParams): ExplosionResult
	local summary: ExplosionResult = {
		DamagedStructures = 0,
		DestroyedStructures = 0,
		DamagedHumanoids = 0,
		OccludedStructures = 0,
		OccludedHumanoids = 0,
	}

	if not SecurityService.IsValidVector3(params.Origin) then
		return summary
	end
	if not SecurityService.IsFiniteNumber(params.Radius) or params.Radius <= 0 then
		return summary
	end

	local origin = params.Origin
	local radius = params.Radius
	local minMult = params.MinFalloffMultiplier or DEFAULT_MIN_FALLOFF_MULTIPLIER

	local baseExcludes: { Instance } = {}
	if params.ExcludeInstances ~= nil then
		for _, inst in params.ExcludeInstances do
			table.insert(baseExcludes, inst)
		end
	end

	-- Phase 1: Collect targets & evaluate Line-of-Sight BEFORE modifying/destroying walls
	local pendingStructureHits: { { Session: RaidSession, Record: RaidPieceRecord, Damage: number } } = {}
	local pendingBaseHits: { { Uid: string, Damage: number } } = {}
	if params.StructureDamage > 0 then
		for _, session in activeSessions do
			for _, record in session.Pieces do
				if record.Model.Parent ~= nil then
					local closest = closestPointOnModel(record.Model, origin)
					local dist = (closest - origin).Magnitude
					if dist <= radius then
						if RaidService.HasExplosionLineOfSight(origin, record.Model, baseExcludes, false) then
							local falloff = computeBlastFalloff(dist, radius, minMult)
							local tierCfg = BuildingConfig.Tiers[record.Piece.Tier] or BuildingConfig.Tiers.wood
							local resistMult = math.max(0.05, 1.0 - tierCfg.ExplosionResistance)
							local damage = math.floor(params.StructureDamage * falloff * resistMult + 0.5)
							if damage > 0 then
								table.insert(pendingStructureHits, {
									Session = session,
									Record = record,
									Damage = damage,
								})
							end
						else
							summary.OccludedStructures += 1
						end
					end
				end
			end
		end

		for _, liveItem in BaseService.GetLivePieceModelsInRadius(origin, radius) do
			if liveItem.Model.Parent ~= nil then
				local closest = closestPointOnModel(liveItem.Model, origin)
				local dist = (closest - origin).Magnitude
				if dist <= radius then
					if RaidService.HasExplosionLineOfSight(origin, liveItem.Model, baseExcludes, false) then
						local falloff = computeBlastFalloff(dist, radius, minMult)
						local rawDamage = math.floor(params.StructureDamage * falloff + 0.5)
						if rawDamage > 0 then
							table.insert(pendingBaseHits, {
								Uid = liveItem.Uid,
								Damage = rawDamage,
							})
						end
					else
						summary.OccludedStructures += 1
					end
				end
			end
		end
	end

	local pendingHumanoidHits: { { Model: Model, Humanoid: Humanoid, Damage: number } } = {}
	if params.PlayerDamage > 0 then
		local checkedModels: { [Model]: boolean } = {}
		local candidateModels: { Model } = {}

		for _, plr in Players:GetPlayers() do
			local char = plr.Character
			if char ~= nil then
				table.insert(candidateModels, char)
			end
		end

		local dummiesFolder = Workspace:FindFirstChild("TestDummies")
		if dummiesFolder ~= nil then
			for _, child in dummiesFolder:GetChildren() do
				if child:IsA("Model") then
					table.insert(candidateModels, child)
				end
			end
		end

		for _, charModel in candidateModels do
			if checkedModels[charModel] or charModel.Parent == nil then
				continue
			end
			checkedModels[charModel] = true

			local humanoid = charModel:FindFirstChildOfClass("Humanoid")
			local hrp = charModel:FindFirstChild("HumanoidRootPart")
			if
				humanoid == nil
				or not SecurityService.IsFiniteNumber(humanoid.Health)
				or humanoid.Health <= 0
				or hrp == nil
				or not hrp:IsA("BasePart")
			then
				continue
			end

			local hrpDist = (hrp.Position - origin).Magnitude
			local closestDist = (closestPointOnModel(charModel, origin) - origin).Magnitude
			local dist = math.min(hrpDist, closestDist)
			if dist <= radius then
				if RaidService.HasExplosionLineOfSight(origin, charModel, baseExcludes, true) then
					local falloff = computeBlastFalloff(dist, radius, minMult)
					local damage = params.PlayerDamage * falloff
					if damage > 0 then
						table.insert(pendingHumanoidHits, {
							Model = charModel,
							Humanoid = humanoid,
							Damage = damage,
						})
					end
				else
					summary.OccludedHumanoids += 1
				end
			end
		end
	end

	-- Phase 2: Apply structure and humanoid damage
	local nowClock = os.clock()
	for _, hit in pendingStructureHits do
		local record = hit.Record
		if hit.Session.Pieces[record.Piece.Uid] == record and record.Model.Parent ~= nil then
			record.Piece.Hp -= hit.Damage
			record.Piece.LastDamagedAt = nowClock
			record.Model:SetAttribute("LastDamagedAt", nowClock)
			summary.DamagedStructures += 1
			if record.Piece.Hp <= 0 then
				destroyRaidPiece(hit.Session, record.Piece.Uid, true)
				summary.DestroyedStructures += 1
			else
				record.Model:SetAttribute("Health", record.Piece.Hp)
				record.Model:SetAttribute("Hp", record.Piece.Hp)
				DefenseService.UpdateDefenseHp(record.Piece.Uid, record.Piece.Hp, nil)
				updatePieceDamageBillboard(record)
			end
		end
	end

	for _, hit in pendingBaseHits do
		local damaged, destroyed = BaseService.DamagePiece(hit.Uid, hit.Damage, "Explosion", params.Attacker)
		if damaged then
			summary.DamagedStructures += 1
		end
		if destroyed then
			summary.DestroyedStructures += 1
		end
	end

	for _, hit in pendingHumanoidHits do
		if hit.Model.Parent ~= nil and hit.Humanoid.Health > 0 then
			if params.Attacker ~= nil and params.Attacker.Parent == Players then
				hit.Model:SetAttribute("LastAttackerUserId", params.Attacker.UserId)
			end
			hit.Humanoid:TakeDamage(hit.Damage)
			local hitPlayer = Players:GetPlayerFromCharacter(hit.Model)
			if hitPlayer ~= nil then
				RaidService.NotifyRaiderDamaged(hitPlayer)
			end
			summary.DamagedHumanoids += 1
		end
	end

	-- Phase 3: Replicate VFX & audio to clients
	broadcastExplosionEffect(origin, radius, params.SourceId or "explosion", params.ProjectileId, params.Attacker)

	return summary
end

function RaidService.NotifyRaiderDamaged(player: Player)
	local session = activeSessions[player]
	if session == nil then
		return
	end
	session.LastDamagedAt = os.clock()
	cancelTcHack(session, "Взлом TC прерван: получен урон")
end

function RaidService.DamageRaidPiece(
	uid: string,
	rawDamage: number,
	damageKind: string,
	_attacker: Player?
): (boolean, boolean)
	if not SecurityService.IsFiniteNumber(rawDamage) or rawDamage <= 0 then
		return false, false
	end

	for _, session in activeSessions do
		local record = session.Pieces[uid]
		if record ~= nil and record.Model.Parent ~= nil then
			local tierCfg = BuildingConfig.Tiers[record.Piece.Tier] or BuildingConfig.Tiers.wood
			local mult = if damageKind == "Explosion"
				then math.max(0.05, 1.0 - tierCfg.ExplosionResistance)
				else tierCfg.ToolDamageMultiplier
			local finalDamage = math.max(1, math.floor(rawDamage * mult + 0.5))
			local nowClock = os.clock()
			record.Piece.Hp -= finalDamage
			record.Piece.LastDamagedAt = nowClock
			record.Model:SetAttribute("LastDamagedAt", nowClock)
			if record.Piece.Hp <= 0 then
				destroyRaidPiece(session, uid, true)
				return true, true
			else
				record.Model:SetAttribute("Health", record.Piece.Hp)
				record.Model:SetAttribute("Hp", record.Piece.Hp)
				DefenseService.UpdateDefenseHp(uid, record.Piece.Hp, nil)
				updatePieceDamageBillboard(record)
				return true, false
			end
		end
	end

	return false, false
end

local function detonateExplosive(
	session: RaidSession,
	explosiveRecord: ActiveExplosiveRecord,
	blastOrigin: Vector3,
	itemId: string
)
	if explosiveRecord.CancelFlag or activeSessions[session.Raider] ~= session then
		return
	end

	local cfg = Explosives[itemId]
	if cfg == nil then
		return
	end

	local excludePart: { Instance } = {}
	if explosiveRecord.Part.Parent then
		table.insert(excludePart, explosiveRecord.Part)
		explosiveRecord.Part:Destroy()
	end

	local idx = table.find(session.ActiveExplosives, explosiveRecord)
	if idx ~= nil then
		table.remove(session.ActiveExplosives, idx)
	end

	RaidService.TriggerExplosion({
		Origin = blastOrigin,
		Radius = cfg.Radius,
		StructureDamage = cfg.StructureDamage,
		PlayerDamage = cfg.PlayerDamage,
		Attacker = session.Raider,
		SourceId = itemId,
		ExcludeInstances = excludePart,
	})
end

local function canUseRaidTerminal(player: Player): boolean
	if Workspace:GetAttribute("RaidServerMode") == true or activeSessions[player] ~= nil then
		return false
	end
	if RunService:IsStudio() then
		return true
	end
	return game.PlaceId == Config.Places.PlayerBase or game.PlaceId == Config.Places.MainMap
end

local function formatCostRequirementText(costMap: { [string]: number }): string
	local parts: { string } = {}
	for itemId, amount in costMap do
		if amount > 0 then
			local itemCfg = Items[itemId]
			table.insert(parts, string.format("%d %s", amount, if itemCfg ~= nil then itemCfg.Name else itemId))
		end
	end
	table.sort(parts)
	return table.concat(parts, ", ")
end

local function onRaidListRequest(player: Player)
	if not SecurityService.CheckRateLimit(player, Net.Events.RaidListRequest) then
		return
	end
	if not canUseRaidTerminal(player) then
		return
	end
	if DataService.IsTeleporting(player) or SecurityService.IsTransactionLocked(player) then
		return
	end
	if DataService.GetData(player) == nil then
		return
	end
	local _, hrp = getAliveCharacterParts(player)
	if hrp == nil or not isNearRaidTerminal(hrp) then
		return
	end

	local now = os.clock()
	local prev = lastListRequest[player]
	if prev ~= nil and (now - prev) < LIST_COOLDOWN then
		return
	end
	lastListRequest[player] = now

	local targets = DataService.GetRaidTargets(player.UserId, 12)
	if player.Parent == Players then
		Net.GetEvent(Net.Events.RaidListSync):FireClient(player, targets)
	end
end

local function resolveTargetTier(targetUserId: number): number
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

local function onStartRaidRequest(player: Player, targetUserIdAny: any)
	if not SecurityService.CheckRateLimit(player, Net.Events.StartRaidRequest) then
		return
	end
	if not canUseRaidTerminal(player) then
		return
	end
	if activeSessions[player] ~= nil or teleportInProgress[player] or SecurityService.IsTeleportLocked(player) then
		return
	end
	if DataService.GetData(player) == nil then
		return
	end
	if not SecurityService.IsValidInteger(targetUserIdAny) then
		return
	end

	local _, hrp = getAliveCharacterParts(player)
	if hrp == nil or not isNearRaidTerminal(hrp) then
		return
	end

	local targetUserId = math.floor(targetUserIdAny :: number)
	if targetUserId == player.UserId then
		return
	end
	local presetTier = DataService.GetPresetTier(targetUserId)
	if targetUserId <= 0 and presetTier == nil then
		return
	end

	local targetName = resolveTargetName(targetUserId)
	local targetBaseTier = resolveTargetTier(targetUserId)
	local attackerBaseTier = BaseService.GetPlayerBaseTier(player)
	if attackerBaseTier < targetBaseTier then
		local msg = string.format(
			"Для рейда на базу Tier %d требуется собственная база Tier %d (сейчас Tier %d)",
			targetBaseTier,
			targetBaseTier,
			attackerBaseTier
		)
		Net.GetEvent(Net.Events.BuildFeedback):FireClient(player, {
			Success = false,
			Message = msg,
			BaseTier = attackerBaseTier,
		})
		sendRaidHud(player, {
			Active = false,
			TargetName = targetName,
			TargetBaseTier = targetBaseTier,
			TimeLeft = 0,
			StatusText = msg,
		})
		return
	end

	local tierCfg = Config.Raid.Tiers[targetBaseTier]
	local launchCostMap = if tierCfg ~= nil then tierCfg.LaunchCost else {}
	local launchCostBatch = costMapToBatch(launchCostMap)
	local paidLaunchCost = false

	SecurityService.RunLocked(player, "StartRaid", function()
		if activeSessions[player] ~= nil or teleportInProgress[player] or DataService.GetData(player) == nil then
			return
		end
		if #launchCostBatch > 0 then
			if not InventoryService.HasItems(player, launchCostBatch) then
				local reqText = formatCostRequirementText(launchCostMap)
				local msg = string.format(
					"Недостаточно ресурсов для запуска рейда Tier %d (%s)",
					targetBaseTier,
					reqText
				)
				sendBuildFeedback(player, false, msg)
				sendRaidHud(player, {
					Active = false,
					TargetName = targetName,
					TargetBaseTier = targetBaseTier,
					TimeLeft = 0,
					StatusText = msg,
				})
				return
			end
			if not InventoryService.RemoveItems(player, launchCostBatch) then
				sendBuildFeedback(
					player,
					false,
					"Не удалось списать стоимость запуска рейда"
				)
				return
			end
		end
		paidLaunchCost = true
	end)

	if not paidLaunchCost then
		return
	end

	teleportInProgress[player] = true
	SecurityService.SetTeleportLock(player, true)
	LootService.CloseContainerForPlayer(player, true)

	if RunService:IsStudio() then
		local released = DataService.ReleaseForTeleport(player)
		print(
			string.format(
				"[RaidService] Studio ReservedServer simulation: ReserveServer(PlaceId=%d) & TeleportToPrivateServer for TargetUserId=%d Tier=%d (ProfileReleased=%s)",
				Config.Places.PlayerBase,
				targetUserId,
				targetBaseTier,
				tostring(released)
			)
		)
		DataService.RestoreAfterFailedTeleport(player)
		teleportInProgress[player] = nil
		SecurityService.SetTeleportLock(player, false)

		if player.Parent == Players and DataService.GetData(player) ~= nil then
			local entered = RaidService.EnterStudioMockRaid(player, targetUserId)
			if not entered and #launchCostBatch > 0 then
				InventoryService.AddItems(player, launchCostBatch)
			end
		elseif #launchCostBatch > 0 then
			InventoryService.AddItems(player, launchCostBatch)
		end
		return
	end

	task.spawn(function()
		sendRaidHud(player, {
			Active = true,
			TargetName = targetName,
			TargetBaseTier = targetBaseTier,
			TimeLeft = RAID_DURATION,
			StatusText = "Reserving raid server...",
		})

		local released = DataService.ReleaseForTeleport(player)
		if not released then
			warn(string.format("[RaidService] Failed to release profile before raid for %s", player.Name))
			DataService.RestoreAfterFailedTeleport(player)
			if #launchCostBatch > 0 then
				InventoryService.AddItems(player, launchCostBatch)
			end
			teleportInProgress[player] = nil
			SecurityService.SetTeleportLock(player, false)
			sendRaidHud(player, {
				Active = false,
				TargetName = targetName,
				TargetBaseTier = targetBaseTier,
				TimeLeft = 0,
				StatusText = "Raid failed: save timeout",
			})
			return
		end

		if player.Parent ~= Players then
			teleportInProgress[player] = nil
			SecurityService.SetTeleportLock(player, false)
			return
		end

		local okReserve, accessCode = pcall(function()
			return TeleportService:ReserveServer(Config.Places.PlayerBase)
		end)
		if not okReserve or type(accessCode) ~= "string" or #accessCode == 0 then
			warn(string.format("[RaidService] ReserveServer failed for %s: %s", player.Name, tostring(accessCode)))
			DataService.RestoreAfterFailedTeleport(player)
			if #launchCostBatch > 0 then
				InventoryService.AddItems(player, launchCostBatch)
			end
			teleportInProgress[player] = nil
			SecurityService.SetTeleportLock(player, false)
			sendRaidHud(player, {
				Active = false,
				TargetName = targetName,
				TargetBaseTier = targetBaseTier,
				TimeLeft = 0,
				StatusText = "Raid failed: server reservation error",
			})
			return
		end

		local teleportData = {
			Mode = "Raid",
			TargetUserId = targetUserId,
			TargetBaseTier = targetBaseTier,
			RaiderUserId = player.UserId,
			TargetName = targetName,
		}
		local options = Instance.new("TeleportOptions")
		options.ReservedServerAccessCode = accessCode
		options:SetTeleportData(teleportData)

		pendingTeleports[player] = {
			TargetPlaceId = Config.Places.PlayerBase,
			Options = options,
			IsReturningToMap = false,
			TargetName = targetName,
			LaunchCostBatch = launchCostBatch,
		}

		local okTp, errTp = pcall(function()
			TeleportService:TeleportAsync(Config.Places.PlayerBase, { player }, options)
		end)
		if not okTp then
			warn(string.format("[RaidService] TeleportAsync failed for %s: %s", player.Name, tostring(errTp)))
			pendingTeleports[player] = nil
			teleportInProgress[player] = nil
			SecurityService.SetTeleportLock(player, false)
			DataService.RestoreAfterFailedTeleport(player)
			if #launchCostBatch > 0 then
				InventoryService.AddItems(player, launchCostBatch)
			end
			sendRaidHud(player, {
				Active = false,
				TargetName = targetName,
				TargetBaseTier = targetBaseTier,
				TimeLeft = 0,
				StatusText = "Raid failed: teleport error",
			})
		end
	end)
end

local function onRaidBuildPlaceRequest(
	player: Player,
	pieceTypeAny: any,
	targetCFrameAny: any,
	parentUidAny: any,
	socketIdAny: any,
	rotStepAny: any
)
	local session = activeSessions[player]
	if session == nil or session.Extracting then
		return
	end
	if not SecurityService.CheckRateLimit(player, Net.Events.BuildPlaceRequest) then
		return
	end
	if DataService.IsTeleporting(player) or SecurityService.IsTransactionLocked(player) then
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

	SecurityService.RunLocked(player, "RaidBuildPlace", function()
		if activeSessions[player] ~= session or session.Extracting or DataService.GetData(player) == nil then
			return
		end
		local character, hrp = SecurityService.GetAliveCharacterRoot(player)
		if hrp == nil then
			return
		end

		local basePieces: { SavedBuildPiece } = {}
		for _, rec in session.RaiderPieces do
			table.insert(basePieces, rec.Piece)
		end

		local validation = BuildingValidator.ValidatePlacement({
			Player = player,
			Character = character,
			HrpPosition = hrp.Position,
			PieceType = pieceType,
			RequestedCFrame = requestedCF,
			ParentUid = parentUid,
			SocketId = socketId,
			ExplicitRotStep = explicitRotStep,
			PlayerRecords = (session.RaiderPieces :: any) :: { [string]: BuildingValidator.LivePieceEntry },
			AllRecordsByUid = (session.RaiderPieces :: any) :: { [string]: BuildingValidator.LivePieceEntry },
			OccupiedSockets = session.RaiderOccupiedSockets,
			OccupiedWorldKeys = session.RaiderOccupiedWorldKeys,
			BasePieces = basePieces,
			PlayerBaseTier = BaseService.GetPlayerBaseTier(player),
			IsRaidMode = true,
		})

		if not validation.Allowed or validation.AuthoritativeCFrame == nil then
			sendBuildFeedback(
				player,
				false,
				validation.Reason or "Нельзя установить объект здесь"
			)
			return
		end

		local costBatch = costMapToBatch(pieceConfig.Cost)
		if #costBatch > 0 and not InventoryService.RemoveItems(player, costBatch) then
			sendBuildFeedback(player, false, "Недостаточно ресурсов")
			return
		end

		local authCF = validation.AuthoritativeCFrame
		local uid = HttpService:GenerateGUID(false)
		local rotY = validation.RotY or BuildingGeometry.QuantizeYaw30(BuildingGeometry.ExtractYawDegrees(authCF))
		local maxHp = BuildingGeometry.ComputeMaxHp(pieceType, "wood")

		local newPiece: SavedBuildPiece = {
			Uid = uid,
			PieceType = pieceType,
			Tier = "wood",
			PosX = authCF.Position.X,
			PosY = authCF.Position.Y,
			PosZ = authCF.Position.Z,
			RotY = rotY,
			ParentUid = validation.ResolvedParentUid,
			AnchorUid = validation.ResolvedParentUid,
			SocketId = validation.ResolvedSocketId,
			Hp = maxHp,
			LastDamagedAt = 0,
		}

		local outpostFolder = getOrCreateFolder(RAID_OUTPOST_STRUCTURES_FOLDER_NAME)
		local model = BuildingGeometry.CreateModel(
			pieceType,
			authCF,
			false,
			string.format("RaidOutpost_%s_%s", pieceType, string.sub(uid, 1, 8))
		)
		BuildingGeometry.ApplyTierVisuals(model, pieceType, "wood")
		model:SetAttribute("BuildUid", uid)
		model:SetAttribute("PieceType", pieceType)
		model:SetAttribute("Tier", "wood")
		model:SetAttribute("OwnerUserId", player.UserId)
		model:SetAttribute("Health", maxHp)
		model:SetAttribute("MaxHealth", maxHp)
		model:SetAttribute("IsRaidOutpostPiece", true)
		model.Parent = outpostFolder

		local record: RaiderPieceRecord = {
			Owner = player,
			Piece = newPiece,
			Model = model,
			CFrame = authCF,
		}
		session.RaiderPieces[uid] = record
		BuildingValidator.RegisterOccupationsForRecord(
			(record :: any) :: BuildingValidator.LivePieceEntry,
			(session.RaiderPieces :: any) :: { [string]: BuildingValidator.LivePieceEntry },
			session.RaiderOccupiedSockets,
			session.RaiderOccupiedWorldKeys
		)
	end)
end

local function onPlaceExplosiveRequest(player: Player, targetUidAny: any, hitPositionAny: any)
	if not SecurityService.CheckRateLimit(player, Net.Events.PlaceExplosiveRequest) then
		return
	end
	local session = activeSessions[player]
	if session == nil or session.Extracting then
		return
	end
	if DataService.IsTeleporting(player) or SecurityService.IsTransactionLocked(player) then
		return
	end
	if DataService.GetData(player) == nil then
		return
	end
	if not SecurityService.IsValidString(targetUidAny, 1, 64) then
		return
	end
	if not SecurityService.IsValidVector3(hitPositionAny) then
		return
	end

	local targetUid = targetUidAny :: string
	local targetRecord = session.Pieces[targetUid]
	if targetRecord == nil or not targetRecord.Model.Parent then
		return
	end

	local _, hrp, _ = getAliveCharacterParts(player)
	if hrp == nil then
		return
	end

	local hitPosition = hitPositionAny :: Vector3
	local clampedPos = closestPointOnModel(targetRecord.Model, hitPosition)
	if (hitPosition - clampedPos).Magnitude > MAX_HIT_SURFACE_OFFSET then
		return
	end
	if (hrp.Position - clampedPos).Magnitude > Types.MAX_EXPLOSIVE_PLACE_DISTANCE + Types.PING_DISTANCE_TOLERANCE then
		return
	end

	SecurityService.RunLocked(player, "PlaceExplosive", function()
		if
			activeSessions[player] ~= session
			or session.Extracting
			or DataService.GetData(player) == nil
			or session.Pieces[targetUid] ~= targetRecord
			or not targetRecord.Model.Parent
		then
			return
		end

		local _, innerHrp, _ = getAliveCharacterParts(player)
		if innerHrp == nil then
			return
		end
		if
			(innerHrp.Position - clampedPos).Magnitude
			> Types.MAX_EXPLOSIVE_PLACE_DISTANCE + Types.PING_DISTANCE_TOLERANCE
		then
			return
		end

		local now = os.clock()
		local prevPlace = lastExplosivePlaceTime[player]
		if prevPlace ~= nil and (now - prevPlace) < EXPLOSIVE_PLACE_COOLDOWN then
			return
		end

		local equippedSlot = InventoryService.GetEquippedSlot(player)
		local slotData = InventoryService.GetSlot(player, equippedSlot)
		if slotData == nil or slotData.Count <= 0 then
			return
		end

		local explosiveCfg = Explosives[slotData.Id]
		if explosiveCfg == nil then
			return
		end

		local explosiveId = slotData.Id
		if not InventoryService.ConsumeSlot(player, equippedSlot, 1) then
			return
		end
		lastExplosivePlaceTime[player] = now

		local toPlayer = innerHrp.Position - clampedPos
		local nudge = if toPlayer.Magnitude > 0.05 then toPlayer.Unit * 0.3 else Vector3.new(0, 0.3, 0)
		local blastOrigin = clampedPos + nudge

		local visualPart, timerLabel = createExplosiveVisual(blastOrigin, explosiveId)
		local explosiveRecord: ActiveExplosiveRecord = {
			Part = visualPart,
			Label = timerLabel,
			CancelFlag = false,
		}
		table.insert(session.ActiveExplosives, explosiveRecord)

		task.spawn(function()
			local detonateAt = os.clock() + explosiveCfg.FuseTime
			while not explosiveRecord.CancelFlag and activeSessions[player] == session do
				local remaining = detonateAt - os.clock()
				if remaining <= 0 then
					break
				end
				if explosiveRecord.Label and explosiveRecord.Label.Parent then
					explosiveRecord.Label.Text = string.format("%.1fs", remaining)
				end
				task.wait(0.1)
			end

			if not explosiveRecord.CancelFlag and activeSessions[player] == session then
				detonateExplosive(session, explosiveRecord, blastOrigin, explosiveId)
			elseif explosiveRecord.Part.Parent then
				explosiveRecord.Part:Destroy()
			end
		end)
	end)
end

local function onRaidExtractRequest(player: Player)
	if not SecurityService.CheckRateLimit(player, Net.Events.RaidExtractRequest) then
		return
	end
	tryExtractFromRaid(player)
end

local function onRaidTcHackRequest(player: Player)
	if not SecurityService.CheckRateLimit(player, Net.Events.RaidTcHackRequest) then
		return
	end
	local session = activeSessions[player]
	if session == nil or session.Extracting then
		return
	end
	startTcHack(session)
end

local function onRaidAbandonRequest(player: Player)
	if not SecurityService.CheckRateLimit(player, Net.Events.RaidAbandonRequest) then
		return
	end
	local session = activeSessions[player]
	if session == nil or session.Extracting then
		return
	end
	failRaidSession(player, "Raid abandoned — Extraction Stash lost", false)
end

local function onTeleportInitFailed(
	player: Player,
	teleportResult: Enum.TeleportResult,
	errorMessage: string,
	_placeId: number,
	_teleportOptions: TeleportOptions
)
	local pending = pendingTeleports[player]
	if pending == nil then
		return
	end
	pendingTeleports[player] = nil
	teleportInProgress[player] = nil
	SecurityService.SetTeleportLock(player, false)
	warn(
		string.format(
			"[RaidService] TeleportInitFailed for %s (%s): %s",
			player.Name,
			tostring(teleportResult),
			errorMessage
		)
	)
	DataService.RestoreAfterFailedTeleport(player)
	if not pending.IsReturningToMap and pending.LaunchCostBatch ~= nil and #pending.LaunchCostBatch > 0 then
		InventoryService.AddItems(player, pending.LaunchCostBatch)
	end

	local session = activeSessions[player]
	if pending.IsReturningToMap and session ~= nil then
		session.Extracting = false
	else
		sendRaidHud(player, {
			Active = false,
			TargetName = pending.TargetName,
			TimeLeft = 0,
			StatusText = string.format("Teleport failed: %s", errorMessage),
		})
	end
end

local function createRaidSessionRecord(
	player: Player,
	targetUserId: number,
	targetName: string,
	targetBaseTier: number,
	origin: Vector3,
	isStudioMock: boolean,
	returnPos: Vector3?
): RaidSession
	local outpostOrigin = origin + Vector3.new(0, 0, Config.Raid.OutpostOffsetZ)
	return {
		Raider = player,
		TargetUserId = targetUserId,
		TargetName = targetName,
		TargetBaseTier = targetBaseTier,
		Origin = origin,
		OutpostOrigin = outpostOrigin,
		IsStudioMock = isStudioMock,
		StartTime = os.clock(),
		Duration = RAID_DURATION,
		Pieces = {},
		RaiderPieces = {},
		RaiderOccupiedSockets = {},
		RaiderOccupiedWorldKeys = {},
		OutpostZoneModel = nil,
		OutpostWorkbenchId = nil,
		ExtractionStashContainerId = nil,
		ExtractionStashModel = nil,
		ExtractionTerminalModel = nil,
		ExtractionTerminalPrompt = nil,
		ExtractionTerminalIndicator = nil,
		ArenaGroundPart = nil,
		RespawnPosition = outpostOrigin + Vector3.new(-3.2, 4.2, 2.4),
		DroppedContainerIds = {},
		ActiveExplosives = {},
		TcPieceUid = nil,
		TcCaptured = false,
		TcHackActive = false,
		TcHackStartTime = 0,
		TcHackPrompt = nil,
		LivesLeft = Config.Raid.MaxLives,
		MaxLives = Config.Raid.MaxLives,
		LastDamagedAt = 0,
		Extracting = false,
		PendingReturnOnRespawn = false,
		ReturnPosition = returnPos,
		Janitor = Janitor.new(),
	}
end

local function startRaidSession(session: RaidSession, baseData: BaseData)
	local player = session.Raider
	activeSessions[player] = session
	player:SetAttribute("InRaid", true)
	spawnRaidTargetBase(session, baseData)
	spawnRaidOutpost(session)
	bindRaiderLifecycle(session)
	teleportCharacterToPosition(player, session.RespawnPosition)
	startSessionTimerLoop(session)
	syncSessionHud(
		session,
		string.format("Raid started (Tier %d) — Hack or destroy enemy TC!", session.TargetBaseTier)
	)
end

local function onPlayerDataLoaded(player: Player, _data: Types.PlayerData)
	local ok, joinData = pcall(function()
		return player:GetJoinData()
	end)
	local teleportData = if ok
			and type(joinData) == "table"
			and type(joinData.TeleportData) == "table"
		then joinData.TeleportData
		else nil
	local isRaidJoin = game.PlaceId == Config.Places.PlayerBase and teleportData ~= nil and teleportData.Mode == "Raid"

	if not isRaidJoin then
		deliverDefenseReports(player)
		return
	end

	local targetUserIdAny = teleportData.TargetUserId
	if not SecurityService.IsValidInteger(targetUserIdAny) then
		return
	end
	local targetUserId = math.floor(targetUserIdAny :: number)
	local targetName = if type(teleportData.TargetName) == "string" and #teleportData.TargetName > 0
		then teleportData.TargetName
		else resolveTargetName(targetUserId)

	local presetTier = DataService.GetPresetTier(targetUserId)
	local targetBaseTier = if presetTier ~= nil
		then presetTier
		elseif SecurityService.IsValidInteger(teleportData.TargetBaseTier) then math.clamp(
			math.floor(teleportData.TargetBaseTier :: number),
			1,
			3
		)
		else resolveTargetTier(targetUserId)

	Workspace:SetAttribute("RaidServerMode", true)

	local baseData: BaseData? = nil
	if targetUserId > 0 then
		baseData = DataService.LoadBaseSnapshot(targetUserId)
	end
	if baseData == nil or #baseData.Pieces == 0 then
		baseData = buildPresetRaidBase(targetBaseTier)
	end

	if activeSessions[player] ~= nil then
		cleanupSession(activeSessions[player])
		activeSessions[player] = nil
	end

	local session = createRaidSessionRecord(player, targetUserId, targetName, targetBaseTier, Vector3.zero, false, nil)
	startRaidSession(session, baseData :: BaseData)
end

function RaidService.EnterStudioMockRaid(player: Player, targetUserId: number): boolean
	if not RunService:IsStudio() or player.Parent ~= Players then
		return false
	end
	if activeSessions[player] ~= nil then
		return false
	end

	local returnPos = getDefaultSpawnPosition()
	local _, hrp, _ = getAliveCharacterParts(player)
	if hrp ~= nil then
		returnPos = hrp.Position + Vector3.new(0, 1, 0)
	end

	local targetBaseTier = resolveTargetTier(targetUserId)
	local baseData: BaseData? = nil
	if targetUserId > 0 then
		baseData = DataService.LoadBaseSnapshot(targetUserId)
	end
	if baseData == nil or #baseData.Pieces == 0 then
		baseData = buildPresetRaidBase(targetBaseTier)
	end

	local targetName = resolveTargetName(targetUserId)
	local session = createRaidSessionRecord(
		player,
		targetUserId,
		targetName,
		targetBaseTier,
		STUDIO_MOCK_RAID_ORIGIN,
		true,
		returnPos
	)
	startRaidSession(session, baseData :: BaseData)
	return true
end

function RaidService.IsPlayerInRaid(player: Player): boolean
	return activeSessions[player] ~= nil
end

function RaidService.GetActiveSessionInfo(player: Player): RaidHudState?
	local session = activeSessions[player]
	if session == nil then
		return nil
	end
	return buildRaidHudState(session, nil)
end

function RaidService.Init()
	if isInitialized then
		return
	end
	isInitialized = true

	Net.InitServer()

	DefenseService.BindRaidHooks({
		TriggerExplosion = RaidService.TriggerExplosion,
		NotifyRaiderDamaged = RaidService.NotifyRaiderDamaged,
	})

	Net.GetEvent(Net.Events.RaidListRequest).OnServerEvent:Connect(onRaidListRequest)
	Net.GetEvent(Net.Events.StartRaidRequest).OnServerEvent:Connect(onStartRaidRequest)
	Net.GetEvent(Net.Events.BuildPlaceRequest).OnServerEvent:Connect(onRaidBuildPlaceRequest)
	Net.GetEvent(Net.Events.PlaceExplosiveRequest).OnServerEvent:Connect(onPlaceExplosiveRequest)
	Net.GetEvent(Net.Events.RaidExtractRequest).OnServerEvent:Connect(onRaidExtractRequest)
	Net.GetEvent(Net.Events.RaidTcHackRequest).OnServerEvent:Connect(onRaidTcHackRequest)
	Net.GetEvent(Net.Events.RaidAbandonRequest).OnServerEvent:Connect(onRaidAbandonRequest)
	TeleportService.TeleportInitFailed:Connect(onTeleportInitFailed)

	DataService.OnDataLoaded(onPlayerDataLoaded)

	Players.PlayerRemoving:Connect(function(player: Player)
		local session = activeSessions[player]
		if session ~= nil then
			if not session.Extracting and not session.TcCaptured then
				recordDefenseReport(
					session,
					true,
					string.format("%s disconnected before capturing TC", player.DisplayName)
				)
			end
			activeSessions[player] = nil
			cleanupSession(session)
		end
		lastListRequest[player] = nil
		lastExplosivePlaceTime[player] = nil
		teleportInProgress[player] = nil
		pendingTeleports[player] = nil
	end)
end

return RaidService
