--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")
local UserInputService = game:GetService("UserInputService")

local Types = require(ReplicatedStorage.Shared.Types)
local Signal = require(ReplicatedStorage.Shared.Signal)
local Items = require(ReplicatedStorage.Shared.configs.Items)
local Net = require(ReplicatedStorage.Shared.Net)
local InventoryController = require(script.Parent.InventoryController)
local LootController = require(script.Parent.LootController)

type Inventory = Types.Inventory

type SlotButtonUI = {
	Button: TextButton,
	Stroke: UIStroke,
	SlotNumLabel: TextLabel,
	NameLabel: TextLabel,
	CountLabel: TextLabel,
}

local COLOR_SLOT_DEFAULT = Color3.fromRGB(34, 34, 40)
local COLOR_SLOT_SELECTED = Color3.fromRGB(65, 58, 34)
local COLOR_STROKE_DEFAULT = Color3.fromRGB(75, 75, 85)
local COLOR_STROKE_SELECTED = Color3.fromRGB(245, 190, 65)

local mainFrame: Frame? = nil
local learnBlueprintBtn: TextButton? = nil
local slotUIs: { [number]: SlotButtonUI } = {}
local selectedSourceSlot: number? = nil
local slotInterceptors: { [string]: (slotIndex: number) -> boolean } = {}
local interceptorOrder: { string } = {}
local isOpen = false
local isInitialized = false
local openChangedSignal: Signal.Signal<boolean> = Signal.new()

local InventoryUIController = {
	OpenChanged = openChangedSignal,
}

local function updateLearnBlueprintButton()
	if not learnBlueprintBtn then
		return
	end
	local canLearn = false
	if selectedSourceSlot ~= nil then
		local slotData = InventoryController.GetSlot(selectedSourceSlot)
		if slotData ~= nil and slotData.Count > 0 then
			local cfg = Items[slotData.Id]
			if cfg ~= nil and cfg.Type == "Blueprint" then
				canLearn = true
			end
		end
	end
	learnBlueprintBtn.Visible = canLearn
end

local function updateSlotSelectionHighlight()
	for i = 1, Types.INVENTORY_SIZE do
		local ui = slotUIs[i]
		if ui then
			local isSelected = (selectedSourceSlot == i)
			ui.Button.BackgroundColor3 = if isSelected then COLOR_SLOT_SELECTED else COLOR_SLOT_DEFAULT
			ui.Stroke.Color = if isSelected then COLOR_STROKE_SELECTED else COLOR_STROKE_DEFAULT
			ui.Stroke.Thickness = if isSelected then 2.5 else 1.5
		end
	end
	updateLearnBlueprintButton()
end

local function refreshInventoryUI(inv: Inventory)
	for i = 1, Types.INVENTORY_SIZE do
		local ui = slotUIs[i]
		if ui then
			local slotData = inv[i]
			if slotData and slotData.Count > 0 then
				local itemConfig = Items[slotData.Id]
				ui.NameLabel.Text = if itemConfig then itemConfig.Name else slotData.Id
				ui.CountLabel.Text = string.format("x%d", slotData.Count)
			else
				ui.NameLabel.Text = ""
				ui.CountLabel.Text = ""
			end
		end
	end
	updateLearnBlueprintButton()
end

local function onSlotClicked(slotIndex: number)
	if LootController.CanDeposit() then
		selectedSourceSlot = nil
		updateSlotSelectionHighlight()
		if InventoryController.GetSlot(slotIndex) ~= nil then
			LootController.RequestDeposit(slotIndex)
		end
		return
	end

	for idx = #interceptorOrder, 1, -1 do
		local key = interceptorOrder[idx]
		local fn = slotInterceptors[key]
		if fn ~= nil and fn(slotIndex) then
			selectedSourceSlot = nil
			updateSlotSelectionHighlight()
			return
		end
	end

	if selectedSourceSlot == nil then
		if InventoryController.GetSlot(slotIndex) ~= nil then
			selectedSourceSlot = slotIndex
			updateSlotSelectionHighlight()
		end
	elseif selectedSourceSlot == slotIndex then
		selectedSourceSlot = nil
		updateSlotSelectionHighlight()
	else
		local source = selectedSourceSlot
		selectedSourceSlot = nil
		updateSlotSelectionHighlight()
		InventoryController.RequestMove(source, slotIndex)
	end
end

local function createSlotButton(parent: Instance, slotIndex: number, layoutOrder: number)
	local btn = Instance.new("TextButton")
	btn.Name = string.format("Slot_%d", slotIndex)
	btn.LayoutOrder = layoutOrder
	btn.BackgroundColor3 = COLOR_SLOT_DEFAULT
	btn.BorderSizePixel = 0
	btn.Text = ""
	btn.AutoButtonColor = true
	btn.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = btn

	local stroke = Instance.new("UIStroke")
	stroke.Color = COLOR_STROKE_DEFAULT
	stroke.Thickness = 1.5
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = btn

	local numLabel = Instance.new("TextLabel")
	numLabel.Name = "SlotNumLabel"
	numLabel.Size = UDim2.fromOffset(22, 16)
	numLabel.Position = UDim2.fromOffset(4, 2)
	numLabel.BackgroundTransparency = 1
	numLabel.Font = Enum.Font.GothamBold
	numLabel.TextSize = 11
	numLabel.TextColor3 = Color3.fromRGB(150, 150, 165)
	numLabel.TextXAlignment = Enum.TextXAlignment.Left
	numLabel.Text = tostring(slotIndex)
	numLabel.Parent = btn

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
	nameLabel.Parent = btn

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
	countLabel.Parent = btn

	btn.Activated:Connect(function()
		onSlotClicked(slotIndex)
	end)

	slotUIs[slotIndex] = {
		Button = btn,
		Stroke = stroke,
		SlotNumLabel = numLabel,
		NameLabel = nameLabel,
		CountLabel = countLabel,
	}
end

local function createInventoryGui()
	local localPlayer = Players.LocalPlayer
	if not localPlayer then
		return
	end
	local playerGui = localPlayer:WaitForChild("PlayerGui") :: PlayerGui

	local existing = playerGui:FindFirstChild("InventoryGui")
	if existing then
		existing:Destroy()
	end

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "InventoryGui"
	screenGui.ResetOnSpawn = false
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.DisplayOrder = 10

	local frame = Instance.new("Frame")
	frame.Name = "MainFrame"
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.new(0.5, -166, 0.48, 0)
	frame.Size = UDim2.fromOffset(480, 486)
	frame.BackgroundColor3 = Color3.fromRGB(20, 20, 25)
	frame.BackgroundTransparency = 0.08
	frame.BorderSizePixel = 0
	frame.Visible = false
	frame.Parent = screenGui

	local frameCorner = Instance.new("UICorner")
	frameCorner.CornerRadius = UDim.new(0, 12)
	frameCorner.Parent = frame

	local frameStroke = Instance.new("UIStroke")
	frameStroke.Color = Color3.fromRGB(85, 85, 95)
	frameStroke.Thickness = 1.5
	frameStroke.Parent = frame

	local header = Instance.new("TextLabel")
	header.Name = "Header"
	header.Position = UDim2.fromOffset(16, 10)
	header.Size = UDim2.new(1, -60, 0, 28)
	header.BackgroundTransparency = 1
	header.Font = Enum.Font.GothamBold
	header.TextSize = 18
	header.TextColor3 = Color3.fromRGB(240, 240, 245)
	header.TextXAlignment = Enum.TextXAlignment.Left
	header.Text = "Inventory [Tab / I]"
	header.Parent = frame

	local closeBtn = Instance.new("TextButton")
	closeBtn.Name = "CloseButton"
	closeBtn.AnchorPoint = Vector2.new(1, 0)
	closeBtn.Position = UDim2.new(1, -12, 0, 10)
	closeBtn.Size = UDim2.fromOffset(28, 28)
	closeBtn.BackgroundColor3 = Color3.fromRGB(160, 55, 55)
	closeBtn.Font = Enum.Font.GothamBold
	closeBtn.TextSize = 14
	closeBtn.TextColor3 = Color3.new(1, 1, 1)
	closeBtn.Text = "X"
	closeBtn.Parent = frame

	local closeCorner = Instance.new("UICorner")
	closeCorner.CornerRadius = UDim.new(0, 6)
	closeCorner.Parent = closeBtn

	closeBtn.Activated:Connect(function()
		InventoryUIController.SetOpen(false)
	end)

	local learnBtn = Instance.new("TextButton")
	learnBtn.Name = "LearnBlueprintButton"
	learnBtn.AnchorPoint = Vector2.new(1, 0)
	learnBtn.Position = UDim2.new(1, -48, 0, 10)
	learnBtn.Size = UDim2.fromOffset(132, 28)
	learnBtn.BackgroundColor3 = Color3.fromRGB(48, 128, 210)
	learnBtn.Font = Enum.Font.GothamBold
	learnBtn.TextSize = 12
	learnBtn.TextColor3 = Color3.new(1, 1, 1)
	learnBtn.Text = "Use / Learn BP"
	learnBtn.Visible = false
	learnBtn.Parent = frame

	local learnCorner = Instance.new("UICorner")
	learnCorner.CornerRadius = UDim.new(0, 6)
	learnCorner.Parent = learnBtn

	learnBtn.Activated:Connect(function()
		if selectedSourceSlot ~= nil then
			local slot = selectedSourceSlot
			selectedSourceSlot = nil
			updateSlotSelectionHighlight()
			Net.GetEvent(Net.Events.LearnBlueprintRequest):FireServer(slot)
		end
	end)
	learnBlueprintBtn = learnBtn

	local backpackLabel = Instance.new("TextLabel")
	backpackLabel.Name = "BackpackLabel"
	backpackLabel.Position = UDim2.fromOffset(16, 44)
	backpackLabel.Size = UDim2.new(1, -32, 0, 18)
	backpackLabel.BackgroundTransparency = 1
	backpackLabel.Font = Enum.Font.GothamBold
	backpackLabel.TextSize = 13
	backpackLabel.TextColor3 = Color3.fromRGB(180, 180, 195)
	backpackLabel.TextXAlignment = Enum.TextXAlignment.Left
	backpackLabel.Text = "Backpack (7-30)"
	backpackLabel.Parent = frame

	local backpackGrid = Instance.new("Frame")
	backpackGrid.Name = "BackpackGrid"
	backpackGrid.Position = UDim2.fromOffset(16, 66)
	backpackGrid.Size = UDim2.fromOffset(448, 300)
	backpackGrid.BackgroundTransparency = 1
	backpackGrid.Parent = frame

	local backpackLayout = Instance.new("UIGridLayout")
	backpackLayout.CellSize = UDim2.fromOffset(68, 68)
	backpackLayout.CellPadding = UDim2.fromOffset(8, 8)
	backpackLayout.SortOrder = Enum.SortOrder.LayoutOrder
	backpackLayout.Parent = backpackGrid

	for i = Types.HOTBAR_SIZE + 1, Types.INVENTORY_SIZE do
		createSlotButton(backpackGrid, i, i - Types.HOTBAR_SIZE)
	end

	local hotbarLabel = Instance.new("TextLabel")
	hotbarLabel.Name = "HotbarLabel"
	hotbarLabel.Position = UDim2.fromOffset(16, 374)
	hotbarLabel.Size = UDim2.new(1, -32, 0, 18)
	hotbarLabel.BackgroundTransparency = 1
	hotbarLabel.Font = Enum.Font.GothamBold
	hotbarLabel.TextSize = 13
	hotbarLabel.TextColor3 = Color3.fromRGB(230, 200, 120)
	hotbarLabel.TextXAlignment = Enum.TextXAlignment.Left
	hotbarLabel.Text = "Hotbar (1-6)"
	hotbarLabel.Parent = frame

	local hotbarGrid = Instance.new("Frame")
	hotbarGrid.Name = "HotbarGrid"
	hotbarGrid.Position = UDim2.fromOffset(16, 396)
	hotbarGrid.Size = UDim2.fromOffset(448, 72)
	hotbarGrid.BackgroundTransparency = 1
	hotbarGrid.Parent = frame

	local hotbarLayout = Instance.new("UIGridLayout")
	hotbarLayout.CellSize = UDim2.fromOffset(68, 68)
	hotbarLayout.CellPadding = UDim2.fromOffset(8, 8)
	hotbarLayout.SortOrder = Enum.SortOrder.LayoutOrder
	hotbarLayout.Parent = hotbarGrid

	for i = 1, Types.HOTBAR_SIZE do
		createSlotButton(hotbarGrid, i, i)
	end

	mainFrame = frame
	screenGui.Parent = playerGui
end

function InventoryUIController.RegisterSlotInterceptor(id: string, fn: (slotIndex: number) -> boolean)
	if slotInterceptors[id] == nil then
		table.insert(interceptorOrder, id)
	end
	slotInterceptors[id] = fn
end

function InventoryUIController.UnregisterSlotInterceptor(id: string)
	slotInterceptors[id] = nil
	local idx = table.find(interceptorOrder, id)
	if idx ~= nil then
		table.remove(interceptorOrder, idx)
	end
end

function InventoryUIController.HasActiveInterceptor(): boolean
	return #interceptorOrder > 0
end

function InventoryUIController.IsOpen(): boolean
	return isOpen
end

function InventoryUIController.SetOpen(open: boolean)
	isOpen = open
	if not open then
		selectedSourceSlot = nil
		updateSlotSelectionHighlight()
	end
	if mainFrame then
		mainFrame.Visible = open
	end
	openChangedSignal:Fire(open)
end

function InventoryUIController.Toggle()
	InventoryUIController.SetOpen(not isOpen)
end

function InventoryUIController.Init()
	if isInitialized then
		return
	end
	isInitialized = true

	pcall(StarterGui.SetCoreGuiEnabled, StarterGui, Enum.CoreGuiType.PlayerList, false)

	createInventoryGui()

	InventoryController.OnChanged(function(inv: Inventory)
		refreshInventoryUI(inv)
	end)

	LootController.OpenChanged:Connect(function(open: boolean)
		if open and LootController.CanDeposit() then
			InventoryUIController.SetOpen(true)
		end
	end)

	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessedEvent: boolean)
		if UserInputService:GetFocusedTextBox() ~= nil then
			return
		end

		if input.KeyCode == Enum.KeyCode.Tab or (input.KeyCode == Enum.KeyCode.I and not gameProcessedEvent) then
			InventoryUIController.Toggle()
		end
	end)
end

return InventoryUIController
