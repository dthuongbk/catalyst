// Environment constants — biz spec §1.1. Same on mainnet, preview and preprod.

pub const basis_point = 10000

pub const year_in_ms = 31536000000

/// minADA every script UTxO carries.
pub const min_ada = 5000000

/// `tx_end - tx_start` may not exceed this, in milliseconds.
pub const max_validity_window = 360000

/// `blake2b_224` output width, in bytes. An owner, binding or remain NFT is
/// recognised only when its name is this long plus its suffix — §5 rule 14.
pub const nft_name_len = 28

pub const owner_nft_suffix = "OWN"

pub const binding_nft_suffix = "BND"

pub const remain_nft_suffix = "RMN"

/// Keeps the AdminNFT's name out of the ProtocolNFT's: both are minted by
/// `nft_mint` from the same seed UTxO in the same transaction, so without this
/// they would be one asset in quantity 2 — §5 rule 3.
pub const admin_nft_suffix = "ADM"

/// Every pool starts here; every `debt_now` ratio is relative to it.
pub const initial_interest_index = 1000000000000

/// Minimum announce-to-effect delay for an oracle rotation, in milliseconds.
pub const oracle_rotation_delay = 86400000

/// `util_rate` is expressed in percent before it becomes `borrow_apy`'s exponent.
pub const percentage = 100
