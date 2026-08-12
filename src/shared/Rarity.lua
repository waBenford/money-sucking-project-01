--!strict
--[[
	Rarity
	The 1..6 tier ladder, and the words for it.

	Its own module rather than a field on Theme (which owns tier *colours*) or on
	a catalog (which would make the other catalogs depend on it): the shop's rate
	rows, the upgrade names and the inventory tooltip all need the same six
	words, and three copies of that list is how "Legendary" ends up spelled two
	ways.

	Stories only reach 5 -- StoryData.MAX_RARITY is deliberately its own number,
	because a sixth-tier Story does not exist. Tier 6 is shop goods only.

	Usage:
		local Rarity = require(ReplicatedStorage.Shared.Rarity)
		local label = Rarity.name(item.Rarity) -- "Legendary"
]]

local Rarity = {}

Rarity.MAX = 6

Rarity.Names = table.freeze({
	[1] = "Common",
	[2] = "Uncommon",
	[3] = "Rare",
	[4] = "Epic",
	[5] = "Legendary",
	[6] = "Mythic",
})

-- Falls back rather than erroring, matching Theme.rarityColor: data with a tier
-- outside the ladder should render plainly, not take a panel down with it.
function Rarity.name(tier: number): string
	return Rarity.Names[tier] or "Unknown"
end

return table.freeze(Rarity)
