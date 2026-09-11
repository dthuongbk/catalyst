//// Unit tests for `protocol/utils.ak`.
////
//// They live outside that module rather than beside it, which departs from this
//// repository's own habit — the ninety-four tests that came before are inline in
//// the module each one exercises. The reason is that the live registry pins every
//// validator hash to the bytes of its own source, so no file under `lib/` that a
//// validator compiles from may change while that registry is in use. A new module
//// costs nothing on chain: `aiken` strips tests from the blueprint, and these
//// reach only what `protocol/utils.ak` already exports.

use aiken/interval
use aiken/primitive/bytearray
use cardano/address.{Address, Script, VerificationKey}
use cardano/assets.{Value}
use cardano/transaction.{
  InlineDatum, Input, NoDatum, Output, OutputReference,
}
use constants
use daken/types.{TupleAsset} as daken_types
use protocol/utils as protocol_utils
use types.{ProtocolDatum}


const t_config_pool_skh =
  #"11111111111111111111111111111111111111111111111111111111"

const t_protocol_nft = (t_config_pool_skh, "proto")

const t_admin_nft = ("nft_mint", "adminADM")

fn t_protocol() -> ProtocolDatum {
  ProtocolDatum {
    pool_skh: "pool_skh",
    loan_skh: "loan_skh",
    config_pool_skh: t_config_pool_skh,
    order_skh: "order_skh",
    position_skh: "position_skh",
    cancel_skh: "cancel_skh",
    adapters: [],
    admin_nft: t_admin_nft,
    oracle_skh: "oracle_skh",
    oracle_ready_at: 0,
    pending_oracle: None,
    loan_repay_skh: "loan_repay_skh",
    loan_close_skh: "loan_close_skh",
  }
}

fn t_script_address(skh: ByteArray) -> Address {
  Address { payment_credential: Script(skh), stake_credential: None }
}

fn t_nft_value(nft: TupleAsset) -> Value {
  let (pid, name) = nft
  assets.from_lovelace(constants.min_ada)
    |> assets.merge(assets.from_asset(pid, name, 1))
}

fn t_registry_out() -> Output {
  Output {
    address: t_script_address(t_config_pool_skh),
    value: t_nft_value(t_protocol_nft),
    datum: InlineDatum(t_protocol()),
    reference_script: None,
  }
}

fn t_registry_in(tag: ByteArray) -> Input {
  Input { output_reference: OutputReference(tag, 0), output: t_registry_out() }
}

// ------------------------------------------------------------------ protocol_utils.tx_bounds

/// §5 rule 1. This is a second copy of the rule — `order/utils` and
/// `position/utils` carry their own — so it is tested on its own terms rather
/// than assumed to agree with theirs.
test tx_bounds_reads_a_finite_window() {
  let (start, end) = protocol_utils.tx_bounds(interval.between(1000, 1500))
  and {
    (start == 1000)?,
    (end == 1500)?,
  }
}

test tx_bounds_admits_the_window_at_its_cap() {
  let (start, end) =
    protocol_utils.tx_bounds(interval.between(1000, 1000 + constants.max_validity_window))
  (end - start == constants.max_validity_window)?
}

test tx_bounds_rejects_a_window_one_past_the_cap() fail {
  let (start, _end) =
    protocol_utils.tx_bounds(interval.between(1000, 1000 + constants.max_validity_window + 1))
  start == 1000
}

/// `tx_start > 0`, strictly: zero is what a builder that never set a lower bound
/// produces, and it would compare below every expiry this protocol writes.
test tx_bounds_rejects_a_zero_lower_bound() fail {
  let (start, _end) = protocol_utils.tx_bounds(interval.between(0, 100))
  start == 0
}

test tx_bounds_rejects_an_open_upper_bound() fail {
  let (start, _end) = protocol_utils.tx_bounds(interval.after(1000))
  start == 1000
}

// --------------------------------------------------------------- protocol_utils.registry_ref

/// §5 rules 2 and 3 — the `ProtocolNFT` alone authenticates the registry, so no
/// address is asserted. It is minted once, never burned, at a name distinct from
/// the `AdminNFT` beside it, which is what makes presence sufficient.
test registry_ref_reads_the_datum_by_index_and_nft() {
  let protocol = protocol_utils.registry_ref([t_registry_in("a")], 0, t_protocol_nft)
  and {
    (protocol == t_protocol())?,
    (protocol.admin_nft == t_admin_nft)?,
  }
}

test registry_ref_reads_the_index_it_is_given() {
  let other =
    Input {
      output_reference: OutputReference("other", 0),
      output: Output {
        ..t_registry_out(),
        value: assets.from_lovelace(constants.min_ada),
      },
    }
  let protocol =
    protocol_utils.registry_ref([other, t_registry_in("a")], 1, t_protocol_nft)
  (protocol.order_skh == "order_skh")?
}

/// §5 rule 2 bars `-1` here. `position/utils.protocol_config` is the one
/// resolver that admits it, and only for §16.2.10's wallet-held owner NFT.
test registry_ref_rejects_minus_one() fail {
  protocol_utils.registry_ref([t_registry_in("a")], -1, t_protocol_nft).order_skh == "order_skh"
}

/// A reference input carrying a forged `ProtocolDatum` and no NFT would name any
/// script hash it liked, which is every validator in the set.
test registry_ref_rejects_an_input_without_the_nft() fail {
  let stripped =
    Input {
      output_reference: OutputReference("a", 0),
      output: Output {
        ..t_registry_out(),
        value: assets.from_lovelace(constants.min_ada),
      },
    }
  protocol_utils.registry_ref([stripped], 0, t_protocol_nft).order_skh == "order_skh"
}

test registry_ref_rejects_a_nft_of_another_name() fail {
  protocol_utils.registry_ref([t_registry_in("a")], 0, (t_config_pool_skh, "not_proto")).order_skh == "order_skh"
}

// ------------------------------------------------------------- protocol_utils.registry_spent

/// §14 with §5 rule 16 — the registry input this arm reads must be the very
/// output reference the `Spend` is running for. Without the equality one
/// `protocol_config` UTxO could be spent while the redeemer's index pointed at
/// another, and the transition would be checked against a datum it does not
/// replace.
test registry_spent_must_be_the_reference_being_spent() {
  let own = OutputReference("a", 0)
  let (output, datum) =
    protocol_utils.registry_spent([t_registry_in("a")], 0, own, t_protocol_nft)
  and {
    (datum == t_protocol())?,
    (output.address == t_script_address(t_config_pool_skh))?,
  }
}

test registry_spent_rejects_another_input() fail {
  let own = OutputReference("a", 0)
  let (_output, datum) =
    protocol_utils.registry_spent([t_registry_in("elsewhere")], 0, own, t_protocol_nft)
  datum == t_protocol()
}

test registry_spent_rejects_an_input_without_the_nft() fail {
  let own = OutputReference("a", 0)
  let stripped =
    Input {
      output_reference: own,
      output: Output {
        ..t_registry_out(),
        value: assets.from_lovelace(constants.min_ada),
      },
    }
  let (_output, datum) = protocol_utils.registry_spent([stripped], 0, own, t_protocol_nft)
  datum == t_protocol()
}

// ----------------------------------------------------------------- protocol_utils.own_address

/// §14.2.3a — `CreateProtocol` has no registry input to pin its output against,
/// so the genesis address is read off the input the `Spend` is running for. The
/// lookup is by output reference rather than by index: the redeemer's
/// `seed_utxo_idx` names the seed, not this.
test own_address_finds_the_input_being_spent() {
  let own = OutputReference("seed", 3)
  let wallet =
    Address {
      payment_credential: VerificationKey("wallet_vk"),
      stake_credential: None,
    }
  let inputs =
    [
      t_registry_in("a"),
      Input {
        output_reference: own,
        output: Output {
          address: wallet,
          value: assets.from_lovelace(constants.min_ada),
          datum: NoDatum,
          reference_script: None,
        },
      },
    ]
  (protocol_utils.own_address(inputs, own) == wallet)?
}

test own_address_fails_where_the_reference_is_absent() fail {
  protocol_utils.own_address([t_registry_in("a")], OutputReference("missing", 0)) == t_script_address(
    t_config_pool_skh,
  )
}

// ------------------------------------------------------------ protocol_utils.admin_authorises

/// §14.2.1 and §15.2.2 — presence of the `AdminNFT` at the named input is the
/// whole authorisation. There is no signature check: the NFT is the credential,
/// and whoever can spend the UTxO holding it is the admin.
test admin_authorises_on_the_nft_alone() {
  let (pid, name) = t_admin_nft
  let holding =
    Input {
      output_reference: OutputReference("admin", 0),
      output: Output {
        address: Address {
          payment_credential: VerificationKey("wallet_vk"),
          stake_credential: None,
        },
        value: t_nft_value(t_admin_nft),
        datum: NoDatum,
        reference_script: None,
      },
    }
  let bare =
    Input {
      output_reference: OutputReference("bare", 0),
      output: Output {
        ..holding.output,
        value: assets.from_lovelace(constants.min_ada),
      },
    }
  let wrong_name =
    Input {
      output_reference: OutputReference("wrong", 0),
      output: Output {
        ..holding.output,
        value: assets.from_lovelace(constants.min_ada)
          |> assets.merge(assets.from_asset(pid, "not_admin", 1)),
      },
    }
  and {
    protocol_utils.admin_authorises([holding], 0, t_admin_nft)?,
    (!protocol_utils.admin_authorises([bare], 0, t_admin_nft))?,
    (!protocol_utils.admin_authorises([wrong_name], 0, t_admin_nft))?,
    // Read by index, so the arm names which input it means.
    protocol_utils.admin_authorises([bare, holding], 1, t_admin_nft)?,
    (name == "adminADM")?,
  }
}

test admin_authorises_fails_past_the_end_of_the_inputs() fail {
  protocol_utils.admin_authorises([], 0, t_admin_nft)
}

// -------------------------------------------------------------- protocol_utils.sole_asset_of

/// §5 rule 14 keeps `admin_nft_suffix` out of the recognition rules, so nothing
/// about the name is asserted — the policy having exactly one token is what
/// identifies it.
test sole_asset_of_names_the_one_token_of_a_policy() {
  let value = t_nft_value(t_admin_nft)
  (protocol_utils.sole_asset_of(value, "nft_mint") == t_admin_nft)?
}

test sole_asset_of_fails_where_a_policy_holds_two() fail {
  let value =
    t_nft_value(t_admin_nft)
      |> assets.merge(assets.from_asset("nft_mint", "second", 1))
  protocol_utils.sole_asset_of(value, "nft_mint") == t_admin_nft
}

// ------------------------------------------------------------ protocol_utils.replaces_output

/// §5 rule 8 — a replaced script output keeps **both** credentials. Comparing
/// the whole address rather than the payment credential alone is what stops the
/// registry being moved to a copy of its own script under a different stake
/// credential, where its rewards would go elsewhere.
test replaces_output_pins_the_whole_address() {
  let in_out = t_registry_out()
  let same = Output { ..in_out, value: assets.from_lovelace(constants.min_ada) }
  let restaked =
    Output {
      ..in_out,
      address: Address {
        payment_credential: Script(t_config_pool_skh),
        stake_credential: Some(address.Inline(Script("stake_skh"))),
      },
    }
  let with_script = Output { ..in_out, reference_script: Some("some_script") }
  and {
    protocol_utils.replaces_output(same, in_out)?,
    (!protocol_utils.replaces_output(restaked, in_out))?,
    (!protocol_utils.replaces_output(with_script, in_out))?,
  }
}

// ------------------------------------------------------------- protocol_utils.is_script_hash

/// §14.2.3a — the genesis registry may not name the empty bytestring as a
/// script, because that is the **lovelace** policy id. A blake2b_224 hash is
/// `nft_name_len` bytes and nothing else is.
test is_script_hash_is_a_width_test() {
  and {
    protocol_utils.is_script_hash(t_config_pool_skh)?,
    (!protocol_utils.is_script_hash(#""))?,
    (!protocol_utils.is_script_hash(bytearray.take(t_config_pool_skh, 27)))?,
    (!protocol_utils.is_script_hash(
      bytearray.concat(t_config_pool_skh, #"00"),
    ))?,
  }
}
