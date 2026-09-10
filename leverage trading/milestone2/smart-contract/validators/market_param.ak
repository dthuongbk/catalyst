//// `market_param`, deployed as `config_pool_skh` — biz spec §15 and §20. Both
//// purposes are §5 rule 16 exceptions: each is authorised by the admin NFT, so
//// neither is accompanied by a withdrawal.

use cardano/assets.{PolicyId}
use cardano/transaction.{OutputReference, Transaction}
use daken/types.{TupleAsset} as daken_types
use protocol/create_market
use protocol/market_param as market_param_arm
use types.{CreateMarket, MarketParamRedeemer, UpdateMarketParam}

validator market_param(protocol_nft: TupleAsset) {
  /// §20 — the only mint this script has: one market, and the pool beside it.
  mint(
    redeemer: MarketParamRedeemer,
    _policy_id: PolicyId,
    Transaction { inputs, reference_inputs, outputs, mint, validity_range, .. }: Transaction,
  ) {
    expect CreateMarket {
      seed_utxo_idx,
      admin_in_idx,
      market_out_idx,
      pool_out_idx,
      protocol_config_ref_idx,
    } = redeemer
    create_market.validate(
      protocol_nft,
      seed_utxo_idx,
      admin_in_idx,
      market_out_idx,
      pool_out_idx,
      protocol_config_ref_idx,
      inputs,
      reference_inputs,
      outputs,
      mint,
      validity_range,
    )
  }

  spend(
    _datum: Option<Data>,
    redeemer: MarketParamRedeemer,
    own_ref: OutputReference,
    Transaction { inputs, reference_inputs, outputs, mint, validity_range, .. }: Transaction,
  ) {
    expect UpdateMarketParam { .. } = redeemer
    market_param_arm.validate(
      protocol_nft,
      redeemer,
      own_ref,
      inputs,
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
