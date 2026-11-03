//// Unit tests for `position/modify_position.ak`.
////
//// They live outside that module rather than beside it, which departs from this
//// repository's own habit — the ninety-four tests that came before are inline in
//// the module each one exercises. The reason is that the live registry pins every
//// validator hash to the bytes of its own source, so no file under `lib/` that a
//// validator compiles from may change while that registry is in use. A new module
//// costs nothing on chain: `aiken` strips tests from the blueprint, and these
//// reach only what `position/modify_position.ak` already exports.

use aiken/collection/list
use cardano/address.{Address, Script, VerificationKey}
use cardano/assets.{AssetName, Value}
use cardano/transaction.{
  InlineDatum, Input, NoDatum, Output, OutputReference,
}
use constants
use daken/prational.{PRational}
use position/modify_position
use types.{PositionDatum, ProtocolDatum}
use utils


const t_position_skh =
  #"11111111111111111111111111111111111111111111111111111111"

const t_loan_skh = #"22222222222222222222222222222222222222222222222222222222"

const t_pool_skh = #"33333333333333333333333333333333333333333333333333333333"

const t_nft_name = #"44444444444444444444444444444444444444444444444444444444"

const t_long = ("usdm_pid", "usdm")

fn t_wallet() -> Address {
  Address {
    payment_credential: VerificationKey("wallet_vk"),
    stake_credential: None,
  }
}

fn t_position_address() -> Address {
  Address {
    payment_credential: Script(t_position_skh),
    stake_credential: None,
  }
}

fn t_owner_name() -> AssetName {
  utils.suffixed(t_nft_name, constants.owner_nft_suffix)
}

fn t_protocol() -> ProtocolDatum {
  ProtocolDatum {
    pool_skh: t_pool_skh,
    loan_skh: t_loan_skh,
    config_pool_skh: "config_pool_skh",
    order_skh: "order_skh",
    position_skh: t_position_skh,
    cancel_skh: "cancel_skh",
    adapters: [],
    admin_nft: ("nft_mint", "adminADM"),
    oracle_skh: "oracle_skh",
    oracle_ready_at: 0,
    pending_oracle: None,
    loan_repay_skh: "loan_repay_skh",
    loan_close_skh: "loan_close_skh",
  }
}

fn t_position() -> PositionDatum {
  PositionDatum {
    long_token: t_long,
    take_profit_price: PRational(2, 1),
    min_execution_amount: 100_000_000,
    max_slippage: 300,
    beneficiary: t_wallet(),
  }
}

/// The `LoanOwnerNFT` rides along: §16.2.3 is what keeps it here, and §10.1.1,
/// §11.2.1 and §12.3.1 each need one input holding both.
fn t_position_value(lovelace: Int) -> Value {
  assets.from_lovelace(lovelace)
    |> assets.merge(assets.from_asset(t_position_skh, t_nft_name, 1))
    |> assets.merge(assets.from_asset(t_loan_skh, t_owner_name(), 1))
}

fn t_position_in() -> Input {
  Input {
    output_reference: OutputReference("position", 0),
    output: Output {
      address: t_position_address(),
      value: t_position_value(constants.min_ada),
      datum: InlineDatum(t_position()),
      reference_script: None,
    },
  }
}

fn t_position_out(value: Value, position: PositionDatum) -> Output {
  Output {
    address: t_position_address(),
    value,
    datum: InlineDatum(position),
    reference_script: None,
  }
}

fn t_owner_in(value: Value) -> Input {
  Input {
    output_reference: OutputReference("owner", 0),
    output: Output {
      address: t_wallet(),
      value,
      datum: NoDatum,
      reference_script: None,
    },
  }
}

fn t_owner_value() -> Value {
  assets.from_lovelace(constants.min_ada)
    |> assets.merge(assets.from_asset(t_position_skh, t_owner_name(), 1))
}

/// The canonical §16: the position at index 0, its owner ticket in a wallet at
/// index 1, the registry resolved, nothing minted and no loan or pool input.
fn t_run(position_out: Output) -> Bool {
  t_run_full(position_out, t_owner_in(t_owner_value()), 0, 1, assets.zero, [])
}

fn t_run_full(
  position_out: Output,
  owner_in: Input,
  position_in_idx: Int,
  position_owner_in_idx: Int,
  mint: Value,
  extra_inputs: List<Input>,
) -> Bool {
  modify_position.validate(
    t_position_in(),
    position_out,
    owner_in,
    position_in_idx,
    position_owner_in_idx,
    0,
    Some(t_protocol()),
    t_position_skh,
    list.concat([t_position_in(), owner_in], extra_inputs),
    mint,
    [],
  )
}

/// §16 — no value moves. The three fields §16.2.6 pins are the position's
/// identity; `take_profit_price` and a **rising** `min_execution_amount` are the
/// two a trader may rewrite.
test modify_position_accepts_a_new_take_profit_price() {
  t_run(
    t_position_out(
      t_position_value(constants.min_ada),
      PositionDatum { ..t_position(), take_profit_price: PRational(5, 2) },
    ),
  )
}

/// A zero numerator is the "no take-profit" encoding, so §16 is also how a
/// trader turns one off after the fact.
test modify_position_accepts_clearing_the_take_profit_price() {
  t_run(
    t_position_out(
      t_position_value(constants.min_ada),
      PositionDatum { ..t_position(), take_profit_price: PRational(0, 1) },
    ),
  )
}

test modify_position_accepts_a_rising_min_execution_amount() {
  t_run(
    t_position_out(
      t_position_value(constants.min_ada),
      PositionDatum { ..t_position(), min_execution_amount: 200_000_000 },
    ),
  )
}

test modify_position_accepts_topping_up_the_lovelace() {
  t_run(
    t_position_out(t_position_value(constants.min_ada + 1), t_position()),
  )
}

/// §16.2.7 — `min_execution_amount` may only rise. It is the floor on what a
/// close must realise, so letting it fall would let a trader shrink the
/// protection they set when the position opened.
test modify_position_rejects_a_falling_min_execution_amount() fail {
  t_run(
    t_position_out(
      t_position_value(constants.min_ada),
      PositionDatum { ..t_position(), min_execution_amount: 99_999_999 },
    ),
  )
}

test modify_position_rejects_a_zero_take_profit_denominator() fail {
  t_run(
    t_position_out(
      t_position_value(constants.min_ada),
      PositionDatum { ..t_position(), take_profit_price: PRational(1, 0) },
    ),
  )
}

/// §16.2.6 — `long_token` is what the collateral **is**; rewriting it would
/// re-denominate a position whose loan is already outstanding.
test modify_position_rejects_a_new_long_token() fail {
  t_run(
    t_position_out(
      t_position_value(constants.min_ada),
      PositionDatum { ..t_position(), long_token: ("other_pid", "other") },
    ),
  )
}

test modify_position_rejects_a_new_max_slippage() fail {
  t_run(
    t_position_out(
      t_position_value(constants.min_ada),
      PositionDatum { ..t_position(), max_slippage: 100 },
    ),
  )
}

/// §16.2.6 pins the beneficiary: it is where every closing arm pays the residual,
/// and this arm needs only the owner ticket, which is transferable.
test modify_position_rejects_a_new_beneficiary() fail {
  t_run(
    t_position_out(
      t_position_value(constants.min_ada),
      PositionDatum {
        ..t_position(),
        beneficiary: Address {
          payment_credential: VerificationKey("attacker_vk"),
          stake_credential: None,
        },
      },
    ),
  )
}

/// §16.2.3 — the token bag is compared without lovelace, so the `LoanOwnerNFT`
/// cannot be walked out. Losing it would strand the loan: §10.1.1 and §11.2.1
/// both need one input holding the position and that ticket at once.
test modify_position_rejects_dropping_the_loan_owner_nft() fail {
  let value =
    assets.from_lovelace(constants.min_ada)
      |> assets.merge(assets.from_asset(t_position_skh, t_nft_name, 1))
  t_run(t_position_out(value, t_position()))
}

test modify_position_rejects_an_added_token() fail {
  let value =
    t_position_value(constants.min_ada)
      |> assets.merge(assets.from_asset("junk_pid", "junk", 1))
  t_run(t_position_out(value, t_position()))
}

test modify_position_rejects_lovelace_below_the_floor() fail {
  t_run(t_position_out(t_position_value(constants.min_ada - 1), t_position()))
}

/// §16.2.4 — the `PositionNFT` name carries over, so one transaction cannot
/// rewrite one position's datum onto another's ticket.
test modify_position_rejects_a_renamed_position_nft() fail {
  let value =
    assets.from_lovelace(constants.min_ada)
      |> assets.merge(assets.from_asset(t_position_skh, "second", 1))
      |> assets.merge(assets.from_asset(t_loan_skh, t_owner_name(), 1))
  t_run(t_position_out(value, t_position()))
}

/// §16.2.2 — the `PositionOwnerNFT` is the authorisation. Without it anyone
/// could rewrite anyone's take-profit price.
test modify_position_rejects_an_owner_input_without_the_ticket() fail {
  t_run_full(
    t_position_out(t_position_value(constants.min_ada), t_position()),
    t_owner_in(assets.from_lovelace(constants.min_ada)),
    0,
    1,
    assets.zero,
    [],
  )
}

/// The two indices must differ. The position UTxO does not hold its own owner
/// ticket, but naming it as both would let the position stand in for its own
/// authorisation if it ever did.
test modify_position_rejects_the_position_as_its_own_owner_input() fail {
  t_run_full(
    t_position_out(t_position_value(constants.min_ada), t_position()),
    t_owner_in(t_owner_value()),
    1,
    1,
    assets.zero,
    [],
  )
}

/// §16.2.8 — nothing of `loan_skh` is minted or burned. §16 moves no value, so a
/// mint here could only be a `LoanOwnerNFT` or a `BindingNFT` slipped in beside
/// a datum rewrite.
test modify_position_rejects_a_loan_mint() fail {
  t_run_full(
    t_position_out(t_position_value(constants.min_ada), t_position()),
    t_owner_in(t_owner_value()),
    0,
    1,
    assets.from_asset(t_loan_skh, t_owner_name(), -1),
    [],
  )
}

/// §16.2.9 — no loan and no pool input. §16 carries none of the arithmetic that
/// spending either one requires, so a loan spent beside it would be spent under
/// a redeemer that never checked `debt_now`.
test modify_position_rejects_a_loan_input_alongside() fail {
  let loan_in =
    Input {
      output_reference: OutputReference("loan", 0),
      output: Output {
        address: Address {
          payment_credential: Script(t_loan_skh),
          stake_credential: None,
        },
        value: assets.from_lovelace(constants.min_ada),
        datum: NoDatum,
        reference_script: None,
      },
    }
  t_run_full(
    t_position_out(t_position_value(constants.min_ada), t_position()),
    t_owner_in(t_owner_value()),
    0,
    1,
    assets.zero,
    [loan_in],
  )
}

test modify_position_rejects_a_pool_input_alongside() fail {
  let pool_in =
    Input {
      output_reference: OutputReference("pool", 0),
      output: Output {
        address: Address {
          payment_credential: Script(t_pool_skh),
          stake_credential: None,
        },
        value: assets.from_lovelace(constants.min_ada),
        datum: NoDatum,
        reference_script: None,
      },
    }
  t_run_full(
    t_position_out(t_position_value(constants.min_ada), t_position()),
    t_owner_in(t_owner_value()),
    0,
    1,
    assets.zero,
    [pool_in],
  )
}

/// §16.2.10 — a wallet-held owner NFT may decline to resolve the registry, and
/// then §16.2.8 and §16.2.9 have no hashes to test against. That is sound
/// because both rules exist to stop a loan or pool being touched, and without
/// the registry this redeemer cannot name either script to begin with.
test modify_position_admits_an_unresolved_registry_for_a_wallet_owner() {
  modify_position.validate(
    t_position_in(),
    t_position_out(
      t_position_value(constants.min_ada),
      PositionDatum { ..t_position(), take_profit_price: PRational(5, 2) },
    ),
    t_owner_in(t_owner_value()),
    0,
    1,
    -1,
    None,
    t_position_skh,
    [t_position_in(), t_owner_in(t_owner_value())],
    assets.zero,
    [],
  )
}
