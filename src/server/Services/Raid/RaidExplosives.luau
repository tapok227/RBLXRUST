--!strict
local CollectionService = game:GetService("CollectionService")
local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)
local Types = require(ReplicatedStorage.Shared.Types)
local BuildingConfig = require(ReplicatedStorage.Shared.configs.BuildingConfig)
local BuildingGeometry = require(ReplicatedStorage.Shared.BuildingGeometry)
local Explosives = require(ReplicatedStorage.Shared.configs.Explosives)
local Net = require(ReplicatedStorage.Shared.Net)
local BaseService = require(ServerScriptService.Server.Services.BaseService)
local BuildingValidator = require(ServerScriptService.Server.Services.BuildingValidator)
local DefenseService = require(ServerScriptService.Server.Services.DefenseService)
local SecurityService = require(ServerScriptService.Server.Services.SecurityService)

type SavedBuildPiece = Types.SavedBuildPiece
type ExplosionParams = Types.ExplosionParams
type ExplosionResult = Types.ExplosionResult

export type ActiveExplosiveRecord = {
	Part: Part,
	Label: TextLabel?,
	CancelFlag: boolean,
	DetonateAt: number,
}

export type ExplosionDeps = {
	ActiveSessions: { [Player]: any },
	ClosestPointOnModel: (model: Model, point: Vector3) -> Vector3,
	DestroyRaidPiece: (session: any, uid: string, dropStorageLoot: boolean) -> (),
	UpdatePieceDamageBillboard: (record: any) -> (),
	IsCharacterInvulnerable: (charModel: Model) -> boolean,
	NotifyRaiderDamaged: (player: Player) -> (),
}

local EXPLOSION_EFFECT_BROADCAST_RADIUS = 350
local MAX_OCCLUSION_RAY_PASSES = 8
local DEFAULT_MIN_FALLOFF_MULTIPLIER = 0.25
local SMOKE_FOLDER_NAME = "TacticalSmokeClouds"

local nextSmokeSeq = 0

local RaidExplosives = {}

local function getOrCreateSmokeFolder(): Folder
	local existing = Workspace:FindFirstChild(SMOKE_FOLDER_NAME)
	if existing and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = SMOKE_FOLDER_NAME
	folder.Parent = Workspace
	return folder
end

function RaidExplosives.CreateExplosiveVisual(position: Vector3, itemId: string, folder: Folder): (Part, TextLabel)
	local part = Instance.new("Part")
	part.Name = string.format("ArmedExplosive_%s", itemId)
	part.Size = if itemId == "c4_charge" then Vector3.new(1.1, 0.5, 0.8) else Vector3.new(1.0, 0.7, 1.0)
	part.Position = position
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.Material = Enum.Material.Metal
	part.Color = if itemId == "c4_charge" then Color3.fromRGB(205, 50, 50) else Color3.fromRGB(160, 110, 55)
	part.Parent = folder

	local gui = Instance.new("BillboardGui")
	gui.Name = "FuseTimerGui"
	gui.Size = UDim2.fromOffset(110, 32)
	gui.StudsOffset = Vector3.new(0, 1.8, 0)
	gui.AlwaysOnTop = true
	gui.MaxDistance = 60
	gui.Adornee = part
	gui.Parent = part

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundColor3 = Color3.fromRGB(28, 12, 12)
	label.BackgroundTransparency = 0.2
	label.BorderSizePixel = 0
	label.Font = Enum.Font.GothamBold
	label.TextSize = 14
	label.TextColor3 = Color3.fromRGB(255, 110, 90)
	label.Text = ""
	label.Parent = gui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 5)
	corner.Parent = label

	return part, label
end

local function findHumanoidCharacter(inst: Instance): (Model?, Humanoid?)
	local current: Instance? = inst
	while current ~= nil and current ~= Workspace do
		if current:IsA("Model") then
			local humanoid = current:FindFirstChildOfClass("Humanoid")
			if humanoid ~= nil then
				return current, humanoid
			end
		end
		current = current.Parent
	end
	return nil, nil
end

local function getTargetControlPoints(targetModel: Model, isCharacterTarget: boolean): { Vector3 }
	local points: { Vector3 } = {}
	if isCharacterTarget then
		local hrp = targetModel:FindFirstChild("HumanoidRootPart")
		local head = targetModel:FindFirstChild("Head")
		if hrp and hrp:IsA("BasePart") then
			table.insert(points, hrp.Position)
			if head and head:IsA("BasePart") then
				table.insert(points, head.Position)
			else
				table.insert(points, hrp.Position + Vector3.new(0, 2.2, 0))
			end
			table.insert(points, hrp.Position - Vector3.new(0, 2.0, 0))
			table.insert(points, hrp.Position + hrp.CFrame.RightVector * 1.2)
			table.insert(points, hrp.Position - hrp.CFrame.RightVector * 1.2)
			return points
		end
	else
		local pieceAttr = targetModel:GetAttribute("PieceType")
		local canonical = if typeof(pieceAttr) == "string" then BuildingGeometry.CanonicalPieceType(pieceAttr) else nil
		local baseCF = targetModel:GetPivot()

		if canonical == "wall" or canonical == "doorway" or canonical == "window_wall" or canonical == "smart_door" then
			local centerCF = baseCF * CFrame.new(0, BuildingConfig.WallBodyHeight * 0.5, 0)
			local hx = BuildingConfig.GridSize * 0.42
			local hy = BuildingConfig.WallBodyHeight * 0.38
			local offsets = {
				Vector3.new(0, 0, 0),
				Vector3.new(-hx, -hy, 0),
				Vector3.new(hx, -hy, 0),
				Vector3.new(-hx, hy, 0),
				Vector3.new(hx, hy, 0),
			}
			for _, off in offsets do
				table.insert(points, (centerCF * CFrame.new(off)).Position)
			end
			return points
		elseif canonical == "foundation" or canonical == "roof" then
			local t = if canonical == "foundation"
				then BuildingConfig.FoundationThickness
				else BuildingConfig.FloorThickness
			local midCF = baseCF * CFrame.new(0, t * 0.5, 0)
			local h = BuildingConfig.GridSize * 0.40
			for _, off in
				{
					Vector3.new(0, 0, 0),
					Vector3.new(-h, 0, -h),
					Vector3.new(h, 0, -h),
					Vector3.new(-h, 0, h),
					Vector3.new(h, 0, h),
				}
			do
				table.insert(points, (midCF * CFrame.new(off)).Position)
			end
			return points
		elseif canonical == "triangle_foundation" or canonical == "triangle_floor" then
			local t = if canonical == "triangle_foundation"
				then BuildingConfig.FoundationThickness
				else BuildingConfig.FloorThickness
			local midCF = baseCF * CFrame.new(0, t * 0.5, 0)
			for _, off in
				{
					Vector3.new(0, 0, 0),
					Vector3.new(-4.8, 0, -2.75),
					Vector3.new(4.8, 0, -2.75),
					Vector3.new(0, 0, 5.5),
					Vector3.new(0, 0, -2.75),
				}
			do
				table.insert(points, (midCF * CFrame.new(off)).Position)
			end
			return points
		end
	end

	local cf, size = targetModel:GetBoundingBox()
	if size.Y >= 3.0 then
		local rx = size.X * 0.35
		local ry = size.Y * 0.35
		table.insert(points, cf.Position)
		table.insert(points, cf.Position + cf.RightVector * rx + cf.UpVector * ry)
		table.insert(points, cf.Position - cf.RightVector * rx + cf.UpVector * ry)
		table.insert(points, cf.Position + cf.RightVector * rx - cf.UpVector * ry)
		table.insert(points, cf.Position - cf.RightVector * rx - cf.UpVector * ry)
	elseif math.max(size.X, size.Z) >= 6.0 then
		local rx = size.X * 0.35
		local rz = size.Z * 0.35
		table.insert(points, cf.Position)
		table.insert(points, cf.Position + cf.RightVector * rx + cf.LookVector * rz)
		table.insert(points, cf.Position - cf.RightVector * rx + cf.LookVector * rz)
		table.insert(points, cf.Position + cf.RightVector * rx - cf.LookVector * rz)
		table.insert(points, cf.Position - cf.RightVector * rx - cf.LookVector * rz)
	else
		local rx = size.X * 0.3
		local ry = size.Y * 0.3
		table.insert(points, cf.Position)
		table.insert(points, cf.Position + cf.RightVector * rx + cf.UpVector * ry)
		table.insert(points, cf.Position - cf.RightVector * rx + cf.UpVector * ry)
		table.insert(points, cf.Position + cf.RightVector * rx - cf.UpVector * ry)
		table.insert(points, cf.Position - cf.RightVector * rx - cf.UpVector * ry)
	end

	return points
end

local function computeBlastFalloff(distance: number, radius: number, minMultiplier: number): number
	if distance <= 1.0 then
		return 1.0
	end
	local t = math.clamp((distance - 1.0) / math.max(0.01, radius - 1.0), 0, 1)
	local clampedMin = math.clamp(minMultiplier, 0, 1)
	return 1.0 - t * (1.0 - clampedMin)
end

local function broadcastExplosionEffect(
	origin: Vector3,
	radius: number,
	sourceId: string,
	projectileId: string?,
	attacker: Player?
)
	local effectEvent = Net.GetEvent(Net.Events.ExplosionEffect)
	for _, other in Players:GetPlayers() do
		if other == attacker then
			effectEvent:FireClient(other, origin, radius, sourceId, projectileId)
			continue
		end
		local char = other.Character
		local hrp = if char then char:FindFirstChild("HumanoidRootPart") else nil
		if hrp and hrp:IsA("BasePart") and (hrp.Position - origin).Magnitude <= EXPLOSION_EFFECT_BROADCAST_RADIUS then
			effectEvent:FireClient(other, origin, radius, sourceId, projectileId)
		end
	end
end

function RaidExplosives.HasExplosionLineOfSight(
	blastOrigin: Vector3,
	targetModel: Model,
	excludeInstances: { Instance }?,
	isCharacterTarget: boolean?
): boolean
	local controlPoints = getTargetControlPoints(targetModel, isCharacterTarget == true)

	for _, targetPoint in controlPoints do
		local delta = targetPoint - blastOrigin
		if delta.Magnitude <= 0.1 then
			return true
		end

		local excludeList: { Instance } = { targetModel }
		if excludeInstances ~= nil then
			for _, inst in excludeInstances do
				table.insert(excludeList, inst)
			end
		end

		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.IgnoreWater = true
		params.FilterDescendantsInstances = excludeList

		local blocked = false
		for _ = 1, MAX_OCCLUSION_RAY_PASSES do
			local result = Workspace:Raycast(blastOrigin, delta, params)
			if result == nil then
				return true
			end

			if result.Instance:IsDescendantOf(targetModel) then
				return true
			end

			if result.Instance.CanCollide == false and not result.Instance:IsA("Terrain") then
				table.insert(excludeList, result.Instance)
				params.FilterDescendantsInstances = excludeList
				continue
			end

			local hitChar = findHumanoidCharacter(result.Instance)
			if hitChar ~= nil then
				table.insert(excludeList, hitChar)
				params.FilterDescendantsInstances = excludeList
				continue
			end

			blocked = true
			break
		end

		if not blocked then
			return true
		end
	end

	return false
end

function RaidExplosives.TriggerExplosion(params: ExplosionParams, deps: ExplosionDeps): ExplosionResult
	local summary: ExplosionResult = {
		DamagedStructures = 0,
		DestroyedStructures = 0,
		DamagedHumanoids = 0,
		OccludedStructures = 0,
		OccludedHumanoids = 0,
	}

	if not SecurityService.IsValidVector3(params.Origin) then
		return summary
	end
	if not SecurityService.IsFiniteNumber(params.Radius) or params.Radius <= 0 then
		return summary
	end

	local origin = params.Origin
	local radius = params.Radius
	local minMult = params.MinFalloffMultiplier or DEFAULT_MIN_FALLOFF_MULTIPLIER

	local baseExcludes: { Instance } = {}
	if params.ExcludeInstances ~= nil then
		for _, inst in params.ExcludeInstances do
			table.insert(baseExcludes, inst)
		end
	end

	local pendingStructureHits: { { Session: any, Record: any, Damage: number } } = {}
	local pendingBaseHits: { { Uid: string, Damage: number } } = {}
	if params.StructureDamage > 0 then
		for _, session in deps.ActiveSessions do
			for _, record in session.Pieces do
				if record.Model.Parent ~= nil then
					local closest = deps.ClosestPointOnModel(record.Model, origin)
					local dist = (closest - origin).Magnitude
					if dist <= radius then
						if RaidExplosives.HasExplosionLineOfSight(origin, record.Model, baseExcludes, false) then
							local falloff = computeBlastFalloff(dist, radius, minMult)
							local damage = BuildingConfig.ComputeExplosionDamage(
								params.StructureDamage * falloff,
								record.Piece.PieceType,
								record.Piece.Tier,
								record.Model:GetAttribute("HasDoor") == true
							)
							if damage > 0 then
								table.insert(pendingStructureHits, {
									Session = session,
									Record = record,
									Damage = damage,
								})
							end
						else
							summary.OccludedStructures += 1
						end
					end
				end
			end
		end

		for _, liveItem in BaseService.GetLivePieceModelsInRadius(origin, radius) do
			if liveItem.Model.Parent ~= nil then
				local closest = deps.ClosestPointOnModel(liveItem.Model, origin)
				local dist = (closest - origin).Magnitude
				if dist <= radius then
					if RaidExplosives.HasExplosionLineOfSight(origin, liveItem.Model, baseExcludes, false) then
						local falloff = computeBlastFalloff(dist, radius, minMult)
						local rawDamage = math.floor(params.StructureDamage * falloff + 0.5)
						if rawDamage > 0 then
							table.insert(pendingBaseHits, {
								Uid = liveItem.Uid,
								Damage = rawDamage,
							})
						end
					else
						summary.OccludedStructures += 1
					end
				end
			end
		end
	end

	local pendingHumanoidHits: { { Model: Model, Humanoid: Humanoid, Damage: number } } = {}
	if params.PlayerDamage > 0 then
		local checkedModels: { [Model]: boolean } = {}
		local candidateModels: { Model } = {}

		for _, plr in Players:GetPlayers() do
			local char = plr.Character
			if char ~= nil then
				table.insert(candidateModels, char)
			end
		end

		local dummiesFolder = Workspace:FindFirstChild("TestDummies")
		if dummiesFolder ~= nil then
			for _, child in dummiesFolder:GetChildren() do
				if child:IsA("Model") then
					table.insert(candidateModels, child)
				end
			end
		end

		for _, charModel in candidateModels do
			if checkedModels[charModel] or charModel.Parent == nil then
				continue
			end
			checkedModels[charModel] = true

			local humanoid = charModel:FindFirstChildOfClass("Humanoid")
			local hrp = charModel:FindFirstChild("HumanoidRootPart")
			if
				humanoid == nil
				or not SecurityService.IsFiniteNumber(humanoid.Health)
				or humanoid.Health <= 0
				or hrp == nil
				or not hrp:IsA("BasePart")
			then
				continue
			end

			local hrpDist = (hrp.Position - origin).Magnitude
			local closestDist = (deps.ClosestPointOnModel(charModel, origin) - origin).Magnitude
			local dist = math.min(hrpDist, closestDist)
			if dist <= radius then
				if RaidExplosives.HasExplosionLineOfSight(origin, charModel, baseExcludes, true) then
					local falloff = computeBlastFalloff(dist, radius, minMult)
					local damage = params.PlayerDamage * falloff
					if damage > 0 then
						table.insert(pendingHumanoidHits, {
							Model = charModel,
							Humanoid = humanoid,
							Damage = damage,
						})
					end
				else
					summary.OccludedHumanoids += 1
				end
			end
		end
	end

	local nowClock = os.clock()
	local nowServer = Workspace:GetServerTimeNow()
	local sessionsWithDestroyedPieces: { [any]: boolean } = {}
	for _, hit in pendingStructureHits do
		local record = hit.Record
		if hit.Session.Pieces[record.Piece.Uid] == record and record.Model.Parent ~= nil then
			record.Piece.Hp -= hit.Damage
			record.Piece.LastDamagedAt = nowClock
			record.Model:SetAttribute("LastDamagedAt", nowClock)
			record.Model:SetAttribute("LastDamagedServerTime", nowServer)
			record.Model:SetAttribute("RaidBlockUntil", nowServer + BuildingConfig.UpgradeRaidBlockSeconds)
			summary.DamagedStructures += 1
			if record.Piece.Hp <= 0 then
				deps.DestroyRaidPiece(hit.Session, record.Piece.Uid, true)
				sessionsWithDestroyedPieces[hit.Session] = true
				summary.DestroyedStructures += 1
			else
				record.Model:SetAttribute("Health", record.Piece.Hp)
				record.Model:SetAttribute("Hp", record.Piece.Hp)
				DefenseService.UpdateDefenseHp(record.Piece.Uid, record.Piece.Hp, nil)
				deps.UpdatePieceDamageBillboard(record)
			end
		end
	end

	for session in sessionsWithDestroyedPieces do
		local remainingPieces: { SavedBuildPiece } = {}
		for _, rec in session.Pieces do
			table.insert(remainingPieces, rec.Piece)
		end
		for _, unsupportedUid in BuildingValidator.FindUnsupportedPieces(remainingPieces, nil) do
			if session.Pieces[unsupportedUid] ~= nil then
				deps.DestroyRaidPiece(session, unsupportedUid, true)
				summary.DestroyedStructures += 1
			end
		end
	end

	for _, hit in pendingBaseHits do
		local damaged, destroyed = BaseService.DamagePiece(hit.Uid, hit.Damage, "Explosion", params.Attacker)
		if damaged then
			summary.DamagedStructures += 1
		end
		if destroyed then
			summary.DestroyedStructures += 1
		end
	end

	local dmgSource = if params.SourceId == "landmine"
		then "Killed by Landmine"
		elseif params.SourceId == "c4_charge" then "Killed by Timed C4"
		elseif params.SourceId == "satchel_charge" then "Killed by Satchel Charge"
		elseif params.ProjectileId == "rocket" or params.SourceId == "rocket" then "Killed by Rocket"
		else "Killed by Explosive"

	if params.Attacker ~= nil and (params.ProjectileId == "rocket" or params.SourceId == "rocket") then
		local attackerSession = deps.ActiveSessions[params.Attacker]
		if attackerSession ~= nil then
			local expValues = Config.Raid.ExplosiveScrapValues :: { [string]: number }
			attackerSession.RaiderSpentScrapValue += (expValues.rocket or 60)
		end
	end

	for _, hit in pendingHumanoidHits do
		if hit.Model.Parent ~= nil and hit.Humanoid.Health > 0 and not deps.IsCharacterInvulnerable(hit.Model) then
			if params.Attacker ~= nil and params.Attacker.Parent == Players then
				hit.Model:SetAttribute("LastAttackerUserId", params.Attacker.UserId)
			end
			hit.Model:SetAttribute("LastDamageSource", dmgSource)
			hit.Humanoid:TakeDamage(hit.Damage)
			local hitPlayer = Players:GetPlayerFromCharacter(hit.Model)
			if hitPlayer ~= nil then
				deps.NotifyRaiderDamaged(hitPlayer)
			end
			summary.DamagedHumanoids += 1
		end
	end

	broadcastExplosionEffect(origin, radius, params.SourceId or "explosion", params.ProjectileId, params.Attacker)

	return summary
end

function RaidExplosives.DetonateExplosive(
	session: any,
	explosiveRecord: ActiveExplosiveRecord,
	blastOrigin: Vector3,
	itemId: string,
	deps: ExplosionDeps
)
	if explosiveRecord.CancelFlag or deps.ActiveSessions[session.Raider] ~= session then
		return
	end
	if explosiveRecord.DetonateAt > 0 and os.clock() < explosiveRecord.DetonateAt - 0.05 then
		return
	end

	local cfg = Explosives[itemId]
	if cfg == nil then
		return
	end

	local excludePart: { Instance } = {}
	if explosiveRecord.Part.Parent then
		table.insert(excludePart, explosiveRecord.Part)
		explosiveRecord.Part:Destroy()
	end

	local idx = table.find(session.ActiveExplosives, explosiveRecord)
	if idx ~= nil then
		table.remove(session.ActiveExplosives, idx)
	end

	RaidExplosives.TriggerExplosion({
		Origin = blastOrigin,
		Radius = cfg.Radius,
		StructureDamage = cfg.StructureDamage,
		PlayerDamage = cfg.PlayerDamage,
		Attacker = session.Raider,
		SourceId = itemId,
		ExcludeInstances = excludePart,
	}, deps)
end

local function broadcastEmpSparksAt(position: Vector3)
	local evt = Net.GetEvent(Net.Events.DefenseEffect)
	for _, plr in Players:GetPlayers() do
		local char = plr.Character
		local hrp = if char then char:FindFirstChild("HumanoidRootPart") else nil
		if hrp and hrp:IsA("BasePart") and (hrp.Position - position).Magnitude <= EXPLOSION_EFFECT_BROADCAST_RADIUS then
			evt:FireClient(plr, "TurretEmp", position, {})
		end
	end
end

local function setDoorIndicatorColor(doorModel: Model, color: Color3)
	local indicator = doorModel:FindFirstChild("DoorIndicator")
	if indicator and indicator:IsA("BasePart") then
		indicator.Color = color
	end
end

function RaidExplosives.TriggerEmpPulse(
	origin: Vector3,
	radius: number,
	duration: number,
	attacker: Player?,
	projectileId: string?
): number
	if not SecurityService.IsValidVector3(origin) then
		return 0
	end
	local safeRadius = if SecurityService.IsFiniteNumber(radius) and radius > 0 then radius else Config.Raid.EmpRadius
	local safeDuration = if SecurityService.IsFiniteNumber(duration) and duration > 0
		then duration
		else Config.Raid.EmpDisableDuration

	local affectedCount = DefenseService.DisableTurretsInRadius(origin, safeRadius, safeDuration)
	local untilTime = os.clock() + safeDuration

	local containerNames = { "RaidTargetStructures", "PlayerBaseStructures", "QA_TestArena" }
	for _, containerName in containerNames do
		local container = Workspace:FindFirstChild(containerName)
		if container == nil then
			continue
		end
		for _, inst in container:GetDescendants() do
			if not inst:IsA("Model") then
				continue
			end
			if inst:GetAttribute("HasDoor") ~= true and inst:GetAttribute("IsSmartDoor") ~= true then
				continue
			end
			local doorPos = if inst.PrimaryPart then inst.PrimaryPart.Position else inst:GetPivot().Position
			if (doorPos - origin).Magnitude <= safeRadius then
				local prevOpen = inst:GetAttribute("DoorOpen") == true
				if inst:GetAttribute("EmpSavedDoorOpen") == nil then
					inst:SetAttribute("EmpSavedDoorOpen", prevOpen)
				end
				inst:SetAttribute("DisabledUntil", untilTime)
				inst:SetAttribute("EmpDisabled", true)
				BuildingGeometry.SetDoorOpen(inst, true)
				setDoorIndicatorColor(inst, Color3.fromRGB(60, 185, 255))
				broadcastEmpSparksAt(doorPos + Vector3.new(0, 3.5, 0))
				affectedCount += 1

				task.delay(safeDuration + 0.05, function()
					if inst.Parent == nil then
						return
					end
					local latestUntil = inst:GetAttribute("DisabledUntil")
					if typeof(latestUntil) == "number" and os.clock() + 0.02 < latestUntil then
						return
					end
					inst:SetAttribute("EmpDisabled", false)
					local savedOpen = inst:GetAttribute("EmpSavedDoorOpen")
					inst:SetAttribute("EmpSavedDoorOpen", nil)
					if savedOpen == false then
						BuildingGeometry.SetDoorOpen(inst, false)
						setDoorIndicatorColor(inst, Color3.fromRGB(220, 65, 65))
					else
						setDoorIndicatorColor(inst, Color3.fromRGB(65, 220, 110))
					end
				end)
			end
		end
	end

	broadcastExplosionEffect(origin, safeRadius, "emp_grenade", projectileId, attacker)
	return affectedCount
end

function RaidExplosives.TriggerSmokeCloud(
	origin: Vector3,
	duration: number,
	attacker: Player?,
	projectileId: string?
): Model?
	if not SecurityService.IsValidVector3(origin) then
		return nil
	end
	local safeDuration = if SecurityService.IsFiniteNumber(duration) and duration > 0
		then duration
		else Config.Raid.SmokeDuration

	nextSmokeSeq += 1
	local cloudModel = Instance.new("Model")
	cloudModel.Name = string.format("SmokeCloud_%d", nextSmokeSeq)
	cloudModel:SetAttribute("SmokeVolume", true)
	cloudModel:SetAttribute("ExpiresAt", os.clock() + safeDuration)

	local puffs: { { Offset: Vector3, Size: Vector3, Transparency: number } } = {
		{ Offset = Vector3.new(0, 3.8, 0), Size = Vector3.new(9.5, 8.5, 9.5), Transparency = 0.28 },
		{ Offset = Vector3.new(4.2, 3.2, 1.5), Size = Vector3.new(8.2, 7.2, 8.2), Transparency = 0.34 },
		{ Offset = Vector3.new(-4.2, 3.4, -1.5), Size = Vector3.new(8.2, 7.2, 8.2), Transparency = 0.34 },
		{ Offset = Vector3.new(1.5, 3.2, -4.4), Size = Vector3.new(8.0, 7.0, 8.0), Transparency = 0.34 },
		{ Offset = Vector3.new(-1.8, 3.3, 4.3), Size = Vector3.new(8.0, 7.0, 8.0), Transparency = 0.34 },
		{ Offset = Vector3.new(3.8, 5.4, -3.2), Size = Vector3.new(7.2, 6.5, 7.2), Transparency = 0.40 },
		{ Offset = Vector3.new(-3.6, 5.5, 3.2), Size = Vector3.new(7.2, 6.5, 7.2), Transparency = 0.40 },
		{ Offset = Vector3.new(0, 6.4, 0), Size = Vector3.new(7.6, 6.5, 7.6), Transparency = 0.42 },
	}

	for idx, puff in puffs do
		local sphere = Instance.new("Part")
		sphere.Name = string.format("SmokePuff_%d", idx)
		sphere.Shape = Enum.PartType.Ball
		sphere.Size = puff.Size
		sphere.CFrame = CFrame.new(origin + puff.Offset)
		sphere.Anchored = true
		sphere.CanCollide = false
		sphere.CanQuery = true
		sphere.CanTouch = false
		sphere.CastShadow = false
		sphere.Material = Enum.Material.SmoothPlastic
		sphere.Color = Color3.fromRGB(195, 202, 210)
		sphere.Transparency = puff.Transparency
		sphere:SetAttribute("SmokeVolume", true)
		CollectionService:AddTag(sphere, "SmokeVolume")
		sphere.Parent = cloudModel
		if idx == 1 then
			cloudModel.PrimaryPart = sphere
		end
	end

	cloudModel.Parent = getOrCreateSmokeFolder()
	Debris:AddItem(cloudModel, safeDuration)
	broadcastExplosionEffect(origin, Config.Raid.SmokeCloudRadius, "smoke_grenade", projectileId, attacker)
	return cloudModel
end

return RaidExplosives
