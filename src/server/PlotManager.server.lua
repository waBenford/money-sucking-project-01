--[[
	PlotManager
	Creates the Workspace.Plots folder (if it isn't there yet) and lets players
	claim a plot by walking up to its sign and pressing E. A claimed plot is
	freed again when its owner leaves.

	Ownership is exposed through attributes, which replicate to clients:
		plot:GetAttribute("OwnerUserId")  -- who owns this plot
		player:GetAttribute("PlotName")   -- which plot this player owns, or
		                                     nil until they claim one
]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local PLOT_COUNT = 8
local PLOT_SIZE = Vector3.new(128, 1, 128)
local PLOT_RADIUS = 300 -- distance from the map centre, leaving room for a hub
local PLOT_COLOR = Color3.fromRGB(91, 154, 76)

local CLAIM_SIZE = Vector3.new(8, 6, 1)
local PROMPT_DISTANCE = 20
local UNCLAIMED_TEXT = "Claim This Plot"

local plotOwners = {} -- [plot] = player
local playerPlots = {} -- [player] = plot

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

-- Both helpers walk down defensively and do nothing if the sign is missing, so
-- a plot built by hand without one can never break claiming.
local function setClaimText(plot, text)
	local claim = plot:FindFirstChild("Claim")
	local billboard = claim and claim:FindFirstChild("Billboard")
	local label = billboard and billboard:FindFirstChild("Label")
	if label then
		label.Text = text
	end
end

local function setPromptEnabled(plot, enabled)
	local claim = plot:FindFirstChild("Claim")
	local prompt = claim and claim:FindFirstChild("ClaimPrompt")
	if prompt then
		prompt.Enabled = enabled
	end
end

local function claimPlot(player, plot)
	if playerPlots[player] then
		return -- they already own a plot
	end

	if plotOwners[plot] then
		return -- someone else got here first
	end

	plotOwners[plot] = player
	playerPlots[player] = plot

	plot:SetAttribute("OwnerUserId", player.UserId)
	player:SetAttribute("PlotName", plot.Name)

	setClaimText(plot, player.DisplayName .. "'s Plot")
	setPromptEnabled(plot, false)

	-- Teleport last, and only if the character is actually there: it may be
	-- loading or dead. A missing character must not undo the claim above.
	local character = player.Character
	if character and character.PrimaryPart then
		-- +5 studs so they land on the plot rather than inside it.
		character:PivotTo(plot.CFrame * CFrame.new(0, 5, 0))
	end
end

local function releasePlot(player)
	local plot = playerPlots[player]
	if not plot then
		return -- they never claimed one
	end

	plotOwners[plot] = nil
	playerPlots[player] = nil
	plot:SetAttribute("OwnerUserId", nil)

	-- Put the sign back so the plot can be claimed again.
	setClaimText(plot, UNCLAIMED_TEXT)
	setPromptEnabled(plot, true)
end

-- Builds the claim sign for a plot. Parented to the plot itself so it travels
-- with it and is always reachable as plot.Claim.
local function ensureClaim(plot)
	local claim = plot:FindFirstChild("Claim")

	if not claim then
		claim = Instance.new("Part")
		claim.Name = "Claim"
		claim.Size = CLAIM_SIZE
		claim.Anchored = true
		claim.CanCollide = false -- players should walk through it
		claim.Locked = true
		claim.Color = Color3.fromRGB(230, 230, 230)
		claim.Material = Enum.Material.SmoothPlastic

		local billboard = Instance.new("BillboardGui")
		billboard.Name = "Billboard"
		billboard.Size = UDim2.fromScale(8, 3)
		billboard.StudsOffset = Vector3.new(0, 4, 0)
		billboard.MaxDistance = 200
		billboard.AlwaysOnTop = true
		billboard.Parent = claim

		local label = Instance.new("TextLabel")
		label.Name = "Label"
		label.Size = UDim2.fromScale(1, 1)
		label.BackgroundTransparency = 1
		label.Text = UNCLAIMED_TEXT
		label.TextScaled = true
		label.TextColor3 = Color3.fromRGB(255, 255, 255)
		label.TextStrokeTransparency = 0 -- keeps it readable against the sky
		label.Parent = billboard

		local prompt = Instance.new("ProximityPrompt")
		prompt.Name = "ClaimPrompt"
		prompt.KeyboardKeyCode = Enum.KeyCode.E
		prompt.ActionText = "Claim"
		prompt.ObjectText = plot.Name
		prompt.MaxActivationDistance = PROMPT_DISTANCE
		prompt.RequiresLineOfSight = false -- otherwise it flickers out when occluded
		prompt.Parent = claim

		-- Connected on creation only, so re-running ensurePlots() never stacks
		-- duplicate handlers on the same prompt.
		prompt.Triggered:Connect(function(player)
			claimPlot(player, plot)
		end)

		claim.Parent = plot
	end

	-- Sit the sign on the plot's inner edge. Plots are built with lookAt facing
	-- the map centre, so local -Z is the edge nearest the hub, and deriving the
	-- CFrame from the plot means the sign inherits its rotation for free.
	claim.CFrame = plot.CFrame * CFrame.new(0, CLAIM_SIZE.Y / 2, -PLOT_SIZE.Z / 2)
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

		-- After the plot is placed, so the sign lands on the right edge.
		ensureClaim(plot)
	end

	return folder
end

ensurePlots()

-- Plots are claimed by hand, so nothing happens on join. Leaving still frees
-- the plot for the next player.
Players.PlayerRemoving:Connect(releasePlot)
