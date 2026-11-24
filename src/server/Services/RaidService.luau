--!strict
local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")
local MessagingService = game:GetService("MessagingService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local TeleportService = game:GetService("TeleportService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)
local Types = require(ReplicatedStorage.Shared.Types)
local Items = require(ReplicatedStorage.Shared.configs.Items)
local BuildingConfig = require(ReplicatedStorage.Shared.configs.BuildingConfig)
local Defenses = require(ReplicatedStorage.Shared.configs.Defenses)
local BuildingGeometry = require(ReplicatedStorage.Shared.BuildingGeometry)
local Explosives = require(ReplicatedStorage.Shared.configs.Explosives)
local Janitor = require(ReplicatedStorage.Shared.Janitor)
local Net = require(ReplicatedStorage.Shared.Net)
local BaseService = require(ServerScriptService.Server.Services.BaseService)
local BuildingValidator = require(ServerScriptService.Server.Services.BuildingValidator)
local CraftingService = require(ServerScriptService.Server.Services.CraftingService)
local DataService = require(ServerScriptService.Server.Services.DataService)
local DefenseService = require(ServerScriptService.Server.Services.DefenseService)
local InventoryService = require(ServerScriptService.Server.Services.InventoryService)
local LootService = require(ServerScriptService.Server.Services.LootService)
local RaidExplosives = require(ServerScriptService.Server.Services.Raid.RaidExplosives)
local RaidIntel = require(ServerScriptService.Server.Services.Raid.RaidIntel)
local RaidOutpost = require(ServerScriptService.Server.Services.Raid.RaidOutpost)
local SecurityService = require(ServerScriptService.Server.Services.SecurityService)

type Slot = Types.Slot
type Inventory = Types.Inventory
type ItemBatchEntry = Types.ItemBatchEntry
type BuildPieceType = Types.BuildPieceType
type BuildTier = Types.BuildTier
type SavedBuildPiece = Types.SavedBuildPiece
type BaseData = Types.BaseData
type RaidTargetInfo = Types.RaidTargetInfo
type RaidIntelPool = Types.RaidIntelPool
type RaidHudState = Types.RaidHudState
type RaidDefenseReport = Types.RaidDefenseReport
type DeathGhostPoint = Types.DeathGhostPoint
type DefenseLogEntry = Types.DefenseLogEntry
type ExplosionParams = Types.ExplosionParams
type ExplosionResult = Types.ExplosionResult

type RaidPieceRecord = {
	Piece: SavedBuildPiece,
	Model: Model,
	ContainerId: string?,
	MaxHp: number,
}

type RaiderPieceRecord = {
	Owner: Player,
	Piece: SavedBuildPiece,
	Model: Model,
	CFrame: CFrame,
}

type ActiveExplosiveRecord = {
	Part: Part,
	Label: TextLabel?,
	CancelFlag: boolean,
}

type RaidSession = {
	Raider: Player,
	TargetUserId: number,
	TargetName: string,
	TargetBaseTier: number,
	Origin: Vector3,
	OutpostOrigin: Vector3,
	IsStudioMock: boolean,
	IsSelfRaid: boolean,
	SavedInventorySnapshot: Inventory?,
	StartTime: number,
	Duration: number,
	Pieces: { [string]: RaidPieceRecord },
	RaiderPieces: { [string]: RaiderPieceRecord },
	RaiderOccupiedSockets: { [string]: { [string]: string } },
	RaiderOccupiedWorldKeys: { [string]: string },
	OutpostZoneModel: Model?,
	OutpostWorkbenchId: string?,
	ExtractionStashContainerId: string?,
	ExtractionStashModel: Model?,
	StashExtractPrompt: ProximityPrompt?,
	SupplyCrateContainerId: string?,
	SupplyCrateModel: Model?,
	ExtractionTerminalModel: Model?,
	ExtractionTerminalPrompt: ProximityPrompt?,
	ExtractionTerminalIndicator: BasePart?,
	ArenaGroundPart: BasePart?,
	RespawnPosition: Vector3,
	DroppedContainerIds: { string },
	ActiveExplosives: { ActiveExplosiveRecord },
	TcPieceUid: string?,
	TcCaptured: boolean,
	TcHackActive: boolean,
	TcHackStartTime: number,
	TcHackPrompt: ProximityPrompt?,
	LivesLeft: number,
	MaxLives: number,
	LivesSpent: number,
	RaiderSpentScrapValue: number,
	DeathPoints: { DeathGhostPoint },
	LastDamagedAt: number,
	Extracting: boolean,
	ExtractionCountdownActive: boolean,
	ExtractionCountdownStart: number,
	ExtractionTotalDuration: number,
	ExtractionSirenSound: Sound?,
	ExtractionBeaconPart: BasePart?,
	StashExtracted: boolean,
	PendingReturnOnRespawn: boolean,
	ReturnPosition: Vector3?,
	RaidId: string,
	ReservedAccessCode: string?,
	AlarmTriggered: boolean,
	Defender: Player?,
	DefenderReturnPos: Vector3?,
	DefenderJanitor: Janitor.Janitor?,
	Janitor: Janitor.Janitor,
}

type PendingTeleport = {
	TargetPlaceId: number,
	Options: TeleportOptions,
	IsReturningToMap: boolean,
	IsDefenderTeleport: boolean?,
	TargetName: string,
	LaunchCostBatch: { ItemBatchEntry }?,
}

type PendingDefenseAlarm = {
	RaidId: string,
	TargetUserId: number,
	TargetName: string,
	RaiderName: string,
	TargetBaseTier: number,
	ReservedAccessCode: string,
	IsStudioMock: boolean,
	PromptExpiresAt: number,
	Accepted: boolean,
	PrepEndsAt: number,
}

local RAID_STRUCTURES_FOLDER_NAME = "RaidTargetStructures"
local RAID_OUTPOST_STRUCTURES_FOLDER_NAME = "RaidOutpostStructures"
local LOOT_CONTAINERS_FOLDER_NAME = "LootContainers"
local STUDIO_MOCK_RAID_ORIGIN = Vector3.new(300, 0, 300)
local RAID_ALARM_TOPIC = "MyRobloxGame_RaidAlarm"
local EXTRACTION_SIREN_SOUND_ID = "rbxasset://sounds/action_falling.ogg"
local RAID_DURATION = Types.RAID_DURATION
local LIST_COOLDOWN = 1.0
local EXPLOSIVE_PLACE_COOLDOWN = 0.5
local MAX_HIT_SURFACE_OFFSET = 4.0

local activeSessions: { [Player]: RaidSession } = {}
local activeSessionByRaidId: { [string]: RaidSession } = {}
local activeSessionByTargetUserId: { [number]: RaidSession } = {}
local pendingDefenseAlarms: { [Player]: PendingDefenseAlarm } = {}
local lastListRequest: { [Player]: number } = {}
local lastExplosivePlaceTime: { [Player]: number } = {}
local teleportInProgress: { [Player]: boolean } = {}
local pendingTeleports: { [Player]: PendingTeleport } = {}
local nextSelfRaidSeq = 0
local isInitialized = false

local RaidService = {}
local getExplosionDeps: () -> RaidExplosives.ExplosionDeps
local getOutpostDeps: () -> RaidOutpost.OutpostDeps
local triggerActiveRaidAlarm: (session: RaidSession) -> ()
local returnDefenderAfterRaid: (session: RaidSession, statusText: string?) -> ()

local function getTerminalPosition(inst: Instance): Vector3?
	if inst:IsA("Model") then
		return if inst.PrimaryPart then inst.PrimaryPart.Position else inst:GetPivot().Position
	elseif inst:IsA("BasePart") then
		return inst.Position
	end
	return nil
end

local function isNearRaidTerminal(hrp: BasePart): boolean
	local candidates: { Instance } = {}
	local direct = Workspace:FindFirstChild("RaidTerminal")
	if direct ~= nil then
		table.insert(candidates, direct)
	end
	for _, tagged in CollectionService:GetTagged("RaidTerminal") do
		table.insert(candidates, tagged)
	end
	local deep = Workspace:FindFirstChild("RaidTerminal", true)
	if deep ~= nil then
		table.insert(candidates, deep)
	end

	if #candidates == 0 then
		return true
	end

	local maxDist = Types.MAX_RAID_TERMINAL_DISTANCE + Types.PING_DISTANCE_TOLERANCE
	local anyValidPos = false
	for _, inst in candidates do
		local pos = getTerminalPosition(inst)
		if pos ~= nil then
			anyValidPos = true
			if (hrp.Position - pos).Magnitude <= maxDist then
				return true
			end
		end
	end
	return not anyValidPos
end

local function hasAnySlots(inv: Inventory, maxSlots: number): boolean
	for i = 1, maxSlots do
		local slot = inv[i]
		if slot ~= nil and slot.Count > 0 then
			return true
		end
	end
	return false
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

local function getAliveCharacterParts(player: Player): (Model?, BasePart?, Humanoid?)
	return SecurityService.GetAliveCharacterRoot(player)
end

local function sendRaidHud(player: Player, state: RaidHudState)
	if player.Parent ~= Players then
		return
	end
	Net.GetEvent(Net.Events.RaidHudSync):FireClient(player, state)
end

local function createRaidPieceModel(piece: SavedBuildPiece, origin: Vector3): (Model, number)
	local canonicalType = BuildingGeometry.CanonicalPieceType(piece.PieceType)
	piece.PieceType = canonicalType
	local worldCF = BuildingGeometry.GetPieceWorldCFrame(piece, origin)
	local modelName = string.format("Raid_%s_%s", canonicalType, string.sub(piece.Uid, 1, 12))
	local model = BuildingGeometry.CreateModel(canonicalType, worldCF, false, modelName, piece.MountSurface)
	BuildingGeometry.ApplyTierVisuals(model, canonicalType, piece.Tier)

	local maxHp = BuildingGeometry.ComputeMaxHp(canonicalType, piece.Tier)
	BuildingGeometry.ApplyWearVisuals(model, canonicalType, piece.Tier, piece.Hp, maxHp)

	model:SetAttribute("RaidPieceUid", piece.Uid)
	model:SetAttribute("BuildUid", piece.Uid)
	model:SetAttribute("PieceType", canonicalType)
	model:SetAttribute("Tier", piece.Tier)
	if piece.MountSurface ~= nil then
		model:SetAttribute("MountSurface", piece.MountSurface)
	end
	model:SetAttribute("Health", piece.Hp)
	model:SetAttribute("Hp", piece.Hp)
	model:SetAttribute("MaxHealth", maxHp)
	model:SetAttribute("MaxHp", maxHp)
	model:SetAttribute("LastDamagedAt", piece.LastDamagedAt or 0)
	model:SetAttribute("IsRaidTarget", true)

	return model, maxHp
end

local function storageMapToInventory(storage: { [string]: Slot }?, maxSlots: number): Inventory
	local inv: Inventory = {}
	if type(storage) ~= "table" then
		return inv
	end

	for k, v in storage do
		local slotIndex = tonumber(k)
		if
			slotIndex ~= nil
			and slotIndex >= 1
			and slotIndex <= maxSlots
			and slotIndex % 1 == 0
			and type(v) == "table"
			and type(v.Id) == "string"
			and type(v.Count) == "number"
			and v.Count > 0
		then
			inv[slotIndex] = {
				Id = v.Id,
				Count = math.floor(v.Count),
			}
		end
	end

	return inv
end

local function updatePieceDamageBillboard(record: RaidPieceRecord)
	local primary = record.Model.PrimaryPart
	if not primary then
		return
	end

	local existingGui = primary:FindFirstChild("DamageHpGui")
	local label: TextLabel? = nil

	if existingGui and existingGui:IsA("BillboardGui") then
		local found = existingGui:FindFirstChild("HpLabel")
		if found and found:IsA("TextLabel") then
			label = found
		end
	else
		local gui = Instance.new("BillboardGui")
		gui.Name = "DamageHpGui"
		gui.Size = UDim2.fromOffset(110, 26)
		gui.StudsOffset = Vector3.new(0, 2.5, 0)
		gui.AlwaysOnTop = true
		gui.MaxDistance = 45
		gui.Adornee = primary
		gui.Parent = primary

		local textLabel = Instance.new("TextLabel")
		textLabel.Name = "HpLabel"
		textLabel.Size = UDim2.fromScale(1, 1)
		textLabel.BackgroundColor3 = Color3.fromRGB(22, 16, 16)
		textLabel.BackgroundTransparency = 0.25
		textLabel.BorderSizePixel = 0
		textLabel.Font = Enum.Font.GothamBold
		textLabel.TextSize = 12
		textLabel.TextColor3 = Color3.fromRGB(255, 195, 130)
		textLabel.Parent = gui

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 4)
		corner.Parent = textLabel

		label = textLabel
	end

	if label then
		label.Text = string.format("%d / %d HP", math.max(0, math.floor(record.Piece.Hp)), record.MaxHp)
	end
end

local function closestPointOnModel(model: Model, point: Vector3): Vector3
	local bestPoint: Vector3? = nil
	local bestDistSq = math.huge

	for _, desc in model:GetDescendants() do
		if desc:IsA("BasePart") then
			local localPos = desc.CFrame:PointToObjectSpace(point)
			local half = desc.Size * 0.5
			local clamped = Vector3.new(
				math.clamp(localPos.X, -half.X, half.X),
				math.clamp(localPos.Y, -half.Y, half.Y),
				math.clamp(localPos.Z, -half.Z, half.Z)
			)
			local worldClosest = desc.CFrame:PointToWorldSpace(clamped)
			local delta = worldClosest - point
			local distSq = delta.X * delta.X + delta.Y * delta.Y + delta.Z * delta.Z
			if distSq < bestDistSq then
				bestDistSq = distSq
				bestPoint = worldClosest
			end
		end
	end

	if bestPoint ~= nil then
		return bestPoint
	end

	local cf, size = model:GetBoundingBox()
	local localPos = cf:PointToObjectSpace(point)
	local half = size * 0.5
	return cf:PointToWorldSpace(
		Vector3.new(
			math.clamp(localPos.X, -half.X, half.X),
			math.clamp(localPos.Y, -half.Y, half.Y),
			math.clamp(localPos.Z, -half.Z, half.Z)
		)
	)
end

local function costMapToBatch(costMap: { [string]: number }): { ItemBatchEntry }
	local batch: { ItemBatchEntry } = {}
	for itemId, count in costMap do
		if count > 0 then
			table.insert(batch, { Id = itemId, Count = count })
		end
	end
	return batch
end

local function buildRaidHudState(session: RaidSession, statusText: string?): RaidHudState
	local elapsed = os.clock() - session.StartTime
	local timeLeft = math.max(0, math.ceil(session.Duration - elapsed))
	local hackProgress = 0
	if session.TcCaptured then
		hackProgress = 1
	elseif session.TcHackActive then
		hackProgress = math.clamp((os.clock() - session.TcHackStartTime) / Config.Raid.TcHackDuration, 0, 1)
	end
	local extActive = session.ExtractionCountdownActive == true
	local extTotal = if session.ExtractionTotalDuration > 0
		then session.ExtractionTotalDuration
		else Config.Raid.StashExtractionDuration
	local extLeft = 0
	if extActive then
		extLeft = math.max(0, math.ceil(extTotal - (os.clock() - session.ExtractionCountdownStart)))
	end
	local finalStatus = statusText
	if finalStatus == nil and extActive then
		finalStatus = string.format("STASH EXTRACTION: %ds (SIREEN ACTIVE)", extLeft)
	end
	return {
		Active = true,
		TargetName = session.TargetName,
		TargetBaseTier = session.TargetBaseTier,
		TimeLeft = timeLeft,
		StatusText = finalStatus,
		TcCaptured = session.TcCaptured,
		TcHackProgress = hackProgress,
		TcHackActive = session.TcHackActive,
		LivesLeft = session.LivesLeft,
		MaxLives = session.MaxLives,
		StashItemCount = RaidOutpost.CountStashItems(session),
		CanExtract = session.TcCaptured and not extActive,
		ExtractionActive = extActive,
		ExtractionTimeLeft = extLeft,
		ExtractionTotalTime = extTotal,
	}
end

local function syncSessionHud(session: RaidSession, statusText: string?)
	sendRaidHud(session.Raider, buildRaidHudState(session, statusText))
end

local function sendBuildFeedback(player: Player, success: boolean, message: string)
	if player.Parent ~= Players then
		return
	end
	Net.GetEvent(Net.Events.BuildFeedback):FireClient(player, {
		Success = success,
		Message = message,
	})
end

local function deliverDefenseReports(player: Player)
	if player.Parent ~= Players or DataService.GetData(player) == nil then
		return
	end
	local reports = DataService.ConsumeDefenseReports(player)
	for _, report in reports do
		local rewardScrap = if type(report.RewardScrap) == "number" and report.RewardScrap > 0
			then math.floor(report.RewardScrap)
			else 0
		if rewardScrap > 0 then
			BaseService.DepositScrapToToolCupboard(player, rewardScrap)
		end

		if report.BonusItems ~= nil then
			local batch: { ItemBatchEntry } = {}
			for itemId, count in report.BonusItems do
				if count > 0 and not (itemId == "scrap" and rewardScrap > 0) then
					table.insert(batch, { Id = itemId, Count = count })
				end
			end
			if #batch > 0 then
				BaseService.DepositItemsToPlayerBase(player, batch)
			end
		end

		local logEntry: DefenseLogEntry = {
			Id = string.format("def_%d_%d", report.Timestamp, math.random(1000, 9999)),
			RaiderUserId = report.RaiderUserId or 0,
			RaiderName = report.RaiderName,
			TargetTier = report.TargetTier,
			Defended = report.Defended,
			LivesSpent = report.LivesSpent or 0,
			MaxLives = report.MaxLives or Config.Raid.MaxLives,
			RewardScrap = rewardScrap,
			Timestamp = report.Timestamp,
			GhostsShown = false,
			DeathPoints = report.DeathPoints or {},
			Summary = report.Summary,
		}
		DataService.AppendDefenseLog(player, logEntry)
		Net.GetEvent(Net.Events.RaidReportNotify):FireClient(player, report)
	end

	if
		#reports > 0
		and (BaseService.IsBaseMode() or RunService:IsStudio())
		and player:GetAttribute("InRaid") ~= true
	then
		BaseService.SpawnSessionDeathGhosts(player)
	end
end

local function recordDefenseReport(session: RaidSession, defended: boolean, summaryText: string)
	if session.IsSelfRaid or session.TargetUserId <= 0 then
		return
	end
	local tierCfg = Config.Raid.Tiers[session.TargetBaseTier]
	local bonus = if defended and tierCfg ~= nil then tierCfg.DefenseBonus else nil
	local rewardScrap = 0
	local mergedBonus: { [string]: number }? = nil
	if defended then
		local ratioReward = math.floor(session.RaiderSpentScrapValue * Config.Raid.DefenseRewardRatio + 0.5)
		local tierScrap = if bonus ~= nil and bonus.scrap ~= nil then bonus.scrap else 0
		rewardScrap = math.max(tierScrap, ratioReward)

		if bonus ~= nil then
			local copy: { [string]: number } = {}
			for itemId, count in bonus do
				if count > 0 then
					copy[itemId] = count
				end
			end
			mergedBonus = copy
		end

		if not session.StashExtracted then
			local stashBatch, stashTotal = RaidOutpost.CollectStashBatch(session)
			if stashTotal > 0 then
				local targetBonus = mergedBonus or {}
				for _, entry in stashBatch do
					if entry.Count > 0 then
						if entry.Id == "scrap" then
							rewardScrap += entry.Count
						else
							targetBonus[entry.Id] = (targetBonus[entry.Id] or 0) + entry.Count
						end
					end
				end
				mergedBonus = targetBonus
			end
		end
	end
	local deathPointsCopy: { DeathGhostPoint } = {}
	for _, pt in session.DeathPoints do
		table.insert(deathPointsCopy, {
			PosX = pt.PosX,
			PosY = pt.PosY,
			PosZ = pt.PosZ,
			Cause = pt.Cause,
			RaiderName = pt.RaiderName,
		})
	end
	local report: RaidDefenseReport = {
		RaiderUserId = session.Raider.UserId,
		RaiderName = session.Raider.DisplayName,
		TargetTier = session.TargetBaseTier,
		Defended = defended,
		LivesSpent = session.LivesSpent,
		MaxLives = session.MaxLives,
		RewardScrap = rewardScrap,
		DeathPoints = deathPointsCopy,
		Timestamp = os.time(),
		BonusItems = mergedBonus,
		Summary = summaryText,
	}
	DataService.RecordRaidDefenseReport(session.TargetUserId, report)
	local onlineDefender = Players:GetPlayerByUserId(session.TargetUserId)
	if onlineDefender ~= nil and onlineDefender ~= session.Raider then
		deliverDefenseReports(onlineDefender)
	end
end

local function cancelTcHack(session: RaidSession, reason: string?)
	if not session.TcHackActive then
		return
	end
	session.TcHackActive = false
	if session.TcHackPrompt ~= nil and session.TcHackPrompt.Parent ~= nil and not session.TcCaptured then
		session.TcHackPrompt.Enabled = true
		session.TcHackPrompt.ActionText = string.format("Hack / Capture TC (%ds)", Config.Raid.TcHackDuration)
	end
	if reason ~= nil and #reason > 0 then
		sendBuildFeedback(session.Raider, false, reason)
		syncSessionHud(session, reason)
	else
		syncSessionHud(session, nil)
	end
end

local function markTcCaptured(session: RaidSession, statusText: string)
	if session.TcCaptured then
		return
	end
	session.TcCaptured = true
	session.TcHackActive = false

	if session.TcHackPrompt ~= nil and session.TcHackPrompt.Parent ~= nil then
		session.TcHackPrompt:Destroy()
		session.TcHackPrompt = nil
	end

	if session.TcPieceUid ~= nil then
		local tcRecord = session.Pieces[session.TcPieceUid]
		if tcRecord ~= nil and tcRecord.Model.Parent ~= nil and tcRecord.ContainerId == nil then
			local tcCfg = BuildingConfig.Pieces.tool_cupboard
			local storageSlots = if tcCfg and tcCfg.StorageSlots
				then tcCfg.StorageSlots
				else Config.Upkeep.TcStorageSlots
			local initialSlots = storageMapToInventory(tcRecord.Piece.Storage, storageSlots)
			local regId = LootService.RegisterStorageContainer(
				tcRecord.Model,
				string.format("%s's Tool Cupboard", session.TargetName),
				nil,
				storageSlots,
				initialSlots,
				nil,
				false
			)
			if #regId > 0 then
				tcRecord.ContainerId = regId
			end
		end
	end

	if session.ExtractionTerminalPrompt ~= nil and session.ExtractionTerminalPrompt.Parent ~= nil then
		session.ExtractionTerminalPrompt.ActionText = "Extract Loot (TC Captured)"
	end
	if session.ExtractionTerminalIndicator ~= nil and session.ExtractionTerminalIndicator.Parent ~= nil then
		session.ExtractionTerminalIndicator.Color = Color3.fromRGB(60, 225, 110)
	end

	sendBuildFeedback(session.Raider, true, statusText)
	syncSessionHud(session, statusText)
end

local function startTcHack(session: RaidSession)
	if session.TcCaptured or session.TcHackActive or session.Extracting then
		return
	end
	local tcUid = session.TcPieceUid
	if tcUid == nil then
		markTcCaptured(session, "TC Captured — Extract Available")
		return
	end
	local tcRecord = session.Pieces[tcUid]
	if tcRecord == nil or tcRecord.Model.Parent == nil or tcRecord.Model.PrimaryPart == nil then
		markTcCaptured(session, "TC Captured — Extract Available")
		return
	end

	local _, hrp, humanoid = getAliveCharacterParts(session.Raider)
	if hrp == nil or humanoid == nil then
		return
	end
	local tcPos = tcRecord.Model.PrimaryPart.Position
	if (hrp.Position - tcPos).Magnitude > Config.Raid.TcHackMaxDistance + Types.PING_DISTANCE_TOLERANCE then
		sendBuildFeedback(
			session.Raider,
			false,
			"Подойдите ближе к вражескому TC для взлома"
		)
		return
	end

	session.TcHackActive = true
	session.TcHackStartTime = os.clock()
	if session.TcHackPrompt ~= nil and session.TcHackPrompt.Parent ~= nil then
		session.TcHackPrompt.Enabled = false
	end
	sendBuildFeedback(
		session.Raider,
		true,
		string.format("Взлом TC запущен (%d сек)...", Config.Raid.TcHackDuration)
	)
	syncSessionHud(session, nil)

	local hackStartedAt = session.TcHackStartTime
	task.spawn(function()
		while activeSessions[session.Raider] == session and session.TcHackActive and not session.TcCaptured do
			if session.Extracting then
				cancelTcHack(session, nil)
				break
			end
			if session.LastDamagedAt >= hackStartedAt then
				cancelTcHack(session, "Взлом TC прерван: получен урон")
				break
			end
			local curTc = session.Pieces[tcUid]
			if curTc == nil or curTc.Model.Parent == nil or curTc.Model.PrimaryPart == nil then
				markTcCaptured(session, "Enemy TC Destroyed — Extract Available")
				break
			end
			local _, innerHrp, innerHum = getAliveCharacterParts(session.Raider)
			if innerHrp == nil or innerHum == nil then
				cancelTcHack(session, "Взлом TC прерван: игрок погиб")
				break
			end
			if
				(innerHrp.Position - curTc.Model.PrimaryPart.Position).Magnitude
				> Config.Raid.TcHackMaxDistance + Types.PING_DISTANCE_TOLERANCE
			then
				cancelTcHack(session, "Взлом TC прерван: вы отошли от шкафа")
				break
			end
			local elapsed = os.clock() - hackStartedAt
			if elapsed >= Config.Raid.TcHackDuration then
				markTcCaptured(session, "TC Captured — Extract Available")
				break
			end
			syncSessionHud(session, nil)
			task.wait(0.25)
		end
	end)
end

local function destroyRaidPiece(session: RaidSession, uid: string, dropStorageLoot: boolean)
	local record = session.Pieces[uid]
	if record == nil then
		return
	end
	session.Pieces[uid] = nil
	DefenseService.UnregisterDefense(uid)

	local dropPos = if record.Model.PrimaryPart then record.Model.PrimaryPart.Position else session.Origin
	local canonical = BuildingGeometry.CanonicalPieceType(record.Piece.PieceType)

	if record.ContainerId ~= nil then
		local state = if dropStorageLoot then LootService.GetContainerState(record.ContainerId) else nil
		LootService.UnregisterContainer(record.ContainerId)
		if state ~= nil and hasAnySlots(state.Slots, Types.INVENTORY_SIZE) then
			RaidOutpost.SpawnDroppedLootBag(
				session,
				dropPos,
				state.Slots,
				getOrCreateFolder(LOOT_CONTAINERS_FOLDER_NAME)
			)
		end
	elseif dropStorageLoot and record.Piece.Storage ~= nil then
		local fallbackSlots = storageMapToInventory(record.Piece.Storage, Config.Upkeep.TcStorageSlots)
		if hasAnySlots(fallbackSlots, Config.Upkeep.TcStorageSlots) then
			RaidOutpost.SpawnDroppedLootBag(
				session,
				dropPos,
				fallbackSlots,
				getOrCreateFolder(LOOT_CONTAINERS_FOLDER_NAME)
			)
		end
	end

	if record.Model.Parent then
		record.Model:Destroy()
	end

	if dropStorageLoot and canonical == "tool_cupboard" and not session.TcCaptured then
		markTcCaptured(session, "Enemy TC Destroyed — Extract Available")
	end
end

local function stopExtractionSiren(session: RaidSession)
	if session.ExtractionSirenSound ~= nil then
		if session.ExtractionSirenSound.Parent ~= nil then
			session.ExtractionSirenSound:Stop()
			session.ExtractionSirenSound:Destroy()
		end
		session.ExtractionSirenSound = nil
	end
	if session.ExtractionBeaconPart ~= nil then
		if session.ExtractionBeaconPart.Parent ~= nil then
			session.ExtractionBeaconPart:Destroy()
		end
		session.ExtractionBeaconPart = nil
	end
end

local function cleanupSession(session: RaidSession)
	session.ExtractionCountdownActive = false
	stopExtractionSiren(session)
	session.Janitor:Destroy()
	if session.DefenderJanitor ~= nil then
		session.DefenderJanitor:Destroy()
		session.DefenderJanitor = nil
	end
	if session.Defender ~= nil and session.Defender.Parent == Players then
		session.Defender:SetAttribute("DefendingRaid", false)
	end
	session.Defender = nil
	if activeSessionByRaidId[session.RaidId] == session then
		activeSessionByRaidId[session.RaidId] = nil
	end
	if activeSessionByTargetUserId[session.TargetUserId] == session then
		activeSessionByTargetUserId[session.TargetUserId] = nil
	end

	for _, explosive in session.ActiveExplosives do
		explosive.CancelFlag = true
		if explosive.Part.Parent then
			explosive.Part:Destroy()
		end
	end
	table.clear(session.ActiveExplosives)

	local uids: { string } = {}
	for uid in session.Pieces do
		table.insert(uids, uid)
	end
	for _, uid in uids do
		destroyRaidPiece(session, uid, false)
	end

	if session.ExtractionStashContainerId ~= nil then
		LootService.DestroyContainer(session.ExtractionStashContainerId)
		session.ExtractionStashContainerId = nil
	end
	if session.SupplyCrateContainerId ~= nil then
		LootService.DestroyContainer(session.SupplyCrateContainerId)
		session.SupplyCrateContainerId = nil
	end
	if session.OutpostWorkbenchId ~= nil then
		CraftingService.UnregisterStation(session.OutpostWorkbenchId)
		session.OutpostWorkbenchId = nil
	end

	for _, rRecord in session.RaiderPieces do
		if rRecord.Model.Parent then
			rRecord.Model:Destroy()
		end
	end
	table.clear(session.RaiderPieces)
	table.clear(session.RaiderOccupiedSockets)
	table.clear(session.RaiderOccupiedWorldKeys)

	if session.ExtractionStashModel and session.ExtractionStashModel.Parent then
		session.ExtractionStashModel:Destroy()
		session.ExtractionStashModel = nil
	end
	if session.SupplyCrateModel and session.SupplyCrateModel.Parent then
		session.SupplyCrateModel:Destroy()
		session.SupplyCrateModel = nil
	end
	if session.ExtractionTerminalModel and session.ExtractionTerminalModel.Parent then
		session.ExtractionTerminalModel:Destroy()
		session.ExtractionTerminalModel = nil
	end
	if session.OutpostZoneModel and session.OutpostZoneModel.Parent then
		session.OutpostZoneModel:Destroy()
		session.OutpostZoneModel = nil
	end
	if session.ArenaGroundPart and session.ArenaGroundPart.Parent then
		session.ArenaGroundPart:Destroy()
		session.ArenaGroundPart = nil
	end

	for _, containerId in session.DroppedContainerIds do
		LootService.DestroyContainer(containerId)
	end
	table.clear(session.DroppedContainerIds)
end

local function spawnRaidTargetBase(session: RaidSession, baseData: BaseData)
	local folder = getOrCreateFolder(RAID_STRUCTURES_FOLDER_NAME)
	local foundTcUid: string? = nil

	for _, savedPiece in baseData.Pieces do
		local pieceConfig = BuildingConfig.Pieces[savedPiece.PieceType]
		if pieceConfig == nil then
			continue
		end

		local copiedStorage: { [string]: Slot }? = nil
		if type(savedPiece.Storage) == "table" then
			copiedStorage = {}
			for k, s in savedPiece.Storage do
				if type(s) == "table" and type(s.Id) == "string" and type(s.Count) == "number" then
					(copiedStorage :: { [string]: Slot })[k] = { Id = s.Id, Count = s.Count }
				end
			end
		end

		local pieceCopy: SavedBuildPiece = {
			Uid = savedPiece.Uid,
			PieceType = savedPiece.PieceType,
			Tier = savedPiece.Tier,
			PosX = savedPiece.PosX,
			PosY = savedPiece.PosY,
			PosZ = savedPiece.PosZ,
			RotY = savedPiece.RotY,
			AnchorUid = savedPiece.AnchorUid,
			SocketId = savedPiece.SocketId,
			MountSurface = savedPiece.MountSurface,
			Hp = savedPiece.Hp,
			Storage = copiedStorage,
			GridX = savedPiece.GridX,
			GridY = savedPiece.GridY,
			GridZ = savedPiece.GridZ,
		}

		local model, maxHp = createRaidPieceModel(pieceCopy, session.Origin)
		model.Parent = folder

		local canonical = BuildingGeometry.CanonicalPieceType(pieceCopy.PieceType)
		local containerId: string? = nil
		if canonical == "storage_box" then
			local storageSlots = pieceConfig.StorageSlots or 18
			local initialSlots = storageMapToInventory(pieceCopy.Storage, storageSlots)
			local containerTitle = string.format("%s's Chest", session.TargetName)
			local registeredId =
				LootService.RegisterStorageContainer(model, containerTitle, nil, storageSlots, initialSlots, nil, false)
			if #registeredId > 0 then
				containerId = registeredId
			end
		elseif canonical == "tool_cupboard" then
			foundTcUid = pieceCopy.Uid
			local primary = model.PrimaryPart
			if primary then
				local hackPrompt = Instance.new("ProximityPrompt")
				hackPrompt.Name = "TcHackPrompt"
				hackPrompt.ActionText = string.format("Hack / Capture TC (%ds)", Config.Raid.TcHackDuration)
				hackPrompt.ObjectText = string.format("%s's Tool Cupboard", session.TargetName)
				hackPrompt.HoldDuration = 0
				hackPrompt.MaxActivationDistance = Config.Raid.TcHackMaxDistance
				hackPrompt.RequiresLineOfSight = false
				hackPrompt.Parent = primary
				session.TcHackPrompt = hackPrompt
				session.Janitor:Add(hackPrompt.Triggered:Connect(function(triggerPlayer: Player)
					if triggerPlayer == session.Raider then
						startTcHack(session)
					end
				end))
			end
		elseif Defenses.Get(canonical) ~= nil then
			local worldCF = BuildingGeometry.GetPieceWorldCFrame(pieceCopy, session.Origin)
			DefenseService.RegisterDefense({
				Uid = pieceCopy.Uid,
				PieceType = canonical,
				Model = model,
				BaseWorldCF = worldCF,
				OwnerUserId = session.TargetUserId,
				IsRaidInstance = true,
				IsQaTest = false,
				InfiniteAmmo = session.IsSelfRaid,
				AllowOwnerTarget = session.IsSelfRaid,
				PieceRef = pieceCopy,
				Hp = pieceCopy.Hp,
				MaxHp = maxHp,
				OnSelfDamage = function(defUid: string, dmg: number)
					RaidService.DamageRaidPiece(defUid, dmg, "Tool", nil)
				end,
				OnSelfDestroy = function(defUid: string)
					destroyRaidPiece(session, defUid, false)
				end,
			})
		end

		session.Pieces[pieceCopy.Uid] = {
			Piece = pieceCopy,
			Model = model,
			ContainerId = containerId,
			MaxHp = maxHp,
		}
	end

	session.TcPieceUid = foundTcUid
	if foundTcUid == nil then
		session.TcCaptured = true
	end
end

local function teleportCharacterToPosition(player: Player, targetPos: Vector3)
	local character = player.Character
	if not character then
		return
	end
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if hrp and hrp:IsA("BasePart") then
		hrp.AssemblyLinearVelocity = Vector3.zero
		hrp.CFrame = CFrame.new(targetPos)
	else
		character:PivotTo(CFrame.new(targetPos))
	end
end

local function isCharacterInvulnerable(charModel: Model): boolean
	return charModel:GetAttribute("RaidInvulnerable") == true or charModel:FindFirstChildOfClass("ForceField") ~= nil
end

local function applySpawnProtection(character: Model)
	local existingField = character:FindFirstChild("RaidSpawnProtection")
	if existingField then
		existingField:Destroy()
	end
	local ff = Instance.new("ForceField")
	ff.Name = "RaidSpawnProtection"
	ff.Visible = true
	ff.Parent = character
	character:SetAttribute("RaidInvulnerable", true)

	task.delay(Config.Raid.SpawnInvulnerabilityDuration, function()
		if ff.Parent ~= nil then
			ff:Destroy()
		end
		if character.Parent ~= nil then
			character:SetAttribute("RaidInvulnerable", false)
		end
	end)
end

local function getDefaultSpawnPosition(): Vector3
	local spawnLoc = Workspace:FindFirstChildOfClass("SpawnLocation")
	if spawnLoc then
		return spawnLoc.Position + Vector3.new(0, 4, 0)
	end
	return Vector3.new(0, 6, 0)
end

local function restoreSelfRaidInventory(player: Player, session: RaidSession)
	if session.IsSelfRaid and session.SavedInventorySnapshot ~= nil then
		local snapshot = session.SavedInventorySnapshot
		session.SavedInventorySnapshot = nil
		if DataService.GetData(player) ~= nil then
			InventoryService.RestoreSnapshot(player, snapshot)
		end
	end
	if player.Parent == Players then
		player:SetAttribute("InSelfRaid", false)
	end
end

local function finishSelfRaidReturn(player: Player, session: RaidSession, statusText: string?)
	restoreSelfRaidInventory(player, session)
	activeSessions[player] = nil
	cleanupSession(session)
	if player.Parent == Players then
		player:SetAttribute("InRaid", false)
		player:SetAttribute("InSelfRaid", false)
	end
	SecurityService.SetTeleportLock(player, false)

	local returnPos = session.ReturnPosition or getDefaultSpawnPosition()
	teleportCharacterToPosition(player, returnPos)

	sendRaidHud(player, {
		Active = false,
		TargetName = session.TargetName,
		TargetBaseTier = session.TargetBaseTier,
		TimeLeft = 0,
		StatusText = statusText,
	})
end

local function completeStudioReturn(player: Player, session: RaidSession, statusText: string?)
	if session.IsSelfRaid then
		finishSelfRaidReturn(player, session, statusText)
		return
	end
	returnDefenderAfterRaid(session, statusText)
	DataService.ReleaseForTeleport(player)
	DataService.RestoreAfterFailedTeleport(player)

	activeSessions[player] = nil
	cleanupSession(session)
	player:SetAttribute("InRaid", false)
	SecurityService.SetTeleportLock(player, false)

	local returnPos = session.ReturnPosition or getDefaultSpawnPosition()
	teleportCharacterToPosition(player, returnPos)

	sendRaidHud(player, {
		Active = false,
		TargetName = session.TargetName,
		TargetBaseTier = session.TargetBaseTier,
		TimeLeft = 0,
		StatusText = statusText,
	})
end

local function finishRaidSession(player: Player, statusText: string?, delayForRespawn: boolean?)
	local session = activeSessions[player]
	if session == nil or session.Extracting then
		return
	end
	session.Extracting = true
	session.ExtractionCountdownActive = false
	stopExtractionSiren(session)
	cancelTcHack(session, nil)
	for uid in session.Pieces do
		DefenseService.UnregisterDefense(uid)
	end
	CraftingService.CancelCraftForPlayer(player, true, false)
	SecurityService.SetTeleportLock(player, true)
	LootService.CloseContainerForPlayer(player, true)

	if session.IsStudioMock then
		if delayForRespawn then
			session.PendingReturnOnRespawn = true
			sendRaidHud(player, {
				Active = true,
				TargetName = session.TargetName,
				TargetBaseTier = session.TargetBaseTier,
				TimeLeft = 0,
				StatusText = statusText or "Raid failed — returning to PlayerBase...",
				TcCaptured = session.TcCaptured,
				LivesLeft = session.LivesLeft,
				MaxLives = session.MaxLives,
				StashItemCount = 0,
				CanExtract = false,
			})
			task.delay(6.0, function()
				if activeSessions[player] == session and session.PendingReturnOnRespawn then
					session.PendingReturnOnRespawn = false
					completeStudioReturn(player, session, statusText)
				end
			end)
			return
		end
		completeStudioReturn(player, session, statusText)
		return
	end

	returnDefenderAfterRaid(session, statusText)

	if teleportInProgress[player] then
		session.Extracting = false
		SecurityService.SetTeleportLock(player, false)
		return
	end
	teleportInProgress[player] = true

	sendRaidHud(player, {
		Active = true,
		TargetName = session.TargetName,
		TargetBaseTier = session.TargetBaseTier,
		TimeLeft = 0,
		StatusText = statusText or "Returning to PlayerBase...",
		TcCaptured = session.TcCaptured,
		LivesLeft = session.LivesLeft,
		MaxLives = session.MaxLives,
		StashItemCount = RaidOutpost.CountStashItems(session),
		CanExtract = false,
	})

	local released = DataService.ReleaseForTeleport(player)
	if not released then
		warn(string.format("[RaidService] Failed to release profile after raid for %s", player.Name))
		DataService.RestoreAfterFailedTeleport(player)
		teleportInProgress[player] = nil
		session.Extracting = false
		SecurityService.SetTeleportLock(player, false)
		return
	end

	if player.Parent ~= Players then
		activeSessions[player] = nil
		cleanupSession(session)
		teleportInProgress[player] = nil
		SecurityService.SetTeleportLock(player, false)
		return
	end

	local options = Instance.new("TeleportOptions")
	options:SetTeleportData({
		FromPlaceId = game.PlaceId,
		OwnerUserId = player.UserId,
		RaiderUserId = player.UserId,
		Mode = "Base",
	})

	pendingTeleports[player] = {
		TargetPlaceId = Config.Places.PlayerBase,
		Options = options,
		IsReturningToMap = true,
		TargetName = session.TargetName,
	}

	local ok, err = pcall(function()
		TeleportService:TeleportAsync(Config.Places.PlayerBase, { player }, options)
	end)
	if not ok then
		warn(string.format("[RaidService] Return TeleportAsync error for %s: %s", player.Name, tostring(err)))
		pendingTeleports[player] = nil
		teleportInProgress[player] = nil
		session.Extracting = false
		SecurityService.SetTeleportLock(player, false)
		DataService.RestoreAfterFailedTeleport(player)
	end
end

local function failRaidSession(player: Player, reason: string, delayForRespawn: boolean?)
	local session = activeSessions[player]
	if session == nil or session.Extracting then
		return
	end
	recordDefenseReport(session, true, string.format("%s's raid failed (%s)", player.DisplayName, reason))
	finishRaidSession(player, reason, delayForRespawn)
end

local function cancelStashExtraction(session: RaidSession, reason: string?)
	if not session.ExtractionCountdownActive then
		return
	end
	session.ExtractionCountdownActive = false
	stopExtractionSiren(session)

	if session.ExtractionTerminalPrompt ~= nil and session.ExtractionTerminalPrompt.Parent ~= nil then
		session.ExtractionTerminalPrompt.Enabled = true
	end
	if session.StashExtractPrompt ~= nil and session.StashExtractPrompt.Parent ~= nil then
		session.StashExtractPrompt.Enabled = true
	end
	if session.ExtractionTerminalIndicator ~= nil and session.ExtractionTerminalIndicator.Parent ~= nil then
		session.ExtractionTerminalIndicator.Color = if session.TcCaptured
			then Color3.fromRGB(60, 225, 110)
			else Color3.fromRGB(220, 140, 45)
	end

	if reason ~= nil and #reason > 0 then
		sendBuildFeedback(session.Raider, false, reason)
		syncSessionHud(session, reason)
	else
		syncSessionHud(session, nil)
	end
end

local function completeStashExtraction(session: RaidSession)
	local player = session.Raider
	if activeSessions[player] ~= session or session.Extracting then
		return
	end
	local _, hrp, hum = getAliveCharacterParts(player)
	if hrp == nil or hum == nil then
		cancelStashExtraction(
			session,
			"Экстракция прервана: рейдер погиб! Лут остался в ExtractionStash"
		)
		return
	end
	if
		teleportInProgress[player]
		or DataService.IsTransferLocked(player)
		or SecurityService.IsTeleportLocked(player)
		or SecurityService.IsTransactionLocked(player)
	then
		cancelStashExtraction(session, nil)
		return
	end
	if DataService.GetData(player) == nil or not session.TcCaptured then
		cancelStashExtraction(session, nil)
		return
	end
	if not RaidOutpost.IsRaiderInExtractionZone(session, hrp) then
		cancelStashExtraction(
			session,
			"Экстракция прервана: вы покинули зону RaidOutpostZone!"
		)
		return
	end
	if (os.clock() - session.ExtractionCountdownStart) < (session.ExtractionTotalDuration - 0.05) then
		return
	end

	session.ExtractionCountdownActive = false
	stopExtractionSiren(session)

	local totalCount = 0
	local extractedItems: { ItemBatchEntry } = {}
	local lockOk = SecurityService.RunLocked(player, "RaidExtract", function()
		if activeSessions[player] ~= session or session.Extracting then
			return
		end
		if
			DataService.IsTransferLocked(player)
			or SecurityService.IsTeleportLocked(player)
			or DataService.GetData(player) == nil
			or not session.TcCaptured
		then
			return
		end
		local _, innerHrp, innerHum = getAliveCharacterParts(player)
		if innerHrp == nil or innerHum == nil or not RaidOutpost.IsRaiderInExtractionZone(session, innerHrp) then
			return
		end
		if not session.StashExtracted then
			if session.IsSelfRaid then
				extractedItems, totalCount = RaidOutpost.CollectStashBatch(session)
				session.StashExtracted = true
				if session.ExtractionStashContainerId ~= nil then
					LootService.ClearContainerSlots(session.ExtractionStashContainerId)
				end
			else
				extractedItems, totalCount = RaidOutpost.CollectStashBatch(session)
				if #extractedItems > 0 then
					BaseService.DepositItemsToPlayerBase(player, extractedItems)
				end
				session.StashExtracted = true
				if session.ExtractionStashContainerId ~= nil then
					LootService.ClearContainerSlots(session.ExtractionStashContainerId)
				end
			end
		end
	end)
	if not lockOk or not session.StashExtracted then
		return
	end

	recordDefenseReport(
		session,
		false,
		string.format("%s captured TC and extracted (%d stash items)", player.DisplayName, totalCount)
	)
	finishRaidSession(
		player,
		string.format("Extracted to PlayerBase! Saved %d items from ExtractionStash", totalCount),
		false
	)
end

local function startStashExtraction(session: RaidSession)
	if session.ExtractionCountdownActive or session.Extracting then
		return
	end
	local totalDuration = Config.Raid.StashExtractionDuration
	session.ExtractionCountdownActive = true
	session.ExtractionCountdownStart = os.clock()
	session.ExtractionTotalDuration = totalDuration

	if session.ExtractionTerminalPrompt ~= nil and session.ExtractionTerminalPrompt.Parent ~= nil then
		session.ExtractionTerminalPrompt.Enabled = false
	end
	if session.StashExtractPrompt ~= nil and session.StashExtractPrompt.Parent ~= nil then
		session.StashExtractPrompt.Enabled = false
	end
	if session.ExtractionTerminalIndicator ~= nil and session.ExtractionTerminalIndicator.Parent ~= nil then
		session.ExtractionTerminalIndicator.Color = Color3.fromRGB(255, 55, 55)
	end

	stopExtractionSiren(session)
	local anchorPart: BasePart? = nil
	if session.ExtractionStashModel ~= nil and session.ExtractionStashModel.PrimaryPart ~= nil then
		anchorPart = session.ExtractionStashModel.PrimaryPart
	elseif session.ExtractionTerminalIndicator ~= nil and session.ExtractionTerminalIndicator.Parent ~= nil then
		anchorPart = session.ExtractionTerminalIndicator
	end
	if anchorPart ~= nil then
		local siren = Instance.new("Sound")
		siren.Name = "ExtractionAlarmSiren"
		siren.SoundId = EXTRACTION_SIREN_SOUND_ID
		siren.Looped = true
		siren.Volume = 0.85
		siren.PlaybackSpeed = 1.15
		siren.RollOffMinDistance = 20
		siren.RollOffMaxDistance = 500
		siren.Parent = anchorPart
		siren:Play()
		session.ExtractionSirenSound = siren

		local beacon = Instance.new("Part")
		beacon.Name = "ExtractionSirenBeacon"
		beacon.Shape = Enum.PartType.Ball
		beacon.Size = Vector3.new(1.5, 1.5, 1.5)
		beacon.CFrame = CFrame.new(anchorPart.Position + Vector3.new(0, 3.8, 0))
		beacon.Anchored = true
		beacon.CanCollide = false
		beacon.CanQuery = false
		beacon.CanTouch = false
		beacon.CastShadow = false
		beacon.Material = Enum.Material.Neon
		beacon.Color = Color3.fromRGB(255, 55, 55)
		beacon.Transparency = 0.1
		beacon.Parent = anchorPart.Parent
		session.ExtractionBeaconPart = beacon
	end

	local startMsg = string.format(
		"Экстракция Stash запущена (%d сек) — сирена активна, оставайтесь в живых!",
		totalDuration
	)
	sendBuildFeedback(session.Raider, true, startMsg)
	syncSessionHud(session, string.format("STASH EXTRACTION: %ds", totalDuration))

	local startedAt = session.ExtractionCountdownStart
	local nextRouteLogAt = startedAt
	local loggedRoutePoints = 0
	task.spawn(function()
		while
			activeSessions[session.Raider] == session
			and session.ExtractionCountdownActive
			and session.ExtractionCountdownStart == startedAt
			and not session.Extracting
		do
			local _, curHrp, curHum = getAliveCharacterParts(session.Raider)
			if curHrp == nil or curHum == nil then
				cancelStashExtraction(
					session,
					"Экстракция прервана: рейдер погиб! Лут остался в ExtractionStash"
				)
				break
			end
			if
				teleportInProgress[session.Raider]
				or DataService.IsTransferLocked(session.Raider)
				or SecurityService.IsTeleportLocked(session.Raider)
			then
				cancelStashExtraction(session, nil)
				break
			end
			if not RaidOutpost.IsRaiderInExtractionZone(session, curHrp) then
				cancelStashExtraction(
					session,
					"Экстракция прервана: вы покинули зону RaidOutpostZone!"
				)
				break
			end

			local now = os.clock()
			if not session.IsSelfRaid and now >= nextRouteLogAt and loggedRoutePoints < 12 then
				nextRouteLogAt = now + Config.Raid.ExtractionRouteLogInterval
				loggedRoutePoints += 1
				local localOffset = curHrp.Position - session.Origin
				table.insert(session.DeathPoints, {
					PosX = localOffset.X,
					PosY = localOffset.Y,
					PosZ = localOffset.Z,
					Cause = "Extraction Route",
					RaiderName = session.Raider.DisplayName,
				})
			end

			if session.ExtractionBeaconPart ~= nil and session.ExtractionBeaconPart.Parent ~= nil then
				local blink = math.floor(now * 4) % 2 == 0
				session.ExtractionBeaconPart.Color = if blink
					then Color3.fromRGB(255, 45, 45)
					else Color3.fromRGB(255, 190, 50)
				session.ExtractionBeaconPart.Transparency = if blink then 0.05 else 0.55
			end

			local elapsed = now - startedAt
			if elapsed >= totalDuration then
				completeStashExtraction(session)
				break
			end
			local remaining = math.max(1, math.ceil(totalDuration - elapsed))
			syncSessionHud(session, string.format("STASH EXTRACTION: %ds", remaining))
			task.wait(0.25)
		end
	end)
end

local function tryExtractFromRaid(player: Player)
	local session = activeSessions[player]
	if session == nil or session.Extracting or session.ExtractionCountdownActive then
		return
	end
	if
		teleportInProgress[player]
		or SecurityService.IsTeleportLocked(player)
		or SecurityService.IsTransactionLocked(player)
	then
		return
	end
	if DataService.GetData(player) == nil then
		return
	end
	local _, hrp = getAliveCharacterParts(player)
	if hrp == nil then
		return
	end
	if not session.TcCaptured then
		sendBuildFeedback(
			player,
			false,
			"Сначала захватите или уничтожьте вражеский TC!"
		)
		return
	end
	if not RaidOutpost.IsRaiderInExtractionZone(session, hrp) then
		sendBuildFeedback(
			player,
			false,
			"Вернитесь к терминалу эвакуации в рейд-кибитке!"
		)
		return
	end

	startStashExtraction(session)
end

getExplosionDeps = function(): RaidExplosives.ExplosionDeps
	return {
		ActiveSessions = activeSessions,
		ClosestPointOnModel = closestPointOnModel,
		DestroyRaidPiece = destroyRaidPiece,
		UpdatePieceDamageBillboard = updatePieceDamageBillboard,
		IsCharacterInvulnerable = isCharacterInvulnerable,
		NotifyRaiderDamaged = RaidService.NotifyRaiderDamaged,
	}
end

getOutpostDeps = function(): RaidOutpost.OutpostDeps
	return {
		GetOrCreateFolder = getOrCreateFolder,
		ActiveSessions = activeSessions,
		SyncSessionHud = syncSessionHud,
		TryExtractFromRaid = tryExtractFromRaid,
		FailRaidSession = failRaidSession,
	}
end

local function bindRaiderCharacter(session: RaidSession, character: Model)
	if activeSessions[session.Raider] ~= session then
		return
	end
	if session.PendingReturnOnRespawn then
		session.PendingReturnOnRespawn = false
		task.defer(function()
			if activeSessions[session.Raider] == session then
				completeStudioReturn(session.Raider, session, "All raid lives lost — returned to PlayerBase")
			end
		end)
		return
	end

	local humanoidInst = character:WaitForChild("Humanoid", 5)
	if not humanoidInst or not humanoidInst:IsA("Humanoid") then
		return
	end
	local humanoid = humanoidInst :: Humanoid
	local prevHealth = humanoid.Health
	local diedHandled = false

	session.Janitor:Add(humanoid.HealthChanged:Connect(function(newHp: number)
		if activeSessions[session.Raider] ~= session then
			return
		end
		if newHp < prevHealth - 0.1 then
			session.LastDamagedAt = os.clock()
			cancelTcHack(session, "Взлом TC прерван: получен урон")
		end
		prevHealth = newHp
	end))

	session.Janitor:Add(humanoid.Died:Connect(function()
		if diedHandled or activeSessions[session.Raider] ~= session or session.Extracting then
			return
		end
		diedHandled = true
		cancelTcHack(session, nil)
		if session.ExtractionCountdownActive then
			cancelStashExtraction(
				session,
				"Экстракция прервана: рейдер погиб! Лут остался в ExtractionStash"
			)
		end
		session.LivesSpent += 1
		if not session.IsSelfRaid then
			local hrp = character:FindFirstChild("HumanoidRootPart")
			local deathPos = if hrp and hrp:IsA("BasePart") then hrp.Position else character:GetPivot().Position
			if
				not BuildingValidator.IsPointInRaidOutpostOrBuffer(
					deathPos,
					Config.Raid.OutpostGhostBufferMargin,
					session.OutpostOrigin
				)
			then
				local causeAttr = character:GetAttribute("LastDamageSource")
				local causeText = if typeof(causeAttr) == "string" and #causeAttr > 0
					then causeAttr
					else "Killed during Raid"
				local localOffset = deathPos - session.Origin
				table.insert(session.DeathPoints, {
					PosX = localOffset.X,
					PosY = localOffset.Y,
					PosZ = localOffset.Z,
					Cause = causeText,
					RaiderName = session.Raider.DisplayName,
				})
			end
		end
		session.LivesLeft = math.max(0, session.LivesLeft - 1)
		if session.LivesLeft > 0 then
			local msg = string.format(
				"Погиб! Быстрое возрождение в кибитке (жизней: %d/%d)",
				session.LivesLeft,
				session.MaxLives
			)
			sendBuildFeedback(session.Raider, false, msg)
			syncSessionHud(session, msg)
			local deadCharacter = character
			task.delay(Config.Raid.RespawnDelay, function()
				if
					activeSessions[session.Raider] == session
					and not session.Extracting
					and session.LivesLeft > 0
					and session.Raider.Parent == Players
					and session.Raider.Character == deadCharacter
				then
					session.Raider:LoadCharacter()
				end
			end)
		else
			failRaidSession(
				session.Raider,
				"Потрачены все жизни — лут в ExtractionStash сгорел",
				true
			)
		end
	end))
end

local function bindRaiderLifecycle(session: RaidSession)
	local player = session.Raider
	if player.Character ~= nil then
		task.spawn(bindRaiderCharacter, session, player.Character)
	end
	session.Janitor:Add(player.CharacterAdded:Connect(function(newChar: Model)
		if activeSessions[player] ~= session then
			return
		end
		task.spawn(bindRaiderCharacter, session, newChar)
		if not session.Extracting and session.LivesLeft > 0 then
			applySpawnProtection(newChar)
			task.spawn(function()
				local hrp = newChar:WaitForChild("HumanoidRootPart", 2)
				task.wait()
				if
					hrp ~= nil
					and activeSessions[player] == session
					and not session.Extracting
					and player.Character == newChar
				then
					teleportCharacterToPosition(player, session.RespawnPosition)
					syncSessionHud(session, "Возрождение в рейд-кибитке (защита 2с)")
				end
			end)
		end
	end))
end

local function startSessionTimerLoop(session: RaidSession)
	task.spawn(function()
		while activeSessions[session.Raider] == session and session.Raider.Parent == Players do
			if session.Extracting then
				break
			end
			local elapsed = os.clock() - session.StartTime
			syncSessionHud(session, nil)
			if elapsed >= session.Duration then
				failRaidSession(session.Raider, "Raid timer expired — Extraction Stash lost!", false)
				break
			end
			task.wait(1)
		end
	end)
end

function RaidService.HasExplosionLineOfSight(
	blastOrigin: Vector3,
	targetModel: Model,
	excludeInstances: { Instance }?,
	isCharacterTarget: boolean?
): boolean
	return RaidExplosives.HasExplosionLineOfSight(blastOrigin, targetModel, excludeInstances, isCharacterTarget)
end

function RaidService.TriggerExplosion(params: ExplosionParams): ExplosionResult
	return RaidExplosives.TriggerExplosion(params, getExplosionDeps())
end

function RaidService.TriggerEmpPulse(
	origin: Vector3,
	radius: number,
	duration: number,
	attacker: Player?,
	projectileId: string?
): number
	return RaidExplosives.TriggerEmpPulse(origin, radius, duration, attacker, projectileId)
end

function RaidService.TriggerSmokeCloud(
	origin: Vector3,
	duration: number,
	attacker: Player?,
	projectileId: string?
): Model?
	return RaidExplosives.TriggerSmokeCloud(origin, duration, attacker, projectileId)
end

function RaidService.NotifyRaiderDamaged(player: Player)
	local session = activeSessions[player]
	if session == nil then
		return
	end
	session.LastDamagedAt = os.clock()
	cancelTcHack(session, "Взлом TC прерван: получен урон")
end

function RaidService.DamageRaidPiece(
	uid: string,
	rawDamage: number,
	damageKind: string,
	_attacker: Player?
): (boolean, boolean)
	if not SecurityService.IsFiniteNumber(rawDamage) or rawDamage <= 0 then
		return false, false
	end

	for _, session in activeSessions do
		local record = session.Pieces[uid]
		if record ~= nil and record.Model.Parent ~= nil then
			if not session.AlarmTriggered and not session.IsSelfRaid and session.TargetUserId > 0 then
				triggerActiveRaidAlarm(session)
			end
			local tierCfg = BuildingConfig.Tiers[record.Piece.Tier] or BuildingConfig.Tiers.wood
			local finalDamage: number
			if damageKind == "Explosion" then
				finalDamage = BuildingConfig.ComputeExplosionDamage(
					rawDamage,
					record.Piece.PieceType,
					record.Piece.Tier,
					record.Model:GetAttribute("HasDoor") == true
				)
			else
				finalDamage = math.max(1, math.floor(rawDamage * tierCfg.ToolDamageMultiplier + 0.5))
			end
			local nowClock = os.clock()
			record.Piece.Hp -= finalDamage
			record.Piece.LastDamagedAt = nowClock
			record.Model:SetAttribute("LastDamagedAt", nowClock)
			record.Model:SetAttribute("LastDamagedServerTime", Workspace:GetServerTimeNow())
			if record.Piece.Hp <= 0 then
				destroyRaidPiece(session, uid, true)
				local remainingPieces: { SavedBuildPiece } = {}
				for _, rec in session.Pieces do
					table.insert(remainingPieces, rec.Piece)
				end
				for _, unsupportedUid in BuildingValidator.FindUnsupportedPieces(remainingPieces, nil) do
					if session.Pieces[unsupportedUid] ~= nil then
						destroyRaidPiece(session, unsupportedUid, true)
					end
				end
				return true, true
			else
				record.Model:SetAttribute("Health", record.Piece.Hp)
				record.Model:SetAttribute("Hp", record.Piece.Hp)
				DefenseService.UpdateDefenseHp(uid, record.Piece.Hp, nil)
				BuildingGeometry.ApplyWearVisuals(
					record.Model,
					record.Piece.PieceType,
					record.Piece.Tier,
					record.Piece.Hp,
					record.MaxHp
				)
				updatePieceDamageBillboard(record)
				return true, false
			end
		end
	end

	return false, false
end

local function canUseRaidTerminal(player: Player): boolean
	if Workspace:GetAttribute("RaidServerMode") == true or activeSessions[player] ~= nil then
		return false
	end
	if RunService:IsStudio() then
		return true
	end
	return game.PlaceId == Config.Places.PlayerBase or game.PlaceId == Config.Places.MainMap
end

local function formatCostRequirementText(costMap: { [string]: number }): string
	local parts: { string } = {}
	for itemId, amount in costMap do
		if amount > 0 then
			local itemCfg = Items[itemId]
			table.insert(parts, string.format("%d %s", amount, if itemCfg ~= nil then itemCfg.Name else itemId))
		end
	end
	table.sort(parts)
	return table.concat(parts, ", ")
end

function RaidService.GetIntelPool(player: Player, tier: number): RaidIntelPool
	return RaidIntel.GetIntelPool(player, tier)
end

function RaidService.RefreshIntelPool(player: Player, tier: number, paid: boolean): (boolean, string, RaidIntelPool?)
	return RaidIntel.RefreshIntelPool(player, tier, paid)
end

local function onRaidListRequest(player: Player, tierAny: any)
	if not SecurityService.CheckRateLimit(player, Net.Events.RaidListRequest) then
		return
	end
	if not canUseRaidTerminal(player) then
		return
	end
	if DataService.IsTeleporting(player) or SecurityService.IsTransactionLocked(player) then
		return
	end
	if DataService.GetData(player) == nil then
		return
	end
	local _, hrp = getAliveCharacterParts(player)
	if hrp == nil or not isNearRaidTerminal(hrp) then
		return
	end

	local now = os.clock()
	local prev = lastListRequest[player]
	if prev ~= nil and (now - prev) < LIST_COOLDOWN then
		return
	end
	lastListRequest[player] = now

	local requestedTier = if SecurityService.IsValidInteger(tierAny, 1, 3)
		then math.floor(tierAny :: number)
		else math.clamp(BaseService.GetPlayerBaseTier(player), 1, 3)
	local pool = RaidIntel.GetIntelPool(player, requestedTier)
	if player.Parent == Players then
		Net.GetEvent(Net.Events.RaidListSync):FireClient(player, pool)
	end
end

local function onRaidRefreshRequest(player: Player, tierAny: any, paidAny: any)
	if not SecurityService.CheckRateLimit(player, Net.Events.RaidRefreshRequest) then
		return
	end
	if not canUseRaidTerminal(player) then
		return
	end
	if DataService.IsTeleporting(player) or SecurityService.IsTransactionLocked(player) then
		return
	end
	if DataService.GetData(player) == nil then
		return
	end
	local _, hrp = getAliveCharacterParts(player)
	if hrp == nil or not isNearRaidTerminal(hrp) then
		return
	end

	local requestedTier = if SecurityService.IsValidInteger(tierAny, 1, 3)
		then math.floor(tierAny :: number)
		else math.clamp(BaseService.GetPlayerBaseTier(player), 1, 3)
	local isPaid = (paidAny == true)
	local ok, msg, pool = RaidService.RefreshIntelPool(player, requestedTier, isPaid)
	sendBuildFeedback(player, ok, msg)
	if pool ~= nil and player.Parent == Players then
		Net.GetEvent(Net.Events.RaidListSync):FireClient(player, pool)
	end
end

local function onStartRaidRequest(player: Player, targetUserIdAny: any)
	if not SecurityService.CheckRateLimit(player, Net.Events.StartRaidRequest) then
		return
	end
	if not canUseRaidTerminal(player) then
		return
	end
	if activeSessions[player] ~= nil or teleportInProgress[player] or SecurityService.IsTeleportLocked(player) then
		return
	end
	if DataService.GetData(player) == nil then
		return
	end
	if not SecurityService.IsValidInteger(targetUserIdAny) then
		return
	end

	local _, hrp = getAliveCharacterParts(player)
	if hrp == nil or not isNearRaidTerminal(hrp) then
		return
	end

	local targetUserId = math.floor(targetUserIdAny :: number)
	if targetUserId == player.UserId then
		return
	end
	local presetTier = DataService.GetPresetTier(targetUserId)
	if targetUserId <= 0 and presetTier == nil then
		return
	end

	local targetName = RaidIntel.ResolveTargetName(targetUserId)
	local targetBaseTier = RaidIntel.ResolveTargetTier(targetUserId)
	local attackerBaseTier = BaseService.GetPlayerBaseTier(player)
	if attackerBaseTier < targetBaseTier then
		local msg = string.format(
			"Для рейда на базу Tier %d требуется собственная база Tier %d (сейчас Tier %d)",
			targetBaseTier,
			targetBaseTier,
			attackerBaseTier
		)
		Net.GetEvent(Net.Events.BuildFeedback):FireClient(player, {
			Success = false,
			Message = msg,
			BaseTier = attackerBaseTier,
		})
		sendRaidHud(player, {
			Active = false,
			TargetName = targetName,
			TargetBaseTier = targetBaseTier,
			TimeLeft = 0,
			StatusText = msg,
		})
		return
	end

	local tierCfg = Config.Raid.Tiers[targetBaseTier]
	local launchCostMap = if tierCfg ~= nil then tierCfg.LaunchCost else {}
	local launchCostBatch = costMapToBatch(launchCostMap)
	local paidLaunchCost = false

	SecurityService.RunLocked(player, "StartRaid", function()
		if activeSessions[player] ~= nil or teleportInProgress[player] or DataService.GetData(player) == nil then
			return
		end
		if #launchCostBatch > 0 then
			if not InventoryService.HasItems(player, launchCostBatch) then
				local reqText = formatCostRequirementText(launchCostMap)
				local msg = string.format(
					"Недостаточно ресурсов для запуска рейда Tier %d (%s)",
					targetBaseTier,
					reqText
				)
				sendBuildFeedback(player, false, msg)
				sendRaidHud(player, {
					Active = false,
					TargetName = targetName,
					TargetBaseTier = targetBaseTier,
					TimeLeft = 0,
					StatusText = msg,
				})
				return
			end
			if not InventoryService.RemoveItems(player, launchCostBatch) then
				sendBuildFeedback(
					player,
					false,
					"Не удалось списать стоимость запуска рейда"
				)
				return
			end
		end
		paidLaunchCost = true
	end)

	if not paidLaunchCost then
		return
	end

	local launchScrapValue = if launchCostMap.scrap ~= nil then math.floor(launchCostMap.scrap) else 0
	teleportInProgress[player] = true
	SecurityService.SetTeleportLock(player, true)
	LootService.CloseContainerForPlayer(player, true)
	BaseService.ClearSessionGhosts(player)

	if RunService:IsStudio() then
		DataService.ReleaseForTeleport(player)
		DataService.RestoreAfterFailedTeleport(player)
		teleportInProgress[player] = nil
		SecurityService.SetTeleportLock(player, false)

		if player.Parent == Players and DataService.GetData(player) ~= nil then
			local entered = RaidService.EnterStudioMockRaid(player, targetUserId, launchScrapValue)
			if not entered and #launchCostBatch > 0 then
				InventoryService.AddItems(player, launchCostBatch)
			end
		elseif #launchCostBatch > 0 then
			InventoryService.AddItems(player, launchCostBatch)
		end
		return
	end

	task.spawn(function()
		sendRaidHud(player, {
			Active = true,
			TargetName = targetName,
			TargetBaseTier = targetBaseTier,
			TimeLeft = RAID_DURATION,
			StatusText = "Reserving raid server...",
		})

		local released = DataService.ReleaseForTeleport(player)
		if not released then
			warn(string.format("[RaidService] Failed to release profile before raid for %s", player.Name))
			DataService.RestoreAfterFailedTeleport(player)
			if #launchCostBatch > 0 then
				InventoryService.AddItems(player, launchCostBatch)
			end
			teleportInProgress[player] = nil
			SecurityService.SetTeleportLock(player, false)
			sendRaidHud(player, {
				Active = false,
				TargetName = targetName,
				TargetBaseTier = targetBaseTier,
				TimeLeft = 0,
				StatusText = "Raid failed: save timeout",
			})
			return
		end

		if player.Parent ~= Players then
			teleportInProgress[player] = nil
			SecurityService.SetTeleportLock(player, false)
			return
		end

		local okReserve, accessCode = pcall(function()
			return TeleportService:ReserveServer(Config.Places.PlayerBase)
		end)
		if not okReserve or type(accessCode) ~= "string" or #accessCode == 0 then
			warn(string.format("[RaidService] ReserveServer failed for %s: %s", player.Name, tostring(accessCode)))
			DataService.RestoreAfterFailedTeleport(player)
			if #launchCostBatch > 0 then
				InventoryService.AddItems(player, launchCostBatch)
			end
			teleportInProgress[player] = nil
			SecurityService.SetTeleportLock(player, false)
			sendRaidHud(player, {
				Active = false,
				TargetName = targetName,
				TargetBaseTier = targetBaseTier,
				TimeLeft = 0,
				StatusText = "Raid failed: server reservation error",
			})
			return
		end

		local teleportData = {
			Mode = "Raid",
			TargetUserId = targetUserId,
			TargetBaseTier = targetBaseTier,
			RaiderUserId = player.UserId,
			TargetName = targetName,
			LaunchScrapValue = launchScrapValue,
			ReservedAccessCode = accessCode,
		}
		local options = Instance.new("TeleportOptions")
		options.ReservedServerAccessCode = accessCode
		options:SetTeleportData(teleportData)

		pendingTeleports[player] = {
			TargetPlaceId = Config.Places.PlayerBase,
			Options = options,
			IsReturningToMap = false,
			TargetName = targetName,
			LaunchCostBatch = launchCostBatch,
		}

		local okTp, errTp = pcall(function()
			TeleportService:TeleportAsync(Config.Places.PlayerBase, { player }, options)
		end)
		if not okTp then
			warn(string.format("[RaidService] TeleportAsync failed for %s: %s", player.Name, tostring(errTp)))
			pendingTeleports[player] = nil
			teleportInProgress[player] = nil
			SecurityService.SetTeleportLock(player, false)
			DataService.RestoreAfterFailedTeleport(player)
			if #launchCostBatch > 0 then
				InventoryService.AddItems(player, launchCostBatch)
			end
			sendRaidHud(player, {
				Active = false,
				TargetName = targetName,
				TargetBaseTier = targetBaseTier,
				TimeLeft = 0,
				StatusText = "Raid failed: teleport error",
			})
		end
	end)
end

local function onRaidBuildPlaceRequest(
	player: Player,
	pieceTypeAny: any,
	targetCFrameAny: any,
	parentUidAny: any,
	socketIdAny: any,
	rotStepAny: any
)
	local session = activeSessions[player]
	if session == nil or session.Extracting then
		return
	end
	if not SecurityService.CheckRateLimit(player, Net.Events.BuildPlaceRequest) then
		return
	end
	if DataService.IsTeleporting(player) or SecurityService.IsTransactionLocked(player) then
		return
	end
	if not SecurityService.IsValidString(pieceTypeAny, 1, 32) then
		return
	end
	local pieceType = BuildingGeometry.CanonicalPieceType(pieceTypeAny :: string)
	local pieceConfig = BuildingConfig.Pieces[pieceType]
	if pieceConfig == nil or not SecurityService.IsValidCFrame(targetCFrameAny, 2000) then
		return
	end
	local requestedCF = targetCFrameAny :: CFrame

	local parentUid: string? = nil
	local socketId: string? = nil
	if parentUidAny ~= nil or socketIdAny ~= nil then
		if
			not SecurityService.IsValidString(parentUidAny, 1, 64)
			or not SecurityService.IsValidString(socketIdAny, 1, 32)
		then
			return
		end
		parentUid = parentUidAny :: string
		socketId = socketIdAny :: string
	end

	local explicitRotStep: number? = nil
	if rotStepAny ~= nil then
		if not SecurityService.IsValidInteger(rotStepAny, 0, 32) then
			return
		end
		explicitRotStep = rotStepAny :: number
	end

	SecurityService.RunLocked(player, "RaidBuildPlace", function()
		if activeSessions[player] ~= session or session.Extracting or DataService.GetData(player) == nil then
			return
		end
		local character, hrp = SecurityService.GetAliveCharacterRoot(player)
		if hrp == nil then
			return
		end

		local basePieces: { SavedBuildPiece } = {}
		for _, rec in session.RaiderPieces do
			table.insert(basePieces, rec.Piece)
		end

		local validation = BuildingValidator.ValidatePlacement({
			Player = player,
			Character = character,
			HrpPosition = hrp.Position,
			PieceType = pieceType,
			RequestedCFrame = requestedCF,
			ParentUid = parentUid,
			SocketId = socketId,
			ExplicitRotStep = explicitRotStep,
			PlayerRecords = (session.RaiderPieces :: any) :: { [string]: BuildingValidator.LivePieceEntry },
			AllRecordsByUid = (session.RaiderPieces :: any) :: { [string]: BuildingValidator.LivePieceEntry },
			OccupiedSockets = session.RaiderOccupiedSockets,
			OccupiedWorldKeys = session.RaiderOccupiedWorldKeys,
			BasePieces = basePieces,
			PlayerBaseTier = BaseService.GetPlayerBaseTier(player),
			IsRaidMode = true,
		})

		if not validation.Allowed or validation.AuthoritativeCFrame == nil then
			sendBuildFeedback(
				player,
				false,
				validation.Reason or "Нельзя установить объект здесь"
			)
			return
		end

		local costBatch = costMapToBatch(pieceConfig.Cost)
		if #costBatch > 0 and not InventoryService.RemoveItems(player, costBatch) then
			sendBuildFeedback(player, false, "Недостаточно ресурсов")
			return
		end

		local authCF = validation.AuthoritativeCFrame
		local uid = HttpService:GenerateGUID(false)
		local rotY = validation.RotY or BuildingGeometry.QuantizeYaw30(BuildingGeometry.ExtractYawDegrees(authCF))
		local maxHp = BuildingGeometry.ComputeMaxHp(pieceType, "wood")

		local newPiece: SavedBuildPiece = {
			Uid = uid,
			PieceType = pieceType,
			Tier = "wood",
			PosX = authCF.Position.X,
			PosY = authCF.Position.Y,
			PosZ = authCF.Position.Z,
			RotY = rotY,
			ParentUid = validation.ResolvedParentUid,
			AnchorUid = validation.ResolvedParentUid,
			SocketId = validation.ResolvedSocketId,
			Hp = maxHp,
			LastDamagedAt = 0,
		}

		local outpostFolder = getOrCreateFolder(RAID_OUTPOST_STRUCTURES_FOLDER_NAME)
		local model = BuildingGeometry.CreateModel(
			pieceType,
			authCF,
			false,
			string.format("RaidOutpost_%s_%s", pieceType, string.sub(uid, 1, 8))
		)
		BuildingGeometry.ApplyTierVisuals(model, pieceType, "wood")
		model:SetAttribute("BuildUid", uid)
		model:SetAttribute("PieceType", pieceType)
		model:SetAttribute("Tier", "wood")
		model:SetAttribute("OwnerUserId", player.UserId)
		model:SetAttribute("Health", maxHp)
		model:SetAttribute("MaxHealth", maxHp)
		model:SetAttribute("IsRaidOutpostPiece", true)
		model.Parent = outpostFolder

		local record: RaiderPieceRecord = {
			Owner = player,
			Piece = newPiece,
			Model = model,
			CFrame = authCF,
		}
		session.RaiderPieces[uid] = record
		BuildingValidator.RegisterOccupationsForRecord(
			(record :: any) :: BuildingValidator.LivePieceEntry,
			(session.RaiderPieces :: any) :: { [string]: BuildingValidator.LivePieceEntry },
			session.RaiderOccupiedSockets,
			session.RaiderOccupiedWorldKeys
		)
	end)
end

local function hasClearPlantLineOfSight(
	fromPos: Vector3,
	targetPos: Vector3,
	character: Model,
	targetModel: Model
): boolean
	local delta = targetPos - fromPos
	if delta.Magnitude <= 0.1 then
		return true
	end
	local exclude: { Instance } = { character, targetModel }
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.IgnoreWater = true
	params.FilterDescendantsInstances = exclude

	for _ = 1, 6 do
		local hit = Workspace:Raycast(fromPos, delta, params)
		if hit == nil then
			return true
		end
		if hit.Instance:IsDescendantOf(targetModel) then
			return true
		end
		if hit.Instance.CanCollide == false and not hit.Instance:IsA("Terrain") then
			table.insert(exclude, hit.Instance)
			params.FilterDescendantsInstances = exclude
		else
			return false
		end
	end
	return false
end

local function onPlaceExplosiveRequest(player: Player, requestAny: any, legacyHitPositionAny: any)
	if not SecurityService.CheckRateLimit(player, Net.Events.PlaceExplosiveRequest) then
		return
	end
	local session = activeSessions[player]
	if session == nil or session.Extracting or os.clock() >= session.EndsAt then
		return
	end
	if
		DataService.IsTransferLocked(player)
		or DataService.IsTeleporting(player)
		or SecurityService.IsTransactionLocked(player)
	then
		return
	end
	if DataService.GetData(player) == nil then
		return
	end

	local targetUid: string
	local hitPosition: Vector3
	local requestedExplosiveId: string? = nil

	if Types.IsValidExplosionRequest(requestAny) then
		local req = requestAny :: Types.ExplosionRequest
		targetUid = req.TargetUid
		hitPosition = req.HitPosition
		requestedExplosiveId = req.ExplosiveId
	elseif
		SecurityService.IsValidString(requestAny, 1, 64) and SecurityService.IsValidVector3(legacyHitPositionAny)
	then
		targetUid = requestAny :: string
		hitPosition = legacyHitPositionAny :: Vector3
	else
		return
	end

	local targetRecord = session.Pieces[targetUid]
	if targetRecord == nil or not targetRecord.Model.Parent then
		return
	end

	local character, hrp, _ = getAliveCharacterParts(player)
	if character == nil or hrp == nil then
		return
	end

	local clampedPos = closestPointOnModel(targetRecord.Model, hitPosition)
	if (hitPosition - clampedPos).Magnitude > MAX_HIT_SURFACE_OFFSET then
		return
	end
	if (hrp.Position - clampedPos).Magnitude > Types.MAX_EXPLOSIVE_PLACE_DISTANCE then
		return
	end
	if not hasClearPlantLineOfSight(hrp.Position, clampedPos, character, targetRecord.Model) then
		return
	end

	SecurityService.RunLocked(player, "PlaceExplosive", function()
		if
			activeSessions[player] ~= session
			or session.Extracting
			or os.clock() >= session.EndsAt
			or DataService.IsTransferLocked(player)
			or DataService.GetData(player) == nil
			or session.Pieces[targetUid] ~= targetRecord
			or not targetRecord.Model.Parent
		then
			return
		end

		local innerChar, innerHrp, _ = getAliveCharacterParts(player)
		if innerChar == nil or innerHrp == nil then
			return
		end
		if (innerHrp.Position - clampedPos).Magnitude > Types.MAX_EXPLOSIVE_PLACE_DISTANCE then
			return
		end
		if not hasClearPlantLineOfSight(innerHrp.Position, clampedPos, innerChar, targetRecord.Model) then
			return
		end

		local now = os.clock()
		local prevPlace = lastExplosivePlaceTime[player]
		if prevPlace ~= nil and (now - prevPlace) < EXPLOSIVE_PLACE_COOLDOWN then
			return
		end

		local equippedSlot = InventoryService.GetEquippedSlot(player)
		local slotData = InventoryService.GetSlot(player, equippedSlot)
		if slotData == nil or slotData.Count <= 0 then
			return
		end
		if requestedExplosiveId ~= nil and slotData.Id ~= requestedExplosiveId then
			return
		end

		local explosiveCfg = Explosives[slotData.Id]
		if explosiveCfg == nil then
			return
		end

		local explosiveId = slotData.Id
		if not InventoryService.ConsumeSlot(player, equippedSlot, 1) then
			return
		end
		lastExplosivePlaceTime[player] = now
		local expValues = Config.Raid.ExplosiveScrapValues :: { [string]: number }
		session.RaiderSpentScrapValue += (expValues[explosiveId] or 0)

		local toPlayer = innerHrp.Position - clampedPos
		local nudge = if toPlayer.Magnitude > 0.05 then toPlayer.Unit * 0.3 else Vector3.new(0, 0.3, 0)
		local blastOrigin = clampedPos + nudge

		local visualPart, timerLabel = RaidExplosives.CreateExplosiveVisual(
			blastOrigin,
			explosiveId,
			getOrCreateFolder(RAID_STRUCTURES_FOLDER_NAME)
		)
		local detonateAt = os.clock() + explosiveCfg.FuseTime
		local explosiveRecord: ActiveExplosiveRecord = {
			Part = visualPart,
			Label = timerLabel,
			CancelFlag = false,
			DetonateAt = detonateAt,
		}
		table.insert(session.ActiveExplosives, explosiveRecord)

		task.spawn(function()
			while not explosiveRecord.CancelFlag and activeSessions[player] == session do
				local remaining = detonateAt - os.clock()
				if remaining <= 0 then
					break
				end
				if explosiveRecord.Label and explosiveRecord.Label.Parent then
					explosiveRecord.Label.Text = string.format("%.1fs", remaining)
				end
				task.wait(0.1)
			end

			if
				not explosiveRecord.CancelFlag
				and activeSessions[player] == session
				and os.clock() >= (explosiveRecord.DetonateAt - 0.05)
			then
				RaidExplosives.DetonateExplosive(session, explosiveRecord, blastOrigin, explosiveId, getExplosionDeps())
			elseif explosiveRecord.Part.Parent then
				explosiveRecord.Part:Destroy()
			end
		end)
	end)
end

local function onRaidExtractRequest(player: Player)
	if not SecurityService.CheckRateLimit(player, Net.Events.RaidExtractRequest) then
		return
	end
	tryExtractFromRaid(player)
end

local function onRaidTcHackRequest(player: Player)
	if not SecurityService.CheckRateLimit(player, Net.Events.RaidTcHackRequest) then
		return
	end
	local session = activeSessions[player]
	if session == nil or session.Extracting then
		return
	end
	startTcHack(session)
end

local function onRaidAbandonRequest(player: Player)
	if not SecurityService.CheckRateLimit(player, Net.Events.RaidAbandonRequest) then
		return
	end
	local session = activeSessions[player]
	if session == nil or session.Extracting then
		return
	end
	failRaidSession(player, "Raid abandoned — Extraction Stash lost", false)
end

local function onTeleportInitFailed(
	player: Player,
	teleportResult: Enum.TeleportResult,
	errorMessage: string,
	_placeId: number,
	_teleportOptions: TeleportOptions
)
	local pending = pendingTeleports[player]
	if pending == nil then
		return
	end
	pendingTeleports[player] = nil
	teleportInProgress[player] = nil
	SecurityService.SetTeleportLock(player, false)
	warn(
		string.format(
			"[RaidService] TeleportInitFailed for %s (%s): %s",
			player.Name,
			tostring(teleportResult),
			errorMessage
		)
	)
	DataService.RestoreAfterFailedTeleport(player)
	if not pending.IsReturningToMap and pending.LaunchCostBatch ~= nil and #pending.LaunchCostBatch > 0 then
		InventoryService.AddItems(player, pending.LaunchCostBatch)
	end

	local session = activeSessions[player]
	if pending.IsReturningToMap and session ~= nil then
		session.Extracting = false
	elseif pending.IsDefenderTeleport then
		player:SetAttribute("DefendingRaid", false)
		sendBuildFeedback(player, false, string.format("Teleport failed: %s", errorMessage))
	else
		sendRaidHud(player, {
			Active = false,
			TargetName = pending.TargetName,
			TimeLeft = 0,
			StatusText = string.format("Teleport failed: %s", errorMessage),
		})
	end
end

local function cloneBaseDataForRaid(source: BaseData): BaseData
	local clonedPieces: { SavedBuildPiece } = {}
	for _, piece in source.Pieces do
		local copiedStorage: { [string]: Slot }? = nil
		if type(piece.Storage) == "table" then
			copiedStorage = {}
			for k, s in piece.Storage do
				if type(s) == "table" and type(s.Id) == "string" and type(s.Count) == "number" then
					(copiedStorage :: { [string]: Slot })[k] = { Id = s.Id, Count = s.Count }
				end
			end
		end
		table.insert(clonedPieces, {
			Uid = piece.Uid,
			PieceType = piece.PieceType,
			Tier = piece.Tier,
			PosX = piece.PosX,
			PosY = piece.PosY,
			PosZ = piece.PosZ,
			RotY = piece.RotY,
			ParentUid = piece.ParentUid,
			AnchorUid = piece.AnchorUid,
			SocketId = piece.SocketId,
			MountSurface = piece.MountSurface,
			Hp = piece.Hp,
			LastDamagedAt = piece.LastDamagedAt,
			Storage = copiedStorage,
			GridX = piece.GridX,
			GridY = piece.GridY,
			GridZ = piece.GridZ,
		})
	end
	return {
		Pieces = clonedPieces,
		BaseTier = source.BaseTier,
		LastUpkeepTimestamp = source.LastUpkeepTimestamp,
	}
end

local function createRaidSessionRecord(
	player: Player,
	targetUserId: number,
	targetName: string,
	targetBaseTier: number,
	origin: Vector3,
	isStudioMock: boolean,
	returnPos: Vector3?,
	isSelfRaid: boolean?,
	initialSpentScrap: number?,
	reservedAccessCode: string?,
	raidId: string?
): RaidSession
	local outpostOrigin = origin + Vector3.new(0, 0, Config.Raid.OutpostOffsetZ)
	return {
		Raider = player,
		TargetUserId = targetUserId,
		TargetName = targetName,
		TargetBaseTier = targetBaseTier,
		Origin = origin,
		OutpostOrigin = outpostOrigin,
		IsStudioMock = isStudioMock,
		IsSelfRaid = isSelfRaid == true,
		SavedInventorySnapshot = nil,
		StartTime = os.clock(),
		Duration = RAID_DURATION,
		Pieces = {},
		RaiderPieces = {},
		RaiderOccupiedSockets = {},
		RaiderOccupiedWorldKeys = {},
		OutpostZoneModel = nil,
		OutpostWorkbenchId = nil,
		ExtractionStashContainerId = nil,
		ExtractionStashModel = nil,
		StashExtractPrompt = nil,
		SupplyCrateContainerId = nil,
		SupplyCrateModel = nil,
		ExtractionTerminalModel = nil,
		ExtractionTerminalPrompt = nil,
		ExtractionTerminalIndicator = nil,
		ArenaGroundPart = nil,
		RespawnPosition = outpostOrigin + Vector3.new(-3.2, 4.2, 2.4),
		DroppedContainerIds = {},
		ActiveExplosives = {},
		TcPieceUid = nil,
		TcCaptured = false,
		TcHackActive = false,
		TcHackStartTime = 0,
		TcHackPrompt = nil,
		LivesLeft = Config.Raid.MaxLives,
		MaxLives = Config.Raid.MaxLives,
		LivesSpent = 0,
		RaiderSpentScrapValue = initialSpentScrap or 0,
		DeathPoints = {},
		LastDamagedAt = 0,
		Extracting = false,
		ExtractionCountdownActive = false,
		ExtractionCountdownStart = 0,
		ExtractionTotalDuration = Config.Raid.StashExtractionDuration,
		ExtractionSirenSound = nil,
		ExtractionBeaconPart = nil,
		StashExtracted = false,
		PendingReturnOnRespawn = false,
		ReturnPosition = returnPos,
		RaidId = raidId or HttpService:GenerateGUID(false),
		ReservedAccessCode = reservedAccessCode,
		AlarmTriggered = false,
		Defender = nil,
		DefenderReturnPos = nil,
		DefenderJanitor = nil,
		Janitor = Janitor.new(),
	}
end

local function startRaidSession(session: RaidSession, baseData: BaseData)
	local player = session.Raider
	activeSessions[player] = session
	activeSessionByRaidId[session.RaidId] = session
	if not session.IsSelfRaid and session.TargetUserId > 0 then
		activeSessionByTargetUserId[session.TargetUserId] = session
	end
	player:SetAttribute("InRaid", true)
	player:SetAttribute("InSelfRaid", session.IsSelfRaid)
	spawnRaidTargetBase(session, baseData)
	RaidOutpost.SpawnRaidOutpost(session, getOutpostDeps())
	bindRaiderLifecycle(session)
	teleportCharacterToPosition(player, session.RespawnPosition)
	startSessionTimerLoop(session)
	local startMsg = if session.IsSelfRaid
		then string.format("Self-Raid Test (Tier %d) — No real loot/ammo risk!", session.TargetBaseTier)
		else string.format("Raid started (Tier %d) — Hack or destroy enemy TC!", session.TargetBaseTier)
	syncSessionHud(session, startMsg)
	if not session.IsSelfRaid and session.TargetUserId > 0 then
		triggerActiveRaidAlarm(session)
	end
end

local function findSafeTcSpawnPosition(session: RaidSession): Vector3
	if session.TcPieceUid ~= nil then
		local tcRecord = session.Pieces[session.TcPieceUid]
		if tcRecord ~= nil and tcRecord.Model.Parent ~= nil then
			local tcPos = if tcRecord.Model.PrimaryPart ~= nil
				then tcRecord.Model.PrimaryPart.Position
				else tcRecord.Model:GetPivot().Position
			return tcPos + Vector3.new(0, 4.0, 0)
		end
	end
	return session.Origin + Vector3.new(0, 5.0, 0)
end

local function grantDefenderCombatKit(session: RaidSession, defender: Player)
	if DataService.GetData(defender) == nil then
		return
	end
	local snapshot = InventoryService.GetSnapshot(defender)
	local owned: { [string]: number } = {}
	for i = 1, Types.INVENTORY_SIZE do
		local slot = snapshot[i]
		if slot ~= nil and slot.Count > 0 then
			owned[slot.Id] = (owned[slot.Id] or 0) + slot.Count
		end
	end

	local hasWeapon = (owned.pipe_pistol or 0) > 0 or (owned.hunting_bow or 0) > 0
	local addedFromTc: { [string]: number } = {}
	local kitBatch: { ItemBatchEntry } = {}

	if session.TcPieceUid ~= nil then
		local tcRecord = session.Pieces[session.TcPieceUid]
		if tcRecord ~= nil and tcRecord.ContainerId == nil and type(tcRecord.Piece.Storage) == "table" then
			local desiredMax: { [string]: number } = {
				pipe_pistol = if hasWeapon then 0 else 1,
				pistol_ammo = 32,
				bandage = 3,
			}
			for key, slot in tcRecord.Piece.Storage do
				local wantMax = desiredMax[slot.Id]
				if wantMax ~= nil and wantMax > 0 and slot.Count > 0 then
					local cur = (owned[slot.Id] or 0) + (addedFromTc[slot.Id] or 0)
					if cur < wantMax then
						local take = math.min(slot.Count, wantMax - cur)
						if take > 0 then
							slot.Count -= take
							if slot.Count <= 0 then
								tcRecord.Piece.Storage[key] = nil
							end
							addedFromTc[slot.Id] = (addedFromTc[slot.Id] or 0) + take
							table.insert(kitBatch, { Id = slot.Id, Count = take })
							if slot.Id == "pipe_pistol" then
								hasWeapon = true
							end
						end
					end
				end
			end
		end
	end

	for _, fallback in Config.Raid.ActiveDefenseFallbackKit do
		if fallback.Id == "pipe_pistol" and hasWeapon then
			continue
		end
		local cur = (owned[fallback.Id] or 0) + (addedFromTc[fallback.Id] or 0)
		if cur < fallback.Count then
			table.insert(kitBatch, { Id = fallback.Id, Count = fallback.Count - cur })
		end
	end

	if #kitBatch > 0 then
		InventoryService.AddItems(defender, kitBatch)
	end
end

local function attachDefenderToSession(session: RaidSession, defender: Player)
	if defender.Parent ~= Players or session.Extracting then
		return
	end
	if session.Defender ~= nil and session.Defender ~= defender then
		return
	end
	if session.DefenderJanitor ~= nil then
		session.DefenderJanitor:Destroy()
	end

	local defJanitor = Janitor.new()
	session.Defender = defender
	session.DefenderJanitor = defJanitor
	defender:SetAttribute("DefendingRaid", true)

	local function spawnAtTc(charModel: Model)
		if session.Defender ~= defender or session.Extracting then
			return
		end
		local safePos = findSafeTcSpawnPosition(session)
		applySpawnProtection(charModel)
		task.spawn(function()
			local hrp = charModel:WaitForChild("HumanoidRootPart", 2)
			task.wait()
			if
				hrp ~= nil
				and session.Defender == defender
				and not session.Extracting
				and defender.Character == charModel
			then
				teleportCharacterToPosition(defender, safePos)
			end
		end)
	end

	if defender.Character ~= nil then
		spawnAtTc(defender.Character)
	end
	defJanitor:Add(defender.CharacterAdded:Connect(function(newChar: Model)
		spawnAtTc(newChar)
	end))

	grantDefenderCombatKit(session, defender)
	sendBuildFeedback(
		defender,
		true,
		"Вы прибыли к TC на оборону базы! Боекомплект выдан."
	)
	Net.GetEvent(Net.Events.RaidAlarmNotify):FireClient(defender, {
		Phase = "Active",
		RaidId = session.RaidId,
		RaiderName = session.Raider.DisplayName,
		TargetName = session.TargetName,
		TargetBaseTier = session.TargetBaseTier,
	})
end

returnDefenderAfterRaid = function(session: RaidSession, statusText: string?)
	local defender = session.Defender
	if defender == nil then
		return
	end
	session.Defender = nil
	if session.DefenderJanitor ~= nil then
		session.DefenderJanitor:Destroy()
		session.DefenderJanitor = nil
	end
	if defender.Parent ~= Players then
		return
	end

	defender:SetAttribute("DefendingRaid", false)
	Net.GetEvent(Net.Events.RaidAlarmNotify):FireClient(defender, {
		Phase = "Ended",
		RaidId = session.RaidId,
		StatusText = statusText or "Рейд завершён",
	})

	if session.IsStudioMock then
		local retPos = session.DefenderReturnPos or getDefaultSpawnPosition()
		teleportCharacterToPosition(defender, retPos)
		sendBuildFeedback(
			defender,
			true,
			statusText or "Оборона завершена — возврат на позицию"
		)
		return
	end

	if teleportInProgress[defender] then
		return
	end
	teleportInProgress[defender] = true
	SecurityService.SetTeleportLock(defender, true)

	local released = DataService.ReleaseForTeleport(defender)
	if not released then
		DataService.RestoreAfterFailedTeleport(defender)
		teleportInProgress[defender] = nil
		SecurityService.SetTeleportLock(defender, false)
		return
	end
	if defender.Parent ~= Players then
		teleportInProgress[defender] = nil
		SecurityService.SetTeleportLock(defender, false)
		return
	end

	local options = Instance.new("TeleportOptions")
	options:SetTeleportData({
		FromPlaceId = game.PlaceId,
		OwnerUserId = defender.UserId,
		Mode = "Base",
	})
	pendingTeleports[defender] = {
		TargetPlaceId = Config.Places.PlayerBase,
		Options = options,
		IsReturningToMap = true,
		IsDefenderTeleport = true,
		TargetName = session.TargetName,
	}
	local ok, err = pcall(function()
		TeleportService:TeleportAsync(Config.Places.PlayerBase, { defender }, options)
	end)
	if not ok then
		warn(string.format("[RaidService] Defender return teleport error for %s: %s", defender.Name, tostring(err)))
		pendingTeleports[defender] = nil
		teleportInProgress[defender] = nil
		SecurityService.SetTeleportLock(defender, false)
		DataService.RestoreAfterFailedTeleport(defender)
	end
end

local function dispatchAlarmToOnlinePlayer(player: Player, payload: { [string]: any })
	if player.Parent ~= Players or DataService.GetData(player) == nil then
		return
	end
	if
		player:GetAttribute("InRaid") == true
		or player:GetAttribute("InSelfRaid") == true
		or player:GetAttribute("DefendingRaid") == true
		or activeSessions[player] ~= nil
		or pendingDefenseAlarms[player] ~= nil
	then
		return
	end

	local raidId = if type(payload.RaidId) == "string" then payload.RaidId else ""
	local targetUserId = if type(payload.TargetUserId) == "number" then math.floor(payload.TargetUserId) else 0
	if #raidId == 0 or targetUserId ~= player.UserId then
		return
	end

	local acceptDur = Config.Raid.ActiveDefensePromptDuration
	local alarm: PendingDefenseAlarm = {
		RaidId = raidId,
		TargetUserId = targetUserId,
		TargetName = if type(payload.TargetName) == "string" then payload.TargetName else player.DisplayName,
		RaiderName = if type(payload.RaiderName) == "string" then payload.RaiderName else "Raider",
		TargetBaseTier = if type(payload.TargetBaseTier) == "number" then payload.TargetBaseTier else 1,
		ReservedAccessCode = if type(payload.ReservedAccessCode) == "string" then payload.ReservedAccessCode else "",
		IsStudioMock = payload.IsStudioMock == true,
		PromptExpiresAt = os.clock() + acceptDur,
		Accepted = false,
		PrepEndsAt = 0,
	}
	pendingDefenseAlarms[player] = alarm

	Net.GetEvent(Net.Events.RaidAlarmNotify):FireClient(player, {
		Phase = "Prompt",
		RaidId = alarm.RaidId,
		RaiderName = alarm.RaiderName,
		TargetName = alarm.TargetName,
		TargetBaseTier = alarm.TargetBaseTier,
		AcceptDuration = acceptDur,
		PrepDuration = Config.Raid.ActiveDefensePrepDuration,
	})

	task.delay(acceptDur + 0.5, function()
		local cur = pendingDefenseAlarms[player]
		if cur == alarm and not cur.Accepted then
			pendingDefenseAlarms[player] = nil
		end
	end)
end

triggerActiveRaidAlarm = function(session: RaidSession)
	if session.AlarmTriggered or session.IsSelfRaid or session.TargetUserId <= 0 then
		return
	end
	session.AlarmTriggered = true

	local payload = {
		RaidId = session.RaidId,
		TargetUserId = session.TargetUserId,
		TargetName = session.TargetName,
		RaiderName = session.Raider.DisplayName,
		TargetBaseTier = session.TargetBaseTier,
		ReservedAccessCode = session.ReservedAccessCode or "",
		IsStudioMock = session.IsStudioMock,
	}

	local localOwner = Players:GetPlayerByUserId(session.TargetUserId)
	if localOwner ~= nil and localOwner ~= session.Raider then
		dispatchAlarmToOnlinePlayer(localOwner, payload)
	end

	if not session.IsStudioMock and not RunService:IsStudio() then
		task.spawn(function()
			local ok, err = pcall(function()
				MessagingService:PublishAsync(RAID_ALARM_TOPIC, payload)
			end)
			if not ok then
				warn(string.format("[RaidService] MessagingService PublishAsync failed: %s", tostring(err)))
			end
		end)
	end
end

local function onRaidAlarmResponse(player: Player, acceptedAny: any, raidIdAny: any)
	if not SecurityService.CheckRateLimit(player, Net.Events.RaidAlarmResponse) then
		return
	end
	if typeof(acceptedAny) ~= "boolean" then
		return
	end
	local alarm = pendingDefenseAlarms[player]
	if alarm == nil or alarm.Accepted then
		return
	end
	if typeof(raidIdAny) == "string" and #raidIdAny > 0 and raidIdAny ~= alarm.RaidId then
		return
	end
	if not acceptedAny or os.clock() > alarm.PromptExpiresAt then
		pendingDefenseAlarms[player] = nil
		return
	end
	if teleportInProgress[player] or DataService.IsTeleporting(player) or SecurityService.IsTeleportLocked(player) then
		pendingDefenseAlarms[player] = nil
		return
	end

	alarm.Accepted = true
	local prepDuration = Config.Raid.ActiveDefensePrepDuration
	alarm.PrepEndsAt = os.clock() + prepDuration

	CraftingService.CancelCraftForPlayer(player, true, false)
	LootService.CloseContainerForPlayer(player, true)

	Net.GetEvent(Net.Events.RaidAlarmNotify):FireClient(player, {
		Phase = "Prep",
		RaidId = alarm.RaidId,
		RaiderName = alarm.RaiderName,
		TargetName = alarm.TargetName,
		TargetBaseTier = alarm.TargetBaseTier,
		PrepDuration = prepDuration,
	})

	task.delay(prepDuration, function()
		if pendingDefenseAlarms[player] ~= alarm then
			return
		end
		pendingDefenseAlarms[player] = nil
		if player.Parent ~= Players or DataService.GetData(player) == nil then
			return
		end

		local localSession = activeSessionByRaidId[alarm.RaidId] or activeSessionByTargetUserId[alarm.TargetUserId]
		if localSession ~= nil and not localSession.Extracting then
			local _, hrp, _ = getAliveCharacterParts(player)
			if hrp ~= nil then
				localSession.DefenderReturnPos = hrp.Position + Vector3.new(0, 1, 0)
			else
				localSession.DefenderReturnPos = getDefaultSpawnPosition()
			end
			attachDefenderToSession(localSession, player)
			return
		end

		if #alarm.ReservedAccessCode == 0 or alarm.IsStudioMock then
			sendBuildFeedback(player, false, "Рейд-сессия уже завершилась")
			Net.GetEvent(Net.Events.RaidAlarmNotify):FireClient(player, {
				Phase = "Ended",
				RaidId = alarm.RaidId,
				StatusText = "Рейд завершён",
			})
			return
		end

		if teleportInProgress[player] then
			return
		end
		teleportInProgress[player] = true
		SecurityService.SetTeleportLock(player, true)

		local released = DataService.ReleaseForTeleport(player)
		if not released then
			DataService.RestoreAfterFailedTeleport(player)
			teleportInProgress[player] = nil
			SecurityService.SetTeleportLock(player, false)
			sendBuildFeedback(
				player,
				false,
				"Не удалось подготовить телепорт на оборону"
			)
			return
		end
		if player.Parent ~= Players then
			teleportInProgress[player] = nil
			SecurityService.SetTeleportLock(player, false)
			return
		end

		local options = Instance.new("TeleportOptions")
		options.ReservedServerAccessCode = alarm.ReservedAccessCode
		options:SetTeleportData({
			Mode = "RaidDefense",
			RaidId = alarm.RaidId,
			TargetUserId = alarm.TargetUserId,
			ReturnPlaceId = game.PlaceId,
		})
		pendingTeleports[player] = {
			TargetPlaceId = Config.Places.PlayerBase,
			Options = options,
			IsReturningToMap = false,
			IsDefenderTeleport = true,
			TargetName = alarm.TargetName,
		}
		local ok, err = pcall(function()
			TeleportService:TeleportAsync(Config.Places.PlayerBase, { player }, options)
		end)
		if not ok then
			warn(string.format("[RaidService] Defense TeleportAsync failed for %s: %s", player.Name, tostring(err)))
			pendingTeleports[player] = nil
			teleportInProgress[player] = nil
			SecurityService.SetTeleportLock(player, false)
			DataService.RestoreAfterFailedTeleport(player)
			sendBuildFeedback(player, false, "Ошибка телепортации к защите базы")
		end
	end)
end

local function onPlayerDataLoaded(player: Player, _data: Types.PlayerData)
	local ok, joinData = pcall(function()
		return player:GetJoinData()
	end)
	local teleportData = if ok
			and type(joinData) == "table"
			and type(joinData.TeleportData) == "table"
		then joinData.TeleportData
		else nil

	if game.PlaceId == Config.Places.PlayerBase and teleportData ~= nil and teleportData.Mode == "RaidDefense" then
		local targetUserIdAny = teleportData.TargetUserId
		local targetUserId = if SecurityService.IsValidInteger(targetUserIdAny)
			then math.floor(targetUserIdAny :: number)
			else 0
		local raidId = if type(teleportData.RaidId) == "string" then teleportData.RaidId else ""
		local session = if #raidId > 0 then activeSessionByRaidId[raidId] else nil
		if session == nil and targetUserId > 0 then
			session = activeSessionByTargetUserId[targetUserId]
		end
		if session ~= nil and not session.Extracting and session.TargetUserId == player.UserId then
			attachDefenderToSession(session, player)
		else
			sendBuildFeedback(
				player,
				false,
				"Рейд уже завершён — возвращение на базу"
			)
			task.delay(1.5, function()
				if player.Parent ~= Players or teleportInProgress[player] then
					return
				end
				teleportInProgress[player] = true
				SecurityService.SetTeleportLock(player, true)
				if DataService.ReleaseForTeleport(player) then
					local opts = Instance.new("TeleportOptions")
					opts:SetTeleportData({
						FromPlaceId = game.PlaceId,
						OwnerUserId = player.UserId,
						Mode = "Base",
					})
					pcall(function()
						TeleportService:TeleportAsync(Config.Places.PlayerBase, { player }, opts)
					end)
				else
					DataService.RestoreAfterFailedTeleport(player)
					teleportInProgress[player] = nil
					SecurityService.SetTeleportLock(player, false)
				end
			end)
		end
		return
	end

	local isRaidJoin = game.PlaceId == Config.Places.PlayerBase and teleportData ~= nil and teleportData.Mode == "Raid"

	if not isRaidJoin then
		deliverDefenseReports(player)
		return
	end

	local targetUserIdAny = teleportData.TargetUserId
	if not SecurityService.IsValidInteger(targetUserIdAny) then
		return
	end
	local targetUserId = math.floor(targetUserIdAny :: number)
	local targetName = if type(teleportData.TargetName) == "string" and #teleportData.TargetName > 0
		then teleportData.TargetName
		else RaidIntel.ResolveTargetName(targetUserId)

	local presetTier = DataService.GetPresetTier(targetUserId)
	local targetBaseTier = if presetTier ~= nil
		then presetTier
		elseif SecurityService.IsValidInteger(teleportData.TargetBaseTier) then math.clamp(
			math.floor(teleportData.TargetBaseTier :: number),
			1,
			3
		)
		else RaidIntel.ResolveTargetTier(targetUserId)

	Workspace:SetAttribute("RaidServerMode", true)

	local baseData: BaseData? = nil
	if targetUserId > 0 then
		baseData = DataService.LoadBaseSnapshot(targetUserId)
	end
	if baseData == nil or #baseData.Pieces == 0 then
		baseData = RaidIntel.BuildPresetBaseForTarget(targetBaseTier, targetUserId)
	end

	if activeSessions[player] ~= nil then
		cleanupSession(activeSessions[player])
		activeSessions[player] = nil
	end

	local launchScrap = if SecurityService.IsValidInteger(teleportData.LaunchScrapValue)
		then math.max(0, math.floor(teleportData.LaunchScrapValue :: number))
		else 0
	local reservedCode = if type(teleportData.ReservedAccessCode) == "string"
		then teleportData.ReservedAccessCode
		else nil
	local session = createRaidSessionRecord(
		player,
		targetUserId,
		targetName,
		targetBaseTier,
		Vector3.zero,
		false,
		nil,
		false,
		launchScrap,
		reservedCode,
		nil
	)
	startRaidSession(session, baseData :: BaseData)
end

function RaidService.EnterStudioMockRaid(player: Player, targetUserId: number, initialSpentScrap: number?): boolean
	if not RunService:IsStudio() or player.Parent ~= Players then
		return false
	end
	if activeSessions[player] ~= nil then
		return false
	end

	CraftingService.CancelCraftForPlayer(player, true, false)

	local returnPos = getDefaultSpawnPosition()
	local _, hrp, _ = getAliveCharacterParts(player)
	if hrp ~= nil then
		returnPos = hrp.Position + Vector3.new(0, 1, 0)
	end

	local targetBaseTier = RaidIntel.ResolveTargetTier(targetUserId)
	local baseData: BaseData? = nil
	if targetUserId > 0 then
		baseData = DataService.LoadBaseSnapshot(targetUserId)
	end
	if baseData == nil or #baseData.Pieces == 0 then
		baseData = RaidIntel.BuildPresetBaseForTarget(targetBaseTier, targetUserId)
	end

	local targetName = RaidIntel.ResolveTargetName(targetUserId)
	local session = createRaidSessionRecord(
		player,
		targetUserId,
		targetName,
		targetBaseTier,
		STUDIO_MOCK_RAID_ORIGIN,
		true,
		returnPos,
		false,
		initialSpentScrap
	)
	startRaidSession(session, baseData :: BaseData)
	return true
end

function RaidService.StartSelfRaid(player: Player): boolean
	if player.Parent ~= Players then
		return false
	end
	if
		activeSessions[player] ~= nil
		or teleportInProgress[player]
		or DataService.IsTeleporting(player)
		or SecurityService.IsTeleportLocked(player)
	then
		return false
	end
	if Workspace:GetAttribute("RaidServerMode") == true then
		return false
	end

	local data = DataService.GetData(player)
	if data == nil or #data.Base.Pieces == 0 then
		sendBuildFeedback(player, false, "Build a base before starting a Self-Raid defense test")
		return false
	end

	CraftingService.CancelCraftForPlayer(player, true, false)
	LootService.CloseContainerForPlayer(player, true)
	BaseService.ClearSessionGhosts(player)

	local returnPos = getDefaultSpawnPosition()
	local _, hrp, _ = getAliveCharacterParts(player)
	if hrp ~= nil then
		returnPos = hrp.Position + Vector3.new(0, 1, 0)
	end

	local realSnapshot = InventoryService.GetSnapshot(player)
	local copiedBase = cloneBaseDataForRaid(data.Base)
	local baseTier = math.clamp(math.max(1, data.Base.BaseTier), 1, 3)

	player:SetAttribute("InSelfRaid", true)
	InventoryService.ClearInventory(player)
	InventoryService.AddItems(player, Config.Raid.SelfRaidKit :: { ItemBatchEntry })

	nextSelfRaidSeq += 1
	local arenaOffset = Vector3.new(((nextSelfRaidSeq - 1) % 6) * 400, 0, 0)
	local arenaOrigin = STUDIO_MOCK_RAID_ORIGIN + arenaOffset
	local session = createRaidSessionRecord(
		player,
		player.UserId,
		string.format("%s (Self-Raid)", player.DisplayName),
		baseTier,
		arenaOrigin,
		true,
		returnPos,
		true,
		0
	)
	session.SavedInventorySnapshot = realSnapshot
	startRaidSession(session, copiedBase)
	return true
end

function RaidService.EndSelfRaid(player: Player, reason: string?): boolean
	local session = activeSessions[player]
	if session == nil or not session.IsSelfRaid then
		return false
	end
	finishSelfRaidReturn(player, session, reason or "Self-Raid test ended — inventory restored")
	return true
end

function RaidService.IsPlayerInRaid(player: Player): boolean
	return activeSessions[player] ~= nil
end

function RaidService.GetActiveSessionInfo(player: Player): RaidHudState?
	local session = activeSessions[player]
	if session == nil then
		return nil
	end
	return buildRaidHudState(session, nil)
end

function RaidService.Init()
	if isInitialized then
		return
	end
	isInitialized = true

	Net.InitServer()

	DefenseService.BindRaidHooks({
		TriggerExplosion = RaidService.TriggerExplosion,
		NotifyRaiderDamaged = RaidService.NotifyRaiderDamaged,
	})
	BaseService.BindRaidHooks({
		StartSelfRaid = RaidService.StartSelfRaid,
	})

	Net.GetEvent(Net.Events.RaidListRequest).OnServerEvent:Connect(onRaidListRequest)
	Net.GetEvent(Net.Events.RaidRefreshRequest).OnServerEvent:Connect(onRaidRefreshRequest)
	Net.GetEvent(Net.Events.StartRaidRequest).OnServerEvent:Connect(onStartRaidRequest)
	Net.GetEvent(Net.Events.BuildPlaceRequest).OnServerEvent:Connect(onRaidBuildPlaceRequest)
	Net.GetEvent(Net.Events.PlaceExplosiveRequest).OnServerEvent:Connect(onPlaceExplosiveRequest)
	Net.GetEvent(Net.Events.RaidExtractRequest).OnServerEvent:Connect(onRaidExtractRequest)
	Net.GetEvent(Net.Events.RaidTcHackRequest).OnServerEvent:Connect(onRaidTcHackRequest)
	Net.GetEvent(Net.Events.RaidAbandonRequest).OnServerEvent:Connect(onRaidAbandonRequest)
	Net.GetEvent(Net.Events.RaidAlarmResponse).OnServerEvent:Connect(onRaidAlarmResponse)
	TeleportService.TeleportInitFailed:Connect(onTeleportInitFailed)

	if not RunService:IsStudio() then
		task.spawn(function()
			local ok, err = pcall(function()
				MessagingService:SubscribeAsync(RAID_ALARM_TOPIC, function(message: any)
					if type(message) ~= "table" or type(message.Data) ~= "table" then
						return
					end
					local data = message.Data :: { [string]: any }
					local targetIdAny = data.TargetUserId
					if type(targetIdAny) ~= "number" then
						return
					end
					local targetPlayer = Players:GetPlayerByUserId(math.floor(targetIdAny))
					if targetPlayer ~= nil then
						dispatchAlarmToOnlinePlayer(targetPlayer, data)
					end
				end)
			end)
			if not ok then
				warn(string.format("[RaidService] MessagingService SubscribeAsync failed: %s", tostring(err)))
			end
		end)
	end

	DataService.OnBeforeUnload(function(player: Player, data: Types.PlayerData)
		local session = activeSessions[player]
		if session ~= nil and session.IsSelfRaid and session.SavedInventorySnapshot ~= nil then
			local restored: Inventory = {}
			for i = 1, Types.INVENTORY_SIZE do
				local slot = session.SavedInventorySnapshot[i]
				if slot ~= nil then
					restored[i] = { Id = slot.Id, Count = slot.Count }
				end
			end
			data.Inventory = restored
			session.SavedInventorySnapshot = nil
		end
	end)

	DataService.OnDataLoaded(onPlayerDataLoaded)

	Players.PlayerRemoving:Connect(function(player: Player)
		local session = activeSessions[player]
		if session ~= nil then
			restoreSelfRaidInventory(player, session)
			if not session.Extracting and not session.TcCaptured then
				recordDefenseReport(
					session,
					true,
					string.format("%s disconnected before capturing TC", player.DisplayName)
				)
			end
			activeSessions[player] = nil
			cleanupSession(session)
		end
		RaidIntel.ClearPlayerState(player)
		pendingDefenseAlarms[player] = nil
		for _, activeSess in activeSessions do
			if activeSess.Defender == player then
				activeSess.Defender = nil
				if activeSess.DefenderJanitor ~= nil then
					activeSess.DefenderJanitor:Destroy()
					activeSess.DefenderJanitor = nil
				end
			end
		end
		lastListRequest[player] = nil
		lastExplosivePlaceTime[player] = nil
		teleportInProgress[player] = nil
		pendingTeleports[player] = nil
	end)
end

return RaidService
