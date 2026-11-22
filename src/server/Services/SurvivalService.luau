--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)
local Types = require(ReplicatedStorage.Shared.Types)
local Items = require(ReplicatedStorage.Shared.configs.Items)
local Consumables = require(ReplicatedStorage.Shared.configs.Consumables)
local Net = require(ReplicatedStorage.Shared.Net)
local Janitor = require(ReplicatedStorage.Shared.Janitor)
local BaseService = require(ServerScriptService.Server.Services.BaseService)
local DataService = require(ServerScriptService.Server.Services.DataService)
local InventoryService = require(ServerScriptService.Server.Services.InventoryService)
local LootService = require(ServerScriptService.Server.Services.LootService)
local CraftingService = require(ServerScriptService.Server.Services.CraftingService)
local SecurityService = require(ServerScriptService.Server.Services.SecurityService)

type Inventory = Types.Inventory
type SurvivalStats = Types.SurvivalStats
type LootContainerState = Types.LootContainerState
type PlayerData = Types.PlayerData

type BleedState = {
	ExpiresAt: number,
	Dps: number,
}

type StaminaState = {
	Stamina: number,
	WantsSprint: boolean,
	IsSprinting: boolean,
	Exhausted: boolean,
	LastSyncAt: number,
	LastSyncedStamina: number,
}

local HUNGER_LOSS_PER_TICK = 0.35
local THIRST_LOSS_PER_TICK = 0.5
local DAMAGE_EPSILON = 0.01
local MOVE_DIRECTION_THRESHOLD = 0.1
local STAMINA_SYNC_INTERVAL = 0.1
local STAMINA_SYNC_DELTA = 0.5
local MAX_HEARTBEAT_DT = 0.25

local playerJanitors: { [Player]: Janitor.Janitor } = {}
local characterJanitors: { [Player]: Janitor.Janitor } = {}
local appliedCharacters: { [Model]: boolean } = {}
local activeBleeds: { [Player]: BleedState } = {}
local nextConsumeTime: { [Player]: number } = {}
local pendingRespawnReset: { [Player]: boolean } = {}
local staminaStates: { [Player]: StaminaState } = {}
local lastDamageAt: { [Player]: number } = {}
local hpRegenAccum: { [Player]: number } = {}
local nextBagId = 0
local isInitialized = false

local SurvivalService = {}

local function roundStat(val: number): number
	return math.floor(val * 100 + 0.5) / 100
end

local function hasAnySlots(inv: Inventory): boolean
	for i = 1, Types.INVENTORY_SIZE do
		local slot = inv[i]
		if slot ~= nil and slot.Count > 0 then
			return true
		end
	end
	return false
end

local function getOrCreateLootFolder(): Folder
	local existing = Workspace:FindFirstChild("LootContainers")
	if existing and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = "LootContainers"
	folder.Parent = Workspace
	return folder
end

local function isWellFed(stats: SurvivalStats): boolean
	local endTime = stats.WellFedEndTime or 0
	return endTime > os.time()
end

local function getPlayerMaxStamina(player: Player): number
	local data = DataService.GetData(player)
	if data ~= nil and isWellFed(data.Stats) then
		local mult = data.Stats.WellFedStaminaMult or 1.0
		return math.floor(Config.MAX_STAMINA * math.max(1.0, mult) + 0.5)
	end
	return Config.MAX_STAMINA
end

local function isHungerDrainFrozen(player: Player): boolean
	return BaseService.IsBaseMode() and player:GetAttribute("InRaid") ~= true
end

local function setAttributeIfChanged(player: Player, name: string, value: any)
	if player:GetAttribute(name) ~= value then
		player:SetAttribute(name, value)
	end
end

local function syncPlayerAttributes(player: Player, stats: SurvivalStats)
	local endTime = stats.WellFedEndTime or 0
	local nowUnix = os.time()
	local wellFedActive = endTime > nowUnix
	local remaining = if wellFedActive then (endTime - nowUnix) else 0
	if not wellFedActive and (stats.WellFedStaminaMult or 1.0) > 1.0 then
		stats.WellFedStaminaMult = 1.0
	end
	setAttributeIfChanged(player, "Hunger", roundStat(stats.Hunger))
	setAttributeIfChanged(player, "Thirst", roundStat(stats.Thirst))
	setAttributeIfChanged(player, "Starving", stats.Hunger <= 0)
	setAttributeIfChanged(player, "Dehydrated", stats.Thirst <= 0)
	setAttributeIfChanged(player, "WellFed", wellFedActive)
	setAttributeIfChanged(player, "WellFedRemaining", remaining)
	setAttributeIfChanged(player, "MaxStamina", getPlayerMaxStamina(player))
end

local function getOrCreateStaminaState(player: Player): StaminaState
	local existing = staminaStates[player]
	if existing ~= nil then
		return existing
	end
	local created: StaminaState = {
		Stamina = Config.MAX_STAMINA,
		WantsSprint = false,
		IsSprinting = false,
		Exhausted = false,
		LastSyncAt = 0,
		LastSyncedStamina = -1,
	}
	staminaStates[player] = created
	return created
end

local function syncStaminaAttributes(player: Player, state: StaminaState, force: boolean)
	if player.Parent ~= Players then
		return
	end
	local maxStamina = getPlayerMaxStamina(player)
	setAttributeIfChanged(player, "IsSprinting", state.IsSprinting)
	setAttributeIfChanged(player, "StaminaExhausted", state.Exhausted)
	setAttributeIfChanged(player, "MaxStamina", maxStamina)

	local now = os.clock()
	local rounded = math.floor(state.Stamina * 10 + 0.5) / 10
	local shouldSyncStamina = force
		or state.Stamina <= 0
		or state.Stamina >= maxStamina
		or math.abs(rounded - state.LastSyncedStamina) >= STAMINA_SYNC_DELTA
		or (now - state.LastSyncAt) >= STAMINA_SYNC_INTERVAL

	if shouldSyncStamina then
		setAttributeIfChanged(player, "Stamina", rounded)
		state.LastSyncAt = now
		state.LastSyncedStamina = rounded
	end
end

local function applyCharacterWalkSpeed(humanoid: Humanoid, isSprinting: boolean)
	local baseSpeed = if isSprinting then Config.SPRINT_WALK_SPEED else Config.BASE_WALK_SPEED
	local slowAttr = humanoid:GetAttribute("SlowMultiplier")
	local targetSpeed = if typeof(slowAttr) == "number"
			and slowAttr > 0
			and slowAttr < 1
		then math.max(2, baseSpeed * slowAttr)
		else baseSpeed
	if math.abs(humanoid.WalkSpeed - targetSpeed) > 0.01 then
		humanoid.WalkSpeed = targetSpeed
	end
end

local function getAliveCharacterParts(player: Player): (Model?, BasePart?, Humanoid?)
	return SecurityService.GetAliveCharacterRoot(player)
end

local function findDropPosition(deathPosition: Vector3, ignoreCharacter: Model?, lootFolder: Folder): Vector3
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local excludeList: { Instance } = { lootFolder }
	if ignoreCharacter then
		table.insert(excludeList, ignoreCharacter)
	end
	params.FilterDescendantsInstances = excludeList

	local origin = deathPosition + Vector3.new(0, 2, 0)
	local result = Workspace:Raycast(origin, Vector3.new(0, -50, 0), params)
	if result then
		return result.Position + Vector3.new(0, 0.7, 0)
	end
	return deathPosition + Vector3.new(0, 0.7, 0)
end

local function spawnLootContainer(ownerName: string, deathPosition: Vector3, slots: Inventory, ignoreCharacter: Model?)
	if not hasAnySlots(slots) then
		return
	end

	local lootFolder = getOrCreateLootFolder()
	nextBagId += 1
	local bagPos = findDropPosition(deathPosition, ignoreCharacter, lootFolder)
	local title = string.format("%s's Backpack", ownerName)

	local model = Instance.new("Model")
	model.Name = string.format("LootBag_%d", nextBagId)

	local body = Instance.new("Part")
	body.Name = "BagBody"
	body.Size = Vector3.new(2.2, 1.4, 1.6)
	body.CFrame = CFrame.new(bagPos)
	body.Anchored = true
	body.CanCollide = false
	body.Color = Color3.fromRGB(115, 82, 52)
	body.Material = Enum.Material.Fabric
	body.Parent = model

	local flap = Instance.new("Part")
	flap.Name = "BagFlap"
	flap.Size = Vector3.new(2.25, 0.35, 1.4)
	flap.CFrame = CFrame.new(bagPos + Vector3.new(0, 0.7, 0))
	flap.Anchored = true
	flap.CanCollide = false
	flap.Color = Color3.fromRGB(88, 60, 38)
	flap.Material = Enum.Material.Fabric
	flap.Parent = model

	local strap = Instance.new("Part")
	strap.Name = "BagStrap"
	strap.Size = Vector3.new(0.45, 0.5, 0.2)
	strap.CFrame = CFrame.new(bagPos + Vector3.new(0, 0.35, 0.78))
	strap.Anchored = true
	strap.CanCollide = false
	strap.Color = Color3.fromRGB(205, 175, 95)
	strap.Material = Enum.Material.Metal
	strap.Parent = model

	model.PrimaryPart = body

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "LootPrompt"
	prompt.ActionText = "Loot Body"
	prompt.ObjectText = title
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 12
	prompt.RequiresLineOfSight = false
	prompt.Parent = body

	model.Parent = lootFolder
	LootService.RegisterSlotsContainer(model, title, ownerName, slots, Types.LOOT_CONTAINER_LIFETIME)
end

local function applyStatsToCharacter(player: Player, character: Model, data: PlayerData)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end

	local defaultHealthScript = character:FindFirstChild("Health")
	if defaultHealthScript then
		defaultHealthScript:Destroy()
	end

	humanoid.MaxHealth = Types.MAX_HEALTH

	if pendingRespawnReset[player] or data.Stats.Health <= 0 then
		pendingRespawnReset[player] = false
		data.Stats.Health = Types.RESPAWN_HEALTH
		data.Stats.Hunger = Types.RESPAWN_HUNGER
		data.Stats.Thirst = Types.RESPAWN_THIRST
		if player:GetAttribute("InSelfRaid") ~= true then
			data.Stats.WellFedEndTime = 0
			data.Stats.WellFedStaminaMult = 1.0
		end
		lastDamageAt[player] = 0
		SurvivalService.ClearBleeding(player)
	end

	humanoid.Health = math.clamp(data.Stats.Health, 1, humanoid.MaxHealth)
	data.Stats.Health = humanoid.Health
	appliedCharacters[character] = true
	hpRegenAccum[player] = 0
	SurvivalService.ResetSprintState(player, true)
	syncPlayerAttributes(player, data.Stats)
end

local function bindCharacter(player: Player, character: Model)
	local existingCharJanitor = characterJanitors[player]
	if existingCharJanitor then
		existingCharJanitor:Cleanup()
	else
		existingCharJanitor = Janitor.new()
		characterJanitors[player] = existingCharJanitor
	end

	local charJanitor = existingCharJanitor :: Janitor.Janitor
	charJanitor:Add(function()
		appliedCharacters[character] = nil
	end)

	local humanoidInstance = character:FindFirstChildOfClass("Humanoid")
	if not humanoidInstance then
		humanoidInstance = character:WaitForChild("Humanoid", 10)
	end
	if not humanoidInstance or not humanoidInstance:IsA("Humanoid") then
		return
	end
	if player.Character ~= character then
		return
	end

	local humanoid = humanoidInstance :: Humanoid
	local diedHandled = false

	local data = DataService.GetData(player)
	if data ~= nil then
		applyStatsToCharacter(player, character, data)
	else
		SurvivalService.ResetSprintState(player, true)
	end

	local lastHealth = humanoid.Health

	charJanitor:Add(humanoid.HealthChanged:Connect(function(newHealth: number)
		local prevHealth = lastHealth
		lastHealth = newHealth
		if not appliedCharacters[character] then
			return
		end
		if newHealth < prevHealth - DAMAGE_EPSILON then
			lastDamageAt[player] = os.clock()
			hpRegenAccum[player] = 0
		end
		local currentData = DataService.GetData(player)
		if currentData ~= nil then
			currentData.Stats.Health = math.clamp(newHealth, 0, humanoid.MaxHealth)
		end
	end))

	charJanitor:Add(humanoid.Died:Connect(function()
		if diedHandled then
			return
		end
		diedHandled = true
		appliedCharacters[character] = nil

		pendingRespawnReset[player] = true
		hpRegenAccum[player] = 0
		SurvivalService.ResetSprintState(player, false)
		SurvivalService.ClearBleeding(player)
		LootService.CloseContainerForPlayer(player, true)

		local currentData = DataService.GetData(player)
		if currentData ~= nil then
			currentData.Stats.Health = 0
		end

		local hrp = character:FindFirstChild("HumanoidRootPart")
		local deathPosition = if hrp and hrp:IsA("BasePart") then hrp.Position else character:GetPivot().Position

		if
			DataService.IsTeleporting(player)
			or SecurityService.IsTeleportLocked(player)
			or DataService.GetData(player) == nil
			or player:GetAttribute("InSelfRaid") == true
		then
			return
		end

		SecurityService.RunLocked(player, "PlayerDeath", function()
			CraftingService.CancelCraftForPlayer(player, true, true)
			local droppedSlots = InventoryService.ClearInventory(player)
			if hasAnySlots(droppedSlots) then
				spawnLootContainer(player.Name, deathPosition, droppedSlots, character)
			end
		end)
	end))
end

local function bindPlayer(player: Player)
	if playerJanitors[player] ~= nil then
		return
	end

	local janitor = Janitor.new()
	playerJanitors[player] = janitor

	syncStaminaAttributes(player, getOrCreateStaminaState(player), true)

	janitor:Add(player:GetAttributeChangedSignal("InRaid"):Connect(function()
		SurvivalService.ResetSprintState(player, true)
	end))

	janitor:Add(player.CharacterAdded:Connect(function(character: Model)
		task.spawn(bindCharacter, player, character)
	end))

	janitor:Add(player.CharacterRemoving:Connect(function(character: Model)
		appliedCharacters[character] = nil
		hpRegenAccum[player] = 0
		SurvivalService.ResetSprintState(player, false)
		local existingCharJanitor = characterJanitors[player]
		if existingCharJanitor then
			existingCharJanitor:Cleanup()
		end
	end))

	if player.Character then
		task.spawn(bindCharacter, player, player.Character)
	end
end

local function onPlayerDataLoaded(player: Player, data: PlayerData)
	syncPlayerAttributes(player, data.Stats)
	local character = player.Character
	if character then
		applyStatsToCharacter(player, character, data)
	end
end

function SurvivalService.ApplyConsumableEffects(
	player: Player,
	data: PlayerData,
	humanoid: Humanoid?,
	itemId: string,
	consumableConfig: Types.ConsumableConfig
)
	if itemId == "bandage" then
		SurvivalService.ClearBleeding(player)
	end

	if humanoid ~= nil and consumableConfig.Health ~= 0 then
		humanoid.Health = math.clamp(humanoid.Health + consumableConfig.Health, 0, humanoid.MaxHealth)
		data.Stats.Health = humanoid.Health
	end

	data.Stats.Hunger = math.clamp(data.Stats.Hunger + consumableConfig.Hunger, 0, Types.MAX_HUNGER)
	data.Stats.Thirst = math.clamp(data.Stats.Thirst + consumableConfig.Thirst, 0, Types.MAX_THIRST)

	if consumableConfig.BuffDuration ~= nil and consumableConfig.BuffDuration > 0 then
		local nowUnix = os.time()
		local currentEnd = data.Stats.WellFedEndTime or 0
		local currentMult = if currentEnd > nowUnix then math.max(1.0, data.Stats.WellFedStaminaMult or 1.0) else 1.0
		local newBonus = math.max(1.0, consumableConfig.MaxStaminaBonus or 1.0)
		local newEnd = nowUnix + math.floor(consumableConfig.BuffDuration)
		data.Stats.WellFedEndTime = math.max(currentEnd, newEnd)
		data.Stats.WellFedStaminaMult = math.max(currentMult, newBonus)
	end

	if consumableConfig.Stamina ~= nil and consumableConfig.Stamina ~= 0 then
		SurvivalService.AddStamina(player, consumableConfig.Stamina)
	end
	syncPlayerAttributes(player, data.Stats)
end

local function onUseConsumable(player: Player, slotIndexAny: any)
	if not SecurityService.CheckRateLimit(player, Net.Events.UseConsumable) then
		return
	end
	if not SecurityService.IsValidInteger(slotIndexAny, 1, Types.INVENTORY_SIZE) then
		return
	end
	local slotIndex = slotIndexAny :: number

	if DataService.IsTeleporting(player) or SecurityService.IsTransactionLocked(player) then
		return
	end
	if DataService.GetData(player) == nil then
		return
	end
	if SecurityService.GetAliveCharacterRoot(player) == nil then
		return
	end

	SecurityService.RunLocked(player, "UseConsumable", function()
		local data = DataService.GetData(player)
		if not data then
			return
		end

		local _, _, humanoid = getAliveCharacterParts(player)
		if not humanoid then
			return
		end

		local slot = InventoryService.GetSlot(player, slotIndex)
		if slot == nil or slot.Count <= 0 then
			return
		end

		local itemConfig = Items[slot.Id]
		local consumableConfig = Consumables[slot.Id]
		if not itemConfig or itemConfig.Type ~= "Consumable" or not consumableConfig then
			return
		end

		local now = os.clock()
		local readyAt = nextConsumeTime[player] or 0
		if now < readyAt then
			return
		end

		local itemId = slot.Id
		if not InventoryService.ConsumeSlot(player, slotIndex, 1) then
			return
		end

		nextConsumeTime[player] = now + consumableConfig.UseCooldown
		SurvivalService.ApplyConsumableEffects(player, data, humanoid, itemId, consumableConfig)
	end)
end

local function onSprintStateRequest(player: Player, wantsSprintAny: any)
	if not SecurityService.CheckRateLimit(player, Net.Events.SprintStateRequest) then
		return
	end
	if typeof(wantsSprintAny) ~= "boolean" then
		SecurityService.LogSuspicious(player, Net.Events.SprintStateRequest, "invalid sprint flag")
		return
	end
	if DataService.IsTeleporting(player) or SecurityService.IsTeleportLocked(player) then
		SurvivalService.ResetSprintState(player, false)
		return
	end

	local state = getOrCreateStaminaState(player)
	local wantsSprint = wantsSprintAny :: boolean
	state.WantsSprint = wantsSprint

	if not wantsSprint and state.IsSprinting then
		state.IsSprinting = false
		local _, _, humanoid = getAliveCharacterParts(player)
		if humanoid ~= nil then
			applyCharacterWalkSpeed(humanoid, false)
		end
		syncStaminaAttributes(player, state, true)
	end
end

local function stepStamina(dt: number)
	local clampedDt = math.min(dt, MAX_HEARTBEAT_DT)
	if clampedDt <= 0 then
		return
	end

	for _, player in Players:GetPlayers() do
		local state = getOrCreateStaminaState(player)
		local _, _, humanoid = getAliveCharacterParts(player)
		if humanoid == nil or DataService.IsTeleporting(player) or SecurityService.IsTeleportLocked(player) then
			if state.IsSprinting or state.WantsSprint then
				SurvivalService.ResetSprintState(player, false)
			end
			continue
		end

		local isMoving = humanoid.MoveDirection.Magnitude > MOVE_DIRECTION_THRESHOLD
		local canStart = (not state.Exhausted) and (state.Stamina >= Config.STAMINA_MIN_TO_SPRINT)
		local canContinue = state.IsSprinting and not state.Exhausted and (state.Stamina > 0)
		local shouldSprint = state.WantsSprint and isMoving and (canContinue or canStart)
		local stateChanged = (shouldSprint ~= state.IsSprinting)

		local maxStamina = getPlayerMaxStamina(player)
		if state.Stamina > maxStamina then
			state.Stamina = maxStamina
		end

		if shouldSprint then
			state.IsSprinting = true
			state.Stamina = math.max(0, state.Stamina - Config.STAMINA_DRAIN_PER_SEC * clampedDt)
			if state.Stamina <= 0 then
				state.Stamina = 0
				state.IsSprinting = false
				state.Exhausted = true
				stateChanged = true
			end
		else
			state.IsSprinting = false
			local regenRate = Config.STAMINA_REGEN_BASE
			local data = DataService.GetData(player)
			if data ~= nil then
				if data.Stats.Hunger <= 0 or data.Stats.Thirst <= 0 then
					regenRate = Config.STAMINA_REGEN_STARVING
				elseif isWellFed(data.Stats) then
					regenRate = Config.STAMINA_REGEN_WELL_FED
				end
			end
			state.Stamina = math.min(maxStamina, state.Stamina + regenRate * clampedDt)
			if state.Exhausted and state.Stamina >= Config.STAMINA_MIN_TO_SPRINT then
				state.Exhausted = false
				stateChanged = true
			end
		end

		applyCharacterWalkSpeed(humanoid, state.IsSprinting)
		syncStaminaAttributes(player, state, stateChanged)
	end
end

local function stepSurvivalLoop()
	local now = os.clock()
	for _, player in Players:GetPlayers() do
		if DataService.IsTeleporting(player) or SecurityService.IsTeleportLocked(player) then
			continue
		end

		local data = DataService.GetData(player)
		local _, _, humanoid = getAliveCharacterParts(player)
		if data ~= nil and humanoid ~= nil then
			local stats = data.Stats
			if not isHungerDrainFrozen(player) then
				stats.Hunger = math.clamp(stats.Hunger - HUNGER_LOSS_PER_TICK, 0, Types.MAX_HUNGER)
				stats.Thirst = math.clamp(stats.Thirst - THIRST_LOSS_PER_TICK, 0, Types.MAX_THIRST)
			end

			local bleed = activeBleeds[player]
			if bleed ~= nil then
				if now >= bleed.ExpiresAt then
					SurvivalService.ClearBleeding(player)
				else
					local bleedDamage = bleed.Dps * Types.SURVIVAL_TICK_INTERVAL
					humanoid.Health = math.max(0, humanoid.Health - bleedDamage)
					lastDamageAt[player] = now
					hpRegenAccum[player] = 0
					setAttributeIfChanged(player, "Bleeding", true)
				end
			end

			local lastDmg = lastDamageAt[player] or 0
			local canRegenHp = isWellFed(stats)
				and activeBleeds[player] == nil
				and (now - lastDmg) >= Config.COMBAT_REGEN_COOLDOWN
				and humanoid.Health > 0
				and humanoid.Health < humanoid.MaxHealth

			if canRegenHp then
				local accum = (hpRegenAccum[player] or 0) + Types.SURVIVAL_TICK_INTERVAL
				while accum >= Config.WELL_FED_HP_INTERVAL and humanoid.Health < humanoid.MaxHealth do
					accum -= Config.WELL_FED_HP_INTERVAL
					humanoid.Health = math.min(humanoid.MaxHealth, humanoid.Health + Config.WELL_FED_HP_REGEN)
				end
				hpRegenAccum[player] = accum
			else
				hpRegenAccum[player] = 0
			end

			stats.Health = math.clamp(humanoid.Health, 0, humanoid.MaxHealth)
			syncPlayerAttributes(player, stats)
		end
	end
end

function SurvivalService.ApplyBleeding(player: Player, duration: number, dps: number)
	if not SecurityService.IsFiniteNumber(duration) or duration <= 0 then
		return
	end
	if not SecurityService.IsFiniteNumber(dps) or dps <= 0 then
		return
	end
	if player.Parent ~= Players then
		return
	end
	if getAliveCharacterParts(player) == nil then
		return
	end

	local expiresAt = os.clock() + duration
	local existing = activeBleeds[player]
	if existing ~= nil then
		existing.ExpiresAt = math.max(existing.ExpiresAt, expiresAt)
		existing.Dps = math.max(existing.Dps, dps)
	else
		activeBleeds[player] = {
			ExpiresAt = expiresAt,
			Dps = dps,
		}
	end
	setAttributeIfChanged(player, "Bleeding", true)
end

function SurvivalService.ClearBleeding(player: Player)
	activeBleeds[player] = nil
	if player.Parent == Players then
		setAttributeIfChanged(player, "Bleeding", false)
	end
end

function SurvivalService.IsWellFed(player: Player): boolean
	local data = DataService.GetData(player)
	if data == nil then
		return false
	end
	return isWellFed(data.Stats)
end

function SurvivalService.GetMaxStamina(player: Player): number
	return getPlayerMaxStamina(player)
end

function SurvivalService.GetStamina(player: Player): number
	local state = staminaStates[player]
	if state ~= nil then
		return state.Stamina
	end
	return getPlayerMaxStamina(player)
end

function SurvivalService.AddStamina(player: Player, amount: number)
	if player.Parent ~= Players then
		return
	end
	if not SecurityService.IsFiniteNumber(amount) then
		return
	end
	local state = getOrCreateStaminaState(player)
	local maxStamina = getPlayerMaxStamina(player)
	state.Stamina = math.clamp(state.Stamina + amount, 0, maxStamina)
	if state.Exhausted and state.Stamina >= Config.STAMINA_MIN_TO_SPRINT then
		state.Exhausted = false
	end
	syncStaminaAttributes(player, state, true)
end

function SurvivalService.ResetSprintState(player: Player, refillStamina: boolean)
	local state = getOrCreateStaminaState(player)
	state.WantsSprint = false
	state.IsSprinting = false
	state.Exhausted = false
	if refillStamina then
		state.Stamina = getPlayerMaxStamina(player)
	end
	local character = player.Character
	local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
	if humanoid and humanoid.Health > 0 then
		applyCharacterWalkSpeed(humanoid, false)
	end
	syncStaminaAttributes(player, state, true)
end

function SurvivalService.GetStats(player: Player): SurvivalStats?
	local data = DataService.GetData(player)
	if not data then
		return nil
	end
	return {
		Health = data.Stats.Health,
		Hunger = data.Stats.Hunger,
		Thirst = data.Stats.Thirst,
		WellFedEndTime = data.Stats.WellFedEndTime,
		WellFedStaminaMult = data.Stats.WellFedStaminaMult,
	}
end

function SurvivalService.GetContainerState(containerId: string): LootContainerState?
	return LootService.GetContainerState(containerId)
end

function SurvivalService.Init()
	if isInitialized then
		return
	end
	isInitialized = true

	Net.InitServer()
	getOrCreateLootFolder()

	Net.GetEvent(Net.Events.UseConsumable).OnServerEvent:Connect(onUseConsumable)
	Net.GetEvent(Net.Events.SprintStateRequest).OnServerEvent:Connect(onSprintStateRequest)

	Players.PlayerAdded:Connect(bindPlayer)
	for _, player in Players:GetPlayers() do
		bindPlayer(player)
	end

	Players.PlayerRemoving:Connect(function(player: Player)
		LootService.CloseContainerForPlayer(player, false)
		activeBleeds[player] = nil
		nextConsumeTime[player] = nil
		pendingRespawnReset[player] = nil
		staminaStates[player] = nil
		lastDamageAt[player] = nil
		hpRegenAccum[player] = nil

		local charJanitor = characterJanitors[player]
		if charJanitor then
			charJanitor:Destroy()
			characterJanitors[player] = nil
		end

		local pJanitor = playerJanitors[player]
		if pJanitor then
			pJanitor:Destroy()
			playerJanitors[player] = nil
		end
	end)

	DataService.OnBeforeUnload(function(player: Player, data: PlayerData)
		SurvivalService.ResetSprintState(player, false)
		local character = player.Character
		local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
		if humanoid then
			data.Stats.Health = math.clamp(humanoid.Health, 0, humanoid.MaxHealth)
		end
	end)

	DataService.OnDataLoaded(onPlayerDataLoaded)

	RunService.Heartbeat:Connect(stepStamina)

	task.spawn(function()
		while true do
			task.wait(Types.SURVIVAL_TICK_INTERVAL)
			stepSurvivalLoop()
		end
	end)
end

return SurvivalService
