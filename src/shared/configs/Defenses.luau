--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage.Shared.Config)
local Types = require(ReplicatedStorage.Shared.Types)

export type DefenseConfig = Types.DefenseConfig

local Configs: { [string]: DefenseConfig } = table.freeze({
	floor_spikes = table.freeze({
		Id = "floor_spikes" :: Types.BuildPieceType,
		Name = "Floor Spikes",
		CapacityCost = Config.DefenseCapacity.Costs.floor_spikes,
		AllowedMount = "Floor" :: Types.DefenseAllowedMount,
		BaseHp = 100,
		Range = 4.2,
		Cooldown = 1.0,
		Damage = 18,
		SlowMultiplier = 0.55,
		SlowDuration = 1.5,
		SelfDamageOnTrigger = 10,
	}),
	landmine = table.freeze({
		Id = "landmine" :: Types.BuildPieceType,
		Name = "Landmine",
		CapacityCost = Config.DefenseCapacity.Costs.landmine,
		AllowedMount = "Floor" :: Types.DefenseAllowedMount,
		BaseHp = 40,
		Range = 4.5,
		Cooldown = 0.5,
		Damage = 0,
		ExplosionRadius = 14,
		ExplosionStructureDamage = 100,
		ExplosionPlayerDamage = 85,
	}),
	shotgun_trap = table.freeze({
		Id = "shotgun_trap" :: Types.BuildPieceType,
		Name = "Shotgun Trap",
		CapacityCost = Config.DefenseCapacity.Costs.shotgun_trap,
		AllowedMount = "WallOrCeiling" :: Types.DefenseAllowedMount,
		BaseHp = 200,
		Range = 12,
		ConeHalfAngleDeg = 35,
		Cooldown = 2.5,
		PelletCount = 6,
		SpreadDeg = 10,
		Damage = 12,
		AmmoId = "shotgun_shell",
		AmmoSlots = 3,
	}),
	auto_turret = table.freeze({
		Id = "auto_turret" :: Types.BuildPieceType,
		Name = "Auto Turret",
		CapacityCost = Config.DefenseCapacity.Costs.auto_turret,
		AllowedMount = "Floor" :: Types.DefenseAllowedMount,
		BaseHp = 500,
		Range = 40,
		LockOnDuration = 0.8,
		Cooldown = 0.9,
		BurstCount = 3,
		BurstInterval = 0.14,
		Damage = 14,
		AmmoId = "pistol_ammo",
		AmmoSlots = 4,
		ProjectileSpeed = 190,
		ProjectileGravity = 12,
	}),
	hbhf_sensor = table.freeze({
		Id = "hbhf_sensor" :: Types.BuildPieceType,
		Name = "HBHF Sensor",
		CapacityCost = Config.DefenseCapacity.Costs.hbhf_sensor,
		AllowedMount = "WallOrCeiling" :: Types.DefenseAllowedMount,
		BaseHp = 100,
		Range = 16,
		ConeHalfAngleDeg = 75,
		Cooldown = 0.5,
		Damage = 0,
		SignalRadius = 24,
	}),
	smart_door = table.freeze({
		Id = "smart_door" :: Types.BuildPieceType,
		Name = "Smart Door",
		CapacityCost = Config.DefenseCapacity.Costs.smart_door,
		AllowedMount = "Doorway" :: Types.DefenseAllowedMount,
		BaseHp = 800,
		Range = 0,
		Cooldown = 0.5,
		Damage = 0,
		OpenDuration = 5.0,
	}),
})

local Defenses = {}
Defenses.Configs = Configs
Defenses.floor_spikes = Configs.floor_spikes
Defenses.landmine = Configs.landmine
Defenses.shotgun_trap = Configs.shotgun_trap
Defenses.auto_turret = Configs.auto_turret
Defenses.hbhf_sensor = Configs.hbhf_sensor
Defenses.smart_door = Configs.smart_door

function Defenses.Get(pieceType: string): DefenseConfig?
	return Configs[pieceType]
end

function Defenses.GetCapacityLimit(baseTier: number): number
	local clampedTier = math.clamp(math.floor(baseTier), 0, 3)
	local limits = Config.DefenseCapacity.MaxByBaseTier :: { [number]: number }
	return limits[clampedTier] or 30
end

return table.freeze(Defenses)
