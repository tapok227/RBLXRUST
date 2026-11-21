--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage.Shared.Config)

print(string.format("[Client] %s started", Config.Game.Name))

local controllersFolder = script:FindFirstChild("Controllers")
if controllersFolder then
	for _, module in controllersFolder:GetChildren() do
		if module:IsA("ModuleScript") then
			local ok, controller = pcall(require, module)
			if ok and type(controller) == "table" and controller.Init then
				controller.Init()
			elseif not ok then
				warn(string.format("[Client] failed to load %s: %s", module.Name, tostring(controller)))
			end
		end
	end
end
