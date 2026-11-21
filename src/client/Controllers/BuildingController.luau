--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)
local Types = require(ReplicatedStorage.Shared.Types)
local Items = require(ReplicatedStorage.Shared.configs.Items)
local BuildingConfig = require(ReplicatedStorage.Shared.configs.BuildingConfig)
local Net = require(ReplicatedStorage.Shared.Net)
local InventoryController = require(script.Parent.InventoryController)
local InventoryUIController = require(script.Parent.InventoryUIController)
local CraftingController = require(script.Parent.CraftingController)
local LootController = require(script.Parent.LootController)

type BuildPieceType = Types.BuildPieceType
type BuildTier = Types.BuildTier
type SavedBuildPiece = Types.SavedBuildPiece

type PieceButtonUI = {
	PieceType: BuildPieceType,
	Button: TextButton,
	Stroke: UIStroke,
	CostLabel: TextLabel,
}

local COLOR_GHOST_VALID = Color3.fromRGB(70, 225, 110)
local COLOR_GHOST_INVALID = Color3.fromRGB(235, 75, 75)
local COLOR_BTN_DEFAULT = Color3.fromRGB(36, 36, 44)
local COLOR_BTN_SELECTED = Color3.fromRGB(56, 86, 62)
local COLOR_STROKE_DEFAULT = Color3.fromRGB(80, 80, 92)
local COLOR_STROKE_SELECTED = Color3.fromRGB(115, 225, 130)
local COLOR_ACTION_ACTIVE = Color3.fromRGB(185, 135, 45)
local COLOR_DEMOLISH_ACTIVE = Color3.fromRGB(175, 55, 55)
local COLOR_ACTION_IDLE = Color3.fromRGB(52, 52, 62)

local PLACE_RAY_DISTANCE = 60

local savedPieces: { SavedBuildPiece } = {}
local selectedPieceIndex = 1
local currentRotY = 0
local isBuildMode = false
local upgradeModeToggle = false
local demolishModeToggle = false
local previewGridX = 0
local previewGridY = 0
local previewGridZ = 0
local hasValidPreview = false
local isInitialized = false

local baseActionBar: Frame? = nil
local buildToggleBtn: TextButton? = nil
local buildMenuFrame: Frame? = nil
local statusInfoLabel: TextLabel? = nil
local rotButton: TextButton? = nil
local upgradeToggleBtn: TextButton? = nil
local demolishToggleBtn: TextButton? = nil
local pieceButtons: { PieceButtonUI } = {}

local ghostModel: Model? = nil
local ghostPieceType: BuildPieceType? = nil
local targetHighlight: Highlight? = nil

local BuildingController = {}

local function isAnyModalUiOpen(): boolean
	return InventoryUIController.IsOpen() or CraftingController.IsOpen() or LootController.IsOpen()
end

local function getSelectedPieceType(): BuildPieceType
	return BuildingConfig.PieceOrder[selectedPieceIndex] or "foundation"
end

local function isUpgradeSubModeActive(): boolean
	return upgradeModeToggle or UserInputService:IsKeyDown(Enum.KeyCode.G)
end

local function isDemolishSubModeActive(): boolean
	return demolishModeToggle and not isUpgradeSubModeActive()
end

local function formatCostText(costMap: { [string]: number }): string
	local parts: { string } = {}
	for itemId, count in costMap do
		local itemCfg = Items[itemId]
		local itemName = if itemCfg then itemCfg.Name else itemId
		table.insert(parts, string.format("%d %s", count, itemName))
	end
	table.sort(parts)
	return table.concat(parts, ", ")
end

local function countOwnedItem(itemId: string): number
	local inv = InventoryController.GetInventory()
	local total = 0
	for i = 1, Types.INVENTORY_SIZE do
		local slot = inv[i]
		if slot ~= nil and slot.Id == itemId then
			total += slot.Count
		end
	end
	return total
end

local function canAffordCost(costMap: { [string]: number }): boolean
	for itemId, required in costMap do
		if countOwnedItem(itemId) < required then
			return false
		end
	end
	return true
end

local function hasLocalCollision(
	pieceType: BuildPieceType,
	gridX: number,
	gridY: number,
	gridZ: number,
	rotY: number
): boolean
	for _, existing in savedPieces do
		if existing.GridX == gridX and existing.GridY == gridY and existing.GridZ == gridZ then
			if existing.PieceType == pieceType then
				return true
			end
			if (pieceType == "wall" or pieceType == "doorway") and existing.RotY == rotY then
				if existing.PieceType == "wall" or existing.PieceType == "doorway" then
					return true
				end
			end
			if pieceType == "storage_box" or pieceType == "workbench_1" then
				if existing.PieceType == "storage_box" or existing.PieceType == "workbench_1" then
					return true
				end
			end
		end
	end
	return false
end

local function destroyGhostModel()
	if ghostModel then
		ghostModel:Destroy()
		ghostModel = nil
	end
	ghostPieceType = nil
end

local function createGhostPart(parent: Instance, size: Vector3, localCF: CFrame): Part
	local part = Instance.new("Part")
	part.Size = size
	part.CFrame = localCF
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.SmoothPlastic
	part.Transparency = 0.55
	part.Color = COLOR_GHOST_VALID
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

local function ensureGhostModel(pieceType: BuildPieceType): Model
	if ghostModel and ghostModel.Parent and ghostPieceType == pieceType then
		return ghostModel
	end

	destroyGhostModel()

	local model = Instance.new("Model")
	model.Name = string.format("BuildGhost_%s", pieceType)

	if pieceType == "foundation" then
		local basePart = createGhostPart(model, Vector3.new(12, 1, 12), CFrame.new(0, 0.5, 0))
		model.PrimaryPart = basePart
	elseif pieceType == "wall" then
		local wallPart = createGhostPart(model, Vector3.new(12, 10, 1), CFrame.new(0, 5, -5.5))
		model.PrimaryPart = wallPart
	elseif pieceType == "doorway" then
		createGhostPart(model, Vector3.new(4, 10, 1), CFrame.new(-4, 5, -5.5))
		createGhostPart(model, Vector3.new(4, 10, 1), CFrame.new(4, 5, -5.5))
		local lintel = createGhostPart(model, Vector3.new(4, 2.5, 1), CFrame.new(0, 8.75, -5.5))
		model.PrimaryPart = lintel
	elseif pieceType == "roof" then
		local roofPart = createGhostPart(model, Vector3.new(12, 0.8, 12), CFrame.new(0, 10.4, 0))
		model.PrimaryPart = roofPart
	elseif pieceType == "storage_box" then
		local body = createGhostPart(model, Vector3.new(4, 2.4, 2.5), CFrame.new(0, 2.2, 0))
		createGhostPart(model, Vector3.new(4.2, 0.4, 2.7), CFrame.new(0, 3.6, 0))
		model.PrimaryPart = body
	elseif pieceType == "workbench_1" then
		local top = createGhostPart(model, Vector3.new(5, 0.6, 3), CFrame.new(0, 3.3, 0))
		createGhostPart(model, Vector3.new(0.6, 2.0, 2.6), CFrame.new(-2.0, 2.0, 0))
		createGhostPart(model, Vector3.new(0.6, 2.0, 2.6), CFrame.new(2.0, 2.0, 0))
		model.PrimaryPart = top
	end

	ghostModel = model
	ghostPieceType = pieceType
	return model
end

local function clearTargetHighlight()
	if targetHighlight then
		targetHighlight.Adornee = nil
		targetHighlight.Enabled = false
	end
end

local function updateBuildUiVisuals()
	local inBase = BuildingController.IsBaseMode()
	if baseActionBar then
		baseActionBar.Visible = inBase
	end

	if buildToggleBtn then
		buildToggleBtn.BackgroundColor3 = if isBuildMode then COLOR_STROKE_SELECTED else Color3.fromRGB(55, 110, 165)
		buildToggleBtn.Text = if isBuildMode then "Build: ON [B]" else "Build [B]"
	end

	if buildMenuFrame then
		buildMenuFrame.Visible = inBase and isBuildMode
	end

	local selectedType = getSelectedPieceType()
	for _, item in pieceButtons do
		local isSelected = (item.PieceType == selectedType)
		item.Button.BackgroundColor3 = if isSelected then COLOR_BTN_SELECTED else COLOR_BTN_DEFAULT
		item.Stroke.Color = if isSelected then COLOR_STROKE_SELECTED else COLOR_STROKE_DEFAULT
		item.Stroke.Thickness = if isSelected then 2 else 1.2

		local pieceCfg = BuildingConfig.Pieces[item.PieceType]
		if pieceCfg then
			local affordable = canAffordCost(pieceCfg.Cost)
			item.CostLabel.TextColor3 = if affordable
				then Color3.fromRGB(145, 225, 150)
				else Color3.fromRGB(235, 115, 115)
		end
	end

	local selectedCfg = BuildingConfig.Pieces[selectedType]
	if statusInfoLabel and selectedCfg then
		local affordable = canAffordCost(selectedCfg.Cost)
		local costText = formatCostText(selectedCfg.Cost)
		statusInfoLabel.Text = string.format("%s | Cost: %s", selectedCfg.Name, costText)
		statusInfoLabel.TextColor3 = if affordable then Color3.fromRGB(140, 235, 145) else Color3.fromRGB(235, 110, 110)
	end

	if rotButton then
		rotButton.Text = string.format("Rot: %d deg [R]", currentRotY)
	end

	local upgradeActive = isUpgradeSubModeActive()
	local demolishActive = isDemolishSubModeActive()
	if upgradeToggleBtn then
		upgradeToggleBtn.BackgroundColor3 = if upgradeActive then COLOR_ACTION_ACTIVE else COLOR_ACTION_IDLE
	end
	if demolishToggleBtn then
		demolishToggleBtn.BackgroundColor3 = if demolishActive then COLOR_DEMOLISH_ACTIVE else COLOR_ACTION_IDLE
	end
end

local function raycastStructureUnderCursor(): (Model?, string?, BuildPieceType?, BuildTier?)
	local structuresFolder = Workspace:FindFirstChild("PlayerBaseStructures")
	local camera = Workspace.CurrentCamera
	local localPlayer = Players.LocalPlayer
	if not structuresFolder or not camera or not localPlayer then
		return nil, nil, nil, nil
	end

	local mouseLoc = UserInputService:GetMouseLocation()
	local unitRay = camera:ViewportPointToRay(mouseLoc.X, mouseLoc.Y)

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { structuresFolder }

	local result = Workspace:Raycast(unitRay.Origin, unitRay.Direction * 120, params)
	if not result or not result.Instance then
		return nil, nil, nil, nil
	end

	local current: Instance? = result.Instance
	while current ~= nil and current.Parent ~= structuresFolder do
		current = current.Parent
	end
	if not current or not current:IsA("Model") then
		return nil, nil, nil, nil
	end

	local uidAttr = current:GetAttribute("BuildUid")
	local pieceTypeAttr = current:GetAttribute("PieceType")
	local tierAttr = current:GetAttribute("Tier")
	if typeof(uidAttr) ~= "string" or typeof(pieceTypeAttr) ~= "string" or typeof(tierAttr) ~= "string" then
		return nil, nil, nil, nil
	end

	return current, uidAttr, pieceTypeAttr :: BuildPieceType, tierAttr :: BuildTier
end

local function handleBuildLeftClick()
	if not BuildingController.IsBaseMode() or not isBuildMode or isAnyModalUiOpen() then
		return
	end

	if isUpgradeSubModeActive() then
		local _, uid, pieceType, tier = raycastStructureUnderCursor()
		if uid == nil or pieceType == nil or tier == nil then
			return
		end
		local pieceCfg = BuildingConfig.Pieces[pieceType]
		if not pieceCfg or not pieceCfg.Upgradeable then
			return
		end
		local nextTier: BuildTier? = if tier == "wood" then "stone" elseif tier == "stone" then "metal" else nil
		if nextTier ~= nil then
			Net.GetEvent(Net.Events.BuildUpgradeRequest):FireServer(uid, nextTier)
		end
		return
	end

	if isDemolishSubModeActive() then
		local _, uid = raycastStructureUnderCursor()
		if uid ~= nil then
			Net.GetEvent(Net.Events.BuildDemolishRequest):FireServer(uid)
		end
		return
	end

	if hasValidPreview then
		local selectedType = getSelectedPieceType()
		Net.GetEvent(Net.Events.BuildPlaceRequest)
			:FireServer(selectedType, previewGridX, previewGridY, previewGridZ, currentRotY)
	end
end

local function updatePreviewAndHighlight()
	if not BuildingController.IsBaseMode() or not isBuildMode or isAnyModalUiOpen() then
		hasValidPreview = false
		if ghostModel then
			ghostModel.Parent = nil
		end
		clearTargetHighlight()
		return
	end

	local upgradeActive = isUpgradeSubModeActive()
	local demolishActive = isDemolishSubModeActive()

	if upgradeActive or demolishActive then
		hasValidPreview = false
		if ghostModel then
			ghostModel.Parent = nil
		end

		local hoveredModel = raycastStructureUnderCursor()
		if hoveredModel and targetHighlight then
			targetHighlight.Adornee = hoveredModel
			targetHighlight.OutlineColor = if demolishActive
				then Color3.fromRGB(255, 85, 85)
				else Color3.fromRGB(255, 210, 75)
			targetHighlight.FillColor = if demolishActive
				then Color3.fromRGB(235, 65, 65)
				else Color3.fromRGB(255, 195, 60)
			targetHighlight.Enabled = true
		else
			clearTargetHighlight()
		end
		return
	end

	clearTargetHighlight()

	local localPlayer = Players.LocalPlayer
	local camera = Workspace.CurrentCamera
	local character = if localPlayer then localPlayer.Character else nil
	local hrp = if character then character:FindFirstChild("HumanoidRootPart") else nil
	if not camera or not hrp or not hrp:IsA("BasePart") then
		hasValidPreview = false
		if ghostModel then
			ghostModel.Parent = nil
		end
		return
	end

	local selectedType = getSelectedPieceType()
	local ghost = ensureGhostModel(selectedType)

	local mouseLoc = UserInputService:GetMouseLocation()
	local unitRay = camera:ViewportPointToRay(mouseLoc.X, mouseLoc.Y)

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local excludeList: { Instance } = { ghost }
	if character then
		table.insert(excludeList, character)
	end
	params.FilterDescendantsInstances = excludeList

	local result = Workspace:Raycast(unitRay.Origin, unitRay.Direction * PLACE_RAY_DISTANCE, params)
	local targetPoint: Vector3
	if result then
		targetPoint = result.Position + result.Normal * 0.05
	else
		targetPoint = hrp.Position + unitRay.Direction * 18
	end

	local gridSize = BuildingConfig.GridSize
	local wallHeight = BuildingConfig.WallHeight
	previewGridX = math.clamp(math.round(targetPoint.X / gridSize), BuildingConfig.GridMinXZ, BuildingConfig.GridMaxXZ)
	previewGridY = math.clamp(
		math.floor(math.max(0, targetPoint.Y) / wallHeight),
		BuildingConfig.GridMinY,
		BuildingConfig.GridMaxY
	)
	previewGridZ = math.clamp(math.round(targetPoint.Z / gridSize), BuildingConfig.GridMinXZ, BuildingConfig.GridMaxXZ)
	hasValidPreview = true

	local baseCF = CFrame.new(previewGridX * gridSize, previewGridY * wallHeight, previewGridZ * gridSize)
		* CFrame.Angles(0, math.rad(currentRotY), 0)

	local pivotOffset = CFrame.identity
	if selectedType == "foundation" then
		pivotOffset = CFrame.new(0, 0.5, 0)
	elseif selectedType == "wall" then
		pivotOffset = CFrame.new(0, 5, -5.5)
	elseif selectedType == "doorway" then
		pivotOffset = CFrame.new(0, 8.75, -5.5)
	elseif selectedType == "roof" then
		pivotOffset = CFrame.new(0, 10.4, 0)
	elseif selectedType == "storage_box" then
		pivotOffset = CFrame.new(0, 2.2, 0)
	elseif selectedType == "workbench_1" then
		pivotOffset = CFrame.new(0, 3.3, 0)
	end

	if ghost.PrimaryPart then
		ghost:PivotTo(baseCF * pivotOffset)
	end

	local pieceCfg = BuildingConfig.Pieces[selectedType]
	local affordable = if pieceCfg then canAffordCost(pieceCfg.Cost) else false
	local collision = hasLocalCollision(selectedType, previewGridX, previewGridY, previewGridZ, currentRotY)
	local underCap = #savedPieces < BuildingConfig.MaxPiecesPerBase
	local canPlace = affordable and not collision and underCap

	local color = if canPlace then COLOR_GHOST_VALID else COLOR_GHOST_INVALID
	for _, child in ghost:GetDescendants() do
		if child:IsA("BasePart") then
			child.Color = color
		end
	end

	ghost.Parent = camera
end

local function createBuildingGui()
	local localPlayer = Players.LocalPlayer
	if not localPlayer then
		return
	end
	local playerGui = localPlayer:WaitForChild("PlayerGui") :: PlayerGui

	local existing = playerGui:FindFirstChild("BuildingGui")
	if existing then
		existing:Destroy()
	end

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "BuildingGui"
	screenGui.ResetOnSpawn = false
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.DisplayOrder = 12

	local actionBar = Instance.new("Frame")
	actionBar.Name = "BaseActionBar"
	actionBar.AnchorPoint = Vector2.new(1, 0)
	actionBar.Position = UDim2.new(1, -16, 0, 16)
	actionBar.Size = UDim2.fromOffset(296, 40)
	actionBar.BackgroundTransparency = 1
	actionBar.Visible = BuildingController.IsBaseMode()
	actionBar.Parent = screenGui

	local barLayout = Instance.new("UIListLayout")
	barLayout.FillDirection = Enum.FillDirection.Horizontal
	barLayout.HorizontalAlignment = Enum.HorizontalAlignment.Right
	barLayout.Padding = UDim.new(0, 8)
	barLayout.SortOrder = Enum.SortOrder.LayoutOrder
	barLayout.Parent = actionBar

	local buildBtn = Instance.new("TextButton")
	buildBtn.Name = "BuildToggleButton"
	buildBtn.LayoutOrder = 1
	buildBtn.Size = UDim2.fromOffset(118, 38)
	buildBtn.BackgroundColor3 = Color3.fromRGB(55, 110, 165)
	buildBtn.BorderSizePixel = 0
	buildBtn.Font = Enum.Font.GothamBold
	buildBtn.TextSize = 13
	buildBtn.TextColor3 = Color3.new(1, 1, 1)
	buildBtn.Text = "Build [B]"
	buildBtn.Parent = actionBar

	local buildBtnCorner = Instance.new("UICorner")
	buildBtnCorner.CornerRadius = UDim.new(0, 8)
	buildBtnCorner.Parent = buildBtn

	buildBtn.Activated:Connect(function()
		BuildingController.SetBuildMode(not isBuildMode)
	end)

	local deployBtn = Instance.new("TextButton")
	deployBtn.Name = "DeployButton"
	deployBtn.LayoutOrder = 2
	deployBtn.Size = UDim2.fromOffset(168, 38)
	deployBtn.BackgroundColor3 = Color3.fromRGB(55, 155, 85)
	deployBtn.BorderSizePixel = 0
	deployBtn.Font = Enum.Font.GothamBold
	deployBtn.TextSize = 13
	deployBtn.TextColor3 = Color3.new(1, 1, 1)
	deployBtn.Text = "Deploy to PvP Map"
	deployBtn.Parent = actionBar

	local deployCorner = Instance.new("UICorner")
	deployCorner.CornerRadius = UDim.new(0, 8)
	deployCorner.Parent = deployBtn

	deployBtn.Activated:Connect(function()
		if BuildingController.IsBaseMode() then
			Net.GetEvent(Net.Events.RequestReturnToMap):FireServer()
		end
	end)

	local menuFrame = Instance.new("Frame")
	menuFrame.Name = "BuildMenuFrame"
	menuFrame.AnchorPoint = Vector2.new(0.5, 1)
	menuFrame.Position = UDim2.new(0.5, 0, 1, -110)
	menuFrame.Size = UDim2.fromOffset(664, 122)
	menuFrame.BackgroundColor3 = Color3.fromRGB(18, 18, 24)
	menuFrame.BackgroundTransparency = 0.12
	menuFrame.BorderSizePixel = 0
	menuFrame.Visible = false
	menuFrame.Parent = screenGui

	local menuCorner = Instance.new("UICorner")
	menuCorner.CornerRadius = UDim.new(0, 10)
	menuCorner.Parent = menuFrame

	local menuStroke = Instance.new("UIStroke")
	menuStroke.Color = Color3.fromRGB(85, 85, 98)
	menuStroke.Thickness = 1.5
	menuStroke.Parent = menuFrame

	local piecesRow = Instance.new("Frame")
	piecesRow.Name = "PiecesRow"
	piecesRow.Position = UDim2.fromOffset(10, 10)
	piecesRow.Size = UDim2.new(1, -20, 0, 48)
	piecesRow.BackgroundTransparency = 1
	piecesRow.Parent = menuFrame

	local piecesLayout = Instance.new("UIListLayout")
	piecesLayout.FillDirection = Enum.FillDirection.Horizontal
	piecesLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	piecesLayout.Padding = UDim.new(0, 6)
	piecesLayout.SortOrder = Enum.SortOrder.LayoutOrder
	piecesLayout.Parent = piecesRow

	table.clear(pieceButtons)
	for index, pieceType in BuildingConfig.PieceOrder do
		local pieceCfg = BuildingConfig.Pieces[pieceType]
		local btn = Instance.new("TextButton")
		btn.Name = string.format("Piece_%s", pieceType)
		btn.LayoutOrder = index
		btn.Size = UDim2.fromOffset(102, 46)
		btn.BackgroundColor3 = COLOR_BTN_DEFAULT
		btn.BorderSizePixel = 0
		btn.Text = ""
		btn.Parent = piecesRow

		local btnCorner = Instance.new("UICorner")
		btnCorner.CornerRadius = UDim.new(0, 7)
		btnCorner.Parent = btn

		local btnStroke = Instance.new("UIStroke")
		btnStroke.Color = COLOR_STROKE_DEFAULT
		btnStroke.Thickness = 1.2
		btnStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		btnStroke.Parent = btn

		local nameLabel = Instance.new("TextLabel")
		nameLabel.Name = "NameLabel"
		nameLabel.Position = UDim2.fromOffset(4, 4)
		nameLabel.Size = UDim2.new(1, -8, 0, 18)
		nameLabel.BackgroundTransparency = 1
		nameLabel.Font = Enum.Font.GothamBold
		nameLabel.TextSize = 11
		nameLabel.TextColor3 = Color3.fromRGB(240, 240, 246)
		nameLabel.Text = if pieceCfg then pieceCfg.Name else pieceType
		nameLabel.Parent = btn

		local costLabel = Instance.new("TextLabel")
		costLabel.Name = "CostLabel"
		costLabel.Position = UDim2.fromOffset(4, 24)
		costLabel.Size = UDim2.new(1, -8, 0, 16)
		costLabel.BackgroundTransparency = 1
		costLabel.Font = Enum.Font.GothamMedium
		costLabel.TextSize = 10
		costLabel.TextColor3 = Color3.fromRGB(165, 215, 165)
		costLabel.Text = if pieceCfg then formatCostText(pieceCfg.Cost) else ""
		costLabel.Parent = btn

		btn.Activated:Connect(function()
			selectedPieceIndex = index
			upgradeModeToggle = false
			demolishModeToggle = false
			updateBuildUiVisuals()
		end)

		table.insert(pieceButtons, {
			PieceType = pieceType,
			Button = btn,
			Stroke = btnStroke,
			CostLabel = costLabel,
		})
	end

	local statusRow = Instance.new("Frame")
	statusRow.Name = "StatusRow"
	statusRow.Position = UDim2.fromOffset(10, 64)
	statusRow.Size = UDim2.new(1, -20, 0, 28)
	statusRow.BackgroundTransparency = 1
	statusRow.Parent = menuFrame

	local statusLabel = Instance.new("TextLabel")
	statusLabel.Name = "StatusInfo"
	statusLabel.Position = UDim2.fromOffset(2, 0)
	statusLabel.Size = UDim2.fromScale(0.46, 1)
	statusLabel.BackgroundTransparency = 1
	statusLabel.Font = Enum.Font.GothamBold
	statusLabel.TextSize = 12
	statusLabel.TextColor3 = Color3.fromRGB(140, 235, 145)
	statusLabel.TextXAlignment = Enum.TextXAlignment.Left
	statusLabel.Text = ""
	statusLabel.Parent = statusRow

	local rotBtn = Instance.new("TextButton")
	rotBtn.Name = "RotateButton"
	rotBtn.Position = UDim2.new(0.47, 0, 0, 1)
	rotBtn.Size = UDim2.fromOffset(118, 26)
	rotBtn.BackgroundColor3 = COLOR_ACTION_IDLE
	rotBtn.BorderSizePixel = 0
	rotBtn.Font = Enum.Font.GothamBold
	rotBtn.TextSize = 11
	rotBtn.TextColor3 = Color3.new(1, 1, 1)
	rotBtn.Text = "Rot: 0 deg [R]"
	rotBtn.Parent = statusRow

	local rotCorner = Instance.new("UICorner")
	rotCorner.CornerRadius = UDim.new(0, 6)
	rotCorner.Parent = rotBtn

	rotBtn.Activated:Connect(function()
		currentRotY = (currentRotY + 90) % 360
		updateBuildUiVisuals()
	end)

	local upgBtn = Instance.new("TextButton")
	upgBtn.Name = "UpgradeButton"
	upgBtn.Position = UDim2.new(0.67, 0, 0, 1)
	upgBtn.Size = UDim2.fromOffset(104, 26)
	upgBtn.BackgroundColor3 = COLOR_ACTION_IDLE
	upgBtn.BorderSizePixel = 0
	upgBtn.Font = Enum.Font.GothamBold
	upgBtn.TextSize = 11
	upgBtn.TextColor3 = Color3.new(1, 1, 1)
	upgBtn.Text = "Upgrade [G]"
	upgBtn.Parent = statusRow

	local upgCorner = Instance.new("UICorner")
	upgCorner.CornerRadius = UDim.new(0, 6)
	upgCorner.Parent = upgBtn

	upgBtn.Activated:Connect(function()
		upgradeModeToggle = not upgradeModeToggle
		if upgradeModeToggle then
			demolishModeToggle = false
		end
		updateBuildUiVisuals()
	end)

	local demBtn = Instance.new("TextButton")
	demBtn.Name = "DemolishButton"
	demBtn.Position = UDim2.new(0.84, 0, 0, 1)
	demBtn.Size = UDim2.fromOffset(96, 26)
	demBtn.BackgroundColor3 = COLOR_ACTION_IDLE
	demBtn.BorderSizePixel = 0
	demBtn.Font = Enum.Font.GothamBold
	demBtn.TextSize = 11
	demBtn.TextColor3 = Color3.new(1, 1, 1)
	demBtn.Text = "Demolish"
	demBtn.Parent = statusRow

	local demCorner = Instance.new("UICorner")
	demCorner.CornerRadius = UDim.new(0, 6)
	demCorner.Parent = demBtn

	demBtn.Activated:Connect(function()
		demolishModeToggle = not demolishModeToggle
		if demolishModeToggle then
			upgradeModeToggle = false
		end
		updateBuildUiVisuals()
	end)

	local hintLabel = Instance.new("TextLabel")
	hintLabel.Name = "ControlsHint"
	hintLabel.AnchorPoint = Vector2.new(0, 1)
	hintLabel.Position = UDim2.new(0, 10, 1, -6)
	hintLabel.Size = UDim2.new(1, -20, 0, 16)
	hintLabel.BackgroundTransparency = 1
	hintLabel.Font = Enum.Font.Gotham
	hintLabel.TextSize = 11
	hintLabel.TextColor3 = Color3.fromRGB(185, 185, 200)
	hintLabel.Text = "[Z/X] Piece | [R] Rotate | [G+LMB] Upgrade | [LMB] Place | [B] Exit"
	hintLabel.Parent = menuFrame

	local highlight = Instance.new("Highlight")
	highlight.Name = "BuildTargetHighlight"
	highlight.FillTransparency = 0.65
	highlight.OutlineTransparency = 0.05
	highlight.Enabled = false
	highlight.Parent = screenGui

	baseActionBar = actionBar
	buildToggleBtn = buildBtn
	buildMenuFrame = menuFrame
	statusInfoLabel = statusLabel
	rotButton = rotBtn
	upgradeToggleBtn = upgBtn
	demolishToggleBtn = demBtn
	targetHighlight = highlight

	screenGui.Parent = playerGui
end

local function onBaseStateSync(piecesAny: any)
	local parsed: { SavedBuildPiece } = {}
	if type(piecesAny) == "table" then
		for _, item in piecesAny do
			if
				type(item) == "table"
				and type(item.Uid) == "string"
				and type(item.PieceType) == "string"
				and type(item.Tier) == "string"
				and type(item.GridX) == "number"
				and type(item.GridY) == "number"
				and type(item.GridZ) == "number"
				and type(item.RotY) == "number"
				and type(item.Hp) == "number"
			then
				table.insert(parsed, {
					Uid = item.Uid,
					PieceType = item.PieceType :: BuildPieceType,
					Tier = item.Tier :: BuildTier,
					GridX = item.GridX,
					GridY = item.GridY,
					GridZ = item.GridZ,
					RotY = item.RotY,
					Hp = item.Hp,
					Storage = if type(item.Storage) == "table" then item.Storage else nil,
				})
			end
		end
	end
	savedPieces = parsed
end

function BuildingController.IsBaseMode(): boolean
	if Workspace:GetAttribute("RaidServerMode") == true then
		return false
	end
	local localPlayer = Players.LocalPlayer
	if localPlayer ~= nil and localPlayer:GetAttribute("InRaid") == true then
		return false
	end
	return game.PlaceId == Config.Places.PlayerBase
		or (RunService:IsStudio() and Workspace:GetAttribute("ForceBaseMode") == true)
end

function BuildingController.IsBuildMode(): boolean
	return BuildingController.IsBaseMode() and isBuildMode
end

function BuildingController.SetBuildMode(enabled: boolean)
	if enabled and not BuildingController.IsBaseMode() then
		return
	end
	isBuildMode = enabled
	if not enabled then
		upgradeModeToggle = false
		demolishModeToggle = false
		hasValidPreview = false
		if ghostModel then
			ghostModel.Parent = nil
		end
		clearTargetHighlight()
	end
	updateBuildUiVisuals()
end

function BuildingController.GetPieces(): { SavedBuildPiece }
	return table.clone(savedPieces)
end

function BuildingController.Init()
	if isInitialized then
		return
	end
	isInitialized = true

	createBuildingGui()
	updateBuildUiVisuals()

	Net.GetEvent(Net.Events.BaseStateSync).OnClientEvent:Connect(onBaseStateSync)

	InventoryController.OnChanged(function()
		updateBuildUiVisuals()
	end)

	if RunService:IsStudio() then
		Workspace:GetAttributeChangedSignal("ForceBaseMode"):Connect(function()
			if not BuildingController.IsBaseMode() then
				BuildingController.SetBuildMode(false)
			end
			updateBuildUiVisuals()
		end)
	end

	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessedEvent: boolean)
		if UserInputService:GetFocusedTextBox() ~= nil then
			return
		end

		if input.KeyCode == Enum.KeyCode.B and not gameProcessedEvent then
			if BuildingController.IsBaseMode() then
				BuildingController.SetBuildMode(not isBuildMode)
			end
			return
		end

		if not BuildingController.IsBuildMode() then
			return
		end

		if input.KeyCode == Enum.KeyCode.R and not gameProcessedEvent then
			currentRotY = (currentRotY + 90) % 360
			updateBuildUiVisuals()
		elseif input.KeyCode == Enum.KeyCode.Z and not gameProcessedEvent then
			local total = #BuildingConfig.PieceOrder
			selectedPieceIndex = ((selectedPieceIndex - 2) % total) + 1
			upgradeModeToggle = false
			demolishModeToggle = false
			updateBuildUiVisuals()
		elseif input.KeyCode == Enum.KeyCode.X and not gameProcessedEvent then
			local total = #BuildingConfig.PieceOrder
			selectedPieceIndex = (selectedPieceIndex % total) + 1
			upgradeModeToggle = false
			demolishModeToggle = false
			updateBuildUiVisuals()
		elseif input.KeyCode == Enum.KeyCode.G then
			updateBuildUiVisuals()
		elseif input.UserInputType == Enum.UserInputType.MouseButton1 and not gameProcessedEvent then
			handleBuildLeftClick()
		end
	end)

	UserInputService.InputEnded:Connect(function(input: InputObject)
		if input.KeyCode == Enum.KeyCode.G and isBuildMode then
			updateBuildUiVisuals()
		end
	end)

	RunService.RenderStepped:Connect(updatePreviewAndHighlight)
end

return BuildingController
