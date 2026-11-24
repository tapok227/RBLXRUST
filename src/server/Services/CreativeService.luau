--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local Items = require(ReplicatedStorage.Shared.configs.Items)
local DataService = require(ServerScriptService.Server.Services.DataService)
local InventoryService = require(ServerScriptService.Server.Services.InventoryService)
local BlueprintService = require(ServerScriptService.Server.Services.BlueprintService)
local SecurityService = require(ServerScriptService.Server.Services.SecurityService)

type GiveAllEntry = {
	Id: string,
	Count: number,
}

local GIVEALL_ITEMS: { GiveAllEntry } = table.freeze({
	table.freeze({ Id = "wood", Count = 1000 }),
	table.freeze({ Id = "stone", Count = 1000 }),
	table.freeze({ Id = "metal_ore", Count = 500 }),
	table.freeze({ Id = "high_quality_metal", Count = 100 }),
	table.freeze({ Id = "scrap", Count = 500 }),
	table.freeze({ Id = "animal_fat", Count = 200 }),
	table.freeze({ Id = "cloth", Count = 200 }),
	table.freeze({ Id = "tech_parts", Count = 50 }),
	table.freeze({ Id = "c4_charge", Count = 5 }),
	table.freeze({ Id = "satchel_charge", Count = 10 }),
	table.freeze({ Id = "emp_grenade", Count = 5 }),
	table.freeze({ Id = "smoke_grenade", Count = 5 }),
	table.freeze({ Id = "building_plan", Count = 1 }),
	table.freeze({ Id = "hammer", Count = 1 }),
	table.freeze({ Id = "repair_hammer", Count = 1 }),
	table.freeze({ Id = "pipe_pistol", Count = 1 }),
	table.freeze({ Id = "pistol_ammo", Count = 64 }),
	table.freeze({ Id = "rocket_launcher", Count = 1 }),
	table.freeze({ Id = "rocket", Count = 10 }),
	table.freeze({ Id = "hunting_bow", Count = 1 }),
	table.freeze({ Id = "arrow", Count = 64 }),
	table.freeze({ Id = "shotgun_shell", Count = 32 }),
	table.freeze({ Id = "spear", Count = 1 }),
	table.freeze({ Id = "metal_hatchet", Count = 1 }),
})

-- Server-authoritative creative player registry keyed by UserId.
-- Replicated attribute IsCreativeMode is strictly for client HUD/UX display.
local CreativePlayers: { [number]: boolean } = {}
local boundPlayers: { [Player]: { RBXScriptConnection } } = {}
local isInitialized = false

local CreativeService = {}

function CreativeService.CanUseCommands(player: Player): boolean
	if RunService:IsStudio() then
		return true
	end
	return game.CreatorId ~= 0 and player.UserId == game.CreatorId
end

function CreativeService.IsCreative(player: Player?): boolean
	if player == nil then
		return false
	end
	return CreativePlayers[player.UserId] == true
end

function CreativeService.IsCreativeUserId(userId: number?): boolean
	if userId == nil then
		return false
	end
	return CreativePlayers[userId] == true
end

local function applyCharacterCreativeProtection(player: Player, character: Model?)
	if character == nil then
		return
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid") or character:WaitForChild("Humanoid", 5)
	if humanoid == nil or not humanoid:IsA("Humanoid") then
		return
	end
	if CreativeService.IsCreative(player) then
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Dead, false)
		if humanoid.Health < 1 then
			humanoid.Health = 1
		end
	else
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Dead, true)
	end
end

function CreativeService.SetCreative(player: Player, enabled: boolean)
	if enabled then
		CreativePlayers[player.UserId] = true
	else
		CreativePlayers[player.UserId] = nil
	end
	player:SetAttribute("IsCreativeMode", enabled)
	task.spawn(applyCharacterCreativeProtection, player, player.Character)
	print(string.format("[CreativeService] %s creative mode = %s", player.Name, tostring(enabled)))
end

function CreativeService.ApplyPlayerDamage(humanoid: Humanoid, amount: number): number
	if amount <= 0 or humanoid.Health <= 0 then
		return 0
	end
	local character = humanoid.Parent
	local targetPlayer = if character ~= nil and character:IsA("Model")
		then Players:GetPlayerFromCharacter(character)
		else nil
	if targetPlayer ~= nil and CreativeService.IsCreative(targetPlayer) then
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Dead, false)
		local newHealth = math.max(1, humanoid.Health - amount)
		humanoid.Health = newHealth
		return amount
	end
	humanoid:TakeDamage(amount)
	return amount
end

function CreativeService.GiveAll(player: Player): boolean
	if not CreativeService.CanUseCommands(player) then
		return false
	end
	if DataService.GetData(player) == nil then
		return false
	end

	local grantedItems = 0
	local unlockedBlueprints = 0
	SecurityService.RunLocked(player, "CreativeGiveAll", function()
		if DataService.GetData(player) == nil then
			return
		end
		for _, entry in GIVEALL_ITEMS do
			local itemCfg = Items[entry.Id]
			if itemCfg ~= nil then
				local currentCount = InventoryService.GetItemCount(player, entry.Id)
				if itemCfg.MaxStack <= 1 then
					if currentCount == 0 then
						local remainder = InventoryService.AddItem(player, entry.Id, 1)
						if remainder < 1 then
							grantedItems += 1
						end
					end
				else
					local targetCount = math.min(entry.Count, itemCfg.MaxStack)
					if currentCount < targetCount then
						local toAdd = targetCount - currentCount
						local remainder = InventoryService.AddItem(player, entry.Id, toAdd)
						if remainder < toAdd then
							grantedItems += 1
						end
					end
				end
			end
		end
		unlockedBlueprints = BlueprintService.UnlockAllBlueprints(player)
	end)

	print(
		string.format(
			"[CreativeService] /giveall granted to %s (itemsUpdated=%d, blueprintsUnlocked=%d)",
			player.Name,
			grantedItems,
			unlockedBlueprints
		)
	)
	return true
end

local function handleChatCommand(player: Player, rawMessage: string)
	if typeof(rawMessage) ~= "string" then
		return
	end
	local trimmed = string.lower(string.match(rawMessage, "^%s*(.-)%s*$") or "")
	if trimmed ~= "/creative" and trimmed ~= "/giveall" then
		return
	end
	if not CreativeService.CanUseCommands(player) then
		warn(
			string.format(
				"[CreativeService] Unauthorized command '%s' from %s (%d)",
				trimmed,
				player.Name,
				player.UserId
			)
		)
		return
	end
	if trimmed == "/creative" then
		CreativeService.SetCreative(player, not CreativeService.IsCreative(player))
	elseif trimmed == "/giveall" then
		CreativeService.GiveAll(player)
	end
end

local function bindPlayer(player: Player)
	if boundPlayers[player] ~= nil then
		return
	end
	player:SetAttribute("IsCreativeMode", CreativeService.IsCreative(player))
	local conns: { RBXScriptConnection } = {}
	boundPlayers[player] = conns

	table.insert(
		conns,
		player.Chatted:Connect(function(message: string)
			handleChatCommand(player, message)
		end)
	)
	table.insert(
		conns,
		player.CharacterAdded:Connect(function(character: Model)
			task.spawn(applyCharacterCreativeProtection, player, character)
		end)
	)
	if player.Character ~= nil then
		task.spawn(applyCharacterCreativeProtection, player, player.Character)
	end
end

function CreativeService.Init()
	if isInitialized then
		return
	end
	isInitialized = true

	Players.PlayerAdded:Connect(bindPlayer)
	Players.PlayerRemoving:Connect(function(player: Player)
		local conns = boundPlayers[player]
		if conns ~= nil then
			for _, conn in conns do
				conn:Disconnect()
			end
			boundPlayers[player] = nil
		end
		CreativePlayers[player.UserId] = nil
	end)

	for _, player in Players:GetPlayers() do
		bindPlayer(player)
	end
end

return CreativeService
