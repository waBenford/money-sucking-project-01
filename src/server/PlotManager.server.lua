--[[
	PlotManager
	Creates the Workspace.Plots folder (if it isn't there yet) and hands one of
	the 8 plots to each player who joins, freeing it again when they leave.

	The assignment is exposed through attributes, which replicate to clients:
		plot:GetAttribute("OwnerUserId")  -- who owns this plot
		player:GetAttribute("PlotName")   -- which plot this player owns
]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local PLOT_COUNT = 8
local PLOT_SIZE = Vector3.new(128, 1, 128)
local PLOT_RADIUS = 300 -- distance from the map centre, leaving room for a hub
local PLOT_COLOR = Color3.fromRGB(91, 154, 76)

-- Spaces the plots evenly around a circle centred on the origin, each one
-- turned to face the middle. Y is half the plot height, which rests them on
-- top of the Baseplate (whose top face is y = 0).
local function cframeFor(index)
	local angle = (index - 1) * (2 * math.pi / PLOT_COUNT)

	local position = Vector3.new(
		math.cos(angle) * PLOT_RADIUS,
		PLOT_SIZE.Y / 2,
		math.sin(angle) * PLOT_RADIUS
	)

	-- lookAt puts the part at `position` with its LookVector aimed at the
	-- target. The target's Y matches the plot's own Y on purpose: aiming at
	-- y = 0 instead would pitch the slab and leave the plot tilted.
	return CFrame.lookAt(position, Vector3.new(0, position.Y, 0))
end

-- Creates any missing plots, then puts every plot where the layout says it
-- belongs. Safe to run repeatedly: it always converges on the same 8 plots in
-- the same places, so a folder left over from an earlier session gets brought
-- up to date instead of keeping a stale layout. Appearance is only set on
-- creation, so colour and material tweaks survive.
local function ensurePlots()
	local folder = Workspace:FindFirstChild("Plots")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "Plots"
		folder.Parent = Workspace
	end

	for i = 1, PLOT_COUNT do
		local name = "Plot" .. i
		local plot = folder:FindFirstChild(name)

		if not plot then
			plot = Instance.new("Part")
			plot.Name = name
			plot.Anchored = true -- an unanchored plot falls out of the world
			plot.Locked = true -- stops accidental dragging in Studio
			plot.CanCollide = true
			plot.Color = PLOT_COLOR
			plot.Material = Enum.Material.Grass
			plot.TopSurface = Enum.SurfaceType.Smooth
			plot.BottomSurface = Enum.SurfaceType.Smooth
			plot.Parent = folder
		end

		-- CFrame, not Position: Position would move the plot without rotating
		-- it, leaving it facing the wrong way.
		plot.Size = PLOT_SIZE
		plot.CFrame = cframeFor(i)
	end

	return folder
end

local plotsFolder = ensurePlots()

local plotOwners = {} -- [plot] = player
local playerPlots = {} -- [player] = plot

local function assignPlot(player)
	-- Walk the plots in order and take the first one nobody owns.
	for i = 1, PLOT_COUNT do
		local plot = plotsFolder:FindFirstChild("Plot" .. i)
		if plot and not plotOwners[plot] then
			plotOwners[plot] = player
			playerPlots[player] = plot

			plot:SetAttribute("OwnerUserId", player.UserId)
			player:SetAttribute("PlotName", plot.Name)
			return
		end
	end

	-- Every plot is taken. The player still joins, just without a plot.
	warn(("No free plot for %s -- all %d are taken."):format(player.Name, PLOT_COUNT))
end

local function releasePlot(player)
	local plot = playerPlots[player]
	if not plot then
		return -- they never got one
	end

	plotOwners[plot] = nil
	playerPlots[player] = nil
	plot:SetAttribute("OwnerUserId", nil)
end

Players.PlayerAdded:Connect(assignPlot)
Players.PlayerRemoving:Connect(releasePlot)

-- Catch anyone who joined before this script started running.
for _, player in ipairs(Players:GetPlayers()) do
	assignPlot(player)
end
