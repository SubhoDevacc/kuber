// The money plan (ProposalKind.Allocation) and the fund manager (ProposalKind.Manager): pure helpers shared by the
// circle page and its tests. Bounds are the contract's own (`Params.validateRules`).
import { encodeAbiParameters } from "viem";
import type { Hex, MoneyPlan } from "../types";

/** `ProposalKind` in `contracts/src/lib/CircleTypes.sol`: Rule, Allocation, Manager, Kick, Join. */
export const KIND = { Rule: 0, Allocation: 1, Manager: 2 } as const;

export const ZERO_ADDRESS: Hex = "0x0000000000000000000000000000000000000000";

export const PLAN_PARTS: {
  key: keyof MoneyPlan;
  label: string;
  line: string;
}[] = [
  {
    key: "loan",
    label: "Ready to lend",
    line: "Kept for members' loans; earns the interest borrowers pay. At most 40%.",
  },
  {
    key: "aave",
    label: "Aave",
    line: "Lent out on Aave (a test vault): small, steady interest.",
  },
  {
    key: "lp",
    label: "LP pool",
    line: "Put in a trading pool (a test vault): can earn more, and can go down. At most 50%.",
  },
  {
    key: "cash",
    label: "Cash",
    line: "Kept in the circle for payouts; earns nothing. At least 5%.",
  },
];

/** The contract's rule, in plain words; null when the plan may be sent. */
export function planProblem(p: MoneyPlan): string | null {
  const parts = [p.loan, p.aave, p.lp, p.cash];
  if (parts.some((v) => !Number.isInteger(v) || v < 0))
    return "Enter each part as a percent from 0 to 100.";
  const total = parts.reduce((a, b) => a + b, 0);
  if (total !== 10_000)
    return `The four parts add up to ${pctText(total)}. They must add up to exactly 100%.`;
  if (p.loan > 4_000) return "Ready to lend can be at most 40%.";
  if (p.lp > 5_000) return "The LP pool can be at most 50%.";
  if (p.cash < 500) return "Cash must be at least 5%.";
  return null;
}

/** "12.5" → 1250 bps; null when not a percent with at most 2 decimals. */
export function pctToBps(v: string): number | null {
  const m = /^(\d{1,3})(?:\.(\d{1,2}))?$/.exec(v.trim());
  if (!m) return null;
  const bps = Number(m[1]) * 100 + Number((m[2] ?? "").padEnd(2, "0"));
  return bps <= 10_000 ? bps : null;
}

/** 1250 → "12.5%". */
export const pctText = (bps: number) =>
  `${Number((bps / 100).toFixed(2)).toString()}%`;

export const planLine = (p: MoneyPlan) =>
  PLAN_PARTS.map((x) => `${x.label} ${pctText(p[x.key])}`).join(" · ");

/** `propose(Allocation, abi.encode(Alloc))`: Alloc is four uint16, a static tuple, so it encodes like four words. */
export const encodePlan = (p: MoneyPlan): Hex =>
  encodeAbiParameters(
    [
      { type: "uint16" },
      { type: "uint16" },
      { type: "uint16" },
      { type: "uint16" },
    ],
    [p.loan, p.aave, p.lp, p.cash],
  );

/** `propose(Manager, abi.encode(address))`; the zero address removes the manager. */
export const encodeManager = (who: Hex): Hex =>
  encodeAbiParameters([{ type: "address" }], [who]);

/** "8%" / "8.5%" / 800 → bps. */
export function rateToBps(rate: number | string | undefined): number {
  if (typeof rate === "number") return rate > 100 ? rate : rate * 100;
  const m = /([\d.]+)/.exec(rate ?? "");
  return m ? Math.round(Number(m[1]) * 100) : 0;
}

/**
 * What backing `amount` risks and earns, with the contract's own formula (`Queue` at funding): a voucher's interest is
 * `amount × rate / 10,000` (floored), an "agree" backer's half that; either can lose up to what they put in.
 */
export function backingRisk(
  amount: bigint,
  rateBps: number,
  tier: "vouch" | "agree" = "vouch",
): { couldLose: bigint; wouldEarn: bigint } {
  const div = tier === "agree" ? 20_000n : 10_000n;
  return { couldLose: amount, wouldEarn: (amount * BigInt(rateBps)) / div };
}
