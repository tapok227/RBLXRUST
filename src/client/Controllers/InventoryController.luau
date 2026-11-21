--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage.Shared.Types)
local Net = require(ReplicatedStorage.Shared.Net)
local Signal = require(ReplicatedStorage.Shared.Signal)

type Inventory = Types.Inventory
type Slot = Types.Slot

local currentInventory: Inventory = {}
local changedSignal: Signal.Signal<Inventory> = Signal.new()
local isInitialized = false

local InventoryController = {
	Changed = changedSignal,
}

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

function InventoryController.GetInventory(): Inventory
	return currentInventory
end

function InventoryController.GetSlot(slotIndex: number): Slot?
	return currentInventory[slotIndex]
end

function InventoryController.OnChanged(callback: (inventory: Inventory) -> ()): Signal.Connection
	local conn = changedSignal:Connect(callback)
	task.spawn(callback, currentInventory)
	return conn
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
		changedSignal:Fire(currentInventory)
	end)
end

return InventoryController
