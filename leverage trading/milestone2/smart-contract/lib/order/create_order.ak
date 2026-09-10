//// Biz spec §6 — create order.

use cardano/address.{Address}
use cardano/assets.{AssetName}
use cardano/transaction.{Input, Output}
use constants
use daken/input_hash
use daken/prational
use order/utils as order_utils
use types.{MarketDatum, OrderDatum, ProtocolDatum}
use utils

/// Returns the two names this action contributes to `mint[order_skh]` — §6.2.4.1.
pub fn validate(
  order_out: Output,
  order_skh: ByteArray,
  seed_utxo: Input,
  protocol: ProtocolDatum,
  market: MarketDatum,
  market_nft_name: AssetName,
  return: fn(AssetName, AssetName) -> result,
) -> result {
  // §6.2.1 items 1, 2 and 8, §6.2.3.1
  let (order, order_nft_name, _stake) =
    order_utils.order_shape(order_out, order_skh)
  let OrderDatum {
    long_token,
    short_token,
    short_amount,
    min_liquidation_threshold: _,
    allowed_adapters: _,
    is_market,
    market_nft_name: datum_market_nft_name,
    beneficiary: _,
    fee_reserve,
    ..
  } = order
  let Output { value: order_out_value, .. } = order_out

  // §6.2.4.2 — the name comes from the seed's output reference and nothing else.
  expect order_nft_name == input_hash.blake2b_224(seed_utxo)

  // §6.2.1.3
  expect [] = utils.tokens_of(order_out_value, protocol.position_skh)
  expect [] = utils.tokens_of(order_out_value, protocol.loan_skh)
  expect [] = utils.tokens_of(order_out_value, protocol.pool_skh)
  expect [] = utils.tokens_of(order_out_value, protocol.config_pool_skh)

  // §6.2.2.7 — `short_token` is the market's supply token, so §2.2's `net`
  // treatment is the same one every other arm applies. Checked before the
  // whitelist below, which reads both tokens as keys.
  expect long_token != short_token
  expect short_token == market.supply_token

  // §6.2.1.4 — `long_token` is admitted deliberately; it is what
  // `long_from_order_in` and §7.2.17 exist for.
  expect
    utils.holds_only(
      order_out_value,
      [
        (assets.ada_policy_id, assets.ada_asset_name),
        short_token,
        long_token,
        (order_skh, order_nft_name),
      ],
    )

  // §6.2.2.8, and `T` for item 6 below.
  let t = order_utils.enabled_threshold(market, long_token)

  // §6.2.1.5 — `margin` is `net(order_out_value, short_token)` here, the one arm
  // with no order input (§2.3).
  let margin = order_utils.order_net(order_out_value, short_token, fee_reserve)
  // Read the same way, so whichever of the two is ADA has its minADA and reserve
  // deducted and the other is taken raw.
  let long_deposit =
    order_utils.order_net(order_out_value, long_token, fee_reserve)
  // A margin of zero is a **long-funded** order: the trader brings the collateral
  // and borrows the whole position against it, so there is nothing for the venue
  // to buy on their behalf that they have not already supplied. §6.2.1.5's dust
  // bound has no supply-token margin to measure then, and falls on `short_amount`
  // — denominated in that same token, and known here without a price.
  //
  // Such an order is filled **synchronously** or not at all, and nothing here has
  // to say so: §7.3.2 puts the long leg in the loan and §7.3's own bound credits
  // the deposit against what the executor must deliver, while on the asynchronous
  // route §7.4.6 is stated twice — `execute` pins the loan's long holding to
  // `long_from_order_in` and `open_loan` pins it to zero. The two agree only where
  // the deposit is zero, so an asynchronous fill of a long-funded order cannot be
  // built. The health gate that route relies on would in any case refuse it: with
  // no margin the venue is handed the proceeds alone and must return collateral
  // worth `1 / threshold` of them, which no honest price can do.
  expect
    if margin == 0 {
      and {
        (long_deposit > 0)?,
        (short_amount >= market.min_tx_amount)?,
      }
    } else {
      (margin >= market.min_tx_amount)?
    }

  // §6.2.2.1
  expect short_amount > margin

  // §6.2.1.6
  expect
    order_utils.within_leverage_cap(
      margin,
      short_amount,
      t,
      market.loan_origination_fee_rate,
    )?

  // §6.2.1.7
  expect assets.lovelace_of(order_out_value) >= constants.min_ada + fee_reserve

  // §6.2.2 items 2 to 6
  expect order_utils.valid_order_params(order, market)

  // §6.2.2.9
  expect datum_market_nft_name == market_nft_name

  // §6.2.2.13. `allowed_adapters`, `is_market` and `beneficiary` carry no bound
  // of their own — items 10, 11 and 12.
  expect fee_reserve >= 0
  expect or {
      !is_market,
      fee_reserve >= order_utils.async_fill_cost(
        market.venue_fee_budget,
        market.execution_tip,
      ),
    }

  return(
    order_nft_name,
    utils.suffixed(order_nft_name, constants.owner_nft_suffix),
  )
}

// ------------------------------------------------------------------ tests

const t_order_skh = "order_skh"

const t_position_skh = "position_skh"

const t_loan_skh = "loan_skh"

const t_pool_skh = "pool_skh"

const t_config_pool_skh = "config_pool_skh"

const t_ada = (#"", #"")

const t_usdm = ("usdm_pid", "usdm")

const t_market_nft_name = "market_nft"

fn t_seed() -> Input {
  Input {
    output_reference: transaction.OutputReference(
      #"2b405c773982c6cddf1d8b8a80769a84851f3ce21febbb227777b3ba43be14f1",
      0,
    ),
    output: Output {
      address: address.from_script("wallet"),
      value: assets.from_lovelace(10_000_000),
      datum: transaction.NoDatum,
      reference_script: None,
    },
  }
}

fn t_protocol() -> ProtocolDatum {
  ProtocolDatum {
    pool_skh: t_pool_skh,
    loan_skh: t_loan_skh,
    config_pool_skh: t_config_pool_skh,
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
    fee_address: address.from_script("fee"),
    supply_token: t_usdm,
    alt_supply_tokens: [],
    min_tx_amount: 100_000_000,
    liquidator_reward_cap: 1000,
    collector_reward: 3_000_000,
    min_liquidator_reward: 10_000_000,
    rollback_tip: 3_000_000,
    execution_tip: 3_000_000,
    max_cancel_fee: 2_000_000,
    venue_fee_budget: 13_000_000,
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
    open_limit_price: prational.PRational(1, 1),
    take_profit_price: prational.PRational(2, 1),
    min_liquidation_threshold: 8000,
    min_execution_amount: 100_000_000,
    max_slippage: 300,
    allowed_adapters: [],
    is_market: False,
    market_nft_name: t_market_nft_name,
    beneficiary: address.from_script("beneficiary"),
    fee_reserve: 0,
  }
}

/// minADA, the margin, and the `OrderNFT` whose name is the seed's hash.
fn t_value(lovelace: Int, margin: Int) -> assets.Value {
  assets.from_lovelace(lovelace)
    |> assets.merge(assets.from_asset(t_usdm.1st, t_usdm.2nd, margin))
    |> assets.merge(
        assets.from_asset(t_order_skh, input_hash.blake2b_224(t_seed()), 1),
      )
}

fn t_run(datum: OrderDatum, value: assets.Value) -> Bool {
  let nft_name = input_hash.blake2b_224(t_seed())
  let order_out =
    Output {
      address: Address {
        payment_credential: address.Script(t_order_skh),
        stake_credential: None,
      },
      value,
      datum: transaction.InlineDatum(datum),
      reference_script: None,
    }
  validate(
    order_out,
    t_order_skh,
    t_seed(),
    t_protocol(),
    t_market(),
    t_market_nft_name,
    fn(order_nft, order_owner_nft) {
      and {
        (order_nft == nft_name)?,
        (order_owner_nft == utils.suffixed(nft_name, constants.owner_nft_suffix))?,
      }
    },
  )
}

type AcceptCase {
  name: ByteArray,
  datum: OrderDatum,
  value: assets.Value,
}

test create_order_accepts() {
  let base = t_datum()
  let async_reserve = 26_000_000
  let tests =
    [
      // §6.2.1 items 5 to 7 at their boundaries: `margin` exactly
      // `min_tx_amount`, and leverage exactly `leverage_cap(8000) = 5.00x`.
      AcceptCase {
        name: "boundary",
        datum: base,
        value: t_value(constants.min_ada, 100_000_000),
      },
      // §6.2.2.13 — `is_market` needs the reserve, and §2.2 keeps it out of the
      // margin, so leverage is unchanged by it.
      AcceptCase {
        name: "market_order",
        datum: OrderDatum {
          ..base,
          is_market: True,
          fee_reserve: async_reserve,
        },
        value: t_value(constants.min_ada + async_reserve, 100_000_000),
      },
      // Below the cap.
      AcceptCase {
        name: "under_leveraged",
        datum: OrderDatum { ..base, short_amount: 400_000_000 },
        value: t_value(constants.min_ada, 100_000_000),
      },
      // §6.2.1.4 — `long_token` in the order UTxO is admitted deliberately.
      AcceptCase {
        name: "long_token_funded",
        datum: base,
        value: t_value(constants.min_ada + 50_000_000, 100_000_000),
      },
      // Surplus margin.
      AcceptCase {
        name: "surplus_margin",
        datum: base,
        value: t_value(constants.min_ada, 400_000_000),
      },
      // §6.2.1.5 — a **long-funded** order: no supply-token margin at all, so the
      // dust bound falls on `short_amount` and §6.2.1.6 has nothing to measure.
      // `long_token` is ADA in this fixture, so the deposit is the lovelace above
      // minADA.
      AcceptCase {
        name: "long_only_no_margin",
        datum: base,
        value: t_value(constants.min_ada + 500_000_000, 0),
      },
      // The leverage the cap would have refused, which a long-funded order reaches
      // only through §4.1's health floor at fill.
      AcceptCase {
        name: "long_only_beyond_the_cap",
        datum: OrderDatum { ..base, short_amount: 5_000_000_000 },
        value: t_value(constants.min_ada + 500_000_000, 0),
      },
    ]
  run_accepts(tests)
}

fn run_accepts(tests: List<AcceptCase>) -> Bool {
  when tests is {
    [] -> True
    [AcceptCase { datum, value, .. }, ..rest] -> and {
        t_run(datum, value)?,
        run_accepts(rest),
      }
  }
}

// §6.2.1.5
test create_order_rejects_margin_below_min_tx() fail {
  t_run(t_datum(), t_value(constants.min_ada, 99_999_999))
}

// §6.2.1.5 — a long-funded order still owes the dust bound, on `short_amount`.
test create_order_rejects_long_only_below_min_tx() fail {
  t_run(
    OrderDatum { ..t_datum(), short_amount: 99_999_999 },
    t_value(constants.min_ada + 500_000_000, 0),
  )
}

// §6.2.1.5 — and an order funded with neither token is not an order.
test create_order_rejects_no_deposit_at_all() fail {
  t_run(t_datum(), t_value(constants.min_ada, 0))
}

// §6.2.1.6
test create_order_rejects_over_leverage() fail {
  t_run(
    OrderDatum { ..t_datum(), short_amount: 500_000_001 },
    t_value(constants.min_ada, 100_000_000),
  )
}

// §6.2.2.1
test create_order_rejects_short_amount_at_margin() fail {
  t_run(
    OrderDatum { ..t_datum(), short_amount: 100_000_000 },
    t_value(constants.min_ada, 100_000_000),
  )
}

// §6.2.1.7
test create_order_rejects_lovelace_below_reserve() fail {
  t_run(
    OrderDatum { ..t_datum(), fee_reserve: 1 },
    t_value(constants.min_ada, 100_000_000),
  )
}

// §6.2.1.4
test create_order_rejects_alien_token() fail {
  t_run(
    t_datum(),
    t_value(constants.min_ada, 100_000_000)
      |> assets.merge(assets.from_asset("alien", "alien", 1)),
  )
}

// §6.2.1.3
test create_order_rejects_position_token() fail {
  t_run(
    t_datum(),
    t_value(constants.min_ada, 100_000_000)
      |> assets.merge(assets.from_asset(t_position_skh, "someOWN", 1)),
  )
}

// §6.2.2.9
test create_order_rejects_wrong_market_nft() fail {
  t_run(
    OrderDatum { ..t_datum(), market_nft_name: "other" },
    t_value(constants.min_ada, 100_000_000),
  )
}

// §6.2.2.6
test create_order_rejects_slippage_above_cap() fail {
  t_run(
    OrderDatum { ..t_datum(), max_slippage: 301 },
    t_value(constants.min_ada, 100_000_000),
  )
}

// §6.2.2.6 — the lower bound is `fillability_margin`, per §1.3's non-emptiness.
test create_order_rejects_slippage_below_fillability() fail {
  t_run(
    OrderDatum { ..t_datum(), max_slippage: 49 },
    t_value(constants.min_ada, 100_000_000),
  )
}

// §6.2.2.13
test create_order_rejects_market_without_reserve() fail {
  t_run(
    OrderDatum { ..t_datum(), is_market: True, fee_reserve: 25_999_999 },
    t_value(constants.min_ada + 25_999_999, 100_000_000),
  )
}

// §6.2.2.7
test create_order_rejects_short_token_not_supply() fail {
  t_run(
    OrderDatum { ..t_datum(), short_token: ("other", "other") },
    t_value(constants.min_ada, 100_000_000),
  )
}

// §6.2.4.2 — the name must be the seed's hash.
test create_order_rejects_wrong_nft_name() fail {
  let bad =
    assets.from_lovelace(constants.min_ada)
      |> assets.merge(assets.from_asset(t_usdm.1st, t_usdm.2nd, 100_000_000))
      |> assets.merge(assets.from_asset(t_order_skh, "not_the_seed_hash", 1))
  t_run(t_datum(), bad)
}
