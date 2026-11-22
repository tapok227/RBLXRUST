--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage.Shared.Types)

export type LootDropEntry = Types.LootDropEntry
export type LootTableConfig = Types.LootTableConfig

local LootTables: { [string]: LootTableConfig } = {
	wooden_crate = {
		Rolls = 2,
		RespawnTime = 90,
		Items = {
			{ Id = "wood", Weight = 35, MinCount = 50, MaxCount = 150 },
			{ Id = "stone", Weight = 30, MinCount = 40, MaxCount = 120 },
			{ Id = "cloth", Weight = 25, MinCount = 10, MaxCount = 25 },
			{ Id = "bandage", Weight = 20, MinCount = 1, MaxCount = 3 },
			{ Id = "water_bottle", Weight = 20, MinCount = 1, MaxCount = 2 },
			{ Id = "scrap", Weight = 15, MinCount = 5, MaxCount = 15 },
		},
	},
	military_crate = {
		Rolls = 3,
		RespawnTime = 180,
		Items = {
			{ Id = "scrap", Weight = 35, MinCount = 15, MaxCount = 40 },
			{ Id = "metal_ore", Weight = 25, MinCount = 30, MaxCount = 80 },
			{ Id = "pistol_ammo", Weight = 25, MinCount = 6, MaxCount = 18 },
			{ Id = "bandage", Weight = 20, MinCount = 2, MaxCount = 4 },
			{ Id = "pipe_pistol", Weight = 10, MinCount = 1, MaxCount = 1 },
			{ Id = "tech_parts", Weight = 10, MinCount = 1, MaxCount = 3 },
		},
	},
	airdrop = {
		Rolls = 4,
		RespawnTime = 0,
		Items = {
			{ Id = "scrap", Weight = 40, MinCount = 50, MaxCount = 100 },
			{ Id = "tech_parts", Weight = 30, MinCount = 3, MaxCount = 8 },
			{ Id = "pipe_pistol", Weight = 25, MinCount = 1, MaxCount = 1 },
			{ Id = "pistol_ammo", Weight = 35, MinCount = 16, MaxCount = 32 },
			{ Id = "hunting_bow", Weight = 20, MinCount = 1, MaxCount = 1 },
			{ Id = "cooked_meat", Weight = 25, MinCount = 3, MaxCount = 6 },
			{ Id = "rocket", Weight = 15, MinCount = 1, MaxCount = 3 },
			{ Id = "rocket_launcher", Weight = 8, MinCount = 1, MaxCount = 1 },
		},
	},
}

return table.freeze(LootTables)
