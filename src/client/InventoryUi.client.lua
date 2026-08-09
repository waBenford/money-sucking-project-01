--[[
	InventoryUi
	Shows the player's collected Stories. Press B to toggle.

	Not Tab: Roblox's CoreGui reserves it for GUI keyboard navigation, so it
	arrives with gameProcessed = true and the guard below discards it.

	The server only ever sends storyIds and counts; everything displayed --
	name, rarity, ordering -- is resolved here from the shared StoryData module.

	Styling seam: createRow() is the only function that builds row visuals.
	Swap its body for ReplicatedStorage.Assets.StoryRow:Clone() when you have
	custom assets, and nothing else needs to change.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local StoryData = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("StoryData"))

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

if not (InventoryUpdated and GetInventory) then
	warn("InventoryUi: Remotes folder is missing InventoryUpdated or GetInventory")
	return
end

--// Configuration

local TOGGLE_KEY = Enum.KeyCode.B
local ROW_HEIGHT = 32

local PANEL_BG = Color3.fromRGB(25, 27, 34)
local ROW_BG = Color3.fromRGB(38, 41, 50)
local TEXT_COLOR = Color3.fromRGB(235, 235, 240)

local RARITY_COLORS = {
	[1] = Color3.fromRGB(200, 200, 200),
	[2] = Color3.fromRGB(80, 200, 120),
	[3] = Color3.fromRGB(70, 130, 230),
	[4] = Color3.fromRGB(160, 90, 220),
	[5] = Color3.fromRGB(255, 190, 60),
}

local player = Players.LocalPlayer

--// State

-- [storyId] = { row = Frame, count = number }
local entries = {}

--// UI construction

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "InventoryUi"
-- Essential: the default destroys this on every respawn, which would leave
-- every cached row reference pointing at a destroyed instance and silently
-- break all further updates.
screenGui.ResetOnSpawn = false
screenGui.Enabled = false
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screenGui.Parent = player:WaitForChild("PlayerGui")

local panel = Instance.new("Frame")
panel.Name = "Panel"
panel.AnchorPoint = Vector2.new(1, 0.5)
panel.Position = UDim2.new(1, -16, 0.5, 0)
panel.Size = UDim2.fromOffset(340, 400)
panel.BackgroundColor3 = PANEL_BG
panel.BackgroundTransparency = 0.1
panel.BorderSizePixel = 0
panel.Parent = screenGui

local panelCorner = Instance.new("UICorner")
panelCorner.CornerRadius = UDim.new(0, 8)
panelCorner.Parent = panel

local title = Instance.new("TextLabel")
title.Name = "Title"
title.Size = UDim2.new(1, 0, 0, 36)
title.BackgroundTransparency = 1
title.Text = "Stories"
title.TextColor3 = TEXT_COLOR
title.TextSize = 20
title.Font = Enum.Font.GothamBold
title.Parent = panel

local list = Instance.new("ScrollingFrame")
list.Name = "List"
list.Position = UDim2.fromOffset(8, 40)
list.Size = UDim2.new(1, -16, 1, -48)
list.BackgroundTransparency = 1
list.BorderSizePixel = 0
list.ScrollBarThickness = 4
-- UIListLayout drives the canvas height, so rows can be added without any
-- manual CanvasSize arithmetic.
list.CanvasSize = UDim2.new()
list.AutomaticCanvasSize = Enum.AutomaticSize.Y
list.Parent = panel

local layout = Instance.new("UIListLayout")
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Padding = UDim.new(0, 4)
layout.Parent = list

--// Rows

local function label(name, parent, xScale, widthScale, alignment)
	local text = Instance.new("TextLabel")
	text.Name = name
	text.Position = UDim2.fromScale(xScale, 0)
	text.Size = UDim2.fromScale(widthScale, 1)
	text.BackgroundTransparency = 1
	text.TextColor3 = TEXT_COLOR
	text.TextSize = 14
	text.Font = Enum.Font.Gotham
	text.TextXAlignment = alignment
	text.Parent = parent
	return text
end

-- The single styling seam. Everything below only reads row.Name / row.Rarity /
-- row.Quantity, so replacing this body with a cloned asset is a local change.
local function createRow(story)
	local row = Instance.new("Frame")
	row.Name = story.Id
	row.Size = UDim2.new(1, 0, 0, ROW_HEIGHT)
	row.BackgroundColor3 = ROW_BG
	row.BorderSizePixel = 0
	-- Higher rarity sorts to the top.
	row.LayoutOrder = StoryData.MAX_RARITY - story.Rarity

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 4)
	corner.Parent = row

	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, 8)
	padding.PaddingRight = UDim.new(0, 8)
	padding.Parent = row

	-- "StoryName", not "Name": a child called Name would be shadowed by the
	-- Frame's own Name property, so row.Name returns the id string instead.
	label("StoryName", row, 0, 0.52, Enum.TextXAlignment.Left).Text = story.Name

	local rarity = label("Rarity", row, 0.52, 0.32, Enum.TextXAlignment.Center)
	-- Driven by MAX_RARITY, so adding a sixth tier needs no UI change.
	rarity.Text = string.rep("*", story.Rarity) .. string.rep("-", StoryData.MAX_RARITY - story.Rarity)
	rarity.TextColor3 = RARITY_COLORS[story.Rarity] or TEXT_COLOR

	label("Quantity", row, 0.84, 0.16, Enum.TextXAlignment.Right)

	return row
end

local function setCount(storyId, count)
	local story = StoryData.getStoryById(storyId)
	if not story then
		-- A story removed in a later update: ignore rather than render a blank
		-- row from an old save.
		return
	end

	local entry = entries[storyId]

	if not entry then
		local row = createRow(story)
		row.Parent = list
		entry = { row = row, count = 0 }
		entries[storyId] = entry
	end

	entry.count = count
	entry.row.Quantity.Text = "x" .. count
end

--// Server sync

-- Connected before the snapshot request below: a grant landing during the
-- round-trip would otherwise be missed entirely.
InventoryUpdated.OnClientEvent:Connect(function(storyId, newCount)
	setCount(storyId, newCount)
end)

task.spawn(function()
	local snapshot = GetInventory:InvokeServer()
	if type(snapshot) ~= "table" then
		return -- throttled, or the server declined
	end

	for storyId, count in pairs(snapshot) do
		local existing = entries[storyId]

		-- max() because connecting the event first means a live update may
		-- already have arrived with a newer count, and this snapshot could be
		-- staler than it.
		--
		-- Correct only while counts are monotonic, which holds because nothing
		-- calls consumeStory yet. When the bed starts consuming Stories this
		-- must become a sequenced/versioned snapshot instead.
		setCount(storyId, math.max(existing and existing.count or 0, count))
	end
end)

--// Toggle

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	-- Same guard as Sprint.client.lua: Tab typed into chat must not toggle.
	if gameProcessed then
		return
	end

	if input.KeyCode == TOGGLE_KEY then
		screenGui.Enabled = not screenGui.Enabled
	end
end)
