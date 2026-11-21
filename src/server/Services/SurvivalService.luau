--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Types = require(ReplicatedStorage.Shared.Types)
local Items = require(ReplicatedStorage.Shared.configs.Items)
local Consumables = require(ReplicatedStorage.Shared.configs.Consumables)
local Net = require(ReplicatedStorage.Shared.Net)
local Janitor = require(ReplicatedStorage.Shared.Janitor)
local DataService = require(ServerScriptService.Server.Services.DataService)
local InventoryService = require(ServerScriptService.Server.Services.InventoryService)
local LootService = require(ServerScriptService.Server.Services.LootService)

type Inventory = Types.Inventory
type SurvivalStats = Types.SurvivalStats
type LootContainerState = Types.LootContainerState
type PlayerData = Types.PlayerData

local HUNGER_LOSS_PER_TICK = 0.35
local THIRST_LOSS_PER_TICK = 0.5
local PASSIVE_REGEN_THRESHOLD = 70
local PASSIVE_REGEN_PER_TICK = 1.5
local STARVE_DAMAGE_PER_TICK = 1.5

local playerJanitors: { [Player]: Janitor.Janitor } = {}
local characterJanitors: { [Player]: Janitor.Janitor } = {}
local appliedCharacters: { [Model]: boolean } = {}
local nextConsumeTime: { [Player]: number } = {}
local pendingRespawnReset: { [Player]: boolean } = {}
local nextBagId = 0
local isInitialized = false

local SurvivalService = {}

local function isValidInteger(val: any): boolean
	return typeof(val) == "number" and val == val and val % 1 == 0 and math.abs(val) ~= math.huge
end

local function roundStat(val: number): number
	return math.floor(val * 100 + 0.5) / 100
end

local function hasAnySlots(inv: Inventory): boolean
	for i = 1, Types.INVENTORY_SIZE do
		local slot = inv[i]
		if slot ~= nil and slot.Count > 0 then
			return true
		end
	end
	return false
end

local function getOrCreateLootFolder(): Folder
	local existing = Workspace:FindFirstChild("LootContainers")
	if existing and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = "LootContainers"
	folder.Parent = Workspace
	return folder
end

local function syncPlayerAttributes(player: Player, stats: SurvivalStats)
	player:SetAttribute("Hunger", roundStat(stats.Hunger))
	player:SetAttribute("Thirst", roundStat(stats.Thirst))
	player:SetAttribute("Starving", stats.Hunger <= 0)
	player:SetAttribute("Dehydrated", stats.Thirst <= 0)
end

local function getAliveCharacterParts(player: Player): (Model?, BasePart?, Humanoid?)
	local character = player.Character
	if not character then
		return nil, nil, nil
	end
	local hrp = character:FindFirstChild("HumanoidRootPart")
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not hrp or not hrp:IsA("BasePart") or not humanoid or humanoid.Health <= 0 then
		return nil, nil, nil
	end
	return character, hrp, humanoid
end

local function findDropPosition(deathPosition: Vector3, ignoreCharacter: Model?, lootFolder: Folder): Vector3
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local excludeList: { Instance } = { lootFolder }
	if ignoreCharacter then
		table.insert(excludeList, ignoreCharacter)
	end
	params.FilterDescendantsInstances = excludeList

	local origin = deathPosition + Vector3.new(0, 2, 0)
	local result = Workspace:Raycast(origin, Vector3.new(0, -50, 0), params)
	if result then
		return result.Position + Vector3.new(0, 0.7, 0)
	end
	return deathPosition + Vector3.new(0, 0.7, 0)
end

local function spawnLootContainer(ownerName: string, deathPosition: Vector3, slots: Inventory, ignoreCharacter: Model?)
	if not hasAnySlots(slots) then
		return
	end

	local lootFolder = getOrCreateLootFolder()
	nextBagId += 1
	local bagPos = findDropPosition(deathPosition, ignoreCharacter, lootFolder)
	local title = string.format("%s's Backpack", ownerName)

	local model = Instance.new("Model")
	model.Name = string.format("LootBag_%d", nextBagId)

	local body = Instance.new("Part")
	body.Name = "BagBody"
	body.Size = Vector3.new(2.2, 1.4, 1.6)
	body.CFrame = CFrame.new(bagPos)
	body.Anchored = true
	body.CanCollide = false
	body.Color = Color3.fromRGB(115, 82, 52)
	body.Material = Enum.Material.Fabric
	body.Parent = model

	local flap = Instance.new("Part")
	flap.Name = "BagFlap"
	flap.Size = Vector3.new(2.25, 0.35, 1.4)
	flap.CFrame = CFrame.new(bagPos + Vector3.new(0, 0.7, 0))
	flap.Anchored = true
	flap.CanCollide = false
	flap.Color = Color3.fromRGB(88, 60, 38)
	flap.Material = Enum.Material.Fabric
	flap.Parent = model

	local strap = Instance.new("Part")
	strap.Name = "BagStrap"
	strap.Size = Vector3.new(0.45, 0.5, 0.2)
	strap.CFrame = CFrame.new(bagPos + Vector3.new(0, 0.35, 0.78))
	strap.Anchored = true
	strap.CanCollide = false
	strap.Color = Color3.fromRGB(205, 175, 95)
	strap.Material = Enum.Material.Metal
	strap.Parent = model

	model.PrimaryPart = body

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "LootPrompt"
	prompt.ActionText = "Loot Body"
	prompt.ObjectText = title
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 12
	prompt.RequiresLineOfSight = false
	prompt.Parent = body

	model.Parent = lootFolder
	LootService.RegisterSlotsContainer(model, title, ownerName, slots, Types.LOOT_CONTAINER_LIFETIME)
end

local function applyStatsToCharacter(player: Player, character: Model, data: PlayerData)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end

	local defaultHealthScript = character:FindFirstChild("Health")
	if defaultHealthScript then
		defaultHealthScript:Destroy()
	end

	humanoid.MaxHealth = Types.MAX_HEALTH

	if pendingRespawnReset[player] or data.Stats.Health <= 0 then
		pendingRespawnReset[player] = false
		data.Stats.Health = Types.RESPAWN_HEALTH
		data.Stats.Hunger = Types.RESPAWN_HUNGER
		data.Stats.Thirst = Types.RESPAWN_THIRST
	end

	appliedCharacters[character] = true
	humanoid.Health = math.clamp(data.Stats.Health, 1, humanoid.MaxHealth)
	data.Stats.Health = humanoid.Health
	syncPlayerAttributes(player, data.Stats)
end

local function bindCharacter(player: Player, character: Model)
	local existingCharJanitor = characterJanitors[player]
	if existingCharJanitor then
		existingCharJanitor:Cleanup()
	else
		existingCharJanitor = Janitor.new()
		characterJanitors[player] = existingCharJanitor
	end

	local charJanitor = existingCharJanitor :: Janitor.Janitor
	charJanitor:Add(function()
		appliedCharacters[character] = nil
	end)

	local humanoidInstance = character:FindFirstChildOfClass("Humanoid")
	if not humanoidInstance then
		humanoidInstance = character:WaitForChild("Humanoid", 10)
	end
	if not humanoidInstance or not humanoidInstance:IsA("Humanoid") then
		return
	end
	if player.Character ~= character then
		return
	end

	local humanoid = humanoidInstance :: Humanoid
	local diedHandled = false

	local data = DataService.GetData(player)
	if data ~= nil then
		applyStatsToCharacter(player, character, data)
	end

	charJanitor:Add(humanoid.HealthChanged:Connect(function(newHealth: number)
		if not appliedCharacters[character] then
			return
		end
		local currentData = DataService.GetData(player)
		if currentData ~= nil then
			currentData.Stats.Health = math.clamp(newHealth, 0, humanoid.MaxHealth)
		end
	end))

	charJanitor:Add(humanoid.Died:Connect(function()
		if diedHandled then
			return
		end
		diedHandled = true
		appliedCharacters[character] = nil

		pendingRespawnReset[player] = true
		LootService.CloseContainerForPlayer(player, true)

		local currentData = DataService.GetData(player)
		if currentData ~= nil then
			currentData.Stats.Health = 0
		end

		local hrp = character:FindFirstChild("HumanoidRootPart")
		local deathPosition = if hrp and hrp:IsA("BasePart") then hrp.Position else character:GetPivot().Position

		local droppedSlots = InventoryService.ClearInventory(player)
		if hasAnySlots(droppedSlots) then
			spawnLootContainer(player.Name, deathPosition, droppedSlots, character)
		end
	end))
end

local function bindPlayer(player: Player)
	if playerJanitors[player] ~= nil then
		return
	end

	local janitor = Janitor.new()
	playerJanitors[player] = janitor

	janitor:Add(player.CharacterAdded:Connect(function(character: Model)
		task.spawn(bindCharacter, player, character)
	end))

	if player.Character then
		task.spawn(bindCharacter, player, player.Character)
	end
end

local function onPlayerDataLoaded(player: Player, data: PlayerData)
	syncPlayerAttributes(player, data.Stats)
	local character = player.Character
	if character then
		applyStatsToCharacter(player, character, data)
	end
end

local function onUseConsumable(player: Player, slotIndexAny: any)
	if not isValidInteger(slotIndexAny) then
		return
	end
	local slotIndex = slotIndexAny :: number
	if slotIndex < 1 or slotIndex > Types.INVENTORY_SIZE then
		return
	end

	local data = DataService.GetData(player)
	if not data then
		return
	end

	local _, _, humanoid = getAliveCharacterParts(player)
	if not humanoid then
		return
	end

	local slot = InventoryService.GetSlot(player, slotIndex)
	if slot == nil or slot.Count <= 0 then
		return
	end

	local itemConfig = Items[slot.Id]
	local consumableConfig = Consumables[slot.Id]
	if not itemConfig or itemConfig.Type ~= "Consumable" or not consumableConfig then
		return
	end

	local now = os.clock()
	local readyAt = nextConsumeTime[player] or 0
	if now < readyAt then
		return
	end

	if not InventoryService.ConsumeSlot(player, slotIndex, 1) then
		return
	end

	nextConsumeTime[player] = now + consumableConfig.UseCooldown

	if consumableConfig.Health ~= 0 then
		humanoid.Health = math.clamp(humanoid.Health + consumableConfig.Health, 0, humanoid.MaxHealth)
		data.Stats.Health = humanoid.Health
	end

	data.Stats.Hunger = math.clamp(data.Stats.Hunger + consumableConfig.Hunger, 0, Types.MAX_HUNGER)
	data.Stats.Thirst = math.clamp(data.Stats.Thirst + consumableConfig.Thirst, 0, Types.MAX_THIRST)
	syncPlayerAttributes(player, data.Stats)
end

local function stepSurvivalLoop()
	for _, player in Players:GetPlayers() do
		local data = DataService.GetData(player)
		local _, _, humanoid = getAliveCharacterParts(player)
		if data ~= nil and humanoid ~= nil then
			local stats = data.Stats
			stats.Hunger = math.clamp(stats.Hunger - HUNGER_LOSS_PER_TICK, 0, Types.MAX_HUNGER)
			stats.Thirst = math.clamp(stats.Thirst - THIRST_LOSS_PER_TICK, 0, Types.MAX_THIRST)

			if
				stats.Hunger > PASSIVE_REGEN_THRESHOLD
				and stats.Thirst > PASSIVE_REGEN_THRESHOLD
				and humanoid.Health < humanoid.MaxHealth
			then
				humanoid.Health = math.min(humanoid.MaxHealth, humanoid.Health + PASSIVE_REGEN_PER_TICK)
			end

			if stats.Hunger <= 0 or stats.Thirst <= 0 then
				humanoid.Health = math.max(0, humanoid.Health - STARVE_DAMAGE_PER_TICK)
			end

			stats.Health = math.clamp(humanoid.Health, 0, humanoid.MaxHealth)
			syncPlayerAttributes(player, stats)
		end
	end
end

function SurvivalService.GetStats(player: Player): SurvivalStats?
	local data = DataService.GetData(player)
	if not data then
		return nil
	end
	return {
		Health = data.Stats.Health,
		Hunger = data.Stats.Hunger,
		Thirst = data.Stats.Thirst,
	}
end

function SurvivalService.GetContainerState(containerId: string): LootContainerState?
	return LootService.GetContainerState(containerId)
end

function SurvivalService.Init()
	if isInitialized then
		return
	end
	isInitialized = true

	Net.InitServer()
	getOrCreateLootFolder()

	Net.GetEvent(Net.Events.UseConsumable).OnServerEvent:Connect(onUseConsumable)

	Players.PlayerAdded:Connect(bindPlayer)
	for _, player in Players:GetPlayers() do
		bindPlayer(player)
	end

	Players.PlayerRemoving:Connect(function(player: Player)
		LootService.CloseContainerForPlayer(player, false)
		nextConsumeTime[player] = nil
		pendingRespawnReset[player] = nil

		local charJanitor = characterJanitors[player]
		if charJanitor then
			charJanitor:Destroy()
			characterJanitors[player] = nil
		end

		local pJanitor = playerJanitors[player]
		if pJanitor then
			pJanitor:Destroy()
			playerJanitors[player] = nil
		end
	end)

	DataService.OnBeforeUnload(function(player: Player, data: PlayerData)
		local character = player.Character
		local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
		if humanoid then
			data.Stats.Health = math.clamp(humanoid.Health, 0, humanoid.MaxHealth)
		end
	end)

	DataService.OnDataLoaded(onPlayerDataLoaded)

	task.spawn(function()
		while true do
			task.wait(Types.SURVIVAL_TICK_INTERVAL)
			stepSurvivalLoop()
		end
	end)
end

return SurvivalService
