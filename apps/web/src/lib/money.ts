// mUSDC has 6 decimals. Amounts arrive as base-unit decimal strings; all math stays in bigint.
const DECIMALS = 6n;

/** "270000000" -> "270.00"; "20000000000" -> "20,000.00". Rounds half up to `places`. */
export function formatAmount(base: string | bigint, places = 2): string {
  let v = typeof base === "bigint" ? base : BigInt(base || "0");
  const negative = v < 0n;
  if (negative) v = -v;
  const unit = 10n ** (DECIMALS - BigInt(places));
  const rounded = (v + unit / 2n) / unit; // value in units of 10^-places
  const scale = 10n ** BigInt(places);
  const whole = (rounded / scale)
    .toString()
    .replace(/\B(?=(\d{3})+(?!\d))/g, ",");
  const frac =
    places > 0 ? `.${(rounded % scale).toString().padStart(places, "0")}` : "";
  return `${negative && rounded > 0n ? "-" : ""}${whole}${frac}`;
}

export const isZero = (base: string) => BigInt(base || "0") === 0n;

/** Share of `part` in `total` as a whole percent (0..100), for bar widths only. */
export function percent(part: string, total: string): number {
  const t = BigInt(total || "0");
  if (t === 0n) return 0;
  return Number((BigInt(part || "0") * 1000n) / t) / 10;
}
