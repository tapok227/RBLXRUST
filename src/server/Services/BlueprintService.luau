--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)
local Types = require(ReplicatedStorage.Shared.Types)
local Items = require(ReplicatedStorage.Shared.configs.Items)
local Recipes = require(ReplicatedStorage.Shared.configs.Recipes)
local Net = require(ReplicatedStorage.Shared.Net)
local DataService = require(ServerScriptService.Server.Services.DataService)
local InventoryService = require(ServerScriptService.Server.Services.InventoryService)
local SecurityService = require(ServerScriptService.Server.Services.SecurityService)

type RecipeConfig = Types.RecipeConfig
type ResearchTableState = Types.ResearchTableState
type ResearchFeedback = Types.ResearchFeedback

type RegisteredTable = {
	TableId: string,
	Model: Model,
	OwnerUserId: number?,
}

local recipeByResultId: { [string]: RecipeConfig } = {}
for _, recipe in Recipes do
	recipeByResultId[recipe.ResultId] = recipe
end

local registeredTables: { [string]: RegisteredTable } = {}
local isInitialized = false

local BlueprintService = {}

local function sendFeedback(player: Player, success: boolean, message: string, recipeId: string?)
	if player.Parent ~= Players then
		return
	end
	local payload: ResearchFeedback = {
		Success = success,
		Message = message,
		RecipeId = recipeId,
	}
	Net.GetEvent(Net.Events.ResearchFeedback):FireClient(player, payload)
end

function BlueprintService.FindRecipeByItemId(itemId: string): RecipeConfig?
	if typeof(itemId) ~= "string" or #itemId == 0 then
		return nil
	end
	if string.sub(itemId, 1, 3) == "bp_" then
		return recipeByResultId[string.sub(itemId, 4)]
	end
	return recipeByResultId[itemId]
end

function BlueprintService.HasBlueprint(player: Player, recipeId: string): boolean
	local recipe = Recipes[recipeId]
	if recipe == nil then
		return false
	end
	if not recipe.RequiresBlueprint then
		return true
	end
	local data = DataService.GetData(player)
	if data == nil or type(data.UnlockedBlueprints) ~= "table" then
		return false
	end
	return data.UnlockedBlueprints[recipeId] == true
end

function BlueprintService.CanCraftRecipe(player: Player, recipeId: string): boolean
	local recipe = Recipes[recipeId]
	if recipe == nil then
		return false
	end
	if not recipe.RequiresBlueprint then
		return true
	end
	return BlueprintService.HasBlueprint(player, recipeId)
end

function BlueprintService.SyncBlueprints(player: Player)
	if player.Parent ~= Players then
		return
	end
	local data = DataService.GetData(player)
	local payload: { [string]: boolean } = {}
	if data ~= nil and type(data.UnlockedBlueprints) == "table" then
		for k, v in data.UnlockedBlueprints do
			if v == true and Recipes[k] ~= nil then
				payload[k] = true
			end
		end
	end
	Net.GetEvent(Net.Events.BlueprintSync):FireClient(player, payload)
end

function BlueprintService.UnlockBlueprint(player: Player, recipeId: string): boolean
	local recipe = Recipes[recipeId]
	if recipe == nil or not recipe.RequiresBlueprint then
		return false
	end
	local data = DataService.GetData(player)
	if data == nil then
		return false
	end
	if type(data.UnlockedBlueprints) ~= "table" then
		data.UnlockedBlueprints = {}
	end
	if data.UnlockedBlueprints[recipeId] == true then
		return false
	end
	data.UnlockedBlueprints[recipeId] = true
	BlueprintService.SyncBlueprints(player)
	return true
end

function BlueprintService.RegisterResearchTable(tableId: string, model: Model, ownerUserId: number?)
	if typeof(tableId) ~= "string" or #tableId == 0 or not model:IsA("Model") then
		return
	end
	local primary = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart", true)
	if not primary then
		warn(string.format('[BlueprintService] ResearchTable "%s" has no BasePart', model.Name))
		return
	end
	if model.PrimaryPart == nil then
		model.PrimaryPart = primary
	end

	registeredTables[tableId] = {
		TableId = tableId,
		Model = model,
		OwnerUserId = ownerUserId,
	}

	local prompt = primary:FindFirstChild("ResearchTablePrompt")
	if not (prompt and prompt:IsA("ProximityPrompt")) then
		local existingPrompt = model:FindFirstChildWhichIsA("ProximityPrompt", true)
		if existingPrompt then
			prompt = existingPrompt
		else
			local created = Instance.new("ProximityPrompt")
			created.Name = "ResearchTablePrompt"
			created.ActionText = "Open Research Table"
			created.ObjectText = "Research Table"
			created.HoldDuration = 0
			created.MaxActivationDistance = 10
			created.RequiresLineOfSight = false
			created.Parent = primary
			prompt = created
		end
	end

	if prompt and prompt:IsA("ProximityPrompt") and prompt:GetAttribute("ResearchPromptBound") ~= true then
		prompt:SetAttribute("ResearchPromptBound", true)
		prompt.Triggered:Connect(function(triggerPlayer: Player)
			local rec = registeredTables[tableId]
			if rec == nil or rec.Model.Parent == nil then
				return
			end
			if DataService.IsTeleporting(triggerPlayer) or SecurityService.IsTeleportLocked(triggerPlayer) then
				return
			end
			if rec.OwnerUserId ~= nil and rec.OwnerUserId ~= triggerPlayer.UserId then
				sendFeedback(triggerPlayer, false, "This Research Table belongs to another player", nil)
				return
			end
			local part = rec.Model.PrimaryPart or rec.Model:FindFirstChildWhichIsA("BasePart", true)
			if not part then
				return
			end
			local maxDist = Config.Research.InteractDistance + Types.PING_DISTANCE_TOLERANCE
			if not SecurityService.IsWithinDistance(triggerPlayer, part.Position, maxDist) then
				return
			end
			local openState: ResearchTableState = {
				TableId = tableId,
				Name = "Research Table",
				Position = part.Position,
			}
			Net.GetEvent(Net.Events.ResearchTableOpen):FireClient(triggerPlayer, openState)
		end)
	end
end

function BlueprintService.UnregisterResearchTable(tableId: string)
	registeredTables[tableId] = nil
end

local function onResearchItemRequest(player: Player, tableIdAny: any, slotIndexAny: any)
	if not SecurityService.CheckRateLimit(player, Net.Events.ResearchItemRequest) then
		return
	end
	if
		DataService.IsTeleporting(player)
		or SecurityService.IsTeleportLocked(player)
		or SecurityService.IsTransactionLocked(player)
	then
		return
	end
	if not SecurityService.IsValidString(tableIdAny, 1, 128) then
		return
	end
	if not SecurityService.IsValidInteger(slotIndexAny, 1, Types.INVENTORY_SIZE) then
		return
	end
	if DataService.GetData(player) == nil or SecurityService.GetAliveCharacterRoot(player) == nil then
		return
	end

	local tableId = tableIdAny :: string
	local slotIndex = math.floor(slotIndexAny :: number)
	local rec = registeredTables[tableId]
	if rec == nil or rec.Model.Parent == nil then
		registeredTables[tableId] = nil
		sendFeedback(player, false, "Research Table unavailable", nil)
		return
	end
	if rec.OwnerUserId ~= nil and rec.OwnerUserId ~= player.UserId then
		sendFeedback(player, false, "This Research Table belongs to another player", nil)
		return
	end
	local part = rec.Model.PrimaryPart or rec.Model:FindFirstChildWhichIsA("BasePart", true)
	if not part then
		return
	end
	local maxDist = Config.Research.InteractDistance + Types.PING_DISTANCE_TOLERANCE
	if not SecurityService.IsWithinDistance(player, part.Position, maxDist) then
		sendFeedback(player, false, "Move closer to the Research Table", nil)
		return
	end

	SecurityService.RunLocked(player, "ResearchItem", function()
		local latest = registeredTables[tableId]
		if latest == nil or latest.Model.Parent == nil then
			sendFeedback(player, false, "Research Table unavailable", nil)
			return
		end
		if DataService.GetData(player) == nil or SecurityService.GetAliveCharacterRoot(player) == nil then
			return
		end
		if not SecurityService.IsWithinDistance(player, part.Position, maxDist) then
			sendFeedback(player, false, "Move closer to the Research Table", nil)
			return
		end

		local slot = InventoryService.GetSlot(player, slotIndex)
		if slot == nil or slot.Count <= 0 then
			sendFeedback(player, false, "Selected slot is empty", nil)
			return
		end

		local itemCfg = Items[slot.Id]
		if itemCfg ~= nil and itemCfg.Type == "Blueprint" then
			sendFeedback(player, false, "Use Blueprint directly from inventory", nil)
			return
		end

		local recipe = recipeByResultId[slot.Id]
		if recipe == nil or not recipe.RequiresBlueprint then
			sendFeedback(player, false, "This item does not require a blueprint", nil)
			return
		end

		if BlueprintService.HasBlueprint(player, recipe.Id) then
			sendFeedback(player, false, "Blueprint already learned", recipe.Id)
			return
		end

		local cost = math.max(0, recipe.ResearchCost)
		if cost > 0 and InventoryService.GetItemCount(player, "scrap") < cost then
			sendFeedback(player, false, string.format("Need %d Scrap to research", cost), recipe.Id)
			return
		end

		if cost > 0 and not InventoryService.RemoveItem(player, "scrap", cost) then
			sendFeedback(player, false, string.format("Need %d Scrap to research", cost), recipe.Id)
			return
		end

		if not InventoryService.ConsumeSlot(player, slotIndex, 1) then
			if cost > 0 then
				InventoryService.AddItem(player, "scrap", cost)
			end
			sendFeedback(player, false, "Failed to consume researched item", recipe.Id)
			return
		end

		BlueprintService.UnlockBlueprint(player, recipe.Id)
		local resultCfg = Items[recipe.ResultId]
		local resultName = if resultCfg then resultCfg.Name else recipe.ResultId
		sendFeedback(player, true, string.format("Learned Blueprint: %s!", resultName), recipe.Id)
	end)
end

local function onLearnBlueprintRequest(player: Player, slotIndexAny: any)
	if not SecurityService.CheckRateLimit(player, Net.Events.LearnBlueprintRequest) then
		return
	end
	if
		DataService.IsTeleporting(player)
		or SecurityService.IsTeleportLocked(player)
		or SecurityService.IsTransactionLocked(player)
	then
		return
	end
	if not SecurityService.IsValidInteger(slotIndexAny, 1, Types.INVENTORY_SIZE) then
		return
	end
	if DataService.GetData(player) == nil or SecurityService.GetAliveCharacterRoot(player) == nil then
		return
	end

	local slotIndex = math.floor(slotIndexAny :: number)
	SecurityService.RunLocked(player, "LearnBlueprint", function()
		if DataService.GetData(player) == nil or SecurityService.GetAliveCharacterRoot(player) == nil then
			return
		end

		local slot = InventoryService.GetSlot(player, slotIndex)
		if slot == nil or slot.Count <= 0 then
			return
		end

		local itemCfg = Items[slot.Id]
		if itemCfg == nil or itemCfg.Type ~= "Blueprint" or string.sub(slot.Id, 1, 3) ~= "bp_" then
			return
		end

		local recipe = BlueprintService.FindRecipeByItemId(slot.Id)
		if recipe == nil or not recipe.RequiresBlueprint then
			sendFeedback(player, false, "Invalid blueprint item", nil)
			return
		end

		if BlueprintService.HasBlueprint(player, recipe.Id) then
			sendFeedback(player, false, "Blueprint already learned", recipe.Id)
			return
		end

		if not InventoryService.ConsumeSlot(player, slotIndex, 1) then
			return
		end

		BlueprintService.UnlockBlueprint(player, recipe.Id)
		local resultCfg = Items[recipe.ResultId]
		local resultName = if resultCfg then resultCfg.Name else recipe.ResultId
		sendFeedback(player, true, string.format("Learned Blueprint: %s!", resultName), recipe.Id)
	end)
end

local function scanStaticResearchTables()
	local scanRoots: { Instance? } = {
		Workspace:FindFirstChild("QA_TestArena"),
		Workspace:FindFirstChild("POI"),
		Workspace:FindFirstChild("Workbenches"),
	}
	local staticHub = Workspace:FindFirstChild("VendorHubZone")
	if staticHub and staticHub:GetAttribute("IsDynamicVendorHub") ~= true then
		table.insert(scanRoots, staticHub)
	end

	for _, root in scanRoots do
		if root ~= nil then
			for _, desc in root:GetDescendants() do
				if desc:IsA("Model") then
					local isTable = desc:GetAttribute("IsResearchTable") == true
						or desc:GetAttribute("StationType") == "research_table"
					if isTable then
						local idAttr = desc:GetAttribute("TableId")
						local tableId = if typeof(idAttr) == "string" and #idAttr > 0
							then idAttr
							else string.format("static_%s", desc:GetFullName())
						BlueprintService.RegisterResearchTable(tableId, desc, nil)
					end
				end
			end
		end
	end
end

function BlueprintService.Init()
	if isInitialized then
		return
	end
	isInitialized = true

	Net.InitServer()
	scanStaticResearchTables()

	Net.GetEvent(Net.Events.ResearchItemRequest).OnServerEvent:Connect(onResearchItemRequest)
	Net.GetEvent(Net.Events.LearnBlueprintRequest).OnServerEvent:Connect(onLearnBlueprintRequest)

	DataService.DataLoaded:Connect(function(player: Player, _data: Types.PlayerData)
		BlueprintService.SyncBlueprints(player)
	end)

	for _, player in Players:GetPlayers() do
		if DataService.GetData(player) ~= nil then
			BlueprintService.SyncBlueprints(player)
		end
	end
end

return BlueprintService
