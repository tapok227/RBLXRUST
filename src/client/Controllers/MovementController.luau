--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Config = require(ReplicatedStorage.Shared.Config)
local Net = require(ReplicatedStorage.Shared.Net)
local Janitor = require(ReplicatedStorage.Shared.Janitor)

local MOVE_DIRECTION_THRESHOLD = 0.1
local BUTTON_INACTIVE_COLOR = Color3.fromRGB(28, 30, 38)
local BUTTON_ACTIVE_COLOR = Color3.fromRGB(215, 175, 45)
local BUTTON_INACTIVE_TEXT_COLOR = Color3.fromRGB(240, 240, 245)
local BUTTON_ACTIVE_TEXT_COLOR = Color3.fromRGB(20, 20, 24)

local characterJanitor = Janitor.new()
local currentHumanoid: Humanoid? = nil
local shiftHeld = false
local touchSprintToggle = false
local lastSentSprint = false
local touchButton: TextButton? = nil
local isInitialized = false

local MovementController = {}

local function updateTouchButtonVisual()
	if not touchButton then
		return
	end
	if touchSprintToggle then
		touchButton.BackgroundColor3 = BUTTON_ACTIVE_COLOR
		touchButton.TextColor3 = BUTTON_ACTIVE_TEXT_COLOR
		touchButton.Text = "SPRINT: ON"
	else
		touchButton.BackgroundColor3 = BUTTON_INACTIVE_COLOR
		touchButton.TextColor3 = BUTTON_INACTIVE_TEXT_COLOR
		touchButton.Text = "SPRINT"
	end
end

local function sendSprintState(desired: boolean)
	if desired == lastSentSprint then
		return
	end
	lastSentSprint = desired
	Net.GetEvent(Net.Events.SprintStateRequest):FireServer(desired)
end

local function resetLocalSprintState()
	shiftHeld = false
	touchSprintToggle = false
	updateTouchButtonVisual()
	sendSprintState(false)
end

local function createTouchSprintButton(localPlayer: Player)
	local playerGui = localPlayer:WaitForChild("PlayerGui") :: PlayerGui
	local existing = playerGui:FindFirstChild("MovementSprintGui")
	if existing then
		existing:Destroy()
	end

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "MovementSprintGui"
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = false
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.DisplayOrder = 5

	local button = Instance.new("TextButton")
	button.Name = "SprintButton"
	button.AnchorPoint = Vector2.new(1, 1)
	button.Position = UDim2.new(1, -24, 1, -130)
	button.Size = UDim2.fromOffset(82, 40)
	button.BackgroundColor3 = BUTTON_INACTIVE_COLOR
	button.BackgroundTransparency = 0.15
	button.BorderSizePixel = 0
	button.Font = Enum.Font.GothamBold
	button.TextSize = 12
	button.TextColor3 = BUTTON_INACTIVE_TEXT_COLOR
	button.Text = "SPRINT"
	button.AutoButtonColor = true
	button.Parent = screenGui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = button

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(90, 95, 110)
	stroke.Thickness = 1.5
	stroke.Parent = button

	button.Activated:Connect(function()
		touchSprintToggle = not touchSprintToggle
		updateTouchButtonVisual()
	end)

	touchButton = button
	updateTouchButtonVisual()
	screenGui.Parent = playerGui
end

local function bindCharacter(character: Model)
	characterJanitor:Cleanup()
	currentHumanoid = nil

	local humanoidInst = character:FindFirstChildOfClass("Humanoid")
	if not humanoidInst then
		humanoidInst = character:WaitForChild("Humanoid", 10)
	end
	if not humanoidInst or not humanoidInst:IsA("Humanoid") then
		return
	end

	local localPlayer = Players.LocalPlayer
	if not localPlayer or localPlayer.Character ~= character then
		return
	end

	local humanoid = humanoidInst :: Humanoid
	currentHumanoid = humanoid

	characterJanitor:Add(humanoid.Died:Connect(function()
		currentHumanoid = nil
		resetLocalSprintState()
	end))
end

local function stepSprintInput()
	local localPlayer = Players.LocalPlayer
	if not localPlayer or not currentHumanoid or currentHumanoid.Health <= 0 then
		sendSprintState(false)
		return
	end

	local staminaAttr = localPlayer:GetAttribute("Stamina")
	local stamina = if typeof(staminaAttr) == "number" then staminaAttr else Config.MAX_STAMINA
	local exhausted = localPlayer:GetAttribute("StaminaExhausted") == true
	local isMoving = currentHumanoid.MoveDirection.Magnitude > MOVE_DIRECTION_THRESHOLD
	local wantsInput = shiftHeld or touchSprintToggle
	local hasEnoughStamina = if lastSentSprint then stamina > 0 else stamina >= Config.STAMINA_MIN_TO_SPRINT

	local desired = wantsInput and isMoving and not exhausted and hasEnoughStamina
	sendSprintState(desired)
end

function MovementController.Init()
	if isInitialized then
		return
	end
	isInitialized = true

	local localPlayer = Players.LocalPlayer
	if not localPlayer then
		return
	end

	if UserInputService.TouchEnabled then
		createTouchSprintButton(localPlayer)
	end

	UserInputService.InputBegan:Connect(function(input: InputObject, _gameProcessedEvent: boolean)
		if UserInputService:GetFocusedTextBox() ~= nil then
			return
		end
		if input.KeyCode == Enum.KeyCode.LeftShift then
			shiftHeld = true
		end
	end)

	UserInputService.InputEnded:Connect(function(input: InputObject)
		if input.KeyCode == Enum.KeyCode.LeftShift then
			shiftHeld = false
		end
	end)

	UserInputService.WindowFocusReleased:Connect(function()
		shiftHeld = false
	end)

	localPlayer:GetAttributeChangedSignal("InRaid"):Connect(function()
		resetLocalSprintState()
	end)

	localPlayer.CharacterAdded:Connect(function(character: Model)
		task.spawn(bindCharacter, character)
	end)

	localPlayer.CharacterRemoving:Connect(function()
		characterJanitor:Cleanup()
		currentHumanoid = nil
		resetLocalSprintState()
	end)

	if localPlayer.Character then
		task.spawn(bindCharacter, localPlayer.Character)
	end

	RunService.Heartbeat:Connect(stepSprintInput)
end

return MovementController
