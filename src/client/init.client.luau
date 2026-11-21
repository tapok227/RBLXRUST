--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage.Shared.Config)

print(`[Client] {Config.Game.Name} started`)

local controllersFolder = script:FindFirstChild("Controllers")
if controllersFolder then
	for _, module in controllersFolder:GetChildren() do
		if module:IsA("ModuleScript") then
			local ok, controller = pcall(require, module)
			if ok and type(controller) == "table" and controller.Init then
				controller.Init()
			elseif not ok then
				warn(`[Client] failed to load {module.Name}: {controller}`)
			end
		end
	end
end
