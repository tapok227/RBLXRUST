--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage.Shared.Types)
local Items = require(ReplicatedStorage.Shared.configs.Items)
local Net = require(ReplicatedStorage.Shared.Net)
local Signal = require(ReplicatedStorage.Shared.Signal)

type Inventory = Types.Inventory

type LootSlotUI = {
	Button: TextButton,
	SlotNumLabel: TextLabel,
	NameLabel: TextLabel,
	CountLabel: TextLabel,
}

local mainFrame: Frame? = nil
local titleLabel: TextLabel? = nil
local slotUIs: { [number]: LootSlotUI } = {}
local currentSlots: Inventory = {}
local activeContainerId: string? = nil
local isOpen = false
local isInitialized = false
local openChangedSignal: Signal.Signal<boolean> = Signal.new()

local LootController = {
	OpenChanged = openChangedSignal,
}

local function parseContainerSlots(payload: any): Inventory
	local slots: Inventory = {}
	if type(payload) ~= "table" then
		return slots
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
			slots[index] = {
				Id = v.Id,
				Count = v.Count,
			}
		end
	end
	return slots
end

local function refreshSlotsUI()
	for i = 1, Types.INVENTORY_SIZE do
		local ui = slotUIs[i]
		if ui then
			local slotData = currentSlots[i]
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
end

local function setClosedState(notifyServer: boolean)
	local prevId = activeContainerId
	local wasOpen = isOpen

	activeContainerId = nil
	table.clear(currentSlots)
	isOpen = false
	refreshSlotsUI()

	if mainFrame then
		mainFrame.Visible = false
	end

	if notifyServer and prevId ~= nil then
		Net.GetEvent(Net.Events.CloseContainer):FireServer(prevId)
	end

	if wasOpen then
		openChangedSignal:Fire(false)
	end
end

local function createSlotButton(parent: Instance, slotIndex: number)
	local btn = Instance.new("TextButton")
	btn.Name = string.format("Slot_%d", slotIndex)
	btn.LayoutOrder = slotIndex
	btn.BackgroundColor3 = Color3.fromRGB(34, 34, 40)
	btn.BorderSizePixel = 0
	btn.Text = ""
	btn.AutoButtonColor = true
	btn.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = btn

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(75, 75, 85)
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
		if activeContainerId == nil then
			return
		end
		local slotData = currentSlots[slotIndex]
		if slotData == nil or slotData.Count <= 0 then
			return
		end
		Net.GetEvent(Net.Events.LootTakeSlot):FireServer(activeContainerId, slotIndex)
	end)

	slotUIs[slotIndex] = {
		Button = btn,
		SlotNumLabel = numLabel,
		NameLabel = nameLabel,
		CountLabel = countLabel,
	}
end

local function createLootGui()
	local localPlayer = Players.LocalPlayer
	if not localPlayer then
		return
	end
	local playerGui = localPlayer:WaitForChild("PlayerGui") :: PlayerGui

	local existing = playerGui:FindFirstChild("LootGui")
	if existing then
		existing:Destroy()
	end

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "LootGui"
	screenGui.ResetOnSpawn = false
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.DisplayOrder = 15

	local frame = Instance.new("Frame")
	frame.Name = "MainFrame"
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.fromScale(0.5, 0.48)
	frame.Size = UDim2.fromOffset(480, 434)
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
	header.Name = "TitleLabel"
	header.Position = UDim2.fromOffset(16, 10)
	header.Size = UDim2.new(1, -60, 0, 28)
	header.BackgroundTransparency = 1
	header.Font = Enum.Font.GothamBold
	header.TextSize = 18
	header.TextColor3 = Color3.fromRGB(240, 240, 245)
	header.TextXAlignment = Enum.TextXAlignment.Left
	header.Text = "Loot Container"
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
		LootController.Close()
	end)

	local gridFrame = Instance.new("Frame")
	gridFrame.Name = "SlotsGrid"
	gridFrame.Position = UDim2.fromOffset(16, 46)
	gridFrame.Size = UDim2.fromOffset(448, 372)
	gridFrame.BackgroundTransparency = 1
	gridFrame.Parent = frame

	local gridLayout = Instance.new("UIGridLayout")
	gridLayout.CellSize = UDim2.fromOffset(68, 68)
	gridLayout.CellPadding = UDim2.fromOffset(8, 8)
	gridLayout.SortOrder = Enum.SortOrder.LayoutOrder
	gridLayout.Parent = gridFrame

	for i = 1, Types.INVENTORY_SIZE do
		createSlotButton(gridFrame, i)
	end

	mainFrame = frame
	titleLabel = header
	screenGui.Parent = playerGui
end

function LootController.IsOpen(): boolean
	return isOpen
end

function LootController.GetActiveContainerId(): string?
	return activeContainerId
end

function LootController.Close()
	setClosedState(true)
end

function LootController.Init()
	if isInitialized then
		return
	end
	isInitialized = true

	createLootGui()

	local openEvent = Net.GetEvent(Net.Events.OpenContainer)
	openEvent.OnClientEvent:Connect(function(containerId: any, title: any, slotsPayload: any)
		if typeof(containerId) ~= "string" or #containerId == 0 then
			return
		end

		local wasOpen = isOpen
		activeContainerId = containerId
		currentSlots = parseContainerSlots(slotsPayload)
		refreshSlotsUI()

		if titleLabel then
			titleLabel.Text = if typeof(title) == "string" and #title > 0 then title else "Loot Container"
		end

		isOpen = true
		if mainFrame then
			mainFrame.Visible = true
		end

		if not wasOpen then
			openChangedSignal:Fire(true)
		end
	end)

	local closeEvent = Net.GetEvent(Net.Events.CloseContainer)
	closeEvent.OnClientEvent:Connect(function(containerId: any)
		if containerId == nil or containerId == activeContainerId then
			setClosedState(false)
		end
	end)
end

return LootController
