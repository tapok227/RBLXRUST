--!strict
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)
local Types = require(ReplicatedStorage.Shared.Types)
local Items = require(ReplicatedStorage.Shared.configs.Items)
local Vendors = require(ReplicatedStorage.Shared.configs.Vendors)
local Net = require(ReplicatedStorage.Shared.Net)
local BaseService = require(ServerScriptService.Server.Services.BaseService)
local BlueprintService = require(ServerScriptService.Server.Services.BlueprintService)
local DataService = require(ServerScriptService.Server.Services.DataService)
local InventoryService = require(ServerScriptService.Server.Services.InventoryService)
local RecyclerService = require(ServerScriptService.Server.Services.RecyclerService)
local SecurityService = require(ServerScriptService.Server.Services.SecurityService)

type VendorId = Types.VendorId
type VendorOffer = Types.VendorOffer
type VendorConfig = Types.VendorConfig
type VendorTradeFeedback = Types.VendorTradeFeedback
type Ingredient = Types.Ingredient

type RegisteredNpc = {
	Key: string,
	VendorId: VendorId,
	Position: Vector3,
	Model: Model,
}

local dynamicHubModel: Model? = nil
local registeredNpcs: { [string]: RegisteredNpc } = {}
local isInitialized = false

local VendorService = {}

local function createPart(
	parent: Instance,
	name: string,
	size: Vector3,
	cf: CFrame,
	material: Enum.Material,
	color: Color3,
	canCollide: boolean
): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = cf
	part.Anchored = true
	part.CanCollide = canCollide
	part.CanQuery = true
	part.CanTouch = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Material = material
	part.Color = color
	part.Parent = parent
	return part
end

local function createWedge(
	parent: Instance,
	name: string,
	size: Vector3,
	cf: CFrame,
	material: Enum.Material,
	color: Color3,
	canCollide: boolean
): WedgePart
	local wedge = Instance.new("WedgePart")
	wedge.Name = name
	wedge.Size = size
	wedge.CFrame = cf
	wedge.Anchored = true
	wedge.CanCollide = canCollide
	wedge.CanQuery = true
	wedge.CanTouch = false
	wedge.TopSurface = Enum.SurfaceType.Smooth
	wedge.BottomSurface = Enum.SurfaceType.Smooth
	wedge.Material = material
	wedge.Color = color
	wedge.Parent = parent
	return wedge
end

local function createSignBoard(parent: Instance, name: string, cf: CFrame, text: string, accent: Color3)
	local signModel = Instance.new("Model")
	signModel.Name = name
	signModel.Parent = parent

	createPart(
		signModel,
		"PostLeft",
		Vector3.new(0.45, 7.0, 0.45),
		cf * CFrame.new(-4.8, 3.5, 0),
		Enum.Material.Metal,
		Color3.fromRGB(58, 62, 70),
		true
	)
	createPart(
		signModel,
		"PostRight",
		Vector3.new(0.45, 7.0, 0.45),
		cf * CFrame.new(4.8, 3.5, 0),
		Enum.Material.Metal,
		Color3.fromRGB(58, 62, 70),
		true
	)
	local board = createPart(
		signModel,
		"Board",
		Vector3.new(10.6, 2.8, 0.4),
		cf * CFrame.new(0, 6.2, 0),
		Enum.Material.SmoothPlastic,
		Color3.fromRGB(28, 30, 38),
		true
	)
	createPart(
		signModel,
		"Trim",
		Vector3.new(10.8, 0.3, 0.46),
		cf * CFrame.new(0, 7.65, 0),
		Enum.Material.Neon,
		accent,
		false
	)

	for _, face in { Enum.NormalId.Front, Enum.NormalId.Back } do
		local sg = Instance.new("SurfaceGui")
		sg.Face = face
		sg.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
		sg.PixelsPerStud = 36
		sg.Parent = board

		local label = Instance.new("TextLabel")
		label.Size = UDim2.fromScale(1, 1)
		label.BackgroundTransparency = 1
		label.Font = Enum.Font.GothamBold
		label.TextScaled = true
		label.TextColor3 = Color3.fromRGB(242, 244, 250)
		label.Text = text
		label.Parent = sg
	end
end

local function sendFeedback(player: Player, success: boolean, message: string, vendorId: string?, offerId: string?)
	if player.Parent ~= Players then
		return
	end
	local payload: VendorTradeFeedback = {
		Success = success,
		Message = message,
		VendorId = vendorId,
		OfferId = offerId,
	}
	Net.GetEvent(Net.Events.VendorTradeFeedback):FireClient(player, payload)
end

local function isRaidBlocked(player: Player): boolean
	if Workspace:GetAttribute("RaidServerMode") == true then
		return true
	end
	if player:GetAttribute("InRaid") == true then
		return true
	end
	return false
end

local function registerNpcModel(key: string, vendorId: VendorId, model: Model)
	local primary = model.PrimaryPart
	if not primary then
		return
	end

	registeredNpcs[key] = {
		Key = key,
		VendorId = vendorId,
		Position = primary.Position,
		Model = model,
	}

	local vendorCfg = Vendors.Get(vendorId)
	local prompt = primary:FindFirstChild("VendorPrompt")
	if not (prompt and prompt:IsA("ProximityPrompt")) then
		local existingPrompt = model:FindFirstChildWhichIsA("ProximityPrompt", true)
		if existingPrompt then
			prompt = existingPrompt
		else
			local newPrompt = Instance.new("ProximityPrompt")
			newPrompt.Name = "VendorPrompt"
			newPrompt.ActionText = "Trade"
			newPrompt.ObjectText = if vendorCfg then vendorCfg.Name else vendorId
			newPrompt.HoldDuration = 0
			newPrompt.MaxActivationDistance = 10
			newPrompt.RequiresLineOfSight = false
			newPrompt.Parent = primary
			prompt = newPrompt
		end
	end

	if prompt and prompt:IsA("ProximityPrompt") and prompt:GetAttribute("VendorPromptBound") ~= true then
		prompt:SetAttribute("VendorPromptBound", true)
		prompt.Triggered:Connect(function(triggerPlayer: Player)
			if isRaidBlocked(triggerPlayer) then
				return
			end
			if DataService.IsTeleporting(triggerPlayer) or SecurityService.IsTeleportLocked(triggerPlayer) then
				return
			end
			local maxDist = Config.VendorHub.InteractDistance + Types.PING_DISTANCE_TOLERANCE
			if not SecurityService.IsWithinDistance(triggerPlayer, primary.Position, maxDist) then
				return
			end
			Net.GetEvent(Net.Events.VendorOpen):FireClient(triggerPlayer, vendorId, primary.Position)
		end)
	end
end

local function buildVendorNpc(vendorCfg: VendorConfig, stallCF: CFrame, parent: Instance): Model
	local npcModel = Instance.new("Model")
	npcModel.Name = string.format("Vendor_%s", vendorCfg.Id)
	npcModel:SetAttribute("VendorId", vendorCfg.Id)
	npcModel:SetAttribute("NoBuild", true)

	createPart(
		npcModel,
		"FloorTile",
		Vector3.new(8.2, 0.3, 6.4),
		stallCF * CFrame.new(0, 0.15, 0),
		Enum.Material.Slate,
		Color3.fromRGB(54, 58, 66),
		true
	)

	local counter = createPart(
		npcModel,
		"Counter",
		Vector3.new(7.4, 3.2, 2.2),
		stallCF * CFrame.new(0, 1.9, 1.4),
		Enum.Material.WoodPlanks,
		Color3.fromRGB(115, 86, 58),
		true
	)
	npcModel.PrimaryPart = counter

	createPart(
		npcModel,
		"AccentTrim",
		Vector3.new(7.6, 0.3, 2.4),
		stallCF * CFrame.new(0, 3.45, 1.4),
		Enum.Material.Neon,
		vendorCfg.AccentColor,
		false
	)

	-- Canopy frame (Part + WedgePart only)
	createPart(
		npcModel,
		"PostBackLeft",
		Vector3.new(0.45, 7.6, 0.45),
		stallCF * CFrame.new(-3.4, 4.1, -2.4),
		Enum.Material.Metal,
		Color3.fromRGB(64, 68, 76),
		true
	)
	createPart(
		npcModel,
		"PostBackRight",
		Vector3.new(0.45, 7.6, 0.45),
		stallCF * CFrame.new(3.4, 4.1, -2.4),
		Enum.Material.Metal,
		Color3.fromRGB(64, 68, 76),
		true
	)
	createPart(
		npcModel,
		"PostFrontLeft",
		Vector3.new(0.4, 7.0, 0.4),
		stallCF * CFrame.new(-3.4, 3.8, 2.4),
		Enum.Material.Metal,
		Color3.fromRGB(64, 68, 76),
		true
	)
	createPart(
		npcModel,
		"PostFrontRight",
		Vector3.new(0.4, 7.0, 0.4),
		stallCF * CFrame.new(3.4, 3.8, 2.4),
		Enum.Material.Metal,
		Color3.fromRGB(64, 68, 76),
		true
	)
	createWedge(
		npcModel,
		"Canopy",
		Vector3.new(7.8, 1.3, 5.6),
		stallCF * CFrame.new(0, 8.0, 0) * CFrame.Angles(0, math.rad(180), 0),
		Enum.Material.SmoothPlastic,
		vendorCfg.AccentColor,
		true
	)

	-- Primitive blocky NPC behind counter
	createPart(
		npcModel,
		"LeftLeg",
		Vector3.new(0.85, 2.0, 0.85),
		stallCF * CFrame.new(-0.5, 1.3, -0.7),
		Enum.Material.SmoothPlastic,
		Color3.fromRGB(48, 52, 62),
		true
	)
	createPart(
		npcModel,
		"RightLeg",
		Vector3.new(0.85, 2.0, 0.85),
		stallCF * CFrame.new(0.5, 1.3, -0.7),
		Enum.Material.SmoothPlastic,
		Color3.fromRGB(48, 52, 62),
		true
	)
	createPart(
		npcModel,
		"Torso",
		Vector3.new(2.0, 2.0, 1.0),
		stallCF * CFrame.new(0, 3.3, -0.7),
		Enum.Material.SmoothPlastic,
		vendorCfg.AccentColor,
		true
	)
	createPart(
		npcModel,
		"LeftArm",
		Vector3.new(0.75, 1.85, 0.75),
		stallCF * CFrame.new(-1.42, 3.35, -0.7),
		Enum.Material.SmoothPlastic,
		Color3.fromRGB(224, 184, 148),
		true
	)
	createPart(
		npcModel,
		"RightArm",
		Vector3.new(0.75, 1.85, 0.75),
		stallCF * CFrame.new(1.42, 3.35, -0.7),
		Enum.Material.SmoothPlastic,
		Color3.fromRGB(224, 184, 148),
		true
	)
	local head = createPart(
		npcModel,
		"Head",
		Vector3.new(1.2, 1.2, 1.2),
		stallCF * CFrame.new(0, 4.95, -0.7),
		Enum.Material.SmoothPlastic,
		Color3.fromRGB(232, 192, 156),
		true
	)

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "VendorLabel"
	billboard.Adornee = head
	billboard.Size = UDim2.fromOffset(180, 46)
	billboard.StudsOffset = Vector3.new(0, 2.2, 0)
	billboard.MaxDistance = 48
	billboard.AlwaysOnTop = false
	billboard.Parent = head

	local bg = Instance.new("Frame")
	bg.Size = UDim2.fromScale(1, 1)
	bg.BackgroundColor3 = Color3.fromRGB(20, 22, 28)
	bg.BackgroundTransparency = 0.2
	bg.BorderSizePixel = 0
	bg.Parent = billboard

	local bgCorner = Instance.new("UICorner")
	bgCorner.CornerRadius = UDim.new(0, 6)
	bgCorner.Parent = bg

	local nameLbl = Instance.new("TextLabel")
	nameLbl.Position = UDim2.fromOffset(6, 3)
	nameLbl.Size = UDim2.new(1, -12, 0, 20)
	nameLbl.BackgroundTransparency = 1
	nameLbl.Font = Enum.Font.GothamBold
	nameLbl.TextSize = 14
	nameLbl.TextColor3 = Color3.fromRGB(245, 245, 250)
	nameLbl.Text = vendorCfg.Name
	nameLbl.Parent = bg

	local roleLbl = Instance.new("TextLabel")
	roleLbl.Position = UDim2.fromOffset(6, 23)
	roleLbl.Size = UDim2.new(1, -12, 0, 18)
	roleLbl.BackgroundTransparency = 1
	roleLbl.Font = Enum.Font.GothamMedium
	roleLbl.TextSize = 11
	roleLbl.TextColor3 = vendorCfg.AccentColor
	roleLbl.Text = vendorCfg.RoleTitle
	roleLbl.Parent = bg

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "VendorPrompt"
	prompt.ActionText = "Trade"
	prompt.ObjectText = vendorCfg.Name
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 10
	prompt.RequiresLineOfSight = false
	prompt.Parent = counter

	npcModel.Parent = parent
	return npcModel
end

local function createStationLabel(adornee: BasePart, titleText: string, subText: string, accent: Color3)
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "StationLabel"
	billboard.Adornee = adornee
	billboard.Size = UDim2.fromOffset(180, 44)
	billboard.StudsOffset = Vector3.new(0, 2.5, 0)
	billboard.MaxDistance = 48
	billboard.AlwaysOnTop = false
	billboard.Parent = adornee

	local bg = Instance.new("Frame")
	bg.Size = UDim2.fromScale(1, 1)
	bg.BackgroundColor3 = Color3.fromRGB(20, 22, 28)
	bg.BackgroundTransparency = 0.2
	bg.BorderSizePixel = 0
	bg.Parent = billboard

	local bgCorner = Instance.new("UICorner")
	bgCorner.CornerRadius = UDim.new(0, 6)
	bgCorner.Parent = bg

	local titleLbl = Instance.new("TextLabel")
	titleLbl.Position = UDim2.fromOffset(6, 3)
	titleLbl.Size = UDim2.new(1, -12, 0, 19)
	titleLbl.BackgroundTransparency = 1
	titleLbl.Font = Enum.Font.GothamBold
	titleLbl.TextSize = 13
	titleLbl.TextColor3 = Color3.fromRGB(245, 245, 250)
	titleLbl.Text = titleText
	titleLbl.Parent = bg

	local subLbl = Instance.new("TextLabel")
	subLbl.Position = UDim2.fromOffset(6, 22)
	subLbl.Size = UDim2.new(1, -12, 0, 18)
	subLbl.BackgroundTransparency = 1
	subLbl.Font = Enum.Font.GothamMedium
	subLbl.TextSize = 11
	subLbl.TextColor3 = accent
	subLbl.Text = subText
	subLbl.Parent = bg
end

local function buildSafeRecyclerModel(cf: CFrame, parent: Instance): Model
	local model = Instance.new("Model")
	model.Name = "SafeRecycler"
	model:SetAttribute("IsRecycler", true)
	model:SetAttribute("StationType", "recycler")
	model:SetAttribute("RecyclerId", "base_safe_recycler")
	model:SetAttribute("RecyclerName", "Safe Recycler (40% Yield)")
	model:SetAttribute("EfficiencyMultiplier", Config.Recycler.SafeEfficiency)
	model:SetAttribute("NoBuild", true)

	createPart(
		model,
		"BaseFrame",
		Vector3.new(4.8, 0.4, 3.6),
		cf * CFrame.new(0, 0.2, 0),
		Enum.Material.DiamondPlate,
		Color3.fromRGB(54, 60, 68),
		true
	)
	local body = createPart(
		model,
		"Body",
		Vector3.new(4.2, 2.4, 3.0),
		cf * CFrame.new(0, 1.6, 0),
		Enum.Material.Metal,
		Color3.fromRGB(78, 108, 134),
		true
	)
	model.PrimaryPart = body

	createPart(
		model,
		"Hopper",
		Vector3.new(2.8, 0.9, 2.2),
		cf * CFrame.new(-0.4, 3.25, 0),
		Enum.Material.Metal,
		Color3.fromRGB(98, 134, 165),
		true
	)
	createPart(
		model,
		"GrinderDrum",
		Vector3.new(1.8, 0.6, 1.6),
		cf * CFrame.new(-0.4, 2.9, 0),
		Enum.Material.DiamondPlate,
		Color3.fromRGB(45, 48, 54),
		true
	)
	createPart(
		model,
		"OutputChute",
		Vector3.new(1.1, 0.9, 1.4),
		cf * CFrame.new(1.9, 1.4, 0),
		Enum.Material.Metal,
		Color3.fromRGB(62, 68, 76),
		true
	)
	createPart(
		model,
		"ControlPanel",
		Vector3.new(1.2, 1.4, 0.4),
		cf * CFrame.new(1.1, 2.1, 1.55),
		Enum.Material.SmoothPlastic,
		Color3.fromRGB(34, 38, 46),
		true
	)
	createPart(
		model,
		"IndicatorLight",
		Vector3.new(0.45, 0.45, 0.45),
		cf * CFrame.new(1.1, 3.05, 1.45),
		Enum.Material.SmoothPlastic,
		Color3.fromRGB(145, 50, 50),
		false
	)

	createStationLabel(body, "SAFE RECYCLER", "40% Yield (No PvP)", Color3.fromRGB(100, 185, 245))
	model.Parent = parent
	return model
end

local function buildSafeResearchTableModel(cf: CFrame, parent: Instance): Model
	local model = Instance.new("Model")
	model.Name = "SafeResearchTable"
	model:SetAttribute("StationType", "research_table")
	model:SetAttribute("IsResearchTable", true)
	model:SetAttribute("TableId", "base_safe_research_table")
	model:SetAttribute("NoBuild", true)

	local tableTop = createPart(
		model,
		"TableTop",
		Vector3.new(4.8, 0.5, 2.9),
		cf * CFrame.new(0, 2.35, 0),
		Enum.Material.WoodPlanks,
		Color3.fromRGB(132, 92, 54),
		true
	)
	model.PrimaryPart = tableTop

	createPart(
		model,
		"LeftLeg",
		Vector3.new(0.55, 2.1, 2.5),
		cf * CFrame.new(-1.95, 1.05, 0),
		Enum.Material.Metal,
		Color3.fromRGB(65, 72, 82),
		true
	)
	createPart(
		model,
		"RightLeg",
		Vector3.new(0.55, 2.1, 2.5),
		cf * CFrame.new(1.95, 1.05, 0),
		Enum.Material.Metal,
		Color3.fromRGB(65, 72, 82),
		true
	)
	createPart(
		model,
		"BlueprintPad",
		Vector3.new(2.4, 0.08, 1.7),
		cf * CFrame.new(-0.3, 2.64, 0),
		Enum.Material.SmoothPlastic,
		Color3.fromRGB(44, 118, 210),
		false
	)
	createPart(
		model,
		"LampPost",
		Vector3.new(0.22, 1.4, 0.22),
		cf * CFrame.new(1.65, 3.3, 0.9),
		Enum.Material.Metal,
		Color3.fromRGB(65, 72, 82),
		true
	)
	createPart(
		model,
		"LampHead",
		Vector3.new(0.75, 0.35, 0.55),
		cf * CFrame.new(1.45, 4.0, 0.75),
		Enum.Material.Neon,
		Color3.fromRGB(255, 224, 130),
		false
	)

	createStationLabel(tableTop, "RESEARCH TABLE", "Learn Blueprints (Scrap)", Color3.fromRGB(100, 175, 255))
	model.Parent = parent
	return model
end

function VendorService.DespawnBaseVendorHub()
	RecyclerService.UnregisterRecycler("base_safe_recycler")
	BlueprintService.UnregisterResearchTable("base_safe_research_table")
	for key, _ in registeredNpcs do
		if string.sub(key, 1, 5) == "base_" then
			registeredNpcs[key] = nil
		end
	end
	if dynamicHubModel ~= nil then
		dynamicHubModel:Destroy()
		dynamicHubModel = nil
	end
	local stale = Workspace:FindFirstChild("VendorHubZone")
	if stale ~= nil and stale:GetAttribute("IsDynamicVendorHub") == true then
		stale:Destroy()
	end
end

function VendorService.SpawnBaseVendorHub()
	if not BaseService.IsBaseMode() or Workspace:GetAttribute("RaidServerMode") == true then
		VendorService.DespawnBaseVendorHub()
		return
	end

	VendorService.DespawnBaseVendorHub()

	local origin = Config.VendorHub.Origin
	local zoneSize = Config.VendorHub.ZoneSize
	local baseCF = CFrame.new(origin)

	local hubModel = Instance.new("Model")
	hubModel.Name = "VendorHubZone"
	hubModel:SetAttribute("IsDynamicVendorHub", true)
	hubModel:SetAttribute("NoBuild", true)
	CollectionService:AddTag(hubModel, "NoBuild")
	CollectionService:AddTag(hubModel, "VendorHubZone")

	local pad = createPart(
		hubModel,
		"VendorHubPad",
		Vector3.new(zoneSize.X, 1.0, zoneSize.Z),
		baseCF * CFrame.new(0, -0.5, 0),
		Enum.Material.Concrete,
		Color3.fromRGB(72, 76, 84),
		true
	)
	hubModel.PrimaryPart = pad

	local noBuildVolume = createPart(
		hubModel,
		"NoBuildVolume",
		zoneSize,
		baseCF * CFrame.new(0, zoneSize.Y * 0.5 - 1.0, 0),
		Enum.Material.SmoothPlastic,
		Color3.fromRGB(80, 180, 120),
		false
	)
	noBuildVolume.Transparency = 1
	noBuildVolume.CanQuery = true

	-- Perimeter curbs
	local halfX = zoneSize.X * 0.5
	local halfZ = zoneSize.Z * 0.5
	createPart(
		hubModel,
		"Curb_North",
		Vector3.new(zoneSize.X, 0.8, 1.0),
		baseCF * CFrame.new(0, 0.4, -halfZ + 0.5),
		Enum.Material.Metal,
		Color3.fromRGB(64, 150, 96),
		true
	)
	createPart(
		hubModel,
		"Curb_West",
		Vector3.new(1.0, 0.8, zoneSize.Z),
		baseCF * CFrame.new(-halfX + 0.5, 0.4, 0),
		Enum.Material.Metal,
		Color3.fromRGB(64, 150, 96),
		true
	)
	createPart(
		hubModel,
		"Curb_East",
		Vector3.new(1.0, 0.8, zoneSize.Z),
		baseCF * CFrame.new(halfX - 0.5, 0.4, 0),
		Enum.Material.Metal,
		Color3.fromRGB(64, 150, 96),
		true
	)

	createSignBoard(
		hubModel,
		"HubSign",
		baseCF * CFrame.new(0, 0, halfZ - 2.0),
		"SAFE VENDOR HUB (NO BUILD)",
		Color3.fromRGB(80, 200, 125)
	)

	local stallOffsets = { -12, 0, 12 }
	for idx, vendorId in Vendors.Order do
		local vendorCfg = Vendors.ById[vendorId]
		if vendorCfg then
			local offsetX = stallOffsets[idx] or 0
			local stallCF = baseCF * CFrame.new(offsetX, 0, -4)
			local npcModel = buildVendorNpc(vendorCfg, stallCF, hubModel)
			registerNpcModel(string.format("base_%s", vendorId), vendorId, npcModel)
		end
	end

	local safeRecyclerModel = buildSafeRecyclerModel(baseCF * CFrame.new(-15, 0, 7), hubModel)
	RecyclerService.RegisterRecycler(safeRecyclerModel, "base_safe_recycler", Config.Recycler.SafeEfficiency)

	local safeResearchModel = buildSafeResearchTableModel(baseCF * CFrame.new(15, 0, 7), hubModel)
	BlueprintService.RegisterResearchTable("base_safe_research_table", safeResearchModel, nil)

	hubModel.Parent = Workspace
	dynamicHubModel = hubModel
end

function VendorService.BindStaticVendorHub(container: Instance)
	for _, desc in container:GetDescendants() do
		if desc:IsA("Model") and (dynamicHubModel == nil or not desc:IsDescendantOf(dynamicHubModel)) then
			local vendorIdAttr = desc:GetAttribute("VendorId")
			local vendorCfg = Vendors.Get(vendorIdAttr)
			if vendorCfg and desc.PrimaryPart ~= nil then
				local key = string.format("static_%s", desc:GetFullName())
				registerNpcModel(key, vendorCfg.Id, desc)
			end
		end
	end
end

local function findOffer(vendorCfg: VendorConfig, offerId: string): VendorOffer?
	for _, offer in vendorCfg.Offers do
		if offer.OfferId == offerId then
			return offer
		end
	end
	return nil
end

local function isPlayerNearVendor(player: Player, vendorId: VendorId): boolean
	local maxDist = Config.VendorHub.InteractDistance + Types.PING_DISTANCE_TOLERANCE
	for key, npc in registeredNpcs do
		if npc.Model.Parent == nil then
			registeredNpcs[key] = nil
		elseif npc.VendorId == vendorId then
			local pos = if npc.Model.PrimaryPart then npc.Model.PrimaryPart.Position else npc.Position
			if SecurityService.IsWithinDistance(player, pos, maxDist) then
				return true
			end
		end
	end
	return false
end

local function onVendorTradeRequest(player: Player, vendorIdAny: any, offerIdAny: any, quantityAny: any)
	if not SecurityService.CheckRateLimit(player, Net.Events.VendorTradeRequest) then
		return
	end
	if
		DataService.IsTeleporting(player)
		or SecurityService.IsTeleportLocked(player)
		or SecurityService.IsTransactionLocked(player)
		or isRaidBlocked(player)
	then
		return
	end
	if
		not SecurityService.IsValidString(vendorIdAny, 1, 32) or not SecurityService.IsValidString(offerIdAny, 1, 64)
	then
		return
	end

	local vendorCfg = Vendors.Get(vendorIdAny)
	if not vendorCfg then
		return
	end
	local offer = findOffer(vendorCfg, offerIdAny :: string)
	if not offer then
		return
	end

	local quantity = 1
	if quantityAny ~= nil then
		if not SecurityService.IsValidInteger(quantityAny, 1, Config.VendorHub.MaxTradeQuantity) then
			return
		end
		quantity = math.floor(quantityAny :: number)
	end

	if DataService.GetData(player) == nil or SecurityService.GetAliveCharacterRoot(player) == nil then
		return
	end

	if not isPlayerNearVendor(player, vendorCfg.Id) then
		sendFeedback(player, false, "Move closer to the vendor", vendorCfg.Id, offer.OfferId)
		return
	end

	SecurityService.RunLocked(player, "VendorTrade", function()
		if DataService.GetData(player) == nil or SecurityService.GetAliveCharacterRoot(player) == nil then
			return
		end
		if isRaidBlocked(player) or not isPlayerNearVendor(player, vendorCfg.Id) then
			sendFeedback(player, false, "Trade unavailable here", vendorCfg.Id, offer.OfferId)
			return
		end

		local totalGive = offer.GiveCount * quantity
		local totalReceive = offer.ReceiveCount * quantity
		local giveBatch: { Types.ItemBatchEntry } = {
			{ Id = offer.GiveId, Count = totalGive },
		}
		local costIngredients: { Ingredient } = {
			{ Id = offer.GiveId, Count = totalGive },
		}

		if not InventoryService.HasItems(player, giveBatch) then
			local giveCfg = Items[offer.GiveId]
			local giveName = if giveCfg then giveCfg.Name else offer.GiveId
			sendFeedback(player, false, string.format("Need %d %s", totalGive, giveName), vendorCfg.Id, offer.OfferId)
			return
		end

		if not InventoryService.CanCraftTransaction(player, costIngredients, offer.ReceiveId, totalReceive) then
			sendFeedback(player, false, "Inventory is full", vendorCfg.Id, offer.OfferId)
			return
		end

		if not InventoryService.RemoveItems(player, giveBatch) then
			sendFeedback(player, false, "Failed to remove items", vendorCfg.Id, offer.OfferId)
			return
		end

		local remainder = InventoryService.AddItem(player, offer.ReceiveId, totalReceive)
		if remainder > 0 then
			local addedCount = totalReceive - remainder
			if addedCount > 0 then
				InventoryService.RemoveItem(player, offer.ReceiveId, addedCount)
			end
			InventoryService.AddItem(player, offer.GiveId, totalGive)
			sendFeedback(player, false, "Inventory is full", vendorCfg.Id, offer.OfferId)
			return
		end

		local recCfg = Items[offer.ReceiveId]
		local recName = if recCfg then recCfg.Name else offer.ReceiveId
		sendFeedback(player, true, string.format("Received %s x%d", recName, totalReceive), vendorCfg.Id, offer.OfferId)
	end)
end

local function refreshBaseVendorHub()
	if BaseService.IsBaseMode() and Workspace:GetAttribute("RaidServerMode") ~= true then
		VendorService.SpawnBaseVendorHub()
	else
		VendorService.DespawnBaseVendorHub()
	end
end

function VendorService.Init()
	if isInitialized then
		return
	end
	isInitialized = true

	Net.InitServer()
	Net.GetEvent(Net.Events.VendorTradeRequest).OnServerEvent:Connect(onVendorTradeRequest)

	local qaArena = Workspace:FindFirstChild("QA_TestArena")
	if qaArena then
		VendorService.BindStaticVendorHub(qaArena)
	end
	local staticHub = Workspace:FindFirstChild("VendorHubZone")
	if staticHub and staticHub:GetAttribute("IsDynamicVendorHub") ~= true then
		VendorService.BindStaticVendorHub(staticHub)
	end

	refreshBaseVendorHub()

	Workspace:GetAttributeChangedSignal("RaidServerMode"):Connect(refreshBaseVendorHub)
	if RunService:IsStudio() then
		Workspace:GetAttributeChangedSignal("ForceBaseMode"):Connect(refreshBaseVendorHub)
	end
end

return VendorService
