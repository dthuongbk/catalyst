/// The pool's own integer arithmetic, replicated so an off-chain build produces
/// the datum the validator recomputes. Every division truncates the way Aiken's
/// `Int` division does, and `ceilingDiv` matches `daken/math.ceiling_div`.
export const BASIS_POINT = 10_000n;
export const PERCENTAGE = 100n;
export const YEAR_IN_MS = 31_536_000_000n;

export const ceilingDiv = (a: bigint, b: bigint): bigint => (a + b - 1n) / b;

/// Plutus `divideInteger` rounds **down**; a BigInt `/` rounds toward zero. The
/// two agree on non-negative operands and differ by one everywhere else, which is
/// enough to make a pool datum the validator recomputes reject the one written
/// here — §18's `dtoken_qty` is negative on every withdrawal.
export const floorDiv = (a: bigint, b: bigint): bigint => {
  const q = a / b;
  return a % b !== 0n && (a < 0n) !== (b < 0n) ? q - 1n : q;
};

const gcd = (a: bigint, b: bigint): bigint => (b === 0n ? a : gcd(b, a % b));

/// `pool/utils.index_at`.
export function indexAt(inIndex: bigint, inApy: bigint, inTime: bigint, t: bigint): bigint {
  return t > inTime
    ? inIndex + (inIndex * inApy * (t - inTime)) / (BASIS_POINT * YEAR_IN_MS)
    : inIndex;
}

/// `pool/utils.borrow_apy`. `rational.new` reduces by the gcd, and `rational.pow`
/// raises the reduced pair, so the numbers stay exact and large.
export function borrowApy(
  baseRate: bigint, powerBase: bigint, totalSupply: bigint, totalBorrow: bigint,
): bigint {
  if (totalSupply <= 0n) return baseRate;
  // util_rate rounded to the nearest whole percent, ties away from zero
  const un = totalBorrow * PERCENTAGE;
  const ud = totalSupply;
  const g0 = gcd(un, ud) || 1n;
  const n = un / g0, d = ud / g0;
  const floorPart = n / d;
  const rem = n % d;
  const exp = rem * 2n >= d ? floorPart + 1n : floorPart;
  const g1 = gcd(powerBase, BASIS_POINT) || 1n;
  const bn = powerBase / g1, bd = BASIS_POINT / g1;
  const num = bn ** exp, den = bd ** exp;
  return baseRate + (num * PERCENTAGE) / den;
}

/// `loan/utils.debt_at`.
export const debtAt = (debt: bigint, apy: bigint, interestTime: bigint, t: bigint): bigint =>
  debt + ceilingDiv(debt * apy * (t - interestTime), BASIS_POINT * YEAR_IN_MS);

/// `loan/utils.health_floor`, with `p` the collateral's price in supply-token units.
export function healthFloor(
  debtAtExpiry: bigint, claimSafetyMargin: bigint, threshold: bigint,
  pNum: bigint, pDen: bigint,
): bigint {
  const inner = ceilingDiv(
    BASIS_POINT * debtAtExpiry * (BASIS_POINT + claimSafetyMargin),
    threshold * BASIS_POINT,
  );
  return ceilingDiv(inner * pDen, pNum);
}

/// `adapter/minswap.achievable` — the venue's constant product, net of its fee.
export function achievable(
  reserveIn: bigint, reserveOut: bigint, sold: bigint, feeNumerator: bigint,
): bigint {
  const paid = (sold * (BASIS_POINT - feeNumerator)) / BASIS_POINT;
  return (reserveOut * paid) / (reserveIn + paid);
}

export const marketFloor = (achievableNow: bigint, maxSlippage: bigint): bigint =>
  (achievableNow * (BASIS_POINT - maxSlippage)) / BASIS_POINT;

export const fillCeiling = (achievableNow: bigint, fillabilityMargin: bigint): bigint =>
  (achievableNow * (BASIS_POINT - fillabilityMargin)) / BASIS_POINT;

/// `order/utils.deposit_qty` and friends.
export const depositQty = (netInQty: bigint, loanAmount: bigint, tbv: bigint): bigint =>
  ceilingDiv(netInQty * loanAmount, tbv);

export const netLoanProceeds = (
  loanAmount: bigint, rate: bigint, minAmount: bigint,
): bigint => {
  const fee = ceilingDiv(rate * loanAmount, BASIS_POINT);
  return loanAmount - (fee > minAmount ? fee : minAmount);
};

export const limitFloor = (sold: bigint, priceNum: bigint, priceDen: bigint): bigint =>
  ceilingDiv(sold * priceDen, priceNum);

/// §2.13 to §2.15 and §11.2.6, in `long_token` units. `p` prices one unit of the
/// collateral in supply-token units.
export const debtInLong = (debt: bigint, pNum: bigint, pDen: bigint): bigint =>
  ceilingDiv(debt * pDen, pNum);

export function rewardBounds(
  collateralAmount: bigint, rewardCap: bigint, minReward: bigint,
  pNum: bigint, pDen: bigint,
): { floor: bigint; cap: bigint } {
  const cap = (collateralAmount * rewardCap) / BASIS_POINT;
  const want = ceilingDiv(minReward * pDen, pNum);
  return { floor: want < cap ? want : cap, cap };
}

export function seizedOf(
  debt: bigint, pNum: bigint, pDen: bigint, collateralAmount: bigint, reward: bigint,
): bigint {
  const inLong = debtInLong(debt, pNum, pDen);
  const left = collateralAmount - reward;
  return inLong < left ? inLong : left;
}

export const repaidOf = (seized: bigint, pNum: bigint, pDen: bigint): bigint =>
  (seized * pNum) / pDen;
