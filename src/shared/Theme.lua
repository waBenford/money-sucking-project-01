--[[
	Theme
	Shared colours. RARITY_COLORS lived in two files already (the inventory UI and
	the conveyor's item parts) and the new item slots need it as a third; one copy
	drifting from the others would mean a story looks legendary on the belt and
	common in the bag.

	Colour only. Sizes and fonts stay with whoever lays out the screen, since
	nothing else has a use for them.

	Usage:
		local Theme = require(ReplicatedStorage.Shared.Theme)
		part.Color = Theme.rarityColor(story.Rarity)
]]

local Theme = {}

Theme.RARITY_COLORS = table.freeze({
	[1] = Color3.fromRGB(200, 200, 200), -- grey
	[2] = Color3.fromRGB(80, 200, 120), -- green
	[3] = Color3.fromRGB(70, 130, 230), -- blue
	[4] = Color3.fromRGB(160, 90, 220), -- purple
	[5] = Color3.fromRGB(255, 190, 60), -- gold
})

--// Panel palette

Theme.PANEL_BG = Color3.fromRGB(25, 27, 34)
Theme.HEADER_BG = Color3.fromRGB(44, 47, 58)
Theme.SLOT_BG = Color3.fromRGB(38, 41, 50)
Theme.SLOT_SELECTED_BG = Color3.fromRGB(58, 63, 78)
Theme.FIELD_BG = Color3.fromRGB(52, 56, 68)

Theme.TEXT = Color3.fromRGB(235, 235, 240)
Theme.TEXT_MUTED = Color3.fromRGB(150, 154, 166)
Theme.ACCENT = Color3.fromRGB(90, 150, 255)
Theme.DANGER = Color3.fromRGB(215, 60, 60)

-- Falls back to rarity 1 rather than erroring: an out-of-range rarity from new
-- data should render plainly, not break the whole panel.
function Theme.rarityColor(rarity: number): Color3
	return Theme.RARITY_COLORS[rarity] or Theme.RARITY_COLORS[1]
end

return table.freeze(Theme)
