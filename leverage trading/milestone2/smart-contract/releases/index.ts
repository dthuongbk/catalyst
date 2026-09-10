import { Lucid, Kupmios, type LucidEvolution } from "@lucid-evolution/lucid";
import { KUPO_ENDPOINT, NETWORK, OGMIOS_ENDPOINT, DEPLOYER_SEED, requireEnv } from "./src/env.ts";
import { Deployer } from "./src/deployer.ts";

requireEnv();

// Initialising asks Ogmios for the protocol parameters behind a 10s ceiling the
// provider sets itself, and the hosted endpoint misses it under load — which
// failed a command before it had run at all.
async function connect(): Promise<LucidEvolution> {
  let last: unknown;
  for (let i = 1; i <= 8; i += 1) {
    try {
      return await Lucid(new Kupmios(KUPO_ENDPOINT!, OGMIOS_ENDPOINT!), NETWORK);
    } catch (e) {
      last = e;
      console.log(`  connect attempt ${i} failed, retrying`);
      await new Promise((r) => setTimeout(r, 4_000 * i));
    }
  }
  throw last;
}

const lucid: LucidEvolution = await connect();
lucid.selectWallet.fromSeed(DEPLOYER_SEED!);

const args = process.argv.slice(2);
const deployer = new Deployer(lucid);

const at = args.includes("--at") ? args[args.indexOf("--at") + 1] : undefined;
if (at !== undefined && !at.startsWith("addr")) {
  console.error("usage: --at <address that will hold the reference scripts>");
  process.exit(1);
}

if (args.includes("--deploy")) {
  await deployer.deploy(at);
} else if (args.includes("--show")) {
  await deployer.show();
} else if (args.includes("--verify")) {
  await deployer.verify();
} else if (args.includes("--deploy-minswap")) {
  await deployer.deployMinswap(at);
} else if (args.includes("--publish-changed")) {
  await deployer.publishChanged(at);
} else if (args.includes("--register-stake")) {
  await deployer.registerStake();
} else if (args.includes("--create-order")) {
  // `--create-order [priceNum] [market|limit] [long <deposit>]`. The deposit is
  // read out before the price, so the two digit strings cannot be confused.
  const rest = args.slice(args.indexOf("--create-order") + 1);
  const li = rest.indexOf("long");
  const longDeposit = li !== -1 ? BigInt(rest[li + 1] ?? "0") : 0n;
  const priceNum = rest
    .filter((_, k) => li === -1 || (k !== li && k !== li + 1))
    .find((a) => /^\d+$/.test(a));
  // A long-funded order is a limit order: no venue fill can take it.
  await deployer.createOrder(
    priceNum !== undefined ? BigInt(priceNum) : undefined,
    !rest.includes("limit") && longDeposit === 0n,
    longDeposit);
} else if (args.includes("--supply")) {
  const i = args.indexOf("--supply");
  const w = args[i + 2];
  await deployer.supply(
    BigInt(args[i + 1] ?? "200000000"),
    w === "fusdm" ? "fusdm" : w === "fbtc" ? "fbtc" : "ada");
} else if (args.includes("--modify-position")) {
  // `--modify-position [tpNum] [tpDen]` — the take-profit price to write.
  const rest = args.slice(args.indexOf("--modify-position") + 1)
    .filter((a) => /^\d+$/.test(a));
  await deployer.modifyPosition(
    rest[0] !== undefined ? BigInt(rest[0]) : undefined,
    rest[1] !== undefined ? BigInt(rest[1]) : undefined);
} else if (args.includes("--take-profit")) {
  // §10.2.1 with no owner input: the oracle authorises it, not the ticket.
  await deployer.closeAsync(true);
} else if (args.includes("--rollback")) {
  await deployer.rollback();
} else if (args.includes("--cancel-claim")) {
  await deployer.cancelClaim();
} else if (args.includes("--announce-oracle")) {
  await deployer.announceOracle(args[args.indexOf("--announce-oracle") + 1] ?? "");
} else if (args.includes("--update-market-param")) {
  await deployer.updateMarketParam();
} else if (args.includes("--settle-close")) {
  await deployer.settleClose();
} else if (args.includes("--close-async")) {
  await deployer.closeAsync();
} else if (args.includes("--collect-remain")) {
  await deployer.collectRemain();
} else if (args.includes("--liquidate")) {
  await deployer.liquidate();
} else if (args.includes("--fill-sync")) {
  await deployer.fillSync();
} else if (args.includes("--borrow-async")) {
  // §7.6 with a claim — `--borrow-async <margin> [loanAmount]`. The margin is in
  // the market's supply token, and the default draws the same again, which is the
  // 2x a market order takes.
  const bi = args.indexOf("--borrow-async");
  const margin = BigInt(args[bi + 1] ?? "0");
  if (margin <= 0n) throw new Error("usage: --borrow-async <margin> [loanAmount]");
  const want = args[bi + 2];
  await deployer.borrowAsync(
    margin, want && /^[0-9]+$/.test(want) ? BigInt(want) : undefined);
} else if (args.includes("--borrow")) {
  // §7.6 — `--borrow <collateral> [loanAmount]`. Omit the amount and it
  // lends half of what §3 admits against that collateral.
  const bi = args.indexOf("--borrow");
  const collateral = BigInt(args[bi + 1] ?? "0");
  if (collateral <= 0n) throw new Error("usage: --borrow <collateral> [loanAmount]");
  // `max` lends exactly what §3 admits, which is the only way to reach §11: the
  // loan opens healthy by a hair and the interest index eats the hair.
  const want = args[bi + 2];
  await deployer.borrow(
    collateral,
    want === "max" ? "max" : want && /^[0-9]+$/.test(want) ? BigInt(want) : undefined);
} else if (args.includes("--redeem")) {
  await deployer.redeem(BigInt(args[args.indexOf("--redeem") + 1] ?? "100000000"));
} else if (args.includes("--withdraw-fee")) {
  await deployer.withdrawFee();
} else if (args.includes("--repay")) {
  await deployer.repay();
} else if (args.includes("--cancel-order")) {
  await deployer.cancelOrder();
} else if (args.includes("--settle-claim")) {
  await deployer.settleClaim();
} else if (args.includes("--fill-minswap")) {
  const fee = args.includes("--batcher-fee") ? args[args.indexOf("--batcher-fee") + 1] : undefined;
  await deployer.fillMinswap(fee !== undefined ? BigInt(fee) : undefined);
} else if (args.includes("--reclaim")) {
  await deployer.reclaim();
} else if (args.includes("--evict")) {
  await deployer.evict(args[args.indexOf("--evict") + 1] ?? "");
} else if (args.includes("--consolidate")) {
  await deployer.consolidate();
} else if (args.includes("--tidy")) {
  await deployer.tidy();
} else if (args.includes("--republish")) {
  const host = args[args.indexOf("--republish") + 1];
  if (!host?.startsWith("addr")) {
    console.error("usage: --republish <address that will hold the reference scripts>");
    process.exit(1);
  }
  await deployer.republish(host);
} else if (args.includes("--update-adapters")) {
  await deployer.updateAdapters();
} else if (args.includes("--create-market")) {
  const which = args[args.indexOf("--create-market") + 1];
  await deployer.createMarket(
    which === "fusdm" ? "fusdm" : which === "fbtc" ? "fbtc" : "ada");
} else {
  console.error("usage: bun run index.ts --show | --deploy | --deploy-minswap | --publish-changed | --update-adapters | --create-market | --reclaim | --consolidate | --evict <addr> | --fill-minswap | --settle-claim | --cancel-order | --repay | --redeem | --fill-sync | --borrow <collateral> [loanAmount] | --borrow-async <margin> [loanAmount] | --liquidate | --collect-remain | --close-async | --settle-close | --modify-position | --update-market-param | --announce-oracle | --cancel-claim | --rollback | --take-profit | --create-order ... long <n> | --withdraw-fee | --verify");
  process.exit(1);
}
