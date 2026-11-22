--!strict
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

export type SpawnOptions = {
	Id: string,
	Origin: Vector3,
	InitialVelocity: Vector3,
	Gravity: number,
	MaxLifetime: number,
	ExcludeInstances: { Instance }?,
	OnStep: ((position: Vector3, velocity: Vector3, elapsed: number) -> ())?,
	OnHit: ((hitResult: RaycastResult, velocity: Vector3, elapsed: number) -> ())?,
	OnExpire: ((position: Vector3, velocity: Vector3) -> ())?,
}

type ActiveProjectile = {
	Id: string,
	Origin: Vector3,
	InitialVelocity: Vector3,
	GravityVec: Vector3,
	MaxLifetime: number,
	Elapsed: number,
	CurrentPosition: Vector3,
	ExcludeInstances: { Instance },
	OnStep: ((position: Vector3, velocity: Vector3, elapsed: number) -> ())?,
	OnHit: ((hitResult: RaycastResult, velocity: Vector3, elapsed: number) -> ())?,
	OnExpire: ((position: Vector3, velocity: Vector3) -> ())?,
	Active: boolean,
}

local MAX_STEP_DT = 0.1
local MAX_SEGMENT_FILTER_PASSES = 6

local activeProjectiles: { [string]: ActiveProjectile } = {}
local activeCount = 0
local heartbeatConnection: RBXScriptConnection? = nil

local Ballistics = {}

local function findCharacterModel(inst: Instance): Model?
	local current: Instance? = inst
	while current ~= nil and current ~= Workspace do
		if current:IsA("Model") then
			if current:FindFirstChildOfClass("Humanoid") ~= nil then
				return current
			end
		end
		current = current.Parent
	end
	return nil
end

local function castSegment(origin: Vector3, delta: Vector3, baseExclude: { Instance }): RaycastResult?
	if delta.Magnitude <= 1e-4 then
		return nil
	end

	local excludeCopy: { Instance } = table.clone(baseExclude)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.IgnoreWater = true
	params.FilterDescendantsInstances = excludeCopy

	for _ = 1, MAX_SEGMENT_FILTER_PASSES do
		local result = Workspace:Raycast(origin, delta, params)
		if result == nil then
			return nil
		end

		if findCharacterModel(result.Instance) ~= nil then
			return result
		end

		if result.Instance.CanCollide == false and not result.Instance:IsA("Terrain") then
			table.insert(excludeCopy, result.Instance)
			params.FilterDescendantsInstances = excludeCopy
		else
			return result
		end
	end

	return nil
end

local function disconnectHeartbeatIfEmpty()
	if activeCount <= 0 and heartbeatConnection ~= nil then
		heartbeatConnection:Disconnect()
		heartbeatConnection = nil
	end
end

local function removeProjectile(proj: ActiveProjectile)
	if not proj.Active then
		return
	end
	proj.Active = false
	if activeProjectiles[proj.Id] == proj then
		activeProjectiles[proj.Id] = nil
		activeCount = math.max(0, activeCount - 1)
	end
end

local function onHeartbeat(dt: number)
	if activeCount <= 0 then
		disconnectHeartbeatIfEmpty()
		return
	end

	local stepDt = math.min(math.max(dt, 0), MAX_STEP_DT)
	if stepDt <= 0 then
		return
	end

	local snapshot: { ActiveProjectile } = {}
	for _, proj in activeProjectiles do
		if proj.Active then
			table.insert(snapshot, proj)
		end
	end

	for _, proj in snapshot do
		if not proj.Active then
			continue
		end

		local prevPos = proj.CurrentPosition
		local nextElapsed = math.min(proj.Elapsed + stepDt, proj.MaxLifetime)
		local nextPos = Ballistics.ComputePosition(proj.Origin, proj.InitialVelocity, proj.GravityVec, nextElapsed)
		local nextVel = Ballistics.ComputeVelocity(proj.InitialVelocity, proj.GravityVec, nextElapsed)

		local segmentDelta = nextPos - prevPos
		local hitResult = castSegment(prevPos, segmentDelta, proj.ExcludeInstances)

		if hitResult ~= nil then
			removeProjectile(proj)
			if proj.OnHit ~= nil then
				local ok, err = pcall(proj.OnHit, hitResult, nextVel, nextElapsed)
				if not ok then
					warn(string.format("[Ballistics] OnHit callback error (%s): %s", proj.Id, tostring(err)))
				end
			end
		elseif nextElapsed >= proj.MaxLifetime then
			removeProjectile(proj)
			if proj.OnExpire ~= nil then
				local ok, err = pcall(proj.OnExpire, nextPos, nextVel)
				if not ok then
					warn(string.format("[Ballistics] OnExpire callback error (%s): %s", proj.Id, tostring(err)))
				end
			end
		else
			proj.Elapsed = nextElapsed
			proj.CurrentPosition = nextPos
			if proj.OnStep ~= nil then
				local ok, err = pcall(proj.OnStep, nextPos, nextVel, nextElapsed)
				if not ok then
					warn(string.format("[Ballistics] OnStep callback error (%s): %s", proj.Id, tostring(err)))
				end
			end
		end
	end

	disconnectHeartbeatIfEmpty()
end

local function ensureHeartbeatConnected()
	if heartbeatConnection == nil then
		heartbeatConnection = RunService.Heartbeat:Connect(onHeartbeat)
	end
end

function Ballistics.ComputePosition(
	origin: Vector3,
	initialVelocity: Vector3,
	gravity: Vector3,
	elapsed: number
): Vector3
	return origin + initialVelocity * elapsed + gravity * (0.5 * elapsed * elapsed)
end

function Ballistics.ComputeVelocity(initialVelocity: Vector3, gravity: Vector3, elapsed: number): Vector3
	return initialVelocity + gravity * elapsed
end

function Ballistics.ComputeCFrame(position: Vector3, velocity: Vector3): CFrame
	if velocity.Magnitude > 1e-4 then
		return CFrame.lookAt(position, position + velocity)
	end
	return CFrame.new(position)
end

function Ballistics.Spawn(options: SpawnOptions): string
	if activeProjectiles[options.Id] ~= nil then
		removeProjectile(activeProjectiles[options.Id])
	end

	local excludeCopy: { Instance } = {}
	if options.ExcludeInstances ~= nil then
		for _, inst in options.ExcludeInstances do
			table.insert(excludeCopy, inst)
		end
	end

	local proj: ActiveProjectile = {
		Id = options.Id,
		Origin = options.Origin,
		InitialVelocity = options.InitialVelocity,
		GravityVec = Vector3.new(0, -math.max(0, options.Gravity), 0),
		MaxLifetime = math.max(0.05, options.MaxLifetime),
		Elapsed = 0,
		CurrentPosition = options.Origin,
		ExcludeInstances = excludeCopy,
		OnStep = options.OnStep,
		OnHit = options.OnHit,
		OnExpire = options.OnExpire,
		Active = true,
	}

	activeProjectiles[options.Id] = proj
	activeCount += 1
	ensureHeartbeatConnected()

	if options.OnStep ~= nil then
		local ok, err = pcall(options.OnStep, options.Origin, options.InitialVelocity, 0)
		if not ok then
			warn(string.format("[Ballistics] Initial OnStep error (%s): %s", options.Id, tostring(err)))
		end
	end

	return options.Id
end

function Ballistics.Cancel(projectileId: string): boolean
	local proj = activeProjectiles[projectileId]
	if proj == nil then
		return false
	end
	removeProjectile(proj)
	disconnectHeartbeatIfEmpty()
	return true
end

function Ballistics.GetActiveCount(): number
	return activeCount
end

return Ballistics
