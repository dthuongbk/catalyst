//// Biz spec §10's position side — the half every arm that ends or carries a
//// position shares: §10.1 the synchronous close, §10.2.1 the sell claim, §10.2.2
//// the repay once it fills, §11 the liquidation and §12.3 / §12.4 the two
//// rollbacks.
////
//// What each of those does to the loan, the pool, the payout and the residual is
//// `lib/loan/`'s. This arm proves the position: that it is a real position, that
//// the loan named it, that whoever moves it consented, and that it either survives
//// byte-identical or is burned.

use aiken/collection/pairs
use cardano/address.{Script}
use cardano/assets.{AssetName}
use cardano/transaction.{
  InlineDatum, Input, Output, Redeemer, ScriptPurpose, Withdraw,
}
use constants
use position/utils as position_utils
use types.{LoanDatum, ProtocolDatum, ScriptHash}
use utils

/// Returns this action's contribution to `mint[position_skh]`.
///
/// The arm is selected by two of the redeemer's own fields, which is the only
/// discrimination available to a script that cannot read the loan redeemer's
/// indices (§5 rule 11):
///
/// - `position_out_idx != -1` — the position survives byte-identical, and nothing
///   is burned. §10.2.1 and §12.4 are the two arms of that shape.
/// - `position_out_idx == -1` and `position_owner_in_idx != -1` — §10.1, the only
///   arm whose owner presents the `PositionOwnerNFT`, and the only one that burns
///   it (item 8).
/// - `position_out_idx == -1` and `position_owner_in_idx == -1` — §10.2.2, §11 and
///   §12.3, each permissionless and each keeping the `PositionOwnerNFT` alive so
///   the residual §13 parks stays claimable.
pub fn validate(
  position_in: Input,
  loan_in: Input,
  owner_in: Option<Input>,
  position_in_idx: Int,
  position_owner_in_idx: Int,
  loan_out_idx: Int,
  position_out_idx: Int,
  outputs: List<Output>,
  protocol_config_ref_idx: Int,
  protocol: ProtocolDatum,
  position_skh: ScriptHash,
  redeemers: Pairs<ScriptPurpose, Redeemer>,
  return: fn(List<(AssetName, Int)>) -> result,
) -> result {
  let Input { output: position_in_out, .. } = position_in
  // §10.1.1's position clause, §11.2.1's `PositionDatum` parse.
  let (_position, position_nft_name, _address) =
    position_utils.position_shape(position_in_out, position_skh)
  let Output { value: position_in_value, .. } = position_in_out
  let position_owner_nft_name =
    utils.suffixed(position_nft_name, constants.owner_nft_suffix)

  // §10.1.1 — `loan_in_datum.owner_nft` names a `LoanOwnerNFT` held by
  // `position_in`. That pairing is the whole of the position's claim on the loan,
  // and §16.2.3 is what keeps it intact.
  let Input {
    output: Output { address: loan_in_address, datum: loan_in_datum_raw, .. },
    ..
  } = loan_in
  expect utils.at_script(loan_in_address, protocol.loan_skh)
  expect InlineDatum(loan_in_data) = loan_in_datum_raw
  expect LoanDatum { owner_nft, .. }: LoanDatum = loan_in_data
  expect
    position_utils.holds_loan_owner_nft(
      position_in_value,
      protocol.loan_skh,
      owner_nft,
    )

  // The loan is spent on every arm, so its withdrawal carries the arithmetic:
  // `debt_now`, §7.2.18's one pool equation, §10.3's shortfall, §13.2's remain
  // UTxO and §10.2.2.8's tip. §5 rule 16 forces that withdrawal to exist for the
  // loan input to be spendable at all; requiring it here is what lets this arm
  // defer.
  //
  // Requiring the withdrawal to be present is the whole check here: rule 16 makes
  // it a precondition of spending the loan at all, and `lib/loan/repay_loan.ak`
  // holds the arithmetic. The position side deliberately does not duplicate it.
  //
  // Any of the **three** loan hosts satisfies it. §5 rule 18 moved §10 to
  // `loan_repay` and §11 with §12 and §13 to `loan_close`, and `loan`'s own walk
  // fails on an arm it does not serve — so naming `loan_skh` alone left every arm
  // that spends a position unbuildable.
  expect or {
      pairs.has_key(redeemers, Withdraw(Script(protocol.loan_skh))),
      pairs.has_key(redeemers, Withdraw(Script(protocol.loan_repay_skh))),
      pairs.has_key(redeemers, Withdraw(Script(protocol.loan_close_skh))),
    }

  // The loan and the position are retired together or neither is: §10.1, §10.2.2,
  // §11 and §12.3 burn both, §10.2.1 and §12.4 keep both. §5 rule 11a — this is
  // what names `loan_out_idx` on the position side.
  expect loan_out_idx == -1 == ( position_out_idx == -1 )

  when owner_in is {
    Some(owner) -> {
      expect position_owner_in_idx != -1
      // §10.1.3, §10.2.1.1 — a wallet UTxO, or the order UTxO it was parked in.
      expect
        assets.quantity_of(
          owner.output.value,
          position_skh,
          position_owner_nft_name,
        ) == 1
      expect position_owner_in_idx != position_in_idx
      // The reciprocity §16.2.10 states, applied here for the same reason: parked
      // in the order is the normal state right after a fill, which §7.2.14 pins.
      expect
        position_utils.owner_input_consents(
          owner,
          position_owner_in_idx,
          protocol_config_ref_idx,
          Some(protocol),
          redeemers,
        )
      Void
    }
    None -> {
      // §10.2.2, §11.2 and §12.3 present no owner NFT and require no signature.
      expect position_owner_in_idx == -1
      Void
    }
  }

  if position_out_idx == -1 {
    // §10.1.8, §10.2.2.7, §11.2.10, §12.3.7.
    if position_owner_in_idx == -1 {
      return([(position_nft_name, -1)])
    } else {
      return([(position_nft_name, -1), (position_owner_nft_name, -1)])
    }
  } else {
    // §10.2.1.10, §12.4.8 — byte-identical in address, value and datum. The
    // input's `reference_script` is already `None` by `position_shape`, so a full
    // record equality says exactly that and nothing more.
    expect utils.output_at(outputs, position_out_idx) == position_in_out
    // §12.4.5, §10.2.1.8 — the surviving loan stays at its own script. Its datum
    // and value are the loan withdrawal's.
    let Output { address: loan_out_address, .. } =
      utils.output_at(outputs, loan_out_idx)
    expect utils.at_script(loan_out_address, protocol.loan_skh)
    // §10.2.1.12, §12.4.10 — nothing is contributed to `mint[position_skh]`.
    return([])
  }
}
