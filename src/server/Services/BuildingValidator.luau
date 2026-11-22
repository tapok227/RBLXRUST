--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Types = require(ReplicatedStorage.Shared.Types)
local BuildingConfig = require(ReplicatedStorage.Shared.configs.BuildingConfig)
local BuildingGeometry = require(ReplicatedStorage.Shared.BuildingGeometry)

type BuildPieceType = Types.BuildPieceType
type BuildSocketDef = Types.BuildSocketDef
type SavedBuildPiece = Types.SavedBuildPiece

export type LivePieceEntry = {
	Owner: Player,
	Piece: SavedBuildPiece,
	Model: Model,
	CFrame: CFrame,
}

export type PlacementValidationInput = {
	Player: Player,
	Character: Model?,
	HrpPosition: Vector3,
	PieceType: BuildPieceType,
	RequestedCFrame: CFrame,
	ParentUid: string?,
	SocketId: string?,
	ExplicitRotStep: number?,
	PlayerRecords: { [string]: LivePieceEntry },
	AllRecordsByUid: { [string]: LivePieceEntry },
	OccupiedSockets: { [string]: { [string]: string } },
	OccupiedWorldKeys: { [string]: string },
	BasePieces: { SavedBuildPiece },
}

export type PlacementValidationResult = {
	Allowed: boolean,
	Reason: string?,
	AuthoritativeCFrame: CFrame?,
	ResolvedParentUid: string?,
	ResolvedSocketId: string?,
	ResolvedSlotKey: string?,
	WorldSocketKey: string?,
	RotY: number?,
}

local SOCKET_MATCH_EPSILON = 0.55

local BuildingValidator = {}

function BuildingValidator.QuantizeSocketWorldKey(worldPos: Vector3, slotCategory: string): string
	local qx = math.floor(worldPos.X + 0.5)
	local qy = math.floor(worldPos.Y + 0.5)
	local qz = math.floor(worldPos.Z + 0.5)
	return string.format("%s:%d:%d:%d", slotCategory, qx, qy, qz)
end

function BuildingValidator.GetWorldSocketKeyForPiece(pieceType: BuildPieceType, worldCF: CFrame): string
	local cfg = BuildingConfig.Pieces[pieceType]
	local category = if cfg ~= nil then cfg.Category else "Unknown"
	local slotCategory = if category == "Stairs" or category == "Deployable" then "Interior" else category
	return BuildingValidator.QuantizeSocketWorldKey(worldCF.Position, slotCategory)
end

local function setSocketOccupied(
	occupiedSockets: { [string]: { [string]: string } },
	parentUid: string,
	slotKey: string,
	childUid: string
)
	local map = occupiedSockets[parentUid]
	if map == nil then
		map = {}
		occupiedSockets[parentUid] = map
	end
	map[slotKey] = childUid
end

function BuildingValidator.UnregisterSocketsForPiece(
	uid: string,
	occupiedSockets: { [string]: { [string]: string } },
	occupiedWorldKeys: { [string]: string }
)
	occupiedSockets[uid] = nil
	for _, socketMap in occupiedSockets do
		for socketId, childUid in socketMap do
			if childUid == uid then
				socketMap[socketId] = nil
			end
		end
	end
	for worldKey, childUid in occupiedWorldKeys do
		if childUid == uid then
			occupiedWorldKeys[worldKey] = nil
		end
	end
end

local function markCoincidentalSockets(
	occupiedSockets: { [string]: { [string]: string } },
	parentUid: string,
	parentType: BuildPieceType,
	parentCF: CFrame,
	childUid: string,
	childType: BuildPieceType,
	childPos: Vector3
)
	local childCfg = BuildingConfig.Pieces[childType]
	if childCfg == nil then
		return
	end
	for _, socket in BuildingGeometry.GetPieceSockets(parentType) do
		if socket.Kind == "WallTop" and childCfg.Category == "Floor" then
			for step = 0, 1 do
				if
					BuildingGeometry.DoesPieceOccupySocket(
						parentType,
						parentCF,
						socket,
						childType,
						childPos,
						SOCKET_MATCH_EPSILON,
						step
					)
				then
					setSocketOccupied(
						occupiedSockets,
						parentUid,
						BuildingGeometry.GetSocketSlotKey(socket, childType, step),
						childUid
					)
				end
			end
		elseif
			BuildingGeometry.DoesPieceOccupySocket(
				parentType,
				parentCF,
				socket,
				childType,
				childPos,
				SOCKET_MATCH_EPSILON
			)
		then
			setSocketOccupied(
				occupiedSockets,
				parentUid,
				BuildingGeometry.GetSocketSlotKey(socket, childType),
				childUid
			)
		end
	end
end

function BuildingValidator.RegisterOccupationsForRecord(
	record: LivePieceEntry,
	playerRecords: { [string]: LivePieceEntry },
	occupiedSockets: { [string]: { [string]: string } },
	occupiedWorldKeys: { [string]: string }
)
	local piece = record.Piece
	local pieceCfg = BuildingConfig.Pieces[piece.PieceType]
	if pieceCfg == nil then
		return
	end
	if occupiedSockets[piece.Uid] == nil then
		occupiedSockets[piece.Uid] = {}
	end

	local worldKey = BuildingValidator.GetWorldSocketKeyForPiece(piece.PieceType, record.CFrame)
	occupiedWorldKeys[worldKey] = piece.Uid

	local childPos = record.CFrame.Position
	local parentUid = piece.ParentUid or piece.AnchorUid
	if parentUid ~= nil and piece.SocketId ~= nil then
		local anchorRecord = playerRecords[parentUid]
		if anchorRecord ~= nil then
			local anchorSocket = BuildingGeometry.GetSocketById(anchorRecord.Piece.PieceType, piece.SocketId)
			if anchorSocket ~= nil then
				if anchorSocket.Kind == "WallTop" and pieceCfg.Category == "Floor" then
					for step = 0, 1 do
						local expected = BuildingGeometry.ComputeSnappedCFrame(
							anchorRecord.Piece.PieceType,
							anchorRecord.CFrame,
							anchorSocket,
							piece.PieceType,
							step
						)
						if (expected.Position - childPos).Magnitude <= 1.5 then
							setSocketOccupied(
								occupiedSockets,
								parentUid,
								BuildingGeometry.GetSocketSlotKey(anchorSocket, piece.PieceType, step),
								piece.Uid
							)
							break
						end
					end
				else
					setSocketOccupied(
						occupiedSockets,
						parentUid,
						BuildingGeometry.GetSocketSlotKey(anchorSocket, piece.PieceType),
						piece.Uid
					)
				end
			end
		end
	end

	for otherUid, otherRecord in playerRecords do
		if otherUid ~= piece.Uid then
			markCoincidentalSockets(
				occupiedSockets,
				otherUid,
				otherRecord.Piece.PieceType,
				otherRecord.CFrame,
				piece.Uid,
				piece.PieceType,
				childPos
			)
			markCoincidentalSockets(
				occupiedSockets,
				piece.Uid,
				piece.PieceType,
				record.CFrame,
				otherUid,
				otherRecord.Piece.PieceType,
				otherRecord.CFrame.Position
			)
		end
	end
end

function BuildingValidator.HasSupportingWallOnEdges(
	anchorEntry: LivePieceEntry,
	playerRecords: { [string]: LivePieceEntry },
	occupiedSockets: { [string]: { [string]: string } }
): boolean
	local sockets = BuildingGeometry.GetPieceSockets(anchorEntry.Piece.PieceType)
	local occMap = occupiedSockets[anchorEntry.Piece.Uid]
	local anchorCfg = BuildingConfig.Pieces[anchorEntry.Piece.PieceType]
	local wallYOffset = if anchorCfg ~= nil and anchorCfg.Category == "Foundation"
		then BuildingConfig.FoundationThickness
		else BuildingConfig.FloorThickness

	for _, socket in sockets do
		if socket.Kind == "Edge" then
			local wallSlotKey = socket.Id .. ":Wall"
			if occMap ~= nil and occMap[wallSlotKey] ~= nil then
				local occupant = playerRecords[occMap[wallSlotKey]]
				if occupant ~= nil then
					local occCfg = BuildingConfig.Pieces[occupant.Piece.PieceType]
					if occCfg ~= nil and occCfg.Category == "Wall" then
						return true
					end
				end
			end
			local edgeWallPos = (anchorEntry.CFrame * socket.LocalCFrame * CFrame.new(0, wallYOffset, 0)).Position
			for _, otherEntry in playerRecords do
				local otherCfg = BuildingConfig.Pieces[otherEntry.Piece.PieceType]
				if otherCfg ~= nil and otherCfg.Category == "Wall" then
					if (otherEntry.CFrame.Position - edgeWallPos).Magnitude <= SOCKET_MATCH_EPSILON then
						return true
					end
				end
			end
		end
	end
	return false
end

function BuildingValidator.RaycastFoundationGround(pos: Vector3, playerCharacter: Model?): RaycastResult?
	local excludeList: { Instance } = {}
	if playerCharacter ~= nil then
		table.insert(excludeList, playerCharacter)
	end
	for _, folderName in { "PlayerBaseStructures", "RaidTargetStructures", "ResourceNodes", "LootContainers" } do
		local folder = Workspace:FindFirstChild(folderName)
		if folder ~= nil then
			table.insert(excludeList, folder)
		end
	end

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.IgnoreWater = true
	params.FilterDescendantsInstances = excludeList

	local origin = Vector3.new(pos.X, pos.Y + 4.0, pos.Z)
	return Workspace:Raycast(origin, Vector3.new(0, -10.0, 0), params)
end

local function getBaseFloorGroundY(pieces: { SavedBuildPiece }, fallbackY: number): number
	local minFoundationY: number? = nil
	for _, piece in pieces do
		local cfg = BuildingConfig.Pieces[piece.PieceType]
		if cfg ~= nil and cfg.Category == "Foundation" then
			local pos = BuildingGeometry.GetPieceWorldCFrame(piece).Position
			if minFoundationY == nil or pos.Y < minFoundationY then
				minFoundationY = pos.Y
			end
		end
	end
	return minFoundationY or fallbackY
end

local function isSameHorizontalSpot(a: Vector3, b: Vector3, maxXZ: number, maxY: number): boolean
	local dx = a.X - b.X
	local dz = a.Z - b.Z
	local dy = math.abs(a.Y - b.Y)
	return (dx * dx + dz * dz) <= (maxXZ * maxXZ) and dy <= maxY
end

function BuildingValidator.HasDuplicateAtSameSpot(
	pieceType: BuildPieceType,
	targetCF: CFrame,
	playerRecords: { [string]: LivePieceEntry }
): boolean
	local cfg = BuildingConfig.Pieces[pieceType]
	if cfg == nil then
		return true
	end

	local targetPos = targetCF.Position
	for _, other in playerRecords do
		local otherCfg = BuildingConfig.Pieces[other.Piece.PieceType]
		if otherCfg ~= nil then
			local otherPos = other.CFrame.Position
			if
				(cfg.Category == "Foundation" or cfg.Category == "Floor")
				and (otherCfg.Category == "Foundation" or otherCfg.Category == "Floor")
			then
				if isSameHorizontalSpot(targetPos, otherPos, 4.0, 1.5) then
					return true
				end
			elseif cfg.Category == "Stairs" and otherCfg.Category == "Stairs" then
				if isSameHorizontalSpot(targetPos, otherPos, 3.0, 4.0) then
					return true
				end
			elseif
				(cfg.Category == "Deployable" or cfg.Category == "Stairs")
				and (otherCfg.Category == "Deployable" or otherCfg.Category == "Stairs")
			then
				if isSameHorizontalSpot(targetPos, otherPos, 2.0, 2.5) then
					return true
				end
			end
		end
	end
	return false
end

function BuildingValidator.CheckParallelWallStacking(
	targetType: BuildPieceType,
	targetCF: CFrame,
	allRecordsByUid: { [string]: LivePieceEntry }
): (boolean, string?)
	local list: { BuildingGeometry.ParallelWallCandidate } = {}
	for _, record in allRecordsByUid do
		if record.Model.Parent ~= nil then
			table.insert(list, {
				PieceType = record.Piece.PieceType,
				CFrame = record.CFrame,
			})
		end
	end
	return BuildingGeometry.CheckParallelWallStacking(targetType, targetCF, list)
end

function BuildingValidator.CheckWorldOverlap(
	pieceType: BuildPieceType,
	targetCF: CFrame,
	excludeInstances: { Instance }?,
	isDetachedFoundation: boolean
): BuildingGeometry.OverlapCheckResult
	return BuildingGeometry.CheckWorldOverlap(pieceType, targetCF, excludeInstances, isDetachedFoundation)
end

local function findAutoMatchedSocket(
	pieceType: BuildPieceType,
	requestedCF: CFrame,
	playerRecords: { [string]: LivePieceEntry },
	explicitRotStep: number?
): (LivePieceEntry?, BuildSocketDef?, number, CFrame?)
	local bestParent: LivePieceEntry? = nil
	local bestSocket: BuildSocketDef? = nil
	local bestStep = 0
	local bestCF: CFrame? = nil
	local bestDist = SOCKET_MATCH_EPSILON

	for _, parentEntry in playerRecords do
		if parentEntry.Model.Parent ~= nil then
			local parentType = parentEntry.Piece.PieceType
			for _, socket in BuildingGeometry.GetPieceSockets(parentType) do
				if BuildingGeometry.IsSocketCompatible(parentType, socket, pieceType) then
					local step = BuildingGeometry.InferRotStepFromCFrame(
						parentType,
						parentEntry.CFrame,
						socket,
						pieceType,
						requestedCF,
						explicitRotStep
					)
					local snappedCF =
						BuildingGeometry.ComputeSnappedCFrame(parentType, parentEntry.CFrame, socket, pieceType, step)
					local dist = (snappedCF.Position - requestedCF.Position).Magnitude
					if dist <= bestDist then
						bestDist = dist
						bestParent = parentEntry
						bestSocket = socket
						bestStep = step
						bestCF = snappedCF
					end
				end
			end
		end
	end

	return bestParent, bestSocket, bestStep, bestCF
end

function BuildingValidator.ValidatePlacement(input: PlacementValidationInput): PlacementValidationResult
	local pieceType = BuildingGeometry.CanonicalPieceType(input.PieceType)
	local pieceConfig = BuildingConfig.Pieces[pieceType]
	if pieceConfig == nil then
		return { Allowed = false, Reason = "Invalid piece type" }
	end

	local parentUid = input.ParentUid
	local socketId = input.SocketId
	local authoritativeCF: CFrame
	local resolvedSlotKey: string? = nil

	if parentUid == nil or socketId == nil then
		if pieceConfig.Category ~= "Foundation" then
			local matchedParent, matchedSocket, matchedStep, matchedCF =
				findAutoMatchedSocket(pieceType, input.RequestedCFrame, input.PlayerRecords, input.ExplicitRotStep)
			if matchedParent == nil or matchedSocket == nil or matchedCF == nil then
				return { Allowed = false, Reason = "Non-foundation piece requires valid supporting socket" }
			end
			parentUid = matchedParent.Piece.Uid
			socketId = matchedSocket.Id
			input.ExplicitRotStep = matchedStep
		end
	end

	if parentUid ~= nil and socketId ~= nil then
		local anchorRecord = input.AllRecordsByUid[parentUid]
		if anchorRecord == nil or anchorRecord.Owner ~= input.Player or anchorRecord.Model.Parent == nil then
			return { Allowed = false, Reason = "Invalid parent structure" }
		end

		local socket = BuildingGeometry.GetSocketById(anchorRecord.Piece.PieceType, socketId)
		if
			socket == nil or not BuildingGeometry.IsSocketCompatible(anchorRecord.Piece.PieceType, socket, pieceType)
		then
			return { Allowed = false, Reason = "Incompatible socket" }
		end

		local rotStep = BuildingGeometry.InferRotStepFromCFrame(
			anchorRecord.Piece.PieceType,
			anchorRecord.CFrame,
			socket,
			pieceType,
			input.RequestedCFrame,
			input.ExplicitRotStep
		)
		local slotKey = BuildingGeometry.GetSocketSlotKey(socket, pieceType, rotStep)
		local anchorOcc = input.OccupiedSockets[parentUid]
		if anchorOcc ~= nil and anchorOcc[slotKey] ~= nil then
			return { Allowed = false, Reason = "Socket already occupied" }
		end

		if socket.Kind == "Top" then
			if
				not BuildingValidator.HasSupportingWallOnEdges(anchorRecord, input.PlayerRecords, input.OccupiedSockets)
			then
				return { Allowed = false, Reason = "Floor requires supporting wall" }
			end
		end

		authoritativeCF = BuildingGeometry.ComputeSnappedCFrame(
			anchorRecord.Piece.PieceType,
			anchorRecord.CFrame,
			socket,
			pieceType,
			rotStep
		)
		resolvedSlotKey = slotKey

		local groundRefY = getBaseFloorGroundY(input.BasePieces, anchorRecord.CFrame.Position.Y)
		local maxAllowedY = groundRefY + BuildingConfig.MaxBuildHeight * BuildingConfig.WallHeight + 2.0
		if authoritativeCF.Position.Y > maxAllowedY then
			return { Allowed = false, Reason = "Max build height exceeded" }
		end
	else
		local yawDeg = BuildingGeometry.QuantizeYaw30(BuildingGeometry.ExtractYawDegrees(input.RequestedCFrame))
		local groundHit = BuildingValidator.RaycastFoundationGround(input.RequestedCFrame.Position, input.Character)
		if groundHit == nil or groundHit.Normal.Y < 0.65 then
			return { Allowed = false, Reason = "Requires flat ground" }
		end
		if BuildingGeometry.IsNoBuildInstance(groundHit.Instance) then
			return { Allowed = false, Reason = "Blocked by restricted zone" }
		end

		local snapY = groundHit.Position.Y
		if math.abs(input.RequestedCFrame.Position.Y - snapY) > 6.0 then
			return { Allowed = false, Reason = "Ground height mismatch" }
		end

		authoritativeCF = CFrame.new(input.RequestedCFrame.Position.X, snapY, input.RequestedCFrame.Position.Z)
			* CFrame.Angles(0, math.rad(yawDeg), 0)
	end

	local maxAllowedDistance = BuildingConfig.MaxBuildDistance + Types.PING_DISTANCE_TOLERANCE
	if (input.HrpPosition - authoritativeCF.Position).Magnitude > maxAllowedDistance then
		return { Allowed = false, Reason = "Target out of build range" }
	end

	local worldSocketKey = BuildingValidator.GetWorldSocketKeyForPiece(pieceType, authoritativeCF)
	if input.OccupiedWorldKeys[worldSocketKey] ~= nil then
		return { Allowed = false, Reason = "World socket position already occupied" }
	end

	if BuildingValidator.HasDuplicateAtSameSpot(pieceType, authoritativeCF, input.PlayerRecords) then
		return { Allowed = false, Reason = "Duplicate structure at same spot" }
	end

	local wallOk, wallReason =
		BuildingValidator.CheckParallelWallStacking(pieceType, authoritativeCF, input.AllRecordsByUid)
	if not wallOk then
		return { Allowed = false, Reason = wallReason or "Parallel wall stacking blocked" }
	end

	local overlap = BuildingValidator.CheckWorldOverlap(pieceType, authoritativeCF, nil, parentUid == nil)
	if not overlap.Allowed then
		return { Allowed = false, Reason = overlap.Reason or "Overlap blocked" }
	end

	local finalRotY = BuildingGeometry.QuantizeYaw30(BuildingGeometry.ExtractYawDegrees(authoritativeCF))
	return {
		Allowed = true,
		AuthoritativeCFrame = authoritativeCF,
		ResolvedParentUid = parentUid,
		ResolvedSocketId = socketId,
		ResolvedSlotKey = resolvedSlotKey,
		WorldSocketKey = worldSocketKey,
		RotY = finalRotY,
	}
end

function BuildingValidator.Init() end

return BuildingValidator
