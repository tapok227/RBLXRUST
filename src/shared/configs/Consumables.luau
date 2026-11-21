--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage.Shared.Types)

export type ConsumableConfig = Types.ConsumableConfig

local Consumables: { [string]: ConsumableConfig } = {
	bandage = {
		Health = 25,
		Hunger = 0,
		Thirst = 0,
		UseCooldown = 1.5,
	},
	cooked_meat = {
		Health = 10,
		Hunger = 35,
		Thirst = -5,
		UseCooldown = 1.0,
	},
	water_bottle = {
		Health = 0,
		Hunger = 0,
		Thirst = 40,
		UseCooldown = 1.0,
	},
}

return table.freeze(Consumables)
