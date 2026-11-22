--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage.Shared.Types)
local Net = require(ReplicatedStorage.Shared.Net)

export type RateLimitRule = {
	Capacity: number,
	RefillPerSec: number,
	Category: string,
}

type TokenBucket = {
	Tokens: number,
	LastRefill: number,
}

type TransactionLock = {
	Reason: string,
	AcquiredAt: number,
}

type ActiveContainerRecord = {
	ContainerId: string,
	PrimaryPart: BasePart,
}

local DEFAULT_RULE: RateLimitRule = {
	Capacity = 5,
	RefillPerSec = 3,
	Category = "Default",
}

local LOG_THROTTLE_SECONDS = 2.0
local DEFAULT_MAX_COORD_ABS = 1e6

local RATE_LIMIT_RULES: { [string]: RateLimitRule } = table.freeze({
	-- Combat
	[Net.Events.AttackRequest] = table.freeze({ Capacity = 6, RefillPerSec = 5, Category = "Combat" }),
	[Net.Events.HitNode] = table.freeze({ Capacity = 5, RefillPerSec = 4, Category = "Combat" }),
	[Net.Events.PlaceExplosiveRequest] = table.freeze({ Capacity = 3, RefillPerSec = 1.5, Category = "Combat" }),

	-- Inventory
	[Net.Events.InventoryMove] = table.freeze({ Capacity = 12, RefillPerSec = 8, Category = "Inventory" }),
	[Net.Events.HotbarSelect] = table.freeze({ Capacity = 15, RefillPerSec = 12, Category = "Inventory" }),
	[Net.Events.LootTakeSlot] = table.freeze({ Capacity = 10, RefillPerSec = 6, Category = "Inventory" }),
	[Net.Events.ContainerDepositSlot] = table.freeze({ Capacity = 10, RefillPerSec = 6, Category = "Inventory" }),
	[Net.Events.UseConsumable] = table.freeze({ Capacity = 4, RefillPerSec = 2, Category = "Inventory" }),
	[Net.Events.CraftRequest] = table.freeze({ Capacity = 4, RefillPerSec = 2, Category = "Inventory" }),
	[Net.Events.CraftCancel] = table.freeze({ Capacity = 4, RefillPerSec = 2, Category = "Inventory" }),

	-- Building
	[Net.Events.BuildPlaceRequest] = table.freeze({ Capacity = 8, RefillPerSec = 4, Category = "Building" }),
	[Net.Events.BuildUpgradeRequest] = table.freeze({ Capacity = 8, RefillPerSec = 4, Category = "Building" }),
	[Net.Events.BuildDemolishRequest] = table.freeze({ Capacity = 8, RefillPerSec = 4, Category = "Building" }),

	-- UI
	[Net.Events.CloseContainer] = table.freeze({ Capacity = 8, RefillPerSec = 5, Category = "UI" }),
	[Net.Events.RaidListRequest] = table.freeze({ Capacity = 3, RefillPerSec = 1, Category = "UI" }),
	[Net.Events.StartRaidRequest] = table.freeze({ Capacity = 2, RefillPerSec = 0.5, Category = "UI" }),
	[Net.Events.RaidExtractRequest] = table.freeze({ Capacity = 2, RefillPerSec = 0.5, Category = "UI" }),
	[Net.Events.RequestReturnToMap] = table.freeze({ Capacity = 2, RefillPerSec = 0.5, Category = "UI" }),
})

local bucketsByUser: { [number]: { [string]: TokenBucket } } = {}
local lastWarnByUser: { [number]: { [string]: number } } = {}
local transactionLocks: { [number]: TransactionLock } = {}
local teleportLocks: { [number]: boolean } = {}
local activeContainers: { [number]: ActiveContainerRecord } = {}
local isInitialized = false

local SecurityService = {}

local function shouldLogWarning(userId: number, key: string, now: number): boolean
	local userWarns = lastWarnByUser[userId]
	if userWarns == nil then
		userWarns = {}
		lastWarnByUser[userId] = userWarns
	end
	local last = userWarns[key]
	if last ~= nil and (now - last) < LOG_THROTTLE_SECONDS then
		return false
	end
	userWarns[key] = now
	return true
end

function SecurityService.LogSuspicious(player: Player, remoteName: string, reason: string)
	local now = os.clock()
	local userId = player.UserId
	if shouldLogWarning(userId, string.format("susp:%s:%s", remoteName, reason), now) then
		warn(
			string.format(
				"[SecurityService] Suspicious call by %s (%d) on %s: %s",
				player.Name,
				userId,
				remoteName,
				reason
			)
		)
	end
end

function SecurityService.CheckRateLimit(player: Player, remoteName: string, cost: number?): boolean
	local rule = RATE_LIMIT_RULES[remoteName] or DEFAULT_RULE
	local tokenCost = if typeof(cost) == "number" and cost == cost and cost > 0 and cost < math.huge then cost else 1
	local now = os.clock()
	local userId = player.UserId

	local userBuckets = bucketsByUser[userId]
	if userBuckets == nil then
		userBuckets = {}
		bucketsByUser[userId] = userBuckets
	end

	local bucket = userBuckets[remoteName]
	if bucket == nil then
		bucket = {
			Tokens = rule.Capacity,
			LastRefill = now,
		}
		userBuckets[remoteName] = bucket
	else
		local dt = math.max(0, now - bucket.LastRefill)
		bucket.Tokens = math.min(rule.Capacity, bucket.Tokens + dt * rule.RefillPerSec)
		bucket.LastRefill = now
	end

	if bucket.Tokens < tokenCost then
		if shouldLogWarning(userId, string.format("rl:%s", remoteName), now) then
			warn(
				string.format(
					"[SecurityService] Rate limit exceeded: %s (%d) remote=%s category=%s",
					player.Name,
					userId,
					remoteName,
					rule.Category
				)
			)
		end
		return false
	end

	bucket.Tokens -= tokenCost
	return true
end

function SecurityService.GetRateLimitRules(): { [string]: RateLimitRule }
	local copy: { [string]: RateLimitRule } = {}
	for k, v in RATE_LIMIT_RULES do
		copy[k] = {
			Capacity = v.Capacity,
			RefillPerSec = v.RefillPerSec,
			Category = v.Category,
		}
	end
	return copy
end

function SecurityService.IsFiniteNumber(val: any): boolean
	return typeof(val) == "number" and val == val and math.abs(val) < math.huge
end

function SecurityService.IsValidInteger(val: any, minVal: number?, maxVal: number?): boolean
	if not SecurityService.IsFiniteNumber(val) then
		return false
	end
	local num = val :: number
	if num % 1 ~= 0 then
		return false
	end
	if minVal ~= nil and num < minVal then
		return false
	end
	if maxVal ~= nil and num > maxVal then
		return false
	end
	return true
end

function SecurityService.IsValidString(val: any, minLen: number?, maxLen: number?): boolean
	if typeof(val) ~= "string" then
		return false
	end
	local str = val :: string
	local lo = minLen or 1
	local hi = maxLen or 64
	return #str >= lo and #str <= hi
end

function SecurityService.IsValidVector3(val: any, maxCoordAbs: number?): boolean
	if typeof(val) ~= "Vector3" then
		return false
	end
	local vec = val :: Vector3
	local limit = maxCoordAbs or DEFAULT_MAX_COORD_ABS
	return vec.X == vec.X
		and vec.Y == vec.Y
		and vec.Z == vec.Z
		and math.abs(vec.X) < math.huge
		and math.abs(vec.Y) < math.huge
		and math.abs(vec.Z) < math.huge
		and math.abs(vec.X) <= limit
		and math.abs(vec.Y) <= limit
		and math.abs(vec.Z) <= limit
end

function SecurityService.GetAliveCharacterRoot(player: Player): (Model?, BasePart?, Humanoid?)
	if player.Parent ~= Players then
		return nil, nil, nil
	end
	local character = player.Character
	if not character then
		return nil, nil, nil
	end
	local hrp = character:FindFirstChild("HumanoidRootPart")
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if
		not hrp
		or not hrp:IsA("BasePart")
		or not humanoid
		or not SecurityService.IsFiniteNumber(humanoid.Health)
		or humanoid.Health <= 0
	then
		return nil, nil, nil
	end
	return character, hrp, humanoid
end

function SecurityService.IsWithinDistance(
	player: Player,
	targetPosition: Vector3,
	maxDistance: number,
	pingTolerance: number?
): boolean
	if not SecurityService.IsValidVector3(targetPosition) then
		return false
	end
	local _, hrp = SecurityService.GetAliveCharacterRoot(player)
	if not hrp then
		return false
	end
	local allowed = maxDistance + (pingTolerance or 0)
	return (hrp.Position - targetPosition).Magnitude <= allowed
end

function SecurityService.IsTeleportLocked(player: Player): boolean
	return teleportLocks[player.UserId] == true
end

function SecurityService.SetTeleportLock(player: Player, locked: boolean)
	if locked then
		teleportLocks[player.UserId] = true
	else
		teleportLocks[player.UserId] = nil
	end
end

function SecurityService.IsTransactionLocked(player: Player): boolean
	local userId = player.UserId
	return transactionLocks[userId] ~= nil or teleportLocks[userId] == true
end

function SecurityService.AcquireTransactionLock(player: Player, reason: string): boolean
	if SecurityService.IsTransactionLocked(player) then
		return false
	end
	transactionLocks[player.UserId] = {
		Reason = reason,
		AcquiredAt = os.clock(),
	}
	return true
end

function SecurityService.ReleaseTransactionLock(player: Player)
	transactionLocks[player.UserId] = nil
end

function SecurityService.RunLocked(player: Player, reason: string, fn: () -> ()): boolean
	if not SecurityService.AcquireTransactionLock(player, reason) then
		return false
	end
	local ok, err = pcall(fn)
	SecurityService.ReleaseTransactionLock(player)
	if not ok then
		warn(
			string.format(
				"[SecurityService] Locked transaction '%s' error for %s (%d): %s",
				reason,
				player.Name,
				player.UserId,
				tostring(err)
			)
		)
	end
	return ok
end

function SecurityService.SetActiveContainer(player: Player, containerId: string, primaryPart: BasePart)
	activeContainers[player.UserId] = {
		ContainerId = containerId,
		PrimaryPart = primaryPart,
	}
end

function SecurityService.ClearActiveContainer(player: Player, containerId: string?)
	local userId = player.UserId
	local current = activeContainers[userId]
	if current == nil then
		return
	end
	if containerId == nil or current.ContainerId == containerId then
		activeContainers[userId] = nil
	end
end

function SecurityService.IsActiveContainerOutOfRange(
	player: Player,
	maxDistance: number,
	pingTolerance: number?
): boolean
	local record = activeContainers[player.UserId]
	if record == nil then
		return false
	end
	if record.PrimaryPart.Parent == nil then
		return true
	end
	local _, hrp = SecurityService.GetAliveCharacterRoot(player)
	if not hrp then
		return true
	end
	local allowed = maxDistance + (pingTolerance or Types.PING_DISTANCE_TOLERANCE)
	return (hrp.Position - record.PrimaryPart.Position).Magnitude > allowed
end

function SecurityService.Init()
	if isInitialized then
		return
	end
	isInitialized = true

	Net.InitServer()

	Players.PlayerRemoving:Connect(function(player: Player)
		local userId = player.UserId
		bucketsByUser[userId] = nil
		lastWarnByUser[userId] = nil
		transactionLocks[userId] = nil
		teleportLocks[userId] = nil
		activeContainers[userId] = nil
	end)
end

return SecurityService
