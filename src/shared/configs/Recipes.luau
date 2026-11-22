--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage.Shared.Types)

export type RecipeConfig = Types.RecipeConfig

local Recipes: { [string]: RecipeConfig } = {
	craft_bandage = {
		Id = "craft_bandage",
		ResultId = "bandage",
		ResultCount = 1,
		CraftTime = 2,
		Station = nil,
		Ingredients = {
			{ Id = "cloth", Count = 2 },
		},
	},
	craft_water_bottle = {
		Id = "craft_water_bottle",
		ResultId = "water_bottle",
		ResultCount = 1,
		CraftTime = 2,
		Station = nil,
		Ingredients = {
			{ Id = "cloth", Count = 1 },
			{ Id = "stone", Count = 5 },
		},
	},
	craft_hatchet = {
		Id = "craft_hatchet",
		ResultId = "hatchet",
		ResultCount = 1,
		CraftTime = 4,
		Station = nil,
		Ingredients = {
			{ Id = "wood", Count = 50 },
			{ Id = "stone", Count = 25 },
		},
	},
	craft_pickaxe = {
		Id = "craft_pickaxe",
		ResultId = "pickaxe",
		ResultCount = 1,
		CraftTime = 4,
		Station = nil,
		Ingredients = {
			{ Id = "wood", Count = 50 },
			{ Id = "stone", Count = 25 },
		},
	},
	craft_workbench_1 = {
		Id = "craft_workbench_1",
		ResultId = "workbench_1",
		ResultCount = 1,
		CraftTime = 5,
		Station = nil,
		Ingredients = {
			{ Id = "wood", Count = 100 },
			{ Id = "stone", Count = 50 },
		},
	},
	craft_spear = {
		Id = "craft_spear",
		ResultId = "spear",
		ResultCount = 1,
		CraftTime = 5,
		Station = "workbench_1",
		Ingredients = {
			{ Id = "wood", Count = 80 },
			{ Id = "cloth", Count = 10 },
		},
	},
	craft_metal_hatchet = {
		Id = "craft_metal_hatchet",
		ResultId = "metal_hatchet",
		ResultCount = 1,
		CraftTime = 6,
		Station = "workbench_1",
		Ingredients = {
			{ Id = "wood", Count = 60 },
			{ Id = "metal_ore", Count = 30 },
		},
	},
	craft_hunting_bow = {
		Id = "craft_hunting_bow",
		ResultId = "hunting_bow",
		ResultCount = 1,
		CraftTime = 5,
		Station = "workbench_1",
		Ingredients = {
			{ Id = "wood", Count = 60 },
			{ Id = "cloth", Count = 15 },
		},
	},
	craft_arrow = {
		Id = "craft_arrow",
		ResultId = "arrow",
		ResultCount = 4,
		CraftTime = 2,
		Station = nil,
		Ingredients = {
			{ Id = "wood", Count = 10 },
			{ Id = "stone", Count = 5 },
		},
	},
	craft_pipe_pistol = {
		Id = "craft_pipe_pistol",
		ResultId = "pipe_pistol",
		ResultCount = 1,
		CraftTime = 6,
		Station = "workbench_1",
		Ingredients = {
			{ Id = "metal_ore", Count = 40 },
			{ Id = "wood", Count = 30 },
		},
	},
	craft_pistol_ammo = {
		Id = "craft_pistol_ammo",
		ResultId = "pistol_ammo",
		ResultCount = 6,
		CraftTime = 3,
		Station = "workbench_1",
		Ingredients = {
			{ Id = "metal_ore", Count = 10 },
		},
	},
	craft_satchel_charge = {
		Id = "craft_satchel_charge",
		ResultId = "satchel_charge",
		ResultCount = 1,
		CraftTime = 6,
		Station = "workbench_1",
		Ingredients = {
			{ Id = "scrap", Count = 25 },
			{ Id = "cloth", Count = 10 },
			{ Id = "metal_ore", Count = 20 },
		},
	},
	craft_c4_charge = {
		Id = "craft_c4_charge",
		ResultId = "c4_charge",
		ResultCount = 1,
		CraftTime = 10,
		Station = "workbench_1",
		Ingredients = {
			{ Id = "tech_parts", Count = 4 },
			{ Id = "scrap", Count = 60 },
			{ Id = "metal_ore", Count = 50 },
		},
	},
	craft_rocket_launcher = {
		Id = "craft_rocket_launcher",
		ResultId = "rocket_launcher",
		ResultCount = 1,
		CraftTime = 12,
		Station = "workbench_1",
		Ingredients = {
			{ Id = "tech_parts", Count = 5 },
			{ Id = "scrap", Count = 80 },
			{ Id = "metal_ore", Count = 60 },
		},
	},
	craft_rocket = {
		Id = "craft_rocket",
		ResultId = "rocket",
		ResultCount = 1,
		CraftTime = 5,
		Station = "workbench_1",
		Ingredients = {
			{ Id = "scrap", Count = 20 },
			{ Id = "metal_ore", Count = 30 },
			{ Id = "cloth", Count = 5 },
		},
	},
}

return table.freeze(Recipes)
