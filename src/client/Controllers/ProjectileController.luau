--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Types = require(ReplicatedStorage.Shared.Types)
local Projectiles = require(ReplicatedStorage.Shared.configs.Projectiles)
local Ballistics = require(ReplicatedStorage.Shared.Ballistics)
local Net = require(ReplicatedStorage.Shared.Net)

type ActiveVisualProjectile = {
	SimId: string,
	ServerId: string?,
	Model: Model,
	CreatedAt: number,
	CleanedUp: boolean,
}

type PlayerVisualRecord = {
	Model: Model?,
	Motor: Motor6D?,
	Connections: { RBXScriptConnection },
	CharacterConnections: { RBXScriptConnection },
}

local ROCKET_LAUNCHER_ITEM_ID = "rocket_launcher"
local VFX_FOLDER_NAME = "ClientProjectileVfx"
local EXPLOSION_SOUND_ID = "rbxasset://sounds/impact_explosion_03.mp3"
local TRAIL_FADE_DELAY = 0.7

local vfxFolder: Folder? = nil
local nextLocalSimSeq = 0
local activeVisualsBySimId: { [string]: ActiveVisualProjectile } = {}
local activeVisualsByServerId: { [string]: ActiveVisualProjectile } = {}
local pendingLocalQueue: { ActiveVisualProjectile } = {}
local playerVisuals: { [Player]: PlayerVisualRecord } = {}
local isInitialized = false

local ProjectileController = {}

local function getVfxFolder(): Folder
	if vfxFolder ~= nil and vfxFolder.Parent ~= nil then
		return vfxFolder
	end
	local existing = Workspace:FindFirstChild(VFX_FOLDER_NAME)
	if existing and existing:IsA("Folder") then
		vfxFolder = existing
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = VFX_FOLDER_NAME
	folder.Parent = Workspace
	vfxFolder = folder
	return folder
end

local function buildFallbackRocketLauncher(): Model
	local launcher = Instance.new("Model")
	launcher.Name = "RocketLauncher"

	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Size = Vector3.new(0.35, 0.75, 0.35)
	handle.CFrame = CFrame.new(0, 0, 0)
	handle.Material = Enum.Material.Metal
	handle.Color = Color3.fromRGB(45, 48, 52)
	handle.Anchored = false
	handle.CanCollide = false
	handle.CanQuery = false
	handle.CanTouch = false
	handle.Massless = true
	handle.TopSurface = Enum.SurfaceType.Smooth
	handle.BottomSurface = Enum.SurfaceType.Smooth
	handle.Parent = launcher

	local function addPart(name: string, shape: Enum.PartType, size: Vector3, cf: CFrame, color: Color3)
		local part = Instance.new("Part")
		part.Name = name
		part.Shape = shape
		part.Size = size
		part.CFrame = cf
		part.Material = Enum.Material.Metal
		part.Color = color
		part.Anchored = false
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.Massless = true
		part.TopSurface = Enum.SurfaceType.Smooth
		part.BottomSurface = Enum.SurfaceType.Smooth
		part.Parent = launcher

		local weld = Instance.new("WeldConstraint")
		weld.Part0 = handle
		weld.Part1 = part
		weld.Parent = part
	end

	addPart(
		"Tube",
		Enum.PartType.Cylinder,
		Vector3.new(3.8, 0.72, 0.72),
		CFrame.new(0, 0.55, -0.1) * CFrame.Angles(0, math.rad(90), 0),
		Color3.fromRGB(82, 96, 68)
	)
	addPart(
		"MuzzleRing",
		Enum.PartType.Cylinder,
		Vector3.new(0.26, 0.82, 0.82),
		CFrame.new(0, 0.55, -1.9) * CFrame.Angles(0, math.rad(90), 0),
		Color3.fromRGB(42, 45, 48)
	)
	addPart(
		"ExhaustBell",
		Enum.PartType.Cylinder,
		Vector3.new(0.34, 0.86, 0.86),
		CFrame.new(0, 0.55, 1.72) * CFrame.Angles(0, math.rad(90), 0),
		Color3.fromRGB(42, 45, 48)
	)
	addPart(
		"SightRail",
		Enum.PartType.Block,
		Vector3.new(0.14, 0.28, 0.6),
		CFrame.new(-0.28, 0.92, -0.55),
		Color3.fromRGB(36, 38, 42)
	)

	launcher.PrimaryPart = handle
	launcher.WorldPivot = handle.CFrame
	return launcher
end

local function buildFallbackRocket(): Model
	local rocket = Instance.new("Model")
	rocket.Name = "Rocket"

	local body = Instance.new("Part")
	body.Name = "Body"
	body.Size = Vector3.new(0.36, 0.36, 1.8)
	body.CFrame = CFrame.new(0, 0, 0)
	body.Transparency = 1
	body.Anchored = true
	body.CanCollide = false
	body.CanQuery = false
	body.CanTouch = false
	body.Massless = true
	body.CastShadow = false
	body.Parent = rocket

	local shaft = Instance.new("Part")
	shaft.Name = "Shaft"
	shaft.Shape = Enum.PartType.Cylinder
	shaft.Size = Vector3.new(1.45, 0.32, 0.32)
	shaft.CFrame = CFrame.new(0, 0, 0.05) * CFrame.Angles(0, math.rad(90), 0)
	shaft.Material = Enum.Material.Metal
	shaft.Color = Color3.fromRGB(92, 102, 92)
	shaft.Anchored = true
	shaft.CanCollide = false
	shaft.CanQuery = false
	shaft.CanTouch = false
	shaft.Massless = true
	shaft.Parent = rocket

	local warhead = Instance.new("Part")
	warhead.Name = "Warhead"
	warhead.Shape = Enum.PartType.Ball
	warhead.Size = Vector3.new(0.36, 0.36, 0.36)
	warhead.CFrame = CFrame.new(0, 0, -0.72)
	warhead.Material = Enum.Material.Metal
	warhead.Color = Color3.fromRGB(195, 52, 42)
	warhead.Anchored = true
	warhead.CanCollide = false
	warhead.CanQuery = false
	warhead.CanTouch = false
	warhead.Massless = true
	warhead.Parent = rocket

	local thruster = Instance.new("Part")
	thruster.Name = "ThrusterGlow"
	thruster.Shape = Enum.PartType.Ball
	thruster.Size = Vector3.new(0.26, 0.26, 0.26)
	thruster.CFrame = CFrame.new(0, 0, 0.8)
	thruster.Material = Enum.Material.Neon
	thruster.Color = Color3.fromRGB(255, 145, 40)
	thruster.Anchored = true
	thruster.CanCollide = false
	thruster.CanQuery = false
	thruster.CanTouch = false
	thruster.Massless = true
	thruster.CastShadow = false
	thruster.Parent = rocket

	local trailTop = Instance.new("Attachment")
	trailTop.Name = "TrailTop"
	trailTop.Position = Vector3.new(0, 0.14, 0.82)
	trailTop.Parent = body

	local trailBottom = Instance.new("Attachment")
	trailBottom.Name = "TrailBottom"
	trailBottom.Position = Vector3.new(0, -0.14, 0.82)
	trailBottom.Parent = body

	local trail = Instance.new("Trail")
	trail.Name = "FlightTrail"
	trail.Attachment0 = trailTop
	trail.Attachment1 = trailBottom
	trail.Lifetime = 0.65
	trail.MinLength = 0.1
	trail.FaceCamera = true
	trail.Color = ColorSequence.new(Color3.fromRGB(255, 175, 70), Color3.fromRGB(200, 200, 205))
	trail.Transparency = NumberSequence.new(0.15, 1)
	trail.Parent = body

	local smoke = Instance.new("ParticleEmitter")
	smoke.Name = "SmokeEmitter"
	smoke.Color = ColorSequence.new(Color3.fromRGB(195, 195, 200), Color3.fromRGB(120, 120, 125))
	smoke.Size = NumberSequence.new(0.45, 1.4)
	smoke.Transparency = NumberSequence.new(0.35, 1)
	smoke.Lifetime = NumberRange.new(0.45, 0.85)
	smoke.Rate = 45
	smoke.Speed = NumberRange.new(1, 3)
	smoke.Parent = thruster

	rocket.PrimaryPart = body
	rocket.WorldPivot = body.CFrame
	return rocket
end

local function cloneLauncherTemplate(): Model
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local weapons = if assets then assets:FindFirstChild("Weapons") else nil
	local template = if weapons then weapons:FindFirstChild("RocketLauncher") else nil
	local model = if template and template:IsA("Model") then template:Clone() else buildFallbackRocketLauncher()

	for _, desc in model:GetDescendants() do
		if desc:IsA("BasePart") then
			desc.Anchored = false
			desc.CanCollide = false
			desc.CanQuery = false
			desc.CanTouch = false
			desc.Massless = true
		end
	end
	return model
end

local function cloneRocketTemplate(): Model
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local projectiles = if assets then assets:FindFirstChild("Projectiles") else nil
	local template = if projectiles then projectiles:FindFirstChild("Rocket") else nil
	local model = if template and template:IsA("Model") then template:Clone() else buildFallbackRocket()

	for _, desc in model:GetDescendants() do
		if desc:IsA("BasePart") then
			desc.Anchored = true
			desc.CanCollide = false
			desc.CanQuery = false
			desc.CanTouch = false
			desc.Massless = true
		end
	end
	return model
end

local function playSoundAtPosition(position: Vector3, playbackSpeed: number, volume: number, maxDist: number)
	local anchor = Instance.new("Part")
	anchor.Name = "ProjectileSoundAnchor"
	anchor.Size = Vector3.new(0.2, 0.2, 0.2)
	anchor.Position = position
	anchor.Transparency = 1
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.CastShadow = false
	anchor.Parent = getVfxFolder()

	local sound = Instance.new("Sound")
	sound.SoundId = EXPLOSION_SOUND_ID
	sound.Volume = volume
	sound.PlaybackSpeed = playbackSpeed
	sound.RollOffMaxDistance = maxDist
	sound.Parent = anchor
	sound:Play()

	sound.Ended:Once(function()
		if anchor.Parent then
			anchor:Destroy()
		end
	end)

	task.delay(4.0, function()
		if anchor.Parent then
			anchor:Destroy()
		end
	end)
end

local function cleanupVisualRecord(record: ActiveVisualProjectile)
	if record.CleanedUp then
		return
	end
	record.CleanedUp = true
	activeVisualsBySimId[record.SimId] = nil
	if record.ServerId ~= nil and activeVisualsByServerId[record.ServerId] == record then
		activeVisualsByServerId[record.ServerId] = nil
	end
	if record.Model.Parent then
		record.Model:Destroy()
	end
end

local function hideVisualBodyAndFadeTrail(record: ActiveVisualProjectile)
	if record.CleanedUp then
		return
	end
	for _, desc in record.Model:GetDescendants() do
		if desc:IsA("BasePart") then
			desc.Transparency = 1
		elseif desc:IsA("ParticleEmitter") then
			desc.Enabled = false
		end
	end
	task.delay(TRAIL_FADE_DELAY, function()
		cleanupVisualRecord(record)
	end)
end

local function spawnVisualBallistic(
	serverId: string?,
	origin: Vector3,
	initialVelocity: Vector3,
	gravity: number,
	maxLifetime: number,
	excludeInstances: { Instance }
): ActiveVisualProjectile
	nextLocalSimSeq += 1
	local simId = string.format("vis_proj_%d", nextLocalSimSeq)

	local rocketModel = cloneRocketTemplate()
	rocketModel.Name = if serverId ~= nil then serverId else simId
	rocketModel:PivotTo(Ballistics.ComputeCFrame(origin, initialVelocity))
	rocketModel.Parent = getVfxFolder()

	local record: ActiveVisualProjectile = {
		SimId = simId,
		ServerId = serverId,
		Model = rocketModel,
		CreatedAt = os.clock(),
		CleanedUp = false,
	}

	activeVisualsBySimId[simId] = record
	if serverId ~= nil then
		activeVisualsByServerId[serverId] = record
	end

	Ballistics.Spawn({
		Id = simId,
		Origin = origin,
		InitialVelocity = initialVelocity,
		Gravity = gravity,
		MaxLifetime = maxLifetime,
		ExcludeInstances = excludeInstances,
		OnStep = function(pos: Vector3, vel: Vector3)
			if not record.CleanedUp and record.Model.Parent then
				record.Model:PivotTo(Ballistics.ComputeCFrame(pos, vel))
			end
		end,
		OnHit = function(hitResult: RaycastResult, vel: Vector3)
			if not record.CleanedUp and record.Model.Parent then
				record.Model:PivotTo(Ballistics.ComputeCFrame(hitResult.Position, vel))
				hideVisualBodyAndFadeTrail(record)
			end
		end,
		OnExpire = function()
			hideVisualBodyAndFadeTrail(record)
		end,
	})

	return record
end

local function clearEquippedVisual(player: Player)
	local rec = playerVisuals[player]
	if rec == nil then
		return
	end
	if rec.Motor ~= nil then
		rec.Motor:Destroy()
		rec.Motor = nil
	end
	if rec.Model ~= nil then
		rec.Model:Destroy()
		rec.Model = nil
	end
end

local function clearCharacterConnections(rec: PlayerVisualRecord)
	for _, conn in rec.CharacterConnections do
		conn:Disconnect()
	end
	table.clear(rec.CharacterConnections)
end

local function refreshEquippedVisual(player: Player)
	local rec = playerVisuals[player]
	if rec == nil then
		return
	end

	clearEquippedVisual(player)

	if player:GetAttribute("EquippedItemId") ~= ROCKET_LAUNCHER_ITEM_ID then
		return
	end

	local character = player.Character
	if character == nil or character.Parent == nil then
		return
	end

	local rightHand = character:FindFirstChild("RightHand") or character:FindFirstChild("Right Arm")
	if rightHand == nil or not rightHand:IsA("BasePart") then
		return
	end

	local model = cloneLauncherTemplate()
	local handle = model.PrimaryPart or model:FindFirstChild("Handle")
	if handle == nil or not handle:IsA("BasePart") then
		model:Destroy()
		return
	end

	local motor = Instance.new("Motor6D")
	motor.Name = "WeaponGripMotor"
	motor.Part0 = rightHand
	motor.Part1 = handle
	motor.C0 = if rightHand.Name == "RightHand" then CFrame.new(0, -0.25, -0.35) else CFrame.new(0, -0.85, -0.35)
	motor.C1 = CFrame.new()
	motor.Parent = rightHand

	model.Name = "EquippedWeaponVisual"
	model.Parent = character

	rec.Model = model
	rec.Motor = motor
end

local function bindCharacter(player: Player, character: Model)
	local rec = playerVisuals[player]
	if rec == nil then
		return
	end

	clearCharacterConnections(rec)
	refreshEquippedVisual(player)

	local childConn = character.ChildAdded:Connect(function(child: Instance)
		if child:IsA("BasePart") and (child.Name == "RightHand" or child.Name == "Right Arm") then
			refreshEquippedVisual(player)
		end
	end)
	table.insert(rec.CharacterConnections, childConn)
end

local function bindPlayer(player: Player)
	if playerVisuals[player] ~= nil then
		return
	end

	local rec: PlayerVisualRecord = {
		Model = nil,
		Motor = nil,
		Connections = {},
		CharacterConnections = {},
	}
	playerVisuals[player] = rec

	table.insert(
		rec.Connections,
		player:GetAttributeChangedSignal("EquippedItemId"):Connect(function()
			refreshEquippedVisual(player)
		end)
	)

	table.insert(
		rec.Connections,
		player.CharacterAdded:Connect(function(character: Model)
			bindCharacter(player, character)
		end)
	)

	table.insert(
		rec.Connections,
		player.CharacterRemoving:Connect(function()
			clearCharacterConnections(rec)
			clearEquippedVisual(player)
		end)
	)

	if player.Character ~= nil then
		bindCharacter(player, player.Character)
	end
end

local function onProjectileSpawn(
	projectileIdAny: any,
	shooterAny: any,
	projectileConfigIdAny: any,
	originAny: any,
	velocityAny: any,
	gravityAny: any
)
	if
		typeof(projectileIdAny) ~= "string"
		or typeof(projectileConfigIdAny) ~= "string"
		or typeof(originAny) ~= "Vector3"
		or typeof(velocityAny) ~= "Vector3"
		or typeof(gravityAny) ~= "number"
	then
		return
	end

	local projectileId = projectileIdAny :: string
	local origin = originAny :: Vector3
	local velocity = velocityAny :: Vector3
	local gravity = gravityAny :: number

	if shooterAny == Players.LocalPlayer then
		local now = os.clock()
		while #pendingLocalQueue > 0 do
			local pending = table.remove(pendingLocalQueue, 1)
			if pending ~= nil and (now - pending.CreatedAt) <= 2.0 then
				if not pending.CleanedUp then
					pending.ServerId = projectileId
					activeVisualsByServerId[projectileId] = pending
				end
				return
			end
		end
	end

	local projCfg = Projectiles[projectileConfigIdAny]
	local maxLifetime = if projCfg
		then math.min(projCfg.MaxLifetime, Types.MAX_PROJECTILE_LIFETIME)
		else Types.MAX_PROJECTILE_LIFETIME

	local excludes: { Instance } = { getVfxFolder() }
	if typeof(shooterAny) == "Instance" and shooterAny:IsA("Player") and shooterAny.Character ~= nil then
		table.insert(excludes, shooterAny.Character)
	end

	spawnVisualBallistic(projectileId, origin, velocity, gravity, maxLifetime, excludes)
	playSoundAtPosition(origin, 1.85, 0.55, 180)
end

local function onExplosionEffect(originAny: any, radiusAny: any, _sourceIdAny: any, projectileIdAny: any)
	if typeof(originAny) ~= "Vector3" or typeof(radiusAny) ~= "number" then
		return
	end

	local origin = originAny :: Vector3
	local radius = math.clamp(radiusAny :: number, 1, 60)

	if typeof(projectileIdAny) == "string" then
		local record = activeVisualsByServerId[projectileIdAny]
		if record ~= nil then
			Ballistics.Cancel(record.SimId)
			hideVisualBodyAndFadeTrail(record)
		end
	end

	local folder = getVfxFolder()

	local explosion = Instance.new("Explosion")
	explosion.Position = origin
	explosion.BlastRadius = radius
	explosion.BlastPressure = 0
	explosion.DestroyJointRadiusPercent = 0
	explosion.ExplosionType = Enum.ExplosionType.NoCraters
	explosion.Parent = folder

	local fireball = Instance.new("Part")
	fireball.Name = "ExplosionFireball"
	fireball.Shape = Enum.PartType.Ball
	fireball.Size = Vector3.new(2, 2, 2)
	fireball.Position = origin
	fireball.Material = Enum.Material.Neon
	fireball.Color = Color3.fromRGB(255, 140, 45)
	fireball.Transparency = 0.15
	fireball.Anchored = true
	fireball.CanCollide = false
	fireball.CanQuery = false
	fireball.CanTouch = false
	fireball.CastShadow = false
	fireball.Parent = folder

	local targetSize = Vector3.new(radius * 1.1, radius * 1.1, radius * 1.1)
	local tween = TweenService:Create(
		fireball,
		TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = targetSize, Transparency = 1 }
	)
	tween:Play()

	task.delay(0.38, function()
		if fireball.Parent then
			fireball:Destroy()
		end
	end)

	task.delay(2.0, function()
		if explosion.Parent then
			explosion:Destroy()
		end
	end)

	playSoundAtPosition(origin, 1.0, 1.0, 320)
end

function ProjectileController.SpawnLocalProjectile(
	projectileConfigId: string,
	origin: Vector3,
	direction: Vector3,
	shooterCharacter: Model
): string
	local projCfg = Projectiles[projectileConfigId]
	if projCfg == nil then
		return ""
	end

	local unitDir = if direction.Magnitude > 1e-4 then direction.Unit else Vector3.new(0, 0, -1)
	local initialVelocity = unitDir * projCfg.Speed
	local maxLifetime = math.min(projCfg.MaxLifetime, Types.MAX_PROJECTILE_LIFETIME)

	local record = spawnVisualBallistic(
		nil,
		origin,
		initialVelocity,
		projCfg.Gravity,
		maxLifetime,
		{ shooterCharacter, getVfxFolder() }
	)
	table.insert(pendingLocalQueue, record)
	playSoundAtPosition(origin, 1.85, 0.55, 180)

	return record.SimId
end

function ProjectileController.GetActiveVisualCount(): number
	local count = 0
	for _ in activeVisualsBySimId do
		count += 1
	end
	return count
end

function ProjectileController.Init()
	if isInitialized then
		return
	end
	isInitialized = true

	Net.GetEvent(Net.Events.ProjectileSpawn).OnClientEvent:Connect(onProjectileSpawn)
	Net.GetEvent(Net.Events.ExplosionEffect).OnClientEvent:Connect(onExplosionEffect)

	for _, player in Players:GetPlayers() do
		bindPlayer(player)
	end

	Players.PlayerAdded:Connect(bindPlayer)

	Players.PlayerRemoving:Connect(function(player: Player)
		local rec = playerVisuals[player]
		if rec ~= nil then
			clearCharacterConnections(rec)
			clearEquippedVisual(player)
			for _, conn in rec.Connections do
				conn:Disconnect()
			end
			playerVisuals[player] = nil
		end
	end)
end

return ProjectileController
