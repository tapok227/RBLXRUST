--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Types = require(ReplicatedStorage.Shared.Types)
local Items = require(ReplicatedStorage.Shared.configs.Items)
local Net = require(ReplicatedStorage.Shared.Net)
local InventoryController = require(script.Parent.InventoryController)

type Inventory = Types.Inventory

type SlotUI = {
	Frame: Frame,
	Stroke: UIStroke,
	KeyLabel: TextLabel,
	NameLabel: TextLabel,
	CountLabel: TextLabel,
}

local KEYCODE_TO_SLOT: { [Enum.KeyCode]: number } = {
	[Enum.KeyCode.One] = 1,
	[Enum.KeyCode.Two] = 2,
	[Enum.KeyCode.Three] = 3,
	[Enum.KeyCode.Four] = 4,
	[Enum.KeyCode.Five] = 5,
	[Enum.KeyCode.Six] = 6,
}

local COLOR_BG_DEFAULT = Color3.fromRGB(30, 30, 35)
local COLOR_BG_SELECTED = Color3.fromRGB(55, 50, 35)
local COLOR_STROKE_DEFAULT = Color3.fromRGB(80, 80, 90)
local COLOR_STROKE_SELECTED = Color3.fromRGB(245, 190, 65)

local selectedSlot: number = 1
local slotUIs: { [number]: SlotUI } = {}
local isInitialized = false

local HotbarController = {}

local function updateSelectionVisuals()
	for i = 1, Types.HOTBAR_SIZE do
		local ui = slotUIs[i]
		if ui then
			local isSelected = (i == selectedSlot)
			ui.Frame.BackgroundColor3 = if isSelected then COLOR_BG_SELECTED else COLOR_BG_DEFAULT
			ui.Stroke.Color = if isSelected then COLOR_STROKE_SELECTED else COLOR_STROKE_DEFAULT
			ui.Stroke.Thickness = if isSelected then 2.5 else 1.5
		end
	end
end

local function updateSlotsContent(inv: Inventory)
	for i = 1, Types.HOTBAR_SIZE do
		local ui = slotUIs[i]
		if ui then
			local slotData = inv[i]
			if slotData and slotData.Count > 0 then
				local itemConfig = Items[slotData.Id]
				ui.NameLabel.Text = if itemConfig then itemConfig.Name else slotData.Id
				ui.CountLabel.Text = `x{slotData.Count}`
			else
				ui.NameLabel.Text = ""
				ui.CountLabel.Text = ""
			end
		end
	end
end

local function createHotbarGui()
	local localPlayer = Players.LocalPlayer
	if not localPlayer then
		return
	end
	local playerGui = localPlayer:WaitForChild("PlayerGui") :: PlayerGui

	local existing = playerGui:FindFirstChild("HotbarGui")
	if existing then
		existing:Destroy()
	end

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "HotbarGui"
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = false
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	local container = Instance.new("Frame")
	container.Name = "Container"
	container.AnchorPoint = Vector2.new(0.5, 1)
	container.Position = UDim2.new(0.5, 0, 1, -16)
	container.Size = UDim2.fromOffset(Types.HOTBAR_SIZE * 72 + (Types.HOTBAR_SIZE - 1) * 8 + 16, 84)
	container.BackgroundColor3 = Color3.fromRGB(18, 18, 22)
	container.BackgroundTransparency = 0.25
	container.BorderSizePixel = 0
	container.Parent = screenGui

	local containerCorner = Instance.new("UICorner")
	containerCorner.CornerRadius = UDim.new(0, 10)
	containerCorner.Parent = container

	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, 8)
	padding.PaddingRight = UDim.new(0, 8)
	padding.PaddingTop = UDim.new(0, 6)
	padding.PaddingBottom = UDim.new(0, 6)
	padding.Parent = container

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Padding = UDim.new(0, 8)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = container

	for i = 1, Types.HOTBAR_SIZE do
		local slotFrame = Instance.new("Frame")
		slotFrame.Name = `Slot_{i}`
		slotFrame.LayoutOrder = i
		slotFrame.Size = UDim2.fromOffset(72, 72)
		slotFrame.BackgroundColor3 = COLOR_BG_DEFAULT
		slotFrame.BackgroundTransparency = 0.1
		slotFrame.BorderSizePixel = 0
		slotFrame.Parent = container

		local slotCorner = Instance.new("UICorner")
		slotCorner.CornerRadius = UDim.new(0, 8)
		slotCorner.Parent = slotFrame

		local stroke = Instance.new("UIStroke")
		stroke.Color = COLOR_STROKE_DEFAULT
		stroke.Thickness = 1.5
		stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		stroke.Parent = slotFrame

		local keyLabel = Instance.new("TextLabel")
		keyLabel.Name = "KeyLabel"
		keyLabel.Size = UDim2.fromOffset(20, 18)
		keyLabel.Position = UDim2.fromOffset(4, 2)
		keyLabel.BackgroundTransparency = 1
		keyLabel.Font = Enum.Font.GothamBold
		keyLabel.TextSize = 12
		keyLabel.TextColor3 = Color3.fromRGB(170, 170, 180)
		keyLabel.TextXAlignment = Enum.TextXAlignment.Left
		keyLabel.Text = tostring(i)
		keyLabel.Parent = slotFrame

		local nameLabel = Instance.new("TextLabel")
		nameLabel.Name = "NameLabel"
		nameLabel.AnchorPoint = Vector2.new(0.5, 0.5)
		nameLabel.Position = UDim2.fromScale(0.5, 0.48)
		nameLabel.Size = UDim2.new(1, -8, 0, 32)
		nameLabel.BackgroundTransparency = 1
		nameLabel.Font = Enum.Font.GothamMedium
		nameLabel.TextSize = 12
		nameLabel.TextColor3 = Color3.fromRGB(240, 240, 245)
		nameLabel.TextWrapped = true
		nameLabel.Text = ""
		nameLabel.Parent = slotFrame

		local countLabel = Instance.new("TextLabel")
		countLabel.Name = "CountLabel"
		countLabel.AnchorPoint = Vector2.new(1, 1)
		countLabel.Position = UDim2.new(1, -5, 1, -3)
		countLabel.Size = UDim2.new(1, -10, 0, 16)
		countLabel.BackgroundTransparency = 1
		countLabel.Font = Enum.Font.GothamBold
		countLabel.TextSize = 12
		countLabel.TextColor3 = Color3.fromRGB(230, 210, 130)
		countLabel.TextXAlignment = Enum.TextXAlignment.Right
		countLabel.Text = ""
		countLabel.Parent = slotFrame

		slotUIs[i] = {
			Frame = slotFrame,
			Stroke = stroke,
			KeyLabel = keyLabel,
			NameLabel = nameLabel,
			CountLabel = countLabel,
		}
	end

	screenGui.Parent = playerGui
end

function HotbarController.SelectSlot(slotIndex: number)
	if slotIndex < 1 or slotIndex > Types.HOTBAR_SIZE or slotIndex % 1 ~= 0 then
		return
	end
	selectedSlot = slotIndex
	updateSelectionVisuals()
	Net.GetEvent(Net.Events.HotbarSelect):FireServer(slotIndex)
end

function HotbarController.GetSelectedSlot(): number
	return selectedSlot
end

function HotbarController.Init()
	if isInitialized then
		return
	end
	isInitialized = true

	createHotbarGui()
	updateSelectionVisuals()
	Net.GetEvent(Net.Events.HotbarSelect):FireServer(selectedSlot)

	InventoryController.OnChanged(function(inv: Inventory)
		updateSlotsContent(inv)
	end)

	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessedEvent: boolean)
		if gameProcessedEvent then
			return
		end
		if UserInputService:GetFocusedTextBox() ~= nil then
			return
		end

		local slotIndex = KEYCODE_TO_SLOT[input.KeyCode]
		if slotIndex then
			HotbarController.SelectSlot(slotIndex)
		end
	end)
end

return HotbarController
