//// Biz spec §15 — update market param. A **Spend** of `config_pool_skh`, one of
//// §5 rule 16's two exceptions, so no withdrawal accompanies it.
////
//// §15.2.5 pushes the whole of §1.3 in here. Every internal bound is read off
//// the **output** datum, which is the datum that has to be consistent with
//// itself once the transaction lands; monotonicity is the only thing read across
//// the two.

use aiken/collection/list
use cardano/address
use cardano/assets.{Value}
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, ValidityRange,
}
use constants
use daken/flist
use daken/math
use daken/tokens
use daken/types.{TupleAsset} as daken_types
use protocol/utils as protocol_utils
use types.{
  LiquidationThreshold, MarketDatum, MarketParamRedeemer, ProtocolDatum,
  UpdateMarketParam,
}
use utils

/// §1.3 — `max_index_staleness` and `max_claim_duration` share this ceiling, ms.
const one_hour_ms = 3600000

/// §1.3 — the floor on `min_claim_duration`, ms.
const min_claim_duration_floor = 600000

/// §1.3 — `claim_safety_margin` and `fillability_margin` both live in
/// `[margin_floor, margin_cap]`.
const margin_floor = 50

const margin_cap = 1000

/// §1.3 — `venue_fee_budget <= min_ada × 4`.
const venue_fee_budget_min_ada_multiple = 4

// ------------------------------------------------------------------ the bound

/// §1.3 — the ceiling on `collaterals[t].liquidation_threshold`. Read off the
/// output datum's own margins, so the resulting market is consistent with
/// itself.
pub fn threshold_cap(fillability_margin: Int, claim_safety_margin: Int) -> Int {
  constants.basis_point * ( constants.basis_point - fillability_margin ) / (
    constants.basis_point + claim_safety_margin
  )
}

/// §15.2.4 + §1.3 — `collaterals` keys are append-only and never reordered, and
/// `liquidation_threshold` may only rise. A key is never removed **at all**: a
/// validator spending `market_param` sees only that UTxO and the admin NFT and
/// cannot enumerate outstanding loans. `enabled` is freely settable, which is
/// what turns a collateral off.
pub fn collaterals_appended(
  old: Pairs<TupleAsset, (LiquidationThreshold, Bool)>,
  new: Pairs<TupleAsset, (LiquidationThreshold, Bool)>,
  cap: Int,
) -> Bool {
  when old is {
    [] ->
      list.all(
        new,
        fn(entry: Pair<TupleAsset, (LiquidationThreshold, Bool)>) {
          let Pair(_, (threshold, _)) = entry
          and {
            threshold > 0,
            threshold <= cap,
          }
        },
      )
    [Pair(key, (threshold, _)), ..old_rest] ->
      when new is {
        [] -> False
        [Pair(key_out, (threshold_out, _)), ..new_rest] -> and {
            key == key_out,
            threshold_out >= threshold,
            threshold_out > 0,
            threshold_out <= cap,
            collaterals_appended(old_rest, new_rest, cap),
          }
      }
  }
}

/// §1.3 — `alt_supply_tokens` is append-only with pairwise-distinct keys:
/// `PoolDatum.alt_supply_tokens_rate` is indexed **positionally** against it, so
/// a removal rebinds every later token to its neighbour's rate.
pub fn alt_tokens_appended(
  old: Pairs<TupleAsset, Bool>,
  new: Pairs<TupleAsset, Bool>,
) -> Bool {
  and {
    keys_prefix(old, new),
    distinct_keys(list.map(new, fn(Pair(key, _)) { key })),
  }
}

fn keys_prefix(old: Pairs<TupleAsset, a>, new: Pairs<TupleAsset, a>) -> Bool {
  when old is {
    [] -> True
    [Pair(key, _), ..old_rest] ->
      when new is {
        [] -> False
        [Pair(key_out, _), ..new_rest] -> and {
            key == key_out,
            keys_prefix(old_rest, new_rest),
          }
      }
  }
}

pub fn distinct_keys(keys: List<a>) -> Bool {
  when keys is {
    [] -> True
    [key, ..rest] -> and {
        !list.has(rest, key),
        distinct_keys(rest),
      }
  }
}

/// §1.3 — `liquidator_reward_cap <= basis_point - max(T)` across **enabled**
/// keys, not over `T(a)`, whose `short_token` case is `basis_point` and would
/// force this to zero. An all-disabled market maxes at `0`, leaving the cap free
/// up to `basis_point`.
pub fn max_enabled_threshold(
  collaterals: Pairs<TupleAsset, (LiquidationThreshold, Bool)>,
) -> Int {
  list.reduce(
    collaterals,
    0,
    fn(acc: Int, entry: Pair<TupleAsset, (LiquidationThreshold, Bool)>) {
      let Pair(_, (threshold, enabled)) = entry
      if and {
        enabled,
        threshold > acc,
      } {
        threshold
      } else {
        acc
      }
    },
  )
}

/// §15.2.5 — every bound and every monotonicity rule of §1.3, between
/// `market_in_datum` and `market_out_datum`.
pub fn bounds_ok(i: MarketDatum, o: MarketDatum) -> Bool {
  let MarketDatum {
    collaterals,
    base_rate,
    power_base,
    util_cap,
    withdrawal_fee,
    loan_fee_rate,
    loan_origination_fee_rate,
    loan_origination_fee_min_amount,
    fee_address: _fee_address,
    supply_token,
    alt_supply_tokens,
    min_tx_amount,
    liquidator_reward_cap,
    collector_reward,
    min_liquidator_reward,
    rollback_tip,
    execution_tip,
    max_cancel_fee,
    venue_fee_budget,
    max_slippage_cap,
    min_claim_duration,
    max_claim_duration,
    max_index_staleness,
    claim_safety_margin,
    fillability_margin,
  } = o
  and {
    // ---------------------------------------------------------------- §15.2.4
    (supply_token == i.supply_token)?,
    collaterals_appended(
      i.collaterals,
      collaterals,
      threshold_cap(fillability_margin, claim_safety_margin),
    )?,
    alt_tokens_appended(i.alt_supply_tokens, alt_supply_tokens)?,
    // ------------------------------------------- §1.3, bounds on the new datum
    (liquidator_reward_cap <= constants.basis_point - max_enabled_threshold(
      collaterals,
    ))?,
    // The `min_liquidator_reward` ceiling and the `min_tx_amount` floor are one
    // inequality cross-multiplied, so a zero cap forces a zero reward.
    (min_liquidator_reward * constants.basis_point <= min_tx_amount * liquidator_reward_cap)?,
    // Where `supply_token` is ADA, §4's `floor > venue_fee_budget` must leave a
    // non-empty interval for the market's smallest position.
    or {
      !tokens.is_ada(supply_token),
      min_tx_amount * ( constants.basis_point - fillability_margin ) >= venue_fee_budget * constants.basis_point,
    }?,
    (loan_origination_fee_min_amount <= math.ceiling_div(
      loan_origination_fee_rate * min_tx_amount,
      constants.basis_point,
    ))?,
    (max_index_staleness <= one_hour_ms)?,
    (min_claim_duration >= min_claim_duration_floor)?,
    (min_claim_duration <= max_claim_duration)?,
    (max_claim_duration <= one_hour_ms)?,
    (claim_safety_margin >= margin_floor)?,
    (claim_safety_margin <= margin_cap)?,
    (fillability_margin >= margin_floor)?,
    (fillability_margin <= margin_cap)?,
    (max_slippage_cap >= fillability_margin)?,
    (max_slippage_cap <= constants.basis_point)?,
    // `max_cancel_fee <= venue_fee_budget - min_ada - rollback_tip` and
    // `venue_fee_budget >= max_cancel_fee + min_ada + rollback_tip` are the same
    // inequality; it is stated once.
    (max_cancel_fee + constants.min_ada + rollback_tip <= venue_fee_budget)?,
    (venue_fee_budget <= constants.min_ada * venue_fee_budget_min_ada_multiple)?,
    (rollback_tip > 0)?,
    (rollback_tip <= constants.min_ada)?,
    (execution_tip <= constants.min_ada)?,
    // §11.2.7 pins the grace arm's tip at `min_ada - collector_reward`, and no
    // output can carry zero lovelace.
    (collector_reward > 0)?,
    (collector_reward < constants.min_ada)?,
    (loan_origination_fee_rate <= constants.basis_point)?,
    (loan_fee_rate <= constants.basis_point)?,
    (withdrawal_fee <= constants.min_ada)?,
    (base_rate <= constants.basis_point)?,
    (util_cap <= constants.basis_point)?,
    (power_base > constants.basis_point)?,
    // ---------------------------------------------------- §1.3, monotone rules
    (min_liquidator_reward <= i.min_liquidator_reward)?,
    (min_tx_amount >= i.min_tx_amount)?,
    (loan_origination_fee_min_amount <= i.loan_origination_fee_min_amount)?,
    (max_index_staleness <= i.max_index_staleness)?,
    (max_claim_duration <= i.max_claim_duration)?,
    (claim_safety_margin >= i.claim_safety_margin)?,
    (fillability_margin <= i.fillability_margin)?,
    (max_cancel_fee <= i.max_cancel_fee)?,
    (execution_tip <= i.execution_tip)?,
    (venue_fee_budget <= i.venue_fee_budget)?,
  }
}

// ------------------------------------------------------------------- the spend

pub fn validate(
  protocol_nft: TupleAsset,
  redeemer: MarketParamRedeemer,
  own_ref: OutputReference,
  inputs: List<Input>,
  reference_inputs: List<Input>,
  outputs: List<Output>,
  mint: Value,
  validity_range: ValidityRange,
) -> Bool {
  // Matching one variant in a parameter is not exhaustive, so it is done here.
  expect UpdateMarketParam {
    market_in_idx,
    admin_in_idx,
    market_out_idx,
    protocol_config_ref_idx,
  } = redeemer
  // §5 rule 1. Read into names and compared: a discarded binding is lazy, so
  // the bounds would never be evaluated and the rule would not hold.
  let (tx_start, tx_end) = protocol_utils.tx_bounds(validity_range)
  expect (tx_end >= tx_start)?
  // §15.2.2 — `admin_nft` comes from a `protocol_config` reference input
  // authenticated by `protocol_nft`.
  let ProtocolDatum { config_pool_skh, admin_nft, .. } =
    protocol_utils.registry_ref(
      reference_inputs,
      protocol_config_ref_idx,
      protocol_nft,
    )
  // §5 rule 16 — the spend is authorised by `market_in_idx`, not by a withdrawal.
  let Input { output_reference, output: market_in } =
    flist.at(inputs, market_in_idx)
  expect output_reference == own_ref
  expect InlineDatum(raw_in) = market_in.datum
  expect datum_in: MarketDatum = raw_in
  let market_out = utils.output_at(outputs, market_out_idx)
  expect InlineDatum(raw_out) = market_out.datum
  expect datum_out: MarketDatum = raw_out
  and {
    // §15.2.1 — at `Script(config_pool_skh)`, holding the `MarketNFT`, quantity
    // 1. `PoolNFT` and `MarketNFT` are the same asset, so the address is what
    // separates the market from the pool — §5 rule 3.
    utils.at_script(market_in.address, config_pool_skh)?,
    tokens.contains_nft(
      market_in.value,
      (config_pool_skh, tokens.get_nft_name(market_in.value, config_pool_skh)),
    )?,
    protocol_utils.admin_authorises(inputs, admin_in_idx, admin_nft)?,
    // §15.2.3 and §15.2.6
    (market_out.value == market_in.value)?,
    protocol_utils.replaces_output(market_out, market_in)?,
    bounds_ok(datum_in, datum_out)?,
    // §5 rule 10 — this arm states no contribution to any policy.
    (assets.flatten(mint) == [])?,
  }
}

// ---------------------------------------------------------------------- tests

const ada = (#"", #"")

const token_a = (#"aa", "A")

const token_b = (#"bb", "B")

fn base() -> MarketDatum {
  MarketDatum {
    collaterals: [Pair(token_a, (8000, True))],
    base_rate: 400,
    power_base: 10470,
    util_cap: 9000,
    withdrawal_fee: 0,
    loan_fee_rate: 2000,
    loan_origination_fee_rate: 0,
    loan_origination_fee_min_amount: 0,
    fee_address: address.from_verification_key(#"00"),
    supply_token: token_b,
    alt_supply_tokens: [],
    min_tx_amount: 100000000,
    liquidator_reward_cap: 1000,
    collector_reward: 3000000,
    min_liquidator_reward: 10000000,
    rollback_tip: 3000000,
    execution_tip: 3000000,
    max_cancel_fee: 2000000,
    venue_fee_budget: 13000000,
    max_slippage_cap: 300,
    min_claim_duration: 600000,
    max_claim_duration: 600000,
    max_index_staleness: 3600000,
    claim_safety_margin: 50,
    fillability_margin: 50,
  }
}

/// One row per §1.3 rule: `moved` is the output datum with exactly one field
/// changed, and `expected` is whether §15 admits it.
type BoundCase {
  label: ByteArray,
  moved: MarketDatum,
  expected: Bool,
}

test defaults_are_admissible() {
  bounds_ok(base(), base())
}

test parameter_bounds() {
  let i = base()
  let cases =
    [
      BoundCase {
        label: "supply_token is immutable",
        moved: MarketDatum { ..i, supply_token: token_a },
        expected: False,
      },
      BoundCase {
        label: "a collateral key is never removed",
        moved: MarketDatum { ..i, collaterals: [] },
        expected: False,
      },
      BoundCase {
        label: "a collateral key may be appended",
        moved: MarketDatum {
          ..i,
          collaterals: [Pair(token_a, (8000, True)), Pair(ada, (8000, True))],
        },
        expected: True,
      },
      BoundCase {
        label: "a collateral key is never reordered",
        moved: MarketDatum {
          ..i,
          collaterals: [Pair(ada, (8000, True)), Pair(token_a, (8000, True))],
        },
        expected: False,
      },
      BoundCase {
        label: "liquidation_threshold may rise",
        moved: MarketDatum { ..i, collaterals: [Pair(token_a, (8500, True))] },
        expected: True,
      },
      BoundCase {
        label: "liquidation_threshold may not fall",
        moved: MarketDatum { ..i, collaterals: [Pair(token_a, (7999, True))] },
        expected: False,
      },
      BoundCase {
        label: "liquidation_threshold is capped by the two margins",
        moved: MarketDatum { ..i, collaterals: [Pair(token_a, (9901, True))] },
        expected: False,
      },
      BoundCase {
        label: "enabled is freely settable",
        moved: MarketDatum { ..i, collaterals: [Pair(token_a, (8000, False))] },
        expected: True,
      },
      BoundCase {
        label: "liquidator_reward_cap is capped by the largest enabled threshold",
        moved: MarketDatum { ..i, liquidator_reward_cap: 2001 },
        expected: False,
      },
      BoundCase {
        label: "min_liquidator_reward may only fall",
        moved: MarketDatum { ..i, min_liquidator_reward: 10000001 },
        expected: False,
      },
      BoundCase {
        label: "min_liquidator_reward sits exactly at its bound",
        moved: MarketDatum { ..i, min_liquidator_reward: 9999999 },
        expected: True,
      },
      BoundCase {
        label: "min_tx_amount may only rise",
        moved: MarketDatum { ..i, min_tx_amount: 99999999 },
        expected: False,
      },
      BoundCase {
        label: "loan_origination_fee_min_amount is bounded by the rate",
        moved: MarketDatum { ..i, loan_origination_fee_min_amount: 1 },
        expected: False,
      },
      BoundCase {
        label: "max_index_staleness may only fall",
        moved: MarketDatum { ..i, max_index_staleness: 3600001 },
        expected: False,
      },
      BoundCase {
        label: "min_claim_duration has a floor",
        moved: MarketDatum { ..i, min_claim_duration: 599999 },
        expected: False,
      },
      BoundCase {
        label: "max_claim_duration may only fall",
        moved: MarketDatum { ..i, max_claim_duration: 900000 },
        expected: False,
      },
      BoundCase {
        label: "min_claim_duration may not exceed max_claim_duration",
        moved: MarketDatum { ..i, min_claim_duration: 700000 },
        expected: False,
      },
      BoundCase {
        label: "claim_safety_margin may only rise",
        moved: MarketDatum { ..i, claim_safety_margin: 49 },
        expected: False,
      },
      BoundCase {
        label: "claim_safety_margin is capped",
        moved: MarketDatum { ..i, claim_safety_margin: 1001 },
        expected: False,
      },
      BoundCase {
        label: "fillability_margin may only fall",
        moved: MarketDatum { ..i, fillability_margin: 51 },
        expected: False,
      },
      BoundCase {
        label: "max_slippage_cap is floored by fillability_margin",
        moved: MarketDatum { ..i, max_slippage_cap: 49 },
        expected: False,
      },
      BoundCase {
        label: "max_cancel_fee may only fall",
        moved: MarketDatum { ..i, max_cancel_fee: 2000001 },
        expected: False,
      },
      BoundCase {
        label: "max_cancel_fee leaves room for minADA and the rollback tip",
        moved: MarketDatum { ..i, venue_fee_budget: 9999999 },
        expected: False,
      },
      BoundCase {
        label: "venue_fee_budget is capped at four minADA",
        moved: MarketDatum { ..i, venue_fee_budget: 20000001 },
        expected: False,
      },
      BoundCase {
        label: "rollback_tip is positive",
        moved: MarketDatum { ..i, rollback_tip: 0 },
        expected: False,
      },
      BoundCase {
        label: "rollback_tip is at most minADA",
        moved: MarketDatum { ..i, rollback_tip: 5000001 },
        expected: False,
      },
      BoundCase {
        label: "execution_tip may only fall",
        moved: MarketDatum { ..i, execution_tip: 3000001 },
        expected: False,
      },
      BoundCase {
        label: "collector_reward is strictly below minADA",
        moved: MarketDatum { ..i, collector_reward: 5000000 },
        expected: False,
      },
      BoundCase {
        label: "collector_reward is positive",
        moved: MarketDatum { ..i, collector_reward: 0 },
        expected: False,
      },
      BoundCase {
        label: "power_base rises with utilisation",
        moved: MarketDatum { ..i, power_base: 10000 },
        expected: False,
      },
      BoundCase {
        label: "util_cap is a basis value",
        moved: MarketDatum { ..i, util_cap: 10001 },
        expected: False,
      },
      BoundCase {
        label: "base_rate is a basis value",
        moved: MarketDatum { ..i, base_rate: 10001 },
        expected: False,
      },
      BoundCase {
        label: "loan_fee_rate is a basis value",
        moved: MarketDatum { ..i, loan_fee_rate: 10001 },
        expected: False,
      },
      BoundCase {
        label: "withdrawal_fee is at most minADA",
        moved: MarketDatum { ..i, withdrawal_fee: 5000001 },
        expected: False,
      },
      BoundCase {
        label: "an alt key may be appended",
        moved: MarketDatum { ..i, alt_supply_tokens: [Pair(token_a, False)] },
        expected: True,
      },
      BoundCase {
        label: "alt keys are pairwise distinct",
        moved: MarketDatum {
          ..i,
          alt_supply_tokens: [Pair(token_a, False), Pair(token_a, True)],
        },
        expected: False,
      },
      BoundCase {
        label: "fee_address carries no bound",
        moved: MarketDatum {
          ..i,
          fee_address: address.from_verification_key(#"11"),
        },
        expected: True,
      },
    ]
  list.all(
    cases,
    fn(BoundCase { label: _label, moved, expected }) {
      bounds_ok(i, moved) == expected
    },
  )
}

/// §1.3 — an ADA `supply_token` needs `min_tx_amount` large enough that §4's
/// `floor > venue_fee_budget` leaves the smallest position a non-empty interval.
test ada_supply_token_floors_min_tx_amount() {
  let i = MarketDatum { ..base(), supply_token: ada }
  let too_small = MarketDatum { ..i, min_tx_amount: 13000000 }
  and {
    bounds_ok(i, i),
    !bounds_ok(too_small, too_small),
  }
}

test alt_key_never_removed() {
  let i = MarketDatum { ..base(), alt_supply_tokens: [Pair(token_a, True)] }
  !bounds_ok(i, MarketDatum { ..i, alt_supply_tokens: [] })
}
