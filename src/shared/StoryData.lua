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

table.freeze(Travelers)
table.freeze(storiesById)
table.freeze(totalWeights)
table.freeze(StoryData.TravelerOrder)

StoryData.Travelers = Travelers

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

return StoryData
