//// `adapter/minswap` — a withdrawal and nothing else. Parameterised by
//// `protocol_nft` and the three Minswap hashes of adapter/02-parameterized.md.

use adapter/minswap as minswap_arm
use cardano/address.{Credential, Script}
use cardano/assets.{PolicyId}
use cardano/transaction.{Transaction}
use daken/types.{TupleAsset} as daken_types
use types.{AdapterRedeemer, ScriptHash}

validator adapter_minswap(
  protocol_nft: TupleAsset,
  venue_order_skh: ScriptHash,
  venue_pool_skh: ScriptHash,
  venue_pool_nft_policy: PolicyId,
) {
  withdraw(
    redeemer: AdapterRedeemer,
    account: Credential,
    Transaction { inputs, reference_inputs, outputs, validity_range, .. }: Transaction,
  ) {
    expect Script(own_skh) = account
    minswap_arm.withdraw(
      protocol_nft,
      venue_order_skh,
      venue_pool_skh,
      venue_pool_nft_policy,
      own_skh,
      redeemer,
      inputs,
      reference_inputs,
      outputs,
      validity_range,
    )
  }

  else(_) {
    fail
  }
}
