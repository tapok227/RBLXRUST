--!strict
return table.freeze({
	MAX_TC_WALL_LAYERS = 2,
	MIN_TURRET_DISTANCE = 14,
	MIN_TRAP_DISTANCE = 6,
	WORKBENCH_RADIUS = 16,
	VendorHub = table.freeze({
		Origin = Vector3.new(0, 0, -68),
		ZoneSize = Vector3.new(44, 32, 34),
		InteractDistance = 14,
		MaxTradeQuantity = 10,
	}),
	Game = table.freeze({
		Name = "MyRobloxGame",
		MaxPlayers = 50,
	}),
	Places = table.freeze({
		MainMap = 115796771630565,
		MainMap_Tier1 = 115796771630565,
		MainMap_Tier2 = 115796771630565,
		MainMap_Tier3 = 115796771630565,
		PlayerBase = 133157812100009,
	}),
	Maps = table.freeze({
		MainMap_Tier1 = table.freeze({
			Key = "MainMap_Tier1",
			Name = "PvP Map Tier 1 (Wood/Stone)",
			PlaceId = 115796771630565,
			RequiredBaseTier = 1,
		}),
		MainMap_Tier2 = table.freeze({
			Key = "MainMap_Tier2",
			Name = "PvP Map Tier 2 (Metal)",
			PlaceId = 115796771630565,
			RequiredBaseTier = 2,
		}),
		MainMap_Tier3 = table.freeze({
			Key = "MainMap_Tier3",
			Name = "PvP Map Tier 3 (Armored)",
			PlaceId = 115796771630565,
			RequiredBaseTier = 3,
		}),
	}),
	MapOrder = table.freeze({
		"MainMap_Tier1",
		"MainMap_Tier2",
		"MainMap_Tier3",
	}),
	BaseProgression = table.freeze({
		Tier1 = table.freeze({
			MinStructuralPieces = 1,
			MinQualifiedPieces = 1,
			MinTierRank = 1,
		}),
		Tier2 = table.freeze({
			MinStructuralPieces = 4,
			MinQualifiedPieces = 4,
			MinTierRank = 3,
		}),
		Tier3 = table.freeze({
			MinStructuralPieces = 6,
			MinQualifiedPieces = 6,
			MinTierRank = 4,
		}),
	}),
	Upkeep = table.freeze({
		AllowedResourceIds = table.freeze({
			"wood",
			"stone",
			"metal_ore",
			"high_quality_metal",
		}),
		ResourceByBuildTier = table.freeze({
			wood = "wood",
			stone = "stone",
			metal = "metal_ore",
			armored = "high_quality_metal",
		}),
		HourlyCostPerPiece = table.freeze({
			wood = 12,
			stone = 18,
			metal = 15,
			armored = 6,
		}),
		TcStorageSlots = 12,
	}),
	Decay = table.freeze({
		TickIntervalSeconds = 60,
		OfflineMaxHours = 24,
		HourlyDamageByTier = table.freeze({
			wood = 60,
			stone = 50,
			metal = 45,
			armored = 40,
		}),
		NoTcMultiplier = 1.5,
	}),
	Extraction = table.freeze({
		Duration = 8,
		CooldownAfterDamage = 5,
	}),
	Raid = table.freeze({
		MaxLives = 3,
		RespawnDelay = 0.8,
		SpawnInvulnerabilityDuration = 2.0,
		TcHackDuration = 10,
		TcHackMaxDistance = 14,
		OutpostRadius = 28,
		OutpostOffsetZ = 46,
		ExtractionStashSlots = 18,
		SupplyCrateSlots = 6,
		StarterSupplyItems = table.freeze({
			table.freeze({ Id = "bandage", Count = 6 }),
			table.freeze({ Id = "cooked_meat", Count = 2 }),
		}),
		Tiers = table.freeze({
			[1] = table.freeze({
				Tier = 1,
				RequiredBaseTier = 1,
				DangerLabel = "Low (Wood/Stone)",
				RewardLabel = "Scrap, Metal Ore, Basic Gear",
				LaunchCost = table.freeze({ scrap = 30 }),
				DefenseBonus = table.freeze({ scrap = 25 }),
			}),
			[2] = table.freeze({
				Tier = 2,
				RequiredBaseTier = 2,
				DangerLabel = "Medium (Metal)",
				RewardLabel = "Metal Ore, Tech Parts, Ammo",
				LaunchCost = table.freeze({ scrap = 75, metal_ore = 40 }),
				DefenseBonus = table.freeze({ scrap = 60, metal_ore = 25 }),
			}),
			[3] = table.freeze({
				Tier = 3,
				RequiredBaseTier = 3,
				DangerLabel = "High (Armored)",
				RewardLabel = "HQM, Tech Parts, Explosives",
				LaunchCost = table.freeze({ scrap = 140, tech_parts = 2 }),
				DefenseBonus = table.freeze({ scrap = 120, tech_parts = 1 }),
			}),
		}),
	}),
	DefenseCapacity = table.freeze({
		MaxByBaseTier = table.freeze({
			[0] = 30,
			[1] = 60,
			[2] = 100,
			[3] = 150,
		}),
		Costs = table.freeze({
			floor_spikes = 5,
			landmine = 10,
			shotgun_trap = 15,
			auto_turret = 25,
		}),
	}),
})
