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
local TERMINAL_MAX_DISTANCE = 20

local currentHudState: RaidHudState? = nil
local cachedTargets: { RaidTargetInfo } = {}
local selectedTierFilter = 0
local isSelectionOpen = false
local lastPlaceTime = 0
local reportToastToken = 0
local isInitialized = false
local boundPrompts: { [ProximityPrompt]: boolean } = {}
local watchedTerminals: { [Instance]: boolean } = {}

local selectFrame: Frame? = nil
local selectStatusLabel: TextLabel? = nil
local playerTierBadgeLabel: TextLabel? = nil
local targetListContainer: ScrollingFrame? = nil
local tierFilterButtons: { [number]: TextButton } = {}
local hudFrame: Frame? = nil
local hudStatusLabel: TextLabel? = nil
local hudMetaLabel: TextLabel? = nil
local extractButton: TextButton? = nil
local abandonButton: TextButton? = nil
local reportToastLabel: TextLabel? = nil

local RaidController = {}

local function getLocalBaseTier(): number
	local localPlayer = Players.LocalPlayer
	local attr = if localPlayer ~= nil then localPlayer:GetAttribute("BaseTier") else nil
	return if typeof(attr) == "number" then math.floor(attr) else 0
end

local function formatCostMap(costMap: { [string]: number }?): string
	if costMap == nil then
		return "Free"
	end
	local parts: { string } = {}
	for itemId, amount in costMap do
		if amount > 0 then
			local cfg = Items[itemId]
			table.insert(parts, string.format("%d %s", amount, if cfg ~= nil then cfg.Name else itemId))
		end
	end
	table.sort(parts)
	if #parts == 0 then
		return "Free"
	end
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

local function canAffordCostMap(costMap: { [string]: number }?): boolean
	if costMap == nil then
		return true
	end
	for itemId, required in costMap do
		if required > 0 and countOwnedItem(itemId) < required then
			return false
		end
	end
	return true
end

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

	local targetTier = math.clamp(target.BaseTier or 1, 1, 3)
	local playerTier = getLocalBaseTier()
	local tierUnlocked = playerTier >= targetTier
	local affordable = canAffordCostMap(target.LaunchCost)
	local canLaunch = tierUnlocked and affordable

	local row = Instance.new("Frame")
	row.Name = string.format("Target_%d", target.UserId)
	row.Size = UDim2.new(1, -8, 0, 82)
	row.BackgroundColor3 = Color3.fromRGB(34, 34, 42)
	row.BorderSizePixel = 0
	row.Parent = targetListContainer

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = row

	local stroke = Instance.new("UIStroke")
	stroke.Color = if tierUnlocked then Color3.fromRGB(78, 86, 104) else Color3.fromRGB(125, 58, 58)
	stroke.Thickness = 1
	stroke.Parent = row

	local nameLabel = Instance.new("TextLabel")
	nameLabel.Name = "TargetName"
	nameLabel.Position = UDim2.fromOffset(12, 6)
	nameLabel.Size = UDim2.new(1, -156, 0, 20)
	nameLabel.BackgroundTransparency = 1
	nameLabel.Font = Enum.Font.GothamBold
	nameLabel.TextSize = 14
	nameLabel.TextColor3 = Color3.fromRGB(240, 240, 245)
	nameLabel.TextXAlignment = Enum.TextXAlignment.Left
	nameLabel.TextTruncate = Enum.TextTruncate.AtEnd
	local tagText = if target.IsPreset then "[Preset] " else ""
	nameLabel.Text =
		string.format("%s%s  |  Tier %d (%d blocks)", tagText, target.DisplayName, targetTier, target.PieceCount)
	nameLabel.Parent = row

	local dangerLabel = Instance.new("TextLabel")
	dangerLabel.Name = "DangerInfo"
	dangerLabel.Position = UDim2.fromOffset(12, 27)
	dangerLabel.Size = UDim2.new(1, -156, 0, 16)
	dangerLabel.BackgroundTransparency = 1
	dangerLabel.Font = Enum.Font.Gotham
	dangerLabel.TextSize = 11
	dangerLabel.TextColor3 = Color3.fromRGB(235, 175, 110)
	dangerLabel.TextXAlignment = Enum.TextXAlignment.Left
	dangerLabel.TextTruncate = Enum.TextTruncate.AtEnd
	dangerLabel.Text =
		string.format("Danger: %s  |  Reward: %s", target.DangerLabel or "Standard", target.RewardLabel or "Base Loot")
	dangerLabel.Parent = row

	local costLabel = Instance.new("TextLabel")
	costLabel.Name = "CostInfo"
	costLabel.Position = UDim2.fromOffset(12, 46)
	costLabel.Size = UDim2.new(1, -156, 0, 18)
	costLabel.BackgroundTransparency = 1
	costLabel.Font = Enum.Font.GothamBold
	costLabel.TextSize = 11
	costLabel.TextColor3 = if affordable then Color3.fromRGB(140, 225, 155) else Color3.fromRGB(235, 115, 115)
	costLabel.TextXAlignment = Enum.TextXAlignment.Left
	costLabel.TextTruncate = Enum.TextTruncate.AtEnd
	costLabel.Text = string.format("Launch Cost: %s", formatCostMap(target.LaunchCost))
	costLabel.Parent = row

	local launchBtn = Instance.new("TextButton")
	launchBtn.Name = "LaunchButton"
	launchBtn.AnchorPoint = Vector2.new(1, 0.5)
	launchBtn.Position = UDim2.new(1, -10, 0.5, 0)
	launchBtn.Size = UDim2.fromOffset(128, 38)
	launchBtn.BackgroundColor3 = if canLaunch then Color3.fromRGB(175, 48, 48) else Color3.fromRGB(72, 66, 74)
	launchBtn.BorderSizePixel = 0
	launchBtn.Font = Enum.Font.GothamBold
	launchBtn.TextSize = 12
	launchBtn.TextColor3 = Color3.new(1, 1, 1)
	launchBtn.AutoButtonColor = canLaunch
	launchBtn.Text = if not tierUnlocked
		then string.format("Need Base T%d", targetTier)
		elseif not affordable then "Need Resources"
		else "Launch Raid"
	launchBtn.Parent = row

	local btnCorner = Instance.new("UICorner")
	btnCorner.CornerRadius = UDim.new(0, 6)
	btnCorner.Parent = launchBtn

	launchBtn.MouseButton1Click:Connect(function()
		if not tierUnlocked then
			if selectStatusLabel then
				selectStatusLabel.Text =
					string.format("Locked: Base Tier %d required (yours: Tier %d)", targetTier, playerTier)
			end
			return
		end
		RaidController.CloseTargetList()
		Net.GetEvent(Net.Events.StartRaidRequest):FireServer(target.UserId)
	end)
end

local function refreshTargetListUi()
	clearTargetRows()
	if playerTierBadgeLabel then
		playerTierBadgeLabel.Text = string.format("Your Base: Tier %d", getLocalBaseTier())
	end
	for tierIdx, btn in tierFilterButtons do
		local active = (selectedTierFilter == tierIdx)
		btn.BackgroundColor3 = if active then Color3.fromRGB(175, 55, 55) else Color3.fromRGB(48, 50, 60)
	end

	local filtered: { RaidTargetInfo } = {}
	for _, target in cachedTargets do
		local tTier = math.clamp(target.BaseTier or 1, 1, 3)
		if selectedTierFilter == 0 or tTier == selectedTierFilter then
			table.insert(filtered, target)
		end
	end

	if #filtered == 0 then
		if selectStatusLabel then
			selectStatusLabel.Text = "No raidable bases available for selected tier."
		end
		return
	end

	if selectStatusLabel then
		selectStatusLabel.Text = string.format("Available targets: %d", #filtered)
	end
	for _, target in filtered do
		createTargetRow(target)
	end
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
	topBar.Size = UDim2.fromOffset(650, 62)
	topBar.BackgroundColor3 = Color3.fromRGB(98, 24, 28)
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
	statusLbl.Position = UDim2.fromOffset(14, 6)
	statusLbl.Size = UDim2.new(1, -246, 0, 22)
	statusLbl.BackgroundTransparency = 1
	statusLbl.Font = Enum.Font.GothamBold
	statusLbl.TextSize = 14
	statusLbl.TextColor3 = Color3.new(1, 1, 1)
	statusLbl.TextXAlignment = Enum.TextXAlignment.Left
	statusLbl.TextTruncate = Enum.TextTruncate.AtEnd
	statusLbl.Text = ""
	statusLbl.Parent = topBar

	local metaLbl = Instance.new("TextLabel")
	metaLbl.Name = "MetaLabel"
	metaLbl.Position = UDim2.fromOffset(14, 30)
	metaLbl.Size = UDim2.new(1, -246, 0, 22)
	metaLbl.BackgroundTransparency = 1
	metaLbl.Font = Enum.Font.GothamMedium
	metaLbl.TextSize = 12
	metaLbl.TextColor3 = Color3.fromRGB(255, 225, 195)
	metaLbl.TextXAlignment = Enum.TextXAlignment.Left
	metaLbl.TextTruncate = Enum.TextTruncate.AtEnd
	metaLbl.Text = ""
	metaLbl.Parent = topBar

	local extractBtn = Instance.new("TextButton")
	extractBtn.Name = "ExtractButton"
	extractBtn.AnchorPoint = Vector2.new(1, 0.5)
	extractBtn.Position = UDim2.new(1, -100, 0.5, 0)
	extractBtn.Size = UDim2.fromOffset(124, 36)
	extractBtn.BackgroundColor3 = Color3.fromRGB(70, 74, 82)
	extractBtn.BorderSizePixel = 0
	extractBtn.Font = Enum.Font.GothamBold
	extractBtn.TextSize = 12
	extractBtn.TextColor3 = Color3.new(1, 1, 1)
	extractBtn.Text = "TC Required"
	extractBtn.Parent = topBar

	local extractCorner = Instance.new("UICorner")
	extractCorner.CornerRadius = UDim.new(0, 6)
	extractCorner.Parent = extractBtn

	extractBtn.MouseButton1Click:Connect(function()
		Net.GetEvent(Net.Events.RaidExtractRequest):FireServer()
	end)

	local abandonBtn = Instance.new("TextButton")
	abandonBtn.Name = "AbandonButton"
	abandonBtn.AnchorPoint = Vector2.new(1, 0.5)
	abandonBtn.Position = UDim2.new(1, -10, 0.5, 0)
	abandonBtn.Size = UDim2.fromOffset(82, 36)
	abandonBtn.BackgroundColor3 = Color3.fromRGB(130, 44, 44)
	abandonBtn.BorderSizePixel = 0
	abandonBtn.Font = Enum.Font.GothamBold
	abandonBtn.TextSize = 12
	abandonBtn.TextColor3 = Color3.new(1, 1, 1)
	abandonBtn.Text = "Abandon"
	abandonBtn.Parent = topBar

	local abandonCorner = Instance.new("UICorner")
	abandonCorner.CornerRadius = UDim.new(0, 6)
	abandonCorner.Parent = abandonBtn

	abandonBtn.MouseButton1Click:Connect(function()
		Net.GetEvent(Net.Events.RaidAbandonRequest):FireServer()
	end)

	-- 2. Defense Report notification toast
	local reportToast = Instance.new("TextLabel")
	reportToast.Name = "DefenseReportToast"
	reportToast.AnchorPoint = Vector2.new(0.5, 0)
	reportToast.Position = UDim2.new(0.5, 0, 0, 82)
	reportToast.Size = UDim2.fromOffset(580, 44)
	reportToast.BackgroundColor3 = Color3.fromRGB(28, 72, 110)
	reportToast.BackgroundTransparency = 0.08
	reportToast.BorderSizePixel = 0
	reportToast.Font = Enum.Font.GothamBold
	reportToast.TextSize = 13
	reportToast.TextColor3 = Color3.new(1, 1, 1)
	reportToast.TextWrapped = true
	reportToast.Text = ""
	reportToast.Visible = false
	reportToast.Parent = screenGui
	local reportCorner = Instance.new("UICorner")
	reportCorner.CornerRadius = UDim.new(0, 8)
	reportCorner.Parent = reportToast

	-- 3. Raid Target Selection Modal
	local modal = Instance.new("Frame")
	modal.Name = "RaidSelectFrame"
	modal.AnchorPoint = Vector2.new(0.5, 0.5)
	modal.Position = UDim2.fromScale(0.5, 0.5)
	modal.Size = UDim2.fromOffset(540, 430)
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
	titleLbl.Size = UDim2.new(1, -260, 0, 26)
	titleLbl.BackgroundTransparency = 1
	titleLbl.Font = Enum.Font.GothamBold
	titleLbl.TextSize = 16
	titleLbl.TextColor3 = Color3.fromRGB(255, 220, 220)
	titleLbl.TextXAlignment = Enum.TextXAlignment.Left
	titleLbl.Text = "RAID TERMINAL"
	titleLbl.Parent = modal

	local tierBadge = Instance.new("TextLabel")
	tierBadge.Name = "YourTierBadge"
	tierBadge.AnchorPoint = Vector2.new(1, 0)
	tierBadge.Position = UDim2.new(1, -132, 0, 10)
	tierBadge.Size = UDim2.fromOffset(118, 28)
	tierBadge.BackgroundColor3 = Color3.fromRGB(45, 92, 68)
	tierBadge.BorderSizePixel = 0
	tierBadge.Font = Enum.Font.GothamBold
	tierBadge.TextSize = 12
	tierBadge.TextColor3 = Color3.new(1, 1, 1)
	tierBadge.Text = "Your Base: Tier 0"
	tierBadge.Parent = modal
	local badgeCorner = Instance.new("UICorner")
	badgeCorner.CornerRadius = UDim.new(0, 6)
	badgeCorner.Parent = tierBadge

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

	local filterRow = Instance.new("Frame")
	filterRow.Name = "TierFilterRow"
	filterRow.Position = UDim2.fromOffset(16, 44)
	filterRow.Size = UDim2.new(1, -32, 0, 28)
	filterRow.BackgroundTransparency = 1
	filterRow.Parent = modal

	local filterLayout = Instance.new("UIListLayout")
	filterLayout.FillDirection = Enum.FillDirection.Horizontal
	filterLayout.Padding = UDim.new(0, 8)
	filterLayout.SortOrder = Enum.SortOrder.LayoutOrder
	filterLayout.Parent = filterRow

	table.clear(tierFilterButtons)
	local filterDefs = {
		{ Tier = 0, Label = "All Tiers" },
		{ Tier = 1, Label = "Tier 1" },
		{ Tier = 2, Label = "Tier 2" },
		{ Tier = 3, Label = "Tier 3" },
	}
	for idx, def in filterDefs do
		local fBtn = Instance.new("TextButton")
		fBtn.Name = string.format("FilterTier_%d", def.Tier)
		fBtn.LayoutOrder = idx
		fBtn.Size = UDim2.fromOffset(92, 26)
		fBtn.BackgroundColor3 = if def.Tier == 0 then Color3.fromRGB(175, 55, 55) else Color3.fromRGB(48, 50, 60)
		fBtn.BorderSizePixel = 0
		fBtn.Font = Enum.Font.GothamBold
		fBtn.TextSize = 12
		fBtn.TextColor3 = Color3.new(1, 1, 1)
		fBtn.Text = def.Label
		fBtn.Parent = filterRow
		local fCorner = Instance.new("UICorner")
		fCorner.CornerRadius = UDim.new(0, 6)
		fCorner.Parent = fBtn
		fBtn.MouseButton1Click:Connect(function()
			selectedTierFilter = def.Tier
			refreshTargetListUi()
		end)
		tierFilterButtons[def.Tier] = fBtn
	end

	local listStatus = Instance.new("TextLabel")
	listStatus.Name = "StatusText"
	listStatus.Position = UDim2.fromOffset(16, 76)
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
	scroller.Position = UDim2.fromOffset(14, 100)
	scroller.Size = UDim2.new(1, -28, 1, -114)
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
	hudMetaLabel = metaLbl
	extractButton = extractBtn
	abandonButton = abandonBtn
	reportToastLabel = reportToast
	selectFrame = modal
	selectStatusLabel = listStatus
	playerTierBadgeLabel = tierBadge
	targetListContainer = scroller

	screenGui.Parent = playerGui
end

local function onRaidListSync(targetsAny: any)
	table.clear(cachedTargets)

	if type(targetsAny) ~= "table" then
		refreshTargetListUi()
		return
	end

	for _, entry in targetsAny do
		if
			type(entry) == "table"
			and typeof(entry.UserId) == "number"
			and typeof(entry.DisplayName) == "string"
			and typeof(entry.PieceCount) == "number"
		then
			local parsedCost: { [string]: number }? = nil
			if type(entry.LaunchCost) == "table" then
				parsedCost = {}
				for k, v in entry.LaunchCost do
					if typeof(k) == "string" and typeof(v) == "number" and v > 0 then
						(parsedCost :: { [string]: number })[k] = v
					end
				end
			end
			table.insert(cachedTargets, {
				UserId = entry.UserId,
				DisplayName = entry.DisplayName,
				PieceCount = entry.PieceCount,
				BaseTier = if typeof(entry.BaseTier) == "number" then entry.BaseTier else 1,
				DangerLabel = if typeof(entry.DangerLabel) == "string" then entry.DangerLabel else nil,
				RewardLabel = if typeof(entry.RewardLabel) == "string" then entry.RewardLabel else nil,
				LaunchCost = parsedCost,
				IsPreset = entry.IsPreset == true,
			})
		end
	end

	refreshTargetListUi()
end

local function onRaidHudSync(stateAny: any)
	if type(stateAny) ~= "table" or typeof(stateAny.Active) ~= "boolean" then
		return
	end

	local targetName = if typeof(stateAny.TargetName) == "string" then stateAny.TargetName else "Target"
	local targetTier = if typeof(stateAny.TargetBaseTier) == "number" then stateAny.TargetBaseTier else nil
	local timeLeft = if typeof(stateAny.TimeLeft) == "number" then stateAny.TimeLeft else 0
	local statusText = if typeof(stateAny.StatusText) == "string" and #stateAny.StatusText > 0
		then stateAny.StatusText
		else nil
	local tcCaptured = stateAny.TcCaptured == true
	local tcHackActive = stateAny.TcHackActive == true
	local tcHackProgress = if typeof(stateAny.TcHackProgress) == "number" then stateAny.TcHackProgress else 0
	local livesLeft = if typeof(stateAny.LivesLeft) == "number" then stateAny.LivesLeft else Config.Raid.MaxLives
	local maxLives = if typeof(stateAny.MaxLives) == "number" then stateAny.MaxLives else Config.Raid.MaxLives
	local stashCount = if typeof(stateAny.StashItemCount) == "number" then stateAny.StashItemCount else 0
	local canExtract = stateAny.CanExtract == true

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
		TargetBaseTier = targetTier,
		TimeLeft = timeLeft,
		StatusText = statusText,
		TcCaptured = tcCaptured,
		TcHackProgress = tcHackProgress,
		TcHackActive = tcHackActive,
		LivesLeft = livesLeft,
		MaxLives = maxLives,
		StashItemCount = stashCount,
		CanExtract = canExtract,
	}
	currentHudState = state

	if hudFrame and hudStatusLabel then
		local tierTag = if targetTier ~= nil then string.format(" [T%d]", targetTier) else ""
		if statusText ~= nil then
			hudStatusLabel.Text = string.format("RAIDING %s%s | %s", targetName, tierTag, statusText)
		else
			hudStatusLabel.Text =
				string.format("RAIDING %s%s | Time: %s", targetName, tierTag, formatTimeMMSS(timeLeft))
		end

		if hudMetaLabel then
			local tcText = if tcCaptured
				then "TC Captured — Extract Available"
				elseif tcHackActive then string.format("Hacking TC: %d%%", math.floor(tcHackProgress * 100 + 0.5))
				else "TC: Active (Hack or Destroy)"
			hudMetaLabel.Text =
				string.format("Lives: %d/%d  |  Stash: %d  |  %s", livesLeft, maxLives, stashCount, tcText)
			hudMetaLabel.TextColor3 = if tcCaptured
				then Color3.fromRGB(130, 245, 165)
				elseif tcHackActive then Color3.fromRGB(255, 220, 115)
				else Color3.fromRGB(255, 210, 195)
		end

		if extractButton then
			extractButton.BackgroundColor3 = if canExtract
				then Color3.fromRGB(36, 155, 82)
				else Color3.fromRGB(70, 74, 82)
			extractButton.Text = if canExtract then "Extract (Outpost)" else "TC Required"
		end
		if abandonButton then
			abandonButton.Visible = true
		end
		hudFrame.Visible = true
	end
end

local function onRaidReportNotify(reportAny: any)
	if type(reportAny) ~= "table" or not reportToastLabel then
		return
	end
	local raiderName = if typeof(reportAny.RaiderName) == "string" then reportAny.RaiderName else "Raider"
	local targetTier = if typeof(reportAny.TargetTier) == "number" then reportAny.TargetTier else 1
	local defended = reportAny.Defended == true
	local bonusText = if type(reportAny.BonusItems) == "table"
		then formatCostMap(reportAny.BonusItems :: { [string]: number })
		else ""
	local msg = if defended
		then string.format(
			"Base Defended (T%d) vs %s! Bonus: %s",
			targetTier,
			raiderName,
			if #bonusText > 0 then bonusText else "None"
		)
		else string.format("Raid Alert (T%d): %s captured TC snapshot", targetTier, raiderName)

	reportToastToken += 1
	local myToken = reportToastToken
	reportToastLabel.Text = msg
	reportToastLabel.BackgroundColor3 = if defended then Color3.fromRGB(36, 125, 76) else Color3.fromRGB(165, 90, 38)
	reportToastLabel.Visible = true
	task.delay(7.0, function()
		if reportToastToken == myToken and reportToastLabel then
			reportToastLabel.Visible = false
		end
	end)
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
	if watchedTerminals[terminal] then
		return
	end
	watchedTerminals[terminal] = true
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

local function findNearestTerminalPos(hrpPos: Vector3): Vector3?
	local candidates: { Instance } = {}
	local direct = Workspace:FindFirstChild("RaidTerminal")
	if direct ~= nil then
		table.insert(candidates, direct)
	end
	for _, tagged in CollectionService:GetTagged("RaidTerminal") do
		table.insert(candidates, tagged)
	end
	local deep = Workspace:FindFirstChild("RaidTerminal", true)
	if deep ~= nil then
		table.insert(candidates, deep)
	end

	local bestPos: Vector3? = nil
	local bestDist = math.huge
	for _, inst in candidates do
		local pos: Vector3? = nil
		if inst:IsA("Model") then
			pos = if inst.PrimaryPart then inst.PrimaryPart.Position else inst:GetPivot().Position
		elseif inst:IsA("BasePart") then
			pos = inst.Position
		end
		if pos ~= nil then
			local d = (hrpPos - pos).Magnitude
			if d < bestDist then
				bestDist = d
				bestPos = pos
			end
		end
	end
	return bestPos
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
	if playerTierBadgeLabel then
		playerTierBadgeLabel.Text = string.format("Your Base: Tier %d", getLocalBaseTier())
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

	for _, desc in Workspace:GetDescendants() do
		if desc.Name == "RaidTerminal" or CollectionService:HasTag(desc, "RaidTerminal") then
			watchTerminal(desc)
		end
	end
	Workspace.DescendantAdded:Connect(function(desc: Instance)
		if desc.Name == "RaidTerminal" or CollectionService:HasTag(desc, "RaidTerminal") then
			watchTerminal(desc)
		end
	end)
	CollectionService:GetInstanceAddedSignal("RaidTerminal"):Connect(function(inst: Instance)
		if inst:IsDescendantOf(Workspace) then
			watchTerminal(inst)
		end
	end)

	Net.GetEvent(Net.Events.RaidListSync).OnClientEvent:Connect(onRaidListSync)
	Net.GetEvent(Net.Events.RaidHudSync).OnClientEvent:Connect(onRaidHudSync)
	Net.GetEvent(Net.Events.RaidReportNotify).OnClientEvent:Connect(onRaidReportNotify)

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
		if not hrp or not hrp:IsA("BasePart") then
			RaidController.CloseTargetList()
			return
		end

		local termPos = findNearestTerminalPos(hrp.Position)
		if termPos == nil or (hrp.Position - termPos).Magnitude > TERMINAL_MAX_DISTANCE then
			RaidController.CloseTargetList()
		end
	end)
end

return RaidController
