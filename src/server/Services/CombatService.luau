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
			return result
		end

		if result.Instance.CanCollide == false then
			table.insert(excludeList, result.Instance)
			params.FilterDescendantsInstances = excludeList
		else
			return result
		end
	end

	return nil
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

local function validateProjectileOrigin(character: Model, hrp: BasePart, requestedOrigin: Vector3): Vector3
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
	projectileConfigId: string,
	requestedOrigin: Vector3,
	unitDir: Vector3
)
	local projCfg = Projectiles[projectileConfigId]
	if projCfg == nil then
		if activeProjectilesByPlayer[player] ~= nil then
			activeProjectilesByPlayer[player] = math.max(0, activeProjectilesByPlayer[player] - 1)
		end
		return
	end

	local safeOrigin = validateProjectileOrigin(character, hrp, requestedOrigin)
	local initialVelocity = unitDir * projCfg.Speed
	local maxLifetime = math.min(projCfg.MaxLifetime, Types.MAX_PROJECTILE_LIFETIME)

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
		ExcludeInstances = { character },
		OnHit = function(hitResult: RaycastResult)
			releaseActiveSlot()
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
	_isHeadshotHintAny: any
)
	if not SecurityService.CheckRateLimit(player, Net.Events.AttackRequest) then
		return
	end
	if not SecurityService.IsValidVector3(originAny) or not SecurityService.IsValidVector3(directionAny) then
		return
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
		if prevAttack ~= nil and (now - prevAttack) < weapon.Cooldown then
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

	local unitDir = direction.Unit
	if weapon.ProjectileId ~= nil then
		launchServerProjectile(player, character, hrp, weapon.ProjectileId, origin, unitDir)
		return
	end

	local hitResult = performServerRaycast(origin, unitDir, weapon.Range, character)

	local didHit = false
	local isHeadshot = false
	local endPos = origin + unitDir * weapon.Range

	if hitResult ~= nil then
		endPos = hitResult.Position
		local targetModel, targetHumanoid = findTargetCharacter(hitResult.Instance)
		if targetModel ~= nil and targetHumanoid ~= nil and targetModel ~= character and targetHumanoid.Health > 0 then
			didHit = true
			isHeadshot = hitResult.Instance.Name == "Head"
			local multiplier = if isHeadshot then weapon.HeadshotMultiplier else 1.0
			local finalDamage = weapon.Damage * multiplier
			targetModel:SetAttribute("LastAttackerUserId", player.UserId)
			targetHumanoid:TakeDamage(finalDamage)
		else
			local buildUid = findBuildPieceUid(hitResult.Instance)
			if buildUid ~= nil then
				local damageKind: BaseService.DamageKind = if weapon.Category == "Melee" then "Tool" else "Bullet"
				local hitPiece = BaseService.DamagePiece(buildUid, weapon.Damage, damageKind, player)
				if hitPiece then
					didHit = true
				end
			end
		end
	end

	broadcastAttackEffect(player, weaponId, weapon.Category, origin, endPos, didHit, isHeadshot)
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
