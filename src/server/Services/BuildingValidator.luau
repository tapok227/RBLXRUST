--!strict
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)
local Types = require(ReplicatedStorage.Shared.Types)
local BuildingConfig = require(ReplicatedStorage.Shared.configs.BuildingConfig)
local Defenses = require(ReplicatedStorage.Shared.configs.Defenses)
local BuildingGeometry = require(ReplicatedStorage.Shared.BuildingGeometry)

type BuildPieceType = Types.BuildPieceType
type BuildSocketDef = Types.BuildSocketDef
type SavedBuildPiece = Types.SavedBuildPiece
type DefenseMountSurface = Types.DefenseMountSurface

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
	MountSurface: DefenseMountSurface?,
	PlayerRecords: { [string]: LivePieceEntry },
	AllRecordsByUid: { [string]: LivePieceEntry },
	OccupiedSockets: { [string]: { [string]: string } },
	OccupiedWorldKeys: { [string]: string },
	BasePieces: { SavedBuildPiece },
	PlayerBaseTier: number?,
	IsRaidMode: boolean?,
}

export type CandidatePieceInput = {
	PieceType: BuildPieceType,
	CFrame: CFrame,
	ParentUid: string?,
	SocketId: string?,
}

export type PlacementValidationResult = {
	Allowed: boolean,
	Reason: string?,
	AuthoritativeCFrame: CFrame?,
	ResolvedParentUid: string?,
	ResolvedSocketId: string?,
	ResolvedSlotKey: string?,
	ResolvedMountSurface: DefenseMountSurface?,
	WorldSocketKey: string?,
	RotY: number?,
}

local SOCKET_MATCH_EPSILON = 0.55
local DEFENSE_MIN_SPACING = 2.0

local BuildingValidator = {}

function BuildingValidator.ComputeDefenseCapacity(pieces: { SavedBuildPiece }, baseTier: number): (number, number)
	local used = 0
	for _, piece in pieces do
		local canonical = BuildingGeometry.CanonicalPieceType(piece.PieceType)
		local defCfg = Defenses.Get(canonical)
		if defCfg ~= nil then
			used += defCfg.CapacityCost
		end
	end
	local maxCapacity = Defenses.GetCapacityLimit(baseTier)
	return used, maxCapacity
end

function BuildingValidator.QuantizeSocketWorldKey(worldPos: Vector3, slotCategory: string): string
	local qx = math.floor(worldPos.X + 0.5)
	local qy = math.floor(worldPos.Y + 0.5)
	local qz = math.floor(worldPos.Z + 0.5)
	return string.format("%s:%d:%d:%d", slotCategory, qx, qy, qz)
end

function BuildingValidator.GetWorldSocketKeyForPiece(pieceType: BuildPieceType, worldCF: CFrame): string
	local cfg = BuildingConfig.Pieces[pieceType]
	local category = if cfg ~= nil then cfg.Category else "Unknown"
	local slotCategory = if cfg ~= nil and cfg.IsDefense == true
		then "Defense"
		elseif category == "Stairs" or category == "Deployable" then "Interior"
		else category
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
	for _, folderName in
		{
			"PlayerBaseStructures",
			"RaidTargetStructures",
			"RaidOutpostStructures",
			"RaidOutpostZone",
			"ResourceNodes",
			"LootContainers",
		}
	do
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
	isDetachedFoundation: boolean,
	allowRaidOutpostZone: boolean?,
	mountSurface: DefenseMountSurface?
): BuildingGeometry.OverlapCheckResult
	return BuildingGeometry.CheckWorldOverlap(
		pieceType,
		targetCF,
		excludeInstances,
		isDetachedFoundation,
		allowRaidOutpostZone,
		mountSurface
	)
end

local function collectRaidOutpostParts(): { BasePart }
	local parts: { BasePart } = {}
	local seen: { [BasePart]: boolean } = {}

	local function addFromInstance(inst: Instance?)
		if inst == nil then
			return
		end
		if inst:IsA("BasePart") then
			if not seen[inst] then
				seen[inst] = true
				table.insert(parts, inst)
			end
		else
			for _, desc in inst:GetDescendants() do
				if desc:IsA("BasePart") and not seen[desc] then
					seen[desc] = true
					table.insert(parts, desc)
				end
			end
		end
	end

	addFromInstance(Workspace:FindFirstChild("RaidOutpostZone"))
	for _, tagged in CollectionService:GetTagged("RaidOutpostZone") do
		addFromInstance(tagged)
	end
	return parts
end

function BuildingValidator.IsInRaidOutpostZone(pieceType: BuildPieceType, targetCF: CFrame): boolean
	local zoneParts = collectRaidOutpostParts()
	if #zoneParts == 0 then
		return false
	end

	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = zoneParts

	for _, box in BuildingGeometry.GetOverlapBoxes(pieceType, targetCF, 0.25) do
		local hits = Workspace:GetPartBoundsInBox(box.CFrame, box.Size, params)
		if #hits > 0 then
			return true
		end
	end
	return false
end

local function isSurfaceCategory(category: Types.BuildPieceCategory): boolean
	return category == "Foundation" or category == "Floor"
end

local function getSurfaceWallYOffset(category: Types.BuildPieceCategory): number
	return if category == "Foundation" then BuildingConfig.FoundationThickness else BuildingConfig.FloorThickness
end

function BuildingValidator.CheckMaxWallsToTC(
	playerRecords: { [string]: LivePieceEntry },
	_occupiedSockets: { [string]: { [string]: string } },
	candidatePiece: CandidatePieceInput?,
	excludeUid: string?
): (boolean, string?, number?)
	type SurfaceNode = {
		Uid: string,
		PieceType: BuildPieceType,
		Category: Types.BuildPieceCategory,
		CFrame: CFrame,
	}
	type EdgeBarrier = {
		CFrame: CFrame,
		Cost: number,
	}
	type GraphEdge = {
		To: string,
		Cost: number,
	}

	local EXTERIOR_UID = "__EXTERIOR__"
	local surfaces: { [string]: SurfaceNode } = {}
	local surfaceList: { SurfaceNode } = {}
	local edgeBarriers: { EdgeBarrier } = {}
	local stairsList: { { PieceType: BuildPieceType, CFrame: CFrame, ParentUid: string? } } = {}

	local tcParentUid: string? = nil
	local tcPos: Vector3? = nil

	for uid, record in playerRecords do
		if record.Model.Parent == nil or (excludeUid ~= nil and uid == excludeUid) then
			continue
		end
		local canonical = BuildingGeometry.CanonicalPieceType(record.Piece.PieceType)
		local cfg = BuildingConfig.Pieces[canonical]
		if cfg == nil then
			continue
		end

		if canonical == "tool_cupboard" then
			tcParentUid = record.Piece.ParentUid or record.Piece.AnchorUid
			tcPos = record.CFrame.Position
		elseif canonical == "wall" or canonical == "window_wall" then
			table.insert(edgeBarriers, { CFrame = record.CFrame, Cost = 1 })
		elseif canonical == "doorway" then
			local barrierCost = if record.Model:GetAttribute("HasDoor") == true then 1 else 0
			table.insert(edgeBarriers, { CFrame = record.CFrame, Cost = barrierCost })
		elseif isSurfaceCategory(cfg.Category) then
			local node: SurfaceNode = {
				Uid = uid,
				PieceType = canonical,
				Category = cfg.Category,
				CFrame = record.CFrame,
			}
			surfaces[uid] = node
			table.insert(surfaceList, node)
		elseif cfg.Category == "Stairs" then
			table.insert(stairsList, {
				PieceType = canonical,
				CFrame = record.CFrame,
				ParentUid = record.Piece.ParentUid or record.Piece.AnchorUid,
			})
		end
	end

	if candidatePiece ~= nil then
		local candCanonical = BuildingGeometry.CanonicalPieceType(candidatePiece.PieceType)
		local candCfg = BuildingConfig.Pieces[candCanonical]
		if candCfg ~= nil then
			if candCanonical == "tool_cupboard" then
				tcParentUid = candidatePiece.ParentUid
				tcPos = candidatePiece.CFrame.Position
			elseif candCanonical == "wall" or candCanonical == "window_wall" then
				table.insert(edgeBarriers, { CFrame = candidatePiece.CFrame, Cost = 1 })
			elseif candCanonical == "doorway" then
				table.insert(edgeBarriers, { CFrame = candidatePiece.CFrame, Cost = 0 })
			elseif isSurfaceCategory(candCfg.Category) then
				local node: SurfaceNode = {
					Uid = "__CANDIDATE__",
					PieceType = candCanonical,
					Category = candCfg.Category,
					CFrame = candidatePiece.CFrame,
				}
				surfaces["__CANDIDATE__"] = node
				table.insert(surfaceList, node)
			elseif candCfg.Category == "Stairs" then
				table.insert(stairsList, {
					PieceType = candCanonical,
					CFrame = candidatePiece.CFrame,
					ParentUid = candidatePiece.ParentUid,
				})
			end
		end
	end

	if tcPos == nil then
		return true, nil, 0
	end

	local tcHostUid: string? = nil
	if tcParentUid ~= nil and surfaces[tcParentUid] ~= nil then
		tcHostUid = tcParentUid
	else
		local bestDist = 6.0
		for _, node in surfaceList do
			local dx = node.CFrame.Position.X - tcPos.X
			local dz = node.CFrame.Position.Z - tcPos.Z
			local dy = math.abs(node.CFrame.Position.Y - tcPos.Y)
			local xzDist = math.sqrt(dx * dx + dz * dz)
			if dy <= 3.0 and xzDist <= bestDist then
				bestDist = xzDist
				tcHostUid = node.Uid
			end
		end
	end

	if tcHostUid == nil then
		return true, nil, 0
	end

	local function getEdgeBarrierCost(edgeWallPos: Vector3): number
		for _, barrier in edgeBarriers do
			if barrier.Cost > 0 and (barrier.CFrame.Position - edgeWallPos).Magnitude <= 1.35 then
				return 1
			end
		end
		return 0
	end

	local function findNeighborAcrossEdge(node: SurfaceNode, edgeWorldPos: Vector3): SurfaceNode?
		local nodeY = node.CFrame.Position.Y
		for _, other in surfaceList do
			if other.Uid ~= node.Uid and math.abs(other.CFrame.Position.Y - nodeY) <= 1.2 then
				for _, otherSocket in BuildingGeometry.GetPieceSockets(other.PieceType) do
					if otherSocket.Kind == "Edge" then
						local otherEdgePos = (other.CFrame * otherSocket.LocalCFrame).Position
						if (otherEdgePos - edgeWorldPos).Magnitude <= 1.35 then
							return other
						end
					end
				end
			end
		end
		return nil
	end

	local adj: { [string]: { GraphEdge } } = {
		[EXTERIOR_UID] = {},
	}
	for _, node in surfaceList do
		adj[node.Uid] = {}
	end

	local function addDirectedEdge(fromUid: string, toUid: string, cost: number)
		table.insert(adj[fromUid], { To = toUid, Cost = cost })
	end

	local function addUndirectedEdge(aUid: string, bUid: string, cost: number)
		addDirectedEdge(aUid, bUid, cost)
		addDirectedEdge(bUid, aUid, cost)
	end

	local function pairKey(a: string, b: string): string
		return if a < b then (a .. "|" .. b) else (b .. "|" .. a)
	end

	for _, node in surfaceList do
		local wallYOffset = getSurfaceWallYOffset(node.Category)
		for _, socket in BuildingGeometry.GetPieceSockets(node.PieceType) do
			if socket.Kind == "Edge" then
				local edgeWorldCF = node.CFrame * socket.LocalCFrame
				local edgeWorldPos = edgeWorldCF.Position
				local edgeWallPos = (edgeWorldCF * CFrame.new(0, wallYOffset, 0)).Position
				local edgeCost = getEdgeBarrierCost(edgeWallPos)
				local neighbor = findNeighborAcrossEdge(node, edgeWorldPos)
				if neighbor ~= nil then
					addDirectedEdge(node.Uid, neighbor.Uid, edgeCost)
				else
					addDirectedEdge(EXTERIOR_UID, node.Uid, edgeCost)
				end
			end
		end
	end

	local hasImmediateCeiling: { [string]: boolean } = {}
	local hasAnyOverheadRoof: { [string]: boolean } = {}
	local connectedPairs: { [string]: boolean } = {}

	-- Connect solid ceiling/floor slabs above lower surfaces (+1 layer) first so stairs cannot bypass solid slabs
	for _, lower in surfaceList do
		local lowerPos = lower.CFrame.Position
		for _, upper in surfaceList do
			if upper.Uid ~= lower.Uid and upper.Category == "Floor" then
				local dy = upper.CFrame.Position.Y - lowerPos.Y
				if dy >= 7.0 then
					local dx = upper.CFrame.Position.X - lowerPos.X
					local dz = upper.CFrame.Position.Z - lowerPos.Z
					local xzDist = math.sqrt(dx * dx + dz * dz)
					if xzDist <= 3.0 then
						hasAnyOverheadRoof[lower.Uid] = true
						if dy <= 12.5 then
							hasImmediateCeiling[lower.Uid] = true
							local pKey = pairKey(lower.Uid, upper.Uid)
							if not connectedPairs[pKey] then
								connectedPairs[pKey] = true
								addUndirectedEdge(lower.Uid, upper.Uid, 1)
							end
						end
					end
				end
			end
		end
	end

	-- Connect unobstructed stairs to adjacent upper floors across shared upper/lower edge
	for _, stair in stairsList do
		local hostNode: SurfaceNode? = if stair.ParentUid ~= nil then surfaces[stair.ParentUid] else nil
		if hostNode == nil then
			local bestDist = 6.0
			for _, node in surfaceList do
				local dx = node.CFrame.Position.X - stair.CFrame.Position.X
				local dz = node.CFrame.Position.Z - stair.CFrame.Position.Z
				local dy = math.abs(node.CFrame.Position.Y - stair.CFrame.Position.Y)
				local xzDist = math.sqrt(dx * dx + dz * dz)
				if dy <= 3.0 and xzDist <= bestDist then
					bestDist = xzDist
					hostNode = node
				end
			end
		end

		if hostNode ~= nil and not hasImmediateCeiling[hostNode.Uid] then
			local hostPos = hostNode.CFrame.Position
			local lowerWallYOffset = getSurfaceWallYOffset(hostNode.Category)
			for _, upper in surfaceList do
				if upper.Uid ~= hostNode.Uid and upper.Category == "Floor" then
					local dy = upper.CFrame.Position.Y - hostPos.Y
					if dy >= 7.0 and dy <= 12.5 then
						local dx = upper.CFrame.Position.X - hostPos.X
						local dz = upper.CFrame.Position.Z - hostPos.Z
						local xzDist = math.sqrt(dx * dx + dz * dz)
						local pKey = pairKey(hostNode.Uid, upper.Uid)
						if xzDist > 3.0 and not connectedPairs[pKey] then
							for _, socket in BuildingGeometry.GetPieceSockets(hostNode.PieceType) do
								if socket.Kind == "Edge" then
									local lowerEdgeCF = hostNode.CFrame * socket.LocalCFrame
									local lowerWallPos = (lowerEdgeCF * CFrame.new(0, lowerWallYOffset, 0)).Position
									local upperEdgePos = lowerEdgeCF.Position + Vector3.new(0, dy, 0)
									local upperWallPos = upperEdgePos + Vector3.new(0, BuildingConfig.FloorThickness, 0)
									local stairEdgeCost =
										math.max(getEdgeBarrierCost(lowerWallPos), getEdgeBarrierCost(upperWallPos))
									local linked = false
									for _, uSock in BuildingGeometry.GetPieceSockets(upper.PieceType) do
										if uSock.Kind == "Edge" then
											local uEdgePos = (upper.CFrame * uSock.LocalCFrame).Position
											if (uEdgePos - upperEdgePos).Magnitude <= 1.5 then
												connectedPairs[pKey] = true
												addUndirectedEdge(hostNode.Uid, upper.Uid, stairEdgeCost)
												linked = true
												break
											end
										end
									end
									if linked then
										break
									end
								end
							end
						end
					end
				end
			end
		end
	end

	-- Open sky surfaces have 0-layer access from exterior
	for _, node in surfaceList do
		if not hasAnyOverheadRoof[node.Uid] then
			addDirectedEdge(EXTERIOR_UID, node.Uid, 0)
		end
	end

	-- 0-1 BFS on deque from EXTERIOR_UID to tcHostUid
	local deque: { [number]: string? } = {}
	local front = 1
	local back = 0
	local dist: { [string]: number } = {}

	dist[EXTERIOR_UID] = 0
	back += 1
	deque[back] = EXTERIOR_UID

	while front <= back do
		local current = deque[front]
		deque[front] = nil
		front += 1
		if current == nil then
			continue
		end
		local curDist = dist[current]
		if curDist == nil then
			continue
		end
		if current == tcHostUid then
			break
		end
		for _, edge in adj[current] do
			local nextDist = curDist + edge.Cost
			local prevDist = dist[edge.To]
			if prevDist == nil or nextDist < prevDist then
				dist[edge.To] = nextDist
				if edge.Cost == 0 then
					front -= 1
					deque[front] = edge.To
				else
					back += 1
					deque[back] = edge.To
				end
			end
		end
	end

	local minLayers = dist[tcHostUid]
	if minLayers == nil or minLayers > Config.MAX_TC_WALL_LAYERS then
		return false,
			"Превышен лимит защиты шкафа: максимум 2 слоя стен до TC",
			minLayers
	end

	return true, nil, minLayers
end

function BuildingValidator.CanReachToolCupboard(
	playerRecords: { [string]: LivePieceEntry },
	occupiedSockets: { [string]: { [string]: string } },
	candidatePiece: CandidatePieceInput?
): (boolean, string?)
	local ok, reason = BuildingValidator.CheckMaxWallsToTC(playerRecords, occupiedSockets, candidatePiece)
	return ok, reason
end

function BuildingValidator.FindUnsupportedPieces(
	pieces: { SavedBuildPiece },
	removedUids: { [string]: boolean }?
): { string }
	type NodeInfo = {
		Piece: SavedBuildPiece,
		Canonical: BuildPieceType,
		Category: Types.BuildPieceCategory,
		AssaultDeployable: boolean,
		CFrame: CFrame,
	}

	local nodes: { NodeInfo } = {}
	local nodesByUid: { [string]: NodeInfo } = {}
	local remainingPieces: { SavedBuildPiece } = {}

	for _, piece in pieces do
		if removedUids ~= nil and removedUids[piece.Uid] == true then
			continue
		end
		local canonical = BuildingGeometry.CanonicalPieceType(piece.PieceType)
		local cfg = BuildingConfig.Pieces[canonical]
		if cfg ~= nil then
			local info: NodeInfo = {
				Piece = piece,
				Canonical = canonical,
				Category = cfg.Category,
				AssaultDeployable = cfg.AssaultDeployable == true,
				CFrame = BuildingGeometry.GetPieceWorldCFrame(piece),
			}
			table.insert(nodes, info)
			nodesByUid[piece.Uid] = info
			table.insert(remainingPieces, piece)
		end
	end

	if #nodes == 0 then
		return {}
	end

	local groundRefY = getBaseFloorGroundY(remainingPieces, 0)
	local supported: { [string]: boolean } = {}
	local floorDepth: { [string]: number } = {}
	local supportedSurfaces: { NodeInfo } = {}
	local supportedWalls: { NodeInfo } = {}
	local supportedFloors: { NodeInfo } = {}

	local function markSupported(node: NodeInfo, depth: number?)
		local uid = node.Piece.Uid
		if supported[uid] then
			return
		end
		supported[uid] = true
		if node.Category == "Foundation" or node.Category == "Floor" then
			table.insert(supportedSurfaces, node)
			if node.Category == "Floor" then
				floorDepth[uid] = depth or 0
				table.insert(supportedFloors, node)
			end
		elseif node.Category == "Wall" then
			table.insert(supportedWalls, node)
		end
	end

	-- Seed grounded pieces: Foundations, AssaultDeployables, and yard-grounded floor deployables
	for _, node in nodes do
		if node.Category == "Foundation" or node.AssaultDeployable then
			markSupported(node, nil)
		elseif node.Category == "Deployable" then
			local parentUid = node.Piece.ParentUid or node.Piece.AnchorUid
			local mount = node.Piece.MountSurface
			if
				(mount == nil or mount == "Floor")
				and parentUid == nil
				and node.CFrame.Position.Y <= (groundRefY + 1.8)
			then
				markSupported(node, nil)
			end
		end
	end

	local function hasSupportedSurfaceUnderEdge(wallPos: Vector3): boolean
		for _, surf in supportedSurfaces do
			local wallYOffset = getSurfaceWallYOffset(surf.Category)
			for _, socket in BuildingGeometry.GetPieceSockets(surf.Canonical) do
				if socket.Kind == "Edge" then
					local expectedWallPos = (surf.CFrame * socket.LocalCFrame * CFrame.new(0, wallYOffset, 0)).Position
					if (expectedWallPos - wallPos).Magnitude <= 1.5 then
						return true
					end
				end
			end
		end
		return false
	end

	local function hasSupportedWallUnderWall(wallPos: Vector3): boolean
		for _, lowerWall in supportedWalls do
			local lp = lowerWall.CFrame.Position
			local dx = wallPos.X - lp.X
			local dz = wallPos.Z - lp.Z
			local dy = wallPos.Y - lp.Y
			if math.sqrt(dx * dx + dz * dz) <= 1.2 and dy >= 8.5 and dy <= 10.8 then
				return true
			end
		end
		return false
	end

	local function hasSupportedWallSupportingFloor(floorNode: NodeInfo): boolean
		local floorSockets = BuildingGeometry.GetPieceSockets(floorNode.Canonical)
		for _, wall in supportedWalls do
			local wallTopPos = wall.CFrame.Position + Vector3.new(0, BuildingConfig.WallBodyHeight, 0)
			for _, socket in floorSockets do
				if socket.Kind == "Edge" then
					local edgePos = (floorNode.CFrame * socket.LocalCFrame).Position
					if (edgePos - wallTopPos).Magnitude <= 1.5 then
						return true
					end
				end
			end
		end
		return false
	end

	local function hasSupportedAdjacentFloor(floorNode: NodeInfo): boolean
		local floorSockets = BuildingGeometry.GetPieceSockets(floorNode.Canonical)
		for _, adj in supportedFloors do
			if (floorDepth[adj.Piece.Uid] or 0) == 0 then
				for _, sockA in floorSockets do
					if sockA.Kind == "Edge" then
						local posA = (floorNode.CFrame * sockA.LocalCFrame).Position
						for _, sockB in BuildingGeometry.GetPieceSockets(adj.Canonical) do
							if sockB.Kind == "Edge" then
								local posB = (adj.CFrame * sockB.LocalCFrame).Position
								if (posA - posB).Magnitude <= 1.5 then
									return true
								end
							end
						end
					end
				end
			end
		end
		return false
	end

	local function isParentValidAndSupported(node: NodeInfo, allowedParentCategories: { [string]: boolean }?): boolean?
		local parentUid = node.Piece.ParentUid or node.Piece.AnchorUid
		if parentUid == nil then
			return nil
		end
		local parentNode = nodesByUid[parentUid]
		if parentNode == nil or not supported[parentUid] then
			return false
		end
		if allowedParentCategories ~= nil and not allowedParentCategories[parentNode.Category] then
			return false
		end
		return true
	end

	local changed = true
	local guard = 0
	while changed and guard <= #nodes do
		changed = false
		guard += 1
		for _, node in nodes do
			if supported[node.Piece.Uid] then
				continue
			end

			local pos = node.CFrame.Position
			if node.Category == "Wall" then
				local parentOk = isParentValidAndSupported(node, { Foundation = true, Floor = true, Wall = true })
				if parentOk == true or hasSupportedSurfaceUnderEdge(pos) or hasSupportedWallUnderWall(pos) then
					markSupported(node, nil)
					changed = true
				end
			elseif node.Category == "Floor" then
				local parentOk = isParentValidAndSupported(node, { Wall = true, Floor = true })
				if hasSupportedWallSupportingFloor(node) then
					markSupported(node, 0)
					changed = true
				elseif parentOk == true then
					local pUid = (node.Piece.ParentUid or node.Piece.AnchorUid) :: string
					local pNode = nodesByUid[pUid]
					local nextDepth = if pNode.Category == "Wall" then 0 else ((floorDepth[pUid] or 0) + 1)
					if nextDepth <= 1 then
						markSupported(node, nextDepth)
						changed = true
					end
				elseif hasSupportedAdjacentFloor(node) then
					markSupported(node, 1)
					changed = true
				end
			elseif node.Category == "Stairs" then
				local parentOk = isParentValidAndSupported(node, { Foundation = true, Floor = true })
				local isOk = parentOk == true
				if not isOk and parentOk == nil then
					for _, surf in supportedSurfaces do
						local dx = pos.X - surf.CFrame.Position.X
						local dz = pos.Z - surf.CFrame.Position.Z
						local dy = pos.Y - surf.CFrame.Position.Y
						if math.sqrt(dx * dx + dz * dz) <= 4.5 and dy >= -0.5 and dy <= 2.2 then
							isOk = true
							break
						end
					end
				end
				if isOk then
					markSupported(node, nil)
					changed = true
				end
			elseif node.Category == "Deployable" then
				local mount = node.Piece.MountSurface
				if mount == "Wall" then
					local parentOk = isParentValidAndSupported(node, { Wall = true })
					local isOk = parentOk == true
					if not isOk and parentOk == nil then
						for _, wall in supportedWalls do
							local lp = wall.CFrame:PointToObjectSpace(pos)
							if math.abs(lp.X) <= 6.2 and math.abs(lp.Z) <= 2.0 and lp.Y >= 0 and lp.Y <= 9.5 then
								isOk = true
								break
							end
						end
					end
					if isOk then
						markSupported(node, nil)
						changed = true
					end
				elseif mount == "Ceiling" then
					local parentOk = isParentValidAndSupported(node, { Floor = true, Foundation = true })
					local isOk = parentOk == true
					if not isOk and parentOk == nil then
						for _, fl in supportedFloors do
							local dx = pos.X - fl.CFrame.Position.X
							local dz = pos.Z - fl.CFrame.Position.Z
							local dy = math.abs(pos.Y - fl.CFrame.Position.Y)
							if math.sqrt(dx * dx + dz * dz) <= 6.2 and dy <= 1.5 then
								isOk = true
								break
							end
						end
					end
					if isOk then
						markSupported(node, nil)
						changed = true
					end
				else
					local parentOk = isParentValidAndSupported(node, { Foundation = true, Floor = true })
					local isOk = parentOk == true
					if not isOk and parentOk == nil then
						for _, surf in supportedSurfaces do
							local dx = pos.X - surf.CFrame.Position.X
							local dz = pos.Z - surf.CFrame.Position.Z
							local dy = pos.Y - surf.CFrame.Position.Y
							if math.sqrt(dx * dx + dz * dz) <= 6.5 and dy >= -0.5 and dy <= 2.5 then
								isOk = true
								break
							end
						end
					end
					if isOk then
						markSupported(node, nil)
						changed = true
					end
				end
			end
		end
	end

	local unsupported: { string } = {}
	for _, node in nodes do
		if not supported[node.Piece.Uid] then
			table.insert(unsupported, node.Piece.Uid)
		end
	end
	return unsupported
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

local function raycastDefenseSurface(origin: Vector3, direction: Vector3, playerCharacter: Model?): RaycastResult?
	local excludeList: { Instance } = {}
	if playerCharacter ~= nil then
		table.insert(excludeList, playerCharacter)
	end
	for _, folderName in { "LootContainers", "RaidOutpostZone", "ResourceNodes" } do
		local folder = Workspace:FindFirstChild(folderName)
		if folder ~= nil then
			table.insert(excludeList, folder)
		end
	end

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.IgnoreWater = true
	params.FilterDescendantsInstances = excludeList

	for _ = 1, 6 do
		local result = Workspace:Raycast(origin, direction, params)
		if result == nil then
			return nil
		end
		if result.Instance.CanCollide == false and not result.Instance:IsA("Terrain") then
			table.insert(excludeList, result.Instance)
			params.FilterDescendantsInstances = excludeList
		else
			return result
		end
	end
	return nil
end

local function findPlayerStructureEntryFromPart(
	hitInstance: Instance,
	playerRecords: { [string]: LivePieceEntry }
): LivePieceEntry?
	local current: Instance? = hitInstance
	while current ~= nil and current ~= Workspace do
		if current:IsA("Model") then
			local uidAttr = current:GetAttribute("BuildUid")
			if typeof(uidAttr) == "string" and #uidAttr > 0 then
				return playerRecords[uidAttr]
			end
		end
		current = current.Parent
	end
	return nil
end

local function validateDefensePlacement(
	input: PlacementValidationInput,
	pieceType: BuildPieceType
): PlacementValidationResult
	if input.IsRaidMode == true then
		return {
			Allowed = false,
			Reason = "Ловушки и турели нельзя устанавливать во время рейда",
		}
	end

	local defCfg = Defenses.Get(pieceType)
	if defCfg == nil then
		return { Allowed = false, Reason = "Invalid defense type" }
	end

	local usedCap, maxCap = BuildingValidator.ComputeDefenseCapacity(input.BasePieces, input.PlayerBaseTier or 0)
	if usedCap + defCfg.CapacityCost > maxCap then
		return {
			Allowed = false,
			Reason = string.format(
				"Лимит защиты превышен: %d / %d очков (+%d)",
				usedCap,
				maxCap,
				defCfg.CapacityCost
			),
		}
	end

	if BuildingValidator.IsInRaidOutpostZone(pieceType, input.RequestedCFrame) then
		return {
			Allowed = false,
			Reason = "Установка защиты в зоне рейд-кибитки (RaidOutpostZone) запрещена",
		}
	end

	local authoritativeCF: CFrame
	local resolvedMount: DefenseMountSurface
	local resolvedParentUid: string? = nil
	local excludeOverlap: { Instance }? = nil

	if defCfg.AllowedMount == "Floor" then
		local hit = raycastDefenseSurface(
			input.RequestedCFrame.Position + Vector3.new(0, 2.5, 0),
			Vector3.new(0, -5.5, 0),
			input.Character
		)
		if hit == nil or hit.Normal.Y < 0.7 then
			return {
				Allowed = false,
				Reason = "Требуется ровная поверхность пола или фундамента",
			}
		end
		if BuildingGeometry.IsNoBuildInstance(hit.Instance, false) then
			return {
				Allowed = false,
				Reason = "Установка в запрещённой зоне невозможна",
			}
		end
		local yawDeg = BuildingGeometry.QuantizeYaw30(BuildingGeometry.ExtractYawDegrees(input.RequestedCFrame))
		authoritativeCF = CFrame.new(hit.Position) * CFrame.Angles(0, math.rad(yawDeg), 0)
		resolvedMount = "Floor"
		local hostEntry = findPlayerStructureEntryFromPart(hit.Instance, input.PlayerRecords)
		if hostEntry ~= nil then
			resolvedParentUid = hostEntry.Piece.Uid
		end
	else
		local mountHint: DefenseMountSurface = if input.MountSurface == "Ceiling" then "Ceiling" else "Wall"
		if mountHint == "Ceiling" then
			local hit = raycastDefenseSurface(
				input.RequestedCFrame.Position - Vector3.new(0, 1.5, 0),
				Vector3.new(0, 4.0, 0),
				input.Character
			)
			if hit == nil or hit.Normal.Y > -0.7 then
				return {
					Allowed = false,
					Reason = "Ловушка-дробовик крепится на стену или потолок",
				}
			end
			local hostEntry = findPlayerStructureEntryFromPart(hit.Instance, input.PlayerRecords)
			if hostEntry == nil or hostEntry.Model.Parent == nil then
				return {
					Allowed = false,
					Reason = "Крепление возможно только на свои постройки",
				}
			end
			local hostCfg = BuildingConfig.Pieces[hostEntry.Piece.PieceType]
			if hostCfg == nil or (hostCfg.Category ~= "Floor" and hostCfg.Category ~= "Foundation") then
				return {
					Allowed = false,
					Reason = "Для потолочного крепления требуется перекрытие",
				}
			end
			local yawDeg = BuildingGeometry.QuantizeYaw30(BuildingGeometry.ExtractYawDegrees(input.RequestedCFrame))
			authoritativeCF = CFrame.new(hit.Position) * CFrame.Angles(0, math.rad(yawDeg), 0)
			resolvedMount = "Ceiling"
			resolvedParentUid = hostEntry.Piece.Uid
			excludeOverlap = { hostEntry.Model }
		else
			local lookVec = input.RequestedCFrame.LookVector
			local horizLook = Vector3.new(lookVec.X, 0, lookVec.Z)
			if horizLook.Magnitude < 0.05 then
				horizLook = Vector3.new(0, 0, -1)
			else
				horizLook = horizLook.Unit
			end
			local hit = raycastDefenseSurface(
				input.RequestedCFrame.Position + horizLook * 1.2,
				-horizLook * 3.2,
				input.Character
			)
			if hit == nil or math.abs(hit.Normal.Y) > 0.35 then
				return {
					Allowed = false,
					Reason = "Ловушка-дробовик крепится на стену или потолок",
				}
			end
			local hostEntry = findPlayerStructureEntryFromPart(hit.Instance, input.PlayerRecords)
			if hostEntry == nil or hostEntry.Model.Parent == nil then
				return {
					Allowed = false,
					Reason = "Крепление возможно только на свои стены",
				}
			end
			local hostCfg = BuildingConfig.Pieces[hostEntry.Piece.PieceType]
			if hostCfg == nil or hostCfg.Category ~= "Wall" then
				return {
					Allowed = false,
					Reason = "Для настенного крепления требуется стена",
				}
			end
			local horizNormal = Vector3.new(hit.Normal.X, 0, hit.Normal.Z)
			if horizNormal.Magnitude < 0.05 then
				return { Allowed = false, Reason = "Некорректная нормаль стены" }
			end
			horizNormal = horizNormal.Unit
			authoritativeCF = CFrame.lookAt(hit.Position, hit.Position + horizNormal)
			resolvedMount = "Wall"
			resolvedParentUid = hostEntry.Piece.Uid
			excludeOverlap = { hostEntry.Model }
		end
	end

	local maxAllowedDistance = BuildingConfig.MaxBuildDistance + Types.PING_DISTANCE_TOLERANCE
	if (input.HrpPosition - authoritativeCF.Position).Magnitude > maxAllowedDistance then
		return { Allowed = false, Reason = "Target out of build range" }
	end

	if BuildingValidator.IsInRaidOutpostZone(pieceType, authoritativeCF) then
		return {
			Allowed = false,
			Reason = "Установка защиты в зоне рейд-кибитки (RaidOutpostZone) запрещена",
		}
	end

	for _, existing in input.PlayerRecords do
		if existing.Model.Parent == nil then
			continue
		end
		local existingType = BuildingGeometry.CanonicalPieceType(existing.Piece.PieceType)
		local existingCfg = BuildingConfig.Pieces[existingType]
		if existingCfg ~= nil and existingCfg.IsDefense == true then
			local dist = (existing.CFrame.Position - authoritativeCF.Position).Magnitude
			if pieceType == "auto_turret" and existingType == "auto_turret" then
				if dist < Config.MIN_TURRET_DISTANCE then
					return {
						Allowed = false,
						Reason = "Слишком близко к другой турели (интерференция)",
					}
				end
			elseif
				(pieceType == "auto_turret" and existingType == "shotgun_trap")
				or (pieceType == "shotgun_trap" and existingType == "auto_turret")
			then
				if dist < Config.MIN_TRAP_DISTANCE then
					return {
						Allowed = false,
						Reason = "Слишком близко к другой турели (интерференция)",
					}
				end
			elseif pieceType == "shotgun_trap" and existingType == "shotgun_trap" then
				if dist < Config.MIN_TRAP_DISTANCE then
					return {
						Allowed = false,
						Reason = "Слишком близко к другой ловушке-дробовику",
					}
				end
			elseif dist < DEFENSE_MIN_SPACING then
				return {
					Allowed = false,
					Reason = "Слишком близко к другой ловушке или турели",
				}
			end
		end
	end

	local worldSocketKey = BuildingValidator.GetWorldSocketKeyForPiece(pieceType, authoritativeCF)
	if input.OccupiedWorldKeys[worldSocketKey] ~= nil then
		return { Allowed = false, Reason = "Позиция уже занята другой защитой" }
	end

	local overlap =
		BuildingValidator.CheckWorldOverlap(pieceType, authoritativeCF, excludeOverlap, false, false, resolvedMount)
	if not overlap.Allowed then
		return { Allowed = false, Reason = overlap.Reason or "Overlap blocked" }
	end

	local finalRotY = BuildingGeometry.QuantizeYaw30(BuildingGeometry.ExtractYawDegrees(authoritativeCF))
	return {
		Allowed = true,
		AuthoritativeCFrame = authoritativeCF,
		ResolvedParentUid = resolvedParentUid,
		ResolvedSocketId = nil,
		ResolvedSlotKey = nil,
		ResolvedMountSurface = resolvedMount,
		WorldSocketKey = worldSocketKey,
		RotY = finalRotY,
	}
end

function BuildingValidator.ValidatePlacement(input: PlacementValidationInput): PlacementValidationResult
	local pieceType = BuildingGeometry.CanonicalPieceType(input.PieceType)
	local pieceConfig = BuildingConfig.Pieces[pieceType]
	if pieceConfig == nil then
		return { Allowed = false, Reason = "Invalid piece type" }
	end

	if pieceConfig.IsDefense == true then
		return validateDefensePlacement(input, pieceType)
	end

	local isRaidMode = input.IsRaidMode == true
	if isRaidMode and pieceType == "tool_cupboard" then
		return { Allowed = false, Reason = "В рейде нельзя устанавливать Tool Cupboard" }
	end

	if not isRaidMode and pieceConfig.MaxPerBase ~= nil then
		local existingCount = 0
		for _, existing in input.BasePieces do
			if BuildingGeometry.CanonicalPieceType(existing.PieceType) == pieceType then
				existingCount += 1
			end
		end
		if existingCount >= pieceConfig.MaxPerBase then
			return {
				Allowed = false,
				Reason = string.format(
					"На базе можно установить не более %d %s",
					pieceConfig.MaxPerBase,
					pieceConfig.Name
				),
			}
		end
	end

	if not isRaidMode and pieceConfig.RequiredBaseTier ~= nil then
		local currentTier = input.PlayerBaseTier or 0
		if currentTier < pieceConfig.RequiredBaseTier then
			return {
				Allowed = false,
				Reason = string.format(
					"Для %s требуется База Tier %d (сейчас Tier %d)",
					pieceConfig.Name,
					pieceConfig.RequiredBaseTier,
					currentTier
				),
			}
		end
	end

	local parentUid = input.ParentUid
	local socketId = input.SocketId
	local authoritativeCF: CFrame
	local resolvedSlotKey: string? = nil

	if parentUid == nil or socketId == nil then
		if pieceConfig.Category ~= "Foundation" and not pieceConfig.AssaultDeployable then
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
		if BuildingGeometry.IsNoBuildInstance(groundHit.Instance, isRaidMode) then
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

	local inOutpostZone = BuildingValidator.IsInRaidOutpostZone(pieceType, authoritativeCF)
	if isRaidMode then
		if not pieceConfig.AssaultDeployable and not inOutpostZone then
			return {
				Allowed = false,
				Reason = "Вне RaidOutpostZone разрешены только штурмовые лестницы и баррикады",
			}
		end
	else
		if inOutpostZone then
			return {
				Allowed = false,
				Reason = "Строительство в зоне рейд-кибитки (RaidOutpostZone) запрещено",
			}
		end
	end

	local overlap = BuildingValidator.CheckWorldOverlap(pieceType, authoritativeCF, nil, parentUid == nil, isRaidMode)
	if not overlap.Allowed then
		return { Allowed = false, Reason = overlap.Reason or "Overlap blocked" }
	end

	if
		not isRaidMode
		and (
			pieceConfig.Category == "Wall"
			or pieceConfig.Category == "Floor"
			or pieceConfig.Category == "Foundation"
			or pieceType == "tool_cupboard"
		)
	then
		local reachable, reachReason = BuildingValidator.CheckMaxWallsToTC(input.PlayerRecords, input.OccupiedSockets, {
			PieceType = pieceType,
			CFrame = authoritativeCF,
			ParentUid = parentUid,
			SocketId = socketId,
		})
		if not reachable then
			return {
				Allowed = false,
				Reason = reachReason
					or "Превышен лимит защиты шкафа: максимум 2 слоя стен до TC",
			}
		end
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
