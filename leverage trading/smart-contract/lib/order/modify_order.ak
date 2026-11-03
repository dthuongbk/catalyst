//// Biz spec §9 — modify order. Two arms, selected by `order_out_idx`: §9.2 the
//// update, §9.3 the cancel.

use aiken/collection/list
use cardano/assets.{AssetName, Value}
use cardano/transaction.{Input, Output}
use constants
use daken/tokens
use order/utils as order_utils
use types.{MarketDatum, OrderDatum, ProtocolDatum, ScriptHash}
use utils

/// §9.2 — the update arm. Contributes nothing to `mint[order_skh]` (item 9).
pub fn validate_update(
  order_in: Input,
  order_out: Output,
  owner_in: Input,
  order_in_idx: Int,
  order_owner_in_idx: Int,
  owner_release_out_idx: Int,
  market_ref_idx: Int,
  outputs: List<Output>,
  mint: Value,
  protocol: ProtocolDatum,
  order_skh: ScriptHash,
  market: MarketDatum,
) -> Bool {
  expect market_ref_idx != -1
  let Input {
    output: Output { value: order_in_value, address: order_in_address, .. } as order_in_out,
    ..
  } = order_in
  // §9.2.1
  let (order_in_datum, order_nft_name, _) =
    order_utils.order_shape(order_in_out, order_skh)
  // §9.2.2
  let Input { output: Output { value: owner_in_value, .. }, .. } = owner_in
  let order_owner_nft_name =
    utils.suffixed(order_nft_name, constants.owner_nft_suffix)
  expect
    assets.quantity_of(owner_in_value, order_skh, order_owner_nft_name) == 1
  expect order_owner_in_idx != order_in_idx

  // §9.2.3, and the order shape of §9.2.1 on the output side.
  let (order_out_datum, order_out_nft_name, _) =
    order_utils.order_shape(order_out, order_skh)
  expect order_out_nft_name == order_nft_name
  let Output { address: order_out_address, value: order_out_value, .. } =
    order_out
  expect order_out_address == order_in_address

  // §9.2.5 — the four immutables, and `fee_reserve` rising only.
  expect order_out_datum.long_token == order_in_datum.long_token
  expect order_out_datum.short_token == order_in_datum.short_token
  expect order_out_datum.market_nft_name == order_in_datum.market_nft_name
  expect order_out_datum.beneficiary == order_in_datum.beneficiary
  let fee_reserve_in = order_in_datum.fee_reserve
  let fee_reserve_out = order_out_datum.fee_reserve
  expect fee_reserve_out >= fee_reserve_in

  // §9.2.4 — nothing moves but lovelace upward and `PositionOwnerNFT`s outward.
  let (released, unaccounted) =
    assets.reduce(
      order_in_value,
      ([], order_out_value),
      fn(pid, name, qty, (released, unaccounted)) {
        let out_qty = assets.quantity_of(unaccounted, pid, name)
        let unaccounted = assets.add(unaccounted, pid, name, -out_qty)
        if tokens.is_ada((pid, name)) {
          expect out_qty >= qty
          (released, unaccounted)
        } else if and {
          pid == protocol.position_skh,
          utils.is_suffixed_nft(name, constants.owner_nft_suffix),
        } {
          if out_qty == qty {
            (released, unaccounted)
          } else {
            expect out_qty == 0
            ([(name, qty), ..released], unaccounted)
          }
        } else {
          expect out_qty == qty
          (released, unaccounted)
        }
      },
    )
  expect assets.flatten(unaccounted) == []
  let in_lovelace = assets.lovelace_of(order_in_value)
  let out_lovelace = assets.lovelace_of(order_out_value)
  expect out_lovelace - in_lovelace >= fee_reserve_out - fee_reserve_in

  // §9.2.4's destination for a released owner NFT: an output outside every
  // protocol script, or a `BurnOwnerNFT` admitted under §13.3. §5 rule 11a puts
  // the index at `-1` where nothing is released.
  let release_value =
    if owner_release_out_idx == -1 {
      assets.zero
    } else {
      let Output { address, value, .. } =
        utils.output_at(outputs, owner_release_out_idx)
      expect order_utils.outside_protocol(address, protocol)
      value
    }
  expect or {
      released != [],
      owner_release_out_idx == -1,
    }
  expect
    list.all(
      released,
      fn((name, qty): (AssetName, Int)) {
        or {
          assets.quantity_of(release_value, protocol.position_skh, name) == qty,
          assets.quantity_of(mint, protocol.position_skh, name) == -qty,
        }
      },
    )

  // §9.2.6. `margin` is `net(order_in_value, short_token)` per §2.3; the output's
  // own short-token holding carries the first clause. The `<=` case is what keeps
  // §10.1.3's release buildable on a fully consumed order.
  let short_token = order_in_datum.short_token
  let margin =
    order_utils.order_net(order_in_value, short_token, fee_reserve_in)
  let net_short_out =
    order_utils.order_net(order_out_value, short_token, fee_reserve_out)
  let short_amount = order_out_datum.short_amount
  let only_release = and {
      released != [],
      out_lovelace == in_lovelace,
      fee_reserve_out == fee_reserve_in,
    }
  expect
    if only_release {
      net_short_out <= short_amount
    } else {
      net_short_out < short_amount
    }
  expect short_amount <= order_in_datum.short_amount
  let t = order_utils.threshold(market, order_in_datum.long_token)
  expect
    order_utils.within_leverage_cap(
      margin,
      short_amount,
      t,
      market.loan_origination_fee_rate,
    )?

  // §9.2.7 — re-checked against the market reference input.
  expect order_utils.valid_order_params(order_out_datum, market)

  // §9.2.10. `is_market` itself is mutable — item 8.
  or {
    !order_out_datum.is_market,
    order_in_datum.is_market,
    fee_reserve_out >= order_utils.async_fill_cost(
      market.venue_fee_budget,
      market.execution_tip,
    ),
  }?
}

/// §9.3 — the cancel arm. Returns the two names this action burns (item 2).
/// No validator check names the owner input: the ledger requires the
/// `OrderOwnerNFT` in an input for the burn to succeed, and that is the whole
/// authorisation (item 3).
pub fn validate_cancel(
  order_in: Input,
  order_owner_in_idx: Int,
  owner_release_out_idx: Int,
  market_ref_idx: Int,
  order_skh: ScriptHash,
  return: fn(AssetName, AssetName) -> result,
) -> result {
  let Input { output: order_in_out, .. } = order_in
  // §9.3.1 — without the singleton the burned name has no source.
  let (_order_in_datum, order_nft_name, _) =
    order_utils.order_shape(order_in_out, order_skh)
  // §5 rule 11a: items 3, 4 and 7 say these are absent, so they are checked so.
  expect order_owner_in_idx == -1
  expect owner_release_out_idx == -1
  expect market_ref_idx == -1
  return(
    order_nft_name,
    utils.suffixed(order_nft_name, constants.owner_nft_suffix),
  )
}
