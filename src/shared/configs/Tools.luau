--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage.Shared.Types)

export type ToolConfig = Types.ToolConfig

local Tools: { [string]: ToolConfig } = {
	hatchet = {
		Power = 25,
		Cooldown = 0.6,
		PreferredNodeType = "Tree",
		BonusMultiplier = 2.0,
	},
	pickaxe = {
		Power = 25,
		Cooldown = 0.7,
		PreferredNodeType = "Rock",
		BonusMultiplier = 2.0,
	},
	metal_hatchet = {
		Power = 35,
		Cooldown = 0.55,
		PreferredNodeType = "Tree",
		BonusMultiplier = 2.0,
	},
	building_plan = {
		Power = 5,
		Cooldown = 0.25,
		PreferredNodeType = "Build",
		BonusMultiplier = 1.0,
	},
	hammer = {
		Power = 5,
		Cooldown = 0.25,
		PreferredNodeType = "Build",
		BonusMultiplier = 1.0,
	},
}

return table.freeze(Tools)
