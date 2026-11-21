--!strict

export type ItemType = "Resource" | "Tool" | "Consumable"

export type ItemConfig = {
	Name: string,
	Type: ItemType,
	MaxStack: number,
}

export type Slot = {
	Id: string,
	Count: number,
}

export type Inventory = { [number]: Slot? }

export type PlayerData = {
	Version: number,
	Inventory: Inventory,
}

export type ItemBatchEntry = {
	Id: string,
	Count: number,
}

export type ToolCategory = "Tree" | "Rock" | "Ore"

export type ToolConfig = {
	Power: number,
	Cooldown: number,
	PreferredNodeType: ToolCategory,
	BonusMultiplier: number,
}

export type NodeType = "tree" | "stone_node" | "metal_node"

export type NodeConfig = {
	Name: string,
	Category: ToolCategory,
	MaxHp: number,
	ResourceId: string,
	YieldPerHit: number,
	BonusOnDestroy: number,
	RespawnTime: number,
}

export type NodeClientState = {
	Hp: number,
	MaxHp: number,
	Depleted: boolean,
}

export type Ingredient = {
	Id: string,
	Count: number,
}

export type RecipeConfig = {
	Id: string,
	ResultId: string,
	ResultCount: number,
	CraftTime: number,
	Station: string?,
	Ingredients: { Ingredient },
}

export type CraftingState = {
	RecipeId: string,
	StartTime: number,
	EndTime: number,
}

local Types = {
	INVENTORY_SIZE = 30,
	HOTBAR_SIZE = 6,
	HANDS_POWER = 5,
	HANDS_COOLDOWN = 0.8,
	BASE_TOOL_MULTIPLIER = 1.0,
	MAX_GATHER_DISTANCE_SERVER = 14,
	MAX_GATHER_DISTANCE_CLIENT = 12,
	MAX_STATION_DISTANCE = 14,
}

return Types
