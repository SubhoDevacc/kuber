// node scripts/deploy-practice-log.ts [--rpc <url>] [--broadcast-fuji]
// Runs contracts/script/DeployPracticeLog.s.sol. Only simulates unless --broadcast-fuji is passed; then it deploys to
// Fuji (chain 43113 only) with DEPLOYER_PRIVATE_KEY from the environment, adds "practiceLog" to deployments/fuji.json,
// and prints the Sourcify and Routescan verify commands (the verify.ts flags).
import { execFileSync, spawnSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { parseArgs } from "node:util";
import { getAddress } from "viem";

const root = join(import.meta.dirname, "..");
process.env.PATH = `${process.env.HOME}/.foundry/bin:${process.env.PATH}`;

const FUJI_RPC = "https://api.avax-test.network/ext/bc/C/rpc";
const VERIFIER_URL =
  "https://api.routescan.io/v2/network/testnet/evm/43113/etherscan";
// Anvil account #0's well-known key: lets a simulation run without the real key.
const ANVIL_KEY =
  "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";

const { values } = parseArgs({
  options: {
    rpc: { type: "string", default: FUJI_RPC },
    "broadcast-fuji": { type: "boolean", default: false },
  },
});
const rpc = values.rpc;
const broadcast = values["broadcast-fuji"];
const key = process.env.DEPLOYER_PRIVATE_KEY ?? (broadcast ? "" : ANVIL_KEY);
if (!key) throw new Error("DEPLOYER_PRIVATE_KEY is not set");

const res = await fetch(rpc, {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}',
});
const chainId = Number(((await res.json()) as { result: string }).result);
if (broadcast && chainId !== 43113)
  throw new Error(`${rpc} is chain ${chainId}, expected 43113`);

const forge = spawnSync(
  "forge",
  [
    "script",
    "script/DeployPracticeLog.s.sol",
    "--rpc-url",
    rpc,
    "--private-key",
    key,
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
  transactions: {
    transactionType: string;
    contractName: string | null;
    contractAddress: string;
    transaction: { from: string };
  }[];
};
const run: Run = JSON.parse(
  readFileSync(
    join(
      root,
      "contracts",
      "broadcast",
      "DeployPracticeLog.s.sol",
      String(chainId),
      "run-latest.json",
    ),
    "utf8",
  ),
);
const tx = run.transactions.find(
  (t) =>
    t.transactionType === "CREATE" && t.contractName === "KuberPracticeLog",
);
if (!tx) throw new Error("KuberPracticeLog not in run-latest.json");
const practiceLog = getAddress(tx.contractAddress);
const owner = getAddress(tx.transaction.from);

const out = join(root, "deployments", "fuji.json");
const deployment = JSON.parse(readFileSync(out, "utf8"));
deployment.practiceLog = practiceLog;
writeFileSync(out, `${JSON.stringify(deployment, null, 2)}\n`);
console.log(`deployed KuberPracticeLog at ${practiceLog}; wrote ${out}`);

const args = execFileSync("cast", ["abi-encode", "f(address)", owner], {
  encoding: "utf8",
}).trim();
const base = `forge verify-contract ${practiceLog} src/KuberPracticeLog.sol:KuberPracticeLog --chain 43113 --rpc-url ${FUJI_RPC} --watch --constructor-args ${args}`;
console.log(`\nverify (run in contracts/):
${base} --verifier sourcify
${base} --verifier custom --verifier-url ${VERIFIER_URL} --verifier-api-key verifyContract`);
