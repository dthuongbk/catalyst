//// The admin moves accrued protocol fees out of the pool — biz spec §19.
//// Without this arm `undistributed_fee` only ever grows and §7.2.18's solvency
//// invariant eventually admits no transaction at all.

use aiken/collection/list
use aiken/math
use cardano/assets.{PolicyId, Value}
use cardano/transaction.{Input, Output, ValidityRange}
use constants
use daken/prational.{PRational}
use daken/tokens
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
  fee_out_idx: Int,
  // transaction context
  inputs: List<Input>,
  outputs: List<Output>,
  reference_inputs: List<Input>,
  redeemers: Redeemers,
  mint: Value,
  validity_range: ValidityRange,
) -> Bool {
  let tx_start = pool_utils.tx_start_of(validity_range)
  // §19.1
  let (market_nft_name, market) =
    pool_utils.market_ref(reference_inputs, market_ref_idx, config_pool_skh)
  let MarketDatum {
    supply_token,
    alt_supply_tokens,
    loan_fee_rate,
    fee_address,
    ..
  } = market
  // §19.2
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
  // §19.10
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

  // §19.3 — the share this very transaction accrues is included, and the admin
  // may take at most the fee that has accrued.
  let platform_fee = in_undistributed_fee + accrued_fee
  let total_borrow = math.max(0, in_total_borrow + accrued)
  // §19.5 — this arm does not move `total_supply`.
  let total_supply = math.max(0, total_supply_before_tx)
  let expected =
    PoolDatum {
      total_supply,
      // §19.6
      circulating_dtoken: in_circulating_dtoken,
      total_borrow,
      // §17 item 10a — this arm takes §7.2.18's `pool_out_datum.total_supply`.
      borrow_apy: pool_utils.borrow_apy(
        market.base_rate,
        market.power_base,
        total_supply,
        total_borrow,
      ),
      // §19.4 — what the admin leaves behind stays fee.
      undistributed_fee: platform_fee + pa.pool_changed_amount,
      interest_index: out_interest_index,
      interest_time: math.max(tx_start, in_interest_time),
      alt_supply_tokens_rate: pa.out_alt_rates,
      bad_debt: in_bad_debt,
    }

  // §19.7 — the raw `short_token` quantity that left, at `market.fee_address`.
  let (short_pid, short_name) = supply_token
  let short_out =
    assets.quantity_of(pool_in_value, short_pid, short_name) - assets.quantity_of(
      pool_out.value,
      short_pid,
      short_name,
    )
  let fee_value = pool_utils.fee_output_value(outputs, fee_out_idx, fee_address)
  and {
    (-platform_fee <= pa.pool_changed_amount)?,
    (pa.pool_changed_amount <= 0)?,
    (assets.quantity_of(fee_value, short_pid, short_name) >= short_out)?,
    (fee_value
      |> assets.flatten
      |> list.all(
          fn((pid, name, _q)) {
            or {
              (pid, name) == supply_token,
              tokens.is_ada((pid, name)),
            }
          },
        ))?,
    // §19.11
    pool_utils.pool_out_holds_min_ada(pool_out.value),
    // §19.9
    pool_utils.no_utxo_at(
      inputs |> list.map(fn(Input { output, .. }) { output }),
      [loan_skh, order_skh, position_skh],
    )?,
    pool_utils.no_adapter_withdrawal(redeemers, adapters)?,
    // §19.6 — this action contributes nothing to `mint[pool_skh]`; §5 rule 10
    // checks that zero in the validator's own aggregation.
    pool_utils.no_mint_of(
      mint,
      [loan_skh, order_skh, position_skh, config_pool_skh],
    ),
    // §19.6a — no `alt_supply_tokens` key moves in either direction.
    pool_utils.check_pool_out(
      pool_in_addr,
      pool_in_value,
      pool_out,
      config_pool_skh,
      market_nft_name,
      supply_token,
      alt_supply_tokens,
      pa,
      pool_utils.AltFrozen,
      expected,
    ),
  }
}

// ------------------------------------------------------------------ tests

/// One scenario's knobs. `interest_time == tx_start` keeps `accrued` at zero, so
/// `platform_fee` is exactly `pool_in_datum.undistributed_fee` and each case
/// asserts §19's own equations.
type Fee {
  name: ByteArray,
  in_usdm: Int,
  out_usdm: Int,
  in_alt: Int,
  out_alt: Int,
  in_rates: List<PRational>,
  out_rates: List<PRational>,
  in_undistributed_fee: Int,
  out_undistributed_fee: Int,
  out_total_supply: Int,
  out_apy: Int,
  fee_short: Int,
  fee_at_market_address: Bool,
}

const one = PRational { numerator: 1, denominator: 1 }

const three_halves = PRational { numerator: 3, denominator: 2 }

const base_fee =
  Fee {
    name: "300 of a 500 accrued fee leaves the pool",
    in_usdm: 10500,
    out_usdm: 10200,
    in_alt: 0,
    out_alt: 0,
    in_rates: [one],
    out_rates: [one],
    in_undistributed_fee: 500,
    out_undistributed_fee: 200,
    out_total_supply: 10000,
    out_apy: 500,
    fee_short: 300,
    fee_at_market_address: True,
  }

fn run(f: Fee) -> Bool {
  let market = pool_utils.t_market(0, 9000, True)
  let fee_address =
    if f.fee_at_market_address {
      pool_utils.t_fee_address
    } else {
      pool_utils.t_wallet_address()
    }
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
    1,
    [
      pool_utils.t_pool_in(
        pool_utils.t_pool_value(5000000, f.in_usdm, f.in_alt, 0),
        pool_utils.t_pool_datum(
          10000,
          10000,
          0,
          f.in_undistributed_fee,
          0,
          f.in_rates,
        ),
      ),
      pool_utils.t_admin_in(),
    ],
    [
      pool_utils.t_pool_out(
        pool_utils.t_pool_value(5000000, f.out_usdm, f.out_alt, 0),
        PoolDatum {
          total_supply: f.out_total_supply,
          circulating_dtoken: 10000,
          total_borrow: 0,
          borrow_apy: f.out_apy,
          undistributed_fee: f.out_undistributed_fee,
          interest_index: constants.initial_interest_index,
          interest_time: pool_utils.t_tx_start,
          alt_supply_tokens_rate: f.out_rates,
          bad_debt: 0,
        },
      ),
      pool_utils.t_plain_out(
        fee_address,
        assets.from_lovelace(2000000)
          |> assets.add(
              pool_utils.t_usdm.1st,
              pool_utils.t_usdm.2nd,
              f.fee_short,
            ),
      ),
    ],
    [pool_utils.t_market_ref(market)],
    pool_utils.t_oracle_redeemers(),
    assets.zero,
    pool_utils.t_range(),
  )
}

test withdraw_fee_happy_paths() {
  let cases =
    [
      base_fee,
      Fee {
        ..base_fee,
        name: "the whole accrued fee leaves",
        out_usdm: 10000,
        out_undistributed_fee: 0,
        fee_short: 500,
      },
      Fee {
        ..base_fee,
        name: "taking nothing is admissible",
        out_usdm: 10500,
        out_undistributed_fee: 500,
        fee_short: 0,
      },
    ]
  list.all(cases, fn(c) { run(c)? })
}

// §19.3 — never the lenders' principal
test fail_withdraw_fee_beyond_the_accrued_fee() fail {
  run(
    Fee { ..base_fee, in_undistributed_fee: 200, out_undistributed_fee: -100 },
  )
}

// §19.7 — the market decides where the fee goes, not the admin
test fail_withdraw_fee_to_an_address_the_admin_chooses() fail {
  run(Fee { ..base_fee, fee_at_market_address: False })
}

// §19.4 — what the admin leaves behind stays fee
test fail_withdraw_fee_when_the_residue_is_credited_to_total_supply() fail {
  run(Fee { ..base_fee, out_undistributed_fee: 500, out_total_supply: 9700 })
}

// §19.6a — no `alt_supply_tokens` key moves on this arm
test fail_withdraw_fee_when_an_alt_holding_moves() fail {
  run(
    Fee {
      ..base_fee,
      in_alt: 100,
      out_alt: 90,
      in_rates: [three_halves],
      out_rates: [three_halves],
      out_undistributed_fee: 185,
    },
  )
}
