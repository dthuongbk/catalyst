//// Biz spec §20 — create a market and its pool. `market_param`'s `Mint`, and the
//// second of §5 rule 16's two exceptions: the admin NFT authorises it, so no
//// withdrawal accompanies it.
////
//// §1.3 is not restated here. `market_param.bounds_ok` reads every internal
//// bound off its second argument and uses the first only for monotonicity and the
//// append-only rules, so passing the new datum as both checks the whole of §1.3
//// against itself while leaving monotonicity trivially satisfied — which is what
//// creation means. It also gives §20.2.6's distinct `alt_supply_tokens` keys and
//// §20.2.7's threshold bounds, since `collaterals_appended` checks every entry.

use aiken/collection/list
use cardano/assets.{Value}
use cardano/transaction.{InlineDatum, Input, Output, ValidityRange}
use constants
use daken/input_hash
use daken/prational.{PRational}
use daken/types.{TupleAsset} as daken_types
use pool/utils as pool_utils
use protocol/market_param
use protocol/utils as protocol_utils
use types.{MarketDatum, PoolDatum, ProtocolDatum}
use utils

pub fn validate(
  protocol_nft: TupleAsset,
  seed_utxo_idx: Int,
  admin_in_idx: Int,
  market_out_idx: Int,
  pool_out_idx: Int,
  protocol_config_ref_idx: Int,
  inputs: List<Input>,
  reference_inputs: List<Input>,
  outputs: List<Output>,
  mint: Value,
  validity_range: ValidityRange,
) -> Bool {
  let (tx_start, _tx_end) = protocol_utils.tx_bounds(validity_range)
  let ProtocolDatum {
    config_pool_skh,
    pool_skh,
    loan_skh,
    order_skh,
    position_skh,
    admin_nft,
    ..
  } =
    protocol_utils.registry_ref(
      reference_inputs,
      protocol_config_ref_idx,
      protocol_nft,
    )

  // §20.2.2 — an output reference is spent once, so no two markets can share a
  // name and the admin cannot choose one.
  let nft_name = input_hash.blake2b_224(utils.input_at(inputs, seed_utxo_idx))
  let nft = (config_pool_skh, nft_name)

  let market_out = utils.output_at(outputs, market_out_idx)
  let pool_out = utils.output_at(outputs, pool_out_idx)
  expect InlineDatum(raw_market) = market_out.datum
  expect market: MarketDatum = raw_market
  expect InlineDatum(raw_pool) = pool_out.datum
  expect pool: PoolDatum = raw_pool

  and {
    // §20.2.1
    protocol_utils.admin_authorises(inputs, admin_in_idx, admin_nft)?,
    // §20.2.3 — two of one asset, so one transaction creates one market
    (utils.mint_of(mint, config_pool_skh) == [(nft_name, 2)])?,
    // §20.2.9
    (utils.mint_of(mint, loan_skh) == [])?,
    (utils.mint_of(mint, order_skh) == [])?,
    (utils.mint_of(mint, position_skh) == [])?,
    (utils.mint_of(mint, pool_skh) == [])?,
    // §20.2.4 — the `PoolNFT` and the `MarketNFT` are the same asset in quantity
    // 2, so the two addresses are what tell the UTxOs apart
    utils.at_script(market_out.address, config_pool_skh)?,
    utils.at_script(pool_out.address, pool_skh)?,
    (market_out.reference_script == None)?,
    (pool_out.reference_script == None)?,
    opens_holding_only(market_out.value, nft)?,
    opens_holding_only(pool_out.value, nft)?,
    // §20.2.7 — an empty market can never open a loan, and §15.2.4 makes the
    // keys append-only, so nothing forces one to ever be added
    (market.collaterals != [])?,
    market_param.distinct_keys(
      list.map(market.collaterals, fn(Pair(key, _)) { key }),
    )?,
    // §20.2.6 — the supply token is not also an alt token, or the pool would
    // carry one balance counted on both sides of §7.2.18
    !list.has(
      list.map(market.alt_supply_tokens, fn(Pair(key, _)) { key }),
      market.supply_token,
    )?,
    // §20.2.6 — the whole of §1.3, read against itself
    market_param.bounds_ok(market, market)?,
    // §20.2.8
    opens_empty(pool, market, tx_start)?,
  }
}

/// §20.2.4 and §20.2.5 — the NFT at quantity 1, lovelace at or above `min_ada`,
/// and no other asset. A market that opened holding tokens would credit them to
/// nobody: `total_supply` is zero.
fn opens_holding_only(v: Value, (pid, name): TupleAsset) -> Bool {
  and {
    utils.holds_only(v, [(pid, name), (#"", #"")])?,
    (assets.quantity_of(v, pid, name) == 1)?,
    (assets.lovelace_of(v) >= constants.min_ada)?,
  }
}

/// §20.2.8 — the opening state and nothing else. `bad_debt` is not in Float
/// lending's pool datum; left free a market could open already carrying a loss.
fn opens_empty(p: PoolDatum, m: MarketDatum, tx_start: Int) -> Bool {
  and {
    (p.total_supply == 0)?,
    (p.circulating_dtoken == 0)?,
    (p.total_borrow == 0)?,
    (p.undistributed_fee == 0)?,
    (p.bad_debt == 0)?,
    (p.interest_index == constants.initial_interest_index)?,
    (p.interest_time == tx_start)?,
    (p.borrow_apy == m.base_rate)?,
    (p.alt_supply_tokens_rate == list.map(
      m.alt_supply_tokens,
      fn(_) { PRational(0, 1) },
    ))?,
  }
}

// ---------------------------------------------------------------------- tests

const t_policy = #"99999999999999999999999999999999999999999999999999999999"

const t_name = #"1234567890123456789012345678901234567890123456789012345678"

const t_other = #"88888888888888888888888888888888888888888888888888888888"

fn t_pool(m: MarketDatum) -> PoolDatum {
  PoolDatum {
    total_supply: 0,
    circulating_dtoken: 0,
    total_borrow: 0,
    borrow_apy: m.base_rate,
    undistributed_fee: 0,
    interest_index: constants.initial_interest_index,
    interest_time: 1000,
    alt_supply_tokens_rate: list.map(
      m.alt_supply_tokens,
      fn(_) { PRational(0, 1) },
    ),
    bad_debt: 0,
  }
}

type PoolCase {
  label: ByteArray,
  pool: PoolDatum,
  ok: Bool,
}

/// §20.2.8 — one row per `PoolDatum` field, so a field added later without an
/// opening value shows up here rather than as a market that opens mid-life.
test the_pool_opens_empty_and_nothing_else() {
  let m = pool_utils.t_market(0, 8000, True)
  let base = t_pool(m)
  let cases =
    [
      PoolCase { label: "the opening state", pool: base, ok: True },
      PoolCase {
        label: "total_supply",
        pool: PoolDatum { ..base, total_supply: 1 },
        ok: False,
      },
      PoolCase {
        label: "circulating_dtoken",
        pool: PoolDatum { ..base, circulating_dtoken: 1 },
        ok: False,
      },
      PoolCase {
        label: "total_borrow",
        pool: PoolDatum { ..base, total_borrow: 1 },
        ok: False,
      },
      PoolCase {
        label: "undistributed_fee",
        pool: PoolDatum { ..base, undistributed_fee: 1 },
        ok: False,
      },
      PoolCase {
        label: "bad_debt",
        pool: PoolDatum { ..base, bad_debt: 1 },
        ok: False,
      },
      PoolCase {
        label: "interest_index",
        pool: PoolDatum { ..base, interest_index: 1 },
        ok: False,
      },
      PoolCase {
        label: "interest_time",
        pool: PoolDatum { ..base, interest_time: 999 },
        ok: False,
      },
      PoolCase {
        label: "borrow_apy",
        pool: PoolDatum { ..base, borrow_apy: m.base_rate + 1 },
        ok: False,
      },
      PoolCase {
        label: "alt_supply_tokens_rate length",
        pool: PoolDatum { ..base, alt_supply_tokens_rate: [] },
        ok: False,
      },
      PoolCase {
        label: "alt_supply_tokens_rate value",
        pool: PoolDatum { ..base, alt_supply_tokens_rate: [PRational(1, 1)] },
        ok: False,
      },
    ]
  and {
    (list.length(cases) == 11)?,
    list.all(cases, fn(c) { (opens_empty(c.pool, m, 1000) == c.ok)? })?,
  }
}

type ValueCase {
  label: ByteArray,
  value: Value,
  ok: Bool,
}

/// §20.2.4 and §20.2.5.
test the_outputs_hold_the_nft_and_lovelace_only() {
  let good =
    assets.from_lovelace(constants.min_ada)
      |> assets.add(t_policy, t_name, 1)
  let cases =
    [
      ValueCase { label: "nft and min_ada", value: good, ok: True },
      ValueCase {
        label: "more lovelace is fine",
        value: good |> assets.add(#"", #"", 1),
        ok: True,
      },
      ValueCase {
        label: "quantity 2",
        value: assets.from_lovelace(constants.min_ada)
          |> assets.add(t_policy, t_name, 2),
        ok: False,
      },
      ValueCase {
        label: "an extra asset",
        value: good |> assets.add(t_other, t_name, 5),
        ok: False,
      },
      ValueCase {
        label: "a second name of the same policy",
        value: good |> assets.add(t_policy, t_other, 1),
        ok: False,
      },
      ValueCase {
        label: "lovelace below min_ada",
        value: assets.from_lovelace(constants.min_ada - 1)
          |> assets.add(t_policy, t_name, 1),
        ok: False,
      },
      ValueCase {
        label: "no nft at all",
        value: assets.from_lovelace(constants.min_ada),
        ok: False,
      },
    ]
  list.all(
    cases,
    fn(c) { (opens_holding_only(c.value, (t_policy, t_name)) == c.ok)? },
  )
}

/// The market the deployer writes on preprod: ADA lent, fUSDM accepted as
/// collateral. Its twin is `releases/src/market.ts`; the numbers must match, and
/// this test is what proves they clear §1.3 before any of them reaches a chain.
fn t_preprod_market() -> MarketDatum {
  MarketDatum {
    collaterals: [
      Pair(
        (
          #"834a15101873b4e1ddfaa830df46792913995d8738dcde34eda27905",
          #"665553444d",
        ),
        (8000, True),
      ),
    ],
    base_rate: 400,
    power_base: 10470,
    util_cap: 8000,
    withdrawal_fee: 0,
    loan_fee_rate: 2000,
    loan_origination_fee_rate: 100,
    loan_origination_fee_min_amount: 0,
    fee_address: pool_utils.t_wallet_address(),
    supply_token: (#"", #""),
    alt_supply_tokens: [],
    min_tx_amount: 100000000,
    liquidator_reward_cap: 1000,
    collector_reward: 3000000,
    min_liquidator_reward: 10000000,
    rollback_tip: 3000000,
    execution_tip: 3000000,
    max_cancel_fee: 2000000,
    venue_fee_budget: 20000000,
    max_slippage_cap: 300,
    min_claim_duration: 600000,
    max_claim_duration: 600000,
    max_index_staleness: 3600000,
    claim_safety_margin: 50,
    fillability_margin: 50,
  }
}

test the_preprod_market_clears_every_bound() {
  let m = t_preprod_market()
  and {
    market_param.bounds_ok(m, m)?,
    // §20.2.7 and §20.2.6, which `bounds_ok` does not cover
    (m.collaterals != [])?,
    !list.has(
      list.map(m.alt_supply_tokens, fn(Pair(key, _)) { key }),
      m.supply_token,
    )?,
  }
}

/// The pool datum that opens beside it.
test the_preprod_pool_opens_empty() {
  let m = t_preprod_market()
  opens_empty(t_pool(m), m, 1000)
}
