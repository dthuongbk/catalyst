//// Unit tests for `position/close_position.ak`.
////
//// They live outside that module rather than beside it, which departs from this
//// repository's own habit — the ninety-four tests that came before are inline in
//// the module each one exercises. The reason is that the live registry pins every
//// validator hash to the bytes of its own source, so no file under `lib/` that a
//// validator compiles from may change while that registry is in use. A new module
//// costs nothing on chain: `aiken` strips tests from the blueprint, and these
//// reach only what `position/close_position.ak` already exports.

use cardano/address.{Address, Script, VerificationKey}
use cardano/assets.{AssetName, Value}
use cardano/transaction.{
  InlineDatum, Input, NoDatum, Output, OutputReference, Redeemer, ScriptPurpose,
  Withdraw,
}
use constants
use daken/prational.{PRational}
use daken/types as daken_types
use position/close_position
use types.{LoanDatum, PositionDatum, ProtocolDatum}
use utils


const t_position_skh =
  #"11111111111111111111111111111111111111111111111111111111"

const t_loan_skh = #"22222222222222222222222222222222222222222222222222222222"

const t_loan_repay_skh =
  #"33333333333333333333333333333333333333333333333333333333"

const t_loan_close_skh =
  #"44444444444444444444444444444444444444444444444444444444"

const t_nft_name = #"55555555555555555555555555555555555555555555555555555555"

fn t_wallet() -> Address {
  Address {
    payment_credential: VerificationKey("wallet_vk"),
    stake_credential: None,
  }
}

fn t_owner_name() -> AssetName {
  utils.suffixed(t_nft_name, constants.owner_nft_suffix)
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
    loan_repay_skh: t_loan_repay_skh,
    loan_close_skh: t_loan_close_skh,
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

/// The position holds its own `PositionNFT` and the loan's `LoanOwnerNFT` — the
/// pairing §10.1.1 reads.
fn t_position_value(owner_name: AssetName) -> Value {
  assets.from_lovelace(constants.min_ada)
    |> assets.merge(assets.from_asset(t_position_skh, t_nft_name, 1))
    |> assets.merge(assets.from_asset(t_loan_skh, owner_name, 1))
}

fn t_position_out() -> Output {
  Output {
    address: Address {
      payment_credential: Script(t_position_skh),
      stake_credential: None,
    },
    value: t_position_value(t_owner_name()),
    datum: InlineDatum(t_position()),
    reference_script: None,
  }
}

fn t_position_in() -> Input {
  Input {
    output_reference: OutputReference("position", 0),
    output: t_position_out(),
  }
}

fn t_loan_datum(owner_nft: Option<daken_types.TupleAsset>) -> LoanDatum {
  LoanDatum {
    owner_nft,
    token: (#"", #""),
    loan_amount: 100_000_000,
    initial_interest_index: constants.initial_interest_index,
    claim: None,
  }
}

fn t_loan_out_at(skh: ByteArray) -> Output {
  Output {
    address: Address {
      payment_credential: Script(skh),
      stake_credential: None,
    },
    value: assets.from_lovelace(constants.min_ada),
    datum: InlineDatum(t_loan_datum(Some((t_loan_skh, t_owner_name())))),
    reference_script: None,
  }
}

fn t_loan_in() -> Input {
  Input {
    output_reference: OutputReference("loan", 0),
    output: t_loan_out_at(t_loan_skh),
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

fn t_withdrawals(skh: ByteArray) -> Pairs<ScriptPurpose, Redeemer> {
  // `Redeemer` is `Data`; the upcast has to be written out.
  let rdmr: Data = 0
  [Pair(Withdraw(Script(skh)), rdmr)]
}

fn t_run(
  position_in: Input,
  loan_in: Input,
  owner_in: Option<Input>,
  position_owner_in_idx: Int,
  loan_out_idx: Int,
  position_out_idx: Int,
  outputs: List<Output>,
  redeemers: Pairs<ScriptPurpose, Redeemer>,
  want: List<(AssetName, Int)>,
) -> Bool {
  close_position.validate(
    position_in,
    loan_in,
    owner_in,
    0,
    position_owner_in_idx,
    loan_out_idx,
    position_out_idx,
    outputs,
    0,
    t_protocol(),
    t_position_skh,
    redeemers,
    fn(mint_contribution) { (mint_contribution == want)? },
  )
}

/// §10.1 — the one closing arm whose owner presents the `PositionOwnerNFT`, and
/// so the only one that burns it. Both tickets go.
test close_position_burns_both_where_the_owner_presents_the_ticket() {
  t_run(
    t_position_in(),
    t_loan_in(),
    Some(t_owner_in(t_owner_value())),
    1,
    -1,
    -1,
    [],
    t_withdrawals(t_loan_repay_skh),
    [(t_nft_name, -1), (t_owner_name(), -1)],
  )
}

/// §10.2.2, §11 and §12.3 are permissionless: nobody presents an owner ticket,
/// so the `PositionOwnerNFT` stays alive and the residual §13 parks stays
/// claimable by whoever holds it.
test close_position_burns_the_position_alone_where_no_owner_is_presented() {
  t_run(
    t_position_in(),
    t_loan_in(),
    None,
    -1,
    -1,
    -1,
    [],
    t_withdrawals(t_loan_close_skh),
    [(t_nft_name, -1)],
  )
}

/// §10.2.1 and §12.4 — the position survives byte-identical and nothing is
/// contributed to `mint[position_skh]`. A full record equality is what says
/// "byte-identical": `position_shape` has already forced the input's
/// `reference_script` to `None`, so the comparison adds nothing else.
test close_position_keeps_both_where_the_position_survives() {
  t_run(
    t_position_in(),
    t_loan_in(),
    None,
    -1,
    1,
    0,
    [t_position_out(), t_loan_out_at(t_loan_skh)],
    t_withdrawals(t_loan_repay_skh),
    [],
  )
}

/// §5 rule 11a on the position side — the loan and the position are retired
/// together or neither is. Without the equality a transaction could burn the
/// position while the loan lived on, leaving a debt in `total_borrow` that no
/// arm could ever reach.
test close_position_rejects_a_surviving_loan_beside_a_burned_position() fail {
  t_run(
    t_position_in(),
    t_loan_in(),
    None,
    -1,
    1,
    -1,
    [t_position_out(), t_loan_out_at(t_loan_skh)],
    t_withdrawals(t_loan_repay_skh),
    [],
  )
}

test close_position_rejects_a_surviving_position_beside_a_burned_loan() fail {
  t_run(
    t_position_in(),
    t_loan_in(),
    None,
    -1,
    -1,
    0,
    [t_position_out()],
    t_withdrawals(t_loan_repay_skh),
    [],
  )
}

/// §5 rule 18 split §10 onto `loan_repay` and §11, §12 and §13 onto
/// `loan_close`, so naming `loan_skh` alone here left every arm that spends a
/// position unbuildable. Any of the three hosts satisfies the rule.
test close_position_accepts_the_withdrawal_at_any_of_the_three_hosts() {
  let burn_both = [(t_nft_name, -1), (t_owner_name(), -1)]
  and {
    t_run(
      t_position_in(), t_loan_in(), Some(t_owner_in(t_owner_value())),
      1, -1, -1, [], t_withdrawals(t_loan_skh), burn_both,
    )?,
    t_run(
      t_position_in(), t_loan_in(), Some(t_owner_in(t_owner_value())),
      1, -1, -1, [], t_withdrawals(t_loan_repay_skh), burn_both,
    )?,
    t_run(
      t_position_in(), t_loan_in(), Some(t_owner_in(t_owner_value())),
      1, -1, -1, [], t_withdrawals(t_loan_close_skh), burn_both,
    )?,
  }
}

/// The loan's withdrawal carries every piece of arithmetic this arm defers:
/// `debt_now`, §7.2.18's pool equation, §10.3's shortfall, §13.2's remain UTxO.
/// §5 rule 16 makes it a precondition of spending the loan at all, so requiring
/// it here is what lets the position side hold none of that.
test close_position_rejects_a_missing_loan_withdrawal() fail {
  t_run(
    t_position_in(),
    t_loan_in(),
    None,
    -1,
    -1,
    -1,
    [],
    t_withdrawals("some_other_skh"),
    [(t_nft_name, -1)],
  )
}

/// §10.1.1 — the pairing is the whole of the position's claim on the loan. A
/// position holding some other loan's ticket would let one loan's closure
/// consume another's collateral.
test close_position_rejects_a_position_holding_another_loans_ticket() fail {
  let other = utils.suffixed(#"66666666666666666666666666666666666666666666666666666666", constants.owner_nft_suffix)
  let position_in =
    Input {
      output_reference: OutputReference("position", 0),
      output: Output { ..t_position_out(), value: t_position_value(other) },
    }
  t_run(
    position_in,
    t_loan_in(),
    None,
    -1,
    -1,
    -1,
    [],
    t_withdrawals(t_loan_close_skh),
    [(t_nft_name, -1)],
  )
}

/// §7.6 opens a loan with no order and no position, so its `owner_nft` is
/// `None`. Reaching a closing arm with such a loan means the arm paired a
/// position with a loan that never had one.
test close_position_rejects_a_loan_naming_no_owner_nft() fail {
  let loan_in =
    Input {
      output_reference: OutputReference("loan", 0),
      output: Output {
        ..t_loan_out_at(t_loan_skh),
        datum: InlineDatum(t_loan_datum(None)),
      },
    }
  t_run(
    t_position_in(), loan_in, None, -1, -1, -1, [],
    t_withdrawals(t_loan_close_skh), [(t_nft_name, -1)],
  )
}

test close_position_rejects_a_loan_input_at_another_script() fail {
  let loan_in =
    Input {
      output_reference: OutputReference("loan", 0),
      output: t_loan_out_at("elsewhere_skh"),
    }
  t_run(
    t_position_in(), loan_in, None, -1, -1, -1, [],
    t_withdrawals(t_loan_close_skh), [(t_nft_name, -1)],
  )
}

/// §10.2.1.10 and §12.4.8 — byte-identical. A single lovelace of drift on the
/// surviving position is what a caller would use to skim its minADA.
test close_position_rejects_a_surviving_position_that_drifted() fail {
  let drifted =
    Output {
      ..t_position_out(),
      value: assets.from_lovelace(constants.min_ada + 1)
        |> assets.merge(assets.from_asset(t_position_skh, t_nft_name, 1))
        |> assets.merge(assets.from_asset(t_loan_skh, t_owner_name(), 1)),
    }
  t_run(
    t_position_in(), t_loan_in(), None, -1, 1, 0,
    [drifted, t_loan_out_at(t_loan_skh)],
    t_withdrawals(t_loan_repay_skh), [],
  )
}

/// §12.4.5 and §10.2.1.8 — the surviving loan stays at its own script. Its
/// datum and value are the loan withdrawal's business; its address is this
/// arm's, because a loan moved off `loan_skh` would be unspendable and its
/// collateral gone.
test close_position_rejects_a_surviving_loan_at_another_script() fail {
  t_run(
    t_position_in(), t_loan_in(), None, -1, 1, 0,
    [t_position_out(), t_loan_out_at("elsewhere_skh")],
    t_withdrawals(t_loan_repay_skh), [],
  )
}

/// §10.1.3 — the owner input has to actually hold the ticket. Presenting any
/// UTxO would otherwise close a position on nobody's authority.
test close_position_rejects_an_owner_input_without_the_ticket() fail {
  t_run(
    t_position_in(),
    t_loan_in(),
    Some(t_owner_in(assets.from_lovelace(constants.min_ada))),
    1,
    -1,
    -1,
    [],
    t_withdrawals(t_loan_repay_skh),
    [(t_nft_name, -1), (t_owner_name(), -1)],
  )
}

/// The index and the input travel together: an owner input present with `-1`, or
/// absent with an index, would let the arm be selected as one shape and checked
/// as another — and the two shapes differ in whether the `PositionOwnerNFT` is
/// burned.
test close_position_rejects_an_owner_input_with_a_minus_one_index() fail {
  t_run(
    t_position_in(), t_loan_in(), Some(t_owner_in(t_owner_value())),
    -1, -1, -1, [], t_withdrawals(t_loan_repay_skh),
    [(t_nft_name, -1), (t_owner_name(), -1)],
  )
}

test close_position_rejects_a_named_owner_index_with_no_owner_input() fail {
  t_run(
    t_position_in(), t_loan_in(), None, 1, -1, -1, [],
    t_withdrawals(t_loan_repay_skh), [(t_nft_name, -1)],
  )
}

/// The position UTxO cannot be its own authorisation, and it never holds its own
/// owner ticket — but the two indices are compared anyway, because the check
/// costs nothing and the alternative is relying on that invariant holding.
test close_position_rejects_the_position_as_its_own_owner_input() fail {
  t_run(
    t_position_in(), t_loan_in(), Some(t_owner_in(t_owner_value())),
    0, -1, -1, [], t_withdrawals(t_loan_repay_skh),
    [(t_nft_name, -1), (t_owner_name(), -1)],
  )
}
