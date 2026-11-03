//// `protocol_config` — biz spec §14. A `Spend` and nothing else: §5 rule 16
//// names it one of the two arms that carry their own logical flow and require no
//// withdrawal.

use cardano/transaction.{OutputReference, Transaction}
use daken/types.{TupleAsset} as daken_types
use protocol/protocol_config as protocol_config_arms
use types.{ProtocolConfigRedeemer}

validator protocol_config(protocol_nft: TupleAsset) {
  spend(
    _datum: Option<Data>,
    redeemer: ProtocolConfigRedeemer,
    own_ref: OutputReference,
    Transaction { inputs, outputs, mint, validity_range, .. }: Transaction,
  ) {
    protocol_config_arms.validate(
      protocol_nft,
      redeemer,
      own_ref,
      inputs,
      outputs,
      mint,
      validity_range,
    )
  }

  else(_) {
    fail
  }
}
