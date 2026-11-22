--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage.Shared.Types)

export type ProjectileConfig = Types.ProjectileConfig

local Projectiles: { [string]: ProjectileConfig } = {
	rocket = table.freeze({
		Id = "rocket",
		Speed = 110,
		Gravity = 28,
		MaxLifetime = 10,
		BlastRadius = 15,
		StructureDamage = 300,
		PlayerDamage = 110,
		MinFalloffMultiplier = 0.25,
	}),
}

return table.freeze(Projectiles)
