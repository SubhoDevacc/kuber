// Hosted mode end to end: boots host.ts on a free port and plays two users interleaved (one step each in turn)
// through the whole tutorial, using only the public surface (/api/* and /rpc with the dev token).
import { type ChildProcess, spawn } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { kuberCircleAbi, mockUsdcAbi } from "@kuber/shared";
import {
  type Abi,
  type Address,
  createPublicClient,
  createWalletClient,
  defineChain,
  http,
} from "viem";
import { generatePrivateKey, privateKeyToAccount } from "viem/accounts";
import { afterAll, beforeAll, expect, test } from "vitest";

const root = join(import.meta.dirname, "..", "..", "..");
const freePort = () =>
  new Promise<number>((resolve) => {
    const s = createServer().listen(0, "127.0.0.1", () => {
      const { port } = s.address() as { port: number };
      s.close(() => resolve(port));
    });
  });

let host: ChildProcess;
let base: string;
let usdc: Address;
const INDEX = "<!doctype html><title>kuber test index</title>";

beforeAll(async () => {
  const port = await freePort();
  base = `http://127.0.0.1:${port}`;
  const dist = mkdtempSync(join(tmpdir(), "kuber-host-dist-"));
  writeFileSync(join(dist, "index.html"), INDEX);
  host = spawn(process.execPath, ["services/dev-api/src/host.ts"], {
    cwd: root,
    detached: true,
    stdio: ["ignore", "ignore", "inherit"],
    env: {
      ...process.env,
      // Never the real Fuji app in a test: without the key /api/app answers 503.
      FUJI_ADMIN_PRIVATE_KEY: "",
      HOST: "127.0.0.1",
      PORT: String(port),
      WEB_DIST: dist,
    },
  });
  for (let i = 0; i < 1200 && !usdc; i++) {
    await new Promise((r) => setTimeout(r, 100));
    const res = await fetch(`${base}/api/health`).catch(() => null);
    if (res?.ok) usdc = ((await res.json()) as { usdc: Address }).usdc;
  }
  if (!usdc) throw new Error("host did not come up");
  const off = await fetch(`${base}/api/app/me`);
  expect(off.status).toBe(503);
  expect(await off.json()).toEqual({
    error: "The real app is not set up on this server",
  });
}, 180_000);

afterAll(() => {
  // Group signal: the host and every instance it started.
  if (host?.pid) process.kill(-host.pid, "SIGTERM");
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
const rpc = async (body: unknown, headers: Record<string, string> = {}) => {
  const res = await fetch(`${base}/rpc`, {
    method: "POST",
    headers: { "content-type": "application/json", ...headers },
    body: JSON.stringify(body),
  });
  return { status: res.status, json: (await res.json()) as J };
};

const chain = defineChain({
  id: 31337,
  name: "anvil",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: ["/rpc"] } },
});

/** One user's whole tutorial; yields after every step so two users can take turns. */
async function* play(name: string) {
  const account = privateKeyToAccount(generatePrivateKey());
  const me = account.address;
  const transport = http(`${base}/rpc`, {
    fetchOptions: { headers: auth(me) },
  });
  const pub = createPublicClient({ chain, transport, pollingInterval: 50 });
  const wallet = createWalletClient({ account, chain, transport });
  const balance = (a: Address) =>
    pub.readContract({
      address: usdc,
      abi: mockUsdcAbi,
      functionName: "balanceOf",
      args: [a],
    }) as Promise<bigint>;

  const o = await api(me, "POST", "/onboard", { name });
  expect(o.status, JSON.stringify(o.json)).toBe(200);
  expect(o.json.grant).toEqual({ musdc: "20000000000", sent: true });
  yield;
  let s = (await api(me, "POST", "/tutorial/start")).json;
  expect(s.stepIndex).toBe(0);
  yield;

  let payouts: bigint[] = [];
  while (!s.done) {
    const a = s.step.action;
    const people = s.snapshot.members.map((m: J) => m.address as Address);
    const before =
      s.step.id === "withdraw" ? await Promise.all(people.map(balance)) : [];
    if (a) {
      const hash = await wallet.writeContract({
        address: a.target === "usdc" ? usdc : s.circle,
        abi: (a.target === "usdc" ? mockUsdcAbi : kuberCircleAbi) as Abi,
        functionName: a.functionName,
        args: a.args.map((x: unknown) =>
          typeof x === "string" && /^\d+$/.test(x) ? BigInt(x) : x,
        ),
      });
      expect((await pub.waitForTransactionReceipt({ hash })).status).toBe(
        "success",
      );
    }
    const prev = s.stepIndex;
    const r = await api(me, "POST", "/tutorial/next", { stepId: s.step.id });
    expect(r.status, `${name} ${s.step.id}: ${JSON.stringify(r.json)}`).toBe(
      200,
    );
    s = r.json;
    expect(s.stepIndex).toBe(prev + 1);
    // The real-app side is off here: no Fuji record, and the step still works.
    expect(s.lastChange.record).toBeNull();
    if (before.length) {
      const after = await Promise.all(people.map(balance));
      const byName = new Map(
        s.snapshot.members.map((m: J, i: number) => [
          m.name,
          after[i] - before[i],
        ]),
      );
      payouts = ["You", "Bala", "Chitra", "Dev", "Esha", "Farhan"].map(
        (n) => byName.get(n) as bigint,
      );
    }
    yield;
  }
  return { s, payouts };
}

const checkEnd = (r: { s: J; payouts: bigint[] }) => {
  expect(r.payouts).toEqual([
    712_043_010n,
    720_477_090n,
    683_926_264n,
    0n,
    693_976_540n,
    714_077_090n,
  ]);
  const m = new Map(r.s.snapshot.members.map((x: J) => [x.name, x]));
  expect((m.get("Dev") as J).debt).toBe("106749998");
  expect((m.get("Chitra") as J).lost).toBe("30000000");
  expect((m.get("Esha") as J).lost).toBe("20000000");
  expect(r.s.snapshot.status).toBe("Completed");
  expect(r.s.done).toBe(true);
};

test("hosted: two users interleaved through the whole tutorial, each on their own chain", async () => {
  // Welcome screen costs nothing: no token, no instance.
  const h = await fetch(`${base}/api/health`);
  expect(await h.json()).toMatchObject({ ok: true, chainId: 31337, usdc });
  expect((await fetch(`${base}/api/me`)).status).toBe(401);
  // Client routes get the app.
  const page = await fetch(`${base}/circles/some/where`);
  expect(page.status).toBe(200);
  expect(page.headers.get("content-type")).toMatch(/text\/html/);
  expect(await page.text()).toBe(INDEX);
  // The Fuji server's internal record route is never served from the public port.
  const internal = await fetch(`${base}/internal/practice-log`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: "{}",
  });
  expect(internal.status).toBe(404);

  const u1 = play("Alice");
  const u2 = play("Kabir");
  let r1: J;
  let r2: J;
  let turns = 0;
  while (!r1 || !r2) {
    if (!r1) {
      const x = await u1.next();
      if (x.done) r1 = x.value;
    }
    if (!r2) {
      const x = await u2.next();
      if (x.done) r2 = x.value;
    }
    turns++;
  }
  console.log(`interleaved turns: ${turns}`);
  console.log(`user 1 payouts (A..F): ${r1.payouts.join(", ")}`);
  console.log(`user 2 payouts (A..F): ${r2.payouts.join(", ")}`);
  checkEnd(r1);
  checkEnd(r2);

  // /rpc refuses time travel, state edits, unlocked accounts, and requests without the token.
  const someone = privateKeyToAccount(generatePrivateKey()).address;
  const call = (method: string, params: unknown[] = []) =>
    rpc({ jsonrpc: "2.0", id: 7, method, params }, auth(someone));
  for (const [method, params] of [
    ["anvil_setBalance", [someone, "0xffffffffffffffff"]],
    ["evm_increaseTime", [3600]],
    ["eth_sendTransaction", [{ from: someone, to: someone }]],
    ["eth_accounts", []],
  ] as const) {
    const r = await call(method, [...params]);
    expect(r.json.error?.code, method).toBe(-32601);
    expect(r.json.result).toBeUndefined();
  }
  const batch = await rpc(
    [
      { jsonrpc: "2.0", id: 1, method: "eth_blockNumber", params: [] },
      { jsonrpc: "2.0", id: 2, method: "evm_mine", params: [] },
    ],
    auth(someone),
  );
  expect(batch.json.map((x: J) => x.error?.code)).toEqual([-32601, -32601]);
  const noToken = await rpc({
    jsonrpc: "2.0",
    id: 1,
    method: "eth_blockNumber",
    params: [],
  });
  expect(noToken.status).toBe(401);
  expect(noToken.json.error).toBeTruthy();
  expect((await call("eth_chainId")).json.result).toBe("0x7a69");
}, 300_000);
