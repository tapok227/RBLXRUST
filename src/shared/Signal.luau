--!strict

export type Connection = {
	Connected: boolean,
	Disconnect: (self: Connection) -> (),
}

export type Signal<T...> = {
	Connect: (self: Signal<T...>, fn: (T...) -> ()) -> Connection,
	Once: (self: Signal<T...>, fn: (T...) -> ()) -> Connection,
	Fire: (self: Signal<T...>, T...) -> (),
	Destroy: (self: Signal<T...>) -> (),
}

type InternalConnection = {
	Connected: boolean,
	Callback: (...any) -> (),
	Disconnect: (self: InternalConnection) -> (),
}

local Signal = {}

function Signal.new<T...>(): Signal<T...>
	local connections: { InternalConnection } = {}
	local destroyed = false

	local signal = {}

	function signal:Connect(fn: (T...) -> ()): Connection
		if destroyed then
			local noop: Connection = {
				Connected = false,
				Disconnect = function() end,
			}
			return noop
		end

		local conn: InternalConnection
		conn = {
			Connected = true,
			Callback = fn :: (...any) -> (),
			Disconnect = function(c: InternalConnection)
				if not c.Connected then
					return
				end
				c.Connected = false
				local idx = table.find(connections, c)
				if idx then
					table.remove(connections, idx)
				end
			end,
		}

		table.insert(connections, conn)
		return conn :: any
	end

	function signal:Once(fn: (T...) -> ()): Connection
		local conn: Connection
		conn = self:Connect(function(...: T...)
			conn:Disconnect()
			fn(...)
		end)
		return conn
	end

	function signal:Fire(...: T...)
		if destroyed or #connections == 0 then
			return
		end
		local snapshot = table.clone(connections)
		for _, conn in snapshot do
			if conn.Connected then
				task.spawn(conn.Callback, ...)
			end
		end
	end

	function signal:Destroy()
		destroyed = true
		for _, conn in connections do
			conn.Connected = false
		end
		table.clear(connections)
	end

	return (signal :: any) :: Signal<T...>
end

return Signal
