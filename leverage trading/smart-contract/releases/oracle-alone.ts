/// The oracle's zero withdrawal, alone — no validator of this repository, no
/// mint, no script input. Builds, never submits.
///
/// This is the diagnostic `DEPLOYMENT.md` trap 16 describes, and the evidence
/// behind §5: if this fails, nothing in our redeemers or our reference-input
/// indices is implicated, and the failure is small enough to hand to whoever owns
/// the oracle.
///
///   bun run oracle-alone.ts
import { Data, Kupmios, Lucid, type UTxO } from "@lucid-evolution/lucid";
import { DEPLOYER_SEED, KUPO_ENDPOINT, NETWORK, OGMIOS_ENDPOINT } from "./src/env.ts";
import { oracleWithdrawal } from "./src/oracle.ts";
import { oracleRewardAddress } from "./src/venues.ts";

const FUSDM = "834a15101873b4e1ddfaa830df46792913995d8738dcde34eda27905.665553444d";
const FBTC  = "007c4fc75b7662fc735177aa714da9d1b06af5644df199fef39e5fc1.66425443";
const lucid = await Lucid(new Kupmios(KUPO_ENDPOINT!, OGMIOS_ENDPOINT!), NETWORK);
lucid.selectWallet.fromSeed(DEPLOYER_SEED!);

for (const [label, supply, priced] of [
  ["fUSDM giá theo ADA ", "", FUSDM],
  ["fBTC giá theo fUSDM", FUSDM, FBTC],
] as [string, string, string][]) {
  try {
    const o = await oracleWithdrawal(supply, [priced]);
    const sorted = [...o.refs].sort((a, b) =>
      a.txHash === b.txHash ? a.outputIndex - b.outputIndex : (a.txHash < b.txHash ? -1 : 1));
    const idx = (u: UTxO) => BigInt(sorted.findIndex(
      (r) => r.txHash === u.txHash && r.outputIndex === u.outputIndex));
    await lucid.newTx()
      .readFrom(sorted)
      .withdraw(oracleRewardAddress(NETWORK), 0n, Data.to(o.redeemerFor(idx)))
      .complete({ setCollateral: 15_000_000n });
    console.log(`${label}: BUILD ĐƯỢC — oracle chấp nhận withdrawal đứng một mình`);
  } catch (e) {
    const m = e instanceof Error ? e.message : JSON.stringify(e);
    console.log(`${label}: THẤT BẠI — ${m.slice(0, 160)}`);
  }
}
