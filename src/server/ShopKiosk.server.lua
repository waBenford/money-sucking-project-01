--!strict
--[[
	ShopKiosk
	The thing in the middle of the map you press E at to open the shop.

	A plain Part, deliberately: there is no shop model yet, and a coloured box
	that is in the right place beats a placeholder mesh that has to be found and
	removed later. It borrows the shop window's own blue so the two read as the
	same object.

	No shop logic lives here. It creates the prompt and nothing else -- ShopUi on
	the client listens to Triggered, because a ProximityPrompt fires that event on
	both sides.

	Safe to run repeatedly: like PlotManager's ensurePlots, it converges on one
	kiosk in one place rather than adding another.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

-- ReplicatedStorage is fully populated before server scripts run, so the direct
-- path is safe here and lets --!strict read Theme's types.
local Theme = require(ReplicatedStorage.Shared.Theme)

local KIOSK_NAME = "ShopKiosk"
local PROMPT_NAME = "ShopPrompt"

local KIOSK_SIZE = Vector3.new(12, 12, 12)

-- The map centre, offset off the origin so it does not sit on top of where
-- players arrive. Plots live at a 300-stud radius (PlotManager.PLOT_RADIUS), so
-- the whole hub is free.
local KIOSK_POSITION = Vector3.new(0, KIOSK_SIZE.Y / 2, 24)

local PROMPT_DISTANCE = 14

local function ensurePrompt(kiosk: BasePart)
	if kiosk:FindFirstChild(PROMPT_NAME) then
		return
	end

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = PROMPT_NAME
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.ActionText = "Shop"
	prompt.ObjectText = "Shop"
	prompt.MaxActivationDistance = PROMPT_DISTANCE
	prompt.RequiresLineOfSight = false -- otherwise it flickers out as the player circles it
	prompt.Parent = kiosk
end

local function ensureKiosk(): BasePart
	local existing = Workspace:FindFirstChild(KIOSK_NAME)
	local kiosk = if existing and existing:IsA("BasePart") then existing else nil

	if not kiosk then
		local part = Instance.new("Part")
		part.Name = KIOSK_NAME
		part.Anchored = true -- an unanchored kiosk falls out of the world
		part.Locked = true -- stops accidental dragging in Studio
		part.CanCollide = true
		part.Color = Theme.Shop.WindowFill
		part.Material = Enum.Material.SmoothPlastic
		part.TopSurface = Enum.SurfaceType.Smooth
		part.BottomSurface = Enum.SurfaceType.Smooth
		part.Parent = Workspace

		kiosk = part
	end

	-- Placement is reapplied every run so a kiosk left over from an earlier
	-- session cannot keep a stale position. Appearance is only set on creation,
	-- so colour tweaks in Studio survive.
	local placed = kiosk :: BasePart
	placed.Size = KIOSK_SIZE
	placed.Position = KIOSK_POSITION

	ensurePrompt(placed)

	return placed
end

ensureKiosk()
