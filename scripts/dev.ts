import { type ChildProcess, spawn, spawnSync } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const root = join(import.meta.dirname, "..");
const RPC = "http://127.0.0.1:8545";
const SENDER = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"; // Anvil account #0's address; Anvil accounts are unlocked, so no key

// foundryup installs to ~/.foundry/bin, which a plain shell may not have on PATH. Children inherit this.
process.env.PATH = `${process.env.HOME}/.foundry/bin:${process.env.PATH}`;

// Each child leads its own process group, so one group SIGTERM also stops what it started (vite, node), leaving no port bound.
const children: ChildProcess[] = [];
process.on("exit", () => {
  for (const child of children) {
    try {
      if (child.pid) process.kill(-child.pid, "SIGTERM");
    } catch {
      // group already gone
    }
  }
});
// SIGHUP: closing the terminal must also stop the children, or Anvil keeps port 8545.
for (const signal of ["SIGINT", "SIGTERM", "SIGHUP"] as const)
  process.on(signal, () => process.exit(0));

// shell: on macOS pnpm's launcher has no shebang, so spawning it directly fails with ENOEXEC; sh runs it.
// stdin "ignore": a detached child that reads the terminal (Vite does) is stopped by SIGTTIN.
const start = (command: string) => {
  const child = spawn(command, {
    cwd: root,
    detached: true,
    shell: true,
    stdio: ["ignore", "inherit", "inherit"],
  });
  children.push(child);
  child.on("exit", (code, signal) => {
    console.error(`${command.split(" ")[0]} exited (${code ?? signal})`);
    process.exit(code || 1);
  });
};

start("anvil --host 127.0.0.1 --port 8545 --chain-id 31337 --quiet");

let chainId = 0;
const deadline = Date.now() + 15_000;
while (!chainId && Date.now() < deadline) {
  await new Promise((resolve) => setTimeout(resolve, 200));
  try {
    const res = await fetch(RPC, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}',
    });
    chainId = Number(((await res.json()) as { result: string }).result);
  } catch {
    // not up yet
  }
}
if (!chainId) {
  console.error("anvil did not answer on 8545");
  process.exit(1);
}
if (chainId !== 31337) {
  console.error(`anvil answered with chain id ${chainId}, expected 31337`);
  process.exit(1);
}

const deploy = spawnSync(
  "forge",
  [
    "script",
    "script/Deploy.s.sol",
    "--rpc-url",
    RPC,
    "--broadcast",
    "--unlocked",
    "--sender",
    SENDER,
  ],
  { cwd: join(root, "contracts"), stdio: "inherit" },
);
if (deploy.status !== 0) {
  console.error(
    `deploy failed${deploy.error ? `: ${deploy.error.message}` : ""}`,
  );
  process.exit(1);
}

mkdirSync(join(root, "deployments"), { recursive: true });
writeFileSync(
  join(root, "deployments", "local.json"),
  `${JSON.stringify({ chainId }, null, 2)}\n`,
);
console.log(`deployed: deployments/local.json (chainId ${chainId})`);

start(
  "pnpm --parallel --filter @kuber/dev-api --filter @kuber/keeper --filter @kuber/web run dev",
);
