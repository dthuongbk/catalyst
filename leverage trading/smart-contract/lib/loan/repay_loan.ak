//// Biz spec §10 — a position is closed. §10.1 closes it on a synchronous
//// venue, §10.2.1 places the sell claim on an asynchronous one, and §10.2.2
//// repays once it fills.
////
//// They are told apart by the indexer alone, and §5 rule 11a pins the rest to
//// `-1`: a `payout_in_idx` means §10.2.2, a surviving `loan_out_idx` means
//// §10.2.1, and neither means §10.1.
////
//// `position_owner_in_idx` then says **who** is closing. The trader's own two
//// arms — §10.1 and §10.2.1 — name the input holding the `PositionOwnerNFT`.
//// The other two do not, and stand on something the trader cannot be cheated
//// out of instead: §10.2.2 on the claim's own `floor`, and take-profit on the
//// oracle against a price the trader wrote into the position.

use aiken/collection/list
use aiken/math
use cardano/address.{Address, Script}
use cardano/assets.{AssetName, Value}
use cardano/transaction.{InlineDatum, Input, Output}
use constants
use daken/prational.{PRational}
use daken/tokens
use daken/types.{Redeemers, TupleAsset} as daken_types
use loan/utils.{Contribution, Registry} as loan_utils
use pool/utils as pool_utils
use types.{
  Claim, Closing, Declaration, Delivered, LoanDatum, MarketDatum, Pending,
  PoolDatum, PositionDatum, ScriptHash, SingleRepayLoanIndexer,
}
use utils

/// One `SingleRepayLoanIndexer`.
pub fn validate(
  // script context
  registry: Registry,
  market_nft_name: AssetName,
  market: MarketDatum,
  adapter_skh: ScriptHash,
  declarations: List<Declaration>,
  // transaction context
  inputs: List<Input>,
  outputs: List<Output>,
  reference_inputs: List<Input>,
  redeemers: Redeemers,
  tx_start: Int,
  tx_end: Int,
  // the pool, where this redeemer spends it
  pool_ref_idx: Int,
  pool_out_interest_index: Int,
  pool_in_value: Value,
  pool_out_value: Value,
  // this loan
  idx: SingleRepayLoanIndexer,
) -> Contribution {
  let Registry {
    loan_skh,
    position_skh,
    pool_skh,
    config_pool_skh,
    adapters,
    ..
  } = registry
  let SingleRepayLoanIndexer {
    position_in_idx,
    position_owner_in_idx,
    loan_in_idx,
    loan_out_idx,
    position_out_idx,
    payout_in_idx,
    trader_out_idx,
    remain_out_idx,
    tip_out_idx,
  } = idx
  let MarketDatum { supply_token, collaterals, .. } = market

  // §8.2.1, and §10.1.1's `owner_nft` chain into the position
  let (loan_in_address, loan_in_value, loan_in_datum, loan_nft_name) =
    loan_utils.read_loan(utils.input_at(inputs, loan_in_idx), loan_skh)
  expect loan_nft_name == market_nft_name
  let LoanDatum {
    owner_nft,
    token: short_token,
    loan_amount,
    initial_interest_index,
    claim,
  } = loan_in_datum
  expect short_token == supply_token
  expect Some(loan_owner_nft) = owner_nft
  let (position_in_value, position_in_datum, position_nft_name) =
    loan_utils.read_position(
      utils.input_at(inputs, position_in_idx),
      position_skh,
      loan_owner_nft,
    )
  let PositionDatum {
    long_token,
    max_slippage,
    beneficiary,
    take_profit_price,
    ..
  } = position_in_datum

  // §10.1.3 / §10.2.1.1 — a wallet UTxO, or the order UTxO it was parked in, in
  // which case a `ModifyOrder` names that input per §9.2.9. Either way the NFT
  // is in an input, and for the trader's own arms that is the whole
  // authorisation.
  //
  // `-1` says there is no such input. Each route below answers for itself
  // whether it may stand without one, so this reports rather than requires — a
  // named input whose NFT is wrong is `False` here and fails the same arms an
  // absent one does.
  let owner_authorised =
    if position_owner_in_idx == -1 {
      False
    } else {
      expect position_owner_in_idx != position_in_idx
      tokens.contains_nft(
        utils.input_at(inputs, position_owner_in_idx).output.value,
        (
          position_skh,
          utils.suffixed(position_nft_name, constants.owner_nft_suffix),
        ),
      )?
    }

  if payout_in_idx != -1 {
    // §10.2.2 — repay once it fills
    expect loan_out_idx == -1
    expect position_out_idx == -1
    expect trader_out_idx == -1
    expect pool_ref_idx == -1
    repay_on_fill(
      registry,
      market,
      adapter_skh,
      declarations,
      inputs,
      outputs,
      loan_owner_nft,
      loan_nft_name,
      position_nft_name,
      position_in_value,
      utils.input_at(inputs, position_in_idx).output.address,
      beneficiary,
      loan_in_value,
      short_token,
      loan_amount,
      initial_interest_index,
      claim,
      long_token,
      pool_out_interest_index,
      payout_in_idx,
      remain_out_idx,
      tip_out_idx,
    )
  } else if loan_out_idx != -1 {
    // §10.2.1 — place the sell claim, either the trader's own or a take-profit
    expect trader_out_idx == -1
    expect remain_out_idx == -1
    expect tip_out_idx == -1
    place_sell_claim(
      registry,
      market,
      market_nft_name,
      adapter_skh,
      declarations,
      inputs,
      outputs,
      reference_inputs,
      redeemers,
      tx_start,
      tx_end,
      pool_ref_idx,
      loan_in_address,
      loan_in_value,
      loan_in_datum,
      loan_owner_nft,
      loan_nft_name,
      long_token,
      max_slippage,
      collaterals,
      position_in_idx,
      position_in_value,
      position_out_idx,
      loan_out_idx,
      take_profit_price,
      owner_authorised,
    )
  } else {
    // §10.1 — close on a synchronous venue
    // §10.1.3 — the collateral leaves for `trader_out`, so only the trader may
    expect owner_authorised
    expect remain_out_idx == -1
    expect tip_out_idx == -1
    expect pool_ref_idx == -1
    // §10.1.2
    expect claim == None
    // §10.1.9 — no adapter withdrawal is present, and this arm carries none
    expect adapter_skh == #""
    expect pool_utils.no_adapter_withdrawal(redeemers, adapters)?
    let debt =
      loan_utils.debt_now(
        loan_amount,
        pool_out_interest_index,
        initial_interest_index,
      )
    let trader_out = utils.output_at(outputs, trader_out_idx)
    expect and {
        // §10.1.6 — `pool_out` is excluded, since §7.2.18 requires its lovelace
        // to be monotone
        long_token_leaves(outputs, registry, long_token)?,
        pool_keeps_long_token(pool_in_value, pool_out_value, long_token)?,
        // §10.1.7 — plus both minADAs
        trader_out_valid(
          trader_out,
          registry,
          loan_in_value,
          position_in_value,
          loan_skh,
          position_skh,
          long_token,
        )?,
      }
    // §10.1.4 — `+ debt_now`; §10.1.10 has no health gate, and §10.1.11 no fee
    Contribution {
      loan_mint: [(loan_nft_name, -1), (loan_owner_nft.2nd, -1)],
      opened_proceeds: 0,
      retired: debt,
      shortfall: 0,
    }
  }
}

/// The oracle's rate for the long leg has reached the position's take-profit
/// price.
///
/// Both sides are quoted the way the oracle quotes: **`short_token` per one of
/// `long_token`**, so a rising number is a rising position and the comparison
/// reads forwards. That is the opposite orientation to `open_limit_price`,
/// which §7.4.2 uses as `sold * denominator / numerator` and so states long per
/// short — an opening bound on what is paid, against a closing bound on what is
/// received. Both denominators are positive by §6.2.2, so cross-multiplying
/// preserves the direction and no division rounds anything away.
fn take_profit_reached(
  prices: Pairs<TupleAsset, PRational>,
  short_token: TupleAsset,
  long_token: TupleAsset,
  take_profit_price: PRational,
) -> Bool {
  let price = loan_utils.price_or_unit(prices, short_token, long_token)
  price.numerator * take_profit_price.denominator >= take_profit_price.numerator * price.denominator
}

// ------------------------------------------------------------------- §10.2.1

fn place_sell_claim(
  registry: Registry,
  market: MarketDatum,
  market_nft_name: AssetName,
  adapter_skh: ScriptHash,
  declarations: List<Declaration>,
  inputs: List<Input>,
  outputs: List<Output>,
  reference_inputs: List<Input>,
  redeemers: Redeemers,
  tx_start: Int,
  tx_end: Int,
  pool_ref_idx: Int,
  loan_in_address: Address,
  loan_in_value: Value,
  loan_in_datum: LoanDatum,
  loan_owner_nft: TupleAsset,
  loan_nft_name: AssetName,
  long_token: TupleAsset,
  max_slippage: Int,
  collaterals: Pairs<TupleAsset, (Int, Bool)>,
  position_in_idx: Int,
  position_in_value: Value,
  position_out_idx: Int,
  loan_out_idx: Int,
  take_profit_price: PRational,
  owner_authorised: Bool,
) -> Contribution {
  let Registry {
    loan_skh,
    position_skh,
    pool_skh,
    config_pool_skh,
    adapters,
    oracle_skh,
    ..
  } = registry
  let LoanDatum {
    token: short_token,
    loan_amount,
    initial_interest_index,
    claim,
    ..
  } = loan_in_datum
  // §10.2.1.3 — a loan holds at most one claim
  expect claim == None
  // §10.2.1.2
  expect loan_utils.adapter_may(adapters, adapter_skh, True)?

  // §10.2.1.13 — the pool is a reference input, and this arm cannot compute a
  // floor without it
  let pool =
    loan_utils.pool_ref_at(
      reference_inputs,
      pool_ref_idx,
      pool_skh,
      config_pool_skh,
      market_nft_name,
      market.max_index_staleness,
      tx_start,
    )
  let PoolDatum { borrow_apy, interest_time, interest_index, .. } = pool
  let index =
    pool_utils.index_at(interest_index, borrow_apy, interest_time, tx_start)
  let debt = loan_utils.debt_now(loan_amount, index, initial_interest_index)

  // §10.2.1.4 — the health gate of §3 on `loan_in`
  let prices = loan_utils.prices_for(redeemers, oracle_skh, short_token)
  let long_amount = utils.net(loan_in_value, long_token)
  expect
    loan_utils.is_healthy(
      loan_utils.collateral_value(
        loan_in_value,
        (loan_skh, loan_nft_name),
        collaterals,
        short_token,
        long_token,
        long_amount,
        prices,
      ),
      debt,
    )?

  // §10.2.1.1 — the trader's own claim needs the ticket. Without it this is a
  // take-profit, and what authorises it is the standing instruction the trader
  // wrote into the position: close once the oracle says the long leg is worth
  // `take_profit_price`. The claim is otherwise identical, so nothing below
  // knows which of the two placed it.
  expect or {
      owner_authorised,
      and {
        // §6.2.2 admits `numerator == 0`, which no price can reach: that is the
        // sentinel for a position with no take-profit standing at all.
        (take_profit_price.numerator > 0)?,
        take_profit_reached(prices, short_token, long_token, take_profit_price)?,
      },
    }

  // §10.2.1.5 — `slippage_src_idx` is this action's own `position_in_idx`
  expect Pending {
    asset: route_asset,
    floor,
    market_floor,
    binding_nft,
    expiry,
    slippage_src_idx,
    stake_credential,
    ..
  } = loan_utils.route_for(declarations, loan_owner_nft.2nd)
  expect route_asset == short_token
  expect slippage_src_idx == position_in_idx
  expect stake_credential == loan_in_address.stake_credential

  // §10.2.1.6 — §4.2 in full, and the claim's duration
  expect
    floor == loan_utils.closing_floor(
      loan_utils.debt_at(debt, borrow_apy, interest_time, expiry),
      market.claim_safety_margin,
      market_floor,
    )
  expect
    loan_utils.floor_clears_venue_budget(
      floor,
      short_token,
      market.venue_fee_budget,
    )?
  expect (expiry - tx_end >= market.min_claim_duration)?
  expect (expiry - tx_end <= market.max_claim_duration)?

  // §10.2.1.7
  let sold = long_amount
  let expected_claim =
    Claim {
      adapter_skh,
      binding_nft,
      direction: Closing,
      asset: short_token,
      sold,
      floor,
      expiry,
    }
  let Output {
    address: loan_out_address,
    value: loan_out_value,
    datum: loan_out_datum,
    reference_script: loan_out_ref_script,
  } = utils.output_at(outputs, loan_out_idx)
  expect InlineDatum(loan_out_datum) = loan_out_datum
  expect loan_out_datum: LoanDatum = loan_out_datum

  let position_out = utils.output_at(outputs, position_out_idx)
  let position_in = utils.input_at(inputs, position_in_idx).output

  expect and {
      (loan_out_datum == LoanDatum {
        ..loan_in_datum,
        claim: Some(expected_claim),
      })?,
      // §10.2.1.8
      (loan_out_address == loan_in_address)?,
      (loan_out_ref_script == None)?,
      // §10.2.1.9 — the venue order carries `sold`, which the adapter proves
      (utils.net(loan_out_value, long_token) == 0)?,
      loan_utils.carries_over(loan_in_value, loan_out_value, [long_token])?,
      (utils.tokens_of(loan_out_value, loan_skh) == [(loan_nft_name, 1)])?,
      loan_utils.holds_none_of(loan_out_value, position_skh)?,
      // §10.2.1.10
      (position_out == position_in)?,
      (position_in_value == position_out.value)?,
    }

  // §10.2.1.12 — the pool is not spent, and this arm mints only the binding
  Contribution {
    loan_mint: [(binding_nft.2nd, 1)],
    opened_proceeds: 0,
    retired: 0,
    shortfall: 0,
  }
}

// ------------------------------------------------------------------- §10.2.2

fn repay_on_fill(
  registry: Registry,
  market: MarketDatum,
  adapter_skh: ScriptHash,
  declarations: List<Declaration>,
  inputs: List<Input>,
  outputs: List<Output>,
  loan_owner_nft: TupleAsset,
  loan_nft_name: AssetName,
  position_nft_name: AssetName,
  position_in_value: Value,
  position_in_address: Address,
  beneficiary: Address,
  loan_in_value: Value,
  short_token: TupleAsset,
  loan_amount: Int,
  initial_interest_index: Int,
  claim: Option<Claim>,
  long_token: TupleAsset,
  pool_out_interest_index: Int,
  payout_in_idx: Int,
  remain_out_idx: Int,
  tip_out_idx: Int,
) -> Contribution {
  let Registry { loan_skh, position_skh, adapters, .. } = registry
  // §10.2.2.1
  expect Some(Claim {
    adapter_skh: claim_adapter_skh,
    binding_nft,
    direction,
    asset,
    sold,
    floor,
    ..
  }) = claim
  expect direction == Closing
  expect adapter_skh == claim_adapter_skh
  expect loan_utils.adapter_may(adapters, adapter_skh, False)?

  // §10.2.2.2 — §8.2.4 with the `Closing` sold leg
  let payout_in_value =
    loan_utils.read_datum_free(
      utils.input_at(inputs, payout_in_idx),
      loan_skh,
      binding_nft,
    )
  expect (utils.net(payout_in_value, long_token) < sold)?
  let q = utils.net(payout_in_value, short_token)
  expect (q >= floor)?

  // §10.2.2.3
  expect
    loan_utils.route_for(declarations, loan_owner_nft.2nd) == Delivered {
      asset,
      amount: q,
      binding_nft: Some(binding_nft),
    }
  expect asset == short_token

  // §10.2.2.4 — the cap at `q` keeps a late fill repayable
  let debt =
    loan_utils.debt_now(
      loan_amount,
      pool_out_interest_index,
      initial_interest_index,
    )
  let debt_repaid = math.min(debt, q)

  // §10.2.2.6 — the residual and every asset the loan, the position or the
  // payout held go to a remain collateral UTxO per §13.2
  let remain_out = utils.output_at(outputs, remain_out_idx)
  let remain_nft_name =
    utils.suffixed(position_nft_name, constants.remain_nft_suffix)
  expect and {
      loan_utils.remain_out_valid(
        remain_out,
        loan_skh,
        position_skh,
        position_in_address,
        remain_nft_name,
        loan_utils.remain_owner_nft(position_skh, position_nft_name),
        beneficiary,
        market.collector_reward,
      )?,
      loan_utils.carries_over(
        loan_in_value,
        remain_out.value,
        [(loan_skh, loan_nft_name), loan_owner_nft],
      )?,
      loan_utils.carries_over(
        position_in_value,
        remain_out.value,
        [(position_skh, position_nft_name), loan_owner_nft],
      )?,
      // `carries_over` skips lovelace, so on a market that lends ADA the proceeds
      // were never in its domain and the clause below governed them alone. Where
      // the supply token is a token they fall under both, and the two disagree by
      // exactly `debt_repaid` — the part that goes to the pool. The sold leg is
      // excluded here for the same reason it is excluded there.
      loan_utils.carries_over(
        payout_in_value,
        remain_out.value,
        [binding_nft, short_token],
      )?,
      (utils.net(remain_out.value, short_token) >= q - debt_repaid)?,
      // §10.2.2.8 — the payout input's own minADA, the same release §8.2.13 makes
      (assets.lovelace_of(utils.output_at(outputs, tip_out_idx).value) == constants.min_ada)?,
    }

  // §10.2.2.5, and §10.3's shortfall
  Contribution {
    loan_mint: [
      (loan_nft_name, -1),
      (loan_owner_nft.2nd, -1),
      (binding_nft.2nd, -1),
      (remain_nft_name, 1),
    ],
    opened_proceeds: 0,
    retired: debt_repaid,
    shortfall: loan_utils.shortfall(debt, debt_repaid),
  }
}

// -------------------------------------------------------------------- §10.1

/// §10.1.6 — `net(out_value, long_token) == 0` for every output this
/// transaction creates at any of the five protocol scripts other than `pool_out`.
fn long_token_leaves(
  outputs: List<Output>,
  registry: Registry,
  long_token: TupleAsset,
) -> Bool {
  let Registry { loan_skh, position_skh, order_skh, config_pool_skh, .. } =
    registry
  outputs
    |> list.all(
        fn(Output { address: Address { payment_credential, .. }, value, .. }) {
          if list.any(
            [loan_skh, position_skh, order_skh, config_pool_skh],
            fn(skh) { payment_credential == Script(skh) },
          ) {
            utils.net(value, long_token) == 0
          } else {
            True
          }
        },
      )
}

/// §10.1.6's second clause. `pool_out` is excluded from the first because
/// §7.2.18 requires its lovelace to be monotone.
fn pool_keeps_long_token(
  pool_in_value: Value,
  pool_out_value: Value,
  (pid, name): TupleAsset,
) -> Bool {
  if tokens.is_ada((pid, name)) {
    True
  } else {
    assets.quantity_of(pool_out_value, pid, name) == assets.quantity_of(
      pool_in_value,
      pid,
      name,
    )
  }
}

/// §10.1.7 — every asset the loan or position held that is not `long_token` and
/// whose policy is neither `loan_skh` nor `position_skh`, plus both minADAs,
/// reaches `trader_out_idx`, whose `payment_credential` is none of the five
/// protocol scripts.
fn trader_out_valid(
  trader_out: Output,
  registry: Registry,
  loan_in_value: Value,
  position_in_value: Value,
  loan_skh: ScriptHash,
  position_skh: ScriptHash,
  long_token: TupleAsset,
) -> Bool {
  let Registry { pool_skh, order_skh, config_pool_skh, .. } = registry
  and {
    pool_utils.no_utxo_at(
      [trader_out],
      [loan_skh, position_skh, pool_skh, order_skh, config_pool_skh],
    )?,
    reaches_trader(
      loan_in_value,
      trader_out.value,
      loan_skh,
      position_skh,
      long_token,
    )?,
    reaches_trader(
      position_in_value,
      trader_out.value,
      loan_skh,
      position_skh,
      long_token,
    )?,
    (assets.lovelace_of(trader_out.value) >= 2 * constants.min_ada)?,
  }
}

fn reaches_trader(
  from: Value,
  to: Value,
  loan_skh: ScriptHash,
  position_skh: ScriptHash,
  long_token: TupleAsset,
) -> Bool {
  from
    |> assets.without_lovelace
    |> assets.reduce(
        True,
        fn(pid, name, qty, ok) {
          if or {
            pid == loan_skh,
            pid == position_skh,
            (pid, name) == long_token,
          } {
            ok
          } else {
            and {
              ok,
              assets.quantity_of(to, pid, name) >= qty,
            }
          }
        },
      )
}

// -------------------------------------------------------------------- tests

test debt_repaid_is_capped_at_what_arrived() {
  // §10.2.2.4 — the cap at `q` keeps a late fill repayable, and §10.3 books the
  // difference rather than discarding it.
  let tests =
    [
      // (debt, q, debt_repaid, shortfall)
      (1_000_000, 1_200_000, 1_000_000, 0),
      (1_000_000, 900_000, 900_000, 100_000),
      (1_000_000, 1_000_000, 1_000_000, 0),
    ]
  list.all(
    tests,
    fn((debt, q, expected_repaid, expected_shortfall)) {
      let debt_repaid = math.min(debt, q)
      and {
        debt_repaid == expected_repaid,
        loan_utils.shortfall(debt, debt_repaid) == expected_shortfall,
      }
    },
  )
}

test closing_floor_is_an_equality_against_both_lower_bounds() {
  // §4.2 — the projected debt with `claim_safety_margin` on top, or
  // `market_floor` where the venue's own curve gives more.
  let tests =
    [
      // (debt_at_expiry, claim_safety_margin, market_floor, floor)
      (1_000_000, 50, 0, 1_005_000),
      // market_floor binds
      (1_000_000, 50, 2_000_000, 2_000_000),
      // the ceiling is on the debt term, not on the max
      (1_000_001, 50, 0, 1_005_002),
    ]
  list.all(
    tests,
    fn((debt, csm, market_floor, expected)) {
      loan_utils.closing_floor(debt, csm, market_floor) == expected
    },
  )
}

test floor_clears_the_venue_budget_only_on_an_ada_leg() {
  // §4.1's side condition, so §12.2 can tell a return from a fill: a return
  // carries at most the venue's leftover budget in the paid leg.
  let token = (#"beef", #"544f4b")
  let tests =
    [
      // (floor, paid_leg, venue_fee_budget, ok)
      (13_000_001, loan_utils.ada, 13_000_000, True),
      (13_000_000, loan_utils.ada, 13_000_000, False),
      (1, token, 13_000_000, True),
    ]
  list.all(
    tests,
    fn((floor, leg, budget, expected)) {
      loan_utils.floor_clears_venue_budget(floor, leg, budget) == expected
    },
  )
}

test health_floor_nests_its_two_ceilings() {
  // §4.1 — the ceilings are nested, not applied to one product. At `T` = 8,000,
  // `claim_safety_margin` = 50 and `p` = 2/1 the inner ceiling converts the
  // projected debt into `short_token` and the outer one into `long_token`.
  let tests =
    [
      // (debt_at_expiry, csm, threshold, p_num, p_den, expected)
      (800_000, 50, 8_000, 1, 1, 1_005_000), (800_000, 50, 8_000, 2, 1, 502_500),
      // one unit of debt still costs one unit of collateral
      (1, 50, 8_000, 1, 1, 2),
    ]
  list.all(
    tests,
    fn((debt, csm, threshold, num, den, expected)) {
      loan_utils.health_floor(
        debt,
        csm,
        threshold,
        PRational { numerator: num, denominator: den },
      ) == expected
    },
  )
}
