//// The loan script. It holds every loan UTxO and every `LoanNFT` is minted under
//// its hash, so all three hosts' arms pass through this validator's `Mint` and
//// `Spend` purposes — but none of them is checked here.
////
//// `Mint` and `Spend` delegate to whichever script hosts the arm, per
//// `loan/dispatch.host_of`, requiring that host's withdrawal with an **equal**
//// redeemer — biz spec §5 rule 16. This script's own `Withdraw` hosts §7.2 and
//// §8; §10 goes to `loan_repay`, and §11 with §12 and §13 go to `loan_close`.

use aiken/collection/list
use cardano/address.{Credential, Script}
use cardano/assets.{PolicyId}
use cardano/transaction.{OutputReference, Transaction, Withdraw}
use daken/pairs as daken_pairs
use daken/types.{TupleAsset} as daken_types
use loan/dispatch
use loan/utils as loan_utils
use types.{LoanAction, LoanRedeemer}

validator loan(protocol_nft: TupleAsset) {
  mint(
    LoanRedeemer { loan_actions, protocol_config_ref_idx } as mint_redeemer: LoanRedeemer,
    policy_id: PolicyId,
    Transaction { reference_inputs, redeemers, .. }: Transaction,
  ) {
    let registry =
      loan_utils.registry_at(
        reference_inputs,
        protocol_config_ref_idx,
        protocol_nft,
      )
    // Every host compares `LoanNFT` quantities against `mint[registry.loan_skh]`.
    // On an arm hosted elsewhere this script's `Withdraw` never runs, so this is
    // the only place that figure is tied to the policy actually being minted.
    expect (policy_id == registry.loan_skh)?
    // A redeemer naming arms with different hosts is rejected by whichever host
    // this resolves to: that host's walk reaches an arm it does not serve.
    expect [first, ..] = loan_actions
    expect withdraw_rdmr: LoanRedeemer =
      daken_pairs.get_first(
        redeemers,
        Withdraw(Script(dispatch.host_of(first, registry))),
      )
    (withdraw_rdmr == mint_redeemer)?
  }

  /// The loan script also holds the venue's **datum-free** payout and refund
  /// UTxOs, so a spend is admitted at `loan_in_idx`, `payout_in_idx` or
  /// `refund_in_idx` — whichever the naming action carries.
  spend(
    _datum: Option<Data>,
    LoanRedeemer { loan_actions, protocol_config_ref_idx } as spend_redeemer: LoanRedeemer,
    out_ref: OutputReference,
    Transaction { inputs, reference_inputs, redeemers, .. }: Transaction,
  ) {
    let registry =
      loan_utils.registry_at(
        reference_inputs,
        protocol_config_ref_idx,
        protocol_nft,
      )
    list.any(
      loan_actions,
      fn(action: LoanAction) {
        let host = dispatch.host_of(action, registry)
        list.any(
          dispatch.spendable_idxs(action),
          fn(idx) {
            dispatch.spends_the_named_input(
              out_ref,
              inputs,
              idx,
              redeemers,
              spend_redeemer,
              host,
            )
          },
        )
      },
    )?
  }

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
    expect (registry.loan_skh == own_skh)?
    dispatch.finalize(
      dispatch.walk_core(
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
