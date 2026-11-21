--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Types = require(ReplicatedStorage.Shared.Types)
local Recipes = require(ReplicatedStorage.Shared.configs.Recipes)
local Net = require(ReplicatedStorage.Shared.Net)
local DataService = require(ServerScriptService.Server.Services.DataService)
local InventoryService = require(ServerScriptService.Server.Services.InventoryService)

type Ingredient = Types.Ingredient
type CraftingState = Types.CraftingState

type StationEntry = {
	StationType: string,
	Position: Vector3,
}

type ActiveCraft = {
	Token: number,
	RecipeId: string,
	StartTime: number,
	EndTime: number,
	ConsumedIngredients: { Ingredient },
	DelayThread: thread?,
}

local stations: { StationEntry } = {}
local dynamicStations: { [string]: StationEntry } = {}
local activeCrafts: { [Player]: ActiveCraft } = {}
local nextToken = 0
local isInitialized = false

local CraftingService = {}

local function scanWorkbenches()
	table.clear(stations)
	local folder = Workspace:FindFirstChild("Workbenches")
	if not folder then
		warn("[CraftingService] Workspace.Workbenches folder not found")
		return
	end

	for _, child in folder:GetChildren() do
		if child:IsA("Model") then
			local primaryPart = child.PrimaryPart
			local stationType = child:GetAttribute("StationType")
			if primaryPart and typeof(stationType) == "string" and #stationType > 0 then
				table.insert(stations, {
					StationType = stationType,
					Position = primaryPart.Position,
				})
			else
				warn(
					string.format(
						'[CraftingService] Workbench "%s" missing PrimaryPart or StationType attribute',
						child.Name
					)
				)
			end
		end
	end
end

local function hasNearbyStation(player: Player, stationType: string): boolean
	local character = player.Character
	local hrp = if character then character:FindFirstChild("HumanoidRootPart") else nil
	if not hrp or not hrp:IsA("BasePart") then
		return false
	end

	for _, entry in stations do
		if entry.StationType == stationType then
			if (hrp.Position - entry.Position).Magnitude <= Types.MAX_STATION_DISTANCE then
				return true
			end
		end
	end

	for _, entry in dynamicStations do
		if entry.StationType == stationType then
			if (hrp.Position - entry.Position).Magnitude <= Types.MAX_STATION_DISTANCE then
				return true
			end
		end
	end

	return false
end

local function cancelCraft(player: Player, syncClient: boolean)
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

local function onCraftRequest(player: Player, recipeIdAny: any)
	if typeof(recipeIdAny) ~= "string" or #recipeIdAny == 0 or #recipeIdAny > 64 then
		return
	end

	local recipe = Recipes[recipeIdAny]
	if not recipe then
		return
	end

	if activeCrafts[player] ~= nil then
		return
	end

	if DataService.GetData(player) == nil then
		return
	end

	if recipe.Station ~= nil and not hasNearbyStation(player, recipe.Station) then
		return
	end

	if not InventoryService.CanCraftTransaction(player, recipe.Ingredients, recipe.ResultId, recipe.ResultCount) then
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

		activeCrafts[player] = nil
		if player.Parent == Players and DataService.GetData(player) ~= nil then
			InventoryService.AddItem(player, recipe.ResultId, recipe.ResultCount)
			Net.GetEvent(Net.Events.CraftStateSync):FireClient(player, nil)
		end
	end)
end

local function onCraftCancel(player: Player)
	cancelCraft(player, true)
end

function CraftingService.RegisterStation(stationId: string, stationType: string, position: Vector3)
	if typeof(stationId) ~= "string" or #stationId == 0 or typeof(stationType) ~= "string" or #stationType == 0 then
		return
	end
	dynamicStations[stationId] = {
		StationType = stationType,
		Position = position,
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
		cancelCraft(player, false)
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		cancelCraft(player, false)
	end)
end

return CraftingService
