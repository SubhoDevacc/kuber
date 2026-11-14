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
  http,
  parseEventLogs,
} from "viem";
import { generatePrivateKey, privateKeyToAccount } from "viem/accounts";
import { afterAll, beforeAll, expect, test } from "vitest";
import { createFujiApp, DEFAULTS, parseFujiEnv } from "../src/fuji.ts";

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
  const bob = privateKeyToAccount(generatePrivateKey());
  const bm = `Kuber sign-in\nAddress: ${bob.address}\nTime: ${new Date().toISOString()}`;
  const bobToken = (
    await call(app, null, "POST", "/session", {
      address: bob.address,
      message: bm,
      signature: await bob.signMessage({ message: bm }),
    })
  ).json.token;
  await call(app, bobToken, "POST", "/onboard", { name: "Bobby" });
  expect(
    (
      await api(
        "GET",
        "/lookup?name=bobby",
        undefined,
        "GET /lookup?name=bobby",
      )
    ).json.address,
  ).toBe(bob.address);
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
    (await api("GET", "/people?q=bo", undefined, "GET /people?q=bo")).json,
  ).toEqual([{ address: bob.address, name: "Bobby" }]);
  expect(
    (
      await api(
        "GET",
        `/names?addrs=${account.address},${bob.address}`,
        undefined,
        "GET /names",
      )
    ).json[1].name,
  ).toBe("Bobby");

  // --- create a circle inviting the practice members (and Bobby), then add the 4 practice members
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
    [...invites, bob.address],
  ]);
  const [ev] = parseEventLogs({
    abi: kuberFactoryAbi,
    logs: created.logs,
    eventName: "CircleCreated",
  });
  const circle = ev.args.circle as Address;
  const start = fixed.startTime;
  const bobList = (await call(app, bobToken, "GET", "/circles")).json as J[];
  expect(bobList.find((r) => r.address === circle)).toMatchObject({
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
  expect(
    pm.json.members.filter((m: J) => m.name.startsWith("Practice member")),
  ).toHaveLength(4);
  expect(pm.json.live.invites).toHaveLength(5);
  expect(
    (
      await call(app, bobToken, "POST", `/circles/${circle}/practice-members`, {
        count: 1,
      })
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

  // --- propose: practice members vote yes (keeper), applied when the round closes
  await send(circle, kuberCircleAbi, "propose", [0, made.encodeRule(7, 200)]);
  await until(
    "practice members voted",
    async () => (await view()).live.proposals[0]?.yes === 4,
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
  expect((await view()).proposals[0].status).toBe("Done");

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
      /^Practice member \d backed your loan with 20.00$/.test(w),
    ),
  ).toBe(true);
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
