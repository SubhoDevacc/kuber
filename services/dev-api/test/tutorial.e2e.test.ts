// Headless end-to-end: own Anvil on a free port, the real deploy, the app in-process, and a user who only follows
// the JSON (target, functionName, args) — the web app's job.
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
  type Abi,
  type Address,
  createPublicClient,
  createWalletClient,
  defineChain,
  http,
} from "viem";
import { generatePrivateKey, privateKeyToAccount } from "viem/accounts";
import { afterAll, beforeAll, expect, test } from "vitest";
import { createApp } from "../src/app.ts";
import { parseEnv } from "../src/chain.ts";

const root = join(import.meta.dirname, "..", "..", "..");
const PATH = `${process.env.HOME}/.foundry/bin:${process.env.PATH}`;
const freePort = () =>
  new Promise<number>((resolve) => {
    const s = createServer().listen(0, "127.0.0.1", () => {
      const { port } = s.address() as { port: number };
      s.close(() => resolve(port));
    });
  });

let anvil: ChildProcess;
let rpc: string;
let app: Awaited<ReturnType<typeof createApp>>["app"];
let usdc: Address;
let factory: Address;
const samples: Record<string, unknown> = {};
const SETTLES = [
  "round1",
  "round2",
  "request",
  "claim",
  "repay1",
  "vote",
  "default",
];
/** Digit-only strings are uints, also inside objects (createCircle's tuples). */
const toArgs = (x: unknown): unknown =>
  typeof x === "string" && /^\d+$/.test(x)
    ? BigInt(x)
    : Array.isArray(x)
      ? x.map(toArgs)
      : x && typeof x === "object"
        ? Object.fromEntries(Object.entries(x).map(([k, v]) => [k, toArgs(v)]))
        : x;

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
    {
      stdio: "ignore",
      env: { ...process.env, PATH },
    },
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
  // deploy.ts always writes deployments/local.json; keep the repo's copy (another track may be using it).
  const shared = join(root, "deployments", "local.json");
  const saved = readFileSync(shared, "utf8");
  const dir = mkdtempSync(join(tmpdir(), "kuber-e2e-"));
  const deployment = join(dir, "local.json");
  try {
    const r = spawnSync(
      process.execPath,
      ["scripts/deploy.ts", "--network", "local", "--rpc", rpc],
      {
        cwd: root,
        env: { ...process.env, PATH },
        encoding: "utf8",
      },
    );
    if (r.status !== 0) throw new Error(`deploy failed: ${r.stderr}`);
    copyFileSync(shared, deployment);
  } finally {
    writeFileSync(shared, saved);
  }
  ({ app } = await createApp(
    parseEnv({ RPC_URL: rpc, DEV_MODE: "true", DEPLOYMENT_PATH: deployment }),
  ));
  ({ usdc, factory } = (await (await app.request("/health")).json()) as {
    usdc: Address;
    factory: Address;
  });
}, 120_000);

afterAll(() => {
  anvil?.kill();
});

// biome-ignore lint/suspicious/noExplicitAny: test reads loose JSON
type J = any;
const api = async (
  who: Address,
  method: string,
  path: string,
  body?: unknown,
) => {
  const res = await app.request(path, {
    method,
    headers: {
      authorization: `Bearer dev:${who}`,
      "content-type": "application/json",
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  return { status: res.status, json: (await res.json()) as J };
};

const chain = () =>
  defineChain({
    id: 31337,
    name: "anvil",
    nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
    rpcUrls: { default: { http: [rpc] } },
  });
const balance = (pub: ReturnType<typeof createPublicClient>, a: Address) =>
  pub.readContract({
    address: usdc,
    abi: mockUsdcAbi,
    functionName: "balanceOf",
    args: [a],
  }) as Promise<bigint>;

/** Plays the whole tutorial as a fresh user; returns the measured payouts and the final state. */
const play = async (name: string, choice: "join" | "create" = "join") => {
  const account = privateKeyToAccount(generatePrivateKey());
  const me = account.address;
  const pub = createPublicClient({
    chain: chain(),
    transport: http(rpc),
    pollingInterval: 50,
  });
  const wallet = createWalletClient({
    account,
    chain: chain(),
    transport: http(rpc),
  });

  expect((await api(me, "POST", "/tutorial/start")).status).toBe(409); // not signed up yet
  const [o1, o2] = await Promise.all([
    api(me, "POST", "/onboard", { name }),
    api(me, "POST", "/onboard", { name }),
  ]);
  expect([o1.json.grant.sent, o2.json.grant.sent].sort()).toEqual([
    false,
    true,
  ]);
  const o3 = await api(me, "POST", "/onboard", { name });
  expect(o3.json.grant).toEqual({ musdc: "20000000000", sent: false });
  expect(o3.json.verified).toBe(true);
  expect(o3.json.musdc).toBe("20000000000");

  // Two starts at once give one circle; a later start returns it again.
  const [st1, st2] = await Promise.all([
    api(me, "POST", "/tutorial/start"),
    api(me, "POST", "/tutorial/start"),
  ]);
  let s = st1.json;
  expect(st2.json.circle).toBe(s.circle);
  expect(s.stepIndex).toBe(0);
  expect(s.chapter).toBe(1);
  expect(s.lastChange).toBeNull();
  expect(s.snapshot.members.length).toBe(5);
  expect((await api(me, "POST", "/tutorial/start")).json.circle).toBe(s.circle);

  // The first step is the choice (no transaction).
  samples[`${choice}: start step`] = s.step;
  expect(s.step.id).toBe("start");
  expect(s.step.action).toBeNull();
  const ids: string[] = ["start"];
  s = (await api(me, "POST", "/tutorial/next", { stepId: "start", choice }))
    .json;
  expect(s.choice).toBe(choice);
  expect(s.stepIndex).toBe(1);
  expect(s.lastChange.rows.length).toBeGreaterThan(0);

  // Skipping the action: 409 and no advance.
  const skip = await api(me, "POST", "/tutorial/next");
  expect(skip.status).toBe(409);
  expect(skip.json.error).toMatch(/\w/);
  expect((await api(me, "GET", "/tutorial")).json.stepIndex).toBe(1);

  let payouts: bigint[] = [];
  while (!s.done) {
    ids.push(s.step.id);
    const a = s.step.action;
    let before: bigint[] = [];
    const people = s.snapshot.members.map((m: J) => m.address as Address);
    if (s.step.id === "withdraw")
      before = await Promise.all(people.map((p: Address) => balance(pub, p)));
    if (a) {
      const args = toArgs(a.args) as unknown[];
      const hash = await wallet.writeContract({
        address:
          a.target === "usdc"
            ? usdc
            : a.target === "factory"
              ? factory
              : s.circle,
        abi: (a.target === "usdc"
          ? mockUsdcAbi
          : a.target === "factory"
            ? kuberFactoryAbi
            : kuberCircleAbi) as Abi,
        functionName: a.functionName,
        args,
      });
      expect((await pub.waitForTransactionReceipt({ hash })).status).toBe(
        "success",
      );
    }
    const prev = s.stepIndex;
    const stepId = s.step.id;
    if (stepId === "create") samples["create: create step"] = s.step;
    if (s.step.options) {
      expect(s.step.options.map((o: J) => o.value)).toEqual(["join", "create"]);
      const r = await api(me, "POST", "/tutorial/next", { stepId, choice });
      expect(r.status, JSON.stringify(r.json)).toBe(200);
      s = r.json;
      expect(s.choice).toBe(choice);
    } else if (s.step.id === "round1") {
      // A double click: both answers show the same, single advance.
      const [x, y] = await Promise.all([
        api(me, "POST", "/tutorial/next"),
        api(me, "POST", "/tutorial/next"),
      ]);
      expect(x.json.stepIndex).toBe(prev + 1);
      expect(y.json.stepIndex).toBe(prev + 1);
      s = x.json;
    } else {
      const r = await api(me, "POST", "/tutorial/next", { stepId: s.step.id });
      expect(r.status, JSON.stringify(r.json)).toBe(200);
      s = r.json;
    }
    expect(s.stepIndex).toBe(prev + 1);
    expect(s.lastChange?.title).toMatch(/\w/);
    expect(s.lastChange.rows.length).toBeGreaterThan(0);
    // Every server transaction of the step is listed and real; a step that closes a round lists its settlement.
    for (const tx of s.lastChange.txs) {
      expect(tx.label).toMatch(/\w/);
      expect((await pub.getTransactionReceipt({ hash: tx.hash })).status).toBe(
        "success",
      );
    }
    if (stepId === "request" || stepId === "create")
      samples[`${choice}: lastChange after ${stepId}`] = s.lastChange;
    if (SETTLES.includes(stepId))
      expect(
        s.lastChange.txs.some((x: J) =>
          /^Round \d+ closed and settled$/.test(x.label),
        ),
        stepId,
      ).toBe(true);
    if (before.length) {
      const after = await Promise.all(
        people.map((p: Address) => balance(pub, p)),
      );
      const byName = new Map(
        s.snapshot.members.map((m: J, i: number) => [
          m.name,
          after[i] - before[i],
        ]),
      );
      payouts = ["You", "Bob", "Cara", "Dave", "Erin", "Frank"].map(
        (n) => byName.get(n) as bigint,
      );
    }
  }
  // A repeated click on the last step changes nothing.
  expect((await api(me, "POST", "/tutorial/next")).json.stepIndex).toBe(
    s.stepIndex,
  );
  // Transaction history: the circle's lines (newest first) and the user's own.
  const act = await api(me, "GET", `/circles/${s.circle}/activity`);
  expect(act.status).toBe(200);
  const whats = act.json.map((e: J) => e.what);
  expect(whats).toContain("You joined");
  expect(whats).toContain("You asked to borrow 350.00");
  expect(whats).toContain("Bob backed your loan with 80.00");
  expect(whats).toContain("Round 7 closed");
  expect(act.json[0].block).toBeGreaterThanOrEqual(act.json.at(-1).block);
  const mine = await api(me, "GET", "/activity");
  expect(mine.json.every((e: J) => e.who === "You")).toBe(true);
  expect(
    mine.json.some((e: J) =>
      e.what.startsWith("You collected a share-out of 712.04"),
    ),
  ).toBe(true);
  if (process.env.TUTORIAL_EXAMPLES)
    writeFileSync(
      process.env.TUTORIAL_EXAMPLES,
      JSON.stringify(
        { circle: act.json.slice(0, 12), mine: mine.json.slice(0, 6), samples },
        null,
        2,
      ),
    );
  return { me, s, ids, payouts };
};

const checkEnd = (r: Awaited<ReturnType<typeof play>>) => {
  expect(r.payouts).toEqual([
    712_043_010n,
    720_477_090n,
    683_926_264n,
    0n,
    693_976_540n,
    714_077_090n,
  ]);
  const m = new Map(r.s.snapshot.members.map((x: J) => [x.name, x]));
  const get = (n: string) => m.get(n) as J;
  expect(get("Dave").debt).toBe("106749998");
  expect(get("Cara").lost).toBe("30000000");
  expect(get("Erin").lost).toBe("20000000");
  expect(get("Frank").lost).toBe("0");
  expect(get("You").lost).toBe("0");
  expect(r.s.snapshot.status).toBe("Completed");
  expect(r.s.done).toBe(true);
};

test("tutorial end to end: two users one after the other, then a reset", async () => {
  const health = await app.request("/health");
  expect(await health.json()).toMatchObject({ ok: true });
  expect((await app.request("/me")).status).toBe(401);

  const first = await play("Alice");
  checkEnd(first);
  console.log(`steps: ${first.ids.join(", ")}`);
  console.log(`payouts (A..F): ${first.payouts.join(", ")}`);

  const second = await play("Second User", "create");
  checkEnd(second);
  expect(second.ids.slice(0, 4)).toEqual([
    "start",
    "create",
    "approve",
    "begin",
  ]);
  console.log(`create path steps: ${second.ids.join(", ")}`);
  expect(second.s.circle).not.toBe(first.s.circle);

  const reset = (await api(second.me, "POST", "/tutorial/reset")).json;
  expect(reset.stepIndex).toBe(0);
  expect(reset.chapter).toBe(1);
  expect(reset.circle).not.toBe(second.s.circle);
  expect(reset.snapshot.status).toBe("Forming");
  expect(reset.lastChange).toBeNull();

  // Each user sees only their own practice circles (the second user: the finished one and the reset one).
  const list = (await api(first.me, "GET", "/circles")).json;
  expect(list.filter((c: J) => c.practice).map((c: J) => c.address)).toEqual([
    first.s.circle,
  ]);
  const list2 = (await api(second.me, "GET", "/circles")).json;
  expect(list2.filter((c: J) => c.practice).length).toBe(2);
  const snap = await api(first.me, "GET", `/circles/${first.s.circle}`);
  expect(snap.json.you.status).toBe("Paid out");
  expect(snap.json.you.paidOut).toBe("712043010");
}, 300_000);
