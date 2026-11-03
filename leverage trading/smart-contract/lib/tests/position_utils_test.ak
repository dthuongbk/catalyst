//// Unit tests for `position/utils.ak`.
////
//// They live outside that module rather than beside it, which departs from this
//// repository's own habit — the ninety-four tests that came before are inline in
//// the module each one exercises. The reason is that the live registry pins every
//// validator hash to the bytes of its own source, so no file under `lib/` that a
//// validator compiles from may change while that registry is in use. A new module
//// costs nothing on chain: `aiken` strips tests from the blueprint, and these
//// reach only what `position/utils.ak` already exports.

use aiken/interval
use cardano/address.{Address, Credential, Script, VerificationKey}
use cardano/assets.{AssetName, Value}
use cardano/transaction.{
  InlineDatum, Input, NoDatum, Output, OutputReference, Redeemer, ScriptPurpose,
  Spend,
}
use constants
use daken/prational.{PRational}
use position/utils as position_utils
use types.{
  CreateOrderIndexer, ModifyOrderIndexer, OrderRedeemer, PositionDatum,
  ProtocolDatum,
}
use utils


const t_position_skh = "position_skh"

const t_loan_skh = "loan_skh"

const t_order_skh = "order_skh"

const t_protocol_nft = ("protocol_skh", "proto")

/// `nft_name_len` bytes, so appending a suffix gives a name §5 rule 14 admits.
const t_nft_name = #"44444444444444444444444444444444444444444444444444444444"

fn t_wallet() -> Address {
  Address {
    payment_credential: VerificationKey("wallet_vk"),
    stake_credential: None,
  }
}

fn t_position() -> PositionDatum {
  PositionDatum {
    long_token: ("usdm_pid", "usdm"),
    take_profit_price: PRational(2, 1),
    min_execution_amount: 100_000_000,
    max_slippage: 300,
    beneficiary: t_wallet(),
  }
}

fn t_position_value(name: AssetName) -> Value {
  assets.from_lovelace(constants.min_ada)
    |> assets.merge(assets.from_asset(t_position_skh, name, 1))
}

fn t_position_out(value: Value) -> Output {
  Output {
    address: Address {
      payment_credential: Script(t_position_skh),
      stake_credential: None,
    },
    value,
    datum: InlineDatum(t_position()),
    reference_script: None,
  }
}

fn t_protocol() -> ProtocolDatum {
  ProtocolDatum {
    pool_skh: "pool_skh",
    loan_skh: t_loan_skh,
    config_pool_skh: "config_pool_skh",
    order_skh: t_order_skh,
    position_skh: t_position_skh,
    cancel_skh: "cancel_skh",
    adapters: [],
    admin_nft: ("protocol_skh", "adminADM"),
    oracle_skh: "oracle_skh",
    oracle_ready_at: 0,
    pending_oracle: None,
    loan_repay_skh: "loan_repay_skh",
    loan_close_skh: "loan_close_skh",
  }
}

fn t_registry_ref() -> Input {
  let (pid, name) = t_protocol_nft
  Input {
    output_reference: OutputReference("registry", 0),
    output: Output {
      address: Address {
        payment_credential: Script("config_pool_skh"),
        stake_credential: None,
      },
      value: assets.from_lovelace(constants.min_ada)
        |> assets.merge(assets.from_asset(pid, name, 1)),
      datum: InlineDatum(t_protocol()),
      reference_script: None,
    },
  }
}

type BoolCase {
  label: ByteArray,
  got: Bool,
  want: Bool,
}

fn all_of(cases: List<BoolCase>) -> Bool {
  when cases is {
    [] -> True
    [BoolCase { got, want, .. }, ..rest] -> and {
        (got == want)?,
        all_of(rest),
      }
  }
}

// ------------------------------------------------------------------ position_utils.tx_bounds

/// §5 rule 1. An open bound would make every `expiry - tx_end` comparison
/// vacuous, and a window wider than `max_validity_window` would let a price read
/// at one slot authorise a settlement six minutes later.
test tx_bounds_reads_a_finite_window() {
  let (start, end) = position_utils.tx_bounds(interval.between(1000, 1000 + 500))
  and {
    (start == 1000)?,
    (end == 1500)?,
  }
}

test tx_bounds_admits_the_window_at_its_cap() {
  let (start, end) =
    position_utils.tx_bounds(interval.between(1000, 1000 + constants.max_validity_window))
  (end - start == constants.max_validity_window)?
}

test tx_bounds_rejects_a_window_one_past_the_cap() fail {
  let (start, _end) =
    position_utils.tx_bounds(interval.between(1000, 1000 + constants.max_validity_window + 1))
  start == 1000
}

/// `tx_start > 0` and not `>= 0`: `interval.between(0, ..)` is what a builder
/// that forgot to set a lower bound produces, and zero would compare below every
/// expiry the protocol writes.
test tx_bounds_rejects_a_zero_lower_bound() fail {
  let (start, _end) = position_utils.tx_bounds(interval.between(0, 100))
  start == 0
}

test tx_bounds_rejects_an_unbounded_upper_end() fail {
  let (start, _end) = position_utils.tx_bounds(interval.after(1000))
  start == 1000
}

// ------------------------------------------------------------ position_utils.protocol_config

/// §16.2.10 — `-1` is the one arm that may decline to resolve the registry, and
/// it means the owner NFT is in a wallet, where no registry field bears on
/// whether its signature counts.
test protocol_config_is_none_at_minus_one() {
  (position_utils.protocol_config([], -1, t_protocol_nft) == None)?
}

test protocol_config_reads_the_registry_by_index_and_nft() {
  expect Some(protocol) =
    position_utils.protocol_config([t_registry_ref()], 0, t_protocol_nft)
  and {
    (protocol.order_skh == t_order_skh)?,
    (protocol.position_skh == t_position_skh)?,
    (protocol.loan_skh == t_loan_skh)?,
  }
}

/// §5 rule 2 — the registry is authenticated by `protocol_nft` alone, so the
/// UTxO at the cited index must actually hold it. A reference input carrying a
/// forged `ProtocolDatum` and no NFT would otherwise name any script it liked.
test protocol_config_rejects_a_reference_input_without_the_nft() fail {
  let Input { output_reference, output } = t_registry_ref()
  let stripped =
    Input {
      output_reference,
      output: Output {
        ..output,
        value: assets.from_lovelace(constants.min_ada),
      },
    }
  position_utils.protocol_config([stripped], 0, t_protocol_nft) == None
}

// ------------------------------------------------------------ position_utils.position_shape

/// §7.2.19, §10.1.1, §11.2.1 and §16.2.1 all read a position UTxO through this,
/// so every one of them inherits the four conditions at once.
test position_shape_reads_the_datum_the_nft_and_the_address() {
  let (position, name, address) =
    position_utils.position_shape(t_position_out(t_position_value(t_nft_name)), t_position_skh)
  and {
    (position == t_position())?,
    (name == t_nft_name)?,
    utils.at_script(address, t_position_skh)?,
  }
}

/// The suffix test is the point of this one. `PositionNFT` and
/// `PositionOwnerNFT` share a policy — the position script's own hash — so
/// without it the owner ticket parked in a position UTxO would pass for the
/// `PositionNFT` and the position would authenticate itself.
test position_shape_rejects_the_owner_nft_standing_in_for_the_position_nft() fail {
  let owner_name = utils.suffixed(t_nft_name, constants.owner_nft_suffix)
  let (_position, name, _address) =
    position_utils.position_shape(t_position_out(t_position_value(owner_name)), t_position_skh)
  name == owner_name
}

/// Exactly one, so a UTxO holding two positions' NFTs cannot be spent as either.
test position_shape_rejects_two_position_nfts() fail {
  let value =
    t_position_value(t_nft_name)
      |> assets.merge(assets.from_asset(t_position_skh, "second", 1))
  let (_position, name, _address) =
    position_utils.position_shape(t_position_out(value), t_position_skh)
  name == t_nft_name
}

test position_shape_rejects_a_quantity_above_one() fail {
  let value =
    assets.from_lovelace(constants.min_ada)
      |> assets.merge(assets.from_asset(t_position_skh, t_nft_name, 2))
  let (_position, name, _address) =
    position_utils.position_shape(t_position_out(value), t_position_skh)
  name == t_nft_name
}

/// A position UTxO carrying a reference script would lock its own minADA up
/// against the script's size and make every closing arm's lovelace arithmetic
/// wrong by that amount.
test position_shape_rejects_a_reference_script() fail {
  let out =
    Output {
      ..t_position_out(t_position_value(t_nft_name)),
      reference_script: Some("some_script"),
    }
  let (_position, name, _address) = position_utils.position_shape(out, t_position_skh)
  name == t_nft_name
}

test position_shape_rejects_a_foreign_address() fail {
  let out =
    Output {
      ..t_position_out(t_position_value(t_nft_name)),
      address: t_wallet(),
    }
  let (_position, name, _address) = position_utils.position_shape(out, t_position_skh)
  name == t_nft_name
}

/// A datum hash is not an inline datum: the validator would have to be handed
/// the preimage, which no arm here does.
test position_shape_rejects_a_missing_datum() fail {
  let out =
    Output { ..t_position_out(t_position_value(t_nft_name)), datum: NoDatum }
  let (_position, name, _address) = position_utils.position_shape(out, t_position_skh)
  name == t_nft_name
}

// ----------------------------------------------------- position_utils.valid_position_params

/// §16.2.7, which §7.2.19 inherits from the order it copies. The asymmetry
/// between the two price fields is deliberate: a zero numerator is the
/// "no take-profit" encoding, while a zero denominator is a division by zero
/// waiting for the first arm that evaluates the ratio.
test valid_position_params_bounds_each_field() {
  let base = t_position()
  let cases =
    [
      BoolCase { label: "the fixture", got: position_utils.valid_position_params(base), want: True },
      BoolCase {
        label: "a zero take-profit numerator disables it",
        got: position_utils.valid_position_params(
          PositionDatum { ..base, take_profit_price: PRational(0, 1) },
        ),
        want: True,
      },
      BoolCase {
        label: "a negative numerator",
        got: position_utils.valid_position_params(
          PositionDatum { ..base, take_profit_price: PRational(-1, 1) },
        ),
        want: False,
      },
      BoolCase {
        label: "a zero denominator",
        got: position_utils.valid_position_params(
          PositionDatum { ..base, take_profit_price: PRational(1, 0) },
        ),
        want: False,
      },
      BoolCase {
        label: "a zero min_execution_amount",
        got: position_utils.valid_position_params(
          PositionDatum { ..base, min_execution_amount: 0 },
        ),
        want: False,
      },
      BoolCase {
        label: "min_execution_amount at one",
        got: position_utils.valid_position_params(
          PositionDatum { ..base, min_execution_amount: 1 },
        ),
        want: True,
      },
      BoolCase {
        label: "a zero max_slippage",
        got: position_utils.valid_position_params(PositionDatum { ..base, max_slippage: 0 }),
        want: False,
      },
    ]
  all_of(cases)
}

// ------------------------------------------------------ position_utils.holds_loan_owner_nft

/// §10.1.1, §11.2.1, §12.3.1 and §12.4.1 all require the position to hold the
/// loan's owner ticket, which is what pairs one loan with one position. Read
/// from the position side, the policy must be the **loan** script's: a token of
/// the right name under any other policy is somebody else's.
test holds_loan_owner_nft_pairs_the_position_to_one_loan() {
  let owner_name = utils.suffixed(t_nft_name, constants.owner_nft_suffix)
  let held =
    t_position_value(t_nft_name)
      |> assets.merge(assets.from_asset(t_loan_skh, owner_name, 1))
  let cases =
    [
      BoolCase {
        label: "the ticket the datum names",
        got: position_utils.holds_loan_owner_nft(held, t_loan_skh, Some((t_loan_skh, owner_name))),
        want: True,
      },
      BoolCase {
        label: "the datum names another loan's ticket",
        got: position_utils.holds_loan_owner_nft(held, t_loan_skh, Some((t_loan_skh, "other"))),
        want: False,
      },
      BoolCase {
        label: "the right name under the wrong policy",
        got: position_utils.holds_loan_owner_nft(held, t_loan_skh, Some(("elsewhere", owner_name))),
        want: False,
      },
      BoolCase {
        label: "the position holds no ticket at all",
        got: position_utils.holds_loan_owner_nft(
          t_position_value(t_nft_name),
          t_loan_skh,
          Some((t_loan_skh, owner_name)),
        ),
        want: False,
      },
    ]
  all_of(cases)
}

/// §7.6 opens a loan whose `owner_nft` is `None` — there is no order and no
/// position ticket to pair. Reaching this from a closing arm means the arm
/// tried to pair a position with a loan that never had one.
test holds_loan_owner_nft_fails_where_the_loan_names_none() fail {
  position_utils.holds_loan_owner_nft(t_position_value(t_nft_name), t_loan_skh, None)
}

// ------------------------------------------------------ position_utils.owner_input_consents

fn t_owner_in(credential: Credential) -> Input {
  Input {
    output_reference: OutputReference("owner", 0),
    output: Output {
      address: Address { payment_credential: credential, stake_credential: None },
      value: assets.from_lovelace(constants.min_ada),
      datum: NoDatum,
      reference_script: None,
    },
  }
}

fn t_spend_redeemers(rdmr: Data) -> Pairs<ScriptPurpose, Redeemer> {
  [Pair(Spend(OutputReference("owner", 0)), rdmr)]
}

fn t_modify(order_in_idx: Int) -> OrderRedeemer {
  OrderRedeemer {
    order_actions: [
      ModifyOrderIndexer {
        order_in_idx,
        order_owner_in_idx: 1,
        order_out_idx: 0,
        owner_release_out_idx: 1,
        market_ref_idx: 0,
      },
    ],
    protocol_config_ref_idx: 0,
  }
}

/// §16.2.10. A `PositionOwnerNFT` may be parked inside an order UTxO — §6 mints
/// it there and item 11 of §6 in DEPLOYMENT.md records that a filled order keeps
/// holding it. So an owner input at `Script(order_skh)` is not consent on its
/// own: the order has to be spent under a `ModifyOrderIndexer` naming **this**
/// input, or the position would be closed while its owner authorised something
/// else entirely.
test owner_input_consents_needs_the_order_spent_under_modify() {
  let protocol = Some(t_protocol())
  let cases =
    [
      BoolCase {
        label: "a wallet owner needs no redeemer",
        got: position_utils.owner_input_consents(
          t_owner_in(VerificationKey("wallet_vk")),
          0,
          -1,
          None,
          [],
        ),
        want: True,
      },
      BoolCase {
        label: "an order input spent under ModifyOrder naming it",
        got: position_utils.owner_input_consents(
          t_owner_in(Script(t_order_skh)),
          0,
          0,
          protocol,
          t_spend_redeemers(t_modify(0)),
        ),
        want: True,
      },
      BoolCase {
        label: "ModifyOrder naming a different input",
        got: position_utils.owner_input_consents(
          t_owner_in(Script(t_order_skh)),
          0,
          0,
          protocol,
          t_spend_redeemers(t_modify(3)),
        ),
        want: False,
      },
      BoolCase {
        label: "the order spent under some other action",
        got: position_utils.owner_input_consents(
          t_owner_in(Script(t_order_skh)),
          0,
          0,
          protocol,
          t_spend_redeemers(
            OrderRedeemer {
              order_actions: [
                CreateOrderIndexer {
                  seed_utxo_idx: 0,
                  order_out_idx: 0,
                  market_ref_idx: 0,
                },
              ],
              protocol_config_ref_idx: 0,
            },
          ),
        ),
        want: False,
      },
      // Any other script: the position script's own arms constrain it, and this
      // helper has nothing to add.
      BoolCase {
        label: "another script needs no order redeemer",
        got: position_utils.owner_input_consents(
          t_owner_in(Script("some_other_skh")),
          0,
          0,
          protocol,
          [],
        ),
        want: True,
      },
    ]
  all_of(cases)
}

/// A script-held owner input with `-1` for the registry: §16.2.10 admits `-1`
/// only for a wallet, because without the registry there is no `order_skh` to
/// compare the credential against and the check above could not run at all.
test owner_input_consents_rejects_minus_one_for_a_script_owner() fail {
  position_utils.owner_input_consents(t_owner_in(Script(t_order_skh)), 0, -1, None, [])
}
