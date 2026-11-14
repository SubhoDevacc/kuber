// Turns decoded transaction calls and events into plain words. Pure: no React, no network.
import { formatAmount } from "../lib/money";
import { shortHash } from "../lib/wallet";

/** Lower-cased address -> display name. */
export type Labels = Record<string, string>;
/** Decoded arguments keyed by their ABI names. */
export type Args = Record<string, unknown>;
export type Row = { label: string; value: string };

const ZERO = "0x0000000000000000000000000000000000000000";
const MAX_UINT = 2n ** 256n - 1n;

const isAddress = (v: unknown): v is string =>
  typeof v === "string" && /^0x[0-9a-fA-F]{40}$/.test(v);

const big = (v: unknown): bigint => {
  try {
    return typeof v === "bigint" ? v : BigInt(String(v ?? 0));
  } catch {
    return 0n;
  }
};

/** A name for an address: its label, else the short form. */
export function who(addr: unknown, labels: Labels): string {
  if (typeof addr !== "string") return "someone";
  if (addr.toLowerCase() === ZERO) return "nobody";
  return labels[addr.toLowerCase()] ?? shortHash(addr);
}

/** The same name, for use mid-sentence ("This circle" -> "this circle", "You" -> "you"). */
export function whoIn(addr: unknown, labels: Labels): string {
  const name = who(addr, labels);
  return /^(This|The|You)\b/.test(name)
    ? name[0].toLowerCase() + name.slice(1)
    : name;
}

/** Base units (6 decimals) -> "350.00 mUSDC". */
export const money = (v: unknown) => `${formatAmount(big(v))} mUSDC`;

/** Basis points -> "8.00%". */
export function pct(bps: unknown): string {
  const b = big(bps);
  return `${b / 100n}.${(b % 100n).toString().padStart(2, "0")}%`;
}

const num = (v: unknown) =>
  big(v)
    .toString()
    .replace(/\B(?=(\d{3})+(?!\d))/g, ",");

/** Seconds -> "1 week", "2 days", "5 minutes". */
export function duration(secs: unknown): string {
  const s = Number(big(secs));
  const units: [number, string][] = [
    [604800, "week"],
    [86400, "day"],
    [3600, "hour"],
    [60, "minute"],
    [1, "second"],
  ];
  for (const [size, name] of units) {
    if (s >= size && s % size === 0) {
      const n = s / size;
      return `${n} ${name}${n === 1 ? "" : "s"}`;
    }
  }
  return `${s} seconds`;
}

const PROPOSAL_KINDS = [
  "rule change",
  "money plan change",
  "new manager",
  "removing a member",
  "new member",
];
const proposalKind = (k: unknown) => PROPOSAL_KINDS[Number(big(k))] ?? "change";

const MONEY_KEYS = new Set([
  "amount",
  "amt",
  "value",
  "contribution",
  "fine",
  "payout",
  "owed",
  "fromBorrower",
  "fromVouchers",
  "fromAgreers",
  "penaltyPaid",
  "debt",
  "remaining",
  "protocolFee",
  "managerFee",
  "saverPot",
  "yieldPot",
  "cash",
  "aaveValue",
  "lpValue",
]);

const LABELS: Record<string, string> = {
  amount: "Amount",
  amt: "Amount",
  value: "Amount",
  id: "Number",
  epoch: "Round",
  n: "How many",
  who: "Who",
  member: "Member",
  person: "Person",
  applicant: "Applicant",
  spender: "Allowed to collect",
  owner: "Owner",
  to: "To",
  from: "From",
  account: "Account",
  yes: "Vote",
  kind: "Kind",
  data: "Details",
  name: "Name",
  repayEpochs: "Paid back over",
  offeredRateBps: "Interest offered",
  extraBps: "Extra for backers",
  newExtraBps: "New extra for backers",
  maxMembers: "Members to process",
  isVerified: "Verified",
  allowed: "Allowed",
};

const label = (key: string) =>
  LABELS[key] ??
  (key.replace(/_$/, "").replace(/([a-z0-9])([A-Z])/g, "$1 $2") || "Value")
    .toLowerCase()
    .replace(/^./, (c) => c.toUpperCase());

/** One argument's value in readable form, guessed from its name and shape. */
export function formatValue(key: string, v: unknown, labels: Labels): string {
  if (isAddress(v)) return who(v, labels);
  if (typeof v === "boolean") return v ? "Yes" : "No";
  if (Array.isArray(v)) {
    if (v.length === 0) return "None";
    return v.map((x) => formatValue(key, x, labels)).join(", ");
  }
  if (typeof v === "bigint" || typeof v === "number") {
    if (MONEY_KEYS.has(key))
      return big(v) === MAX_UINT ? "Any amount" : money(v);
    if (/bps$/i.test(key)) return pct(v);
    if (key === "repayEpochs")
      return `${num(v)} round${big(v) === 1n ? "" : "s"}`;
    if (key === "kind") return proposalKind(v);
    if (key === "id") return `#${num(v)}`;
    return num(v);
  }
  if (typeof v === "string") {
    if (/^0x[0-9a-fA-F]*$/.test(v))
      return v.length > 20
        ? `${v.slice(0, 10)}… (${(v.length - 2) / 2} bytes)`
        : v;
    return v;
  }
  if (v && typeof v === "object") return "(details)";
  return String(v);
}

type Fixed = {
  contribution?: bigint;
  epochDuration?: number;
  totalEpochs?: number;
  minMembers?: number;
  maxMembers?: number;
};
type Rules = {
  ownLtvBps?: number;
  ownRateBps?: number;
  managerFeeBps?: number;
};

/** createCircle / initialize: a few readable fields, no raw structs. */
function circleRows(args: Args, labels: Labels): Row[] {
  const f = (args.fixedParams_ ?? {}) as Fixed;
  const r = (args.rules_ ?? {}) as Rules;
  const invites = Array.isArray(args.invites) ? args.invites : [];
  const rows: Row[] = [];
  if (typeof args.name === "string")
    rows.push({ label: "Name", value: args.name });
  if (args.creator)
    rows.push({ label: "Started by", value: who(args.creator, labels) });
  if (f.contribution !== undefined)
    rows.push({ label: "Saving per round", value: money(f.contribution) });
  if (f.epochDuration !== undefined)
    rows.push({ label: "Round length", value: duration(f.epochDuration) });
  if (f.totalEpochs !== undefined)
    rows.push({ label: "Rounds", value: num(f.totalEpochs) });
  if (f.minMembers !== undefined && f.maxMembers !== undefined)
    rows.push({
      label: "Members",
      value: `${f.minMembers} to ${f.maxMembers}`,
    });
  if (r.ownLtvBps !== undefined)
    rows.push({
      label: "Borrow up to",
      value: `${pct(r.ownLtvBps)} of own savings`,
    });
  if (r.ownRateBps !== undefined)
    rows.push({
      label: "Interest on own-savings loans",
      value: pct(r.ownRateBps),
    });
  rows.push({
    label: "Invited",
    value: invites.length
      ? invites.map((a) => who(a, labels)).join(", ")
      : "Nobody yet",
  });
  return rows;
}

const s = (n: unknown, word: string) =>
  `${num(n)} ${word}${big(n) === 1n ? "" : "s"}`;

/** Headline and readable arguments for a decoded function call. */
export function describeCall(
  functionName: string,
  args: Args,
  labels: Labels,
): { headline: string; rows: Row[] } {
  const a = args;
  const h = ((): string => {
    switch (functionName) {
      // Circle
      case "payNow":
        return "Saved this round";
      case "requestLoan":
        return `Asked to borrow ${money(a.amount)}`;
      case "vouch":
        return `Backed loan #${num(a.id)} with ${money(a.amt)}`;
      case "agree":
        return `Backed loan #${num(a.id)} with ${money(a.amt)} (second in line)`;
      case "unback":
        return `Took back backing from loan #${num(a.id)}`;
      case "cancelRequest":
        return `Cancelled loan request #${num(a.id)}`;
      case "raiseExtra":
        return `Raised the extra on loan request #${num(a.id)} to ${pct(a.newExtraBps)}`;
      case "claim":
        return "Collected money waiting for you";
      case "withdraw":
        return "Collected share-out";
      case "repayAll":
        return "Paid back the whole loan";
      case "repayDebt":
        return `Paid ${money(a.amt)} towards what is owed`;
      case "payArrears":
        return `Paid ${s(a.n, "overdue repayment")}`;
      case "catchUp":
        return `Caught up on round ${num(a.epoch)}`;
      case "settle":
        return "Closed the round";
      case "activate":
        return "Started the circle";
      case "cancel":
        return "Cancelled the circle";
      case "join":
        return "Joined the circle";
      case "applyToJoin":
        return "Applied to join";
      case "requestToJoin":
        return "Asked to join";
      case "invite":
        return `Invited ${whoIn(a.who, labels)}`;
      case "sponsor":
        return `Sponsored ${whoIn(a.applicant, labels)} to join`;
      case "requestLeave":
        return "Asked to leave";
      case "cancelLeave":
        return "Decided to stay";
      case "leave":
        return "Left the circle";
      case "propose":
        return `Proposed a ${proposalKind(a.kind)}`;
      case "vote":
        return `Voted ${a.yes ? "yes" : "no"} on rule change #${num(a.id)}`;
      case "applyFreed":
        return `Used ${whoIn(a.member, labels)}'s freed savings to cover a loan`;
      case "receiveLienPayment":
        return `Received ${money(a.amount)} towards ${whoIn(a.person, labels)}'s debt`;
      case "initialize":
        return "Set up the circle";
      // Factory
      case "createCircle":
        return "Created a circle";
      // Test money
      case "approve":
        return big(a.value) === MAX_UINT
          ? `Allowed ${whoIn(a.spender, labels)} to collect any amount`
          : `Allowed ${whoIn(a.spender, labels)} to collect ${money(a.value)}`;
      case "transfer":
        return `Sent ${money(a.value)} to ${whoIn(a.to, labels)}`;
      case "transferFrom":
        return `Moved ${money(a.value)} from ${whoIn(a.from, labels)} to ${whoIn(a.to, labels)}`;
      case "mint":
        return `Created ${money(a.amount)} of test money for ${whoIn(a.to, labels)}`;
      // Registry
      case "setVerified":
        return `Marked ${whoIn(a.account, labels)} as ${a.isVerified ? "verified" : "not verified"}`;
      default:
        return `Called ${functionName}`;
    }
  })();
  const rows =
    functionName === "createCircle" || functionName === "initialize"
      ? circleRows(a, labels)
      : Object.entries(a).map(([k, v]) => ({
          label: label(k),
          value: formatValue(k, v, labels),
        }));
  return { headline: h, rows };
}

/** One plain-words line for a decoded event. */
export function describeEvent(
  eventName: string,
  args: Args,
  labels: Labels,
): string {
  const a = args ?? {};
  const first = (k: string) => who(a[k], labels);
  const mid = (k: string) => whoIn(a[k], labels);
  switch (eventName) {
    case "ContributionPaid":
      return `${first("member")} saved ${money(a.amount)} (round ${num(a.epoch)})`;
    case "ContributionMissed":
      return `${first("member")} missed a payment (round ${num(a.epoch)})`;
    case "CaughtUp":
      return `${first("member")} caught up on round ${num(a.epoch)} (fine ${money(a.fine)})`;
    case "EpochSettled":
      return `Round ${num(a.epoch)} closed`;
    case "LoanRequested":
      return `Loan requested: ${money(a.amount)} over ${s(a.repayEpochs, "round")}`;
    case "Backed":
      return `${first("backer")} backed loan #${num(a.id)} with ${money(a.amount)}`;
    case "Unbacked":
      return `${first("backer")} took back ${money(a.amount)} from loan #${num(a.id)}`;
    case "LoanFunded":
      return `Loan #${num(a.id)} approved`;
    case "LoanClaimed":
      return `${first("borrower")} took the loan: ${money(a.amount)}`;
    case "InstallmentPaid":
      return `Repayment ${num(a.installment)} on loan #${num(a.id)} paid: ${money(a.amount)}`;
    case "InstallmentMissed":
      return `Repayment ${num(a.installment)} on loan #${num(a.id)} missed`;
    case "LoanRepaid":
      return `Loan #${num(a.id)} paid back${a.onTime ? " on time" : ""}`;
    case "RequestExpired":
      return `Loan request #${num(a.id)} ran out of time`;
    case "FineCharged":
      return `${first("member")} was fined ${money(a.amount)} on loan #${num(a.id)}`;
    case "DebtRepaid":
      return `${first("member")} paid ${money(a.amount)} towards what they owe (${money(a.remaining)} left)`;
    case "Claimed":
      return `${first("member")} collected ${money(a.amount)}`;
    case "Withdrawn":
      return `${first("member")} collected a share-out of ${money(a.amount)}`;
    case "MemberSuspended":
      return `A member was paused over loan #${num(a.loanId)} (owed ${money(a.owed)})`;
    case "MemberReinstated":
      return `${first("member")} is back in good standing`;
    case "MemberAdmitted":
      return `${first("member")} was let in`;
    case "MemberKicked":
      return `${first("member")} was removed and paid ${money(a.payout)}`;
    case "MemberLeft":
      return `${first("member")} left and was paid ${money(a.payout)}`;
    case "LeaveRequested":
      return `${first("member")} asked to leave`;
    case "Voted":
      return `${first("voter")} voted ${a.yes ? "yes" : "no"} on rule change #${num(a.id)}`;
    case "ProposalCreated":
      return `${first("proposer")} proposed a ${proposalKind(a.kind)} (#${num(a.id)})`;
    case "ProposalPassed":
      return `Rule change #${num(a.id)} passed`;
    case "ProposalApplied":
      return `Rule change #${num(a.id)} took effect`;
    case "Joined":
      return `${first("who")} joined`;
    case "Invited":
      return `${first("who")} was invited`;
    case "JoinRequested":
      return `${first("who")} asked to join`;
    case "JoinApplied":
      return `${first("applicant")} applied to join`;
    case "Sponsored":
      return `${first("sponsor")} sponsored ${mid("applicant")} to join`;
    case "Activated":
      return "The circle started";
    case "Cancelled":
      return "The circle was cancelled";
    case "Finalized":
      return "The circle ended and share-outs were worked out";
    case "FeesCharged":
      return `Fees taken: ${money(a.protocolFee)} to Kuber, ${money(a.managerFee)} to the manager`;
    case "Rebalanced":
      return `Money plan rebalanced (${money(a.cash)} kept as cash)`;
    case "ManagerChanged":
      return `${first("manager")} is now the manager`;
    case "LienPaid":
      return `${money(a.amount)} of ${mid("person")}'s pay went to ${mid("toCircle")}`;
    case "GasReimbursed":
      return `${first("caller")} got a small refund for network fees`;
    case "Approval":
      return big(a.value) === MAX_UINT
        ? `${first("owner")} allowed ${mid("spender")} to collect any amount`
        : `${first("owner")} allowed ${mid("spender")} to collect ${money(a.value)}`;
    case "Transfer":
      if (String(a.from).toLowerCase() === ZERO)
        return `${money(a.value)} test money created for ${mid("to")}`;
      return `${money(a.value)} moved from ${mid("from")} to ${mid("to")}`;
    case "CircleCreated":
      return `Circle created: ${String(a.name ?? "")}`;
    case "VerifiedSet":
      return `${first("account")} marked as ${a.isVerified ? "verified" : "not verified"}`;
    case "CircleAuthorized":
      return `${first("circle")} was registered with Kuber`;
    case "Initialized":
      return "The circle was set up";
    case "DebtAdded":
      return `${first("person")} now owes money to ${mid("circle")}`;
    case "DebtCleared":
      return `${first("person")} no longer owes money to ${mid("circle")}`;
    case "MinterSet":
      return `${first("account")} ${a.allowed ? "can now" : "can no longer"} create test money`;
    default:
      return eventName;
  }
}
