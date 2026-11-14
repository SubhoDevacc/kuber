// Shapes from SPRINT.md. The server owns every number and every word; the app only renders them.
export type Hex = `0x${string}`;

export type Action = {
  label: string;
  target: "usdc" | "circle" | "factory";
  functionName: string;
  /** Structs (e.g. createCircle's params) arrive as objects keyed by field name. */
  args: (string | number | boolean | string[] | Record<string, unknown>)[];
};

export type ChangeRow = {
  label: string;
  before: string;
  after: string;
  tone: "good" | "bad" | "plain";
};

/** A tutorial step's public copy on Avalanche Fuji (the practice chain itself has no explorer). */
export type PublicRecord = { chain: string; hash: Hex; url: string };

export type LastChange = {
  title: string;
  rows: ChangeRow[];
  note: string | null;
  /** The real transactions the server sent during the step (practice members, the settlement). Optional. */
  txs?: { label: string; hash: Hex }[];
  /** The step's record on Avalanche Fuji. Missing or null = none (older server, or local dev without Fuji). */
  record?: PublicRecord | null;
};

export type StepOption = { value: string; label: string; description: string };

export type Member = {
  address: Hex;
  name: string;
  you: boolean;
  role: string | null;
  status: string;
  savings: string;
  loanOwed: string;
  pledged: string;
  lost: string;
  debt: string;
  /** The member the group voted in as fund manager. Optional for older servers. */
  isManager?: boolean;
  /** Run by Kuber (real app). Optional. */
  practice?: boolean;
};

/** The fund manager: chooses the money plan (still voted on by everyone). */
export type Manager = {
  address: Hex;
  name: string;
  /** Track record from the registry (`managerStats`), when the server sends it. */
  roundsManaged?: number;
  /** e.g. "+0.42%", null before the first round. */
  averagePerRound?: string | null;
};

/** How the pot is split between loans, Aave, the LP pool and cash, in basis points (sum 10,000). */
export type MoneyPlan = {
  loan: number;
  aave: number;
  lp: number;
  cash: number;
};

export type Loan = {
  id: number;
  borrower: string;
  amount: string;
  status: string;
  backers: { name: string; amount: string; earned: string; lost: string }[];
};

export type Proposal = {
  id: number;
  title: string;
  yes: number;
  no: number;
  status: string;
  youVoted: boolean;
  kind?: "rule" | "plan" | "manager" | "other";
  plan?: MoneyPlan | null;
};

export type CircleSnapshot = {
  address: Hex;
  name: string;
  practice: boolean;
  status: "Forming" | "Active" | "Completed" | "Cancelled";
  round: number;
  totalRounds: number;
  contribution: string;
  pot: {
    total: string;
    cash: string;
    invested: string;
    lent: string;
    earned: string;
    /** This round's change per part (real app), when the server sends it. Signed base-unit strings. */
    aaveEarned?: string;
    lpChange?: string;
    /** A plain line about the test vaults. */
    note?: string | null;
  };
  /** null = no fund manager; undefined = an older server that does not say. */
  manager?: Manager | null;
  /** The money plan now in force, when the server sends it. */
  plan?: MoneyPlan;
  you: null | {
    savings: string;
    wallet: string;
    loanOwed: string;
    pledged: string;
    rewards: string;
    claimable: string;
    status: string;
    /** Only after you collected your share-out: the amount paid to you. */
    paidOut?: string;
  };
  members: Member[];
  loans: Loan[];
  proposals: Proposal[];
};

export type TutorialState = {
  circle: Hex;
  done: boolean;
  chapter: number;
  chapters: string[];
  stepIndex: number;
  stepCount: number;
  step: {
    id: string;
    title: string;
    body: string;
    action: Action | null;
    waitNote: string | null;
    /** A choice instead of an action: one button per option; the value goes back as `choice`. Optional. */
    options?: StepOption[];
  };
  lastChange: LastChange | null;
  snapshot: CircleSnapshot;
};

export type Me = {
  address: Hex;
  name: string | null;
  verified: boolean;
  musdc: string;
  tutorial: TutorialState | null;
};

export type Onboarded = Me & { grant: { musdc: string; sent: boolean } };

export type CircleSummary = {
  address: Hex;
  name: string;
  status: string;
  members: number;
  round: number;
  totalRounds: number;
  practice: boolean;
};
