//// Helpers the adapters share.
////
//// §5 rule 11 draws the boundary this module respects: an adapter reaches what
//// it inspects three ways and no other — its declaration's own indices, its
//// declaration's own **keys**, and its redeemer's own two reference indices. The
//// lookups below are the "keys" route: nothing here takes an index from a core
//// action.

use aiken/collection/list
use cardano/address.{Address}
use cardano/assets.{Value}
use cardano/transaction.{InlineDatum, Input, NoDatum, Output}
use constants
use daken/pairs as daken_pairs
use daken/tokens
use daken/types.{TupleAsset} as daken_types
use types.{
  AdapterEntry, Declaration, LoanDatum, MarketDatum, OrderDatum, PositionDatum,
  ScriptHash,
}
use utils

/// §7.4.3 — `binding_nft == (loan_skh, LoanOwnerNFT.asset_name ++
/// binding_nft_suffix)`, and the declaration's key **is** that asset name, so an
/// adapter derives the whole asset without reading anything.
pub fn binding_nft_of(
  loan_skh: ScriptHash,
  loan_owner_nft_name: ByteArray,
) -> TupleAsset {
  (loan_skh, utils.suffixed(loan_owner_nft_name, constants.binding_nft_suffix))
}

/// 01-validator §4.2 — `loan_owner_nft_name` values are pairwise distinct across
/// `declarations`. Without it one loan answers for another's collateral.
pub fn distinct_keys(declarations: List<Declaration>) -> Bool {
  when declarations is {
    [] -> True
    [Declaration { loan_owner_nft_name, .. }, ..rest] -> and {
        !list.any(
          rest,
          fn(other: Declaration) {
            other.loan_owner_nft_name == loan_owner_nft_name
          },
        ),
        distinct_keys(rest),
      }
  }
}

/// §5 rule 11 — the loan output is the output at `Script(loan_skh)` whose datum's
/// `owner_nft` name is the declaration's key, and **not** the `loan_out_idx` the
/// core action names. Exactly one such output, or the key names nothing.
pub fn loan_output_for(
  outputs: List<Output>,
  loan_skh: ScriptHash,
  loan_owner_nft_name: ByteArray,
) -> Output {
  expect [loan_out] =
    list.filter(
      outputs,
      fn(out: Output) {
        if utils.at_script(out.address, loan_skh) {
          when out.datum is {
            InlineDatum(raw) -> {
              expect LoanDatum { owner_nft, .. }: LoanDatum = raw
              when owner_nft is {
                Some((_, name)) -> name == loan_owner_nft_name
                None -> False
              }
            }
            _ -> False
          }
        } else {
          False
        }
      },
    )
  loan_out
}

/// §5 rule 11 — the payout or refund input is the input at `Script(loan_skh)`
/// with **no datum** carrying the declaration's `binding_nft`, and is the only
/// such input. §5 rule 17 is why the no-datum test is part of the identity: these
/// two are the only inputs this protocol reads that carry none.
pub fn bound_input_for(
  inputs: List<Input>,
  loan_skh: ScriptHash,
  binding_nft: TupleAsset,
) -> Output {
  expect [bound_in] =
    list.filter_map(
      inputs,
      fn(Input { output, .. }) {
        if and {
          utils.at_script(output.address, loan_skh),
          output.datum == NoDatum,
          tokens.contains_nft(output.value, binding_nft),
        } {
          Some(output)
        } else {
          None
        }
      },
    )
  bound_in
}

/// The market as a reference input — §5 rule 3: the `MarketNFT` under
/// `config_pool_skh` **at** `Script(config_pool_skh)`. `PoolNFT` and `MarketNFT`
/// are the same asset, so the address is what tells the market from the pool.
pub fn market_ref(
  reference_inputs: List<Input>,
  market_ref_idx: Int,
  config_pool_skh: ScriptHash,
) -> MarketDatum {
  expect market_ref_idx != -1
  let Input { output: Output { address, value, datum, .. }, .. } =
    utils.input_at(reference_inputs, market_ref_idx)
  expect utils.at_script(address, config_pool_skh)
  expect [(_, 1)] = utils.tokens_of(value, config_pool_skh)
  expect InlineDatum(raw) = datum
  expect market: MarketDatum = raw
  market
}

/// 00-interface §1 — the whitelist is re-checked at every use. `Pending` is a
/// create path; `Delivered` and `Recovered` on this adapter are consumes.
pub fn permits_create(
  adapters: Pairs<ScriptHash, AdapterEntry>,
  own_skh: ScriptHash,
) -> Bool {
  let AdapterEntry { may_create, .. } = daken_pairs.get_first(adapters, own_skh)
  may_create
}

pub fn permits_recover(
  adapters: Pairs<ScriptHash, AdapterEntry>,
  own_skh: ScriptHash,
) -> Bool {
  let AdapterEntry { may_recover, .. } =
    daken_pairs.get_first(adapters, own_skh)
  may_recover
}

/// §2.20 — the tolerance sits at `route.slippage_src_idx`: the order on a fill,
/// the position on an asynchronous close. Both hashes come from the registry, so
/// the adapter tells the two apart without reading a core action's indices.
pub fn max_slippage_at(
  inputs: List<Input>,
  outputs: List<Output>,
  slippage_src_idx: Int,
  order_skh: ScriptHash,
  position_skh: ScriptHash,
) -> Int {
  // A non-negative index names an **input** — the order on a fill, the position
  // on an asynchronous close. A negative one names an **output** at
  // `-1 - slippage_src_idx`, which is the only form open to a transaction that
  // opens the loan and places the venue order at once: the position it states
  // its slippage in does not exist yet. That output is at `position_skh` and the
  // core reads the same one, so the value is still the borrower's own.
  let Output { address, datum, .. } =
    if slippage_src_idx >= 0 {
      utils.input_at(inputs, slippage_src_idx).output
    } else {
      utils.output_at(outputs, -1 - slippage_src_idx)
    }
  expect InlineDatum(raw) = datum
  if utils.at_script(address, order_skh) {
    expect OrderDatum { max_slippage, .. }: OrderDatum = raw
    max_slippage
  } else {
    expect utils.at_script(address, position_skh)
    expect PositionDatum { max_slippage, .. }: PositionDatum = raw
    max_slippage
  }
}

/// 05-01 §2.2 — no `BindingNFT` is minted in the transaction. A `BindingNFT` is
/// recognised by §5 rule 14's suffix test under `loan_skh`.
pub fn mints_binding_nft(mint: Value, loan_skh: ScriptHash) -> Bool {
  list.any(
    utils.tokens_of(mint, loan_skh),
    fn(entry: (ByteArray, Int)) {
      utils.is_suffixed_nft(entry.1st, constants.binding_nft_suffix)
    },
  )
}

/// The address the venue must pay a filled or returned claim back to — §7.5's
/// `receiver`. The stake credential travels in the declaration because the
/// adapter cannot reach `claim_source`; the core proves the two equal.
pub fn claim_receiver(
  loan_skh: ScriptHash,
  stake_credential: Option<address.StakeCredential>,
) -> Address {
  Address { payment_credential: address.Script(loan_skh), stake_credential }
}

// ---------------------------------------------------------------------- tests

const loan_skh_fixture =
  #"00000000000000000000000000000000000000000000000000000000"

const owner_a = #"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

const owner_b = #"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

fn delivered(loan_owner_nft_name: ByteArray) -> Declaration {
  Declaration {
    loan_owner_nft_name,
    route: types.Delivered { asset: (#"", #""), amount: 1, binding_nft: None },
  }
}

/// One row per declaration list. 01-validator §4.2 makes the key the identity of
/// a declaration, so a repeat is a second answer for one loan.
type KeyCase {
  label: ByteArray,
  declarations: List<Declaration>,
  expected: Bool,
}

test declaration_keys_are_pairwise_distinct() {
  let cases =
    [
      KeyCase { label: "empty", declarations: [], expected: True },
      KeyCase {
        label: "one key",
        declarations: [delivered(owner_a)],
        expected: True,
      },
      KeyCase {
        label: "two distinct keys",
        declarations: [delivered(owner_a), delivered(owner_b)],
        expected: True,
      },
      KeyCase {
        label: "the same key twice",
        declarations: [delivered(owner_a), delivered(owner_a)],
        expected: False,
      },
      KeyCase {
        label: "a repeat separated by another key",
        declarations: [
          delivered(owner_a),
          delivered(owner_b),
          delivered(owner_a),
        ],
        expected: False,
      },
    ]
  list.all(
    cases,
    fn(KeyCase { label: _label, declarations, expected }) {
      distinct_keys(declarations) == expected
    },
  )
}

/// §7.4.3 — the binding NFT is the declaration's own key plus the suffix, under
/// `loan_skh`, and §5 rule 14's length equality holds by construction.
test binding_nft_is_derived_from_the_key() {
  let (policy, name) = binding_nft_of(loan_skh_fixture, owner_a)
  and {
    policy == loan_skh_fixture,
    utils.is_suffixed_nft(name, constants.binding_nft_suffix),
    name != owner_a,
  }
}
