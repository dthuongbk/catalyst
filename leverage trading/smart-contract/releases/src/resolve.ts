import type { UTxO } from "@lucid-evolution/lucid";
import { KUPO_ENDPOINT } from "./env.ts";

/// Kupo, read without the provider in the way.
///
/// Two reasons this exists rather than `lucid.utxosByOutRef`:
///
/// - The provider validates Kupo's response against a schema that admits a JS
///   number or a digit string. Minswap and Splash LP tokens are minted at about
///   2^63, which `JSON.parse` turns into a float and neither branch accepts.
/// - It resolves by transaction hash and validates **every** output of that
///   transaction, so one such sibling fails the lookup for an unrelated UTxO.
///
/// Long integers are quoted before parsing, so quantities survive exactly.
export async function kupoJson(pattern: string): Promise<any[]> {
  // The hosted endpoint answers 524 through its proxy under load, which killed a
  // deploy at the ninth reference script of ten. Every read is retried.
  let last = "";
  for (let i = 1; i <= 6; i += 1) {
    try {
      const r = await fetch(`${KUPO_ENDPOINT}/matches/${pattern}?unspent`);
      if (r.ok) {
        const text = (await r.text()).replace(/:\s*(\d{16,})/g, ':"$1"');
        return JSON.parse(text) as any[];
      }
      last = `${r.status}`;
    } catch (e) {
      // A closed socket, not a rejected request: the hosted endpoint drops
      // connections under load and the fetch throws rather than answering.
      last = e instanceof Error ? e.message : String(e);
    }
    await new Promise((f) => setTimeout(f, 3_000 * i));
  }
  throw new Error(`kupo ${pattern}: ${last}`);
}

async function retryFetch(url: string): Promise<Response | null> {
  for (let i = 1; i <= 6; i += 1) {
    try {
      const r = await fetch(url);
      if (r.ok) return r;
      if (r.status === 404) return null;
    } catch {
      // fall through to the sleep
    }
    await new Promise((f) => setTimeout(f, 3_000 * i));
  }
  return null;
}

async function datumOf(hash: string): Promise<string | null> {
  const r = await retryFetch(`${KUPO_ENDPOINT}/datums/${hash}`);
  if (!r) return null;
  const body = (await r.json()) as { datum?: string };
  return body.datum ?? null;
}

async function scriptOf(hash: string): Promise<{ type: string; script: string } | null> {
  const r = await retryFetch(`${KUPO_ENDPOINT}/scripts/${hash}`);
  if (!r) return null;
  const body = (await r.json()) as { language?: string; script?: string };
  if (!body.script) return null;
  const type =
    body.language === "plutus:v3" ? "PlutusV3"
    : body.language === "plutus:v2" ? "PlutusV2"
    : body.language === "plutus:v1" ? "PlutusV1"
    : "Native";
  return { type, script: body.script };
}

function assetsOf(row: any): Record<string, bigint> {
  const out: Record<string, bigint> = { lovelace: BigInt(row.value.coins) };
  for (const [k, q] of Object.entries(row.value.assets ?? {})) {
    out[k.replace(".", "")] = BigInt(q as string);
  }
  return out;
}

/// One UTxO, complete with its inline datum and reference script.
export async function resolve(txHash: string, outputIndex: number): Promise<UTxO> {
  const [row] = await kupoJson(`${outputIndex}@${txHash}`);
  if (!row) throw new Error(`${txHash}#${outputIndex} is not an unspent output`);
  const datum = row.datum_type === "inline" && row.datum_hash
    ? await datumOf(row.datum_hash)
    : null;
  const scriptRef = row.script_hash ? await scriptOf(row.script_hash) : null;
  return {
    txHash: row.transaction_id,
    outputIndex: row.output_index,
    address: row.address,
    assets: assetsOf(row),
    datumHash: row.datum_type === "hash" ? row.datum_hash : null,
    datum,
    scriptRef: scriptRef as UTxO["scriptRef"],
  };
}

export async function resolveMany(refs: [string, number][]): Promise<UTxO[]> {
  return Promise.all(refs.map(([h, i]) => resolve(h, i)));
}
