//// Unit tests for `adapter/sync_generic.ak`.
////
//// They live outside that module rather than beside it, which departs from this
//// repository's own habit — the ninety-four tests that came before are inline in
//// the module each one exercises. The reason is that the live registry pins every
//// validator hash to the bytes of its own source, so no file under `lib/` that a
//// validator compiles from may change while that registry is in use. A new module
//// costs nothing on chain: `aiken` strips tests from the blueprint, and these
//// reach only what `adapter/sync_generic.ak` already exports.

use adapter/sync_generic
use aiken/collection/list
use aiken/interval
use cardano/address.{Address, Script}
use cardano/assets.{AssetName, Value}
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference,
}
use constants
use daken/types as daken_types
use types.{
  AdapterEntry, AdapterRedeemer, Declaration, Delivered, LoanDatum, Pending,
  ProtocolDatum, Recovered,
}
use utils


const t_own_skh = #"11111111111111111111111111111111111111111111111111111111"

const t_loan_skh = #"22222222222222222222222222222222222222222222222222222222"

const t_config_pool_skh =
  #"33333333333333333333333333333333333333333333333333333333"

const t_protocol_nft = (t_config_pool_skh, "proto")

const t_owner_a = #"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

const t_owner_b = #"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

const t_collateral = ("usdm_pid", "usdm")

fn t_protocol(may_create: Bool) -> ProtocolDatum {
  ProtocolDatum {
    pool_skh: "pool_skh",
    loan_skh: t_loan_skh,
    config_pool_skh: t_config_pool_skh,
    order_skh: "order_skh",
    position_skh: "position_skh",
    cancel_skh: "cancel_skh",
    adapters: [Pair(t_own_skh, AdapterEntry { may_create, may_recover: False })],
    admin_nft: ("nft_mint", "adminADM"),
    oracle_skh: "oracle_skh",
    oracle_ready_at: 0,
    pending_oracle: None,
    loan_repay_skh: "loan_repay_skh",
    loan_close_skh: "loan_close_skh",
  }
}

fn t_registry(protocol: ProtocolDatum) -> Input {
  let (pid, name) = t_protocol_nft
  Input {
    output_reference: OutputReference("registry", 0),
    output: Output {
      address: Address {
        payment_credential: Script(t_config_pool_skh),
        stake_credential: None,
      },
      value: assets.from_lovelace(constants.min_ada)
        |> assets.merge(assets.from_asset(pid, name, 1)),
      datum: InlineDatum(protocol),
      reference_script: None,
    },
  }
}

fn t_loan_datum(owner_name: AssetName) -> LoanDatum {
  LoanDatum {
    owner_nft: Some((t_loan_skh, owner_name)),
    token: (#"", #""),
    loan_amount: 100_000_000,
    initial_interest_index: constants.initial_interest_index,
    claim: None,
  }
}

/// A loan output the adapter locates by the declaration's **key** — §5 rule 11:
/// never by the core action's `loan_out_idx`.
fn t_loan_out(owner_name: AssetName, held: Value) -> Output {
  Output {
    address: Address {
      payment_credential: Script(t_loan_skh),
      stake_credential: None,
    },
    value: assets.from_lovelace(constants.min_ada) |> assets.merge(held),
    datum: InlineDatum(t_loan_datum(owner_name)),
    reference_script: None,
  }
}

fn t_delivered(
  owner_name: AssetName,
  asset: daken_types.TupleAsset,
  amount: Int,
) -> Declaration {
  Declaration {
    loan_owner_nft_name: owner_name,
    route: Delivered { asset, amount, binding_nft: None },
  }
}

fn t_owner_mint(names: List<AssetName>) -> Value {
  list.foldl(
    names,
    assets.zero,
    fn(name, acc) {
      acc |> assets.merge(assets.from_asset(t_loan_skh, name, 1))
    },
  )
}

fn t_run(
  declarations: List<Declaration>,
  market_ref_idx: Int,
  outputs: List<Output>,
  mint: Value,
  may_create: Bool,
) -> Bool {
  sync_generic.withdraw(
    t_protocol_nft,
    t_own_skh,
    AdapterRedeemer {
      declarations,
      protocol_config_ref_idx: 0,
      market_ref_idx,
    },
    [t_registry(t_protocol(may_create))],
    outputs,
    mint,
    interval.between(1000, 1500),
  )
}

/// The whole of this adapter: obligation 1 alone. It declares what it reads off
/// the loan outputs the core action names and asserts nothing about the price,
/// the health gate or the fee arithmetic, which are the core's.
test sync_generic_accepts_a_delivered_collateral() {
  t_run(
    [t_delivered(t_owner_a, t_collateral, 500)],
    -1,
    [t_loan_out(t_owner_a, assets.from_asset("usdm_pid", "usdm", 500))],
    t_owner_mint([t_owner_a]),
    True,
  )
}

/// 05-01 §2.4 uses `>=`, and §7.3.5 is why: the core has its own bound on the
/// collateral, so a surplus above what the adapter declared is left free rather
/// than being a reason to reject.
test sync_generic_admits_a_surplus_above_the_declared_amount() {
  t_run(
    [t_delivered(t_owner_a, t_collateral, 500)],
    -1,
    [t_loan_out(t_owner_a, assets.from_asset("usdm_pid", "usdm", 501))],
    t_owner_mint([t_owner_a]),
    True,
  )
}

test sync_generic_rejects_less_than_the_declared_amount() {
  !t_run(
    [t_delivered(t_owner_a, t_collateral, 500)],
    -1,
    [t_loan_out(t_owner_a, assets.from_asset("usdm_pid", "usdm", 499))],
    t_owner_mint([t_owner_a]),
    True,
  )
}

/// Two loans filled in one transaction, each declaration matched to its own loan
/// output by its key.
test sync_generic_accepts_two_declarations_for_two_loans() {
  t_run(
    [
      t_delivered(t_owner_a, t_collateral, 500),
      t_delivered(t_owner_b, t_collateral, 700),
    ],
    -1,
    [
      t_loan_out(t_owner_a, assets.from_asset("usdm_pid", "usdm", 500)),
      t_loan_out(t_owner_b, assets.from_asset("usdm_pid", "usdm", 700)),
    ],
    t_owner_mint([t_owner_a, t_owner_b]),
    True,
  )
}

/// DEPLOYMENT.md §6 item 19 is this rule from the other side. `net(..)` strips
/// `min_ada` on the lovelace leg, so a declaration whose `asset` is ADA is
/// measured against what the loan output holds **beyond** its own minADA — and a
/// route hardcoded to `["", ""]` on a market that lends a token would compare a
/// minADA against a token amount.
test sync_generic_measures_an_ada_leg_net_of_min_ada() {
  let ada = (#"", #"")
  and {
    t_run(
      [t_delivered(t_owner_a, ada, 500)],
      -1,
      [t_loan_out(t_owner_a, assets.from_lovelace(500))],
      t_owner_mint([t_owner_a]),
      True,
    )?,
    // One lovelace short once the minADA is stripped.
    (!t_run(
      [t_delivered(t_owner_a, ada, 500)],
      -1,
      [t_loan_out(t_owner_a, assets.from_lovelace(499))],
      t_owner_mint([t_owner_a]),
      True,
    ))?,
  }
}

/// §5 rule 11a — an adapter that reads no market field must say so with `-1`.
/// This one carries no venue order, so there is no market parameter it could
/// legitimately need, and a live index would be an unexplained reference input.
test sync_generic_rejects_a_market_reference_index() {
  !t_run(
    [t_delivered(t_owner_a, t_collateral, 500)],
    0,
    [t_loan_out(t_owner_a, assets.from_asset("usdm_pid", "usdm", 500))],
    t_owner_mint([t_owner_a]),
    True,
  )
}

/// An adapter withdrawal that declares nothing proves nothing, and §5 rule 16
/// makes the withdrawal itself the authorisation for the core action — so an
/// empty one would be a free pass.
test sync_generic_rejects_an_empty_declaration_list() {
  !t_run([], -1, [], assets.zero, True)
}

/// 00-interface §1 — the whitelist is re-checked at every use, not only when the
/// adapter is registered. `Delivered` is a create path here, so `may_create` is
/// the flag that governs it and an adapter switched off in the registry stops
/// working immediately.
test sync_generic_rejects_an_adapter_not_permitted_to_create() {
  !t_run(
    [t_delivered(t_owner_a, t_collateral, 500)],
    -1,
    [t_loan_out(t_owner_a, assets.from_asset("usdm_pid", "usdm", 500))],
    t_owner_mint([t_owner_a]),
    False,
  )
}

/// 05-01 §2.2 — a synchronous fill leaves no claim behind, so nothing in the
/// transaction may bind one. A `BindingNFT` minted here would create a claim
/// with no venue order to settle it and no expiry anyone agreed to.
test sync_generic_rejects_a_binding_nft_mint() {
  let binding = utils.suffixed(t_owner_a, constants.binding_nft_suffix)
  !t_run(
    [t_delivered(t_owner_a, t_collateral, 500)],
    -1,
    [t_loan_out(t_owner_a, assets.from_asset("usdm_pid", "usdm", 500))],
    t_owner_mint([t_owner_a])
      |> assets.merge(assets.from_asset(t_loan_skh, binding, 1)),
    True,
  )
}

/// The other half of the same rule: the route itself may not name one either.
test sync_generic_rejects_a_route_that_names_a_binding_nft() {
  let declaration =
    Declaration {
      loan_owner_nft_name: t_owner_a,
      route: Delivered {
        asset: t_collateral,
        amount: 500,
        binding_nft: Some((t_loan_skh, "bound")),
      },
    }
  !t_run(
    [declaration],
    -1,
    [t_loan_out(t_owner_a, assets.from_asset("usdm_pid", "usdm", 500))],
    t_owner_mint([t_owner_a]),
    True,
  )
}

/// 01-validator §4.2 — the key is the identity of a declaration, so a repeat is
/// a second answer for one loan. Without the rule one loan output could satisfy
/// two declarations and a second loan would open against nothing.
test sync_generic_rejects_a_repeated_declaration_key() {
  !t_run(
    [
      t_delivered(t_owner_a, t_collateral, 500),
      t_delivered(t_owner_a, t_collateral, 500),
    ],
    -1,
    [t_loan_out(t_owner_a, assets.from_asset("usdm_pid", "usdm", 500))],
    t_owner_mint([t_owner_a]),
    True,
  )
}

/// 05-01 §2.3 — the declaration is matched to the loan the core action opened by
/// the mint of its `LoanOwnerNFT`. Without the mint the declaration could name
/// a loan output that already existed and was never opened in this transaction.
test sync_generic_rejects_a_declaration_whose_owner_nft_is_not_minted() {
  !t_run(
    [t_delivered(t_owner_a, t_collateral, 500)],
    -1,
    [t_loan_out(t_owner_a, assets.from_asset("usdm_pid", "usdm", 500))],
    assets.zero,
    True,
  )
}

/// 05-01 §2.1 — `Pending` and `Recovered` are rejected outright. This adapter
/// settles inside our own transaction; a `Pending` route would be a claim it has
/// no venue to place and no expiry logic to bound.
test sync_generic_rejects_a_pending_route() fail {
  let declaration =
    Declaration {
      loan_owner_nft_name: t_owner_a,
      route: Pending {
        asset: t_collateral,
        floor: 500,
        market_floor: 500,
        binding_nft: (t_loan_skh, "bound"),
        expiry: 2000,
        slippage_src_idx: 0,
        venue_ref_idx: 0,
        venue_out_idx: 0,
        stake_credential: None,
      },
    }
  t_run(
    [declaration],
    -1,
    [t_loan_out(t_owner_a, assets.from_asset("usdm_pid", "usdm", 500))],
    t_owner_mint([t_owner_a]),
    True,
  )
}

test sync_generic_rejects_a_recovered_route() fail {
  let declaration =
    Declaration {
      loan_owner_nft_name: t_owner_a,
      route: Recovered {
        asset: t_collateral,
        amount: 500,
        binding_nft: (t_loan_skh, "bound"),
      },
    }
  t_run(
    [declaration],
    -1,
    [t_loan_out(t_owner_a, assets.from_asset("usdm_pid", "usdm", 500))],
    t_owner_mint([t_owner_a]),
    True,
  )
}

/// §5 rule 11 — exactly one loan output answers a key, or the key names
/// nothing. Two outputs carrying the same `LoanOwnerNFT` name would make the
/// lookup ambiguous, and the adapter would attest to whichever came first.
test sync_generic_rejects_two_loan_outputs_for_one_key() fail {
  t_run(
    [t_delivered(t_owner_a, t_collateral, 500)],
    -1,
    [
      t_loan_out(t_owner_a, assets.from_asset("usdm_pid", "usdm", 500)),
      t_loan_out(t_owner_a, assets.from_asset("usdm_pid", "usdm", 500)),
    ],
    t_owner_mint([t_owner_a]),
    True,
  )
}

test sync_generic_rejects_a_key_no_loan_output_answers() fail {
  t_run(
    [t_delivered(t_owner_b, t_collateral, 500)],
    -1,
    [t_loan_out(t_owner_a, assets.from_asset("usdm_pid", "usdm", 500))],
    t_owner_mint([t_owner_b]),
    True,
  )
}

/// §5 rule 1 applies to an adapter as much as to a core arm: the price and the
/// expiry comparisons downstream are all relative to this window.
test sync_generic_rejects_an_unbounded_validity_range() fail {
  sync_generic.withdraw(
    t_protocol_nft,
    t_own_skh,
    AdapterRedeemer {
      declarations: [t_delivered(t_owner_a, t_collateral, 500)],
      protocol_config_ref_idx: 0,
      market_ref_idx: -1,
    },
    [t_registry(t_protocol(True))],
    [t_loan_out(t_owner_a, assets.from_asset("usdm_pid", "usdm", 500))],
    t_owner_mint([t_owner_a]),
    interval.after(1000),
  )
}
