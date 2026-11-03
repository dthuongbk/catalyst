# Preprod deployment — leverage DEX adapter

Every transaction below was built and submitted on **preprod**, against the real
Minswap V2. Each hash is the evidence that the arm it names is buildable, and the
shapes recorded with it are the shapes the validators accepted.

Nine arms are absent, and §5 is the account of why — two of the three causes were
this repository's own and are fixed; the third is a change to the oracle's price
path dated to 02:29 UTC on 4 September, after which nothing that reads a price
builds. Every one of those nine ran on the registry immediately before this one,
against ten of these same eleven validators; §5 lists them with their hashes.

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
| ProtocolNFT | `bc2d3b7cf1009c788b1daf2208a38026ab20d7f8209d896ad1a09c14.70f48d8dedd769ada7c44fdb4774b6c1c07d748bdc042ee5b955636080fea212` |
| AdminNFT | `bc2d3b7cf1009c788b1daf2208a38026ab20d7f8209d896ad1a09c14.459e8ad7efb9369a7fffab114adf7d37f7a9e0a6864b7baeb0165901d4f2dffd` |
| `protocol_config` UTxO | at `addr_test1wqex8q3mzs62tk3dd79tjdpul4sunmunhtyk23yyn9z35as7099cg` |
| Genesis | [`7e97f3dd5014796c…`](https://preprod.cardanoscan.io/transaction/7e97f3dd5014796cb7f17bc334ac0f4f7e3acb2562e1e2644cf0b0a8a18424ce) |
| Reference scripts held at | `addr_test1qqv5l5k8zax8agy84qanqr44tr4padeescstfh9pexxktapdzjk7wvmnvwrgara7yay07vnhh78chyvla8yeuw5ltxysx2qgkv` |
| Oracle (`oracle_skh`) | `3158c9a7ba551eb3b6b9aa578e7995dec5ce34e272fde0bda76b46d1` |

### Scripts

| Validator | Script hash | Bytes |
|---|---|---:|
| `adapter_minswap` | `e25c70a0a4d1395315ed4066da4391511e17092617adb1b48ffc391b` | 8,558 |
| `adapter_sync_generic` | `3fbf5841a1f19dd7d525236712f7d75e406927d70b5e71e5ac9969b3` | 3,326 |
| `cancel` | `d2a000949ab15fa90dc12dc29d75c02b86778fecc444b0542c35b392` | 2,710 |
| `loan` | `6bc87e3e981ce88249be083fa3278b3a40f8ffafa43b2e1713e0dfe4` | 14,556 |
| `loan_close` | `e52dfbe9ecbe7a621fae8f6d0540df9086924d4b9a5650d89aab595b` | 14,261 |
| `loan_repay` | `01ab270ea1a08e4f4d9c0e3cea0976139f9f8b0a0e23552848e31d2a` | 13,123 |
| `market_param` | `1858b5e3a3722348e1334fa3226edc8ef179a17571b0ced4ff08ec9a` | 6,115 |
| `order` | `19ddca304a9f2216ddc23d3d03655cbc8e54deff8151eaa028fdea5d` | 13,214 |
| `pool` | `e20d719a11624989cba3ff7512924d565b2e6887c8b62f55e2da615c` | 12,566 |
| `position` | `30ecfbefeaebe3cbf0b7d95aa50899626f5aa7c6ea94d26b8025900b` | 6,947 |
| `protocol_config` | `3263823b1434a5da2d6f8ab9343cfd61c9ef93bac965448499451a76` | 4,029 |

### Markets

| Key | Lends | Collateral | MarketNFT |
|---|---|---|---|
| `market` | ADA | fUSDM | `3cf2d4ad7f6e90b0b200d083…` |
| `marketFusdm` | fUSDM | fBTC | `d244f30ddfb30e2bee8b85fb…` |
| `marketFbtc` | fBTC | fUSDM | `d41cb093d0cc0e9c21f4adb0…` |

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

Eighty-one transactions, every one of them on this registry. `sweep`, `tidy` and
`consolidate` are wallet hygiene rather than arms of the spec — they are listed
because they were submitted, not because they prove anything.

| # | Command | What it proves | Transaction |
|---:|---|---|---|
| 1 | `genesis` | §14 genesis — the registry | [`7e97f3dd5014796c…`](https://preprod.cardanoscan.io/transaction/7e97f3dd5014796cb7f17bc334ac0f4f7e3acb2562e1e2644cf0b0a8a18424ce) |
| 2 | `publish protocol_config` | §5 rule 4 — a reference script | [`2844229dbeb9feb8…`](https://preprod.cardanoscan.io/transaction/2844229dbeb9feb8f46402d1fcd5f165e48c4f7bb3d2a28b0ec765da85000952) |
| 3 | `publish market_param` | §5 rule 4 — a reference script | [`cf1b0a305acb82ab…`](https://preprod.cardanoscan.io/transaction/cf1b0a305acb82abca7c90a0f3d990f533a4398de50e65c4b8a345f9ffc5d6c4) |
| 4 | `publish pool` | §5 rule 4 — a reference script | [`7859839e0c98e6ed…`](https://preprod.cardanoscan.io/transaction/7859839e0c98e6ed734e8b650d630bef3fcc6632b9ecb873267ee6b86c1891aa) |
| 5 | `publish loan` | §5 rule 4 — a reference script | [`27c561c66579193b…`](https://preprod.cardanoscan.io/transaction/27c561c66579193b4be89dae4a70ca51caaa31f911355262b8d8ab5778501e19) |
| 6 | `publish loan_repay` | §5 rule 4 — a reference script | [`76b48c28d3944967…`](https://preprod.cardanoscan.io/transaction/76b48c28d3944967e7fecfd3295801940a7ac649d39a55c1b0ac6f61d04a2b72) |
| 7 | `publish loan_close` | §5 rule 4 — a reference script | [`593c9d93d05682f3…`](https://preprod.cardanoscan.io/transaction/593c9d93d05682f343e674a5b1afc3f0918b4bba8b209b4ab33a1a3645264637) |
| 8 | `publish order` | §5 rule 4 — a reference script | [`597566d0194c68ac…`](https://preprod.cardanoscan.io/transaction/597566d0194c68ac2c56b9b797e0adf1c08b13d410a4a1de0ba429d2405fbd61) |
| 9 | `publish position` | §5 rule 4 — a reference script | [`092b18ba1756617e…`](https://preprod.cardanoscan.io/transaction/092b18ba1756617e2a1418a8ef9d3e6d731749ec992139320378d7fb2915b9cb) |
| 10 | `publish cancel` | §5 rule 4 — a reference script | [`005988ce0c233dbe…`](https://preprod.cardanoscan.io/transaction/005988ce0c233dbedca622a30886583d98e7634585ac53ba19b9c438e8fc3071) |
| 11 | `publish adapter_sync_generic` | §5 rule 4 — a reference script | [`2fae09a684e5b299…`](https://preprod.cardanoscan.io/transaction/2fae09a684e5b299a9522b119cc0299f23045085ed242279d5a957dac72821dd) |
| 12 | `adapter_minswap` | §5 rule 4 — the venue adapter | [`5b919d8e735a0977…`](https://preprod.cardanoscan.io/transaction/5b919d8e735a097790bbf84564f349dce703d1001f148682b8de75bf0f73287e) |
| 13 | `register 9 account(s)` | stake registration | [`769d174f2e28eef9…`](https://preprod.cardanoscan.io/transaction/769d174f2e28eef9d1c75e459b062843ef34023a742dcaed842cc1e29aad9c3f) |
| 14 | `update-adapters` | §14.2.6 `UpdateAdapters` | [`f15c0b5ca41e2ce7…`](https://preprod.cardanoscan.io/transaction/f15c0b5ca41e2ce70142f4d91d0abfa42e4ed329ce0faede6d2d8cce79e90fa7) |
| 15 | `consolidate` | wallet hygiene | [`1eebf2fd472f3157…`](https://preprod.cardanoscan.io/transaction/1eebf2fd472f3157a3e75d184e37995574175540142f7a7985f197a270c2aa3c) |
| 16 | `create-market` | §20 `CreateMarket` | [`c0848a5a58b50f3f…`](https://preprod.cardanoscan.io/transaction/c0848a5a58b50f3f289c6154d90ea17f5247c8b443317bd546b01368127a42a9) |
| 17 | `supply` | §18 `TopupWithdraw`, deposit | [`209c6a1710247052…`](https://preprod.cardanoscan.io/transaction/209c6a1710247052a43bf911ba71a3ac8965893693f24424a616303feea3cfa5) |
| 18 | `create-market` | §20 `CreateMarket` | [`8203be9ba6b7a861…`](https://preprod.cardanoscan.io/transaction/8203be9ba6b7a861b281f6e2db7e7cd5fba28c518cf8dd6a552eecc83d5b2971) |
| 19 | `supply` | §18 `TopupWithdraw`, deposit | [`73d6291fa9e5a750…`](https://preprod.cardanoscan.io/transaction/73d6291fa9e5a750e3ad82b929c558db9fe6a560e1027bca2fcb30673219d4e4) |
| 20 | `create-market` | §20 `CreateMarket` | [`a8ea5df73a3ccaae…`](https://preprod.cardanoscan.io/transaction/a8ea5df73a3ccaae5120bf1ac8fc9a6fe7a3d6b7a22ec24705def2f4a1ebada5) |
| 21 | `supply` | §18 `TopupWithdraw`, deposit | [`ffd97eef07160622…`](https://preprod.cardanoscan.io/transaction/ffd97eef071606227274d11f89d1405146c88826cc678c7417a22471c8bda7f5) |
| 22 | `update-adapters` | §14.2.6 `UpdateAdapters` | [`774ee74a27a830d3…`](https://preprod.cardanoscan.io/transaction/774ee74a27a830d399c6e11141116a261e4d33545bb09f3b130efe11ec7b46af) |
| 23 | `adapter_minswap` | §5 rule 4 — the venue adapter | [`db68dcc78cfce730…`](https://preprod.cardanoscan.io/transaction/db68dcc78cfce730f0a3be8a3713d6d15f2b26017dcf0af72d4f59c702c9de48) |
| 24 | `update-adapters` | §14.2.6 `UpdateAdapters` | [`44a66ee6aa2e0f97…`](https://preprod.cardanoscan.io/transaction/44a66ee6aa2e0f97468a7c353f20359d9a8cad5e9b093927d00dda0194bd6203) |
| 25 | `register 1 account(s)` | stake registration | [`b7433e8b50c65248…`](https://preprod.cardanoscan.io/transaction/b7433e8b50c65248ed03f77b95d9f30dbf92555e551f4ce9bb8e43c3710431a9) |
| 26 | `borrow-async` | §7.6 `OpenDirect` with a claim — one transaction opens and places the swap | [`1b8fec515b4d6602…`](https://preprod.cardanoscan.io/transaction/1b8fec515b4d660207b74ccf5c03a2cdcbdc5c01c5278f4e6c9d4eb297fe65b8) |
| 27 | `settle-claim` | §8 `SettleClaim` | [`46ec9b2cd8bb248d…`](https://preprod.cardanoscan.io/transaction/46ec9b2cd8bb248decc80f246947a4a41ffac8050838a04e4bbccdd47688bb5f) |
| 28 | `sweep` | wallet hygiene | [`ec04f3958d289a5e…`](https://preprod.cardanoscan.io/transaction/ec04f3958d289a5ef85721b5319967a72cb9cea37dd9dca7ebda9b092c251947) |
| 29 | `create-order` | §6 `CreateOrder` | [`4c2dc5ffcccae963…`](https://preprod.cardanoscan.io/transaction/4c2dc5ffcccae96379014298595fcdfecc84e30b66626b106a8becf938aad246) |
| 30 | `fill-sync` | §7.3 the synchronous fill | [`40e275d68d2efc0a…`](https://preprod.cardanoscan.io/transaction/40e275d68d2efc0ad16f9c0867b5a37f0460be3fcfd47abbccfdc74f3788ab56) |
| 31 | `cancel-order` | §9.3 `ModifyOrder`, cancel arm | [`2751d19d56068f18…`](https://preprod.cardanoscan.io/transaction/2751d19d56068f188df45ae1e74eeb7ce17c5c617901872357882d6ab3c48bc3) |
| 32 | `repay` | §10.1 `RepayLoan` | [`c07e7a239084ac99…`](https://preprod.cardanoscan.io/transaction/c07e7a239084ac9959a86364dac38d17e7df588b4f958ca5728f41c9a8dbb06b) |
| 33 | `sweep` | wallet hygiene | [`bf5fcbb96584986a…`](https://preprod.cardanoscan.io/transaction/bf5fcbb96584986a2acb84a58972ee2037d0243ded05c4eca89d270833231f1c) |
| 34 | `create-order` | §6 `CreateOrder` | [`283bed3a07b345ac…`](https://preprod.cardanoscan.io/transaction/283bed3a07b345ac71a373025d8559070345602a64c9faf9a6e637cb20112476) |
| 35 | `fill-sync` | §7.3 the synchronous fill | [`984e9bbe6ba04d5d…`](https://preprod.cardanoscan.io/transaction/984e9bbe6ba04d5d9f7ce053859e9d44afca51d58ad100b270edb09a1e108442) |
| 36 | `cancel-order` | §9.3 `ModifyOrder`, cancel arm | [`492f9b0dd6cc792d…`](https://preprod.cardanoscan.io/transaction/492f9b0dd6cc792d5af4646ca1268cd28b72570630186dd7d4c2bd822d691fa6) |
| 37 | `repay` | §10.1 `RepayLoan` | [`b4ed97bced32b500…`](https://preprod.cardanoscan.io/transaction/b4ed97bced32b500a6b593cf05873625b57b49a60c7f2abeb908bdf23f33e319) |
| 38 | `supply` | §18 `TopupWithdraw`, deposit | [`c5fe7efa27251d85…`](https://preprod.cardanoscan.io/transaction/c5fe7efa27251d850b4b2519ae2bd05dba6080d395109836ea8f1c86afd02ec8) |
| 39 | `sweep` | wallet hygiene | [`eb02a1f05a1feda8…`](https://preprod.cardanoscan.io/transaction/eb02a1f05a1feda8913a92762a08789a2e969f9bc67f9c220be693f8d2f62c9a) |
| 40 | `create-order` | §6 `CreateOrder` | [`9d79314e9e9a9a01…`](https://preprod.cardanoscan.io/transaction/9d79314e9e9a9a018039caf36c5522b0e75cf192bc423db059b27eb0c09adb8d) |
| 41 | `sweep` | wallet hygiene | [`82637acd823cfab8…`](https://preprod.cardanoscan.io/transaction/82637acd823cfab85903dbeb97125dc10018ebf3ec2cbbe71c69498239f22e18) |
| 42 | `fill-minswap` | §7.2 with §7.4 — the asynchronous fill | [`2b7ee2e6d68d8d7f…`](https://preprod.cardanoscan.io/transaction/2b7ee2e6d68d8d7fcc134c8b828e719c2ca0d9b74896a96da042cc6bfd9aa931) |
| 43 | `settle-claim` | §8 `SettleClaim` | [`28ee6fa1b722e793…`](https://preprod.cardanoscan.io/transaction/28ee6fa1b722e793499716762e702c90e62b676e4b33754003322f90f30f864c) |
| 44 | `cancel-order` | §9.3 `ModifyOrder`, cancel arm | [`348e90e0d7a054e5…`](https://preprod.cardanoscan.io/transaction/348e90e0d7a054e5e2d4b62117f1be6950cdcb6f5265803fdd723959a353508e) |
| 45 | `borrow` | §7.6 `OpenDirect`, collateral already held | [`83cc29d95dcbf1ff…`](https://preprod.cardanoscan.io/transaction/83cc29d95dcbf1ffbb97f2275e14cbcc0f6af62f9288cccd33cd4a77c2762017) |
| 46 | `borrow` | §7.6 `OpenDirect`, collateral already held | [`cc071be7937affc3…`](https://preprod.cardanoscan.io/transaction/cc071be7937affc3b3089aba7aae6a4787685619edaaa9d2c579de85dd299746) |
| 47 | `liquidate` | §11 `Liquidate` | [`cda16a79e7900c14…`](https://preprod.cardanoscan.io/transaction/cda16a79e7900c14e168952c7c35b30a6749138e08a93023e02c7ee95c26341d) |
| 48 | `collect-remain` | §13.3 `CollectRemain` | [`f26d594d0d428766…`](https://preprod.cardanoscan.io/transaction/f26d594d0d4287669319fb90f3e50df0f29f8086b94b626aea0153bba2e868da) |
| 49 | `sweep` | wallet hygiene | [`5ebdc91f747db182…`](https://preprod.cardanoscan.io/transaction/5ebdc91f747db182d49d9c3657a5bfa99e9604e3472bdce177835011b58ac7c1) |
| 50 | `create-order` | §6 `CreateOrder` | [`909ba9cf29f0fbba…`](https://preprod.cardanoscan.io/transaction/909ba9cf29f0fbbaf4c901afe82fe8e5986fa206a4425841e32718a7e4544879) |
| 51 | `fill-sync` | §7.3 the synchronous fill | [`8385aef413f3251a…`](https://preprod.cardanoscan.io/transaction/8385aef413f3251acb2f9f43b0c4f4616fd21956924e1d3e0d8e2c681078b427) |
| 52 | `cancel-order` | §9.3 `ModifyOrder`, cancel arm | [`0643e1358d9f8cce…`](https://preprod.cardanoscan.io/transaction/0643e1358d9f8ccea6dcb6a8552bc8643c630b3577cc537beb2d9b15b0ca7640) |
| 53 | `sweep` | wallet hygiene | [`582d4ccfede2d1ea…`](https://preprod.cardanoscan.io/transaction/582d4ccfede2d1eaa65e6b7a4643296be121a7b317ed1365760e1dc595f8190b) |
| 54 | `create-order` | §6 `CreateOrder` | [`a1b38e56d8b5b8ec…`](https://preprod.cardanoscan.io/transaction/a1b38e56d8b5b8ec5b4294143e55850ffedc2efac2b104030575ff7c29491837) |
| 55 | `sweep` | wallet hygiene | [`103051a52e88613f…`](https://preprod.cardanoscan.io/transaction/103051a52e88613fe6bf1626471121207d6537b7d21f37cdbe34900a6b058226) |
| 56 | `fill-minswap` | §7.2 with §7.4 — the asynchronous fill | [`99ddcc5c1237c03a…`](https://preprod.cardanoscan.io/transaction/99ddcc5c1237c03acdf04be948d257ac08e1a3366499656f9b33a1960cfff833) |
| 57 | `cancel-claim` | §4.3 the claim is cancelled once expired | [`30a6c90fe44f96e9…`](https://preprod.cardanoscan.io/transaction/30a6c90fe44f96e95dde69359364bb2de053c2353d447861d00b0499775cc5a5) |
| 58 | `rollback` | §12.3 `Rollback` | [`0cbe9d818899f190…`](https://preprod.cardanoscan.io/transaction/0cbe9d818899f190986f7446123a4674b889570ac3a521eacc3110bc28c649d6) |
| 59 | `collect-remain` | §13.3 `CollectRemain` | [`bba6082c88db21f6…`](https://preprod.cardanoscan.io/transaction/bba6082c88db21f63f37cf7dfa656052a098201ee7748679b2c730ced4ec8885) |
| 60 | `cancel-order` | §9.3 `ModifyOrder`, cancel arm | [`3508c775df794dae…`](https://preprod.cardanoscan.io/transaction/3508c775df794daea804a8f2dcc7711d3a2a185a093bbb6b1470a4d38b1be165) |
| 61 | `redeem` | §18 `TopupWithdraw`, withdrawal | [`6827c7c1a3b0aafc…`](https://preprod.cardanoscan.io/transaction/6827c7c1a3b0aafc38676c7e67cc91b43d8490d43e5dd12ff6b429dacf09519c) |
| 62 | `modify-position` | §16 `ModifyPosition` | [`0220ae2d43e9fcb8…`](https://preprod.cardanoscan.io/transaction/0220ae2d43e9fcb8cab63563dac0481b74a550f1a0d1c7a0bea7935d86a83853) |
| 63 | `close-async` | §10.2.1 the sell claim | [`261421ceaf98b42e…`](https://preprod.cardanoscan.io/transaction/261421ceaf98b42e235bed1ebc46927b37359ac39a76213fa55f50b4721411fe) |
| 64 | `sweep` | wallet hygiene | [`5289144e373efa23…`](https://preprod.cardanoscan.io/transaction/5289144e373efa234995b8f216b7b0beadace4bd2c931a2d4d095a345af5d28c) |
| 65 | `create-order` | §6 `CreateOrder` | [`8e18f8670faa498f…`](https://preprod.cardanoscan.io/transaction/8e18f8670faa498fc666cc5e74faf8834c72db2efc39ba32f87115930476db5e) |
| 66 | `fill-sync` | §7.3 the synchronous fill | [`7b7f919c3ba543e5…`](https://preprod.cardanoscan.io/transaction/7b7f919c3ba543e5fd3bdf6dc619eb482505cdf9f8f3c70b839c82f6d0a40f08) |
| 67 | `cancel-order` | §9.3 `ModifyOrder`, cancel arm | [`1afa461f7304361b…`](https://preprod.cardanoscan.io/transaction/1afa461f7304361bdaf7a01d226711b7804e8f2f7bdbcadee8af42d1144e23bc) |
| 68 | `modify-position` | §16 `ModifyPosition` | [`95e3abf8cf0ce432…`](https://preprod.cardanoscan.io/transaction/95e3abf8cf0ce432aaeaeaed83b224376c358dde059650a5c8bc7b85905047ad) |
| 69 | `sweep` | wallet hygiene | [`7341b906e046911d…`](https://preprod.cardanoscan.io/transaction/7341b906e046911db34bbda57fd307952ad04f6c98b40f02a32dbcb49c6a49dc) |
| 70 | `take-profit` | §10.2.1, the take-profit close no one signed | [`ecc7436afbb90690…`](https://preprod.cardanoscan.io/transaction/ecc7436afbb9069016436c082011a1c60afb25c4c3f398bcdff501035b5c844a) |
| 71 | `tidy` | — | [`abd222adfe182d9d…`](https://preprod.cardanoscan.io/transaction/abd222adfe182d9dddf06ddfa66405cbf8dec1710e325efff9391258b79979a1) |
| 72 | `update-market-param` | §15 `UpdateMarketParam` | [`202ca877848478f7…`](https://preprod.cardanoscan.io/transaction/202ca877848478f7b12906e8936541c1cb2a705516c88f75cf0359b1deebe6d2) |
| 73 | `withdraw-fee` | §19 `WithdrawFee` | [`8c5f1a211dbec4f2…`](https://preprod.cardanoscan.io/transaction/8c5f1a211dbec4f20bba05915cc71e2774d24abf04e180efdf647b9c1858a09a) |
| 74 | `announce-oracle` | §14.2.5 `AnnounceOracle` | [`67de5dda290ce7f2…`](https://preprod.cardanoscan.io/transaction/67de5dda290ce7f239b8764bd836c2d5e9ac8c041221ad7f4de29fba6a447fa5) |
| 75 | `settle-close` | §10.2.2 repay on fill | [`70e4aa6c15d9badc…`](https://preprod.cardanoscan.io/transaction/70e4aa6c15d9badc56658010daf9be937faeb0ac99b7355cb723d3db6e78c749) |
| 76 | `settle-close` | §10.2.2 repay on fill | [`0b7a2f2e118ddb41…`](https://preprod.cardanoscan.io/transaction/0b7a2f2e118ddb41bbe365bdf40ad50b3a39690f62c66a9ebf10ae9edec04af3) |
| 77 | `create-order` | §6 `CreateOrder` | [`7fbbf32207bfc043…`](https://preprod.cardanoscan.io/transaction/7fbbf32207bfc043a736f79fe6ceb2a5422a3ab31c817684f4414cce49a49f40) |
| 78 | `fill-sync` | §7.3 the synchronous fill | [`757bdf025cda5f0e…`](https://preprod.cardanoscan.io/transaction/757bdf025cda5f0e5ffd779695666f564e93b49424fdbbf653643cff71d72bb5) |
| 79 | `cancel-order` | §9.3 `ModifyOrder`, cancel arm | [`c76e7ebaf860e4ad…`](https://preprod.cardanoscan.io/transaction/c76e7ebaf860e4adea39cfe4c2cb9bec460ca5d4338c201f63d45dc397461098) |
| 80 | `repay` | §10.1 `RepayLoan` | [`b0106e78cc71c316…`](https://preprod.cardanoscan.io/transaction/b0106e78cc71c31644d4c52b13613eaaa9d4844a96f89b7479f37173d87e6f2a) |
| 81 | `collect-remain` | §13.3 `CollectRemain` | [`5db52ea31b0f0b72…`](https://preprod.cardanoscan.io/transaction/5db52ea31b0f0b72761b576d78e2524ed05d80d346d003d98243dbc6936721b5) |

## 4. How each transaction is shaped

Eight of the subsections below describe arms this deployment did **not** exercise
— 4.7, 4.8, 4.9, 4.13, 4.14, 4.18, 4.19 and 4.20, every one of them downstream of
a price. Their shapes are unchanged and worth reading; what is missing is a hash
of this deployment beside them. §5 is the reason, and the transaction links inside
those eight belong to the previous release, whose registry no longer exists.

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

Only `take_profit_price` and `min_execution_amount` may move, and the latter only
upward. The value is byte-identical, which is what keeps the `LoanOwnerNFT`
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
needs only its index, checked against `max_index_staleness`. The loan must be
**healthy** here, which is the opposite of §11's gate.

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

### 4.20 Take-profit — §10.2.1 with no owner input

**The one to copy:** [`1d62ef9edf67579d…`](https://preprod.cardanoscan.io/transaction/1d62ef9edf67579da4256446c3be907304377f682a26d3997a62eb79e3c3583e), settled by
[`300ad1970fea5038…`](https://preprod.cardanoscan.io/transaction/300ad1970fea50389facd1bc4c756736ec9b6a1329137f5c8ac75a5f42a614c5) and swept by [`d55972bbe88e5169…`](https://preprod.cardanoscan.io/transaction/d55972bbe88e5169b9b628e4ab161f1debe4651d617e43937da0bd796e392dbf). Neither
of the first two carries a `PositionOwnerNFT` in any input. For contrast, the same
arm taken by the trader is [`4dbda380c2721bf2…`](https://preprod.cardanoscan.io/transaction/4dbda380c2721bf27d85e63a62492713b13a1a4088d7999c29b73bcb799140ea), where
the ticket is named.

The same transaction as §4.18, built by someone who does not hold the ticket. The
difference is one index and one gate:

| | |
|---|---|
| redeemer | `position_owner_in_idx = -1` — §5 rule 11a's absent index |
| inputs | loan, position, funding. **No `PositionOwnerNFT`** |
| gate | `take_profit_price.numerator > 0`, and the oracle's rate for the long leg has reached it |

Everything else — the floor, the venue order, the claim, the health gate — is
byte-for-byte the arm above, which is the point: what the venue sees cannot tell
the two apart, so a take-profit needs no separate settlement path.

```
price = oracle rate for long_token, quoted in short_token per unit
fires when  price.num * tp.den >= tp.num * price.den
```

Cross-multiplied rather than divided, because a division would round where the
validator does not. **`take_profit_price` is quoted the way the oracle quotes —
supply token per unit of the long leg — which is the opposite orientation to
`open_limit_price`**, whose §7.4.2 use is `sold * denominator / numerator` and so
states long per short. An opening bound on what is paid, against a closing bound
on what is received. `numerator == 0` is the sentinel §6.2.2 leaves room for: a
position with no take-profit standing, which no price can reach.

The gate was exercised in all three states against the same live oracle rate of
`523221885148/159562448003` — about 3.279 ADA per fUSDM:

| `take_profit_price` | | Result |
|---|---|---|
| `0/1` | no standing instruction | rejected, `Withdraw[1]` |
| `1046443770296/159562448003` | twice the rate | rejected, `Withdraw[1]` |
| `523221885148/319124896006` | half the rate | **accepted** |

Both rejections come from the `loan_repay` withdrawal, which is where the gate
lives; nothing else about the transaction changed between them.

One trap for whoever automates this, and [`2b976d32ba9184c4…`](https://preprod.cardanoscan.io/transaction/2b976d32ba9184c4a211787ef916222a19db90dd505f191555ded3c1aabcf40c)
is what it looks like. `--cancel-order` releases the
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

The three transactions, in order:

| | | Transaction |
|---|---|---|
| the borrower opens and places the swap | one transaction | [`1b8fec515b4d…`](https://preprod.cardanoscan.io/transaction/1b8fec515b4d660207b74ccf5c03a2cdcbdc5c01c5278f4e6c9d4eb297fe65b8) |
| the venue's own batcher fills it | 220 737 fBTC against a floor of 214 114 | `0d45b8c549d0…#0` |
| §8 settles the payout into the loan | permissionless | [`46ec9b2cd8bb…`](https://preprod.cardanoscan.io/transaction/46ec9b2cd8bb248decc80f246947a4a41ffac8050838a04e4bbccdd47688bb5f) |

---

## 5. The price, and the arms that wait on it

Nine arms read a price, and every one of them was rejected before it was
accepted. All four causes were in this repository, and three of them are
invisible from the error the node returns.

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

With all four fixed, every price-reading arm ran on this registry, against the
fUSDM market — the pair whose oracle path is maintained:

| Arm | | Transaction |
|---|---|---|
| §7.6.7 `OpenDirect` with a claim | one transaction opens and places the swap | [`1b8fec515b4d…`](https://preprod.cardanoscan.io/transaction/1b8fec515b4d660207b74ccf5c03a2cdcbdc5c01c5278f4e6c9d4eb297fe65b8) |
| §7.2 with §7.4 | the asynchronous fill | [`2b7ee2e6d68d…`](https://preprod.cardanoscan.io/transaction/2b7ee2e6d68d8d7fcc134c8b828e719c2ca0d9b74896a96da042cc6bfd9aa931) |
| §8 `SettleClaim` |  | [`28ee6fa1b722…`](https://preprod.cardanoscan.io/transaction/28ee6fa1b722e793499716762e702c90e62b676e4b33754003322f90f30f864c) |
| §7.6 `OpenDirect` | collateral already held | [`83cc29d95dcb…`](https://preprod.cardanoscan.io/transaction/83cc29d95dcbf1ffbb97f2275e14cbcc0f6af62f9288cccd33cd4a77c2762017) |
| §7.6 at the health boundary | opened with the headroom the index would eat | [`cc071be7937a…`](https://preprod.cardanoscan.io/transaction/cc071be7937affc3b3089aba7aae6a4787685619edaaa9d2c579de85dd299746) |
| §11 `Liquidate` | once the index had eaten it | [`cda16a79e790…`](https://preprod.cardanoscan.io/transaction/cda16a79e7900c14e168952c7c35b30a6749138e08a93023e02c7ee95c26341d) |
| §13.3 `CollectRemain` |  | [`f26d594d0d42…`](https://preprod.cardanoscan.io/transaction/f26d594d0d4287669319fb90f3e50df0f29f8086b94b626aea0153bba2e868da) |
| §16 `ModifyPosition` |  | [`0220ae2d43e9…`](https://preprod.cardanoscan.io/transaction/0220ae2d43e9fcb8cab63563dac0481b74a550f1a0d1c7a0bea7935d86a83853) |
| §10.2.1 the sell claim |  | [`261421ceaf98…`](https://preprod.cardanoscan.io/transaction/261421ceaf98b42e235bed1ebc46927b37359ac39a76213fa55f50b4721411fe) |
| §10.2.1 take-profit | no owner input — a stranger closed it on the oracle's word | [`ecc7436afbb9…`](https://preprod.cardanoscan.io/transaction/ecc7436afbb9069016436c082011a1c60afb25c4c3f398bcdff501035b5c844a) |
| §10.2.2 repay on fill |  | [`70e4aa6c15d9…`](https://preprod.cardanoscan.io/transaction/70e4aa6c15d9badc56658010daf9be937faeb0ac99b7355cb723d3db6e78c749) |

### §10.2.2, and why this registry exists at all

Proving §10.2.1 exposed a contract bug that only a token-supply market can hit.
§10.2.2.6 requires the remain UTxO to carry over every asset the payout held, and
`carries_over` skips lovelace — so on a market that lends ADA the venue's proceeds
were never in its domain, and `net(remain, short_token) >= q - debt_repaid`
governed them alone. Where the supply token is a token they fall under both at
once and the two disagree by exactly `debt_repaid`: the remain was required to
hold the whole payout while the pool was required to be paid out of it. §10.2.2
could not be built on such a market at all. The sold leg is now excluded from the
payout's carry-over, `loan_repay` moved 13 043 → 13 050 bytes as compiled
(13 123 once the `ProtocolNFT` is applied, which is the size §1 lists), and since
`loan_repay_skh` is one of the registry's immutable fields this registry is what
that fix required.

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

---

## 7. Where it ended

Read back off chain after the last transaction:

| | |
|---|---|
| ADA pool | 806.500031 ADA · `total_supply` 800.000024, `total_borrow` **0**, `undistributed_fee` 1.500007, `bad_debt` **0** |
| fUSDM pool | 5 ADA + 199,996,998.185483 fUSDM · `total_supply` 200,000,000.028351, `total_borrow` 3,003.347883, `undistributed_fee` 1.503933, `bad_debt` **0** |
| fBTC pool | 5 ADA + 1 fBTC · `total_supply` 100,000,000, `total_borrow` **0**, `undistributed_fee` 0, `bad_debt` **0** |
| Loans | three open, all three carrying no claim, with three positions to match. One §13.2 remain UTxO is still unswept |
| Orders | **none** — every order this registry posted was filled or cancelled |
| Reference scripts | all 11 reproduce from this source — `--verify` rebuilds each from `plutus.json` and matches the record |

Ten loans were opened — five through §7.3, two through §7.2, two through §7.6 and
one through §7.6.7 — and seven were closed, by every closing route the spec has:

| Route | | Times |
|---|---|---:|
| Repaid, no venue | §10.1 | 3 |
| Repaid out of a venue fill | §10.2.2 | 2 |
| Liquidated | §11 | 1 |
| Rolled back after an unfilled claim | §12.3 | 1 |

The two §10.2.2 are worth separating: one settled a claim `--close-async` placed,
the other one that **take-profit** placed, and the second is what proves the
record change in §6 item 20. Before it, the arm had to be handed its loan by
hand, because two `Closing` claims were outstanding and the record could name
only one. After it, `--settle-close` found the loan itself and read the claim's
floor, sold leg and expiry off that loan's own datum.

`bad_debt` of **0** on all three pools is what says the seven closures landed
whole, the §12.3 included — its recovered leg covered its debt exactly. The three
loans still open carry no claim and can be closed by either route whenever.

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
