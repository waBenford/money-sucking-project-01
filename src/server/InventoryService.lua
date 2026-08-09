--[[
	InventoryService
	Owns every player's collected Stories. Nothing else may write to an
	inventory directly.

	Server-only on purpose: this lives in ServerScriptService, not
	ReplicatedStorage, so no client can require it or read its logic. StoryData
	is shared because clients need names and rarities to render items; grant
	logic is not.

	Collecting a Story stores it. Money is earned later, by dreaming it at the
	bed -- this module deliberately never touches leaderstats.

	Capacity comes from ReplicatedStorage.Shared.InventoryConfig, which the UI
	reads too: MAX_SLOTS distinct kinds, MAX_STACK copies of each. This module is
	the only thing that enforces them -- the client merely displays them.

	Usage:
		local InventoryService = require(ServerScriptService.Server.InventoryService)

		local ok, reason = InventoryService.grantStory(player, "salt_road_lullaby")
		local count = InventoryService.getCount(player, "salt_road_lullaby")
		local ok, left = InventoryService.discardStory(player, "salt_road_lullaby", 2)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local InventoryConfig = require(Shared:WaitForChild("InventoryConfig"))
local StoryData = require(Shared:WaitForChild("StoryData"))

local InventoryService = {}

-- [player] = { [storyId] = count }
local inventories = {}

-- [player] = number. Bumped on every change and sent out with every event and
-- snapshot, so a client can tell a stale message from a fresh one. Counts can
-- now go down, which means "the bigger number wins" is no longer a safe way to
-- reconcile a snapshot against a live update.
local revisions = {}

-- Fired on every successful grant, as (player, storyId, newCount, revision).
-- Inventory UI and quest tracking subscribe here rather than editing this module.
InventoryService.StoryGranted = Instance.new("BindableEvent")

-- The mirror of the above, for a count going down -- dreaming a Story at the bed
-- or throwing one away. Same payload, so a listener that only cares about the
-- new count can connect one handler to both.
InventoryService.StoryRemoved = Instance.new("BindableEvent")

--// Internal

-- Slots, not copies: one kind of item occupies exactly one slot no matter how
-- many are stacked in it, which is what the "n/20" counter in the UI shows.
local function slotsUsed(inventory)
	local used = 0
	for _ in pairs(inventory) do
		used += 1
	end
	return used
end

local function bumpRevision(player)
	local revision = (revisions[player] or 0) + 1
	revisions[player] = revision
	return revision
end

--// API

-- Grants one copy of a Story. Takes only a player and an id: the Story -- and
-- therefore its BaseReward -- is re-derived from StoryData rather than trusted
-- from the caller, so nothing upstream can inflate a reward by passing its own
-- numbers. Returns false plus a reason rather than erroring, leaving the
-- caller to decide what the player sees.
function InventoryService.grantStory(player: Player, storyId: string): (boolean, string?)
	local inventory = inventories[player]
	if not inventory then
		-- Player left mid-collection, or was never registered.
		return false, "no_inventory"
	end

	local story = StoryData.getStoryById(storyId)
	if not story then
		-- A story id that does not exist means a bug in the caller, not player
		-- input, so it is worth surfacing.
		warn(("InventoryService: unknown story id '%s'"):format(tostring(storyId)))
		return false, "unknown_story"
	end

	local count = inventory[storyId]

	if count then
		-- A stack tops out instead of spilling into a second slot, so a player
		-- holding five of something cannot take a sixth even with slots free.
		if count >= InventoryConfig.MAX_STACK then
			return false, "stack_full"
		end
	elseif slotsUsed(inventory) >= InventoryConfig.MAX_SLOTS then
		-- Only a *new* kind needs a free slot; topping up an existing stack is
		-- always allowed by this check.
		return false, "inventory_full"
	end

	local newCount = (count or 0) + 1
	inventory[storyId] = newCount

	InventoryService.StoryGranted:Fire(player, storyId, newCount, bumpRevision(player))

	return true
end

-- Shared by consumeStory and discardStory. Returns the count left, or nil when
-- there was nothing to take. Fires StoryRemoved once, whatever the amount, so
-- the UI never has to coalesce a burst of single-copy events.
local function removeCopies(player, storyId, amount)
	local inventory = inventories[player]
	if not inventory then
		return nil
	end

	local count = inventory[storyId]
	if not count or count <= 0 then
		return nil
	end

	local taken = math.min(amount, count)
	local remaining = count - taken

	if remaining <= 0 then
		inventory[storyId] = nil -- keep the table free of zero entries
		remaining = 0
	else
		inventory[storyId] = remaining
	end

	InventoryService.StoryRemoved:Fire(player, storyId, remaining, bumpRevision(player))

	return remaining
end

-- Removes one copy. The bed's entry point for dreaming a Story: it reads
-- BaseReward from StoryData itself, so the payout never depends on what the
-- caller believes the story is worth.
function InventoryService.consumeStory(player: Player, storyId: string): boolean
	return removeCopies(player, storyId, 1) ~= nil
end

-- Throws copies away for nothing in return -- the inventory panel's trash
-- button. `amount` comes from a client, so it is floored and clamped here rather
-- than trusted: asking for 999 removes the stack and nothing more, a fraction is
-- floored, and anything under one (or a NaN) removes nothing at all. Returns the
-- count left in the slot.
function InventoryService.discardStory(player: Player, storyId: string, amount: number): (boolean, number)
	if type(amount) ~= "number" or amount ~= amount then
		return false, InventoryService.getCount(player, storyId)
	end

	local requested = math.floor(amount)
	if requested < 1 then
		return false, InventoryService.getCount(player, storyId)
	end

	local remaining = removeCopies(player, storyId, math.min(requested, InventoryConfig.MAX_STACK))
	if not remaining then
		return false, 0
	end

	return true, remaining
end

function InventoryService.getCount(player: Player, storyId: string): number
	local inventory = inventories[player]
	return inventory and inventory[storyId] or 0
end

-- Returns a copy: callers must go through grantStory/consumeStory/discardStory to
-- change anything, so a stray write on the returned table cannot desync the real
-- one.
function InventoryService.getInventory(player: Player): { [string]: number }
	local inventory = inventories[player]
	if not inventory then
		return {}
	end

	return table.clone(inventory)
end

-- The revision the values from getInventory belong to. Read it in the same
-- (non-yielding) breath as the snapshot, or the pair can describe two different
-- moments and the client will discard live updates it still needs.
function InventoryService.getRevision(player: Player): number
	return revisions[player] or 0
end

--// Lifecycle
--
-- In-memory only for now. Persistence hooks in here: load into inventories on
-- join, save on leave, mirroring PlayerData.server.lua's pcall-guarded pattern.

local function onPlayerAdded(player)
	inventories[player] = {}
	revisions[player] = 0
end

local function onPlayerRemoving(player)
	inventories[player] = nil
	revisions[player] = nil
end

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)

-- Covers anyone who joined before this module was first required.
for _, player in ipairs(Players:GetPlayers()) do
	if not inventories[player] then
		onPlayerAdded(player)
	end
end

return InventoryService
