--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage.Shared.Types)
local Net = require(ReplicatedStorage.Shared.Net)

type ExtractionState = Types.ExtractionState

local ACCENT_COLOR = Color3.fromRGB(60, 220, 120)

local panelFrame: Frame? = nil
local zoneNameLabel: TextLabel? = nil
local statusLabel: TextLabel? = nil
local progressFill: Frame? = nil
local currentState: ExtractionState? = nil
local isInitialized = false

local ExtractionController = {}

local function createExtractionGui()
	local localPlayer = Players.LocalPlayer
	if not localPlayer then
		return
	end
	local playerGui = localPlayer:WaitForChild("PlayerGui") :: PlayerGui

	local existing = playerGui:FindFirstChild("ExtractionGui")
	if existing then
		existing:Destroy()
	end

	local gui = Instance.new("ScreenGui")
	gui.Name = "ExtractionGui"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.DisplayOrder = 25

	local panel = Instance.new("Frame")
	panel.Name = "ExtractionPanel"
	panel.AnchorPoint = Vector2.new(0.5, 0)
	panel.Position = UDim2.new(0.5, 0, 0, 84)
	panel.Size = UDim2.fromOffset(340, 78)
	panel.BackgroundColor3 = Color3.fromRGB(18, 22, 24)
	panel.BackgroundTransparency = 0.12
	panel.BorderSizePixel = 0
	panel.Visible = false
	panel.Parent = gui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = panel

	local stroke = Instance.new("UIStroke")
	stroke.Color = ACCENT_COLOR
	stroke.Thickness = 1.8
	stroke.Parent = panel

	local title = Instance.new("TextLabel")
	title.Name = "ZoneNameLabel"
	title.Position = UDim2.fromOffset(14, 8)
	title.Size = UDim2.new(1, -28, 0, 22)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBold
	title.TextSize = 15
	title.TextColor3 = Color3.fromRGB(130, 245, 175)
	title.Text = ""
	title.Parent = panel

	local status = Instance.new("TextLabel")
	status.Name = "StatusLabel"
	status.Position = UDim2.fromOffset(14, 30)
	status.Size = UDim2.new(1, -28, 0, 18)
	status.BackgroundTransparency = 1
	status.Font = Enum.Font.GothamMedium
	status.TextSize = 13
	status.TextColor3 = Color3.fromRGB(235, 242, 238)
	status.Text = ""
	status.Parent = panel

	local progressBg = Instance.new("Frame")
	progressBg.Name = "ProgressBackground"
	progressBg.Position = UDim2.fromOffset(14, 54)
	progressBg.Size = UDim2.new(1, -28, 0, 12)
	progressBg.BackgroundColor3 = Color3.fromRGB(36, 44, 46)
	progressBg.BorderSizePixel = 0
	progressBg.Parent = panel

	local bgCorner = Instance.new("UICorner")
	bgCorner.CornerRadius = UDim.new(0, 6)
	bgCorner.Parent = progressBg

	local fill = Instance.new("Frame")
	fill.Name = "ProgressFill"
	fill.Size = UDim2.fromScale(0, 1)
	fill.BackgroundColor3 = ACCENT_COLOR
	fill.BorderSizePixel = 0
	fill.Parent = progressBg

	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(0, 6)
	fillCorner.Parent = fill

	gui.Parent = playerGui
	panelFrame = panel
	zoneNameLabel = title
	statusLabel = status
	progressFill = fill
end

local function isFiniteNumber(val: any): boolean
	return typeof(val) == "number" and val == val and math.abs(val) ~= math.huge
end

local function applyExtractionState(state: ExtractionState)
	currentState = state

	if not panelFrame or not zoneNameLabel or not statusLabel or not progressFill then
		return
	end

	if not state.Active then
		panelFrame.Visible = false
		progressFill.Size = UDim2.fromScale(0, 1)
		return
	end

	zoneNameLabel.Text = state.ZoneName

	if state.StatusText and #state.StatusText > 0 then
		statusLabel.Text = state.StatusText
	else
		statusLabel.Text = string.format("Extracting in %.1fs...", math.max(0, state.TimeLeft))
	end

	local totalTime = math.max(0.01, state.TotalTime)
	local progress = math.clamp(1 - (state.TimeLeft / totalTime), 0, 1)
	progressFill.Size = UDim2.fromScale(progress, 1)
	panelFrame.Visible = true
end

local function onExtractionStateSync(payloadAny: any)
	if type(payloadAny) ~= "table" then
		return
	end

	local active = payloadAny.Active
	local zoneName = payloadAny.ZoneName
	local timeLeft = payloadAny.TimeLeft
	local totalTime = payloadAny.TotalTime
	local statusText = payloadAny.StatusText

	if
		typeof(active) ~= "boolean"
		or typeof(zoneName) ~= "string"
		or not isFiniteNumber(timeLeft)
		or not isFiniteNumber(totalTime)
		or (statusText ~= nil and typeof(statusText) ~= "string")
	then
		return
	end

	applyExtractionState({
		Active = active,
		ZoneName = zoneName,
		TimeLeft = timeLeft,
		TotalTime = totalTime,
		StatusText = statusText,
	})
end

function ExtractionController.IsVisible(): boolean
	return panelFrame ~= nil and panelFrame.Visible
end

function ExtractionController.GetState(): ExtractionState?
	if currentState == nil then
		return nil
	end
	return {
		Active = currentState.Active,
		ZoneName = currentState.ZoneName,
		TimeLeft = currentState.TimeLeft,
		TotalTime = currentState.TotalTime,
		StatusText = currentState.StatusText,
	}
end

function ExtractionController.Init()
	if isInitialized then
		return
	end
	isInitialized = true

	createExtractionGui()
	Net.GetEvent(Net.Events.ExtractionStateSync).OnClientEvent:Connect(onExtractionStateSync)
end

return ExtractionController
