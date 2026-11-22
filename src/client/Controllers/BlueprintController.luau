--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Config = require(ReplicatedStorage.Shared.Config)
local Types = require(ReplicatedStorage.Shared.Types)
local Signal = require(ReplicatedStorage.Shared.Signal)
local Items = require(ReplicatedStorage.Shared.configs.Items)
local Recipes = require(ReplicatedStorage.Shared.configs.Recipes)
local Net = require(ReplicatedStorage.Shared.Net)
local InventoryController = require(script.Parent.InventoryController)
local InventoryUIController = require(script.Parent.InventoryUIController)
local LootController = require(script.Parent.LootController)

type Inventory = Types.Inventory
type RecipeConfig = Types.RecipeConfig
type ResearchTableState = Types.ResearchTableState

local INTERCEPTOR_ID = "ResearchTable"
local COLOR_OK = Color3.fromRGB(48, 150, 88)
local COLOR_ERR = Color3.fromRGB(165, 60, 60)
local COLOR_BTN_READY = Color3.fromRGB(52, 130, 215)
local COLOR_BTN_DISABLED = Color3.fromRGB(64, 66, 76)

local recipeByResultId: { [string]: RecipeConfig } = {}
for _, recipe in Recipes do
	recipeByResultId[recipe.ResultId] = recipe
end

local unlockedBlueprints: { [string]: boolean } = {}
local activeTable: ResearchTableState? = nil
local selectedSlotIndex: number? = nil
local isOpen = false
local isInitialized = false
local changedSignal: Signal.Signal<{ [string]: boolean }> = Signal.new()

local mainFrame: Frame? = nil
local itemNameLabel: TextLabel? = nil
local recipeInfoLabel: TextLabel? = nil
local costLabel: TextLabel? = nil
local researchButton: TextButton? = nil
local feedbackLabel: TextLabel? = nil
local toastFrame: Frame? = nil
local toastLabel: TextLabel? = nil
local toastExpireAt = 0

local BlueprintController = {
	Changed = changedSignal,
}

local function countScrap(): number
	local inv = InventoryController.GetInventory()
	local total = 0
	for i = 1, Types.INVENTORY_SIZE do
		local slot = inv[i]
		if slot ~= nil and slot.Id == "scrap" and slot.Count > 0 then
			total += slot.Count
		end
	end
	return total
end

local function showToast(success: boolean, message: string)
	if toastFrame and toastLabel then
		toastFrame.BackgroundColor3 = if success then COLOR_OK else COLOR_ERR
		toastLabel.Text = message
		toastFrame.Visible = true
		toastExpireAt = os.clock() + 3.2
	end
	if feedbackLabel then
		feedbackLabel.Text = message
		feedbackLabel.TextColor3 = if success then Color3.fromRGB(130, 235, 155) else Color3.fromRGB(245, 120, 120)
	end
end

local function refreshResearchUi()
	if not itemNameLabel or not recipeInfoLabel or not costLabel or not researchButton then
		return
	end

	local scrapOwned = countScrap()
	if selectedSlotIndex == nil then
		itemNameLabel.Text = "No item selected"
		recipeInfoLabel.Text = "Click a Tier 1-3 item in your inventory on the left."
		costLabel.Text = string.format("Your Scrap: %d", scrapOwned)
		costLabel.TextColor3 = Color3.fromRGB(205, 210, 220)
		researchButton.Text = "Select Item"
		researchButton.BackgroundColor3 = COLOR_BTN_DISABLED
		return
	end

	local slot = InventoryController.GetSlot(selectedSlotIndex)
	if slot == nil or slot.Count <= 0 then
		selectedSlotIndex = nil
		refreshResearchUi()
		return
	end

	local itemCfg = Items[slot.Id]
	local itemName = if itemCfg then itemCfg.Name else slot.Id
	itemNameLabel.Text = string.format("Slot %d: %s", selectedSlotIndex, itemName)

	if itemCfg ~= nil and itemCfg.Type == "Blueprint" then
		recipeInfoLabel.Text = "Physical Blueprint scroll (use directly from Inventory)"
		costLabel.Text = "No Research Table needed"
		costLabel.TextColor3 = Color3.fromRGB(145, 200, 255)
		researchButton.Text = "Learn in Inv"
		researchButton.BackgroundColor3 = COLOR_BTN_DISABLED
		return
	end

	local recipe = recipeByResultId[slot.Id]
	if recipe == nil or not recipe.RequiresBlueprint then
		recipeInfoLabel.Text = "This item does not require a blueprint."
		costLabel.Text = string.format("Your Scrap: %d", scrapOwned)
		costLabel.TextColor3 = Color3.fromRGB(185, 185, 195)
		researchButton.Text = "Not Researchable"
		researchButton.BackgroundColor3 = COLOR_BTN_DISABLED
		return
	end

	if unlockedBlueprints[recipe.Id] == true then
		recipeInfoLabel.Text = string.format("Workbench Lv.%d recipe already unlocked!", recipe.RequiredWorkbench)
		costLabel.Text = "Status: LEARNED"
		costLabel.TextColor3 = Color3.fromRGB(130, 235, 155)
		researchButton.Text = "Already Learned"
		researchButton.BackgroundColor3 = COLOR_BTN_DISABLED
		return
	end

	local cost = math.max(0, recipe.ResearchCost)
	local canAfford = scrapOwned >= cost
	recipeInfoLabel.Text = string.format("Unlocks %s (WB Lv.%d) - consumes 1x item", itemName, recipe.RequiredWorkbench)
	costLabel.Text = string.format("Cost: %d Scrap (You have %d)", cost, scrapOwned)
	costLabel.TextColor3 = if canAfford then Color3.fromRGB(145, 230, 155) else Color3.fromRGB(245, 125, 125)
	researchButton.Text = string.format("Research (%d Scrap)", cost)
	researchButton.BackgroundColor3 = if canAfford then COLOR_BTN_READY else COLOR_BTN_DISABLED
end

local function createResearchGui()
	local localPlayer = Players.LocalPlayer
	if not localPlayer then
		return
	end
	local playerGui = localPlayer:WaitForChild("PlayerGui") :: PlayerGui

	local existing = playerGui:FindFirstChild("ResearchGui")
	if existing then
		existing:Destroy()
	end

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "ResearchGui"
	screenGui.ResetOnSpawn = false
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.DisplayOrder = 11

	local frame = Instance.new("Frame")
	frame.Name = "MainFrame"
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.new(0.5, 260, 0.48, 0)
	frame.Size = UDim2.fromOffset(350, 310)
	frame.BackgroundColor3 = Color3.fromRGB(20, 22, 28)
	frame.BackgroundTransparency = 0.06
	frame.BorderSizePixel = 0
	frame.Visible = false
	frame.Parent = screenGui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 12)
	corner.Parent = frame

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(70, 130, 210)
	stroke.Thickness = 1.5
	stroke.Parent = frame

	local header = Instance.new("TextLabel")
	header.Position = UDim2.fromOffset(16, 12)
	header.Size = UDim2.new(1, -60, 0, 26)
	header.BackgroundTransparency = 1
	header.Font = Enum.Font.GothamBold
	header.TextSize = 18
	header.TextColor3 = Color3.fromRGB(240, 244, 250)
	header.TextXAlignment = Enum.TextXAlignment.Left
	header.Text = "Research Table"
	header.Parent = frame

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
		BlueprintController.SetOpen(false)
	end)

	local card = Instance.new("Frame")
	card.Position = UDim2.fromOffset(16, 52)
	card.Size = UDim2.new(1, -32, 0, 132)
	card.BackgroundColor3 = Color3.fromRGB(30, 34, 42)
	card.BorderSizePixel = 0
	card.Parent = frame

	local cardCorner = Instance.new("UICorner")
	cardCorner.CornerRadius = UDim.new(0, 8)
	cardCorner.Parent = card

	local nameLbl = Instance.new("TextLabel")
	nameLbl.Position = UDim2.fromOffset(12, 10)
	nameLbl.Size = UDim2.new(1, -24, 0, 24)
	nameLbl.BackgroundTransparency = 1
	nameLbl.Font = Enum.Font.GothamBold
	nameLbl.TextSize = 15
	nameLbl.TextColor3 = Color3.fromRGB(245, 245, 250)
	nameLbl.TextXAlignment = Enum.TextXAlignment.Left
	nameLbl.Text = "No item selected"
	nameLbl.Parent = card

	local infoLbl = Instance.new("TextLabel")
	infoLbl.Position = UDim2.fromOffset(12, 38)
	infoLbl.Size = UDim2.new(1, -24, 0, 44)
	infoLbl.BackgroundTransparency = 1
	infoLbl.Font = Enum.Font.Gotham
	infoLbl.TextSize = 12
	infoLbl.TextWrapped = true
	infoLbl.TextColor3 = Color3.fromRGB(190, 198, 212)
	infoLbl.TextXAlignment = Enum.TextXAlignment.Left
	infoLbl.TextYAlignment = Enum.TextYAlignment.Top
	infoLbl.Text = ""
	infoLbl.Parent = card

	local cLbl = Instance.new("TextLabel")
	cLbl.Position = UDim2.fromOffset(12, 92)
	cLbl.Size = UDim2.new(1, -24, 0, 24)
	cLbl.BackgroundTransparency = 1
	cLbl.Font = Enum.Font.GothamBold
	cLbl.TextSize = 13
	cLbl.TextColor3 = Color3.fromRGB(235, 200, 95)
	cLbl.TextXAlignment = Enum.TextXAlignment.Left
	cLbl.Text = ""
	cLbl.Parent = card

	local rBtn = Instance.new("TextButton")
	rBtn.Position = UDim2.fromOffset(16, 198)
	rBtn.Size = UDim2.new(1, -32, 0, 42)
	rBtn.BackgroundColor3 = COLOR_BTN_DISABLED
	rBtn.BorderSizePixel = 0
	rBtn.Font = Enum.Font.GothamBold
	rBtn.TextSize = 15
	rBtn.TextColor3 = Color3.new(1, 1, 1)
	rBtn.Text = "Select Item"
	rBtn.Parent = frame

	local rCorner = Instance.new("UICorner")
	rCorner.CornerRadius = UDim.new(0, 8)
	rCorner.Parent = rBtn

	rBtn.Activated:Connect(function()
		if activeTable ~= nil and selectedSlotIndex ~= nil then
			Net.GetEvent(Net.Events.ResearchItemRequest):FireServer(activeTable.TableId, selectedSlotIndex)
		end
	end)

	local fLbl = Instance.new("TextLabel")
	fLbl.Position = UDim2.fromOffset(16, 252)
	fLbl.Size = UDim2.new(1, -32, 0, 42)
	fLbl.BackgroundTransparency = 1
	fLbl.Font = Enum.Font.GothamMedium
	fLbl.TextSize = 12
	fLbl.TextWrapped = true
	fLbl.TextColor3 = Color3.fromRGB(165, 175, 190)
	fLbl.Text = "Tip: Click any item in your inventory to inspect research cost."
	fLbl.Parent = frame

	local toast = Instance.new("Frame")
	toast.Name = "BlueprintToast"
	toast.AnchorPoint = Vector2.new(0.5, 0)
	toast.Position = UDim2.new(0.5, 0, 0, 74)
	toast.Size = UDim2.fromOffset(360, 36)
	toast.BackgroundColor3 = COLOR_OK
	toast.BorderSizePixel = 0
	toast.Visible = false
	toast.Parent = screenGui

	local tCorner = Instance.new("UICorner")
	tCorner.CornerRadius = UDim.new(0, 8)
	tCorner.Parent = toast

	local tLbl = Instance.new("TextLabel")
	tLbl.Size = UDim2.fromScale(1, 1)
	tLbl.BackgroundTransparency = 1
	tLbl.Font = Enum.Font.GothamBold
	tLbl.TextSize = 14
	tLbl.TextColor3 = Color3.new(1, 1, 1)
	tLbl.Text = ""
	tLbl.Parent = toast

	mainFrame = frame
	itemNameLabel = nameLbl
	recipeInfoLabel = infoLbl
	costLabel = cLbl
	researchButton = rBtn
	feedbackLabel = fLbl
	toastFrame = toast
	toastLabel = tLbl
	screenGui.Parent = playerGui
end

function BlueprintController.HasBlueprint(recipeId: string): boolean
	local recipe = Recipes[recipeId]
	if recipe == nil then
		return false
	end
	if not recipe.RequiresBlueprint then
		return true
	end
	return unlockedBlueprints[recipeId] == true
end

function BlueprintController.IsOpen(): boolean
	return isOpen
end

function BlueprintController.SetOpen(open: boolean)
	if isOpen == open then
		return
	end
	isOpen = open
	if open then
		if LootController.IsOpen() then
			LootController.Close()
		end
		InventoryUIController.RegisterSlotInterceptor(INTERCEPTOR_ID, function(slotIndex: number): boolean
			if not isOpen then
				return false
			end
			selectedSlotIndex = slotIndex
			refreshResearchUi()
			return true
		end)
		if not InventoryUIController.IsOpen() then
			InventoryUIController.SetOpen(true)
		end
		refreshResearchUi()
	else
		activeTable = nil
		selectedSlotIndex = nil
		InventoryUIController.UnregisterSlotInterceptor(INTERCEPTOR_ID)
	end
	if mainFrame then
		mainFrame.Visible = open
	end
end

function BlueprintController.Init()
	if isInitialized then
		return
	end
	isInitialized = true

	createResearchGui()

	Net.GetEvent(Net.Events.BlueprintSync).OnClientEvent:Connect(function(payload: any)
		local nextMap: { [string]: boolean } = {}
		if type(payload) == "table" then
			for k, v in payload do
				if type(k) == "string" and v == true then
					nextMap[k] = true
				end
			end
		end
		unlockedBlueprints = nextMap
		changedSignal:Fire(unlockedBlueprints)
		if isOpen then
			refreshResearchUi()
		end
	end)

	Net.GetEvent(Net.Events.ResearchTableOpen).OnClientEvent:Connect(function(payload: any)
		if type(payload) ~= "table" or type(payload.TableId) ~= "string" then
			return
		end
		activeTable = {
			TableId = payload.TableId,
			Name = if type(payload.Name) == "string" then payload.Name else "Research Table",
			Position = if typeof(payload.Position) == "Vector3" then payload.Position else Vector3.zero,
		}
		selectedSlotIndex = nil
		if feedbackLabel then
			feedbackLabel.Text = "Tip: Click any item in your inventory to inspect research cost."
			feedbackLabel.TextColor3 = Color3.fromRGB(165, 175, 190)
		end
		BlueprintController.SetOpen(true)
	end)

	Net.GetEvent(Net.Events.ResearchFeedback).OnClientEvent:Connect(function(payload: any)
		if type(payload) ~= "table" or type(payload.Message) ~= "string" then
			return
		end
		showToast(payload.Success == true, payload.Message)
		if isOpen then
			refreshResearchUi()
		end
	end)

	InventoryController.OnChanged(function(_inv: Inventory)
		if isOpen then
			refreshResearchUi()
		end
	end)

	InventoryUIController.OpenChanged:Connect(function(open: boolean)
		if not open and isOpen then
			BlueprintController.SetOpen(false)
		end
	end)

	LootController.OpenChanged:Connect(function(open: boolean)
		if open and isOpen then
			BlueprintController.SetOpen(false)
		end
	end)

	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessedEvent: boolean)
		if gameProcessedEvent then
			return
		end
		if input.KeyCode == Enum.KeyCode.Escape and isOpen then
			BlueprintController.SetOpen(false)
		end
	end)

	RunService.Heartbeat:Connect(function()
		if toastFrame and toastFrame.Visible and os.clock() >= toastExpireAt then
			toastFrame.Visible = false
		end
		if isOpen and activeTable ~= nil then
			local localPlayer = Players.LocalPlayer
			local char = if localPlayer then localPlayer.Character else nil
			local hrp = if char then char:FindFirstChild("HumanoidRootPart") else nil
			if not (hrp and hrp:IsA("BasePart")) then
				BlueprintController.SetOpen(false)
				return
			end
			local maxDist = Config.Research.InteractDistance + 4
			if (hrp.Position - activeTable.Position).Magnitude > maxDist then
				BlueprintController.SetOpen(false)
			end
		end
	end)
end

return BlueprintController
