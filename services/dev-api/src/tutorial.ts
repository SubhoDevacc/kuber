// The practice-circle tutorial: SPEC §4 / contracts S1 (BackingTestBase._s1Run) with the user as member A and five
// bots. Steps are data; the server does the bots' part, moves chain time on the circle's own clock, and settles.
import {
  type Address,
  encodeAbiParameters,
  maxUint256,
  parseEventLogs,
  zeroHash,
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
const BOTS = {
  B: "Bala",
  C: "Chitra",
  D: "Dev",
  E: "Esha",
  F: "Farhan",
} as const;
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
export type Change = {
  title: string;
  rows: Row[];
  note: string | null;
  /** The real transactions the server sent during the step, in order (practice members, admin, settlements). */
  txs?: { label: string; hash: `0x${string}` }[];
  /** The step's public record on Avalanche Fuji (KuberPracticeLog), null when there is none. */
  record?: PublicRecord | null;
};
export type PublicRecord = {
  chain: "Avalanche Fuji";
  hash: `0x${string}`;
  url: string;
};
/** Sends one step's record to the Fuji server; resolves to the Fuji transaction hash, or null. */
export type Recorder = (entry: {
  user: Address;
  practiceCircle: Address;
  step: string;
  actions: { label: string; practiceTx: `0x${string}` }[];
}) => Promise<`0x${string}` | null>;
type Action = {
  label: string;
  target: "usdc" | "circle" | "factory";
  functionName: string;
  // Digit-only strings are uints (also inside objects: createCircle's tuples are objects).
  args: (string | number | boolean | string[] | Record<string, unknown>)[];
};
type Choice = "join" | "create";
const OPTIONS = [
  {
    value: "join",
    label: "Join a circle",
    description:
      "Bala has started a practice circle and invited you. Join it with the other practice members.",
  },
  {
    value: "create",
    label: "Create a circle",
    description:
      "Start the practice circle yourself with one real transaction, then the five practice members join you.",
  },
];

export type Tutorial = {
  user: Address;
  circle: Address;
  bots: Record<Bot, PrivateKeyAccount>;
  names: Names;
  stepIndex: number;
  lastChange: Change | null;
  before: Facts;
  userLoan: number;
  devLoan: number;
  proposal: number;
  /** Round 3, item 9: Chitra's proposal to make Bala the fund manager (0% fee, so no money changes). */
  managerProposal: number;
  running: Promise<unknown> | null;
  /** "join" (Bala's circle, default) or "create" (the user's own circle); null until the first step is done. */
  path: Choice | null;
  createArgs: Action["args"] | null;
  createFrom: bigint;
  /** Last block of the previous step: the user's own transaction for a step is after it. */
  mark: bigint;
};

type Engine = ReturnType<typeof engine>;
type Step = {
  id: string;
  /** Only on this path (absent: both). */
  path?: Choice;
  options?: typeof OPTIONS;
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
/** "80.00" (money without the unit). */
const plainMoney = (v: bigint) => money(v).replace(" mUSDC", "");
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

const joinChange = (b: Facts, a: Facts): Change => ({
  title: "The circle started",
  rows: [
    row("Members", String(b.members.length), String(a.members.length), "good"),
    row("Circle", roundLabel(b), roundLabel(a), "good"),
    mrow("Saved in the circle", potTotal(b), potTotal(a), "good"),
  ],
  note: "The others paid round 1 right away. Yours is collected when the round closes.",
});

const STEPS: Step[] = [
  {
    id: "start",
    chapter: 1,
    title: "Join or create a circle",
    body: () =>
      "Every circle is started by one person, who invites the others. Join the practice circle Bala started, or create your own and the practice members join you. Either way the story and the numbers are the same.",
    action: null,
    options: OPTIONS,
    waitNote: "Getting your practice circle ready…",
    change: (_b, _a, t) => ({
      title:
        t.path === "create"
          ? "You will create the circle"
          : "You will join Bala's circle",
      rows: [
        row(
          "Your practice circle",
          "Not chosen",
          t.path === "create" ? "Started by you" : "Started by Bala",
          "good",
        ),
      ],
      note:
        t.path === "create"
          ? "Next you send the transaction that creates the circle on your practice chain."
          : "Bala, Chitra, Dev, Esha and Farhan are already in it.",
    }),
  },
  {
    id: "create",
    path: "create",
    chapter: 1,
    title: "Create your circle",
    body: (f) =>
      `Create the practice circle: everyone saves ${money(f.contribution)} (test money) each round for ${f.totalRounds} rounds, and you invite Bala, Chitra, Dev, Esha and Farhan. This is one real transaction.`,
    action: (_f, t) => ({
      label: "Create the circle",
      target: "factory",
      functionName: "createCircle",
      args: t.createArgs ?? [],
    }),
    waitNote: "Bala, Chitra, Dev, Esha and Farhan are joining…",
    change: (_b, a) => ({
      title: "Your circle is ready",
      rows: [
        row("Your circle", "Not created", "Created", "good"),
        row("Members", "1", String(a.members.length), "good"),
        row("Circle", "Not created", roundLabel(a), "plain"),
      ],
      note: "You created the circle, so you are already a member. The five practice members joined after your invite.",
    }),
  },
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
    path: "join",
    chapter: 1,
    title: "Join the circle",
    body: () =>
      "Bala started this practice circle and invited you, Chitra, Dev, Esha and Farhan. They have all joined. Join too, and the circle starts with 6 people.",
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
    change: joinChange,
  },
  {
    id: "begin",
    path: "create",
    chapter: 1,
    title: "Start the circle",
    body: () =>
      "Bala, Chitra, Dev, Esha and Farhan have joined your circle. At its start time the circle starts with 6 people.",
    action: null,
    waitNote: "Starting the circle…",
    run: async (e, t) => {
      await e.toRound(t, 1);
      await e.admin(t.circle, "activate", [], BIG_GAS);
      await e.payBots(t, BOT_LETTERS);
    },
    change: joinChange,
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
      // Round 3 is paid up front by every bot (Dev must have 3 rounds saved before he can borrow).
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
      "Ask for 350, paid back over 2 rounds. Up to 270 can come from your own 300 of savings. The other 80 needs a backer: Bala will back you by putting 80 of his savings on hold for your loan, at the 8% interest you offer. Bala could lose up to 80.00 · Bala earns 6.40.",
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
    waitNote: "Bala is backing you, and round 3 is closing…",
    run: async (e, t, f) => {
      const me = user(f, t);
      t.userLoan = me?.pendingRequestId || me?.activeLoanId || 0;
      await e.bot(t, "D", "requestLoan", [350n * USDC, 3n, 800n, 0n]);
      const devM = await e.member(t, "D");
      t.devLoan = devM.pendingRequestId;
      await e.bot(t, "B", "vouch", [BigInt(t.userLoan), 80n * USDC]);
      await e.bot(t, "C", "vouch", [BigInt(t.devLoan), 30n * USDC]);
      await e.bot(t, "E", "agree", [BigInt(t.devLoan), 50n * USDC]);
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
          mrow("Backed by Bala", 0n, l?.backedNeed ?? 0n, "good"),
          mrow(
            "Bala's savings on hold",
            n0(who(b, t, "B"), "pledgedOut"),
            n0(who(a, t, "B"), "pledgedOut"),
          ),
          // Item 5: the backer's risk and reward in money (couldLose = the pledge; earns = pledge x offered rate).
          ...(l?.vouchers[0]
            ? [
                row(
                  "Bala's risk for backing you",
                  "None",
                  `Bala could lose up to ${plainMoney(l.vouchers[0].amount)} · Bala earns ${plainMoney((l.vouchers[0].amount * BigInt((l as { offeredRateBps?: number }).offeredRateBps ?? 800)) / 10_000n)}`,
                  "plain",
                ),
              ]
            : []),
        ],
        note: "Loans are paid out when a round closes. Dev also borrowed 350, backed by Chitra and Esha.",
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
      // R-I: Dev takes his loan, then removes his permission, so nothing more can be collected from him.
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
            "Dev's round 4 savings",
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
      const kabir = l.vouchers[0]?.interest ?? 0n;
      return `This round you pay your savings plus the first repayment of ${money(installmentOf(l))}: ${money(l.amount / n)} of the loan, ${money(l.saverInterest / n)} interest for all savers, and ${money(kabir / n)} for Bala for backing you.`;
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
          "Bala earned for backing you",
          n0(who(b, t, "B"), "rewards"),
          n0(who(a, t, "B"), "rewards"),
          "good",
        ),
        row(
          "Dev",
          memberStatus(who(b, t, "D")),
          memberStatus(who(a, t, "D")),
          "bad",
        ),
      ],
      note: "Paying on time keeps you on track. Dev paid nothing, so he is now behind on his loan.",
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
      // Round 3, item 9: Chitra suggests Bala as fund manager (one proposal per member per round, so not Bala).
      await e.bot(t, "C", "propose", [
        2,
        encodeAbiParameters([{ type: "address" }], [t.bots.B.address]),
      ]);
      t.managerProposal = Number((await e.state(t)).proposalCount);
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
          "Bala earned for backing you",
          n0(who(b, t, "B"), "rewards"),
          n0(who(a, t, "B"), "rewards"),
          "good",
        ),
        mrow(
          "Bala's savings on hold",
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
      note: "Bala earned interest for trusting you, and his savings are free again.",
    }),
  },
  {
    id: "manager",
    chapter: 4,
    title: "Vote in a fund manager",
    body: () =>
      "Chitra suggests making Bala the circle's fund manager. A fund manager suggests how the pot is invested (the money plan: ready to lend, Aave, LP pool, cash), and everyone still votes on each plan. Bala's fee stays 0%, so nobody's money changes. Vote yes to make Bala the fund manager.",
    action: (_f, t) => ({
      label: "Vote yes",
      target: "circle",
      functionName: "vote",
      args: [String(t.managerProposal), true],
    }),
    check: (f, t) =>
      f.proposals.find((p) => p.id === t.managerProposal)?.youVoted
        ? null
        : "Your vote isn't in yet. Press “Vote yes”, wait until it is confirmed, then continue.",
    waitNote: "Recording the votes…",
    run: async (e, t) => {
      await e.bot(t, "B", "vote", [BigInt(t.managerProposal), true]);
      await e.bot(t, "C", "vote", [BigInt(t.managerProposal), true]);
      await e.bot(t, "E", "vote", [BigInt(t.managerProposal), true]);
      await e.bot(t, "F", "vote", [BigInt(t.managerProposal), true]);
    },
    change: (b, a, t) => {
      const pb = b.proposals.find((p) => p.id === t.managerProposal);
      const pa = a.proposals.find((p) => p.id === t.managerProposal);
      return {
        title: "Your vote is in",
        rows: [
          row("Yes votes", String(pb?.yes ?? 0), String(pa?.yes ?? 0), "good"),
          row("No votes", String(pb?.no ?? 0), String(pa?.no ?? 0)),
          row("Fund manager", "None", "Bala, when round 6 closes", "plain"),
        ],
        note: "More than half of the members said yes. Like every change, it applies when the round closes.",
      };
    },
  },
  {
    id: "vote",
    chapter: 4,
    title: "Vote on a rule",
    body: (f) =>
      `Bala suggests lowering the fee for leaving the circle early from ${pct(f.exitFeeBps)} to 2%. It passes if more than half of the ${f.members.length} members vote yes. Nobody is leaving this circle, so it changes no one's money here.`,
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
            "Fund manager",
            b.manager
              ? (t.names.get(b.manager.address.toLowerCase()) ?? "Bala")
              : "None",
            a.manager
              ? (t.names.get(a.manager.address.toLowerCase()) ?? "Bala")
              : "None",
            "good",
          ),
          row(
            "Dev",
            memberStatus(who(b, t, "D")),
            memberStatus(who(a, t, "D")),
            "bad",
          ),
        ],
        note: passed
          ? `More than half of the members said yes, so the rule changed when round 6 closed.${a.manager ? " Bala is now the fund manager (fee 0%)." : ""}`
          : "Not enough members said yes, so the rule stayed the same.",
      };
    },
  },
  {
    id: "default",
    chapter: 5,
    title: "Dev stops paying",
    body: () =>
      "Dev borrowed 350 and has paid nothing back: he is 2 repayments behind. When the last round closes, the circle takes what he owes from his own savings first. Only what is still missing comes from the people who backed him.",
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
      const d = loan(a, t.devLoan);
      const lostC = n0(who(a, t, "C"), "lost");
      const lostE = n0(who(a, t, "E"), "lost");
      const fromDev = (d?.amount ?? 0n) - lostC - lostE;
      return {
        title: "Dev's loan was covered",
        rows: [
          mrow(
            "Dev's savings",
            n0(who(b, t, "D"), "savings"),
            n0(who(a, t, "D"), "savings"),
            "bad",
          ),
          mrow(
            "Chitra lost (she backed Dev)",
            n0(who(b, t, "C"), "lost"),
            lostC,
            "bad",
          ),
          mrow(
            "Esha lost (she backed Dev)",
            n0(who(b, t, "E"), "lost"),
            lostE,
            "bad",
          ),
          mrow(
            "Farhan lost",
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
            "Dev still owes",
            n0(who(b, t, "D"), "debt"),
            n0(who(a, t, "D"), "debt"),
            "bad",
          ),
          row("Circle", roundLabel(b), roundLabel(a)),
        ],
        note: `Dev's own savings paid ${money(fromDev)} first; only the people who backed him covered the rest (Chitra ${money(lostC)}, Esha ${money(lostE)}). Farhan and you lost nothing.`,
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
          share("B", "Bala's share-out"),
          share("C", "Chitra's share-out"),
          share("D", "Dev's share-out"),
          share("E", "Esha's share-out"),
          share("F", "Farhan's share-out"),
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

const BOT_LABEL = (
  t: Tutorial,
  l: Bot,
  fn: string,
  args: readonly unknown[],
) => {
  const n = BOTS[l];
  if (fn === "payNow") return `${n} paid this round's savings`;
  if (fn === "vouch" || fn === "agree")
    return Number(args[0]) === t.userLoan
      ? `${n} backed your loan`
      : `${n} backed Dev's loan`;
  if (fn === "requestLoan")
    return `${n} asked to borrow ${money(args[0] as bigint)}`;
  if (fn === "claim") return `${n} took the loan`;
  if (fn === "vote") return `${n} voted ${args[1] ? "yes" : "no"}`;
  if (fn === "propose")
    return args[0] === 2
      ? `${n} proposed making Bala the fund manager`
      : `${n} proposed a rule change`;
  if (fn === "withdraw") return `${n} collected the share-out`;
  if (fn === "join") return `${n} joined`;
  return `${n}: ${fn}`;
};

const engine = (c: Chain) => {
  const { abis } = c;
  /** Transactions of the step being run (next() runs one at a time under the chain lock). */
  let txs: { label: string; hash: `0x${string}` }[] | null = null;
  const rec = <R extends { transactionHash: `0x${string}` }>(
    label: string,
    r: R,
  ) => {
    txs?.push({ label, hash: r.transactionHash });
    return r;
  };
  const state = (t: Tutorial) =>
    c.read<{
      status: number;
      currentEpoch: bigint;
      settledEpoch: bigint;
      proposalCount: bigint;
    }>(t.circle, abis.circle, "getCircleState");
  const ADMIN_LABEL: Record<string, string> = {
    activate: "The circle started",
    mint: "The circle's investments paid out their earnings",
  };
  return {
    chain: c,
    state,
    begin: () => {
      txs = [];
    },
    end: () => {
      const out = txs ?? [];
      txs = null;
      return out;
    },
    admin: async (
      to: Address,
      fn: string,
      args: readonly unknown[] = [],
      gas?: bigint,
      abi: "circle" | "usdc" | "registry" = "circle",
    ) =>
      rec(
        ADMIN_LABEL[fn] ?? fn,
        await c.send(c.admin, to, abis[abi], fn, args, gas),
      ),
    bot: async (
      t: Tutorial,
      l: Bot,
      fn: string,
      args: readonly unknown[] = [],
    ) =>
      rec(
        BOT_LABEL(t, l, fn, args),
        await c.send(t.bots[l], t.circle, abis.circle, fn, args),
      ),
    botUsdc: async (
      t: Tutorial,
      l: Bot,
      fn: string,
      args: readonly unknown[],
    ) =>
      rec(
        fn === "approve" && args[1] === 0n
          ? `${BOTS[l]} stopped paying (took back the circle's permission)`
          : `${BOTS[l]} allowed the circle to collect savings`,
        await c.send(t.bots[l], c.usdc, abis.usdc, fn, args),
      ),
    member: (t: Tutorial, l: Bot) =>
      c.read<{ pendingRequestId: number }>(t.circle, abis.circle, "getMember", [
        t.bots[l].address,
      ]),
    payBots: async (t: Tutorial, ls: Bot[]) => {
      for (const l of ls)
        rec(
          BOT_LABEL(t, l, "payNow", []),
          await c.send(t.bots[l], t.circle, abis.circle, "payNow"),
        );
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
        rec(
          `Round ${s.settledEpoch + 1n} closed and settled`,
          await c.send(
            c.admin,
            t.circle,
            abis.circle,
            "settle",
            [maxUint256],
            BIG_GAS,
          ),
        );
      }
    },
  };
};

// ---------- the S1 circle's parameters (also the "Create a circle" transaction's)

const RULES = {
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

// ---------- public API

export type TutorialState = Awaited<ReturnType<Tutorials["view"]>>;
export type Tutorials = ReturnType<typeof tutorials>;

export const tutorials = (
  c: Chain,
  readFacts: (circle: Address, u: Address | null) => Promise<Facts>,
  recorder: Recorder | null = null,
) => {
  const e = engine(c);
  /** Fuji records: lowercase practice-chain tx hash -> the record of the step it belongs to. */
  const records = new Map<string, PublicRecord>();
  const cut = (s: string) => (s.length > 120 ? `${s.slice(0, 119)}…` : s);
  /** The user's latest transaction since the previous step (a few blocks on Anvil), else null. */
  const userTx = async (t: Tutorial) => {
    const latest = await c.pub.getBlockNumber({ cacheTime: 0 });
    for (let b = latest; b > t.mark && latest - b < 50n; b--) {
      const blk = await c.pub.getBlock({
        blockNumber: b,
        includeTransactions: true,
      });
      const tx = blk.transactions.find(
        (x) => x.from.toLowerCase() === t.user.toLowerCase(),
      );
      if (tx) return tx.hash;
    }
    return null;
  };
  /** One Fuji record per finished step; waits for it to confirm (30 s at most); any failure just means no record. */
  const record = async (
    t: Tutorial,
    circle: Address,
    title: string,
    own: `0x${string}` | null,
    change: Change,
  ) => {
    if (!recorder) return;
    const actions = [
      ...(own ? [{ label: cut(title), practiceTx: own }] : []),
      ...(change.txs ?? []).map((x) => ({
        label: cut(x.label),
        practiceTx: x.hash,
      })),
    ].slice(0, 20);
    if (actions.length === 0)
      actions.push({ label: cut(title), practiceTx: zeroHash });
    const hash = await Promise.race([
      recorder({
        user: t.user,
        practiceCircle: circle,
        step: cut(title),
        actions,
      }),
      new Promise<null>((ok) => setTimeout(() => ok(null), 30_000).unref()),
    ]).catch(() => null);
    if (!hash) return;
    const r: PublicRecord = {
      chain: "Avalanche Fuji",
      hash,
      url: `https://testnet.snowtrace.io/tx/${hash}`,
    };
    change.record = r;
    for (const a of actions)
      if (a.practiceTx !== zeroHash) records.set(a.practiceTx.toLowerCase(), r);
  };
  const { abis } = c;
  const fixedParams = async () => ({
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
  });
  /** Practice circles: lowercase circle -> display names of its members. */
  const practice = new Map<string, Names>();

  /** Five fresh bots (verified, gas, 10,000 mUSDC), Bala creates the S1 circle inviting the user, the rest join. */
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
    const fixed = await fixedParams();
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
      RULES,
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
      devLoan: 0,
      proposal: 0,
      managerProposal: 0,
      running: null,
      path: null,
      createArgs: null,
      createFrom: 0n,
      mark: await c.pub.getBlockNumber({ cacheTime: 0 }),
    };
  };

  /** "Create a circle": the practice members join the user's own circle and allow their savings. */
  const adopt = async (t: Tutorial) => {
    const found = (await c.pub.getContractEvents({
      address: c.factory,
      abi: abis.factory,
      eventName: "CircleCreated",
      args: { creator: t.user },
      fromBlock: t.createFrom,
    } as never)) as unknown as { args: { circle: Address } }[];
    const circle = found.at(-1)?.args.circle;
    if (!circle)
      throw new HttpError(
        409,
        "We can't see your new circle yet. Press “Create the circle”, wait until it is confirmed, then continue.",
      );
    const old = t.circle;
    t.circle = circle;
    for (const l of BOT_LETTERS) await e.bot(t, l, "join");
    for (const l of BOT_LETTERS)
      await e.botUsdc(t, l, "approve", [circle, 5_000n * USDC]);
    // Bala's circle stays behind unused; it is no longer the user's (a copy of the names without the user).
    const left = new Map(t.names);
    left.delete(t.user.toLowerCase());
    practice.set(old.toLowerCase(), left);
    practice.set(circle.toLowerCase(), t.names);
  };

  /** Next step index on the user's path. */
  const onPath = (t: Tutorial, i: number) =>
    !STEPS[i].path || STEPS[i].path === (t.path ?? "join");
  const after = (t: Tutorial, i: number) => {
    let j = i + 1;
    while (j < STEPS.length - 1 && !onPath(t, j)) j++;
    return j;
  };

  const view = (t: Tutorial, f: Facts) => {
    const s = STEPS[t.stepIndex];
    const path = STEPS.map((_, i) => i).filter((i) => onPath(t, i));
    return {
      circle: t.circle,
      done: t.stepIndex === STEPS.length - 1,
      chapter: s.chapter,
      chapters: CHAPTERS,
      choice: t.path,
      stepIndex: path.indexOf(t.stepIndex),
      stepCount: path.length,
      step: {
        id: s.id,
        title: s.title,
        body: s.body(f, t),
        action: s.action ? s.action(f, t) : null,
        ...(s.options ? { options: s.options } : {}),
        waitNote: s.waitNote,
      },
      lastChange: t.lastChange,
      snapshot: toSnapshot(f, t.names, true),
    };
  };

  /** Verifies the user's action, runs the server's part, moves on. One run per user at a time; a failure does not advance. */
  const next = (t: Tutorial, stepId?: string, choice?: Choice) => {
    if (t.running) return t.running as Promise<TutorialState>;
    let done: { title: string; own: `0x${string}` | null } | null = null;
    const locked = c.locked(async () => {
      const s = STEPS[t.stepIndex];
      const f = await readFacts(t.circle, t.user);
      // A repeated click for a step that already finished: nothing to do.
      if ((stepId && stepId !== s.id) || t.stepIndex === STEPS.length - 1)
        return view(t, f);
      const missing = s.check?.(f, t);
      if (missing) throw new HttpError(409, missing);
      const own =
        recorder && s.action ? await userTx(t).catch(() => null) : null;
      e.begin();
      try {
        if (s.id === "start") {
          // No choice (an older client) means "join", today's path.
          t.path = choice ?? "join";
          if (t.path === "create") {
            t.createFrom = await c.pub.getBlockNumber({ cacheTime: 0 });
            const fixed = await fixedParams();
            t.createArgs = [
              `${PRACTICE_PREFIX} (${t.names.get(t.user.toLowerCase()) ?? "you"})`,
              {
                ...fixed,
                contribution: fixed.contribution.toString(),
                startTime: fixed.startTime.toString(),
              },
              RULES,
              BOT_LETTERS.map((l) => t.bots[l].address),
            ];
          }
        }
        if (s.id === "create") await adopt(t);
        await s.run?.(e, t, f);
      } catch (err) {
        e.end();
        throw err;
      }
      const a = await readFacts(t.circle, t.user);
      t.lastChange = {
        ...s.change(t.before, a, t),
        txs: e.end(),
        record: null,
      };
      t.before = a;
      t.mark = await c.pub.getBlockNumber({ cacheTime: 0 });
      t.stepIndex = after(t, t.stepIndex);
      done = { title: s.title, own };
      return view(t, a);
    });
    // Outside the chain lock: the Fuji record never holds up the practice chain (30 s at most).
    const run = locked.then(async (v) => {
      if (done && v.lastChange)
        await record(t, v.circle, done.title, done.own, v.lastChange);
      return v;
    });
    t.running = run;
    return run.finally(() => {
      t.running = null;
    });
  };

  return {
    practice,
    create: (u: Address, name: string) => c.locked(() => create(u, name)),
    factory: c.factory,
    view: async (t: Tutorial) => view(t, await readFacts(t.circle, t.user)),
    next,
    records,
  };
};
