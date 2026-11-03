//// Position-side helpers. The registry resolution and the validity-range rule are
//// deliberately not shared with `order/utils`: the two script families stay
//// independent, as they are in the deployed contract.

use aiken/collection/list
use aiken/interval.{Finite, Interval, IntervalBound}
use cardano/address.{Address, Script}
use cardano/assets.{AssetName}
use cardano/transaction.{
  InlineDatum, Input, Output, Redeemer, ScriptPurpose, Spend, ValidityRange,
}
use constants
use daken/pairs as daken_pairs
use daken/types.{TupleAsset} as daken_types
use daken/util as daken_util
use types.{
  ModifyOrderIndexer, OrderRedeemer, PositionDatum, ProtocolDatum, ScriptHash,
}
use utils

/// §5 rule 1.
pub fn tx_bounds(validity_range: ValidityRange) -> (Int, Int) {
  let Interval { lower_bound, upper_bound } = validity_range
  expect IntervalBound { bound_type: Finite(tx_start), .. } = lower_bound
  expect IntervalBound { bound_type: Finite(tx_end), .. } = upper_bound
  expect tx_start > 0
  expect tx_end - tx_start <= constants.max_validity_window
  (tx_start, tx_end)
}

/// §5 rules 2 and 3. `None` where the redeemer carries `-1`, which §16.2.10 admits
/// for a wallet-held owner NFT and no other arm does.
pub fn protocol_config(
  reference_inputs: List<Input>,
  idx: Int,
  protocol_nft: TupleAsset,
) -> Option<ProtocolDatum> {
  if idx == -1 {
    None
  } else {
    expect protocol: ProtocolDatum =
      daken_util.get_inline_datum_by_idx_and_nft(
        reference_inputs,
        idx,
        protocol_nft,
      )
    Some(protocol)
  }
}

/// The shape every position UTxO has: at `Script(position_skh)`, an inline
/// `PositionDatum` parsing strictly, no reference script, and exactly one token of
/// `position_skh` — §7.2.19, §10.1.1, §11.2.1, §16.2.1. The suffix test bars the
/// `PositionOwnerNFT`, which shares the policy, from standing in for the
/// `PositionNFT`.
pub fn position_shape(
  Output { address, value, datum, reference_script }: Output,
  position_skh: ScriptHash,
) -> (PositionDatum, AssetName, Address) {
  expect utils.at_script(address, position_skh)
  expect reference_script == None
  expect InlineDatum(position_data) = datum
  expect position: PositionDatum = position_data
  expect [(position_nft_name, 1)] = utils.tokens_of(value, position_skh)
  expect !utils.is_suffixed_nft(position_nft_name, constants.owner_nft_suffix)
  (position, position_nft_name, address)
}

/// The datum sanity §16.2.7 states and §7.2.19 inherits from the order it copies.
pub fn valid_position_params(position: PositionDatum) -> Bool {
  and {
    (position.take_profit_price.numerator >= 0)?,
    (position.take_profit_price.denominator > 0)?,
    (position.min_execution_amount > 0)?,
    (position.max_slippage > 0)?,
  }
}

/// The `LoanOwnerNFT` this position holds — the pairing §10.1.1, §11.2.1, §12.3.1
/// and §12.4.1 all require, read from the position side.
pub fn holds_loan_owner_nft(
  position_value: assets.Value,
  loan_skh: ScriptHash,
  owner_nft: Option<TupleAsset>,
) -> Bool {
  expect Some((pid, name)) = owner_nft
  and {
    (pid == loan_skh)?,
    (assets.quantity_of(position_value, loan_skh, name) == 1)?,
  }
}

/// §16.2.10, and §10.1.3 / §10.2.1's second case. Where the owner input sits at a
/// script address the registry must be resolved, and where that credential is
/// `Script(order_skh)` the transaction must carry a `Spend` at that input's own
/// `OutputReference` whose `OrderRedeemer` contains a `ModifyOrderIndexer` naming
/// it. Without it a `PositionOwnerNFT` parked inside an order UTxO authorises this
/// action while the order is spent under some **other** order action, and the
/// position's owner never consents.
pub fn owner_input_consents(
  Input {
    output_reference,
    output: Output { address: Address { payment_credential, .. }, .. },
  }: Input,
  owner_in_idx: Int,
  protocol_config_ref_idx: Int,
  protocol: Option<ProtocolDatum>,
  redeemers: Pairs<ScriptPurpose, Redeemer>,
) -> Bool {
  when payment_credential is {
    Script(skh) -> {
      expect protocol_config_ref_idx != -1
      expect Some(ProtocolDatum { order_skh, .. }) = protocol
      if skh == order_skh {
        expect order_redeemer: OrderRedeemer =
          daken_pairs.get_first(redeemers, Spend(output_reference))
        list.any(
          order_redeemer.order_actions,
          fn(action) {
            when action is {
              ModifyOrderIndexer { order_in_idx, .. } ->
                order_in_idx == owner_in_idx
              _ -> False
            }
          },
        )?
      } else {
        True
      }
    }
    _ -> True
  }
}
