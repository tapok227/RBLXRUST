--!strict
local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Types = require(ReplicatedStorage.Shared.Types)
local Items = require(ReplicatedStorage.Shared.configs.Items)
local Net = require(ReplicatedStorage.Shared.Net)
local InventoryController = require(script.Parent.InventoryController)

type Inventory = Types.Inventory
type DefenseUiState = Types.DefenseUiState

type AmmoSlotUI = {
	Index: number,
	Button: TextButton,
	NameLabel: TextLabel,
	CountLabel: TextLabel,
}

local SOUND_SHOT = "rbxasset://sounds/impact_explosion_03.mp3"
local SOUND_BEEP = "rbxasset://sounds/action_falling.ogg"

local COLOR_BG = Color3.fromRGB(20, 22, 28)
local COLOR_SLOT = Color3.fromRGB(34, 38, 46)
local COLOR_STROKE = Color3.fromRGB(78, 84, 98)
local COLOR_OK = Color3.fromRGB(95, 225, 130)
local COLOR_WARN = Color3.fromRGB(240, 185, 80)

local mainFrame: Frame? = nil
local titleLabel: TextLabel? = nil
local hpLabel: TextLabel? = nil
local capacityLabel: TextLabel? = nil
local ammoSummaryLabel: TextLabel? = nil
local depositBtn: TextButton? = nil
local slotUIs: { AmmoSlotUI } = {}
local currentState: DefenseUiState? = nil
local isOpen = false
local isInitialized = false

local DefenseController = {}

local function countInventoryItem(itemId: string): number
	local total = 0
	for i = 1, Types.INVENTORY_SIZE do
		local slot = InventoryController.GetSlot(i)
		if slot ~= nil and slot.Id == itemId and slot.Count > 0 then
			total += slot.Count
		end
	end
	return total
end

local function parseSlots(rawSlots: any, maxSlots: number): Inventory
	local inv: Inventory = {}
	if type(rawSlots) ~= "table" then
		return inv
	end
	for k, v in rawSlots do
		local idx = tonumber(k)
		if
			idx ~= nil
			and idx >= 1
			and idx <= maxSlots
			and idx % 1 == 0
			and type(v) == "table"
			and type(v.Id) == "string"
			and type(v.Count) == "number"
			and v.Count > 0
		then
			inv[idx] = { Id = v.Id, Count = math.floor(v.Count) }
		end
	end
	return inv
end

local function refreshUi()
	if not mainFrame then
		return
	end
	mainFrame.Visible = isOpen and currentState ~= nil
	if not isOpen or currentState == nil then
		return
	end

	local state = currentState :: DefenseUiState
	if titleLabel then
		titleLabel.Text = string.upper(state.Name) .. " (AMMO)"
	end
	if hpLabel then
		hpLabel.Text = string.format("HP: %d / %d", state.Hp, state.MaxHp)
		hpLabel.TextColor3 = if state.Hp >= state.MaxHp * 0.5 then COLOR_OK else COLOR_WARN
	end
	if capacityLabel then
		capacityLabel.Text = string.format("Защита: %d / %d очков", state.DefenseUsed, state.DefenseMax)
	end

	local itemCfg = Items[state.AmmoId]
	local ammoName = if itemCfg then itemCfg.Name else state.AmmoId
	if ammoSummaryLabel then
		ammoSummaryLabel.Text = string.format("Боезапас (%s): %d", ammoName, state.AmmoCount)
	end

	for _, ui in slotUIs do
		if ui.Index <= state.AmmoSlots then
			ui.Button.Visible = true
			local slot = state.Slots[ui.Index]
			if slot ~= nil and slot.Count > 0 then
				local sCfg = Items[slot.Id]
				ui.NameLabel.Text = if sCfg then sCfg.Name else slot.Id
				ui.CountLabel.Text = string.format("x%d", slot.Count)
			else
				ui.NameLabel.Text = "Пусто"
				ui.CountLabel.Text = ""
			end
		else
			ui.Button.Visible = false
		end
	end

	if depositBtn then
		local owned = countInventoryItem(state.AmmoId)
		depositBtn.Text = string.format("+ Загрузить %s (%d)", ammoName, owned)
		depositBtn.BackgroundColor3 = if owned > 0 then Color3.fromRGB(48, 88, 60) else Color3.fromRGB(45, 48, 56)
		depositBtn.TextColor3 = if owned > 0 then Color3.new(1, 1, 1) else Color3.fromRGB(145, 150, 160)
	end
end

local function createGui()
	local localPlayer = Players.LocalPlayer
	if not localPlayer then
		return
	end
	local playerGui = localPlayer:WaitForChild("PlayerGui") :: PlayerGui

	local existing = playerGui:FindFirstChild("DefenseAmmoGui")
	if existing then
		existing:Destroy()
	end

	local gui = Instance.new("ScreenGui")
	gui.Name = "DefenseAmmoGui"
	gui.ResetOnSpawn = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.DisplayOrder = 23

	local frame = Instance.new("Frame")
	frame.Name = "DefensePanel"
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.fromScale(0.5, 0.5)
	frame.Size = UDim2.fromOffset(440, 290)
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
	title.TextSize = 16
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextColor3 = Color3.fromRGB(240, 242, 248)
	title.Text = "DEFENSE AMMO"
	title.Parent = frame
	titleLabel = title

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
	local cCorner = Instance.new("UICorner")
	cCorner.CornerRadius = UDim.new(0, 6)
	cCorner.Parent = closeBtn
	closeBtn.Activated:Connect(function()
		DefenseController.Close()
	end)

	local hpLbl = Instance.new("TextLabel")
	hpLbl.Name = "HpLabel"
	hpLbl.Position = UDim2.fromOffset(16, 42)
	hpLbl.Size = UDim2.new(0.5, -20, 0, 20)
	hpLbl.BackgroundTransparency = 1
	hpLbl.Font = Enum.Font.GothamBold
	hpLbl.TextSize = 12
	hpLbl.TextXAlignment = Enum.TextXAlignment.Left
	hpLbl.TextColor3 = COLOR_OK
	hpLbl.Text = "HP: 0 / 0"
	hpLbl.Parent = frame
	hpLabel = hpLbl

	local capLbl = Instance.new("TextLabel")
	capLbl.Name = "CapacityLabel"
	capLbl.Position = UDim2.new(0.5, 4, 0, 42)
	capLbl.Size = UDim2.new(0.5, -20, 0, 20)
	capLbl.BackgroundTransparency = 1
	capLbl.Font = Enum.Font.GothamBold
	capLbl.TextSize = 12
	capLbl.TextXAlignment = Enum.TextXAlignment.Right
	capLbl.TextColor3 = Color3.fromRGB(185, 205, 240)
	capLbl.Text = "Защита: 0 / 60"
	capLbl.Parent = frame
	capacityLabel = capLbl

	local ammoLbl = Instance.new("TextLabel")
	ammoLbl.Name = "AmmoSummary"
	ammoLbl.Position = UDim2.fromOffset(16, 68)
	ammoLbl.Size = UDim2.new(1, -32, 0, 20)
	ammoLbl.BackgroundTransparency = 1
	ammoLbl.Font = Enum.Font.GothamMedium
	ammoLbl.TextSize = 13
	ammoLbl.TextXAlignment = Enum.TextXAlignment.Left
	ammoLbl.TextColor3 = Color3.fromRGB(220, 226, 236)
	ammoLbl.Text = "Боезапас: 0"
	ammoLbl.Parent = frame
	ammoSummaryLabel = ammoLbl

	local slotsRow = Instance.new("Frame")
	slotsRow.Name = "AmmoSlots"
	slotsRow.Position = UDim2.fromOffset(16, 98)
	slotsRow.Size = UDim2.fromOffset(408, 92)
	slotsRow.BackgroundTransparency = 1
	slotsRow.Parent = frame

	local grid = Instance.new("UIGridLayout")
	grid.CellSize = UDim2.fromOffset(96, 84)
	grid.CellPadding = UDim2.fromOffset(8, 0)
	grid.SortOrder = Enum.SortOrder.LayoutOrder
	grid.Parent = slotsRow

	table.clear(slotUIs)
	for i = 1, 4 do
		local btn = Instance.new("TextButton")
		btn.Name = string.format("AmmoSlot_%d", i)
		btn.LayoutOrder = i
		btn.BackgroundColor3 = COLOR_SLOT
		btn.BorderSizePixel = 0
		btn.Text = ""
		btn.Parent = slotsRow
		local sc = Instance.new("UICorner")
		sc.CornerRadius = UDim.new(0, 7)
		sc.Parent = btn
		local ss = Instance.new("UIStroke")
		ss.Color = Color3.fromRGB(64, 70, 84)
		ss.Thickness = 1
		ss.Parent = btn

		local nLbl = Instance.new("TextLabel")
		nLbl.Name = "ItemName"
		nLbl.Position = UDim2.fromOffset(6, 10)
		nLbl.Size = UDim2.new(1, -12, 0, 38)
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
		cLbl.Position = UDim2.new(1, -6, 1, -6)
		cLbl.Size = UDim2.new(1, -12, 0, 20)
		cLbl.BackgroundTransparency = 1
		cLbl.Font = Enum.Font.GothamBold
		cLbl.TextSize = 13
		cLbl.TextXAlignment = Enum.TextXAlignment.Right
		cLbl.TextColor3 = Color3.fromRGB(160, 230, 165)
		cLbl.Text = ""
		cLbl.Parent = btn

		btn.Activated:Connect(function()
			if currentState ~= nil and currentState.Slots[i] ~= nil then
				Net.GetEvent(Net.Events.DefenseAction):FireServer("WithdrawSlot", i)
			end
		end)

		table.insert(slotUIs, {
			Index = i,
			Button = btn,
			NameLabel = nLbl,
			CountLabel = cLbl,
		})
	end

	local depBtn = Instance.new("TextButton")
	depBtn.Name = "DepositAmmoButton"
	depBtn.Position = UDim2.fromOffset(16, 206)
	depBtn.Size = UDim2.new(1, -32, 0, 40)
	depBtn.BackgroundColor3 = Color3.fromRGB(48, 88, 60)
	depBtn.BorderSizePixel = 0
	depBtn.Font = Enum.Font.GothamBold
	depBtn.TextSize = 13
	depBtn.TextColor3 = Color3.new(1, 1, 1)
	depBtn.Text = "+ Загрузить патроны"
	depBtn.Parent = frame
	local dCorner = Instance.new("UICorner")
	dCorner.CornerRadius = UDim.new(0, 7)
	dCorner.Parent = depBtn
	depBtn.Activated:Connect(function()
		Net.GetEvent(Net.Events.DefenseAction):FireServer("DepositAmmo")
	end)
	depositBtn = depBtn

	local hint = Instance.new("TextLabel")
	hint.Name = "Hint"
	hint.Position = UDim2.fromOffset(16, 254)
	hint.Size = UDim2.new(1, -32, 0, 22)
	hint.BackgroundTransparency = 1
	hint.Font = Enum.Font.Gotham
	hint.TextSize = 11
	hint.TextColor3 = Color3.fromRGB(170, 178, 192)
	hint.Text = "Нажмите на слот выше, чтобы забрать патроны обратно"
	hint.Parent = frame

	gui.Parent = playerGui
	mainFrame = frame
end

local function spawnWorldSound(pos: Vector3, soundId: string, volume: number, speed: number)
	local holder = Instance.new("Part")
	holder.Name = "DefenseSoundAnchor"
	holder.Anchored = true
	holder.CanCollide = false
	holder.CanQuery = false
	holder.CanTouch = false
	holder.Transparency = 1
	holder.Size = Vector3.new(0.2, 0.2, 0.2)
	holder.Position = pos
	holder.Parent = Workspace

	local sound = Instance.new("Sound")
	sound.SoundId = soundId
	sound.Volume = volume
	sound.PlaybackSpeed = speed
	sound.RollOffMaxDistance = 90
	sound.Parent = holder
	sound:Play()

	Debris:AddItem(holder, 1.5)
end

local function spawnBeamPart(origin: Vector3, endPos: Vector3, thickness: number, color: Color3, duration: number)
	local delta = endPos - origin
	local dist = delta.Magnitude
	if dist < 0.05 then
		return
	end
	local beam = Instance.new("Part")
	beam.Name = "DefenseBeamVfx"
	beam.Anchored = true
	beam.CanCollide = false
	beam.CanQuery = false
	beam.CanTouch = false
	beam.Material = Enum.Material.Neon
	beam.Color = color
	beam.Transparency = 0.25
	beam.Size = Vector3.new(thickness, thickness, dist)
	beam.CFrame = CFrame.lookAt((origin + endPos) * 0.5, endPos)
	beam.Parent = Workspace
	Debris:AddItem(beam, duration)
end

local function onDefenseEffect(effectKindAny: any, originAny: any, targetPositionsAny: any)
	if typeof(effectKindAny) ~= "string" or typeof(originAny) ~= "Vector3" then
		return
	end
	local effectKind = effectKindAny :: string
	local origin = originAny :: Vector3
	local targets: { Vector3 } = {}
	if type(targetPositionsAny) == "table" then
		for _, p in targetPositionsAny do
			if typeof(p) == "Vector3" then
				table.insert(targets, p)
			end
		end
	end

	if effectKind == "TurretLock" then
		spawnWorldSound(origin, SOUND_BEEP, 0.45, 2.6)
		if #targets > 0 then
			spawnBeamPart(origin, targets[1], 0.08, Color3.fromRGB(255, 50, 50), 0.22)
		end
	elseif effectKind == "TurretShot" then
		spawnWorldSound(origin, SOUND_SHOT, 0.35, 2.8)
		if #targets > 0 then
			spawnBeamPart(origin, targets[1], 0.14, Color3.fromRGB(255, 210, 85), 0.09)
		end
	elseif effectKind == "Shotgun" then
		spawnWorldSound(origin, SOUND_SHOT, 0.45, 2.1)
		for _, endPos in targets do
			spawnBeamPart(origin, endPos, 0.1, Color3.fromRGB(255, 185, 65), 0.1)
		end
	elseif effectKind == "Spikes" then
		spawnWorldSound(origin, SOUND_BEEP, 0.4, 2.0)
	elseif effectKind == "MineArm" then
		spawnWorldSound(origin, SOUND_BEEP, 0.55, 2.4)
	elseif effectKind == "TurretEmp" then
		spawnWorldSound(origin, SOUND_SHOT, 0.7, 2.6)
		for i = 1, 6 do
			local angle = (i / 6) * math.pi * 2
			local sparkOffset = Vector3.new(math.cos(angle) * 2.2, 0.6 + (i % 2) * 0.9, math.sin(angle) * 2.2)
			spawnBeamPart(origin, origin + sparkOffset, 0.14, Color3.fromRGB(65, 205, 255), 0.35)
		end
	end
end

local function onDefenseSync(payloadAny: any)
	if payloadAny == nil then
		currentState = nil
		isOpen = false
		refreshUi()
		return
	end
	if type(payloadAny) ~= "table" or type(payloadAny.Uid) ~= "string" then
		return
	end
	local maxSlots = if type(payloadAny.AmmoSlots) == "number" then math.floor(payloadAny.AmmoSlots) else 3
	currentState = {
		Uid = payloadAny.Uid,
		PieceType = payloadAny.PieceType,
		Name = if type(payloadAny.Name) == "string" then payloadAny.Name else "Defense",
		Hp = if type(payloadAny.Hp) == "number" then payloadAny.Hp else 0,
		MaxHp = if type(payloadAny.MaxHp) == "number" then payloadAny.MaxHp else 100,
		AmmoId = if type(payloadAny.AmmoId) == "string" then payloadAny.AmmoId else "pistol_ammo",
		AmmoCount = if type(payloadAny.AmmoCount) == "number" then payloadAny.AmmoCount else 0,
		AmmoSlots = maxSlots,
		Slots = parseSlots(payloadAny.Slots, maxSlots),
		DefenseUsed = if type(payloadAny.DefenseUsed) == "number" then payloadAny.DefenseUsed else 0,
		DefenseMax = if type(payloadAny.DefenseMax) == "number" then payloadAny.DefenseMax else 60,
	}
	isOpen = true
	refreshUi()
end

function DefenseController.IsOpen(): boolean
	return isOpen
end

function DefenseController.Close()
	if not isOpen then
		return
	end
	isOpen = false
	currentState = nil
	refreshUi()
	Net.GetEvent(Net.Events.DefenseAction):FireServer("Close")
end

function DefenseController.Init()
	if isInitialized then
		return
	end
	isInitialized = true

	createGui()

	Net.GetEvent(Net.Events.DefenseSync).OnClientEvent:Connect(onDefenseSync)
	Net.GetEvent(Net.Events.DefenseEffect).OnClientEvent:Connect(onDefenseEffect)

	InventoryController.OnChanged(function()
		if isOpen then
			refreshUi()
		end
	end)

	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if gameProcessed then
			return
		end
		if input.KeyCode == Enum.KeyCode.Escape and isOpen then
			DefenseController.Close()
		end
	end)
end

return DefenseController
