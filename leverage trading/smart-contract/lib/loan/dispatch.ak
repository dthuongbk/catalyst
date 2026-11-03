//// The loan lifecycle, shared by the three scripts that host it.
////
//// The six arms do not fit in one validator: `maxTxSize` is 16_384 bytes and the
//// six together compile to 23_057. Each arm's logic therefore lives in exactly
//// one host script's `Withdraw`, and every other purpose that a transaction
//// touches requires that host's withdrawal carrying an **equal** redeemer —
//// biz spec §5 rule 16. `host_of` is the single place that mapping is written.

use aiken/collection/dict.{Dict}
use aiken/collection/list
use cardano/address.{Script}
use cardano/assets.{AssetName, Value}
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, Redeemer, ScriptPurpose,
  Transaction, Withdraw,
}
use daken/flist
use daken/pairs as daken_pairs
use loan/collect_remain
use loan/liquidate
use loan/open_direct
use loan/open_loan
use loan/repay_loan
use loan/rollback
use loan/settle_claim
use loan/utils.{Contribution, Registry} as loan_utils
use types.{
  CollectRemain, Liquidate, LoanAction, LoanDatum, LoanRedeemer, OpenDirect, OpenLoan, OrderDatum, RepayLoan, Rollback, SettleClaim,
}
use utils

/// Which script hosts an arm's logic. Every purpose that needs the arm validated
/// requires a withdrawal from this hash with an equal redeemer.
pub fn host_of(action: LoanAction, registry: Registry) -> ByteArray {
  when action is {
    OpenLoan { .. } -> registry.loan_skh
    // §7.6 opens a loan, so it hosts where opening hosts — §5 rule 18.
    OpenDirect { .. } -> registry.loan_skh
    SettleClaim { .. } -> registry.loan_skh
    Liquidate { .. } -> registry.loan_close_skh
    RepayLoan { .. } -> registry.loan_repay_skh
    Rollback { .. } -> registry.loan_close_skh
    CollectRemain { .. } -> registry.loan_close_skh
  }
}

/// §5 rule 10 and §7.2.18's residual. `LoanNFT` is minted under `registry.loan_skh`
/// whichever script hosts the arm, so the comparison is always against that policy
/// and never against the host's own credential.
pub fn finalize(
  total: Contribution,
  registry: Registry,
  tx: Transaction,
) -> Bool {
  and {
    (as_dict(total.loan_mint) == assets.tokens(tx.mint, registry.loan_skh))?,
    (total.retired >= 0)?,
    (total.shortfall >= 0)?,
  }
}

/// The input indices a `Spend` of this script may be pinned to, per arm.
pub fn spendable_idxs(action: LoanAction) -> List<Int> {
  when action is {
    OpenLoan { .. } -> []
    // §7.6 spends no loan: it creates one.
    OpenDirect { .. } -> []
    SettleClaim { claims, .. } ->
      list.flat_map(claims, fn(c) { [c.loan_in_idx, c.payout_in_idx] })
    RepayLoan { loans, .. } ->
      list.flat_map(loans, fn(l) { [l.loan_in_idx, l.payout_in_idx] })
    Liquidate { loan_in_idx, payout_in_idx, .. } -> [loan_in_idx, payout_in_idx]
    Rollback { loan_in_idx, refund_in_idx, .. } -> [loan_in_idx, refund_in_idx]
    CollectRemain { remains, .. } ->
      list.map(remains, fn(r) { r.remain_in_idx })
  }
}

pub fn spends_the_named_input(
  out_ref: OutputReference,
  inputs: List<Input>,
  idx: Int,
  redeemers: Pairs<ScriptPurpose, Redeemer>,
  spend_redeemer: LoanRedeemer,
  host: ByteArray,
) -> Bool {
  if idx == -1 {
    False
  } else {
    let Input { output_reference, .. } = flist.at(inputs, idx)
    if output_reference == out_ref {
      expect withdraw_rdmr: LoanRedeemer =
        daken_pairs.get_first(redeemers, Withdraw(Script(host)))
      expect withdraw_rdmr == spend_redeemer
      True
    } else {
      False
    }
  }
}

/// Sums a contribution list into the sorted shape `assets.tokens` returns, so the
/// comparison is order-independent and duplicate names add up.
pub fn as_dict(entries: List<(AssetName, Int)>) -> Dict<AssetName, Int> {
  list.foldl(
    entries,
    dict.empty,
    fn((name, qty), acc) {
      when dict.get(acc, name) is {
        Some(prev) ->
          if prev + qty == 0 {
            dict.delete(acc, name)
          } else {
            dict.insert(acc, name, prev + qty)
          }
        None ->
          if qty == 0 {
            acc
          } else {
            dict.insert(acc, name, qty)
          }
      }
    },
  )
}

/// The market an order belongs to, from its own datum.
pub fn order_market_of(inputs: List<Input>, order_in_idx: Int) -> AssetName {
  expect InlineDatum(raw) = flist.at(inputs, order_in_idx).output.datum
  expect OrderDatum { market_nft_name, .. }: OrderDatum = raw
  market_nft_name
}

/// A fresh loan's `LoanOwnerNFT` name, read off the output it is written into.
/// §7.2.12 names the `LoanNFT` for the market, so a loan output says which
/// market it belongs to. §7.2.19 puts the `LoanOwnerNFT` on the position, so this
/// is the only token of `loan_skh` a loan output holds.
pub fn loan_market_name_of(loan_out: Output, loan_skh: ByteArray) -> AssetName {
  expect [(name, 1)] = utils.tokens_of(loan_out.value, loan_skh)
  name
}

pub fn loan_owner_name_of(loan_out: Output) -> AssetName {
  expect InlineDatum(raw) = loan_out.datum
  expect LoanDatum { owner_nft: Some((_pid, name)), .. }: LoanDatum = raw
  name
}

/// `-1` means the arm does not spend the pool, so there is nothing to read.
pub fn pool_index_or_zero(outputs: List<Output>, pool_out_idx: Int) -> Int {
  if pool_out_idx == -1 {
    0
  } else {
    loan_utils.pool_out_index(outputs, pool_out_idx)
  }
}

pub fn pool_value_or_zero(inputs: List<Input>, pool_in_idx: Int) -> Value {
  if pool_in_idx == -1 {
    assets.zero
  } else {
    flist.at(inputs, pool_in_idx).output.value
  }
}

pub fn pool_out_value_or_zero(outputs: List<Output>, pool_out_idx: Int) -> Value {
  if pool_out_idx == -1 {
    assets.zero
  } else {
    flist.at(outputs, pool_out_idx).value
  }
}

pub fn add(a: Contribution, b: Contribution) -> Contribution {
  Contribution {
    loan_mint: list.concat(a.loan_mint, b.loan_mint),
    opened_proceeds: a.opened_proceeds + b.opened_proceeds,
    retired: a.retired + b.retired,
    shortfall: a.shortfall + b.shortfall,
  }
}

/// The arms the `loan` script itself hosts — §7.2 and §8.
pub fn walk_core(
  actions: List<LoanAction>,
  acc: Contribution,
  registry: Registry,
  tx: Transaction,
) -> Contribution {
  when actions is {
    [] -> acc
    [action, ..rest] -> {
      let (tx_start, tx_end) = loan_utils.valid_range(tx.validity_range)
      let one =
        when action is {
          OpenLoan { loans, market_ref_idx, pool_out_idx, adapter_skh, .. } -> {
            let declarations = loan_utils.declarations_of(tx.redeemers, adapter_skh)
            expect (list.length(declarations) == list.length(loans))?
            list.foldl(
              loans,
              loan_utils.no_contribution(),
              fn(one, acc) {
                let loan_out = flist.at(tx.outputs, one.loan_out_idx)
                let market_nft_name =
                  order_market_of(tx.inputs, one.order_in_idx)
                let market =
                  loan_utils.market_at(
                    tx.reference_inputs,
                    market_ref_idx,
                    registry.config_pool_skh,
                    market_nft_name,
                  )
                let pool_out =
                  loan_utils.pool_out_datum_at(tx.outputs, pool_out_idx)
                add(
                  acc,
                  open_loan.validate(
                    registry,
                    adapter_skh,
                    market_nft_name,
                    market,
                    declarations,
                    tx.outputs,
                    tx.redeemers,
                    tx_end,
                    pool_out.interest_index,
                    pool_out.borrow_apy,
                    pool_out.interest_time,
                    flist.at(tx.inputs, one.order_in_idx),
                    loan_out,
                    loan_owner_name_of(loan_out),
                  ),
                )
              },
            )
          }

          // §7.6
          OpenDirect { loans, market_ref_idx, pool_out_idx } ->
            list.foldl(
              loans,
              loan_utils.no_contribution(),
              fn(one, acc) {
                let loan_out = flist.at(tx.outputs, one.loan_out_idx)
                // No order says which market this is, so the `LoanNFT`'s own name
                // does — §7.2.12 ties it to the market either way, and
                // `market_at` closes the loop against the market's own NFT.
                let market_nft_name =
                  loan_market_name_of(loan_out, registry.loan_skh)
                let market =
                  loan_utils.market_at(
                    tx.reference_inputs,
                    market_ref_idx,
                    registry.config_pool_skh,
                    market_nft_name,
                  )
                let pool_out =
                  loan_utils.pool_out_datum_at(tx.outputs, pool_out_idx)
                add(
                  acc,
                  open_direct.validate(
                    registry,
                    market_nft_name,
                    market,
                    tx.redeemers,
                    tx_end,
                    pool_out.interest_index,
                    pool_out.borrow_apy,
                    pool_out.interest_time,
                    loan_out,
                    flist.at(tx.outputs, one.position_out_idx),
                    loan_owner_name_of(loan_out),
                  ),
                )
              },
            )

          // §8
          SettleClaim { claims, market_ref_idx, adapter_skh } -> {
            let declarations = loan_utils.declarations_of(tx.redeemers, adapter_skh)
            let _ = market_ref_idx
            list.foldl(
              claims,
              loan_utils.no_contribution(),
              fn(one, acc) {
                let market_nft_name =
                  loan_utils.market_nft_name_of(
                    tx.inputs,
                    one.loan_in_idx,
                    registry.loan_skh,
                  )
                add(
                  acc,
                  Contribution {
                    loan_mint: settle_claim.validate(
                      registry,
                      adapter_skh,
                      market_nft_name,
                      declarations,
                      tx.inputs,
                      flist.at(tx.inputs, one.loan_in_idx),
                      flist.at(tx.inputs, one.payout_in_idx),
                      flist.at(tx.outputs, one.loan_out_idx),
                      flist.at(tx.outputs, one.tip_out_idx),
                    ),
                    opened_proceeds: 0,
                    retired: 0,
                    shortfall: 0,
                  },
                )
              },
            )
          }
          _ -> fail @"loan: this arm is hosted by another script"
        }
      walk_core(rest, add(acc, one), registry, tx)
    }
  }
}

/// The single arm `loan_repay` hosts — §10. It is the heaviest arm, and alone
/// exceeds what one script can hold beside the others.
pub fn walk_repay(
  actions: List<LoanAction>,
  acc: Contribution,
  registry: Registry,
  tx: Transaction,
) -> Contribution {
  when actions is {
    [] -> acc
    [action, ..rest] -> {
      let (tx_start, tx_end) = loan_utils.valid_range(tx.validity_range)
      let one =
        when action is {
          RepayLoan {
            loans,
            market_ref_idx,
            pool_ref_idx,
            pool_in_idx,
            pool_out_idx,
            adapter_skh,
          } -> {
            let declarations = loan_utils.declarations_of(tx.redeemers, adapter_skh)
            list.foldl(
              loans,
              loan_utils.no_contribution(),
              fn(one, acc) {
                let market_nft_name =
                  loan_utils.market_nft_name_of(
                    tx.inputs,
                    one.loan_in_idx,
                    registry.loan_skh,
                  )
                add(
                  acc,
                  repay_loan.validate(
                    registry,
                    market_nft_name,
                    loan_utils.market_at(
                      tx.reference_inputs,
                      market_ref_idx,
                      registry.config_pool_skh,
                      market_nft_name,
                    ),
                    adapter_skh,
                    declarations,
                    tx.inputs,
                    tx.outputs,
                    tx.reference_inputs,
                    tx.redeemers,
                    tx_start,
                    tx_end,
                    pool_ref_idx,
                    pool_index_or_zero(tx.outputs, pool_out_idx),
                    pool_value_or_zero(tx.inputs, pool_in_idx),
                    pool_out_value_or_zero(tx.outputs, pool_out_idx),
                    one,
                  ),
                )
              },
            )
          }
          _ -> fail @"loan: this arm is hosted by another script"
        }
      walk_repay(rest, add(acc, one), registry, tx)
    }
  }
}

/// The arms `loan_close` hosts — §11, §12 and §13: every way a loan is closed
/// other than the borrower repaying it.
pub fn walk_close(
  actions: List<LoanAction>,
  acc: Contribution,
  registry: Registry,
  tx: Transaction,
) -> Contribution {
  when actions is {
    [] -> acc
    [action, ..rest] -> {
      let (tx_start, tx_end) = loan_utils.valid_range(tx.validity_range)
      let one =
        when action is {
          // §13 — no market is read; the reward comes from `RemainDatum`
          CollectRemain { remains, collector_out_idx } ->
            collect_remain.validate(
              registry,
              tx.outputs,
              tx.inputs,
              remains,
              collector_out_idx,
            )

          // §11 — no adapter runs on either arm
          Liquidate {
            loan_in_idx,
            position_in_idx,
            payout_in_idx,
            pool_in_idx,
            pool_out_idx,
            liquidator_out_idx,
            remain_out_idx,
            tip_out_idx,
            market_ref_idx,
            reward,
          } -> {
            let market_nft_name =
              loan_utils.market_nft_name_of(
                tx.inputs,
                loan_in_idx,
                registry.loan_skh,
              )
            liquidate.validate(
              registry,
              market_nft_name,
              loan_utils.market_at(
                tx.reference_inputs,
                market_ref_idx,
                registry.config_pool_skh,
                market_nft_name,
              ),
              tx.inputs,
              tx.outputs,
              tx.redeemers,
              tx_start,
              loan_utils.pool_out_index(tx.outputs, pool_out_idx),
              loan_in_idx,
              position_in_idx,
              payout_in_idx,
              liquidator_out_idx,
              remain_out_idx,
              tip_out_idx,
              reward,
            )
          }
          Rollback {
            loan_in_idx,
            position_in_idx,
            refund_in_idx,
            loan_out_idx,
            position_out_idx,
            pool_out_idx,
            remain_out_idx,
            order_in_idx,
            order_out_idx,
            tip_out_idx,
            market_ref_idx,
            adapter_skh,
            ..
          } -> {
            let market_nft_name =
              loan_utils.market_nft_name_of(
                tx.inputs,
                loan_in_idx,
                registry.loan_skh,
              )
            rollback.validate(
              registry,
              market_nft_name,
              loan_utils.market_at(
                tx.reference_inputs,
                market_ref_idx,
                registry.config_pool_skh,
                market_nft_name,
              ),
              adapter_skh,
              loan_utils.declarations_of(tx.redeemers, adapter_skh),
              tx.inputs,
              tx.outputs,
              tx.redeemers,
              tx_start,
              pool_index_or_zero(tx.outputs, pool_out_idx),
              loan_in_idx,
              position_in_idx,
              refund_in_idx,
              loan_out_idx,
              position_out_idx,
              remain_out_idx,
              order_in_idx,
              order_out_idx,
              tip_out_idx,
            )
          }
          _ -> fail @"loan: this arm is hosted by another script"
        }
      walk_close(rest, add(acc, one), registry, tx)
    }
  }
}

// ---------------------------------------------------------------------- tests

const t_loan = #"11111111111111111111111111111111111111111111111111111111"

const t_repay = #"22222222222222222222222222222222222222222222222222222222"

const t_close = #"33333333333333333333333333333333333333333333333333333333"

fn t_registry() -> Registry {
  Registry {
    pool_skh: #"44444444444444444444444444444444444444444444444444444444",
    loan_skh: t_loan,
    loan_repay_skh: t_repay,
    loan_close_skh: t_close,
    config_pool_skh: #"55555555555555555555555555555555555555555555555555555555",
    order_skh: #"66666666666666666666666666666666666666666666666666666666",
    position_skh: #"77777777777777777777777777777777777777777777777777777777",
    oracle_skh: #"88888888888888888888888888888888888888888888888888888888",
    adapters: [],
  }
}

type HostCase {
  label: ByteArray,
  action: LoanAction,
  host: ByteArray,
}

/// §5 rule 18 — one row per arm, so an arm added later without a host shows up
/// here rather than at deploy time.
test every_arm_maps_to_exactly_one_host() {
  let cases =
    [
      HostCase {
        label: "OpenLoan",
        action: OpenLoan {
          loans: [],
          market_ref_idx: 0,
          pool_in_idx: 0,
          pool_out_idx: 0,
          adapter_skh: #"",
        },
        host: t_loan,
      },
      HostCase {
        label: "SettleClaim",
        action: SettleClaim { claims: [], market_ref_idx: 0, adapter_skh: #"" },
        host: t_loan,
      },
      HostCase {
        label: "RepayLoan",
        action: RepayLoan {
          loans: [],
          market_ref_idx: 0,
          pool_ref_idx: 0,
          pool_in_idx: 0,
          pool_out_idx: 0,
          adapter_skh: #"",
        },
        host: t_repay,
      },
      HostCase {
        label: "Liquidate",
        action: Liquidate {
          loan_in_idx: 0,
          position_in_idx: 0,
          payout_in_idx: -1,
          pool_in_idx: 0,
          pool_out_idx: 0,
          liquidator_out_idx: 0,
          remain_out_idx: -1,
          tip_out_idx: -1,
          market_ref_idx: 0,
          reward: 0,
        },
        host: t_close,
      },
      HostCase {
        label: "Rollback",
        action: Rollback {
          loan_in_idx: 0,
          position_in_idx: 0,
          refund_in_idx: 0,
          loan_out_idx: -1,
          position_out_idx: -1,
          pool_in_idx: 0,
          pool_out_idx: 0,
          remain_out_idx: -1,
          order_in_idx: -1,
          order_out_idx: -1,
          tip_out_idx: -1,
          market_ref_idx: 0,
          adapter_skh: #"",
        },
        host: t_close,
      },
      HostCase {
        label: "CollectRemain",
        action: CollectRemain { remains: [], collector_out_idx: 0 },
        host: t_close,
      },
    ]
  let registry = t_registry()
  and {
    (list.length(cases) == 6)?,
    list.all(cases, fn(c) { (host_of(c.action, registry) == c.host)? })?,
  }
}

/// The three hosts are distinct, which is the whole point: if two collapsed to
/// one hash the split would compile and deploy while one script carried both.
test the_three_hosts_are_distinct() {
  let r = t_registry()
  and {
    (r.loan_skh != r.loan_repay_skh)?,
    (r.loan_skh != r.loan_close_skh)?,
    (r.loan_repay_skh != r.loan_close_skh)?,
  }
}
