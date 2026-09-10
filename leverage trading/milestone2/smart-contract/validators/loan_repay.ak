//// A **withdrawal-only** host: it never holds a UTxO and never mints. It exists
//// because the six loan arms do not fit in one validator — see `loan/dispatch.ak`.
////
//// It hosts §10 — the sync close, the sell claim and the repay on fill.
//// The `loan` script's `Mint` and `Spend` require this withdrawal with an equal
//// redeemer, which is what binds the two together — biz spec §5 rule 16.

use cardano/address.{Credential, Script}
use cardano/transaction.{Transaction}
use daken/types.{TupleAsset} as daken_types
use loan/dispatch
use loan/utils as loan_utils
use types.{LoanRedeemer}

validator loan_repay(protocol_nft: TupleAsset) {
  withdraw(
    LoanRedeemer { loan_actions, protocol_config_ref_idx }: LoanRedeemer,
    cred: Credential,
    tx: Transaction,
  ) {
    expect Script(own_skh) = cred
    // §5 rule 2
    expect (protocol_config_ref_idx != -1)?
    let registry =
      loan_utils.registry_at(
        tx.reference_inputs,
        protocol_config_ref_idx,
        protocol_nft,
      )
    expect (registry.loan_repay_skh == own_skh)?
    dispatch.finalize(
      dispatch.walk_repay(
        loan_actions,
        loan_utils.no_contribution(),
        registry,
        tx,
      ),
      registry,
      tx,
    )
  }

  else(_) {
    fail
  }
}
