--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage.Shared.Types)

export type VendorId = Types.VendorId
export type VendorOffer = Types.VendorOffer
export type VendorConfig = Types.VendorConfig

local ById: { [VendorId]: VendorConfig } = table.freeze({
	recycler = table.freeze({
		Id = "recycler" :: VendorId,
		Name = "Recycler",
		RoleTitle = "Resource & Loot Buyer",
		AccentColor = Color3.fromRGB(220, 155, 55),
		Description = "Trades gathered resources and spare gear for Scrap.",
		Offers = table.freeze({
			table.freeze({
				OfferId = "sell_wood",
				Mode = "Sell" :: Types.VendorOfferMode,
				GiveId = "wood",
				GiveCount = 100,
				ReceiveId = "scrap",
				ReceiveCount = 4,
			}),
			table.freeze({
				OfferId = "sell_stone",
				Mode = "Sell" :: Types.VendorOfferMode,
				GiveId = "stone",
				GiveCount = 100,
				ReceiveId = "scrap",
				ReceiveCount = 5,
			}),
			table.freeze({
				OfferId = "sell_metal_ore",
				Mode = "Sell" :: Types.VendorOfferMode,
				GiveId = "metal_ore",
				GiveCount = 50,
				ReceiveId = "scrap",
				ReceiveCount = 8,
			}),
			table.freeze({
				OfferId = "sell_cloth",
				Mode = "Sell" :: Types.VendorOfferMode,
				GiveId = "cloth",
				GiveCount = 25,
				ReceiveId = "scrap",
				ReceiveCount = 4,
			}),
			table.freeze({
				OfferId = "sell_animal_fat",
				Mode = "Sell" :: Types.VendorOfferMode,
				GiveId = "animal_fat",
				GiveCount = 20,
				ReceiveId = "scrap",
				ReceiveCount = 6,
			}),
			table.freeze({
				OfferId = "sell_bone",
				Mode = "Sell" :: Types.VendorOfferMode,
				GiveId = "bone",
				GiveCount = 20,
				ReceiveId = "scrap",
				ReceiveCount = 5,
			}),
			table.freeze({
				OfferId = "sell_hqm",
				Mode = "Sell" :: Types.VendorOfferMode,
				GiveId = "high_quality_metal",
				GiveCount = 10,
				ReceiveId = "scrap",
				ReceiveCount = 14,
			}),
			table.freeze({
				OfferId = "sell_tech_parts",
				Mode = "Sell" :: Types.VendorOfferMode,
				GiveId = "tech_parts",
				GiveCount = 1,
				ReceiveId = "scrap",
				ReceiveCount = 15,
			}),
			table.freeze({
				OfferId = "sell_hunting_bow",
				Mode = "Sell" :: Types.VendorOfferMode,
				GiveId = "hunting_bow",
				GiveCount = 1,
				ReceiveId = "scrap",
				ReceiveCount = 8,
			}),
			table.freeze({
				OfferId = "sell_pipe_pistol",
				Mode = "Sell" :: Types.VendorOfferMode,
				GiveId = "pipe_pistol",
				GiveCount = 1,
				ReceiveId = "scrap",
				ReceiveCount = 20,
			}),
		}),
	}),
	weaponsmith = table.freeze({
		Id = "weaponsmith" :: VendorId,
		Name = "Weaponsmith",
		RoleTitle = "Weapons, Ammo & Tech",
		AccentColor = Color3.fromRGB(205, 75, 75),
		Description = "Sells weapons, ammo, and tech parts for Scrap.",
		Offers = table.freeze({
			table.freeze({
				OfferId = "buy_hunting_bow",
				Mode = "Buy" :: Types.VendorOfferMode,
				GiveId = "scrap",
				GiveCount = 25,
				ReceiveId = "hunting_bow",
				ReceiveCount = 1,
			}),
			table.freeze({
				OfferId = "buy_arrow",
				Mode = "Buy" :: Types.VendorOfferMode,
				GiveId = "scrap",
				GiveCount = 10,
				ReceiveId = "arrow",
				ReceiveCount = 12,
			}),
			table.freeze({
				OfferId = "buy_pipe_pistol",
				Mode = "Buy" :: Types.VendorOfferMode,
				GiveId = "scrap",
				GiveCount = 60,
				ReceiveId = "pipe_pistol",
				ReceiveCount = 1,
			}),
			table.freeze({
				OfferId = "buy_pistol_ammo",
				Mode = "Buy" :: Types.VendorOfferMode,
				GiveId = "scrap",
				GiveCount = 15,
				ReceiveId = "pistol_ammo",
				ReceiveCount = 12,
			}),
			table.freeze({
				OfferId = "buy_shotgun_shell",
				Mode = "Buy" :: Types.VendorOfferMode,
				GiveId = "scrap",
				GiveCount = 25,
				ReceiveId = "shotgun_shell",
				ReceiveCount = 8,
			}),
			table.freeze({
				OfferId = "buy_metal_hatchet",
				Mode = "Buy" :: Types.VendorOfferMode,
				GiveId = "scrap",
				GiveCount = 35,
				ReceiveId = "metal_hatchet",
				ReceiveCount = 1,
			}),
			table.freeze({
				OfferId = "buy_tech_parts",
				Mode = "Buy" :: Types.VendorOfferMode,
				GiveId = "scrap",
				GiveCount = 45,
				ReceiveId = "tech_parts",
				ReceiveCount = 1,
			}),
		}),
	}),
	quartermaster = table.freeze({
		Id = "quartermaster" :: VendorId,
		Name = "Quartermaster",
		RoleTitle = "Meds, Food & Supplies",
		AccentColor = Color3.fromRGB(70, 170, 115),
		Description = "Sells medical supplies, rations, and building resources for Scrap.",
		Offers = table.freeze({
			table.freeze({
				OfferId = "buy_bandage",
				Mode = "Buy" :: Types.VendorOfferMode,
				GiveId = "scrap",
				GiveCount = 10,
				ReceiveId = "bandage",
				ReceiveCount = 3,
			}),
			table.freeze({
				OfferId = "buy_cooked_meat",
				Mode = "Buy" :: Types.VendorOfferMode,
				GiveId = "scrap",
				GiveCount = 12,
				ReceiveId = "cooked_meat",
				ReceiveCount = 2,
			}),
			table.freeze({
				OfferId = "buy_water_bottle",
				Mode = "Buy" :: Types.VendorOfferMode,
				GiveId = "scrap",
				GiveCount = 10,
				ReceiveId = "water_bottle",
				ReceiveCount = 2,
			}),
			table.freeze({
				OfferId = "buy_wood",
				Mode = "Buy" :: Types.VendorOfferMode,
				GiveId = "scrap",
				GiveCount = 15,
				ReceiveId = "wood",
				ReceiveCount = 120,
			}),
			table.freeze({
				OfferId = "buy_stone",
				Mode = "Buy" :: Types.VendorOfferMode,
				GiveId = "scrap",
				GiveCount = 20,
				ReceiveId = "stone",
				ReceiveCount = 120,
			}),
			table.freeze({
				OfferId = "buy_metal_ore",
				Mode = "Buy" :: Types.VendorOfferMode,
				GiveId = "scrap",
				GiveCount = 30,
				ReceiveId = "metal_ore",
				ReceiveCount = 60,
			}),
			table.freeze({
				OfferId = "buy_cloth",
				Mode = "Buy" :: Types.VendorOfferMode,
				GiveId = "scrap",
				GiveCount = 15,
				ReceiveId = "cloth",
				ReceiveCount = 30,
			}),
			table.freeze({
				OfferId = "buy_building_plan",
				Mode = "Buy" :: Types.VendorOfferMode,
				GiveId = "scrap",
				GiveCount = 10,
				ReceiveId = "building_plan",
				ReceiveCount = 1,
			}),
			table.freeze({
				OfferId = "buy_hammer",
				Mode = "Buy" :: Types.VendorOfferMode,
				GiveId = "scrap",
				GiveCount = 15,
				ReceiveId = "hammer",
				ReceiveCount = 1,
			}),
		}),
	}),
})

local Order: { VendorId } = table.freeze({
	"recycler" :: VendorId,
	"weaponsmith" :: VendorId,
	"quartermaster" :: VendorId,
})

local function getVendor(vendorId: any): VendorConfig?
	if typeof(vendorId) ~= "string" then
		return nil
	end
	return (ById :: { [string]: VendorConfig })[vendorId]
end

return table.freeze({
	ById = ById,
	Order = Order,
	Get = getVendor,
})
