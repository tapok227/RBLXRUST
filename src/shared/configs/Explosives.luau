--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage.Shared.Types)

export type ExplosiveConfig = Types.ExplosiveConfig

local Explosives: { [string]: ExplosiveConfig } = {
	satchel_charge = table.freeze({
		StructureDamage = 180,
		Radius = 14,
		FuseTime = 4.0,
	}),
	c4_charge = table.freeze({
		StructureDamage = 550,
		Radius = 16,
		FuseTime = 5.0,
	}),
}

return table.freeze(Explosives)
