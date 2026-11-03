//// Unit tests for `order/modify_order.ak`.
////
//// They live outside that module rather than beside it, which departs from this
//// repository's own habit — the ninety-four tests that came before are inline in
//// the module each one exercises. The reason is that the live registry pins every
//// validator hash to the bytes of its own source, so no file under `lib/` that a
//// validator compiles from may change while that registry is in use. A new module
//// costs nothing on chain: `aiken` strips tests from the blueprint, and these
//// reach only what `order/modify_order.ak` already exports.

use cardano/address.{Address, Script, VerificationKey}
use cardano/assets.{AssetName, Value}
use cardano/transaction.{
  InlineDatum, Input, NoDatum, Output, OutputReference,
}
use constants
use daken/prational.{PRational}
use order/modify_order
use order/utils as order_utils
use types.{MarketDatum, OrderDatum, ProtocolDatum}
use utils


const t_order_skh = #"11111111111111111111111111111111111111111111111111111111"

const t_position_skh =
  #"22222222222222222222222222222222222222222222222222222222"

const t_loan_skh = #"33333333333333333333333333333333333333333333333333333333"

const t_nft_name = #"44444444444444444444444444444444444444444444444444444444"

const t_pos_nft_name =
  #"55555555555555555555555555555555555555555555555555555555"

const t_ada = (#"", #"")

const t_usdm = ("usdm_pid", "usdm")

const t_market_nft_name = "usdm_market"

fn t_wallet() -> Address {
  Address {
    payment_credential: VerificationKey("wallet_vk"),
    stake_credential: None,
  }
}

fn t_order_address() -> Address {
  Address { payment_credential: Script(t_order_skh), stake_credential: None }
}

fn t_owner_name() -> AssetName {
  utils.suffixed(t_nft_name, constants.owner_nft_suffix)
}

fn t_pos_owner_name() -> AssetName {
  utils.suffixed(t_pos_nft_name, constants.owner_nft_suffix)
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
    admin_nft: ("nft_mint", "adminADM"),
    oracle_skh: "oracle_skh",
    oracle_ready_at: 0,
    pending_oracle: None,
    loan_repay_skh: "loan_repay_skh",
    loan_close_skh: "loan_close_skh",
  }
}

/// `long_token` is ADA and is the collateral; `short_token` is the supply token,
/// so `margin` is the order's own fUSDM holding.
fn t_market() -> MarketDatum {
  MarketDatum {
    collaterals: [Pair(t_ada, (8000, True))],
    base_rate: 400,
    power_base: 10470,
    util_cap: 9000,
    withdrawal_fee: 0,
    loan_fee_rate: 2000,
    loan_origination_fee_rate: 0,
    loan_origination_fee_min_amount: 0,
    fee_address: t_wallet(),
    supply_token: t_usdm,
    alt_supply_tokens: [],
    min_tx_amount: 100_000_000,
    liquidator_reward_cap: 1000,
    collector_reward: 1_200_000,
    min_liquidator_reward: 10_000_000,
    rollback_tip: 1_100_000,
    execution_tip: 1_100_000,
    max_cancel_fee: 200_000,
    venue_fee_budget: 8_400_000,
    max_slippage_cap: 300,
    min_claim_duration: 600_000,
    max_claim_duration: 600_000,
    max_index_staleness: 3_600_000,
    claim_safety_margin: 50,
    fillability_margin: 50,
  }
}

fn t_datum() -> OrderDatum {
  OrderDatum {
    long_token: t_ada,
    short_token: t_usdm,
    short_amount: 500_000_000,
    open_limit_price: PRational(1, 1),
    take_profit_price: PRational(2, 1),
    min_liquidation_threshold: 8000,
    min_execution_amount: 100_000_000,
    max_slippage: 300,
    allowed_adapters: [],
    is_market: False,
    market_nft_name: t_market_nft_name,
    beneficiary: t_wallet(),
    fee_reserve: 0,
  }
}

/// minADA, the margin in `short_token`, the `OrderNFT`, and optionally a
/// `PositionOwnerNFT` parked here by a fill — §7.2.14.
fn t_value(lovelace: Int, margin: Int, parked: Bool) -> Value {
  let base =
    assets.from_lovelace(lovelace)
      |> assets.merge(assets.from_asset(t_order_skh, t_nft_name, 1))
  let with_margin =
    if margin == 0 {
      base
    } else {
      base |> assets.merge(assets.from_asset("usdm_pid", "usdm", margin))
    }
  if parked {
    with_margin
      |> assets.merge(
          assets.from_asset(t_position_skh, t_pos_owner_name(), 1),
        )
  } else {
    with_margin
  }
}

fn t_order_in(value: Value, datum: OrderDatum) -> Input {
  Input {
    output_reference: OutputReference("order", 0),
    output: Output {
      address: t_order_address(),
      value,
      datum: InlineDatum(datum),
      reference_script: None,
    },
  }
}

fn t_order_out(value: Value, datum: OrderDatum) -> Output {
  Output {
    address: t_order_address(),
    value,
    datum: InlineDatum(datum),
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
    |> assets.merge(assets.from_asset(t_order_skh, t_owner_name(), 1))
}

/// A wallet output the released `PositionOwnerNFT` may go to — §9.2.4 requires
/// it to sit outside every protocol script.
fn t_release_out(address: Address) -> Output {
  Output {
    address,
    value: assets.from_lovelace(constants.min_ada)
      |> assets.merge(
          assets.from_asset(t_position_skh, t_pos_owner_name(), 1),
        ),
    datum: NoDatum,
    reference_script: None,
  }
}

fn t_update(
  in_value: Value,
  in_datum: OrderDatum,
  out_value: Value,
  out_datum: OrderDatum,
  owner_in: Input,
  order_in_idx: Int,
  order_owner_in_idx: Int,
  owner_release_out_idx: Int,
  market_ref_idx: Int,
  outputs: List<Output>,
  mint: Value,
) -> Bool {
  modify_order.validate_update(
    t_order_in(in_value, in_datum),
    t_order_out(out_value, out_datum),
    owner_in,
    order_in_idx,
    order_owner_in_idx,
    owner_release_out_idx,
    market_ref_idx,
    outputs,
    mint,
    t_protocol(),
    t_order_skh,
    t_market(),
  )
}

/// The canonical §9.2: the order at index 0, its owner ticket in a wallet at
/// index 1, the market resolved, nothing released and nothing minted.
fn t_plain(out_value: Value, out_datum: OrderDatum) -> Bool {
  t_update(
    t_value(constants.min_ada, 100_000_000, False),
    t_datum(),
    out_value,
    out_datum,
    t_owner_in(t_owner_value()),
    0,
    1,
    -1,
    0,
    [],
    assets.zero,
  )
}

// --------------------------------------------------------------- §9.2, update

/// §9.2.6 — `short_amount` may only fall, and must stay strictly above what the
/// order still holds in `short_token`. Shrinking the order is the whole point of
/// the arm: it is how a trader walks back an order nobody has filled.
test modify_order_accepts_a_falling_short_amount() {
  t_plain(
    t_value(constants.min_ada, 100_000_000, False),
    OrderDatum { ..t_datum(), short_amount: 400_000_000 },
  )
}

/// §9.2.5 — `fee_reserve` may rise, and §9.2.4 requires the lovelace to rise
/// with it. Topping the reserve up is how a resting limit order becomes
/// asynchronously fillable, which §7.4.9 now gates on funding rather than on
/// `is_market`.
test modify_order_accepts_a_funded_fee_reserve_rise() {
  let afc = order_utils.async_fill_cost(8_400_000, 1_100_000)
  t_plain(
    t_value(constants.min_ada + afc, 100_000_000, False),
    OrderDatum { ..t_datum(), short_amount: 400_000_000, fee_reserve: afc },
  )
}

/// The reserve is lovelace the order must actually be carrying. Raising the
/// field alone would let a trader claim a funded reserve the fill then spends
/// out of the margin.
test modify_order_rejects_a_fee_reserve_rise_without_the_lovelace() fail {
  t_plain(
    t_value(constants.min_ada, 100_000_000, False),
    OrderDatum { ..t_datum(), short_amount: 400_000_000, fee_reserve: 19_500_000 },
  )
}

/// §9.2.5 — the reserve may only rise. Letting it fall would be a withdrawal
/// dressed as a datum edit: §2.2 keeps the reserve out of `margin`, so dropping
/// it converts protocol-owed lovelace into collateral.
test modify_order_rejects_a_falling_fee_reserve() fail {
  let afc = order_utils.async_fill_cost(8_400_000, 1_100_000)
  t_update(
    t_value(constants.min_ada + afc, 100_000_000, False),
    OrderDatum { ..t_datum(), fee_reserve: afc },
    t_value(constants.min_ada + afc, 100_000_000, False),
    OrderDatum { ..t_datum(), short_amount: 400_000_000, fee_reserve: 0 },
    t_owner_in(t_owner_value()),
    0,
    1,
    -1,
    0,
    [],
    assets.zero,
  )
}

test modify_order_rejects_a_rising_short_amount() fail {
  t_plain(
    t_value(constants.min_ada, 100_000_000, False),
    OrderDatum { ..t_datum(), short_amount: 500_000_001 },
  )
}

/// §9.2.6's strict inequality. An order whose `short_amount` has fallen to what
/// it already holds has nothing left to borrow against, and §7.2's
/// `total_borrowed_value` would be zero — which `order/utils` rejects rather
/// than divide by.
test modify_order_rejects_a_short_amount_down_to_the_margin() fail {
  t_plain(
    t_value(constants.min_ada, 100_000_000, False),
    OrderDatum { ..t_datum(), short_amount: 100_000_000 },
  )
}

/// §9.2.6 re-checks §2.18's leverage cap against the market reference input, so
/// shrinking `short_amount` cannot be used to leave a position more leveraged
/// than the collateral's threshold admits. `leverage_cap(8000, 0)` is 5.00x, and
/// the fixture sits exactly there.
test modify_order_rejects_breaching_the_leverage_cap() fail {
  t_update(
    t_value(constants.min_ada, 100_000_000, False),
    OrderDatum { ..t_datum(), short_amount: 600_000_000 },
    t_value(constants.min_ada, 100_000_000, False),
    OrderDatum { ..t_datum(), short_amount: 500_000_001 },
    t_owner_in(t_owner_value()),
    0,
    1,
    -1,
    0,
    [],
    assets.zero,
  )
}

/// §9.2.5 — the four immutables. `beneficiary` is where the fill pays, so it is
/// the one an owner-ticket holder would most want to rewrite; the ticket is
/// transferable, and the order's proceeds are not.
test modify_order_rejects_a_new_beneficiary() fail {
  t_plain(
    t_value(constants.min_ada, 100_000_000, False),
    OrderDatum {
      ..t_datum(),
      short_amount: 400_000_000,
      beneficiary: Address {
        payment_credential: VerificationKey("attacker_vk"),
        stake_credential: None,
      },
    },
  )
}

test modify_order_rejects_a_new_long_token() fail {
  t_plain(
    t_value(constants.min_ada, 100_000_000, False),
    OrderDatum {
      ..t_datum(),
      short_amount: 400_000_000,
      long_token: ("other_pid", "other"),
    },
  )
}

test modify_order_rejects_a_new_short_token() fail {
  t_plain(
    t_value(constants.min_ada, 100_000_000, False),
    OrderDatum {
      ..t_datum(),
      short_amount: 400_000_000,
      short_token: ("other_pid", "other"),
    },
  )
}

/// `market_nft_name` is which market the order belongs to. Rewriting it would
/// let an order posted against one market be filled out of another's pool.
test modify_order_rejects_a_new_market_nft_name() fail {
  t_plain(
    t_value(constants.min_ada, 100_000_000, False),
    OrderDatum {
      ..t_datum(),
      short_amount: 400_000_000,
      market_nft_name: "another_market",
    },
  )
}

/// §9.2.7 — the datum bounds are re-checked verbatim against the market. A
/// `min_execution_amount` below `min_tx_amount` would post an order the fill
/// arms could never satisfy.
test modify_order_rejects_a_min_execution_below_the_market_floor() fail {
  t_plain(
    t_value(constants.min_ada, 100_000_000, False),
    OrderDatum {
      ..t_datum(),
      short_amount: 400_000_000,
      min_execution_amount: 99_999_999,
    },
  )
}

test modify_order_rejects_a_max_slippage_above_the_cap() fail {
  t_plain(
    t_value(constants.min_ada, 100_000_000, False),
    OrderDatum { ..t_datum(), short_amount: 400_000_000, max_slippage: 301 },
  )
}

/// §9.2.4 — lovelace may only rise. The margin and the reserve both live in the
/// order UTxO's value, so a decrease is a withdrawal, and §9.2 moves nothing out
/// but a `PositionOwnerNFT`.
test modify_order_rejects_a_lovelace_decrease() fail {
  t_update(
    t_value(constants.min_ada + 1, 100_000_000, False),
    t_datum(),
    t_value(constants.min_ada, 100_000_000, False),
    OrderDatum { ..t_datum(), short_amount: 400_000_000 },
    t_owner_in(t_owner_value()),
    0,
    1,
    -1,
    0,
    [],
    assets.zero,
  )
}

/// Every other token is held at equality, so the margin cannot be walked out
/// under cover of a datum edit.
test modify_order_rejects_removing_the_margin() fail {
  t_plain(
    t_value(constants.min_ada, 0, False),
    OrderDatum { ..t_datum(), short_amount: 400_000_000 },
  )
}

test modify_order_rejects_an_added_token() fail {
  let out =
    t_value(constants.min_ada, 100_000_000, False)
      |> assets.merge(assets.from_asset("junk_pid", "junk", 1))
  t_plain(out, OrderDatum { ..t_datum(), short_amount: 400_000_000 })
}

/// §9.2.2 — the `OrderOwnerNFT` is the authorisation, and the two indices must
/// differ so the order cannot stand in for its own consent.
test modify_order_rejects_an_owner_input_without_the_ticket() fail {
  t_update(
    t_value(constants.min_ada, 100_000_000, False),
    t_datum(),
    t_value(constants.min_ada, 100_000_000, False),
    OrderDatum { ..t_datum(), short_amount: 400_000_000 },
    t_owner_in(assets.from_lovelace(constants.min_ada)),
    0,
    1,
    -1,
    0,
    [],
    assets.zero,
  )
}

test modify_order_rejects_the_order_as_its_own_owner_input() fail {
  t_update(
    t_value(constants.min_ada, 100_000_000, False),
    t_datum(),
    t_value(constants.min_ada, 100_000_000, False),
    OrderDatum { ..t_datum(), short_amount: 400_000_000 },
    t_owner_in(t_owner_value()),
    1,
    1,
    -1,
    0,
    [],
    assets.zero,
  )
}

/// §9.2.1 with §5 rule 3 — the update arm reads the market, so it may not
/// decline to resolve it. §9.2.6 and §9.2.7 are both stated against it.
test modify_order_rejects_a_missing_market_reference() fail {
  t_update(
    t_value(constants.min_ada, 100_000_000, False),
    t_datum(),
    t_value(constants.min_ada, 100_000_000, False),
    OrderDatum { ..t_datum(), short_amount: 400_000_000 },
    t_owner_in(t_owner_value()),
    0,
    1,
    -1,
    -1,
    [],
    assets.zero,
  )
}

/// §9.2.3 — the order stays at its own address, both credentials. Moving it
/// would strand it: nothing else in the protocol looks for an order anywhere
/// else.
test modify_order_rejects_a_moved_order_output() fail {
  modify_order.validate_update(
    t_order_in(t_value(constants.min_ada, 100_000_000, False), t_datum()),
    Output {
      address: Address {
        payment_credential: Script(t_order_skh),
        stake_credential: Some(address.Inline(Script("stake_skh"))),
      },
      value: t_value(constants.min_ada, 100_000_000, False),
      datum: InlineDatum(OrderDatum { ..t_datum(), short_amount: 400_000_000 }),
      reference_script: None,
    },
    t_owner_in(t_owner_value()),
    0,
    1,
    -1,
    0,
    [],
    assets.zero,
    t_protocol(),
    t_order_skh,
    t_market(),
  )
}

// ------------------------------------------- §9.2.4, releasing a parked ticket

/// §7.2.14 parks the `PositionOwnerNFT` in the order UTxO, and DEPLOYMENT.md §6
/// item 11 records that a filled order goes on holding it. §9.2.4 is how it
/// leaves: to an output outside every protocol script.
test modify_order_accepts_releasing_a_parked_position_owner_nft() {
  t_update(
    t_value(constants.min_ada, 100_000_000, True),
    t_datum(),
    t_value(constants.min_ada, 100_000_000, False),
    t_datum(),
    t_owner_in(t_owner_value()),
    0,
    1,
    0,
    0,
    [t_release_out(t_wallet())],
    assets.zero,
  )
}

/// The `only_release` case §9.2.6's `<=` exists for: a fully consumed order,
/// `short_amount` at zero and no margin left, whose one remaining job is to hand
/// the ticket back. The strict inequality would make that unbuildable.
test modify_order_accepts_releasing_from_a_fully_consumed_order() {
  let consumed = OrderDatum { ..t_datum(), short_amount: 0 }
  t_update(
    t_value(constants.min_ada, 0, True),
    consumed,
    t_value(constants.min_ada, 0, False),
    consumed,
    t_owner_in(t_owner_value()),
    0,
    1,
    0,
    0,
    [t_release_out(t_wallet())],
    assets.zero,
  )
}

/// §9.2.4's other destination: the ticket is burned instead, which §13.3 admits
/// through `BurnOwnerNFT`.
test modify_order_accepts_burning_the_released_ticket_instead() {
  t_update(
    t_value(constants.min_ada, 100_000_000, True),
    t_datum(),
    t_value(constants.min_ada, 100_000_000, False),
    t_datum(),
    t_owner_in(t_owner_value()),
    0,
    1,
    -1,
    0,
    [],
    assets.from_asset(t_position_skh, t_pos_owner_name(), -1),
  )
}

/// The released ticket has to actually arrive. Without the equality it would go
/// to the transaction's change, which is where a caller's own wallet is — the
/// point of the rule is that the position's owner keeps it, and the order's
/// owner is not necessarily the same person.
test modify_order_rejects_a_release_that_arrives_nowhere() fail {
  t_update(
    t_value(constants.min_ada, 100_000_000, True),
    t_datum(),
    t_value(constants.min_ada, 100_000_000, False),
    t_datum(),
    t_owner_in(t_owner_value()),
    0,
    1,
    -1,
    0,
    [],
    assets.zero,
  )
}

/// §9.2.4 — outside **every** protocol script. An output at `position_skh`
/// would park the ticket where the position script's own arms could move it.
test modify_order_rejects_a_release_into_a_protocol_script() fail {
  t_update(
    t_value(constants.min_ada, 100_000_000, True),
    t_datum(),
    t_value(constants.min_ada, 100_000_000, False),
    t_datum(),
    t_owner_in(t_owner_value()),
    0,
    1,
    0,
    0,
    [
      t_release_out(
        Address {
          payment_credential: Script(t_position_skh),
          stake_credential: None,
        },
      ),
    ],
    assets.zero,
  )
}

/// §5 rule 11a — the index is `-1` where nothing is released, so a live index
/// with an empty release list is a reference to an output the arm never checks.
test modify_order_rejects_a_release_index_with_nothing_released() fail {
  t_update(
    t_value(constants.min_ada, 100_000_000, False),
    t_datum(),
    t_value(constants.min_ada, 100_000_000, False),
    OrderDatum { ..t_datum(), short_amount: 400_000_000 },
    t_owner_in(t_owner_value()),
    0,
    1,
    0,
    0,
    [t_release_out(t_wallet())],
    assets.zero,
  )
}

// -------------------------------------------------------------- §9.2.10 again

/// §9.2.10 with §9.2.8 — `is_market` is itself mutable, but flipping it **on**
/// requires the reserve to cover `async_fill_cost`, because §6.2.2.13 would have
/// demanded exactly that of an order created this way.
test modify_order_rejects_flipping_is_market_on_unfunded() fail {
  t_plain(
    t_value(constants.min_ada, 100_000_000, False),
    OrderDatum { ..t_datum(), short_amount: 400_000_000, is_market: True },
  )
}

test modify_order_accepts_flipping_is_market_on_with_the_reserve() {
  let afc = order_utils.async_fill_cost(8_400_000, 1_100_000)
  t_plain(
    t_value(constants.min_ada + afc, 100_000_000, False),
    OrderDatum {
      ..t_datum(),
      short_amount: 400_000_000,
      is_market: True,
      fee_reserve: afc,
    },
  )
}

/// An order that was already a market order stays one without re-proving the
/// reserve: §6.2.2.13 checked it when the order was created, and §9.2.5 only
/// lets the reserve rise.
test modify_order_accepts_a_market_order_staying_one() {
  let market_in = OrderDatum { ..t_datum(), is_market: True }
  t_update(
    t_value(constants.min_ada, 100_000_000, False),
    market_in,
    t_value(constants.min_ada, 100_000_000, False),
    OrderDatum { ..market_in, short_amount: 400_000_000 },
    t_owner_in(t_owner_value()),
    0,
    1,
    -1,
    0,
    [],
    assets.zero,
  )
}

// --------------------------------------------------------------- §9.3, cancel

fn t_cancel(
  value: Value,
  order_owner_in_idx: Int,
  owner_release_out_idx: Int,
  market_ref_idx: Int,
) -> Bool {
  modify_order.validate_cancel(
    t_order_in(value, t_datum()),
    order_owner_in_idx,
    owner_release_out_idx,
    market_ref_idx,
    t_order_skh,
    fn(order_nft_name, order_owner_nft_name) {
      and {
        (order_nft_name == t_nft_name)?,
        (order_owner_nft_name == t_owner_name())?,
      }
    },
  )
}

/// §9.3 — the cancel arm burns both tickets and names no owner input: the ledger
/// requires the `OrderOwnerNFT` in an input for the burn to succeed at all, and
/// that is the whole authorisation. DEPLOYMENT.md §6 item 11 is why this matters
/// operationally — it is also what retires a **filled** order UTxO.
test cancel_order_returns_the_two_names_it_burns() {
  t_cancel(t_value(constants.min_ada, 100_000_000, False), -1, -1, -1)
}

/// §5 rule 11a — items 3, 4 and 7 say these three indices are absent on this
/// arm, so they are checked to be. A live index would be a reference the arm
/// never validates.
test cancel_order_rejects_an_owner_input_index() fail {
  t_cancel(t_value(constants.min_ada, 100_000_000, False), 1, -1, -1)
}

test cancel_order_rejects_a_release_output_index() fail {
  t_cancel(t_value(constants.min_ada, 100_000_000, False), -1, 0, -1)
}

test cancel_order_rejects_a_market_reference_index() fail {
  t_cancel(t_value(constants.min_ada, 100_000_000, False), -1, -1, 0)
}

/// §9.3.1 — without the singleton the burned name has no source, and the arm
/// would be free to name any `OrderNFT` it liked.
test cancel_order_rejects_an_order_without_a_singleton_nft() fail {
  let value =
    assets.from_lovelace(constants.min_ada)
      |> assets.merge(assets.from_asset(t_order_skh, t_nft_name, 1))
      |> assets.merge(assets.from_asset(t_order_skh, "second", 1))
  t_cancel(value, -1, -1, -1)
}
