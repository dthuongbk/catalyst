# releases

Deploys the contract set to a Cardano network, and drives one transaction per arm
of the spec against it. What it produced on preprod is written up in
[`../DEPLOYMENT.md`](../DEPLOYMENT.md); this file is how to run it.

Every command is `bun run index.ts --<command>`. Each one that submits appends a
line to `../deployments/<network>-transactions.jsonl` and updates
`../deployments/<network>.json`, which is where the next command reads the
registry, the reference-script out-refs and the NFT names it needs. The commands
are therefore ordered: an arm cannot run before the arm that created what it
spends.

## Run

```bash
bun install
cp .env.example .env      # then fill it in
bun run index.ts --show   # prints every script hash, submits nothing
bun run index.ts --deploy
```

`--show` needs only a funded wallet address. It derives the one-shot NFT from the
wallet's leanest UTxO, so on an already-deployed wallet it previews what a *new*
genesis would look like rather than reporting the live one — read
`../deployments/<network>.json` for that, or `--verify`.

## Deployment and registry

| | |
|---|---|
| `--deploy [--at <addr>]` | genesis: mint the AdminNFT, write the registry, publish all ten parameterised scripts as reference scripts at `--at` (default: this wallet) |
| `--deploy-minswap [--at <addr>]` | `adapter_minswap` separately — it names the venue's three per-network hashes, which genesis cannot know |
| `--publish-changed [--at <addr>]` | republish only the validators whose hash moved. Reuses the existing NFTs, so unchanged validators keep the reference scripts they already have. Mints nothing |
| `--republish <addr>` | move the whole reference-script set to another address. Nothing in the registry points at a script's location, so this is safe — but the host decides who can reclaim the locked min-ADA, ~60 ADA for a 14 kB script |
| `--register-stake` | register the stake credential of every withdraw-hosted validator. A zero withdrawal *builds* without it and fails only at submission, Ogmios 3141 |
| `--update-adapters` | §14.2.6, add the adapter hashes to the registry whitelist. Merges into the existing list rather than replacing it |
| `--verify` | rebuild all eleven from `plutus.json` and compare against the record. Submits nothing |

A validator's hash is a compile-time function of `protocol_nft`, so changing any
source moves that validator's hash — and if the moved hash is one the registry
holds immutably (`order_skh` among them), no `protocol_config` transition can
adopt it and the deployment needs a fresh genesis. `DEPLOYMENT.md` section 1 says
which fields those are.

## Markets and the pool

| | |
|---|---|
| `--create-market [ada\|fusdm\|fbtc]` | §20, mint a MarketNFT and open its pool |
| `--supply <units> [ada\|fusdm\|fbtc]` | §18 deposit. `units` is in the market's **supply token**, not lovelace |
| `--redeem <lovelace>` | §18 withdrawal, burning dToken |
| `--withdraw-fee` | §19, the accrued protocol fee to the fee address |
| `--update-market-param` | §15, rewrite the market datum |
| `--announce-oracle <hash>` | §14.2.5. The rotation itself needs `oracle_rotation_delay` (24 h) to pass |

## An order, and filling it

| | |
|---|---|
| `--create-order [priceNum] [limit]` | §6. Default is a market order; `limit` writes `is_market = false` |
| `--fill-minswap [--batcher-fee n]` | §7.2 + §7.4, the asynchronous fill: place a venue order and open the loan against the claim. `--batcher-fee 0` makes a claim no batcher will take, which is how the rollback path is reached |
| `--fill-sync` | §7.3, the synchronous fill: the executor delivers the collateral itself |
| `--borrow <collateral> [loanAmount]` | §7.6 `OpenDirect`, the loan opened with **no order at all**: the borrower deposits the collateral, so there is nothing to buy, no venue and no claim. Omit `loanAmount` and it lends half of what §3 admits |
| `--settle-claim` | §8, the venue filled — settle the claim into the position |
| `--cancel-order` | §9.3 cancel arm. Also what retires a *filled* order UTxO: it burns the OrderNFT and the OrderOwnerNFT, releases the PositionOwnerNFT and returns the unspent `fee_reserve` |

## Closing a loan

| | |
|---|---|
| `--repay` | §10.1 on a synchronous venue |
| `--close-async` then `--settle-close` | §10.2.1 sell claim, then §10.2.2 repay on fill |
| `--liquidate` | §11 |
| `--modify-position` | §16 |
| `--collect-remain` | §13.3, sweep the remain UTxO and burn its NFT |
| `--cancel-claim` then `--rollback` | §4.3 cancel the venue order past its expiry — built against the venue's own validator — then §12.3 |

## Wallet hygiene

The admin wallet is shared with whoever else is testing the admin arms, and a
transaction's value and input list are both bounded. These four keep it buildable.

| | |
|---|---|
| `--consolidate` | collapse dust into as few UTxOs as the 5 000-byte value limit admits |
| `--evict <addr>` | send everything except the AdminNFT, the collateral token and the pool's dToken to another wallet |
| `--tidy` | the AdminNFT alone in one UTxO, the other tokens in one bag, the ADA clean. Every admin arm spends the AdminNFT, and a change output carries whatever its input did |
| `--reclaim` | spend the reference-script UTxOs at this wallet and keep the ADA |

## Environment

| Variable | |
|---|---|
| `NETWORK` | `Preprod`, `Preview` or `Mainnet` |
| `KUPO_ENDPOINT`, `OGMIOS_ENDPOINT` | the chain provider |
| `DEPLOYER_SEED` | 24 words for a funded wallet. `.env` is gitignored; never commit it |
| `OUT_FOLDER` | where the record is written, `../deployments` |

`DUMP_TX=1` writes each signed transaction's CBOR to `/tmp/signed.cbor`, which is
the only way to read back what was actually submitted when a node's error names a
count rather than a cause — a duplicate input was found exactly that way.

Genesis needs roughly 250 test ADA: about 25 per reference script plus fees. A
transaction that cites ten reference scripts pays about 3.7 ADA in fee alone, so
collateral is set to 15 ADA — 150% of the fee, and the 5 ADA a builder defaults to
is short.

## Why two genesis transactions

Biz spec §14 item 4 needs the `AdminNFT` as an **input** to `CreateProtocol`, and
§14.2.3a lets that arm mint nothing but the `ProtocolNFT`. A token minted in a
transaction reaches an output, not an input, so the two cannot share one.

1. `nft_mint` — daken's one-shot policy from `../protocol_script.json` — mints the
   `AdminNFT`, named `blake2b_224(seed) ++ "ADM"`, to the deployer wallet.
2. `CreateProtocol` mints the `ProtocolNFT` and writes the genesis registry,
   reading that `AdminNFT` as an input.

The circular dependency — every validator is parameterised by `protocol_nft`, and
the registry datum must name the resulting script hashes — is broken by deriving
the NFT's name from the funding UTxO before spending it, so both are known before
either transaction is built.
