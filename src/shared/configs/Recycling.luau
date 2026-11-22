--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage.Shared.Types)

export type RecycleOutputEntry = Types.RecycleOutputEntry
export type RecycleEntry = {
	BatchSize: number,
	Outputs: { RecycleOutputEntry },
}

local Entries: { [string]: RecycleEntry } = table.freeze({
	-- Components & gear found on RT
	tech_parts = table.freeze({
		BatchSize = 1,
		Outputs = table.freeze({
			table.freeze({ Id = "scrap", Count = 20 }),
			table.freeze({ Id = "high_quality_metal", Count = 2 }),
		}),
	}),
	bandage = table.freeze({
		BatchSize = 1,
		Outputs = table.freeze({
			table.freeze({ Id = "cloth", Count = 1 }),
		}),
	}),

	-- Tools & melee
	hatchet = table.freeze({
		BatchSize = 1,
		Outputs = table.freeze({
			table.freeze({ Id = "wood", Count = 25 }),
			table.freeze({ Id = "stone", Count = 12 }),
		}),
	}),
	pickaxe = table.freeze({
		BatchSize = 1,
		Outputs = table.freeze({
			table.freeze({ Id = "wood", Count = 25 }),
			table.freeze({ Id = "stone", Count = 12 }),
		}),
	}),
	metal_hatchet = table.freeze({
		BatchSize = 1,
		Outputs = table.freeze({
			table.freeze({ Id = "wood", Count = 30 }),
			table.freeze({ Id = "metal_ore", Count = 15 }),
			table.freeze({ Id = "scrap", Count = 5 }),
		}),
	}),
	spear = table.freeze({
		BatchSize = 1,
		Outputs = table.freeze({
			table.freeze({ Id = "wood", Count = 40 }),
			table.freeze({ Id = "cloth", Count = 5 }),
		}),
	}),

	-- Weapons
	hunting_bow = table.freeze({
		BatchSize = 1,
		Outputs = table.freeze({
			table.freeze({ Id = "wood", Count = 30 }),
			table.freeze({ Id = "cloth", Count = 8 }),
		}),
	}),
	pipe_pistol = table.freeze({
		BatchSize = 1,
		Outputs = table.freeze({
			table.freeze({ Id = "metal_ore", Count = 20 }),
			table.freeze({ Id = "wood", Count = 15 }),
			table.freeze({ Id = "scrap", Count = 10 }),
		}),
	}),
	rocket_launcher = table.freeze({
		BatchSize = 1,
		Outputs = table.freeze({
			table.freeze({ Id = "scrap", Count = 40 }),
			table.freeze({ Id = "metal_ore", Count = 30 }),
			table.freeze({ Id = "high_quality_metal", Count = 8 }),
		}),
	}),

	-- Ammo
	arrow = table.freeze({
		BatchSize = 4,
		Outputs = table.freeze({
			table.freeze({ Id = "wood", Count = 5 }),
			table.freeze({ Id = "stone", Count = 2 }),
		}),
	}),
	pistol_ammo = table.freeze({
		BatchSize = 6,
		Outputs = table.freeze({
			table.freeze({ Id = "metal_ore", Count = 5 }),
			table.freeze({ Id = "scrap", Count = 2 }),
		}),
	}),
	shotgun_shell = table.freeze({
		BatchSize = 3,
		Outputs = table.freeze({
			table.freeze({ Id = "metal_ore", Count = 6 }),
			table.freeze({ Id = "scrap", Count = 2 }),
		}),
	}),

	-- Explosives
	satchel_charge = table.freeze({
		BatchSize = 1,
		Outputs = table.freeze({
			table.freeze({ Id = "scrap", Count = 10 }),
			table.freeze({ Id = "cloth", Count = 5 }),
			table.freeze({ Id = "metal_ore", Count = 12 }),
		}),
	}),
	rocket = table.freeze({
		BatchSize = 1,
		Outputs = table.freeze({
			table.freeze({ Id = "scrap", Count = 12 }),
			table.freeze({ Id = "metal_ore", Count = 18 }),
			table.freeze({ Id = "high_quality_metal", Count = 2 }),
		}),
	}),
	c4_charge = table.freeze({
		BatchSize = 1,
		Outputs = table.freeze({
			table.freeze({ Id = "scrap", Count = 25 }),
			table.freeze({ Id = "metal_ore", Count = 25 }),
			table.freeze({ Id = "high_quality_metal", Count = 4 }),
		}),
	}),

	-- Traps & Defenses
	floor_spikes = table.freeze({
		BatchSize = 1,
		Outputs = table.freeze({
			table.freeze({ Id = "wood", Count = 30 }),
			table.freeze({ Id = "metal_ore", Count = 10 }),
		}),
	}),
	landmine = table.freeze({
		BatchSize = 1,
		Outputs = table.freeze({
			table.freeze({ Id = "metal_ore", Count = 18 }),
			table.freeze({ Id = "scrap", Count = 10 }),
		}),
	}),
	shotgun_trap = table.freeze({
		BatchSize = 1,
		Outputs = table.freeze({
			table.freeze({ Id = "wood", Count = 25 }),
			table.freeze({ Id = "metal_ore", Count = 30 }),
			table.freeze({ Id = "scrap", Count = 12 }),
		}),
	}),
	auto_turret = table.freeze({
		BatchSize = 1,
		Outputs = table.freeze({
			table.freeze({ Id = "high_quality_metal", Count = 8 }),
			table.freeze({ Id = "scrap", Count = 30 }),
			table.freeze({ Id = "metal_ore", Count = 40 }),
		}),
	}),

	-- Deployables
	workbench_1 = table.freeze({
		BatchSize = 1,
		Outputs = table.freeze({
			table.freeze({ Id = "wood", Count = 50 }),
			table.freeze({ Id = "stone", Count = 25 }),
		}),
	}),
	workbench_2 = table.freeze({
		BatchSize = 1,
		Outputs = table.freeze({
			table.freeze({ Id = "wood", Count = 75 }),
			table.freeze({ Id = "metal_ore", Count = 60 }),
			table.freeze({ Id = "scrap", Count = 40 }),
		}),
	}),
	workbench_3 = table.freeze({
		BatchSize = 1,
		Outputs = table.freeze({
			table.freeze({ Id = "high_quality_metal", Count = 20 }),
			table.freeze({ Id = "scrap", Count = 75 }),
		}),
	}),
	tool_cupboard = table.freeze({
		BatchSize = 1,
		Outputs = table.freeze({
			table.freeze({ Id = "wood", Count = 100 }),
		}),
	}),
	research_table = table.freeze({
		BatchSize = 1,
		Outputs = table.freeze({
			table.freeze({ Id = "wood", Count = 60 }),
			table.freeze({ Id = "metal_ore", Count = 40 }),
			table.freeze({ Id = "scrap", Count = 35 }),
		}),
	}),
})

local Recycling = {}

function Recycling.GetEntry(itemId: string): RecycleEntry?
	return Entries[itemId]
end

function Recycling.CanRecycle(itemId: string): boolean
	return Entries[itemId] ~= nil
end

function Recycling.ComputeOutputs(
	itemId: string,
	efficiencyMultiplier: number,
	availableCount: number?
): ({ Types.ItemBatchEntry }, number)
	local entry = Entries[itemId]
	if entry == nil then
		return {}, 0
	end

	local mult = math.clamp(efficiencyMultiplier, 0.1, 3.0)
	local batchSize = math.max(1, entry.BatchSize)
	local countToConsume = if availableCount ~= nil then math.min(availableCount, batchSize) else batchSize
	if countToConsume <= 0 then
		return {}, 0
	end

	local ratio = countToConsume / batchSize
	local results: { Types.ItemBatchEntry } = {}
	for _, out in entry.Outputs do
		local scaled = math.max(1, math.floor(out.Count * mult * ratio + 0.5))
		table.insert(results, {
			Id = out.Id,
			Count = scaled,
		})
	end

	return results, countToConsume
end

return Recycling
