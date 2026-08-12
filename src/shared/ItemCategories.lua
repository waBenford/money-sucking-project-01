--[[
	ItemCategories
	The item categories, and the order their tabs appear in the inventory.

	The UI builds its tab row by walking Order, so adding pillows or buffs later
	means adding an entry here and setting Category on the data -- no UI change.

	ALL is a pseudo-category: it is a tab, never a value stored on an item.
	matches() is the single place that knows that, so no caller has to special
	case it.

	Usage:
		local ItemCategories = require(ReplicatedStorage.Shared.ItemCategories)

		for _, id in ipairs(ItemCategories.Order) do ... end
		if ItemCategories.matches(activeTab, item.Category) then ... end
]]

local ItemCategories = {}

-- Ids are stable keys: they end up in saved item data, so treat them like
-- StoryData ids and never reword them. DisplayNames below are free to change.
ItemCategories.ALL = "all"
ItemCategories.STORY = "story"
ItemCategories.ACCESSORIES = "accessories"
-- The four bed slots (pillow, blanket, body pillow, mattress). Its own category
-- rather than folded into BOOST: an upgrade is a permanent part of the bed,
-- while a boost is a temporary effect, and the bag needs to tell them apart.
ItemCategories.UPGRADE = "upgrade"
ItemCategories.BOOST = "boost"

ItemCategories.Order = table.freeze({
	ItemCategories.ALL,
	ItemCategories.STORY,
	ItemCategories.ACCESSORIES,
	ItemCategories.UPGRADE,
	ItemCategories.BOOST,
})

ItemCategories.DisplayNames = table.freeze({
	[ItemCategories.ALL] = "ALL",
	[ItemCategories.STORY] = "Story",
	[ItemCategories.ACCESSORIES] = "Accessories",
	[ItemCategories.UPGRADE] = "Upgrade",
	[ItemCategories.BOOST] = "Boost",
})

-- Shown by the grid when a tab holds nothing. Per-category rather than one
-- generic line, because "you have none yet" and "this does not exist yet" are
-- different messages to a player.
ItemCategories.EmptyMessages = table.freeze({
	[ItemCategories.ALL] = "Your inventory is empty.\nCollect Stories from the conveyor belt.",
	[ItemCategories.STORY] = "No Stories yet.\nCollect them from the conveyor belt.",
	[ItemCategories.ACCESSORIES] = "No accessories yet.\nRoll for them at the shop.",
	[ItemCategories.UPGRADE] = "No bed upgrades yet.\nRoll for them at the shop.",
	[ItemCategories.BOOST] = "Boosts are coming soon.",
})

-- True when an item of `category` belongs under the `tab` currently selected.
-- Takes an optional category so an item whose data forgot to set one still shows
-- up somewhere -- under ALL -- instead of vanishing from every tab.
function ItemCategories.matches(tab: string, category: string?): boolean
	return tab == ItemCategories.ALL or tab == category
end

return table.freeze(ItemCategories)
