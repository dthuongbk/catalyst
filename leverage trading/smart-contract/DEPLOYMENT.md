# Preprod deployment — leverage DEX adapter

Every transaction below was built and submitted on **preprod**, against the real
Minswap V2. Each hash is the evidence that the arm it names is buildable, and the
shapes recorded with it are the shapes the validators accepted.

Three arms are absent, and one external fact accounts for all three: the Minswap
preprod batcher filled none of the venue orders this registry posted. Every one of
them was returned at expiry instead, so §7.5, §8 and §10.2.2 — the venue settling,
`SettleClaim` and the repay that a fill funds — have no hash here. The arms that
place those orders, §7.2 and §10.2.1, are in §3 with theirs.

The tooling that produced it is `releases/` in this repository — one command per
arm, `bun run index.ts --<command>`. Its `deployments/preprod.json` is the
machine-readable form of the first two sections and
`deployments/preprod-transactions.jsonl` is the log the third is generated from.

Both hold **this** deployment and nothing else. The transactions of the releases
that preceded it were dropped: their script hashes and their registry no longer
exist, and reading them beside these would only mislead. Git has them.

One caveat on the parameters below. §8 lowers five of them to take `fee_reserve`
from 33 ADA to 19.5, and **has not been submitted**: read §2 as what is live and
§8 as the transaction to run next. It changes no validator source, so every hash
in §1 is unaffected and this registry stays the one in use.

---

## 1. What is deployed

| | |
|---|---|
| Network | Preprod |
| ProtocolNFT | `bc2d3b7cf1009c788b1daf2208a38026ab20d7f8209d896ad1a09c14.92882ac93945e9575af5c5f5b6eebd226a63327f4375a0771718393ae2f12f66` |
| AdminNFT | `bc2d3b7cf1009c788b1daf2208a38026ab20d7f8209d896ad1a09c14.41807518040679c22f08d4a0b8c0cb6c39f40a08da07e427d531add242a29d51` |
| `protocol_config` UTxO | at `addr_test1wpxaflseqekc6g3c0964w83pl0gfeavp5wq6dzzumyc9fwgyedjgz` |
| Genesis | [`4059a4e9a94499ad…`](https://preprod.cardanoscan.io/transaction/4059a4e9a94499adba4b1a6471859b94f34a02ddd13ea23f6d2c1755897e8bd7) |
| Reference scripts held at | `addr_test1qqv5l5k8zax8agy84qanqr44tr4padeescstfh9pexxktapdzjk7wvmnvwrgara7yay07vnhh78chyvla8yeuw5ltxysx2qgkv` |
| Oracle (`oracle_skh`) | `3158c9a7ba551eb3b6b9aa578e7995dec5ce34e272fde0bda76b46d1` |

### Scripts

| Validator | Script hash | Bytes |
|---|---|---:|
| `adapter_minswap` | `9dda1b5cd9126857659905f2aec25cd3e1468ce31dbbeaff29c9b1f2` | 8,591 |
| `adapter_sync_generic` | `b9c12b67425b205c0a95c48e11fc9f4b50b7fbb6461d4912dbb452c1` | 3,326 |
| `cancel` | `127c9b24c9d282dc1d04b184e950bfd34c475969d40e473860928227` | 2,710 |
| `loan` | `619079f0bf32bf6beecd858fa699ef81921f033bc7cabfa23d0363da` | 14,605 |
| `loan_close` | `49603aea7a018f9bf821fd92290012b376ed117b2c316ecf22b25ab6` | 14,293 |
| `loan_repay` | `bf30f525d1a7fca156ab4ab776c24d34322b65ffab9f9a31192d8b72` | 13,112 |
| `market_param` | `6f8a501f011d9182250c1ce798f55ecf64c4b583f97b08f836f8b81a` | 6,115 |
| `order` | `556737da840f96668759c10259a979b49af03c7b1f65b2b6270caf13` | 13,384 |
| `pool` | `be26684781e1754344770c391dea8e2faeff0dfef19f7731a136cc77` | 12,566 |
| `position` | `17d09609ae033aaa7870b93400d5551861339ed7f3a75613212e9223` | 7,075 |
| `protocol_config` | `4dd4fe19066d8d22387975571e21fbd09cf581a381a6885cd93054b9` | 4,029 |

### Markets

| Key | Lends | Collateral | MarketNFT |
|---|---|---|---|
| `market` | ADA | fUSDM | `57234f1a655324a9d9c9b300…` |
| `marketFusdm` | fUSDM | fBTC | `8317111b23f8353d53efb2cb…` |
| `marketFbtc` | fBTC | fUSDM | `188439b3547575a6ab456775…` |

## 2. Parameters

One protocol hosts three markets, each `CreateMarket` minting its own MarketNFT
from its own seed, all read through the one shared registry:

| Market | Record key | Lends | Collateral | Supplied |
|---|---|---|---|---|
| **ADA** | `market` | ADA | fUSDM | 1,000 ADA, less a 100 ADA redemption |
| **fUSDM** | `marketFusdm` | fUSDM | fBTC | 10,000 fUSDM |
| **fBTC** | `marketFbtc` | fBTC | fUSDM | 1 fBTC |

The loan lifecycle ran on the ADA market. The other two are the leverage pair —
borrow fUSDM against fBTC to go long, borrow fBTC against fUSDM to go short — and
they were opened and funded, but every arm that would put them to work reads a
price. §5.

- fUSDM `834a15101873b4e1ddfaa830df46792913995d8738dcde34eda27905.665553444d`
- fBTC `007c4fc75b7662fc735177aa714da9d1b06af5644df199fef39e5fc1.66425443`
- ADA is the empty policy and the empty name, `["", ""]` in every datum.

**The two tokens do not carry the same decimals**, and an earlier release of this
document said they did. fUSDM has six and fBTC has **eight**. Neither has token
registry metadata on preprod, so the mint is the only authority, and a transfer
described as "10M USDM and 10 BTC" arrived as 1e13 and 1e9 units. It matters
because the price aggregator quotes a **human-readable** rate — quote token per
whole base token — while every validator here computes in units, so the two
decimal places stand between the two. The pair whose decimals agree, ADA against
fUSDM, scales by one, which is why this stayed invisible until fBTC met fUSDM and
made collateral appear to be worth a hundred times what it is.

Where that scaling belongs is **not** settled by this deployment. `releases/`
applies it on the way into the oracle's redeemer, which is wrong if the oracle
verifies the rate it is handed — and it does. Sending the raw rate instead was
tried and refused for other reasons (§5), so the question is open: the arithmetic
that consumes a price is in the validators, and it is the validators, not the
tooling, that should scale a human-readable rate into units. That needs the
decimals on chain, which no datum carries today.

## 3. Every transaction, in the order it ran

Sixty-two transactions, every one of them on this registry. `sweep`, `tidy` and
`consolidate` are wallet hygiene rather than arms of the spec — they are listed
because they were submitted, not because they prove anything.

| # | Command | What it proves | Transaction |
|---:|---|---|---|
| 1 | `genesis` | §14 genesis — the registry | [`4059a4e9a94499ad…`](https://preprod.cardanoscan.io/transaction/4059a4e9a94499adba4b1a6471859b94f34a02ddd13ea23f6d2c1755897e8bd7) |
| 2 | `publish protocol_config` | §5 rule 4 — a reference script | [`2b687644d7921577…`](https://preprod.cardanoscan.io/transaction/2b687644d7921577c4ff6137713444239980b32d3611052a5b4f6077c4a582b1) |
| 3 | `publish market_param` | §5 rule 4 — a reference script | [`db7276b5513720e7…`](https://preprod.cardanoscan.io/transaction/db7276b5513720e7a92871ce755aede2738280580a0ccb1bf4a6766cadff6ad7) |
| 4 | `publish pool` | §5 rule 4 — a reference script | [`62d2757b3cfa83aa…`](https://preprod.cardanoscan.io/transaction/62d2757b3cfa83aa2d530e2874870a696b6990aaf56d5ab13dc960cb65c4184e) |
| 5 | `publish loan` | §5 rule 4 — a reference script | [`ff4ce0e5d862d9b5…`](https://preprod.cardanoscan.io/transaction/ff4ce0e5d862d9b5a998b40e603179a88981f05c0a7021bea2bdf5f89d8226b3) |
| 6 | `publish loan_repay` | §5 rule 4 — a reference script | [`6f684d421e588420…`](https://preprod.cardanoscan.io/transaction/6f684d421e588420b1308cf0e51939f231991a9da235fa0a5b09dd3ccc0726d0) |
| 7 | `publish loan_close` | §5 rule 4 — a reference script | [`8b5a3767c93aa9f0…`](https://preprod.cardanoscan.io/transaction/8b5a3767c93aa9f0a295fe24a43ecdcb7a0904a4ef6bb14a59dc15fa52463dd4) |
| 8 | `publish order` | §5 rule 4 — a reference script | [`054991203b3b457b…`](https://preprod.cardanoscan.io/transaction/054991203b3b457bad7c8f7731ddce9a8bab2448c177538005ff96b41b36d8f0) |
| 9 | `publish position` | §5 rule 4 — a reference script | [`32fca2042218bd16…`](https://preprod.cardanoscan.io/transaction/32fca2042218bd165a6d9532c34945af5e3301286751016a5e4fb814b96349db) |
| 10 | `publish cancel` | §5 rule 4 — a reference script | [`bab42f50cc0501ed…`](https://preprod.cardanoscan.io/transaction/bab42f50cc0501edb2c6c4fbb97fbf5a01d88e1a7b59c9fcf0e1bae4e9ae787b) |
| 11 | `publish adapter_sync_generic` | §5 rule 4 — the venue adapter | [`da05c6b19f6f082a…`](https://preprod.cardanoscan.io/transaction/da05c6b19f6f082ab6bb382a5dc18d74976aa5ecea5d70435a7f48e13ec0b0f7) |
| 12 | `publish adapter_minswap` | §5 rule 4 — the venue adapter | [`ff8766aca554dfc9…`](https://preprod.cardanoscan.io/transaction/ff8766aca554dfc9a0ec20d912f17e3d64f8ef9b4dfff779a62a39e0adbe52ce) |
| 13 | `register 9 account(s)` | stake registration | [`ab5aa2539c68afbe…`](https://preprod.cardanoscan.io/transaction/ab5aa2539c68afbe4a40b23f3cf130631254dee54a67793da7b7bcd6d9cc2b3b) |
| 14 | `update-adapters` | §14.2.6 `UpdateAdapters` | [`62b810fe43147c21…`](https://preprod.cardanoscan.io/transaction/62b810fe43147c212ea3dc4b89f5b9cb47cb2f6a17751af94d39abd58b783be3) |
| 15 | `create-market` | §20 `CreateMarket` | [`4ee71d7bfc1bb3f0…`](https://preprod.cardanoscan.io/transaction/4ee71d7bfc1bb3f05211079b773b7dd50d4b3d3b2ffbe9a5be8b10d01129fb00) |
| 16 | `supply` | §18 `TopupWithdraw`, deposit | [`c2cf3d327ed13e82…`](https://preprod.cardanoscan.io/transaction/c2cf3d327ed13e824c0019a9eb8b0cdd0e8d8e62a74b3e48fd6863b6771f145f) |
| 17 | `create-market` | §20 `CreateMarket` | [`1a400bd84402d4f1…`](https://preprod.cardanoscan.io/transaction/1a400bd84402d4f1b3df7485f37edfa77d9942653032f5c77bb1701a4e8997b8) |
| 18 | `supply` | §18 `TopupWithdraw`, deposit | [`cccbfb25b7cce1b1…`](https://preprod.cardanoscan.io/transaction/cccbfb25b7cce1b18115b2bf8b589d673074c4c2418f1beb7dfd6f1293dff2c2) |
| 19 | `create-market` | §20 `CreateMarket` | [`48751d0e51ac64ea…`](https://preprod.cardanoscan.io/transaction/48751d0e51ac64eac7f9b447db5834c53efbb2c5dacd5c6f1d5cbe1ec094b5ec) |
| 20 | `supply` | §18 `TopupWithdraw`, deposit | [`59588286c9e5b19f…`](https://preprod.cardanoscan.io/transaction/59588286c9e5b19f14443524aacc7a80abb51c67edab8aae93cef75cd926af25) |
| 21 | `sweep` | wallet hygiene | [`58ea2e516497d565…`](https://preprod.cardanoscan.io/transaction/58ea2e516497d565146e7f8cca9bfd1f88631030af2826694f2da8c9d7632b56) |
| 22 | `create-order` | §6 `CreateOrder` | [`a0e2352fc8f024eb…`](https://preprod.cardanoscan.io/transaction/a0e2352fc8f024eb1751656a0c2b48e50ad17756b3b12c652b0e45e3f255e0f7) |
| 23 | `fill-sync` | §7.3 the synchronous fill | [`0e7a33f8e1e40fc9…`](https://preprod.cardanoscan.io/transaction/0e7a33f8e1e40fc9f6beaef1bdf9ef979233f773086f0b490b6d237876a2a937) |
| 24 | `cancel-order` | §9.3 `ModifyOrder`, cancel arm | [`50aab4dacc7189b8…`](https://preprod.cardanoscan.io/transaction/50aab4dacc7189b8cbc6bc31a8f166685084dc4a845c4c3e20f4fcfffca55c0b) |
| 25 | `modify-position` | §16 `ModifyPosition` | [`de000d3ad7a1dc14…`](https://preprod.cardanoscan.io/transaction/de000d3ad7a1dc14a9d7e27e01ac14011c25c143d54be1d30ced245d81109481) |
| 26 | `sweep` | wallet hygiene | [`27f75c8b5b88e844…`](https://preprod.cardanoscan.io/transaction/27f75c8b5b88e84461e74fd756f3f9767e076cc15e9cab822e69406235a6f60d) |
| 27 | `create-order` | §6 `CreateOrder` | [`549ee01c823eae12…`](https://preprod.cardanoscan.io/transaction/549ee01c823eae1208bb114a665742e5b398ad2b483d41c3d01f44f2ae5202f0) |
| 28 | `fill-sync` | §7.3 the synchronous fill | [`7ffa065e0f2e7e87…`](https://preprod.cardanoscan.io/transaction/7ffa065e0f2e7e87bce1001648fd1335d78426e80996490d4c10aabf7d8b11e7) |
| 29 | `cancel-order` | §9.3 `ModifyOrder`, cancel arm | [`f878b5228b6fe253…`](https://preprod.cardanoscan.io/transaction/f878b5228b6fe2530ae17fdb31ce828a9fc1c697ff408987c13050194dfe7520) |
| 30 | `modify-position` | §16 `ModifyPosition` | [`15dda5cce9ee3ace…`](https://preprod.cardanoscan.io/transaction/15dda5cce9ee3acebdd4c6462b68fc200bae6400cef9fb69ca99aceffaf424c3) |
| 31 | `sweep` | wallet hygiene | [`ad6092a7a8266536…`](https://preprod.cardanoscan.io/transaction/ad6092a7a8266536cac459c4949763e358c2fc7970ebbd02faba68c89e112128) |
| 32 | `create-order` | §6 `CreateOrder` | [`18059a8d58539d42…`](https://preprod.cardanoscan.io/transaction/18059a8d58539d42ca86f7fd4b128a5e251780715fb6c51b43a556464e1c4058) |
| 33 | `fill-sync` | §7.3 the synchronous fill | [`3cf5affc415cc2d0…`](https://preprod.cardanoscan.io/transaction/3cf5affc415cc2d0e5d705a9688836bed5dca832e854f963a2e29274e4e21066) |
| 34 | `cancel-order` | §9.3 `ModifyOrder`, cancel arm | [`8c96ae00024b44e5…`](https://preprod.cardanoscan.io/transaction/8c96ae00024b44e520fde049e1faafb5970f46f0dce586898b06793f1fb0adae) |
| 35 | `modify-position` | §16 `ModifyPosition` | [`da03548386e1ff37…`](https://preprod.cardanoscan.io/transaction/da03548386e1ff3774296ffc87cd60cc50d59d557bcaeba350b8f9edb81005a7) |
| 36 | `sweep` | wallet hygiene | [`552acdc5d9b5a533…`](https://preprod.cardanoscan.io/transaction/552acdc5d9b5a533dfb944d6fb91d5418d521ae25c5500cf04a7f383066bb0d6) |
| 37 | `take-profit` | §10.2.1 closed by a standing instruction, with no owner input | [`0f4d7ef193509eeb…`](https://preprod.cardanoscan.io/transaction/0f4d7ef193509eeb0f0bdabfdf120e7106674124cd306983c4b7899e1f080e09) |
| 38 | `create-order` | §6 `CreateOrder` | [`568f4081cd9c8f81…`](https://preprod.cardanoscan.io/transaction/568f4081cd9c8f81c318738315efd469ef549744581454820349a17cef434830) |
| 39 | `fill-minswap` | §7.2 the asynchronous fill | [`a95cad9daf5e4639…`](https://preprod.cardanoscan.io/transaction/a95cad9daf5e463920f52630cfb20eacb2dc7b1a5f980cf16621fbef964f4f17) |
| 40 | `create-order` | §6 `CreateOrder` | [`975c6913e48992e5…`](https://preprod.cardanoscan.io/transaction/975c6913e48992e5b7bd7974291426406ff0a439e6e91bcffad9d152aa991320) |
| 41 | `fill-minswap` | §7.2 the asynchronous fill | [`473c398f0b79ffb0…`](https://preprod.cardanoscan.io/transaction/473c398f0b79ffb05fd1efa78d4782f2d8093021adb23a82e9ebea86f3890eb0) |
| 42 | `borrow-async` | §7.6.7 `OpenDirect` with a claim | [`d48f90fd228f7048…`](https://preprod.cardanoscan.io/transaction/d48f90fd228f70484336a1c11353bf80e8cbdbab480163f9a99171bdf90db64f) |
| 43 | `redeem` | §18 `TopupWithdraw`, withdrawal | [`f2df98b2effa77b4…`](https://preprod.cardanoscan.io/transaction/f2df98b2effa77b410b6a9227c4e077e482f74fe31d4e9619d10ef269be9e8c5) |
| 44 | `borrow` | §7.6 `OpenDirect` | [`da659498888c5704…`](https://preprod.cardanoscan.io/transaction/da659498888c57047283a2524c98ad521b859de66f7d125615cd967a18e1fa05) |
| 45 | `repay` | §10.1 `RepayLoan` on a synchronous venue | [`fc7f81855cabfaef…`](https://preprod.cardanoscan.io/transaction/fc7f81855cabfaef5ab302b5ae4e5ea44dc445691a1de67d73fd64b3ddcd2df4) |
| 46 | `sweep` | wallet hygiene | [`bb0a288944a90d10…`](https://preprod.cardanoscan.io/transaction/bb0a288944a90d10fc9fc017df88754b9e5d4b7db341498a37ab01363f0be868) |
| 47 | `create-order` | §6 `CreateOrder` | [`4c87d7d7c7d03493…`](https://preprod.cardanoscan.io/transaction/4c87d7d7c7d0349311ed2fe748f4cf5d8dd91a175be227befdf3f21d65c4b950) |
| 48 | `rollback` | §4.3 the claim the venue returned | [`14e063690a04d8b3…`](https://preprod.cardanoscan.io/transaction/14e063690a04d8b359b8c36ad98145422632002d129d3d8a65390e69d8c1491b) |
| 49 | `collect-remain` | §13.3 `CollectRemain` | [`b01b84b4d3e2ad59…`](https://preprod.cardanoscan.io/transaction/b01b84b4d3e2ad594f43929c3ba736e3b8176869f6d942d09160b788549f09e7) |
| 50 | `cancel-order` | §9.3 `ModifyOrder`, cancel arm | [`4d6d05b6ba8532a5…`](https://preprod.cardanoscan.io/transaction/4d6d05b6ba8532a5491464f2e99e8786284ee53c968a03e9203dec40f556e878) |
| 51 | `rollback` | §4.3 the claim the venue returned | [`a459dfc728cbe504…`](https://preprod.cardanoscan.io/transaction/a459dfc728cbe504e35e99aa016a6a2ee4c507db530fc83b81be691072a111f7) |
| 52 | `collect-remain` | §13.3 `CollectRemain` | [`fd752d73e7f6fd05…`](https://preprod.cardanoscan.io/transaction/fd752d73e7f6fd052db1ea35b3757580e8606c87a5fbdc0790a31dce77e29355) |
| 53 | `create-order` | §6 `CreateOrder` | [`2a3999e8bbab72f0…`](https://preprod.cardanoscan.io/transaction/2a3999e8bbab72f062af6ab6a5b9ae8b3d5884dbcc19ef6fdcdf930750d8e4b4) |
| 54 | `fill-sync` | §7.3 the synchronous fill | [`4d6c0c6673551605…`](https://preprod.cardanoscan.io/transaction/4d6c0c6673551605599f6f082232476f6819a771037827268b3a1beafd52ece9) |
| 55 | `cancel-order` | §9.3 `ModifyOrder`, cancel arm | [`5384a9b481c9576e…`](https://preprod.cardanoscan.io/transaction/5384a9b481c9576e350a3b2733c92961687d484a5ef6a0982ecd76c1aea4696f) |
| 56 | `close-async` | §10.2.1 the sell claim | [`6c35f17bd17bab1b…`](https://preprod.cardanoscan.io/transaction/6c35f17bd17bab1bb69dc5050463b23ac6a2e48715c4bcddf4937d70d9cdba47) |
| 57 | `tidy` | wallet hygiene | [`2e7dd0522b447b56…`](https://preprod.cardanoscan.io/transaction/2e7dd0522b447b56ca437a71a061b4eaa98fd39105ded23e8728dda454398c70) |
| 58 | `update-market-param` | §15 `UpdateMarketParam` | [`5fdd4f52acd0fc75…`](https://preprod.cardanoscan.io/transaction/5fdd4f52acd0fc755e4f93bc5050f2e71f5b0aa4f12d4438b504efb2797939e0) |
| 59 | `withdraw-fee` | §19 `WithdrawFee` | [`1be298df3a15689b…`](https://preprod.cardanoscan.io/transaction/1be298df3a15689b17f8c07b930777f743531901caa086d28bf60db3573c878e) |
| 60 | `borrow` | §7.6 `OpenDirect` | [`6c9fddc74dcb5eeb…`](https://preprod.cardanoscan.io/transaction/6c9fddc74dcb5eeb6e6906872f78a46cbe3d19ab5c59377095d17f45b7a8c441) |
| 61 | `liquidate` | §11 `Liquidate` | [`6eb853e822306d62…`](https://preprod.cardanoscan.io/transaction/6eb853e822306d62547fa833e43429403561b89b8e9388a0e49d8592c203fb40) |
| 62 | `collect-remain` | §13.3 `CollectRemain` | [`dcf192b3aae2e406…`](https://preprod.cardanoscan.io/transaction/dcf192b3aae2e406ea48ff105c2f005149d1c26af6391eb6417f7807d12e61ca) |

## 4. How each transaction is shaped

Three of the subsections below describe arms this deployment did **not** exercise
— 4.8, 4.9 and 4.19, each of them downstream of a venue order actually filling,
and 4.21 ran only its second half. Their shapes are unchanged and worth reading;
what is missing is a hash of this deployment beside them, and the links inside
them belong to an earlier release whose registry no longer exists.

Conventions used throughout:

- **Every index is into the transaction's own canonically ordered list** —
  inputs sorted by `(tx_hash, index)`, reference inputs the same, outputs in the
  order they are added. `-1` means "this arm has no such index" and is checked as
  such; it is never read as a position.
- Aiken **2-tuples encode as a CBOR list**, not a constructor: `TupleAsset` is
  `[policy_id, asset_name]`. Records and sum types encode as `Constr`.
- §5 rule 16: a `Mint` or `Spend` of one of these scripts is validated by a
  **withdrawal of 0** from the script that hosts the arm, carrying an **equal**
  redeemer. Every transaction below therefore lists more withdrawals than a
  reader might expect.
- Reference scripts are cited, never attached. A script carried by a spent input
  is priced per byte too, and the builder's fee estimate omits it.

### 4.1 Genesis

Two transactions. The first mints the ProtocolNFT and the AdminNFT from one seed
input under `daken`'s `one_shot` policy — which admits exactly two names,
`blake2b_256(all inputs)` and `blake2b_256(of that)`, so the seed must be the
**only** input — and writes the registry as the `protocol_config` datum. The
second publishes one reference script per validator, one transaction each: ten of
them come to 88 kB against a 16 kB transaction limit.

No validator can check the genesis datum: `CreateProtocol` carries no
`protocol_in_idx` and at genesis there is no `protocol_config` UTxO to spend. The
registry is trusted to whoever runs it, which is why it is recorded here.

### 4.2 Stake registration

Every withdrawal-hosted script needs its **stake credential registered** before a
zero withdrawal from it will submit; without it the node answers Ogmios error
3141 `incompleteWithdrawals`. Nine registrations fit in one transaction.

### 4.3 `UpdateAdapters` — §14.2.6

Spends `protocol_config` with the AdminNFT in an input and writes the adapter
whitelist. `ProtocolConfigRedeemer::UpdateAdapters` is constructor **1**:
`Constr(1, [protocol_in_idx, admin_in_idx, protocol_out_idx])`. An entry is never
removed, only added or re-permissioned, so a stale adapter hash left behind is
harmless.

### 4.4 `CreateMarket` — §20

Mints the `MarketNFT` (= `PoolNFT`) from a seed input under `market_param`'s own
policy and opens **two** UTxOs with it: the market at `Script(config_pool_skh)`
carrying the parameters, and the pool at `Script(pool_skh)` carrying
`PoolDatum` at its opening state — every field zero except
`interest_index = 1_000_000_000_000` and `interest_time = tx_start`.
`MarketParamRedeemer::CreateMarket` is constructor **1**; `UpdateMarketParam`
keeps constructor 0 so §15 stays wire-compatible with the record it used to be.

`interest_time` must equal `tx_start` **exactly**, and `tx_start` is the value the
script sees — a POSIX time not on a slot boundary comes back rounded. Build the
window as `slotToUnixTime(unixTimeToSlot(t))`.

### 4.5 `TopupWithdraw` — §18, both directions

| | |
|---|---|
| purposes | `Spend` pool, `Withdraw` pool (equal redeemer), `Mint` dToken under `pool_skh` |
| inputs | pool, the lender's funding (and the dToken on a withdrawal) |
| reference inputs | `protocol_config`, market, `pool` script |
| outputs | pool |
| redeemer | `PoolRedeemer = Constr(0, [[Constr(2, [pool_in_idx, pool_out_idx, market_ref_idx, fee_out_idx])], protocol_config_ref_idx])` |

The dToken is named for the market — `(pool_skh, MarketNFT.asset_name)`. Its
quantity is `pool_changed_amount × circulating_dtoken / total_supply_before_tx`,
and `fee_out_idx` is `-1` because this market's `withdrawal_fee` is zero.
`|pool_changed_amount| >= min_tx_amount` bounds both directions, so 100 ADA is
the smallest move.

### 4.6 `CreateOrder` — §6

| | |
|---|---|
| purposes | `Mint` OrderNFT + OrderOwnerNFT under `order_skh`, `Withdraw` order |
| inputs | one seed UTxO — `OrderNFT.asset_name == blake2b_224(seed.output_reference)` |
| reference inputs | `protocol_config`, market, `order` script |
| outputs | the order at `Script(order_skh)` under the trader's stake credential, holding `min_ada + fee_reserve + margin`; the OrderOwnerNFT to the trader |
| redeemer | `OrderRedeemer = Constr(0, [[Constr(0, [seed_utxo_idx, order_out_idx, market_ref_idx])], protocol_config_ref_idx])` |

`OrderOwnerNFT.asset_name == OrderNFT.asset_name ++ "OWN"`.

`is_market` is written into the datum but **no longer gates anything**. §6.2.2.13
still forces `fee_reserve >= async_fill_cost` on an order that sets it, and
§9.2.10 still asks for the reserve when a limit order is turned into a market one —
but the asynchronous fill reads the reserve itself now (§4.7 below), so the flag
grants no access it would otherwise withhold. A client is free to post
`is_market = false` and fund the reserve anyway, which is what the two orders in
§3 do.

### 4.7 The asynchronous fill — §7.2 with §7.4

The heaviest transaction in the protocol: **ten script purposes**, 12 reference
inputs, ~66 kB of reference script.

**This route is funded, not flagged.** §7.4.9 used to require `is_market`; it now
requires nothing of the flag, and §7.4.10 alone decides — `fee_reserve >=
async_fill_cost` and an `execution_tip_idx` whose output holds exactly
`market.execution_tip`. Nothing of the trader's price is given up: §7.4.2's floor
is `max(health_floor, market_floor, limit_floor)` and `limit_floor` is
`ceil(sold × den / num)` of `open_limit_price`, so the limit still bounds the payout
the claim may accept. The order UTxO the fill writes carries the proof —
`is_market false`, `open_limit_price 4/1`, `short_amount 0`, `fee_reserve 0`.

| | |
|---|---|
| purposes | `Spend` order, `Spend` pool, `Mint` under `loan_skh`, `Mint` under `position_skh`, and `Withdraw` from **order, pool, loan, position, the adapter and the oracle** |
| inputs | order, pool, one seed UTxO |
| reference inputs | `protocol_config`, market, the **Minswap pool**, the five script references, and the oracle's four |
| outputs | 0 order, 1 position, 2 loan, 3 pool, 4 the venue order, 5 the execution tip |

Mints, all three names distinct:

| Policy | Name | Qty |
|---|---|---:|
| `loan_skh` | `MarketNFT.asset_name` — the `LoanNFT` | +1 |
| `loan_skh` | `blake2b_224(seed)` — the `LoanOwnerNFT` | +1 |
| `loan_skh` | that name ++ `"BND"` — the `BindingNFT` | +1 |
| `position_skh` | `blake2b_224(seed)` — the `PositionNFT` | +1 |
| `position_skh` | that name ++ `"OWN"` — the `PositionOwnerNFT` | +1 |

The `LoanNFT` is named for the **market**, so a batch of N fills mints N of it;
the other three are one each of N distinct names. The loan datum's `owner_nft` is
`(loan_skh, LoanOwnerNFT.asset_name)` — the loan script's policy, not the
position's — and that NFT lives in the **position** output.

Redeemers:

```
OrderRedeemer     Constr(0, [[Constr(1, [                      -- ExecuteOrderIndexer
                     [Constr(0, [order_in_idx, order_out_idx, position_out_idx,
                                 loan_out_idx, seed_utxo_idx, execution_tip_idx])],
                     market_ref_idx, pool_in_idx, pool_out_idx, adapter_skh])],
                   protocol_config_ref_idx])
LoanRedeemer      Constr(0, [[Constr(0, [                      -- OpenLoan
                     [Constr(0, [order_in_idx, loan_out_idx, position_out_idx, seed_utxo_idx])],
                     market_ref_idx, pool_in_idx, pool_out_idx, adapter_skh])],
                   protocol_config_ref_idx])
PositionRedeemer  Constr(0, [[Constr(0, [seed_utxo_idx, position_out_idx])],  -- CreatePosition
                   protocol_config_ref_idx])
PoolRedeemer      Constr(0, [[Constr(0, [pool_in_idx, pool_out_idx, market_ref_idx,
                     [LoanOwnerNFT.asset_name]])],             -- PoolFlow
                   protocol_config_ref_idx])
AdapterRedeemer   Constr(0, [[Constr(0, [loan_owner_nft_name, route])],
                   protocol_config_ref_idx, market_ref_idx])
  route Pending = Constr(1, [asset, floor, market_floor, binding_nft, expiry,
                             slippage_src_idx, venue_ref_idx, venue_out_idx,
                             stake_credential])
```

The arithmetic, all of it integer and all of it recomputed by the validator:

```
margin              = order_in[lovelace] - fee_reserve - min_ada
tbv                 = short_amount - margin
loan_amount         <= tbv,  >= min_tx_amount
net_loan_proceeds   = loan_amount - max(ceil(rate*loan_amount/10000), min_amount)
short_from_order_in = ceil(margin * loan_amount / tbv)
sold                = short_from_order_in + net_loan_proceeds
achievable          = reserve_out * (sold*(10000-fee)/10000) / (reserve_in + that)
market_floor        = achievable * (10000 - order.max_slippage) / 10000
limit_floor         = ceil(sold * limit.den / limit.num)
debt_at_expiry      = debt + ceil(debt*apy*(expiry-interest_time)/(10000*year_ms))
health_floor        = ceil(ceil(10000*debt_at_expiry*(10000+margin_bp)/(T*10000)) * p.den / p.num)
floor               = max(health_floor, market_floor, limit_floor)   -- and <= achievable*(10000-50)/10000
```

`sold` includes the **margin**, not only the proceeds: with the proceeds alone the
trader's margin lands in the filler's change.

The venue order, §7.5, is a Minswap V2 order datum of nine fields:

```
Constr(0, [ canceller           = Constr(1, [cancel_skh])       -- a script
          , refund_receiver     = Address(Script(loan_skh), trader's stake)
          , refund_datum        = Constr(0, [])                  -- NoDatum
          , success_receiver    = the same address
          , success_datum       = Constr(0, [])
          , lp_asset            = Constr(0, [authen_policy, pool's LP name])
          , step                = Constr(0, [ a_to_b_direction    -- Bool
                                            , Constr(0, [sold])   -- SpecificAmount
                                            , minimum_receive     -- == floor
                                            , Constr(1, []) ])    -- killable
          , max_batcher_fee     = <= budget - max_cancel_fee - min_ada - rollback_tip
          , expiry_setting_opt  = Constr(0, [[expiry, max_cancel_fee]]) ])
```

Its value is `venue_fee_budget + sold` in lovelace when the sold leg is ADA, plus
the `BindingNFT` and nothing else. Three details were decoded from live UTxOs
rather than taken from the venue's documentation:

- the pool writes `asset_a`/`asset_b` as **records**, `Constr(0, [policy, name])`;
- the pool holds **two** assets of the authen policy — its identity NFT, named
  `"MSP"` on every pool alike, and its own LP token, which is what an order names;
- `swap_amount` is wrapped in `SwapAmountOption`, `Constr(0, [amount])` — 311 of
  400 live orders carry that shape, and it is what the monorepo's own
  `MinswapV2SwapComposer` writes.

### 4.8 The venue settles — §7.5

Nothing to build: a Minswap batcher executes the order and pays the proceeds to
`Script(loan_skh)` under the trader's stake credential, **datum-free**, carrying
the `BindingNFT`. On the runs recorded here that took about a minute.

### 4.9 `SettleClaim` — §8

| | |
|---|---|
| purposes | `Spend` loan, `Spend` the payout, `Withdraw` loan, `Withdraw` the adapter, `Mint` −1 `BindingNFT` |
| inputs | loan, payout, funding |
| reference inputs | `protocol_config`, `loan`, the adapter |
| outputs | 0 the loan with the collateral inside, 1 the tip — **exactly** `min_ada` |
| redeemer | `Constr(0, [[Constr(1, [[Constr(0, [loan_in_idx, loan_out_idx, payout_in_idx, tip_out_idx])], -1, adapter_skh])], protocol_config_ref_idx])` |

Permissionless: the payout UTxO's own minADA is the tip that pays for it. The
declaration is `Delivered { asset, amount = net(payout, asset), Some(binding) }`
and the adapter's `market_ref_idx` is `-1` on that route. `floor` is read from
the loan's own claim, never from the declaration. No oracle is involved.

### 4.10 `ModifyOrder`, cancel arm — §9.3

`order_out_idx == -1` is the cancel. Authorisation **is** the burn: the arm
requires `mint[order_skh] == { OrderNFT: -1, OrderOwnerNFT: -1 }` and the owner
NFT sits in the trader's wallet. `order_owner_in_idx`, `owner_release_out_idx`
and `market_ref_idx` are all `-1`. Whatever else the order held — after a fill,
the `PositionOwnerNFT` — is released.

### 4.11 `RepayLoan` on a synchronous venue — §10.1

| | |
|---|---|
| purposes | `Spend` loan, `Spend` position, `Spend` pool, `Withdraw` **loan_repay**, `Withdraw` position, `Withdraw` pool, `Mint` −1 `LoanNFT` −1 `LoanOwnerNFT`, `Mint` −1 `PositionNFT` −1 `PositionOwnerNFT` |
| inputs | loan, position, the `PositionOwnerNFT`, pool, funding |
| reference inputs | `protocol_config`, market, `loan`, `loan_repay`, `position`, `pool` |
| outputs | 0 the trader, 1 the pool |
| redeemers | `LoanRedeemer` action `Constr(2, [[SingleRepayLoanIndexer], market_ref_idx, pool_ref_idx = -1, pool_in_idx, pool_out_idx, adapter_skh = ""])`, `PositionRedeemer` action `Constr(3, [[Constr(0, [position_in_idx, position_owner_in_idx, loan_in_idx, -1, -1])]])` |

`SingleRepayLoanIndexer` is
`[position_in_idx, position_owner_in_idx, loan_in_idx, loan_out_idx,
position_out_idx, payout_in_idx, trader_out_idx, remain_out_idx, tip_out_idx]`,
and the arm is selected by those indices alone: a `payout_in_idx` means §10.2.2, a
surviving `loan_out_idx` means §10.2.1, neither means §10.1.

`adapter_skh` is the **empty** byte string, which is what tells the arm no venue
is involved, and no adapter withdrawal may be present. The collateral must leave
the protocol — no output at any of the five protocol scripts may hold it — so
with the trader's own wallet as the venue this is a plain repay: pay `debt_now`
into the pool, take the collateral.

### 4.12 The synchronous fill — §7.3

The fill of §4.7 with `adapter_sync_generic` in place of the venue adapter: no
oracle, no venue reference input, no `BindingNFT`, `execution_tip_idx = -1` and
`fee_reserve` unchanged. The route is
`Delivered { asset = long_token, amount, binding_nft = None }` and the filler
delivers `amount` of the collateral into the loan output out of their own pocket,
taking the margin and the proceeds. `amount >= long_from_order_in + limit_floor`.

### 4.13 `Liquidate` — §11

| | |
|---|---|
| purposes | `Spend` loan, `Spend` position, `Spend` pool, `Withdraw` **loan_close**, `Withdraw` position, `Withdraw` pool, `Withdraw` the oracle, `Mint` −1 `LoanNFT` −1 `LoanOwnerNFT` +1 `RemainNFT`, `Mint` −1 `PositionNFT` |
| outputs | 0 the liquidator, 1 the remain UTxO, 2 the pool |
| redeemer | action `Constr(3, [loan_in_idx, position_in_idx, payout_in_idx = -1, pool_in_idx, pool_out_idx, liquidator_out_idx, remain_out_idx, tip_out_idx = -1, market_ref_idx, reward])` |

Permissionless, and the position side presents **no** owner NFT — so
`SingleClosePositionIndexer.position_owner_in_idx` is `-1` and only the
`PositionNFT` burns, keeping the `PositionOwnerNFT` alive for §13.

```
cap          = collateral_amount * liquidator_reward_cap / 10000
reward_floor = min(ceil(min_liquidator_reward * p.den / p.num), cap)
seized       = min(ceil(debt * p.den / p.num), collateral_amount - reward)
taken        = seized + reward          -- to the liquidator, exactly
repaid       = seized * p.num / p.den   -- to the pool
shortfall    = max(0, debt - repaid)    -- booked as bad_debt in the pool datum
```

`reward` is **declared** in the redeemer, not inferred, and is bounded on both
sides. Where the collateral did not cover the debt, `reward` must equal
`reward_floor` — a maximal reward may not manufacture a shortfall.

The remain UTxO sits at `Script(loan_skh)` under the **position's** stake
credential, holds the `RemainNFT` (`PositionNFT.asset_name ++ "RMN"`) and
`min_ada + collector_reward`, and its datum is
`RemainDatum { owner_nft = (position_skh, PositionNFT.asset_name ++ "OWN"),
beneficiary, collector_reward }`.

A loan is only liquidatable when the oracle disagrees with the trader's own limit
price: at `open_limit_price` 6/1 against an oracle rate of ≈3.28 ADA per fUSDM,
the least collateral §7.3.2 admits opens the loan already under water. That is how
the transaction recorded here was arranged.

### 4.14 `CollectRemain` — §13.3

| | |
|---|---|
| purposes | `Spend` the remain UTxO, `Withdraw` **loan_close**, `Mint` −1 `RemainNFT` |
| reference inputs | `protocol_config`, `loan_close`, `loan` |
| outputs | 0 the beneficiary, 1 the collector — **exactly** `collector_reward` lovelace and nothing else |
| redeemer | action `Constr(5, [[Constr(0, [remain_in_idx, beneficiary_out_idx])], collector_out_idx])` |

Permissionless and signature-free: the beneficiary is fixed by the remain datum,
and `owner_nft` is re-derived from the `RemainNFT`'s own name.

### 4.15 `WithdrawFee` — §19

| | |
|---|---|
| purposes | `Spend` pool, `Withdraw` pool |
| inputs | pool, the AdminNFT, funding |
| outputs | 0 the pool, 1 the fee at `market.fee_address`, 2 the AdminNFT back |
| redeemer | action `Constr(3, [pool_in_idx, pool_out_idx, admin_in_idx, market_ref_idx, fee_out_idx])` |

Bounded by `undistributed_fee + accrued_fee`; what is left behind stays fee. The
fee output may hold only lovelace and the supply token.

### 4.16 `ModifyPosition` — §16

| | |
|---|---|
| purposes | `Spend` position, `Withdraw` position |
| inputs | position, the `PositionOwnerNFT`, funding |
| outputs | 0 the position |
| redeemer | action `Constr(2, [position_in_idx, position_owner_in_idx, position_out_idx])` |

Only `take_profit_price`, `stop_loss_price` and `min_execution_amount` may move,
and the last only upward. Both standing instructions are checked for
`numerator >= 0` and `denominator > 0`; `0/1` writes the instruction off. The value is byte-identical, which is what keeps the `LoanOwnerNFT`
pairing intact, and no input may sit at `loan_skh` or `pool_skh`.

### 4.17 `UpdateMarketParam` — §15

A **`Spend`** of the market UTxO, not a withdrawal: `§5 rule 16` is satisfied by
`market_in_idx` naming the input being spent. `MarketParamRedeemer` constructor 0,
`Constr(0, [market_in_idx, admin_in_idx, market_out_idx, protocol_config_ref_idx])`.
The AdminNFT authorises, the value is carried across untouched, the mint must be
empty, and every new number has to clear §1.3's bounds.

### 4.18 The sell claim — §10.2.1

The mirror image of §4.7: the collateral goes to the venue and the loan keeps a
`Closing` claim against the proceeds.

| | |
|---|---|
| purposes | `Spend` loan, `Spend` position, `Withdraw` **loan_repay**, `Withdraw` position, `Withdraw` the adapter, `Withdraw` the oracle, `Mint` +1 `BindingNFT` |
| inputs | loan, position, the `PositionOwnerNFT` **unless this is a take-profit**, funding |
| reference inputs | `protocol_config`, market, **the pool**, the Minswap pool, `loan`, `loan_repay`, `position`, the adapter, the oracle's four |
| outputs | 0 the loan with its claim, 1 the position byte-identical, 2 the venue order |
| redeemer | `LoanRedeemer` action `Constr(2, [[indexer], market_ref_idx, pool_ref_idx, -1, -1, adapter_skh])` with `loan_out_idx` and `position_out_idx` set |

The pool is a **reference** input on this arm — it moves no value, and the floor
needs only its index. The loan must be **healthy** here, which is the opposite of
§11's gate.

§5 rule 6's freshness bound is **not** applied to that reference read, and this
is the one arm it would have applied to. Because the pool is referenced rather
than spent, nothing here can advance its index — so the bound turned a pool
nobody had spent for an hour into a position nobody could close, which is exactly
when a trader wants out. What it bought was a ceiling on how understated
`debt_at(expiry)` can be, and the claim's own `floor` still has to clear
`health_floor` at that debt: a stale index lowers that floor, it does not remove
it. `max_index_staleness` stays in `MarketDatum` with its §1.3 bounds, unread —
§15 could only ever lower it and §1.3 caps it at an hour, so raising it was never
a way out. Removing the read moved `loan_repay` 13 050 → 12 914 bytes compiled.

```
sold         = net(loan_in_value, long_token)     -- the whole collateral
achievable   = venue curve on (reserve_of_long, reserve_of_supply)
market_floor = achievable * (10000 - position.max_slippage) / 10000
floor        = max(ceil(debt_at_expiry * (10000 + claim_safety_margin) / 10000), market_floor)
```

and `floor > venue_fee_budget`, because on this route the paid leg is the supply
token: that is what lets §12 tell a return from a fill. The claim written is
`Claim { direction: Closing, asset: short_token, sold, floor, expiry }`, and the
venue order sells the other leg — `a_to_b_direction` flips accordingly.

### 4.19 Repay on fill — §10.2.2

| | |
|---|---|
| purposes | `Spend` loan, `Spend` the payout, `Spend` position, `Spend` pool, `Withdraw` **loan_repay**, `Withdraw` position, `Withdraw` pool, `Withdraw` the adapter, `Mint` −1 `LoanNFT` −1 `LoanOwnerNFT` −1 `BindingNFT` +1 `RemainNFT`, `Mint` −1 `PositionNFT` |
| outputs | 0 the remain UTxO, 1 the pool, 2 the tip — **exactly** `min_ada` |
| redeemer | the same action with `payout_in_idx`, `remain_out_idx` and `tip_out_idx` set and `loan_out_idx = position_out_idx = -1` |

```
q           = net(payout_in_value, short_token)   -- >= claim.floor
debt_repaid = min(debt_now, q)                    -- the cap keeps a late fill repayable
residual    = q - debt_repaid                     -- parked in the remain UTxO
shortfall   = max(0, debt_now - debt_repaid)      -- booked as bad_debt
```

The declaration is `Delivered { asset = short_token, amount = q, Some(binding) }`.

This arm is now permissionless in the implementation as well as in the spec. It
used to read `position_owner_in_idx` in the prelude §10's routes share, so the
ticket had to be in an input here too even though the position side had always
passed `-1`. Both sides now agree, and a take-profit no one signed can be settled
by the same stranger who placed it. Nothing is at risk in doing so: `q >= floor`
is checked here, and the remain UTxO is addressed to the position's
`beneficiary`, so a settler cannot divert the proceeds — only earn the tip.

### 4.20 Closed by a standing instruction — §10.2.1 with no owner input

**The one to copy:** [`0f4d7ef193509eeb…`](https://preprod.cardanoscan.io/transaction/0f4d7ef193509eeb0f0bdabfdf120e7106674124cd306983c4b7899e1f080e09),
which the **stop-loss** authorised: no input carries a `PositionOwnerNFT`, the
take-profit was not reached, and the redeemer names no owner index. The position
it closed was given both instructions by
[`da03548386e1ff37…`](https://preprod.cardanoscan.io/transaction/da03548386e1ff3774296ffc87cd60cc50d59d557bcaeba350b8f9edb81005a7).
The take-profit side of the same gate ran on the registry before this one.

The same transaction as §4.18, built by someone who does not hold the ticket. The
difference is one index and one gate:

| | |
|---|---|
| redeemer | `position_owner_in_idx = -1` — §5 rule 11a's absent index |
| inputs | loan, position, funding. **No `PositionOwnerNFT`** |
| gate | one of the two standing instructions is set and reached: `take_profit_price.numerator > 0` with the oracle's rate for the long leg at or above it, or `stop_loss_price.numerator > 0` with the rate at or below it |

Everything else — the floor, the venue order, the claim, the health gate — is
byte-for-byte the arm above, which is the point: what the venue sees cannot tell
the two apart, so a take-profit needs no separate settlement path.

```
price = oracle rate for long_token, quoted in short_token per unit
take-profit fires when  price.num * tp.den >= tp.num * price.den
stop-loss   fires when  price.num * sl.den <= sl.num * price.den
```

The two face opposite directions and both are inclusive at the stated price. A
stop-loss is an exit **above** the liquidation threshold: §4.1's floor still has
to clear `health_floor` at `debt_at_expiry`, so it never substitutes for §11.

Cross-multiplied rather than divided, because a division would round where the
validator does not. **`take_profit_price` is quoted the way the oracle quotes —
supply token per unit of the long leg — which is the opposite orientation to
`open_limit_price`**, whose §7.4.2 use is `sold * denominator / numerator` and so
states long per short. An opening bound on what is paid, against a closing bound
on what is received. `numerator == 0` is the sentinel §6.2.2 leaves room for, and it reads the same on
both sides: no price is at or below zero either, so `0/1` is a position with that
instruction unset.

The take-profit side was exercised in all three states against a live oracle rate
of `523221885148/159562448003` — about 3.279 ADA per fUSDM:

| `take_profit_price` | | Result |
|---|---|---|
| `0/1` | no standing instruction | rejected, `Withdraw[1]` |
| `1046443770296/159562448003` | twice the rate | rejected, `Withdraw[1]` |
| `523221885148/319124896006` | half the rate | **accepted** |

Both rejections come from the `loan_repay` withdrawal, which is where the gate
lives; nothing else about the transaction changed between them.

The stop-loss side was isolated the same way, at an oracle rate of
`3105273981850/5452582673` — about 569.5 fUSDM per fBTC — with the take-profit set
where no price reaches it, so only the stop-loss could admit the close:

| `take_profit_price` | `stop_loss_price` | Result |
|---|---|---|
| `1000000/1` — not reached | `999999/1` — reached | **accepted** |

One trap for whoever automates this, and [`2b976d32ba9184c4…`](https://preprod.cardanoscan.io/transaction/2b976d32ba9184c4a211787ef916222a19db90dd505f191555ded3c1aabcf40c)
on an earlier registry is what it looks like. `--cancel-order` releases the
`PositionOwnerNFT` into the wallet's token bag, and the leanest UTxO is that bag,
so a take-profit funded from it **carries the ticket in an input the redeemer
never names**. The transaction is valid and the validator never reads it — but on
chain it is indistinguishable at a glance from a close the trader signed. Fund a
take-profit from a token-free UTxO if the point is to demonstrate that no
signature was needed.

---

### 4.21 The claim that never filled — §4.3 with §12.3

A fill sent to the venue with no batcher fee is one no batcher will execute. The
claim then reaches its expiry untouched, and the two arms that unwind it run in
order: §4.3 takes the order back off the venue, §12.3 unwinds the loan around it.

| | |
|---|---|
| §4.3 purposes | `Spend` the venue order under the venue's own `CancelOrderByOwner`, `Withdraw` **cancel** |
| §4.3 outputs | one UTxO at the `loan` script, **datum-free**, carrying the `BindingNFT` and everything the venue gave back |
| §12.3 purposes | `Spend` loan, `Spend` the returned UTxO, `Spend` position, `Spend` pool, `Withdraw` loan_close, `Withdraw` position, `Withdraw` pool, `Withdraw` the adapter, `Mint` −1 `LoanNFT` −1 `LoanOwnerNFT` −1 `BindingNFT` +1 `RemainNFT`, `Mint` −1 `PositionNFT` |
| §12.3 outputs | 0 the remain UTxO, 1 the pool, 2 the tip — **exactly** `rollback_tip` |
| §12.3 redeemer | loan action 4 with `order_in_idx = -1`, which §12.3.9 answers by requiring no order UTxO among the inputs at all |

The `cancel` withdrawal gates *when* and *which*: `tx_start > claim.expiry`, and the
`BindingNFT`s leaving venue orders must be exactly those the redeemer names. It
says nothing about **value** — that is §12.2's job, and §12.2.2 states it as
`recovered > 0` measured in the leg the claim was selling. The two together are
why trap 21 matters: a §4.3 that hands back less than the venue held is accepted
on its own and leaves §12.3 unbuildable for ever after.

```
recovered   = net(refund_in_value, sold_leg)
debt_repaid = min(debt_now, recovered)
shortfall   = max(0, debt_now - debt_repaid)   -- booked as bad_debt
remain      = recovered - debt_repaid          -- plus both freed minADAs
```

§12.2.6's lovelace equation is written against `refund_asset`: the pool's
repayment comes out of the returned lovelace only where the sold leg is ADA. On
a market that lends a token the repayment is in that token and the lovelace
equation drops the term — `opening_lovelace` in `lib/loan/rollback.ak` is the
one place the difference is spelled out.

---

### 4.22 `OpenDirect` — §7.6, a loan with no order

Every other opening arm starts from an order, because the venue is buying the
collateral and the order is where the borrower states the price and the slippage
the fill has to honour. A borrower who already holds the collateral is buying
nothing, and none of those terms says anything about the loan that results. So
this arm names no order, no venue, no adapter and no claim.

What it keeps is what protects the pool, and nothing else:

| Clause | What it requires |
|---|---|
| §7.6.1 | no adapter withdrawal appears in the transaction |
| §7.6.2 | the collateral is the position output's own `long_token` |
| §7.6.3 | `owner_nft`, `token == supply_token`, `claim == None`, `initial_interest_index == pool_out.interest_index`, `loan_amount >= min_tx_amount` |
| §7.6.4 | the loan holds collateral and **no** supply token — what is borrowed leaves |
| §7.6.5 | §3's health gate at the oracle's price, on the whole of the holding |
| §7.6.6 | the pool lends `loan_amount` and keeps the origination fee |

The `LoanNFT` carries the **market's** own NFT name, which is what tells the
validator which market this is when no order does: `loan_market_name_of` reads it
off the loan output, and `market_at` then closes the loop against the market's own
NFT in the reference input. The `LoanOwnerNFT` and the `PositionNFT` share the
seed UTxO's hash, exactly as a fill's do — which is what lets §10, §11 and §12
read this loan through the same pairing as any other.

Shape:

- **inputs** — the pool, plus the borrower's collateral UTxO and the seed
- **mint** — `loan_skh`: `{ MarketNFT name: 1, seed name: 1 }`; `position_skh`:
  `{ seed name: 1, seed name + "OWN": 1 }`
- **withdrawals, all zero** — `pool`, `loan` (the `OpenDirect` redeemer, §5 rule
  18's `loan` host), `position` (`CreatePosition`), and the oracle
- **outputs** — `[0]` the position, `[1]` the loan holding the collateral, `[2]`
  the pool. The `PositionOwnerNFT` and the loan proceeds leave in the change: with
  no order to park the ticket on, the borrower holds it from the start

### 4.23 `OpenDirect` with a claim — §7.6.7, three transactions and no order

The same arm, the same redeemer, the same indexer. What changes is that the loan
it writes carries a claim, so the venue order goes out in the very transaction
that opens the loan and the borrower never posts an order UTxO:

| | |
|---|---|
| purposes | `Spend` pool, `Withdraw` **loan**, `Withdraw` position, `Withdraw` pool, `Withdraw` the adapter, `Withdraw` the oracle, `Mint` +1 `LoanNFT` +1 `LoanOwnerNFT` +1 `BindingNFT`, `Mint` +1 `PositionNFT` +1 `PositionOwnerNFT` |
| outputs | 0 the position, 1 the loan, 2 the pool, 3 the venue order |
| redeemer | loan action 6, unchanged — the adapter is read from the claim the loan writes, not named in the redeemer |

```
sold  = margin + net_loan_proceeds     -- the borrower's own money rides with the loan's
floor = max( health_floor(debt_at(expiry)), market_floor )
```

Two things make this route different from §7.2, and both come from there being no
order to read:

- **`sold` is bounded, not derived.** §7.2 computes it as `margin + proceeds` from
  the order's own value, so what the pool lends provably reaches the venue. Here
  the margin is an ordinary wallet input, so §7.6.7.3 states the bound directly:
  `sold >= net_loan_proceeds`. Without it a borrower draws the loan, sends a token
  of it to be swapped, keeps the rest and leaves §12 to book the difference.
- **No limit price.** §4.1's third term needs `open_limit_price`, an order field.
  This route is market-only and the floor is a max over two terms. A limit order
  still goes through §6 and §7.2.

The adapter had to move for this, and it is the one change outside `open_direct`.
`max_slippage` is a field of the order on a fill and of the position on an
asynchronous close — both **inputs**. Here the position is an *output*, so
`slippage_src_idx` now reads an output when it is negative: `-1` names
`outputs[0]`. The output is still checked to sit at `position_skh`, and §7.6.2
reads the same one for `long_token`, so the value is the borrower's own either
way. `adapter_minswap` moved 8 351 → 8 381 bytes compiled; it is whitelisted
through §14.2.6 rather than named in the registry, so this needed
`--publish-changed`, `--update-adapters` and `--register-stake` — not a genesis.

The three transactions, in order. Only the first ran on this registry; the other
two are from an earlier release, since no venue order posted here was filled:

| | | Transaction |
|---|---|---|
| the borrower opens and places the swap | one transaction | [`d48f90fd228f…`](https://preprod.cardanoscan.io/transaction/d48f90fd228f70484336a1c11353bf80e8cbdbab480163f9a99171bdf90db64f) |
| the venue's own batcher fills it | 220 737 fBTC against a floor of 214 114 | `0d45b8c549d0…#0` |
| §8 settles the payout into the loan | permissionless | [`46ec9b2cd8bb…`](https://preprod.cardanoscan.io/transaction/46ec9b2cd8bb248decc80f246947a4a41ffac8050838a04e4bbccdd47688bb5f) |

---

## 5. The price, and the arms that wait on it

Every arm that reads a price was rejected before it was accepted. All four causes
were in this repository, and three of them are invisible from the error the node
returns.

The oracle recomputes the rate from the reference input the redeemer cites and
checks it with `expect price == price_in_rdmr` — a structural equality on
`PRational`, the two integers rather than the value they denote. Three of the
four causes are that equality being read as though it compared values:

1. `releases/src/oracle.ts` scaled the aggregator's rate into units on both
   sides. Right arithmetic, wrong pair of integers; it divides the numerator
   back down instead.
2. The aggregator's number holds only while its cache and the pool agree, and a
   pool moves whenever anyone trades against it — this deployment's own batcher
   included. The rate is now read from `reserve_a`/`reserve_b` of the very UTxO
   the redeemer cites, which cannot disagree with what the validator computes
   from the same bytes.
3. The validator composes a price path from `PRational(1, 1)` and reduces by
   `math.gcd` at every node, so a single-node path yields the rate **in lowest
   terms**. A raw reserve pair therefore passes only while the two reserves are
   coprime — which they were, for a couple of hours, and then were not. The
   rate is reduced before it is sent.

The fourth had nothing to do with the price. The Minswap pool an asynchronous
fill trades against **is** the pool the oracle reads the rate from, so the
reference list named one UTxO twice. The ledger dedupes; the list the indices
were taken over did not, and every index past the repeat was one too high.

With all four fixed, every price-reading arm builds and submits. The ones this
registry ran are in §3 — §7.2, §7.6, §7.6.7, §10.2.1 with and without the owner
ticket, §11, §13.3 and §16 among them. What a price cannot supply is a
counterparty: §7.5, §8 and §10.2.2 each need a venue order to have filled, and on
preprod none did.

### §10.2.2 on a market that lends a token

Only a token-supply market can hit this, and §10.2.1 is what exposes it.
§10.2.2.6 requires the remain UTxO to carry over every asset the payout held, and
`carries_over` skips lovelace — so on a market that lends ADA the venue's proceeds
were never in its domain, and `net(remain, short_token) >= q - debt_repaid`
governed them alone. Where the supply token is a token they fall under both at
once and the two disagree by exactly `debt_repaid`: the remain was required to
hold the whole payout while the pool was required to be paid out of it. §10.2.2
could not be built on such a market at all. The sold leg is excluded from the
payout's carry-over, so the market that lends fUSDM closes through §10.2.1 and
§10.2.2 like any other.

## 6. What an implementer has to get right

Each of these cost a rejected transaction here.

1. **Integer division floors.** Plutus `divideInteger` rounds **down**; a JS
   `BigInt` `/` and a Go `int64` `/` round toward zero. They agree on
   non-negative operands and differ by one everywhere else — §18's `dtoken_qty`
   is negative on every withdrawal, and one lovelace of drift makes the pool
   datum the validator recomputes reject the one you wrote.
2. **Aiken 2-tuples are CBOR lists**, not constructors. `TupleAsset` is
   `[policy, name]`; `Option<(Int, Int)>` is `Constr(0, [[a, b]])`. Records and
   sum types are `Constr`. Getting this wrong makes a datum no validator can
   decode, and nothing catches it before submission.
3. **Duplicate inputs are fatal.** If the UTxO holding an owner NFT is also the
   one you pick to pay the fee, the builder emits an inputs *set* whose declared
   length counts the duplicate — the node answers "Final number of elements: 3
   does not match the total count that was decoded: 4" and nothing else.
   De-duplicate by out-ref before building.
4. **A withdrawal needs its stake credential registered.** Ogmios error 3141
   `incompleteWithdrawals`, and it only appears at submission — a zero withdrawal
   *builds* happily without it.
5. **Cite the `loan` reference script whenever a loan UTxO is spent**, beside the
   host that carries the arm. Three hosts, and the spend purpose belongs to none
   of them.
6. **Reference scripts are priced per byte**, tiered, on top of the ordinary fee —
   including scripts carried by inputs you merely spend. Builders' estimates omit
   this; set a floor. Sixty-six kilobytes of reference script costs about
   1.7 ADA on top.
7. **Collateral is a percentage of the fee** (150% on preprod). A ten-script
   transaction pays about 3.7 ADA, so the 5 ADA a builder defaults to is short.
8. **`tx_start` is what the script sees.** Round the validity window to slot
   boundaries before you compute anything that compares against it — §20's
   `interest_time == tx_start` is an equality.
9. **Mirror an external protocol's datum from a live UTxO.** Three of the Minswap
   mirrors here were wrong when taken from the type names alone, and each
   produced a transaction that built and then matched nothing on chain.
10. **The value size limit is 5 000 bytes** per output — about a hundred and ten
    assets. A test wallet's token bag exceeds it and cannot be swept into one
    output.

11. **A filled order UTxO does not retire itself.** Once `short_amount` reaches
    zero the order UTxO stays where it is, holding its `OrderNFT`, the
    `PositionOwnerNFT` the fill minted for the trader, and whatever is left of
    `fee_reserve` — 33 ADA on a synchronous fill, which never touches the reserve.
    Nothing in the closing arms reaches into it: a position here was liquidated,
    and another rolled back, while its owner ticket was still sitting in the order
    UTxO. Run §9.3's cancel arm to retire it; that burns the `OrderNFT` and the
    `OrderOwnerNFT`, releases the ticket, and returns the reserve.

12. **A change output's minADA is priced by the bag you spend, not by the amount
    you send.** Spending the UTxO that holds a token puts every *other* token in
    that UTxO into the change, and a twenty-asset change output wanted 2 ADA where
    the bag itself carried barely its own minimum. Three arms failed this way on a
    wallet holding 1 700 ADA — the ADA had drifted into the bag, and a bag is
    excluded from coin selection. Bring a token-free UTxO along.
13. **`min_tx_amount` gates §18 in both directions.** It reads as a floor on
    deposits, but withdrawals are held to it too. The pool validator crashes with
    nothing to say about which rule failed.

14. **A reference-script UTxO is indistinguishable from spendable ADA at a
    glance.** The eleven live at the deployer wallet, each holding about 55 ADA
    and no tokens, so any balance read that counts token-free UTxOs counts them.
    This wallet reported 7 489 ADA across 23 token-free UTxOs and two admin arms
    still failed with *no funding UTxO with at least 20 ADA*: the ADA was either
    locked under a script or sitting in the token bag trap 12 describes. Run
    `--tidy` before an admin arm rather than trusting a total.

15. **§3 and §7.2.23 are different ceilings, and on a demo pool the second
    binds.** 0.05 fBTC is worth 5 264 fUSDM at the oracle's rate, which §3 would
    lend half of; the pool held 10 000 fUSDM, and 2 632 was fine, while the 0.5
    fBTC first tried would have asked for 26 323 and been refused by the
    utilisation cap. Size a loan by the smaller of what the collateral admits and
    what the pool has room for — the health gate alone will happily overshoot.

16. **A venue pool can be one of the oracle's own price sources.** The Minswap
    pool an asynchronous fill trades against is exactly where the fBTC/fUSDM rate
    comes from, so a naive reference list holds that UTxO twice. The ledger
    dedupes it and the list the redeemer's indices were taken over did not, so
    every index past the repeat was one too high: `registry_at` read the wrong
    UTxO and the mint handler died with nothing to say. After the fix the indices
    fall by exactly one — `market_ref` 7 to 6, `proto_ref` 9 to 8 — which is how
    you know that was it. The same lesson applies to spent inputs and was already
    learned there; reference inputs need it too.

17. **A `LoanNFT` is named for the market, not the loan.** §7.2.12, and it means
    every open loan on one market holds a token of the same policy and name.
    Looking a loan up by that token finds as many as are open — three, here — or
    none once they are closed and burned. The `LoanOwnerNFT` in the datum is what
    is unique.

18. **A withdrawal that fails alone is not proof the fault is not yours.** This
    document said the opposite for a while, and `releases/oracle-alone.ts` is the
    probe that made the claim tempting: build a transaction carrying nothing but
    the oracle's reference inputs and its zero withdrawal, and if that fails,
    surely nothing of yours is implicated. It failed, the fault was ours, and the
    probe still fails today while §7.6, §11 and §7.4 all read the same price
    successfully. Whatever the isolated transaction gets wrong, it is not what
    the arms get wrong. Use the probe to *reproduce* a failure, never to place it.

19. **A declaration's `asset` is the market's supply asset, not ADA.** The
    adapter checks `net(payout_in.value, asset) == amount` on the very input the
    claim names, so a route hardcoded to `["", ""]` is right on a market that
    lends ADA and silently wrong on every other one — it compares the payout's
    minADA against a token amount. §10.2.1's `Recovered` and §10.2.2's
    `Delivered` both carry it.

20. **A record with one slot per arm cannot name two open loans.** A loan, a
    claim and an order each live on chain until something closes them, while a
    record that keeps the last entry of every arm names only one of each. Two
    outstanding claims and the second is addressable only by decoding its owner
    name off the chain by hand. Selecting with `A ?? B ?? C` over those slots
    compounds it: that takes the first entry which *exists*, not the first still
    *open*, so an arm's success depends on which command ran before it. Append to
    a list, and read each arm's target back through a predicate — is it open, does
    it carry a claim, is it bound to **this** claim. Matching on "has a claim" is
    not enough: a take-profit and an asynchronous close can both be outstanding,
    and it pairs one loan with the other's payout.

21. **Send the oracle's rate in lowest terms.** The price path is composed from
    `PRational(1, 1)` and reduced by `math.gcd` at every node, and the check is
    structural equality on the pair. A raw `(reserve_b, reserve_a)` is accepted
    only while the reserves are coprime, which is a property of the pool at that
    moment and not of your code.

22. **§4.3 must return the venue order's whole value, and §12.2.2 is why.**
    The `cancel` validator constrains which binding NFTs leave the venue and
    when — not what comes back, so a refund built as `{ lovelace, bindingNFT }`
    is accepted and the sold leg goes to the canceller's change. §12.2.2 then
    requires `recovered > 0` measured in that leg, and no other arm will spend a
    loan whose claim is cancelled: the loan, its margin and its position are
    stranded on chain with the debt still counted in `total_borrow`. Pay the
    venue order's value across verbatim.

23. **A datum that gains a field moves every positional index that reads it.**
    Off-chain code reads a datum by position, so inserting `stop_loss_price` at
    field 2 of `PositionDatum` shifted `min_execution_amount`, `max_slippage` and
    `beneficiary` down one. The two failure modes differ: reading `beneficiary`
    one slot early yields a value of the wrong **type** and the builder throws,
    while reading `max_slippage` one slot early yields another Int — 101 000 000
    where 300 was meant — and the transaction builds, then dies inside the
    adapter, which recomputes the market floor from it and disagrees. Grep every
    positional read of that datum across the whole builder when a field is added;
    a compiler that types the field as `any` will not.

---

## 7. Where it ended

Read back off chain after the last transaction:

| | |
|---|---|
| ADA pool | 405.000131 ADA · `total_supply` 700.006499, `total_borrow` 300.006368, `undistributed_fee` 0, `bad_debt` **0** |
| fUSDM pool | 5 ADA + 208,999,557.511655 fUSDM · `total_supply` 209,000,000.002996, `total_borrow` 450.003398, `undistributed_fee` 7.511841, `bad_debt` **0** |
| fBTC pool | 5 ADA + 1,607.69230789 fBTC · `total_supply` 1,607.69230789, `total_borrow` 0, `undistributed_fee` 0, `bad_debt` **0** |
| Loans | five open — two carrying no claim, one an `Opening` claim, two a `Closing` claim |
| Orders | two open |
| At the loan script besides the loans | three venue payouts the venue returned at expiry, each holding its `BindingNFT` and no datum |
| Reference scripts | all 11 reproduce from this source — `--verify` rebuilds each from `plutus.json` and matches the record |

Nine loans were opened — four through §7.3, two through §7.2, two through §7.6 and
one through §7.6.7 — and four were closed:

| Route | | Times |
|---|---|---:|
| Repaid, no venue | §10.1 | 1 |
| Repaid out of a venue fill | §10.2.2 | 0 |
| Liquidated | §11 | 1 |
| Rolled back after an unfilled claim | §12.3 | 2 |

`bad_debt` of **0** on all three pools is what says those four closures landed
whole, the two §12.3 included — each recovered leg covered its debt exactly.

Both §12 arms are in the contract: §12.3 unwinds an `Opening` claim and §12.4 a
`Closing` one. `releases/` implements only the first, so the two loans holding a
returned `Closing` claim have no command to unwind them yet.

---

## 8. The fee, and the two floors under it

`fee_reserve` is what a trader fronts to place a market order, so it is the
protocol's headline cost. It is **33 ADA** and this section takes it to
**19.5** — a 41% cut that changes no validator source, moves no script hash,
and needs one transaction per market.

**Not submitted.** §1 through §7 are the deployment that ran; this is the
parameter set to write next. What is proven here is that the numbers clear
§1.3, the ledger's own minima and `adapter_minswap`'s batcher term, and that
§15 admits the move from what is live — `lib/tests/market_params_test.ak`
checks each of those. Not that a 19.5 ADA order fills against Minswap.

### 8.1 What the 33 is made of

§6.2.2.13 requires the reserve to cover `async_fill_cost`, which
`order/utils.ak` defines as

```
async_fill_cost = venue_fee_budget + execution_tip + 2 x min_ada
                = 20 + 3 + 2 x 5 = 33 ADA
```

The two `min_ada` fund the loan and the position a fill creates. None of the
three terms was sized against anything: the budget and the tip were set
generously, and `min_ada` at 5 ADA is roughly twice what the ledger wants for
any UTxO this protocol writes.

### 8.2 The four floors, three of them the ledger's

None of these is visible in the validator source, and none of them is a §1.3
bound.

| Floor | Where | Value |
|---|---|---:|
| `lovelace_of(tip_out) == execution_tip`, an **equality**, so the tip output is its own minADA — a bare output with a stake credential is 85 bytes, `(160 + 85) x 4310` | `order/execute.ak:336` | **1.055950** |
| `lovelace_of(tip_out) == rollback_tip`, likewise | `loan/rollback.ak:122` | **1.055950** |
| `min_ada - collector_reward` is §11.2.7's grace tip, so that difference is a minADA too | `loan/liquidate.ak:252` | **1.055950** |
| `max_batcher_fee <= venue_fee_budget - max_cancel_fee - min_ada - rollback_tip`, and Minswap V2's batcher fee is fixed | `adapter/minswap.ak:409` | **2.000000** |

Substituting §1.3's `venue_fee_budget >= max_cancel_fee + min_ada +
rollback_tip` and the batcher term into `async_fill_cost` collapses the whole
thing to one inequality:

```
fee_reserve  >=  batcher_fee + max_cancel_fee + 3 x min_ada
                            + rollback_tip + execution_tip
```

`min_ada` is multiplied by **three** — once for the venue order and twice for
the loan and position — so every lovelace shaved off it returns three. That is
the whole of why the first floor below is so much higher than the second.

### 8.3 Two floors, and only one is reachable from here

```
min_ada = 5.0 (deployed)   >=  2.0 + 0 + 15.000000 + 1.055950 + 1.055950  =  19.111900
min_ada free               >=  2.0 + 0 + 3 x 2.331710 + 1.055950 + 1.055950  =  11.107030
```

The second figure takes `min_ada` down to 2.331710, which is what the ledger
wants for the heaviest UTxO carrying nothing but that floor: the loan output
holding a `Claim`, with its `LoanNFT` and the collateral token, 381 bytes.

**Ten ADA is under both.** Not by a parameter choice and not by a code change
either: 11.107 already assumes a zero cancel fee, both tips at the ledger's
minimum, and `min_ada` written at exactly the ledger's answer for the largest
UTxO in the protocol — where one field added to `LoanDatum` would make every
loan output unspendable.

### 8.4 What this section changes

The five charges, and nothing else:

| | Was | Now | Floor | Headroom |
|---|---:|---:|---:|---:|
| `venue_fee_budget` | 20.0 | **8.4** | 8.300000 | 0.100000 |
| `execution_tip` | 3.0 | **1.1** | 1.055950 | 0.044050 |
| `rollback_tip` | 3.0 | **1.1** | 1.055950 | 0.044050 |
| `max_cancel_fee` | 2.0 | **0.2** | 0 | — |
| `collector_reward` | 3.0 | **1.2** | — | 2.744050 under its cap |
| **`fee_reserve`** | **33.0** | **19.5** | 19.111900 | 0.388100 |

`min_ada` stays at 5.0. `min_liquidator_reward` stays at 10, where
`min_liquidator_reward x basis_point <= min_tx_amount x liquidator_reward_cap`
already holds with equality.

0.388100 ADA is all the slack left in the reserve. There is no further
parameter change to make.

### 8.5 Why it needs no genesis

All five are **datum** fields, and §1.3's monotone rules run one way:
`venue_fee_budget`, `execution_tip` and `max_cancel_fee` may only **fall**.
Every charge above therefore moves in the direction §15 already permits, and
`--update-market-param` applies them to the markets that are live right now —
one transaction each, spending the `AdminNFT`.

`min_ada` is the exception, and it is the reason 12.3 ADA is not on this list.
It is a compile-time constant in eighteen modules, so lowering it moves nine of
the eleven script hashes; `order_skh`, `loan_repay_skh` and `loan_close_skh` are
immutable registry fields, so no `protocol_config` transition can adopt the
moved hashes and the deployment would need a fresh genesis. The trade is 7.2 ADA
of reserve against re-proving all eighty-one transactions of §3 on a new
registry, and this section does not take it.

| | `min_ada` | `fee_reserve` | Hashes | Needs |
|---|---:|---:|---|---|
| Deployed today | 5.0 | 33.0 | — | — |
| **This section** | 5.0 | **19.5** | **all 11 unmoved** | one `--update-market-param` per market |
| Not taken | 2.6 | 12.3 | 9 of 11 move | fresh genesis, §3 re-run |

### 8.6 Two things to settle before submitting

1. **The tips are below the cost of earning them.** `execution_tip` becomes
   1.1 ADA and the transaction that earns it pays about 3.7 ADA in fees. That
   was already true at 3 ADA, so this widens an existing gap rather than opening
   one — but a tip that does not cover its own transaction will not attract a
   third-party executor, and the 1.055950 floor means the gap cannot be closed
   from below. Only raising the tip closes it, and §1.3 will not let it rise
   again on a market once lowered.
2. **`max_cancel_fee` at 0.2 ADA prices the cancel arm below its own
   transaction too.** §4.3's canceller is whoever notices an expired claim, and
   0.2 ADA is not a reason to notice. §12.2.2 is what makes this matter: a claim
   nobody cancels leaves the loan, its margin and its position stranded with the
   debt still counted in `total_borrow`.
