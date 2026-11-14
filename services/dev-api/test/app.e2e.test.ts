// Real-app server (fuji.ts) end to end against a local Anvil standing in for Fuji: same code path, chain id from the
// RPC, real time moved forward by the test, rounds closed only by the server's keeper loop. Never touches Fuji.
import { type ChildProcess, spawn, spawnSync } from "node:child_process";
import {
  copyFileSync,
  mkdtempSync,
  readFileSync,
  writeFileSync,
} from "node:fs";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { kuberCircleAbi, kuberFactoryAbi, mockUsdcAbi } from "@kuber/shared";
import {
  type Address,
  createPublicClient,
  createTestClient,
  createWalletClient,
  defineChain,
  encodeAbiParameters,
  http,
  parseEventLogs,
} from "viem";
import { generatePrivateKey, privateKeyToAccount } from "viem/accounts";
import { afterAll, beforeAll, expect, test } from "vitest";
import {
  createFujiApp,
  DEFAULTS,
  encodeAlloc,
  PRACTICE_NAMES,
  parseFujiEnv,
} from "../src/fuji.ts";

const root = join(import.meta.dirname, "..", "..", "..");
const PATH = `${process.env.HOME}/.foundry/bin:${process.env.PATH}`;
const ANVIL0 =
  "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";
const USDC = 1_000_000n;
const freePort = () =>
  new Promise<number>((resolve) => {
    const s = createServer().listen(0, "127.0.0.1", () => {
      const { port } = s.address() as { port: number };
      s.close(() => resolve(port));
    });
  });

let anvil: ChildProcess;
let rpc: string;
let deployment: string;
let dir: string;
let made: Awaited<ReturnType<typeof createFujiApp>>;
const examples: Record<string, unknown> = {};
const env = (extra: Record<string, string> = {}) =>
  parseFujiEnv({
    FUJI_RPC_URL: rpc,
    FUJI_ADMIN_PRIVATE_KEY: ANVIL0,
    FUJI_DEPLOYMENT_PATH: deployment,
    SESSION_SECRET: "test-secret-test-secret-test-secret",
    KEEPER_INTERVAL_MS: "200",
    LOG_MIN_GAP_MS: "0",
    POLL_MS: "50",
    NAMES_PATH: join(dir, "names.json"),
    ...extra,
  });

beforeAll(async () => {
  const port = await freePort();
  rpc = `http://127.0.0.1:${port}`;
  anvil = spawn(
    "anvil",
    [
      "--host",
      "127.0.0.1",
      "--port",
      String(port),
      "--chain-id",
      "31337",
      "--quiet",
    ],
    { stdio: "ignore", env: { ...process.env, PATH } },
  );
  for (let i = 0; i < 100; i++) {
    await new Promise((r) => setTimeout(r, 100));
    const ok = await fetch(rpc, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}',
    }).then(
      () => true,
      () => false,
    );
    if (ok) break;
  }
  const shared = join(root, "deployments", "local.json");
  const saved = readFileSync(shared, "utf8");
  dir = mkdtempSync(join(tmpdir(), "kuber-app-e2e-"));
  deployment = join(dir, "local.json");
  try {
    const r = spawnSync(
      process.execPath,
      ["scripts/deploy.ts", "--network", "local", "--rpc", rpc],
      { cwd: root, env: { ...process.env, PATH }, encoding: "utf8" },
    );
    if (r.status !== 0) throw new Error(`deploy failed: ${r.stderr}`);
    copyFileSync(shared, deployment);
  } finally {
    writeFileSync(shared, saved);
  }
  made = await createFujiApp(env());
}, 120_000);

afterAll(() => {
  made?.stop();
  anvil?.kill();
  if (process.env.APP_EXAMPLES)
    writeFileSync(process.env.APP_EXAMPLES, JSON.stringify(examples, null, 2));
});

// biome-ignore lint/suspicious/noExplicitAny: test reads loose JSON
type J = any;
const call = async (
  app: typeof made.app,
  token: string | null,
  method: string,
  path: string,
  body?: unknown,
  label?: string,
) => {
  const res = await app.request(`/api/app${path}`, {
    method,
    headers: {
      ...(token ? { authorization: `Bearer ${token}` } : {}),
      "content-type": "application/json",
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const json = (await res.json()) as J;
  if (label) examples[label] = { status: res.status, body: json };
  return { status: res.status, json };
};
const until = async (what: string, ok: () => Promise<boolean>, ms = 30_000) => {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    if (await ok().catch(() => false)) return;
    await new Promise((r) => setTimeout(r, 200));
  }
  throw new Error(`timed out waiting for: ${what}`);
};

test("real app on an Anvil standing in for Fuji: sign-in, grant once, a full circle with practice members", async () => {
  const chain = defineChain({
    id: 31337,
    name: "anvil",
    nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
    rpcUrls: { default: { http: [rpc] } },
  });
  const pub = createPublicClient({
    chain,
    transport: http(rpc),
    pollingInterval: 50,
  });
  const testClient = createTestClient({
    chain,
    transport: http(rpc),
    mode: "anvil",
  });
  const app = made.app;
  const health = (
    await call(app, null, "GET", "/health", undefined, "GET /health")
  ).json;
  const { usdc, factory } = health as { usdc: Address; factory: Address };
  const account = privateKeyToAccount(generatePrivateKey());
  const wallet = createWalletClient({ account, chain, transport: http(rpc) });
  const send = async (
    to: Address,
    abi: unknown,
    functionName: string,
    args: unknown[] = [],
  ) => {
    const hash = await wallet.writeContract({
      address: to,
      abi,
      functionName,
      args,
    } as never);
    const r = await pub.waitForTransactionReceipt({ hash });
    expect(r.status).toBe("success");
    return r;
  };
  const balance = () =>
    pub.readContract({
      address: usdc,
      abi: mockUsdcAbi,
      functionName: "balanceOf",
      args: [account.address],
    });

  // --- sign-in by signature
  const message = `Kuber sign-in\nAddress: ${account.address}\nTime: ${new Date().toISOString()}`;
  const signature = await account.signMessage({ message });
  const bad = await call(
    app,
    null,
    "POST",
    "/session",
    {
      address: account.address,
      message,
      signature: await privateKeyToAccount(generatePrivateKey()).signMessage({
        message,
      }),
    },
    "POST /session (wrong signer)",
  );
  expect(bad.status).toBe(401);
  const old = `Kuber sign-in\nAddress: ${account.address}\nTime: ${new Date(Date.now() - 600_000).toISOString()}`;
  expect(
    (
      await call(app, null, "POST", "/session", {
        address: account.address,
        message: old,
        signature: await account.signMessage({ message: old }),
      })
    ).status,
  ).toBe(401);
  const s = await call(
    app,
    null,
    "POST",
    "/session",
    { address: account.address, message, signature },
    "POST /session",
  );
  expect(s.status).toBe(200);
  const token = s.json.token as string;
  expect(
    (await call(app, null, "GET", "/me", undefined, "GET /me (no token)"))
      .status,
  ).toBe(401);
  const api = (method: string, path: string, body?: unknown, label?: string) =>
    call(app, token, method, path, body, label);

  expect(
    (await api("GET", "/me", undefined, "GET /me (new user)")).json.verified,
  ).toBe(false);
  expect(
    (await api("POST", "/onboard", { name: "Ma" }, "POST /onboard (bad name)"))
      .status,
  ).toBe(400);

  // --- onboard grants once; twice gives nothing more; a restarted server (fresh names file) gives nothing more
  const first = await api(
    "POST",
    "/onboard",
    { name: "Maya" },
    "POST /onboard",
  );
  expect(first.status).toBe(200);
  expect(first.json).toMatchObject({
    name: "Maya",
    verified: true,
    musdc: "20000000000",
    granted: true,
  });
  expect(BigInt(first.json.avax)).toBe(50_000_000_000_000_000n);
  const again = await api("POST", "/onboard", { name: "Maya" });
  expect(again.json.musdc).toBe("20000000000");
  const restarted = await createFujiApp(
    env({ KEEPER_INTERVAL_MS: "0", NAMES_PATH: join(dir, "names2.json") }),
  );
  const s2 = await call(restarted.app, null, "POST", "/session", {
    address: account.address,
    message,
    signature,
  });
  const r2 = await call(restarted.app, s2.json.token, "POST", "/onboard", {
    name: "Maya",
  });
  expect(r2.status).toBe(200);
  expect(r2.json.musdc).toBe("20000000000");
  restarted.stop();

  // --- faucet once an hour
  expect(
    (await api("POST", "/faucet", undefined, "POST /faucet")).json.musdc,
  ).toBe("30000000000");
  expect(
    (await api("POST", "/faucet", undefined, "POST /faucet (again)")).status,
  ).toBe(429);

  // --- a second real user for names / lookup / people
  const kabir = privateKeyToAccount(generatePrivateKey());
  const bm = `Kuber sign-in\nAddress: ${kabir.address}\nTime: ${new Date().toISOString()}`;
  const kabirToken = (
    await call(app, null, "POST", "/session", {
      address: kabir.address,
      message: bm,
      signature: await kabir.signMessage({ message: bm }),
    })
  ).json.token;
  await call(app, kabirToken, "POST", "/onboard", { name: "Kabir" });
  expect(
    (
      await api(
        "GET",
        "/lookup?name=kabir",
        undefined,
        "GET /lookup?name=kabir",
      )
    ).json.address,
  ).toBe(kabir.address);
  expect(
    (
      await api(
        "GET",
        "/lookup?name=Nobody",
        undefined,
        "GET /lookup?name=Nobody",
      )
    ).status,
  ).toBe(404);
  expect(
    (await api("GET", "/people?q=ka", undefined, "GET /people?q=ka")).json,
  ).toEqual([{ address: kabir.address, name: "Kabir" }]);
  expect(
    (
      await api(
        "GET",
        `/names?addrs=${account.address},${kabir.address}`,
        undefined,
        "GET /names",
      )
    ).json[1].name,
  ).toBe("Kabir");

  // --- create a circle inviting the practice members (and Kabir), then add the 4 practice members
  const { invites } = (
    await api("GET", "/practice-invites", undefined, "GET /practice-invites")
  ).json as { invites: Address[] };
  expect(invites).toHaveLength(4);
  const t0 = (await pub.getBlock()).timestamp;
  const dur = 120n;
  const fixed = {
    contribution: 100n * USDC,
    epochDuration: Number(dur),
    lockBps: DEFAULTS.fixed.lockBps,
    startTime: t0 + 60n,
    minSaveEpochs: 3,
    totalEpochs: 6,
    minMembers: 5,
    maxMembers: 10,
    maxRepayEpochs: 3,
    cooldownEpochs: 1,
  };
  const created = await send(factory, kuberFactoryAbi, "createCircle", [
    "Demo circle",
    fixed,
    DEFAULTS.rules,
    [...invites, kabir.address],
  ]);
  const [ev] = parseEventLogs({
    abi: kuberFactoryAbi,
    logs: created.logs,
    eventName: "CircleCreated",
  });
  const circle = ev.args.circle as Address;
  const start = fixed.startTime;
  const kabirList = (await call(app, kabirToken, "GET", "/circles"))
    .json as J[];
  expect(kabirList.find((r) => r.address === circle)).toMatchObject({
    invited: true,
    canJoin: true,
    mine: false,
  });

  const pm = await api(
    "POST",
    `/circles/${circle}/practice-members`,
    { count: 4 },
    "POST /circles/:address/practice-members",
  );
  expect(pm.status).toBe(200);
  expect(pm.json.members).toHaveLength(5);
  expect(pm.json.live.practiceMembers).toBe(4);
  // Round 3, item 6: practice members have plain Indian first names and stay tagged as practice members.
  expect(
    pm.json.members
      .filter((m: J) => m.practice)
      .map((m: J) => m.name)
      .sort(),
  ).toEqual([...PRACTICE_NAMES].sort());
  expect(pm.json.live.invites.filter((i: J) => i.practice)).toHaveLength(4);
  expect(pm.json.manager).toBeNull();
  expect(pm.json.live.invites).toHaveLength(5);
  expect(
    (
      await call(
        app,
        kabirToken,
        "POST",
        `/circles/${circle}/practice-members`,
        {
          count: 1,
        },
      )
    ).status,
  ).toBe(403);
  examples["GET /circles"] = {
    status: 200,
    body: (await api("GET", "/circles")).json,
  };
  examples["GET /circles/:address (Forming, creator)"] = {
    status: 200,
    body: (await api("GET", `/circles/${circle}`)).json,
  };

  await send(usdc, mockUsdcAbi, "approve", [circle, 5_000n * USDC]);
  const view = async () => (await api("GET", `/circles/${circle}`)).json as J;
  const warp = async (t: bigint) => {
    const now = (await pub.getBlock()).timestamp;
    if (t > now) await testClient.increaseTime({ seconds: Number(t - now) });
    await testClient.mine({ blocks: 1 });
  };

  // --- the keeper starts it and closes rounds
  await warp(start + 1n);
  await until("activated", async () => (await view()).status === "Active");
  await warp(start + dur + 1n);
  await until(
    "round 1 closed",
    async () => (await view()).you.savings === "100000000",
  );
  await warp(start + 2n * dur + 1n);
  await until(
    "round 2 closed",
    async () => (await view()).you.savings === "200000000",
  );
  // --- item 4: the test vaults' demo controls (real admin transactions at start-up) make a round earn
  await made.vaultsReady;
  const vaultAbi = [
    {
      type: "function",
      name: "speedup",
      inputs: [],
      outputs: [{ type: "uint32" }],
      stateMutability: "view",
    },
  ] as const;
  expect(
    await pub.readContract({
      address: made.vaults.aave,
      abi: vaultAbi,
      functionName: "speedup",
    }),
  ).toBe(21_600);
  const r2v = await view();
  expect(BigInt(r2v.pot.earned)).toBeGreaterThan(0n);
  expect(BigInt(r2v.live.investments.aave.value)).toBeGreaterThan(0n);
  expect(r2v.live.investments.aave.apyBps).toBe(500);
  expect(r2v.live.investments.note).toContain("a month");
  // The LP pool's price moves (first move is up), from the keeper's loop; forced here instead of waiting 60 s.
  expect(await made.moveLp(true)).toBe(30);
  expect(
    BigInt((await view()).live.investments.lp.changeThisRound),
  ).toBeGreaterThan(0n);
  examples["GET /circles/:address (round 2 closed: investments)"] = {
    status: 200,
    body: { pot: r2v.pot, investments: (await view()).live.investments },
  };
  await send(circle, kuberCircleAbi, "payNow");
  const r3 = await view();
  expect(r3.you.savings).toBe("300000000");
  expect(r3.live.you.canBorrow).toBe(true);
  expect(r3.live.you.ownLimit).toBe("270000000");
  expect(BigInt(r3.live.you.loanLimit)).toBeGreaterThanOrEqual(290n * USDC);

  // --- borrow 290: 270 against own savings, 20 backed by a practice member
  await send(circle, kuberCircleAbi, "requestLoan", [
    290n * USDC,
    2n,
    800n,
    0n,
  ]);
  const asked = await view();
  expect(asked.live.requests[0]).toMatchObject({
    amount: "290000000",
    needsBacking: "20000000",
    mine: true,
    rateBps: 800,
    // item 5: the risk and the reward of backing what the request needs
    ifYouBack: {
      amount: "20000000",
      couldLose: "20000000",
      wouldEarn: "1600000",
    },
    ifYouAgree: {
      amount: "20000000",
      couldLose: "20000000",
      wouldEarn: "800000",
    },
  });
  const ifb = await api(
    "GET",
    `/circles/${circle}/requests/${asked.live.requests[0].id}/if-you-back?amount=20000000`,
    undefined,
    "GET /circles/:address/requests/:id/if-you-back",
  );
  expect(ifb.json).toEqual({
    how: "vouch",
    amount: "20000000",
    couldLose: "20000000",
    wouldEarn: "1600000",
    rateBps: 800,
  });
  examples["GET /circles/:address (Active, loan request waiting)"] = {
    status: 200,
    body: asked,
  };
  const backed = await api(
    "POST",
    `/circles/${circle}/practice-back`,
    { requestId: asked.live.requests[0].id },
    "POST /circles/:address/practice-back",
  );
  expect(backed.status).toBe(200);
  expect(backed.json.live.requests[0].needsBacking).toBe("0");
  // What the contract takes on hold from the practice backer is exactly couldLose.
  expect(backed.json.members.find((m: J) => m.pledged !== "0")?.pledged).toBe(
    asked.live.requests[0].ifYouBack.couldLose,
  );

  // --- item 1: vote a practice member in as fund manager (round 3; practice members vote yes via the keeper)
  const r3b = backed.json;
  expect(r3b.live.you.canProposeManager).toBe(true);
  const gita = r3b.live.managerCandidates.find((m: J) => m.name === "Gita");
  expect(gita.practice).toBe(true);
  await send(circle, kuberCircleAbi, "propose", [
    2,
    encodeAbiParameters([{ type: "address" }], [gita.address]),
  ]);
  const mp = await view();
  expect(mp.live.you.proposedThisRound).toBe(true);
  expect(mp.live.you.canPropose).toBe(false);
  expect(mp.live.you.proposeReason).toBe(
    "You already suggested a change this round. You can suggest another next round.",
  );
  expect(mp.live.proposals[0]).toMatchObject({
    kind: "manager",
    title: "Make Gita the fund manager",
  });
  await until(
    "practice members voted for the manager",
    async () => (await view()).live.proposals[0]?.yes === 4,
  );
  await warp(start + 3n * dur + 1n);
  await until(
    "loan funded",
    async () => (await view()).live.you.activeLoan?.status === "Being repaid",
  ).catch(async (e) => {
    const v = await view();
    console.log(
      JSON.stringify(
        {
          round: v.round,
          loans: v.loans,
          you: v.you,
          live: v.live.you,
          req: v.live.requests,
        },
        null,
        1,
      ),
    );
    throw e;
  });
  const before = await balance();
  await send(circle, kuberCircleAbi, "claim");
  expect((await balance()) - before).toBe(290n * USDC);

  // --- item 2: Gita is the fund manager (applied when round 3 closed)
  const r4 = await view();
  expect(r4.manager).toMatchObject({ address: gita.address, name: "Gita" });
  expect(r4.members.find((m: J) => m.isManager)?.name).toBe("Gita");
  expect(
    r4.members.filter((m: J) => m.isManager && m.name !== "Gita"),
  ).toHaveLength(0);
  expect(r4.live.you.isManager).toBe(false);
  // --- item 3: only the manager may propose a plan; the user asks Gita, who proposes the preset
  expect(r4.live.you.canProposePlan).toBe(false);
  expect(r4.live.planNote).toBe(
    "Only the fund manager, Gita, can suggest a new money plan. Everyone still votes on it.",
  );
  await expect(
    pub.simulateContract({
      account,
      address: circle,
      abi: kuberCircleAbi,
      functionName: "propose",
      args: [
        1,
        encodeAlloc({ loan: 4_000, aave: 2_000, lp: 3_000, cash: 1_000 }),
      ],
    }),
  ).rejects.toThrow(/OnlyManager/);
  expect(r4.live.canAskManagerPlan).toBe(true);
  expect(r4.live.askManagerPlanLabel).toBe(
    "Ask Gita to propose a new money plan",
  );
  expect(r4.live.managerPreset).toEqual({
    loan: 4_000,
    aave: 3_500,
    lp: 1_500,
    cash: 1_000,
  });
  expect(r4.live.plan.current).toEqual(DEFAULTS.rules.alloc);
  const asked2 = await api(
    "POST",
    `/circles/${circle}/practice-plan`,
    undefined,
    "POST /circles/:address/practice-plan",
  );
  expect(asked2.status).toBe(200);
  const planP = asked2.json.live.proposals.find((p: J) => p.kind === "plan");
  expect(planP).toMatchObject({
    title: "New money plan: ready to lend 40%, Aave 35%, LP pool 15%, cash 10%",
    open: true,
    plan: { loan: 4_000, aave: 3_500, lp: 1_500, cash: 1_000 },
  });
  expect(asked2.json.live.canAskManagerPlan).toBe(false);
  expect((await api("POST", `/circles/${circle}/practice-plan`)).status).toBe(
    409,
  );
  await send(circle, kuberCircleAbi, "vote", [BigInt(planP.id), true]);

  // --- propose: practice members vote yes (keeper), applied when the round closes
  await send(circle, kuberCircleAbi, "propose", [0, made.encodeRule(7, 200)]);
  const ruleId = () =>
    view().then((v) => v.live.proposals.find((p: J) => p.kind === "rule") as J);
  await until(
    "practice members voted",
    async () =>
      (await ruleId())?.yes === 4 &&
      (await view()).live.proposals.find((p: J) => p.id === planP.id)?.yes ===
        5,
  );
  await send(circle, kuberCircleAbi, "repayAll");
  const repaid = await view();
  expect(repaid.live.you.activeLoan).toBeNull();
  expect(repaid.loans[0].status).toBe("Repaid");
  examples["GET /circles/:address (Active, voting)"] = {
    status: 200,
    body: repaid,
  };
  await warp(start + 4n * dur + 1n);
  await until(
    "proposal applied",
    async () => (await view()).live.rules[7].current === 200,
  );
  const applied = await view();
  expect(
    applied.proposals
      .filter((p: J) => p.status === "Done")
      .map((p: J) => p.kind)
      .sort(),
  ).toEqual(["manager", "plan", "rule"]);
  // The money plan the practice manager proposed is the circle's plan now.
  expect(applied.live.plan.current).toEqual({
    loan: 4_000,
    aave: 3_500,
    lp: 1_500,
    cash: 1_000,
  });
  examples["GET /circles/:address (manager appointed, plan applied)"] = {
    status: 200,
    body: {
      manager: applied.manager,
      members: applied.members,
      proposals: applied.proposals,
      live: {
        you: applied.live.you,
        plan: applied.live.plan,
        planNote: applied.live.planNote,
        canAskManagerPlan: applied.live.canAskManagerPlan,
        askManagerPlanReason: applied.live.askManagerPlanReason,
        askManagerPlanLabel: applied.live.askManagerPlanLabel,
        managerPreset: applied.live.managerPreset,
        managerPresetNote: applied.live.managerPresetNote,
        managerCandidates: applied.live.managerCandidates,
        investments: applied.live.investments,
      },
    },
  };

  // --- to the end; collect the share-out
  await warp(start + 5n * dur + 1n);
  await until(
    "round 5 closed",
    async () => (await view()).you.savings === "500000000",
  );
  await warp(start + 6n * dur + 1n);
  await until("completed", async () => (await view()).status === "Completed");
  expect((await view()).live.you.canCollect).toBe(true);
  const b2 = await balance();
  await send(circle, kuberCircleAbi, "withdraw");
  const done = await view();
  expect(BigInt(done.you.paidOut)).toBeGreaterThanOrEqual(600n * USDC);
  // item 5 end to end: the practice backer was paid exactly the wouldEarn shown before backing.
  expect(done.loans[0].backers[0].earned).toBe(
    asked.live.requests[0].ifYouBack.wouldEarn,
  );
  // Gita managed rounds 4-6: the registry's record (item 7).
  expect(done.manager.roundsManaged).toBeGreaterThanOrEqual(1);
  expect((await balance()) - b2).toBe(BigInt(done.you.paidOut));
  examples["GET /circles/:address (Completed, collected)"] = {
    status: 200,
    body: done,
  };

  // --- activity
  const act = (
    await api(
      "GET",
      `/circles/${circle}/activity`,
      undefined,
      "GET /circles/:address/activity",
    )
  ).json as J[];
  const whats = act.map((e) => e.what);
  expect(whats).toContain("You saved 100.00");
  expect(whats).toContain("You asked to borrow 290.00");
  expect(whats).toContain("Round 1 closed");
  expect(
    whats.some((w: string) =>
      /^(Gita|Hari|Indu|Jay) backed your loan with 20.00$/.test(w),
    ),
  ).toBe(true);
  expect(whats).toContain("You proposed: make Gita the fund manager");
  expect(whats).toContain("Gita is now the fund manager");
  expect(whats).toContain(
    "Gita proposed: a new money plan (ready to lend 40%, Aave 35%, LP pool 15%, cash 10%)",
  );
  expect(act[0].block).toBeGreaterThanOrEqual(act[act.length - 1].block);
  for (const e of act) expect(e.txHash).toMatch(/^0x[0-9a-f]{64}$/);
  const mine = (await api("GET", "/activity", undefined, "GET /activity"))
    .json as J[];
  expect(mine.some((e) => e.what.startsWith("Welcome money"))).toBe(true);
  expect(
    mine.some(
      (e) => e.circle === "Demo circle" && e.what.startsWith("You collected"),
    ),
  ).toBe(true);
  const receipt = await pub.getTransactionReceipt({
    hash: mine.find((e) => e.what.startsWith("Welcome money")).txHash,
  });
  expect(receipt.status).toBe("success");
}, 240_000);
