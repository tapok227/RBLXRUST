--!strict
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Types = require(ReplicatedStorage.Shared.Types)
local BuildingConfig = require(ReplicatedStorage.Shared.configs.BuildingConfig)
local BuildingGeometry = require(ReplicatedStorage.Shared.BuildingGeometry)
local BaseSerializer = require(ReplicatedStorage.Shared.BaseSerializer)
local BuildingValidator = require(ServerScriptService.Server.Services.BuildingValidator)
local BaseUpkeep = require(ServerScriptService.Server.Services.Base.BaseUpkeep)
local DataService = require(ServerScriptService.Server.Services.DataService)

type BuildPieceType = Types.BuildPieceType
type BuildTier = Types.BuildTier
type SavedBuildPiece = Types.SavedBuildPiece
type BlueprintPieceEntry = Types.BlueprintPieceEntry
type BaseBlueprintSlot = Types.BaseBlueprintSlot
type BaseBlueprintSummary = Types.BaseBlueprintSummary
type DefenseMountSurface = Types.DefenseMountSurface

export type BlueprintLoadDeps = {
	SpawnedByPlayer: { [Player]: { [string]: BaseUpkeep.LivePieceEntry } },
	RecordsByUid: { [string]: BaseUpkeep.LivePieceEntry },
	OccupiedSockets: { [string]: { [string]: string } },
	OccupiedWorldKeys: { [string]: string },
	CleanupPieceRuntime: (record: BaseUpkeep.LivePieceEntry) -> (),
	SpawnPieceForPlayer: (player: Player, piece: SavedBuildPiece) -> (),
	RecalculateAndSyncBaseTier: (player: Player) -> (),
	SyncBaseState: (player: Player) -> (),
	SyncToolCupboardForPlayer: (player: Player) -> (),
}

local MAX_SLOTS = 2
local BUILTIN_2X2_ID = "builtin_2x2"
local BUILTIN_2X2_NAME = "Компактный 2x2 с бункером"

local BUILTIN_2X2_PIECES: { BlueprintPieceEntry } = table.freeze({
	-- 4 Square Foundations (TC sits at (0,0,0) on top of (0,-1,0))
	table.freeze({
		PieceType = "foundation" :: BuildPieceType,
		Tier = "wood" :: BuildTier,
		RelX = 0,
		RelY = -1,
		RelZ = 0,
		RelRotY = 0,
	}),
	table.freeze({
		PieceType = "foundation" :: BuildPieceType,
		Tier = "wood" :: BuildTier,
		RelX = 12,
		RelY = -1,
		RelZ = 0,
		RelRotY = 0,
	}),
	table.freeze({
		PieceType = "foundation" :: BuildPieceType,
		Tier = "wood" :: BuildTier,
		RelX = 0,
		RelY = -1,
		RelZ = -12,
		RelRotY = 0,
	}),
	table.freeze({
		PieceType = "foundation" :: BuildPieceType,
		Tier = "wood" :: BuildTier,
		RelX = 12,
		RelY = -1,
		RelZ = -12,
		RelRotY = 0,
	}),
	-- Outer perimeter walls & entrance doorway
	table.freeze({
		PieceType = "wall" :: BuildPieceType,
		Tier = "wood" :: BuildTier,
		RelX = 0,
		RelY = 0,
		RelZ = 6,
		RelRotY = 180,
	}),
	table.freeze({
		PieceType = "doorway" :: BuildPieceType,
		Tier = "wood" :: BuildTier,
		RelX = 12,
		RelY = 0,
		RelZ = 6,
		RelRotY = 180,
	}),
	table.freeze({
		PieceType = "wall" :: BuildPieceType,
		Tier = "wood" :: BuildTier,
		RelX = 18,
		RelY = 0,
		RelZ = 0,
		RelRotY = 270,
	}),
	table.freeze({
		PieceType = "wall" :: BuildPieceType,
		Tier = "wood" :: BuildTier,
		RelX = 18,
		RelY = 0,
		RelZ = -12,
		RelRotY = 270,
	}),
	table.freeze({
		PieceType = "wall" :: BuildPieceType,
		Tier = "wood" :: BuildTier,
		RelX = 0,
		RelY = 0,
		RelZ = -18,
		RelRotY = 0,
	}),
	table.freeze({
		PieceType = "wall" :: BuildPieceType,
		Tier = "wood" :: BuildTier,
		RelX = 12,
		RelY = 0,
		RelZ = -18,
		RelRotY = 0,
	}),
	table.freeze({
		PieceType = "wall" :: BuildPieceType,
		Tier = "wood" :: BuildTier,
		RelX = -6,
		RelY = 0,
		RelZ = 0,
		RelRotY = 90,
	}),
	table.freeze({
		PieceType = "wall" :: BuildPieceType,
		Tier = "wood" :: BuildTier,
		RelX = -6,
		RelY = 0,
		RelZ = -12,
		RelRotY = 90,
	}),
	-- Inner bunker partition around TC cell (doorway + wall)
	table.freeze({
		PieceType = "doorway" :: BuildPieceType,
		Tier = "wood" :: BuildTier,
		RelX = 6,
		RelY = 0,
		RelZ = 0,
		RelRotY = 90,
	}),
	table.freeze({
		PieceType = "wall" :: BuildPieceType,
		Tier = "wood" :: BuildTier,
		RelX = 0,
		RelY = 0,
		RelZ = -6,
		RelRotY = 0,
	}),
	-- 4 Roof slabs
	table.freeze({
		PieceType = "roof" :: BuildPieceType,
		Tier = "wood" :: BuildTier,
		RelX = 0,
		RelY = 9.2,
		RelZ = 0,
		RelRotY = 0,
	}),
	table.freeze({
		PieceType = "roof" :: BuildPieceType,
		Tier = "wood" :: BuildTier,
		RelX = 12,
		RelY = 9.2,
		RelZ = 0,
		RelRotY = 0,
	}),
	table.freeze({
		PieceType = "roof" :: BuildPieceType,
		Tier = "wood" :: BuildTier,
		RelX = 0,
		RelY = 9.2,
		RelZ = -12,
		RelRotY = 0,
	}),
	table.freeze({
		PieceType = "roof" :: BuildPieceType,
		Tier = "wood" :: BuildTier,
		RelX = 12,
		RelY = 9.2,
		RelZ = -12,
		RelRotY = 0,
	}),
})

local TIER_SEQUENCE: { BuildTier } = { "wood", "stone", "metal", "armored" }

local BaseBlueprints = {}

local function accumulatePieceCost(costMap: { [string]: number }, pieceType: BuildPieceType, tier: BuildTier)
	local canonical = BuildingGeometry.CanonicalPieceType(pieceType)
	local pieceCfg = BuildingConfig.Pieces[canonical]
	if pieceCfg == nil then
		return
	end
	for resId, amt in pieceCfg.Cost do
		if amt > 0 then
			costMap[resId] = (costMap[resId] or 0) + amt
		end
	end
	if pieceCfg.Upgradeable then
		local targetTierCfg = BuildingConfig.Tiers[tier]
		local targetRank = if targetTierCfg ~= nil then targetTierCfg.Rank else 1
		for _, seqTier in TIER_SEQUENCE do
			local seqCfg = BuildingConfig.Tiers[seqTier]
			if seqCfg ~= nil and seqCfg.Rank > 1 and seqCfg.Rank <= targetRank and seqCfg.UpgradeCost ~= nil then
				for resId, amt in seqCfg.UpgradeCost do
					if amt > 0 then
						costMap[resId] = (costMap[resId] or 0) + amt
					end
				end
			end
		end
	end
end

local function computeBlueprintTotalCost(entries: { BlueprintPieceEntry }): { [string]: number }
	local costMap: { [string]: number } = {}
	for _, entry in entries do
		local canonical = BuildingGeometry.CanonicalPieceType(entry.PieceType)
		if canonical ~= "tool_cupboard" and entry.IsTc ~= true then
			accumulatePieceCost(costMap, canonical, entry.Tier)
		end
	end
	return costMap
end

local function computeBlocksCost(blocks: { SavedBuildPiece }): { [string]: number }
	local costMap: { [string]: number } = {}
	for _, block in blocks do
		local canonical = BuildingGeometry.CanonicalPieceType(block.PieceType)
		if canonical ~= "tool_cupboard" then
			accumulatePieceCost(costMap, canonical, block.Tier)
		end
	end
	return costMap
end

local function computeRefundFromPieces(pieces: { SavedBuildPiece }): { [string]: number }
	local rawTotals: { [string]: number } = {}
	for _, piece in pieces do
		local canonical = BuildingGeometry.CanonicalPieceType(piece.PieceType)
		local pieceCfg = BuildingConfig.Pieces[canonical]
		if canonical ~= "tool_cupboard" and pieceCfg ~= nil and pieceCfg.AssaultDeployable ~= true then
			accumulatePieceCost(rawTotals, canonical, piece.Tier)
		end
	end
	local refund: { [string]: number } = {}
	for resId, total in rawTotals do
		local refunded = math.floor(total * 0.8)
		if refunded > 0 then
			refund[resId] = refunded
		end
	end
	return refund
end

local function isAnyPieceRaidBlocked(
	pieces: { SavedBuildPiece },
	playerRecords: { [string]: BaseUpkeep.LivePieceEntry }
): boolean
	local now = os.clock()
	for _, piece in pieces do
		local record = playerRecords[piece.Uid]
		local attrDamaged = if record ~= nil then record.Model:GetAttribute("LastDamagedAt") else nil
		local lastDamaged = math.max(
			piece.LastDamagedAt or 0,
			if record ~= nil then record.LastDamagedAt else 0,
			if typeof(attrDamaged) == "number" then attrDamaged else 0
		)
		if lastDamaged > 0 and (now - lastDamaged) < BuildingConfig.UpgradeRaidBlockSeconds then
			return true
		end
	end
	return false
end

function BaseBlueprints.BuildSummaries(player: Player): { BaseBlueprintSummary }
	local data = DataService.GetData(player)
	local summaries: { BaseBlueprintSummary } = {
		{
			Id = BUILTIN_2X2_ID,
			Name = BUILTIN_2X2_NAME,
			PieceCount = #BUILTIN_2X2_PIECES,
			SavedAt = 0,
			IsBuiltin = true,
			HasData = true,
			Cost = computeBlueprintTotalCost(BUILTIN_2X2_PIECES),
		},
	}

	local savedMap = if data ~= nil then data.BaseBlueprints else {}
	for slotIdx = 1, MAX_SLOTS do
		local key = tostring(slotIdx)
		local slot = savedMap[key]
		local pieceCount = 0
		local slotCost: { [string]: number }? = nil
		local hasSlotData = false

		if slot ~= nil then
			if type(slot.EncodedBlocks) == "string" and #slot.EncodedBlocks > 0 then
				if type(slot.PieceCount) == "number" and slot.PieceCount > 0 and type(slot.Cost) == "table" then
					pieceCount = math.floor(slot.PieceCount)
					slotCost = slot.Cost
					hasSlotData = true
				else
					local ok, decoded = BaseSerializer.DeserializeBase(slot.EncodedBlocks, CFrame.identity)
					if ok and type(decoded) == "table" and #(decoded :: { SavedBuildPiece }) > 0 then
						local blocks = decoded :: { SavedBuildPiece }
						pieceCount = #blocks
						slotCost = computeBlocksCost(blocks)
						slot.PieceCount = pieceCount
						slot.Cost = slotCost
						hasSlotData = true
					end
				end
			elseif type(slot.Pieces) == "table" and #slot.Pieces > 0 then
				pieceCount = #slot.Pieces
				slotCost = computeBlueprintTotalCost(slot.Pieces)
				hasSlotData = true
			end
		end

		if slot ~= nil and hasSlotData then
			table.insert(summaries, {
				Id = string.format("slot_%d", slotIdx),
				Name = slot.Name,
				PieceCount = pieceCount,
				SavedAt = slot.SavedAt,
				IsBuiltin = false,
				HasData = true,
				Cost = slotCost or {},
			})
		else
			table.insert(summaries, {
				Id = string.format("slot_%d", slotIdx),
				Name = string.format("Слот #%d (пусто)", slotIdx),
				PieceCount = 0,
				SavedAt = 0,
				IsBuiltin = false,
				HasData = false,
				Cost = {},
			})
		end
	end

	return summaries
end

function BaseBlueprints.SaveBlueprint(player: Player, slotIndex: number): (boolean, string)
	if slotIndex < 1 or slotIndex > MAX_SLOTS or slotIndex % 1 ~= 0 then
		return false, "Некорректный слот планировки"
	end
	local data = DataService.GetData(player)
	if data == nil then
		return false, "Данные игрока не загружены"
	end
	local tcPiece = BaseUpkeep.FindToolCupboardPiece(data.Base.Pieces)
	if tcPiece == nil then
		return false, "Не найден шкаф (TC)"
	end

	local tcCF = BuildingGeometry.GetPieceWorldCFrame(tcPiece)
	local blocksToSave: { SavedBuildPiece } = {}

	for _, piece in data.Base.Pieces do
		local canonical = BuildingGeometry.CanonicalPieceType(piece.PieceType)
		local pieceCfg = BuildingConfig.Pieces[canonical]
		if canonical ~= "tool_cupboard" and pieceCfg ~= nil and pieceCfg.AssaultDeployable ~= true then
			table.insert(blocksToSave, piece)
		end
	end

	if #blocksToSave == 0 then
		return false, "На базе нет модулей для сохранения в планировку"
	end

	local encoded = BaseSerializer.SerializeBase(blocksToSave, tcCF)
	local cost = computeBlocksCost(blocksToSave)

	data.BaseBlueprints = data.BaseBlueprints or {}
	local slotKey = tostring(slotIndex)
	data.BaseBlueprints[slotKey] = {
		Id = string.format("slot_%d", slotIndex),
		Name = string.format("База #%d (%d мод.)", slotIndex, #blocksToSave),
		SavedAt = os.time(),
		EncodedBlocks = encoded,
		PieceCount = #blocksToSave,
		Cost = cost,
	}

	return true,
		string.format(
			"Планировка сохранена в слот #%d (%d модулей)",
			slotIndex,
			#blocksToSave
		)
end

local function entriesToWorldBlocks(entries: { BlueprintPieceEntry }, tcCF: CFrame, tcRotY: number): { SavedBuildPiece }
	local blocks: { SavedBuildPiece } = {}
	for _, entry in entries do
		local canonical = BuildingGeometry.CanonicalPieceType(entry.PieceType)
		if canonical == "tool_cupboard" or entry.IsTc == true then
			continue
		end
		local pieceCfg = BuildingConfig.Pieces[canonical]
		if pieceCfg ~= nil then
			local tier: BuildTier = if BuildingConfig.Tiers[entry.Tier] ~= nil then entry.Tier else "wood"
			local worldCF = tcCF
				* CFrame.new(entry.RelX, entry.RelY, entry.RelZ)
				* CFrame.Angles(0, math.rad(entry.RelRotY), 0)
			local worldRotY = BuildingGeometry.QuantizeYaw30(tcRotY + entry.RelRotY)
			local maxHp = BuildingGeometry.ComputeMaxHp(canonical, tier)
			table.insert(blocks, {
				Uid = HttpService:GenerateGUID(false),
				PieceType = canonical,
				Tier = tier,
				PosX = worldCF.Position.X,
				PosY = worldCF.Position.Y,
				PosZ = worldCF.Position.Z,
				RotY = worldRotY,
				MountSurface = entry.MountSurface,
				Hp = maxHp,
				LastDamagedAt = 0,
			})
		end
	end
	return blocks
end

local function resolveBlueprintWorldBlocks(
	data: Types.PlayerData,
	blueprintId: string,
	tcCF: CFrame,
	tcRotY: number
): ({ SavedBuildPiece }?, string?, string?)
	if blueprintId == BUILTIN_2X2_ID then
		return entriesToWorldBlocks(BUILTIN_2X2_PIECES, tcCF, tcRotY), BUILTIN_2X2_NAME, nil
	end
	local slotMatch = string.match(blueprintId, "^slot_(%d+)$")
	if slotMatch ~= nil then
		local slotIdx = tonumber(slotMatch)
		if slotIdx ~= nil and slotIdx >= 1 and slotIdx <= MAX_SLOTS then
			local slot = data.BaseBlueprints[tostring(slotIdx)]
			if slot == nil then
				return nil, nil, nil
			end
			if type(slot.EncodedBlocks) == "string" and #slot.EncodedBlocks > 0 then
				local ok, decoded = BaseSerializer.DeserializeBase(slot.EncodedBlocks, tcCF)
				if not ok then
					return nil, nil, tostring(decoded)
				end
				return decoded :: { SavedBuildPiece }, slot.Name, nil
			elseif type(slot.Pieces) == "table" and #slot.Pieces > 0 then
				local blocks = entriesToWorldBlocks(slot.Pieces, tcCF, tcRotY)
				slot.EncodedBlocks = BaseSerializer.SerializeBase(blocks, tcCF)
				slot.PieceCount = #blocks
				slot.Cost = computeBlocksCost(blocks)
				slot.Pieces = nil
				return blocks, slot.Name, nil
			end
		end
	end
	return nil, nil, nil
end

function BaseBlueprints.LoadBlueprint(player: Player, blueprintId: string, deps: BlueprintLoadDeps): (boolean, string)
	if player:GetAttribute("InRaid") == true then
		return false, "Загрузка планировки невозможна во время рейда"
	end
	local data = DataService.GetData(player)
	if data == nil then
		return false, "Данные игрока не загружены"
	end
	local tcPiece = BaseUpkeep.FindToolCupboardPiece(data.Base.Pieces)
	if tcPiece == nil then
		return false, "Не найден шкаф (TC)"
	end
	local playerRecords = deps.SpawnedByPlayer[player] or {}
	local tcRecord = playerRecords[tcPiece.Uid]
	if tcRecord == nil or tcRecord.Model.Parent == nil then
		return false, "Модель шкафа (TC) не активна"
	end
	if isAnyPieceRaidBlocked(data.Base.Pieces, playerRecords) then
		return false,
			"Нельзя загрузить планировку во время 30-сек рейд-блока"
	end

	local tcCF = BuildingGeometry.GetPieceWorldCFrame(tcPiece)
	local tcRotY = BuildingGeometry.QuantizeYaw30(tcPiece.RotY)

	local rawWorldBlocks, bpName, decodeErr = resolveBlueprintWorldBlocks(data, blueprintId, tcCF, tcRotY)
	if decodeErr ~= nil then
		return false, string.format("Ошибка декодирования планировки: %s", decodeErr)
	end
	if rawWorldBlocks == nil or #rawWorldBlocks == 0 or bpName == nil then
		return false, "Выбранный слот планировки пуст"
	end
	if (#rawWorldBlocks + 1) > BuildingConfig.MaxPiecesPerBase then
		return false, "Превышен максимальный лимит модулей базы"
	end

	-- Compute blueprint costs & 80% refund from existing non-TC blocks
	local bpCost = computeBlocksCost(rawWorldBlocks)
	local refundMap = computeRefundFromPieces(data.Base.Pieces)
	local tcTotals = BaseUpkeep.ComputeTcStorageTotals(tcPiece)

	for resId, required in bpCost do
		local available = (tcTotals[resId] or 0) + (refundMap[resId] or 0)
		if available < required then
			return false,
				string.format(
					"Недостаточно ресурсов в TC: требуется %s (%d, есть %d с учётом возврата 80%%)",
					resId,
					required,
					available
				)
		end
	end

	local existingModelsExclude: { Instance } = {}
	for _, rec in playerRecords do
		table.insert(existingModelsExclude, rec.Model)
	end

	local candidatePieces: { SavedBuildPiece } = { tcPiece }
	local candidateRecords: { [string]: BuildingValidator.LivePieceEntry } = {
		[tcPiece.Uid] = {
			Owner = player,
			Piece = tcPiece,
			Model = tcRecord.Model,
			CFrame = tcCF,
		},
	}
	local countsByType: { [string]: number } = { tool_cupboard = 1 }
	local seenWorldKeys: { [string]: boolean } = {
		[BuildingValidator.GetWorldSocketKeyForPiece("tool_cupboard", tcCF)] = true,
	}
	local wallCandidates: { BuildingGeometry.ParallelWallCandidate } = {}

	for _, entry in rawWorldBlocks do
		local canonical = BuildingGeometry.CanonicalPieceType(entry.PieceType)
		if canonical == "tool_cupboard" then
			continue
		end
		local pieceCfg = BuildingConfig.Pieces[canonical]
		if pieceCfg == nil then
			return false, string.format("Неизвестный тип модуля: %s", tostring(entry.PieceType))
		end

		countsByType[canonical] = (countsByType[canonical] or 0) + 1
		if pieceCfg.MaxPerBase ~= nil and countsByType[canonical] > pieceCfg.MaxPerBase then
			return false,
				string.format("Нарушен лимит %s (макс. %d)", pieceCfg.Name, pieceCfg.MaxPerBase)
		end

		local worldCF = BuildingGeometry.GetPieceWorldCFrame(entry)

		if BuildingValidator.IsInRaidOutpostZone(canonical, worldCF) then
			return false, "Планировка пересекает запрещённую зону (RaidOutpostZone)"
		end

		local worldKey = BuildingValidator.GetWorldSocketKeyForPiece(canonical, worldCF)
		if seenWorldKeys[worldKey] then
			return false,
				"В планировке обнаружены дублирующиеся модули в одной точке"
		end
		seenWorldKeys[worldKey] = true

		local parallelOk, parallelReason =
			BuildingGeometry.CheckParallelWallStacking(canonical, worldCF, wallCandidates)
		if not parallelOk then
			return false, parallelReason or "Обнаружено наложение параллельных стен"
		end

		local mountSurface: DefenseMountSurface? = entry.MountSurface
		if pieceCfg.IsDefense == true and mountSurface == nil then
			mountSurface = if pieceCfg.AllowedMount == "WallOrCeiling" then "Wall" else "Floor"
		end

		local overlap =
			BuildingValidator.CheckWorldOverlap(canonical, worldCF, existingModelsExclude, false, false, mountSurface)
		if not overlap.Allowed then
			return false,
				overlap.Reason or "Планировка пересекает препятствия на карте"
		end

		if pieceCfg.Category == "Foundation" and math.abs(worldCF.Position.Y - (tcCF.Position.Y - 1)) <= 0.5 then
			local groundHit = BuildingValidator.RaycastFoundationGround(worldCF.Position, player.Character)
			if groundHit == nil or math.abs(groundHit.Position.Y - worldCF.Position.Y) > 6.0 then
				return false,
					"Недостаточно ровной земли под фундаменты планировки"
			end
		end

		local tier: BuildTier = if BuildingConfig.Tiers[entry.Tier] ~= nil and pieceCfg.Upgradeable
			then entry.Tier
			else "wood"
		local maxHp = BuildingGeometry.ComputeMaxHp(canonical, tier)
		local newUid = HttpService:GenerateGUID(false)
		local newPiece: SavedBuildPiece = {
			Uid = newUid,
			PieceType = canonical,
			Tier = tier,
			PosX = worldCF.Position.X,
			PosY = worldCF.Position.Y,
			PosZ = worldCF.Position.Z,
			RotY = entry.RotY,
			ParentUid = nil,
			AnchorUid = nil,
			SocketId = nil,
			MountSurface = mountSurface,
			Hp = maxHp,
			LastDamagedAt = 0,
			Storage = if pieceCfg.StorageSlots ~= nil then {} else nil,
			HasCodeLock = entry.HasCodeLock,
			IsDoorOpen = entry.IsDoorOpen,
			LinkedHbhfSensor = entry.LinkedHbhfSensor,
			HasDoor = entry.HasDoor,
		}
		table.insert(candidatePieces, newPiece)
		table.insert(wallCandidates, {
			PieceType = canonical,
			CFrame = worldCF,
		})
		candidateRecords[newUid] = {
			Owner = player,
			Piece = newPiece,
			Model = tcRecord.Model,
			CFrame = worldCF,
		}
	end

	-- Validate projected BaseTier, RequiredBaseTier, DefenseCapacity, TC wall layers, and structural support
	local projectedTier = BaseUpkeep.ComputeBaseTier(candidatePieces, true)
	for _, piece in candidatePieces do
		local pieceCfg = BuildingConfig.Pieces[piece.PieceType]
		if pieceCfg ~= nil and pieceCfg.RequiredBaseTier ~= nil and projectedTier < pieceCfg.RequiredBaseTier then
			return false,
				string.format(
					"Для %s в планировке требуется База Tier %d",
					pieceCfg.Name,
					pieceCfg.RequiredBaseTier
				)
		end
	end

	local usedDef, maxDef = BuildingValidator.ComputeDefenseCapacity(candidatePieces, projectedTier)
	if usedDef > maxDef then
		return false, string.format("Превышен лимит защиты: %d / %d очков", usedDef, maxDef)
	end

	local tcPathOk, tcPathMsg = BuildingValidator.CheckMaxWallsToTC(candidateRecords, {}, nil, nil)
	if not tcPathOk then
		return false,
			tcPathMsg or "Планировка нарушает правило 2 слоёв защиты до TC"
	end

	local unsupported = BuildingValidator.FindUnsupportedPieces(candidatePieces, nil)
	if #unsupported > 0 then
		return false,
			"Часть модулей планировки не имеет опоры (отклонено BuildingValidator)"
	end

	-- Assign TC ParentUid to foundation directly underneath TC (if present)
	for _, piece in candidatePieces do
		local cfg = BuildingConfig.Pieces[piece.PieceType]
		if cfg ~= nil and (cfg.Category == "Foundation" or cfg.Category == "Floor") then
			local dx = piece.PosX - tcPiece.PosX
			local dz = piece.PosZ - tcPiece.PosZ
			local dy = tcPiece.PosY - piece.PosY
			if math.sqrt(dx * dx + dz * dz) <= 6.2 and dy >= 0.5 and dy <= 1.8 then
				tcPiece.ParentUid = piece.Uid
				tcPiece.AnchorUid = piece.Uid
				break
			end
		end
	end

	-- Pre-check net TC resource transaction (consume shortfalls first, then refund surpluses)
	local consumeMap: { [string]: number } = {}
	local depositMap: { [string]: number } = {}
	local allResIds: { [string]: boolean } = {}
	for resId in bpCost do
		allResIds[resId] = true
	end
	for resId in refundMap do
		allResIds[resId] = true
	end
	for resId in allResIds do
		local costAmt = bpCost[resId] or 0
		local refundAmt = refundMap[resId] or 0
		if costAmt > refundAmt then
			consumeMap[resId] = costAmt - refundAmt
		elseif refundAmt > costAmt then
			depositMap[resId] = refundAmt - costAmt
		end
	end

	if not BaseUpkeep.CanAffordInTcStorage(tcPiece, consumeMap) then
		return false, "Недостаточно ресурсов в TC для возведения планировки"
	end

	-- Commit resource changes in TC storage
	BaseUpkeep.ConsumeCostFromTcStorage(tcPiece, consumeMap)
	for resId, depAmt in depositMap do
		BaseUpkeep.DepositResourceToTcStorage(tcPiece, resId, depAmt)
	end

	-- Clear existing non-TC structures cleanly (keeping TC and its storage intact)
	local oldNonTcUids: { string } = {}
	for uid, rec in playerRecords do
		if uid ~= tcPiece.Uid then
			table.insert(oldNonTcUids, uid)
		end
		if uid == tcPiece.Uid then
			rec.Piece = tcPiece
		end
	end
	for _, oldUid in oldNonTcUids do
		local rec = playerRecords[oldUid]
		playerRecords[oldUid] = nil
		if rec ~= nil then
			deps.CleanupPieceRuntime(rec)
		end
	end

	-- Replace Base.Pieces with validated candidatePieces and spawn new modules
	data.Base.Pieces = candidatePieces
	for _, piece in candidatePieces do
		if piece.Uid ~= tcPiece.Uid then
			deps.SpawnPieceForPlayer(player, piece)
		end
	end
	BuildingValidator.RegisterOccupationsForRecord(
		(tcRecord :: any) :: BuildingValidator.LivePieceEntry,
		(playerRecords :: any) :: { [string]: BuildingValidator.LivePieceEntry },
		deps.OccupiedSockets,
		deps.OccupiedWorldKeys
	)

	deps.RecalculateAndSyncBaseTier(player)
	deps.SyncBaseState(player)
	deps.SyncToolCupboardForPlayer(player)

	return true,
		string.format(
			"Планировка «%s» возведена (%d модулей)",
			bpName,
			#candidatePieces - 1
		)
end

return BaseBlueprints
