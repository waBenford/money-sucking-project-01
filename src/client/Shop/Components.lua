--!strict
--[[
	Components
	The factories every shop view builds itself out of. Two rules they exist to
	enforce, in one place instead of thirty:

	1. Nothing names a colour. Callers pass Theme tokens in.
	2. No label carries a fixed TextSize. Everything is TextScaled with a cap, so
	   the same window is legible on a 4K monitor and a 390-wide phone.

	Properties are set explicitly rather than looped over a props table: --!strict
	cannot check `instance[key] = value`, and a typo in a key would then be a
	runtime error instead of a red squiggle.

	Parent is always assigned last, so the engine lays each subtree out once
	instead of on every property write.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Direct paths, not WaitForChild: --!strict resolves a module's exported types
-- only through a statically readable path, and this file annotates against
-- Trove.Trove. Everything required here is Rojo-synced and present before the
-- client's scripts run.
local Theme = require(ReplicatedStorage.Shared.Theme)
local Trove = require(script.Parent.Trove)

local Components = {}

-- Pixels between a tab and its selection ring. Padding, which the layout rules
-- allow as an offset.
local TAB_RING_INSET = 4

--// Types

export type LabelProps = {
	name: string,
	parent: Instance,
	size: UDim2,
	position: UDim2?,
	anchorPoint: Vector2?,
	text: string,
	textColor: Color3,
	maxTextSize: number,
	font: Font?,
	xAlign: Enum.TextXAlignment?,
	yAlign: Enum.TextYAlignment?,
	layoutOrder: number?,
	zIndex: number?,
}

export type BoxProps = {
	name: string,
	parent: Instance,
	size: UDim2,
	position: UDim2?,
	anchorPoint: Vector2?,
	color: Color3,
	cornerRadius: number?,
	stroked: boolean?,
	layoutOrder: number?,
	zIndex: number?,
}

export type ButtonProps = {
	name: string,
	parent: Instance,
	size: UDim2,
	position: UDim2?,
	anchorPoint: Vector2?,
	text: string,
	textColor: Color3,
	maxTextSize: number,
	baseColor: Color3,
	font: Font?,
	cornerRadius: number?,
	layoutOrder: number?,
	-- Every connection this factory makes is registered here, so a view's
	-- Destroy() cannot leave a hover handler alive.
	trove: Trove.Trove,
	onClick: (() -> ())?,
}

-- setBaseColor exists for the tab bar, whose selected state changes fill while
-- keeping its hover and press behaviour.
export type Button = {
	instance: TextButton,
	setEnabled: (enabled: boolean) -> (),
	setBaseColor: (color: Color3) -> (),
}

-- root, not button, is the layout item: the selection ring lives on a holder
-- around the button so it can sit outside the button's own black stroke.
export type Tab = {
	root: Frame,
	button: Button,
	setSelected: (selected: boolean) -> (),
}

export type TabProps = {
	name: string,
	parent: Instance,
	size: UDim2,
	position: UDim2?,
	anchorPoint: Vector2?,
	layoutOrder: number?,
	text: string,
	trove: Trove.Trove,
	onClick: () -> (),
}

export type CardProps = {
	name: string,
	parent: Instance,
	size: UDim2,
	title: string,
	layoutOrder: number?,
}

export type Card = {
	root: Frame,
	title: TextLabel,
	image: Frame,
	buttonRow: Frame,
}

--// Text

-- Money, grouped in threes. Here rather than in each view because the shop
-- writes a balance, three prices and a refund message, and four copies of this
-- would eventually disagree about the separator.
function Components.formatMoney(value: number): string
	local digits = tostring(math.max(math.floor(value), 0))
	local grouped = digits:reverse():gsub("(%d%d%d)", "%1,")

	-- Parenthesised to drop gsub's replacement count, and to strip the comma a
	-- multiple-of-three-digit number leaves on the front.
	return (grouped:reverse():gsub("^,", ""))
end

--// Primitives

-- Border mode, per the spec: the stroke sits outside the fill, which is what
-- makes the wireframe's outlines read as thick as they do.
function Components.stroke(parent: GuiObject, color: Color3?, thickness: number?): UIStroke
	local stroke = Instance.new("UIStroke")
	stroke.Color = color or Theme.Shop.Stroke
	stroke.Thickness = thickness or Theme.Shop.StrokeThickness
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = parent
	return stroke
end

function Components.corner(parent: GuiObject, radius: number): UICorner
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius)
	corner.Parent = parent
	return corner
end

-- A scale radius of 1 is always exactly a pill, at any size -- which is what the
-- spec's "999px" means in Roblox terms.
function Components.pillCorner(parent: GuiObject): UICorner
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = parent
	return corner
end

-- Offsets, which the layout rules allow for padding.
function Components.padding(parent: GuiObject, top: number, right: number, bottom: number, left: number): UIPadding
	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, top)
	padding.PaddingRight = UDim.new(0, right)
	padding.PaddingBottom = UDim.new(0, bottom)
	padding.PaddingLeft = UDim.new(0, left)
	padding.Parent = parent
	return padding
end

function Components.label(props: LabelProps): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = props.name
	label.Size = props.size
	label.BackgroundTransparency = 1
	label.BorderSizePixel = 0
	label.Text = props.text
	label.TextColor3 = props.textColor
	label.FontFace = props.font or Theme.Shop.Fonts.Ui
	label.TextScaled = true
	label.TextXAlignment = props.xAlign or Enum.TextXAlignment.Center
	label.TextYAlignment = props.yAlign or Enum.TextYAlignment.Center

	if props.position then
		label.Position = props.position
	end
	if props.anchorPoint then
		label.AnchorPoint = props.anchorPoint
	end
	if props.layoutOrder then
		label.LayoutOrder = props.layoutOrder
	end
	if props.zIndex then
		label.ZIndex = props.zIndex
	end

	local constraint = Instance.new("UITextSizeConstraint")
	constraint.MaxTextSize = props.maxTextSize
	constraint.Parent = label

	label.Parent = props.parent
	return label
end

function Components.box(props: BoxProps): Frame
	local box = Instance.new("Frame")
	box.Name = props.name
	box.Size = props.size
	box.BackgroundColor3 = props.color
	box.BorderSizePixel = 0

	if props.position then
		box.Position = props.position
	end
	if props.anchorPoint then
		box.AnchorPoint = props.anchorPoint
	end
	if props.layoutOrder then
		box.LayoutOrder = props.layoutOrder
	end
	if props.zIndex then
		box.ZIndex = props.zIndex
	end
	if props.cornerRadius and props.cornerRadius > 0 then
		Components.corner(box, props.cornerRadius)
	end
	if props.stroked then
		Components.stroke(box)
	end

	box.Parent = props.parent
	return box
end

-- The light content area: PanelFill, black stroke, square corners.
function Components.panel(props: BoxProps): Frame
	local panel = Components.box({
		name = props.name,
		parent = props.parent,
		size = props.size,
		position = props.position,
		anchorPoint = props.anchorPoint,
		color = props.color,
		cornerRadius = Theme.Shop.Corner.Panel,
		stroked = true,
		layoutOrder = props.layoutOrder,
		zIndex = props.zIndex,
	})
	return panel
end

function Components.pill(props: LabelProps): TextLabel
	local pill = Components.label(props)
	pill.BackgroundTransparency = 0
	pill.BackgroundColor3 = Theme.Shop.PillFill
	Components.pillCorner(pill)
	Components.stroke(pill)
	return pill
end

--// Buttons

-- AutoButtonColor is off on purpose: Roblox's own press darkening would fight
-- the states below, and it has no hover or disabled step at all.
function Components.button(props: ButtonProps): Button
	local instance = Instance.new("TextButton")
	instance.Name = props.name
	instance.Size = props.size
	instance.BackgroundColor3 = props.baseColor
	instance.BorderSizePixel = 0
	instance.AutoButtonColor = false
	instance.Text = props.text
	instance.TextColor3 = props.textColor
	instance.FontFace = props.font or Theme.Shop.Fonts.UiBold
	instance.TextScaled = true

	if props.position then
		instance.Position = props.position
	end
	if props.anchorPoint then
		instance.AnchorPoint = props.anchorPoint
	end
	if props.layoutOrder then
		instance.LayoutOrder = props.layoutOrder
	end

	local constraint = Instance.new("UITextSizeConstraint")
	constraint.MaxTextSize = props.maxTextSize
	constraint.Parent = instance

	Components.corner(instance, props.cornerRadius or Theme.Shop.Corner.Button)
	Components.stroke(instance)

	instance.Parent = props.parent

	local baseColor = props.baseColor
	local hovered = false
	local pressed = false
	local enabled = true

	local function repaint()
		local state: Theme.ButtonState = "Idle"

		if not enabled then
			state = "Disabled"
		elseif pressed then
			state = "Press"
		elseif hovered then
			state = "Hover"
		end

		instance.BackgroundColor3 = Theme.stateColor(baseColor, state)
		-- Disabled has to read as unavailable even where the fill is already
		-- pale, so the text fades with it.
		instance.TextTransparency = if enabled then 0 else 0.45
	end

	props.trove:add(instance.MouseEnter:Connect(function()
		hovered = true
		repaint()
	end))

	-- Clears pressed as well as hovered: releasing the mouse outside the button
	-- never sends MouseButton1Up here, and the button would stay dark.
	props.trove:add(instance.MouseLeave:Connect(function()
		hovered = false
		pressed = false
		repaint()
	end))

	props.trove:add(instance.MouseButton1Down:Connect(function()
		pressed = true
		repaint()
	end))

	props.trove:add(instance.MouseButton1Up:Connect(function()
		pressed = false
		repaint()
	end))

	local onClick = props.onClick
	if onClick then
		props.trove:add(instance.MouseButton1Click:Connect(function()
			-- Guarded here rather than by unbinding: a disabled button must still
			-- show its states, it just must not act.
			if enabled then
				onClick()
			end
		end))
	end

	repaint()

	return {
		instance = instance,

		setEnabled = function(value: boolean)
			enabled = value
			instance.Active = value
			instance.Selectable = value
			repaint()
		end,

		setBaseColor = function(color: Color3)
			baseColor = color
			repaint()
		end,
	}
end

--// Tabs

-- Selected and idle tabs share one fill; what changes is the white ring. Both
-- the main tab bar and the Accessory sub-tabs go through here, so the two can
-- never disagree about what "selected" looks like.
function Components.tab(props: TabProps): Tab
	local root = Instance.new("Frame")
	root.Name = props.name
	root.Size = props.size
	root.BackgroundTransparency = 1
	root.BorderSizePixel = 0

	if props.position then
		root.Position = props.position
	end
	if props.anchorPoint then
		root.AnchorPoint = props.anchorPoint
	end
	if props.layoutOrder then
		root.LayoutOrder = props.layoutOrder
	end

	Components.corner(root, Theme.Shop.Corner.Button + TAB_RING_INSET)

	local ring = Components.stroke(root, Theme.Shop.TabSelectedRing)
	ring.Enabled = false

	-- The inset is what makes the ring read as *outside* the tab rather than as a
	-- second border touching it.
	Components.padding(root, TAB_RING_INSET, TAB_RING_INSET, TAB_RING_INSET, TAB_RING_INSET)

	root.Parent = props.parent

	local button = Components.button({
		name = "Button",
		parent = root,
		size = UDim2.fromScale(1, 1),
		text = props.text,
		textColor = Theme.Shop.TextOnDark,
		maxTextSize = Theme.Shop.MaxTextSize.Tab,
		baseColor = Theme.Shop.TabIdle,
		trove = props.trove,
		onClick = props.onClick,
	})

	return {
		root = root,
		button = button,

		setSelected = function(selected: boolean)
			ring.Enabled = selected
		end,
	}
end

--// Cards

-- The gamepass card: title, a square placeholder where art will go, and a row
-- for its buy buttons. The caller fills the row, because how many buttons a card
-- gets comes from ShopConfig, not from here.
function Components.card(props: CardProps): Card
	local root = Instance.new("Frame")
	root.Name = props.name
	root.Size = props.size
	root.BackgroundTransparency = 1
	root.BorderSizePixel = 0

	if props.layoutOrder then
		root.LayoutOrder = props.layoutOrder
	end

	local title = Components.label({
		name = "Title",
		parent = root,
		size = UDim2.fromScale(1, 0.13),
		text = props.title,
		textColor = Theme.Shop.TextOnLight,
		maxTextSize = Theme.Shop.MaxTextSize.Title,
		font = Theme.Shop.Fonts.Display,
		xAlign = Enum.TextXAlignment.Left,
	})

	-- TODO: asset -- swap this Frame for an ImageLabel once product art exists.
	-- Square regardless of the card's own proportions, as drawn.
	local image = Components.box({
		name = "Image",
		parent = root,
		position = UDim2.fromScale(0, 0.19),
		size = UDim2.fromScale(0, 0.62),
		color = Theme.Shop.SlotFill,
	})

	local aspect = Instance.new("UIAspectRatioConstraint")
	aspect.AspectRatio = 1
	aspect.DominantAxis = Enum.DominantAxis.Height
	aspect.Parent = image

	local buttonRow = Instance.new("Frame")
	buttonRow.Name = "Buttons"
	buttonRow.Position = UDim2.fromScale(0, 0.86)
	buttonRow.Size = UDim2.fromScale(1, 0.14)
	buttonRow.BackgroundTransparency = 1
	buttonRow.BorderSizePixel = 0

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Padding = UDim.new(0.04, 0)
	layout.Parent = buttonRow

	buttonRow.Parent = root
	root.Parent = props.parent

	return {
		root = root,
		title = title,
		image = image,
		buttonRow = buttonRow,
	}
end

return table.freeze(Components)
