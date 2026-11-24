--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Types = require(ReplicatedStorage.Shared.Types)
local Items = require(ReplicatedStorage.Shared.configs.Items)
local Recipes = require(ReplicatedStorage.Shared.configs.Recipes)
local Net = require(ReplicatedStorage.Shared.Net)
local Signal = require(ReplicatedStorage.Shared.Signal)
local InventoryController = require(script.Parent.InventoryController)
local InventoryUIController = require(script.Parent.InventoryUIController)
local LootController = require(script.Parent.LootController)
local BlueprintController = require(script.Parent.BlueprintController)

type Inventory = Types.Inventory
type RecipeConfig = Types.RecipeConfig
type CraftingState = Types.CraftingState

type IngredientRowUI = {
	Id: string,
	Required: number,
	Label: TextLabel,
}

type RecipeCardUI = {
	Recipe: RecipeConfig,
	Card: Frame,
	CardStroke: UIStroke,
	StationLabel: TextLabel,
	IngredientRows: { IngredientRowUI },
	CraftButton: TextButton,
}

type FilterDef = {
	Key: string,
	Label: string,
}

local FILTERS: { FilterDef } = table.freeze({
	table.freeze({ Key = "All", Label = "All" }),
	table.freeze({ Key = "Available", Label = "Avail" }),
	table.freeze({ Key = "T0", Label = "T0" }),
	table.freeze({ Key = "T1", Label = "T1" }),
	table.freeze({ Key = "T2", Label = "T2" }),
	table.freeze({ Key = "T3", Label = "T3" }),
})

local TIER_COLORS: { [number]: Color3 } = table.freeze({
	[1] = Color3.fromRGB(235, 170, 65),
	[2] = Color3.fromRGB(90, 175, 240),
	[3] = Color3.fromRGB(250, 205, 75),
})

local COLOR_AFFORDABLE = Color3.fromRGB(110, 220, 120)
local COLOR_MISSING = Color3.fromRGB(235, 100, 100)
local COLOR_BTN_READY = Color3.fromRGB(58, 130, 75)
local COLOR_BTN_DISABLED = Color3.fromRGB(60, 60, 70)
local COLOR_FILTER_ACTIVE = Color3.fromRGB(66, 128, 195)
local COLOR_FILTER_IDLE = Color3.fromRGB(40, 42, 50)
local COLOR_TIER_OK = Color3.fromRGB(130, 220, 145)
local COLOR_TIER_LOCKED = Color3.fromRGB(240, 140, 90)
local COLOR_STROKE_READY = Color3.fromRGB(90, 175, 105)
local COLOR_STROKE_IDLE = Color3.fromRGB(70, 70, 82)
local COLOR_STROKE_LOCKED = Color3.fromRGB(65, 50, 54)

local mainFrame: Frame? = nil
local activeCraftPanel: Frame? = nil
local statusLabel: TextLabel? = nil
local progressFill: Frame? = nil
local headerTierBadge: TextLabel? = nil
local hudBadgeFrame: Frame? = nil
local hudBadgeLabel: TextLabel? = nil
local hudBadgeAccent: Frame? = nil
local hudBadgeStroke: UIStroke? = nil
local filterButtons: { [string]: TextButton } = {}
local recipeCards: { RecipeCardUI } = {}
local activeCraft: CraftingState? = nil
local currentWorkbenchTier = 0
local nearCampfire = false
local activeFilter = "All"
local isOpen = false
local isInitialized = false
local openChangedSignal: Signal.Signal<boolean> = Signal.new()

local CraftingController = {
	OpenChanged = openChangedSignal,
}

local function getSortedRecipes(): { RecipeConfig }
	local list: { RecipeConfig } = {}
	for _, recipe in Recipes do
		table.insert(list, recipe)
	end
	table.sort(list, function(a: RecipeConfig, b: RecipeConfig): boolean
		if a.RequiredWorkbench ~= b.RequiredWorkbench then
			return a.RequiredWorkbench < b.RequiredWorkbench
		end
		return a.Id < b.Id
	end)
	return list
end

local function countItemInInventory(inv: Inventory, itemId: string): number
	local total = 0
	for i = 1, Types.INVENTORY_SIZE do
		local slot = inv[i]
		if slot ~= nil and slot.Id == itemId then
			total += slot.Count
		end
	end
	return total
end

local function matchesFilter(recipe: RecipeConfig, tierMet: boolean): boolean
	if activeFilter == "All" then
		return true
	elseif activeFilter == "Available" then
		return tierMet
	elseif activeFilter == "T0" then
		return recipe.RequiredWorkbench == 0
	elseif activeFilter == "T1" then
		return recipe.RequiredWorkbench == 1
	elseif activeFilter == "T2" then
		return recipe.RequiredWorkbench == 2
	elseif activeFilter == "T3" then
		return recipe.RequiredWorkbench == 3
	end
	return true
end

local function refreshFilterButtons()
	for key, btn in filterButtons do
		btn.BackgroundColor3 = if key == activeFilter then COLOR_FILTER_ACTIVE else COLOR_FILTER_IDLE
	end
end

local function refreshWorkbenchHud()
	if hudBadgeFrame and hudBadgeLabel and hudBadgeAccent and hudBadgeStroke then
		if currentWorkbenchTier >= 1 then
			local tierColor = TIER_COLORS[currentWorkbenchTier] or TIER_COLORS[1]
			hudBadgeLabel.Text = string.format("Workbench Level %d", currentWorkbenchTier)
			hudBadgeLabel.TextColor3 = tierColor
			hudBadgeAccent.BackgroundColor3 = tierColor
			hudBadgeStroke.Color = tierColor
			hudBadgeFrame.Visible = true
		else
			hudBadgeFrame.Visible = false
		end
	end

	if headerTierBadge then
		if currentWorkbenchTier >= 1 then
			local tierColor = TIER_COLORS[currentWorkbenchTier] or TIER_COLORS[1]
			headerTierBadge.Text = string.format("WB Lv.%d", currentWorkbenchTier)
			headerTierBadge.TextColor3 = tierColor
			headerTierBadge.BackgroundColor3 = Color3.fromRGB(36, 42, 52)
		else
			headerTierBadge.Text = "Hand"
			headerTierBadge.TextColor3 = Color3.fromRGB(185, 190, 200)
			headerTierBadge.BackgroundColor3 = Color3.fromRGB(38, 38, 46)
		end
	end
end

local function refreshRecipeCards()
	local inv = InventoryController.GetInventory()
	for _, cardUI in recipeCards do
		local recipe = cardUI.Recipe
		local stationMet = if recipe.RequiredWorkbench > 0
			then currentWorkbenchTier >= recipe.RequiredWorkbench
			elseif recipe.Station == "campfire" then nearCampfire
			else true
		local bpMet = BlueprintController.HasBlueprint(recipe.Id)
		cardUI.Card.Visible = matchesFilter(recipe, stationMet)

		local localPlayer = Players.LocalPlayer
		local isCreative = localPlayer ~= nil and localPlayer:GetAttribute("IsCreativeMode") == true
		local canAffordAll = true
		for _, row in cardUI.IngredientRows do
			local owned = countItemInInventory(inv, row.Id)
			local itemCfg = Items[row.Id]
			local itemName = if itemCfg then itemCfg.Name else row.Id
			row.Label.Text = string.format("%s: %d / %d", itemName, owned, row.Required)
			if isCreative or owned >= row.Required then
				row.Label.TextColor3 = COLOR_AFFORDABLE
			else
				row.Label.TextColor3 = COLOR_MISSING
				canAffordAll = false
			end
		end

		cardUI.StationLabel.TextColor3 = if stationMet and bpMet then COLOR_TIER_OK else COLOR_TIER_LOCKED
		if not bpMet then
			cardUI.CraftButton.Text = "Need BP"
			cardUI.CraftButton.BackgroundColor3 = COLOR_BTN_DISABLED
			cardUI.CardStroke.Color = COLOR_STROKE_LOCKED
		elseif not stationMet then
			cardUI.CraftButton.Text = if recipe.Station == "campfire"
				then "Campfire"
				else string.format("WB %d", recipe.RequiredWorkbench)
			cardUI.CraftButton.BackgroundColor3 = COLOR_BTN_DISABLED
			cardUI.CardStroke.Color = COLOR_STROKE_LOCKED
		else
			cardUI.CraftButton.Text = "Craft"
			local canClick = canAffordAll and activeCraft == nil
			cardUI.CraftButton.BackgroundColor3 = if canClick then COLOR_BTN_READY else COLOR_BTN_DISABLED
			cardUI.CardStroke.Color = if canAffordAll then COLOR_STROKE_READY else COLOR_STROKE_IDLE
		end
	end
end

local function refreshActiveCraftPanel()
	if not activeCraftPanel or not statusLabel or not progressFill then
		return
	end

	if activeCraft == nil then
		activeCraftPanel.Visible = false
		progressFill.Size = UDim2.fromScale(0, 1)
		return
	end

	local recipe = Recipes[activeCraft.RecipeId]
	local resultItem = if recipe then Items[recipe.ResultId] else nil
	local resultName = if resultItem then resultItem.Name else activeCraft.RecipeId

	local now = Workspace:GetServerTimeNow()
	local duration = math.max(0.01, activeCraft.EndTime - activeCraft.StartTime)
	local remaining = math.max(0, activeCraft.EndTime - now)
	local ratio = math.clamp((now - activeCraft.StartTime) / duration, 0, 1)

	statusLabel.Text = string.format("Crafting %s (%.1fs)", resultName, remaining)
	progressFill.Size = UDim2.fromScale(ratio, 1)
	activeCraftPanel.Visible = true
end

local function formatRequirementText(recipe: RecipeConfig): string
	local baseText: string
	if recipe.Station == "campfire" then
		baseText = "[Requires Campfire]"
	elseif recipe.RequiredWorkbench <= 0 then
		baseText = "[Hand Craft - Tier 0]"
	elseif recipe.RequiredWorkbench == 3 then
		baseText = "[Requires Workbench Lv.3]"
	else
		baseText = string.format("[Requires Workbench Lv.%d+]", recipe.RequiredWorkbench)
	end
	if recipe.RequiresBlueprint then
		return baseText .. " [BP]"
	end
	return baseText
end

local function buildRecipeCard(parent: Instance, recipe: RecipeConfig, layoutOrder: number)
	local resultItem = Items[recipe.ResultId]
	local resultName = if resultItem then resultItem.Name else recipe.ResultId

	local rowCount = #recipe.Ingredients
	local cardHeight = 46 + rowCount * 16 + 16

	local card = Instance.new("Frame")
	card.Name = recipe.Id
	card.LayoutOrder = layoutOrder
	card.Size = UDim2.new(1, -8, 0, cardHeight)
	card.BackgroundColor3 = Color3.fromRGB(32, 32, 38)
	card.BorderSizePixel = 0
	card.Parent = parent

	local cardCorner = Instance.new("UICorner")
	cardCorner.CornerRadius = UDim.new(0, 8)
	cardCorner.Parent = card

	local cardStroke = Instance.new("UIStroke")
	cardStroke.Color = COLOR_STROKE_IDLE
	cardStroke.Thickness = 1
	cardStroke.Parent = card

	local title = Instance.new("TextLabel")
	title.Name = "TitleLabel"
	title.Position = UDim2.fromOffset(10, 6)
	title.Size = UDim2.new(1, -88, 0, 18)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBold
	title.TextSize = 13
	title.TextColor3 = Color3.fromRGB(240, 240, 245)
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Text = string.format("%s x%d (%ds)", resultName, recipe.ResultCount, recipe.CraftTime)
	title.Parent = card

	local craftBtn = Instance.new("TextButton")
	craftBtn.Name = "CraftButton"
	craftBtn.AnchorPoint = Vector2.new(1, 0)
	craftBtn.Position = UDim2.new(1, -8, 0, 8)
	craftBtn.Size = UDim2.fromOffset(66, 26)
	craftBtn.BackgroundColor3 = COLOR_BTN_READY
	craftBtn.BorderSizePixel = 0
	craftBtn.Font = Enum.Font.GothamBold
	craftBtn.TextSize = 12
	craftBtn.TextColor3 = Color3.new(1, 1, 1)
	craftBtn.Text = "Craft"
	craftBtn.Parent = card

	local btnCorner = Instance.new("UICorner")
	btnCorner.CornerRadius = UDim.new(0, 6)
	btnCorner.Parent = craftBtn

	craftBtn.Activated:Connect(function()
		if not BlueprintController.HasBlueprint(recipe.Id) then
			return
		end
		if recipe.RequiredWorkbench > 0 and currentWorkbenchTier < recipe.RequiredWorkbench then
			return
		elseif recipe.Station == "campfire" and not nearCampfire then
			return
		end
		Net.GetEvent(Net.Events.CraftRequest):FireServer(recipe.Id)
	end)

	local stationLabel = Instance.new("TextLabel")
	stationLabel.Name = "StationLabel"
	stationLabel.Position = UDim2.fromOffset(10, 26)
	stationLabel.Size = UDim2.new(1, -88, 0, 14)
	stationLabel.BackgroundTransparency = 1
	stationLabel.Font = Enum.Font.GothamMedium
	stationLabel.TextSize = 11
	stationLabel.TextColor3 = COLOR_TIER_OK
	stationLabel.TextXAlignment = Enum.TextXAlignment.Left
	stationLabel.Text = formatRequirementText(recipe)
	stationLabel.Parent = card

	local yOffset = 42
	local ingredientRows: { IngredientRowUI } = {}
	for _, ing in recipe.Ingredients do
		local ingLabel = Instance.new("TextLabel")
		ingLabel.Name = string.format("Ing_%s", ing.Id)
		ingLabel.Position = UDim2.fromOffset(10, yOffset)
		ingLabel.Size = UDim2.new(1, -20, 0, 15)
		ingLabel.BackgroundTransparency = 1
		ingLabel.Font = Enum.Font.Gotham
		ingLabel.TextSize = 12
		ingLabel.TextColor3 = COLOR_MISSING
		ingLabel.TextXAlignment = Enum.TextXAlignment.Left
		ingLabel.Text = ""
		ingLabel.Parent = card

		table.insert(ingredientRows, {
			Id = ing.Id,
			Required = ing.Count,
			Label = ingLabel,
		})
		yOffset += 16
	end

	table.insert(recipeCards, {
		Recipe = recipe,
		Card = card,
		CardStroke = cardStroke,
		StationLabel = stationLabel,
		IngredientRows = ingredientRows,
		CraftButton = craftBtn,
	})
end

local function createCraftingGui()
	local localPlayer = Players.LocalPlayer
	if not localPlayer then
		return
	end
	local playerGui = localPlayer:WaitForChild("PlayerGui") :: PlayerGui

	local existing = playerGui:FindFirstChild("CraftingGui")
	if existing then
		existing:Destroy()
	end

	table.clear(recipeCards)
	table.clear(filterButtons)

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "CraftingGui"
	screenGui.ResetOnSpawn = false
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.DisplayOrder = 10

	-- Persistent Workbench Tier HUD Badge (above SurvivalHudGui bottom-left)
	local badge = Instance.new("Frame")
	badge.Name = "WorkbenchHudBadge"
	badge.AnchorPoint = Vector2.new(0, 1)
	badge.Position = UDim2.new(0, 16, 1, -120)
	badge.Size = UDim2.fromOffset(220, 30)
	badge.BackgroundColor3 = Color3.fromRGB(20, 22, 28)
	badge.BackgroundTransparency = 0.15
	badge.BorderSizePixel = 0
	badge.Visible = false
	badge.Parent = screenGui

	local badgeCorner = Instance.new("UICorner")
	badgeCorner.CornerRadius = UDim.new(0, 8)
	badgeCorner.Parent = badge

	local badgeStroke = Instance.new("UIStroke")
	badgeStroke.Color = TIER_COLORS[1]
	badgeStroke.Thickness = 1.5
	badgeStroke.Parent = badge

	local badgeAccent = Instance.new("Frame")
	badgeAccent.Name = "Accent"
	badgeAccent.Position = UDim2.fromOffset(6, 6)
	badgeAccent.Size = UDim2.fromOffset(5, 18)
	badgeAccent.BackgroundColor3 = TIER_COLORS[1]
	badgeAccent.BorderSizePixel = 0
	badgeAccent.Parent = badge

	local accentCorner = Instance.new("UICorner")
	accentCorner.CornerRadius = UDim.new(0, 3)
	accentCorner.Parent = badgeAccent

	local badgeLabel = Instance.new("TextLabel")
	badgeLabel.Name = "Label"
	badgeLabel.Position = UDim2.fromOffset(18, 0)
	badgeLabel.Size = UDim2.new(1, -24, 1, 0)
	badgeLabel.BackgroundTransparency = 1
	badgeLabel.Font = Enum.Font.GothamBold
	badgeLabel.TextSize = 13
	badgeLabel.TextColor3 = TIER_COLORS[1]
	badgeLabel.TextXAlignment = Enum.TextXAlignment.Left
	badgeLabel.Text = "Workbench Level 1"
	badgeLabel.Parent = badge

	local frame = Instance.new("Frame")
	frame.Name = "MainFrame"
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.new(0.5, 254, 0.48, 0)
	frame.Size = UDim2.fromOffset(336, 512)
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
	header.Position = UDim2.fromOffset(14, 10)
	header.Size = UDim2.new(1, -132, 0, 26)
	header.BackgroundTransparency = 1
	header.Font = Enum.Font.GothamBold
	header.TextSize = 17
	header.TextColor3 = Color3.fromRGB(240, 240, 245)
	header.TextXAlignment = Enum.TextXAlignment.Left
	header.Text = "Crafting [C / Tab]"
	header.Parent = frame

	local tierBadge = Instance.new("TextLabel")
	tierBadge.Name = "HeaderTierBadge"
	tierBadge.AnchorPoint = Vector2.new(1, 0)
	tierBadge.Position = UDim2.new(1, -46, 0, 12)
	tierBadge.Size = UDim2.fromOffset(66, 22)
	tierBadge.BackgroundColor3 = Color3.fromRGB(38, 38, 46)
	tierBadge.BorderSizePixel = 0
	tierBadge.Font = Enum.Font.GothamBold
	tierBadge.TextSize = 11
	tierBadge.TextColor3 = Color3.fromRGB(185, 190, 200)
	tierBadge.Text = "Hand"
	tierBadge.Parent = frame

	local tierBadgeCorner = Instance.new("UICorner")
	tierBadgeCorner.CornerRadius = UDim.new(0, 6)
	tierBadgeCorner.Parent = tierBadge

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
		CraftingController.SetOpen(false)
	end)

	local filterBar = Instance.new("Frame")
	filterBar.Name = "FilterBar"
	filterBar.Position = UDim2.fromOffset(12, 42)
	filterBar.Size = UDim2.new(1, -24, 0, 24)
	filterBar.BackgroundTransparency = 1
	filterBar.Parent = frame

	local filterLayout = Instance.new("UIListLayout")
	filterLayout.FillDirection = Enum.FillDirection.Horizontal
	filterLayout.Padding = UDim.new(0, 4)
	filterLayout.SortOrder = Enum.SortOrder.LayoutOrder
	filterLayout.Parent = filterBar

	for idx, def in FILTERS do
		local fBtn = Instance.new("TextButton")
		fBtn.Name = string.format("Filter_%s", def.Key)
		fBtn.LayoutOrder = idx
		fBtn.Size = UDim2.new(0, if idx <= 2 then 56 else 45, 1, 0)
		fBtn.BackgroundColor3 = if def.Key == activeFilter then COLOR_FILTER_ACTIVE else COLOR_FILTER_IDLE
		fBtn.BorderSizePixel = 0
		fBtn.Font = Enum.Font.GothamBold
		fBtn.TextSize = 11
		fBtn.TextColor3 = Color3.fromRGB(240, 242, 248)
		fBtn.Text = def.Label
		fBtn.Parent = filterBar

		local fCorner = Instance.new("UICorner")
		fCorner.CornerRadius = UDim.new(0, 5)
		fCorner.Parent = fBtn

		fBtn.Activated:Connect(function()
			activeFilter = def.Key
			refreshFilterButtons()
			refreshRecipeCards()
		end)

		filterButtons[def.Key] = fBtn
	end

	local list = Instance.new("ScrollingFrame")
	list.Name = "RecipeList"
	list.Position = UDim2.fromOffset(12, 74)
	list.Size = UDim2.new(1, -24, 1, -152)
	list.BackgroundTransparency = 1
	list.BorderSizePixel = 0
	list.ScrollBarThickness = 6
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.CanvasSize = UDim2.fromOffset(0, 0)
	list.Parent = frame

	local listLayout = Instance.new("UIListLayout")
	listLayout.Padding = UDim.new(0, 8)
	listLayout.SortOrder = Enum.SortOrder.LayoutOrder
	listLayout.Parent = list

	for idx, recipe in ipairs(getSortedRecipes()) do
		buildRecipeCard(list, recipe, idx)
	end

	local panel = Instance.new("Frame")
	panel.Name = "ActiveCraftPanel"
	panel.AnchorPoint = Vector2.new(0, 1)
	panel.Position = UDim2.new(0, 12, 1, -12)
	panel.Size = UDim2.new(1, -24, 0, 58)
	panel.BackgroundColor3 = Color3.fromRGB(30, 30, 36)
	panel.BorderSizePixel = 0
	panel.Visible = false
	panel.Parent = frame

	local panelCorner = Instance.new("UICorner")
	panelCorner.CornerRadius = UDim.new(0, 8)
	panelCorner.Parent = panel

	local sLabel = Instance.new("TextLabel")
	sLabel.Name = "StatusLabel"
	sLabel.Position = UDim2.fromOffset(10, 6)
	sLabel.Size = UDim2.new(1, -84, 0, 18)
	sLabel.BackgroundTransparency = 1
	sLabel.Font = Enum.Font.GothamBold
	sLabel.TextSize = 12
	sLabel.TextColor3 = Color3.fromRGB(240, 240, 245)
	sLabel.TextXAlignment = Enum.TextXAlignment.Left
	sLabel.Text = ""
	sLabel.Parent = panel

	local cancelBtn = Instance.new("TextButton")
	cancelBtn.Name = "CancelButton"
	cancelBtn.AnchorPoint = Vector2.new(1, 0)
	cancelBtn.Position = UDim2.new(1, -8, 0, 6)
	cancelBtn.Size = UDim2.fromOffset(64, 22)
	cancelBtn.BackgroundColor3 = Color3.fromRGB(165, 60, 60)
	cancelBtn.BorderSizePixel = 0
	cancelBtn.Font = Enum.Font.GothamBold
	cancelBtn.TextSize = 11
	cancelBtn.TextColor3 = Color3.new(1, 1, 1)
	cancelBtn.Text = "Cancel"
	cancelBtn.Parent = panel

	local cancelCorner = Instance.new("UICorner")
	cancelCorner.CornerRadius = UDim.new(0, 5)
	cancelCorner.Parent = cancelBtn

	cancelBtn.Activated:Connect(function()
		Net.GetEvent(Net.Events.CraftCancel):FireServer()
	end)

	local barBg = Instance.new("Frame")
	barBg.Name = "BarBackground"
	barBg.Position = UDim2.fromOffset(10, 34)
	barBg.Size = UDim2.new(1, -20, 0, 12)
	barBg.BackgroundColor3 = Color3.fromRGB(48, 48, 58)
	barBg.BorderSizePixel = 0
	barBg.Parent = panel

	local barCorner = Instance.new("UICorner")
	barCorner.CornerRadius = UDim.new(0, 4)
	barCorner.Parent = barBg

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(0, 1)
	fill.BackgroundColor3 = Color3.fromRGB(95, 195, 115)
	fill.BorderSizePixel = 0
	fill.Parent = barBg

	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(0, 4)
	fillCorner.Parent = fill

	mainFrame = frame
	activeCraftPanel = panel
	statusLabel = sLabel
	progressFill = fill
	headerTierBadge = tierBadge
	hudBadgeFrame = badge
	hudBadgeLabel = badgeLabel
	hudBadgeAccent = badgeAccent
	hudBadgeStroke = badgeStroke

	screenGui.Parent = playerGui
end

function CraftingController.IsOpen(): boolean
	return isOpen
end

function CraftingController.SetOpen(open: boolean)
	local changed = isOpen ~= open
	isOpen = open
	if mainFrame then
		mainFrame.Visible = open
	end
	if changed then
		openChangedSignal:Fire(open)
	end
end

function CraftingController.Toggle()
	CraftingController.SetOpen(not isOpen)
end

function CraftingController.GetActiveCraft(): CraftingState?
	return activeCraft
end

function CraftingController.GetWorkbenchTier(): number
	return currentWorkbenchTier
end

local function updateWorkbenchTierFromPlayer(localPlayer: Player)
	local attr = localPlayer:GetAttribute("WorkbenchTier")
	local nextTier = if typeof(attr) == "number" then math.clamp(math.floor(attr), 0, 3) else 0
	if nextTier ~= currentWorkbenchTier then
		currentWorkbenchTier = nextTier
		refreshWorkbenchHud()
		refreshRecipeCards()
	end
end

local function updateCampfireFromPlayer(localPlayer: Player)
	local nextNear = localPlayer:GetAttribute("NearCampfire") == true
	if nextNear ~= nearCampfire then
		nearCampfire = nextNear
		refreshRecipeCards()
	end
end

function CraftingController.Init()
	if isInitialized then
		return
	end
	isInitialized = true

	createCraftingGui()

	local localPlayer = Players.LocalPlayer
	if localPlayer then
		updateWorkbenchTierFromPlayer(localPlayer)
		updateCampfireFromPlayer(localPlayer)
		refreshWorkbenchHud()
		refreshRecipeCards()

		localPlayer:GetAttributeChangedSignal("WorkbenchTier"):Connect(function()
			updateWorkbenchTierFromPlayer(localPlayer)
		end)

		localPlayer:GetAttributeChangedSignal("NearCampfire"):Connect(function()
			updateCampfireFromPlayer(localPlayer)
		end)

		localPlayer:GetAttributeChangedSignal("IsCreativeMode"):Connect(function()
			refreshRecipeCards()
		end)
	end

	InventoryController.OnChanged(function(_inv: Inventory)
		refreshRecipeCards()
	end)

	BlueprintController.Changed:Connect(function()
		refreshRecipeCards()
	end)

	InventoryUIController.OpenChanged:Connect(function(open: boolean)
		if open and (LootController.IsOpen() or InventoryUIController.HasActiveInterceptor()) then
			CraftingController.SetOpen(false)
			return
		end
		CraftingController.SetOpen(open)
	end)

	LootController.OpenChanged:Connect(function(open: boolean)
		if open then
			CraftingController.SetOpen(false)
		end
	end)

	local stateSyncEvent = Net.GetEvent(Net.Events.CraftStateSync)
	stateSyncEvent.OnClientEvent:Connect(function(state: any)
		if
			type(state) == "table"
			and type(state.RecipeId) == "string"
			and type(state.StartTime) == "number"
			and type(state.EndTime) == "number"
		then
			activeCraft = {
				RecipeId = state.RecipeId,
				StartTime = state.StartTime,
				EndTime = state.EndTime,
			}
		else
			activeCraft = nil
		end
		refreshRecipeCards()
		refreshActiveCraftPanel()
	end)

	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessedEvent: boolean)
		if UserInputService:GetFocusedTextBox() ~= nil or gameProcessedEvent then
			return
		end

		if input.KeyCode == Enum.KeyCode.C then
			CraftingController.Toggle()
		end
	end)

	RunService.RenderStepped:Connect(function()
		if activeCraft ~= nil then
			refreshActiveCraftPanel()
		end
	end)
end

return CraftingController
