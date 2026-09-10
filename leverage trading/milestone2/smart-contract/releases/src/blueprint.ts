import { readBlueprint } from "@danogo-js/sdk";
import type { Script } from "@lucid-evolution/lucid";

export type TupleAsset = [string, string];

/// Our validators, all parameterised by `protocol_nft` — biz spec §5 rule 3
/// authenticates the registry by that NFT, so every script is bound to one
/// protocol instance at compile time.
///
/// `protocol_nft` is **one** parameter whose schema is a two-item list, so it is
/// applied as `[[policyId, assetName]]`. The sibling repo passes two arguments
/// because the validator it applies them to declares two.
export function ours() {
  const path = Bun.fileURLToPath(import.meta.resolve("../../plutus.json"));
  const { getValidator } = readBlueprint(path);
  const p = (title: string) => (nft: TupleAsset): Script =>
    getValidator(title, [nft]);
  return {
    protocol_config: p("protocol_config.protocol_config.spend"),
    market_param: p("market_param.market_param.spend"),
    pool: p("pool.pool.withdraw"),
    loan: p("loan.loan.withdraw"),
    loan_repay: p("loan_repay.loan_repay.withdraw"),
    loan_close: p("loan_close.loan_close.withdraw"),
    order: p("order.order.withdraw"),
    position: p("position.position.withdraw"),
    cancel: p("cancel.cancel.withdraw"),
    adapter_sync_generic: p("adapter_sync_generic.adapter_sync_generic.withdraw"),
  };
}

/// `adapter_minswap` additionally names the venue's own three hashes, which are
/// per-network and not known here, so it is deployed separately once a preprod
/// Minswap instance is picked.
export function minswapAdapter(
  nft: TupleAsset,
  venueOrderSkh: string,
  venuePoolSkh: string,
  venuePoolNftPolicy: string,
): Script {
  const path = Bun.fileURLToPath(import.meta.resolve("../../plutus.json"));
  const { getValidator } = readBlueprint(path);
  return getValidator("adapter_minswap.adapter_minswap.withdraw", [
    nft,
    venueOrderSkh,
    venuePoolSkh,
    venuePoolNftPolicy,
  ]);
}

/// daken's one-shot minting policy, used here as `nft_mint`: it mints the
/// ProtocolNFT and the AdminNFT and can never mint again.
export function oneShotMint(): Script {
  const path = Bun.fileURLToPath(import.meta.resolve("../../protocol_script.json"));
  const { getValidator } = readBlueprint(path);
  return getValidator("protocol.one_shot.mint");
}
