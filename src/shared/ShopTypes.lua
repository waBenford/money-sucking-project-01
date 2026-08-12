--!strict
--[[
	ShopTypes
	The shape of everything that crosses ReplicatedStorage.Remotes.ShopRequest,
	written once and required by both sides. A copy per side would drift, and the
	first symptom would be a silently ignored field.

	Types only -- no logic, nothing to call. Require it for the `export type`s:

		local ShopTypes = require(ReplicatedStorage.Shared.ShopTypes)
		local request: ShopTypes.Request = { action = "Roll", variantId = id, count = 1 }

	Every request carries ids and counts, never prices, levels or outcomes: the
	client asks, the server decides. A roll's rates come from the machine level
	the *server* holds, so a forged level in a payload has nothing to attach to --
	which is why there is no field for one.

	The success side is one table with optional fields rather than a union per
	action. Narrowing a union through a RemoteFunction boundary buys nothing when
	the caller already knows which action it sent.
]]

local ShopTypes = {}

export type Action = "GetState" | "Roll" | "BuyDaily" | "BuyProduct"

-- Everything the shop needs to draw itself on open: machine levels, and which of
-- today's daily slots this player has already bought.
export type GetStateRequest = {
	action: "GetState",
}

export type RollRequest = {
	action: "Roll",
	variantId: string,
	count: number, -- must be one of ShopConfig.ROLL_COUNTS
}

-- Daily is a shop, not a giveaway: this spends money like any other purchase.
export type BuyDailyRequest = {
	action: "BuyDaily",
	slotId: string,
}

export type BuyProductRequest = {
	action: "BuyProduct",
	productId: string,
	quantity: number,
}

export type Request = GetStateRequest | RollRequest | BuyDailyRequest | BuyProductRequest

-- Level is derived from rolls, but both are sent: the client draws the bar from
-- the raw count and would otherwise have to duplicate the arithmetic.
export type VariantState = {
	level: number,
	rolls: number,
}

export type SuccessResponse = {
	ok: true,

	-- GetState
	variants: { [string]: VariantState }?,
	soldSlots: { [string]: boolean }?,
	window: number?,

	-- Roll: the ids that were granted, in order, plus the machine's state after.
	-- `stopped` names why at least one pull could not be delivered -- a full
	-- stack or a full category, typically. Those pulls were refunded
	-- individually; the rest of the batch still rolled, so `rolled` can be
	-- shorter than the count that was asked for.
	rolled: { string }?,
	level: number?,
	rolls: number?,
	stopped: string?,

	-- BuyProduct: what to hand MarketplaceService:PromptProductPurchase. The
	-- server answering with an id is permission to prompt, not proof of a
	-- purchase -- the grant happens later, in ProcessReceipt.
	robloxProductId: number?,
}

-- reason is a stable machine-readable code ("rate_limited", "insufficient_funds"),
-- not display text: the client decides what a player reads.
export type FailureResponse = {
	ok: false,
	reason: string,
}

export type Response = SuccessResponse | FailureResponse

return table.freeze(ShopTypes)
