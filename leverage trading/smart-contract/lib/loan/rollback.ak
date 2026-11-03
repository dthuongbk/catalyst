//// Biz spec §12 — anyone may unwind a claim the venue has returned, and is paid
//// `rollback_tip` for it. The returned input is the proof: §12.2's gate tells a
//// return from a fill by the **sold** leg, which no fill can carry in full.
////
//// Two arms, separated by `claim.direction`. §12.3 unwinds an `Opening` claim:
//// the loan and the position end, the pool is repaid what came back, and the
//// order's notional is restored. §12.4 unwinds a `Closing` one: the loan keeps
//// its collateral, the pool is untouched, and the position survives.

use aiken/collection/list
use aiken/math
use cardano/address.{Address, Script}
use cardano/assets.{AssetName, Value}
use cardano/transaction.{InlineDatum, Input, Output}
use constants
use daken/tokens
use daken/types.{Redeemers, TupleAsset} as daken_types
use loan/utils.{Contribution, Registry} as loan_utils
use pool/utils as pool_utils
use types.{
  Claim, Closing, Declaration, LoanDatum, MarketDatum, Opening, OrderDatum,
  PositionDatum, Recovered, ScriptHash,
}
use utils

/// One `Rollback` action.
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
  redeemers: Redeemers,
  tx_start: Int,
  // the pool, where the `Opening` arm spends it
  pool_out_interest_index: Int,
  // indexers
  loan_in_idx: Int,
  position_in_idx: Int,
  refund_in_idx: Int,
  loan_out_idx: Int,
  position_out_idx: Int,
  remain_out_idx: Int,
  order_in_idx: Int,
  order_out_idx: Int,
  tip_out_idx: Int,
) -> Contribution {
  let Registry { loan_skh, position_skh, order_skh, adapters, .. } = registry
  let MarketDatum { supply_token, rollback_tip, collector_reward, .. } = market

  // §12.3.1 / §12.4.1 — §8.2.1, and the `owner_nft` chain into the position
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
  let position_in = utils.input_at(inputs, position_in_idx).output
  let (position_in_value, position_in_datum, position_nft_name) =
    loan_utils.read_position(
      utils.input_at(inputs, position_in_idx),
      position_skh,
      loan_owner_nft,
    )
  let PositionDatum { long_token, beneficiary, .. } = position_in_datum

  expect Some(Claim {
    adapter_skh: claim_adapter_skh,
    binding_nft,
    direction,
    asset,
    sold,
    floor,
    expiry,
  }) = claim
  // §12.3.2 / §12.4.2
  expect adapter_skh == claim_adapter_skh
  expect loan_utils.adapter_may(adapters, adapter_skh, False)?

  // §12.2 — the gate
  let refund_asset = loan_utils.sold_leg(direction, short_token, long_token)
  let refund_in_value =
    loan_utils.read_datum_free(
      utils.input_at(inputs, refund_in_idx),
      loan_skh,
      binding_nft,
    )
  let recovered = utils.net(refund_in_value, refund_asset)
  expect
    gate(
      refund_in_value,
      refund_asset,
      asset,
      recovered,
      sold,
      floor,
      expiry,
      tx_start,
    )?

  // §12.3.4 / §12.4.4
  expect
    loan_utils.route_for(declarations, loan_owner_nft.2nd) == Recovered {
      asset: refund_asset,
      amount: recovered,
      binding_nft,
    }

  // §12.3.8 / §12.4.11 — **exactly** `rollback_tip`, taken from the lovelace the
  // venue returned, never from the margin. An upper bound as well as a lower one
  expect
    (assets.lovelace_of(utils.output_at(outputs, tip_out_idx).value) == rollback_tip)?

  when direction is {
    Opening -> {
      expect loan_out_idx == -1
      expect position_out_idx == -1
      // §12.3.5 — the pool receives `Σ debt_repaid`
      let debt =
        loan_utils.debt_now(
          loan_amount,
          pool_out_interest_index,
          initial_interest_index,
        )
      let debt_repaid = math.min(debt, recovered)
      let remain_out = utils.output_at(outputs, remain_out_idx)
      let remain_nft_name =
        utils.suffixed(position_nft_name, constants.remain_nft_suffix)
      expect and {
          // §12.3.6 — the value recovered but not paid to the pool, and every
          // other asset the loan or position held
          loan_utils.remain_out_valid(
            remain_out,
            loan_skh,
            position_skh,
            position_in.address,
            remain_nft_name,
            loan_utils.remain_owner_nft(position_skh, position_nft_name),
            beneficiary,
            collector_reward,
          )?,
          loan_utils.carries_over(
            refund_in_value,
            remain_out.value,
            [binding_nft, refund_asset],
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
          (utils.net(remain_out.value, refund_asset) >= recovered - debt_repaid)?,
          // §12.2.6 — the `Opening` arm frees both minADAs, and the pool's
          // repayment and the tip both come out of the returned lovelace where
          // the sold leg is ADA
          opening_lovelace(
            assets.lovelace_of(remain_out.value),
            assets.lovelace_of(refund_in_value),
            rollback_tip,
            refund_asset,
            debt_repaid,
          )?,
          // §12.3 preamble — `short_amount` is restored on the order where the
          // order still exists, under an accompanying `ModifyOrder`
          order_restored(
            inputs,
            outputs,
            order_skh,
            order_in_idx,
            order_out_idx,
            sold,
            loan_amount,
            market,
          )?,
        }
      // §12.3.7
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
    Closing -> {
      // §12.4.9 — the pool is not spent and `total_borrow` is unchanged, so this
      // arm books nothing: nothing was lent against a `Closing` claim
      expect remain_out_idx == -1
      expect order_in_idx == -1
      expect order_out_idx == -1
      let Output {
        address: loan_out_address,
        value: loan_out_value,
        datum: loan_out_datum,
        reference_script: loan_out_ref_script,
      } = utils.output_at(outputs, loan_out_idx)
      expect InlineDatum(loan_out_datum) = loan_out_datum
      expect loan_out_datum: LoanDatum = loan_out_datum
      expect and {
          // §12.4.5
          (loan_out_address == loan_in_address)?,
          (loan_out_ref_script == None)?,
          // §12.4.6
          (utils.net(loan_out_value, long_token) == utils.net(
            loan_in_value,
            long_token,
          ) + recovered)?,
          loan_utils.carries_over(loan_in_value, loan_out_value, [long_token])?,
          loan_utils.carries_over(
            refund_in_value,
            loan_out_value,
            [binding_nft, refund_asset],
          )?,
          no_new_token(loan_in_value, refund_in_value, loan_out_value)?,
          loan_utils.holds_none_of(loan_out_value, position_skh)?,
          // §12.4.7
          (loan_out_datum == LoanDatum { ..loan_in_datum, claim: None })?,
          // §12.4.8
          (utils.output_at(outputs, position_out_idx) == position_in)?,
          // §12.2.6 — both UTxOs survive and keep their own minADAs. Carrying
          // the `2 × min_ada` term across from the `Opening` arm makes this
          // unsatisfiable against §12.4.6's equality, whatever the venue returned
          (assets.lovelace_of(loan_out_value) >= assets.lovelace_of(
            refund_in_value,
          ) - rollback_tip)?,
        }
      // §12.4.10
      Contribution {
        loan_mint: [(binding_nft.2nd, -1)],
        opened_proceeds: 0,
        retired: 0,
        shortfall: 0,
      }
    }
  }
}

/// §12.2 items 2 to 5. Item 3 holds on **both** the item 4 arm and the item 5
/// arm: a fill arrives at or above `claim.floor` in the paid leg, and a return
/// carries at most the venue's leftover budget. Item 5 relaxes item 4 alone,
/// because without it a venue returning one unit less than it was sent freezes
/// the loan, the refund UTxO and the pool's principal permanently.
pub fn gate(
  refund_in_value: Value,
  refund_asset: TupleAsset,
  claim_asset: TupleAsset,
  recovered: Int,
  sold: Int,
  floor: Int,
  expiry: Int,
  tx_start: Int,
) -> Bool {
  and {
    // §12.2.2
    (recovered > 0)?,
    // §12.2.3 — a magnitude, not `== 0`, for the reason §8.2.4 gives
    (utils.net(refund_in_value, claim_asset) < floor)?,
    // §12.2.4, relaxed by §12.2.5
    or {
      recovered >= sold,
      tx_start > expiry + constants.max_validity_window,
    }?,
  }
}

/// §12.2.6's `Opening` equation. §12.3.7 burns the loan and the position, so
/// their two minADAs are freed; the pool's repayment and the tip both come out
/// of the returned lovelace when the sold leg is ADA, and without netting them
/// out the three claims on it exceed what the venue returned.
pub fn opening_lovelace(
  remain_out_lovelace: Int,
  refund_in_lovelace: Int,
  rollback_tip: Int,
  refund_asset: TupleAsset,
  debt_repaid: Int,
) -> Bool {
  remain_out_lovelace >= refund_in_lovelace + 2 * constants.min_ada - rollback_tip - if tokens.is_ada(
    refund_asset,
  ) {
    debt_repaid
  } else {
    0
  }
}

/// §12.3's preamble — `short_amount` is restored on the order where the order
/// still exists, so the trader can try again rather than posting a new one: the
/// fill decremented it by `loan_amount + short_from_order_in`, and a venue that
/// never executed should not consume the order's notional. §9.2.6's monotonicity
/// does not apply here.
///
/// `order_in_idx` and `order_out_idx` are either both `-1` — the order was
/// cancelled, or fully consumed and burned — or both set.
fn order_restored(
  inputs: List<Input>,
  outputs: List<Output>,
  order_skh: ScriptHash,
  order_in_idx: Int,
  order_out_idx: Int,
  sold: Int,
  loan_amount: Int,
  market: MarketDatum,
) -> Bool {
  if order_in_idx == -1 {
    // §12.3.9 — no order UTxO is an input on this branch
    and {
      order_out_idx == -1,
      no_input_at(inputs, order_skh),
    }
  } else {
    expect order_out_idx != -1
    let Input {
      output: Output {
        address: order_in_address,
        value: order_in_value,
        datum: order_in_datum,
        ..
      },
      ..
    } = utils.input_at(inputs, order_in_idx)
    expect InlineDatum(order_in_datum) = order_in_datum
    expect order_in_datum: OrderDatum = order_in_datum
    let Output {
      address: order_out_address,
      value: order_out_value,
      datum: order_out_datum,
      ..
    } = utils.output_at(outputs, order_out_idx)
    expect InlineDatum(order_out_datum) = order_out_datum
    expect order_out_datum: OrderDatum = order_out_datum
    let fee_kept =
      loan_amount - pool_utils.net_loan_proceeds(
        loan_amount,
        market.loan_origination_fee_rate,
        market.loan_origination_fee_min_amount,
      )
    and {
      (order_in_address.payment_credential == Script(order_skh))?,
      // the whole notional the fill consumed, the last term being the
      // origination fee the pool kept
      (order_out_datum == OrderDatum {
        ..order_in_datum,
        short_amount: order_in_datum.short_amount + sold + fee_kept,
      })?,
      (order_out_value == order_in_value)?,
      (order_out_address == order_in_address)?,
    }
  }
}

fn no_input_at(inputs: List<Input>, skh: ScriptHash) -> Bool {
  inputs
    |> list.all(
        fn(Input { output: Output { address, .. }, .. }) {
          address.payment_credential != Script(skh)
        },
      )
}

fn no_new_token(
  loan_in_value: Value,
  refund_in_value: Value,
  loan_out_value: Value,
) -> Bool {
  loan_out_value
    |> assets.reduce(
        True,
        fn(pid, name, _qty, ok) {
          and {
            ok,
            or {
              assets.quantity_of(loan_in_value, pid, name) > 0,
              assets.quantity_of(refund_in_value, pid, name) > 0,
            },
          }
        },
      )
}

// -------------------------------------------------------------------- tests

test the_gate_tells_a_return_from_a_fill() {
  // §12.2 — a fill swapped the sold asset away, so no fill can carry
  // `claim.sold` of it, whatever lovelace it also holds. Comparing the **paid**
  // leg against `claim.floor` instead would misread a return as a fill whenever
  // `claim.asset` is ADA and the returned budget exceeds the floor.
  let ada = loan_utils.ada
  let token = (#"beef", #"544f4b")
  let ma = constants.min_ada
  let tests =
    [
      // a plain return: the whole sold leg comes back in a token
      (
        assets.from_asset(#"beef", #"544f4b", 1_000)
          |> assets.merge(assets.from_lovelace(ma + 1_000_000)),
        token,
        ada,
        1_000,
        2_000_000,
        1_000,
        0,
        True,
      ),
      // a fill: the sold leg is gone, so item 4 fails and item 5 does not apply
      (
        assets.from_lovelace(ma + 2_500_000),
        token,
        ada,
        1_000,
        2_000_000,
        1_000,
        0,
        False,
      ),
      // a return short by one unit, inside the window: item 4 fails
      (
        assets.from_asset(#"beef", #"544f4b", 999)
          |> assets.merge(assets.from_lovelace(ma)),
        token,
        ada,
        1_000,
        2_000_000,
        1_000,
        0,
        False,
      ),
      // the same return past `expiry + max_validity_window`: item 5 admits it
      (
        assets.from_asset(#"beef", #"544f4b", 999)
          |> assets.merge(assets.from_lovelace(ma)),
        token,
        ada,
        1_000,
        2_000_000,
        1_000,
        constants.max_validity_window + 2,
        True,
      ),
      // item 3 is never relaxed: a payout at or above the floor is a fill
      (
        assets.from_asset(#"beef", #"544f4b", 1_000)
          |> assets.merge(assets.from_lovelace(ma + 2_000_000)),
        token,
        ada,
        1_000,
        2_000_000,
        1_000,
        constants.max_validity_window + 2,
        False,
      ),
    ]
  list.all(
    tests,
    fn(
      (value, refund_asset, claim_asset, sold, floor, _r, extra_time, expected),
    ) {
      let recovered = utils.net(value, refund_asset)
      gate(
        value,
        refund_asset,
        claim_asset,
        recovered,
        sold,
        floor,
        1_000_000,
        1_000_001 + extra_time,
      ) == expected
    },
  )
}

test opening_lovelace_nets_out_the_repayment_and_the_tip() {
  // §12.2.6 — on an ADA sold leg the pool's repayment and the tip both come out
  // of the returned lovelace. Without netting them out the three claims on it
  // exceed what the venue returned.
  let ada = loan_utils.ada
  let token = (#"beef", #"544f4b")
  let ma = constants.min_ada
  let tip = 3_000_000
  let tests =
    [
      // (refund_lovelace, refund_asset, debt_repaid, remain_lovelace, ok)
      (
        ma + 10_000_000,
        ada,
        8_000_000,
        ma + 10_000_000 + 2 * ma - tip - 8_000_000,
        True,
      ),
      (
        ma + 10_000_000,
        ada,
        8_000_000,
        ma + 10_000_000 + 2 * ma - tip - 8_000_001,
        False,
      ),
      // a token sold leg: the repayment is not in lovelace
      (ma + 1_000_000, token, 8_000_000, ma + 1_000_000 + 2 * ma - tip, True),
      (
        ma + 1_000_000,
        token,
        8_000_000,
        ma + 1_000_000 + 2 * ma - tip - 1,
        False,
      ),
    ]
  list.all(
    tests,
    fn((refund_lovelace, refund_asset, debt_repaid, remain_lovelace, expected)) {
      opening_lovelace(
        remain_lovelace,
        refund_lovelace,
        tip,
        refund_asset,
        debt_repaid,
      ) == expected
    },
  )
}

test closing_lovelace_carries_no_min_ada_term() {
  // §12.2.6 — on the `Closing` arm both UTxOs survive and keep their own
  // minADAs, so `loan_out` carries `>= refund_in[lovelace] - rollback_tip`.
  // Carrying the `2 × min_ada` term across makes it unsatisfiable against
  // §12.4.6's equality.
  let tip = 3_000_000
  let tests =
    [
      // (refund_lovelace, loan_out_lovelace, ok)
      (10_000_000, 7_000_000, True), (10_000_000, 6_999_999, False),
      (10_000_000, 10_000_000, True),
    ]
  list.all(
    tests,
    fn((refund_lovelace, loan_out_lovelace, expected)) {
      loan_out_lovelace >= refund_lovelace - tip == expected
    },
  )
}
