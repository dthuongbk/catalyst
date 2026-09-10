//// Biz spec §8 — anyone may move an arrived payout into the loan and clear the
//// binding. The claim's position UTxO is not spent: claim state lives only in
//// `LoanDatum`.

use aiken/collection/list
use cardano/assets.{AssetName, Value}
use cardano/transaction.{InlineDatum, Input, Output}
use constants
use daken/types.{TupleAsset} as daken_types
use loan/utils.{Registry} as loan_utils
use types.{Claim, Declaration, Delivered, LoanDatum, Opening, ScriptHash}
use utils

/// One `SingleSettleClaimIndexer`. Returns the mint contribution this action
/// makes to `mint[loan_skh]` — §8.2.12.
pub fn validate(
  // script context
  registry: Registry,
  adapter_skh: ScriptHash,
  market_nft_name: AssetName,
  declarations: List<Declaration>,
  // transaction context
  inputs: List<Input>,
  // this claim
  loan_in: Input,
  payout_in: Input,
  loan_out: Output,
  tip_out: Output,
) -> List<(AssetName, Int)> {
  let Registry { loan_skh, position_skh, adapters, .. } = registry

  // §8.2.1
  let (loan_in_address, loan_in_value, loan_in_datum, loan_nft_name) =
    loan_utils.read_loan(loan_in, loan_skh)
  expect loan_nft_name == market_nft_name
  let LoanDatum { owner_nft, token: short_token, claim, .. } = loan_in_datum

  // §8.2.2
  expect Some(Claim {
    adapter_skh: claim_adapter_skh,
    binding_nft,
    direction,
    asset,
    sold,
    floor,
    ..
  }) = claim
  expect adapter_skh == claim_adapter_skh
  expect loan_utils.adapter_may(adapters, adapter_skh, False)?

  // §8.2.3 — a `Closing` claim is rejected here; §10.2.2 is its only settle path
  expect direction == Opening

  // §8.2.4 — a fill swapped the sold leg away and cannot carry `claim.sold` of
  // it; a return carries all of it. A magnitude, not `== 0`.
  let payout_in_value =
    loan_utils.read_datum_free(payout_in, loan_skh, binding_nft)
  expect (utils.net(payout_in_value, short_token) < sold)?

  // §8.2.5 — `floor` is read from `loan_in_datum.claim`, never the declaration
  expect Some(loan_owner_nft) = owner_nft
  let c = utils.net(payout_in_value, asset)
  expect
    loan_utils.route_for(declarations, loan_owner_nft.2nd) == Delivered {
      asset,
      amount: c,
      binding_nft: Some(binding_nft),
    }

  // §8.2.6
  expect (c >= floor)?

  // §8.2.14 — this claim's position UTxO is not spent
  expect !holds_owner_nft(inputs, loan_owner_nft)?

  let Output {
    address: loan_out_address,
    value: loan_out_value,
    datum: loan_out_datum,
    reference_script: loan_out_ref_script,
  } = loan_out
  expect InlineDatum(loan_out_datum) = loan_out_datum
  expect loan_out_datum: LoanDatum = loan_out_datum

  expect and {
      // §8.2.7
      (loan_out_address == loan_in_address)?,
      (loan_out_ref_script == None)?,
      // §8.2.8, and §8.2.9's lovelace equation
      value_moved(loan_in_value, payout_in_value, loan_out_value, asset, c)?,
      // §8.2.9
      loan_utils.carries_over(
        payout_in_value,
        loan_out_value,
        [binding_nft, asset],
      )?,
      loan_utils.carries_over(loan_in_value, loan_out_value, [asset])?,
      (utils.tokens_of(loan_out_value, loan_skh) == [(loan_nft_name, 1)])?,
      // §8.2.10
      no_new_token(loan_in_value, payout_in_value, loan_out_value)?,
      loan_utils.holds_none_of(loan_out_value, position_skh)?,
      // §8.2.11
      (loan_out_datum == LoanDatum { ..loan_in_datum, claim: None })?,
      // §8.2.13 — the payout UTxO's own minADA, on **both** legs
      (assets.lovelace_of(tip_out.value) == constants.min_ada)?,
    }

  [(binding_nft.2nd, -1)]
}

/// §8.2.14 — the `LoanOwnerNFT` lives in the position UTxO, so an input holding
/// it is that position being spent.
fn holds_owner_nft(inputs: List<Input>, (pid, name): TupleAsset) -> Bool {
  list.any(
    inputs,
    fn(Input { output: Output { value, .. }, .. }) {
      assets.quantity_of(value, pid, name) > 0
    },
  )
}

/// §8.2.8 for `claim.asset`, and §8.2.9's lovelace equation, which is what funds
/// the tip. Where `claim.asset` is lovelace the two coincide: `net` on both
/// sides of item 8 releases the payout UTxO's own minADA.
fn value_moved(
  loan_in_value: Value,
  payout_in_value: Value,
  loan_out_value: Value,
  asset: TupleAsset,
  c: Int,
) -> Bool {
  and {
    utils.net(loan_out_value, asset) == utils.net(loan_in_value, asset) + c,
    assets.lovelace_of(loan_out_value) == assets.lovelace_of(loan_in_value) + assets.lovelace_of(
      payout_in_value,
    ) - constants.min_ada,
  }
}

/// §8.2.10 — `loan_out_value` carries no token absent from `loan_in_value` or
/// `payout_in_value`.
fn no_new_token(
  loan_in_value: Value,
  payout_in_value: Value,
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
              assets.quantity_of(payout_in_value, pid, name) > 0,
            },
          }
        },
      )
}

// -------------------------------------------------------------------- tests

test fill_test_is_a_magnitude_not_zero() {
  // §8.2.4 — where the sold leg is ADA the payout always carries lovelace, so
  // `net(v, lovelace) == 0` is unsatisfiable and the test has to be a magnitude.
  let ada = loan_utils.ada
  let token = (#"beef", #"544f4b")
  let tests =
    [
      // (sold_leg, payout_value, sold, is_a_fill)
      (
        ada,
        assets.from_lovelace(constants.min_ada + 1_000_000),
        13_000_000,
        True,
      ),
      (
        ada,
        assets.from_lovelace(constants.min_ada + 13_000_000),
        13_000_000,
        False,
      ),
      (token, assets.from_lovelace(constants.min_ada), 1_000, True),
      (
        token,
        assets.from_asset(#"beef", #"544f4b", 1_000)
          |> assets.merge(assets.from_lovelace(constants.min_ada)),
        1_000,
        False,
      ),
    ]
  list.all(
    tests,
    fn((sold_leg, payout_value, sold, is_a_fill)) {
      utils.net(payout_value, sold_leg) < sold == is_a_fill
    },
  )
}

test lovelace_equation_funds_the_tip() {
  // §8.2.9 — the payout's whole lovelace reaches `loan_out` less one `min_ada`,
  // which §8.2.13 sends to `tip_out_idx`. On a token leg that is the settler's
  // only payment; conditioning the tip on the leg paid them nothing at all.
  let token = (#"beef", #"544f4b")
  let ada = loan_utils.ada
  let tests =
    [
      // (asset, loan_in_lovelace, payout_lovelace, qty, loan_out_lovelace, ok)
      (
        token,
        constants.min_ada,
        constants.min_ada,
        700,
        constants.min_ada,
        True,
      ),
      (
        token,
        constants.min_ada,
        constants.min_ada,
        700,
        2 * constants.min_ada,
        False,
      ),
      (
        ada,
        constants.min_ada,
        constants.min_ada + 700,
        700,
        constants.min_ada + 700,
        True,
      ),
      (
        ada,
        constants.min_ada,
        constants.min_ada + 700,
        700,
        constants.min_ada + 699,
        False,
      ),
    ]
  list.all(
    tests,
    fn((asset, loan_in_lv, payout_lv, qty, loan_out_lv, expected)) {
      let (pid, name) = asset
      let loan_in_value = assets.from_lovelace(loan_in_lv)
      let payout_in_value =
        if asset == ada {
          assets.from_lovelace(payout_lv)
        } else {
          assets.from_asset(pid, name, qty)
            |> assets.merge(assets.from_lovelace(payout_lv))
        }
      let c = utils.net(payout_in_value, asset)
      let loan_out_value =
        if asset == ada {
          assets.from_lovelace(loan_out_lv)
        } else {
          assets.from_asset(pid, name, qty)
            |> assets.merge(assets.from_lovelace(loan_out_lv))
        }
      value_moved(loan_in_value, payout_in_value, loan_out_value, asset, c) == expected
    },
  )
}

test no_new_token_rejects_an_unaccounted_asset() {
  let loan_in = assets.from_asset(#"beef", #"41", 1)
  let payout_in = assets.from_asset(#"cafe", #"42", 5)
  let tests =
    [
      (assets.merge(loan_in, payout_in), True),
      (loan_in, True),
      (assets.merge(loan_in, assets.from_asset(#"dead", #"43", 1)), False),
    ]
  list.all(
    tests,
    fn((loan_out, expected)) {
      no_new_token(loan_in, payout_in, loan_out) == expected
    },
  )
}
