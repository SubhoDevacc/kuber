// The real app's server (`/api/app`, REAL-APP.md). Amounts are base-unit strings (6 decimals) like the tutorial's.
import { ApiError } from "../lib/errors";
import type { CircleSnapshot, Hex, MoneyPlan } from "../types";

export type AppHealth = {
  ok: boolean;
  chainId?: number;
  usdc?: Hex;
  factory?: Hex;
  registry?: Hex;
};

export type AppMe = {
  address: Hex;
  name: string | null;
  verified: boolean;
  musdc: string;
  avax: string;
  granted: boolean;
  /** If the server ever remembers it: this person finished the tutorial once. */
  tutorialDone?: boolean;
};

export type AppCircle = {
  address: Hex;
  name: string;
  status: string;
  members: number;
  maxMembers: number;
  round: number;
  totalRounds: number;
  contribution: string;
  startsAt: number | string;
  mine: boolean;
  canJoin: boolean;
  invited?: boolean;
  canRequest?: boolean;
};

export type LoanRequest = {
  id: number;
  borrower: string;
  amount: string;
  needsBacking: string;
  backedSoFar: string;
  rate: number | string;
  mine: boolean;
  repayRounds?: number;
  canBack?: boolean;
  maxBack?: string;
  /** The offered rate in basis points (800 = 8%), when the server sends it; otherwise parsed from `rate`. */
  rateBps?: number;
  /** Server-computed risk for the suggested backing amount (base units). */
  ifYouBack?: Risk;
  ifYouAgree?: Risk;
  canAgree?: boolean;
  maxAgree?: string;
};

export type Risk = { amount: string; couldLose: string; wouldEarn: string };

export type OpenProposal = {
  id: number;
  title: string;
  yes: number;
  no: number;
  needed: number;
  youVoted: boolean;
  open: boolean;
  kind?: "rule" | "plan" | "manager" | "other";
};

export type Live = {
  now: number | string;
  roundEndsAt: number | string | null;
  locked: boolean;
  lockedReason?: string | null;
  startsAt: number | string;
  minMembers?: number;
  maxMembers?: number;
  you: {
    isMember: boolean;
    invited: boolean;
    requested?: boolean;
    canJoin: boolean;
    canRequest?: boolean;
    allowance?: string;
    suggestedAllowance?: string;
    loanLimit: string;
    ownLimit?: string;
    maxRepayRounds?: number;
    offeredRateBps?: number;
    canBorrow: boolean;
    reasonNoBorrow: string | null;
    activeLoan: {
      id?: number;
      amount?: string;
      owed: string;
      nextDue: { amount: string; round: number | null } | string | null;
      status?: string;
      claimable?: string;
    } | null;
    canClaim?: boolean;
    canSave?: boolean;
    saveAmount?: string;
    paidThisRound?: boolean;
    canRepayAll?: boolean;
    canVote: boolean;
    canPropose?: boolean;
    canLeave?: boolean;
    pendingLeave: boolean;
    canCollect?: boolean;
    freeSavings?: string;
    /** May propose a new money plan (no manager, or you are the manager). */
    canProposePlan?: boolean;
    canProposeManager?: boolean;
    canRemoveManager?: boolean;
    isManager?: boolean;
    proposedThisRound?: boolean;
    proposeReason?: string | null;
    rateLimits?: { minBps: number; maxBps: number };
  };
  /** The money plan in force (bps) and its rules. */
  plan?: {
    current: MoneyPlan;
    limits?: { loanMax: number; lpMax: number; cashMin: number; total: number };
    parts?: { key: keyof MoneyPlan; label: string; help: string }[];
  };
  planNote?: string | null;
  managerCandidates?: { address: Hex; name: string; practice?: boolean }[];
  /** The manager is a practice member: the user may ask them to propose a plan. */
  canAskManagerPlan?: boolean;
  askManagerPlanLabel?: string | null;
  managerPreset?: MoneyPlan | null;
  managerPresetNote?: string | null;
  investments?: {
    earnedSoFar: string;
    aave?: { value: string; apyBps: number; earnedThisRound: string };
    lp?: { value: string; apyBps: number; changeThisRound: string };
    note?: string | null;
  };
  requests: LoanRequest[];
  proposals: OpenProposal[];
  rules?: {
    field: number;
    label: string;
    current: number;
    currentText: string;
  }[];
  isCreator: boolean;
  practiceMembers: number;
  practiceInvited?: number;
  canAddPractice?: boolean;
  invites?: { address: Hex; name: string; joined: boolean }[];
  joinRequests?: { address: Hex; name: string }[];
};

export type AppCircleDetail = CircleSnapshot & { live: Live };

export type ActivityItem = {
  time: number | string;
  who: string;
  what: string;
  amount: string | null;
  txHash: Hex;
  block: number;
  circle?: string;
};

export type Person = { address: Hex; name: string };

const BASE = "/api/app";
const STORE = "kuber.appSession";

let token: string | null = null;
let tokenFor: Hex | null = null;

function remembered(address: Hex): string | null {
  try {
    const raw = localStorage.getItem(STORE);
    const s = raw ? (JSON.parse(raw) as { address: Hex; token: string }) : null;
    return s && s.address.toLowerCase() === address.toLowerCase()
      ? s.token
      : null;
  } catch {
    return null;
  }
}

export function forgetSession() {
  token = null;
  tokenFor = null;
  try {
    localStorage.removeItem(STORE);
  } catch {
    // nothing stored
  }
}

async function raw<T>(
  method: "GET" | "POST",
  path: string,
  body?: unknown,
  auth = true,
): Promise<T> {
  let res: Response;
  try {
    res = await fetch(`${BASE}${path}`, {
      method,
      headers: {
        ...(auth && token ? { authorization: `Bearer ${token}` } : {}),
        ...(body === undefined ? {} : { "content-type": "application/json" }),
      },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
  } catch {
    throw new ApiError(
      0,
      "Can't reach the Kuber server. Check your connection, then try again.",
    );
  }
  const text = await res.text();
  let json: unknown = null;
  try {
    json = text ? JSON.parse(text) : null;
  } catch {
    // not JSON
  }
  if (!res.ok) {
    const error = (json as { error?: unknown } | null)?.error;
    throw new ApiError(
      res.status,
      typeof error === "string" && error
        ? error
        : res.status >= 500
          ? "The Kuber server had a problem. Try again in a moment."
          : "Something went wrong. Try again.",
    );
  }
  return json as T;
}

/** On only when the server says so; off for 503 (not set up), 401/404 (tutorial-only server) or no server. */
export async function appHealth(): Promise<AppHealth | null> {
  try {
    const h = await raw<AppHealth>("GET", "/health", undefined, false);
    return h?.ok ? h : null;
  } catch {
    return null;
  }
}

/** Signs `Kuber sign-in` with the wallet and trades it for the server's session token (kept 24 h). */
export async function startSession(
  address: Hex,
  sign: (message: string) => Promise<Hex>,
  privyToken?: string | null,
): Promise<void> {
  const kept = remembered(address);
  if (kept) {
    token = kept;
    tokenFor = address;
    try {
      await raw("GET", "/me");
      return;
    } catch (err) {
      if (!(err instanceof ApiError) || err.status !== 401) throw err;
    }
  }
  const message = `Kuber sign-in\nAddress: ${address}\nTime: ${new Date().toISOString()}`;
  const signature = await sign(message);
  const res = await raw<{ token: string }>(
    "POST",
    "/session",
    { address, message, signature, ...(privyToken ? { privyToken } : {}) },
    false,
  );
  token = res.token;
  tokenFor = address;
  try {
    localStorage.setItem(STORE, JSON.stringify({ address, token }));
  } catch {
    // private mode: sign again next visit
  }
}

export const sessionAddress = () => tokenFor;

const q = encodeURIComponent;

export const appApi = {
  me: () => raw<AppMe>("GET", "/me"),
  onboard: (name: string) => raw<AppMe>("POST", "/onboard", { name }),
  faucet: () => raw<AppMe>("POST", "/faucet", {}),
  circles: () => raw<AppCircle[]>("GET", "/circles"),
  circle: (a: string) => raw<AppCircleDetail>("GET", `/circles/${a}`),
  practiceMembers: (a: string, count: number) =>
    raw<unknown>("POST", `/circles/${a}/practice-members`, { count }),
  practiceBack: (a: string, requestId: number) =>
    raw<unknown>("POST", `/circles/${a}/practice-back`, { requestId }),
  /** The practice member who is fund manager proposes the preset money plan (a real `propose` from their wallet). */
  practicePlan: (a: string) =>
    raw<AppCircleDetail>("POST", `/circles/${a}/practice-plan`, {}),
  /** Four practice-member addresses to invite in `createCircle` (they join only when added). */
  practiceInvites: () => raw<{ invites: Hex[] }>("GET", "/practice-invites"),
  names: (addrs: string[]) =>
    raw<Person[]>("GET", `/names?addrs=${addrs.join(",")}`),
  activity: (a: string) => raw<ActivityItem[]>("GET", `/circles/${a}/activity`),
  myActivity: () => raw<ActivityItem[]>("GET", "/activity"),
  lookup: (name: string) => raw<Person>("GET", `/lookup?name=${q(name)}`),
  people: (prefix: string) => raw<Person[]>("GET", `/people?q=${q(prefix)}`),
};

/** Server times may be unix seconds, milliseconds or ISO strings. */
export function toMs(t: number | string | null | undefined): number | null {
  if (t === null || t === undefined || t === "") return null;
  if (typeof t === "number") return t < 1e12 ? t * 1000 : t;
  if (/^\d+$/.test(t)) return toMs(Number(t));
  const ms = Date.parse(t);
  return Number.isNaN(ms) ? null : ms;
}
