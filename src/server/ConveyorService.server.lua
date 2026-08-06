--[[
	ConveyorService
	Spawns the current Traveler's Stories onto a per-plot conveyor belt and
	slides them from StartPart to EndPart, destroying each on arrival.

	Movement is script-driven (TweenService on anchored parts) rather than
	physics, so item positions are entirely server-authoritative.

	A belt only runs while its plot is claimed. Ownership is read from the
	OwnerUserId attribute that PlotManager already maintains, so the two
	scripts share no state.

	Items live in plot.Conveyor.Items and carry a StoryId attribute, ready for
	the collection mechanic.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local StoryData = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("StoryData"))
local InventoryService = require(ServerScriptService:WaitForChild("Server"):WaitForChild("InventoryService"))

--// Configuration

local CURRENT_TRAVELER_ID = "wandering_peddler"

local SPAWN_INTERVAL = 4 -- seconds between items
local TRAVEL_TIME = 12 -- seconds to cross the belt

local BELT_LENGTH = 80 -- studs
local BELT_OFFSET_X = 50
local BELT_OFFSET_Z = -10 -- plot-local, toward the hub
local BELT_HEIGHT = 3 -- above the plot surface

local ITEM_SIZE = Vector3.new(2, 2, 2)
local MARKER_SIZE = Vector3.new(4, 1, 6)

local COLLECT_DISTANCE = 12 -- studs; the prompt's activation range

-- Linear, not the default Quad: a belt runs at constant speed. Easing would
-- make items visibly accelerate and bunch up mid-run.
local TWEEN_INFO = TweenInfo.new(TRAVEL_TIME, Enum.EasingStyle.Linear, Enum.EasingDirection.InOut)

local RARITY_COLORS = {
	[1] = Color3.fromRGB(200, 200, 200), -- grey
	[2] = Color3.fromRGB(80, 200, 120), -- green
	[3] = Color3.fromRGB(70, 130, 230), -- blue
	[4] = Color3.fromRGB(160, 90, 220), -- purple
	[5] = Color3.fromRGB(255, 190, 60), -- gold
}

--// State

-- [plot] = state. The table itself is the token identifying a belt run: see
-- startBelt for why identity matters rather than a boolean.
local activeBelts = {}

--// Belt geometry

local function makeMarker(name, color)
	local part = Instance.new("Part")
	part.Name = name
	part.Size = MARKER_SIZE
	part.Anchored = true
	part.CanCollide = false
	part.Color = color
	part.Material = Enum.Material.Metal
	return part
end

-- Creates the belt if it is missing and re-places it every call, matching the
-- converge-on-desired-state behaviour of ensurePlots in PlotManager.
local function ensureBelt(plot)
	local conveyor = plot:FindFirstChild("Conveyor")

	if not conveyor then
		conveyor = Instance.new("Folder")
		conveyor.Name = "Conveyor"

		makeMarker("StartPart", Color3.fromRGB(120, 180, 120)).Parent = conveyor
		makeMarker("EndPart", Color3.fromRGB(180, 120, 120)).Parent = conveyor

		local items = Instance.new("Folder")
		items.Name = "Items"
		items.Parent = conveyor

		conveyor.Parent = plot
	end

	-- Derived from the plot's CFrame, so the belt inherits its rotation and
	-- runs across the hub-facing edge -- the same trick ensureClaim uses.
	conveyor.StartPart.CFrame = plot.CFrame * CFrame.new(BELT_OFFSET_X, BELT_HEIGHT, BELT_OFFSET_Z + (BELT_LENGTH / 2))
	conveyor.EndPart.CFrame = plot.CFrame * CFrame.new(BELT_OFFSET_X, BELT_HEIGHT, BELT_OFFSET_Z - (BELT_LENGTH / 2))

	return conveyor
end

--// Items

local function destroyItem(state, item)
	local tween = state.items[item]
	if tween then
		-- Cancelling an already-finished tween is a no-op, so this same path
		-- serves both arrival at EndPart and early teardown mid-flight.
		tween:Cancel()
		tween:Destroy()
		state.items[item] = nil
	end

	item:Destroy()
end

local function createItem(story, conveyor)
	local item = Instance.new("Part")
	item.Name = "StoryItem"
	item.Size = ITEM_SIZE
	item.Anchored = true
	item.CanCollide = false
	item.Material = Enum.Material.Neon
	item.Color = RARITY_COLORS[story.Rarity] or RARITY_COLORS[1]
	item.CFrame = conveyor.StartPart.CFrame

	-- Read by the collection mechanic. StoryId is the authoritative one; the
	-- rest let UI render an item without a round-trip through StoryData.
	item:SetAttribute("StoryId", story.Id)
	item:SetAttribute("TravelerId", CURRENT_TRAVELER_ID)
	item:SetAttribute("Rarity", story.Rarity)
	item:SetAttribute("BaseReward", story.BaseReward)

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "Billboard"
	billboard.Size = UDim2.fromScale(8, 2)
	billboard.StudsOffset = Vector3.new(0, 2, 0)
	billboard.MaxDistance = 120
	billboard.AlwaysOnTop = true
	billboard.Parent = item

	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = ("%s  %s"):format(string.rep("*", story.Rarity), story.Name)
	label.TextScaled = true
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.TextStrokeTransparency = 0
	label.Parent = billboard

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "CollectPrompt"
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.ActionText = "Collect"
	prompt.ObjectText = story.Name
	prompt.MaxActivationDistance = COLLECT_DISTANCE
	prompt.RequiresLineOfSight = false -- otherwise it flickers out as the item moves
	prompt.Parent = item

	item.Parent = conveyor.Items
	return item
end

-- Every check here runs on the server. ProximityPrompt already enforces its own
-- activation distance server-side, so this is about *who* may collect and
-- ensuring an item can only ever be collected once.
local function tryCollect(player, plot, state, item)
	-- The double-collect guard. Triggered can fire again before the Destroy
	-- below replicates, and the arrival tween may have already cleared this
	-- entry. Either way, no entry means there is nothing left to collect.
	if not state.items[item] then
		return
	end

	-- Belts run on private plots, so only the owner may take from one. Silent
	-- reject: a visitor holding E should not flood the server log.
	if plot:GetAttribute("OwnerUserId") ~= player.UserId then
		return
	end

	local character = player.Character
	local root = character and character.PrimaryPart
	if not root then
		return
	end

	-- Belt-and-braces with deliberate slack for latency; the prompt's own
	-- server-side range check is the real defence, not this.
	if (root.Position - item.Position).Magnitude > COLLECT_DISTANCE * 2 then
		return
	end

	local storyId = item:GetAttribute("StoryId")
	if not storyId then
		return
	end

	-- Mutate state before calling out. grantStory may yield once persistence
	-- lands, and a yield between the guard above and this line would reopen
	-- the double-collect window.
	destroyItem(state, item)

	-- Only the id crosses this boundary: InventoryService re-derives the story
	-- and its BaseReward from StoryData, so nothing here can inflate a reward.
	InventoryService.grantStory(player, storyId)
end

local function spawnItem(plot, state)
	local story = StoryData.getRandomStory(CURRENT_TRAVELER_ID)
	if not story then
		-- StoryData already warns on an unknown traveler id; just skip a beat.
		return
	end

	local conveyor = plot:FindFirstChild("Conveyor")
	if not conveyor then
		return
	end

	local item = createItem(story, conveyor)

	item.CollectPrompt.Triggered:Connect(function(player)
		tryCollect(player, plot, state, item)
	end)

	local tween = TweenService:Create(item, TWEEN_INFO, { CFrame = conveyor.EndPart.CFrame })
	state.items[item] = tween

	tween.Completed:Connect(function()
		destroyItem(state, item)
	end)

	tween:Play()
end

--// Belt lifecycle

local function stopBelt(plot)
	local state = activeBelts[plot]
	if not state then
		return
	end

	-- Cleared first: the spawn loop checks this on its next iteration and exits.
	activeBelts[plot] = nil

	for item in pairs(state.items) do
		destroyItem(state, item)
	end
end

local function startBelt(plot)
	if activeBelts[plot] then
		return
	end

	ensureBelt(plot)

	local state = { items = {} }
	activeBelts[plot] = state

	task.spawn(function()
		-- Compare identity, not a boolean flag: a fast claim -> release ->
		-- claim would leave this loop running alongside the new one, spawning
		-- at double rate forever. A stale loop sees a different state table
		-- here and exits.
		while activeBelts[plot] == state do
			spawnItem(plot, state)
			task.wait(SPAWN_INTERVAL)
		end
	end)
end

local function onOwnerChanged(plot)
	if plot:GetAttribute("OwnerUserId") then
		startBelt(plot)
	else
		stopBelt(plot)
	end
end

-- ChildAdded is connected synchronously while the initial enumeration is
-- deferred, so a plot appearing in that gap can arrive down both paths. Without
-- this guard it would get a second GetAttributeChangedSignal connection.
local setupPlots = {}

local function setupPlot(plot)
	if setupPlots[plot] then
		return
	end
	setupPlots[plot] = true

	ensureBelt(plot)

	plot:GetAttributeChangedSignal("OwnerUserId"):Connect(function()
		onOwnerChanged(plot)
	end)

	-- Covers a plot that was already claimed before this script reached it.
	onOwnerChanged(plot)
end

--// Startup

local plotsFolder = Workspace:WaitForChild("Plots", 30)

if not plotsFolder then
	warn("ConveyorService: Workspace.Plots never appeared -- is PlotManager running?")
	return
end

local function onPlotAdded(plot)
	if not plot:IsA("BasePart") then
		return
	end

	-- Deferred on purpose. PlotManager parents each plot before assigning its
	-- Size and CFrame, so reading plot.CFrame synchronously here would place
	-- the belt relative to the origin. Deferring resumes after that loop ends.
	task.defer(setupPlot, plot)
end

-- WaitForChild above returns as soon as the folder exists, which is before the
-- plots inside it are created, so this enumeration is deferred too.
task.defer(function()
	for _, plot in ipairs(plotsFolder:GetChildren()) do
		onPlotAdded(plot)
	end
end)

plotsFolder.ChildAdded:Connect(onPlotAdded)
