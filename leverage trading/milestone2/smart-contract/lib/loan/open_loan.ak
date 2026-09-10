//// Biz spec §7.2 items 19 to 22 — the **loan side** of a fill. The order side is
//// `order/execute`, the position side `position/create_position`, and the pool
//// side `pool/pool_flow`; this file owns only the loan output and the claim.
////
//// Two routes. `Delivered` (§7.3) means the collateral is already in the loan
//// output. `Pending` (§7.4) means it rests at the venue and the loan carries a
//// `Claim` instead.

use aiken/collection/list
use cardano/address.{Address, Inline, Script, VerificationKey}
use cardano/assets.{AssetName, Value}
use cardano/transaction.{InlineDatum, Input, Output, OutputReference}
use constants
use daken/math
use daken/prational.{PRational}
use daken/types.{Redeemers, TupleAsset} as daken_types
use loan/utils.{Contribution, Registry} as loan_utils
use order/utils as order_utils
use pool/utils as pool_utils
use types.{
  Claim, Declaration, Delivered, LoanDatum, MarketDatum, Opening, OrderDatum,
  AdapterEntry, Pending, ScriptHash,
}
use utils

/// One `SingleOpenLoanIndexer`.
pub fn validate(
  // script context
  registry: Registry,
  adapter_skh: ScriptHash,
  market_nft_name: AssetName,
  market: MarketDatum,
  declarations: List<Declaration>,
  // transaction context
  outputs: List<Output>,
  redeemers: Redeemers,
  tx_end: Int,
  // the pool this fill draws from
  pool_out_interest_index: Int,
  pool_borrow_apy: Int,
  pool_interest_time: Int,
  // this loan
  order_in: Input,
  loan_out: Output,
  loan_owner_nft_name: AssetName,
) -> Contribution {
  let Registry { loan_skh, adapters, oracle_skh, .. } = registry
  let MarketDatum {
    collaterals,
    supply_token,
    loan_origination_fee_rate,
    loan_origination_fee_min_amount,
    claim_safety_margin,
    min_claim_duration,
    max_claim_duration,
    venue_fee_budget,
    ..
  } = market

  // §7.2.2 — the adapter must be whitelisted to create
  expect loan_utils.adapter_may(adapters, adapter_skh, True)?

  expect InlineDatum(order_raw) = order_in.output.datum
  expect OrderDatum {
    long_token,
    short_token,
    short_amount: short_amount_before,
    open_limit_price,
    market_nft_name: order_market_nft_name,
    fee_reserve: order_fee_reserve,
    ..
  }: OrderDatum = order_raw

  // §7.2.5 — the order belongs to this market, and its short leg is the pool's
  expect (order_market_nft_name == market_nft_name)?
  expect (short_token == supply_token)?

  // §7.2.20 — the loan output, address in both credentials and every datum field
  let Output {
    address: loan_address,
    value: loan_value,
    datum: loan_datum_raw,
    reference_script,
  } = loan_out
  expect (reference_script == None)?
  expect utils.at_script(loan_address, loan_skh)?
  expect
    (loan_address.stake_credential == order_in.output.address.stake_credential)?
  expect InlineDatum(raw) = loan_datum_raw
  expect LoanDatum {
    owner_nft: Some(owner_nft),
    token: loan_token,
    loan_amount,
    initial_interest_index,
    claim,
  }: LoanDatum = raw

  // §7.2.20 — the `LoanOwnerNFT` this loan is read through is minted under
  // `loan_skh`, not under the position script: it is the position **output** that
  // holds it, which is `position/create_position`'s clause, and §7.2.19 names the
  // pair `(loan_skh, name)`. Naming `position_skh` here contradicted both
  // `order/execute` and `pool/utils.loan_by_owner_nft`, which look the loan up by
  // that very pair — the pool's withdrawal failed on an empty list.
  expect (owner_nft == (loan_skh, loan_owner_nft_name))?
  expect (loan_token == supply_token)?
  // §7.2.20 — a new loan starts at the pool's advanced index, which is what makes
  // its `debt_now` equal its `loan_amount` exactly
  expect (initial_interest_index == pool_out_interest_index)?
  expect (loan_amount > 0)?
  expect (loan_amount <= short_amount_before)?

  // §2 item 6
  let rate_fee =
    math.ceiling_div(
      loan_origination_fee_rate * loan_amount,
      constants.basis_point,
    )
  let origination_fee =
    if rate_fee > loan_origination_fee_min_amount {
      rate_fee
    } else {
      loan_origination_fee_min_amount
    }
  let net_loan_proceeds = loan_amount - origination_fee
  expect (net_loan_proceeds > 0)?

  let route = loan_utils.route_for(declarations, loan_owner_nft_name)
  let binding_mint =
    when route is {
      // ------------------------------------------------- §7.3, synchronous
      Delivered { asset, amount, binding_nft } -> {
        expect (asset == long_token)?
        // §7.3.4 — no binding NFT on this route
        expect (binding_nft == None)?
        // §7.3.3
        expect (claim == None)?
        // §7.3.2 — the collateral clears the trader's own limit price
        expect (utils.net(loan_value, long_token) >= amount)?
        expect
          (amount >= math.ceiling_div(
            net_loan_proceeds * open_limit_price.denominator,
            open_limit_price.numerator,
          ))?
        []
      }

      // ------------------------------------------------ §7.4, asynchronous
      Pending { asset, floor, market_floor, binding_nft, expiry, .. } -> {
        expect (asset == long_token)?
        // §7.4.3 — the binding NFT is this loan's own owner name, suffixed
        expect
          (binding_nft == (
            loan_skh,
            utils.suffixed(loan_owner_nft_name, constants.binding_nft_suffix),
          ))?
        // §7.4.4
        expect (expiry - tx_end >= min_claim_duration)?
        expect (expiry - tx_end <= max_claim_duration)?

        // §7.4.5 — `sold` is the margin this fill takes **plus** the proceeds.
        // With the proceeds alone the trader's margin goes to the venue for
        // nothing: the order output is allowed to keep none of it, the loan holds
        // none of it, and the difference lands in the filler's change.
        let margin =
          order_utils.order_net(
            order_in.output.value,
            short_token,
            order_fee_reserve,
          )
        let tbv = order_utils.total_borrowed_value(short_amount_before, margin)
        let short_from_order_in =
          order_utils.deposit_qty(margin, loan_amount, tbv)
        // §6.2.1.4 admits the long token in the order, and §7.2.16 releases this
        // fill's share of it. `order/execute` computes the same figure from the
        // same three numbers, so the two scripts agree by construction.
        let long_from_order_in =
          order_utils.deposit_qty(
            order_utils.order_net(
              order_in.output.value,
              long_token,
              order_fee_reserve,
            ),
            loan_amount,
            tbv,
          )
        let sold = short_from_order_in + net_loan_proceeds
        // §4.1 — the floor is an equality over the three terms, and the
        // declaration carries `market_floor` so one party can evaluate the max
        let p =
          loan_utils.price_of(
            loan_utils.prices_for(redeemers, oracle_skh, supply_token),
            long_token,
          )
        let debt_at_expiry =
          loan_utils.debt_at(
            loan_amount,
            pool_borrow_apy,
            pool_interest_time,
            expiry,
          )
        let threshold =
          loan_utils.threshold_of(collaterals, supply_token, long_token)
        let limit_floor =
          math.ceiling_div(
            sold * open_limit_price.denominator,
            open_limit_price.numerator,
          )
        // §4.1. `health_floor` bounds the collateral the loan must end up
        // holding, and what the order brought is already part of that — the
        // venue is only asked for the difference. `market_floor` and
        // `limit_floor` are untouched: both speak about the swap, not about the
        // total. A margin-funded order deposits no long token, so the credit is
        // zero and this is the bound it always was.
        let health =
          loan_utils.health_floor(
            debt_at_expiry,
            claim_safety_margin,
            threshold,
            p,
          )
        let health_owed_by_venue =
          if health > long_from_order_in {
            health - long_from_order_in
          } else {
            0
          }
        expect
          (floor == loan_utils.opening_floor(
            health_owed_by_venue,
            market_floor,
            limit_floor,
          ))?
        // §4.1 — a return must be distinguishable from a fill on the paid leg
        expect
          loan_utils.floor_clears_venue_budget(
            floor,
            long_token,
            venue_fee_budget,
          )?

        // §7.4.5 — the claim, field by field from the declaration
        expect
          (claim == Some(
            Claim {
              adapter_skh,
              binding_nft,
              direction: Opening,
              asset: long_token,
              sold,
              floor,
              expiry,
            },
          ))?
        // §7.4.6 — the venue holds the leg it is buying, so the loan holds none
        // of it beyond what the order handed over. `order/execute` has always
        // pinned this to `long_from_order_in`; pinning it to zero here made the
        // two agree only where the order carried no collateral, which is what had
        // made a long-funded order unfillable on this route.
        expect (utils.net(loan_value, long_token) == long_from_order_in)?
        let (_bpid, bname) = binding_nft
        [(bname, 1)]
      }

      // §7.2's fill never recovers
      _ -> fail @"open_loan: route must be Delivered or Pending"
    }

  // §7.2.12 — two distinct names: the `LoanNFT` is named for the **market**, so a
  // batch of `N` fills mints `N` of it, while the `LoanOwnerNFT` is named for this
  // fill alone. Naming both the same asset contradicts §7.2.12's per-fill point
  // check in `order/execute`, which requires exactly one of the owner name.
  Contribution {
    loan_mint: list.concat(
      [(market_nft_name, 1), (loan_owner_nft_name, 1)],
      binding_mint,
    ),
    opened_proceeds: net_loan_proceeds,
    retired: 0,
    shortfall: 0,
  }
}

// ---------------------------------------------------------------------- tests

const t_fbtc =
  (#"007c4fc75b7662fc735177aa714da9d1b06af5644df199fef39e5fc1", #"66425443")

const t_fusdm =
  (#"834a15101873b4e1ddfaa830df46792913995d8738dcde34eda27905", #"665553444d")

const t_loan = #"505e255e247cea71028bcc6677ca4bc9bdc02e0594cb5dbba2f0de9f"

const t_order = #"a0f88aa259305f096729aee5840ebe12f4a456994952d01caac45a25"

const t_oracle = #"3158c9a7ba551eb3b6b9aa578e7995dec5ce34e272fde0bda76b46d1"

const t_adapter = #"c7337667ee947fb46cbadeac3285d2c61ec42581fed9918e793890ca"

const t_market_nft = #"914c34dab9c5a29a6f8ae414845250cb31afc5017492d1fc2ea381b6"

const t_owner = #"a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1"

const t_stake = #"c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1"

fn t_addr(skh: ByteArray) -> Address {
  Address {
    payment_credential: Script(skh),
    stake_credential: Some(Inline(VerificationKey(t_stake))),
  }
}

fn t_registry() -> Registry {
  Registry {
    pool_skh: #"9e5239107df6622c50a22cae6567b4a90a372458ad375f5ddf453b40",
    loan_skh: t_loan,
    loan_repay_skh: #"414be350f5cd1c9796a44d70ef23e98f5f40bf2425efd2278da52588",
    loan_close_skh: #"0291c46094eacde5ea1f7006636ccd0623c546f5a85ea4fdc3e2b71f",
    config_pool_skh: #"4b3aaf66e7bb6cf47798a3b68bafecc9d55489ba7f3977fc0681d2a3",
    order_skh: t_order,
    position_skh: #"c177d56c716f6a962602f00232342cd1ae708270e356a8b196183e57",
    oracle_skh: t_oracle,
    adapters: [Pair(t_adapter, AdapterEntry { may_create: True, may_recover: True })],
  }
}

/// The fUSDM market as `--create-market fusdm` writes it: fUSDM lent, fBTC the
/// one collateral, and no alternative supply token.
fn t_market() -> MarketDatum {
  MarketDatum {
    ..pool_utils.t_market(0, 8000, False),
    collaterals: [Pair(t_fbtc, (8000, True))],
    supply_token: t_fusdm,
    alt_supply_tokens: [],
    loan_origination_fee_rate: 100,
    min_tx_amount: 100_000_000,
    venue_fee_budget: 20_000_000,
  }
}

/// §7.4 as preprod refused it — `--fill-minswap` on the fUSDM market builds every
/// number below and the loan policy rejects the mint. Each figure is the one that
/// transaction printed, and the three floor terms are computed here the way the
/// core computes them rather than pasted, so a mismatch in the arithmetic shows
/// up as a floor that disagrees rather than as a fixture that lies.
test async_fill_on_a_token_market() {
  let long = t_fbtc
  let supply = t_fusdm
  let binding = utils.suffixed(t_owner, constants.binding_nft_suffix)
  let market = t_market()
  let p = PRational { numerator: 23597937993546, denominator: 17928992479 }
  let apy = 761
  let index = 1000048722316
  let tx_end = 1788482953000
  let expiry = tx_end + 600_000
  let interest_time = tx_end
  let loan_amount = 150_000_000
  let short_amount = 300_000_000
  let margin = 150_000_000
  let nlp = 148_500_000
  let sold = 298_500_000
  let market_floor = 219_873
  let debt_at_expiry = loan_utils.debt_at(loan_amount, apy, interest_time, expiry)
  let health = loan_utils.health_floor(debt_at_expiry, 50, 8000, p)
  let limit_floor = math.ceiling_div(nlp, 1400)
  let floor = loan_utils.opening_floor(health, market_floor, limit_floor)

  let order_datum =
    OrderDatum {
      long_token: long,
      short_token: supply,
      short_amount,
      open_limit_price: PRational { numerator: 1400, denominator: 1 },
      take_profit_price: PRational { numerator: 0, denominator: 1 },
      min_liquidation_threshold: 8000,
      min_execution_amount: 100_000_000,
      max_slippage: 300,
      allowed_adapters: [t_adapter],
      is_market: True,
      market_nft_name: t_market_nft,
      beneficiary: t_addr(t_order),
      fee_reserve: 33_000_000,
    }
  let order_in =
    Input {
      output_reference: OutputReference {
        transaction_id: #"0000000000000000000000000000000000000000000000000000000000000000",
        output_index: 0,
      },
      output: Output {
        address: t_addr(t_order),
        value: assets.from_lovelace(38_000_000)
          |> assets.merge(assets.from_asset(supply.1st, supply.2nd, margin)),
        datum: InlineDatum(order_datum),
        reference_script: None,
      },
    }

  let claim =
    Claim {
      adapter_skh: t_adapter,
      binding_nft: (t_loan, binding),
      direction: Opening,
      asset: long,
      sold,
      floor,
      expiry,
    }
  let loan_out =
    Output {
      address: t_addr(t_loan),
      value: assets.from_lovelace(constants.min_ada)
        |> assets.merge(assets.from_asset(t_loan, t_market_nft, 1)),
      datum: InlineDatum(
        LoanDatum {
          owner_nft: Some((t_loan, t_owner)),
          token: supply,
          loan_amount,
          initial_interest_index: index,
          claim: Some(claim),
        },
      ),
      reference_script: None,
    }

  let declaration =
    Declaration {
      loan_owner_nft_name: t_owner,
      route: Pending {
        asset: long,
        floor,
        market_floor,
        binding_nft: (t_loan, binding),
        expiry,
        slippage_src_idx: 0,
        venue_ref_idx: 0,
        venue_out_idx: 0,
        stake_credential: Some(Inline(VerificationKey(t_stake))),
      },
    }
  let oracle_rdmr =
    loan_utils.OraclePriceRedeemer {
      global_config_idx: 0,
      oracle_path_idxs: [],
      oracle_idxs: [],
      prices: [Pair(supply, [Pair(long, p)])],
      borrow_rates: [],
    }

  let contribution =
    validate(
      t_registry(),
      t_adapter,
      t_market_nft,
      market,
      [declaration],
      [],
      pool_utils.t_withdraw_redeemers(t_oracle, oracle_rdmr),
      tx_end,
      index,
      apy,
      interest_time,
      order_in,
      loan_out,
      t_owner,
    )
  and {
    (contribution.opened_proceeds == nlp)?,
    (contribution.loan_mint == [(t_market_nft, 1), (t_owner, 1), (binding, 1)])?,
  }
}
