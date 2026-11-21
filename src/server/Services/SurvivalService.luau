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

type Inventory = Types.Inventory
type Slot = Types.Slot
type SurvivalStats = Types.SurvivalStats
type LootContainerState = Types.LootContainerState
type PlayerData = Types.PlayerData

type ServerLootContainer = {
	ContainerId: string,
	OwnerName: string,
	Slots: Inventory,
	ExpiresAt: number,
	Model: Model,
	PrimaryPart: BasePart,
	Viewers: { [Player]: boolean },
}

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
local openContainerByPlayer: { [Player]: string } = {}
local lootContainers: { [string]: ServerLootContainer } = {}
local nextContainerId = 0
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

local function cloneInventory(inv: Inventory): Inventory
	local copy: Inventory = {}
	for i = 1, Types.INVENTORY_SIZE do
		local slot = inv[i]
		if slot ~= nil and slot.Count > 0 then
			copy[i] = {
				Id = slot.Id,
				Count = slot.Count,
			}
		end
	end
	return copy
end

local function serializeSlotsForNet(slots: Inventory): { [string]: Slot }
	local raw: { [string]: Slot } = {}
	for i = 1, Types.INVENTORY_SIZE do
		local slot = slots[i]
		if slot ~= nil and slot.Count > 0 then
			raw[tostring(i)] = {
				Id = slot.Id,
				Count = slot.Count,
			}
		end
	end
	return raw
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

local function closeContainerForPlayer(player: Player, notifyClient: boolean)
	local containerId = openContainerByPlayer[player]
	if containerId == nil then
		return
	end
	openContainerByPlayer[player] = nil

	local container = lootContainers[containerId]
	if container ~= nil then
		container.Viewers[player] = nil
	end

	if notifyClient and player.Parent == Players then
		Net.GetEvent(Net.Events.CloseContainer):FireClient(player, containerId)
	end
end

local function destroyLootContainer(containerId: string)
	local container = lootContainers[containerId]
	if container == nil then
		return
	end
	lootContainers[containerId] = nil

	local viewersToNotify: { Player } = {}
	for viewer in container.Viewers do
		table.insert(viewersToNotify, viewer)
	end
	table.clear(container.Viewers)

	local closeEvent = Net.GetEvent(Net.Events.CloseContainer)
	for _, viewer in viewersToNotify do
		if openContainerByPlayer[viewer] == containerId then
			openContainerByPlayer[viewer] = nil
		end
		if viewer.Parent == Players then
			closeEvent:FireClient(viewer, containerId)
		end
	end

	if container.Model.Parent then
		container.Model:Destroy()
	end
end

local function notifyContainerViewers(container: ServerLootContainer)
	local payload = serializeSlotsForNet(container.Slots)
	local title = string.format("%s's Backpack", container.OwnerName)
	local openEvent = Net.GetEvent(Net.Events.OpenContainer)

	local staleViewers: { Player } = {}
	for viewer in container.Viewers do
		if viewer.Parent == Players then
			openEvent:FireClient(viewer, container.ContainerId, title, payload)
		else
			table.insert(staleViewers, viewer)
		end
	end

	for _, stale in staleViewers do
		container.Viewers[stale] = nil
		if openContainerByPlayer[stale] == container.ContainerId then
			openContainerByPlayer[stale] = nil
		end
	end
end

local function openContainerForPlayer(player: Player, container: ServerLootContainer)
	local prevContainerId = openContainerByPlayer[player]
	if prevContainerId ~= nil and prevContainerId ~= container.ContainerId then
		local prevContainer = lootContainers[prevContainerId]
		if prevContainer ~= nil then
			prevContainer.Viewers[player] = nil
		end
	end

	openContainerByPlayer[player] = container.ContainerId
	container.Viewers[player] = true

	local title = string.format("%s's Backpack", container.OwnerName)
	Net.GetEvent(Net.Events.OpenContainer)
		:FireClient(player, container.ContainerId, title, serializeSlotsForNet(container.Slots))
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
	nextContainerId += 1
	local containerId = string.format("loot_%d", nextContainerId)
	local expiresAt = Workspace:GetServerTimeNow() + Types.LOOT_CONTAINER_LIFETIME
	local bagPos = findDropPosition(deathPosition, ignoreCharacter, lootFolder)

	local model = Instance.new("Model")
	model.Name = string.format("LootBag_%s", containerId)

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
	model:SetAttribute("ContainerId", containerId)
	model:SetAttribute("OwnerName", ownerName)
	model:SetAttribute("ExpiresAt", expiresAt)

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "LootPrompt"
	prompt.ActionText = "Loot Body"
	prompt.ObjectText = string.format("%s's Backpack", ownerName)
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 12
	prompt.RequiresLineOfSight = false
	prompt.Parent = body

	local container: ServerLootContainer = {
		ContainerId = containerId,
		OwnerName = ownerName,
		Slots = cloneInventory(slots),
		ExpiresAt = expiresAt,
		Model = model,
		PrimaryPart = body,
		Viewers = {},
	}
	lootContainers[containerId] = container
	model.Parent = lootFolder

	prompt.Triggered:Connect(function(viewer: Player)
		if lootContainers[containerId] ~= container then
			return
		end
		if DataService.GetData(viewer) == nil then
			return
		end
		local _, hrp, _ = getAliveCharacterParts(viewer)
		if not hrp then
			return
		end
		if (hrp.Position - body.Position).Magnitude > Types.MAX_LOOT_DISTANCE then
			return
		end
		openContainerForPlayer(viewer, container)
	end)

	task.delay(Types.LOOT_CONTAINER_LIFETIME, function()
		if lootContainers[containerId] == container then
			destroyLootContainer(containerId)
		end
	end)
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
		closeContainerForPlayer(player, true)

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

local function onCloseContainer(player: Player, _containerIdAny: any)
	closeContainerForPlayer(player, false)
end

local function onLootTakeSlot(player: Player, containerIdAny: any, containerSlotAny: any, targetPlayerSlotAny: any)
	if typeof(containerIdAny) ~= "string" or #containerIdAny == 0 or #containerIdAny > 64 then
		return
	end
	if not isValidInteger(containerSlotAny) then
		return
	end
	local containerSlot = containerSlotAny :: number
	if containerSlot < 1 or containerSlot > Types.INVENTORY_SIZE then
		return
	end

	local targetPlayerSlot: number? = nil
	if targetPlayerSlotAny ~= nil then
		if not isValidInteger(targetPlayerSlotAny) then
			return
		end
		local candidate = targetPlayerSlotAny :: number
		if candidate < 1 or candidate > Types.INVENTORY_SIZE then
			return
		end
		targetPlayerSlot = candidate
	end

	if DataService.GetData(player) == nil then
		return
	end

	local _, hrp, _ = getAliveCharacterParts(player)
	if not hrp then
		return
	end

	local container = lootContainers[containerIdAny]
	if container == nil or not container.PrimaryPart.Parent then
		return
	end

	if (hrp.Position - container.PrimaryPart.Position).Magnitude > Types.MAX_LOOT_DISTANCE then
		return
	end

	local slot = container.Slots[containerSlot]
	if slot == nil or slot.Count <= 0 then
		return
	end

	local remainder: number
	if targetPlayerSlot ~= nil then
		remainder = InventoryService.AddItemToSlot(player, slot.Id, slot.Count, targetPlayerSlot)
	else
		remainder = InventoryService.AddItem(player, slot.Id, slot.Count)
	end

	if remainder >= slot.Count then
		return
	end

	if remainder <= 0 then
		container.Slots[containerSlot] = nil
	else
		slot.Count = remainder
	end

	if not hasAnySlots(container.Slots) then
		destroyLootContainer(container.ContainerId)
	else
		notifyContainerViewers(container)
	end
end

local function stepSurvivalLoop()
	for _, player in Players:GetPlayers() do
		local data = DataService.GetData(player)
		local _, hrp, humanoid = getAliveCharacterParts(player)
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

		local openId = openContainerByPlayer[player]
		if openId ~= nil then
			local container = lootContainers[openId]
			if
				container == nil
				or not container.PrimaryPart.Parent
				or not hrp
				or (hrp.Position - container.PrimaryPart.Position).Magnitude > (Types.MAX_LOOT_DISTANCE + 2)
			then
				closeContainerForPlayer(player, true)
			end
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
	local container = lootContainers[containerId]
	if not container then
		return nil
	end
	return {
		ContainerId = container.ContainerId,
		OwnerName = container.OwnerName,
		Slots = cloneInventory(container.Slots),
		ExpiresAt = container.ExpiresAt,
	}
end

function SurvivalService.Init()
	if isInitialized then
		return
	end
	isInitialized = true

	Net.InitServer()
	getOrCreateLootFolder()

	Net.GetEvent(Net.Events.UseConsumable).OnServerEvent:Connect(onUseConsumable)
	Net.GetEvent(Net.Events.CloseContainer).OnServerEvent:Connect(onCloseContainer)
	Net.GetEvent(Net.Events.LootTakeSlot).OnServerEvent:Connect(onLootTakeSlot)

	Players.PlayerAdded:Connect(bindPlayer)
	for _, player in Players:GetPlayers() do
		bindPlayer(player)
	end

	Players.PlayerRemoving:Connect(function(player: Player)
		closeContainerForPlayer(player, false)
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
