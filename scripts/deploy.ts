// node scripts/deploy.ts [--network local|fuji] [--rpc <url>] [--broadcast-fuji]
// Runs contracts/script/Deploy.s.sol and writes deployments/<network>.json. Fuji only simulates unless
// --broadcast-fuji is passed; its key comes from DEPLOYER_PRIVATE_KEY in the environment.
import { spawnSync } from "node:child_process";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { parseArgs } from "node:util";
import { getAddress } from "viem";

const root = join(import.meta.dirname, "..");
process.env.PATH = `${process.env.HOME}/.foundry/bin:${process.env.PATH}`;

const { values } = parseArgs({
  options: {
    network: { type: "string", default: "local" },
    rpc: { type: "string" },
    "broadcast-fuji": { type: "boolean", default: false },
  },
});
const NETWORKS = {
  // Anvil account #0's well-known key; local chains only.
  local: {
    rpc: "http://127.0.0.1:8545",
    key: "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80",
  },
  fuji: {
    rpc: "https://api.avax-test.network/ext/bc/C/rpc",
    key: process.env.DEPLOYER_PRIVATE_KEY,
  },
};
const network = values.network as keyof typeof NETWORKS;
const net = NETWORKS[network];
if (!net) throw new Error(`unknown network ${values.network}`);
if (!net.key) throw new Error("DEPLOYER_PRIVATE_KEY is not set");
const rpc = values.rpc ?? net.rpc;
const broadcast = network === "local" || values["broadcast-fuji"];

// local: any chain id (tests give each Anvil its own, since two forge deploys on one chain id collide in forge's
// cache) but only on this machine. fuji: chain 43113 only.
if (network === "local" && !/^http:\/\/(127\.0\.0\.1|localhost)[:/]/.test(rpc))
  throw new Error(`--network local needs a 127.0.0.1 RPC, got ${rpc}`);
const res = await fetch(rpc, {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}',
});
const chainId = Number(((await res.json()) as { result: string }).result);
if (network === "fuji" && chainId !== 43113)
  throw new Error(`${rpc} is chain ${chainId}, expected 43113`);

const forge = spawnSync(
  "forge",
  [
    "script",
    "script/Deploy.s.sol",
    "--rpc-url",
    rpc,
    "--private-key",
    net.key,
    ...(broadcast ? ["--broadcast", "--slow"] : []),
  ],
  { cwd: join(root, "contracts"), stdio: "inherit" },
);
if (forge.status !== 0)
  throw new Error(
    `forge script failed${forge.error ? `: ${forge.error.message}` : ""}`,
  );
if (!broadcast) {
  console.log("simulated only; pass --broadcast-fuji to deploy");
  process.exit(0);
}

type Run = {
  libraries: string[];
  transactions: {
    transactionType: string;
    contractName: string | null;
    contractAddress: string;
  }[];
  receipts: { blockNumber: string }[];
};
const run: Run = JSON.parse(
  readFileSync(
    join(
      root,
      "contracts",
      "broadcast",
      "Deploy.s.sol",
      String(chainId),
      "run-latest.json",
    ),
    "utf8",
  ),
);
const created = (name: string) => {
  const tx = run.transactions.find(
    (t) => t.transactionType === "CREATE" && t.contractName === name,
  );
  if (!tx) throw new Error(`${name} not in run-latest.json`);
  return getAddress(tx.contractAddress);
};
const deployment = {
  chainId,
  block: Math.max(...run.receipts.map((r) => Number(r.blockNumber))),
  usdc: created("MockUSDC"),
  aaveVault: created("MockAaveVault"),
  lpVault: created("MockLPVault"),
  registry: created("KuberRegistry"),
  factory: created("KuberFactory"),
  circleImpl: created("KuberCircle"),
  // "src/lib/Forming.sol:Forming:0x…"
  libraries: Object.fromEntries(
    run.libraries.map((entry) => {
      const [, name, address] = entry.split(":");
      return [name, getAddress(address)];
    }),
  ),
};
// A test chain (any id but 31337) gets its own file, so a test never overwrites the one `pnpm dev` serves.
const name =
  network === "local" && chainId !== 31337 ? `local-${chainId}` : network;
mkdirSync(join(root, "deployments"), { recursive: true });
const out = join(root, "deployments", `${name}.json`);
writeFileSync(out, `${JSON.stringify(deployment, null, 2)}\n`);
console.log(`deployed: ${out}`);
