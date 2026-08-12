--!strict
--[[
	ProductView
	The Gamepass tab: a row of product cards, each with a buy button per quantity
	in ShopConfig.BUY_QUANTITIES.

	These are Developer Products, not gamepasses, which is why quantity buttons
	make sense at all -- a gamepass is owned once and could not be bought ten
	times. The tab keeps the wireframe's label.

	Nothing here prompts a purchase. onBuy hands the request to the controller,
	which asks the server to confirm the product exists and hand back its Roblox
	id; only then does a purchase prompt appear.

	Usage:
		local view = ProductView.new({ parent = panel, onBuy = buy })
		view:SetBusy(true)
		view:Destroy()
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Direct paths so --!strict can see the exported types; see the note in
-- Components.
local ShopConfig = require(ReplicatedStorage.Shared.ShopConfig)
local Theme = require(ReplicatedStorage.Shared.Theme)

local Components = require(script.Parent.Components)
local Trove = require(script.Parent.Trove)

--// Layout
--
-- Scales relative to the content panel. Cards are sized by the row's height and
-- an aspect ratio rather than a fraction of its width: a scale-based width would
-- be measured against a canvas that is itself measured from the cards, and a
-- fraction of the count would squeeze every card thinner as products are added.
-- This way the row scrolls instead.

local ROW_Y = 0.1
local ROW_HEIGHT = 0.82
local CARD_ASPECT = 0.78 -- width / height, from the wireframe
local CARD_GAP = 0.03
local BUTTON_WIDTH = 0.42

local ProductView = {}
ProductView.__index = ProductView

export type Props = {
	parent: Instance,
	onBuy: (productId: string, quantity: number) -> (),
}

function ProductView.new(props: Props): ProductView
	local trove = Trove.new()

	local root = Instance.new("Frame")
	root.Name = "Products"
	root.Size = UDim2.fromScale(1, 1)
	root.BackgroundTransparency = 1
	root.BorderSizePixel = 0
	root.Visible = false
	root.Parent = props.parent

	trove:add(root)

	local row = Instance.new("ScrollingFrame")
	row.Name = "Row"
	row.Position = UDim2.fromScale(0, ROW_Y)
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
	layout.Padding = UDim.new(CARD_GAP, 0)
	layout.Parent = row

	local buttons: { Components.Button } = {}

	for order, product in ipairs(ShopConfig.Products) do
		local card = Components.card({
			name = product.Id,
			parent = row,
			-- Height-driven; the constraint below supplies the width.
			size = UDim2.fromScale(0, 1),
			-- The "?" mask for an unrevealed product comes from ShopConfig, so the
			-- server knows exactly what the player was shown.
			title = ShopConfig.productTitle(product),
			layoutOrder = order,
		})

		local cardAspect = Instance.new("UIAspectRatioConstraint")
		cardAspect.AspectRatio = CARD_ASPECT
		cardAspect.DominantAxis = Enum.DominantAxis.Height
		cardAspect.Parent = card.root

		for index, quantity in ipairs(ShopConfig.BUY_QUANTITIES) do
			local button = Components.button({
				name = "Buy" .. quantity,
				parent = card.buttonRow,
				size = UDim2.fromScale(BUTTON_WIDTH, 1),
				text = ("Buy x%d"):format(quantity),
				textColor = Theme.Shop.TextOnLight,
				maxTextSize = Theme.Shop.MaxTextSize.Small,
				baseColor = Theme.Shop.PanelFill,
				font = Theme.Shop.Fonts.Ui,
				layoutOrder = index,
				trove = trove,
				onClick = function()
					props.onBuy(product.Id, quantity)
				end,
			})

			table.insert(buttons, button)
		end
	end

	return setmetatable({
		root = root,
		trove = trove,
		buttons = buttons,
	}, ProductView)
end

-- Held while a request is in flight. Every card's buttons go down, not just the
-- one clicked: the answer may be a purchase prompt, and two prompts at once is
-- not a state worth supporting.
function ProductView.SetBusy(self: ProductView, busy: boolean)
	for _, button in ipairs(self.buttons) do
		button.setEnabled(not busy)
	end
end

function ProductView.SetVisible(self: ProductView, visible: boolean)
	self.root.Visible = visible
end

function ProductView.Destroy(self: ProductView)
	self.trove:clean()
end

export type ProductView = typeof(setmetatable(
	{} :: {
		root: Frame,
		trove: Trove.Trove,
		buttons: { Components.Button },
	},
	ProductView
))

return ProductView
