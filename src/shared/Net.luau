--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local REMOTES_FOLDER_NAME = "Remotes"

local Events = table.freeze({
	InventorySync = "InventorySync",
	InventoryMove = "InventoryMove",
	HotbarSelect = "HotbarSelect",
	HitNode = "HitNode",
	NodeUpdated = "NodeUpdated",
	CraftRequest = "CraftRequest",
	CraftCancel = "CraftCancel",
	CraftStateSync = "CraftStateSync",
	UseConsumable = "UseConsumable",
	OpenContainer = "OpenContainer",
	CloseContainer = "CloseContainer",
	LootTakeSlot = "LootTakeSlot",
	ContainerDepositSlot = "ContainerDepositSlot",
	AttackRequest = "AttackRequest",
	AttackEffect = "AttackEffect",
	WorldEventNotify = "WorldEventNotify",
	ExtractionStateSync = "ExtractionStateSync",
	RequestReturnToMap = "RequestReturnToMap",
	BuildPlaceRequest = "BuildPlaceRequest",
	BuildUpgradeRequest = "BuildUpgradeRequest",
	BuildDemolishRequest = "BuildDemolishRequest",
	BaseStateSync = "BaseStateSync",
	RaidListRequest = "RaidListRequest",
	RaidListSync = "RaidListSync",
	StartRaidRequest = "StartRaidRequest",
	PlaceExplosiveRequest = "PlaceExplosiveRequest",
	RaidHudSync = "RaidHudSync",
	RaidExtractRequest = "RaidExtractRequest",
	ProjectileSpawn = "ProjectileSpawn",
	ExplosionEffect = "ExplosionEffect",
})

local Net = {
	Events = Events,
}

local remotesFolder: Folder? = nil
local eventCache: { [string]: RemoteEvent } = {}

local function getOrCreateFolder(): Folder
	if remotesFolder and remotesFolder.Parent then
		return remotesFolder
	end

	if RunService:IsServer() then
		local existing = ReplicatedStorage:FindFirstChild(REMOTES_FOLDER_NAME)
		if existing and existing:IsA("Folder") then
			remotesFolder = existing
			return existing
		end
		local folder = Instance.new("Folder")
		folder.Name = REMOTES_FOLDER_NAME
		folder.Parent = ReplicatedStorage
		remotesFolder = folder
		return folder
	else
		local folder = ReplicatedStorage:WaitForChild(REMOTES_FOLDER_NAME) :: Folder
		remotesFolder = folder
		return folder
	end
end

function Net.InitServer()
	local folder = getOrCreateFolder()
	for _, eventName in Events do
		local existing = folder:FindFirstChild(eventName)
		if existing and existing:IsA("RemoteEvent") then
			eventCache[eventName] = existing
		elseif not existing then
			local remote = Instance.new("RemoteEvent")
			remote.Name = eventName
			remote.Parent = folder
			eventCache[eventName] = remote
		end
	end
end

function Net.GetEvent(eventName: string): RemoteEvent
	local cached = eventCache[eventName]
	if cached ~= nil and cached.Parent ~= nil then
		return cached
	end

	local folder = getOrCreateFolder()
	if RunService:IsServer() then
		local existing = folder:FindFirstChild(eventName)
		if existing and existing:IsA("RemoteEvent") then
			eventCache[eventName] = existing
			return existing
		end
		local remote = Instance.new("RemoteEvent")
		remote.Name = eventName
		remote.Parent = folder
		eventCache[eventName] = remote
		return remote
	else
		local remote = folder:WaitForChild(eventName) :: RemoteEvent
		eventCache[eventName] = remote
		return remote
	end
end

return Net
