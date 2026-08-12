--!strict
--[[
	AccessoryData
	The things a player puts beside the bed. Every one carries exactly one buff,
	either additive or multiplicative -- never both, so what an accessory does
	fits on one line of a tooltip and stacking rules stay obvious.

	Two per rarity tier, which is what the Accessory Roll's rate curve assumes:
	it picks a rarity first, then an item inside it. A tier with no items would
	make that roll dead-end, so ItemData asserts every tier is populated.

	Buff values are balance, not structure -- change them here and nothing else
	moves. Nothing in this file knows about the bed; applying a buff is the
	equip system's job, which does not exist yet.

	Usage:
		local AccessoryData = require(ReplicatedStorage.Shared.AccessoryData)
		for _, accessory in ipairs(AccessoryData.All) do ... end
]]

local ItemCategories = require(script.Parent.ItemCategories)

local AccessoryData = {}

-- MoneyAdd  -- flat money added to one dream cycle's payout
-- MoneyMult -- multiplies a dream cycle's payout
export type BuffKind = "MoneyAdd" | "MoneyMult"

export type Buff = {
	Kind: BuffKind,
	Value: number,
}

export type Accessory = {
	Id: string,
	Name: string,
	Category: string,
	Rarity: number, -- 1 (Common) to 6 (Mythic)
	Buff: Buff,
}

local function add(value: number): Buff
	return { Kind = "MoneyAdd", Value = value }
end

local function mult(value: number): Buff
	return { Kind = "MoneyMult", Value = value }
end

--// Data

local accessories: { Accessory } = {
	-- Common
	{ Id = "bunny_plush", Name = "Bunny Plush", Category = ItemCategories.ACCESSORIES, Rarity = 1, Buff = add(2) },
	{ Id = "old_alarm_clock", Name = "Old Alarm Clock", Category = ItemCategories.ACCESSORIES, Rarity = 1, Buff = add(3) },

	-- Uncommon
	{ Id = "storybook", Name = "Storybook", Category = ItemCategories.ACCESSORIES, Rarity = 2, Buff = add(8) },
	{ Id = "reading_lamp", Name = "Reading Lamp", Category = ItemCategories.ACCESSORIES, Rarity = 2, Buff = add(10) },

	-- Rare
	{ Id = "music_box", Name = "Music Box", Category = ItemCategories.ACCESSORIES, Rarity = 3, Buff = mult(1.05) },
	{ Id = "potted_plant", Name = "Potted Plant", Category = ItemCategories.ACCESSORIES, Rarity = 3, Buff = add(30) },

	-- Epic
	{ Id = "star_mobile", Name = "Star Mobile", Category = ItemCategories.ACCESSORIES, Rarity = 4, Buff = mult(1.12) },
	{ Id = "warm_milk", Name = "Warm Milk", Category = ItemCategories.ACCESSORIES, Rarity = 4, Buff = add(90) },

	-- Legendary
	{ Id = "lavender_diffuser", Name = "Lavender Diffuser", Category = ItemCategories.ACCESSORIES, Rarity = 5, Buff = mult(1.25) },
	{ Id = "heirloom_bear", Name = "Heirloom Bear", Category = ItemCategories.ACCESSORIES, Rarity = 5, Buff = add(300) },

	-- Mythic
	{ Id = "dreamcatcher_jar", Name = "Dreamcatcher Jar", Category = ItemCategories.ACCESSORIES, Rarity = 6, Buff = mult(1.5) },
	{ Id = "hourglass_of_night", Name = "Hourglass of Night", Category = ItemCategories.ACCESSORIES, Rarity = 6, Buff = mult(1.4) },
}

-- Frozen bottom-up, like StoryData: getRandomStory-style helpers hand out shared
-- references, and a stray write in consumer code would otherwise corrupt the
-- item for the whole server. table.freeze is shallow, so the buff goes first.
for _, accessory in ipairs(accessories) do
	table.freeze(accessory.Buff)
	table.freeze(accessory)
end

AccessoryData.All = table.freeze(accessories)

return table.freeze(AccessoryData)
