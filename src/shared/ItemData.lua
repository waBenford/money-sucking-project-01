--!strict
--[[
	ItemData
	One id space for everything a player can hold: Stories, Accessories and bed
	Upgrades.

	It exists because the bag stores ids and nothing else. Before this module,
	InventoryService validated every id through StoryData.getStoryById, so a
	rolled accessory could never enter the bag at all -- it was rejected as an
	unknown story.

	Entries are *normalised copies*, not the catalog tables. A Story carries
	BaseReward and Weight, an Accessory carries a Buff; consumers want one shape
	with optional fields rather than three shapes and a type test at every call
	site. The copies are frozen, so the originals stay authoritative.

	Direction of dependency is one-way -- ItemData pulls from the three catalogs
	and none of them knows it exists. Do not require this from a catalog.

	Deliberately NOT used by the bed: BedService and BedUi still resolve through
	StoryData, which is what stops a pillow from appearing in the list of things
	you can dream.

	Usage:
		local ItemData = require(ReplicatedStorage.Shared.ItemData)

		local item = ItemData.getItemById("bunny_plush")
		local pool = ItemData.getByRarity(ItemCategories.ACCESSORIES, 6)
		local text = ItemData.describeBuff(item)
]]

local AccessoryData = require(script.Parent.AccessoryData)
local ItemCategories = require(script.Parent.ItemCategories)
local Rarity = require(script.Parent.Rarity)
local StoryData = require(script.Parent.StoryData)
local UpgradeData = require(script.Parent.UpgradeData)

local ItemData = {}

export type Buff = {
	Kind: string, -- "MoneyAdd" | "MoneyMult" | "CycleMult"
	Value: number,
}

-- The union of what the three catalogs carry. Everything after Rarity is
-- optional because it depends on where the item came from.
export type Item = {
	Id: string,
	Name: string,
	Category: string,
	Rarity: number,
	BaseReward: number?, -- Stories: money per dream cycle
	Buff: Buff?, -- Accessories and Upgrades
	Slot: string?, -- Upgrades: which of the four bed slots
}

--// Index
--
-- Built once at require. The shop resolves ids on every roll and the bag on
-- every update, so nothing here may be a per-call scan.

local itemsById: { [string]: Item } = {}

-- [category][rarity] = { Item }. The roll picks a rarity first and then an item
-- inside it, so this is the shape that lookup actually needs.
local byCategoryRarity: { [string]: { [number]: { Item } } } = {}

local function register(item: Item)
	-- The id index is global across catalogs, so a duplicate would silently
	-- shadow another item and mis-price whatever resolved to it. Fail at startup
	-- instead -- same reasoning as StoryData's own duplicate guard, widened to
	-- cover collisions *between* catalogs.
	assert(
		itemsById[item.Id] == nil,
		("ItemData: duplicate item id '%s' (category '%s')"):format(item.Id, item.Category)
	)

	table.freeze(item)
	itemsById[item.Id] = item

	local byRarity = byCategoryRarity[item.Category]
	if not byRarity then
		byRarity = {}
		byCategoryRarity[item.Category] = byRarity
	end

	local tier = byRarity[item.Rarity]
	if not tier then
		tier = {}
		byRarity[item.Rarity] = tier
	end

	table.insert(tier, item)
end

for _, traveler in pairs(StoryData.Travelers) do
	for _, story in ipairs(traveler.Stories) do
		register({
			Id = story.Id,
			Name = story.Name,
			Category = story.Category or ItemCategories.STORY,
			Rarity = story.Rarity,
			BaseReward = story.BaseReward,
		})
	end
end

for _, accessory in ipairs(AccessoryData.All) do
	register({
		Id = accessory.Id,
		Name = accessory.Name,
		Category = accessory.Category,
		Rarity = accessory.Rarity,
		Buff = { Kind = accessory.Buff.Kind, Value = accessory.Buff.Value },
	})
end

for _, upgrade in ipairs(UpgradeData.All) do
	register({
		Id = upgrade.Id,
		Name = upgrade.Name,
		Category = upgrade.Category,
		Rarity = upgrade.Rarity,
		Slot = upgrade.Slot,
		Buff = { Kind = upgrade.Buff.Kind, Value = upgrade.Buff.Value },
	})
end

-- A roll picks a rarity from a curve and then an item at that rarity. A tier
-- with nothing in it would make that roll return nil and quietly swallow the
-- money paid for it, so the shop's two categories are checked here at startup
-- rather than discovered by a player.
for _, category in ipairs({ ItemCategories.ACCESSORIES, ItemCategories.UPGRADE }) do
	for tier = 1, Rarity.MAX do
		local items = byCategoryRarity[category] and byCategoryRarity[category][tier]
		assert(
			items and #items > 0,
			("ItemData: category '%s' has no items at rarity %d -- a roll landing there would return nothing"):format(
				category,
				tier
			)
		)
	end
end

--// API

function ItemData.getItemById(itemId: string): Item?
	return itemsById[itemId]
end

-- Empty rather than nil for an unknown pair, so callers can `#pool == 0` instead
-- of branching twice.
function ItemData.getByRarity(category: string, tier: number): { Item }
	local byRarity = byCategoryRarity[category]
	local items = byRarity and byRarity[tier]
	return items or {}
end

-- One line of player-facing text for what an item does, or nil for items that do
-- nothing on their own (Stories, whose value is BaseReward instead).
function ItemData.describeBuff(item: Item): string?
	local buff = item.Buff
	if not buff then
		return nil
	end

	if buff.Kind == "MoneyAdd" then
		return ("+%d money per dream cycle"):format(buff.Value)
	elseif buff.Kind == "MoneyMult" then
		return ("x%.2f dream money"):format(buff.Value)
	elseif buff.Kind == "CycleMult" then
		-- Stored as a duration multiplier, read out as the saving, because
		-- "-25% dream time" is what a player is actually buying.
		return ("-%d%% dream time"):format(math.round((1 - buff.Value) * 100))
	end

	return nil
end

return table.freeze(ItemData)
