--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)
local Types = require(ReplicatedStorage.Shared.Types)
local Items = require(ReplicatedStorage.Shared.configs.Items)
local LootTables = require(ReplicatedStorage.Shared.configs.LootTables)
local Net = require(ReplicatedStorage.Shared.Net)
local DataService = require(ServerScriptService.Server.Services.DataService)
local InventoryService = require(ServerScriptService.Server.Services.InventoryService)
local SecurityService = require(ServerScriptService.Server.Services.SecurityService)

type Inventory = Types.Inventory
type Slot = Types.Slot
type LootContainerState = Types.LootContainerState
type LootDropEntry = Types.LootDropEntry

type PartSnapshot = {
	Part: BasePart,
	OriginalTransparency: number,
	OriginalCanCollide: boolean,
	OriginalCanQuery: boolean,
}

type ContainerKind = "POI" | "Temporary" | "Storage"

type ServerContainer = {
	ContainerId: string,
	Kind: ContainerKind,
	Title: string,
	OwnerName: string,
	TableId: string?,
	RespawnTime: number,
	ExpiresAt: number,
	Depleted: boolean,
	Locked: boolean,
	MaxSlots: number,
	AllowDeposit: boolean,
	OwnerUserId: number?,
	OnChanged: ((slots: Inventory) -> ())?,
	Model: Model,
	PrimaryPart: BasePart,
	Prompt: ProximityPrompt?,
	Parts: { PartSnapshot },
	Slots: Inventory,
	Viewers: { [Player]: boolean },
	RespawnToken: number,
	PromptConn: RBXScriptConnection?,
	ExpireThread: thread?,
}

local DEPLETED_TRANSPARENCY = 0.75
local VIEWER_CHECK_INTERVAL = 1.0

local containers: { [string]: ServerContainer } = {}
local openContainerByPlayer: { [Player]: string } = {}
local nextTempId = 0
local nextStorageId = 0
local nextPoiFallbackId = 0
local rng = Random.new()
local isInitialized = false

local LootService = {}

local function isValidPositiveNumber(val: any): boolean
	return typeof(val) == "number" and val == val and val > 0 and val < math.huge
end

local function hasAnySlots(inv: Inventory, maxSlots: number?): boolean
	local limit = maxSlots or Types.INVENTORY_SIZE
	for i = 1, limit do
		local slot = inv[i]
		if slot ~= nil and slot.Count > 0 then
			return true
		end
	end
	return false
end

local function cloneInventory(inv: Inventory, maxSlots: number?): Inventory
	local limit = maxSlots or Types.INVENTORY_SIZE
	local copy: Inventory = {}
	for i = 1, limit do
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

local function serializeSlotsForNet(slots: Inventory, maxSlots: number?): { [string]: Slot }
	local limit = maxSlots or Types.INVENTORY_SIZE
	local raw: { [string]: Slot } = {}
	for i = 1, limit do
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

local function addItemToSlots(slots: Inventory, maxSlots: number, itemId: string, count: number): number
	local itemConfig = Items[itemId]
	if not itemConfig or count <= 0 then
		return count
	end

	local maxStack = itemConfig.MaxStack
	local remaining = count

	for i = 1, maxSlots do
		if remaining <= 0 then
			break
		end
		local slot = slots[i]
		if slot ~= nil and slot.Id == itemId and slot.Count < maxStack then
			local canAdd = math.min(remaining, maxStack - slot.Count)
			if canAdd > 0 then
				slot.Count += canAdd
				remaining -= canAdd
			end
		end
	end

	for i = 1, maxSlots do
		if remaining <= 0 then
			break
		end
		if slots[i] == nil then
			local toAdd = math.min(remaining, maxStack)
			slots[i] = {
				Id = itemId,
				Count = toAdd,
			}
			remaining -= toAdd
		end
	end

	return remaining
end

local function addLootToSlots(slots: Inventory, itemId: string, count: number)
	addItemToSlots(slots, Types.INVENTORY_SIZE, itemId, count)
end

local function computeAvailableCapacity(
	slots: Inventory,
	maxSlots: number,
	itemId: string,
	maxStack: number,
	targetSlot: number?
): number
	if targetSlot ~= nil then
		local existing = slots[targetSlot]
		if existing == nil then
			return maxStack
		elseif existing.Id == itemId and existing.Count < maxStack then
			return maxStack - existing.Count
		end
		return 0
	end

	local capacity = 0
	for i = 1, maxSlots do
		local slot = slots[i]
		if slot == nil then
			capacity += maxStack
		elseif slot.Id == itemId and slot.Count < maxStack then
			capacity += (maxStack - slot.Count)
		end
	end
	return capacity
end

local function getAliveCharacterRoot(player: Player): BasePart?
	local _, hrp = SecurityService.GetAliveCharacterRoot(player)
	return hrp
end

local function closeAllViewers(container: ServerContainer)
	local viewersToNotify: { Player } = {}
	for viewer in container.Viewers do
		table.insert(viewersToNotify, viewer)
	end
	table.clear(container.Viewers)

	local closeEvent = Net.GetEvent(Net.Events.CloseContainer)
	for _, viewer in viewersToNotify do
		if openContainerByPlayer[viewer] == container.ContainerId then
			openContainerByPlayer[viewer] = nil
		end
		SecurityService.ClearActiveContainer(viewer, container.ContainerId)
		if viewer.Parent == Players then
			closeEvent:FireClient(viewer, container.ContainerId)
		end
	end
end

local function notifyContainerViewers(container: ServerContainer)
	local payload = serializeSlotsForNet(container.Slots, container.MaxSlots)
	local openEvent = Net.GetEvent(Net.Events.OpenContainer)

	local staleViewers: { Player } = {}
	for viewer in container.Viewers do
		if viewer.Parent == Players then
			openEvent:FireClient(
				viewer,
				container.ContainerId,
				container.Title,
				payload,
				container.MaxSlots,
				container.AllowDeposit
			)
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

local function openContainerInternal(player: Player, container: ServerContainer)
	local prevContainerId = openContainerByPlayer[player]
	if prevContainerId ~= nil and prevContainerId ~= container.ContainerId then
		local prevContainer = containers[prevContainerId]
		if prevContainer ~= nil then
			prevContainer.Viewers[player] = nil
		end
	end

	openContainerByPlayer[player] = container.ContainerId
	container.Viewers[player] = true
	SecurityService.SetActiveContainer(player, container.ContainerId, container.PrimaryPart)

	Net.GetEvent(Net.Events.OpenContainer):FireClient(
		player,
		container.ContainerId,
		container.Title,
		serializeSlotsForNet(container.Slots, container.MaxSlots),
		container.MaxSlots,
		container.AllowDeposit
	)
end

local function collectPartSnapshots(model: Model): { PartSnapshot }
	local parts: { PartSnapshot } = {}
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			table.insert(parts, {
				Part = descendant,
				OriginalTransparency = descendant.Transparency,
				OriginalCanCollide = descendant.CanCollide,
				OriginalCanQuery = descendant.CanQuery,
			})
		end
	end
	return parts
end

local function depletePoiContainer(container: ServerContainer)
	container.Depleted = true
	container.Model:SetAttribute("Depleted", true)
	closeAllViewers(container)

	if container.Prompt then
		container.Prompt.Enabled = false
	end

	for _, snapshot in container.Parts do
		snapshot.Part.Transparency = DEPLETED_TRANSPARENCY
		snapshot.Part.CanCollide = false
		snapshot.Part.CanQuery = false
	end

	local effectiveRespawnTime = container.RespawnTime
	if RunService:IsStudio() then
		local override = container.Model:GetAttribute("RespawnTimeOverride")
		if isValidPositiveNumber(override) then
			effectiveRespawnTime = override :: number
		end
	end

	container.RespawnToken += 1
	local token = container.RespawnToken
	local tableId = container.TableId
	if not tableId then
		return
	end

	task.delay(effectiveRespawnTime, function()
		if containers[container.ContainerId] ~= container or container.RespawnToken ~= token then
			return
		end
		if not container.Model.Parent then
			return
		end

		container.Slots = LootService.RollLootTable(tableId)
		container.Depleted = false
		container.Model:SetAttribute("Depleted", false)

		for _, snapshot in container.Parts do
			snapshot.Part.Transparency = snapshot.OriginalTransparency
			snapshot.Part.CanCollide = snapshot.OriginalCanCollide
			snapshot.Part.CanQuery = snapshot.OriginalCanQuery
		end

		if container.Prompt then
			container.Prompt.Enabled = true
		end
	end)
end

local function cleanupContainerHandles(container: ServerContainer)
	if container.PromptConn ~= nil then
		container.PromptConn:Disconnect()
		container.PromptConn = nil
	end
	if
		container.ExpireThread ~= nil
		and container.ExpireThread ~= coroutine.running()
		and coroutine.status(container.ExpireThread) == "suspended"
	then
		pcall(task.cancel, container.ExpireThread)
	end
	container.ExpireThread = nil
end

local function bindPrompt(container: ServerContainer, prompt: ProximityPrompt)
	if container.PromptConn ~= nil then
		container.PromptConn:Disconnect()
	end
	container.PromptConn = prompt.Triggered:Connect(function(viewer: Player)
		LootService.OpenContainerForPlayer(viewer, container.ContainerId)
	end)
end

local function registerPoiCrate(model: Instance)
	if not model:IsA("Model") then
		return
	end

	local tableIdAttr = model:GetAttribute("LootTable")
	if typeof(tableIdAttr) ~= "string" or #tableIdAttr == 0 then
		return
	end

	local tableConfig = LootTables[tableIdAttr]
	if not tableConfig then
		warn(string.format('[LootService] Unknown LootTable "%s" on "%s"', tableIdAttr, model.Name))
		return
	end

	local primaryPart = model.PrimaryPart
	if not primaryPart then
		warn(string.format('[LootService] POI crate "%s" has no PrimaryPart', model.Name))
		return
	end

	local containerId: string
	local crateIdAttr = model:GetAttribute("CrateId")
	if typeof(crateIdAttr) == "string" and #crateIdAttr > 0 and containers[crateIdAttr] == nil then
		containerId = crateIdAttr
	else
		repeat
			nextPoiFallbackId += 1
			containerId = string.format("poi_crate_%d", nextPoiFallbackId)
		until containers[containerId] == nil
		model:SetAttribute("CrateId", containerId)
	end

	local titleAttr = model:GetAttribute("ContainerTitle")
	local title: string
	if typeof(titleAttr) == "string" and #titleAttr > 0 then
		title = titleAttr
	elseif tableIdAttr == "elite_crate" then
		title = "Elite Crate"
	elseif tableIdAttr == "military_crate" then
		title = "Military Crate"
	elseif tableIdAttr == "wooden_crate" then
		title = "Wooden Crate"
	else
		title = model.Name
	end

	local prompt = primaryPart:FindFirstChildOfClass("ProximityPrompt")
	if not prompt then
		local found = model:FindFirstChildWhichIsA("ProximityPrompt", true)
		if found and found:IsA("ProximityPrompt") then
			prompt = found
		end
	end
	if not prompt then
		local created = Instance.new("ProximityPrompt")
		created.Name = "SearchPrompt"
		created.ActionText = "Search Crate"
		created.ObjectText = title
		created.HoldDuration = 0
		created.MaxActivationDistance = 12
		created.RequiresLineOfSight = false
		created.Parent = primaryPart
		prompt = created
	end

	local container: ServerContainer = {
		ContainerId = containerId,
		Kind = "POI",
		Title = title,
		OwnerName = title,
		TableId = tableIdAttr,
		RespawnTime = tableConfig.RespawnTime,
		ExpiresAt = 0,
		Depleted = false,
		Locked = false,
		MaxSlots = Types.INVENTORY_SIZE,
		AllowDeposit = false,
		OwnerUserId = nil,
		OnChanged = nil,
		Model = model,
		PrimaryPart = primaryPart,
		Prompt = prompt,
		Parts = collectPartSnapshots(model),
		Slots = LootService.RollLootTable(tableIdAttr),
		Viewers = {},
		RespawnToken = 0,
		PromptConn = nil,
		ExpireThread = nil,
	}

	containers[containerId] = container
	model:SetAttribute("ContainerId", containerId)
	model:SetAttribute("Depleted", false)

	if prompt then
		bindPrompt(container, prompt)
	end
end

local function scanPoiFolder()
	local poiFolder = Workspace:FindFirstChild("POI")
	if not poiFolder then
		warn("[LootService] Workspace.POI folder not found")
		return
	end

	for _, descendant in poiFolder:GetDescendants() do
		if descendant:IsA("Model") and descendant:GetAttribute("LootTable") ~= nil then
			registerPoiCrate(descendant)
		end
	end
end

local function onCloseContainer(player: Player, containerIdAny: any)
	if not SecurityService.CheckRateLimit(player, Net.Events.CloseContainer) then
		return
	end
	if containerIdAny ~= nil and not SecurityService.IsValidString(containerIdAny, 1, 64) then
		return
	end
	LootService.CloseContainerForPlayer(player, false)
end

local function canPlayerAccessContainer(player: Player, container: ServerContainer): boolean
	if container.OwnerUserId ~= nil and player.UserId ~= container.OwnerUserId then
		return false
	end
	return true
end

local function onLootTakeSlot(player: Player, containerIdAny: any, containerSlotAny: any, targetPlayerSlotAny: any)
	if not SecurityService.CheckRateLimit(player, Net.Events.LootTakeSlot) then
		return
	end
	if not SecurityService.IsValidString(containerIdAny, 1, 64) then
		return
	end
	if not SecurityService.IsValidInteger(containerSlotAny, 1, Types.INVENTORY_SIZE) then
		return
	end
	local containerSlot = containerSlotAny :: number

	local targetPlayerSlot: number? = nil
	if targetPlayerSlotAny ~= nil then
		if not SecurityService.IsValidInteger(targetPlayerSlotAny, 1, Types.INVENTORY_SIZE) then
			return
		end
		targetPlayerSlot = targetPlayerSlotAny :: number
	end

	if DataService.IsTeleporting(player) or SecurityService.IsTransactionLocked(player) then
		return
	end
	if DataService.GetData(player) == nil then
		return
	end

	local hrp = getAliveCharacterRoot(player)
	if not hrp then
		return
	end

	local containerId = containerIdAny :: string
	if openContainerByPlayer[player] ~= containerId then
		return
	end

	local container = containers[containerId]
	if container == nil or container.Depleted or container.Locked or not container.PrimaryPart.Parent then
		return
	end

	if not canPlayerAccessContainer(player, container) then
		return
	end

	if containerSlot > container.MaxSlots then
		return
	end

	if
		(hrp.Position - container.PrimaryPart.Position).Magnitude
		> Types.MAX_LOOT_DISTANCE + Types.PING_DISTANCE_TOLERANCE
	then
		return
	end

	SecurityService.RunLocked(player, "LootTakeSlot", function()
		if
			containers[containerId] ~= container
			or container.Depleted
			or container.Locked
			or not container.PrimaryPart.Parent
			or openContainerByPlayer[player] ~= containerId
			or DataService.GetData(player) == nil
		then
			return
		end

		local innerHrp = getAliveCharacterRoot(player)
		if
			not innerHrp
			or (innerHrp.Position - container.PrimaryPart.Position).Magnitude
				> Types.MAX_LOOT_DISTANCE + Types.PING_DISTANCE_TOLERANCE
		then
			return
		end

		container.Locked = true
		local ok, err = pcall(function()
			local slot = container.Slots[containerSlot]
			if slot == nil or slot.Count <= 0 then
				return
			end

			local takenId = slot.Id
			local takenCount = slot.Count
			container.Slots[containerSlot] = nil

			local remainder: number
			if targetPlayerSlot ~= nil then
				remainder = InventoryService.AddItemToSlot(player, takenId, takenCount, targetPlayerSlot)
			else
				remainder = InventoryService.AddItem(player, takenId, takenCount)
			end

			if remainder > 0 then
				container.Slots[containerSlot] = {
					Id = takenId,
					Count = remainder,
				}
			end

			if remainder >= takenCount then
				return
			end

			if container.OnChanged then
				container.OnChanged(container.Slots)
			end

			if not hasAnySlots(container.Slots, container.MaxSlots) then
				if container.Kind == "Storage" then
					notifyContainerViewers(container)
				elseif container.Kind == "POI" and container.RespawnTime > 0 and container.TableId ~= nil then
					depletePoiContainer(container)
				else
					LootService.DestroyContainer(container.ContainerId)
				end
			else
				notifyContainerViewers(container)
			end
		end)
		container.Locked = false
		if not ok then
			error(err)
		end
	end)
end

local function onContainerDepositSlot(
	player: Player,
	containerIdAny: any,
	playerSlotAny: any,
	targetContainerSlotAny: any
)
	if not SecurityService.CheckRateLimit(player, Net.Events.ContainerDepositSlot) then
		return
	end
	if not SecurityService.IsValidString(containerIdAny, 1, 64) then
		return
	end
	if not SecurityService.IsValidInteger(playerSlotAny, 1, Types.INVENTORY_SIZE) then
		return
	end
	local playerSlotIndex = playerSlotAny :: number

	if DataService.IsTeleporting(player) or SecurityService.IsTransactionLocked(player) then
		return
	end
	if DataService.GetData(player) == nil then
		return
	end

	local hrp = getAliveCharacterRoot(player)
	if not hrp then
		return
	end

	local containerId = containerIdAny :: string
	if openContainerByPlayer[player] ~= containerId then
		return
	end

	local container = containers[containerId]
	if
		container == nil
		or container.Depleted
		or container.Locked
		or not container.PrimaryPart.Parent
		or not container.AllowDeposit
	then
		return
	end

	if not canPlayerAccessContainer(player, container) then
		return
	end

	local targetContainerSlot: number? = nil
	if targetContainerSlotAny ~= nil then
		if not SecurityService.IsValidInteger(targetContainerSlotAny, 1, container.MaxSlots) then
			return
		end
		targetContainerSlot = targetContainerSlotAny :: number
	end

	if
		(hrp.Position - container.PrimaryPart.Position).Magnitude
		> Types.MAX_LOOT_DISTANCE + Types.PING_DISTANCE_TOLERANCE
	then
		return
	end

	SecurityService.RunLocked(player, "ContainerDepositSlot", function()
		if
			containers[containerId] ~= container
			or container.Depleted
			or container.Locked
			or not container.PrimaryPart.Parent
			or not container.AllowDeposit
			or openContainerByPlayer[player] ~= containerId
			or DataService.GetData(player) == nil
		then
			return
		end

		local innerHrp = getAliveCharacterRoot(player)
		if
			not innerHrp
			or (innerHrp.Position - container.PrimaryPart.Position).Magnitude
				> Types.MAX_LOOT_DISTANCE + Types.PING_DISTANCE_TOLERANCE
		then
			return
		end

		container.Locked = true
		local ok, err = pcall(function()
			local playerSlot = InventoryService.GetSlot(player, playerSlotIndex)
			if playerSlot == nil or playerSlot.Count <= 0 then
				return
			end

			local itemId = playerSlot.Id
			local itemCount = playerSlot.Count
			local itemConfig = Items[itemId]
			if not itemConfig then
				return
			end

			local availableCapacity = computeAvailableCapacity(
				container.Slots,
				container.MaxSlots,
				itemId,
				itemConfig.MaxStack,
				targetContainerSlot
			)
			local toDeposit = math.min(itemCount, availableCapacity)
			if toDeposit <= 0 then
				return
			end

			if not InventoryService.ConsumeSlot(player, playerSlotIndex, toDeposit) then
				return
			end

			if targetContainerSlot ~= nil then
				local existing = container.Slots[targetContainerSlot]
				if existing == nil then
					container.Slots[targetContainerSlot] = {
						Id = itemId,
						Count = toDeposit,
					}
				else
					existing.Count += toDeposit
				end
			else
				local leftover = addItemToSlots(container.Slots, container.MaxSlots, itemId, toDeposit)
				if leftover > 0 then
					InventoryService.AddItemToSlot(player, itemId, leftover, playerSlotIndex)
				end
			end

			if container.OnChanged then
				container.OnChanged(container.Slots)
			end

			notifyContainerViewers(container)
		end)
		container.Locked = false
		if not ok then
			error(err)
		end
	end)
end

local function stepViewerDistanceCheck()
	if next(openContainerByPlayer) == nil then
		return
	end
	local toClose: { Player } = {}
	for player, openId in openContainerByPlayer do
		local container = containers[openId]
		local hrp = getAliveCharacterRoot(player)
		if
			container == nil
			or container.Depleted
			or not container.PrimaryPart.Parent
			or not hrp
			or (hrp.Position - container.PrimaryPart.Position).Magnitude > (Types.MAX_LOOT_DISTANCE + 2)
		then
			table.insert(toClose, player)
		end
	end

	for _, player in toClose do
		LootService.CloseContainerForPlayer(player, true)
	end
end

function LootService.RollLootTable(tableId: string, mapTierOverride: number?): Inventory
	local slots: Inventory = {}
	if typeof(tableId) ~= "string" then
		return slots
	end

	local config = LootTables[tableId]
	if not config then
		warn(string.format('[LootService] Unknown loot table "%s"', tableId))
		return slots
	end

	local validEntries: { LootDropEntry } = {}
	local totalWeight = 0
	for _, entry in config.Items do
		if entry.Weight > 0 and Items[entry.Id] ~= nil then
			totalWeight += entry.Weight
			table.insert(validEntries, entry)
		end
	end

	if totalWeight <= 0 or #validEntries == 0 then
		return slots
	end

	local rawTier = if typeof(mapTierOverride) == "number" then mapTierOverride else Workspace:GetAttribute("MapTier")
	local mapTier = if typeof(rawTier) == "number" then math.clamp(math.floor(rawTier), 1, 3) else 1
	local scaleMap = Config.MapLootScaling :: { [number]: number }
	local scale = scaleMap[mapTier] or 1.0

	for _ = 1, config.Rolls do
		local target = rng:NextNumber(0, totalWeight)
		local cumulative = 0
		local chosen = validEntries[#validEntries]
		for _, entry in validEntries do
			cumulative += entry.Weight
			if target <= cumulative then
				chosen = entry
				break
			end
		end

		local minCount = math.min(chosen.MinCount, chosen.MaxCount)
		local maxCount = math.max(chosen.MinCount, chosen.MaxCount)
		local rolledCount = rng:NextInteger(minCount, maxCount)
		local itemCfg = Items[chosen.Id]
		if itemCfg ~= nil and itemCfg.Type == "Resource" and scale ~= 1.0 then
			rolledCount = math.max(1, math.floor(rolledCount * scale + 0.5))
		end
		addLootToSlots(slots, chosen.Id, rolledCount)
	end

	return slots
end

function LootService.RegisterSlotsContainer(
	model: Model,
	title: string,
	ownerName: string,
	slots: Inventory,
	lifeTime: number
): string
	local primaryPart = model.PrimaryPart
	if not primaryPart then
		warn(string.format('[LootService] Temporary container "%s" has no PrimaryPart', model.Name))
		return ""
	end

	nextTempId += 1
	local containerId = string.format("temp_%d", nextTempId)
	local expiresAt = if lifeTime > 0 then Workspace:GetServerTimeNow() + lifeTime else 0

	local prompt = primaryPart:FindFirstChildOfClass("ProximityPrompt")
	if not prompt then
		local found = model:FindFirstChildWhichIsA("ProximityPrompt", true)
		if found and found:IsA("ProximityPrompt") then
			prompt = found
		end
	end
	if not prompt then
		local created = Instance.new("ProximityPrompt")
		created.Name = "LootPrompt"
		created.ActionText = "Open Container"
		created.ObjectText = title
		created.HoldDuration = 0
		created.MaxActivationDistance = 12
		created.RequiresLineOfSight = false
		created.Parent = primaryPart
		prompt = created
	end

	local container: ServerContainer = {
		ContainerId = containerId,
		Kind = "Temporary",
		Title = title,
		OwnerName = ownerName,
		TableId = nil,
		RespawnTime = 0,
		ExpiresAt = expiresAt,
		Depleted = false,
		Locked = false,
		MaxSlots = Types.INVENTORY_SIZE,
		AllowDeposit = false,
		OwnerUserId = nil,
		OnChanged = nil,
		Model = model,
		PrimaryPart = primaryPart,
		Prompt = prompt,
		Parts = collectPartSnapshots(model),
		Slots = cloneInventory(slots, Types.INVENTORY_SIZE),
		Viewers = {},
		RespawnToken = 0,
		PromptConn = nil,
		ExpireThread = nil,
	}

	containers[containerId] = container
	model:SetAttribute("ContainerId", containerId)
	model:SetAttribute("OwnerName", ownerName)
	model:SetAttribute("ExpiresAt", expiresAt)
	model:SetAttribute("Depleted", false)

	if prompt then
		bindPrompt(container, prompt)
	end

	if lifeTime > 0 then
		container.ExpireThread = task.delay(lifeTime, function()
			container.ExpireThread = nil
			if containers[containerId] == container then
				LootService.DestroyContainer(containerId)
			end
		end)
	end

	return containerId
end

function LootService.SpawnTemporaryContainer(model: Model, title: string, tableId: string, lifeTime: number): string
	local slots = LootService.RollLootTable(tableId)
	return LootService.RegisterSlotsContainer(model, title, title, slots, lifeTime)
end

function LootService.RegisterStorageContainer(
	model: Model,
	title: string,
	ownerUserId: number?,
	maxSlots: number,
	initialSlots: Inventory,
	onChanged: ((slots: Inventory) -> ())?,
	allowDeposit: boolean?
): string
	local primaryPart = model.PrimaryPart
	if not primaryPart then
		warn(string.format('[LootService] Storage container "%s" has no PrimaryPart', model.Name))
		return ""
	end

	local canDeposit = if allowDeposit == nil then true else allowDeposit == true
	local effectiveMaxSlots = math.clamp(math.floor(maxSlots), 1, Types.INVENTORY_SIZE)
	local containerId: string
	repeat
		nextStorageId += 1
		containerId = string.format("storage_%d", nextStorageId)
	until containers[containerId] == nil

	local prompt = primaryPart:FindFirstChildOfClass("ProximityPrompt")
	if not prompt then
		local found = model:FindFirstChildWhichIsA("ProximityPrompt", true)
		if found and found:IsA("ProximityPrompt") then
			prompt = found
		end
	end
	if not prompt then
		local created = Instance.new("ProximityPrompt")
		created.Name = "StoragePrompt"
		created.ActionText = if canDeposit then "Open Storage" else "Loot Chest"
		created.ObjectText = title
		created.HoldDuration = 0
		created.MaxActivationDistance = 12
		created.RequiresLineOfSight = false
		created.Parent = primaryPart
		prompt = created
	end

	local container: ServerContainer = {
		ContainerId = containerId,
		Kind = "Storage",
		Title = title,
		OwnerName = title,
		TableId = nil,
		RespawnTime = 0,
		ExpiresAt = 0,
		Depleted = false,
		Locked = false,
		MaxSlots = effectiveMaxSlots,
		AllowDeposit = canDeposit,
		OwnerUserId = ownerUserId,
		OnChanged = onChanged,
		Model = model,
		PrimaryPart = primaryPart,
		Prompt = prompt,
		Parts = collectPartSnapshots(model),
		Slots = cloneInventory(initialSlots, effectiveMaxSlots),
		Viewers = {},
		RespawnToken = 0,
		PromptConn = nil,
		ExpireThread = nil,
	}

	containers[containerId] = container
	model:SetAttribute("ContainerId", containerId)
	if ownerUserId ~= nil then
		model:SetAttribute("OwnerUserId", ownerUserId)
	end
	model:SetAttribute("Depleted", false)

	if prompt then
		bindPrompt(container, prompt)
	end

	return containerId
end

function LootService.UnregisterContainer(containerId: string)
	local container = containers[containerId]
	if container == nil then
		return
	end
	containers[containerId] = nil
	cleanupContainerHandles(container)
	closeAllViewers(container)
end

function LootService.OpenContainerForPlayer(player: Player, containerId: string): boolean
	if typeof(containerId) ~= "string" or #containerId == 0 then
		return false
	end

	if DataService.IsTeleporting(player) or SecurityService.IsTransactionLocked(player) then
		return false
	end

	local container = containers[containerId]
	if container == nil or container.Depleted or not container.PrimaryPart.Parent then
		return false
	end

	if not canPlayerAccessContainer(player, container) then
		return false
	end

	if DataService.GetData(player) == nil then
		return false
	end

	local hrp = getAliveCharacterRoot(player)
	if not hrp then
		return false
	end

	if (hrp.Position - container.PrimaryPart.Position).Magnitude > Types.MAX_LOOT_DISTANCE then
		return false
	end

	openContainerInternal(player, container)
	return true
end

function LootService.CloseContainerForPlayer(player: Player, notifyClient: boolean)
	local containerId = openContainerByPlayer[player]
	if containerId == nil then
		SecurityService.ClearActiveContainer(player, nil)
		return
	end
	openContainerByPlayer[player] = nil
	SecurityService.ClearActiveContainer(player, containerId)

	local container = containers[containerId]
	if container ~= nil then
		container.Viewers[player] = nil
	end

	if notifyClient and player.Parent == Players then
		Net.GetEvent(Net.Events.CloseContainer):FireClient(player, containerId)
	end
end

function LootService.DestroyContainer(containerId: string)
	local container = containers[containerId]
	if container == nil then
		return
	end
	containers[containerId] = nil
	cleanupContainerHandles(container)
	closeAllViewers(container)

	if container.Model.Parent then
		container.Model:Destroy()
	end
end

function LootService.GetContainerState(containerId: string): LootContainerState?
	local container = containers[containerId]
	if not container then
		return nil
	end
	return {
		ContainerId = container.ContainerId,
		OwnerName = container.OwnerName,
		Slots = cloneInventory(container.Slots, container.MaxSlots),
		ExpiresAt = container.ExpiresAt,
	}
end

function LootService.DepositToStorageContainer(containerId: string, itemId: string, count: number): number
	local container = containers[containerId]
	if container == nil or container.Kind ~= "Storage" or count <= 0 then
		return 0
	end
	local toAdd = math.floor(count)
	local leftover = addItemToSlots(container.Slots, container.MaxSlots, itemId, toAdd)
	local deposited = toAdd - leftover
	if deposited > 0 then
		if container.OnChanged then
			container.OnChanged(container.Slots)
		end
		notifyContainerViewers(container)
	end
	return deposited
end

function LootService.ClearContainerSlots(containerId: string)
	local container = containers[containerId]
	if container == nil then
		return
	end
	table.clear(container.Slots)
	if container.OnChanged then
		container.OnChanged(container.Slots)
	end
	notifyContainerViewers(container)
end

function LootService.IsContainerDepleted(containerId: string): boolean
	local container = containers[containerId]
	if not container then
		return false
	end
	return container.Depleted
end

function LootService.Init()
	if isInitialized then
		return
	end
	isInitialized = true

	Net.InitServer()
	scanPoiFolder()

	Net.GetEvent(Net.Events.CloseContainer).OnServerEvent:Connect(onCloseContainer)
	Net.GetEvent(Net.Events.LootTakeSlot).OnServerEvent:Connect(onLootTakeSlot)
	Net.GetEvent(Net.Events.ContainerDepositSlot).OnServerEvent:Connect(onContainerDepositSlot)

	Players.PlayerRemoving:Connect(function(player: Player)
		LootService.CloseContainerForPlayer(player, false)
	end)

	task.spawn(function()
		while true do
			task.wait(VIEWER_CHECK_INTERVAL)
			stepViewerDistanceCheck()
		end
	end)
end

return LootService
