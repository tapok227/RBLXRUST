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
	npc_rt_guard = {
		Rolls = 3,
		RespawnTime = 0,
		Items = {
			{ Id = "scrap", Weight = 35, MinCount = 15, MaxCount = 35 },
			{ Id = "pistol_ammo", Weight = 30, MinCount = 8, MaxCount = 18 },
			{ Id = "shotgun_shell", Weight = 18, MinCount = 4, MaxCount = 10 },
			{ Id = "bandage", Weight = 25, MinCount = 1, MaxCount = 3 },
			{ Id = "tech_parts", Weight = 15, MinCount = 1, MaxCount = 2 },
			{ Id = "high_quality_metal", Weight = 12, MinCount = 3, MaxCount = 8 },
		},
	},
	npc_rt_scientist = {
		Rolls = 4,
		RespawnTime = 0,
		Items = {
			{ Id = "scrap", Weight = 35, MinCount = 25, MaxCount = 55 },
			{ Id = "tech_parts", Weight = 30, MinCount = 1, MaxCount = 4 },
			{ Id = "high_quality_metal", Weight = 20, MinCount = 5, MaxCount = 12 },
			{ Id = "pistol_ammo", Weight = 25, MinCount = 10, MaxCount = 24 },
			{ Id = "bandage", Weight = 25, MinCount = 2, MaxCount = 4 },
			{ Id = "water_bottle", Weight = 15, MinCount = 1, MaxCount = 2 },
		},
	},
	animal_deer = {
		Rolls = 3,
		RespawnTime = 0,
		Items = {
			{ Id = "raw_meat", Weight = 45, MinCount = 2, MaxCount = 4 },
			{ Id = "cloth", Weight = 25, MinCount = 8, MaxCount = 16 },
			{ Id = "bone", Weight = 20, MinCount = 6, MaxCount = 12 },
			{ Id = "animal_fat", Weight = 15, MinCount = 4, MaxCount = 8 },
		},
	},
	animal_boar = {
		Rolls = 3,
		RespawnTime = 0,
		Items = {
			{ Id = "raw_meat", Weight = 40, MinCount = 2, MaxCount = 4 },
			{ Id = "animal_fat", Weight = 30, MinCount = 8, MaxCount = 16 },
			{ Id = "cloth", Weight = 18, MinCount = 6, MaxCount = 14 },
			{ Id = "bone", Weight = 18, MinCount = 5, MaxCount = 10 },
		},
	},
	animal_wolf = {
		Rolls = 3,
		RespawnTime = 0,
		Items = {
			{ Id = "raw_meat", Weight = 35, MinCount = 2, MaxCount = 4 },
			{ Id = "cloth", Weight = 28, MinCount = 10, MaxCount = 20 },
			{ Id = "animal_fat", Weight = 22, MinCount = 6, MaxCount = 14 },
			{ Id = "bone", Weight = 22, MinCount = 8, MaxCount = 16 },
		},
	},
	animal_bear = {
		Rolls = 4,
		RespawnTime = 0,
		Items = {
			{ Id = "raw_meat", Weight = 40, MinCount = 4, MaxCount = 7 },
			{ Id = "animal_fat", Weight = 35, MinCount = 14, MaxCount = 26 },
			{ Id = "cloth", Weight = 25, MinCount = 15, MaxCount = 28 },
			{ Id = "bone", Weight = 25, MinCount = 12, MaxCount = 22 },
		},
	},
}

return table.freeze(LootTables)
