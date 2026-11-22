--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Types = require(ReplicatedStorage.Shared.Types)
local Weapons = require(ReplicatedStorage.Shared.configs.Weapons)
local Projectiles = require(ReplicatedStorage.Shared.configs.Projectiles)
local Ballistics = require(ReplicatedStorage.Shared.Ballistics)
local Net = require(ReplicatedStorage.Shared.Net)
local BaseService = require(ServerScriptService.Server.Services.BaseService)
local DataService = require(ServerScriptService.Server.Services.DataService)
local InventoryService = require(ServerScriptService.Server.Services.InventoryService)
local RaidService = require(ServerScriptService.Server.Services.RaidService)
local SecurityService = require(ServerScriptService.Server.Services.SecurityService)

type WeaponConfig = Types.WeaponConfig

local MAX_RAY_FILTER_PASSES = 8
local ATTACK_EFFECT_BROADCAST_RADIUS = 250
local PROJECTILE_BROADCAST_RADIUS = 400
local LIMB_DAMAGE_MULTIPLIER = 0.75
local DEFAULT_MELEE_CONE_HALF_ANGLE_DEG = 42

local lastAttackTime: { [Player]: number } = {}
local activeProjectilesByPlayer: { [Player]: number } = {}
local nextProjectileSeq = 0
local boundDummies: { [Model]: boolean } = {}
local cachedLootFolder: Instance? = nil
local isInitialized = false

local CombatService = {}

local function getWeaponForPlayer(player: Player): (string, WeaponConfig)
	local equipped = InventoryService.GetEquippedItem(player)
	if equipped ~= nil and equipped.Id ~= "FISTS" then
		local cfg = Weapons[equipped.Id]
		if cfg ~= nil then
			return equipped.Id, cfg
		end
	end
	return "fists", Weapons.FISTS
end

local function findTargetCharacter(inst: Instance): (Model?, Humanoid?)
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

local function findBuildPieceUid(inst: Instance): string?
	local folder = Workspace:FindFirstChild("PlayerBaseStructures")
	if folder == nil or not inst:IsDescendantOf(folder) then
		return nil
	end
	local current: Instance? = inst
	while current ~= nil and current.Parent ~= folder do
		current = current.Parent
	end
	if current ~= nil and current:IsA("Model") then
		local uid = current:GetAttribute("BuildUid")
		if typeof(uid) == "string" and #uid > 0 then
			return uid
		end
	end
	return nil
end

local function findRaidPieceUid(inst: Instance): string?
	local folder = Workspace:FindFirstChild("RaidTargetStructures")
	if folder == nil or not inst:IsDescendantOf(folder) then
		return nil
	end
	local current: Instance? = inst
	while current ~= nil and current.Parent ~= folder do
		current = current.Parent
	end
	if current ~= nil and current:IsA("Model") then
		local uid = current:GetAttribute("RaidPieceUid")
		if typeof(uid) == "string" and #uid > 0 then
			return uid
		end
	end
	return nil
end

local function resolveDamageMultiplier(
	weapon: WeaponConfig,
	hitPart: BasePart,
	overrideHeadMult: number?
): (number, boolean)
	local zone = Ballistics.ClassifyHitZone(hitPart)
	if zone == "Head" then
		return (overrideHeadMult or weapon.HeadshotMultiplier), true
	elseif zone == "Limb" then
		return LIMB_DAMAGE_MULTIPLIER, false
	end
	return 1.0, false
end

local function performServerRaycast(
	origin: Vector3,
	unitDir: Vector3,
	range: number,
	attackerCharacter: Model
): RaycastResult?
	local excludeList: { Instance } = { attackerCharacter }
	if cachedLootFolder == nil or cachedLootFolder.Parent == nil then
		cachedLootFolder = Workspace:FindFirstChild("LootContainers")
	end
	if cachedLootFolder ~= nil then
		table.insert(excludeList, cachedLootFolder)
	end

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.IgnoreWater = true
	params.FilterDescendantsInstances = excludeList

	for _ = 1, MAX_RAY_FILTER_PASSES do
		local result = Workspace:Raycast(origin, unitDir * range, params)
		if result == nil then
			return nil
		end

		local targetModel = findTargetCharacter(result.Instance)
		if targetModel ~= nil then
			if Ballistics.IsIgnoredCharacterPart(result.Instance) then
				table.insert(excludeList, result.Instance)
				params.FilterDescendantsInstances = excludeList
			else
				return result
			end
		elseif result.Instance.CanCollide == false then
			table.insert(excludeList, result.Instance)
			params.FilterDescendantsInstances = excludeList
		else
			return result
		end
	end

	return nil
end

local function collectMeleeCandidateModels(attackerCharacter: Model): { Model }
	local list: { Model } = {}
	local seen: { [Model]: boolean } = {}

	local function tryAdd(inst: Instance?)
		if inst == nil or not inst:IsA("Model") or inst == attackerCharacter or seen[inst] then
			return
		end
		local hum = inst:FindFirstChildOfClass("Humanoid")
		if hum ~= nil and hum.Health > 0 then
			seen[inst] = true
			table.insert(list, inst)
		end
	end

	for _, plr in Players:GetPlayers() do
		tryAdd(plr.Character)
	end

	local folderNames = { "ActiveNPCs", "TestDummies" }
	for _, folderName in folderNames do
		local folder = Workspace:FindFirstChild(folderName)
		if folder ~= nil then
			for _, child in folder:GetChildren() do
				tryAdd(child)
			end
		end
	end

	local qaArena = Workspace:FindFirstChild("QA_TestArena")
	local sector5 = if qaArena then qaArena:FindFirstChild("Sector5_CombatRange") else nil
	if sector5 ~= nil then
		for _, subName in { "BowRangeTargets", "CombatHitboxRange" } do
			local subFolder = sector5:FindFirstChild(subName)
			if subFolder ~= nil then
				for _, child in subFolder:GetChildren() do
					tryAdd(child)
				end
			end
		end
	end

	return list
end

local function hasClearLineToTarget(
	origin: Vector3,
	targetPoint: Vector3,
	maxRange: number,
	attackerCharacter: Model,
	targetModel: Model
): RaycastResult?
	local delta = targetPoint - origin
	local dist = delta.Magnitude
	if dist <= 0.01 or dist > maxRange then
		return nil
	end

	local unitDir = delta / dist
	local hit = performServerRaycast(origin, unitDir, math.min(maxRange, dist + 0.5), attackerCharacter)
	if hit == nil then
		return nil
	end
	if hit.Instance:IsDescendantOf(targetModel) and (hit.Position - origin).Magnitude <= maxRange then
		return hit
	end
	return nil
end

local function performServerMeleeSweep(
	origin: Vector3,
	unitDir: Vector3,
	range: number,
	coneHalfAngleDeg: number,
	attackerCharacter: Model
): RaycastResult?
	local directHit = performServerRaycast(origin, unitDir, range, attackerCharacter)
	if directHit ~= nil then
		local directModel, directHum = findTargetCharacter(directHit.Instance)
		if directModel ~= nil and directHum ~= nil and directModel ~= attackerCharacter and directHum.Health > 0 then
			return directHit
		end
	end

	local maxAllowedRange = range + Types.PING_DISTANCE_TOLERANCE
	local bestHit: RaycastResult? = nil
	local bestAngle = coneHalfAngleDeg + 0.01
	local bestDist = maxAllowedRange + 0.01

	local probeNames = { "Head", "UpperTorso", "Torso", "HumanoidRootPart", "LowerTorso", "Body" }
	for _, candidate in collectMeleeCandidateModels(attackerCharacter) do
		local root = candidate:FindFirstChild("HumanoidRootPart") or candidate.PrimaryPart
		if root ~= nil and root:IsA("BasePart") then
			local broadDist = (root.Position - origin).Magnitude
			if broadDist <= maxAllowedRange + 3.0 then
				for _, partName in probeNames do
					local part = candidate:FindFirstChild(partName)
					if part ~= nil and part:IsA("BasePart") then
						local toPart = part.Position - origin
						local partDist = toPart.Magnitude
						if partDist > 0.05 and partDist <= maxAllowedRange + 2.0 then
							local angleDeg = math.deg(math.acos(math.clamp(unitDir:Dot(toPart / partDist), -1, 1)))
							if angleDeg <= coneHalfAngleDeg then
								local clearHit = hasClearLineToTarget(
									origin,
									part.Position,
									maxAllowedRange,
									attackerCharacter,
									candidate
								)
								if clearHit ~= nil then
									local hitDist = (clearHit.Position - origin).Magnitude
									if
										angleDeg < bestAngle - 0.5
										or (math.abs(angleDeg - bestAngle) <= 0.5 and hitDist < bestDist)
									then
										bestAngle = angleDeg
										bestDist = hitDist
										bestHit = clearHit
									end
									break
								end
							end
						end
					end
				end
			end
		end
	end

	return bestHit or directHit
end

local function broadcastAttackEffect(
	attacker: Player,
	weaponId: string,
	category: Types.WeaponCategory,
	origin: Vector3,
	endPos: Vector3,
	didHit: boolean,
	isHeadshot: boolean
)
	local effectEvent = Net.GetEvent(Net.Events.AttackEffect)
	if category == "Melee" then
		if didHit and attacker.Parent == Players then
			effectEvent:FireClient(attacker, attacker, weaponId, origin, endPos, didHit, isHeadshot)
		end
		return
	end

	for _, other in Players:GetPlayers() do
		if other == attacker then
			effectEvent:FireClient(other, attacker, weaponId, origin, endPos, didHit, isHeadshot)
			continue
		end
		local char = other.Character
		local hrp = if char then char:FindFirstChild("HumanoidRootPart") else nil
		if hrp and hrp:IsA("BasePart") then
			local pos = hrp.Position
			if
				(pos - origin).Magnitude <= ATTACK_EFFECT_BROADCAST_RADIUS
				or (pos - endPos).Magnitude <= ATTACK_EFFECT_BROADCAST_RADIUS
			then
				effectEvent:FireClient(other, attacker, weaponId, origin, endPos, didHit, isHeadshot)
			end
		end
	end
end

local function validateAttackOrigin(character: Model, hrp: BasePart, requestedOrigin: Vector3): Vector3
	local head = character:FindFirstChild("Head")
	local basePos = if head and head:IsA("BasePart") then head.Position else (hrp.Position + Vector3.new(0, 1.5, 0))
	local delta = requestedOrigin - basePos
	if delta.Magnitude <= 0.1 then
		return requestedOrigin
	end

	local excludeList: { Instance } = { character }
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.IgnoreWater = true
	params.FilterDescendantsInstances = excludeList

	for _ = 1, 4 do
		local result = Workspace:Raycast(basePos, delta, params)
		if result == nil then
			return requestedOrigin
		end
		if result.Instance.CanCollide == false and not result.Instance:IsA("Terrain") then
			table.insert(excludeList, result.Instance)
			params.FilterDescendantsInstances = excludeList
		else
			return basePos
		end
	end

	return basePos
end

local function broadcastProjectileSpawn(
	projectileId: string,
	shooter: Player,
	projectileConfigId: string,
	origin: Vector3,
	velocity: Vector3,
	gravity: number
)
	local spawnEvent = Net.GetEvent(Net.Events.ProjectileSpawn)
	for _, other in Players:GetPlayers() do
		if other == shooter then
			spawnEvent:FireClient(other, projectileId, shooter, projectileConfigId, origin, velocity, gravity)
			continue
		end
		local char = other.Character
		local hrp = if char then char:FindFirstChild("HumanoidRootPart") else nil
		if hrp and hrp:IsA("BasePart") and (hrp.Position - origin).Magnitude <= PROJECTILE_BROADCAST_RADIUS then
			spawnEvent:FireClient(other, projectileId, shooter, projectileConfigId, origin, velocity, gravity)
		end
	end
end

local function launchServerProjectile(
	player: Player,
	character: Model,
	hrp: BasePart,
	weaponId: string,
	weapon: WeaponConfig,
	projectileConfigId: string,
	requestedOrigin: Vector3,
	unitDir: Vector3,
	chargeRatio: number
)
	local projCfg = Projectiles[projectileConfigId]
	if projCfg == nil then
		if activeProjectilesByPlayer[player] ~= nil then
			activeProjectilesByPlayer[player] = math.max(0, activeProjectilesByPlayer[player] - 1)
		end
		return
	end

	local clampedCharge = math.clamp(chargeRatio, 0, 1)
	local speed = projCfg.Speed
	if projCfg.MinSpeed ~= nil and projCfg.MaxSpeed ~= nil then
		speed = projCfg.MinSpeed + (projCfg.MaxSpeed - projCfg.MinSpeed) * clampedCharge
	end

	local minDmg = weapon.MinDamage or projCfg.MinDamage or weapon.Damage
	local maxDmg = weapon.Damage
	local baseDamage = minDmg + (maxDmg - minDmg) * clampedCharge
	local headMult = weapon.HeadshotMultiplier or projCfg.HeadshotMultiplier or 1.5
	local isDirect = projCfg.ImpactKind == "Direct"

	local safeOrigin = validateAttackOrigin(character, hrp, requestedOrigin)
	local initialVelocity = unitDir * speed
	local maxLifetime = math.min(projCfg.MaxLifetime, Types.MAX_PROJECTILE_LIFETIME)
	local hitTargets: { [Model]: boolean } = {}

	local excludeInstances: { Instance } = { character }
	if isDirect then
		if cachedLootFolder == nil or cachedLootFolder.Parent == nil then
			cachedLootFolder = Workspace:FindFirstChild("LootContainers")
		end
		if cachedLootFolder ~= nil then
			table.insert(excludeInstances, cachedLootFolder)
		end
	end

	nextProjectileSeq += 1
	local projectileId = string.format("proj_%d_%d", player.UserId, nextProjectileSeq)

	local released = false
	local function releaseActiveSlot()
		if released then
			return
		end
		released = true
		if activeProjectilesByPlayer[player] ~= nil then
			activeProjectilesByPlayer[player] = math.max(0, activeProjectilesByPlayer[player] - 1)
		end
	end

	broadcastProjectileSpawn(projectileId, player, projectileConfigId, safeOrigin, initialVelocity, projCfg.Gravity)

	Ballistics.Spawn({
		Id = projectileId,
		Origin = safeOrigin,
		InitialVelocity = initialVelocity,
		Gravity = projCfg.Gravity,
		MaxLifetime = maxLifetime,
		ExcludeInstances = excludeInstances,
		OnHit = function(hitResult: RaycastResult)
			releaseActiveSlot()
			if isDirect then
				local didHit = false
				local isHeadshot = false
				local targetModel, targetHumanoid = findTargetCharacter(hitResult.Instance)
				if
					targetModel ~= nil
					and targetHumanoid ~= nil
					and targetModel ~= character
					and targetHumanoid.Health > 0
					and not hitTargets[targetModel]
				then
					hitTargets[targetModel] = true
					didHit = true
					local multiplier, headshot = resolveDamageMultiplier(weapon, hitResult.Instance, headMult)
					isHeadshot = headshot
					local finalDamage = math.max(1, math.floor(baseDamage * multiplier + 0.5))
					targetModel:SetAttribute("LastAttackerUserId", player.UserId)
					targetHumanoid:TakeDamage(finalDamage)
					local targetPlayer = Players:GetPlayerFromCharacter(targetModel)
					if targetPlayer ~= nil then
						RaidService.NotifyRaiderDamaged(targetPlayer)
					end
				else
					local structDmg = projCfg.StructureDamage or weapon.Damage
					local buildUid = findBuildPieceUid(hitResult.Instance)
					if buildUid ~= nil then
						local hitPiece = BaseService.DamagePiece(buildUid, structDmg, "Bullet", player)
						if hitPiece then
							didHit = true
						end
					else
						local raidUid = findRaidPieceUid(hitResult.Instance)
						if raidUid ~= nil then
							local hitRaidPiece = RaidService.DamageRaidPiece(raidUid, structDmg, "Bullet", player)
							if hitRaidPiece then
								didHit = true
							end
						end
					end
				end

				if didHit and player.Parent == Players then
					Net.GetEvent(Net.Events.AttackEffect)
						:FireClient(player, player, weaponId, safeOrigin, hitResult.Position, true, isHeadshot)
				end
				return
			end

			local blastOrigin = hitResult.Position + hitResult.Normal * 0.25
			RaidService.TriggerExplosion({
				Origin = blastOrigin,
				Radius = projCfg.BlastRadius,
				StructureDamage = projCfg.StructureDamage,
				PlayerDamage = projCfg.PlayerDamage,
				Attacker = player,
				SourceId = projectileConfigId,
				ProjectileId = projectileId,
				MinFalloffMultiplier = projCfg.MinFalloffMultiplier,
			})
		end,
		OnExpire = function()
			releaseActiveSlot()
		end,
	})
end

local function bindDummyHpDisplay(model: Model)
	if boundDummies[model] then
		return
	end

	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end

	boundDummies[model] = true

	local function updateLabel()
		local head = model:FindFirstChild("Head")
		local billboard = if head then head:FindFirstChild("HpBillboard") else nil
		local label = if billboard then billboard:FindFirstChild("HpLabel", true) else nil
		if label and label:IsA("TextLabel") then
			local currentHp = math.max(0, math.ceil(humanoid.Health))
			local maxHp = math.ceil(humanoid.MaxHealth)
			label.Text = string.format("%s: %d / %d", model.Name, currentHp, maxHp)
		end
	end

	local healthConn = humanoid.HealthChanged:Connect(function()
		updateLabel()
	end)

	local ancestryConn: RBXScriptConnection
	ancestryConn = model.AncestryChanged:Connect(function(_, parent)
		if parent == nil then
			boundDummies[model] = nil
			healthConn:Disconnect()
			ancestryConn:Disconnect()
		end
	end)

	updateLabel()
end

local function bindDummiesFolder(folder: Instance)
	for _, child in folder:GetChildren() do
		if child:IsA("Model") then
			bindDummyHpDisplay(child)
		end
	end

	folder.ChildAdded:Connect(function(child: Instance)
		if child:IsA("Model") then
			task.defer(bindDummyHpDisplay, child)
		end
	end)
end

local function onAttackRequest(
	player: Player,
	originAny: any,
	directionAny: any,
	_targetModelAny: any,
	_isHeadshotHintAny: any,
	chargeRatioAny: any
)
	if not SecurityService.CheckRateLimit(player, Net.Events.AttackRequest) then
		return
	end
	if not SecurityService.IsValidVector3(originAny) or not SecurityService.IsValidVector3(directionAny) then
		return
	end

	local chargeRatio = 1.0
	if chargeRatioAny ~= nil then
		if
			not SecurityService.IsFiniteNumber(chargeRatioAny)
			or (chargeRatioAny :: number) < 0
			or (chargeRatioAny :: number) > 1
		then
			return
		end
		chargeRatio = chargeRatioAny :: number
	end

	local origin = originAny :: Vector3
	local direction = directionAny :: Vector3
	if not SecurityService.IsFiniteNumber(direction.Magnitude) or direction.Magnitude <= 0.01 then
		return
	end

	if DataService.IsTeleporting(player) or SecurityService.IsTransactionLocked(player) then
		return
	end
	if DataService.GetData(player) == nil then
		return
	end

	local character, hrp = SecurityService.GetAliveCharacterRoot(player)
	if not character or not hrp then
		return
	end

	if (origin - hrp.Position).Magnitude > Types.MAX_ATTACK_ORIGIN_OFFSET then
		return
	end

	local canAttack = false
	local weaponId = "fists"
	local weapon = Weapons.FISTS

	SecurityService.RunLocked(player, "AttackAmmo", function()
		if DataService.GetData(player) == nil then
			return
		end
		weaponId, weapon = getWeaponForPlayer(player)

		local now = os.clock()
		local prevAttack = lastAttackTime[player]
		local cooldownRequired = if weapon.DrawMinTime ~= nil
			then math.max(weapon.DrawMinTime, weapon.Cooldown)
			else weapon.Cooldown
		if prevAttack ~= nil and (now - prevAttack) < cooldownRequired then
			if (now - prevAttack) < cooldownRequired * 0.5 then
				SecurityService.LogSuspicious(player, Net.Events.AttackRequest, "RapidFire")
			end
			return
		end

		if weapon.ProjectileId ~= nil then
			if Projectiles[weapon.ProjectileId] == nil then
				return
			end
			if (activeProjectilesByPlayer[player] or 0) >= Types.MAX_ACTIVE_PROJECTILES_PER_PLAYER then
				return
			end
		end

		if weapon.AmmoId ~= nil then
			if not InventoryService.RemoveItem(player, weapon.AmmoId, 1) then
				return
			end
		end

		if weapon.ProjectileId ~= nil then
			activeProjectilesByPlayer[player] = (activeProjectilesByPlayer[player] or 0) + 1
		end

		lastAttackTime[player] = now
		canAttack = true
	end)

	if not canAttack then
		return
	end

	local safeOrigin = validateAttackOrigin(character, hrp, origin)
	local unitDir = direction.Unit
	if weapon.ProjectileId ~= nil then
		launchServerProjectile(
			player,
			character,
			hrp,
			weaponId,
			weapon,
			weapon.ProjectileId,
			safeOrigin,
			unitDir,
			chargeRatio
		)
		return
	end

	local hitResult: RaycastResult?
	if weapon.Category == "Melee" then
		local coneHalf = weapon.MeleeConeHalfAngleDeg or DEFAULT_MELEE_CONE_HALF_ANGLE_DEG
		hitResult = performServerMeleeSweep(safeOrigin, unitDir, weapon.Range, coneHalf, character)
	else
		hitResult = performServerRaycast(safeOrigin, unitDir, weapon.Range, character)
	end

	local didHit = false
	local isHeadshot = false
	local endPos = safeOrigin + unitDir * weapon.Range
	local hitTargets: { [Model]: boolean } = {}

	if hitResult ~= nil then
		endPos = hitResult.Position
		if (endPos - safeOrigin).Magnitude <= (weapon.Range + Types.PING_DISTANCE_TOLERANCE) then
			local targetModel, targetHumanoid = findTargetCharacter(hitResult.Instance)
			if
				targetModel ~= nil
				and targetHumanoid ~= nil
				and targetModel ~= character
				and targetHumanoid.Health > 0
				and not hitTargets[targetModel]
			then
				hitTargets[targetModel] = true
				didHit = true
				local multiplier, headshot = resolveDamageMultiplier(weapon, hitResult.Instance, nil)
				isHeadshot = headshot
				local finalDamage = math.max(1, math.floor(weapon.Damage * multiplier + 0.5))
				targetModel:SetAttribute("LastAttackerUserId", player.UserId)
				targetHumanoid:TakeDamage(finalDamage)
				local targetPlayer = Players:GetPlayerFromCharacter(targetModel)
				if targetPlayer ~= nil then
					RaidService.NotifyRaiderDamaged(targetPlayer)
				end
			else
				local buildUid = findBuildPieceUid(hitResult.Instance)
				if buildUid ~= nil then
					local damageKind: BaseService.DamageKind = if weapon.Category == "Melee" then "Tool" else "Bullet"
					local hitPiece = BaseService.DamagePiece(buildUid, weapon.Damage, damageKind, player)
					if hitPiece then
						didHit = true
					end
				else
					local raidUid = findRaidPieceUid(hitResult.Instance)
					if raidUid ~= nil then
						local damageKind: BaseService.DamageKind = if weapon.Category == "Melee"
							then "Tool"
							else "Bullet"
						local hitRaidPiece = RaidService.DamageRaidPiece(raidUid, weapon.Damage, damageKind, player)
						if hitRaidPiece then
							didHit = true
						end
					end
				end
			end
		end
	end

	broadcastAttackEffect(player, weaponId, weapon.Category, safeOrigin, endPos, didHit, isHeadshot)
end

function CombatService.GetEquippedWeapon(player: Player): (string, WeaponConfig)
	return getWeaponForPlayer(player)
end

function CombatService.Init()
	if isInitialized then
		return
	end
	isInitialized = true

	Net.InitServer()

	Net.GetEvent(Net.Events.AttackRequest).OnServerEvent:Connect(onAttackRequest)

	Players.PlayerRemoving:Connect(function(player: Player)
		lastAttackTime[player] = nil
		activeProjectilesByPlayer[player] = nil
	end)

	local dummiesFolder = Workspace:FindFirstChild("TestDummies")
	if dummiesFolder then
		bindDummiesFolder(dummiesFolder)
	else
		Workspace.ChildAdded:Connect(function(child: Instance)
			if child.Name == "TestDummies" then
				bindDummiesFolder(child)
			end
		end)
	end
end

return CombatService
