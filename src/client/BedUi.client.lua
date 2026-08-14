--[[
	BedUi
	The dream panel: pick a Story to feed the bed, or see what it is already
	dreaming. Opened by walking to a Bed and pressing E -- BedInteraction fires
	the OpenRequest signal this script creates below.

	Two states, one panel. Idle lists the Stories the player holds with what each
	is worth in total (BaseReward x CYCLES_PER_STORY). Active shows the running
	dream and cannot start another.

	Everything here is display. The client sends a storyId and nothing else: the
	server resolves the bed from the player's own plot, re-reads the reward from
	StoryData every cycle, and consumeStory is what proves ownership.

	Layout follows InventoryUi: one fixed design space (DESIGN_WIDTH x
	DESIGN_HEIGHT) with a UIScale shrinking the panel to fit the viewport, rather
	than mixing scale and offset per child.

	Styling seam: createStoryRow() is the only function that builds a row's
	visuals, the role createSlot() plays in InventoryUi.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BedConfig = require(Shared:WaitForChild("BedConfig"))
local StoryData = require(Shared:WaitForChild("StoryData"))
local Theme = require(Shared:WaitForChild("Theme"))

-- Timed, so a missing instance says so instead of yielding forever. An untimed
-- WaitForChild here would leave the script hanging with the UI simply absent --
-- the hardest kind of failure to diagnose.
local Remotes = ReplicatedStorage:WaitForChild("Remotes", 10)
if not Remotes then
	warn("BedUi: ReplicatedStorage.Remotes is missing -- restart `rojo serve` so it re-reads default.project.json")
	return
end

local StartDream = Remotes:WaitForChild("StartDream", 10)
local BedStateChanged = Remotes:WaitForChild("BedStateChanged", 10)
local GetBedState = Remotes:WaitForChild("GetBedState", 10)
local GetInventory = Remotes:WaitForChild("GetInventory", 10)
local InventoryUpdated = Remotes:WaitForChild("InventoryUpdated", 10)

if not (StartDream and BedStateChanged and GetBedState and GetInventory and InventoryUpdated) then
	warn("BedUi: Remotes is missing one of StartDream/BedStateChanged/GetBedState/GetInventory/InventoryUpdated")
	return
end

--// Configuration

-- The design space every offset below is written in. The panel never renders at
-- more than 1:1; it only ever scales down.
local DESIGN_WIDTH = 960
local DESIGN_HEIGHT = 480

local VIEWPORT_MARGIN_X = 0.92
local VIEWPORT_MARGIN_Y = 0.86
local MIN_SCALE = 0.4

local PADDING = 14
local GAP = 10
local HEADER_HEIGHT = 44
local FOOTER_HEIGHT = 44
local ROW_HEIGHT = 46

local CONTENT_WIDTH = DESIGN_WIDTH - (PADDING * 2)
local BODY_Y = PADDING + HEADER_HEIGHT + GAP
local BODY_HEIGHT = DESIGN_HEIGHT - BODY_Y - FOOTER_HEIGHT - GAP - PADDING

local player = Players.LocalPlayer

--// State

-- [storyId] = { row = TextButton, count = number }
local rows = {}

local counts = {} -- [storyId] = count, the inventory as the panel knows it
local selectedId = nil
local bedActive = false
local bedStoryId = nil
local bedCyclesLeft = 0

--// Helpers
--
-- Same shapes as InventoryUi, so the two panels stay visually identical.

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

-- Driven by MAX_RARITY, so adding a sixth tier needs no UI change.
local function rarityStars(rarity)
	return string.rep("*", rarity) .. string.rep("-", StoryData.MAX_RARITY - rarity)
end

--// Screen

local screenGui = make("ScreenGui", {
	Name = "BedUi",
	-- Essential: the default destroys this on every respawn, which would leave
	-- every cached row reference pointing at a destroyed instance and silently
	-- break all further updates.
	ResetOnSpawn = false,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	Parent = player:WaitForChild("PlayerGui"),
})

-- Created here, by the consumer, so it always exists before BedInteraction can
-- fire it. Two LocalScripts cannot call each other directly.
local openRequest = make("BindableEvent", { Name = "OpenRequest", Parent = screenGui })

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
	Size = UDim2.fromOffset(CONTENT_WIDTH, HEADER_HEIGHT),
	BackgroundColor3 = Theme.HEADER_BG,
	BorderSizePixel = 0,
	Parent = panel,
}), 8)

local title = label({
	Name = "Title",
	Position = UDim2.fromOffset(16, 0),
	Size = UDim2.new(1, -140, 1, 0),
	Text = "Dream",
	TextSize = 20,
	Font = Enum.Font.GothamBold,
	TextXAlignment = Enum.TextXAlignment.Left,
	Parent = titleBar,
})

local closeButton = round(button({
	Name = "CloseButton",
	AnchorPoint = Vector2.new(1, 0.5),
	Position = UDim2.new(1, -8, 0.5, 0),
	Size = UDim2.fromOffset(28, 28),
	BackgroundColor3 = Theme.SLOT_BG,
	Text = "X",
	Parent = titleBar,
}), 6)

--// Body -- Idle: the story list

local list = make("ScrollingFrame", {
	Name = "List",
	AnchorPoint = Vector2.new(0.5, 0),
	Position = UDim2.new(0.5, 0, 0, BODY_Y),
	Size = UDim2.fromOffset(CONTENT_WIDTH, BODY_HEIGHT),
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	ScrollBarThickness = 4,
	-- UIListLayout drives the canvas height, so rows can be added without any
	-- manual CanvasSize arithmetic.
	CanvasSize = UDim2.new(),
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
	Parent = panel,
})

make("UIListLayout", {
	SortOrder = Enum.SortOrder.LayoutOrder,
	Padding = UDim.new(0, GAP // 2),
	Parent = list,
})

local emptyMessage = label({
	Name = "EmptyMessage",
	AnchorPoint = Vector2.new(0.5, 0),
	Position = UDim2.new(0.5, 0, 0, BODY_Y + 40),
	Size = UDim2.fromOffset(CONTENT_WIDTH, 60),
	Text = "No Stories yet.\nCollect them from the conveyor belt.",
	TextColor3 = Theme.TEXT_MUTED,
	Visible = false,
	Parent = panel,
})

--// Body -- Active: the running dream

local activePanel = round(make("Frame", {
	Name = "ActivePanel",
	AnchorPoint = Vector2.new(0.5, 0),
	Position = UDim2.new(0.5, 0, 0, BODY_Y),
	Size = UDim2.fromOffset(CONTENT_WIDTH, BODY_HEIGHT),
	BackgroundColor3 = Theme.SLOT_BG,
	BorderSizePixel = 0,
	Visible = false,
	Parent = panel,
}), 8)

local activeTitle = label({
	Name = "ActiveTitle",
	Position = UDim2.fromOffset(0, 40),
	Size = UDim2.new(1, 0, 0, 28),
	Text = "Dreaming",
	TextSize = 22,
	Font = Enum.Font.GothamBold,
	Parent = activePanel,
})

local activeStory = label({
	Name = "ActiveStory",
	Position = UDim2.fromOffset(0, 76),
	Size = UDim2.new(1, 0, 0, 24),
	Text = "",
	TextSize = 16,
	Parent = activePanel,
})

local activeProgress = label({
	Name = "ActiveProgress",
	Position = UDim2.fromOffset(0, 108),
	Size = UDim2.new(1, 0, 0, 22),
	Text = "",
	TextColor3 = Theme.TEXT_MUTED,
	Parent = activePanel,
})

local activeHint = label({
	Name = "ActiveHint",
	Position = UDim2.fromOffset(0, 140),
	Size = UDim2.new(1, 0, 0, 22),
	Text = "You can walk away -- the bed keeps paying out.",
	TextColor3 = Theme.TEXT_MUTED,
	TextSize = 13,
	Parent = activePanel,
})

--// Footer

local startButton = round(button({
	Name = "StartButton",
	AnchorPoint = Vector2.new(0.5, 1),
	Position = UDim2.new(0.5, 0, 1, -PADDING),
	Size = UDim2.fromOffset(260, FOOTER_HEIGHT),
	BackgroundColor3 = Theme.ACCENT,
	Text = "Start Dreaming",
	TextSize = 16,
	Parent = panel,
}), 8)

--// Rows

-- The single styling seam. Everything below only reads the row's Selected
-- state, so replacing this body with a cloned asset stays a local change.
local function createStoryRow(story, count)
	local row = round(button({
		Name = story.Id,
		Size = UDim2.new(1, -8, 0, ROW_HEIGHT),
		BackgroundColor3 = Theme.SLOT_BG,
		Text = "",
		LayoutOrder = StoryData.MAX_RARITY - story.Rarity,
		Parent = list,
	}), 6)

	make("UIPadding", {
		PaddingLeft = UDim.new(0, 12),
		PaddingRight = UDim.new(0, 12),
		Parent = row,
	})

	label({
		Name = "StoryName",
		Size = UDim2.fromScale(0.42, 1),
		Text = story.Name,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = row,
	})

	label({
		Name = "Rarity",
		Position = UDim2.fromScale(0.42, 0),
		Size = UDim2.fromScale(0.16, 1),
		Text = rarityStars(story.Rarity),
		TextColor3 = Theme.rarityColor(story.Rarity),
		Parent = row,
	})

	label({
		Name = "Total",
		Position = UDim2.fromScale(0.58, 0),
		Size = UDim2.fromScale(0.28, 1),
		-- The headline number: what the whole Story is worth, not one cycle.
		Text = ("$%d  (%d x %d)"):format(
			BedConfig.totalReward(story.BaseReward),
			BedConfig.CYCLES_PER_STORY,
			story.BaseReward
		),
		Parent = row,
	})

	label({
		Name = "Count",
		Position = UDim2.fromScale(0.86, 0),
		Size = UDim2.fromScale(0.14, 1),
		Text = "x" .. count,
		TextColor3 = Theme.TEXT_MUTED,
		TextXAlignment = Enum.TextXAlignment.Right,
		Parent = row,
	})

	return row
end

local function paintSelection()
	for storyId, entry in pairs(rows) do
		entry.row.BackgroundColor3 = (storyId == selectedId) and Theme.SLOT_SELECTED_BG or Theme.SLOT_BG
	end

	startButton.BackgroundColor3 = selectedId and Theme.ACCENT or Theme.FIELD_BG
	startButton.Text = selectedId and "Start Dreaming" or "Select a Story"
end

-- Rebuilt rather than patched: the list is at most MAX_SLOTS rows and only
-- changes when the panel is opened or the inventory moves, so a rebuild is
-- simpler than reconciling and cannot drift.
local function refresh()
	for _, entry in pairs(rows) do
		entry.row:Destroy()
	end
	rows = {}

	local any = false

	for storyId, count in pairs(counts) do
		local story = StoryData.getStoryById(storyId)
		-- A story removed in a later update: skip rather than render a blank row.
		if story and count > 0 then
			any = true

			local row = createStoryRow(story, count)
			rows[storyId] = { row = row, count = count }

			row.Activated:Connect(function()
				selectedId = storyId
				paintSelection()
			end)
		end
	end

	-- The selected story may have just been spent or discarded.
	if selectedId and not rows[selectedId] then
		selectedId = nil
	end

	emptyMessage.Visible = not any and not bedActive
	paintSelection()
end

--// Panel state

local function renderBedState()
	list.Visible = not bedActive
	startButton.Visible = not bedActive
	activePanel.Visible = bedActive
	emptyMessage.Visible = not bedActive and next(rows) == nil

	if bedActive then
		local story = StoryData.getStoryById(bedStoryId)
		activeStory.Text = story and story.Name or "Unknown Story"
		activeProgress.Text = ("%d of %d cycles left  --  $%d every %ds"):format(
			bedCyclesLeft,
			BedConfig.CYCLES_PER_STORY,
			story and story.BaseReward or 0,
			BedConfig.CYCLE_SECONDS
		)
	end
end

local function setOpen(open)
	panel.Visible = open

	if open then
		updateScale()
		refresh()
		renderBedState()
	end
end

--// Server sync

-- Connected before the pulls below: a change landing during a round-trip would
-- otherwise be missed entirely.
BedStateChanged.OnClientEvent:Connect(function(active, storyId, cyclesLeft)
	bedActive = active and true or false
	bedStoryId = storyId
	bedCyclesLeft = cyclesLeft or 0

	if panel.Visible then
		refresh()
		renderBedState()
	end
end)

InventoryUpdated.OnClientEvent:Connect(function(storyId, newCount)
	counts[storyId] = newCount

	if panel.Visible then
		refresh()
		renderBedState()
	end
end)

task.spawn(function()
	local snapshot = GetInventory:InvokeServer()

	-- GetInventory answers { items = { [storyId] = count }, revision = n }. Read
	-- through .items: iterating the envelope itself put "items" and "revision"
	-- into counts as story ids, which left this list empty until the next grant
	-- arrived -- so a rejoining player could not dream anything they already had.
	--
	-- The revision is ignored here on purpose. "Only fill gaps" already lets a
	-- live update beat the snapshot, and decrements arrive as live updates.
	local items = if type(snapshot) == "table" then snapshot.items else nil

	if type(items) == "table" then
		for storyId, count in pairs(items) do
			if counts[storyId] == nil then
				counts[storyId] = count
			end
		end
	end

	local state = GetBedState:InvokeServer()
	if type(state) == "table" then
		bedActive = state.active and true or false
		bedStoryId = state.storyId
		bedCyclesLeft = state.cyclesLeft or 0
	end
end)

--// Input

openRequest.Event:Connect(function()
	setOpen(true)
end)

closeButton.Activated:Connect(function()
	setOpen(false)
end)

startButton.Activated:Connect(function()
	if bedActive or not selectedId then
		return
	end

	-- Only the id crosses the wire. The server resolves the bed from this
	-- player's own plot and re-reads the reward from StoryData.
	StartDream:FireServer(selectedId)
	setOpen(false)
end)

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

updateScale()
