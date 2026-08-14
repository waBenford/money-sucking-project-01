--!strict
--[[
	RollView
	The Accessory tab. One view serves every roll variant in ShopConfig --
	"Accessory Roll" and "Bed Upgrade Roll" are the same screen with different
	numbers, so building two of these would guarantee they drift apart.

	Switching variants goes through SetVariant, which rewrites text and widths on
	the instances that already exist. Nothing is created or destroyed, so the
	sub-tabs are instant and there is nothing to leak.

	The sub-tab row is an addition, not something the wireframes show: they draw
	two variants with no way to move between them.

	Everything a player reads here about odds comes from ShopConfig.ratesFor, the
	same function the server rolls against -- so the dropdown cannot advertise
	rates the machine does not use. Level and balance both arrive from outside:
	this view never guesses either.

	Usage:
		local view = RollView.new({ parent = panel, onRoll = roll })
		view:SetVariantState("accessory", 3, 24)
		view:SetBalance(1200)
		view:ShowResult({ "bunny_plush" })
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Direct paths so --!strict can see the exported types; see the note in
-- Components.
local ItemData = require(ReplicatedStorage.Shared.ItemData)
local ShopConfig = require(ReplicatedStorage.Shared.ShopConfig)
local Theme = require(ReplicatedStorage.Shared.Theme)

local Components = require(script.Parent.Components)
local ItemPreview = require(script.Parent.ItemPreview)
local Trove = require(script.Parent.Trove)

--// Layout
--
-- Scales relative to the content panel, measured off the wireframe. The centre
-- preview is the one deliberate departure: the spec calls it larger and raised,
-- so it is the side boxes scaled by CENTER_SCALE and lifted clear of them.

local TITLE_Y = 0.053
local TITLE_HEIGHT = 0.075
local SUBTAB_Y = 0.14
local SUBTAB_HEIGHT = 0.08
local SUBTAB_WIDTH = 0.17
local SUBTAB_GAP = 0.012

-- The three previews are positioned by their vertical centre, so SIDE_Y is the
-- middle of the row rather than its top edge.
local SIDE_WIDTH = 0.14
local SIDE_HEIGHT = 0.43
local SIDE_Y = 0.386
local CENTER_SCALE = 1.15
local CENTER_RAISE = 0.09
local PREVIEW_GAP = 0.012

local RATE_X = 0.821
local RATE_WIDTH = 0.152
local RATE_Y = 0.1
local RATE_HEIGHT = 0.077
local RATE_LIST_Y = 0.19
local RATE_ROW_HEIGHT = 0.057

local LEVEL_X = 0.013
local LEVEL_WIDTH = 0.309
local LEVEL_LABEL_Y = 0.855
local LEVEL_LABEL_HEIGHT = 0.06
local LEVEL_BAR_Y = 0.926
local LEVEL_BAR_HEIGHT = 0.032
local MAX_TAG_Y = 0.8
local MAX_TAG_HEIGHT = 0.05
local MAX_TAG_WIDTH = 0.06

local ROLL_Y = 0.746
local ROLL_WIDTH = 0.229
local ROLL_HEIGHT = 0.22
local TEN_X = 0.625
local TEN_Y = 0.839
local TEN_WIDTH = 0.113
local TEN_HEIGHT = 0.122
local PRICE_HEIGHT = 0.05

local RATE_PADDING = 6

local COLLAPSED_GLYPH = "\u{25BC}" -- black down-pointing triangle
local EXPANDED_GLYPH = "\u{25B2}"

local RollView = {}
RollView.__index = RollView

export type Props = {
	parent: Instance,
	onRoll: (variantId: string, count: number) -> (),
}

type RateRow = {
	root: Frame,
	name: TextLabel,
	chance: TextLabel,
}

type PreviewSlot = {
	box: Frame,
	preview: ItemPreview.ItemPreview,
}

type VariantState = {
	level: number,
	rolls: number,
}

-- Rows are built once for the longest rate table in config and reused by every
-- variant, so switching never touches the instance tree.
local function widestRateTable(): number
	local widest = 0
	for _, variant in ipairs(ShopConfig.RollVariants) do
		widest = math.max(widest, #variant.Weights)
	end
	return widest
end

-- Two decimals, trailing zeros trimmed, and never rounded down to a flat "0%":
-- at level 1 Mythic really is 0.01%, and showing "0%" would say the machine
-- cannot produce something it can.
local function formatChance(chance: number): string
	if chance > 0 and chance < 0.01 then
		return "<0.01%"
	end

	local text = string.format("%.2f", chance)
	text = text:gsub("%.?0+$", "")

	return text .. "%"
end

local function previewBox(parent: Instance, trove: Trove.Trove, name: string, color: Color3, x: number, y: number, width: number, height: number): PreviewSlot
	local box = Components.box({
		name = name,
		parent = parent,
		position = UDim2.fromScale(x, y),
		anchorPoint = Vector2.new(0, 0.5),
		size = UDim2.fromScale(width, height),
		color = color,
		stroked = true,
	})

	local preview = ItemPreview.new({
		parent = box,
		size = UDim2.fromScale(1, 1),
	})

	trove:add(function()
		preview:Destroy()
	end)

	return { box = box, preview = preview }
end

function RollView.new(props: Props): RollView
	local trove = Trove.new()

	local root = Instance.new("Frame")
	root.Name = "Roll"
	root.Size = UDim2.fromScale(1, 1)
	root.BackgroundTransparency = 1
	root.BorderSizePixel = 0
	root.Visible = false
	root.Parent = props.parent

	trove:add(root)

	local title = Components.label({
		name = "Title",
		parent = root,
		position = UDim2.fromScale(LEVEL_X, TITLE_Y),
		size = UDim2.fromScale(0.4, TITLE_HEIGHT),
		text = "",
		textColor = Theme.Shop.TextOnLight,
		maxTextSize = Theme.Shop.MaxTextSize.Title,
		font = Theme.Shop.Fonts.Display,
		xAlign = Enum.TextXAlignment.Left,
	})

	--// Previews. Centre first, so the side boxes can be placed against it.

	local centerWidth = SIDE_WIDTH * CENTER_SCALE
	local centerHeight = SIDE_HEIGHT * CENTER_SCALE
	local centerX = 0.5 - (centerWidth / 2)
	-- Larger *and* lifted clear of the side boxes, as drawn: growing it alone
	-- would only stretch it downward and read as misaligned rather than focused.
	local centerY = SIDE_Y - CENTER_RAISE

	local left = previewBox(root, trove, "PreviewLeft", Theme.Shop.PreviewSide, centerX - PREVIEW_GAP - SIDE_WIDTH, SIDE_Y, SIDE_WIDTH, SIDE_HEIGHT)
	local center = previewBox(root, trove, "PreviewCenter", Theme.Shop.PreviewFocus, centerX, centerY, centerWidth, centerHeight)
	local right = previewBox(root, trove, "PreviewRight", Theme.Shop.PreviewSideDark, centerX + centerWidth + PREVIEW_GAP, SIDE_Y, SIDE_WIDTH, SIDE_HEIGHT)

	--// Rate dropdown

	local rateRowCount = widestRateTable()

	local rateList = Instance.new("Frame")
	rateList.Name = "RateList"
	rateList.Position = UDim2.fromScale(RATE_X, RATE_LIST_Y)
	rateList.Size = UDim2.fromScale(RATE_WIDTH, RATE_ROW_HEIGHT * rateRowCount)
	rateList.BackgroundTransparency = 1
	rateList.BorderSizePixel = 0
	rateList.Visible = false
	rateList.Parent = root

	local rateLayout = Instance.new("UIListLayout")
	rateLayout.FillDirection = Enum.FillDirection.Vertical
	rateLayout.SortOrder = Enum.SortOrder.LayoutOrder
	rateLayout.Parent = rateList

	local rateRows: { RateRow } = {}

	for index = 1, rateRowCount do
		local rowRoot = Instance.new("Frame")
		rowRoot.Name = "Rate" .. index
		rowRoot.Size = UDim2.fromScale(1, 1 / rateRowCount)
		rowRoot.BackgroundTransparency = 1
		rowRoot.BorderSizePixel = 0
		rowRoot.LayoutOrder = index
		rowRoot.Parent = rateList

		local name = Components.label({
			name = "RarityName",
			parent = rowRoot,
			size = UDim2.fromScale(0.5, 1),
			text = "",
			textColor = Theme.Shop.TextOnLight,
			maxTextSize = Theme.Shop.MaxTextSize.Body,
			font = Theme.Shop.Fonts.Display,
			xAlign = Enum.TextXAlignment.Left,
		})

		local chance = Components.label({
			name = "Chance",
			parent = rowRoot,
			position = UDim2.fromScale(0.5, 0),
			size = UDim2.fromScale(0.5, 1),
			text = "",
			textColor = Theme.Shop.TextOnLight,
			maxTextSize = Theme.Shop.MaxTextSize.Body,
			font = Theme.Shop.Fonts.UiBold,
			xAlign = Enum.TextXAlignment.Right,
		})

		rateRows[index] = { root = rowRoot, name = name, chance = chance }
	end

	--// Level progress

	local levelLeft = Components.label({
		name = "LevelCurrent",
		parent = root,
		position = UDim2.fromScale(LEVEL_X, LEVEL_LABEL_Y),
		size = UDim2.fromScale(0.1, LEVEL_LABEL_HEIGHT),
		text = "",
		textColor = Theme.Shop.TextOnLight,
		maxTextSize = Theme.Shop.MaxTextSize.Body,
		font = Theme.Shop.Fonts.Display,
		xAlign = Enum.TextXAlignment.Left,
	})

	local levelRight = Components.label({
		name = "LevelMax",
		parent = root,
		position = UDim2.fromScale(LEVEL_X + LEVEL_WIDTH - 0.1, LEVEL_LABEL_Y),
		size = UDim2.fromScale(0.1, LEVEL_LABEL_HEIGHT),
		text = "",
		textColor = Theme.Shop.TextOnLight,
		maxTextSize = Theme.Shop.MaxTextSize.Body,
		font = Theme.Shop.Fonts.Display,
		xAlign = Enum.TextXAlignment.Right,
	})

	Components.label({
		name = "MaxTag",
		parent = root,
		position = UDim2.fromScale(LEVEL_X + LEVEL_WIDTH - MAX_TAG_WIDTH, MAX_TAG_Y),
		size = UDim2.fromScale(MAX_TAG_WIDTH, MAX_TAG_HEIGHT),
		text = "max",
		textColor = Theme.Shop.MaxTag,
		maxTextSize = Theme.Shop.MaxTextSize.Small,
		xAlign = Enum.TextXAlignment.Right,
	})

	local levelTrack = Components.box({
		name = "LevelTrack",
		parent = root,
		position = UDim2.fromScale(LEVEL_X, LEVEL_BAR_Y),
		size = UDim2.fromScale(LEVEL_WIDTH, LEVEL_BAR_HEIGHT),
		color = Theme.Shop.LevelTrack,
		stroked = true,
	})

	local levelFill = Components.box({
		name = "LevelFill",
		parent = levelTrack,
		size = UDim2.fromScale(0, 1),
		color = Theme.Shop.LevelFill,
	})

	--// Roll buttons

	local counts = ShopConfig.ROLL_COUNTS
	local primaryCount = counts[1]
	local secondaryCount = counts[2]

	local rollPrice = Components.label({
		name = "RollPrice",
		parent = root,
		position = UDim2.fromScale(0.5, ROLL_Y - PRICE_HEIGHT),
		anchorPoint = Vector2.new(0.5, 0),
		size = UDim2.fromScale(ROLL_WIDTH, PRICE_HEIGHT),
		text = "",
		textColor = Theme.Shop.TextOnLight,
		maxTextSize = Theme.Shop.MaxTextSize.Small,
		font = Theme.Shop.Fonts.UiBold,
	})

	local rollButton = Components.button({
		name = "Roll",
		parent = root,
		position = UDim2.fromScale(0.5, ROLL_Y),
		anchorPoint = Vector2.new(0.5, 0),
		size = UDim2.fromScale(ROLL_WIDTH, ROLL_HEIGHT),
		text = "Roll",
		textColor = Theme.Shop.TextOnLight,
		maxTextSize = Theme.Shop.MaxTextSize.Button,
		baseColor = Theme.Shop.RollFill,
		trove = trove,
	})

	local tenPrice: TextLabel? = nil
	local tenButton: Components.Button? = nil

	if secondaryCount then
		tenPrice = Components.label({
			name = "RollManyPrice",
			parent = root,
			position = UDim2.fromScale(TEN_X, TEN_Y - PRICE_HEIGHT),
			size = UDim2.fromScale(TEN_WIDTH, PRICE_HEIGHT),
			text = "",
			textColor = Theme.Shop.TextOnLight,
			maxTextSize = Theme.Shop.MaxTextSize.Small,
			font = Theme.Shop.Fonts.UiBold,
		})

		tenButton = Components.button({
			name = "RollMany",
			parent = root,
			position = UDim2.fromScale(TEN_X, TEN_Y),
			size = UDim2.fromScale(TEN_WIDTH, TEN_HEIGHT),
			text = "x" .. secondaryCount,
			textColor = Theme.Shop.TextOnLight,
			maxTextSize = Theme.Shop.MaxTextSize.Button,
			baseColor = Theme.Shop.RollFill,
			trove = trove,
		})
	end

	local rateToggle = Components.button({
		name = "RateToggle",
		parent = root,
		position = UDim2.fromScale(RATE_X, RATE_Y),
		size = UDim2.fromScale(RATE_WIDTH, RATE_HEIGHT),
		text = "",
		textColor = Theme.Shop.TextOnLight,
		maxTextSize = Theme.Shop.MaxTextSize.Body,
		baseColor = Theme.Shop.PillFill,
		trove = trove,
	})

	Components.label({
		name = "RateLabel",
		parent = rateToggle.instance,
		size = UDim2.fromScale(0.7, 1),
		text = "Rate %",
		textColor = Theme.Shop.TextOnLight,
		maxTextSize = Theme.Shop.MaxTextSize.Body,
		font = Theme.Shop.Fonts.UiBold,
		xAlign = Enum.TextXAlignment.Left,
	})

	local rateGlyph = Components.label({
		name = "RateGlyph",
		parent = rateToggle.instance,
		position = UDim2.fromScale(0.7, 0),
		size = UDim2.fromScale(0.3, 1),
		text = COLLAPSED_GLYPH,
		textColor = Theme.Shop.TextOnLight,
		maxTextSize = Theme.Shop.MaxTextSize.Body,
		xAlign = Enum.TextXAlignment.Right,
	})

	Components.padding(rateToggle.instance, 0, RATE_PADDING, 0, RATE_PADDING)

	local self = setmetatable({
		root = root,
		trove = trove,
		title = title,
		subTabs = {},
		rateRows = rateRows,
		rateList = rateList,
		rateGlyph = rateGlyph,
		levelLeft = levelLeft,
		levelRight = levelRight,
		levelFill = levelFill,
		rollButton = rollButton,
		tenButton = tenButton,
		rollPrice = rollPrice,
		tenPrice = tenPrice,
		previews = { left = left, center = center, right = right },
		states = {},
		variantId = ShopConfig.RollVariants[1].Id,
		balance = 0,
		expanded = false,
		busy = false,
		visible = false,
	}, RollView)

	--// Sub-tabs, one per variant

	for order, variant in ipairs(ShopConfig.RollVariants) do
		local variantId = variant.Id

		self.subTabs[variantId] = Components.tab({
			name = variantId,
			parent = root,
			position = UDim2.fromScale(LEVEL_X + (order - 1) * (SUBTAB_WIDTH + SUBTAB_GAP), SUBTAB_Y),
			size = UDim2.fromScale(SUBTAB_WIDTH, SUBTAB_HEIGHT),
			text = variant.Title,
			trove = trove,
			onClick = function()
				RollView.SetVariant(self, variantId)
			end,
		})
	end

	--// Wiring

	trove:add(rateToggle.instance.MouseButton1Click:Connect(function()
		RollView.setExpanded(self, not self.expanded)
	end))

	trove:add(rollButton.instance.MouseButton1Click:Connect(function()
		if RollView.canAfford(self, primaryCount) and not self.busy then
			props.onRoll(self.variantId, primaryCount)
		end
	end))

	if tenButton and secondaryCount then
		trove:add(tenButton.instance.MouseButton1Click:Connect(function()
			if RollView.canAfford(self, secondaryCount) and not self.busy then
				props.onRoll(self.variantId, secondaryCount)
			end
		end))
	end

	RollView.SetVariant(self, self.variantId)

	return self
end

--// Internal

function RollView.canAfford(self: RollView, count: number): boolean
	local variant = ShopConfig.getRollVariant(self.variantId)
	if not variant then
		return false
	end

	return self.balance >= variant.Price * count
end

-- A roll is refused for two different reasons -- no money, or a request already
-- in flight -- and both look the same on the button.
local function refreshButtons(self: RollView)
	local counts = ShopConfig.ROLL_COUNTS

	self.rollButton.setEnabled(not self.busy and RollView.canAfford(self, counts[1]))

	local tenButton = self.tenButton
	if tenButton and counts[2] then
		tenButton.setEnabled(not self.busy and RollView.canAfford(self, counts[2]))
	end
end

function RollView.setExpanded(self: RollView, expanded: boolean)
	self.expanded = expanded
	self.rateList.Visible = expanded
	self.rateGlyph.Text = if expanded then EXPANDED_GLYPH else COLLAPSED_GLYPH
end

--// API

-- The whole variant switch: title, percentages, prices, progress and which
-- sub-tab reads as selected. No instance is added or removed.
function RollView.SetVariant(self: RollView, variantId: string)
	local variant = ShopConfig.getRollVariant(variantId)
	if not variant then
		warn(("RollView: unknown roll variant '%s'"):format(tostring(variantId)))
		return
	end

	self.variantId = variantId
	self.title.Text = variant.Title

	local state = self.states[variantId] or { level = 1, rolls = 0 }
	local rates = ShopConfig.ratesFor(variantId, state.level)

	for index, row in ipairs(self.rateRows) do
		local rate = rates[index]

		if rate then
			row.root.Visible = true
			row.name.Text = rate.Name
			row.name.TextColor3 = ShopConfig.rateColor(rate)
			row.chance.Text = formatChance(rate.Chance)
		else
			-- A variant with fewer tiers than the widest: hide the spare row
			-- rather than rebuild the list.
			row.root.Visible = false
		end
	end

	self.levelLeft.Text = "lv." .. state.level
	self.levelRight.Text = "lv." .. variant.MaxLevel
	self.levelFill.Size = UDim2.fromScale(ShopConfig.levelProgress(variant, state.rolls), 1)

	self.rollPrice.Text = "$" .. Components.formatMoney(variant.Price)

	local tenPrice = self.tenPrice
	local secondary = ShopConfig.ROLL_COUNTS[2]
	if tenPrice and secondary then
		tenPrice.Text = "$" .. Components.formatMoney(variant.Price * secondary)
	end

	for id, tab in pairs(self.subTabs) do
		tab.setSelected(id == variantId)
	end

	refreshButtons(self)
end

-- Level and roll count are the server's, always. Passing them in rather than
-- counting clicks here is what keeps the advertised rates honest: the dropdown
-- redraws from the same numbers the machine will roll against.
function RollView.SetVariantState(self: RollView, variantId: string, level: number, rolls: number)
	self.states[variantId] = { level = level, rolls = rolls }

	if variantId == self.variantId then
		RollView.SetVariant(self, variantId)
	end
end

function RollView.SetBalance(self: RollView, balance: number)
	self.balance = balance
	refreshButtons(self)
end

-- Shows the tail of a batch: the newest lands in the focused centre box, the two
-- before it fall back to the sides, so a x10 leaves a readable trace instead of
-- flashing ten items through one box.
function RollView.ShowResult(self: RollView, itemIds: { string })
	local order = { self.previews.center, self.previews.left, self.previews.right }

	for offset, slot in ipairs(order) do
		local itemId = itemIds[#itemIds - (offset - 1)]
		slot.preview:SetItem(if itemId then ItemData.getItemById(itemId) else nil)
	end
end

-- Held while a request is in flight: the buttons stay visible but stop acting,
-- so a second click cannot queue a second roll before the first is answered.
function RollView.SetBusy(self: RollView, busy: boolean)
	self.busy = busy
	refreshButtons(self)
end

function RollView.SetVisible(self: RollView, visible: boolean)
	self.visible = visible
	self.root.Visible = visible

	-- The previews only spin while this tab is the one on screen; a hidden frame
	-- still reports Visible = true from its own property, so they cannot work
	-- this out for themselves.
	for _, slot in pairs(self.previews) do
		slot.preview:SetActive(visible)
	end

	if not visible then
		-- Leaving the tab with the dropdown open would reopen it on return,
		-- covering the previews before the player asked for it.
		RollView.setExpanded(self, false)
	end
end

function RollView.Destroy(self: RollView)
	self.trove:clean()
end

export type RollView = typeof(setmetatable(
	{} :: {
		root: Frame,
		trove: Trove.Trove,
		title: TextLabel,
		subTabs: { [string]: Components.Tab },
		rateRows: { RateRow },
		rateList: Frame,
		rateGlyph: TextLabel,
		levelLeft: TextLabel,
		levelRight: TextLabel,
		levelFill: Frame,
		rollButton: Components.Button,
		tenButton: Components.Button?,
		rollPrice: TextLabel,
		tenPrice: TextLabel?,
		previews: { [string]: PreviewSlot },
		states: { [string]: VariantState },
		variantId: string,
		balance: number,
		expanded: boolean,
		busy: boolean,
		visible: boolean,
	},
	RollView
))

return RollView
