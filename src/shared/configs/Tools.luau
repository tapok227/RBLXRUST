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
}

return table.freeze(Tools)
