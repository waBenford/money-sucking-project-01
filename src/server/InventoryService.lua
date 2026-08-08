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

	Usage:
		local InventoryService = require(ServerScriptService.Server.InventoryService)

		local ok, reason = InventoryService.grantStory(player, "salt_road_lullaby")
		local count = InventoryService.getCount(player, "salt_road_lullaby")
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local StoryData = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("StoryData"))

local InventoryService = {}

-- A stated ceiling so the structure has a defined failure mode before
-- persistence exists. Raise it, or swap it for a bed-upgrade-driven value.
local MAX_STORIES = 100

-- [player] = { [storyId] = count }
local inventories = {}

-- Fired on every successful grant, as (player, storyId, newCount). Inventory UI
-- and quest tracking subscribe here rather than editing this module.
InventoryService.StoryGranted = Instance.new("BindableEvent")

--// Internal

local function totalHeld(inventory)
	local total = 0
	for _, count in pairs(inventory) do
		total += count
	end
	return total
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

	if totalHeld(inventory) >= MAX_STORIES then
		return false, "inventory_full"
	end

	local newCount = (inventory[storyId] or 0) + 1
	inventory[storyId] = newCount

	InventoryService.StoryGranted:Fire(player, storyId, newCount)

	return true
end

-- Removes one copy. The bed's entry point for dreaming a Story: it reads
-- BaseReward from StoryData itself, so the payout never depends on what the
-- caller believes the story is worth.
function InventoryService.consumeStory(player: Player, storyId: string): boolean
	local inventory = inventories[player]
	if not inventory then
		return false
	end

	local count = inventory[storyId]
	if not count or count <= 0 then
		return false
	end

	if count == 1 then
		inventory[storyId] = nil -- keep the table free of zero entries
	else
		inventory[storyId] = count - 1
	end

	return true
end

function InventoryService.getCount(player: Player, storyId: string): number
	local inventory = inventories[player]
	return inventory and inventory[storyId] or 0
end

-- Returns a copy: callers must go through grantStory/consumeStory to change
-- anything, so a stray write on the returned table cannot desync the real one.
function InventoryService.getInventory(player: Player): { [string]: number }
	local inventory = inventories[player]
	if not inventory then
		return {}
	end

	return table.clone(inventory)
end

--// Lifecycle
--
-- In-memory only for now. Persistence hooks in here: load into inventories on
-- join, save on leave, mirroring PlayerData.server.lua's pcall-guarded pattern.

local function onPlayerAdded(player)
	inventories[player] = {}
end

local function onPlayerRemoving(player)
	inventories[player] = nil
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
