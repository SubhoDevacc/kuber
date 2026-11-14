// The real app's server (REAL-APP.md): one shared process for Avalanche Fuji (or an Anvil standing in for it).
// Sign-in by wallet signature, welcome grant, faucet, circle views with the live action state, practice members,
// activity from event logs, and a keeper loop (activate, settle, practice members vote yes).
import { createHmac, timingSafeEqual } from "node:crypto";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { mockLpVaultAbi } from "@kuber/shared";
import { PrivyClient } from "@privy-io/node";
import { Hono } from "hono";
import {
  type Abi,
  type Account,
  type Address,
  concat,
  createWalletClient,
  encodeAbiParameters,
  getAddress,
  isAddress,
  keccak256,
  parseEther,
  toHex,
  verifyMessage,
  zeroAddress,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { z } from "zod";
import { type ActivityEntry, activity } from "./activity.ts";
import { type Chain, connect } from "./chain.ts";
import {
  type Alloc,
  type Facts,
  installmentOf,
  loanOwed,
  money,
  type Names,
  pct,
  planText,
  readFacts,
  toSnapshot,
} from "./snapshot.ts";

const hex64 = z.string().regex(/^0x[0-9a-fA-F]{64}$/, "must be a 0x key");
const FujiEnvSchema = z.object({
  FUJI_RPC_URL: z.url().default("https://api.avax-test.network/ext/bc/C/rpc"),
  FUJI_ADMIN_PRIVATE_KEY: hex64,
  FUJI_DEPLOYMENT_PATH: z.string().optional(),
  SESSION_SECRET: z.string().min(16).optional(),
  PRIVY_APP_ID: z.string().optional(),
  PRIVY_APP_SECRET: z.string().optional(),
  WELCOME_GRANT_MUSDC: z.coerce.number().int().positive().default(20000),
  WELCOME_GAS_AVAX: z.string().default("0.05"),
  FAUCET_MUSDC: z.coerce.number().int().positive().default(10000),
  PRACTICE_GAS_AVAX: z.string().default("0.02"),
  KEEPER_INTERVAL_MS: z.coerce.number().int().min(0).default(10_000),
  LOG_CHUNK: z.coerce.number().int().positive().default(100),
  LOG_MIN_GAP_MS: z.coerce.number().int().min(0).default(3000),
  POLL_MS: z.coerce.number().int().min(10).default(1000),
  NAMES_PATH: z.string().optional(),
  // Test-vault demo controls (round 3): yield sped up so a 2-minute round earns about a month of interest
  // (30 days / 120 s = 21,600); 0 = leave the vaults as they are. The LP pool's price moves now and then.
  VAULT_SPEEDUP: z.coerce.number().int().min(0).max(1_000_000).default(21_600),
  VAULT_AAVE_APY_BPS: z.coerce.number().int().min(0).max(10_000).default(500),
  VAULT_LP_APY_BPS: z.coerce.number().int().min(0).max(10_000).default(800),
  LP_MOVE_EVERY_MS: z.coerce.number().int().min(0).default(60_000),
  LP_MOVE_UP_BPS: z.coerce.number().int().min(1).max(500).default(30),
  LP_MOVE_DOWN_BPS: z.coerce.number().int().min(1).max(500).default(20),
});
export type FujiEnv = z.infer<typeof FujiEnvSchema>;
export const parseFujiEnv = (raw: NodeJS.ProcessEnv): FujiEnv => {
  const r = FujiEnvSchema.safeParse(raw);
  if (!r.success)
    throw new Error(
      `bad environment: ${r.error.issues.map((i) => `${i.path.join(".")} ${i.message}`).join("; ")}`,
    );
  return r.data;
};

const USDC = 1_000_000n;
const SESSION_MS = 24 * 3600_000;
const SIGN_SKEW_MS = 5 * 60_000;
const FAUCET_MS = 3600_000;
const SETTLE_BATCH = 25n;
const PRACTICE_COUNT = 4;
/** Real-app practice members' names (index 0-3); every such row also carries practice: true. */
export const PRACTICE_NAMES = ["Gita", "Hari", "Indu", "Jay"] as const;
/** Contract bounds (Params.validateRules / Queue): the money plan and the rate a borrower offers. */
const PLAN_LIMITS = {
  loanMax: 4_000,
  lpMax: 5_000,
  cashMin: 500,
  total: 10_000,
};
const MAX_OFFERED_RATE = 3_000;
const PLAN_PARTS = [
  {
    key: "loan",
    label: "Ready to lend",
    help: "Kept free so members can borrow from the pot.",
  },
  {
    key: "aave",
    label: "Aave",
    help: "Lent out on Aave (test vault): steady interest.",
  },
  {
    key: "lp",
    label: "LP pool",
    help: "Put in a trading pool (test vault): earns more, but its value can go down.",
  },
  {
    key: "cash",
    label: "Cash",
    help: "Kept as cash for payouts and people leaving.",
  },
];
/** What a practice fund manager proposes: "safer" unless the plan already is that, then "more growth". */
const PRESET_SAFE: Alloc = { loan: 4_000, aave: 3_500, lp: 1_500, cash: 1_000 };
const PRESET_GROWTH: Alloc = {
  loan: 4_000,
  aave: 2_500,
  lp: 2_500,
  cash: 1_000,
};
const sameAlloc = (a: Alloc, b: Alloc) =>
  a.loan === b.loan && a.aave === b.aave && a.lp === b.lp && a.cash === b.cash;
export const encodeAlloc = (a: Alloc) =>
  encodeAbiParameters(
    [
      { type: "uint16" },
      { type: "uint16" },
      { type: "uint16" },
      { type: "uint16" },
    ],
    [a.loan, a.aave, a.lp, a.cash],
  );
/** The contract's backer interest (Queue._fundOne): vouch amount x rate, agree half of it; a backer can lose the pledge. */
export const ifBacked = (amount: bigint, rateBps: number, agree = false) => ({
  amount: amount.toString(),
  couldLose: amount.toString(),
  wouldEarn: (
    (amount * BigInt(rateBps)) /
    (agree ? 20_000n : 10_000n)
  ).toString(),
});
const STATUS = ["Forming", "Active", "Completed", "Cancelled"] as const;
const RULE_FIELDS = [
  ["ownLtvBps", "Share of your savings you can borrow"],
  ["ownRateBps", "Interest on borrowing your own savings"],
  ["perLoanMaxBps", "Largest single loan (share of the pot)"],
  ["fastLaneBps", "Fast-lane share"],
  ["penaltyBps", "Penalty for not repaying"],
  ["contribFineBps", "Fine for a late round"],
  ["installFineBps", "Fine for a late repayment"],
  ["exitFeeBps", "Fee for leaving early"],
  ["managerFeeBps", "Manager fee"],
] as const;
/** The defaults the web app uses for createCircle (the tutorial's tested S1 rules). */
export const DEFAULTS = {
  fixed: {
    lockBps: 2_000,
    minSaveEpochs: 3,
    minMembers: 5,
    maxRepayEpochs: 3,
    cooldownEpochs: 1,
  },
  rules: {
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
  },
  offeredRateBps: 800,
};

export class AppError extends Error {
  status: 400 | 401 | 403 | 404 | 409 | 429 | 503;
  constructor(status: AppError["status"], message: string) {
    super(message);
    this.status = status;
  }
}

type Grant = {
  time: number;
  what: string;
  amount: string;
  txHash: `0x${string}`;
  block: number;
};
type Store = {
  names: Record<string, string>; // lowercase address -> name
  grants: Record<string, Grant[]>;
  faucet: Record<string, number>;
  privy: Record<string, string>; // privy user id -> lowercase address
  sessions: Record<string, string>; // lowercase address -> privy user id
};

const loadStore = (path: string): Store => {
  const empty: Store = {
    names: {},
    grants: {},
    faucet: {},
    privy: {},
    sessions: {},
  };
  try {
    if (existsSync(path))
      return { ...empty, ...JSON.parse(readFileSync(path, "utf8")) };
  } catch {
    // a broken file only loses names and history
  }
  return empty;
};

/** Smaller of two bigints (Math.min does not take bigints). */
const minB = (a: bigint, b: bigint) =>
  [a, b].sort((x, y) => (x < y ? -1 : 1))[0];
const b64 = (s: string) => Buffer.from(s).toString("base64url");
const firstLine = (e: unknown) =>
  String((e as Error)?.message ?? e).split("\n")[0];

/** Plain words for the contract's revert names that a user can hit. */
const REASONS: Record<string, string> = {
  NotVerified: "Please finish signing up first.",
  HasOpenDebt: "You have unpaid debt in a circle.",
  NotInvited: "You need an invite from the person who made this circle.",
  AlreadyMember: "You are already in this circle.",
  CircleFull: "This circle is full.",
  FormingClosed: "This circle has already started.",
  NotForming: "This circle is no longer taking members.",
  LockWindow: "This is paused until the round closes.",
  SettlementPending: "The last round is still closing. Try again in a moment.",
  NotPending: "That loan request is no longer waiting for backers.",
  OverPledged: "That loan is already fully backed.",
  ExceedsFreeSavings: "Not enough free savings to back that loan.",
  NotActive: "This circle is not running.",
  MembershipCapReached: "Someone is already in 5 unfinished circles.",
};
const reason = (e: unknown) => {
  const m =
    /reverted with the following reason:\s*\n?\s*(\w+)|error:\s*(\w+)\(/.exec(
      String((e as Error)?.message ?? ""),
    );
  const name =
    m?.[1] ??
    m?.[2] ??
    Object.keys(REASONS).find((k) =>
      String((e as Error)?.message ?? "").includes(k),
    );
  return name ? REASONS[name] : undefined;
};

type StateRaw = {
  name: string;
  creator: Address;
  status: number;
  memberCount: bigint;
  currentEpoch: bigint;
  window: number;
  settledEpoch: bigint;
  fixedParams: {
    contribution: bigint;
    epochDuration: number;
    lockBps: number;
    startTime: bigint;
    minSaveEpochs: number;
    totalEpochs: number;
    minMembers: number;
    maxMembers: number;
    maxRepayEpochs: number;
    cooldownEpochs: number;
  };
  rules: Record<string, number>;
  manager: Address;
  loanCount: bigint;
  proposalCount: bigint;
};
type MemberExtra = {
  cooldownUntil: number;
  leavePending: boolean;
  paidBitmap: bigint;
};

export const createFujiApp = async (env: FujiEnv) => {
  const path =
    env.FUJI_DEPLOYMENT_PATH ??
    new URL("../../../deployments/fuji.json", import.meta.url).pathname;
  const c: Chain = await connect(
    {
      RPC_URL: env.FUJI_RPC_URL,
      ADMIN_PRIVATE_KEY: env.FUJI_ADMIN_PRIVATE_KEY,
      DEPLOYMENT_PATH: path,
    },
    { freezeTime: false, pollingInterval: env.POLL_MS },
  );
  const { abis } = c;
  const adminKey = env.FUJI_ADMIN_PRIVATE_KEY as `0x${string}`;
  const secret =
    env.SESSION_SECRET ?? toHex(crypto.getRandomValues(new Uint8Array(32)));
  if (!env.SESSION_SECRET)
    console.warn(
      "app: SESSION_SECRET not set; using a random one (sessions end on restart)",
    );
  const storePath = env.NAMES_PATH ?? join(tmpdir(), "kuber-app-names.json");
  const store = loadStore(storePath);
  const save = () => {
    try {
      writeFileSync(storePath, JSON.stringify(store));
    } catch (e) {
      console.error(`app: could not save names: ${firstLine(e)}`);
    }
  };
  const log = activity(c, BigInt(env.LOG_CHUNK), env.LOG_MIN_GAP_MS);
  const privy =
    env.PRIVY_APP_ID && env.PRIVY_APP_SECRET
      ? new PrivyClient({
          appId: env.PRIVY_APP_ID,
          appSecret: env.PRIVY_APP_SECRET,
        })
      : null;

  // ---------- transactions: one nonce stream per signer (the admin above all)
  const nonces = new Map<string, number>();
  const tails = new Map<string, Promise<unknown>>();
  const serial = <T>(key: string, fn: () => Promise<T>): Promise<T> => {
    const run = (tails.get(key) ?? Promise.resolve()).then(fn, fn);
    tails.set(
      key,
      run.catch(() => {}),
    );
    return run;
  };
  type Req = {
    to: Address;
    abi?: Abi;
    functionName?: string;
    args?: readonly unknown[];
    value?: bigint;
    gas?: bigint;
  };
  const fire = (account: Account, r: Req) =>
    serial(account.address, async () => {
      const wallet = createWalletClient({
        account,
        chain: c.chain,
        transport: c.transport,
      });
      const nonce =
        nonces.get(account.address) ??
        (await c.pub.getTransactionCount({
          address: account.address,
          blockTag: "pending",
        }));
      try {
        const hash = r.abi
          ? await wallet.writeContract({
              address: r.to,
              abi: r.abi,
              functionName: r.functionName,
              args: r.args ?? [],
              value: r.value,
              gas: r.gas,
              nonce,
            } as never)
          : await wallet.sendTransaction({
              to: r.to,
              value: r.value,
              nonce,
            } as never);
        nonces.set(account.address, nonce + 1);
        return hash;
      } catch (e) {
        nonces.delete(account.address);
        throw e;
      }
    });
  const wait = async (hash: `0x${string}`) => {
    const r = await c.pub.waitForTransactionReceipt({ hash });
    if (r.status !== "success") throw new Error("transaction reverted");
    return r;
  };
  const admin = c.admin;
  const adminTx = async (r: Req) => wait(await fire(admin, r));
  /** settle/activate: viem's bare estimate is too tight for the inner try/catch, so 1.5x (at least 1M). */
  const keeperTx = async (
    circle: Address,
    functionName: string,
    args: readonly unknown[],
  ) => {
    const est = await c.pub.estimateContractGas({
      address: circle,
      abi: abis.circle,
      functionName,
      args,
      account: admin,
    } as never);
    const gas = (est * 3n) / 2n < 1_000_000n ? 1_000_000n : (est * 3n) / 2n;
    return adminTx({
      to: circle,
      abi: abis.circle,
      functionName,
      args,
      gas: gas > 14_000_000n ? 14_000_000n : gas,
    });
  };

  // ---------- reads
  const read = c.read;
  const state = (circle: Address) =>
    read<StateRaw>(circle, abis.circle, "getCircleState");
  const now = async () => Number((await c.pub.getBlock()).timestamp);
  const isCircle = async (raw: string) => {
    if (!isAddress(raw, { strict: false }))
      throw new AppError(400, "That is not a circle address.");
    const a = getAddress(raw);
    if (!(await read<boolean>(c.registry, abis.registry, "isCircle", [a])))
      throw new AppError(404, "There is no circle at that address.");
    return a;
  };

  // ---------- test-vault demo controls (round 3): real admin transactions on the mock vaults
  const vaultCfg = {
    aaveApy: 0,
    lpApy: 0,
    speedup: 1,
    owned: false,
    note: null as string | null,
  };
  const [aaveVault, lpVault] = await Promise.all([
    read<Address>(c.factory, abis.factory, "AAVE_VAULT"),
    read<Address>(c.factory, abis.factory, "LP_VAULT"),
  ]);
  const vaultAbi = mockLpVaultAbi as Abi;
  // Never touch the tutorial chain's vaults (its end numbers depend on them): skip when pointed at its deployment file.
  const tutorialVaults =
    resolve(path) ===
    resolve(
      new URL("../../../deployments/local.json", import.meta.url).pathname,
    );
  const configureVaults = async () => {
    const owners = await Promise.all(
      [aaveVault, lpVault].map((v) => read<Address>(v, vaultAbi, "owner")),
    );
    vaultCfg.owned =
      !tutorialVaults &&
      owners.every((o) => o.toLowerCase() === admin.address.toLowerCase());
    if (tutorialVaults)
      console.warn(
        "app: pointed at the tutorial's deployment; leaving its test vaults alone",
      );
    const want = [
      [aaveVault, env.VAULT_AAVE_APY_BPS],
      [lpVault, env.VAULT_LP_APY_BPS],
    ] as const;
    if (vaultCfg.owned && env.VAULT_SPEEDUP > 0) {
      const t = BigInt(await now());
      for (const [v, apy] of want) {
        const [cur, sp] = await Promise.all([
          read<number>(v, vaultAbi, "apyBps"),
          read<number>(v, vaultAbi, "speedup"),
        ]);
        if (Number(cur) !== apy)
          await adminTx({
            to: v,
            abi: vaultAbi,
            functionName: "setApy",
            args: [apy, t],
            // fixed gas: the estimate is taken before the vault accrues interest, and the accrual mint then needs more
            gas: 500_000n,
          });
        if (Number(sp) !== env.VAULT_SPEEDUP)
          await adminTx({
            to: v,
            abi: vaultAbi,
            functionName: "setSpeedup",
            args: [env.VAULT_SPEEDUP],
            // fixed gas: the estimate is taken before the vault accrues interest, and the accrual mint then needs more
            gas: 500_000n,
          });
      }
      console.log(
        `app: test vaults set (Aave ${env.VAULT_AAVE_APY_BPS / 100}%, LP ${env.VAULT_LP_APY_BPS / 100}%, speed-up ${env.VAULT_SPEEDUP})`,
      );
    } else if (!vaultCfg.owned && !tutorialVaults)
      console.warn("app: the admin does not own the test vaults; leaving them");
    const [a, l, sp] = await Promise.all([
      read<number>(aaveVault, vaultAbi, "apyBps"),
      read<number>(lpVault, vaultAbi, "apyBps"),
      read<number>(aaveVault, vaultAbi, "speedup"),
    ]);
    vaultCfg.aaveApy = Number(a);
    vaultCfg.lpApy = Number(l);
    vaultCfg.speedup = Number(sp);
    const perRound = Math.round((120 * vaultCfg.speedup) / 86_400);
    vaultCfg.note =
      vaultCfg.speedup > 1
        ? `Test vaults: interest is sped up so a 2-minute round earns about ${perRound >= 28 && perRound <= 31 ? "a month" : `${perRound} days`} of interest${vaultCfg.owned && env.VAULT_SPEEDUP > 0 && env.LP_MOVE_EVERY_MS > 0 ? ", and the server moves the LP pool's price up and down now and then" : ""}.`
        : null;
  };
  const vaultsReady = configureVaults().catch((e) =>
    console.error(`app: test vaults: ${firstLine(e)}`),
  );
  // LP pool price moves from the keeper loop: up a little three times out of four, down a little the fourth.
  let lpMoves = 0;
  let lpMovedAt = Date.now();
  const moveLp = async (force = false) => {
    if (
      !vaultCfg.owned ||
      env.VAULT_SPEEDUP === 0 ||
      env.LP_MOVE_EVERY_MS === 0
    )
      return null;
    if (!force && Date.now() - lpMovedAt < env.LP_MOVE_EVERY_MS) return null;
    lpMovedAt = Date.now();
    const bps =
      lpMoves++ % 4 === 3 ? -env.LP_MOVE_DOWN_BPS : env.LP_MOVE_UP_BPS;
    await adminTx({
      to: lpVault,
      abi: vaultAbi,
      functionName: "shock",
      args: [bps],
      // fixed gas: the estimate is taken before the vault accrues interest, and the accrual mint then needs more
      gas: 500_000n,
    });
    console.log(
      `keeper: LP pool moved ${bps > 0 ? "up" : "down"} ${Math.abs(bps) / 100}%`,
    );
    return bps;
  };

  // ---------- practice members: keys from the admin key + creator + the creator's circle number + index
  const practiceKeys = (creator: Address, n: number) =>
    Array.from({ length: PRACTICE_COUNT }, (_, i) =>
      privateKeyToAccount(
        keccak256(
          concat([
            adminKey,
            creator,
            toHex(n, { size: 32 }),
            toHex(i, { size: 32 }),
          ]),
        ),
      ),
    );
  const practiceCache = new Map<string, ReturnType<typeof practiceKeys>>();
  const practiceOf = async (circle: Address, creator?: Address) => {
    const hit = practiceCache.get(circle.toLowerCase());
    if (hit) return hit;
    await log.syncFactory();
    const who = creator ?? (await state(circle)).creator;
    const n = log
      .circlesBy(who)
      .findIndex((a) => a.toLowerCase() === circle.toLowerCase());
    if (n < 0) return [];
    const keys = practiceKeys(who, n);
    practiceCache.set(circle.toLowerCase(), keys);
    return keys;
  };
  const namesFor = async (circle: Address | null) => {
    const names: Names = new Map(Object.entries(store.names));
    if (circle)
      (await practiceOf(circle)).forEach((a, i) => {
        names.set(
          a.address.toLowerCase(),
          PRACTICE_NAMES[i] ?? `Practice member ${i + 1}`,
        );
      });
    return names;
  };

  /** Invited / JoinRequested / Joined addresses of a circle, from its logs. */
  const forming = async (circle: Address) => {
    const logs = (await log.logs(circle)) ?? [];
    const invited = new Set<string>();
    const requested = new Set<string>();
    const order: Address[] = [];
    for (const l of logs) {
      const who = l.args.who as Address | undefined;
      if (l.eventName === "Invited" && who) {
        if (!invited.has(who.toLowerCase())) order.push(who);
        invited.add(who.toLowerCase());
      }
      if (l.eventName === "JoinRequested" && who)
        requested.add(who.toLowerCase());
    }
    return { invited, requested, order };
  };

  const paidOutOf = async (circle: Address, user: Address) => {
    const logs = (await log.logs(circle)) ?? [];
    return logs
      .filter(
        (l) =>
          l.eventName === "Withdrawn" &&
          String(l.args.member).toLowerCase() === user.toLowerCase(),
      )
      .reduce((t, l) => t + BigInt(l.args.amount as bigint), 0n);
  };

  // ---------- the circle view: CircleSnapshot + live
  const view = async (circle: Address, user: Address) => {
    const [f, s, t, limits, queue, open, debt, verified] = await Promise.all([
      readFacts(c, circle, user, paidOutOf),
      state(circle),
      now(),
      read<readonly [bigint, bigint, bigint]>(
        circle,
        abis.circle,
        "loanLimits",
        [user],
      ),
      read<readonly number[]>(circle, abis.circle, "getQueue"),
      read<readonly number[]>(circle, abis.circle, "openProposals"),
      read<boolean>(c.registry, abis.registry, "hasOpenDebt", [user]),
      read<boolean>(c.registry, abis.registry, "verified", [user]),
    ]);
    const practice = await practiceOf(circle, s.creator);
    const names = await namesFor(circle);
    const snapshot = toSnapshot(f, names, false);
    const fx = s.fixedParams;
    const round = Number(s.currentEpoch);
    const total = fx.totalEpochs;
    const start = Number(fx.startTime);
    const dur = Number(fx.epochDuration);
    const active = s.status === 1;
    const pending = active && Number(s.settledEpoch) !== round - 1;
    const lockWindow = active && s.window === 1;
    const locked = pending || lockWindow;
    const me = f.members.find(
      (m) => m.address.toLowerCase() === user.toLowerCase(),
    ) as (Facts["members"][number] & MemberExtra) | undefined;
    const isMember = me?.status === 1;
    const fm = await forming(circle);
    const invited = fm.invited.has(user.toLowerCase());
    const beforeStart = s.status === 0 && t < start;
    const full = Number(s.memberCount) >= fx.maxMembers;
    const canJoin = beforeStart && invited && !me && !full && verified && !debt;
    const canRequest =
      beforeStart &&
      !invited &&
      !me &&
      verified &&
      !fm.requested.has(user.toLowerCase());
    const ownLimit = limits[2];
    // loanLimits is at today's pot; a request is checked when the round closes, after this round's savings are in.
    // Project: V' = V + unpaid savings of this round (V recovered from perLoanMax = V x loan% x perLoan%).
    const loanBps = BigInt(
      s.rules.alloc ? (s.rules.alloc as unknown as { loan: number }).loan : 0,
    );
    const perBps = BigInt(s.rules.perLoanMaxBps ?? 0);
    const unpaid =
      s.status === 1 && Number(s.currentEpoch) >= 1
        ? BigInt(
            f.members.filter(
              (m) =>
                m.status === 1 &&
                (BigInt(m.paidBitmap) & (1n << s.currentEpoch)) === 0n,
            ).length,
          ) * f.contribution
        : 0n;
    const projCap = limits[0] + (unpaid * loanBps) / 10_000n;
    const projPer =
      loanBps && perBps
        ? limits[1] + (unpaid * loanBps * perBps) / 100_000_000n
        : limits[1];
    const maxLoan = minB(projPer, projCap);
    const loan = me?.activeLoanId
      ? f.loans.find((l) => l.id === me.activeLoanId)
      : undefined;
    const maxRepay = Math.min(fx.maxRepayEpochs, total - round - 1);
    const reasonNoBorrow = (() => {
      if (s.status === 0) return "Loans open once the circle has started.";
      if (!active) return "This circle is not running any more.";
      if (!me) return "Only members can borrow.";
      if (me.status === 2) return "You are paused in this circle.";
      if (me.status !== 1) return "You are no longer in this circle.";
      if (me.paidCount < fx.minSaveEpochs)
        return `You need ${fx.minSaveEpochs} rounds of savings before you can borrow (you have ${me.paidCount}).`;
      if (me.activeLoanId) return "You already have a loan. Repay it first.";
      if (me.pendingRequestId)
        return "You already asked for a loan. It is paid out when a round closes, once it is fully backed.";
      if (round <= me.cooldownUntil)
        return `You just finished a loan. You can borrow again after round ${me.cooldownUntil}.`;
      if (maxRepay < 1)
        return "It is too late in this circle to borrow: a loan must be repaid before the last round.";
      if (debt) return "You have unpaid debt in a circle.";
      if (me.leavePending) return "You asked to leave this circle.";
      if (pending)
        return "The last round is still closing. Try again in a moment.";
      if (lockWindow)
        return "New loans are paused until this round closes. Try again in the next round.";
      return null;
    })();
    const nextDueRound = loan
      ? loan.fundedEpoch + 2 + loan.installmentsPaid
      : null;
    const installment = loan
      ? loan.installmentsPaid + 1 >= loan.repayEpochs
        ? loanOwed(loan)
        : installmentOf(loan)
      : 0n;
    const paidThisRound =
      !!me &&
      round >= 1 &&
      (BigInt(me.paidBitmap) & (1n << BigInt(round))) !== 0n;
    const dueNow =
      !!loan &&
      loan.status === 2 &&
      nextDueRound !== null &&
      round >= nextDueRound;
    const saveAmount =
      (paidThisRound || round < 1 ? 0n : f.contribution) +
      (dueNow ? installment : 0n);
    const canSave =
      active && isMember && round >= 1 && round <= total && saveAmount > 0n;
    const actionOk = active && !locked;
    const voteOk = active && !pending;
    const activeCount = f.members.filter((m) => m.status === 1).length;
    const proposals = f.proposals.map((p) => {
      const snap = snapshot.proposals.find((x) => x.id === p.id);
      return {
        id: p.id,
        title: snap?.title ?? "A change",
        yes: p.yes,
        no: p.no,
        needed: Math.floor(activeCount / 2) + 1,
        youVoted: p.youVoted,
        open: p.status === 1 && open.includes(p.id),
        status: snap?.status ?? "Unknown",
        kind: snap?.kind ?? "other",
        plan: snap?.plan ?? null,
      };
    });
    const free = me ? me.savings - me.pledgedOut : 0n;
    const canBackAny =
      actionOk &&
      isMember &&
      !me?.activeLoanId &&
      !me?.pendingRequestId &&
      free > 0n;
    const requests = queue.map((id) => {
      const l = f.loans.find((x) => x.id === Number(id));
      const rateBps = Number(
        (l as { offeredRateBps?: number } | undefined)?.offeredRateBps ?? 0,
      );
      const myAgree =
        l?.agreers.find((b) => b.backer.toLowerCase() === user.toLowerCase())
          ?.amount ?? 0n;
      const iVouched = !!l?.vouchers.some(
        (b) => b.backer.toLowerCase() === user.toLowerCase(),
      );
      const pledged = l
        ? [...l.vouchers, ...l.agreers].reduce((x, b) => x + b.amount, 0n)
        : 0n;
      const mine = !!l && l.borrower.toLowerCase() === user.toLowerCase();
      const need = l ? l.backedNeed - pledged : 0n;
      return {
        id: Number(id),
        borrower:
          snapshot.loans.find((x) => x.id === Number(id))?.borrower ?? "",
        amount: (l?.amount ?? 0n).toString(),
        repayRounds: l?.repayEpochs ?? 0,
        needsBacking: need.toString(),
        backedSoFar: pledged.toString(),
        rate: `${rateBps / 100}%`,
        rateBps,
        mine,
        canBack: canBackAny && !mine && need > 0n && myAgree === 0n,
        maxBack: minB(need, free).toString(),
        canAgree:
          canBackAny &&
          !mine &&
          need > 0n &&
          !iVouched &&
          f.contribution - myAgree > 0n,
        maxAgree: minB(minB(need, free), f.contribution - myAgree).toString(),
        // The suggested amount: what you can put in now, or what the request still needs.
        ifYouBack: ifBacked(
          canBackAny && !mine && need > 0n ? minB(need, free) : need,
          rateBps,
        ),
        ifYouAgree: ifBacked(
          minB(need, f.contribution - myAgree),
          rateBps,
          true,
        ),
      };
    });
    const isCreator = s.creator.toLowerCase() === user.toLowerCase();
    const practiceSet = new Set(practice.map((a) => a.address.toLowerCase()));
    const memberSet = new Set(f.members.map((m) => m.address.toLowerCase()));
    const practiceMembers = f.members.filter((m) =>
      practiceSet.has(m.address.toLowerCase()),
    ).length;
    const practiceInvited = practice.filter(
      (a) =>
        fm.invited.has(a.address.toLowerCase()) &&
        !memberSet.has(a.address.toLowerCase()),
    ).length;
    const nameOf = (a: Address) =>
      names.get(a.toLowerCase()) ?? `${a.slice(0, 6)}…${a.slice(-4)}`;
    // ---------- fund manager and money plan (round 3)
    const mgr = f.manager?.address ?? null;
    const isManager = !!mgr && mgr.toLowerCase() === user.toLowerCase();
    const openOf = (pred: (p: Facts["proposals"][number]) => boolean) =>
      f.proposals.some((p) => pred(p) && p.status === 1 && open.includes(p.id));
    const openPlan = openOf((p) => p.kind === 1);
    const openAppoint = openOf((p) => p.kind === 2 && p.target !== zeroAddress);
    const openFire = openOf((p) => p.kind === 2 && p.target === zeroAddress);
    const proposedBy = (a: string) =>
      f.proposals.some(
        (p) =>
          p.proposer.toLowerCase() === a.toLowerCase() && p.epoch === round,
      );
    const proposedThisRound = proposedBy(user);
    const proposeBase =
      actionOk && isMember && (me?.paidCount ?? 0) >= fx.minSaveEpochs;
    const canPropose = proposeBase && !proposedThisRound;
    const proposeReason = canPropose
      ? null
      : s.status === 0
        ? "Changes can be suggested once the circle has started."
        : !active
          ? "This circle is not running any more."
          : !isMember
            ? "Only members can suggest changes."
            : (me?.paidCount ?? 0) < fx.minSaveEpochs
              ? `You need ${fx.minSaveEpochs} rounds of savings before you can suggest a change (you have ${me?.paidCount ?? 0}).`
              : pending
                ? "The last round is still closing. Try again in a moment."
                : lockWindow
                  ? "Suggestions are paused until this round closes."
                  : "You already suggested a change this round. You can suggest another next round.";
    const managerName = mgr ? nameOf(mgr) : null;
    const planNote =
      mgr && !isManager
        ? `Only the fund manager, ${managerName}, can suggest a new money plan. Everyone still votes on it.`
        : openPlan
          ? "A new money plan is already up for a vote this round."
          : null;
    const alloc = f.alloc;
    const preset = sameAlloc(alloc, PRESET_SAFE) ? PRESET_GROWTH : PRESET_SAFE;
    const mgrMember = mgr
      ? f.members.find((m) => m.address.toLowerCase() === mgr.toLowerCase())
      : undefined;
    const mgrPractice = !!mgr && practiceSet.has(mgr.toLowerCase());
    const askReason = !mgr
      ? "There is no fund manager yet."
      : !mgrPractice
        ? "The fund manager is not a practice member."
        : !isMember
          ? "Only members can ask the fund manager."
          : openPlan
            ? "A new money plan is already up for a vote this round."
            : proposedBy(mgr as string)
              ? `${managerName} already suggested a change this round. Try again next round.`
              : !actionOk
                ? "Proposals are paused until this round closes."
                : mgrMember?.status !== 1 ||
                    (mgrMember?.paidCount ?? 0) < fx.minSaveEpochs
                  ? `${managerName} cannot suggest a change yet.`
                  : null;
    const lastRebalance = [...((await log.logs(circle)) ?? [])]
      .reverse()
      .find((l) => l.eventName === "Rebalanced");
    const since = (nowV: bigint, key: string) =>
      (
        nowV -
        (lastRebalance ? BigInt(lastRebalance.args[key] as bigint) : nowV)
      ).toString();
    const rules = RULE_FIELDS.map(([k, label], field) => ({
      field,
      label,
      current: s.rules[k],
      currentText: pct(s.rules[k]),
    }));
    return {
      ...snapshot,
      members: snapshot.members.map((m) => ({
        ...m,
        practice: practiceSet.has(m.address.toLowerCase()),
      })),
      live: {
        now: t,
        startsAt: start,
        roundEndsAt:
          active && round >= 1 && round <= total ? start + round * dur : null,
        roundLength: dur,
        locked,
        lockedReason: pending
          ? "The last round is still closing. Actions open again in a moment."
          : lockWindow
            ? "New loans, backing and proposals are paused until this round closes. You can still save, repay and vote."
            : null,
        minMembers: fx.minMembers,
        maxMembers: fx.maxMembers,
        memberCount: Number(s.memberCount),
        you: {
          isMember,
          invited,
          requested: fm.requested.has(user.toLowerCase()),
          canJoin,
          canRequest,
          wallet: f.userWallet.toString(),
          allowance: f.userAllowance.toString(),
          suggestedAllowance: (
            ((f.contribution *
              BigInt(Math.max(1, total - (me?.paidCount ?? 0))) +
              (loan ? loanOwed(loan) : 0n)) *
              11n) /
            10n
          ).toString(),
          loanLimit: maxLoan.toString(),
          loanLimitNow: minB(limits[1], limits[0]).toString(),
          ownLimit: ownLimit.toString(),
          maxRepayRounds: Math.max(0, maxRepay),
          offeredRateBps: DEFAULTS.offeredRateBps,
          rateLimits: { minBps: 0, maxBps: MAX_OFFERED_RATE },
          canBorrow: reasonNoBorrow === null,
          reasonNoBorrow,
          activeLoan: loan
            ? {
                id: loan.id,
                amount: loan.amount.toString(),
                owed: loanOwed(loan).toString(),
                nextDue:
                  loan.status === 2
                    ? { amount: installment.toString(), round: nextDueRound }
                    : null,
                status:
                  snapshot.loans.find((x) => x.id === loan.id)?.status ?? "",
                claimable: (me?.claimable ?? 0n).toString(),
              }
            : null,
          canClaim: !!me && me.claimable > 0n,
          canSave,
          saveAmount: saveAmount.toString(),
          paidThisRound,
          canRepayAll: !!loan && loan.status === 2 && isMember && active,
          canVote:
            voteOk && isMember && proposals.some((p) => p.open && !p.youVoted),
          canPropose,
          proposedThisRound,
          proposeReason,
          isManager,
          canProposeManager:
            canPropose &&
            !isManager &&
            !openAppoint &&
            f.members.some(
              (m) =>
                m.status === 1 &&
                m.address.toLowerCase() !== (mgr ?? "").toLowerCase(),
            ),
          canRemoveManager: canPropose && !!mgr && !isManager && !openFire,
          canProposePlan: canPropose && (!mgr || isManager) && !openPlan,
          canLeave:
            actionOk &&
            isMember &&
            !me?.activeLoanId &&
            !me?.pendingRequestId &&
            me?.pledgedOut === 0n &&
            !me?.leavePending,
          pendingLeave: !!me?.leavePending,
          canCollect:
            s.status === 2 &&
            !!me &&
            (me.status === 1 || me.status === 2) &&
            !me.withdrawn,
          freeSavings: free.toString(),
        },
        requests,
        proposals,
        rules,
        managerCandidates: f.members
          .filter(
            (m) =>
              m.status === 1 &&
              m.address.toLowerCase() !== (mgr ?? "").toLowerCase(),
          )
          .map((m) => ({
            address: m.address,
            name:
              m.address.toLowerCase() === user.toLowerCase()
                ? "You"
                : nameOf(m.address),
            practice: practiceSet.has(m.address.toLowerCase()),
          })),
        plan: { current: alloc, limits: PLAN_LIMITS, parts: PLAN_PARTS },
        planNote,
        canAskManagerPlan: askReason === null,
        askManagerPlanReason: askReason,
        askManagerPlanLabel: mgrPractice
          ? `Ask ${managerName} to propose a new money plan`
          : null,
        managerPreset: mgrPractice ? preset : null,
        managerPresetNote: mgrPractice
          ? preset === PRESET_SAFE
            ? `A little safer: ${planText(preset)}.`
            : `A little more growth: ${planText(preset)}.`
          : null,
        investments: {
          earnedSoFar: f.pot.earned.toString(),
          aave: {
            value: f.pot.aave.toString(),
            apyBps: vaultCfg.aaveApy,
            earnedThisRound: since(f.pot.aave, "aaveValue"),
          },
          lp: {
            value: f.pot.lp.toString(),
            apyBps: vaultCfg.lpApy,
            changeThisRound: since(f.pot.lp, "lpValue"),
          },
          note: vaultCfg.note,
        },
        isCreator,
        practiceMembers,
        practiceInvited,
        canAddPractice:
          isCreator && beforeStart && practiceInvited > 0 && !full,
        invites:
          isCreator && s.status === 0
            ? fm.order.map((a) => ({
                address: a,
                name: nameOf(a),
                joined: memberSet.has(a.toLowerCase()),
                practice: practiceSet.has(a.toLowerCase()),
              }))
            : [],
        joinRequests:
          isCreator && s.status === 0
            ? [...fm.requested]
                .filter((a) => !fm.invited.has(a) && !memberSet.has(a))
                .map((a) => ({
                  address: getAddress(a),
                  name: nameOf(getAddress(a)),
                }))
            : [],
      },
    };
  };

  // ---------- users
  const me = async (address: Address) => {
    const [verified, musdc, avax] = await Promise.all([
      read<boolean>(c.registry, abis.registry, "verified", [address]),
      read<bigint>(c.usdc, abis.usdc, "balanceOf", [address]),
      c.pub.getBalance({ address }),
    ]);
    return {
      address,
      name: store.names[address.toLowerCase()] ?? null,
      verified,
      musdc: musdc.toString(),
      avax: avax.toString(),
      granted: verified,
    };
  };
  const addGrant = async (
    address: Address,
    what: string,
    amount: bigint,
    hash: `0x${string}`,
  ) => {
    const r = await wait(hash);
    const b = await c.pub.getBlock({ blockNumber: r.blockNumber });
    const key = address.toLowerCase();
    store.grants[key] = [
      ...(store.grants[key] ?? []),
      {
        time: Number(b.timestamp),
        what,
        amount: amount.toString(),
        txHash: hash,
        block: Number(r.blockNumber),
      },
    ];
    save();
  };
  const onboarding = new Map<string, Promise<unknown>>();

  const sign = (address: Address) => {
    const body = b64(
      JSON.stringify({ a: address, e: Date.now() + SESSION_MS }),
    );
    return `${body}.${createHmac("sha256", secret).update(body).digest("base64url")}`;
  };
  const verifyToken = (token: string): Address | null => {
    const [body, mac] = token.split(".");
    if (!body || !mac) return null;
    const want = createHmac("sha256", secret).update(body).digest();
    const got = Buffer.from(mac, "base64url");
    if (got.length !== want.length || !timingSafeEqual(got, want)) return null;
    try {
      const { a, e } = JSON.parse(Buffer.from(body, "base64url").toString());
      if (typeof e !== "number" || e < Date.now() || !isAddress(a)) return null;
      return getAddress(a);
    } catch {
      return null;
    }
  };

  // ---------- keeper
  const keeperTick = async () => {
    await vaultsReady;
    await moveLp().catch((e) =>
      console.error(`keeper: LP move: ${firstLine(e)}`),
    );
    // Keeps the circle index fresh, so a new circle's logs are scanned from (about) its own block.
    await log.syncFactory();
    const list = await read<readonly Address[]>(
      c.factory,
      abis.factory,
      "allCircles",
    );
    const t = BigInt(await now());
    for (const circle of list) {
      try {
        let s = await state(circle);
        if (s.status === 0 && t >= BigInt(s.fixedParams.startTime)) {
          await keeperTx(circle, "activate", []);
          console.log(`keeper: activated ${circle}`);
          s = await state(circle);
        }
        if (s.status !== 1) continue;
        for (
          let i = 0;
          i < 20 && s.status === 1 && s.settledEpoch < s.currentEpoch - 1n;
          i++
        ) {
          await keeperTx(circle, "settle", [SETTLE_BATCH]);
          s = await state(circle);
        }
        if (s.status !== 1 || s.settledEpoch !== s.currentEpoch - 1n) continue;
        const open = await read<readonly number[]>(
          circle,
          abis.circle,
          "openProposals",
        );
        if (open.length === 0) continue;
        const practice = await practiceOf(circle, s.creator);
        const members = new Set(
          (await read<readonly Address[]>(circle, abis.circle, "members")).map(
            (a) => a.toLowerCase(),
          ),
        );
        const votes: Promise<unknown>[] = [];
        for (const id of open)
          for (const a of practice) {
            if (!members.has(a.address.toLowerCase())) continue;
            const ballot = await read<number>(circle, abis.circle, "ballotOf", [
              BigInt(id),
              a.address,
            ]);
            if (ballot === 0)
              votes.push(
                fire(a, {
                  to: circle,
                  abi: abis.circle,
                  functionName: "vote",
                  args: [BigInt(id), true],
                }).then(wait),
              );
          }
        await Promise.allSettled(votes);
      } catch (e) {
        console.error(`keeper: ${circle.slice(0, 10)}: ${firstLine(e)}`);
      }
    }
  };
  let stopped = false;
  let timer: ReturnType<typeof setTimeout> | null = null;
  const loop = async () => {
    if (stopped) return;
    try {
      await keeperTick();
    } catch (e) {
      console.error(`keeper: ${firstLine(e)}`);
    }
    if (!stopped) timer = setTimeout(loop, env.KEEPER_INTERVAL_MS);
  };
  if (env.KEEPER_INTERVAL_MS > 0) timer = setTimeout(loop, 0);
  const stop = () => {
    stopped = true;
    if (timer) clearTimeout(timer);
  };

  // ---------- HTTP
  const app = new Hono<{ Variables: { user: Address } }>().basePath("/api/app");
  app.onError((err, ctx) => {
    if (err instanceof AppError)
      return ctx.json({ error: err.message }, err.status);
    const plainReason = reason(err);
    if (plainReason) return ctx.json({ error: plainReason }, 409);
    console.error(
      `app error on ${ctx.req.method} ${ctx.req.path}: ${firstLine(err)}`,
    );
    return ctx.json(
      { error: "Something went wrong on our side. Please try again." },
      500,
    );
  });
  app.notFound((ctx) => ctx.json({ error: "There is nothing here." }, 404));

  app.get("/health", async (ctx) =>
    ctx.json({
      ok: true,
      // Chain time (unix seconds): createCircle's startTime must be after it.
      now: await now().catch(() => Math.floor(Date.now() / 1000)),
      chainId: c.chainId,
      usdc: c.usdc,
      factory: c.factory,
      registry: c.registry,
      explorer: c.chainId === 43113 ? "https://testnet.snowtrace.io" : null,
      defaults: DEFAULTS,
    }),
  );

  const SessionBody = z.object({
    address: z
      .string()
      .refine(
        (a) => isAddress(a, { strict: false }),
        "That is not a wallet address.",
      ),
    message: z.string().max(300),
    signature: z
      .string()
      .regex(/^0x[0-9a-fA-F]+$/, "That signature doesn't look right."),
    privyToken: z.string().max(4000).optional(),
  });
  const parse = async <T>(
    ctx: { req: { json: () => Promise<unknown> } },
    schema: z.ZodType<T>,
  ) => {
    const raw = await ctx.req.json().catch(() => ({}));
    const r = schema.safeParse(raw ?? {});
    if (!r.success)
      throw new AppError(
        400,
        r.error.issues[0]?.message ?? "That request doesn't look right.",
      );
    return r.data;
  };

  app.post("/session", async (ctx) => {
    const b = await parse(ctx, SessionBody);
    const address = getAddress(b.address);
    const m = /^Kuber sign-in\nAddress: (0x[0-9a-fA-F]{40})\nTime: (.+)$/.exec(
      b.message,
    );
    if (!m || getAddress(m[1]) !== address)
      throw new AppError(400, "The sign-in message doesn't look right.");
    const at = Date.parse(m[2]);
    if (!Number.isFinite(at) || Math.abs(Date.now() - at) > SIGN_SKEW_MS)
      throw new AppError(401, "That sign-in is too old. Please sign in again.");
    const ok = await verifyMessage({
      address,
      message: b.message,
      signature: b.signature as `0x${string}`,
    }).catch(() => false);
    if (!ok)
      throw new AppError(401, "The signature doesn't match this wallet.");
    if (b.privyToken && privy) {
      try {
        // Never let a slow Privy key fetch hold up sign-in.
        const v = await Promise.race([
          privy.utils().auth().verifyAccessToken(b.privyToken),
          new Promise<never>((_, no) =>
            setTimeout(() => no(new Error("privy timeout")), 5_000),
          ),
        ]);
        store.sessions[address.toLowerCase()] = v.user_id;
        save();
      } catch {
        // an unverifiable Privy token only means the one-grant-per-person check is by address
      }
    }
    return ctx.json({ token: sign(address) });
  });

  app.use("*", async (ctx, next) => {
    if (
      ctx.req.path === "/api/app/health" ||
      ctx.req.path === "/api/app/session"
    )
      return next();
    const m = /^Bearer (\S+)$/.exec(ctx.req.header("authorization") ?? "");
    const user = m ? verifyToken(m[1]) : null;
    if (!user) return ctx.json({ error: "Please sign in first." }, 401);
    ctx.set("user", user);
    await next();
  });

  app.get("/me", async (ctx) => ctx.json(await me(ctx.get("user"))));

  const NameBody = z.object({
    name: z
      .string()
      .trim()
      .regex(
        /^[A-Za-z0-9 -]{3,24}$/,
        "A name is 3 to 24 letters, digits, spaces or dashes.",
      ),
  });
  app.post("/onboard", async (ctx) => {
    const user = ctx.get("user");
    const key = user.toLowerCase();
    const { name } = await parse(ctx, NameBody);
    const taken = Object.entries(store.names).some(
      ([a, n]) => a !== key && n.toLowerCase() === name.toLowerCase(),
    );
    if (taken)
      throw new AppError(409, "That name is taken. Please pick another one.");
    store.names[key] = name;
    save();
    const run =
      onboarding.get(key) ??
      (async () => {
        // The registry's verified flag is the durable "already granted" marker: set first, granted once.
        if (await read<boolean>(c.registry, abis.registry, "verified", [user]))
          return;
        const pid = store.sessions[key];
        const other = pid ? store.privy[pid] : undefined;
        if (other && other !== key)
          throw new AppError(
            409,
            "Your account already got its welcome money on another wallet.",
          );
        await adminTx({
          to: c.registry,
          abi: abis.registry,
          functionName: "setVerified",
          args: [user, true],
        });
        if (pid) {
          store.privy[pid] = key;
          save();
        }
        const grant = BigInt(env.WELCOME_GRANT_MUSDC) * USDC;
        const gas = parseEther(env.WELCOME_GAS_AVAX);
        const [h1, h2] = await Promise.all([
          fire(admin, {
            to: c.usdc,
            abi: abis.usdc,
            functionName: "mint",
            args: [user, grant],
          }),
          fire(admin, { to: user, value: gas }),
        ]);
        await addGrant(
          user,
          `Welcome money: ${money(grant).replace(" mUSDC", "")} test mUSDC`,
          grant,
          h1,
        );
        await addGrant(
          user,
          `Gas for transactions: ${env.WELCOME_GAS_AVAX} test AVAX`,
          0n,
          h2,
        );
      })().finally(() => onboarding.delete(key));
    onboarding.set(key, run);
    await run;
    return ctx.json(await me(user));
  });

  app.post("/faucet", async (ctx) => {
    const user = ctx.get("user");
    const key = user.toLowerCase();
    if (!(await read<boolean>(c.registry, abis.registry, "verified", [user])))
      throw new AppError(409, "Please finish signing up first.");
    const last = store.faucet[key] ?? 0;
    if (Date.now() - last < FAUCET_MS) {
      const mins = Math.ceil((FAUCET_MS - (Date.now() - last)) / 60_000);
      throw new AppError(
        429,
        `You can add test money once an hour. Try again in ${mins} minute${mins === 1 ? "" : "s"}.`,
      );
    }
    store.faucet[key] = Date.now();
    save();
    const amount = BigInt(env.FAUCET_MUSDC) * USDC;
    try {
      const h = await fire(admin, {
        to: c.usdc,
        abi: abis.usdc,
        functionName: "mint",
        args: [user, amount],
      });
      await addGrant(
        user,
        `Test money: ${money(amount).replace(" mUSDC", "")} test mUSDC`,
        amount,
        h,
      );
    } catch (e) {
      store.faucet[key] = last;
      save();
      throw e;
    }
    return ctx.json(await me(user));
  });

  app.get("/circles", async (ctx) => {
    const user = ctx.get("user");
    const [list, verified, t] = await Promise.all([
      read<readonly Address[]>(c.factory, abis.factory, "allCircles"),
      read<boolean>(c.registry, abis.registry, "verified", [user]),
      now(),
    ]);
    const rows = await Promise.all(
      [...list].reverse().map(async (address) => {
        const [s, m] = await Promise.all([
          state(address),
          read<{ status: number }>(address, abis.circle, "getMember", [user]),
        ]);
        const fm = s.status === 0 ? await forming(address) : null;
        const invited = !!fm?.invited.has(user.toLowerCase());
        const beforeStart =
          s.status === 0 && t < Number(s.fixedParams.startTime);
        const total = s.fixedParams.totalEpochs;
        return {
          address,
          name: s.name,
          status: STATUS[s.status] ?? "Forming",
          members: Number(s.memberCount),
          maxMembers: s.fixedParams.maxMembers,
          round: Math.min(Number(s.currentEpoch), total),
          totalRounds: total,
          contribution: s.fixedParams.contribution.toString(),
          startsAt: Number(s.fixedParams.startTime),
          mine: m.status !== 0,
          invited,
          canJoin:
            beforeStart &&
            invited &&
            m.status === 0 &&
            verified &&
            Number(s.memberCount) < s.fixedParams.maxMembers,
          canRequest:
            beforeStart &&
            !invited &&
            m.status === 0 &&
            verified &&
            !fm?.requested.has(user.toLowerCase()),
        };
      }),
    );
    return ctx.json(rows);
  });

  app.get("/circles/:address", async (ctx) => {
    const circle = await isCircle(ctx.req.param("address"));
    return ctx.json(await view(circle, ctx.get("user")));
  });

  const strip = (e: ActivityEntry) => {
    const { actor: _a, ...rest } = e;
    return rest;
  };
  app.get("/circles/:address/activity", async (ctx) => {
    const circle = await isCircle(ctx.req.param("address"));
    const user = ctx.get("user");
    const names = await namesFor(circle);
    const nameOf = (a: Address) =>
      a.toLowerCase() === user.toLowerCase()
        ? "You"
        : (names.get(a.toLowerCase()) ?? `${a.slice(0, 6)}…${a.slice(-4)}`);
    return ctx.json((await log.forCircle(circle, nameOf)).map(strip));
  });

  app.get("/activity", async (ctx) => {
    const user = ctx.get("user");
    const key = user.toLowerCase();
    const list = await read<readonly Address[]>(
      c.factory,
      abis.factory,
      "allCircles",
    );
    const mineList = (
      await Promise.all(
        list.map(async (a) => {
          const m = await read<{ status: number }>(
            a,
            abis.circle,
            "getMember",
            [user],
          );
          return m.status !== 0 ? a : null;
        }),
      )
    ).filter((a): a is Address => !!a);
    const out: (Omit<ActivityEntry, "actor"> & { circle: string | null })[] =
      [];
    for (const circle of mineList) {
      const [s, names] = await Promise.all([state(circle), namesFor(circle)]);
      const nameOf = (a: Address) =>
        a.toLowerCase() === key
          ? "You"
          : (names.get(a.toLowerCase()) ?? `${a.slice(0, 6)}…${a.slice(-4)}`);
      for (const e of await log.forCircle(circle, nameOf))
        if (e.actor === key) out.push({ ...strip(e), circle: s.name });
    }
    for (const g of store.grants[key] ?? [])
      out.push({
        time: g.time,
        who: "Kuber",
        what: g.what,
        amount: g.amount === "0" ? null : g.amount,
        txHash: g.txHash,
        block: g.block,
        circle: null,
      });
    out.sort((x, y) => y.block - x.block || y.time - x.time);
    return ctx.json(out.slice(0, 200));
  });

  app.get("/practice-invites", async (ctx) => {
    const user = ctx.get("user");
    await log.syncFactory();
    const n = log.circlesBy(user).length;
    return ctx.json({ invites: practiceKeys(user, n).map((a) => a.address) });
  });

  const CountBody = z.object({
    count: z.coerce
      .number()
      .int()
      .min(1)
      .max(PRACTICE_COUNT)
      .default(PRACTICE_COUNT),
  });
  app.post("/circles/:address/practice-members", async (ctx) => {
    const circle = await isCircle(ctx.req.param("address"));
    const user = ctx.get("user");
    const { count } = await parse(ctx, CountBody);
    const s = await state(circle);
    if (s.creator.toLowerCase() !== user.toLowerCase())
      throw new AppError(
        403,
        "Only the person who made this circle can add practice members.",
      );
    if (s.status !== 0 || (await now()) >= Number(s.fixedParams.startTime) - 5)
      throw new AppError(
        409,
        "Practice members can only join before the circle starts.",
      );
    const practice = await practiceOf(circle, s.creator);
    const fm = await forming(circle);
    const members = new Set(
      (await read<readonly Address[]>(circle, abis.circle, "members")).map(
        (a) => a.toLowerCase(),
      ),
    );
    const room = s.fixedParams.maxMembers - members.size;
    const todo = practice
      .filter(
        (a) =>
          fm.invited.has(a.address.toLowerCase()) &&
          !members.has(a.address.toLowerCase()),
      )
      .slice(0, Math.min(count, room));
    if (todo.length === 0)
      throw new AppError(
        409,
        practice.some((a) => members.has(a.address.toLowerCase()))
          ? "All the practice members are already in this circle."
          : "This circle was made without practice members. Make a new circle in the app to use them.",
      );
    const fx = s.fixedParams;
    const need = (fx.contribution * BigInt(fx.totalEpochs) * 12n) / 10n;
    const gas = parseEther(env.PRACTICE_GAS_AVAX);
    // Admin part first (verified, gas, test money), all in one nonce stream, then the members' own approve + join.
    const hashes: `0x${string}`[] = [];
    for (const a of todo) {
      const [v, bal, avax] = await Promise.all([
        read<boolean>(c.registry, abis.registry, "verified", [a.address]),
        read<bigint>(c.usdc, abis.usdc, "balanceOf", [a.address]),
        c.pub.getBalance({ address: a.address }),
      ]);
      if (!v)
        hashes.push(
          await fire(admin, {
            to: c.registry,
            abi: abis.registry,
            functionName: "setVerified",
            args: [a.address, true],
          }),
        );
      if (bal < need)
        hashes.push(
          await fire(admin, {
            to: c.usdc,
            abi: abis.usdc,
            functionName: "mint",
            args: [a.address, need - bal],
          }),
        );
      if (avax < gas / 2n)
        hashes.push(await fire(admin, { to: a.address, value: gas }));
    }
    await Promise.all(hashes.map(wait));
    const own: `0x${string}`[] = [];
    for (const a of todo) {
      own.push(
        await fire(a, {
          to: c.usdc,
          abi: abis.usdc,
          functionName: "approve",
          args: [circle, need * 2n],
        }),
      );
      own.push(
        await fire(a, { to: circle, abi: abis.circle, functionName: "join" }),
      );
    }
    await Promise.all(own.map(wait));
    return ctx.json(await view(circle, user));
  });

  const BackBody = z.object({ requestId: z.coerce.number().int().positive() });
  app.post("/circles/:address/practice-back", async (ctx) => {
    const circle = await isCircle(ctx.req.param("address"));
    const user = ctx.get("user");
    const { requestId } = await parse(ctx, BackBody);
    const f = await readFacts(c, circle, user, paidOutOf);
    const loan = f.loans.find((l) => l.id === requestId);
    if (loan?.status !== 1)
      throw new AppError(409, "That loan request is not waiting for backers.");
    if (loan.borrower.toLowerCase() !== user.toLowerCase())
      throw new AppError(
        403,
        "Practice members only back your own loan requests.",
      );
    let need =
      loan.backedNeed -
      [...loan.vouchers, ...loan.agreers].reduce((t, b) => t + b.amount, 0n);
    if (need <= 0n)
      throw new AppError(409, "Your loan is already fully backed.");
    const s = await state(circle);
    if (s.window === 1 || Number(s.settledEpoch) !== Number(s.currentEpoch) - 1)
      throw new AppError(
        409,
        "Backing is paused until this round closes. Try again in the next round.",
      );
    const practice = new Map(
      (await practiceOf(circle, s.creator)).map((a) => [
        a.address.toLowerCase(),
        a,
      ]),
    );
    const helpers = f.members
      .filter(
        (m) =>
          practice.has(m.address.toLowerCase()) &&
          m.status === 1 &&
          !m.activeLoanId &&
          !m.pendingRequestId &&
          m.savings > m.pledgedOut,
      )
      .sort((a, b) =>
        b.savings - b.pledgedOut > a.savings - a.pledgedOut ? 1 : -1,
      );
    const free = helpers.reduce((t, m) => t + m.savings - m.pledgedOut, 0n);
    if (helpers.length === 0 || free < need)
      throw new AppError(
        409,
        `The practice members can back up to ${money(free)} right now, and your loan needs ${money(need)}. Ask for a smaller loan.`,
      );
    for (const m of helpers) {
      if (need <= 0n) break;
      const amt = minB(m.savings - m.pledgedOut, need);
      const acct = practice.get(m.address.toLowerCase()) as Account;
      await wait(
        await fire(acct, {
          to: circle,
          abi: abis.circle,
          functionName: "vouch",
          args: [BigInt(requestId), amt],
        }),
      );
      need -= amt;
    }
    return ctx.json(await view(circle, user));
  });

  // Item 3: the practice fund manager proposes a preset money plan (its own real propose transaction).
  app.post("/circles/:address/practice-plan", async (ctx) => {
    const circle = await isCircle(ctx.req.param("address"));
    const user = ctx.get("user");
    const v = await view(circle, user);
    if (!v.live.canAskManagerPlan || !v.live.managerPreset || !v.manager)
      throw new AppError(
        409,
        v.live.askManagerPlanReason ?? "That cannot be done right now.",
      );
    const s = await state(circle);
    const acct = (await practiceOf(circle, s.creator)).find(
      (a) => a.address.toLowerCase() === s.manager.toLowerCase(),
    );
    if (!acct)
      throw new AppError(409, "The fund manager is not a practice member.");
    await wait(
      await fire(acct, {
        to: circle,
        abi: abis.circle,
        functionName: "propose",
        args: [1, encodeAlloc(v.live.managerPreset)],
      }),
    );
    return ctx.json(await view(circle, user));
  });

  // Item 5: the risk and the reward of backing `amount` (the contract's own formula; see ifBacked).
  app.get("/circles/:address/requests/:id/if-you-back", async (ctx) => {
    const circle = await isCircle(ctx.req.param("address"));
    const id = Number(ctx.req.param("id"));
    const raw = ctx.req.query("amount") ?? "";
    const how = ctx.req.query("how") === "agree" ? "agree" : "vouch";
    if (!Number.isInteger(id) || id < 1 || !/^\d{1,30}$/.test(raw))
      throw new AppError(400, "Give a loan request and an amount.");
    const s = await state(circle);
    if (id > Number(s.loanCount))
      throw new AppError(404, "There is no such loan request.");
    const l = await read<{ offeredRateBps: number }>(
      circle,
      abis.circle,
      "getLoan",
      [BigInt(id)],
    );
    const rateBps = Number(l.offeredRateBps);
    return ctx.json({
      how,
      ...ifBacked(BigInt(raw), rateBps, how === "agree"),
      rateBps,
    });
  });

  const nameRows = (
    q: (a: string, n: string) => boolean,
    limit: number,
    skip?: string,
  ) =>
    Object.entries(store.names)
      .filter(([a, n]) => a !== skip && q(a, n))
      .slice(0, limit)
      .map(([a, n]) => ({ address: getAddress(a), name: n }));

  app.get("/names", async (ctx) => {
    const addrs = (ctx.req.query("addrs") ?? "")
      .split(",")
      .map((a) => a.trim())
      .filter((a) => isAddress(a, { strict: false }))
      .slice(0, 100);
    return ctx.json(
      addrs.map((a) => ({
        address: getAddress(a),
        name: store.names[a.toLowerCase()] ?? null,
      })),
    );
  });
  app.get("/lookup", async (ctx) => {
    const name = (ctx.req.query("name") ?? "").trim();
    const [hit] = nameRows(
      (_a, n) => n.toLowerCase() === name.toLowerCase(),
      1,
    );
    if (!hit)
      throw new AppError(404, `${name || "That name"} is not on Kuber yet.`);
    return ctx.json(hit);
  });
  app.get("/people", async (ctx) => {
    const q = (ctx.req.query("q") ?? "").trim().toLowerCase();
    return ctx.json(
      nameRows(
        (_a, n) => !q || n.toLowerCase().includes(q),
        8,
        ctx.get("user").toLowerCase(),
      ),
    );
  });

  return {
    app,
    chain: c,
    stop,
    keeperTick,
    practiceKeys,
    vaultsReady,
    vaults: { aave: aaveVault, lp: lpVault },
    moveLp,
    encodeRule: (field: number, bps: number) =>
      encodeAbiParameters(
        [{ type: "uint8" }, { type: "uint256" }],
        [field, BigInt(bps)],
      ),
  };
};
