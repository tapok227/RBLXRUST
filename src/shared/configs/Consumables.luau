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
		Stamina = 25,
		UseCooldown = 1.0,
		BuffDuration = 300,
		MaxStaminaBonus = 1.0,
	},
	raw_meat = {
		Health = -8,
		Hunger = 10,
		Thirst = -4,
		UseCooldown = 1.0,
	},
	water_bottle = {
		Health = 0,
		Hunger = 0,
		Thirst = 40,
		Stamina = 20,
		UseCooldown = 1.0,
	},
	wild_berries = {
		Health = 2,
		Hunger = 10,
		Thirst = 12,
		UseCooldown = 1.0,
	},
	mushrooms = {
		Health = 2,
		Hunger = 12,
		Thirst = 5,
		UseCooldown = 1.0,
	},
	meat_stew = {
		Health = 20,
		Hunger = 60,
		Thirst = 25,
		Stamina = 40,
		UseCooldown = 1.5,
		BuffDuration = 900,
		MaxStaminaBonus = 1.1,
	},
	mushroom_stew = {
		Health = 15,
		Hunger = 50,
		Thirst = 30,
		Stamina = 40,
		UseCooldown = 1.5,
		BuffDuration = 900,
		MaxStaminaBonus = 1.1,
	},
}

return table.freeze(Consumables)
