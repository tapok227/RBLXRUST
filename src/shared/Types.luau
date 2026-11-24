--!strict

export type ItemType = "Resource" | "Tool" | "Consumable" | "Blueprint"

export type ItemConfig = {
	Name: string,
	Type: ItemType,
	MaxStack: number,
}

export type ItemId = string

export type Slot = {
	Id: ItemId,
	Count: number,
}

export type InventorySlot = Slot

export type Inventory = { [number]: Slot? }

export type EquipmentMap = { [string]: InventorySlot? }

export type ContainerData = {
	ContainerId: string,
	OwnerUserId: number?,
	OwnerName: string,
	MaxSlots: number,
	Slots: Inventory,
	ExpiresAt: number?,
	IsPersistent: boolean?,
}

export type SurvivalStats = {
	Health: number,
	Hunger: number,
	Thirst: number,
	WellFedEndTime: number?,
	WellFedStaminaMult: number?,
}

export type ConsumableConfig = {
	Health: number,
	Hunger: number,
	Thirst: number,
	Stamina: number?,
	UseCooldown: number,
	BuffDuration: number?,
	MaxStaminaBonus: number?,
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
	| "research_table"
	| "assault_ladder"
	| "barricade"
	| "floor_spikes"
	| "landmine"
	| "shotgun_trap"
	| "auto_turret"
	| "hbhf_sensor"
	| "smart_door"
	| "TriangleFoundation"
	| "WindowWall"
	| "TriangleFloor"
	| "SquareStairs"
	| "TriangleStairs"

export type BuildTier = "wood" | "stone" | "metal" | "armored"

export type ModuleType = BuildPieceType

export type BuildingTier = BuildTier

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

export type DefenseAllowedMount = "Floor" | "WallOrCeiling" | "Doorway"

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
	SignalRadius: number?,
	OpenDuration: number?,
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
	HasCodeLock: boolean?,
	IsDoorOpen: boolean?,
	LinkedHbhfSensor: boolean?,
	HasDoor: boolean?,
	GridX: number?,
	GridY: number?,
	GridZ: number?,
}

export type BaseTier = number

export type ToolCupboardStatus = "Protected" | "Decaying"

export type DeathGhostPoint = {
	PosX: number,
	PosY: number,
	PosZ: number,
	Cause: string,
	RaiderName: string,
}

export type DefenseLogEntry = {
	Id: string,
	RaiderUserId: number,
	RaiderName: string,
	TargetTier: number,
	Defended: boolean,
	LivesSpent: number,
	MaxLives: number,
	RewardScrap: number,
	Timestamp: number,
	GhostsShown: boolean,
	DeathPoints: { DeathGhostPoint },
	Summary: string,
}

export type BlueprintPieceEntry = {
	PieceType: BuildPieceType,
	Tier: BuildTier,
	RelX: number,
	RelY: number,
	RelZ: number,
	RelRotY: number,
	MountSurface: DefenseMountSurface?,
	IsTc: boolean?,
}

export type BaseBlueprintSlot = {
	Id: string,
	Name: string,
	SavedAt: number,
	EncodedBlocks: string?,
	PieceCount: number?,
	Cost: { [string]: number }?,
	Pieces: { BlueprintPieceEntry }?,
}

export type BaseBlueprintSummary = {
	Id: string,
	Name: string,
	PieceCount: number,
	SavedAt: number,
	IsBuiltin: boolean,
	HasData: boolean,
	Cost: { [string]: number },
}

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
	DefenseLogs: { DefenseLogEntry }?,
	Blueprints: { BaseBlueprintSummary }?,
}

export type BaseData = {
	Pieces: { SavedBuildPiece },
	BaseTier: BaseTier,
	LastUpkeepTimestamp: number,
	SerializedBlocks: string?,
	ContainerSidecar: { [string]: { [string]: Slot } }?,
}

export type BuildingBlockData = SavedBuildPiece

export type QuantizedBlock = {
	Uid: string,
	Module: ModuleType,
	Tier: BuildingTier,
	QX: number,
	QY: number,
	QZ: number,
	YawStep: number,
	ParentUid: string?,
	SocketId: string?,
	MountSurface: DefenseMountSurface?,
	Hp: number,
}

export type BaseSnapshot = {
	OwnerUserId: number,
	OwnerName: string?,
	BaseTier: BaseTier,
	Pieces: { BuildingBlockData },
	QuantizedBlocks: { QuantizedBlock }?,
	SavedAt: number,
	IsPreset: boolean?,
}

export type TCState = ToolCupboardState

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
	SchemaVersion: number,
	DataVersion: number,
	Version: number,
	Inventory: Inventory,
	Equipment: EquipmentMap,
	Stats: SurvivalStats,
	Base: BaseData,
	UnlockedBlueprints: { [string]: boolean },
	DefenseLogs: { DefenseLogEntry },
	BaseBlueprints: { [string]: BaseBlueprintSlot },
	LastStarterKitAt: number?,
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
	RequiredWorkbench: number,
	Station: string?,
	RequiresBlueprint: boolean,
	ResearchCost: number,
	Ingredients: { Ingredient },
}

export type CraftingState = {
	RecipeId: string,
	StartTime: number,
	EndTime: number,
}

export type RecycleOutputEntry = {
	Id: string,
	Count: number,
}

export type RecyclerState = {
	RecyclerId: string,
	Name: string,
	EfficiencyMultiplier: number,
	IsRunning: boolean,
	InputSlots: Inventory,
	OutputSlots: Inventory,
	Progress: number,
	Position: Vector3,
}

export type ResearchTableState = {
	TableId: string,
	Name: string,
	Position: Vector3,
}

export type ResearchFeedback = {
	Success: boolean,
	Message: string,
	RecipeId: string?,
}

export type VendorId = "recycler" | "weaponsmith" | "quartermaster"

export type VendorOfferMode = "Buy" | "Sell"

export type VendorOffer = {
	OfferId: string,
	Mode: VendorOfferMode,
	GiveId: string,
	GiveCount: number,
	ReceiveId: string,
	ReceiveCount: number,
}

export type VendorConfig = {
	Id: VendorId,
	Name: string,
	RoleTitle: string,
	AccentColor: Color3,
	Description: string,
	Offers: { VendorOffer },
}

export type VendorTradeFeedback = {
	Success: boolean,
	Message: string,
	VendorId: string?,
	OfferId: string?,
}

export type WeaponCategory = "Melee" | "Ranged"

export type HitZone = "Head" | "Torso" | "Limb"

export type WeaponConfig = {
	Category: WeaponCategory,
	Damage: number,
	MinDamage: number?,
	HeadshotMultiplier: number,
	Range: number,
	Cooldown: number,
	AmmoId: string?,
	ProjectileId: string?,
	DrawMinTime: number?,
	DrawFullTime: number?,
	RecoilPitchDeg: number?,
	RecoilYawPattern: { number }?,
	RecoilRecoveryRate: number?,
	BaseSpreadDeg: number?,
	MoveSpreadDeg: number?,
	AirSpreadDeg: number?,
	CrouchSpreadMultiplier: number?,
	MeleeConeHalfAngleDeg: number?,
	FalloffStartRatio: number?,
	MinFalloffMultiplier: number?,
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
	ImpactKind: ("Explosive" | "Direct" | "Emp" | "Smoke")?,
	Speed: number,
	MinSpeed: number?,
	MaxSpeed: number?,
	Gravity: number,
	MaxLifetime: number,
	BlastRadius: number,
	StructureDamage: number,
	PlayerDamage: number,
	Damage: number?,
	MinDamage: number?,
	HeadshotMultiplier: number?,
	MinFalloffMultiplier: number,
	EffectDuration: number?,
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
	DominantTier: BuildTier?,
	UsedDefenseCapacity: number?,
	MaxDefenseCapacity: number?,
	TurretCount: number?,
	TrapCount: number?,
	LootCategory: string?,
}

export type RaidIntelCard = RaidTargetInfo

export type RaidSessionState = {
	SessionId: string,
	AttackerUserId: number,
	TargetUserId: number,
	TargetName: string,
	TargetBaseTier: BaseTier,
	StartedAt: number,
	EndsAt: number,
	TcCaptured: boolean,
	TcHackProgress: number,
	TcHackActive: boolean,
	LivesLeft: number,
	MaxLives: number,
	Extracting: boolean,
	ExtractionEndsAt: number?,
	IsSelfRaid: boolean?,
}

export type TransferReason = "Extraction" | "ReturnToMap" | "StartRaid" | "RaidReturn" | "RaidDefense"

export type TransferPayload = {
	TransferId: string,
	UserId: number,
	Reason: TransferReason,
	SourcePlaceId: number,
	TargetPlaceId: number,
	IssuedAt: number,
	InventoryHash: string?,
	TargetBaseUserId: number?,
	MapKey: string?,
	LootItems: { ItemBatchEntry }?,
	RaidMetadata: { [string]: any }?,
	Consumed: boolean?,
	ConsumedAt: number?,
	ConsumedByJobId: string?,
}

export type TransferReceipt = {
	TransferId: string,
	UserId: number,
	Success: boolean,
	ProfileReleased: boolean,
	ProcessedAt: number,
	ErrorMessage: string?,
}

export type RaidIntelPool = {
	Tier: number,
	Targets: { RaidTargetInfo },
	FreeRefreshAt: number,
	RefreshCostScrap: number,
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
	ExtractionActive: boolean?,
	ExtractionTimeLeft: number?,
	ExtractionTotalTime: number?,
}

export type RaidDefenseReport = {
	RaiderUserId: number?,
	RaiderName: string,
	TargetTier: number,
	Defended: boolean,
	LivesSpent: number?,
	MaxLives: number?,
	RewardScrap: number?,
	DeathPoints: { DeathGhostPoint }?,
	Timestamp: number,
	BonusItems: { [string]: number }?,
	Summary: string,
}

export type NPCKind = "Guard" | "Animal"
export type NPCBehavior = "RangedHostile" | "MeleeHostile" | "PassiveFlee"
export type NPCState = "Patrol" | "Alert" | "Combat" | "Chase" | "Flee" | "Return"

export type NPCConfig = {
	Id: string,
	DisplayName: string,
	Kind: NPCKind,
	Behavior: NPCBehavior,
	MaxHealth: number,
	WalkSpeed: number,
	RunSpeed: number,
	DetectionRadius: number,
	ChaseRadius: number,
	AttackRange: number,
	Damage: number,
	AttackCooldown: number,
	BurstCount: number?,
	BurstInterval: number?,
	SpreadDeg: number?,
	ProjectileSpeed: number?,
	ProjectileGravity: number?,
	ReactionDelayMin: number?,
	ReactionDelayMax: number?,
	FirstShotSpreadMultiplier: number?,
	MagazineSize: number?,
	ReloadDuration: number?,
	BleedDuration: number?,
	BleedDps: number?,
	DefaultPatrolRadius: number,
	DefaultRespawnTime: number,
	LootTableId: string,
	PrimaryColor: Color3,
	SecondaryColor: Color3,
	AccentColor: Color3,
	Scale: number,
}

export type BallisticShotRequest = {
	Origin: Vector3,
	Direction: Vector3,
	ChargeRatio: number?,
	WeaponId: ItemId?,
	ClientTime: number?,
	ClientTimestamp: number?,
	TargetInstance: Instance?,
}

export type BallisticHitResult = {
	Hit: boolean,
	HitPosition: Vector3?,
	HitNormal: Vector3?,
	HitZone: HitZone?,
	TargetUserId: number?,
	TargetUid: string?,
	DamageDealt: number,
	Distance: number,
}

export type ExplosionRequest = {
	TargetUid: string,
	HitPosition: Vector3,
	ExplosiveId: ItemId?,
}

export type NetResult<T> = {
	Ok: boolean,
	Data: T?,
	ErrorCode: string?,
	Message: string?,
}

local VALID_MODULE_TYPES: { [string]: boolean } = table.freeze({
	foundation = true,
	triangle_foundation = true,
	wall = true,
	doorway = true,
	window_wall = true,
	roof = true,
	triangle_floor = true,
	square_stairs = true,
	triangle_stairs = true,
	storage_box = true,
	tool_cupboard = true,
	workbench_1 = true,
	workbench_2 = true,
	workbench_3 = true,
	research_table = true,
	assault_ladder = true,
	barricade = true,
	floor_spikes = true,
	landmine = true,
	shotgun_trap = true,
	auto_turret = true,
	hbhf_sensor = true,
	smart_door = true,
	TriangleFoundation = true,
	WindowWall = true,
	TriangleFloor = true,
	SquareStairs = true,
	TriangleStairs = true,
})

local VALID_BUILDING_TIERS: { [string]: boolean } = table.freeze({
	wood = true,
	stone = true,
	metal = true,
	armored = true,
})

local VALID_TRANSFER_REASONS: { [string]: boolean } = table.freeze({
	Extraction = true,
	ReturnToMap = true,
	StartRaid = true,
	RaidReturn = true,
	RaidDefense = true,
})

local DEFAULT_MAX_VECTOR_COORD = 1e6

local function isFiniteNumber(val: any): boolean
	return type(val) == "number" and val == val and val ~= math.huge and val ~= -math.huge
end

local function isValidInteger(val: any, minVal: number?, maxVal: number?): boolean
	if not isFiniteNumber(val) then
		return false
	end
	local num = val :: number
	if num % 1 ~= 0 then
		return false
	end
	if minVal ~= nil and num < minVal then
		return false
	end
	if maxVal ~= nil and num > maxVal then
		return false
	end
	return true
end

local function isValidString(val: any, minLen: number?, maxLen: number?): boolean
	if type(val) ~= "string" then
		return false
	end
	local len = string.len(val :: string)
	if minLen ~= nil and len < minLen then
		return false
	end
	if maxLen ~= nil and len > maxLen then
		return false
	end
	return true
end

local function isValidVector3(val: any, maxAbs: number?): boolean
	if typeof(val) ~= "Vector3" then
		return false
	end
	local v = val :: Vector3
	if not (isFiniteNumber(v.X) and isFiniteNumber(v.Y) and isFiniteNumber(v.Z)) then
		return false
	end
	local limit = maxAbs or DEFAULT_MAX_VECTOR_COORD
	return math.abs(v.X) <= limit and math.abs(v.Y) <= limit and math.abs(v.Z) <= limit
end

local function isValidInventorySlot(val: any): boolean
	if type(val) ~= "table" then
		return false
	end
	if not isValidString(val.Id, 1, 64) then
		return false
	end
	if not isValidInteger(val.Count, 1, 1000000) then
		return false
	end
	return true
end

local Types = {
	INVENTORY_SIZE = 30,
	HOTBAR_SIZE = 6,
	HANDS_POWER = 5,
	HANDS_COOLDOWN = 0.8,
	BASE_TOOL_MULTIPLIER = 1.0,
	MAX_GATHER_DISTANCE_SERVER = 14,
	MAX_GATHER_DISTANCE_CLIENT = 12,
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
	MAX_EXPLOSIVE_PLACE_DISTANCE = 12,
	RAID_DURATION = 300,
	CURRENT_SCHEMA_VERSION = 9,
	CURRENT_DATA_VERSION = 9,
	PING_DISTANCE_TOLERANCE = 2,
	MAX_BUILD_DISTANCE = 20,
	MAX_RAID_TERMINAL_DISTANCE = 24,
	MAX_PROJECTILE_LIFETIME = 10,
	MAX_ACTIVE_PROJECTILES_PER_PLAYER = 6,
}

function Types.IsFiniteNumber(val: any): boolean
	return isFiniteNumber(val)
end

function Types.IsValidInteger(val: any, minVal: number?, maxVal: number?): boolean
	return isValidInteger(val, minVal, maxVal)
end

function Types.IsValidString(val: any, minLen: number?, maxLen: number?): boolean
	return isValidString(val, minLen, maxLen)
end

function Types.IsValidVector3(val: any, maxAbs: number?): boolean
	return isValidVector3(val, maxAbs)
end

function Types.IsValidInventorySlot(val: any): boolean
	return isValidInventorySlot(val)
end

function Types.IsValidModuleType(val: any): boolean
	return type(val) == "string" and VALID_MODULE_TYPES[val :: string] == true
end

function Types.IsValidBuildingTier(val: any): boolean
	return type(val) == "string" and VALID_BUILDING_TIERS[val :: string] == true
end

function Types.IsValidShotRequest(val: any): boolean
	if type(val) ~= "table" then
		return false
	end
	if val.Damage ~= nil or val.Multiplier ~= nil or val.HitboxMultiplier ~= nil or val.HeadshotMultiplier ~= nil then
		return false
	end
	if not isValidVector3(val.Origin) or not isValidVector3(val.Direction) then
		return false
	end
	local dir = val.Direction :: Vector3
	if not isFiniteNumber(dir.Magnitude) or dir.Magnitude <= 0.01 then
		return false
	end
	if val.ChargeRatio ~= nil then
		if
			not isFiniteNumber(val.ChargeRatio)
			or (val.ChargeRatio :: number) < 0
			or (val.ChargeRatio :: number) > 1
		then
			return false
		end
	end
	if val.WeaponId ~= nil and not isValidString(val.WeaponId, 1, 64) then
		return false
	end
	if val.ClientTime ~= nil and (not isFiniteNumber(val.ClientTime) or (val.ClientTime :: number) < 0) then
		return false
	end
	if
		val.ClientTimestamp ~= nil and (not isFiniteNumber(val.ClientTimestamp) or (val.ClientTimestamp :: number) < 0)
	then
		return false
	end
	if val.TargetInstance ~= nil and typeof(val.TargetInstance) ~= "Instance" then
		return false
	end
	return true
end

function Types.IsValidExplosionRequest(val: any): boolean
	if type(val) ~= "table" then
		return false
	end
	if not isValidString(val.TargetUid, 1, 64) then
		return false
	end
	if not isValidVector3(val.HitPosition) then
		return false
	end
	if val.ExplosiveId ~= nil and not isValidString(val.ExplosiveId, 1, 64) then
		return false
	end
	return true
end

function Types.IsValidTransferPayload(val: any): boolean
	if type(val) ~= "table" then
		return false
	end
	if not isValidString(val.TransferId, 1, 64) then
		return false
	end
	if not isValidInteger(val.UserId, 1) then
		return false
	end
	if type(val.Reason) ~= "string" or VALID_TRANSFER_REASONS[val.Reason :: string] ~= true then
		return false
	end
	if not isValidInteger(val.SourcePlaceId, 0) or not isValidInteger(val.TargetPlaceId, 0) then
		return false
	end
	if not isFiniteNumber(val.IssuedAt) or (val.IssuedAt :: number) < 0 then
		return false
	end
	if val.TargetBaseUserId ~= nil and not isValidInteger(val.TargetBaseUserId) then
		return false
	end
	if val.MapKey ~= nil and not isValidString(val.MapKey, 1, 64) then
		return false
	end
	if val.InventoryHash ~= nil and not isValidString(val.InventoryHash, 1, 64) then
		return false
	end
	if val.LootItems ~= nil then
		if type(val.LootItems) ~= "table" then
			return false
		end
		for idx, item in val.LootItems do
			if not isValidInteger(idx, 1, 256) or not isValidInventorySlot(item) then
				return false
			end
		end
	end
	return true
end

function Types.IsValidBuildPlaceArgs(pieceType: any, position: any, rotY: any): boolean
	if not Types.IsValidModuleType(pieceType) then
		return false
	end
	if not isValidVector3(position) then
		return false
	end
	if not isFiniteNumber(rotY) then
		return false
	end
	return true
end

return Types
