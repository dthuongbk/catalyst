//// Biz spec §7 — execute order. §7.2 is common to both venue shapes; the route
//// the adapter declares selects §7.3 (synchronous) or §7.4 (asynchronous).
////
//// The floor interval of §7.4.2 and the health gate of §7.2.22 are the loan
//// script's: both rest on the oracle withdrawal and on `debt_at`, which live with
//// `LoanDatum`. What this arm proves about a claim is its shape, its identity, its
//// duration and its `sold` — every term an order holds.

use aiken/collection/list
use cardano/address.{Address, Script}
use cardano/assets.{AssetName, Value}
use cardano/transaction.{InlineDatum, Input, Output}
use constants
use daken/input_hash
use order/utils as order_utils
use types.{
  Claim, Declaration, Delivered, LoanDatum, MarketDatum, Opening, OrderDatum,
  Pending, PositionDatum, ProtocolDatum, Recovered, ScriptHash,
}
use utils

pub fn validate(
  order_in: Input,
  order_in_idx: Int,
  order_out: Output,
  position_out: Output,
  loan_out: Output,
  seed_utxo: Input,
  execution_tip_idx: Int,
  outputs: List<Output>,
  mint: Value,
  protocol: ProtocolDatum,
  order_skh: ScriptHash,
  adapter_skh: ScriptHash,
  declarations: List<Declaration>,
  market: MarketDatum,
  market_nft_name: AssetName,
  pool_out_interest_index: Int,
  tx_end: Int,
) -> Bool {
  let Input { output: order_in_out, .. } = order_in
  let Output { value: order_in_value, address: order_in_address, .. } =
    order_in_out
  // §7.2 item 1's `order_skh` shape, and §9.2.1's, are one test.
  let (order, _order_nft_name, order_in_stake) =
    order_utils.order_shape(order_in_out, order_skh)
  let OrderDatum {
    long_token,
    short_token,
    short_amount,
    open_limit_price,
    min_liquidation_threshold,
    min_execution_amount,
    allowed_adapters,
    is_market,
    market_nft_name: order_market_nft_name,
    fee_reserve,
    ..
  } = order

  // §7.2.1
  expect or {
      allowed_adapters == [],
      list.has(allowed_adapters, adapter_skh),
    }

  // §7.2.5's order half. The pool half is checked once per action.
  expect order_market_nft_name == market_nft_name

  // §7.2.9
  let t = order_utils.enabled_threshold(market, long_token)
  expect t >= min_liquidation_threshold

  // ---------------------------------------------------------- the loan output
  let Output {
    address: loan_out_address,
    value: loan_out_value,
    datum: loan_out_datum_raw,
    reference_script: loan_out_ref_script,
  } = loan_out
  // §7.2.21
  expect
    utils.script_address_matches(
      loan_out_address,
      protocol.loan_skh,
      order_in_stake,
    )
  expect loan_out_ref_script == None
  expect assets.lovelace_of(loan_out_value) >= constants.min_ada
  expect InlineDatum(loan_out_data) = loan_out_datum_raw
  expect LoanDatum {
    owner_nft,
    token,
    loan_amount,
    initial_interest_index,
    claim,
  }: LoanDatum = loan_out_data
  // §7.2.20
  expect token == short_token
  expect initial_interest_index == pool_out_interest_index
  expect Some((loan_owner_pid, loan_owner_nft_name)) = owner_nft
  expect loan_owner_pid == protocol.loan_skh
  // §7.2.12 — `LoanNFT.asset_name == MarketNFT.asset_name`, and the loan holds
  // exactly one token of its own policy on both arms: the binding NFT goes to the
  // venue order, never here.
  expect
    [(market_nft_name, 1)] == utils.tokens_of(loan_out_value, protocol.loan_skh)

  // ------------------------------------------------------ the position output
  let Output {
    address: position_out_address,
    value: position_out_value,
    datum: position_out_datum_raw,
    reference_script: position_out_ref_script,
  } = position_out
  // §7.2.21
  expect
    utils.script_address_matches(
      position_out_address,
      protocol.position_skh,
      order_in_stake,
    )
  expect position_out_ref_script == None
  expect assets.lovelace_of(position_out_value) >= constants.min_ada
  // §7.2.19's value clause
  expect [(position_nft_name, 1)] =
    utils.tokens_of(position_out_value, protocol.position_skh)
  expect
    [(loan_owner_nft_name, 1)] == utils.tokens_of(
      position_out_value,
      protocol.loan_skh,
    )
  expect
    utils.holds_only(
      position_out_value,
      [
        (assets.ada_policy_id, assets.ada_asset_name),
        (protocol.position_skh, position_nft_name),
        (protocol.loan_skh, loan_owner_nft_name),
      ],
    )
  // §7.2.10
  let seed_name = input_hash.blake2b_224(seed_utxo)
  expect position_nft_name == seed_name
  expect loan_owner_nft_name == seed_name
  // §7.2.11
  let position_owner_nft_name =
    utils.suffixed(position_nft_name, constants.owner_nft_suffix)
  // §7.2.19's datum clause — all five fields copied from `order_in_datum`.
  expect
    position_out_datum_raw == InlineDatum(
      PositionDatum {
        long_token,
        take_profit_price: order.take_profit_price,
        min_execution_amount,
        max_slippage: order.max_slippage,
        beneficiary: order.beneficiary,
      },
    )
  // §7.2.12's per-fill point checks. Exhaustiveness over `mint[loan_skh]` and
  // `mint[position_skh]` belongs to those scripts' own withdrawals.
  expect assets.quantity_of(mint, protocol.loan_skh, loan_owner_nft_name) == 1
  expect assets.quantity_of(mint, protocol.position_skh, position_nft_name) == 1
  expect
    assets.quantity_of(mint, protocol.position_skh, position_owner_nft_name) == 1

  // -------------------------------------------------------- the value it moves
  // §2.3, §2.4
  let margin = order_utils.order_net(order_in_value, short_token, fee_reserve)
  let tbv = order_utils.total_borrowed_value(short_amount, margin)
  // §2.6
  let nlp =
    order_utils.net_loan_proceeds(
      loan_amount,
      market.loan_origination_fee_rate,
      market.loan_origination_fee_min_amount,
    )
  // §7.2.6
  expect loan_amount >= market.min_tx_amount
  expect loan_amount <= tbv
  // §7.2.7
  expect
    order_utils.within_leverage_cap(
      margin,
      short_amount,
      t,
      market.loan_origination_fee_rate,
    )?

  let Output {
    address: order_out_address,
    value: order_out_value,
    datum: order_out_datum_raw,
    reference_script: order_out_ref_script,
  } = order_out
  // §7.2.21 — both credentials.
  expect order_out_address == order_in_address
  expect order_out_ref_script == None
  expect InlineDatum(order_out_data) = order_out_datum_raw
  expect order_out: OrderDatum = order_out_data
  let out_fee_reserve = order_out.fee_reserve
  // §7.2.16's lovelace clause.
  expect
    assets.lovelace_of(order_out_value) >= constants.min_ada + out_fee_reserve

  let (short_from_order_in, long_from_order_in, unaccounted) =
    assets.reduce(
      order_in_value,
      (0, 0, order_out_value),
      fn(pid, name, qty, (short_from_order_in, long_from_order_in, unaccounted)) {
        let a = (pid, name)
        let out_qty = assets.quantity_of(unaccounted, pid, name)
        let unaccounted = assets.add(unaccounted, pid, name, -out_qty)
        if pid == order_skh || pid == protocol.position_skh {
          // §7.2.15 — `deposit_qty` does not apply to these.
          expect out_qty == qty
          (short_from_order_in, long_from_order_in, unaccounted)
        } else {
          let in_net = order_utils.order_net_qty(a, qty, fee_reserve)
          let dq = order_utils.deposit_qty(in_net, loan_amount, tbv)
          // §7.2.16
          expect
            order_utils.order_net_qty(a, out_qty, out_fee_reserve) >= in_net - dq
          if a == short_token {
            (dq, long_from_order_in, unaccounted)
          } else if a == long_token {
            (short_from_order_in, dq, unaccounted)
          } else {
            // §7.2.17 — `net`, not the raw quantity.
            expect utils.net(loan_out_value, a) >= dq
            (short_from_order_in, long_from_order_in, unaccounted)
          }
        }
      },
    )
  // §7.2.14 — an equality over the multiset of entries.
  expect
    assets.flatten(unaccounted) == [
      (protocol.position_skh, position_owner_nft_name, 1),
    ]

  // §7.2.8
  expect or {
      short_amount == loan_amount + short_from_order_in,
      loan_amount + short_from_order_in >= min_execution_amount,
    }

  // ------------------------------------------------------------- the two arms
  expect Some(Declaration { route, .. }) =
    list.find(
      declarations,
      fn(Declaration { loan_owner_nft_name: key, .. }) {
        key == loan_owner_nft_name
      },
    )
  let expected_fee_reserve =
    when route is {
      Delivered { asset, amount, binding_nft } -> {
        // §7.3.1
        expect asset == long_token
        expect binding_nft == None
        // §7.3.2 — the surplus above this bound is unconstrained (item 5).
        expect utils.net(loan_out_value, long_token) >= amount
        expect
          amount >= long_from_order_in + order_utils.limit_floor(
            short_from_order_in,
            nlp,
            open_limit_price,
          )
        // §7.3.3
        expect claim == None
        // §7.3.4 — no tip is paid, so §7.2.13 debits no reserve.
        expect execution_tip_idx == -1
        fee_reserve
      }
      Pending {
        asset,
        floor,
        market_floor: _,
        binding_nft,
        expiry,
        slippage_src_idx,
        venue_ref_idx: _,
        venue_out_idx: _,
        stake_credential,
      } -> {
        // §7.4.1 — the core's half of §7.5's `receiver` split, and the tolerance
        // source pinned to this action's own order input. `market_floor` is taken
        // on trust per §4.1; the adapter proves it against the reserves.
        expect asset == long_token
        expect stake_credential == order_in_stake
        expect slippage_src_idx == order_in_idx
        // §7.4.3
        let binding_nft_name =
          utils.suffixed(loan_owner_nft_name, constants.binding_nft_suffix)
        expect binding_nft == (protocol.loan_skh, binding_nft_name)
        // §7.2.12's asynchronous addition.
        expect
          assets.quantity_of(mint, protocol.loan_skh, binding_nft_name) == 1
        // §7.4.4
        expect expiry - tx_end >= market.min_claim_duration
        expect expiry - tx_end <= market.max_claim_duration
        // §7.4.5 — field by field from the declaration, with no substitution.
        expect
          claim == Some(
            Claim {
              adapter_skh,
              binding_nft,
              direction: Opening,
              asset: long_token,
              sold: short_from_order_in + nlp,
              floor,
              expiry,
            },
          )
        // §7.4.6
        expect utils.net(loan_out_value, long_token) == long_from_order_in
        // §7.4.9 — this route is funded, not flagged. `is_market` used to gate it,
        // but the term it stood for is the one right below: an asynchronous fill
        // pays `execution_tip` and the two `min_ada` out of `fee_reserve`, and
        // §6.2.2.13 only forces a reserve on an order that declared itself a
        // market one. A limit order that did fund the reserve gives up nothing by
        // taking this route — §7.4.2's floor is `max(health, market, limit)`
        // (loan/open_loan.ak), so `open_limit_price` still bounds the payout.
        // §7.4.10
        let afc =
          order_utils.async_fill_cost(
            market.venue_fee_budget,
            market.execution_tip,
          )
        expect fee_reserve >= afc
        expect execution_tip_idx != -1
        let Output { value: tip_value, .. } =
          utils.output_at(outputs, execution_tip_idx)
        expect assets.lovelace_of(tip_value) == market.execution_tip
        fee_reserve - afc
      }
      // §7 places a claim or takes delivery. A returned one is §12's.
      Recovered { .. } -> fail @"execute: Recovered route"
    }

  // §7.2.13 — every other field byte-identical, `market_nft_name` and
  // `beneficiary` included.
  (order_out_datum_raw == InlineDatum(
    OrderDatum {
      ..order,
      short_amount: short_amount - loan_amount - short_from_order_in,
      fee_reserve: expected_fee_reserve,
    },
  ))?
}

/// §7.2.4 — every input at `Script(loan_skh)` or `Script(position_skh)` is named
/// by an action of the redeemer that owns it, which is what its own withdrawal
/// proves (§5 rule 16). This arm requires that withdrawal to be present, so a
/// fill cannot carry a loan or position input no script accounts for.
pub fn no_unaccounted_script_inputs(
  inputs: List<Input>,
  protocol: ProtocolDatum,
  has_loan_withdrawal: Bool,
  has_position_withdrawal: Bool,
) -> Bool {
  list.all(
    inputs,
    fn(
      Input {
        output: Output { address: Address { payment_credential, .. }, .. },
        ..
      },
    ) {
      if payment_credential == Script(protocol.loan_skh) {
        has_loan_withdrawal
      } else if payment_credential == Script(protocol.position_skh) {
        has_position_withdrawal
      } else {
        True
      }
    },
  )
}
