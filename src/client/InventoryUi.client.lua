--[[
	InventoryUi
	The player's bag: a centred panel with category tabs, a search box, a grid of
	item slots, a detail popup that appears when a slot is clicked, and a two-step
	discard dialog behind its trash button.

	Opened by the on-screen button (the only way that works on a phone) or by
	pressing B. Not Tab: Roblox's CoreGui reserves it for GUI keyboard
	navigation, so it arrives with gameProcessed = true and the guard below
	discards it. That same guard is why typing "b" into the search box does not
	close the panel.

	One kind of item is one slot, and a stack stops at InventoryConfig.MAX_STACK
	instead of spilling into a second slot, so "n/20" counts kinds held, not
	copies. The server enforces both -- everything here is display.

	The server only ever sends storyIds, counts and a revision; everything shown
	-- name, rarity, category, reward -- is resolved from the shared modules.

	Layout is done in one fixed design space (DESIGN_WIDTH x DESIGN_HEIGHT) and a
	UIScale shrinks the whole panel to fit the viewport. Mixing scale and offset
	per child would make square grid cells and readable text impossible to hold
	on both a monitor and a phone.

	Styling seam: createSlot() is the only function that builds a slot's visuals,
	and setDetail() the only one that writes the detail popup -- including showing
	and hiding it, so nothing else needs to know it is conditional. Swap
	createSlot's body for ReplicatedStorage.Assets.ItemSlot:Clone() when there are
	icons; until then a slot shows the item's name as placeholder art.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local InventoryConfig = require(Shared:WaitForChild("InventoryConfig"))
local ItemCategories = require(Shared:WaitForChild("ItemCategories"))
-- ItemData, not StoryData: the bag holds accessories and bed upgrades as well
-- now, and resolving through the Story catalog alone would silently drop every
-- slot that is not a Story.
local ItemData = require(Shared:WaitForChild("ItemData"))
local Rarity = require(Shared:WaitForChild("Rarity"))
local Theme = require(Shared:WaitForChild("Theme"))

-- Timed, so a missing instance says so instead of yielding forever. An untimed
-- WaitForChild here would leave the script hanging with the UI simply absent --
-- the hardest kind of failure to diagnose.
local Remotes = ReplicatedStorage:WaitForChild("Remotes", 10)
if not Remotes then
	warn("InventoryUi: ReplicatedStorage.Remotes is missing -- restart `rojo serve` so it re-reads default.project.json")
	return
end

local InventoryUpdated = Remotes:WaitForChild("InventoryUpdated", 10)
local GetInventory = Remotes:WaitForChild("GetInventory", 10)
local DiscardItem = Remotes:WaitForChild("DiscardItem", 10)

if not (InventoryUpdated and GetInventory and DiscardItem) then
	warn("InventoryUi: Remotes folder is missing InventoryUpdated, GetInventory or DiscardItem")
	return
end

--// Configuration

local TOGGLE_KEY = Enum.KeyCode.B

-- The design space every offset below is written in. The panel never renders at
-- more than 1:1; it only ever scales down.
local DESIGN_WIDTH = 960
local DESIGN_HEIGHT = 480

local VIEWPORT_MARGIN_X = 0.92 -- fraction of the screen the panel may occupy
local VIEWPORT_MARGIN_Y = 0.86
local MIN_SCALE = 0.4 -- below this the text stops being readable anyway

local PADDING = 14
local GAP = 10
local HEADER_HEIGHT = 44
local TAB_HEIGHT = 34
local TOOLBAR_HEIGHT = 32
local DETAIL_HEIGHT = 140
local CELL_SIZE = 72
local CELL_PADDING = 8

local CONTENT_WIDTH = DESIGN_WIDTH - (PADDING * 2)
local BODY_Y = PADDING + HEADER_HEIGHT + GAP + TAB_HEIGHT + GAP
local BODY_HEIGHT = DESIGN_HEIGHT - BODY_Y - PADDING
local GRID_Y = TOOLBAR_HEIGHT + GAP
-- The grid owns the whole area below the toolbar. The detail popup is drawn over
-- its lower strip rather than given a lane of its own, so nothing is left as
-- dead space while no item is selected.
local GRID_HEIGHT = BODY_HEIGHT - GRID_Y

local player = Players.LocalPlayer

--// State

-- [storyId] = { slot = TextButton, count = number }
local entries = {}

local activeTab = ItemCategories.ALL
local selectedId = nil
local searchText = ""

-- Revision of the newest change already applied. Counts can go down now, so
-- "the bigger count wins" no longer works: the server's revision number is what
-- orders messages. See the snapshot block at the bottom.
local localRevision = 0
local snapshotApplied = false
local bufferedUpdates = {}

-- How many copies the open discard dialog is about to throw away.
local discardAmount = 1

--// Helpers

-- Properties first, Parent last: every write happens while the instance is
-- still outside the tree, so the engine lays the panel out once at the end
-- rather than on each assignment.
local function make(className, props)
	local instance = Instance.new(className)
	local parent = props.Parent
	props.Parent = nil

	for key, value in pairs(props) do
		instance[key] = value
	end

	instance.Parent = parent
	return instance
end

local function round(instance, radius)
	make("UICorner", { CornerRadius = UDim.new(0, radius), Parent = instance })
	return instance
end

local function label(props)
	props.BackgroundTransparency = props.BackgroundTransparency or 1
	props.TextColor3 = props.TextColor3 or Theme.TEXT
	props.TextSize = props.TextSize or 14
	props.Font = props.Font or Enum.Font.Gotham
	return make("TextLabel", props)
end

local function button(props)
	props.BorderSizePixel = 0
	props.TextColor3 = props.TextColor3 or Theme.TEXT
	props.TextSize = props.TextSize or 14
	props.Font = props.Font or Enum.Font.GothamBold
	props.AutoButtonColor = true
	return make("TextButton", props)
end

-- Driven by Rarity.MAX, so the six-tier ladder the shop introduced needs no UI
-- change here. Stories only reach five and simply show two empty pips.
local function rarityStars(rarity)
	return string.rep("*", rarity) .. string.rep("-", Rarity.MAX - rarity)
end

-- Capacity is per category, so the counter answers for whichever tab is open:
-- the ALL tab sums every category, a single tab reports only its own.
local function capacityFor(category)
	if category == ItemCategories.ALL then
		return InventoryConfig.totalSlots()
	end
	return InventoryConfig.slotsFor(category)
end

local function slotsUsedIn(category)
	local used = 0

	for itemId in pairs(entries) do
		local item = ItemData.getItemById(itemId)
		if item and (category == ItemCategories.ALL or item.Category == category) then
			used += 1
		end
	end

	return used
end

--// Screen

local screenGui = make("ScreenGui", {
	Name = "InventoryUi",
	-- Essential: the default destroys this on every respawn, which would leave
	-- every cached slot reference pointing at a destroyed instance and silently
	-- break all further updates.
	ResetOnSpawn = false,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	Parent = player:WaitForChild("PlayerGui"),
})

-- Below the topbar but clear of both thumbstick and jump button, which own the
-- bottom corners on touch devices.
local openButton = round(button({
	Name = "OpenButton",
	AnchorPoint = Vector2.new(1, 0),
	Position = UDim2.new(1, -16, 0, 16),
	Size = UDim2.fromOffset(56, 56),
	BackgroundColor3 = Theme.HEADER_BG,
	Text = "BAG",
	TextSize = 13,
	Parent = screenGui,
}), 28)

local panel = round(make("Frame", {
	Name = "Panel",
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.5),
	Size = UDim2.fromOffset(DESIGN_WIDTH, DESIGN_HEIGHT),
	BackgroundColor3 = Theme.PANEL_BG,
	BackgroundTransparency = 0.05,
	BorderSizePixel = 0,
	Visible = false,
	Parent = screenGui,
}), 12)

local panelScale = make("UIScale", { Parent = panel })

-- Scales about the panel's own centre because its AnchorPoint is (0.5, 0.5), so
-- shrinking never pushes it off screen.
local function updateScale()
	local camera = Workspace.CurrentCamera
	local viewport = camera and camera.ViewportSize or Vector2.new(1280, 720)

	if viewport.X <= 0 or viewport.Y <= 0 then
		return -- one frame during camera setup
	end

	local scale = math.min(
		(viewport.X * VIEWPORT_MARGIN_X) / DESIGN_WIDTH,
		(viewport.Y * VIEWPORT_MARGIN_Y) / DESIGN_HEIGHT,
		1
	)

	panelScale.Scale = math.max(scale, MIN_SCALE)
end

--// Header

local titleBar = round(make("Frame", {
	Name = "TitleBar",
	AnchorPoint = Vector2.new(0.5, 0),
	Position = UDim2.new(0.5, 0, 0, PADDING),
	Size = UDim2.fromOffset(360, HEADER_HEIGHT),
	BackgroundColor3 = Theme.HEADER_BG,
	BorderSizePixel = 0,
	Parent = panel,
}), 8)

label({
	Name = "Title",
	Size = UDim2.fromScale(1, 1),
	Text = "Inventory",
	TextSize = 22,
	Font = Enum.Font.GothamBold,
	Parent = titleBar,
})

local closeButton = round(button({
	Name = "Close",
	AnchorPoint = Vector2.new(1, 0),
	Position = UDim2.new(1, -PADDING, 0, PADDING),
	Size = UDim2.fromOffset(HEADER_HEIGHT, HEADER_HEIGHT),
	BackgroundColor3 = Theme.DANGER,
	Text = "X",
	TextSize = 20,
	Parent = panel,
}), 8)

--// Tabs

local tabsRow = make("Frame", {
	Name = "Tabs",
	Position = UDim2.fromOffset(PADDING, PADDING + HEADER_HEIGHT + GAP),
	Size = UDim2.fromOffset(CONTENT_WIDTH, TAB_HEIGHT),
	BackgroundTransparency = 1,
	Parent = panel,
})

make("UIListLayout", {
	FillDirection = Enum.FillDirection.Horizontal,
	SortOrder = Enum.SortOrder.LayoutOrder,
	Padding = UDim.new(0, 8),
	Parent = tabsRow,
})

-- [categoryId] = TextButton. Built from ItemCategories.Order, so a new category
-- appears here without touching this file.
local tabButtons = {}

--// Body

local body = make("Frame", {
	Name = "Body",
	Position = UDim2.fromOffset(PADDING, BODY_Y),
	Size = UDim2.fromOffset(CONTENT_WIDTH, BODY_HEIGHT),
	BackgroundTransparency = 1,
	Parent = panel,
})

local searchBox = round(make("TextBox", {
	Name = "Search",
	Size = UDim2.fromOffset(280, TOOLBAR_HEIGHT),
	BackgroundColor3 = Theme.FIELD_BG,
	BorderSizePixel = 0,
	Text = "",
	PlaceholderText = "Search",
	PlaceholderColor3 = Theme.TEXT_MUTED,
	TextColor3 = Theme.TEXT,
	TextSize = 14,
	Font = Enum.Font.Gotham,
	TextXAlignment = Enum.TextXAlignment.Left,
	-- Otherwise clicking the box to fix a typo wipes the filter.
	ClearTextOnFocus = false,
	Parent = body,
}), 6)

make("UIPadding", {
	PaddingLeft = UDim.new(0, 10),
	PaddingRight = UDim.new(0, 10),
	Parent = searchBox,
})

local capacityLabel = label({
	Name = "Capacity",
	Position = UDim2.fromOffset(296, 0),
	Size = UDim2.fromOffset(160, TOOLBAR_HEIGHT),
	Text = "0/" .. InventoryConfig.totalSlots(),
	TextSize = 18,
	Font = Enum.Font.GothamBold,
	TextXAlignment = Enum.TextXAlignment.Left,
	Parent = body,
})

local grid = make("ScrollingFrame", {
	Name = "Grid",
	Position = UDim2.fromOffset(0, GRID_Y),
	Size = UDim2.fromOffset(CONTENT_WIDTH, GRID_HEIGHT),
	BackgroundColor3 = Theme.HEADER_BG,
	BackgroundTransparency = 0.5,
	BorderSizePixel = 0,
	ScrollBarThickness = 8,
	ScrollingDirection = Enum.ScrollingDirection.Y,
	-- UIGridLayout drives the canvas height, so slots can be added without any
	-- manual CanvasSize arithmetic.
	CanvasSize = UDim2.new(),
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
	Parent = body,
})
round(grid, 6)

make("UIPadding", {
	PaddingTop = UDim.new(0, 8),
	PaddingLeft = UDim.new(0, 8),
	PaddingBottom = UDim.new(0, 8),
	Parent = grid,
})

make("UIGridLayout", {
	CellSize = UDim2.fromOffset(CELL_SIZE, CELL_SIZE),
	CellPadding = UDim2.fromOffset(CELL_PADDING, CELL_PADDING),
	SortOrder = Enum.SortOrder.LayoutOrder,
	Parent = grid,
})

-- Parented to the body, not the grid: a child of the grid would be laid out as
-- another cell and would drag the canvas height around.
local emptyState = label({
	Name = "EmptyState",
	Position = UDim2.fromOffset(0, GRID_Y),
	Size = UDim2.fromOffset(CONTENT_WIDTH, GRID_HEIGHT),
	Text = "",
	TextColor3 = Theme.TEXT_MUTED,
	TextWrapped = true,
	Parent = body,
})

--// Detail popup
--
-- Hidden until a slot is clicked, and drawn above the grid it overlaps. The two
-- rows a full inventory needs sit clear of it, so nothing reachable ends up
-- behind the popup.

local detail = round(make("Frame", {
	Name = "Detail",
	Position = UDim2.fromOffset(0, BODY_HEIGHT - DETAIL_HEIGHT),
	Size = UDim2.fromOffset(CONTENT_WIDTH, DETAIL_HEIGHT),
	BackgroundColor3 = Theme.HEADER_BG,
	BorderSizePixel = 0,
	Visible = false,
	ZIndex = 3,
	Parent = body,
}), 8)

-- Reads as a layer sitting on top of the grid rather than part of it.
make("UIStroke", {
	Color = Theme.ACCENT,
	Thickness = 2,
	Transparency = 0.4,
	Parent = detail,
})

local detailInfo = make("ScrollingFrame", {
	Name = "Info",
	Position = UDim2.fromOffset(14, 10),
	Size = UDim2.new(1, -80, 1, -20),
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	ScrollBarThickness = 6,
	ScrollingDirection = Enum.ScrollingDirection.Y,
	CanvasSize = UDim2.new(),
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
	Parent = detail,
})

make("UIListLayout", {
	SortOrder = Enum.SortOrder.LayoutOrder,
	Padding = UDim.new(0, 4),
	Parent = detailInfo,
})

-- Built once and rewritten by setDetail; the popup always shows the same set of
-- lines, so there is nothing to create or destroy per selection.
local function detailLine(order, props)
	props.LayoutOrder = order
	props.Size = UDim2.new(1, 0, 0, props.LineHeight or 20)
	props.LineHeight = nil
	props.TextXAlignment = Enum.TextXAlignment.Left
	props.TextWrapped = true
	props.Parent = detailInfo
	return label(props)
end

local detailName = detailLine(1, { Name = "ItemName", Text = "", TextSize = 20, Font = Enum.Font.GothamBold, LineHeight = 26 })
local detailRarity = detailLine(2, { Name = "Rarity", Text = "" })
local detailCategory = detailLine(3, { Name = "Category", Text = "", TextColor3 = Theme.TEXT_MUTED })
local detailReward = detailLine(4, { Name = "Reward", Text = "", TextColor3 = Theme.TEXT_MUTED })
local detailHeld = detailLine(5, { Name = "Held", Text = "", TextColor3 = Theme.TEXT_MUTED })

-- The popup's own dismiss. Without it the only ways out would be switching tab
-- or emptying the stack, neither of which is obvious.
local detailClose = round(button({
	Name = "Close",
	AnchorPoint = Vector2.new(1, 0),
	Position = UDim2.new(1, -12, 0, 10),
	Size = UDim2.fromOffset(28, 28),
	BackgroundColor3 = Theme.FIELD_BG,
	Text = "X",
	TextSize = 14,
	Parent = detail,
}), 6)

local trashButton = round(button({
	Name = "Trash",
	AnchorPoint = Vector2.new(1, 1),
	Position = UDim2.new(1, -12, 1, -12),
	Size = UDim2.fromOffset(44, 44),
	BackgroundColor3 = Theme.DANGER,
	Text = "DEL",
	TextSize = 13,
	Parent = detail,
}), 6)

--// Discard dialog

-- Active = true so the dim layer swallows clicks: without it the grid and tabs
-- behind stay clickable while a confirmation is on screen.
local dialogOverlay = make("Frame", {
	Name = "DiscardOverlay",
	Size = UDim2.fromScale(1, 1),
	BackgroundColor3 = Color3.new(0, 0, 0),
	BackgroundTransparency = 0.45,
	BorderSizePixel = 0,
	Active = true,
	Visible = false,
	ZIndex = 5,
	Parent = panel,
})

local dialog = round(make("Frame", {
	Name = "Dialog",
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.5),
	Size = UDim2.fromOffset(360, 190),
	BackgroundColor3 = Theme.PANEL_BG,
	BorderSizePixel = 0,
	ZIndex = 6,
	Parent = dialogOverlay,
}), 10)

local function dialogStep(name)
	return make("Frame", {
		Name = name,
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Visible = false,
		Parent = dialog,
	})
end

-- Step one: how many.
local amountStep = dialogStep("AmountStep")

label({
	Position = UDim2.fromOffset(0, 14),
	Size = UDim2.new(1, 0, 0, 24),
	Text = "Throw away how many?",
	TextSize = 17,
	Font = Enum.Font.GothamBold,
	Parent = amountStep,
})

local amountItemName = label({
	Name = "ItemName",
	Position = UDim2.fromOffset(16, 40),
	Size = UDim2.new(1, -32, 0, 20),
	Text = "",
	TextColor3 = Theme.TEXT_MUTED,
	TextTruncate = Enum.TextTruncate.AtEnd,
	Parent = amountStep,
})

local minusButton = round(button({
	Name = "Minus",
	Position = UDim2.fromOffset(104, 70),
	Size = UDim2.fromOffset(44, 44),
	BackgroundColor3 = Theme.FIELD_BG,
	Text = "-",
	TextSize = 24,
	Parent = amountStep,
}), 6)

local amountLabel = label({
	Name = "Amount",
	Position = UDim2.fromOffset(148, 70),
	Size = UDim2.fromOffset(64, 44),
	Text = "1",
	TextSize = 22,
	Font = Enum.Font.GothamBold,
	Parent = amountStep,
})

local plusButton = round(button({
	Name = "Plus",
	Position = UDim2.fromOffset(212, 70),
	Size = UDim2.fromOffset(44, 44),
	BackgroundColor3 = Theme.FIELD_BG,
	Text = "+",
	TextSize = 24,
	Parent = amountStep,
}), 6)

local amountCancel = round(button({
	Name = "Cancel",
	Position = UDim2.fromOffset(24, 130),
	Size = UDim2.fromOffset(140, 40),
	BackgroundColor3 = Theme.FIELD_BG,
	Text = "Cancel",
	Parent = amountStep,
}), 6)

local amountNext = round(button({
	Name = "Next",
	Position = UDim2.fromOffset(196, 130),
	Size = UDim2.fromOffset(140, 40),
	BackgroundColor3 = Theme.ACCENT,
	Text = "Next",
	Parent = amountStep,
}), 6)

-- Step two: are you sure.
local confirmStep = dialogStep("ConfirmStep")

local confirmMessage = label({
	Name = "Message",
	Position = UDim2.fromOffset(20, 24),
	Size = UDim2.new(1, -40, 0, 80),
	Text = "",
	TextSize = 16,
	TextWrapped = true,
	Parent = confirmStep,
})

local confirmCancel = round(button({
	Name = "Cancel",
	Position = UDim2.fromOffset(24, 130),
	Size = UDim2.fromOffset(140, 40),
	BackgroundColor3 = Theme.FIELD_BG,
	Text = "Back",
	Parent = confirmStep,
}), 6)

local confirmDiscard = round(button({
	Name = "Confirm",
	Position = UDim2.fromOffset(196, 130),
	Size = UDim2.fromOffset(140, 40),
	BackgroundColor3 = Theme.DANGER,
	Text = "Discard",
	Parent = confirmStep,
}), 6)

--// Rendering

local refresh -- forward declared: selection and the dialog both drive it

local function setDetail(itemId)
	local entry = itemId and entries[itemId]
	local item = itemId and ItemData.getItemById(itemId)

	if not (entry and item) then
		-- Nothing selected: the whole popup goes away rather than sitting there
		-- empty, which is what the mockup's "appears when you click an item" means.
		detail.Visible = false
		return
	end

	detailName.Text = item.Name
	detailRarity.Text = ("Rarity  %s"):format(rarityStars(item.Rarity))
	detailRarity.TextColor3 = Theme.rarityColor(item.Rarity)
	-- The last fallback is for data that forgot to set a category: a nil here
	-- would make format() throw and take the whole popup with it.
	local categoryName = ItemCategories.DisplayNames[item.Category] or item.Category or "Unknown"
	detailCategory.Text = ("Category  %s"):format(categoryName)

	-- One line for what the item is worth, whichever kind it is. Stories pay out
	-- at the bed; accessories and upgrades carry a buff instead, and reading
	-- BaseReward off one of those would format a nil and take the popup down.
	if item.BaseReward then
		detailReward.Text = ("Dream reward  %d per cycle"):format(item.BaseReward)
	else
		detailReward.Text = ItemData.describeBuff(item) or ""
	end

	detailHeld.Text = ("Held  %d / %d"):format(entry.count, InventoryConfig.MAX_STACK)

	detail.Visible = true
end

-- Passing nil dismisses the popup and clears the highlight.
local function selectSlot(storyId)
	selectedId = storyId
	setDetail(storyId)

	for id, entry in pairs(entries) do
		entry.slot.BackgroundColor3 = (id == storyId) and Theme.SLOT_SELECTED_BG or Theme.SLOT_BG
	end
end

detailClose.MouseButton1Click:Connect(function()
	selectSlot(nil)
end)

-- The single styling seam. Everything below only reads slot.Quantity and
-- slot.BackgroundColor3, so replacing this body with a cloned asset is a local
-- change.
local function createSlot(story)
	local slot = round(button({
		Name = story.Id,
		BackgroundColor3 = Theme.SLOT_BG,
		Text = "",
		-- Higher rarity sorts to the top.
		LayoutOrder = Rarity.MAX - story.Rarity,
	}), 6)

	make("UIStroke", {
		Color = Theme.rarityColor(story.Rarity),
		Thickness = 2,
		Parent = slot,
	})

	-- Placeholder art: the name, shrunk to fit. Becomes an ImageLabel the moment
	-- there are icons to point it at.
	label({
		Name = "Icon",
		Position = UDim2.fromOffset(4, 4),
		Size = UDim2.new(1, -8, 1, -20),
		Text = story.Name,
		TextSize = 11,
		TextWrapped = true,
		TextColor3 = Theme.TEXT_MUTED,
		Parent = slot,
	})

	label({
		Name = "Quantity",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -4, 1, -2),
		Size = UDim2.fromOffset(30, 16),
		Text = "x0",
		TextSize = 13,
		Font = Enum.Font.GothamBold,
		TextXAlignment = Enum.TextXAlignment.Right,
		Parent = slot,
	})

	slot.MouseButton1Click:Connect(function()
		selectSlot(story.Id)
	end)

	return slot
end

local closeDialog -- forward declared: refresh closes it when a stack vanishes

function refresh()
	local visible = 0

	for storyId, entry in pairs(entries) do
		local story = ItemData.getItemById(storyId)
		local matchesTab = story and ItemCategories.matches(activeTab, story.Category)
		local matchesSearch = searchText == ""
			or (story and string.find(string.lower(story.Name), searchText, 1, true) ~= nil)

		local shown = (matchesTab and matchesSearch) or false
		entry.slot.Visible = shown

		if shown then
			visible += 1
		end
	end

	-- A selection the current tab or search has hidden must let go of the detail
	-- strip too, or the trash button stays live for an item no longer on screen.
	if selectedId then
		local selected = entries[selectedId]
		if not (selected and selected.slot.Visible) then
			selectSlot(nil)
			closeDialog()
		end
	end

	if visible > 0 then
		emptyState.Visible = false
	else
		emptyState.Visible = true
		emptyState.Text = if searchText ~= ""
			then ("Nothing here matches \"%s\"."):format(searchBox.Text)
			else ItemCategories.EmptyMessages[activeTab] or "Nothing here yet."
	end

	-- Reports the open tab's own budget, because that is the limit a player is
	-- about to hit: a full Upgrade shelf does not stop them collecting Stories.
	local capacity = capacityFor(activeTab)
	local used = slotsUsedIn(activeTab)

	capacityLabel.Text = ("%d/%d"):format(used, capacity)
	capacityLabel.TextColor3 = (used >= capacity) and Theme.DANGER or Theme.TEXT

	for categoryId, tabButton in pairs(tabButtons) do
		local isActive = categoryId == activeTab
		tabButton.BackgroundColor3 = isActive and Theme.ACCENT or Theme.HEADER_BG
		tabButton.TextColor3 = isActive and Color3.new(1, 1, 1) or Theme.TEXT
	end
end

local function setCount(storyId, count)
	local story = ItemData.getItemById(storyId)
	if not story then
		-- A story removed in a later update: ignore rather than render a blank
		-- slot from an old save.
		return
	end

	local entry = entries[storyId]

	if count <= 0 then
		-- Destroyed, not left showing "x0": the slot has to disappear, and a
		-- lingering entry would also keep counting against the n/20 display.
		if entry then
			entry.slot:Destroy()
			entries[storyId] = nil
		end

		-- refresh() lets go of the selection and closes any open dialog once the
		-- entry is gone, so there is nothing else to clean up here.
		refresh()
		return
	end

	if not entry then
		local slot = createSlot(story)
		slot.Parent = grid
		entry = { slot = slot, count = 0 }
		entries[storyId] = entry
	end

	entry.count = count
	entry.slot.Quantity.Text = "x" .. count

	if selectedId == storyId then
		setDetail(storyId)
		-- The stack may have shrunk under an open dialog.
		discardAmount = math.clamp(discardAmount, 1, count)
		amountLabel.Text = tostring(discardAmount)
	end

	refresh()
end

--// Tabs, search, open and close

for order, categoryId in ipairs(ItemCategories.Order) do
	local tabButton = round(button({
		Name = categoryId,
		LayoutOrder = order,
		-- Sized by its own text, so a longer category name cannot be clipped.
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, TAB_HEIGHT),
		BackgroundColor3 = Theme.HEADER_BG,
		Text = ItemCategories.DisplayNames[categoryId] or categoryId,
		Parent = tabsRow,
	}), 6)

	make("UIPadding", {
		PaddingLeft = UDim.new(0, 18),
		PaddingRight = UDim.new(0, 18),
		Parent = tabButton,
	})

	tabButton.MouseButton1Click:Connect(function()
		activeTab = categoryId
		refresh()
	end)

	tabButtons[categoryId] = tabButton
end

searchBox:GetPropertyChangedSignal("Text"):Connect(function()
	-- Lowered once here rather than per slot on every keystroke.
	searchText = string.lower(searchBox.Text)
	refresh()
end)

local function setPanelOpen(open)
	panel.Visible = open

	if not open then
		closeDialog()
	end
end

openButton.MouseButton1Click:Connect(function()
	setPanelOpen(not panel.Visible)
end)

closeButton.MouseButton1Click:Connect(function()
	setPanelOpen(false)
end)

--// Discard flow

function closeDialog()
	dialogOverlay.Visible = false
	amountStep.Visible = false
	confirmStep.Visible = false
end

local function showAmountStep()
	amountStep.Visible = true
	confirmStep.Visible = false
	amountLabel.Text = tostring(discardAmount)
end

local function setAmount(amount)
	local entry = selectedId and entries[selectedId]
	if not entry then
		return
	end

	discardAmount = math.clamp(amount, 1, entry.count)
	amountLabel.Text = tostring(discardAmount)
end

trashButton.MouseButton1Click:Connect(function()
	local entry = selectedId and entries[selectedId]
	local story = selectedId and ItemData.getItemById(selectedId)
	if not (entry and story) then
		return
	end

	discardAmount = 1
	amountItemName.Text = story.Name
	dialogOverlay.Visible = true
	showAmountStep()
end)

minusButton.MouseButton1Click:Connect(function()
	setAmount(discardAmount - 1)
end)

plusButton.MouseButton1Click:Connect(function()
	setAmount(discardAmount + 1)
end)

amountCancel.MouseButton1Click:Connect(closeDialog)
confirmCancel.MouseButton1Click:Connect(showAmountStep)

amountNext.MouseButton1Click:Connect(function()
	local story = selectedId and ItemData.getItemById(selectedId)
	if not story then
		closeDialog()
		return
	end

	confirmMessage.Text = ("Throw away %d x %s?\nThis cannot be undone -- discarded Stories are gone, not sold.")
		:format(discardAmount, story.Name)

	amountStep.Visible = false
	confirmStep.Visible = true
end)

confirmDiscard.MouseButton1Click:Connect(function()
	local storyId = selectedId
	closeDialog()

	if not storyId then
		return
	end

	-- A request, not an instruction: the count on screen only changes when the
	-- server answers on InventoryUpdated, so a rejected discard cannot leave the
	-- UI showing a stack the player still owns.
	DiscardItem:FireServer(storyId, discardAmount)
end)

--// Server sync

local function applyUpdate(storyId, count, revision)
	if type(revision) == "number" then
		-- Anything at or behind what is already applied is a straggler from
		-- before the snapshot; applying it would resurrect an old count.
		if revision <= localRevision then
			return
		end
		localRevision = revision
	end

	setCount(storyId, count)
end

-- Connected before the snapshot request below: a grant landing during the
-- round-trip would otherwise be missed entirely. Until the snapshot has been
-- applied these are held back, because the snapshot overwrites counts wholesale
-- and would undo them.
InventoryUpdated.OnClientEvent:Connect(function(storyId, count, revision)
	if not snapshotApplied then
		table.insert(bufferedUpdates, { storyId = storyId, count = count, revision = revision })
		return
	end

	applyUpdate(storyId, count, revision)
end)

task.spawn(function()
	local snapshot = GetInventory:InvokeServer()

	-- nil means throttled or declined. The buffered updates below still replay,
	-- so the panel fills in from live grants instead of staying blank forever.
	if type(snapshot) == "table" and type(snapshot.items) == "table" then
		localRevision = tonumber(snapshot.revision) or 0

		for storyId, count in pairs(snapshot.items) do
			setCount(storyId, count)
		end
	end

	-- Nothing between here and the end of the replay yields, so no update can
	-- slip past both the buffer and this loop.
	snapshotApplied = true

	for _, update in ipairs(bufferedUpdates) do
		applyUpdate(update.storyId, update.count, update.revision)
	end

	bufferedUpdates = {}
end)

--// Lifecycle

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	-- Same guard as Sprint.client.lua. It is also what keeps typing "b" into the
	-- search box from closing the panel.
	if gameProcessed then
		return
	end

	if input.KeyCode == TOGGLE_KEY then
		setPanelOpen(not panel.Visible)
	end
end)

updateScale()

-- The camera is occasionally not assigned yet on the first frame, and the
-- viewport changes on window resize and on a phone rotating.
Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
	local camera = Workspace.CurrentCamera
	if camera then
		camera:GetPropertyChangedSignal("ViewportSize"):Connect(updateScale)
		updateScale()
	end
end)

if Workspace.CurrentCamera then
	Workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(updateScale)
end

setDetail(nil)
refresh()
