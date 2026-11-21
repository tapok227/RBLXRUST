--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage.Shared.Types)

export type ItemConfig = Types.ItemConfig

local Items: { [string]: ItemConfig } = {
	wood = {
		Name = "Wood",
		Type = "Resource",
		MaxStack = 1000,
	},
	stone = {
		Name = "Stone",
		Type = "Resource",
		MaxStack = 1000,
	},
	metal_ore = {
		Name = "Metal Ore",
		Type = "Resource",
		MaxStack = 500,
	},
	cloth = {
		Name = "Cloth",
		Type = "Resource",
		MaxStack = 200,
	},
	hatchet = {
		Name = "Hatchet",
		Type = "Tool",
		MaxStack = 1,
	},
	pickaxe = {
		Name = "Pickaxe",
		Type = "Tool",
		MaxStack = 1,
	},
	bandage = {
		Name = "Bandage",
		Type = "Consumable",
		MaxStack = 10,
	},
	cooked_meat = {
		Name = "Cooked Meat",
		Type = "Consumable",
		MaxStack = 10,
	},
	water_bottle = {
		Name = "Water Bottle",
		Type = "Consumable",
		MaxStack = 5,
	},
	workbench_1 = {
		Name = "Workbench Lv.1",
		Type = "Consumable",
		MaxStack = 1,
	},
	spear = {
		Name = "Wooden Spear",
		Type = "Tool",
		MaxStack = 1,
	},
	metal_hatchet = {
		Name = "Metal Hatchet",
		Type = "Tool",
		MaxStack = 1,
	},
}

return table.freeze(Items)
