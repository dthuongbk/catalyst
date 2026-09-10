/// Sign a transaction someone else built, with this wallet, and submit it.
///
/// Nothing here derives the transaction: it is taken as given. So the default is
/// to **look**, not to sign — the summary below is the only thing standing
/// between a hex blob and the admin key. `--submit` is the second, deliberate
/// step.
///
///   bun run sign-submit.ts <file-with-cbor-hex>            # inspect only
///   bun run sign-submit.ts <file-with-cbor-hex> --submit   # sign and send
import { CML, Kupmios, Lucid } from "@lucid-evolution/lucid";
import { DEPLOYER_SEED, KUPO_ENDPOINT, NETWORK, OGMIOS_ENDPOINT } from "./src/env.ts";

const path = process.argv[2];
if (!path) throw new Error("usage: bun run sign-submit.ts <file-with-cbor-hex> [--submit]");
const doSubmit = process.argv.includes("--submit");
const hex = (await Bun.file(path).text()).trim().replace(/\s+/g, "");
if (!/^[0-9a-fA-F]+$/.test(hex)) throw new Error("that file is not a hex string");

const lucid = await Lucid(new Kupmios(KUPO_ENDPOINT!, OGMIOS_ENDPOINT!), NETWORK);
lucid.selectWallet.fromSeed(DEPLOYER_SEED!);
const walletAddr = await lucid.wallet().address();

const tx = CML.Transaction.from_cbor_hex(hex);
const body = tx.body();
console.log(`\nnetwork ${NETWORK}, ${hex.length / 2} bytes`);
console.log(`this wallet ${walletAddr}`);

// The names below differ between CML builds, so every read is guarded and the
// script says what it could not read rather than pretending it read it.
const guard = <T,>(what: string, f: () => T): T | undefined => {
  try {
    return f();
  } catch (e) {
    console.log(`  (could not read ${what}: ${e instanceof Error ? e.message : e})`);
    return undefined;
  }
};

const ins = guard("inputs", () => body.inputs());
if (ins) {
  console.log(`\ninputs (${ins.len()}):`);
  for (let i = 0; i < ins.len(); i += 1) {
    const o = ins.get(i);
    console.log(`  ${o.transaction_id().to_hex().slice(0, 16)}…#${o.index()}`);
  }
}

/// Every protocol NFT this deployment minted, so an output that moves one is
/// named rather than buried in a list of policies.
const rec = await Bun.file(`${import.meta.dir}/../deployments/${NETWORK.toLowerCase()}.json`)
  .json()
  .catch(() => null);
const admin = rec
  ? `${rec.adminNft.policyId}.${rec.adminNft.assetName}`
  : null;

const outs = guard("outputs", () => body.outputs());
let adminMoves: string | null = null;
if (outs) {
  console.log(`\noutputs (${outs.len()}):`);
  for (let i = 0; i < outs.len(); i += 1) {
    const o = outs.get(i);
    const addr = o.address().to_bech32(undefined);
    const amt = o.amount();
    const lovelace = amt.coin().toString();
    const ma = amt.multi_asset();
    const lines: string[] = [];
    const pols = ma.keys();
    for (let p = 0; p < pols.len(); p += 1) {
      const pol = pols.get(p);
      const names = ma.get_assets(pol)!;
      const ks = names.keys();
      for (let n = 0; n < ks.len(); n += 1) {
        const nm = ks.get(n);
        const unit = `${pol.to_hex()}.${nm.to_hex()}`;
        const qty = names.get(nm)!.toString();
        if (admin && unit === admin) {
          adminMoves = addr;
          lines.push(`      *** AdminNFT *** ${qty}`);
        } else {
          lines.push(`      ${qty} ${unit.slice(0, 20)}…`);
        }
      }
    }
    const mine = addr === walletAddr ? "  <- this wallet" : "";
    console.log(`  [${i}] ${addr.slice(0, 32)}…${mine}`);
    console.log(`      ${(Number(lovelace) / 1e6).toFixed(6)} ADA${lines.length ? "" : "  (no tokens)"}`);
    lines.forEach((l) => console.log(l));
  }
}
guard("fee", () => console.log(`\nfee ${(Number(body.fee()) / 1e6).toFixed(6)} ADA`));
guard("mint", () => {
  const m = body.mint();
  console.log(`mint: ${m ? `${m.keys().len()} policy(ies)` : "none"}`);
});

if (adminMoves && adminMoves !== walletAddr) {
  console.log(`\n!!! this transaction sends the AdminNFT to ${adminMoves}`);
  console.log(`!!! that is not this wallet. Do not submit unless that is the intent.`);
} else if (adminMoves) {
  console.log(`\nthe AdminNFT stays at this wallet.`);
}

if (!doSubmit) {
  console.log(`\nnothing was signed. Re-run with --submit to sign and send.`);
} else {
  const signed = await lucid.fromTx(hex).sign.withWallet().complete();
  const hash = await signed.submit();
  console.log(`\nsubmitted ${hash}`);
  console.log(`https://preprod.cardanoscan.io/transaction/${hash}`);
}
