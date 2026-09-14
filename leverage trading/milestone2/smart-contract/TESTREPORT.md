# Test report — Smart contracts

| | |
|---|---|
| Suite | `aiken check` |
| Result | **287 tests, 0 failures** |
| Modules with tests | 32 — 21 inline, 11 under `lib/tests/` |
| Compiler | Aiken v1.1.17+c3a7fba, Plutus V3 |
| Dependencies | `aiken-lang/stdlib` v3.0.0, `danogo2023/daken` v2.3.5 |
| Warnings | 19, all pre-existing — §6 lists them |
| Validator hashes | **all eleven byte-identical to `main`** — §2 |
| Build | `aiken build -t silent` succeeds; largest validator `loan` at 14 483 bytes against a 16 384 limit |

```bash
aiken check                 # 287 tests
aiken build -t silent       # the eleven validators
```

`aiken check` emits JSON on stdout, one record per test with its execution
units. Everything below is read off that.

---

## 1. What a test here is, and what it proves

Aiken's `test` blocks call a `validate` function **directly**, with a
hand-constructed `Input`, `Output`, `Value` and redeemer. They are unit tests of
the validators' logic and nothing wider. §5 is explicit about what that leaves
out.

Two block forms appear, and they carry different weight:

- A **plain block** asserts a shape is accepted. 135 of the 287 are plain, and
  many are table-driven: 193 tabulated case rows sit inside them, each a
  labelled row with its own `expected`, so the number of distinct scenarios
  exercised is well above the number of blocks.
- A **`fail` block** asserts a shape is rejected. 152 of the 287 are `fail`
  blocks.

A `fail` block is weaker evidence than it looks, and the suite is built around
that. `test x() fail { .. }` passes when the body returns `False` **or** crashes
— for any reason, including a fixture the validator never got far enough to
judge. So a rejection is only evidence when an accepting case beside it holds
the rest of the shape constant: every module here has a fixture that **passes**
first, and each rejection is that same fixture with one field moved. Where the
accepting case would fail, so would the attribution of every rejection near it.

`lib/tests/execute_order_test.ak` is the clearest instance. One §7.2 fill is
arranged so every term is a round number —

```
margin              = net(order_in, fUSDM)   = 100_000_000
short_amount                                 = 500_000_000
tbv    = short_amount - margin               = 400_000_000
loan_amount                                  = 400_000_000
short_from_order_in = deposit_qty            = 100_000_000
long_from_order_in                           = 0
```

— so §7.2.8 closes exactly (`short_amount == loan_amount +
short_from_order_in`) and §7.2.7 sits on the leverage cap,
`leverage_cap(8000, 0) = 5.00x`. Two accepting blocks establish it, one per
venue arm, and twenty-nine single-field departures follow.

## 2. Why 193 of these tests are not beside the code they test

The 94 tests that came first are inline, each in the module it exercises. The
193 added since are in eleven new modules under `lib/tests/`, and that is a
departure from the repository's own habit made for one reason: **every validator
hash is a compile-time function of the bytes of its own source**, and the
registry recorded in `deployments/preprod.json` is the one in use. A file under
`lib/` that a validator compiles from cannot change while that is true —
`order_skh`, `loan_repay_skh` and `loan_close_skh` are immutable registry
fields, so a moved hash cannot be adopted by any `protocol_config` transition
and the deployment would need a fresh genesis.

So the property this branch holds, and which is worth re-checking after any
change to it:

```
$ diff <(hashes from main) <(hashes from HEAD)     # all eleven idenal
$ git diff --name-only main -- lib/                # nothing but new files
```

`aiken` strips tests from the blueprint, so a test module costs nothing on
chain and the arrangement is reversible: moving these inline later changes no
hash either. Each module says as much at the top. They reach only what their
subject already exports, so no visibility had to be widened to accommodate them.

## 3. Coverage

### Added — `lib/tests/`

| Module | Subject | Tests | Plain | `fail` |
|---|---|---:|---:|---:|
| `tests/utils_test` | `utils.ak` | 9 | 7 | 2 |
| `tests/wire_format_test` | `types.ak` | 9 | 8 | 1 |
| `tests/protocol_utils_test` | `protocol/utils.ak` | 21 | 10 | 11 |
| `tests/position_utils_test` | `position/utils.ak` | 20 | 8 | 12 |
| `tests/create_position_test` | `position/create_position.ak` | 9 | 2 | 7 |
| `tests/modify_position_test` | `position/modify_position.ak` | 19 | 5 | 14 |
| `tests/close_position_test` | `position/close_position.ak` | 16 | 4 | 12 |
| `tests/modify_order_test` | `order/modify_order.ak` | 34 | 8 | 26 |
| `tests/execute_order_test` | `order/execute.ak` | 31 | 4 | 27 |
| `tests/sync_generic_test` | `adapter/sync_generic.ak` | 17 | 12 | 5 |
| `tests/market_params_test` | the deployer's market datum | 8 | 8 | 0 |
| | | **193** | **76** | **117** |

Ten of the eleven subjects had **no test at all** before — about 1 400 lines,
including the whole position arm and order execution, the two most expensive
paths in the protocol.

### Pre-existing — inline

| Module | Tests | | Module | Tests |
|---|---:|---|---|---:|
| `order/create_order` | 15 | | `loan/rollback` | 3 |
| `loan/utils` | 7 | | `loan/settle_claim` | 3 |
| `pool/utils` | 7 | | `loan/collect_remain` | 3 |
| `pool/pool_flow` | 6 | | `loan/liquidate` | 3 |
| `pool/rebalance_alt` | 5 | | `loan/open_direct` | 3 |
| `pool/topup_withdraw` | 5 | | `adapter/minswap` | 3 |
| `pool/withdraw_fee` | 5 | | `adapter/utils` | 2 |
| `protocol/protocol_config` | 5 | | `loan/dispatch` | 2 |
| `protocol/create_market` | 4 | | `loan/open_loan` | 1 |
| `protocol/market_param` | 4 | | | |
| `loan/repay_loan` | 4 | | | |
| `order/utils` | 4 | | **subtotal** | **94** |

Test counts are not a quality ranking. `loan/` has the fewest per line and the
densest arithme, because its tests are table-driven over the arithmetic
directly — `loan/utils`' seven blocks cover `debt_now`, `debt_at`, the health
gate, the seized/repaid shortfall and the reward clamp across dozens of rows —
while `order/` and `position/` need a whole transaction shape per case and so
spend a block on each.

`constants.ak` is the one module with no tests. It is declarations only.

## 4. Two things the suite pins that nothing else would

### The wire format

`types.ak` holds no logic, and `wire_format_test` pins the one property of it
that can break silently. Every datum decodes **positionally**, so a field
inserted anywhere but the end rebinds every field after it (§5 rule 13a), and a
constructor index that moves changes what an already-deployed redeemer means.
Neither is a type error. Neither surfaces before a transaction is built against
a live UTxO and rejected with nothing to say.

- the arity of `OrderDatum` (13), `PositionDatum` (5), `LoanDatum` (5),
  `PoolDatum` (9), `RemainDatum` (3) and `Claim` (7), each at constructor 0;
- three `OrderDatum` fields pinned by **position and value** — `short_amount`
  at index 2, `min_liquidation_threshold` at 5, `fee_reserve` at 12;
- `ReservedTakeProfit` holding constructor index **1**. §5 rule 15 keeps the
  placeholder because dropping it would renumber `ModifyPosition`,
  `ClosePosition` and `BurnOwnerNFT` — a redeemer built against the deployed
  encoding would then select the wrong arm rather than fail to decode;
- `UpdateMarketParam` still at index 0, so §15 is unchanged on the wire;
- `CollateralRoute` at 0/1/2 and `ClaimDirection` at 0/1;
- DEPLOYMENT.md §6 item 2 — an Aiken 2-tuple is a CBOR **list**, so
  `TupleAsset` is `[policy, name]` and `Option<(Int, Int)>` is
  `Constr(0, [[a, b]])`.

### The market parameters, as a transition

`t_preprod_market()` in `protocol/create_market.ak` used to be the twin of
`MARKET` in `releases/src/market.ts`, checked against §1.3 by the test beside
it. It is no longer: the fixture keeps the values the live markets opened with,
because nothing under `lib/` may move. `market_params_test` took over, and it
proves strictly more than the fixture could:

- the whole of §1.3 on the proposed datum;
- `bounds_ok(deployed, proposed)` — that §15 admits the move from what is
  actually live, which a datum checked against itself cannot express;
- that the reverse is **barred**, since `venue_fee_budget`, `execution_tip` and
  `max_cancel_fee` may only fall;
- the three amounts §1.3 does not bound but the ledger does. Each is paid to an
  output whose lovelace a validator fixes by **equality** — `execution_tip`
  (`order/execute.ak:336`), `rollback_tip` (`loan/rollback.ak:122`) and
  `min_ada - collector_reward`, §11.2.7's grace tip
  (`loan/liquidate.ak:252`) — so a value under 1 055 950 makes the arm
  unbuildable rather than merely unattractive, and `aiken check` alone would not
  notice;
- `adapter_minswap.ak:409`'s batcher term, which §1.3 knows nothing about: a
  budget that satisfies §1.3 and leaves Minswap's 2 ADA nothing would pass
  `bounds_ok` and then fail every asynchronous fill;
- `venue_fee_budget`'s cap and floor **in isolation**. Neither is reachable from
  `parameter_bounds` in `protocol/market_param.ak`, because the monotone rule
  `venue_fee_budget <= i.venue_fee_budget` fires first on any value above that
  fixture's own. Each needs an input datum that separates the two rules.

The last point is the general lesson of this suite: a green `fail` case proves a
rejection happened, not which rule did the rejecting, and a bound reachable only
through a fixture that also violates a neighbouring rule is a bound nobody is
checking.

## 5. What this suite does not cover

The honest limits, in the order they matter.

1. **These are not ledger-level tests.** A test calls `validate` with a fixture
   it built. Nothing here exercises script context assembly, redeemer CBOR
   decoding, the minADA rule, fees, collateral, reference-script cost, execution
   unit budgets, or `maxTxSize`. Every one of those has cost a rejected
   transaction on preprod, and DEPLOYMENT.md §6 is the list — twenty-two items,
   most of them invisible from inside a unit test.

2. **Cross-arm consistency is not exercised end to end.** §7.2.18's pool
   equation spans a loan action and a pool action in one transaction, and each
   side is tested against its own fixture with the other side assumed. The same
   holds for §5 rule 16's withdrawal pairing: `close_position` checks that a loan
   withdrawal is *present*, `loan_repay` holds the arithmetic, and no test runs
   both scripts against one transaction. That composition is proven only on
   chain.

3. **The oracle is out of scope.** Every price-reading arm resolves its rate
   through `oracle_skh`, a separate script this repository does not contain. The
   fixtures supply prices directly. DEPLOYMENT.md §5 is the account of what that
   left undetected: four causes, three of them invisible from the node's error,
   and all four found by submitting rather than by testing.

4. **No property or fuzz testing.** All 287 blocks are unit tests over chosen
   values. Aiken supports property tests; none is used. The arithmetic modules —
   `loan/utils`' `debt_at`, `pool/utils`' interest curve, `order/utils`'
   `leverage_cap` — are the obvious candidates, and their floor-division
   behaviour is exactly what a fuzzer finds and a table does not
   (DEPLOYMENT.md §6 item 1).

5. **DEPLOYMENT.md §8's parameters are proven admissible, not submitted.**
   `market_params_test` shows they clear §1.3, the ledger's three minima and the
   batcher term, and that §15 admits the transition. No `--update-market-param`
   has run. What is proven is that the markets *can* be moved to those numbers,
   not that a 19.5 ADA order then fills against Minswap.

6. **19 compiler warnings remain**, all pre-existing, in three kinds:

   | Kind | Count | Where |
   |---|---:|---|
   | unused import | 7 | `pool/utils`, `loan/utils`, `loan/open_loan` (2), `adapter/minswap` (2), `loan/liquidate` |
   | unused binding in a pattern | 11 | `loan/dispatch` (4), `loan/repay_loan` (3), `loan/rollback` (2), `loan/open_loan`, `order/execute` |
   | `expect` on a single-constructor type | 1 | `adapter/minswap.ak:345` |

   None affects compiled output, and none is in `lib/tests/`. They are left
   alone rather than swept, and not only because touching those files would move
   a hash: some of the unused bindings are load-bearing as documentation.
   `order/execute.ak:59`'s `is_market` is the clearest — the field is still
   destructured out of `OrderDatum` and no longer read, because §7.4.9 now gates
   the asynchronous fill on whether the reserve is **funded** rather than on the
   flag. Deleting the binding would erase that.

## 6. Execution units

The JSON reports the cost of evaluating each test. **These are not on-chain
validator costs**: a test body builds its own fixture and then calls one
`validate` function, so it counts the fixture construction and excludes script
context assembly, redeemer decoding and the other purposes a real transaction
runs. Read them as a relative signal — a test that grew unexpectedly large is
usually one whose fixture did — and not against the ledger's per-transaction
budget.

Suite totals: **175 326 214** mem, **55 833 040 065** cpu. The five heaviest
blocks are all table-driven, which is what a table costs:

| Test | cpu | mem |
|---|---:|---:|
| `pool/pool_flow.pool_flow_happy_paths` | 1 794 329 648 | 5 703 273 |
| `protocol/market_param.parameter_bounds` | 1 789 402 325 | 5 131 227 |
| `order/create_order.create_order_accepts` | 1 768 900 616 | 5 332 350 |
| `pool/topup_withdraw.topup_withdraw_happy_paths` | 1 527 185 249 | 4 794 965 |
| `pool/withdraw_fee.withdraw_fee_happy_paths` | 1 268 944 279 | 3 941 638 |

For the sizes that **do** bind on chain, see DEPLOYMENT.md §1: `loan` compiles
to 14 483 bytes before `protocol_nft` is applied and 14 556 after, against a
`maxTxSize` of 16 384. `aiken build -t silent` is not optional there — tracing
adds about 64% and puts the three loan hosts over the limit.

## 7. How this sits beside the on-chain record

The two halves prove different things and neither substitutes for the other.

| | Unit tests | DEPLOYMENT.md |
|---|---|---|
| What is exercised | one `validate` function per case | whole transactions, submitted |
| Coverage | every module with logic, 287 cases | every arm the spec has, 81 transactions |
| Catches | a rule that admits what it should reject | a rule no builder can satisfy at all |
| Blind to | everything in §5 above | anything a built transaction never reaches |
| Cost of a failure | a second | a rejected submission and, twice here, a fresh genesis |

DEPLOYMENT.md §7 is the on-chain counterpart of this document: ten loans opened
across §7.2, §7.3, §7.6 and §7.6.7, seven closed by every route the spec has,
and `bad_debt` of 0 on all three pools — which is what says those closures
landed whole.
