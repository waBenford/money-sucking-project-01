--!strict
--[[
	InventoryConfig
	The bag's capacity rules, in one place because both sides need them:
	InventoryService enforces them, the UI displays "n/20" and clamps its discard
	picker to the stack size.

	Capacity is per category, not one shared pool. With Stories, Accessories and
	bed Upgrades all in the same bag, a single limit would mean a run of good
	rolls locks a player out of collecting Stories -- two unrelated activities
	competing for the same 20 slots.

	Shared, not server-only, on purpose. These are display numbers, not secrets --
	a client that lies about them changes nothing, because every grant and
	discard is still checked against these same values on the server.

	One kind of item takes exactly one slot in its own category. A stack tops out
	at MAX_STACK and does not spill into a second slot.

	Usage:
		local InventoryConfig = require(ReplicatedStorage.Shared.InventoryConfig)
		local capacity = InventoryConfig.slotsFor(ItemCategories.ACCESSORIES)
]]

local ItemCategories = require(script.Parent.ItemCategories)

local InventoryConfig = {}

InventoryConfig.MAX_STACK = 5 -- copies per kind, the same in every category

-- Distinct kinds per category. Upgrades get fewer than they have ids (24) on
-- purpose: once equipping lands, only the best of each of the four slots is
-- worth keeping, and the discard flow already exists for the rest.
local SLOTS: { [string]: number } = {
	[ItemCategories.STORY] = 20,
	[ItemCategories.ACCESSORIES] = 20,
	[ItemCategories.UPGRADE] = 12,
	[ItemCategories.BOOST] = 10,
}

InventoryConfig.Slots = table.freeze(SLOTS)

-- The fallback matters: a category added to ItemCategories but forgotten here
-- must still be holdable, or items become ungrantable with no obvious cause.
InventoryConfig.DEFAULT_SLOTS = 10

function InventoryConfig.slotsFor(category: string): number
	return SLOTS[category] or InventoryConfig.DEFAULT_SLOTS
end

-- Every category's capacity added up. Only the bag's ALL tab wants this; the
-- rules themselves are always per category.
function InventoryConfig.totalSlots(): number
	local total = 0
	for _, category in ipairs(ItemCategories.Order) do
		if category ~= ItemCategories.ALL then
			total += InventoryConfig.slotsFor(category)
		end
	end
	return total
end

return table.freeze(InventoryConfig)
