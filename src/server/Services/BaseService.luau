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
local BuildingConfig = require(ReplicatedStorage.Shared.configs.BuildingConfig)
local Net = require(ReplicatedStorage.Shared.Net)
local DataService = require(ServerScriptService.Server.Services.DataService)
local InventoryService = require(ServerScriptService.Server.Services.InventoryService)
local LootService = require(ServerScriptService.Server.Services.LootService)
local CraftingService = require(ServerScriptService.Server.Services.CraftingService)

type Slot = Types.Slot
type Inventory = Types.Inventory
type ItemBatchEntry = Types.ItemBatchEntry
type BuildPieceType = Types.BuildPieceType
type BuildTier = Types.BuildTier
type SavedBuildPiece = Types.SavedBuildPiece

type SpawnedPieceRecord = {
	Piece: SavedBuildPiece,
	Model: Model,
	ContainerId: string?,
}

local STRUCTURES_FOLDER_NAME = "PlayerBaseStructures"
local STUDIO_SIM_BANNER_DURATION = 4

local TIER_VISUALS: { [BuildTier]: { Material: Enum.Material, Color: Color3 } } = {
	wood = {
		Material = Enum.Material.WoodPlanks,
		Color = Color3.fromRGB(165, 118, 72),
	},
	stone = {
		Material = Enum.Material.Cobblestone,
		Color = Color3.fromRGB(140, 140, 145),
	},
	metal = {
		Material = Enum.Material.DiamondPlate,
		Color = Color3.fromRGB(95, 108, 122),
	},
}

local spawnedByPlayer: { [Player]: { [string]: SpawnedPieceRecord } } = {}
local teleportInProgress: { [Player]: boolean } = {}
local pendingTeleports: { [Player]: boolean } = {}
local isInitialized = false

local BaseService = {}

local function isValidInteger(val: any): boolean
	return typeof(val) == "number" and val == val and val % 1 == 0 and math.abs(val) ~= math.huge
end

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

local function createPiecePart(parent: Instance, name: string, size: Vector3, cframe: CFrame): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = cframe
	part.Anchored = true
	part.CanCollide = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

local function applyTierVisuals(model: Model, pieceType: BuildPieceType, tier: BuildTier)
	if pieceType == "storage_box" then
		for _, child in model:GetDescendants() do
			if child:IsA("BasePart") then
				child.Material = Enum.Material.Wood
				if child.Name == "ChestLid" then
					child.Color = Color3.fromRGB(95, 62, 32)
				else
					child.Color = Color3.fromRGB(130, 88, 48)
				end
			end
		end
		return
	end

	if pieceType == "workbench_1" then
		for _, child in model:GetDescendants() do
			if child:IsA("BasePart") then
				if child.Name == "TableTop" then
					child.Material = Enum.Material.WoodPlanks
					child.Color = Color3.fromRGB(150, 105, 65)
				else
					child.Material = Enum.Material.Metal
					child.Color = Color3.fromRGB(70, 74, 80)
				end
			end
		end
		return
	end

	local visual = TIER_VISUALS[tier] or TIER_VISUALS.wood
	for _, child in model:GetDescendants() do
		if child:IsA("BasePart") then
			child.Material = visual.Material
			child.Color = visual.Color
		end
	end
end

local function createPieceModel(owner: Player, piece: SavedBuildPiece): Model
	local model = Instance.new("Model")
	model.Name = string.format("%s_%s", piece.PieceType, string.sub(piece.Uid, 1, 8))

	local gridSize = BuildingConfig.GridSize
	local wallHeight = BuildingConfig.WallHeight
	local baseCF = CFrame.new(piece.GridX * gridSize, piece.GridY * wallHeight, piece.GridZ * gridSize)
		* CFrame.Angles(0, math.rad(piece.RotY), 0)

	if piece.PieceType == "foundation" then
		local basePart = createPiecePart(model, "Base", Vector3.new(12, 1, 12), baseCF * CFrame.new(0, 0.5, 0))
		model.PrimaryPart = basePart
	elseif piece.PieceType == "wall" then
		local wallPart = createPiecePart(model, "Wall", Vector3.new(12, 10, 1), baseCF * CFrame.new(0, 5, -5.5))
		model.PrimaryPart = wallPart
	elseif piece.PieceType == "doorway" then
		createPiecePart(model, "LeftPillar", Vector3.new(4, 10, 1), baseCF * CFrame.new(-4, 5, -5.5))
		createPiecePart(model, "RightPillar", Vector3.new(4, 10, 1), baseCF * CFrame.new(4, 5, -5.5))
		local lintel = createPiecePart(model, "TopLintel", Vector3.new(4, 2.5, 1), baseCF * CFrame.new(0, 8.75, -5.5))
		model.PrimaryPart = lintel
	elseif piece.PieceType == "roof" then
		local roofPart = createPiecePart(model, "Roof", Vector3.new(12, 0.8, 12), baseCF * CFrame.new(0, 10.4, 0))
		model.PrimaryPart = roofPart
	elseif piece.PieceType == "storage_box" then
		local body = createPiecePart(model, "ChestBody", Vector3.new(4, 2.4, 2.5), baseCF * CFrame.new(0, 2.2, 0))
		createPiecePart(model, "ChestLid", Vector3.new(4.2, 0.4, 2.7), baseCF * CFrame.new(0, 3.6, 0))
		model.PrimaryPart = body
	elseif piece.PieceType == "workbench_1" then
		local top = createPiecePart(model, "TableTop", Vector3.new(5, 0.6, 3), baseCF * CFrame.new(0, 3.3, 0))
		createPiecePart(model, "LeftLeg", Vector3.new(0.6, 2.0, 2.6), baseCF * CFrame.new(-2.0, 2.0, 0))
		createPiecePart(model, "RightLeg", Vector3.new(0.6, 2.0, 2.6), baseCF * CFrame.new(2.0, 2.0, 0))
		model.PrimaryPart = top
		model:SetAttribute("StationType", "workbench_1")
	end

	applyTierVisuals(model, piece.PieceType, piece.Tier)

	local pieceConfig = BuildingConfig.Pieces[piece.PieceType]
	local tierConfig = BuildingConfig.Tiers[piece.Tier]
	local maxHp = math.floor(pieceConfig.BaseHp * tierConfig.HpMultiplier + 0.5)

	model:SetAttribute("BuildUid", piece.Uid)
	model:SetAttribute("PieceType", piece.PieceType)
	model:SetAttribute("Tier", piece.Tier)
	model:SetAttribute("OwnerUserId", owner.UserId)
	model:SetAttribute("GridX", piece.GridX)
	model:SetAttribute("GridY", piece.GridY)
	model:SetAttribute("GridZ", piece.GridZ)
	model:SetAttribute("RotY", piece.RotY)
	model:SetAttribute("Hp", piece.Hp)
	model:SetAttribute("MaxHp", maxHp)

	return model
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

local function inventoryToStorageMap(slots: Inventory, maxSlots: number): { [string]: Slot }
	local map: { [string]: Slot } = {}
	for i = 1, maxSlots do
		local slot = slots[i]
		if slot ~= nil and slot.Count > 0 then
			map[tostring(i)] = {
				Id = slot.Id,
				Count = slot.Count,
			}
		end
	end
	return map
end

local function cleanupPieceRuntime(record: SpawnedPieceRecord)
	if record.ContainerId ~= nil then
		LootService.UnregisterContainer(record.ContainerId)
	end
	if record.Piece.PieceType == "workbench_1" then
		CraftingService.UnregisterStation(record.Piece.Uid)
	end
	if record.Model.Parent then
		record.Model:Destroy()
	end
end

local function spawnPieceForPlayer(player: Player, piece: SavedBuildPiece)
	local playerRecords = spawnedByPlayer[player]
	if playerRecords == nil then
		playerRecords = {}
		spawnedByPlayer[player] = playerRecords
	end

	local existing = playerRecords[piece.Uid]
	if existing ~= nil then
		cleanupPieceRuntime(existing)
		playerRecords[piece.Uid] = nil
	end

	local folder = getOrCreateStructuresFolder()
	local model = createPieceModel(player, piece)
	model.Parent = folder

	local containerId: string? = nil
	local pieceConfig = BuildingConfig.Pieces[piece.PieceType]
	if piece.PieceType == "storage_box" then
		local storageSlots = (if pieceConfig then pieceConfig.StorageSlots else nil) or 18
		if piece.Storage == nil then
			piece.Storage = {}
		end
		local initialSlots = storageMapToInventory(piece.Storage, storageSlots)
		local registeredId = LootService.RegisterStorageContainer(
			model,
			"Storage Box",
			player.UserId,
			storageSlots,
			initialSlots,
			function(updatedSlots: Inventory)
				piece.Storage = inventoryToStorageMap(updatedSlots, storageSlots)
			end
		)
		if #registeredId > 0 then
			containerId = registeredId
		end
	elseif piece.PieceType == "workbench_1" and model.PrimaryPart then
		CraftingService.RegisterStation(piece.Uid, "workbench_1", model.PrimaryPart.Position)
	end

	playerRecords[piece.Uid] = {
		Piece = piece,
		Model = model,
		ContainerId = containerId,
	}
end

local function despawnBaseForPlayer(player: Player)
	local playerRecords = spawnedByPlayer[player]
	if playerRecords == nil then
		return
	end
	spawnedByPlayer[player] = nil

	for _, record in playerRecords do
		cleanupPieceRuntime(record)
	end
end

local function syncBaseState(player: Player)
	if player.Parent ~= Players then
		return
	end
	local data = DataService.GetData(player)
	if data == nil then
		return
	end
	Net.GetEvent(Net.Events.BaseStateSync):FireClient(player, data.Base.Pieces)
end

local function spawnBaseForPlayer(player: Player, data: Types.PlayerData)
	despawnBaseForPlayer(player)
	for _, piece in data.Base.Pieces do
		spawnPieceForPlayer(player, piece)
	end
	syncBaseState(player)
end

local function costMapToBatch(costMap: { [string]: number }): { ItemBatchEntry }
	local entries: { ItemBatchEntry } = {}
	for itemId, count in costMap do
		if count > 0 then
			table.insert(entries, {
				Id = itemId,
				Count = count,
			})
		end
	end
	return entries
end

local function hasPlacementCollision(
	pieces: { SavedBuildPiece },
	pieceType: BuildPieceType,
	gridX: number,
	gridY: number,
	gridZ: number,
	rotY: number
): boolean
	for _, existing in pieces do
		if existing.GridX == gridX and existing.GridY == gridY and existing.GridZ == gridZ then
			if existing.PieceType == pieceType then
				return true
			end
			if (pieceType == "wall" or pieceType == "doorway") and existing.RotY == rotY then
				if existing.PieceType == "wall" or existing.PieceType == "doorway" then
					return true
				end
			end
			if pieceType == "storage_box" or pieceType == "workbench_1" then
				if existing.PieceType == "storage_box" or existing.PieceType == "workbench_1" then
					return true
				end
			end
		end
	end
	return false
end

local function onBuildPlaceRequest(
	player: Player,
	pieceTypeAny: any,
	gridXAny: any,
	gridYAny: any,
	gridZAny: any,
	rotYAny: any
)
	if not BaseService.IsBaseMode() then
		return
	end

	if typeof(pieceTypeAny) ~= "string" then
		return
	end
	local pieceConfig = BuildingConfig.Pieces[pieceTypeAny :: BuildPieceType]
	if pieceConfig == nil then
		return
	end
	local pieceType = pieceTypeAny :: BuildPieceType

	if
		not isValidInteger(gridXAny)
		or not isValidInteger(gridYAny)
		or not isValidInteger(gridZAny)
		or not isValidInteger(rotYAny)
	then
		return
	end

	local gridX = gridXAny :: number
	local gridY = gridYAny :: number
	local gridZ = gridZAny :: number
	local rotY = rotYAny :: number

	if
		gridX < BuildingConfig.GridMinXZ
		or gridX > BuildingConfig.GridMaxXZ
		or gridY < BuildingConfig.GridMinY
		or gridY > BuildingConfig.GridMaxY
		or gridZ < BuildingConfig.GridMinXZ
		or gridZ > BuildingConfig.GridMaxXZ
		or BuildingConfig.ValidRotations[rotY] ~= true
	then
		return
	end

	local data = DataService.GetData(player)
	if data == nil then
		return
	end

	if #data.Base.Pieces >= BuildingConfig.MaxPiecesPerBase then
		return
	end

	if hasPlacementCollision(data.Base.Pieces, pieceType, gridX, gridY, gridZ, rotY) then
		return
	end

	local costBatch = costMapToBatch(pieceConfig.Cost)
	if not InventoryService.RemoveItems(player, costBatch) then
		return
	end

	local newPiece: SavedBuildPiece = {
		Uid = HttpService:GenerateGUID(false),
		PieceType = pieceType,
		Tier = "wood",
		GridX = gridX,
		GridY = gridY,
		GridZ = gridZ,
		RotY = rotY,
		Hp = pieceConfig.BaseHp,
		Storage = if pieceConfig.StorageSlots ~= nil then {} else nil,
	}

	table.insert(data.Base.Pieces, newPiece)
	spawnPieceForPlayer(player, newPiece)
	syncBaseState(player)
end

local function onBuildUpgradeRequest(player: Player, uidAny: any, targetTierAny: any)
	if not BaseService.IsBaseMode() then
		return
	end

	if typeof(uidAny) ~= "string" or #uidAny == 0 or #uidAny > 64 then
		return
	end
	if targetTierAny ~= "stone" and targetTierAny ~= "metal" then
		return
	end
	local targetTier = targetTierAny :: BuildTier

	local data = DataService.GetData(player)
	if data == nil then
		return
	end

	local targetPiece: SavedBuildPiece? = nil
	for _, piece in data.Base.Pieces do
		if piece.Uid == uidAny then
			targetPiece = piece
			break
		end
	end
	if targetPiece == nil then
		return
	end

	local pieceConfig = BuildingConfig.Pieces[targetPiece.PieceType]
	if pieceConfig == nil or not pieceConfig.Upgradeable then
		return
	end

	local expectedNextTier: BuildTier? = if targetPiece.Tier == "wood"
		then "stone"
		elseif targetPiece.Tier == "stone" then "metal"
		else nil
	if expectedNextTier ~= targetTier then
		return
	end

	local tierConfig = BuildingConfig.Tiers[targetTier]
	if tierConfig == nil or tierConfig.UpgradeCost == nil then
		return
	end

	local costBatch = costMapToBatch(tierConfig.UpgradeCost)
	if not InventoryService.RemoveItems(player, costBatch) then
		return
	end

	local maxHp = math.floor(pieceConfig.BaseHp * tierConfig.HpMultiplier + 0.5)
	targetPiece.Tier = targetTier
	targetPiece.Hp = maxHp

	local playerRecords = spawnedByPlayer[player]
	local record = if playerRecords then playerRecords[targetPiece.Uid] else nil
	if record ~= nil and record.Model.Parent then
		applyTierVisuals(record.Model, targetPiece.PieceType, targetTier)
		record.Model:SetAttribute("Tier", targetTier)
		record.Model:SetAttribute("Hp", maxHp)
		record.Model:SetAttribute("MaxHp", maxHp)
	end

	syncBaseState(player)
end

local function onBuildDemolishRequest(player: Player, uidAny: any)
	if not BaseService.IsBaseMode() then
		return
	end

	if typeof(uidAny) ~= "string" or #uidAny == 0 or #uidAny > 64 then
		return
	end

	local data = DataService.GetData(player)
	if data == nil then
		return
	end

	local targetIndex: number? = nil
	for index, piece in data.Base.Pieces do
		if piece.Uid == uidAny then
			targetIndex = index
			break
		end
	end
	if targetIndex == nil then
		return
	end

	local playerRecords = spawnedByPlayer[player]
	if playerRecords ~= nil then
		local record = playerRecords[uidAny]
		if record ~= nil then
			cleanupPieceRuntime(record)
			playerRecords[uidAny] = nil
		end
	end

	table.remove(data.Base.Pieces, targetIndex)
	syncBaseState(player)
end

local function sendReturnBanner(player: Player, active: boolean, statusText: string?)
	if player.Parent ~= Players then
		return
	end
	Net.GetEvent(Net.Events.ExtractionStateSync):FireClient(player, {
		Active = active,
		ZoneName = "Base Portal",
		TimeLeft = 0,
		TotalTime = 1,
		StatusText = statusText,
	})
end

local function onRequestReturnToMap(player: Player)
	if not BaseService.IsBaseMode() then
		return
	end
	if teleportInProgress[player] or DataService.GetData(player) == nil then
		return
	end

	teleportInProgress[player] = true

	if RunService:IsStudio() then
		local released = DataService.ReleaseForTeleport(player)
		print(
			string.format(
				"[BaseService] Studio mock teleport to MainMap (%d) for %s (ProfileReleased=%s)",
				Config.Places.MainMap,
				player.Name,
				tostring(released)
			)
		)
		sendReturnBanner(player, true, "Returning to PvP Map (Studio Simulation)")

		task.delay(STUDIO_SIM_BANNER_DURATION, function()
			if player.Parent == Players and pendingTeleports[player] == nil then
				sendReturnBanner(player, false, nil)
			end
		end)
		return
	end

	task.spawn(function()
		sendReturnBanner(player, true, "Saving base & deploying to PvP Map...")

		local released = DataService.ReleaseForTeleport(player)
		if not released then
			warn(string.format("[BaseService] Failed to release profile before teleport for %s", player.Name))
			DataService.RestoreAfterFailedTeleport(player)
			teleportInProgress[player] = nil
			sendReturnBanner(player, false, nil)
			return
		end

		if player.Parent ~= Players then
			teleportInProgress[player] = nil
			return
		end

		local options = Instance.new("TeleportOptions")
		options:SetTeleportData({
			FromPlaceId = game.PlaceId,
			OwnerUserId = player.UserId,
			Mode = "Raid",
		})

		pendingTeleports[player] = true
		local ok, err = pcall(function()
			TeleportService:TeleportAsync(Config.Places.MainMap, { player }, options)
		end)
		if not ok then
			warn(string.format("[BaseService] TeleportAsync error for %s: %s", player.Name, tostring(err)))
			pendingTeleports[player] = nil
			teleportInProgress[player] = nil
			DataService.RestoreAfterFailedTeleport(player)
			sendReturnBanner(player, false, nil)
		end
	end)
end

local function onTeleportInitFailed(
	player: Player,
	teleportResult: Enum.TeleportResult,
	errorMessage: string,
	_placeId: number,
	_teleportOptions: TeleportOptions
)
	if not pendingTeleports[player] then
		return
	end
	pendingTeleports[player] = nil
	teleportInProgress[player] = nil
	warn(
		string.format(
			"[BaseService] TeleportInitFailed for %s (%s): %s",
			player.Name,
			tostring(teleportResult),
			errorMessage
		)
	)
	DataService.RestoreAfterFailedTeleport(player)
	sendReturnBanner(player, false, nil)
end

local function onForceBaseModeChanged()
	if BaseService.IsBaseMode() then
		getOrCreateStructuresFolder()
		for _, player in Players:GetPlayers() do
			local data = DataService.GetData(player)
			if data ~= nil then
				spawnBaseForPlayer(player, data)
			end
		end
	else
		for _, player in Players:GetPlayers() do
			despawnBaseForPlayer(player)
		end
	end
end

function BaseService.IsBaseMode(): boolean
	return game.PlaceId == Config.Places.PlayerBase
		or (RunService:IsStudio() and Workspace:GetAttribute("ForceBaseMode") == true)
end

function BaseService.GetPlayerPieces(player: Player): { SavedBuildPiece }
	local data = DataService.GetData(player)
	if data == nil then
		return {}
	end
	return table.clone(data.Base.Pieces)
end

function BaseService.GetStorageContainerId(player: Player, uid: string): string?
	local playerRecords = spawnedByPlayer[player]
	if playerRecords == nil then
		return nil
	end
	local record = playerRecords[uid]
	if record == nil then
		return nil
	end
	return record.ContainerId
end

function BaseService.Init()
	if isInitialized then
		return
	end
	isInitialized = true

	Net.InitServer()

	if BaseService.IsBaseMode() then
		getOrCreateStructuresFolder()
	end

	Net.GetEvent(Net.Events.BuildPlaceRequest).OnServerEvent:Connect(onBuildPlaceRequest)
	Net.GetEvent(Net.Events.BuildUpgradeRequest).OnServerEvent:Connect(onBuildUpgradeRequest)
	Net.GetEvent(Net.Events.BuildDemolishRequest).OnServerEvent:Connect(onBuildDemolishRequest)
	Net.GetEvent(Net.Events.RequestReturnToMap).OnServerEvent:Connect(onRequestReturnToMap)
	TeleportService.TeleportInitFailed:Connect(onTeleportInitFailed)

	DataService.OnDataLoaded(function(player: Player, data: Types.PlayerData)
		if BaseService.IsBaseMode() then
			spawnBaseForPlayer(player, data)
		end
	end)

	if RunService:IsStudio() then
		Workspace:GetAttributeChangedSignal("ForceBaseMode"):Connect(onForceBaseModeChanged)
	end

	Players.PlayerRemoving:Connect(function(player: Player)
		despawnBaseForPlayer(player)
		teleportInProgress[player] = nil
		pendingTeleports[player] = nil
	end)
end

return BaseService
