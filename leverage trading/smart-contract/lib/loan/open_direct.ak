//// Biz spec §7.6 — a loan opened against collateral the borrower already holds.
////
//// §7.2 exists because the venue buys the collateral on the borrower's behalf:
//// the order states how much of their own money they put up, what price they
//// will accept and how much slippage they tolerate, and the fill has to honour
//// all three. A borrower who deposits the collateral themselves is buying
//// nothing. None of those terms has anything to say about the loan that results,
//// which is only ever an amount owed against a holding, its health and its
//// accrual — so this arm asks for no order, no venue, no adapter and no claim.
////
//// What it keeps is everything that protects the pool: the loan is healthy at
//// the oracle's price when it opens (§3), it is no smaller than `min_tx_amount`,
//// its index is the pool's, and the origination fee is charged.
////
//// A borrower opening at the market price is buying, and has no need of an order
//// to say so: the order's three terms only ever addressed a keeper filling on
//// their behalf. So this arm also opens **with** a claim, placing the venue order
//// in the same transaction — one transaction to open, the venue's own batcher to
//// fill, §8 to settle. The collateral is then in flight rather than held, and §3
//// is met by the floor the venue owes instead of by a holding. Everything that
//// bounds a swap comes from the adapter's declaration, exactly as in §7.4; what
//// the order used to supply — a margin to measure and a limit price — is replaced
//// by a single bound on `sold`, and this arm takes no limit price at all.

use aiken/collection/list
use cardano/address.{Address, Inline, Script, VerificationKey}
use cardano/assets.{AssetName}
use cardano/transaction.{InlineDatum, Output, Withdraw}
use daken/types.{Redeemers} as daken_types
use loan/utils.{Contribution, Registry} as loan_utils
use order/utils as order_utils
use pool/utils as pool_utils
use constants
use daken/prational.{PRational}
use types.{
  AdapterEntry, AdapterRedeemer, Claim, Declaration, LoanDatum, MarketDatum, Opening, Pending,
  PositionDatum,
}
use utils

/// One `SingleOpenDirectIndexer`.
pub fn validate(
  registry: Registry,
  market_nft_name: AssetName,
  market: MarketDatum,
  redeemers: Redeemers,
  tx_end: Int,
  pool_out_interest_index: Int,
  pool_borrow_apy: Int,
  pool_interest_time: Int,
  loan_out: Output,
  position_out: Output,
  loan_owner_nft_name: AssetName,
) -> Contribution {
  let Registry { loan_skh, adapters, oracle_skh, .. } = registry
  let MarketDatum {
    collaterals,
    supply_token,
    min_tx_amount,
    loan_origination_fee_rate,
    loan_origination_fee_min_amount,
    claim_safety_margin,
    min_claim_duration,
    max_claim_duration,
    venue_fee_budget,
    ..
  } = market

  // §7.6.2 — the collateral this loan is opened against is the position's own
  // `long_token`. The position output is named by this action and validated by
  // the position script's `CreatePosition`, which is what ties the two together.
  expect InlineDatum(position_raw) = position_out.datum
  expect PositionDatum { long_token, .. }: PositionDatum = position_raw

  // `read_loan` reads an input; this loan is an output and does not exist yet, so
  // its shape is checked here. The `LoanNFT` is the one token of `loan_skh` the
  // loan holds — §7.2.19 puts the `LoanOwnerNFT` on the position instead.
  let Output { address: loan_address, value: loan_value, datum: loan_raw, .. } =
    loan_out
  expect InlineDatum(loan_data) = loan_raw
  expect LoanDatum { owner_nft, token, loan_amount, initial_interest_index, claim }: LoanDatum =
    loan_data
  expect [(loan_nft_name, 1)] = utils.tokens_of(loan_value, loan_skh)
  expect (loan_nft_name == market_nft_name)?

  // §7.6.3 — the shape every later arm reads this loan through.
  expect (owner_nft == Some((loan_skh, loan_owner_nft_name)))?
  expect (token == supply_token)?
  expect (initial_interest_index == pool_out_interest_index)?
  expect (loan_amount >= min_tx_amount)?

  // §7.6.4 — the loan holds nothing of the supply token on either route: what is
  // borrowed leaves, either for the borrower or for the venue.
  expect (utils.net(loan_value, supply_token) == 0)?
  expect utils.at_script(loan_address, loan_skh)?

  // §7.6.6 — the pool lends `loan_amount` and keeps the origination fee, exactly
  // as §7.2.20 has it.
  let net_loan_proceeds =
    order_utils.net_loan_proceeds(
      loan_amount,
      loan_origination_fee_rate,
      loan_origination_fee_min_amount,
    )
  let prices = loan_utils.prices_for(redeemers, oracle_skh, supply_token)

  let binding_mint =
    when claim is {
      // ------------------------------- the collateral is already the borrower's
      None -> {
        // §7.6.1 — no venue takes part, so no adapter may either.
        expect pool_utils.no_adapter_withdrawal(redeemers, adapters)?
        // §7.6.4 — §3's gate is measured on what stays.
        expect (utils.net(loan_value, long_token) > 0)?
        // §7.6.5 — §3 at the oracle's price, on the whole of what the loan holds.
        // This is the only price this route reads, and the only one it needs:
        // there is no purchase to bound, only a debt to cover.
        expect
          loan_utils.is_healthy(
            loan_utils.collateral_value(
              loan_value,
              (loan_skh, loan_nft_name),
              collaterals,
              supply_token,
              long_token,
              utils.net(loan_value, long_token),
              prices,
            ),
            loan_amount,
          )?
        []
      }

      // ------------------------- §7.6.7, the venue buys with no order in between
      Some(Claim {
        adapter_skh,
        binding_nft,
        direction,
        asset,
        sold,
        floor,
        expiry,
      }) -> {
        // §7.6.7.1 — the adapter is what constrains the venue order, so it must be
        // whitelisted to create and its withdrawal has to be here to be read.
        expect loan_utils.adapter_may(adapters, adapter_skh, True)?
        expect Pending {
          asset: route_asset,
          floor: route_floor,
          market_floor,
          binding_nft: route_binding,
          expiry: route_expiry,
          stake_credential,
          ..
        } =
          loan_utils.route_for(
            loan_utils.declarations_of(redeemers, adapter_skh),
            loan_owner_nft_name,
          )
        // §7.6.7.2 — the claim is the declaration, term for term, so the adapter
        // and the core cannot be reading two different swaps.
        expect (direction == Opening)?
        expect (asset == long_token)?
        expect (route_asset == long_token)?
        expect (route_binding == binding_nft)?
        expect (route_expiry == expiry)?
        expect (route_floor == floor)?
        // §7.4.3 — the binding NFT is this loan's own owner name, suffixed
        expect
          (binding_nft == (
            loan_skh,
            utils.suffixed(loan_owner_nft_name, constants.binding_nft_suffix),
          ))?
        // §7.4.4
        expect (expiry - tx_end >= min_claim_duration)?
        expect (expiry - tx_end <= max_claim_duration)?
        // §7.5 — the core's half of `receiver`. §7.2 anchors it to the order it
        // spends; there is no order here, so the venue pays back to the stake
        // credential this loan itself lives under.
        expect (stake_credential == loan_address.stake_credential)?
        // §7.6.7.3 — what the pool lends has to reach the venue. §7.2 gets this
        // for free from `sold == margin + net_loan_proceeds`; with no order to
        // measure the margin against, this bound is the whole of what stops a
        // borrower drawing the loan, sending a token of it to be swapped and
        // leaving §12 to book the rest as bad debt.
        expect (sold >= net_loan_proceeds)?
        // §7.6.7.4 — the collateral is in flight, so §3 is met by the floor the
        // venue owes rather than by a holding. There is no limit price on this
        // route, so §4.1's third term is absent and the max is over two.
        expect (utils.net(loan_value, long_token) == 0)?
        expect
          (floor == loan_utils.opening_floor(
            loan_utils.health_floor(
              loan_utils.debt_at(
                loan_amount,
                pool_borrow_apy,
                pool_interest_time,
                expiry,
              ),
              claim_safety_margin,
              loan_utils.threshold_of(collaterals, supply_token, long_token),
              loan_utils.price_of(prices, long_token),
            ),
            market_floor,
            0,
          ))?
        // §4.1 — a return must be distinguishable from a fill on the paid leg
        expect
          loan_utils.floor_clears_venue_budget(
            floor,
            long_token,
            venue_fee_budget,
          )?
        let (_bpid, bname) = binding_nft
        [(bname, 1)]
      }
    }

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

test collateral_value_of_a_one_asset_loan_is_the_weighed_holding() {
  // §7.6.5 reads §2.12a on a loan holding exactly one collateral, its `LoanNFT`
  // and its minADA — and nothing else, since §7.6.4 forbids the supply token.
  // This is the whole of what an off-chain caller has to reproduce to size such a
  // loan, and the two have drifted before. The lovelace never contributes: `net`
  // takes `min_ada` off it, so even on an ADA-supply market, where §2.12a admits
  // lovelace into the domain, there is nothing left of it to weigh.
  let loan_skh = #"beef"
  let nft_name = #"4d41524b"
  let long = (#"cafe", #"4c4f4e47")
  let supply = (#"", #"")
  let collaterals = [Pair(long, (8000, True))]
  let prices = [Pair(long, PRational { numerator: 3, denominator: 2 })]
  let tests =
    [
      // (long_amount, expected) — qty * 3 * 8000 / (2 * 10000)
      (1_000_000, 1_200_000),
      (5_000_000, 6_000_000),
      // the floor divides: 7 * 3 * 8000 / 20000 == 8, not 8.4
      (7, 8),
      (0, 0),
    ]
  list.all(
    tests,
    fn((long_amount, expected)) {
      let value =
        assets.from_asset(long.1st, long.2nd, long_amount)
          |> assets.merge(assets.from_asset(loan_skh, nft_name, 1))
          |> assets.merge(assets.from_lovelace(constants.min_ada))
      loan_utils.collateral_value(
        value,
        (loan_skh, nft_name),
        collaterals,
        supply,
        long,
        long_amount,
        prices,
      ) == expected
    },
  )
}


// --------------------------------------------- fixtures for the claim route

const t_loan = #"505e255e247cea71028bcc6677ca4bc9bdc02e0594cb5dbba2f0de9f"

const t_oracle = #"3158c9a7ba551eb3b6b9aa578e7995dec5ce34e272fde0bda76b46d1"

const t_adapter = #"c7337667ee947fb46cbadeac3285d2c61ec42581fed9918e793890ca"

const t_position = #"c177d56c716f6a962602f00232342cd1ae708270e356a8b196183e57"

const t_market_nft = #"914c34dab9c5a29a6f8ae414845250cb31afc5017492d1fc2ea381b6"

const t_owner = #"a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1"

const t_stake = #"c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1"

const t_fbtc =
  (#"007c4fc75b7662fc735177aa714da9d1b06af5644df199fef39e5fc1", #"66425443")

const t_fusdm =
  (#"834a15101873b4e1ddfaa830df46792913995d8738dcde34eda27905", #"665553444d")

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
    order_skh: #"a0f88aa259305f096729aee5840ebe12f4a456994952d01caac45a25",
    position_skh: t_position,
    oracle_skh: t_oracle,
    adapters: [
      Pair(t_adapter, AdapterEntry { may_create: True, may_recover: True }),
    ],
  }
}

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

fn t_position_out() -> Output {
  Output {
    address: t_addr(t_position),
    value: assets.from_lovelace(constants.min_ada)
      |> assets.merge(assets.from_asset(t_position, t_owner, 1)),
    datum: InlineDatum(
      PositionDatum {
        long_token: t_fbtc,
        take_profit_price: PRational { numerator: 0, denominator: 1 },
        min_execution_amount: 100_000_000,
        max_slippage: 300,
        beneficiary: t_addr(t_position),
      },
    ),
    reference_script: None,
  }
}

/// §7.6.7 built the way `--borrow-async` builds it: the borrower's own 150 fUSDM
/// plus the 148.5 the pool nets go to the venue as one swap, the loan holds no
/// collateral yet, and the floor is the max of health and the venue's own
/// reserve term — no limit price takes part on this route.
fn t_open_direct_async(sold: Int) -> Contribution {
  let binding = utils.suffixed(t_owner, constants.binding_nft_suffix)
  let p = PRational { numerator: 23597937993546, denominator: 17928992479 }
  let apy = 761
  let index = 1000048722316
  let tx_end = 1788482953000
  let expiry = tx_end + 600_000
  let loan_amount = 150_000_000
  let market_floor = 219_873
  let floor =
    loan_utils.opening_floor(
      loan_utils.health_floor(
        loan_utils.debt_at(loan_amount, apy, tx_end, expiry),
        50,
        8000,
        p,
      ),
      market_floor,
      0,
    )
  let claim =
    Claim {
      adapter_skh: t_adapter,
      binding_nft: (t_loan, binding),
      direction: Opening,
      asset: t_fbtc,
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
          token: t_fusdm,
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
        asset: t_fbtc,
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
  let oracle_rdmr: Data =
    loan_utils.OraclePriceRedeemer {
      global_config_idx: 0,
      oracle_path_idxs: [],
      oracle_idxs: [],
      prices: [Pair(t_fusdm, [Pair(t_fbtc, p)])],
      borrow_rates: [],
    }
  let adapter_rdmr: Data =
    AdapterRedeemer {
      declarations: [declaration],
      protocol_config_ref_idx: 0,
      market_ref_idx: 0,
    }
  let redeemers: Redeemers =
    [
      Pair(Withdraw(Script(t_oracle)), oracle_rdmr),
      Pair(Withdraw(Script(t_adapter)), adapter_rdmr),
    ]
  validate(
    t_registry(),
    t_market_nft,
    t_market(),
    redeemers,
    tx_end,
    index,
    apy,
    tx_end,
    loan_out,
    t_position_out(),
    t_owner,
  )
}

test open_direct_takes_a_pending_claim() {
  let contribution = t_open_direct_async(298_500_000)
  let binding = utils.suffixed(t_owner, constants.binding_nft_suffix)
  and {
    (contribution.opened_proceeds == 148_500_000)?,
    (contribution.loan_mint == [(t_market_nft, 1), (t_owner, 1), (binding, 1)])?,
  }
}

test open_direct_rejects_sold_below_the_proceeds() fail {
  // §7.6.7.3 — one lovelace short of what the pool nets is the whole of the
  // attack: the rest of the loan stays with the borrower and §12 books it.
  t_open_direct_async(148_499_999) == t_open_direct_async(148_499_999)
}
