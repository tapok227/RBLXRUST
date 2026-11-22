--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Ballistics = require(ReplicatedStorage.Shared.Ballistics)
local BuildingGeometry = require(ReplicatedStorage.Shared.BuildingGeometry)
local Defenses = require(ReplicatedStorage.Shared.configs.Defenses)
local Net = require(ReplicatedStorage.Shared.Net)
local Types = require(ReplicatedStorage.Shared.Types)
local DataService = require(ServerScriptService.Server.Services.DataService)
local InventoryService = require(ServerScriptService.Server.Services.InventoryService)
local SecurityService = require(ServerScriptService.Server.Services.SecurityService)

type Slot = Types.Slot
type Inventory = Types.Inventory
type BuildPieceType = Types.BuildPieceType
type SavedBuildPiece = Types.SavedBuildPiece
type DefenseConfig = Types.DefenseConfig
type DefenseUiState = Types.DefenseUiState
type ExplosionParams = Types.ExplosionParams
type ExplosionResult = Types.ExplosionResult

export type RegisterDefenseOptions = {
	Uid: string,
	PieceType: BuildPieceType,
	Model: Model,
	BaseWorldCF: CFrame?,
	OwnerUserId: number,
	OwnerPlayer: Player?,
	IsRaidInstance: boolean?,
	IsQaTest: boolean?,
	PieceRef: SavedBuildPiece?,
	Hp: number?,
	MaxHp: number?,
	OnSelfDamage: ((uid: string, damage: number) -> ())?,
	OnSelfDestroy: ((uid: string) -> ())?,
	OnStorageChanged: ((uid: string) -> ())?,
}

export type RaidHookBindings = {
	TriggerExplosion: (params: ExplosionParams) -> ExplosionResult,
	NotifyRaiderDamaged: (player: Player) -> (),
}

type ActiveDefenseRecord = {
	Uid: string,
	PieceType: BuildPieceType,
	Config: DefenseConfig,
	Model: Model,
	BaseWorldCF: CFrame,
	OwnerUserId: number,
	OwnerPlayer: Player?,
	IsRaidInstance: boolean,
	IsQaTest: boolean,
	PieceRef: SavedBuildPiece?,
	Storage: { [string]: Slot },
	Hp: number,
	MaxHp: number,
	LastFireTime: number,
	Triggered: boolean,
	LockTarget: Model?,
	LockStartTime: number,
	LastLockEffectTime: number,
	BurstRemaining: number,
	NextBurstShotTime: number,
	Prompt: ProximityPrompt?,
	PromptConn: RBXScriptConnection?,
	OnSelfDamage: ((uid: string, damage: number) -> ())?,
	OnSelfDestroy: ((uid: string) -> ())?,
	OnStorageChanged: ((uid: string) -> ())?,
}

type SlowState = {
	BaseSpeed: number,
	Token: number,
}

local SCAN_INTERVAL = 0.15
local EFFECT_BROADCAST_RADIUS = 160
local TURRET_PIVOT_HEIGHT = 2.55
local MAX_AMMO_STACK = 64
local MAX_LOS_PASSES = 6

local TURRET_LOCAL_HEAD = CFrame.new(0, 0, 0)
local TURRET_LOCAL_DRUM = CFrame.new(0.9, -0.1, 0.2)
local TURRET_LOCAL_BARREL = CFrame.new(0, 0, -1.65)
local TURRET_LOCAL_MUZZLE = CFrame.new(0, 0, -2.55)
local TURRET_LOCAL_SENSOR = CFrame.new(0, 0.5, -0.65)

local defensesByUid: { [string]: ActiveDefenseRecord } = {}
local openDefenseByPlayer: { [Player]: string } = {}
local slowStates: { [Humanoid]: SlowState } = {}
local raidHooks: RaidHookBindings = {
	TriggerExplosion = function(_params: ExplosionParams): ExplosionResult
		return {
			DamagedStructures = 0,
			DestroyedStructures = 0,
			DamagedHumanoids = 0,
			OccludedStructures = 0,
			OccludedHumanoids = 0,
		}
	end,
	NotifyRaiderDamaged = function(_player: Player) end,
}

local nextBulletSeq = 0
local nextSlowToken = 0
local lastScanClock = 0
local isInitialized = false

local DefenseService = {}

local function getDefenseOriginPosition(record: ActiveDefenseRecord): Vector3
	if record.Model.PrimaryPart ~= nil then
		return record.Model.PrimaryPart.Position
	end
	return record.BaseWorldCF.Position
end

local function countStorageAmmo(record: ActiveDefenseRecord): number
	local ammoId = record.Config.AmmoId
	if ammoId == nil then
		return 0
	end
	local total = 0
	local maxSlots = record.Config.AmmoSlots or 0
	for i = 1, maxSlots do
		local slot = record.Storage[tostring(i)]
		if slot ~= nil and slot.Id == ammoId and slot.Count > 0 then
			total += math.floor(slot.Count)
		end
	end
	return total
end

local function consumeStorageAmmo(record: ActiveDefenseRecord, amount: number): boolean
	local ammoId = record.Config.AmmoId
	if ammoId == nil or amount <= 0 then
		return false
	end
	if countStorageAmmo(record) < amount then
		return false
	end

	local remaining = amount
	local maxSlots = record.Config.AmmoSlots or 0
	for i = maxSlots, 1, -1 do
		if remaining <= 0 then
			break
		end
		local key = tostring(i)
		local slot = record.Storage[key]
		if slot ~= nil and slot.Id == ammoId and slot.Count > 0 then
			local take = math.min(remaining, slot.Count)
			slot.Count -= take
			remaining -= take
			if slot.Count <= 0 then
				record.Storage[key] = nil
			end
		end
	end

	if record.PieceRef ~= nil then
		record.PieceRef.Storage = record.Storage
	end
	if record.OnStorageChanged ~= nil then
		record.OnStorageChanged(record.Uid)
	end
	return true
end

local function depositStorageAmmo(record: ActiveDefenseRecord, amount: number): number
	local ammoId = record.Config.AmmoId
	local maxSlots = record.Config.AmmoSlots or 0
	if ammoId == nil or maxSlots <= 0 or amount <= 0 then
		return 0
	end

	local remaining = amount
	for i = 1, maxSlots do
		if remaining <= 0 then
			break
		end
		local key = tostring(i)
		local slot = record.Storage[key]
		if slot ~= nil and slot.Id == ammoId and slot.Count < MAX_AMMO_STACK then
			local add = math.min(remaining, MAX_AMMO_STACK - slot.Count)
			slot.Count += add
			remaining -= add
		end
	end
	for i = 1, maxSlots do
		if remaining <= 0 then
			break
		end
		local key = tostring(i)
		if record.Storage[key] == nil then
			local add = math.min(remaining, MAX_AMMO_STACK)
			record.Storage[key] = { Id = ammoId, Count = add }
			remaining -= add
		end
	end

	local added = amount - remaining
	if added > 0 then
		if record.PieceRef ~= nil then
			record.PieceRef.Storage = record.Storage
		end
		if record.OnStorageChanged ~= nil then
			record.OnStorageChanged(record.Uid)
		end
	end
	return added
end

local function storageToInventory(storage: { [string]: Slot }, maxSlots: number): Inventory
	local inv: Inventory = {}
	for i = 1, maxSlots do
		local slot = storage[tostring(i)]
		if slot ~= nil and slot.Count > 0 then
			inv[i] = { Id = slot.Id, Count = math.floor(slot.Count) }
		end
	end
	return inv
end

local function computeOwnerCapacity(owner: Player): (number, number)
	local data = DataService.GetData(owner)
	if data == nil then
		return 0, Defenses.GetCapacityLimit(0)
	end
	local used = 0
	for _, piece in data.Base.Pieces do
		local canonical = BuildingGeometry.CanonicalPieceType(piece.PieceType)
		local defCfg = Defenses.Get(canonical)
		if defCfg ~= nil then
			used += defCfg.CapacityCost
		end
	end
	return used, Defenses.GetCapacityLimit(data.Base.BaseTier)
end

local function buildUiStateForRecord(record: ActiveDefenseRecord, owner: Player): DefenseUiState?
	local ammoId = record.Config.AmmoId
	local ammoSlots = record.Config.AmmoSlots or 0
	if ammoId == nil or ammoSlots <= 0 then
		return nil
	end
	local used, maxCap = computeOwnerCapacity(owner)
	return {
		Uid = record.Uid,
		PieceType = record.PieceType,
		Name = record.Config.Name,
		Hp = math.max(0, math.floor(record.Hp + 0.5)),
		MaxHp = math.max(1, math.floor(record.MaxHp + 0.5)),
		AmmoId = ammoId,
		AmmoCount = countStorageAmmo(record),
		AmmoSlots = ammoSlots,
		Slots = storageToInventory(record.Storage, ammoSlots),
		DefenseUsed = used,
		DefenseMax = maxCap,
	}
end

local function syncDefenseUiForOwner(record: ActiveDefenseRecord)
	local owner = record.OwnerPlayer
	if owner == nil or owner.Parent ~= Players then
		return
	end
	if openDefenseByPlayer[owner] ~= record.Uid then
		return
	end
	local state = buildUiStateForRecord(record, owner)
	if state == nil then
		openDefenseByPlayer[owner] = nil
	end
	Net.GetEvent(Net.Events.DefenseSync):FireClient(owner, state)
end

local function closeDefenseUiForPlayer(player: Player)
	if openDefenseByPlayer[player] ~= nil then
		openDefenseByPlayer[player] = nil
		if player.Parent == Players then
			Net.GetEvent(Net.Events.DefenseSync):FireClient(player, nil)
		end
	end
end

local function broadcastDefenseEffect(effectKind: string, origin: Vector3, targetPositions: { Vector3 })
	local evt = Net.GetEvent(Net.Events.DefenseEffect)
	for _, plr in Players:GetPlayers() do
		local char = plr.Character
		local hrp = if char then char:FindFirstChild("HumanoidRootPart") else nil
		if hrp and hrp:IsA("BasePart") and (hrp.Position - origin).Magnitude <= EFFECT_BROADCAST_RADIUS then
			evt:FireClient(plr, effectKind, origin, targetPositions)
		end
	end
end

local function setSensorColor(record: ActiveDefenseRecord, color: Color3)
	local sensor = record.Model:FindFirstChild("SensorLight")
	if sensor and sensor:IsA("BasePart") then
		sensor.Color = color
	end
end

local function updateTurretAimCFrame(record: ActiveDefenseRecord, lookTargetPos: Vector3?)
	local pivotWorldCF = record.BaseWorldCF * CFrame.new(0, TURRET_PIVOT_HEIGHT, 0)
	local aimCF: CFrame
	if lookTargetPos ~= nil then
		local delta = lookTargetPos - pivotWorldCF.Position
		if delta.Magnitude > 0.1 then
			aimCF = CFrame.lookAt(pivotWorldCF.Position, lookTargetPos)
		else
			aimCF = pivotWorldCF
		end
	else
		aimCF = pivotWorldCF
	end

	local mapping: { { Name: string, Offset: CFrame } } = {
		{ Name = "TurretHead", Offset = TURRET_LOCAL_HEAD },
		{ Name = "AmmoDrum", Offset = TURRET_LOCAL_DRUM },
		{ Name = "TurretBarrel", Offset = TURRET_LOCAL_BARREL },
		{ Name = "Muzzle", Offset = TURRET_LOCAL_MUZZLE },
		{ Name = "SensorLight", Offset = TURRET_LOCAL_SENSOR },
	}
	for _, entry in mapping do
		local part = record.Model:FindFirstChild(entry.Name)
		if part and part:IsA("BasePart") then
			part.CFrame = aimCF * entry.Offset
		end
	end
end

local function findCharacterModelFromPart(inst: Instance): (Model?, Humanoid?)
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

local function collectCandidateTargets(
	record: ActiveDefenseRecord
): { { Model: Model, Humanoid: Humanoid, Root: BasePart } }
	local targets: { { Model: Model, Humanoid: Humanoid, Root: BasePart } } = {}
	local seen: { [Model]: boolean } = {}

	local function considerModel(charModel: Model?)
		if charModel == nil or charModel.Parent == nil or seen[charModel] then
			return
		end
		seen[charModel] = true
		local humanoid = charModel:FindFirstChildOfClass("Humanoid")
		local hrp = charModel:FindFirstChild("HumanoidRootPart")
		if
			humanoid == nil
			or not SecurityService.IsFiniteNumber(humanoid.Health)
			or humanoid.Health <= 0
			or hrp == nil
			or not hrp:IsA("BasePart")
		then
			return
		end

		local plr = Players:GetPlayerFromCharacter(charModel)
		if plr ~= nil then
			if not record.IsQaTest and plr.UserId == record.OwnerUserId then
				return
			end
		end

		table.insert(targets, {
			Model = charModel,
			Humanoid = humanoid,
			Root = hrp,
		})
	end

	for _, plr in Players:GetPlayers() do
		considerModel(plr.Character)
	end

	local dummiesFolder = Workspace:FindFirstChild("TestDummies")
	if dummiesFolder ~= nil then
		for _, child in dummiesFolder:GetChildren() do
			if child:IsA("Model") then
				considerModel(child)
			end
		end
	end

	return targets
end

local function hasLineOfSight(origin: Vector3, targetPart: BasePart, targetModel: Model, defenseModel: Model): boolean
	local delta = targetPart.Position - origin
	if delta.Magnitude <= 0.1 then
		return true
	end

	local excludeList: { Instance } = { defenseModel }
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.IgnoreWater = true
	params.FilterDescendantsInstances = excludeList

	for _ = 1, MAX_LOS_PASSES do
		local hit = Workspace:Raycast(origin, delta, params)
		if hit == nil then
			return true
		end
		if hit.Instance:IsDescendantOf(targetModel) then
			return true
		end
		if hit.Instance.CanCollide == false and not hit.Instance:IsA("Terrain") then
			table.insert(excludeList, hit.Instance)
			params.FilterDescendantsInstances = excludeList
		else
			return false
		end
	end

	return false
end

local function isCharacterInvulnerable(targetModel: Model): boolean
	return targetModel:GetAttribute("RaidInvulnerable") == true
		or targetModel:FindFirstChildOfClass("ForceField") ~= nil
end

local function applyDamageToTarget(record: ActiveDefenseRecord, targetModel: Model, humanoid: Humanoid, amount: number)
	if humanoid.Health <= 0 or amount <= 0 or isCharacterInvulnerable(targetModel) then
		return
	end
	if record.OwnerUserId ~= 0 then
		targetModel:SetAttribute("LastAttackerUserId", record.OwnerUserId)
	end
	humanoid:TakeDamage(amount)
	local hitPlayer = Players:GetPlayerFromCharacter(targetModel)
	if hitPlayer ~= nil then
		raidHooks.NotifyRaiderDamaged(hitPlayer)
	end
end

local function applySlowToHumanoid(humanoid: Humanoid, multiplier: number, duration: number)
	local existing = slowStates[humanoid]
	local baseSpeed = if existing ~= nil then existing.BaseSpeed else humanoid.WalkSpeed
	nextSlowToken += 1
	local token = nextSlowToken

	slowStates[humanoid] = {
		BaseSpeed = baseSpeed,
		Token = token,
	}
	humanoid.WalkSpeed = math.max(2, baseSpeed * multiplier)

	task.delay(duration, function()
		local current = slowStates[humanoid]
		if current ~= nil and current.Token == token then
			slowStates[humanoid] = nil
			if humanoid.Parent ~= nil and humanoid.Health > 0 then
				humanoid.WalkSpeed = current.BaseSpeed
			end
		end
	end)
end

local function tickFloorSpikes(record: ActiveDefenseRecord, now: number)
	local cfg = record.Config
	if (now - record.LastFireTime) < cfg.Cooldown then
		return
	end

	local trapPos = getDefenseOriginPosition(record)
	local hitAny = false
	local hitPositions: { Vector3 } = {}

	for _, target in collectCandidateTargets(record) do
		local tPos = target.Root.Position
		local dx = tPos.X - trapPos.X
		local dz = tPos.Z - trapPos.Z
		local horizDist = math.sqrt(dx * dx + dz * dz)
		if
			horizDist <= cfg.Range
			and math.abs(tPos.Y - trapPos.Y) <= 4.0
			and not isCharacterInvulnerable(target.Model)
		then
			hitAny = true
			table.insert(hitPositions, tPos)
			applyDamageToTarget(record, target.Model, target.Humanoid, cfg.Damage)
			applySlowToHumanoid(target.Humanoid, cfg.SlowMultiplier or 0.55, cfg.SlowDuration or 1.5)
		end
	end

	if hitAny then
		record.LastFireTime = now
		broadcastDefenseEffect("Spikes", trapPos, hitPositions)
		local selfDmg = cfg.SelfDamageOnTrigger or 10
		if record.OnSelfDamage ~= nil then
			record.OnSelfDamage(record.Uid, selfDmg)
		end
	end
end

local function tickLandmine(record: ActiveDefenseRecord)
	if record.Triggered then
		return
	end
	local cfg = record.Config
	local minePos = getDefenseOriginPosition(record)

	for _, target in collectCandidateTargets(record) do
		local tPos = target.Root.Position
		local dx = tPos.X - minePos.X
		local dz = tPos.Z - minePos.Z
		local horizDist = math.sqrt(dx * dx + dz * dz)
		if horizDist <= cfg.Range and math.abs(tPos.Y - minePos.Y) <= 4.0 then
			record.Triggered = true
			broadcastDefenseEffect("MineArm", minePos, { tPos })
			task.delay(0.15, function()
				if record.Model.Parent == nil then
					return
				end
				raidHooks.TriggerExplosion({
					Origin = minePos + Vector3.new(0, 0.8, 0),
					Radius = cfg.ExplosionRadius or 14,
					StructureDamage = cfg.ExplosionStructureDamage or 90,
					PlayerDamage = cfg.ExplosionPlayerDamage or 85,
					SourceId = "landmine",
					ExcludeInstances = { record.Model },
				})
				if record.OnSelfDestroy ~= nil then
					record.OnSelfDestroy(record.Uid)
				end
			end)
			break
		end
	end
end

local function castShotgunPellet(
	origin: Vector3,
	dir: Vector3,
	range: number,
	defenseModel: Model
): (RaycastResult?, Vector3)
	local excludeList: { Instance } = { defenseModel }
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.IgnoreWater = true
	params.FilterDescendantsInstances = excludeList

	for _ = 1, MAX_LOS_PASSES do
		local hit = Workspace:Raycast(origin, dir * range, params)
		if hit == nil then
			return nil, origin + dir * range
		end
		local charModel = findCharacterModelFromPart(hit.Instance)
		if charModel ~= nil then
			return hit, hit.Position
		end
		if hit.Instance.CanCollide == false and not hit.Instance:IsA("Terrain") then
			table.insert(excludeList, hit.Instance)
			params.FilterDescendantsInstances = excludeList
		else
			return hit, hit.Position
		end
	end
	return nil, origin + dir * range
end

local function tickShotgunTrap(record: ActiveDefenseRecord, now: number)
	local cfg = record.Config
	if (now - record.LastFireTime) < cfg.Cooldown then
		return
	end
	if countStorageAmmo(record) < 1 then
		return
	end

	local muzzlePart = record.Model:FindFirstChild("Muzzle")
	local muzzlePos: Vector3
	local muzzleDir: Vector3
	if muzzlePart and muzzlePart:IsA("BasePart") then
		muzzlePos = muzzlePart.Position
		muzzleDir = muzzlePart.CFrame.LookVector
	else
		muzzlePos = getDefenseOriginPosition(record)
		muzzleDir = record.BaseWorldCF.LookVector
	end

	local maxAngleDeg = cfg.ConeHalfAngleDeg or 35
	local chosenTargetPos: Vector3? = nil
	local bestDist = cfg.Range + 0.01

	for _, target in collectCandidateTargets(record) do
		local targetPos = target.Root.Position
		local toTarget = targetPos - muzzlePos
		local dist = toTarget.Magnitude
		if dist > 0.2 and dist <= cfg.Range and dist < bestDist then
			local unitDir = toTarget / dist
			local angleDeg = math.deg(math.acos(math.clamp(muzzleDir:Dot(unitDir), -1, 1)))
			if angleDeg <= maxAngleDeg and hasLineOfSight(muzzlePos, target.Root, target.Model, record.Model) then
				bestDist = dist
				chosenTargetPos = targetPos
			end
		end
	end

	if chosenTargetPos == nil then
		return
	end
	if not consumeStorageAmmo(record, 1) then
		return
	end

	record.LastFireTime = now
	syncDefenseUiForOwner(record)

	local aimDir = ((chosenTargetPos :: Vector3) - muzzlePos).Unit
	local baseAimCF = CFrame.lookAt(muzzlePos, muzzlePos + aimDir)
	local spreadRad = math.rad(cfg.SpreadDeg or 10)
	local pellets = cfg.PelletCount or 6

	local damageByModel: { [Model]: { Humanoid: Humanoid, Damage: number } } = {}
	local endPositions: { Vector3 } = {}

	for _ = 1, pellets do
		local rx = (math.random() * 2 - 1) * spreadRad
		local ry = (math.random() * 2 - 1) * spreadRad
		local pelletDir = (baseAimCF * CFrame.Angles(rx, ry, 0)).LookVector
		local hit, endPos = castShotgunPellet(muzzlePos, pelletDir, cfg.Range, record.Model)
		table.insert(endPositions, endPos)
		if hit ~= nil then
			local charModel, humanoid = findCharacterModelFromPart(hit.Instance)
			if charModel ~= nil and humanoid ~= nil and humanoid.Health > 0 then
				local validTarget = true
				local plr = Players:GetPlayerFromCharacter(charModel)
				if plr ~= nil and not record.IsQaTest and plr.UserId == record.OwnerUserId then
					validTarget = false
				end
				if validTarget then
					local entry = damageByModel[charModel]
					if entry == nil then
						damageByModel[charModel] = { Humanoid = humanoid, Damage = cfg.Damage }
					else
						entry.Damage += cfg.Damage
					end
				end
			end
		end
	end

	for charModel, entry in damageByModel do
		applyDamageToTarget(record, charModel, entry.Humanoid, entry.Damage)
	end

	broadcastDefenseEffect("Shotgun", muzzlePos, endPositions)
end

local function fireTurretRound(record: ActiveDefenseRecord, targetPos: Vector3)
	local cfg = record.Config
	if not consumeStorageAmmo(record, 1) then
		return
	end
	syncDefenseUiForOwner(record)

	local muzzlePart = record.Model:FindFirstChild("Muzzle")
	local pivotPos = (record.BaseWorldCF * CFrame.new(0, TURRET_PIVOT_HEIGHT, 0)).Position
	local muzzlePos = if muzzlePart and muzzlePart:IsA("BasePart")
		then muzzlePart.Position
		else (pivotPos + (targetPos - pivotPos).Unit * 2.5)

	local delta = targetPos - muzzlePos
	local aimDir = if delta.Magnitude > 0.1 then delta.Unit else record.BaseWorldCF.LookVector
	local speed = cfg.ProjectileSpeed or 190
	local gravity = cfg.ProjectileGravity or 12

	nextBulletSeq += 1
	local bulletId = string.format("turret_%s_%d", string.sub(record.Uid, 1, 8), nextBulletSeq)

	broadcastDefenseEffect("TurretShot", muzzlePos, { targetPos })

	Ballistics.Spawn({
		Id = bulletId,
		Origin = muzzlePos,
		InitialVelocity = aimDir * speed,
		Gravity = gravity,
		MaxLifetime = 0.6,
		ExcludeInstances = { record.Model },
		OnHit = function(hitResult: RaycastResult, _vel: Vector3, _elapsed: number)
			local charModel, humanoid = findCharacterModelFromPart(hitResult.Instance)
			if charModel ~= nil and humanoid ~= nil and humanoid.Health > 0 then
				local plr = Players:GetPlayerFromCharacter(charModel)
				if plr ~= nil and not record.IsQaTest and plr.UserId == record.OwnerUserId then
					return
				end
				applyDamageToTarget(record, charModel, humanoid, cfg.Damage)
			end
		end,
	})
end

local function tickAutoTurret(record: ActiveDefenseRecord, now: number)
	local cfg = record.Config
	if countStorageAmmo(record) < 1 then
		record.LockTarget = nil
		record.BurstRemaining = 0
		setSensorColor(record, Color3.fromRGB(110, 110, 115))
		return
	end

	local pivotPos = (record.BaseWorldCF * CFrame.new(0, TURRET_PIVOT_HEIGHT, 0)).Position
	local bestTarget: { Model: Model, Humanoid: Humanoid, Root: BasePart }? = nil
	local bestDist = cfg.Range + 0.01

	for _, target in collectCandidateTargets(record) do
		local dist = (target.Root.Position - pivotPos).Magnitude
		if dist <= cfg.Range and dist < bestDist then
			if hasLineOfSight(pivotPos, target.Root, target.Model, record.Model) then
				bestDist = dist
				bestTarget = target
			end
		end
	end

	if bestTarget == nil then
		record.LockTarget = nil
		record.BurstRemaining = 0
		setSensorColor(record, Color3.fromRGB(65, 225, 110))
		return
	end

	local targetPos = bestTarget.Root.Position
	updateTurretAimCFrame(record, targetPos)

	if record.LockTarget ~= bestTarget.Model then
		record.LockTarget = bestTarget.Model
		record.LockStartTime = now
		record.BurstRemaining = 0
		if (now - record.LastLockEffectTime) >= 0.4 then
			record.LastLockEffectTime = now
			broadcastDefenseEffect("TurretLock", pivotPos, { targetPos })
		end
	end

	local lockDuration = cfg.LockOnDuration or 0.8
	if (now - record.LockStartTime) < lockDuration then
		setSensorColor(record, Color3.fromRGB(255, 165, 35))
		return
	end

	setSensorColor(record, Color3.fromRGB(255, 45, 45))

	if record.BurstRemaining > 0 then
		if now >= record.NextBurstShotTime then
			record.BurstRemaining -= 1
			record.NextBurstShotTime = now + (cfg.BurstInterval or 0.14)
			fireTurretRound(record, targetPos)
			if record.BurstRemaining <= 0 then
				record.LastFireTime = now
			end
		end
		return
	end

	if (now - record.LastFireTime) >= cfg.Cooldown then
		record.BurstRemaining = math.max(1, (cfg.BurstCount or 3) - 1)
		record.NextBurstShotTime = now + (cfg.BurstInterval or 0.14)
		fireTurretRound(record, targetPos)
		if record.BurstRemaining <= 0 then
			record.LastFireTime = now
		end
	end
end

local function onHeartbeat()
	local now = os.clock()
	if (now - lastScanClock) < SCAN_INTERVAL then
		return
	end
	lastScanClock = now

	local snapshot: { ActiveDefenseRecord } = {}
	for _, record in defensesByUid do
		if record.Model.Parent ~= nil then
			table.insert(snapshot, record)
		end
	end

	for _, record in snapshot do
		if record.Model.Parent == nil or defensesByUid[record.Uid] ~= record then
			continue
		end
		if record.PieceType == "floor_spikes" then
			tickFloorSpikes(record, now)
		elseif record.PieceType == "landmine" then
			tickLandmine(record)
		elseif record.PieceType == "shotgun_trap" then
			tickShotgunTrap(record, now)
		elseif record.PieceType == "auto_turret" then
			tickAutoTurret(record, now)
		end
	end
end

local function attachAmmoPrompt(record: ActiveDefenseRecord)
	if record.IsRaidInstance or record.IsQaTest then
		return
	end
	if record.Config.AmmoId == nil or (record.Config.AmmoSlots or 0) <= 0 then
		return
	end
	local primary = record.Model.PrimaryPart
	if primary == nil then
		return
	end

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "DefenseAmmoPrompt"
	prompt.ActionText = "Manage Ammo"
	prompt.ObjectText = record.Config.Name
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 10
	prompt.RequiresLineOfSight = false
	prompt.Parent = primary

	record.Prompt = prompt
	record.PromptConn = prompt.Triggered:Connect(function(triggerPlayer: Player)
		if triggerPlayer.UserId ~= record.OwnerUserId then
			return
		end
		if not SecurityService.IsWithinDistance(triggerPlayer, primary.Position, Types.MAX_LOOT_DISTANCE) then
			return
		end
		openDefenseByPlayer[triggerPlayer] = record.Uid
		syncDefenseUiForOwner(record)
	end)
end

local function onDefenseAction(player: Player, actionAny: any, argAny: any)
	if not SecurityService.CheckRateLimit(player, Net.Events.DefenseAction) then
		return
	end
	if DataService.IsTeleporting(player) or SecurityService.IsTransactionLocked(player) then
		return
	end
	if not SecurityService.IsValidString(actionAny, 1, 32) then
		return
	end

	local action = actionAny :: string
	if action == "Close" then
		openDefenseByPlayer[player] = nil
		return
	end

	local openUid = openDefenseByPlayer[player]
	if openUid == nil then
		return
	end

	SecurityService.RunLocked(player, "DefenseAction", function()
		local record = defensesByUid[openUid]
		if record == nil or record.Model.Parent == nil or record.OwnerUserId ~= player.UserId then
			closeDefenseUiForPlayer(player)
			return
		end

		local originPos = getDefenseOriginPosition(record)
		if not SecurityService.IsWithinDistance(player, originPos, Types.MAX_LOOT_DISTANCE) then
			closeDefenseUiForPlayer(player)
			return
		end

		local ammoId = record.Config.AmmoId
		local maxSlots = record.Config.AmmoSlots or 0
		if ammoId == nil or maxSlots <= 0 then
			closeDefenseUiForPlayer(player)
			return
		end

		if action == "DepositAmmo" then
			local owned = InventoryService.GetItemCount(player, ammoId)
			if owned <= 0 then
				syncDefenseUiForOwner(record)
				return
			end
			local toDeposit = math.min(owned, MAX_AMMO_STACK)
			local added = depositStorageAmmo(record, toDeposit)
			if added > 0 then
				if not InventoryService.RemoveItem(player, ammoId, added) then
					consumeStorageAmmo(record, added)
				end
			end
			syncDefenseUiForOwner(record)
		elseif action == "WithdrawSlot" then
			if not SecurityService.IsValidInteger(argAny, 1, maxSlots) then
				return
			end
			local slotIdx = argAny :: number
			local key = tostring(slotIdx)
			local slot = record.Storage[key]
			if slot ~= nil and slot.Count > 0 then
				local added = InventoryService.AddItem(player, slot.Id, slot.Count)
				if added > 0 then
					slot.Count -= added
					if slot.Count <= 0 then
						record.Storage[key] = nil
					end
					if record.PieceRef ~= nil then
						record.PieceRef.Storage = record.Storage
					end
					if record.OnStorageChanged ~= nil then
						record.OnStorageChanged(record.Uid)
					end
				end
			end
			syncDefenseUiForOwner(record)
		end
	end)
end

local function tryRegisterQaModel(inst: Instance)
	if not inst:IsA("Model") then
		return
	end
	if inst:GetAttribute("IsQaDefense") ~= true then
		return
	end
	local pieceTypeAttr = inst:GetAttribute("PieceType")
	if typeof(pieceTypeAttr) ~= "string" then
		return
	end
	local canonical = BuildingGeometry.CanonicalPieceType(pieceTypeAttr)
	local defCfg = Defenses.Get(canonical)
	if defCfg == nil then
		return
	end

	local uidAttr = inst:GetAttribute("DefenseUid")
	local uid = if typeof(uidAttr) == "string" and #uidAttr > 0 then uidAttr else inst:GetFullName()
	if defensesByUid[uid] ~= nil then
		return
	end

	local initAmmoAttr = inst:GetAttribute("InitialAmmo")
	local initAmmo = if typeof(initAmmoAttr) == "number" and initAmmoAttr > 0 then math.floor(initAmmoAttr) else 30
	local storage: { [string]: Slot } = {}
	if defCfg.AmmoId ~= nil and (defCfg.AmmoSlots or 0) > 0 and initAmmo > 0 then
		storage["1"] = { Id = defCfg.AmmoId, Count = math.min(initAmmo, MAX_AMMO_STACK) }
	end

	local maxHpAttr = inst:GetAttribute("MaxHealth")
	local maxHp = if typeof(maxHpAttr) == "number" and maxHpAttr > 0 then maxHpAttr else defCfg.BaseHp
	local hpAttr = inst:GetAttribute("Health")
	local hp = if typeof(hpAttr) == "number" and hpAttr > 0 then hpAttr else maxHp

	local mountAttr = inst:GetAttribute("MountSurface")
	local mountSurface: Types.DefenseMountSurface? = if mountAttr == "Floor"
			or mountAttr == "Wall"
			or mountAttr == "Ceiling"
		then mountAttr :: Types.DefenseMountSurface
		else nil

	local baseCF = inst:GetPivot()
	local dummyPiece: SavedBuildPiece = {
		Uid = uid,
		PieceType = canonical,
		Tier = "wood",
		PosX = baseCF.Position.X,
		PosY = baseCF.Position.Y,
		PosZ = baseCF.Position.Z,
		RotY = BuildingGeometry.ExtractYawDegrees(baseCF),
		MountSurface = mountSurface,
		Hp = hp,
		Storage = storage,
	}

	DefenseService.RegisterDefense({
		Uid = uid,
		PieceType = canonical,
		Model = inst,
		BaseWorldCF = baseCF,
		OwnerUserId = 0,
		IsRaidInstance = false,
		IsQaTest = true,
		PieceRef = dummyPiece,
		Hp = hp,
		MaxHp = maxHp,
		OnSelfDamage = function(defUid: string, dmg: number)
			local rec = defensesByUid[defUid]
			if rec == nil then
				return
			end
			rec.Hp -= dmg
			rec.Model:SetAttribute("Health", math.max(0, rec.Hp))
			rec.Model:SetAttribute("Hp", math.max(0, rec.Hp))
			if rec.Hp <= 0 then
				DefenseService.UnregisterDefense(defUid)
				if rec.Model.Parent ~= nil then
					rec.Model:Destroy()
				end
			end
		end,
		OnSelfDestroy = function(defUid: string)
			local rec = defensesByUid[defUid]
			DefenseService.UnregisterDefense(defUid)
			if rec ~= nil and rec.Model.Parent ~= nil then
				rec.Model:Destroy()
			end
		end,
	})
end

local function scanQaTestArena()
	local qaFolder = Workspace:FindFirstChild("QA_TestArena")
	if qaFolder == nil then
		return
	end
	for _, desc in qaFolder:GetDescendants() do
		tryRegisterQaModel(desc)
	end
	qaFolder.DescendantAdded:Connect(function(desc: Instance)
		task.defer(tryRegisterQaModel, desc)
	end)
end

function DefenseService.BindRaidHooks(hooks: RaidHookBindings)
	raidHooks = hooks
end

function DefenseService.RegisterDefense(options: RegisterDefenseOptions)
	local canonical = BuildingGeometry.CanonicalPieceType(options.PieceType)
	local defCfg = Defenses.Get(canonical)
	if defCfg == nil then
		return
	end

	DefenseService.UnregisterDefense(options.Uid)

	local storage: { [string]: Slot }
	if options.PieceRef ~= nil then
		options.PieceRef.Storage = options.PieceRef.Storage or {}
		storage = options.PieceRef.Storage :: { [string]: Slot }
	else
		storage = {}
	end

	local record: ActiveDefenseRecord = {
		Uid = options.Uid,
		PieceType = canonical,
		Config = defCfg,
		Model = options.Model,
		BaseWorldCF = options.BaseWorldCF or options.Model:GetPivot(),
		OwnerUserId = options.OwnerUserId,
		OwnerPlayer = options.OwnerPlayer,
		IsRaidInstance = options.IsRaidInstance == true,
		IsQaTest = options.IsQaTest == true,
		PieceRef = options.PieceRef,
		Storage = storage,
		Hp = options.Hp or defCfg.BaseHp,
		MaxHp = options.MaxHp or defCfg.BaseHp,
		LastFireTime = 0,
		Triggered = false,
		LockTarget = nil,
		LockStartTime = 0,
		LastLockEffectTime = 0,
		BurstRemaining = 0,
		NextBurstShotTime = 0,
		Prompt = nil,
		PromptConn = nil,
		OnSelfDamage = options.OnSelfDamage,
		OnSelfDestroy = options.OnSelfDestroy,
		OnStorageChanged = options.OnStorageChanged,
	}

	defensesByUid[options.Uid] = record
	attachAmmoPrompt(record)
end

function DefenseService.UnregisterDefense(uid: string)
	local record = defensesByUid[uid]
	if record == nil then
		return
	end
	defensesByUid[uid] = nil

	if record.PromptConn ~= nil then
		record.PromptConn:Disconnect()
		record.PromptConn = nil
	end
	if record.Prompt ~= nil then
		record.Prompt:Destroy()
		record.Prompt = nil
	end

	for plr, openUid in openDefenseByPlayer do
		if openUid == uid then
			closeDefenseUiForPlayer(plr)
		end
	end
end

function DefenseService.UpdateDefenseHp(uid: string, hp: number, maxHp: number?)
	local record = defensesByUid[uid]
	if record == nil then
		return
	end
	record.Hp = hp
	if maxHp ~= nil and maxHp > 0 then
		record.MaxHp = maxHp
	end
	syncDefenseUiForOwner(record)
end

function DefenseService.GetActiveCount(): number
	local count = 0
	for _ in defensesByUid do
		count += 1
	end
	return count
end

function DefenseService.Init()
	if isInitialized then
		return
	end
	isInitialized = true

	Net.InitServer()

	Net.GetEvent(Net.Events.DefenseAction).OnServerEvent:Connect(onDefenseAction)

	Players.PlayerRemoving:Connect(function(player: Player)
		openDefenseByPlayer[player] = nil
	end)

	scanQaTestArena()
	Workspace.ChildAdded:Connect(function(child: Instance)
		if child.Name == "QA_TestArena" then
			task.defer(scanQaTestArena)
		end
	end)

	RunService.Heartbeat:Connect(onHeartbeat)
end

return DefenseService
