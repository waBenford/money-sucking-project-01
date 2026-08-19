--[[
	StoryData
	The single source of truth for Travelers and the Stories they carry.

	Each Traveler has their own pool of stories. When a Traveler leaves and the
	next one arrives, the spawnable pool changes entirely -- so the conveyor
	always rolls against one specific Traveler, never a global list.

	A Story is what the player dreams at their bed to earn money. Rarity runs
	from 1 to 5 stars; BaseReward is the money one dream cycle pays out before
	any bed-upgrade multipliers are applied.

	Usage:
		local StoryData = require(ReplicatedStorage.Shared.StoryData)

		local story = StoryData.getRandomStory("wandering_peddler")
		local saved = StoryData.getStoryById("rain_on_the_window")
		local first = StoryData.Travelers[StoryData.TravelerOrder[1] ]
]]

local ItemCategories = require(script.Parent:WaitForChild("ItemCategories"))

local StoryData = {}

-- Id is the stable key: it goes into DataStores and must never change.
-- Name is display text and is free to be reworded or localised.
export type Story = {
	Id: string,
	Name: string,
	-- An ItemCategories id. Optional here because the entries below do not spell
	-- it out: the index loop stamps it on every Story before freezing it, so it
	-- is always a string by the time anything can read one.
	Category: string?,
	Rarity: number, -- 1 (common) to 5 (legendary)
	BaseReward: number, -- money per dream cycle, before bed multipliers
	Weight: number, -- relative drop chance within this Traveler's pool
}

export type Traveler = {
	Id: string,
	Name: string,
	Level: number, -- arrival order; higher means richer stories
	MoneyGoal: number, -- money the player must hand over before they depart
	Stories: { Story },
}

StoryData.MAX_RARITY = 5

--// Data
--
-- Every Traveler carries six stories spanning rarities 1,1,2,3,4,5 on the same
-- weight curve (500/500/250/100/30/5). Only BaseReward scales with Level, so a
-- 3-star from the Archivist out-earns a 5-star from the Peddler.

local Travelers: { [string]: Traveler } = {
	wandering_peddler = {
		Id = "wandering_peddler",
		Name = "The Wandering Peddler",
		Level = 1,
		MoneyGoal = 2500,
		Stories = {
			{ Id = "a_dreamless_nap", Name = "A Dreamless Nap", Rarity = 1, BaseReward = 10, Weight = 500 },
			{ Id = "rain_on_the_window", Name = "Rain on the Window", Rarity = 1, BaseReward = 10, Weight = 500 },
			{ Id = "the_long_road_home", Name = "The Long Road Home", Rarity = 2, BaseReward = 35, Weight = 250 },
			{ Id = "a_market_at_dawn", Name = "A Market at Dawn", Rarity = 3, BaseReward = 120, Weight = 100 },
			{ Id = "the_coin_that_returned", Name = "The Coin That Always Returned", Rarity = 4, BaseReward = 500, Weight = 30 },
			{ Id = "salt_road_lullaby", Name = "Salt Road Lullaby", Rarity = 5, BaseReward = 2500, Weight = 5 },
		},
	},

	lighthouse_keeper = {
		Id = "lighthouse_keeper",
		Name = "The Lighthouse Keeper",
		Level = 2,
		MoneyGoal = 30000,
		Stories = {
			{ Id = "fog_before_morning", Name = "Fog Before Morning", Rarity = 1, BaseReward = 60, Weight = 500 },
			{ Id = "the_tide_chart", Name = "The Tide Chart", Rarity = 1, BaseReward = 60, Weight = 500 },
			{ Id = "letters_never_sent", Name = "Letters Never Sent", Rarity = 2, BaseReward = 210, Weight = 250 },
			{ Id = "the_ship_that_waited", Name = "The Ship That Waited", Rarity = 3, BaseReward = 720, Weight = 100 },
			{ Id = "city_beneath_the_salt", Name = "City Beneath the Salt Flats", Rarity = 4, BaseReward = 3000, Weight = 30 },
			{ Id = "ocean_that_dreamed_a_man", Name = "The Ocean That Dreamed a Man", Rarity = 5, BaseReward = 15000, Weight = 5 },
		},
	},

	starlit_archivist = {
		Id = "starlit_archivist",
		Name = "The Starlit Archivist",
		Level = 3,
		MoneyGoal = 300000,
		Stories = {
			{ Id = "a_footnote_in_gold", Name = "A Footnote in Gold", Rarity = 1, BaseReward = 360, Weight = 500 },
			{ Id = "the_borrowed_hour", Name = "The Borrowed Hour", Rarity = 1, BaseReward = 360, Weight = 500 },
			{ Id = "the_cartographers_regret", Name = "The Cartographer's Regret", Rarity = 2, BaseReward = 1260, Weight = 250 },
			{ Id = "where_the_compass_spins", Name = "Where the Compass Spins", Rarity = 3, BaseReward = 4320, Weight = 100 },
			{ Id = "emperor_of_small_hours", Name = "The Emperor of Small Hours", Rarity = 4, BaseReward = 18000, Weight = 30 },
			{ Id = "last_travelers_confession", Name = "The Last Traveler's Confession", Rarity = 5, BaseReward = 90000, Weight = 5 },
		},
	},
}

--// Story Levels
--
-- The progression ladder the Quest NPC sells. A player's StoryLevel decides how
-- much of the catalogue their conveyor may spawn, and the pool is CUMULATIVE:
-- reaching Level 2 adds its stories to Level 1's rather than replacing them.
--
-- This is the one place a Story is assigned to a Level. Everything else derives
-- from it -- story.Level is stamped from here in the loop below, and the load
-- asserts catch an id that is listed twice or not at all.

export type StoryLevel = {
	Level: number,
	UnlockCost: number, -- money to reach this level; Level 1 costs nothing
	StoryIds: { string },
}

local Levels: { StoryLevel } = {
	{
		Level = 1,
		UnlockCost = 0, -- everyone starts here
		StoryIds = {
			"a_dreamless_nap",
			"rain_on_the_window",
			"the_long_road_home",
			"a_market_at_dawn",
			"the_coin_that_returned",
			"salt_road_lullaby",
		},
	},
	{
		Level = 2,
		UnlockCost = 2500,
		StoryIds = {
			"fog_before_morning",
			"the_tide_chart",
			"letters_never_sent",
			"the_ship_that_waited",
			"city_beneath_the_salt",
			"ocean_that_dreamed_a_man",
		},
	},
	{
		Level = 3,
		UnlockCost = 30000,
		StoryIds = {
			"a_footnote_in_gold",
			"the_borrowed_hour",
			"the_cartographers_regret",
			"where_the_compass_spins",
			"emperor_of_small_hours",
			"last_travelers_confession",
		},
	},
}

StoryData.MAX_LEVEL = #Levels
StoryData.MIN_LEVEL = 1

-- Built before the index loop, because that loop stamps story.Level from it.
local levelByStoryId: { [string]: number } = {}
local unlockCostByLevel: { [number]: number } = {}

for _, entry in ipairs(Levels) do
	unlockCostByLevel[entry.Level] = entry.UnlockCost

	for _, storyId in ipairs(entry.StoryIds) do
		assert(
			levelByStoryId[storyId] == nil,
			("StoryData: story '%s' is listed in more than one Level"):format(storyId)
		)
		levelByStoryId[storyId] = entry.Level
	end

	table.freeze(entry.StoryIds)
	table.freeze(entry)
end

table.freeze(Levels)
table.freeze(unlockCostByLevel)

StoryData.Levels = Levels

--// Load-time indexes
--
-- All built once at require: the conveyor calls getRandomStory on a timer, so
-- nothing here should be recomputed per call.

local totalWeights: { [string]: number } = {}
local storiesById: { [string]: Story } = {}

StoryData.TravelerOrder = {} :: { string }

for travelerId, traveler in pairs(Travelers) do
	local total = 0

	for _, story in ipairs(traveler.Stories) do
		-- The id index is global, so a duplicate would silently shadow another
		-- Traveler's story and mis-price its payout. Fail at startup instead.
		assert(
			storiesById[story.Id] == nil,
			("StoryData: duplicate story id '%s' (in traveler '%s')"):format(story.Id, travelerId)
		)

		-- Assigned here rather than repeated on all eighteen entries: every Story
		-- is by definition in the Story category, and the inventory tabs filter
		-- on this field. Must happen before the freeze below.
		story.Category = ItemCategories.STORY

		-- Stamped from the Levels table, same as Category. A Story missing from
		-- every Level would silently never spawn, so fail at startup instead.
		story.Level = assert(
			levelByStoryId[story.Id],
			("StoryData: story '%s' is not listed in any Level"):format(story.Id)
		)

		storiesById[story.Id] = story
		total += story.Weight

		-- getRandomStory hands out shared references, so freeze each entry: a
		-- stray write in consumer code would otherwise corrupt the story for
		-- the whole server. table.freeze is shallow, hence bottom-up here.
		table.freeze(story)
	end

	assert(total > 0, ("StoryData: traveler '%s' has no drop weight"):format(travelerId))

	totalWeights[travelerId] = total
	table.insert(StoryData.TravelerOrder, travelerId)

	table.freeze(traveler.Stories)
	table.freeze(traveler)
end

-- Dictionary iteration order is undefined, so progression code cannot find
-- "the next Traveler" by walking Travelers. Sort by Level to give it a
-- deterministic sequence.
table.sort(StoryData.TravelerOrder, function(a, b)
	return Travelers[a].Level < Travelers[b].Level
end)

-- The other half of the Level check: every id listed in Levels must resolve to
-- a real Story. A typo here would otherwise just shrink the spawn pool quietly.
for _, entry in ipairs(Levels) do
	for _, storyId in ipairs(entry.StoryIds) do
		assert(
			storiesById[storyId],
			("StoryData: Level %d lists unknown story '%s'"):format(entry.Level, storyId)
		)
	end
end

table.freeze(Travelers)
table.freeze(storiesById)
table.freeze(totalWeights)
table.freeze(StoryData.TravelerOrder)

StoryData.Travelers = Travelers

-- Cumulative spawn pools, one per reachable level: poolsByMaxLevel[n] holds
-- every Story with Level <= n. Precomputed because the conveyor asks for one on
-- a timer, and rebuilding the list per spawn would be pure waste.
local poolsByMaxLevel: { [number]: { stories: { Story }, totalWeight: number } } = {}

for maxLevel = StoryData.MIN_LEVEL, StoryData.MAX_LEVEL do
	local stories = {}
	local totalWeight = 0

	-- Walked in Level order so the pool is deterministic, which keeps the
	-- weighted walk below reproducible for a given seed.
	for _, entry in ipairs(Levels) do
		if entry.Level <= maxLevel then
			for _, storyId in ipairs(entry.StoryIds) do
				local story = storiesById[storyId]
				table.insert(stories, story)
				totalWeight += story.Weight
			end
		end
	end

	assert(totalWeight > 0, ("StoryData: level %d has no drop weight"):format(maxLevel))

	table.freeze(stories)
	poolsByMaxLevel[maxLevel] = table.freeze({ stories = stories, totalWeight = totalWeight })
end

table.freeze(poolsByMaxLevel)

-- Per-level Story lists, and the quest requirement derived from them: one copy
-- of each rarity the level contains. Derived rather than authored, so adding a
-- Story to a Level automatically updates both what the panel shows and what the
-- server demands.
local storiesByLevel: { [number]: { Story } } = {}
local requirementByLevel: { [number]: { { Rarity: number, StoryIds: { string } } } } = {}

for _, entry in ipairs(Levels) do
	local stories = {}
	local idsByRarity: { [number]: { string } } = {}
	local rarities = {}

	for _, storyId in ipairs(entry.StoryIds) do
		local story = storiesById[storyId]
		table.insert(stories, story)

		local bucket = idsByRarity[story.Rarity]
		if not bucket then
			bucket = {}
			idsByRarity[story.Rarity] = bucket
			table.insert(rarities, story.Rarity)
		end

		table.insert(bucket, storyId)
	end

	-- Ascending, so the panel lists the cheap commons before the legendary and
	-- the server reports missing rarities in a readable order.
	table.sort(rarities)

	local requirement = {}
	for _, rarity in ipairs(rarities) do
		table.freeze(idsByRarity[rarity])
		table.insert(requirement, table.freeze({ Rarity = rarity, StoryIds = idsByRarity[rarity] }))
	end

	storiesByLevel[entry.Level] = table.freeze(stories)
	requirementByLevel[entry.Level] = table.freeze(requirement)
end

table.freeze(storiesByLevel)
table.freeze(requirementByLevel)

-- Its own stream, so no other script reseeding the global math.random generator
-- can shift the drop rates.
local rng = Random.new()

--// API

function StoryData.getTraveler(travelerId: string): Traveler?
	return Travelers[travelerId]
end

-- Resolves a saved Id back to its Story, across every Traveler. The player
-- keeps collected stories after a Traveler departs, so bed payouts cannot look
-- them up through a Traveler. Returns nil for unknown ids, so a story removed
-- in a later update cannot break loading an old save.
function StoryData.getStoryById(storyId: string): Story?
	return storiesById[storyId]
end

-- Weighted pick from one Traveler's pool: walk their stories accumulating
-- weight until the roll is covered.
function StoryData.getRandomStory(travelerId: string): Story?
	local traveler = Travelers[travelerId]
	if not traveler then
		-- warn rather than error: a bad id is a bug and must be visible, but
		-- raising here would kill the conveyor loop for everyone on the server.
		warn(("StoryData: unknown traveler id '%s'"):format(tostring(travelerId)))
		return nil
	end

	local roll = rng:NextNumber(0, totalWeights[travelerId])
	local cumulative = 0

	for _, story in ipairs(traveler.Stories) do
		cumulative += story.Weight
		if roll <= cumulative then
			return story
		end
	end

	-- Accumulated float error can leave roll a hair above the final cumulative.
	-- Without this the loop falls through and returns nil to the caller.
	return traveler.Stories[#traveler.Stories]
end

--// Levels

-- Money required to reach `level`. Returns nil past the last one, which is how
-- callers tell "max level" from "free".
function StoryData.getUnlockCost(level: number): number?
	return unlockCostByLevel[level]
end

-- Every Story belonging to `level`, in the order it is listed. The quest panel
-- shows this as "what you will get" for the level being unlocked.
function StoryData.getLevelStories(level: number): { Story }
	return storiesByLevel[level] or {}
end

-- What the quest for `level` demands in Stories: one copy of each rarity that
-- level contains.
--
-- Grouped by rarity rather than listed as flat ids because a level can hold two
-- Stories of the same rarity (every level has two commons), and either one
-- satisfies that slot. Callers pick whichever the player actually holds.
--
-- The client renders from this and the server validates against it, so the
-- requirement shown and the requirement enforced cannot drift apart.
function StoryData.getQuestRequirement(level: number): { { Rarity: number, StoryIds: { string } } }
	return requirementByLevel[level] or {}
end

-- Weighted pick across every Story from Level 1 up to maxLevel -- the conveyor's
-- entry point. Same cumulative walk as getRandomStory, over a precomputed pool.
function StoryData.getRandomStoryUpToLevel(maxLevel: number): Story?
	-- Clamped rather than rejected: a player's level is server data, but it can
	-- legitimately be missing for a frame during join, and a belt should keep
	-- spawning Level 1 stories rather than stall.
	local clamped = math.clamp(
		math.floor(tonumber(maxLevel) or StoryData.MIN_LEVEL),
		StoryData.MIN_LEVEL,
		StoryData.MAX_LEVEL
	)

	local pool = poolsByMaxLevel[clamped]
	local roll = rng:NextNumber(0, pool.totalWeight)
	local cumulative = 0

	for _, story in ipairs(pool.stories) do
		cumulative += story.Weight
		if roll <= cumulative then
			return story
		end
	end

	-- Same float-rounding guard as above.
	return pool.stories[#pool.stories]
end

return StoryData
