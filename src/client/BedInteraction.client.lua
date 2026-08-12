--[[
	BedInteraction
	Opens BedUi when the local player triggers a Bed's ProximityPrompt.

	No remote involved: a ProximityPrompt's Triggered signal fires locally in a
	LocalScript for the player who actually triggered it, and opening a panel is
	not a privileged action. Everything that matters -- owning the Story, owning
	the bed -- is checked on the server when Start Dreaming is pressed.

	Beds are created at runtime by BedService, one per plot, so they are found by
	CollectionService tag rather than by path.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BedConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BedConfig"))

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- Timed, so a missing panel says so instead of yielding forever. BedUi owns
-- this signal because the consumer should exist before anything fires it.
local bedUi = playerGui:WaitForChild("BedUi", 10)
local openRequest = bedUi and bedUi:WaitForChild("OpenRequest", 10)

if not openRequest then
	warn("BedInteraction: PlayerGui.BedUi.OpenRequest is missing -- is BedUi.client.lua running?")
	return
end

-- Connected prompts, so a bed re-tagged or re-enumerated cannot stack handlers
-- and open the panel twice per press.
local connected = {}

local function bindBed(bed)
	if connected[bed] then
		return
	end

	-- The bed is tagged only after its prompt is parented, but a bed that
	-- somehow lacks one should be skipped rather than error.
	local prompt = bed:FindFirstChildOfClass("ProximityPrompt")
	if not prompt then
		return
	end

	connected[bed] = true

	prompt.Triggered:Connect(function()
		openRequest:Fire()
	end)

	bed.Destroying:Connect(function()
		connected[bed] = nil
	end)
end

for _, bed in ipairs(CollectionService:GetTagged(BedConfig.BED_TAG)) do
	bindBed(bed)
end

-- Beds stream in as plots are set up, so the tag signal is the primary path
-- rather than a fallback.
CollectionService:GetInstanceAddedSignal(BedConfig.BED_TAG):Connect(bindBed)
