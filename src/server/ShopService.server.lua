--!strict
--[[
	ShopService
	The server end of ReplicatedStorage.Remotes.ShopRequest: rolls, daily
	purchases, and the machine levels behind them.

	The client sends ids and counts. Prices, rates, levels and outcomes are all
	read or decided here, so there is nothing in a payload worth forging -- a
	request names *what* to do, never what it should cost or produce.

	Order matters in every path below: take the money first, then produce the
	item, then refund anything that could not be delivered. Producing first would
	mean a full bag hands out free items; refunding is the only step that can be
	skipped without losing something.

	Machine levels are per player and per machine, and they come from rolls alone.
	They live in memory, like the inventory and the bed -- this project has no
	persistence layer yet, so a server restart resets them.

	BuyProduct remains a lookup only: Developer Products are delivered by
	MarketplaceService.ProcessReceipt, sketched at the bottom of this file.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local ShopConfig = require(ReplicatedStorage.Shared.ShopConfig)
local ShopTypes = require(ReplicatedStorage.Shared.ShopTypes)
local ItemData = require(ReplicatedStorage.Shared.ItemData)

local Server = ServerScriptService:WaitForChild("Server")
local InventoryService = require(Server:WaitForChild("InventoryService"))
local Wallet = require(Server:WaitForChild("Wallet"))

-- Timed, like the client's lookups: a remote that never arrives -- because
-- `rojo serve` was started before default.project.json declared it -- would
-- otherwise leave this script yielding forever with no clue in the Output.
local Remotes = ReplicatedStorage:WaitForChild("Remotes", 10)
if not Remotes then
	warn("ShopService: ReplicatedStorage.Remotes is missing -- restart `rojo serve` so it re-reads default.project.json")
	return
end

local shopRequest = Remotes:WaitForChild("ShopRequest", 10)
if not shopRequest or not shopRequest:IsA("RemoteFunction") then
	warn("ShopService: Remotes.ShopRequest is missing or is not a RemoteFunction")
	return
end

-- Every legitimate request is behind a button a human has to click, so nothing
-- honest arrives faster than this. Rejecting rather than yielding means a
-- spammer cannot hold a server thread open either.
local REQUEST_COOLDOWN = 0.25

--// State
--
-- All keyed by Player and dropped on leave. Nothing here survives a restart.

local lastRequest: { [Player]: number } = {}

-- [player][variantId] = rolls made. Level is derived from it, never stored, so
-- the two can never disagree.
local rollCounts: { [Player]: { [string]: number } } = {}

-- [player] = { window = n, sold = { [slotId] = true } }. Reset the moment the
-- window turns over, which is what makes the stock "daily" without storing a
-- date per slot.
local dailyPurchases: { [Player]: { window: number, sold: { [string]: boolean } } } = {}

-- Its own stream, so no other script reseeding the global generator can shift
-- the drop rates -- the same reasoning as StoryData's rng.
local rng = Random.new()

--// Helpers

local function fail(reason: string): ShopTypes.FailureResponse
	return { ok = false, reason = reason }
end

local function rollsFor(player: Player, variantId: string): number
	local counts = rollCounts[player]
	return counts and counts[variantId] or 0
end

local function addRoll(player: Player, variantId: string)
	local counts = rollCounts[player]
	if not counts then
		counts = {}
		rollCounts[player] = counts
	end

	counts[variantId] = (counts[variantId] or 0) + 1
end

local function soldSlotsFor(player: Player): { [string]: boolean }
	local record = dailyPurchases[player]
	local window = ShopConfig.currentWindow()

	if not record or record.window ~= window then
		record = { window = window, sold = {} }
		dailyPurchases[player] = record
	end

	return record.sold
end

-- Picks a rarity from the machine's curve at this level, then an item of that
-- rarity. Weighted walk over the percentages, which already sum to 100.
local function rollOne(variant: ShopConfig.RollVariant, level: number): ItemData.Item?
	local rates = ShopConfig.ratesFor(variant.Id, level)

	local roll = rng:NextNumber(0, 100)
	local cumulative = 0
	local chosen = rates[#rates]

	for _, rate in ipairs(rates) do
		cumulative += rate.Chance
		if roll <= cumulative then
			chosen = rate
			break
		end
	end

	if not chosen then
		return nil
	end

	local pool = ItemData.getByRarity(variant.Category, chosen.Rarity)
	if #pool == 0 then
		-- ItemData asserts every tier is populated at startup, so this is only
		-- reachable if a catalog changes underneath a running server.
		return nil
	end

	return pool[rng:NextInteger(1, #pool)]
end

--// Actions

local function handleGetState(player: Player): ShopTypes.Response
	local variants: { [string]: ShopTypes.VariantState } = {}

	for _, variant in ipairs(ShopConfig.RollVariants) do
		local rolls = rollsFor(player, variant.Id)
		variants[variant.Id] = {
			level = ShopConfig.levelFor(variant, rolls),
			rolls = rolls,
		}
	end

	return {
		ok = true,
		variants = variants,
		soldSlots = soldSlotsFor(player),
		window = ShopConfig.currentWindow(),
	}
end

local function handleRoll(player: Player, variantId: unknown, count: unknown): ShopTypes.Response
	if type(variantId) ~= "string" or type(count) ~= "number" then
		return fail("malformed")
	end

	local variant = ShopConfig.getRollVariant(variantId)
	if not variant then
		return fail("unknown_variant")
	end

	-- An arbitrary count is the obvious exploit here: only the values the buttons
	-- can actually produce are allowed, so "roll 100000" is not a number to
	-- clamp, it is a rejection.
	if not ShopConfig.isAllowedCount(count) then
		return fail("bad_count")
	end

	-- Charged for the whole batch up front. Per-roll charging would let a player
	-- start a x10 they cannot finish and leave the shop mid-way through.
	if not Wallet.spend(player, variant.Price * count) then
		return fail("insufficient_funds")
	end

	local rolled: { string } = {}
	local refunded = 0
	local failure: string? = nil

	for _ = 1, count do
		-- Re-read the level every iteration: a x10 that crosses a level boundary
		-- should roll its later pulls at the better rates the player just earned.
		local level = ShopConfig.levelFor(variant, rollsFor(player, variantId))
		local item = rollOne(variant, level)

		local granted = false
		local reason: string? = "no_items"

		if item then
			granted, reason = InventoryService.grantItem(player, item.Id)
		end

		if granted and item then
			-- Counted only when the item actually landed, so a refunded pull
			-- never advances the machine.
			addRoll(player, variantId)
			table.insert(rolled, item.Id)
		else
			-- Nowhere to put this one: refund that single pull and keep going.
			-- Aborting the batch would let one full stack cancel the other nine,
			-- and a player watching a x10 stop after two pulls has no way to tell
			-- a refund from a robbery.
			refunded += 1
			failure = reason or "grant_failed"
		end
	end

	if refunded > 0 then
		Wallet.credit(player, variant.Price * refunded)
	end

	local rolls = rollsFor(player, variantId)

	return {
		ok = true,
		rolled = rolled,
		level = ShopConfig.levelFor(variant, rolls),
		rolls = rolls,
		stopped = failure,
	}
end

local function handleBuyDaily(player: Player, slotId: unknown): ShopTypes.Response
	if type(slotId) ~= "string" then
		return fail("malformed")
	end

	local sold = soldSlotsFor(player)
	if sold[slotId] then
		return fail("already_bought")
	end

	-- Recomputed here rather than trusted: the client sends which slot, never
	-- what is in it or what it costs. A slot from yesterday's rotation simply
	-- does not match anything on sale now.
	local entry: ShopConfig.DailyEntry? = nil
	for _, candidate in ipairs(ShopConfig.dailyStock()) do
		if candidate.SlotId == slotId then
			entry = candidate
			break
		end
	end

	if not entry then
		return fail("stock_expired")
	end

	if not Wallet.spend(player, entry.Price) then
		return fail("insufficient_funds")
	end

	local granted, reason = InventoryService.grantItem(player, entry.ItemId)
	if not granted then
		Wallet.credit(player, entry.Price)
		return fail(reason or "grant_failed")
	end

	-- Marked only after delivery, so a failed grant leaves the slot buyable.
	sold[slotId] = true

	return {
		ok = true,
		rolled = { entry.ItemId },
		soldSlots = sold,
	}
end

local function handleBuyProduct(player: Player, productId: unknown, quantity: unknown): ShopTypes.Response
	if type(productId) ~= "string" or type(quantity) ~= "number" then
		return fail("malformed")
	end

	local product = ShopConfig.getProduct(productId)
	if not product then
		return fail("unknown_product")
	end

	if not ShopConfig.isAllowedCount(quantity) then
		return fail("bad_quantity")
	end

	-- TODO: implement in ShopService -- a real product carries one Roblox
	-- Developer Product id per quantity, so the pair (productId, quantity)
	-- should resolve to a distinct id here rather than reusing one.
	if product.RobloxProductId <= 0 then
		return fail("product_not_configured")
	end

	return { ok = true, robloxProductId = product.RobloxProductId }
end

--// Handler

-- `player` is supplied by the engine, not by the caller, so there is no id to
-- forge: a client can only ever act as itself. `payload` is the opposite -- it is
-- entirely client-authored, so every field is narrowed before it is believed.
-- `any` rather than `unknown` because OnServerInvoke's own type is variadic and
-- would reject a stricter signature.
local function onServerInvoke(player: Player, payload: any): ShopTypes.Response
	local now = os.clock()
	local last = lastRequest[player]

	if last and now - last < REQUEST_COOLDOWN then
		return fail("rate_limited")
	end

	lastRequest[player] = now

	if type(payload) ~= "table" then
		return fail("malformed")
	end

	local request = payload :: { [string]: unknown }
	local action = request.action

	if action == "GetState" then
		return handleGetState(player)
	elseif action == "Roll" then
		return handleRoll(player, request.variantId, request.count)
	elseif action == "BuyDaily" then
		return handleBuyDaily(player, request.slotId)
	elseif action == "BuyProduct" then
		return handleBuyProduct(player, request.productId, request.quantity)
	end

	return fail("unknown_action")
end

shopRequest.OnServerInvoke = onServerInvoke

Players.PlayerRemoving:Connect(function(player: Player)
	lastRequest[player] = nil
	rollCounts[player] = nil
	dailyPurchases[player] = nil
end)

--// TODO: implement in ShopService -- purchase delivery
--
-- MarketplaceService.ProcessReceipt is deliberately left unassigned: an empty
-- handler that returned PurchaseGranted would take Robux and deliver nothing,
-- which is worse than the current behaviour (Roblox retries an unhandled receipt
-- and refunds if it is never granted).
--
-- The real one belongs here, assigned exactly once for the whole server:
--
--   MarketplaceService.ProcessReceipt = function(receipt)
--       -- 1. map receipt.ProductId back to a ShopConfig product; unknown ids
--       --    must return NotProcessedYet, never Granted
--       -- 2. reject a receipt whose PurchaseId this player has already been
--       --    granted -- store the PurchaseId with the grant, in one DataStore
--       --    write, or a retry pays out twice
--       -- 3. the player may have left: return NotProcessedYet so Roblox retries
--       --    rather than losing the purchase
--       -- 4. grant through InventoryService, then persist, then return
--       --    Enum.ProductPurchaseDecision.PurchaseGranted
--   end
