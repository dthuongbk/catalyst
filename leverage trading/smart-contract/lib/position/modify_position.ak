//// Biz spec §16 — modify position. No value moves.

use aiken/collection/list
use cardano/address.{Address, Script}
use cardano/assets.{Value}
use cardano/transaction.{Input, Output, Redeemer, ScriptPurpose}
use constants
use position/utils as position_utils
use types.{PositionDatum, ProtocolDatum, ScriptHash}
use utils

pub fn validate(
  position_in: Input,
  position_out: Output,
  owner_in: Input,
  position_in_idx: Int,
  position_owner_in_idx: Int,
  protocol_config_ref_idx: Int,
  protocol: Option<ProtocolDatum>,
  position_skh: ScriptHash,
  inputs: List<Input>,
  mint: Value,
  redeemers: Pairs<ScriptPurpose, Redeemer>,
) -> Bool {
  let Input { output: position_in_out, .. } = position_in
  // §16.2.1
  let (position_in_datum, position_nft_name, position_in_address) =
    position_utils.position_shape(position_in_out, position_skh)
  let Output { value: position_in_value, .. } = position_in_out

  // §16.2.2
  let Input { output: Output { value: owner_in_value, .. }, .. } = owner_in
  let position_owner_nft_name =
    utils.suffixed(position_nft_name, constants.owner_nft_suffix)
  expect
    assets.quantity_of(owner_in_value, position_skh, position_owner_nft_name) == 1
  expect position_owner_in_idx != position_in_idx
  // §16.2.10
  expect
    position_utils.owner_input_consents(
      owner_in,
      position_owner_in_idx,
      protocol_config_ref_idx,
      protocol,
      redeemers,
    )

  // §16.2.4, and the position shape of item 1 on the output side.
  let (position_out_datum, position_out_nft_name, position_out_address) =
    position_utils.position_shape(position_out, position_skh)
  expect position_out_nft_name == position_nft_name
  expect position_out_address == position_in_address
  let Output { value: position_out_value, .. } = position_out

  // §16.2.3 — decisively, the `LoanOwnerNFT` stays: §10.1.1, §11.2.1 and §12.3.1
  // each require one input holding both.
  expect
    assets.without_lovelace(position_out_value) == assets.without_lovelace(
      position_in_value,
    )
  // §16.2.5
  expect assets.lovelace_of(position_out_value) >= constants.min_ada

  // §16.2.6
  expect position_out_datum.long_token == position_in_datum.long_token
  expect position_out_datum.max_slippage == position_in_datum.max_slippage
  expect position_out_datum.beneficiary == position_in_datum.beneficiary

  // §16.2.7 — no `market_param` reference input is read: this redeemer holds
  // neither a loan nor an order, so §5 rule 3 could pin none.
  expect position_out_datum.take_profit_price.numerator >= 0
  expect position_out_datum.take_profit_price.denominator > 0
  expect
    position_out_datum.min_execution_amount >= position_in_datum.min_execution_amount

  // §16.2.8's `mint[loan_skh]` half, and §16.2.9's spend half, both only where the
  // registry is resolved — §16.2.10 admits `-1` for a wallet-held owner NFT.
  // `mint[position_skh]` is the withdrawal's own zero.
  when protocol is {
    Some(ProtocolDatum { loan_skh, pool_skh, .. }) -> and {
        (utils.tokens_of(mint, loan_skh) == [])?,
        list.all(
          inputs,
          fn(
            Input {
              output: Output { address: Address { payment_credential, .. }, .. },
              ..
            },
          ) {
            and {
              payment_credential != Script(loan_skh),
              payment_credential != Script(pool_skh),
            }
          },
        )?,
      }
    None -> True
  }?
}
