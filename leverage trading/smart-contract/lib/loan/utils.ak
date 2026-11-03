//// Biz spec §2 items 9 to 17, §3's health gate, and the reference-input and
//// oracle reads §5 rules 3 and 5 require of every loan arm.
////
//// Flooring direction, `PRational` pairs and clamp placement are the deployed
//// Float rate lending validator's. Where a formula departs, the item says so.

use aiken/collection/list
use aiken/collection/pairs
use aiken/math
use aiken/primitive/bytearray
use cardano/address.{Address, Script}
use cardano/assets.{AssetName, Value}
use cardano/transaction.{
  InlineDatum, Input, NoDatum, Output, Redeemer, ScriptPurpose, ValidityRange,
  Withdraw,
}
use constants
use daken/flist
use daken/math as daken_math
use daken/pairs as daken_pairs
use daken/prational.{PRational}
use daken/time
use daken/tokens
use daken/types.{Basis, OK, TupleAsset} as daken_types
use types.{
  AdapterEntry, AdapterRedeemer, Claim, ClaimDirection, Closing, CollateralRoute, Declaration,
  LiquidationThreshold, LoanDatum, MarketDatum, Opening, PoolDatum,
  PositionDatum, ProtocolDatum, RemainDatum, ScriptHash,
}
use utils

/// The oracle price script's own redeemer — §5 rule 5. Only `prices` is read;
/// the remaining fields are the oracle's own proof machinery and this protocol
/// constrains nothing about how a value was derived. Keys are `TupleAsset`, and
/// each rate is a bare `PRational`: the oracle this registry names serialises its
/// index lists as lists, which is the V1 shape, and V1 carries no `CalcType`.
pub type OraclePrices =
  Pairs<TupleAsset, Pairs<TupleAsset, PRational>>

pub type OraclePriceRedeemer {
  global_config_idx: Data,
  oracle_path_idxs: Data,
  oracle_idxs: Data,
  prices: OraclePrices,
  borrow_rates: Data,
}

/// Everything §5 rule 3 resolves from `protocol_config`, read once per redeemer.
pub type Registry {
  pool_skh: ScriptHash,
  loan_skh: ScriptHash,
  loan_repay_skh: ScriptHash,
  loan_close_skh: ScriptHash,
  config_pool_skh: ScriptHash,
  order_skh: ScriptHash,
  position_skh: ScriptHash,
  oracle_skh: ScriptHash,
  adapters: Pairs<ScriptHash, AdapterEntry>,
}

pub const ada: TupleAsset = (#"", #"")

// --------------------------------------------------------------- §2 arithmetic

/// §2.9 — principal plus accrued interest, floored, as Float lending and the
/// deployed `take_profit` both compute it.
pub fn debt_now(
  loan_amount: Int,
  interest_index: Int,
  initial_interest_index: Int,
) -> Int {
  loan_amount * interest_index / initial_interest_index
}

/// §2.10 — the debt projected to `t`. The ceiling is this design's, in the
/// pool's favour: Float lending never projects past `tx_start` and both of its
/// forward computations floor.
pub fn debt_at(debt: Int, borrow_apy: Basis, interest_time: Int, t: Int) -> Int {
  debt + daken_math.ceiling_div(
    debt * borrow_apy * ( t - interest_time ),
    constants.basis_point * constants.year_in_ms,
  )
}

/// §2.11 — how much `long_token` backs the loan. `payout` is the arrived payout
/// where §11.2 consumes it, `None` everywhere else.
pub fn collateral_amount(
  claim: Option<Claim>,
  loan_value: Value,
  long_token: TupleAsset,
  payout: Option<Int>,
) -> Int {
  when claim is {
    None -> utils.net(loan_value, long_token)
    Some(Claim { direction: Opening, floor, .. }) ->
      when payout is {
        Some(arrived) -> arrived
        None -> floor
      }
    Some(Claim { direction: Closing, .. }) -> 0
  }
}

/// §2.12 — `T(a)`. The borrowed token held as collateral carries **no haircut**;
/// that case is a deliberate departure from the deployed contract, which
/// haircuts the supply token like any other collateral. `enabled` is not read:
/// an asset whose key is disabled still contributes at `T(a)`, and a key absent
/// from `collaterals` altogether fails per §5 rule 13.
pub fn threshold_of(
  collaterals: Pairs<TupleAsset, (LiquidationThreshold, Bool)>,
  short_token: TupleAsset,
  a: TupleAsset,
) -> LiquidationThreshold {
  if a == short_token {
    constants.basis_point
  } else {
    let (threshold, _enabled) = daken_pairs.get_first(collaterals, a)
    threshold
  }
}

/// The oracle's rate for `a`, quoted as `short_token` per `a`. A missing entry
/// fails the arm — §5 rule 5.
pub fn price_of(
  prices: Pairs<TupleAsset, PRational>,
  a: TupleAsset,
) -> PRational {
  daken_pairs.get_first(prices, a)
}

/// The unit of account is worth one of itself, asserted here rather than read
/// from the oracle.
///
/// Demanding that the oracle quote `short_token` against itself at exactly 1/1
/// was this protection stated as a requirement on the quote, and the deployed
/// oracle refuses it: a self-pair has no price path to prove, so the whole
/// withdrawal fails. Fixing the rate here is strictly stronger — an oracle
/// cannot inflate the unit of account when it is never asked about it.
pub fn price_or_unit(
  prices: Pairs<TupleAsset, PRational>,
  short_token: TupleAsset,
  a: TupleAsset,
) -> PRational {
  if a == short_token {
    PRational { numerator: 1, denominator: 1 }
  } else {
    price_of(prices, a)
  }
}

/// One term of §2.12a's sum: `floor(qty × p.num × T / (p.den × basis_point))`,
/// the deployed contract's expression unchanged.
pub fn weigh(qty: Int, p: PRational, threshold: LiquidationThreshold) -> Int {
  qty * p.numerator * threshold / ( p.denominator * constants.basis_point )
}

/// §2.12a — the risk-adjusted worth of everything backing the loan, summed per
/// asset at that asset's own threshold, one floor per asset.
///
/// The domain is `net(loan_value, ·)` less the `LoanNFT`, which must be present
/// exactly once. `long_token` is taken from `long_amount` — §2.11's
/// `collateral_amount` — rather than from the holding, so a resting claim is
/// valued at its `floor` and an arrived payout at what arrived; where the loan
/// carries no claim the two coincide. Lovelace enters the domain only where ADA
/// is `short_token` or an **enabled** `collaterals` key.
pub fn collateral_value(
  loan_value: Value,
  loan_nft: TupleAsset,
  collaterals: Pairs<TupleAsset, (LiquidationThreshold, Bool)>,
  short_token: TupleAsset,
  long_token: TupleAsset,
  long_amount: Int,
  prices: Pairs<TupleAsset, PRational>,
) -> Int {
  let ada_counts = ada_is_collateral(collaterals, short_token)
  let (sum, has_loan_nft) =
    loan_value
      |> assets.reduce(
          (0, False),
          fn(pid, name, qty, (sum, has_loan_nft)) {
            let a = (pid, name)
            if a == loan_nft {
              expect qty == 1
              (sum, True)
            } else if a == long_token {
              // valued from `long_amount` below, never from the holding
              (sum, has_loan_nft)
            } else if tokens.is_ada(a) && !ada_counts {
              (sum, has_loan_nft)
            } else {
              let net_qty =
                if tokens.is_ada(a) {
                  qty - constants.min_ada
                } else {
                  qty
                }
              (
                sum + weigh(
                  net_qty,
                  price_or_unit(prices, short_token, a),
                  threshold_of(collaterals, short_token, a),
                ),
                has_loan_nft,
              )
            }
          },
        )
  expect has_loan_nft?
  sum + weigh(
    long_amount,
    price_or_unit(prices, short_token, long_token),
    threshold_of(collaterals, short_token, long_token),
  )
}

/// True where lovelace belongs in §2.12a's domain. `short_token == ada` is this
/// file's addition: on an ADA-supply market nothing puts ADA in `collaterals`,
/// yet §2.12a values the un-swapped `short_token` remainder at
/// `T(short_token) == basis_point`, so the domain has to admit it.
pub fn ada_is_collateral(
  collaterals: Pairs<TupleAsset, (LiquidationThreshold, Bool)>,
  short_token: TupleAsset,
) -> Bool {
  or {
    short_token == ada,
    when pairs.get_first(collaterals, ada) is {
      Some((_threshold, enabled)) -> enabled
      None -> False
    },
  }
}

/// §3 — non-strict, and there is **no** buffer beyond the liquidation
/// threshold. A deliberate departure: Float lending's `is_valid_hf` evaluates
/// `collateral_value × 100 / loan_amount > 100`, admitting only
/// `collateral_value >= ceil(1.01 × debt_now)`.
pub fn is_healthy(collateral_value: Int, debt: Int) -> Bool {
  collateral_value >= debt
}

/// §11.2.6 — `reward` is bounded on both sides, in `long_token`.
/// `reward_floor <= cap` by construction, and `cap <= collateral_amount`, so
/// `seized >= 0`.
pub fn reward_bounds(
  collateral_amount: Int,
  liquidator_reward_cap: Basis,
  min_liquidator_reward: Int,
  p: PRational,
) -> (Int, Int) {
  let cap = collateral_amount * liquidator_reward_cap / constants.basis_point
  let reward_floor =
    math.min(
      daken_math.ceiling_div(min_liquidator_reward * p.denominator, p.numerator),
      cap,
    )
  (reward_floor, cap)
}

/// The debt expressed in `long_token` — the un-clamped term of §2.13's `min`,
/// and §11.2.7's test for whether the collateral covered the debt at all.
pub fn debt_in_long(debt: Int, p: PRational) -> Int {
  daken_math.ceiling_div(debt * p.denominator, p.numerator)
}

/// §2.13 — everything follows from the declared `reward`.
pub fn seized(
  debt: Int,
  p: PRational,
  collateral_amount: Int,
  reward: Int,
) -> Int {
  math.min(debt_in_long(debt, p), collateral_amount - reward)
}

/// §2.14 — what the pool actually receives from a liquidation.
pub fn repaid(seized: Int, p: PRational) -> Int {
  seized * p.numerator / p.denominator
}

/// §2.15 — debt the collateral could not cover. `seized` ceilings and `repaid`
/// floors, so `repaid > debt_now` is reachable and the clamp is load-bearing.
pub fn shortfall(debt: Int, repaid: Int) -> Int {
  math.max(0, debt - repaid)
}

/// §2.16 — the `long_token` a liquidation leaves behind, read off the remain
/// output. `collector_reward` is a structural charge on that UTxO, the same as
/// its minADA, and `net` strips only the minADA.
pub fn observed_remainder(
  remain_out_value: Value,
  long_token: TupleAsset,
  collector_reward: Int,
) -> Int {
  utils.net(remain_out_value, long_token) - if tokens.is_ada(long_token) {
    collector_reward
  } else {
    0
  }
}

/// §2.17 — the name a parked residual is keyed by, derived from the
/// `PositionNFT` of the position being ended. Never a name the caller chooses.
pub fn remain_owner_nft(
  position_skh: ScriptHash,
  position_nft_name: AssetName,
) -> TupleAsset {
  (position_skh, utils.suffixed(position_nft_name, constants.owner_nft_suffix))
}

// ------------------------------------------------------------- §5 rule 1 and 6

/// §5 rule 1 — both bounds `Finite`, `tx_start > 0`, and
/// `tx_end - tx_start <= max_validity_window`. An open bound is not admissible:
/// it would make every `expiry - tx_end` bound and every `tx_start >
/// claim.expiry` gate vacuous. A slot length of one millisecond makes `ttl` the
/// window itself.
pub fn valid_range(range: ValidityRange) -> (Int, Int) {
  expect OK((tx_start, tx_end)) =
    time.tx_validity_valid_with_boundaries(
      range,
      1,
      Some(constants.max_validity_window),
      True,
    )
  (tx_start, tx_end)
}

// ------------------------------------------------------- §5 rule 3 authenticity

/// `protocol_config` by `protocol_nft`, quantity 1. No address is required: the
/// NFT is minted once at a name distinct from the `AdminNFT` beside it, so
/// exactly one UTxO can carry it — §5 rule 3.
pub fn registry_at(
  reference_inputs: List<Input>,
  idx: Int,
  protocol_nft: TupleAsset,
) -> Registry {
  expect idx != -1
  let Input { output: Output { value, datum, .. }, .. } =
    utils.input_at(reference_inputs, idx)
  expect tokens.contains_nft(value, protocol_nft)
  expect InlineDatum(datum) = datum
  expect ProtocolDatum {
    pool_skh,
    loan_skh,
    config_pool_skh,
    order_skh,
    position_skh,
    oracle_skh,
    adapters,
    loan_repay_skh,
    loan_close_skh,
    ..
  }: ProtocolDatum = datum
  Registry {
    pool_skh,
    loan_skh,
    loan_repay_skh,
    loan_close_skh,
    config_pool_skh,
    order_skh,
    position_skh,
    oracle_skh,
    adapters,
  }
}

/// `market_param` by `MarketNFT` under `config_pool_skh` at
/// `Script(config_pool_skh)` — `PoolNFT` and `MarketNFT` are the same asset in
/// quantity 2, so the address is what separates the two UTxOs. Where a loan is
/// an input, `MarketNFT.asset_name == loan.LoanNFT.asset_name` — §5 rule 3.
pub fn market_at(
  reference_inputs: List<Input>,
  idx: Int,
  config_pool_skh: ScriptHash,
  market_nft_name: AssetName,
) -> MarketDatum {
  expect idx != -1
  let Input {
    output: Output {
      address: Address { payment_credential, .. },
      value,
      datum,
      ..
    },
    ..
  } = utils.input_at(reference_inputs, idx)
  expect payment_credential == Script(config_pool_skh)
  expect tokens.contains_nft(value, (config_pool_skh, market_nft_name))
  expect InlineDatum(datum) = datum
  expect market: MarketDatum = datum
  market
}

/// `pool` by `PoolNFT` at policy `config_pool_skh` with
/// `PoolNFT.asset_name == MarketNFT.asset_name`, quantity 1, at
/// `Script(pool_skh)` — §5 rule 3 — and fresh per §5 rule 6.
pub fn pool_ref_at(
  reference_inputs: List<Input>,
  idx: Int,
  pool_skh: ScriptHash,
  config_pool_skh: ScriptHash,
  market_nft_name: AssetName,
  max_index_staleness: Int,
  tx_start: Int,
) -> PoolDatum {
  expect idx != -1
  let Input {
    output: Output {
      address: Address { payment_credential, .. },
      value,
      datum,
      ..
    },
    ..
  } = utils.input_at(reference_inputs, idx)
  expect payment_credential == Script(pool_skh)
  expect tokens.contains_nft(value, (config_pool_skh, market_nft_name))
  expect InlineDatum(datum) = datum
  expect pool: PoolDatum = datum
  expect tx_start - pool.interest_time <= max_index_staleness
  pool
}

/// The oracle's price table for `to_token`, located by
/// `Withdraw(Script(oracle_skh))` — §5 rule 5.
pub fn prices_for(
  redeemers: Pairs<ScriptPurpose, Redeemer>,
  oracle_skh: ScriptHash,
  to_token: TupleAsset,
) -> Pairs<TupleAsset, PRational> {
  expect rdmr: OraclePriceRedeemer =
    daken_pairs.get_first(redeemers, Withdraw(Script(oracle_skh)))
  daken_pairs.get_first(rdmr.prices, to_token)
}

// ---------------------------------------------------------- loan-side readers

/// §8.2.1 — `loan_in` is at `Script(loan_skh)` and holds the `LoanNFT` with
/// `asset_name == MarketNFT.asset_name`, quantity 1, and **exactly one** token
/// of `loan_skh`. Returns the datum and the value.
pub fn read_loan(
  loan_in: Input,
  loan_skh: ScriptHash,
) -> (Address, Value, LoanDatum, AssetName) {
  let Input { output: Output { address, value, datum, .. }, .. } = loan_in
  expect utils.at_script(address, loan_skh)
  let loan_nft_name = tokens.get_nft_name(value, loan_skh)
  expect InlineDatum(datum) = datum
  expect loan: LoanDatum = datum
  (address, value, loan, loan_nft_name)
}

/// §11.2.1 / §10.1.1 — `position_in` is at `Script(position_skh)`, holds the
/// `PositionNFT` quantity 1 and the `LoanOwnerNFT` the loan datum names, and its
/// datum parses strictly as a `PositionDatum`.
pub fn read_position(
  position_in: Input,
  position_skh: ScriptHash,
  loan_owner_nft: TupleAsset,
) -> (Value, PositionDatum, AssetName) {
  let Input { output: Output { address, value, datum, .. }, .. } = position_in
  expect utils.at_script(address, position_skh)
  let position_nft_name = tokens.get_nft_name(value, position_skh)
  expect tokens.contains_nft(value, loan_owner_nft)
  expect InlineDatum(datum) = datum
  expect position: PositionDatum = datum
  (value, position, position_nft_name)
}

/// The venue payout or refund input: at `Script(loan_skh)`, **no datum**, and
/// carrying `binding_nft` — §8.2.4, §12.2.1, and §5 rule 17.
pub fn read_datum_free(
  input: Input,
  loan_skh: ScriptHash,
  binding_nft: TupleAsset,
) -> Value {
  let Input { output: Output { address, value, datum, .. }, .. } = input
  expect utils.at_script(address, loan_skh)
  expect datum == NoDatum
  expect tokens.contains_nft(value, binding_nft)
  value
}

/// The declaration for this loan, keyed by `loan_owner_nft_name` — §5 rule 11.
/// The declarations the adapter's own withdrawal carries — §5 rule 11: the core
/// reads the adapter's redeemer, never the reverse.
pub fn declarations_of(
  redeemers: Pairs<ScriptPurpose, Redeemer>,
  adapter_skh: ByteArray,
) -> List<Declaration> {
  if adapter_skh == #"" {
    []
  } else {
    expect AdapterRedeemer { declarations, .. }: AdapterRedeemer =
      daken_pairs.get_first(redeemers, Withdraw(Script(adapter_skh)))
    declarations
  }
}

pub fn route_for(
  declarations: List<Declaration>,
  loan_owner_nft_name: AssetName,
) -> CollateralRoute {
  expect Some(Declaration { route, .. }) =
    list.find(
      declarations,
      fn(Declaration { loan_owner_nft_name: name, .. }) {
        name == loan_owner_nft_name
      },
    )
  route
}

/// `adapter_skh` is present in `protocol_config.adapters` with the permission
/// the arm requires.
pub fn adapter_may(
  adapters: Pairs<ScriptHash, AdapterEntry>,
  adapter_skh: ScriptHash,
  create: Bool,
) -> Bool {
  let AdapterEntry { may_create, may_recover } =
    daken_pairs.get_first(adapters, adapter_skh)
  if create {
    may_create
  } else {
    may_recover
  }
}

/// §13.2 — the remain collateral UTxO a parking arm creates. `stake_credential`
/// is copied from the parking transaction's `position_in.address`.
pub fn remain_out_valid(
  remain_out: Output,
  loan_skh: ScriptHash,
  position_skh: ScriptHash,
  position_address: Address,
  remain_nft_name: AssetName,
  owner_nft: TupleAsset,
  beneficiary: Address,
  collector_reward: Int,
) -> Bool {
  let Output { address, value, datum, reference_script } = remain_out
  expect InlineDatum(datum) = datum
  expect remain: RemainDatum = datum
  and {
    utils.script_address_matches(
      address,
      loan_skh,
      position_address.stake_credential,
    )?,
    (reference_script == None)?,
    (utils.tokens_of(value, loan_skh) == [(remain_nft_name, 1)])?,
    (utils.tokens_of(value, position_skh) == [])?,
    (remain == RemainDatum { owner_nft, beneficiary, collector_reward })?,
    (assets.lovelace_of(value) >= constants.min_ada + collector_reward)?,
  }
}

/// §5 rule 9 — every non-lovelace asset of `from` other than those in `except`
/// reaches `to`, at no less than the quantity it arrived with.
pub fn carries_over(from: Value, to: Value, except: List<TupleAsset>) -> Bool {
  from
    |> assets.without_lovelace
    |> assets.reduce(
        True,
        fn(pid, name, qty, ok) {
          if list.has(except, (pid, name)) {
            ok
          } else {
            and {
              ok,
              assets.quantity_of(to, pid, name) >= qty,
            }
          }
        },
      )
}

/// True where `v` holds no token whose policy is `pid`.
pub fn holds_none_of(v: Value, pid: ByteArray) -> Bool {
  utils.tokens_of(v, pid) == []
}

/// The `ClaimDirection` the arm requires, and the leg the claim was selling —
/// `short_token` for `Opening`, `long_token` for `Closing`.
pub fn sold_leg(
  direction: ClaimDirection,
  short_token: TupleAsset,
  long_token: TupleAsset,
) -> TupleAsset {
  when direction is {
    Opening -> short_token
    Closing -> long_token
  }
}

// ------------------------------------------------------------------ §4 floors

/// §4.2 — the closing floor, an equality against its lower bounds. `market_floor`
/// is the adapter's, proved against the reserves at `route.venue_ref_idx`; the
/// core evaluates the whole `max` from it.
pub fn closing_floor(
  debt_at_expiry: Int,
  claim_safety_margin: Basis,
  market_floor: Int,
) -> Int {
  math.max(
    daken_math.ceiling_div(
      debt_at_expiry * ( constants.basis_point + claim_safety_margin ),
      constants.basis_point,
    ),
    market_floor,
  )
}

/// §4.1's `health_floor`. The ceilings are **nested**, not applied to one
/// product: the inner one converts the projected debt into `short_token` at the
/// threshold, the outer one converts that into `long_token` at `1/p`.
pub fn health_floor(
  debt_at_expiry: Int,
  claim_safety_margin: Basis,
  threshold: LiquidationThreshold,
  p: PRational,
) -> Int {
  let inner =
    daken_math.ceiling_div(
      constants.basis_point * debt_at_expiry * (
        constants.basis_point + claim_safety_margin
      ),
      threshold * constants.basis_point,
    )
  daken_math.ceiling_div(inner * p.denominator, p.numerator)
}

/// §4.1 — the opening floor. `limit_floor` is §7.3.2's **ceiling term alone**;
/// the `long_from_order_in` term of that item does not belong here, since §7.4.6
/// pins `net(loan_out_value, long_token)` separately.
pub fn opening_floor(
  health_floor: Int,
  market_floor: Int,
  limit_floor: Int,
) -> Int {
  math.max(health_floor, math.max(market_floor, limit_floor))
}

/// §4.1 and §4.2's shared side condition: `floor > market.venue_fee_budget`
/// where the paid leg is ADA, so §12.2 can tell a return from a fill.
pub fn floor_clears_venue_budget(
  floor: Int,
  paid_leg: TupleAsset,
  venue_fee_budget: Int,
) -> Bool {
  if tokens.is_ada(paid_leg) {
    floor > venue_fee_budget
  } else {
    True
  }
}

/// What one action contributes to the sums §7.2.18 and §10.3 take over every
/// action sharing `pool_out_idx` — §5 rule 10 and §5 rule 12. `retired` is the
/// arm-specific `R`: `debt_now` on §10.1, `debt_repaid` on §10.2.2 and §12.3,
/// `repaid` on §11.
pub type Contribution {
  loan_mint: List<(AssetName, Int)>,
  opened_proceeds: Int,
  retired: Int,
  shortfall: Int,
}

pub fn no_contribution() -> Contribution {
  Contribution { loan_mint: [], opened_proceeds: 0, retired: 0, shortfall: 0 }
}

// -------------------------------------------------------------------- tests

test debt_now_floors() {
  let tests =
    [
      // (loan_amount, interest_index, initial_index, expected)
      (
        100_000_000,
        constants.initial_interest_index,
        constants.initial_interest_index,
        100_000_000,
      ),
      (
        100_000_000,
        1_005_000_000_000,
        constants.initial_interest_index,
        100_500_000,
      ),
      // floors, never rounds: 3 × 1e12+1 / 1e12 == 3
      (
        3,
        constants.initial_interest_index + 1,
        constants.initial_interest_index,
        3,
      ),
    ]
  list.all(
    tests,
    fn((loan_amount, index, initial, expected)) {
      debt_now(loan_amount, index, initial) == expected
    },
  )
}

test debt_at_ceilings() {
  let tests =
    [
      // (debt, borrow_apy, interest_time, t, expected)
      (1_000_000, 400, 0, 0, 1_000_000),
      // 1_000_000 × 400 × year / (10_000 × year) == 40_000, exact
      (1_000_000, 400, 0, constants.year_in_ms, 1_040_000),
      // one millisecond of interest ceilings to one unit
      (1_000_000, 400, 0, 1, 1_000_001),
    ]
  list.all(
    tests,
    fn((debt, apy, interest_time, t, expected)) {
      debt_at(debt, apy, interest_time, t) == expected
    },
  )
}

test seized_repaid_shortfall() {
  let tests =
    [
      // (debt, p_num, p_den, collateral_amount, reward, seized, repaid, shortfall)
      // §2.15's own example: debt 100 at p = 3/1 gives seized 34, repaid 102
      (100, 3, 1, 1_000, 0, 34, 102, 0),
      // the collateral binds instead of the debt
      (100, 3, 1, 20, 5, 15, 45, 55),
      // exact cover, no shortfall
      (100, 1, 1, 200, 10, 100, 100, 0),
    ]
  list.all(
    tests,
    fn((debt, num, den, collateral, reward, exp_seized, exp_repaid, exp_short)) {
      let p = PRational { numerator: num, denominator: den }
      let s = seized(debt, p, collateral, reward)
      let r = repaid(s, p)
      and {
        s == exp_seized,
        r == exp_repaid,
        shortfall(debt, r) == exp_short,
      }
    },
  )
}

test reward_bounds_clamped() {
  let tests =
    [
      // (collateral, cap_bp, min_reward, p_num, p_den, floor, cap)
      // 1,000 × 1,000bp = 100; min 10 at p = 1/1 ceilings to 10
      (1_000, 1_000, 10, 1, 1, 10, 100),
      // the floor is clamped to the cap where the cap is the smaller
      (50, 1_000, 10, 1, 1, 5, 5),
      // p = 2/1 halves the reward floor expressed in long_token
      (1_000, 1_000, 10, 2, 1, 5, 100),
    ]
  list.all(
    tests,
    fn((collateral, cap_bp, min_reward, num, den, exp_floor, exp_cap)) {
      let p = PRational { numerator: num, denominator: den }
      reward_bounds(collateral, cap_bp, min_reward, p) == (exp_floor, exp_cap)
    },
  )
}

test health_gate_is_non_strict_with_no_buffer() {
  let tests =
    [
      // (collateral_value, debt, healthy)
      (100, 100, True), (99, 100, False), (101, 100, True),
    ]
  list.all(tests, fn((cv, debt, expected)) { is_healthy(cv, debt) == expected })
}

test weigh_floors_per_asset() {
  let tests =
    [
      // (qty, num, den, threshold, expected)
      (1_000, 1, 1, 8_000, 800),
      // floors: 1_001 × 1 × 8_000 / 10_000 == 800
      (1_001, 1, 1, 8_000, 800),
      // no haircut at basis_point
      (1_000, 1, 1, constants.basis_point, 1_000),
      (1_000, 3, 2, 9_000, 1_350),
    ]
  list.all(
    tests,
    fn((qty, num, den, threshold, expected)) {
      weigh(qty, PRational { numerator: num, denominator: den }, threshold) == expected
    },
  )
}

test observed_remainder_charges_the_collector_reward_on_ada_only() {
  let token = (#"beef", #"544f4b")
  let tests =
    [
      // (long_token, value, collector_reward, expected)
      (
        ada,
        assets.from_lovelace(constants.min_ada + 3_000_000 + 100),
        3_000_000,
        100,
      ),
      (
        token,
        assets.from_asset(#"beef", #"544f4b", 100)
          |> assets.merge(assets.from_lovelace(constants.min_ada + 3_000_000)),
        3_000_000,
        100,
      ),
    ]
  list.all(
    tests,
    fn((long_token, value, collector_reward, expected)) {
      observed_remainder(value, long_token, collector_reward) == expected
    },
  )
}

/// The market a loan belongs to, read from the loan's own NFT name: §7.2.12 makes
/// `LoanNFT.asset_name == MarketNFT.asset_name`, so the loan input carries it.
pub fn market_nft_name_of(
  inputs: List<Input>,
  loan_in_idx: Int,
  loan_skh: ScriptHash,
) -> AssetName {
  let (_addr, _value, _datum, loan_nft_name) =
    read_loan(flist.at(inputs, loan_in_idx), loan_skh)
  loan_nft_name
}

/// `pool_out_datum.interest_index` — what §7.2.20 pins a new loan's
/// `initial_interest_index` to, and what §2 item 9 recomputes `debt_now` from.
pub fn pool_out_index(outputs: List<Output>, pool_out_idx: Int) -> Int {
  expect InlineDatum(raw) = flist.at(outputs, pool_out_idx).datum
  expect PoolDatum { interest_index, .. }: PoolDatum = raw
  interest_index
}

/// The whole `PoolDatum` on the pool output, for the arms that need more than its
/// index — §7.4's floor reads `borrow_apy` and `interest_time` too.
pub fn pool_out_datum_at(outputs: List<Output>, pool_out_idx: Int) -> PoolDatum {
  expect InlineDatum(raw) = flist.at(outputs, pool_out_idx).datum
  expect pool: PoolDatum = raw
  pool
}
