--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Types = require(ReplicatedStorage.Shared.Types)
local Net = require(ReplicatedStorage.Shared.Net)
local Janitor = require(ReplicatedStorage.Shared.Janitor)

type WorldEventPayload = Types.WorldEventPayload

type ActiveBeacon = {
	Id: number,
	TargetPosition: Vector3,
	AnchorPart: Part,
	Billboard: BillboardGui,
	DistanceLabel: TextLabel,
	TrackedModel: Model?,
	Janitor: Janitor.Janitor,
	CleanedUp: boolean,
}

local BANNER_DURATION = 6
local HORIZONTAL_MATCH_EPSILON = 2

local screenGui: ScreenGui? = nil
local bannerFrame: Frame? = nil
local bannerTitleLabel: TextLabel? = nil
local bannerSubtitleLabel: TextLabel? = nil
local bannerToken = 0
local isBannerVisible = false

local nextBeaconId = 0
local activeBeacons: { [number]: ActiveBeacon } = {}
local isInitialized = false

local WorldEventController = {}

local function getOrCreateClientBeaconsFolder(): Folder
	local existing = Workspace:FindFirstChild("ClientEventBeacons")
	if existing and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = "ClientEventBeacons"
	folder.Parent = Workspace
	return folder
end

local function createWorldEventHud()
	local localPlayer = Players.LocalPlayer
	if not localPlayer then
		return
	end
	local playerGui = localPlayer:WaitForChild("PlayerGui") :: PlayerGui

	local existing = playerGui:FindFirstChild("WorldEventHudGui")
	if existing then
		existing:Destroy()
	end

	local gui = Instance.new("ScreenGui")
	gui.Name = "WorldEventHudGui"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.DisplayOrder = 20

	local frame = Instance.new("Frame")
	frame.Name = "BannerFrame"
	frame.AnchorPoint = Vector2.new(0.5, 0)
	frame.Position = UDim2.new(0.5, 0, 0, 18)
	frame.Size = UDim2.fromOffset(380, 54)
	frame.BackgroundColor3 = Color3.fromRGB(22, 22, 28)
	frame.BackgroundTransparency = 0.12
	frame.BorderSizePixel = 0
	frame.Visible = false
	frame.Parent = gui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = frame

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(235, 155, 45)
	stroke.Thickness = 1.5
	stroke.Parent = frame

	local title = Instance.new("TextLabel")
	title.Name = "TitleLabel"
	title.Position = UDim2.fromOffset(12, 6)
	title.Size = UDim2.new(1, -24, 0, 22)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBold
	title.TextSize = 16
	title.TextColor3 = Color3.fromRGB(255, 220, 130)
	title.Text = ""
	title.Parent = frame

	local subtitle = Instance.new("TextLabel")
	subtitle.Name = "SubtitleLabel"
	subtitle.Position = UDim2.fromOffset(12, 29)
	subtitle.Size = UDim2.new(1, -24, 0, 18)
	subtitle.BackgroundTransparency = 1
	subtitle.Font = Enum.Font.GothamMedium
	subtitle.TextSize = 12
	subtitle.TextColor3 = Color3.fromRGB(205, 205, 215)
	subtitle.Text = "Follow the beacon to the drop zone"
	subtitle.Parent = frame

	gui.Parent = playerGui
	screenGui = gui
	bannerFrame = frame
	bannerTitleLabel = title
	bannerSubtitleLabel = subtitle
end

local function showBanner(titleText: string)
	if not bannerFrame or not bannerTitleLabel then
		return
	end

	bannerToken += 1
	local token = bannerToken

	bannerTitleLabel.Text = titleText
	if bannerSubtitleLabel then
		bannerSubtitleLabel.Text = "Follow the beacon to the drop zone"
	end
	bannerFrame.Visible = true
	isBannerVisible = true

	task.delay(BANNER_DURATION, function()
		if bannerToken ~= token then
			return
		end
		isBannerVisible = false
		if bannerFrame then
			bannerFrame.Visible = false
		end
	end)
end

local function cleanupBeacon(beaconId: number)
	local beacon = activeBeacons[beaconId]
	if not beacon or beacon.CleanedUp then
		return
	end
	beacon.CleanedUp = true
	activeBeacons[beaconId] = nil
	beacon.Janitor:Destroy()
end

local function tryBindModel(beacon: ActiveBeacon, candidate: Instance)
	if beacon.CleanedUp or beacon.TrackedModel ~= nil then
		return
	end
	if not candidate:IsA("Model") then
		return
	end

	local attrPos = candidate:GetAttribute("EventPosition")
	if typeof(attrPos) ~= "Vector3" then
		return
	end

	local horizontalDist =
		Vector3.new(attrPos.X - beacon.TargetPosition.X, 0, attrPos.Z - beacon.TargetPosition.Z).Magnitude
	if horizontalDist >= HORIZONTAL_MATCH_EPSILON then
		return
	end

	beacon.TrackedModel = candidate
	beacon.Janitor:Add(candidate.AncestryChanged:Connect(function()
		if not candidate:IsDescendantOf(Workspace) then
			cleanupBeacon(beacon.Id)
		end
	end))
	beacon.Janitor:Add(candidate.Destroying:Connect(function()
		cleanupBeacon(beacon.Id)
	end))
end

local function attachWorldEventsWatcher(beacon: ActiveBeacon)
	local function watchFolder(folder: Instance)
		for _, child in folder:GetChildren() do
			tryBindModel(beacon, child)
		end
		beacon.Janitor:Add(folder.ChildAdded:Connect(function(child: Instance)
			tryBindModel(beacon, child)
		end))
	end

	local worldEventsFolder = Workspace:FindFirstChild("WorldEvents")
	if worldEventsFolder then
		watchFolder(worldEventsFolder)
	else
		local wsConn: RBXScriptConnection? = nil
		wsConn = Workspace.ChildAdded:Connect(function(child: Instance)
			if child.Name == "WorldEvents" then
				if wsConn then
					wsConn:Disconnect()
					wsConn = nil
				end
				watchFolder(child)
			end
		end)
		if wsConn then
			beacon.Janitor:Add(wsConn)
		end
	end
end

local function createBeacon(payload: WorldEventPayload)
	if not screenGui then
		return
	end

	nextBeaconId += 1
	local beaconId = nextBeaconId
	local beaconJanitor = Janitor.new()

	local anchorPart = Instance.new("Part")
	anchorPart.Name = string.format("BeaconAnchor_%d", beaconId)
	anchorPart.Size = Vector3.new(1, 1, 1)
	anchorPart.Position = payload.Position + Vector3.new(0, 2, 0)
	anchorPart.Anchored = true
	anchorPart.CanCollide = false
	anchorPart.CanQuery = false
	anchorPart.CanTouch = false
	anchorPart.Transparency = 1
	anchorPart.Parent = getOrCreateClientBeaconsFolder()
	beaconJanitor:Add(anchorPart)

	local billboard = Instance.new("BillboardGui")
	billboard.Name = string.format("WorldEventBeacon_%d", beaconId)
	billboard.AlwaysOnTop = true
	billboard.Size = UDim2.fromOffset(180, 52)
	billboard.StudsOffsetWorldSpace = Vector3.new(0, 5, 0)
	billboard.MaxDistance = 0
	billboard.Adornee = anchorPart
	billboard.Parent = screenGui
	beaconJanitor:Add(billboard)

	local badge = Instance.new("Frame")
	badge.Name = "Badge"
	badge.Size = UDim2.fromScale(1, 1)
	badge.BackgroundColor3 = Color3.fromRGB(20, 20, 26)
	badge.BackgroundTransparency = 0.15
	badge.BorderSizePixel = 0
	badge.Parent = billboard

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = badge

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(235, 155, 45)
	stroke.Thickness = 1.5
	stroke.Parent = badge

	local eventLabel = Instance.new("TextLabel")
	eventLabel.Name = "EventLabel"
	eventLabel.Position = UDim2.fromOffset(6, 4)
	eventLabel.Size = UDim2.new(1, -12, 0, 20)
	eventLabel.BackgroundTransparency = 1
	eventLabel.Font = Enum.Font.GothamBold
	eventLabel.TextSize = 13
	eventLabel.TextColor3 = Color3.fromRGB(255, 220, 130)
	eventLabel.Text = if payload.EventType == "Airdrop" then "Supply Drop" else payload.Title
	eventLabel.Parent = badge

	local distanceLabel = Instance.new("TextLabel")
	distanceLabel.Name = "DistanceLabel"
	distanceLabel.Position = UDim2.fromOffset(6, 25)
	distanceLabel.Size = UDim2.new(1, -12, 0, 20)
	distanceLabel.BackgroundTransparency = 1
	distanceLabel.Font = Enum.Font.GothamMedium
	distanceLabel.TextSize = 12
	distanceLabel.TextColor3 = Color3.fromRGB(235, 235, 240)
	distanceLabel.Text = "0 studs"
	distanceLabel.Parent = badge

	local beacon: ActiveBeacon = {
		Id = beaconId,
		TargetPosition = payload.Position,
		AnchorPart = anchorPart,
		Billboard = billboard,
		DistanceLabel = distanceLabel,
		TrackedModel = nil,
		Janitor = beaconJanitor,
		CleanedUp = false,
	}

	activeBeacons[beaconId] = beacon
	attachWorldEventsWatcher(beacon)

	task.delay(payload.Duration, function()
		cleanupBeacon(beaconId)
	end)
end

local function onWorldEventNotify(payloadAny: any)
	if type(payloadAny) ~= "table" then
		return
	end

	local eventType = payloadAny.EventType
	local title = payloadAny.Title
	local position = payloadAny.Position
	local duration = payloadAny.Duration

	if
		typeof(eventType) ~= "string"
		or typeof(title) ~= "string"
		or typeof(position) ~= "Vector3"
		or typeof(duration) ~= "number"
		or duration ~= duration
		or duration <= 0
		or duration == math.huge
	then
		return
	end

	local payload: WorldEventPayload = {
		EventType = eventType,
		Title = title,
		Position = position,
		Duration = duration,
	}

	showBanner(payload.Title)
	createBeacon(payload)
end

local function updateBeacons()
	local localPlayer = Players.LocalPlayer
	local origin: Vector3? = nil

	if localPlayer and localPlayer.Character then
		local hrp = localPlayer.Character:FindFirstChild("HumanoidRootPart")
		if hrp and hrp:IsA("BasePart") then
			origin = hrp.Position
		end
	end

	if not origin and Workspace.CurrentCamera then
		origin = Workspace.CurrentCamera.CFrame.Position
	end

	if not origin then
		return
	end

	for _, beacon in activeBeacons do
		local tracked = beacon.TrackedModel
		if tracked and tracked.Parent and tracked.PrimaryPart then
			beacon.AnchorPart.Position = tracked.PrimaryPart.Position
		end
		local dist = (origin - beacon.AnchorPart.Position).Magnitude
		beacon.DistanceLabel.Text = string.format("%d studs", math.floor(dist + 0.5))
	end
end

function WorldEventController.IsBannerVisible(): boolean
	return isBannerVisible
end

function WorldEventController.GetActiveBeaconCount(): number
	local count = 0
	for _ in activeBeacons do
		count += 1
	end
	return count
end

function WorldEventController.Init()
	if isInitialized then
		return
	end
	isInitialized = true

	createWorldEventHud()
	Net.GetEvent(Net.Events.WorldEventNotify).OnClientEvent:Connect(onWorldEventNotify)
	RunService.RenderStepped:Connect(updateBeacons)
end

return WorldEventController
