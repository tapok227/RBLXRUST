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
	raw_meat = {
		Name = "Raw Meat",
		Type = "Consumable",
		MaxStack = 10,
	},
	animal_fat = {
		Name = "Animal Fat",
		Type = "Resource",
		MaxStack = 200,
	},
	bone = {
		Name = "Bone Fragments",
		Type = "Resource",
		MaxStack = 200,
	},
	water_bottle = {
		Name = "Water Bottle",
		Type = "Consumable",
		MaxStack = 5,
	},
	wild_berries = {
		Name = "Wild Berries",
		Type = "Consumable",
		MaxStack = 20,
	},
	mushrooms = {
		Name = "Mushrooms",
		Type = "Consumable",
		MaxStack = 20,
	},
	meat_stew = {
		Name = "Hearty Meat Stew",
		Type = "Consumable",
		MaxStack = 5,
	},
	mushroom_stew = {
		Name = "Forest Mushroom Stew",
		Type = "Consumable",
		MaxStack = 5,
	},
	workbench_1 = {
		Name = "Workbench Lv.1",
		Type = "Tool",
		MaxStack = 1,
	},
	workbench_2 = {
		Name = "Workbench Lv.2",
		Type = "Tool",
		MaxStack = 1,
	},
	workbench_3 = {
		Name = "Workbench Lv.3",
		Type = "Tool",
		MaxStack = 1,
	},
	tool_cupboard = {
		Name = "Tool Cupboard",
		Type = "Tool",
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
	emp_grenade = {
		Name = "EMP Grenade",
		Type = "Tool",
		MaxStack = 5,
	},
	smoke_grenade = {
		Name = "Smoke Grenade",
		Type = "Tool",
		MaxStack = 5,
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
	repair_hammer = {
		Name = "Repair Hammer",
		Type = "Tool",
		MaxStack = 1,
	},
	high_quality_metal = {
		Name = "High Quality Metal",
		Type = "Resource",
		MaxStack = 100,
	},
	shotgun_shell = {
		Name = "Shotgun Shell",
		Type = "Resource",
		MaxStack = 32,
	},
	floor_spikes = {
		Name = "Floor Spikes",
		Type = "Tool",
		MaxStack = 5,
	},
	landmine = {
		Name = "Landmine",
		Type = "Tool",
		MaxStack = 5,
	},
	shotgun_trap = {
		Name = "Shotgun Trap",
		Type = "Tool",
		MaxStack = 3,
	},
	auto_turret = {
		Name = "Auto Turret",
		Type = "Tool",
		MaxStack = 2,
	},
	hbhf_sensor = {
		Name = "HBHF Sensor",
		Type = "Tool",
		MaxStack = 3,
	},
	smart_door = {
		Name = "Smart Door",
		Type = "Tool",
		MaxStack = 3,
	},
	research_table = {
		Name = "Research Table",
		Type = "Tool",
		MaxStack = 1,
	},
	bp_metal_hatchet = {
		Name = "Blueprint: Metal Hatchet",
		Type = "Blueprint",
		MaxStack = 1,
	},
	bp_pipe_pistol = {
		Name = "Blueprint: Pipe Pistol",
		Type = "Blueprint",
		MaxStack = 1,
	},
	bp_pistol_ammo = {
		Name = "Blueprint: Pistol Ammo",
		Type = "Blueprint",
		MaxStack = 1,
	},
	bp_floor_spikes = {
		Name = "Blueprint: Floor Spikes",
		Type = "Blueprint",
		MaxStack = 1,
	},
	bp_satchel_charge = {
		Name = "Blueprint: Satchel Charge",
		Type = "Blueprint",
		MaxStack = 1,
	},
	bp_shotgun_shell = {
		Name = "Blueprint: Shotgun Shell",
		Type = "Blueprint",
		MaxStack = 1,
	},
	bp_landmine = {
		Name = "Blueprint: Landmine",
		Type = "Blueprint",
		MaxStack = 1,
	},
	bp_shotgun_trap = {
		Name = "Blueprint: Shotgun Trap",
		Type = "Blueprint",
		MaxStack = 1,
	},
	bp_rocket = {
		Name = "Blueprint: Rocket",
		Type = "Blueprint",
		MaxStack = 1,
	},
	bp_c4_charge = {
		Name = "Blueprint: Timed C4",
		Type = "Blueprint",
		MaxStack = 1,
	},
	bp_rocket_launcher = {
		Name = "Blueprint: Rocket Launcher",
		Type = "Blueprint",
		MaxStack = 1,
	},
	bp_auto_turret = {
		Name = "Blueprint: Auto Turret",
		Type = "Blueprint",
		MaxStack = 1,
	},
}

return table.freeze(Items)
