--!strict
--[[
	UpgradeData
	The bed itself: pillow, blanket, body pillow, mattress. Four slots, no more --
	an upgrade is always one of these four, at one of the six rarity tiers.

	Rarity *is* the tier. "Replace the old one with the new one" means a
	Legendary Pillow supersedes a Rare Pillow in the same slot, which is why the
	ladder below is per slot and strictly improving. The equip system that acts
	on that does not exist yet; for now a rolled upgrade simply lands in the bag
	carrying the number it will eventually apply.

	The 24 entries are generated from the four rows in `slots` rather than typed
	out, so a balance pass is six numbers per slot and cannot leave a tier
	missing.

	Usage:
		local UpgradeData = require(ReplicatedStorage.Shared.UpgradeData)
		for _, upgrade in ipairs(UpgradeData.All) do ... end
]]

local ItemCategories = require(script.Parent.ItemCategories)
local Rarity = require(script.Parent.Rarity)

local UpgradeData = {}

-- CycleMult multiplies the dream cycle's *duration*, so lower is better -- it is
-- the "reduce dream time" upgrade Prompt.txt describes.
export type BuffKind = "MoneyAdd" | "MoneyMult" | "CycleMult"

export type Buff = {
	Kind: BuffKind,
	Value: number,
}

export type Upgrade = {
	Id: string,
	Name: string,
	Category: string,
	Rarity: number,
	Slot: string, -- which of the four the item occupies
	Buff: Buff,
}

type SlotSpec = {
	Slot: string,
	Noun: string,
	Kind: BuffKind,
	-- One value per tier, Common first. Length must equal Rarity.MAX.
	Values: { number },
}

local slots: { SlotSpec } = {
	{
		Slot = "pillow",
		Noun = "Pillow",
		Kind = "MoneyMult",
		Values = { 1.02, 1.05, 1.09, 1.15, 1.22, 1.3 },
	},
	{
		Slot = "blanket",
		Noun = "Blanket",
		Kind = "MoneyMult",
		Values = { 1.03, 1.07, 1.12, 1.2, 1.32, 1.45 },
	},
	{
		Slot = "body_pillow",
		Noun = "Body Pillow",
		Kind = "MoneyAdd",
		Values = { 5, 15, 45, 120, 250, 400 },
	},
	{
		Slot = "mattress",
		Noun = "Mattress",
		Kind = "CycleMult",
		Values = { 0.98, 0.95, 0.92, 0.87, 0.81, 0.75 },
	},
}

--// Generation

local upgrades: { Upgrade } = {}

for _, spec in ipairs(slots) do
	assert(
		#spec.Values == Rarity.MAX,
		("UpgradeData: slot '%s' has %d tiers, expected %d"):format(spec.Slot, #spec.Values, Rarity.MAX)
	)

	for tier = 1, Rarity.MAX do
		local buff: Buff = { Kind = spec.Kind, Value = spec.Values[tier] }
		table.freeze(buff)

		local upgrade: Upgrade = {
			-- Id carries the tier, not the rarity word: ids go into saves and must
			-- survive renaming "Epic" to something else.
			Id = ("%s_t%d"):format(spec.Slot, tier),
			Name = ("%s %s"):format(Rarity.name(tier), spec.Noun),
			Category = ItemCategories.UPGRADE,
			Rarity = tier,
			Slot = spec.Slot,
			Buff = buff,
		}

		table.freeze(upgrade)
		table.insert(upgrades, upgrade)
	end
end

UpgradeData.All = table.freeze(upgrades)

-- The four slot ids, in display order. The equip system will need exactly this
-- list; nothing else should hardcode "pillow".
local slotIds: { string } = {}
for _, spec in ipairs(slots) do
	table.insert(slotIds, spec.Slot)
end

UpgradeData.Slots = table.freeze(slotIds)

return table.freeze(UpgradeData)
