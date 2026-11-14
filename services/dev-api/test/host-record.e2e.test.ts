// Tutorial step records end to end: host.ts with the real-app side on, where a local Anvil stands in for Fuji
// (never real Fuji). Every tutorial step must produce one KuberPracticeLog.record transaction on that chain.
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
import {
  kuberCircleAbi,
  kuberPracticeLogAbi,
  mockUsdcAbi,
} from "@kuber/shared";
import {
  type Abi,
  type Address,
  createPublicClient,
  createWalletClient,
  defineChain,
  type Hex,
  http,
  parseEventLogs,
  zeroHash,
} from "viem";
import { generatePrivateKey, privateKeyToAccount } from "viem/accounts";
import { afterAll, beforeAll, expect, test } from "vitest";
import { createFujiApp, parseFujiEnv } from "../src/fuji.ts";

const root = join(import.meta.dirname, "..", "..", "..");
const PATH = `${process.env.HOME}/.foundry/bin:${process.env.PATH}`;
const ANVIL0 =
  "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";
const freePort = () =>
  new Promise<number>((resolve) => {
    const s = createServer().listen(0, "127.0.0.1", () => {
      const { port } = s.address() as { port: number };
      s.close(() => resolve(port));
    });
  });
const local = defineChain({
  id: 31337,
  name: "anvil",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: ["/rpc"] } },
});

let fuji: ChildProcess;
let fujiRpc: string;
let host: ChildProcess;
let base: string;
let usdc: Address;
let log: Address;
let dir: string;
let deployment: string;
const fujiPub = () =>
  createPublicClient({
    chain: local,
    transport: http(fujiRpc),
    pollingInterval: 50,
  });

beforeAll(async () => {
  // The Fuji stand-in: kuber deployed (the real app needs it) plus the practice log, owned by the admin key.
  const port = await freePort();
  fujiRpc = `http://127.0.0.1:${port}`;
  fuji = spawn(
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
    const ok = await fetch(fujiRpc, {
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
  dir = mkdtempSync(join(tmpdir(), "kuber-record-e2e-"));
  deployment = join(dir, "fuji.json");
  try {
    const r = spawnSync(
      process.execPath,
      ["scripts/deploy.ts", "--network", "local", "--rpc", fujiRpc],
      { cwd: root, env: { ...process.env, PATH }, encoding: "utf8" },
    );
    if (r.status !== 0) throw new Error(`deploy failed: ${r.stderr}`);
    copyFileSync(shared, deployment);
  } finally {
    writeFileSync(shared, saved);
  }
  const art = JSON.parse(
    readFileSync(
      join(root, "contracts/out/KuberPracticeLog.sol/KuberPracticeLog.json"),
      "utf8",
    ),
  ) as { bytecode: { object: Hex } };
  const admin = privateKeyToAccount(ANVIL0);
  const wallet = createWalletClient({
    account: admin,
    chain: local,
    transport: http(fujiRpc),
  });
  const hash = await wallet.deployContract({
    abi: kuberPracticeLogAbi,
    bytecode: art.bytecode.object,
    args: [admin.address],
  });
  log = (await fujiPub().waitForTransactionReceipt({ hash }))
    .contractAddress as Address;

  const hostPort = await freePort();
  base = `http://127.0.0.1:${hostPort}`;
  const dist = mkdtempSync(join(tmpdir(), "kuber-record-dist-"));
  writeFileSync(join(dist, "index.html"), "<!doctype html><title>t</title>");
  host = spawn(process.execPath, ["services/dev-api/src/host.ts"], {
    cwd: root,
    detached: true,
    stdio: ["ignore", "ignore", "inherit"],
    env: {
      ...process.env,
      HOST: "127.0.0.1",
      PORT: String(hostPort),
      WEB_DIST: dist,
      FUJI_ADMIN_PRIVATE_KEY: ANVIL0,
      FUJI_RPC_URL: fujiRpc,
      FUJI_DEPLOYMENT_PATH: deployment,
      PRACTICE_LOG_ADDRESS: log,
      SESSION_SECRET: "test-secret-test-secret-test-secret",
      KEEPER_INTERVAL_MS: "0",
      VAULT_SPEEDUP: "0",
      LP_MOVE_EVERY_MS: "0",
      LOG_MIN_GAP_MS: "0",
      POLL_MS: "50",
      NAMES_PATH: join(dir, "names.json"),
    },
  });
  for (let i = 0; i < 1200; i++) {
    await new Promise((r) => setTimeout(r, 100));
    if (!usdc) {
      const res = await fetch(`${base}/api/health`).catch(() => null);
      if (res?.ok) usdc = ((await res.json()) as { usdc: Address }).usdc;
    }
    if (usdc && (await fetch(`${base}/api/app/health`).catch(() => null))?.ok)
      break;
  }
  if (!usdc) throw new Error("host did not come up");
  expect((await fetch(`${base}/api/app/health`)).status).toBe(200);
}, 240_000);

afterAll(() => {
  if (host?.pid) process.kill(-host.pid, "SIGTERM");
  fuji?.kill();
});

// biome-ignore lint/suspicious/noExplicitAny: test reads loose JSON
type J = any;
const auth = (who: Address) => ({ authorization: `Bearer dev:${who}` });
const api = async (
  who: Address,
  method: string,
  path: string,
  body?: unknown,
) => {
  const res = await fetch(`${base}/api${path}`, {
    method,
    headers: { ...auth(who), "content-type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  return { status: res.status, json: (await res.json()) as J };
};

test("the internal record route is not reachable from the public port or without the token", async () => {
  const body = JSON.stringify({
    user: log,
    practiceCircle: log,
    step: "x",
    actions: [{ label: "x", practiceTx: zeroHash }],
  });
  const headers = {
    "content-type": "application/json",
    "x-internal-token": "a".repeat(64),
  };
  for (const path of [
    "/internal/practice-log",
    "/api/app/%2e%2e/%2e%2e/internal/practice-log",
  ]) {
    const r = await fetch(`${base}${path}`, { method: "POST", headers, body });
    expect(r.status, path).toBe(404);
  }
  // Under /api/app it is just an unknown app route behind sign-in.
  const app = await fetch(`${base}/api/app/internal/practice-log`, {
    method: "POST",
    headers,
    body,
  });
  expect(app.status).toBe(401);

  // The Fuji server itself: no token or a wrong one is refused before anything is sent.
  const made = await createFujiApp(
    parseFujiEnv({
      FUJI_RPC_URL: fujiRpc,
      FUJI_ADMIN_PRIVATE_KEY: ANVIL0,
      FUJI_DEPLOYMENT_PATH: deployment,
      SESSION_SECRET: "test-secret-test-secret-test-secret",
      KEEPER_INTERVAL_MS: "0",
      VAULT_SPEEDUP: "0",
      LP_MOVE_EVERY_MS: "0",
      INTERNAL_TOKEN: "b".repeat(64),
      NAMES_PATH: join(dir, "names2.json"),
    }),
  );
  try {
    const url = "http://x/internal/practice-log";
    const noToken = await made.internal.fetch(
      new Request(url, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body,
      }),
    );
    expect(noToken.status).toBe(401);
    const wrong = await made.internal.fetch(
      new Request(url, { method: "POST", headers, body }),
    );
    expect(wrong.status).toBe(401);
  } finally {
    made.stop();
  }
}, 60_000);

test("hosted: every tutorial step is recorded by one transaction on the Fuji stand-in", async () => {
  const account = privateKeyToAccount(generatePrivateKey());
  const me = account.address;
  const transport = http(`${base}/rpc`, {
    fetchOptions: { headers: auth(me) },
  });
  const pub = createPublicClient({
    chain: local,
    transport,
    pollingInterval: 50,
  });
  const wallet = createWalletClient({ account, chain: local, transport });

  expect((await api(me, "POST", "/onboard", { name: "Rhea" })).status).toBe(
    200,
  );
  let s = (await api(me, "POST", "/tutorial/start")).json;
  const steps: {
    title: string;
    own: Hex | null;
    txs: { label: string; hash: Hex }[];
    record: J;
  }[] = [];
  while (!s.done) {
    const a = s.step.action;
    let own: Hex | null = null;
    if (a) {
      own = await wallet.writeContract({
        address: a.target === "usdc" ? usdc : s.circle,
        abi: (a.target === "usdc" ? mockUsdcAbi : kuberCircleAbi) as Abi,
        functionName: a.functionName,
        args: a.args.map((x: unknown) =>
          typeof x === "string" && /^\d+$/.test(x) ? BigInt(x) : x,
        ),
      });
      expect((await pub.waitForTransactionReceipt({ hash: own })).status).toBe(
        "success",
      );
    }
    const title = s.step.title;
    const r = await api(me, "POST", "/tutorial/next", { stepId: s.step.id });
    expect(r.status, `${s.step.id}: ${JSON.stringify(r.json)}`).toBe(200);
    s = r.json;
    const rec = s.lastChange.record;
    expect(rec, title).toMatchObject({ chain: "Avalanche Fuji" });
    expect(rec.hash).toMatch(/^0x[0-9a-f]{64}$/);
    expect(rec.url).toBe(`https://testnet.snowtrace.io/tx/${rec.hash}`);
    steps.push({ title, own, txs: s.lastChange.txs ?? [], record: rec });
  }
  expect(s.snapshot.status).toBe("Completed");

  // One successful record transaction per step, to the log, with the step's labels in order.
  const fp = fujiPub();
  expect(new Set(steps.map((x) => x.record.hash)).size).toBe(steps.length);
  for (const step of steps) {
    const receipt = await fp.waitForTransactionReceipt({
      hash: step.record.hash,
    });
    expect(receipt.status, step.title).toBe("success");
    expect(receipt.to?.toLowerCase()).toBe(log.toLowerCase());
    const events = parseEventLogs({
      abi: kuberPracticeLogAbi,
      logs: receipt.logs,
      eventName: "PracticeAction",
    }) as unknown as {
      args: {
        user: Address;
        practiceCircle: Address;
        step: string;
        action: string;
        practiceTx: Hex;
      };
    }[];
    const want = [
      ...(step.own ? [{ label: step.title, hash: step.own }] : []),
      ...step.txs,
    ].slice(0, 20);
    if (want.length === 0) want.push({ label: step.title, hash: zeroHash });
    expect(
      events.map((e) => [e.args.action, e.args.practiceTx]),
      step.title,
    ).toEqual(want.map((w) => [w.label, w.hash]));
    for (const e of events) {
      expect(e.args.user).toBe(me);
      expect(e.args.step).toBe(step.title);
    }
  }

  // The tutorial activity route carries the record of the step each transaction belongs to.
  const byTx = new Map<string, string>();
  for (const step of steps)
    for (const h of [step.own, ...step.txs.map((x) => x.hash)])
      if (h) byTx.set(h.toLowerCase(), step.record.hash);
  const activity = (await api(me, "GET", "/activity")).json as J[];
  expect(activity.length).toBeGreaterThan(0);
  for (const row of activity) {
    const want = byTx.get(row.txHash.toLowerCase());
    if (want) expect(row.record?.hash).toBe(want);
  }
  expect(activity.some((row) => row.record)).toBe(true);
}, 300_000);
