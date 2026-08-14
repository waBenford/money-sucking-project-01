--!strict
--[[
	DailyView
	The Daily tab: today's stock, and a countdown to the next rotation.

	This is a shop, not a giveaway -- a slot is bought with money like anything
	else. Tapping one opens the detail panel underneath, which is where the price
	and the Buy button live; the wireframe draws the row of squares only, and
	"press to look at it, then buy it" needs somewhere to put both.

	The stock itself is not stored anywhere. ShopConfig.dailyStock() derives it
	from the clock, so this view and the server compute the same list
	independently -- which is what lets the rotation work with no persistence
	layer in the project.

	The countdown never accumulates. Every frame it recomputes the remaining time
	from os.time() and only writes the label when the formatted string changes,
	so a lag spike, a long yield or a rejoin cannot make it drift. It is also
	what notices the rotation: when the window index changes, the stock is
	rebuilt.

	Usage:
		local view = DailyView.new({ parent = panel, onBuy = buy })
		view:SetSold({ daily_1 = true })
		view:SetBalance(500)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

-- Direct paths so --!strict can see the exported types; see the note in
-- Components.
local ItemData = require(ReplicatedStorage.Shared.ItemData)
local Rarity = require(ReplicatedStorage.Shared.Rarity)
local ShopConfig = require(ReplicatedStorage.Shared.ShopConfig)
local Theme = require(ReplicatedStorage.Shared.Theme)

local Components = require(script.Parent.Components)
local ItemPreview = require(script.Parent.ItemPreview)
local Trove = require(script.Parent.Trove)

--// Layout
--
-- Scales relative to the content panel, derived from the wireframe's pixel
-- measurements. Offsets appear only as padding.

local TIMER_HEIGHT = 0.096
local ROW_TOP = 0.116
local ROW_HEIGHT = 0.42
local SLOT_HEIGHT = 0.86 -- of the row; width follows from the 1:1 aspect
local SLOT_GAP = 0.035
local SLOT_PRICE_HEIGHT = 0.18

local DETAIL_TOP = 0.58
local DETAIL_HEIGHT = 0.42
local DETAIL_PREVIEW = 0.34
local DETAIL_TEXT_X = 0.4
local DETAIL_LINE = 0.17

local TIMER_TEXT_PADDING = 10

local DailyView = {}
DailyView.__index = DailyView

export type Props = {
	parent: Instance,
	onBuy: (slotId: string) -> (),
}

type Slot = {
	button: Components.Button,
	preview: ItemPreview.ItemPreview,
	price: TextLabel,
	sold: TextLabel,
	entry: ShopConfig.DailyEntry,
}

local function formatCountdown(remaining: number): string
	local hours = math.floor(remaining / 3600)
	local minutes = math.floor((remaining % 3600) / 60)
	local seconds = remaining % 60

	return ("%02d:%02d:%02d"):format(hours, minutes, seconds)
end

function DailyView.new(props: Props): DailyView
	local trove = Trove.new()

	local root = Instance.new("Frame")
	root.Name = "Daily"
	root.Size = UDim2.fromScale(1, 1)
	root.BackgroundTransparency = 1
	root.BorderSizePixel = 0
	root.Visible = false
	root.Parent = props.parent

	trove:add(root)

	local timerBar = Components.box({
		name = "TimerBar",
		parent = root,
		size = UDim2.fromScale(1, TIMER_HEIGHT),
		color = Theme.Shop.TimerFill,
		stroked = true,
	})

	local timerLabel = Components.label({
		name = "Countdown",
		parent = timerBar,
		size = UDim2.fromScale(1, 1),
		text = formatCountdown(ShopConfig.secondsUntilReset()),
		textColor = Theme.Shop.TextOnLight,
		maxTextSize = Theme.Shop.MaxTextSize.Timer,
		font = Theme.Shop.Fonts.UiBold,
		xAlign = Enum.TextXAlignment.Right,
	})

	Components.padding(timerLabel, 0, TIMER_TEXT_PADDING, 0, TIMER_TEXT_PADDING)

	-- Scrolls horizontally so a longer stock than the panel can hold stays
	-- reachable. No scrollbar: the wireframe has none, and drag and wheel still
	-- work without one.
	local row = Instance.new("ScrollingFrame")
	row.Name = "Stock"
	row.Position = UDim2.fromScale(0, ROW_TOP)
	row.Size = UDim2.fromScale(1, ROW_HEIGHT)
	row.BackgroundTransparency = 1
	row.BorderSizePixel = 0
	row.ScrollBarThickness = 0
	row.ScrollingDirection = Enum.ScrollingDirection.X
	row.CanvasSize = UDim2.new()
	row.AutomaticCanvasSize = Enum.AutomaticSize.X
	row.Parent = root

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Padding = UDim.new(SLOT_GAP, 0)
	layout.Parent = row

	--// Detail panel

	local detail = Components.box({
		name = "Detail",
		parent = root,
		position = UDim2.fromScale(0, DETAIL_TOP),
		size = UDim2.fromScale(1, DETAIL_HEIGHT),
		color = Theme.Shop.TimerFill,
		stroked = true,
	})
	detail.Visible = false

	local detailPreview = ItemPreview.new({
		parent = detail,
		position = UDim2.fromScale(0.03, 0.5),
		anchorPoint = Vector2.new(0, 0.5),
		size = UDim2.fromScale(DETAIL_PREVIEW * 0.5, DETAIL_PREVIEW * 2),
	})

	trove:add(function()
		detailPreview:Destroy()
	end)

	local function detailLine(order: number, isBold: boolean): TextLabel
		return Components.label({
			name = "Line" .. order,
			parent = detail,
			position = UDim2.fromScale(DETAIL_TEXT_X, 0.08 + (order - 1) * DETAIL_LINE),
			size = UDim2.fromScale(0.45, DETAIL_LINE),
			text = "",
			textColor = Theme.Shop.TextOnLight,
			maxTextSize = if isBold then Theme.Shop.MaxTextSize.Title else Theme.Shop.MaxTextSize.Body,
			font = if isBold then Theme.Shop.Fonts.Display else Theme.Shop.Fonts.Ui,
			xAlign = Enum.TextXAlignment.Left,
		})
	end

	local detailName = detailLine(1, true)
	local detailRarity = detailLine(2, false)
	local detailBuff = detailLine(3, false)
	local detailPrice = detailLine(4, false)

	local buyButton = Components.button({
		name = "Buy",
		parent = detail,
		anchorPoint = Vector2.new(1, 1),
		position = UDim2.fromScale(0.97, 0.88),
		size = UDim2.fromScale(0.22, 0.3),
		text = "Buy",
		textColor = Theme.Shop.TextOnLight,
		maxTextSize = Theme.Shop.MaxTextSize.Button,
		baseColor = Theme.Shop.PanelFill,
		trove = trove,
	})

	local closeButton = Components.button({
		name = "CloseDetail",
		parent = detail,
		anchorPoint = Vector2.new(1, 0),
		position = UDim2.fromScale(0.985, 0.06),
		size = UDim2.fromScale(0.06, 0.22),
		text = "X",
		textColor = Theme.Shop.TextOnLight,
		maxTextSize = Theme.Shop.MaxTextSize.Small,
		baseColor = Theme.Shop.RollFill,
		trove = trove,
	})

	-- Rebuilt whenever the stock rotates, so its connections and previews have to
	-- go with it. The outer trove owns this one and cleans it on teardown.
	local stockTrove = Trove.new()

	local self = setmetatable({
		root = root,
		trove = trove,
		stockTrove = stockTrove,
		row = row,
		timerLabel = timerLabel,
		detail = detail,
		detailPreview = detailPreview,
		detailName = detailName,
		detailRarity = detailRarity,
		detailBuff = detailBuff,
		detailPrice = detailPrice,
		buyButton = buyButton,
		slots = {},
		sold = {},
		selectedId = nil,
		balance = 0,
		busy = false,
		visible = false,
		window = -1,
		lastText = timerLabel.Text,
	}, DailyView)

	trove:add(function()
		self.stockTrove:clean()
	end)

	trove:add(buyButton.instance.MouseButton1Click:Connect(function()
		local slotId = self.selectedId
		if slotId and not self.busy and not self.sold[slotId] then
			props.onBuy(slotId)
		end
	end))

	trove:add(closeButton.instance.MouseButton1Click:Connect(function()
		DailyView.select(self, nil)
	end))

	DailyView.rebuildStock(self)

	trove:add(RunService.Heartbeat:Connect(function()
		DailyView.tick(self)
	end))

	return self
end

--// Stock

-- Cheap enough to run every frame: two divisions and a string compare. Writing
-- the label unconditionally would be the expensive part, hence the guard.
function DailyView.tick(self: DailyView)
	if ShopConfig.currentWindow() ~= self.window then
		-- Midnight rolled over while the shop was open.
		DailyView.rebuildStock(self)
	end

	local text = formatCountdown(ShopConfig.secondsUntilReset())
	if text == self.lastText then
		return
	end

	self.lastText = text
	self.timerLabel.Text = text
end

function DailyView.rebuildStock(self: DailyView)
	-- Everything the previous stock made -- slots, previews, click handlers --
	-- came out of this trove, so one clean leaves nothing behind.
	self.stockTrove:clean()
	self.stockTrove = Trove.new()
	self.slots = {}

	DailyView.select(self, nil)

	self.window = ShopConfig.currentWindow()

	for order, entry in ipairs(ShopConfig.dailyStock(self.window)) do
		local slotId = entry.SlotId
		local item = ItemData.getItemById(entry.ItemId)

		local button = Components.button({
			name = slotId,
			parent = self.row,
			-- Height-driven: the aspect constraint below turns it into a square,
			-- so any number of slots stays uniform.
			size = UDim2.fromScale(0, SLOT_HEIGHT),
			text = "",
			textColor = Theme.Shop.TextOnDark,
			maxTextSize = Theme.Shop.MaxTextSize.Small,
			baseColor = Theme.Shop.SlotFill,
			layoutOrder = order,
			trove = self.stockTrove,
		})

		local aspect = Instance.new("UIAspectRatioConstraint")
		aspect.AspectRatio = 1
		aspect.DominantAxis = Enum.DominantAxis.Height
		aspect.Parent = button.instance

		local preview = ItemPreview.new({
			parent = button.instance,
			size = UDim2.fromScale(1, 1 - SLOT_PRICE_HEIGHT),
			active = self.visible,
		})
		preview:SetItem(item)

		self.stockTrove:add(function()
			preview:Destroy()
		end)

		local price = Components.label({
			name = "Price",
			parent = button.instance,
			position = UDim2.fromScale(0, 1 - SLOT_PRICE_HEIGHT),
			size = UDim2.fromScale(1, SLOT_PRICE_HEIGHT),
			text = "$" .. Components.formatMoney(entry.Price),
			textColor = Theme.Shop.TextOnDark,
			maxTextSize = Theme.Shop.MaxTextSize.Small,
			font = Theme.Shop.Fonts.UiBold,
		})

		local sold = Components.label({
			name = "Sold",
			parent = button.instance,
			size = UDim2.fromScale(1, 1),
			text = "SOLD",
			textColor = Theme.Shop.MaxTag,
			maxTextSize = Theme.Shop.MaxTextSize.Title,
			font = Theme.Shop.Fonts.UiBold,
			zIndex = 3,
		})
		sold.Visible = false

		self.stockTrove:add(button.instance.MouseButton1Click:Connect(function()
			DailyView.select(self, slotId)
		end))

		self.slots[slotId] = {
			button = button,
			preview = preview,
			price = price,
			sold = sold,
			entry = entry,
		}
	end

	DailyView.applySold(self)
end

--// Selection

function DailyView.select(self: DailyView, slotId: string?)
	self.selectedId = slotId

	local slot = slotId and self.slots[slotId]
	if not slot then
		self.detail.Visible = false
		self.detailPreview:SetActive(false)
		return
	end

	local item = ItemData.getItemById(slot.entry.ItemId)

	self.detailName.Text = item and item.Name or slot.entry.ItemId
	self.detailRarity.Text = if item then Rarity.name(item.Rarity) else ""
	self.detailRarity.TextColor3 = if item then Theme.rarityColor(item.Rarity) else Theme.Shop.TextOnLight
	-- Stories have no buff and sell on their reward instead; either way there is
	-- one line describing what the thing does.
	self.detailBuff.Text = (item and (ItemData.describeBuff(item) or (item.BaseReward and ("Dream reward %d per cycle"):format(item.BaseReward)))) or ""
	self.detailPrice.Text = "Price  $" .. Components.formatMoney(slot.entry.Price)

	self.detailPreview:SetItem(item)
	self.detailPreview:SetActive(self.visible)
	self.detail.Visible = true

	DailyView.refreshBuy(self)
end

function DailyView.refreshBuy(self: DailyView)
	local slotId = self.selectedId
	local slot = slotId and self.slots[slotId]

	if not (slotId and slot) then
		return
	end

	local affordable = self.balance >= slot.entry.Price
	self.buyButton.setEnabled(not self.busy and not self.sold[slotId] and affordable)
	self.buyButton.instance.Text = if self.sold[slotId] then "Sold" else "Buy"
end

function DailyView.applySold(self: DailyView)
	for slotId, slot in pairs(self.slots) do
		local isSold = self.sold[slotId] == true

		slot.sold.Visible = isSold
		slot.price.Visible = not isSold
		-- A sold slot is still clickable: the player may want to look at what
		-- they bought. Only the Buy button goes down.
		slot.preview:SetActive(self.visible and not isSold)
	end

	DailyView.refreshBuy(self)
end

--// API

function DailyView.SetSold(self: DailyView, sold: { [string]: boolean })
	self.sold = sold
	DailyView.applySold(self)
end

function DailyView.SetBalance(self: DailyView, balance: number)
	self.balance = balance
	DailyView.refreshBuy(self)
end

function DailyView.SetBusy(self: DailyView, busy: boolean)
	self.busy = busy
	DailyView.refreshBuy(self)
end

function DailyView.SetVisible(self: DailyView, visible: boolean)
	self.visible = visible
	self.root.Visible = visible

	for _, slot in pairs(self.slots) do
		slot.preview:SetActive(visible and not self.sold[slot.entry.SlotId])
	end

	self.detailPreview:SetActive(visible and self.detail.Visible)
end

function DailyView.Destroy(self: DailyView)
	-- The trove holds the root, the stock trove and every connection, so this is
	-- the whole teardown: Heartbeat first, instances after.
	self.trove:clean()
end

export type DailyView = typeof(setmetatable(
	{} :: {
		root: Frame,
		trove: Trove.Trove,
		stockTrove: Trove.Trove,
		row: ScrollingFrame,
		timerLabel: TextLabel,
		detail: Frame,
		detailPreview: ItemPreview.ItemPreview,
		detailName: TextLabel,
		detailRarity: TextLabel,
		detailBuff: TextLabel,
		detailPrice: TextLabel,
		buyButton: Components.Button,
		slots: { [string]: Slot },
		sold: { [string]: boolean },
		selectedId: string?,
		balance: number,
		busy: boolean,
		visible: boolean,
		window: number,
		lastText: string,
	},
	DailyView
))

return DailyView
