--[[
	QuestUi
	The Traveler panel: shows your Story Level, what the next one costs, and a
	button to pay for it. Opened by walking to the NPC and pressing E --
	QuestInteraction fires the OpenRequest signal this script creates below.

	Money and StoryLevel are IntValues inside leaderstats, so they replicate to
	this client for free. The panel reads them directly and re-renders on their
	Changed signals, which is why there is no GetQuestState remote: the values are
	already here, and they are the server's own. Same approach ShopUi takes.

	The unlock request carries no arguments at all. There is no level to claim and
	no price to quote -- the server reads this player's leaderstats and looks the
	cost up in StoryData itself.

	Layout follows BedUi: one fixed design space (DESIGN_WIDTH x DESIGN_HEIGHT)
	with a UIScale shrinking the panel to fit the viewport.

	Styling seam: createLevelRow() is the only function that builds a row's
	visuals, the role createStoryRow() plays in BedUi.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local StoryData = require(Shared:WaitForChild("StoryData"))
local Theme = require(Shared:WaitForChild("Theme"))

-- Timed, so a missing instance says so instead of yielding forever. An untimed
-- WaitForChild here would leave the script hanging with the UI simply absent --
-- the hardest kind of failure to diagnose.
local Remotes = ReplicatedStorage:WaitForChild("Remotes", 10)
if not Remotes then
	warn("QuestUi: ReplicatedStorage.Remotes is missing -- restart `rojo serve` so it re-reads default.project.json")
	return
end

local UnlockLevel = Remotes:WaitForChild("UnlockLevel", 10)
local UnlockResult = Remotes:WaitForChild("UnlockResult", 10)

if not (UnlockLevel and UnlockResult) then
	warn("QuestUi: Remotes is missing UnlockLevel or UnlockResult -- restart `rojo serve`")
	return
end

local player = Players.LocalPlayer

-- PlayerData builds leaderstats on join, which can land after this script runs.
local leaderstats = player:WaitForChild("leaderstats", 20)
local money = leaderstats and leaderstats:WaitForChild("Money", 10)
local storyLevel = leaderstats and leaderstats:WaitForChild("StoryLevel", 10)

if not (money and storyLevel) then
	warn("QuestUi: leaderstats.Money or leaderstats.StoryLevel is missing -- is PlayerData running?")
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
local ROW_HEIGHT = 52

local CONTENT_WIDTH = DESIGN_WIDTH - (PADDING * 2)
local BODY_Y = PADDING + HEADER_HEIGHT + GAP
local BODY_HEIGHT = DESIGN_HEIGHT - BODY_Y - FOOTER_HEIGHT - GAP - PADDING

--// Helpers
--
-- Same shapes as BedUi and InventoryUi, so every panel stays visually identical.

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

--// Screen

local screenGui = make("ScreenGui", {
	Name = "QuestUi",
	-- Essential: the default destroys this on every respawn, which would leave
	-- every cached reference pointing at a destroyed instance and silently break
	-- all further updates.
	ResetOnSpawn = false,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	Parent = player:WaitForChild("PlayerGui"),
})

-- Created here, by the consumer, so it always exists before QuestInteraction can
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

label({
	Name = "Title",
	Position = UDim2.fromOffset(16, 0),
	Size = UDim2.new(1, -220, 1, 0),
	Text = "The Traveler",
	TextSize = 20,
	Font = Enum.Font.GothamBold,
	TextXAlignment = Enum.TextXAlignment.Left,
	Parent = titleBar,
})

local moneyLabel = label({
	Name = "Money",
	AnchorPoint = Vector2.new(1, 0.5),
	Position = UDim2.new(1, -48, 0.5, 0),
	Size = UDim2.fromOffset(160, HEADER_HEIGHT),
	Text = "",
	TextXAlignment = Enum.TextXAlignment.Right,
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

--// Body

local body = make("Frame", {
	Name = "Body",
	AnchorPoint = Vector2.new(0.5, 0),
	Position = UDim2.new(0.5, 0, 0, BODY_Y),
	Size = UDim2.fromOffset(CONTENT_WIDTH, BODY_HEIGHT),
	BackgroundTransparency = 1,
	Parent = panel,
})

make("UIListLayout", {
	SortOrder = Enum.SortOrder.LayoutOrder,
	Padding = UDim.new(0, GAP),
	Parent = body,
})

-- The single styling seam. Everything below only writes the returned label's
-- Text, so replacing this body with a cloned asset stays a local change.
local function createLevelRow(order, name, valueColor)
	local row = round(make("Frame", {
		Name = name,
		Size = UDim2.new(1, 0, 0, ROW_HEIGHT),
		BackgroundColor3 = Theme.SLOT_BG,
		BorderSizePixel = 0,
		LayoutOrder = order,
		Parent = body,
	}), 6)

	make("UIPadding", {
		PaddingLeft = UDim.new(0, 16),
		PaddingRight = UDim.new(0, 16),
		Parent = row,
	})

	label({
		Name = "Caption",
		Size = UDim2.fromScale(0.5, 1),
		Text = name,
		TextColor3 = Theme.TEXT_MUTED,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = row,
	})

	return label({
		Name = "Value",
		Position = UDim2.fromScale(0.5, 0),
		Size = UDim2.fromScale(0.5, 1),
		Text = "",
		TextColor3 = valueColor or Theme.TEXT,
		TextSize = 18,
		Font = Enum.Font.GothamBold,
		TextXAlignment = Enum.TextXAlignment.Right,
		Parent = row,
	})
end

local currentLevelValue = createLevelRow(1, "Current Story Level")
local nextLevelValue = createLevelRow(2, "Next Level")
local costValue = createLevelRow(3, "Cost to Unlock", Theme.ACCENT)

local statusLabel = label({
	Name = "Status",
	AnchorPoint = Vector2.new(0.5, 1),
	Position = UDim2.new(0.5, 0, 1, -(FOOTER_HEIGHT + GAP + PADDING)),
	Size = UDim2.fromOffset(CONTENT_WIDTH, 22),
	Text = "",
	TextColor3 = Theme.TEXT_MUTED,
	TextSize = 13,
	Parent = panel,
})

--// Footer

local unlockButton = round(button({
	Name = "UnlockButton",
	AnchorPoint = Vector2.new(0.5, 1),
	Position = UDim2.new(0.5, 0, 1, -PADDING),
	Size = UDim2.fromOffset(300, FOOTER_HEIGHT),
	BackgroundColor3 = Theme.ACCENT,
	Text = "Pay to Unlock",
	TextSize = 16,
	Parent = panel,
}), 8)

--// Rendering

-- Every number shown comes from leaderstats or StoryData -- nothing is cached
-- and nothing is predicted, so the panel cannot drift from the server.
local function render()
	local level = storyLevel.Value
	local nextLevel = level + 1
	local atMax = nextLevel > StoryData.MAX_LEVEL

	moneyLabel.Text = ("$%d"):format(money.Value)
	currentLevelValue.Text = ("%d / %d"):format(level, StoryData.MAX_LEVEL)

	if atMax then
		nextLevelValue.Text = "--"
		costValue.Text = "Max Level"
		costValue.TextColor3 = Theme.TEXT_MUTED

		unlockButton.Text = "Max Level"
		unlockButton.BackgroundColor3 = Theme.FIELD_BG
		unlockButton.AutoButtonColor = false
		statusLabel.Text = "Every Story is already spawning on your belt."
		return
	end

	local cost = StoryData.getUnlockCost(nextLevel) or 0
	local affordable = money.Value >= cost

	nextLevelValue.Text = ("Level %d"):format(nextLevel)
	costValue.Text = ("$%d"):format(cost)
	costValue.TextColor3 = affordable and Theme.ACCENT or Theme.DANGER

	unlockButton.Text = "Pay to Unlock"
	unlockButton.BackgroundColor3 = affordable and Theme.ACCENT or Theme.FIELD_BG
	unlockButton.AutoButtonColor = affordable
	statusLabel.Text = affordable and "New Stories join your belt straight away."
		or ("You need $%d more."):format(cost - money.Value)
end

local function setOpen(open)
	panel.Visible = open

	if open then
		updateScale()
		render()
	end
end

--// Signals

-- Re-render on the server's own values changing, so the panel updates the
-- instant money is deducted rather than waiting to be reopened.
money.Changed:Connect(function()
	if panel.Visible then
		render()
	end
end)

storyLevel.Changed:Connect(function()
	if panel.Visible then
		render()
	end
end)

UnlockResult.OnClientEvent:Connect(function(ok, reason)
	if not panel.Visible then
		return
	end

	if ok then
		statusLabel.Text = "Unlocked. New Stories will start appearing on your belt."
	elseif reason == "insufficient_funds" then
		statusLabel.Text = "Not enough money yet."
	elseif reason == "max_level" then
		statusLabel.Text = "Already at max level."
	elseif reason == "no_plot" then
		statusLabel.Text = "Claim a plot first."
	else
		statusLabel.Text = "Could not unlock right now."
	end
end)

openRequest.Event:Connect(function()
	setOpen(true)
end)

closeButton.Activated:Connect(function()
	setOpen(false)
end)

unlockButton.Activated:Connect(function()
	-- No arguments: the server reads this player's own leaderstats and looks the
	-- cost up itself. The local checks below are courtesy, not security.
	if storyLevel.Value >= StoryData.MAX_LEVEL then
		return
	end

	UnlockLevel:FireServer()
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
