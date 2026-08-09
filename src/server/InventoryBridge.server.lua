--[[
	InventoryBridge
	The only link between the server-side InventoryService and the client.

	Deliberately thin: it translates, it does not decide. All inventory rules
	stay in InventoryService -- including how many copies a discard may actually
	take, which is why the amount below is passed straight through rather than
	clamped here.

	Only storyIds, counts and a revision number cross the wire. Names, rarities
	and rewards are resolved client-side from ReplicatedStorage.Shared.StoryData,
	so nothing about pricing is sent over the network and adding a Story never
	changes the protocol.

	The revision is what lets the client order messages. Grants and removals both
	arrive on InventoryUpdated as (storyId, count, revision), and the snapshot
	carries the revision it was taken at, so a client can drop anything older
	than what it has already applied.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local InventoryService = require(ServerScriptService:WaitForChild("Server"):WaitForChild("InventoryService"))

-- Timed, like InventoryUi's lookups: a remote that never arrives -- because
-- `rojo serve` was started before default.project.json declared it -- would
-- otherwise leave this script yielding forever with no clue in the Output.
local Remotes = ReplicatedStorage:WaitForChild("Remotes", 10)
if not Remotes then
	warn("InventoryBridge: ReplicatedStorage.Remotes is missing -- restart `rojo serve` so it re-reads default.project.json")
	return
end

local InventoryUpdated = Remotes:WaitForChild("InventoryUpdated", 10)
local GetInventory = Remotes:WaitForChild("GetInventory", 10)
local DiscardItem = Remotes:WaitForChild("DiscardItem", 10)

if not (InventoryUpdated and GetInventory and DiscardItem) then
	warn("InventoryBridge: Remotes folder is missing InventoryUpdated, GetInventory or DiscardItem -- restart `rojo serve`")
	return
end

-- The UI pulls a snapshot exactly once at startup, so this only ever bites on
-- abuse. Returning nil rather than erroring leaves the client's state intact.
local REQUEST_COOLDOWN = 0.5

-- Discards are behind a confirmation dialog, so a legitimate one can never
-- arrive faster than this. Its own timer, so spamming the trash button cannot
-- lock a player out of the startup snapshot.
local DISCARD_COOLDOWN = 0.2

local lastRequest = {}
local lastDiscard = {}

--// Server -> client push

-- Both directions land on the same remote: the client only cares what the count
-- is now, not why it changed.
local function onCountChanged(player, storyId, newCount, revision)
	-- FireClient, never FireAllClients: one player's collection is not other
	-- players' business.
	InventoryUpdated:FireClient(player, storyId, newCount, revision)
end

InventoryService.StoryGranted.Event:Connect(onCountChanged)
InventoryService.StoryRemoved.Event:Connect(onCountChanged)

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

	-- Read together, with nothing that can yield in between: a grant landing
	-- between these two lines would produce a snapshot labelled with an older
	-- revision than it actually contains, and the client would then replay an
	-- update it had already applied.
	return {
		items = InventoryService.getInventory(player),
		revision = InventoryService.getRevision(player),
	}
end

--// Client -> server discard

-- Requests, never instructions. The client says which slot and how many; the
-- service decides what is actually possible and reports the result through
-- StoryRemoved, so a forged amount cannot take more than the stack holds and a
-- forged storyId simply matches nothing.
DiscardItem.OnServerEvent:Connect(function(player, storyId, amount)
	if type(storyId) ~= "string" or type(amount) ~= "number" then
		return
	end

	local now = os.clock()
	local last = lastDiscard[player]

	if last and now - last < DISCARD_COOLDOWN then
		return
	end

	lastDiscard[player] = now

	InventoryService.discardStory(player, storyId, amount)
end)

Players.PlayerRemoving:Connect(function(player)
	lastRequest[player] = nil
	lastDiscard[player] = nil
end)
