--[[
	InventoryBridge
	The only link between the server-side InventoryService and the client.

	Deliberately thin: it translates, it does not decide. All inventory rules
	stay in InventoryService.

	Only storyIds and counts cross the wire. Names, rarities and rewards are
	resolved client-side from ReplicatedStorage.Shared.StoryData, so nothing
	about pricing is sent over the network and adding a Story never changes the
	protocol.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local InventoryService = require(ServerScriptService:WaitForChild("Server"):WaitForChild("InventoryService"))

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local InventoryUpdated = Remotes:WaitForChild("InventoryUpdated")
local GetInventory = Remotes:WaitForChild("GetInventory")

-- The UI pulls a snapshot exactly once at startup, so this only ever bites on
-- abuse. Returning nil rather than erroring leaves the client's state intact.
local REQUEST_COOLDOWN = 0.5

local lastRequest = {}

--// Server -> client push

InventoryService.StoryGranted.Event:Connect(function(player, storyId, newCount)
	-- FireClient, never FireAllClients: one player's collection is not other
	-- players' business.
	InventoryUpdated:FireClient(player, storyId, newCount)
end)

--// Client -> server pull

-- `player` is supplied by the engine, not by the caller, so a client can only
-- ever retrieve its own inventory -- there is no id argument to forge.
function GetInventory.OnServerInvoke(player)
	local now = os.clock()
	local last = lastRequest[player]

	if last and now - last < REQUEST_COOLDOWN then
		return nil
	end

	lastRequest[player] = now

	return InventoryService.getInventory(player)
end

Players.PlayerRemoving:Connect(function(player)
	lastRequest[player] = nil
end)
