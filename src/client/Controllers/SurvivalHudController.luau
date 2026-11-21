--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

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

local healthBar: BarUI? = nil
local hungerBar: BarUI? = nil
local thirstBar: BarUI? = nil

local currentHealth = Types.MAX_HEALTH
local currentMaxHealth = Types.MAX_HEALTH
local currentHunger = Types.MAX_HUNGER
local currentThirst = Types.MAX_THIRST

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
	container.Size = UDim2.fromOffset(220, 96)
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

	screenGui.Parent = playerGui
end

local function updateHealthDisplay()
	if not healthBar then
		return
	end
	local maxHp = math.max(1, currentMaxHealth)
	local ratio = math.clamp(currentHealth / maxHp, 0, 1)
	healthBar.Fill.Size = UDim2.fromScale(ratio, 1)
	healthBar.ValueLabel.Text = string.format("HP: %d / %d", math.ceil(currentHealth), math.ceil(maxHp))
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

	updateHungerDisplay()
	updateThirstDisplay()
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
	end)
end

return SurvivalHudController
