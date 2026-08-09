--[[
	InventoryConfig
	The inventory's capacity rules, in one place because both sides need them:
	InventoryService enforces them, the UI displays "n/20" and clamps its
	discard picker to the stack size.

	Shared, not server-only, on purpose. These are display numbers, not secrets
	-- a client that lies about them changes nothing, because every grant and
	discard is still checked against these same values on the server.

	One kind of item takes exactly one slot. A stack tops out at MAX_STACK and
	does not spill into a second slot, so the true ceiling is
	MAX_SLOTS * MAX_STACK items across MAX_SLOTS distinct kinds.

	Usage:
		local InventoryConfig = require(ReplicatedStorage.Shared.InventoryConfig)
		if slotsUsed >= InventoryConfig.MAX_SLOTS then ... end
]]

local InventoryConfig = {}

InventoryConfig.MAX_SLOTS = 20 -- distinct kinds of item a player may hold
InventoryConfig.MAX_STACK = 5 -- copies per kind

return table.freeze(InventoryConfig)
