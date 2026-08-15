--[[
	QuestService
	One Traveler NPC per plot. Paying it raises the player's StoryLevel, which
	widens what their conveyor may spawn.

	Server-authoritative throughout, and unusually easy to secure: the client
	sends no arguments at all. There is no level to claim and no price to quote,
	so there is nothing to forge -- the server reads the caller's own leaderstats
	and looks the cost up in StoryData.

	NPCs are created per plot the same way BedService creates beds: idempotent,
	re-placed on every run, found by CollectionService tag on the client.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local QuestConfig = require(Shared:WaitForChild("QuestConfig"))
local StoryData = require(Shared:WaitForChild("StoryData"))
local Theme = require(Shared:WaitForChild("Theme"))

local Remotes = ReplicatedStorage:WaitForChild("Remotes", 10)
if not Remotes then
	warn("QuestService: ReplicatedStorage.Remotes is missing -- restart `rojo serve` so it re-reads default.project.json")
	return
end

local UnlockLevel = Remotes:WaitForChild("UnlockLevel", 10)
local UnlockResult = Remotes:WaitForChild("UnlockResult", 10)

if not (UnlockLevel and UnlockResult) then
	warn("QuestService: Remotes is missing UnlockLevel or UnlockResult -- restart `rojo serve`")
	return
end

--// Configuration

local PLOT_HALF_HEIGHT = 0.5 -- plots are 128 x 1 x 128, so their top is +0.5 local

local NPC_SIZE = Vector3.new(4, 6, 4)
local NPC_OFFSET_X = -45 -- the free lane: the bed sits at 0, the belt at +50
local NPC_OFFSET_Z = 0

-- UnlockLevel is a client-driven RemoteEvent, so it gets the same treatment as
-- the bed's and the inventory's: one call per player per interval.
local REQUEST_COOLDOWN = 0.5

--// State

local lastRequest = {}

--// NPC geometry

-- Creates the NPC if it is missing and re-places it every call, matching the
-- converge-on-desired-state behaviour of ensurePlots in PlotManager.
local function ensureNpc(plot)
	local npc = plot:FindFirstChild("QuestNpc")

	if not npc then
		npc = Instance.new("Part")
		npc.Name = "QuestNpc"
		npc.Size = NPC_SIZE
		npc.Anchored = true -- an unanchored NPC falls out of the world
		npc.Locked = true -- stops accidental dragging in Studio
		npc.CanCollide = true
		npc.Color = Theme.ACCENT
		npc.Material = Enum.Material.SmoothPlastic
		npc.TopSurface = Enum.SurfaceType.Smooth
		npc.BottomSurface = Enum.SurfaceType.Smooth

		local prompt = Instance.new("ProximityPrompt")
		prompt.Name = "TalkPrompt"
		prompt.KeyboardKeyCode = Enum.KeyCode.E
		prompt.ActionText = "Talk"
		prompt.ObjectText = "Traveler"
		prompt.MaxActivationDistance = 12
		prompt.RequiresLineOfSight = false
		prompt.Parent = npc

		npc.Parent = plot

		-- Tagged so the client can find every NPC without hardcoding a path.
		-- Added last, so anything reacting to the tag sees a complete NPC.
		CollectionService:AddTag(npc, QuestConfig.NPC_TAG)
	end

	-- Derived from the plot's CFrame, so the NPC inherits its rotation -- the
	-- same trick ensureBed and ensureBelt use.
	npc.CFrame = plot.CFrame
		* CFrame.new(NPC_OFFSET_X, PLOT_HALF_HEIGHT + (NPC_SIZE.Y / 2), NPC_OFFSET_Z)

	return npc
end

--// Unlocking

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

local function tryUnlock(player)
	local plot = findPlotFor(player)
	if not plot then
		return false, "no_plot"
	end

	if not plot:FindFirstChild("QuestNpc") then
		return false, "no_npc"
	end

	local leaderstats = player:FindFirstChild("leaderstats")
	local money = leaderstats and leaderstats:FindFirstChild("Money")
	local storyLevel = leaderstats and leaderstats:FindFirstChild("StoryLevel")
	if not (money and storyLevel) then
		return false, "no_stats"
	end

	local nextLevel = storyLevel.Value + 1
	if nextLevel > StoryData.MAX_LEVEL then
		return false, "max_level"
	end

	local cost = StoryData.getUnlockCost(nextLevel)
	if not cost then
		return false, "max_level"
	end

	if money.Value < cost then
		return false, "insufficient_funds"
	end

	-- Nothing between the check above and these two writes may yield. Read
	-- -check-write on a replicated value is only atomic while this thread never
	-- suspends, and a yield in that gap is exactly how a double-click buys two
	-- levels for one payment.
	money.Value -= cost
	storyLevel.Value = nextLevel

	return true
end

--// Plot wiring

-- ChildAdded is connected synchronously while the initial enumeration is
-- deferred, so a plot appearing in that gap can arrive down both paths. Without
-- this guard it would get a second ensureNpc pass.
local setupPlots = {}

local function setupPlot(plot)
	if setupPlots[plot] then
		return
	end
	setupPlots[plot] = true

	ensureNpc(plot)
end

--// Remotes

UnlockLevel.OnServerEvent:Connect(function(player)
	local now = os.clock()
	local last = lastRequest[player]

	if last and now - last < REQUEST_COOLDOWN then
		return
	end
	lastRequest[player] = now

	local ok, reason = tryUnlock(player)
	-- Told back to the client so the panel can explain itself. The panel already
	-- knows the cost and the player's money, so this only ever confirms.
	UnlockResult:FireClient(player, ok, reason)
end)

Players.PlayerRemoving:Connect(function(player)
	lastRequest[player] = nil
end)

--// Startup

local plotsFolder = Workspace:WaitForChild("Plots", 30)

if not plotsFolder then
	warn("QuestService: Workspace.Plots never appeared -- is PlotManager running?")
	return
end

local function onPlotAdded(plot)
	if not plot:IsA("BasePart") then
		return
	end

	-- Deferred on purpose. PlotManager parents each plot before assigning its
	-- Size and CFrame, so reading plot.CFrame synchronously here would place
	-- the NPC relative to the origin. Deferring resumes after that loop ends.
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
