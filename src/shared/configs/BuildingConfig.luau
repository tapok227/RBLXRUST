--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage.Shared.Types)

export type BuildPieceType = Types.BuildPieceType
export type BuildTier = Types.BuildTier
export type BuildPieceConfig = Types.BuildPieceConfig
export type BuildTierConfig = Types.BuildTierConfig

local Pieces: { [BuildPieceType]: BuildPieceConfig } = table.freeze({
	foundation = table.freeze({
		Name = "Foundation",
		Cost = table.freeze({ wood = 50 }),
		BaseHp = 150,
		Upgradeable = true,
	}),
	wall = table.freeze({
		Name = "Wall",
		Cost = table.freeze({ wood = 35 }),
		BaseHp = 150,
		Upgradeable = true,
	}),
	doorway = table.freeze({
		Name = "Doorway",
		Cost = table.freeze({ wood = 30 }),
		BaseHp = 120,
		Upgradeable = true,
	}),
	roof = table.freeze({
		Name = "Roof",
		Cost = table.freeze({ wood = 35 }),
		BaseHp = 120,
		Upgradeable = true,
	}),
	storage_box = table.freeze({
		Name = "Storage Box",
		Cost = table.freeze({ wood = 60 }),
		BaseHp = 100,
		Upgradeable = false,
		StorageSlots = 18,
	}),
	workbench_1 = table.freeze({
		Name = "Workbench Lv.1",
		Cost = table.freeze({ wood = 100, stone = 50 }),
		BaseHp = 150,
		Upgradeable = false,
	}),
})

local Tiers: { [BuildTier]: BuildTierConfig } = table.freeze({
	wood = table.freeze({
		Name = "Wood",
		HpMultiplier = 1.0,
		UpgradeCost = nil,
	}),
	stone = table.freeze({
		Name = "Stone",
		HpMultiplier = 2.0,
		UpgradeCost = table.freeze({ stone = 75 }),
	}),
	metal = table.freeze({
		Name = "Metal",
		HpMultiplier = 3.5,
		UpgradeCost = table.freeze({ metal_ore = 60 }),
	}),
})

local ValidRotations: { [number]: boolean } = table.freeze({
	[0] = true,
	[90] = true,
	[180] = true,
	[270] = true,
})

local PieceOrder: { BuildPieceType } = table.freeze({
	"foundation",
	"wall",
	"doorway",
	"roof",
	"storage_box",
	"workbench_1",
})

local TierOrder: { BuildTier } = table.freeze({
	"wood",
	"stone",
	"metal",
})

local BuildingConfig = table.freeze({
	GridSize = 12,
	WallHeight = 10,
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
})

return BuildingConfig
