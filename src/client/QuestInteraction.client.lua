--[[
	QuestInteraction
	Opens QuestUi when the local player triggers a Traveler NPC's ProximityPrompt.

	No remote involved: a ProximityPrompt's Triggered signal fires locally in a
	LocalScript for the player who actually triggered it, and opening a panel is
	not a privileged action. The unlock itself is checked entirely on the server.

	NPCs are created at runtime by QuestService, one per plot, so they are found
	by CollectionService tag rather than by path.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local QuestConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("QuestConfig"))

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- Timed, so a missing panel says so instead of yielding forever. QuestUi owns
-- this signal because the consumer should exist before anything fires it.
local questUi = playerGui:WaitForChild("QuestUi", 10)
local openRequest = questUi and questUi:WaitForChild("OpenRequest", 10)

if not openRequest then
	warn("QuestInteraction: PlayerGui.QuestUi.OpenRequest is missing -- is QuestUi.client.lua running?")
	return
end

-- Connected prompts, so an NPC re-tagged or re-enumerated cannot stack handlers
-- and open the panel twice per press.
local connected = {}

local function bindNpc(npc)
	if connected[npc] then
		return
	end

	-- The NPC is tagged only after its prompt is parented, but one that somehow
	-- lacks a prompt should be skipped rather than error.
	local prompt = npc:FindFirstChildOfClass("ProximityPrompt")
	if not prompt then
		return
	end

	connected[npc] = true

	prompt.Triggered:Connect(function()
		openRequest:Fire()
	end)

	npc.Destroying:Connect(function()
		connected[npc] = nil
	end)
end

for _, npc in ipairs(CollectionService:GetTagged(QuestConfig.NPC_TAG)) do
	bindNpc(npc)
end

-- NPCs stream in as plots are set up, so the tag signal is the primary path
-- rather than a fallback.
CollectionService:GetInstanceAddedSignal(QuestConfig.NPC_TAG):Connect(bindNpc)
