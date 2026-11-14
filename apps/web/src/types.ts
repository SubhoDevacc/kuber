// Shapes from SPRINT.md. The server owns every number and every word; the app only renders them.
export type Hex = `0x${string}`;

export type Action = {
  label: string;
  target: "usdc" | "circle";
  functionName: string;
  args: (string | number | boolean | string[])[];
};

export type ChangeRow = {
  label: string;
  before: string;
  after: string;
  tone: "good" | "bad" | "plain";
};

export type LastChange = {
  title: string;
  rows: ChangeRow[];
  note: string | null;
};

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
  };
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
