--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage.Shared.Config)

print(`[Server] {Config.Game.Name} started`)

local servicesFolder = script:FindFirstChild("Services")
if servicesFolder then
	for _, module in servicesFolder:GetChildren() do
		if module:IsA("ModuleScript") then
			local ok, service = pcall(require, module)
			if ok and type(service) == "table" and service.Init then
				service.Init()
			elseif not ok then
				warn(`[Server] failed to load {module.Name}: {service}`)
			end
		end
	end
end
