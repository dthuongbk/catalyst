//// The pool side of any transaction that lends or is repaid — biz spec §7.2
//// item 18, and §10.3 where a retiring arm books a shortfall.

use aiken/collection/list
use aiken/math
use cardano/address.{Address, Script}
use cardano/assets.{AssetName, PolicyId, Value}
use cardano/transaction.{InlineDatum, Input, Output, ValidityRange}
use constants
use daken/prational.{PRational}
use daken/types.{Redeemers} as daken_types
use pool/utils as pool_utils
use types.{LoanDatum, MarketDatum, PoolDatum}
use utils

/// What the loans this action names contribute to the pool's equations. The two
/// domains are disjoint — §7.2.18 — and a loan the transaction neither mints nor
/// burns contributes to neither.
type Loans {
  opened: Int,
  opened_proceeds: Int,
  opened_count: Int,
  retired_debt_now: Int,
  retired_count: Int,
}

fn walk_loans(
  names: List<AssetName>,
  loan_skh: PolicyId,
  market_nft_name: AssetName,
  market: MarketDatum,
  out_interest_index: Int,
  loan_ins: List<Output>,
  loan_outs: List<Output>,
  mint: Value,
) -> Loans {
  when names is {
    [] ->
      Loans {
        opened: 0,
        opened_proceeds: 0,
        opened_count: 0,
        retired_debt_now: 0,
        retired_count: 0,
      }
    [name, ..rest] -> {
      let acc =
        walk_loans(
          rest,
          loan_skh,
          market_nft_name,
          market,
          out_interest_index,
          loan_ins,
          loan_outs,
          mint,
        )
      // The `LoanOwnerNFT` is minted where a loan opens and burned where it is
      // retired, which is what makes the two domains of §7.2.18 disjoint.
      let minted = assets.quantity_of(mint, loan_skh, name)
      if minted == 1 {
        let loan =
          pool_utils.loan_by_owner_nft(
            loan_outs,
            loan_skh,
            market_nft_name,
            name,
          )
        let proceeds =
          pool_utils.net_loan_proceeds(
            loan.loan_amount,
            market.loan_origination_fee_rate,
            market.loan_origination_fee_min_amount,
          )
        // §7.2.6
        expect (loan.loan_amount >= market.min_tx_amount)?
        expect (proceeds > 0)?
        Loans {
          ..acc,
          opened: acc.opened + loan.loan_amount,
          opened_proceeds: acc.opened_proceeds + proceeds,
          opened_count: acc.opened_count + 1,
        }
      } else if minted == -1 {
        let loan =
          pool_utils.loan_by_owner_nft(
            loan_ins,
            loan_skh,
            market_nft_name,
            name,
          )
        Loans {
          ..acc,
          retired_debt_now: acc.retired_debt_now + pool_utils.debt_now(
            loan.loan_amount,
            out_interest_index,
            loan.initial_interest_index,
          ),
          retired_count: acc.retired_count + 1,
        }
      } else {
        // §7.2.12 mints one `LoanOwnerNFT` per opened loan and §7.2.18 burns one
        // per retired loan; no other quantity is reachable.
        expect (minted == 0)?
        acc
      }
    }
  }
}

pub fn validate(
  // script context
  pool_skh: PolicyId,
  config_pool_skh: PolicyId,
  loan_skh: PolicyId,
  oracle_skh: ByteArray,
  // indexers
  pool_in_idx: Int,
  pool_out_idx: Int,
  market_ref_idx: Int,
  loans: List<AssetName>,
  // transaction context
  inputs: List<Input>,
  outputs: List<Output>,
  reference_inputs: List<Input>,
  redeemers: Redeemers,
  mint: Value,
  validity_range: ValidityRange,
) -> Bool {
  let tx_start = pool_utils.tx_start_of(validity_range)
  let (market_nft_name, market) =
    pool_utils.market_ref(reference_inputs, market_ref_idx, config_pool_skh)
  let MarketDatum { supply_token, alt_supply_tokens, loan_fee_rate, .. } =
    market
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

  let l =
    walk_loans(
      loans,
      loan_skh,
      market_nft_name,
      market,
      out_interest_index,
      inputs |> list.map(fn(Input { output, .. }) { output }),
      outputs,
      mint,
    )

  // §10.3 — `Σ shortfall` is the retiring arm's, declared through `bad_debt` and
  // read back here so §7.2.18's clamp is applied after it. Nothing can be
  // written down where no loan is retired.
  expect InlineDatum(declared) = pool_out.datum
  expect PoolDatum { bad_debt: out_bad_debt, .. }: PoolDatum = declared
  let shortfall = out_bad_debt - in_bad_debt
  expect (shortfall >= 0)?
  expect or {
      l.retired_count > 0,
      shortfall == 0,
    }?

  let total_supply = math.max(0, total_supply_before_tx - shortfall)
  let total_borrow =
    math.max(0, in_total_borrow + accrued + l.opened - l.retired_debt_now)
  let undistributed_fee =
    in_undistributed_fee + l.opened - l.opened_proceeds + accrued_fee
  let expected =
    PoolDatum {
      total_supply,
      circulating_dtoken: in_circulating_dtoken,
      total_borrow,
      borrow_apy: pool_utils.borrow_apy(
        market.base_rate,
        market.power_base,
        total_supply,
        total_borrow,
      ),
      undistributed_fee,
      interest_index: out_interest_index,
      interest_time: math.max(tx_start, in_interest_time),
      alt_supply_tokens_rate: pa.out_alt_rates,
      bad_debt: out_bad_debt,
    }

  // §7.2.18 — the one `short_token` equation. `Σ_opened net_loan_proceeds` is
  // this arm's to evaluate; `Σ_retired R` is the retiring arm's term and is only
  // bounded here, since `R` is `debt_repaid` or `repaid` depending on which arm
  // hands it back and neither is reachable from the pool's own redeemer.
  let (short_pid, short_name) = supply_token
  let retired_inflow =
    assets.quantity_of(pool_out.value, short_pid, short_name) - assets.quantity_of(
      pool_in_value,
      short_pid,
      short_name,
    ) + l.opened_proceeds
  and {
    (retired_inflow >= 0)?,
    or {
      l.retired_count > 0,
      retired_inflow == 0,
    }?,
    // §7.2.23 belongs to §7 alone: only a fill raises `total_borrow`.
    or {
      l.opened_count == 0,
      market.util_cap * total_supply > total_borrow * constants.basis_point,
    }?,
    pool_utils.check_pool_out(
      pool_in_addr,
      pool_in_value,
      pool_out,
      config_pool_skh,
      market_nft_name,
      supply_token,
      alt_supply_tokens,
      pa,
      pool_utils.flow_of(pa.pool_changed_amount),
      expected,
    ),
  }
}

// ------------------------------------------------------------------ tests

/// One scenario's knobs. `pool_utils.t_*` supplies everything else, and the
/// pool's `interest_time` equals `tx_start` so `accrued` is zero and each case
/// asserts this arm's own equations rather than the accrual.
type Fill {
  name: ByteArray,
  in_usdm: Int,
  out_usdm: Int,
  out_junk: Int,
  loans: List<AssetName>,
  loan_amount: Int,
  util_cap: Int,
  out_total_supply: Int,
  out_total_borrow: Int,
  out_apy: Int,
  out_bad_debt: Int,
}

const base_fill =
  Fill {
    name: "one fill of 1,000 against a supply of 10,000",
    in_usdm: 10000,
    out_usdm: 9000,
    out_junk: 0,
    loans: ["owner_one"],
    loan_amount: 1000,
    util_cap: 9000,
    out_total_supply: 10000,
    out_total_borrow: 1000,
    out_apy: 558,
    out_bad_debt: 0,
  }

fn loan_output(owner_nft_name: AssetName, loan_amount: Int) -> Output {
  Output {
    address: Address {
      payment_credential: Script(pool_utils.t_loan_skh),
      stake_credential: None,
    },
    value: assets.from_lovelace(5000000)
      |> assets.add(pool_utils.t_loan_skh, pool_utils.t_market_nft_name, 1),
    datum: InlineDatum(
      LoanDatum {
        owner_nft: Some((pool_utils.t_loan_skh, owner_nft_name)),
        token: pool_utils.t_usdm,
        loan_amount,
        initial_interest_index: constants.initial_interest_index,
        claim: None,
      },
    ),
    reference_script: None,
  }
}

fn run(f: Fill) -> Bool {
  let market = pool_utils.t_market(0, f.util_cap, True)
  let one = PRational { numerator: 1, denominator: 1 }
  let pool_in_value = pool_utils.t_pool_value(5000000, f.in_usdm, 0, 0)
  let pool_out_value =
    pool_utils.t_pool_value(5000000, f.out_usdm, 0, f.out_junk)
  let pool_out_datum =
    PoolDatum {
      total_supply: f.out_total_supply,
      circulating_dtoken: 10000,
      total_borrow: f.out_total_borrow,
      borrow_apy: f.out_apy,
      undistributed_fee: 0,
      interest_index: constants.initial_interest_index,
      interest_time: pool_utils.t_tx_start,
      alt_supply_tokens_rate: [one],
      bad_debt: f.out_bad_debt,
    }
  let mint =
    f.loans
      |> list.foldl(
          assets.zero,
          fn(name, acc) {
            acc
              |> assets.add(
                  pool_utils.t_loan_skh,
                  pool_utils.t_market_nft_name,
                  1,
                )
              |> assets.add(pool_utils.t_loan_skh, name, 1)
          },
        )
  pool_flow_validate(
    [
      pool_utils.t_pool_in(
        pool_in_value,
        pool_utils.t_pool_datum(10000, 10000, 0, 0, 0, [one]),
      ),
    ],
    [
      pool_utils.t_pool_out(pool_out_value, pool_out_datum),
      ..list.map(f.loans, fn(name) { loan_output(name, f.loan_amount) })
    ],
    [pool_utils.t_market_ref(market)],
    mint,
    f.loans,
  )
}

fn pool_flow_validate(
  inputs: List<Input>,
  outputs: List<Output>,
  reference_inputs: List<Input>,
  mint: Value,
  loans: List<AssetName>,
) -> Bool {
  validate(
    pool_utils.t_pool_skh,
    pool_utils.t_config_pool_skh,
    pool_utils.t_loan_skh,
    pool_utils.t_oracle_skh,
    0,
    0,
    0,
    loans,
    inputs,
    outputs,
    reference_inputs,
    pool_utils.t_oracle_redeemers(),
    mint,
    pool_utils.t_range(),
  )
}

test pool_flow_happy_paths() {
  let cases =
    [
      base_fill,
      Fill {
        ..base_fill,
        name: "two fills sum into one `total_borrow` equation",
        loans: ["owner_one", "owner_two"],
        loan_amount: 500,
      },
      Fill {
        ..base_fill,
        name: "a fill at `min_tx_amount`",
        out_usdm: 9900,
        loan_amount: 100,
        out_total_borrow: 100,
        out_apy: 504,
      },
      Fill {
        ..base_fill,
        name: "a pool spend naming no loan moves no `short_token`",
        out_usdm: 10000,
        loans: [],
        out_total_borrow: 0,
        out_apy: 500,
      },
    ]
  list.all(cases, fn(c) { run(c)? })
}

// §7.2.18's positive whitelist
test fail_pool_flow_when_the_pool_out_holds_a_foreign_token() fail {
  run(Fill { ..base_fill, out_junk: 1 })
}

// §7.2.18's `short_token` equation: no unexplained inflow where no loan retires
test fail_pool_flow_when_short_token_arrives_with_no_retired_loan() fail {
  run(Fill { ..base_fill, out_usdm: 9100 })
}

// §7.2.23
test fail_pool_flow_when_util_cap_is_breached() fail {
  run(Fill { ..base_fill, util_cap: 900 })
}

// §10.3 — nothing is written down where no loan is retired
test fail_pool_flow_when_bad_debt_is_booked_with_no_retired_loan() fail {
  run(Fill { ..base_fill, out_bad_debt: 5, out_total_supply: 9995 })
}

// §7.2.18 — `borrow_apy` is recomputed on every arm that spends the pool
test fail_pool_flow_when_borrow_apy_is_carried_forward() fail {
  run(Fill { ..base_fill, out_apy: 500 })
}
