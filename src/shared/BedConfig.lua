--[[
	BedConfig
	The dream cycle's numbers, in one place because both sides need them: the
	BedUi shows "5 x 120 = 600" before the player commits a Story, and BedService
	enforces the same count and interval.

	Shared, not server-only, on purpose. These are display numbers, not secrets --
	a client that lies about them changes nothing, because every payout is still
	re-derived from StoryData on the server, one cycle at a time.

	A Story is worth BaseReward * CYCLES_PER_STORY in total. That product, not
	BaseReward alone, is the number to balance against a Traveler's MoneyGoal.

	Usage:
		local BedConfig = require(ReplicatedStorage.Shared.BedConfig)
		local total = BedConfig.totalReward(story.BaseReward)
]]

local BedConfig = {}

BedConfig.CYCLE_SECONDS = 15 -- seconds between payouts
BedConfig.CYCLES_PER_STORY = 5 -- payouts one Story is worth

-- CollectionService tag, so the client finds beds without hardcoding a path
-- like workspace.Plots.Plot3.Bed. Beds are created at runtime, one per plot.
BedConfig.BED_TAG = "Bed"

-- The one place the total is computed, so the panel's headline number and any
-- future balancing pass can never disagree about what a Story is worth.
function BedConfig.totalReward(baseReward: number): number
	return baseReward * BedConfig.CYCLES_PER_STORY
end

return table.freeze(BedConfig)
