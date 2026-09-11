//// Unit tests for `order/execute.ak`.
////
//// They live outside that module rather than beside it, which departs from this
//// repository's own habit — the ninety-four tests that came before are inline in
//// the module each one exercises. The reason is that the live registry pins every
//// validator hash to the bytes of its own source, so no file under `lib/` that a
//// validator compiles from may change while that registry is in use. A new module
//// costs nothing on chain: `aiken` strips tests from the blueprint, and these
//// reach only what `order/execute.ak` already exports.

use cardano/address.{Address, Script, VerificationKey}
use cardano/assets.{AssetName, Value}
use cardano/transaction.{InlineDatum, Input, NoDatum, Output, OutputReference}
use constants
use daken/input_hash
use daken/prational.{PRational}
use daken/types as daken_types
use order/execute
use order/utils as order_utils
use types.{
  Claim, Declaration, Delivered, LoanDatum, MarketDatum, Opening, OrderDatum,
  Pending, PositionDatum, ProtocolDatum, Recovered, ScriptHash,
}
use utils

//
// The fixture is one §7.2 fill, fully consumed, arranged so every term is a
// round number:
//
//   short_token = fUSDM (what the pool lends), long_token = ADA (the collateral)
//   margin  = net(order_in, fUSDM)      = 100_000_000
//   short_amount                        = 500_000_000
//   tbv     = short_amount - margin     = 400_000_000
//   loan_amount                         = 400_000_000   (the whole of it)
//   nlp     = loan_amount, at a zero origination fee
//   short_from_order_in = deposit_qty   = 100_000_000
//   long_from_order_in                  = 0   (the order held no ADA above minADA)
//
// so §7.2.8 closes exactly — `short_amount == loan_amount + short_from_order_in`
// — and §7.2.7 sits at the leverage cap, `leverage_cap(8000, 0) = 5.00x`.

const t_order_skh = #"11111111111111111111111111111111111111111111111111111111"

const t_position_skh =
  #"22222222222222222222222222222222222222222222222222222222"

const t_loan_skh = #"33333333333333333333333333333333333333333333333333333333"

const t_adapter_skh =
  #"44444444444444444444444444444444444444444444444444444444"

const t_order_nft_name =
  #"55555555555555555555555555555555555555555555555555555555"

const t_market_nft_name = "usdm_market"

const t_ada = (#"", #"")

const t_usdm = ("usdm_pid", "usdm")

const t_margin = 100_000_000

const t_short_amount = 500_000_000

const t_loan_amount = 400_000_000

/// `limit_floor(100_000_000, 400_000_000, 1/1)`.
const t_limit_floor = 500_000_000

const t_interest_index = 1_000_000_000_000

const t_tx_end = 1_700_000_001_000

fn t_wallet() -> Address {
  Address {
    payment_credential: VerificationKey("wallet_vk"),
    stake_credential: None,
  }
}

fn t_at(skh: ByteArray) -> Address {
  Address { payment_credential: Script(skh), stake_credential: None }
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

fn t_order(fee_reserve: Int) -> OrderDatum {
  OrderDatum {
    long_token: t_ada,
    short_token: t_usdm,
    short_amount: t_short_amount,
    open_limit_price: PRational(1, 1),
    take_profit_price: PRational(2, 1),
    min_liquidation_threshold: 8000,
    min_execution_amount: 100_000_000,
    max_slippage: 300,
    allowed_adapters: [],
    is_market: True,
    market_nft_name: t_market_nft_name,
    beneficiary: t_wallet(),
    fee_reserve,
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

/// §7.2.10 — one hash names the `PositionNFT`, the `LoanOwnerNFT` and, suffixed,
/// the `PositionOwnerNFT`.
fn t_seed_name() -> AssetName {
  input_hash.blake2b_224(t_seed())
}

fn t_pos_owner_name() -> AssetName {
  utils.suffixed(t_seed_name(), constants.owner_nft_suffix)
}

fn t_binding_name() -> AssetName {
  utils.suffixed(t_seed_name(), constants.binding_nft_suffix)
}

fn t_order_in(fee_reserve: Int) -> Input {
  Input {
    output_reference: OutputReference("order", 0),
    output: Output {
      address: t_at(t_order_skh),
      value: assets.from_lovelace(constants.min_ada + fee_reserve)
        |> assets.merge(assets.from_asset("usdm_pid", "usdm", t_margin))
        |> assets.merge(assets.from_asset(t_order_skh, t_order_nft_name, 1)),
      datum: InlineDatum(t_order(fee_reserve)),
      reference_script: None,
    },
  }
}

/// §7.2.14 — the fill parks the `PositionOwnerNFT` in the order UTxO, which is
/// why the leftover of `assets.reduce` must be exactly that one entry.
fn t_order_out(out_fee_reserve: Int) -> Output {
  Output {
    address: t_at(t_order_skh),
    value: assets.from_lovelace(constants.min_ada + out_fee_reserve)
      |> assets.merge(assets.from_asset(t_order_skh, t_order_nft_name, 1))
      |> assets.merge(assets.from_asset(t_position_skh, t_pos_owner_name(), 1)),
    datum: InlineDatum(
      OrderDatum { ..t_order(out_fee_reserve), short_amount: 0 },
    ),
    reference_script: None,
  }
}

fn t_loan_out(lovelace: Int, claim: Option<Claim>) -> Output {
  Output {
    address: t_at(t_loan_skh),
    value: assets.from_lovelace(lovelace)
      |> assets.merge(assets.from_asset(t_loan_skh, t_market_nft_name, 1)),
    datum: InlineDatum(
      LoanDatum {
        owner_nft: Some((t_loan_skh, t_seed_name())),
        token: t_usdm,
        loan_amount: t_loan_amount,
        initial_interest_index: t_interest_index,
        claim,
      },
    ),
    reference_script: None,
  }
}

/// §7.2.19 — the five fields copied from the order, and the value clause: its own
/// `PositionNFT`, the `LoanOwnerNFT`, and nothing else.
fn t_position_out() -> Output {
  Output {
    address: t_at(t_position_skh),
    value: assets.from_lovelace(constants.min_ada)
      |> assets.merge(assets.from_asset(t_position_skh, t_seed_name(), 1))
      |> assets.merge(assets.from_asset(t_loan_skh, t_seed_name(), 1)),
    datum: InlineDatum(
      PositionDatum {
        long_token: t_ada,
        take_profit_price: PRational(2, 1),
        min_execution_amount: 100_000_000,
        max_slippage: 300,
        beneficiary: t_wallet(),
      },
    ),
    reference_script: None,
  }
}

/// §7.2.12 — the three the fill always mints. Exhaustiveness over each policy is
/// the loan and position scripts' own withdrawals.
fn t_mint(binding: Bool) -> Value {
  let base =
    assets.from_asset(t_loan_skh, t_seed_name(), 1)
      |> assets.merge(assets.from_asset(t_position_skh, t_seed_name(), 1))
      |> assets.merge(
          assets.from_asset(t_position_skh, t_pos_owner_name(), 1),
        )
  if binding {
    base |> assets.merge(assets.from_asset(t_loan_skh, t_binding_name(), 1))
  } else {
    base
  }
}

fn t_delivered(asset: daken_types.TupleAsset, amount: Int) -> Declaration {
  Declaration {
    loan_owner_nft_name: t_seed_name(),
    route: Delivered { asset, amount, binding_nft: None },
  }
}

fn t_pending(expiry: Int, slippage_src_idx: Int) -> Declaration {
  Declaration {
    loan_owner_nft_name: t_seed_name(),
    route: Pending {
      asset: t_ada,
      floor: t_limit_floor,
      market_floor: t_limit_floor,
      binding_nft: (t_loan_skh, t_binding_name()),
      expiry,
      slippage_src_idx,
      venue_ref_idx: 0,
      venue_out_idx: 0,
      stake_credential: None,
    },
  }
}

fn t_run(
  order_in: Input,
  order_out: Output,
  position_out: Output,
  loan_out: Output,
  execution_tip_idx: Int,
  outputs: List<Output>,
  mint: Value,
  declarations: List<Declaration>,
  adapter_skh: ScriptHash,
  market_nft_name: AssetName,
  pool_out_interest_index: Int,
) -> Bool {
  execute.validate(
    order_in,
    0,
    order_out,
    position_out,
    loan_out,
    t_seed(),
    execution_tip_idx,
    outputs,
    mint,
    t_protocol(),
    t_order_skh,
    adapter_skh,
    declarations,
    t_market(),
    market_nft_name,
    pool_out_interest_index,
    t_tx_end,
  )
}

// -------------------------------------------------- §7.3, the synchronous fill

/// The executor delivers the collateral inside the same transaction, so there is
/// no claim, no venue and no tip. §7.3.2's floor is what stops it delivering
/// less than the order's own limit price would have bought.
fn t_sync(loan_lovelace: Int, amount: Int) -> Bool {
  t_run(
    t_order_in(0),
    t_order_out(0),
    t_position_out(),
    t_loan_out(loan_lovelace, None),
    -1,
    [],
    t_mint(False),
    [t_delivered(t_ada, amount)],
    t_adapter_skh,
    t_market_nft_name,
    t_interest_index,
  )
}

test execute_accepts_a_synchronous_fill() {
  t_sync(constants.min_ada + t_limit_floor, t_limit_floor)
}

/// §7.3.2 item 5 — the surplus above the floor is unconstrained. An executor
/// who beats the limit price keeps nothing back: the whole delivery lands on the
/// loan as collateral.
test execute_admits_collateral_above_the_limit_floor() {
  t_sync(constants.min_ada + t_limit_floor + 1, t_limit_floor + 1)
}

/// §7.3.2 — the declared `amount` must cover `long_from_order_in +
/// limit_floor(..)`. One unit short and the loan opens against less collateral
/// than the order's `open_limit_price` promised.
test execute_rejects_collateral_one_below_the_limit_floor() fail {
  t_sync(constants.min_ada + t_limit_floor, t_limit_floor - 1)
}

/// The declaration is a claim about the loan output, so the loan output has to
/// actually hold it — measured with `net(..)`, which strips the loan UTxO's own
/// minADA on the lovelace leg.
test execute_rejects_a_declared_amount_the_loan_does_not_hold() fail {
  t_sync(constants.min_ada + t_limit_floor - 1, t_limit_floor)
}

/// §7.3.1 — the declared asset is the order's `long_token`. DEPLOYMENT.md §6
/// item 19 is the operational form of this: a route hardcoded to ADA is right on
/// a market that lends ADA and silently wrong on every other one.
test execute_rejects_a_declaration_of_another_asset() fail {
  t_run(
    t_order_in(0),
    t_order_out(0),
    t_position_out(),
    t_loan_out(constants.min_ada + t_limit_floor, None),
    -1,
    [],
    t_mint(False),
    [t_delivered(t_usdm, t_limit_floor)],
    t_adapter_skh,
    t_market_nft_name,
    t_interest_index,
  )
}

/// §7.3.3 — a synchronous fill leaves no claim. A loan opened with one would
/// wait for a venue that was never asked to do anything.
test execute_rejects_a_claim_on_the_synchronous_arm() fail {
  t_run(
    t_order_in(0),
    t_order_out(0),
    t_position_out(),
    t_loan_out(
      constants.min_ada + t_limit_floor,
      Some(
        Claim {
          adapter_skh: t_adapter_skh,
          binding_nft: (t_loan_skh, t_binding_name()),
          direction: Opening,
          asset: t_ada,
          sold: t_margin + t_loan_amount,
          floor: t_limit_floor,
          expiry: t_tx_end + 600_000,
        },
      ),
    ),
    -1,
    [],
    t_mint(False),
    [t_delivered(t_ada, t_limit_floor)],
    t_adapter_skh,
    t_market_nft_name,
    t_interest_index,
  )
}

/// §7.3.4 — no tip is paid on this arm, so §7.2.13 debits no reserve and the
/// index must say so.
test execute_rejects_a_tip_index_on_the_synchronous_arm() fail {
  t_run(
    t_order_in(0),
    t_order_out(0),
    t_position_out(),
    t_loan_out(constants.min_ada + t_limit_floor, None),
    0,
    [
      Output {
        address: t_wallet(),
        value: assets.from_lovelace(1_100_000),
        datum: NoDatum,
        reference_script: None,
      },
    ],
    t_mint(False),
    [t_delivered(t_ada, t_limit_floor)],
    t_adapter_skh,
    t_market_nft_name,
    t_interest_index,
  )
}

// ------------------------------------------------- §7.4, the asynchronous fill

/// The venue buys the collateral later, so the loan opens holding a `Claim` and
/// nothing else: §7.4.6 pins `net(loan_out, long_token)` to
/// `long_from_order_in`, which is zero here. `fee_reserve` funds
/// `async_fill_cost` and the tip comes out of it — §7.4.10.
fn t_async(
  fee_reserve: Int,
  claim: Option<Claim>,
  declaration: Declaration,
  tip_lovelace: Int,
) -> Bool {
  let afc = order_utils.async_fill_cost(8_400_000, 1_100_000)
  t_run(
    t_order_in(fee_reserve),
    t_order_out(fee_reserve - afc),
    t_position_out(),
    t_loan_out(constants.min_ada, claim),
    0,
    [
      Output {
        address: t_wallet(),
        value: assets.from_lovelace(tip_lovelace),
        datum: NoDatum,
        reference_script: None,
      },
    ],
    t_mint(True),
    [declaration],
    t_adapter_skh,
    t_market_nft_name,
    t_interest_index,
  )
}

fn t_claim(sold: Int, expiry: Int) -> Option<Claim> {
  Some(
    Claim {
      adapter_skh: t_adapter_skh,
      binding_nft: (t_loan_skh, t_binding_name()),
      direction: Opening,
      asset: t_ada,
      sold,
      floor: t_limit_floor,
      expiry,
    },
  )
}

test execute_accepts_an_asynchronous_fill() {
  let afc = order_utils.async_fill_cost(8_400_000, 1_100_000)
  t_async(
    afc,
    t_claim(t_margin + t_loan_amount, t_tx_end + 600_000),
    t_pending(t_tx_end + 600_000, 0),
    1_100_000,
  )
}

/// §7.4.10 — the reserve has to cover `async_fill_cost`. One lovelace short and
/// the fill would place a venue order the order never funded, leaving the
/// executor to pay the batcher out of pocket or the claim to be untakeable.
test execute_rejects_an_asynchronous_fill_below_the_fill_cost() fail {
  let afc = order_utils.async_fill_cost(8_400_000, 1_100_000)
  t_async(
    afc - 1,
    t_claim(t_margin + t_loan_amount, t_tx_end + 600_000),
    t_pending(t_tx_end + 600_000, 0),
    1_100_000,
  )
}

/// The tip output's lovelace is an **equality**, not a floor. That is what makes
/// `execution_tip` a ledger minADA in its own right — see `lib/constants.ak`.
test execute_rejects_a_tip_that_is_not_exactly_the_execution_tip() fail {
  let afc = order_utils.async_fill_cost(8_400_000, 1_100_000)
  t_async(
    afc,
    t_claim(t_margin + t_loan_amount, t_tx_end + 600_000),
    t_pending(t_tx_end + 600_000, 0),
    1_100_001,
  )
}

/// §7.4.5 — `sold` is `short_from_order_in + nlp`, the whole of what the venue
/// is being handed to spend. Understating it would let the claim settle for less
/// than the order paid in.
test execute_rejects_a_claim_that_understates_what_was_sold() fail {
  let afc = order_utils.async_fill_cost(8_400_000, 1_100_000)
  t_async(
    afc,
    t_claim(t_margin + t_loan_amount - 1, t_tx_end + 600_000),
    t_pending(t_tx_end + 600_000, 0),
    1_100_000,
  )
}

/// §7.4.4 — `expiry - tx_end` lives in
/// `[min_claim_duration, max_claim_duration]`, both 600 000 ms in this market,
/// so the window is exact. Too short and the venue cannot fill it; too long and
/// the borrower's collateral is locked past what they agreed to.
test execute_rejects_an_expiry_inside_the_minimum_claim_duration() fail {
  let afc = order_utils.async_fill_cost(8_400_000, 1_100_000)
  t_async(
    afc,
    t_claim(t_margin + t_loan_amount, t_tx_end + 599_999),
    t_pending(t_tx_end + 599_999, 0),
    1_100_000,
  )
}

test execute_rejects_an_expiry_past_the_maximum_claim_duration() fail {
  let afc = order_utils.async_fill_cost(8_400_000, 1_100_000)
  t_async(
    afc,
    t_claim(t_margin + t_loan_amount, t_tx_end + 600_001),
    t_pending(t_tx_end + 600_001, 0),
    1_100_000,
  )
}

/// §7.4.5 is a field-by-field equality with no substitution, so a claim whose
/// expiry disagrees with the route's is rejected even where both are in range.
test execute_rejects_a_claim_whose_expiry_disagrees_with_the_route() fail {
  let afc = order_utils.async_fill_cost(8_400_000, 1_100_000)
  t_async(
    afc,
    t_claim(t_margin + t_loan_amount, t_tx_end + 600_000),
    t_pending(t_tx_end + 600_000 - 1, 0),
    1_100_000,
  )
}

/// §7.4.1 — the tolerance source is pinned to **this** action's order input.
/// Left free, an adapter could read `max_slippage` off some other order in the
/// same transaction and admit a worse fill than this order allowed.
test execute_rejects_a_slippage_source_that_is_not_this_order() fail {
  let afc = order_utils.async_fill_cost(8_400_000, 1_100_000)
  t_async(
    afc,
    t_claim(t_margin + t_loan_amount, t_tx_end + 600_000),
    t_pending(t_tx_end + 600_000, 1),
    1_100_000,
  )
}

/// §7.4.6 — the loan holds `long_from_order_in` of the collateral and no more:
/// the rest is out with the venue. Collateral sitting on the loan **and** a
/// claim for it outstanding would double-count it against the health gate.
test execute_rejects_collateral_on_a_loan_that_carries_a_claim() fail {
  let afc = order_utils.async_fill_cost(8_400_000, 1_100_000)
  t_run(
    t_order_in(afc),
    t_order_out(0),
    t_position_out(),
    t_loan_out(constants.min_ada + 1, t_claim(t_margin + t_loan_amount, t_tx_end + 600_000)),
    0,
    [
      Output {
        address: t_wallet(),
        value: assets.from_lovelace(1_100_000),
        datum: NoDatum,
        reference_script: None,
      },
    ],
    t_mint(True),
    [t_pending(t_tx_end + 600_000, 0)],
    t_adapter_skh,
    t_market_nft_name,
    t_interest_index,
  )
}

/// §7.2.12's asynchronous addition — the `BindingNFT` is minted, and it is what
/// ties the venue order to this loan. Without the mint the claim names a token
/// nobody issued and §8 could never settle it.
test execute_rejects_an_asynchronous_fill_that_mints_no_binding_nft() fail {
  let afc = order_utils.async_fill_cost(8_400_000, 1_100_000)
  t_run(
    t_order_in(afc),
    t_order_out(0),
    t_position_out(),
    t_loan_out(constants.min_ada, t_claim(t_margin + t_loan_amount, t_tx_end + 600_000)),
    0,
    [
      Output {
        address: t_wallet(),
        value: assets.from_lovelace(1_100_000),
        datum: NoDatum,
        reference_script: None,
      },
    ],
    t_mint(False),
    [t_pending(t_tx_end + 600_000, 0)],
    t_adapter_skh,
    t_market_nft_name,
    t_interest_index,
  )
}

// ------------------------------------------------------- §7.2, common to both

/// §7.2.1 — an order may name the adapters it will be filled through, and an
/// empty list means any whitelisted one. A trader who lists none is trusting the
/// registry; one who lists some is not.
test execute_rejects_an_adapter_the_order_did_not_allow() fail {
  let order_in =
    Input {
      output_reference: OutputReference("order", 0),
      output: Output {
        ..t_order_in(0).output,
        datum: InlineDatum(
          OrderDatum { ..t_order(0), allowed_adapters: [t_adapter_skh] },
        ),
      },
    }
  t_run(
    order_in,
    Output {
      ..t_order_out(0),
      datum: InlineDatum(
        OrderDatum {
          ..t_order(0),
          short_amount: 0,
          allowed_adapters: [t_adapter_skh],
        },
      ),
    },
    t_position_out(),
    t_loan_out(constants.min_ada + t_limit_floor, None),
    -1,
    [],
    t_mint(False),
    [t_delivered(t_ada, t_limit_floor)],
    #"99999999999999999999999999999999999999999999999999999999",
    t_market_nft_name,
    t_interest_index,
  )
}

/// §7.2.5's order half — the order names its market, and the pool half of the
/// same rule is checked once per action. A fill across the two would lend one
/// market's supply against another market's parameters.
test execute_rejects_a_market_the_order_does_not_name() fail {
  t_run(
    t_order_in(0),
    t_order_out(0),
    t_position_out(),
    t_loan_out(constants.min_ada + t_limit_floor, None),
    -1,
    [],
    t_mint(False),
    [t_delivered(t_ada, t_limit_floor)],
    t_adapter_skh,
    "another_market",
    t_interest_index,
  )
}

/// §7.2.20 — `initial_interest_index` is the pool's index **as this transaction
/// leaves it**. Writing a stale one would start the loan's interest accrual
/// behind the pool and undercharge it for the gap.
test execute_rejects_a_loan_index_that_is_not_the_pools() fail {
  t_run(
    t_order_in(0),
    t_order_out(0),
    t_position_out(),
    t_loan_out(constants.min_ada + t_limit_floor, None),
    -1,
    [],
    t_mint(False),
    [t_delivered(t_ada, t_limit_floor)],
    t_adapter_skh,
    t_market_nft_name,
    t_interest_index + 1,
  )
}

/// §7.2.12 — `LoanNFT.asset_name == MarketNFT.asset_name`. DEPLOYMENT.md §6
/// item 17 is the consequence: every open loan on one market holds a token of
/// the same policy **and name**, so the `LoanOwnerNFT` in the datum is what is
/// unique.
test execute_rejects_a_loan_nft_named_for_the_loan() fail {
  let loan_out =
    Output {
      ..t_loan_out(constants.min_ada + t_limit_floor, None),
      value: assets.from_lovelace(constants.min_ada + t_limit_floor)
        |> assets.merge(assets.from_asset(t_loan_skh, t_seed_name(), 1)),
    }
  t_run(
    t_order_in(0),
    t_order_out(0),
    t_position_out(),
    loan_out,
    -1,
    [],
    t_mint(False),
    [t_delivered(t_ada, t_limit_floor)],
    t_adapter_skh,
    t_market_nft_name,
    t_interest_index,
  )
}

/// §7.2.14 — the leftover after the value walk is exactly the
/// `PositionOwnerNFT`, an equality over the multiset of entries. It is the rule
/// that puts the trader's ticket in the order UTxO, and DEPLOYMENT.md §6 item 11
/// records what that means afterwards: a filled order goes on holding it until
/// §9.3 retires it.
test execute_rejects_an_order_output_missing_the_parked_owner_nft() fail {
  let order_out =
    Output {
      ..t_order_out(0),
      value: assets.from_lovelace(constants.min_ada)
        |> assets.merge(assets.from_asset(t_order_skh, t_order_nft_name, 1)),
    }
  t_run(
    t_order_in(0),
    order_out,
    t_position_out(),
    t_loan_out(constants.min_ada + t_limit_floor, None),
    -1,
    [],
    t_mint(False),
    [t_delivered(t_ada, t_limit_floor)],
    t_adapter_skh,
    t_market_nft_name,
    t_interest_index,
  )
}

/// §7.2.13 — every other field of the order carries over byte-identical, and
/// `short_amount` falls by exactly what this fill consumed. A fill that left
/// `short_amount` higher would let the same margin back a second loan.
test execute_rejects_an_order_output_that_did_not_debit_short_amount() fail {
  t_run(
    t_order_in(0),
    Output {
      ..t_order_out(0),
      datum: InlineDatum(OrderDatum { ..t_order(0), short_amount: 1 }),
    },
    t_position_out(),
    t_loan_out(constants.min_ada + t_limit_floor, None),
    -1,
    [],
    t_mint(False),
    [t_delivered(t_ada, t_limit_floor)],
    t_adapter_skh,
    t_market_nft_name,
    t_interest_index,
  )
}

/// §7.2.19's datum clause — all five fields copied from the order. The position
/// is what every closing arm reads the trader's terms off, so a fill that wrote
/// its own `beneficiary` there would redirect the proceeds.
test execute_rejects_a_position_datum_that_is_not_a_copy_of_the_order() fail {
  let position_out =
    Output {
      ..t_position_out(),
      datum: InlineDatum(
        PositionDatum {
          long_token: t_ada,
          take_profit_price: PRational(2, 1),
          min_execution_amount: 100_000_000,
          max_slippage: 300,
          beneficiary: Address {
            payment_credential: VerificationKey("attacker_vk"),
            stake_credential: None,
          },
        },
      ),
    }
  t_run(
    t_order_in(0),
    t_order_out(0),
    position_out,
    t_loan_out(constants.min_ada + t_limit_floor, None),
    -1,
    [],
    t_mint(False),
    [t_delivered(t_ada, t_limit_floor)],
    t_adapter_skh,
    t_market_nft_name,
    t_interest_index,
  )
}

/// §7.2.21 — the loan and position outputs inherit the order's **stake**
/// credential, not just its script. §7.5 later proves a venue's `receiver`
/// against `claim_source`, and the whole chain rests on the stake credential
/// travelling with the loan.
test execute_rejects_a_loan_output_at_another_stake_credential() fail {
  let loan_out =
    Output {
      ..t_loan_out(constants.min_ada + t_limit_floor, None),
      address: Address {
        payment_credential: Script(t_loan_skh),
        stake_credential: Some(address.Inline(Script("stake_skh"))),
      },
    }
  t_run(
    t_order_in(0),
    t_order_out(0),
    t_position_out(),
    loan_out,
    -1,
    [],
    t_mint(False),
    [t_delivered(t_ada, t_limit_floor)],
    t_adapter_skh,
    t_market_nft_name,
    t_interest_index,
  )
}

/// §7.2.6 — `loan_amount <= tbv`, and `tbv` is `short_amount - margin`. The cap
/// is what keeps the trader's own margin in the position: a loan for the whole
/// `short_amount` would be a position with no skin in it.
test execute_rejects_a_loan_amount_above_the_borrowable_value() fail {
  let loan_out =
    Output {
      ..t_loan_out(constants.min_ada + t_limit_floor, None),
      datum: InlineDatum(
        LoanDatum {
          owner_nft: Some((t_loan_skh, t_seed_name())),
          token: t_usdm,
          loan_amount: t_loan_amount + 1,
          initial_interest_index: t_interest_index,
          claim: None,
        },
      ),
    }
  t_run(
    t_order_in(0),
    t_order_out(0),
    t_position_out(),
    loan_out,
    -1,
    [],
    t_mint(False),
    [t_delivered(t_ada, t_limit_floor)],
    t_adapter_skh,
    t_market_nft_name,
    t_interest_index,
  )
}

/// §7.2.20 — the loan is denominated in the order's `short_token`, which is the
/// market's supply token. A loan that named the collateral instead would be
/// repaid in the wrong asset.
test execute_rejects_a_loan_denominated_in_the_collateral() fail {
  let loan_out =
    Output {
      ..t_loan_out(constants.min_ada + t_limit_floor, None),
      datum: InlineDatum(
        LoanDatum {
          owner_nft: Some((t_loan_skh, t_seed_name())),
          token: t_ada,
          loan_amount: t_loan_amount,
          initial_interest_index: t_interest_index,
          claim: None,
        },
      ),
    }
  t_run(
    t_order_in(0),
    t_order_out(0),
    t_position_out(),
    loan_out,
    -1,
    [],
    t_mint(False),
    [t_delivered(t_ada, t_limit_floor)],
    t_adapter_skh,
    t_market_nft_name,
    t_interest_index,
  )
}

/// §7.2.10 — the `PositionNFT` and the `LoanOwnerNFT` are both the seed's hash.
/// An output reference is spent once, which is what makes the pair unique and
/// unforgeable.
test execute_rejects_a_position_nft_the_seed_did_not_name() fail {
  let other = #"77777777777777777777777777777777777777777777777777777777"
  let position_out =
    Output {
      ..t_position_out(),
      value: assets.from_lovelace(constants.min_ada)
        |> assets.merge(assets.from_asset(t_position_skh, other, 1))
        |> assets.merge(assets.from_asset(t_loan_skh, t_seed_name(), 1)),
    }
  t_run(
    t_order_in(0),
    t_order_out(0),
    position_out,
    t_loan_out(constants.min_ada + t_limit_floor, None),
    -1,
    [],
    t_mint(False),
    [t_delivered(t_ada, t_limit_floor)],
    t_adapter_skh,
    t_market_nft_name,
    t_interest_index,
  )
}

/// A declaration is matched to the loan by the `LoanOwnerNFT` name, so a
/// transaction whose adapter declared some other loan's collateral proves
/// nothing about this one.
test execute_rejects_a_declaration_list_that_names_another_loan() fail {
  let other =
    Declaration {
      loan_owner_nft_name: #"88888888888888888888888888888888888888888888888888888888",
      route: Delivered { asset: t_ada, amount: t_limit_floor, binding_nft: None },
    }
  t_run(
    t_order_in(0),
    t_order_out(0),
    t_position_out(),
    t_loan_out(constants.min_ada + t_limit_floor, None),
    -1,
    [],
    t_mint(False),
    [other],
    t_adapter_skh,
    t_market_nft_name,
    t_interest_index,
  )
}

/// §5 rule 12 — `Recovered` is §12's route, and reaching it from a fill means a
/// venue order that was cancelled is being treated as one that filled.
test execute_rejects_a_recovered_route() fail {
  let recovered =
    Declaration {
      loan_owner_nft_name: t_seed_name(),
      route: Recovered {
        asset: t_ada,
        amount: t_limit_floor,
        binding_nft: (t_loan_skh, t_binding_name()),
      },
    }
  t_run(
    t_order_in(0),
    t_order_out(0),
    t_position_out(),
    t_loan_out(constants.min_ada + t_limit_floor, None),
    -1,
    [],
    t_mint(False),
    [recovered],
    t_adapter_skh,
    t_market_nft_name,
    t_interest_index,
  )
}

// ------------------------------------------- execute.no_unaccounted_script_inputs

/// §7.2.4 with §5 rule 16 — every input at `loan_skh` or `position_skh` is
/// accounted for by that script's own withdrawal. A fill that carried a loan
/// input no script walked would spend it under a redeemer that checked nothing
/// about it.
test unaccounted_script_inputs_need_their_own_withdrawal() {
  let at = fn(skh: ByteArray) {
    Input {
      output_reference: OutputReference("in", 0),
      output: Output {
        address: t_at(skh),
        value: assets.from_lovelace(constants.min_ada),
        datum: NoDatum,
        reference_script: None,
      },
    }
  }
  let protocol = t_protocol()
  and {
    // Nothing at either script: both flags are irrelevant.
    execute.no_unaccounted_script_inputs([at(t_order_skh)], protocol, False, False)?,
    execute.no_unaccounted_script_inputs([at(t_loan_skh)], protocol, True, False)?,
    (!execute.no_unaccounted_script_inputs([at(t_loan_skh)], protocol, False, False))?,
    execute.no_unaccounted_script_inputs([at(t_position_skh)], protocol, False, True)?,
    (!execute.no_unaccounted_script_inputs(
      [at(t_position_skh)],
      protocol,
      True,
      False,
    ))?,
    // Both present, both walked.
    execute.no_unaccounted_script_inputs(
      [at(t_loan_skh), at(t_position_skh)],
      protocol,
      True,
      True,
    )?,
    (!execute.no_unaccounted_script_inputs(
      [at(t_loan_skh), at(t_position_skh)],
      protocol,
      True,
      False,
    ))?,
  }
}
