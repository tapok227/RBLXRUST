--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local TeleportService = game:GetService("TeleportService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)
local Types = require(ReplicatedStorage.Shared.Types)
local BuildingConfig = require(ReplicatedStorage.Shared.configs.BuildingConfig)
local Explosives = require(ReplicatedStorage.Shared.configs.Explosives)
local Net = require(ReplicatedStorage.Shared.Net)
local DataService = require(ServerScriptService.Server.Services.DataService)
local InventoryService = require(ServerScriptService.Server.Services.InventoryService)
local LootService = require(ServerScriptService.Server.Services.LootService)
local SecurityService = require(ServerScriptService.Server.Services.SecurityService)

type Slot = Types.Slot
type Inventory = Types.Inventory
type BuildPieceType = Types.BuildPieceType
type BuildTier = Types.BuildTier
type SavedBuildPiece = Types.SavedBuildPiece
type BaseData = Types.BaseData
type RaidTargetInfo = Types.RaidTargetInfo
type RaidHudState = Types.RaidHudState
type ExplosionParams = Types.ExplosionParams
type ExplosionResult = Types.ExplosionResult

type RaidPieceRecord = {
	Piece: SavedBuildPiece,
	Model: Model,
	ContainerId: string?,
	MaxHp: number,
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
	Origin: Vector3,
	IsStudioMock: boolean,
	StartTime: number,
	Duration: number,
	Pieces: { [string]: RaidPieceRecord },
	DroppedContainerIds: { string },
	ActiveExplosives: { ActiveExplosiveRecord },
	Extracting: boolean,
	ReturnPosition: Vector3?,
}

type PendingTeleport = {
	TargetPlaceId: number,
	Options: TeleportOptions,
	IsReturningToMap: boolean,
	TargetName: string,
}

local RAID_STRUCTURES_FOLDER_NAME = "RaidTargetStructures"
local LOOT_CONTAINERS_FOLDER_NAME = "LootContainers"
local STUDIO_MOCK_RAID_ORIGIN = Vector3.new(300, 0, 300)
local RAID_DURATION = Types.RAID_DURATION
local LIST_COOLDOWN = 1.0
local EXPLOSIVE_PLACE_COOLDOWN = 0.5
local MAX_HIT_SURFACE_OFFSET = 4.0
local EXPLOSION_EFFECT_BROADCAST_RADIUS = 350
local MAX_OCCLUSION_RAY_PASSES = 8
local DEFAULT_MIN_FALLOFF_MULTIPLIER = 0.25

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

local activeSessions: { [Player]: RaidSession } = {}
local lastListRequest: { [Player]: number } = {}
local lastExplosivePlaceTime: { [Player]: number } = {}
local teleportInProgress: { [Player]: boolean } = {}
local pendingTeleports: { [Player]: PendingTeleport } = {}
local nextBagId = 0
local isInitialized = false

local RaidService = {}

local function isNearRaidTerminal(hrp: BasePart): boolean
	local terminal = Workspace:FindFirstChild("RaidTerminal")
	if terminal == nil then
		return true
	end
	local pos: Vector3
	if terminal:IsA("Model") then
		pos = if terminal.PrimaryPart then terminal.PrimaryPart.Position else terminal:GetPivot().Position
	elseif terminal:IsA("BasePart") then
		pos = terminal.Position
	else
		return true
	end
	return (hrp.Position - pos).Magnitude <= Types.MAX_RAID_TERMINAL_DISTANCE + Types.PING_DISTANCE_TOLERANCE
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

local function resolveTargetName(targetUserId: number): string
	if targetUserId == DataService.MOCK_RAID_TARGET_USER_ID then
		return "MockRaidTarget"
	end
	local online = Players:GetPlayerByUserId(targetUserId)
	if online ~= nil then
		return online.DisplayName
	end
	local ok, name = pcall(function()
		return Players:GetNameFromUserIdAsync(targetUserId)
	end)
	if ok and type(name) == "string" and #name > 0 then
		return name
	end
	return string.format("Player_%d", targetUserId)
end

local function buildMockRaidBase(): BaseData
	local pieces: { SavedBuildPiece } = {
		{
			Uid = "mock_foundation_1",
			PieceType = "foundation",
			Tier = "stone",
			GridX = 0,
			GridY = 0,
			GridZ = 0,
			RotY = 0,
			Hp = 300,
		},
		{
			Uid = "mock_foundation_2",
			PieceType = "foundation",
			Tier = "stone",
			GridX = 0,
			GridY = 0,
			GridZ = -1,
			RotY = 0,
			Hp = 300,
		},
		{
			Uid = "mock_wall_front",
			PieceType = "wall",
			Tier = "wood",
			GridX = 0,
			GridY = 0,
			GridZ = 0,
			RotY = 180,
			Hp = 150,
		},
		{
			Uid = "mock_wall_west_1",
			PieceType = "wall",
			Tier = "stone",
			GridX = 0,
			GridY = 0,
			GridZ = 0,
			RotY = 90,
			Hp = 300,
		},
		{
			Uid = "mock_wall_east_1",
			PieceType = "wall",
			Tier = "stone",
			GridX = 0,
			GridY = 0,
			GridZ = 0,
			RotY = 270,
			Hp = 300,
		},
		{
			Uid = "mock_wall_west_2",
			PieceType = "wall",
			Tier = "stone",
			GridX = 0,
			GridY = 0,
			GridZ = -1,
			RotY = 90,
			Hp = 300,
		},
		{
			Uid = "mock_wall_east_2",
			PieceType = "wall",
			Tier = "stone",
			GridX = 0,
			GridY = 0,
			GridZ = -1,
			RotY = 270,
			Hp = 300,
		},
		{
			Uid = "mock_wall_north",
			PieceType = "wall",
			Tier = "stone",
			GridX = 0,
			GridY = 0,
			GridZ = -1,
			RotY = 0,
			Hp = 300,
		},
		{
			Uid = "mock_doorway_inner",
			PieceType = "doorway",
			Tier = "stone",
			GridX = 0,
			GridY = 0,
			GridZ = 0,
			RotY = 0,
			Hp = 240,
		},
		{
			Uid = "mock_roof_1",
			PieceType = "roof",
			Tier = "stone",
			GridX = 0,
			GridY = 0,
			GridZ = 0,
			RotY = 0,
			Hp = 240,
		},
		{
			Uid = "mock_roof_2",
			PieceType = "roof",
			Tier = "stone",
			GridX = 0,
			GridY = 0,
			GridZ = -1,
			RotY = 0,
			Hp = 240,
		},
		{
			Uid = "mock_storage_1",
			PieceType = "storage_box",
			Tier = "wood",
			GridX = 0,
			GridY = 0,
			GridZ = -1,
			RotY = 0,
			Hp = 100,
			Storage = {
				["1"] = { Id = "scrap", Count = 120 },
				["2"] = { Id = "tech_parts", Count = 6 },
				["3"] = { Id = "metal_ore", Count = 80 },
				["4"] = { Id = "pistol_ammo", Count = 24 },
				["5"] = { Id = "cooked_meat", Count = 5 },
			},
		},
	}

	return {
		Pieces = pieces,
	}
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

local function createRaidPieceModel(piece: SavedBuildPiece, origin: Vector3): (Model, number)
	local model = Instance.new("Model")
	model.Name = string.format("Raid_%s_%s", piece.PieceType, string.sub(piece.Uid, 1, 12))

	local gridSize = BuildingConfig.GridSize
	local wallHeight = BuildingConfig.WallHeight
	local baseCF = CFrame.new(
		origin.X + piece.GridX * gridSize,
		origin.Y + piece.GridY * wallHeight,
		origin.Z + piece.GridZ * gridSize
	) * CFrame.Angles(0, math.rad(piece.RotY), 0)

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
	end

	applyTierVisuals(model, piece.PieceType, piece.Tier)

	local pieceConfig = BuildingConfig.Pieces[piece.PieceType]
	local tierConfig = BuildingConfig.Tiers[piece.Tier]
	local maxHp = math.floor(pieceConfig.BaseHp * tierConfig.HpMultiplier + 0.5)

	model:SetAttribute("RaidPieceUid", piece.Uid)
	model:SetAttribute("BuildUid", piece.Uid)
	model:SetAttribute("PieceType", piece.PieceType)
	model:SetAttribute("Tier", piece.Tier)
	model:SetAttribute("Hp", piece.Hp)
	model:SetAttribute("MaxHp", maxHp)
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

local function spawnDroppedLootBag(session: RaidSession, position: Vector3, slots: Inventory)
	local folder = getOrCreateFolder(LOOT_CONTAINERS_FOLDER_NAME)
	nextBagId += 1

	local model = Instance.new("Model")
	model.Name = string.format("RaidLootBag_%d", nextBagId)

	local bag = Instance.new("Part")
	bag.Name = "LootBag"
	bag.Size = Vector3.new(2.4, 1.4, 1.8)
	bag.Position = Vector3.new(position.X, session.Origin.Y + 0.8, position.Z)
	bag.Anchored = true
	bag.CanCollide = true
	bag.Material = Enum.Material.Fabric
	bag.Color = Color3.fromRGB(115, 78, 45)
	bag.TopSurface = Enum.SurfaceType.Smooth
	bag.BottomSurface = Enum.SurfaceType.Smooth
	bag.Parent = model

	model.PrimaryPart = bag
	model.Parent = folder

	local containerId = LootService.RegisterSlotsContainer(
		model,
		string.format("%s's Loot Bag", session.TargetName),
		session.TargetName,
		slots,
		Types.LOOT_CONTAINER_LIFETIME
	)
	if #containerId > 0 then
		table.insert(session.DroppedContainerIds, containerId)
	elseif model.Parent then
		model:Destroy()
	end
end

local function destroyRaidPiece(session: RaidSession, uid: string, dropStorageLoot: boolean)
	local record = session.Pieces[uid]
	if record == nil then
		return
	end
	session.Pieces[uid] = nil

	local dropPos = if record.Model.PrimaryPart then record.Model.PrimaryPart.Position else session.Origin

	if record.ContainerId ~= nil then
		local state = if dropStorageLoot then LootService.GetContainerState(record.ContainerId) else nil
		LootService.UnregisterContainer(record.ContainerId)
		if state ~= nil and hasAnySlots(state.Slots, Types.INVENTORY_SIZE) then
			spawnDroppedLootBag(session, dropPos, state.Slots)
		end
	end

	if record.Model.Parent then
		record.Model:Destroy()
	end
end

local function cleanupSession(session: RaidSession)
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

	for _, containerId in session.DroppedContainerIds do
		LootService.DestroyContainer(containerId)
	end
	table.clear(session.DroppedContainerIds)
end

local function spawnRaidTargetBase(session: RaidSession, baseData: BaseData)
	getOrCreateFolder(RAID_STRUCTURES_FOLDER_NAME)
	local folder = getOrCreateFolder(RAID_STRUCTURES_FOLDER_NAME)

	for _, savedPiece in baseData.Pieces do
		local pieceConfig = BuildingConfig.Pieces[savedPiece.PieceType]
		if pieceConfig == nil then
			continue
		end

		local pieceCopy: SavedBuildPiece = {
			Uid = savedPiece.Uid,
			PieceType = savedPiece.PieceType,
			Tier = savedPiece.Tier,
			GridX = savedPiece.GridX,
			GridY = savedPiece.GridY,
			GridZ = savedPiece.GridZ,
			RotY = savedPiece.RotY,
			Hp = savedPiece.Hp,
			Storage = savedPiece.Storage,
		}

		local model, maxHp = createRaidPieceModel(pieceCopy, session.Origin)
		model.Parent = folder

		local containerId: string? = nil
		if pieceCopy.PieceType == "storage_box" then
			local storageSlots = pieceConfig.StorageSlots or 18
			local initialSlots = storageMapToInventory(pieceCopy.Storage, storageSlots)
			local registeredId = LootService.RegisterStorageContainer(
				model,
				string.format("%s's Chest", session.TargetName),
				nil,
				storageSlots,
				initialSlots,
				nil,
				false
			)
			if #registeredId > 0 then
				containerId = registeredId
			end
		end

		session.Pieces[pieceCopy.Uid] = {
			Piece = pieceCopy,
			Model = model,
			ContainerId = containerId,
			MaxHp = maxHp,
		}
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

local function getDefaultSpawnPosition(): Vector3
	local spawnLoc = Workspace:FindFirstChildOfClass("SpawnLocation")
	if spawnLoc then
		return spawnLoc.Position + Vector3.new(0, 4, 0)
	end
	return Vector3.new(0, 6, 0)
end

local function finishRaidSession(player: Player, statusText: string?)
	local session = activeSessions[player]
	if session == nil or session.Extracting then
		return
	end
	session.Extracting = true
	SecurityService.SetTeleportLock(player, true)

	LootService.CloseContainerForPlayer(player, true)

	if session.IsStudioMock then
		local released = DataService.ReleaseForTeleport(player)
		print(
			string.format(
				"[RaidService] Studio raid extracted for %s (Target=%s, ProfileSaved=%s)",
				player.Name,
				session.TargetName,
				tostring(released)
			)
		)
		DataService.RestoreAfterFailedTeleport(player)

		activeSessions[player] = nil
		cleanupSession(session)
		player:SetAttribute("InRaid", false)

		local returnPos = session.ReturnPosition or getDefaultSpawnPosition()
		teleportCharacterToPosition(player, returnPos)

		sendRaidHud(player, {
			Active = false,
			TargetName = session.TargetName,
			TimeLeft = 0,
			StatusText = statusText,
		})
		return
	end

	if teleportInProgress[player] then
		session.Extracting = false
		SecurityService.SetTeleportLock(player, false)
		return
	end
	teleportInProgress[player] = true

	sendRaidHud(player, {
		Active = true,
		TargetName = session.TargetName,
		TimeLeft = 0,
		StatusText = statusText or "Saving loot & returning to PvP Map...",
	})

	local released = DataService.ReleaseForTeleport(player)
	if not released then
		warn(string.format("[RaidService] Failed to release profile after raid for %s", player.Name))
		DataService.RestoreAfterFailedTeleport(player)
		teleportInProgress[player] = nil
		session.Extracting = false
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
		RaiderUserId = player.UserId,
		Mode = "MainMap",
	})

	pendingTeleports[player] = {
		TargetPlaceId = Config.Places.MainMap,
		Options = options,
		IsReturningToMap = true,
		TargetName = session.TargetName,
	}

	local ok, err = pcall(function()
		TeleportService:TeleportAsync(Config.Places.MainMap, { player }, options)
	end)
	if not ok then
		warn(string.format("[RaidService] Return TeleportAsync error for %s: %s", player.Name, tostring(err)))
		pendingTeleports[player] = nil
		teleportInProgress[player] = nil
		session.Extracting = false
		DataService.RestoreAfterFailedTeleport(player)
	end
end

local function startSessionTimerLoop(session: RaidSession)
	task.spawn(function()
		while activeSessions[session.Raider] == session and session.Raider.Parent == Players do
			if session.Extracting then
				break
			end
			local elapsed = os.clock() - session.StartTime
			local timeLeft = math.max(0, math.ceil(session.Duration - elapsed))
			sendRaidHud(session.Raider, {
				Active = true,
				TargetName = session.TargetName,
				TimeLeft = timeLeft,
			})
			if elapsed >= session.Duration then
				finishRaidSession(session.Raider, "Raid timer expired - extracting with loot")
				break
			end
			task.wait(1)
		end
	end)
end

local function createExplosiveVisual(position: Vector3, itemId: string): (Part, TextLabel)
	local folder = getOrCreateFolder(RAID_STRUCTURES_FOLDER_NAME)

	local part = Instance.new("Part")
	part.Name = string.format("ArmedExplosive_%s", itemId)
	part.Size = if itemId == "c4_charge" then Vector3.new(1.1, 0.5, 0.8) else Vector3.new(1.0, 0.7, 1.0)
	part.Position = position
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.Material = Enum.Material.Metal
	part.Color = if itemId == "c4_charge" then Color3.fromRGB(205, 50, 50) else Color3.fromRGB(160, 110, 55)
	part.Parent = folder

	local gui = Instance.new("BillboardGui")
	gui.Name = "FuseTimerGui"
	gui.Size = UDim2.fromOffset(110, 32)
	gui.StudsOffset = Vector3.new(0, 1.8, 0)
	gui.AlwaysOnTop = true
	gui.MaxDistance = 60
	gui.Adornee = part
	gui.Parent = part

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundColor3 = Color3.fromRGB(28, 12, 12)
	label.BackgroundTransparency = 0.2
	label.BorderSizePixel = 0
	label.Font = Enum.Font.GothamBold
	label.TextSize = 14
	label.TextColor3 = Color3.fromRGB(255, 110, 90)
	label.Text = ""
	label.Parent = gui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 5)
	corner.Parent = label

	return part, label
end

local function findHumanoidCharacter(inst: Instance): (Model?, Humanoid?)
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

local function getTargetControlPoints(targetModel: Model, isCharacterTarget: boolean): { Vector3 }
	local points: { Vector3 } = {}
	if isCharacterTarget then
		local hrp = targetModel:FindFirstChild("HumanoidRootPart")
		local head = targetModel:FindFirstChild("Head")
		if hrp and hrp:IsA("BasePart") then
			table.insert(points, hrp.Position)
			if head and head:IsA("BasePart") then
				table.insert(points, head.Position)
			end
			table.insert(points, hrp.Position - Vector3.new(0, 2.0, 0))
			return points
		end
	else
		if targetModel:GetAttribute("PieceType") == "doorway" then
			for _, partName in { "LeftPillar", "RightPillar", "TopLintel" } do
				local part = targetModel:FindFirstChild(partName)
				if part and part:IsA("BasePart") then
					table.insert(points, part.Position)
				end
			end
			if #points > 0 then
				return points
			end
		end
	end

	local cf, size = targetModel:GetBoundingBox()
	if size.Y >= 3.0 then
		table.insert(points, cf.Position)
		table.insert(points, cf.Position + cf.UpVector * (size.Y * 0.35))
		table.insert(points, cf.Position - cf.UpVector * (size.Y * 0.35))
	elseif math.max(size.X, size.Z) >= 6.0 then
		table.insert(points, cf.Position)
		table.insert(points, cf.Position + cf.RightVector * (size.X * 0.3))
		table.insert(points, cf.Position - cf.RightVector * (size.X * 0.3))
	else
		table.insert(points, cf.Position)
		table.insert(points, cf.Position + Vector3.new(0, size.Y * 0.3, 0))
		table.insert(points, cf.Position - Vector3.new(0, size.Y * 0.3, 0))
	end

	return points
end

local function computeBlastFalloff(distance: number, radius: number, minMultiplier: number): number
	if distance <= 1.0 then
		return 1.0
	end
	local t = math.clamp((distance - 1.0) / math.max(0.01, radius - 1.0), 0, 1)
	local clampedMin = math.clamp(minMultiplier, 0, 1)
	return 1.0 - t * (1.0 - clampedMin)
end

local function broadcastExplosionEffect(
	origin: Vector3,
	radius: number,
	sourceId: string,
	projectileId: string?,
	attacker: Player?
)
	local effectEvent = Net.GetEvent(Net.Events.ExplosionEffect)
	for _, other in Players:GetPlayers() do
		if other == attacker then
			effectEvent:FireClient(other, origin, radius, sourceId, projectileId)
			continue
		end
		local char = other.Character
		local hrp = if char then char:FindFirstChild("HumanoidRootPart") else nil
		if hrp and hrp:IsA("BasePart") and (hrp.Position - origin).Magnitude <= EXPLOSION_EFFECT_BROADCAST_RADIUS then
			effectEvent:FireClient(other, origin, radius, sourceId, projectileId)
		end
	end
end

function RaidService.HasExplosionLineOfSight(
	blastOrigin: Vector3,
	targetModel: Model,
	excludeInstances: { Instance }?,
	isCharacterTarget: boolean?
): boolean
	local controlPoints = getTargetControlPoints(targetModel, isCharacterTarget == true)

	for _, targetPoint in controlPoints do
		local delta = targetPoint - blastOrigin
		if delta.Magnitude <= 0.1 then
			return true
		end

		local excludeList: { Instance } = { targetModel }
		if excludeInstances ~= nil then
			for _, inst in excludeInstances do
				table.insert(excludeList, inst)
			end
		end

		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.IgnoreWater = true
		params.FilterDescendantsInstances = excludeList

		local blocked = false
		for _ = 1, MAX_OCCLUSION_RAY_PASSES do
			local result = Workspace:Raycast(blastOrigin, delta, params)
			if result == nil then
				return true
			end

			if result.Instance:IsDescendantOf(targetModel) then
				return true
			end

			if result.Instance.CanCollide == false and not result.Instance:IsA("Terrain") then
				table.insert(excludeList, result.Instance)
				params.FilterDescendantsInstances = excludeList
				continue
			end

			local hitChar = findHumanoidCharacter(result.Instance)
			if hitChar ~= nil then
				table.insert(excludeList, hitChar)
				params.FilterDescendantsInstances = excludeList
				continue
			end

			blocked = true
			break
		end

		if not blocked then
			return true
		end
	end

	return false
end

function RaidService.TriggerExplosion(params: ExplosionParams): ExplosionResult
	local summary: ExplosionResult = {
		DamagedStructures = 0,
		DestroyedStructures = 0,
		DamagedHumanoids = 0,
		OccludedStructures = 0,
		OccludedHumanoids = 0,
	}

	if not SecurityService.IsValidVector3(params.Origin) then
		return summary
	end
	if not SecurityService.IsFiniteNumber(params.Radius) or params.Radius <= 0 then
		return summary
	end

	local origin = params.Origin
	local radius = params.Radius
	local minMult = params.MinFalloffMultiplier or DEFAULT_MIN_FALLOFF_MULTIPLIER

	local baseExcludes: { Instance } = {}
	if params.ExcludeInstances ~= nil then
		for _, inst in params.ExcludeInstances do
			table.insert(baseExcludes, inst)
		end
	end

	-- Phase 1: Collect targets & evaluate Line-of-Sight BEFORE modifying/destroying walls
	local pendingStructureHits: { { Session: RaidSession, Record: RaidPieceRecord, Damage: number } } = {}
	if params.StructureDamage > 0 then
		for _, session in activeSessions do
			for _, record in session.Pieces do
				if record.Model.Parent ~= nil then
					local closest = closestPointOnModel(record.Model, origin)
					local dist = (closest - origin).Magnitude
					if dist <= radius then
						if RaidService.HasExplosionLineOfSight(origin, record.Model, baseExcludes, false) then
							local falloff = computeBlastFalloff(dist, radius, minMult)
							local damage = math.floor(params.StructureDamage * falloff + 0.5)
							if damage > 0 then
								table.insert(pendingStructureHits, {
									Session = session,
									Record = record,
									Damage = damage,
								})
							end
						else
							summary.OccludedStructures += 1
						end
					end
				end
			end
		end
	end

	local pendingHumanoidHits: { { Model: Model, Humanoid: Humanoid, Damage: number } } = {}
	if params.PlayerDamage > 0 then
		local checkedModels: { [Model]: boolean } = {}
		local candidateModels: { Model } = {}

		for _, plr in Players:GetPlayers() do
			local char = plr.Character
			if char ~= nil then
				table.insert(candidateModels, char)
			end
		end

		local dummiesFolder = Workspace:FindFirstChild("TestDummies")
		if dummiesFolder ~= nil then
			for _, child in dummiesFolder:GetChildren() do
				if child:IsA("Model") then
					table.insert(candidateModels, child)
				end
			end
		end

		for _, charModel in candidateModels do
			if checkedModels[charModel] or charModel.Parent == nil then
				continue
			end
			checkedModels[charModel] = true

			local humanoid = charModel:FindFirstChildOfClass("Humanoid")
			local hrp = charModel:FindFirstChild("HumanoidRootPart")
			if
				humanoid == nil
				or not SecurityService.IsFiniteNumber(humanoid.Health)
				or humanoid.Health <= 0
				or hrp == nil
				or not hrp:IsA("BasePart")
			then
				continue
			end

			local hrpDist = (hrp.Position - origin).Magnitude
			local closestDist = (closestPointOnModel(charModel, origin) - origin).Magnitude
			local dist = math.min(hrpDist, closestDist)
			if dist <= radius then
				if RaidService.HasExplosionLineOfSight(origin, charModel, baseExcludes, true) then
					local falloff = computeBlastFalloff(dist, radius, minMult)
					local damage = params.PlayerDamage * falloff
					if damage > 0 then
						table.insert(pendingHumanoidHits, {
							Model = charModel,
							Humanoid = humanoid,
							Damage = damage,
						})
					end
				else
					summary.OccludedHumanoids += 1
				end
			end
		end
	end

	-- Phase 2: Apply structure and humanoid damage
	for _, hit in pendingStructureHits do
		local record = hit.Record
		if hit.Session.Pieces[record.Piece.Uid] == record and record.Model.Parent ~= nil then
			record.Piece.Hp -= hit.Damage
			summary.DamagedStructures += 1
			if record.Piece.Hp <= 0 then
				destroyRaidPiece(hit.Session, record.Piece.Uid, true)
				summary.DestroyedStructures += 1
			else
				record.Model:SetAttribute("Hp", record.Piece.Hp)
				updatePieceDamageBillboard(record)
			end
		end
	end

	for _, hit in pendingHumanoidHits do
		if hit.Model.Parent ~= nil and hit.Humanoid.Health > 0 then
			if params.Attacker ~= nil and params.Attacker.Parent == Players then
				hit.Model:SetAttribute("LastAttackerUserId", params.Attacker.UserId)
			end
			hit.Humanoid:TakeDamage(hit.Damage)
			summary.DamagedHumanoids += 1
		end
	end

	-- Phase 3: Replicate VFX & audio to clients
	broadcastExplosionEffect(origin, radius, params.SourceId or "explosion", params.ProjectileId, params.Attacker)

	return summary
end

local function detonateExplosive(
	session: RaidSession,
	explosiveRecord: ActiveExplosiveRecord,
	blastOrigin: Vector3,
	itemId: string
)
	if explosiveRecord.CancelFlag or activeSessions[session.Raider] ~= session then
		return
	end

	local cfg = Explosives[itemId]
	if cfg == nil then
		return
	end

	local excludePart: { Instance } = {}
	if explosiveRecord.Part.Parent then
		table.insert(excludePart, explosiveRecord.Part)
		explosiveRecord.Part:Destroy()
	end

	local idx = table.find(session.ActiveExplosives, explosiveRecord)
	if idx ~= nil then
		table.remove(session.ActiveExplosives, idx)
	end

	RaidService.TriggerExplosion({
		Origin = blastOrigin,
		Radius = cfg.Radius,
		StructureDamage = cfg.StructureDamage,
		PlayerDamage = cfg.PlayerDamage,
		Attacker = session.Raider,
		SourceId = itemId,
		ExcludeInstances = excludePart,
	})
end

local function onRaidListRequest(player: Player)
	if not SecurityService.CheckRateLimit(player, Net.Events.RaidListRequest) then
		return
	end
	if game.PlaceId ~= Config.Places.MainMap and not RunService:IsStudio() then
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

	local targets = DataService.GetRaidTargets(player.UserId, 10)
	if player.Parent == Players then
		Net.GetEvent(Net.Events.RaidListSync):FireClient(player, targets)
	end
end

local function onStartRaidRequest(player: Player, targetUserIdAny: any)
	if not SecurityService.CheckRateLimit(player, Net.Events.StartRaidRequest) then
		return
	end
	if game.PlaceId ~= Config.Places.MainMap and not RunService:IsStudio() then
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
	if targetUserId <= 0 and not (RunService:IsStudio() and targetUserId == DataService.MOCK_RAID_TARGET_USER_ID) then
		return
	end

	teleportInProgress[player] = true
	SecurityService.SetTeleportLock(player, true)
	LootService.CloseContainerForPlayer(player, true)
	local targetName = resolveTargetName(targetUserId)

	if RunService:IsStudio() then
		local released = DataService.ReleaseForTeleport(player)
		print(
			string.format(
				"[RaidService] Studio ReservedServer simulation: ReserveServer(PlaceId=%d) & TeleportToPrivateServer for TargetUserId=%d (ProfileReleased=%s)",
				Config.Places.PlayerBase,
				targetUserId,
				tostring(released)
			)
		)
		DataService.RestoreAfterFailedTeleport(player)
		teleportInProgress[player] = nil

		if player.Parent == Players and DataService.GetData(player) ~= nil then
			RaidService.EnterStudioMockRaid(player, targetUserId)
		end
		return
	end

	task.spawn(function()
		sendRaidHud(player, {
			Active = true,
			TargetName = targetName,
			TimeLeft = RAID_DURATION,
			StatusText = "Reserving raid server...",
		})

		local released = DataService.ReleaseForTeleport(player)
		if not released then
			warn(string.format("[RaidService] Failed to release profile before raid for %s", player.Name))
			DataService.RestoreAfterFailedTeleport(player)
			teleportInProgress[player] = nil
			sendRaidHud(player, {
				Active = false,
				TargetName = targetName,
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
			teleportInProgress[player] = nil
			sendRaidHud(player, {
				Active = false,
				TargetName = targetName,
				TimeLeft = 0,
				StatusText = "Raid failed: server reservation error",
			})
			return
		end

		local teleportData = {
			Mode = "Raid",
			TargetUserId = targetUserId,
			RaiderUserId = player.UserId,
			TargetName = targetName,
		}
		local options = Instance.new("TeleportOptions")
		options.ReservedServerAccessCode = accessCode
		options:SetTeleportData(teleportData)

		pendingTeleports[player] = {
			TargetPlaceId = Config.Places.PlayerBase,
			Options = options,
			IsReturningToMap = false,
			TargetName = targetName,
		}

		local okTp, errTp = pcall(function()
			TeleportService:TeleportAsync(Config.Places.PlayerBase, { player }, options)
		end)
		if not okTp then
			warn(string.format("[RaidService] TeleportAsync failed for %s: %s", player.Name, tostring(errTp)))
			pendingTeleports[player] = nil
			teleportInProgress[player] = nil
			DataService.RestoreAfterFailedTeleport(player)
			sendRaidHud(player, {
				Active = false,
				TargetName = targetName,
				TimeLeft = 0,
				StatusText = "Raid failed: teleport error",
			})
		end
	end)
end

local function onPlaceExplosiveRequest(player: Player, targetUidAny: any, hitPositionAny: any)
	if not SecurityService.CheckRateLimit(player, Net.Events.PlaceExplosiveRequest) then
		return
	end
	local session = activeSessions[player]
	if session == nil or session.Extracting then
		return
	end
	if DataService.IsTeleporting(player) or SecurityService.IsTransactionLocked(player) then
		return
	end
	if DataService.GetData(player) == nil then
		return
	end
	if not SecurityService.IsValidString(targetUidAny, 1, 64) then
		return
	end
	if not SecurityService.IsValidVector3(hitPositionAny) then
		return
	end

	local targetUid = targetUidAny :: string
	local targetRecord = session.Pieces[targetUid]
	if targetRecord == nil or not targetRecord.Model.Parent then
		return
	end

	local _, hrp, _ = getAliveCharacterParts(player)
	if hrp == nil then
		return
	end

	local hitPosition = hitPositionAny :: Vector3
	local clampedPos = closestPointOnModel(targetRecord.Model, hitPosition)
	if (hitPosition - clampedPos).Magnitude > MAX_HIT_SURFACE_OFFSET then
		return
	end
	if (hrp.Position - clampedPos).Magnitude > Types.MAX_EXPLOSIVE_PLACE_DISTANCE + Types.PING_DISTANCE_TOLERANCE then
		return
	end

	SecurityService.RunLocked(player, "PlaceExplosive", function()
		if
			activeSessions[player] ~= session
			or session.Extracting
			or DataService.GetData(player) == nil
			or session.Pieces[targetUid] ~= targetRecord
			or not targetRecord.Model.Parent
		then
			return
		end

		local _, innerHrp, _ = getAliveCharacterParts(player)
		if innerHrp == nil then
			return
		end
		if
			(innerHrp.Position - clampedPos).Magnitude
			> Types.MAX_EXPLOSIVE_PLACE_DISTANCE + Types.PING_DISTANCE_TOLERANCE
		then
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

		local explosiveCfg = Explosives[slotData.Id]
		if explosiveCfg == nil then
			return
		end

		local explosiveId = slotData.Id
		if not InventoryService.ConsumeSlot(player, equippedSlot, 1) then
			return
		end
		lastExplosivePlaceTime[player] = now

		local toPlayer = innerHrp.Position - clampedPos
		local nudge = if toPlayer.Magnitude > 0.05 then toPlayer.Unit * 0.3 else Vector3.new(0, 0.3, 0)
		local blastOrigin = clampedPos + nudge

		local visualPart, timerLabel = createExplosiveVisual(blastOrigin, explosiveId)
		local explosiveRecord: ActiveExplosiveRecord = {
			Part = visualPart,
			Label = timerLabel,
			CancelFlag = false,
		}
		table.insert(session.ActiveExplosives, explosiveRecord)

		task.spawn(function()
			local detonateAt = os.clock() + explosiveCfg.FuseTime
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

			if not explosiveRecord.CancelFlag and activeSessions[player] == session then
				detonateExplosive(session, explosiveRecord, blastOrigin, explosiveId)
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
	local session = activeSessions[player]
	if session == nil or session.Extracting then
		return
	end
	if teleportInProgress[player] or SecurityService.IsTeleportLocked(player) then
		return
	end
	if DataService.GetData(player) == nil then
		return
	end
	if SecurityService.GetAliveCharacterRoot(player) == nil then
		return
	end
	finishRaidSession(player, "Extracted with loot")
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
	warn(
		string.format(
			"[RaidService] TeleportInitFailed for %s (%s): %s",
			player.Name,
			tostring(teleportResult),
			errorMessage
		)
	)
	DataService.RestoreAfterFailedTeleport(player)

	local session = activeSessions[player]
	if pending.IsReturningToMap and session ~= nil then
		session.Extracting = false
	else
		sendRaidHud(player, {
			Active = false,
			TargetName = pending.TargetName,
			TimeLeft = 0,
			StatusText = string.format("Teleport failed: %s", errorMessage),
		})
	end
end

local function onPlayerDataLoaded(player: Player, _data: Types.PlayerData)
	if game.PlaceId ~= Config.Places.PlayerBase then
		return
	end

	local ok, joinData = pcall(function()
		return player:GetJoinData()
	end)
	if not ok or type(joinData) ~= "table" or type(joinData.TeleportData) ~= "table" then
		return
	end

	local teleportData = joinData.TeleportData
	if teleportData.Mode ~= "Raid" then
		return
	end

	local targetUserIdAny = teleportData.TargetUserId
	if not SecurityService.IsValidInteger(targetUserIdAny) then
		return
	end
	local targetUserId = math.floor(targetUserIdAny :: number)
	local targetName = if type(teleportData.TargetName) == "string" and #teleportData.TargetName > 0
		then teleportData.TargetName
		else resolveTargetName(targetUserId)

	Workspace:SetAttribute("RaidServerMode", true)

	local snapshot = DataService.LoadBaseSnapshot(targetUserId)
	local baseData: BaseData = if snapshot ~= nil then snapshot else { Pieces = {} }

	if activeSessions[player] ~= nil then
		cleanupSession(activeSessions[player])
		activeSessions[player] = nil
	end

	local session: RaidSession = {
		Raider = player,
		TargetUserId = targetUserId,
		TargetName = targetName,
		Origin = Vector3.zero,
		IsStudioMock = false,
		StartTime = os.clock(),
		Duration = RAID_DURATION,
		Pieces = {},
		DroppedContainerIds = {},
		ActiveExplosives = {},
		Extracting = false,
		ReturnPosition = nil,
	}

	activeSessions[player] = session
	player:SetAttribute("InRaid", true)
	spawnRaidTargetBase(session, baseData)
	teleportCharacterToPosition(player, Vector3.new(0, 4, 24))
	startSessionTimerLoop(session)
end

function RaidService.EnterStudioMockRaid(player: Player, targetUserId: number): boolean
	if not RunService:IsStudio() or player.Parent ~= Players then
		return false
	end
	if activeSessions[player] ~= nil then
		return false
	end

	local returnPos = getDefaultSpawnPosition()
	local _, hrp, _ = getAliveCharacterParts(player)
	if hrp ~= nil then
		returnPos = hrp.Position + Vector3.new(0, 1, 0)
	end

	local baseData: BaseData? = nil
	if targetUserId > 0 then
		baseData = DataService.LoadBaseSnapshot(targetUserId)
	end
	if baseData == nil or #baseData.Pieces == 0 then
		baseData = buildMockRaidBase()
	end

	local targetName = resolveTargetName(targetUserId)
	local session: RaidSession = {
		Raider = player,
		TargetUserId = targetUserId,
		TargetName = targetName,
		Origin = STUDIO_MOCK_RAID_ORIGIN,
		IsStudioMock = true,
		StartTime = os.clock(),
		Duration = RAID_DURATION,
		Pieces = {},
		DroppedContainerIds = {},
		ActiveExplosives = {},
		Extracting = false,
		ReturnPosition = returnPos,
	}

	activeSessions[player] = session
	player:SetAttribute("InRaid", true)
	spawnRaidTargetBase(session, baseData :: BaseData)
	teleportCharacterToPosition(player, STUDIO_MOCK_RAID_ORIGIN + Vector3.new(0, 4, 18))
	startSessionTimerLoop(session)
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
	local timeLeft = math.max(0, math.ceil(session.Duration - (os.clock() - session.StartTime)))
	return {
		Active = true,
		TargetName = session.TargetName,
		TimeLeft = timeLeft,
	}
end

function RaidService.Init()
	if isInitialized then
		return
	end
	isInitialized = true

	Net.InitServer()

	Net.GetEvent(Net.Events.RaidListRequest).OnServerEvent:Connect(onRaidListRequest)
	Net.GetEvent(Net.Events.StartRaidRequest).OnServerEvent:Connect(onStartRaidRequest)
	Net.GetEvent(Net.Events.PlaceExplosiveRequest).OnServerEvent:Connect(onPlaceExplosiveRequest)
	Net.GetEvent(Net.Events.RaidExtractRequest).OnServerEvent:Connect(onRaidExtractRequest)
	TeleportService.TeleportInitFailed:Connect(onTeleportInitFailed)

	DataService.OnDataLoaded(onPlayerDataLoaded)

	Players.PlayerRemoving:Connect(function(player: Player)
		local session = activeSessions[player]
		if session ~= nil then
			activeSessions[player] = nil
			cleanupSession(session)
		end
		lastListRequest[player] = nil
		lastExplosivePlaceTime[player] = nil
		teleportInProgress[player] = nil
		pendingTeleports[player] = nil
	end)
end

return RaidService
