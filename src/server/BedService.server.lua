--[[
	BedService
	One Bed per plot. Feeding it a Story starts a passive dream: the server pays
	out BaseReward every CYCLE_SECONDS for exactly CYCLES_PER_STORY cycles, and
	the player is free to walk away the whole time.

	Server-authoritative throughout. The client asks to dream with a storyId and
	nothing else -- it never names a bed, never sends a reward, and never drives
	the timer. The bed is resolved from the caller's own plot, the reward is read
	from StoryData every cycle, and consumeStory is what proves ownership.

	Beds are created per plot the same way ConveyorService creates belts:
	idempotent, re-placed on every run, driven off the OwnerUserId attribute
	PlotManager maintains, so the two scripts share no state.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BedConfig = require(Shared:WaitForChild("BedConfig"))
local StoryData = require(Shared:WaitForChild("StoryData"))
local Theme = require(Shared:WaitForChild("Theme"))
local InventoryService = require(ServerScriptService:WaitForChild("Server"):WaitForChild("InventoryService"))

local Remotes = ReplicatedStorage:WaitForChild("Remotes", 10)
if not Remotes then
	warn("BedService: ReplicatedStorage.Remotes is missing -- restart `rojo serve` so it re-reads default.project.json")
	return
end

local StartDream = Remotes:WaitForChild("StartDream", 10)
local BedStateChanged = Remotes:WaitForChild("BedStateChanged", 10)
local GetBedState = Remotes:WaitForChild("GetBedState", 10)

if not (StartDream and BedStateChanged and GetBedState) then
	warn("BedService: Remotes is missing StartDream, BedStateChanged or GetBedState -- restart `rojo serve`")
	return
end

--// Configuration

local PLOT_HALF_HEIGHT = 0.5 -- plots are 128 x 1 x 128, so their top is +0.5 local

local BED_SIZE = Vector3.new(10, 2, 16)
local BED_OFFSET_X = 0 -- opposite side of the plot from the belt (+50)
local BED_OFFSET_Z = 0

-- StartDream is a client-driven RemoteEvent, so it gets the same treatment as
-- the inventory's remotes: one call per player per interval.
local REQUEST_COOLDOWN = 0.5

--// State

-- [plot] = state. The table itself is the run token -- see startDream for why
-- identity matters rather than a boolean.
local activeDreams = {}

local lastRequest = {}

--// Bed geometry

-- Creates the bed if it is missing and re-places it every call, matching the
-- converge-on-desired-state behaviour of ensurePlots in PlotManager.
local function ensureBed(plot)
	local bed = plot:FindFirstChild("Bed")

	if not bed then
		bed = Instance.new("Part")
		bed.Name = "Bed"
		bed.Size = BED_SIZE
		bed.Anchored = true -- an unanchored bed falls out of the world
		bed.Locked = true -- stops accidental dragging in Studio
		bed.CanCollide = true
		bed.Color = Theme.SLOT_BG
		bed.Material = Enum.Material.Fabric
		bed.TopSurface = Enum.SurfaceType.Smooth
		bed.BottomSurface = Enum.SurfaceType.Smooth

		local prompt = Instance.new("ProximityPrompt")
		prompt.Name = "SleepPrompt"
		prompt.KeyboardKeyCode = Enum.KeyCode.E
		prompt.ActionText = "Sleep"
		prompt.ObjectText = "Bed"
		prompt.MaxActivationDistance = 12
		prompt.RequiresLineOfSight = false
		prompt.Parent = bed

		bed.Parent = plot

		-- Tagged so the client can find every bed without hardcoding a path.
		-- Added last, so anything reacting to the tag sees a complete bed.
		CollectionService:AddTag(bed, BedConfig.BED_TAG)
	end

	-- Derived from the plot's CFrame, so the bed inherits its rotation -- the
	-- same trick ensureClaim and ensureBelt use.
	bed.CFrame = plot.CFrame
		* CFrame.new(BED_OFFSET_X, PLOT_HALF_HEIGHT + (BED_SIZE.Y / 2), BED_OFFSET_Z)

	return bed
end

--// Dream state

local function findPlotFor(player)
	local plotsFolder = Workspace:FindFirstChild("Plots")
	local plotName = player:GetAttribute("PlotName")
	if not (plotsFolder and plotName) then
		return nil
	end

	local plot = plotsFolder:FindFirstChild(plotName)
	-- Re-checked rather than trusted: PlotName is set by PlotManager, but the
	-- authoritative claim is the plot's own OwnerUserId.
	if plot and plot:GetAttribute("OwnerUserId") == player.UserId then
		return plot
	end

	return nil
end

-- The only place a payout is computed. A bed-upgrade multiplier belongs here
-- and nowhere else.
local function payoutFor(story)
	return story.BaseReward
end

local function creditMoney(player, amount)
	-- Defensive: the player may have left mid-cycle, or PlayerData may not have
	-- built leaderstats yet.
	local leaderstats = player:FindFirstChild("leaderstats")
	local money = leaderstats and leaderstats:FindFirstChild("Money")
	if money then
		money.Value += amount
	end
end

local function pushState(player, state)
	if not player.Parent then
		return -- left the game
	end

	if state then
		BedStateChanged:FireClient(player, true, state.storyId, state.cyclesLeft)
	else
		BedStateChanged:FireClient(player, false, nil, 0)
	end
end

local function stopDream(plot)
	local state = activeDreams[plot]
	if not state then
		return
	end

	-- Cleared first: the cycle loop checks this on its next wake and exits.
	activeDreams[plot] = nil
	plot:SetAttribute("DreamStoryId", nil)

	pushState(state.player, nil)
end

local function startDream(player, storyId)
	-- Client input: never assume it is even the right type.
	if type(storyId) ~= "string" then
		return false, "bad_request"
	end

	local plot = findPlotFor(player)
	if not plot then
		return false, "no_plot"
	end

	if not plot:FindFirstChild("Bed") then
		return false, "no_bed"
	end

	if activeDreams[plot] then
		return false, "busy"
	end

	local story = StoryData.getStoryById(storyId)
	if not story then
		return false, "unknown_story"
	end

	-- Last, and deliberately so. This both proves the player owns a copy and
	-- spends it, so any rejection above cannot eat a Story.
	if not InventoryService.consumeStory(player, storyId) then
		return false, "not_owned"
	end

	local state = {
		player = player,
		storyId = storyId,
		cyclesLeft = BedConfig.CYCLES_PER_STORY,
	}

	activeDreams[plot] = state
	-- Replicates, so a future effect script can react without a remote.
	plot:SetAttribute("DreamStoryId", storyId)

	pushState(player, state)

	task.spawn(function()
		-- Compare identity, not a boolean flag: a fast stop -> start would
		-- otherwise leave this loop paying out alongside the new one. A stale
		-- loop sees a different state table here and exits.
		while activeDreams[plot] == state and state.cyclesLeft > 0 do
			task.wait(BedConfig.CYCLE_SECONDS)

			if activeDreams[plot] ~= state then
				return -- stopped while we were waiting
			end

			-- Re-read from StoryData every cycle. Nothing the client sent is
			-- ever used to size a payout.
			creditMoney(player, payoutFor(story))

			state.cyclesLeft -= 1
			pushState(player, state.cyclesLeft > 0 and state or nil)
		end

		if activeDreams[plot] == state then
			stopDream(plot)
		end
	end)

	return true
end

--// Plot wiring

local function onOwnerChanged(plot)
	if not plot:GetAttribute("OwnerUserId") then
		-- Plot released: whoever was dreaming here no longer owns it.
		stopDream(plot)
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

	ensureBed(plot)

	plot:GetAttributeChangedSignal("OwnerUserId"):Connect(function()
		onOwnerChanged(plot)
	end)
end

--// Remotes

StartDream.OnServerEvent:Connect(function(player, storyId)
	local now = os.clock()
	local last = lastRequest[player]

	if last and now - last < REQUEST_COOLDOWN then
		return
	end
	lastRequest[player] = now

	-- Rejections are silent to the player: the panel already knows whether the
	-- bed is idle, and a spammed remote should not spam the log either.
	startDream(player, storyId)
end)

-- `player` is supplied by the engine, not the caller, so a client can only ever
-- read its own bed -- there is no plot argument to forge.
function GetBedState.OnServerInvoke(player)
	local plot = findPlotFor(player)
	local state = plot and activeDreams[plot]

	if not state then
		return { active = false, cyclesLeft = 0 }
	end

	return {
		active = true,
		storyId = state.storyId,
		cyclesLeft = state.cyclesLeft,
	}
end

Players.PlayerRemoving:Connect(function(player)
	lastRequest[player] = nil

	-- Disconnect stops and resets the bed. No offline earnings for now.
	for plot, state in pairs(activeDreams) do
		if state.player == player then
			stopDream(plot)
		end
	end
end)

--// Startup

local plotsFolder = Workspace:WaitForChild("Plots", 30)

if not plotsFolder then
	warn("BedService: Workspace.Plots never appeared -- is PlotManager running?")
	return
end

local function onPlotAdded(plot)
	if not plot:IsA("BasePart") then
		return
	end

	-- Deferred on purpose. PlotManager parents each plot before assigning its
	-- Size and CFrame, so reading plot.CFrame synchronously here would place
	-- the bed relative to the origin. Deferring resumes after that loop ends.
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
