import { describe, expect, it } from "vitest";
import { describeCall, describeEvent, duration, pct, who } from "./txDescribe";

const CIRCLE = "0x1111111111111111111111111111111111111111";
const BALA = "0x2222222222222222222222222222222222222222";
const ME = "0x3333333333333333333333333333333333333333";
const STRANGER = "0xAbCdEf0000000000000000000000000000001234";
const ZERO = "0x0000000000000000000000000000000000000000";
const labels = {
  [CIRCLE]: "This circle",
  [BALA]: "Bala",
  [ME]: "You",
};

describe("helpers", () => {
  it("names addresses from labels, else short form", () => {
    expect(who(BALA, labels)).toBe("Bala");
    expect(who(BALA.toUpperCase().replace("0X", "0x"), labels)).toBe("Bala");
    expect(who(STRANGER, labels)).toBe("0xAbCd…1234");
  });
  it("formats percents and durations", () => {
    expect(pct(800n)).toBe("8.00%");
    expect(pct(9000)).toBe("90.00%");
    expect(pct(5n)).toBe("0.05%");
    expect(duration(604800)).toBe("1 week");
    expect(duration(172800)).toBe("2 days");
    expect(duration(300)).toBe("5 minutes");
  });
});

describe("describeCall", () => {
  it("words the main circle actions", () => {
    expect(describeCall("payNow", {}, labels).headline).toBe(
      "Saved this round",
    );
    expect(describeCall("withdraw", {}, labels).headline).toBe(
      "Collected share-out",
    );
    expect(describeCall("vote", { id: 1n, yes: true }, labels).headline).toBe(
      "Voted yes on rule change #1",
    );
  });
  it("words a loan request and its arguments", () => {
    const d = describeCall(
      "requestLoan",
      {
        amount: 350000000n,
        repayEpochs: 2n,
        offeredRateBps: 800n,
        extraBps: 200n,
      },
      labels,
    );
    expect(d.headline).toBe("Asked to borrow 350.00 mUSDC");
    expect(d.rows).toEqual([
      { label: "Amount", value: "350.00 mUSDC" },
      { label: "Paid back over", value: "2 rounds" },
      { label: "Interest offered", value: "8.00%" },
      { label: "Extra for backers", value: "2.00%" },
    ]);
  });
  it("words an approval with a labelled spender", () => {
    const d = describeCall(
      "approve",
      { spender: CIRCLE, value: 700000000n },
      labels,
    );
    expect(d.headline).toBe("Allowed this circle to collect 700.00 mUSDC");
    expect(d.rows[0]).toEqual({
      label: "Allowed to collect",
      value: "This circle",
    });
  });
  it("summarises createCircle without dumping structs", () => {
    const d = describeCall(
      "createCircle",
      {
        name: "Friends",
        fixedParams_: {
          contribution: 100000000n,
          epochDuration: 604800,
          totalEpochs: 6,
          minMembers: 3,
          maxMembers: 6,
        },
        rules_: { ownLtvBps: 9000, ownRateBps: 500 },
        invites: [BALA],
      },
      labels,
    );
    expect(d.headline).toBe("Created a circle");
    expect(d.rows).toContainEqual({ label: "Name", value: "Friends" });
    expect(d.rows).toContainEqual({
      label: "Saving per round",
      value: "100.00 mUSDC",
    });
    expect(d.rows).toContainEqual({ label: "Round length", value: "1 week" });
    expect(d.rows).toContainEqual({
      label: "Borrow up to",
      value: "90.00% of own savings",
    });
    expect(d.rows).toContainEqual({ label: "Invited", value: "Bala" });
    expect(
      JSON.stringify(d.rows, (_, v) => (typeof v === "bigint" ? "" : v)),
    ).not.toContain("object");
  });
  it("falls back to the function name", () => {
    expect(describeCall("recordJoin", { person: BALA }, labels)).toEqual({
      headline: "Called recordJoin",
      rows: [{ label: "Person", value: "Bala" }],
    });
  });
});

describe("describeEvent", () => {
  it("words circle events", () => {
    expect(
      describeEvent(
        "ContributionPaid",
        { member: BALA, epoch: 3n, amount: 100000000n },
        labels,
      ),
    ).toBe("Bala saved 100.00 mUSDC (round 3)");
    expect(
      describeEvent(
        "LoanRequested",
        {
          id: 1n,
          borrower: ME,
          amount: 350000000n,
          repayEpochs: 2n,
          offeredRateBps: 0n,
          extraBps: 0n,
        },
        labels,
      ),
    ).toBe("Loan requested: 350.00 mUSDC over 2 rounds");
    expect(
      describeEvent(
        "Backed",
        { id: 1n, backer: BALA, tier: 0, amount: 80000000n },
        labels,
      ),
    ).toBe("Bala backed loan #1 with 80.00 mUSDC");
    expect(
      describeEvent("Voted", { id: 1n, voter: ME, yes: false }, labels),
    ).toBe("You voted no on rule change #1");
    expect(describeEvent("EpochSettled", { epoch: 4n }, labels)).toBe(
      "Round 4 closed",
    );
    expect(
      describeEvent("Withdrawn", { member: BALA, amount: 712043010n }, labels),
    ).toBe("Bala collected a share-out of 712.04 mUSDC");
  });
  it("words token events, including mints", () => {
    expect(
      describeEvent(
        "Approval",
        { owner: ME, spender: CIRCLE, value: 700000000n },
        labels,
      ),
    ).toBe("You allowed this circle to collect 700.00 mUSDC");
    expect(
      describeEvent(
        "Transfer",
        { from: ZERO, to: BALA, value: 1000000000n },
        labels,
      ),
    ).toBe("1,000.00 mUSDC test money created for Bala");
    expect(
      describeEvent(
        "Transfer",
        { from: ME, to: CIRCLE, value: 100000000n },
        labels,
      ),
    ).toBe("100.00 mUSDC moved from you to this circle");
  });
  it("falls back to the raw event name", () => {
    expect(describeEvent("SomethingNew", {}, labels)).toBe("SomethingNew");
    expect(describeEvent("Activated", {}, labels)).toBe("The circle started");
  });
});
