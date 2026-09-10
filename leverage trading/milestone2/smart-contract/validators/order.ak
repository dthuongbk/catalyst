//// The `order_skh` script. Three purposes, one redeemer.
////
//// `mint` and `spend` carry §5 rule 16: a mint is admissible only alongside a
//// `Withdraw(Script(order_skh))` bearing an equal redeemer, and a spend only where
//// the `OutputReference` being spent is the one at an `order_in_idx` that
//// withdrawal's actions name. `withdraw` holds the whole logical flow, including
//// the one exhaustiveness check §5 rule 10 makes over `mint[order_skh]`.

use aiken/collection/dict.{Dict}
use aiken/collection/list
use aiken/collection/pairs
use cardano/address.{Address, Credential, Script}
use cardano/assets.{AssetName, PolicyId}
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, Redeemer, ScriptPurpose,
  Transaction, Withdraw,
}
use daken/bitset
use daken/flist
use daken/pairs as daken_pairs
use daken/types.{TupleAsset} as daken_types
use order/create_order
use order/execute
use order/modify_order
use order/utils as order_utils
use types.{
  AdapterEntry, AdapterRedeemer, CreateOrderIndexer, ExecuteOrderIndexer,
  ModifyOrderIndexer, OrderAction, OrderRedeemer, PoolDatum, ScriptHash,
  SingleExecuteOrderIndexer,
}
use utils

validator order(protocol_nft: TupleAsset) {
  mint(
    mint_redeemer: OrderRedeemer,
    policy_id: PolicyId,
    Transaction { redeemers, .. }: Transaction,
  ) {
    expect withdraw_rdmr: OrderRedeemer =
      daken_pairs.get_first(redeemers, Withdraw(Script(policy_id)))
    (withdraw_rdmr == mint_redeemer)?
  }

  spend(
    _datum: Option<Data>,
    OrderRedeemer { order_actions, .. } as spend_redeemer: OrderRedeemer,
    out_ref: OutputReference,
    Transaction { inputs, redeemers, .. }: Transaction,
  ) {
    list.any(
      order_actions,
      fn(action: OrderAction) {
        when action is {
          ExecuteOrderIndexer { orders, .. } ->
            list.any(
              orders,
              fn(single: SingleExecuteOrderIndexer) {
                authorises_spend(
                  out_ref,
                  inputs,
                  single.order_in_idx,
                  redeemers,
                  spend_redeemer,
                )
              },
            )
          ModifyOrderIndexer { order_in_idx, .. } ->
            authorises_spend(
              out_ref,
              inputs,
              order_in_idx,
              redeemers,
              spend_redeemer,
            )
          // §5 rule 16 — `seed_utxo_idx` never authorises a spend.
          _ -> False
        }
      },
    )?
  }

  withdraw(
    OrderRedeemer { order_actions, protocol_config_ref_idx }: OrderRedeemer,
    cred: Credential,
    Transaction {
      inputs,
      reference_inputs,
      mint,
      outputs,
      redeemers,
      validity_range,
      ..
    }: Transaction,
  ) {
    expect Script(order_skh) = cred
    // §5 rule 1
    let (_tx_start, tx_end) = order_utils.tx_bounds(validity_range)
    // §5 rule 2 — every arm of this redeemer resolves the registry: §6.2.1.3 and
    // §9.2.4 both name the other four scripts, and §9.3.7 says so outright.
    let protocol =
      order_utils.protocol_config(
        reference_inputs,
        protocol_config_ref_idx,
        protocol_nft,
      )
    let
      minted,
      _seed_bitset,
      _index_bitsets,
    <-
      flist.foldl3(
        order_actions,
        dict.empty,
        0,
        (0, 0),
        fn(
          action: OrderAction,
          minted: Dict<AssetName, Int>,
          seed_bitset: Int,
          (input_bitset, output_bitset): (Int, Int),
          return,
        ) {
          when action is {
            CreateOrderIndexer { seed_utxo_idx, order_out_idx, market_ref_idx } -> {
              let (market, market_nft_name) =
                order_utils.market_at(
                  reference_inputs,
                  market_ref_idx,
                  protocol.config_pool_skh,
                )
              let
                order_nft,
                order_owner_nft,
              <-
                create_order.validate(
                  utils.output_at(outputs, order_out_idx),
                  order_skh,
                  utils.input_at(inputs, seed_utxo_idx),
                  protocol,
                  market,
                  market_nft_name,
                )
              // §6.2.4.1
              return(
                minted
                  |> must_insert(order_nft, 1)
                  |> must_insert(order_owner_nft, 1),
                bitset.must_add(seed_bitset, seed_utxo_idx),
                (input_bitset, bitset.must_add(output_bitset, order_out_idx)),
              )
            }
            ExecuteOrderIndexer {
              orders,
              market_ref_idx,
              pool_in_idx,
              pool_out_idx,
              adapter_skh,
            } -> {
              let (market, market_nft_name) =
                order_utils.market_at(
                  reference_inputs,
                  market_ref_idx,
                  protocol.config_pool_skh,
                )
              // §7.2.2 — whitelisted with `may_create`, and the credential of the
              // withdrawal that carries the declaration.
              let AdapterEntry { may_create, .. } =
                daken_pairs.get_first(protocol.adapters, adapter_skh)
              expect may_create
              expect AdapterRedeemer { declarations, .. }: AdapterRedeemer =
                daken_pairs.get_first(redeemers, Withdraw(Script(adapter_skh)))
              // §7.2.3 — one entry per loan this redeemer names. The keys are
              // hashes of pairwise-distinct seed output references, so item 10's
              // index distinctness is what makes them distinct.
              expect list.length(declarations) == list.length(orders)
              // §7.2.5's pool half — `PoolNFT` and `MarketNFT` are the same asset,
              // so the address is what tells the pool from the market.
              let Input {
                output: Output {
                  address: pool_in_address,
                  value: pool_in_value,
                  ..
                },
                ..
              } = utils.input_at(inputs, pool_in_idx)
              expect utils.at_script(pool_in_address, protocol.pool_skh)
              expect [(pool_nft_name, 1)] =
                utils.tokens_of(pool_in_value, protocol.config_pool_skh)
              expect pool_nft_name == market_nft_name
              // §7.2.20's `interest_index`. Every other field of the pool output
              // is §7.2.18's, which the pool script owns.
              let Output {
                address: pool_out_address,
                datum: pool_out_datum,
                ..
              } = utils.output_at(outputs, pool_out_idx)
              expect utils.at_script(pool_out_address, protocol.pool_skh)
              expect InlineDatum(pool_out_data) = pool_out_datum
              expect PoolDatum { interest_index, .. }: PoolDatum = pool_out_data
              // §7.2.4
              expect
                execute.no_unaccounted_script_inputs(
                  inputs,
                  protocol,
                  has_withdrawal(redeemers, protocol.loan_skh),
                  has_withdrawal(redeemers, protocol.position_skh),
                )
              let
                seed_bitset,
                input_bitset,
                output_bitset,
              <-
                flist.foldl3(
                  orders,
                  seed_bitset,
                  input_bitset,
                  output_bitset,
                  fn(
                    SingleExecuteOrderIndexer {
                      order_in_idx,
                      order_out_idx,
                      position_out_idx,
                      loan_out_idx,
                      seed_utxo_idx,
                      execution_tip_idx,
                    }: SingleExecuteOrderIndexer,
                    seed_bitset,
                    input_bitset,
                    output_bitset,
                    return,
                  ) {
                    expect
                      execute.validate(
                        utils.input_at(inputs, order_in_idx),
                        order_in_idx,
                        utils.output_at(outputs, order_out_idx),
                        utils.output_at(outputs, position_out_idx),
                        utils.output_at(outputs, loan_out_idx),
                        utils.input_at(inputs, seed_utxo_idx),
                        execution_tip_idx,
                        outputs,
                        mint,
                        protocol,
                        order_skh,
                        adapter_skh,
                        declarations,
                        market,
                        market_nft_name,
                        interest_index,
                        tx_end,
                      )
                    return(
                      bitset.must_add(seed_bitset, seed_utxo_idx),
                      bitset.must_add(input_bitset, order_in_idx),
                      add_optional(
                        bitset.must_add(output_bitset, order_out_idx)
                          |> bitset.must_add(position_out_idx)
                          |> bitset.must_add(loan_out_idx),
                        execution_tip_idx,
                      ),
                    )
                  },
                )
              // §7.2.12 — this action states nothing about `mint[order_skh]`, and
              // §5 rule 10 checks that zero.
              return(minted, seed_bitset, (input_bitset, output_bitset))
            }
            ModifyOrderIndexer {
              order_in_idx,
              order_owner_in_idx,
              order_out_idx,
              owner_release_out_idx,
              market_ref_idx,
            } ->
              if order_out_idx == -1 {
                let
                  order_nft,
                  order_owner_nft,
                <-
                  modify_order.validate_cancel(
                    utils.input_at(inputs, order_in_idx),
                    order_owner_in_idx,
                    owner_release_out_idx,
                    market_ref_idx,
                    order_skh,
                  )
                // §9.3.2
                return(
                  minted
                    |> must_insert(order_nft, -1)
                    |> must_insert(order_owner_nft, -1),
                  seed_bitset,
                  (bitset.must_add(input_bitset, order_in_idx), output_bitset),
                )
              } else {
                let (market, _market_nft_name) =
                  order_utils.market_at(
                    reference_inputs,
                    market_ref_idx,
                    protocol.config_pool_skh,
                  )
                expect
                  modify_order.validate_update(
                    utils.input_at(inputs, order_in_idx),
                    utils.output_at(outputs, order_out_idx),
                    utils.input_at(inputs, order_owner_in_idx),
                    order_in_idx,
                    order_owner_in_idx,
                    owner_release_out_idx,
                    market_ref_idx,
                    outputs,
                    mint,
                    protocol,
                    order_skh,
                    market,
                  )
                // The owner input is deliberately not tracked for distinctness:
                // one UTxO may carry many `OrderOwnerNFT`s and authorise them all
                // — §5 rule 12's authorisation-input exemption.
                return(
                  minted,
                  seed_bitset,
                  (
                    bitset.must_add(input_bitset, order_in_idx),
                    add_optional(
                      bitset.must_add(output_bitset, order_out_idx),
                      owner_release_out_idx,
                    ),
                  ),
                )
              }
          }
        },
      )
    // §5 rule 10 — one comparison per policy, over the sum of every action.
    (minted == assets.tokens(mint, order_skh))?
  }

  else(_) {
    fail
  }
}

fn authorises_spend(
  out_ref: OutputReference,
  inputs: List<Input>,
  order_in_idx: Int,
  redeemers: Pairs<ScriptPurpose, Redeemer>,
  spend_redeemer: OrderRedeemer,
) -> Bool {
  let Input {
    output_reference,
    output: Output { address: Address { payment_credential, .. }, .. },
  } = utils.input_at(inputs, order_in_idx)
  if output_reference == out_ref {
    expect withdraw_rdmr: OrderRedeemer =
      daken_pairs.get_first(redeemers, Withdraw(payment_credential))
    expect withdraw_rdmr == spend_redeemer
    True
  } else {
    False
  }
}

/// §5 rule 10 — an accumulated contribution is stated once. Two actions claiming
/// the same name would otherwise overwrite one another and the total would still
/// match.
fn must_insert(
  self: Dict<AssetName, Int>,
  key: AssetName,
  qty: Int,
) -> Dict<AssetName, Int> {
  expect !dict.has_key(self, key)
  dict.insert(self, key, qty)
}

/// §5 rule 12 — `-1` is exempt from distinctness.
fn add_optional(self: Int, idx: Int) -> Int {
  if idx == -1 {
    self
  } else {
    bitset.must_add(self, idx)
  }
}

fn has_withdrawal(
  redeemers: Pairs<ScriptPurpose, Redeemer>,
  skh: ScriptHash,
) -> Bool {
  pairs.has_key(redeemers, Withdraw(Script(skh)))
}
