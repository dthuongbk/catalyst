//// A lender supplies the pool and receives `dToken`, or burns `dToken` and
//// withdraws — biz spec §18. The pool's only funding path.

use aiken/collection/list
use aiken/math
use cardano/assets.{AssetName, PolicyId, Value}
use cardano/transaction.{Input, Output, ValidityRange}
use constants
use daken/prational.{PRational}
use daken/types.{Redeemers} as daken_types
use pool/utils as pool_utils
use types.{AdapterEntry, MarketDatum, PoolDatum, ScriptHash}
use utils

/// Returns this action's contribution to `mint[pool_skh]` — biz spec §18 item 3.
/// The `dToken` is named for the market, as the deployed contract names it.
pub fn validate(
  // script context
  pool_skh: PolicyId,
  config_pool_skh: PolicyId,
  loan_skh: PolicyId,
  order_skh: PolicyId,
  position_skh: PolicyId,
  oracle_skh: ByteArray,
  adapters: Pairs<ScriptHash, AdapterEntry>,
  // indexers
  pool_in_idx: Int,
  pool_out_idx: Int,
  market_ref_idx: Int,
  fee_out_idx: Int,
  // transaction context
  inputs: List<Input>,
  outputs: List<Output>,
  reference_inputs: List<Input>,
  redeemers: Redeemers,
  mint: Value,
  validity_range: ValidityRange,
) -> (AssetName, Int) {
  let tx_start = pool_utils.tx_start_of(validity_range)
  // §18.1
  let (market_nft_name, market) =
    pool_utils.market_ref(reference_inputs, market_ref_idx, config_pool_skh)
  let MarketDatum {
    supply_token,
    alt_supply_tokens,
    loan_fee_rate,
    min_tx_amount,
    withdrawal_fee,
    fee_address,
    ..
  } = market
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
  // §18.10
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

  // §18.3 — the denominator is the supply before this transaction, so a lender
  // neither gains nor loses from their own deposit.
  let dtoken_qty =
    if or {
      total_supply_before_tx == 0,
      in_circulating_dtoken == 0,
    } {
      pa.pool_changed_amount
    } else {
      pa.pool_changed_amount * in_circulating_dtoken / total_supply_before_tx
    }
  expect (dtoken_qty != 0)?

  // §18.5, §18.6
  let total_supply =
    math.max(0, total_supply_before_tx + pa.pool_changed_amount)
  let total_borrow = math.max(0, in_total_borrow + accrued)
  let expected =
    PoolDatum {
      total_supply,
      // §18.4
      circulating_dtoken: in_circulating_dtoken + dtoken_qty,
      total_borrow,
      // §17 item 10a — this arm takes §7.2.18's `pool_out_datum.total_supply`.
      borrow_apy: pool_utils.borrow_apy(
        market.base_rate,
        market.power_base,
        total_supply,
        total_borrow,
      ),
      undistributed_fee: in_undistributed_fee + accrued_fee,
      interest_index: out_interest_index,
      interest_time: math.max(tx_start, in_interest_time),
      alt_supply_tokens_rate: pa.out_alt_rates,
      bad_debt: in_bad_debt,
    }

  // §18.8 — the fee is lovelace whatever the market's `supply_token` is.
  expect
    if and {
      pa.pool_changed_amount < 0,
      withdrawal_fee > 0,
    } {
      let fee_value =
        pool_utils.fee_output_value(outputs, fee_out_idx, fee_address)
      and {
        (assets.lovelace_of(fee_value) >= withdrawal_fee)?,
        (fee_value |> assets.without_lovelace |> assets.is_zero)?,
      }
    } else {
      (fee_out_idx == -1)?
    }

  expect and {
      // §18.2
      (math.abs(pa.pool_changed_amount) >= min_tx_amount)?,
      // §18.11
      pool_utils.pool_out_holds_min_ada(pool_out.value),
      // §18.9
      pool_utils.no_utxo_at(
        inputs |> list.map(fn(Input { output, .. }) { output }),
        [loan_skh, order_skh, position_skh],
      )?,
      pool_utils.no_adapter_withdrawal(redeemers, adapters)?,
      // §18.3 — nothing to any other policy, and no `alt_supply_tokens` mint or
      // burn: an alt key may be an asset this protocol cannot mint.
      pool_utils.no_mint_of(
        mint,
        [loan_skh, order_skh, position_skh, config_pool_skh],
      ),
      alt_supply_tokens
        |> list.all(
            fn(Pair((pid, name), _allow)) {
              assets.quantity_of(mint, pid, name) == 0
            },
          ),
      // §18.7 — the direction follows the sign of the `dToken` mint.
      pool_utils.check_pool_out(
        pool_in_addr,
        pool_in_value,
        pool_out,
        config_pool_skh,
        market_nft_name,
        supply_token,
        alt_supply_tokens,
        pa,
        pool_utils.flow_of(dtoken_qty),
        expected,
      ),
    }
  (market_nft_name, dtoken_qty)
}

// ------------------------------------------------------------------ tests

/// One scenario's knobs. `interest_time == tx_start` keeps `accrued` at zero, so
/// each case asserts §18's own equations.
type Topup {
  name: ByteArray,
  withdrawal_fee: Int,
  in_usdm: Int,
  out_usdm: Int,
  in_circulating: Int,
  out_circulating: Int,
  out_total_supply: Int,
  out_apy: Int,
  fee_out_idx: Int,
  fee_lovelace: Int,
}

const one = PRational { numerator: 1, denominator: 1 }

const base_topup =
  Topup {
    name: "a deposit of 200 against a supply of 10,000 mints 200 dToken",
    withdrawal_fee: 0,
    in_usdm: 10000,
    out_usdm: 10200,
    in_circulating: 10000,
    out_circulating: 10200,
    out_total_supply: 10200,
    out_apy: 500,
    fee_out_idx: -1,
    fee_lovelace: 0,
  }

fn run(t: Topup) -> Bool {
  let market = pool_utils.t_market(t.withdrawal_fee, 9000, True)
  let dtoken_qty = t.out_circulating - t.in_circulating
  validate(
    pool_utils.t_pool_skh,
    pool_utils.t_config_pool_skh,
    pool_utils.t_loan_skh,
    pool_utils.t_order_skh,
    pool_utils.t_position_skh,
    pool_utils.t_oracle_skh,
    [],
    0,
    0,
    0,
    t.fee_out_idx,
    [
      pool_utils.t_pool_in(
        pool_utils.t_pool_value(5000000, t.in_usdm, 0, 0),
        pool_utils.t_pool_datum(10000, t.in_circulating, 0, 0, 0, [one]),
      ),
    ],
    [
      pool_utils.t_pool_out(
        pool_utils.t_pool_value(5000000, t.out_usdm, 0, 0),
        PoolDatum {
          total_supply: t.out_total_supply,
          circulating_dtoken: t.out_circulating,
          total_borrow: 0,
          borrow_apy: t.out_apy,
          undistributed_fee: 0,
          interest_index: constants.initial_interest_index,
          interest_time: pool_utils.t_tx_start,
          alt_supply_tokens_rate: [one],
          bad_debt: 0,
        },
      ),
      pool_utils.t_plain_out(
        pool_utils.t_fee_address,
        assets.from_lovelace(t.fee_lovelace),
      ),
    ],
    [pool_utils.t_market_ref(market)],
    pool_utils.t_oracle_redeemers(),
    assets.from_asset(
      pool_utils.t_pool_skh,
      pool_utils.t_market_nft_name,
      dtoken_qty,
    ),
    pool_utils.t_range(),
  ) == (pool_utils.t_market_nft_name, dtoken_qty)
}

test topup_withdraw_happy_paths() {
  let cases =
    [
      base_topup,
      Topup {
        ..base_topup,
        name: "a withdrawal of 200 burns 200 dToken",
        out_usdm: 9800,
        out_circulating: 9800,
        out_total_supply: 9800,
      },
      Topup {
        ..base_topup,
        name: "a withdrawal pays the market's withdrawal fee in lovelace",
        withdrawal_fee: 1000000,
        out_usdm: 9800,
        out_circulating: 9800,
        out_total_supply: 9800,
        fee_out_idx: 1,
        fee_lovelace: 1000000,
      },
      Topup {
        ..base_topup,
        name: "the first deposit into a pool with no dToken mints one for one",
        in_circulating: 0,
        out_circulating: 200,
      },
    ]
  list.all(cases, fn(c) { run(c)? })
}

// §18.2
test fail_topup_below_min_tx_amount() fail {
  run(
    Topup {
      ..base_topup,
      out_usdm: 10050,
      out_circulating: 10050,
      out_total_supply: 10050,
    },
  )
}

// §18.3 — a deposit small enough to floor to zero is credited to nobody
test fail_topup_when_dtoken_qty_floors_to_zero() fail {
  run(
    Topup {
      ..base_topup,
      in_circulating: 1,
      out_usdm: 10100,
      out_circulating: 1,
      out_total_supply: 10100,
    },
  )
}

// §18.8 — `fee_out_idx == -1` where no withdrawal fee is due
test fail_topup_when_a_fee_output_is_named_with_no_fee_due() fail {
  run(Topup { ..base_topup, fee_out_idx: 1 })
}

// §18.8
test fail_withdraw_when_the_fee_output_is_short() fail {
  run(
    Topup {
      ..base_topup,
      withdrawal_fee: 1000000,
      out_usdm: 9800,
      out_circulating: 9800,
      out_total_supply: 9800,
      fee_out_idx: 1,
      fee_lovelace: 999999,
    },
  )
}
