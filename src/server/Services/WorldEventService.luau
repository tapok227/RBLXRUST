--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Types = require(ReplicatedStorage.Shared.Types)
local Net = require(ReplicatedStorage.Shared.Net)
local LootService = require(ServerScriptService.Server.Services.LootService)

type WorldEventPayload = Types.WorldEventPayload

local SUPPLY_DROP_INTERVAL = 420
local SUPPLY_DROP_DURATION = 180
local SUPPLY_DROP_HEIGHT = 120
local SUPPLY_DROP_DESCENT_TIME = 6
local CRATE_HALF_HEIGHT = 1.6
local FALLBACK_MIN_RADIUS = 60
local FALLBACK_MAX_RADIUS = 140

local rng = Random.new()
local nextDropIndex = 0
local activeAirdropModel: Model? = nil
local activeAirdropContainerId: string? = nil
local isInitialized = false

local WorldEventService = {}

local function isValidNonNegativeNumber(val: any): boolean
	return typeof(val) == "number" and val == val and val >= 0 and val < math.huge
end

local function getOrCreateWorldEventsFolder(): Folder
	local existing = Workspace:FindFirstChild("WorldEvents")
	if existing and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = "WorldEvents"
	folder.Parent = Workspace
	return folder
end

local function raycastGroundY(x: number, z: number, excludeInstances: { Instance }): number
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = excludeInstances

	local result = Workspace:Raycast(Vector3.new(x, 100, z), Vector3.new(0, -250, 0), params)
	if result then
		return result.Position.Y
	end
	return 0
end

local function chooseDropPosition(worldEventsFolder: Folder): Vector3
	local exclude: { Instance } = { worldEventsFolder }
	local zonesFolder = Workspace:FindFirstChild("AirdropZones")
	if zonesFolder then
		table.insert(exclude, zonesFolder)
		local zones: { BasePart } = {}
		for _, child in zonesFolder:GetChildren() do
			if child:IsA("BasePart") then
				table.insert(zones, child)
			end
		end
		if #zones > 0 then
			local picked = zones[rng:NextInteger(1, #zones)]
			local groundY = raycastGroundY(picked.Position.X, picked.Position.Z, exclude)
			return Vector3.new(picked.Position.X, groundY, picked.Position.Z)
		end
	end

	local angle = rng:NextNumber(0, math.pi * 2)
	local radius = rng:NextNumber(FALLBACK_MIN_RADIUS, FALLBACK_MAX_RADIUS)
	local x = math.cos(angle) * radius
	local z = math.sin(angle) * radius
	local groundY = raycastGroundY(x, z, exclude)
	return Vector3.new(x, groundY, z)
end

local function buildSupplyDropModel(
	dropIndex: number,
	startCenter: Vector3,
	dropPos: Vector3,
	worldEventsFolder: Folder
): (Model, Model, ProximityPrompt)
	local crateModel = Instance.new("Model")
	crateModel.Name = string.format("SupplyDrop_%d", dropIndex)
	crateModel:SetAttribute("EventType", "Airdrop")
	crateModel:SetAttribute("EventPosition", dropPos)
	crateModel:SetAttribute("Landed", false)

	local crateBody = Instance.new("Part")
	crateBody.Name = "SupplyCrate"
	crateBody.Size = Vector3.new(4, 3.2, 4)
	crateBody.CFrame = CFrame.new(startCenter)
	crateBody.Anchored = true
	crateBody.CanCollide = true
	crateBody.Material = Enum.Material.Metal
	crateBody.Color = Color3.fromRGB(205, 130, 35)
	crateBody.Parent = crateModel

	local band = Instance.new("Part")
	band.Name = "CrateBand"
	band.Size = Vector3.new(4.15, 0.45, 4.15)
	band.CFrame = CFrame.new(startCenter)
	band.Anchored = true
	band.CanCollide = false
	band.Material = Enum.Material.Metal
	band.Color = Color3.fromRGB(58, 68, 56)
	band.Parent = crateModel

	local parachute = Instance.new("Model")
	parachute.Name = "Parachute"
	parachute.Parent = crateModel

	local canopy = Instance.new("Part")
	canopy.Name = "Canopy"
	canopy.Size = Vector3.new(10, 1.5, 10)
	canopy.CFrame = CFrame.new(startCenter + Vector3.new(0, 9, 0))
	canopy.Anchored = true
	canopy.CanCollide = false
	canopy.Material = Enum.Material.Fabric
	canopy.Color = Color3.fromRGB(235, 235, 240)
	canopy.Parent = parachute

	local harness = Instance.new("Part")
	harness.Name = "Harness"
	harness.Size = Vector3.new(0.4, 7, 0.4)
	harness.CFrame = CFrame.new(startCenter + Vector3.new(0, 4.8, 0))
	harness.Anchored = true
	harness.CanCollide = false
	harness.Material = Enum.Material.Metal
	harness.Color = Color3.fromRGB(85, 85, 90)
	harness.Parent = parachute

	local smoke = Instance.new("ParticleEmitter")
	smoke.Name = "SignalSmoke"
	smoke.Color = ColorSequence.new(Color3.fromRGB(255, 105, 45), Color3.fromRGB(200, 200, 205))
	smoke.Lifetime = NumberRange.new(3, 5)
	smoke.Rate = 18
	smoke.Speed = NumberRange.new(4, 7)
	smoke.Size = NumberSequence.new(1.5, 5)
	smoke.Transparency = NumberSequence.new(0.25, 1)
	smoke.EmissionDirection = Enum.NormalId.Top
	smoke.Parent = crateBody

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "SupplyDropPrompt"
	prompt.ActionText = "Open Supply Drop"
	prompt.ObjectText = "Supply Drop"
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 12
	prompt.RequiresLineOfSight = false
	prompt.Enabled = false
	prompt.Parent = crateBody

	crateModel.PrimaryPart = crateBody
	crateModel.Parent = worldEventsFolder

	return crateModel, parachute, prompt
end

function WorldEventService.TriggerAirdropNow(descentTimeOverride: number?): Model
	local worldEventsFolder = getOrCreateWorldEventsFolder()
	local dropPos = chooseDropPosition(worldEventsFolder)

	nextDropIndex += 1
	local startCFrame = CFrame.new(dropPos + Vector3.new(0, SUPPLY_DROP_HEIGHT + CRATE_HALF_HEIGHT, 0))
	local endCFrame = CFrame.new(dropPos + Vector3.new(0, CRATE_HALF_HEIGHT, 0))

	local crateModel, parachute, prompt =
		buildSupplyDropModel(nextDropIndex, startCFrame.Position, dropPos, worldEventsFolder)

	activeAirdropModel = crateModel
	activeAirdropContainerId = nil

	crateModel.Destroying:Connect(function()
		if activeAirdropModel == crateModel then
			activeAirdropModel = nil
			activeAirdropContainerId = nil
		end
	end)

	local payload: WorldEventPayload = {
		EventType = "Airdrop",
		Title = "Supply Drop Incoming!",
		Position = dropPos,
		Duration = SUPPLY_DROP_DURATION,
	}
	Net.GetEvent(Net.Events.WorldEventNotify):FireAllClients(payload)

	local effectiveDescentTime = SUPPLY_DROP_DESCENT_TIME
	if RunService:IsStudio() then
		if isValidNonNegativeNumber(descentTimeOverride) then
			effectiveDescentTime = descentTimeOverride :: number
		else
			local attrOverride = Workspace:GetAttribute("SupplyDropDescentTimeOverride")
			if isValidNonNegativeNumber(attrOverride) then
				effectiveDescentTime = attrOverride :: number
			end
		end
	end

	task.spawn(function()
		if effectiveDescentTime > 0 then
			local elapsed = 0
			while elapsed < effectiveDescentTime do
				local dt = RunService.Heartbeat:Wait()
				if not crateModel.Parent then
					return
				end
				elapsed += dt
				local alpha = math.clamp(elapsed / effectiveDescentTime, 0, 1)
				crateModel:PivotTo(startCFrame:Lerp(endCFrame, alpha))
			end
		end

		if not crateModel.Parent then
			return
		end

		crateModel:PivotTo(endCFrame)
		if parachute.Parent then
			parachute:Destroy()
		end

		local containerId =
			LootService.SpawnTemporaryContainer(crateModel, "Supply Drop", "airdrop", SUPPLY_DROP_DURATION)
		prompt.Enabled = true
		crateModel:SetAttribute("Landed", true)

		if activeAirdropModel == crateModel then
			activeAirdropContainerId = containerId
		end
	end)

	return crateModel
end

function WorldEventService.GetActiveAirdropModel(): Model?
	return activeAirdropModel
end

function WorldEventService.GetActiveAirdropContainerId(): string?
	return activeAirdropContainerId
end

function WorldEventService.Init()
	if isInitialized then
		return
	end
	isInitialized = true

	Net.InitServer()
	getOrCreateWorldEventsFolder()

	task.spawn(function()
		while true do
			task.wait(SUPPLY_DROP_INTERVAL)
			WorldEventService.TriggerAirdropNow()
		end
	end)

	if RunService:IsStudio() then
		Workspace:GetAttributeChangedSignal("TriggerAirdropNow"):Connect(function()
			if Workspace:GetAttribute("TriggerAirdropNow") == true then
				Workspace:SetAttribute("TriggerAirdropNow", false)
				WorldEventService.TriggerAirdropNow()
			end
		end)
	end
end

return WorldEventService
