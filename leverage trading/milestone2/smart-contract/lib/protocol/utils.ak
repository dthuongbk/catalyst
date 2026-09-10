//// Helpers shared by the registry-owning validators — `protocol_config` (biz
//// spec §14) and `market_param` (§15) — and by the adapters, which resolve
//// `loan_skh`, `order_skh`, `position_skh`, `config_pool_skh` and `cancel_skh`
//// from the same registry.

use aiken/interval.{Finite, Interval, IntervalBound}
use aiken/primitive/bytearray
use cardano/address.{Address}
use cardano/assets.{PolicyId, Value}
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, ValidityRange,
}
use constants
use daken/flist
use daken/tokens
use daken/types.{TupleAsset} as daken_types
use daken/util as daken_util
use types.{ProtocolDatum}

/// §5 rule 1. An open bound would make every `expiry - tx_end` bound and every
/// `tx_start > claim.expiry` gate vacuous.
pub fn tx_bounds(range: ValidityRange) -> (Int, Int) {
  let Interval {
    lower_bound: IntervalBound { bound_type: lower, .. },
    upper_bound: IntervalBound { bound_type: upper, .. },
  } = range
  expect Finite(tx_start) = lower
  expect Finite(tx_end) = upper
  expect tx_start > 0
  expect tx_end - tx_start <= constants.max_validity_window
  (tx_start, tx_end)
}

/// The registry read as a reference input — §5 rules 2 and 3. `protocol_nft`
/// alone authenticates it: quantity 1, minted once, never burned, at a name
/// distinct from the `AdminNFT` beside it, so no address is required.
pub fn registry_ref(
  reference_inputs: List<Input>,
  protocol_config_ref_idx: Int,
  protocol_nft: TupleAsset,
) -> ProtocolDatum {
  expect protocol_config_ref_idx != -1
  expect datum: ProtocolDatum =
    daken_util.get_inline_datum_by_idx_and_nft(
      reference_inputs,
      protocol_config_ref_idx,
      protocol_nft,
    )
  datum
}

/// The registry read as the **spent** input — §14. `protocol_in_idx` locates it
/// and, per §5 rule 16, must be the very output reference being spent.
pub fn registry_spent(
  inputs: List<Input>,
  protocol_in_idx: Int,
  own_ref: OutputReference,
  protocol_nft: TupleAsset,
) -> (Output, ProtocolDatum) {
  let Input { output_reference, output } = flist.at(inputs, protocol_in_idx)
  expect output_reference == own_ref
  expect tokens.contains_nft(output.value, protocol_nft)
  expect InlineDatum(raw) = output.datum
  expect datum: ProtocolDatum = raw
  (output, datum)
}

/// The address of the input this `Spend` is running for. `CreateProtocol` has no
/// registry input to pin its output against — §14.2.3a — so the genesis address
/// comes from here.
pub fn own_address(inputs: List<Input>, own_ref: OutputReference) -> Address {
  expect Some(Input { output: Output { address, .. }, .. }) =
    inputs
      |> daken_util.find_map(
          fn(input: Input) {
            if input.output_reference == own_ref {
              Some(input)
            } else {
              None
            }
          },
        )
  address
}

/// §14.2.1 / §15.2.2 — the input at `admin_in_idx` holds the registry's
/// `admin_nft`, quantity 1. Presence of the NFT is the whole authorisation.
pub fn admin_authorises(
  inputs: List<Input>,
  admin_in_idx: Int,
  admin_nft: TupleAsset,
) -> Bool {
  let Input { output: Output { value, .. }, .. } =
    flist.at(inputs, admin_in_idx)
  tokens.contains_nft(value, admin_nft)
}

/// The single asset of `policy` an authorising input holds, as a whole asset.
/// §5 rule 14 keeps `admin_nft_suffix` out of the recognition rules, so nothing
/// about the name is asserted here.
pub fn sole_asset_of(value: Value, policy: PolicyId) -> TupleAsset {
  (policy, tokens.get_nft_name(value, policy))
}

/// §5 rule 8 — a replaced script output keeps its address in **both**
/// credentials, and carries no reference script.
pub fn replaces_output(out: Output, in_out: Output) -> Bool {
  and {
    out.address == in_out.address,
    out.reference_script == None,
  }
}

/// §14.2.3a — a script hash is `nft_name_len` bytes; the empty bytestring is not
/// a script but the **lovelace** policy.
pub fn is_script_hash(skh: ByteArray) -> Bool {
  bytearray.length(skh) == constants.nft_name_len
}
