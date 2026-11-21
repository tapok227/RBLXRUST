--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Types = require(ReplicatedStorage.Shared.Types)
local Nodes = require(ReplicatedStorage.Shared.configs.Nodes)
local Tools = require(ReplicatedStorage.Shared.configs.Tools)
local Net = require(ReplicatedStorage.Shared.Net)
local DataService = require(ServerScriptService.Server.Services.DataService)
local InventoryService = require(ServerScriptService.Server.Services.InventoryService)

type PartSnapshot = {
	Part: BasePart,
	OriginalTransparency: number,
	OriginalCanCollide: boolean,
	OriginalCanQuery: boolean,
}

type ServerNodeState = {
	NodeId: string,
	NodeType: string,
	Model: Model,
	PrimaryPart: BasePart,
	Parts: { PartSnapshot },
	Hp: number,
	MaxHp: number,
	Position: Vector3,
	Depleted: boolean,
}

local nodesById: { [string]: ServerNodeState } = {}
local lastHitTime: { [Player]: number } = {}
local isInitialized = false

local ResourceService = {}

local function registerNode(model: Instance)
	if not model:IsA("Model") then
		return
	end

	local primaryPart = model.PrimaryPart
	if not primaryPart then
		warn(string.format('[ResourceService] Node model "%s" has no PrimaryPart', model.Name))
		return
	end

	local nodeId = model:GetAttribute("NodeId")
	local nodeType = model:GetAttribute("NodeType")
	if typeof(nodeId) ~= "string" or #nodeId == 0 or typeof(nodeType) ~= "string" then
		warn(string.format('[ResourceService] Node model "%s" missing valid NodeId/NodeType attributes', model.Name))
		return
	end

	local nodeConfig = Nodes[nodeType]
	if not nodeConfig then
		warn(string.format('[ResourceService] Unknown NodeType "%s" on "%s"', nodeType, model.Name))
		return
	end

	local parts: { PartSnapshot } = {}
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			table.insert(parts, {
				Part = descendant,
				OriginalTransparency = descendant.Transparency,
				OriginalCanCollide = descendant.CanCollide,
				OriginalCanQuery = descendant.CanQuery,
			})
		end
	end

	nodesById[nodeId] = {
		NodeId = nodeId,
		NodeType = nodeType,
		Model = model,
		PrimaryPart = primaryPart,
		Parts = parts,
		Hp = nodeConfig.MaxHp,
		MaxHp = nodeConfig.MaxHp,
		Position = primaryPart.Position,
		Depleted = false,
	}

	model:SetAttribute("Hp", nodeConfig.MaxHp)
	model:SetAttribute("Depleted", false)
end

local function depleteNode(node: ServerNodeState, respawnTime: number)
	node.Depleted = true
	node.Hp = 0
	node.Model:SetAttribute("Hp", 0)
	node.Model:SetAttribute("Depleted", true)

	for _, snapshot in node.Parts do
		snapshot.Part.Transparency = 1
		snapshot.Part.CanCollide = false
		snapshot.Part.CanQuery = false
	end

	local effectiveRespawnTime = respawnTime
	if RunService:IsStudio() then
		local override = node.Model:GetAttribute("RespawnTimeOverride")
		if typeof(override) == "number" and override == override and override > 0 and override < math.huge then
			effectiveRespawnTime = override
		end
	end

	task.delay(effectiveRespawnTime, function()
		if not node.Model.Parent then
			return
		end

		node.Hp = node.MaxHp
		node.Depleted = false
		node.Model:SetAttribute("Hp", node.Hp)
		node.Model:SetAttribute("Depleted", false)

		for _, snapshot in node.Parts do
			snapshot.Part.Transparency = snapshot.OriginalTransparency
			snapshot.Part.CanCollide = snapshot.OriginalCanCollide
			snapshot.Part.CanQuery = snapshot.OriginalCanQuery
		end

		local updatedEvent = Net.GetEvent(Net.Events.NodeUpdated)
		updatedEvent:FireAllClients(node.NodeId, node.Hp, node.MaxHp, false)
	end)
end

local function onHitNode(player: Player, nodeIdAny: any)
	if typeof(nodeIdAny) ~= "string" or #nodeIdAny == 0 or #nodeIdAny > 64 then
		return
	end

	local node = nodesById[nodeIdAny]
	if not node or node.Depleted then
		return
	end

	if DataService.GetData(player) == nil then
		return
	end

	local character = player.Character
	local hrp = if character then character:FindFirstChild("HumanoidRootPart") else nil
	local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
	if not hrp or not hrp:IsA("BasePart") or not humanoid or humanoid.Health <= 0 then
		return
	end

	if (hrp.Position - node.PrimaryPart.Position).Magnitude > Types.MAX_GATHER_DISTANCE_SERVER then
		return
	end

	local equipped = InventoryService.GetEquippedItem(player)
	local toolConfig = if equipped ~= nil then Tools[equipped.Id] else nil
	local basePower = if toolConfig ~= nil then toolConfig.Power else Types.HANDS_POWER
	local cooldown = if toolConfig ~= nil then toolConfig.Cooldown else Types.HANDS_COOLDOWN

	local now = os.clock()
	local prevHit = lastHitTime[player]
	if prevHit ~= nil and (now - prevHit) < cooldown then
		return
	end
	lastHitTime[player] = now

	local nodeConfig = Nodes[node.NodeType]
	local multiplier = if toolConfig ~= nil and toolConfig.PreferredNodeType == nodeConfig.Category
		then toolConfig.BonusMultiplier
		else Types.BASE_TOOL_MULTIPLIER

	local damage = basePower * multiplier
	local actualDamage = math.min(damage, node.Hp)
	local yieldAmount = math.max(1, math.floor(nodeConfig.YieldPerHit * (actualDamage / 25) + 0.5))

	node.Hp = math.max(0, node.Hp - actualDamage)
	node.Model:SetAttribute("Hp", node.Hp)

	local totalGrant = yieldAmount
	if node.Hp <= 0 then
		totalGrant += nodeConfig.BonusOnDestroy
		depleteNode(node, nodeConfig.RespawnTime)
	end

	InventoryService.AddItem(player, nodeConfig.ResourceId, totalGrant)

	local updatedEvent = Net.GetEvent(Net.Events.NodeUpdated)
	updatedEvent:FireAllClients(node.NodeId, node.Hp, node.MaxHp, node.Depleted)
end

function ResourceService.Init()
	if isInitialized then
		return
	end
	isInitialized = true

	Net.InitServer()

	local nodesFolder = Workspace:FindFirstChild("ResourceNodes")
	if nodesFolder then
		for _, child in nodesFolder:GetChildren() do
			registerNode(child)
		end
	else
		warn("[ResourceService] Workspace.ResourceNodes folder not found")
	end

	local hitEvent = Net.GetEvent(Net.Events.HitNode)
	hitEvent.OnServerEvent:Connect(onHitNode)

	Players.PlayerRemoving:Connect(function(player: Player)
		lastHitTime[player] = nil
	end)

	Players.PlayerAdded:Connect(function(player: Player)
		local updatedEvent = Net.GetEvent(Net.Events.NodeUpdated)
		for _, node in nodesById do
			if node.Depleted or node.Hp < node.MaxHp then
				updatedEvent:FireClient(player, node.NodeId, node.Hp, node.MaxHp, node.Depleted)
			end
		end
	end)
end

return ResourceService
