--!strict
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Types = require(ReplicatedStorage.Shared.Types)
local BuildingConfig = require(ReplicatedStorage.Shared.configs.BuildingConfig)

type BuildPieceType = Types.BuildPieceType
type BuildTier = Types.BuildTier
type BuildSocketDef = Types.BuildSocketDef
type BuildOverlapBox = Types.BuildOverlapBox
type SavedBuildPiece = Types.SavedBuildPiece

export type ParallelWallCandidate = { PieceType: BuildPieceType, CFrame: CFrame }
export type OverlapCheckResult = { Allowed: boolean, Reason: string? }

local TRIANGLE_HEIGHT = BuildingConfig.TriangleHeight
local TRIANGLE_INRADIUS = BuildingConfig.TriangleInradius
local GRID_SIZE = BuildingConfig.GridSize
local WALL_HEIGHT = BuildingConfig.WallHeight
local WALL_BODY_HEIGHT = BuildingConfig.WallBodyHeight
local WALL_THICKNESS = BuildingConfig.WallThickness
local FLOOR_THICKNESS = BuildingConfig.FloorThickness
local FOUNDATION_THICKNESS = BuildingConfig.FoundationThickness
local COS_15_DEG = math.cos(math.rad(15))

local function makeSquareSockets(topY: number, centerY: number): { BuildSocketDef }
	local h = GRID_SIZE * 0.5
	return table.freeze({
		table.freeze({ Id = "Edge_1", Kind = "Edge", LocalCFrame = CFrame.new(0, 0, -h) }),
		table.freeze({
			Id = "Edge_2",
			Kind = "Edge",
			LocalCFrame = CFrame.new(h, 0, 0) * CFrame.Angles(0, math.rad(-90), 0),
		}),
		table.freeze({
			Id = "Edge_3",
			Kind = "Edge",
			LocalCFrame = CFrame.new(0, 0, h) * CFrame.Angles(0, math.rad(180), 0),
		}),
		table.freeze({
			Id = "Edge_4",
			Kind = "Edge",
			LocalCFrame = CFrame.new(-h, 0, 0) * CFrame.Angles(0, math.rad(90), 0),
		}),
		table.freeze({ Id = "Top", Kind = "Top", LocalCFrame = CFrame.new(0, topY, 0) }),
		table.freeze({ Id = "Center", Kind = "Center", LocalCFrame = CFrame.new(0, centerY, 0) }),
	})
end

local function makeTriangleSockets(topY: number, centerY: number): { BuildSocketDef }
	local r = TRIANGLE_INRADIUS
	return table.freeze({
		table.freeze({
			Id = "Edge_1",
			Kind = "Edge",
			LocalCFrame = CFrame.Angles(0, math.rad(0), 0) * CFrame.new(0, 0, -r),
		}),
		table.freeze({
			Id = "Edge_2",
			Kind = "Edge",
			LocalCFrame = CFrame.Angles(0, math.rad(120), 0) * CFrame.new(0, 0, -r),
		}),
		table.freeze({
			Id = "Edge_3",
			Kind = "Edge",
			LocalCFrame = CFrame.Angles(0, math.rad(240), 0) * CFrame.new(0, 0, -r),
		}),
		table.freeze({ Id = "Top", Kind = "Top", LocalCFrame = CFrame.new(0, topY, 0) }),
		table.freeze({ Id = "Center", Kind = "Center", LocalCFrame = CFrame.new(0, centerY, 0) }),
	})
end

local SQUARE_FOUNDATION_SOCKETS = makeSquareSockets(FOUNDATION_THICKNESS + WALL_BODY_HEIGHT, FOUNDATION_THICKNESS)
local SQUARE_FLOOR_SOCKETS = makeSquareSockets(WALL_HEIGHT, FLOOR_THICKNESS)
local TRIANGLE_FOUNDATION_SOCKETS = makeTriangleSockets(FOUNDATION_THICKNESS + WALL_BODY_HEIGHT, FOUNDATION_THICKNESS)
local TRIANGLE_FLOOR_SOCKETS = makeTriangleSockets(WALL_HEIGHT, FLOOR_THICKNESS)
local WALL_SOCKETS: { BuildSocketDef } = table.freeze({
	table.freeze({ Id = "WallTop", Kind = "WallTop", LocalCFrame = CFrame.new(0, WALL_BODY_HEIGHT, 0) }),
})
local EMPTY_SOCKETS: { BuildSocketDef } = table.freeze({})
local NO_BUILD_FOLDERS = {
	"NoBuildZones",
	"Monuments",
	"POI",
	"ExtractionZones",
	"AirdropZones",
	"ResourceNodes",
	"Workbenches",
	"RaidTerminal",
	"RaidOutpostZone",
}

local BuildingGeometry = {}

function BuildingGeometry.CanonicalPieceType(pieceType: string): BuildPieceType
	return BuildingConfig.NormalizePieceType(pieceType) or (pieceType :: BuildPieceType)
end

local function spawnPrim(
	className: "Part" | "WedgePart",
	parent: Instance,
	name: string,
	size: Vector3,
	cf: CFrame,
	isGhost: boolean
): BasePart
	local part = Instance.new(className) :: BasePart
	part.Name = name
	part.Size = size
	part.CFrame = cf
	part.Anchored = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.CanCollide = not isGhost
	part.CanQuery = not isGhost
	part.CanTouch = not isGhost
	part.CastShadow = not isGhost
	part.Transparency = if isGhost then 0.5 else 0
	if isGhost then
		part.Material = Enum.Material.SmoothPlastic
	end
	part.Parent = parent
	return part
end

function BuildingGeometry.ExtractYawDegrees(cf: CFrame): number
	local _, yRad, _ = cf:ToOrientation()
	local deg = math.deg(yRad) % 360
	return if deg < 0 then deg + 360 else deg
end

function BuildingGeometry.QuantizeYaw30(yawDeg: number): number
	local snapped = (math.floor((yawDeg / 30) + 0.5) * 30) % 360
	return if snapped < 0 then snapped + 360 else snapped
end

function BuildingGeometry.ComposeWorldCFrame(posX: number, posY: number, posZ: number, rotYDeg: number): CFrame
	return CFrame.new(posX, posY, posZ) * CFrame.Angles(0, math.rad(rotYDeg), 0)
end

function BuildingGeometry.ConvertLegacyGridPiece(
	pieceType: BuildPieceType,
	gridX: number,
	gridY: number,
	gridZ: number,
	rotY: number
): CFrame
	local canonical = BuildingGeometry.CanonicalPieceType(pieceType)
	local baseCF = CFrame.new(gridX * GRID_SIZE, gridY * WALL_HEIGHT, gridZ * GRID_SIZE)
		* CFrame.Angles(0, math.rad(rotY), 0)
	if canonical == "foundation" or canonical == "triangle_foundation" then
		return baseCF
	elseif canonical == "wall" or canonical == "doorway" or canonical == "window_wall" then
		return baseCF * CFrame.new(0, FOUNDATION_THICKNESS, -GRID_SIZE * 0.5)
	elseif canonical == "roof" or canonical == "triangle_floor" then
		return baseCF * CFrame.new(0, FOUNDATION_THICKNESS + WALL_BODY_HEIGHT, 0)
	end
	return baseCF * CFrame.new(0, FOUNDATION_THICKNESS, 0)
end

function BuildingGeometry.GetPieceWorldCFrame(piece: SavedBuildPiece, originOffset: Vector3?): CFrame
	local offset = originOffset or Vector3.zero
	if typeof(piece.PosX) == "number" and typeof(piece.PosY) == "number" and typeof(piece.PosZ) == "number" then
		return CFrame.new(offset.X + piece.PosX, offset.Y + piece.PosY, offset.Z + piece.PosZ)
			* CFrame.Angles(0, math.rad(piece.RotY), 0)
	end
	return CFrame.new(offset)
		* BuildingGeometry.ConvertLegacyGridPiece(
			piece.PieceType,
			piece.GridX or 0,
			piece.GridY or 0,
			piece.GridZ or 0,
			piece.RotY
		)
end

function BuildingGeometry.ComputeMaxHp(pieceType: BuildPieceType, tier: BuildTier): number
	local pieceConfig = BuildingConfig.Pieces[pieceType]
	local tierConfig = BuildingConfig.Tiers[tier]
	if pieceConfig == nil or tierConfig == nil then
		return 100
	end
	return math.floor(pieceConfig.BaseHp * tierConfig.HpMultiplier + 0.5)
end

function BuildingGeometry.CreateModel(
	pieceType: BuildPieceType,
	worldCF: CFrame,
	isGhost: boolean,
	nameOverride: string?
): Model
	local canonical = BuildingGeometry.CanonicalPieceType(pieceType)
	local model = Instance.new("Model")
	model.Name = nameOverride or canonical

	local primaryPart: BasePart? = nil
	local primaryLocalCF = CFrame.identity

	if canonical == "foundation" or canonical == "roof" then
		local t = if canonical == "foundation" then FOUNDATION_THICKNESS else FLOOR_THICKNESS
		primaryLocalCF = CFrame.new(0, t * 0.5, 0)
		primaryPart =
			spawnPrim("Part", model, "Base", Vector3.new(GRID_SIZE, t, GRID_SIZE), worldCF * primaryLocalCF, isGhost)
	elseif canonical == "triangle_foundation" or canonical == "triangle_floor" then
		local t = if canonical == "triangle_foundation" then FOUNDATION_THICKNESS else FLOOR_THICKNESS
		local zCenter = TRIANGLE_HEIGHT / 6
		local wSize = Vector3.new(t, GRID_SIZE * 0.5, TRIANGLE_HEIGHT)
		primaryLocalCF = CFrame.new(-GRID_SIZE * 0.25, t * 0.5, zCenter)
			* CFrame.Angles(0, math.rad(180), math.rad(-90))
		primaryPart = spawnPrim("WedgePart", model, "LeftWedge", wSize, worldCF * primaryLocalCF, isGhost)
		local rightCF = CFrame.new(GRID_SIZE * 0.25, t * 0.5, zCenter) * CFrame.Angles(0, math.rad(180), math.rad(90))
		spawnPrim("WedgePart", model, "RightWedge", wSize, worldCF * rightCF, isGhost)
	elseif canonical == "wall" then
		primaryLocalCF = CFrame.new(0, WALL_BODY_HEIGHT * 0.5, 0)
		primaryPart = spawnPrim(
			"Part",
			model,
			"Wall",
			Vector3.new(GRID_SIZE, WALL_BODY_HEIGHT, WALL_THICKNESS),
			worldCF * primaryLocalCF,
			isGhost
		)
	elseif canonical == "doorway" then
		local pSize = Vector3.new(3.5, WALL_BODY_HEIGHT, WALL_THICKNESS)
		spawnPrim("Part", model, "LeftPillar", pSize, worldCF * CFrame.new(-4.25, WALL_BODY_HEIGHT * 0.5, 0), isGhost)
		spawnPrim("Part", model, "RightPillar", pSize, worldCF * CFrame.new(4.25, WALL_BODY_HEIGHT * 0.5, 0), isGhost)
		primaryLocalCF = CFrame.new(0, 8.4, 0)
		primaryPart = spawnPrim(
			"Part",
			model,
			"TopLintel",
			Vector3.new(5.0, 1.6, WALL_THICKNESS),
			worldCF * primaryLocalCF,
			isGhost
		)
	elseif canonical == "window_wall" then
		local pSize = Vector3.new(3.5, WALL_BODY_HEIGHT, WALL_THICKNESS)
		spawnPrim("Part", model, "LeftPillar", pSize, worldCF * CFrame.new(-4.25, WALL_BODY_HEIGHT * 0.5, 0), isGhost)
		spawnPrim("Part", model, "RightPillar", pSize, worldCF * CFrame.new(4.25, WALL_BODY_HEIGHT * 0.5, 0), isGhost)
		primaryLocalCF = CFrame.new(0, 1.3, 0)
		primaryPart = spawnPrim(
			"Part",
			model,
			"BottomSill",
			Vector3.new(5.0, 2.6, WALL_THICKNESS),
			worldCF * primaryLocalCF,
			isGhost
		)
		spawnPrim(
			"Part",
			model,
			"TopHeader",
			Vector3.new(5.0, 2.4, WALL_THICKNESS),
			worldCF * CFrame.new(0, 8.0, 0),
			isGhost
		)
	elseif canonical == "square_stairs" then
		primaryLocalCF = CFrame.new(-3.0, 4.2, -3.0)
		primaryPart =
			spawnPrim("Part", model, "MidLanding", Vector3.new(5.2, 0.8, 5.2), worldCF * primaryLocalCF, isGhost)
		local rSize = Vector3.new(5.2, 4.5, 5.6)
		spawnPrim(
			"WedgePart",
			model,
			"LowerRamp",
			rSize,
			worldCF * CFrame.new(-3.0, 2.25, 2.4) * CFrame.Angles(0, math.rad(180), 0),
			isGhost
		)
		spawnPrim(
			"WedgePart",
			model,
			"UpperRamp",
			rSize,
			worldCF * CFrame.new(2.4, 6.75, -3.0) * CFrame.Angles(0, math.rad(90), 0),
			isGhost
		)
		spawnPrim(
			"Part",
			model,
			"SupportPostA",
			Vector3.new(0.6, 3.8, 0.6),
			worldCF * CFrame.new(-5.2, 1.9, -5.2),
			isGhost
		)
		spawnPrim(
			"Part",
			model,
			"SupportPostB",
			Vector3.new(0.6, 3.8, 0.6),
			worldCF * CFrame.new(-0.8, 1.9, -5.2),
			isGhost
		)
	elseif canonical == "triangle_stairs" then
		primaryLocalCF = CFrame.new(2.3, 4.2, -1.65)
		primaryPart =
			spawnPrim("Part", model, "MidLanding", Vector3.new(2.2, 0.8, 2.4), worldCF * primaryLocalCF, isGhost)
		spawnPrim(
			"WedgePart",
			model,
			"LowerRamp",
			Vector3.new(2.4, 4.5, 4.4),
			worldCF * CFrame.new(-1.0, 2.25, -1.65) * CFrame.Angles(0, math.rad(90), 0),
			isGhost
		)
		local dir2 = Vector3.new(-0.5, 0, math.sqrt(3) / 2)
		local upperCenter = Vector3.new(1.0, 6.75, 1.1)
		spawnPrim(
			"WedgePart",
			model,
			"UpperRamp",
			Vector3.new(2.2, 4.5, 4.4),
			worldCF * CFrame.lookAt(upperCenter, upperCenter - dir2),
			isGhost
		)
		spawnPrim("Part", model, "TopExitPad", Vector3.new(1.8, 0.8, 1.4), worldCF * CFrame.new(0, 8.6, 3.3), isGhost)
		spawnPrim(
			"Part",
			model,
			"SupportPost",
			Vector3.new(0.6, 3.8, 0.6),
			worldCF * CFrame.new(2.3, 1.9, -1.65),
			isGhost
		)
	elseif canonical == "storage_box" then
		primaryLocalCF = CFrame.new(0, 1.2, 0)
		primaryPart =
			spawnPrim("Part", model, "ChestBody", Vector3.new(4.0, 2.4, 2.5), worldCF * primaryLocalCF, isGhost)
		spawnPrim("Part", model, "ChestLid", Vector3.new(4.2, 0.4, 2.7), worldCF * CFrame.new(0, 2.6, 0), isGhost)
	elseif canonical == "tool_cupboard" then
		primaryLocalCF = CFrame.new(0, 2.7, 0)
		primaryPart =
			spawnPrim("Part", model, "CabinetBody", Vector3.new(3.2, 5.4, 2.2), worldCF * primaryLocalCF, isGhost)
		spawnPrim(
			"Part",
			model,
			"CabinetDoor",
			Vector3.new(2.8, 4.8, 0.2),
			worldCF * CFrame.new(0, 2.6, -1.15),
			isGhost
		)
		spawnPrim("Part", model, "TopTrim", Vector3.new(3.5, 0.35, 2.5), worldCF * CFrame.new(0, 5.55, 0), isGhost)
		spawnPrim(
			"Part",
			model,
			"LockPlate",
			Vector3.new(0.5, 0.7, 0.25),
			worldCF * CFrame.new(1.0, 2.7, -1.25),
			isGhost
		)
	elseif canonical == "workbench_1" then
		primaryLocalCF = CFrame.new(0, 2.3, 0)
		primaryPart =
			spawnPrim("Part", model, "TableTop", Vector3.new(5.0, 0.6, 3.0), worldCF * primaryLocalCF, isGhost)
		spawnPrim("Part", model, "LeftLeg", Vector3.new(0.6, 2.0, 2.6), worldCF * CFrame.new(-2.0, 1.0, 0), isGhost)
		spawnPrim("Part", model, "RightLeg", Vector3.new(0.6, 2.0, 2.6), worldCF * CFrame.new(2.0, 1.0, 0), isGhost)
		if not isGhost then
			model:SetAttribute("StationType", "workbench_1")
		end
	elseif canonical == "workbench_2" then
		primaryLocalCF = CFrame.new(0, 2.4, 0)
		primaryPart =
			spawnPrim("Part", model, "TableTop", Vector3.new(5.4, 0.6, 3.2), worldCF * primaryLocalCF, isGhost)
		spawnPrim("Part", model, "LeftLeg", Vector3.new(0.7, 2.1, 2.8), worldCF * CFrame.new(-2.2, 1.05, 0), isGhost)
		spawnPrim("Part", model, "RightLeg", Vector3.new(0.7, 2.1, 2.8), worldCF * CFrame.new(2.2, 1.05, 0), isGhost)
		spawnPrim("Part", model, "BackPanel", Vector3.new(5.2, 2.2, 0.3), worldCF * CFrame.new(0, 3.8, 1.4), isGhost)
		spawnPrim("Part", model, "ToolRack", Vector3.new(4.6, 0.4, 0.5), worldCF * CFrame.new(0, 4.7, 1.15), isGhost)
		if not isGhost then
			model:SetAttribute("StationType", "workbench_2")
		end
	elseif canonical == "workbench_3" then
		primaryLocalCF = CFrame.new(0, 2.5, 0)
		primaryPart =
			spawnPrim("Part", model, "TableTop", Vector3.new(5.8, 0.7, 3.4), worldCF * primaryLocalCF, isGhost)
		spawnPrim("Part", model, "LeftLeg", Vector3.new(0.8, 2.2, 3.0), worldCF * CFrame.new(-2.35, 1.1, 0), isGhost)
		spawnPrim("Part", model, "RightLeg", Vector3.new(0.8, 2.2, 3.0), worldCF * CFrame.new(2.35, 1.1, 0), isGhost)
		spawnPrim("Part", model, "BackPanel", Vector3.new(5.6, 2.6, 0.35), worldCF * CFrame.new(0, 4.15, 1.45), isGhost)
		spawnPrim("Part", model, "TopLamp", Vector3.new(4.8, 0.35, 0.6), worldCF * CFrame.new(0, 5.55, 1.1), isGhost)
		if not isGhost then
			model:SetAttribute("StationType", "workbench_3")
		end
	elseif canonical == "assault_ladder" then
		primaryLocalCF = CFrame.new(-1.1, 5.0, 0)
		primaryPart =
			spawnPrim("Part", model, "LeftRail", Vector3.new(0.28, 10.0, 0.35), worldCF * primaryLocalCF, isGhost)
		spawnPrim("Part", model, "RightRail", Vector3.new(0.28, 10.0, 0.35), worldCF * CFrame.new(1.1, 5.0, 0), isGhost)
		for rungIdx = 1, 7 do
			local rungY = rungIdx * 1.25
			spawnPrim(
				"Part",
				model,
				string.format("Rung_%d", rungIdx),
				Vector3.new(2.0, 0.25, 0.3),
				worldCF * CFrame.new(0, rungY, 0),
				isGhost
			)
		end
	elseif canonical == "barricade" then
		primaryLocalCF = CFrame.new(0, 2.1, 0)
		primaryPart =
			spawnPrim("Part", model, "MainWall", Vector3.new(8.0, 4.2, 1.4), worldCF * primaryLocalCF, isGhost)
		spawnPrim("Part", model, "TopCap", Vector3.new(8.2, 0.4, 1.6), worldCF * CFrame.new(0, 4.3, 0), isGhost)
		spawnPrim(
			"WedgePart",
			model,
			"BraceLeft",
			Vector3.new(0.7, 3.2, 1.8),
			worldCF * CFrame.new(-2.8, 1.6, -1.5) * CFrame.Angles(0, math.rad(180), 0),
			isGhost
		)
		spawnPrim(
			"WedgePart",
			model,
			"BraceRight",
			Vector3.new(0.7, 3.2, 1.8),
			worldCF * CFrame.new(2.8, 1.6, -1.5) * CFrame.Angles(0, math.rad(180), 0),
			isGhost
		)
	end

	if primaryPart ~= nil then
		model.PrimaryPart = primaryPart
		primaryPart.PivotOffset = primaryLocalCF:Inverse()
	end
	return model
end

BuildingGeometry.CreatePieceModel = BuildingGeometry.CreateModel

function BuildingGeometry.ApplyTierVisuals(model: Model, pieceType: BuildPieceType, tier: BuildTier)
	local canonical = BuildingGeometry.CanonicalPieceType(pieceType)
	local tierCfg = BuildingConfig.Tiers[tier] or BuildingConfig.Tiers.wood
	for _, child in model:GetDescendants() do
		if child:IsA("BasePart") then
			if canonical == "storage_box" then
				child.Material = Enum.Material.Wood
				child.Color = if child.Name == "ChestLid"
					then Color3.fromRGB(95, 62, 32)
					else Color3.fromRGB(130, 88, 48)
			elseif canonical == "tool_cupboard" then
				if child.Name == "LockPlate" then
					child.Material = Enum.Material.Metal
					child.Color = Color3.fromRGB(205, 165, 70)
				elseif child.Name == "CabinetDoor" or child.Name == "TopTrim" then
					child.Material = Enum.Material.WoodPlanks
					child.Color = Color3.fromRGB(115, 78, 44)
				else
					child.Material = Enum.Material.WoodPlanks
					child.Color = Color3.fromRGB(148, 102, 58)
				end
			elseif canonical == "workbench_1" then
				child.Material = if child.Name == "TableTop" then Enum.Material.WoodPlanks else Enum.Material.Metal
				child.Color = if child.Name == "TableTop"
					then Color3.fromRGB(150, 105, 65)
					else Color3.fromRGB(70, 74, 80)
			elseif canonical == "workbench_2" then
				if child.Name == "ToolRack" then
					child.Material = Enum.Material.WoodPlanks
					child.Color = Color3.fromRGB(165, 118, 72)
				else
					child.Material = Enum.Material.Metal
					child.Color = if child.Name == "TableTop"
						then Color3.fromRGB(96, 112, 130)
						else Color3.fromRGB(62, 70, 80)
				end
			elseif canonical == "workbench_3" then
				if child.Name == "TopLamp" then
					child.Material = Enum.Material.Neon
					child.Color = Color3.fromRGB(80, 215, 255)
				else
					child.Material = Enum.Material.DiamondPlate
					child.Color = if child.Name == "TableTop"
						then Color3.fromRGB(68, 78, 92)
						else Color3.fromRGB(45, 52, 62)
				end
			elseif canonical == "assault_ladder" then
				child.Material = Enum.Material.WoodPlanks
				child.Color = if string.sub(child.Name, 1, 4) == "Rung"
					then Color3.fromRGB(185, 136, 84)
					else Color3.fromRGB(132, 92, 54)
			elseif canonical == "barricade" then
				if child.Name == "MainWall" or child.Name == "TopCap" then
					child.Material = Enum.Material.WoodPlanks
					child.Color = Color3.fromRGB(145, 108, 68)
				else
					child.Material = Enum.Material.Metal
					child.Color = Color3.fromRGB(86, 94, 102)
				end
			else
				child.Material = tierCfg.Material
				child.Color = tierCfg.Color
			end
		end
	end
end

function BuildingGeometry.SetGhostColor(model: Model, color: Color3)
	for _, child in model:GetDescendants() do
		if child:IsA("BasePart") then
			child.Color = color
			child.Transparency = 0.5
		end
	end
end

function BuildingGeometry.GetPieceSockets(pieceType: BuildPieceType): { BuildSocketDef }
	local cfg = BuildingConfig.Pieces[pieceType]
	if cfg == nil then
		return EMPTY_SOCKETS
	end
	if cfg.Category == "Foundation" then
		return if cfg.Shape == "Square" then SQUARE_FOUNDATION_SOCKETS else TRIANGLE_FOUNDATION_SOCKETS
	elseif cfg.Category == "Floor" then
		return if cfg.Shape == "Square" then SQUARE_FLOOR_SOCKETS else TRIANGLE_FLOOR_SOCKETS
	elseif cfg.Category == "Wall" then
		return WALL_SOCKETS
	end
	return EMPTY_SOCKETS
end

function BuildingGeometry.GetSocketById(pieceType: BuildPieceType, socketId: string): BuildSocketDef?
	for _, def in BuildingGeometry.GetPieceSockets(pieceType) do
		if def.Id == socketId then
			return def
		end
	end
	return nil
end

function BuildingGeometry.IsSocketCompatible(
	parentType: BuildPieceType,
	socket: BuildSocketDef,
	childType: BuildPieceType
): boolean
	local parentCfg = BuildingConfig.Pieces[parentType]
	local childCfg = BuildingConfig.Pieces[childType]
	local canonicalChild = BuildingGeometry.CanonicalPieceType(childType)
	if parentCfg == nil or childCfg == nil then
		return false
	end

	if socket.Kind == "Edge" then
		if parentCfg.Category == "Foundation" then
			return childCfg.Category == "Foundation" or childCfg.Category == "Wall"
		elseif parentCfg.Category == "Floor" then
			return childCfg.Category == "Floor" or childCfg.Category == "Wall"
		end
	elseif socket.Kind == "Top" then
		return (parentCfg.Shape == "Square" and canonicalChild == "roof")
			or (parentCfg.Shape == "Triangle" and canonicalChild == "triangle_floor")
	elseif socket.Kind == "WallTop" then
		return childCfg.Category == "Wall" or childCfg.Category == "Floor"
	elseif socket.Kind == "Center" then
		if canonicalChild == "square_stairs" then
			return parentCfg.Shape == "Square"
		elseif canonicalChild == "triangle_stairs" then
			return parentCfg.Shape == "Triangle"
		elseif childCfg.Category == "Deployable" then
			return parentCfg.Category == "Foundation" or parentCfg.Category == "Floor"
		end
	end
	return false
end

function BuildingGeometry.GetSocketSlotKey(socket: BuildSocketDef, childType: BuildPieceType, rotStep: number?): string
	local childCfg = BuildingConfig.Pieces[childType]
	if socket.Kind == "Edge" then
		return if childCfg ~= nil and childCfg.Category == "Wall" then socket.Id .. ":Wall" else socket.Id .. ":Surface"
	elseif socket.Kind == "Top" then
		return "Top:Floor"
	elseif socket.Kind == "Center" then
		return "Center:Interior"
	elseif socket.Kind == "WallTop" then
		if childCfg ~= nil and childCfg.Category == "Wall" then
			return "WallTop:Wall"
		end
		local side = (if typeof(rotStep) == "number" then math.floor(rotStep) else 0) % 2
		return string.format("WallTop:Floor_%d", side)
	end
	return socket.Id
end

function BuildingGeometry.ComputeSnappedCFrame(
	parentType: BuildPieceType,
	parentWorldCF: CFrame,
	socket: BuildSocketDef,
	childType: BuildPieceType,
	rotStep: number?
): CFrame
	local parentCfg = BuildingConfig.Pieces[parentType]
	local childCfg = BuildingConfig.Pieces[childType]
	local canonicalChild = BuildingGeometry.CanonicalPieceType(childType)
	local step = if typeof(rotStep) == "number" then math.floor(rotStep) else 0
	local socketWorldCF = parentWorldCF * socket.LocalCFrame
	if parentCfg == nil or childCfg == nil then
		return socketWorldCF
	end

	if socket.Kind == "Edge" then
		local wallYOffset = if parentCfg.Category == "Foundation" then FOUNDATION_THICKNESS else FLOOR_THICKNESS
		if childCfg.Category == "Wall" then
			return socketWorldCF * CFrame.new(0, wallYOffset, 0) * CFrame.Angles(0, math.rad((step % 2) * 180), 0)
		elseif childCfg.Shape == "Square" then
			return socketWorldCF * CFrame.new(0, 0, -GRID_SIZE * 0.5)
		elseif childCfg.Shape == "Triangle" then
			return socketWorldCF * CFrame.new(0, 0, -TRIANGLE_INRADIUS) * CFrame.Angles(0, math.rad(180), 0)
		end
	elseif socket.Kind == "Top" then
		return socketWorldCF
	elseif socket.Kind == "WallTop" then
		local sideFlip = (step % 2) * 180
		if childCfg.Category == "Wall" then
			return socketWorldCF * CFrame.new(0, FLOOR_THICKNESS, 0) * CFrame.Angles(0, math.rad(sideFlip), 0)
		elseif childCfg.Shape == "Square" then
			return socketWorldCF * CFrame.Angles(0, math.rad(sideFlip), 0) * CFrame.new(0, 0, -GRID_SIZE * 0.5)
		elseif childCfg.Shape == "Triangle" then
			return socketWorldCF
				* CFrame.Angles(0, math.rad(sideFlip), 0)
				* CFrame.new(0, 0, -TRIANGLE_INRADIUS)
				* CFrame.Angles(0, math.rad(180), 0)
		end
	elseif socket.Kind == "Center" then
		local deg = if canonicalChild == "triangle_stairs" then (step % 3) * 120 else (step % 4) * 90
		return socketWorldCF * CFrame.Angles(0, math.rad(deg), 0)
	end
	return socketWorldCF
end

function BuildingGeometry.InferRotStepFromCFrame(
	parentType: BuildPieceType,
	parentWorldCF: CFrame,
	socket: BuildSocketDef,
	childType: BuildPieceType,
	requestedCF: CFrame,
	explicitRotStep: number?
): number
	if typeof(explicitRotStep) == "number" then
		return math.floor(explicitRotStep)
	end
	local bestStep = 0
	local bestDist = math.huge
	local reqYaw = BuildingGeometry.ExtractYawDegrees(requestedCF)
	for step = 0, 11 do
		local cand = BuildingGeometry.ComputeSnappedCFrame(parentType, parentWorldCF, socket, childType, step)
		local posDist = (cand.Position - requestedCF.Position).Magnitude
		local candYaw = BuildingGeometry.ExtractYawDegrees(cand)
		local yawDiff = math.abs(((candYaw - reqYaw + 180) % 360) - 180)
		local score = posDist * 10 + yawDiff * 0.05
		if score < bestDist then
			bestDist = score
			bestStep = step
		end
	end
	return bestStep
end

function BuildingGeometry.DoesPieceOccupySocket(
	parentType: BuildPieceType,
	parentWorldCF: CFrame,
	socket: BuildSocketDef,
	pieceType: BuildPieceType,
	piecePos: Vector3,
	tolerance: number?,
	rotStep: number?
): boolean
	if not BuildingGeometry.IsSocketCompatible(parentType, socket, pieceType) then
		return false
	end
	local cfg = BuildingConfig.Pieces[pieceType]
	if cfg == nil then
		return false
	end

	local eps = tolerance or 0.5
	if socket.Kind == "WallTop" and cfg.Category == "Floor" then
		local startStep = if typeof(rotStep) == "number" then math.floor(rotStep) % 2 else 0
		local endStep = if typeof(rotStep) == "number" then startStep else 1
		for step = startStep, endStep do
			local expected = BuildingGeometry.ComputeSnappedCFrame(parentType, parentWorldCF, socket, pieceType, step)
			if (expected.Position - piecePos).Magnitude <= math.max(eps, 1.5) then
				return true
			end
		end
		return false
	end

	local expected = BuildingGeometry.ComputeSnappedCFrame(parentType, parentWorldCF, socket, pieceType, 0)
	local limit = if socket.Kind == "Top" or socket.Kind == "Center" then math.max(eps, 1.5) else eps
	return (expected.Position - piecePos).Magnitude <= limit
end

function BuildingGeometry.GetOverlapBoxes(
	pieceType: BuildPieceType,
	worldCF: CFrame,
	expandXZ: number?
): { BuildOverlapBox }
	local canonical = BuildingGeometry.CanonicalPieceType(pieceType)
	local shrink = BuildingConfig.OverlapShrinkFactor
	local extra = expandXZ or 0
	local hasExpand = expandXZ ~= nil and expandXZ > 0
	local boxes: { BuildOverlapBox } = {}

	if canonical == "foundation" or canonical == "roof" then
		local t = if canonical == "foundation" then FOUNDATION_THICKNESS else FLOOR_THICKNESS
		local baseXZ = if hasExpand then GRID_SIZE else GRID_SIZE * shrink
		table.insert(boxes, {
			CFrame = worldCF * CFrame.new(0, t * 0.5, 0),
			Size = Vector3.new(baseXZ + extra * 2, t * shrink, baseXZ + extra * 2),
		})
	elseif canonical == "triangle_foundation" or canonical == "triangle_floor" then
		local t = if canonical == "triangle_foundation" then FOUNDATION_THICKNESS else FLOOR_THICKNESS
		local w1 = if hasExpand then 7.2 else 6.2
		local d1 = if hasExpand then 3.2 else 2.6
		local w2 = if hasExpand then 3.4 else 2.4
		local d2 = if hasExpand then 3.8 else 3.3
		table.insert(boxes, {
			CFrame = worldCF * CFrame.new(0, t * 0.5, -1.4),
			Size = Vector3.new(w1 + extra * 2, t * shrink, d1 + extra * 2),
		})
		table.insert(boxes, {
			CFrame = worldCF * CFrame.new(0, t * 0.5, 1.55),
			Size = Vector3.new(w2 + extra * 2, t * shrink, d2 + extra * 2),
		})
	elseif canonical == "wall" or canonical == "doorway" or canonical == "window_wall" then
		table.insert(boxes, {
			CFrame = worldCF * CFrame.new(0, WALL_BODY_HEIGHT * 0.5, 0),
			Size = Vector3.new(GRID_SIZE * shrink, WALL_BODY_HEIGHT * shrink, WALL_THICKNESS * shrink),
		})
	elseif canonical == "square_stairs" then
		table.insert(boxes, {
			CFrame = worldCF * CFrame.new(0, WALL_BODY_HEIGHT * 0.5, 0),
			Size = Vector3.new(9.2, WALL_BODY_HEIGHT * shrink, 9.2),
		})
	elseif canonical == "triangle_stairs" then
		table.insert(boxes, {
			CFrame = worldCF * CFrame.new(0, WALL_BODY_HEIGHT * 0.5, -1.3),
			Size = Vector3.new(6.2, WALL_BODY_HEIGHT * shrink, 2.4),
		})
		table.insert(boxes, {
			CFrame = worldCF * CFrame.new(0, WALL_BODY_HEIGHT * 0.5, 1.8),
			Size = Vector3.new(2.6, WALL_BODY_HEIGHT * shrink, 3.0),
		})
	elseif canonical == "storage_box" then
		table.insert(boxes, { CFrame = worldCF * CFrame.new(0, 1.4, 0), Size = Vector3.new(3.4, 2.2, 2.1) })
	elseif canonical == "tool_cupboard" then
		table.insert(boxes, { CFrame = worldCF * CFrame.new(0, 2.75, 0), Size = Vector3.new(2.8, 5.0, 2.0) })
	elseif canonical == "workbench_1" then
		table.insert(boxes, { CFrame = worldCF * CFrame.new(0, 1.3, 0), Size = Vector3.new(4.2, 2.2, 2.5) })
	elseif canonical == "workbench_2" then
		table.insert(boxes, { CFrame = worldCF * CFrame.new(0, 1.8, 0), Size = Vector3.new(4.6, 3.2, 2.7) })
	elseif canonical == "workbench_3" then
		table.insert(boxes, { CFrame = worldCF * CFrame.new(0, 2.0, 0), Size = Vector3.new(5.0, 3.6, 2.9) })
	elseif canonical == "assault_ladder" then
		table.insert(boxes, { CFrame = worldCF * CFrame.new(0, 4.8, 0), Size = Vector3.new(2.6, 9.2, 1.2) })
	elseif canonical == "barricade" then
		table.insert(boxes, { CFrame = worldCF * CFrame.new(0, 2.0, 0), Size = Vector3.new(7.4, 3.8, 1.8) })
	end
	return boxes
end

local function pointToSegmentDistXZ(point: Vector3, segCenter: Vector3, segRightUnit: Vector3, halfLen: number): number
	local dx = point.X - segCenter.X
	local dz = point.Z - segCenter.Z
	local proj = math.clamp(dx * segRightUnit.X + dz * segRightUnit.Z, -halfLen, halfLen)
	local rx = point.X - (segCenter.X + segRightUnit.X * proj)
	local rz = point.Z - (segCenter.Z + segRightUnit.Z * proj)
	return math.sqrt(rx * rx + rz * rz)
end

function BuildingGeometry.CheckParallelWallStacking(
	targetType: BuildPieceType,
	targetCF: CFrame,
	existingPieces: { ParallelWallCandidate }
): (boolean, string?)
	local targetCfg = BuildingConfig.Pieces[targetType]
	if targetCfg == nil or targetCfg.Category ~= "Wall" then
		return true, nil
	end

	local targetPos = targetCF.Position
	local targetRight = Vector3.new(targetCF.RightVector.X, 0, targetCF.RightVector.Z)
	local targetLook = Vector3.new(targetCF.LookVector.X, 0, targetCF.LookVector.Z)
	if targetRight.Magnitude < 0.01 or targetLook.Magnitude < 0.01 then
		return true, nil
	end
	targetRight = targetRight.Unit
	targetLook = targetLook.Unit

	local minParallelDist = BuildingConfig.MinParallelWallDistance
	local searchRadius = BuildingConfig.ParallelWallSearchRadius
	local halfWall = GRID_SIZE * 0.5

	for _, candidate in existingPieces do
		local cfg = BuildingConfig.Pieces[candidate.PieceType]
		if cfg ~= nil and cfg.Category == "Wall" then
			local otherPos = candidate.CFrame.Position
			if math.abs(otherPos.Y - targetPos.Y) < (WALL_HEIGHT - 1.0) then
				local otherRight = Vector3.new(candidate.CFrame.RightVector.X, 0, candidate.CFrame.RightVector.Z)
				local otherLook = Vector3.new(candidate.CFrame.LookVector.X, 0, candidate.CFrame.LookVector.Z)
				if otherRight.Magnitude >= 0.01 and otherLook.Magnitude >= 0.01 then
					otherRight = otherRight.Unit
					otherLook = otherLook.Unit

					local minMidSeg = math.min(
						pointToSegmentDistXZ(targetPos, otherPos, otherRight, halfWall),
						pointToSegmentDistXZ(otherPos, targetPos, targetRight, halfWall)
					)
					if minMidSeg < minParallelDist then
						return false,
							if minMidSeg < 0.5
								then "Wall already exists on this edge"
								else "Too close to existing wall (anti-stacking)"
					end

					if math.abs(targetLook:Dot(otherLook)) >= COS_15_DEG then
						local flatDelta = Vector3.new(otherPos.X - targetPos.X, 0, otherPos.Z - targetPos.Z)
						local alongDist = math.abs(flatDelta:Dot(targetRight))
						local perpDist = math.abs(flatDelta:Dot(targetLook))
						if
							(flatDelta.Magnitude <= searchRadius or alongDist < (GRID_SIZE - 0.8))
							and perpDist < minParallelDist
						then
							return false, "Too close to parallel wall (anti-stacking)"
						end
					end
				end
			end
		end
	end
	return true, nil
end

function BuildingGeometry.IsNoBuildInstance(inst: Instance, allowRaidOutpostZone: boolean?): boolean
	local current: Instance? = inst
	while current ~= nil and current ~= Workspace do
		local isOutpostZone = current.Name == "RaidOutpostZone" or CollectionService:HasTag(current, "RaidOutpostZone")
		if
			CollectionService:HasTag(current, "NoBuild")
			or CollectionService:HasTag(current, "Monument")
			or current:GetAttribute("NoBuild") == true
			or (
				current.Parent == Workspace
				and table.find(NO_BUILD_FOLDERS, current.Name) ~= nil
				and not (allowRaidOutpostZone == true and isOutpostZone)
			)
		then
			return true
		end
		current = current.Parent
	end
	return false
end

local function isStructureOrCharacterPart(inst: Instance): (boolean, boolean)
	local pFolder = Workspace:FindFirstChild("PlayerBaseStructures")
	local rFolder = Workspace:FindFirstChild("RaidTargetStructures")
	local oFolder = Workspace:FindFirstChild("RaidOutpostStructures")
	if
		(pFolder and inst:IsDescendantOf(pFolder))
		or (rFolder and inst:IsDescendantOf(rFolder))
		or (oFolder and inst:IsDescendantOf(oFolder))
	then
		return true, false
	end
	local cur: Instance? = inst
	while cur ~= nil and cur ~= Workspace do
		if cur:IsA("Model") and cur:FindFirstChildOfClass("Humanoid") ~= nil then
			return false, true
		end
		cur = cur.Parent
	end
	return false, false
end

local function isPointInsideBox(point: Vector3, boxCF: CFrame, boxSize: Vector3): boolean
	local localPos = boxCF:PointToObjectSpace(point)
	local half = boxSize * 0.5
	return math.abs(localPos.X) <= half.X and math.abs(localPos.Y) <= half.Y and math.abs(localPos.Z) <= half.Z
end

local function checkNoBuildVolumes(boxes: { BuildOverlapBox }, allowRaidOutpostZone: boolean?): boolean
	for _, folderName in NO_BUILD_FOLDERS do
		if allowRaidOutpostZone == true and folderName == "RaidOutpostZone" then
			continue
		end
		local inst = Workspace:FindFirstChild(folderName)
		if inst ~= nil then
			local parts = if inst:IsA("BasePart") then { inst } else inst:GetDescendants()
			for _, desc in parts do
				if desc:IsA("BasePart") then
					for _, box in boxes do
						if isPointInsideBox(box.CFrame.Position, desc.CFrame, desc.Size + box.Size) then
							return true
						end
					end
				end
			end
		end
	end
	return false
end

local function filterExactWedgeHits(box: BuildOverlapBox, rawParts: { BasePart }): { BasePart }
	local result: { BasePart } = {}
	local wedges: { Instance } = {}
	for _, part in rawParts do
		if part:IsA("WedgePart") then
			table.insert(wedges, part)
		else
			table.insert(result, part)
		end
	end
	if #wedges == 0 then
		return result
	end
	local probe = Instance.new("Part")
	probe.Anchored = true
	probe.CanCollide = false
	probe.CanQuery = false
	probe.CanTouch = false
	probe.Transparency = 1
	probe.Size = box.Size
	probe.CFrame = box.CFrame
	probe.Parent = Workspace
	local wParams = OverlapParams.new()
	wParams.FilterType = Enum.RaycastFilterType.Include
	wParams.FilterDescendantsInstances = wedges
	local ok, hits = pcall(function()
		return Workspace:GetPartsInPart(probe, wParams)
	end)
	probe:Destroy()
	if ok and type(hits) == "table" then
		for _, w in hits do
			table.insert(result, w)
		end
	end
	return result
end

function BuildingGeometry.CheckWorldOverlap(
	pieceType: BuildPieceType,
	targetCF: CFrame,
	excludeInstances: { Instance }?,
	isDetachedFoundation: boolean,
	allowRaidOutpostZone: boolean?
): OverlapCheckResult
	local cfg = BuildingConfig.Pieces[pieceType]
	if cfg == nil then
		return { Allowed = false, Reason = "Unknown building piece" }
	end

	local boxes = BuildingGeometry.GetOverlapBoxes(pieceType, targetCF, nil)
	if checkNoBuildVolumes(boxes, allowRaidOutpostZone) then
		return { Allowed = false, Reason = "Blocked by restricted zone" }
	end

	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = excludeInstances or {}

	for _, box in boxes do
		local parts = filterExactWedgeHits(box, Workspace:GetPartBoundsInBox(box.CFrame, box.Size, params))
		for _, part in parts do
			if BuildingGeometry.IsNoBuildInstance(part, allowRaidOutpostZone) then
				return { Allowed = false, Reason = "Blocked by restricted zone" }
			end
			local isStruct, isChar = isStructureOrCharacterPart(part)
			if isStruct then
				return { Allowed = false, Reason = "Overlaps existing structure" }
			elseif isChar then
				return { Allowed = false, Reason = "Blocked by player" }
			elseif
				part.CanCollide
				and not part:IsA("Terrain")
				and part.Name ~= "Baseplate"
				and part.Name ~= "Ground"
			then
				if
					(cfg.Category ~= "Foundation" and not cfg.AssaultDeployable)
					or (part.Position.Y + part.Size.Y * 0.5) > (targetCF.Position.Y + 0.35)
				then
					return { Allowed = false, Reason = "Blocked by obstacle" }
				end
			end
		end
	end

	if isDetachedFoundation and cfg.Category == "Foundation" then
		for _, box in BuildingGeometry.GetOverlapBoxes(pieceType, targetCF, BuildingConfig.FreeFoundationSpacing) do
			local tallBox: BuildOverlapBox =
				{ CFrame = box.CFrame * CFrame.new(0, 2.0, 0), Size = Vector3.new(box.Size.X, 8.0, box.Size.Z) }
			for _, part in
				filterExactWedgeHits(tallBox, Workspace:GetPartBoundsInBox(tallBox.CFrame, tallBox.Size, params))
			do
				local isStruct = isStructureOrCharacterPart(part)
				if isStruct then
					return { Allowed = false, Reason = "Too close to existing base (use sockets)" }
				end
			end
		end
	end

	return { Allowed = true, Reason = nil }
end

return BuildingGeometry
