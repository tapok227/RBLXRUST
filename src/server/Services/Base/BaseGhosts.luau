--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)
local Janitor = require(ReplicatedStorage.Shared.Janitor)
local BuildingValidator = require(ServerScriptService.Server.Services.BuildingValidator)
local DataService = require(ServerScriptService.Server.Services.DataService)

local GHOSTS_FOLDER_NAME = "SessionDeathGhosts"

local sessionGhostsJanitors: { [Player]: Janitor.Janitor } = {}

local BaseGhosts = {}

local function getOrCreateGhostsFolder(): Folder
	local existing = Workspace:FindFirstChild(GHOSTS_FOLDER_NAME)
	if existing and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = GHOSTS_FOLDER_NAME
	folder.Parent = Workspace
	return folder
end

local function createGhostPrimitive(
	parent: Instance,
	name: string,
	size: Vector3,
	cf: CFrame,
	material: Enum.Material,
	color: Color3,
	transparency: number,
	shape: Enum.PartType?
): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = cf
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = material
	part.Color = color
	part.Transparency = transparency
	if shape ~= nil then
		part.Shape = shape
	end
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

function BaseGhosts.ClearSessionGhosts(player: Player)
	local janitor = sessionGhostsJanitors[player]
	if janitor ~= nil then
		janitor:Destroy()
		sessionGhostsJanitors[player] = nil
	end
end

function BaseGhosts.SpawnSessionDeathGhosts(player: Player): number
	local data = DataService.GetData(player)
	if data == nil or type(data.DefenseLogs) ~= "table" then
		return 0
	end

	local janitor = sessionGhostsJanitors[player]
	local ghostsFolder = getOrCreateGhostsFolder()
	local spawnedCount = 0
	local outpostOrigin = Vector3.new(0, 0, Config.Raid.OutpostOffsetZ)

	for _, logEntry in data.DefenseLogs do
		if not logEntry.GhostsShown then
			logEntry.GhostsShown = true
			for idx, point in logEntry.DeathPoints do
				local worldPos = Vector3.new(point.PosX, point.PosY, point.PosZ)
				local isRouteGhost = point.Cause == "Extraction Route"
				if
					isRouteGhost
					or not BuildingValidator.IsPointInRaidOutpostOrBuffer(
						worldPos,
						Config.Raid.OutpostGhostBufferMargin,
						outpostOrigin
					)
				then
					if janitor == nil then
						janitor = Janitor.new()
						sessionGhostsJanitors[player] = janitor
					end

					local ghostModel = Instance.new("Model")
					ghostModel.Name = string.format(
						"%s_%d_%d",
						if isRouteGhost then "RouteGhost" else "DeathGhost",
						player.UserId,
						idx
					)

					createGhostPrimitive(
						ghostModel,
						"MarkerRing",
						Vector3.new(2.6, 0.2, 2.6),
						CFrame.new(worldPos + Vector3.new(0, 0.12, 0)),
						Enum.Material.Neon,
						if isRouteGhost then Color3.fromRGB(255, 195, 45) else Color3.fromRGB(255, 85, 85),
						0.35,
						nil
					)
					local body = createGhostPrimitive(
						ghostModel,
						"GhostBody",
						Vector3.new(1.5, 3.4, 1.0),
						CFrame.new(worldPos + Vector3.new(0, 2.0, 0)),
						Enum.Material.ForceField,
						if isRouteGhost then Color3.fromRGB(255, 220, 105) else Color3.fromRGB(110, 225, 255),
						0.3,
						nil
					)
					local head = createGhostPrimitive(
						ghostModel,
						"GhostHead",
						Vector3.new(1.3, 1.3, 1.3),
						CFrame.new(worldPos + Vector3.new(0, 4.5, 0)),
						Enum.Material.ForceField,
						if isRouteGhost then Color3.fromRGB(255, 175, 55) else Color3.fromRGB(255, 115, 125),
						0.2,
						Enum.PartType.Ball
					)
					ghostModel.PrimaryPart = body

					local bb = Instance.new("BillboardGui")
					bb.Name = "DeathGhostInfo"
					bb.Adornee = head
					bb.Size = UDim2.fromOffset(220, 48)
					bb.StudsOffset = Vector3.new(0, 1.8, 0)
					bb.AlwaysOnTop = false
					bb.MaxDistance = 80
					bb.Parent = head

					local bg = Instance.new("Frame")
					bg.Size = UDim2.fromScale(1, 1)
					bg.BackgroundColor3 = Color3.fromRGB(18, 22, 30)
					bg.BackgroundTransparency = 0.25
					bg.BorderSizePixel = 0
					bg.Parent = bb

					local bgCorner = Instance.new("UICorner")
					bgCorner.CornerRadius = UDim.new(0, 6)
					bgCorner.Parent = bg

					local nameLbl = Instance.new("TextLabel")
					nameLbl.Name = "RaiderNameLabel"
					nameLbl.Position = UDim2.fromOffset(6, 3)
					nameLbl.Size = UDim2.new(1, -12, 0, 20)
					nameLbl.BackgroundTransparency = 1
					nameLbl.Font = Enum.Font.GothamBold
					nameLbl.TextSize = 12
					nameLbl.TextColor3 = Color3.fromRGB(255, 235, 235)
					nameLbl.Text = point.RaiderName
					nameLbl.Parent = bg

					local causeLbl = Instance.new("TextLabel")
					causeLbl.Name = "DeathCauseLabel"
					causeLbl.Position = UDim2.fromOffset(6, 23)
					causeLbl.Size = UDim2.new(1, -12, 0, 20)
					causeLbl.BackgroundTransparency = 1
					causeLbl.Font = Enum.Font.Gotham
					causeLbl.TextSize = 11
					causeLbl.TextColor3 = if isRouteGhost
						then Color3.fromRGB(255, 215, 115)
						else Color3.fromRGB(255, 145, 145)
					causeLbl.Text = point.Cause
					causeLbl.Parent = bg

					ghostModel.Parent = ghostsFolder;
					(janitor :: Janitor.Janitor):Add(ghostModel)
					spawnedCount += 1
				end
			end
		end
	end

	return spawnedCount
end

return BaseGhosts
