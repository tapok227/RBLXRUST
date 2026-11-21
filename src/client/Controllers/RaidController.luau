--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Types = require(ReplicatedStorage.Shared.Types)
local Explosives = require(ReplicatedStorage.Shared.configs.Explosives)
local Net = require(ReplicatedStorage.Shared.Net)
local HotbarController = require(script.Parent.HotbarController)
local InventoryController = require(script.Parent.InventoryController)
local InventoryUIController = require(script.Parent.InventoryUIController)
local CraftingController = require(script.Parent.CraftingController)
local LootController = require(script.Parent.LootController)
local BuildingController = require(script.Parent.BuildingController)

type RaidTargetInfo = Types.RaidTargetInfo
type RaidHudState = Types.RaidHudState

local PLACE_RAY_DISTANCE = 60
local PLACE_COOLDOWN = 0.4
local TERMINAL_MAX_DISTANCE = 16

local currentHudState: RaidHudState? = nil
local isSelectionOpen = false
local lastPlaceTime = 0
local isInitialized = false
local boundPrompts: { [ProximityPrompt]: boolean } = {}

local selectFrame: Frame? = nil
local selectStatusLabel: TextLabel? = nil
local targetListContainer: ScrollingFrame? = nil
local hudFrame: Frame? = nil
local hudStatusLabel: TextLabel? = nil
local extractButton: TextButton? = nil

local RaidController = {}

local function isAnyModalUiOpen(): boolean
	return isSelectionOpen or InventoryUIController.IsOpen() or CraftingController.IsOpen() or LootController.IsOpen()
end

local function formatTimeMMSS(totalSeconds: number): string
	local clamped = math.max(0, math.floor(totalSeconds + 0.5))
	local minutes = math.floor(clamped / 60)
	local seconds = clamped % 60
	return string.format("%02d:%02d", minutes, seconds)
end

local function clearTargetRows()
	if not targetListContainer then
		return
	end
	for _, child in targetListContainer:GetChildren() do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end
end

local function createTargetRow(target: RaidTargetInfo)
	if not targetListContainer then
		return
	end

	local row = Instance.new("Frame")
	row.Name = string.format("Target_%d", target.UserId)
	row.Size = UDim2.new(1, -8, 0, 52)
	row.BackgroundColor3 = Color3.fromRGB(34, 34, 42)
	row.BorderSizePixel = 0
	row.Parent = targetListContainer

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = row

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(70, 70, 84)
	stroke.Thickness = 1
	stroke.Parent = row

	local nameLabel = Instance.new("TextLabel")
	nameLabel.Name = "TargetName"
	nameLabel.Position = UDim2.fromOffset(12, 6)
	nameLabel.Size = UDim2.new(1, -140, 0, 20)
	nameLabel.BackgroundTransparency = 1
	nameLabel.Font = Enum.Font.GothamBold
	nameLabel.TextSize = 14
	nameLabel.TextColor3 = Color3.fromRGB(240, 240, 245)
	nameLabel.TextXAlignment = Enum.TextXAlignment.Left
	nameLabel.TextTruncate = Enum.TextTruncate.AtEnd
	nameLabel.Text = target.DisplayName
	nameLabel.Parent = row

	local infoLabel = Instance.new("TextLabel")
	infoLabel.Name = "PieceInfo"
	infoLabel.Position = UDim2.fromOffset(12, 27)
	infoLabel.Size = UDim2.new(1, -140, 0, 18)
	infoLabel.BackgroundTransparency = 1
	infoLabel.Font = Enum.Font.Gotham
	infoLabel.TextSize = 12
	infoLabel.TextColor3 = Color3.fromRGB(185, 190, 205)
	infoLabel.TextXAlignment = Enum.TextXAlignment.Left
	infoLabel.Text = string.format("Structures: %d", target.PieceCount)
	infoLabel.Parent = row

	local launchBtn = Instance.new("TextButton")
	launchBtn.Name = "LaunchButton"
	launchBtn.AnchorPoint = Vector2.new(1, 0.5)
	launchBtn.Position = UDim2.new(1, -10, 0.5, 0)
	launchBtn.Size = UDim2.fromOffset(112, 34)
	launchBtn.BackgroundColor3 = Color3.fromRGB(175, 48, 48)
	launchBtn.BorderSizePixel = 0
	launchBtn.Font = Enum.Font.GothamBold
	launchBtn.TextSize = 13
	launchBtn.TextColor3 = Color3.new(1, 1, 1)
	launchBtn.Text = "Launch Raid"
	launchBtn.Parent = row

	local btnCorner = Instance.new("UICorner")
	btnCorner.CornerRadius = UDim.new(0, 6)
	btnCorner.Parent = launchBtn

	launchBtn.MouseButton1Click:Connect(function()
		RaidController.CloseTargetList()
		Net.GetEvent(Net.Events.StartRaidRequest):FireServer(target.UserId)
	end)
end

local function createRaidGui()
	local localPlayer = Players.LocalPlayer
	if not localPlayer then
		return
	end
	local playerGui = localPlayer:WaitForChild("PlayerGui") :: PlayerGui

	local existing = playerGui:FindFirstChild("RaidGui")
	if existing then
		existing:Destroy()
	end

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "RaidGui"
	screenGui.ResetOnSpawn = false
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	-- 1. Top Raid HUD bar
	local topBar = Instance.new("Frame")
	topBar.Name = "RaidHudFrame"
	topBar.AnchorPoint = Vector2.new(0.5, 0)
	topBar.Position = UDim2.new(0.5, 0, 0, 12)
	topBar.Size = UDim2.fromOffset(470, 44)
	topBar.BackgroundColor3 = Color3.fromRGB(135, 28, 28)
	topBar.BackgroundTransparency = 0.08
	topBar.BorderSizePixel = 0
	topBar.Visible = false
	topBar.Parent = screenGui

	local topCorner = Instance.new("UICorner")
	topCorner.CornerRadius = UDim.new(0, 8)
	topCorner.Parent = topBar

	local topStroke = Instance.new("UIStroke")
	topStroke.Color = Color3.fromRGB(245, 95, 95)
	topStroke.Thickness = 1.5
	topStroke.Parent = topBar

	local statusLbl = Instance.new("TextLabel")
	statusLbl.Name = "StatusLabel"
	statusLbl.Position = UDim2.fromOffset(14, 0)
	statusLbl.Size = UDim2.new(1, -172, 1, 0)
	statusLbl.BackgroundTransparency = 1
	statusLbl.Font = Enum.Font.GothamBold
	statusLbl.TextSize = 14
	statusLbl.TextColor3 = Color3.new(1, 1, 1)
	statusLbl.TextXAlignment = Enum.TextXAlignment.Left
	statusLbl.TextTruncate = Enum.TextTruncate.AtEnd
	statusLbl.Text = ""
	statusLbl.Parent = topBar

	local extractBtn = Instance.new("TextButton")
	extractBtn.Name = "ExtractButton"
	extractBtn.AnchorPoint = Vector2.new(1, 0.5)
	extractBtn.Position = UDim2.new(1, -10, 0.5, 0)
	extractBtn.Size = UDim2.fromOffset(144, 30)
	extractBtn.BackgroundColor3 = Color3.fromRGB(36, 145, 78)
	extractBtn.BorderSizePixel = 0
	extractBtn.Font = Enum.Font.GothamBold
	extractBtn.TextSize = 12
	extractBtn.TextColor3 = Color3.new(1, 1, 1)
	extractBtn.Text = "Extract with Loot"
	extractBtn.Parent = topBar

	local extractCorner = Instance.new("UICorner")
	extractCorner.CornerRadius = UDim.new(0, 6)
	extractCorner.Parent = extractBtn

	extractBtn.MouseButton1Click:Connect(function()
		Net.GetEvent(Net.Events.RaidExtractRequest):FireServer()
	end)

	-- 2. Raid Target Selection Modal
	local modal = Instance.new("Frame")
	modal.Name = "RaidSelectFrame"
	modal.AnchorPoint = Vector2.new(0.5, 0.5)
	modal.Position = UDim2.fromScale(0.5, 0.5)
	modal.Size = UDim2.fromOffset(440, 360)
	modal.BackgroundColor3 = Color3.fromRGB(22, 22, 28)
	modal.BackgroundTransparency = 0.05
	modal.BorderSizePixel = 0
	modal.Visible = false
	modal.Parent = screenGui

	local modalCorner = Instance.new("UICorner")
	modalCorner.CornerRadius = UDim.new(0, 10)
	modalCorner.Parent = modal

	local modalStroke = Instance.new("UIStroke")
	modalStroke.Color = Color3.fromRGB(190, 60, 60)
	modalStroke.Thickness = 2
	modalStroke.Parent = modal

	local titleLbl = Instance.new("TextLabel")
	titleLbl.Name = "TitleLabel"
	titleLbl.Position = UDim2.fromOffset(16, 12)
	titleLbl.Size = UDim2.new(1, -140, 0, 26)
	titleLbl.BackgroundTransparency = 1
	titleLbl.Font = Enum.Font.GothamBold
	titleLbl.TextSize = 16
	titleLbl.TextColor3 = Color3.fromRGB(255, 220, 220)
	titleLbl.TextXAlignment = Enum.TextXAlignment.Left
	titleLbl.Text = "RAID TERMINAL"
	titleLbl.Parent = modal

	local refreshBtn = Instance.new("TextButton")
	refreshBtn.Name = "RefreshButton"
	refreshBtn.AnchorPoint = Vector2.new(1, 0)
	refreshBtn.Position = UDim2.new(1, -50, 0, 10)
	refreshBtn.Size = UDim2.fromOffset(74, 28)
	refreshBtn.BackgroundColor3 = Color3.fromRGB(52, 54, 66)
	refreshBtn.BorderSizePixel = 0
	refreshBtn.Font = Enum.Font.GothamBold
	refreshBtn.TextSize = 12
	refreshBtn.TextColor3 = Color3.fromRGB(235, 235, 240)
	refreshBtn.Text = "Refresh"
	refreshBtn.Parent = modal

	local refreshCorner = Instance.new("UICorner")
	refreshCorner.CornerRadius = UDim.new(0, 6)
	refreshCorner.Parent = refreshBtn

	refreshBtn.MouseButton1Click:Connect(function()
		if selectStatusLabel then
			selectStatusLabel.Text = "Refreshing raid targets..."
		end
		Net.GetEvent(Net.Events.RaidListRequest):FireServer()
	end)

	local closeBtn = Instance.new("TextButton")
	closeBtn.Name = "CloseButton"
	closeBtn.AnchorPoint = Vector2.new(1, 0)
	closeBtn.Position = UDim2.new(1, -12, 0, 10)
	closeBtn.Size = UDim2.fromOffset(28, 28)
	closeBtn.BackgroundColor3 = Color3.fromRGB(150, 48, 48)
	closeBtn.BorderSizePixel = 0
	closeBtn.Font = Enum.Font.GothamBold
	closeBtn.TextSize = 14
	closeBtn.TextColor3 = Color3.new(1, 1, 1)
	closeBtn.Text = "X"
	closeBtn.Parent = modal

	local closeCorner = Instance.new("UICorner")
	closeCorner.CornerRadius = UDim.new(0, 6)
	closeCorner.Parent = closeBtn

	closeBtn.MouseButton1Click:Connect(function()
		RaidController.CloseTargetList()
	end)

	local listStatus = Instance.new("TextLabel")
	listStatus.Name = "StatusText"
	listStatus.Position = UDim2.fromOffset(16, 44)
	listStatus.Size = UDim2.new(1, -32, 0, 20)
	listStatus.BackgroundTransparency = 1
	listStatus.Font = Enum.Font.Gotham
	listStatus.TextSize = 12
	listStatus.TextColor3 = Color3.fromRGB(190, 190, 200)
	listStatus.TextXAlignment = Enum.TextXAlignment.Left
	listStatus.Text = "Select a base to raid:"
	listStatus.Parent = modal

	local scroller = Instance.new("ScrollingFrame")
	scroller.Name = "TargetList"
	scroller.Position = UDim2.fromOffset(14, 70)
	scroller.Size = UDim2.new(1, -28, 1, -84)
	scroller.BackgroundColor3 = Color3.fromRGB(16, 16, 22)
	scroller.BackgroundTransparency = 0.2
	scroller.BorderSizePixel = 0
	scroller.ScrollBarThickness = 6
	scroller.CanvasSize = UDim2.fromOffset(0, 0)
	scroller.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroller.Parent = modal

	local listPadding = Instance.new("UIPadding")
	listPadding.PaddingTop = UDim.new(0, 6)
	listPadding.PaddingBottom = UDim.new(0, 6)
	listPadding.PaddingLeft = UDim.new(0, 6)
	listPadding.PaddingRight = UDim.new(0, 6)
	listPadding.Parent = scroller

	local listLayout = Instance.new("UIListLayout")
	listLayout.Padding = UDim.new(0, 8)
	listLayout.SortOrder = Enum.SortOrder.LayoutOrder
	listLayout.Parent = scroller

	hudFrame = topBar
	hudStatusLabel = statusLbl
	extractButton = extractBtn
	selectFrame = modal
	selectStatusLabel = listStatus
	targetListContainer = scroller

	screenGui.Parent = playerGui
end

local function onRaidListSync(targetsAny: any)
	clearTargetRows()

	if type(targetsAny) ~= "table" then
		if selectStatusLabel then
			selectStatusLabel.Text = "No raid targets found."
		end
		return
	end

	local validTargets: { RaidTargetInfo } = {}
	for _, entry in targetsAny do
		if
			type(entry) == "table"
			and typeof(entry.UserId) == "number"
			and typeof(entry.DisplayName) == "string"
			and typeof(entry.PieceCount) == "number"
		then
			table.insert(validTargets, {
				UserId = entry.UserId,
				DisplayName = entry.DisplayName,
				PieceCount = entry.PieceCount,
			})
		end
	end

	if #validTargets == 0 then
		if selectStatusLabel then
			selectStatusLabel.Text = "No raidable bases available right now."
		end
		return
	end

	if selectStatusLabel then
		selectStatusLabel.Text = string.format("Available targets: %d", #validTargets)
	end
	for _, target in validTargets do
		createTargetRow(target)
	end
end

local function onRaidHudSync(stateAny: any)
	if type(stateAny) ~= "table" or typeof(stateAny.Active) ~= "boolean" then
		return
	end

	local targetName = if typeof(stateAny.TargetName) == "string" then stateAny.TargetName else "Target"
	local timeLeft = if typeof(stateAny.TimeLeft) == "number" then stateAny.TimeLeft else 0
	local statusText = if typeof(stateAny.StatusText) == "string" and #stateAny.StatusText > 0
		then stateAny.StatusText
		else nil

	if not stateAny.Active then
		currentHudState = nil
		if hudFrame then
			hudFrame.Visible = false
		end
		return
	end

	local state: RaidHudState = {
		Active = true,
		TargetName = targetName,
		TimeLeft = timeLeft,
		StatusText = statusText,
	}
	currentHudState = state

	if hudFrame and hudStatusLabel then
		if statusText ~= nil then
			hudStatusLabel.Text = string.format("RAIDING: %s | %s", targetName, statusText)
		else
			hudStatusLabel.Text = string.format("RAIDING: %s | Time Left: %s", targetName, formatTimeMMSS(timeLeft))
		end
		if extractButton then
			extractButton.Visible = statusText == nil
		end
		hudFrame.Visible = true
	end
end

local function findRaidPieceFromInstance(inst: Instance?): (Model?, string?)
	local structuresFolder = Workspace:FindFirstChild("RaidTargetStructures")
	if not structuresFolder or not inst or not inst:IsDescendantOf(structuresFolder) then
		return nil, nil
	end

	local current: Instance? = inst
	while current and current.Parent ~= structuresFolder do
		current = current.Parent
	end

	if not current or not current:IsA("Model") then
		return nil, nil
	end

	local uid = current:GetAttribute("RaidPieceUid")
	if typeof(uid) ~= "string" or #uid == 0 then
		return nil, nil
	end

	return current, uid
end

local function tryPlaceExplosive()
	if BuildingController.IsBuildMode() or isAnyModalUiOpen() then
		return
	end

	local selectedSlot = HotbarController.GetSelectedSlot()
	local equippedItem = InventoryController.GetSlot(selectedSlot)
	if equippedItem == nil or Explosives[equippedItem.Id] == nil then
		return
	end

	local now = os.clock()
	if (now - lastPlaceTime) < PLACE_COOLDOWN then
		return
	end

	local localPlayer = Players.LocalPlayer
	local camera = Workspace.CurrentCamera
	if not localPlayer or not camera then
		return
	end

	local character = localPlayer.Character
	local hrp = if character then character:FindFirstChild("HumanoidRootPart") else nil
	local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
	if not hrp or not hrp:IsA("BasePart") or not humanoid or humanoid.Health <= 0 then
		return
	end

	local mouseLoc = UserInputService:GetMouseLocation()
	local unitRay = camera:ViewportPointToRay(mouseLoc.X, mouseLoc.Y)

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.IgnoreWater = true
	if character then
		params.FilterDescendantsInstances = { character }
	end

	local result = Workspace:Raycast(unitRay.Origin, unitRay.Direction * PLACE_RAY_DISTANCE, params)
	if not result then
		return
	end

	local pieceModel, targetUid = findRaidPieceFromInstance(result.Instance)
	if not pieceModel or not targetUid then
		return
	end

	if (hrp.Position - result.Position).Magnitude > Types.MAX_EXPLOSIVE_PLACE_DISTANCE then
		return
	end

	lastPlaceTime = now
	Net.GetEvent(Net.Events.PlaceExplosiveRequest):FireServer(targetUid, result.Position)
end

local function bindPrompt(prompt: ProximityPrompt)
	if boundPrompts[prompt] then
		return
	end
	boundPrompts[prompt] = true

	prompt.Triggered:Connect(function(triggeringPlayer: Player)
		if triggeringPlayer == Players.LocalPlayer then
			RaidController.OpenTargetList()
		end
	end)
end

local function watchTerminal(terminal: Instance)
	for _, desc in terminal:GetDescendants() do
		if desc:IsA("ProximityPrompt") then
			bindPrompt(desc)
		end
	end
	terminal.DescendantAdded:Connect(function(desc: Instance)
		if desc:IsA("ProximityPrompt") then
			bindPrompt(desc)
		end
	end)
end

function RaidController.IsInRaid(): boolean
	return currentHudState ~= nil and currentHudState.Active
end

function RaidController.IsSelectionOpen(): boolean
	return isSelectionOpen
end

function RaidController.GetHudState(): RaidHudState?
	if currentHudState == nil then
		return nil
	end
	return table.clone(currentHudState)
end

function RaidController.OpenTargetList()
	isSelectionOpen = true
	local localPlayer = Players.LocalPlayer
	if localPlayer then
		localPlayer:SetAttribute("RaidSelectOpen", true)
	end
	if selectFrame then
		selectFrame.Visible = true
	end
	if selectStatusLabel then
		selectStatusLabel.Text = "Loading raid targets..."
	end
	clearTargetRows()
	Net.GetEvent(Net.Events.RaidListRequest):FireServer()
end

function RaidController.CloseTargetList()
	isSelectionOpen = false
	local localPlayer = Players.LocalPlayer
	if localPlayer then
		localPlayer:SetAttribute("RaidSelectOpen", false)
	end
	if selectFrame then
		selectFrame.Visible = false
	end
end

function RaidController.Init()
	if isInitialized then
		return
	end
	isInitialized = true

	createRaidGui()

	local existingTerminal = Workspace:FindFirstChild("RaidTerminal")
	if existingTerminal then
		watchTerminal(existingTerminal)
	end
	Workspace.ChildAdded:Connect(function(child: Instance)
		if child.Name == "RaidTerminal" then
			watchTerminal(child)
		end
	end)

	Net.GetEvent(Net.Events.RaidListSync).OnClientEvent:Connect(onRaidListSync)
	Net.GetEvent(Net.Events.RaidHudSync).OnClientEvent:Connect(onRaidHudSync)

	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessedEvent: boolean)
		if UserInputService:GetFocusedTextBox() ~= nil then
			return
		end
		if input.KeyCode == Enum.KeyCode.Escape and isSelectionOpen then
			RaidController.CloseTargetList()
			return
		end
		if gameProcessedEvent then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			tryPlaceExplosive()
		end
	end)

	RunService.Heartbeat:Connect(function()
		if not isSelectionOpen then
			return
		end
		local localPlayer = Players.LocalPlayer
		local character = if localPlayer then localPlayer.Character else nil
		local hrp = if character then character:FindFirstChild("HumanoidRootPart") else nil
		local terminal = Workspace:FindFirstChild("RaidTerminal")
		local primary = if terminal and terminal:IsA("Model") then terminal.PrimaryPart else nil

		if not hrp or not hrp:IsA("BasePart") or not primary then
			RaidController.CloseTargetList()
			return
		end

		if (hrp.Position - primary.Position).Magnitude > TERMINAL_MAX_DISTANCE then
			RaidController.CloseTargetList()
		end
	end)
end

return RaidController
