//// The market parameters `releases/src/market.ts` writes, checked against §1.3
//// and against the set the live registry was created with.
////
//// This module exists because those two are no longer the same record.
//// `t_preprod_market()` in `protocol/create_market.ak` used to be the deployer's
//// twin, and it still holds the values the live markets opened with —
//// deliberately, because every validator hash is a compile-time function of its
//// own source and nothing in `lib/` may move while that registry is the one in
//// use. So the fixture describes what is deployed and this module describes what
//// the deployer writes next.
////
//// The five charges that change are all **datum** fields, which is what makes
//// the change possible at all: §15 rewrites them on a market that is already
//// open, and §1.3's monotone rules let each of them fall and never rise. The
//// test that matters here is therefore not self-consistency but the
//// **transition** — `bounds_ok(deployed, proposed)` — which the old fixture,
//// checking itself against itself, could not express.

use cardano/address
use constants
use order/utils as order_utils
use protocol/market_param
use types.{MarketDatum}

/// A bare wallet output with a stake credential serialises to 85 bytes, so the
/// ledger wants `(160 + 85) * 4310` lovelace for one. Three amounts in a market
/// datum are paid as an **equality** rather than a floor and so are each a
/// minADA in their own right: `execution_tip` (order/execute.ak),
/// `rollback_tip` (loan/rollback.ak), and `min_ada - collector_reward`, the
/// grace tip of §11.2.7 (loan/liquidate.ak).
const bare_output_min_ada = 1_055_950

/// Minswap V2's batcher fee, which `adapter_minswap.ak:409` requires
/// `venue_fee_budget` to hold on top of `max_cancel_fee + min_ada +
/// rollback_tip`.
const minswap_batcher_fee = 2_000_000

const fusdm = (#"834a15101873b4e1ddfaa830df46792913995d8738dcde34eda27905", #"665553444d")

/// The ADA market as §2 of DEPLOYMENT.md records it: ADA lent, fUSDM the one
/// accepted collateral.
fn deployed() -> MarketDatum {
  MarketDatum {
    collaterals: [Pair(fusdm, (8000, True))],
    base_rate: 400,
    power_base: 10470,
    util_cap: 8000,
    withdrawal_fee: 0,
    loan_fee_rate: 2000,
    loan_origination_fee_rate: 100,
    loan_origination_fee_min_amount: 0,
    fee_address: address.from_verification_key(#"00"),
    supply_token: (#"", #""),
    alt_supply_tokens: [],
    min_tx_amount: 100_000_000,
    liquidator_reward_cap: 1000,
    collector_reward: 3_000_000,
    min_liquidator_reward: 10_000_000,
    rollback_tip: 3_000_000,
    execution_tip: 3_000_000,
    max_cancel_fee: 2_000_000,
    venue_fee_budget: 20_000_000,
    max_slippage_cap: 300,
    min_claim_duration: 600_000,
    max_claim_duration: 600_000,
    max_index_staleness: 3_600_000,
    claim_safety_margin: 50,
    fillability_margin: 50,
  }
}

/// The five charges `releases/src/market.ts` now writes. Nothing else moves.
fn proposed() -> MarketDatum {
  MarketDatum {
    ..deployed(),
    collector_reward: 1_200_000,
    rollback_tip: 1_100_000,
    execution_tip: 1_100_000,
    max_cancel_fee: 200_000,
    venue_fee_budget: 8_400_000,
  }
}

/// What a trader fronts to place a market order — §6.2.2.13 ties `fee_reserve`
/// to this, and `ORDER.feeReserve` in `releases/src/market.ts` must equal it.
test proposed_fee_reserve_is_nineteen_and_a_half_ada() {
  let m = proposed()
  and {
    (order_utils.async_fill_cost(m.venue_fee_budget, m.execution_tip) == 19_500_000)?,
    // Down from 33 ADA, which is what the deployed set gives.
    (order_utils.async_fill_cost(
      deployed().venue_fee_budget,
      deployed().execution_tip,
    ) == 33_000_000)?,
  }
}

/// The floor, with `min_ada` where it is. Substituting §1.3's
/// `venue_fee_budget >= max_cancel_fee + min_ada + rollback_tip` and
/// `adapter_minswap`'s batcher term into `async_fill_cost` collapses the whole
/// thing to one inequality:
///
/// ```
/// fee_reserve >= batcher_fee + max_cancel_fee + 3 x min_ada
///                           + rollback_tip + execution_tip
/// ```
///
/// At a zero cancel fee and both tips at the ledger's own minimum that is
/// 19_111_900. The proposed set sits 388 100 above it, and no choice of
/// parameters goes lower: `min_ada` is multiplied by **three** — once for the
/// venue order and twice for the loan and position a fill creates — and it is a
/// compile-time constant, not a datum field.
test nineteen_ada_is_the_floor_while_min_ada_is_five() {
  let floor =
    minswap_batcher_fee + 3 * constants.min_ada + 2 * bare_output_min_ada
  let m = proposed()
  let reserve =
    order_utils.async_fill_cost(m.venue_fee_budget, m.execution_tip)
  and {
    (floor == 19_111_900)?,
    (reserve >= floor)?,
    (reserve - floor == 388_100)?,
  }
}

/// §15.2.5 — the whole of §1.3 on the new datum, and every monotone rule between
/// the two. This is the test the old self-check could not be: it says the live
/// markets can actually be moved to these numbers, not merely that the numbers
/// are internally consistent.
test proposed_is_a_legal_transition_from_what_is_deployed() {
  and {
    market_param.bounds_ok(deployed(), deployed())?,
    market_param.bounds_ok(proposed(), proposed())?,
    market_param.bounds_ok(deployed(), proposed())?,
  }
}

/// And it is one-way. `venue_fee_budget`, `execution_tip` and `max_cancel_fee`
/// may only fall, so the reverse transition is barred — which is the property
/// that makes lowering a fee safe to do on a live market and raising one
/// impossible without a new one.
test the_reverse_transition_is_barred() {
  !market_param.bounds_ok(proposed(), deployed())
}

/// The three amounts §1.3 does not bound but the ledger does. Each is paid to an
/// output whose lovelace the validator fixes by **equality**, so a value below
/// the ledger's own minimum makes the arm unbuildable rather than merely
/// unattractive — and `aiken check` would not notice.
test the_amounts_paid_as_equalities_clear_the_ledgers_minimum() {
  let m = proposed()
  and {
    (m.execution_tip >= bare_output_min_ada)?,
    (m.rollback_tip >= bare_output_min_ada)?,
    // §11.2.7 pins the grace tip at exactly this difference.
    (constants.min_ada - m.collector_reward >= bare_output_min_ada)?,
  }
}

/// `adapter_minswap.ak:409` — `max_batcher_fee <= venue_fee_budget -
/// max_cancel_fee - min_ada - rollback_tip`. §1.3 knows nothing about the venue,
/// so a budget that satisfies §1.3 and leaves the batcher nothing would pass
/// `bounds_ok` and then fail every asynchronous fill.
test the_budget_still_holds_minswaps_batcher_fee() {
  let m = proposed()
  let headroom =
    m.venue_fee_budget - m.max_cancel_fee - constants.min_ada - m.rollback_tip
  and {
    (headroom >= minswap_batcher_fee)?,
    (headroom == 2_100_000)?,
  }
}

/// §1.3's `venue_fee_budget <= min_ada * 4`, in isolation. `parameter_bounds` in
/// `protocol/market_param.ak` cannot reach this bound: the monotone rule
/// `venue_fee_budget <= i.venue_fee_budget` fires first on any value above the
/// fixture's own. Passing a datum whose budget is already at the cap is what
/// separates the two rules.
test venue_fee_budget_is_capped_at_four_min_ada() {
  let cap = constants.min_ada * 4
  let at_cap = MarketDatum { ..deployed(), venue_fee_budget: cap }
  let over_cap = MarketDatum { ..deployed(), venue_fee_budget: cap + 1 }
  and {
    market_param.bounds_ok(at_cap, at_cap)?,
    (!market_param.bounds_ok(over_cap, over_cap))?,
  }
}

/// And its floor, `max_cancel_fee + min_ada + rollback_tip <= venue_fee_budget`,
/// also in isolation — 6 300 000 at the proposed charges.
test venue_fee_budget_leaves_room_for_min_ada_and_the_tip() {
  let m = proposed()
  let floor = m.max_cancel_fee + constants.min_ada + m.rollback_tip
  let at_floor = MarketDatum { ..m, venue_fee_budget: floor }
  let below = MarketDatum { ..m, venue_fee_budget: floor - 1 }
  and {
    (floor == 6_300_000)?,
    market_param.bounds_ok(at_floor, at_floor)?,
    (!market_param.bounds_ok(below, below))?,
  }
}
