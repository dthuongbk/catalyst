//// Unit tests for `utils.ak`.
////
//// They live outside that module rather than beside it, which departs from this
//// repository's own habit — the ninety-four tests that came before are inline in
//// the module each one exercises. The reason is that the live registry pins every
//// validator hash to the bytes of its own source, so no file under `lib/` that a
//// validator compiles from may change while that registry is in use. A new module
//// costs nothing on chain: `aiken` strips tests from the blueprint, and these
//// reach only what `utils.ak` already exports.

use aiken/collection/list
use aiken/primitive/bytearray
use cardano/address.{Address, Inline, Script, VerificationKey}
use cardano/assets.{Value}
use cardano/transaction.{Input, NoDatum, Output, OutputReference}
use constants
use daken/types.{TupleAsset}
use utils


const t_pid = "pid_one"

const t_pid_two = "pid_two"

/// `nft_name_len` bytes wide, which is what `blake2b_224` gives.
const t_base = #"33333333333333333333333333333333333333333333333333333333"

const t_ada = (#"", #"")

const t_token = (t_pid, "tok")

const t_skh = "script_hash"

type BoolCase {
  name: ByteArray,
  got: Bool,
  want: Bool,
}

fn all_of(cases: List<BoolCase>) -> Bool {
  when cases is {
    [] -> True
    [BoolCase { got, want, .. }, ..rest] -> and {
        (got == want)?,
        all_of(rest),
      }
  }
}

type NetCase {
  name: ByteArray,
  value: Value,
  asset: TupleAsset,
  want: Int,
}

/// §2 item 2. The lovelace case is the whole point of this function: an output
/// obliged to carry `min_ada` and carrying nothing more nets **zero**, so a
/// margin, a deposit or a payout measured through `utils.net` is never satisfied by
/// the structural minimum the ledger already demands.
test net_strips_min_ada_from_the_lovelace_leg_only() {
  let cases =
    [
      NetCase {
        name: "lovelace above min_ada",
        value: assets.from_lovelace(constants.min_ada + 7),
        asset: t_ada,
        want: 7,
      },
      NetCase {
        name: "lovelace at min_ada nets nothing",
        value: assets.from_lovelace(constants.min_ada),
        asset: t_ada,
        want: 0,
      },
      // Not clamped. §7.2.18's sums are differences of `utils.net`, so a floor here
      // would hide an underfunded output instead of failing it.
      NetCase {
        name: "lovelace below min_ada goes negative",
        value: assets.from_lovelace(constants.min_ada - 1),
        asset: t_ada,
        want: -1,
      },
      NetCase {
        name: "a token leg keeps its whole quantity",
        value: assets.from_asset(t_pid, "tok", 42)
          |> assets.merge(assets.from_lovelace(constants.min_ada)),
        asset: t_token,
        want: 42,
      },
      NetCase {
        name: "an absent token is zero, not negative",
        value: assets.from_lovelace(constants.min_ada),
        asset: t_token,
        want: 0,
      },
    ]
  list.all(
    cases,
    fn(NetCase { value, asset, want, .. }) { (utils.net(value, asset) == want)? },
  )
}

/// §5 rule 14 — the length equality is half the test, so a name that merely
/// ends in the suffix does not pass for one. Without it a 31-byte name whose
/// last three bytes happen to read `OWN` would stand in for an owner ticket.
test suffixed_nft_names_are_recognised_by_length_and_suffix() {
  let owned = utils.suffixed(t_base, constants.owner_nft_suffix)
  let cases =
    [
      BoolCase {
        name: "the derived name",
        got: utils.is_suffixed_nft(owned, constants.owner_nft_suffix),
        want: True,
      },
      BoolCase {
        name: "the bare base carries no suffix",
        got: utils.is_suffixed_nft(t_base, constants.owner_nft_suffix),
        want: False,
      },
      BoolCase {
        name: "another suffix of the same width",
        got: utils.is_suffixed_nft(owned, constants.binding_nft_suffix),
        want: False,
      },
      BoolCase {
        name: "the right suffix at the wrong width",
        got: utils.is_suffixed_nft(
          bytearray.concat(
            bytearray.take(t_base, 20),
            constants.owner_nft_suffix,
          ),
          constants.owner_nft_suffix,
        ),
        want: False,
      },
    ]
  all_of(cases)
}

/// `utils.suffixed` truncates to `nft_name_len` before it concatenates, which makes it
/// idempotent on the base: an `OrderOwnerNFT` name re-derived from an already
/// utils.suffixed one gives the same token back. A `Closing` arm derives names this
/// way, and without the truncation it would look up a token nobody minted.
test suffixed_truncates_to_nft_name_len() {
  let owned = utils.suffixed(t_base, constants.owner_nft_suffix)
  and {
    (bytearray.length(owned) == constants.nft_name_len + 3)?,
    (utils.suffixed(owned, constants.owner_nft_suffix) == owned)?,
    (utils.suffixed(t_base, constants.remain_nft_suffix) != owned)?,
  }
}

/// §5 rule 10 — an arm states its contribution to one policy and the total is
/// checked against it, so a policy the arm says nothing about must come back as
/// the empty list and compare equal to the `[]` the arm declares. `utils.tokens_of`
/// carries the same weight under both names.
test tokens_of_selects_one_policy_and_gives_nothing_for_the_rest() {
  let v =
    assets.from_lovelace(constants.min_ada)
      |> assets.merge(assets.from_asset(t_pid, "tok", 3))
      |> assets.merge(assets.from_asset(t_pid, "other", 1))
      |> assets.merge(assets.from_asset(t_pid_two, "tok", 9))
  and {
    (utils.tokens_of(v, t_pid) == [("other", 1), ("tok", 3)])?,
    (utils.tokens_of(v, t_pid_two) == [("tok", 9)])?,
    (utils.tokens_of(v, "absent") == [])?,
    (utils.mint_of(v, t_pid_two) == [("tok", 9)])?,
    (utils.mint_of(v, "absent") == [])?,
  }
}

/// §7.2 item 18's positive whitelist. Every pool output is checked this way
/// rather than by naming what may not be there: a market can gain an
/// `alt_supply_token` later, and an exclusion list written today would not know
/// about it, while a whitelist rejects anything it was not told to admit.
test holds_only_admits_the_whitelist_and_nothing_else() {
  let bag =
    assets.from_lovelace(constants.min_ada)
      |> assets.merge(assets.from_asset(t_pid, "tok", 1))
  let with_junk = bag |> assets.merge(assets.from_asset(t_pid_two, "junk", 1))
  let cases =
    [
      BoolCase {
        name: "exactly the whitelist",
        got: utils.holds_only(bag, [t_ada, t_token]),
        want: True,
      },
      BoolCase {
        name: "a whitelist wider than the bag",
        got: utils.holds_only(bag, [t_ada, t_token, (t_pid_two, "junk")]),
        want: True,
      },
      BoolCase {
        name: "one asset outside it",
        got: utils.holds_only(with_junk, [t_ada, t_token]),
        want: False,
      },
      BoolCase {
        name: "lovelace left off the whitelist",
        got: utils.holds_only(bag, [t_token]),
        want: False,
      },
      BoolCase {
        name: "an empty bag holds only anything",
        got: utils.holds_only(assets.zero, []),
        want: True,
      },
    ]
  all_of(cases)
}

/// §5 rule 8 — the stake credential is pinned too, not only the payment one.
/// Two addresses at the same script with different stake credentials are
/// different addresses on chain and pay their rewards to different places, so an
/// arm that checked the payment credential alone would let an output be
/// redirected while still passing for the script's own.
test script_address_matches_pins_both_credentials() {
  let stake = Some(Inline(Script("stake_skh")))
  let pinned = Address { payment_credential: Script(t_skh), stake_credential: stake }
  let bare = Address { payment_credential: Script(t_skh), stake_credential: None }
  let elsewhere =
    Address {
      payment_credential: Script(t_skh),
      stake_credential: Some(Inline(Script("other_stake"))),
    }
  let wallet =
    Address { payment_credential: VerificationKey(t_skh), stake_credential: stake }
  let cases =
    [
      BoolCase {
        name: "both credentials agree",
        got: utils.script_address_matches(pinned, t_skh, stake),
        want: True,
      },
      BoolCase {
        name: "no stake credential where one is required",
        got: utils.script_address_matches(bare, t_skh, stake),
        want: False,
      },
      BoolCase {
        name: "a different stake credential",
        got: utils.script_address_matches(elsewhere, t_skh, stake),
        want: False,
      },
      BoolCase {
        name: "the same hash as a verification key",
        got: utils.script_address_matches(wallet, t_skh, stake),
        want: False,
      },
      BoolCase {
        name: "another script",
        got: utils.script_address_matches(pinned, "other_skh", stake),
        want: False,
      },
      // `utils.at_script` is the loose form, for the arms that constrain the script
      // and leave the stake credential to whoever built the transaction.
      BoolCase {
        name: "utils.at_script ignores the stake credential",
        got: utils.at_script(elsewhere, t_skh),
        want: True,
      },
      BoolCase {
        name: "utils.at_script still rejects a verification key",
        got: utils.at_script(wallet, t_skh),
        want: False,
      },
    ]
  all_of(cases)
}

fn t_out(tag: ByteArray) -> Output {
  Output {
    address: Address {
      payment_credential: Script(tag),
      stake_credential: None,
    },
    value: assets.from_lovelace(constants.min_ada),
    datum: NoDatum,
    reference_script: None,
  }
}

/// §5 rule 13 — every index in a redeemer is read through `flist.at`, which
/// fails out of range. Reading one as absent is what the rule bars: an arm that
/// treated a missing output as "nothing to check" would pass on a transaction
/// that simply left it out.
test indexed_reads_are_positional() {
  let outputs = [t_out("a"), t_out("b"), t_out("c")]
  let inputs =
    list.indexed_map(
      outputs,
      fn(i, output) { Input { output_reference: OutputReference("tx", i), output } },
    )
  and {
    utils.at_script(utils.output_at(outputs, 0).address, "a")?,
    utils.at_script(utils.output_at(outputs, 2).address, "c")?,
    utils.at_script(utils.input_at(inputs, 1).output.address, "b")?,
    (utils.input_at(inputs, 2).output_reference == OutputReference("tx", 2))?,
  }
}

test output_at_fails_past_the_end() fail {
  utils.at_script(utils.output_at([t_out("a")], 1).address, "a")
}

test input_at_fails_on_a_negative_index() fail {
  let inputs =
    [Input { output_reference: OutputReference("tx", 0), output: t_out("a") }]
  utils.at_script(utils.input_at(inputs, -1).output.address, "a")
}
