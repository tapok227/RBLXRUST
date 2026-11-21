--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage.Shared.Config)

print(string.format("[Server] %s started", Config.Game.Name))

local servicesFolder = script:FindFirstChild("Services")
if servicesFolder then
	for _, module in servicesFolder:GetChildren() do
		if module:IsA("ModuleScript") then
			local ok, service = pcall(require, module)
			if ok and type(service) == "table" and service.Init then
				service.Init()
			elseif not ok then
				warn(string.format("[Server] failed to load %s: %s", module.Name, tostring(service)))
			end
		end
	end
end
