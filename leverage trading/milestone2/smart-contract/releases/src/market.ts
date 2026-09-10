import { Constr, type Data, getAddressDetails } from "@lucid-evolution/lucid";

/// The market the deployer writes. Its twin is `t_preprod_market()` in
/// `lib/protocol/create_market.ak`, and the test beside it is what proves these
/// numbers clear every §1.3 bound — change one here, change it there.
///
/// ADA is lent; fUSDM is the one accepted collateral. `supply_token` is ADA, which
/// is the empty policy and the empty name, so §1.3's ADA clause applies:
/// `min_tx_amount * (basis_point - fillability_margin) >= venue_fee_budget * basis_point`.
export const MARKET = {
  collateral: {
    policyId: "834a15101873b4e1ddfaa830df46792913995d8738dcde34eda27905",
    assetName: "665553444d",
    liquidationThreshold: 8000n,
    enabled: true,
  },
  baseRate: 400n,
  powerBase: 10470n,
  utilCap: 8000n,
  withdrawalFee: 0n,
  loanFeeRate: 2000n,
  loanOriginationFeeRate: 100n,
  loanOriginationFeeMinAmount: 0n,
  minTxAmount: 100_000_000n,
  liquidatorRewardCap: 1000n,
  collectorReward: 3_000_000n,
  minLiquidatorReward: 10_000_000n,
  rollbackTip: 3_000_000n,
  executionTip: 3_000_000n,
  maxCancelFee: 2_000_000n,
  venueFeeBudget: 20_000_000n,
  maxSlippageCap: 300n,
  minClaimDuration: 600_000n,
  maxClaimDuration: 600_000n,
  maxIndexStaleness: 3_600_000n,
  claimSafetyMargin: 50n,
  fillabilityMargin: 50n,
} as const;

/// The leverage pair. fUSDM carries **six** decimals and fBTC **eight** — neither
/// has token-registry metadata on preprod, so the mint is the only authority: a
/// transfer of "10M USDM and 10 BTC" arrived as 1e13 and 1e9 units.
///
/// The difference matters because the aggregator quotes a **human-readable** rate.
/// Its fBTC/fUSDM numbers are 2_352_822_199_577_200 over 17_982_012_499, where the
/// denominator is the venue pool's fBTC reserve in units and the numerator is its
/// fUSDM reserve in units times 100 — exactly `10 ** (8 - 6)`. `oracle.ts` scales
/// that back to units before it reaches a redeemer, since every validator here
/// computes in units.
const FBTC = {
  policyId: "007c4fc75b7662fc735177aa714da9d1b06af5644df199fef39e5fc1",
  assetName: "66425443",
} as const;
const FUSDM = {
  policyId: MARKET.collateral.policyId,
  assetName: MARKET.collateral.assetName,
} as const;

/// The market whose `supply_token` is ADA, named for symmetry with the two below.
export const MARKET_ADA = {
  ...MARKET,
  supplyToken: { policyId: "", assetName: "" },
} as const;

/// **fUSDM is lent, fBTC is the collateral** — the market a trader borrows from to
/// go long fBTC.
///
/// Two of §1.3's bounds read differently once the supply token is not ADA. The
/// clause tying `min_tx_amount` to `venue_fee_budget` applies only where the supply
/// token **is** ADA, so the budget is free of it here. And `min_tx_amount` with
/// `min_liquidator_reward` are quantities of the supply token, so they are in
/// fUSDM's six decimals — while `collector_reward`, the two tips and
/// `max_cancel_fee` stay lovelace, being structural charges on a UTxO rather than
/// amounts of what is lent.
///
/// `min_liquidator_reward * basis_point <= min_tx_amount * liquidator_reward_cap`
/// holds with equality: 10 fUSDM against 100 fUSDM at a cap of 1_000.
export const MARKET_FUSDM = {
  ...MARKET,
  collateral: { ...FBTC, liquidationThreshold: 8000n, enabled: true },
  supplyToken: FUSDM,
  minTxAmount: 100_000_000n,        // 100 fUSDM
  minLiquidatorReward: 10_000_000n, //  10 fUSDM
} as const;

/// **fBTC is lent, fUSDM is the collateral** — the market a trader borrows from to
/// go short fBTC.
///
/// The same two quantities, now in fBTC's six decimals. A 0.01 fBTC floor on a loan
/// is about 1_280 fUSDM at the oracle's rate, and the liquidator's floor is a
/// hundredth of that, which the cap of 1_000 basis points admits exactly.
export const MARKET_FBTC = {
  ...MARKET,
  collateral: { ...FUSDM, liquidationThreshold: 8000n, enabled: true },
  supplyToken: FBTC,
  minTxAmount: 10_000n,             // 0.01 fBTC
  minLiquidatorReward: 1_000n,      // 0.001 fBTC
} as const;

export type MarketParams =
  | typeof MARKET_ADA
  | typeof MARKET_FUSDM
  | typeof MARKET_FBTC;

/// Aiken's `Bool`: `False` is constructor 0, `True` is constructor 1.
const bool = (b: boolean): Data => new Constr(b ? 1 : 0, []);

/// `Address` is `Constr(0, [Credential, Option<StakeCredential>])`, with
/// `VerificationKey` at 0 and `Script` at 1, `Inline` at 0, `Some` at 0.
export function addressData(bech32: string): Data {
  const d = getAddressDetails(bech32);
  const pc = d.paymentCredential;
  if (!pc) throw new Error(`no payment credential in ${bech32}`);
  const payment = new Constr(pc.type === "Script" ? 1 : 0, [pc.hash]);
  const sc = d.stakeCredential;
  const stake: Data = sc
    ? new Constr(0, [new Constr(0, [new Constr(sc.type === "Script" ? 1 : 0, [sc.hash])])])
    : new Constr(1, []);
  return new Constr(0, [payment, stake]);
}

/// `MarketDatum`, in the field order `lib/types.ak` declares. Datums decode
/// positionally, so the order is the wire format.
export function marketDatum(feeAddressBech32: string, m: MarketParams = MARKET_ADA): Data {
  const collaterals = new Map<Data, Data>([
    [
      [m.collateral.policyId, m.collateral.assetName],
      [m.collateral.liquidationThreshold, bool(m.collateral.enabled)],
    ],
  ]);
  return new Constr(0, [
    collaterals,
    m.baseRate,
    m.powerBase,
    m.utilCap,
    m.withdrawalFee,
    m.loanFeeRate,
    m.loanOriginationFeeRate,
    m.loanOriginationFeeMinAmount,
    addressData(feeAddressBech32),
    [m.supplyToken.policyId, m.supplyToken.assetName],
    new Map<Data, Data>(),                      // alt_supply_tokens: none
    m.minTxAmount,
    m.liquidatorRewardCap,
    m.collectorReward,
    m.minLiquidatorReward,
    m.rollbackTip,
    m.executionTip,
    m.maxCancelFee,
    m.venueFeeBudget,
    m.maxSlippageCap,
    m.minClaimDuration,
    m.maxClaimDuration,
    m.maxIndexStaleness,
    m.claimSafetyMargin,
    m.fillabilityMargin,
  ]);
}

/// `initial_interest_index` from `lib/constants.ak`.
export const INITIAL_INTEREST_INDEX = 1_000_000_000_000n;

/// `PoolDatum` at its opening state — biz spec §20.2.8. `alt_supply_tokens_rate`
/// is empty because `alt_supply_tokens` is.
export function poolDatum(txStartMs: bigint, m: MarketParams = MARKET_ADA): Data {
  return new Constr(0, [
    0n,                        // total_supply
    0n,                        // circulating_dtoken
    0n,                        // total_borrow
    m.baseRate,                // borrow_apy == base_rate
    0n,                        // undistributed_fee
    INITIAL_INTEREST_INDEX,    // interest_index
    txStartMs,                 // interest_time == tx_start
    [],                        // alt_supply_tokens_rate
    0n,                        // bad_debt
  ]);
}

/// The market every loan-lifecycle command runs against, chosen once per
/// invocation by `MARKET_KEY` (`ada`, `fusdm` or `fbtc`).
///
/// Thirteen methods read one market's parameters and one market's UTxO. Threading
/// the choice through each of them as an argument would put the same value in
/// thirteen signatures and every call site, so it is selected here and read as a
/// constant — the deployer drives one market per invocation either way.
/// Decimals per asset, `""` for ADA. Used only to scale the aggregator's
/// human-readable rate into the units a validator computes in; where the two
/// sides of a pair agree the scale is 1, which is why the ADA market never needed
/// it.
export const DECIMALS: Record<string, number> = {
  "": 6,
  [`${FUSDM.policyId}.${FUSDM.assetName}`]: 6,
  [`${FBTC.policyId}.${FBTC.assetName}`]: 8,
};

export type MarketKey = "ada" | "fusdm" | "fbtc";
export const MARKET_KEY: MarketKey = ((k) =>
  k === "fusdm" || k === "fbtc" ? k : "ada")(Bun.env["MARKET_KEY"]);

export const ACTIVE =
  MARKET_KEY === "fusdm" ? MARKET_FUSDM : MARKET_KEY === "fbtc" ? MARKET_FBTC : MARKET_ADA;

/// The key `--create-market` writes that market's record entry under.
export const ACTIVE_KEY =
  MARKET_KEY === "fusdm" ? "marketFusdm" : MARKET_KEY === "fbtc" ? "marketFbtc" : "market";

/// True where the supply token is not ADA, which changes where a margin lives:
/// in the order's token holding rather than in its lovelace.
export const SUPPLY_IS_TOKEN = ACTIVE.supplyToken.policyId !== "";

/// The order the deployer places — biz spec §6.
///
/// `is_market` is true and `fee_reserve` covers `async_fill_cost`
/// (`venue_fee_budget + execution_tip + 2 x min_ada`), so the same order can be
/// filled either synchronously or against Minswap. `open_limit_price` is quoted
/// the way the oracle quotes: units of `short_token` per unit of `long_token`.
export const ORDER = {
  shortAmount: 300_000_000n,
  margin: 150_000_000n,
  feeReserve: 33_000_000n,
  openLimitPriceNum: 4n,
  openLimitPriceDen: 1n,
  minLiquidationThreshold: 8000n,
  minExecutionAmount: 100_000_000n,
  maxSlippage: 300n,
  isMarket: true,
} as const;

/// `OrderDatum`, in the field order `lib/types.ak` declares.
export function orderDatum(
  beneficiaryBech32: string,
  marketNftName: string,
  allowedAdapters: string[],
  /// Units of `short_token` per unit of `long_token`. Above the oracle's own rate
  /// the fill is legal but the loan opens under-collateralised, which is how §11
  /// becomes reachable at all.
  limitPriceNum: bigint = ORDER.openLimitPriceNum,
  /// A **limit** order declares `is_market = false`. §6.2.2.13 then stops
  /// demanding `fee_reserve >= async_fill_cost` — but it still admits one, and a
  /// limit order that funds the reserve is exactly what the asynchronous fill now
  /// gates on rather than on this flag.
  isMarket: boolean = ORDER.isMarket,
): Data {
  return new Constr(0, [
    [ACTIVE.collateral.policyId, ACTIVE.collateral.assetName],    // long_token
    [ACTIVE.supplyToken.policyId, ACTIVE.supplyToken.assetName],  // short_token
    ORDER.shortAmount,
    new Constr(0, [limitPriceNum, ORDER.openLimitPriceDen]),
    new Constr(0, [0n, 1n]),                                      // take_profit_price
    ORDER.minLiquidationThreshold,
    ORDER.minExecutionAmount,
    ORDER.maxSlippage,
    allowedAdapters,
    new Constr(isMarket ? 1 : 0, []),
    marketNftName,
    addressData(beneficiaryBech32),
    ORDER.feeReserve,
  ]);
}
