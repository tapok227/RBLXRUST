--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Types = require(ReplicatedStorage.Shared.Types)
local Weapons = require(ReplicatedStorage.Shared.configs.Weapons)
local Projectiles = require(ReplicatedStorage.Shared.configs.Projectiles)
local Consumables = require(ReplicatedStorage.Shared.configs.Consumables)
local Explosives = require(ReplicatedStorage.Shared.configs.Explosives)
local Net = require(ReplicatedStorage.Shared.Net)
local HotbarController = require(script.Parent.HotbarController)
local InventoryController = require(script.Parent.InventoryController)
local InventoryUIController = require(script.Parent.InventoryUIController)
local CraftingController = require(script.Parent.CraftingController)
local LootController = require(script.Parent.LootController)
local GatheringController = require(script.Parent.GatheringController)
local BuildingController = require(script.Parent.BuildingController)
local DefenseController = require(script.Parent.DefenseController)
local ToolCupboardController = require(script.Parent.ToolCupboardController)
local VendorController = require(script.Parent.VendorController)
local ProjectileController = require(script.Parent.ProjectileController)

type WeaponConfig = Types.WeaponConfig

local TRACER_DURATION = 0.12
local HITMARKER_DURATION = 0.15
local AIM_RAY_MIN_DISTANCE = 250

local lastLocalAttack = 0
local hitmarkerToken = 0
local bowDrawing = false
local bowDrawStart = 0
local bowDrawSlot = 0
local bowDrawWeaponId = ""
local isInitialized = false

local crosshairContainer: Frame? = nil
local hitmarkerContainer: Frame? = nil
local hitmarkerBars: { Frame } = {}
local bowDrawBarBg: Frame? = nil
local bowDrawBarFill: Frame? = nil

local CombatController = {}

local function isAnyUiOpen(): boolean
	local localPlayer = Players.LocalPlayer
	local raidSelectOpen = localPlayer ~= nil and localPlayer:GetAttribute("RaidSelectOpen") == true
	return raidSelectOpen
		or InventoryUIController.IsOpen()
		or CraftingController.IsOpen()
		or LootController.IsOpen()
		or DefenseController.IsOpen()
		or ToolCupboardController.IsOpen()
		or VendorController.IsOpen()
end

local function hasAmmoInInventory(ammoId: string): boolean
	for i = 1, Types.INVENTORY_SIZE do
		local slot = InventoryController.GetSlot(i)
		if slot ~= nil and slot.Id == ammoId and slot.Count > 0 then
			return true
		end
	end
	return false
end

local function getEquippedWeapon(): (string, WeaponConfig)
	local selectedSlot = HotbarController.GetSelectedSlot()
	local equipped = InventoryController.GetSlot(selectedSlot)
	if equipped ~= nil and equipped.Id ~= "FISTS" then
		local cfg = Weapons[equipped.Id]
		if cfg ~= nil then
			return equipped.Id, cfg
		end
	end
	return "fists", Weapons.FISTS
end

local function findTargetCharacterFromPart(inst: Instance): (Model?, boolean)
	local current: Instance? = inst
	while current ~= nil and current ~= Workspace do
		if current:IsA("Model") then
			local humanoid = current:FindFirstChildOfClass("Humanoid")
			if humanoid ~= nil then
				return current, inst.Name == "Head"
			end
		end
		current = current.Parent
	end
	return nil, false
end

local function createCrosshairGui()
	local localPlayer = Players.LocalPlayer
	if not localPlayer then
		return
	end
	local playerGui = localPlayer:WaitForChild("PlayerGui") :: PlayerGui

	local existing = playerGui:FindFirstChild("CrosshairGui")
	if existing then
		existing:Destroy()
	end

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "CrosshairGui"
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = true
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	local container = Instance.new("Frame")
	container.Name = "CrosshairContainer"
	container.AnchorPoint = Vector2.new(0.5, 0.5)
	container.Position = UDim2.fromScale(0.5, 0.5)
	container.Size = UDim2.fromOffset(24, 24)
	container.BackgroundTransparency = 1
	container.Parent = screenGui

	local centerDot = Instance.new("Frame")
	centerDot.Name = "CenterDot"
	centerDot.AnchorPoint = Vector2.new(0.5, 0.5)
	centerDot.Position = UDim2.fromScale(0.5, 0.5)
	centerDot.Size = UDim2.fromOffset(4, 4)
	centerDot.BackgroundColor3 = Color3.new(1, 1, 1)
	centerDot.BackgroundTransparency = 0.1
	centerDot.BorderSizePixel = 0
	centerDot.Parent = container

	local lineSpecs = {
		{ Name = "Top", Pos = UDim2.new(0.5, 0, 0.5, -7), Size = UDim2.fromOffset(2, 6) },
		{ Name = "Bottom", Pos = UDim2.new(0.5, 0, 0.5, 7), Size = UDim2.fromOffset(2, 6) },
		{ Name = "Left", Pos = UDim2.new(0.5, -7, 0.5, 0), Size = UDim2.fromOffset(6, 2) },
		{ Name = "Right", Pos = UDim2.new(0.5, 7, 0.5, 0), Size = UDim2.fromOffset(6, 2) },
	}

	for _, spec in lineSpecs do
		local line = Instance.new("Frame")
		line.Name = spec.Name
		line.AnchorPoint = Vector2.new(0.5, 0.5)
		line.Position = spec.Pos
		line.Size = spec.Size
		line.BackgroundColor3 = Color3.new(1, 1, 1)
		line.BackgroundTransparency = 0.25
		line.BorderSizePixel = 0
		line.Parent = container
	end

	local hitFrame = Instance.new("Frame")
	hitFrame.Name = "Hitmarker"
	hitFrame.AnchorPoint = Vector2.new(0.5, 0.5)
	hitFrame.Position = UDim2.fromScale(0.5, 0.5)
	hitFrame.Size = UDim2.fromOffset(24, 24)
	hitFrame.BackgroundTransparency = 1
	hitFrame.Visible = false
	hitFrame.Parent = container

	table.clear(hitmarkerBars)
	local barSpecs = {
		{ Name = "TopLeft", Pos = UDim2.new(0.5, -6, 0.5, -6), Rot = 45 },
		{ Name = "TopRight", Pos = UDim2.new(0.5, 6, 0.5, -6), Rot = -45 },
		{ Name = "BottomLeft", Pos = UDim2.new(0.5, -6, 0.5, 6), Rot = -45 },
		{ Name = "BottomRight", Pos = UDim2.new(0.5, 6, 0.5, 6), Rot = 45 },
	}

	for _, spec in barSpecs do
		local bar = Instance.new("Frame")
		bar.Name = spec.Name
		bar.AnchorPoint = Vector2.new(0.5, 0.5)
		bar.Position = spec.Pos
		bar.Size = UDim2.fromOffset(2, 7)
		bar.Rotation = spec.Rot
		bar.BackgroundColor3 = Color3.new(1, 1, 1)
		bar.BorderSizePixel = 0
		bar.Parent = hitFrame
		table.insert(hitmarkerBars, bar)
	end

	local drawBg = Instance.new("Frame")
	drawBg.Name = "BowDrawBarBg"
	drawBg.AnchorPoint = Vector2.new(0.5, 0.5)
	drawBg.Position = UDim2.new(0.5, 0, 0.5, 22)
	drawBg.Size = UDim2.fromOffset(52, 5)
	drawBg.BackgroundColor3 = Color3.fromRGB(18, 20, 26)
	drawBg.BackgroundTransparency = 0.25
	drawBg.BorderSizePixel = 0
	drawBg.Visible = false
	drawBg.Parent = container

	local drawFill = Instance.new("Frame")
	drawFill.Name = "BowDrawBarFill"
	drawFill.Size = UDim2.fromScale(0, 1)
	drawFill.BackgroundColor3 = Color3.fromRGB(160, 160, 170)
	drawFill.BorderSizePixel = 0
	drawFill.Parent = drawBg

	crosshairContainer = container
	hitmarkerContainer = hitFrame
	bowDrawBarBg = drawBg
	bowDrawBarFill = drawFill
	screenGui.Parent = playerGui
end

local function flashHitmarker(isHeadshot: boolean)
	if not hitmarkerContainer then
		return
	end

	hitmarkerToken += 1
	local myToken = hitmarkerToken

	local color = if isHeadshot then Color3.fromRGB(255, 65, 65) else Color3.new(1, 1, 1)
	for _, bar in hitmarkerBars do
		bar.BackgroundColor3 = color
	end
	hitmarkerContainer.Visible = true

	task.delay(HITMARKER_DURATION, function()
		if hitmarkerToken == myToken and hitmarkerContainer then
			hitmarkerContainer.Visible = false
		end
	end)
end

local function spawnTracer(startPos: Vector3, endPos: Vector3, isHeadshot: boolean)
	local delta = endPos - startPos
	local dist = delta.Magnitude
	if dist < 0.1 then
		return
	end

	local tracer = Instance.new("Part")
	tracer.Name = "WeaponTracer"
	tracer.Anchored = true
	tracer.CanCollide = false
	tracer.CanQuery = false
	tracer.CanTouch = false
	tracer.CastShadow = false
	tracer.Material = Enum.Material.Neon
	tracer.Color = if isHeadshot then Color3.fromRGB(255, 110, 60) else Color3.fromRGB(255, 235, 140)
	tracer.Transparency = 0.25
	tracer.Size = Vector3.new(0.12, 0.12, dist)
	tracer.CFrame = CFrame.lookAt(startPos, endPos) * CFrame.new(0, 0, -dist * 0.5)
	tracer.Parent = Workspace.CurrentCamera or Workspace

	local tween = TweenService:Create(
		tracer,
		TweenInfo.new(TRACER_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Transparency = 1 }
	)
	tween:Play()

	task.delay(TRACER_DURATION, function()
		if tracer.Parent then
			tracer:Destroy()
		end
	end)
end

local function isCombatBlockedByItem(): boolean
	local selectedSlot = HotbarController.GetSelectedSlot()
	local equippedItem = InventoryController.GetSlot(selectedSlot)
	return equippedItem ~= nil
		and (
			Consumables[equippedItem.Id] ~= nil
			or Explosives[equippedItem.Id] ~= nil
			or equippedItem.Id == "building_plan"
			or equippedItem.Id == "hammer"
		)
end

local function getAliveCharacter(): (Model?, BasePart?)
	local localPlayer = Players.LocalPlayer
	if not localPlayer then
		return nil, nil
	end
	local character = localPlayer.Character
	if not character then
		return nil, nil
	end
	local hrp = character:FindFirstChild("HumanoidRootPart")
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not hrp or not hrp:IsA("BasePart") or not humanoid or humanoid.Health <= 0 then
		return nil, nil
	end
	return character, hrp
end

local function computeAimData(weapon: WeaponConfig): (Vector3?, Vector3?, Model?, boolean, Model?)
	local camera = Workspace.CurrentCamera
	local character, hrp = getAliveCharacter()
	if not camera or not character or not hrp then
		return nil, nil, nil, false, nil
	end

	local mouseLoc = UserInputService:GetMouseLocation()
	local unitRay = camera:ViewportPointToRay(mouseLoc.X, mouseLoc.Y)

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.IgnoreWater = true
	params.FilterDescendantsInstances = { character }

	local rayDist = math.max(weapon.Range, AIM_RAY_MIN_DISTANCE)
	local result = Workspace:Raycast(unitRay.Origin, unitRay.Direction * rayDist, params)
	local aimPoint = if result then result.Position else (unitRay.Origin + unitRay.Direction * rayDist)

	local targetModel: Model? = nil
	local isHeadshotHint = false
	if result then
		targetModel, isHeadshotHint = findTargetCharacterFromPart(result.Instance)
	end

	local head = character:FindFirstChild("Head")
	local origin = if head and head:IsA("BasePart") then head.Position else (hrp.Position + Vector3.new(0, 1.5, 0))

	local rawDir = aimPoint - origin
	local direction = if rawDir.Magnitude > 0.01 then rawDir.Unit else unitRay.Direction.Unit
	return origin, direction, targetModel, isHeadshotHint, character
end

local function cancelBowDraw()
	bowDrawing = false
	if bowDrawBarBg then
		bowDrawBarBg.Visible = false
	end
	if bowDrawBarFill then
		bowDrawBarFill.Size = UDim2.fromScale(0, 1)
	end
end

local function fireWeaponWithCharge(weapon: WeaponConfig, chargeRatio: number)
	local origin, direction, targetModel, isHeadshotHint, character = computeAimData(weapon)
	if origin == nil or direction == nil or character == nil then
		return
	end

	lastLocalAttack = os.clock()
	if weapon.ProjectileId ~= nil then
		local projCfg = Projectiles[weapon.ProjectileId]
		local speedOverride: number? = nil
		if projCfg ~= nil and projCfg.MinSpeed ~= nil and projCfg.MaxSpeed ~= nil then
			speedOverride = projCfg.MinSpeed + (projCfg.MaxSpeed - projCfg.MinSpeed) * math.clamp(chargeRatio, 0, 1)
		end
		ProjectileController.SpawnLocalProjectile(weapon.ProjectileId, origin, direction, character, speedOverride)
	end
	Net.GetEvent(Net.Events.AttackRequest):FireServer(origin, direction, targetModel, isHeadshotHint, chargeRatio)
end

local function handleAttackPress()
	if BuildingController.IsBuildMode() or isAnyUiOpen() or isCombatBlockedByItem() then
		return
	end

	local weaponId, weapon = getEquippedWeapon()
	if weapon.Category == "Melee" and GatheringController.IsCursorOnActiveNode() then
		return
	end

	local now = os.clock()
	if (now - lastLocalAttack) < weapon.Cooldown then
		return
	end

	if weapon.AmmoId ~= nil and not hasAmmoInInventory(weapon.AmmoId) then
		return
	end

	if getAliveCharacter() == nil then
		return
	end

	if weapon.DrawMinTime ~= nil and weapon.DrawFullTime ~= nil then
		bowDrawing = true
		bowDrawStart = now
		bowDrawSlot = HotbarController.GetSelectedSlot()
		bowDrawWeaponId = weaponId
		return
	end

	fireWeaponWithCharge(weapon, 1.0)
end

local function handleAttackRelease()
	if not bowDrawing then
		return
	end

	local elapsed = os.clock() - bowDrawStart
	local startSlot = bowDrawSlot
	local startWeaponId = bowDrawWeaponId
	cancelBowDraw()

	if BuildingController.IsBuildMode() or isAnyUiOpen() or isCombatBlockedByItem() then
		return
	end
	if HotbarController.GetSelectedSlot() ~= startSlot then
		return
	end

	local weaponId, weapon = getEquippedWeapon()
	if weaponId ~= startWeaponId or weapon.DrawMinTime == nil or weapon.DrawFullTime == nil then
		return
	end
	if (os.clock() - lastLocalAttack) < weapon.Cooldown then
		return
	end
	if weapon.AmmoId ~= nil and not hasAmmoInInventory(weapon.AmmoId) then
		return
	end
	if elapsed < weapon.DrawMinTime then
		return
	end

	local span = math.max(0.01, weapon.DrawFullTime - weapon.DrawMinTime)
	local chargeRatio = math.clamp((elapsed - weapon.DrawMinTime) / span, 0, 1)
	fireWeaponWithCharge(weapon, chargeRatio)
end

function CombatController.Init()
	if isInitialized then
		return
	end
	isInitialized = true

	createCrosshairGui()

	Net.GetEvent(Net.Events.AttackEffect).OnClientEvent:Connect(
		function(
			attacker: Player,
			weaponId: string,
			startPos: Vector3,
			endPos: Vector3,
			didHit: boolean,
			isHeadshot: boolean
		)
			if typeof(weaponId) ~= "string" or typeof(startPos) ~= "Vector3" or typeof(endPos) ~= "Vector3" then
				return
			end

			if attacker == Players.LocalPlayer and didHit == true then
				flashHitmarker(isHeadshot == true)
			end

			local cfg = Weapons[weaponId]
			if cfg ~= nil and cfg.Category == "Ranged" and cfg.ProjectileId == nil then
				spawnTracer(startPos, endPos, isHeadshot == true)
			end
		end
	)

	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessedEvent: boolean)
		if gameProcessedEvent then
			return
		end
		if UserInputService:GetFocusedTextBox() ~= nil then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			handleAttackPress()
		end
	end)

	UserInputService.InputEnded:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			handleAttackRelease()
		end
	end)

	RunService.RenderStepped:Connect(function()
		local uiOpen = isAnyUiOpen()
		if crosshairContainer then
			crosshairContainer.Visible = not uiOpen
		end

		if bowDrawing then
			local weaponId, weapon = getEquippedWeapon()
			local invalidState = uiOpen
				or BuildingController.IsBuildMode()
				or isCombatBlockedByItem()
				or HotbarController.GetSelectedSlot() ~= bowDrawSlot
				or weaponId ~= bowDrawWeaponId
				or weapon.DrawMinTime == nil
				or weapon.DrawFullTime == nil
				or getAliveCharacter() == nil
				or (weapon.AmmoId ~= nil and not hasAmmoInInventory(weapon.AmmoId))
			if invalidState then
				cancelBowDraw()
				return
			end

			local elapsed = os.clock() - bowDrawStart
			local drawMin = weapon.DrawMinTime :: number
			local drawFull = weapon.DrawFullTime :: number
			local fillRatio = math.clamp(elapsed / math.max(0.01, drawFull), 0, 1)

			if bowDrawBarBg then
				bowDrawBarBg.Visible = true
			end
			if bowDrawBarFill then
				bowDrawBarFill.Size = UDim2.fromScale(fillRatio, 1)
				if elapsed < drawMin then
					bowDrawBarFill.BackgroundColor3 = Color3.fromRGB(150, 150, 160)
				elseif elapsed >= drawFull then
					bowDrawBarFill.BackgroundColor3 = Color3.fromRGB(85, 230, 120)
				else
					bowDrawBarFill.BackgroundColor3 = Color3.fromRGB(245, 200, 75)
				end
			end
		end
	end)
end

return CombatController
