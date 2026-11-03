//// `adapter/sync_generic` — a withdrawal and nothing else: no spend, no mint, no
//// address, no value. 01-validator §1.

use adapter/sync_generic as sync_generic_arm
use cardano/address.{Credential, Script}
use cardano/transaction.{Transaction}
use daken/types.{TupleAsset} as daken_types
use types.{AdapterRedeemer}

validator adapter_sync_generic(protocol_nft: TupleAsset) {
  withdraw(
    redeemer: AdapterRedeemer,
    account: Credential,
    Transaction { reference_inputs, outputs, mint, validity_range, .. }: Transaction,
  ) {
    expect Script(own_skh) = account
    sync_generic_arm.withdraw(
      protocol_nft,
      own_skh,
      redeemer,
      reference_inputs,
      outputs,
      mint,
      validity_range,
    )
  }

  else(_) {
    fail
  }
}
