import { kuberCircleAbi, mockUsdcAbi } from "@kuber/shared";
import type { Abi } from "viem";
import { describe, expect, it } from "vitest";
import { toArgs } from "./args";
import { formatAmount, percent } from "./money";

describe("formatAmount", () => {
  it("formats base units with two places and separators", () => {
    expect(formatAmount("270000000")).toBe("270.00");
    expect(formatAmount("20000000000")).toBe("20,000.00");
    expect(formatAmount("0")).toBe("0.00");
    expect(formatAmount("")).toBe("0.00");
  });
  it("rounds half up without floats", () => {
    expect(formatAmount("712043010")).toBe("712.04");
    expect(formatAmount("106749998")).toBe("106.75");
    expect(formatAmount("182250000")).toBe("182.25");
    expect(formatAmount("4999")).toBe("0.00");
    expect(formatAmount("5000")).toBe("0.01");
    expect(formatAmount(123456789012345678n)).toBe("123,456,789,012.35");
    expect(formatAmount("-30000000")).toBe("-30.00");
    expect(formatAmount("20000000000", 0)).toBe("20,000");
  });
  it("gives bar percentages", () => {
    expect(percent("720000000", "1800000000")).toBe(40);
    expect(percent("1", "0")).toBe(0);
  });
});

describe("toArgs", () => {
  it("converts numeric strings to bigint by ABI type", () => {
    expect(
      toArgs(kuberCircleAbi as Abi, "requestLoan", [
        "350000000",
        "2",
        "800",
        "0",
      ]),
    ).toEqual([350000000n, 2n, 800n, 0n]);
  });
  it("keeps addresses and booleans, accepts bool strings", () => {
    const circle = "0x5FbDB2315678afecb367f032d93F642f64180aa3";
    expect(
      toArgs(mockUsdcAbi as Abi, "approve", [circle, "1000000000"]),
    ).toEqual([circle, 1000000000n]);
    expect(toArgs(kuberCircleAbi as Abi, "vote", ["1", true])).toEqual([
      1n,
      true,
    ]);
    expect(toArgs(kuberCircleAbi as Abi, "vote", [1, "false"])).toEqual([
      1n,
      false,
    ]);
    expect(toArgs(kuberCircleAbi as Abi, "join", [])).toEqual([]);
  });
  it("rejects an unknown function or a wrong arg count", () => {
    expect(() => toArgs(kuberCircleAbi as Abi, "nope", [])).toThrow();
    expect(() => toArgs(kuberCircleAbi as Abi, "vote", ["1"])).toThrow();
  });
});

describe("toArgs structs", () => {
  it("turns a createCircle struct's digit strings into bigints by field type", async () => {
    const { kuberFactoryAbi } = await import("@kuber/shared");
    const [name, fixed, , invites] = toArgs(
      kuberFactoryAbi as Abi,
      "createCircle",
      [
        "Practice circle (Maya)",
        {
          contribution: "100000000",
          epochDuration: 60,
          lockBps: 2000,
          startTime: "1794632776",
          minSaveEpochs: 3,
          totalEpochs: 7,
          minMembers: 5,
          maxMembers: 50,
          maxRepayEpochs: 3,
          cooldownEpochs: 1,
        },
        {
          ownLtvBps: 9000,
          ownRateBps: 300,
          perLoanMaxBps: 5000,
          fastLaneBps: 3000,
          penaltyBps: 1000,
          contribFineBps: 100,
          installFineBps: 300,
          exitFeeBps: 300,
          managerFeeBps: 0,
          alloc: { loan: 4000, aave: 3000, lp: 2000, cash: 1000 },
        },
        ["0x8C3229EC621644789d7F61FAa82c6d0E5F97d43D"],
      ],
    ) as [string, Record<string, unknown>, unknown, string[]];
    expect(name).toBe("Practice circle (Maya)");
    expect(fixed.contribution).toBe(100000000n);
    expect(fixed.startTime).toBe(1794632776n);
    expect(fixed.epochDuration).toBe(60n);
    expect(invites).toHaveLength(1);
  });
});
