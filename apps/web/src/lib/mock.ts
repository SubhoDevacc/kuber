// In-browser stand-in for services/dev-api, switched on by VITE_MOCK_API=1.
// It replays the SPEC §4 story (the user is A) with the same shapes the real server returns.
import type {
  CircleSnapshot,
  CircleSummary,
  Hex,
  LastChange,
  Member,
  TutorialState,
} from "../types";
import { ApiError } from "./errors";
import { formatAmount } from "./money";

export const MOCK = import.meta.env.VITE_MOCK_API === "1";

const M = 1_000_000n;
const CIRCLE: Hex = "0x5FbDB2315678afecb367f032d93F642f64180aa3";
const STORE = "kuber.mock";
const CHAPTERS = [
  "Join and save",
  "Borrow",
  "Repay",
  "Vote",
  "A member stops paying",
  "Share-out",
];

type Model = {
  status: CircleSnapshot["status"];
  round: number;
  wallet: bigint;
  claimable: bigint;
  rewards: bigint;
  earned: bigint;
  members: (Omit<
    Member,
    "savings" | "loanOwed" | "pledged" | "lost" | "debt"
  > & {
    savings: bigint;
    loanOwed: bigint;
    pledged: bigint;
    lost: bigint;
    debt: bigint;
  })[];
  loans: CircleSnapshot["loans"];
  proposals: CircleSnapshot["proposals"];
  /** The fund manager's name, or null. */
  manager: string | null;
};

type Step = {
  chapter: number;
  id: string;
  title: string;
  body: string;
  action: TutorialState["step"]["action"];
  waitNote: string | null;
  apply: (m: Model) => LastChange;
};

const f = (v: bigint) => `${formatAmount(v)} mUSDC`;
const row = (
  label: string,
  before: string,
  after: string,
  tone: "good" | "bad" | "plain" = "plain",
) => ({ label, before, after, tone });
const by = (m: Model, name: string) => {
  const found = m.members.find(
    (x) => x.name === name || (name === "you" && x.you),
  );
  if (!found) throw new Error(name);
  return found;
};
const saveRound = (m: Model, skip: string[] = []) => {
  for (const x of m.members) {
    if (
      skip.includes(x.name) ||
      x.status === "Paused" ||
      x.status === "Not joined yet"
    )
      continue;
    x.savings += 100n * M;
    if (x.you) m.wallet -= 100n * M;
  }
};

const steps: Step[] = [
  {
    chapter: 1,
    id: "intro",
    title: "Meet your practice circle",
    body: "Six people each save 100 test mUSDC per round, for 7 rounds. Bala, Chitra, Dev, Esha and Farhan are practice members run by Kuber. The empty seat is yours.",
    action: null,
    waitNote: null,
    apply: () => ({
      title: "Your seat is waiting",
      rows: [row("Seats taken", "5 of 6", "5 of 6")],
      note: "Nothing has changed yet. Next, you let the circle collect your savings.",
    }),
  },
  {
    chapter: 1,
    id: "approve",
    title: "Let the circle collect your savings",
    body: "Before you join, allow the circle to take your 100 at the start of each round. You can see every payment here.",
    action: {
      label: "Allow payments",
      target: "usdc",
      functionName: "approve",
      args: [CIRCLE, "1000000000"],
    },
    waitNote: null,
    apply: () => ({
      title: "Payments allowed",
      rows: [row("The circle can collect", f(0n), f(1000n * M))],
      note: "Nothing has left your wallet yet.",
    }),
  },
  {
    chapter: 1,
    id: "join",
    title: "Join the circle",
    body: "Take the sixth seat. The circle starts as soon as all six have joined.",
    action: {
      label: "Join the circle",
      target: "circle",
      functionName: "join",
      args: [],
    },
    waitNote: "The circle is starting…",
    apply: (m) => {
      m.status = "Active";
      m.round = 1;
      for (const x of m.members) x.status = "On track";
      return {
        title: "You're in",
        rows: [
          row("Seats taken", "5 of 6", "6 of 6", "good"),
          row("Circle", "Waiting to start", "Round 1 of 7", "good"),
        ],
        note: "From now on everyone saves 100 at the start of each round.",
      };
    },
  },
  {
    chapter: 1,
    id: "pay-1",
    title: "Save your first 100",
    body: "Pay this round's 100 now. Paying early is fine; anything unpaid is collected when the round closes.",
    action: {
      label: "Pay 100 now",
      target: "circle",
      functionName: "payNow",
      args: [],
    },
    waitNote: "Round 1 is closing…",
    apply: (m) => {
      const w = m.wallet;
      saveRound(m);
      m.round = 2;
      return {
        title: "Round 1 closed",
        rows: [
          row("Your savings", f(0n), f(100n * M), "good"),
          row("Your wallet", f(w), f(m.wallet)),
          row("The pot", f(0n), f(600n * M), "good"),
        ],
        note: "All six paid, so the pot holds 600.",
      };
    },
  },
  {
    chapter: 1,
    id: "rounds-2-3",
    title: "Two more rounds",
    body: "Rounds 2 and 3 close next. Everyone pays 100 each time, and the group invests part of the pot so it earns while it waits.",
    action: null,
    waitNote: "Rounds 2 and 3 are closing…",
    apply: (m) => {
      saveRound(m);
      saveRound(m);
      m.round = 3;
      return {
        title: "Your savings grew",
        rows: [
          row("Your savings", f(100n * M), f(300n * M), "good"),
          row("The pot", f(600n * M), f(1800n * M), "good"),
          row("Put to work", f(360n * M), f(1080n * M), "good"),
        ],
        note: "40% of the pot is kept ready for loans. The rest is invested, and what it earns is shared at the end.",
      };
    },
  },
  {
    chapter: 2,
    id: "request-loan",
    title: "Ask for a loan of 350",
    body: "You can borrow up to 90% of your own savings: 270. The other 80 needs someone to back you, and Bala has said yes.",
    action: {
      label: "Ask to borrow 350",
      target: "circle",
      functionName: "requestLoan",
      args: ["350000000", "2", "800", "0"],
    },
    waitNote: null,
    apply: (m) => {
      m.loans.push(
        {
          id: 1,
          borrower: by(m, "you").name,
          amount: "350000000",
          status: "Needs backing",
          backers: [],
        },
        {
          id: 2,
          borrower: "Dev",
          amount: "350000000",
          status: "Needs backing",
          backers: [],
        },
      );
      return {
        title: "Loan requested",
        rows: [
          row("From your savings", f(0n), f(270n * M)),
          row("Needs backing", f(0n), f(80n * M)),
          row(
            "Bala's risk for backing you",
            "—",
            "Bala could lose up to 80.00 · Bala earns 6.40",
          ),
        ],
        note: "Dev asked for 350 too.",
      };
    },
  },
  {
    chapter: 2,
    id: "backed",
    title: "Bala backs your loan",
    body: "Bala puts 80 of his savings behind you. If you don't repay, he covers up to 80. If you do, he earns 6.40 for taking the risk.",
    action: null,
    waitNote: "Bala is backing you, then round 3 closes…",
    apply: (m) => {
      by(m, "Bala").pledged = 80n * M;
      by(m, "Chitra").pledged = 30n * M;
      by(m, "Esha").pledged = 50n * M;
      by(m, "Bala").role = "Backer";
      by(m, "Chitra").role = "Backer";
      by(m, "Esha").role = "Backer";
      by(m, "you").role = "Borrower";
      by(m, "Dev").role = "Borrower";
      m.loans[0].backers = [
        { name: "Bala", amount: "80000000", earned: "0", lost: "0" },
      ];
      m.loans[1].backers = [
        { name: "Chitra", amount: "30000000", earned: "0", lost: "0" },
        { name: "Esha", amount: "50000000", earned: "0", lost: "0" },
      ];
      m.loans[0].status = "Ready to collect";
      m.loans[1].status = "Repaying";
      by(m, "Dev").loanOwed = 364_500_000n;
      m.claimable = 350n * M;
      m.round = 4;
      return {
        title: "Your loan was approved",
        rows: [
          row("Needs backing", f(80n * M), f(0n), "good"),
          row("Bala's backing", f(0n), f(80n * M)),
          row("Your loan", "Waiting", "Ready to collect", "good"),
        ],
        note: "Both loans fit in the money kept for loans, so both were approved when round 3 closed. Chitra and Esha back Dev.",
      };
    },
  },
  {
    chapter: 2,
    id: "claim",
    title: "Collect your loan",
    body: "Your 350 is ready. Move it to your wallet.",
    action: {
      label: "Collect 350",
      target: "circle",
      functionName: "claim",
      args: [],
    },
    waitNote: null,
    apply: (m) => {
      const w = m.wallet;
      m.wallet += 350n * M;
      m.claimable = 0n;
      by(m, "you").loanOwed = 364_500_000n;
      m.loans[0].status = "Repaying";
      return {
        title: "350 is in your wallet",
        rows: [
          row("Your wallet", f(w), f(m.wallet), "good"),
          row("You owe", f(0n), f(364_500_000n)),
        ],
        note: "You repay 364.50 in two parts: the 350, plus 8.10 for the group and 6.40 for Bala.",
      };
    },
  },
  {
    chapter: 3,
    id: "repay-1",
    title: "Pay back the first half",
    body: "This round you pay your 100 savings plus 182.25 of the loan.",
    action: {
      label: "Pay 282.25",
      target: "circle",
      functionName: "payNow",
      args: [],
    },
    waitNote: "Round 4 is closing…",
    apply: (m) => {
      const you = by(m, "you");
      saveRound(m, ["Dev"]);
      m.wallet -= 182_250_000n;
      you.loanOwed = 182_250_000n;
      by(m, "Dev").status = "1 payment behind";
      m.loans[0].backers[0].earned = "3200000";
      m.round = 5;
      return {
        title: "Half paid back",
        rows: [
          row("You owe", f(364_500_000n), f(182_250_000n), "good"),
          row("Your savings", f(300n * M), f(400n * M), "good"),
          row("Bala has earned", f(0n), f(3_200_000n), "good"),
        ],
        note: "Dev didn't pay this round. Keep an eye on him.",
      };
    },
  },
  {
    chapter: 3,
    id: "repay-2",
    title: "Pay off the loan",
    body: "Pay the last 182.25 together with this round's savings.",
    action: {
      label: "Pay 282.25",
      target: "circle",
      functionName: "payNow",
      args: [],
    },
    waitNote: "Round 5 is closing…",
    apply: (m) => {
      saveRound(m, ["Dev"]);
      m.wallet -= 182_250_000n;
      by(m, "you").loanOwed = 0n;
      by(m, "you").role = null;
      by(m, "Bala").pledged = 0n;
      by(m, "Bala").role = null;
      by(m, "Dev").status = "2 payments behind";
      m.loans[0].status = "Repaid";
      m.loans[0].backers[0].earned = "6400000";
      m.rewards = 0n;
      m.proposals.push(
        {
          id: 1,
          title: "Make Bala the fund manager",
          yes: 1,
          no: 0,
          status: "Voting",
          youVoted: false,
          kind: "manager",
        },
        {
          id: 2,
          title: "Keep the money plan as it is until the end",
          yes: 1,
          no: 0,
          status: "Voting",
          youVoted: false,
          kind: "rule",
        },
      );
      m.round = 6;
      return {
        title: "Loan repaid",
        rows: [
          row("You owe", f(182_250_000n), f(0n), "good"),
          row("Bala has earned", f(3_200_000n), f(6_400_000n), "good"),
          row("Bala's backing", f(80n * M), f(0n)),
        ],
        note: "Bala's 80 is free again, and he keeps 6.40 for backing you.",
      };
    },
  },
  {
    chapter: 4,
    id: "manager",
    title: "Vote in a fund manager",
    body: "Chitra suggests making Bala the circle's fund manager. A fund manager suggests how the pot is invested (the money plan: ready to lend, Aave, LP pool, cash), and everyone still votes on each plan. Bala's fee stays 0%, so nobody's money changes. Vote yes to make Bala the fund manager.",
    action: {
      label: "Vote yes",
      target: "circle",
      functionName: "vote",
      args: ["1", true],
    },
    waitNote: "Recording the votes…",
    apply: (m) => {
      Object.assign(m.proposals[0], { yes: 5, youVoted: true });
      return {
        title: "Your vote is in",
        rows: [
          row("Yes votes", "1", "5", "good"),
          row("No votes", "0", "0"),
          row("Fund manager", "None", "Bala, when round 6 closes"),
        ],
        note: "More than half of the members said yes. Like every change, it applies when the round closes.",
      };
    },
  },
  {
    chapter: 4,
    id: "vote",
    title: "Vote on Esha's idea",
    body: "Esha proposes keeping the money plan as it is until the circle ends. Every member gets one vote. This vote doesn't move anyone's money.",
    action: {
      label: "Vote yes",
      target: "circle",
      functionName: "vote",
      args: ["2", true],
    },
    waitNote: "Counting the votes…",
    apply: (m) => {
      Object.assign(m.proposals[0], { status: "Applied" });
      Object.assign(m.proposals[1], {
        yes: 5,
        no: 0,
        status: "Passed",
        youVoted: true,
      });
      m.manager = "Bala";
      return {
        title: "The vote passed",
        rows: [
          row("Your vote", "Not yet", "Yes"),
          row("Yes votes", "1 of 6", "5 of 6", "good"),
          row("Result", "Open", "Passed", "good"),
        ],
        note: "Each person's vote counts the same. Changes take effect when a round closes.",
      };
    },
  },
  {
    chapter: 5,
    id: "default-behind",
    title: "Dev is 2 payments behind",
    body: "Dev stopped paying, and he still owes his loan. He can catch up with a small fine. If he misses a third payment, he is paused.",
    action: null,
    waitNote: "Round 6 is closing…",
    apply: (m) => {
      saveRound(m, ["Dev"]);
      by(m, "Dev").status = "3 payments behind";
      m.round = 7;
      return {
        title: "Dev missed another payment",
        rows: [
          row("Dev", "2 payments behind", "3 payments behind", "bad"),
          row("Your savings", f(500n * M), f(600n * M), "good"),
        ],
        note: "Three missed payments means Dev is paused when this round closes.",
      };
    },
  },
  {
    chapter: 5,
    id: "default-paused",
    title: "Dev's loan is covered",
    body: "Dev is paused. His loan is covered in a fixed order: his own savings first, then the people who chose to back him. Nobody else pays.",
    action: null,
    waitNote: "Round 7 is closing…",
    apply: (m) => {
      saveRound(m, ["Dev"]);
      const dev = by(m, "Dev");
      dev.lost = 300n * M;
      dev.savings = 0n;
      dev.status = "Paused";
      dev.loanOwed = 0n;
      dev.debt = 106_749_998n;
      for (const [name, lost] of [
        ["Chitra", 30n],
        ["Esha", 20n],
      ] as const) {
        const x = by(m, name);
        x.lost = lost * M;
        x.savings -= lost * M;
        x.pledged = 0n;
      }
      m.loans[1].status = "Covered";
      m.loans[1].backers[0].lost = "30000000";
      m.loans[1].backers[1].lost = "20000000";
      m.status = "Completed";
      return {
        title: "Who paid for Dev's loan",
        rows: [
          row("Dev's savings", f(300n * M), f(0n), "bad"),
          row("Chitra lost (backed Dev)", f(0n), f(30n * M), "bad"),
          row("Esha lost (backed Dev)", f(0n), f(20n * M), "bad"),
          row("Farhan lost", f(0n), f(0n), "good"),
          row("You lost", f(0n), f(0n), "good"),
        ],
        note: "Only Dev and the two people who backed him lost money. Dev now owes 106.75, taken from anything Kuber pays him later.",
      };
    },
  },
  {
    chapter: 6,
    id: "share-out",
    title: "The circle has ended",
    body: "All 7 rounds are done. The savings and what the group earned are shared out by how much each person saved, and for how long.",
    action: null,
    waitNote: "Working out the share-out…",
    apply: (m) => {
      m.earned = 60n * M;
      m.claimable = 712_043_010n;
      return {
        title: "Your share-out is ready",
        rows: [
          row("Earned by the group", f(0n), f(60n * M), "good"),
          row("Your share-out", f(0n), f(712_043_010n), "good"),
        ],
        note: "You saved 700 and paid 14.50 in loan interest. You get 712.04 back.",
      };
    },
  },
  {
    chapter: 6,
    id: "withdraw",
    title: "Take your share-out",
    body: "Move your 712.04 to your wallet. That ends the practice circle.",
    action: {
      label: "Withdraw 712.04",
      target: "circle",
      functionName: "withdraw",
      args: [],
    },
    waitNote: null,
    apply: (m) => {
      const w = m.wallet;
      m.wallet += m.claimable;
      m.claimable = 0n;
      for (const x of m.members) x.savings = 0n;
      return {
        title: "Paid out",
        rows: [
          row("Your share-out", "Not paid", f(712_043_010n), "good"),
          row("Your wallet", f(w), f(m.wallet), "good"),
        ],
        note: "Bala got 720.48, Farhan 714.08, Esha 693.98 and Chitra 683.93. Dev got nothing and still owes 106.75.",
      };
    },
  },
];

type Saved = {
  name: string | null;
  step: number;
  started: boolean;
  txFor: string | null;
};

function load(): Saved {
  try {
    const raw = localStorage.getItem(STORE);
    if (raw) return JSON.parse(raw) as Saved;
  } catch {
    // fall through
  }
  return { name: null, step: 0, started: false, txFor: null };
}
const save = (s: Saved) => localStorage.setItem(STORE, JSON.stringify(s));

/** Called by the mock wallet so /tutorial/next can tell whether the step's action was "sent". */
export function mockNoteTx() {
  const s = load();
  s.txFor = steps[Math.min(s.step, steps.length - 1)].id;
  save(s);
}

function fresh(name: string, address: Hex): Model {
  const bot = (n: string, i: number) => ({
    address: `0x${(i + 1).toString(16).padStart(40, "b")}` as Hex,
    name: n,
    you: false,
    role: null,
    status: "Waiting to start",
    savings: 0n,
    loanOwed: 0n,
    pledged: 0n,
    lost: 0n,
    debt: 0n,
  });
  return {
    status: "Forming",
    round: 0,
    wallet: 20_000n * M,
    claimable: 0n,
    rewards: 0n,
    earned: 0n,
    members: [
      { ...bot(name, 9), address, you: true, status: "Not joined yet" },
      ...["Bala", "Chitra", "Dev", "Esha", "Farhan"].map(bot),
    ],
    loans: [],
    proposals: [],
    manager: null,
  };
}

function build(name: string, address: Hex, upTo: number) {
  const m = fresh(name, address);
  let last: LastChange | null = null;
  for (let i = 0; i < upTo; i++) last = steps[i].apply(m);
  return { m, last };
}

function snapshot(m: Model): CircleSnapshot {
  const total = m.members.reduce((a, x) => a + x.savings, 0n);
  const lent = m.members.reduce((a, x) => a + x.loanOwed, 0n);
  const invested = (total * 60n) / 100n;
  const cash =
    total + m.earned - invested - lent > 0n
      ? total + m.earned - invested - lent
      : 0n;
  const you = m.members.find((x) => x.you);
  const s = (v: bigint) => v.toString();
  return {
    address: CIRCLE,
    name: "Practice circle",
    practice: true,
    status: m.status,
    round: m.round,
    totalRounds: 7,
    contribution: "100000000",
    pot: {
      total: s(total + m.earned),
      cash: s(cash),
      invested: s(invested),
      lent: s(lent),
      earned: s(m.earned),
    },
    you: you
      ? {
          savings: s(you.savings),
          wallet: s(m.wallet),
          loanOwed: s(you.loanOwed),
          pledged: s(you.pledged),
          rewards: s(m.rewards),
          claimable: s(m.claimable),
          status: you.status,
        }
      : null,
    manager: (() => {
      const mgr = m.members.find((x) => x.name === m.manager);
      return mgr
        ? {
            address: mgr.address,
            name: mgr.name,
            roundsManaged: 0,
            averagePerRound: null,
          }
        : null;
    })(),
    members: m.members.map((x) => ({
      ...x,
      isManager: x.name === m.manager,
      savings: s(x.savings),
      loanOwed: s(x.loanOwed),
      pledged: s(x.pledged),
      lost: s(x.lost),
      debt: s(x.debt),
    })),
    loans: structuredClone(m.loans),
    proposals: structuredClone(m.proposals),
  };
}

function tutorial(saved: Saved, address: Hex): TutorialState {
  const name = saved.name ?? "You";
  const index = Math.min(saved.step, steps.length - 1);
  const { m, last } = build(name, address, saved.step);
  const step = steps[index];
  return {
    circle: CIRCLE,
    done: saved.step >= steps.length,
    chapter: step.chapter,
    chapters: CHAPTERS,
    stepIndex: index,
    stepCount: steps.length,
    step: {
      id: step.id,
      title: step.title,
      body: step.body,
      action: step.action,
      waitNote: step.waitNote,
    },
    lastChange: last ? { ...last, record: null } : null,
    snapshot: snapshot(m),
  };
}

class MockHttpError extends Error {
  status: number;
  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

const wait = (ms: number) => new Promise((r) => setTimeout(r, ms));

export async function mockApi(
  address: Hex,
  method: string,
  path: string,
  body: unknown,
) {
  const s = load();
  const me = () => ({
    address,
    name: s.name,
    verified: s.name !== null,
    musdc: s.name
      ? (snapshot(build(s.name, address, s.step).m).you?.wallet ?? "0")
      : "0",
    tutorial: s.started ? tutorial(s, address) : null,
  });
  try {
    await wait(350);
    const route = `${method} ${path}`;
    if (route === "GET /me") return me();
    if (route === "POST /onboard") {
      const name = String((body as { name?: string })?.name ?? "").trim();
      if (!/^[A-Za-z0-9 -]{3,24}$/.test(name)) {
        throw new MockHttpError(
          400,
          "Pick a name of 3 to 24 letters, numbers, spaces or dashes.",
        );
      }
      if (
        ["bala", "chitra", "dev", "esha", "farhan"].includes(name.toLowerCase())
      ) {
        throw new MockHttpError(409, "That name is taken. Try another one.");
      }
      await wait(900);
      const first = s.name === null;
      s.name = name;
      save(s);
      return { ...me(), grant: { musdc: "20000000000", sent: first } };
    }
    if (route === "POST /tutorial/start") {
      if (!s.started) await wait(1500);
      s.started = true;
      save(s);
      return tutorial(s, address);
    }
    if (route === "GET /tutorial") return tutorial(s, address);
    if (route === "POST /tutorial/reset") {
      await wait(1200);
      Object.assign(s, { step: 0, started: true, txFor: null });
      save(s);
      return tutorial(s, address);
    }
    if (route === "POST /tutorial/next") {
      if (s.step >= steps.length) return tutorial(s, address);
      const step = steps[s.step];
      if (step.action && s.txFor !== step.id) {
        throw new MockHttpError(
          409,
          `We couldn't see that you did this step yet. Press "${step.action.label}" first.`,
        );
      }
      await wait(step.waitNote ? 2600 : 700);
      s.step += 1;
      s.txFor = null;
      save(s);
      return tutorial(s, address);
    }
    if (route === "GET /circles") {
      const t = tutorial(s, address).snapshot;
      const list: CircleSummary[] = s.started
        ? [
            {
              address: CIRCLE,
              name: t.name,
              status: t.status,
              members: t.members.length,
              round: t.round,
              totalRounds: t.totalRounds,
              practice: true,
            },
          ]
        : [];
      return list;
    }
    if (method === "GET" && path.startsWith("/circles/")) {
      if (path.slice(9).toLowerCase() !== CIRCLE.toLowerCase()) {
        throw new MockHttpError(404, "There's no circle at that address.");
      }
      return tutorial(s, address).snapshot;
    }
    throw new MockHttpError(404, "Not found.");
  } catch (err) {
    if (err instanceof MockHttpError)
      throw new ApiError(err.status, err.message);
    throw err;
  }
}
