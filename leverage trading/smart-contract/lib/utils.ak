//// Helpers the whole contract set shares. Anything `daken` or the stdlib already
//// provides is used from there — `flist.at` for an indexed read that fails out of
//// range (biz spec §5 rule 13), `math.ceiling_div`, `tokens.contains_only_nft`,
//// `pairs.get_first`.

use aiken/collection/list
use aiken/primitive/bytearray
use cardano/address.{Address, Script, StakeCredential}
use cardano/assets.{AssetName, PolicyId, Value}
use cardano/transaction.{Input, Output}
use constants
use daken/flist
use daken/tokens
use daken/types.{TupleAsset}

/// `net(v, a)` — how much of `a` the UTxO holds **beyond** the minADA it must
/// carry. Where `a` is not lovelace this is the plain quantity; where it is, the
/// UTxO's own `min_ada` is stripped, so a token leg and a minADA are never
/// confused for one another. Biz spec §2 item 2.
pub fn net(v: Value, (pid, name): TupleAsset) -> Int {
  let qty = assets.quantity_of(v, pid, name)
  if tokens.is_ada((pid, name)) {
    qty - constants.min_ada
  } else {
    qty
  }
}

/// The output at `idx`, failing where `idx` is out of range — never read as
/// absent. Biz spec §5 rule 13.
pub fn output_at(outputs: List<Output>, idx: Int) -> Output {
  flist.at(outputs, idx)
}

pub fn input_at(inputs: List<Input>, idx: Int) -> Input {
  flist.at(inputs, idx)
}

/// Recognises an owner, binding or remain NFT: the name must be `nft_name_len`
/// bytes followed by the suffix, and the length equality is part of the test.
/// Biz spec §5 rule 14.
pub fn is_suffixed_nft(name: AssetName, suffix: ByteArray) -> Bool {
  and {
    bytearray.length(name) == constants.nft_name_len + bytearray.length(suffix),
    bytearray.drop(name, constants.nft_name_len) == suffix,
  }
}

/// The name that `base ++ suffix` gives, for deriving one NFT's name from
/// another's.
pub fn suffixed(base: AssetName, suffix: ByteArray) -> AssetName {
  bytearray.concat(bytearray.take(base, constants.nft_name_len), suffix)
}

/// Every token of `pid` in `v`, as `(name, quantity)`. Used for the exhaustive
/// per-policy comparisons of biz spec §5 rule 10 and the `tokens(v, skh) == [..]`
/// equalities.
pub fn tokens_of(v: Value, pid: PolicyId) -> List<(AssetName, Int)> {
  v
    |> assets.flatten
    |> list.filter_map(
        fn((p, name, q)) {
          if p == pid {
            Some((name, q))
          } else {
            None
          }
        },
      )
}

/// A script address, both credentials pinned. Biz spec §5 rule 8 requires the
/// stake credential too, not only the payment credential.
pub fn script_address_matches(
  addr: Address,
  skh: ByteArray,
  stake: Option<StakeCredential>,
) -> Bool {
  and {
    addr.payment_credential == Script(skh),
    addr.stake_credential == stake,
  }
}

/// `addr` is at `Script(skh)`, whatever its stake credential.
pub fn at_script(addr: Address, skh: ByteArray) -> Bool {
  addr.payment_credential == Script(skh)
}

/// Sums one policy's mint entries so an arm can state its contribution and have
/// the total checked against it — biz spec §5 rule 10. An arm that states nothing
/// about a policy contributes **zero**, and that zero is checked.
pub fn mint_of(mint: Value, pid: PolicyId) -> List<(AssetName, Int)> {
  tokens_of(mint, pid)
}

/// True where `v` holds nothing outside `allowed` — the positive whitelist form
/// biz spec §7.2 item 18 applies to every pool output.
pub fn holds_only(v: Value, allowed: List<TupleAsset>) -> Bool {
  v
    |> assets.flatten
    |> list.all(fn((pid, name, _q)) { list.has(allowed, (pid, name)) })
}
