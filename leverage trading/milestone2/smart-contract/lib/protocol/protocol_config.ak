//// Biz spec §14 — update protocol config. Five arms, one registry UTxO.
////
//// §14.2.2a is the spine of this module: every arm states the fields it may
//// move, and the whole datum is compared against the input with exactly those
//// substitutions. Nothing is left free.

use aiken/collection/list
use cardano/assets.{PolicyId, Value}
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, ValidityRange,
}
use constants
use daken/flist
use daken/outref_hash
use daken/pairs as daken_pairs
use daken/tokens
use daken/types.{TupleAsset} as daken_types
use protocol/utils as protocol_utils
use types.{
  AdapterEntry, AnnounceOracle, CreateProtocol, ProtocolConfigRedeemer,
  ProtocolDatum, RotateAdmin, RotateOracle, ScriptHash, UpdateAdapters,
}
use utils

// ------------------------------------------------------------ §14.2.2a matrix

/// `UpdateAdapters` → `adapters`.
pub fn only_adapters_moved(i: ProtocolDatum, o: ProtocolDatum) -> Bool {
  o == ProtocolDatum { ..i, adapters: o.adapters }
}

/// `RotateAdmin` → `admin_nft`.
pub fn only_admin_nft_moved(i: ProtocolDatum, o: ProtocolDatum) -> Bool {
  o == ProtocolDatum { ..i, admin_nft: o.admin_nft }
}

/// `AnnounceOracle` → `pending_oracle` and `oracle_ready_at`.
pub fn only_announcement_moved(i: ProtocolDatum, o: ProtocolDatum) -> Bool {
  o == ProtocolDatum {
    ..i,
    oracle_ready_at: o.oracle_ready_at,
    pending_oracle: o.pending_oracle,
  }
}

/// `RotateOracle` → `oracle_skh` and `pending_oracle`.
pub fn only_rotation_moved(i: ProtocolDatum, o: ProtocolDatum) -> Bool {
  o == ProtocolDatum {
    ..i,
    oracle_skh: o.oracle_skh,
    pending_oracle: o.pending_oracle,
  }
}

// ------------------------------------------------------------- the whitelist

/// §14.2.6 — monotone in `may_recover`, and an entry is never removed. Read
/// through `get_first`, so an entry prepended under an existing key is caught:
/// the first match is the effective one everywhere else too.
pub fn adapters_monotone(
  adapters_in: Pairs<ScriptHash, AdapterEntry>,
  adapters_out: Pairs<ScriptHash, AdapterEntry>,
) -> Bool {
  list.all(
    adapters_in,
    fn(entry: Pair<ScriptHash, AdapterEntry>) {
      let Pair(skh, AdapterEntry { may_recover, .. }) = entry
      let AdapterEntry { may_recover: may_recover_out, .. } =
        daken_pairs.get_first(adapters_out, skh)
      or {
        !may_recover,
        may_recover_out,
      }
    },
  )
}

// ------------------------------------------------------------------ the arms

pub fn validate(
  protocol_nft: TupleAsset,
  redeemer: ProtocolConfigRedeemer,
  own_ref: OutputReference,
  inputs: List<Input>,
  outputs: List<Output>,
  mint: Value,
  validity_range: ValidityRange,
) -> Bool {
  let (tx_start, tx_end) = protocol_utils.tx_bounds(validity_range)
  // §14.2.4 — the `AdminNFT`'s policy is `nft_mint`, which the validator reads
  // as `protocol_nft.policy_id`. The `ProtocolNFT` is minted by that same
  // policy, so no extra parameter is needed.
  let (nft_mint, protocol_nft_name) = protocol_nft
  when redeemer is {
    CreateProtocol { seed_utxo_idx, admin_in_idx, protocol_out_idx } ->
      create_protocol(
        nft_mint,
        protocol_nft,
        protocol_nft_name,
        seed_utxo_idx,
        admin_in_idx,
        protocol_out_idx,
        own_ref,
        inputs,
        outputs,
        mint,
      )
    UpdateAdapters { protocol_in_idx, admin_in_idx, protocol_out_idx } -> {
      let (datum_in, datum_out) =
        registry_step(
          protocol_nft,
          protocol_in_idx,
          admin_in_idx,
          protocol_out_idx,
          own_ref,
          inputs,
          outputs,
        )
      and {
        only_adapters_moved(datum_in, datum_out)?,
        adapters_monotone(datum_in.adapters, datum_out.adapters)?,
        mints_nothing(mint)?,
      }
    }
    RotateAdmin {
      protocol_in_idx,
      admin_in_idx,
      new_admin_in_idx,
      protocol_out_idx,
    } -> {
      let (datum_in, datum_out) =
        registry_step(
          protocol_nft,
          protocol_in_idx,
          admin_in_idx,
          protocol_out_idx,
          own_ref,
          inputs,
          outputs,
        )
      let Input { output: Output { value: new_admin_value, .. }, .. } =
        flist.at(inputs, new_admin_in_idx)
      let (old_policy, old_name) = datum_in.admin_nft
      and {
        only_admin_nft_moved(datum_in, datum_out)?,
        // §14.2.4 — the incoming NFT is the asset held at `new_admin_in_idx`,
        // under `nft_mint`.
        (datum_out.admin_nft == protocol_utils.sole_asset_of(
          new_admin_value,
          nft_mint,
        ))?,
        (datum_out.admin_nft != datum_in.admin_nft)?,
        // exactly `{ old admin_nft: -1 }`, the whole policy, and nothing else.
        (old_policy == nft_mint)?,
        (assets.flatten(mint) == [(nft_mint, old_name, -1)])?,
      }
    }
    AnnounceOracle { protocol_in_idx, admin_in_idx, protocol_out_idx } -> {
      let (datum_in, datum_out) =
        registry_step(
          protocol_nft,
          protocol_in_idx,
          admin_in_idx,
          protocol_out_idx,
          own_ref,
          inputs,
          outputs,
        )
      // §14.2.5 — may not overwrite a `pending_oracle` that is already `Some`.
      expect None = datum_in.pending_oracle
      expect Some(announced) = datum_out.pending_oracle
      and {
        only_announcement_moved(datum_in, datum_out)?,
        (announced != #"")?,
        (datum_out.oracle_ready_at >= tx_end + constants.oracle_rotation_delay)?,
        mints_nothing(mint)?,
      }
    }
    RotateOracle { protocol_in_idx, admin_in_idx, protocol_out_idx } -> {
      let (datum_in, datum_out) =
        registry_step(
          protocol_nft,
          protocol_in_idx,
          admin_in_idx,
          protocol_out_idx,
          own_ref,
          inputs,
          outputs,
        )
      and {
        only_rotation_moved(datum_in, datum_out)?,
        // §14.2.5 — all three, or the announce delay buys nothing.
        (datum_in.pending_oracle == Some(datum_out.oracle_skh))?,
        (tx_start >= datum_in.oracle_ready_at)?,
        (datum_out.pending_oracle == None)?,
        mints_nothing(mint)?,
      }
    }
  }
}

/// The four arms that spend the registry share this: §5 rule 16's index
/// equality, §14.2.1's admin NFT, and §14.2.2's pinned value and address.
fn registry_step(
  protocol_nft: TupleAsset,
  protocol_in_idx: Int,
  admin_in_idx: Int,
  protocol_out_idx: Int,
  own_ref: OutputReference,
  inputs: List<Input>,
  outputs: List<Output>,
) -> (ProtocolDatum, ProtocolDatum) {
  let (protocol_in, datum_in) =
    protocol_utils.registry_spent(
      inputs,
      protocol_in_idx,
      own_ref,
      protocol_nft,
    )
  expect
    protocol_utils.admin_authorises(inputs, admin_in_idx, datum_in.admin_nft)
  let protocol_out = utils.output_at(outputs, protocol_out_idx)
  expect protocol_out.value == protocol_in.value
  expect protocol_utils.replaces_output(protocol_out, protocol_in)
  expect tokens.contains_nft(protocol_out.value, protocol_nft)
  expect InlineDatum(raw) = protocol_out.datum
  expect datum_out: ProtocolDatum = raw
  (datum_in, datum_out)
}

/// §14.2.3a — the genesis datum, field by field. There is no registry input, so
/// §14.2.2 and §14.2.2a are both vacuous here and this is the only thing that
/// binds the datum; §5 rule 16 likewise has no index to bind, so the spent
/// input serves only to supply the address the output is pinned to.
fn create_protocol(
  nft_mint: PolicyId,
  protocol_nft: TupleAsset,
  protocol_nft_name: ByteArray,
  seed_utxo_idx: Int,
  admin_in_idx: Int,
  protocol_out_idx: Int,
  own_ref: OutputReference,
  inputs: List<Input>,
  outputs: List<Output>,
  mint: Value,
) -> Bool {
  let Input { output_reference: seed_ref, .. } = flist.at(inputs, seed_utxo_idx)
  let Input { output: Output { value: admin_value, .. }, .. } =
    flist.at(inputs, admin_in_idx)
  let protocol_out = utils.output_at(outputs, protocol_out_idx)
  expect InlineDatum(raw) = protocol_out.datum
  expect ProtocolDatum {
    pool_skh,
    loan_skh,
    config_pool_skh,
    order_skh,
    position_skh,
    cancel_skh,
    adapters,
    admin_nft,
    oracle_skh,
    oracle_ready_at,
    pending_oracle,
    loan_repay_skh,
    loan_close_skh,
  }: ProtocolDatum = raw
  and {
    (protocol_out.address == protocol_utils.own_address(inputs, own_ref))?,
    (protocol_out.reference_script == None)?,
    tokens.contains_nft(protocol_out.value, protocol_nft)?,
    // The eight hashes: a script, never the empty bytestring, which is the
    // lovelace policy — the confusion §5 rule 2 exists to prevent.
    list.all(
      [
        pool_skh, loan_skh, loan_repay_skh, loan_close_skh, config_pool_skh,
        order_skh, position_skh, cancel_skh,
      ],
      protocol_utils.is_script_hash,
    )?,
    (adapters == [])?,
    // A genesis `Some` paired with `oracle_ready_at == 0` would let the first
    // `RotateOracle` install any oracle immediately.
    (pending_oracle == None)?,
    (oracle_ready_at == 0)?,
    (oracle_skh != #"")?,
    (admin_nft == protocol_utils.sole_asset_of(admin_value, nft_mint))?,
    (protocol_nft_name == outref_hash.blake2b_224(seed_ref))?,
    (assets.flatten(mint) == [(nft_mint, protocol_nft_name, 1)])?,
  }
}

/// §5 rule 10 — an arm that states no contribution to a policy contributes zero
/// to it, and that zero is checked.
fn mints_nothing(mint: Value) -> Bool {
  assets.flatten(mint) == []
}

// ---------------------------------------------------------------------- tests

const skh_a = #"00000000000000000000000000000000000000000000000000000000"

const skh_b = #"11111111111111111111111111111111111111111111111111111111"

const nft_policy = #"22222222222222222222222222222222222222222222222222222222"

fn base() -> ProtocolDatum {
  ProtocolDatum {
    pool_skh: skh_a,
    loan_skh: skh_a,
    config_pool_skh: skh_a,
    order_skh: skh_a,
    position_skh: skh_a,
    cancel_skh: skh_a,
    adapters: [
      Pair(skh_a, AdapterEntry { may_create: True, may_recover: True }),
    ],
    admin_nft: (nft_policy, "admin"),
    oracle_skh: skh_a,
    oracle_ready_at: 100,
    pending_oracle: None,
    loan_repay_skh: skh_a,
    loan_close_skh: skh_a,
  }
}

/// The four arms §14.2.2a gives a row to. `CreateProtocol` is absent: it has no
/// input, so the clause is vacuous on it and §14.2.3a governs instead.
type Arm {
  ArmUpdateAdapters
  ArmRotateAdmin
  ArmAnnounceOracle
  ArmRotateOracle
}

fn arm_admits(arm: Arm, i: ProtocolDatum, o: ProtocolDatum) -> Bool {
  when arm is {
    ArmUpdateAdapters -> only_adapters_moved(i, o)
    ArmRotateAdmin -> only_admin_nft_moved(i, o)
    ArmAnnounceOracle -> only_announcement_moved(i, o)
    ArmRotateOracle -> only_rotation_moved(i, o)
  }
}

const every_arm =
  [ArmUpdateAdapters, ArmRotateAdmin, ArmAnnounceOracle, ArmRotateOracle]

/// One row per `ProtocolDatum` field: `moved` is the output datum with that one
/// field changed, and `allowed_by` names the arms §14.2.2a lets move it. The
/// test walks (field × arm) and asserts every other pair is refused.
type MatrixCase {
  label: ByteArray,
  moved: ProtocolDatum,
  allowed_by: List<Arm>,
}

fn matrix() -> List<MatrixCase> {
  let i = base()
  [
    MatrixCase {
      label: "pool_skh",
      moved: ProtocolDatum { ..i, pool_skh: skh_b },
      allowed_by: [],
    },
    MatrixCase {
      label: "loan_skh",
      moved: ProtocolDatum { ..i, loan_skh: skh_b },
      allowed_by: [],
    },
    MatrixCase {
      label: "loan_repay_skh",
      moved: ProtocolDatum { ..i, loan_repay_skh: skh_b },
      allowed_by: [],
    },
    MatrixCase {
      label: "loan_close_skh",
      moved: ProtocolDatum { ..i, loan_close_skh: skh_b },
      allowed_by: [],
    },
    MatrixCase {
      label: "config_pool_skh",
      moved: ProtocolDatum { ..i, config_pool_skh: skh_b },
      allowed_by: [],
    },
    MatrixCase {
      label: "order_skh",
      moved: ProtocolDatum { ..i, order_skh: skh_b },
      allowed_by: [],
    },
    MatrixCase {
      label: "position_skh",
      moved: ProtocolDatum { ..i, position_skh: skh_b },
      allowed_by: [],
    },
    MatrixCase {
      label: "cancel_skh",
      moved: ProtocolDatum { ..i, cancel_skh: skh_b },
      allowed_by: [],
    },
    MatrixCase {
      label: "adapters",
      moved: ProtocolDatum { ..i, adapters: [] },
      allowed_by: [ArmUpdateAdapters],
    },
    MatrixCase {
      label: "admin_nft",
      moved: ProtocolDatum { ..i, admin_nft: (nft_policy, "other") },
      allowed_by: [ArmRotateAdmin],
    },
    MatrixCase {
      label: "oracle_skh",
      moved: ProtocolDatum { ..i, oracle_skh: skh_b },
      allowed_by: [ArmRotateOracle],
    },
    MatrixCase {
      label: "oracle_ready_at",
      moved: ProtocolDatum { ..i, oracle_ready_at: 0 },
      allowed_by: [ArmAnnounceOracle],
    },
    MatrixCase {
      label: "pending_oracle",
      moved: ProtocolDatum { ..i, pending_oracle: Some(skh_b) },
      allowed_by: [ArmAnnounceOracle, ArmRotateOracle],
    },
  ]
}

test immutability_matrix() {
  let i = base()
  list.all(
    matrix(),
    fn(MatrixCase { label: _label, moved, allowed_by }) {
      list.all(
        every_arm,
        fn(arm: Arm) { arm_admits(arm, i, moved) == list.has(allowed_by, arm) },
      )
    },
  )
}

test unmoved_datum_passes_every_arm() {
  let i = base()
  list.all(every_arm, fn(arm: Arm) { arm_admits(arm, i, i) })
}

/// The composition §14.2.2a exists to stop: an `UpdateAdapters` writing
/// `pending_oracle` and zeroing `oracle_ready_at`, so the next block's
/// `RotateOracle` installs any oracle at all.
test update_adapters_cannot_arm_a_rotation() {
  let i = base()
  let o =
    ProtocolDatum {
      ..i,
      adapters: [],
      pending_oracle: Some(skh_b),
      oracle_ready_at: 0,
    }
  !only_adapters_moved(i, o)
}

/// §14.2.6 — one row per admissible and inadmissible whitelist move.
type MonotoneCase {
  label: ByteArray,
  adapters_in: Pairs<ScriptHash, AdapterEntry>,
  adapters_out: Pairs<ScriptHash, AdapterEntry>,
  expected: Bool,
}

test whitelist_monotonicity() {
  let live = AdapterEntry { may_create: True, may_recover: True }
  let withdrawn = AdapterEntry { may_create: False, may_recover: True }
  let killed = AdapterEntry { may_create: False, may_recover: False }
  let cases =
    [
      MonotoneCase {
        label: "may_create may fall — the incident action",
        adapters_in: [Pair(skh_a, live)],
        adapters_out: [Pair(skh_a, withdrawn)],
        expected: True,
      },
      MonotoneCase {
        label: "may_create may rise",
        adapters_in: [Pair(skh_a, withdrawn)],
        adapters_out: [Pair(skh_a, live)],
        expected: True,
      },
      MonotoneCase {
        label: "may_recover may rise",
        adapters_in: [Pair(skh_a, killed)],
        adapters_out: [Pair(skh_a, live)],
        expected: True,
      },
      MonotoneCase {
        label: "may_recover may never fall",
        adapters_in: [Pair(skh_a, live)],
        adapters_out: [Pair(skh_a, killed)],
        expected: False,
      },
      MonotoneCase {
        label: "an entry may be appended",
        adapters_in: [Pair(skh_a, live)],
        adapters_out: [Pair(skh_a, live), Pair(skh_b, live)],
        expected: True,
      },
      MonotoneCase {
        label: "a shadowing entry cannot clear may_recover",
        adapters_in: [Pair(skh_a, live)],
        adapters_out: [Pair(skh_a, killed), Pair(skh_a, live)],
        expected: False,
      },
    ]
  list.all(
    cases,
    fn(MonotoneCase { label: _label, adapters_in, adapters_out, expected }) {
      adapters_monotone(adapters_in, adapters_out) == expected
    },
  )
}

test whitelist_entry_never_removed() fail {
  let live = AdapterEntry { may_create: True, may_recover: True }
  adapters_monotone([Pair(skh_a, live)], [])
}
