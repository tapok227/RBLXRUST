--!strict

export type ItemType = "Resource" | "Tool" | "Consumable"

export type ItemConfig = {
	Name: string,
	Type: ItemType,
	MaxStack: number,
}

export type Slot = {
	Id: string,
	Count: number,
}

export type Inventory = { [number]: Slot? }

export type SurvivalStats = {
	Health: number,
	Hunger: number,
	Thirst: number,
}

export type ConsumableConfig = {
	Health: number,
	Hunger: number,
	Thirst: number,
	UseCooldown: number,
}

export type LootContainerState = {
	ContainerId: string,
	OwnerName: string,
	Slots: Inventory,
	ExpiresAt: number,
}

export type BuildPieceType =
	"foundation"
	| "triangle_foundation"
	| "wall"
	| "doorway"
	| "window_wall"
	| "roof"
	| "triangle_floor"
	| "square_stairs"
	| "triangle_stairs"
	| "storage_box"
	| "tool_cupboard"
	| "workbench_1"
	| "workbench_2"
	| "workbench_3"
	| "assault_ladder"
	| "barricade"
	| "floor_spikes"
	| "landmine"
	| "shotgun_trap"
	| "auto_turret"
	| "TriangleFoundation"
	| "WindowWall"
	| "TriangleFloor"
	| "SquareStairs"
	| "TriangleStairs"

export type BuildTier = "wood" | "stone" | "metal" | "armored"

export type BuildPieceCategory = "Foundation" | "Floor" | "Wall" | "Stairs" | "Deployable"

export type BuildPieceShape = "Square" | "Triangle" | "Edge" | "Deployable"

export type BuildSocketKind = "Edge" | "Top" | "Center" | "WallTop"

export type BuildSocketDef = {
	Id: string,
	Kind: BuildSocketKind,
	LocalCFrame: CFrame,
}

export type BuildOverlapBox = {
	CFrame: CFrame,
	Size: Vector3,
}

export type DefenseMountSurface = "Floor" | "Wall" | "Ceiling"

export type DefenseAllowedMount = "Floor" | "WallOrCeiling"

export type DefenseConfig = {
	Id: BuildPieceType,
	Name: string,
	CapacityCost: number,
	AllowedMount: DefenseAllowedMount,
	BaseHp: number,
	Range: number,
	ConeHalfAngleDeg: number?,
	LockOnDuration: number?,
	Cooldown: number,
	BurstCount: number?,
	BurstInterval: number?,
	PelletCount: number?,
	SpreadDeg: number?,
	Damage: number,
	SlowMultiplier: number?,
	SlowDuration: number?,
	SelfDamageOnTrigger: number?,
	ExplosionRadius: number?,
	ExplosionStructureDamage: number?,
	ExplosionPlayerDamage: number?,
	AmmoId: string?,
	AmmoSlots: number?,
	ProjectileSpeed: number?,
	ProjectileGravity: number?,
}

export type DefenseUiState = {
	Uid: string,
	PieceType: BuildPieceType,
	Name: string,
	Hp: number,
	MaxHp: number,
	AmmoId: string,
	AmmoCount: number,
	AmmoSlots: number,
	Slots: Inventory,
	DefenseUsed: number,
	DefenseMax: number,
}

export type SavedBuildPiece = {
	Uid: string,
	PieceType: BuildPieceType,
	Tier: BuildTier,
	PosX: number,
	PosY: number,
	PosZ: number,
	RotY: number,
	ParentUid: string?,
	AnchorUid: string?,
	SocketId: string?,
	MountSurface: DefenseMountSurface?,
	Hp: number,
	LastDamagedAt: number?,
	Storage: { [string]: Slot }?,
	GridX: number?,
	GridY: number?,
	GridZ: number?,
}

export type BaseTier = number

export type ToolCupboardStatus = "Protected" | "Decaying"

export type ToolCupboardState = {
	Uid: string,
	ContainerId: string,
	BaseTier: BaseTier,
	Status: ToolCupboardStatus,
	HourlyUpkeep: { [string]: number },
	ProtectedHours: number,
	PathValid: boolean,
	PathMessage: string?,
	DefenseUsed: number?,
	DefenseMax: number?,
	Slots: Inventory,
}

export type BaseData = {
	Pieces: { SavedBuildPiece },
	BaseTier: BaseTier,
	LastUpkeepTimestamp: number,
}

export type BuildPieceConfig = {
	Name: string,
	Category: BuildPieceCategory,
	Shape: BuildPieceShape,
	Cost: { [string]: number },
	BaseHp: number,
	Upgradeable: boolean,
	StorageSlots: number?,
	RequiredBaseTier: number?,
	MaxPerBase: number?,
	AssaultDeployable: boolean?,
	DefenseCost: number?,
	IsDefense: boolean?,
	AllowedMount: DefenseAllowedMount?,
}

export type BuildTierConfig = {
	Rank: number,
	Name: string,
	HpMultiplier: number,
	ExplosionResistance: number,
	ToolDamageMultiplier: number,
	Material: Enum.Material,
	Color: Color3,
	UpgradeCost: { [string]: number }?,
}

export type PlayerData = {
	DataVersion: number,
	Version: number,
	Inventory: Inventory,
	Stats: SurvivalStats,
	Base: BaseData,
}

export type ItemBatchEntry = {
	Id: string,
	Count: number,
}

export type ToolCategory = "Tree" | "Rock" | "Ore" | "Build"

export type ToolConfig = {
	Power: number,
	Cooldown: number,
	PreferredNodeType: ToolCategory,
	BonusMultiplier: number,
}

export type NodeType = "tree" | "stone_node" | "metal_node"

export type NodeConfig = {
	Name: string,
	Category: ToolCategory,
	MaxHp: number,
	ResourceId: string,
	YieldPerHit: number,
	BonusOnDestroy: number,
	RespawnTime: number,
}

export type NodeClientState = {
	Hp: number,
	MaxHp: number,
	Depleted: boolean,
}

export type Ingredient = {
	Id: string,
	Count: number,
}

export type RecipeConfig = {
	Id: string,
	ResultId: string,
	ResultCount: number,
	CraftTime: number,
	Station: string?,
	Ingredients: { Ingredient },
}

export type CraftingState = {
	RecipeId: string,
	StartTime: number,
	EndTime: number,
}

export type WeaponCategory = "Melee" | "Ranged"

export type WeaponConfig = {
	Category: WeaponCategory,
	Damage: number,
	HeadshotMultiplier: number,
	Range: number,
	Cooldown: number,
	AmmoId: string?,
	ProjectileId: string?,
}

export type LootDropEntry = {
	Id: string,
	Weight: number,
	MinCount: number,
	MaxCount: number,
}

export type LootTableConfig = {
	Rolls: number,
	RespawnTime: number,
	Items: { LootDropEntry },
}

export type WorldEventPayload = {
	EventType: string,
	Title: string,
	Position: Vector3,
	Duration: number,
}

export type ExtractionState = {
	Active: boolean,
	ZoneName: string,
	TimeLeft: number,
	TotalTime: number,
	StatusText: string?,
}

export type ExplosiveConfig = {
	StructureDamage: number,
	PlayerDamage: number,
	Radius: number,
	FuseTime: number,
}

export type ProjectileConfig = {
	Id: string,
	Speed: number,
	Gravity: number,
	MaxLifetime: number,
	BlastRadius: number,
	StructureDamage: number,
	PlayerDamage: number,
	MinFalloffMultiplier: number,
}

export type ExplosionParams = {
	Origin: Vector3,
	Radius: number,
	StructureDamage: number,
	PlayerDamage: number,
	Attacker: Player?,
	SourceId: string?,
	ProjectileId: string?,
	ExcludeInstances: { Instance }?,
	MinFalloffMultiplier: number?,
}

export type ExplosionResult = {
	DamagedStructures: number,
	DestroyedStructures: number,
	DamagedHumanoids: number,
	OccludedStructures: number,
	OccludedHumanoids: number,
}

export type RaidTargetInfo = {
	UserId: number,
	DisplayName: string,
	PieceCount: number,
	BaseTier: number?,
	DangerLabel: string?,
	RewardLabel: string?,
	LaunchCost: { [string]: number }?,
	IsPreset: boolean?,
}

export type RaidHudState = {
	Active: boolean,
	TargetName: string,
	TargetBaseTier: number?,
	TimeLeft: number,
	StatusText: string?,
	TcCaptured: boolean?,
	TcHackProgress: number?,
	TcHackActive: boolean?,
	LivesLeft: number?,
	MaxLives: number?,
	StashItemCount: number?,
	CanExtract: boolean?,
}

export type RaidDefenseReport = {
	RaiderName: string,
	TargetTier: number,
	Defended: boolean,
	Timestamp: number,
	BonusItems: { [string]: number }?,
	Summary: string,
}

local Types = {
	INVENTORY_SIZE = 30,
	HOTBAR_SIZE = 6,
	HANDS_POWER = 5,
	HANDS_COOLDOWN = 0.8,
	BASE_TOOL_MULTIPLIER = 1.0,
	MAX_GATHER_DISTANCE_SERVER = 14,
	MAX_GATHER_DISTANCE_CLIENT = 12,
	MAX_STATION_DISTANCE = 14,
	MAX_HEALTH = 100,
	MAX_HUNGER = 100,
	MAX_THIRST = 100,
	RESPAWN_HEALTH = 100,
	RESPAWN_HUNGER = 80,
	RESPAWN_THIRST = 80,
	SURVIVAL_TICK_INTERVAL = 2.0,
	MAX_LOOT_DISTANCE = 14,
	LOOT_CONTAINER_LIFETIME = 300,
	MAX_ATTACK_ORIGIN_OFFSET = 8,
	MAX_EXPLOSIVE_PLACE_DISTANCE = 14,
	RAID_DURATION = 300,
	CURRENT_DATA_VERSION = 4,
	PING_DISTANCE_TOLERANCE = 2,
	MAX_BUILD_DISTANCE = 20,
	MAX_RAID_TERMINAL_DISTANCE = 24,
	MAX_PROJECTILE_LIFETIME = 10,
	MAX_ACTIVE_PROJECTILES_PER_PLAYER = 3,
}

return Types
