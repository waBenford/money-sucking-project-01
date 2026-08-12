--!strict
--[[
	Theme
	Every colour, corner radius, font and text-size cap the UI is allowed to use.
	No other file may name a colour: RARITY_COLORS used to be copy-pasted in two
	places, and a story that looked legendary on the belt and common in the bag
	was the result.

	Two palettes live here for two surfaces -- the inventory panel's dark tokens
	at the top, the shop's blue ones under Theme.Shop. They are deliberately not
	merged: they are different designs, and collapsing them would force one to
	drift when the other is restyled.

	Rarity runs 1..6. Stories only reach 5 (StoryData.MAX_RARITY); tier 6, Mythic,
	exists for the shop's roll tables and has no Story behind it yet.

	Usage:
		local Theme = require(ReplicatedStorage.Shared.Theme)
		part.Color = Theme.rarityColor(story.Rarity)
		button.BackgroundColor3 = Theme.stateColor(Theme.Shop.TabIdle, "Hover")
]]

local Theme = {}

--// Rarity

local RARITY_COLORS: { [number]: Color3 } = {
	[1] = Color3.fromRGB(128, 128, 128), -- Common
	[2] = Color3.fromRGB(76, 217, 100), -- Uncommon
	[3] = Color3.fromRGB(47, 168, 232), -- Rare
	[4] = Color3.fromRGB(224, 123, 224), -- Epic
	[5] = Color3.fromRGB(245, 166, 35), -- Legendary
	[6] = Color3.fromRGB(224, 32, 32), -- Mythic
}

Theme.RARITY_COLORS = table.freeze(RARITY_COLORS)

--// Inventory panel palette

Theme.PANEL_BG = Color3.fromRGB(25, 27, 34)
Theme.HEADER_BG = Color3.fromRGB(44, 47, 58)
Theme.SLOT_BG = Color3.fromRGB(38, 41, 50)
Theme.SLOT_SELECTED_BG = Color3.fromRGB(58, 63, 78)
Theme.FIELD_BG = Color3.fromRGB(52, 56, 68)

Theme.TEXT = Color3.fromRGB(235, 235, 240)
Theme.TEXT_MUTED = Color3.fromRGB(150, 154, 166)
Theme.ACCENT = Color3.fromRGB(90, 150, 255)
Theme.DANGER = Color3.fromRGB(215, 60, 60)

--// Shop palette

export type ButtonState = "Idle" | "Hover" | "Press" | "Disabled"

Theme.Shop = table.freeze({
	WindowFill = Color3.fromRGB(107, 168, 255),
	PanelFill = Color3.fromRGB(207, 226, 255),
	PillFill = Color3.fromRGB(255, 255, 255),
	TabIdle = Color3.fromRGB(128, 128, 128),
	-- The selection indicator is a ring drawn outside the tab's own black
	-- stroke, not a fill change: idle and selected tabs share TabIdle.
	TabSelectedRing = Color3.fromRGB(255, 255, 255),
	Stroke = Color3.fromRGB(0, 0, 0),
	Rail = Color3.fromRGB(150, 160, 175),

	TimerFill = Color3.fromRGB(240, 245, 255),
	SlotFill = Color3.fromRGB(128, 128, 128),
	LevelTrack = Color3.fromRGB(228, 232, 240),
	LevelFill = Color3.fromRGB(150, 160, 175),
	-- Three preview boxes, light to dark, with the focused one black.
	PreviewSide = Color3.fromRGB(128, 128, 128),
	PreviewSideDark = Color3.fromRGB(61, 61, 61),
	PreviewFocus = Color3.fromRGB(0, 0, 0),

	-- A ViewportFrame carries its own lighting; without these the block inside
	-- renders nearly black and the rarity tint is invisible.
	PreviewAmbient = Color3.fromRGB(190, 190, 200),
	PreviewLight = Color3.fromRGB(255, 255, 255),
	PreviewEmpty = Color3.fromRGB(90, 94, 105),
	RollFill = Color3.fromRGB(122, 138, 158),

	TextOnDark = Color3.fromRGB(255, 255, 255),
	TextOnLight = Color3.fromRGB(0, 0, 0),
	MaxTag = Color3.fromRGB(224, 32, 32),

	StrokeThickness = 3,

	-- Corner radii in pixels. Panel is square by design; the pill is "999" in the
	-- spec, which in Roblox terms is a scale radius that always reads as a pill.
	Corner = table.freeze({
		Window = 24,
		Panel = 0,
		Button = 4,
	}),

	-- Caps for TextScaled labels. Text is never given a fixed TextSize: the
	-- window scales with the viewport, so a fixed size would be huge on a phone
	-- and tiny on a 4K monitor.
	MaxTextSize = table.freeze({
		Pill = 34,
		Money = 30,
		Tab = 18,
		Title = 26,
		Timer = 24,
		Body = 18,
		Button = 20,
		Small = 14,
	}),

	-- FontFace values, not Enum.Font: the enum property is the older surface, and
	-- Font.fromEnum gives the same faces through the current one.
	Fonts = table.freeze({
		-- Serif-ish display face for the pill, the money box and card titles.
		Display = Font.fromEnum(Enum.Font.Merriweather),
		Ui = Font.fromEnum(Enum.Font.Gotham),
		UiBold = Font.fromEnum(Enum.Font.GothamBold),
	}),

	-- How far a button's fill moves toward each target for each state. Kept here
	-- so button states work off any base colour without a per-button token.
	StateBlend = table.freeze({
		Idle = 0,
		Hover = 0.14,
		Press = 0.2,
		Disabled = 0.45,
	}),

	StateToward = table.freeze({
		Hover = Color3.fromRGB(255, 255, 255),
		Press = Color3.fromRGB(0, 0, 0),
		Disabled = Color3.fromRGB(150, 150, 150),
	}),
})

--// Helpers

-- Falls back to rarity 1 rather than erroring: an out-of-range rarity from new
-- data should render plainly, not break the whole panel.
function Theme.rarityColor(rarity: number): Color3
	return RARITY_COLORS[rarity] or RARITY_COLORS[1]
end

-- Derives a button's fill for one interaction state from its base colour.
function Theme.stateColor(base: Color3, state: ButtonState): Color3
	if state == "Idle" then
		return base
	end

	local blend: number = Theme.Shop.StateBlend[state]
	local toward: Color3 = Theme.Shop.StateToward[state]

	return base:Lerp(toward, blend)
end

return table.freeze(Theme)
