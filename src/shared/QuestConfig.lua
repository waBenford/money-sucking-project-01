--[[
	QuestConfig
	Constants the Quest NPC needs on both sides: QuestService spawns and tags the
	NPC, QuestInteraction finds it by that tag, and PlayerData seeds a new
	player's level.

	The costs themselves are NOT here -- they live with the Stories they unlock,
	in StoryData.Levels, so a level's price and its contents can never drift
	apart.

	Usage:
		local QuestConfig = require(ReplicatedStorage.Shared.QuestConfig)
		CollectionService:AddTag(npc, QuestConfig.NPC_TAG)
]]

local QuestConfig = {}

-- CollectionService tag, so the client finds NPCs without hardcoding a path
-- like workspace.Plots.Plot3.QuestNpc. NPCs are created at runtime, one per plot.
QuestConfig.NPC_TAG = "QuestNpc"

QuestConfig.DEFAULT_STORY_LEVEL = 1

return table.freeze(QuestConfig)
