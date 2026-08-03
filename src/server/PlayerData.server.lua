--[[
	PlayerData
	Loads and saves each player's Money to a DataStore.

	Money lives in player.leaderstats.Money, which Roblox shows in the player list.
	Every DataStore call is wrapped in pcall -- they are network calls and will
	throw if the API is throttled, down, or disabled in Studio.
]]

local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")

-- The "_v1" suffix lets us start a fresh key space later without wiping old data.
local moneyStore = DataStoreService:GetDataStore("PlayerMoney_v1")

local DEFAULT_MONEY = 0

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

	leaderstats.Parent = player

	local ok, result = pcall(function()
		return moneyStore:GetAsync(keyFor(player))
	end)

	if not ok then
		warn(("Failed to load data for %s: %s"):format(player.Name, tostring(result)))
		return
	end

	-- A nil result just means this is their first time playing.
	if result ~= nil then
		money.Value = result
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
	if not money then
		return
	end

	local ok, err = pcall(function()
		moneyStore:SetAsync(keyFor(player), money.Value)
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
