//// Unit tests for `types.ak`.
////
//// They live outside that module rather than beside it, which departs from this
//// repository's own habit — the ninety-four tests that came before are inline in
//// the module each one exercises. The reason is that the live registry pins every
//// validator hash to the bytes of its own source, so no file under `lib/` that a
//// validator compiles from may change while that registry is in use. A new module
//// costs nothing on chain: `aiken` strips tests from the blueprint, and these
//// reach only what `types.ak` already exports.

use aiken/builtin
use aiken/collection/list
use cardano/address.{Address, Script}
use daken/prational.{PRational}
use daken/types.{TupleAsset} as daken_types
use types.{
  BurnOwnerNFT, Claim, ClosePosition, Closing, CreateMarket, CreatePosition,
  Delivered, LoanDatum, ModifyPosition, Opening, OrderDatum, Pending,
  PoolDatum, PositionAction, PositionDatum, Recovered, RemainDatum,
  ReservedTakeProfit, UpdateMarketParam,
}

//
// These pin the **wire format**, which is the one property of this module that
// can break silently. Every datum here decodes positionally, so a field inserted
// anywhere but the end rebinds every field after it — §5 rule 13a — and a
// constructor index that moves changes what a deployed redeemer means. Neither
// shows up as a type error, and neither shows up until a transaction is built
// against a live UTxO and rejected with nothing to say.

fn t_addr() -> Address {
  Address { payment_credential: Script("skh"), stake_credential: None }
}

fn t_asset() -> TupleAsset {
  ("policy", "name")
}

/// The arity of every datum, at the position each field holds today. A field
/// appended at the end raises the count and nothing else; a field inserted
/// anywhere else moves a value the deployed contract reads at a fixed index.
test datum_arities_are_the_deployed_ones() {
  let order: Data =
    OrderDatum {
      long_token: t_asset(),
      short_token: ("", ""),
      short_amount: 300_000_000,
      open_limit_price: PRational(4, 1),
      take_profit_price: PRational(0, 1),
      min_liquidation_threshold: 8000,
      min_execution_amount: 100_000_000,
      max_slippage: 300,
      allowed_adapters: [],
      is_market: True,
      market_nft_name: "market",
      beneficiary: t_addr(),
      fee_reserve: 19_500_000,
    }
  let position: Data =
    PositionDatum {
      long_token: t_asset(),
      take_profit_price: PRational(2, 1),
      min_execution_amount: 100_000_000,
      max_slippage: 300,
      beneficiary: t_addr(),
    }
  let loan: Data =
    LoanDatum {
      owner_nft: Some(t_asset()),
      token: ("", ""),
      loan_amount: 400_000_000,
      initial_interest_index: 1_000_000_000_000,
      claim: None,
    }
  let pool: Data =
    PoolDatum {
      total_supply: 1,
      circulating_dtoken: 2,
      total_borrow: 3,
      borrow_apy: 400,
      undistributed_fee: 4,
      interest_index: 1_000_000_000_000,
      interest_time: 5,
      alt_supply_tokens_rate: [],
      bad_debt: 0,
    }
  let remain: Data =
    RemainDatum {
      owner_nft: t_asset(),
      beneficiary: t_addr(),
      collector_reward: 1_200_000,
    }
  let claim: Data =
    Claim {
      adapter_skh: "adapter",
      binding_nft: t_asset(),
      direction: Opening,
      asset: t_asset(),
      sold: 1,
      floor: 2,
      expiry: 3,
    }
  let cases =
    [
      // The five §5 rule 13a names, with the counts that note gives:
      // eight of `PoolDatum`, four of `LoanDatum`, fourteen of `MarketDatum`,
      // seven of `OrderDatum` and three of `PositionDatum` are the *deployed*
      // prefixes; these are the full arities this version carries.
      ("OrderDatum", order, 13),
      ("PositionDatum", position, 5),
      ("LoanDatum", loan, 5),
      ("PoolDatum", pool, 9),
      ("RemainDatum", remain, 3),
      ("Claim", claim, 7),
    ]
  list.all(
    cases,
    fn((_label, datum, want): (ByteArray, Data, Int)) {
      let Pair(index, fields) = builtin.un_constr_data(datum)
      and {
        (index == 0)?,
        (list.length(fields) == want)?,
      }
    },
  )
}

/// The positions §5 rule 13a is about, spot-checked by value. `short_amount` is
/// the third field of an `OrderDatum` and `loan_amount` the third of a
/// `LoanDatum`; reading either one position out gives a number that parses fine
/// and means something else entirely.
test datum_fields_sit_where_the_deployed_contract_reads_them() {
  let order: Data =
    OrderDatum {
      long_token: t_asset(),
      short_token: ("", ""),
      short_amount: 300_000_000,
      open_limit_price: PRational(4, 1),
      take_profit_price: PRational(0, 1),
      min_liquidation_threshold: 8000,
      min_execution_amount: 100_000_000,
      max_slippage: 300,
      allowed_adapters: [],
      is_market: True,
      market_nft_name: "market",
      beneficiary: t_addr(),
      fee_reserve: 19_500_000,
    }
  let Pair(_index, fields) = builtin.un_constr_data(order)
  expect Some(short_amount) = list.at(fields, 2)
  expect Some(min_liquidation_threshold) = list.at(fields, 5)
  expect Some(fee_reserve) = list.at(fields, 12)
  and {
    (builtin.un_i_data(short_amount) == 300_000_000)?,
    (builtin.un_i_data(min_liquidation_threshold) == 8000)?,
    (builtin.un_i_data(fee_reserve) == 19_500_000)?,
  }
}

/// §5 rule 15 — index 1 is **reserved**. The deployed contract assigns
/// `TakeProfit` there and this version drops it, so the variant stays in place
/// as a placeholder: removing it would renumber `ModifyPosition`,
/// `ClosePosition` and `BurnOwnerNFT`, and a redeemer built against the
/// deployed encoding would then select the wrong arm rather than fail to decode.
test position_action_keeps_its_deployed_constructor_indices() {
  let cases =
    [
      (CreatePosition { seed_utxo_idx: 0, position_out_idx: 1 }, 0),
      (ReservedTakeProfit, 1),
      (
        ModifyPosition {
          position_in_idx: 0,
          position_owner_in_idx: 1,
          position_out_idx: 2,
        },
        2,
      ),
      (ClosePosition { positions: [] }, 3),
      (BurnOwnerNFT { owner_in_idx: 0, owner_nft_name: "name" }, 4),
    ]
  list.all(
    cases,
    fn((action, want): (PositionAction, Int)) {
      let data: Data = action
      let Pair(index, _fields) = builtin.un_constr_data(data)
      (index == want)?
    },
  )
}

/// §15 is unchanged on the wire: `UpdateMarketParam` is declared first so it
/// keeps the `Constr(0, ..)` encoding it had when `MarketParamRedeemer` was a
/// plain record and `CreateMarket` did not exist.
test market_param_redeemer_keeps_update_at_index_zero() {
  let update: Data =
    UpdateMarketParam {
      market_in_idx: 0,
      admin_in_idx: 1,
      market_out_idx: 2,
      protocol_config_ref_idx: 3,
    }
  let create: Data =
    CreateMarket {
      seed_utxo_idx: 0,
      admin_in_idx: 1,
      market_out_idx: 2,
      pool_out_idx: 3,
      protocol_config_ref_idx: 4,
    }
  let Pair(update_index, update_fields) = builtin.un_constr_data(update)
  let Pair(create_index, _) = builtin.un_constr_data(create)
  and {
    (update_index == 0)?,
    (list.length(update_fields) == 4)?,
    (create_index == 1)?,
  }
}

/// The order of `CollateralRoute` and `ClaimDirection`, for the same reason: an
/// adapter's declaration and a loan's `Claim` both travel as `Constr` tags.
test route_and_direction_indices_are_the_deployed_ones() {
  let delivered: Data =
    Delivered { asset: t_asset(), amount: 1, binding_nft: None }
  let pending: Data =
    Pending {
      asset: t_asset(),
      floor: 1,
      market_floor: 1,
      binding_nft: t_asset(),
      expiry: 2,
      slippage_src_idx: 0,
      venue_ref_idx: 0,
      venue_out_idx: 0,
      stake_credential: None,
    }
  let recovered: Data =
    Recovered { asset: t_asset(), amount: 1, binding_nft: t_asset() }
  let opening: Data = Opening
  let closing: Data = Closing
  and {
    (builtin.un_constr_data(delivered).1st == 0)?,
    (builtin.un_constr_data(pending).1st == 1)?,
    (builtin.un_constr_data(recovered).1st == 2)?,
    (builtin.un_constr_data(opening).1st == 0)?,
    (builtin.un_constr_data(closing).1st == 1)?,
  }
}

/// DEPLOYMENT.md §6 item 2 — an Aiken 2-tuple is a CBOR **list**, not a
/// constructor. `TupleAsset` is `[policy, name]`, and getting this wrong makes a
/// datum no validator can decode with nothing catching it before submission.
test tuple_asset_is_a_cbor_list() {
  let asset: Data = t_asset()
  let items = builtin.un_list_data(asset)
  and {
    (list.length(items) == 2)?,
    (list.at(items, 0) == Some(builtin.b_data("policy")))?,
    (list.at(items, 1) == Some(builtin.b_data("name")))?,
  }
}

test tuple_asset_is_not_a_constructor() fail {
  let asset: Data = t_asset()
  builtin.un_constr_data(asset).1st == 0
}

/// The corollary: `Option<(Int, Int)>` is `Constr(0, [[a, b]])` — a constructor
/// wrapping a list, not a constructor wrapping two integers.
test option_of_a_tuple_wraps_a_list() {
  let wrapped: Data = Some((7, 9))
  let Pair(index, fields) = builtin.un_constr_data(wrapped)
  expect Some(inner) = list.at(fields, 0)
  and {
    (index == 0)?,
    (list.length(fields) == 1)?,
    (list.length(builtin.un_list_data(inner)) == 2)?,
  }
}

/// `Bool` travels as a constructor with no fields, `False` at 0 and `True` at 1
/// — the encoding `releases/src/market.ts` mirrors when it writes a market datum.
test bool_is_a_constructor_with_false_first() {
  let f: Data = False
  let t: Data = True
  and {
    (builtin.un_constr_data(f).1st == 0)?,
    (builtin.un_constr_data(t).1st == 1)?,
  }
}
