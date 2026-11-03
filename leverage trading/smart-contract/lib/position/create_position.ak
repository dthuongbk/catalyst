//// The position side of biz spec §7.2 items 10, 11, 19 and 21.
////
//// A position exists only as the product of a fill: §7.2.19 is the whole of its
//// creation, and this arm is what accounts for `{ PositionNFT: 1,
//// PositionOwnerNFT: 1 }` in `mint[position_skh]` — §5 rule 10 needs the position
//// script's own redeemer to state it, so a fill carries this action beside its
//// `ExecuteOrderIndexer`. What ties the datum to the order that paid for it is
//// §7.2.19's equality, checked by `order/execute`, whose indices this script may
//// not read.

use cardano/assets.{AssetName}
use cardano/transaction.{Input, Output}
use constants
use daken/input_hash
use position/utils as position_utils
use types.{ProtocolDatum, ScriptHash}
use utils

/// Returns the two names this action contributes to `mint[position_skh]`.
pub fn validate(
  position_out: Output,
  position_skh: ScriptHash,
  seed_utxo: Input,
  protocol: ProtocolDatum,
  return: fn(AssetName, AssetName) -> result,
) -> result {
  let (position, position_nft_name, _address) =
    position_utils.position_shape(position_out, position_skh)
  let Output { value: position_out_value, .. } = position_out

  // §7.2.10 — one hash names the `PositionNFT` and the `LoanOwnerNFT` alike.
  let seed_name = input_hash.blake2b_224(seed_utxo)
  expect position_nft_name == seed_name

  // §7.2.19's value clause. The `LoanOwnerNFT` is what §10.1.1, §11.2.1 and
  // §12.3.1 later read the loan through, so it is pinned here by name.
  expect
    [(seed_name, 1)] == utils.tokens_of(position_out_value, protocol.loan_skh)
  expect
    utils.holds_only(
      position_out_value,
      [
        (assets.ada_policy_id, assets.ada_asset_name),
        (position_skh, position_nft_name),
        (protocol.loan_skh, seed_name),
      ],
    )
  // §7.2.21
  expect assets.lovelace_of(position_out_value) >= constants.min_ada

  expect position_utils.valid_position_params(position)

  // §7.2.11
  return(
    position_nft_name,
    utils.suffixed(position_nft_name, constants.owner_nft_suffix),
  )
}
