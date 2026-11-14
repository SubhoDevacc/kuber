// The practice-circle tutorial: SPEC §4 / contracts S1 (BackingTestBase._s1Run) with the user as member A and five
// bots. Steps are data; the server does the bots' part, moves chain time on the circle's own clock, and settles.
import {
  type Address,
  encodeAbiParameters,
  maxUint256,
  parseEventLogs,
} from "viem";
import { mnemonicToAccount, type PrivateKeyAccount } from "viem/accounts";
import { BIG_GAS, type Chain } from "./chain.ts";
import {
  type Facts,
  installmentOf,
  type LoanRaw,
  type MemberFacts,
  memberStatus,
  money,
  type Names,
  pct,
  toSnapshot,
} from "./snapshot.ts";

const MNEMONIC = "test test test test test test test test test test test junk";
const USDC = 1_000_000n;
export const CHAPTERS = [
  "Join and save",
  "Borrow",
  "Repay",
  "Vote",
  "A member stops paying",
  "Share-out",
];
const BOTS = { B: "Bob", C: "Cara", D: "Dave", E: "Erin", F: "Frank" } as const;
type Bot = keyof typeof BOTS;
type Letter = Bot | "A";
const BOT_LETTERS = Object.keys(BOTS) as Bot[];
const PRACTICE_PREFIX = "Practice circle";

export class HttpError extends Error {
  status: 400 | 401 | 404 | 409;
  constructor(status: 400 | 401 | 404 | 409, message: string) {
    super(message);
    this.status = status;
  }
}

type Row = {
  label: string;
  before: string;
  after: string;
  tone: "good" | "bad" | "plain";
};
export type Change = { title: string; rows: Row[]; note: string | null };
type Action = {
  label: string;
  target: "usdc" | "circle";
  functionName: string;
  args: (string | number | boolean | string[])[];
};

export type Tutorial = {
  user: Address;
  circle: Address;
  bots: Record<Bot, PrivateKeyAccount>;
  names: Names;
  stepIndex: number;
  lastChange: Change | null;
  before: Facts;
  userLoan: number;
  daveLoan: number;
  proposal: number;
  running: Promise<unknown> | null;
};

type Engine = ReturnType<typeof engine>;
type Step = {
  id: string;
  chapter: number;
  title: string;
  body: (f: Facts, t: Tutorial) => string;
  action: null | ((f: Facts, t: Tutorial) => Action);
  /** null when the user's action is on chain, else the plain-words reason for a 409. */
  check?: (f: Facts, t: Tutorial) => string | null;
  waitNote: string | null;
  run?: (e: Engine, t: Tutorial, f: Facts) => Promise<void>;
  change: (b: Facts, a: Facts, t: Tutorial) => Change;
};

// ---------- reading helpers

const addrOf = (t: Tutorial, l: Letter) =>
  l === "A" ? t.user : t.bots[l].address;
const who = (f: Facts, t: Tutorial, l: Letter): MemberFacts | undefined => {
  const a = addrOf(t, l).toLowerCase();
  return f.members.find((m) => m.address.toLowerCase() === a);
};
const n0 = (
  m: MemberFacts | undefined,
  k: "savings" | "pledgedOut" | "rewards" | "lost" | "debt" | "loanOwed",
) => (m ? m[k] : 0n);
const loan = (f: Facts, id: number): LoanRaw | undefined =>
  f.loans.find((l) => l.id === id);
const row = (
  label: string,
  before: string,
  after: string,
  tone: Row["tone"] = "plain",
): Row => ({
  label,
  before,
  after,
  tone,
});
const mrow = (
  label: string,
  b: bigint,
  a: bigint,
  tone: Row["tone"] = "plain",
) => row(label, money(b), money(a), tone);
const roundLabel = (f: Facts) =>
  f.status === 0
    ? "Waiting to start"
    : f.status === 2
      ? "Ended"
      : `Round ${Math.min(f.round, f.totalRounds)} of ${f.totalRounds}`;
const potTotal = (f: Facts) => f.pot.cash + f.pot.invested + f.pot.lent;
const user = (f: Facts, t: Tutorial) => who(f, t, "A");
const repayAllowance = (f: Facts, t: Tutorial) => {
  const me = user(f, t);
  const l = loan(f, t.userLoan);
  const owed = l
    ? l.amount +
      l.saverInterest +
      [...l.vouchers, ...l.agreers].reduce((s, b) => s + b.interest, 0n)
    : 0n;
  const rounds = BigInt(f.totalRounds - (me?.paidCount ?? 0));
  return { rounds, owed, total: rounds * f.contribution + owed + owed / 10n };
};

// ---------- the story

const STEPS: Step[] = [
  {
    id: "approve",
    chapter: 1,
    title: "Allow your savings",
    body: (f) =>
      `Everyone in this circle saves ${money(f.contribution)} (test money) each round, for ${f.totalRounds} rounds. First, allow the circle to collect up to ${money(f.contribution * BigInt(f.totalRounds))} from your wallet: one round's savings at a time, only when they are due.`,
    action: (f) => ({
      label: `Allow ${money(f.contribution * BigInt(f.totalRounds))}`,
      target: "usdc",
      functionName: "approve",
      args: [f.circle, (f.contribution * BigInt(f.totalRounds)).toString()],
    }),
    check: (f) =>
      f.userAllowance >= f.contribution * BigInt(f.totalRounds)
        ? null
        : "We can't see your permission on the chain yet. Press the Allow button, wait until it is confirmed, then continue.",
    waitNote: "Checking your permission…",
    change: (b, a) => ({
      title: "Permission given",
      rows: [
        mrow(
          "The circle may collect",
          b.userAllowance,
          a.userAllowance,
          "good",
        ),
        mrow("Your wallet", b.userWallet, a.userWallet),
      ],
      note: "Nothing left your wallet yet: you only gave permission.",
    }),
  },
  {
    id: "join",
    chapter: 1,
    title: "Join the circle",
    body: () =>
      "Bob started this practice circle and invited you, Cara, Dave, Erin and Frank. They have all joined. Join too, and the circle starts with 6 people.",
    action: () => ({
      label: "Join the circle",
      target: "circle",
      functionName: "join",
      args: [],
    }),
    check: (f, t) =>
      user(f, t)?.status === 1
        ? null
        : "You haven't joined yet. Press “Join the circle”, wait until it is confirmed, then continue.",
    waitNote: "Starting the circle…",
    run: async (e, t) => {
      await e.toRound(t, 1);
      await e.admin(t.circle, "activate", [], BIG_GAS);
      await e.payBots(t, BOT_LETTERS);
    },
    change: (b, a) => ({
      title: "The circle started",
      rows: [
        row(
          "Members",
          String(b.members.length),
          String(a.members.length),
          "good",
        ),
        row("Circle", roundLabel(b), roundLabel(a), "good"),
        mrow("Saved in the circle", potTotal(b), potTotal(a), "good"),
      ],
      note: "The others paid round 1 right away. Yours is collected when the round closes.",
    }),
  },
  {
    id: "round1",
    chapter: 1,
    title: "Round 1 closes",
    body: () =>
      "You don't need to do anything each round. When a round closes, the circle collects the savings of everyone who hasn't paid yet, using the permission they gave.",
    action: null,
    waitNote: "Round 1 is closing…",
    run: async (e, t) => {
      await e.toRound(t, 2);
      await e.settle(t);
      await e.payBots(t, BOT_LETTERS);
    },
    change: (b, a, t) => ({
      title: "Round 1 closed",
      rows: [
        mrow(
          "Your savings",
          n0(user(b, t), "savings"),
          n0(user(a, t), "savings"),
          "good",
        ),
        mrow("Your wallet", b.userWallet, a.userWallet),
        mrow("Invested by the circle", b.pot.invested, a.pot.invested, "good"),
      ],
      note: "Your savings grow by one round's savings every round, and the circle puts the money to work.",
    }),
  },
  {
    id: "round2",
    chapter: 1,
    title: "Your money at work",
    body: () =>
      "The circle keeps some cash, keeps some ready to lend to members, and invests the rest. Whatever it earns is shared out at the end.",
    action: null,
    waitNote: "Round 2 is closing…",
    run: async (e, t) => {
      await e.toRound(t, 3);
      await e.settle(t);
      // Round 3 is paid up front by every bot (Dave must have 3 rounds saved before he can borrow).
      await e.payBots(t, BOT_LETTERS);
    },
    change: (b, a, t) => ({
      title: "Round 2 closed",
      rows: [
        mrow(
          "Your savings",
          n0(user(b, t), "savings"),
          n0(user(a, t), "savings"),
          "good",
        ),
        mrow("Cash in the circle", b.pot.cash, a.pot.cash),
        mrow("Invested by the circle", b.pot.invested, a.pot.invested, "good"),
      ],
      note: "Cash, money kept for loans, and investments all still count as everyone's savings.",
    }),
  },
  {
    id: "prepay",
    chapter: 2,
    title: "Save round 3 early",
    body: () =>
      "To borrow, you need 3 rounds of savings. Rounds 1 and 2 are done. Pay round 3 now instead of waiting for the round to close.",
    action: (f) => ({
      label: `Pay ${money(f.contribution)} now`,
      target: "circle",
      functionName: "payNow",
      args: [],
    }),
    check: (f, t) =>
      (user(f, t)?.paidCount ?? 0) >= 3
        ? null
        : "Round 3 isn't paid yet. Press the Pay button, wait until it is confirmed, then continue.",
    waitNote: "Checking your payment…",
    change: (b, a, t) => ({
      title: "Round 3 paid",
      rows: [
        mrow(
          "Your savings",
          n0(user(b, t), "savings"),
          n0(user(a, t), "savings"),
          "good",
        ),
        mrow("Your wallet", b.userWallet, a.userWallet),
        row(
          "Rounds saved",
          `${user(b, t)?.paidCount ?? 0} of ${b.totalRounds}`,
          `${user(a, t)?.paidCount ?? 0} of ${a.totalRounds}`,
          "good",
        ),
      ],
      note: "With 3 rounds saved, you can now ask for a loan.",
    }),
  },
  {
    id: "request",
    chapter: 2,
    title: "Ask for a loan",
    body: () =>
      "Ask for 350, paid back over 2 rounds. Up to 270 can come from your own 300 of savings. The other 80 needs a backer: Bob will back you by putting 80 of his savings on hold for your loan.",
    action: () => ({
      label: "Ask for 350.00 mUSDC",
      target: "circle",
      functionName: "requestLoan",
      args: [(350n * USDC).toString(), "2", "800", "0"],
    }),
    check: (f, t) => {
      const me = user(f, t);
      return me && (me.pendingRequestId || me.activeLoanId)
        ? null
        : "We can't see your loan request yet. Press “Ask for 350.00 mUSDC”, wait until it is confirmed, then continue.";
    },
    waitNote: "Bob is backing you, and round 3 is closing…",
    run: async (e, t, f) => {
      const me = user(f, t);
      t.userLoan = me?.pendingRequestId || me?.activeLoanId || 0;
      await e.bot(t, "D", "requestLoan", [350n * USDC, 3n, 800n, 0n]);
      const dave = await e.member(t, "D");
      t.daveLoan = dave.pendingRequestId;
      await e.bot(t, "B", "vouch", [BigInt(t.userLoan), 80n * USDC]);
      await e.bot(t, "C", "vouch", [BigInt(t.daveLoan), 30n * USDC]);
      await e.bot(t, "E", "agree", [BigInt(t.daveLoan), 50n * USDC]);
      await e.toRound(t, 4);
      await e.settle(t);
    },
    change: (b, a, t) => {
      const l = loan(a, t.userLoan);
      const funded = l?.status === 2;
      return {
        title: funded ? "Your loan is ready" : "Your loan is waiting",
        rows: [
          row(
            "Your loan",
            "None",
            l
              ? `${money(l.amount)}${funded ? ", ready" : ", waiting"}`
              : "None",
            funded ? "good" : "plain",
          ),
          mrow("From your own savings", 0n, l?.ownPart ?? 0n),
          mrow("Backed by Bob", 0n, l?.backedNeed ?? 0n, "good"),
          mrow(
            "Bob's savings on hold",
            n0(who(b, t, "B"), "pledgedOut"),
            n0(who(a, t, "B"), "pledgedOut"),
          ),
        ],
        note: "Loans are paid out when a round closes. Dave also borrowed 350, backed by Cara and Erin.",
      };
    },
  },
  {
    id: "approve2",
    chapter: 2,
    title: "Allow your repayments",
    body: (f, t) => {
      const r = repayAllowance(f, t);
      const l = loan(f, t.userLoan);
      return `You will repay ${money(l ? installmentOf(l) : 0n)} in each of the next 2 rounds, on top of your savings. A new permission replaces the old one, so allow ${money(r.total)}: your ${r.rounds} remaining rounds of savings, both repayments (${money(r.owed)}), and a 10% cushion.`;
    },
    action: (f, t) => {
      const r = repayAllowance(f, t);
      return {
        label: `Allow ${money(r.total)}`,
        target: "usdc",
        functionName: "approve",
        args: [f.circle, r.total.toString()],
      };
    },
    check: (f, t) =>
      f.userAllowance >= repayAllowance(f, t).total
        ? null
        : "We can't see the new permission yet. Press the Allow button, wait until it is confirmed, then continue.",
    waitNote: "Checking your permission…",
    change: (b, a) => ({
      title: "Repayments allowed",
      rows: [
        mrow(
          "The circle may collect",
          b.userAllowance,
          a.userAllowance,
          "good",
        ),
      ],
      note: "Without this, your repayments could not be collected and you would fall behind.",
    }),
  },
  {
    id: "claim",
    chapter: 2,
    title: "Take your loan",
    body: () => "Your 350 is waiting in the circle. Move it to your wallet.",
    action: () => ({
      label: "Take 350.00 mUSDC",
      target: "circle",
      functionName: "claim",
      args: [],
    }),
    check: (f, t) =>
      loan(f, t.userLoan)?.unclaimed === 0n
        ? null
        : "Your loan is still in the circle. Press “Take 350.00 mUSDC”, wait until it is confirmed, then continue.",
    waitNote: "Round 4 is closing…",
    run: async (e, t) => {
      // R-I: Dave takes his loan, then removes his permission, so nothing more can be collected from him.
      await e.bot(t, "D", "claim");
      await e.botUsdc(t, "D", "approve", [t.circle, 0n]);
      await e.payBots(t, ["B", "C", "E", "F"]);
      await e.toRound(t, 5);
      await e.settle(t);
    },
    change: (b, a, t) => {
      const d = who(a, t, "D");
      const missed = d ? (d.missedBitmap & (1n << 4n)) !== 0n : false;
      return {
        title: "Round 4 closed",
        rows: [
          mrow("Your wallet", b.userWallet, a.userWallet, "good"),
          mrow(
            "Your savings",
            n0(user(b, t), "savings"),
            n0(user(a, t), "savings"),
            "good",
          ),
          row(
            "Your 350.00 mUSDC loan",
            "In the circle",
            loan(a, t.userLoan)?.unclaimed === 0n
              ? "In your wallet"
              : "In the circle",
            "good",
          ),
          row(
            "Dave's round 4 savings",
            "Due",
            missed ? "Not paid" : "Paid",
            missed ? "bad" : "plain",
          ),
        ],
        note: "Borrowing did not touch your savings: they kept growing and keep earning.",
      };
    },
  },
  {
    id: "repay1",
    chapter: 3,
    title: "Repay, part 1",
    body: (f, t) => {
      const l = loan(f, t.userLoan);
      if (!l) return "Pay this round's savings plus your first repayment.";
      const n = BigInt(l.repayEpochs);
      const bob = l.vouchers[0]?.interest ?? 0n;
      return `This round you pay your savings plus the first repayment of ${money(installmentOf(l))}: ${money(l.amount / n)} of the loan, ${money(l.saverInterest / n)} interest for all savers, and ${money(bob / n)} for Bob for backing you.`;
    },
    action: (f, t) => {
      const l = loan(f, t.userLoan);
      return {
        label: `Pay ${money(f.contribution + (l ? installmentOf(l) : 0n))}`,
        target: "circle",
        functionName: "payNow",
        args: [],
      };
    },
    check: (f, t) =>
      (loan(f, t.userLoan)?.installmentsPaid ?? 0) >= 1
        ? null
        : "Your first repayment isn't in yet. Press the Pay button, wait until it is confirmed, then continue.",
    waitNote: "Round 5 is closing…",
    run: async (e, t) => {
      await e.payBots(t, ["B", "C", "E", "F"]);
      await e.toRound(t, 6);
      await e.settle(t);
    },
    change: (b, a, t) => ({
      title: "Round 5 closed",
      rows: [
        mrow(
          "You still owe",
          n0(user(b, t), "loanOwed"),
          n0(user(a, t), "loanOwed"),
          "good",
        ),
        mrow(
          "Your savings",
          n0(user(b, t), "savings"),
          n0(user(a, t), "savings"),
          "good",
        ),
        mrow(
          "Bob earned for backing you",
          n0(who(b, t, "B"), "rewards"),
          n0(who(a, t, "B"), "rewards"),
          "good",
        ),
        row(
          "Dave",
          memberStatus(who(b, t, "D")),
          memberStatus(who(a, t, "D")),
          "bad",
        ),
      ],
      note: "Paying on time keeps you on track. Dave paid nothing, so he is now behind on his loan.",
    }),
  },
  {
    id: "repay2",
    chapter: 3,
    title: "Repay, part 2",
    body: (f, t) => {
      const l = loan(f, t.userLoan);
      return `Pay your savings and the last repayment of ${money(l ? (n0(user(f, t), "loanOwed") ?? 0n) : 0n)}. Then your loan is done.`;
    },
    action: (f, t) => ({
      label: `Pay ${money(f.contribution + n0(user(f, t), "loanOwed"))}`,
      target: "circle",
      functionName: "payNow",
      args: [],
    }),
    check: (f, t) =>
      loan(f, t.userLoan)?.status === 3
        ? null
        : "Your last repayment isn't in yet. Press the Pay button, wait until it is confirmed, then continue.",
    waitNote: "Recording your repayment…",
    run: async (e, t) => {
      await e.payBots(t, ["B", "C", "E", "F"]);
      // Chapter 4's proposal: lower the early-leave fee. Nobody leaves this circle, so no payout changes.
      const data = encodeAbiParameters(
        [{ type: "uint8" }, { type: "uint256" }],
        [7, 200n],
      );
      await e.bot(t, "B", "propose", [0, data]);
      t.proposal = Number((await e.state(t)).proposalCount);
    },
    change: (b, a, t) => ({
      title: "Loan repaid",
      rows: [
        mrow(
          "You still owe",
          n0(user(b, t), "loanOwed"),
          n0(user(a, t), "loanOwed"),
          "good",
        ),
        mrow(
          "Bob earned for backing you",
          n0(who(b, t, "B"), "rewards"),
          n0(who(a, t, "B"), "rewards"),
          "good",
        ),
        mrow(
          "Bob's savings on hold",
          n0(who(b, t, "B"), "pledgedOut"),
          n0(who(a, t, "B"), "pledgedOut"),
          "good",
        ),
        mrow(
          "Your savings",
          n0(user(b, t), "savings"),
          n0(user(a, t), "savings"),
          "good",
        ),
      ],
      note: "Bob earned interest for trusting you, and his savings are free again.",
    }),
  },
  {
    id: "vote",
    chapter: 4,
    title: "Vote on a rule",
    body: (f) =>
      `Bob suggests lowering the fee for leaving the circle early from ${pct(f.exitFeeBps)} to 2%. It passes if more than half of the ${f.members.length} members vote yes. Nobody is leaving this circle, so it changes no one's money here.`,
    action: (_f, t) => ({
      label: "Vote yes",
      target: "circle",
      functionName: "vote",
      args: [String(t.proposal), true],
    }),
    check: (f, t) =>
      f.proposals.find((p) => p.id === t.proposal)?.youVoted
        ? null
        : "Your vote isn't in yet. Press “Vote yes”, wait until it is confirmed, then continue.",
    waitNote: "Counting the votes as round 6 closes…",
    run: async (e, t) => {
      await e.bot(t, "B", "vote", [BigInt(t.proposal), true]);
      await e.bot(t, "C", "vote", [BigInt(t.proposal), true]);
      await e.bot(t, "E", "vote", [BigInt(t.proposal), true]);
      await e.bot(t, "F", "vote", [BigInt(t.proposal), false]);
      await e.toRound(t, 7);
      await e.settle(t);
    },
    change: (b, a, t) => {
      const pb = b.proposals.find((p) => p.id === t.proposal);
      const pa = a.proposals.find((p) => p.id === t.proposal);
      const passed = pa?.status === 4;
      return {
        title: passed ? "The vote passed" : "The vote did not pass",
        rows: [
          row("Yes votes", String(pb?.yes ?? 0), String(pa?.yes ?? 0)),
          row("No votes", String(pb?.no ?? 0), String(pa?.no ?? 0)),
          row(
            "Fee for leaving early",
            pct(b.exitFeeBps),
            pct(a.exitFeeBps),
            passed ? "good" : "plain",
          ),
          row(
            "Dave",
            memberStatus(who(b, t, "D")),
            memberStatus(who(a, t, "D")),
            "bad",
          ),
        ],
        note: passed
          ? "More than half of the members said yes, so the rule changed when round 6 closed."
          : "Not enough members said yes, so the rule stayed the same.",
      };
    },
  },
  {
    id: "default",
    chapter: 5,
    title: "Dave stops paying",
    body: () =>
      "Dave borrowed 350 and has paid nothing back: he is 2 repayments behind. When the last round closes, the circle takes what he owes from his own savings first. Only what is still missing comes from the people who backed him.",
    action: null,
    waitNote: "Round 7, the last round, is closing…",
    run: async (e, t) => {
      await e.payBots(t, ["B", "C", "E", "F"]);
      await e.toRound(t, 8);
      // R-I: the circle's investment earnings (60) arrive as cash just before the last settlement.
      await e.admin(
        e.chain.usdc,
        "mint",
        [t.circle, 60n * USDC],
        undefined,
        "usdc",
      );
      await e.settle(t);
    },
    change: (b, a, t) => {
      const d = loan(a, t.daveLoan);
      const lostC = n0(who(a, t, "C"), "lost");
      const lostE = n0(who(a, t, "E"), "lost");
      const fromDave = (d?.amount ?? 0n) - lostC - lostE;
      return {
        title: "Dave's loan was covered",
        rows: [
          mrow(
            "Dave's savings",
            n0(who(b, t, "D"), "savings"),
            n0(who(a, t, "D"), "savings"),
            "bad",
          ),
          mrow(
            "Cara lost (she backed Dave)",
            n0(who(b, t, "C"), "lost"),
            lostC,
            "bad",
          ),
          mrow(
            "Erin lost (she backed Dave)",
            n0(who(b, t, "E"), "lost"),
            lostE,
            "bad",
          ),
          mrow(
            "Frank lost",
            n0(who(b, t, "F"), "lost"),
            n0(who(a, t, "F"), "lost"),
            "good",
          ),
          mrow(
            "You lost",
            n0(user(b, t), "lost"),
            n0(user(a, t), "lost"),
            "good",
          ),
          mrow(
            "Dave still owes",
            n0(who(b, t, "D"), "debt"),
            n0(who(a, t, "D"), "debt"),
            "bad",
          ),
          row("Circle", roundLabel(b), roundLabel(a)),
        ],
        note: `Dave's own savings paid ${money(fromDave)} first; only the people who backed him covered the rest (Cara ${money(lostC)}, Erin ${money(lostE)}). Frank and you lost nothing.`,
      };
    },
  },
  {
    id: "withdraw",
    chapter: 6,
    title: "Collect your share-out",
    body: () =>
      "The circle has ended. Your share-out is your savings plus your part of what the circle earned: the interest paid on loans and 60 from investments. Collect it.",
    action: () => ({
      label: "Collect my share-out",
      target: "circle",
      functionName: "withdraw",
      args: [],
    }),
    check: (f, t) =>
      user(f, t)?.withdrawn
        ? null
        : "Your share-out is still in the circle. Press “Collect my share-out”, wait until it is confirmed, then continue.",
    waitNote: "Paying everyone out…",
    run: async (e, t) => {
      for (const l of BOT_LETTERS) await e.bot(t, l, "withdraw");
    },
    change: (b, a, t) => {
      const got = (l: Letter) =>
        (who(a, t, l)?.wallet ?? 0n) - (who(b, t, l)?.wallet ?? 0n);
      const share = (l: Letter, label: string): Row =>
        row(label, "Not paid", money(got(l)), l === "D" ? "bad" : "good");
      const mine = got("A");
      const saved = a.contribution * BigInt(a.totalRounds);
      return {
        title: "Everyone was paid out",
        rows: [
          share("A", "Your share-out"),
          mrow("Your wallet", b.userWallet, a.userWallet, "good"),
          share("B", "Bob's share-out"),
          share("C", "Cara's share-out"),
          share("D", "Dave's share-out"),
          share("E", "Erin's share-out"),
          share("F", "Frank's share-out"),
        ],
        note: `You saved ${money(saved)} and got back ${money(mine)}: your savings plus your share of what the circle earned.`,
      };
    },
  },
  {
    id: "finished",
    chapter: 6,
    title: "You did it",
    body: () =>
      "You saved, borrowed with a backer, repaid, voted, and saw how the circle covers a loan that isn't repaid. Your practice circle is finished. The test money in your wallet is yours to use in the app.",
    action: null,
    waitNote: null,
    change: () => ({ title: "", rows: [], note: null }),
  },
];
export const STEP_IDS = STEPS.map((s) => s.id);

// ---------- chain side

const engine = (c: Chain) => {
  const { abis } = c;
  const state = (t: Tutorial) =>
    c.read<{
      status: number;
      currentEpoch: bigint;
      settledEpoch: bigint;
      proposalCount: bigint;
    }>(t.circle, abis.circle, "getCircleState");
  return {
    chain: c,
    state,
    admin: (
      to: Address,
      fn: string,
      args: readonly unknown[] = [],
      gas?: bigint,
      abi: "circle" | "usdc" | "registry" = "circle",
    ) => c.send(c.admin, to, abis[abi], fn, args, gas),
    bot: (t: Tutorial, l: Bot, fn: string, args: readonly unknown[] = []) =>
      c.send(t.bots[l], t.circle, abis.circle, fn, args),
    botUsdc: (t: Tutorial, l: Bot, fn: string, args: readonly unknown[]) =>
      c.send(t.bots[l], c.usdc, abis.usdc, fn, args),
    member: (t: Tutorial, l: Bot) =>
      c.read<{ pendingRequestId: number }>(t.circle, abis.circle, "getMember", [
        t.bots[l].address,
      ]),
    payBots: async (t: Tutorial, ls: Bot[]) => {
      for (const l of ls)
        await c.send(t.bots[l], t.circle, abis.circle, "payNow");
    },
    /** Start of round `e` on the circle's own clock (startTime + (e − 1) × epochDuration). */
    toRound: async (t: Tutorial, e: number) => {
      const f = t.before;
      await c.warpTo(f.startTime + BigInt(e - 1) * f.epochDuration);
    },
    /** Settles every ended round (settle(max) handles all members at once for six). */
    settle: async (t: Tutorial) => {
      for (let i = 0; i < 10; i++) {
        const s = await state(t);
        if (s.status !== 1 || s.settledEpoch >= s.currentEpoch - 1n) return;
        await c.send(
          c.admin,
          t.circle,
          abis.circle,
          "settle",
          [maxUint256],
          BIG_GAS,
        );
      }
    },
  };
};

// ---------- public API

export type TutorialState = Awaited<ReturnType<Tutorials["view"]>>;
export type Tutorials = ReturnType<typeof tutorials>;

export const tutorials = (
  c: Chain,
  readFacts: (circle: Address, u: Address | null) => Promise<Facts>,
) => {
  const e = engine(c);
  const { abis } = c;
  /** Practice circles: lowercase circle -> display names of its members. */
  const practice = new Map<string, Names>();

  /** Five fresh bots (verified, gas, 10,000 mUSDC), Bob creates the S1 circle inviting the user, the rest join. */
  const create = async (u: Address, userName: string): Promise<Tutorial> => {
    // Unique per run, also across server restarts on the same chain: every run creates exactly one circle.
    const run = Number(
      await c.read<bigint>(c.factory, abis.factory, "circleCount"),
    );
    const bots = Object.fromEntries(
      BOT_LETTERS.map((l, i) => [
        l,
        mnemonicToAccount(MNEMONIC, { addressIndex: 100 + run * 10 + i }),
      ]),
    ) as unknown as Record<Bot, PrivateKeyAccount>;
    for (const l of BOT_LETTERS) {
      const a = bots[l].address;
      await c.setGas(a);
      await e.admin(
        c.registry,
        "setVerified",
        [a, true],
        undefined,
        "registry",
      );
      await e.admin(c.usdc, "mint", [a, 10_000n * USDC], undefined, "usdc");
    }
    for (const l of BOT_LETTERS)
      if (
        !(await c.read<boolean>(c.registry, abis.registry, "verified", [
          bots[l].address,
        ]))
      )
        throw new Error("bot verification failed");
    const fixed = {
      contribution: 100n * USDC,
      epochDuration: 60,
      lockBps: 2_000,
      startTime: (await c.now()) + 60n,
      minSaveEpochs: 3,
      totalEpochs: 7,
      minMembers: 5,
      maxMembers: 50,
      maxRepayEpochs: 3,
      cooldownEpochs: 1,
    };
    const rules = {
      ownLtvBps: 9_000,
      ownRateBps: 300,
      perLoanMaxBps: 5_000,
      fastLaneBps: 3_000,
      penaltyBps: 1_000,
      contribFineBps: 100,
      installFineBps: 300,
      exitFeeBps: 300,
      managerFeeBps: 0,
      alloc: { loan: 4_000, aave: 3_000, lp: 2_000, cash: 1_000 },
    };
    const invites = [
      u,
      bots.C.address,
      bots.D.address,
      bots.E.address,
      bots.F.address,
    ];
    const r = await c.send(bots.B, c.factory, abis.factory, "createCircle", [
      `${PRACTICE_PREFIX} (${userName})`,
      fixed,
      rules,
      invites,
    ]);
    const [ev] = parseEventLogs({
      abi: abis.factory,
      logs: r.logs,
      eventName: "CircleCreated",
    }) as unknown as {
      args: { circle: Address };
    }[];
    const circle = ev.args.circle;
    for (const l of ["C", "D", "E", "F"] as const)
      await c.send(bots[l], circle, abis.circle, "join");
    for (const l of BOT_LETTERS)
      await c.send(bots[l], c.usdc, abis.usdc, "approve", [
        circle,
        5_000n * USDC,
      ]);
    const names: Names = new Map(
      BOT_LETTERS.map((l) => [bots[l].address.toLowerCase(), BOTS[l]]),
    );
    names.set(u.toLowerCase(), userName);
    practice.set(circle.toLowerCase(), names);
    return {
      user: u,
      circle,
      bots,
      names,
      stepIndex: 0,
      lastChange: null,
      before: await readFacts(circle, u),
      userLoan: 0,
      daveLoan: 0,
      proposal: 0,
      running: null,
    };
  };

  const view = (t: Tutorial, f: Facts) => {
    const s = STEPS[t.stepIndex];
    return {
      circle: t.circle,
      done: t.stepIndex === STEPS.length - 1,
      chapter: s.chapter,
      chapters: CHAPTERS,
      stepIndex: t.stepIndex,
      stepCount: STEPS.length,
      step: {
        id: s.id,
        title: s.title,
        body: s.body(f, t),
        action: s.action ? s.action(f, t) : null,
        waitNote: s.waitNote,
      },
      lastChange: t.lastChange,
      snapshot: toSnapshot(f, t.names, true),
    };
  };

  /** Verifies the user's action, runs the server's part, moves on. One run per user at a time; a failure does not advance. */
  const next = (t: Tutorial, stepId?: string) => {
    if (t.running) return t.running as Promise<TutorialState>;
    const run = c.locked(async () => {
      const s = STEPS[t.stepIndex];
      const f = await readFacts(t.circle, t.user);
      // A repeated click for a step that already finished: nothing to do.
      if ((stepId && stepId !== s.id) || t.stepIndex === STEPS.length - 1)
        return view(t, f);
      const missing = s.check?.(f, t);
      if (missing) throw new HttpError(409, missing);
      await s.run?.(e, t, f);
      const a = await readFacts(t.circle, t.user);
      t.lastChange = s.change(t.before, a, t);
      t.before = a;
      t.stepIndex += 1;
      return view(t, a);
    });
    t.running = run;
    return run.finally(() => {
      t.running = null;
    });
  };

  return {
    practice,
    create: (u: Address, name: string) => c.locked(() => create(u, name)),
    view: async (t: Tutorial) => view(t, await readFacts(t.circle, t.user)),
    next,
  };
};
