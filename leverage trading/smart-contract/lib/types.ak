//// Datums and redeemers.
////
//// Every datum here is an append-only extension of its deployed counterpart:
//// the first eight fields of `PoolDatum`, four of `LoanDatum`, fourteen of
//// `MarketDatum`, seven of `OrderDatum` and three of `PositionDatum` keep their
//// deployed name, type **and position**. Datums decode positionally, so a field
//// inserted anywhere but the end silently rebinds every field after it — biz
//// spec §5 rule 13a.

use cardano/address.{Address, StakeCredential}
use cardano/assets.{AssetName}
use daken/prational.{PRational}
use daken/types.{Basis, TupleAsset} as daken_types

pub type ScriptHash =
  ByteArray

pub type LiquidationThreshold =
  Basis

// ---------------------------------------------------------------- datums

pub type OrderDatum {
  long_token: TupleAsset,
  short_token: TupleAsset,
  short_amount: Int,
  open_limit_price: PRational,
  take_profit_price: PRational,
  min_liquidation_threshold: LiquidationThreshold,
  min_execution_amount: Int,
  max_slippage: Basis,
  allowed_adapters: List<ScriptHash>,
  is_market: Bool,
  market_nft_name: AssetName,
  beneficiary: Address,
  fee_reserve: Int,
}

pub type PositionDatum {
  long_token: TupleAsset,
  take_profit_price: PRational,
  min_execution_amount: Int,
  max_slippage: Basis,
  beneficiary: Address,
}

pub type ClaimDirection {
  Opening
  Closing
}

pub type Claim {
  adapter_skh: ScriptHash,
  binding_nft: TupleAsset,
  direction: ClaimDirection,
  asset: TupleAsset,
  sold: Int,
  floor: Int,
  expiry: Int,
}

pub type LoanDatum {
  owner_nft: Option<TupleAsset>,
  token: TupleAsset,
  loan_amount: Int,
  initial_interest_index: Int,
  claim: Option<Claim>,
}

pub type PoolDatum {
  total_supply: Int,
  circulating_dtoken: Int,
  total_borrow: Int,
  borrow_apy: Basis,
  undistributed_fee: Int,
  interest_index: Int,
  interest_time: Int,
  alt_supply_tokens_rate: List<PRational>,
  bad_debt: Int,
}

pub type RemainDatum {
  owner_nft: TupleAsset,
  beneficiary: Address,
  collector_reward: Int,
}

pub type MarketDatum {
  collaterals: Pairs<TupleAsset, (LiquidationThreshold, Bool)>,
  base_rate: Basis,
  power_base: Basis,
  util_cap: Basis,
  withdrawal_fee: Int,
  loan_fee_rate: Basis,
  loan_origination_fee_rate: Basis,
  loan_origination_fee_min_amount: Int,
  fee_address: Address,
  supply_token: TupleAsset,
  alt_supply_tokens: Pairs<TupleAsset, Bool>,
  min_tx_amount: Int,
  liquidator_reward_cap: Basis,
  collector_reward: Int,
  min_liquidator_reward: Int,
  rollback_tip: Int,
  execution_tip: Int,
  max_cancel_fee: Int,
  venue_fee_budget: Int,
  max_slippage_cap: Basis,
  min_claim_duration: Int,
  max_claim_duration: Int,
  max_index_staleness: Int,
  claim_safety_margin: Basis,
  fillability_margin: Basis,
}

pub type AdapterEntry {
  may_create: Bool,
  may_recover: Bool,
}

pub type ProtocolDatum {
  pool_skh: ByteArray,
  loan_skh: ByteArray,
  config_pool_skh: ByteArray,
  order_skh: ByteArray,
  position_skh: ByteArray,
  cancel_skh: ByteArray,
  adapters: Pairs<ScriptHash, AdapterEntry>,
  admin_nft: TupleAsset,
  oracle_skh: ByteArray,
  oracle_ready_at: Int,
  pending_oracle: Option<ByteArray>,
  loan_repay_skh: ByteArray,
  loan_close_skh: ByteArray,
}

// ------------------------------------------------------------- order book

pub type OrderRedeemer {
  order_actions: List<OrderAction>,
  protocol_config_ref_idx: Int,
}

pub type SingleExecuteOrderIndexer {
  order_in_idx: Int,
  order_out_idx: Int,
  position_out_idx: Int,
  loan_out_idx: Int,
  seed_utxo_idx: Int,
  /// The asynchronous arm; `-1` on the synchronous one, which pays no tip.
  execution_tip_idx: Int,
}

pub type OrderAction {
  CreateOrderIndexer {
    seed_utxo_idx: Int,
    order_out_idx: Int,
    market_ref_idx: Int,
  }
  ExecuteOrderIndexer {
    orders: List<SingleExecuteOrderIndexer>,
    market_ref_idx: Int,
    pool_in_idx: Int,
    pool_out_idx: Int,
    adapter_skh: ScriptHash,
  }
  /// `order_out_idx == -1` is the cancel arm — biz spec §9.3.
  ModifyOrderIndexer {
    order_in_idx: Int,
    order_owner_in_idx: Int,
    order_out_idx: Int,
    owner_release_out_idx: Int,
    market_ref_idx: Int,
  }
}

pub type SingleClosePositionIndexer {
  position_in_idx: Int,
  /// `-1` where a loan action authorises instead.
  position_owner_in_idx: Int,
  loan_in_idx: Int,
  loan_out_idx: Int,
  position_out_idx: Int,
}

pub type PositionRedeemer {
  position_actions: List<PositionAction>,
  protocol_config_ref_idx: Int,
}

pub type PositionAction {
  CreatePosition { seed_utxo_idx: Int, position_out_idx: Int }
  /// Index 1 is reserved: the deployed contract assigns `TakeProfit` there, which
  /// this version drops — biz spec §5 rule 15.
  ReservedTakeProfit
  ModifyPosition {
    position_in_idx: Int,
    position_owner_in_idx: Int,
    position_out_idx: Int,
  }
  ClosePosition { positions: List<SingleClosePositionIndexer> }
  BurnOwnerNFT { owner_in_idx: Int, owner_nft_name: AssetName }
}

// ---------------------------------------------------------------- lending

pub type PoolRedeemer {
  pool_actions: List<PoolAction>,
  protocol_config_ref_idx: Int,
}

pub type PoolAction {
  /// The pool side of any transaction that lends or is repaid. `loans` equals, as a
  /// set, the `LoanOwnerNFT` names this redeemer's actions name on this arm; every
  /// sum of biz spec §7.2.18 is over that list.
  PoolFlow {
    pool_in_idx: Int,
    pool_out_idx: Int,
    market_ref_idx: Int,
    loans: List<AssetName>,
  }
  RebalanceAlt {
    pool_in_idx: Int,
    pool_out_idx: Int,
    admin_in_idx: Int,
    market_ref_idx: Int,
  }
  TopupWithdraw {
    pool_in_idx: Int,
    pool_out_idx: Int,
    market_ref_idx: Int,
    /// `-1` unless withdrawing with `withdrawal_fee > 0`.
    fee_out_idx: Int,
  }
  WithdrawFee {
    pool_in_idx: Int,
    pool_out_idx: Int,
    admin_in_idx: Int,
    market_ref_idx: Int,
    fee_out_idx: Int,
  }
}

/// §7.6. No `order_in_idx`: there is no order. The market is read from the
/// `LoanNFT`'s own name, which §7.2.12 already ties to it.
pub type SingleOpenDirectIndexer {
  loan_out_idx: Int,
  position_out_idx: Int,
  seed_utxo_idx: Int,
}

pub type SingleOpenLoanIndexer {
  order_in_idx: Int,
  loan_out_idx: Int,
  position_out_idx: Int,
  seed_utxo_idx: Int,
}

pub type SingleSettleClaimIndexer {
  loan_in_idx: Int,
  loan_out_idx: Int,
  payout_in_idx: Int,
  /// Where the payout UTxO's own minADA goes, on **both** legs; never `-1` — biz
  /// spec §8.2.13.
  tip_out_idx: Int,
}

pub type SingleRepayLoanIndexer {
  position_in_idx: Int,
  position_owner_in_idx: Int,
  loan_in_idx: Int,
  loan_out_idx: Int,
  position_out_idx: Int,
  payout_in_idx: Int,
  trader_out_idx: Int,
  remain_out_idx: Int,
  /// The repay-on-fill arm; `-1` otherwise — biz spec §10.2.2.
  tip_out_idx: Int,
}

/// No owner input index: the sweep presents no owner NFT and requires no
/// signature — biz spec §13.3.2.
pub type SingleCollectRemainIndexer {
  remain_in_idx: Int,
  beneficiary_out_idx: Int,
}

pub type LoanRedeemer {
  loan_actions: List<LoanAction>,
  protocol_config_ref_idx: Int,
}

pub type LoanAction {
  OpenLoan {
    loans: List<SingleOpenLoanIndexer>,
    market_ref_idx: Int,
    pool_in_idx: Int,
    pool_out_idx: Int,
    adapter_skh: ScriptHash,
  }
  SettleClaim {
    claims: List<SingleSettleClaimIndexer>,
    market_ref_idx: Int,
    adapter_skh: ScriptHash,
  }
  RepayLoan {
    loans: List<SingleRepayLoanIndexer>,
    market_ref_idx: Int,
    pool_ref_idx: Int,
    pool_in_idx: Int,
    pool_out_idx: Int,
    adapter_skh: ScriptHash,
  }
  Liquidate {
    loan_in_idx: Int,
    position_in_idx: Int,
    payout_in_idx: Int,
    pool_in_idx: Int,
    pool_out_idx: Int,
    liquidator_out_idx: Int,
    remain_out_idx: Int,
    tip_out_idx: Int,
    market_ref_idx: Int,
    /// Declared, not inferred, so a collapsed position stays liquidatable — biz
    /// spec §2.13.
    reward: Int,
  }
  Rollback {
    loan_in_idx: Int,
    position_in_idx: Int,
    refund_in_idx: Int,
    loan_out_idx: Int,
    position_out_idx: Int,
    pool_in_idx: Int,
    pool_out_idx: Int,
    remain_out_idx: Int,
    /// Restore `short_amount`; `-1` where the order is gone — biz spec §12.3.
    order_in_idx: Int,
    order_out_idx: Int,
    tip_out_idx: Int,
    market_ref_idx: Int,
    adapter_skh: ScriptHash,
  }
  CollectRemain {
    remains: List<SingleCollectRemainIndexer>,
    collector_out_idx: Int,
  }
  /// §7.6 — a loan opened against collateral the borrower deposits, with no
  /// order and no venue.
  ///
  /// A loan's terms are its own: how much is borrowed, what backs it, whether it
  /// is healthy, what it accrues. None of an order's parameters bears on any of
  /// them — `margin`, `short_amount` and `open_limit_price` describe how a
  /// position was *acquired*, and §7.2 needs them only because the venue buys the
  /// collateral on the borrower's behalf. A borrower who already holds the
  /// collateral has nothing to buy and nothing to wait for, so there is no order
  /// for them to wait in.
  OpenDirect {
    loans: List<SingleOpenDirectIndexer>,
    market_ref_idx: Int,
    pool_out_idx: Int,
  }
}

/// A `Spend` of `config_pool_skh`, not a withdrawal — biz spec §15.
/// `UpdateMarketParam` is first, so it keeps the `Constr(0, ..)` encoding it had
/// as a plain record — biz spec §15 is unchanged on the wire.
pub type MarketParamRedeemer {
  UpdateMarketParam {
    market_in_idx: Int,
    admin_in_idx: Int,
    market_out_idx: Int,
    protocol_config_ref_idx: Int,
  }
  CreateMarket {
    seed_utxo_idx: Int,
    admin_in_idx: Int,
    market_out_idx: Int,
    pool_out_idx: Int,
    protocol_config_ref_idx: Int,
  }
}

// -------------------------------------------------------- protocol config

pub type ProtocolConfigRedeemer {
  CreateProtocol {
    seed_utxo_idx: Int,
    admin_in_idx: Int,
    protocol_out_idx: Int,
  }
  UpdateAdapters {
    protocol_in_idx: Int,
    admin_in_idx: Int,
    protocol_out_idx: Int,
  }
  RotateAdmin {
    protocol_in_idx: Int,
    admin_in_idx: Int,
    new_admin_in_idx: Int,
    protocol_out_idx: Int,
  }
  AnnounceOracle {
    protocol_in_idx: Int,
    admin_in_idx: Int,
    protocol_out_idx: Int,
  }
  RotateOracle {
    protocol_in_idx: Int,
    admin_in_idx: Int,
    protocol_out_idx: Int,
  }
}

// ---------------------------------------------------------------- adapter

pub type CollateralRoute {
  Delivered { asset: TupleAsset, amount: Int, binding_nft: Option<TupleAsset> }
  Pending {
    asset: TupleAsset,
    floor: Int,
    /// The reserve-side term of §4.1's `max`: the adapter proves it, the core
    /// evaluates the whole `max` from it.
    market_floor: Int,
    binding_nft: TupleAsset,
    expiry: Int,
    /// The input holding `max_slippage` — the order on a fill, the position on an
    /// asynchronous close.
    slippage_src_idx: Int,
    venue_ref_idx: Int,
    venue_out_idx: Int,
    /// The stake credential the venue must pay back to. The adapter constrains the
    /// venue order's `receiver` from it; the core proves it against `claim_source`,
    /// which the adapter cannot reach — biz spec §7.5.
    stake_credential: Option<StakeCredential>,
  }
  Recovered { asset: TupleAsset, amount: Int, binding_nft: TupleAsset }
}

pub type Declaration {
  loan_owner_nft_name: AssetName,
  route: CollateralRoute,
}

pub type AdapterRedeemer {
  declarations: List<Declaration>,
  protocol_config_ref_idx: Int,
  market_ref_idx: Int,
}
