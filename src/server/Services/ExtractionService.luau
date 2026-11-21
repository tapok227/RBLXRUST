--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local TeleportService = game:GetService("TeleportService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)
local Types = require(ReplicatedStorage.Shared.Types)
local Net = require(ReplicatedStorage.Shared.Net)
local Janitor = require(ReplicatedStorage.Shared.Janitor)
local DataService = require(ServerScriptService.Server.Services.DataService)

type ExtractionState = Types.ExtractionState

type ExtractionZone = {
	Part: BasePart,
	ZoneName: string,
	HalfSize: Vector3,
}

type ActiveExtraction = {
	ZoneName: string,
	StartTime: number,
	TotalTime: number,
}

type PendingTeleport = {
	TargetPlaceId: number,
	ZoneName: string,
	TotalTime: number,
	Attempts: number,
	Retrying: boolean,
	Options: TeleportOptions,
}

local TICK_INTERVAL = 0.25
local DAMAGE_EPSILON = 0.05
local MAX_TELEPORT_RETRIES = 2
local TELEPORT_RETRY_DELAY = 2
local STUDIO_SIM_BANNER_DURATION = 5

local zones: { ExtractionZone } = {}
local activeExtractions: { [Player]: ActiveExtraction } = {}
local lastDamageTime: { [Player]: number } = {}
local teleportInProgress: { [Player]: boolean } = {}
local pendingTeleports: { [Player]: PendingTeleport } = {}
local playerJanitors: { [Player]: Janitor.Janitor } = {}
local characterJanitors: { [Player]: Janitor.Janitor } = {}
local folderJanitor: Janitor.Janitor? = nil
local isInitialized = false

local ExtractionService = {}

local function sendExtractionState(player: Player, state: ExtractionState)
	if player.Parent ~= Players then
		return
	end
	Net.GetEvent(Net.Events.ExtractionStateSync):FireClient(player, state)
end

local function isInCombatCooldown(player: Player, now: number): boolean
	local dmgTime = lastDamageTime[player]
	if dmgTime == nil then
		return false
	end
	return (now - dmgTime) < Config.Extraction.CooldownAfterDamage
end

local function getAliveCharacterParts(player: Player): (Model?, BasePart?, Humanoid?)
	local character = player.Character
	if not character then
		return nil, nil, nil
	end
	local hrp = character:FindFirstChild("HumanoidRootPart")
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not hrp or not hrp:IsA("BasePart") or not humanoid or humanoid.Health <= 0 then
		return nil, nil, nil
	end
	return character, hrp, humanoid
end

local function isPointInZone(point: Vector3, zone: ExtractionZone): boolean
	local localPos = zone.Part.CFrame:PointToObjectSpace(point)
	local half = zone.HalfSize
	return math.abs(localPos.X) <= half.X and math.abs(localPos.Y) <= half.Y + 2 and math.abs(localPos.Z) <= half.Z
end

local function findZoneAtPosition(point: Vector3): ExtractionZone?
	for _, zone in zones do
		if zone.Part.Parent ~= nil and isPointInZone(point, zone) then
			return zone
		end
	end
	return nil
end

local function cancelExtraction(player: Player, statusText: string?)
	local active = activeExtractions[player]
	if active == nil then
		return
	end
	activeExtractions[player] = nil
	sendExtractionState(player, {
		Active = false,
		ZoneName = active.ZoneName,
		TimeLeft = active.TotalTime,
		TotalTime = active.TotalTime,
		StatusText = statusText,
	})
end

local function recordPlayerDamage(player: Player)
	lastDamageTime[player] = os.clock()
	if activeExtractions[player] ~= nil then
		cancelExtraction(player, "Extraction cancelled: took damage")
	end
end

local function scanExtractionZones()
	table.clear(zones)
	local folder = Workspace:FindFirstChild("ExtractionZones")
	if not folder then
		warn("[ExtractionService] Workspace.ExtractionZones folder not found")
		return
	end

	for _, child in folder:GetChildren() do
		if child:IsA("BasePart") then
			local attrName = child:GetAttribute("ZoneName")
			local zoneName = if typeof(attrName) == "string" and #attrName > 0 then attrName else child.Name
			table.insert(zones, {
				Part = child,
				ZoneName = zoneName,
				HalfSize = child.Size * 0.5,
			})
		end
	end
end

local function watchExtractionFolder(folder: Instance)
	if folderJanitor then
		folderJanitor:Destroy()
		folderJanitor = nil
	end

	local janitor = Janitor.new()
	folderJanitor = janitor

	janitor:Add(folder.ChildAdded:Connect(function()
		scanExtractionZones()
	end))
	janitor:Add(folder.ChildRemoved:Connect(function()
		scanExtractionZones()
	end))

	scanExtractionZones()
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
	lastDamageTime[player] = nil

	local humanoidInst = character:FindFirstChildOfClass("Humanoid")
	if not humanoidInst then
		humanoidInst = character:WaitForChild("Humanoid", 10)
	end
	if not humanoidInst or not humanoidInst:IsA("Humanoid") then
		return
	end
	if player.Character ~= character then
		return
	end

	local humanoid = humanoidInst :: Humanoid
	local lastHealth = humanoid.Health

	charJanitor:Add(humanoid.HealthChanged:Connect(function(newHealth: number)
		local prevHealth = lastHealth
		lastHealth = newHealth
		if newHealth < prevHealth - DAMAGE_EPSILON then
			recordPlayerDamage(player)
		end
	end))

	charJanitor:Add(humanoid.Died:Connect(function()
		cancelExtraction(player, nil)
	end))
end

local function bindPlayer(player: Player)
	if playerJanitors[player] ~= nil then
		return
	end

	local janitor = Janitor.new()
	playerJanitors[player] = janitor

	janitor:Add(player.CharacterAdded:Connect(function(character: Model)
		task.spawn(bindCharacter, player, character)
	end))

	janitor:Add(player.CharacterRemoving:Connect(function()
		cancelExtraction(player, nil)
		local existingCharJanitor = characterJanitors[player]
		if existingCharJanitor then
			existingCharJanitor:Cleanup()
		end
	end))

	if player.Character then
		task.spawn(bindCharacter, player, player.Character)
	end
end

local function handleTeleportFailure(player: Player, reasonText: string, allowRetry: boolean)
	local pending = pendingTeleports[player]
	if pending == nil or pending.Retrying then
		return
	end

	if allowRetry and pending.Attempts <= MAX_TELEPORT_RETRIES and player.Parent == Players then
		pending.Retrying = true
		local retryNumber = pending.Attempts
		pending.Attempts += 1
		sendExtractionState(player, {
			Active = true,
			ZoneName = pending.ZoneName,
			TimeLeft = 0,
			TotalTime = pending.TotalTime,
			StatusText = string.format("Teleport failed, retrying (%d/%d)...", retryNumber, MAX_TELEPORT_RETRIES),
		})

		task.delay(TELEPORT_RETRY_DELAY, function()
			local currentPending = pendingTeleports[player]
			if currentPending ~= pending then
				return
			end
			currentPending.Retrying = false
			if player.Parent ~= Players then
				pendingTeleports[player] = nil
				teleportInProgress[player] = nil
				return
			end

			local ok, err = pcall(function()
				TeleportService:TeleportAsync(currentPending.TargetPlaceId, { player }, currentPending.Options)
			end)
			if not ok then
				warn(string.format("[ExtractionService] Teleport retry failed for %s: %s", player.Name, tostring(err)))
				handleTeleportFailure(player, reasonText, true)
			end
		end)
		return
	end

	pendingTeleports[player] = nil
	teleportInProgress[player] = nil
	DataService.RestoreAfterFailedTeleport(player)
	sendExtractionState(player, {
		Active = false,
		ZoneName = pending.ZoneName,
		TimeLeft = pending.TotalTime,
		TotalTime = pending.TotalTime,
		StatusText = reasonText,
	})
end

local function teleportPlayerToPlace(
	player: Player,
	targetPlaceId: number,
	zoneName: string,
	totalTime: number,
	teleportData: { [string]: any },
	studioLabel: string
)
	if teleportInProgress[player] or player.Parent ~= Players then
		return
	end
	teleportInProgress[player] = true

	if RunService:IsStudio() then
		local released = DataService.ReleaseForTeleport(player)
		print(
			string.format(
				"[ExtractionService] Studio mock teleport to %s (%d) for %s (ProfileReleased=%s)",
				studioLabel,
				targetPlaceId,
				player.Name,
				tostring(released)
			)
		)
		sendExtractionState(player, {
			Active = true,
			ZoneName = zoneName,
			TimeLeft = 0,
			TotalTime = totalTime,
			StatusText = "Extracted (Studio Simulation)",
		})

		task.delay(STUDIO_SIM_BANNER_DURATION, function()
			if player.Parent == Players and pendingTeleports[player] == nil then
				sendExtractionState(player, {
					Active = false,
					ZoneName = zoneName,
					TimeLeft = 0,
					TotalTime = totalTime,
				})
			end
		end)
		return
	end

	sendExtractionState(player, {
		Active = true,
		ZoneName = zoneName,
		TimeLeft = 0,
		TotalTime = totalTime,
		StatusText = "Saving data & teleporting...",
	})

	local released = DataService.ReleaseForTeleport(player)
	if not released then
		warn(string.format("[ExtractionService] Failed to release profile before teleport for %s", player.Name))
		DataService.RestoreAfterFailedTeleport(player)
		teleportInProgress[player] = nil
		sendExtractionState(player, {
			Active = false,
			ZoneName = zoneName,
			TimeLeft = totalTime,
			TotalTime = totalTime,
			StatusText = "Extraction failed: save timeout",
		})
		return
	end

	if player.Parent ~= Players then
		teleportInProgress[player] = nil
		return
	end

	local options = Instance.new("TeleportOptions")
	options:SetTeleportData(teleportData)

	pendingTeleports[player] = {
		TargetPlaceId = targetPlaceId,
		ZoneName = zoneName,
		TotalTime = totalTime,
		Attempts = 1,
		Retrying = false,
		Options = options,
	}

	local ok, err = pcall(function()
		TeleportService:TeleportAsync(targetPlaceId, { player }, options)
	end)
	if not ok then
		warn(string.format("[ExtractionService] TeleportAsync error for %s: %s", player.Name, tostring(err)))
		handleTeleportFailure(player, "Teleport failed", true)
	end
end

local function completeExtraction(player: Player, zoneName: string, totalTime: number)
	teleportPlayerToPlace(player, Config.Places.PlayerBase, zoneName, totalTime, {
		FromPlaceId = game.PlaceId,
		OwnerUserId = player.UserId,
		Mode = "Base",
	}, "PlayerBase")
end

local function onTeleportInitFailed(
	player: Player,
	teleportResult: Enum.TeleportResult,
	errorMessage: string,
	_placeId: number,
	_teleportOptions: TeleportOptions
)
	if pendingTeleports[player] == nil then
		return
	end
	warn(
		string.format(
			"[ExtractionService] TeleportInitFailed for %s (%s): %s",
			player.Name,
			tostring(teleportResult),
			errorMessage
		)
	)
	handleTeleportFailure(player, string.format("Teleport failed: %s", errorMessage), true)
end

local function stepExtractionLoop()
	if #zones == 0 then
		return
	end
	local now = os.clock()
	for _, player in Players:GetPlayers() do
		if teleportInProgress[player] or DataService.GetData(player) == nil then
			continue
		end

		local _, hrp, _ = getAliveCharacterParts(player)
		if hrp == nil then
			cancelExtraction(player, nil)
			continue
		end

		local zone = findZoneAtPosition(hrp.Position)
		if zone == nil then
			cancelExtraction(player, nil)
			continue
		end

		if isInCombatCooldown(player, now) then
			cancelExtraction(player, "Extraction blocked: in combat")
			continue
		end

		local active = activeExtractions[player]
		if active == nil or active.ZoneName ~= zone.ZoneName then
			active = {
				ZoneName = zone.ZoneName,
				StartTime = now,
				TotalTime = Config.Extraction.Duration,
			}
			activeExtractions[player] = active
		end

		local timeLeft = math.max(0, active.TotalTime - (now - active.StartTime))
		if timeLeft > 0 then
			sendExtractionState(player, {
				Active = true,
				ZoneName = active.ZoneName,
				TimeLeft = timeLeft,
				TotalTime = active.TotalTime,
			})
		else
			activeExtractions[player] = nil
			task.spawn(completeExtraction, player, active.ZoneName, active.TotalTime)
		end
	end
end

function ExtractionService.GetExtractionState(player: Player): ExtractionState?
	local active = activeExtractions[player]
	if active == nil then
		return nil
	end
	local timeLeft = math.max(0, active.TotalTime - (os.clock() - active.StartTime))
	return {
		Active = true,
		ZoneName = active.ZoneName,
		TimeLeft = timeLeft,
		TotalTime = active.TotalTime,
	}
end

function ExtractionService.IsInCombatCooldown(player: Player): boolean
	return isInCombatCooldown(player, os.clock())
end

function ExtractionService.RecordDamage(player: Player)
	recordPlayerDamage(player)
end

function ExtractionService.Init()
	if isInitialized then
		return
	end
	isInitialized = true

	Net.InitServer()

	local zonesFolder = Workspace:FindFirstChild("ExtractionZones")
	if zonesFolder then
		watchExtractionFolder(zonesFolder)
	else
		Workspace.ChildAdded:Connect(function(child: Instance)
			if child.Name == "ExtractionZones" then
				watchExtractionFolder(child)
			end
		end)
	end

	TeleportService.TeleportInitFailed:Connect(onTeleportInitFailed)

	Players.PlayerAdded:Connect(bindPlayer)
	for _, player in Players:GetPlayers() do
		bindPlayer(player)
	end

	Players.PlayerRemoving:Connect(function(player: Player)
		activeExtractions[player] = nil
		lastDamageTime[player] = nil
		teleportInProgress[player] = nil
		pendingTeleports[player] = nil

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

	task.spawn(function()
		while true do
			task.wait(TICK_INTERVAL)
			stepExtractionLoop()
		end
	end)
end

return ExtractionService
