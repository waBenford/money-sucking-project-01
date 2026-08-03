--[[
	Sprint
	Hold LeftShift to accelerate to sprint speed; release to ease back down.
	Releasing always returns the player to normal speed, so they can never get
	stuck sprinting.

	Only one speed tween is ever alive at a time -- see stopActiveTween below.
]]

--// Services

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

--// Configuration

local WALK_SPEED = 14
local SPRINT_SPEED = 28
local SPRINT_KEY = Enum.KeyCode.LeftShift

-- Out rather than InOut so the speed responds the instant the key goes down
-- and decelerates into the target, which reads as acceleration.
local TWEEN_INFO = TweenInfo.new(1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

--// State

local player = Players.LocalPlayer

-- The one in-flight speed tween, if any. Sprint has a single target at a time,
-- so a single slot is all the bookkeeping this needs.
local activeTween = nil

--// Helpers

-- Read the Humanoid fresh every time instead of caching it: the character is
-- replaced on each respawn, so a cached Humanoid would go stale the first time
-- the player dies. FindFirstChildOfClass rather than WaitForChild because this
-- is called from input callbacks, which must not yield.
local function getHumanoid()
	local character = player.Character
	return character and character:FindFirstChildOfClass("Humanoid")
end

-- Ends the current tween, if there is one. Cancel leaves WalkSpeed at whatever
-- value it had reached rather than snapping it back, which is what lets the
-- next tween pick up smoothly from mid-ramp. Destroy then releases the tween's
-- reference to the Humanoid so it can be collected.
local function stopActiveTween()
	if activeTween then
		activeTween:Cancel()
		activeTween:Destroy()
		activeTween = nil
	end
end

local function tweenWalkSpeedTo(targetSpeed)
	-- Always first: even with no Humanoid to animate, a stale tween must not
	-- outlive this call, or rapid presses would stack overlapping tweens.
	stopActiveTween()

	local humanoid = getHumanoid()
	if not humanoid then
		return
	end

	activeTween = TweenService:Create(humanoid, TWEEN_INFO, { WalkSpeed = targetSpeed })
	activeTween:Play()
end

--// Input

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	-- Ignore Shift that the game already consumed -- typing in chat, or a UI
	-- element that has focus.
	if gameProcessed then
		return
	end

	if input.KeyCode == SPRINT_KEY then
		tweenWalkSpeedTo(SPRINT_SPEED)
	end
end)

UserInputService.InputEnded:Connect(function(input)
	-- No gameProcessed check here on purpose. If the player holds Shift, clicks
	-- into the chat box and then lets go, the release arrives flagged as
	-- game-processed -- skipping it would leave them sprinting forever.
	if input.KeyCode == SPRINT_KEY then
		tweenWalkSpeedTo(WALK_SPEED)
	end
end)

--// Lifecycle

player.CharacterAdded:Connect(function(character)
	-- Any tween still running points at the previous Humanoid, which is now
	-- being discarded. Drop it before it keeps that character alive.
	stopActiveTween()

	local humanoid = character:WaitForChild("Humanoid")
	humanoid.WalkSpeed = WALK_SPEED
end)
