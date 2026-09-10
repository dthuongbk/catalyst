//// Biz spec §11 — anyone may liquidate an unhealthy loan: supply `short_token`,
//// take the collateral plus a bounded reward. Liquidation is **full only**;
//// there is no partial shape.
////
//// Two arms. The ordinary one consumes an unbound loan. §11.3's grace arm
//// consumes the payout of an `Opening` claim nobody settled, and is the only
//// liquidation path a bound loan has.

use aiken/collection/list
use cardano/address.{Address}
use cardano/assets.{AssetName, Value}
use cardano/transaction.{Input, Output}
use constants
use daken/prational.{PRational}
use daken/tokens
use daken/types.{Redeemers, TupleAsset} as daken_types
use loan/utils.{Contribution, Registry} as loan_utils
use pool/utils as pool_utils
use types.{Claim, LoanDatum, MarketDatum, Opening, PositionDatum}
use utils

/// One `Liquidate` action.
pub fn validate(
  // script context
  registry: Registry,
  market_nft_name: AssetName,
  market: MarketDatum,
  // transaction context
  inputs: List<Input>,
  outputs: List<Output>,
  redeemers: Redeemers,
  tx_start: Int,
  // the pool, which this arm always spends
  pool_out_interest_index: Int,
  // indexers
  loan_in_idx: Int,
  position_in_idx: Int,
  payout_in_idx: Int,
  liquidator_out_idx: Int,
  remain_out_idx: Int,
  tip_out_idx: Int,
  reward: Int,
) -> Contribution {
  let Registry { loan_skh, position_skh, adapters, oracle_skh, .. } = registry
  let MarketDatum {
    supply_token,
    collaterals,
    liquidator_reward_cap,
    min_liquidator_reward,
    collector_reward,
    ..
  } = market

  // §11.2.1
  let (_loan_in_address, loan_in_value, loan_in_datum, loan_nft_name) =
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

  // §11.2.2 — either the loan carries no claim and no payout is consumed, or
  // §11.3 applies. §11.2.8 guards on `payout_in_idx != -1` for the reason §5
  // rule 13 gives: an index out of range fails, it is never read as absent.
  let (payout_value, binding_burn) =
    if payout_in_idx == -1 {
      expect claim == None
      expect tip_out_idx == -1
      (None, [])
    } else {
      // §11.3 — the gate is `Opening`, and §11.2.2 rejects a `Closing` claim on
      // both branches
      expect Some(Claim { direction, binding_nft, expiry, .. }) = claim
      expect direction == Opening
      expect (tx_start > expiry)?
      expect tip_out_idx != -1
      let v =
        loan_utils.read_datum_free(
          utils.input_at(inputs, payout_in_idx),
          loan_skh,
          binding_nft,
        )
      (Some(v), [(binding_nft.2nd, -1)])
    }

  // §11.3.2 / §2.11 — on the grace arm the collateral is what arrived
  let arrived =
    when payout_value is {
      Some(v) -> {
        expect Some(Claim { asset, .. }) = claim
        Some(utils.net(v, asset))
      }
      None -> None
    }
  let collateral_amount =
    loan_utils.collateral_amount(claim, loan_in_value, long_token, arrived)

  // §11.2.3 — the gate of §3 **fails**, `debt_now` from `pool_out_datum`
  let prices = loan_utils.prices_for(redeemers, oracle_skh, short_token)
  let p = loan_utils.price_of(prices, long_token)
  let debt =
    loan_utils.debt_now(
      loan_amount,
      pool_out_interest_index,
      initial_interest_index,
    )
  expect
    !loan_utils.is_healthy(
      loan_utils.collateral_value(
        loan_in_value,
        (loan_skh, loan_nft_name),
        collaterals,
        short_token,
        long_token,
        collateral_amount,
        prices,
      ),
      debt,
    )?

  // §11.2.6
  let (reward_floor, cap) =
    loan_utils.reward_bounds(
      collateral_amount,
      liquidator_reward_cap,
      min_liquidator_reward,
      p,
    )
  expect (reward >= reward_floor)?
  expect (reward <= cap)?

  // §2.13, §2.14
  let seized = loan_utils.seized(debt, p, collateral_amount, reward)
  let taken = seized + reward
  let remainder = collateral_amount - taken
  let repaid = loan_utils.repaid(seized, p)

  // §11.2.7's last clause — where the collateral did not cover the debt the
  // difference is booked per §10.3, and a maximal reward may not manufacture it
  expect or {
      seized >= loan_utils.debt_in_long(debt, p),
      reward == reward_floor,
    }?

  let liquidator_out = utils.output_at(outputs, liquidator_out_idx)
  let remain_out = utils.output_at(outputs, remain_out_idx)
  let remain_nft_name =
    utils.suffixed(position_nft_name, constants.remain_nft_suffix)

  expect and {
      // §11.2.7
      (utils.net(liquidator_out.value, long_token) == taken)?,
      lovelace_equations(
        long_token,
        taken,
        remainder,
        collector_reward,
        assets.lovelace_of(liquidator_out.value),
        assets.lovelace_of(remain_out.value),
        if tip_out_idx == -1 {
          None
        } else {
          Some(assets.lovelace_of(utils.output_at(outputs, tip_out_idx).value))
        },
      )?,
      // §11.2.8 — the remain collateral UTxO per §13.2, plus the payout's other
      // assets **where `payout_in_idx != -1`**
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
      residual_carried(
        loan_in_value,
        position_in_value,
        payout_value,
        remain_out.value,
        loan_skh,
        position_skh,
        long_token,
        loan_owner_nft,
      )?,
      // §11.2.11 — no adapter withdrawal of any credential is present
      pool_utils.no_adapter_withdrawal(redeemers, adapters)?,
    }

  // §11.2.4, §11.2.10, and §10.3's shortfall. §11.2.9 charges no protocol fee.
  Contribution {
    loan_mint: list.concat(
      [(loan_nft_name, -1), (loan_owner_nft.2nd, -1), (remain_nft_name, 1)],
      binding_burn,
    ),
    opened_proceeds: 0,
    retired: repaid,
    shortfall: loan_utils.shortfall(debt, repaid),
  }
}

/// §11.2.7's lovelace equations, per [§5](#5) rule 9: `long_token` and the
/// minADAs are separated by `net`, never by position in a flattened list.
///
/// The liquidator's output is pinned; `remain_out`'s is a **floor**, and rule 9
/// does the rest — the three UTxOs this arm consumes must reach an output the
/// redeemer names, and the other two are pinned, so every lovelace above the
/// floor lands here with nowhere else to go. Pinning it as an equality closes
/// that destination: §12.2.6's `Closing` arm pays the venue's returned budget
/// into `loan_out`, and a resting order's un-swapped `short_token` collateral is
/// lovelace on an ADA-supply market.
pub fn lovelace_equations(
  long_token: TupleAsset,
  taken: Int,
  remainder: Int,
  collector_reward: Int,
  liquidator_out_lovelace: Int,
  remain_out_lovelace: Int,
  tip_out_lovelace: Option<Int>,
) -> Bool {
  let long_is_ada = tokens.is_ada(long_token)
  and {
    (liquidator_out_lovelace == constants.min_ada + if long_is_ada {
      taken
    } else {
      0
    })?,
    (remain_out_lovelace >= constants.min_ada + collector_reward + if long_is_ada {
      remainder
    } else {
      0
    })?,
    when tip_out_lovelace is {
      // §11.3 — the payout's third minADA covers the tip and the collector's
      // reward at once, so nothing is topped up
      Some(lovelace) -> (lovelace == constants.min_ada - collector_reward)?
      // `tip_out_idx == -1` on the ordinary arm
      None -> True
    },
  }
}

/// §11.2.8 — `remainder`, and every other asset the loan and the position held
/// whose policy is neither `loan_skh` nor `position_skh`, and, where the grace
/// arm consumes a payout, every such asset of that input too.
fn residual_carried(
  loan_in_value: Value,
  position_in_value: Value,
  payout_value: Option<Value>,
  remain_out_value: Value,
  loan_skh: ByteArray,
  position_skh: ByteArray,
  long_token: TupleAsset,
  loan_owner_nft: TupleAsset,
) -> Bool {
  and {
    carried(loan_in_value, remain_out_value, loan_skh, position_skh, long_token),
    carried(
      position_in_value,
      remain_out_value,
      loan_skh,
      position_skh,
      long_token,
    ),
    when payout_value is {
      Some(v) ->
        carried(v, remain_out_value, loan_skh, position_skh, long_token)
      None -> True
    },
    // the `LoanOwnerNFT` is burned, so it reaches no output
    assets.quantity_of(remain_out_value, loan_owner_nft.1st, loan_owner_nft.2nd) == 0,
  }
}

fn carried(
  from: Value,
  to: Value,
  loan_skh: ByteArray,
  position_skh: ByteArray,
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

/// One case of §11.2.7's lovelace arithmetic.
type Case {
  name: String,
  long_is_ada: Bool,
  grace: Bool,
  taken: Int,
  remainder: Int,
  liquidator_lovelace: Int,
  remain_lovelace: Int,
  ok: Bool,
}

const cr = 3_000_000

const ma = constants.min_ada

test lovelace_equations_over_four_cases() {
  let token = (#"beef", #"544f4b")
  let tests =
    [
      Case {
        name: @"ordinary, non-ADA long_token",
        long_is_ada: False,
        grace: False,
        taken: 1_000,
        remainder: 200,
        liquidator_lovelace: ma,
        remain_lovelace: ma + cr,
        ok: True,
      },
      Case {
        name: @"ordinary, ADA long_token — taken rides on the liquidator's minADA",
        long_is_ada: True,
        grace: False,
        taken: 1_000_000,
        remainder: 200_000,
        liquidator_lovelace: ma + 1_000_000,
        remain_lovelace: ma + cr + 200_000,
        ok: True,
      },
      Case {
        name: @"grace, non-ADA long_token — the tip is min_ada - collector_reward",
        long_is_ada: False,
        grace: True,
        taken: 1_000,
        remainder: 200,
        liquidator_lovelace: ma,
        remain_lovelace: ma + cr,
        ok: True,
      },
      Case {
        name: @"grace, ADA long_token",
        long_is_ada: True,
        grace: True,
        taken: 1_000_000,
        remainder: 200_000,
        liquidator_lovelace: ma + 1_000_000,
        remain_lovelace: ma + cr + 200_000,
        ok: True,
      },
      Case {
        name: @"the liquidator's lovelace is an equality, not a floor",
        long_is_ada: True,
        grace: False,
        taken: 1_000_000,
        remainder: 0,
        liquidator_lovelace: ma + 1_000_001,
        remain_lovelace: ma + cr,
        ok: False,
      },
      Case {
        name: @"a non-ADA long_token may not pull lovelace to the liquidator",
        long_is_ada: False,
        grace: False,
        taken: 1_000,
        remainder: 0,
        liquidator_lovelace: ma + 1_000,
        remain_lovelace: ma + cr,
        ok: False,
      },
      Case {
        name: @"remain_out is a floor — the venue's returned budget lands here",
        long_is_ada: False,
        grace: False,
        taken: 1_000,
        remainder: 0,
        liquidator_lovelace: ma,
        remain_lovelace: ma + cr + 13_000_000,
        ok: True,
      },
      Case {
        name: @"remain_out one lovelace below its floor",
        long_is_ada: True,
        grace: False,
        taken: 1_000_000,
        remainder: 200_000,
        liquidator_lovelace: ma + 1_000_000,
        remain_lovelace: ma + cr + 199_999,
        ok: False,
      },
    ]
  list.all(
    tests,
    fn(case) {
      let Case {
        long_is_ada,
        grace,
        taken,
        remainder,
        liquidator_lovelace,
        remain_lovelace,
        ok,
        ..
      } = case
      lovelace_equations(
        if long_is_ada {
          loan_utils.ada
        } else {
          token
        },
        taken,
        remainder,
        cr,
        liquidator_lovelace,
        remain_lovelace,
        if grace {
          Some(ma - cr)
        } else {
          None
        },
      ) == ok
    },
  )
}

test structural_lovelace_balances_on_both_arms() {
  // §11.2.7 — on the ordinary arm the two burned UTxOs bring `2 × min_ada`
  // against `2 × min_ada + collector_reward` of structural lovelace, so the
  // liquidator tops up `collector_reward` and is repaid out of `reward`. On the
  // grace arm the payout's third `min_ada` covers both that and the tip.
  let tests =
    [
      // (utxos_consumed, tip_paid, topped_up_by_the_liquidator)
      (2, False, cr), (3, True, 0),
    ]
  list.all(
    tests,
    fn((utxos, tip_paid, expected_topup)) {
      let structural =
        ma + ma + cr + if tip_paid {
          ma - cr
        } else {
          0
        }
      structural - utxos * ma == expected_topup
    },
  )
}

test seizure_arithmetic_over_the_shortfall_boundary() {
  // §2.13 to §2.15 — `seized` ceilings and `repaid` floors, so `repaid` may
  // exceed `debt_now`; §11.2.7 requires `reward == reward_floor` only where the
  // collateral did not cover the debt.
  let tests =
    [
      // (debt, p_num, p_den, collateral, reward, taken, remainder, repaid, shortfall, covered)
      (1_000, 1, 1, 2_000, 100, 1_100, 900, 1_000, 0, True),
      // the collateral binds: seized is clamped and a shortfall is booked
      (1_000, 1, 1, 800, 80, 800, 0, 720, 280, False),
      // §2.15's own example, scaled: debt 100 at p = 3/1 over-recovers
      (100, 3, 1, 1_000, 0, 34, 966, 102, 0, True),
    ]
  list.all(
    tests,
    fn(
      (
        debt,
        num,
        den,
        collateral,
        reward,
        exp_taken,
        exp_remainder,
        exp_repaid,
        exp_shortfall,
        exp_covered,
      ),
    ) {
      let p = PRational { numerator: num, denominator: den }
      let seized = loan_utils.seized(debt, p, collateral, reward)
      let taken = seized + reward
      let repaid = loan_utils.repaid(seized, p)
      and {
        taken == exp_taken,
        collateral - taken == exp_remainder,
        repaid == exp_repaid,
        loan_utils.shortfall(debt, repaid) == exp_shortfall,
        seized >= loan_utils.debt_in_long(debt, p) == exp_covered,
      }
    },
  )
}
