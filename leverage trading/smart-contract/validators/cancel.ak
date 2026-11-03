//// `cancel` — the withdrawal script §7.5's `canceller` row names, whose redeemer
//// requires `tx_start > claim.expiry`. It is the whole of §4.3's last row: past
//// expiry, anyone triggers the venue's expired-order cancel for `max_cancel_fee`,
//// and §12 then unwinds the returned claim.
////
//// 04-transaction.md records this validator as the one with **no page**, so the
//// redeemer below is not quoted from the spec. Its shape is the minimum that
//// makes the expiry gate a check on *this* cancel: `binding_nft` names the venue
//// order actually being spent, and the loan reference input is where that claim's
//// `expiry` is written. A redeemer carrying the expiry alone would let a caller
//// name `0` and cancel a resting claim at will, and one carrying only a loan
//// index would let them point at an expired claim while cancelling a live order.

use aiken/collection/list
use aiken/primitive/bytearray
use cardano/address.{Credential}
use cardano/transaction.{InlineDatum, Input, Output, Transaction}
use constants
use daken/types.{TupleAsset} as daken_types
use protocol/utils as protocol_utils
use types.{Claim, LoanDatum, ProtocolDatum, ScriptHash}
use utils

/// One venue order being cancelled. `loan_ref_idx` is a reference input: the loan
/// is not spent by a cancel, so the claim can only be read.
pub type CancelClaim {
  binding_nft: TupleAsset,
  loan_ref_idx: Int,
}

pub type CancelRedeemer {
  cancels: List<CancelClaim>,
  protocol_config_ref_idx: Int,
}

validator cancel(protocol_nft: TupleAsset) {
  withdraw(
    CancelRedeemer { cancels, protocol_config_ref_idx }: CancelRedeemer,
    _account: Credential,
    Transaction { inputs, reference_inputs, validity_range, .. }: Transaction,
  ) {
    let (tx_start, _tx_end) = protocol_utils.tx_bounds(validity_range)
    let ProtocolDatum { loan_skh, .. } =
      protocol_utils.registry_ref(
        reference_inputs,
        protocol_config_ref_idx,
        protocol_nft,
      )
    // Every `BindingNFT` this transaction takes out of a venue order. A claim is
    // all-or-nothing, so one cancelled order is one binding NFT.
    let leaving = binding_nfts_spent(inputs, loan_skh)
    and {
      (cancels != [])?,
      distinct(list.map(cancels, fn(entry: CancelClaim) { entry.binding_nft }))?,
      // A bijection between the orders leaving the venue and the claims declared:
      // equal counts, declared names distinct, and every declared name present.
      (list.length(leaving) == list.length(cancels))?,
      list.all(
        cancels,
        fn(entry: CancelClaim) {
          and {
            list.has(leaving, entry.binding_nft)?,
            expired(
              reference_inputs,
              entry.loan_ref_idx,
              loan_skh,
              entry.binding_nft,
              tx_start,
            )?,
          }
        },
      )?,
    }
  }

  else(_) {
    fail
  }
}

/// The `BindingNFT`s leaving venue orders in this transaction, recognised by §5
/// rule 14's suffix test under `loan_skh`, each at quantity 1.
fn binding_nfts_spent(
  inputs: List<Input>,
  loan_skh: ScriptHash,
) -> List<TupleAsset> {
  list.flat_map(
    inputs,
    fn(Input { output: Output { value, .. }, .. }) {
      list.filter_map(
        utils.tokens_of(value, loan_skh),
        fn(entry: (ByteArray, Int)) {
          let (name, quantity) = entry
          if utils.is_suffixed_nft(name, constants.binding_nft_suffix) {
            expect quantity == 1
            Some((loan_skh, name))
          } else {
            None
          }
        },
      )
    },
  )
}

/// The loan carrying this claim, read as a reference input, and the gate itself.
fn expired(
  reference_inputs: List<Input>,
  loan_ref_idx: Int,
  loan_skh: ScriptHash,
  binding_nft: TupleAsset,
  tx_start: Int,
) -> Bool {
  let Input { output: Output { address, value, datum, .. }, .. } =
    utils.input_at(reference_inputs, loan_ref_idx)
  expect utils.at_script(address, loan_skh)
  expect InlineDatum(raw) = datum
  expect LoanDatum { claim, .. }: LoanDatum = raw
  expect Some(Claim { binding_nft: claim_binding_nft, expiry, .. }) = claim
  expect [(loan_nft_name, 1)] = utils.tokens_of(value, loan_skh)
  and {
    // §5 rules 3 and 14 — the `LoanNFT` is `nft_name_len` bytes with no suffix,
    // which is what tells it from a `BindingNFT` or a `RemainNFT` under the same
    // policy. Only `loan` mints it, so a UTxO parked at this address by anyone
    // else cannot carry one, and a forged datum has no reachable claim.
    (bytearray.length(loan_nft_name) == constants.nft_name_len)?,
    (claim_binding_nft == binding_nft)?,
    (tx_start > expiry)?,
  }
}

fn distinct(assets_declared: List<TupleAsset>) -> Bool {
  when assets_declared is {
    [] -> True
    [head, ..rest] -> and {
        !list.has(rest, head),
        distinct(rest),
      }
  }
}
