--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Config = require(ReplicatedStorage.Shared.Config)
local Types = require(ReplicatedStorage.Shared.Types)
local Items = require(ReplicatedStorage.Shared.configs.Items)
local Net = require(ReplicatedStorage.Shared.Net)
local InventoryController = require(script.Parent.InventoryController)

type Inventory = Types.Inventory
type ToolCupboardState = Types.ToolCupboardState
type DefenseLogEntry = Types.DefenseLogEntry
type BaseBlueprintSummary = Types.BaseBlueprintSummary

type TcSlotUI = {
	Index: number,
	Button: TextButton,
	NameLabel: TextLabel,
	CountLabel: TextLabel,
}

type DepositButtonUI = {
	ResourceId: string,
	Button: TextButton,
}

local COLOR_BG = Color3.fromRGB(20, 22, 28)
local COLOR_SLOT = Color3.fromRGB(34, 38, 46)
local COLOR_STROKE = Color3.fromRGB(78, 84, 98)
local COLOR_OK = Color3.fromRGB(95, 225, 130)
local COLOR_WARN = Color3.fromRGB(240, 185, 80)
local COLOR_BAD = Color3.fromRGB(235, 85, 85)

local mainFrame: Frame? = nil
local tierBadgeLabel: TextLabel? = nil
local statusBadgeLabel: TextLabel? = nil
local pathBadgeLabel: TextLabel? = nil
local upkeepLabel: TextLabel? = nil
local defenseCapLabel: TextLabel? = nil
local tabUpkeepBtn: TextButton? = nil
local tabBlueprintsBtn: TextButton? = nil
local upkeepTabFrame: Frame? = nil
local blueprintsTabFrame: Frame? = nil
local blueprintsListFrame: ScrollingFrame? = nil
local defenseLogListFrame: ScrollingFrame? = nil
local slotUIs: { TcSlotUI } = {}
local depositButtons: { DepositButtonUI } = {}
local currentState: ToolCupboardState? = nil
local activeTab: "Upkeep" | "Blueprints" = "Upkeep"
local isOpen = false
local isInitialized = false

local ToolCupboardController = {}

local function formatProtectedTime(hours: number): string
	if hours <= 0 then
		return "0m"
	end
	local totalMinutes = math.floor(hours * 60 + 0.5)
	local h = math.floor(totalMinutes / 60)
	local m = totalMinutes % 60
	if h > 0 then
		return string.format("%dh %dm", h, m)
	end
	return string.format("%dm", m)
end

local function formatBlueprintCost(costMap: { [string]: number }?): string
	if costMap == nil then
		return "—"
	end
	local parts: { string } = {}
	for resId, amt in costMap do
		if amt > 0 then
			local itemCfg = Items[resId]
			local name = if itemCfg then itemCfg.Name else resId
			table.insert(parts, string.format("%d %s", amt, name))
		end
	end
	if #parts == 0 then
		return "—"
	end
	table.sort(parts)
	return table.concat(parts, ", ")
end

local function countInventoryResource(resourceId: string): (number, number?)
	local inv = InventoryController.GetInventory()
	local total = 0
	local firstSlot: number? = nil
	for i = 1, Types.INVENTORY_SIZE do
		local slot = inv[i]
		if slot ~= nil and slot.Id == resourceId and slot.Count > 0 then
			total += slot.Count
			if firstSlot == nil then
				firstSlot = i
			end
		end
	end
	return total, firstSlot
end

local function parseTcSlots(rawSlots: any): Inventory
	local slots: Inventory = {}
	if type(rawSlots) ~= "table" then
		return slots
	end
	local maxSlots = Config.Upkeep.TcStorageSlots
	for k, v in rawSlots do
		local index = if type(k) == "number" then k else tonumber(k)
		if
			index ~= nil
			and index >= 1
			and index <= maxSlots
			and index % 1 == 0
			and type(v) == "table"
			and type(v.Id) == "string"
			and type(v.Count) == "number"
			and v.Count > 0
		then
			slots[index] = {
				Id = v.Id,
				Count = math.floor(v.Count),
			}
		end
	end
	return slots
end

local function refreshUi()
	if not mainFrame then
		return
	end
	mainFrame.Visible = isOpen and currentState ~= nil
	if not isOpen or currentState == nil then
		return
	end

	local state = currentState :: ToolCupboardState
	if tierBadgeLabel then
		tierBadgeLabel.Text = string.format("Base Tier: Tier %d", state.BaseTier)
		tierBadgeLabel.TextColor3 = if state.BaseTier >= 3
			then Color3.fromRGB(110, 220, 255)
			elseif state.BaseTier == 2 then COLOR_WARN
			elseif state.BaseTier == 1 then COLOR_OK
			else COLOR_BAD
	end

	if statusBadgeLabel then
		if state.Status == "Protected" then
			statusBadgeLabel.Text = string.format("Protected (%s)", formatProtectedTime(state.ProtectedHours))
			statusBadgeLabel.TextColor3 = COLOR_OK
		else
			statusBadgeLabel.Text = "Decaying!"
			statusBadgeLabel.TextColor3 = COLOR_BAD
		end
	end

	if pathBadgeLabel then
		local badgeText = state.PathMessage
		if state.PathValid then
			pathBadgeLabel.Text = if badgeText ~= nil and #badgeText > 0
				then badgeText
				else "TC Protection: Valid (<= 2 layers)"
			pathBadgeLabel.TextColor3 = COLOR_OK
		else
			pathBadgeLabel.Text = if badgeText ~= nil and #badgeText > 0 then badgeText else "TC Protection: > 2 layers"
			pathBadgeLabel.TextColor3 = COLOR_BAD
		end
	end

	if upkeepLabel then
		local parts: { string } = {}
		for _, resId in Config.Upkeep.AllowedResourceIds do
			local rate = state.HourlyUpkeep[resId] or 0
			local itemCfg = Items[resId]
			local name = if itemCfg then itemCfg.Name else resId
			table.insert(parts, string.format("%s: %d/h", name, rate))
		end
		upkeepLabel.Text = string.format("Upkeep: %s", table.concat(parts, " | "))
	end

	if defenseCapLabel then
		local used = state.DefenseUsed or 0
		local maxCap = state.DefenseMax or 60
		defenseCapLabel.Text = string.format("Защита базы: %d / %d очков", used, maxCap)
		defenseCapLabel.TextColor3 = if used >= maxCap
			then COLOR_BAD
			elseif used >= math.floor(maxCap * 0.8) then COLOR_WARN
			else COLOR_OK
	end

	local isUpkeepTab = (activeTab == "Upkeep")
	if upkeepTabFrame then
		upkeepTabFrame.Visible = isUpkeepTab
	end
	if blueprintsTabFrame then
		blueprintsTabFrame.Visible = not isUpkeepTab
	end
	if tabUpkeepBtn then
		tabUpkeepBtn.BackgroundColor3 = if isUpkeepTab then Color3.fromRGB(58, 96, 138) else Color3.fromRGB(34, 38, 46)
	end
	if tabBlueprintsBtn then
		tabBlueprintsBtn.BackgroundColor3 = if not isUpkeepTab
			then Color3.fromRGB(58, 96, 138)
			else Color3.fromRGB(34, 38, 46)
	end

	if blueprintsListFrame then
		for _, child in blueprintsListFrame:GetChildren() do
			if child:IsA("Frame") or child:IsA("TextLabel") then
				child:Destroy()
			end
		end
		local bps = state.Blueprints or {}
		local playerSlotIndex = 0
		for idx, bp in bps do
			if not bp.IsBuiltin then
				playerSlotIndex += 1
			end
			local capturedSlotIdx = playerSlotIndex
			local card = Instance.new("Frame")
			card.Name = string.format("BlueprintCard_%s", bp.Id)
			card.LayoutOrder = idx
			card.Size = UDim2.new(1, -8, 0, 92)
			card.BackgroundColor3 = if bp.IsBuiltin then Color3.fromRGB(28, 42, 58) else Color3.fromRGB(30, 34, 42)
			card.BorderSizePixel = 0
			card.Parent = blueprintsListFrame

			local cardCorner = Instance.new("UICorner")
			cardCorner.CornerRadius = UDim.new(0, 8)
			cardCorner.Parent = card

			local cardStroke = Instance.new("UIStroke")
			cardStroke.Color = if bp.IsBuiltin then Color3.fromRGB(85, 145, 215) else Color3.fromRGB(68, 76, 92)
			cardStroke.Thickness = 1.2
			cardStroke.Parent = card

			local titleLbl = Instance.new("TextLabel")
			titleLbl.Position = UDim2.fromOffset(10, 8)
			titleLbl.Size = UDim2.new(1, -20, 0, 20)
			titleLbl.BackgroundTransparency = 1
			titleLbl.Font = Enum.Font.GothamBold
			titleLbl.TextSize = 13
			titleLbl.TextXAlignment = Enum.TextXAlignment.Left
			titleLbl.TextColor3 = Color3.fromRGB(240, 244, 250)
			titleLbl.Text = if bp.IsBuiltin then string.format("[Шаблон] %s", bp.Name) else bp.Name
			titleLbl.Parent = card

			local infoLbl = Instance.new("TextLabel")
			infoLbl.Position = UDim2.fromOffset(10, 30)
			infoLbl.Size = UDim2.new(1, -20, 0, 20)
			infoLbl.BackgroundTransparency = 1
			infoLbl.Font = Enum.Font.GothamMedium
			infoLbl.TextSize = 11
			infoLbl.TextXAlignment = Enum.TextXAlignment.Left
			infoLbl.TextTruncate = Enum.TextTruncate.AtEnd
			infoLbl.TextColor3 = Color3.fromRGB(185, 198, 218)
			infoLbl.Text = if bp.HasData
				then string.format("Модулей: %d | Цена: %s", bp.PieceCount, formatBlueprintCost(bp.Cost))
				else "Пустой слот — сохраните текущую базу относительно TC"
			infoLbl.Parent = card

			if not bp.IsBuiltin then
				local saveBtn = Instance.new("TextButton")
				saveBtn.Name = "SaveButton"
				saveBtn.Position = UDim2.fromOffset(10, 56)
				saveBtn.Size = UDim2.fromOffset(170, 28)
				saveBtn.BackgroundColor3 = Color3.fromRGB(48, 108, 72)
				saveBtn.BorderSizePixel = 0
				saveBtn.Font = Enum.Font.GothamBold
				saveBtn.TextSize = 11
				saveBtn.TextColor3 = Color3.new(1, 1, 1)
				saveBtn.Text = if bp.HasData
					then "Перезаписать базу"
					else "Сохранить текущую базу"
				saveBtn.Parent = card
				local sc = Instance.new("UICorner")
				sc.CornerRadius = UDim.new(0, 6)
				sc.Parent = saveBtn
				saveBtn.Activated:Connect(function()
					Net.GetEvent(Net.Events.ToolCupboardAction):FireServer("SaveBlueprint", capturedSlotIdx)
				end)
			end

			local loadBtn = Instance.new("TextButton")
			loadBtn.Name = "LoadButton"
			loadBtn.AnchorPoint = Vector2.new(1, 0)
			loadBtn.Position = UDim2.new(1, -10, 0, 56)
			loadBtn.Size = UDim2.fromOffset(if bp.IsBuiltin then 210 else 170, 28)
			loadBtn.BackgroundColor3 = if bp.HasData then Color3.fromRGB(58, 118, 185) else Color3.fromRGB(45, 48, 56)
			loadBtn.BorderSizePixel = 0
			loadBtn.Font = Enum.Font.GothamBold
			loadBtn.TextSize = 11
			loadBtn.TextColor3 = if bp.HasData then Color3.new(1, 1, 1) else Color3.fromRGB(135, 140, 150)
			loadBtn.Text = if bp.IsBuiltin
				then "Построить шаблон 2x2"
				else "Загрузить планировку"
			loadBtn.Active = bp.HasData
			loadBtn.Parent = card
			local lc = Instance.new("UICorner")
			lc.CornerRadius = UDim.new(0, 6)
			lc.Parent = loadBtn
			loadBtn.Activated:Connect(function()
				if bp.HasData then
					Net.GetEvent(Net.Events.ToolCupboardAction):FireServer("LoadBlueprint", bp.Id)
				end
			end)
		end
	end

	for _, ui in slotUIs do
		local slot = state.Slots[ui.Index]
		if slot ~= nil and slot.Count > 0 then
			local itemCfg = Items[slot.Id]
			ui.NameLabel.Text = if itemCfg then itemCfg.Name else slot.Id
			ui.CountLabel.Text = string.format("x%d", slot.Count)
		else
			ui.NameLabel.Text = ""
			ui.CountLabel.Text = ""
		end
	end

	for _, dep in depositButtons do
		local total, _ = countInventoryResource(dep.ResourceId)
		local itemCfg = Items[dep.ResourceId]
		local label = if itemCfg then itemCfg.Name else dep.ResourceId
		dep.Button.Text = string.format("+ %s (%d)", label, total)
		dep.Button.BackgroundColor3 = if total > 0 then Color3.fromRGB(48, 88, 60) else Color3.fromRGB(40, 42, 48)
		dep.Button.TextColor3 = if total > 0 then Color3.new(1, 1, 1) else Color3.fromRGB(150, 155, 165)
	end

	if defenseLogListFrame then
		for _, child in defenseLogListFrame:GetChildren() do
			if child:IsA("Frame") or child:IsA("TextLabel") then
				child:Destroy()
			end
		end
		local logs = state.DefenseLogs
		if logs == nil or #logs == 0 then
			local emptyLbl = Instance.new("TextLabel")
			emptyLbl.Name = "EmptyLogsLabel"
			emptyLbl.Size = UDim2.new(1, -8, 0, 26)
			emptyLbl.BackgroundTransparency = 1
			emptyLbl.Font = Enum.Font.Gotham
			emptyLbl.TextSize = 11
			emptyLbl.TextColor3 = Color3.fromRGB(155, 165, 180)
			emptyLbl.Text =
				"Журнал обороны пуст (последние 5 атак появятся здесь)"
			emptyLbl.Parent = defenseLogListFrame
		else
			for i = #logs, 1, -1 do
				local entry = logs[i]
				local row = Instance.new("Frame")
				row.Name = string.format("DefenseLog_%d", i)
				row.LayoutOrder = #logs - i + 1
				row.Size = UDim2.new(1, -8, 0, 26)
				row.BackgroundColor3 = if entry.Defended then Color3.fromRGB(28, 52, 40) else Color3.fromRGB(58, 30, 32)
				row.BorderSizePixel = 0
				row.Parent = defenseLogListFrame

				local rCorner = Instance.new("UICorner")
				rCorner.CornerRadius = UDim.new(0, 5)
				rCorner.Parent = row

				local statusText = if entry.Defended then "DEFENDED" else "BREACHED"
				local rewardText = if entry.RewardScrap > 0
					then string.format("+%d Scrap", entry.RewardScrap)
					else "0 Scrap"
				local rowLbl = Instance.new("TextLabel")
				rowLbl.Size = UDim2.new(1, -12, 1, 0)
				rowLbl.Position = UDim2.fromOffset(6, 0)
				rowLbl.BackgroundTransparency = 1
				rowLbl.Font = Enum.Font.GothamMedium
				rowLbl.TextSize = 11
				rowLbl.TextXAlignment = Enum.TextXAlignment.Left
				rowLbl.TextTruncate = Enum.TextTruncate.AtEnd
				rowLbl.TextColor3 = if entry.Defended
					then Color3.fromRGB(170, 240, 185)
					else Color3.fromRGB(245, 175, 175)
				rowLbl.Text = string.format(
					"[%s] %s | Lives: %d/%d | %s",
					statusText,
					entry.RaiderName,
					entry.LivesSpent,
					entry.MaxLives,
					rewardText
				)
				rowLbl.Parent = row
			end
		end
	end
end

local function createGui()
	local localPlayer = Players.LocalPlayer
	if not localPlayer then
		return
	end
	local playerGui = localPlayer:WaitForChild("PlayerGui") :: PlayerGui

	local existing = playerGui:FindFirstChild("ToolCupboardGui")
	if existing then
		existing:Destroy()
	end

	local gui = Instance.new("ScreenGui")
	gui.Name = "ToolCupboardGui"
	gui.ResetOnSpawn = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.DisplayOrder = 22

	local frame = Instance.new("Frame")
	frame.Name = "ToolCupboardPanel"
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.fromScale(0.5, 0.48)
	frame.Size = UDim2.fromOffset(540, 650)
	frame.BackgroundColor3 = COLOR_BG
	frame.BackgroundTransparency = 0.08
	frame.BorderSizePixel = 0
	frame.Visible = false
	frame.Parent = gui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = frame

	local stroke = Instance.new("UIStroke")
	stroke.Color = COLOR_STROKE
	stroke.Thickness = 1.6
	stroke.Parent = frame

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.Position = UDim2.fromOffset(16, 10)
	title.Size = UDim2.new(1, -64, 0, 24)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBold
	title.TextSize = 17
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextColor3 = Color3.fromRGB(240, 242, 248)
	title.Text = "TOOL CUPBOARD (UPKEEP)"
	title.Parent = frame

	local closeBtn = Instance.new("TextButton")
	closeBtn.Name = "CloseButton"
	closeBtn.AnchorPoint = Vector2.new(1, 0)
	closeBtn.Position = UDim2.new(1, -12, 0, 10)
	closeBtn.Size = UDim2.fromOffset(28, 26)
	closeBtn.BackgroundColor3 = Color3.fromRGB(165, 55, 55)
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
		ToolCupboardController.Close()
	end)

	local badgesRow = Instance.new("Frame")
	badgesRow.Name = "BadgesRow"
	badgesRow.Position = UDim2.fromOffset(16, 42)
	badgesRow.Size = UDim2.new(1, -32, 0, 26)
	badgesRow.BackgroundTransparency = 1
	badgesRow.Parent = frame

	local function makeBadge(name: string, posX: number, wScale: number): TextLabel
		local lbl = Instance.new("TextLabel")
		lbl.Name = name
		lbl.Position = UDim2.fromScale(posX, 0)
		lbl.Size = UDim2.new(wScale, -4, 1, 0)
		lbl.BackgroundColor3 = Color3.fromRGB(30, 34, 42)
		lbl.BorderSizePixel = 0
		lbl.Font = Enum.Font.GothamBold
		lbl.TextSize = 12
		lbl.TextColor3 = Color3.new(1, 1, 1)
		lbl.Text = ""
		lbl.Parent = badgesRow
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0, 6)
		c.Parent = lbl
		return lbl
	end

	tierBadgeLabel = makeBadge("TierBadge", 0, 0.30)
	statusBadgeLabel = makeBadge("StatusBadge", 0.31, 0.36)
	pathBadgeLabel = makeBadge("PathBadge", 0.68, 0.32)

	local upkeepLbl = Instance.new("TextLabel")
	upkeepLbl.Name = "UpkeepSummary"
	upkeepLbl.Position = UDim2.fromOffset(16, 74)
	upkeepLbl.Size = UDim2.new(1, -32, 0, 22)
	upkeepLbl.BackgroundTransparency = 1
	upkeepLbl.Font = Enum.Font.GothamMedium
	upkeepLbl.TextSize = 12
	upkeepLbl.TextXAlignment = Enum.TextXAlignment.Left
	upkeepLbl.TextTruncate = Enum.TextTruncate.AtEnd
	upkeepLbl.TextColor3 = Color3.fromRGB(205, 212, 224)
	upkeepLbl.Text = "Upkeep: -"
	upkeepLbl.Parent = frame
	upkeepLabel = upkeepLbl

	local defLbl = Instance.new("TextLabel")
	defLbl.Name = "DefenseCapacitySummary"
	defLbl.Position = UDim2.fromOffset(16, 96)
	defLbl.Size = UDim2.new(1, -32, 0, 20)
	defLbl.BackgroundTransparency = 1
	defLbl.Font = Enum.Font.GothamBold
	defLbl.TextSize = 12
	defLbl.TextXAlignment = Enum.TextXAlignment.Left
	defLbl.TextColor3 = COLOR_OK
	defLbl.Text = "Защита базы: 0 / 60 очков"
	defLbl.Parent = frame
	defenseCapLabel = defLbl

	local tabsRow = Instance.new("Frame")
	tabsRow.Name = "TabsRow"
	tabsRow.Position = UDim2.fromOffset(16, 120)
	tabsRow.Size = UDim2.new(1, -32, 0, 28)
	tabsRow.BackgroundTransparency = 1
	tabsRow.Parent = frame

	local function makeTabBtn(name: string, posX: number, labelText: string): TextButton
		local btn = Instance.new("TextButton")
		btn.Name = name
		btn.Position = UDim2.fromScale(posX, 0)
		btn.Size = UDim2.fromScale(0.49, 1)
		btn.BackgroundColor3 = Color3.fromRGB(34, 38, 46)
		btn.BorderSizePixel = 0
		btn.Font = Enum.Font.GothamBold
		btn.TextSize = 12
		btn.TextColor3 = Color3.new(1, 1, 1)
		btn.Text = labelText
		btn.Parent = tabsRow
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0, 6)
		c.Parent = btn
		return btn
	end

	local upkeepTabBtn = makeTabBtn("UpkeepTabButton", 0, "Содержание и Защита")
	upkeepTabBtn.Activated:Connect(function()
		activeTab = "Upkeep"
		refreshUi()
	end)
	tabUpkeepBtn = upkeepTabBtn

	local bpTabBtn = makeTabBtn("BlueprintsTabButton", 0.51, "Планировки")
	bpTabBtn.Activated:Connect(function()
		activeTab = "Blueprints"
		refreshUi()
	end)
	tabBlueprintsBtn = bpTabBtn

	local upkeepContainer = Instance.new("Frame")
	upkeepContainer.Name = "UpkeepTabContainer"
	upkeepContainer.Position = UDim2.fromOffset(0, 152)
	upkeepContainer.Size = UDim2.new(1, 0, 1, -152)
	upkeepContainer.BackgroundTransparency = 1
	upkeepContainer.Parent = frame
	upkeepTabFrame = upkeepContainer

	local gridFrame = Instance.new("Frame")
	gridFrame.Name = "SlotsGrid"
	gridFrame.Position = UDim2.fromOffset(16, 2)
	gridFrame.Size = UDim2.fromOffset(508, 224)
	gridFrame.BackgroundTransparency = 1
	gridFrame.Parent = upkeepContainer

	local grid = Instance.new("UIGridLayout")
	grid.CellSize = UDim2.fromOffset(121, 68)
	grid.CellPadding = UDim2.fromOffset(8, 8)
	grid.SortOrder = Enum.SortOrder.LayoutOrder
	grid.Parent = gridFrame

	table.clear(slotUIs)
	for i = 1, Config.Upkeep.TcStorageSlots do
		local btn = Instance.new("TextButton")
		btn.Name = string.format("TcSlot_%d", i)
		btn.LayoutOrder = i
		btn.BackgroundColor3 = COLOR_SLOT
		btn.BorderSizePixel = 0
		btn.Text = ""
		btn.Parent = gridFrame
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0, 7)
		c.Parent = btn
		local s = Instance.new("UIStroke")
		s.Color = Color3.fromRGB(64, 70, 84)
		s.Thickness = 1
		s.Parent = btn

		local nLbl = Instance.new("TextLabel")
		nLbl.Name = "ItemName"
		nLbl.Position = UDim2.fromOffset(6, 8)
		nLbl.Size = UDim2.new(1, -12, 0, 30)
		nLbl.BackgroundTransparency = 1
		nLbl.Font = Enum.Font.GothamBold
		nLbl.TextSize = 11
		nLbl.TextWrapped = true
		nLbl.TextColor3 = Color3.fromRGB(236, 240, 245)
		nLbl.Text = ""
		nLbl.Parent = btn

		local cLbl = Instance.new("TextLabel")
		cLbl.Name = "ItemCount"
		cLbl.AnchorPoint = Vector2.new(1, 1)
		cLbl.Position = UDim2.new(1, -6, 1, -4)
		cLbl.Size = UDim2.new(1, -12, 0, 18)
		cLbl.BackgroundTransparency = 1
		cLbl.Font = Enum.Font.GothamBold
		cLbl.TextSize = 12
		cLbl.TextXAlignment = Enum.TextXAlignment.Right
		cLbl.TextColor3 = Color3.fromRGB(160, 230, 165)
		cLbl.Text = ""
		cLbl.Parent = btn

		btn.Activated:Connect(function()
			if currentState ~= nil and currentState.Slots[i] ~= nil then
				Net.GetEvent(Net.Events.ToolCupboardAction):FireServer("Withdraw", i)
			end
		end)

		table.insert(slotUIs, {
			Index = i,
			Button = btn,
			NameLabel = nLbl,
			CountLabel = cLbl,
		})
	end

	local depositTitle = Instance.new("TextLabel")
	depositTitle.Name = "DepositHeader"
	depositTitle.Position = UDim2.fromOffset(16, 232)
	depositTitle.Size = UDim2.new(1, -32, 0, 18)
	depositTitle.BackgroundTransparency = 1
	depositTitle.Font = Enum.Font.GothamMedium
	depositTitle.TextSize = 12
	depositTitle.TextXAlignment = Enum.TextXAlignment.Left
	depositTitle.TextColor3 = Color3.fromRGB(185, 195, 210)
	depositTitle.Text = "Quick Deposit from Inventory (click slot above to withdraw):"
	depositTitle.Parent = upkeepContainer

	local depRow = Instance.new("Frame")
	depRow.Name = "DepositRow"
	depRow.Position = UDim2.fromOffset(16, 254)
	depRow.Size = UDim2.new(1, -32, 0, 62)
	depRow.BackgroundTransparency = 1
	depRow.Parent = upkeepContainer

	local depGrid = Instance.new("UIGridLayout")
	depGrid.CellSize = UDim2.fromOffset(121, 56)
	depGrid.CellPadding = UDim2.fromOffset(8, 0)
	depGrid.SortOrder = Enum.SortOrder.LayoutOrder
	depGrid.Parent = depRow

	table.clear(depositButtons)
	for idx, resId in Config.Upkeep.AllowedResourceIds do
		local dBtn = Instance.new("TextButton")
		dBtn.Name = string.format("Deposit_%s", resId)
		dBtn.LayoutOrder = idx
		dBtn.BackgroundColor3 = Color3.fromRGB(48, 88, 60)
		dBtn.BorderSizePixel = 0
		dBtn.Font = Enum.Font.GothamBold
		dBtn.TextSize = 11
		dBtn.TextWrapped = true
		dBtn.TextColor3 = Color3.new(1, 1, 1)
		dBtn.Text = resId
		dBtn.Parent = depRow
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0, 7)
		c.Parent = dBtn

		dBtn.Activated:Connect(function()
			local total, slotIdx = countInventoryResource(resId)
			if total > 0 and slotIdx ~= nil then
				Net.GetEvent(Net.Events.ToolCupboardAction):FireServer("Deposit", slotIdx)
			end
		end)

		table.insert(depositButtons, {
			ResourceId = resId,
			Button = dBtn,
		})
	end

	local logHeader = Instance.new("TextLabel")
	logHeader.Name = "DefenseLogHeader"
	logHeader.Position = UDim2.fromOffset(16, 322)
	logHeader.Size = UDim2.new(1, -210, 0, 20)
	logHeader.BackgroundTransparency = 1
	logHeader.Font = Enum.Font.GothamBold
	logHeader.TextSize = 12
	logHeader.TextXAlignment = Enum.TextXAlignment.Left
	logHeader.TextColor3 = Color3.fromRGB(220, 228, 240)
	logHeader.Text = "Журнал обороны (последние 5):"
	logHeader.Parent = upkeepContainer

	local selfRaidBtn = Instance.new("TextButton")
	selfRaidBtn.Name = "SelfRaidTestButton"
	selfRaidBtn.AnchorPoint = Vector2.new(1, 0)
	selfRaidBtn.Position = UDim2.new(1, -16, 0, 318)
	selfRaidBtn.Size = UDim2.fromOffset(186, 28)
	selfRaidBtn.BackgroundColor3 = Color3.fromRGB(168, 72, 42)
	selfRaidBtn.BorderSizePixel = 0
	selfRaidBtn.Font = Enum.Font.GothamBold
	selfRaidBtn.TextSize = 11
	selfRaidBtn.TextColor3 = Color3.new(1, 1, 1)
	selfRaidBtn.Text = "Тест защиты (Self-Raid)"
	selfRaidBtn.Parent = upkeepContainer
	local srCorner = Instance.new("UICorner")
	srCorner.CornerRadius = UDim.new(0, 6)
	srCorner.Parent = selfRaidBtn
	selfRaidBtn.Activated:Connect(function()
		ToolCupboardController.Close()
		Net.GetEvent(Net.Events.ToolCupboardAction):FireServer("StartSelfRaid")
	end)

	local logScroll = Instance.new("ScrollingFrame")
	logScroll.Name = "DefenseLogList"
	logScroll.Position = UDim2.fromOffset(16, 350)
	logScroll.Size = UDim2.fromOffset(508, 134)
	logScroll.BackgroundColor3 = Color3.fromRGB(15, 17, 22)
	logScroll.BackgroundTransparency = 0.2
	logScroll.BorderSizePixel = 0
	logScroll.ScrollBarThickness = 5
	logScroll.CanvasSize = UDim2.fromOffset(0, 0)
	logScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	logScroll.Parent = upkeepContainer

	local logCorner = Instance.new("UICorner")
	logCorner.CornerRadius = UDim.new(0, 6)
	logCorner.Parent = logScroll

	local logPad = Instance.new("UIPadding")
	logPad.PaddingTop = UDim.new(0, 4)
	logPad.PaddingBottom = UDim.new(0, 4)
	logPad.PaddingLeft = UDim.new(0, 4)
	logPad.PaddingRight = UDim.new(0, 4)
	logPad.Parent = logScroll

	local logLayout = Instance.new("UIListLayout")
	logLayout.Padding = UDim.new(0, 4)
	logLayout.SortOrder = Enum.SortOrder.LayoutOrder
	logLayout.Parent = logScroll

	defenseLogListFrame = logScroll

	local bpContainer = Instance.new("Frame")
	bpContainer.Name = "BlueprintsTabContainer"
	bpContainer.Position = UDim2.fromOffset(0, 152)
	bpContainer.Size = UDim2.new(1, 0, 1, -152)
	bpContainer.BackgroundTransparency = 1
	bpContainer.Visible = false
	bpContainer.Parent = frame
	blueprintsTabFrame = bpContainer

	local bpHeader = Instance.new("TextLabel")
	bpHeader.Name = "BlueprintsHeader"
	bpHeader.Position = UDim2.fromOffset(16, 4)
	bpHeader.Size = UDim2.new(1, -32, 0, 20)
	bpHeader.BackgroundTransparency = 1
	bpHeader.Font = Enum.Font.GothamBold
	bpHeader.TextSize = 13
	bpHeader.TextXAlignment = Enum.TextXAlignment.Left
	bpHeader.TextColor3 = Color3.fromRGB(225, 232, 245)
	bpHeader.Text = "Чертежи планировки базы (относительно TC, без лута):"
	bpHeader.Parent = bpContainer

	local bpHint = Instance.new("TextLabel")
	bpHint.Name = "BlueprintsHint"
	bpHint.Position = UDim2.fromOffset(16, 24)
	bpHint.Size = UDim2.new(1, -32, 0, 18)
	bpHint.BackgroundTransparency = 1
	bpHint.Font = Enum.Font.Gotham
	bpHint.TextSize = 11
	bpHint.TextXAlignment = Enum.TextXAlignment.Left
	bpHint.TextColor3 = Color3.fromRGB(165, 180, 205)
	bpHint.Text =
		"Загрузка проверяет ресурсы в TC и возвращает 80% ресурсов старых модулей"
	bpHint.Parent = bpContainer

	local bpScroll = Instance.new("ScrollingFrame")
	bpScroll.Name = "BlueprintsList"
	bpScroll.Position = UDim2.fromOffset(16, 48)
	bpScroll.Size = UDim2.fromOffset(508, 434)
	bpScroll.BackgroundColor3 = Color3.fromRGB(15, 17, 22)
	bpScroll.BackgroundTransparency = 0.25
	bpScroll.BorderSizePixel = 0
	bpScroll.ScrollBarThickness = 5
	bpScroll.CanvasSize = UDim2.fromOffset(0, 0)
	bpScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	bpScroll.Parent = bpContainer

	local bpPad = Instance.new("UIPadding")
	bpPad.PaddingTop = UDim.new(0, 6)
	bpPad.PaddingBottom = UDim.new(0, 6)
	bpPad.PaddingLeft = UDim.new(0, 6)
	bpPad.PaddingRight = UDim.new(0, 6)
	bpPad.Parent = bpScroll

	local bpLayout = Instance.new("UIListLayout")
	bpLayout.Padding = UDim.new(0, 8)
	bpLayout.SortOrder = Enum.SortOrder.LayoutOrder
	bpLayout.Parent = bpScroll

	blueprintsListFrame = bpScroll

	gui.Parent = playerGui
	mainFrame = frame
end

local function onToolCupboardSync(payloadAny: any)
	if payloadAny == nil then
		currentState = nil
		isOpen = false
		refreshUi()
		return
	end
	if type(payloadAny) ~= "table" or type(payloadAny.Uid) ~= "string" then
		return
	end

	local hourlyUpkeep: { [string]: number } = {}
	if type(payloadAny.HourlyUpkeep) == "table" then
		for k, v in payloadAny.HourlyUpkeep do
			if type(k) == "string" and type(v) == "number" then
				hourlyUpkeep[k] = v
			end
		end
	end

	local parsedLogs: { DefenseLogEntry } = {}
	if type(payloadAny.DefenseLogs) == "table" then
		for _, rawLog in payloadAny.DefenseLogs do
			if type(rawLog) == "table" and type(rawLog.RaiderName) == "string" then
				table.insert(parsedLogs, {
					Id = if type(rawLog.Id) == "string" then rawLog.Id else "",
					RaiderUserId = if type(rawLog.RaiderUserId) == "number" then rawLog.RaiderUserId else 0,
					RaiderName = rawLog.RaiderName,
					TargetTier = if type(rawLog.TargetTier) == "number" then rawLog.TargetTier else 1,
					Defended = rawLog.Defended == true,
					LivesSpent = if type(rawLog.LivesSpent) == "number" then rawLog.LivesSpent else 0,
					MaxLives = if type(rawLog.MaxLives) == "number" then rawLog.MaxLives else Config.Raid.MaxLives,
					RewardScrap = if type(rawLog.RewardScrap) == "number" then rawLog.RewardScrap else 0,
					Timestamp = if type(rawLog.Timestamp) == "number" then rawLog.Timestamp else 0,
					GhostsShown = rawLog.GhostsShown == true,
					DeathPoints = {},
					Summary = if type(rawLog.Summary) == "string" then rawLog.Summary else "",
				})
			end
		end
	end

	local parsedBlueprints: { BaseBlueprintSummary } = {}
	if type(payloadAny.Blueprints) == "table" then
		for _, rawBp in payloadAny.Blueprints do
			if type(rawBp) == "table" and type(rawBp.Id) == "string" and type(rawBp.Name) == "string" then
				local costMap: { [string]: number } = {}
				if type(rawBp.Cost) == "table" then
					for rId, rAmt in rawBp.Cost do
						if type(rId) == "string" and type(rAmt) == "number" and rAmt > 0 then
							costMap[rId] = math.floor(rAmt)
						end
					end
				end
				table.insert(parsedBlueprints, {
					Id = rawBp.Id,
					Name = rawBp.Name,
					PieceCount = if type(rawBp.PieceCount) == "number" then math.floor(rawBp.PieceCount) else 0,
					SavedAt = if type(rawBp.SavedAt) == "number" then math.floor(rawBp.SavedAt) else 0,
					IsBuiltin = rawBp.IsBuiltin == true,
					HasData = rawBp.HasData == true,
					Cost = costMap,
				})
			end
		end
	end

	currentState = {
		Uid = payloadAny.Uid,
		ContainerId = if type(payloadAny.ContainerId) == "string" then payloadAny.ContainerId else payloadAny.Uid,
		BaseTier = if type(payloadAny.BaseTier) == "number" then payloadAny.BaseTier else 0,
		Status = if payloadAny.Status == "Protected" then "Protected" else "Decaying",
		HourlyUpkeep = hourlyUpkeep,
		ProtectedHours = if type(payloadAny.ProtectedHours) == "number" then payloadAny.ProtectedHours else 0,
		PathValid = payloadAny.PathValid == true,
		PathMessage = if type(payloadAny.PathMessage) == "string" then payloadAny.PathMessage else nil,
		DefenseUsed = if type(payloadAny.DefenseUsed) == "number" then payloadAny.DefenseUsed else 0,
		DefenseMax = if type(payloadAny.DefenseMax) == "number" then payloadAny.DefenseMax else 60,
		Slots = parseTcSlots(payloadAny.Slots),
		DefenseLogs = parsedLogs,
		Blueprints = parsedBlueprints,
	}
	isOpen = true
	refreshUi()
end

function ToolCupboardController.IsOpen(): boolean
	return isOpen
end

function ToolCupboardController.Close()
	if not isOpen then
		return
	end
	isOpen = false
	refreshUi()
	Net.GetEvent(Net.Events.ToolCupboardAction):FireServer("Close")
end

function ToolCupboardController.GetState(): ToolCupboardState?
	return currentState
end

function ToolCupboardController.Init()
	if isInitialized then
		return
	end
	isInitialized = true

	createGui()
	Net.GetEvent(Net.Events.ToolCupboardSync).OnClientEvent:Connect(onToolCupboardSync)
	InventoryController.OnChanged(function()
		if isOpen then
			refreshUi()
		end
	end)

	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessedEvent: boolean)
		if gameProcessedEvent then
			return
		end
		if input.KeyCode == Enum.KeyCode.Escape and isOpen then
			ToolCupboardController.Close()
		end
	end)
end

return ToolCupboardController
