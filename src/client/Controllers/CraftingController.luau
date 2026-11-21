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
local InventoryController = require(script.Parent.InventoryController)
local InventoryUIController = require(script.Parent.InventoryUIController)
local LootController = require(script.Parent.LootController)

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
	IngredientRows: { IngredientRowUI },
	CraftButton: TextButton,
}

local COLOR_AFFORDABLE = Color3.fromRGB(110, 220, 120)
local COLOR_MISSING = Color3.fromRGB(235, 100, 100)
local COLOR_BTN_READY = Color3.fromRGB(58, 130, 75)
local COLOR_BTN_DISABLED = Color3.fromRGB(60, 60, 70)

local mainFrame: Frame? = nil
local activeCraftPanel: Frame? = nil
local statusLabel: TextLabel? = nil
local progressFill: Frame? = nil
local recipeCards: { RecipeCardUI } = {}
local activeCraft: CraftingState? = nil
local isOpen = false
local isInitialized = false

local CraftingController = {}

local function getSortedRecipes(): { RecipeConfig }
	local list: { RecipeConfig } = {}
	for _, recipe in Recipes do
		table.insert(list, recipe)
	end
	table.sort(list, function(a: RecipeConfig, b: RecipeConfig): boolean
		local aStation = if a.Station ~= nil then 1 else 0
		local bStation = if b.Station ~= nil then 1 else 0
		if aStation ~= bStation then
			return aStation < bStation
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

local function refreshRecipeCards()
	local inv = InventoryController.GetInventory()
	for _, cardUI in recipeCards do
		local canAffordAll = true
		for _, row in cardUI.IngredientRows do
			local owned = countItemInInventory(inv, row.Id)
			local itemCfg = Items[row.Id]
			local itemName = if itemCfg then itemCfg.Name else row.Id
			row.Label.Text = string.format("%s: %d / %d", itemName, owned, row.Required)
			if owned >= row.Required then
				row.Label.TextColor3 = COLOR_AFFORDABLE
			else
				row.Label.TextColor3 = COLOR_MISSING
				canAffordAll = false
			end
		end

		local canClick = canAffordAll and activeCraft == nil
		cardUI.CraftButton.BackgroundColor3 = if canClick then COLOR_BTN_READY else COLOR_BTN_DISABLED
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

local function buildRecipeCard(parent: Instance, recipe: RecipeConfig, layoutOrder: number)
	local resultItem = Items[recipe.ResultId]
	local resultName = if resultItem then resultItem.Name else recipe.ResultId

	local rowCount = #recipe.Ingredients
	local hasStation = recipe.Station ~= nil
	local cardHeight = 46 + rowCount * 16 + (if hasStation then 16 else 0)

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
	cardStroke.Color = Color3.fromRGB(70, 70, 82)
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
		Net.GetEvent(Net.Events.CraftRequest):FireServer(recipe.Id)
	end)

	local yOffset = 26
	if hasStation then
		local stationLabel = Instance.new("TextLabel")
		stationLabel.Name = "StationLabel"
		stationLabel.Position = UDim2.fromOffset(10, yOffset)
		stationLabel.Size = UDim2.new(1, -20, 0, 14)
		stationLabel.BackgroundTransparency = 1
		stationLabel.Font = Enum.Font.GothamMedium
		stationLabel.TextSize = 11
		stationLabel.TextColor3 = Color3.fromRGB(240, 195, 95)
		stationLabel.TextXAlignment = Enum.TextXAlignment.Left
		stationLabel.Text = if recipe.Station == "workbench_1"
			then "[Workbench Lv.1]"
			else string.format("[%s]", tostring(recipe.Station))
		stationLabel.Parent = card
		yOffset += 16
	end

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

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "CraftingGui"
	screenGui.ResetOnSpawn = false
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.DisplayOrder = 10

	local frame = Instance.new("Frame")
	frame.Name = "MainFrame"
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.new(0.5, 246, 0.48, 0)
	frame.Size = UDim2.fromOffset(320, 486)
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
	header.Size = UDim2.new(1, -56, 0, 28)
	header.BackgroundTransparency = 1
	header.Font = Enum.Font.GothamBold
	header.TextSize = 18
	header.TextColor3 = Color3.fromRGB(240, 240, 245)
	header.TextXAlignment = Enum.TextXAlignment.Left
	header.Text = "Crafting [C / Tab]"
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
		CraftingController.SetOpen(false)
	end)

	local list = Instance.new("ScrollingFrame")
	list.Name = "RecipeList"
	list.Position = UDim2.fromOffset(12, 46)
	list.Size = UDim2.new(1, -24, 1, -124)
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

	screenGui.Parent = playerGui
end

function CraftingController.IsOpen(): boolean
	return isOpen
end

function CraftingController.SetOpen(open: boolean)
	isOpen = open
	if mainFrame then
		mainFrame.Visible = open
	end
end

function CraftingController.Toggle()
	CraftingController.SetOpen(not isOpen)
end

function CraftingController.GetActiveCraft(): CraftingState?
	return activeCraft
end

function CraftingController.Init()
	if isInitialized then
		return
	end
	isInitialized = true

	createCraftingGui()

	InventoryController.OnChanged(function(_inv: Inventory)
		refreshRecipeCards()
	end)

	InventoryUIController.OpenChanged:Connect(function(open: boolean)
		if open and LootController.IsOpen() then
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
