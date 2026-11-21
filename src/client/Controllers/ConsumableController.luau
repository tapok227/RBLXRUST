--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Items = require(ReplicatedStorage.Shared.configs.Items)
local Consumables = require(ReplicatedStorage.Shared.configs.Consumables)
local Net = require(ReplicatedStorage.Shared.Net)
local HotbarController = require(script.Parent.HotbarController)
local InventoryController = require(script.Parent.InventoryController)
local InventoryUIController = require(script.Parent.InventoryUIController)
local CraftingController = require(script.Parent.CraftingController)
local LootController = require(script.Parent.LootController)
local BuildingController = require(script.Parent.BuildingController)

local nextUseTime = 0
local isInitialized = false

local ConsumableController = {}

local function tryUseEquippedConsumable()
	if
		BuildingController.IsBuildMode()
		or InventoryUIController.IsOpen()
		or CraftingController.IsOpen()
		or LootController.IsOpen()
	then
		return
	end

	local selectedSlot = HotbarController.GetSelectedSlot()
	local slotData = InventoryController.GetSlot(selectedSlot)
	if slotData == nil or slotData.Count <= 0 then
		return
	end

	local itemConfig = Items[slotData.Id]
	local consumableConfig = Consumables[slotData.Id]
	if not itemConfig or itemConfig.Type ~= "Consumable" or not consumableConfig then
		return
	end

	local now = os.clock()
	if now < nextUseTime then
		return
	end
	nextUseTime = now + consumableConfig.UseCooldown

	Net.GetEvent(Net.Events.UseConsumable):FireServer(selectedSlot)
end

function ConsumableController.Init()
	if isInitialized then
		return
	end
	isInitialized = true

	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessedEvent: boolean)
		if gameProcessedEvent then
			return
		end
		if UserInputService:GetFocusedTextBox() ~= nil then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			tryUseEquippedConsumable()
		end
	end)
end

return ConsumableController
