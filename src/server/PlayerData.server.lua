--[[
	PlayerData
	Loads and saves each player's Money and StoryLevel to a DataStore.

	Both live in player.leaderstats, which Roblox shows in the player list.
	Every DataStore call is wrapped in pcall -- they are network calls and will
	throw if the API is throttled, down, or disabled in Studio.

	The saved value used to be a bare number (Money alone). It is a table now, and
	the loader still accepts the old shape -- see onPlayerAdded. That is why the
	key keeps its _v1 name: bumping it would have reset everyone's money.
]]

local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local QuestConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("QuestConfig"))

-- The "_v1" suffix lets us start a fresh key space later without wiping old data.
local moneyStore = DataStoreService:GetDataStore("PlayerMoney_v1")

local DEFAULT_MONEY = 0
local DEFAULT_STORY_LEVEL = QuestConfig.DEFAULT_STORY_LEVEL

-- Players whose data loaded successfully. We only save for these, so a failed
-- load can never overwrite good saved data with the default value.
local sessionLoaded = {}

-- Key on UserId, never Name -- players can change their name.
local function keyFor(player)
	return "Player_" .. player.UserId
end

local function onPlayerAdded(player)
	-- Build leaderstats, parenting the folder last so the player list never
	-- briefly shows an empty leaderstats.
	local leaderstats = Instance.new("Folder")
	leaderstats.Name = "leaderstats"

	local money = Instance.new("IntValue")
	money.Name = "Money"
	money.Value = DEFAULT_MONEY
	money.Parent = leaderstats

	-- Shown on the player list beside Money, and read by the conveyor to decide
	-- which Stories may spawn. The client reads it straight off leaderstats,
	-- which is why QuestUi needs no remote to display it.
	local storyLevel = Instance.new("IntValue")
	storyLevel.Name = "StoryLevel"
	storyLevel.Value = DEFAULT_STORY_LEVEL
	storyLevel.Parent = leaderstats

	leaderstats.Parent = player

	local ok, result = pcall(function()
		return moneyStore:GetAsync(keyFor(player))
	end)

	if not ok then
		warn(("Failed to load data for %s: %s"):format(player.Name, tostring(result)))
		return
	end

	-- Three shapes to handle. nil is a first-time player; a bare number is a save
	-- written before StoryLevel existed, and keeping that branch is what lets the
	-- key stay _v1 without wiping anyone's money.
	if type(result) == "number" then
		money.Value = result
	elseif type(result) == "table" then
		money.Value = result.Money or DEFAULT_MONEY
		storyLevel.Value = result.StoryLevel or DEFAULT_STORY_LEVEL
	end

	sessionLoaded[player] = true
end

local function savePlayer(player)
	-- Never save for a player whose load failed -- that would wipe their data.
	if not sessionLoaded[player] then
		return
	end

	local leaderstats = player:FindFirstChild("leaderstats")
	local money = leaderstats and leaderstats:FindFirstChild("Money")
	local storyLevel = leaderstats and leaderstats:FindFirstChild("StoryLevel")
	if not (money and storyLevel) then
		return
	end

	local ok, err = pcall(function()
		moneyStore:SetAsync(keyFor(player), {
			Money = money.Value,
			StoryLevel = storyLevel.Value,
		})
	end)

	if not ok then
		warn(("Failed to save data for %s: %s"):format(player.Name, tostring(err)))
	end
end

local function onPlayerRemoving(player)
	savePlayer(player)
	sessionLoaded[player] = nil
end

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)

-- Catch anyone who joined before this script started running.
for _, player in ipairs(Players:GetPlayers()) do
	onPlayerAdded(player)
end

-- Without this, a server shutdown loses the whole session's progress:
-- PlayerRemoving does not reliably fire for everyone when the server closes.
game:BindToClose(function()
	for _, player in ipairs(Players:GetPlayers()) do
		savePlayer(player)
	end
end)
