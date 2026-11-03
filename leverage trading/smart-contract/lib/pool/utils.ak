//// The pool's arithmetic — biz spec §2 items 7, 8, 9, 21, 22, 23, 24 and 25 —
//// and the pool-output invariant of §7.2.18 that every arm spending the pool
//// shares.

use aiken/collection/list
use aiken/collection/pairs
use aiken/interval.{Finite, Interval, IntervalBound}
use aiken/math
use aiken/math/rational
use aiken/primitive/bytearray
use cardano/address.{Address, Script, VerificationKey}
use cardano/assets.{AssetName, PolicyId, Value}
use cardano/transaction.{
  InlineDatum, Input, NoDatum, Output, OutputReference, ValidityRange, Withdraw,
}
use constants
use daken/math as dmath
use daken/pairs as daken_pairs
use daken/prational.{PRational}
use daken/tokens
use daken/types.{Basis, Redeemers, TupleAsset} as daken_types
use types.{AdapterEntry, LoanDatum, MarketDatum, PoolDatum, ScriptHash}
use utils

// ----------------------------------------------------------------- oracle

/// `prices[to_token][from_token]`, keyed by `TupleAsset` — biz spec
/// §5 rule 5 and the oracle price spec's `OraclePriceInfo`.
pub type OraclePriceInfo =
  Pairs<TupleAsset, Pairs<TupleAsset, PRational>>

/// The oracle's redeemer, mirrored only so `prices` can be read out of it at the
/// right position. Every other field is **`Data`**, following the audited
/// `danogo-float-rate-lending` contract: two oracle versions are in service and
/// they disagree on those fields — V1 encodes the index lists as lists, V3 as
/// packed bytes — so naming a concrete type there binds this protocol to one
/// version for no gain, since none of them is read.
pub type OracleRedeemer {
  global_config_idx: Data,
  oracle_path_idxs: Data,
  oracle_idxs: Data,
  prices: OraclePriceInfo,
  borrow_rates: Data,
}

/// The `prices[short_token]` row of the oracle withdrawal — biz spec §5 rule 5.
/// The oracle's quote for everything priced against `short_token`, or nothing at
/// all where the transaction carries no oracle withdrawal.
///
/// A market with no `alt_supply_tokens` needs no price: the pool holds one asset
/// and its own supply token is the unit of account. Demanding the withdrawal
/// anyway made every such transaction unbuildable, and the off-chain builder
/// agrees — `DanoOracleHelper` emits `Constr 0 []` and no reference inputs when
/// there are no alt tokens. The audited float-lending contract returns an empty
/// quote in the same case, and that is what this follows.
pub fn prices_to(
  redeemers: Redeemers,
  oracle_skh: ByteArray,
  short_token: TupleAsset,
) -> Pairs<TupleAsset, PRational> {
  when pairs.get_first(redeemers, Withdraw(Script(oracle_skh))) is {
    None -> []
    Some(raw) -> {
      expect rdmr: OracleRedeemer = raw
      daken_pairs.get_first(rdmr.prices, short_token)
    }
  }
}

// ------------------------------------------------------------- arithmetic

/// §2 item 7
pub fn index_at(
  in_interest_index: Int,
  in_borrow_apy: Basis,
  in_interest_time: Int,
  t: Int,
) -> Int {
  if t > in_interest_time {
    in_interest_index + in_interest_index * in_borrow_apy * (
      t - in_interest_time
    ) / ( constants.basis_point * constants.year_in_ms )
  } else {
    in_interest_index
  }
}

/// §2 item 8
pub fn accrued(
  in_total_borrow: Int,
  in_interest_index: Int,
  out_interest_index: Int,
) -> Int {
  in_total_borrow * ( out_interest_index - in_interest_index ) / in_interest_index
}

/// §2 item 9
pub fn debt_now(
  loan_amount: Int,
  interest_index: Int,
  initial_interest_index: Int,
) -> Int {
  loan_amount * interest_index / initial_interest_index
}

/// §2 item 6
pub fn net_loan_proceeds(
  loan_amount: Int,
  loan_origination_fee_rate: Basis,
  loan_origination_fee_min_amount: Int,
) -> Int {
  loan_amount - math.max(
    dmath.ceiling_div(
      loan_origination_fee_rate * loan_amount,
      constants.basis_point,
    ),
    loan_origination_fee_min_amount,
  )
}

/// The protocol's share of this transaction's accrual — §7.2.18.
pub fn accrued_fee(accrued_amount: Int, loan_fee_rate: Basis) -> Int {
  dmath.ceiling_div(accrued_amount * loan_fee_rate, constants.basis_point)
}

/// §2 item 25
pub fn total_supply_before_tx(
  in_total_supply: Int,
  accrued_amount: Int,
  accrued_fee_amount: Int,
  alt_tokens_yield: Int,
) -> Int {
  in_total_supply + accrued_amount - accrued_fee_amount + alt_tokens_yield
}

/// `floor((power_base / basis_point) ^ round(util_rate × 100) × 100) + base_rate`,
/// `== base_rate` where the denominator is non-positive — §7.2.18.
pub fn borrow_apy(
  base_rate: Basis,
  power_base: Basis,
  total_supply: Int,
  total_borrow: Int,
) -> Basis {
  if total_supply > 0 {
    expect Some(util_rate) =
      rational.new(total_borrow * constants.percentage, total_supply)
    expect Some(base) = rational.new(power_base, constants.basis_point)
    expect Some(rate) = rational.pow(base, rational.round(util_rate))
    base_rate + rational.numerator(rate) * constants.percentage / rational.denominator(
      rate,
    )
  } else {
    base_rate
  }
}

// ------------------------------------------------- alternative-token pass

/// Everything the alternative-token keys contribute to one pool spend — §2
/// items 21, 22 and 24, plus the two direction flags §7.2.18 keys on the sign
/// of `pool_changed_amount`.
pub type PoolAssets {
  pool_total_asset: Int,
  pool_changed_amount: Int,
  alt_tokens_change: Int,
  alt_tokens_yield: Int,
  out_alt_rates: List<PRational>,
  all_alt_not_decrease: Bool,
  all_alt_not_increase: Bool,
}

/// Which way `alt_supply_tokens` keys may move on this arm.
pub type AltFlow {
  /// `pool_changed_amount >= 0` — every key may rise and none may fall.
  AltMayRise
  /// `pool_changed_amount < 0` — every key may fall and none may rise, bounded
  /// by `abs(alt_tokens_change) <= abs(pool_changed_amount)`.
  AltMayFall
  /// §17 alone, bounded by value instead.
  AltFree
  /// §19 item 6a — no key moves in either direction.
  AltFrozen
}

/// §7.2.18 — the flow direction is the sign of `pool_changed_amount`.
pub fn flow_of(pool_changed_amount: Int) -> AltFlow {
  if pool_changed_amount >= 0 {
    AltMayRise
  } else {
    AltMayFall
  }
}

fn zero_assets() -> PoolAssets {
  PoolAssets {
    pool_total_asset: 0,
    pool_changed_amount: 0,
    alt_tokens_change: 0,
    alt_tokens_yield: 0,
    out_alt_rates: [],
    all_alt_not_decrease: True,
    all_alt_not_increase: True,
  }
}

fn walk_alts(
  alts: Pairs<TupleAsset, Bool>,
  idx: Int,
  pool_in_value: Value,
  pool_out_value: Value,
  in_rates: List<PRational>,
  prices: Pairs<TupleAsset, PRational>,
) -> PoolAssets {
  when alts is {
    [] -> zero_assets()
    [Pair(alt, allow_supply), ..rest] -> {
      let acc =
        walk_alts(
          rest,
          idx + 1,
          pool_in_value,
          pool_out_value,
          in_rates,
          prices,
        )
      let (pid, name) = alt
      let in_qty = assets.quantity_of(pool_in_value, pid, name)
      let out_qty = assets.quantity_of(pool_out_value, pid, name)
      // §1.3 `alt_supply_tokens` and §7.2.18: a key with `allow_supply == False`
      // may fall but never rise.
      expect or {
          allow_supply,
          out_qty <= in_qty,
        }?
      // §2 item 21: `0/1` where the stored list is shorter than the market's.
      let stored =
        when list.at(in_rates, idx) is {
          Some(rate) -> rate
          None -> PRational { numerator: 0, denominator: 1 }
        }
      if or {
        in_qty > 0,
        out_qty > 0,
      } {
        let PRational { numerator: rate_num, denominator: rate_den } as rate =
          daken_pairs.get_first(prices, alt)
        PoolAssets {
          // §2 item 24
          pool_total_asset: acc.pool_total_asset + out_qty * rate_num / rate_den,
          pool_changed_amount: 0,
          // §2 item 22
          alt_tokens_change: acc.alt_tokens_change + ( out_qty - in_qty ) * rate_num / rate_den,
          // §2 item 21 — two floors, not one floor over the rate difference
          alt_tokens_yield: acc.alt_tokens_yield + if in_qty > 0 {
            in_qty * rate_num / rate_den - in_qty * stored.numerator / stored.denominator
          } else {
            0
          },
          out_alt_rates: [rate, ..acc.out_alt_rates],
          all_alt_not_decrease: acc.all_alt_not_decrease && out_qty >= in_qty,
          all_alt_not_increase: acc.all_alt_not_increase && out_qty <= in_qty,
        }
      } else {
        PoolAssets { ..acc, out_alt_rates: [stored, ..acc.out_alt_rates] }
      }
    }
  }
}

/// §2 items 21 to 24, over the market's `alt_supply_tokens` in list order.
pub fn pool_assets(
  pool_in_value: Value,
  pool_out_value: Value,
  short_token: TupleAsset,
  alt_supply_tokens: Pairs<TupleAsset, Bool>,
  in_rates: List<PRational>,
  prices: Pairs<TupleAsset, PRational>,
) -> PoolAssets {
  let (short_pid, short_name) = short_token
  let in_short = assets.quantity_of(pool_in_value, short_pid, short_name)
  let out_short = assets.quantity_of(pool_out_value, short_pid, short_name)
  let acc =
    walk_alts(
      alt_supply_tokens,
      0,
      pool_in_value,
      pool_out_value,
      in_rates,
      prices,
    )
  PoolAssets {
    ..acc,
    pool_total_asset: // §2 item 24 — the short-token quantity is raw, not `net`
    out_short + acc.pool_total_asset,
    pool_changed_amount: // §2 item 23 — raw quantities on both sides
    out_short - in_short + acc.alt_tokens_change,
  }
}

// ------------------------------------------------ shared pool-out checks

/// §7.2.18 — the positive whitelist. Nothing outside `short_token`, the
/// `PoolNFT`, the `alt_supply_tokens` keys and lovelace.
fn holds_only_pool_assets(
  pool_out_value: Value,
  pool_nft: TupleAsset,
  short_token: TupleAsset,
  alt_supply_tokens: Pairs<TupleAsset, Bool>,
) -> Bool {
  pool_out_value
    |> assets.flatten
    |> list.all(
        fn((pid, name, _q)) {
          let a = (pid, name)
          or {
            a == pool_nft,
            a == short_token,
            tokens.is_ada(a),
            pairs.has_key(alt_supply_tokens, a),
          }
        },
      )
}

/// §7.2.18 — for every asset that is neither `short_token` nor an
/// `alt_supply_tokens` key, lovelace included, `pool_out_value[a] >=
/// pool_in_value[a]`. The whitelist above leaves lovelace and the `PoolNFT` as
/// the whole of that class, and the `PoolNFT` is pinned at one on both sides.
fn residual_not_falling(
  pool_in_value: Value,
  pool_out_value: Value,
  short_token: TupleAsset,
  alt_supply_tokens: Pairs<TupleAsset, Bool>,
) -> Bool {
  let ada = (assets.ada_policy_id, assets.ada_asset_name)
  if or {
    ada == short_token,
    pairs.has_key(alt_supply_tokens, ada),
  } {
    True
  } else {
    assets.lovelace_of(pool_out_value) >= assets.lovelace_of(pool_in_value)
  }
}

fn alt_flow_holds(flow: AltFlow, pa: PoolAssets) -> Bool {
  when flow is {
    AltMayRise -> pa.all_alt_not_decrease?
    AltMayFall -> and {
        pa.all_alt_not_increase?,
        (math.abs(pa.alt_tokens_change) <= math.abs(pa.pool_changed_amount))?,
      }
    AltFree -> True
    AltFrozen -> and {
        pa.all_alt_not_decrease?,
        pa.all_alt_not_increase?,
      }
  }
}

/// Every invariant §7.2.18 states on a pool output. `expected` is the datum the
/// arm derived; the arm owns the fields it moves and this owns the rest.
pub fn check_pool_out(
  pool_in_addr: Address,
  pool_in_value: Value,
  Output {
    address: pool_out_addr,
    value: pool_out_value,
    datum: pool_out_datum,
    reference_script: pool_out_ref_script,
  }: Output,
  config_pool_skh: PolicyId,
  market_nft_name: AssetName,
  short_token: TupleAsset,
  alt_supply_tokens: Pairs<TupleAsset, Bool>,
  pa: PoolAssets,
  flow: AltFlow,
  expected: PoolDatum,
) -> Bool {
  and {
    (pool_out_addr == pool_in_addr)?,
    (pool_out_ref_script == None)?,
    (pool_out_datum == InlineDatum(expected))?,
    (utils.tokens_of(pool_out_value, config_pool_skh) == [(market_nft_name, 1)])?,
    holds_only_pool_assets(
      pool_out_value,
      (config_pool_skh, market_nft_name),
      short_token,
      alt_supply_tokens,
    )?,
    residual_not_falling(
      pool_in_value,
      pool_out_value,
      short_token,
      alt_supply_tokens,
    )?,
    alt_flow_holds(flow, pa),
    // the solvency invariant
    (pa.pool_total_asset >= expected.total_supply + expected.undistributed_fee - expected.total_borrow)?,
  }
}

// -------------------------------------------------------- reading the tx

/// §5 rule 1
pub fn tx_start_of(validity_range: ValidityRange) -> Int {
  expect Interval {
    lower_bound: IntervalBound { bound_type: Finite(tx_start), .. },
    upper_bound: IntervalBound { bound_type: Finite(tx_end), .. },
  } = validity_range
  expect (tx_start > 0)?
  expect (tx_end - tx_start <= constants.max_validity_window)?
  tx_start
}

/// §5 rule 3 — `market_param` by its `MarketNFT` at `Script(config_pool_skh)`.
pub fn market_ref(
  reference_inputs: List<Input>,
  market_ref_idx: Int,
  config_pool_skh: PolicyId,
) -> (AssetName, MarketDatum) {
  expect (market_ref_idx != -1)?
  let Input { output: Output { address, value, datum, .. }, .. } =
    utils.input_at(reference_inputs, market_ref_idx)
  expect utils.at_script(address, config_pool_skh)?
  let market_nft_name = tokens.get_nft_name(value, config_pool_skh)
  expect InlineDatum(raw) = datum
  expect market: MarketDatum = raw
  (market_nft_name, market)
}

/// §5 rule 3 — the pool by its `PoolNFT` at `Script(pool_skh)`, the NFT being
/// the same asset as the `MarketNFT` so the address is what separates them.
pub fn pool_input(
  inputs: List<Input>,
  pool_in_idx: Int,
  pool_skh: PolicyId,
  config_pool_skh: PolicyId,
  market_nft_name: AssetName,
) -> (Address, Value, PoolDatum) {
  let Input { output: Output { address, value, datum, .. }, .. } =
    utils.input_at(inputs, pool_in_idx)
  expect utils.at_script(address, pool_skh)?
  expect (assets.quantity_of(value, config_pool_skh, market_nft_name) == 1)?
  expect InlineDatum(raw) = datum
  expect pool: PoolDatum = raw
  (address, value, pool)
}

/// The loan UTxO keyed by its `LoanOwnerNFT` name — biz spec §5 rule 11's key
/// convention — among the UTxOs at `Script(loan_skh)` that carry the `LoanNFT`.
/// The venue payout and refund UTxOs sit at the same script and carry no
/// `LoanNFT`, which is what keeps them out of this scan.
pub fn loan_by_owner_nft(
  utxos: List<Output>,
  loan_skh: PolicyId,
  market_nft_name: AssetName,
  owner_nft_name: AssetName,
) -> LoanDatum {
  expect [loan] =
    utxos
      |> list.filter_map(
          fn(Output { address, value, datum, .. }) {
            if and {
              utils.at_script(address, loan_skh),
              assets.quantity_of(value, loan_skh, market_nft_name) == 1,
            } {
              expect InlineDatum(raw) = datum
              expect loan: LoanDatum = raw
              if loan.owner_nft == Some((loan_skh, owner_nft_name)) {
                Some(loan)
              } else {
                None
              }
            } else {
              None
            }
          },
        )
  loan
}

/// True where no input sits at any of `skhs` — biz spec §17 item 13, §18 item 9
/// and §19 item 9.
pub fn no_utxo_at(utxos: List<Output>, skhs: List<PolicyId>) -> Bool {
  utxos
    |> list.all(
        fn(Output { address: Address { payment_credential, .. }, .. }) {
          !list.any(skhs, fn(skh) { payment_credential == Script(skh) })
        },
      )
}

/// §17 item 13, §18 item 9, §19 item 9 — no adapter withdrawal is present.
pub fn no_adapter_withdrawal(
  redeemers: Redeemers,
  adapters: Pairs<ScriptHash, AdapterEntry>,
) -> Bool {
  pairs.keys(adapters)
    |> list.all(fn(skh) { !pairs.has_key(redeemers, Withdraw(Script(skh))) })
}

/// The output an arm pays a fee to — §18 item 8 and §19 item 7. `NoDatum`,
/// pinned to `market.fee_address`, no reference script.
pub fn fee_output_value(
  outputs: List<Output>,
  fee_out_idx: Int,
  fee_address: Address,
) -> Value {
  let Output { address, value, datum, reference_script } =
    utils.output_at(outputs, fee_out_idx)
  expect (address == fee_address)?
  expect (datum == NoDatum)?
  expect (reference_script == None)?
  value
}

/// §17 item 2 and §19 item 2 — the input at `admin_in_idx` holds the registry's
/// `admin_nft`, quantity 1. Presence of the NFT is the whole authorisation; no
/// signature is required.
pub fn admin_input(
  inputs: List<Input>,
  admin_in_idx: Int,
  pool_in_idx: Int,
  admin_nft: TupleAsset,
) -> Bool {
  expect (admin_in_idx != pool_in_idx)?
  let Input { output: Output { value, .. }, .. } =
    utils.input_at(inputs, admin_in_idx)
  tokens.contains_nft(value, admin_nft)?
}

/// §5 rule 10 — an arm that states no contribution to a policy contributes zero
/// to it, and the total is checked against that zero.
pub fn no_mint_of(mint: Value, pids: List<PolicyId>) -> Bool {
  pids |> list.all(fn(pid) { utils.tokens_of(mint, pid) == [] })
}

/// §17 item 12a, §18 item 11, §19 item 11.
pub fn pool_out_holds_min_ada(pool_out_value: Value) -> Bool {
  (assets.lovelace_of(pool_out_value) >= constants.min_ada)?
}

// ------------------------------------------------------- test fixtures
//
// The four arm modules share these. `lib/fixture/` belongs to no arm, so the
// fixture sits beside the arithmetic it exercises. Nothing here is reachable
// from a validator.

pub const t_pool_skh = "pool_skh"

pub const t_config_pool_skh = "config_pool_skh"

pub const t_loan_skh = "loan_skh"

pub const t_order_skh = "order_skh"

pub const t_position_skh = "position_skh"

pub const t_oracle_skh = "oracle_skh"

pub const t_market_nft_name = "usdm_market"

pub const t_admin_nft = ("protocol_skh", "adminADM")

pub const t_usdm = ("usdm_pid", "usdm")

pub const t_alt = ("alt_pid", "alt")

pub const t_junk = ("junk_pid", "junk")

pub const t_tx_start = 1700000000000

pub const t_pool_address =
  Address { payment_credential: Script(t_pool_skh), stake_credential: None }

pub const t_fee_address =
  Address { payment_credential: Script("fee_skh"), stake_credential: None }

pub fn t_market(
  withdrawal_fee: Int,
  util_cap: Basis,
  alt_allow_supply: Bool,
) -> MarketDatum {
  MarketDatum {
    collaterals: [],
    base_rate: 400,
    power_base: 10470,
    util_cap,
    withdrawal_fee,
    loan_fee_rate: 2000,
    loan_origination_fee_rate: 0,
    loan_origination_fee_min_amount: 0,
    fee_address: t_fee_address,
    supply_token: t_usdm,
    alt_supply_tokens: [Pair(t_alt, alt_allow_supply)],
    min_tx_amount: 100,
    liquidator_reward_cap: 1000,
    collector_reward: 3000000,
    min_liquidator_reward: 10,
    rollback_tip: 3000000,
    execution_tip: 3000000,
    max_cancel_fee: 2000000,
    venue_fee_budget: 13000000,
    max_slippage_cap: 300,
    min_claim_duration: 600000,
    max_claim_duration: 600000,
    max_index_staleness: 3600000,
    claim_safety_margin: 50,
    fillability_margin: 50,
  }
}

pub fn t_market_ref(market: MarketDatum) -> Input {
  Input {
    output_reference: OutputReference("market", 0),
    output: Output {
      address: Address {
        payment_credential: Script(t_config_pool_skh),
        stake_credential: None,
      },
      value: assets.from_asset(t_config_pool_skh, t_market_nft_name, 1),
      datum: InlineDatum(market),
      reference_script: None,
    },
  }
}

pub fn t_pool_datum(
  total_supply: Int,
  circulating_dtoken: Int,
  total_borrow: Int,
  undistributed_fee: Int,
  bad_debt: Int,
  alt_rates: List<PRational>,
) -> PoolDatum {
  PoolDatum {
    total_supply,
    circulating_dtoken,
    total_borrow,
    borrow_apy: 500,
    undistributed_fee,
    interest_index: constants.initial_interest_index,
    // `interest_time == tx_start` keeps `accrued` at zero, so a test asserts the
    // arm's own equations and not the accrual.
    interest_time: t_tx_start,
    alt_supply_tokens_rate: alt_rates,
    bad_debt,
  }
}

pub fn t_pool_value(lovelace: Int, usdm: Int, alt: Int, junk: Int) -> Value {
  assets.from_lovelace(lovelace)
    |> assets.add(t_config_pool_skh, t_market_nft_name, 1)
    |> assets.add(t_usdm.1st, t_usdm.2nd, usdm)
    |> assets.add(t_alt.1st, t_alt.2nd, alt)
    |> assets.add(t_junk.1st, t_junk.2nd, junk)
}

pub fn t_pool_in(value: Value, datum: PoolDatum) -> Input {
  Input {
    output_reference: OutputReference("pool", 0),
    output: Output {
      address: t_pool_address,
      value,
      datum: InlineDatum(datum),
      reference_script: None,
    },
  }
}

pub fn t_pool_out(value: Value, datum: PoolDatum) -> Output {
  Output {
    address: t_pool_address,
    value,
    datum: InlineDatum(datum),
    reference_script: None,
  }
}

pub fn t_admin_in() -> Input {
  Input {
    output_reference: OutputReference("admin", 0),
    output: Output {
      address: Address {
        payment_credential: VerificationKey("admin_vk"),
        stake_credential: None,
      },
      value: assets.from_lovelace(2000000)
        |> assets.add(t_admin_nft.1st, t_admin_nft.2nd, 1),
      datum: NoDatum,
      reference_script: None,
    },
  }
}

/// An output constrained by value alone — biz spec §5 rule 17.
pub fn t_plain_out(address: Address, value: Value) -> Output {
  Output { address, value, datum: NoDatum, reference_script: None }
}

pub fn t_plain_in(tag: ByteArray, address: Address, value: Value) -> Input {
  Input {
    output_reference: OutputReference(tag, 0),
    output: t_plain_out(address, value),
  }
}

pub fn t_wallet_address() -> Address {
  Address {
    payment_credential: VerificationKey("wallet_vk"),
    stake_credential: None,
  }
}

pub fn t_range() -> ValidityRange {
  interval.between(t_tx_start, t_tx_start + 1000)
}

/// The oracle withdrawal of §5 rule 5, quoting the mandatory
/// `short_token → short_token` self-pair and `alt` at 3/2.
pub fn t_oracle_redeemers() -> Redeemers {
  t_withdraw_redeemers(
    t_oracle_skh,
    OracleRedeemer {
      global_config_idx: 0,
      oracle_path_idxs: "",
      oracle_idxs: "",
      prices: [
        Pair(
          t_usdm,
          [
            Pair(t_usdm, PRational { numerator: 1, denominator: 1 }),
            Pair(t_alt, PRational { numerator: 3, denominator: 2 }),
          ],
        ),
      ],
      borrow_rates: [],
    },
  )
}

pub fn t_withdraw_redeemers(skh: ByteArray, rdmr: Data) -> Redeemers {
  [Pair(Withdraw(Script(skh)), rdmr)]
}

// ------------------------------------------------------------------ tests

type ArithCase {
  name: ByteArray,
  in_index: Int,
  apy: Basis,
  in_time: Int,
  at: Int,
  want_index: Int,
  total_borrow: Int,
  want_accrued: Int,
}

test arithmetic_cases() {
  // §2 items 7 and 8, including the backwards-dating guard.
  let cases =
    [
      ArithCase {
        name: "one year at 400bp",
        in_index: constants.initial_interest_index,
        apy: 400,
        in_time: 0,
        at: constants.year_in_ms,
        want_index: 1040000000000,
        total_borrow: 1000000,
        want_accrued: 40000,
      },
      ArithCase {
        name: "tx_start at interest_time does not move the index",
        in_index: constants.initial_interest_index,
        apy: 400,
        in_time: 1000,
        at: 1000,
        want_index: constants.initial_interest_index,
        total_borrow: 1000000,
        want_accrued: 0,
      },
      ArithCase {
        name: "tx_start before interest_time never winds the index down",
        in_index: constants.initial_interest_index,
        apy: 400,
        in_time: 5000,
        at: 1000,
        want_index: constants.initial_interest_index,
        total_borrow: 1000000,
        want_accrued: 0,
      },
      ArithCase {
        name: "accrual floors to zero on a short tick",
        in_index: constants.initial_interest_index,
        apy: 796,
        in_time: 0,
        at: 1981,
        want_index: 1000000005000,
        total_borrow: 100000000,
        want_accrued: 0,
      },
    ]
  list.all(
    cases,
    fn(c) {
      let out_index = index_at(c.in_index, c.apy, c.in_time, c.at)
      and {
        (out_index == c.want_index)?,
        (accrued(c.total_borrow, c.in_index, out_index) == c.want_accrued)?,
      }
    },
  )
}

type DebtCase {
  loan_amount: Int,
  index: Int,
  initial_index: Int,
  want: Int,
}

test debt_now_cases() {
  // §2 item 9 — floors, as Float lending and `take_profit` both compute it.
  let cases =
    [
      DebtCase {
        loan_amount: 100000000,
        index: constants.initial_interest_index,
        initial_index: constants.initial_interest_index,
        want: 100000000,
      },
      DebtCase {
        loan_amount: 100000000,
        index: 1000000005000,
        initial_index: constants.initial_interest_index,
        want: 100000000,
      },
      DebtCase {
        loan_amount: 100000000,
        index: 1000000010000,
        initial_index: constants.initial_interest_index,
        want: 100000001,
      },
      DebtCase { loan_amount: 3, index: 2, initial_index: 3, want: 2 },
    ]
  list.all(
    cases,
    fn(c) { debt_now(c.loan_amount, c.index, c.initial_index) == c.want },
  )
}

type FeeCase {
  loan_amount: Int,
  rate: Basis,
  min_amount: Int,
  want_proceeds: Int,
  accrued_amount: Int,
  loan_fee_rate: Basis,
  want_fee: Int,
}

test fee_cases() {
  // §2 item 6 ceilings the origination fee; §7.2.18 ceilings the protocol share.
  let cases =
    [
      FeeCase {
        loan_amount: 100000000,
        rate: 0,
        min_amount: 0,
        want_proceeds: 100000000,
        accrued_amount: 0,
        loan_fee_rate: 2000,
        want_fee: 0,
      },
      FeeCase {
        loan_amount: 1001,
        rate: 1000,
        min_amount: 0,
        want_proceeds: 900,
        accrued_amount: 1,
        loan_fee_rate: 2000,
        want_fee: 1,
      },
      FeeCase {
        loan_amount: 1000,
        rate: 100,
        min_amount: 500,
        want_proceeds: 500,
        accrued_amount: 10001,
        loan_fee_rate: 2000,
        want_fee: 2001,
      },
    ]
  list.all(
    cases,
    fn(c) {
      and {
        (net_loan_proceeds(c.loan_amount, c.rate, c.min_amount) == c.want_proceeds)?,
        (accrued_fee(c.accrued_amount, c.loan_fee_rate) == c.want_fee)?,
      }
    },
  )
}

type ApyCase {
  total_supply: Int,
  total_borrow: Int,
  want: Basis,
}

test borrow_apy_cases() {
  // `base_rate` 400, `power_base` 10470.
  let cases =
    [
      ApyCase { total_supply: 0, total_borrow: 0, want: 400 },
      ApyCase { total_supply: -5, total_borrow: 100, want: 400 },
      ApyCase { total_supply: 1000, total_borrow: 0, want: 500 },
      ApyCase { total_supply: 1000, total_borrow: 500, want: 1393 },
    ]
  list.all(
    cases,
    fn(c) { borrow_apy(400, 10470, c.total_supply, c.total_borrow) == c.want },
  )
}

const alt_a = ("alt_a_pid", "alt_a")

const alt_b = ("alt_b_pid", "alt_b")

const usdm = ("usdm_pid", "usdm")

fn rate(num: Int, den: Int) -> PRational {
  PRational { numerator: num, denominator: den }
}

type AssetsCase {
  name: ByteArray,
  in_alt_a: Int,
  out_alt_a: Int,
  in_short: Int,
  out_short: Int,
  in_rates: List<PRational>,
  want_total_asset: Int,
  want_changed: Int,
  want_alt_change: Int,
  want_yield: Int,
  want_out_rates: List<PRational>,
}

test pool_assets_cases() {
  // §2 items 21 to 24. `alt_a` is quoted at 3/2, `alt_b` at 5/1 and is never held.
  let prices =
    [Pair(alt_a, rate(3, 2)), Pair(alt_b, rate(5, 1)), Pair(usdm, rate(1, 1))]
  let alts = [Pair(alt_a, True), Pair(alt_b, True)]
  let cases =
    [
      AssetsCase {
        name: "a key held on neither side needs no quote and carries its stored rate forward",
        in_alt_a: 0,
        out_alt_a: 0,
        in_short: 1000,
        out_short: 1500,
        in_rates: [rate(1, 4), rate(7, 8)],
        want_total_asset: 1500,
        want_changed: 500,
        want_alt_change: 0,
        want_yield: 0,
        want_out_rates: [rate(1, 4), rate(7, 8)],
      },
      AssetsCase {
        name: "appreciation of a holding the pool already had, two floors",
        in_alt_a: 101,
        out_alt_a: 101,
        in_short: 1000,
        out_short: 1000,
        in_rates: [rate(1, 3), rate(7, 8)],
        want_total_asset: 1151,
        want_changed: 0,
        want_alt_change: 0,
        // floor(101 × 3/2) − floor(101 × 1/3) = 151 − 33
        want_yield: 118,
        want_out_rates: [rate(3, 2), rate(7, 8)],
      },
      AssetsCase {
        name: "a holding that falls floors toward negative infinity",
        in_alt_a: 101,
        out_alt_a: 100,
        in_short: 1000,
        out_short: 1002,
        in_rates: [rate(3, 2)],
        want_total_asset: 1152,
        // floor(-1 × 3/2) = -2
        want_changed: 0,
        want_alt_change: -2,
        want_yield: 0,
        // the stored list is shorter than the market's, so `alt_b` reads 0/1
        want_out_rates: [rate(3, 2), rate(0, 1)],
      },
    ]
  list.all(
    cases,
    fn(c) {
      let pool_in_value =
        assets.from_asset(alt_a.1st, alt_a.2nd, c.in_alt_a)
          |> assets.merge(assets.from_asset(usdm.1st, usdm.2nd, c.in_short))
      let pool_out_value =
        assets.from_asset(alt_a.1st, alt_a.2nd, c.out_alt_a)
          |> assets.merge(assets.from_asset(usdm.1st, usdm.2nd, c.out_short))
      let pa =
        pool_assets(
          pool_in_value,
          pool_out_value,
          usdm,
          alts,
          c.in_rates,
          prices,
        )
      and {
        (pa.pool_total_asset == c.want_total_asset)?,
        (pa.pool_changed_amount == c.want_changed)?,
        (pa.alt_tokens_change == c.want_alt_change)?,
        (pa.alt_tokens_yield == c.want_yield)?,
        (pa.out_alt_rates == c.want_out_rates)?,
      }
    },
  )
}

type FlowCase {
  in_alt: Int,
  out_alt: Int,
  changed: Int,
  flow: AltFlow,
  want: Bool,
}

test alt_flow_cases() {
  // §7.2.18's flow-directed rule and §19 item 6a's frozen form.
  let cases =
    [
      FlowCase {
        in_alt: 10,
        out_alt: 10,
        changed: 0,
        flow: AltMayRise,
        want: True,
      },
      FlowCase {
        in_alt: 10,
        out_alt: 11,
        changed: 1,
        flow: AltMayRise,
        want: True,
      },
      FlowCase {
        in_alt: 10,
        out_alt: 9,
        changed: 1,
        flow: AltMayRise,
        want: False,
      },
      FlowCase {
        in_alt: 10,
        out_alt: 9,
        changed: -1,
        flow: AltMayFall,
        want: True,
      },
      FlowCase {
        in_alt: 10,
        out_alt: 11,
        changed: -1,
        flow: AltMayFall,
        want: False,
      },
      FlowCase {
        in_alt: 10,
        out_alt: 9,
        changed: 0,
        flow: AltMayFall,
        want: False,
      },
      FlowCase {
        in_alt: 10,
        out_alt: 9,
        changed: -1,
        flow: AltFree,
        want: True,
      },
      FlowCase {
        in_alt: 10,
        out_alt: 10,
        changed: 0,
        flow: AltFrozen,
        want: True,
      },
      FlowCase {
        in_alt: 10,
        out_alt: 11,
        changed: 1,
        flow: AltFrozen,
        want: False,
      },
    ]
  list.all(
    cases,
    fn(c) {
      let pa =
        PoolAssets {
          ..zero_assets(),
          pool_changed_amount: c.changed,
          alt_tokens_change: c.out_alt - c.in_alt,
          all_alt_not_decrease: c.out_alt >= c.in_alt,
          all_alt_not_increase: c.out_alt <= c.in_alt,
        }
      alt_flow_holds(c.flow, pa) == c.want
    },
  )
}

type WhitelistCase {
  name: ByteArray,
  value: Value,
  want: Bool,
}

test whitelist_cases() {
  // §7.2.18's positive whitelist on every pool output.
  let pool_nft = ("config_pool_skh", "usdm_market")
  let alts = [Pair(alt_a, True)]
  let base =
    assets.from_lovelace(5000000)
      |> assets.merge(assets.from_asset(pool_nft.1st, pool_nft.2nd, 1))
      |> assets.merge(assets.from_asset(usdm.1st, usdm.2nd, 1000))
  let cases =
    [
      WhitelistCase {
        name: "short token, pool nft, lovelace",
        value: base,
        want: True,
      },
      WhitelistCase {
        name: "an alt key the market permits",
        value: base |> assets.merge(assets.from_asset(alt_a.1st, alt_a.2nd, 5)),
        want: True,
      },
      WhitelistCase {
        name: "one unit of a worthless token no arm may then remove",
        value: base |> assets.merge(assets.from_asset(alt_b.1st, alt_b.2nd, 1)),
        want: False,
      },
    ]
  list.all(
    cases,
    fn(c) { holds_only_pool_assets(c.value, pool_nft, usdm, alts) == c.want },
  )
}
