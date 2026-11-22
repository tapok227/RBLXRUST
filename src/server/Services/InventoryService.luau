--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local Types = require(ReplicatedStorage.Shared.Types)
local Items = require(ReplicatedStorage.Shared.configs.Items)
local Net = require(ReplicatedStorage.Shared.Net)
local DataService = require(ServerScriptService.Server.Services.DataService)
local SecurityService = require(ServerScriptService.Server.Services.SecurityService)

type Inventory = Types.Inventory
type Slot = Types.Slot
type ItemBatchEntry = Types.ItemBatchEntry
type Ingredient = Types.Ingredient

local equippedSlots: { [Player]: number } = {}
local isInitialized = false

local InventoryService = {}

local function isValidInteger(val: any): boolean
	return typeof(val) == "number" and val == val and val % 1 == 0 and math.abs(val) ~= math.huge
end

local function isInventoryEmpty(inv: Inventory): boolean
	for i = 1, Types.INVENTORY_SIZE do
		local slot = inv[i]
		if slot ~= nil and slot.Count > 0 then
			return false
		end
	end
	return true
end

local function cloneInventory(inv: Inventory): Inventory
	local copy: Inventory = {}
	for i = 1, Types.INVENTORY_SIZE do
		local slot = inv[i]
		if slot ~= nil then
			copy[i] = {
				Id = slot.Id,
				Count = slot.Count,
			}
		end
	end
	return copy
end

local function serializeInventoryForNet(inv: Inventory): { [string]: Slot }
	local raw: { [string]: Slot } = {}
	for i = 1, Types.INVENTORY_SIZE do
		local slot = inv[i]
		if slot ~= nil and slot.Count > 0 then
			raw[tostring(i)] = {
				Id = slot.Id,
				Count = slot.Count,
			}
		end
	end
	return raw
end

local function updateEquippedAttribute(player: Player)
	if player.Parent ~= Players then
		return
	end
	local data = DataService.GetData(player)
	local slotIndex = equippedSlots[player] or 1
	local slot = if data then data.Inventory[slotIndex] else nil
	local equippedId = if slot ~= nil and slot.Count > 0 then slot.Id else ""
	if player:GetAttribute("EquippedItemId") ~= equippedId then
		player:SetAttribute("EquippedItemId", equippedId)
	end
end

local function sendInventorySync(player: Player)
	if player.Parent ~= Players then
		return
	end
	local data = DataService.GetData(player)
	if not data then
		return
	end
	updateEquippedAttribute(player)
	local syncEvent = Net.GetEvent(Net.Events.InventorySync)
	syncEvent:FireClient(player, serializeInventoryForNet(data.Inventory))
end

local function addItemInternal(inv: Inventory, id: string, count: number): (number, boolean)
	if typeof(id) ~= "string" or not isValidInteger(count) or count <= 0 then
		return (if typeof(count) == "number" and count > 0 then count else 0), false
	end

	local itemConfig = Items[id]
	if not itemConfig then
		return count, false
	end

	local remaining = count
	local maxStack = itemConfig.MaxStack
	local changed = false

	-- 1. Fill existing stacks of the same item
	for i = 1, Types.INVENTORY_SIZE do
		if remaining <= 0 then
			break
		end
		local slot = inv[i]
		if slot ~= nil and slot.Id == id and slot.Count < maxStack then
			local canAdd = math.min(remaining, maxStack - slot.Count)
			if canAdd > 0 then
				slot.Count += canAdd
				remaining -= canAdd
				changed = true
			end
		end
	end

	-- 2. Fill empty slots
	for i = 1, Types.INVENTORY_SIZE do
		if remaining <= 0 then
			break
		end
		local slot = inv[i]
		if slot == nil then
			local toAdd = math.min(remaining, maxStack)
			inv[i] = {
				Id = id,
				Count = toAdd,
			}
			remaining -= toAdd
			changed = true
		end
	end

	return remaining, changed
end

local function getCountInInventory(inv: Inventory, id: string): number
	local total = 0
	for i = 1, Types.INVENTORY_SIZE do
		local slot = inv[i]
		if slot ~= nil and slot.Id == id then
			total += slot.Count
		end
	end
	return total
end

local function removeItemInternal(inv: Inventory, id: string, count: number): boolean
	if typeof(id) ~= "string" or not isValidInteger(count) or count <= 0 then
		return false
	end

	if not Items[id] then
		return false
	end

	if getCountInInventory(inv, id) < count then
		return false
	end

	local remainingToRemove = count
	for i = Types.INVENTORY_SIZE, 1, -1 do
		if remainingToRemove <= 0 then
			break
		end
		local slot = inv[i]
		if slot ~= nil and slot.Id == id then
			local take = math.min(slot.Count, remainingToRemove)
			slot.Count -= take
			remainingToRemove -= take
			if slot.Count <= 0 then
				inv[i] = nil
			end
		end
	end

	return true
end

function InventoryService.GetEquippedSlot(player: Player): number
	return equippedSlots[player] or 1
end

function InventoryService.GetEquippedItem(player: Player): Slot?
	local data = DataService.GetData(player)
	if not data then
		return nil
	end
	local slotIndex = equippedSlots[player] or 1
	return data.Inventory[slotIndex]
end

function InventoryService.GetSlot(player: Player, slotIndex: number): Slot?
	if not isValidInteger(slotIndex) or slotIndex < 1 or slotIndex > Types.INVENTORY_SIZE then
		return nil
	end
	local data = DataService.GetData(player)
	if not data then
		return nil
	end
	return data.Inventory[slotIndex]
end

function InventoryService.GetItemCount(player: Player, id: string): number
	if typeof(id) ~= "string" then
		return 0
	end
	local data = DataService.GetData(player)
	if not data then
		return 0
	end
	return getCountInInventory(data.Inventory, id)
end

function InventoryService.HasItems(player: Player, items: { ItemBatchEntry }): boolean
	local data = DataService.GetData(player)
	if not data then
		return false
	end

	local totalsRequired: { [string]: number } = {}
	for _, entry in items do
		if
			typeof(entry.Id) ~= "string"
			or not isValidInteger(entry.Count)
			or entry.Count <= 0
			or not Items[entry.Id]
		then
			return false
		end
		totalsRequired[entry.Id] = (totalsRequired[entry.Id] or 0) + entry.Count
	end

	for itemId, requiredCount in totalsRequired do
		if getCountInInventory(data.Inventory, itemId) < requiredCount then
			return false
		end
	end

	return true
end

function InventoryService.CanCraftTransaction(
	player: Player,
	ingredients: { Ingredient },
	resultId: string,
	resultCount: number
): boolean
	if typeof(resultId) ~= "string" or not Items[resultId] or not isValidInteger(resultCount) or resultCount <= 0 then
		return false
	end

	local data = DataService.GetData(player)
	if not data then
		return false
	end

	local simulated = cloneInventory(data.Inventory)
	for _, ing in ingredients do
		if not removeItemInternal(simulated, ing.Id, ing.Count) then
			return false
		end
	end

	local remainder = addItemInternal(simulated, resultId, resultCount)
	return remainder == 0
end

function InventoryService.CanAddItems(player: Player, items: { ItemBatchEntry }): boolean
	local data = DataService.GetData(player)
	if not data then
		return false
	end

	local simulated = cloneInventory(data.Inventory)
	for _, entry in items do
		if
			typeof(entry.Id) ~= "string"
			or not isValidInteger(entry.Count)
			or entry.Count <= 0
			or not Items[entry.Id]
		then
			return false
		end
		local rem = addItemInternal(simulated, entry.Id, entry.Count)
		if rem > 0 then
			return false
		end
	end

	return true
end

function InventoryService.GetSnapshot(player: Player): Inventory
	local data = DataService.GetData(player)
	if not data then
		return {}
	end
	return cloneInventory(data.Inventory)
end

function InventoryService.RestoreSnapshot(player: Player, snapshot: Inventory)
	local data = DataService.GetData(player)
	if not data then
		return
	end
	data.Inventory = cloneInventory(snapshot)
	sendInventorySync(player)
end

function InventoryService.AddItem(player: Player, id: string, count: number): number
	if typeof(id) ~= "string" or not isValidInteger(count) or count <= 0 then
		return if typeof(count) == "number" and count > 0 then count else 0
	end

	if not Items[id] then
		return count
	end

	local data = DataService.GetData(player)
	if not data then
		return count
	end

	local remaining, changed = addItemInternal(data.Inventory, id, count)
	if changed then
		sendInventorySync(player)
	end

	return remaining
end

function InventoryService.AddItems(player: Player, items: { ItemBatchEntry }): { number }
	local remainders: { number } = {}
	local data = DataService.GetData(player)
	if not data then
		for i, entry in items do
			remainders[i] = entry.Count
		end
		return remainders
	end

	local anyChanged = false
	for i, entry in items do
		local rem, changed = addItemInternal(data.Inventory, entry.Id, entry.Count)
		remainders[i] = rem
		if changed then
			anyChanged = true
		end
	end

	if anyChanged then
		sendInventorySync(player)
	end

	return remainders
end

function InventoryService.RemoveItem(player: Player, id: string, count: number): boolean
	local data = DataService.GetData(player)
	if not data then
		return false
	end

	if not removeItemInternal(data.Inventory, id, count) then
		return false
	end

	sendInventorySync(player)
	return true
end

function InventoryService.RemoveItems(player: Player, items: { ItemBatchEntry }): boolean
	if not InventoryService.HasItems(player, items) then
		return false
	end

	local data = DataService.GetData(player)
	if not data then
		return false
	end

	local snapshot = cloneInventory(data.Inventory)
	for _, entry in items do
		if not removeItemInternal(data.Inventory, entry.Id, entry.Count) then
			data.Inventory = snapshot
			return false
		end
	end

	sendInventorySync(player)
	return true
end

function InventoryService.ConsumeSlot(player: Player, slotIndex: number, count: number): boolean
	if
		not isValidInteger(slotIndex)
		or slotIndex < 1
		or slotIndex > Types.INVENTORY_SIZE
		or not isValidInteger(count)
		or count <= 0
	then
		return false
	end

	local data = DataService.GetData(player)
	if not data then
		return false
	end

	local slot = data.Inventory[slotIndex]
	if slot == nil or slot.Count < count then
		return false
	end

	slot.Count -= count
	if slot.Count <= 0 then
		data.Inventory[slotIndex] = nil
	end

	sendInventorySync(player)
	return true
end

function InventoryService.ClearInventory(player: Player): Inventory
	local data = DataService.GetData(player)
	if not data then
		return {}
	end

	local snapshot = cloneInventory(data.Inventory)
	table.clear(data.Inventory)
	sendInventorySync(player)
	return snapshot
end

function InventoryService.AddItemToSlot(player: Player, id: string, count: number, targetSlot: number): number
	if
		typeof(id) ~= "string"
		or not isValidInteger(count)
		or count <= 0
		or not isValidInteger(targetSlot)
		or targetSlot < 1
		or targetSlot > Types.INVENTORY_SIZE
	then
		return if typeof(count) == "number" and count > 0 then count else 0
	end

	local itemConfig = Items[id]
	if not itemConfig then
		return count
	end

	local data = DataService.GetData(player)
	if not data then
		return count
	end

	local maxStack = itemConfig.MaxStack
	local existing = data.Inventory[targetSlot]
	local changed = false
	local remaining = count

	if existing == nil then
		local toAdd = math.min(remaining, maxStack)
		if toAdd > 0 then
			data.Inventory[targetSlot] = {
				Id = id,
				Count = toAdd,
			}
			remaining -= toAdd
			changed = true
		end
	elseif existing.Id == id and existing.Count < maxStack then
		local canAdd = math.min(remaining, maxStack - existing.Count)
		if canAdd > 0 then
			existing.Count += canAdd
			remaining -= canAdd
			changed = true
		end
	end

	if changed then
		sendInventorySync(player)
	end

	return remaining
end

local function onInventoryMove(player: Player, fromSlotAny: any, toSlotAny: any)
	if not SecurityService.CheckRateLimit(player, Net.Events.InventoryMove) then
		return
	end

	if
		not SecurityService.IsValidInteger(fromSlotAny, 1, Types.INVENTORY_SIZE)
		or not SecurityService.IsValidInteger(toSlotAny, 1, Types.INVENTORY_SIZE)
	then
		return
	end

	local fromSlot = fromSlotAny :: number
	local toSlot = toSlotAny :: number
	if fromSlot == toSlot then
		return
	end

	if DataService.IsTeleporting(player) or SecurityService.IsTransactionLocked(player) then
		return
	end

	if SecurityService.GetAliveCharacterRoot(player) == nil then
		return
	end

	if SecurityService.IsActiveContainerOutOfRange(player, Types.MAX_LOOT_DISTANCE, Types.PING_DISTANCE_TOLERANCE) then
		return
	end

	SecurityService.RunLocked(player, "InventoryMove", function()
		if SecurityService.GetAliveCharacterRoot(player) == nil then
			return
		end

		local data = DataService.GetData(player)
		if not data then
			return
		end

		local inv = data.Inventory
		local source = inv[fromSlot]
		if source == nil or source.Count <= 0 then
			return
		end

		local target = inv[toSlot]
		if target == nil then
			inv[fromSlot] = nil
			inv[toSlot] = source
			sendInventorySync(player)
			return
		end

		if source.Id == target.Id then
			local itemConfig = Items[source.Id]
			local maxStack = if itemConfig then itemConfig.MaxStack else 1
			if target.Count < maxStack then
				local transfer = math.min(source.Count, maxStack - target.Count)
				if transfer > 0 then
					source.Count -= transfer
					if source.Count <= 0 then
						inv[fromSlot] = nil
					end
					target.Count += transfer
					sendInventorySync(player)
				end
			end
		else
			inv[fromSlot] = nil
			inv[toSlot] = nil
			inv[toSlot] = source
			inv[fromSlot] = target
			sendInventorySync(player)
		end
	end)
end

local function onHotbarSelect(player: Player, slotAny: any)
	if not SecurityService.CheckRateLimit(player, Net.Events.HotbarSelect) then
		return
	end

	if not SecurityService.IsValidInteger(slotAny, 1, Types.HOTBAR_SIZE) then
		return
	end

	if
		DataService.GetData(player) == nil
		or DataService.IsTeleporting(player)
		or SecurityService.IsTeleportLocked(player)
	then
		return
	end

	if SecurityService.GetAliveCharacterRoot(player) == nil then
		return
	end

	equippedSlots[player] = slotAny :: number
	updateEquippedAttribute(player)
end

local function onPlayerDataLoaded(player: Player, data: Types.PlayerData)
	if equippedSlots[player] == nil then
		equippedSlots[player] = 1
	end

	if RunService:IsStudio() then
		if isInventoryEmpty(data.Inventory) then
			InventoryService.AddItems(player, {
				{ Id = "building_plan", Count = 1 },
				{ Id = "hammer", Count = 1 },
				{ Id = "hatchet", Count = 1 },
				{ Id = "pickaxe", Count = 1 },
				{ Id = "hunting_bow", Count = 1 },
				{ Id = "rocket_launcher", Count = 1 },
				{ Id = "satchel_charge", Count = 3 },
				{ Id = "arrow", Count = 20 },
				{ Id = "pistol_ammo", Count = 32 },
				{ Id = "shotgun_shell", Count = 24 },
				{ Id = "rocket", Count = 6 },
				{ Id = "wood", Count = 500 },
				{ Id = "stone", Count = 300 },
				{ Id = "metal_ore", Count = 300 },
				{ Id = "tech_parts", Count = 20 },
				{ Id = "high_quality_metal", Count = 60 },
				{ Id = "bandage", Count = 5 },
				{ Id = "cooked_meat", Count = 3 },
				{ Id = "water_bottle", Count = 3 },
				{ Id = "cloth", Count = 20 },
			})
			return
		else
			local topUp: { ItemBatchEntry } = {}
			if InventoryService.GetItemCount(player, "building_plan") == 0 then
				table.insert(topUp, { Id = "building_plan", Count = 1 })
			end
			if InventoryService.GetItemCount(player, "hammer") == 0 then
				table.insert(topUp, { Id = "hammer", Count = 1 })
			end
			if InventoryService.GetItemCount(player, "wood") < 300 then
				table.insert(topUp, { Id = "wood", Count = 500 })
			end
			if InventoryService.GetItemCount(player, "stone") < 200 then
				table.insert(topUp, { Id = "stone", Count = 300 })
			end
			if InventoryService.GetItemCount(player, "tech_parts") < 10 then
				table.insert(topUp, { Id = "tech_parts", Count = 20 })
			end
			if InventoryService.GetItemCount(player, "high_quality_metal") < 30 then
				table.insert(topUp, { Id = "high_quality_metal", Count = 60 })
			end
			if InventoryService.GetItemCount(player, "metal_ore") < 200 then
				table.insert(topUp, { Id = "metal_ore", Count = 300 })
			end
			if InventoryService.GetItemCount(player, "cloth") == 0 then
				table.insert(topUp, { Id = "cloth", Count = 20 })
			end
			if InventoryService.GetItemCount(player, "water_bottle") == 0 then
				table.insert(topUp, { Id = "water_bottle", Count = 3 })
			end
			if InventoryService.GetItemCount(player, "hunting_bow") == 0 then
				table.insert(topUp, { Id = "hunting_bow", Count = 1 })
			end
			if InventoryService.GetItemCount(player, "rocket_launcher") == 0 then
				table.insert(topUp, { Id = "rocket_launcher", Count = 1 })
			end
			if InventoryService.GetItemCount(player, "satchel_charge") == 0 then
				table.insert(topUp, { Id = "satchel_charge", Count = 3 })
			end
			if InventoryService.GetItemCount(player, "arrow") == 0 then
				table.insert(topUp, { Id = "arrow", Count = 20 })
			end
			if InventoryService.GetItemCount(player, "pistol_ammo") == 0 then
				table.insert(topUp, { Id = "pistol_ammo", Count = 32 })
			end
			if InventoryService.GetItemCount(player, "shotgun_shell") == 0 then
				table.insert(topUp, { Id = "shotgun_shell", Count = 24 })
			end
			if InventoryService.GetItemCount(player, "rocket") == 0 then
				table.insert(topUp, { Id = "rocket", Count = 6 })
			end
			if #topUp > 0 then
				InventoryService.AddItems(player, topUp)
				return
			end
		end
	end

	sendInventorySync(player)
end

function InventoryService.Init()
	if isInitialized then
		return
	end
	isInitialized = true

	Net.InitServer()

	local moveEvent = Net.GetEvent(Net.Events.InventoryMove)
	moveEvent.OnServerEvent:Connect(onInventoryMove)

	local hotbarSelectEvent = Net.GetEvent(Net.Events.HotbarSelect)
	hotbarSelectEvent.OnServerEvent:Connect(onHotbarSelect)

	Players.PlayerRemoving:Connect(function(player: Player)
		equippedSlots[player] = nil
	end)

	DataService.OnDataLoaded(onPlayerDataLoaded)
end

return InventoryService
