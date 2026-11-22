--!strict
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
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
local BlueprintController = require(script.Parent.BlueprintController)
local RecyclerController = require(script.Parent.RecyclerController)

type RaidTargetInfo = Types.RaidTargetInfo
type RaidHudState = Types.RaidHudState

local PLACE_RAY_DISTANCE = 60
local PLACE_COOLDOWN = 0.4
local TERMINAL_MAX_DISTANCE = 20

local TIER_LABELS: { [string]: string } = {
	wood = "Wood",
	stone = "Stone",
	metal = "Metal",
	armored = "Armored",
}

local currentHudState: RaidHudState? = nil
local cachedTargets: { RaidTargetInfo } = {}
local selectedTierFilter = 1
local currentFreeRefreshAt = 0
local currentRefreshCostScrap = Config.Raid.IntelPaidRefreshScrap
local isSelectionOpen = false
local lastPlaceTime = 0
local reportToastToken = 0
local isInitialized = false
local boundPrompts: { [ProximityPrompt]: boolean } = {}
local watchedTerminals: { [Instance]: boolean } = {}

local selectFrame: Frame? = nil
local selectStatusLabel: TextLabel? = nil
local playerTierBadgeLabel: TextLabel? = nil
local freeRefreshButton: TextButton? = nil
local paidRefreshButton: TextButton? = nil
local targetListContainer: ScrollingFrame? = nil
local tierFilterButtons: { [number]: TextButton } = {}
local hudFrame: Frame? = nil
local hudStatusLabel: TextLabel? = nil
local hudMetaLabel: TextLabel? = nil
local extractButton: TextButton? = nil
local abandonButton: TextButton? = nil
local reportToastLabel: TextLabel? = nil
local alarmFrame: Frame? = nil
local alarmBodyLabel: TextLabel? = nil
local alarmTimerLabel: TextLabel? = nil
local prepOverlayFrame: Frame? = nil
local prepTimerLabel: TextLabel? = nil

local activeAlarmRaidId: string? = nil
local activeAlarmExpiresAt = 0
local activePrepEndsAt = 0

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
	return isSelectionOpen
		or InventoryUIController.IsOpen()
		or CraftingController.IsOpen()
		or LootController.IsOpen()
		or BlueprintController.IsOpen()
		or RecyclerController.IsOpen()
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
	row.Size = UDim2.new(1, -8, 0, 102)
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
	local tagText = if target.IsPreset then "[Intel] " else "[Player] "
	nameLabel.Text =
		string.format("%s%s  |  Tier %d (%d blocks)", tagText, target.DisplayName, targetTier, target.PieceCount)
	nameLabel.Parent = row

	local matName = if target.DominantTier ~= nil
		then (TIER_LABELS[target.DominantTier] or target.DominantTier)
		else "Mixed"
	local usedDef = target.UsedDefenseCapacity or 0
	local maxDef = target.MaxDefenseCapacity or 60
	local turrets = target.TurretCount or 0
	local traps = target.TrapCount or 0

	local intelLabel = Instance.new("TextLabel")
	intelLabel.Name = "IntelSummary"
	intelLabel.Position = UDim2.fromOffset(12, 27)
	intelLabel.Size = UDim2.new(1, -156, 0, 18)
	intelLabel.BackgroundTransparency = 1
	intelLabel.Font = Enum.Font.GothamMedium
	intelLabel.TextSize = 11
	intelLabel.TextColor3 = Color3.fromRGB(165, 215, 245)
	intelLabel.TextXAlignment = Enum.TextXAlignment.Left
	intelLabel.TextTruncate = Enum.TextTruncate.AtEnd
	intelLabel.Text = string.format(
		"Walls: %s  |  Defense: %d/%d  |  Turrets: %d  Traps: %d",
		matName,
		usedDef,
		maxDef,
		turrets,
		traps
	)
	intelLabel.Parent = row

	local lootLabel = Instance.new("TextLabel")
	lootLabel.Name = "LootInfo"
	lootLabel.Position = UDim2.fromOffset(12, 47)
	lootLabel.Size = UDim2.new(1, -156, 0, 16)
	lootLabel.BackgroundTransparency = 1
	lootLabel.Font = Enum.Font.Gotham
	lootLabel.TextSize = 11
	lootLabel.TextColor3 = Color3.fromRGB(235, 185, 110)
	lootLabel.TextXAlignment = Enum.TextXAlignment.Left
	lootLabel.TextTruncate = Enum.TextTruncate.AtEnd
	lootLabel.Text = string.format("Loot Intel: %s", target.LootCategory or target.RewardLabel or "Base Loot")
	lootLabel.Parent = row

	local costLabel = Instance.new("TextLabel")
	costLabel.Name = "CostInfo"
	costLabel.Position = UDim2.fromOffset(12, 68)
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

local function updateRefreshButtonsVisual()
	local nowUnix = os.time()
	local freeRem = math.max(0, math.floor(currentFreeRefreshAt - nowUnix))
	if freeRefreshButton then
		if freeRem <= 0 then
			freeRefreshButton.Text = "Free Reroll"
			freeRefreshButton.BackgroundColor3 = Color3.fromRGB(52, 125, 76)
		else
			freeRefreshButton.Text = string.format("Free %02d:%02d", math.floor(freeRem / 60), freeRem % 60)
			freeRefreshButton.BackgroundColor3 = Color3.fromRGB(52, 54, 66)
		end
	end
	if paidRefreshButton then
		local ownedScrap = countOwnedItem("scrap")
		local canPay = ownedScrap >= currentRefreshCostScrap
		paidRefreshButton.Text = string.format("Reroll (%d Scrap)", currentRefreshCostScrap)
		paidRefreshButton.BackgroundColor3 = if canPay then Color3.fromRGB(165, 115, 42) else Color3.fromRGB(64, 60, 66)
	end
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
	updateRefreshButtonsVisual()

	local filtered: { RaidTargetInfo } = {}
	for _, target in cachedTargets do
		local tTier = math.clamp(target.BaseTier or 1, 1, 3)
		if tTier == selectedTierFilter then
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
		selectStatusLabel.Text = string.format("Scouted Tier %d Intel (%d / 3 cards):", selectedTierFilter, #filtered)
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
	modal.Size = UDim2.fromOffset(600, 476)
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
	titleLbl.Size = UDim2.new(1, -390, 0, 26)
	titleLbl.BackgroundTransparency = 1
	titleLbl.Font = Enum.Font.GothamBold
	titleLbl.TextSize = 16
	titleLbl.TextColor3 = Color3.fromRGB(255, 220, 220)
	titleLbl.TextXAlignment = Enum.TextXAlignment.Left
	titleLbl.Text = "RAID INTEL"
	titleLbl.Parent = modal

	local tierBadge = Instance.new("TextLabel")
	tierBadge.Name = "YourTierBadge"
	tierBadge.AnchorPoint = Vector2.new(1, 0)
	tierBadge.Position = UDim2.new(1, -264, 0, 10)
	tierBadge.Size = UDim2.fromOffset(112, 28)
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

	local freeBtn = Instance.new("TextButton")
	freeBtn.Name = "FreeRefreshButton"
	freeBtn.AnchorPoint = Vector2.new(1, 0)
	freeBtn.Position = UDim2.new(1, -162, 0, 10)
	freeBtn.Size = UDim2.fromOffset(96, 28)
	freeBtn.BackgroundColor3 = Color3.fromRGB(52, 54, 66)
	freeBtn.BorderSizePixel = 0
	freeBtn.Font = Enum.Font.GothamBold
	freeBtn.TextSize = 11
	freeBtn.TextColor3 = Color3.fromRGB(235, 235, 240)
	freeBtn.Text = "Free 10:00"
	freeBtn.Parent = modal
	local freeCorner = Instance.new("UICorner")
	freeCorner.CornerRadius = UDim.new(0, 6)
	freeCorner.Parent = freeBtn
	freeBtn.MouseButton1Click:Connect(function()
		Net.GetEvent(Net.Events.RaidRefreshRequest):FireServer(selectedTierFilter, false)
	end)

	local paidBtn = Instance.new("TextButton")
	paidBtn.Name = "PaidRefreshButton"
	paidBtn.AnchorPoint = Vector2.new(1, 0)
	paidBtn.Position = UDim2.new(1, -48, 0, 10)
	paidBtn.Size = UDim2.fromOffset(108, 28)
	paidBtn.BackgroundColor3 = Color3.fromRGB(165, 115, 42)
	paidBtn.BorderSizePixel = 0
	paidBtn.Font = Enum.Font.GothamBold
	paidBtn.TextSize = 11
	paidBtn.TextColor3 = Color3.new(1, 1, 1)
	paidBtn.Text = string.format("Reroll (%d Scrap)", Config.Raid.IntelPaidRefreshScrap)
	paidBtn.Parent = modal
	local paidCorner = Instance.new("UICorner")
	paidCorner.CornerRadius = UDim.new(0, 6)
	paidCorner.Parent = paidBtn
	paidBtn.MouseButton1Click:Connect(function()
		Net.GetEvent(Net.Events.RaidRefreshRequest):FireServer(selectedTierFilter, true)
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
		{ Tier = 1, Label = "Tier 1" },
		{ Tier = 2, Label = "Tier 2" },
		{ Tier = 3, Label = "Tier 3" },
	}
	for idx, def in filterDefs do
		local fBtn = Instance.new("TextButton")
		fBtn.Name = string.format("FilterTier_%d", def.Tier)
		fBtn.LayoutOrder = idx
		fBtn.Size = UDim2.fromOffset(108, 26)
		fBtn.BackgroundColor3 = if def.Tier == 1 then Color3.fromRGB(175, 55, 55) else Color3.fromRGB(48, 50, 60)
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
			Net.GetEvent(Net.Events.RaidListRequest):FireServer(selectedTierFilter)
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
	freeRefreshButton = freeBtn
	paidRefreshButton = paidBtn
	targetListContainer = scroller

	-- 4. Active Raid Defense Alarm prompt (15s)
	local aFrame = Instance.new("Frame")
	aFrame.Name = "RaidAlarmFrame"
	aFrame.AnchorPoint = Vector2.new(0.5, 0)
	aFrame.Position = UDim2.new(0.5, 0, 0, 86)
	aFrame.Size = UDim2.fromOffset(470, 148)
	aFrame.BackgroundColor3 = Color3.fromRGB(34, 16, 20)
	aFrame.BackgroundTransparency = 0.05
	aFrame.BorderSizePixel = 0
	aFrame.Visible = false
	aFrame.Parent = screenGui

	local aCorner = Instance.new("UICorner")
	aCorner.CornerRadius = UDim.new(0, 10)
	aCorner.Parent = aFrame

	local aStroke = Instance.new("UIStroke")
	aStroke.Color = Color3.fromRGB(245, 75, 75)
	aStroke.Thickness = 2
	aStroke.Parent = aFrame

	local aTitle = Instance.new("TextLabel")
	aTitle.Name = "AlarmTitle"
	aTitle.Position = UDim2.fromOffset(16, 10)
	aTitle.Size = UDim2.new(1, -32, 0, 24)
	aTitle.BackgroundTransparency = 1
	aTitle.Font = Enum.Font.GothamBold
	aTitle.TextSize = 16
	aTitle.TextColor3 = Color3.fromRGB(255, 110, 110)
	aTitle.TextXAlignment = Enum.TextXAlignment.Left
	aTitle.Text = "ТРЕВОГА: БАЗА ПОД АТАКОЙ!"
	aTitle.Parent = aFrame

	local aBody = Instance.new("TextLabel")
	aBody.Name = "AlarmBody"
	aBody.Position = UDim2.fromOffset(16, 36)
	aBody.Size = UDim2.new(1, -32, 0, 38)
	aBody.BackgroundTransparency = 1
	aBody.Font = Enum.Font.GothamMedium
	aBody.TextSize = 13
	aBody.TextColor3 = Color3.fromRGB(245, 245, 250)
	aBody.TextWrapped = true
	aBody.TextXAlignment = Enum.TextXAlignment.Left
	aBody.Text = "Вашу базу штурмуют! Вернуться к обороне?"
	aBody.Parent = aFrame

	local aTimer = Instance.new("TextLabel")
	aTimer.Name = "AlarmTimer"
	aTimer.Position = UDim2.fromOffset(16, 76)
	aTimer.Size = UDim2.new(1, -32, 0, 20)
	aTimer.BackgroundTransparency = 1
	aTimer.Font = Enum.Font.GothamBold
	aTimer.TextSize = 12
	aTimer.TextColor3 = Color3.fromRGB(255, 210, 105)
	aTimer.TextXAlignment = Enum.TextXAlignment.Left
	aTimer.Text = "Осталось времени: 15с"
	aTimer.Parent = aFrame

	local acceptBtn = Instance.new("TextButton")
	acceptBtn.Name = "AcceptDefenseButton"
	acceptBtn.Position = UDim2.fromOffset(16, 102)
	acceptBtn.Size = UDim2.fromOffset(210, 34)
	acceptBtn.BackgroundColor3 = Color3.fromRGB(40, 155, 82)
	acceptBtn.BorderSizePixel = 0
	acceptBtn.Font = Enum.Font.GothamBold
	acceptBtn.TextSize = 13
	acceptBtn.TextColor3 = Color3.new(1, 1, 1)
	acceptBtn.Text = "Защищать базу"
	acceptBtn.Parent = aFrame
	local accCorner = Instance.new("UICorner")
	accCorner.CornerRadius = UDim.new(0, 6)
	accCorner.Parent = acceptBtn
	acceptBtn.MouseButton1Click:Connect(function()
		if activeAlarmRaidId ~= nil then
			local rid = activeAlarmRaidId
			activeAlarmRaidId = nil
			activeAlarmExpiresAt = 0
			aFrame.Visible = false
			Net.GetEvent(Net.Events.RaidAlarmResponse):FireServer(true, rid)
		end
	end)

	local declineBtn = Instance.new("TextButton")
	declineBtn.Name = "DeclineDefenseButton"
	declineBtn.Position = UDim2.fromOffset(244, 102)
	declineBtn.Size = UDim2.fromOffset(210, 34)
	declineBtn.BackgroundColor3 = Color3.fromRGB(78, 82, 92)
	declineBtn.BorderSizePixel = 0
	declineBtn.Font = Enum.Font.GothamBold
	declineBtn.TextSize = 13
	declineBtn.TextColor3 = Color3.new(1, 1, 1)
	declineBtn.Text = "Игнорировать"
	declineBtn.Parent = aFrame
	local decCorner = Instance.new("UICorner")
	decCorner.CornerRadius = UDim.new(0, 6)
	decCorner.Parent = declineBtn
	declineBtn.MouseButton1Click:Connect(function()
		local rid = activeAlarmRaidId
		activeAlarmRaidId = nil
		activeAlarmExpiresAt = 0
		aFrame.Visible = false
		if rid ~= nil then
			Net.GetEvent(Net.Events.RaidAlarmResponse):FireServer(false, rid)
		end
	end)

	-- 5. Active Raid Defense 6s Prep screen
	local pFrame = Instance.new("Frame")
	pFrame.Name = "DefensePrepOverlay"
	pFrame.AnchorPoint = Vector2.new(0.5, 0.5)
	pFrame.Position = UDim2.fromScale(0.5, 0.42)
	pFrame.Size = UDim2.fromOffset(440, 140)
	pFrame.BackgroundColor3 = Color3.fromRGB(16, 22, 34)
	pFrame.BackgroundTransparency = 0.06
	pFrame.BorderSizePixel = 0
	pFrame.Visible = false
	pFrame.Parent = screenGui

	local pCorner = Instance.new("UICorner")
	pCorner.CornerRadius = UDim.new(0, 12)
	pCorner.Parent = pFrame

	local pStroke = Instance.new("UIStroke")
	pStroke.Color = Color3.fromRGB(85, 195, 255)
	pStroke.Thickness = 2
	pStroke.Parent = pFrame

	local pTitle = Instance.new("TextLabel")
	pTitle.Name = "PrepTitle"
	pTitle.Position = UDim2.fromOffset(16, 16)
	pTitle.Size = UDim2.new(1, -32, 0, 28)
	pTitle.BackgroundTransparency = 1
	pTitle.Font = Enum.Font.GothamBold
	pTitle.TextSize = 18
	pTitle.TextColor3 = Color3.fromRGB(120, 220, 255)
	pTitle.Text = "ПОДГОТОВКА К ОБОРОНЕ"
	pTitle.Parent = pFrame

	local pTimer = Instance.new("TextLabel")
	pTimer.Name = "PrepTimer"
	pTimer.Position = UDim2.fromOffset(16, 52)
	pTimer.Size = UDim2.new(1, -32, 0, 32)
	pTimer.BackgroundTransparency = 1
	pTimer.Font = Enum.Font.GothamBold
	pTimer.TextSize = 22
	pTimer.TextColor3 = Color3.new(1, 1, 1)
	pTimer.Text = "Телепортация к TC через 6с..."
	pTimer.Parent = pFrame

	local pSub = Instance.new("TextLabel")
	pSub.Name = "PrepSub"
	pSub.Position = UDim2.fromOffset(16, 92)
	pSub.Size = UDim2.new(1, -32, 0, 30)
	pSub.BackgroundTransparency = 1
	pSub.Font = Enum.Font.Gotham
	pSub.TextSize = 12
	pSub.TextColor3 = Color3.fromRGB(190, 210, 230)
	pSub.TextWrapped = true
	pSub.Text = "Подготовка боекомплекта из хранилища TC и инвентаря"
	pSub.Parent = pFrame

	alarmFrame = aFrame
	alarmBodyLabel = aBody
	alarmTimerLabel = aTimer
	prepOverlayFrame = pFrame
	prepTimerLabel = pTimer

	screenGui.Parent = playerGui
end

local function onRaidListSync(payloadAny: any)
	table.clear(cachedTargets)

	if type(payloadAny) ~= "table" then
		refreshTargetListUi()
		return
	end

	local rawTargets = payloadAny
	if type(payloadAny.Targets) == "table" then
		rawTargets = payloadAny.Targets
		if typeof(payloadAny.Tier) == "number" then
			selectedTierFilter = math.clamp(math.floor(payloadAny.Tier), 1, 3)
		end
		if typeof(payloadAny.FreeRefreshAt) == "number" then
			currentFreeRefreshAt = math.floor(payloadAny.FreeRefreshAt)
		end
		if typeof(payloadAny.RefreshCostScrap) == "number" then
			currentRefreshCostScrap = math.floor(payloadAny.RefreshCostScrap)
		end
	end

	for _, entry in rawTargets do
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
				DominantTier = if typeof(entry.DominantTier) == "string"
					then entry.DominantTier :: Types.BuildTier
					else nil,
				UsedDefenseCapacity = if typeof(entry.UsedDefenseCapacity) == "number"
					then entry.UsedDefenseCapacity
					else nil,
				MaxDefenseCapacity = if typeof(entry.MaxDefenseCapacity) == "number"
					then entry.MaxDefenseCapacity
					else nil,
				TurretCount = if typeof(entry.TurretCount) == "number" then entry.TurretCount else nil,
				TrapCount = if typeof(entry.TrapCount) == "number" then entry.TrapCount else nil,
				LootCategory = if typeof(entry.LootCategory) == "string" then entry.LootCategory else nil,
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
	local extractionActive = stateAny.ExtractionActive == true
	local extractionTimeLeft = if typeof(stateAny.ExtractionTimeLeft) == "number"
		then stateAny.ExtractionTimeLeft
		else 0
	local extractionTotalTime = if typeof(stateAny.ExtractionTotalTime) == "number"
		then stateAny.ExtractionTotalTime
		else Config.Raid.StashExtractionDuration

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
		ExtractionActive = extractionActive,
		ExtractionTimeLeft = extractionTimeLeft,
		ExtractionTotalTime = extractionTotalTime,
	}
	currentHudState = state

	if hudFrame and hudStatusLabel then
		local tierTag = if targetTier ~= nil then string.format(" [T%d]", targetTier) else ""
		if extractionActive then
			hudStatusLabel.Text =
				string.format("STASH EXTRACTION (%ds) | %s%s", extractionTimeLeft, targetName, tierTag)
		elseif statusText ~= nil then
			hudStatusLabel.Text = string.format("RAIDING %s%s | %s", targetName, tierTag, statusText)
		else
			hudStatusLabel.Text =
				string.format("RAIDING %s%s | Time: %s", targetName, tierTag, formatTimeMMSS(timeLeft))
		end

		if hudMetaLabel then
			local tcText = if extractionActive
				then string.format(
					"Сирена активна! Выжить %ds/%ds",
					extractionTimeLeft,
					extractionTotalTime
				)
				elseif tcCaptured then "TC Captured — Extract Available"
				elseif tcHackActive then string.format("Hacking TC: %d%%", math.floor(tcHackProgress * 100 + 0.5))
				else "TC: Active (Hack or Destroy)"
			hudMetaLabel.Text =
				string.format("Lives: %d/%d  |  Stash: %d  |  %s", livesLeft, maxLives, stashCount, tcText)
			hudMetaLabel.TextColor3 = if extractionActive
				then Color3.fromRGB(255, 225, 110)
				elseif tcCaptured then Color3.fromRGB(130, 245, 165)
				elseif tcHackActive then Color3.fromRGB(255, 220, 115)
				else Color3.fromRGB(255, 210, 195)
		end

		if extractButton then
			if extractionActive then
				extractButton.BackgroundColor3 = Color3.fromRGB(205, 65, 55)
				extractButton.Text = string.format("Extracting %ds", extractionTimeLeft)
			else
				extractButton.BackgroundColor3 = if canExtract
					then Color3.fromRGB(36, 155, 82)
					else Color3.fromRGB(70, 74, 82)
				extractButton.Text = if canExtract then "Extract (18s)" else "TC Required"
			end
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

local function onRaidAlarmNotify(payloadAny: any)
	if type(payloadAny) ~= "table" then
		return
	end
	local phase = if typeof(payloadAny.Phase) == "string" then payloadAny.Phase else "Prompt"
	local raidId = if typeof(payloadAny.RaidId) == "string" then payloadAny.RaidId else ""

	if phase == "Prompt" then
		local raiderName = if typeof(payloadAny.RaiderName) == "string" then payloadAny.RaiderName else "Raider"
		local tier = if typeof(payloadAny.TargetBaseTier) == "number" then payloadAny.TargetBaseTier else 1
		local acceptDur = if typeof(payloadAny.AcceptDuration) == "number"
			then payloadAny.AcceptDuration
			else Config.Raid.ActiveDefensePromptDuration
		activeAlarmRaidId = raidId
		activeAlarmExpiresAt = os.clock() + acceptDur
		if alarmBodyLabel then
			alarmBodyLabel.Text = string.format(
				"Вашу базу (Tier %d) штурмует %s! Вернуться к обороне?",
				tier,
				raiderName
			)
		end
		if alarmTimerLabel then
			alarmTimerLabel.Text = string.format("Осталось времени: %dс", math.ceil(acceptDur))
		end
		if alarmFrame then
			alarmFrame.Visible = true
		end
		if prepOverlayFrame then
			prepOverlayFrame.Visible = false
		end
		local alarmSound = Instance.new("Sound")
		alarmSound.SoundId = "rbxasset://sounds/action_falling.ogg"
		alarmSound.Volume = 0.7
		alarmSound.PlaybackSpeed = 1.6
		alarmSound.Parent = SoundService
		alarmSound:Play()
		alarmSound.Ended:Once(function()
			alarmSound:Destroy()
		end)
		task.delay(2.5, function()
			if alarmSound.Parent then
				alarmSound:Destroy()
			end
		end)
	elseif phase == "Prep" then
		local prepDur = if typeof(payloadAny.PrepDuration) == "number"
			then payloadAny.PrepDuration
			else Config.Raid.ActiveDefensePrepDuration
		activeAlarmRaidId = nil
		activeAlarmExpiresAt = 0
		activePrepEndsAt = os.clock() + prepDur
		if alarmFrame then
			alarmFrame.Visible = false
		end
		if prepTimerLabel then
			prepTimerLabel.Text = string.format("Телепортация к TC через %dс...", math.ceil(prepDur))
		end
		if prepOverlayFrame then
			prepOverlayFrame.Visible = true
		end
	elseif phase == "Active" or phase == "Ended" then
		activeAlarmRaidId = nil
		activeAlarmExpiresAt = 0
		activePrepEndsAt = 0
		if alarmFrame then
			alarmFrame.Visible = false
		end
		if prepOverlayFrame then
			prepOverlayFrame.Visible = false
		end
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
	selectedTierFilter = math.clamp(getLocalBaseTier(), 1, 3)
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
		selectStatusLabel.Text = "Scouting 3 raid targets..."
	end
	clearTargetRows()
	updateRefreshButtonsVisual()
	Net.GetEvent(Net.Events.RaidListRequest):FireServer(selectedTierFilter)
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
	Net.GetEvent(Net.Events.RaidAlarmNotify).OnClientEvent:Connect(onRaidAlarmNotify)

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

	local lastTimerTick = 0
	RunService.Heartbeat:Connect(function()
		local now = os.clock()
		if activeAlarmRaidId ~= nil and alarmFrame and alarmFrame.Visible then
			local rem = activeAlarmExpiresAt - now
			if rem <= 0 then
				activeAlarmRaidId = nil
				activeAlarmExpiresAt = 0
				alarmFrame.Visible = false
			elseif alarmTimerLabel then
				alarmTimerLabel.Text = string.format("Осталось времени: %dс", math.ceil(rem))
			end
		end
		if activePrepEndsAt > 0 and prepOverlayFrame and prepOverlayFrame.Visible then
			local prepRem = activePrepEndsAt - now
			if prepRem <= 0 then
				activePrepEndsAt = 0
				prepOverlayFrame.Visible = false
			elseif prepTimerLabel then
				prepTimerLabel.Text =
					string.format("Телепортация к TC через %dс...", math.ceil(prepRem))
			end
		end

		if not isSelectionOpen then
			return
		end
		if (now - lastTimerTick) >= 1.0 then
			lastTimerTick = now
			updateRefreshButtonsVisual()
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
