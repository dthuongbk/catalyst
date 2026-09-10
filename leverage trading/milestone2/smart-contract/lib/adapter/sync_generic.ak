//// `adapter/sync_generic` — 05-01-sync-generic.md. One adapter for every venue
//// that settles inside our own transaction.
////
//// It implements obligation 1 alone, and its whole job is to declare what it
//// reads from the outputs the core action names. The limit price, the health
//// gate, the thresholds, the fee arithmetic and the payout destinations are the
//// core's.

use adapter/utils as adapter_utils
use aiken/collection/list
use cardano/assets.{Value}
use cardano/transaction.{Input, Output, ValidityRange}
use daken/types.{TupleAsset} as daken_types
use protocol/utils as protocol_utils
use types.{AdapterRedeemer, Declaration, Delivered, ProtocolDatum, ScriptHash}
use utils

pub fn withdraw(
  protocol_nft: TupleAsset,
  own_skh: ScriptHash,
  AdapterRedeemer { declarations, protocol_config_ref_idx, market_ref_idx }: AdapterRedeemer,
  reference_inputs: List<Input>,
  outputs: List<Output>,
  mint: Value,
  validity_range: ValidityRange,
) -> Bool {
  // §5 rule 1. Read into names and compared: a discarded binding is lazy, so
  // the bounds would never be evaluated and the rule would not hold.
  let (tx_start, tx_end) = protocol_utils.tx_bounds(validity_range)
  expect (tx_end >= tx_start)?
  // 05-01 §2.3 — `loan_skh` is resolved from the `protocol_config` reference
  // input at `protocol_config_ref_idx`; §5 rule 2 bars `-1`.
  let ProtocolDatum { loan_skh, adapters, .. } =
    protocol_utils.registry_ref(
      reference_inputs,
      protocol_config_ref_idx,
      protocol_nft,
    )
  and {
    // §5 rule 11 — this adapter carries no venue order and so reads no market
    // field; §5 rule 11a requires the index it does carry to say so.
    (market_ref_idx == -1)?,
    (declarations != [])?,
    adapter_utils.permits_create(adapters, own_skh)?,
    // 05-01 §2.2 — the second half of `binding_nft == None`: a synchronous fill
    // leaves no claim behind, so nothing may bind one.
    (!adapter_utils.mints_binding_nft(mint, loan_skh))?,
    adapter_utils.distinct_keys(declarations)?,
    list.all(
      declarations,
      fn(declaration: Declaration) {
        declares_delivered(declaration, loan_skh, outputs, mint)
      },
    )?,
  }
}

fn declares_delivered(
  Declaration { loan_owner_nft_name, route }: Declaration,
  loan_skh: ScriptHash,
  outputs: List<Output>,
  mint: Value,
) -> Bool {
  // 05-01 §2.1 — `Pending` and `Recovered` are rejected outright.
  expect Delivered { asset, amount, binding_nft } = route
  // §5 rule 11 — located by the declaration's own key, not by `loan_out_idx`.
  let loan_out =
    adapter_utils.loan_output_for(outputs, loan_skh, loan_owner_nft_name)
  and {
    (binding_nft == None)?,
    // 05-01 §2.3 — the declaration is matched to the loan the core action names
    // by the mint of its `LoanOwnerNFT`.
    (assets.quantity_of(mint, loan_skh, loan_owner_nft_name) == 1)?,
    // 05-01 §2.4 — `amount` of `asset` is present at that loan output, measured
    // with `net(..)`. §7.3.5 leaves the surplus above the core's own bound free.
    (utils.net(loan_out.value, asset) >= amount)?,
  }
}
