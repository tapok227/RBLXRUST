--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)
local Types = require(ReplicatedStorage.Shared.Types)
local NPCs = require(ReplicatedStorage.Shared.configs.NPCs)
local Ballistics = require(ReplicatedStorage.Shared.Ballistics)
local Janitor = require(ReplicatedStorage.Shared.Janitor)
local Net = require(ReplicatedStorage.Shared.Net)
local LootService = require(ServerScriptService.Server.Services.LootService)
local SurvivalService = require(ServerScriptService.Server.Services.SurvivalService)

type NPCConfig = Types.NPCConfig
type NPCState = Types.NPCState
type Inventory = Types.Inventory

type SpawnMarkerRecord = {
	Part: BasePart,
	NPCType: string,
	Config: NPCConfig,
	RespawnTime: number,
	PatrolRadius: number,
	SpawnPosition: Vector3,
	ActiveNpc: ActiveNpcRecord?,
	RespawnThread: thread?,
	Destroyed: boolean,
}

type ActiveNpcRecord = {
	Id: string,
	Marker: SpawnMarkerRecord,
	Config: NPCConfig,
	Model: Model,
	Humanoid: Humanoid,
	RootPart: BasePart,
	Head: BasePart,
	Muzzle: BasePart?,
	Janitor: Janitor.Janitor,
	State: NPCState,
	TargetPlayer: Player?,
	ThreatPosition: Vector3?,
	LastSeenTime: number,
	AlertUntil: number,
	StateUntil: number,
	NextMoveTime: number,
	NextAttackTime: number,
	ReturnStartedAt: number,
	StrafeSign: number,
	BurstActive: boolean,
	ActiveBurstThread: thread?,
	Alive: boolean,
	PrevHealth: number,
	HpFill: Frame?,
	HpLabel: TextLabel?,
	HpBillboard: BillboardGui?,
}

local AI_TICK_INTERVAL = 0.25
local TRACER_BROADCAST_RADIUS = 250
local LOOT_LOST_LOS_TIMEOUT = 5.0
local GUARD_ALERT_DELAY = 0.45
local FLEE_DURATION = 6.0
local OUT_OF_COMBAT_REGEN_PER_TICK = 2.0
local MAX_LOS_FILTER_PASSES = 6

local rng = Random.new()
local nextNpcSeq = 0
local nextBulletSeq = 0
local nextBagSeq = 0

local markerRecordsByPart: { [BasePart]: SpawnMarkerRecord } = {}
local activeNpcs: { [string]: ActiveNpcRecord } = {}
local activeNpcCount = 0
local serverHasPlayers = false
local aiLoopThread: thread? = nil
local isInitialized = false

local NPCService = {}

local function isMainMapPlace(): boolean
	return game.PlaceId ~= Config.Places.PlayerBase and Workspace:GetAttribute("RaidServerMode") ~= true
end

local function getOrCreateFolder(name: string): Folder
	local existing = Workspace:FindFirstChild(name)
	if existing and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = Workspace
	return folder
end

local function hasAnyLootSlots(slots: Inventory): boolean
	for i = 1, Types.INVENTORY_SIZE do
		local slot = slots[i]
		if slot ~= nil and slot.Count > 0 then
			return true
		end
	end
	return false
end

local function getAlivePlayerParts(player: Player): (Model?, BasePart?, Humanoid?)
	if player.Parent ~= Players then
		return nil, nil, nil
	end
	if player:GetAttribute("InRaid") == true then
		return nil, nil, nil
	end
	local character = player.Character
	if not character then
		return nil, nil, nil
	end
	if character:GetAttribute("RaidInvulnerable") == true or character:FindFirstChildOfClass("ForceField") ~= nil then
		return nil, nil, nil
	end
	local hrp = character:FindFirstChild("HumanoidRootPart")
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if hrp and hrp:IsA("BasePart") and humanoid and humanoid.Health > 0 then
		return character, hrp, humanoid
	end
	return nil, nil, nil
end

local function raycastGroundY(x: number, refY: number, z: number, excludeList: { Instance }): number?
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.IgnoreWater = true
	params.FilterDescendantsInstances = excludeList

	local origin = Vector3.new(x, refY + 12, z)
	local result = Workspace:Raycast(origin, Vector3.new(0, -45, 0), params)
	if result then
		return result.Position.Y
	end
	return nil
end

local function buildEnvironmentExcludeList(): { Instance }
	local exclude: { Instance } = {}
	local activeFolder = Workspace:FindFirstChild("ActiveNPCs")
	if activeFolder then
		table.insert(exclude, activeFolder)
	end
	local spawnsFolder = Workspace:FindFirstChild("NPCSpawns")
	if spawnsFolder then
		table.insert(exclude, spawnsFolder)
	end
	local lootFolder = Workspace:FindFirstChild("LootContainers")
	if lootFolder then
		table.insert(exclude, lootFolder)
	end
	return exclude
end

local function hasLineOfSight(
	origin: Vector3,
	targetPart: BasePart,
	targetChar: Model,
	excludeBase: { Instance }
): boolean
	local delta = targetPart.Position - origin
	if delta.Magnitude <= 0.1 then
		return true
	end

	local excludeCopy = table.clone(excludeBase)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.IgnoreWater = true
	params.FilterDescendantsInstances = excludeCopy

	for _ = 1, MAX_LOS_FILTER_PASSES do
		local result = Workspace:Raycast(origin, delta, params)
		if result == nil then
			return true
		end
		if result.Instance:IsDescendantOf(targetChar) then
			return true
		end
		if result.Instance.CanCollide == false and not result.Instance:IsA("Terrain") then
			table.insert(excludeCopy, result.Instance)
			params.FilterDescendantsInstances = excludeCopy
		else
			return false
		end
	end

	return false
end

local function findNearestPlayer(
	origin: Vector3,
	radius: number,
	requireLos: boolean,
	excludeBase: { Instance }
): (Player?, Model?, BasePart?, number)
	local bestPlayer: Player? = nil
	local bestChar: Model? = nil
	local bestHrp: BasePart? = nil
	local bestDist = radius + 0.01

	for _, player in Players:GetPlayers() do
		local char, hrp = getAlivePlayerParts(player)
		if char ~= nil and hrp ~= nil then
			local dist = (hrp.Position - origin).Magnitude
			if dist <= radius and dist < bestDist then
				if not requireLos or hasLineOfSight(origin, hrp, char, excludeBase) then
					bestDist = dist
					bestPlayer = player
					bestChar = char
					bestHrp = hrp
				end
			end
		end
	end

	return bestPlayer, bestChar, bestHrp, bestDist
end

local function createPrimitivePart(
	parent: Instance,
	name: string,
	className: string,
	size: Vector3,
	cframe: CFrame,
	color: Color3,
	material: Enum.Material,
	canCollide: boolean,
	massless: boolean
): BasePart
	local part: BasePart
	if className == "WedgePart" then
		part = Instance.new("WedgePart")
	else
		part = Instance.new("Part")
	end
	part.Name = name
	part.Size = size
	part.CFrame = cframe
	part.Color = color
	part.Material = material
	part.Anchored = false
	part.CanCollide = canCollide
	part.Massless = massless
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

local function weldParts(root: BasePart, part: BasePart)
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = root
	weld.Part1 = part
	weld.Parent = part
end

local function attachHpBillboard(head: BasePart, cfg: NPCConfig, studsOffset: Vector3): (BillboardGui, Frame, TextLabel)
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "HpBillboard"
	billboard.Adornee = head
	billboard.Size = UDim2.fromOffset(116, 34)
	billboard.StudsOffset = studsOffset
	billboard.AlwaysOnTop = false
	billboard.MaxDistance = 95
	billboard.Enabled = false
	billboard.Parent = head

	local bg = Instance.new("Frame")
	bg.Name = "Container"
	bg.Size = UDim2.fromScale(1, 1)
	bg.BackgroundColor3 = Color3.fromRGB(20, 22, 26)
	bg.BackgroundTransparency = 0.2
	bg.BorderSizePixel = 0
	bg.Parent = billboard

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 5)
	corner.Parent = bg

	local nameLabel = Instance.new("TextLabel")
	nameLabel.Name = "NameLabel"
	nameLabel.Position = UDim2.fromOffset(4, 1)
	nameLabel.Size = UDim2.new(1, -8, 0, 14)
	nameLabel.BackgroundTransparency = 1
	nameLabel.Font = Enum.Font.GothamBold
	nameLabel.TextSize = 11
	nameLabel.TextColor3 = Color3.fromRGB(240, 240, 245)
	nameLabel.Text = cfg.DisplayName
	nameLabel.Parent = bg

	local barBg = Instance.new("Frame")
	barBg.Name = "BarBg"
	barBg.Position = UDim2.fromOffset(5, 17)
	barBg.Size = UDim2.new(1, -10, 0, 12)
	barBg.BackgroundColor3 = Color3.fromRGB(45, 45, 52)
	barBg.BorderSizePixel = 0
	barBg.Parent = bg

	local barCorner = Instance.new("UICorner")
	barCorner.CornerRadius = UDim.new(0, 3)
	barCorner.Parent = barBg

	local fill = Instance.new("Frame")
	fill.Name = "HpFill"
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundColor3 = Color3.fromRGB(80, 205, 95)
	fill.BorderSizePixel = 0
	fill.Parent = barBg

	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(0, 3)
	fillCorner.Parent = fill

	local hpLabel = Instance.new("TextLabel")
	hpLabel.Name = "HpLabel"
	hpLabel.Size = UDim2.fromScale(1, 1)
	hpLabel.BackgroundTransparency = 1
	hpLabel.ZIndex = 2
	hpLabel.Font = Enum.Font.GothamBold
	hpLabel.TextSize = 10
	hpLabel.TextColor3 = Color3.new(1, 1, 1)
	hpLabel.TextStrokeTransparency = 0.45
	hpLabel.Text = string.format("%d / %d", cfg.MaxHealth, cfg.MaxHealth)
	hpLabel.Parent = barBg

	return billboard, fill, hpLabel
end

local function buildGuardModel(
	npcId: string,
	cfg: NPCConfig,
	spawnPos: Vector3
): (Model, Humanoid, BasePart, BasePart, BasePart?, BillboardGui, Frame, TextLabel)
	local model = Instance.new("Model")
	model.Name = npcId

	local rootCF = CFrame.new(spawnPos + Vector3.new(0, 3.0, 0))
	local hrp = createPrimitivePart(
		model,
		"HumanoidRootPart",
		"Part",
		Vector3.new(2, 2, 1),
		rootCF,
		cfg.PrimaryColor,
		Enum.Material.SmoothPlastic,
		false,
		false
	)
	hrp.Transparency = 1
	hrp.RootPriority = 1

	local torso = createPrimitivePart(
		model,
		"Torso",
		"Part",
		Vector3.new(2, 2, 1),
		rootCF,
		cfg.PrimaryColor,
		Enum.Material.Fabric,
		true,
		true
	)
	weldParts(hrp, torso)

	local vest = createPrimitivePart(
		model,
		"Vest",
		"Part",
		Vector3.new(2.15, 1.45, 1.18),
		rootCF * CFrame.new(0, 0.1, 0),
		cfg.SecondaryColor,
		Enum.Material.Metal,
		false,
		true
	)
	weldParts(hrp, vest)

	local leftArm = createPrimitivePart(
		model,
		"LeftArm",
		"Part",
		Vector3.new(0.85, 1.9, 0.85),
		rootCF * CFrame.new(-1.48, 0.05, 0),
		cfg.PrimaryColor,
		Enum.Material.Fabric,
		false,
		true
	)
	weldParts(hrp, leftArm)

	local rightArm = createPrimitivePart(
		model,
		"RightArm",
		"Part",
		Vector3.new(0.85, 1.9, 0.85),
		rootCF * CFrame.new(1.42, 0.2, -0.45) * CFrame.Angles(math.rad(75), 0, 0),
		cfg.PrimaryColor,
		Enum.Material.Fabric,
		false,
		true
	)
	weldParts(hrp, rightArm)

	local leftLeg = createPrimitivePart(
		model,
		"LeftLeg",
		"Part",
		Vector3.new(0.9, 2.0, 0.9),
		rootCF * CFrame.new(-0.55, -2.0, 0),
		cfg.SecondaryColor,
		Enum.Material.Fabric,
		false,
		true
	)
	weldParts(hrp, leftLeg)

	local rightLeg = createPrimitivePart(
		model,
		"RightLeg",
		"Part",
		Vector3.new(0.9, 2.0, 0.9),
		rootCF * CFrame.new(0.55, -2.0, 0),
		cfg.SecondaryColor,
		Enum.Material.Fabric,
		false,
		true
	)
	weldParts(hrp, rightLeg)

	local headColor = if cfg.Id == "rt_scientist" then cfg.PrimaryColor else Color3.fromRGB(220, 185, 150)
	local head = createPrimitivePart(
		model,
		"Head",
		"Part",
		Vector3.new(1.3, 1.3, 1.3),
		rootCF * CFrame.new(0, 1.7, 0),
		headColor,
		Enum.Material.SmoothPlastic,
		true,
		true
	)
	weldParts(hrp, head)

	local helmet = createPrimitivePart(
		model,
		"Helmet",
		"Part",
		Vector3.new(1.48, 0.55, 1.48),
		rootCF * CFrame.new(0, 2.22, 0),
		cfg.SecondaryColor,
		Enum.Material.Metal,
		false,
		true
	)
	weldParts(hrp, helmet)

	local visor = createPrimitivePart(
		model,
		"Visor",
		"WedgePart",
		Vector3.new(1.18, 0.44, 0.35),
		rootCF * CFrame.new(0, 1.82, -0.68),
		cfg.AccentColor,
		Enum.Material.Neon,
		false,
		true
	)
	weldParts(hrp, visor)

	local gunBody = createPrimitivePart(
		model,
		"GunBody",
		"Part",
		Vector3.new(0.28, 0.4, 1.55),
		rootCF * CFrame.new(1.32, 0.25, -1.25),
		Color3.fromRGB(40, 42, 46),
		Enum.Material.Metal,
		false,
		true
	)
	weldParts(hrp, gunBody)

	local gunBarrel = createPrimitivePart(
		model,
		"GunBarrel",
		"Part",
		Vector3.new(0.14, 0.14, 1.0),
		rootCF * CFrame.new(1.32, 0.32, -2.35),
		Color3.fromRGB(28, 30, 34),
		Enum.Material.Metal,
		false,
		true
	)
	weldParts(hrp, gunBarrel)

	local muzzle = createPrimitivePart(
		model,
		"Muzzle",
		"Part",
		Vector3.new(0.18, 0.18, 0.18),
		rootCF * CFrame.new(1.32, 0.32, -2.95),
		cfg.AccentColor,
		Enum.Material.SmoothPlastic,
		false,
		true
	)
	muzzle.Transparency = 1
	muzzle.CanQuery = false
	muzzle.CanTouch = false
	weldParts(hrp, muzzle)

	local humanoid = Instance.new("Humanoid")
	humanoid.Name = "Humanoid"
	humanoid.MaxHealth = cfg.MaxHealth
	humanoid.Health = cfg.MaxHealth
	humanoid.WalkSpeed = cfg.WalkSpeed
	humanoid.JumpPower = 0
	humanoid.HipHeight = 2.0
	humanoid.AutoRotate = true
	humanoid.BreakJointsOnDeath = false
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, false)
	humanoid.Parent = model

	model.PrimaryPart = hrp
	local billboard, hpFill, hpLabel = attachHpBillboard(head, cfg, Vector3.new(0, 1.9, 0))

	return model, humanoid, hrp, head, muzzle, billboard, hpFill, hpLabel
end

local function buildAnimalModel(
	npcId: string,
	cfg: NPCConfig,
	spawnPos: Vector3
): (Model, Humanoid, BasePart, BasePart, BillboardGui, Frame, TextLabel)
	local model = Instance.new("Model")
	model.Name = npcId

	local s = cfg.Scale
	local rootCF = CFrame.new(spawnPos + Vector3.new(0, 2.1 * s, 0))
	local hrp = createPrimitivePart(
		model,
		"HumanoidRootPart",
		"Part",
		Vector3.new(2.0 * s, 1.6 * s, 3.0 * s),
		rootCF,
		cfg.PrimaryColor,
		Enum.Material.SmoothPlastic,
		false,
		false
	)
	hrp.Transparency = 1
	hrp.RootPriority = 1

	local body = createPrimitivePart(
		model,
		"Body",
		"Part",
		Vector3.new(1.65 * s, 1.4 * s, 3.1 * s),
		rootCF * CFrame.new(0, 0.2 * s, 0),
		cfg.PrimaryColor,
		Enum.Material.SmoothPlastic,
		true,
		true
	)
	weldParts(hrp, body)

	local legOffsets = {
		{ Name = "LegFL", Offset = Vector3.new(-0.55 * s, -1.3 * s, -1.05 * s) },
		{ Name = "LegFR", Offset = Vector3.new(0.55 * s, -1.3 * s, -1.05 * s) },
		{ Name = "LegBL", Offset = Vector3.new(-0.55 * s, -1.3 * s, 1.05 * s) },
		{ Name = "LegBR", Offset = Vector3.new(0.55 * s, -1.3 * s, 1.05 * s) },
	}
	for _, legDef in legOffsets do
		local leg = createPrimitivePart(
			model,
			legDef.Name,
			"Part",
			Vector3.new(0.46 * s, 1.6 * s, 0.46 * s),
			rootCF * CFrame.new(legDef.Offset),
			cfg.SecondaryColor,
			Enum.Material.SmoothPlastic,
			false,
			true
		)
		weldParts(hrp, leg)
	end

	local headOffsetY = if cfg.Id == "deer" then 1.15 * s else 0.45 * s
	local headOffsetZ = if cfg.Id == "deer" then -1.85 * s else -1.95 * s

	local neck = createPrimitivePart(
		model,
		"Neck",
		"WedgePart",
		Vector3.new(0.95 * s, 0.9 * s, 1.05 * s),
		rootCF * CFrame.new(0, (0.55 + (if cfg.Id == "deer" then 0.35 else 0)) * s, -1.45 * s),
		cfg.PrimaryColor,
		Enum.Material.SmoothPlastic,
		false,
		true
	)
	weldParts(hrp, neck)

	local head = createPrimitivePart(
		model,
		"Head",
		"Part",
		Vector3.new(1.05 * s, 0.95 * s, 1.15 * s),
		rootCF * CFrame.new(0, headOffsetY, headOffsetZ),
		cfg.PrimaryColor,
		Enum.Material.SmoothPlastic,
		true,
		true
	)
	weldParts(hrp, head)

	local snout = createPrimitivePart(
		model,
		"Snout",
		"Part",
		Vector3.new(0.62 * s, 0.52 * s, 0.65 * s),
		rootCF * CFrame.new(0, headOffsetY - 0.16 * s, headOffsetZ - 0.72 * s),
		cfg.SecondaryColor,
		Enum.Material.SmoothPlastic,
		false,
		true
	)
	weldParts(hrp, snout)

	local tail = createPrimitivePart(
		model,
		"Tail",
		"WedgePart",
		Vector3.new(0.32 * s, 0.38 * s, 0.75 * s),
		rootCF * CFrame.new(0, 0.45 * s, 1.82 * s) * CFrame.Angles(math.rad(-25), math.rad(180), 0),
		cfg.SecondaryColor,
		Enum.Material.SmoothPlastic,
		false,
		true
	)
	weldParts(hrp, tail)

	if cfg.Id == "deer" then
		for _, side in { -1, 1 } do
			local stem = createPrimitivePart(
				model,
				if side < 0 then "AntlerL" else "AntlerR",
				"Part",
				Vector3.new(0.14 * s, 0.9 * s, 0.14 * s),
				rootCF
					* CFrame.new(0.32 * side * s, headOffsetY + 0.85 * s, headOffsetZ)
					* CFrame.Angles(0, 0, math.rad(-18 * side)),
				cfg.AccentColor,
				Enum.Material.Wood,
				false,
				true
			)
			weldParts(hrp, stem)

			local prong = createPrimitivePart(
				model,
				if side < 0 then "AntlerProngL" else "AntlerProngR",
				"Part",
				Vector3.new(0.12 * s, 0.5 * s, 0.12 * s),
				rootCF
					* CFrame.new(0.48 * side * s, headOffsetY + 1.05 * s, headOffsetZ - 0.22 * s)
					* CFrame.Angles(math.rad(-35), 0, math.rad(-10 * side)),
				cfg.AccentColor,
				Enum.Material.Wood,
				false,
				true
			)
			weldParts(hrp, prong)
		end
	elseif cfg.Id == "boar" then
		for _, side in { -1, 1 } do
			local tusk = createPrimitivePart(
				model,
				if side < 0 then "TuskL" else "TuskR",
				"WedgePart",
				Vector3.new(0.14 * s, 0.38 * s, 0.28 * s),
				rootCF * CFrame.new(0.28 * side * s, headOffsetY - 0.12 * s, headOffsetZ - 1.0 * s),
				cfg.AccentColor,
				Enum.Material.SmoothPlastic,
				false,
				true
			)
			weldParts(hrp, tusk)
		end
	elseif cfg.Id == "wolf" then
		for _, side in { -1, 1 } do
			local ear = createPrimitivePart(
				model,
				if side < 0 then "EarL" else "EarR",
				"WedgePart",
				Vector3.new(0.22 * s, 0.42 * s, 0.26 * s),
				rootCF * CFrame.new(0.32 * side * s, headOffsetY + 0.62 * s, headOffsetZ + 0.18 * s),
				cfg.PrimaryColor,
				Enum.Material.SmoothPlastic,
				false,
				true
			)
			weldParts(hrp, ear)

			local eye = createPrimitivePart(
				model,
				if side < 0 then "EyeL" else "EyeR",
				"Part",
				Vector3.new(0.14 * s, 0.14 * s, 0.14 * s),
				rootCF * CFrame.new(0.26 * side * s, headOffsetY + 0.14 * s, headOffsetZ - 0.54 * s),
				cfg.AccentColor,
				Enum.Material.Neon,
				false,
				true
			)
			weldParts(hrp, eye)
		end
	elseif cfg.Id == "bear" then
		local hump = createPrimitivePart(
			model,
			"ShoulderHump",
			"Part",
			Vector3.new(1.55 * s, 0.55 * s, 1.45 * s),
			rootCF * CFrame.new(0, 0.98 * s, -0.65 * s),
			cfg.SecondaryColor,
			Enum.Material.SmoothPlastic,
			false,
			true
		)
		weldParts(hrp, hump)

		for _, side in { -1, 1 } do
			local ear = createPrimitivePart(
				model,
				if side < 0 then "EarL" else "EarR",
				"Part",
				Vector3.new(0.28 * s, 0.28 * s, 0.22 * s),
				rootCF * CFrame.new(0.42 * side * s, headOffsetY + 0.55 * s, headOffsetZ + 0.15 * s),
				cfg.SecondaryColor,
				Enum.Material.SmoothPlastic,
				false,
				true
			)
			weldParts(hrp, ear)
		end
	end

	local humanoid = Instance.new("Humanoid")
	humanoid.Name = "Humanoid"
	humanoid.MaxHealth = cfg.MaxHealth
	humanoid.Health = cfg.MaxHealth
	humanoid.WalkSpeed = cfg.WalkSpeed
	humanoid.JumpPower = 0
	humanoid.HipHeight = 1.3 * s
	humanoid.AutoRotate = true
	humanoid.BreakJointsOnDeath = false
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, false)
	humanoid.Parent = model

	model.PrimaryPart = hrp
	local billboard, hpFill, hpLabel = attachHpBillboard(head, cfg, Vector3.new(0, 1.65 * s, 0))

	return model, humanoid, hrp, head, billboard, hpFill, hpLabel
end

local function spawnNpcLootBag(cfg: NPCConfig, deathPosition: Vector3)
	local slots = LootService.RollLootTable(cfg.LootTableId)
	if not hasAnyLootSlots(slots) then
		return
	end

	local lootFolder = getOrCreateFolder("LootContainers")
	local exclude = buildEnvironmentExcludeList()
	local groundY = raycastGroundY(deathPosition.X, deathPosition.Y, deathPosition.Z, exclude)
	local dropPos = Vector3.new(deathPosition.X, (groundY or deathPosition.Y) + 0.6, deathPosition.Z)

	nextBagSeq += 1
	local model = Instance.new("Model")
	model.Name = string.format("NPCLootBag_%d", nextBagSeq)

	local bodyColor = if cfg.Kind == "Guard" then Color3.fromRGB(70, 82, 66) else Color3.fromRGB(115, 78, 52)
	local tieColor = if cfg.Kind == "Guard" then Color3.fromRGB(190, 165, 85) else Color3.fromRGB(165, 130, 90)

	local body = Instance.new("Part")
	body.Name = "BagBody"
	body.Size = Vector3.new(2.0, 1.2, 1.5)
	body.CFrame = CFrame.new(dropPos)
	body.Anchored = true
	body.CanCollide = false
	body.Color = bodyColor
	body.Material = Enum.Material.Fabric
	body.Parent = model

	local top = Instance.new("Part")
	top.Name = "BagTop"
	top.Size = Vector3.new(1.5, 0.35, 1.2)
	top.CFrame = CFrame.new(dropPos + Vector3.new(0, 0.65, 0))
	top.Anchored = true
	top.CanCollide = false
	top.Color = tieColor
	top.Material = Enum.Material.Fabric
	top.Parent = model

	model.PrimaryPart = body

	local title = string.format("%s Loot", cfg.DisplayName)
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "LootPrompt"
	prompt.ActionText = if cfg.Kind == "Animal" then "Harvest" else "Loot Body"
	prompt.ObjectText = title
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 12
	prompt.RequiresLineOfSight = false
	prompt.Parent = body

	model.Parent = lootFolder
	LootService.RegisterSlotsContainer(model, title, cfg.DisplayName, slots, Types.LOOT_CONTAINER_LIFETIME)
end

local function broadcastNpcTracer(origin: Vector3, endPos: Vector3)
	local effectEvent = Net.GetEvent(Net.Events.AttackEffect)
	for _, player in Players:GetPlayers() do
		local _, hrp = getAlivePlayerParts(player)
		if hrp then
			local pos = hrp.Position
			if
				(pos - origin).Magnitude <= TRACER_BROADCAST_RADIUS
				or (pos - endPos).Magnitude <= TRACER_BROADCAST_RADIUS
			then
				effectEvent:FireClient(player, nil, "pipe_pistol", origin, endPos, false, false)
			end
		end
	end
end

local function computeSpreadDirection(baseDir: Vector3, spreadDeg: number): Vector3
	if spreadDeg <= 0 then
		return baseDir.Unit
	end
	local spreadRad = math.rad(spreadDeg)
	local yaw = rng:NextNumber(-spreadRad, spreadRad)
	local pitch = rng:NextNumber(-spreadRad, spreadRad)
	local baseCF = CFrame.lookAt(Vector3.zero, baseDir)
	return (baseCF * CFrame.Angles(pitch, yaw, 0)).LookVector.Unit
end

local function findPlayerFromHit(inst: Instance): (Player?, Humanoid?)
	local current: Instance? = inst
	while current ~= nil and current ~= Workspace do
		if current:IsA("Model") then
			local plr = Players:GetPlayerFromCharacter(current)
			if plr ~= nil then
				local _, _, hum = getAlivePlayerParts(plr)
				return plr, hum
			end
		end
		current = current.Parent
	end
	return nil, nil
end

local function fireGuardBurst(record: ActiveNpcRecord, targetChar: Model, targetHrp: BasePart)
	local cfg = record.Config
	local burstCount = cfg.BurstCount or 3
	local burstInterval = cfg.BurstInterval or 0.16
	local spreadDeg = cfg.SpreadDeg or 4.0
	local speed = cfg.ProjectileSpeed or 210
	local gravity = cfg.ProjectileGravity or 12

	if record.ActiveBurstThread ~= nil then
		if coroutine.status(record.ActiveBurstThread) == "suspended" then
			task.cancel(record.ActiveBurstThread)
		end
		record.ActiveBurstThread = nil
	end

	record.BurstActive = true
	local burstThread: thread
	burstThread = task.spawn(function()
		for i = 1, burstCount do
			if not record.Alive or record.State ~= "Combat" then
				break
			end
			if targetChar.Parent == nil or targetHrp.Parent == nil then
				break
			end
			local targetPlr = Players:GetPlayerFromCharacter(targetChar)
			if targetPlr == nil or getAlivePlayerParts(targetPlr) == nil then
				break
			end

			local muzzlePos = if record.Muzzle and record.Muzzle.Parent
				then record.Muzzle.Position
				else record.Head.Position
			local aimPoint = targetHrp.Position + Vector3.new(0, 0.5, 0)
			local rawDir = aimPoint - muzzlePos
			if rawDir.Magnitude > 0.1 then
				local shotDir = computeSpreadDirection(rawDir.Unit, spreadDeg)
				nextBulletSeq += 1
				local bulletId = string.format("npc_%s_%d", record.Id, nextBulletSeq)
				local exclude = buildEnvironmentExcludeList()

				Ballistics.Spawn({
					Id = bulletId,
					Origin = muzzlePos,
					InitialVelocity = shotDir * speed,
					Gravity = gravity,
					MaxLifetime = 1.2,
					ExcludeInstances = exclude,
					OnHit = function(hitResult: RaycastResult)
						broadcastNpcTracer(muzzlePos, hitResult.Position)
						local hitPlayer, hitHum = findPlayerFromHit(hitResult.Instance)
						if hitPlayer ~= nil and hitHum ~= nil and hitHum.Health > 0 then
							local hitChar = hitPlayer.Character
							if
								hitPlayer:GetAttribute("InRaid") ~= true
								and hitChar ~= nil
								and hitChar:GetAttribute("RaidInvulnerable") ~= true
								and hitChar:FindFirstChildOfClass("ForceField") == nil
							then
								hitHum:TakeDamage(cfg.Damage)
							end
						end
					end,
					OnExpire = function(endPos: Vector3)
						broadcastNpcTracer(muzzlePos, endPos)
					end,
				})
			end

			if i < burstCount then
				task.wait(burstInterval)
			end
		end
		if record.ActiveBurstThread == burstThread then
			record.ActiveBurstThread = nil
		end
		record.BurstActive = false
	end)
	record.ActiveBurstThread = burstThread
end

local function findSafeGroundWaypoint(
	center: Vector3,
	minDist: number,
	maxDist: number,
	exclude: { Instance }
): Vector3?
	for _ = 1, 6 do
		local angle = rng:NextNumber(0, math.pi * 2)
		local dist = rng:NextNumber(minDist, maxDist)
		local cx = center.X + math.cos(angle) * dist
		local cz = center.Z + math.sin(angle) * dist
		local gy = raycastGroundY(cx, center.Y, cz, exclude)
		if gy ~= nil then
			return Vector3.new(cx, gy, cz)
		end
	end
	return nil
end

local function updateHpBar(record: ActiveNpcRecord, currentHp: number)
	if not record.HpBillboard or not record.HpFill or not record.HpLabel then
		return
	end
	local maxHp = record.Config.MaxHealth
	if currentHp <= 0 then
		record.HpBillboard.Enabled = false
		return
	end
	if currentHp < maxHp then
		record.HpBillboard.Enabled = true
	end
	local ratio = math.clamp(currentHp / math.max(1, maxHp), 0, 1)
	record.HpFill.Size = UDim2.fromScale(ratio, 1)
	if ratio > 0.5 then
		record.HpFill.BackgroundColor3 = Color3.fromRGB(80, 205, 95)
	elseif ratio > 0.25 then
		record.HpFill.BackgroundColor3 = Color3.fromRGB(235, 185, 55)
	else
		record.HpFill.BackgroundColor3 = Color3.fromRGB(220, 65, 65)
	end
	record.HpLabel.Text = string.format("%d / %d", math.ceil(currentHp), math.ceil(maxHp))
end

local function cleanupActiveNpc(record: ActiveNpcRecord)
	if activeNpcs[record.Id] == record then
		activeNpcs[record.Id] = nil
		activeNpcCount = math.max(0, activeNpcCount - 1)
	end
	if record.Marker.ActiveNpc == record then
		record.Marker.ActiveNpc = nil
	end
	record.Alive = false
	record.BurstActive = false
	if record.ActiveBurstThread ~= nil then
		if coroutine.status(record.ActiveBurstThread) == "suspended" then
			task.cancel(record.ActiveBurstThread)
		end
		record.ActiveBurstThread = nil
	end
	record.Janitor:Destroy()
end

local function scheduleMarkerRespawn(marker: SpawnMarkerRecord)
	if marker.Destroyed or not serverHasPlayers then
		return
	end
	if marker.RespawnThread ~= nil then
		return
	end
	local delaySec = math.max(5, marker.RespawnTime)
	marker.RespawnThread = task.delay(delaySec, function()
		marker.RespawnThread = nil
		if not marker.Destroyed and serverHasPlayers and marker.ActiveNpc == nil then
			NPCService.SpawnFromMarker(marker.Part)
		end
	end)
end

local function spawnNpcInternal(marker: SpawnMarkerRecord): Model?
	if marker.Destroyed or marker.ActiveNpc ~= nil then
		return nil
	end

	local cfg = marker.Config
	local activeFolder = getOrCreateFolder("ActiveNPCs")
	local exclude = buildEnvironmentExcludeList()
	local rawPos = marker.Part.Position
	local groundY = raycastGroundY(rawPos.X, rawPos.Y, rawPos.Z, exclude)
	local spawnPos = Vector3.new(rawPos.X, groundY or rawPos.Y, rawPos.Z)
	marker.SpawnPosition = spawnPos

	nextNpcSeq += 1
	local npcId = string.format("%s_%d", cfg.Id, nextNpcSeq)

	local model: Model
	local humanoid: Humanoid
	local hrp: BasePart
	local head: BasePart
	local muzzle: BasePart? = nil
	local billboard: BillboardGui
	local hpFill: Frame
	local hpLabel: TextLabel

	if cfg.Kind == "Guard" then
		model, humanoid, hrp, head, muzzle, billboard, hpFill, hpLabel = buildGuardModel(npcId, cfg, spawnPos)
	else
		model, humanoid, hrp, head, billboard, hpFill, hpLabel = buildAnimalModel(npcId, cfg, spawnPos)
	end

	local janitor = Janitor.new()
	janitor:Add(model)

	local record: ActiveNpcRecord = {
		Id = npcId,
		Marker = marker,
		Config = cfg,
		Model = model,
		Humanoid = humanoid,
		RootPart = hrp,
		Head = head,
		Muzzle = muzzle,
		Janitor = janitor,
		State = "Patrol",
		TargetPlayer = nil,
		ThreatPosition = nil,
		LastSeenTime = 0,
		AlertUntil = 0,
		StateUntil = 0,
		NextMoveTime = 0,
		NextAttackTime = 0,
		ReturnStartedAt = 0,
		StrafeSign = if rng:NextNumber() < 0.5 then -1 else 1,
		BurstActive = false,
		ActiveBurstThread = nil,
		Alive = true,
		PrevHealth = cfg.MaxHealth,
		HpFill = hpFill,
		HpLabel = hpLabel,
		HpBillboard = billboard,
	}

	janitor:Add(humanoid.HealthChanged:Connect(function(newHp: number)
		if not record.Alive then
			return
		end
		updateHpBar(record, newHp)
		local tookDamage = newHp < record.PrevHealth
		record.PrevHealth = newHp

		if tookDamage and newHp > 0 then
			local attackerUid = model:GetAttribute("LastAttackerUserId")
			if typeof(attackerUid) == "number" then
				local attacker = Players:GetPlayerByUserId(attackerUid)
				if attacker ~= nil then
					local _, attackerHrp = getAlivePlayerParts(attacker)
					if attackerHrp ~= nil then
						local dist = (attackerHrp.Position - hrp.Position).Magnitude
						if dist <= cfg.ChaseRadius * 1.4 then
							if cfg.Behavior == "RangedHostile" then
								record.TargetPlayer = attacker
								record.LastSeenTime = os.clock()
								if record.State == "Patrol" or record.State == "Return" or record.State == "Alert" then
									record.State = "Combat"
								end
							elseif cfg.Behavior == "MeleeHostile" then
								record.TargetPlayer = attacker
								record.LastSeenTime = os.clock()
								record.State = "Chase"
							else
								record.ThreatPosition = attackerHrp.Position
								record.State = "Flee"
								record.StateUntil = os.clock() + FLEE_DURATION
							end
						end
					end
				end
			end
		end
	end))

	janitor:Add(humanoid.Died:Connect(function()
		if not record.Alive then
			return
		end
		record.Alive = false
		local deathPos = hrp.Position
		updateHpBar(record, 0)
		spawnNpcLootBag(cfg, deathPos)

		task.delay(0.35, function()
			cleanupActiveNpc(record)
			scheduleMarkerRespawn(marker)
		end)
	end))

	janitor:Add(model.AncestryChanged:Connect(function(_, parent)
		if parent == nil and record.Alive then
			cleanupActiveNpc(record)
		end
	end))

	model.Parent = activeFolder
	pcall(function()
		hrp:SetNetworkOwner(nil)
	end)

	marker.ActiveNpc = record
	activeNpcs[npcId] = record
	activeNpcCount += 1

	return model
end

local function stepPatrol(record: ActiveNpcRecord, now: number, exclude: { Instance })
	record.Humanoid.AutoRotate = true
	record.Humanoid.WalkSpeed = record.Config.WalkSpeed

	if record.Humanoid.Health < record.Config.MaxHealth then
		record.Humanoid.Health =
			math.min(record.Config.MaxHealth, record.Humanoid.Health + OUT_OF_COMBAT_REGEN_PER_TICK)
	end

	if now >= record.NextMoveTime then
		record.NextMoveTime = now + rng:NextNumber(2.8, 5.2)
		local wp = findSafeGroundWaypoint(record.Marker.SpawnPosition, 3, record.Marker.PatrolRadius, exclude)
		if wp ~= nil then
			record.Humanoid:MoveTo(wp)
		end
	end
end

local function stepReturn(record: ActiveNpcRecord, now: number)
	record.Humanoid.AutoRotate = true
	record.Humanoid.WalkSpeed = record.Config.RunSpeed

	local spawnPos = record.Marker.SpawnPosition
	local distHome = (Vector3.new(record.RootPart.Position.X, spawnPos.Y, record.RootPart.Position.Z) - spawnPos).Magnitude
	if distHome <= 6 or (now - record.ReturnStartedAt) >= 10 then
		record.State = "Patrol"
		record.TargetPlayer = nil
		record.NextMoveTime = now + 1.0
		return
	end

	record.Humanoid:MoveTo(spawnPos)
end

local function faceTargetYaw(hrp: BasePart, targetPos: Vector3)
	local pos = hrp.Position
	local flatTarget = Vector3.new(targetPos.X, pos.Y, targetPos.Z)
	if (flatTarget - pos).Magnitude > 0.1 then
		hrp.CFrame = CFrame.lookAt(pos, flatTarget)
	end
end

local function stepRangedGuard(record: ActiveNpcRecord, now: number, exclude: { Instance })
	local cfg = record.Config
	local myPos = record.RootPart.Position
	local eyeOrigin = record.Head.Position

	if record.State == "Patrol" then
		stepPatrol(record, now, exclude)
		local foundPlayer = findNearestPlayer(eyeOrigin, cfg.DetectionRadius, true, exclude)
		if foundPlayer ~= nil then
			record.TargetPlayer = foundPlayer
			record.State = "Alert"
			record.AlertUntil = now + GUARD_ALERT_DELAY
			record.LastSeenTime = now
			record.Humanoid:MoveTo(myPos)
		end
		return
	end

	if record.State == "Return" then
		local foundPlayer = findNearestPlayer(eyeOrigin, cfg.DetectionRadius * 0.8, true, exclude)
		if foundPlayer ~= nil then
			record.TargetPlayer = foundPlayer
			record.State = "Combat"
			record.LastSeenTime = now
			return
		end
		stepReturn(record, now)
		return
	end

	local targetPlayer = record.TargetPlayer
	if targetPlayer == nil then
		record.State = "Return"
		record.ReturnStartedAt = now
		return
	end
	local targetChar, targetHrp = getAlivePlayerParts(targetPlayer)
	if targetChar == nil or targetHrp == nil then
		record.State = "Return"
		record.ReturnStartedAt = now
		record.TargetPlayer = nil
		return
	end

	local targetPos = targetHrp.Position
	local dist = (targetPos - myPos).Magnitude
	local distHome = (myPos - record.Marker.SpawnPosition).Magnitude
	if dist > cfg.ChaseRadius or distHome > (cfg.ChaseRadius + record.Marker.PatrolRadius) then
		record.State = "Return"
		record.ReturnStartedAt = now
		record.TargetPlayer = nil
		return
	end

	local hasLos = hasLineOfSight(eyeOrigin, targetHrp, targetChar, exclude)
	if hasLos then
		record.LastSeenTime = now
	elseif (now - record.LastSeenTime) > LOOT_LOST_LOS_TIMEOUT then
		record.State = "Return"
		record.ReturnStartedAt = now
		record.TargetPlayer = nil
		return
	end

	record.Humanoid.AutoRotate = false
	faceTargetYaw(record.RootPart, targetPos)

	if record.State == "Alert" then
		if now >= record.AlertUntil then
			if hasLos then
				record.State = "Combat"
			else
				record.State = "Patrol"
				record.TargetPlayer = nil
			end
		end
		return
	end

	-- Combat state
	record.Humanoid.WalkSpeed = cfg.RunSpeed
	if now >= record.NextMoveTime then
		record.NextMoveTime = now + rng:NextNumber(1.1, 1.9)
		if rng:NextNumber() < 0.35 then
			record.StrafeSign = -record.StrafeSign
		end
		local flatDelta = Vector3.new(targetPos.X - myPos.X, 0, targetPos.Z - myPos.Z)
		local dirFlat = if flatDelta.Magnitude > 0.1 then flatDelta.Unit else Vector3.new(0, 0, -1)
		local rightVec = Vector3.new(-dirFlat.Z, 0, dirFlat.X)

		local desiredGoal: Vector3
		if dist < 14 then
			desiredGoal = myPos - dirFlat * 10 + rightVec * (record.StrafeSign * 5)
		elseif dist > 36 or not hasLos then
			desiredGoal = targetPos - dirFlat * 22 + rightVec * (record.StrafeSign * 6)
		else
			desiredGoal = myPos + rightVec * (record.StrafeSign * 10)
		end

		local gy = raycastGroundY(desiredGoal.X, myPos.Y, desiredGoal.Z, exclude)
		if gy ~= nil then
			record.Humanoid:MoveTo(Vector3.new(desiredGoal.X, gy, desiredGoal.Z))
		end
	end

	if hasLos and dist <= cfg.AttackRange and now >= record.NextAttackTime and not record.BurstActive then
		record.NextAttackTime = now + cfg.AttackCooldown
		fireGuardBurst(record, targetChar, targetHrp)
	end
end

local function stepMeleeAnimal(record: ActiveNpcRecord, now: number, exclude: { Instance })
	local cfg = record.Config
	local myPos = record.RootPart.Position
	record.Humanoid.AutoRotate = true

	if record.State == "Patrol" then
		stepPatrol(record, now, exclude)
		local foundPlayer = findNearestPlayer(record.Head.Position, cfg.DetectionRadius, true, exclude)
		if foundPlayer ~= nil then
			record.TargetPlayer = foundPlayer
			record.State = "Chase"
			record.LastSeenTime = now
		end
		return
	end

	if record.State == "Return" then
		stepReturn(record, now)
		return
	end

	local targetPlayer = record.TargetPlayer
	if targetPlayer == nil then
		record.State = "Return"
		record.ReturnStartedAt = now
		return
	end
	local targetChar, targetHrp, targetHum = getAlivePlayerParts(targetPlayer)
	if targetChar == nil or targetHrp == nil or targetHum == nil then
		record.State = "Return"
		record.ReturnStartedAt = now
		record.TargetPlayer = nil
		return
	end

	local targetPos = targetHrp.Position
	local dist = (targetPos - myPos).Magnitude
	local distHome = (myPos - record.Marker.SpawnPosition).Magnitude
	if dist > cfg.ChaseRadius or distHome > (cfg.ChaseRadius + record.Marker.PatrolRadius) then
		record.State = "Return"
		record.ReturnStartedAt = now
		record.TargetPlayer = nil
		return
	end

	record.Humanoid.WalkSpeed = cfg.RunSpeed
	record.Humanoid:MoveTo(targetPos)

	if dist <= cfg.AttackRange and now >= record.NextAttackTime then
		if hasLineOfSight(record.Head.Position, targetHrp, targetChar, exclude) then
			record.NextAttackTime = now + cfg.AttackCooldown
			targetHum:TakeDamage(cfg.Damage)
			if cfg.BleedDuration ~= nil and cfg.BleedDps ~= nil then
				SurvivalService.ApplyBleeding(targetPlayer, cfg.BleedDuration, cfg.BleedDps)
			end
		end
	end
end

local function stepPassiveAnimal(record: ActiveNpcRecord, now: number, exclude: { Instance })
	local cfg = record.Config
	local myPos = record.RootPart.Position
	record.Humanoid.AutoRotate = true

	if record.State == "Flee" then
		record.Humanoid.WalkSpeed = cfg.RunSpeed
		local nearestPlayer, _, nearestHrp, nearestDist = findNearestPlayer(myPos, cfg.ChaseRadius, false, exclude)
		if nearestPlayer ~= nil and nearestHrp ~= nil and nearestDist <= cfg.DetectionRadius then
			record.ThreatPosition = nearestHrp.Position
			record.StateUntil = math.max(record.StateUntil, now + 3.0)
		end

		if now >= record.StateUntil and (nearestPlayer == nil or nearestDist > cfg.DetectionRadius * 1.4) then
			record.State = "Return"
			record.ReturnStartedAt = now
			return
		end

		if now >= record.NextMoveTime then
			record.NextMoveTime = now + 0.9
			local threatPos = record.ThreatPosition or (myPos + Vector3.new(1, 0, 0))
			local away = Vector3.new(myPos.X - threatPos.X, 0, myPos.Z - threatPos.Z)
			local awayDir = if away.Magnitude > 0.1
				then away.Unit
				else Vector3.new(rng:NextNumber(-1, 1), 0, rng:NextNumber(-1, 1)).Unit

			local chosenGoal: Vector3? = nil
			for _, angleDeg in { 0, 35, -35, 75, -75 } do
				local rotated = (CFrame.Angles(0, math.rad(angleDeg), 0) * awayDir).Unit
				local candidate = myPos + rotated * 22
				local spawnPos = record.Marker.SpawnPosition
				local homeDelta = Vector3.new(candidate.X - spawnPos.X, 0, candidate.Z - spawnPos.Z)
				local maxDrift = record.Marker.PatrolRadius * 1.6
				if homeDelta.Magnitude > maxDrift then
					candidate = spawnPos + homeDelta.Unit * maxDrift
				end
				local gy = raycastGroundY(candidate.X, myPos.Y, candidate.Z, exclude)
				if gy ~= nil then
					chosenGoal = Vector3.new(candidate.X, gy, candidate.Z)
					break
				end
			end

			if chosenGoal ~= nil then
				record.Humanoid:MoveTo(chosenGoal)
			end
		end
		return
	end

	if record.State == "Return" then
		local nearThreat, _, nearHrp = findNearestPlayer(myPos, cfg.DetectionRadius, false, exclude)
		if nearThreat ~= nil and nearHrp ~= nil then
			record.ThreatPosition = nearHrp.Position
			record.State = "Flee"
			record.StateUntil = now + FLEE_DURATION
			return
		end
		stepReturn(record, now)
		return
	end

	-- Patrol
	stepPatrol(record, now, exclude)
	local foundPlayer, foundChar, foundHrp, foundDist = findNearestPlayer(myPos, cfg.DetectionRadius, false, exclude)
	if foundPlayer ~= nil and foundChar ~= nil and foundHrp ~= nil then
		if
			foundDist <= cfg.DetectionRadius * 0.65
			or hasLineOfSight(record.Head.Position, foundHrp, foundChar, exclude)
		then
			record.ThreatPosition = foundHrp.Position
			record.State = "Flee"
			record.StateUntil = now + FLEE_DURATION
			record.NextMoveTime = 0
		end
	end
end

local function stepAiTick()
	if not isMainMapPlace() then
		return
	end
	local now = os.clock()
	local exclude = buildEnvironmentExcludeList()

	local snapshot: { ActiveNpcRecord } = {}
	for _, record in activeNpcs do
		if record.Alive then
			table.insert(snapshot, record)
		end
	end

	for _, record in snapshot do
		if not record.Alive or record.Model.Parent == nil or record.Humanoid.Health <= 0 then
			continue
		end
		if record.Config.Behavior == "RangedHostile" then
			stepRangedGuard(record, now, exclude)
		elseif record.Config.Behavior == "MeleeHostile" then
			stepMeleeAnimal(record, now, exclude)
		else
			stepPassiveAnimal(record, now, exclude)
		end
	end
end

local function ensureAiLoopRunning()
	if aiLoopThread ~= nil or not serverHasPlayers then
		return
	end
	aiLoopThread = task.spawn(function()
		while serverHasPlayers do
			stepAiTick()
			task.wait(AI_TICK_INTERVAL)
		end
		aiLoopThread = nil
	end)
end

local function registerMarkerPart(inst: Instance)
	if not inst:IsA("BasePart") or markerRecordsByPart[inst] ~= nil then
		return
	end

	local npcTypeAttr = inst:GetAttribute("NPCType")
	if typeof(npcTypeAttr) ~= "string" then
		return
	end

	local cfg = NPCs[npcTypeAttr]
	if cfg == nil then
		warn(string.format('[NPCService] Unknown NPCType "%s" on marker "%s"', npcTypeAttr, inst.Name))
		return
	end

	inst.Transparency = 1
	inst.CanCollide = false
	inst.CanQuery = false
	inst.CanTouch = false

	local respawnAttr = inst:GetAttribute("RespawnTime")
	local respawnTime = if typeof(respawnAttr) == "number" and respawnAttr >= 5
		then respawnAttr
		else cfg.DefaultRespawnTime

	local patrolAttr = inst:GetAttribute("PatrolRadius")
	local patrolRadius = if typeof(patrolAttr) == "number" and patrolAttr >= 4
		then patrolAttr
		else cfg.DefaultPatrolRadius

	local markerRecord: SpawnMarkerRecord = {
		Part = inst,
		NPCType = npcTypeAttr,
		Config = cfg,
		RespawnTime = respawnTime,
		PatrolRadius = patrolRadius,
		SpawnPosition = inst.Position,
		ActiveNpc = nil,
		RespawnThread = nil,
		Destroyed = false,
	}

	markerRecordsByPart[inst] = markerRecord

	inst.Destroying:Connect(function()
		markerRecord.Destroyed = true
		if markerRecord.RespawnThread ~= nil then
			if coroutine.status(markerRecord.RespawnThread) == "suspended" then
				task.cancel(markerRecord.RespawnThread)
			end
			markerRecord.RespawnThread = nil
		end
		if markerRecord.ActiveNpc ~= nil then
			cleanupActiveNpc(markerRecord.ActiveNpc)
		end
		markerRecordsByPart[inst] = nil
	end)

	if serverHasPlayers then
		spawnNpcInternal(markerRecord)
	end
end

local function bindSpawnsFolder(folder: Instance)
	for _, desc in folder:GetDescendants() do
		registerMarkerPart(desc)
	end

	folder.DescendantAdded:Connect(function(desc: Instance)
		registerMarkerPart(desc)
	end)
end

local function spawnMissingMarkers()
	for _, marker in markerRecordsByPart do
		if not marker.Destroyed and marker.ActiveNpc == nil then
			if marker.RespawnThread ~= nil then
				if coroutine.status(marker.RespawnThread) == "suspended" then
					task.cancel(marker.RespawnThread)
				end
				marker.RespawnThread = nil
			end
			spawnNpcInternal(marker)
		end
	end
end

function NPCService.GetActiveCount(): number
	return activeNpcCount
end

function NPCService.SpawnFromMarker(marker: BasePart): Model?
	if not isMainMapPlace() then
		return nil
	end
	if markerRecordsByPart[marker] == nil then
		registerMarkerPart(marker)
	end
	local record = markerRecordsByPart[marker]
	if record == nil then
		return nil
	end
	return spawnNpcInternal(record)
end

function NPCService.DespawnAll()
	for _, marker in markerRecordsByPart do
		if marker.RespawnThread ~= nil then
			if coroutine.status(marker.RespawnThread) == "suspended" then
				task.cancel(marker.RespawnThread)
			end
			marker.RespawnThread = nil
		end
	end

	local snapshot: { ActiveNpcRecord } = {}
	for _, record in activeNpcs do
		table.insert(snapshot, record)
	end
	for _, record in snapshot do
		cleanupActiveNpc(record)
	end
end

function NPCService.Init()
	if isInitialized then
		return
	end
	isInitialized = true

	if not isMainMapPlace() then
		return
	end

	Net.InitServer()
	getOrCreateFolder("ActiveNPCs")

	serverHasPlayers = #Players:GetPlayers() > 0

	local spawnsFolder = Workspace:FindFirstChild("NPCSpawns")
	if spawnsFolder then
		bindSpawnsFolder(spawnsFolder)
	else
		Workspace.ChildAdded:Connect(function(child: Instance)
			if child.Name == "NPCSpawns" then
				bindSpawnsFolder(child)
			end
		end)
	end

	if serverHasPlayers then
		spawnMissingMarkers()
		ensureAiLoopRunning()
	end

	Players.PlayerAdded:Connect(function(_player: Player)
		if not serverHasPlayers then
			serverHasPlayers = true
			spawnMissingMarkers()
			ensureAiLoopRunning()
		end
	end)

	Workspace:GetAttributeChangedSignal("RaidServerMode"):Connect(function()
		if Workspace:GetAttribute("RaidServerMode") == true then
			NPCService.DespawnAll()
		end
	end)

	Players.PlayerRemoving:Connect(function(_player: Player)
		task.defer(function()
			if #Players:GetPlayers() == 0 then
				serverHasPlayers = false
				NPCService.DespawnAll()
			end
		end)
	end)
end

return NPCService
