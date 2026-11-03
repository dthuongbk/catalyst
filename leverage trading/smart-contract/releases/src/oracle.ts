import { Constr, Data, type UTxO } from "@lucid-evolution/lucid";
import { NETWORK } from "./env.ts";
import { resolve } from "./resolve.ts";
import { DECIMALS } from "./market.ts";
import { oracleSkhFor } from "./venues.ts";

/// `ONCHAIN_PRICE_AGGREGATOR_URL` for preprod, from the monorepo's `.env.preprod`.
const AGGREGATOR = "https://nio-onchain-price-preprod.dev.tekoapis.net";

/// The oracle's own reference script. It is not something the aggregator returns,
/// and the redeemer's `ORACLE_SCRIPT` entry is a sentinel rather than a source.
const ORACLE_SCRIPT_REF: [string, number] = [
  "ac0868ede8fead21c58ad7901119db2606189ff5b484fb189f9ac3c9afccd5b8",
  0,
];

/// `OracleUTxOType`, the ordinal the validator expects. Only real sources are
/// encoded; the three sentinels mark a structural role and are filtered out.
const SOURCE_TYPE: Record<string, number | null> = {
  ORCFAX_FSP: 0, ORCFAX_FS: 1, LIQWID_MARKET_STATE: 2, LIQWID_MARKET_PARAM: 3,
  LIQWID_ORACLE_V2: 4, DANOGO_FLOAT_POOL: 5, INDIGO_ORACLE: 6, DJED_ORACLE: 7,
  DANOGO_STAKING_ORACLE: 8, MINSWAP_LP: 9, LIQWID_ORACLE_V1: 10,
  SPLASH_LP_CFMM_G1: 11, SPLASH_LP_CFMM_G2: 12, SPLASH_LP_CFMM_G3: 13,
  SPLASH_LP_STABLE: 14, CHARLI3_ORACLE: 15, MINSWAP_LP_STABLE: 16,
  CONCENTRATED_LP: 17,
  ORACLE_SCRIPT: null, ORACLE_CONFIG: null, ORACLE_SOURCE_PATH: null,
};

export type Quote = {
  /// `"policyId.assetNameHex"`, or `""` for ADA.
  asset: string;
  numerator: bigint;
  denominator: bigint;
};

type Typed = { type: string; utxo: UTxO };

/// One quote from the aggregator, with the reference inputs that prove it.
///
/// `quoteToken` is the market's `supply_token` — the unit every rate is expressed
/// in — and `baseToken` is the asset being priced.
async function askAggregator(baseToken: string, quoteToken: string) {
  const body = JSON.stringify({
    tokenPairs: [{ baseToken, quoteToken, oracleScriptHash: oracleSkhFor(NETWORK) }],
  });
  const r = await fetch(`${AGGREGATOR}/api/v1/prices`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body,
  });
  if (!r.ok) throw new Error(`aggregator ${r.status}`);
  const j = (await r.json()) as any;
  const info = j?.data?.priceInfos?.[0];
  if (!info) throw new Error(`the aggregator has no price for ${baseToken || "ADA"}`);
  return info as {
    exchangeRateNum: string;
    exchangeRateDen: string;
    referenceInputs: { outRef: string; type: string }[];
  };
}

const tuple = (asset: string): Data =>
  asset === "" ? ["", ""] : [asset.slice(0, 56), asset.slice(57)];

/// The oracle withdrawal for one market: the reference inputs it needs and the
/// redeemer that proves every rate.
///
/// The redeemer is the Oracle **V1** shape — the index lists are lists, and each
/// rate is a bare `PRational`. `tx-build-cardano`'s `DanoOracleHelper` is the
/// reference for the encoding; the entries are sorted the way it sorts them, so
/// the validator can binary-search the list.
/// The redeemer names its reference inputs **by index into the transaction's own
/// reference-input set**, which is why it is returned as a function of that set
/// rather than as a value: a fill cites the registry, the market, the venue pool
/// and five script references beside the oracle's four, so indices taken over the
/// oracle's own refs alone would all be wrong.

/// A Minswap V2 pool datum, in the field order `lib/adapter/minswap.ak` reads:
/// stake credential, `asset_a`, `asset_b`, `total_liquidity`, `reserve_a`,
/// `reserve_b`, then the two fee numerators.
const gcd = (a: bigint, b: bigint): bigint => (b === 0n ? a : gcd(b, a % b));

function fromMinswapPool(pool: UTxO, priced: string, fallback: Quote): Quote {
  try {
    const d = Data.from(pool.datum!) as Constr<any>;
    const side = (i: number) => {
      const a = d.fields[i] as Constr<any>;
      const pid = a.fields[0] as string;
      const name = a.fields[1] as string;
      return pid === "" && name === "" ? "" : `${pid}.${name}`;
    };
    const a = side(1);
    const b = side(2);
    const reserveA = d.fields[4] as bigint;
    const reserveB = d.fields[5] as bigint;
    // The oracle composes a path node by node from `PRational(1, 1)` and reduces by
    // the gcd at every step — `helpers.get_prices_and_borrow_rates` — so a
    // single-node path yields the rate in **lowest terms**. `expect price ==
    // price_in_rdmr` is structural, so the raw pair only matches while the two
    // reserves happen to be coprime, which is most of the time and not all of it.
    const reduce = (num: bigint, den: bigint): Quote => {
      const d = gcd(num, den);
      return { asset: priced, numerator: num / d, denominator: den / d };
    };
    if (priced === a) return reduce(reserveB, reserveA);
    if (priced === b) return reduce(reserveA, reserveB);
    return fallback;
  } catch {
    return fallback;
  }
}

export async function oracleWithdrawal(
  supplyToken: string,
  priced: string[],
): Promise<{
  refs: UTxO[];
  redeemerFor: (idx: (u: UTxO) => bigint) => Data;
  quotes: Quote[];
}> {
  const typed: Typed[] = [
    { type: "ORACLE_SCRIPT", utxo: await resolve(...ORACLE_SCRIPT_REF) },
  ];
  const seen = new Set([`${ORACLE_SCRIPT_REF[0]}#${ORACLE_SCRIPT_REF[1]}`]);
  const quotes: Quote[] = [];
  for (const asset of priced) {
    const info = await askAggregator(asset, supplyToken);
    // The aggregator quotes **human-readable** amounts: `quoteToken` per whole
    // `baseToken`. Every validator here computes in units, so the rate is scaled
    // by the two decimal places before it reaches the redeemer. The pair whose
    // decimals agree — ADA against fUSDM, both six — scales by 1, which is why
    // this was invisible until fBTC's eight decimals met fUSDM's six and made
    // the collateral appear to be worth a hundred times what it is.
    const dec = (a: string) => {
      const d = DECIMALS[a];
      if (d === undefined) throw new Error(`no decimals recorded for ${a || "ADA"}`);
      return BigInt(d);
    };
    const pow = (n: bigint) => 10n ** n;
    // The oracle recomputes the rate from the pool's own reserves and compares it
    // to this one with `expect price == price_in_rdmr` — a **structural** equality
    // on `PRational`, not an equality of value. So the pair of integers has to be
    // the pair the validator arrives at, not merely a fraction worth the same.
    // A Minswap CPAMM leg at `tAPerB` yields `PRational(reserve_b, reserve_a)`,
    // and the aggregator hands back that same denominator with a numerator
    // already scaled by the two decimal places. Dividing it back out lands on the
    // validator's own integers; scaling both sides, as this did before, lands on
    // a fraction of equal value that the equality still rejects.
    const shift = dec(asset) - dec(supplyToken);
    const num = BigInt(info.exchangeRateNum);
    const den = BigInt(info.exchangeRateDen);
    const scaled =
      shift >= 0n
        ? { asset, numerator: num / pow(shift), denominator: den }
        : { asset, numerator: num, denominator: den / pow(-shift) };

    let source: UTxO | undefined;
    for (const ref of info.referenceInputs) {
      const [h, i] = ref.outRef.split("#");
      const utxo = await resolve(h!, Number(i));
      if (ref.type === "MINSWAP_LP") source = utxo;
      if (seen.has(ref.outRef)) continue;
      seen.add(ref.outRef);
      typed.push({ type: ref.type, utxo });
    }

    // The oracle recomputes the rate from this very UTxO and compares the two
    // integers, so the aggregator's own number is only usable while its cache and
    // the pool agree — and a pool moves whenever anyone trades against it, this
    // deployment's own batcher included. Reading the reserves out of the reference
    // input the redeemer cites removes the race: a Minswap CPAMM leg at `tAPerB`
    // is `PRational(reserve_b, reserve_a)`, oriented by which side is being priced.
    quotes.push(source ? fromMinswapPool(source, asset, scaled) : scaled);
  }

  const sorted = [...typed].sort((a, b) =>
    a.utxo.txHash === b.utxo.txHash
      ? a.utxo.outputIndex - b.utxo.outputIndex
      : a.utxo.txHash < b.utxo.txHash ? -1 : 1,
  );

  const config = typed.find((t) => t.type === "ORACLE_CONFIG");
  if (!config) throw new Error("the aggregator named no ORACLE_CONFIG");
  const paths = typed.filter((t) => t.type === "ORACLE_SOURCE_PATH");
  const sources = typed
    .filter((t) => SOURCE_TYPE[t.type] !== null && SOURCE_TYPE[t.type] !== undefined)
    .sort((a, b) => SOURCE_TYPE[a.type]! - SOURCE_TYPE[b.type]!);

  // prices[supply_token][priced_asset] = rate. The supply token is not quoted
  // against itself: the oracle has no path for a self-pair and rejects the whole
  // withdrawal, and the contracts fix that rate at 1/1 themselves.
  const row = new Map<Data, Data>(
    quotes.map((q) => [tuple(q.asset), new Constr(0, [q.numerator, q.denominator])]),
  );
  const prices = new Map<Data, Data>([[tuple(supplyToken), row]]);

  return {
    refs: sorted.map((t) => t.utxo),
    redeemerFor: (idx) =>
      new Constr(0, [
        idx(config.utxo),
        paths.map((t) => idx(t.utxo)),
        sources.map((t) => [
          new Constr(0, []),                        // UtxoTarget::RefInput
          new Constr(SOURCE_TYPE[t.type]!, []),      // OracleUTxOType
          idx(t.utxo),
        ]),
        prices,
        new Map(),
      ]),
    quotes,
  };
}
