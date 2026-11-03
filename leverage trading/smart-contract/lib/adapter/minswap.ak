//// `adapter/minswap` — 05-02-minswap.md. Pinned to Minswap DEX V2, the one
//// asynchronous venue, and the only adapter implementing all five obligations.
////
//// The venue datums below carry exactly the fields 05-02 and §7.5 name. Their
//// **field order** is not something either document fixes, so it is the one
//// thing here that has to be reconciled against the deployed Minswap V2 CBOR
//// before this script is parameterised at a real `venue_order_skh`.

use adapter/utils as adapter_utils
use aiken/collection/list
use cardano/address.{Credential, Script}
use cardano/assets
use cardano/transaction.{InlineDatum, Input, Output, ValidityRange}
use constants
use daken/pairs as daken_pairs
use daken/tokens
use daken/types.{TupleAsset} as daken_types
use protocol/utils as protocol_utils
use types.{
  AdapterRedeemer, Declaration, Delivered, MarketDatum, Pending, ProtocolDatum,
  Recovered, ScriptHash,
}
use utils

// ------------------------------------------------------------- venue datums

/// `SwapExactIn` only — §7.5 denies `PartialSwap` and every other arm, and a
/// single-constructor type is how that denial is expressed: any other step fails
/// to decode.
pub type VenueStep {
  SwapExactIn {
    a_to_b_direction: Bool,
    swap_amount: VenueSwapAmount,
    minimum_receive: Int,
    killable: Bool,
  }
}

/// The venue's `SwapAmountOption`. Its other constructor spends whatever the
/// order holds less a deduction, which would put `sold` outside this adapter's
/// reach, so a single constructor is how §7.5 denies it: any other fails to
/// decode. Decoded from live preprod orders — 311 of 400 carry
/// `Constr(0, [Constr(0, [amount]), ..])` here — and it is the shape the
/// monorepo's own Minswap V2 composer writes.
pub type VenueSwapAmount {
  SpecificAmount { amount: Int }
}

/// The venue order, reduced to §7.5's rows. `receiver`/`refund_receiver` and
/// their datum hashes are what §7.5 names; a datum hash of `None` is the only
/// admissible value, so modelling them as `Option` both matches the table and
/// rejects an inline-datum receiver.
/// The venue writes an asset as a record, not as a tuple. Decoded from a real
/// preprod order: `Constr(0, [policy_id, asset_name])`.
pub type VenueAsset {
  policy_id: ByteArray,
  asset_name: ByteArray,
}

/// The venue's `ExtraOrderDatum`. `NoExtraDatum` is `Constr(0, [])`, which is not
/// what `Option<ByteArray>` decodes — `None` there is `Constr(1, [])` — so an
/// `Option` could never read a real order.
pub type VenueExtraDatum {
  NoExtraDatum
  ExtraDatumHash { hash: ByteArray }
  ExtraInlineDatum { datum: Data }
}

/// The venue's `OrderAuthorizationMethod`. It is **not** Aiken's `Credential`:
/// index 1 there is a *spend* of the named script, and this protocol's `cancel`
/// is withdraw-only, so encoding it as `Credential::Script` named a cancel path
/// no transaction could ever take. Index 2 is the withdrawal form.
pub type VenueCanceller {
  ByKey { hash: ByteArray }
  BySpend { hash: ByteArray }
  ByWithdraw { hash: ByteArray }
  ByMint { hash: ByteArray }
}

pub type VenueOrderDatum {
  canceller: VenueCanceller,
  refund_receiver: address.Address,
  refund_datum: VenueExtraDatum,
  receiver: address.Address,
  receiver_datum: VenueExtraDatum,
  lp_asset: VenueAsset,
  step: VenueStep,
  max_batcher_fee: Int,
  expiry_setting_opt: Option<(Int, Int)>,
}

/// The venue pool, reduced to the rows 05-02 §1.1 reads: the asset pair, the
/// reserves — from the **datum**, never from the UTxO's value — and the LP asset.
/// `trading_fee_numerator` is over `basis_point`; §7.4.2 requires `achievable` to
/// be net of the venue's own fee, so the curve cannot be evaluated without it.
/// Decoded from the live preprod ADA/fUSDM pool. Ten fields, and **no** LP asset:
/// the LP token is the single token of `venue_pool_nft_policy` the pool UTxO
/// holds, which is where `lp_asset` now comes from. The fee is per direction —
/// the venue charges it on the asset being sold — so there is no one
/// `trading_fee_numerator`.
///
/// The fields this adapter does not read are `Data`: their shapes are the venue's
/// business and naming a type for them would bind us to a version of it.
pub type VenuePoolDatum {
  pool_batching_stake_credential: Data,
  asset_a: VenueAsset,
  asset_b: VenueAsset,
  total_liquidity: Data,
  reserve_a: Int,
  reserve_b: Int,
  base_fee_a_numerator: Int,
  base_fee_b_numerator: Int,
  fee_sharing_numerator_opt: Data,
  allow_dynamic_fee: Data,
}

// -------------------------------------------------------------- the curve

/// §2.19 `achievable(venue_ref, sold)` — what the venue's own constant-product
/// curve returns for `sold`, net of its fee.
pub fn achievable(
  reserve_in: Int,
  reserve_out: Int,
  sold: Int,
  trading_fee_numerator: Int,
) -> Int {
  let paid =
    sold * ( constants.basis_point - trading_fee_numerator ) / constants.basis_point
  reserve_out * paid / ( reserve_in + paid )
}

/// §2.20 `market_floor` — the least payout the trader's own slippage tolerance
/// admits, on the reserves **as the reference input holds them**.
pub fn market_floor(achievable_now: Int, max_slippage: Int) -> Int {
  achievable_now * ( constants.basis_point - max_slippage ) / constants.basis_point
}

/// The upper bound of §4.1 and §4.2, which is evaluated **cumulatively** over the
/// declarations sharing one venue reference input.
pub fn fill_ceiling(achievable_now: Int, fillability_margin: Int) -> Int {
  achievable_now * ( constants.basis_point - fillability_margin ) / constants.basis_point
}

// -------------------------------------------------------------- the withdraw

/// The authen policy mints two assets into every pool: the pool's identity NFT,
/// named `"MSP"` on every pool alike, and that pool's own LP token, named for its
/// asset pair. A venue order names the **LP token**, so the NFT is what proves the
/// reference input is a genuine pool and the LP token is what the order points at.
/// Both were read off two live preprod pools.
const venue_pool_nft_name = "MSP"

pub fn withdraw(
  protocol_nft: TupleAsset,
  venue_order_skh: ScriptHash,
  venue_pool_skh: ScriptHash,
  venue_pool_nft_policy: ByteArray,
  own_skh: ScriptHash,
  AdapterRedeemer { declarations, protocol_config_ref_idx, market_ref_idx }: AdapterRedeemer,
  inputs: List<Input>,
  reference_inputs: List<Input>,
  outputs: List<Output>,
  validity_range: ValidityRange,
) -> Bool {
  let (_tx_start, tx_end) = protocol_utils.tx_bounds(validity_range)
  let ProtocolDatum {
    loan_skh,
    config_pool_skh,
    order_skh,
    position_skh,
    cancel_skh,
    adapters,
    ..
  } =
    protocol_utils.registry_ref(
      reference_inputs,
      protocol_config_ref_idx,
      protocol_nft,
    )
  expect adapter_utils.distinct_keys(declarations)
  // 01-validator §3 — one core action accepts one route kind, so the redeemer is
  // homogeneous. Branching on the head and pinning the rest to the same
  // constructor is what makes `market_ref_idx` determinate: §5 rule 11 sets it
  // on `Pending` and `-1` on the two consume routes.
  when declarations is {
    [] -> fail @"declarations must not be empty"
    [head, ..] ->
      when head.route is {
        Pending { .. } -> {
          expect adapter_utils.permits_create(adapters, own_skh)
          let market =
            adapter_utils.market_ref(
              reference_inputs,
              market_ref_idx,
              config_pool_skh,
            )
          // The accumulator has to be **consumed**. A binding nothing reads is
          // lazy, so the optimiser deletes it: with `let _reserves` the fold
          // never ran and this arm validated nothing at all — editing
          // `creates_claim` left `aiken build` emitting byte-identical code.
          let reserves =
            list.foldl(
              declarations,
              [],
              fn(declaration: Declaration, state: Pairs<Int, (Int, Int)>) {
                creates_claim(
                  declaration,
                  state,
                  venue_order_skh,
                  venue_pool_skh,
                  venue_pool_nft_policy,
                  loan_skh,
                  cancel_skh,
                  order_skh,
                  position_skh,
                  market,
                  tx_end,
                  inputs,
                  reference_inputs,
                  outputs,
                )
              },
            )
          // One entry per venue reference input the declarations touched, and
          // forcing its spine is what forces every check inside the fold.
          (list.length(reserves) > 0)?
        }
        Delivered { .. } -> {
          expect market_ref_idx == -1
          expect adapter_utils.permits_recover(adapters, own_skh)
          list.all(
            declarations,
            fn(declaration: Declaration) {
              delivers_payout(declaration, loan_skh, inputs)
            },
          )?
        }
        Recovered { .. } -> {
          expect market_ref_idx == -1
          expect adapter_utils.permits_recover(adapters, own_skh)
          list.all(
            declarations,
            fn(declaration: Declaration) {
              recovers_refund(declaration, loan_skh, inputs)
            },
          )?
        }
      }
  }
}

// ------------------------------------------------- obligation 1 — create

/// 05-02 §1.1 — the venue order at `venue_out_idx` satisfies §7.5 in full, the
/// declared `market_floor` is the value the reference input's reserves give, and
/// `floor` clears §4's upper bound on those reserves as this declaration's
/// predecessors leave them. Returns the reserves this declaration leaves behind.
fn creates_claim(
  Declaration { loan_owner_nft_name, route }: Declaration,
  state: Pairs<Int, (Int, Int)>,
  venue_order_skh: ScriptHash,
  venue_pool_skh: ScriptHash,
  venue_pool_nft_policy: ByteArray,
  loan_skh: ScriptHash,
  cancel_skh: ScriptHash,
  order_skh: ScriptHash,
  position_skh: ScriptHash,
  market: MarketDatum,
  tx_end: Int,
  inputs: List<Input>,
  reference_inputs: List<Input>,
  outputs: List<Output>,
) -> Pairs<Int, (Int, Int)> {
  expect Pending {
    asset,
    floor,
    market_floor: declared_market_floor,
    binding_nft,
    expiry,
    slippage_src_idx,
    venue_ref_idx,
    venue_out_idx,
    stake_credential,
  } = route

  // ---- the venue pool: identity, then the pair and the reserves from its datum
  let Input {
    output: Output {
      address: pool_address,
      value: pool_value,
      datum: pool_datum,
      ..
    },
    ..
  } = utils.input_at(reference_inputs, venue_ref_idx)
  expect utils.at_script(pool_address, venue_pool_skh)
  let venue_assets = utils.tokens_of(pool_value, venue_pool_nft_policy)
  expect list.has(venue_assets, (venue_pool_nft_name, 1))
  expect [(lp_name, _lp_qty)] =
    list.filter(venue_assets, fn((name, _qty)) { name != venue_pool_nft_name })
  expect InlineDatum(raw_pool) = pool_datum
  expect VenuePoolDatum {
    asset_a,
    asset_b,
    reserve_a,
    reserve_b,
    base_fee_a_numerator,
    base_fee_b_numerator,
    ..
  }: VenuePoolDatum = raw_pool
  let lp_asset =
    VenueAsset { policy_id: venue_pool_nft_policy, asset_name: lp_name }
  // The pool datum's pair equals `(asset_sold, claim.asset)`; the claim pays out
  // one leg, so the other is what was sold.
  let (asset_sold, a_to_b) =
    if asset == (asset_b.policy_id, asset_b.asset_name) {
      ((asset_a.policy_id, asset_a.asset_name), True)
    } else {
      expect asset == (asset_a.policy_id, asset_a.asset_name)
      ((asset_b.policy_id, asset_b.asset_name), False)
    }
  // The venue takes its fee out of what is sold, so the numerator is the sold
  // leg's, not one rate for the pool.
  let trading_fee_numerator =
    if a_to_b {
      base_fee_a_numerator
    } else {
      base_fee_b_numerator
    }

  // ---- the venue order
  let venue_out = utils.output_at(outputs, venue_out_idx)
  expect InlineDatum(raw_order) = venue_out.datum
  expect VenueOrderDatum {
    canceller,
    refund_receiver,
    refund_datum,
    receiver,
    receiver_datum,
    lp_asset: order_lp_asset,
    step,
    max_batcher_fee,
    expiry_setting_opt,
  }: VenueOrderDatum = raw_order
  expect SwapExactIn {
    a_to_b_direction,
    swap_amount,
    minimum_receive,
    killable,
  } = step

  // `sold` is read off the order's own value, which §7.5 pins in both legs.
  let sold_is_ada = tokens.is_ada(asset_sold)
  let sold =
    if sold_is_ada {
      assets.lovelace_of(venue_out.value) - market.venue_fee_budget
    } else {
      assets.quantity_of(venue_out.value, asset_sold.1st, asset_sold.2nd)
    }
  let expected_tokens =
    if sold_is_ada {
      assets.from_asset(binding_nft.1st, binding_nft.2nd, 1)
    } else {
      assets.from_asset(asset_sold.1st, asset_sold.2nd, sold)
        |> assets.add(binding_nft.1st, binding_nft.2nd, 1)
    }
  let expected_lovelace =
    market.venue_fee_budget + if sold_is_ada {
      sold
    } else {
      0
    }

  // ---- the two floor terms
  let (existing, rest) = daken_pairs.extract(state, venue_ref_idx)
  let (current_a, current_b) =
    when existing is {
      Some(reserves) -> reserves
      None -> (reserve_a, reserve_b)
    }
  let max_slippage =
    adapter_utils.max_slippage_at(
      inputs,
      outputs,
      slippage_src_idx,
      order_skh,
      position_skh,
    )
  let pristine_achievable =
    if a_to_b {
      achievable(reserve_a, reserve_b, sold, trading_fee_numerator)
    } else {
      achievable(reserve_b, reserve_a, sold, trading_fee_numerator)
    }
  let cumulative_achievable =
    if a_to_b {
      achievable(current_a, current_b, sold, trading_fee_numerator)
    } else {
      achievable(current_b, current_a, sold, trading_fee_numerator)
    }

  expect and {
      // ------------------------------------------------------------------- §7.5
      utils.at_script(venue_out.address, venue_order_skh)?,
      (sold > 0)?,
      (assets.without_lovelace(venue_out.value) == expected_tokens)?,
      (assets.lovelace_of(venue_out.value) == expected_lovelace)?,
      (order_lp_asset == lp_asset)?,
      (max_batcher_fee <= market.venue_fee_budget - market.max_cancel_fee - constants.min_ada - market.rollback_tip)?,
      (receiver == adapter_utils.claim_receiver(loan_skh, stake_credential))?,
      (receiver_datum == NoExtraDatum)?,
      (refund_receiver == receiver)?,
      (refund_datum == NoExtraDatum)?,
      // Never `loan_skh`'s withdrawal: the canceller must be one no third party
      // can satisfy, and §4.3's last row is the only escape a claim that neither
      // filled nor was cancelled has.
      (canceller == ByWithdraw { hash: cancel_skh })?,
      (a_to_b_direction == a_to_b)?,
      (swap_amount == SpecificAmount { amount: sold })?,
      (minimum_receive == floor)?,
      killable?,
      // An equality, not a range: at one lovelace nobody would run the venue's
      // expired-order cancel, and the executor has already banked `execution_tip`.
      (expiry_setting_opt == Some((expiry, market.max_cancel_fee)))?,
      // ------------------------------------------------- 05-02 §1.3, obligation 3
      (binding_nft == adapter_utils.binding_nft_of(
        loan_skh,
        loan_owner_nft_name,
      ))?,
      // -------------------------------------- obligation 1's expiry window, §7.4.4
      (expiry - tx_end >= market.min_claim_duration)?,
      (expiry - tx_end <= market.max_claim_duration)?,
      // ------------------------------------------------------------ §2.20 and §4
      (declared_market_floor == market_floor(pristine_achievable, max_slippage))?,
      (floor <= fill_ceiling(cumulative_achievable, market.fillability_margin))?,
    }

  // §7.4.7 — the next declaration sharing this reference input sees the reserves
  // this one leaves. Proving each against the same pre-trade reserves would let
  // a batch of `N` orders each claim depth only the first of them has.
  let next =
    if a_to_b {
      (current_a + sold, current_b - cumulative_achievable)
    } else {
      (current_a - cumulative_achievable, current_b + sold)
    }
  [Pair(venue_ref_idx, next), ..rest]
}

// ------------------------------------------------ obligations 4 and 5

/// 05-02 §1.5 — the payout input is at `Script(loan_skh)` with no datum, located
/// by `binding_nft`, and `amount == net(payout_in_value, asset)`.
fn delivers_payout(
  Declaration { loan_owner_nft_name, route }: Declaration,
  loan_skh: ScriptHash,
  inputs: List<Input>,
) -> Bool {
  expect Delivered { asset, amount, binding_nft } = route
  // 01-validator §4.4 — reached from a claim, so the payout input and its
  // `binding_nft` are named.
  expect Some(bound_nft) = binding_nft
  let payout_in = adapter_utils.bound_input_for(inputs, loan_skh, bound_nft)
  and {
    (bound_nft == adapter_utils.binding_nft_of(loan_skh, loan_owner_nft_name))?,
    (utils.net(payout_in.value, asset) == amount)?,
  }
}

/// 05-02 §1.4 — the refund input is the returned UTxO itself; `venue_ref_idx` is
/// absent because that UTxO is the proof. `asset` is the leg the claim was
/// **selling**, which the core pins against `claim.direction`.
fn recovers_refund(
  Declaration { loan_owner_nft_name, route }: Declaration,
  loan_skh: ScriptHash,
  inputs: List<Input>,
) -> Bool {
  expect Recovered { asset, amount, binding_nft } = route
  let refund_in = adapter_utils.bound_input_for(inputs, loan_skh, binding_nft)
  and {
    (binding_nft == adapter_utils.binding_nft_of(loan_skh, loan_owner_nft_name))?,
    (utils.net(refund_in.value, asset) == amount)?,
  }
}

// ---------------------------------------------------------------------- tests

/// One row per curve reading. `reserve_in`/`reserve_out` are the oriented
/// reserves the pool datum gives.
type CurveCase {
  label: ByteArray,
  reserve_in: Int,
  reserve_out: Int,
  sold: Int,
  fee: Int,
  expected: Int,
}

test achievable_is_net_of_the_venue_fee() {
  let cases =
    [
      CurveCase {
        label: "fee-free constant product",
        reserve_in: 1000000,
        reserve_out: 1000000,
        sold: 1000,
        fee: 0,
        expected: 999,
      },
      CurveCase {
        label: "30 bp fee costs the trader",
        reserve_in: 1000000,
        reserve_out: 1000000,
        sold: 1000,
        fee: 30,
        expected: 996,
      },
      CurveCase {
        label: "a thin pool pays much less",
        reserve_in: 10000,
        reserve_out: 10000,
        sold: 1000,
        fee: 30,
        expected: 906,
      },
      CurveCase {
        label: "an unbalanced pool prices the scarce leg up",
        reserve_in: 1000000,
        reserve_out: 2000000,
        sold: 1000,
        fee: 30,
        expected: 1992,
      },
    ]
  list.all(
    cases,
    fn(
      CurveCase { label: _label, reserve_in, reserve_out, sold, fee, expected },
    ) {
      achievable(reserve_in, reserve_out, sold, fee) == expected
    },
  )
}

/// One row per tolerance. `market_floor` and `fill_ceiling` are the same shape
/// applied to different margins — §2.20 and §4's upper bound.
type MarginCase {
  label: ByteArray,
  achievable_now: Int,
  margin: Int,
  expected_floor: Int,
  expected_ceiling: Int,
}

test margins_floor_toward_the_protocol() {
  let cases =
    [
      MarginCase {
        label: "no tolerance at all",
        achievable_now: 1000,
        margin: 0,
        expected_floor: 1000,
        expected_ceiling: 1000,
      },
      MarginCase {
        label: "the default 50 bp fillability margin",
        achievable_now: 1000000,
        margin: 50,
        expected_floor: 995000,
        expected_ceiling: 995000,
      },
      MarginCase {
        label: "the default 300 bp slippage cap",
        achievable_now: 1000000,
        margin: 300,
        expected_floor: 970000,
        expected_ceiling: 970000,
      },
      MarginCase {
        label: "the division floors, never rounds",
        achievable_now: 7,
        margin: 50,
        expected_floor: 6,
        expected_ceiling: 6,
      },
    ]
  list.all(
    cases,
    fn(
      MarginCase {
        label: _label,
        achievable_now,
        margin,
        expected_floor,
        expected_ceiling,
      },
    ) {
      and {
        market_floor(achievable_now, margin) == expected_floor,
        fill_ceiling(achievable_now, margin) == expected_ceiling,
      }
    },
  )
}

/// §7.4.7 — the ceiling is cumulative while §2.20's `market_floor` is not. Two
/// declarations sharing one reference input see different depth, which is why a
/// shared `venue_ref_idx` admits at most one in practice.
test the_second_declaration_sees_shallower_depth() {
  let first = achievable(1000000, 1000000, 100000, 30)
  let second = achievable(1000000 + 100000, 1000000 - first, 100000, 30)
  and {
    first > second,
    // and the pristine reading, which `market_floor` uses, does not move
    achievable(1000000, 1000000, 100000, 30) == first,
  }
}
