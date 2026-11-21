--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage.Shared.Types)

export type NodeConfig = Types.NodeConfig

local Nodes: { [string]: NodeConfig } = {
	tree = {
		Name = "Pine Tree",
		Category = "Tree",
		MaxHp = 100,
		ResourceId = "wood",
		YieldPerHit = 15,
		BonusOnDestroy = 40,
		RespawnTime = 30,
	},
	stone_node = {
		Name = "Stone Node",
		Category = "Rock",
		MaxHp = 120,
		ResourceId = "stone",
		YieldPerHit = 15,
		BonusOnDestroy = 40,
		RespawnTime = 45,
	},
	metal_node = {
		Name = "Metal Vein",
		Category = "Ore",
		MaxHp = 150,
		ResourceId = "metal_ore",
		YieldPerHit = 10,
		BonusOnDestroy = 30,
		RespawnTime = 60,
	},
}

return table.freeze(Nodes)
