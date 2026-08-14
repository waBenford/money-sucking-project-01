--!strict
--[[
	ShopUi
	Wires the shop window to the world: find the kiosk, find the player's money,
	hand both to ShopController.

	Opening goes through the kiosk's ProximityPrompt rather than a remote.
	Triggered fires on the client as well as the server, so the local player
	pressing E is already a client-side event -- adding a RemoteEvent to relay it
	back would be a round trip to learn something we already know.

	The wireframes have no close button, so the two ways out are pressing E again
	and walking away, which hides the prompt.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

-- Direct path, not WaitForChild: the Shop folder is a Rojo-synced sibling of this
-- script, and --!strict cannot resolve a module's types through WaitForChild.
local ShopController = require(script.Parent.Shop.ShopController)

local KIOSK_NAME = "ShopKiosk"
local PROMPT_NAME = "ShopPrompt"

-- Timed, so a missing instance says so instead of yielding forever. An untimed
-- WaitForChild here would leave the script hanging with the shop simply absent --
-- the hardest kind of failure to diagnose.
local Remotes = ReplicatedStorage:WaitForChild("Remotes", 10)
if not Remotes then
	warn("ShopUi: ReplicatedStorage.Remotes is missing -- restart `rojo serve` so it re-reads default.project.json")
	return
end

local shopRequest = Remotes:WaitForChild("ShopRequest", 10)
if not shopRequest or not shopRequest:IsA("RemoteFunction") then
	warn("ShopUi: Remotes.ShopRequest is missing or is not a RemoteFunction")
	return
end

local player = Players.LocalPlayer

-- PlayerData builds leaderstats on join, which can land after this script runs.
local leaderstats = player:WaitForChild("leaderstats", 20)
local money = leaderstats and leaderstats:WaitForChild("Money", 10)

if not money or not money:IsA("IntValue") then
	warn("ShopUi: leaderstats.Money is missing -- is PlayerData running?")
	return
end

-- Longer wait than the remotes: the kiosk is built by a server script that also
-- waits on the Workspace, and it replicates rather than being declared in the
-- project file.
local kiosk = Workspace:WaitForChild(KIOSK_NAME, 30)
local prompt = kiosk and kiosk:WaitForChild(PROMPT_NAME, 10)

if not prompt or not prompt:IsA("ProximityPrompt") then
	warn("ShopUi: the shop kiosk has no ProximityPrompt -- is ShopKiosk running?")
	return
end

local controller = ShopController.new({
	currency = money,
	remote = shopRequest,
})

-- On the client this only ever fires for the local player; the check is for the
-- day this moves somewhere shared.
prompt.Triggered:Connect(function(triggeringPlayer: Player)
	if triggeringPlayer == player then
		controller:Toggle()
	end
end)

-- Walking out of range hides the prompt. Leaving the window open behind the
-- player, with no close button anywhere in the design, would strand them in it.
prompt.PromptHidden:Connect(function()
	controller:Close()
end)
