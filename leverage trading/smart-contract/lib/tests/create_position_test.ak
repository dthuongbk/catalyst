//// Unit tests for `position/create_position.ak`.
////
//// They live outside that module rather than beside it, which departs from this
//// repository's own habit — the ninety-four tests that came before are inline in
//// the module each one exercises. The reason is that the live registry pins every
//// validator hash to the bytes of its own source, so no file under `lib/` that a
//// validator compiles from may change while that registry is in use. A new module
//// costs nothing on chain: `aiken` strips tests from the blueprint, and these
//// reach only what `position/create_position.ak` already exports.

use cardano/address.{Address, Script, VerificationKey}
use cardano/assets.{AssetName, Value}
use cardano/transaction.{InlineDatum, Input, NoDatum, Output, OutputReference}
use constants
use daken/input_hash
use daken/prational.{PRational}
use position/create_position
use types.{PositionDatum, ProtocolDatum}
use utils


const t_position_skh =
  #"11111111111111111111111111111111111111111111111111111111"

const t_loan_skh = #"22222222222222222222222222222222222222222222222222222222"

const t_long = ("usdm_pid", "usdm")

fn t_wallet() -> Address {
  Address {
    payment_credential: VerificationKey("wallet_vk"),
    stake_credential: None,
  }
}

fn t_seed() -> Input {
  Input {
    output_reference: OutputReference(
      #"2b405c773982c6cddf1d8b8a80769a84851f3ce21febbb227777b3ba43be14f1",
      0,
    ),
    output: Output {
      address: t_wallet(),
      value: assets.from_lovelace(10_000_000),
      datum: NoDatum,
      reference_script: None,
    },
  }
}

fn t_seed_name() -> AssetName {
  input_hash.blake2b_224(t_seed())
}

fn t_protocol() -> ProtocolDatum {
  ProtocolDatum {
    pool_skh: "pool_skh",
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

/// §7.2.19's value clause: minADA, the `PositionNFT` and the `LoanOwnerNFT`,
/// both named by the seed's hash.
fn t_value(lovelace: Int, nft_name: AssetName, owner_name: AssetName) -> Value {
  assets.from_lovelace(lovelace)
    |> assets.merge(assets.from_asset(t_position_skh, nft_name, 1))
    |> assets.merge(assets.from_asset(t_loan_skh, owner_name, 1))
}

fn t_out(value: Value, position: PositionDatum) -> Output {
  Output {
    address: Address {
      payment_credential: Script(t_position_skh),
      stake_credential: None,
    },
    value,
    datum: InlineDatum(position),
    reference_script: None,
  }
}

fn t_run(value: Value, position: PositionDatum) -> Bool {
  create_position.validate(
    t_out(value, position),
    t_position_skh,
    t_seed(),
    t_protocol(),
    fn(position_nft_name, position_owner_nft_name) {
      and {
        (position_nft_name == t_seed_name())?,
        (position_owner_nft_name == utils.suffixed(
          t_seed_name(),
          constants.owner_nft_suffix,
        ))?,
      }
    },
  )
}

/// §7.2.10 and §7.2.11 — one seed hash names the `PositionNFT`, the
/// `LoanOwnerNFT` and, with the suffix, the `PositionOwnerNFT`. A position
/// exists only as the product of a fill, so this is the whole of its creation.
test create_position_accepts_the_shape_a_fill_writes() {
  t_run(
    t_value(constants.min_ada, t_seed_name(), t_seed_name()),
    t_position(),
  )
}

test create_position_admits_lovelace_above_the_floor() {
  t_run(
    t_value(constants.min_ada + 1, t_seed_name(), t_seed_name()),
    t_position(),
  )
}

/// §7.2.21 — a position output below `min_ada` is one the ledger would not
/// accept anyway, but the equality matters because every closing arm's lovelace
/// arithmetic is stated relative to this floor.
test create_position_rejects_lovelace_below_the_floor() fail {
  t_run(
    t_value(constants.min_ada - 1, t_seed_name(), t_seed_name()),
    t_position(),
  )
}

/// §7.2.10 — the `PositionNFT` name is the seed's hash and not the minter's
/// choice, which is what makes it unique: an output reference is spent once.
test create_position_rejects_a_position_nft_the_seed_did_not_name() fail {
  let wrong = #"33333333333333333333333333333333333333333333333333333333"
  t_run(t_value(constants.min_ada, wrong, t_seed_name()), t_position())
}

/// §7.2.19 pins the `LoanOwnerNFT` by name because §10.1.1, §11.2.1 and §12.3.1
/// later read the loan **through** it. A position carrying another loan's ticket
/// would pair with a loan it never backed.
test create_position_rejects_a_loan_owner_nft_of_another_name() fail {
  let other = #"44444444444444444444444444444444444444444444444444444444"
  t_run(t_value(constants.min_ada, t_seed_name(), other), t_position())
}

test create_position_rejects_a_missing_loan_owner_nft() fail {
  let value =
    assets.from_lovelace(constants.min_ada)
      |> assets.merge(assets.from_asset(t_position_skh, t_seed_name(), 1))
  t_run(value, t_position())
}

/// The whitelist of §7.2.19. A position that opened holding a token nobody
/// accounted for would carry it through every closing arm untouched — the
/// closing arms measure the collateral on the **loan**, not here.
test create_position_rejects_an_asset_outside_the_whitelist() fail {
  let value =
    t_value(constants.min_ada, t_seed_name(), t_seed_name())
      |> assets.merge(assets.from_asset("junk_pid", "junk", 1))
  t_run(value, t_position())
}

/// §7.2.19 inherits §16.2.7's datum sanity from the order it copies, so a
/// position cannot open with a zero denominator that the first take-profit
/// evaluation would divide by.
test create_position_rejects_a_datum_that_fails_the_param_bounds() fail {
  t_run(
    t_value(constants.min_ada, t_seed_name(), t_seed_name()),
    PositionDatum { ..t_position(), take_profit_price: PRational(1, 0) },
  )
}

test create_position_rejects_a_zero_min_execution_amount() fail {
  t_run(
    t_value(constants.min_ada, t_seed_name(), t_seed_name()),
    PositionDatum { ..t_position(), min_execution_amount: 0 },
  )
}
