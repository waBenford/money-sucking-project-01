--!strict
--[[
	ShopConfig
	Every number the shop runs on: what the roll machines cost, how their rates
	move with level, what the daily stock is, and which Developer Products exist.

	Shared, not client-only: ShopService must price a roll and resolve a daily
	slot against the same tables the UI offered, or the client would be defining
	what things cost.

	Two things here are computed rather than listed, and both are deliberate:

	1. Rates are a curve, not a table per level. Each rarity has a weight at
	   level 1 and at max level; ratesFor() interpolates and normalises to 100%.
	   A hand-written table per level would be 120 numbers per machine that must
	   sum correctly, and the first balance pass would break that.

	2. Daily stock is derived from the clock, not stored. Both sides compute
	   `floor(os.time() / DAILY_RESET_PERIOD)` and seed a Random with it, so the
	   stock rotates daily and agrees across machines with nothing persisted --
	   which matters because this project has no persistence layer yet.

	Usage:
		local ShopConfig = require(ReplicatedStorage.Shared.ShopConfig)

		local rates = ShopConfig.ratesFor("accessory", 3)
		local stock = ShopConfig.dailyStock()
]]

local ItemCategories = require(script.Parent.ItemCategories)
local ItemData = require(script.Parent.ItemData)
local Rarity = require(script.Parent.Rarity)
local Theme = require(script.Parent.Theme)

local ShopConfig = {}

--// Types

export type RarityRate = {
	Rarity: number,
	Name: string,
	Chance: number, -- percent; the set always sums to 100
}

export type RollVariant = {
	Id: string,
	Title: string,
	Category: string, -- which catalog this machine rolls from
	Price: number, -- money per single roll
	MaxLevel: number,
	RollsPerLevel: number,
	-- Weight per rarity at level 1 and at MaxLevel. Interpolated by ratesFor.
	Weights: { { Rarity: number, Min: number, Max: number } },
}

export type Product = {
	Id: string,
	Name: string,
	Revealed: boolean,
	RobloxProductId: number,
}

export type DailyEntry = {
	SlotId: string,
	ItemId: string,
	Price: number,
}

--// Rolls

-- How sharply the curve bends. A straight line would already have Epic at a
-- percent or so by level 3; cubing the progress keeps levels 1-3 almost
-- entirely Common/Uncommon/Rare, which is the intended early game.
ShopConfig.WEIGHT_CURVE_EXPONENT = 3

local rollVariants: { RollVariant } = {
	{
		Id = "accessory",
		Title = "Accessory Roll",
		Category = ItemCategories.ACCESSORIES,
		Price = 250,
		MaxLevel = 10,
		RollsPerLevel = 10,
		Weights = {
			{ Rarity = 1, Min = 600, Max = 300 },
			{ Rarity = 2, Min = 300, Max = 300 },
			{ Rarity = 3, Min = 95, Max = 220 },
			{ Rarity = 4, Min = 1, Max = 120 },
			{ Rarity = 5, Min = 0.3, Max = 50 },
			{ Rarity = 6, Min = 0.1, Max = 10 },
		},
	},
	{
		Id = "bed_upgrade",
		Title = "Bed Upgrade Roll",
		Category = ItemCategories.UPGRADE,
		Price = 500,
		MaxLevel = 10,
		RollsPerLevel = 10,
		Weights = {
			{ Rarity = 1, Min = 620, Max = 280 },
			{ Rarity = 2, Min = 290, Max = 300 },
			{ Rarity = 3, Min = 88, Max = 230 },
			{ Rarity = 4, Min = 1.5, Max = 130 },
			{ Rarity = 5, Min = 0.4, Max = 50 },
			{ Rarity = 6, Min = 0.1, Max = 10 },
		},
	},
}

ShopConfig.RollVariants = table.freeze(rollVariants)

-- The Roll and x10 buttons. A set rather than a maximum, because the server has
-- to reject anything that is not exactly one of these.
ShopConfig.ROLL_COUNTS = table.freeze({ 1, 10 })

--// Daily stock

ShopConfig.DAILY_RESET_PERIOD = 24 * 60 * 60
ShopConfig.DAILY_SLOT_COUNT = 3

-- What a daily item costs, by rarity. Rolling for the same thing is cheaper on
-- average and far less certain -- the daily slot is the "just buy it" option.
ShopConfig.PRICE_BY_RARITY = table.freeze({
	[1] = 150,
	[2] = 400,
	[3] = 1200,
	[4] = 4000,
	[5] = 15000,
	[6] = 60000,
})

ShopConfig.DEFAULT_PRICE = 500

-- Which catalogs the daily rotation can draw from.
local DAILY_CATEGORIES = table.freeze({ ItemCategories.ACCESSORIES, ItemCategories.UPGRADE })

--// Products

local products: { Product } = {
	-- TODO: replace RobloxProductId with real Developer Product ids from the
	-- Creator Dashboard. 0 is a valid number and an invalid product, so a
	-- purchase prompt will fail loudly rather than charge anyone.
	{ Id = "gold_boot", Name = "gold Boot", Revealed = true, RobloxProductId = 0 },
	{ Id = "silver_boot", Name = "Boot", Revealed = false, RobloxProductId = 0 },
	{ Id = "bronze_boot", Name = "Boot", Revealed = false, RobloxProductId = 0 },
}

ShopConfig.Products = table.freeze(products)
ShopConfig.BUY_QUANTITIES = table.freeze({ 1, 10 })

--// Lookups

local variantById: { [string]: RollVariant } = {}

for _, variant in ipairs(rollVariants) do
	assert(variantById[variant.Id] == nil, ("ShopConfig: duplicate roll variant id '%s'"):format(variant.Id))
	assert(variant.MaxLevel > 1, ("ShopConfig: variant '%s' needs MaxLevel > 1"):format(variant.Id))
	assert(variant.RollsPerLevel > 0, ("ShopConfig: variant '%s' needs RollsPerLevel > 0"):format(variant.Id))
	assert(#variant.Weights == Rarity.MAX, ("ShopConfig: variant '%s' must weight all %d tiers"):format(variant.Id, Rarity.MAX))

	variantById[variant.Id] = variant
	table.freeze(variant.Weights)
	table.freeze(variant)
end

local productById: { [string]: Product } = {}
for _, product in ipairs(products) do
	assert(productById[product.Id] == nil, ("ShopConfig: duplicate product id '%s'"):format(product.Id))
	productById[product.Id] = product
end

function ShopConfig.getRollVariant(variantId: string): RollVariant?
	return variantById[variantId]
end

function ShopConfig.getProduct(productId: string): Product?
	return productById[productId]
end

function ShopConfig.isAllowedCount(count: number): boolean
	for _, allowed in ipairs(ShopConfig.ROLL_COUNTS) do
		if count == allowed then
			return true
		end
	end
	return false
end

function ShopConfig.priceForRarity(tier: number): number
	return ShopConfig.PRICE_BY_RARITY[tier] or ShopConfig.DEFAULT_PRICE
end

-- Display name with the wireframe's "?" mask applied. Lives here rather than in
-- the view so the server never has to guess what the client showed.
function ShopConfig.productTitle(product: Product): string
	if product.Revealed then
		return product.Name
	end
	return "? " .. product.Name
end

--// Level

-- Levels come from rolls and nothing else. Level 1 is the floor, so a player who
-- has never rolled still sees lv.1 rather than lv.0.
function ShopConfig.levelFor(variant: RollVariant, rolls: number): number
	local level = math.floor(rolls / variant.RollsPerLevel) + 1
	return math.clamp(level, 1, variant.MaxLevel)
end

-- How far through the whole ladder the player is, 0..1 -- what the lv.1 .. lv.10
-- bar fills to. Counts progress inside the current level too, so the bar moves
-- on every roll instead of jumping once every ten.
function ShopConfig.levelProgress(variant: RollVariant, rolls: number): number
	local span = variant.MaxLevel - 1
	local earned = rolls / variant.RollsPerLevel
	return math.clamp(earned / span, 0, 1)
end

-- The rate table at a given level, normalised so the six always sum to 100.
--
-- The same function feeds the Rate % dropdown and the server's own roll, so what
-- a player reads is by construction what they are rolling against.
function ShopConfig.ratesFor(variantId: string, level: number): { RarityRate }
	local variant = variantById[variantId]
	if not variant then
		return {}
	end

	local clamped = math.clamp(level, 1, variant.MaxLevel)
	local t = (clamped - 1) / (variant.MaxLevel - 1)
	local curved = t ^ ShopConfig.WEIGHT_CURVE_EXPONENT

	local weights: { number } = {}
	local total = 0

	for index, entry in ipairs(variant.Weights) do
		local weight = entry.Min + (entry.Max - entry.Min) * curved
		weights[index] = weight
		total += weight
	end

	local rates: { RarityRate } = {}

	for index, entry in ipairs(variant.Weights) do
		table.insert(rates, {
			Rarity = entry.Rarity,
			Name = Rarity.name(entry.Rarity),
			-- Percent, not a fraction: it is displayed far more often than it is
			-- computed with, and the roll below re-derives its own total anyway.
			Chance = (weights[index] / total) * 100,
		})
	end

	return rates
end

-- The rarity colour a rate row is tinted with, resolved through Theme so the
-- shop and the rest of the game cannot disagree about what "Rare" looks like.
function ShopConfig.rateColor(rate: RarityRate): Color3
	return Theme.rarityColor(rate.Rarity)
end

--// Daily stock
--
-- Derived from the clock so both sides agree without storing anything. The
-- server recomputes it when validating a purchase, so a client asking for
-- yesterday's slot is simply not offering something that exists.

function ShopConfig.currentWindow(): number
	return math.floor(os.time() / ShopConfig.DAILY_RESET_PERIOD)
end

-- Seconds until the stock rotates. Always strictly positive, so the countdown
-- never sits on 00:00:00 waiting for a tick.
function ShopConfig.secondsUntilReset(): number
	local period = ShopConfig.DAILY_RESET_PERIOD
	return ((ShopConfig.currentWindow() + 1) * period) - os.time()
end

-- The whole pool the daily rotation draws from, in a fixed order so the same
-- seed picks the same items on every machine. pairs() order would differ between
-- server and client and hand them different stock.
local dailyPool: { string } = {}

for _, category in ipairs(DAILY_CATEGORIES) do
	for tier = 1, Rarity.MAX do
		for _, item in ipairs(ItemData.getByRarity(category, tier)) do
			table.insert(dailyPool, item.Id)
		end
	end
end

table.sort(dailyPool)
table.freeze(dailyPool)

-- Today's stock: DAILY_SLOT_COUNT distinct items, priced by rarity.
--
-- Seeded with the window index alone, so it is a pure function of the date --
-- call it as often as you like, on either side, and it answers the same thing.
function ShopConfig.dailyStock(window: number?): { DailyEntry }
	local index = window or ShopConfig.currentWindow()
	local rng = Random.new(index)

	-- Copied element by element rather than with table.clone: dailyPool is frozen,
	-- and whether a clone inherits that is a detail worth not depending on when
	-- the very next thing this does is shuffle in place.
	local shuffled: { string } = {}
	for index, itemId in ipairs(dailyPool) do
		shuffled[index] = itemId
	end

	for position = #shuffled, 2, -1 do
		local swap = rng:NextInteger(1, position)
		shuffled[position], shuffled[swap] = shuffled[swap], shuffled[position]
	end

	local stock: { DailyEntry } = {}
	local wanted = math.min(ShopConfig.DAILY_SLOT_COUNT, #shuffled)

	for slot = 1, wanted do
		local itemId = shuffled[slot]
		local item = ItemData.getItemById(itemId)

		table.insert(stock, {
			-- Position-based, so a slot id means "the second thing on sale today"
			-- and stays meaningful when the stock rotates.
			SlotId = "daily_" .. slot,
			ItemId = itemId,
			Price = item and ShopConfig.priceForRarity(item.Rarity) or ShopConfig.DEFAULT_PRICE,
		})
	end

	return stock
end

return table.freeze(ShopConfig)
