//// Biz spec §13.3 — anyone may sweep a residual parked by §10.2.2, §11 or
//// §12.3, and is paid `collector_reward`. The residual itself goes to the
//// beneficiary the parking transaction recorded.
////
//// The rest of §13.2 is **not** re-checked here: the `RemainNFT` is the proof,
//// minted by the parking transaction that enforced it. Re-checking it would be
//// unbuildable — §13.2.2 compares `collector_reward` against the market and
//// §13.2.1 against the parking transaction's `position_in`, while this arm reads
//// no `market_param` and that position is long spent.

use aiken/collection/list
use aiken/primitive/bytearray
use cardano/assets.{AssetName, Value}
use cardano/transaction.{InlineDatum, Input, Output}
use constants
use daken/tokens
use loan/utils.{Contribution, Registry} as loan_utils
use types.{RemainDatum, ScriptHash, SingleCollectRemainIndexer}
use utils

/// One `CollectRemain` action. `collector_out_idx` is shared by every sweep the
/// action names, so the reward is summed once and compared once — §5 rule 12.
pub fn validate(
  registry: Registry,
  outputs: List<Output>,
  inputs: List<Input>,
  remains: List<SingleCollectRemainIndexer>,
  collector_out_idx: Int,
) -> Contribution {
  let (mint, total_reward) =
    list.foldl(
      remains,
      ([], 0),
      fn(
        SingleCollectRemainIndexer { remain_in_idx, beneficiary_out_idx },
        (mint, total_reward),
      ) {
        let (remain_nft_name, reward) =
          sweep(
            registry,
            utils.input_at(inputs, remain_in_idx),
            utils.output_at(outputs, beneficiary_out_idx),
          )
        ([(remain_nft_name, -1), ..mint], total_reward + reward)
      },
    )
  // §13.3.4 — the reward reaches `collector_out_idx` in lovelace only, taken
  // from the datum and never from a `market_param` reference input
  expect
    (utils.output_at(outputs, collector_out_idx).value == assets.from_lovelace(
      total_reward,
    ))?
  // §13.3.6 — `remain_in_idx` values are pairwise distinct across `remains`
  expect distinct(list.map(remains, fn(r) { r.remain_in_idx }))?
  // §13.3.5
  Contribution { loan_mint: mint, opened_proceeds: 0, retired: 0, shortfall: 0 }
}

/// §13.3 items 1, 3 and 4 for one residual. Returns the `RemainNFT`'s name and
/// the reward its datum stamped.
fn sweep(
  registry: Registry,
  remain_in: Input,
  beneficiary_out: Output,
) -> (AssetName, Int) {
  let Registry { loan_skh, position_skh, .. } = registry
  let Input { output: Output { address, value, datum, .. }, .. } = remain_in
  // §13.3.1
  expect utils.at_script(address, loan_skh)
  let remain_nft_name = tokens.get_nft_name(value, loan_skh)
  expect utils.is_suffixed_nft(remain_nft_name, constants.remain_nft_suffix)?
  expect InlineDatum(datum) = datum
  expect RemainDatum { owner_nft, beneficiary, collector_reward }: RemainDatum =
    datum
  // `owner_nft` is derivable from the `RemainNFT` name
  expect
    owner_nft == (
      position_skh,
      bytearray.concat(
        bytearray.take(remain_nft_name, constants.nft_name_len),
        constants.owner_nft_suffix,
      ),
    )
  // §13.3.2 — no owner NFT is presented and no signature is required; the output
  // address is fixed by `remain_in_datum`
  expect and {
      // §13.3.3
      (beneficiary_out.address == beneficiary)?,
      carries_residual(value, beneficiary_out.value, loan_skh, remain_nft_name)?,
      // §13.3.4
      (assets.lovelace_of(beneficiary_out.value) >= assets.lovelace_of(value) - collector_reward)?,
    }
  (remain_nft_name, collector_reward)
}

/// §13.3.3 — every non-lovelace asset of `remain_in_value` other than the
/// `RemainNFT` reaches the beneficiary's output.
fn carries_residual(
  remain_in_value: Value,
  beneficiary_out_value: Value,
  loan_skh: ScriptHash,
  remain_nft_name: AssetName,
) -> Bool {
  remain_in_value
    |> assets.without_lovelace
    |> assets.reduce(
        True,
        fn(pid, name, qty, ok) {
          if (pid, name) == (loan_skh, remain_nft_name) {
            ok
          } else {
            and {
              ok,
              assets.quantity_of(beneficiary_out_value, pid, name) >= qty,
            }
          }
        },
      )
}

fn distinct(idxs: List<Int>) -> Bool {
  when idxs is {
    [] -> True
    [x, ..xs] -> and {
        !list.has(xs, x),
        distinct(xs),
      }
  }
}

// -------------------------------------------------------------------- tests

test owner_nft_is_derived_from_the_remain_nft_name() {
  // §13.3.1 — `owner_nft == (position_skh, take(RemainNFT.asset_name,
  // nft_name_len) ++ owner_nft_suffix)`. The `RemainNFT`'s own name is the
  // `PositionNFT`'s plus `remain_nft_suffix`, so the two suffixes swap.
  let position_nft_name =
    #"00112233445566778899aabbccddeeff00112233445566778899aabb"
  let tests =
    [
      (constants.remain_nft_suffix, constants.owner_nft_suffix, True),
      // a name of the wrong length is not a remain NFT at all — §5 rule 14
      (#"", constants.owner_nft_suffix, False),
    ]
  list.all(
    tests,
    fn((remain_suffix, owner_suffix, expected)) {
      let remain_nft_name = bytearray.concat(position_nft_name, remain_suffix)
      and {
        utils.is_suffixed_nft(remain_nft_name, constants.remain_nft_suffix) == expected,
        bytearray.concat(
          bytearray.take(remain_nft_name, constants.nft_name_len),
          owner_suffix,
        ) == utils.suffixed(position_nft_name, owner_suffix),
      }
    },
  )
}

test beneficiary_keeps_everything_but_the_reward() {
  // §13.3.4 — a floor, so the parking arm's surplus lovelace still reaches the
  // beneficiary, and exactly `collector_reward` may be held back.
  let reward = 3_000_000
  let tests =
    [
      // (remain_lovelace, beneficiary_lovelace, ok)
      (constants.min_ada + reward, constants.min_ada, True),
      (constants.min_ada + reward, constants.min_ada - 1, False),
      (constants.min_ada + reward, constants.min_ada + reward, True),
    ]
  list.all(
    tests,
    fn((remain_lovelace, beneficiary_lovelace, expected)) {
      beneficiary_lovelace >= remain_lovelace - reward == expected
    },
  )
}

test remain_in_idx_values_are_pairwise_distinct() {
  let tests = [([0, 1, 2], True), ([0, 1, 0], False), ([], True), ([4], True)]
  list.all(tests, fn((idxs, expected)) { distinct(idxs) == expected })
}
