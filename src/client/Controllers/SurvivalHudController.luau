--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage.Shared.Config)
local Types = require(ReplicatedStorage.Shared.Types)
local Janitor = require(ReplicatedStorage.Shared.Janitor)

type BarUI = {
	Fill: Frame,
	ValueLabel: TextLabel,
	Stroke: UIStroke,
}

local LOW_WARNING_THRESHOLD = 15
local DEFAULT_STROKE_COLOR = Color3.fromRGB(55, 55, 65)
local WARNING_STROKE_COLOR = Color3.fromRGB(255, 85, 85)
local STAMINA_COLOR = Color3.fromRGB(235, 200, 55)
local STAMINA_EXHAUSTED_COLOR = Color3.fromRGB(180, 110, 55)

local healthBar: BarUI? = nil
local hungerBar: BarUI? = nil
local thirstBar: BarUI? = nil
local staminaBar: BarUI? = nil
local bleedingBadge: TextLabel? = nil
local wellFedBadge: TextLabel? = nil

local currentHealth = Types.MAX_HEALTH
local currentMaxHealth = Types.MAX_HEALTH
local currentHunger = Types.MAX_HUNGER
local currentThirst = Types.MAX_THIRST
local currentStamina = Config.MAX_STAMINA
local currentMaxStamina = Config.MAX_STAMINA
local staminaExhausted = false
local isWellFed = false
local wellFedRemaining = 0
local isBleeding = false

local characterJanitor = Janitor.new()
local isInitialized = false

local SurvivalHudController = {}

local function createStatBar(
	parent: Instance,
	name: string,
	labelText: string,
	color: Color3,
	layoutOrder: number
): BarUI
	local row = Instance.new("Frame")
	row.Name = name
	row.LayoutOrder = layoutOrder
	row.Size = UDim2.new(1, 0, 0, 22)
	row.BackgroundColor3 = Color3.fromRGB(32, 32, 38)
	row.BorderSizePixel = 0
	row.Parent = parent

	local rowCorner = Instance.new("UICorner")
	rowCorner.CornerRadius = UDim.new(0, 6)
	rowCorner.Parent = row

	local stroke = Instance.new("UIStroke")
	stroke.Color = DEFAULT_STROKE_COLOR
	stroke.Thickness = 1
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = row

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundColor3 = color
	fill.BorderSizePixel = 0
	fill.Parent = row

	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(0, 6)
	fillCorner.Parent = fill

	local valueLabel = Instance.new("TextLabel")
	valueLabel.Name = "ValueLabel"
	valueLabel.Position = UDim2.fromOffset(8, 0)
	valueLabel.Size = UDim2.new(1, -16, 1, 0)
	valueLabel.BackgroundTransparency = 1
	valueLabel.ZIndex = 2
	valueLabel.Font = Enum.Font.GothamBold
	valueLabel.TextSize = 12
	valueLabel.TextColor3 = Color3.fromRGB(245, 245, 250)
	valueLabel.TextStrokeTransparency = 0.45
	valueLabel.TextXAlignment = Enum.TextXAlignment.Left
	valueLabel.Text = labelText
	valueLabel.Parent = row

	return {
		Fill = fill,
		ValueLabel = valueLabel,
		Stroke = stroke,
	}
end

local function createSurvivalHudGui()
	local localPlayer = Players.LocalPlayer
	if not localPlayer then
		return
	end
	local playerGui = localPlayer:WaitForChild("PlayerGui") :: PlayerGui

	local existing = playerGui:FindFirstChild("SurvivalHudGui")
	if existing then
		existing:Destroy()
	end

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "SurvivalHudGui"
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = false
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.DisplayOrder = 5

	local container = Instance.new("Frame")
	container.Name = "Container"
	container.AnchorPoint = Vector2.new(0, 1)
	container.Position = UDim2.new(0, 16, 1, -16)
	container.Size = UDim2.fromOffset(220, 123)
	container.BackgroundColor3 = Color3.fromRGB(18, 18, 22)
	container.BackgroundTransparency = 0.25
	container.BorderSizePixel = 0
	container.Parent = screenGui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = container

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(80, 80, 90)
	stroke.Thickness = 1.5
	stroke.Parent = container

	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, 10)
	padding.PaddingRight = UDim.new(0, 10)
	padding.PaddingTop = UDim.new(0, 10)
	padding.PaddingBottom = UDim.new(0, 10)
	padding.Parent = container

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.Padding = UDim.new(0, 5)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = container

	healthBar = createStatBar(container, "HealthBar", "HP: 100 / 100", Color3.fromRGB(215, 65, 65), 1)
	hungerBar = createStatBar(container, "HungerBar", "Hunger: 100%", Color3.fromRGB(230, 145, 50), 2)
	thirstBar = createStatBar(container, "ThirstBar", "Thirst: 100%", Color3.fromRGB(65, 175, 235), 3)
	staminaBar = createStatBar(container, "StaminaBar", "Stamina: 100%", STAMINA_COLOR, 4)

	local wfBadge = Instance.new("TextLabel")
	wfBadge.Name = "WellFedBadge"
	wfBadge.AnchorPoint = Vector2.new(0, 1)
	wfBadge.Position = UDim2.new(0, 16, 1, -145)
	wfBadge.Size = UDim2.fromOffset(220, 24)
	wfBadge.BackgroundColor3 = Color3.fromRGB(36, 98, 56)
	wfBadge.BackgroundTransparency = 0.1
	wfBadge.BorderSizePixel = 0
	wfBadge.Font = Enum.Font.GothamBold
	wfBadge.TextSize = 11
	wfBadge.TextColor3 = Color3.fromRGB(235, 255, 240)
	wfBadge.Text = "Well Fed 00:00"
	wfBadge.Visible = false
	wfBadge.Parent = screenGui

	local wfCorner = Instance.new("UICorner")
	wfCorner.CornerRadius = UDim.new(0, 8)
	wfCorner.Parent = wfBadge

	local wfStroke = Instance.new("UIStroke")
	wfStroke.Color = Color3.fromRGB(95, 210, 130)
	wfStroke.Thickness = 1.2
	wfStroke.Parent = wfBadge

	wellFedBadge = wfBadge

	local bleedBadge = Instance.new("TextLabel")
	bleedBadge.Name = "BleedingBadge"
	bleedBadge.AnchorPoint = Vector2.new(0, 1)
	bleedBadge.Position = UDim2.new(0, 16, 1, -174)
	bleedBadge.Size = UDim2.fromOffset(220, 26)
	bleedBadge.BackgroundColor3 = Color3.fromRGB(165, 32, 32)
	bleedBadge.BackgroundTransparency = 0.1
	bleedBadge.BorderSizePixel = 0
	bleedBadge.Font = Enum.Font.GothamBold
	bleedBadge.TextSize = 12
	bleedBadge.TextColor3 = Color3.fromRGB(255, 240, 240)
	bleedBadge.Text = "BLEEDING - Use Bandage"
	bleedBadge.Visible = false
	bleedBadge.Parent = screenGui

	local bleedCorner = Instance.new("UICorner")
	bleedCorner.CornerRadius = UDim.new(0, 8)
	bleedCorner.Parent = bleedBadge

	local bleedStroke = Instance.new("UIStroke")
	bleedStroke.Color = Color3.fromRGB(255, 95, 95)
	bleedStroke.Thickness = 1.5
	bleedStroke.Parent = bleedBadge

	bleedingBadge = bleedBadge

	screenGui.Parent = playerGui
end

local function updateWellFedBadge()
	if not wellFedBadge then
		return
	end
	if isWellFed and wellFedRemaining > 0 then
		local mins = math.floor(wellFedRemaining / 60)
		local secs = wellFedRemaining % 60
		local bonusText = if currentMaxStamina > Config.MAX_STAMINA then " (+10% Stam)" else ""
		wellFedBadge.Text = string.format("Well Fed %02d:%02d%s", mins, secs, bonusText)
		wellFedBadge.Visible = true
	else
		wellFedBadge.Visible = false
	end
	if bleedingBadge then
		bleedingBadge.Position = if wellFedBadge.Visible then UDim2.new(0, 16, 1, -174) else UDim2.new(0, 16, 1, -145)
	end
end

local function updateHealthDisplay()
	if not healthBar then
		return
	end
	local maxHp = math.max(1, currentMaxHealth)
	local ratio = math.clamp(currentHealth / maxHp, 0, 1)
	healthBar.Fill.Size = UDim2.fromScale(ratio, 1)
	if isWellFed then
		healthBar.ValueLabel.Text = string.format("HP: %d / %d (Well Fed)", math.ceil(currentHealth), math.ceil(maxHp))
	else
		healthBar.ValueLabel.Text = string.format("HP: %d / %d", math.ceil(currentHealth), math.ceil(maxHp))
	end
end

local function updateHungerDisplay()
	if not hungerBar then
		return
	end
	local ratio = math.clamp(currentHunger / Types.MAX_HUNGER, 0, 1)
	hungerBar.Fill.Size = UDim2.fromScale(ratio, 1)
	hungerBar.ValueLabel.Text = string.format("Hunger: %d%%", math.floor(currentHunger + 0.5))
end

local function updateThirstDisplay()
	if not thirstBar then
		return
	end
	local ratio = math.clamp(currentThirst / Types.MAX_THIRST, 0, 1)
	thirstBar.Fill.Size = UDim2.fromScale(ratio, 1)
	thirstBar.ValueLabel.Text = string.format("Thirst: %d%%", math.floor(currentThirst + 0.5))
end

local function updateStaminaDisplay()
	if not staminaBar then
		return
	end
	local maxStam = math.max(1, currentMaxStamina)
	local ratio = math.clamp(currentStamina / maxStam, 0, 1)
	staminaBar.Fill.Size = UDim2.fromScale(ratio, 1)
	staminaBar.Fill.BackgroundColor3 = if staminaExhausted then STAMINA_EXHAUSTED_COLOR else STAMINA_COLOR
	staminaBar.ValueLabel.Text =
		string.format("Stamina: %d / %d", math.floor(currentStamina + 0.5), math.floor(maxStam + 0.5))
end

local function applyBarPulse(bar: BarUI?, value: number, alpha: number)
	if not bar then
		return
	end
	if value <= LOW_WARNING_THRESHOLD then
		bar.Fill.BackgroundTransparency = 0.38 * alpha
		bar.Stroke.Color = WARNING_STROKE_COLOR
		bar.Stroke.Thickness = 1 + 1.5 * alpha
	else
		bar.Fill.BackgroundTransparency = 0
		bar.Stroke.Color = DEFAULT_STROKE_COLOR
		bar.Stroke.Thickness = 1
	end
end

local function bindCharacter(character: Model)
	characterJanitor:Cleanup()

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		local waited = character:WaitForChild("Humanoid", 10)
		if waited and waited:IsA("Humanoid") then
			humanoid = waited
		end
	end
	if not humanoid then
		return
	end

	currentHealth = humanoid.Health
	currentMaxHealth = humanoid.MaxHealth
	updateHealthDisplay()

	characterJanitor:Add(humanoid.HealthChanged:Connect(function(newHealth: number)
		currentHealth = newHealth
		currentMaxHealth = humanoid.MaxHealth
		updateHealthDisplay()
	end))

	characterJanitor:Add(humanoid:GetPropertyChangedSignal("MaxHealth"):Connect(function()
		currentMaxHealth = humanoid.MaxHealth
		updateHealthDisplay()
	end))
end

local function readAttributesFromPlayer(localPlayer: Player)
	local hungerAttr = localPlayer:GetAttribute("Hunger")
	currentHunger = if typeof(hungerAttr) == "number"
		then math.clamp(hungerAttr, 0, Types.MAX_HUNGER)
		else Types.MAX_HUNGER

	local thirstAttr = localPlayer:GetAttribute("Thirst")
	currentThirst = if typeof(thirstAttr) == "number"
		then math.clamp(thirstAttr, 0, Types.MAX_THIRST)
		else Types.MAX_THIRST

	local maxStaminaAttr = localPlayer:GetAttribute("MaxStamina")
	currentMaxStamina = if typeof(maxStaminaAttr) == "number" and maxStaminaAttr >= Config.MAX_STAMINA
		then maxStaminaAttr
		else Config.MAX_STAMINA

	local staminaAttr = localPlayer:GetAttribute("Stamina")
	currentStamina = if typeof(staminaAttr) == "number"
		then math.clamp(staminaAttr, 0, currentMaxStamina)
		else currentMaxStamina

	staminaExhausted = localPlayer:GetAttribute("StaminaExhausted") == true
	isWellFed = localPlayer:GetAttribute("WellFed") == true
	local wfRemAttr = localPlayer:GetAttribute("WellFedRemaining")
	wellFedRemaining = if typeof(wfRemAttr) == "number" and wfRemAttr > 0 then math.floor(wfRemAttr) else 0

	isBleeding = localPlayer:GetAttribute("Bleeding") == true
	if bleedingBadge then
		bleedingBadge.Visible = isBleeding
	end

	updateWellFedBadge()
	updateHealthDisplay()
	updateHungerDisplay()
	updateThirstDisplay()
	updateStaminaDisplay()
end

function SurvivalHudController.Init()
	if isInitialized then
		return
	end
	isInitialized = true

	createSurvivalHudGui()

	local localPlayer = Players.LocalPlayer
	if not localPlayer then
		return
	end

	readAttributesFromPlayer(localPlayer)

	localPlayer:GetAttributeChangedSignal("Hunger"):Connect(function()
		local val = localPlayer:GetAttribute("Hunger")
		if typeof(val) == "number" then
			currentHunger = math.clamp(val, 0, Types.MAX_HUNGER)
			updateHungerDisplay()
		end
	end)

	localPlayer:GetAttributeChangedSignal("Thirst"):Connect(function()
		local val = localPlayer:GetAttribute("Thirst")
		if typeof(val) == "number" then
			currentThirst = math.clamp(val, 0, Types.MAX_THIRST)
			updateThirstDisplay()
		end
	end)

	localPlayer:GetAttributeChangedSignal("MaxStamina"):Connect(function()
		local val = localPlayer:GetAttribute("MaxStamina")
		if typeof(val) == "number" and val >= Config.MAX_STAMINA then
			currentMaxStamina = val
			updateStaminaDisplay()
			updateWellFedBadge()
		end
	end)

	localPlayer:GetAttributeChangedSignal("Stamina"):Connect(function()
		local val = localPlayer:GetAttribute("Stamina")
		if typeof(val) == "number" then
			currentStamina = math.clamp(val, 0, currentMaxStamina)
			updateStaminaDisplay()
		end
	end)

	localPlayer:GetAttributeChangedSignal("StaminaExhausted"):Connect(function()
		staminaExhausted = localPlayer:GetAttribute("StaminaExhausted") == true
		updateStaminaDisplay()
	end)

	localPlayer:GetAttributeChangedSignal("WellFed"):Connect(function()
		isWellFed = localPlayer:GetAttribute("WellFed") == true
		updateHealthDisplay()
		updateWellFedBadge()
	end)

	localPlayer:GetAttributeChangedSignal("WellFedRemaining"):Connect(function()
		local val = localPlayer:GetAttribute("WellFedRemaining")
		wellFedRemaining = if typeof(val) == "number" and val > 0 then math.floor(val) else 0
		updateWellFedBadge()
	end)

	localPlayer:GetAttributeChangedSignal("Bleeding"):Connect(function()
		isBleeding = localPlayer:GetAttribute("Bleeding") == true
		if bleedingBadge then
			bleedingBadge.Visible = isBleeding
		end
	end)

	localPlayer.CharacterAdded:Connect(function(character: Model)
		task.spawn(bindCharacter, character)
	end)

	if localPlayer.Character then
		task.spawn(bindCharacter, localPlayer.Character)
	end

	RunService.RenderStepped:Connect(function()
		local alpha = 0.5 + 0.5 * math.sin(os.clock() * 6)
		applyBarPulse(hungerBar, currentHunger, alpha)
		applyBarPulse(thirstBar, currentThirst, alpha)
		if bleedingBadge and isBleeding then
			bleedingBadge.BackgroundTransparency = 0.05 + 0.35 * alpha
		end
	end)
end

return SurvivalHudController
