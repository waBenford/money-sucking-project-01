--!strict
--[[
	ItemPreview
	A rotating 3D block standing in for an item, inside a ViewportFrame.

	Placeholder art with depth: there are no meshes or images in this project, so
	a spinning block tinted by rarity says "an item goes here" far better than a
	flat rectangle, and it swaps for a real model later by changing buildModel()
	alone.

	One RenderStepped connection for the whole module, not one per preview. Five
	or six of these are on screen at once and they all want the same tick; a
	connection each would be five times the scheduler traffic for identical work.
	The connection only exists while at least one preview is active, so a closed
	shop costs nothing.

	Active state is set by the owning view rather than read from Visible: a
	preview inside a hidden tab still has Visible = true on itself, and would
	keep spinning off screen.

	Usage:
		local preview = ItemPreview.new({ parent = box, size = UDim2.fromScale(1, 1) })
		preview:SetItem(item)
		preview:SetActive(true)
		preview:Destroy()
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local ItemData = require(ReplicatedStorage.Shared.ItemData)
local Theme = require(ReplicatedStorage.Shared.Theme)

local Components = require(script.Parent.Components)

--// Configuration

local TURNS_PER_SECOND = 0.25 -- a full 360 every four seconds
local BLOCK_SIZE = Vector3.new(2, 2, 2)
local CAMERA_POSITION = Vector3.new(0, 1.6, 5.2)
-- Tilted forward so the top face shows and the block reads as solid rather than
-- as a spinning square.
local BLOCK_TILT = math.rad(18)
local LABEL_HEIGHT = 0.18

local ItemPreview = {}
ItemPreview.__index = ItemPreview

export type Props = {
	parent: Instance,
	size: UDim2,
	position: UDim2?,
	anchorPoint: Vector2?,
	zIndex: number?,
	-- Off by default: the caller decides when its tab is on screen.
	active: boolean?,
}

--// Shared ticker

local activePreviews: { [ItemPreview]: true } = {}
local ticker: RBXScriptConnection? = nil

local function tick(deltaTime: number)
	for preview in pairs(activePreviews) do
		preview.angle = (preview.angle + deltaTime * TURNS_PER_SECOND * math.pi * 2) % (math.pi * 2)
		preview.block.CFrame = CFrame.Angles(BLOCK_TILT, preview.angle, 0)
	end
end

local function refreshTicker()
	local wanted = next(activePreviews) ~= nil

	if wanted and not ticker then
		ticker = RunService.RenderStepped:Connect(tick)
	elseif not wanted and ticker then
		ticker:Disconnect()
		ticker = nil
	end
end

--// Construction

-- The single styling seam. Replace the block with a cloned model here and
-- nothing outside this function needs to know.
local function buildModel(): (WorldModel, BasePart)
	local world = Instance.new("WorldModel")
	world.Name = "World"

	-- TODO: asset -- swap for a per-item model once there is art.
	local block = Instance.new("Part")
	block.Name = "Block"
	block.Size = BLOCK_SIZE
	block.Anchored = true
	block.CanCollide = false
	block.Material = Enum.Material.SmoothPlastic
	block.CFrame = CFrame.Angles(BLOCK_TILT, 0, 0)
	block.Parent = world

	return world, block
end

function ItemPreview.new(props: Props): ItemPreview
	local frame = Instance.new("ViewportFrame")
	frame.Name = "Preview"
	frame.Size = props.size
	frame.BackgroundTransparency = 1
	frame.BorderSizePixel = 0
	-- Without lighting of its own a ViewportFrame renders nearly black, which
	-- would hide the rarity colour the block exists to show.
	frame.Ambient = Theme.Shop.PreviewAmbient
	frame.LightColor = Theme.Shop.PreviewLight
	frame.LightDirection = Vector3.new(-1, -1, -0.6)

	if props.position then
		frame.Position = props.position
	end
	if props.anchorPoint then
		frame.AnchorPoint = props.anchorPoint
	end
	if props.zIndex then
		frame.ZIndex = props.zIndex
	end

	local world, block = buildModel()
	world.Parent = frame

	local camera = Instance.new("Camera")
	camera.CFrame = CFrame.lookAt(CAMERA_POSITION, Vector3.zero)
	camera.Parent = frame
	frame.CurrentCamera = camera

	frame.Parent = props.parent

	local label = Components.label({
		name = "ItemName",
		parent = frame,
		position = UDim2.fromScale(0, 1 - LABEL_HEIGHT),
		size = UDim2.fromScale(1, LABEL_HEIGHT),
		text = "",
		textColor = Theme.Shop.TextOnDark,
		maxTextSize = Theme.Shop.MaxTextSize.Small,
		zIndex = (props.zIndex or 1) + 1,
	})

	local self = setmetatable({
		frame = frame,
		block = block,
		label = label,
		angle = 0,
		active = false,
	}, ItemPreview)

	ItemPreview.SetItem(self, nil)

	if props.active then
		ItemPreview.SetActive(self, true)
	end

	return self
end

--// API

-- nil clears the preview back to its empty state, which is what the side boxes
-- show before anything has been rolled.
function ItemPreview.SetItem(self: ItemPreview, item: ItemData.Item?)
	if item then
		self.block.Color = Theme.rarityColor(item.Rarity)
		self.label.Text = item.Name
	else
		self.block.Color = Theme.Shop.PreviewEmpty
		self.label.Text = ""
	end
end

function ItemPreview.SetActive(self: ItemPreview, active: boolean)
	if self.active == active then
		return
	end

	self.active = active

	if active then
		activePreviews[self] = true
	else
		activePreviews[self] = nil
	end

	refreshTicker()
end

function ItemPreview.Destroy(self: ItemPreview)
	-- Out of the ticker first: leaving it registered would keep both this table
	-- and its destroyed instances alive for as long as the shop runs.
	ItemPreview.SetActive(self, false)
	self.frame:Destroy()
end

export type ItemPreview = typeof(setmetatable(
	{} :: {
		frame: ViewportFrame,
		block: BasePart,
		label: TextLabel,
		angle: number,
		active: boolean,
	},
	ItemPreview
))

return ItemPreview
