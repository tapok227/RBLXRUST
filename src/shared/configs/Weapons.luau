--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage.Shared.Types)

export type WeaponConfig = Types.WeaponConfig

local FISTS: WeaponConfig = table.freeze({
	Category = "Melee" :: Types.WeaponCategory,
	Damage = 8,
	HeadshotMultiplier = 1.25,
	Range = 6,
	Cooldown = 0.7,
	AmmoId = nil,
})

local Weapons: { [string]: WeaponConfig } = {
	wooden_spear = table.freeze({
		Category = "Melee" :: Types.WeaponCategory,
		Damage = 25,
		HeadshotMultiplier = 1.5,
		Range = 10,
		Cooldown = 0.75,
		AmmoId = nil,
	}),
	spear = table.freeze({
		Category = "Melee" :: Types.WeaponCategory,
		Damage = 25,
		HeadshotMultiplier = 1.5,
		Range = 10,
		Cooldown = 0.75,
		AmmoId = nil,
	}),
	hatchet = table.freeze({
		Category = "Melee" :: Types.WeaponCategory,
		Damage = 18,
		HeadshotMultiplier = 1.5,
		Range = 7,
		Cooldown = 0.6,
		AmmoId = nil,
	}),
	metal_hatchet = table.freeze({
		Category = "Melee" :: Types.WeaponCategory,
		Damage = 22,
		HeadshotMultiplier = 1.5,
		Range = 7,
		Cooldown = 0.55,
		AmmoId = nil,
	}),
	pickaxe = table.freeze({
		Category = "Melee" :: Types.WeaponCategory,
		Damage = 16,
		HeadshotMultiplier = 1.5,
		Range = 7,
		Cooldown = 0.7,
		AmmoId = nil,
	}),
	hunting_bow = table.freeze({
		Category = "Ranged" :: Types.WeaponCategory,
		Damage = 45,
		HeadshotMultiplier = 2.0,
		Range = 160,
		Cooldown = 1.1,
		AmmoId = "arrow",
	}),
	pipe_pistol = table.freeze({
		Category = "Ranged" :: Types.WeaponCategory,
		Damage = 32,
		HeadshotMultiplier = 1.8,
		Range = 140,
		Cooldown = 0.45,
		AmmoId = "pistol_ammo",
	}),
	rocket_launcher = table.freeze({
		Category = "Ranged" :: Types.WeaponCategory,
		Damage = 110,
		HeadshotMultiplier = 1.0,
		Range = 350,
		Cooldown = 3.2,
		AmmoId = "rocket",
		ProjectileId = "rocket",
	}),
	FISTS = FISTS,
}

return table.freeze(Weapons)
