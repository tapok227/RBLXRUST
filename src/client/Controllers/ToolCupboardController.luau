--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Config = require(ReplicatedStorage.Shared.Config)
local Types = require(ReplicatedStorage.Shared.Types)
local Items = require(ReplicatedStorage.Shared.configs.Items)
local Net = require(ReplicatedStorage.Shared.Net)
local InventoryController = require(script.Parent.InventoryController)

type Inventory = Types.Inventory
type ToolCupboardState = Types.ToolCupboardState

type TcSlotUI = {
	Index: number,
	Button: TextButton,
	NameLabel: TextLabel,
	CountLabel: TextLabel,
}

type DepositButtonUI = {
	ResourceId: string,
	Button: TextButton,
}

local COLOR_BG = Color3.fromRGB(20, 22, 28)
local COLOR_SLOT = Color3.fromRGB(34, 38, 46)
local COLOR_STROKE = Color3.fromRGB(78, 84, 98)
local COLOR_OK = Color3.fromRGB(95, 225, 130)
local COLOR_WARN = Color3.fromRGB(240, 185, 80)
local COLOR_BAD = Color3.fromRGB(235, 85, 85)

local mainFrame: Frame? = nil
local tierBadgeLabel: TextLabel? = nil
local statusBadgeLabel: TextLabel? = nil
local pathBadgeLabel: TextLabel? = nil
local upkeepLabel: TextLabel? = nil
local slotUIs: { TcSlotUI } = {}
local depositButtons: { DepositButtonUI } = {}
local currentState: ToolCupboardState? = nil
local isOpen = false
local isInitialized = false

local ToolCupboardController = {}

local function formatProtectedTime(hours: number): string
	if hours <= 0 then
		return "0m"
	end
	local totalMinutes = math.floor(hours * 60 + 0.5)
	local h = math.floor(totalMinutes / 60)
	local m = totalMinutes % 60
	if h > 0 then
		return string.format("%dh %dm", h, m)
	end
	return string.format("%dm", m)
end

local function countInventoryResource(resourceId: string): (number, number?)
	local inv = InventoryController.GetInventory()
	local total = 0
	local firstSlot: number? = nil
	for i = 1, Types.INVENTORY_SIZE do
		local slot = inv[i]
		if slot ~= nil and slot.Id == resourceId and slot.Count > 0 then
			total += slot.Count
			if firstSlot == nil then
				firstSlot = i
			end
		end
	end
	return total, firstSlot
end

local function parseTcSlots(rawSlots: any): Inventory
	local slots: Inventory = {}
	if type(rawSlots) ~= "table" then
		return slots
	end
	local maxSlots = Config.Upkeep.TcStorageSlots
	for k, v in rawSlots do
		local index = if type(k) == "number" then k else tonumber(k)
		if
			index ~= nil
			and index >= 1
			and index <= maxSlots
			and index % 1 == 0
			and type(v) == "table"
			and type(v.Id) == "string"
			and type(v.Count) == "number"
			and v.Count > 0
		then
			slots[index] = {
				Id = v.Id,
				Count = math.floor(v.Count),
			}
		end
	end
	return slots
end

local function refreshUi()
	if not mainFrame then
		return
	end
	mainFrame.Visible = isOpen and currentState ~= nil
	if not isOpen or currentState == nil then
		return
	end

	local state = currentState :: ToolCupboardState
	if tierBadgeLabel then
		tierBadgeLabel.Text = string.format("Base Tier: Tier %d", state.BaseTier)
		tierBadgeLabel.TextColor3 = if state.BaseTier >= 3
			then Color3.fromRGB(110, 220, 255)
			elseif state.BaseTier == 2 then COLOR_WARN
			elseif state.BaseTier == 1 then COLOR_OK
			else COLOR_BAD
	end

	if statusBadgeLabel then
		if state.Status == "Protected" then
			statusBadgeLabel.Text = string.format("Protected (%s)", formatProtectedTime(state.ProtectedHours))
			statusBadgeLabel.TextColor3 = COLOR_OK
		else
			statusBadgeLabel.Text = "Decaying!"
			statusBadgeLabel.TextColor3 = COLOR_BAD
		end
	end

	if pathBadgeLabel then
		if state.PathValid then
			pathBadgeLabel.Text = "Path to TC: Valid"
			pathBadgeLabel.TextColor3 = COLOR_OK
		else
			pathBadgeLabel.Text = "Path to TC: Blocked"
			pathBadgeLabel.TextColor3 = COLOR_BAD
		end
	end

	if upkeepLabel then
		local parts: { string } = {}
		for _, resId in Config.Upkeep.AllowedResourceIds do
			local rate = state.HourlyUpkeep[resId] or 0
			local itemCfg = Items[resId]
			local name = if itemCfg then itemCfg.Name else resId
			table.insert(parts, string.format("%s: %d/h", name, rate))
		end
		upkeepLabel.Text = string.format("Upkeep: %s", table.concat(parts, " | "))
	end

	for _, ui in slotUIs do
		local slot = state.Slots[ui.Index]
		if slot ~= nil and slot.Count > 0 then
			local itemCfg = Items[slot.Id]
			ui.NameLabel.Text = if itemCfg then itemCfg.Name else slot.Id
			ui.CountLabel.Text = string.format("x%d", slot.Count)
		else
			ui.NameLabel.Text = ""
			ui.CountLabel.Text = ""
		end
	end

	for _, dep in depositButtons do
		local total, _ = countInventoryResource(dep.ResourceId)
		local itemCfg = Items[dep.ResourceId]
		local label = if itemCfg then itemCfg.Name else dep.ResourceId
		dep.Button.Text = string.format("+ %s (%d)", label, total)
		dep.Button.BackgroundColor3 = if total > 0 then Color3.fromRGB(48, 88, 60) else Color3.fromRGB(40, 42, 48)
		dep.Button.TextColor3 = if total > 0 then Color3.new(1, 1, 1) else Color3.fromRGB(150, 155, 165)
	end
end

local function createGui()
	local localPlayer = Players.LocalPlayer
	if not localPlayer then
		return
	end
	local playerGui = localPlayer:WaitForChild("PlayerGui") :: PlayerGui

	local existing = playerGui:FindFirstChild("ToolCupboardGui")
	if existing then
		existing:Destroy()
	end

	local gui = Instance.new("ScreenGui")
	gui.Name = "ToolCupboardGui"
	gui.ResetOnSpawn = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.DisplayOrder = 22

	local frame = Instance.new("Frame")
	frame.Name = "ToolCupboardPanel"
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.fromScale(0.5, 0.48)
	frame.Size = UDim2.fromOffset(540, 444)
	frame.BackgroundColor3 = COLOR_BG
	frame.BackgroundTransparency = 0.08
	frame.BorderSizePixel = 0
	frame.Visible = false
	frame.Parent = gui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = frame

	local stroke = Instance.new("UIStroke")
	stroke.Color = COLOR_STROKE
	stroke.Thickness = 1.6
	stroke.Parent = frame

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.Position = UDim2.fromOffset(16, 10)
	title.Size = UDim2.new(1, -64, 0, 24)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBold
	title.TextSize = 17
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextColor3 = Color3.fromRGB(240, 242, 248)
	title.Text = "TOOL CUPBOARD (UPKEEP)"
	title.Parent = frame

	local closeBtn = Instance.new("TextButton")
	closeBtn.Name = "CloseButton"
	closeBtn.AnchorPoint = Vector2.new(1, 0)
	closeBtn.Position = UDim2.new(1, -12, 0, 10)
	closeBtn.Size = UDim2.fromOffset(28, 26)
	closeBtn.BackgroundColor3 = Color3.fromRGB(165, 55, 55)
	closeBtn.BorderSizePixel = 0
	closeBtn.Font = Enum.Font.GothamBold
	closeBtn.TextSize = 14
	closeBtn.TextColor3 = Color3.new(1, 1, 1)
	closeBtn.Text = "X"
	closeBtn.Parent = frame
	local closeCorner = Instance.new("UICorner")
	closeCorner.CornerRadius = UDim.new(0, 6)
	closeCorner.Parent = closeBtn
	closeBtn.Activated:Connect(function()
		ToolCupboardController.Close()
	end)

	local badgesRow = Instance.new("Frame")
	badgesRow.Name = "BadgesRow"
	badgesRow.Position = UDim2.fromOffset(16, 42)
	badgesRow.Size = UDim2.new(1, -32, 0, 26)
	badgesRow.BackgroundTransparency = 1
	badgesRow.Parent = frame

	local function makeBadge(name: string, posX: number, wScale: number): TextLabel
		local lbl = Instance.new("TextLabel")
		lbl.Name = name
		lbl.Position = UDim2.fromScale(posX, 0)
		lbl.Size = UDim2.new(wScale, -4, 1, 0)
		lbl.BackgroundColor3 = Color3.fromRGB(30, 34, 42)
		lbl.BorderSizePixel = 0
		lbl.Font = Enum.Font.GothamBold
		lbl.TextSize = 12
		lbl.TextColor3 = Color3.new(1, 1, 1)
		lbl.Text = ""
		lbl.Parent = badgesRow
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0, 6)
		c.Parent = lbl
		return lbl
	end

	tierBadgeLabel = makeBadge("TierBadge", 0, 0.30)
	statusBadgeLabel = makeBadge("StatusBadge", 0.31, 0.36)
	pathBadgeLabel = makeBadge("PathBadge", 0.68, 0.32)

	local upkeepLbl = Instance.new("TextLabel")
	upkeepLbl.Name = "UpkeepSummary"
	upkeepLbl.Position = UDim2.fromOffset(16, 74)
	upkeepLbl.Size = UDim2.new(1, -32, 0, 22)
	upkeepLbl.BackgroundTransparency = 1
	upkeepLbl.Font = Enum.Font.GothamMedium
	upkeepLbl.TextSize = 12
	upkeepLbl.TextXAlignment = Enum.TextXAlignment.Left
	upkeepLbl.TextTruncate = Enum.TextTruncate.AtEnd
	upkeepLbl.TextColor3 = Color3.fromRGB(205, 212, 224)
	upkeepLbl.Text = "Upkeep: -"
	upkeepLbl.Parent = frame
	upkeepLabel = upkeepLbl

	local gridFrame = Instance.new("Frame")
	gridFrame.Name = "SlotsGrid"
	gridFrame.Position = UDim2.fromOffset(16, 104)
	gridFrame.Size = UDim2.fromOffset(508, 228)
	gridFrame.BackgroundTransparency = 1
	gridFrame.Parent = frame

	local grid = Instance.new("UIGridLayout")
	grid.CellSize = UDim2.fromOffset(121, 68)
	grid.CellPadding = UDim2.fromOffset(8, 8)
	grid.SortOrder = Enum.SortOrder.LayoutOrder
	grid.Parent = gridFrame

	table.clear(slotUIs)
	for i = 1, Config.Upkeep.TcStorageSlots do
		local btn = Instance.new("TextButton")
		btn.Name = string.format("TcSlot_%d", i)
		btn.LayoutOrder = i
		btn.BackgroundColor3 = COLOR_SLOT
		btn.BorderSizePixel = 0
		btn.Text = ""
		btn.Parent = gridFrame
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0, 7)
		c.Parent = btn
		local s = Instance.new("UIStroke")
		s.Color = Color3.fromRGB(64, 70, 84)
		s.Thickness = 1
		s.Parent = btn

		local nLbl = Instance.new("TextLabel")
		nLbl.Name = "ItemName"
		nLbl.Position = UDim2.fromOffset(6, 8)
		nLbl.Size = UDim2.new(1, -12, 0, 30)
		nLbl.BackgroundTransparency = 1
		nLbl.Font = Enum.Font.GothamBold
		nLbl.TextSize = 11
		nLbl.TextWrapped = true
		nLbl.TextColor3 = Color3.fromRGB(236, 240, 245)
		nLbl.Text = ""
		nLbl.Parent = btn

		local cLbl = Instance.new("TextLabel")
		cLbl.Name = "ItemCount"
		cLbl.AnchorPoint = Vector2.new(1, 1)
		cLbl.Position = UDim2.new(1, -6, 1, -4)
		cLbl.Size = UDim2.new(1, -12, 0, 18)
		cLbl.BackgroundTransparency = 1
		cLbl.Font = Enum.Font.GothamBold
		cLbl.TextSize = 12
		cLbl.TextXAlignment = Enum.TextXAlignment.Right
		cLbl.TextColor3 = Color3.fromRGB(160, 230, 165)
		cLbl.Text = ""
		cLbl.Parent = btn

		btn.Activated:Connect(function()
			if currentState ~= nil and currentState.Slots[i] ~= nil then
				Net.GetEvent(Net.Events.ToolCupboardAction):FireServer("Withdraw", i)
			end
		end)

		table.insert(slotUIs, {
			Index = i,
			Button = btn,
			NameLabel = nLbl,
			CountLabel = cLbl,
		})
	end

	local depositTitle = Instance.new("TextLabel")
	depositTitle.Name = "DepositHeader"
	depositTitle.Position = UDim2.fromOffset(16, 342)
	depositTitle.Size = UDim2.new(1, -32, 0, 18)
	depositTitle.BackgroundTransparency = 1
	depositTitle.Font = Enum.Font.GothamMedium
	depositTitle.TextSize = 12
	depositTitle.TextXAlignment = Enum.TextXAlignment.Left
	depositTitle.TextColor3 = Color3.fromRGB(185, 195, 210)
	depositTitle.Text = "Quick Deposit from Inventory (click slot above to withdraw):"
	depositTitle.Parent = frame

	local depRow = Instance.new("Frame")
	depRow.Name = "DepositRow"
	depRow.Position = UDim2.fromOffset(16, 366)
	depRow.Size = UDim2.new(1, -32, 0, 62)
	depRow.BackgroundTransparency = 1
	depRow.Parent = frame

	local depGrid = Instance.new("UIGridLayout")
	depGrid.CellSize = UDim2.fromOffset(121, 56)
	depGrid.CellPadding = UDim2.fromOffset(8, 0)
	depGrid.SortOrder = Enum.SortOrder.LayoutOrder
	depGrid.Parent = depRow

	table.clear(depositButtons)
	for idx, resId in Config.Upkeep.AllowedResourceIds do
		local dBtn = Instance.new("TextButton")
		dBtn.Name = string.format("Deposit_%s", resId)
		dBtn.LayoutOrder = idx
		dBtn.BackgroundColor3 = Color3.fromRGB(48, 88, 60)
		dBtn.BorderSizePixel = 0
		dBtn.Font = Enum.Font.GothamBold
		dBtn.TextSize = 11
		dBtn.TextWrapped = true
		dBtn.TextColor3 = Color3.new(1, 1, 1)
		dBtn.Text = resId
		dBtn.Parent = depRow
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0, 7)
		c.Parent = dBtn

		dBtn.Activated:Connect(function()
			local total, slotIdx = countInventoryResource(resId)
			if total > 0 and slotIdx ~= nil then
				Net.GetEvent(Net.Events.ToolCupboardAction):FireServer("Deposit", slotIdx)
			end
		end)

		table.insert(depositButtons, {
			ResourceId = resId,
			Button = dBtn,
		})
	end

	gui.Parent = playerGui
	mainFrame = frame
end

local function onToolCupboardSync(payloadAny: any)
	if payloadAny == nil then
		currentState = nil
		isOpen = false
		refreshUi()
		return
	end
	if type(payloadAny) ~= "table" or type(payloadAny.Uid) ~= "string" then
		return
	end

	local hourlyUpkeep: { [string]: number } = {}
	if type(payloadAny.HourlyUpkeep) == "table" then
		for k, v in payloadAny.HourlyUpkeep do
			if type(k) == "string" and type(v) == "number" then
				hourlyUpkeep[k] = v
			end
		end
	end

	currentState = {
		Uid = payloadAny.Uid,
		ContainerId = if type(payloadAny.ContainerId) == "string" then payloadAny.ContainerId else payloadAny.Uid,
		BaseTier = if type(payloadAny.BaseTier) == "number" then payloadAny.BaseTier else 0,
		Status = if payloadAny.Status == "Protected" then "Protected" else "Decaying",
		HourlyUpkeep = hourlyUpkeep,
		ProtectedHours = if type(payloadAny.ProtectedHours) == "number" then payloadAny.ProtectedHours else 0,
		PathValid = payloadAny.PathValid == true,
		PathMessage = if type(payloadAny.PathMessage) == "string" then payloadAny.PathMessage else nil,
		Slots = parseTcSlots(payloadAny.Slots),
	}
	isOpen = true
	refreshUi()
end

function ToolCupboardController.IsOpen(): boolean
	return isOpen
end

function ToolCupboardController.Close()
	if not isOpen then
		return
	end
	isOpen = false
	refreshUi()
	Net.GetEvent(Net.Events.ToolCupboardAction):FireServer("Close")
end

function ToolCupboardController.GetState(): ToolCupboardState?
	return currentState
end

function ToolCupboardController.Init()
	if isInitialized then
		return
	end
	isInitialized = true

	createGui()
	Net.GetEvent(Net.Events.ToolCupboardSync).OnClientEvent:Connect(onToolCupboardSync)
	InventoryController.OnChanged(function()
		if isOpen then
			refreshUi()
		end
	end)

	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessedEvent: boolean)
		if gameProcessedEvent then
			return
		end
		if input.KeyCode == Enum.KeyCode.Escape and isOpen then
			ToolCupboardController.Close()
		end
	end)
end

return ToolCupboardController
