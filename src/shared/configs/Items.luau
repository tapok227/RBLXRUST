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
	wooden_spear = {
		Name = "Wooden Spear",
		Type = "Tool",
		MaxStack = 1,
	},
	hunting_bow = {
		Name = "Hunting Bow",
		Type = "Tool",
		MaxStack = 1,
	},
	arrow = {
		Name = "Wooden Arrow",
		Type = "Resource",
		MaxStack = 64,
	},
	pipe_pistol = {
		Name = "Pipe Pistol",
		Type = "Tool",
		MaxStack = 1,
	},
	pistol_ammo = {
		Name = "Pistol Ammo",
		Type = "Resource",
		MaxStack = 64,
	},
	scrap = {
		Name = "Scrap",
		Type = "Resource",
		MaxStack = 500,
	},
	tech_parts = {
		Name = "Tech Parts",
		Type = "Resource",
		MaxStack = 50,
	},
	satchel_charge = {
		Name = "Satchel Charge",
		Type = "Tool",
		MaxStack = 10,
	},
	c4_charge = {
		Name = "Timed C4",
		Type = "Tool",
		MaxStack = 5,
	},
	rocket_launcher = {
		Name = "Rocket Launcher",
		Type = "Tool",
		MaxStack = 1,
	},
	rocket = {
		Name = "Rocket",
		Type = "Resource",
		MaxStack = 10,
	},
	building_plan = {
		Name = "Building Plan",
		Type = "Tool",
		MaxStack = 1,
	},
	hammer = {
		Name = "Hammer",
		Type = "Tool",
		MaxStack = 1,
	},
	high_quality_metal = {
		Name = "High Quality Metal",
		Type = "Resource",
		MaxStack = 100,
	},
}

return table.freeze(Items)
