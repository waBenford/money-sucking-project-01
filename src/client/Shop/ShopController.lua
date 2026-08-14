--!strict
--[[
	ShopController
	Builds the shop window, owns which tab is showing, and is the only place that
	talks to the server.

	All three tab views are constructed once at mount and switched with Visible.
	Rebuilding a tab on every click would throw away scroll positions, restart the
	countdown, and churn instances for no reason.

	Nothing here decides an outcome. Every claim, roll and purchase is a request
	whose answer the server gives; the money label follows leaderstats and is
	never written from a predicted value.

	Usage:
		local controller = ShopController.new({ currency = money, remote = remote })
		controller:Open()
		controller:Destroy()
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

-- Direct paths so --!strict can see the exported types; see the note in
-- Components.
local ShopTypes = require(ReplicatedStorage.Shared.ShopTypes)
local Theme = require(ReplicatedStorage.Shared.Theme)

local Components = require(script.Parent.Components)
local DailyView = require(script.Parent.DailyView)
local ProductView = require(script.Parent.ProductView)
local RollView = require(script.Parent.RollView)
local Trove = require(script.Parent.Trove)

--// Layout
--
-- Window-relative scales, measured off the wireframes. Only the size floor and
-- the panel's inner padding are pixels.

local WINDOW_WIDTH = 0.92
local WINDOW_HEIGHT = 0.86
local WINDOW_ASPECT = 2
local WINDOW_MIN = Vector2.new(300, 150)

local INSET_LEFT = 0.025
local INSET_RIGHT = 0.039

local PILL_WIDTH = 0.155
local PILL_HEIGHT = 0.109
local PILL_Y = 0.039

local MONEY_WIDTH = 0.265
local MONEY_HEIGHT = 0.089
local MONEY_Y = 0.048

local TAB_Y = 0.172
local TAB_HEIGHT = 0.078
local TAB_WIDTH = 0.112 -- of the tab bar, which is itself inset from the window
local TAB_GAP = 0.0235

local CONTENT_Y = 0.279
local CONTENT_BOTTOM_INSET = 0.037

local RAIL_THICKNESS = 9
local PANEL_PADDING = 12

local OPEN_TWEEN = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local CLOSED_SCALE = 0.85

--// Tabs
--
-- The three tabs are what this screen is, not data a designer tunes, so they
-- live here rather than in ShopConfig. Order is display order.

type TabId = "daily" | "accessory" | "gamepass"

local TAB_ORDER: { TabId } = { "daily", "accessory", "gamepass" }

local TAB_NAMES: { [string]: string } = {
	daily = "Daily",
	accessory = "Accessory",
	gamepass = "Gamepass",
}

-- One uniform handle per tab, so switching, busy-gating and balance updates do
-- not have to know which concrete view they are holding.
type ViewHandle = {
	setVisible: (visible: boolean) -> (),
	setBusy: (busy: boolean) -> (),
	setBalance: (balance: number) -> (),
}

local player = Players.LocalPlayer

local ShopController = {}
ShopController.__index = ShopController

export type Props = {
	currency: IntValue,
	remote: RemoteFunction,
}

function ShopController.new(props: Props): ShopController
	local trove = Trove.new()

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "ShopGui"
	-- The shop must survive a respawn: every cached view reference would
	-- otherwise point at a destroyed instance.
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = true
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.Enabled = false
	screenGui.Parent = player:WaitForChild("PlayerGui")

	trove:add(screenGui)

	-- A CanvasGroup rather than a Frame: GroupTransparency fades the whole window
	-- as one image, which is the only way to fade a subtree without walking every
	-- descendant's own transparency.
	local window = Instance.new("CanvasGroup")
	window.Name = "Window"
	window.AnchorPoint = Vector2.new(0.5, 0.5)
	window.Position = UDim2.fromScale(0.5, 0.5)
	window.Size = UDim2.fromScale(WINDOW_WIDTH, WINDOW_HEIGHT)
	window.BackgroundColor3 = Theme.Shop.WindowFill
	window.BorderSizePixel = 0
	window.GroupTransparency = 1
	window.Parent = screenGui

	Components.corner(window, Theme.Shop.Corner.Window)
	Components.stroke(window)

	-- FitWithinMaxSize keeps the 2:1 shape inside the Size box above, so the
	-- window is limited by whichever screen axis runs out first.
	local aspect = Instance.new("UIAspectRatioConstraint")
	aspect.AspectRatio = WINDOW_ASPECT
	aspect.AspectType = Enum.AspectType.FitWithinMaxSize
	aspect.DominantAxis = Enum.DominantAxis.Width
	aspect.Parent = window

	local sizeConstraint = Instance.new("UISizeConstraint")
	sizeConstraint.MinSize = WINDOW_MIN
	sizeConstraint.Parent = window

	local scale = Instance.new("UIScale")
	scale.Scale = CLOSED_SCALE
	scale.Parent = window

	--// Header

	Components.pill({
		name = "ShopPill",
		parent = window,
		position = UDim2.fromScale(0.5, PILL_Y),
		anchorPoint = Vector2.new(0.5, 0),
		size = UDim2.fromScale(PILL_WIDTH, PILL_HEIGHT),
		text = "Shop",
		textColor = Theme.Shop.TextOnLight,
		maxTextSize = Theme.Shop.MaxTextSize.Pill,
		font = Theme.Shop.Fonts.Display,
	})

	local moneyBox = Components.box({
		name = "Money",
		parent = window,
		position = UDim2.fromScale(1 - INSET_RIGHT, MONEY_Y),
		anchorPoint = Vector2.new(1, 0),
		size = UDim2.fromScale(MONEY_WIDTH, MONEY_HEIGHT),
		color = Theme.Shop.PanelFill,
		stroked = true,
	})

	local moneyLabel = Components.label({
		name = "Amount",
		parent = moneyBox,
		size = UDim2.fromScale(1, 1),
		text = Components.formatMoney(props.currency.Value),
		textColor = Theme.Shop.TextOnLight,
		maxTextSize = Theme.Shop.MaxTextSize.Money,
		font = Theme.Shop.Fonts.Display,
	})

	--// Tab bar

	local tabBar = Instance.new("Frame")
	tabBar.Name = "TabBar"
	tabBar.Position = UDim2.fromScale(INSET_LEFT, TAB_Y)
	tabBar.Size = UDim2.fromScale(1 - INSET_LEFT - INSET_RIGHT, TAB_HEIGHT)
	tabBar.BackgroundTransparency = 1
	tabBar.BorderSizePixel = 0
	tabBar.Parent = window

	local tabLayout = Instance.new("UIListLayout")
	tabLayout.FillDirection = Enum.FillDirection.Horizontal
	tabLayout.SortOrder = Enum.SortOrder.LayoutOrder
	tabLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	tabLayout.Padding = UDim.new(TAB_GAP, 0)
	tabLayout.Parent = tabBar

	--// Content

	-- The rail on the window's inside edge is this frame's own scrollbar, and
	-- ScrollBarInset keeps the panel clear of it whether or not it is showing.
	local contentScroll = Instance.new("ScrollingFrame")
	contentScroll.Name = "ContentScroll"
	contentScroll.Position = UDim2.fromScale(INSET_LEFT, CONTENT_Y)
	contentScroll.Size = UDim2.fromScale(1 - INSET_LEFT - INSET_RIGHT, 1 - CONTENT_Y - CONTENT_BOTTOM_INSET)
	contentScroll.BackgroundTransparency = 1
	contentScroll.BorderSizePixel = 0
	contentScroll.ScrollBarThickness = RAIL_THICKNESS
	contentScroll.ScrollBarImageColor3 = Theme.Shop.Rail
	contentScroll.ScrollingDirection = Enum.ScrollingDirection.Y
	contentScroll.VerticalScrollBarInset = Enum.ScrollBarInset.ScrollBar
	-- Fixed at one viewport, not AutomaticCanvasSize: the panel below is sized by
	-- scale, and an automatic canvas measuring a scale-sized child that is itself
	-- measured against that canvas is a feedback loop. A height of 1 means the
	-- panel fills the frame exactly and the rail appears only if a taller tab is
	-- ever added.
	contentScroll.CanvasSize = UDim2.new(0, 0, 1, 0)
	contentScroll.Parent = window

	local contentPanel = Components.panel({
		name = "ContentPanel",
		parent = contentScroll,
		size = UDim2.fromScale(1, 1),
		color = Theme.Shop.PanelFill,
	})

	Components.padding(contentPanel, PANEL_PADDING, PANEL_PADDING, PANEL_PADDING, PANEL_PADDING)

	--// Views
	--
	-- Declared before self so their callbacks can close over it; they run long
	-- after the assignment below, never during construction.

	local self: ShopController

	local daily = DailyView.new({
		parent = contentPanel,
		onBuy = function(slotId: string)
			ShopController.buyDaily(self, slotId)
		end,
	})

	local roll = RollView.new({
		parent = contentPanel,
		onRoll = function(variantId: string, count: number)
			ShopController.roll(self, variantId, count)
		end,
	})

	local products = ProductView.new({
		parent = contentPanel,
		onBuy = function(productId: string, quantity: number)
			ShopController.buy(self, productId, quantity)
		end,
	})

	trove:add(function()
		daily:Destroy()
		roll:Destroy()
		products:Destroy()
	end)

	self = setmetatable({
		trove = trove,
		screenGui = screenGui,
		window = window,
		scale = scale,
		moneyLabel = moneyLabel,
		currency = props.currency,
		remote = props.remote,
		tabs = {},
		views = {},
		daily = daily,
		roll = roll,
		activeTab = TAB_ORDER[1],
		open = false,
		generation = 0,
		scaleTween = nil,
		fadeTween = nil,
	}, ShopController)

	self.views.daily = {
		setVisible = function(visible: boolean)
			daily:SetVisible(visible)
		end,
		setBusy = function(busy: boolean)
			daily:SetBusy(busy)
		end,
		setBalance = function(balance: number)
			daily:SetBalance(balance)
		end,
	}

	self.views.accessory = {
		setVisible = function(visible: boolean)
			roll:SetVisible(visible)
		end,
		setBusy = function(busy: boolean)
			roll:SetBusy(busy)
		end,
		setBalance = function(balance: number)
			roll:SetBalance(balance)
		end,
	}

	self.views.gamepass = {
		setVisible = function(visible: boolean)
			products:SetVisible(visible)
		end,
		setBusy = function(busy: boolean)
			products:SetBusy(busy)
		end,
		-- Developer Products are bought with Robux, so a money balance changes
		-- nothing about what this tab can do.
		setBalance = function(_balance: number) end,
	}

	--// Tabs, now that the views they switch exist

	for order, tabId in ipairs(TAB_ORDER) do
		self.tabs[tabId] = Components.tab({
			name = tabId,
			parent = tabBar,
			size = UDim2.fromScale(TAB_WIDTH, 1),
			layoutOrder = order,
			text = TAB_NAMES[tabId],
			trove = trove,
			onClick = function()
				ShopController.SetTab(self, tabId)
			end,
		})
	end

	-- The balance drives more than the label: every price-gated button reads it,
	-- so one signal keeps the whole window in step with what the player can
	-- actually afford.
	local function applyBalance(value: number)
		moneyLabel.Text = Components.formatMoney(value)

		for _, handle in pairs(self.views) do
			handle.setBalance(value)
		end
	end

	trove:add(props.currency.Changed:Connect(applyBalance))
	applyBalance(props.currency.Value)

	ShopController.SetTab(self, self.activeTab)

	-- Machine levels and today's sold-out slots live on the server; without this
	-- the shop would open showing lv.1 and nothing sold until the first roll.
	task.spawn(function()
		ShopController.refreshState(self)
	end)

	return self
end

--// Server state

function ShopController.refreshState(self: ShopController)
	local response = ShopController.request(self, self.activeTab, { action = "GetState" })
	if not response then
		return
	end

	local variants = response.variants
	if variants then
		for variantId, state in pairs(variants) do
			self.roll:SetVariantState(variantId, state.level, state.rolls)
		end
	end

	local soldSlots = response.soldSlots
	if soldSlots then
		self.daily:SetSold(soldSlots)
	end
end

--// Tabs

function ShopController.SetTab(self: ShopController, tabId: TabId)
	self.activeTab = tabId

	for id, handle in pairs(self.views) do
		handle.setVisible(id == tabId)
	end

	for id, tab in pairs(self.tabs) do
		tab.setSelected(id == tabId)
	end
end

--// Server requests

-- One path for all three actions: gate the tab that asked, invoke, ungate,
-- then act on the answer. The UI is never touched before the answer arrives.
-- Returns only a success -- every failure is logged and reported as nil, so no
-- caller has to re-check `ok`.
function ShopController.request(self: ShopController, tabId: TabId, request: ShopTypes.Request): ShopTypes.SuccessResponse?
	local handle = self.views[tabId]
	handle.setBusy(true)

	-- pcall because InvokeServer propagates a server-side error to the caller,
	-- and an errored request must still release the buttons.
	local ok, result = pcall(function()
		return self.remote:InvokeServer(request)
	end)

	handle.setBusy(false)

	if not ok then
		warn(("ShopController: %s request failed -- %s"):format(request.action, tostring(result)))
		return nil
	end

	if type(result) ~= "table" then
		warn(("ShopController: %s got a malformed response"):format(request.action))
		return nil
	end

	local response = result :: ShopTypes.Response

	if not response.ok then
		-- reason is a code, not display text. There is nowhere in the wireframes
		-- to show it, so it goes to the log until there is.
		warn(("ShopController: %s refused -- %s"):format(request.action, response.reason))
		return nil
	end

	return response
end

function ShopController.buyDaily(self: ShopController, slotId: string)
	task.spawn(function()
		local response = ShopController.request(self, "daily", {
			action = "BuyDaily",
			slotId = slotId,
		})

		if not response then
			return
		end

		-- The server confirmed it, so this is reporting a fact rather than
		-- predicting one. The money label follows leaderstats on its own.
		local soldSlots = response.soldSlots
		if soldSlots then
			self.daily:SetSold(soldSlots)
		end
	end)
end

function ShopController.roll(self: ShopController, variantId: string, count: number)
	task.spawn(function()
		local response = ShopController.request(self, "accessory", {
			action = "Roll",
			variantId = variantId,
			count = count,
		})

		if not response then
			return
		end

		local rolled = response.rolled
		if rolled then
			self.roll:ShowResult(rolled)
		end

		-- Level and roll count come back with the result rather than being
		-- counted here: the machine's rates are the server's to know.
		local level, rolls = response.level, response.rolls
		if level and rolls then
			self.roll:SetVariantState(variantId, level, rolls)
		end

		if response.stopped then
			-- Some pulls had nowhere to go and were refunded. There is nowhere in
			-- the wireframes to say so, so it goes to the log until there is.
			warn(("ShopController: part of the roll could not be delivered -- %s"):format(response.stopped))
		end
	end)
end

function ShopController.buy(self: ShopController, productId: string, quantity: number)
	task.spawn(function()
		local response = ShopController.request(self, "gamepass", {
			action = "BuyProduct",
			productId = productId,
			quantity = quantity,
		})

		if not response then
			return
		end

		local robloxProductId = response.robloxProductId

		-- 0 is what ShopConfig ships as a placeholder. Prompting with it would
		-- throw; saying so is more use than a stack trace.
		if not robloxProductId or robloxProductId <= 0 then
			warn(("ShopController: product '%s' has no Developer Product id yet -- see the TODO in ShopConfig"):format(productId))
			return
		end

		-- The prompt is the purchase. Granting happens server-side in
		-- ProcessReceipt, never from this response.
		MarketplaceService:PromptProductPurchase(player, robloxProductId)
	end)
end

--// Open and close

local function stopTween(tween: Tween?)
	if tween then
		tween:Cancel()
		tween:Destroy()
	end
end

function ShopController.Open(self: ShopController)
	if self.open then
		return
	end

	self.open = true
	self.generation += 1

	stopTween(self.scaleTween)
	stopTween(self.fadeTween)

	self.screenGui.Enabled = true

	self.scaleTween = TweenService:Create(self.scale, OPEN_TWEEN, { Scale = 1 })
	self.fadeTween = TweenService:Create(self.window, OPEN_TWEEN, { GroupTransparency = 0 })

	local scaleTween = self.scaleTween
	local fadeTween = self.fadeTween
	if scaleTween then
		scaleTween:Play()
	end
	if fadeTween then
		fadeTween:Play()
	end
end

function ShopController.Close(self: ShopController)
	if not self.open then
		return
	end

	self.open = false
	self.generation += 1

	stopTween(self.scaleTween)
	stopTween(self.fadeTween)

	self.scaleTween = TweenService:Create(self.scale, OPEN_TWEEN, { Scale = CLOSED_SCALE })
	self.fadeTween = TweenService:Create(self.window, OPEN_TWEEN, { GroupTransparency = 1 })

	local scaleTween = self.scaleTween
	local fadeTween = self.fadeTween
	if scaleTween then
		scaleTween:Play()
	end

	if fadeTween then
		-- Compare the generation, not a boolean: a close followed immediately by
		-- an open would otherwise let this handler disable a window that is on
		-- its way back in.
		local generation = self.generation

		fadeTween.Completed:Connect(function()
			if self.generation == generation then
				self.screenGui.Enabled = false
			end
		end)

		fadeTween:Play()
	end
end

function ShopController.Toggle(self: ShopController)
	if self.open then
		ShopController.Close(self)
	else
		ShopController.Open(self)
	end
end

function ShopController.IsOpen(self: ShopController): boolean
	return self.open
end

function ShopController.Destroy(self: ShopController)
	stopTween(self.scaleTween)
	stopTween(self.fadeTween)
	self.scaleTween = nil
	self.fadeTween = nil

	-- Views, connections and the ScreenGui all come out of the one trove, in the
	-- reverse of the order they went in.
	self.trove:clean()
end

export type ShopController = typeof(setmetatable(
	{} :: {
		trove: Trove.Trove,
		screenGui: ScreenGui,
		window: CanvasGroup,
		scale: UIScale,
		moneyLabel: TextLabel,
		currency: IntValue,
		remote: RemoteFunction,
		tabs: { [string]: Components.Tab },
		views: { [string]: ViewHandle },
		daily: DailyView.DailyView,
		roll: RollView.RollView,
		activeTab: TabId,
		open: boolean,
		generation: number,
		scaleTween: Tween?,
		fadeTween: Tween?,
	},
	ShopController
))

return ShopController
