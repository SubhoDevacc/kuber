// Reads a circle's raw numbers from the contract views (Facts) and turns them into the API's CircleSnapshot.
import type { Address } from "viem";
import type { Chain } from "./chain.ts";

type Backing = {
  backer: Address;
  amount: bigint;
  interest: bigint;
  interestPaid: bigint;
  loss: bigint;
};
export type LoanRaw = {
  id: number;
  borrower: Address;
  amount: bigint;
  ownPart: bigint;
  backedNeed: bigint;
  saverInterest: bigint;
  repayEpochs: number;
  fundedEpoch: number;
  installmentsPaid: number;
  status: number;
  unclaimed: bigint;
  vouchers: readonly Backing[];
  agreers: readonly Backing[];
};
type MemberRaw = {
  savings: bigint;
  pledgedOut: bigint;
  rewards: bigint;
  claimable: bigint;
  paidBitmap: bigint;
  missedBitmap: bigint;
  activeLoanId: number;
  pendingRequestId: number;
  paidCount: number;
  status: number;
  withdrawn: boolean;
  debtLoanId: number;
};
export type MemberFacts = MemberRaw & {
  address: Address;
  wallet: bigint;
  debt: bigint;
  lost: bigint;
  loanOwed: bigint;
  behind: number;
};
type ProposalRaw = {
  kind: number;
  status: number;
  field: number;
  value: number;
  yes: number;
  no: number;
};
export type Facts = {
  circle: Address;
  name: string;
  status: number;
  round: number;
  settled: number;
  startTime: bigint;
  epochDuration: bigint;
  totalRounds: number;
  contribution: bigint;
  exitFeeBps: number;
  pot: { cash: bigint; invested: bigint; lent: bigint; earned: bigint };
  members: MemberFacts[];
  loans: LoanRaw[];
  proposals: (ProposalRaw & { id: number; youVoted: boolean })[];
  user: Address | null;
  userWallet: bigint;
  userAllowance: bigint;
  /** The user's share-out once withdrawn (0 before); the contract leaves `savings` unchanged after withdraw. */
  userPaidOut: bigint;
};

type StateRaw = {
  name: string;
  status: number;
  currentEpoch: bigint;
  settledEpoch: bigint;
  fixedParams: {
    contribution: bigint;
    epochDuration: number;
    startTime: bigint;
    totalEpochs: number;
  };
  rules: { exitFeeBps: number };
  loanCount: bigint;
  proposalCount: bigint;
};
type SummaryRaw = {
  cash: bigint;
  outstandingPrincipal: bigint;
  yieldPot: bigint;
  aaveValue: bigint;
  lpValue: bigint;
};

/** What a loan still owes: each component minus its floor parts already paid (Loans.installment). */
export const loanOwed = (l: LoanRaw): bigint => {
  if (l.status !== 2) return 0n;
  const n = BigInt(l.repayEpochs);
  const p = BigInt(l.installmentsPaid);
  const parts = [
    l.amount,
    l.saverInterest,
    ...l.vouchers.map((b) => b.interest),
    ...l.agreers.map((b) => b.interest),
  ];
  return parts.reduce((s, c) => s + c - p * (c / n), 0n);
};

/** One installment of a funded loan (the first; the last carries the rounding remainder). */
export const installmentOf = (l: LoanRaw): bigint => {
  const n = BigInt(l.repayEpochs);
  const parts = [
    l.amount,
    l.saverInterest,
    ...l.vouchers.map((b) => b.interest),
    ...l.agreers.map((b) => b.interest),
  ];
  return parts.reduce((s, c) => s + c / n, 0n);
};

export const readFacts = async (
  c: Chain,
  circle: Address,
  user: Address | null,
  /** How to find the user's share-out once withdrawn; default: the Withdrawn event from block 0 (fine on Anvil). */
  paidOutOf?: (circle: Address, user: Address) => Promise<bigint>,
): Promise<Facts> => {
  const { abis } = c;
  const [s, sum, list] = await Promise.all([
    c.read<StateRaw>(circle, abis.circle, "getCircleState"),
    c.read<SummaryRaw>(circle, abis.circle, "getPublicSummary"),
    c.read<readonly Address[]>(circle, abis.circle, "members"),
  ]);
  const loanIds = Array.from({ length: Number(s.loanCount) }, (_, i) => i + 1);
  const propIds = Array.from(
    { length: Number(s.proposalCount) },
    (_, i) => i + 1,
  );
  const [raws, loans, props, userWallet, userAllowance] = await Promise.all([
    Promise.all(
      list.map((a) =>
        Promise.all([
          c.read<MemberRaw>(circle, abis.circle, "getMember", [a]),
          c.read<bigint>(c.usdc, abis.usdc, "balanceOf", [a]),
          c.read<bigint>(circle, abis.circle, "debtOf", [a]),
        ]),
      ),
    ),
    Promise.all(
      loanIds.map(async (id) => ({
        ...(await c.read<Omit<LoanRaw, "id">>(circle, abis.circle, "getLoan", [
          BigInt(id),
        ])),
        id,
      })),
    ),
    Promise.all(
      propIds.map(async (id) => ({
        ...(await c.read<ProposalRaw>(circle, abis.circle, "getProposal", [
          BigInt(id),
        ])),
        id,
        youVoted: user
          ? (await c.read<number>(circle, abis.circle, "ballotOf", [
              BigInt(id),
              user,
            ])) !== 0
          : false,
      })),
    ),
    user ? c.read<bigint>(c.usdc, abis.usdc, "balanceOf", [user]) : 0n,
    user ? c.read<bigint>(c.usdc, abis.usdc, "allowance", [user, circle]) : 0n,
  ]);
  const settled = Number(s.settledEpoch);
  const members = list.map((address, i) => {
    const [m, wallet, debt] = raws[i];
    const same = (b: Backing) =>
      b.backer.toLowerCase() === address.toLowerCase();
    const lost = loans.reduce(
      (t, l) =>
        t +
        [...l.vouchers, ...l.agreers]
          .filter(same)
          .reduce((x, b) => x + b.loss, 0n),
      0n,
    );
    const own = loans.find((l) => l.id === m.activeLoanId);
    // R-H badge: installments due by the last settlement and not yet paid (installment i is due in funded + 2 + i).
    const due = own
      ? Math.max(0, Math.min(own.repayEpochs, settled - own.fundedEpoch - 1))
      : 0;
    const behind =
      own && own.status === 2 ? Math.max(0, due - own.installmentsPaid) : 0;
    return {
      ...m,
      address,
      wallet,
      debt,
      lost,
      loanOwed: own ? loanOwed(own) : 0n,
      behind,
    };
  });
  const me = user
    ? members.find((m) => m.address.toLowerCase() === user.toLowerCase())
    : undefined;
  // The amount withdraw() paid is only in its Withdrawn event.
  const paid =
    user && me?.withdrawn && paidOutOf
      ? [{ args: { amount: await paidOutOf(circle, user) } }]
      : user && me?.withdrawn
        ? ((await c.pub.getContractEvents({
            address: circle,
            abi: abis.circle,
            eventName: "Withdrawn",
            args: { member: user },
            fromBlock: 0n,
          } as never)) as unknown as { args: { amount: bigint } }[])
        : [];
  return {
    circle,
    name: s.name,
    status: s.status,
    round: Number(s.currentEpoch),
    settled,
    startTime: BigInt(s.fixedParams.startTime),
    epochDuration: BigInt(s.fixedParams.epochDuration),
    totalRounds: s.fixedParams.totalEpochs,
    contribution: s.fixedParams.contribution,
    exitFeeBps: s.rules.exitFeeBps,
    pot: {
      cash: sum.cash,
      invested: sum.aaveValue + sum.lpValue,
      lent: sum.outstandingPrincipal,
      earned: sum.yieldPot,
    },
    members,
    loans,
    proposals: props,
    user,
    userWallet,
    userAllowance,
    userPaidOut: paid.reduce((t, l) => t + l.args.amount, 0n),
  };
};

// ---------- formatting

/** "1,234.56 mUSDC" (to the nearest cent); base units have 6 decimals. */
export const money = (v: bigint): string => {
  const neg = v < 0n;
  const c = ((neg ? -v : v) + 5_000n) / 10_000n;
  const whole = (c / 100n).toLocaleString("en-US");
  const cents = (c % 100n).toString().padStart(2, "0");
  return `${neg ? "-" : ""}${whole}.${cents} mUSDC`;
};

const CIRCLE_STATUS = ["Forming", "Active", "Completed", "Cancelled"] as const;
const LOAN_STATUS = [
  "None",
  "Waiting for backers",
  "Being repaid",
  "Repaid",
  "Not repaid",
  "Cancelled",
  "Expired",
];
const PROPOSAL_STATUS = [
  "None",
  "Voting",
  "Passed",
  "Rejected",
  "Done",
  "Dropped",
];
const RULE_NAMES = [
  "Share of your savings you can borrow",
  "Interest on borrowing your own savings",
  "Largest single loan",
  "Fast-lane share",
  "Penalty for not repaying",
  "Fine for a late round",
  "Fine for a late repayment",
  "Fee for leaving early",
  "Manager fee",
];

export const pct = (bps: number) => `${bps / 100}%`;

export const memberStatus = (m: MemberFacts | undefined): string => {
  if (!m) return "Not joined";
  if (m.status === 2) return "Paused";
  if (m.status === 3) return "Left";
  if (m.status === 4) return "Removed";
  if (m.withdrawn) return "Paid out";
  if (m.behind === 1) return "1 behind";
  if (m.behind >= 2) return `${m.behind} behind`;
  return "On track";
};

export type Names = Map<string, string>; // lowercase address -> display name

export type CircleSnapshot = ReturnType<typeof toSnapshot>;

export const toSnapshot = (f: Facts, names: Names, practice: boolean) => {
  const nameOf = (a: Address) =>
    f.user && a.toLowerCase() === f.user.toLowerCase()
      ? "You"
      : (names.get(a.toLowerCase()) ?? `${a.slice(0, 6)}…${a.slice(-4)}`);
  const isYou = (a: Address) =>
    !!f.user && a.toLowerCase() === f.user.toLowerCase();
  const me = f.members.find((m) => isYou(m.address));
  const role = (m: MemberFacts) => {
    if (
      f.loans.some(
        (l) => l.borrower === m.address && l.status >= 2 && l.status <= 4,
      )
    )
      return "Borrower";
    if (
      f.loans.some((l) =>
        [...l.vouchers, ...l.agreers].some((b) => b.backer === m.address),
      )
    )
      return "Backer";
    return "Saver";
  };
  const s = (v: bigint) => v.toString();
  return {
    address: f.circle,
    name: f.name,
    practice,
    status: CIRCLE_STATUS[f.status] ?? "Forming",
    round: Math.min(f.round, f.totalRounds),
    totalRounds: f.totalRounds,
    contribution: s(f.contribution),
    pot: {
      total: s(f.pot.cash + f.pot.invested + f.pot.lent),
      cash: s(f.pot.cash),
      invested: s(f.pot.invested),
      lent: s(f.pot.lent),
      earned: s(f.pot.earned),
    },
    you: me
      ? {
          savings: s(me.savings),
          wallet: s(me.wallet),
          loanOwed: s(me.loanOwed),
          pledged: s(me.pledgedOut),
          rewards: s(me.rewards),
          claimable: s(me.claimable),
          status: memberStatus(me),
          // Only once withdrawn: the share-out collected.
          ...(me.withdrawn ? { paidOut: s(f.userPaidOut) } : {}),
        }
      : null,
    members: f.members.map((m) => ({
      address: m.address,
      name: nameOf(m.address),
      you: isYou(m.address),
      role: role(m),
      status: memberStatus(m),
      savings: s(m.savings),
      loanOwed: s(m.loanOwed),
      pledged: s(m.pledgedOut),
      lost: s(m.lost),
      debt: s(m.debt),
    })),
    loans: f.loans.map((l) => ({
      id: l.id,
      borrower: nameOf(l.borrower),
      amount: s(l.amount),
      status: LOAN_STATUS[l.status] ?? "Unknown",
      backers: [...l.vouchers, ...l.agreers].map((b) => ({
        name: nameOf(b.backer),
        amount: s(b.amount),
        earned: s(b.interestPaid),
        lost: s(b.loss),
      })),
    })),
    proposals: f.proposals.map((p) => ({
      id: p.id,
      title:
        p.kind === 0
          ? `${RULE_NAMES[p.field] ?? "A rule"}: change to ${pct(p.value)}`
          : "Change the circle",
      yes: p.yes,
      no: p.no,
      status: PROPOSAL_STATUS[p.status] ?? "Unknown",
      youVoted: p.youVoted,
    })),
  };
};
