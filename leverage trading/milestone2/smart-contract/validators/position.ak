//// The `position_skh` script. Three purposes, one redeemer, and §5 rule 10's one
//// exhaustiveness check over `mint[position_skh]`.

use aiken/collection/dict.{Dict}
use aiken/collection/list
use aiken/primitive/bytearray
use cardano/address.{Address, Credential, Script}
use cardano/assets.{AssetName, PolicyId}
use cardano/transaction.{
  Input, Output, OutputReference, Redeemer, ScriptPurpose, Transaction, Withdraw,
}
use constants
use daken/bitset
use daken/flist
use daken/pairs as daken_pairs
use daken/types.{TupleAsset} as daken_types
use position/close_position
use position/create_position
use position/modify_position
use position/utils as position_utils
use types.{
  BurnOwnerNFT, ClosePosition, CreatePosition, ModifyPosition, PositionAction,
  PositionRedeemer, ProtocolDatum, ReservedTakeProfit,
  SingleClosePositionIndexer,
}
use utils

validator position(protocol_nft: TupleAsset) {
  mint(
    mint_redeemer: PositionRedeemer,
    policy_id: PolicyId,
    Transaction { redeemers, .. }: Transaction,
  ) {
    expect withdraw_rdmr: PositionRedeemer =
      daken_pairs.get_first(redeemers, Withdraw(Script(policy_id)))
    (withdraw_rdmr == mint_redeemer)?
  }

  spend(
    _datum: Option<Data>,
    PositionRedeemer { position_actions, .. } as spend_redeemer: PositionRedeemer,
    out_ref: OutputReference,
    Transaction { inputs, redeemers, .. }: Transaction,
  ) {
    list.any(
      position_actions,
      fn(action: PositionAction) {
        when action is {
          ModifyPosition { position_in_idx, .. } ->
            authorises_spend(
              out_ref,
              inputs,
              position_in_idx,
              redeemers,
              spend_redeemer,
            )
          ClosePosition { positions } ->
            list.any(
              positions,
              fn(single: SingleClosePositionIndexer) {
                authorises_spend(
                  out_ref,
                  inputs,
                  single.position_in_idx,
                  redeemers,
                  spend_redeemer,
                )
              },
            )
          // §5 rule 16 — neither `seed_utxo_idx` nor `owner_in_idx` authorises a
          // spend of this script.
          _ -> False
        }
      },
    )?
  }

  withdraw(
    PositionRedeemer { position_actions, protocol_config_ref_idx }: PositionRedeemer,
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
    expect Script(position_skh) = cred
    // §5 rule 1
    let (_tx_start, _tx_end) = position_utils.tx_bounds(validity_range)
    // §5 rule 2. `None` only where §16.2.10 admits it — a wallet-held
    // `PositionOwnerNFT` on a `ModifyPosition`; every other arm names another
    // script and fails on `None`.
    let protocol =
      position_utils.protocol_config(
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
        position_actions,
        dict.empty,
        0,
        (0, 0),
        fn(
          action: PositionAction,
          minted: Dict<AssetName, Int>,
          seed_bitset: Int,
          (input_bitset, output_bitset): (Int, Int),
          return,
        ) {
          when action is {
            CreatePosition { seed_utxo_idx, position_out_idx } -> {
              expect Some(resolved) = protocol
              let
                position_nft,
                position_owner_nft,
              <-
                create_position.validate(
                  utils.output_at(outputs, position_out_idx),
                  position_skh,
                  utils.input_at(inputs, seed_utxo_idx),
                  resolved,
                )
              // §7.2.12's position half.
              return(
                minted
                  |> must_insert(position_nft, 1)
                  |> must_insert(position_owner_nft, 1),
                bitset.must_add(seed_bitset, seed_utxo_idx),
                (input_bitset, bitset.must_add(output_bitset, position_out_idx)),
              )
            }
            // §5 rule 15 — constructor index 1 is the deployed contract's
            // `TakeProfit`, which this version drops. It predates
            // `LoanDatum.claim` and would write `loan_amount` down while the
            // collateral sits at a venue.
            ReservedTakeProfit -> fail @"position: TakeProfit has no arm"
            ModifyPosition {
              position_in_idx,
              position_owner_in_idx,
              position_out_idx,
            } -> {
              // §16 always replaces the position, so §5 rule 11a leaves this
              // index no `-1` case.
              expect position_out_idx != -1
              expect
                modify_position.validate(
                  utils.input_at(inputs, position_in_idx),
                  utils.output_at(outputs, position_out_idx),
                  utils.input_at(inputs, position_owner_in_idx),
                  position_in_idx,
                  position_owner_in_idx,
                  protocol_config_ref_idx,
                  protocol,
                  position_skh,
                  inputs,
                  mint,
                  redeemers,
                )
              // §16.2.8 — nothing is contributed, and §5 rule 10 checks that zero.
              return(
                minted,
                seed_bitset,
                (
                  bitset.must_add(input_bitset, position_in_idx),
                  bitset.must_add(output_bitset, position_out_idx),
                ),
              )
            }
            ClosePosition { positions } -> {
              expect Some(resolved) = protocol
              let
                minted,
                input_bitset,
                output_bitset,
              <-
                flist.foldl3(
                  positions,
                  minted,
                  input_bitset,
                  output_bitset,
                  fn(
                    SingleClosePositionIndexer {
                      position_in_idx,
                      position_owner_in_idx,
                      loan_in_idx,
                      loan_out_idx,
                      position_out_idx,
                    }: SingleClosePositionIndexer,
                    minted,
                    input_bitset,
                    output_bitset,
                    return,
                  ) {
                    let owner_in =
                      if position_owner_in_idx == -1 {
                        None
                      } else {
                        Some(utils.input_at(inputs, position_owner_in_idx))
                      }
                    let burns <-
                      close_position.validate(
                        utils.input_at(inputs, position_in_idx),
                        utils.input_at(inputs, loan_in_idx),
                        owner_in,
                        position_in_idx,
                        position_owner_in_idx,
                        loan_out_idx,
                        position_out_idx,
                        outputs,
                        protocol_config_ref_idx,
                        resolved,
                        position_skh,
                        redeemers,
                      )
                    return(
                      insert_all(minted, burns),
                      bitset.must_add(input_bitset, position_in_idx)
                        |> bitset.must_add(loan_in_idx),
                      add_optional(output_bitset, position_out_idx)
                        |> add_optional(loan_out_idx),
                    )
                  },
                )
              return(minted, seed_bitset, (input_bitset, output_bitset))
            }
            BurnOwnerNFT { owner_in_idx, owner_nft_name } -> {
              expect Some(ProtocolDatum { loan_skh, .. }) = protocol
              // §5 rule 14
              expect
                utils.is_suffixed_nft(
                  owner_nft_name,
                  constants.owner_nft_suffix,
                )
              // The ledger requires the token in an input for the burn to
              // succeed; the redeemer names which input, so no scan is needed.
              let Input { output: Output { value: owner_in_value, .. }, .. } =
                utils.input_at(inputs, owner_in_idx)
              expect
                assets.quantity_of(owner_in_value, position_skh, owner_nft_name) == 1
              // §13.3's trailer — admissible only where this transaction burns
              // the matching `PositionNFT`, or spends a `RemainNFT` whose name
              // derives from it. Absence of the `PositionNFT` from the inputs is
              // **not** the test.
              let base = bytearray.take(owner_nft_name, constants.nft_name_len)
              let remain_nft_name =
                utils.suffixed(base, constants.remain_nft_suffix)
              expect or {
                  assets.quantity_of(mint, position_skh, base) == -1,
                  list.any(
                    inputs,
                    fn(Input { output: Output { value, .. }, .. }) {
                      assets.quantity_of(value, loan_skh, remain_nft_name) == 1
                    },
                  ),
                }
              // The owner input is not tracked for distinctness: one UTxO may
              // carry many owner NFTs — §5 rule 12's authorisation exemption.
              return(
                minted |> must_insert(owner_nft_name, -1),
                seed_bitset,
                (input_bitset, output_bitset),
              )
            }
          }
        },
      )
    // §5 rule 10.
    (minted == assets.tokens(mint, position_skh))?
  }

  else(_) {
    fail
  }
}

fn authorises_spend(
  out_ref: OutputReference,
  inputs: List<Input>,
  position_in_idx: Int,
  redeemers: Pairs<ScriptPurpose, Redeemer>,
  spend_redeemer: PositionRedeemer,
) -> Bool {
  let Input {
    output_reference,
    output: Output { address: Address { payment_credential, .. }, .. },
  } = utils.input_at(inputs, position_in_idx)
  if output_reference == out_ref {
    expect withdraw_rdmr: PositionRedeemer =
      daken_pairs.get_first(redeemers, Withdraw(payment_credential))
    expect withdraw_rdmr == spend_redeemer
    True
  } else {
    False
  }
}

fn must_insert(
  self: Dict<AssetName, Int>,
  key: AssetName,
  qty: Int,
) -> Dict<AssetName, Int> {
  expect !dict.has_key(self, key)
  dict.insert(self, key, qty)
}

fn insert_all(
  self: Dict<AssetName, Int>,
  entries: List<(AssetName, Int)>,
) -> Dict<AssetName, Int> {
  when entries is {
    [] -> self
    [(key, qty), ..rest] -> insert_all(must_insert(self, key, qty), rest)
  }
}

/// §5 rule 12 — `-1` is exempt from distinctness.
fn add_optional(self: Int, idx: Int) -> Int {
  if idx == -1 {
    self
  } else {
    bitset.must_add(self, idx)
  }
}
