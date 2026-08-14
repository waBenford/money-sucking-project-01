--!strict
--[[
	Trove
	A cleanup bag. Anything created that outlives a single statement goes in, and
	one clean() call disposes of all of it in reverse order.

	Written here rather than pulled in: this repo has no Wally manifest and no
	Packages folder, and the two dozen lines below are the whole of what the shop
	needs from Trove/Maid.

	Reverse order matters. A connection added after the instance it touches must
	be disconnected before that instance is destroyed, or the handler can fire
	once more against a half-torn-down view.

	Usage:
		local trove = Trove.new()
		trove:add(frame)
		trove:add(button.MouseButton1Click:Connect(onClick))
		trove:add(function() customTeardown() end)
		trove:clean()
]]

-- A function is included so callers can hand back state that is neither an
-- instance nor a connection -- a tween to cancel, a flag to reset.
export type Trackable = Instance | RBXScriptConnection | (() -> ())

local Trove = {}
Trove.__index = Trove

function Trove.new(): Trove
	return setmetatable({
		items = {},
		cleaned = false,
	}, Trove)
end

-- Returns what it was given, so a creation can be wrapped in place:
--     local frame = trove:add(Instance.new("Frame"))
function Trove.add<T>(self: Trove, item: T & Trackable): T
	if self.cleaned then
		-- Adding to a cleaned trove would leak the item silently, since nothing
		-- will ever clean it again. A caller doing this has a lifetime bug.
		warn("Trove: add() after clean() -- the item will never be disposed of")
	end

	table.insert(self.items, item)
	return item
end

function Trove.clean(self: Trove)
	-- Flagged before the loop: a teardown function that adds to this trove would
	-- otherwise append to the list being iterated.
	self.cleaned = true

	for index = #self.items, 1, -1 do
		local item = self.items[index]
		self.items[index] = nil

		if typeof(item) == "RBXScriptConnection" then
			item:Disconnect()
		elseif typeof(item) == "Instance" then
			item:Destroy()
		elseif type(item) == "function" then
			item()
		end
	end
end

-- Only for teardown assertions -- see the Trove check in the plan's
-- verification steps.
function Trove.count(self: Trove): number
	return #self.items
end

-- Declared after the methods so the alias covers all of them.
export type Trove = typeof(setmetatable(
	{} :: {
		items: { Trackable },
		cleaned: boolean,
	},
	Trove
))

return Trove
