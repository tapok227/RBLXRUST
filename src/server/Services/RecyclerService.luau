--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)
local Types = require(ReplicatedStorage.Shared.Types)
local Items = require(ReplicatedStorage.Shared.configs.Items)
local Recycling = require(ReplicatedStorage.Shared.configs.Recycling)
local Net = require(ReplicatedStorage.Shared.Net)
local DataService = require(ServerScriptService.Server.Services.DataService)
local InventoryService = require(ServerScriptService.Server.Services.InventoryService)
local SecurityService = require(ServerScriptService.Server.Services.SecurityService)

type Inventory = Types.Inventory
type Slot = Types.Slot
type ItemBatchEntry = Types.ItemBatchEntry
type RecyclerState = Types.RecyclerState

type ServerRecycler = {
	RecyclerId: string,
	Name: string,
	Model: Model,
	PrimaryPart: BasePart,
	EfficiencyMultiplier: number,
	IsRunning: boolean,
	Progress: number,
	InputSlots: Inventory,
	OutputSlots: Inventory,
	Viewers: { [Player]: boolean },
	IndicatorLight: BasePart?,
	PointLight: PointLight?,
	WorkSound: Sound?,
	CompleteSound: Sound?,
}

local SOUND_WORK_LOOP = "rbxasset://sounds/action_falling.ogg"
local SOUND_COMPLETE_TICK = "rbxasset://sounds/impact_explosion_03.mp3"
local TICK_STEP_SECONDS = 0.25

local recyclersById: { [string]: ServerRecycler } = {}
local recyclersByModel: { [Model]: ServerRecycler } = {}
local isInitialized = false

local RecyclerService = {}

local function serializeSlotsForNet(slots: Inventory, maxSlots: number): { [string]: Slot }
	local out: { [string]: Slot } = {}
	for i = 1, maxSlots do
		local slot = slots[i]
		if slot ~= nil and slot.Count > 0 then
			out[tostring(i)] = {
				Id = slot.Id,
				Count = slot.Count,
			}
		end
	end
	return out
end

local function cloneSlots(slots: Inventory, maxSlots: number): Inventory
	local copy: Inventory = {}
	for i = 1, maxSlots do
		local slot = slots[i]
		if slot ~= nil and slot.Count > 0 then
			copy[i] = {
				Id = slot.Id,
				Count = slot.Count,
			}
		end
	end
	return copy
end

local function addItemToSlots(slots: Inventory, maxSlots: number, itemId: string, count: number): number
	local itemCfg = Items[itemId]
	if itemCfg == nil or count <= 0 then
		return count
	end
	local maxStack = math.max(1, itemCfg.MaxStack)
	local remaining = count

	if maxStack > 1 then
		for i = 1, maxSlots do
			local slot = slots[i]
			if slot ~= nil and slot.Id == itemId and slot.Count < maxStack then
				local space = maxStack - slot.Count
				local add = math.min(space, remaining)
				slot.Count += add
				remaining -= add
				if remaining <= 0 then
					return 0
				end
			end
		end
	end

	for i = 1, maxSlots do
		if slots[i] == nil then
			local add = math.min(maxStack, remaining)
			slots[i] = {
				Id = itemId,
				Count = add,
			}
			remaining -= add
			if remaining <= 0 then
				return 0
			end
		end
	end

	return remaining
end

local function canFitAllOutputs(outputSlots: Inventory, outputs: { ItemBatchEntry }): boolean
	if #outputs == 0 then
		return false
	end
	local simulated = cloneSlots(outputSlots, Config.Recycler.OutputSlots)
	for _, entry in outputs do
		local rem = addItemToSlots(simulated, Config.Recycler.OutputSlots, entry.Id, entry.Count)
		if rem > 0 then
			return false
		end
	end
	return true
end

local function findNextRecyclableSlot(rec: ServerRecycler): (number?, Slot?)
	for i = 1, Config.Recycler.InputSlots do
		local slot = rec.InputSlots[i]
		if slot ~= nil and slot.Count > 0 and Recycling.CanRecycle(slot.Id) then
			return i, slot
		end
	end
	return nil, nil
end

local function updateVisualsAndAudio(rec: ServerRecycler)
	rec.Model:SetAttribute("IsRunning", rec.IsRunning)

	if rec.IndicatorLight ~= nil then
		if rec.IsRunning then
			rec.IndicatorLight.Material = Enum.Material.Neon
			rec.IndicatorLight.Color = Color3.fromRGB(70, 235, 110)
		else
			rec.IndicatorLight.Material = Enum.Material.SmoothPlastic
			rec.IndicatorLight.Color = Color3.fromRGB(145, 50, 50)
		end
	end

	if rec.PointLight ~= nil then
		rec.PointLight.Enabled = rec.IsRunning
	end

	if rec.WorkSound ~= nil then
		if rec.IsRunning then
			if not rec.WorkSound.IsPlaying then
				rec.WorkSound:Play()
			end
		else
			if rec.WorkSound.IsPlaying then
				rec.WorkSound:Stop()
			end
		end
	end
end

local function buildNetPayload(rec: ServerRecycler): { [string]: any }
	return {
		RecyclerId = rec.RecyclerId,
		Name = rec.Name,
		EfficiencyMultiplier = rec.EfficiencyMultiplier,
		IsRunning = rec.IsRunning,
		InputSlots = serializeSlotsForNet(rec.InputSlots, Config.Recycler.InputSlots),
		OutputSlots = serializeSlotsForNet(rec.OutputSlots, Config.Recycler.OutputSlots),
		Progress = rec.Progress,
		Position = rec.PrimaryPart.Position,
	}
end

local function syncToViewer(rec: ServerRecycler, player: Player)
	if player.Parent ~= Players then
		rec.Viewers[player] = nil
		return
	end
	Net.GetEvent(Net.Events.RecyclerStateSync):FireClient(player, buildNetPayload(rec))
end

local function broadcastToViewers(rec: ServerRecycler)
	local payload = buildNetPayload(rec)
	local syncEvent = Net.GetEvent(Net.Events.RecyclerStateSync)
	for viewer, _ in rec.Viewers do
		if viewer.Parent ~= Players then
			rec.Viewers[viewer] = nil
		else
			syncEvent:FireClient(viewer, payload)
		end
	end
end

local function stopRecycler(rec: ServerRecycler)
	if rec.IsRunning or rec.Progress > 0 then
		rec.IsRunning = false
		rec.Progress = 0
		updateVisualsAndAudio(rec)
	end
end

local function canStartRecycler(rec: ServerRecycler): boolean
	local _, slot = findNextRecyclableSlot(rec)
	if slot == nil then
		return false
	end
	local outputs, consumeCount = Recycling.ComputeOutputs(slot.Id, rec.EfficiencyMultiplier, slot.Count)
	if consumeCount <= 0 or #outputs == 0 then
		return false
	end
	return canFitAllOutputs(rec.OutputSlots, outputs)
end

local function ensureAudioVisualAttachments(
	model: Model,
	primaryPart: BasePart
): (BasePart?, PointLight?, Sound?, Sound?)
	local indicator: BasePart? = nil
	local foundLight = model:FindFirstChild("IndicatorLight", true)
	if foundLight and foundLight:IsA("BasePart") then
		indicator = foundLight
	end

	local pointLight: PointLight? = nil
	if indicator ~= nil then
		local existingPL = indicator:FindFirstChildOfClass("PointLight")
		if existingPL then
			pointLight = existingPL
		else
			local createdPL = Instance.new("PointLight")
			createdPL.Color = Color3.fromRGB(70, 235, 110)
			createdPL.Range = 14
			createdPL.Brightness = 1.6
			createdPL.Enabled = false
			createdPL.Parent = indicator
			pointLight = createdPL
		end
	end

	local workSound = primaryPart:FindFirstChild("RecyclerWorkSound")
	if not (workSound and workSound:IsA("Sound")) then
		local s = Instance.new("Sound")
		s.Name = "RecyclerWorkSound"
		s.SoundId = SOUND_WORK_LOOP
		s.Looped = true
		s.PlaybackSpeed = 0.55
		s.Volume = 0.4
		s.RollOffMaxDistance = 85
		s.RollOffMinDistance = 12
		s.Parent = primaryPart
		workSound = s
	end

	local completeSound = primaryPart:FindFirstChild("RecyclerTickSound")
	if not (completeSound and completeSound:IsA("Sound")) then
		local s = Instance.new("Sound")
		s.Name = "RecyclerTickSound"
		s.SoundId = SOUND_COMPLETE_TICK
		s.Looped = false
		s.PlaybackSpeed = 1.6
		s.Volume = 0.25
		s.RollOffMaxDistance = 75
		s.RollOffMinDistance = 10
		s.Parent = primaryPart
		completeSound = s
	end

	return indicator,
		pointLight,
		if workSound and workSound:IsA("Sound") then workSound else nil,
		if completeSound and completeSound:IsA("Sound") then completeSound else nil
end

function RecyclerService.RegisterRecycler(model: Model, recyclerId: string?, efficiencyOverride: number?): string
	if not model:IsA("Model") then
		return ""
	end
	local existing = recyclersByModel[model]
	if existing ~= nil then
		return existing.RecyclerId
	end

	local primaryPart = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart", true)
	if not primaryPart then
		warn(string.format('[RecyclerService] Recycler "%s" has no BasePart', model.Name))
		return ""
	end
	if model.PrimaryPart == nil then
		model.PrimaryPart = primaryPart
	end

	local attrId = model:GetAttribute("RecyclerId")
	local resolvedId = if typeof(recyclerId) == "string" and #recyclerId > 0
		then recyclerId
		elseif typeof(attrId) == "string" and #attrId > 0 then attrId
		else string.format("recycler_%s", model:GetFullName())

	if recyclersById[resolvedId] ~= nil then
		RecyclerService.UnregisterRecycler(resolvedId)
	end

	local effAttr = model:GetAttribute("EfficiencyMultiplier")
	local rawEff = if typeof(efficiencyOverride) == "number"
		then efficiencyOverride
		elseif typeof(effAttr) == "number" then effAttr
		else Config.Recycler.DefaultEfficiency
	local eff = math.clamp(rawEff, 0.1, 3.0)
	model:SetAttribute("EfficiencyMultiplier", eff)

	local yieldPct = math.floor(eff * 50 + 0.5)
	local nameAttr = model:GetAttribute("RecyclerName")
	local displayName = if typeof(nameAttr) == "string" and #nameAttr > 0
		then nameAttr
		else string.format("Recycler (%d%% Yield)", yieldPct)

	local indicator, pointLight, workSound, completeSound = ensureAudioVisualAttachments(model, primaryPart)

	local rec: ServerRecycler = {
		RecyclerId = resolvedId,
		Name = displayName,
		Model = model,
		PrimaryPart = primaryPart,
		EfficiencyMultiplier = eff,
		IsRunning = false,
		Progress = 0,
		InputSlots = {},
		OutputSlots = {},
		Viewers = {},
		IndicatorLight = indicator,
		PointLight = pointLight,
		WorkSound = workSound,
		CompleteSound = completeSound,
	}

	recyclersById[resolvedId] = rec
	recyclersByModel[model] = rec
	updateVisualsAndAudio(rec)

	local prompt = primaryPart:FindFirstChild("RecyclerPrompt")
	if not (prompt and prompt:IsA("ProximityPrompt")) then
		local found = model:FindFirstChildWhichIsA("ProximityPrompt", true)
		if found then
			prompt = found
		else
			local created = Instance.new("ProximityPrompt")
			created.Name = "RecyclerPrompt"
			created.ActionText = "Open Recycler"
			created.ObjectText = displayName
			created.HoldDuration = 0
			created.MaxActivationDistance = 10
			created.RequiresLineOfSight = false
			created.Parent = primaryPart
			prompt = created
		end
	end

	if prompt and prompt:IsA("ProximityPrompt") and prompt:GetAttribute("RecyclerPromptBound") ~= true then
		prompt:SetAttribute("RecyclerPromptBound", true)
		prompt.Triggered:Connect(function(triggerPlayer: Player)
			local current = recyclersById[resolvedId]
			if current == nil or current.Model.Parent == nil then
				return
			end
			if DataService.IsTeleporting(triggerPlayer) or SecurityService.IsTeleportLocked(triggerPlayer) then
				return
			end
			local maxDist = Config.Recycler.InteractDistance + Types.PING_DISTANCE_TOLERANCE
			if not SecurityService.IsWithinDistance(triggerPlayer, current.PrimaryPart.Position, maxDist) then
				return
			end
			current.Viewers[triggerPlayer] = true
			local payload = buildNetPayload(current)
			Net.GetEvent(Net.Events.RecyclerOpen):FireClient(triggerPlayer, payload)
			syncToViewer(current, triggerPlayer)
		end)
	end

	return resolvedId
end

function RecyclerService.UnregisterRecycler(recyclerId: string)
	local rec = recyclersById[recyclerId]
	if rec == nil then
		return
	end
	stopRecycler(rec)
	recyclersById[recyclerId] = nil
	recyclersByModel[rec.Model] = nil
	table.clear(rec.Viewers)
end

function RecyclerService.GetRecyclerState(recyclerId: string): RecyclerState?
	local rec = recyclersById[recyclerId]
	if rec == nil then
		return nil
	end
	return {
		RecyclerId = rec.RecyclerId,
		Name = rec.Name,
		EfficiencyMultiplier = rec.EfficiencyMultiplier,
		IsRunning = rec.IsRunning,
		InputSlots = cloneSlots(rec.InputSlots, Config.Recycler.InputSlots),
		OutputSlots = cloneSlots(rec.OutputSlots, Config.Recycler.OutputSlots),
		Progress = rec.Progress,
		Position = rec.PrimaryPart.Position,
	}
end

local function onRecyclerClose(player: Player, recyclerIdAny: any)
	if not SecurityService.CheckRateLimit(player, Net.Events.RecyclerClose) then
		return
	end
	if typeof(recyclerIdAny) == "string" and #recyclerIdAny > 0 then
		local rec = recyclersById[recyclerIdAny]
		if rec ~= nil then
			rec.Viewers[player] = nil
		end
		return
	end
	for _, rec in recyclersById do
		rec.Viewers[player] = nil
	end
end

local function onRecyclerAction(player: Player, recyclerIdAny: any, actionAny: any, argAny: any)
	if not SecurityService.CheckRateLimit(player, Net.Events.RecyclerAction) then
		return
	end
	if
		DataService.IsTeleporting(player)
		or SecurityService.IsTeleportLocked(player)
		or SecurityService.IsTransactionLocked(player)
	then
		return
	end
	if
		not SecurityService.IsValidString(recyclerIdAny, 1, 128) or not SecurityService.IsValidString(actionAny, 1, 32)
	then
		return
	end
	if DataService.GetData(player) == nil or SecurityService.GetAliveCharacterRoot(player) == nil then
		return
	end

	local recyclerId = recyclerIdAny :: string
	local action = actionAny :: string
	local rec = recyclersById[recyclerId]
	if rec == nil or rec.Model.Parent == nil then
		return
	end

	local maxDist = Config.Recycler.InteractDistance + Types.PING_DISTANCE_TOLERANCE
	if not SecurityService.IsWithinDistance(player, rec.PrimaryPart.Position, maxDist) then
		return
	end

	SecurityService.RunLocked(player, "RecyclerAction", function()
		local latest = recyclersById[recyclerId]
		if latest == nil or latest.Model.Parent == nil then
			return
		end
		if DataService.GetData(player) == nil or SecurityService.GetAliveCharacterRoot(player) == nil then
			return
		end
		if not SecurityService.IsWithinDistance(player, latest.PrimaryPart.Position, maxDist) then
			return
		end

		latest.Viewers[player] = true

		if action == "Toggle" then
			if latest.IsRunning then
				stopRecycler(latest)
			elseif canStartRecycler(latest) then
				latest.IsRunning = true
				latest.Progress = 0
				updateVisualsAndAudio(latest)
			end
			broadcastToViewers(latest)
		elseif action == "Deposit" then
			if not SecurityService.IsValidInteger(argAny, 1, Types.INVENTORY_SIZE) then
				return
			end
			local invSlotIdx = math.floor(argAny :: number)
			local slot = InventoryService.GetSlot(player, invSlotIdx)
			if slot == nil or slot.Count <= 0 or not Recycling.CanRecycle(slot.Id) then
				return
			end

			local origCount = slot.Count
			local origId = slot.Id
			local prevInput = cloneSlots(latest.InputSlots, Config.Recycler.InputSlots)
			local rem = addItemToSlots(latest.InputSlots, Config.Recycler.InputSlots, origId, origCount)
			local moved = origCount - rem
			if moved <= 0 then
				return
			end

			if not InventoryService.ConsumeSlot(player, invSlotIdx, moved) then
				latest.InputSlots = prevInput
				return
			end
			broadcastToViewers(latest)
		elseif action == "TakeInput" then
			if not SecurityService.IsValidInteger(argAny, 1, Config.Recycler.InputSlots) then
				return
			end
			local inputIdx = math.floor(argAny :: number)
			local slot = latest.InputSlots[inputIdx]
			if slot == nil or slot.Count <= 0 then
				return
			end
			local remainder = InventoryService.AddItem(player, slot.Id, slot.Count)
			if remainder <= 0 then
				latest.InputSlots[inputIdx] = nil
			elseif remainder < slot.Count then
				slot.Count = remainder
			else
				return
			end
			if latest.IsRunning and not canStartRecycler(latest) then
				stopRecycler(latest)
			end
			broadcastToViewers(latest)
		elseif action == "TakeOutput" then
			if not SecurityService.IsValidInteger(argAny, 1, Config.Recycler.OutputSlots) then
				return
			end
			local outIdx = math.floor(argAny :: number)
			local slot = latest.OutputSlots[outIdx]
			if slot == nil or slot.Count <= 0 then
				return
			end
			local remainder = InventoryService.AddItem(player, slot.Id, slot.Count)
			if remainder <= 0 then
				latest.OutputSlots[outIdx] = nil
			elseif remainder < slot.Count then
				slot.Count = remainder
			else
				return
			end
			broadcastToViewers(latest)
		elseif action == "TakeAllOutput" then
			local changed = false
			for i = 1, Config.Recycler.OutputSlots do
				local slot = latest.OutputSlots[i]
				if slot ~= nil and slot.Count > 0 then
					local remainder = InventoryService.AddItem(player, slot.Id, slot.Count)
					if remainder <= 0 then
						latest.OutputSlots[i] = nil
						changed = true
					elseif remainder < slot.Count then
						slot.Count = remainder
						changed = true
					end
				end
			end
			if changed then
				broadcastToViewers(latest)
			end
		end
	end)
end

local function stepRecyclers(dt: number)
	local tickDuration = math.max(0.5, Config.Recycler.TickInterval)
	local maxDist = Config.Recycler.InteractDistance + Types.PING_DISTANCE_TOLERANCE + 4

	for recyclerId, rec in recyclersById do
		if rec.Model.Parent == nil then
			RecyclerService.UnregisterRecycler(recyclerId)
			continue
		end

		for viewer, _ in rec.Viewers do
			if
				viewer.Parent ~= Players
				or SecurityService.GetAliveCharacterRoot(viewer) == nil
				or not SecurityService.IsWithinDistance(viewer, rec.PrimaryPart.Position, maxDist)
			then
				rec.Viewers[viewer] = nil
			end
		end

		if not rec.IsRunning then
			continue
		end

		local slotIdx, slot = findNextRecyclableSlot(rec)
		if slotIdx == nil or slot == nil then
			stopRecycler(rec)
			broadcastToViewers(rec)
			continue
		end

		local outputs, consumeCount = Recycling.ComputeOutputs(slot.Id, rec.EfficiencyMultiplier, slot.Count)
		if consumeCount <= 0 or #outputs == 0 or not canFitAllOutputs(rec.OutputSlots, outputs) then
			stopRecycler(rec)
			broadcastToViewers(rec)
			continue
		end

		rec.Progress += dt / tickDuration
		if rec.Progress >= 1.0 then
			rec.Progress -= 1.0
			slot.Count -= consumeCount
			if slot.Count <= 0 then
				rec.InputSlots[slotIdx] = nil
			end
			for _, outEntry in outputs do
				addItemToSlots(rec.OutputSlots, Config.Recycler.OutputSlots, outEntry.Id, outEntry.Count)
			end
			if rec.CompleteSound ~= nil then
				rec.CompleteSound:Play()
			end
			if not canStartRecycler(rec) then
				stopRecycler(rec)
			end
		end

		broadcastToViewers(rec)
	end
end

local function scanStaticRecyclers()
	local scanRoots: { Instance? } = {
		Workspace:FindFirstChild("POI"),
		Workspace:FindFirstChild("QA_TestArena"),
		Workspace:FindFirstChild("Recyclers"),
	}
	local staticHub = Workspace:FindFirstChild("VendorHubZone")
	if staticHub and staticHub:GetAttribute("IsDynamicVendorHub") ~= true then
		table.insert(scanRoots, staticHub)
	end

	for _, root in scanRoots do
		if root ~= nil then
			for _, desc in root:GetDescendants() do
				if desc:IsA("Model") then
					local isRecycler = desc:GetAttribute("IsRecycler") == true
						or desc:GetAttribute("StationType") == "recycler"
					if isRecycler then
						RecyclerService.RegisterRecycler(desc, nil, nil)
					end
				end
			end
		end
	end
end

function RecyclerService.Init()
	if isInitialized then
		return
	end
	isInitialized = true

	Net.InitServer()
	scanStaticRecyclers()

	Net.GetEvent(Net.Events.RecyclerAction).OnServerEvent:Connect(onRecyclerAction)
	Net.GetEvent(Net.Events.RecyclerClose).OnServerEvent:Connect(onRecyclerClose)

	Players.PlayerRemoving:Connect(function(player: Player)
		for _, rec in recyclersById do
			rec.Viewers[player] = nil
		end
	end)

	task.spawn(function()
		while true do
			local elapsed = task.wait(TICK_STEP_SECONDS)
			stepRecyclers(elapsed)
		end
	end)
end

return RecyclerService
