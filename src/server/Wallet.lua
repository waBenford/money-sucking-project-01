--!strict
--[[
	Wallet
	Reading and changing a player's Money, in one place.

	Money lives in player.leaderstats.Money, created by PlayerData on join and
	saved by it on leave. This module does not own that value -- it owns the
	*rules* for moving it: never below zero, never partially spent, and never
	from a number a client supplied.

	spend() is the reason this exists. Checking the balance and deducting it must
	happen with nothing yielding in between, or two purchases racing through a
	yield can both pass a check that only one of them could afford.

	BedService.creditMoney predates this and still writes leaderstats directly;
	folding it in here is a follow-up, not part of the shop work.

	Usage:
		local Wallet = require(ServerScriptService.Server.Wallet)

		if not Wallet.spend(player, price) then
			return -- could not afford it; nothing was taken
		end
]]

local Wallet = {}

-- Walks down defensively: leaderstats can be absent for a player who is still
-- loading, or whose data failed to load. Every caller treats nil as "no money"
-- rather than erroring, which turns a load failure into a refused purchase
-- instead of a broken remote.
local function findMoney(player: Player): IntValue?
	local leaderstats = player:FindFirstChild("leaderstats")
	if not leaderstats then
		return nil
	end

	local money = leaderstats:FindFirstChild("Money")
	if money and money:IsA("IntValue") then
		return money
	end

	return nil
end

function Wallet.getBalance(player: Player): number
	local money = findMoney(player)
	return money and money.Value or 0
end

-- Takes `amount` only if the whole of it is there. Returns false and changes
-- nothing otherwise -- there is no partial spend.
function Wallet.spend(player: Player, amount: number): boolean
	if amount <= 0 then
		-- A zero or negative price would be a free purchase, or a refund dressed
		-- up as one. Refuse rather than quietly succeed.
		return false
	end

	local money = findMoney(player)
	if not money then
		return false
	end

	-- Read, compare and write with nothing between them that can yield.
	local balance = money.Value
	if balance < amount then
		return false
	end

	money.Value = balance - amount
	return true
end

-- Used for refunds -- the tail of a x10 roll that had nowhere to put its items.
function Wallet.credit(player: Player, amount: number)
	if amount <= 0 then
		return
	end

	local money = findMoney(player)
	if not money then
		-- The player left mid-transaction. Nothing to credit and nowhere to put
		-- it; their session is over either way.
		return
	end

	money.Value += amount
end

return table.freeze(Wallet)
