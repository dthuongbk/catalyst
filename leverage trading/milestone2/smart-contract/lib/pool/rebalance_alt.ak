//// The admin moves pool value between `supply_token` and the alternative
//// supply tokens the market permits — biz spec §17. The only redeemer that may
//// lower an alt holding.

use aiken/collection/list
use aiken/math
use cardano/address.{Address, Script}
use cardano/assets.{PolicyId, Value}
use cardano/transaction.{Input, Output, ValidityRange}
use constants
use daken/prational.{PRational}
use daken/types.{Redeemers, TupleAsset} as daken_types
use pool/utils as pool_utils
use types.{AdapterEntry, MarketDatum, PoolDatum, ScriptHash}
use utils

pub fn validate(
  // script context
  pool_skh: PolicyId,
  config_pool_skh: PolicyId,
  loan_skh: PolicyId,
  order_skh: PolicyId,
  position_skh: PolicyId,
  oracle_skh: ByteArray,
  admin_nft: TupleAsset,
  adapters: Pairs<ScriptHash, AdapterEntry>,
  // indexers
  pool_in_idx: Int,
  pool_out_idx: Int,
  admin_in_idx: Int,
  market_ref_idx: Int,
  // transaction context
  inputs: List<Input>,
  outputs: List<Output>,
  reference_inputs: List<Input>,
  redeemers: Redeemers,
  mint: Value,
  validity_range: ValidityRange,
) -> Bool {
  let tx_start = pool_utils.tx_start_of(validity_range)
  // §17.1
  let (market_nft_name, market) =
    pool_utils.market_ref(reference_inputs, market_ref_idx, config_pool_skh)
  let MarketDatum { supply_token, alt_supply_tokens, loan_fee_rate, .. } =
    market
  // §17.2
  expect pool_utils.admin_input(inputs, admin_in_idx, pool_in_idx, admin_nft)
  let (pool_in_addr, pool_in_value, pool_in_datum) =
    pool_utils.pool_input(
      inputs,
      pool_in_idx,
      pool_skh,
      config_pool_skh,
      market_nft_name,
    )
  let PoolDatum {
    total_supply: in_total_supply,
    circulating_dtoken: in_circulating_dtoken,
    total_borrow: in_total_borrow,
    borrow_apy: in_borrow_apy,
    undistributed_fee: in_undistributed_fee,
    interest_index: in_interest_index,
    interest_time: in_interest_time,
    alt_supply_tokens_rate: in_alt_rates,
    bad_debt: in_bad_debt,
  } = pool_in_datum

  let out_interest_index =
    pool_utils.index_at(
      in_interest_index,
      in_borrow_apy,
      in_interest_time,
      tx_start,
    )
  let accrued =
    pool_utils.accrued(in_total_borrow, in_interest_index, out_interest_index)
  let accrued_fee = pool_utils.accrued_fee(accrued, loan_fee_rate)

  let pool_out = utils.output_at(outputs, pool_out_idx)
  // §17.3 — an unquoted key the pool holds on either side fails the arm.
  let pa =
    pool_utils.pool_assets(
      pool_in_value,
      pool_out.value,
      supply_token,
      alt_supply_tokens,
      in_alt_rates,
      pool_utils.prices_to(redeemers, oracle_skh, supply_token),
    )
  let total_supply_before_tx =
    pool_utils.total_supply_before_tx(
      in_total_supply,
      accrued,
      accrued_fee,
      pa.alt_tokens_yield,
    )

  // §17.8, §17.9
  let total_supply =
    math.max(0, total_supply_before_tx + pa.pool_changed_amount)
  let total_borrow = math.max(0, in_total_borrow + accrued)
  let expected =
    PoolDatum {
      total_supply,
      circulating_dtoken: in_circulating_dtoken,
      total_borrow,
      // §17.10 — the denominator is the supply **before** `pool_changed_amount`,
      // which is §17's alone.
      borrow_apy: pool_utils.borrow_apy(
        market.base_rate,
        market.power_base,
        total_supply_before_tx,
        total_borrow,
      ),
      undistributed_fee: in_undistributed_fee + accrued_fee,
      interest_index: out_interest_index,
      interest_time: math.max(tx_start, in_interest_time),
      alt_supply_tokens_rate: pa.out_alt_rates,
      bad_debt: in_bad_debt,
    }
  and {
    // §17.4
    (pa.pool_changed_amount >= 0)?,
    // §17.12a
    pool_utils.pool_out_holds_min_ada(pool_out.value),
    // §17.13 — a remain-collateral UTxO also lives at `Script(loan_skh)`.
    pool_utils.no_utxo_at(
      inputs |> list.map(fn(Input { output, .. }) { output }),
      [loan_skh, order_skh, position_skh],
    )?,
    pool_utils.no_utxo_at(outputs, [loan_skh, order_skh, position_skh])?,
    pool_utils.no_mint_of(
      mint,
      [loan_skh, order_skh, position_skh, config_pool_skh],
    ),
    pool_utils.no_adapter_withdrawal(redeemers, adapters)?,
    // §17.5 — exempt from §7.2.18's per-key lower bound, and from it alone; the
    // disabled-key rule of §17.6 and the whitelist of §17.7 still hold.
    pool_utils.check_pool_out(
      pool_in_addr,
      pool_in_value,
      pool_out,
      config_pool_skh,
      market_nft_name,
      supply_token,
      alt_supply_tokens,
      pa,
      pool_utils.AltFree,
      expected,
    ),
  }
}

// ------------------------------------------------------------------ tests

/// One scenario's knobs. The pool's `interest_time` equals `tx_start`, so
/// `accrued` is zero and each case asserts §17's own equations. `alt` is quoted
/// at 3/2 by `pool_utils.t_oracle_redeemers`.
type Rebal {
  name: ByteArray,
  in_total_supply: Int,
  in_usdm: Int,
  out_usdm: Int,
  in_alt: Int,
  out_alt: Int,
  in_rates: List<PRational>,
  out_rates: List<PRational>,
  out_total_supply: Int,
  out_apy: Int,
  alt_allow: Bool,
  admin_has_nft: Bool,
  loan_input: Bool,
}

const one = PRational { numerator: 1, denominator: 1 }

const three_halves = PRational { numerator: 3, denominator: 2 }

const base_rebal =
  Rebal {
    name: "600 of `supply_token` becomes 400 of `alt` at 3/2",
    in_total_supply: 10000,
    in_usdm: 10000,
    out_usdm: 9400,
    in_alt: 0,
    out_alt: 400,
    in_rates: [one],
    out_rates: [three_halves],
    out_total_supply: 10000,
    out_apy: 500,
    alt_allow: True,
    admin_has_nft: True,
    loan_input: False,
  }

fn run(r: Rebal) -> Bool {
  let market = pool_utils.t_market(0, 9000, r.alt_allow)
  let admin =
    if r.admin_has_nft {
      pool_utils.t_admin_in()
    } else {
      pool_utils.t_plain_in(
        "no_admin",
        pool_utils.t_wallet_address(),
        assets.from_lovelace(2000000),
      )
    }
  let extra =
    if r.loan_input {
      [
        pool_utils.t_plain_in(
          "loan",
          Address {
            payment_credential: Script(pool_utils.t_loan_skh),
            stake_credential: None,
          },
          assets.from_lovelace(5000000),
        ),
      ]
    } else {
      []
    }
  let inputs =
    list.concat(
      [
        pool_utils.t_pool_in(
          pool_utils.t_pool_value(5000000, r.in_usdm, r.in_alt, 0),
          pool_utils.t_pool_datum(r.in_total_supply, 10000, 0, 0, 0, r.in_rates),
        ),
        admin,
      ],
      extra,
    )
  validate(
    pool_utils.t_pool_skh,
    pool_utils.t_config_pool_skh,
    pool_utils.t_loan_skh,
    pool_utils.t_order_skh,
    pool_utils.t_position_skh,
    pool_utils.t_oracle_skh,
    pool_utils.t_admin_nft,
    [],
    0,
    0,
    1,
    0,
    inputs,
    [
      pool_utils.t_pool_out(
        pool_utils.t_pool_value(5000000, r.out_usdm, r.out_alt, 0),
        PoolDatum {
          total_supply: r.out_total_supply,
          circulating_dtoken: 10000,
          total_borrow: 0,
          borrow_apy: r.out_apy,
          undistributed_fee: 0,
          interest_index: constants.initial_interest_index,
          interest_time: pool_utils.t_tx_start,
          alt_supply_tokens_rate: r.out_rates,
          bad_debt: 0,
        },
      ),
    ],
    [pool_utils.t_market_ref(market)],
    pool_utils.t_oracle_redeemers(),
    assets.zero,
    pool_utils.t_range(),
  )
}

test rebalance_alt_happy_paths() {
  let cases =
    [
      base_rebal,
      Rebal {
        ..base_rebal,
        name: "the arm may add value and hold no alt at all",
        out_usdm: 10500,
        out_alt: 0,
        out_rates: [one],
        out_total_supply: 10500,
      },
      Rebal {
        ..base_rebal,
        name: "400 of `alt` becomes 600 of `supply_token`, its appreciation booked",
        in_total_supply: 9800,
        in_usdm: 9400,
        out_usdm: 10000,
        in_alt: 400,
        out_alt: 0,
        out_total_supply: 10000,
      },
    ]
  list.all(cases, fn(c) { run(c)? })
}

// §17.4 — the arm may exchange value and may add it, never remove it
test fail_rebalance_when_value_leaves_the_pool() fail {
  run(Rebal { ..base_rebal, out_alt: 300, out_total_supply: 9850 })
}

// §17.2
test fail_rebalance_without_the_admin_nft() fail {
  run(Rebal { ..base_rebal, admin_has_nft: False })
}

// §17.6 — a key with `allow_supply == False` may fall but never rise
test fail_rebalance_when_a_disabled_key_rises() fail {
  run(Rebal { ..base_rebal, alt_allow: False })
}

// §17.13
test fail_rebalance_when_a_loan_utxo_is_an_input() fail {
  run(Rebal { ..base_rebal, loan_input: True })
}
