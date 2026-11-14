// Hosted mode: one public process, one private chain + dev-api per user (keyed by the dev token's address).
// Time is global on a chain and the tutorial moves it, so users are isolated by giving each their own Anvil.
// Boot: deploy once to a template Anvil, dump its state, and start every user chain from that file.
import { type ChildProcess, spawn, spawnSync } from "node:child_process";
import {
  copyFileSync,
  existsSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { extname, join, resolve, sep } from "node:path";
import { serve } from "@hono/node-server";
import { Hono } from "hono";
import { bodyLimit } from "hono/body-limit";

const root = join(import.meta.dirname, "..", "..", "..");
process.env.PATH = `${process.env.HOME}/.foundry/bin:${process.env.PATH}`;

// The children run dev-api with DEV_MODE=true (a sandbox by design), and dev-api refuses that next to
// NODE_ENV=production. The guard stays: never set NODE_ENV=production for this host or its children.
if (process.env.NODE_ENV === "production")
  throw new Error(
    "refusing to start: the hosted demo runs dev-api in DEV_MODE; unset NODE_ENV=production",
  );

const HOST = process.env.HOST ?? "0.0.0.0";
const PORT = Number(process.env.PORT ?? 8080);
const MAX_INSTANCES = Number(process.env.MAX_INSTANCES ?? 12);
const IDLE_MS = Number(process.env.IDLE_MINUTES ?? 30) * 60_000;
const DIST = resolve(process.env.WEB_DIST ?? join(root, "apps", "web", "dist"));
const dir = mkdtempSync(join(tmpdir(), "kuber-host-"));
const STATE = join(dir, "state.json");
const DEPLOYMENT = join(dir, "deployment.json");

const freePort = () =>
  new Promise<number>((ok) => {
    const s = createServer().listen(0, "127.0.0.1", () => {
      const { port } = s.address() as { port: number };
      s.close(() => ok(port));
    });
  });
const rpcCall = async (url: string, method: string, params: unknown[] = []) => {
  const res = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
  });
  return ((await res.json()) as { result: string }).result;
};
const waitFor = async (what: string, ok: () => Promise<boolean>) => {
  for (let i = 0; i < 300; i++) {
    if (await ok().catch(() => false)) return;
    await new Promise((r) => setTimeout(r, 100));
  }
  throw new Error(`${what} did not come up`);
};

// The real app's secrets stay with the host and its Fuji child; per-user chains and dev-apis never see them.
const SECRETS = [
  "FUJI_ADMIN_PRIVATE_KEY",
  "SESSION_SECRET",
  "PRIVY_APP_SECRET",
] as const;
const childEnv: NodeJS.ProcessEnv = { ...process.env };
for (const k of SECRETS) delete childEnv[k];

// Each child leads its own process group, so one group signal also stops what it started.
const all = new Set<ChildProcess>();
const launch = (cmd: string, args: string[], env = childEnv) => {
  const child = spawn(cmd, args, {
    cwd: root,
    env,
    detached: true,
    stdio: ["ignore", "ignore", "inherit"],
  });
  all.add(child);
  child.on("exit", () => all.delete(child));
  return child;
};
const kill = (child: ChildProcess) => {
  try {
    if (child.pid) process.kill(-child.pid, "SIGTERM");
  } catch {
    // already gone
  }
};
process.on("exit", () => {
  for (const child of all) kill(child);
  rmSync(dir, { recursive: true, force: true });
});
for (const signal of ["SIGINT", "SIGTERM", "SIGHUP"] as const)
  process.on(signal, () => process.exit(0));

const startAnvil = async (extra: string[]) => {
  const port = await freePort();
  const rpc = `http://127.0.0.1:${port}`;
  const child = launch("anvil", [
    "--host",
    "127.0.0.1",
    "--port",
    String(port),
    "--chain-id",
    "31337",
    "--quiet",
    ...extra,
  ]);
  try {
    await waitFor("anvil", async () => !!(await rpcCall(rpc, "eth_chainId")));
  } catch (err) {
    kill(child);
    throw err;
  }
  return { child, rpc };
};
const stopAndWait = (child: ChildProcess) =>
  new Promise<void>((ok) => {
    if (child.exitCode !== null || child.signalCode !== null) return ok();
    child.once("exit", () => ok());
    kill(child);
  });

// --- Boot: template chain, deploy, dump, verify a loaded copy. ---
{
  const t = await startAnvil(["--dump-state", STATE]);
  // deploy.ts writes deployments/local.json for chain 31337; keep the repo's copy as it was.
  const shared = join(root, "deployments", "local.json");
  const saved = existsSync(shared) ? readFileSync(shared, "utf8") : null;
  try {
    const r = spawnSync(
      process.execPath,
      ["scripts/deploy.ts", "--network", "local", "--rpc", t.rpc],
      { cwd: root, encoding: "utf8" },
    );
    if (r.status !== 0) throw new Error(`deploy failed: ${r.stderr}`);
    copyFileSync(shared, DEPLOYMENT);
  } finally {
    if (saved !== null) writeFileSync(shared, saved);
  }
  await stopAndWait(t.child);
  if (!existsSync(STATE)) throw new Error("anvil did not write its state");
}
const dep = JSON.parse(readFileSync(DEPLOYMENT, "utf8")) as {
  chainId: number;
  usdc: string;
  factory: string;
  registry: string;
};
{
  const check = await startAnvil(["--load-state", STATE]);
  for (const a of [dep.usdc, dep.factory, dep.registry])
    if ((await rpcCall(check.rpc, "eth_getCode", [a, "latest"])).length <= 2)
      throw new Error(`state file has no contract at ${a}`);
  await stopAndWait(check.child);
}

// --- The real app (REAL-APP.md): one shared Fuji server child when FUJI_ADMIN_PRIVATE_KEY is set. ---
const APP_OFF = "The real app is not set up on this server";
let appUrl: string | null = null;
const startApp = async () => {
  const port = await freePort();
  const url = `http://127.0.0.1:${port}`;
  const child = launch(
    process.execPath,
    ["services/dev-api/src/fuji-server.ts"],
    { ...process.env, APP_PORT: String(port), APP_HOST: "127.0.0.1" },
  );
  child.on("exit", (code) => {
    appUrl = null;
    console.error(`real app server exited (${code}); restarting in 5 s`);
    setTimeout(() => void startApp().catch(() => {}), 5_000).unref();
  });
  try {
    await waitFor(
      "real app server",
      async () => (await fetch(`${url}/api/app/health`)).ok,
    );
    appUrl = url;
    console.log("real app server ready");
  } catch (err) {
    console.error(`real app server: ${String((err as Error).message)}`);
  }
};
if (process.env.FUJI_ADMIN_PRIVATE_KEY) void startApp();

// --- Per-user instances. ---
type Entry = {
  last: number;
  procs: ChildProcess[];
  ready: Promise<{ rpc: string; api: string }>;
};
const live = new Map<string, Entry>();
const short = (key: string) => `${key.slice(0, 6)}…${key.slice(-4)}`;
class Full extends Error {}

const stop = (key: string) => {
  const e = live.get(key);
  if (!e) return;
  live.delete(key);
  for (const p of e.procs) kill(p);
  console.log(`instance stopped ${short(key)} (${live.size} live)`);
};

const boot = async (key: string, e: Entry) => {
  const watch = (p: ChildProcess) => {
    e.procs.push(p);
    if (live.get(key) !== e) kill(p); // stopped while booting
    p.on("exit", () => {
      if (live.get(key) === e) stop(key);
    });
  };
  const a = await startAnvil(["--load-state", STATE]);
  watch(a.child);
  const apiPort = await freePort();
  const api = `http://127.0.0.1:${apiPort}`;
  // NODE_ENV is passed through untouched (the guard above); dev-api binds loopback only.
  watch(
    launch(process.execPath, ["services/dev-api/src/index.ts"], {
      ...childEnv,
      RPC_URL: a.rpc,
      PORT: String(apiPort),
      DEV_MODE: "true",
      DEPLOYMENT_PATH: DEPLOYMENT,
    }),
  );
  await waitFor("dev-api", async () => (await fetch(`${api}/health`)).ok);
  console.log(`instance started ${short(key)} (${live.size} live)`);
  return { rpc: a.rpc, api };
};

const instanceFor = (key: string) => {
  let e = live.get(key);
  if (!e) {
    if (live.size >= MAX_INSTANCES) {
      const idle = [...live]
        .filter(([, x]) => Date.now() - x.last > IDLE_MS)
        .sort((x, y) => x[1].last - y[1].last)[0];
      if (!idle) throw new Full();
      stop(idle[0]);
    }
    const entry: Entry = { last: Date.now(), procs: [], ready: null as never };
    entry.ready = boot(key, entry);
    entry.ready.catch((err) => {
      console.error(`instance failed ${short(key)}: ${String(err.message)}`);
      if (live.get(key) === entry) stop(key);
    });
    live.set(key, entry);
    e = entry;
  }
  e.last = Date.now();
  return e.ready;
};
setInterval(() => {
  for (const [key, e] of live) if (Date.now() - e.last > IDLE_MS) stop(key);
}, 60_000).unref();

const userKey = (header: string | undefined) => {
  const m = /^Bearer dev:(0x[0-9a-fA-F]{40})$/.exec(header ?? "");
  return m ? m[1].toLowerCase() : null;
};
const FULL = "The demo is full right now. Try again in a few minutes.";

// --- Routes. ---
const app = new Hono();
const limit = bodyLimit({
  maxSize: 100 * 1024,
  onError: (c) => c.json({ error: "That request is too large." }, 413),
});

app.get("/api/health", (c) =>
  c.json({
    ok: true,
    chainId: dep.chainId,
    usdc: dep.usdc,
    factory: dep.factory,
  }),
);

app.all("/api/app/*", limit, async (c) => {
  if (!process.env.FUJI_ADMIN_PRIVATE_KEY)
    return c.json({ error: APP_OFF }, 503);
  if (!appUrl)
    return c.json(
      { error: "The real app is starting. Try again in a moment." },
      503,
    );
  const url = new URL(c.req.url);
  const hasBody = c.req.method !== "GET" && c.req.method !== "HEAD";
  const auth = c.req.header("authorization");
  const res = await fetch(`${appUrl}${url.pathname}${url.search}`, {
    method: c.req.method,
    headers: {
      ...(auth ? { authorization: auth } : {}),
      "content-type": c.req.header("content-type") ?? "application/json",
    },
    body: hasBody ? await c.req.arrayBuffer() : undefined,
  }).catch(() => null);
  if (!res)
    return c.json(
      {
        error:
          "The real app is not available right now. Try again in a moment.",
      },
      503,
    );
  return new Response(res.body, {
    status: res.status,
    headers: {
      "content-type": res.headers.get("content-type") ?? "application/json",
    },
  });
});

app.all("/api/*", limit, async (c) => {
  const auth = c.req.header("authorization");
  const key = userKey(auth);
  if (!key) return c.json({ error: "Please sign in first." }, 401);
  let target: { api: string };
  try {
    target = await instanceFor(key);
  } catch (err) {
    if (err instanceof Full) return c.json({ error: FULL }, 503);
    return c.json(
      { error: "The practice chain did not start. Try again in a moment." },
      503,
    );
  }
  const url = new URL(c.req.url);
  const hasBody = c.req.method !== "GET" && c.req.method !== "HEAD";
  const res = await fetch(
    `${target.api}${url.pathname.slice(4)}${url.search}`,
    {
      method: c.req.method,
      headers: {
        authorization: auth as string,
        "content-type": c.req.header("content-type") ?? "application/json",
      },
      body: hasBody ? await c.req.arrayBuffer() : undefined,
    },
  );
  return new Response(res.body, {
    status: res.status,
    headers: {
      "content-type": res.headers.get("content-type") ?? "application/json",
    },
  });
});

// Read and send-raw only: anything that moves time, edits state, or uses Anvil's unlocked accounts is refused.
const allowed = (method: unknown) =>
  typeof method === "string" &&
  (method === "net_version" ||
    method === "web3_clientVersion" ||
    (method.startsWith("eth_") &&
      !method.startsWith("eth_sign") &&
      !/^eth_(accounts|requestAccounts|coinbase)$/.test(method) &&
      (!method.startsWith("eth_send") ||
        /^eth_sendRawTransaction(Sync)?$/.test(method))));
const rpcError = (id: unknown, code: number, message: string) => ({
  jsonrpc: "2.0",
  id: id ?? null,
  error: { code, message },
});

app.post("/rpc", limit, async (c) => {
  const key = userKey(c.req.header("authorization"));
  if (!key) return c.json(rpcError(null, -32001, "Please sign in first."), 401);
  const text = await c.req.text();
  let body: unknown;
  try {
    body = JSON.parse(text);
  } catch {
    return c.json(rpcError(null, -32700, "Parse error"));
  }
  const items = (Array.isArray(body) ? body : [body]) as { id?: unknown }[];
  const bad = (x: unknown) =>
    !x || typeof x !== "object" || !allowed((x as { method?: unknown }).method);
  if (items.length === 0 || items.some(bad)) {
    const errors = items.map((x) =>
      rpcError(x?.id, -32601, bad(x) ? "Method not allowed" : "Batch refused"),
    );
    return c.json(
      Array.isArray(body)
        ? errors.length
          ? errors
          : rpcError(null, -32600, "Empty batch")
        : errors[0],
    );
  }
  let target: { rpc: string };
  try {
    target = await instanceFor(key);
  } catch (err) {
    return c.json(
      rpcError(null, -32002, err instanceof Full ? FULL : "Chain not ready"),
      503,
    );
  }
  const res = await fetch(target.rpc, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: text,
  });
  return new Response(res.body, {
    status: res.status,
    headers: { "content-type": "application/json" },
  });
});

const TYPES: Record<string, string> = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".mjs": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json",
  ".webmanifest": "application/manifest+json",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".webp": "image/webp",
  ".ico": "image/x-icon",
  ".woff2": "font/woff2",
  ".txt": "text/plain; charset=utf-8",
  ".map": "application/json",
};
const isFile = (p: string) => {
  try {
    return statSync(p).isFile();
  } catch {
    return false;
  }
};
// Static app; client routes and unknown paths get index.html. resolve + prefix check stops traversal.
app.get("*", (c) => {
  let file = join(DIST, "index.html");
  try {
    const want = resolve(
      DIST,
      `.${decodeURIComponent(new URL(c.req.url).pathname)}`,
    );
    if (want.startsWith(DIST + sep) && isFile(want)) file = want;
  } catch {
    // malformed path: index.html
  }
  if (!isFile(file)) return c.text("The app is not built.", 404);
  return c.body(readFileSync(file), 200, {
    "content-type": TYPES[extname(file)] ?? "application/octet-stream",
    "cache-control": file.includes(`${sep}assets${sep}`)
      ? "public, max-age=31536000, immutable"
      : "no-cache",
  });
});

serve({ fetch: app.fetch, hostname: HOST, port: PORT }, (info) => {
  console.log(
    `kuber host listening on http://${HOST}:${info.port} (max ${MAX_INSTANCES} users, idle ${IDLE_MS / 60_000} min)`,
  );
});
