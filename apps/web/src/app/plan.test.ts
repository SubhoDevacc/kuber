import { decodeAbiParameters } from "viem";
import { describe, expect, it } from "vitest";
import {
  backingRisk,
  encodeManager,
  encodePlan,
  KIND,
  pctToBps,
  planLine,
  planProblem,
  rateToBps,
  ZERO_ADDRESS,
} from "./plan";

describe("money plan", () => {
  it("uses the contract's ProposalKind order", () => {
    expect(KIND).toEqual({ Rule: 0, Allocation: 1, Manager: 2 });
  });

  it("accepts a plan that adds to 100% within the bounds", () => {
    expect(planProblem({ loan: 4000, aave: 3500, lp: 1500, cash: 1000 })).toBe(
      null,
    );
  });

  it("checks the contract's bounds before sending", () => {
    expect(
      planProblem({ loan: 4000, aave: 3000, lp: 2000, cash: 500 }),
    ).toMatch(/95%/);
    expect(
      planProblem({ loan: 4100, aave: 2900, lp: 2000, cash: 1000 }),
    ).toMatch(/Ready to lend can be at most 40%/);
    expect(
      planProblem({ loan: 2000, aave: 2000, lp: 5100, cash: 900 }),
    ).toMatch(/LP pool can be at most 50%/);
    expect(
      planProblem({ loan: 4000, aave: 4000, lp: 1600, cash: 400 }),
    ).toMatch(/Cash must be at least 5%/);
  });

  it("encodes Alloc as four words and the manager as an address", () => {
    const data = encodePlan({ loan: 4000, aave: 3500, lp: 1500, cash: 1000 });
    expect(
      decodeAbiParameters(
        [
          { type: "uint16" },
          { type: "uint16" },
          { type: "uint16" },
          { type: "uint16" },
        ],
        data,
      ),
    ).toEqual([4000, 3500, 1500, 1000]);
    expect(encodeManager(ZERO_ADDRESS)).toBe(`0x${"0".repeat(64)}`);
  });

  it("reads percents and lines", () => {
    expect(pctToBps("12.5")).toBe(1250);
    expect(pctToBps("101")).toBe(null);
    expect(pctToBps("abc")).toBe(null);
    expect(planLine({ loan: 4000, aave: 3500, lp: 1500, cash: 1000 })).toBe(
      "Ready to lend 40% · Aave 35% · LP pool 15% · Cash 10%",
    );
  });
});

describe("backing risk (the contract's formula)", () => {
  it("vouch earns amount × rate, agree half; either can lose what they put in", () => {
    // The tutorial's numbers: Bala backs 80.00 at 8% → earns 6.40.
    expect(backingRisk(80_000_000n, 800)).toEqual({
      couldLose: 80_000_000n,
      wouldEarn: 6_400_000n,
    });
    expect(backingRisk(80_000_000n, 800, "agree").wouldEarn).toBe(3_200_000n);
    expect(backingRisk(1n, 800).wouldEarn).toBe(0n);
  });

  it("reads the rate as bps or as text", () => {
    expect(rateToBps("8%")).toBe(800);
    expect(rateToBps("8.5%")).toBe(850);
    expect(rateToBps(800)).toBe(800);
  });
});
