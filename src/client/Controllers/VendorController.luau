--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Config = require(ReplicatedStorage.Shared.Config)
local Types = require(ReplicatedStorage.Shared.Types)
local Items = require(ReplicatedStorage.Shared.configs.Items)
local Vendors = require(ReplicatedStorage.Shared.configs.Vendors)
local Net = require(ReplicatedStorage.Shared.Net)
local Signal = require(ReplicatedStorage.Shared.Signal)
local InventoryController = require(script.Parent.InventoryController)
local InventoryUIController = require(script.Parent.InventoryUIController)
local LootController = require(script.Parent.LootController)
local CraftingController = require(script.Parent.CraftingController)

type Inventory = Types.Inventory
type VendorId = Types.VendorId
type VendorOffer = Types.VendorOffer
type VendorConfig = Types.VendorConfig

type OfferCardUI = {
	Offer: VendorOffer,
	OwnedLabel: TextLabel,
	BuyOneButton: TextButton,
	BuyFiveButton: TextButton?,
	CardStroke: UIStroke,
}

local COLOR_BUY_PILL = Color3.fromRGB(55, 130, 210)
local COLOR_SELL_PILL = Color3.fromRGB(210, 140, 50)
local COLOR_AFFORD = Color3.fromRGB(115, 225, 130)
local COLOR_MISSING = Color3.fromRGB(235, 105, 105)
local COLOR_BTN_READY = Color3.fromRGB(58, 135, 78)
local COLOR_BTN_DISABLED = Color3.fromRGB(58, 60, 70)
local COLOR_FEEDBACK_OK = Color3.fromRGB(40, 115, 62)
local COLOR_FEEDBACK_ERR = Color3.fromRGB(145, 50, 50)

local mainFrame: Frame? = nil
local accentBar: Frame? = nil
local titleLabel: TextLabel? = nil
local roleLabel: TextLabel? = nil
local scrapLabel: TextLabel? = nil
local offerListFrame: ScrollingFrame? = nil
local feedbackBanner: Frame? = nil
local feedbackLabel: TextLabel? = nil
local offerCards: { OfferCardUI } = {}
local activeVendorId: VendorId? = nil
local activeNpcPosition: Vector3? = nil
local feedbackHideAt = 0
local isOpen = false
local isInitialized = false
local openChangedSignal: Signal.Signal<boolean> = Signal.new()

local VendorController = {
	OpenChanged = openChangedSignal,
}

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

local function refreshOffers()
	local inv = InventoryController.GetInventory()
	if scrapLabel then
		local scrapCount = countItemInInventory(inv, "scrap")
		scrapLabel.Text = string.format("Scrap: %d", scrapCount)
	end

	for _, cardUI in offerCards do
		local offer = cardUI.Offer
		local owned = countItemInInventory(inv, offer.GiveId)
		local giveCfg = Items[offer.GiveId]
		local giveName = if giveCfg then giveCfg.Name else offer.GiveId
		local canAffordOne = owned >= offer.GiveCount
		local canAffordFive = owned >= offer.GiveCount * 5

		cardUI.OwnedLabel.Text = string.format("Owned %s: %d", giveName, owned)
		cardUI.OwnedLabel.TextColor3 = if canAffordOne then COLOR_AFFORD else COLOR_MISSING
		cardUI.BuyOneButton.BackgroundColor3 = if canAffordOne then COLOR_BTN_READY else COLOR_BTN_DISABLED
		cardUI.CardStroke.Color = if canAffordOne then Color3.fromRGB(85, 150, 95) else Color3.fromRGB(68, 68, 80)

		if cardUI.BuyFiveButton then
			cardUI.BuyFiveButton.BackgroundColor3 = if canAffordFive then COLOR_BTN_READY else COLOR_BTN_DISABLED
		end
	end
end

local function clearOfferCards()
	table.clear(offerCards)
	if not offerListFrame then
		return
	end
	for _, child in offerListFrame:GetChildren() do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end
end

local function buildOfferCards(vendorCfg: VendorConfig)
	clearOfferCards()
	if not offerListFrame then
		return
	end

	for idx, offer in ipairs(vendorCfg.Offers) do
		local giveCfg = Items[offer.GiveId]
		local recCfg = Items[offer.ReceiveId]
		local giveName = if giveCfg then giveCfg.Name else offer.GiveId
		local recName = if recCfg then recCfg.Name else offer.ReceiveId
		local recMaxStack = if recCfg then recCfg.MaxStack else 1

		local card = Instance.new("Frame")
		card.Name = offer.OfferId
		card.LayoutOrder = idx
		card.Size = UDim2.new(1, -8, 0, 58)
		card.BackgroundColor3 = Color3.fromRGB(32, 33, 40)
		card.BorderSizePixel = 0
		card.Parent = offerListFrame

		local cardCorner = Instance.new("UICorner")
		cardCorner.CornerRadius = UDim.new(0, 8)
		cardCorner.Parent = card

		local cardStroke = Instance.new("UIStroke")
		cardStroke.Color = Color3.fromRGB(68, 68, 80)
		cardStroke.Thickness = 1
		cardStroke.Parent = card

		local pill = Instance.new("TextLabel")
		pill.Name = "ModePill"
		pill.Position = UDim2.fromOffset(10, 8)
		pill.Size = UDim2.fromOffset(42, 18)
		pill.BackgroundColor3 = if offer.Mode == "Sell" then COLOR_SELL_PILL else COLOR_BUY_PILL
		pill.BorderSizePixel = 0
		pill.Font = Enum.Font.GothamBold
		pill.TextSize = 10
		pill.TextColor3 = Color3.new(1, 1, 1)
		pill.Text = if offer.Mode == "Sell" then "SELL" else "BUY"
		pill.Parent = card

		local pillCorner = Instance.new("UICorner")
		pillCorner.CornerRadius = UDim.new(0, 4)
		pillCorner.Parent = pill

		local tradeLabel = Instance.new("TextLabel")
		tradeLabel.Name = "TradeLabel"
		tradeLabel.Position = UDim2.fromOffset(58, 7)
		tradeLabel.Size = UDim2.new(1, -170, 0, 20)
		tradeLabel.BackgroundTransparency = 1
		tradeLabel.Font = Enum.Font.GothamBold
		tradeLabel.TextSize = 12
		tradeLabel.TextColor3 = Color3.fromRGB(240, 242, 248)
		tradeLabel.TextXAlignment = Enum.TextXAlignment.Left
		tradeLabel.Text = string.format("%s x%d  ->  %s x%d", giveName, offer.GiveCount, recName, offer.ReceiveCount)
		tradeLabel.Parent = card

		local ownedLabel = Instance.new("TextLabel")
		ownedLabel.Name = "OwnedLabel"
		ownedLabel.Position = UDim2.fromOffset(10, 32)
		ownedLabel.Size = UDim2.new(1, -124, 0, 18)
		ownedLabel.BackgroundTransparency = 1
		ownedLabel.Font = Enum.Font.Gotham
		ownedLabel.TextSize = 11
		ownedLabel.TextColor3 = COLOR_MISSING
		ownedLabel.TextXAlignment = Enum.TextXAlignment.Left
		ownedLabel.Text = ""
		ownedLabel.Parent = card

		local btnOne = Instance.new("TextButton")
		btnOne.Name = "TradeOneButton"
		btnOne.AnchorPoint = Vector2.new(1, 0.5)
		btnOne.Position = UDim2.new(1, if recMaxStack > 1 then -58 else -10, 0.5, 0)
		btnOne.Size = UDim2.fromOffset(44, 28)
		btnOne.BackgroundColor3 = COLOR_BTN_READY
		btnOne.BorderSizePixel = 0
		btnOne.Font = Enum.Font.GothamBold
		btnOne.TextSize = 12
		btnOne.TextColor3 = Color3.new(1, 1, 1)
		btnOne.Text = "x1"
		btnOne.Parent = card

		local oneCorner = Instance.new("UICorner")
		oneCorner.CornerRadius = UDim.new(0, 6)
		oneCorner.Parent = btnOne

		btnOne.Activated:Connect(function()
			if activeVendorId then
				Net.GetEvent(Net.Events.VendorTradeRequest):FireServer(activeVendorId, offer.OfferId, 1)
			end
		end)

		local btnFive: TextButton? = nil
		if recMaxStack > 1 then
			local five = Instance.new("TextButton")
			five.Name = "TradeFiveButton"
			five.AnchorPoint = Vector2.new(1, 0.5)
			five.Position = UDim2.new(1, -10, 0.5, 0)
			five.Size = UDim2.fromOffset(44, 28)
			five.BackgroundColor3 = COLOR_BTN_READY
			five.BorderSizePixel = 0
			five.Font = Enum.Font.GothamBold
			five.TextSize = 12
			five.TextColor3 = Color3.new(1, 1, 1)
			five.Text = "x5"
			five.Parent = card

			local fiveCorner = Instance.new("UICorner")
			fiveCorner.CornerRadius = UDim.new(0, 6)
			fiveCorner.Parent = five

			five.Activated:Connect(function()
				if activeVendorId then
					Net.GetEvent(Net.Events.VendorTradeRequest):FireServer(activeVendorId, offer.OfferId, 5)
				end
			end)
			btnFive = five
		end

		table.insert(offerCards, {
			Offer = offer,
			OwnedLabel = ownedLabel,
			BuyOneButton = btnOne,
			BuyFiveButton = btnFive,
			CardStroke = cardStroke,
		})
	end
end

local function createVendorGui()
	local localPlayer = Players.LocalPlayer
	if not localPlayer then
		return
	end
	local playerGui = localPlayer:WaitForChild("PlayerGui") :: PlayerGui

	local existing = playerGui:FindFirstChild("VendorGui")
	if existing then
		existing:Destroy()
	end

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "VendorGui"
	screenGui.ResetOnSpawn = false
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.DisplayOrder = 12

	local frame = Instance.new("Frame")
	frame.Name = "MainFrame"
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.fromScale(0.5, 0.5)
	frame.Size = UDim2.fromOffset(440, 520)
	frame.BackgroundColor3 = Color3.fromRGB(20, 22, 28)
	frame.BackgroundTransparency = 0.06
	frame.BorderSizePixel = 0
	frame.Visible = false
	frame.Parent = screenGui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 12)
	corner.Parent = frame

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(90, 94, 108)
	stroke.Thickness = 1.5
	stroke.Parent = frame

	local topBar = Instance.new("Frame")
	topBar.Name = "AccentBar"
	topBar.Size = UDim2.new(1, 0, 0, 5)
	topBar.BackgroundColor3 = Color3.fromRGB(220, 155, 55)
	topBar.BorderSizePixel = 0
	topBar.Parent = frame

	local barCorner = Instance.new("UICorner")
	barCorner.CornerRadius = UDim.new(0, 12)
	barCorner.Parent = topBar

	local tLabel = Instance.new("TextLabel")
	tLabel.Name = "TitleLabel"
	tLabel.Position = UDim2.fromOffset(14, 12)
	tLabel.Size = UDim2.new(1, -150, 0, 24)
	tLabel.BackgroundTransparency = 1
	tLabel.Font = Enum.Font.GothamBold
	tLabel.TextSize = 18
	tLabel.TextColor3 = Color3.fromRGB(245, 246, 250)
	tLabel.TextXAlignment = Enum.TextXAlignment.Left
	tLabel.Text = "Vendor"
	tLabel.Parent = frame

	local rLabel = Instance.new("TextLabel")
	rLabel.Name = "RoleLabel"
	rLabel.Position = UDim2.fromOffset(14, 36)
	rLabel.Size = UDim2.new(1, -150, 0, 16)
	rLabel.BackgroundTransparency = 1
	rLabel.Font = Enum.Font.GothamMedium
	rLabel.TextSize = 12
	rLabel.TextColor3 = Color3.fromRGB(175, 180, 195)
	rLabel.TextXAlignment = Enum.TextXAlignment.Left
	rLabel.Text = ""
	rLabel.Parent = frame

	local sLabel = Instance.new("TextLabel")
	sLabel.Name = "ScrapLabel"
	sLabel.AnchorPoint = Vector2.new(1, 0)
	sLabel.Position = UDim2.new(1, -48, 0, 15)
	sLabel.Size = UDim2.fromOffset(105, 24)
	sLabel.BackgroundColor3 = Color3.fromRGB(36, 38, 46)
	sLabel.BorderSizePixel = 0
	sLabel.Font = Enum.Font.GothamBold
	sLabel.TextSize = 12
	sLabel.TextColor3 = Color3.fromRGB(240, 200, 95)
	sLabel.Text = "Scrap: 0"
	sLabel.Parent = frame

	local sCorner = Instance.new("UICorner")
	sCorner.CornerRadius = UDim.new(0, 6)
	sCorner.Parent = sLabel

	local closeBtn = Instance.new("TextButton")
	closeBtn.Name = "CloseButton"
	closeBtn.AnchorPoint = Vector2.new(1, 0)
	closeBtn.Position = UDim2.new(1, -12, 0, 12)
	closeBtn.Size = UDim2.fromOffset(28, 28)
	closeBtn.BackgroundColor3 = Color3.fromRGB(160, 55, 55)
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
		VendorController.SetOpen(false)
	end)

	local list = Instance.new("ScrollingFrame")
	list.Name = "OfferList"
	list.Position = UDim2.fromOffset(12, 60)
	list.Size = UDim2.new(1, -24, 1, -108)
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

	local banner = Instance.new("Frame")
	banner.Name = "FeedbackBanner"
	banner.AnchorPoint = Vector2.new(0, 1)
	banner.Position = UDim2.new(0, 12, 1, -10)
	banner.Size = UDim2.new(1, -24, 0, 30)
	banner.BackgroundColor3 = COLOR_FEEDBACK_OK
	banner.BorderSizePixel = 0
	banner.Visible = false
	banner.Parent = frame

	local bannerCorner = Instance.new("UICorner")
	bannerCorner.CornerRadius = UDim.new(0, 6)
	bannerCorner.Parent = banner

	local fLabel = Instance.new("TextLabel")
	fLabel.Name = "FeedbackLabel"
	fLabel.Size = UDim2.fromScale(1, 1)
	fLabel.BackgroundTransparency = 1
	fLabel.Font = Enum.Font.GothamBold
	fLabel.TextSize = 12
	fLabel.TextColor3 = Color3.new(1, 1, 1)
	fLabel.Text = ""
	fLabel.Parent = banner

	mainFrame = frame
	accentBar = topBar
	titleLabel = tLabel
	roleLabel = rLabel
	scrapLabel = sLabel
	offerListFrame = list
	feedbackBanner = banner
	feedbackLabel = fLabel

	screenGui.Parent = playerGui
end

function VendorController.IsOpen(): boolean
	return isOpen
end

function VendorController.GetActiveVendorId(): VendorId?
	return activeVendorId
end

function VendorController.SetOpen(open: boolean)
	local changed = isOpen ~= open
	isOpen = open
	if not open then
		activeVendorId = nil
		activeNpcPosition = nil
		if feedbackBanner then
			feedbackBanner.Visible = false
		end
	end
	if mainFrame then
		mainFrame.Visible = open
	end
	if changed then
		openChangedSignal:Fire(open)
	end
end

function VendorController.Init()
	if isInitialized then
		return
	end
	isInitialized = true

	createVendorGui()

	Net.GetEvent(Net.Events.VendorOpen).OnClientEvent:Connect(function(vendorIdAny: any, npcPosAny: any)
		local vendorCfg = Vendors.Get(vendorIdAny)
		if not vendorCfg then
			return
		end

		if InventoryUIController.IsOpen() then
			InventoryUIController.SetOpen(false)
		end
		if CraftingController.IsOpen() then
			CraftingController.SetOpen(false)
		end

		activeVendorId = vendorCfg.Id
		activeNpcPosition = if typeof(npcPosAny) == "Vector3" then npcPosAny else nil

		if accentBar then
			accentBar.BackgroundColor3 = vendorCfg.AccentColor
		end
		if titleLabel then
			titleLabel.Text = vendorCfg.Name
		end
		if roleLabel then
			roleLabel.Text = vendorCfg.RoleTitle
		end
		if feedbackBanner then
			feedbackBanner.Visible = false
		end

		buildOfferCards(vendorCfg)
		refreshOffers()
		VendorController.SetOpen(true)
	end)

	Net.GetEvent(Net.Events.VendorTradeFeedback).OnClientEvent:Connect(function(payload: any)
		if type(payload) ~= "table" or type(payload.Message) ~= "string" then
			return
		end
		if feedbackBanner and feedbackLabel then
			feedbackBanner.BackgroundColor3 = if payload.Success == true then COLOR_FEEDBACK_OK else COLOR_FEEDBACK_ERR
			feedbackLabel.Text = payload.Message
			feedbackBanner.Visible = true
			feedbackHideAt = os.clock() + 3.0
		end
		refreshOffers()
	end)

	InventoryController.OnChanged(function(_inv: Inventory)
		if isOpen then
			refreshOffers()
		end
	end)

	InventoryUIController.OpenChanged:Connect(function(open: boolean)
		if open and isOpen then
			VendorController.SetOpen(false)
		end
	end)

	LootController.OpenChanged:Connect(function(open: boolean)
		if open and isOpen then
			VendorController.SetOpen(false)
		end
	end)

	CraftingController.OpenChanged:Connect(function(open: boolean)
		if open and isOpen then
			VendorController.SetOpen(false)
		end
	end)

	local localPlayer = Players.LocalPlayer
	if localPlayer then
		localPlayer:GetAttributeChangedSignal("InRaid"):Connect(function()
			if localPlayer:GetAttribute("InRaid") == true and isOpen then
				VendorController.SetOpen(false)
			end
		end)
	end

	UserInputService.InputBegan:Connect(function(input: InputObject, _gameProcessedEvent: boolean)
		if isOpen and input.KeyCode == Enum.KeyCode.Escape then
			VendorController.SetOpen(false)
		end
	end)

	RunService.RenderStepped:Connect(function()
		if feedbackBanner and feedbackBanner.Visible and os.clock() >= feedbackHideAt then
			feedbackBanner.Visible = false
		end
		if isOpen and activeNpcPosition ~= nil and localPlayer and localPlayer.Character then
			local hrp = localPlayer.Character:FindFirstChild("HumanoidRootPart")
			if hrp and hrp:IsA("BasePart") then
				if (hrp.Position - activeNpcPosition).Magnitude > (Config.VendorHub.InteractDistance + 3) then
					VendorController.SetOpen(false)
				end
			end
		end
	end)
end

return VendorController
