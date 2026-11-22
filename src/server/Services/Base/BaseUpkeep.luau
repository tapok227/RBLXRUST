--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Config = require(ReplicatedStorage.Shared.Config)
local Types = require(ReplicatedStorage.Shared.Types)
local Items = require(ReplicatedStorage.Shared.configs.Items)
local BuildingConfig = require(ReplicatedStorage.Shared.configs.BuildingConfig)
local BuildingGeometry = require(ReplicatedStorage.Shared.BuildingGeometry)
local BuildingValidator = require(ServerScriptService.Server.Services.BuildingValidator)
local DataService = require(ServerScriptService.Server.Services.DataService)
local DefenseService = require(ServerScriptService.Server.Services.DefenseService)
local InventoryService = require(ServerScriptService.Server.Services.InventoryService)
local LootService = require(ServerScriptService.Server.Services.LootService)

type Slot = Types.Slot
type Inventory = Types.Inventory
type ItemBatchEntry = Types.ItemBatchEntry
type SavedBuildPiece = Types.SavedBuildPiece

export type LivePieceEntry = {
	Owner: Player,
	Piece: SavedBuildPiece,
	Model: Model,
	CFrame: CFrame,
	ContainerId: string?,
	LastDamagedAt: number,
}

export type UpkeepDeps = {
	SpawnedByPlayer: { [Player]: { [string]: LivePieceEntry } },
	OccupiedSockets: { [string]: { [string]: string } },
	StorageMapToInventory: (storage: { [string]: Slot }?, maxSlots: number) -> Inventory,
	CleanupPieceRuntime: (record: LivePieceEntry) -> (),
	DestroyUnsupportedCascade: (player: Player, data: Types.PlayerData) -> number,
	RecalculateAndSyncBaseTier: (player: Player) -> (),
	SyncBaseState: (player: Player) -> (),
	SyncToolCupboardForPlayer: (player: Player) -> (),
}

local upkeepFractions: { [Player]: { [string]: number } } = {}
local decayFractions: { [string]: number } = {}

local BaseUpkeep = {}

function BaseUpkeep.ClearPlayerState(player: Player)
	upkeepFractions[player] = nil
end

function BaseUpkeep.ClearDecayFraction(uid: string)
	decayFractions[uid] = nil
end

function BaseUpkeep.FindToolCupboardPiece(pieces: { SavedBuildPiece }): SavedBuildPiece?
	for _, piece in pieces do
		if BuildingGeometry.CanonicalPieceType(piece.PieceType) == "tool_cupboard" then
			return piece
		end
	end
	return nil
end

function BaseUpkeep.ComputeTcStorageTotals(tcPiece: SavedBuildPiece?): { [string]: number }
	local totals: { [string]: number } = {}
	if tcPiece == nil or type(tcPiece.Storage) ~= "table" then
		return totals
	end
	for _, slot in tcPiece.Storage do
		if type(slot) == "table" and type(slot.Id) == "string" and type(slot.Count) == "number" and slot.Count > 0 then
			totals[slot.Id] = (totals[slot.Id] or 0) + math.floor(slot.Count)
		end
	end
	return totals
end

function BaseUpkeep.ComputeProtectedHours(
	tcPiece: SavedBuildPiece?,
	hourlyUpkeep: { [string]: number }
): (number, { [string]: boolean })
	local missingByRes: { [string]: boolean } = {}
	if tcPiece == nil then
		return 0, missingByRes
	end
	local totals = BaseUpkeep.ComputeTcStorageTotals(tcPiece)
	local minHours: number? = nil
	for resId, hourlyRate in hourlyUpkeep do
		if hourlyRate > 0 then
			local stored = totals[resId] or 0
			if stored <= 0 then
				missingByRes[resId] = true
				minHours = 0
			else
				local hrs = stored / hourlyRate
				if minHours == nil or hrs < minHours then
					minHours = hrs
				end
			end
		end
	end
	if minHours == nil then
		return 24, missingByRes
	end
	return minHours, missingByRes
end

function BaseUpkeep.ComputeHourlyUpkeep(pieces: { SavedBuildPiece }): { [string]: number }
	local upkeep: { [string]: number } = {}
	local resourceByTier = Config.Upkeep.ResourceByBuildTier :: { [string]: string }
	local costByTier = Config.Upkeep.HourlyCostPerPiece :: { [string]: number }

	for _, piece in pieces do
		local canonical = BuildingGeometry.CanonicalPieceType(piece.PieceType)
		local pieceCfg = BuildingConfig.Pieces[canonical]
		if pieceCfg ~= nil and pieceCfg.Upgradeable then
			local resId = resourceByTier[piece.Tier]
			local rate = costByTier[piece.Tier]
			if resId ~= nil and rate ~= nil and rate > 0 then
				upkeep[resId] = (upkeep[resId] or 0) + rate
			end
		end
	end
	return upkeep
end

function BaseUpkeep.ComputeBaseTier(pieces: { SavedBuildPiece }, hasActiveTc: boolean): number
	if not hasActiveTc then
		return 0
	end

	local totalStructural = 0
	local tier2Qualified = 0
	local tier3Qualified = 0
	local t2MinRank = Config.BaseProgression.Tier2.MinTierRank
	local t3MinRank = Config.BaseProgression.Tier3.MinTierRank

	for _, piece in pieces do
		local canonical = BuildingGeometry.CanonicalPieceType(piece.PieceType)
		local pieceCfg = BuildingConfig.Pieces[canonical]
		if
			pieceCfg ~= nil
			and (
				pieceCfg.Category == "Foundation"
				or pieceCfg.Category == "Wall"
				or pieceCfg.Category == "Floor"
				or pieceCfg.Category == "Stairs"
			)
		then
			totalStructural += 1
			local tierCfg = BuildingConfig.Tiers[piece.Tier]
			local rank = if tierCfg ~= nil then tierCfg.Rank else 1
			if rank >= t2MinRank then
				tier2Qualified += 1
			end
			if rank >= t3MinRank then
				tier3Qualified += 1
			end
		end
	end

	local prog = Config.BaseProgression
	if totalStructural >= prog.Tier3.MinStructuralPieces and tier3Qualified >= prog.Tier3.MinQualifiedPieces then
		return 3
	elseif totalStructural >= prog.Tier2.MinStructuralPieces and tier2Qualified >= prog.Tier2.MinQualifiedPieces then
		return 2
	elseif totalStructural >= prog.Tier1.MinStructuralPieces then
		return 1
	end
	return 0
end

function BaseUpkeep.BuildToolCupboardState(player: Player, deps: UpkeepDeps): Types.ToolCupboardState?
	local data = DataService.GetData(player)
	if data == nil then
		return nil
	end
	local tcPiece = BaseUpkeep.FindToolCupboardPiece(data.Base.Pieces)
	if tcPiece == nil then
		return nil
	end

	local hourlyUpkeep = BaseUpkeep.ComputeHourlyUpkeep(data.Base.Pieces)
	local protectedHours = BaseUpkeep.ComputeProtectedHours(tcPiece, hourlyUpkeep)
	local status: Types.ToolCupboardStatus = if protectedHours > 0 then "Protected" else "Decaying"

	local playerRecords = deps.SpawnedByPlayer[player] or {}
	local pathValid, pathMessage, minLayers = BuildingValidator.CheckMaxWallsToTC(
		(playerRecords :: any) :: { [string]: BuildingValidator.LivePieceEntry },
		deps.OccupiedSockets,
		nil
	)
	if pathValid and minLayers ~= nil then
		pathMessage = string.format("Защита TC: %d/%d слоёв", minLayers, Config.MAX_TC_WALL_LAYERS)
	end

	local maxSlots = Config.Upkeep.TcStorageSlots
	local defUsed, defMax = BuildingValidator.ComputeDefenseCapacity(data.Base.Pieces, data.Base.BaseTier)
	return {
		Uid = tcPiece.Uid,
		ContainerId = tcPiece.Uid,
		BaseTier = data.Base.BaseTier,
		Status = status,
		HourlyUpkeep = hourlyUpkeep,
		ProtectedHours = protectedHours,
		PathValid = pathValid,
		PathMessage = pathMessage,
		DefenseUsed = defUsed,
		DefenseMax = defMax,
		Slots = deps.StorageMapToInventory(tcPiece.Storage, maxSlots),
		DefenseLogs = data.DefenseLogs,
	}
end

local function consumeFromTcStorage(tcPiece: SavedBuildPiece, itemId: string, amount: number): number
	if amount <= 0 or type(tcPiece.Storage) ~= "table" then
		return 0
	end
	local remaining = amount
	local maxSlots = Config.Upkeep.TcStorageSlots
	for i = maxSlots, 1, -1 do
		if remaining <= 0 then
			break
		end
		local key = tostring(i)
		local slot = tcPiece.Storage[key]
		if slot ~= nil and slot.Id == itemId and slot.Count > 0 then
			local take = math.min(remaining, slot.Count)
			slot.Count -= take
			remaining -= take
			if slot.Count <= 0 then
				tcPiece.Storage[key] = nil
			end
		end
	end
	return amount - remaining
end

local function isOuterBasePiece(
	piece: SavedBuildPiece,
	allPieces: { SavedBuildPiece },
	tcPos: Vector3,
	maxRadiusFromTc: number
): boolean
	local canonical = BuildingGeometry.CanonicalPieceType(piece.PieceType)
	if canonical == "tool_cupboard" then
		return false
	end
	local pos = Vector3.new(piece.PosX, piece.PosY, piece.PosZ)
	local dx = pos.X - tcPos.X
	local dz = pos.Z - tcPos.Z
	local distXZ = math.sqrt(dx * dx + dz * dz)
	if maxRadiusFromTc <= 13.0 then
		return true
	end
	if distXZ >= maxRadiusFromTc - 13.0 then
		return true
	end
	local cfg = BuildingConfig.Pieces[canonical]
	if cfg ~= nil and cfg.Category == "Wall" then
		local neighborCount = 0
		for _, other in allPieces do
			if other.Uid ~= piece.Uid then
				local ox = other.PosX - piece.PosX
				local oz = other.PosZ - piece.PosZ
				if (ox * ox + oz * oz) <= 64 then
					neighborCount += 1
				end
			end
		end
		if neighborCount <= 2 then
			return true
		end
	end
	return false
end

function BaseUpkeep.ProcessUpkeepAndDecay(player: Player, elapsedSeconds: number, deps: UpkeepDeps): boolean
	local data = DataService.GetData(player)
	if data == nil then
		return false
	end
	if #data.Base.Pieces == 0 then
		data.Base.LastUpkeepTimestamp = os.time()
		return false
	end

	local clampedElapsed = math.clamp(elapsedSeconds, 0, Config.Decay.OfflineMaxHours * 3600)
	if clampedElapsed <= 0 then
		return false
	end

	local hours = clampedElapsed / 3600
	local tcPiece = BaseUpkeep.FindToolCupboardPiece(data.Base.Pieces)
	local hourlyUpkeep = BaseUpkeep.ComputeHourlyUpkeep(data.Base.Pieces)

	local playerFracs = upkeepFractions[player]
	if playerFracs == nil then
		playerFracs = {}
		upkeepFractions[player] = playerFracs
	end

	local decayingResources: { [string]: boolean } = {}
	local storageChanged = false
	if tcPiece == nil then
		for resId, rate in hourlyUpkeep do
			if rate > 0 then
				decayingResources[resId] = true
			end
		end
	else
		tcPiece.Storage = tcPiece.Storage or {}
		local tcTotals = BaseUpkeep.ComputeTcStorageTotals(tcPiece)
		for resId, hourlyRate in hourlyUpkeep do
			if hourlyRate > 0 then
				local neededFloat = hourlyRate * hours + (playerFracs[resId] or 0)
				local wholeNeeded = math.floor(neededFloat)
				playerFracs[resId] = neededFloat - wholeNeeded
				if wholeNeeded > 0 then
					local consumed = consumeFromTcStorage(tcPiece, resId, wholeNeeded)
					if consumed > 0 then
						storageChanged = true
					end
					if consumed < wholeNeeded then
						decayingResources[resId] = true
						playerFracs[resId] = 0
					end
				elseif (tcTotals[resId] or 0) <= 0 then
					decayingResources[resId] = true
				end
			end
		end
	end

	local isAnyDecaying = (tcPiece == nil) or (next(decayingResources) ~= nil)
	local structureChanged = false

	if isAnyDecaying then
		local centerPos: Vector3
		if tcPiece ~= nil then
			centerPos = Vector3.new(tcPiece.PosX, tcPiece.PosY, tcPiece.PosZ)
		else
			local sumX, sumY, sumZ = 0, 0, 0
			for _, p in data.Base.Pieces do
				sumX += p.PosX
				sumY += p.PosY
				sumZ += p.PosZ
			end
			local count = math.max(1, #data.Base.Pieces)
			centerPos = Vector3.new(sumX / count, sumY / count, sumZ / count)
		end

		local resourceByTier = Config.Upkeep.ResourceByBuildTier :: { [string]: string }
		local damagePerHourByTier = Config.Decay.HourlyDamageByTier :: { [string]: number }
		local maxRadius = 0
		local candidatePieces: { SavedBuildPiece } = {}

		for _, piece in data.Base.Pieces do
			local canonical = BuildingGeometry.CanonicalPieceType(piece.PieceType)
			local pieceCfg = BuildingConfig.Pieces[canonical]
			local resId = resourceByTier[piece.Tier]
			local shouldDecay = (tcPiece == nil)
				or (pieceCfg ~= nil and pieceCfg.Upgradeable and resId ~= nil and decayingResources[resId] == true)
			if shouldDecay then
				table.insert(candidatePieces, piece)
				if canonical ~= "tool_cupboard" then
					local dx = piece.PosX - centerPos.X
					local dz = piece.PosZ - centerPos.Z
					local d = math.sqrt(dx * dx + dz * dz)
					if d > maxRadius then
						maxRadius = d
					end
				end
			end
		end

		local targetList: { SavedBuildPiece } = {}
		for _, piece in candidatePieces do
			if isOuterBasePiece(piece, data.Base.Pieces, centerPos, maxRadius) then
				table.insert(targetList, piece)
			end
		end
		if #targetList == 0 then
			targetList = candidatePieces
		end

		local noTcMult = if tcPiece == nil then Config.Decay.NoTcMultiplier else 1.0
		local destroyedUids: { [string]: boolean } = {}
		local playerRecords = deps.SpawnedByPlayer[player]

		for _, piece in targetList do
			local hourlyDamage = damagePerHourByTier[piece.Tier] or 50
			local rawDmg = hourlyDamage * hours * noTcMult + (decayFractions[piece.Uid] or 0)
			local wholeDmg = math.floor(rawDmg)
			decayFractions[piece.Uid] = rawDmg - wholeDmg
			if wholeDmg > 0 then
				piece.Hp -= wholeDmg
				structureChanged = true
				local record = if playerRecords ~= nil then playerRecords[piece.Uid] else nil
				if piece.Hp <= 0 then
					destroyedUids[piece.Uid] = true
					decayFractions[piece.Uid] = nil
					if playerRecords ~= nil and record ~= nil then
						playerRecords[piece.Uid] = nil
					end
					if record ~= nil then
						deps.CleanupPieceRuntime(record)
					end
				elseif record ~= nil and record.Model.Parent ~= nil then
					record.Model:SetAttribute("Health", piece.Hp)
					record.Model:SetAttribute("Hp", piece.Hp)
					DefenseService.UpdateDefenseHp(piece.Uid, piece.Hp, nil)
				end
			end
		end

		if next(destroyedUids) ~= nil then
			local kept: { SavedBuildPiece } = {}
			for _, piece in data.Base.Pieces do
				if not destroyedUids[piece.Uid] then
					table.insert(kept, piece)
				end
			end
			data.Base.Pieces = kept
			deps.DestroyUnsupportedCascade(player, data)
		end
	end

	data.Base.LastUpkeepTimestamp = os.time()
	deps.RecalculateAndSyncBaseTier(player)
	if structureChanged then
		deps.SyncBaseState(player)
	elseif storageChanged then
		deps.SyncToolCupboardForPlayer(player)
	end
	return isAnyDecaying or storageChanged
end

local function depositIntoSavedPieceStorage(
	piece: SavedBuildPiece,
	itemId: string,
	count: number,
	maxSlots: number
): number
	local itemCfg = Items[itemId]
	if itemCfg == nil or count <= 0 then
		return 0
	end
	if type(piece.Storage) ~= "table" then
		piece.Storage = {}
	end
	local storage = piece.Storage :: { [string]: Slot }
	local maxStack = itemCfg.MaxStack
	local remaining = count

	for i = 1, maxSlots do
		if remaining <= 0 then
			break
		end
		local key = tostring(i)
		local existing = storage[key]
		if existing ~= nil and existing.Id == itemId and existing.Count < maxStack then
			local addAmt = math.min(remaining, maxStack - existing.Count)
			if addAmt > 0 then
				existing.Count += addAmt
				remaining -= addAmt
			end
		end
	end

	for i = 1, maxSlots do
		if remaining <= 0 then
			break
		end
		local key = tostring(i)
		if storage[key] == nil then
			local addAmt = math.min(remaining, maxStack)
			storage[key] = { Id = itemId, Count = addAmt }
			remaining -= addAmt
		end
	end

	return count - remaining
end

function BaseUpkeep.DepositScrapToToolCupboard(player: Player, amount: number, deps: UpkeepDeps): number
	local data = DataService.GetData(player)
	if data == nil or amount <= 0 then
		return 0
	end
	local intAmount = math.floor(amount)
	if intAmount <= 0 then
		return 0
	end

	local depositedTotal = 0
	local tcPiece = BaseUpkeep.FindToolCupboardPiece(data.Base.Pieces)
	if tcPiece ~= nil then
		local inTc = depositIntoSavedPieceStorage(tcPiece, "scrap", intAmount, Config.Upkeep.TcStorageSlots)
		depositedTotal += inTc
		intAmount -= inTc
		if inTc > 0 then
			deps.SyncToolCupboardForPlayer(player)
			deps.SyncBaseState(player)
		end
	end

	if intAmount > 0 then
		local invAdded, storageAdded = BaseUpkeep.DepositItemsToPlayerBase(player, {
			{ Id = "scrap", Count = intAmount },
		}, deps)
		depositedTotal += invAdded + storageAdded
	end

	return depositedTotal
end

function BaseUpkeep.DepositItemsToPlayerBase(
	player: Player,
	items: { ItemBatchEntry },
	deps: UpkeepDeps
): (number, number)
	local data = DataService.GetData(player)
	if data == nil or #items == 0 then
		return 0, 0
	end

	local addedInvTotal = 0
	local addedStorageTotal = 0
	local playerRecords = deps.SpawnedByPlayer[player]

	for _, entry in items do
		if entry.Count <= 0 or Items[entry.Id] == nil then
			continue
		end
		local addedInv = InventoryService.AddItem(player, entry.Id, entry.Count)
		addedInvTotal += addedInv
		local remaining = entry.Count - addedInv
		if remaining <= 0 then
			continue
		end

		for _, piece in data.Base.Pieces do
			if remaining <= 0 then
				break
			end
			if BuildingGeometry.CanonicalPieceType(piece.PieceType) == "storage_box" then
				local liveRecord = if playerRecords ~= nil then playerRecords[piece.Uid] else nil
				if liveRecord ~= nil and liveRecord.ContainerId ~= nil then
					local deposited = LootService.DepositToStorageContainer(liveRecord.ContainerId, entry.Id, remaining)
					remaining -= deposited
					addedStorageTotal += deposited
				else
					local boxCfg = BuildingConfig.Pieces.storage_box
					local slotsLimit = if boxCfg and boxCfg.StorageSlots then boxCfg.StorageSlots else 18
					local deposited = depositIntoSavedPieceStorage(piece, entry.Id, remaining, slotsLimit)
					remaining -= deposited
					addedStorageTotal += deposited
				end
			end
		end
	end

	if addedStorageTotal > 0 then
		deps.SyncBaseState(player)
	end

	return addedInvTotal, addedStorageTotal
end

return BaseUpkeep
