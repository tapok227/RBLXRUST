--!strict
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)
local Types = require(ReplicatedStorage.Shared.Types)
local Items = require(ReplicatedStorage.Shared.configs.Items)
local BuildingConfig = require(ReplicatedStorage.Shared.configs.BuildingConfig)
local Defenses = require(ReplicatedStorage.Shared.configs.Defenses)
local BuildingGeometry = require(ReplicatedStorage.Shared.BuildingGeometry)
local Net = require(ReplicatedStorage.Shared.Net)
local HotbarController = require(script.Parent.HotbarController)
local InventoryController = require(script.Parent.InventoryController)
local InventoryUIController = require(script.Parent.InventoryUIController)
local CraftingController = require(script.Parent.CraftingController)
local LootController = require(script.Parent.LootController)
local ToolCupboardController = require(script.Parent.ToolCupboardController)
local DefenseController = require(script.Parent.DefenseController)

type BuildPieceType = Types.BuildPieceType
type BuildTier = Types.BuildTier
type BuildSocketDef = Types.BuildSocketDef
type SavedBuildPiece = Types.SavedBuildPiece
type DefenseMountSurface = Types.DefenseMountSurface

type PieceButtonUI = {
	PieceType: BuildPieceType,
	Button: TextButton,
	Stroke: UIStroke,
	CostLabel: TextLabel,
}

local COLOR_GHOST_VALID_GRID = Color3.fromRGB(65, 220, 115)
local COLOR_GHOST_VALID_SOCKET = Color3.fromRGB(65, 155, 255)
local COLOR_GHOST_INVALID = Color3.fromRGB(235, 70, 70)
local COLOR_BTN_DEFAULT = Color3.fromRGB(36, 36, 44)
local COLOR_BTN_SELECTED = Color3.fromRGB(56, 86, 62)
local COLOR_STROKE_DEFAULT = Color3.fromRGB(80, 80, 92)
local COLOR_STROKE_SELECTED = Color3.fromRGB(115, 225, 130)
local COLOR_ACTION_ACTIVE = Color3.fromRGB(185, 135, 45)
local COLOR_DEMOLISH_ACTIVE = Color3.fromRGB(175, 55, 55)
local COLOR_ACTION_IDLE = Color3.fromRGB(52, 52, 62)

local PLACE_RAY_DISTANCE = 64
local SOCKET_SEARCH_RADIUS_FOUNDATION = 8.0
local SOCKET_SEARCH_RADIUS_OTHER = 10.5
local SOCKET_OCCUPY_EPSILON = 0.55

local savedPieces: { SavedBuildPiece } = {}
local selectedPieceIndex = 1
local currentRotStep = 0
local currentYawDeg = 0
local manualBuildMode = false
local toolMode: "None" | "Build" | "Hammer" | "DefenseItem" = "None"
local upgradeModeToggle = false
local demolishModeToggle = false

local previewCFrame: CFrame? = nil
local previewParentUid: string? = nil
local previewSocketId: string? = nil
local previewRotStep = 0
local previewMountSurface: DefenseMountSurface? = nil
local previewPlaceable = false
local previewStatusMessage = ""
local hammerStatusMessage = ""
local hammerStatusValid = true
local selectedMapIndex = 1
local feedbackToken = 0
local isInitialized = false

local baseActionBar: Frame? = nil
local baseTierBadge: TextLabel? = nil
local defenseCapacityBadge: TextLabel? = nil
local mapCycleBtn: TextButton? = nil
local buildToggleBtn: TextButton? = nil
local deployToMapBtn: TextButton? = nil
local feedbackToastLabel: TextLabel? = nil
local buildMenuFrame: Frame? = nil
local statusInfoLabel: TextLabel? = nil
local rotButton: TextButton? = nil
local upgradeToggleBtn: TextButton? = nil
local demolishToggleBtn: TextButton? = nil
local pieceButtons: { PieceButtonUI } = {}

local ghostModel: Model? = nil
local ghostPieceType: BuildPieceType? = nil
local ghostMountSurface: DefenseMountSurface? = nil
local targetHighlight: Highlight? = nil

-- Cached RaycastParams (updated only on character change or ghostModel recreation)
local cachedPreviewRayParams = RaycastParams.new()
cachedPreviewRayParams.FilterType = Enum.RaycastFilterType.Exclude
cachedPreviewRayParams.IgnoreWater = true
local cachedPreviewExcludes: { Instance } = {}

local cachedHammerRayParams = RaycastParams.new()
cachedHammerRayParams.FilterType = Enum.RaycastFilterType.Include

local BuildingController = {}

local function isInRaidMode(): boolean
	if Workspace:GetAttribute("RaidServerMode") == true then
		return true
	end
	local localPlayer = Players.LocalPlayer
	return localPlayer ~= nil and localPlayer:GetAttribute("InRaid") == true
end

local function getActiveStructuresFolder(): Instance?
	if isInRaidMode() then
		return Workspace:FindFirstChild("RaidOutpostStructures")
	end
	return Workspace:FindFirstChild("PlayerBaseStructures")
end

local function refreshPreviewRaycastFilter()
	local excludeList: { Instance } = {}
	local localPlayer = Players.LocalPlayer
	if localPlayer and localPlayer.Character then
		table.insert(excludeList, localPlayer.Character)
	end
	if ghostModel then
		table.insert(excludeList, ghostModel)
	end
	local outpostZone = Workspace:FindFirstChild("RaidOutpostZone")
	if outpostZone then
		table.insert(excludeList, outpostZone)
	end
	for _, tagged in CollectionService:GetTagged("RaidOutpostZone") do
		table.insert(excludeList, tagged)
	end
	cachedPreviewExcludes = excludeList
	cachedPreviewRayParams.FilterDescendantsInstances = excludeList
end

local function isAnyModalUiOpen(): boolean
	return InventoryUIController.IsOpen()
		or CraftingController.IsOpen()
		or LootController.IsOpen()
		or ToolCupboardController.IsOpen()
		or DefenseController.IsOpen()
end

local function getLocalBaseTier(): number
	local localPlayer = Players.LocalPlayer
	local attr = if localPlayer ~= nil then localPlayer:GetAttribute("BaseTier") else nil
	return if typeof(attr) == "number" then math.floor(attr) else 0
end

local function computeLocalDefenseCapacity(): (number, number)
	local used = 0
	for _, piece in savedPieces do
		local defCfg = Defenses.Get(BuildingGeometry.CanonicalPieceType(piece.PieceType))
		if defCfg ~= nil then
			used += defCfg.CapacityCost
		end
	end
	local maxCap = Defenses.GetCapacityLimit(getLocalBaseTier())
	return used, maxCap
end

local function getSelectedMapKey(): string
	local order = Config.MapOrder :: { string }
	return order[selectedMapIndex] or order[1] or "MainMap_Tier1"
end

local function getSelectedPieceType(): BuildPieceType
	return BuildingConfig.PieceOrder[selectedPieceIndex] or "foundation"
end

local function isHammerModeActive(): boolean
	return toolMode == "Hammer" or upgradeModeToggle or demolishModeToggle or UserInputService:IsKeyDown(Enum.KeyCode.G)
end

local function isDemolishSubModeActive(): boolean
	return demolishModeToggle and not UserInputService:IsKeyDown(Enum.KeyCode.G)
end

local function formatCostText(costMap: { [string]: number }): string
	local parts: { string } = {}
	for itemId, count in costMap do
		local itemCfg = Items[itemId]
		table.insert(parts, string.format("%d %s", count, if itemCfg then itemCfg.Name else itemId))
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

local function canAffordPiece(pieceType: BuildPieceType, pieceCfg: Types.BuildPieceConfig): boolean
	if toolMode == "DefenseItem" then
		local equipped = InventoryController.GetSlot(HotbarController.GetSelectedSlot())
		if equipped ~= nil and equipped.Count > 0 and BuildingGeometry.CanonicalPieceType(equipped.Id) == pieceType then
			return true
		end
	end
	return canAffordCost(pieceCfg.Cost)
end

local function destroyGhostModel()
	if ghostModel then
		ghostModel:Destroy()
		ghostModel = nil
	end
	ghostPieceType = nil
	ghostMountSurface = nil
	refreshPreviewRaycastFilter()
end

local function ensureGhostModel(pieceType: BuildPieceType, mountSurface: DefenseMountSurface?): Model
	local canonical = BuildingGeometry.CanonicalPieceType(pieceType)
	if ghostModel and ghostPieceType == canonical and ghostMountSurface == mountSurface then
		return ghostModel
	end
	destroyGhostModel()
	local model = BuildingGeometry.CreateModel(
		canonical,
		CFrame.identity,
		true,
		string.format("ClientBuildPreview_%s", canonical),
		mountSurface
	)
	ghostModel = model
	ghostPieceType = canonical
	ghostMountSurface = mountSurface
	refreshPreviewRaycastFilter()
	return model
end

local function clearTargetHighlight()
	if targetHighlight then
		targetHighlight.Adornee = nil
		targetHighlight.Enabled = false
	end
end

local function collectPlayerStructureModels(): { Model }
	local models: { Model } = {}
	local localPlayer = Players.LocalPlayer
	local structuresFolder = getActiveStructuresFolder()
	if not localPlayer or not structuresFolder then
		return models
	end
	for _, child in structuresFolder:GetChildren() do
		if child:IsA("Model") and child:GetAttribute("OwnerUserId") == localPlayer.UserId then
			table.insert(models, child)
		end
	end
	return models
end

local function isSocketOccupiedLocally(
	parentModel: Model,
	parentType: BuildPieceType,
	parentCF: CFrame,
	socket: BuildSocketDef,
	childType: BuildPieceType,
	allModels: { Model },
	rotStepOverride: number?
): boolean
	if BuildingConfig.Pieces[childType] == nil then
		return true
	end
	local targetSlotKey = BuildingGeometry.GetSocketSlotKey(socket, childType, rotStepOverride)
	for _, otherModel in allModels do
		if otherModel ~= parentModel then
			local otherTypeAttr = otherModel:GetAttribute("PieceType")
			if typeof(otherTypeAttr) == "string" then
				local otherType = BuildingGeometry.CanonicalPieceType(otherTypeAttr)
				if BuildingGeometry.GetSocketSlotKey(socket, otherType, rotStepOverride) == targetSlotKey then
					local otherPos = otherModel:GetPivot().Position
					if
						BuildingGeometry.DoesPieceOccupySocket(
							parentType,
							parentCF,
							socket,
							otherType,
							otherPos,
							SOCKET_OCCUPY_EPSILON,
							rotStepOverride
						)
					then
						return true
					end
				end
			end
		end
	end
	return false
end

local function hasSupportingWallLocally(parentType: BuildPieceType, parentCF: CFrame, allModels: { Model }): boolean
	local parentCfg = BuildingConfig.Pieces[parentType]
	local wallYOffset = if parentCfg ~= nil and parentCfg.Category == "Foundation"
		then BuildingConfig.FoundationThickness
		else BuildingConfig.FloorThickness
	for _, socket in BuildingGeometry.GetPieceSockets(parentType) do
		if socket.Kind == "Edge" then
			local edgeWallPos = (parentCF * socket.LocalCFrame * CFrame.new(0, wallYOffset, 0)).Position
			for _, otherModel in allModels do
				local otherTypeAttr = otherModel:GetAttribute("PieceType")
				if typeof(otherTypeAttr) == "string" then
					local otherCfg = BuildingConfig.Pieces[otherTypeAttr :: BuildPieceType]
					if otherCfg ~= nil and otherCfg.Category == "Wall" then
						if (otherModel:GetPivot().Position - edgeWallPos).Magnitude <= SOCKET_OCCUPY_EPSILON then
							return true
						end
					end
				end
			end
		end
	end
	return false
end

local function getLowestFoundationYLocally(allModels: { Model }, fallbackY: number): number
	local minY: number? = nil
	for _, model in allModels do
		local pieceTypeAttr = model:GetAttribute("PieceType")
		if typeof(pieceTypeAttr) == "string" then
			local cfg = BuildingConfig.Pieces[pieceTypeAttr :: BuildPieceType]
			if cfg ~= nil and cfg.Category == "Foundation" then
				local y = model:GetPivot().Position.Y
				if minY == nil or y < minY then
					minY = y
				end
			end
		end
	end
	return minY or fallbackY
end

local function buildLocalWallCandidates(allModels: { Model }): { BuildingGeometry.ParallelWallCandidate }
	local candidates: { BuildingGeometry.ParallelWallCandidate } = {}
	local folder = getActiveStructuresFolder()
	local sourceList = if folder then folder:GetChildren() else allModels
	for _, child in sourceList do
		if child:IsA("Model") then
			local pieceTypeAttr = child:GetAttribute("PieceType")
			if typeof(pieceTypeAttr) == "string" then
				table.insert(candidates, {
					PieceType = BuildingGeometry.CanonicalPieceType(pieceTypeAttr),
					CFrame = child:GetPivot(),
				})
			end
		end
	end
	return candidates
end

local function updateBuildUiVisuals()
	local canBuild = BuildingController.CanBuild()
	local inBase = BuildingController.IsBaseMode()
	local buildActive = BuildingController.IsBuildMode()
	local hammerActive = buildActive and isHammerModeActive()

	if baseActionBar then
		baseActionBar.Visible = canBuild
	end
	if baseTierBadge then
		local tier = getLocalBaseTier()
		baseTierBadge.Visible = inBase
		baseTierBadge.Text = string.format("Base: Tier %d", tier)
		baseTierBadge.BackgroundColor3 = if tier >= 3
			then Color3.fromRGB(45, 115, 155)
			elseif tier == 2 then Color3.fromRGB(150, 110, 40)
			elseif tier == 1 then Color3.fromRGB(52, 125, 72)
			else Color3.fromRGB(125, 52, 52)
	end
	if mapCycleBtn then
		mapCycleBtn.Visible = inBase
		local mapKey = getSelectedMapKey()
		local maps =
			Config.Maps :: { [string]: { Key: string, Name: string, PlaceId: number, RequiredBaseTier: number } }
		local mapCfg = maps[mapKey]
		local reqTier = if mapCfg ~= nil then mapCfg.RequiredBaseTier else 1
		local unlocked = getLocalBaseTier() >= reqTier
		mapCycleBtn.Text = string.format("Map: T%d", reqTier)
		mapCycleBtn.BackgroundColor3 = if unlocked then Color3.fromRGB(48, 86, 125) else Color3.fromRGB(95, 52, 52)
	end
	if deployToMapBtn then
		deployToMapBtn.Visible = inBase
	end
	if buildToggleBtn then
		buildToggleBtn.BackgroundColor3 = if hammerActive
			then COLOR_ACTION_ACTIVE
			elseif buildActive then COLOR_STROKE_SELECTED
			else Color3.fromRGB(55, 110, 165)
		buildToggleBtn.Text = if hammerActive then "Hammer [B]" elseif buildActive then "Build: ON [B]" else "Build [B]"
	end
	if buildMenuFrame then
		buildMenuFrame.Visible = canBuild and buildActive
	end

	local selectedType = getSelectedPieceType()
	local selectedCfgGlobal = BuildingConfig.Pieces[selectedType]
	local defUsed, defMax = computeLocalDefenseCapacity()
	local selectedDefCfg = Defenses.Get(selectedType)

	if defenseCapacityBadge then
		local showBadge = inBase or toolMode == "DefenseItem" or (buildActive and selectedDefCfg ~= nil)
		defenseCapacityBadge.Visible = showBadge
		defenseCapacityBadge.Text = string.format("Защита: %d / %d очков", defUsed, defMax)
		local wouldExceed = selectedDefCfg ~= nil and (defUsed + selectedDefCfg.CapacityCost) > defMax
		defenseCapacityBadge.BackgroundColor3 = if wouldExceed or defUsed >= defMax
			then Color3.fromRGB(155, 52, 52)
			elseif defUsed >= math.floor(defMax * 0.8) then Color3.fromRGB(165, 115, 40)
			else Color3.fromRGB(48, 95, 72)
	end

	for _, item in pieceButtons do
		local isSelected = (item.PieceType == selectedType)
		item.Button.BackgroundColor3 = if isSelected then COLOR_BTN_SELECTED else COLOR_BTN_DEFAULT
		item.Stroke.Color = if isSelected then COLOR_STROKE_SELECTED else COLOR_STROKE_DEFAULT
		item.Stroke.Thickness = if isSelected then 2 else 1.2
		local pieceCfg = BuildingConfig.Pieces[item.PieceType]
		if pieceCfg then
			item.CostLabel.TextColor3 = if canAffordPiece(item.PieceType, pieceCfg)
				then Color3.fromRGB(145, 225, 150)
				else Color3.fromRGB(235, 115, 115)
		end
	end

	if statusInfoLabel then
		if hammerActive then
			statusInfoLabel.Text = if #hammerStatusMessage > 0
				then hammerStatusMessage
				else "Hammer: LMB Upgrade/Repair | RMB Demolish"
			statusInfoLabel.TextColor3 = if hammerStatusValid
				then Color3.fromRGB(255, 215, 105)
				else Color3.fromRGB(235, 110, 110)
		else
			local selectedCfg = selectedCfgGlobal
			if selectedCfg then
				local affordable = canAffordPiece(selectedType, selectedCfg)
				local costText = if toolMode == "DefenseItem" and selectedDefCfg ~= nil
					then string.format("1x %s (+%d оч.)", selectedCfg.Name, selectedDefCfg.CapacityCost)
					elseif selectedDefCfg ~= nil then string.format(
						"%s (+%d оч.)",
						formatCostText(selectedCfg.Cost),
						selectedDefCfg.CapacityCost
					)
					else formatCostText(selectedCfg.Cost)
				if #previewStatusMessage > 0 and not previewPlaceable then
					statusInfoLabel.Text = string.format("%s | %s", selectedCfg.Name, previewStatusMessage)
					statusInfoLabel.TextColor3 = Color3.fromRGB(235, 110, 110)
				else
					statusInfoLabel.Text = string.format("%s | Cost: %s", selectedCfg.Name, costText)
					statusInfoLabel.TextColor3 = if affordable
						then Color3.fromRGB(140, 235, 145)
						else Color3.fromRGB(235, 110, 110)
				end
			end
		end
	end

	if rotButton then
		rotButton.Text = string.format("Rot: %d deg [R]", currentYawDeg)
	end
	local demolishActive = isDemolishSubModeActive()
	if upgradeToggleBtn then
		upgradeToggleBtn.BackgroundColor3 = if hammerActive and not demolishActive
			then COLOR_ACTION_ACTIVE
			else COLOR_ACTION_IDLE
	end
	if demolishToggleBtn then
		demolishToggleBtn.BackgroundColor3 = if demolishActive then COLOR_DEMOLISH_ACTIVE else COLOR_ACTION_IDLE
	end
end

local function raycastStructureUnderCursor(): (Model?, string?, BuildPieceType?, BuildTier?)
	local structuresFolder = getActiveStructuresFolder()
	local camera = Workspace.CurrentCamera
	if not structuresFolder or not camera then
		return nil, nil, nil, nil
	end

	local mouseLoc = UserInputService:GetMouseLocation()
	local unitRay = camera:ViewportPointToRay(mouseLoc.X, mouseLoc.Y)
	cachedHammerRayParams.FilterDescendantsInstances = { structuresFolder }

	local result = Workspace:Raycast(unitRay.Origin, unitRay.Direction * 120, cachedHammerRayParams)
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
	return current, uidAttr, BuildingGeometry.CanonicalPieceType(pieceTypeAttr), tierAttr :: BuildTier
end

local function getRemainingRaidBlockSeconds(hoveredModel: Model): number
	local serverTimeAttr = hoveredModel:GetAttribute("LastDamagedServerTime")
	if typeof(serverTimeAttr) == "number" and serverTimeAttr > 0 then
		return BuildingConfig.UpgradeRaidBlockSeconds - (Workspace:GetServerTimeNow() - serverTimeAttr)
	end
	local clockAttr = hoveredModel:GetAttribute("LastDamagedAt")
	if typeof(clockAttr) == "number" and clockAttr > 0 then
		return BuildingConfig.UpgradeRaidBlockSeconds - (os.clock() - clockAttr)
	end
	return 0
end

local function handleHammerAction(forceDemolish: boolean)
	local localPlayer = Players.LocalPlayer
	local character = if localPlayer then localPlayer.Character else nil
	local hrp = if character then character:FindFirstChild("HumanoidRootPart") else nil
	if not localPlayer or not hrp or not hrp:IsA("BasePart") then
		return
	end

	local hoveredModel, uid, pieceType, tier = raycastStructureUnderCursor()
	if not hoveredModel or uid == nil or pieceType == nil or tier == nil then
		return
	end
	if hoveredModel:GetAttribute("OwnerUserId") ~= localPlayer.UserId then
		return
	end
	if (hrp.Position - hoveredModel:GetPivot().Position).Magnitude > BuildingConfig.MaxBuildDistance then
		return
	end

	if forceDemolish or isDemolishSubModeActive() then
		Net.GetEvent(Net.Events.BuildDemolishRequest):FireServer(uid)
		return
	end

	local pieceCfg = BuildingConfig.Pieces[pieceType]
	if not pieceCfg or getRemainingRaidBlockSeconds(hoveredModel) > 0 then
		return
	end

	local hpAttr = hoveredModel:GetAttribute("Health") or hoveredModel:GetAttribute("Hp")
	local maxHpAttr = hoveredModel:GetAttribute("MaxHealth") or hoveredModel:GetAttribute("MaxHp")
	local hp = if typeof(hpAttr) == "number" then math.floor(hpAttr + 0.5) else 0
	local maxHp = if typeof(maxHpAttr) == "number" then math.floor(maxHpAttr + 0.5) else 1
	local nextTier = if pieceCfg.Upgradeable then BuildingConfig.GetNextTier(tier) else nil

	if hp < maxHp and (not pieceCfg.Upgradeable or nextTier == nil) then
		Net.GetEvent(Net.Events.BuildRepairRequest):FireServer(uid)
		return
	end

	if not pieceCfg.Upgradeable then
		return
	end

	local nextTierCfg = if nextTier ~= nil then BuildingConfig.Tiers[nextTier] else nil
	if
		nextTier == nil
		or nextTierCfg == nil
		or nextTierCfg.UpgradeCost == nil
		or not canAffordCost(nextTierCfg.UpgradeCost)
	then
		return
	end
	Net.GetEvent(Net.Events.BuildUpgradeRequest):FireServer(uid, nextTier)
end

local function handleBuildLeftClick()
	if not BuildingController.IsBuildMode() or isAnyModalUiOpen() then
		return
	end
	if isHammerModeActive() then
		handleHammerAction(false)
		return
	end
	if previewPlaceable and previewCFrame ~= nil then
		local selectedType = getSelectedPieceType()
		Net.GetEvent(Net.Events.BuildPlaceRequest)
			:FireServer(
				selectedType,
				previewCFrame,
				previewParentUid,
				previewSocketId,
				previewRotStep,
				previewMountSurface
			)
	end
end

local function updateHammerHover()
	if ghostModel then
		ghostModel.Parent = nil
	end
	previewCFrame = nil
	previewPlaceable = false

	local localPlayer = Players.LocalPlayer
	local character = if localPlayer then localPlayer.Character else nil
	local hrp = if character then character:FindFirstChild("HumanoidRootPart") else nil
	local hoveredModel, _, pieceType, tier = raycastStructureUnderCursor()

	if
		not hoveredModel
		or not targetHighlight
		or pieceType == nil
		or tier == nil
		or not localPlayer
		or not hrp
		or not hrp:IsA("BasePart")
	then
		clearTargetHighlight()
		hammerStatusMessage = "Hammer: LMB Upgrade | RMB Demolish"
		hammerStatusValid = true
		updateBuildUiVisuals()
		return
	end

	local isOwner = hoveredModel:GetAttribute("OwnerUserId") == localPlayer.UserId
	local inRange = (hrp.Position - hoveredModel:GetPivot().Position).Magnitude <= BuildingConfig.MaxBuildDistance
	local pieceCfg = BuildingConfig.Pieces[pieceType]
	local pieceName = if pieceCfg then pieceCfg.Name else pieceType
	local hpAttr = hoveredModel:GetAttribute("Health") or hoveredModel:GetAttribute("Hp")
	local maxHpAttr = hoveredModel:GetAttribute("MaxHealth") or hoveredModel:GetAttribute("MaxHp")
	local hp = if typeof(hpAttr) == "number" then math.max(0, math.floor(hpAttr + 0.5)) else 0
	local maxHp = if typeof(maxHpAttr) == "number" then math.max(1, math.floor(maxHpAttr + 0.5)) else 1

	targetHighlight.Adornee = hoveredModel
	targetHighlight.Enabled = true

	if not isOwner or not inRange then
		targetHighlight.OutlineColor = Color3.fromRGB(255, 75, 75)
		targetHighlight.FillColor = Color3.fromRGB(235, 65, 65)
		hammerStatusMessage = if not isOwner
			then string.format("%s | Not your structure", pieceName)
			else string.format("%s | Too far (>%d studs)", pieceName, BuildingConfig.MaxBuildDistance)
		hammerStatusValid = false
		updateBuildUiVisuals()
		return
	end

	if isDemolishSubModeActive() then
		targetHighlight.OutlineColor = Color3.fromRGB(255, 85, 85)
		targetHighlight.FillColor = Color3.fromRGB(235, 65, 65)
		hammerStatusMessage = string.format("Demolish: %s (%d/%d HP) [LMB/RMB]", pieceName, hp, maxHp)
		hammerStatusValid = true
		updateBuildUiVisuals()
		return
	end

	if not pieceCfg or not pieceCfg.Upgradeable then
		local raidBlockRemaining = getRemainingRaidBlockSeconds(hoveredModel)
		if hp < maxHp then
			if raidBlockRemaining > 0 then
				targetHighlight.OutlineColor = Color3.fromRGB(255, 75, 75)
				targetHighlight.FillColor = Color3.fromRGB(235, 65, 65)
				hammerStatusMessage = string.format(
					"%s (%d/%d HP) | Raid Blocked: %ds",
					pieceName,
					hp,
					maxHp,
					math.ceil(raidBlockRemaining)
				)
				hammerStatusValid = false
			else
				targetHighlight.OutlineColor = Color3.fromRGB(95, 235, 125)
				targetHighlight.FillColor = Color3.fromRGB(70, 200, 110)
				hammerStatusMessage =
					string.format("Repair: %s (%d/%d HP) [LMB Repair | RMB Remove]", pieceName, hp, maxHp)
				hammerStatusValid = true
			end
		else
			targetHighlight.OutlineColor = Color3.fromRGB(160, 160, 175)
			targetHighlight.FillColor = Color3.fromRGB(120, 120, 135)
			hammerStatusMessage = string.format("%s (%d/%d HP) | RMB Remove", pieceName, hp, maxHp)
			hammerStatusValid = true
		end
		updateBuildUiVisuals()
		return
	end

	local nextTier = BuildingConfig.GetNextTier(tier)
	if nextTier == nil then
		local raidBlockRemaining = getRemainingRaidBlockSeconds(hoveredModel)
		if hp < maxHp and raidBlockRemaining <= 0 then
			targetHighlight.OutlineColor = Color3.fromRGB(95, 235, 125)
			targetHighlight.FillColor = Color3.fromRGB(70, 200, 110)
			hammerStatusMessage = string.format("Repair: %s [Armored] (%d/%d HP) [LMB Repair]", pieceName, hp, maxHp)
			hammerStatusValid = true
		else
			targetHighlight.OutlineColor = Color3.fromRGB(85, 195, 255)
			targetHighlight.FillColor = Color3.fromRGB(70, 165, 235)
			hammerStatusMessage = string.format("%s [Armored] (%d/%d HP) | Max Tier", pieceName, hp, maxHp)
			hammerStatusValid = true
		end
		updateBuildUiVisuals()
		return
	end

	local raidBlockRemaining = getRemainingRaidBlockSeconds(hoveredModel)
	if raidBlockRemaining > 0 then
		targetHighlight.OutlineColor = Color3.fromRGB(255, 75, 75)
		targetHighlight.FillColor = Color3.fromRGB(235, 65, 65)
		hammerStatusMessage =
			string.format("%s (%d/%d HP) | Raid Blocked: %ds", pieceName, hp, maxHp, math.ceil(raidBlockRemaining))
		hammerStatusValid = false
		updateBuildUiVisuals()
		return
	end

	local currentTierCfg = BuildingConfig.Tiers[tier]
	local nextTierCfg = BuildingConfig.Tiers[nextTier]
	local costText = if nextTierCfg and nextTierCfg.UpgradeCost then formatCostText(nextTierCfg.UpgradeCost) else ""
	local affordable = if nextTierCfg and nextTierCfg.UpgradeCost then canAffordCost(nextTierCfg.UpgradeCost) else false

	targetHighlight.OutlineColor = if affordable then Color3.fromRGB(95, 235, 125) else Color3.fromRGB(255, 130, 65)
	targetHighlight.FillColor = if affordable then Color3.fromRGB(255, 195, 60) else Color3.fromRGB(220, 90, 50)
	hammerStatusMessage = string.format(
		"%s [%s -> %s] (%d/%d HP) | Cost: %s",
		pieceName,
		if currentTierCfg then currentTierCfg.Name else tier,
		if nextTierCfg then nextTierCfg.Name else nextTier,
		hp,
		maxHp,
		costText
	)
	hammerStatusValid = affordable
	updateBuildUiVisuals()
end

local function isTargetInRaidOutpostZone(pieceType: BuildPieceType, targetCF: CFrame): boolean
	local zoneParts: { BasePart } = {}
	local seen: { [BasePart]: boolean } = {}
	local function addZoneInst(inst: Instance?)
		if inst == nil then
			return
		end
		if inst:IsA("BasePart") then
			if not seen[inst] then
				seen[inst] = true
				table.insert(zoneParts, inst)
			end
		else
			for _, desc in inst:GetDescendants() do
				if desc:IsA("BasePart") and not seen[desc] then
					seen[desc] = true
					table.insert(zoneParts, desc)
				end
			end
		end
	end
	addZoneInst(Workspace:FindFirstChild("RaidOutpostZone"))
	for _, tagged in CollectionService:GetTagged("RaidOutpostZone") do
		addZoneInst(tagged)
	end
	if #zoneParts == 0 then
		return false
	end
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = zoneParts
	for _, box in BuildingGeometry.GetOverlapBoxes(pieceType, targetCF, 0.25) do
		local hits = Workspace:GetPartBoundsInBox(box.CFrame, box.Size, params)
		if #hits > 0 then
			return true
		end
	end
	return false
end

local function updatePreviewAndHighlight()
	if not BuildingController.IsBuildMode() or isAnyModalUiOpen() then
		previewCFrame = nil
		previewParentUid = nil
		previewSocketId = nil
		previewPlaceable = false
		if ghostModel then
			ghostModel.Parent = nil
		end
		clearTargetHighlight()
		return
	end

	if isHammerModeActive() then
		updateHammerHover()
		return
	end

	clearTargetHighlight()

	local localPlayer = Players.LocalPlayer
	local camera = Workspace.CurrentCamera
	local character = if localPlayer then localPlayer.Character else nil
	local hrp = if character then character:FindFirstChild("HumanoidRootPart") else nil
	if not localPlayer or not camera or not hrp or not hrp:IsA("BasePart") then
		previewCFrame = nil
		previewPlaceable = false
		if ghostModel then
			ghostModel.Parent = nil
		end
		return
	end

	local selectedType = getSelectedPieceType()
	local pieceCfg = BuildingConfig.Pieces[selectedType]
	if pieceCfg == nil then
		return
	end

	local mouseLoc = UserInputService:GetMouseLocation()
	local unitRay = camera:ViewportPointToRay(mouseLoc.X, mouseLoc.Y)

	local result = Workspace:Raycast(unitRay.Origin, unitRay.Direction * PLACE_RAY_DISTANCE, cachedPreviewRayParams)
	local aimPos = if result
		then result.Position
		else (unitRay.Origin + unitRay.Direction * BuildingConfig.MaxBuildDistance)

	local inRaid = isInRaidMode()
	local hitStructureModel: Model? = nil
	local structuresFolder = getActiveStructuresFolder()
	if result and structuresFolder and result.Instance:IsDescendantOf(structuresFolder) then
		local cur: Instance? = result.Instance
		while cur ~= nil and cur.Parent ~= structuresFolder do
			cur = cur.Parent
		end
		if cur and cur:IsA("Model") then
			hitStructureModel = cur
		end
	end

	local playerModels = collectPlayerStructureModels()
	local defCfg = Defenses.Get(selectedType)
	if pieceCfg.IsDefense == true and defCfg ~= nil then
		local targetCF = CFrame.new(aimPos) * CFrame.Angles(0, math.rad(currentYawDeg), 0)
		local mountSurface: DefenseMountSurface = if defCfg.AllowedMount == "WallOrCeiling" then "Wall" else "Floor"
		local hasValidTarget = true
		local reason = ""
		local overlapExcludes = table.clone(cachedPreviewExcludes)

		if inRaid then
			hasValidTarget = false
			reason = "Ловушки и турели запрещены в рейде"
		else
			local usedCap, maxCap = computeLocalDefenseCapacity()
			if (usedCap + defCfg.CapacityCost) > maxCap then
				hasValidTarget = false
				reason = string.format("Лимит защиты: %d/%d (+%d)", usedCap, maxCap, defCfg.CapacityCost)
			end
		end

		if defCfg.AllowedMount == "Floor" then
			mountSurface = "Floor"
			local groundResult = result
			if groundResult == nil then
				local downOrigin = Vector3.new(aimPos.X, aimPos.Y + 2.5, aimPos.Z)
				groundResult = Workspace:Raycast(downOrigin, Vector3.new(0, -5.5, 0), cachedPreviewRayParams)
			end
			if
				groundResult ~= nil
				and groundResult.Normal.Y >= 0.7
				and not BuildingGeometry.IsNoBuildInstance(groundResult.Instance, false)
			then
				targetCF = CFrame.new(groundResult.Position) * CFrame.Angles(0, math.rad(currentYawDeg), 0)
			else
				hasValidTarget = false
				if #reason == 0 then
					reason = "Требуется ровный пол или фундамент"
				end
			end
		else
			if
				result ~= nil
				and hitStructureModel ~= nil
				and hitStructureModel:GetAttribute("OwnerUserId") == localPlayer.UserId
			then
				local hostTypeAttr = hitStructureModel:GetAttribute("PieceType")
				local hostType = if typeof(hostTypeAttr) == "string"
					then BuildingGeometry.CanonicalPieceType(hostTypeAttr)
					else nil
				local hostCfg = if hostType ~= nil then BuildingConfig.Pieces[hostType] else nil
				if
					result.Normal.Y <= -0.7
					and hostCfg ~= nil
					and (hostCfg.Category == "Floor" or hostCfg.Category == "Foundation")
				then
					mountSurface = "Ceiling"
					targetCF = CFrame.new(result.Position) * CFrame.Angles(0, math.rad(currentYawDeg), 0)
					table.insert(overlapExcludes, hitStructureModel)
				elseif math.abs(result.Normal.Y) <= 0.35 and hostCfg ~= nil and hostCfg.Category == "Wall" then
					local horizNormal = Vector3.new(result.Normal.X, 0, result.Normal.Z)
					if horizNormal.Magnitude >= 0.05 then
						mountSurface = "Wall"
						targetCF = CFrame.lookAt(result.Position, result.Position + horizNormal.Unit)
						table.insert(overlapExcludes, hitStructureModel)
					else
						hasValidTarget = false
						if #reason == 0 then
							reason = "Наведите на свою стену или потолок"
						end
					end
				else
					hasValidTarget = false
					if #reason == 0 then
						reason =
							"Ловушка-дробовик крепится на стену или потолок"
					end
				end
			else
				hasValidTarget = false
				if #reason == 0 then
					reason = "Наведите на свою стену или потолок"
				end
			end
		end

		if hasValidTarget then
			if (hrp.Position - targetCF.Position).Magnitude > BuildingConfig.MaxBuildDistance then
				hasValidTarget = false
				reason = string.format("Too far (>%d studs)", BuildingConfig.MaxBuildDistance)
			elseif #savedPieces >= BuildingConfig.MaxPiecesPerBase then
				hasValidTarget = false
				reason = "Max pieces limit reached"
			elseif isTargetInRaidOutpostZone(selectedType, targetCF) then
				hasValidTarget = false
				reason = "Запрещено в RaidOutpostZone"
			elseif not canAffordPiece(selectedType, pieceCfg) then
				hasValidTarget = false
				reason = "Недостаточно ресурсов/предметов"
			else
				for _, existing in playerModels do
					local exTypeAttr = existing:GetAttribute("PieceType")
					if typeof(exTypeAttr) == "string" then
						local exCfg = BuildingConfig.Pieces[BuildingGeometry.CanonicalPieceType(exTypeAttr)]
						if exCfg ~= nil and exCfg.IsDefense == true then
							if (existing:GetPivot().Position - targetCF.Position).Magnitude < 2.0 then
								hasValidTarget = false
								reason = "Слишком близко к другой защите"
								break
							end
						end
					end
				end
				if hasValidTarget then
					local overlap = BuildingGeometry.CheckWorldOverlap(
						selectedType,
						targetCF,
						overlapExcludes,
						false,
						false,
						mountSurface
					)
					if not overlap.Allowed then
						hasValidTarget = false
						reason = overlap.Reason or "Blocked"
					end
				end
			end
		end

		local ghost = ensureGhostModel(selectedType, mountSurface)
		previewCFrame = targetCF
		previewParentUid = nil
		previewSocketId = nil
		previewRotStep = currentRotStep
		previewMountSurface = mountSurface
		previewPlaceable = hasValidTarget
		previewStatusMessage = reason

		ghost:PivotTo(targetCF)
		BuildingGeometry.SetGhostColor(ghost, if hasValidTarget then COLOR_GHOST_VALID_GRID else COLOR_GHOST_INVALID)
		ghost.Parent = Workspace
		updateBuildUiVisuals()
		return
	end

	previewMountSurface = nil
	local ghost = ensureGhostModel(selectedType, nil)
	local isFoundation = (pieceCfg.Category == "Foundation")
	local isAssaultDeployable = (pieceCfg.AssaultDeployable == true)
	local bestScore = if isFoundation then SOCKET_SEARCH_RADIUS_FOUNDATION else SOCKET_SEARCH_RADIUS_OTHER

	local bestCF: CFrame? = nil
	local bestParentUid: string? = nil
	local bestSocketId: string? = nil
	local bestSocketKind: Types.BuildSocketKind? = nil
	local bestParentType: BuildPieceType? = nil
	local bestParentCF: CFrame? = nil
	local bestRotStep = currentRotStep

	for _, parentModel in playerModels do
		local uidAttr = parentModel:GetAttribute("BuildUid")
		local typeAttr = parentModel:GetAttribute("PieceType")
		if typeof(uidAttr) == "string" and typeof(typeAttr) == "string" then
			local parentType = BuildingGeometry.CanonicalPieceType(typeAttr)
			local parentCF = parentModel:GetPivot()
			local hitBonus = if parentModel == hitStructureModel then 2.0 else 0

			for _, socket in BuildingGeometry.GetPieceSockets(parentType) do
				if BuildingGeometry.IsSocketCompatible(parentType, socket, selectedType) then
					local stepsToTry = if socket.Kind == "WallTop" and pieceCfg.Category == "Floor"
						then { 0, 1 }
						else { currentRotStep }
					for _, candStep in stepsToTry do
						if
							not isSocketOccupiedLocally(
								parentModel,
								parentType,
								parentCF,
								socket,
								selectedType,
								playerModels,
								candStep
							)
						then
							local candidateCF = BuildingGeometry.ComputeSnappedCFrame(
								parentType,
								parentCF,
								socket,
								selectedType,
								candStep
							)
							local sockPos = (parentCF * socket.LocalCFrame).Position
							local distToAim = if pieceCfg.Category == "Foundation"
									or pieceCfg.Category == "Floor"
								then (aimPos - candidateCF.Position).Magnitude * 0.65 + (aimPos - sockPos).Magnitude * 0.35
								else (aimPos - sockPos).Magnitude
							local score = distToAim - hitBonus
							if score < bestScore then
								bestScore = score
								bestCF = candidateCF
								bestParentUid = uidAttr
								bestSocketId = socket.Id
								bestSocketKind = socket.Kind
								bestParentType = parentType
								bestParentCF = parentCF
								bestRotStep = candStep
							end
						end
					end
				end
			end
		end
	end

	local targetCF: CFrame
	local parentUid: string? = nil
	local socketId: string? = nil
	local chosenRotStep = currentRotStep
	local hasValidTarget = true
	local reason = ""

	if bestCF ~= nil and bestParentUid ~= nil and bestSocketId ~= nil then
		targetCF = bestCF
		parentUid = bestParentUid
		socketId = bestSocketId
		chosenRotStep = bestRotStep

		if bestSocketKind == "Top" and bestParentType ~= nil and bestParentCF ~= nil then
			if not hasSupportingWallLocally(bestParentType, bestParentCF, playerModels) then
				hasValidTarget = false
				reason = "Requires supporting wall"
			end
		end

		local groundRefY = getLowestFoundationYLocally(playerModels, targetCF.Position.Y)
		local maxAllowedY = groundRefY + BuildingConfig.MaxBuildHeight * BuildingConfig.WallHeight + 2.0
		if hasValidTarget and targetCF.Position.Y > maxAllowedY then
			hasValidTarget = false
			reason = "Max build height reached"
		end
	elseif isFoundation or isAssaultDeployable then
		local groundResult = result
		if groundResult == nil or hitStructureModel ~= nil then
			local downOrigin = Vector3.new(aimPos.X, aimPos.Y + 4.0, aimPos.Z)
			groundResult = Workspace:Raycast(downOrigin, Vector3.new(0, -12.0, 0), cachedPreviewRayParams)
		end

		if
			groundResult ~= nil
			and groundResult.Normal.Y >= 0.65
			and not BuildingGeometry.IsNoBuildInstance(groundResult.Instance, inRaid)
		then
			if isAssaultDeployable then
				targetCF = CFrame.new(groundResult.Position) * CFrame.Angles(0, math.rad(currentYawDeg), 0)
			else
				local gridStep = BuildingConfig.GridSize
				local snapX = math.round(groundResult.Position.X / gridStep) * gridStep
				local snapZ = math.round(groundResult.Position.Z / gridStep) * gridStep
				targetCF = CFrame.new(snapX, groundResult.Position.Y, snapZ)
					* CFrame.Angles(0, math.rad(currentYawDeg), 0)
			end
		else
			targetCF = CFrame.new(aimPos.X, aimPos.Y, aimPos.Z) * CFrame.Angles(0, math.rad(currentYawDeg), 0)
			hasValidTarget = false
			reason = "Aim at flat ground or socket"
		end
	else
		targetCF = CFrame.new(aimPos) * CFrame.Angles(0, math.rad(currentYawDeg), 0)
		hasValidTarget = false
		reason = "Snap to valid socket"
	end

	if hasValidTarget then
		if inRaid and selectedType == "tool_cupboard" then
			hasValidTarget = false
			reason = "Tool Cupboard disabled in raid"
		elseif inRaid and not isAssaultDeployable and not isTargetInRaidOutpostZone(selectedType, targetCF) then
			hasValidTarget = false
			reason = "Outpost zone only (use ladder/barricade outside)"
		elseif (hrp.Position - targetCF.Position).Magnitude > BuildingConfig.MaxBuildDistance then
			hasValidTarget = false
			reason = string.format("Too far (>%d studs)", BuildingConfig.MaxBuildDistance)
		elseif not inRaid and #savedPieces >= BuildingConfig.MaxPiecesPerBase then
			hasValidTarget = false
			reason = "Max pieces limit reached"
		elseif not inRaid and pieceCfg.RequiredBaseTier ~= nil and getLocalBaseTier() < pieceCfg.RequiredBaseTier then
			hasValidTarget = false
			reason = string.format("Requires Base Tier %d", pieceCfg.RequiredBaseTier)
		elseif not canAffordCost(pieceCfg.Cost) then
			hasValidTarget = false
			reason = "Not enough resources"
		else
			if not inRaid and pieceCfg.MaxPerBase ~= nil then
				local existingCount = 0
				for _, p in savedPieces do
					if BuildingGeometry.CanonicalPieceType(p.PieceType) == selectedType then
						existingCount += 1
					end
				end
				if existingCount >= pieceCfg.MaxPerBase then
					hasValidTarget = false
					reason = string.format("Max %d %s per base", pieceCfg.MaxPerBase, pieceCfg.Name)
				end
			end
		end
		if hasValidTarget then
			local wallOk, wallReason = BuildingGeometry.CheckParallelWallStacking(
				selectedType,
				targetCF,
				buildLocalWallCandidates(playerModels)
			)
			if not wallOk then
				hasValidTarget = false
				reason = wallReason or "Anti-stacking: too close to wall"
			else
				local overlap = BuildingGeometry.CheckWorldOverlap(
					selectedType,
					targetCF,
					cachedPreviewExcludes,
					parentUid == nil,
					inRaid
				)
				if not overlap.Allowed then
					hasValidTarget = false
					reason = overlap.Reason or "Blocked"
				end
			end
		end
	end

	previewCFrame = targetCF
	previewParentUid = parentUid
	previewSocketId = socketId
	previewRotStep = chosenRotStep
	previewPlaceable = hasValidTarget
	previewStatusMessage = reason

	ghost:PivotTo(targetCF)
	local ghostColor = if not hasValidTarget
		then COLOR_GHOST_INVALID
		elseif socketId ~= nil then COLOR_GHOST_VALID_SOCKET
		else COLOR_GHOST_VALID_GRID
	BuildingGeometry.SetGhostColor(ghost, ghostColor)
	ghost.Parent = Workspace
	updateBuildUiVisuals()
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
	actionBar.Size = UDim2.fromOffset(700, 40)
	actionBar.BackgroundTransparency = 1
	actionBar.Visible = BuildingController.CanBuild()
	actionBar.Parent = screenGui

	local barLayout = Instance.new("UIListLayout")
	barLayout.FillDirection = Enum.FillDirection.Horizontal
	barLayout.HorizontalAlignment = Enum.HorizontalAlignment.Right
	barLayout.Padding = UDim.new(0, 8)
	barLayout.SortOrder = Enum.SortOrder.LayoutOrder
	barLayout.Parent = actionBar

	local defBadge = Instance.new("TextLabel")
	defBadge.Name = "DefenseCapacityBadge"
	defBadge.LayoutOrder = -1
	defBadge.Size = UDim2.fromOffset(162, 38)
	defBadge.BackgroundColor3 = Color3.fromRGB(48, 95, 72)
	defBadge.BorderSizePixel = 0
	defBadge.Font = Enum.Font.GothamBold
	defBadge.TextSize = 12
	defBadge.TextColor3 = Color3.new(1, 1, 1)
	defBadge.Text = "Защита: 0 / 60 очков"
	defBadge.Visible = BuildingController.IsBaseMode()
	defBadge.Parent = actionBar
	local defCorner = Instance.new("UICorner")
	defCorner.CornerRadius = UDim.new(0, 8)
	defCorner.Parent = defBadge

	local tierLbl = Instance.new("TextLabel")
	tierLbl.Name = "BaseTierBadge"
	tierLbl.LayoutOrder = 0
	tierLbl.Size = UDim2.fromOffset(102, 38)
	tierLbl.BackgroundColor3 = Color3.fromRGB(125, 52, 52)
	tierLbl.BorderSizePixel = 0
	tierLbl.Font = Enum.Font.GothamBold
	tierLbl.TextSize = 13
	tierLbl.TextColor3 = Color3.new(1, 1, 1)
	tierLbl.Text = "Base: Tier 0"
	tierLbl.Visible = BuildingController.IsBaseMode()
	tierLbl.Parent = actionBar
	local tierCorner = Instance.new("UICorner")
	tierCorner.CornerRadius = UDim.new(0, 8)
	tierCorner.Parent = tierLbl

	local function makeTopBtn(name: string, order: number, w: number, bg: Color3, text: string): TextButton
		local btn = Instance.new("TextButton")
		btn.Name = name
		btn.LayoutOrder = order
		btn.Size = UDim2.fromOffset(w, 38)
		btn.BackgroundColor3 = bg
		btn.BorderSizePixel = 0
		btn.Font = Enum.Font.GothamBold
		btn.TextSize = 13
		btn.TextColor3 = Color3.new(1, 1, 1)
		btn.Text = text
		btn.Parent = actionBar
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0, 8)
		c.Parent = btn
		return btn
	end

	local buildBtn = makeTopBtn("BuildToggleButton", 1, 114, Color3.fromRGB(55, 110, 165), "Build [B]")
	buildBtn.Activated:Connect(function()
		BuildingController.SetBuildMode(not BuildingController.IsBuildMode())
	end)

	local mapBtn = makeTopBtn("MapCycleButton", 2, 86, Color3.fromRGB(48, 86, 125), "Map: T1")
	mapBtn.Visible = BuildingController.IsBaseMode()
	mapBtn.Activated:Connect(function()
		local order = Config.MapOrder :: { string }
		selectedMapIndex = (selectedMapIndex % #order) + 1
		updateBuildUiVisuals()
	end)

	local deployBtn = makeTopBtn("DeployButton", 3, 156, Color3.fromRGB(55, 155, 85), "Deploy to PvP Map")
	deployBtn.Visible = BuildingController.IsBaseMode()
	deployBtn.Activated:Connect(function()
		if BuildingController.IsBaseMode() then
			Net.GetEvent(Net.Events.RequestReturnToMap):FireServer(getSelectedMapKey())
		end
	end)

	local toast = Instance.new("TextLabel")
	toast.Name = "BuildFeedbackToast"
	toast.AnchorPoint = Vector2.new(0.5, 0)
	toast.Position = UDim2.new(0.5, 0, 0, 20)
	toast.Size = UDim2.fromOffset(520, 36)
	toast.BackgroundColor3 = Color3.fromRGB(165, 45, 45)
	toast.BackgroundTransparency = 0.08
	toast.BorderSizePixel = 0
	toast.Font = Enum.Font.GothamBold
	toast.TextSize = 14
	toast.TextColor3 = Color3.new(1, 1, 1)
	toast.Text = ""
	toast.Visible = false
	toast.Parent = screenGui
	local toastCorner = Instance.new("UICorner")
	toastCorner.CornerRadius = UDim.new(0, 8)
	toastCorner.Parent = toast

	local menuFrame = Instance.new("Frame")
	menuFrame.Name = "BuildMenuFrame"
	menuFrame.AnchorPoint = Vector2.new(0.5, 1)
	menuFrame.Position = UDim2.new(0.5, 0, 1, -110)
	menuFrame.Size = UDim2.fromOffset(860, 200)
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

	local piecesGridFrame = Instance.new("Frame")
	piecesGridFrame.Name = "PiecesGrid"
	piecesGridFrame.Position = UDim2.fromOffset(10, 8)
	piecesGridFrame.Size = UDim2.new(1, -20, 0, 130)
	piecesGridFrame.BackgroundTransparency = 1
	piecesGridFrame.Parent = menuFrame

	local piecesGrid = Instance.new("UIGridLayout")
	piecesGrid.CellSize = UDim2.fromOffset(98, 40)
	piecesGrid.CellPadding = UDim2.fromOffset(6, 5)
	piecesGrid.HorizontalAlignment = Enum.HorizontalAlignment.Center
	piecesGrid.SortOrder = Enum.SortOrder.LayoutOrder
	piecesGrid.Parent = piecesGridFrame

	table.clear(pieceButtons)
	for index, pieceType in BuildingConfig.PieceOrder do
		local pieceCfg = BuildingConfig.Pieces[pieceType]
		local btn = Instance.new("TextButton")
		btn.Name = string.format("Piece_%s", pieceType)
		btn.LayoutOrder = index
		btn.BackgroundColor3 = COLOR_BTN_DEFAULT
		btn.BorderSizePixel = 0
		btn.Text = ""
		btn.Parent = piecesGridFrame
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
		nameLabel.Position = UDim2.fromOffset(4, 3)
		nameLabel.Size = UDim2.new(1, -8, 0, 18)
		nameLabel.BackgroundTransparency = 1
		nameLabel.Font = Enum.Font.GothamBold
		nameLabel.TextSize = 10
		nameLabel.TextTruncate = Enum.TextTruncate.AtEnd
		nameLabel.TextColor3 = Color3.fromRGB(240, 240, 246)
		local tierTag = if pieceCfg and pieceCfg.RequiredBaseTier ~= nil
			then string.format(" [T%d]", pieceCfg.RequiredBaseTier)
			else ""
		nameLabel.Text = (if pieceCfg then pieceCfg.Name else pieceType) .. tierTag
		nameLabel.Parent = btn

		local costLabel = Instance.new("TextLabel")
		costLabel.Name = "CostLabel"
		costLabel.Position = UDim2.fromOffset(4, 22)
		costLabel.Size = UDim2.new(1, -8, 0, 16)
		costLabel.BackgroundTransparency = 1
		costLabel.Font = Enum.Font.GothamMedium
		costLabel.TextSize = 10
		costLabel.TextTruncate = Enum.TextTruncate.AtEnd
		costLabel.TextColor3 = Color3.fromRGB(165, 215, 165)
		costLabel.Text = if pieceCfg then formatCostText(pieceCfg.Cost) else ""
		costLabel.Parent = btn

		btn.Activated:Connect(function()
			selectedPieceIndex = index
			upgradeModeToggle = false
			demolishModeToggle = false
			if toolMode == "Hammer" then
				toolMode = "None"
				manualBuildMode = true
			end
			updateBuildUiVisuals()
		end)

		table.insert(pieceButtons, { PieceType = pieceType, Button = btn, Stroke = btnStroke, CostLabel = costLabel })
	end

	local statusRow = Instance.new("Frame")
	statusRow.Name = "StatusRow"
	statusRow.Position = UDim2.fromOffset(10, 142)
	statusRow.Size = UDim2.new(1, -20, 0, 28)
	statusRow.BackgroundTransparency = 1
	statusRow.Parent = menuFrame

	local statusLabel = Instance.new("TextLabel")
	statusLabel.Name = "StatusInfo"
	statusLabel.Position = UDim2.fromOffset(2, 0)
	statusLabel.Size = UDim2.fromScale(0.50, 1)
	statusLabel.BackgroundTransparency = 1
	statusLabel.Font = Enum.Font.GothamBold
	statusLabel.TextSize = 12
	statusLabel.TextTruncate = Enum.TextTruncate.AtEnd
	statusLabel.TextColor3 = Color3.fromRGB(140, 235, 145)
	statusLabel.TextXAlignment = Enum.TextXAlignment.Left
	statusLabel.Text = ""
	statusLabel.Parent = statusRow

	local function makeActionBtn(name: string, xScale: number, w: number, text: string): TextButton
		local b = Instance.new("TextButton")
		b.Name = name
		b.Position = UDim2.new(xScale, 0, 0, 1)
		b.Size = UDim2.fromOffset(w, 26)
		b.BackgroundColor3 = COLOR_ACTION_IDLE
		b.BorderSizePixel = 0
		b.Font = Enum.Font.GothamBold
		b.TextSize = 11
		b.TextColor3 = Color3.new(1, 1, 1)
		b.Text = text
		b.Parent = statusRow
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0, 6)
		c.Parent = b
		return b
	end

	local rotBtn = makeActionBtn("RotateButton", 0.51, 112, "Rot: 0 deg [R]")
	rotBtn.Activated:Connect(function()
		currentRotStep = (currentRotStep + 1) % 12
		currentYawDeg = (currentYawDeg + 30) % 360
		updateBuildUiVisuals()
	end)

	local upgBtn = makeActionBtn("UpgradeButton", 0.68, 110, "Hammer [G]")
	upgBtn.Activated:Connect(function()
		upgradeModeToggle = not upgradeModeToggle
		if upgradeModeToggle then
			demolishModeToggle = false
		elseif toolMode == "Hammer" then
			toolMode = "None"
			manualBuildMode = true
		end
		updateBuildUiVisuals()
	end)

	local demBtn = makeActionBtn("DemolishButton", 0.85, 96, "Demolish")
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
	hintLabel.Text = "[Z/X] Piece | [R] Rotate | [G/Hammer] LMB Upgrade / RMB Demolish | [LMB] Place | [B] Exit"
	hintLabel.Parent = menuFrame

	local highlight = Instance.new("Highlight")
	highlight.Name = "BuildTargetHighlight"
	highlight.FillTransparency = 0.65
	highlight.OutlineTransparency = 0.05
	highlight.Enabled = false
	highlight.Parent = screenGui

	baseActionBar = actionBar
	baseTierBadge = tierLbl
	defenseCapacityBadge = defBadge
	mapCycleBtn = mapBtn
	buildToggleBtn = buildBtn
	deployToMapBtn = deployBtn
	feedbackToastLabel = toast
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
				and type(item.RotY) == "number"
				and type(item.Hp) == "number"
			then
				local parentUid = if type(item.ParentUid) == "string"
					then item.ParentUid
					elseif type(item.AnchorUid) == "string" then item.AnchorUid
					else nil
				table.insert(parsed, {
					Uid = item.Uid,
					PieceType = BuildingGeometry.CanonicalPieceType(item.PieceType),
					Tier = item.Tier :: BuildTier,
					PosX = if type(item.PosX) == "number" then item.PosX else 0,
					PosY = if type(item.PosY) == "number" then item.PosY else 0,
					PosZ = if type(item.PosZ) == "number" then item.PosZ else 0,
					RotY = item.RotY,
					ParentUid = parentUid,
					AnchorUid = parentUid,
					SocketId = if type(item.SocketId) == "string" then item.SocketId else nil,
					MountSurface = if item.MountSurface == "Floor"
							or item.MountSurface == "Wall"
							or item.MountSurface == "Ceiling"
						then item.MountSurface :: DefenseMountSurface
						else nil,
					Hp = item.Hp,
					LastDamagedAt = if type(item.LastDamagedAt) == "number" then item.LastDamagedAt else nil,
					Storage = if type(item.Storage) == "table" then item.Storage else nil,
				})
			end
		end
	end
	savedPieces = parsed
	updateBuildUiVisuals()
end

local function syncModeFromEquippedTool()
	if not BuildingController.CanBuild() then
		toolMode = "None"
		manualBuildMode = false
		upgradeModeToggle = false
		demolishModeToggle = false
		updateBuildUiVisuals()
		return
	end

	local selectedSlot = HotbarController.GetSelectedSlot()
	local equipped = InventoryController.GetSlot(selectedSlot)
	local itemId = if equipped ~= nil and equipped.Count > 0 then equipped.Id else ""

	if itemId == "building_plan" then
		toolMode = "Build"
		upgradeModeToggle = false
		demolishModeToggle = false
	elseif itemId == "hammer" then
		toolMode = "Hammer"
		upgradeModeToggle = true
		demolishModeToggle = false
	elseif Defenses.Get(itemId) ~= nil then
		toolMode = "DefenseItem"
		upgradeModeToggle = false
		demolishModeToggle = false
		local orderIdx = table.find(BuildingConfig.PieceOrder, BuildingGeometry.CanonicalPieceType(itemId))
		if orderIdx ~= nil then
			selectedPieceIndex = orderIdx
		end
	elseif toolMode ~= "None" then
		toolMode = "None"
		manualBuildMode = false
		upgradeModeToggle = false
		demolishModeToggle = false
	end

	if not BuildingController.IsBuildMode() then
		previewCFrame = nil
		previewPlaceable = false
		if ghostModel then
			ghostModel.Parent = nil
		end
		clearTargetHighlight()
	end
	updateBuildUiVisuals()
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

function BuildingController.CanBuild(): boolean
	return true
end

function BuildingController.IsBuildMode(): boolean
	return BuildingController.CanBuild() and (toolMode ~= "None" or manualBuildMode)
end

function BuildingController.SetBuildMode(enabled: boolean)
	if enabled and not BuildingController.CanBuild() then
		return
	end
	manualBuildMode = enabled
	if not enabled then
		toolMode = "None"
		upgradeModeToggle = false
		demolishModeToggle = false
		previewCFrame = nil
		previewParentUid = nil
		previewSocketId = nil
		previewPlaceable = false
		if ghostModel then
			ghostModel.Parent = nil
		end
		clearTargetHighlight()
	else
		if toolMode == "Hammer" then
			toolMode = "None"
		end
		upgradeModeToggle = false
		demolishModeToggle = false
	end
	updateBuildUiVisuals()
end

function BuildingController.GetPieces(): { SavedBuildPiece }
	return table.clone(savedPieces)
end

local function onBuildFeedback(payloadAny: any)
	if type(payloadAny) ~= "table" then
		return
	end
	local msg = payloadAny.Message
	if typeof(msg) ~= "string" or #msg == 0 then
		return
	end
	local success = payloadAny.Success == true
	if feedbackToastLabel then
		feedbackToken += 1
		local myToken = feedbackToken
		feedbackToastLabel.Text = msg
		feedbackToastLabel.BackgroundColor3 = if success
			then Color3.fromRGB(45, 135, 72)
			else Color3.fromRGB(165, 45, 45)
		feedbackToastLabel.Visible = true
		task.delay(3.5, function()
			if feedbackToken == myToken and feedbackToastLabel then
				feedbackToastLabel.Visible = false
			end
		end)
	end
	updateBuildUiVisuals()
end

function BuildingController.Init()
	if isInitialized then
		return
	end
	isInitialized = true

	createBuildingGui()
	refreshPreviewRaycastFilter()
	updateBuildUiVisuals()

	Net.GetEvent(Net.Events.BaseStateSync).OnClientEvent:Connect(onBaseStateSync)
	Net.GetEvent(Net.Events.BuildFeedback).OnClientEvent:Connect(onBuildFeedback)
	InventoryController.OnChanged(syncModeFromEquippedTool)
	HotbarController.SelectionChanged:Connect(syncModeFromEquippedTool)

	local localPlayer = Players.LocalPlayer
	if localPlayer ~= nil then
		localPlayer:GetAttributeChangedSignal("InRaid"):Connect(function()
			refreshPreviewRaycastFilter()
			syncModeFromEquippedTool()
		end)
		localPlayer:GetAttributeChangedSignal("BaseTier"):Connect(updateBuildUiVisuals)
		localPlayer.CharacterAdded:Connect(function()
			refreshPreviewRaycastFilter()
		end)
		localPlayer.CharacterRemoving:Connect(function()
			refreshPreviewRaycastFilter()
		end)
	end
	Workspace.ChildAdded:Connect(function(child: Instance)
		if child.Name == "RaidOutpostZone" then
			refreshPreviewRaycastFilter()
		end
	end)
	Workspace:GetAttributeChangedSignal("RaidServerMode"):Connect(function()
		refreshPreviewRaycastFilter()
		syncModeFromEquippedTool()
	end)
	if RunService:IsStudio() then
		Workspace:GetAttributeChangedSignal("ForceBaseMode"):Connect(updateBuildUiVisuals)
	end

	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessedEvent: boolean)
		if UserInputService:GetFocusedTextBox() ~= nil then
			return
		end
		if input.KeyCode == Enum.KeyCode.B and not gameProcessedEvent then
			if BuildingController.CanBuild() then
				BuildingController.SetBuildMode(not BuildingController.IsBuildMode())
			end
			return
		end
		if not BuildingController.IsBuildMode() then
			return
		end

		if input.KeyCode == Enum.KeyCode.R and not gameProcessedEvent then
			currentRotStep = (currentRotStep + 1) % 12
			currentYawDeg = (currentYawDeg + 30) % 360
			updateBuildUiVisuals()
		elseif (input.KeyCode == Enum.KeyCode.Z or input.KeyCode == Enum.KeyCode.X) and not gameProcessedEvent then
			local total = #BuildingConfig.PieceOrder
			local delta = if input.KeyCode == Enum.KeyCode.Z then -2 else 0
			selectedPieceIndex = ((selectedPieceIndex + delta) % total) + 1
			upgradeModeToggle = false
			demolishModeToggle = false
			if toolMode == "Hammer" then
				toolMode = "None"
				manualBuildMode = true
			end
			updateBuildUiVisuals()
		elseif input.KeyCode == Enum.KeyCode.G then
			updateBuildUiVisuals()
		elseif input.UserInputType == Enum.UserInputType.MouseButton1 and not gameProcessedEvent then
			handleBuildLeftClick()
		elseif
			input.UserInputType == Enum.UserInputType.MouseButton2
			and isHammerModeActive()
			and not isAnyModalUiOpen()
		then
			handleHammerAction(true)
		end
	end)

	UserInputService.InputEnded:Connect(function(input: InputObject)
		if input.KeyCode == Enum.KeyCode.G and BuildingController.IsBuildMode() then
			updateBuildUiVisuals()
		end
	end)

	RunService.RenderStepped:Connect(updatePreviewAndHighlight)
end

return BuildingController
