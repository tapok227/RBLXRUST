--!strict

export type Janitor = {
	Add: <T>(self: Janitor, item: T, methodName: string?) -> T,
	Cleanup: (self: Janitor) -> (),
	Destroy: (self: Janitor) -> (),
}

type CleanupEntry = {
	Item: any,
	Method: string?,
}

local Janitor = {}

local function cleanupItem(item: any, methodName: string?)
	local itemTypeof = typeof(item)
	if itemTypeof == "RBXScriptConnection" then
		if item.Connected then
			item:Disconnect()
		end
		return
	elseif itemTypeof == "Instance" then
		item:Destroy()
		return
	end

	local itemType = type(item)
	if itemType == "function" then
		item()
	elseif itemType == "table" then
		if methodName ~= nil and type(item[methodName]) == "function" then
			item[methodName](item)
		elseif type(item.Disconnect) == "function" then
			item:Disconnect()
		elseif type(item.Destroy) == "function" then
			item:Destroy()
		elseif type(item.Cleanup) == "function" then
			item:Cleanup()
		end
	end
end

function Janitor.new(): Janitor
	local entries: { CleanupEntry } = {}
	local janitor = {}

	function janitor:Add<T>(item: T, methodName: string?): T
		table.insert(entries, {
			Item = item,
			Method = methodName,
		})
		return item
	end

	function janitor:Cleanup()
		for i = #entries, 1, -1 do
			local entry = entries[i]
			cleanupItem(entry.Item, entry.Method)
		end
		table.clear(entries)
	end

	function janitor:Destroy()
		self:Cleanup()
	end

	return (janitor :: any) :: Janitor
end

return Janitor
