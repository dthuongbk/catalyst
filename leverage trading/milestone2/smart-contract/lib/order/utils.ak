//// Order-side arithmetic — biz spec §2 items 3, 4, 5, 6, 18, 20 and §4.1's
//// `limit_floor` — plus the pieces of the transaction every order arm resolves the
//// same way: the registry, the market reference input, the validity range, and the
//// shape of an order UTxO.
////
//// `daken` and `lib/utils.ak` are used before anything is written here.

use aiken/interval.{Finite, Interval, IntervalBound}
use cardano/address.{Address, Credential, Script, StakeCredential}
use cardano/assets.{AssetName, Value}
use cardano/transaction.{InlineDatum, Input, Output, ValidityRange}
use constants
use daken/math as daken_math
use daken/pairs as daken_pairs
use daken/prational.{PRational}
use daken/tokens
use daken/types.{TupleAsset} as daken_types
use daken/util as daken_util
use types.{MarketDatum, OrderDatum, ProtocolDatum, ScriptHash}
use utils

/// The order UTxO's `net`: §2.2's lovelace case additionally excludes
/// `fee_reserve`, read from the datum of the same UTxO whose value is being read.
pub fn order_net(v: Value, a: TupleAsset, fee_reserve: Int) -> Int {
  if tokens.is_ada(a) {
    utils.net(v, a) - fee_reserve
  } else {
    utils.net(v, a)
  }
}

/// §2.2's lovelace case applied to a quantity already in hand, so a fold over
/// `order_in_value` pays for one `quantity_of` and not two.
pub fn order_net_qty(a: TupleAsset, qty: Int, fee_reserve: Int) -> Int {
  if tokens.is_ada(a) {
    qty - constants.min_ada - fee_reserve
  } else {
    qty
  }
}

/// §2.4. The `> 0` belongs to every arm that evaluates this and is what keeps
/// `deposit_qty` from dividing by zero.
pub fn total_borrowed_value(short_amount: Int, margin: Int) -> Int {
  let tbv = short_amount - margin
  expect tbv > 0
  tbv
}

/// §2.5.
pub fn deposit_qty(net_in_qty: Int, loan_amount: Int, tbv: Int) -> Int {
  daken_math.ceiling_div(net_in_qty * loan_amount, tbv)
}

/// §2.6. The fee never leaves the pool, so the whole difference stays behind as
/// `undistributed_fee`.
pub fn net_loan_proceeds(
  loan_amount: Int,
  origination_fee_rate: Int,
  origination_fee_min_amount: Int,
) -> Int {
  let fee =
    daken_math.ceiling_div(
      origination_fee_rate * loan_amount,
      constants.basis_point,
    )
  let nlp =
    loan_amount - if fee > origination_fee_min_amount {
      fee
    } else {
      origination_fee_min_amount
    }
  expect nlp > 0
  nlp
}

/// §2.18. The only ceiling on leverage — evaluated at the order's own collateral
/// threshold, never at the largest the market enables.
pub fn leverage_cap(t: Int, origination_fee_rate: Int) -> Int {
  let bp = constants.basis_point
  constants.basis_point + bp * bp * t / (
    bp * bp - t * bp + t * origination_fee_rate
  )
}

/// §6.2.1.6, §7.2.7 and §9.2.6's shared ceiling — asserted only where there is a
/// margin to assert it against.
///
/// `leverage_cap` is the collateral threshold restated: at a zero origination fee
/// it is exactly `1 / (1 - T)`, which the cases below pin at 5.00x for T = 8_000
/// and 10.0x for T = 9_000. It therefore carries no bound that §3's health gate
/// does not, and the health gate carries it better — against the oracle's price
/// of the collateral actually received, rather than the price implied by what was
/// paid for it. What this form adds is that it can be checked at all: none of
/// `create_order`, `modify_order` or `execute` reads a price.
///
/// A **long-funded** order has no supply-token margin, so there is nothing here to
/// measure. The formula reads `margin` and `short_amount` and never sees the long
/// deposit, so on such an order it is not merely unavailable but wrong: a trader
/// who brings collateral would be bounded as though they had brought none. Those
/// orders are bounded where the price lives — §4.1's `health_floor`, which no fill
/// can open a loan without satisfying.
pub fn within_leverage_cap(
  margin: Int,
  short_amount: Int,
  t: Int,
  origination_fee_rate: Int,
) -> Bool {
  or {
    margin == 0,
    margin * leverage_cap(t, origination_fee_rate) >= short_amount * constants.basis_point,
  }
}

/// §2.20. The reserves are the adapter's to read; this is the shape the value it
/// declares must have, and the core takes that value on trust per §4.1.
pub fn market_floor(achievable: Int, max_slippage: Int) -> Int {
  achievable * ( constants.basis_point - max_slippage ) / constants.basis_point
}

/// §4.1's `limit_floor` — the ceiling term of §7.3.2 alone, not that item's whole
/// right-hand side.
pub fn limit_floor(
  short_from_order_in: Int,
  net_loan_proceeds: Int,
  open_limit_price: PRational,
) -> Int {
  daken_math.ceiling_div(
    ( short_from_order_in + net_loan_proceeds ) * open_limit_price.denominator,
    open_limit_price.numerator,
  )
}

/// §6.2.2 item 13. The two `min_ada` are the loan and position UTxOs a fill
/// creates.
pub fn async_fill_cost(venue_fee_budget: Int, execution_tip: Int) -> Int {
  venue_fee_budget + execution_tip + 2 * constants.min_ada
}

/// §5 rule 1. An open bound would make every `expiry - tx_end` bound vacuous.
pub fn tx_bounds(validity_range: ValidityRange) -> (Int, Int) {
  let Interval { lower_bound, upper_bound } = validity_range
  expect IntervalBound { bound_type: Finite(tx_start), .. } = lower_bound
  expect IntervalBound { bound_type: Finite(tx_end), .. } = upper_bound
  expect tx_start > 0
  expect tx_end - tx_start <= constants.max_validity_window
  (tx_start, tx_end)
}

/// §5 rules 2 and 3 — the registry, authenticated by `protocol_nft` alone: it is
/// minted once at a name distinct from the `AdminNFT`, so no address is needed.
pub fn protocol_config(
  reference_inputs: List<Input>,
  idx: Int,
  protocol_nft: TupleAsset,
) -> ProtocolDatum {
  expect idx != -1
  expect protocol: ProtocolDatum =
    daken_util.get_inline_datum_by_idx_and_nft(
      reference_inputs,
      idx,
      protocol_nft,
    )
  protocol
}

/// §5 rule 3 — `market_param` by its `MarketNFT` under `config_pool_skh` **and** by
/// `Script(config_pool_skh)`: the `MarketNFT` and the `PoolNFT` are the same asset
/// minted in quantity 2, so the NFT alone does not tell the two UTxOs apart.
pub fn market_at(
  reference_inputs: List<Input>,
  idx: Int,
  config_pool_skh: ScriptHash,
) -> (MarketDatum, AssetName) {
  expect idx != -1
  let Input { output: Output { address, value, datum, .. }, .. } =
    utils.input_at(reference_inputs, idx)
  expect utils.at_script(address, config_pool_skh)
  expect [(market_nft_name, 1)] = utils.tokens_of(value, config_pool_skh)
  expect InlineDatum(market_data) = datum
  expect market: MarketDatum = market_data
  (market, market_nft_name)
}

/// The shape every order UTxO has, on input and on output alike: at
/// `Script(order_skh)`, an inline `OrderDatum` parsing strictly, no reference
/// script, and **exactly one** token of `order_skh` in quantity 1 — §6.2.1 items 1
/// and 8, §9.2.1, §9.3.1. §6.2.1.2 follows from the singleton: the `OrderOwnerNFT`
/// shares this policy, so it cannot also be in here.
pub fn order_shape(
  Output { address, value, datum, reference_script }: Output,
  order_skh: ScriptHash,
) -> (OrderDatum, AssetName, Option<StakeCredential>) {
  expect utils.at_script(address, order_skh)
  expect reference_script == None
  expect InlineDatum(order_data) = datum
  expect order: OrderDatum = order_data
  expect [(order_nft_name, 1)] = utils.tokens_of(value, order_skh)
  expect !utils.is_suffixed_nft(order_nft_name, constants.owner_nft_suffix)
  (order, order_nft_name, address.stake_credential)
}

/// §6.2.2 items 2 to 6, re-checked verbatim by §9.2.7 against the market
/// reference input.
pub fn valid_order_params(order: OrderDatum, market: MarketDatum) -> Bool {
  and {
    (order.open_limit_price.numerator > 0)?,
    (order.open_limit_price.denominator > 0)?,
    (order.take_profit_price.numerator >= 0)?,
    (order.take_profit_price.denominator > 0)?,
    (order.min_liquidation_threshold > 0)?,
    (order.min_liquidation_threshold <= constants.basis_point)?,
    (order.min_execution_amount >= market.min_tx_amount)?,
    (market.fillability_margin <= order.max_slippage)?,
    (order.max_slippage <= market.max_slippage_cap)?,
  }
}

/// `market.collaterals[a]` with §6.2.2.8 / §7.2.9's `enabled` gate applied. An
/// absent key fails, per §5 rule 13.
pub fn enabled_threshold(market: MarketDatum, a: TupleAsset) -> Int {
  let (t, enabled) = daken_pairs.get_first(market.collaterals, a)
  expect enabled
  t
}

/// §2.12's `T(a)` on the order side, where `long_token != short_token` holds by
/// §6.2.2.7 so the `short_token` case cannot arise. **No** `enabled` gate: §1.3
/// makes clearing it bar a new fill and nothing else, so §9.2.6 must still value a
/// disabled collateral or a market turning one off would freeze every resting
/// order's update path.
pub fn threshold(market: MarketDatum, a: TupleAsset) -> Int {
  let (t, _enabled) = daken_pairs.get_first(market.collaterals, a)
  t
}

/// True where `addr` is at none of the six protocol scripts — the test §9.2.4 and
/// §10.1.7 apply to an output that pays a third party.
pub fn outside_protocol(
  Address { payment_credential, .. }: Address,
  protocol: ProtocolDatum,
) -> Bool {
  !list_has_credential(
    [
      protocol.order_skh,
      protocol.position_skh,
      protocol.loan_skh,
      protocol.pool_skh,
      protocol.config_pool_skh,
    ],
    payment_credential,
  )
}

fn list_has_credential(skhs: List<ScriptHash>, cred: Credential) -> Bool {
  when skhs is {
    [] -> False
    [skh, ..rest] ->
      if cred == Script(skh) {
        True
      } else {
        list_has_credential(rest, cred)
      }
  }
}

// ------------------------------------------------------------------ tests

type ArithCase {
  name: ByteArray,
  got: Int,
  want: Int,
}

test arithmetic() {
  let bp = constants.basis_point
  let tests =
    [
      // §2.18 — T = 8,000 at a zero origination fee is exactly 5.00x.
      ArithCase {
        name: "leverage_cap_8000",
        got: leverage_cap(8000, 0),
        want: 50_000,
      },
      ArithCase {
        name: "leverage_cap_8500",
        got: leverage_cap(8500, 0),
        want: 66_666,
      },
      ArithCase {
        name: "leverage_cap_9000",
        got: leverage_cap(9000, 0),
        want: 100_000,
      },
      // A live origination fee tightens the bound.
      ArithCase {
        name: "leverage_cap_fee",
        got: leverage_cap(8000, 100),
        want: 48_461,
      },
      // §2.5 — ceiling.
      ArithCase {
        name: "deposit_qty_exact",
        got: deposit_qty(100, 50, 100),
        want: 50,
      },
      ArithCase {
        name: "deposit_qty_ceil",
        got: deposit_qty(10, 1, 3),
        want: 4,
      },
      ArithCase {
        name: "deposit_qty_zero",
        got: deposit_qty(0, 999, 3),
        want: 0,
      },
      // The deployed partial fill: margin 10e6 against `short_amount` 110e6 gives
      // `total_borrowed_value` 100e6, and a 10e6 draw takes a tenth of every leg.
      ArithCase {
        name: "deposit_qty_partial_short",
        got: deposit_qty(10_000_000, 10_000_000, 100_000_000),
        want: 1_000_000,
      },
      ArithCase {
        name: "deposit_qty_partial_other",
        got: deposit_qty(10_000_000, 100_000_000, 100_000_000),
        want: 10_000_000,
      },
      // §2.4.
      ArithCase { name: "tbv", got: total_borrowed_value(110, 10), want: 100 },
      // §2.6 — the rate ceiling wins over the minimum, and the other way round.
      ArithCase {
        name: "nlp_rate",
        got: net_loan_proceeds(100_000, 1_000, 0),
        want: 90_000,
      },
      ArithCase {
        name: "nlp_min",
        got: net_loan_proceeds(100_000, 0, 5_000),
        want: 95_000,
      },
      ArithCase {
        name: "nlp_ceil",
        got: net_loan_proceeds(1_000_001, 1, 0),
        want: 999_900,
      },
      ArithCase {
        name: "nlp_zero_fee",
        got: net_loan_proceeds(100, 0, 0),
        want: 100,
      },
      // §2.20 — floor.
      ArithCase {
        name: "market_floor",
        got: market_floor(1_000_000, 300),
        want: 970_000,
      },
      ArithCase {
        name: "market_floor_floors",
        got: market_floor(99, 50),
        want: 98,
      },
      // §4.1's limit_floor — ceiling, against the limit price's reciprocal.
      ArithCase {
        name: "limit_floor_unit",
        got: limit_floor(0, 1_000, PRational(1, 1)),
        want: 1_000,
      },
      ArithCase {
        name: "limit_floor_ceil",
        got: limit_floor(1, 9, PRational(3, 1)),
        want: 4,
      },
      ArithCase {
        name: "limit_floor_deposit_counts",
        got: limit_floor(500, 1_000, PRational(2, 1)),
        want: 750,
      },
      // §6.2.2.13.
      ArithCase {
        name: "async_fill_cost",
        got: async_fill_cost(13_000_000, 3_000_000),
        want: 26_000_000,
      },
      ArithCase { name: "basis_point", got: bp, want: 10_000 },
    ]
  list_all_arith(tests)
}

fn list_all_arith(tests: List<ArithCase>) -> Bool {
  when tests is {
    [] -> True
    [ArithCase { got, want, .. }, ..rest] -> and {
        (got == want)?,
        list_all_arith(rest),
      }
  }
}

test tbv_must_be_positive() fail {
  total_borrowed_value(100, 100) == 0
}

test nlp_must_be_positive() fail {
  net_loan_proceeds(100, constants.basis_point, 0) == 0
}

type NetCase {
  name: ByteArray,
  asset: TupleAsset,
  qty: Int,
  fee_reserve: Int,
  want: Int,
}

test order_net_strips_min_ada_and_reserve() {
  let ada = (assets.ada_policy_id, assets.ada_asset_name)
  let usdm = ("usdm_pid", "usdm")
  let tests =
    [
      // §2.2 — lovelace loses the minADA and the reserve.
      NetCase {
        name: "ada_both",
        asset: ada,
        qty: constants.min_ada + 3_000_000 + 500,
        fee_reserve: 3_000_000,
        want: 500,
      },
      NetCase {
        name: "ada_no_reserve",
        asset: ada,
        qty: constants.min_ada + 7,
        fee_reserve: 0,
        want: 7,
      },
      // A token leg loses neither.
      NetCase {
        name: "token",
        asset: usdm,
        qty: 42,
        fee_reserve: 3_000_000,
        want: 42,
      },
    ]
  list_all_net(tests)
}

fn list_all_net(tests: List<NetCase>) -> Bool {
  when tests is {
    [] -> True
    [NetCase { asset, qty, fee_reserve, want, .. }, ..rest] -> and {
        (order_net_qty(asset, qty, fee_reserve) == want)?,
        (order_net(
          assets.from_asset(asset.1st, asset.2nd, qty),
          asset,
          fee_reserve,
        ) == want)?,
        list_all_net(rest),
      }
  }
}
