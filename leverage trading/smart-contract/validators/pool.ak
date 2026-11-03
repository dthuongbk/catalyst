use aiken/collection/dict.{Dict}
use aiken/collection/list
use cardano/address.{Address, Credential, Script}
use cardano/assets.{AssetName, PolicyId, Value}
use cardano/transaction.{
  Input, Output, OutputReference, Redeemer, ScriptPurpose, Transaction,
  ValidityRange, Withdraw,
}
use daken/bitset
use daken/flist
use daken/pairs as daken_pairs
use daken/types.{TupleAsset} as daken_types
use daken/util as daken_util
use pool/pool_flow
use pool/rebalance_alt
use pool/topup_withdraw
use pool/withdraw_fee
use types.{
  AdapterEntry, PoolAction, PoolFlow, PoolRedeemer, ProtocolDatum, RebalanceAlt,
  ScriptHash, TopupWithdraw, WithdrawFee,
}

/// The `dToken` policy is the pool script's own, and the pool UTxO lives at
/// `Script(pool_skh)` — biz spec §5 rule 3, where the address is what separates
/// the pool from the `market_param` UTxO carrying the same NFT.
validator pool(protocol_nft: TupleAsset) {
  mint(
    mint_redeemer: PoolRedeemer,
    policy_id: PolicyId,
    Transaction { redeemers, .. }: Transaction,
  ) {
    expect withdraw_rdmr: PoolRedeemer =
      daken_pairs.get_first(redeemers, Withdraw(Script(policy_id)))
    (withdraw_rdmr == mint_redeemer)?
  }

  // biz spec §5 rule 16
  spend(
    _datum: Option<Data>,
    PoolRedeemer { pool_actions, .. } as spend_redeemer: PoolRedeemer,
    out_ref: OutputReference,
    Transaction { inputs, redeemers, .. }: Transaction,
  ) {
    list.any(
      pool_actions,
      fn(action: PoolAction) {
        spends_the_named_input(
          out_ref,
          inputs,
          pool_in_idx_of(action),
          redeemers,
          spend_redeemer,
        )
      },
    )?
  }

  withdraw(
    PoolRedeemer { pool_actions, protocol_config_ref_idx }: PoolRedeemer,
    cred: Credential,
    Transaction {
      inputs,
      reference_inputs,
      outputs,
      mint,
      redeemers,
      validity_range,
      ..
    }: Transaction,
  ) {
    expect Script(pool_skh) = cred
    // §5 rule 2
    expect (protocol_config_ref_idx != -1)?
    expect ProtocolDatum {
      pool_skh: registry_pool_skh,
      loan_skh,
      config_pool_skh,
      order_skh,
      position_skh,
      adapters,
      admin_nft,
      oracle_skh,
      ..
    }: ProtocolDatum =
      daken_util.get_inline_datum_by_idx_and_nft(
        reference_inputs,
        protocol_config_ref_idx,
        protocol_nft,
      )
    expect (registry_pool_skh == pool_skh)?
    // §17.14, §18.9a and §19.9a — items 8, 9 and 10 of those arms are absolute
    // equations, so a second action sharing the pool would contradict them.
    expect or {
        list.all(pool_actions, is_pool_flow),
        list.length(pool_actions) == 1,
      }?
    let (minted, _in_bits, _out_bits) =
      walk_actions(
        pool_actions,
        dict.empty,
        0,
        0,
        pool_skh,
        config_pool_skh,
        loan_skh,
        order_skh,
        position_skh,
        oracle_skh,
        admin_nft,
        adapters,
        inputs,
        outputs,
        reference_inputs,
        redeemers,
        mint,
        validity_range,
      )
    // §5 rule 10 — the total is compared once per policy, and an arm that states
    // no contribution contributes zero.
    (minted == assets.tokens(mint, pool_skh))?
  }

  else(_) {
    fail
  }
}

fn is_pool_flow(action: PoolAction) -> Bool {
  when action is {
    PoolFlow { .. } -> True
    _ -> False
  }
}

fn pool_in_idx_of(action: PoolAction) -> Int {
  when action is {
    PoolFlow { pool_in_idx, .. } -> pool_in_idx
    RebalanceAlt { pool_in_idx, .. } -> pool_in_idx
    TopupWithdraw { pool_in_idx, .. } -> pool_in_idx
    WithdrawFee { pool_in_idx, .. } -> pool_in_idx
  }
}

fn spends_the_named_input(
  out_ref: OutputReference,
  inputs: List<Input>,
  pool_in_idx: Int,
  redeemers: Pairs<ScriptPurpose, Redeemer>,
  spend_redeemer: PoolRedeemer,
) -> Bool {
  let Input {
    output_reference,
    output: Output { address: Address { payment_credential, .. }, .. },
  } = flist.at(inputs, pool_in_idx)
  if output_reference == out_ref {
    expect withdraw_rdmr: PoolRedeemer =
      daken_pairs.get_first(redeemers, Withdraw(payment_credential))
    expect withdraw_rdmr == spend_redeemer
    True
  } else {
    False
  }
}

fn walk_actions(
  actions: List<PoolAction>,
  minted: Dict<AssetName, Int>,
  in_bits: Int,
  out_bits: Int,
  pool_skh: PolicyId,
  config_pool_skh: PolicyId,
  loan_skh: PolicyId,
  order_skh: PolicyId,
  position_skh: PolicyId,
  oracle_skh: ByteArray,
  admin_nft: TupleAsset,
  adapters: Pairs<ScriptHash, AdapterEntry>,
  inputs: List<Input>,
  outputs: List<Output>,
  reference_inputs: List<Input>,
  redeemers: Pairs<ScriptPurpose, Redeemer>,
  mint: Value,
  validity_range: ValidityRange,
) -> (Dict<AssetName, Int>, Int, Int) {
  when actions is {
    [] -> (minted, in_bits, out_bits)
    [action, ..rest] -> {
      // §5 rule 12 — input indices are pairwise distinct from one another and
      // output indices from one another, across every action of the redeemer.
      // `market_ref_idx` and `admin_in_idx` are exempt: a reference input or an
      // authorisation input may serve several actions.
      let (minted, in_bits, out_bits) =
        when action is {
          PoolFlow { pool_in_idx, pool_out_idx, market_ref_idx, loans } -> {
            expect
              pool_flow.validate(
                pool_skh,
                config_pool_skh,
                loan_skh,
                oracle_skh,
                pool_in_idx,
                pool_out_idx,
                market_ref_idx,
                loans,
                inputs,
                outputs,
                reference_inputs,
                redeemers,
                mint,
                validity_range,
              )
            (
              minted,
              bitset.must_add(in_bits, pool_in_idx),
              bitset.must_add(out_bits, pool_out_idx),
            )
          }
          RebalanceAlt {
            pool_in_idx,
            pool_out_idx,
            admin_in_idx,
            market_ref_idx,
          } -> {
            expect
              rebalance_alt.validate(
                pool_skh,
                config_pool_skh,
                loan_skh,
                order_skh,
                position_skh,
                oracle_skh,
                admin_nft,
                adapters,
                pool_in_idx,
                pool_out_idx,
                admin_in_idx,
                market_ref_idx,
                inputs,
                outputs,
                reference_inputs,
                redeemers,
                mint,
                validity_range,
              )
            (
              minted,
              bitset.must_add(in_bits, pool_in_idx),
              bitset.must_add(out_bits, pool_out_idx),
            )
          }
          TopupWithdraw {
            pool_in_idx,
            pool_out_idx,
            market_ref_idx,
            fee_out_idx,
          } -> {
            let (dtoken_name, dtoken_qty) =
              topup_withdraw.validate(
                pool_skh,
                config_pool_skh,
                loan_skh,
                order_skh,
                position_skh,
                oracle_skh,
                adapters,
                pool_in_idx,
                pool_out_idx,
                market_ref_idx,
                fee_out_idx,
                inputs,
                outputs,
                reference_inputs,
                redeemers,
                mint,
                validity_range,
              )
            (
              minted |> dict.insert(dtoken_name, dtoken_qty),
              bitset.must_add(in_bits, pool_in_idx),
              bitset.must_add(out_bits, pool_out_idx)
                |> add_optional(fee_out_idx),
            )
          }
          WithdrawFee {
            pool_in_idx,
            pool_out_idx,
            admin_in_idx,
            market_ref_idx,
            fee_out_idx,
          } -> {
            expect
              withdraw_fee.validate(
                pool_skh,
                config_pool_skh,
                loan_skh,
                order_skh,
                position_skh,
                oracle_skh,
                admin_nft,
                adapters,
                pool_in_idx,
                pool_out_idx,
                admin_in_idx,
                market_ref_idx,
                fee_out_idx,
                inputs,
                outputs,
                reference_inputs,
                redeemers,
                mint,
                validity_range,
              )
            (
              minted,
              bitset.must_add(in_bits, pool_in_idx),
              bitset.must_add(out_bits, pool_out_idx)
                |> add_optional(fee_out_idx),
            )
          }
        }
      walk_actions(
        rest,
        minted,
        in_bits,
        out_bits,
        pool_skh,
        config_pool_skh,
        loan_skh,
        order_skh,
        position_skh,
        oracle_skh,
        admin_nft,
        adapters,
        inputs,
        outputs,
        reference_inputs,
        redeemers,
        mint,
        validity_range,
      )
    }
  }
}

/// `-1` means the index is absent — biz spec §5 rule 13 — and several actions
/// may carry it for the same field.
fn add_optional(bits: Int, idx: Int) -> Int {
  if idx == -1 {
    bits
  } else {
    bitset.must_add(bits, idx)
  }
}
