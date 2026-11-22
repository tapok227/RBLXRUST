--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage.Shared.Config)
local Types = require(ReplicatedStorage.Shared.Types)

export type BuildPieceType = Types.BuildPieceType
export type BuildTier = Types.BuildTier
export type BuildPieceCategory = Types.BuildPieceCategory
export type BuildPieceShape = Types.BuildPieceShape
export type BuildPieceConfig = Types.BuildPieceConfig
export type BuildTierConfig = Types.BuildTierConfig

local GRID_SIZE = 12
local WALL_HEIGHT = 10
local WALL_BODY_HEIGHT = 9.2
local THICKNESS = 0.8
local FOUNDATION_THICKNESS = 1.0
local TRIANGLE_HEIGHT = GRID_SIZE * math.sqrt(3) / 2
local TRIANGLE_INRADIUS = GRID_SIZE * math.sqrt(3) / 6
local TRIANGLE_CIRCUMRADIUS = GRID_SIZE * math.sqrt(3) / 3

local triangleFoundationCfg: BuildPieceConfig = table.freeze({
	Name = "Triangle Foundation",
	Category = "Foundation",
	Shape = "Triangle",
	Cost = table.freeze({ wood = 30 }),
	BaseHp = 200,
	Upgradeable = true,
})

local windowWallCfg: BuildPieceConfig = table.freeze({
	Name = "Window Wall",
	Category = "Wall",
	Shape = "Edge",
	Cost = table.freeze({ wood = 30 }),
	BaseHp = 200,
	Upgradeable = true,
})

local triangleFloorCfg: BuildPieceConfig = table.freeze({
	Name = "Triangle Floor",
	Category = "Floor",
	Shape = "Triangle",
	Cost = table.freeze({ wood = 20 }),
	BaseHp = 180,
	Upgradeable = true,
})

local squareStairsCfg: BuildPieceConfig = table.freeze({
	Name = "Square Stairs",
	Category = "Stairs",
	Shape = "Square",
	Cost = table.freeze({ wood = 45 }),
	BaseHp = 200,
	Upgradeable = true,
})

local triangleStairsCfg: BuildPieceConfig = table.freeze({
	Name = "Triangle Stairs",
	Category = "Stairs",
	Shape = "Triangle",
	Cost = table.freeze({ wood = 35 }),
	BaseHp = 180,
	Upgradeable = true,
})

local Pieces: { [BuildPieceType]: BuildPieceConfig } = table.freeze({
	foundation = table.freeze({
		Name = "Foundation",
		Category = "Foundation",
		Shape = "Square",
		Cost = table.freeze({ wood = 50 }),
		BaseHp = 250,
		Upgradeable = true,
	}),
	triangle_foundation = triangleFoundationCfg,
	TriangleFoundation = triangleFoundationCfg,
	wall = table.freeze({
		Name = "Wall",
		Category = "Wall",
		Shape = "Edge",
		Cost = table.freeze({ wood = 35 }),
		BaseHp = 250,
		Upgradeable = true,
	}),
	doorway = table.freeze({
		Name = "Doorway",
		Category = "Wall",
		Shape = "Edge",
		Cost = table.freeze({ wood = 30 }),
		BaseHp = 200,
		Upgradeable = true,
	}),
	window_wall = windowWallCfg,
	WindowWall = windowWallCfg,
	roof = table.freeze({
		Name = "Square Floor",
		Category = "Floor",
		Shape = "Square",
		Cost = table.freeze({ wood = 35 }),
		BaseHp = 200,
		Upgradeable = true,
	}),
	triangle_floor = triangleFloorCfg,
	TriangleFloor = triangleFloorCfg,
	square_stairs = squareStairsCfg,
	SquareStairs = squareStairsCfg,
	triangle_stairs = triangleStairsCfg,
	TriangleStairs = triangleStairsCfg,
	storage_box = table.freeze({
		Name = "Storage Box",
		Category = "Deployable",
		Shape = "Deployable",
		Cost = table.freeze({ wood = 60 }),
		BaseHp = 150,
		Upgradeable = false,
		StorageSlots = 18,
	}),
	tool_cupboard = table.freeze({
		Name = "Tool Cupboard",
		Category = "Deployable",
		Shape = "Deployable",
		Cost = table.freeze({ wood = 200 }),
		BaseHp = 300,
		Upgradeable = false,
		StorageSlots = 12,
		MaxPerBase = 1,
	}),
	workbench_1 = table.freeze({
		Name = "Workbench Lv.1",
		Category = "Deployable",
		Shape = "Deployable",
		Cost = table.freeze({ wood = 100, stone = 50 }),
		BaseHp = 200,
		Upgradeable = false,
		RequiredBaseTier = 1,
	}),
	workbench_2 = table.freeze({
		Name = "Workbench Lv.2",
		Category = "Deployable",
		Shape = "Deployable",
		Cost = table.freeze({ wood = 150, metal_ore = 120, scrap = 80 }),
		BaseHp = 350,
		Upgradeable = false,
		RequiredBaseTier = 2,
	}),
	workbench_3 = table.freeze({
		Name = "Workbench Lv.3",
		Category = "Deployable",
		Shape = "Deployable",
		Cost = table.freeze({ high_quality_metal = 40, tech_parts = 6, scrap = 150 }),
		BaseHp = 500,
		Upgradeable = false,
		RequiredBaseTier = 3,
	}),
	research_table = table.freeze({
		Name = "Research Table",
		Category = "Deployable",
		Shape = "Deployable",
		Cost = table.freeze({ wood = 120, metal_ore = 80, scrap = 75 }),
		BaseHp = 250,
		Upgradeable = false,
		MaxPerBase = 2,
	}),
	assault_ladder = table.freeze({
		Name = "Assault Ladder",
		Category = "Deployable",
		Shape = "Deployable",
		Cost = table.freeze({ wood = 40 }),
		BaseHp = 120,
		Upgradeable = false,
		AssaultDeployable = true,
	}),
	barricade = table.freeze({
		Name = "Assault Barricade",
		Category = "Deployable",
		Shape = "Deployable",
		Cost = table.freeze({ wood = 50, stone = 20 }),
		BaseHp = 220,
		Upgradeable = false,
		AssaultDeployable = true,
	}),
	floor_spikes = table.freeze({
		Name = "Floor Spikes",
		Category = "Deployable",
		Shape = "Deployable",
		Cost = table.freeze({ wood = 60, metal_ore = 20 }),
		BaseHp = 100,
		Upgradeable = false,
		IsDefense = true,
		DefenseCost = Config.DefenseCapacity.Costs.floor_spikes,
		AllowedMount = "Floor",
	}),
	landmine = table.freeze({
		Name = "Landmine",
		Category = "Deployable",
		Shape = "Deployable",
		Cost = table.freeze({ metal_ore = 35, scrap = 20 }),
		BaseHp = 40,
		Upgradeable = false,
		IsDefense = true,
		DefenseCost = Config.DefenseCapacity.Costs.landmine,
		AllowedMount = "Floor",
	}),
	shotgun_trap = table.freeze({
		Name = "Shotgun Trap",
		Category = "Deployable",
		Shape = "Deployable",
		Cost = table.freeze({ wood = 50, metal_ore = 60, scrap = 25 }),
		BaseHp = 200,
		Upgradeable = false,
		StorageSlots = 3,
		IsDefense = true,
		DefenseCost = Config.DefenseCapacity.Costs.shotgun_trap,
		AllowedMount = "WallOrCeiling",
	}),
	auto_turret = table.freeze({
		Name = "Auto Turret",
		Category = "Deployable",
		Shape = "Deployable",
		Cost = table.freeze({ high_quality_metal = 15, tech_parts = 3, metal_ore = 80 }),
		BaseHp = 500,
		Upgradeable = false,
		StorageSlots = 4,
		IsDefense = true,
		DefenseCost = Config.DefenseCapacity.Costs.auto_turret,
		AllowedMount = "Floor",
	}),
})

local CanonicalPieceMap: { [string]: BuildPieceType } = table.freeze({
	foundation = "foundation",
	triangle_foundation = "triangle_foundation",
	TriangleFoundation = "triangle_foundation",
	wall = "wall",
	doorway = "doorway",
	window_wall = "window_wall",
	WindowWall = "window_wall",
	roof = "roof",
	triangle_floor = "triangle_floor",
	TriangleFloor = "triangle_floor",
	square_stairs = "square_stairs",
	SquareStairs = "square_stairs",
	triangle_stairs = "triangle_stairs",
	TriangleStairs = "triangle_stairs",
	storage_box = "storage_box",
	tool_cupboard = "tool_cupboard",
	workbench_1 = "workbench_1",
	workbench_2 = "workbench_2",
	workbench_3 = "workbench_3",
	research_table = "research_table",
	assault_ladder = "assault_ladder",
	barricade = "barricade",
	floor_spikes = "floor_spikes",
	landmine = "landmine",
	shotgun_trap = "shotgun_trap",
	auto_turret = "auto_turret",
})

local Tiers: { [BuildTier]: BuildTierConfig } = table.freeze({
	wood = table.freeze({
		Rank = 1,
		Name = "Wood",
		HpMultiplier = 1.0,
		ExplosionResistance = 0.0,
		ToolDamageMultiplier = 1.0,
		Material = Enum.Material.WoodPlanks,
		Color = Color3.fromRGB(165, 118, 72),
		UpgradeCost = nil,
	}),
	stone = table.freeze({
		Rank = 2,
		Name = "Stone",
		HpMultiplier = 2.0,
		ExplosionResistance = 0.0,
		ToolDamageMultiplier = 0.25,
		Material = Enum.Material.Cobblestone,
		Color = Color3.fromRGB(142, 142, 148),
		UpgradeCost = table.freeze({ stone = 75 }),
	}),
	metal = table.freeze({
		Rank = 3,
		Name = "Metal",
		HpMultiplier = 4.0,
		ExplosionResistance = 0.0,
		ToolDamageMultiplier = 0.10,
		Material = Enum.Material.Metal,
		Color = Color3.fromRGB(108, 118, 128),
		UpgradeCost = table.freeze({ metal_ore = 60 }),
	}),
	armored = table.freeze({
		Rank = 4,
		Name = "Armored",
		HpMultiplier = 8.0,
		ExplosionResistance = 0.0,
		ToolDamageMultiplier = 0.02,
		Material = Enum.Material.DiamondPlate,
		Color = Color3.fromRGB(64, 72, 82),
		UpgradeCost = table.freeze({ high_quality_metal = 15, metal_ore = 40 }),
	}),
})

local ValidRotations: { [number]: boolean } = table.freeze({
	[0] = true,
	[30] = true,
	[60] = true,
	[90] = true,
	[120] = true,
	[150] = true,
	[180] = true,
	[210] = true,
	[240] = true,
	[270] = true,
	[300] = true,
	[330] = true,
})

local PieceOrder: { BuildPieceType } = table.freeze({
	"foundation",
	"triangle_foundation",
	"wall",
	"doorway",
	"window_wall",
	"roof",
	"triangle_floor",
	"square_stairs",
	"triangle_stairs",
	"storage_box",
	"tool_cupboard",
	"workbench_1",
	"workbench_2",
	"workbench_3",
	"research_table",
	"assault_ladder",
	"barricade",
	"floor_spikes",
	"landmine",
	"shotgun_trap",
	"auto_turret",
})

local TierOrder: { BuildTier } = table.freeze({
	"wood",
	"stone",
	"metal",
	"armored",
})

local function getNextTier(tier: BuildTier): BuildTier?
	local idx = table.find(TierOrder, tier)
	if idx == nil or idx >= #TierOrder then
		return nil
	end
	return TierOrder[idx + 1]
end

local function normalizePieceType(raw: string): BuildPieceType?
	return CanonicalPieceMap[raw]
end

local function computeExplosionDamage(
	rawDamage: number,
	pieceType: BuildPieceType,
	tier: BuildTier,
	hasDoor: boolean?
): number
	local canonical = normalizePieceType(pieceType) or pieceType
	local pieceCfg = Pieces[canonical]
	local tierCfg = Tiers[tier] or Tiers.wood
	local tierMults = Config.Explosion.TierDamageMultiplier :: { [string]: number }
	local mult = tierMults[tier] or math.max(0.05, 1.0 - tierCfg.ExplosionResistance)
	if pieceCfg ~= nil and pieceCfg.IsDefense == true then
		mult *= Config.Explosion.DefenseDamageMultiplier
	end
	if canonical == "doorway" and hasDoor == true then
		mult *= Config.Explosion.DoorDamageMultiplier
	end
	return math.max(1, math.floor(rawDamage * mult + 0.5))
end

local BuildingConfig = table.freeze({
	GridSize = GRID_SIZE,
	WallHeight = WALL_HEIGHT,
	WallBodyHeight = WALL_BODY_HEIGHT,
	Thickness = THICKNESS,
	WallThickness = THICKNESS,
	FloorThickness = THICKNESS,
	FoundationThickness = FOUNDATION_THICKNESS,
	TriangleHeight = TRIANGLE_HEIGHT,
	TriangleInradius = TRIANGLE_INRADIUS,
	TriangleCircumradius = TRIANGLE_CIRCUMRADIUS,
	MaxBuildDistance = Types.MAX_BUILD_DISTANCE,
	MinParallelWallDistance = 3.5,
	ParallelWallSearchRadius = 6.0,
	ParallelWallAngleDeg = 15.0,
	FreeFoundationSpacing = 3.5,
	UpgradeRaidBlockSeconds = Config.Explosion.UpgradeRaidBlockSeconds,
	MaxBuildHeight = 4,
	OverlapShrinkFactor = 0.85,
	GridMinXZ = -10,
	GridMaxXZ = 10,
	GridMinY = 0,
	GridMaxY = 4,
	MaxPiecesPerBase = 200,
	ValidRotations = ValidRotations,
	PieceOrder = PieceOrder,
	TierOrder = TierOrder,
	Pieces = Pieces,
	Tiers = Tiers,
	GetNextTier = getNextTier,
	NormalizePieceType = normalizePieceType,
	ComputeExplosionDamage = computeExplosionDamage,
})

return BuildingConfig
