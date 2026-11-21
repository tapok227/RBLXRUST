--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Types = require(ReplicatedStorage.Shared.Types)
local Items = require(ReplicatedStorage.Shared.configs.Items)
local Nodes = require(ReplicatedStorage.Shared.configs.Nodes)
local Tools = require(ReplicatedStorage.Shared.configs.Tools)
local Net = require(ReplicatedStorage.Shared.Net)
local HotbarController = require(script.Parent.HotbarController)
local InventoryController = require(script.Parent.InventoryController)
local InventoryUIController = require(script.Parent.InventoryUIController)

type NodeClientState = Types.NodeClientState

local HOVER_RAY_MAX_DIST = 16
local CLIENT_RAY_LENGTH = 100

local nodeStates: { [string]: NodeClientState } = {}
local lastLocalHit = 0
local isInitialized = false

local hudFrame: Frame? = nil
local hudTitleLabel: TextLabel? = nil
local hudHpLabel: TextLabel? = nil
local hudFillBar: Frame? = nil

local GatheringController = {}

local function findNodeModelFromInstance(inst: Instance?): (Model?, string?, string?)
	local nodesFolder = Workspace:FindFirstChild("ResourceNodes")
	if not nodesFolder or not inst or not inst:IsDescendantOf(nodesFolder) then
		return nil, nil, nil
	end

	local current: Instance? = inst
	while current and current.Parent ~= nodesFolder do
		current = current.Parent
	end

	if not current or not current:IsA("Model") then
		return nil, nil, nil
	end

	local nodeId = current:GetAttribute("NodeId")
	local nodeType = current:GetAttribute("NodeType")
	if typeof(nodeId) ~= "string" or typeof(nodeType) ~= "string" then
		return nil, nil, nil
	end

	return current, nodeId, nodeType
end

local function findNodeModelById(nodeId: string): Model?
	local nodesFolder = Workspace:FindFirstChild("ResourceNodes")
	if not nodesFolder then
		return nil
	end
	for _, child in nodesFolder:GetChildren() do
		if child:IsA("Model") and child:GetAttribute("NodeId") == nodeId then
			return child
		end
	end
	return nil
end

local function raycastNodeFromCursor(maxCharacterDistance: number): (Model?, string?, string?, Vector3?)
	local localPlayer = Players.LocalPlayer
	local camera = Workspace.CurrentCamera
	if not localPlayer or not camera then
		return nil, nil, nil, nil
	end

	local character = localPlayer.Character
	local hrp = if character then character:FindFirstChild("HumanoidRootPart") else nil
	if not hrp or not hrp:IsA("BasePart") then
		return nil, nil, nil, nil
	end

	local mouseLoc = UserInputService:GetMouseLocation()
	local unitRay = camera:ViewportPointToRay(mouseLoc.X, mouseLoc.Y)

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	if character then
		params.FilterDescendantsInstances = { character }
	end

	local result = Workspace:Raycast(unitRay.Origin, unitRay.Direction * CLIENT_RAY_LENGTH, params)
	if not result then
		return nil, nil, nil, nil
	end

	local model, nodeId, nodeType = findNodeModelFromInstance(result.Instance)
	if not model or not nodeId or not nodeType then
		return nil, nil, nil, nil
	end

	local primaryPart = model.PrimaryPart
	local hitDist = (hrp.Position - result.Position).Magnitude
	local centerDist = if primaryPart then (hrp.Position - primaryPart.Position).Magnitude else math.huge

	if hitDist > maxCharacterDistance and centerDist > maxCharacterDistance then
		return nil, nil, nil, nil
	end

	return model, nodeId, nodeType, result.Position
end

local function playHitFeedback(model: Model, text: string)
	local primaryPart = model.PrimaryPart
	if not primaryPart then
		return
	end

	local highlight = Instance.new("Highlight")
	highlight.FillColor = Color3.fromRGB(255, 230, 140)
	highlight.FillTransparency = 0.65
	highlight.OutlineColor = Color3.new(1, 1, 1)
	highlight.OutlineTransparency = 0.1
	highlight.Parent = model

	task.delay(0.12, function()
		if highlight.Parent then
			highlight:Destroy()
		end
	end)

	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.fromOffset(140, 36)
	billboard.StudsOffset = Vector3.new(0, 3, 0)
	billboard.AlwaysOnTop = true
	billboard.Adornee = primaryPart

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextSize = 16
	label.TextColor3 = Color3.fromRGB(255, 230, 120)
	label.TextStrokeTransparency = 0.3
	label.Text = text
	label.Parent = billboard

	billboard.Parent = primaryPart

	local offsetTween = TweenService:Create(
		billboard,
		TweenInfo.new(0.65, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ StudsOffset = Vector3.new(0, 5.5, 0) }
	)
	local fadeTween = TweenService:Create(
		label,
		TweenInfo.new(0.65, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
		{ TextTransparency = 1, TextStrokeTransparency = 1 }
	)

	offsetTween:Play()
	fadeTween:Play()

	task.delay(0.7, function()
		if billboard.Parent then
			billboard:Destroy()
		end
	end)
end

local function createGatherHud()
	local localPlayer = Players.LocalPlayer
	if not localPlayer then
		return
	end
	local playerGui = localPlayer:WaitForChild("PlayerGui") :: PlayerGui

	local existing = playerGui:FindFirstChild("GatherHudGui")
	if existing then
		existing:Destroy()
	end

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "GatherHudGui"
	screenGui.ResetOnSpawn = false
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	local frame = Instance.new("Frame")
	frame.Name = "NodeHudFrame"
	frame.AnchorPoint = Vector2.new(0.5, 1)
	frame.Position = UDim2.new(0.5, 0, 1, -110)
	frame.Size = UDim2.fromOffset(240, 46)
	frame.BackgroundColor3 = Color3.fromRGB(20, 20, 26)
	frame.BackgroundTransparency = 0.2
	frame.BorderSizePixel = 0
	frame.Visible = false
	frame.Parent = screenGui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = frame

	local title = Instance.new("TextLabel")
	title.Name = "NodeTitle"
	title.Position = UDim2.fromOffset(10, 4)
	title.Size = UDim2.new(0.6, -10, 0, 18)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBold
	title.TextSize = 13
	title.TextColor3 = Color3.fromRGB(240, 240, 245)
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Text = ""
	title.Parent = frame

	local hpLabel = Instance.new("TextLabel")
	hpLabel.Name = "HpLabel"
	hpLabel.AnchorPoint = Vector2.new(1, 0)
	hpLabel.Position = UDim2.new(1, -10, 0, 4)
	hpLabel.Size = UDim2.new(0.4, -10, 0, 18)
	hpLabel.BackgroundTransparency = 1
	hpLabel.Font = Enum.Font.GothamMedium
	hpLabel.TextSize = 12
	hpLabel.TextColor3 = Color3.fromRGB(200, 220, 200)
	hpLabel.TextXAlignment = Enum.TextXAlignment.Right
	hpLabel.Text = ""
	hpLabel.Parent = frame

	local barBg = Instance.new("Frame")
	barBg.Name = "BarBackground"
	barBg.Position = UDim2.fromOffset(10, 26)
	barBg.Size = UDim2.new(1, -20, 0, 10)
	barBg.BackgroundColor3 = Color3.fromRGB(45, 45, 55)
	barBg.BorderSizePixel = 0
	barBg.Parent = frame

	local barBgCorner = Instance.new("UICorner")
	barBgCorner.CornerRadius = UDim.new(0, 4)
	barBgCorner.Parent = barBg

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundColor3 = Color3.fromRGB(95, 195, 105)
	fill.BorderSizePixel = 0
	fill.Parent = barBg

	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(0, 4)
	fillCorner.Parent = fill

	hudFrame = frame
	hudTitleLabel = title
	hudHpLabel = hpLabel
	hudFillBar = fill

	screenGui.Parent = playerGui
end

local function updateHoverHud()
	if not hudFrame or not hudTitleLabel or not hudHpLabel or not hudFillBar then
		return
	end

	if InventoryUIController.IsOpen() then
		hudFrame.Visible = false
		return
	end

	local model, nodeId, nodeType = raycastNodeFromCursor(HOVER_RAY_MAX_DIST)
	if not model or not nodeId or not nodeType then
		hudFrame.Visible = false
		return
	end

	local nodeConfig = Nodes[nodeType]
	if not nodeConfig then
		hudFrame.Visible = false
		return
	end

	local state = nodeStates[nodeId]
	local hp = if state then state.Hp else nodeConfig.MaxHp
	local maxHp = if state then state.MaxHp else nodeConfig.MaxHp
	local depleted = if state then state.Depleted else (model:GetAttribute("Depleted") == true)

	if depleted or hp <= 0 then
		hudFrame.Visible = false
		return
	end

	hudTitleLabel.Text = nodeConfig.Name
	hudHpLabel.Text = string.format("%d / %d", math.ceil(hp), maxHp)
	local ratio = if maxHp > 0 then math.clamp(hp / maxHp, 0, 1) else 0
	hudFillBar.Size = UDim2.fromScale(ratio, 1)
	hudFrame.Visible = true
end

local function tryGather()
	if InventoryUIController.IsOpen() then
		return
	end

	local model, nodeId, nodeType = raycastNodeFromCursor(Types.MAX_GATHER_DISTANCE_CLIENT)
	if not model or not nodeId or not nodeType then
		return
	end

	local state = nodeStates[nodeId]
	local isDepleted = if state then state.Depleted else (model:GetAttribute("Depleted") == true)
	if isDepleted then
		return
	end

	local equippedSlot = HotbarController.GetSelectedSlot()
	local equippedItem = InventoryController.GetSlot(equippedSlot)
	local toolConfig = if equippedItem ~= nil then Tools[equippedItem.Id] else nil
	local cooldown = if toolConfig ~= nil then toolConfig.Cooldown else Types.HANDS_COOLDOWN

	local now = os.clock()
	if (now - lastLocalHit) < cooldown then
		return
	end
	lastLocalHit = now

	Net.GetEvent(Net.Events.HitNode):FireServer(nodeId)
end

function GatheringController.GetNodeState(nodeId: string): NodeClientState?
	return nodeStates[nodeId]
end

function GatheringController.Init()
	if isInitialized then
		return
	end
	isInitialized = true

	createGatherHud()

	local updatedEvent = Net.GetEvent(Net.Events.NodeUpdated)
	updatedEvent.OnClientEvent:Connect(function(nodeId: string, hp: number, maxHp: number, depleted: boolean)
		if typeof(nodeId) ~= "string" or typeof(hp) ~= "number" or typeof(maxHp) ~= "number" then
			return
		end

		local prev = nodeStates[nodeId]
		local prevHp = if prev then prev.Hp else maxHp
		nodeStates[nodeId] = {
			Hp = hp,
			MaxHp = maxHp,
			Depleted = depleted == true,
		}

		if hp < prevHp then
			local model = findNodeModelById(nodeId)
			if model then
				local nodeType = model:GetAttribute("NodeType")
				local nodeConfig = if typeof(nodeType) == "string" then Nodes[nodeType] else nil
				local resConfig = if nodeConfig then Items[nodeConfig.ResourceId] else nil
				local resName = if resConfig then resConfig.Name else "Resource"
				local dmgDelta = math.max(1, math.floor(prevHp - hp + 0.5))
				playHitFeedback(model, string.format("-%d HP (%s)", dmgDelta, resName))
			end
		end
	end)

	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessedEvent: boolean)
		if gameProcessedEvent then
			return
		end
		if UserInputService:GetFocusedTextBox() ~= nil then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			tryGather()
		end
	end)

	RunService.RenderStepped:Connect(updateHoverHud)
end

return GatheringController
