import { Constr, Data } from "@lucid-evolution/lucid";

export type Registry = {
  poolSkh: string;
  loanSkh: string;
  loanRepaySkh: string;
  loanCloseSkh: string;
  configPoolSkh: string;
  orderSkh: string;
  positionSkh: string;
  cancelSkh: string;
  adminNft: [string, string];
  oracleSkh: string;
};

/// `ProtocolDatum`, in the field order `lib/types.ak` declares — datums decode
/// positionally, so the order is the wire format.
///
/// `CreateProtocol` writes it: eight script hashes, an empty whitelist,
/// `admin_nft`, `oracle_skh`, `oracle_ready_at = 0`, `pending_oracle = None` and
/// the two extra loan hosts — biz spec §14 item 3a.
///
/// `loan_repay_skh` and `loan_close_skh` are **appended**, so a datum written
/// before they existed still decodes for every reader that does not need them.
export function genesisDatum(r: Registry): string {
  return Data.to(
    new Constr(0, [
      r.poolSkh,
      r.loanSkh,
      r.configPoolSkh,
      r.orderSkh,
      r.positionSkh,
      r.cancelSkh,
      new Map(),                                  // adapters: empty
      // `TupleAsset` is `dataType: "list"` in the blueprint — two flat items, not
      // a constructor. Encoding it as `Constr(0, ..)` produced a registry whose
      // `admin_nft` no validator could decode, and nothing caught it because
      // `CreateProtocol` cannot run at genesis.
      [r.adminNft[0], r.adminNft[1]],
      r.oracleSkh,
      0n,                                         // oracle_ready_at
      new Constr(1, []),                          // pending_oracle: None
      r.loanRepaySkh,
      r.loanCloseSkh,
    ]),
  );
}
