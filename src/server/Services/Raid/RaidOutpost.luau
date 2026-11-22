--!strict
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)
local Types = require(ReplicatedStorage.Shared.Types)
local BuildingGeometry = require(ReplicatedStorage.Shared.BuildingGeometry)
local BuildingValidator = require(ServerScriptService.Server.Services.BuildingValidator)
local CraftingService = require(ServerScriptService.Server.Services.CraftingService)
local LootService = require(ServerScriptService.Server.Services.LootService)

type Inventory = Types.Inventory
type ItemBatchEntry = Types.ItemBatchEntry
type BuildPieceType = Types.BuildPieceType
type SavedBuildPiece = Types.SavedBuildPiece

export type OutpostDeps = {
	GetOrCreateFolder: (name: string) -> Folder,
	ActiveSessions: { [Player]: any },
	SyncSessionHud: (session: any, statusText: string?) -> (),
	TryExtractFromRaid: (player: Player) -> (),
	FailRaidSession: (player: Player, reason: string, delayForRespawn: boolean?) -> (),
}

local RAID_OUTPOST_STRUCTURES_FOLDER_NAME = "RaidOutpostStructures"

local nextBagId = 0
local nextOutpostSeq = 0

local RaidOutpost = {}

function RaidOutpost.CreatePrimitivePart(
	parent: Instance,
	name: string,
	size: Vector3,
	cf: CFrame,
	material: Enum.Material,
	color: Color3,
	canCollide: boolean?
): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = cf
	part.Anchored = true
	part.CanCollide = if canCollide == nil then true else canCollide
	part.Material = material
	part.Color = color
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

function RaidOutpost.SpawnDroppedLootBag(session: any, position: Vector3, slots: Inventory, folder: Folder)
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

function RaidOutpost.CountStashItems(session: any): number
	if session.ExtractionStashContainerId == nil then
		return 0
	end
	local state = LootService.GetContainerState(session.ExtractionStashContainerId)
	if state == nil then
		return 0
	end
	local total = 0
	for i = 1, Config.Raid.ExtractionStashSlots do
		local slot = state.Slots[i]
		if slot ~= nil and slot.Count > 0 then
			total += slot.Count
		end
	end
	return total
end

function RaidOutpost.CollectStashBatch(session: any): ({ ItemBatchEntry }, number)
	local batch: { ItemBatchEntry } = {}
	local totalItems = 0
	if session.ExtractionStashContainerId == nil then
		return batch, 0
	end
	local state = LootService.GetContainerState(session.ExtractionStashContainerId)
	if state == nil then
		return batch, 0
	end
	for i = 1, Config.Raid.ExtractionStashSlots do
		local slot = state.Slots[i]
		if slot ~= nil and slot.Count > 0 then
			table.insert(batch, { Id = slot.Id, Count = slot.Count })
			totalItems += slot.Count
		end
	end
	return batch, totalItems
end

function RaidOutpost.IsRaiderInExtractionZone(session: any, hrp: BasePart): boolean
	if session.ExtractionTerminalModel and session.ExtractionTerminalModel.PrimaryPart then
		if (hrp.Position - session.ExtractionTerminalModel.PrimaryPart.Position).Magnitude <= 18 then
			return true
		end
	end
	local delta = hrp.Position - session.OutpostOrigin
	return math.abs(delta.X) <= Config.Raid.OutpostRadius + 4 and math.abs(delta.Z) <= Config.Raid.OutpostRadius + 4
end

local function spawnOutpostStructuralPiece(
	session: any,
	folder: Folder,
	uid: string,
	pieceType: BuildPieceType,
	worldCF: CFrame,
	parentUid: string?,
	socketId: string?
)
	local piece: SavedBuildPiece = {
		Uid = uid,
		PieceType = pieceType,
		Tier = "wood",
		PosX = worldCF.Position.X,
		PosY = worldCF.Position.Y,
		PosZ = worldCF.Position.Z,
		RotY = BuildingGeometry.QuantizeYaw30(BuildingGeometry.ExtractYawDegrees(worldCF)),
		ParentUid = parentUid,
		AnchorUid = parentUid,
		SocketId = socketId,
		Hp = BuildingGeometry.ComputeMaxHp(pieceType, "wood"),
	}
	local model = BuildingGeometry.CreateModel(pieceType, worldCF, false, string.format("Outpost_%s", uid))
	BuildingGeometry.ApplyTierVisuals(model, pieceType, "wood")
	model:SetAttribute("BuildUid", uid)
	model:SetAttribute("PieceType", pieceType)
	model:SetAttribute("Tier", "wood")
	model:SetAttribute("OwnerUserId", session.Raider.UserId)
	model:SetAttribute("IsRaidOutpostPiece", true)
	model.Parent = folder

	local record = {
		Owner = session.Raider,
		Piece = piece,
		Model = model,
		CFrame = worldCF,
	}
	session.RaiderPieces[uid] = record
	BuildingValidator.RegisterOccupationsForRecord(
		(record :: any) :: BuildingValidator.LivePieceEntry,
		(session.RaiderPieces :: any) :: { [string]: BuildingValidator.LivePieceEntry },
		session.RaiderOccupiedSockets,
		session.RaiderOccupiedWorldKeys
	)
end

local function ensureArenaGround(session: any)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local hitOrigin = Workspace:Raycast(session.Origin + Vector3.new(0, 12, 0), Vector3.new(0, -30, 0), params)
	local hitOutpost = Workspace:Raycast(session.OutpostOrigin + Vector3.new(0, 12, 0), Vector3.new(0, -30, 0), params)
	if hitOrigin ~= nil and hitOutpost ~= nil then
		return
	end
	local ground = RaidOutpost.CreatePrimitivePart(
		Workspace,
		"Ground",
		Vector3.new(180, 2, 200),
		CFrame.new(session.Origin.X, session.Origin.Y - 1, session.Origin.Z + 18),
		Enum.Material.Grass,
		Color3.fromRGB(68, 94, 58),
		true
	)
	session.ArenaGroundPart = ground
end

function RaidOutpost.SpawnRaidOutpost(session: any, deps: OutpostDeps)
	ensureArenaGround(session)

	local outpostOrigin = session.OutpostOrigin
	local radius = Config.Raid.OutpostRadius

	if not session.IsSelfRaid then
		local existingZone = Workspace:FindFirstChild("RaidOutpostZone")
		if existingZone ~= nil and existingZone:GetAttribute("IsDynamicRaidZone") == true then
			existingZone:Destroy()
		end
	end
	local zoneModel = Instance.new("Model")
	zoneModel.Name = "RaidOutpostZone"
	zoneModel:SetAttribute("IsDynamicRaidZone", true)
	CollectionService:AddTag(zoneModel, "RaidOutpostZone")

	local zoneVolume = RaidOutpost.CreatePrimitivePart(
		zoneModel,
		"OutpostVolume",
		Vector3.new(radius * 2, 48, radius * 2),
		CFrame.new(outpostOrigin + Vector3.new(0, 22, 0)),
		Enum.Material.SmoothPlastic,
		Color3.fromRGB(55, 165, 225),
		false
	)
	zoneVolume.Transparency = 1
	zoneVolume.CanQuery = true
	zoneVolume.CanTouch = false

	local zonePad = RaidOutpost.CreatePrimitivePart(
		zoneModel,
		"OutpostPad",
		Vector3.new(radius * 2, 0.2, radius * 2),
		CFrame.new(outpostOrigin + Vector3.new(0, 0.1, 0)),
		Enum.Material.Neon,
		Color3.fromRGB(55, 165, 225),
		false
	)
	zonePad.Transparency = 0.84
	zonePad.CanQuery = false
	zonePad.CanTouch = false
	zoneModel.PrimaryPart = zoneVolume
	zoneModel.Parent = Workspace
	session.OutpostZoneModel = zoneModel

	local outpostFolder = deps.GetOrCreateFolder(RAID_OUTPOST_STRUCTURES_FOLDER_NAME)
	local baseCF = CFrame.new(outpostOrigin)
	spawnOutpostStructuralPiece(session, outpostFolder, "outpost_foundation", "foundation", baseCF, nil, nil)
	spawnOutpostStructuralPiece(
		session,
		outpostFolder,
		"outpost_wall_back",
		"wall",
		baseCF * CFrame.new(0, 1, 6),
		"outpost_foundation",
		"Edge_3"
	)
	spawnOutpostStructuralPiece(
		session,
		outpostFolder,
		"outpost_wall_left",
		"wall",
		baseCF * CFrame.new(-6, 1, 0) * CFrame.Angles(0, math.rad(90), 0),
		"outpost_foundation",
		"Edge_4"
	)
	spawnOutpostStructuralPiece(
		session,
		outpostFolder,
		"outpost_wall_right",
		"wall",
		baseCF * CFrame.new(6, 1, 0) * CFrame.Angles(0, math.rad(270), 0),
		"outpost_foundation",
		"Edge_2"
	)
	spawnOutpostStructuralPiece(
		session,
		outpostFolder,
		"outpost_doorway_front",
		"doorway",
		baseCF * CFrame.new(0, 1, -6) * CFrame.Angles(0, math.rad(180), 0),
		"outpost_foundation",
		"Edge_1"
	)
	spawnOutpostStructuralPiece(
		session,
		outpostFolder,
		"outpost_roof",
		"roof",
		baseCF * CFrame.new(0, 10.2, 0),
		"outpost_foundation",
		"Top"
	)

	nextOutpostSeq += 1
	local wbId = string.format("raid_outpost_wb_%d", nextOutpostSeq)
	local wbCF = baseCF * CFrame.new(-3.2, 1.0, -2.2) * CFrame.Angles(0, math.rad(90), 0)
	local wbModel = BuildingGeometry.CreateModel("workbench_1", wbCF, false, "OutpostWorkbench")
	BuildingGeometry.ApplyTierVisuals(wbModel, "workbench_1", "wood")
	wbModel:SetAttribute("BuildUid", "outpost_workbench")
	wbModel:SetAttribute("PieceType", "workbench_1")
	wbModel.Parent = outpostFolder
	session.RaiderPieces.outpost_workbench = {
		Owner = session.Raider,
		Piece = {
			Uid = "outpost_workbench",
			PieceType = "workbench_1",
			Tier = "wood",
			PosX = wbCF.Position.X,
			PosY = wbCF.Position.Y,
			PosZ = wbCF.Position.Z,
			RotY = 90,
			Hp = 200,
		},
		Model = wbModel,
		CFrame = wbCF,
	}
	CraftingService.RegisterStation(wbId, "workbench_1", wbCF.Position, session.Raider.UserId)
	session.OutpostWorkbenchId = wbId

	local padModel = Instance.new("Model")
	padModel.Name = "OutpostRespawnPad"
	local mat = RaidOutpost.CreatePrimitivePart(
		padModel,
		"Mat",
		Vector3.new(3.2, 0.35, 5.2),
		baseCF * CFrame.new(-3.2, 1.18, 2.4),
		Enum.Material.Fabric,
		Color3.fromRGB(58, 125, 76),
		true
	)
	RaidOutpost.CreatePrimitivePart(
		padModel,
		"Pillow",
		Vector3.new(2.4, 0.4, 1.1),
		baseCF * CFrame.new(-3.2, 1.45, 4.1),
		Enum.Material.Fabric,
		Color3.fromRGB(220, 220, 210),
		true
	)
	padModel.PrimaryPart = mat
	padModel.Parent = outpostFolder
	session.RaiderPieces.outpost_respawn_pad = {
		Owner = session.Raider,
		Piece = {
			Uid = "outpost_respawn_pad",
			PieceType = "storage_box",
			Tier = "wood",
			PosX = mat.Position.X,
			PosY = mat.Position.Y,
			PosZ = mat.Position.Z,
			RotY = 0,
			Hp = 150,
		},
		Model = padModel,
		CFrame = mat.CFrame,
	}
	session.RespawnPosition = outpostOrigin + Vector3.new(-3.2, 4.2, 2.4)

	local stashCF = baseCF * CFrame.new(3.2, 1.0, 3.1) * CFrame.Angles(0, math.rad(-90), 0)
	local stashModel = BuildingGeometry.CreateModel("storage_box", stashCF, false, "ExtractionStash")
	for _, desc in stashModel:GetDescendants() do
		if desc:IsA("BasePart") then
			desc.Material = Enum.Material.Metal
			desc.Color = if desc.Name == "ChestLid" then Color3.fromRGB(45, 145, 110) else Color3.fromRGB(52, 84, 78)
		end
	end
	stashModel.Parent = outpostFolder
	session.ExtractionStashModel = stashModel

	if stashModel.PrimaryPart then
		local stashGui = Instance.new("BillboardGui")
		stashGui.Size = UDim2.fromOffset(145, 28)
		stashGui.StudsOffset = Vector3.new(0, 2.6, 0)
		stashGui.AlwaysOnTop = true
		stashGui.MaxDistance = 40
		stashGui.Adornee = stashModel.PrimaryPart
		stashGui.Parent = stashModel.PrimaryPart
		local stashLbl = Instance.new("TextLabel")
		stashLbl.Size = UDim2.fromScale(1, 1)
		stashLbl.BackgroundColor3 = Color3.fromRGB(16, 42, 34)
		stashLbl.BackgroundTransparency = 0.2
		stashLbl.BorderSizePixel = 0
		stashLbl.Font = Enum.Font.GothamBold
		stashLbl.TextSize = 12
		stashLbl.TextColor3 = Color3.fromRGB(125, 245, 195)
		stashLbl.Text = "EXTRACTION STASH"
		stashLbl.Parent = stashGui

		local stashExtractPrompt = Instance.new("ProximityPrompt")
		stashExtractPrompt.Name = "StashExtractPrompt"
		stashExtractPrompt.ActionText =
			string.format("Start Stash Extraction (%ds)", Config.Raid.StashExtractionDuration)
		stashExtractPrompt.ObjectText = "Extraction Stash"
		stashExtractPrompt.HoldDuration = 0.4
		stashExtractPrompt.MaxActivationDistance = 10
		stashExtractPrompt.RequiresLineOfSight = false
		stashExtractPrompt.KeyboardKeyCode = Enum.KeyCode.F
		stashExtractPrompt.Parent = stashModel.PrimaryPart
		session.StashExtractPrompt = stashExtractPrompt
		session.Janitor:Add(stashExtractPrompt.Triggered:Connect(function(triggerPlayer: Player)
			if triggerPlayer == session.Raider then
				deps.TryExtractFromRaid(triggerPlayer)
			end
		end))
	end

	local stashId = LootService.RegisterStorageContainer(
		stashModel,
		"Extraction Stash",
		session.Raider.UserId,
		Config.Raid.ExtractionStashSlots,
		{},
		function()
			if deps.ActiveSessions[session.Raider] == session then
				deps.SyncSessionHud(session, nil)
			end
		end,
		true
	)
	if #stashId > 0 then
		session.ExtractionStashContainerId = stashId
	end

	local supplyCF = baseCF * CFrame.new(3.4, 1.0, -0.55) * CFrame.Angles(0, math.rad(-90), 0)
	local supplyModel = Instance.new("Model")
	supplyModel.Name = "RaidSupplyCrate"
	local supplyBody = RaidOutpost.CreatePrimitivePart(
		supplyModel,
		"ChestBody",
		Vector3.new(2.8, 1.8, 2.2),
		supplyCF * CFrame.new(0, 0.9, 0),
		Enum.Material.Metal,
		Color3.fromRGB(224, 228, 232),
		true
	)
	RaidOutpost.CreatePrimitivePart(
		supplyModel,
		"ChestLid",
		Vector3.new(3.0, 0.35, 2.4),
		supplyCF * CFrame.new(0, 1.95, 0),
		Enum.Material.Metal,
		Color3.fromRGB(188, 48, 48),
		true
	)
	RaidOutpost.CreatePrimitivePart(
		supplyModel,
		"MedCrossH",
		Vector3.new(0.9, 0.1, 0.3),
		supplyCF * CFrame.new(0, 2.16, 0),
		Enum.Material.SmoothPlastic,
		Color3.fromRGB(245, 245, 245),
		false
	)
	RaidOutpost.CreatePrimitivePart(
		supplyModel,
		"MedCrossV",
		Vector3.new(0.3, 0.1, 0.9),
		supplyCF * CFrame.new(0, 2.16, 0),
		Enum.Material.SmoothPlastic,
		Color3.fromRGB(245, 245, 245),
		false
	)
	supplyModel.PrimaryPart = supplyBody
	supplyModel.Parent = outpostFolder
	session.SupplyCrateModel = supplyModel

	local supplyGui = Instance.new("BillboardGui")
	supplyGui.Size = UDim2.fromOffset(160, 28)
	supplyGui.StudsOffset = Vector3.new(0, 2.5, 0)
	supplyGui.AlwaysOnTop = true
	supplyGui.MaxDistance = 40
	supplyGui.Adornee = supplyBody
	supplyGui.Parent = supplyBody
	local supplyLbl = Instance.new("TextLabel")
	supplyLbl.Size = UDim2.fromScale(1, 1)
	supplyLbl.BackgroundColor3 = Color3.fromRGB(56, 18, 22)
	supplyLbl.BackgroundTransparency = 0.2
	supplyLbl.BorderSizePixel = 0
	supplyLbl.Font = Enum.Font.GothamBold
	supplyLbl.TextSize = 12
	supplyLbl.TextColor3 = Color3.fromRGB(255, 195, 195)
	supplyLbl.Text = "RAID SUPPLIES (MEDS)"
	supplyLbl.Parent = supplyGui

	local supplyInitialSlots: Inventory = {}
	for slotIndex, itemEntry in Config.Raid.StarterSupplyItems do
		supplyInitialSlots[slotIndex] = {
			Id = itemEntry.Id,
			Count = itemEntry.Count,
		}
	end
	local supplyId = LootService.RegisterStorageContainer(
		supplyModel,
		"Raid Supply Crate",
		session.Raider.UserId,
		Config.Raid.SupplyCrateSlots,
		supplyInitialSlots,
		nil,
		false
	)
	if #supplyId > 0 then
		session.SupplyCrateContainerId = supplyId
	end

	local termModel = Instance.new("Model")
	termModel.Name = "ExtractionTerminal"
	local termBase = RaidOutpost.CreatePrimitivePart(
		termModel,
		"ConsoleBase",
		Vector3.new(2.2, 3.4, 1.6),
		baseCF * CFrame.new(3.5, 2.7, -3.0),
		Enum.Material.Metal,
		Color3.fromRGB(48, 54, 66),
		true
	)
	local screenPart = Instance.new("WedgePart")
	screenPart.Name = "ConsoleScreen"
	screenPart.Size = Vector3.new(2.0, 1.1, 1.2)
	screenPart.CFrame = baseCF * CFrame.new(3.5, 4.95, -2.9)
	screenPart.Anchored = true
	screenPart.CanCollide = true
	screenPart.Material = Enum.Material.SmoothPlastic
	screenPart.Color = Color3.fromRGB(28, 34, 42)
	screenPart.Parent = termModel

	local indicator = RaidOutpost.CreatePrimitivePart(
		termModel,
		"StatusLight",
		Vector3.new(1.8, 0.35, 0.35),
		baseCF * CFrame.new(3.5, 5.7, -3.0),
		Enum.Material.Neon,
		Color3.fromRGB(220, 140, 45),
		false
	)
	termModel.PrimaryPart = termBase
	termModel.Parent = outpostFolder
	session.ExtractionTerminalModel = termModel
	session.ExtractionTerminalIndicator = indicator

	local extractPrompt = Instance.new("ProximityPrompt")
	extractPrompt.Name = "ExtractPrompt"
	extractPrompt.ActionText = if session.TcCaptured then "Extract Loot (TC Captured)" else "Capture Enemy TC First"
	extractPrompt.ObjectText = "Extraction Terminal"
	extractPrompt.HoldDuration = 0.4
	extractPrompt.MaxActivationDistance = 10
	extractPrompt.RequiresLineOfSight = false
	extractPrompt.KeyboardKeyCode = Enum.KeyCode.E
	extractPrompt.Parent = termBase
	session.ExtractionTerminalPrompt = extractPrompt
	session.Janitor:Add(extractPrompt.Triggered:Connect(function(triggerPlayer: Player)
		if triggerPlayer == session.Raider then
			deps.TryExtractFromRaid(triggerPlayer)
		end
	end))

	local abandonPrompt = Instance.new("ProximityPrompt")
	abandonPrompt.Name = "AbandonPrompt"
	abandonPrompt.ActionText = "Abandon Raid (Lose Stash)"
	abandonPrompt.ObjectText = "Extraction Terminal"
	abandonPrompt.HoldDuration = 1.5
	abandonPrompt.MaxActivationDistance = 10
	abandonPrompt.RequiresLineOfSight = false
	abandonPrompt.KeyboardKeyCode = Enum.KeyCode.F
	abandonPrompt.Parent = termBase
	session.Janitor:Add(abandonPrompt.Triggered:Connect(function(triggerPlayer: Player)
		if triggerPlayer == session.Raider then
			deps.FailRaidSession(triggerPlayer, "Raid abandoned — stash lost", false)
		end
	end))
end

return RaidOutpost
