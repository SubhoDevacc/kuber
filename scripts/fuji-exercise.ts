// node scripts/fuji-exercise.ts [--api <url>] [--rpc <url>]
// Runs three sample circles on Avalanche Fuji through the live Kuber server and the real contracts. Throwaway wallets
// live in memory only (never written or printed); the server grants them test mUSDC and a little AVAX. Writes the
// summary (addresses, tx hashes, counts, times; no keys) to deployments/fuji-exercise.json.
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { parseArgs } from "node:util";
import {
  type Address,
  BaseError,
  ContractFunctionRevertedError,
  createPublicClient,
  createWalletClient,
  defineChain,
  encodeAbiParameters,
  type Hash,
  http,
  parseEventLogs,
} from "viem";
import { generatePrivateKey, privateKeyToAccount } from "viem/accounts";
import {
  kuberCircleAbi,
  kuberFactoryAbi,
  mockUsdcAbi,
} from "../packages/shared/src/generated.ts";

const { values } = parseArgs({
  options: {
    api: {
      type: "string",
      default: "https://kuber-production.up.railway.app/api/app",
    },
    rpc: {
      type: "string",
      default: "https://avalanche-fuji-c-chain-rpc.publicnode.com",
    },
    // Round length in seconds (default 120).
    round: { type: "string", default: "120" },
    // Run only the two-user circle again with other sample names; merges into the existing summary file.
    rerun: { type: "boolean", default: false },
  },
});
const API = values.api as string;
const RPC = values.rpc as string;
const USDC = 1_000_000n;
const ROUND = Number(values.round);
const RERUN = values.rerun as boolean;
const EXPLORER = "https://testnet.snowtrace.io";
const startedAt = new Date().toISOString();

const chain = defineChain({
  id: 43113,
  name: "Avalanche Fuji",
  nativeCurrency: { name: "Avalanche", symbol: "AVAX", decimals: 18 },
  rpcUrls: { default: { http: [RPC] } },
});
const pub = createPublicClient({
  chain,
  transport: http(RPC, { retryCount: 3 }),
  pollingInterval: 2_000,
});

// biome-ignore lint/suspicious/noExplicitAny: loose server JSON
type J = any;
type User = {
  name: string;
  account: ReturnType<typeof privateKeyToAccount>;
  wallet: ReturnType<typeof createWalletClient>;
  token: string;
};
type Tx = {
  circle: string;
  action: string;
  from: string;
  hash: Hash;
  ok: boolean;
  time: string;
};
const txs: Tx[] = [];
const serverCalls: { circle: string; action: string; ok: boolean }[] = [];
const failures: { circle: string; action: string; reason: string }[] = [];
let serverTrouble = false;
let serverBlip = false;

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const t = () => new Date().toISOString().slice(11, 19);
const log = (tag: string, msg: string) => console.log(`${t()} [${tag}] ${msg}`);
const usd = (s: string | bigint) => (Number(BigInt(s)) / 1e6).toFixed(2);

const api = async (
  u: User | null,
  method: string,
  path: string,
  body?: unknown,
) => {
  for (let i = 0; i < 5; i++) {
    try {
      const res = await fetch(`${API}${path}`, {
        method,
        headers: {
          ...(u ? { authorization: `Bearer ${u.token}` } : {}),
          "content-type": "application/json",
        },
        body: body === undefined ? undefined : JSON.stringify(body),
        signal: AbortSignal.timeout(60_000),
      });
      const json = (await res.json().catch(() => ({}))) as J;
      // A redeploy shows up as 502/503/504 for a minute: wait and retry.
      if ([502, 503, 504].includes(res.status) && i < 4) {
        serverBlip = true;
        await sleep(5_000 * (i + 1));
        continue;
      }
      if (res.status === 429 || res.status === 503) {
        if (path !== "/faucet") serverTrouble = true;
      }
      return { status: res.status, json };
    } catch (e) {
      serverBlip = true;
      if (i === 4) return { status: 0, json: { error: String(e) } };
      await sleep(5_000 * (i + 1));
    }
  }
  return { status: 0, json: {} };
};

const reason = (e: unknown) => {
  if (e instanceof BaseError) {
    const rev = e.walk((x) => x instanceof ContractFunctionRevertedError);
    if (rev instanceof ContractFunctionRevertedError)
      return rev.data?.errorName ?? rev.reason ?? rev.shortMessage;
    return e.shortMessage;
  }
  return String(e).slice(0, 200);
};
const isRevert = (e: unknown) =>
  e instanceof BaseError &&
  !!e.walk((x) => x instanceof ContractFunctionRevertedError);

// Simulate, estimate × 1.5, send, wait for the receipt; retry once on a transient RPC error. Never throws.
const send = async (
  circle: string,
  action: string,
  u: User,
  address: Address,
  abi: unknown,
  functionName: string,
  args: unknown[] = [],
) => {
  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      const p = {
        account: u.account,
        address,
        abi,
        functionName,
        args,
      } as never;
      await pub.simulateContract(p);
      const gas = await pub.estimateContractGas(p);
      const hash = await u.wallet.writeContract({
        ...(p as object),
        chain,
        gas: (gas * 3n) / 2n,
      } as never);
      const r = await pub.waitForTransactionReceipt({
        hash,
        timeout: 120_000,
      });
      const ok = r.status === "success";
      txs.push({
        circle,
        action,
        from: u.name,
        hash,
        ok,
        time: new Date().toISOString(),
      });
      log(
        circle,
        `${u.name}: ${action} ${ok ? "ok" : "REVERTED"} ${EXPLORER}/tx/${hash}`,
      );
      return ok ? r : null;
    } catch (e) {
      if (!isRevert(e) && attempt === 0) {
        log(circle, `${u.name}: ${action} transient error, retrying once`);
        await sleep(4_000);
        continue;
      }
      failures.push({ circle, action, reason: reason(e) });
      log(circle, `${u.name}: ${action} refused: ${reason(e)}`);
      return null;
    }
  }
  return null;
};

const serverAction = async (
  circle: string,
  action: string,
  u: User,
  path: string,
  body?: unknown,
) => {
  const r = await api(u, "POST", path, body);
  const ok = r.status === 200;
  serverCalls.push({ circle, action, ok });
  if (!ok) failures.push({ circle, action, reason: r.json?.error ?? r.status });
  log(
    circle,
    `${u.name}: ${action} ${ok ? "ok" : `refused (${r.status}): ${r.json?.error}`}`,
  );
  return r;
};

// --- users
const signIn = async (name: string): Promise<User | null> => {
  const account = privateKeyToAccount(generatePrivateKey());
  const wallet = createWalletClient({
    account,
    chain,
    transport: http(RPC, { retryCount: 3 }),
  });
  const message = `Kuber sign-in\nAddress: ${account.address}\nTime: ${new Date().toISOString()}`;
  const s = await api(null, "POST", "/session", {
    address: account.address,
    message,
    signature: await account.signMessage({ message }),
  });
  if (s.status !== 200) {
    log("setup", `sign-in failed (${s.status}): ${s.json?.error}`);
    return null;
  }
  const u: User = { name, account, wallet, token: s.json.token };
  for (const n of [name, `${name} ${Math.floor(10 + Math.random() * 89)}`]) {
    const o = await api(u, "POST", "/onboard", { name: n });
    if (o.status === 200) {
      u.name = o.json.name ?? n;
      log(
        "setup",
        `${u.name} onboarded ${account.address}: ${usd(o.json.musdc)} mUSDC, ${(Number(BigInt(o.json.avax)) / 1e18).toFixed(3)} AVAX`,
      );
      if (BigInt(o.json.avax) < 10_000_000_000_000_000n) {
        log("setup", "funding looks low (avax < 0.01); adding no more users");
        serverTrouble = true;
      }
      return u;
    }
    log("setup", `onboard "${n}" refused (${o.status}): ${o.json?.error}`);
    if (o.status === 429 || o.status === 503) return null;
  }
  return null;
};

// --- circle plans: what each circle tries, spread over the rounds
type Plan = {
  name: string;
  saveRounds: number[];
  secondSaveRounds: number[];
  loans: number;
  managerRound: number;
  ruleRound: number;
  rule: [number, bigint];
  secondRuleRound: number;
  secondRule: [number, bigint];
  plans: number;
};
const PLANS: Plan[] = [
  {
    name: "Market friends",
    saveRounds: [1, 3, 5],
    secondSaveRounds: [2, 3, 4],
    loans: 2,
    managerRound: 2,
    ruleRound: 99,
    rule: [7, 200n],
    secondRuleRound: 2,
    secondRule: [5, 200n],
    plans: 1,
  },
  {
    name: "Harbor circle",
    saveRounds: [1, 2, 3, 4],
    secondSaveRounds: [],
    loans: 1,
    managerRound: 3,
    ruleRound: 99,
    rule: [7, 200n],
    secondRuleRound: 99,
    secondRule: [5, 200n],
    plans: 2,
  },
  {
    name: "Office savers",
    saveRounds: [3, 6],
    secondSaveRounds: [],
    loans: 1,
    managerRound: 4,
    ruleRound: 2,
    rule: [7, 200n],
    secondRuleRound: 99,
    secondRule: [5, 200n],
    plans: 1,
  },
];

type Circle = {
  plan: Plan;
  address: Address | null;
  creator: User;
  second: User | null;
  done: Set<string>;
  loansAsked: number;
  claimRound: number;
  backTried: Set<number>;
  backHow: Map<number, string>;
  plansAsked: number;
  finished: boolean;
};

let practiceQueue: Promise<unknown> = Promise.resolve();
const setupCircle = async (c: Circle, health: J) => {
  const tag = c.plan.name;
  const u = c.creator;
  const inv = await api(u, "GET", "/practice-invites");
  if (inv.status !== 200) {
    log(tag, `practice-invites failed (${inv.status}): ${inv.json?.error}`);
    return;
  }
  const invites = inv.json.invites as Address[];
  const now = BigInt((await api(null, "GET", "/health")).json.now ?? 0);
  const d = health.defaults;
  const fixed = {
    contribution: 100n * USDC,
    epochDuration: ROUND,
    lockBps: d.fixed.lockBps,
    startTime: now + (RERUN ? 90n : c.second ? 180n : 150n),
    minSaveEpochs: d.fixed.minSaveEpochs,
    totalEpochs: 6,
    minMembers: 5,
    maxMembers: 5,
    maxRepayEpochs: d.fixed.maxRepayEpochs,
    cooldownEpochs: d.fixed.cooldownEpochs,
  };
  const r = await send(
    tag,
    "createCircle",
    u,
    health.factory,
    kuberFactoryAbi,
    "createCircle",
    [c.plan.name, fixed, d.rules, invites],
  );
  if (!r) return;
  const [ev] = parseEventLogs({
    abi: kuberFactoryAbi,
    logs: r.logs,
    eventName: "CircleCreated",
  });
  c.address = (ev.args as { circle: Address }).circle;
  log(tag, `circle ${EXPLORER}/address/${c.address}`);
  const usdc = health.usdc as Address;
  let practice = 4;
  if (c.second) {
    const b = c.second;
    if (
      (await send(tag, "invite", u, c.address, kuberCircleAbi, "invite", [
        b.account.address,
      ])) &&
      (await send(tag, "approve", b, usdc, mockUsdcAbi, "approve", [
        c.address,
        3_000n * USDC,
      ])) &&
      (await send(tag, "join", b, c.address, kuberCircleAbi, "join"))
    )
      practice = 3;
    else c.second = null;
  }
  // The server's admin wallet adds practice members; ask for one circle at a time. A failed call may have added
  // some of them, so each retry asks only for the ones still missing.
  const addPractice = async () => {
    for (let i = 0; i < 6; i++) {
      const v = await api(u, "GET", `/circles/${c.address}`);
      const have = Number(v.json?.live?.memberCount ?? 0);
      const need = i === 0 ? practice : 5 - have;
      if (v.status === 200 && need <= 0) return;
      const r = await serverAction(
        tag,
        "practice-members",
        u,
        `/circles/${c.address}/practice-members`,
        { count: Math.min(4, Math.max(1, need)) },
      );
      if (r.status === 200) return;
      await sleep(10_000);
    }
  };
  const turn = practiceQueue.then(addPractice);
  practiceQueue = turn.then(
    () => undefined,
    () => undefined,
  );
  await turn;
  await send(tag, "approve", u, usdc, mockUsdcAbi, "approve", [
    c.address,
    3_000n * USDC,
  ]);
};

// One step for one user: the first useful thing the server's live flags allow. Returns true if it acted.
const step = async (c: Circle, u: User, v: J): Promise<boolean> => {
  const tag = c.plan.name;
  const a = c.address as Address;
  const L = v.live;
  const y = L?.you ?? {};
  const isCreator = u === c.creator;
  const key = (k: string) => `${u.name}:${k}`;
  const once = (k: string) => {
    if (c.done.has(key(k))) return false;
    c.done.add(key(k));
    return true;
  };
  const round = v.round as number;
  const tx = (action: string, fn: string, args: unknown[] = []) =>
    send(tag, action, u, a, kuberCircleAbi, fn, args);

  if (v.status === "Completed") {
    if (y.canCollect && once("withdraw")) {
      await tx("withdraw (collect share-out)", "withdraw");
      return true;
    }
    return false;
  }
  if (v.status !== "Active" || L.locked) return false;

  if (y.canClaim && once(`claim:${c.loansAsked}`)) {
    if (await tx("claim (take loan)", "claim")) c.claimRound = round;
    return true;
  }
  for (const p of L.proposals ?? []) {
    if (p.open && !p.youVoted && y.canVote && once(`vote:${p.id}`)) {
      await tx(`vote yes (${p.kind})`, "vote", [BigInt(p.id), true]);
      return true;
    }
  }
  for (const q of L.requests ?? []) {
    if (q.mine || BigInt(q.needsBacking) === 0n || c.backTried.has(q.id))
      continue;
    if (!isCreator) {
      c.backTried.add(q.id);
      const nth = c.backTried.size;
      if (nth === 1 && q.canBack && BigInt(q.maxBack) > 0n) {
        c.backHow.set(q.id, "vouch");
        await tx("vouch (back a loan)", "vouch", [
          BigInt(q.id),
          BigInt(q.maxBack),
        ]);
        return true;
      }
      if (q.canAgree && BigInt(q.maxAgree) > 0n) {
        c.backHow.set(q.id, "agree");
        await tx("agree (back a loan)", "agree", [
          BigInt(q.id),
          BigInt(q.maxAgree),
        ]);
        return true;
      }
      if (q.canBack && BigInt(q.maxBack) > 0n) {
        await tx("vouch (back a loan)", "vouch", [
          BigInt(q.id),
          BigInt(q.maxBack),
        ]);
        return true;
      }
      log(tag, `${u.name}: cannot back request ${q.id} (no canBack/canAgree)`);
    }
  }
  if (isCreator) {
    for (const q of L.requests ?? []) {
      if (!q.mine || BigInt(q.needsBacking) === 0n) continue;
      if (c.second && !c.backTried.has(q.id)) continue; // let the second user back first
      if (once(`practice-back:${q.id}`)) {
        await serverAction(
          tag,
          "practice-back",
          u,
          `/circles/${a}/practice-back`,
          { requestId: q.id },
        );
        return true;
      }
    }
  }
  const saves = isCreator ? c.plan.saveRounds : c.plan.secondSaveRounds;
  if (y.canSave && saves.includes(round) && once(`save:${round}`)) {
    await tx("payNow (save now)", "payNow");
    return true;
  }
  if (
    isCreator &&
    y.canRepayAll &&
    y.activeLoan &&
    (round > c.claimRound || round >= 6 || c.plan.loans > 1) &&
    once(`repay:${c.loansAsked}`)
  ) {
    await tx("repayAll", "repayAll");
    return true;
  }
  if (
    isCreator &&
    y.canBorrow &&
    !y.activeLoan &&
    c.loansAsked < c.plan.loans &&
    round <= 5 &&
    once(`borrow:${c.loansAsked + 1}`)
  ) {
    const own = BigInt(y.ownLimit ?? 0);
    const max = BigInt(y.loanLimit ?? 0);
    let amount = own + 10n * USDC;
    if (amount > max) amount = max;
    if (amount <= 0n) return false;
    const rounds = BigInt(Math.max(1, Math.min(2, y.maxRepayRounds ?? 1)));
    log(
      tag,
      `${u.name}: asking to borrow ${usd(amount)} (own limit ${usd(own)}, limit ${usd(max)})`,
    );
    if (
      await tx("requestLoan", "requestLoan", [
        amount,
        rounds,
        BigInt(y.offeredRateBps ?? 800),
        0n,
      ])
    )
      c.loansAsked++;
    return true;
  }
  if (
    isCreator &&
    round >= c.plan.managerRound &&
    y.canProposeManager &&
    y.canPropose &&
    !v.manager
  ) {
    const cand = (L.managerCandidates ?? []).find((m: J) => m.practice);
    if (cand && once("propose-manager")) {
      c.done.add(`managerRound:${round}`);
      await tx(`propose: make ${cand.name} the fund manager`, "propose", [
        2,
        encodeAbiParameters([{ type: "address" }], [cand.address]),
      ]);
      return true;
    }
  }
  if (
    isCreator &&
    v.manager &&
    L.canAskManagerPlan &&
    c.plansAsked < c.plan.plans &&
    once(`plan:${round}`)
  ) {
    const r = await serverAction(
      tag,
      "practice-plan",
      u,
      `/circles/${a}/practice-plan`,
    );
    if (r.status === 200) c.plansAsked++;
    return true;
  }
  const [rr, rule] = isCreator
    ? [c.plan.ruleRound, c.plan.rule]
    : [c.plan.secondRuleRound, c.plan.secondRule];
  if (round >= rr && y.canPropose && once("propose-rule")) {
    await tx(`propose: rule ${rule[0]} to ${rule[1]} bps`, "propose", [
      0,
      encodeAbiParameters(
        [{ type: "uint8" }, { type: "uint256" }],
        [rule[0], rule[1]],
      ),
    ]);
    return true;
  }
  return false;
};

// After a server restart the display-name file is empty: give each user the same name again (no second grant).
const reOnboard = async (list: (User | null)[]) => {
  serverBlip = false;
  for (const u of list) {
    if (!u) continue;
    const m = await api(u, "GET", "/me");
    if (m.status === 200 && m.json.name == null) {
      const o = await api(u, "POST", "/onboard", { name: u.name });
      log(
        "setup",
        `${u.name}: name set again after a server restart (${o.status})`,
      );
    }
  }
};

const follow = async (c: Circle, deadline: number) => {
  const tag = c.plan.name;
  let lastStatus = "";
  while (Date.now() < deadline && !c.finished) {
    let acted = false;
    for (const u of [c.creator, c.second].filter(Boolean) as User[]) {
      const r = await api(u, "GET", `/circles/${c.address}`);
      if (r.status !== 200) {
        log(tag, `view failed (${r.status}): ${r.json?.error}`);
        continue;
      }
      const v = r.json;
      if (serverBlip) await reOnboard([c.creator, c.second]);
      if (
        u === c.creator &&
        (v.status === "Cancelled" ||
          (v.status === "Forming" &&
            v.live?.startsAt &&
            v.live.now > v.live.startsAt + 3 * ROUND))
      ) {
        log(
          tag,
          `did not start (${v.status}, ${v.live?.memberCount}/5 members); giving up on this circle`,
        );
        failures.push({
          circle: tag,
          action: "start",
          reason: `${v.status}: too few members at the start time`,
        });
        c.finished = true;
        break;
      }
      const s = `${v.status} round ${v.round}/${v.totalRounds}`;
      if (u === c.creator && s !== lastStatus) {
        lastStatus = s;
        log(
          tag,
          `${s}; pot ${usd(v.pot?.total ?? 0)}; manager ${v.manager?.name ?? "none"}`,
        );
      }
      try {
        if (await step(c, u, v)) acted = true;
      } catch (e) {
        log(tag, `${u.name}: step error: ${reason(e)}`);
      }
      if (
        v.status === "Completed" &&
        u === c.creator &&
        c.done.has(`${u.name}:withdraw`)
      ) {
        const secondDone = !c.second || c.done.has(`${c.second.name}:withdraw`);
        if (secondDone) c.finished = true;
      }
    }
    if (!acted) await sleep(serverTrouble ? 20_000 : 10_000);
  }
};

const OUT = join(
  import.meta.dirname,
  "..",
  "deployments",
  "fuji-exercise.json",
);
// A rerun keeps the earlier run's summary in the same file.
const earlier: J =
  RERUN && existsSync(OUT) ? JSON.parse(readFileSync(OUT, "utf8")) : null;
const writeSummary = (circles: Circle[], users: User[]) => {
  const count = (list: Tx[]) => {
    const m: Record<string, number> = {};
    for (const x of list) m[x.action] = (m[x.action] ?? 0) + 1;
    return m;
  };
  const summary = {
    what: "Sample circles run by scripts/fuji-exercise.ts on Avalanche Fuji through the live Kuber server and the real contracts. Users are throwaway wallets made by the script; practice members and the keeper are the server's.",
    startedAt,
    finishedAt: new Date().toISOString(),
    server: API,
    rpc: RPC,
    chainId: 43113,
    users: users.map((u) => ({ name: u.name, address: u.account.address })),
    circles: circles.map((c) => {
      const list = txs.filter((x) => x.circle === c.plan.name);
      return {
        name: c.plan.name,
        address: c.address,
        snowtrace: c.address ? `${EXPLORER}/address/${c.address}` : null,
        creator: c.creator.name,
        secondUser: c.second?.name ?? null,
        finished: c.finished,
        txCount: list.length,
        txByAction: count(list),
        serverActions: serverCalls.filter((s) => s.circle === c.plan.name),
        txs: list,
      };
    }),
    setupTxs: txs.filter((x) => !circles.some((c) => c.plan.name === x.circle)),
    totals: {
      txs: txs.length,
      txsOk: txs.filter((x) => x.ok).length,
      byAction: count(txs),
      serverActions: serverCalls.length,
      refused: failures.length,
    },
    refused: failures,
  };
  let out: J = summary;
  if (earlier) {
    const byAction: Record<string, number> = { ...earlier.totals.byAction };
    for (const [k, n] of Object.entries(summary.totals.byAction))
      byAction[k] = (byAction[k] ?? 0) + n;
    out = {
      ...summary,
      allRunsTotals: {
        txs: earlier.totals.txs + summary.totals.txs,
        txsOk: earlier.totals.txsOk + summary.totals.txsOk,
        byAction,
        serverActions:
          earlier.totals.serverActions + summary.totals.serverActions,
      },
      earlierRun: earlier,
    };
  }
  writeFileSync(OUT, `${JSON.stringify(out, null, 2)}\n`);
  return summary;
};

// --- main
const health = (await api(null, "GET", "/health")).json;
if (!health?.ok || health.chainId !== 43113) {
  console.error("live server not ready", health);
  process.exit(1);
}
log("setup", `server ok, chain ${health.chainId}, factory ${health.factory}`);
const NAMES = RERUN
  ? ["Nisha P", "Ravi M", "Meera S", "Arjun D"]
  : ["Asha K", "Ravi M", "Meera S", "Kabir T"];
if (RERUN) PLANS[0].name = "Corner shop circle";
const users: User[] = [];
for (const [i, n] of NAMES.entries()) {
  if (serverTrouble) break;
  if (RERUN && (i === 1 || i === 2)) continue;
  const u = await signIn(n);
  if (u) users.push(u);
}
const creators = RERUN ? users.slice(0, 1) : users.slice(0, 3);
const circles: Circle[] = creators.map((u, i) => ({
  plan: PLANS[i],
  address: null,
  creator: u,
  second: i === 0 ? ((RERUN ? users[1] : users[3]) ?? null) : null,
  done: new Set(),
  loansAsked: 0,
  claimRound: 99,
  backTried: new Set(),
  backHow: new Map(),
  plansAsked: 0,
  finished: false,
}));
await Promise.all(circles.map((c) => setupCircle(c, health)));
const live = circles.filter((c) => c.address);
const deadline = Date.now() + 22 * 60_000;
const timer = setInterval(() => writeSummary(circles, users), 60_000);
await Promise.all(live.map((c) => follow(c, deadline)));
clearInterval(timer);
const s = writeSummary(circles, users);

console.log("\n===== Summary =====");
for (const c of s.circles) {
  console.log(`\n${c.name}: ${c.snowtrace ?? "(not created)"}`);
  console.log(
    `  creator ${c.creator}${c.secondUser ? `, second user ${c.secondUser}` : ""}; finished ${c.finished}`,
  );
  for (const [k, n] of Object.entries(c.txByAction))
    console.log(`  ${n} × ${k}`);
  for (const x of c.txs)
    console.log(`  ${x.ok ? "ok " : "rev"} ${x.action} (${x.from}) ${x.hash}`);
}
console.log(
  `\nTotals: ${s.totals.txs} txs from sample users (${s.totals.txsOk} ok), ${s.totals.serverActions} server actions, ${s.totals.refused} refused`,
);
for (const [k, n] of Object.entries(s.totals.byAction))
  console.log(`  ${n} × ${k}`);
console.log("Written to deployments/fuji-exercise.json");
process.exit(0);
