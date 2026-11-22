--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)
local Types = require(ReplicatedStorage.Shared.Types)
local Recipes = require(ReplicatedStorage.Shared.configs.Recipes)
local Net = require(ReplicatedStorage.Shared.Net)
local DataService = require(ServerScriptService.Server.Services.DataService)
local InventoryService = require(ServerScriptService.Server.Services.InventoryService)
local SecurityService = require(ServerScriptService.Server.Services.SecurityService)
local BlueprintService = require(ServerScriptService.Server.Services.BlueprintService)

type Ingredient = Types.Ingredient
type CraftingState = Types.CraftingState

type StationEntry = {
	StationType: string,
	Tier: number,
	Position: Vector3,
	OwnerUserId: number?,
}

type ActiveCraft = {
	Token: number,
	RecipeId: string,
	StartTime: number,
	EndTime: number,
	ConsumedIngredients: { Ingredient },
	DelayThread: thread?,
}

local WORKBENCH_TIERS: { [string]: number } = table.freeze({
	workbench_1 = 1,
	workbench_2 = 2,
	workbench_3 = 3,
})

local WORKBENCH_SYNC_INTERVAL = 0.25

local stations: { StationEntry } = {}
local dynamicStations: { [string]: StationEntry } = {}
local activeCrafts: { [Player]: ActiveCraft } = {}
local playerCraftConnections: { [Player]: { RBXScriptConnection } } = {}
local lastSyncedTierByPlayer: { [Player]: number } = {}
local lastSyncedCampfireByPlayer: { [Player]: boolean } = {}
local nextToken = 0
local isInitialized = false

local CraftingService = {}

local function resolveStationTier(stationType: string): number
	return WORKBENCH_TIERS[stationType] or 0
end

local function canPlayerUseStation(player: Player, entry: StationEntry): boolean
	return entry.OwnerUserId == nil or entry.OwnerUserId == player.UserId
end

local function registerStationModel(child: Instance, seen: { [Model]: boolean }, defaultStationType: string?)
	if not child:IsA("Model") or seen[child] then
		return
	end
	local primaryPart = child.PrimaryPart
	local stationAttr = child:GetAttribute("StationType")
	local stationType = if typeof(stationAttr) == "string" and #stationAttr > 0 then stationAttr else defaultStationType
	local ownerAttr = child:GetAttribute("OwnerUserId")
	local ownerUserId: number? = if typeof(ownerAttr) == "number" then ownerAttr else nil
	if primaryPart and typeof(stationType) == "string" and #stationType > 0 then
		seen[child] = true
		table.insert(stations, {
			StationType = stationType,
			Tier = resolveStationTier(stationType),
			Position = primaryPart.Position,
			OwnerUserId = ownerUserId,
		})
	elseif defaultStationType == nil then
		warn(string.format('[CraftingService] Workbench "%s" missing PrimaryPart or StationType attribute', child.Name))
	end
end

local function scanWorkbenches()
	table.clear(stations)
	local seen: { [Model]: boolean } = {}

	local folder = Workspace:FindFirstChild("Workbenches")
	if not folder then
		warn("[CraftingService] Workspace.Workbenches folder not found")
	else
		for _, child in folder:GetChildren() do
			registerStationModel(child, seen, nil)
		end
	end

	local campfiresFolder = Workspace:FindFirstChild("Campfires")
	if campfiresFolder then
		for _, child in campfiresFolder:GetChildren() do
			registerStationModel(child, seen, "campfire")
		end
	end

	local qaArena = Workspace:FindFirstChild("QA_TestArena")
	if qaArena then
		for _, desc in qaArena:GetDescendants() do
			if desc:IsA("Model") then
				local attr = desc:GetAttribute("StationType")
				if attr == "campfire" or desc.Name == "QA_Campfire" then
					registerStationModel(desc, seen, "campfire")
				end
			end
		end
	end
end

local function doesStationSatisfy(availableStation: string, requiredStation: string): boolean
	local availTier = WORKBENCH_TIERS[availableStation]
	local reqTier = WORKBENCH_TIERS[requiredStation]
	if availTier ~= nil and reqTier ~= nil then
		return availTier >= reqTier
	end
	return availableStation == requiredStation
end

function CraftingService.GetPlayerWorkbenchTier(player: Player, includePingTolerance: boolean?): number
	local _, hrp = SecurityService.GetAliveCharacterRoot(player)
	if not hrp then
		return 0
	end

	local radius = Config.WORKBENCH_RADIUS + (if includePingTolerance == true then Types.PING_DISTANCE_TOLERANCE else 0)
	local bestTier = 0

	for _, entry in stations do
		if entry.Tier > bestTier and canPlayerUseStation(player, entry) then
			if (hrp.Position - entry.Position).Magnitude <= radius then
				bestTier = entry.Tier
			end
		end
	end

	for _, entry in dynamicStations do
		if entry.Tier > bestTier and canPlayerUseStation(player, entry) then
			if (hrp.Position - entry.Position).Magnitude <= radius then
				bestTier = entry.Tier
			end
		end
	end

	return bestTier
end

local function hasNearbyStation(player: Player, stationType: string, includePingTolerance: boolean?): boolean
	local _, hrp = SecurityService.GetAliveCharacterRoot(player)
	if not hrp then
		return false
	end

	local pingPad = if includePingTolerance == false then 0 else Types.PING_DISTANCE_TOLERANCE
	local maxDistance = Config.WORKBENCH_RADIUS + pingPad

	for _, entry in stations do
		if canPlayerUseStation(player, entry) and doesStationSatisfy(entry.StationType, stationType) then
			if (hrp.Position - entry.Position).Magnitude <= maxDistance then
				return true
			end
		end
	end

	for _, entry in dynamicStations do
		if canPlayerUseStation(player, entry) and doesStationSatisfy(entry.StationType, stationType) then
			if (hrp.Position - entry.Position).Magnitude <= maxDistance then
				return true
			end
		end
	end

	return false
end

local function cancelCraftInternal(player: Player, syncClient: boolean)
	local active = activeCrafts[player]
	if active == nil then
		return
	end

	activeCrafts[player] = nil
	if
		active.DelayThread ~= nil
		and active.DelayThread ~= coroutine.running()
		and coroutine.status(active.DelayThread) == "suspended"
	then
		pcall(task.cancel, active.DelayThread)
	end
	active.DelayThread = nil
	InventoryService.AddItems(player, active.ConsumedIngredients)

	if syncClient and player.Parent == Players then
		local syncEvent = Net.GetEvent(Net.Events.CraftStateSync)
		syncEvent:FireClient(player, nil)
	end
end

function CraftingService.CancelCraftForPlayer(player: Player, syncClient: boolean, bypassLock: boolean?)
	if bypassLock == true then
		cancelCraftInternal(player, syncClient)
		return
	end
	SecurityService.RunLocked(player, "CraftCancel", function()
		cancelCraftInternal(player, syncClient)
	end)
end

local function onCraftRequest(player: Player, recipeIdAny: any)
	if not SecurityService.CheckRateLimit(player, Net.Events.CraftRequest) then
		return
	end
	if not SecurityService.IsValidString(recipeIdAny, 1, 64) then
		return
	end

	local recipe = Recipes[recipeIdAny :: string]
	if not recipe then
		return
	end

	if DataService.IsTeleporting(player) or SecurityService.IsTransactionLocked(player) then
		return
	end
	if DataService.GetData(player) == nil then
		return
	end
	if SecurityService.GetAliveCharacterRoot(player) == nil then
		return
	end

	SecurityService.RunLocked(player, "CraftRequest", function()
		if activeCrafts[player] ~= nil or DataService.GetData(player) == nil then
			return
		end
		if SecurityService.GetAliveCharacterRoot(player) == nil then
			return
		end
		if recipe.RequiredWorkbench > 0 then
			if CraftingService.GetPlayerWorkbenchTier(player, true) < recipe.RequiredWorkbench then
				return
			end
		elseif recipe.Station ~= nil and not hasNearbyStation(player, recipe.Station, true) then
			return
		end
		if not BlueprintService.CanCraftRecipe(player, recipe.Id) then
			return
		end
		if
			not InventoryService.CanCraftTransaction(player, recipe.Ingredients, recipe.ResultId, recipe.ResultCount)
		then
			return
		end
		if not InventoryService.RemoveItems(player, recipe.Ingredients) then
			return
		end

		nextToken += 1
		local token = nextToken
		local startTime = Workspace:GetServerTimeNow()
		local endTime = startTime + recipe.CraftTime

		local consumed: { Ingredient } = {}
		for _, ing in recipe.Ingredients do
			table.insert(consumed, {
				Id = ing.Id,
				Count = ing.Count,
			})
		end

		local craftRecord: ActiveCraft = {
			Token = token,
			RecipeId = recipe.Id,
			StartTime = startTime,
			EndTime = endTime,
			ConsumedIngredients = consumed,
			DelayThread = nil,
		}
		activeCrafts[player] = craftRecord

		local statePayload: CraftingState = {
			RecipeId = recipe.Id,
			StartTime = startTime,
			EndTime = endTime,
		}
		Net.GetEvent(Net.Events.CraftStateSync):FireClient(player, statePayload)

		craftRecord.DelayThread = task.delay(recipe.CraftTime, function()
			craftRecord.DelayThread = nil
			local current = activeCrafts[player]
			if current == nil or current.Token ~= token then
				return
			end

			if player.Parent ~= Players or DataService.GetData(player) == nil then
				activeCrafts[player] = nil
				return
			end

			if
				DataService.IsTeleporting(player)
				or SecurityService.IsTeleportLocked(player)
				or SecurityService.GetAliveCharacterRoot(player) == nil
			then
				CraftingService.CancelCraftForPlayer(player, true, false)
				return
			end

			SecurityService.RunLocked(player, "CraftComplete", function()
				local latest = activeCrafts[player]
				if latest == nil or latest.Token ~= token then
					return
				end
				activeCrafts[player] = nil
				if player.Parent == Players and DataService.GetData(player) ~= nil then
					local remainder = InventoryService.AddItem(player, recipe.ResultId, recipe.ResultCount)
					if remainder > 0 then
						local addedCount = recipe.ResultCount - remainder
						if addedCount > 0 then
							InventoryService.RemoveItem(player, recipe.ResultId, addedCount)
						end
						InventoryService.AddItems(player, latest.ConsumedIngredients)
					end
					Net.GetEvent(Net.Events.CraftStateSync):FireClient(player, nil)
				end
			end)
		end)
	end)
end

local function onCraftCancel(player: Player)
	if not SecurityService.CheckRateLimit(player, Net.Events.CraftCancel) then
		return
	end
	if DataService.IsTeleporting(player) or SecurityService.IsTransactionLocked(player) then
		return
	end
	if SecurityService.GetAliveCharacterRoot(player) == nil then
		return
	end
	CraftingService.CancelCraftForPlayer(player, true, false)
end

function CraftingService.RegisterStation(
	stationId: string,
	stationType: string,
	position: Vector3,
	ownerUserId: number?
)
	if typeof(stationId) ~= "string" or #stationId == 0 or typeof(stationType) ~= "string" or #stationType == 0 then
		return
	end
	dynamicStations[stationId] = {
		StationType = stationType,
		Tier = resolveStationTier(stationType),
		Position = position,
		OwnerUserId = ownerUserId,
	}
end

function CraftingService.UnregisterStation(stationId: string)
	dynamicStations[stationId] = nil
end

function CraftingService.GetActiveCraft(player: Player): CraftingState?
	local active = activeCrafts[player]
	if not active then
		return nil
	end
	return {
		RecipeId = active.RecipeId,
		StartTime = active.StartTime,
		EndTime = active.EndTime,
	}
end

local function syncWorkbenchAttribute(player: Player)
	local tier = CraftingService.GetPlayerWorkbenchTier(player, false)
	if lastSyncedTierByPlayer[player] ~= tier then
		lastSyncedTierByPlayer[player] = tier
		player:SetAttribute("WorkbenchTier", tier)
	end

	local nearCampfire = hasNearbyStation(player, "campfire", false)
	if lastSyncedCampfireByPlayer[player] ~= nearCampfire then
		lastSyncedCampfireByPlayer[player] = nearCampfire
		player:SetAttribute("NearCampfire", nearCampfire)
	end
end

local function bindCraftPlayerLifecycle(player: Player)
	if playerCraftConnections[player] ~= nil then
		return
	end
	local conns: { RBXScriptConnection } = {}
	playerCraftConnections[player] = conns

	local function bindCharacter(character: Model)
		local humanoid = character:FindFirstChildOfClass("Humanoid") or character:WaitForChild("Humanoid", 5)
		if humanoid and humanoid:IsA("Humanoid") and playerCraftConnections[player] == conns then
			table.insert(
				conns,
				humanoid.Died:Connect(function()
					CraftingService.CancelCraftForPlayer(player, true, false)
				end)
			)
		end
	end

	table.insert(
		conns,
		player.CharacterAdded:Connect(function(character: Model)
			task.spawn(bindCharacter, character)
		end)
	)
	table.insert(
		conns,
		player.CharacterRemoving:Connect(function()
			CraftingService.CancelCraftForPlayer(player, true, false)
		end)
	)
	if player.Character ~= nil then
		task.spawn(bindCharacter, player.Character)
	end
end

function CraftingService.Init()
	if isInitialized then
		return
	end
	isInitialized = true

	Net.InitServer()
	scanWorkbenches()

	Net.GetEvent(Net.Events.CraftRequest).OnServerEvent:Connect(onCraftRequest)
	Net.GetEvent(Net.Events.CraftCancel).OnServerEvent:Connect(onCraftCancel)

	DataService.OnBeforeUnload(function(player: Player, _data: Types.PlayerData)
		CraftingService.CancelCraftForPlayer(player, false, true)
	end)

	for _, player in Players:GetPlayers() do
		lastSyncedTierByPlayer[player] = 0
		lastSyncedCampfireByPlayer[player] = false
		player:SetAttribute("WorkbenchTier", 0)
		player:SetAttribute("NearCampfire", false)
		bindCraftPlayerLifecycle(player)
	end

	Players.PlayerAdded:Connect(function(player: Player)
		lastSyncedTierByPlayer[player] = 0
		lastSyncedCampfireByPlayer[player] = false
		player:SetAttribute("WorkbenchTier", 0)
		player:SetAttribute("NearCampfire", false)
		bindCraftPlayerLifecycle(player)
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		local conns = playerCraftConnections[player]
		if conns ~= nil then
			for _, conn in conns do
				conn:Disconnect()
			end
			playerCraftConnections[player] = nil
		end
		CraftingService.CancelCraftForPlayer(player, false, true)
		lastSyncedTierByPlayer[player] = nil
		lastSyncedCampfireByPlayer[player] = nil
	end)

	task.spawn(function()
		while true do
			task.wait(WORKBENCH_SYNC_INTERVAL)
			for _, player in Players:GetPlayers() do
				syncWorkbenchAttribute(player)
			end
		end
	end)
end

return CraftingService
