import { credentialToRewardAddress, type Network } from "@lucid-evolution/lucid";

/// The venue hashes `adapter_minswap` is parameterised by. They determine its
/// hash, so they belong in the repo rather than in `.env`: a deployment has to be
/// reproducible from the source, which is what `--verify` checks.
export type MinswapV2 = {
  orderSkh: string;
  poolSkh: string;
  poolNftPolicy: string;
};

/// Do **not** take these from the monorepo's `.env.preprod`. Its `MINSWAP_V2_*`
/// block carries mainnet values on both networks — `MINSWAP_V2_POOL_SCRIPT_HASH`
/// and `MINSWAP_V2_ORDER_SCRIPT_HASH` are byte-identical in `.env.preprod` and
/// `.env.mainnet`, and neither matches anything on preprod (Kupo returns 0 UTxOs
/// for both). The preprod values below come from the `MINSWAP_NETWORK__*` block,
/// with `orderSkh` decoded from `MINSWAP_NETWORK__MARKET_ORDER_ADDRESS_V2`, and
/// each was confirmed against preprod: 537 pool UTxOs, 2_207 order UTxOs, 1_483
/// LP NFTs.
export const MINSWAP_V2: Partial<Record<Network, MinswapV2>> = {
  Preprod: {
    orderSkh: "da9525463841173ad1230b1d5a1b5d0a3116bbdeb4412327148a1b7a",
    poolSkh: "d6ba9b7509eac866288ff5072d2a18205ac56f744bc82dcd808cb8fe",
    poolNftPolicy: "d6aae2059baee188f74917493cf7637e679cd219bdfbbf4dcbeb1d0b",
  },
  Mainnet: {
    orderSkh: "c3e28c36c3447315ba5a56f33da6a6ddc1770a876a8d9f0cb3a97c4c",
    poolSkh: "ea07b733d932129c378af627436e7cbc2ef0bf96e0036bb51b3bde6b",
    poolNftPolicy: "f5808c2c990d86da54bfc97d89cee6efa20cd8461616359478d96b4c",
  },
};

export function minswapV2For(network: Network): MinswapV2 {
  const v = MINSWAP_V2[network];
  if (!v) throw new Error(`no Minswap V2 hashes recorded for ${network}`);
  return v;
}

/// The canonical oracle `oracle_skh` names — the on-chain price aggregator's
/// script, whose withdrawal redeemer carries the prices every health check reads.
///
/// Genesis must write a real hash here: biz spec §14.2.3a requires `oracle_skh`
/// non-empty, and an empty script hash is the **lovelace** policy rather than a
/// script. It also has to be right the first time — `oracle_skh` moves only
/// through `AnnounceOracle` then `RotateOracle`, and `oracle_rotation_delay` is
/// 86_400_000 ms, so a wrong hash costs a day or a fresh genesis.
///
/// Verified on preprod by fetching the reference script at
/// ac0868ede8fead21c58ad7901119db2606189ff5b484fb189f9ac3c9afccd5b8#0 and hashing
/// it. Note the monorepo also carries `LATEST_ORACLE_SCRIPT_HASH`
/// (0edfb519…, float-lending's own oracle) and `ORACLE_SCRIPT_HASH_V2` — three
/// different oracles, so the key matters, not just the network.
export const ORACLE_SKH: Partial<Record<Network, string>> = {
  Preprod: "3158c9a7ba551eb3b6b9aa578e7995dec5ce34e272fde0bda76b46d1",
  Mainnet: "012a6bd4ae76261c1d3b5067caa4010f781f5c1c64ce2779bba2f90a",
};

export function oracleSkhFor(network: Network): string {
  const h = ORACLE_SKH[network];
  if (!h) throw new Error(`no oracle script hash recorded for ${network}`);
  return h;
}

/// The oracle's withdrawal account. A price is proved by a zero withdrawal from
/// this address carrying the rates as its redeemer.
export function oracleRewardAddress(network: Network): string {
  return credentialToRewardAddress(network, { type: "Script", hash: oracleSkhFor(network) });
}
