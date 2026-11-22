--!strict
return table.freeze({
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
})
