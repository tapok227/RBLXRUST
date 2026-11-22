--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage.Shared.Types)

export type ProjectileConfig = Types.ProjectileConfig

local Projectiles: { [string]: ProjectileConfig } = {
	rocket = table.freeze({
		Id = "rocket",
		ImpactKind = "Explosive",
		Speed = 110,
		Gravity = 28,
		MaxLifetime = 10,
		BlastRadius = 15,
		StructureDamage = 250,
		PlayerDamage = 110,
		MinFalloffMultiplier = 0.25,
	}),
	arrow = table.freeze({
		Id = "arrow",
		ImpactKind = "Direct",
		Speed = 145,
		MinSpeed = 65,
		MaxSpeed = 145,
		Gravity = 48,
		MaxLifetime = 6,
		BlastRadius = 0,
		StructureDamage = 12,
		PlayerDamage = 55,
		Damage = 55,
		MinDamage = 18,
		HeadshotMultiplier = 2.0,
		MinFalloffMultiplier = 1.0,
	}),
	emp_grenade = table.freeze({
		Id = "emp_grenade",
		ImpactKind = "Emp" :: "Emp",
		Speed = 68,
		Gravity = 52,
		MaxLifetime = 5,
		BlastRadius = 18,
		StructureDamage = 0,
		PlayerDamage = 0,
		MinFalloffMultiplier = 1.0,
		EffectDuration = 10,
	}),
	smoke_grenade = table.freeze({
		Id = "smoke_grenade",
		ImpactKind = "Smoke" :: "Smoke",
		Speed = 68,
		Gravity = 52,
		MaxLifetime = 5,
		BlastRadius = 11,
		StructureDamage = 0,
		PlayerDamage = 0,
		MinFalloffMultiplier = 1.0,
		EffectDuration = 15,
	}),
}

return table.freeze(Projectiles)
