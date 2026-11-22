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
		StructureDamage = 300,
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
}

return table.freeze(Projectiles)
