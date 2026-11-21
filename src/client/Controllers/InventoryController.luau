--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage.Shared.Types)
local Net = require(ReplicatedStorage.Shared.Net)

type Inventory = Types.Inventory
type Slot = Types.Slot

local currentInventory: Inventory = {}
local changedListeners: { (inventory: Inventory) -> () } = {}
local isInitialized = false

local InventoryController = {}

local function parseSyncPayload(payload: any): Inventory
	local inv: Inventory = {}
	if type(payload) ~= "table" then
		return inv
	end

	for k, v in payload do
		local index = if type(k) == "number" then k else tonumber(k)
		if
			index
			and index >= 1
			and index <= Types.INVENTORY_SIZE
			and index % 1 == 0
			and type(v) == "table"
			and type(v.Id) == "string"
			and type(v.Count) == "number"
			and v.Count > 0
		then
			inv[index] = {
				Id = v.Id,
				Count = v.Count,
			}
		end
	end
	return inv
end

local function fireChanged()
	for _, listener in changedListeners do
		task.spawn(listener, currentInventory)
	end
end

function InventoryController.GetInventory(): Inventory
	return currentInventory
end

function InventoryController.GetSlot(slotIndex: number): Slot?
	return currentInventory[slotIndex]
end

function InventoryController.OnChanged(callback: (inventory: Inventory) -> ()): () -> ()
	table.insert(changedListeners, callback)
	task.spawn(callback, currentInventory)

	return function()
		local idx = table.find(changedListeners, callback)
		if idx then
			table.remove(changedListeners, idx)
		end
	end
end

function InventoryController.RequestMove(fromSlot: number, toSlot: number)
	local moveEvent = Net.GetEvent(Net.Events.InventoryMove)
	moveEvent:FireServer(fromSlot, toSlot)
end

function InventoryController.Init()
	if isInitialized then
		return
	end
	isInitialized = true

	local syncEvent = Net.GetEvent(Net.Events.InventorySync)
	syncEvent.OnClientEvent:Connect(function(payload: any)
		currentInventory = parseSyncPayload(payload)
		fireChanged()
	end)
end

return InventoryController
