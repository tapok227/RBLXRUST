--!strict
local HttpService = game:GetService("HttpService")
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
local Recipes = require(ReplicatedStorage.Shared.configs.Recipes)
local BuildingGeometry = require(ReplicatedStorage.Shared.BuildingGeometry)
local Net = require(ReplicatedStorage.Shared.Net)
local BaseGhosts = require(ServerScriptService.Server.Services.Base.BaseGhosts)
local BaseUpkeep = require(ServerScriptService.Server.Services.Base.BaseUpkeep)
local BuildingValidator = require(ServerScriptService.Server.Services.BuildingValidator)
local DataService = require(ServerScriptService.Server.Services.DataService)
local DefenseService = require(ServerScriptService.Server.Services.DefenseService)
local ExtractionService = require(ServerScriptService.Server.Services.ExtractionService)
local InventoryService = require(ServerScriptService.Server.Services.InventoryService)
local LootService = require(ServerScriptService.Server.Services.LootService)
local CraftingService = require(ServerScriptService.Server.Services.CraftingService)
local BlueprintService = require(ServerScriptService.Server.Services.BlueprintService)
local SecurityService = require(ServerScriptService.Server.Services.SecurityService)

type Slot = Types.Slot
type Inventory = Types.Inventory
type ItemBatchEntry = Types.ItemBatchEntry
type BuildPieceType = Types.BuildPieceType
type BuildTier = Types.BuildTier
type SavedBuildPiece = Types.SavedBuildPiece

export type LivePieceRecord = {
	Owner: Player,
	Piece: SavedBuildPiece,
	Model: Model,
	CFrame: CFrame,
	ContainerId: string?,
	LastDamagedAt: number,
}

export type DamageKind = "Explosion" | "Tool" | "Bullet"

export type RaidHooks = {
	StartSelfRaid: ((player: Player) -> boolean)?,
}

local STRUCTURES_FOLDER_NAME = "PlayerBaseStructures"
local STUDIO_SIM_BANNER_DURATION = 4
local BUILD_ACTION_COOLDOWN = 0.15

local spawnedByPlayer: { [Player]: { [string]: LivePieceRecord } } = {}
local recordsByUid: { [string]: LivePieceRecord } = {}
local occupiedSockets: { [string]: { [string]: string } } = {}
local occupiedWorldKeys: { [string]: string } = {}
local lastBuildActionTime: { [Player]: number } = {}
local teleportInProgress: { [Player]: boolean } = {}
local pendingTeleports: { [Player]: boolean } = {}
local openTcByPlayer: { [Player]: string } = {}
local raidHooks: RaidHooks = {}
local isInitialized = false

local REQUIRED_WB_BY_PIECE: { [string]: number } = {}
for _, recipe in Recipes do
	if recipe.ResultCount == 1 and recipe.RequiredWorkbench > 0 then
		REQUIRED_WB_BY_PIECE[recipe.ResultId] = recipe.RequiredWorkbench
	end
end

local BaseService = {}

local function getOrCreateStructuresFolder(): Folder
	local existing = Workspace:FindFirstChild(STRUCTURES_FOLDER_NAME)
	if existing and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = STRUCTURES_FOLDER_NAME
	folder.Parent = Workspace
	return folder
end

local function storageMapToInventory(storage: { [string]: Slot }?, maxSlots: number): Inventory
	local inv: Inventory = {}
	if type(storage) ~= "table" then
		return inv
	end
	for k, v in storage do
		local idx = tonumber(k)
		if
			idx
			and idx >= 1
			and idx <= maxSlots
			and idx % 1 == 0
			and type(v) == "table"
			and type(v.Id) == "string"
			and type(v.Count) == "number"
			and v.Count > 0
		then
			inv[idx] = { Id = v.Id, Count = math.floor(v.Count) }
		end
	end
	return inv
end

local function inventoryToStorageMap(slots: Inventory, maxSlots: number): { [string]: Slot }
	local map: { [string]: Slot } = {}
	for i = 1, maxSlots do
		local slot = slots[i]
		if slot ~= nil and slot.Count > 0 then
			map[tostring(i)] = { Id = slot.Id, Count = slot.Count }
		end
	end
	return map
end

local function sendBuildFeedback(player: Player, success: boolean, message: string, baseTier: number?)
	if player.Parent ~= Players then
		return
	end
	Net.GetEvent(Net.Events.BuildFeedback):FireClient(player, {
		Success = success,
		Message = message,
		BaseTier = baseTier,
	})
end

local function isWorkbenchType(canonicalType: BuildPieceType): boolean
	return canonicalType == "workbench_1" or canonicalType == "workbench_2" or canonicalType == "workbench_3"
end

local getUpkeepDeps: () -> BaseUpkeep.UpkeepDeps

function BaseService.ComputeHourlyUpkeep(pieces: { SavedBuildPiece }): { [string]: number }
	return BaseUpkeep.ComputeHourlyUpkeep(pieces)
end

function BaseService.ComputeBaseTier(pieces: { SavedBuildPiece }, hasActiveTc: boolean): number
	return BaseUpkeep.ComputeBaseTier(pieces, hasActiveTc)
end

function BaseService.GetPlayerBaseTier(player: Player): number
	local data = DataService.GetData(player)
	return if data ~= nil then data.Base.BaseTier else 0
end

function BaseService.BuildToolCupboardState(player: Player): Types.ToolCupboardState?
	return BaseUpkeep.BuildToolCupboardState(player, getUpkeepDeps())
end

local function syncToolCupboardForPlayer(player: Player)
	if player.Parent ~= Players then
		return
	end
	if openTcByPlayer[player] == nil then
		return
	end
	local state = BaseService.BuildToolCupboardState(player)
	if state == nil then
		openTcByPlayer[player] = nil
	end
	Net.GetEvent(Net.Events.ToolCupboardSync):FireClient(player, state)
end

local function recalculateAndSyncBaseTier(player: Player)
	local data = DataService.GetData(player)
	if data == nil then
		return
	end
	local tcPiece = BaseUpkeep.FindToolCupboardPiece(data.Base.Pieces)
	local tier = BaseService.ComputeBaseTier(data.Base.Pieces, tcPiece ~= nil)
	data.Base.BaseTier = tier
	if player.Parent == Players then
		player:SetAttribute("BaseTier", tier)
	end
	if tcPiece ~= nil then
		local record = recordsByUid[tcPiece.Uid]
		if record ~= nil and record.Model.Parent ~= nil then
			record.Model:SetAttribute("BaseTier", tier)
		end
	end
	syncToolCupboardForPlayer(player)
end

local function cleanupPieceRuntime(record: LivePieceRecord)
	recordsByUid[record.Piece.Uid] = nil
	BaseUpkeep.ClearDecayFraction(record.Piece.Uid)
	DefenseService.UnregisterDefense(record.Piece.Uid)
	BuildingValidator.UnregisterSocketsForPiece(record.Piece.Uid, occupiedSockets, occupiedWorldKeys)
	if record.ContainerId ~= nil then
		LootService.UnregisterContainer(record.ContainerId)
	end
	local canonicalType = BuildingGeometry.CanonicalPieceType(record.Piece.PieceType)
	if isWorkbenchType(canonicalType) then
		CraftingService.UnregisterStation(record.Piece.Uid)
	elseif canonicalType == "research_table" then
		BlueprintService.UnregisterResearchTable(record.Piece.Uid)
	end
	if canonicalType == "tool_cupboard" and openTcByPlayer[record.Owner] == record.Piece.Uid then
		openTcByPlayer[record.Owner] = nil
		if record.Owner.Parent == Players then
			Net.GetEvent(Net.Events.ToolCupboardSync):FireClient(record.Owner, nil)
		end
	end
	if record.Model.Parent then
		record.Model:Destroy()
	end
end

local function destroyUnsupportedCascade(player: Player, data: Types.PlayerData): number
	local unsupportedUids = BuildingValidator.FindUnsupportedPieces(data.Base.Pieces, nil)
	if #unsupportedUids == 0 then
		return 0
	end

	local dropSet: { [string]: boolean } = {}
	for _, dropUid in unsupportedUids do
		dropSet[dropUid] = true
	end

	local playerRecords = spawnedByPlayer[player]
	for _, dropUid in unsupportedUids do
		BaseUpkeep.ClearDecayFraction(dropUid)
		local rec = if playerRecords ~= nil then playerRecords[dropUid] else recordsByUid[dropUid]
		if playerRecords ~= nil then
			playerRecords[dropUid] = nil
		end
		if rec ~= nil then
			cleanupPieceRuntime(rec)
		end
	end

	local kept: { SavedBuildPiece } = {}
	for _, piece in data.Base.Pieces do
		if not dropSet[piece.Uid] then
			table.insert(kept, piece)
		end
	end
	data.Base.Pieces = kept
	return #unsupportedUids
end

local function createPieceModel(owner: Player, piece: SavedBuildPiece): (Model, CFrame)
	local canonicalType = BuildingGeometry.CanonicalPieceType(piece.PieceType)
	piece.PieceType = canonicalType
	local worldCF = BuildingGeometry.GetPieceWorldCFrame(piece)
	local modelName = string.format("%s_%s", canonicalType, string.sub(piece.Uid, 1, 8))
	local model = BuildingGeometry.CreateModel(canonicalType, worldCF, false, modelName, piece.MountSurface)
	BuildingGeometry.ApplyTierVisuals(model, canonicalType, piece.Tier)

	local maxHp = BuildingGeometry.ComputeMaxHp(canonicalType, piece.Tier)
	model:SetAttribute("BuildUid", piece.Uid)
	model:SetAttribute("PieceType", canonicalType)
	model:SetAttribute("Tier", piece.Tier)
	if piece.MountSurface ~= nil then
		model:SetAttribute("MountSurface", piece.MountSurface)
	end
	model:SetAttribute("OwnerUserId", owner.UserId)
	model:SetAttribute("PosX", piece.PosX)
	model:SetAttribute("PosY", piece.PosY)
	model:SetAttribute("PosZ", piece.PosZ)
	model:SetAttribute("RotY", piece.RotY)
	model:SetAttribute("Health", piece.Hp)
	model:SetAttribute("Hp", piece.Hp)
	model:SetAttribute("MaxHealth", maxHp)
	model:SetAttribute("MaxHp", maxHp)
	model:SetAttribute("LastDamagedAt", piece.LastDamagedAt or 0)
	model:SetAttribute("LastDamagedServerTime", 0)
	return model, worldCF
end

local function syncBaseState(player: Player)
	if player.Parent ~= Players then
		return
	end
	local data = DataService.GetData(player)
	if data ~= nil then
		Net.GetEvent(Net.Events.BaseStateSync):FireClient(player, data.Base.Pieces)
	end
end

getUpkeepDeps = function(): BaseUpkeep.UpkeepDeps
	return {
		SpawnedByPlayer = spawnedByPlayer,
		OccupiedSockets = occupiedSockets,
		StorageMapToInventory = storageMapToInventory,
		CleanupPieceRuntime = cleanupPieceRuntime,
		DestroyUnsupportedCascade = destroyUnsupportedCascade,
		RecalculateAndSyncBaseTier = recalculateAndSyncBaseTier,
		SyncBaseState = syncBaseState,
		SyncToolCupboardForPlayer = syncToolCupboardForPlayer,
	}
end

local function spawnPieceForPlayer(player: Player, piece: SavedBuildPiece)
	local playerRecords = spawnedByPlayer[player]
	if playerRecords == nil then
		playerRecords = {}
		spawnedByPlayer[player] = playerRecords
	end
	if playerRecords[piece.Uid] ~= nil then
		cleanupPieceRuntime(playerRecords[piece.Uid])
		playerRecords[piece.Uid] = nil
	end

	local model, worldCF = createPieceModel(player, piece)
	model.Parent = getOrCreateStructuresFolder()

	local containerId: string? = nil
	local canonicalType = BuildingGeometry.CanonicalPieceType(piece.PieceType)
	local pieceConfig = BuildingConfig.Pieces[canonicalType]
	if canonicalType == "storage_box" then
		local storageSlots = (if pieceConfig then pieceConfig.StorageSlots else nil) or 18
		piece.Storage = piece.Storage or {}
		local registeredId = LootService.RegisterStorageContainer(
			model,
			"Storage Box",
			player.UserId,
			storageSlots,
			storageMapToInventory(piece.Storage, storageSlots),
			function(updatedSlots: Inventory)
				piece.Storage = inventoryToStorageMap(updatedSlots, storageSlots)
			end
		)
		if #registeredId > 0 then
			containerId = registeredId
		end
	elseif canonicalType == "tool_cupboard" and model.PrimaryPart then
		piece.Storage = piece.Storage or {}
		local prompt = Instance.new("ProximityPrompt")
		prompt.Name = "ToolCupboardPrompt"
		prompt.ActionText = "Open Tool Cupboard"
		prompt.ObjectText = "Tool Cupboard"
		prompt.HoldDuration = 0
		prompt.MaxActivationDistance = 10
		prompt.RequiresLineOfSight = false
		prompt.Parent = model.PrimaryPart
		prompt.Triggered:Connect(function(triggerPlayer: Player)
			if triggerPlayer ~= player then
				return
			end
			if
				not SecurityService.IsWithinDistance(triggerPlayer, model.PrimaryPart.Position, Types.MAX_LOOT_DISTANCE)
			then
				return
			end
			openTcByPlayer[triggerPlayer] = piece.Uid
			syncToolCupboardForPlayer(triggerPlayer)
		end)
	elseif isWorkbenchType(canonicalType) and model.PrimaryPart then
		CraftingService.RegisterStation(piece.Uid, canonicalType, model.PrimaryPart.Position, player.UserId)
	elseif canonicalType == "research_table" and model.PrimaryPart then
		BlueprintService.RegisterResearchTable(piece.Uid, model, player.UserId)
	elseif Defenses.Get(canonicalType) ~= nil then
		local maxHp = BuildingGeometry.ComputeMaxHp(canonicalType, piece.Tier)
		DefenseService.RegisterDefense({
			Uid = piece.Uid,
			PieceType = canonicalType,
			Model = model,
			BaseWorldCF = worldCF,
			OwnerUserId = player.UserId,
			OwnerPlayer = player,
			IsRaidInstance = false,
			IsQaTest = false,
			PieceRef = piece,
			Hp = piece.Hp,
			MaxHp = maxHp,
			OnSelfDamage = function(defUid: string, dmg: number)
				BaseService.DamagePiece(defUid, dmg, "Tool", nil)
			end,
			OnSelfDestroy = function(defUid: string)
				local rec = recordsByUid[defUid]
				if rec ~= nil then
					BaseService.DamagePiece(defUid, rec.Piece.Hp + 1000, "Explosion", nil)
				end
			end,
			OnStorageChanged = function(_defUid: string)
				syncBaseState(player)
			end,
		})
	end

	local record: LivePieceRecord = {
		Owner = player,
		Piece = piece,
		Model = model,
		CFrame = worldCF,
		ContainerId = containerId,
		LastDamagedAt = piece.LastDamagedAt or 0,
	}
	playerRecords[piece.Uid] = record
	recordsByUid[piece.Uid] = record
	BuildingValidator.RegisterOccupationsForRecord(
		(record :: any) :: BuildingValidator.LivePieceEntry,
		(playerRecords :: any) :: { [string]: BuildingValidator.LivePieceEntry },
		occupiedSockets,
		occupiedWorldKeys
	)
end

function BaseService.BindRaidHooks(hooks: RaidHooks)
	raidHooks = hooks
end

function BaseService.ClearSessionGhosts(player: Player)
	BaseGhosts.ClearSessionGhosts(player)
end

function BaseService.SpawnSessionDeathGhosts(player: Player): number
	return BaseGhosts.SpawnSessionDeathGhosts(player)
end

local function despawnBaseForPlayer(player: Player)
	BaseService.ClearSessionGhosts(player)
	local playerRecords = spawnedByPlayer[player]
	if playerRecords == nil then
		return
	end
	spawnedByPlayer[player] = nil
	for _, record in playerRecords do
		cleanupPieceRuntime(record)
	end
end

local function spawnBaseForPlayer(player: Player, data: Types.PlayerData)
	despawnBaseForPlayer(player)
	for _, piece in data.Base.Pieces do
		spawnPieceForPlayer(player, piece)
	end
	if data.Base.LastUpkeepTimestamp > 0 then
		local offlineElapsed = os.time() - data.Base.LastUpkeepTimestamp
		if offlineElapsed >= Config.Decay.TickIntervalSeconds then
			BaseService.ProcessUpkeepAndDecay(player, offlineElapsed)
		end
	end
	data.Base.LastUpkeepTimestamp = os.time()
	recalculateAndSyncBaseTier(player)
	syncBaseState(player)
	BaseService.SpawnSessionDeathGhosts(player)
end

local function costMapToBatch(costMap: { [string]: number }): { ItemBatchEntry }
	local entries: { ItemBatchEntry } = {}
	for itemId, count in costMap do
		if count > 0 then
			table.insert(entries, { Id = itemId, Count = count })
		end
	end
	return entries
end

local function onBuildPlaceRequest(
	player: Player,
	pieceTypeAny: any,
	targetCFrameAny: any,
	parentUidAny: any,
	socketIdAny: any,
	rotStepAny: any,
	mountSurfaceAny: any
)
	if player:GetAttribute("InRaid") == true then
		return
	end
	if not SecurityService.CheckRateLimit(player, Net.Events.BuildPlaceRequest) then
		return
	end
	if
		not BaseService.CanBuild(player)
		or DataService.IsTeleporting(player)
		or SecurityService.IsTransactionLocked(player)
	then
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

	local mountSurfaceHint: Types.DefenseMountSurface? = nil
	if mountSurfaceAny == "Floor" or mountSurfaceAny == "Wall" or mountSurfaceAny == "Ceiling" then
		mountSurfaceHint = mountSurfaceAny :: Types.DefenseMountSurface
	end

	local _, hrp = SecurityService.GetAliveCharacterRoot(player)
	if not hrp then
		return
	end

	SecurityService.RunLocked(player, "BuildPlace", function()
		if not BaseService.CanBuild(player) then
			return
		end
		local character, innerHrp = SecurityService.GetAliveCharacterRoot(player)
		if not innerHrp then
			return
		end

		local now = os.clock()
		local prevAction = lastBuildActionTime[player]
		if prevAction ~= nil and (now - prevAction) < BUILD_ACTION_COOLDOWN then
			return
		end

		local data = DataService.GetData(player)
		if data == nil or #data.Base.Pieces >= BuildingConfig.MaxPiecesPerBase then
			return
		end

		local playerRecords = spawnedByPlayer[player]
		if playerRecords == nil then
			playerRecords = {}
			spawnedByPlayer[player] = playerRecords
		end

		local validation = BuildingValidator.ValidatePlacement({
			Player = player,
			Character = character,
			HrpPosition = innerHrp.Position,
			PieceType = pieceType,
			RequestedCFrame = requestedCF,
			ParentUid = parentUid,
			SocketId = socketId,
			ExplicitRotStep = explicitRotStep,
			MountSurface = mountSurfaceHint,
			PlayerRecords = (playerRecords :: any) :: { [string]: BuildingValidator.LivePieceEntry },
			AllRecordsByUid = (recordsByUid :: any) :: { [string]: BuildingValidator.LivePieceEntry },
			OccupiedSockets = occupiedSockets,
			OccupiedWorldKeys = occupiedWorldKeys,
			BasePieces = data.Base.Pieces,
			PlayerBaseTier = data.Base.BaseTier,
		})

		if not validation.Allowed or validation.AuthoritativeCFrame == nil then
			sendBuildFeedback(
				player,
				false,
				validation.Reason or "Нельзя установить объект здесь",
				data.Base.BaseTier
			)
			return
		end

		local equippedSlotIdx = InventoryService.GetEquippedSlot(player)
		local equippedSlot = InventoryService.GetEquippedItem(player)
		local isDeployableItem = pieceConfig.IsDefense == true
			or pieceType == "tool_cupboard"
			or pieceType == "workbench_1"
			or pieceType == "workbench_2"
			or pieceType == "workbench_3"
			or pieceType == "research_table"
		local isUsingEquippedDeployableItem = isDeployableItem
			and equippedSlot ~= nil
			and BuildingGeometry.CanonicalPieceType(equippedSlot.Id) == pieceType
			and equippedSlot.Count > 0

		if isUsingEquippedDeployableItem then
			if not InventoryService.ConsumeSlot(player, equippedSlotIdx, 1) then
				sendBuildFeedback(player, false, "Недостаточно предметов", data.Base.BaseTier)
				return
			end
		else
			if pieceConfig.IsDefense == true then
				local reqWb = REQUIRED_WB_BY_PIECE[pieceType] or 0
				if reqWb > 0 and CraftingService.GetPlayerWorkbenchTier(player, true) < reqWb then
					sendBuildFeedback(
						player,
						false,
						string.format(
							"Требуется верстак Lv.%d рядом или предмет в слоте",
							reqWb
						),
						data.Base.BaseTier
					)
					return
				end
			end
			if not InventoryService.RemoveItems(player, costMapToBatch(pieceConfig.Cost)) then
				sendBuildFeedback(player, false, "Недостаточно ресурсов", data.Base.BaseTier)
				return
			end
		end

		lastBuildActionTime[player] = now
		local pos = validation.AuthoritativeCFrame.Position
		local rotY = validation.RotY
			or BuildingGeometry.QuantizeYaw30(BuildingGeometry.ExtractYawDegrees(validation.AuthoritativeCFrame))

		local newPiece: SavedBuildPiece = {
			Uid = HttpService:GenerateGUID(false),
			PieceType = pieceType,
			Tier = "wood",
			PosX = pos.X,
			PosY = pos.Y,
			PosZ = pos.Z,
			RotY = rotY,
			ParentUid = validation.ResolvedParentUid,
			AnchorUid = validation.ResolvedParentUid,
			SocketId = validation.ResolvedSocketId,
			MountSurface = validation.ResolvedMountSurface,
			Hp = pieceConfig.BaseHp,
			LastDamagedAt = 0,
			Storage = if pieceConfig.StorageSlots ~= nil then {} else nil,
		}

		table.insert(data.Base.Pieces, newPiece)
		spawnPieceForPlayer(player, newPiece)
		recalculateAndSyncBaseTier(player)
		syncBaseState(player)
	end)
end

local function onBuildUpgradeRequest(player: Player, uidAny: any, targetTierAny: any)
	if not SecurityService.CheckRateLimit(player, Net.Events.BuildUpgradeRequest) then
		return
	end
	if
		not BaseService.CanBuild(player)
		or DataService.IsTeleporting(player)
		or SecurityService.IsTransactionLocked(player)
	then
		return
	end
	if not SecurityService.IsValidString(uidAny, 1, 64) or not SecurityService.IsValidString(targetTierAny, 1, 32) then
		return
	end
	local targetTier = targetTierAny :: BuildTier
	local targetTierConfig = BuildingConfig.Tiers[targetTier]
	if targetTierConfig == nil then
		return
	end
	local uid = uidAny :: string
	if SecurityService.GetAliveCharacterRoot(player) == nil then
		return
	end

	SecurityService.RunLocked(player, "BuildUpgrade", function()
		if not BaseService.CanBuild(player) then
			return
		end
		local _, innerHrp = SecurityService.GetAliveCharacterRoot(player)
		if not innerHrp then
			return
		end

		local now = os.clock()
		local prevAction = lastBuildActionTime[player]
		if prevAction ~= nil and (now - prevAction) < BUILD_ACTION_COOLDOWN then
			return
		end

		local data = DataService.GetData(player)
		local record = recordsByUid[uid]
		if data == nil or record == nil or record.Owner ~= player or not record.Model.Parent then
			return
		end

		if
			(innerHrp.Position - record.CFrame.Position).Magnitude
			> BuildingConfig.MaxBuildDistance + Types.PING_DISTANCE_TOLERANCE
		then
			return
		end

		local targetPiece = record.Piece
		local pieceConfig = BuildingConfig.Pieces[targetPiece.PieceType]
		local currentTierConfig = BuildingConfig.Tiers[targetPiece.Tier]
		if pieceConfig == nil or not pieceConfig.Upgradeable or currentTierConfig == nil then
			return
		end

		if
			targetTierConfig.Rank <= currentTierConfig.Rank
			or BuildingConfig.GetNextTier(targetPiece.Tier) ~= targetTier
		then
			return
		end

		local attrDamaged = record.Model:GetAttribute("LastDamagedAt")
		local lastDamagedAt = math.max(
			targetPiece.LastDamagedAt or 0,
			record.LastDamagedAt or 0,
			if typeof(attrDamaged) == "number" then attrDamaged else 0
		)
		if lastDamagedAt > 0 and (now - lastDamagedAt) < BuildingConfig.UpgradeRaidBlockSeconds then
			return
		end

		if
			targetTierConfig.UpgradeCost == nil
			or not InventoryService.RemoveItems(player, costMapToBatch(targetTierConfig.UpgradeCost))
		then
			return
		end

		lastBuildActionTime[player] = now
		local maxHp = BuildingGeometry.ComputeMaxHp(targetPiece.PieceType, targetTier)
		targetPiece.Tier = targetTier
		targetPiece.Hp = maxHp

		BuildingGeometry.ApplyTierVisuals(record.Model, targetPiece.PieceType, targetTier)
		record.Model:SetAttribute("Tier", targetTier)
		record.Model:SetAttribute("Health", maxHp)
		record.Model:SetAttribute("Hp", maxHp)
		record.Model:SetAttribute("MaxHealth", maxHp)
		record.Model:SetAttribute("MaxHp", maxHp)

		recalculateAndSyncBaseTier(player)
		syncBaseState(player)
	end)
end

local function onBuildDemolishRequest(player: Player, uidAny: any)
	if not SecurityService.CheckRateLimit(player, Net.Events.BuildDemolishRequest) then
		return
	end
	if
		not BaseService.CanBuild(player)
		or DataService.IsTeleporting(player)
		or SecurityService.IsTransactionLocked(player)
	then
		return
	end
	if not SecurityService.IsValidString(uidAny, 1, 64) or SecurityService.GetAliveCharacterRoot(player) == nil then
		return
	end
	local uid = uidAny :: string

	SecurityService.RunLocked(player, "BuildDemolish", function()
		if not BaseService.CanBuild(player) then
			return
		end
		local _, innerHrp = SecurityService.GetAliveCharacterRoot(player)
		if not innerHrp then
			return
		end

		local now = os.clock()
		local prevAction = lastBuildActionTime[player]
		if prevAction ~= nil and (now - prevAction) < BUILD_ACTION_COOLDOWN then
			return
		end

		local data = DataService.GetData(player)
		local record = recordsByUid[uid]
		if data == nil or record == nil or record.Owner ~= player then
			return
		end
		if
			(innerHrp.Position - record.CFrame.Position).Magnitude
			> BuildingConfig.MaxBuildDistance + Types.PING_DISTANCE_TOLERANCE
		then
			return
		end

		local targetIndex: number? = nil
		for index, piece in data.Base.Pieces do
			if piece.Uid == uid then
				targetIndex = index
				break
			end
		end
		if targetIndex == nil then
			return
		end

		local canonicalRemoved = BuildingGeometry.CanonicalPieceType(record.Piece.PieceType)
		local removedConfig = BuildingConfig.Pieces[canonicalRemoved]
		local playerRecords = spawnedByPlayer[player]
		if removedConfig ~= nil and removedConfig.Category == "Stairs" and playerRecords ~= nil then
			local reachOk, reachReason = BuildingValidator.CheckMaxWallsToTC(
				(playerRecords :: any) :: { [string]: BuildingValidator.LivePieceEntry },
				occupiedSockets,
				nil,
				uid
			)
			if not reachOk then
				sendBuildFeedback(
					player,
					false,
					reachReason
						or "Нельзя снести лестницу: превышен лимит слоёв стен до TC",
					data.Base.BaseTier
				)
				return
			end
		end

		local unsupportedDependents = BuildingValidator.FindUnsupportedPieces(data.Base.Pieces, { [uid] = true })
		if #unsupportedDependents > 0 then
			sendBuildFeedback(
				player,
				false,
				string.format(
					"Сначала снесите верхние/зависимые элементы (%d шт.)",
					#unsupportedDependents
				),
				data.Base.BaseTier
			)
			return
		end

		local isDefense = Defenses.Get(canonicalRemoved) ~= nil
		if isDefense then
			if not InventoryService.CanCraftTransaction(player, {}, canonicalRemoved, 1) then
				sendBuildFeedback(
					player,
					false,
					"Освободите слот в инвентаре для снятия защиты",
					data.Base.BaseTier
				)
				return
			end
		end

		lastBuildActionTime[player] = now
		if isDefense then
			InventoryService.AddItem(player, canonicalRemoved, 1)
			if type(record.Piece.Storage) == "table" then
				for _, slot in record.Piece.Storage do
					if
						type(slot) == "table"
						and type(slot.Id) == "string"
						and type(slot.Count) == "number"
						and slot.Count > 0
					then
						InventoryService.AddItem(player, slot.Id, math.floor(slot.Count))
					end
				end
				record.Piece.Storage = nil
			end
		end

		if playerRecords ~= nil then
			playerRecords[uid] = nil
		end
		cleanupPieceRuntime(record)
		table.remove(data.Base.Pieces, targetIndex)
		recalculateAndSyncBaseTier(player)
		syncBaseState(player)
	end)
end

local function onBuildRepairRequest(player: Player, uidAny: any)
	if not SecurityService.CheckRateLimit(player, Net.Events.BuildRepairRequest) then
		return
	end
	if
		not BaseService.CanBuild(player)
		or DataService.IsTeleporting(player)
		or SecurityService.IsTransactionLocked(player)
	then
		return
	end
	if not SecurityService.IsValidString(uidAny, 1, 64) or SecurityService.GetAliveCharacterRoot(player) == nil then
		return
	end
	local uid = uidAny :: string

	SecurityService.RunLocked(player, "BuildRepair", function()
		if not BaseService.CanBuild(player) then
			return
		end
		local _, innerHrp = SecurityService.GetAliveCharacterRoot(player)
		if not innerHrp then
			return
		end

		local now = os.clock()
		local prevAction = lastBuildActionTime[player]
		if prevAction ~= nil and (now - prevAction) < BUILD_ACTION_COOLDOWN then
			return
		end

		local data = DataService.GetData(player)
		local record = recordsByUid[uid]
		if data == nil or record == nil or record.Owner ~= player or not record.Model.Parent then
			return
		end

		if
			(innerHrp.Position - record.CFrame.Position).Magnitude
			> BuildingConfig.MaxBuildDistance + Types.PING_DISTANCE_TOLERANCE
		then
			return
		end

		local targetPiece = record.Piece
		local pieceConfig = BuildingConfig.Pieces[targetPiece.PieceType]
		if pieceConfig == nil then
			return
		end

		local maxHp = BuildingGeometry.ComputeMaxHp(targetPiece.PieceType, targetPiece.Tier)
		if targetPiece.Hp >= maxHp then
			return
		end

		local attrDamaged = record.Model:GetAttribute("LastDamagedAt")
		local lastDamagedAt = math.max(
			targetPiece.LastDamagedAt or 0,
			record.LastDamagedAt or 0,
			if typeof(attrDamaged) == "number" then attrDamaged else 0
		)
		if lastDamagedAt > 0 and (now - lastDamagedAt) < BuildingConfig.UpgradeRaidBlockSeconds then
			sendBuildFeedback(
				player,
				false,
				"Нельзя чинить сразу после урона",
				data.Base.BaseTier
			)
			return
		end

		local missingRatio = math.clamp((maxHp - targetPiece.Hp) / math.max(1, maxHp), 0.05, 1.0)
		local repairCostMap: { [string]: number } = {}
		for resId, costCount in pieceConfig.Cost do
			local amt = math.max(1, math.ceil(costCount * missingRatio * 0.5))
			repairCostMap[resId] = (repairCostMap[resId] or 0) + amt
		end
		local tierCfg = BuildingConfig.Tiers[targetPiece.Tier]
		if tierCfg ~= nil and tierCfg.UpgradeCost ~= nil then
			for resId, costCount in tierCfg.UpgradeCost do
				local amt = math.max(1, math.ceil(costCount * missingRatio * 0.5))
				repairCostMap[resId] = (repairCostMap[resId] or 0) + amt
			end
		end

		if not InventoryService.RemoveItems(player, costMapToBatch(repairCostMap)) then
			sendBuildFeedback(
				player,
				false,
				"Недостаточно ресурсов для ремонта",
				data.Base.BaseTier
			)
			return
		end

		lastBuildActionTime[player] = now
		targetPiece.Hp = maxHp
		record.Model:SetAttribute("Health", maxHp)
		record.Model:SetAttribute("Hp", maxHp)
		DefenseService.UpdateDefenseHp(uid, maxHp, maxHp)
		syncBaseState(player)
		sendBuildFeedback(
			player,
			true,
			string.format("%s отремонтирован (%d HP)", pieceConfig.Name, maxHp),
			data.Base.BaseTier
		)
	end)
end

function BaseService.ProcessUpkeepAndDecay(player: Player, elapsedSeconds: number): boolean
	return BaseUpkeep.ProcessUpkeepAndDecay(player, elapsedSeconds, getUpkeepDeps())
end

local function onToolCupboardAction(player: Player, actionAny: any, arg1Any: any)
	if not SecurityService.CheckRateLimit(player, Net.Events.ToolCupboardAction) then
		return
	end
	if
		not BaseService.CanBuild(player)
		or DataService.IsTeleporting(player)
		or SecurityService.IsTransactionLocked(player)
	then
		return
	end
	if not SecurityService.IsValidString(actionAny, 1, 24) then
		return
	end
	local action = actionAny :: string

	if action == "Close" then
		openTcByPlayer[player] = nil
		Net.GetEvent(Net.Events.ToolCupboardSync):FireClient(player, nil)
		return
	end

	if SecurityService.GetAliveCharacterRoot(player) == nil then
		return
	end

	local shouldStartSelfRaid = false
	SecurityService.RunLocked(player, "ToolCupboardAction", function()
		if not BaseService.CanBuild(player) then
			return
		end
		local data = DataService.GetData(player)
		if data == nil then
			return
		end
		local tcPiece = BaseUpkeep.FindToolCupboardPiece(data.Base.Pieces)
		if tcPiece == nil then
			openTcByPlayer[player] = nil
			Net.GetEvent(Net.Events.ToolCupboardSync):FireClient(player, nil)
			return
		end

		local playerRecords = spawnedByPlayer[player]
		local tcRecord = if playerRecords ~= nil then playerRecords[tcPiece.Uid] else nil
		if tcRecord == nil or tcRecord.Model.Parent == nil then
			return
		end
		if not SecurityService.IsWithinDistance(player, tcRecord.CFrame.Position, Types.MAX_LOOT_DISTANCE) then
			return
		end

		tcPiece.Storage = tcPiece.Storage or {}
		local maxSlots = Config.Upkeep.TcStorageSlots

		if action == "Open" then
			openTcByPlayer[player] = tcPiece.Uid
			syncToolCupboardForPlayer(player)
		elseif action == "StartSelfRaid" then
			openTcByPlayer[player] = nil
			Net.GetEvent(Net.Events.ToolCupboardSync):FireClient(player, nil)
			shouldStartSelfRaid = true
		elseif action == "Deposit" then
			if not SecurityService.IsValidInteger(arg1Any, 1, Types.INVENTORY_SIZE) then
				return
			end
			local playerSlotIndex = arg1Any :: number
			local invSlot = InventoryService.GetSlot(player, playerSlotIndex)
			if invSlot == nil or invSlot.Count <= 0 then
				return
			end
			if table.find(Config.Upkeep.AllowedResourceIds, invSlot.Id) == nil then
				sendBuildFeedback(
					player,
					false,
					"В шкаф можно положить только ресурсы содержания",
					data.Base.BaseTier
				)
				return
			end

			local itemCfg = Items[invSlot.Id]
			local maxStack = if itemCfg ~= nil then itemCfg.MaxStack else 1000
			local remaining = invSlot.Count
			local storageCopy: { [string]: Slot } = {}
			for i = 1, maxSlots do
				local k = tostring(i)
				local existing = tcPiece.Storage[k]
				if existing ~= nil then
					storageCopy[k] = { Id = existing.Id, Count = existing.Count }
				end
			end

			for i = 1, maxSlots do
				if remaining <= 0 then
					break
				end
				local k = tostring(i)
				local existing = storageCopy[k]
				if existing ~= nil and existing.Id == invSlot.Id and existing.Count < maxStack then
					local canAdd = math.min(remaining, maxStack - existing.Count)
					if canAdd > 0 then
						existing.Count += canAdd
						remaining -= canAdd
					end
				end
			end

			for i = 1, maxSlots do
				if remaining <= 0 then
					break
				end
				local k = tostring(i)
				if storageCopy[k] == nil then
					local toAdd = math.min(remaining, maxStack)
					if toAdd > 0 then
						storageCopy[k] = { Id = invSlot.Id, Count = toAdd }
						remaining -= toAdd
					end
				end
			end

			local moved = invSlot.Count - remaining
			if moved <= 0 then
				sendBuildFeedback(player, false, "Шкаф (TC) переполнен", data.Base.BaseTier)
				return
			end
			if InventoryService.ConsumeSlot(player, playerSlotIndex, moved) then
				tcPiece.Storage = storageCopy
				openTcByPlayer[player] = tcPiece.Uid
				recalculateAndSyncBaseTier(player)
			end
		elseif action == "Withdraw" then
			if not SecurityService.IsValidInteger(arg1Any, 1, maxSlots) then
				return
			end
			local tcSlotKey = tostring(arg1Any :: number)
			local tcSlot = tcPiece.Storage[tcSlotKey]
			if tcSlot == nil or tcSlot.Count <= 0 then
				return
			end
			local remaining = InventoryService.AddItem(player, tcSlot.Id, tcSlot.Count)
			if remaining <= 0 then
				tcPiece.Storage[tcSlotKey] = nil
			elseif remaining < tcSlot.Count then
				tcSlot.Count = remaining
			end
			openTcByPlayer[player] = tcPiece.Uid
			recalculateAndSyncBaseTier(player)
		end
	end)

	if shouldStartSelfRaid then
		if raidHooks.StartSelfRaid ~= nil then
			BaseService.ClearSessionGhosts(player)
			raidHooks.StartSelfRaid(player)
		else
			sendBuildFeedback(player, false, "Self-Raid test unavailable", BaseService.GetPlayerBaseTier(player))
		end
	end
end

local function sendReturnBanner(player: Player, active: boolean, statusText: string?)
	if player.Parent == Players then
		Net.GetEvent(Net.Events.ExtractionStateSync):FireClient(player, {
			Active = active,
			ZoneName = "Base Portal",
			TimeLeft = 0,
			TotalTime = 1,
			StatusText = statusText,
		})
	end
end

local function onRequestReturnToMap(player: Player, mapKeyAny: any)
	if not SecurityService.CheckRateLimit(player, Net.Events.RequestReturnToMap) or not BaseService.IsBaseMode() then
		return
	end
	if teleportInProgress[player] or SecurityService.IsTeleportLocked(player) then
		return
	end
	local data = DataService.GetData(player)
	if data == nil then
		return
	end
	if SecurityService.GetAliveCharacterRoot(player) == nil then
		return
	end

	local mapKey = if SecurityService.IsValidString(mapKeyAny, 1, 64) then mapKeyAny :: string else "MainMap_Tier1"
	local canAccess, reason = ExtractionService.CanAccessMap(player, mapKey, data.Base.BaseTier)
	if not canAccess then
		local msg = reason or "Недостаточный уровень базы для этой PvP-карты"
		sendBuildFeedback(player, false, msg, data.Base.BaseTier)
		sendReturnBanner(player, true, msg)
		task.delay(3.5, function()
			if player.Parent == Players and pendingTeleports[player] == nil and not teleportInProgress[player] then
				sendReturnBanner(player, false, nil)
			end
		end)
		return
	end

	local maps = Config.Maps :: { [string]: { Key: string, Name: string, PlaceId: number, RequiredBaseTier: number } }
	local mapCfg = maps[mapKey]
	local targetPlaceId = if mapCfg ~= nil then mapCfg.PlaceId else Config.Places.MainMap
	local targetMapName = if mapCfg ~= nil then mapCfg.Name else "PvP Map"

	teleportInProgress[player] = true
	SecurityService.SetTeleportLock(player, true)
	LootService.CloseContainerForPlayer(player, true)
	BaseService.ClearSessionGhosts(player)

	if RunService:IsStudio() then
		DataService.ReleaseForTeleport(player)
		sendReturnBanner(player, true, string.format("Deploying to %s (Studio Simulation)", targetMapName))
		task.delay(STUDIO_SIM_BANNER_DURATION, function()
			if player.Parent == Players and pendingTeleports[player] == nil then
				sendReturnBanner(player, false, nil)
			end
		end)
		return
	end

	task.spawn(function()
		sendReturnBanner(player, true, string.format("Saving base & deploying to %s...", targetMapName))
		if not DataService.ReleaseForTeleport(player) then
			DataService.RestoreAfterFailedTeleport(player)
			teleportInProgress[player] = nil
			sendReturnBanner(player, false, nil)
			return
		end
		if player.Parent ~= Players then
			teleportInProgress[player] = nil
			SecurityService.SetTeleportLock(player, false)
			return
		end

		local options = Instance.new("TeleportOptions")
		options:SetTeleportData({
			FromPlaceId = game.PlaceId,
			OwnerUserId = player.UserId,
			Mode = "Raid",
			TargetMapKey = mapKey,
		})
		pendingTeleports[player] = true
		local ok = pcall(function()
			TeleportService:TeleportAsync(targetPlaceId, { player }, options)
		end)
		if not ok then
			pendingTeleports[player] = nil
			teleportInProgress[player] = nil
			DataService.RestoreAfterFailedTeleport(player)
			sendReturnBanner(player, false, nil)
		end
	end)
end

local function onTeleportInitFailed(player: Player)
	if pendingTeleports[player] then
		pendingTeleports[player] = nil
		teleportInProgress[player] = nil
		DataService.RestoreAfterFailedTeleport(player)
		sendReturnBanner(player, false, nil)
	end
end

function BaseService.IsBaseMode(): boolean
	if Workspace:GetAttribute("RaidServerMode") == true then
		return false
	end
	if game.PlaceId == Config.Places.PlayerBase and game.PrivateServerId ~= "" and game.PrivateServerOwnerId == 0 then
		return false
	end
	return game.PlaceId == Config.Places.PlayerBase
		or (RunService:IsStudio() and Workspace:GetAttribute("ForceBaseMode") == true)
end

function BaseService.CanBuild(player: Player): boolean
	if player.Parent ~= Players then
		return false
	end
	if Workspace:GetAttribute("RaidServerMode") == true or player:GetAttribute("InRaid") == true then
		return false
	end
	return not DataService.IsTeleporting(player) and not SecurityService.IsTeleportLocked(player)
end

function BaseService.DamagePiece(
	uid: string,
	rawDamage: number,
	damageKind: DamageKind,
	_attacker: Player?
): (boolean, boolean)
	if not SecurityService.IsFiniteNumber(rawDamage) or rawDamage <= 0 then
		return false, false
	end
	local record = recordsByUid[uid]
	if record == nil or record.Model.Parent == nil then
		return false, false
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
	record.LastDamagedAt = nowClock
	record.Piece.LastDamagedAt = nowClock
	record.Model:SetAttribute("LastDamagedAt", nowClock)
	record.Model:SetAttribute("LastDamagedServerTime", Workspace:GetServerTimeNow())

	record.Piece.Hp -= finalDamage
	if record.Piece.Hp <= 0 then
		local owner = record.Owner
		local data = DataService.GetData(owner)
		local playerRecords = spawnedByPlayer[owner]
		if playerRecords ~= nil then
			playerRecords[uid] = nil
		end
		cleanupPieceRuntime(record)
		if data ~= nil then
			for index, piece in data.Base.Pieces do
				if piece.Uid == uid then
					table.remove(data.Base.Pieces, index)
					break
				end
			end
			destroyUnsupportedCascade(owner, data)
			recalculateAndSyncBaseTier(owner)
			syncBaseState(owner)
		end
		return true, true
	end

	record.Model:SetAttribute("Health", record.Piece.Hp)
	record.Model:SetAttribute("Hp", record.Piece.Hp)
	DefenseService.UpdateDefenseHp(uid, record.Piece.Hp, nil)
	syncBaseState(record.Owner)
	return true, false
end

function BaseService.GetLivePieceModelsInRadius(origin: Vector3, radius: number): { { Uid: string, Model: Model } }
	local result: { { Uid: string, Model: Model } } = {}
	for uid, record in recordsByUid do
		if
			record.Model.Parent ~= nil
			and (record.CFrame.Position - origin).Magnitude <= radius + BuildingConfig.GridSize
		then
			table.insert(result, { Uid = uid, Model = record.Model })
		end
	end
	return result
end

function BaseService.GetPlayerPieces(player: Player): { SavedBuildPiece }
	local data = DataService.GetData(player)
	return if data ~= nil then table.clone(data.Base.Pieces) else {}
end

function BaseService.GetStorageContainerId(player: Player, uid: string): string?
	local playerRecords = spawnedByPlayer[player]
	local record = if playerRecords ~= nil then playerRecords[uid] else nil
	return if record ~= nil then record.ContainerId else nil
end

function BaseService.DepositScrapToToolCupboard(player: Player, amount: number): number
	return BaseUpkeep.DepositScrapToToolCupboard(player, amount, getUpkeepDeps())
end

function BaseService.DepositItemsToPlayerBase(player: Player, items: { ItemBatchEntry }): (number, number)
	return BaseUpkeep.DepositItemsToPlayerBase(player, items, getUpkeepDeps())
end

function BaseService.Init()
	if isInitialized then
		return
	end
	isInitialized = true

	Net.InitServer()
	getOrCreateStructuresFolder()

	Net.GetEvent(Net.Events.BuildPlaceRequest).OnServerEvent:Connect(onBuildPlaceRequest)
	Net.GetEvent(Net.Events.BuildUpgradeRequest).OnServerEvent:Connect(onBuildUpgradeRequest)
	Net.GetEvent(Net.Events.BuildDemolishRequest).OnServerEvent:Connect(onBuildDemolishRequest)
	Net.GetEvent(Net.Events.BuildRepairRequest).OnServerEvent:Connect(onBuildRepairRequest)
	Net.GetEvent(Net.Events.RequestReturnToMap).OnServerEvent:Connect(onRequestReturnToMap)
	Net.GetEvent(Net.Events.ToolCupboardAction).OnServerEvent:Connect(onToolCupboardAction)
	TeleportService.TeleportInitFailed:Connect(onTeleportInitFailed)

	DataService.OnBeforeUnload(function(_player: Player, data: Types.PlayerData)
		data.Base.LastUpkeepTimestamp = os.time()
	end)

	DataService.OnDataLoaded(function(player: Player, data: Types.PlayerData)
		local isRaidJoin = false
		local ok, joinData = pcall(function()
			return player:GetJoinData()
		end)
		if
			ok
			and type(joinData) == "table"
			and type(joinData.TeleportData) == "table"
			and (joinData.TeleportData.Mode == "Raid" or joinData.TeleportData.Mode == "RaidDefense")
		then
			isRaidJoin = true
		end
		local canSpawn = not isRaidJoin
			and Workspace:GetAttribute("RaidServerMode") ~= true
			and player:GetAttribute("InRaid") ~= true
			and (BaseService.IsBaseMode() or RunService:IsStudio())
		if canSpawn then
			spawnBaseForPlayer(player, data)
		end
	end)

	if RunService:IsStudio() then
		Workspace:GetAttributeChangedSignal("ForceBaseMode"):Connect(function()
			if BaseService.IsBaseMode() or RunService:IsStudio() then
				getOrCreateStructuresFolder()
				for _, player in Players:GetPlayers() do
					local data = DataService.GetData(player)
					if data ~= nil and spawnedByPlayer[player] == nil then
						spawnBaseForPlayer(player, data)
					end
				end
			else
				for _, player in Players:GetPlayers() do
					despawnBaseForPlayer(player)
				end
			end
		end)
	end

	Players.PlayerRemoving:Connect(function(player: Player)
		despawnBaseForPlayer(player)
		lastBuildActionTime[player] = nil
		teleportInProgress[player] = nil
		pendingTeleports[player] = nil
		openTcByPlayer[player] = nil
		BaseUpkeep.ClearPlayerState(player)
	end)

	task.spawn(function()
		while true do
			task.wait(Config.Decay.TickIntervalSeconds)
			if BaseService.IsBaseMode() or RunService:IsStudio() then
				for _, player in Players:GetPlayers() do
					if spawnedByPlayer[player] ~= nil and DataService.GetData(player) ~= nil then
						SecurityService.RunLocked(player, "UpkeepDecayTick", function()
							BaseService.ProcessUpkeepAndDecay(player, Config.Decay.TickIntervalSeconds)
						end)
					end
				end
			end
		end
	end)
end

return BaseService
