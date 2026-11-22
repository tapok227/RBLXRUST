--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Config = require(ReplicatedStorage.Shared.Config)
local Types = require(ReplicatedStorage.Shared.Types)
local Items = require(ReplicatedStorage.Shared.configs.Items)
local Recycling = require(ReplicatedStorage.Shared.configs.Recycling)
local Net = require(ReplicatedStorage.Shared.Net)
local BlueprintController = require(script.Parent.BlueprintController)
local InventoryController = require(script.Parent.InventoryController)
local InventoryUIController = require(script.Parent.InventoryUIController)
local LootController = require(script.Parent.LootController)

type Inventory = Types.Inventory
type RecyclerState = Types.RecyclerState

type SlotBtnUI = {
	Button: TextButton,
	NameLabel: TextLabel,
	CountLabel: TextLabel,
}

local INTERCEPTOR_ID = "Recycler"
local SLOT_DEFAULT_BG = Color3.fromRGB(34, 36, 44)
local SLOT_OUTPUT_BG = Color3.fromRGB(28, 40, 38)
local BTN_ON_BG = Color3.fromRGB(175, 58, 52)
local BTN_OFF_BG = Color3.fromRGB(48, 152, 86)

local activeState: RecyclerState? = nil
local isOpen = false
local isInitialized = false

local mainFrame: Frame? = nil
local titleLabel: TextLabel? = nil
local yieldBadgeLabel: TextLabel? = nil
local toggleButton: TextButton? = nil
local progressFill: Frame? = nil
local statusLabel: TextLabel? = nil
local inputSlotUIs: { [number]: SlotBtnUI } = {}
local outputSlotUIs: { [number]: SlotBtnUI } = {}

local RecyclerController = {}

local function parseSlotMap(payload: any, maxSlots: number): Inventory
	local out: Inventory = {}
	if type(payload) ~= "table" then
		return out
	end
	for k, v in payload do
		local idx = if type(k) == "number" then k else tonumber(k)
		if
			idx ~= nil
			and idx >= 1
			and idx <= maxSlots
			and idx % 1 == 0
			and type(v) == "table"
			and type(v.Id) == "string"
			and type(v.Count) == "number"
			and v.Count > 0
		then
			out[idx] = {
				Id = v.Id,
				Count = v.Count,
			}
		end
	end
	return out
end

local function parseRecyclerState(payload: any): RecyclerState?
	if type(payload) ~= "table" or type(payload.RecyclerId) ~= "string" then
		return nil
	end
	return {
		RecyclerId = payload.RecyclerId,
		Name = if type(payload.Name) == "string" then payload.Name else "Recycler",
		EfficiencyMultiplier = if type(payload.EfficiencyMultiplier) == "number"
			then payload.EfficiencyMultiplier
			else 1.0,
		IsRunning = payload.IsRunning == true,
		InputSlots = parseSlotMap(payload.InputSlots, Config.Recycler.InputSlots),
		OutputSlots = parseSlotMap(payload.OutputSlots, Config.Recycler.OutputSlots),
		Progress = if type(payload.Progress) == "number" then math.clamp(payload.Progress, 0, 1) else 0,
		Position = if typeof(payload.Position) == "Vector3" then payload.Position else Vector3.zero,
	}
end

local function refreshSlotGrid(uis: { [number]: SlotBtnUI }, slots: Inventory, count: number)
	for i = 1, count do
		local ui = uis[i]
		if ui ~= nil then
			local slot = slots[i]
			if slot ~= nil and slot.Count > 0 then
				local cfg = Items[slot.Id]
				ui.NameLabel.Text = if cfg then cfg.Name else slot.Id
				ui.CountLabel.Text = string.format("x%d", slot.Count)
			else
				ui.NameLabel.Text = ""
				ui.CountLabel.Text = ""
			end
		end
	end
end

local function refreshRecyclerUi()
	if not activeState then
		return
	end
	if titleLabel then
		titleLabel.Text = "Recycler"
	end
	if yieldBadgeLabel then
		local yieldPct = math.floor(activeState.EfficiencyMultiplier * 50 + 0.5)
		local isRt = activeState.EfficiencyMultiplier >= 1.0
		yieldBadgeLabel.Text = if isRt
			then string.format("RT %d%% Yield", yieldPct)
			else string.format("Safe %d%% Yield", yieldPct)
		yieldBadgeLabel.TextColor3 = if isRt then Color3.fromRGB(255, 200, 85) else Color3.fromRGB(115, 195, 255)
	end
	if toggleButton then
		toggleButton.Text = if activeState.IsRunning then "Turn Off" else "Turn On"
		toggleButton.BackgroundColor3 = if activeState.IsRunning then BTN_ON_BG else BTN_OFF_BG
	end
	if progressFill then
		progressFill.Size = UDim2.fromScale(activeState.Progress, 1)
	end
	if statusLabel then
		statusLabel.Text = if activeState.IsRunning
			then string.format("Recycling... (%d%%)", math.floor(activeState.Progress * 100 + 0.5))
			else "Idle — click recyclable items in Inventory to deposit"
	end
	refreshSlotGrid(inputSlotUIs, activeState.InputSlots, Config.Recycler.InputSlots)
	refreshSlotGrid(outputSlotUIs, activeState.OutputSlots, Config.Recycler.OutputSlots)
end

local function createGridSlot(
	parent: Instance,
	index: number,
	bgColor: Color3,
	onClick: (slotIdx: number) -> ()
): SlotBtnUI
	local btn = Instance.new("TextButton")
	btn.Name = string.format("Slot_%d", index)
	btn.LayoutOrder = index
	btn.BackgroundColor3 = bgColor
	btn.BorderSizePixel = 0
	btn.Text = ""
	btn.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = btn

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(72, 76, 90)
	stroke.Thickness = 1.2
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = btn

	local nameLbl = Instance.new("TextLabel")
	nameLbl.Position = UDim2.fromOffset(3, 4)
	nameLbl.Size = UDim2.new(1, -6, 0, 30)
	nameLbl.BackgroundTransparency = 1
	nameLbl.Font = Enum.Font.GothamMedium
	nameLbl.TextSize = 10
	nameLbl.TextWrapped = true
	nameLbl.TextColor3 = Color3.fromRGB(236, 238, 245)
	nameLbl.Text = ""
	nameLbl.Parent = btn

	local countLbl = Instance.new("TextLabel")
	countLbl.AnchorPoint = Vector2.new(1, 1)
	countLbl.Position = UDim2.new(1, -4, 1, -2)
	countLbl.Size = UDim2.new(1, -8, 0, 14)
	countLbl.BackgroundTransparency = 1
	countLbl.Font = Enum.Font.GothamBold
	countLbl.TextSize = 11
	countLbl.TextColor3 = Color3.fromRGB(235, 210, 120)
	countLbl.TextXAlignment = Enum.TextXAlignment.Right
	countLbl.Text = ""
	countLbl.Parent = btn

	btn.Activated:Connect(function()
		onClick(index)
	end)

	return {
		Button = btn,
		NameLabel = nameLbl,
		CountLabel = countLbl,
	}
end

local function createRecyclerGui()
	local localPlayer = Players.LocalPlayer
	if not localPlayer then
		return
	end
	local playerGui = localPlayer:WaitForChild("PlayerGui") :: PlayerGui

	local existing = playerGui:FindFirstChild("RecyclerGui")
	if existing then
		existing:Destroy()
	end

	table.clear(inputSlotUIs)
	table.clear(outputSlotUIs)

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "RecyclerGui"
	screenGui.ResetOnSpawn = false
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.DisplayOrder = 11

	local frame = Instance.new("Frame")
	frame.Name = "MainFrame"
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.new(0.5, 270, 0.48, 0)
	frame.Size = UDim2.fromOffset(386, 360)
	frame.BackgroundColor3 = Color3.fromRGB(20, 22, 26)
	frame.BackgroundTransparency = 0.06
	frame.BorderSizePixel = 0
	frame.Visible = false
	frame.Parent = screenGui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 12)
	corner.Parent = frame

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(210, 145, 55)
	stroke.Thickness = 1.5
	stroke.Parent = frame

	local hLabel = Instance.new("TextLabel")
	hLabel.Position = UDim2.fromOffset(14, 10)
	hLabel.Size = UDim2.fromOffset(110, 26)
	hLabel.BackgroundTransparency = 1
	hLabel.Font = Enum.Font.GothamBold
	hLabel.TextSize = 18
	hLabel.TextColor3 = Color3.fromRGB(245, 245, 250)
	hLabel.TextXAlignment = Enum.TextXAlignment.Left
	hLabel.Text = "Recycler"
	hLabel.Parent = frame

	local yBadge = Instance.new("TextLabel")
	yBadge.Position = UDim2.fromOffset(118, 12)
	yBadge.Size = UDim2.fromOffset(140, 22)
	yBadge.BackgroundColor3 = Color3.fromRGB(34, 38, 46)
	yBadge.BorderSizePixel = 0
	yBadge.Font = Enum.Font.GothamBold
	yBadge.TextSize = 12
	yBadge.TextColor3 = Color3.fromRGB(255, 200, 85)
	yBadge.Text = "RT 60% Yield"
	yBadge.Parent = frame

	local yCorner = Instance.new("UICorner")
	yCorner.CornerRadius = UDim.new(0, 6)
	yCorner.Parent = yBadge

	local closeBtn = Instance.new("TextButton")
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
		RecyclerController.SetOpen(false)
	end)

	local inTitle = Instance.new("TextLabel")
	inTitle.Position = UDim2.fromOffset(14, 46)
	inTitle.Size = UDim2.new(1, -28, 0, 18)
	inTitle.BackgroundTransparency = 1
	inTitle.Font = Enum.Font.GothamBold
	inTitle.TextSize = 12
	inTitle.TextColor3 = Color3.fromRGB(190, 195, 210)
	inTitle.TextXAlignment = Enum.TextXAlignment.Left
	inTitle.Text = "Input (click slot to take back)"
	inTitle.Parent = frame

	local inGrid = Instance.new("Frame")
	inGrid.Position = UDim2.fromOffset(14, 68)
	inGrid.Size = UDim2.fromOffset(358, 58)
	inGrid.BackgroundTransparency = 1
	inGrid.Parent = frame

	local inLayout = Instance.new("UIGridLayout")
	inLayout.CellSize = UDim2.fromOffset(56, 56)
	inLayout.CellPadding = UDim2.fromOffset(4, 4)
	inLayout.SortOrder = Enum.SortOrder.LayoutOrder
	inLayout.Parent = inGrid

	for i = 1, Config.Recycler.InputSlots do
		inputSlotUIs[i] = createGridSlot(inGrid, i, SLOT_DEFAULT_BG, function(slotIdx: number)
			if activeState ~= nil then
				Net.GetEvent(Net.Events.RecyclerAction):FireServer(activeState.RecyclerId, "TakeInput", slotIdx)
			end
		end)
	end

	local pBg = Instance.new("Frame")
	pBg.Position = UDim2.fromOffset(14, 138)
	pBg.Size = UDim2.new(1, -28, 0, 12)
	pBg.BackgroundColor3 = Color3.fromRGB(36, 38, 46)
	pBg.BorderSizePixel = 0
	pBg.Parent = frame

	local pCorner = Instance.new("UICorner")
	pCorner.CornerRadius = UDim.new(0, 4)
	pCorner.Parent = pBg

	local pFill = Instance.new("Frame")
	pFill.Size = UDim2.fromScale(0, 1)
	pFill.BackgroundColor3 = Color3.fromRGB(70, 210, 110)
	pFill.BorderSizePixel = 0
	pFill.Parent = pBg

	local pfCorner = Instance.new("UICorner")
	pfCorner.CornerRadius = UDim.new(0, 4)
	pfCorner.Parent = pFill

	local sLabel = Instance.new("TextLabel")
	sLabel.Position = UDim2.fromOffset(14, 154)
	sLabel.Size = UDim2.new(1, -28, 0, 18)
	sLabel.BackgroundTransparency = 1
	sLabel.Font = Enum.Font.GothamMedium
	sLabel.TextSize = 11
	sLabel.TextColor3 = Color3.fromRGB(180, 188, 200)
	sLabel.TextXAlignment = Enum.TextXAlignment.Left
	sLabel.Text = "Idle"
	sLabel.Parent = frame

	local tBtn = Instance.new("TextButton")
	tBtn.Position = UDim2.fromOffset(14, 178)
	tBtn.Size = UDim2.fromOffset(172, 36)
	tBtn.BackgroundColor3 = BTN_OFF_BG
	tBtn.BorderSizePixel = 0
	tBtn.Font = Enum.Font.GothamBold
	tBtn.TextSize = 14
	tBtn.TextColor3 = Color3.new(1, 1, 1)
	tBtn.Text = "Turn On"
	tBtn.Parent = frame

	local tCorner = Instance.new("UICorner")
	tCorner.CornerRadius = UDim.new(0, 8)
	tCorner.Parent = tBtn

	tBtn.Activated:Connect(function()
		if activeState ~= nil then
			Net.GetEvent(Net.Events.RecyclerAction):FireServer(activeState.RecyclerId, "Toggle", nil)
		end
	end)

	local takeAllBtn = Instance.new("TextButton")
	takeAllBtn.Position = UDim2.fromOffset(200, 178)
	takeAllBtn.Size = UDim2.fromOffset(172, 36)
	takeAllBtn.BackgroundColor3 = Color3.fromRGB(58, 108, 168)
	takeAllBtn.BorderSizePixel = 0
	takeAllBtn.Font = Enum.Font.GothamBold
	takeAllBtn.TextSize = 14
	takeAllBtn.TextColor3 = Color3.new(1, 1, 1)
	takeAllBtn.Text = "Take All Output"
	takeAllBtn.Parent = frame

	local taCorner = Instance.new("UICorner")
	taCorner.CornerRadius = UDim.new(0, 8)
	taCorner.Parent = takeAllBtn

	takeAllBtn.Activated:Connect(function()
		if activeState ~= nil then
			Net.GetEvent(Net.Events.RecyclerAction):FireServer(activeState.RecyclerId, "TakeAllOutput", nil)
		end
	end)

	local outTitle = Instance.new("TextLabel")
	outTitle.Position = UDim2.fromOffset(14, 228)
	outTitle.Size = UDim2.new(1, -28, 0, 18)
	outTitle.BackgroundTransparency = 1
	outTitle.Font = Enum.Font.GothamBold
	outTitle.TextSize = 12
	outTitle.TextColor3 = Color3.fromRGB(145, 220, 180)
	outTitle.TextXAlignment = Enum.TextXAlignment.Left
	outTitle.Text = "Output (click slot to collect)"
	outTitle.Parent = frame

	local outGrid = Instance.new("Frame")
	outGrid.Position = UDim2.fromOffset(14, 250)
	outGrid.Size = UDim2.fromOffset(358, 58)
	outGrid.BackgroundTransparency = 1
	outGrid.Parent = frame

	local outLayout = Instance.new("UIGridLayout")
	outLayout.CellSize = UDim2.fromOffset(56, 56)
	outLayout.CellPadding = UDim2.fromOffset(4, 4)
	outLayout.SortOrder = Enum.SortOrder.LayoutOrder
	outLayout.Parent = outGrid

	for i = 1, Config.Recycler.OutputSlots do
		outputSlotUIs[i] = createGridSlot(outGrid, i, SLOT_OUTPUT_BG, function(slotIdx: number)
			if activeState ~= nil then
				Net.GetEvent(Net.Events.RecyclerAction):FireServer(activeState.RecyclerId, "TakeOutput", slotIdx)
			end
		end)
	end

	local tipLbl = Instance.new("TextLabel")
	tipLbl.Position = UDim2.fromOffset(14, 320)
	tipLbl.Size = UDim2.new(1, -28, 0, 26)
	tipLbl.BackgroundTransparency = 1
	tipLbl.Font = Enum.Font.Gotham
	tipLbl.TextSize = 11
	tipLbl.TextColor3 = Color3.fromRGB(160, 166, 178)
	tipLbl.TextXAlignment = Enum.TextXAlignment.Left
	tipLbl.Text = "Tick: 1 item every 3.0s | Auto-stops when empty or full"
	tipLbl.Parent = frame

	mainFrame = frame
	titleLabel = hLabel
	yieldBadgeLabel = yBadge
	toggleButton = tBtn
	progressFill = pFill
	statusLabel = sLabel
	screenGui.Parent = playerGui
end

function RecyclerController.IsOpen(): boolean
	return isOpen
end

function RecyclerController.SetOpen(open: boolean)
	if isOpen == open then
		return
	end
	isOpen = open
	if open then
		if LootController.IsOpen() then
			LootController.Close()
		end
		if BlueprintController.IsOpen() then
			BlueprintController.SetOpen(false)
		end
		InventoryUIController.RegisterSlotInterceptor(INTERCEPTOR_ID, function(slotIndex: number): boolean
			if not isOpen or activeState == nil then
				return false
			end
			local slot = InventoryController.GetSlot(slotIndex)
			if slot ~= nil and slot.Count > 0 and Recycling.CanRecycle(slot.Id) then
				Net.GetEvent(Net.Events.RecyclerAction):FireServer(activeState.RecyclerId, "Deposit", slotIndex)
			end
			return true
		end)
		if not InventoryUIController.IsOpen() then
			InventoryUIController.SetOpen(true)
		end
		refreshRecyclerUi()
	else
		local closedId = if activeState ~= nil then activeState.RecyclerId else nil
		activeState = nil
		InventoryUIController.UnregisterSlotInterceptor(INTERCEPTOR_ID)
		if closedId ~= nil then
			Net.GetEvent(Net.Events.RecyclerClose):FireServer(closedId)
		end
	end
	if mainFrame then
		mainFrame.Visible = open
	end
end

function RecyclerController.Init()
	if isInitialized then
		return
	end
	isInitialized = true

	createRecyclerGui()

	Net.GetEvent(Net.Events.RecyclerOpen).OnClientEvent:Connect(function(payload: any)
		local parsed = parseRecyclerState(payload)
		if parsed == nil then
			return
		end
		activeState = parsed
		RecyclerController.SetOpen(true)
	end)

	Net.GetEvent(Net.Events.RecyclerStateSync).OnClientEvent:Connect(function(payload: any)
		local parsed = parseRecyclerState(payload)
		if parsed == nil then
			return
		end
		if activeState ~= nil and activeState.RecyclerId == parsed.RecyclerId then
			activeState = parsed
			refreshRecyclerUi()
		end
	end)

	Net.GetEvent(Net.Events.ResearchTableOpen).OnClientEvent:Connect(function()
		if isOpen then
			RecyclerController.SetOpen(false)
		end
	end)

	InventoryUIController.OpenChanged:Connect(function(open: boolean)
		if not open and isOpen then
			RecyclerController.SetOpen(false)
		end
	end)

	LootController.OpenChanged:Connect(function(open: boolean)
		if open and isOpen then
			RecyclerController.SetOpen(false)
		end
	end)

	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessedEvent: boolean)
		if gameProcessedEvent then
			return
		end
		if input.KeyCode == Enum.KeyCode.Escape and isOpen then
			RecyclerController.SetOpen(false)
		end
	end)

	RunService.Heartbeat:Connect(function()
		if isOpen and activeState ~= nil then
			local localPlayer = Players.LocalPlayer
			local char = if localPlayer then localPlayer.Character else nil
			local hrp = if char then char:FindFirstChild("HumanoidRootPart") else nil
			if not (hrp and hrp:IsA("BasePart")) then
				RecyclerController.SetOpen(false)
				return
			end
			local maxDist = Config.Recycler.InteractDistance + 4
			if (hrp.Position - activeState.Position).Magnitude > maxDist then
				RecyclerController.SetOpen(false)
			end
		end
	end)
end

return RecyclerController
