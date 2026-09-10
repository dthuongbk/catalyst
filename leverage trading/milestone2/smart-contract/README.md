# TIC-30 — leverage order book on Cardano

Aiken validators for a leverage order book with per-DEX adapters, plus the tooling
that deployed them and the record of what that deployment did on chain.

## Read this first

**[`DEPLOYMENT.md`](DEPLOYMENT.md)** is the authoritative account of the live
preprod deployment: every script hash, every parameter, every transaction in the
order it ran, and — section 4 — the shape of each one, purpose by purpose, index by
index. A transaction builder should be written against that section, not against
the validators alone: the shapes there are the ones the validators accepted on
chain, and section 6 lists the eleven mistakes that each cost a rejected
transaction here.

`deployments/preprod.json` is the same deployment in machine-readable form — the
registry, the reference-script out-refs, and the NFT names of everything still
alive. `deployments/preprod-transactions.jsonl` is the append-only trail, one line
per submission.

## Layout

| Path | |
|---|---|
| `validators/` | the eleven validators, one file each |
| `lib/` | the arms themselves — `loan/`, `order/`, `pool/`, `position/`, `protocol/`, `adapter/` |
| `releases/` | the deployment tooling: one command per arm, see [`releases/README.md`](releases/README.md) |
| `deployments/` | what is deployed, and the trail of how it got there |
| `protocol_script.json` | daken's one-shot minting policy, used as `nft_mint` for the ProtocolNFT and AdminNFT |

Three of the validators are one lifecycle across three hosts — `loan` carries
opening, `loan_repay` the repayment arms, `loan_close` the closing arms — so a
transaction that spends a loan UTxO cites two reference scripts. `DEPLOYMENT.md`
section 1 says which.

## Build and test

```bash
aiken check
```

```bash
aiken build -t silent
```

`-t silent` is not optional when you care about the size of a validator: tracing
adds about 64% and the `maxTxSize` of 16 384 bytes is reached with it on.

To confirm that the deployed hashes still come from this source:

```bash
cd releases && bun run index.ts --verify
```

It rebuilds all eleven from `plutus.json` and compares against
`deployments/preprod.json`. It submits nothing.
