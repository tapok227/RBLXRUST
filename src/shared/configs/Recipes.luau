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
}

return table.freeze(Recipes)
