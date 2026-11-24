--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage.Shared.Config)

print(string.format("[Server] %s started", Config.Game.Name))

local PRIORITY_SERVICES = {
	"SecurityService",
	"TeleportService",
	"DataService",
}

local servicesFolder = script:FindFirstChild("Services")
if servicesFolder then
	local initializedNames: { [string]: boolean } = {}
	for _, serviceName in PRIORITY_SERVICES do
		local module = servicesFolder:FindFirstChild(serviceName)
		if module and module:IsA("ModuleScript") then
			initializedNames[serviceName] = true
			local ok, service = pcall(require, module)
			if ok and type(service) == "table" and service.Init then
				service.Init()
			elseif not ok then
				warn(string.format("[Server] failed to load %s: %s", module.Name, tostring(service)))
			end
		end
	end

	for _, module in servicesFolder:GetChildren() do
		if module:IsA("ModuleScript") and not initializedNames[module.Name] then
			local ok, service = pcall(require, module)
			if ok and type(service) == "table" and service.Init then
				service.Init()
			elseif not ok then
				warn(string.format("[Server] failed to load %s: %s", module.Name, tostring(service)))
			end
		end
	end
end
