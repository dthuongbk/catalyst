import {
  Constr,
  credentialToAddress,
  Data,
  getAddressDetails,
  type LucidEvolution,
  type Script,
  toUnit,
  type UTxO,
  validatorToAddress,
  validatorToRewardAddress,
  validatorToScriptHash,
} from "@lucid-evolution/lucid";
import { blake2b224, blake2b256, hashUtxo } from "@danogo-js/sdk";
import { getInputIndices, slotToUnixTime, unixTimeToSlot } from "@lucid-evolution/utils";
import {
  ACTIVE, ACTIVE_KEY, MARKET_ADA, MARKET_FBTC, MARKET_FUSDM, MARKET_KEY, ORDER,
  SUPPLY_IS_TOKEN, addressData, type MarketParams, marketDatum,
  orderDatum, poolDatum,
} from "./market.ts";
import { KUPO_ENDPOINT, NETWORK, OUT_FOLDER } from "./env.ts";
import { genesisDatum, type Registry } from "./datum.ts";
import { minswapAdapter, oneShotMint, ours, type TupleAsset } from "./blueprint.ts";
import { minswapV2For, type MinswapV2, oracleRewardAddress, oracleSkhFor } from "./venues.ts";
import { kupoJson, resolve } from "./resolve.ts";
import { oracleWithdrawal } from "./oracle.ts";
import {
  achievable, borrowApy, ceilingDiv, debtAt, depositQty, fillCeiling, healthFloor,
  floorDiv, indexAt, limitFloor, marketFloor, netLoanProceeds, repaidOf, rewardBounds,
  seizedOf,
} from "./arith.ts";

/// `constants.min_ada` — every script UTxO this protocol writes carries it.
const MIN_ADA = 5_000_000n;

/// The name the Minswap authen policy gives every pool's identity NFT, so the
/// pool's other asset of that policy is its LP token.
const MSP = "4d5350";

const max0 = (x: bigint): bigint => (x > 0n ? x : 0n);

const SCAN: Record<string, string> = {
  Preprod: "https://preprod.cardanoscan.io/transaction",
  Preview: "https://preview.cardanoscan.io/transaction",
  Mainnet: "https://cardanoscan.io/transaction",
};

export class Deployer {
  constructor(private readonly lucid: LucidEvolution) {}

  /// Fewest assets first. Genesis spends exactly one input — a second would
  /// change the name its policy computes — so this input's tokens are the ones
  /// its change output has to carry, and a hundred of them exceed `maxValSize`.
  ///
  /// Read through Kupo rather than the provider: a sweep submitted moments ago
  /// leaves `lucid.utxosAt` naming inputs the node has already seen spent, and
  /// the transaction is rejected for an unknown output reference.
  private async fund(min: bigint): Promise<UTxO> {
    const addr = await this.lucid.wallet().address();
    const rows = (await this.kupo(addr))
      .filter((r) => !r.script_hash && BigInt(r.value.coins) >= min)
      .sort(
        (a, b) =>
          Object.keys(a.value.assets ?? {}).length - Object.keys(b.value.assets ?? {}).length,
      );
    const row = rows[0];
    if (!row) {
      throw new Error(
        `no UTxO with at least ${min} lovelace at ${addr}. Fund the wallet from the preprod faucet.`,
      );
    }
    return resolve(row.transaction_id, row.output_index);
  }

  /// Kupo and Ogmios both time out at 5s under load, which killed a deploy at
  /// script 9 of 10. Every build and submit is retried rather than restarted:
  /// a partial run leaves reference scripts published under hashes that a later
  /// run cannot reuse.
  private async retry<T>(what: string, f: () => Promise<T>, attempts = 8): Promise<T> {
    let last: unknown;
    for (let i = 1; i <= attempts; i += 1) {
      try {
        return await f();
      } catch (e) {
        last = e;
        const why = (e instanceof Error ? e.message : String(e)).replace(/\s+/g, " ");
        console.log(`    ${what} attempt ${i} failed: ${why.slice(0, 900)}`);
        await new Promise((r) => setTimeout(r, 4_000 * i));
      }
    }
    throw last;
  }

  private async submit(label: string, tx: any): Promise<string> {
    // Signing queries the provider too, so it times out on the same 5s ceiling
    // that killed a run at script 9 of 10. It is retried like the rest.
    const signed = await this.retry<any>(`sign ${label}`, () =>
      tx.sign.withWallet().complete(),
    );
    // `DUMP_TX=1` writes the signed CBOR out. A node that rejects a transaction
    // as malformed says nothing about which part, so the bytes are the only way
    // in — a duplicate input was found exactly this way.
    if (process.env["DUMP_TX"]) {
      await Bun.write("/tmp/signed.cbor", (signed as any).toCBOR());
      console.log("  wrote /tmp/signed.cbor");
    }
    const hash = await this.retry<string>(`submit ${label}`, () => signed.submit());
    // Appended rather than folded into the deployment record: every arm writes
    // that record whole, and a transaction log has to survive being overwritten.
    const trail = `${OUT_FOLDER}/${NETWORK.toLowerCase()}-transactions.jsonl`;
    const line = JSON.stringify({ step: label.trim(), tx: hash, at: new Date().toISOString() });
    const before = await Bun.file(trail).exists() ? await Bun.file(trail).text() : "";
    await Bun.write(trail, before + line + "\n");
    console.log(`  ${label}: ${hash}`);
    console.log(`    ${SCAN[NETWORK] ?? ""}/${hash}`);
    await this.lucid.awaitTx(hash);
    return hash;
  }

  /// Genesis, in two transactions.
  ///
  /// The naming is daken's `one_shot` policy's, not this spec's: it admits exactly
  /// two names, `blake2b_256(all inputs)` for the ProtocolNFT and
  /// `blake2b_256(that)` for the second, and rejects anything else. So
  /// `admin_nft_suffix` is not used here — the policy already keeps the two names
  /// apart, which is all §5 rule 3 needs.
  ///
  /// The policy does **not** inspect the genesis datum, and §14's `CreateProtocol`
  /// cannot either: it carries no `protocol_in_idx`, and at genesis there is no
  /// `protocol_config` UTxO to spend. The registry written here is therefore
  /// trusted to the deployer. Enforcing it on-chain needs a minting policy of our
  /// own that reads the output datum.
  async deploy(host?: string): Promise<void> {
    const mintScript = oneShotMint();
    const pid = validatorToScriptHash(mintScript);
    const walletAddr = await this.lucid.wallet().address();
    const mintRdmr = Data.to(new Constr(0, []));

    // Before anything is minted: the wallet's ADA sits in token-carrying UTxOs
    // between runs, and both the genesis change and every reference-script
    // publish need funding that carries nothing.
    await this.ensureCleanFunding(walletAddr, 500_000_000n);

    // One input only, so `blake2b_256(all inputs)` is `hashUtxo(seed)`. Adding a
    // second input to balance fees would change the name the policy computes.
    const seed = await this.fund(400_000_000n);
    const nftName = hashUtxo(seed, blake2b256);
    const adminName = blake2b256(nftName);
    const protocolNft: TupleAsset = [pid, nftName];
    const protoUnit = toUnit(pid, nftName);
    const adminUnit = toUnit(pid, adminName);

    // `nftName` is known before the mint, so every validator's parameter — and so
    // its script hash — is computable now. That is what lets the genesis datum
    // name all eight hashes in the transaction that mints the NFT authenticating it.
    const v = ours();
    const built = {
      protocol_config: v.protocol_config(protocolNft),
      market_param: v.market_param(protocolNft),
      pool: v.pool(protocolNft),
      loan: v.loan(protocolNft),
      loan_repay: v.loan_repay(protocolNft),
      loan_close: v.loan_close(protocolNft),
      order: v.order(protocolNft),
      position: v.position(protocolNft),
      cancel: v.cancel(protocolNft),
      adapter_sync_generic: v.adapter_sync_generic(protocolNft),
    };
    const hash = (x: Script) => validatorToScriptHash(x);
    const registry: Registry = {
      poolSkh: hash(built.pool),
      loanSkh: hash(built.loan),
      loanRepaySkh: hash(built.loan_repay),
      loanCloseSkh: hash(built.loan_close),
      configPoolSkh: hash(built.market_param),
      orderSkh: hash(built.order),
      positionSkh: hash(built.position),
      cancelSkh: hash(built.cancel),
      adminNft: [pid, adminName],
      oracleSkh: oracleSkhFor(NETWORK),
    };
    const protocolAddr = validatorToAddress(NETWORK, built.protocol_config);

    // Pinned to the seed alone. The policy computes the NFT name from **all**
    // inputs, so a second one the builder picks for balance would change it —
    // and a stale wallet set is what made the node reject this transaction for
    // an unknown output reference.
    this.lucid.overrideUTxOs([seed]);
    console.log("1/2  mint both NFTs and write the genesis registry");
    const tx1 = await this.retry("build genesis", () => this.lucid
      .newTx()
      .collectFrom([seed])
      .mintAssets({ [protoUnit]: 1n, [adminUnit]: 1n }, mintRdmr)
      .attach.MintingPolicy(mintScript)
      .pay.ToContract(
        protocolAddr,
        { kind: "inline", value: genesisDatum(registry) },
        { lovelace: 5_000_000n, [protoUnit]: 1n },
      )
      .pay.ToAddress(walletAddr, { lovelace: 5_000_000n, [adminUnit]: 1n })
      .complete());
    const genesisTx = await this.submit("genesis", tx1);

    // One transaction per script: a reference script carries the whole compiled
    // program, and ten of ours come to 84 kB against the 16 kB transaction limit.
    const entries = Object.entries(built);
    const scriptsOf = () => Object.fromEntries(
      Object.entries(built).map(([n, x]) => [
        n,
        {
          scriptHash: hash(x),
          sizeBytes: x.script.length / 2,
          address: validatorToAddress(NETWORK, x),
          rewardAddress: validatorToRewardAddress(NETWORK, x),
        },
      ]),
    );
    const record = `${OUT_FOLDER}/${NETWORK.toLowerCase()}.json`;
    const save = async (refTxs: Record<string, string>) => {
      await Bun.write(record, JSON.stringify({
        network: NETWORK,
        protocolNft: { policyId: pid, assetName: nftName },
        adminNft: { policyId: pid, assetName: adminName },
        protocolConfigAddress: protocolAddr,
        registry,
        genesisTx,
        referenceScripts: refTxs,
        referenceScriptHost: host ?? walletAddr,
        scripts: scriptsOf(),
      }, null, 2) + "\n");
    };
    // Genesis had to spend the wallet's one large UTxO, so its change carries
    // every test token again. Sweeping once here leaves a single clean UTxO that
    // funds all eleven publishes; the AdminNFT is spared so it stays on its own.
    await this.ensureCleanFunding(walletAddr, 200_000_000n, [adminUnit]);
    const refTxs: Record<string, string> = {};
    let n = 0;
    for (const [name, script] of entries) {
      n += 1;
      if (refTxs[name]) {
        console.log(`2/2  reference script ${n}/${entries.length}  ${name} — already published`);
        continue;
      }
      console.log(`2/2  reference script ${n}/${entries.length}  ${name}`);
      // Funded from clean ADA. A change output carries whatever its inputs did,
      // and one token-heavy input pushes a 12 kB script past `maxTxSize`.
      const fuel = this.cleanFunding(await this.kupo(walletAddr), 200_000_000n);
      console.log(`     funded by ${fuel.length} token-free UTxO`);
      this.lucid.overrideUTxOs(fuel.map((r) => this.toUtxo(r, walletAddr)));
      const tx = await this.retry(`build ${name}`, () =>
        this.lucid
          .newTx()
          .pay.ToAddressWithData(
            host ?? walletAddr,
            { kind: "inline", value: Data.to(new Constr(0, [])) },
            { lovelace: 30_000_000n },
            script,
          )
          .complete(),
      );
      refTxs[name] = await this.submit(`  ${name} ${hash(script)}`, tx);
      // Recorded one at a time: a dropped connection at the ninth of ten used to
      // orphan the whole genesis, since nothing was written until all ten landed.
      await save(refTxs);
    }

    console.log(`\nwrote ${record}`);
  }

  /// `adapter_minswap` names the venue's own three hashes, so it cannot be built
  /// in the genesis run: the registry does not carry them and the whitelist starts
  /// empty. Publishing its reference script is all this does — admitting it still
  /// takes an `UpdateAdapters` from the admin, biz spec §14.2.6.
  async deployMinswap(host?: string): Promise<void> {
    const record = `${OUT_FOLDER}/${NETWORK.toLowerCase()}.json`;
    const rec = await Bun.file(record).json();
    const nft: TupleAsset = [rec.protocolNft.policyId, rec.protocolNft.assetName];
    const venue = minswapV2For(NETWORK);
    const script = minswapAdapter(nft, venue.orderSkh, venue.poolSkh, venue.poolNftPolicy);
    const skh = validatorToScriptHash(script);
    const size = script.script.length / 2;
    console.log(`adapter_minswap ${skh}`);
    console.log(`  order ${venue.orderSkh}`);
    console.log(`  pool  ${venue.poolSkh}`);
    console.log(`  lpNft ${venue.poolNftPolicy}`);
    console.log(`  size  ${size} bytes`);
    if (rec.referenceScripts.adapter_minswap) {
      console.log("already published; nothing to do");
      return;
    }
    const walletAddr = await this.lucid.wallet().address();
    await this.ensureCleanFunding(walletAddr, 200_000_000n, [
      toUnit(rec.adminNft.policyId, rec.adminNft.assetName),
    ]);
    this.lucid.overrideUTxOs(
      this.cleanFunding(await this.kupo(walletAddr), 200_000_000n).map((r) =>
        this.toUtxo(r, walletAddr),
      ),
    );
    const tx = await this.retry("build adapter_minswap", () =>
      this.lucid
        .newTx()
        .pay.ToAddressWithData(
          host ?? walletAddr,
          { kind: "inline", value: Data.to(new Constr(0, [])) },
          { lovelace: 30_000_000n },
          script,
        )
        .complete(),
    );
    rec.referenceScripts.adapter_minswap = await this.submit("  adapter_minswap", tx);
    rec.scripts.adapter_minswap = {
      scriptHash: skh,
      sizeBytes: size,
      address: validatorToAddress(NETWORK, script),
      rewardAddress: validatorToRewardAddress(NETWORK, script),
    };
    rec.minswapV2 = venue;
    await Bun.write(record, JSON.stringify(rec, null, 2) + "\n");
    console.log(`\nupdated ${record}`);
  }

  /// Kupo, asked directly. `lucid.utxosAt` runs behind a 5s ceiling in the
  /// provider, and an address holding thirty reference scripts does not resolve
  /// inside it — each script has to be fetched. Querying by asset keeps the
  /// result to one row, and an address query here gets as long as it needs.
  private async kupo(pattern: string): Promise<any[]> {
    return kupoJson(pattern);
  }

  private async kupoDirect(pattern: string): Promise<any[]> {
    const r = await fetch(`${KUPO_ENDPOINT}/matches/${pattern}?unspent`);
    if (!r.ok) throw new Error(`kupo ${pattern}: ${r.status}`);
    // Minswap's preprod LP tokens are minted at about 2^63. `JSON.parse` turns
    // such a quantity into a float and loses digits, so long integers are quoted
    // before parsing and read back as strings.
    const text = (await r.text()).replace(/:\s*(\d{16,})/g, ':"$1"');
    return JSON.parse(text) as any[];
  }

  /// A Kupo row turned into a `UTxO` without going back through the provider.
  ///
  /// `utxosByOutRef` resolves by transaction hash and validates every output of
  /// that transaction, so one sibling holding a 2^63 Minswap LP token fails the
  /// whole lookup even when the UTxO wanted is plain. Building it here reads only
  /// the row asked for. Datum-carrying UTxOs still go through the provider — this
  /// is for funding inputs, which have neither datum nor script.
  private toUtxo(r: any, address: string): UTxO {
    const assets: Record<string, bigint> = { lovelace: BigInt(r.value.coins) };
    for (const [k, q] of Object.entries(r.value.assets ?? {})) {
      assets[k.replace(".", "")] = BigInt(q as string);
    }
    return {
      txHash: r.transaction_id,
      outputIndex: r.output_index,
      address,
      assets,
      datumHash: null,
      datum: null,
      scriptRef: null,
    };
  }

  /// A UTxO lucid can read.
  ///
  /// Minswap's preprod LP tokens are minted at about 2^63, and the provider
  /// validates Kupo's response against a schema that admits a JS number or a
  /// digit string. Such a quantity is neither once `JSON.parse` has turned it
  /// into a float, so resolving that UTxO fails outright — it has to be left
  /// alone rather than swept or spent.
  private readable(_r: any): boolean {
    return true;
  }

  /// Leaves the wallet holding one large asset-free UTxO.
  ///
  /// Publishing a 12 kB script needs its funding input to carry no tokens: a
  /// change output has to carry whatever the inputs did, and one input holding a
  /// hundred test tokens adds four kilobytes and pushes the transaction past
  /// `maxTxSize`. The wallet's own ADA sits in token-carrying UTxOs, so the
  /// tokens are swept into one output and the change comes back clean.
  private async ensureCleanFunding(
    walletAddr: string,
    want: bigint,
    keep: string[] = [],
  ): Promise<void> {
    const held = (r: any) => Object.keys(r.value.assets ?? {});
    const spared = (r: any) => held(r).some((u) => keep.includes(u));
    const rows = (await this.kupo(walletAddr)).filter((r) => !spared(r));
    const clean = rows.filter((r) => !r.script_hash && held(r).length === 0);
    if (clean.some((r) => BigInt(r.value.coins) >= want)) {
      console.log("  funding already clean");
      return;
    }
    const withAssets = rows
      .filter((r) => !r.script_hash && held(r).length > 0 && this.readable(r))
      .sort((a, b) => Number(BigInt(b.value.coins) - BigInt(a.value.coins)));
    if (withAssets.length === 0) throw new Error("no token-carrying UTxO to sweep");
    const utxos = [...withAssets, ...clean].map((r) => this.toUtxo(r, walletAddr));
    const bag: Record<string, bigint> = {};
    for (const u of utxos) {
      for (const [unit, qty] of Object.entries(u.assets)) {
        if (unit === "lovelace") continue;
        bag[unit] = (bag[unit] ?? 0n) + qty;
      }
    }
    // One output per sixty assets. A value serialises at about forty bytes per
    // asset against a `maxValSize` of 5_000, and a single output holding a
    // hundred and twenty came to 5_115 — the whole sweep failed to build.
    const units = Object.keys(bag);
    const chunks: Record<string, bigint>[] = [];
    for (let i = 0; i < units.length; i += 60) {
      chunks.push(Object.fromEntries(units.slice(i, i + 60).map((u) => [u, bag[u]!])));
    }
    console.log(`  sweeping ${units.length} assets into ${chunks.length} output(s)`);
    this.lucid.overrideUTxOs(utxos);
    const tx = await this.retry("build sweep", () => {
      let b = this.lucid.newTx().collectFrom(utxos);
      for (const chunk of chunks) b = b.pay.ToAddress(walletAddr, chunk);
      return b.complete();
    });
    await this.submit("  sweep", tx);
    // `awaitTx` proves the block; Kupo may still be a few seconds behind it, and
    // every caller's next step reads its funding from Kupo.
    for (let i = 0; i < 20; i += 1) {
      const rows = await this.kupo(walletAddr);
      const clean = rows.filter(
        (r) => !r.script_hash && Object.keys(r.value.assets ?? {}).length === 0,
      );
      if (clean.some((r) => BigInt(r.value.coins) >= want)) return;
      await new Promise((r) => setTimeout(r, 3_000));
    }
    throw new Error("the sweep did not surface a clean UTxO");
  }

  /// Wallet UTxOs with the fewest assets first. A change output has to carry
  /// whatever the inputs did, and one input holding a hundred test tokens pushes
  /// a 12 kB script transaction past `maxTxSize` on its own.
  /// Funding that carries no token at all, enough to cover `want`.
  ///
  /// A change output has to carry whatever its inputs did, so one token-heavy
  /// input adds kilobytes: a 12 kB reference script came to 17_605 bytes against
  /// a 16_384 limit purely because the funding UTxO held a hundred test tokens.
  /// Several clean UTxOs are combined rather than reaching for a dirty one.
  private cleanFunding(rows: any[], want: bigint): any[] {
    const clean = rows
      .filter((r) => !r.script_hash && Object.keys(r.value.assets ?? {}).length === 0)
      .sort((a, b) => Number(BigInt(b.value.coins) - BigInt(a.value.coins)));
    const picked: any[] = [];
    let have = 0n;
    for (const r of clean) {
      picked.push(r);
      have += BigInt(r.value.coins);
      if (have >= want) break;
    }
    if (have < want) {
      throw new Error(
        `only ${have} lovelace across ${clean.length} token-free UTxO, need ${want}. ` +
        `Run --tidy to sweep the tokens into one output.`,
      );
    }
    return picked;
  }

  private leanest(rows: any[], n: number): any[] {
    return rows
      .filter(
        (r) => !r.script_hash && BigInt(r.value.coins) >= 20_000_000n && this.readable(r),
      )
      .sort(
        (a, b) =>
          Object.keys(a.value.assets ?? {}).length - Object.keys(b.value.assets ?? {}).length ||
          Number(BigInt(b.value.coins) - BigInt(a.value.coins)),
      )
      .slice(0, n);
  }

  private async oneHolding(unit: string, what: string): Promise<UTxO> {
    const dot = `${unit.slice(0, 56)}.${unit.slice(56)}`;
    const rows = await this.kupo(dot);
    if (rows.length !== 1) {
      throw new Error(`expected exactly one UTxO holding ${what}, found ${rows.length}`);
    }
    const row = rows[0];
    // A plain wallet output is built here rather than resolved: the provider
    // validates every sibling of the transaction it came from, and one holding a
    // 2^63 quantity fails that for an unrelated UTxO.
    if (!row.datum_type) return this.toUtxo(row, row.address);
    const [u] = await this.lucid.utxosByOutRef([
      { txHash: row.transaction_id, outputIndex: row.output_index },
    ]);
    if (!u) throw new Error(`${what} out-ref did not resolve`);
    return u;
  }

  /// The registry UTxO and the admin UTxO, the two every admin arm needs.
  private async adminContext(rec: any) {
    const registry = await this.oneHolding(
      toUnit(rec.protocolNft.policyId, rec.protocolNft.assetName),
      "the ProtocolNFT",
    );
    const admin = await this.oneHolding(
      toUnit(rec.adminNft.policyId, rec.adminNft.assetName),
      "the AdminNFT",
    );
    const walletAddr = await this.lucid.wallet().address();
    // Anything that is not a published script and not the admin UTxO itself. A
    // seed has no constraint on its value — §20.2 item 3.1 — so carrying other
    // tokens is fine; fewest first only to keep the transaction small.
    const rows = (await this.kupo(walletAddr))
      .filter(
        (r) =>
          !r.script_hash &&
          !(r.transaction_id === admin.txHash && r.output_index === admin.outputIndex) &&
          BigInt(r.value.coins) >= 20_000_000n,
      )
      .sort(
        (a, b) =>
          Object.keys(a.value.assets ?? {}).length - Object.keys(b.value.assets ?? {}).length ||
          Number(BigInt(b.value.coins) - BigInt(a.value.coins)),
      );
    if (rows.length === 0) throw new Error("no funding UTxO with at least 20 ADA at the deployer wallet");
    const [funding] = await this.lucid.utxosByOutRef([
      { txHash: rows[0].transaction_id, outputIndex: rows[0].output_index },
    ]);
    if (!funding) throw new Error("funding out-ref did not resolve");
    return { registry, admin, funding, walletAddr };
  }

  /// The window every admin arm validates against. `tx_start` is read back
  /// through the slot conversion, because that is the value the script sees: a
  /// POSIX time not on a slot boundary comes back rounded, and §20.2.8 compares
  /// `interest_time` to it exactly.
  private window(): { from: number; to: number; startMs: bigint } {
    const from = slotToUnixTime(NETWORK, unixTimeToSlot(NETWORK, Date.now() - 120_000));
    return { from, to: from + 300_000, startMs: BigInt(from) };
  }

  /// §14 `UpdateAdapters` — whitelist the two adapters. Every other field of the
  /// registry is carried over unchanged, which is what §14.2.2a requires.
  async updateAdapters(): Promise<void> {
    const record = `${OUT_FOLDER}/${NETWORK.toLowerCase()}.json`;
    const rec = await Bun.file(record).json();
    const { registry, admin, funding, walletAddr } = await this.adminContext(rec);
    if (!registry.datum) throw new Error("registry UTxO carries no inline datum");

    const entry = new Constr(0, [new Constr(1, []), new Constr(1, [])]); // may_create, may_recover
    const current = Data.from(registry.datum) as Constr<Data>;
    const fields = [...current.fields];
    // §14.2.6 admits adding and re-permissioning, never removing: an entry whose
    // script is superseded stays in place, harmless, because nothing can withdraw
    // from a hash no reference script publishes any more.
    const adapters = new Map<Data, Data>(
      (fields[6] instanceof Map ? [...(fields[6] as Map<Data, Data>)] : []),
    );
    for (const name of ["adapter_sync_generic", "adapter_minswap"] as const) {
      adapters.set(rec.scripts[name].scriptHash, entry);
    }
    fields[6] = adapters;                        // ProtocolDatum.adapters
    const next = Data.to(new Constr(current.index, fields));

    const all = [registry, admin, funding];
    const idx = getInputIndices([registry, admin], all);
    const protocolInIdx = idx[0]!;
    const adminInIdx = idx[1]!;
    console.log(`  protocol_in_idx=${protocolInIdx} admin_in_idx=${adminInIdx} protocol_out_idx=0`);
    const rdmr = Data.to(new Constr(1, [protocolInIdx, adminInIdx, 0n]));
    const { from, to } = this.window();
    const refUtxo = (await this.lucid.utxosByOutRef([
      { txHash: rec.referenceScripts.protocol_config, outputIndex: 0 },
    ]))[0];
    if (!refUtxo?.scriptRef) throw new Error("protocol_config reference script not found");

    const tx = await this.retry("build update-adapters", () =>
      this.lucid
        .newTx()
        .collectFrom([registry], rdmr)
        .collectFrom([admin, funding])
        .readFrom([refUtxo])
        .pay.ToContract(
          rec.protocolConfigAddress,
          { kind: "inline", value: next },
          registry.assets,
        )
        // The AdminNFT goes back on its own. Left to the change selector it ends
        // up holding the wallet's whole ADA balance, and the next admin arm then
        // finds no funding UTxO that is not the admin UTxO.
        .pay.ToAddress(
          walletAddr,
          { [toUnit(rec.adminNft.policyId, rec.adminNft.assetName)]: 1n },
        )
        .validFrom(from)
        .validTo(to)
        .complete(),
    );
    const hash = await this.submit("  update-adapters", tx);
    rec.adaptersWhitelisted = {
      tx: hash,
      adapter_sync_generic: rec.scripts.adapter_sync_generic.scriptHash,
      adapter_minswap: rec.scripts.adapter_minswap.scriptHash,
    };
    await Bun.write(record, JSON.stringify(rec, null, 2) + "\n");
    console.log(`\nupdated ${record}`);
  }

  /// §20 `CreateMarket` — one market, one pool, ADA lent and fUSDM accepted.
  async createMarket(which: "ada" | "fusdm" | "fbtc" = "ada"): Promise<void> {
    const m: MarketParams =
      which === "fusdm" ? MARKET_FUSDM : which === "fbtc" ? MARKET_FBTC : MARKET_ADA;
    // A protocol hosts many markets: each `CreateMarket` mints its own MarketNFT
    // from its own seed, and the registry they are all read through is shared.
    const key = which === "ada" ? "market" : `market${which[0]!.toUpperCase()}${which.slice(1)}`;
    const record = `${OUT_FOLDER}/${NETWORK.toLowerCase()}.json`;
    const rec = await Bun.file(record).json();
    const { registry, admin, funding, walletAddr } = await this.adminContext(rec);
    const nft: TupleAsset = [rec.protocolNft.policyId, rec.protocolNft.assetName];
    const marketParam = ours().market_param(nft);
    const configPoolSkh = validatorToScriptHash(marketParam);
    if (configPoolSkh !== rec.registry.configPoolSkh) {
      throw new Error(
        `registry names config_pool_skh ${rec.registry.configPoolSkh} but this source builds ${configPoolSkh}. ` +
        `A market minted under the built hash could never be read. Run a genesis whose registry names it.`,
      );
    }
    // The seed is the funding UTxO: its output reference names the MarketNFT.
    const marketName = hashUtxo(funding, blake2b224);
    const marketUnit = toUnit(configPoolSkh, marketName);
    const marketAddr = validatorToAddress(NETWORK, marketParam);
    const poolAddr = validatorToAddress(NETWORK, ours().pool(nft));

    const all = [admin, funding];
    const idx = getInputIndices([funding, admin], all);
    const seedIdx = idx[0]!;
    const adminIdx = idx[1]!;
    const { from, to, startMs } = this.window();
    // ADA is the empty policy and the empty name, which is how a token is told
    // from it without naming either literal.
    const shown = (t: { policyId: string; assetName: string }) =>
      t.policyId.length === 0 ? "ADA" : t.assetName;
    const recorded = (t: { policyId: string; assetName: string }) =>
      t.policyId.length === 0 ? "ada" : `${t.policyId}.${t.assetName}`;
    console.log(`  ${which} market: lends ${shown(m.supplyToken)}, `
      + `collateral ${shown(m.collateral)} at ${m.collateral.liquidationThreshold}`);
    console.log(`  min_tx_amount ${m.minTxAmount}, min_liquidator_reward ${m.minLiquidatorReward}`);
    console.log(`  MarketNFT ${configPoolSkh}.${marketName}`);
    console.log(`  seed_utxo_idx=${seedIdx} admin_in_idx=${adminIdx} market_out_idx=0 pool_out_idx=1`);
    console.log(`  tx_start=${startMs} (interest_time must equal it)`);

    const rdmr = Data.to(new Constr(1, [seedIdx, adminIdx, 0n, 1n, 0n]));
    const tx = await this.retry("build create-market", () =>
      this.lucid
        .newTx()
        .collectFrom(all)
        .readFrom([registry])
        .mintAssets({ [marketUnit]: 2n }, rdmr)
        .attach.MintingPolicy(marketParam)
        .pay.ToContract(
          marketAddr,
          { kind: "inline", value: Data.to(marketDatum(walletAddr, m)) },
          { lovelace: 5_000_000n, [marketUnit]: 1n },
        )
        .pay.ToContract(
          poolAddr,
          { kind: "inline", value: Data.to(poolDatum(startMs, m)) },
          { lovelace: 5_000_000n, [marketUnit]: 1n },
        )
        .pay.ToAddress(
          walletAddr,
          { [toUnit(rec.adminNft.policyId, rec.adminNft.assetName)]: 1n },
        )
        .validFrom(from)
        .validTo(to)
        .complete(),
    );
    const hash = await this.submit("  create-market", tx);
    rec[key] = {
      tx: hash,
      marketNft: { policyId: configPoolSkh, assetName: marketName },
      marketAddress: marketAddr,
      poolAddress: poolAddr,
      supplyToken: recorded(m.supplyToken),
      collateral: recorded(m.collateral),
    };
    await Bun.write(record, JSON.stringify(rec, null, 2) + "\n");
    console.log(`\nupdated ${record}`);
  }

  /// Registers the reward account of every script whose logic lives in a
  /// `Withdraw`.
  ///
  /// The withdraw-zero pattern needs the stake credential registered. A local
  /// evaluation does not say so — the script runs and the transaction builds —
  /// but submission fails with `incompleteWithdrawals` (Ogmios 3141) until the
  /// account exists. Registration itself is permissionless: no script witness,
  /// just the deposit.
  async registerStake(): Promise<void> {
    const record = `${OUT_FOLDER}/${NETWORK.toLowerCase()}.json`;
    const rec = await Bun.file(record).json();
    const walletAddr = await this.lucid.wallet().address();
    const names = [
      "pool", "loan", "loan_repay", "loan_close", "order", "position",
      "cancel", "adapter_sync_generic", "adapter_minswap",
    ];
    // Keyed by reward address, not by validator name: republishing a script under
    // a new hash gives it a new withdrawal account, and a list of names called it
    // registered while the node still answered Ogmios 3141 for it.
    const already: string[] = (rec.stakeRegistered ?? []).map((e: string) =>
      e.startsWith("stake") ? e : (rec.scripts[e]?.rewardAddress ?? e));
    const todo = names.filter((n) => !already.includes(rec.scripts[n].rewardAddress));
    if (todo.length === 0) {
      console.log("every withdrawal account is already registered");
      return;
    }
    this.lucid.overrideUTxOs(
      this.leanest(await this.kupo(walletAddr), 1).map((r) => this.toUtxo(r, walletAddr)),
    );
    let tx = this.lucid.newTx();
    for (const name of todo) {
      const reward = rec.scripts[name].rewardAddress as string;
      console.log(`  ${name.padEnd(22)} ${reward}`);
      tx = tx.registerStake(reward);
    }
    const built = await this.retry("build register-stake", () => tx.complete());
    const hash = await this.submit(`  register ${todo.length} account(s)`, built);
    rec.stakeRegistered = [...already, ...todo.map((n) => rec.scripts[n].rewardAddress)];
    rec.stakeRegistrationTx = hash;
    await Bun.write(record, JSON.stringify(rec, null, 2) + "\n");
    console.log(`\nupdated ${record}`);
  }

  /// §6 `CreateOrder` — the trader posts margin and an intent.
  ///
  /// No oracle is involved: §6 reads no price. The `OrderNFT` names the order and
  /// the `OrderOwnerNFT` goes to the trader, who is the only one who can modify
  /// or cancel it afterwards.
  /// §6 `CreateOrder`.
  ///
  /// `longDeposit` posts a **long-funded** order: the trader brings the collateral
  /// and no supply-token margin at all. Such an order can only be filled
  /// synchronously — §7.4.6 is stated twice and the two halves agree only where
  /// the deposit is zero — so it is written as a limit order and the reserve it
  /// carries is reclaimed by §9.3 rather than spent by a venue fill.
  async createOrder(
    limitPriceNum?: bigint,
    isMarket = true,
    longDeposit = 0n,
  ): Promise<void> {
    const record = `${OUT_FOLDER}/${NETWORK.toLowerCase()}.json`;
    const rec = await Bun.file(record).json();
    if (!rec[ACTIVE_KEY]) throw new Error("no market recorded; run --create-market first");
    const nft: TupleAsset = [rec.protocolNft.policyId, rec.protocolNft.assetName];
    const v = ours();
    const orderScript = v.order(nft);
    const orderSkh = validatorToScriptHash(orderScript);
    if (orderSkh !== rec.registry.orderSkh) {
      throw new Error(`registry names order_skh ${rec.registry.orderSkh}, this source builds ${orderSkh}`);
    }
    const walletAddr = await this.lucid.wallet().address();
    const registry = await this.oneHolding(
      toUnit(rec.protocolNft.policyId, rec.protocolNft.assetName), "the ProtocolNFT");
    const holders = await this.kupo(
      `${rec[ACTIVE_KEY].marketNft.policyId}.${rec[ACTIVE_KEY].marketNft.assetName}`);
    const marketRow = holders.find((r) => r.address === rec[ACTIVE_KEY].marketAddress);
    if (!marketRow) throw new Error("market UTxO not found");
    const market = await resolve(marketRow.transaction_id, marketRow.output_index);
    const orderRef = await resolve(rec.referenceScripts.order, 0);

    // The order carries its margin and reserve in lovelace, and the wallet's ADA
    // drifts into the token bag as the arms run — a bag is excluded from the
    // selection this builds, so a wallet with 1 700 ADA can still fail to find
    // the 190 it needs. Sweep one clean output first.
    await this.ensureCleanFunding(walletAddr, 250_000_000n);
    const seedRow = this.leanest(await this.kupo(walletAddr), 1)[0];
    if (!seedRow) throw new Error("no funding UTxO to seed the order");
    const seed = await resolve(seedRow.transaction_id, seedRow.output_index);
    // Whatever the order is funded with has to come from an input, and the seed is
    // the leanest UTxO — by definition not the one holding a token. A long-funded
    // order needs the collateral; a market whose supply token is not ADA needs
    // that token for the margin.
    const longUnit = `${ACTIVE.collateral.policyId}${ACTIVE.collateral.assetName}`;
    const holder = async (dotted: string, want: bigint): Promise<UTxO> => {
      const row = (await this.kupo(dotted)).find((r) => r.address === walletAddr
        && BigInt(r.value.assets[dotted] ?? 0) >= want);
      if (!row) throw new Error(`no wallet UTxO holding ${want} of ${dotted}`);
      return resolve(row.transaction_id, row.output_index);
    };
    const funded: UTxO[] = [];
    if (longDeposit > 0n) {
      funded.push(await holder(
        `${ACTIVE.collateral.policyId}.${ACTIVE.collateral.assetName}`, longDeposit));
    }
    if (SUPPLY_IS_TOKEN && ORDER.margin > 0n && longDeposit === 0n) {
      funded.push(await holder(
        `${ACTIVE.supplyToken.policyId}.${ACTIVE.supplyToken.assetName}`, ORDER.margin));
    }
    const orderNftName = hashUtxo(seed, blake2b224);
    const ownerNftName = orderNftName + Buffer.from("OWN").toString("hex");
    const orderUnit = toUnit(orderSkh, orderNftName);
    const ownerUnit = toUnit(orderSkh, ownerNftName);
    // The order carries the trader's stake credential, which §7.2.21 then pins on
    // the position and the loan.
    const orderAddr = validatorToAddress(
      NETWORK, orderScript, getAddressDetails(walletAddr).stakeCredential,
    );

    const refs = [registry, market, orderRef];
    const sortedRefs = [...refs].sort((a, b) =>
      a.txHash === b.txHash ? a.outputIndex - b.outputIndex : (a.txHash < b.txHash ? -1 : 1));
    const refIdx = (u: UTxO) => BigInt(sortedRefs.findIndex(
      (r) => r.txHash === u.txHash && r.outputIndex === u.outputIndex));
    const ins = this.distinct([seed, ...funded]);
    const seedIdx = getInputIndices([seed], ins)[0]!;
    const rdmr = Data.to(new Constr(0, [
      [new Constr(0, [seedIdx, 0n, refIdx(market)])],
      refIdx(registry),
    ]));
    const { from, to } = this.window();
    // A long-funded order holds minADA and the reserve and nothing more in the
    // supply token, which is exactly what makes `order_net` read its margin as
    // zero.
    const margin = longDeposit > 0n ? 0n : ORDER.margin;
    // `fee_reserve` is lovelace on every market — §1.3 calls it a structural
    // charge on a UTxO rather than an amount of what is lent — but the margin is
    // denominated in the supply token. Where that is not ADA it leaves the
    // lovelace alone and rides as a token instead.
    const supplyUnit = `${ACTIVE.supplyToken.policyId}${ACTIVE.supplyToken.assetName}`;
    const lovelace = 5_000_000n + ORDER.feeReserve + (SUPPLY_IS_TOKEN ? 0n : margin);
    console.log(`  a ${isMarket ? "market" : "limit"} order, fee_reserve ${ORDER.feeReserve}`);
    console.log(`  OrderNFT ${orderSkh}.${orderNftName}`);
    console.log(`  seed_utxo_idx=${seedIdx} order_out_idx=0 market_ref_idx=${refIdx(market)} protocol_ref=${refIdx(registry)}`);
    console.log(`  order holds ${lovelace} lovelace: min_ada + fee_reserve ${ORDER.feeReserve} + margin ${margin}`);
    if (longDeposit > 0n)
      console.log(`  long-funded: ${longDeposit} of the collateral, no supply-token margin`);

    this.lucid.overrideUTxOs(ins);
    const tx = await this.retry("build create-order", () =>
      this.lucid
        .newTx()
        .collectFrom(ins)
        .readFrom(refs)
        .mintAssets({ [orderUnit]: 1n, [ownerUnit]: 1n }, rdmr)
        .withdraw(validatorToRewardAddress(NETWORK, orderScript), 0n, rdmr)
        .pay.ToContract(
          orderAddr,
          { kind: "inline", value: Data.to(orderDatum(
            walletAddr, rec[ACTIVE_KEY].marketNft.assetName,
            [rec.scripts.adapter_sync_generic.scriptHash, rec.scripts.adapter_minswap.scriptHash],
            limitPriceNum,
            isMarket,
          )) },
          {
            lovelace,
            [orderUnit]: 1n,
            ...(longDeposit > 0n ? { [longUnit]: longDeposit } : {}),
            ...(SUPPLY_IS_TOKEN && margin > 0n ? { [supplyUnit]: margin } : {}),
          },
        )
        .pay.ToAddress(walletAddr, { [ownerUnit]: 1n })
        .validFrom(from)
        .validTo(to)
        .complete(),
    );
    const hash = await this.submit("  create-order", tx);
    rec.order = {
      tx: hash,
      orderNft: { policyId: orderSkh, assetName: orderNftName },
      ownerNft: { policyId: orderSkh, assetName: ownerNftName },
      address: orderAddr,
      lovelace: lovelace.toString(),
      margin: ORDER.margin.toString(),
      shortAmount: ORDER.shortAmount.toString(),
      isMarket,
    };
    rec.orders = Deployer.remember(
      rec.orders, { arm: "create-order", market: MARKET_KEY, ...rec.order }, "orderNft");
    await Bun.write(record, JSON.stringify(rec, null, 2) + "\n");
    console.log(`\nupdated ${record}`);
  }

  /// §18 `TopupWithdraw` — a deposit into the pool.
  ///
  /// The market has no `alt_supply_tokens`, so no oracle withdrawal is present:
  /// the pool holds one asset and its own supply token is the unit of account.
  /// `DanoOracleHelper` takes the same view — it emits no withdrawal at all in
  /// that case.
  async supply(amount: bigint, which: "ada" | "fusdm" | "fbtc" = "ada"): Promise<void> {
    const record = `${OUT_FOLDER}/${NETWORK.toLowerCase()}.json`;
    const rec = await Bun.file(record).json();
    const m: MarketParams =
      which === "fusdm" ? MARKET_FUSDM : which === "fbtc" ? MARKET_FBTC : MARKET_ADA;
    const key = which === "ada" ? "market" : `market${which[0]!.toUpperCase()}${which.slice(1)}`;
    if (!rec[key]) throw new Error(`no ${key} recorded; run --create-market ${which} first`);
    const nft: TupleAsset = [rec.protocolNft.policyId, rec.protocolNft.assetName];
    const poolScript = ours().pool(nft);
    const walletAddr = await this.lucid.wallet().address();
    const registry = await this.byNft(
      rec.protocolNft.policyId, rec.protocolNft.assetName, "the ProtocolNFT");
    const { market, pool } = await this.marketPool(rec, key);
    const poolRef = await resolve(rec.referenceScripts.pool, 0);

    // The deposit is a quantity of `supply_token`. Where that is ADA it is the
    // pool's lovelace that moves; where it is a token, the lovelace must **not**
    // move at all — §7.2.18's whitelist requires it to be monotone for every
    // asset that is neither the supply token nor an alternative key.
    const isAda = m.supplyToken.policyId.length === 0;
    const supplyUnit = isAda
      ? "lovelace"
      : toUnit(m.supplyToken.policyId, m.supplyToken.assetName);
    const wallet: UTxO[] = [];
    let gathered = 0n;
    for (const row of (await this.kupo(walletAddr))
      .filter((r) => !r.script_hash)
      .sort((a, b) =>
        Number(BigInt((b.value.assets ?? {})[`${m.supplyToken.policyId}.${m.supplyToken.assetName}`] ?? 0)
          - BigInt((a.value.assets ?? {})[`${m.supplyToken.policyId}.${m.supplyToken.assetName}`] ?? 0)))) {
      if (gathered >= amount && wallet.length > 0) break;
      const u = await resolve(row.transaction_id, row.output_index);
      wallet.push(u);
      gathered += isAda ? BigInt(u.assets["lovelace"] ?? 0n) : (u.assets[supplyUnit] ?? 0n);
    }
    if (gathered < amount) throw new Error(`hold ${gathered} of the supply token, need ${amount}`);
    // Enough lovelace for the fee has to come along too — and the change output
    // is the expensive part, not the fee. Spending the bag that holds the supply
    // token puts **every other token in that bag** into the change, whose minADA
    // scales with the bag rather than with the amount supplied: a 20-asset change
    // wanted 2 ADA where the bag itself carried barely more than its own minimum.
    // The lean UTxO is always brought along; `distinct` drops it if it was
    // already gathered.
    const fuel = this.leanest(await this.kupo(walletAddr), 1)[0];
    if (fuel) wallet.push(await resolve(fuel.transaction_id, fuel.output_index));
    const inputs = this.distinct(wallet);

    const { from, to, startMs } = this.window();
    const st = this.poolState(pool, startMs, m);
    const supplyBefore = st.inSupply + st.accrued - st.accruedFee;
    // §18.3 — the denominator is the supply as it stood before this transaction,
    // so a lender neither gains nor loses from their own deposit.
    const dtokenQty =
      supplyBefore === 0n || st.inDtoken === 0n
        ? amount
        : floorDiv(amount * st.inDtoken, supplyBefore);
    if (dtokenQty === 0n) throw new Error("the dToken quantity floors to zero");
    if (amount < m.minTxAmount) {
      throw new Error(`§18.2: |pool_changed_amount| ${amount} is below min_tx_amount ${m.minTxAmount}`);
    }
    const totalSupply = max0(supplyBefore + amount);
    const totalBorrow = max0(st.inBorrow + st.accrued);
    const poolOut = new Constr(0, [
      totalSupply, st.inDtoken + dtokenQty, totalBorrow,
      borrowApy(m.baseRate, m.powerBase, totalSupply, totalBorrow),
      st.inFee + st.accruedFee, st.outIndex, st.interestTime,
      st.pd.fields[7], st.pd.fields[8],
    ]);
    const marketUnit = toUnit(rec[key].marketNft.policyId, rec[key].marketNft.assetName);
    const dtokenUnit = toUnit(rec.registry.poolSkh, rec[key].marketNft.assetName);
    const poolValue: Record<string, bigint> = {};
    for (const [u, q] of Object.entries(pool.assets)) poolValue[u] = q;
    poolValue[supplyUnit] = (poolValue[supplyUnit] ?? 0n) + amount;
    poolValue[marketUnit] = 1n;

    const sortedRefs = [registry, market, poolRef].sort((a, b) =>
      a.txHash === b.txHash ? a.outputIndex - b.outputIndex : (a.txHash < b.txHash ? -1 : 1));
    const refIdx = (u: UTxO) => BigInt(sortedRefs.findIndex(
      (r) => r.txHash === u.txHash && r.outputIndex === u.outputIndex));
    const all = this.distinct([pool, ...inputs]);
    const [poolIn] = getInputIndices([pool], all) as bigint[];
    // `TopupWithdraw` is pool action index 2, with no fee output on a deposit.
    const rdmr = Data.to(new Constr(0, [
      [new Constr(2, [poolIn!, 0n, refIdx(market), -1n])], refIdx(registry),
    ]));
    console.log(`  depositing ${amount} ${isAda ? "lovelace" : m.supplyToken.assetName}, minting ${dtokenQty} dToken`);
    console.log(`  supply ${st.inSupply} -> ${totalSupply}, dToken ${st.inDtoken} -> ${st.inDtoken + dtokenQty}, apy ${st.inApy} -> ${borrowApy(m.baseRate, m.powerBase, totalSupply, totalBorrow)}`);
    console.log(`  pool holds ${poolValue["lovelace"]} lovelace and ${Object.keys(poolValue).length - 1} token(s)`);
    const refBytes = sortedRefs.reduce((n, u) => n + (u.scriptRef ? u.scriptRef.script.length / 2 : 0), 0);

    this.lucid.overrideUTxOs(inputs);
    const tx = await this.retry("build supply", () =>
      this.lucid
        .newTx()
        .setMinFee(1_500_000n + BigInt(Math.ceil(refBytes * 25)))
        .collectFrom([pool], rdmr)
        .collectFrom(inputs)
        .readFrom(sortedRefs)
        .withdraw(validatorToRewardAddress(NETWORK, poolScript), 0n, rdmr)
        .mintAssets({ [dtokenUnit]: dtokenQty }, rdmr)
        .pay.ToContract(pool.address, { kind: "inline", value: Data.to(poolOut) }, poolValue)
        .validFrom(from)
        .validTo(to)
        .complete({ setCollateral: 15_000_000n }),
      2,
    );
    const hash = await this.submit("  supply", tx);
    rec[key].supply = { tx: hash, amount: amount.toString(), dtoken: dtokenQty.toString() };
    await Bun.write(record, JSON.stringify(rec, null, 2) + "\n");
    console.log(`\nupdated ${record}`);
  }

  /// The Minswap V2 pool for `long` against ADA, as the venue holds it now.
  ///
  /// Located by value rather than by out-ref: the pool UTxO moves every time a
  /// batch executes, so a recorded reference goes stale within minutes. Only
  /// pools holding the collateral are read, and the datum decides the pair.
  ///
  /// The venue's own `asset_a` / `asset_b` is a canonical ordering of the pair and
  /// says nothing about which side a market lends. Reserves are returned by
  /// **role** — supply and collateral — with `supplyIsA` left for the callers that
  /// have to state a direction the venue will recognise.
  private async minswapPool(venue: MinswapV2, longDotted: string, supplyDotted: string) {
    const rows = (await this.kupo(`${venue.poolSkh}/*`)).filter(
      (r) => (r.value.assets ?? {})[longDotted],
    );
    for (const row of rows) {
      const utxo = await resolve(row.transaction_id, row.output_index);
      if (!utxo.datum) continue;
      const d = Data.from(utxo.datum) as Constr<any>;
      if (d.fields.length !== 10) continue;
      // The venue writes each leg as a record, so the pair is read field by
      // field. ADA is the empty policy and the empty name.
      const dotted = (i: number) => {
        const c = d.fields[i] as Constr<any>;
        return `${c.fields[0] as string}.${c.fields[1] as string}`;
      };
      // The datum writes ADA as an empty policy and an empty name, which this
      // dotted form renders as a bare `.` — the oracle's own spelling for ADA is
      // the empty string, so the two conventions have to be reconciled here.
      const supplyKey = supplyDotted === "" ? "." : supplyDotted;
      const [a, b] = [dotted(1), dotted(2)];
      const supplyIsA = a === supplyKey && b === longDotted;
      const supplyIsB = b === supplyKey && a === longDotted;
      if (!supplyIsA && !supplyIsB) continue;
      const lp = Object.keys(utxo.assets).find(
        (u) => u.startsWith(venue.poolNftPolicy) && u.slice(56) !== MSP,
      );
      if (!lp) throw new Error("the pool holds no LP token of the authen policy");
      if (utxo.assets[toUnit(venue.poolNftPolicy, MSP)] !== 1n) {
        throw new Error("the pool holds no pool NFT of the authen policy");
      }
      const [rA, rB, fA, fB] = [4, 5, 6, 7].map((i) => d.fields[i] as bigint);
      return {
        utxo,
        lpName: lp.slice(56),
        supplyIsA,
        reserveSupply: supplyIsA ? rA! : rB!,
        reserveLong: supplyIsA ? rB! : rA!,
        feeSupply: supplyIsA ? fA! : fB!,
        feeLong: supplyIsA ? fB! : fA!,
      };
    }
    throw new Error(
      `no Minswap V2 pool pairing ${supplyDotted || "ADA"} with ${longDotted} on ${NETWORK}`);
  }

  /// §7.2 with §7.4 — one asynchronous fill, against Minswap.
  ///
  /// Ten script purposes in one transaction: the order and the pool are spent,
  /// `loan_skh` and `position_skh` mint, and six withdrawals carry the arms —
  /// order, pool, loan, position, the adapter, and the oracle whose redeemer
  /// carries the price the health floor rests on. The collateral is not delivered
  /// here: the venue order at the end of the outputs is what buys it, and the loan
  /// holds a `Claim` against it until §8 settles.
  async fillMinswap(batcherFee?: bigint): Promise<void> {
    const record = `${OUT_FOLDER}/${NETWORK.toLowerCase()}.json`;
    const rec = await Bun.file(record).json();
    const orderRec = await this.liveOrder(rec);
    const nft: TupleAsset = [rec.protocolNft.policyId, rec.protocolNft.assetName];
    const v = ours();
    const venue = minswapV2For(NETWORK);
    const built = {
      order: v.order(nft),
      pool: v.pool(nft),
      loan: v.loan(nft),
      position: v.position(nft),
      adapter_minswap: minswapAdapter(nft, venue.orderSkh, venue.poolSkh, venue.poolNftPolicy),
    };
    const skh = Object.fromEntries(
      Object.entries(built).map(([n, s]) => [n, validatorToScriptHash(s)]),
    ) as Record<keyof typeof built, string>;
    for (const [name, want] of [
      ["order", rec.registry.orderSkh],
      ["pool", rec.registry.poolSkh],
      ["loan", rec.registry.loanSkh],
      ["position", rec.registry.positionSkh],
      ["adapter_minswap", rec.adaptersWhitelisted?.adapter_minswap],
    ] as const) {
      if (want && skh[name as keyof typeof built] !== want) {
        throw new Error(`${name}: this source builds ${skh[name as keyof typeof built]}, the deployment uses ${want}`);
      }
    }

    // ------------------------------------------------------------------ state
    const walletAddr = await this.lucid.wallet().address();
    const stake = getAddressDetails(walletAddr).stakeCredential;
    const marketUnit = toUnit(rec[ACTIVE_KEY].marketNft.policyId, rec[ACTIVE_KEY].marketNft.assetName);
    const orderUnit = toUnit(orderRec.orderNft.policyId, orderRec.orderNft.assetName);
    const longDotted = `${ACTIVE.collateral.policyId}.${ACTIVE.collateral.assetName}`;
    const supplyDotted = ACTIVE.supplyToken.policyId === ""
      ? ""
      : `${ACTIVE.supplyToken.policyId}.${ACTIVE.supplyToken.assetName}`;

    const protoRow = (await this.kupo(
      `${rec.protocolNft.policyId}.${rec.protocolNft.assetName}`))[0];
    const holders = await this.kupo(
      `${rec[ACTIVE_KEY].marketNft.policyId}.${rec[ACTIVE_KEY].marketNft.assetName}`);
    const marketRow = holders.find((r) => r.address === rec[ACTIVE_KEY].marketAddress);
    const poolRow = holders.find((r) => r.address === rec[ACTIVE_KEY].poolAddress);
    const orderRow = (await this.kupo(
      `${orderRec.orderNft.policyId}.${orderRec.orderNft.assetName}`))[0];
    if (!protoRow || !marketRow || !poolRow || !orderRow) {
      throw new Error("registry, market, pool or order UTxO not found on chain");
    }
    const registry = await resolve(protoRow.transaction_id, protoRow.output_index);
    const market = await resolve(marketRow.transaction_id, marketRow.output_index);
    const pool = await resolve(poolRow.transaction_id, poolRow.output_index);
    const order = await resolve(orderRow.transaction_id, orderRow.output_index);
    const scriptRefs = await Promise.all(
      (Object.keys(built) as (keyof typeof built)[]).map((n) =>
        resolve(rec.referenceScripts[n], 0)),
    );
    const venuePool = await this.minswapPool(venue, longDotted, supplyDotted);
    const oracle = await oracleWithdrawal(supplyDotted, [longDotted]);
    const price = oracle.quotes[0]!;

    // The fill funds the venue order, the execution tip and two minADAs out of
    // this wallet — around 126 ADA — and it spends one UTxO to do it. Reference
    // scripts published to this same wallet are excluded from coin selection, so
    // a wallet holding thousands of ADA can still have no single output big
    // enough. Sweep one that is.
    await this.ensureCleanFunding(walletAddr, 250_000_000n);
    const seedRow = this.leanest(await this.kupo(walletAddr), 1)[0];
    if (!seedRow) throw new Error("no funding UTxO to seed the fill");
    const seed = await resolve(seedRow.transaction_id, seedRow.output_index);

    // ---------------------------------------------------------------- numbers
    const od = Data.from(order.datum!) as Constr<any>;
    const shortAmount = od.fields[2] as bigint;
    const limit = od.fields[3] as Constr<any>;
    const [limitNum, limitDen] = [limit.fields[0] as bigint, limit.fields[1] as bigint];
    const feeReserve = od.fields[12] as bigint;
    const maxSlippage = od.fields[7] as bigint;

    const pd = Data.from(pool.datum!) as Constr<any>;
    const at = (i: number) => pd.fields[i] as bigint;
    const inSupply = at(0), inDtoken = at(1), inBorrow = at(2), inApy = at(3);
    const inFee = at(4), inIndex = at(5), inTime = at(6);
    const { from, to, startMs } = this.window();

    // §2.2 to §2.6 — the order's own terms.
    // The margin is whatever the order holds of the supply token, net of what is
    // structural: minADA and the reserve, which are lovelace on every market.
    const supplyUnit = `${ACTIVE.supplyToken.policyId}${ACTIVE.supplyToken.assetName}`;
    const margin = SUPPLY_IS_TOKEN
      ? (order.assets[supplyUnit] ?? 0n)
      : BigInt(order.assets["lovelace"]!) - feeReserve - MIN_ADA;
    const tbv = shortAmount - margin;
    // The largest draw this order admits, which makes the fill final: §7.2.8's
    // first branch rather than its `min_execution_amount` branch.
    const loanAmount = tbv;
    const nlp = netLoanProceeds(
      loanAmount, ACTIVE.loanOriginationFeeRate, ACTIVE.loanOriginationFeeMinAmount);
    const shortFromOrderIn = depositQty(margin, loanAmount, tbv);
    const sold = shortFromOrderIn + nlp;
    const afc = ACTIVE.venueFeeBudget + ACTIVE.executionTip + 2n * MIN_ADA;
    if (feeReserve < afc) throw new Error(`fee_reserve ${feeReserve} below async_fill_cost ${afc}`);

    // §7.2.18 — the pool side.
    const outIndex = indexAt(inIndex, inApy, inTime, startMs);
    const accrued = inBorrow === 0n ? 0n : (inBorrow * (outIndex - inIndex)) / inIndex;
    const accruedFee = accrued === 0n ? 0n : ceilingDiv(accrued * ACTIVE.loanFeeRate, 10_000n);
    const totalSupply = max0(inSupply + accrued - accruedFee);
    const totalBorrow = max0(inBorrow + accrued + loanAmount);
    const outApy = borrowApy(ACTIVE.baseRate, ACTIVE.powerBase, totalSupply, totalBorrow);
    const interestTime = startMs > inTime ? startMs : inTime;
    // §7.2.23 — only a fill raises `total_borrow`, so the cap is checked here.
    if (ACTIVE.utilCap * totalSupply <= totalBorrow * 10_000n) {
      throw new Error(`util cap: ${ACTIVE.utilCap} * ${totalSupply} <= ${totalBorrow} * 10000`);
    }
    const poolOutAda = SUPPLY_IS_TOKEN
      ? BigInt(pool.assets["lovelace"]!)
      : BigInt(pool.assets["lovelace"]!) - nlp;
    const poolOutSupply = SUPPLY_IS_TOKEN
      ? (pool.assets[supplyUnit] ?? 0n) - nlp
      : 0n;

    // §4.1 — the floor is the maximum of three terms, each in units of the
    // collateral. `expiry` is pinned: the market's two claim durations are equal.
    const expiry = BigInt(to) + ACTIVE.minClaimDuration;
    const debtAtExpiry = debtAt(loanAmount, outApy, interestTime, expiry);
    const health = healthFloor(
      debtAtExpiry, ACTIVE.claimSafetyMargin, ACTIVE.collateral.liquidationThreshold,
      price.numerator, price.denominator);
    // Selling the supply token for the collateral, whichever side the venue keeps
    // each of them on.
    const aToB = venuePool.supplyIsA;
    const ach = achievable(
      venuePool.reserveSupply, venuePool.reserveLong, sold, venuePool.feeSupply);
    const market_floor = marketFloor(ach, maxSlippage);
    const limit_floor = limitFloor(sold, limitNum, limitDen);
    const floor = [health, market_floor, limit_floor].reduce((a, b) => (a > b ? a : b));
    const ceiling = fillCeiling(ach, ACTIVE.fillabilityMargin);
    if (floor > ceiling) {
      throw new Error(`floor ${floor} above the venue's ceiling ${ceiling} — the pool is too thin for ${sold}`);
    }

    // ------------------------------------------------------------------ names
    const seedName = hashUtxo(seed, blake2b224);
    const hex = (s: string) => Buffer.from(s).toString("hex");
    const loanNftName = rec[ACTIVE_KEY].marketNft.assetName;
    const ownerName = seedName;                              // PositionNFT and LoanOwnerNFT
    const positionOwnerName = seedName + hex("OWN");
    const bindingName = seedName + hex("BND");
    const loanNftUnit = toUnit(skh.loan, loanNftName);
    const loanOwnerUnit = toUnit(skh.loan, ownerName);
    const bindingUnit = toUnit(skh.loan, bindingName);
    const positionUnit = toUnit(skh.position, ownerName);
    const positionOwnerUnit = toUnit(skh.position, positionOwnerName);

    // ---------------------------------------------------------------- indices
    // A venue pool can be one of the oracle's own price sources — the Minswap
    // pool this fill trades against is exactly where the fBTC/fUSDM rate comes
    // from — and a reference input named twice is still one reference input. The
    // ledger dedupes it, so indices taken over a list that does not are off by
    // one for everything past the repeat.
    const refs = this.distinct([registry, market, venuePool.utxo, ...scriptRefs, ...oracle.refs]);
    const sortedRefs = [...refs].sort((a, b) =>
      a.txHash === b.txHash ? a.outputIndex - b.outputIndex : (a.txHash < b.txHash ? -1 : 1));
    const refIdx = (u: UTxO) => BigInt(sortedRefs.findIndex(
      (r) => r.txHash === u.txHash && r.outputIndex === u.outputIndex));
    if (Bun.env["DEBUG_REFS"]) {
      console.log(`  refs(${sortedRefs.length}): ` + sortedRefs.map((u, i) =>
        `${i}:${u.txHash.slice(0, 8)}#${u.outputIndex}${u.scriptRef ? "*" : ""}`).join(" "));
      const rd = oracle.redeemerFor(refIdx) as any;
      const flat = (x: any): string => Array.isArray(x)
        ? "[" + x.map(flat).join(",") + "]"
        : (x && typeof x === "object" && "index" in x ? `C${x.index}` : String(x));
      console.log(`  oracle rdmr: cfg=${flat(rd.fields[0])} paths=${flat(rd.fields[1])} srcs=${flat(rd.fields[2])}`);
    }
    const all = [order, pool, seed];
    const [orderIn, poolIn, seedIn] = getInputIndices([order, pool, seed], all) as bigint[];
    const OUT = { order: 0n, position: 1n, loan: 2n, pool: 3n, venue: 4n, tip: 5n };

    // -------------------------------------------------------------- redeemers
    const protoRef = refIdx(registry);
    const marketRef = refIdx(market);
    const orderRdmr = Data.to(new Constr(0, [
      [new Constr(1, [
        [new Constr(0, [orderIn!, OUT.order, OUT.position, OUT.loan, seedIn!, OUT.tip])],
        marketRef, poolIn!, OUT.pool, skh.adapter_minswap,
      ])],
      protoRef,
    ]));
    const poolRdmr = Data.to(new Constr(0, [
      [new Constr(0, [poolIn!, OUT.pool, marketRef, [ownerName]])], protoRef,
    ]));
    const loanRdmr = Data.to(new Constr(0, [
      [new Constr(0, [
        [new Constr(0, [orderIn!, OUT.loan, OUT.position, seedIn!])],
        marketRef, poolIn!, OUT.pool, skh.adapter_minswap,
      ])],
      protoRef,
    ]));
    const positionRdmr = Data.to(new Constr(0, [
      [new Constr(0, [seedIn!, OUT.position])], protoRef,
    ]));
    // `Pending` is route index 1, and `stake_credential` is the order's own —
    // §7.5's `receiver` split rests on it.
    const stakeData: Data = stake
      ? new Constr(0, [new Constr(0, [new Constr(stake.type === "Script" ? 1 : 0, [stake.hash])])])
      : new Constr(1, []);
    const adapterRdmr = Data.to(new Constr(0, [
      [new Constr(0, [
        ownerName,
        new Constr(1, [
          [ACTIVE.collateral.policyId, ACTIVE.collateral.assetName],
          floor, market_floor,
          [skh.loan, bindingName],
          expiry, orderIn!, refIdx(venuePool.utxo), OUT.venue, stakeData,
        ]),
      ])],
      protoRef, marketRef,
    ]));

    // ---------------------------------------------------------------- outputs
    const orderOut = new Constr(0, [
      ...od.fields.slice(0, 2),
      shortAmount - loanAmount - shortFromOrderIn,
      ...od.fields.slice(3, 12),
      feeReserve - afc,
    ]);
    const positionOut = new Constr(0, [
      od.fields[0], od.fields[4], od.fields[6], od.fields[7], od.fields[11],
    ]);
    const claim = new Constr(0, [
      skh.adapter_minswap,
      [skh.loan, bindingName],
      new Constr(0, []),                                   // Opening
      [ACTIVE.collateral.policyId, ACTIVE.collateral.assetName],
      sold, floor, expiry,
    ]);
    const loanOut = new Constr(0, [
      // The `LoanOwnerNFT` — `loan_skh`, not the position script, per §7.2.19.
      new Constr(0, [[skh.loan, ownerName]]),
      od.fields[1], loanAmount, outIndex, new Constr(0, [claim]),
    ]);
    const poolOut = new Constr(0, [
      totalSupply, inDtoken, totalBorrow, outApy,
      inFee + loanAmount - nlp + accruedFee,
      outIndex, interestTime, pd.fields[7], pd.fields[8],
    ]);
    // §7.5 — the venue order. `receiver` is `Script(loan_skh)` under the trader's
    // own stake credential, which is where §8 later finds the payout.
    const receiver = new Constr(0, [new Constr(1, [skh.loan]), stakeData]);
    const venueOut = new Constr(0, [
      // The venue's `OrderAuthorizationMethod`: index 2 is the *withdrawal*
      // form, which is the only one this protocol's withdraw-only `cancel`
      // script can ever satisfy.
      new Constr(2, [rec.registry.cancelSkh]),             // canceller: the cancel script
      receiver,
      new Constr(0, []),                                   // refund datum: none
      receiver,
      new Constr(0, []),                                   // receiver datum: none
      new Constr(0, [venue.poolNftPolicy, venuePool.lpName]),
      new Constr(0, [
        new Constr(aToB ? 1 : 0, []),                      // a_to_b_direction
        new Constr(0, [sold]),                             // SpecificAmount
        floor,                                             // minimum_receive
        new Constr(1, []),                                 // killable
      ]),
      batcherFee ?? ACTIVE.venueFeeBudget - ACTIVE.maxCancelFee - MIN_ADA - ACTIVE.rollbackTip,
      new Constr(0, [[expiry, ACTIVE.maxCancelFee]]),      // expiry_setting_opt
    ]);
    const venueAddr = credentialToAddress(
      NETWORK, { type: "Script", hash: venue.orderSkh },
      stake ? { type: stake.type === "Script" ? "Script" : "Key", hash: stake.hash } : undefined);

    console.log(`  loan ${loanAmount} of ${shortAmount}, margin ${margin}, nlp ${nlp}, sold ${sold}`);
    console.log(`  floor ${floor} = max(health ${health}, market ${market_floor}, limit ${limit_floor}) <= ceiling ${ceiling}`);
    console.log(`  price ${price.numerator}/${price.denominator}, venue reserves ${venuePool.reserveSupply}/${venuePool.reserveLong} fee ${venuePool.feeSupply}`);
    console.log(`  pool ${inSupply}/${inBorrow} -> ${totalSupply}/${totalBorrow}, apy ${inApy} -> ${outApy}, index ${inIndex} -> ${outIndex}`);
    console.log(`  order_in=${orderIn} pool_in=${poolIn} seed=${seedIn}, market_ref=${marketRef} proto_ref=${protoRef} venue_ref=${refIdx(venuePool.utxo)}`);
    console.log(`  expiry ${expiry} = tx_end ${to} + ${ACTIVE.minClaimDuration}`);

    // Six reference scripts are cited here, and every byte of them is priced on
    // top of the ordinary fee, which the builder's estimate leaves out.
    const refBytes = sortedRefs.reduce(
      (n, u) => n + (u.scriptRef ? u.scriptRef.script.length / 2 : 0), 0);
    const feeFloor = 2_000_000n + BigInt(Math.ceil(refBytes * 25));
    console.log(`  ${refBytes} bytes of reference script, fee floor ${feeFloor}`);

    this.lucid.overrideUTxOs([seed]);
    const tx = await this.retry("build fill-minswap", () =>
      this.lucid
        .newTx()
        .setMinFee(feeFloor)
        .collectFrom([order], orderRdmr)
        .collectFrom([pool], poolRdmr)
        .collectFrom([seed])
        .readFrom(sortedRefs)
        .mintAssets({ [loanNftUnit]: 1n, [loanOwnerUnit]: 1n, [bindingUnit]: 1n }, loanRdmr)
        .mintAssets({ [positionUnit]: 1n, [positionOwnerUnit]: 1n }, positionRdmr)
        .withdraw(validatorToRewardAddress(NETWORK, built.order), 0n, orderRdmr)
        .withdraw(validatorToRewardAddress(NETWORK, built.pool), 0n, poolRdmr)
        .withdraw(validatorToRewardAddress(NETWORK, built.loan), 0n, loanRdmr)
        .withdraw(validatorToRewardAddress(NETWORK, built.position), 0n, positionRdmr)
        .withdraw(validatorToRewardAddress(NETWORK, built.adapter_minswap), 0n, adapterRdmr)
        .withdraw(oracleRewardAddress(NETWORK), 0n, Data.to(oracle.redeemerFor(refIdx)))
        .pay.ToContract(order.address, { kind: "inline", value: Data.to(orderOut) },
          { lovelace: MIN_ADA, [orderUnit]: 1n, [positionOwnerUnit]: 1n })
        .pay.ToContract(
          validatorToAddress(NETWORK, built.position, stake),
          { kind: "inline", value: Data.to(positionOut) },
          { lovelace: MIN_ADA, [positionUnit]: 1n, [loanOwnerUnit]: 1n })
        .pay.ToContract(
          validatorToAddress(NETWORK, built.loan, stake),
          { kind: "inline", value: Data.to(loanOut) },
          { lovelace: MIN_ADA, [loanNftUnit]: 1n })
        .pay.ToContract(pool.address, { kind: "inline", value: Data.to(poolOut) },
          {
            lovelace: poolOutAda,
            [marketUnit]: 1n,
            ...(SUPPLY_IS_TOKEN ? { [supplyUnit]: poolOutSupply } : {}),
          })
        .pay.ToContract(venueAddr, { kind: "inline", value: Data.to(venueOut) },
          {
            lovelace: ACTIVE.venueFeeBudget + (SUPPLY_IS_TOKEN ? 0n : sold),
            [bindingUnit]: 1n,
            ...(SUPPLY_IS_TOKEN ? { [supplyUnit]: sold } : {}),
          })
        .pay.ToAddress(walletAddr, { lovelace: ACTIVE.executionTip })
        .validFrom(from)
        .validTo(to)
        // Collateral is a percentage of the fee — 150% on preprod — and the
        // builder's 5 ADA default falls short of a ten-script transaction's.
        .complete({ setCollateral: 15_000_000n }),
      2,
    );
    const hash = await this.submit("  fill-minswap", tx);
    rec.fill = {
      tx: hash,
      loanAmount: loanAmount.toString(),
      sold: sold.toString(),
      floor: floor.toString(),
      expiry: expiry.toString(),
      loanNft: { policyId: skh.loan, assetName: loanNftName },
      loanOwnerNft: { policyId: skh.loan, assetName: ownerName },
      bindingNft: { policyId: skh.loan, assetName: bindingName },
      positionNft: { policyId: skh.position, assetName: ownerName },
      venueOrderAddress: venueAddr,
      price: `${price.numerator}/${price.denominator}`,
    };
    rec.loans = Deployer.remember(
      rec.loans, { arm: "fill-minswap", market: MARKET_KEY, ...rec.fill }, "loanOwnerNft");
    await Bun.write(record, JSON.stringify(rec, null, 2) + "\n");
    console.log(`\nupdated ${record}`);
  }

  /// Distinct out-refs, order preserved.
  ///
  /// The wallet UTxO holding an owner NFT is often the leanest one, so it gets
  /// picked as the fee funding too. The builder emits the inputs as a CBOR set
  /// whose declared length counts the duplicate while its contents do not, and
  /// the node rejects the transaction as malformed: "Final number of elements: 3
  /// does not match the total count that was decoded: 4".
  private distinct(utxos: UTxO[]): UTxO[] {
    const seen = new Set<string>();
    return utxos.filter((u) => {
      const k = `${u.txHash}#${u.outputIndex}`;
      if (seen.has(k)) return false;
      seen.add(k);
      return true;
    });
  }

  /// The one UTxO holding a given NFT, resolved through Kupo.
  private async byNft(policyId: string, assetName: string, what: string): Promise<UTxO> {
    const rows = await this.kupo(`${policyId}.${assetName}`);
    if (rows.length !== 1) throw new Error(`expected one UTxO holding ${what}, found ${rows.length}`);
    return resolve(rows[0]!.transaction_id, rows[0]!.output_index);
  }

  /// The record keeps one slot per arm, which names only the **last** loan that
  /// arm opened — while a loan lives on chain until it is closed. Two loans open
  /// at once and one of them has no slot: that is how a claim ends up settleable
  /// only by reconstructing its handle from the chain by hand. Every opening arm
  /// therefore appends here as well, and selection reads this list.
  private static remember(list: any[] | undefined, entry: any, key: string): any[] {
    const name = entry?.[key]?.assetName;
    return [...(list ?? []).filter((e) => e?.[key]?.assetName !== name), entry];
  }

  /// Newest first, this market only, with the single slots behind them so that a
  /// record written before the list existed still resolves.
  private static loanCandidates(rec: any): any[] {
    return [
      ...[...(rec.loans ?? [])].reverse()
        .filter((e) => !e?.market || e.market === MARKET_KEY),
      rec.fill, rec.fillSync,
      rec.openDirect?.market === MARKET_KEY ? rec.openDirect : undefined,
      rec.openDirectAsync, rec.openDirect,
    ];
  }

  /// The `BindingNFT` of a claim is the loan's own owner name, suffixed — §7.4.3.
  /// Deriving it beats reading it off a record entry, which the arms that open
  /// without a claim never wrote.
  private static bindingOf(target: any): { policyId: string; assetName: string } {
    return {
      policyId: target.loanOwnerNft.policyId,
      assetName: target.loanOwnerNft.assetName + Buffer.from("BND").toString("hex"),
    };
  }

  /// A record accumulates entries from every arm, and the loans some of them
  /// name have since been closed and their NFTs burned. Walk the candidates and
  /// take the first whose loan is still on chain.
  private async liveLoan(
    rec: any,
    admits?: (loan: UTxO) => boolean,
  ): Promise<any> {
    for (const c of Deployer.loanCandidates(rec)) {
      if (!c?.loanNft || !c?.loanOwnerNft) continue;
      try {
        const loan = await this.loanByOwner(
          c.loanNft.policyId, c.loanNft.assetName, c.loanOwnerNft.assetName);
        if (admits && !admits(loan)) continue;
        return c;
      } catch (_) {
        continue;
      }
    }
    throw new Error("no recorded loan is still open");
  }

  /// The claim a loan carries, or `undefined` where it carries none.
  private static claimOf(loan: UTxO): Constr<any> | undefined {
    const slot = (Data.from(loan.datum!) as Constr<any>).fields[4] as Constr<any>;
    return slot.index === 0 ? (slot.fields[0] as Constr<any>) : undefined;
  }

  /// §10.1 and §10.2.1 both want a loan carrying **no** claim: one already bound
  /// to a venue cannot be closed again until it settles or rolls back.
  private static unclaimed(loan: UTxO): boolean {
    return Deployer.claimOf(loan) === undefined;
  }

  /// `Opening` is claim direction 0 and `Closing` is 1. §8, §4.3 and §12.3 unwind
  /// the first; §10.2.2 settles the second.
  private static opening(loan: UTxO): boolean {
    const c = Deployer.claimOf(loan);
    return c !== undefined && (c.fields[2] as Constr<any>).index === 0;
  }

  private static closing(loan: UTxO): boolean {
    const c = Deployer.claimOf(loan);
    return c !== undefined && (c.fields[2] as Constr<any>).index === 1;
  }

  /// A claim's own terms, which is where §10.2.2 should read them: the record's
  /// one sell slot need not name the loan the arm ends up settling.
  private static sellOf(loan: UTxO): { floor: bigint; sold: bigint; expiry: bigint } {
    const c = Deployer.claimOf(loan)!;
    return {
      sold: c.fields[4] as bigint,
      floor: c.fields[5] as bigint,
      expiry: c.fields[6] as bigint,
    };
  }

  /// The same slot problem on the order side: `--create-order` overwrites one
  /// field, and every order it displaced stays on chain until someone cancels it.
  private async liveOrder(rec: any): Promise<any> {
    const candidates = [
      ...[...(rec.orders ?? [])].reverse()
        .filter((e) => !e?.market || e.market === MARKET_KEY),
      rec.order,
    ];
    for (const c of candidates) {
      if (!c?.orderNft) continue;
      try {
        await this.byNft(c.orderNft.policyId, c.orderNft.assetName, "the OrderNFT");
        return c;
      } catch (_) {
        continue;
      }
    }
    throw new Error("no recorded order is still on chain; run --create-order first");
  }

  /// The `LoanNFT` carries the **market's** name, not the loan's — §7.2.12 — so
  /// every open loan on one market holds a token of the same policy and name, and
  /// `byNft` cannot tell them apart. What is unique is the `LoanOwnerNFT` the
  /// datum names, which is also what the position holds.
  private async loanByOwner(
    loanPolicy: string, marketNftName: string, ownerName: string,
  ): Promise<UTxO> {
    const rows = await this.kupo(`${loanPolicy}.${marketNftName}`);
    const found: UTxO[] = [];
    for (const r of rows) {
      const u = await resolve(r.transaction_id, r.output_index);
      if (!u.datum) continue;
      const d = Data.from(u.datum) as Constr<any>;
      const owner = d.fields[0] as Constr<any>;
      if (owner?.index === 0 && (owner.fields[0] as string[])[1] === ownerName) found.push(u);
    }
    if (found.length !== 1)
      throw new Error(`expected one loan owned by ${ownerName.slice(0, 16)}…, found ${found.length}`);
    return found[0]!;
  }

  /// §8 `SettleClaim` — the venue's payout becomes the loan's collateral.
  ///
  /// Permissionless: anyone may move an arrived payout in, and the payout UTxO's
  /// own minADA is the tip that pays for doing it. The position is **not** spent —
  /// claim state lives only in `LoanDatum`.
  async settleClaim(): Promise<void> {
    const record = `${OUT_FOLDER}/${NETWORK.toLowerCase()}.json`;
    const rec = await Bun.file(record).json();
    // §8 settles an `Opening` claim, and which loan carries one is a question for
    // the chain: the record's slots name only the last loan of each arm.
    const target = await this.liveLoan(rec, Deployer.opening);
    const bindingNft = Deployer.bindingOf(target);
    const nft: TupleAsset = [rec.protocolNft.policyId, rec.protocolNft.assetName];
    const v = ours();
    const venue = minswapV2For(NETWORK);
    const loanScript = v.loan(nft);
    const adapterScript = minswapAdapter(nft, venue.orderSkh, venue.poolSkh, venue.poolNftPolicy);
    const loanSkh = validatorToScriptHash(loanScript);
    const adapterSkh = validatorToScriptHash(adapterScript);

    const walletAddr = await this.lucid.wallet().address();
    const registry = await this.byNft(rec.protocolNft.policyId, rec.protocolNft.assetName, "the ProtocolNFT");
    const loan = await this.loanByOwner(target.loanNft.policyId, target.loanNft.assetName, target.loanOwnerNft.assetName);
    // The binding NFT rides the venue order until a batcher executes it, and
    // lands in the datum-free payout the venue pays back.
    let payout = await this.byNft(bindingNft.policyId, bindingNft.assetName, "the BindingNFT");
    for (let i = 0; payout.datum || payout.datumHash; i += 1) {
      if (i >= 60) throw new Error("the venue has not settled the order");
      if (i === 0) console.log("  waiting for the venue to settle the order");
      await new Promise((r) => setTimeout(r, 15_000));
      payout = await this.byNft(bindingNft.policyId, bindingNft.assetName, "the BindingNFT");
    }
    const loanRef = await resolve(rec.referenceScripts.loan, 0);
    const adapterRef = await resolve(rec.referenceScripts.adapter_minswap, 0);
    const fundingRow = this.leanest(await this.kupo(walletAddr), 1)[0];
    if (!fundingRow) throw new Error("no funding UTxO");
    const funding = await resolve(fundingRow.transaction_id, fundingRow.output_index);

    const ld = Data.from(loan.datum!) as Constr<any>;
    const claim = (ld.fields[4] as Constr<any>).fields[0] as Constr<any>;
    const longUnit = `${ACTIVE.collateral.policyId}${ACTIVE.collateral.assetName}`;
    const bindingUnit = toUnit(bindingNft.policyId, bindingNft.assetName);
    const loanNftUnit = toUnit(target.loanNft.policyId, target.loanNft.assetName);
    // §8.2.5 — `c` is what actually arrived, and §8.2.6 holds it above the floor
    // the claim itself names.
    const c = payout.assets[longUnit] ?? 0n;
    const floor = claim.fields[5] as bigint;
    if (c < floor) throw new Error(`the payout ${c} is below the claim's floor ${floor}`);
    const loanOutAda =
      BigInt(loan.assets["lovelace"]!) + BigInt(payout.assets["lovelace"]!) - MIN_ADA;

    const refs = [registry, loanRef, adapterRef];
    const sortedRefs = [...refs].sort((a, b) =>
      a.txHash === b.txHash ? a.outputIndex - b.outputIndex : (a.txHash < b.txHash ? -1 : 1));
    const refIdx = (u: UTxO) => BigInt(sortedRefs.findIndex(
      (r) => r.txHash === u.txHash && r.outputIndex === u.outputIndex));
    const all = [loan, payout, funding];
    const [loanIn, payoutIn] = getInputIndices([loan, payout], all) as bigint[];
    const OUT = { loan: 0n, tip: 1n };
    const protoRef = refIdx(registry);

    // `SettleClaim` is loan action index 1; `market_ref_idx` is unread on this arm.
    const loanRdmr = Data.to(new Constr(0, [
      [new Constr(1, [
        [new Constr(0, [loanIn!, OUT.loan, payoutIn!, OUT.tip])], -1n, adapterSkh,
      ])],
      protoRef,
    ]));
    // `Delivered` is route index 0, and the adapter reads no market on it.
    const adapterRdmr = Data.to(new Constr(0, [
      [new Constr(0, [
        target.loanOwnerNft.assetName,
        new Constr(0, [
          [ACTIVE.collateral.policyId, ACTIVE.collateral.assetName],
          c,
          new Constr(0, [[loanSkh, bindingNft.assetName]]),
        ]),
      ])],
      protoRef, -1n,
    ]));
    const loanOut = new Constr(0, [...ld.fields.slice(0, 4), new Constr(1, [])]);

    console.log(`  payout ${c} ${ACTIVE.collateral.assetName} against floor ${floor}`);
    console.log(`  loan_in=${loanIn} payout_in=${payoutIn} loan_out=0 tip_out=1 proto_ref=${protoRef}`);
    const { from, to } = this.window();
    const refBytes = sortedRefs.reduce((n, u) => n + (u.scriptRef ? u.scriptRef.script.length / 2 : 0), 0);

    this.lucid.overrideUTxOs([funding]);
    const tx = await this.retry("build settle-claim", () =>
      this.lucid
        .newTx()
        .setMinFee(1_500_000n + BigInt(Math.ceil(refBytes * 25)))
        .collectFrom([loan], loanRdmr)
        .collectFrom([payout], loanRdmr)
        .collectFrom([funding])
        .readFrom(sortedRefs)
        .mintAssets({ [bindingUnit]: -1n }, loanRdmr)
        .withdraw(validatorToRewardAddress(NETWORK, loanScript), 0n, loanRdmr)
        .withdraw(validatorToRewardAddress(NETWORK, adapterScript), 0n, adapterRdmr)
        .pay.ToContract(loan.address, { kind: "inline", value: Data.to(loanOut) },
          { lovelace: loanOutAda, [loanNftUnit]: 1n, [longUnit]: c })
        .pay.ToAddress(walletAddr, { lovelace: MIN_ADA })
        .validFrom(from)
        .validTo(to)
        .complete({ setCollateral: 15_000_000n }),
      2,
    );
    const hash = await this.submit("  settle-claim", tx);
    rec.settle = { tx: hash, collateral: c.toString(), floor: floor.toString() };
    await Bun.write(record, JSON.stringify(rec, null, 2) + "\n");
    console.log(`\nupdated ${record}`);
  }

  /// §9.3 `ModifyOrder` with `order_out_idx == -1` — the trader cancels.
  ///
  /// Authorisation is the burn itself: the arm requires `mint[order_skh]` to be
  /// `{ OrderNFT: -1, OrderOwnerNFT: -1 }`, and the owner NFT sits in the
  /// trader's wallet. Everything else the order held — here the
  /// `PositionOwnerNFT` a fill paid into it — is released to them.
  async cancelOrder(): Promise<void> {
    const record = `${OUT_FOLDER}/${NETWORK.toLowerCase()}.json`;
    const rec = await Bun.file(record).json();
    const orderRec = await this.liveOrder(rec);
    const nft: TupleAsset = [rec.protocolNft.policyId, rec.protocolNft.assetName];
    const orderScript = ours().order(nft);
    const walletAddr = await this.lucid.wallet().address();
    const registry = await this.byNft(rec.protocolNft.policyId, rec.protocolNft.assetName, "the ProtocolNFT");
    const order = await this.byNft(orderRec.orderNft.policyId, orderRec.orderNft.assetName, "the OrderNFT");
    const owner = await this.byNft(orderRec.ownerNft.policyId, orderRec.ownerNft.assetName, "the OrderOwnerNFT");
    const orderRef = await resolve(rec.referenceScripts.order, 0);

    const sortedRefs = [registry, orderRef].sort((a, b) =>
      a.txHash === b.txHash ? a.outputIndex - b.outputIndex : (a.txHash < b.txHash ? -1 : 1));
    const refIdx = (u: UTxO) => BigInt(sortedRefs.findIndex(
      (r) => r.txHash === u.txHash && r.outputIndex === u.outputIndex));
    // The owner NFT's own UTxO carries barely more than its minADA, so the fee
    // comes from elsewhere.
    const fundingRow = this.leanest(await this.kupo(walletAddr), 1)[0];
    if (!fundingRow) throw new Error("no funding UTxO");
    const funding = await resolve(fundingRow.transaction_id, fundingRow.output_index);
    const wallet = this.distinct([owner, funding]);
    const all = [order, ...wallet];
    const [orderIn] = getInputIndices([order], all) as bigint[];
    // Order action index 2, with every optional index absent — §5 rule 11a.
    const rdmr = Data.to(new Constr(0, [
      [new Constr(2, [orderIn!, -1n, -1n, -1n, -1n])], refIdx(registry),
    ]));
    const orderUnit = toUnit(orderRec.orderNft.policyId, orderRec.orderNft.assetName);
    const ownerUnit = toUnit(orderRec.ownerNft.policyId, orderRec.ownerNft.assetName);
    const released = Object.fromEntries(
      Object.entries(order.assets).filter(([u]) => u !== "lovelace" && u !== orderUnit),
    );
    console.log(`  order_in=${orderIn}, releasing ${Object.keys(released).length} token(s)`);
    const { from, to } = this.window();
    const refBytes = sortedRefs.reduce((n, u) => n + (u.scriptRef ? u.scriptRef.script.length / 2 : 0), 0);

    this.lucid.overrideUTxOs(wallet);
    const tx = await this.retry("build cancel-order", () =>
      this.lucid
        .newTx()
        .setMinFee(1_500_000n + BigInt(Math.ceil(refBytes * 25)))
        .collectFrom([order], rdmr)
        .collectFrom(wallet)
        .readFrom(sortedRefs)
        .mintAssets({ [orderUnit]: -1n, [ownerUnit]: -1n }, rdmr)
        .withdraw(validatorToRewardAddress(NETWORK, orderScript), 0n, rdmr)
        .pay.ToAddress(walletAddr, { lovelace: MIN_ADA, ...released })
        .validFrom(from)
        .validTo(to)
        .complete({ setCollateral: 15_000_000n }),
      2,
    );
    const hash = await this.submit("  cancel-order", tx);
    rec.orderCancelled = { tx: hash, released: Object.keys(released) };
    await Bun.write(record, JSON.stringify(rec, null, 2) + "\n");
    console.log(`\nupdated ${record}`);
  }

  /// §10.1 `RepayLoan` on a synchronous venue — the trader closes the position.
  ///
  /// The collateral leaves the protocol (§10.1.6: no protocol-script output may
  /// hold it) and the debt reaches the pool, so with the trader's own wallet as
  /// the venue this is a plain repay: pay `debt_now` in the supply token, take the
  /// collateral. The loan and the position are retired together — §10.1.8 — which
  /// is why the position script carries `ClosePosition` beside this arm.
  async repay(): Promise<void> {
    const record = `${OUT_FOLDER}/${NETWORK.toLowerCase()}.json`;
    const rec = await Bun.file(record).json();
    // §10.1 is the arm for a loan carrying **no** claim, which is the state a
    // settled claim leaves behind and equally the state a synchronous fill or
    // §7.6 opens in. The loan's own datum is checked below; the record only has
    // to say which loan.
    // A record keeps the last entry of every opening arm, so several of them name
    // loans that have since been closed. Ask the chain which is still open, and
    // skip any that carry a claim: §10.1 is the arm for a loan with none.
    const target = await this.liveLoan(rec, Deployer.unclaimed);
    if (!target) throw new Error("no loan recorded to repay");
    const nft: TupleAsset = [rec.protocolNft.policyId, rec.protocolNft.assetName];
    const v = ours();
    const built = { loan_repay: v.loan_repay(nft), position: v.position(nft), pool: v.pool(nft) };
    const walletAddr = await this.lucid.wallet().address();

    const registry = await this.byNft(rec.protocolNft.policyId, rec.protocolNft.assetName, "the ProtocolNFT");
    const loan = await this.loanByOwner(target.loanNft.policyId, target.loanNft.assetName, target.loanOwnerNft.assetName);
    if ((Data.from(loan.datum!) as Constr<any>).fields[4].index !== 1)
      throw new Error("this loan carries a claim; §10.2 is its arm, not §10.1");
    const position = await this.byNft(target.positionNft.policyId, target.positionNft.assetName, "the PositionNFT");
    const ownerName = target.loanOwnerNft.assetName;
    const positionOwnerName = ownerName + Buffer.from("OWN").toString("hex");
    const owner = await this.byNft(target.positionNft.policyId, positionOwnerName, "the PositionOwnerNFT");
    const holders = await this.kupo(
      `${rec[ACTIVE_KEY].marketNft.policyId}.${rec[ACTIVE_KEY].marketNft.assetName}`);
    const marketRow = holders.find((r) => r.address === rec[ACTIVE_KEY].marketAddress);
    const poolRow = holders.find((r) => r.address === rec[ACTIVE_KEY].poolAddress);
    if (!marketRow || !poolRow) throw new Error("market or pool UTxO not found");
    const market = await resolve(marketRow.transaction_id, marketRow.output_index);
    const pool = await resolve(poolRow.transaction_id, poolRow.output_index);
    const scriptRefs = await Promise.all(
      (["loan", "loan_repay", "position", "pool"] as const).map((n) => resolve(rec.referenceScripts[n], 0)));
    const fundingRow = this.leanest(await this.kupo(walletAddr), 1)[0];
    if (!fundingRow) throw new Error("no funding UTxO");
    const funding = await resolve(fundingRow.transaction_id, fundingRow.output_index);

    // ---------------------------------------------------------------- numbers
    const ld = Data.from(loan.datum!) as Constr<any>;
    const loanAmount = ld.fields[2] as bigint;
    const initialIndex = ld.fields[3] as bigint;
    const pd = Data.from(pool.datum!) as Constr<any>;
    const at = (i: number) => pd.fields[i] as bigint;
    const inSupply = at(0), inDtoken = at(1), inBorrow = at(2), inApy = at(3);
    const inFee = at(4), inIndex = at(5), inTime = at(6);
    const { from, to, startMs } = this.window();
    const outIndex = indexAt(inIndex, inApy, inTime, startMs);
    const accrued = inBorrow === 0n ? 0n : (inBorrow * (outIndex - inIndex)) / inIndex;
    const accruedFee = accrued === 0n ? 0n : ceilingDiv(accrued * ACTIVE.loanFeeRate, 10_000n);
    // §2.9 `debt_now`, which §10.1.4 retires in full.
    const debt = (loanAmount * outIndex) / initialIndex;
    const totalSupply = max0(inSupply + accrued - accruedFee);
    const totalBorrow = max0(inBorrow + accrued - debt);
    const outApy = borrowApy(ACTIVE.baseRate, ACTIVE.powerBase, totalSupply, totalBorrow);
    // §10.1 repays in the supply token, which is lovelace only where the market
    // lends ADA.
    const supplyUnit = `${ACTIVE.supplyToken.policyId}${ACTIVE.supplyToken.assetName}`;
    const poolOutAda = SUPPLY_IS_TOKEN
      ? BigInt(pool.assets["lovelace"]!)
      : BigInt(pool.assets["lovelace"]!) + debt;
    const poolOutSupply = SUPPLY_IS_TOKEN ? (pool.assets[supplyUnit] ?? 0n) + debt : 0n;
    const poolOut = new Constr(0, [
      totalSupply, inDtoken, totalBorrow, outApy, inFee + accruedFee,
      outIndex, startMs > inTime ? startMs : inTime, pd.fields[7], pd.fields[8],
    ]);

    const longUnit = `${ACTIVE.collateral.policyId}${ACTIVE.collateral.assetName}`;
    const collateral = loan.assets[longUnit] ?? 0n;
    const loanNftUnit = toUnit(target.loanNft.policyId, target.loanNft.assetName);
    const loanOwnerUnit = toUnit(target.loanNft.policyId, ownerName);
    const positionUnit = toUnit(target.positionNft.policyId, ownerName);
    const positionOwnerUnit = toUnit(target.positionNft.policyId, positionOwnerName);
    const marketUnit = toUnit(rec[ACTIVE_KEY].marketNft.policyId, rec[ACTIVE_KEY].marketNft.assetName);

    // ---------------------------------------------------------------- indices
    const refs = [registry, market, ...scriptRefs];
    const sortedRefs = [...refs].sort((a, b) =>
      a.txHash === b.txHash ? a.outputIndex - b.outputIndex : (a.txHash < b.txHash ? -1 : 1));
    const refIdx = (u: UTxO) => BigInt(sortedRefs.findIndex(
      (r) => r.txHash === u.txHash && r.outputIndex === u.outputIndex));
    const wallet = this.distinct([owner, funding]);
    const all = [loan, position, pool, ...wallet];
    const [loanIn, positionIn, ownerIn, poolIn] =
      getInputIndices([loan, position, owner, pool], all) as bigint[];
    const OUT = { trader: 0n, pool: 1n };
    const protoRef = refIdx(registry);
    const marketRef = refIdx(market);

    // `RepayLoan` is loan action index 2; `adapter_skh` is empty on §10.1, which
    // is what tells the arm no venue is involved.
    const loanRdmr = Data.to(new Constr(0, [
      [new Constr(2, [
        [new Constr(0, [
          positionIn!, ownerIn!, loanIn!, -1n, -1n, -1n, OUT.trader, -1n, -1n,
        ])],
        marketRef, -1n, poolIn!, OUT.pool, "",
      ])],
      protoRef,
    ]));
    // `ClosePosition` is position action index 3.
    const positionRdmr = Data.to(new Constr(0, [
      [new Constr(3, [[new Constr(0, [positionIn!, ownerIn!, loanIn!, -1n, -1n])]])],
      protoRef,
    ]));
    const poolRdmr = Data.to(new Constr(0, [
      [new Constr(0, [poolIn!, OUT.pool, marketRef, [ownerName]])], protoRef,
    ]));

    console.log(`  debt_now ${debt} against loan_amount ${loanAmount}, collateral ${collateral} returns`);
    console.log(`  pool ${inSupply}/${inBorrow} -> ${totalSupply}/${totalBorrow}, apy ${inApy} -> ${outApy}, ada ${pool.assets["lovelace"]} -> ${poolOutAda}`);
    console.log(`  loan_in=${loanIn} position_in=${positionIn} owner_in=${ownerIn} pool_in=${poolIn} trader_out=0 pool_out=1`);
    const refBytes = sortedRefs.reduce((n, u) => n + (u.scriptRef ? u.scriptRef.script.length / 2 : 0), 0);

    this.lucid.overrideUTxOs(wallet);
    const tx = await this.retry("build repay", () =>
      this.lucid
        .newTx()
        .setMinFee(2_000_000n + BigInt(Math.ceil(refBytes * 25)))
        .collectFrom([loan], loanRdmr)
        .collectFrom([position], positionRdmr)
        .collectFrom([pool], poolRdmr)
        .collectFrom(wallet)
        .readFrom(sortedRefs)
        .mintAssets({ [loanNftUnit]: -1n, [loanOwnerUnit]: -1n }, loanRdmr)
        .mintAssets({ [positionUnit]: -1n, [positionOwnerUnit]: -1n }, positionRdmr)
        .withdraw(validatorToRewardAddress(NETWORK, built.loan_repay), 0n, loanRdmr)
        .withdraw(validatorToRewardAddress(NETWORK, built.position), 0n, positionRdmr)
        .withdraw(validatorToRewardAddress(NETWORK, built.pool), 0n, poolRdmr)
        // §10.1.7 — both minADAs and everything that is not the collateral reach
        // the trader; the collateral may come here too, since §10.1.6 only bars it
        // from the protocol's own scripts.
        .pay.ToAddress(walletAddr, { lovelace: 2n * MIN_ADA, [longUnit]: collateral })
        .pay.ToContract(pool.address, { kind: "inline", value: Data.to(poolOut) },
          {
            lovelace: poolOutAda, [marketUnit]: 1n,
            ...(SUPPLY_IS_TOKEN ? { [supplyUnit]: poolOutSupply } : {}),
          })
        .validFrom(from)
        .validTo(to)
        .complete({ setCollateral: 15_000_000n }),
      2,
    );
    const hash = await this.submit("  repay", tx);
    rec.repay = { tx: hash, debt: debt.toString(), collateralReturned: collateral.toString() };
    await Bun.write(record, JSON.stringify(rec, null, 2) + "\n");
    console.log(`\nupdated ${record}`);
  }

  /// The market UTxO and the pool UTxO, which share the `MarketNFT` and are told
  /// apart by their address alone.
  private async marketPool(rec: any, key = "market"): Promise<{ market: UTxO; pool: UTxO }> {
    const m = rec[key];
    if (!m) throw new Error(`no ${key} recorded`);
    const holders = await this.kupo(`${m.marketNft.policyId}.${m.marketNft.assetName}`);
    const marketRow = holders.find((r) => r.address === m.marketAddress);
    const poolRow = holders.find((r) => r.address === m.poolAddress);
    if (!marketRow || !poolRow) throw new Error("market or pool UTxO not found on chain");
    return {
      market: await resolve(marketRow.transaction_id, marketRow.output_index),
      pool: await resolve(poolRow.transaction_id, poolRow.output_index),
    };
  }

  /// The pool datum's numbers, advanced to `tx_start` — the part every pool arm
  /// shares before it applies its own equations.
  private poolState(pool: UTxO, startMs: bigint, m: MarketParams = MARKET_ADA) {
    const pd = Data.from(pool.datum!) as Constr<any>;
    const at = (i: number) => pd.fields[i] as bigint;
    const inIndex = at(5);
    const outIndex = indexAt(inIndex, at(3), at(6), startMs);
    const accrued = at(2) === 0n ? 0n : (at(2) * (outIndex - inIndex)) / inIndex;
    return {
      pd,
      inSupply: at(0), inDtoken: at(1), inBorrow: at(2), inApy: at(3),
      inFee: at(4), inIndex, inTime: at(6),
      outIndex,
      accrued,
      accruedFee: accrued === 0n ? 0n : ceilingDiv(accrued * m.loanFeeRate, 10_000n),
      interestTime: startMs > at(6) ? startMs : at(6),
    };
  }

  /// §18 the withdrawing direction — `dToken` is burned and the supply token
  /// leaves. `withdrawal_fee` is zero in this market, so §18.8 requires **no** fee
  /// output, which is what `fee_out_idx == -1` says.
  async redeem(lovelace: bigint): Promise<void> {
    const record = `${OUT_FOLDER}/${NETWORK.toLowerCase()}.json`;
    const rec = await Bun.file(record).json();
    const nft: TupleAsset = [rec.protocolNft.policyId, rec.protocolNft.assetName];
    const poolScript = ours().pool(nft);
    const walletAddr = await this.lucid.wallet().address();
    const registry = await this.byNft(rec.protocolNft.policyId, rec.protocolNft.assetName, "the ProtocolNFT");
    const { market, pool } = await this.marketPool(rec, ACTIVE_KEY);
    const poolRef = await resolve(rec.referenceScripts.pool, 0);
    const dtokenUnit = toUnit(rec.registry.poolSkh, rec[ACTIVE_KEY].marketNft.assetName);
    const dtokenRow = (await this.kupo(`${rec.registry.poolSkh}.${rec[ACTIVE_KEY].marketNft.assetName}`))
      .find((r) => r.address === walletAddr);
    if (!dtokenRow) throw new Error("no dToken in this wallet");
    const dtoken = await resolve(dtokenRow.transaction_id, dtokenRow.output_index);
    // The dToken usually sits in the wallet's own change, so it funds the fee
    // itself; a second input is added only when it cannot.
    const fundingRow = this.leanest(await this.kupo(walletAddr), 8)
      .find((r) => r.transaction_id !== dtoken.txHash || r.output_index !== dtoken.outputIndex);
    const walletIns = [dtoken];
    if (fundingRow) {
      walletIns.push(await resolve(fundingRow.transaction_id, fundingRow.output_index));
    } else if (BigInt(dtoken.assets["lovelace"] ?? 0n) < 20_000_000n) {
      throw new Error("no wallet UTxO with enough ADA to pay the fee");
    }

    const { from, to, startMs } = this.window();
    const st = this.poolState(pool, startMs, ACTIVE);
    const supplyBefore = st.inSupply + st.accrued - st.accruedFee;
    // §18.3 — the sign follows the value leaving, and the denominator is the
    // supply as it stood before this transaction.
    const changed = -lovelace;
    const dtokenQty =
      supplyBefore === 0n || st.inDtoken === 0n
        ? changed
        : floorDiv(changed * st.inDtoken, supplyBefore);
    if (dtokenQty === 0n) throw new Error("the dToken quantity floors to zero");
    const totalSupply = max0(supplyBefore + changed);
    const totalBorrow = max0(st.inBorrow + st.accrued);
    const poolOut = new Constr(0, [
      totalSupply, st.inDtoken + dtokenQty, totalBorrow,
      borrowApy(ACTIVE.baseRate, ACTIVE.powerBase, totalSupply, totalBorrow),
      st.inFee + st.accruedFee, st.outIndex, st.interestTime,
      st.pd.fields[7], st.pd.fields[8],
    ]);
    const marketUnit = toUnit(rec[ACTIVE_KEY].marketNft.policyId, rec[ACTIVE_KEY].marketNft.assetName);
    const poolOutAda = BigInt(pool.assets["lovelace"]!) - lovelace;

    const refs = [registry, market, poolRef];
    const sortedRefs = [...refs].sort((a, b) =>
      a.txHash === b.txHash ? a.outputIndex - b.outputIndex : (a.txHash < b.txHash ? -1 : 1));
    const refIdx = (u: UTxO) => BigInt(sortedRefs.findIndex(
      (r) => r.txHash === u.txHash && r.outputIndex === u.outputIndex));
    const all = [pool, ...walletIns];
    const [poolIn] = getInputIndices([pool], all) as bigint[];
    // `TopupWithdraw` is pool action index 2.
    const rdmr = Data.to(new Constr(0, [
      [new Constr(2, [poolIn!, 0n, refIdx(market), -1n])], refIdx(registry),
    ]));
    console.log(`  withdrawing ${lovelace}, burning ${-dtokenQty} dToken`);
    console.log(`  supply ${st.inSupply} -> ${totalSupply}, dToken ${st.inDtoken} -> ${st.inDtoken + dtokenQty}`);
    const refBytes = sortedRefs.reduce((n, u) => n + (u.scriptRef ? u.scriptRef.script.length / 2 : 0), 0);

    this.lucid.overrideUTxOs(walletIns);
    const tx = await this.retry("build redeem", () =>
      this.lucid
        .newTx()
        .setMinFee(1_500_000n + BigInt(Math.ceil(refBytes * 25)))
        .collectFrom([pool], rdmr)
        .collectFrom(walletIns)
        .readFrom(sortedRefs)
        .mintAssets({ [dtokenUnit]: dtokenQty }, rdmr)
        .withdraw(validatorToRewardAddress(NETWORK, poolScript), 0n, rdmr)
        .pay.ToContract(pool.address, { kind: "inline", value: Data.to(poolOut) },
          { lovelace: poolOutAda, [marketUnit]: 1n })
        .validFrom(from)
        .validTo(to)
        .complete({ setCollateral: 15_000_000n }),
      2,
    );
    const hash = await this.submit("  redeem", tx);
    rec.redeem = { tx: hash, lovelace: lovelace.toString(), dtokenBurned: (-dtokenQty).toString() };
    await Bun.write(record, JSON.stringify(rec, null, 2) + "\n");
    console.log(`\nupdated ${record}`);
  }

  /// §19 `WithdrawFee` — the admin takes what has accrued as protocol fee.
  ///
  /// Bounded by `undistributed_fee + accrued_fee` and paid to `market.fee_address`,
  /// and what is left behind stays fee — §19.4.
  async withdrawFee(): Promise<void> {
    const record = `${OUT_FOLDER}/${NETWORK.toLowerCase()}.json`;
    const rec = await Bun.file(record).json();
    const nft: TupleAsset = [rec.protocolNft.policyId, rec.protocolNft.assetName];
    const poolScript = ours().pool(nft);
    const { registry, admin, funding, walletAddr } = await this.adminContext(rec);
    const { market, pool } = await this.marketPool(rec, ACTIVE_KEY);
    const poolRef = await resolve(rec.referenceScripts.pool, 0);

    const { from, to, startMs } = this.window();
    const st = this.poolState(pool, startMs, ACTIVE);
    const platformFee = st.inFee + st.accruedFee;
    if (platformFee <= 0n) throw new Error("no fee has accrued yet");
    const changed = -platformFee;
    const totalSupply = max0(st.inSupply + st.accrued - st.accruedFee);
    const totalBorrow = max0(st.inBorrow + st.accrued);
    const poolOut = new Constr(0, [
      totalSupply, st.inDtoken, totalBorrow,
      borrowApy(ACTIVE.baseRate, ACTIVE.powerBase, totalSupply, totalBorrow),
      platformFee + changed, st.outIndex, st.interestTime,
      st.pd.fields[7], st.pd.fields[8],
    ]);
    const marketUnit = toUnit(rec[ACTIVE_KEY].marketNft.policyId, rec[ACTIVE_KEY].marketNft.assetName);
    const adminUnit = toUnit(rec.adminNft.policyId, rec.adminNft.assetName);
    const supplyUnit = `${ACTIVE.supplyToken.policyId}${ACTIVE.supplyToken.assetName}`;
    const poolOutAda = SUPPLY_IS_TOKEN
      ? BigInt(pool.assets["lovelace"]!)
      : BigInt(pool.assets["lovelace"]!) - platformFee;
    const poolOutSupply = SUPPLY_IS_TOKEN
      ? (pool.assets[supplyUnit] ?? 0n) - platformFee
      : 0n;

    const refs = [registry, market, poolRef];
    const sortedRefs = [...refs].sort((a, b) =>
      a.txHash === b.txHash ? a.outputIndex - b.outputIndex : (a.txHash < b.txHash ? -1 : 1));
    const refIdx = (u: UTxO) => BigInt(sortedRefs.findIndex(
      (r) => r.txHash === u.txHash && r.outputIndex === u.outputIndex));
    const wallet = this.distinct([admin, funding]);
    const all = [pool, ...wallet];
    const [poolIn, adminIn] = getInputIndices([pool, admin], all) as bigint[];
    // `WithdrawFee` is pool action index 3.
    const rdmr = Data.to(new Constr(0, [
      [new Constr(3, [poolIn!, 0n, adminIn!, refIdx(market), 1n])], refIdx(registry),
    ]));
    console.log(`  taking ${platformFee} of fee to the market's fee address`);
    const refBytes = sortedRefs.reduce((n, u) => n + (u.scriptRef ? u.scriptRef.script.length / 2 : 0), 0);

    this.lucid.overrideUTxOs(wallet);
    const tx = await this.retry("build withdraw-fee", () =>
      this.lucid
        .newTx()
        .setMinFee(1_500_000n + BigInt(Math.ceil(refBytes * 25)))
        .collectFrom([pool], rdmr)
        .collectFrom(wallet)
        .readFrom(sortedRefs)
        .withdraw(validatorToRewardAddress(NETWORK, poolScript), 0n, rdmr)
        .pay.ToContract(pool.address, { kind: "inline", value: Data.to(poolOut) },
          {
            lovelace: poolOutAda, [marketUnit]: 1n,
            ...(SUPPLY_IS_TOKEN ? { [supplyUnit]: poolOutSupply } : {}),
          })
        // §19.7 — the fee output sits at `market.fee_address` and holds nothing
        // but the supply token, which is lovelace only where ADA is lent.
        .pay.ToAddress(
          walletAddr,
          SUPPLY_IS_TOKEN
            ? { lovelace: MIN_ADA, [supplyUnit]: platformFee }
            : { lovelace: platformFee })
        .pay.ToAddress(walletAddr, { [adminUnit]: 1n })
        .validFrom(from)
        .validTo(to)
        .complete({ setCollateral: 15_000_000n }),
      2,
    );
    const hash = await this.submit("  withdraw-fee", tx);
    rec.withdrawFee = { tx: hash, taken: platformFee.toString() };
    await Bun.write(record, JSON.stringify(rec, null, 2) + "\n");
    console.log(`\nupdated ${record}`);
  }

  /// §7.3 — the synchronous fill. The filler delivers the collateral out of their
  /// own pocket and takes the margin and the loan proceeds; no venue, no claim, no
  /// oracle. `adapter_sync_generic` is the adapter that says exactly that.
  ///
  /// The collateral delivered is the least §7.3.2 admits, which at a limit price
  /// above the oracle's own rate opens the loan already unhealthy — that is how
  /// §11 becomes reachable at all.
  async fillSync(): Promise<void> {
    const record = `${OUT_FOLDER}/${NETWORK.toLowerCase()}.json`;
    const rec = await Bun.file(record).json();
    const orderRec = await this.liveOrder(rec);
    const nft: TupleAsset = [rec.protocolNft.policyId, rec.protocolNft.assetName];
    const v = ours();
    const built = {
      order: v.order(nft), pool: v.pool(nft), loan: v.loan(nft),
      position: v.position(nft), adapter_sync_generic: v.adapter_sync_generic(nft),
    };
    const skh = Object.fromEntries(Object.entries(built).map(([n, s]) =>
      [n, validatorToScriptHash(s)])) as Record<keyof typeof built, string>;

    const walletAddr = await this.lucid.wallet().address();
    const stake = getAddressDetails(walletAddr).stakeCredential;
    const registry = await this.byNft(rec.protocolNft.policyId, rec.protocolNft.assetName, "the ProtocolNFT");
    const { market, pool } = await this.marketPool(rec, ACTIVE_KEY);
    const order = await this.byNft(orderRec.orderNft.policyId, orderRec.orderNft.assetName, "the OrderNFT");
    const scriptRefs = await Promise.all((Object.keys(built) as (keyof typeof built)[])
      .map((n) => resolve(rec.referenceScripts[n], 0)));
    const longUnit = `${ACTIVE.collateral.policyId}${ACTIVE.collateral.assetName}`;
    const collateralRow = (await this.kupo(
      `${ACTIVE.collateral.policyId}.${ACTIVE.collateral.assetName}`))
      .find((r) => r.address === walletAddr);
    if (!collateralRow) throw new Error("no collateral in this wallet to deliver");
    const collateralIn = await resolve(collateralRow.transaction_id, collateralRow.output_index);
    const seedRow = this.leanest(await this.kupo(walletAddr), 1)[0];
    if (!seedRow) throw new Error("no funding UTxO to seed the fill");
    const seed = await resolve(seedRow.transaction_id, seedRow.output_index);

    // ---------------------------------------------------------------- numbers
    const od = Data.from(order.datum!) as Constr<any>;
    const shortAmount = od.fields[2] as bigint;
    const limit = od.fields[3] as Constr<any>;
    const feeReserve = od.fields[12] as bigint;
    const { from, to, startMs } = this.window();
    const st = this.poolState(pool, startMs, ACTIVE);
    // The margin is whatever the order holds of the supply token, net of what is
    // structural: minADA and the reserve, which are lovelace on every market.
    const supplyUnit = `${ACTIVE.supplyToken.policyId}${ACTIVE.supplyToken.assetName}`;
    const margin = SUPPLY_IS_TOKEN
      ? (order.assets[supplyUnit] ?? 0n)
      : BigInt(order.assets["lovelace"]!) - feeReserve - MIN_ADA;
    const tbv = shortAmount - margin;
    const loanAmount = tbv;
    const nlp = netLoanProceeds(loanAmount, ACTIVE.loanOriginationFeeRate, ACTIVE.loanOriginationFeeMinAmount);
    const shortFromOrderIn = depositQty(margin, loanAmount, tbv);
    // §7.3.2 — the ceiling term, plus whatever collateral the order brought with
    // it. §7.2.16 releases the order's own share pro rata and §7.3.2 credits it
    // against what the executor has to deliver, so only the difference comes out
    // of this wallet.
    const longFromOrderIn = depositQty(order.assets[longUnit] ?? 0n, loanAmount, tbv);
    const amount = longFromOrderIn
      + limitFloor(shortFromOrderIn + nlp, limit.fields[0] as bigint, limit.fields[1] as bigint);
    const deliver = amount - longFromOrderIn;
    const have = collateralIn.assets[longUnit] ?? 0n;
    if (have < deliver) throw new Error(`need ${deliver} collateral to deliver, hold ${have}`);
    if (longFromOrderIn > 0n)
      console.log(`  the order brought ${longFromOrderIn}; this wallet delivers ${deliver}`);

    const totalSupply = max0(st.inSupply + st.accrued - st.accruedFee);
    const totalBorrow = max0(st.inBorrow + st.accrued + loanAmount);
    const outApy = borrowApy(ACTIVE.baseRate, ACTIVE.powerBase, totalSupply, totalBorrow);
    if (ACTIVE.utilCap * totalSupply <= totalBorrow * 10_000n) {
      throw new Error(`util cap: ${ACTIVE.utilCap} * ${totalSupply} <= ${totalBorrow} * 10000`);
    }
    // What the pool lends leaves in the supply token, which is only lovelace where
    // the market's supply token is ADA. §7.3 is otherwise identical either way.
    const poolOutAda = SUPPLY_IS_TOKEN
      ? BigInt(pool.assets["lovelace"]!)
      : BigInt(pool.assets["lovelace"]!) - nlp;
    const poolOutSupply = SUPPLY_IS_TOKEN ? (pool.assets[supplyUnit] ?? 0n) - nlp : 0n;
    // §7.2.16 draws the order's margin pro rata; on a token market what is left of
    // it stays on the order as a token rather than as lovelace.
    const orderOutSupply = SUPPLY_IS_TOKEN ? margin - shortFromOrderIn : 0n;

    const seedName = hashUtxo(seed, blake2b224);
    const hex = (s: string) => Buffer.from(s).toString("hex");
    const positionOwnerName = seedName + hex("OWN");
    const loanNftUnit = toUnit(skh.loan, rec[ACTIVE_KEY].marketNft.assetName);
    const loanOwnerUnit = toUnit(skh.loan, seedName);
    const positionUnit = toUnit(skh.position, seedName);
    const positionOwnerUnit = toUnit(skh.position, positionOwnerName);
    const orderUnit = toUnit(orderRec.orderNft.policyId, orderRec.orderNft.assetName);
    const marketUnit = toUnit(rec[ACTIVE_KEY].marketNft.policyId, rec[ACTIVE_KEY].marketNft.assetName);

    const refs = [registry, market, ...scriptRefs];
    const sortedRefs = [...refs].sort((a, b) =>
      a.txHash === b.txHash ? a.outputIndex - b.outputIndex : (a.txHash < b.txHash ? -1 : 1));
    const refIdx = (u: UTxO) => BigInt(sortedRefs.findIndex(
      (r) => r.txHash === u.txHash && r.outputIndex === u.outputIndex));
    const walletIns = [seed, ...(collateralIn.txHash === seed.txHash && collateralIn.outputIndex === seed.outputIndex ? [] : [collateralIn])];
    const all = [order, pool, ...walletIns];
    const [orderIn, poolIn, seedIn] = getInputIndices([order, pool, seed], all) as bigint[];
    const OUT = { order: 0n, position: 1n, loan: 2n, pool: 3n };
    const protoRef = refIdx(registry);
    const marketRef = refIdx(market);

    // `execution_tip_idx` is `-1`: §7.3.4 pays no tip, so §7.2.13 debits no reserve.
    const orderRdmr = Data.to(new Constr(0, [
      [new Constr(1, [
        [new Constr(0, [orderIn!, OUT.order, OUT.position, OUT.loan, seedIn!, -1n])],
        marketRef, poolIn!, OUT.pool, skh.adapter_sync_generic,
      ])],
      protoRef,
    ]));
    const poolRdmr = Data.to(new Constr(0, [
      [new Constr(0, [poolIn!, OUT.pool, marketRef, [seedName]])], protoRef,
    ]));
    const loanRdmr = Data.to(new Constr(0, [
      [new Constr(0, [
        [new Constr(0, [orderIn!, OUT.loan, OUT.position, seedIn!])],
        marketRef, poolIn!, OUT.pool, skh.adapter_sync_generic,
      ])],
      protoRef,
    ]));
    const positionRdmr = Data.to(new Constr(0, [
      [new Constr(0, [seedIn!, OUT.position])], protoRef,
    ]));
    // `Delivered` is route index 0, and it carries no binding NFT — §7.3.4.
    const adapterRdmr = Data.to(new Constr(0, [
      [new Constr(0, [
        seedName,
        new Constr(0, [
          [ACTIVE.collateral.policyId, ACTIVE.collateral.assetName],
          amount,
          new Constr(1, []),
        ]),
      ])],
      protoRef, -1n,
    ]));

    const orderOut = new Constr(0, [
      ...od.fields.slice(0, 2), shortAmount - loanAmount - shortFromOrderIn,
      ...od.fields.slice(3, 12), feeReserve,
    ]);
    const positionOut = new Constr(0, [
      od.fields[0], od.fields[4], od.fields[6], od.fields[7], od.fields[11],
    ]);
    const loanOut = new Constr(0, [
      new Constr(0, [[skh.loan, seedName]]),
      od.fields[1], loanAmount, st.outIndex, new Constr(1, []),
    ]);
    const poolOut = new Constr(0, [
      totalSupply, st.inDtoken, totalBorrow, outApy,
      st.inFee + loanAmount - nlp + st.accruedFee,
      st.outIndex, st.interestTime, st.pd.fields[7], st.pd.fields[8],
    ]);

    console.log(`  loan ${loanAmount} of ${shortAmount}, nlp ${nlp}, delivering ${amount} collateral at limit ${limit.fields[0]}/${limit.fields[1]}`);
    console.log(`  pool ${st.inSupply}/${st.inBorrow} -> ${totalSupply}/${totalBorrow}, apy ${st.inApy} -> ${outApy}`);
    console.log(`  order_in=${orderIn} pool_in=${poolIn} seed=${seedIn} market_ref=${marketRef} proto_ref=${protoRef}`);
    const refBytes = sortedRefs.reduce((n, u) => n + (u.scriptRef ? u.scriptRef.script.length / 2 : 0), 0);

    this.lucid.overrideUTxOs(walletIns);
    const tx = await this.retry("build fill-sync", () =>
      this.lucid
        .newTx()
        .setMinFee(2_000_000n + BigInt(Math.ceil(refBytes * 25)))
        .collectFrom([order], orderRdmr)
        .collectFrom([pool], poolRdmr)
        .collectFrom(walletIns)
        .readFrom(sortedRefs)
        .mintAssets({ [loanNftUnit]: 1n, [loanOwnerUnit]: 1n }, loanRdmr)
        .mintAssets({ [positionUnit]: 1n, [positionOwnerUnit]: 1n }, positionRdmr)
        .withdraw(validatorToRewardAddress(NETWORK, built.order), 0n, orderRdmr)
        .withdraw(validatorToRewardAddress(NETWORK, built.pool), 0n, poolRdmr)
        .withdraw(validatorToRewardAddress(NETWORK, built.loan), 0n, loanRdmr)
        .withdraw(validatorToRewardAddress(NETWORK, built.position), 0n, positionRdmr)
        .withdraw(validatorToRewardAddress(NETWORK, built.adapter_sync_generic), 0n, adapterRdmr)
        .pay.ToContract(order.address, { kind: "inline", value: Data.to(orderOut) },
          {
            lovelace: MIN_ADA + feeReserve, [orderUnit]: 1n, [positionOwnerUnit]: 1n,
            ...(SUPPLY_IS_TOKEN && orderOutSupply > 0n ? { [supplyUnit]: orderOutSupply } : {}),
          })
        .pay.ToContract(validatorToAddress(NETWORK, built.position, stake),
          { kind: "inline", value: Data.to(positionOut) },
          { lovelace: MIN_ADA, [positionUnit]: 1n, [loanOwnerUnit]: 1n })
        .pay.ToContract(validatorToAddress(NETWORK, built.loan, stake),
          { kind: "inline", value: Data.to(loanOut) },
          { lovelace: MIN_ADA, [loanNftUnit]: 1n, [longUnit]: amount })
        .pay.ToContract(pool.address, { kind: "inline", value: Data.to(poolOut) },
          {
            lovelace: poolOutAda, [marketUnit]: 1n,
            ...(SUPPLY_IS_TOKEN ? { [supplyUnit]: poolOutSupply } : {}),
          })
        .validFrom(from)
        .validTo(to)
        .complete({ setCollateral: 15_000_000n }),
      2,
    );
    const hash = await this.submit("  fill-sync", tx);
    rec.fillSync = {
      tx: hash,
      loanAmount: loanAmount.toString(),
      collateral: amount.toString(),
      limitPrice: `${limit.fields[0]}/${limit.fields[1]}`,
      loanNft: { policyId: skh.loan, assetName: rec[ACTIVE_KEY].marketNft.assetName },
      loanOwnerNft: { policyId: skh.loan, assetName: seedName },
      positionNft: { policyId: skh.position, assetName: seedName },
    };
    rec.loans = Deployer.remember(
      rec.loans, { arm: "fill-sync", market: MARKET_KEY, ...rec.fillSync }, "loanOwnerNft");
    await Bun.write(record, JSON.stringify(rec, null, 2) + "\n");
    console.log(`\nupdated ${record}`);
  }


  /// §7.6 `OpenDirect` — the loan a borrower opens against collateral they
  /// already hold.
  ///
  /// §7.2 exists because the venue buys the collateral on the borrower's behalf,
  /// so the order states the price and the slippage the fill has to honour. A
  /// borrower who deposits the collateral themselves buys nothing, and none of
  /// those terms has anything to say about the loan that results — so this arm
  /// asks for no order, no venue, no adapter and no claim. What it keeps is
  /// everything that protects the pool: §3's health gate at the oracle's price,
  /// `min_tx_amount`, the pool's own index, and the origination fee.
  async borrow(collateral: bigint, wantLoan?: bigint | "max"): Promise<void> {
    const record = `${OUT_FOLDER}/${NETWORK.toLowerCase()}.json`;
    const rec = await Bun.file(record).json();
    const nft: TupleAsset = [rec.protocolNft.policyId, rec.protocolNft.assetName];
    const v = ours();
    const built = { pool: v.pool(nft), loan: v.loan(nft), position: v.position(nft) };
    const skh = Object.fromEntries(Object.entries(built).map(([n, s]) =>
      [n, validatorToScriptHash(s)])) as Record<keyof typeof built, string>;

    const walletAddr = await this.lucid.wallet().address();
    const stake = getAddressDetails(walletAddr).stakeCredential;
    const registry = await this.byNft(rec.protocolNft.policyId, rec.protocolNft.assetName, "the ProtocolNFT");
    const { market, pool } = await this.marketPool(rec, ACTIVE_KEY);
    const scriptRefs = await Promise.all((["pool", "loan", "position"] as const)
      .map((n) => resolve(rec.referenceScripts[n], 0)));

    const longUnit = `${ACTIVE.collateral.policyId}${ACTIVE.collateral.assetName}`;
    const longDotted = `${ACTIVE.collateral.policyId}.${ACTIVE.collateral.assetName}`;
    const supplyUnit = `${ACTIVE.supplyToken.policyId}${ACTIVE.supplyToken.assetName}`;
    const supplyDotted = ACTIVE.supplyToken.policyId === ""
      ? "" : `${ACTIVE.supplyToken.policyId}.${ACTIVE.supplyToken.assetName}`;
    const oracle = await oracleWithdrawal(supplyDotted, [longDotted]);
    const price = oracle.quotes[0]!;

    // The borrower's own collateral, and a lean UTxO whose hash names both NFTs.
    const collateralRow = (await this.kupo(longDotted)).find((r) => r.address === walletAddr);
    if (!collateralRow) throw new Error("no collateral in this wallet to deposit");
    const collateralIn = await resolve(collateralRow.transaction_id, collateralRow.output_index);
    const have = collateralIn.assets[longUnit] ?? 0n;
    if (have < collateral) throw new Error(`need ${collateral} collateral, this UTxO holds ${have}`);
    const seedRow = this.leanest(await this.kupo(walletAddr), 1)[0];
    if (!seedRow) throw new Error("no funding UTxO to seed the loan");
    const seed = await resolve(seedRow.transaction_id, seedRow.output_index);

    // ---------------------------------------------------------------- numbers
    const { from, to, startMs } = this.window();
    const st = this.poolState(pool, startMs, ACTIVE);
    // §2.12a on a loan holding one asset. `weigh` floors, and the loan's own
    // minADA never counts: `net` subtracts it, which leaves nothing to weigh even
    // where ADA is the supply token and so admitted to the domain.
    const worth = (collateral * price.numerator * ACTIVE.collateral.liquidationThreshold)
      / (price.denominator * 10_000n);
    // Two ceilings bind, and the default has to respect both: §3 on the
    // collateral, and §7.2.23's utilisation cap on the pool. Collateral worth far
    // more than the pool can lend is the common case on a demo pool, and asking
    // §3 alone produces a loan the cap then refuses.
    const totalSupply = max0(st.inSupply + st.accrued - st.accruedFee);
    const borrowedNow = max0(st.inBorrow + st.accrued);
    const utilRoom = max0((ACTIVE.utilCap * totalSupply) / 10_000n - borrowedNow);
    const byHealth = worth / 2n;
    const byUtil = (utilRoom * 9n) / 10n;
    const loanAmount =
      wantLoan === "max" ? worth : wantLoan ?? (byHealth < byUtil ? byHealth : byUtil);
    if (loanAmount > worth)
      throw new Error(`§3: this collateral is worth ${worth}, asked to lend ${loanAmount}`);
    if (loanAmount < ACTIVE.minTxAmount)
      throw new Error(
        `§7.6.3: loan ${loanAmount} is below min_tx_amount ${ACTIVE.minTxAmount}`
        + ` (§3 admits ${worth}, the pool has room for ${utilRoom})`);
    const nlp = netLoanProceeds(loanAmount, ACTIVE.loanOriginationFeeRate, ACTIVE.loanOriginationFeeMinAmount);

    const totalBorrow = max0(st.inBorrow + st.accrued + loanAmount);
    const outApy = borrowApy(ACTIVE.baseRate, ACTIVE.powerBase, totalSupply, totalBorrow);
    if (ACTIVE.utilCap * totalSupply <= totalBorrow * 10_000n)
      throw new Error(`util cap: ${ACTIVE.utilCap} * ${totalSupply} <= ${totalBorrow} * 10000`);
    const poolOutAda = SUPPLY_IS_TOKEN
      ? BigInt(pool.assets["lovelace"]!)
      : BigInt(pool.assets["lovelace"]!) - nlp;
    const poolOutSupply = SUPPLY_IS_TOKEN ? (pool.assets[supplyUnit] ?? 0n) - nlp : 0n;

    const seedName = hashUtxo(seed, blake2b224);
    const hex = (s: string) => Buffer.from(s).toString("hex");
    const positionOwnerName = seedName + hex("OWN");
    const marketNftName = rec[ACTIVE_KEY].marketNft.assetName;
    const loanNftUnit = toUnit(skh.loan, marketNftName);
    const loanOwnerUnit = toUnit(skh.loan, seedName);
    const positionUnit = toUnit(skh.position, seedName);
    const positionOwnerUnit = toUnit(skh.position, positionOwnerName);
    const marketUnit = toUnit(rec[ACTIVE_KEY].marketNft.policyId, marketNftName);

    // A venue pool can be one of the oracle's own price sources — the Minswap
    // pool this fill trades against is exactly where the fBTC/fUSDM rate comes
    // from — and a reference input named twice is still one reference input. The
    // ledger dedupes it, so indices taken over a list that does not are off by
    // one for everything past the repeat.
    const refs = this.distinct([registry, market, ...scriptRefs, ...oracle.refs]);
    const sortedRefs = [...refs].sort((a, b) =>
      a.txHash === b.txHash ? a.outputIndex - b.outputIndex : (a.txHash < b.txHash ? -1 : 1));
    const refIdx = (u: UTxO) => BigInt(sortedRefs.findIndex(
      (r) => r.txHash === u.txHash && r.outputIndex === u.outputIndex));
    if (Bun.env["DEBUG_REFS"]) {
      console.log(`  refs(${sortedRefs.length}): ` + sortedRefs.map((u, i) =>
        `${i}:${u.txHash.slice(0, 8)}#${u.outputIndex}${u.scriptRef ? "*" : ""}`).join(" "));
      const rd = oracle.redeemerFor(refIdx) as any;
      const flat = (x: any): string => Array.isArray(x)
        ? "[" + x.map(flat).join(",") + "]"
        : (x && typeof x === "object" && "index" in x ? `C${x.index}` : String(x));
      console.log(`  oracle rdmr: cfg=${flat(rd.fields[0])} paths=${flat(rd.fields[1])} srcs=${flat(rd.fields[2])}`);
    }
    const walletIns = this.distinct([seed, collateralIn]);
    const all = this.distinct([pool, ...walletIns]);
    const [poolIn, seedIn] = getInputIndices([pool, seed], all) as bigint[];
    const OUT = { position: 0n, loan: 1n, pool: 2n };
    const protoRef = refIdx(registry);
    const marketRef = refIdx(market);

    // `OpenDirect` is loan action index 6. §7.6.1 admits no adapter, so unlike
    // every other opening redeemer this one names no adapter script hash.
    const loanRdmr = Data.to(new Constr(0, [
      [new Constr(6, [
        [new Constr(0, [OUT.loan, OUT.position, seedIn!])],
        marketRef, OUT.pool,
      ])],
      protoRef,
    ]));
    const poolRdmr = Data.to(new Constr(0, [
      [new Constr(0, [poolIn!, OUT.pool, marketRef, [seedName]])], protoRef,
    ]));
    const positionRdmr = Data.to(new Constr(0, [
      [new Constr(0, [seedIn!, OUT.position])], protoRef,
    ]));

    // `take_profit_price` is `0/1` — the same "unset" the order datum writes, and
    // what §16 later moves. The beneficiary is the borrower.
    const positionOut = new Constr(0, [
      [ACTIVE.collateral.policyId, ACTIVE.collateral.assetName],
      new Constr(0, [0n, 1n]),
      ORDER.minExecutionAmount,
      ORDER.maxSlippage,
      addressData(walletAddr),
    ]);
    const loanOut = new Constr(0, [
      new Constr(0, [[skh.loan, seedName]]),
      [ACTIVE.supplyToken.policyId, ACTIVE.supplyToken.assetName],
      loanAmount, st.outIndex, new Constr(1, []),
    ]);
    const poolOut = new Constr(0, [
      totalSupply, st.inDtoken, totalBorrow, outApy,
      st.inFee + loanAmount - nlp + st.accruedFee,
      st.outIndex, st.interestTime, st.pd.fields[7], st.pd.fields[8],
    ]);

    console.log(`  oracle ${price.numerator}/${price.denominator}`);
    console.log(`  ${collateral} collateral is worth ${worth}; lending ${loanAmount}, borrower receives ${nlp}`);
    console.log(`  pool ${st.inSupply}/${st.inBorrow} -> ${totalSupply}/${totalBorrow}, apy ${st.inApy} -> ${outApy}`);
    console.log(`  pool_in=${poolIn} seed=${seedIn} market_ref=${marketRef} proto_ref=${protoRef}`);
    const refBytes = sortedRefs.reduce((n, u) => n + (u.scriptRef ? u.scriptRef.script.length / 2 : 0), 0);

    this.lucid.overrideUTxOs(walletIns);
    const tx = await this.retry("build borrow", () =>
      this.lucid
        .newTx()
        .setMinFee(2_000_000n + BigInt(Math.ceil(refBytes * 25)))
        .collectFrom([pool], poolRdmr)
        .collectFrom(walletIns)
        .readFrom(sortedRefs)
        .mintAssets({ [loanNftUnit]: 1n, [loanOwnerUnit]: 1n }, loanRdmr)
        .mintAssets({ [positionUnit]: 1n, [positionOwnerUnit]: 1n }, positionRdmr)
        .withdraw(validatorToRewardAddress(NETWORK, built.pool), 0n, poolRdmr)
        .withdraw(validatorToRewardAddress(NETWORK, built.loan), 0n, loanRdmr)
        .withdraw(validatorToRewardAddress(NETWORK, built.position), 0n, positionRdmr)
        .withdraw(oracleRewardAddress(NETWORK), 0n, Data.to(oracle.redeemerFor(refIdx)))
        .pay.ToContract(validatorToAddress(NETWORK, built.position, stake),
          { kind: "inline", value: Data.to(positionOut) },
          { lovelace: MIN_ADA, [positionUnit]: 1n, [loanOwnerUnit]: 1n })
        .pay.ToContract(validatorToAddress(NETWORK, built.loan, stake),
          { kind: "inline", value: Data.to(loanOut) },
          { lovelace: MIN_ADA, [loanNftUnit]: 1n, [longUnit]: collateral })
        .pay.ToContract(pool.address, { kind: "inline", value: Data.to(poolOut) },
          {
            lovelace: poolOutAda, [marketUnit]: 1n,
            ...(SUPPLY_IS_TOKEN ? { [supplyUnit]: poolOutSupply } : {}),
          })
        .validFrom(from)
        .validTo(to)
        .complete({ setCollateral: 15_000_000n }),
      2,
    );
    const hash = await this.submit("  borrow", tx);
    rec.openDirect = {
      tx: hash,
      market: MARKET_KEY,
      loanAmount: loanAmount.toString(),
      collateral: collateral.toString(),
      proceeds: nlp.toString(),
      oraclePrice: `${price.numerator}/${price.denominator}`,
      loanNft: { policyId: skh.loan, assetName: marketNftName },
      loanOwnerNft: { policyId: skh.loan, assetName: seedName },
      positionNft: { policyId: skh.position, assetName: seedName },
    };
    rec.loans = Deployer.remember(
      rec.loans, { arm: "borrow", market: MARKET_KEY, ...rec.openDirect }, "loanOwnerNft");
    await Bun.write(record, JSON.stringify(rec, null, 2) + "\n");
    console.log(`\nupdated ${record}`);
  }

  /// §7.6 with a claim — one transaction opens the loan **and** places the venue
  /// order, so the borrower never posts an order UTxO. The venue's own batcher
  /// fills it and §8 settles the payout: three transactions in all, and only the
  /// first is the borrower's.
  ///
  /// Everything the order used to say is replaced by two numbers the borrower
  /// passes here — the margin they put up and the loan they draw — and by the
  /// single bound §7.6.7.3 puts on `sold`. There is no limit price on this route,
  /// so §4.1's max is over health and the venue's reserve term alone.
  async borrowAsync(margin: bigint, wantLoan?: bigint): Promise<void> {
    const record = `${OUT_FOLDER}/${NETWORK.toLowerCase()}.json`;
    const rec = await Bun.file(record).json();
    const nft: TupleAsset = [rec.protocolNft.policyId, rec.protocolNft.assetName];
    const v = ours();
    const venue = minswapV2For(NETWORK);
    const built = {
      pool: v.pool(nft),
      loan: v.loan(nft),
      position: v.position(nft),
      adapter_minswap: minswapAdapter(nft, venue.orderSkh, venue.poolSkh, venue.poolNftPolicy),
    };
    const skh = Object.fromEntries(Object.entries(built).map(([n, s]) =>
      [n, validatorToScriptHash(s)])) as Record<keyof typeof built, string>;

    const walletAddr = await this.lucid.wallet().address();
    const stake = getAddressDetails(walletAddr).stakeCredential;
    const registry = await this.byNft(rec.protocolNft.policyId, rec.protocolNft.assetName, "the ProtocolNFT");
    const { market, pool } = await this.marketPool(rec, ACTIVE_KEY);
    const scriptRefs = await Promise.all((Object.keys(built) as (keyof typeof built)[])
      .map((n) => resolve(rec.referenceScripts[n], 0)));

    const longUnit = `${ACTIVE.collateral.policyId}${ACTIVE.collateral.assetName}`;
    const longDotted = `${ACTIVE.collateral.policyId}.${ACTIVE.collateral.assetName}`;
    const supplyUnit = `${ACTIVE.supplyToken.policyId}${ACTIVE.supplyToken.assetName}`;
    const supplyDotted = ACTIVE.supplyToken.policyId === ""
      ? "" : `${ACTIVE.supplyToken.policyId}.${ACTIVE.supplyToken.assetName}`;
    const venuePool = await this.minswapPool(venue, longDotted, supplyDotted);
    const oracle = await oracleWithdrawal(supplyDotted, [longDotted]);
    const price = oracle.quotes[0]!;

    // The margin, both minADAs and the venue's fee budget all leave this one
    // input, and published reference scripts are excluded from coin selection.
    await this.ensureCleanFunding(
      walletAddr, ACTIVE.venueFeeBudget + 2n * MIN_ADA + 60_000_000n);
    const seedRow = this.leanest(await this.kupo(walletAddr), 1)[0];
    if (!seedRow) throw new Error("no funding UTxO to seed the loan");
    // The seed is deliberately token-free — `hashUtxo(seed)` names every NFT
    // this loan mints, and `ensureCleanFunding` produces exactly that. Where the
    // supply token is a token the margin therefore rides in a second input, the
    // way §7.6's collateral does.
    const seed = await resolve(seedRow.transaction_id, seedRow.output_index);
    const walletIns = [seed];
    if (SUPPLY_IS_TOKEN) {
      const marginRow = (await this.kupo(supplyDotted))
        .find((r) => r.address === walletAddr
          && !(r.transaction_id === seed.txHash && r.output_index === seed.outputIndex));
      if (!marginRow) throw new Error("no UTxO in this wallet holds the supply token");
      walletIns.push(await resolve(marginRow.transaction_id, marginRow.output_index));
    }
    const held = walletIns.reduce((n, u) => n + (SUPPLY_IS_TOKEN
      ? (u.assets[supplyUnit] ?? 0n)
      : BigInt(u.assets["lovelace"]!)), 0n);
    if (held < margin) {
      throw new Error(`these inputs hold ${held} of the supply token, margin is ${margin}`);
    }

    // ---------------------------------------------------------------- numbers
    const { from, to, startMs } = this.window();
    const st = this.poolState(pool, startMs, ACTIVE);
    const totalSupply = max0(st.inSupply + st.accrued - st.accruedFee);
    const borrowedNow = max0(st.inBorrow + st.accrued);
    const utilRoom = max0((ACTIVE.utilCap * totalSupply) / 10_000n - borrowedNow);
    // 2x is the shape a market order takes: the borrower's margin, matched.
    const loanAmount = wantLoan ?? (margin < (utilRoom * 9n) / 10n ? margin : (utilRoom * 9n) / 10n);
    if (loanAmount < ACTIVE.minTxAmount) {
      throw new Error(`§7.6.3: loan ${loanAmount} is below min_tx_amount ${ACTIVE.minTxAmount}`
        + ` (the pool has room for ${utilRoom})`);
    }
    const nlp = netLoanProceeds(
      loanAmount, ACTIVE.loanOriginationFeeRate, ACTIVE.loanOriginationFeeMinAmount);
    // §7.6.7.3 — what the pool nets has to reach the venue, and the margin rides
    // with it. `sold` is the whole swap.
    const sold = margin + nlp;

    const totalBorrow = max0(st.inBorrow + st.accrued + loanAmount);
    const outApy = borrowApy(ACTIVE.baseRate, ACTIVE.powerBase, totalSupply, totalBorrow);
    if (ACTIVE.utilCap * totalSupply <= totalBorrow * 10_000n) {
      throw new Error(`util cap: ${ACTIVE.utilCap} * ${totalSupply} <= ${totalBorrow} * 10000`);
    }
    const poolOutAda = SUPPLY_IS_TOKEN
      ? BigInt(pool.assets["lovelace"]!)
      : BigInt(pool.assets["lovelace"]!) - nlp;
    const poolOutSupply = SUPPLY_IS_TOKEN ? (pool.assets[supplyUnit] ?? 0n) - nlp : 0n;

    // §4.1 without its third term — this route takes no limit price.
    const expiry = BigInt(to) + ACTIVE.minClaimDuration;
    const debtAtExpiry = debtAt(loanAmount, outApy, st.interestTime, expiry);
    const health = healthFloor(
      debtAtExpiry, ACTIVE.claimSafetyMargin, ACTIVE.collateral.liquidationThreshold,
      price.numerator, price.denominator);
    const aToB = venuePool.supplyIsA;
    const ach = achievable(
      venuePool.reserveSupply, venuePool.reserveLong, sold, venuePool.feeSupply);
    const market_floor = marketFloor(ach, ORDER.maxSlippage);
    const floor = health > market_floor ? health : market_floor;
    const ceiling = fillCeiling(ach, ACTIVE.fillabilityMargin);
    if (floor > ceiling) {
      throw new Error(`floor ${floor} above the venue's ceiling ${ceiling} — the pool is too thin for ${sold}`);
    }

    // ------------------------------------------------------------------ names
    const seedName = hashUtxo(seed, blake2b224);
    const hex = (s: string) => Buffer.from(s).toString("hex");
    const marketNftName = rec[ACTIVE_KEY].marketNft.assetName;
    const ownerName = seedName;
    const positionOwnerName = seedName + hex("OWN");
    const bindingName = seedName + hex("BND");
    const loanNftUnit = toUnit(skh.loan, marketNftName);
    const loanOwnerUnit = toUnit(skh.loan, ownerName);
    const bindingUnit = toUnit(skh.loan, bindingName);
    const positionUnit = toUnit(skh.position, ownerName);
    const positionOwnerUnit = toUnit(skh.position, positionOwnerName);
    const marketUnit = toUnit(rec[ACTIVE_KEY].marketNft.policyId, marketNftName);

    // The venue pool is one of the oracle's own price sources on this pair, so
    // the same UTxO is named twice — trap 16. `distinct` is what keeps the
    // indices honest.
    const refs = this.distinct([registry, market, ...scriptRefs, ...oracle.refs, venuePool.utxo]);
    const sortedRefs = [...refs].sort((a, b) =>
      a.txHash === b.txHash ? a.outputIndex - b.outputIndex : (a.txHash < b.txHash ? -1 : 1));
    const refIdx = (u: UTxO) => BigInt(sortedRefs.findIndex(
      (r) => r.txHash === u.txHash && r.outputIndex === u.outputIndex));
    const ins = this.distinct(walletIns);
    const all = this.distinct([pool, ...ins]);
    const [poolIn, seedIn] = getInputIndices([pool, seed], all) as bigint[];
    const OUT = { position: 0n, loan: 1n, pool: 2n, venue: 3n };
    const protoRef = refIdx(registry);
    const marketRef = refIdx(market);

    // -------------------------------------------------------------- redeemers
    // `OpenDirect` is loan action index 6, and its indexer is unchanged: the
    // adapter is read from the claim this loan writes, not from the redeemer.
    const loanRdmr = Data.to(new Constr(0, [
      [new Constr(6, [
        [new Constr(0, [OUT.loan, OUT.position, seedIn!])],
        marketRef, OUT.pool,
      ])],
      protoRef,
    ]));
    const poolRdmr = Data.to(new Constr(0, [
      [new Constr(0, [poolIn!, OUT.pool, marketRef, [seedName]])], protoRef,
    ]));
    const positionRdmr = Data.to(new Constr(0, [
      [new Constr(0, [seedIn!, OUT.position])], protoRef,
    ]));
    const stakeData: Data = stake
      ? new Constr(0, [new Constr(0, [new Constr(stake.type === "Script" ? 1 : 0, [stake.hash])])])
      : new Constr(1, []);
    // `Pending` is route index 1. `slippage_src_idx` names no input on this
    // route — there is no order and no position input — so it is `-1`.
    const adapterRdmr = Data.to(new Constr(0, [
      [new Constr(0, [
        ownerName,
        new Constr(1, [
          [ACTIVE.collateral.policyId, ACTIVE.collateral.assetName],
          floor, market_floor,
          [skh.loan, bindingName],
          expiry, -1n, refIdx(venuePool.utxo), OUT.venue, stakeData,
        ]),
      ])],
      protoRef, marketRef,
    ]));

    // ---------------------------------------------------------------- outputs
    const positionOut = new Constr(0, [
      [ACTIVE.collateral.policyId, ACTIVE.collateral.assetName],
      new Constr(0, [0n, 1n]),
      ORDER.minExecutionAmount,
      ORDER.maxSlippage,
      addressData(walletAddr),
    ]);
    const claim = new Constr(0, [
      skh.adapter_minswap,
      [skh.loan, bindingName],
      new Constr(0, []),                                   // Opening
      [ACTIVE.collateral.policyId, ACTIVE.collateral.assetName],
      sold, floor, expiry,
    ]);
    const loanOut = new Constr(0, [
      new Constr(0, [[skh.loan, ownerName]]),
      [ACTIVE.supplyToken.policyId, ACTIVE.supplyToken.assetName],
      loanAmount, st.outIndex, new Constr(0, [claim]),
    ]);
    const poolOut = new Constr(0, [
      totalSupply, st.inDtoken, totalBorrow, outApy,
      st.inFee + loanAmount - nlp + st.accruedFee,
      st.outIndex, st.interestTime, st.pd.fields[7], st.pd.fields[8],
    ]);
    const receiver = new Constr(0, [new Constr(1, [skh.loan]), stakeData]);
    const venueOut = new Constr(0, [
      new Constr(2, [rec.registry.cancelSkh]),
      receiver,
      new Constr(0, []),
      receiver,
      new Constr(0, []),
      new Constr(0, [venue.poolNftPolicy, venuePool.lpName]),
      new Constr(0, [
        new Constr(aToB ? 1 : 0, []),
        new Constr(0, [sold]),
        floor,
        new Constr(1, []),
      ]),
      ACTIVE.venueFeeBudget - ACTIVE.maxCancelFee - MIN_ADA - ACTIVE.rollbackTip,
      new Constr(0, [[expiry, ACTIVE.maxCancelFee]]),
    ]);
    const venueAddr = credentialToAddress(
      NETWORK, { type: "Script", hash: venue.orderSkh },
      stake ? { type: stake.type === "Script" ? "Script" : "Key", hash: stake.hash } : undefined);

    console.log(`  margin ${margin} + nlp ${nlp} -> sold ${sold}, loan ${loanAmount}`);
    console.log(`  floor ${floor} = max(health ${health}, market ${market_floor}) <= ceiling ${ceiling}`);
    console.log(`  price ${price.numerator}/${price.denominator}, venue reserves ${venuePool.reserveSupply}/${venuePool.reserveLong} fee ${venuePool.feeSupply}`);
    console.log(`  pool ${st.inSupply}/${st.inBorrow} -> ${totalSupply}/${totalBorrow}, apy ${st.inApy} -> ${outApy}`);
    console.log(`  pool_in=${poolIn} seed=${seedIn}, market_ref=${marketRef} proto_ref=${protoRef} venue_ref=${refIdx(venuePool.utxo)}`);
    console.log(`  expiry ${expiry} = tx_end ${to} + ${ACTIVE.minClaimDuration}`);
    const refBytes = sortedRefs.reduce(
      (n, u) => n + (u.scriptRef ? u.scriptRef.script.length / 2 : 0), 0);
    const feeFloor = 2_000_000n + BigInt(Math.ceil(refBytes * 25));
    console.log(`  ${refBytes} bytes of reference script, fee floor ${feeFloor}`);

    this.lucid.overrideUTxOs(ins);
    const tx = await this.retry("build borrow-async", () =>
      this.lucid
        .newTx()
        .setMinFee(feeFloor)
        .collectFrom([pool], poolRdmr)
        .collectFrom(ins)
        .readFrom(sortedRefs)
        .mintAssets({ [loanNftUnit]: 1n, [loanOwnerUnit]: 1n, [bindingUnit]: 1n }, loanRdmr)
        .mintAssets({ [positionUnit]: 1n, [positionOwnerUnit]: 1n }, positionRdmr)
        .withdraw(validatorToRewardAddress(NETWORK, built.pool), 0n, poolRdmr)
        .withdraw(validatorToRewardAddress(NETWORK, built.loan), 0n, loanRdmr)
        .withdraw(validatorToRewardAddress(NETWORK, built.position), 0n, positionRdmr)
        .withdraw(validatorToRewardAddress(NETWORK, built.adapter_minswap), 0n, adapterRdmr)
        .withdraw(oracleRewardAddress(NETWORK), 0n, Data.to(oracle.redeemerFor(refIdx)))
        .pay.ToContract(validatorToAddress(NETWORK, built.position, stake),
          { kind: "inline", value: Data.to(positionOut) },
          { lovelace: MIN_ADA, [positionUnit]: 1n, [loanOwnerUnit]: 1n })
        .pay.ToContract(validatorToAddress(NETWORK, built.loan, stake),
          { kind: "inline", value: Data.to(loanOut) },
          { lovelace: MIN_ADA, [loanNftUnit]: 1n })
        .pay.ToContract(pool.address, { kind: "inline", value: Data.to(poolOut) },
          {
            lovelace: poolOutAda, [marketUnit]: 1n,
            ...(SUPPLY_IS_TOKEN ? { [supplyUnit]: poolOutSupply } : {}),
          })
        .pay.ToContract(venueAddr, { kind: "inline", value: Data.to(venueOut) },
          {
            lovelace: ACTIVE.venueFeeBudget + (SUPPLY_IS_TOKEN ? 0n : sold),
            [bindingUnit]: 1n,
            ...(SUPPLY_IS_TOKEN ? { [supplyUnit]: sold } : {}),
          })
        .validFrom(from)
        .validTo(to)
        .complete({ setCollateral: 15_000_000n }),
      2,
    );
    const hash = await this.submit("  borrow-async", tx);
    const target = {
      tx: hash,
      market: MARKET_KEY,
      loanAmount: loanAmount.toString(),
      sold: sold.toString(),
      floor: floor.toString(),
      expiry: expiry.toString(),
      bindingNft: { policyId: skh.loan, assetName: bindingName },
      loanNft: { policyId: skh.loan, assetName: marketNftName },
      loanOwnerNft: { policyId: skh.loan, assetName: ownerName },
      positionNft: { policyId: skh.position, assetName: ownerName },
      venueOrderAddress: venueAddr,
    };
    rec.openDirectAsync = target;
    rec.loans = Deployer.remember(
      rec.loans, { arm: "borrow-async", ...target }, "loanOwnerNft");
    // §8 and §12 read the claim through the same entry an order-funded fill
    // writes, so the arms that follow need no flag to tell the two apart.
    rec.fill = target;
    await Bun.write(record, JSON.stringify(rec, null, 2) + "\n");
    console.log(`\nupdated ${record}`);
  }

  /// §11 `Liquidate` — permissionless, on a loan the oracle says is under water.
  ///
  /// The liquidator hands the pool what the collateral is worth, takes the
  /// collateral plus a bounded reward, and the residual is parked in a remain
  /// UTxO §13 later sweeps to the beneficiary. Hosted by `loan_close`.
  async liquidate(): Promise<void> {
    const record = `${OUT_FOLDER}/${NETWORK.toLowerCase()}.json`;
    const rec = await Bun.file(record).json();
    // A record can hold loans from more than one market, and a closed one has had
    // its NFTs burned. Prefer the entry this invocation's own market opened.
    const target = await this.liveLoan(rec);
    if (!target) throw new Error("no loan recorded to liquidate");
    const nft: TupleAsset = [rec.protocolNft.policyId, rec.protocolNft.assetName];
    const v = ours();
    const built = { loan_close: v.loan_close(nft), position: v.position(nft), pool: v.pool(nft) };
    const walletAddr = await this.lucid.wallet().address();
    const registry = await this.byNft(rec.protocolNft.policyId, rec.protocolNft.assetName, "the ProtocolNFT");
    const { market, pool } = await this.marketPool(rec, ACTIVE_KEY);
    const loan = await this.loanByOwner(target.loanNft.policyId, target.loanNft.assetName, target.loanOwnerNft.assetName);
    const position = await this.byNft(target.positionNft.policyId, target.positionNft.assetName, "the PositionNFT");
    const scriptRefs = await Promise.all((["loan", "loan_close", "position", "pool"] as const)
      .map((n) => resolve(rec.referenceScripts[n], 0)));
    const longDotted = `${ACTIVE.collateral.policyId}.${ACTIVE.collateral.assetName}`;
    const supplyDotted = ACTIVE.supplyToken.policyId === ""
      ? ""
      : `${ACTIVE.supplyToken.policyId}.${ACTIVE.supplyToken.assetName}`;
    const longUnit = `${ACTIVE.collateral.policyId}${ACTIVE.collateral.assetName}`;
    const oracle = await oracleWithdrawal(supplyDotted, [longDotted]);
    const price = oracle.quotes[0]!;
    const fundingRow = this.leanest(await this.kupo(walletAddr), 1)[0];
    if (!fundingRow) throw new Error("no funding UTxO");
    const funding = await resolve(fundingRow.transaction_id, fundingRow.output_index);

    // ---------------------------------------------------------------- numbers
    const ld = Data.from(loan.datum!) as Constr<any>;
    const loanAmount = ld.fields[2] as bigint;
    const initialIndex = ld.fields[3] as bigint;
    if ((ld.fields[4] as Constr<any>).index !== 1) {
      throw new Error("this loan carries a claim; §11.3 is the grace arm, not this one");
    }
    const { from, to, startMs } = this.window();
    const st = this.poolState(pool, startMs, ACTIVE);
    const debt = (loanAmount * st.outIndex) / initialIndex;
    const collateralAmount = loan.assets[longUnit] ?? 0n;
    const health = (collateralAmount * price.numerator * ACTIVE.collateral.liquidationThreshold)
      / (price.denominator * 10_000n);
    if (health >= debt) {
      throw new Error(`the loan is healthy: collateral value ${health} against debt ${debt}`);
    }
    const { floor: rewardFloor, cap } = rewardBounds(
      collateralAmount, ACTIVE.liquidatorRewardCap, ACTIVE.minLiquidatorReward,
      price.numerator, price.denominator);
    const reward = rewardFloor;
    const seized = seizedOf(debt, price.numerator, price.denominator, collateralAmount, reward);
    const taken = seized + reward;
    const remainder = collateralAmount - taken;
    const repaid = repaidOf(seized, price.numerator, price.denominator);
    const shortfall = debt > repaid ? debt - repaid : 0n;

    const totalSupply = max0(st.inSupply + st.accrued - st.accruedFee - shortfall);
    const totalBorrow = max0(st.inBorrow + st.accrued - debt);
    const poolOut = new Constr(0, [
      totalSupply, st.inDtoken, totalBorrow,
      borrowApy(ACTIVE.baseRate, ACTIVE.powerBase, totalSupply, totalBorrow),
      st.inFee + st.accruedFee, st.outIndex, st.interestTime,
      st.pd.fields[7], (st.pd.fields[8] as bigint) + shortfall,
    ]);
    // What the liquidator hands the pool arrives in the supply token, which is
    // lovelace only where the market lends ADA.
    const supplyUnit = `${ACTIVE.supplyToken.policyId}${ACTIVE.supplyToken.assetName}`;
    const poolOutAda = SUPPLY_IS_TOKEN
      ? BigInt(pool.assets["lovelace"]!)
      : BigInt(pool.assets["lovelace"]!) + repaid;
    const poolOutSupply = SUPPLY_IS_TOKEN ? (pool.assets[supplyUnit] ?? 0n) + repaid : 0n;

    const positionNftName = target.positionNft.assetName;
    const remainName = positionNftName + Buffer.from("RMN").toString("hex");
    const ownerName = target.loanOwnerNft.assetName;
    const loanNftUnit = toUnit(target.loanNft.policyId, target.loanNft.assetName);
    const loanOwnerUnit = toUnit(target.loanNft.policyId, ownerName);
    const remainUnit = toUnit(target.loanNft.policyId, remainName);
    const positionUnit = toUnit(target.positionNft.policyId, positionNftName);
    const marketUnit = toUnit(rec[ACTIVE_KEY].marketNft.policyId, rec[ACTIVE_KEY].marketNft.assetName);
    // §13.2 — keyed by the `PositionOwnerNFT`'s name, and paid to the position's
    // own beneficiary; the remain UTxO sits at the loan script under the
    // position's stake credential.
    const pdatum = Data.from(position.datum!) as Constr<any>;
    const remainDatum = new Constr(0, [
      [target.positionNft.policyId, positionNftName + Buffer.from("OWN").toString("hex")],
      pdatum.fields[4],
      ACTIVE.collectorReward,
    ]);
    const positionStake = getAddressDetails(position.address).stakeCredential;

    // A venue pool can be one of the oracle's own price sources — the Minswap
    // pool this fill trades against is exactly where the fBTC/fUSDM rate comes
    // from — and a reference input named twice is still one reference input. The
    // ledger dedupes it, so indices taken over a list that does not are off by
    // one for everything past the repeat.
    const refs = this.distinct([registry, market, ...scriptRefs, ...oracle.refs]);
    const sortedRefs = [...refs].sort((a, b) =>
      a.txHash === b.txHash ? a.outputIndex - b.outputIndex : (a.txHash < b.txHash ? -1 : 1));
    const refIdx = (u: UTxO) => BigInt(sortedRefs.findIndex(
      (r) => r.txHash === u.txHash && r.outputIndex === u.outputIndex));
    if (Bun.env["DEBUG_REFS"]) {
      console.log(`  refs(${sortedRefs.length}): ` + sortedRefs.map((u, i) =>
        `${i}:${u.txHash.slice(0, 8)}#${u.outputIndex}${u.scriptRef ? "*" : ""}`).join(" "));
      const rd = oracle.redeemerFor(refIdx) as any;
      const flat = (x: any): string => Array.isArray(x)
        ? "[" + x.map(flat).join(",") + "]"
        : (x && typeof x === "object" && "index" in x ? `C${x.index}` : String(x));
      console.log(`  oracle rdmr: cfg=${flat(rd.fields[0])} paths=${flat(rd.fields[1])} srcs=${flat(rd.fields[2])}`);
    }
    const all = this.distinct([loan, position, pool, funding]);
    const [loanIn, positionIn, poolIn] =
      getInputIndices([loan, position, pool], all) as bigint[];
    const OUT = { liquidator: 0n, remain: 1n, pool: 2n };
    const protoRef = refIdx(registry);
    const marketRef = refIdx(market);

    // `Liquidate` is loan action index 3, with `payout_in_idx` and `tip_out_idx`
    // absent — the grace arm of §11.3 is the one that consumes a payout.
    const loanRdmr = Data.to(new Constr(0, [
      [new Constr(3, [
        loanIn!, positionIn!, -1n, poolIn!, OUT.pool,
        OUT.liquidator, OUT.remain, -1n, marketRef, reward,
      ])],
      protoRef,
    ]));
    // `ClosePosition` with no owner input: §11.2 is permissionless, so only the
    // `PositionNFT` burns and the `PositionOwnerNFT` stays alive for §13.
    const positionRdmr = Data.to(new Constr(0, [
      [new Constr(3, [[new Constr(0, [positionIn!, -1n, loanIn!, -1n, -1n])]])],
      protoRef,
    ]));
    const poolRdmr = Data.to(new Constr(0, [
      [new Constr(0, [poolIn!, OUT.pool, marketRef, [ownerName]])], protoRef,
    ]));

    console.log(`  debt ${debt}, collateral ${collateralAmount}, health value ${health} — under water`);
    console.log(`  reward ${reward} (floor ${rewardFloor}, cap ${cap}), seized ${seized}, taken ${taken}, remainder ${remainder}`);
    console.log(`  repaid ${repaid} to the pool, shortfall ${shortfall}`);
    const refBytes = sortedRefs.reduce((n, u) => n + (u.scriptRef ? u.scriptRef.script.length / 2 : 0), 0);

    this.lucid.overrideUTxOs([funding]);
    const tx = await this.retry("build liquidate", () =>
      this.lucid
        .newTx()
        .setMinFee(2_000_000n + BigInt(Math.ceil(refBytes * 25)))
        .collectFrom([loan], loanRdmr)
        .collectFrom([position], positionRdmr)
        .collectFrom([pool], poolRdmr)
        .collectFrom([funding])
        .readFrom(sortedRefs)
        .mintAssets({ [loanNftUnit]: -1n, [loanOwnerUnit]: -1n, [remainUnit]: 1n }, loanRdmr)
        .mintAssets({ [positionUnit]: -1n }, positionRdmr)
        .withdraw(validatorToRewardAddress(NETWORK, built.loan_close), 0n, loanRdmr)
        .withdraw(validatorToRewardAddress(NETWORK, built.position), 0n, positionRdmr)
        .withdraw(validatorToRewardAddress(NETWORK, built.pool), 0n, poolRdmr)
        .withdraw(oracleRewardAddress(NETWORK), 0n, Data.to(oracle.redeemerFor(refIdx)))
        // §11.2.7 — the liquidator's own minADA plus what it took.
        .pay.ToAddress(walletAddr, { lovelace: MIN_ADA, [longUnit]: taken })
        // §13.2 — the residual rests at the **loan** script, under the stake
        // credential the position carried.
        .pay.ToContract(
          validatorToAddress(NETWORK, v.loan(nft), positionStake),
          { kind: "inline", value: Data.to(remainDatum) },
          remainder > 0n
            ? { lovelace: MIN_ADA + ACTIVE.collectorReward, [remainUnit]: 1n, [longUnit]: remainder }
            : { lovelace: MIN_ADA + ACTIVE.collectorReward, [remainUnit]: 1n },
        )
        .pay.ToContract(pool.address, { kind: "inline", value: Data.to(poolOut) },
          {
            lovelace: poolOutAda, [marketUnit]: 1n,
            ...(SUPPLY_IS_TOKEN ? { [supplyUnit]: poolOutSupply } : {}),
          })
        .validFrom(from)
        .validTo(to)
        .complete({ setCollateral: 15_000_000n }),
      2,
    );
    const hash = await this.submit("  liquidate", tx);
    rec.liquidate = {
      tx: hash, debt: debt.toString(), reward: reward.toString(),
      taken: taken.toString(), remainder: remainder.toString(),
      repaid: repaid.toString(), shortfall: shortfall.toString(),
      remainNft: { policyId: target.loanNft.policyId, assetName: remainName },
    };
    await Bun.write(record, JSON.stringify(rec, null, 2) + "\n");
    console.log(`\nupdated ${record}`);
  }

  /// §13.3 `CollectRemain` — anyone may sweep a parked residual and is paid
  /// `collector_reward` for it. The residual goes to the beneficiary the parking
  /// transaction recorded, not to whoever sweeps.
  async collectRemain(): Promise<void> {
    const record = `${OUT_FOLDER}/${NETWORK.toLowerCase()}.json`;
    const rec = await Bun.file(record).json();
    // §11 and §10.2.2 both park a residual; whichever is still unspent is swept.
    const parked = [rec.rollback, rec.settleClose, rec.liquidate].filter((x) => x?.remainNft);
    if (parked.length === 0) throw new Error("no parked residual recorded");
    const nft: TupleAsset = [rec.protocolNft.policyId, rec.protocolNft.assetName];
    const loanCloseScript = ours().loan_close(nft);
    const walletAddr = await this.lucid.wallet().address();
    const registry = await this.byNft(rec.protocolNft.policyId, rec.protocolNft.assetName, "the ProtocolNFT");
    let remain: UTxO | null = null;
    for (const p of parked) {
      const rows = await this.kupo(`${p.remainNft.policyId}.${p.remainNft.assetName}`);
      if (rows.length === 1) {
        remain = await resolve(rows[0]!.transaction_id, rows[0]!.output_index);
        break;
      }
    }
    if (!remain) throw new Error("every recorded residual has already been swept");
    const closeRef = await resolve(rec.referenceScripts.loan_close, 0);
    // The residual sits at the loan script, so its own script is cited too.
    const loanRef = await resolve(rec.referenceScripts.loan, 0);
    const fundingRow = this.leanest(await this.kupo(walletAddr), 1)[0];
    if (!fundingRow) throw new Error("no funding UTxO");
    const funding = await resolve(fundingRow.transaction_id, fundingRow.output_index);

    const rd = Data.from(remain.datum!) as Constr<any>;
    const collectorReward = rd.fields[2] as bigint;
    const remainName = Object.keys(remain.assets).find(
      (u) => u.startsWith(parked[0]!.remainNft.policyId) && u !== "lovelace")!.slice(56);
    const remainUnit = toUnit(parked[0]!.remainNft.policyId, remainName);
    const residual = Object.fromEntries(Object.entries(remain.assets)
      .filter(([u]) => u !== "lovelace" && u !== remainUnit));
    const beneficiaryAda = BigInt(remain.assets["lovelace"]!) - collectorReward;

    const sortedRefs = [registry, closeRef, loanRef].sort((a, b) =>
      a.txHash === b.txHash ? a.outputIndex - b.outputIndex : (a.txHash < b.txHash ? -1 : 1));
    const refIdx = (u: UTxO) => BigInt(sortedRefs.findIndex(
      (r) => r.txHash === u.txHash && r.outputIndex === u.outputIndex));
    const all = [remain, funding];
    const [remainIn] = getInputIndices([remain], all) as bigint[];
    // `CollectRemain` is loan action index 5.
    const rdmr = Data.to(new Constr(0, [
      [new Constr(5, [[new Constr(0, [remainIn!, 0n])], 1n])], refIdx(registry),
    ]));
    console.log(`  sweeping ${Object.keys(residual).length} residual asset(s), reward ${collectorReward}`);
    const { from, to } = this.window();
    const refBytes = sortedRefs.reduce((n, u) => n + (u.scriptRef ? u.scriptRef.script.length / 2 : 0), 0);

    this.lucid.overrideUTxOs([funding]);
    const tx = await this.retry("build collect-remain", () =>
      this.lucid
        .newTx()
        .setMinFee(1_500_000n + BigInt(Math.ceil(refBytes * 25)))
        .collectFrom([remain], rdmr)
        .collectFrom([funding])
        .readFrom(sortedRefs)
        .mintAssets({ [remainUnit]: -1n }, rdmr)
        .withdraw(validatorToRewardAddress(NETWORK, loanCloseScript), 0n, rdmr)
        // §13.3.3 — the residual reaches the recorded beneficiary.
        .pay.ToAddress(walletAddr, { lovelace: beneficiaryAda, ...residual })
        // §13.3.4 — the reward is lovelace and nothing else, exactly.
        .pay.ToAddress(walletAddr, { lovelace: collectorReward })
        .validFrom(from)
        .validTo(to)
        .complete({ setCollateral: 15_000_000n }),
      2,
    );
    const hash = await this.submit("  collect-remain", tx);
    rec.collectRemain = { tx: hash, reward: collectorReward.toString(), remainNft: remainName };
    await Bun.write(record, JSON.stringify(rec, null, 2) + "\n");
    console.log(`\nupdated ${record}`);
  }

  /// §10.2.1 — the trader places a **sell** claim: the collateral goes to the
  /// venue and the loan keeps a `Closing` claim against the proceeds.
  ///
  /// The pool is a reference input here, not an input: this arm moves no value
  /// through it, and the floor it computes needs only the index. §10.2.2 is what
  /// repays once the venue fills.
  /// §10.2.1, both callers of it.
  ///
  /// `takeProfit` is the whole difference: the trader's own close names the
  /// input holding the `PositionOwnerNFT`, a take-profit names none and the
  /// validator reads the position's own `take_profit_price` against the oracle
  /// instead. Nothing else about the claim changes, which is the point — what
  /// the venue sees is the same order either way.
  async closeAsync(takeProfit = false): Promise<void> {
    const record = `${OUT_FOLDER}/${NETWORK.toLowerCase()}.json`;
    const rec = await Bun.file(record).json();
    // §10.2.1 closes any loan that carries no claim, however it was opened.
    const target = await this.liveLoan(rec, Deployer.unclaimed);
    if (!target || !rec.settle) throw new Error("no settled async loan recorded");
    const nft: TupleAsset = [rec.protocolNft.policyId, rec.protocolNft.assetName];
    const v = ours();
    const venue = minswapV2For(NETWORK);
    const built = {
      loan_repay: v.loan_repay(nft), position: v.position(nft),
      adapter_minswap: minswapAdapter(nft, venue.orderSkh, venue.poolSkh, venue.poolNftPolicy),
    };
    const loanSkh = validatorToScriptHash(v.loan(nft));
    const adapterSkh = validatorToScriptHash(built.adapter_minswap);
    const walletAddr = await this.lucid.wallet().address();
    const registry = await this.byNft(rec.protocolNft.policyId, rec.protocolNft.assetName, "the ProtocolNFT");
    const { market, pool } = await this.marketPool(rec, ACTIVE_KEY);
    const loan = await this.loanByOwner(target.loanNft.policyId, target.loanNft.assetName, target.loanOwnerNft.assetName);
    const position = await this.byNft(target.positionNft.policyId, target.positionNft.assetName, "the PositionNFT");
    const ownerName = target.loanOwnerNft.assetName;
    const positionOwnerName = ownerName + Buffer.from("OWN").toString("hex");
    const owner = takeProfit
      ? null
      : await this.byNft(target.positionNft.policyId, positionOwnerName, "the PositionOwnerNFT");
    const scriptRefs = await Promise.all((["loan", "loan_repay", "position", "adapter_minswap"] as const)
      .map((n) => resolve(rec.referenceScripts[n], 0)));
    const longDotted = `${ACTIVE.collateral.policyId}.${ACTIVE.collateral.assetName}`;
    const supplyDotted = ACTIVE.supplyToken.policyId === ""
      ? ""
      : `${ACTIVE.supplyToken.policyId}.${ACTIVE.supplyToken.assetName}`;
    const longUnit = `${ACTIVE.collateral.policyId}${ACTIVE.collateral.assetName}`;
    const venuePool = await this.minswapPool(venue, longDotted, supplyDotted);
    const oracle = await oracleWithdrawal(supplyDotted, [longDotted]);
    // A take-profit has to be provable from the transaction alone. `--cancel-order`
    // leaves the `PositionOwnerNFT` in the wallet's token bag, and the leanest
    // UTxO is that bag, so funding from it puts the ticket in an input the
    // redeemer never names — true, and indistinguishable at a glance from a close
    // the trader signed. A token-free UTxO removes the question.
    if (takeProfit) await this.ensureCleanFunding(walletAddr, 20_000_000n);
    const rows = await this.kupo(walletAddr);
    const fundingRow = takeProfit
      ? rows.find((r) => !r.script_hash
          && Object.keys(r.value.assets ?? {}).length === 0
          && BigInt(r.value.coins) >= 20_000_000n)
      : this.leanest(rows, 1)[0];
    if (!fundingRow) throw new Error("no funding UTxO");
    const funding = await resolve(fundingRow.transaction_id, fundingRow.output_index);

    // ---------------------------------------------------------------- numbers
    const ld = Data.from(loan.datum!) as Constr<any>;
    const loanAmount = ld.fields[2] as bigint;
    const initialIndex = ld.fields[3] as bigint;
    if ((ld.fields[4] as Constr<any>).index !== 1) throw new Error("this loan already carries a claim");
    const pdatum = Data.from(position.datum!) as Constr<any>;
    const maxSlippage = pdatum.fields[3] as bigint;
    const { from, to, startMs } = this.window();
    const st = this.poolState(pool, startMs, ACTIVE);
    const debt = (loanAmount * st.outIndex) / initialIndex;
    const sold = loan.assets[longUnit] ?? 0n;
    if (sold === 0n) throw new Error("this loan holds no collateral to sell");
    const expiry = BigInt(to) + ACTIVE.minClaimDuration;
    // §4.2 — the closing floor rests on the debt projected to `expiry` at the
    // pool's own rate, and on what the venue can actually pay.
    const debtAtExpiry = debtAt(debt, st.inApy, st.inTime, expiry);
    // The mirror of the opening fill: the collateral is sold back for the supply.
    const ach = achievable(
      venuePool.reserveLong, venuePool.reserveSupply, sold, venuePool.feeLong);
    const market_floor = marketFloor(ach, maxSlippage);
    const safety = ceilingDiv(debtAtExpiry * (10_000n + ACTIVE.claimSafetyMargin), 10_000n);
    const floor = safety > market_floor ? safety : market_floor;
    const ceiling = fillCeiling(ach, ACTIVE.fillabilityMargin);
    if (floor > ceiling) throw new Error(`floor ${floor} above the venue's ceiling ${ceiling}`);
    if (floor <= ACTIVE.venueFeeBudget) throw new Error(`floor ${floor} does not clear the venue budget`);

    const bindingName = ownerName + Buffer.from("BND").toString("hex");
    const bindingUnit = toUnit(loanSkh, bindingName);
    const loanNftUnit = toUnit(target.loanNft.policyId, target.loanNft.assetName);
    const stake = getAddressDetails(loan.address).stakeCredential;
    const stakeData: Data = stake
      ? new Constr(0, [new Constr(0, [new Constr(stake.type === "Script" ? 1 : 0, [stake.hash])])])
      : new Constr(1, []);

    // A venue pool can be one of the oracle's own price sources — the Minswap
    // pool this fill trades against is exactly where the fBTC/fUSDM rate comes
    // from — and a reference input named twice is still one reference input. The
    // ledger dedupes it, so indices taken over a list that does not are off by
    // one for everything past the repeat.
    const refs = this.distinct([registry, market, pool, venuePool.utxo, ...scriptRefs, ...oracle.refs]);
    const sortedRefs = [...refs].sort((a, b) =>
      a.txHash === b.txHash ? a.outputIndex - b.outputIndex : (a.txHash < b.txHash ? -1 : 1));
    const refIdx = (u: UTxO) => BigInt(sortedRefs.findIndex(
      (r) => r.txHash === u.txHash && r.outputIndex === u.outputIndex));
    if (Bun.env["DEBUG_REFS"]) {
      console.log(`  refs(${sortedRefs.length}): ` + sortedRefs.map((u, i) =>
        `${i}:${u.txHash.slice(0, 8)}#${u.outputIndex}${u.scriptRef ? "*" : ""}`).join(" "));
      const rd = oracle.redeemerFor(refIdx) as any;
      const flat = (x: any): string => Array.isArray(x)
        ? "[" + x.map(flat).join(",") + "]"
        : (x && typeof x === "object" && "index" in x ? `C${x.index}` : String(x));
      console.log(`  oracle rdmr: cfg=${flat(rd.fields[0])} paths=${flat(rd.fields[1])} srcs=${flat(rd.fields[2])}`);
    }
    const wallet = this.distinct(owner ? [owner, funding] : [funding]);
    const all = [loan, position, ...wallet];
    const [loanIn, positionIn, ownerFound] =
      getInputIndices([loan, position, owner ?? position], all) as bigint[];
    // §5 rule 11a — no owner input, so the index that would name it is `-1`, and
    // that absence is what tells the validator to read the oracle instead.
    const ownerIn = owner ? ownerFound! : -1n;
    const OUT = { loan: 0n, position: 1n, venue: 2n };
    const protoRef = refIdx(registry);
    const marketRef = refIdx(market);

    if (takeProfit) {
      const tp = pdatum.fields[1] as Constr<any>;
      const [tpNum, tpDen] = tp.fields as [bigint, bigint];
      const price = oracle.quotes[0]!;
      // The same comparison the validator makes, cross-multiplied so the two
      // agree exactly: a division here would round where Plutus does not.
      const reached = price.numerator * tpDen >= tpNum * price.denominator;
      console.log(`  oracle ${price.numerator}/${price.denominator}, take_profit ${tpNum}/${tpDen}` +
        ` -> ${tpNum === 0n ? "DISABLED" : reached ? "reached" : "NOT reached"}`);
      // Two separate facts, and only the first is what the validator acts on.
      const ownerUnit = toUnit(target.positionNft.policyId, positionOwnerName);
      const carried = all.some((u) => (u.assets[ownerUnit] ?? 0n) > 0n);
      console.log(`  owner_in_idx = -1, so the ticket is never read`);
      console.log(`  PositionOwnerNFT ${carried ? "IS carried by an input (unread)" : "is absent from every input"}`);
    }
    const loanRdmr = Data.to(new Constr(0, [
      [new Constr(2, [
        [new Constr(0, [
          positionIn!, ownerIn, loanIn!, OUT.loan, OUT.position, -1n, -1n, -1n, -1n,
        ])],
        marketRef, refIdx(pool), -1n, -1n, adapterSkh,
      ])],
      protoRef,
    ]));
    const positionRdmr = Data.to(new Constr(0, [
      [new Constr(3, [[new Constr(0, [positionIn!, ownerIn, loanIn!, OUT.loan, OUT.position])]])],
      protoRef,
    ]));
    // The claim sells the collateral **for** the supply token, so the route's
    // `asset` is the supply token and the venue sells the other leg. §10.2.1.5
    // checks it against the loan's `short_token`, which is only ADA on the market
    // that lends ADA.
    const supplyAsset = [ACTIVE.supplyToken.policyId, ACTIVE.supplyToken.assetName];
    const adapterRdmr = Data.to(new Constr(0, [
      [new Constr(0, [
        ownerName,
        new Constr(1, [
          supplyAsset, floor, market_floor, [loanSkh, bindingName],
          expiry, positionIn!, refIdx(venuePool.utxo), OUT.venue, stakeData,
        ]),
      ])],
      protoRef, marketRef,
    ]));

    const claim = new Constr(0, [
      adapterSkh, [loanSkh, bindingName],
      new Constr(1, []),                                  // Closing
      supplyAsset, sold, floor, expiry,
    ]);
    const loanOut = new Constr(0, [...ld.fields.slice(0, 4), new Constr(0, [claim])]);
    const receiver = new Constr(0, [new Constr(1, [loanSkh]), stakeData]);
    const venueOut = new Constr(0, [
      // The venue's `OrderAuthorizationMethod`: index 2 is the *withdrawal*
      // form, which is the only one this protocol's withdraw-only `cancel`
      // script can ever satisfy.
      new Constr(2, [rec.registry.cancelSkh]),
      receiver, new Constr(0, []), receiver, new Constr(0, []),
      new Constr(0, [venue.poolNftPolicy, venuePool.lpName]),
      new Constr(0, [
        new Constr(venuePool.supplyIsA ? 0 : 1, []),      // a_to_b_direction
        new Constr(0, [sold]),
        floor,
        new Constr(1, []),
      ]),
      ACTIVE.venueFeeBudget - ACTIVE.maxCancelFee - MIN_ADA - ACTIVE.rollbackTip,
      new Constr(0, [[expiry, ACTIVE.maxCancelFee]]),
    ]);
    const venueAddr = credentialToAddress(
      NETWORK, { type: "Script", hash: venue.orderSkh },
      stake ? { type: stake.type === "Script" ? "Script" : "Key", hash: stake.hash } : undefined);

    console.log(`  selling ${sold} collateral, debt ${debt} -> at expiry ${debtAtExpiry}`);
    console.log(`  floor ${floor} = max(safety ${safety}, market ${market_floor}) <= ceiling ${ceiling}`);
    const refBytes = sortedRefs.reduce((n, u) => n + (u.scriptRef ? u.scriptRef.script.length / 2 : 0), 0);

    this.lucid.overrideUTxOs(wallet);
    const tx = await this.retry("build close-async", () =>
      this.lucid
        .newTx()
        .setMinFee(2_000_000n + BigInt(Math.ceil(refBytes * 25)))
        .collectFrom([loan], loanRdmr)
        .collectFrom([position], positionRdmr)
        .collectFrom(wallet)
        .readFrom(sortedRefs)
        .mintAssets({ [bindingUnit]: 1n }, loanRdmr)
        .withdraw(validatorToRewardAddress(NETWORK, built.loan_repay), 0n, loanRdmr)
        .withdraw(validatorToRewardAddress(NETWORK, built.position), 0n, positionRdmr)
        .withdraw(validatorToRewardAddress(NETWORK, built.adapter_minswap), 0n, adapterRdmr)
        .withdraw(oracleRewardAddress(NETWORK), 0n, Data.to(oracle.redeemerFor(refIdx)))
        .pay.ToContract(loan.address, { kind: "inline", value: Data.to(loanOut) },
          { lovelace: BigInt(loan.assets["lovelace"]!), [loanNftUnit]: 1n })
        // §10.2.1.10 — the position survives byte-identical. Its datum is
        // re-encoded from the parsed value rather than passed through as the raw
        // hex Kupo returned: the builder rejects the latter outright.
        .pay.ToContract(position.address,
          { kind: "inline", value: Data.to(Data.from(position.datum!)) },
          Object.fromEntries(Object.entries(position.assets)))
        .pay.ToContract(venueAddr, { kind: "inline", value: Data.to(venueOut) },
          { lovelace: ACTIVE.venueFeeBudget, [longUnit]: sold, [bindingUnit]: 1n })
        .validFrom(from)
        .validTo(to)
        .complete({ setCollateral: 15_000_000n }),
      2,
    );
    // The trail is read by whoever comes next, and both arms come through this
    // method — so it is named after the command that was run, not the method.
    const hash = await this.submit(takeProfit ? "  take-profit" : "  close-async", tx);
    // A record holds one entry per step, so writing both arms to `closeAsync`
    // would leave whichever ran last as the only example of either.
    rec[takeProfit ? "takeProfit" : "closeAsync"] = {
      tx: hash, sold: sold.toString(), floor: floor.toString(), expiry: expiry.toString(),
      bindingNft: { policyId: loanSkh, assetName: bindingName },
    };
    await Bun.write(record, JSON.stringify(rec, null, 2) + "\n");
    console.log(`\nupdated ${record}`);
  }

  /// §10.2.2 — the sell claim filled, so the loan is repaid out of the proceeds
  /// and whatever is left is parked for §13.
  async settleClose(): Promise<void> {
    const record = `${OUT_FOLDER}/${NETWORK.toLowerCase()}.json`;
    const rec = await Bun.file(record).json();
    // The sell claim's terms are read off the loan that carries it, not off the
    // record: the record has one sell slot while a take-profit and a
    // `--close-async` can both be outstanding, so the slot need not name the
    // loan this arm ends up settling.
    // §10.2.1 closes any loan that carries no claim, however it was opened.
    // The record keeps one entry per opening arm and one sell claim, and the two
    // need not name the same loan: a take-profit and a `--close-async` can both
    // be outstanding. Match the loan to **this** claim's binding NFT rather than
    // to any claim at all, or the arm pairs a loan with someone else's payout.
    const target = await this.liveLoan(rec, Deployer.closing);
    const nft: TupleAsset = [rec.protocolNft.policyId, rec.protocolNft.assetName];
    const v = ours();
    const venue = minswapV2For(NETWORK);
    const built = {
      loan_repay: v.loan_repay(nft), position: v.position(nft), pool: v.pool(nft),
      adapter_minswap: minswapAdapter(nft, venue.orderSkh, venue.poolSkh, venue.poolNftPolicy),
    };
    const loanSkh = validatorToScriptHash(v.loan(nft));
    const adapterSkh = validatorToScriptHash(built.adapter_minswap);
    const walletAddr = await this.lucid.wallet().address();
    const registry = await this.byNft(rec.protocolNft.policyId, rec.protocolNft.assetName, "the ProtocolNFT");
    const { market, pool } = await this.marketPool(rec, ACTIVE_KEY);
    const loan = await this.loanByOwner(target.loanNft.policyId, target.loanNft.assetName, target.loanOwnerNft.assetName);
    const sell = { ...Deployer.sellOf(loan), bindingNft: Deployer.bindingOf(target) };
    const position = await this.byNft(target.positionNft.policyId, target.positionNft.assetName, "the PositionNFT");
    const ownerName = target.loanOwnerNft.assetName;
    const positionNftName = target.positionNft.assetName;
    const positionOwnerName = positionNftName + Buffer.from("OWN").toString("hex");
    const owner = await this.byNft(target.positionNft.policyId, positionOwnerName, "the PositionOwnerNFT");
    let payout = await this.byNft(
      sell.bindingNft.policyId, sell.bindingNft.assetName, "the BindingNFT");
    for (let i = 0; payout.datum || payout.datumHash; i += 1) {
      if (i >= 60) throw new Error("the venue has not settled the sell order");
      if (i === 0) console.log("  waiting for the venue to settle the sell order");
      await new Promise((r) => setTimeout(r, 15_000));
      payout = await this.byNft(
        sell.bindingNft.policyId, sell.bindingNft.assetName, "the BindingNFT");
    }
    const scriptRefs = await Promise.all(
      (["loan", "loan_repay", "position", "pool", "adapter_minswap"] as const)
        .map((n) => resolve(rec.referenceScripts[n], 0)));
    const fundingRow = this.leanest(await this.kupo(walletAddr), 1)[0];
    if (!fundingRow) throw new Error("no funding UTxO");
    const funding = await resolve(fundingRow.transaction_id, fundingRow.output_index);

    // ---------------------------------------------------------------- numbers
    const ld = Data.from(loan.datum!) as Constr<any>;
    const loanAmount = ld.fields[2] as bigint;
    const initialIndex = ld.fields[3] as bigint;
    const { from, to, startMs } = this.window();
    const st = this.poolState(pool, startMs, ACTIVE);
    const debt = (loanAmount * st.outIndex) / initialIndex;
    // §10.2.2.2 — `q` is what arrived, net of the payout UTxO's own minADA.
    // The venue pays back in the supply token, and only a market lending ADA gets
    // that as lovelace — where it does, the payout's own minADA is the tip.
    const supplyUnit = `${ACTIVE.supplyToken.policyId}${ACTIVE.supplyToken.assetName}`;
    const q = SUPPLY_IS_TOKEN
      ? (payout.assets[supplyUnit] ?? 0n)
      : BigInt(payout.assets["lovelace"]!) - MIN_ADA;
    const floor = sell.floor;
    if (q < floor) throw new Error(`the proceeds ${q} are below the claim's floor ${floor}`);
    const debtRepaid = debt < q ? debt : q;
    const shortfall = debt > debtRepaid ? debt - debtRepaid : 0n;
    const residual = q - debtRepaid;

    const totalSupply = max0(st.inSupply + st.accrued - st.accruedFee - shortfall);
    const totalBorrow = max0(st.inBorrow + st.accrued - debt);
    const poolOut = new Constr(0, [
      totalSupply, st.inDtoken, totalBorrow,
      borrowApy(ACTIVE.baseRate, ACTIVE.powerBase, totalSupply, totalBorrow),
      st.inFee + st.accruedFee, st.outIndex, st.interestTime,
      st.pd.fields[7], (st.pd.fields[8] as bigint) + shortfall,
    ]);
    const poolOutAda = SUPPLY_IS_TOKEN
      ? BigInt(pool.assets["lovelace"]!)
      : BigInt(pool.assets["lovelace"]!) + debtRepaid;
    const poolOutSupply = SUPPLY_IS_TOKEN ? (pool.assets[supplyUnit] ?? 0n) + debtRepaid : 0n;

    const remainName = positionNftName + Buffer.from("RMN").toString("hex");
    const loanNftUnit = toUnit(target.loanNft.policyId, target.loanNft.assetName);
    const loanOwnerUnit = toUnit(target.loanNft.policyId, ownerName);
    const bindingUnit = toUnit(sell.bindingNft.policyId, sell.bindingNft.assetName);
    const remainUnit = toUnit(target.loanNft.policyId, remainName);
    const positionUnit = toUnit(target.positionNft.policyId, positionNftName);
    const marketUnit = toUnit(rec[ACTIVE_KEY].marketNft.policyId, rec[ACTIVE_KEY].marketNft.assetName);
    const pdatum = Data.from(position.datum!) as Constr<any>;
    const remainDatum = new Constr(0, [
      [target.positionNft.policyId, positionOwnerName], pdatum.fields[4], ACTIVE.collectorReward,
    ]);
    const positionStake = getAddressDetails(position.address).stakeCredential;

    const refs = [registry, market, ...scriptRefs];
    const sortedRefs = [...refs].sort((a, b) =>
      a.txHash === b.txHash ? a.outputIndex - b.outputIndex : (a.txHash < b.txHash ? -1 : 1));
    const refIdx = (u: UTxO) => BigInt(sortedRefs.findIndex(
      (r) => r.txHash === u.txHash && r.outputIndex === u.outputIndex));
    // §10.2.2 asks for no owner input: the claim's `floor` is checked here and
    // the proceeds are pinned to the position's `beneficiary`, so whoever
    // settles cannot divert them. The position redeemer has always said `-1`;
    // now the loan redeemer agrees, and a take-profit the trader never signed
    // can be settled by the same stranger who placed it.
    const wallet = this.distinct([funding]);
    const all = [loan, position, payout, pool, ...wallet];
    const [loanIn, positionIn, payoutIn, poolIn] =
      getInputIndices([loan, position, payout, pool], all) as bigint[];
    const OUT = { remain: 0n, pool: 1n, tip: 2n };
    const protoRef = refIdx(registry);
    const marketRef = refIdx(market);

    const loanRdmr = Data.to(new Constr(0, [
      [new Constr(2, [
        [new Constr(0, [
          positionIn!, -1n, loanIn!, -1n, -1n, payoutIn!, -1n, OUT.remain, OUT.tip,
        ])],
        marketRef, -1n, poolIn!, OUT.pool, adapterSkh,
      ])],
      protoRef,
    ]));
    const positionRdmr = Data.to(new Constr(0, [
      [new Constr(3, [[new Constr(0, [positionIn!, -1n, loanIn!, -1n, -1n])]])],
      protoRef,
    ]));
    const poolRdmr = Data.to(new Constr(0, [
      [new Constr(0, [poolIn!, OUT.pool, marketRef, [ownerName]])], protoRef,
    ]));
    // §10.2.2.3 — the arrival is declared as `Delivered` on the supply token.
    const adapterRdmr = Data.to(new Constr(0, [
      [new Constr(0, [
        ownerName,
        new Constr(0, [
          [ACTIVE.supplyToken.policyId, ACTIVE.supplyToken.assetName],
          q,
          new Constr(0, [[loanSkh, sell.bindingNft.assetName]]),
        ]),
      ])],
      protoRef, -1n,
    ]));

    console.log(`  proceeds ${q} against floor ${floor}, debt ${debt}, repaid ${debtRepaid}, residual ${residual}`);
    const refBytes = sortedRefs.reduce((n, u) => n + (u.scriptRef ? u.scriptRef.script.length / 2 : 0), 0);

    this.lucid.overrideUTxOs(wallet);
    const tx = await this.retry("build settle-close", () =>
      this.lucid
        .newTx()
        .setMinFee(2_000_000n + BigInt(Math.ceil(refBytes * 25)))
        .collectFrom([loan], loanRdmr)
        .collectFrom([payout], loanRdmr)
        .collectFrom([position], positionRdmr)
        .collectFrom([pool], poolRdmr)
        .collectFrom(wallet)
        .readFrom(sortedRefs)
        .mintAssets({
          [loanNftUnit]: -1n, [loanOwnerUnit]: -1n, [bindingUnit]: -1n, [remainUnit]: 1n,
        }, loanRdmr)
        .mintAssets({ [positionUnit]: -1n }, positionRdmr)
        .withdraw(validatorToRewardAddress(NETWORK, built.loan_repay), 0n, loanRdmr)
        .withdraw(validatorToRewardAddress(NETWORK, built.position), 0n, positionRdmr)
        .withdraw(validatorToRewardAddress(NETWORK, built.pool), 0n, poolRdmr)
        .withdraw(validatorToRewardAddress(NETWORK, built.adapter_minswap), 0n, adapterRdmr)
        .pay.ToContract(
          validatorToAddress(NETWORK, v.loan(nft), positionStake),
          { kind: "inline", value: Data.to(remainDatum) },
          {
            lovelace: MIN_ADA + ACTIVE.collectorReward + (SUPPLY_IS_TOKEN ? 0n : residual),
            [remainUnit]: 1n,
            ...(SUPPLY_IS_TOKEN && residual > 0n ? { [supplyUnit]: residual } : {}),
          })
        .pay.ToContract(pool.address, { kind: "inline", value: Data.to(poolOut) },
          {
            lovelace: poolOutAda, [marketUnit]: 1n,
            ...(SUPPLY_IS_TOKEN ? { [supplyUnit]: poolOutSupply } : {}),
          })
        // §10.2.2.8 — the payout UTxO's own minADA is released as the tip.
        .pay.ToAddress(walletAddr, { lovelace: MIN_ADA })
        .validFrom(from)
        .validTo(to)
        .complete({ setCollateral: 15_000_000n }),
      2,
    );
    const hash = await this.submit("  settle-close", tx);
    rec.settleClose = {
      tx: hash, proceeds: q.toString(), repaid: debtRepaid.toString(),
      residual: residual.toString(), shortfall: shortfall.toString(),
      remainNft: { policyId: target.loanNft.policyId, assetName: remainName },
    };
    await Bun.write(record, JSON.stringify(rec, null, 2) + "\n");
    console.log(`\nupdated ${record}`);
  }

  /// §16 `ModifyPosition` — the owner changes the terms the position carries.
  ///
  /// Only `take_profit_price` and `min_execution_amount` may move, and the latter
  /// only upward; the value is byte-identical, which is what keeps the
  /// `LoanOwnerNFT` pairing intact.
  /// §16, used here to move the position's `take_profit_price`. That field is
  /// the standing instruction the take-profit route reads, so being able to
  /// place it above and then below the oracle's rate is what shows the gate
  /// working in both directions.
  async modifyPosition(tpNum = 5n, tpDen = 1n): Promise<void> {
    const record = `${OUT_FOLDER}/${NETWORK.toLowerCase()}.json`;
    const rec = await Bun.file(record).json();
    // §16 moves a position's own take-profit price, and every position has one
    // however it was opened — a claim is not part of it. `liquidate` reads the
    // record the same way.
    // A record holds one entry per opening arm and keeps the last of each, so
    // several of them name loans that have since been closed and had their NFTs
    // burned. Ask the chain which is still open rather than guessing an order.
    const target = await this.liveLoan(rec);
    const nft: TupleAsset = [rec.protocolNft.policyId, rec.protocolNft.assetName];
    const positionScript = ours().position(nft);
    const walletAddr = await this.lucid.wallet().address();
    const registry = await this.byNft(rec.protocolNft.policyId, rec.protocolNft.assetName, "the ProtocolNFT");
    const position = await this.byNft(target.positionNft.policyId, target.positionNft.assetName, "the PositionNFT");
    const positionOwnerName = target.positionNft.assetName + Buffer.from("OWN").toString("hex");
    const owner = await this.byNft(target.positionNft.policyId, positionOwnerName, "the PositionOwnerNFT");
    const positionRef = await resolve(rec.referenceScripts.position, 0);
    const fundingRow = this.leanest(await this.kupo(walletAddr), 1)[0];
    if (!fundingRow) throw new Error("no funding UTxO");
    const funding = await resolve(fundingRow.transaction_id, fundingRow.output_index);

    const pd = Data.from(position.datum!) as Constr<any>;
    // §16.2.6, §16.2.7 — a take-profit price is set and the execution floor is
    // raised; the other three fields are copied.
    const out = new Constr(0, [
      pd.fields[0], new Constr(0, [tpNum, tpDen]),
      (pd.fields[2] as bigint) + 1_000_000n,
      pd.fields[3], pd.fields[4],
    ]);

    const sortedRefs = [registry, positionRef].sort((a, b) =>
      a.txHash === b.txHash ? a.outputIndex - b.outputIndex : (a.txHash < b.txHash ? -1 : 1));
    const refIdx = (u: UTxO) => BigInt(sortedRefs.findIndex(
      (r) => r.txHash === u.txHash && r.outputIndex === u.outputIndex));
    const wallet = this.distinct([owner, funding]);
    const all = [position, ...wallet];
    const [positionIn, ownerIn] = getInputIndices([position, owner], all) as bigint[];
    // `ModifyPosition` is position action index 2.
    const rdmr = Data.to(new Constr(0, [
      [new Constr(2, [positionIn!, ownerIn!, 0n])], refIdx(registry),
    ]));
    console.log(`  take_profit ${(pd.fields[1] as Constr<any>).fields.join("/")} -> ${tpNum}/${tpDen}` +
      `, min_execution ${pd.fields[2]} -> ${(pd.fields[2] as bigint) + 1_000_000n}`);
    const { from, to } = this.window();
    const refBytes = sortedRefs.reduce((n, u) => n + (u.scriptRef ? u.scriptRef.script.length / 2 : 0), 0);

    this.lucid.overrideUTxOs(wallet);
    const tx = await this.retry("build modify-position", () =>
      this.lucid
        .newTx()
        .setMinFee(1_500_000n + BigInt(Math.ceil(refBytes * 25)))
        .collectFrom([position], rdmr)
        .collectFrom(wallet)
        .readFrom(sortedRefs)
        .withdraw(validatorToRewardAddress(NETWORK, positionScript), 0n, rdmr)
        .pay.ToContract(position.address, { kind: "inline", value: Data.to(out) },
          Object.fromEntries(Object.entries(position.assets)))
        .validFrom(from)
        .validTo(to)
        .complete({ setCollateral: 15_000_000n }),
      2,
    );
    const hash = await this.submit("  modify-position", tx);
    rec.modifyPosition = { tx: hash };
    await Bun.write(record, JSON.stringify(rec, null, 2) + "\n");
    console.log(`\nupdated ${record}`);
  }

  /// §12.3 `Rollback` of an `Opening` claim — the venue gave the money back, so
  /// the loan and the position end and the pool is repaid what came back.
  ///
  /// Permissionless, and paid `rollback_tip` out of the returned lovelace. The
  /// returned input is the proof: §12.2 tells a return from a fill by the **sold**
  /// leg, which no fill can carry in full.
  async rollback(): Promise<void> {
    const record = `${OUT_FOLDER}/${NETWORK.toLowerCase()}.json`;
    const rec = await Bun.file(record).json();
    // §4.3 and §12 unwind an `Opening` claim; ask the chain which loan holds one.
    const target = await this.liveLoan(rec, Deployer.opening);
    target.bindingNft = Deployer.bindingOf(target);
    if (!target?.bindingNft) throw new Error("no claim recorded");
    const nft: TupleAsset = [rec.protocolNft.policyId, rec.protocolNft.assetName];
    const v = ours();
    const venue = minswapV2For(NETWORK);
    const built = {
      loan_close: v.loan_close(nft), position: v.position(nft), pool: v.pool(nft),
      adapter_minswap: minswapAdapter(nft, venue.orderSkh, venue.poolSkh, venue.poolNftPolicy),
    };
    const loanSkh = validatorToScriptHash(v.loan(nft));
    const adapterSkh = validatorToScriptHash(built.adapter_minswap);
    const walletAddr = await this.lucid.wallet().address();
    const registry = await this.byNft(rec.protocolNft.policyId, rec.protocolNft.assetName, "the ProtocolNFT");
    const { market, pool } = await this.marketPool(rec, ACTIVE_KEY);
    const loan = await this.loanByOwner(target.loanNft.policyId, target.loanNft.assetName, target.loanOwnerNft.assetName);
    const position = await this.byNft(target.positionNft.policyId, target.positionNft.assetName, "the PositionNFT");
    const refund = await this.byNft(
      target.bindingNft.policyId, target.bindingNft.assetName, "the BindingNFT");
    if (refund.datum || refund.datumHash) {
      throw new Error("the binding NFT still rides a venue order — cancel it first");
    }
    const scriptRefs = await Promise.all(
      (["loan", "loan_close", "position", "pool", "adapter_minswap"] as const)
        .map((n) => resolve(rec.referenceScripts[n], 0)));
    const fundingRow = this.leanest(await this.kupo(walletAddr), 1)[0];
    if (!fundingRow) throw new Error("no funding UTxO");
    const funding = await resolve(fundingRow.transaction_id, fundingRow.output_index);

    // ---------------------------------------------------------------- numbers
    const ld = Data.from(loan.datum!) as Constr<any>;
    const loanAmount = ld.fields[2] as bigint;
    const initialIndex = ld.fields[3] as bigint;
    const claim = (ld.fields[4] as Constr<any>).fields[0] as Constr<any>;
    const expiry = claim.fields[6] as bigint;
    const sold = claim.fields[4] as bigint;
    // §12.2's gate wants `tx_start > expiry` where the return is partial, and the
    // window's start is what the script sees.
    const { from, to, startMs } = this.window();
    if (startMs <= expiry) {
      throw new Error(`the claim expires at ${expiry}; nothing to roll back yet`);
    }
    const st = this.poolState(pool, startMs, ACTIVE);
    const supplyUnit = `${ACTIVE.supplyToken.policyId}${ACTIVE.supplyToken.assetName}`;
    const refundAda = BigInt(refund.assets["lovelace"]!);
    const recovered = SUPPLY_IS_TOKEN ? (refund.assets[supplyUnit] ?? 0n) : refundAda - MIN_ADA;
    if (recovered < sold) {
      console.log(`  recovered ${recovered} is short of sold ${sold}; §12.2.5 admits it only past expiry + the window`);
    }
    const debt = (loanAmount * st.outIndex) / initialIndex;
    const debtRepaid = debt < recovered ? debt : recovered;
    const shortfall = debt > debtRepaid ? debt - debtRepaid : 0n;
    // §12.2.6 — both minADAs are freed, and the pool's repayment and the tip come
    // out of what the venue returned.
    const remainAda = refundAda + 2n * MIN_ADA - ACTIVE.rollbackTip
      - (SUPPLY_IS_TOKEN ? 0n : debtRepaid);
    const remainSupply = SUPPLY_IS_TOKEN ? recovered - debtRepaid : 0n;

    const totalSupply = max0(st.inSupply + st.accrued - st.accruedFee - shortfall);
    const totalBorrow = max0(st.inBorrow + st.accrued - debt);
    const poolOut = new Constr(0, [
      totalSupply, st.inDtoken, totalBorrow,
      borrowApy(ACTIVE.baseRate, ACTIVE.powerBase, totalSupply, totalBorrow),
      st.inFee + st.accruedFee, st.outIndex, st.interestTime,
      st.pd.fields[7], (st.pd.fields[8] as bigint) + shortfall,
    ]);
    const poolOutAda = SUPPLY_IS_TOKEN
      ? BigInt(pool.assets["lovelace"]!)
      : BigInt(pool.assets["lovelace"]!) + debtRepaid;
    const poolOutSupply = SUPPLY_IS_TOKEN ? (pool.assets[supplyUnit] ?? 0n) + debtRepaid : 0n;

    const positionNftName = target.positionNft.assetName;
    const ownerName = target.loanOwnerNft.assetName;
    const remainName = positionNftName + Buffer.from("RMN").toString("hex");
    const loanNftUnit = toUnit(target.loanNft.policyId, target.loanNft.assetName);
    const loanOwnerUnit = toUnit(target.loanNft.policyId, ownerName);
    const bindingUnit = toUnit(target.bindingNft.policyId, target.bindingNft.assetName);
    const remainUnit = toUnit(target.loanNft.policyId, remainName);
    const positionUnit = toUnit(target.positionNft.policyId, positionNftName);
    const marketUnit = toUnit(rec[ACTIVE_KEY].marketNft.policyId, rec[ACTIVE_KEY].marketNft.assetName);
    const pdatum = Data.from(position.datum!) as Constr<any>;
    const remainDatum = new Constr(0, [
      [target.positionNft.policyId, positionNftName + Buffer.from("OWN").toString("hex")],
      pdatum.fields[4], ACTIVE.collectorReward,
    ]);
    const positionStake = getAddressDetails(position.address).stakeCredential;

    const refs = [registry, market, ...scriptRefs];
    const sortedRefs = [...refs].sort((a, b) =>
      a.txHash === b.txHash ? a.outputIndex - b.outputIndex : (a.txHash < b.txHash ? -1 : 1));
    const refIdx = (u: UTxO) => BigInt(sortedRefs.findIndex(
      (r) => r.txHash === u.txHash && r.outputIndex === u.outputIndex));
    const all = this.distinct([loan, position, refund, pool, funding]);
    const [loanIn, positionIn, refundIn, poolIn] =
      getInputIndices([loan, position, refund, pool], all) as bigint[];
    const OUT = { remain: 0n, pool: 1n, tip: 2n };
    const protoRef = refIdx(registry);
    const marketRef = refIdx(market);

    // `Rollback` is loan action index 4. `order_in_idx` is `-1`: §12.3.9 then
    // requires no order UTxO among the inputs at all.
    const loanRdmr = Data.to(new Constr(0, [
      [new Constr(4, [
        loanIn!, positionIn!, refundIn!, -1n, -1n, poolIn!, OUT.pool,
        OUT.remain, -1n, -1n, OUT.tip, marketRef, adapterSkh,
      ])],
      protoRef,
    ]));
    const positionRdmr = Data.to(new Constr(0, [
      [new Constr(3, [[new Constr(0, [positionIn!, -1n, loanIn!, -1n, -1n])]])],
      protoRef,
    ]));
    const poolRdmr = Data.to(new Constr(0, [
      [new Constr(0, [poolIn!, OUT.pool, marketRef, [ownerName]])], protoRef,
    ]));
    // `Recovered` is route index 2, and the adapter reads no market on it.
    const adapterRdmr = Data.to(new Constr(0, [
      [new Constr(0, [
        ownerName,
        new Constr(2, [
          [ACTIVE.supplyToken.policyId, ACTIVE.supplyToken.assetName],
          recovered,
          [loanSkh, target.bindingNft.assetName],
        ]),
      ])],
      protoRef, -1n,
    ]));

    console.log(`  recovered ${recovered} of ${sold} sold, debt ${debt}, repaid ${debtRepaid}, remain ${remainAda}`);
    const refBytes = sortedRefs.reduce((n, u) => n + (u.scriptRef ? u.scriptRef.script.length / 2 : 0), 0);

    this.lucid.overrideUTxOs([funding]);
    const tx = await this.retry("build rollback", () =>
      this.lucid
        .newTx()
        .setMinFee(2_000_000n + BigInt(Math.ceil(refBytes * 25)))
        .collectFrom([loan], loanRdmr)
        .collectFrom([refund], loanRdmr)
        .collectFrom([position], positionRdmr)
        .collectFrom([pool], poolRdmr)
        .collectFrom([funding])
        .readFrom(sortedRefs)
        .mintAssets({
          [loanNftUnit]: -1n, [loanOwnerUnit]: -1n, [bindingUnit]: -1n, [remainUnit]: 1n,
        }, loanRdmr)
        .mintAssets({ [positionUnit]: -1n }, positionRdmr)
        .withdraw(validatorToRewardAddress(NETWORK, built.loan_close), 0n, loanRdmr)
        .withdraw(validatorToRewardAddress(NETWORK, built.position), 0n, positionRdmr)
        .withdraw(validatorToRewardAddress(NETWORK, built.pool), 0n, poolRdmr)
        .withdraw(validatorToRewardAddress(NETWORK, built.adapter_minswap), 0n, adapterRdmr)
        .pay.ToContract(
          validatorToAddress(NETWORK, v.loan(nft), positionStake),
          { kind: "inline", value: Data.to(remainDatum) },
          { lovelace: remainAda, [remainUnit]: 1n,
            ...(SUPPLY_IS_TOKEN && remainSupply > 0n ? { [supplyUnit]: remainSupply } : {}) })
        .pay.ToContract(pool.address, { kind: "inline", value: Data.to(poolOut) },
          { lovelace: poolOutAda, [marketUnit]: 1n,
            ...(SUPPLY_IS_TOKEN ? { [supplyUnit]: poolOutSupply } : {}) })
        // §12.3.8 — exactly `rollback_tip`.
        .pay.ToAddress(walletAddr, { lovelace: ACTIVE.rollbackTip })
        .validFrom(from)
        .validTo(to)
        .complete({ setCollateral: 15_000_000n }),
      2,
    );
    const hash = await this.submit("  rollback", tx);
    rec.rollback = {
      tx: hash, recovered: recovered.toString(), repaid: debtRepaid.toString(),
      shortfall: shortfall.toString(),
      remainNft: { policyId: target.loanNft.policyId, assetName: remainName },
    };
    await Bun.write(record, JSON.stringify(rec, null, 2) + "\n");
    console.log(`\nupdated ${record}`);
  }

  /// §4.3's last row — past `claim.expiry`, the venue order is cancelled and the
  /// claim comes back as a refund for §12 to unwind.
  ///
  /// Two validators agree to it. The venue's own order script is spent with
  /// `CancelOrderByOwner`, and the `canceller` its datum names is
  /// `ByWithdraw(cancel_skh)` — so this protocol's `cancel` script, which has no
  /// spend purpose at all, authorises by withdrawing zero. `cancel`'s redeemer
  /// names the `BindingNFT` leaving the venue and the loan reference input where
  /// that claim's `expiry` is written, which is what makes the expiry gate a check
  /// on *this* cancel rather than on any expired claim the caller can point at.
  async cancelClaim(): Promise<void> {
    const record = `${OUT_FOLDER}/${NETWORK.toLowerCase()}.json`;
    const rec = await Bun.file(record).json();
    // §4.3 and §12 unwind an `Opening` claim; ask the chain which loan holds one.
    const target = await this.liveLoan(rec, Deployer.opening);
    target.bindingNft = Deployer.bindingOf(target);
    if (!target?.bindingNft) throw new Error("no claim recorded");
    const nft: TupleAsset = [rec.protocolNft.policyId, rec.protocolNft.assetName];
    const v = ours();
    const cancelScript = v.cancel(nft);
    const loanSkh = validatorToScriptHash(v.loan(nft));
    const venue = minswapV2For(NETWORK);
    const walletAddr = await this.lucid.wallet().address();

    const registry = await this.byNft(rec.protocolNft.policyId, rec.protocolNft.assetName, "the ProtocolNFT");
    const loan = await this.loanByOwner(target.loanNft.policyId, target.loanNft.assetName, target.loanOwnerNft.assetName);
    const order = await this.byNft(
      target.bindingNft.policyId, target.bindingNft.assetName, "the BindingNFT");
    if (!order.datum) throw new Error("the venue order is already gone — it filled or was cancelled");
    const cancelRef = await resolve(rec.referenceScripts.cancel, 0);
    const loanRef = await resolve(rec.referenceScripts.loan, 0);
    const fundingRow = this.leanest(await this.kupo(walletAddr), 1)[0];
    if (!fundingRow) throw new Error("no funding UTxO");
    const funding = await resolve(fundingRow.transaction_id, fundingRow.output_index);

    // The venue publishes no reference script this deployment can cite, so its
    // order validator is fetched by hash and attached.
    const r = await fetch(`${KUPO_ENDPOINT}/scripts/${venue.orderSkh}`);
    if (!r.ok) throw new Error(`the venue's order script is not on chain: ${r.status}`);
    const body = (await r.json()) as { language?: string; script?: string };
    if (!body.script) throw new Error("the venue's order script has no bytes");
    const venueScript: Script = {
      type: body.language === "plutus:v3" ? "PlutusV3" : "PlutusV2",
      script: body.script,
    };

    const ld = Data.from(loan.datum!) as Constr<any>;
    const claim = (ld.fields[4] as Constr<any>).fields[0] as Constr<any>;
    const expiry = claim.fields[6] as bigint;
    // `cancel` requires `tx_start > claim.expiry`, and `tx_start` is what the
    // script sees. The ordinary window already starts after a claim that expired
    // a while ago; one pinned to the expiry itself would have its upper bound in
    // the past and the node would reject it as outside its validity interval.
    const { from, to, startMs } = this.window();
    if (startMs <= expiry) {
      throw new Error(`the claim expires at ${expiry}; ${Math.ceil((Number(expiry) - from) / 1000)}s to wait`);
    }

    const bindingUnit = toUnit(target.bindingNft.policyId, target.bindingNft.assetName);
    const stake = getAddressDetails(loan.address).stakeCredential;
    const refs = [registry, loan, cancelRef, loanRef];
    const sortedRefs = [...refs].sort((a, b) =>
      a.txHash === b.txHash ? a.outputIndex - b.outputIndex : (a.txHash < b.txHash ? -1 : 1));
    const refIdx = (u: UTxO) => BigInt(sortedRefs.findIndex(
      (r) => r.txHash === u.txHash && r.outputIndex === u.outputIndex));
    const cancelRdmr = Data.to(new Constr(0, [
      [new Constr(0, [[loanSkh, target.bindingNft.assetName], refIdx(loan)])],
      refIdx(registry),
    ]));
    // The venue's own redeemer: `CancelOrderByOwner`.
    const venueRdmr = Data.to(new Constr(1, []));
    const refundAda = BigInt(order.assets["lovelace"]!);
    if (order.assets[bindingUnit] !== 1n) throw new Error("the venue order does not hold the BindingNFT");
    const refundSold = order.assets[`${ACTIVE.supplyToken.policyId}${ACTIVE.supplyToken.assetName}`] ?? 0n;
    console.log(`  cancelling ${order.txHash.slice(0, 12)}#${order.outputIndex}, refunding ${refundAda} lovelace`
      + (SUPPLY_IS_TOKEN ? ` and ${refundSold} of the supply token` : "") + " to the loan script");

    this.lucid.overrideUTxOs([funding]);
    const tx = await this.retry("build cancel-claim", () =>
      this.lucid
        .newTx()
        .setMinFee(2_500_000n)
        .collectFrom([order], venueRdmr)
        .collectFrom([funding])
        .attach.SpendingValidator(venueScript)
        .readFrom(sortedRefs)
        .withdraw(validatorToRewardAddress(NETWORK, cancelScript), 0n, cancelRdmr)
        // §12.2 reads this input: datum-free, at the loan script, carrying the
        // binding NFT and everything the venue gave back.
        .pay.ToAddress(
          validatorToAddress(NETWORK, v.loan(nft), stake),
          { ...order.assets },
        )
        .validFrom(from)
        .validTo(to)
        .complete({ setCollateral: 15_000_000n }),
      2,
    );
    const hash = await this.submit("  cancel-claim", tx);
    rec.cancelClaim = { tx: hash, refunded: refundAda.toString() };
    await Bun.write(record, JSON.stringify(rec, null, 2) + "\n");
    console.log(`\nupdated ${record}`);
  }

  /// §14.2.5 `AnnounceOracle` — the admin names the oracle that will replace this
  /// one, and the clock starts.
  ///
  /// Nothing changes for anyone reading prices: `oracle_skh` stays as it is until
  /// `RotateOracle`, which may not run until `oracle_ready_at`, a full day later.
  /// That delay is the point of the two-step.
  async announceOracle(pending: string): Promise<void> {
    const record = `${OUT_FOLDER}/${NETWORK.toLowerCase()}.json`;
    const rec = await Bun.file(record).json();
    if (!/^[0-9a-f]{56}$/.test(pending)) {
      throw new Error("the announced oracle must be a 28-byte script hash in hex");
    }
    const nft: TupleAsset = [rec.protocolNft.policyId, rec.protocolNft.assetName];
    const configScript = ours().protocol_config(nft);
    const { registry, admin, funding, walletAddr } = await this.adminContext(rec);
    const configRef = await resolve(rec.referenceScripts.protocol_config, 0);
    const adminUnit = toUnit(rec.adminNft.policyId, rec.adminNft.assetName);

    const pd = Data.from(registry.datum!) as Constr<any>;
    if ((pd.fields[10] as Constr<any>).index !== 1) {
      throw new Error("an oracle is already pending; §14.2.5 will not overwrite it");
    }
    const { from, to } = this.window();
    // §14.2.5 — `oracle_ready_at >= tx_end + oracle_rotation_delay`.
    const readyAt = BigInt(to) + 86_400_000n;
    const out = new Constr(0, [
      ...pd.fields.slice(0, 9), readyAt, new Constr(0, [pending]), ...pd.fields.slice(11),
    ]);

    const sortedRefs = [configRef];
    const wallet = this.distinct([admin, funding]);
    const all = [registry, ...wallet];
    const [configIn, adminIn] = getInputIndices([registry, admin], all) as bigint[];
    // `AnnounceOracle` is protocol-config redeemer index 3.
    const rdmr = Data.to(new Constr(0 + 3, [configIn!, adminIn!, 0n]));
    console.log(`  pending oracle ${pending}, ready at ${readyAt}`);
    const refBytes = sortedRefs.reduce((n, u) => n + (u.scriptRef ? u.scriptRef.script.length / 2 : 0), 0);

    this.lucid.overrideUTxOs(wallet);
    const tx = await this.retry("build announce-oracle", () =>
      this.lucid
        .newTx()
        .setMinFee(1_500_000n + BigInt(Math.ceil(refBytes * 25)))
        .collectFrom([registry], rdmr)
        .collectFrom(wallet)
        .readFrom(sortedRefs)
        .pay.ToContract(registry.address, { kind: "inline", value: Data.to(out) },
          Object.fromEntries(Object.entries(registry.assets)))
        .pay.ToAddress(walletAddr, { [adminUnit]: 1n })
        .validFrom(from)
        .validTo(to)
        .complete({ setCollateral: 15_000_000n }),
      2,
    );
    const hash = await this.submit("  announce-oracle", tx);
    rec.announceOracle = { tx: hash, pendingOracle: pending, readyAt: readyAt.toString() };
    await Bun.write(record, JSON.stringify(rec, null, 2) + "\n");
    console.log(`\nupdated ${record}`);
  }

  /// §15 `UpdateMarketParam` — the admin rewrites the market's parameters.
  ///
  /// A **spend** of the market UTxO rather than a withdrawal, authorised by the
  /// AdminNFT in an input; the value is carried across untouched and every new
  /// number has to clear §1.3's bounds.
  async updateMarketParam(): Promise<void> {
    const record = `${OUT_FOLDER}/${NETWORK.toLowerCase()}.json`;
    const rec = await Bun.file(record).json();
    const nft: TupleAsset = [rec.protocolNft.policyId, rec.protocolNft.assetName];
    const { registry, admin, funding, walletAddr } = await this.adminContext(rec);
    const { market } = await this.marketPool(rec, ACTIVE_KEY);
    const marketRef = await resolve(rec.referenceScripts.market_param, 0);
    const adminUnit = toUnit(rec.adminNft.policyId, rec.adminNft.assetName);

    const md = Data.from(market.datum!) as Constr<any>;
    // `liquidator_reward_cap` — one number, well inside §1.3, so what this proves
    // is the arm rather than the bound.
    const was = md.fields[12] as bigint;
    const out = new Constr(0, [...md.fields.slice(0, 12), was + 200n, ...md.fields.slice(13)]);

    const sortedRefs = [registry, marketRef].sort((a, b) =>
      a.txHash === b.txHash ? a.outputIndex - b.outputIndex : (a.txHash < b.txHash ? -1 : 1));
    const refIdx = (u: UTxO) => BigInt(sortedRefs.findIndex(
      (r) => r.txHash === u.txHash && r.outputIndex === u.outputIndex));
    const wallet = this.distinct([admin, funding]);
    const all = [market, ...wallet];
    const [marketIn, adminIn] = getInputIndices([market, admin], all) as bigint[];
    // `UpdateMarketParam` keeps the `Constr(0, ..)` encoding it had as a record.
    const rdmr = Data.to(new Constr(0, [marketIn!, adminIn!, 0n, refIdx(registry)]));
    console.log(`  liquidator_reward_cap ${was} -> ${was + 200n}`);
    const { from, to } = this.window();
    const refBytes = sortedRefs.reduce((n, u) => n + (u.scriptRef ? u.scriptRef.script.length / 2 : 0), 0);

    this.lucid.overrideUTxOs(wallet);
    const tx = await this.retry("build update-market-param", () =>
      this.lucid
        .newTx()
        .setMinFee(1_500_000n + BigInt(Math.ceil(refBytes * 25)))
        .collectFrom([market], rdmr)
        .collectFrom(wallet)
        .readFrom(sortedRefs)
        .pay.ToContract(market.address, { kind: "inline", value: Data.to(out) },
          Object.fromEntries(Object.entries(market.assets)))
        .pay.ToAddress(walletAddr, { [adminUnit]: 1n })
        .validFrom(from)
        .validTo(to)
        .complete({ setCollateral: 15_000_000n }),
      2,
    );
    const hash = await this.submit("  update-market-param", tx);
    rec.updateMarketParam = { tx: hash, liquidatorRewardCap: (was + 200n).toString() };
    await Bun.write(record, JSON.stringify(rec, null, 2) + "\n");
    console.log(`\nupdated ${record}`);
  }

  /// Sends every asset this deployment has no use for to `host`, and leaves the
  /// three it does in one small UTxO.
  ///
  /// Kept: the AdminNFT, which admin arms spend; the market's collateral, which a
  /// synchronous fill delivers; and the pool's `dToken`, which is this wallet's
  /// claim on the supply it lent. Everything else — a test network's foreign
  /// tokens, the NFTs of superseded genesis runs, order and position NFTs whose
  /// UTxOs are long spent — is what makes a value too large to serialise.
  ///
  /// The three kept assets go to their **own** output rather than into the change:
  /// a builder that picks the clean UTxO then carries no token at all.
  async evict(host: string): Promise<void> {
    if (!host.startsWith("addr")) throw new Error("usage: --evict <address>");
    const record = `${OUT_FOLDER}/${NETWORK.toLowerCase()}.json`;
    const rec = await Bun.file(record).json();
    const walletAddr = await this.lucid.wallet().address();
    if (host === walletAddr) throw new Error("that is this wallet");
    const keepUnits = new Set([
      toUnit(rec.adminNft.policyId, rec.adminNft.assetName),
      toUnit(ACTIVE.collateral.policyId, ACTIVE.collateral.assetName),
      toUnit(rec.registry.poolSkh, rec[ACTIVE_KEY].marketNft.assetName),
    ]);
    const adminUnit = toUnit(rec.adminNft.policyId, rec.adminNft.assetName);
    const rows = (await this.kupo(walletAddr)).filter(
      (r) => !r.script_hash && !Object.keys(r.value.assets ?? {}).includes(
        `${rec.adminNft.policyId}.${rec.adminNft.assetName}`),
    );
    const utxos = this.distinct(rows.map((r) => this.toUtxo(r, walletAddr)));
    const junk: Record<string, bigint> = {};
    const keep: Record<string, bigint> = {};
    for (const u of utxos) {
      for (const [unit, qty] of Object.entries(u.assets)) {
        if (unit === "lovelace") continue;
        const into = keepUnits.has(unit) ? keep : junk;
        into[unit] = (into[unit] ?? 0n) + qty;
      }
    }
    const units = Object.keys(junk);
    if (units.length === 0) {
      console.log("no junk left to move");
      return;
    }
    const chunks: Record<string, bigint>[] = [];
    for (let i = 0; i < units.length; i += 60) {
      chunks.push(Object.fromEntries(units.slice(i, i + 60).map((u) => [u, junk[u]!])));
    }
    console.log(`  moving ${units.length} asset(s) to ${host.slice(0, 24)}… in ${chunks.length} output(s)`);
    console.log(`  keeping ${Object.keys(keep).length}: the collateral, the dToken, and the AdminNFT where it is`);

    this.lucid.overrideUTxOs(utxos);
    const tx = await this.retry("build evict", () => {
      let b = this.lucid.newTx().collectFrom(utxos);
      for (const chunk of chunks) b = b.pay.ToAddress(host, chunk);
      if (Object.keys(keep).length > 0) b = b.pay.ToAddress(walletAddr, keep);
      return b.complete();
    });
    const hash = await this.submit("  evict", tx);
    rec.evicted = { tx: hash, host, moved: units.length, kept: Object.keys(keep).length };
    void adminUnit;
    await Bun.write(record, JSON.stringify(rec, null, 2) + "\n");
    console.log(`\nupdated ${record}`);
  }

  /// Collapses the wallet's UTxOs into one clean ADA output and as few token bags
  /// as the value size admits.
  ///
  /// Dust is not free: a builder's coin selection reaches for many small inputs,
  /// and a long input list is what pushes a transaction past `maxTxSize` before it
  /// has carried anything. The AdminNFT is left where it is — a change output has
  /// to carry whatever its input did, so an admin arm that spent a bag would put
  /// the whole bag back into its change.
  async consolidate(): Promise<void> {
    const record = `${OUT_FOLDER}/${NETWORK.toLowerCase()}.json`;
    const rec = await Bun.file(record).json();
    const walletAddr = await this.lucid.wallet().address();
    const adminKey = `${rec.adminNft.policyId}.${rec.adminNft.assetName}`;
    const rows = await this.kupo(walletAddr);
    const held = (r: any) => Object.keys(r.value.assets ?? {});
    const spend = rows.filter(
      (r) => !r.script_hash && !held(r).includes(adminKey),
    );
    if (spend.length < 2) {
      console.log("nothing to collapse");
      return;
    }
    const utxos = this.distinct(spend.map((r) => this.toUtxo(r, walletAddr)));
    const bag: Record<string, bigint> = {};
    let ada = 0n;
    for (const u of utxos) {
      for (const [unit, qty] of Object.entries(u.assets)) {
        if (unit === "lovelace") ada += qty;
        else bag[unit] = (bag[unit] ?? 0n) + qty;
      }
    }
    // One output per sixty assets: a value serialises at about forty bytes each
    // against a `maxValSize` of 5_000, and the outputs have to fit in the same
    // transaction as every input being collapsed.
    const units = Object.keys(bag);
    const chunks: Record<string, bigint>[] = [];
    for (let i = 0; i < units.length; i += 60) {
      chunks.push(Object.fromEntries(units.slice(i, i + 60).map((u) => [u, bag[u]!])));
    }
    console.log(`  collapsing ${utxos.length} UTxO, ${ada} lovelace and ${units.length} assets`);
    console.log(`  into ${chunks.length} token bag(s) and one clean output; the AdminNFT is left alone`);

    this.lucid.overrideUTxOs(utxos);
    const tx = await this.retry("build consolidate", () => {
      let b = this.lucid.newTx().collectFrom(utxos);
      // Each bag is paid without lovelace, so the builder gives it its own minADA
      // and the rest of the ADA comes back as one clean change output.
      for (const chunk of chunks) b = b.pay.ToAddress(walletAddr, chunk);
      return b.complete();
    });
    const hash = await this.submit("  consolidate", tx);
    rec.consolidated = { tx: hash, collapsed: utxos.length, bags: chunks.length };
    await Bun.write(record, JSON.stringify(rec, null, 2) + "\n");
    console.log(`\nupdated ${record}`);
  }

  /// Leaves the admin wallet in a shape admin transactions can use: the AdminNFT
  /// alone, the other tokens in one bag, and the ADA clean.
  ///
  /// Every admin arm spends the AdminNFT, and a change output has to carry
  /// whatever its input did. With the NFT sitting beside a hundred test tokens,
  /// that is four kilobytes on every admin transaction, which is enough to push
  /// one carrying a script past `maxTxSize`.
  async tidy(): Promise<void> {
    const record = `${OUT_FOLDER}/${NETWORK.toLowerCase()}.json`;
    const rec = await Bun.file(record).json();
    const walletAddr = await this.lucid.wallet().address();
    const adminUnit = toUnit(rec.adminNft.policyId, rec.adminNft.assetName);
    const rows = (await this.kupo(walletAddr)).filter(
      (r) => !r.script_hash && this.readable(r),
    );
    const holder = rows.find(
      (r) => (r.value.assets ?? {})[`${rec.adminNft.policyId}.${rec.adminNft.assetName}`],
    );
    if (!holder) throw new Error("the AdminNFT is not in a readable wallet UTxO");
    const others = Object.keys(holder.value.assets).length - 1;
    if (others === 0) {
      console.log("the AdminNFT is already on its own");
      return;
    }
    console.log(`splitting the AdminNFT out from ${others} other token(s)`);
    const utxo = this.toUtxo(holder, walletAddr);
    const bag: Record<string, bigint> = {};
    for (const [unit, qty] of Object.entries(utxo.assets)) {
      if (unit !== "lovelace" && unit !== adminUnit) bag[unit] = qty;
    }
    // Both outputs need their own min-ADA, and a hundred-token bag needs about
    // twenty of it. The holder alone rarely covers that, so clean ADA comes too.
    const fuel = this.leanest(rows, 1).map((r) => this.toUtxo(r, walletAddr));
    const set = [utxo, ...fuel.filter((f) => f.txHash !== utxo.txHash || f.outputIndex !== utxo.outputIndex)];
    this.lucid.overrideUTxOs(set);
    const tx = await this.retry("build tidy", () =>
      this.lucid
        .newTx()
        .collectFrom(set)
        .pay.ToAddress(walletAddr, { [adminUnit]: 1n })
        .pay.ToAddress(walletAddr, bag)
        .complete(),
    );
    await this.submit("  tidy", tx);
    console.log("  the AdminNFT now sits alone; the rest is a token bag and clean ADA");
  }

  /// Spends every reference-script UTxO at this wallet and keeps only the ADA.
  ///
  /// An abandoned deployment leaves its reference scripts behind, and the admin
  /// wallet is shared with whoever is testing the admin arms — a stray script
  /// output there is both locked min-ADA and a UTxO someone else has to skip.
  /// The scripts are counted against the 200_000-byte per-transaction reference
  /// budget even when they are only being spent, so they go in measured batches.
  async reclaim(): Promise<void> {
    const walletAddr = await this.lucid.wallet().address();
    const rows = (await this.kupo(walletAddr)).filter((r) => r.script_hash);
    if (rows.length === 0) {
      console.log("no reference script sits at this wallet");
      return;
    }
    console.log(`reclaiming ${rows.length} reference-script UTxO`);
    const sized: { row: any; bytes: number }[] = [];
    for (const row of rows) {
      const r = await fetch(`${KUPO_ENDPOINT}/scripts/${row.script_hash}`);
      const body = r.ok ? ((await r.json()) as { script?: string } | null) : null;
      sized.push({ row, bytes: (body?.script?.length ?? 0) / 2 });
    }
    const BUDGET = 150_000;
    let batch: any[] = [];
    let bytes = 0;
    const flush = async () => {
      if (batch.length === 0) return;
      const utxos = batch.map((r) => this.toUtxo(r, walletAddr));
      this.lucid.overrideUTxOs(utxos);
      // A script carried by a *spent* input counts toward the transaction's
      // reference-script size, which is priced per byte on top of the ordinary
      // fee — and the builder's estimate does not include it, so submission is
      // rejected for an insufficient fee. The floor is set by hand from the
      // measured bytes; the overshoot is pennies against the ADA being freed.
      const floor = 2_000_000n + BigInt(Math.ceil(bytes * 25));
      const tx = await this.retry("build reclaim", () =>
        this.lucid.newTx().collectFrom(utxos).setMinFee(floor).complete(),
      );
      await this.submit(`  reclaim ${batch.length}`, tx);
      batch = [];
      bytes = 0;
    };
    for (const { row, bytes: b } of sized) {
      if (bytes + b > BUDGET) await flush();
      batch.push(row);
      bytes += b;
    }
    await flush();
  }

  /// Spends every reference script this wallet holds, then publishes the whole
  /// set again at `host`.
  ///
  /// A reference script is read-only to whoever cites it, so the host need not be
  /// this wallet — but it decides who can ever reclaim the min-ADA those UTxOs
  /// lock, which for a 14 kB script is around 60 ADA each. Nothing in the
  /// registry points at a reference script's location, so moving them is safe:
  /// only the hashes matter, and those do not change here.
  async republish(host: string): Promise<void> {
    const record = `${OUT_FOLDER}/${NETWORK.toLowerCase()}.json`;
    const rec = await Bun.file(record).json();
    const walletAddr = await this.lucid.wallet().address();
    const rows = (await this.kupo(walletAddr)) as any[];
    const carrying = rows.filter((r) => r.script_hash);
    console.log(`reclaiming ${carrying.length} reference script UTxO`);
    const locked = carrying.reduce((s, r) => s + BigInt(r.value.coins), 0n);
    console.log(`  ${locked} lovelace locked in them`);

    // Spending a UTxO that carries a reference script counts that script against
    // the transaction's 200_000-byte reference-script budget, so the whole set
    // does not fit in one. Batched under a conservative share of it.
    const budget = 120_000;
    if (carrying.length > 0) {
      const resolved = await this.lucid.utxosByOutRef(
        carrying.map((r) => ({ txHash: r.transaction_id, outputIndex: r.output_index })),
      );
      const batches: UTxO[][] = [];
      let batch: UTxO[] = [];
      let size = 0;
      for (const u of resolved) {
        const bytes = (u.scriptRef?.script.length ?? 0) / 2;
        if (batch.length > 0 && size + bytes > budget) {
          batches.push(batch);
          batch = [];
          size = 0;
        }
        batch.push(u);
        size += bytes;
      }
      if (batch.length > 0) batches.push(batch);
      console.log(`  ${batches.length} batch(es) under ${budget} bytes each`);
      for (let i = 0; i < batches.length; i += 1) {
        const fee = this.leanest(await this.kupo(walletAddr), 1).map((r) =>
          this.toUtxo(r, walletAddr),
        );
        const set = [...batches[i]!, ...fee];
        this.lucid.overrideUTxOs(set);
        const tx = await this.retry(`build reclaim ${i + 1}/${batches.length}`, () =>
          this.lucid.newTx().collectFrom(set).complete(),
        );
        await this.submit(`  reclaim ${i + 1}/${batches.length} (${batches[i]!.length} UTxO)`, tx);
      }
    }

    // One transaction per script: a reference script carries the whole compiled
    // program, and the set comes to far more than one transaction can hold.
    const nft: TupleAsset = [rec.protocolNft.policyId, rec.protocolNft.assetName];
    const venue = minswapV2For(NETWORK);
    const v = ours();
    const built: Record<string, Script> = {
      protocol_config: v.protocol_config(nft),
      market_param: v.market_param(nft),
      pool: v.pool(nft),
      loan: v.loan(nft),
      loan_repay: v.loan_repay(nft),
      loan_close: v.loan_close(nft),
      order: v.order(nft),
      position: v.position(nft),
      cancel: v.cancel(nft),
      adapter_sync_generic: v.adapter_sync_generic(nft),
      adapter_minswap: minswapAdapter(
        nft, venue.orderSkh, venue.poolSkh, venue.poolNftPolicy,
      ),
    };
    await this.ensureCleanFunding(walletAddr, 400_000_000n);

    // What the host already carries, so a rerun after a failure does not pay for
    // the same script twice.
    const hosted = new Map<string, string>();
    for (const r of await this.kupo(host)) {
      if (r.script_hash) hosted.set(r.script_hash, r.transaction_id);
    }
    const entries = Object.entries(built);
    let n = 0;
    for (const [name, script] of entries) {
      n += 1;
      const skh = validatorToScriptHash(script);
      if (skh !== rec.scripts[name]?.scriptHash) {
        throw new Error(`${name} builds ${skh} but the record says ${rec.scripts[name]?.scriptHash}`);
      }
      console.log(`publishing ${n}/${entries.length}  ${name}`);
      const already = hosted.get(skh);
      if (already) {
        console.log(`  already at the host in ${already.slice(0, 12)}`);
        rec.referenceScripts[name] = already;
        await Bun.write(record, JSON.stringify(rec, null, 2) + "\n");
        continue;
      }
      const fuel = this.cleanFunding(await this.kupo(walletAddr), 200_000_000n);
      console.log(`     funded by ${fuel.length} token-free UTxO`);
      this.lucid.overrideUTxOs(fuel.map((r) => this.toUtxo(r, walletAddr)));
      const tx = await this.retry(`build ${name}`, () =>
        this.lucid
          .newTx()
          .pay.ToAddressWithData(
            host,
            { kind: "inline", value: Data.to(new Constr(0, [])) },
            {},
            script,
          )
          .complete(),
      );
      rec.referenceScripts[name] = await this.submit(`  ${name}`, tx);
      rec.referenceScriptHost = host;
      await Bun.write(record, JSON.stringify(rec, null, 2) + "\n");
    }
    rec.referenceScriptHost = host;
    await Bun.write(record, JSON.stringify(rec, null, 2) + "\n");
    console.log(`\nall ${entries.length} republished at ${host}`);
    console.log(`updated ${record}`);
  }

  /// Republishes only the scripts whose hash moved.
  ///
  /// `protocol_nft` is a compile-time parameter, so reusing the NFTs a past
  /// genesis minted keeps every unchanged validator at the hash it already has —
  /// its reference script on chain is still the right one. Changing a validator's
  /// source moves only that validator. Nothing is minted here.
  async publishChanged(host?: string): Promise<void> {
    const record = `${OUT_FOLDER}/${NETWORK.toLowerCase()}.json`;
    const rec = await Bun.file(record).json();
    const nft: TupleAsset = [rec.protocolNft.policyId, rec.protocolNft.assetName];
    const venue = minswapV2For(NETWORK);
    const v = ours();
    const built: Record<string, Script> = {
      protocol_config: v.protocol_config(nft),
      market_param: v.market_param(nft),
      pool: v.pool(nft),
      loan: v.loan(nft),
      loan_repay: v.loan_repay(nft),
      loan_close: v.loan_close(nft),
      order: v.order(nft),
      position: v.position(nft),
      cancel: v.cancel(nft),
      adapter_sync_generic: v.adapter_sync_generic(nft),
      adapter_minswap: minswapAdapter(
        nft, venue.orderSkh, venue.poolSkh, venue.poolNftPolicy,
      ),
    };
    const walletAddr = await this.lucid.wallet().address();
    const changed: string[] = [];
    for (const [name, script] of Object.entries(built)) {
      const skh = validatorToScriptHash(script);
      // Also publishes where the hash is unchanged but no reference UTxO was
      // ever recorded, which is what a dropped connection mid-deploy leaves.
      if (rec.scripts[name]?.scriptHash === skh && rec.referenceScripts[name]) {
        console.log(`  ${name.padEnd(22)} unchanged`);
        continue;
      }
      const was = rec.scripts[name]?.scriptHash ?? "(absent)";
      console.log(`  ${name.padEnd(22)} ${was.slice(0, 12)} -> ${skh.slice(0, 12)}, publishing`);
      const tx = await this.retry(`build ${name}`, () =>
        this.lucid
          .newTx()
          .pay.ToAddressWithData(
            host ?? walletAddr,
            { kind: "inline", value: Data.to(new Constr(0, [])) },
            { lovelace: 30_000_000n },
            script,
          )
          .complete(),
      );
      rec.referenceScripts[name] = await this.submit(`  ${name}`, tx);
      rec.scripts[name] = {
        scriptHash: skh,
        sizeBytes: script.script.length / 2,
        address: validatorToAddress(NETWORK, script),
        rewardAddress: validatorToRewardAddress(NETWORK, script),
      };
      changed.push(name);
    }

    // A hash that moved out from under the registry is unusable: the registry
    // names it and §14 item 3 makes that field immutable. Recorded rather than
    // left for a reader to work out.
    const registryFields: [string, string, string | undefined][] = [
      ["pool_skh", "pool", rec.registry?.poolSkh],
      ["loan_skh", "loan", rec.registry?.loanSkh],
      ["loan_repay_skh", "loan_repay", rec.registry?.loanRepaySkh],
      ["loan_close_skh", "loan_close", rec.registry?.loanCloseSkh],
      ["config_pool_skh", "market_param", rec.registry?.configPoolSkh],
      ["order_skh", "order", rec.registry?.orderSkh],
      ["position_skh", "position", rec.registry?.positionSkh],
      ["cancel_skh", "cancel", rec.registry?.cancelSkh],
    ];
    const stale = registryFields.flatMap(([field, name, recorded]) => {
      const script = built[name];
      if (recorded === undefined || script === undefined) return [];
      const sourceBuilds = validatorToScriptHash(script);
      return recorded === sourceBuilds
        ? []
        : [{ field, script: name, registrySays: recorded, sourceBuilds }];
    });
    if (stale.length > 0) rec.registryStale = stale;
    else delete rec.registryStale;

    await Bun.write(record, JSON.stringify(rec, null, 2) + "\n");
    console.log(`\n${changed.length} published, ${Object.keys(built).length - changed.length} unchanged`);
    if (stale.length > 0) {
      console.log(`\n${stale.length} registry field(s) now name a hash the source no longer builds:`);
      for (const s of stale) {
        console.log(`  ${s.field}  registry ${s.registrySays.slice(0, 12)} vs source ${s.sourceBuilds.slice(0, 12)}`);
      }
      console.log("These are immutable per §14 item 3, so those paths need a fresh genesis.");
    }
    console.log(`\nupdated ${record}`);
  }

  /// Rebuilds every script against the `protocol_nft` a past deploy recorded and
  /// compares hashes. This is what makes `deployments/<network>.json` checkable:
  /// `--show` cannot do it, because it derives `protocol_nft` from whichever UTxO
  /// the wallet happens to hold now, so every hash it prints is for a *future*
  /// genesis rather than the one on chain.
  async verify(): Promise<void> {
    const record = `${OUT_FOLDER}/${NETWORK.toLowerCase()}.json`;
    const rec = await Bun.file(record).json();
    const nft: TupleAsset = [rec.protocolNft.policyId, rec.protocolNft.assetName];
    const v = ours();
    let bad = 0;
    for (const [name, entry] of Object.entries(rec.scripts) as [string, any][]) {
      if (name === "adapter_minswap") {
        const venue = minswapV2For(NETWORK);
        const got = validatorToScriptHash(
          minswapAdapter(nft, venue.orderSkh, venue.poolSkh, venue.poolNftPolicy),
        );
        const ok = got === entry.scriptHash;
        if (!ok) bad += 1;
        console.log(`  ${name.padEnd(22)} ${ok ? "matches" : `MISMATCH got ${got}`}`);
        continue;
      }
      const make = (v as Record<string, unknown>)[name];
      if (typeof make !== "function") {
        console.log(`  ${name.padEnd(22)} not in the blueprint`);
        bad += 1;
        continue;
      }
      const built = (make as (n: TupleAsset) => Script)(nft);
      const got = validatorToScriptHash(built);
      const ok = got === entry.scriptHash;
      if (!ok) bad += 1;
      console.log(`  ${name.padEnd(22)} ${ok ? "matches" : `MISMATCH got ${got}`}`);
    }
    console.log(
      bad === 0
        ? `\nall ${Object.keys(rec.scripts).length} hashes reproduce from this source`
        : `\n${bad} script(s) do not reproduce`,
    );
    if (bad > 0) process.exit(1);
  }

  /// Prints every script hash and address without submitting anything, so the
  /// parameterisation can be checked before spending test ADA.
  async show(): Promise<void> {
    const mintScript = oneShotMint();
    const pid = validatorToScriptHash(mintScript);
    const seed = await this.fund(20_000_000n);
    const nftName = hashUtxo(seed, blake2b256);
    console.log(`nft_mint policy   ${pid}`);
    console.log(`seed UTxO         ${seed.txHash}#${seed.outputIndex}`);
    console.log(`ProtocolNFT name  ${nftName}`);
    const v = ours();
    for (const [name, make] of Object.entries(v)) {
      const s = (make as (n: TupleAsset) => Script)([pid, nftName]);
      console.log(`  ${name.padEnd(22)} ${validatorToScriptHash(s)}`);
    }
  }
}
