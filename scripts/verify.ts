// node scripts/verify.ts [--rpc <url>]
// Verifies every contract in deployments/fuji.json. Verifier: Avalanche Builder Hub's Etherscan-compatible API (no API
// key; the key field is required by tooling and ignored), falling back to Sourcify. Already-verified contracts are
// skipped, so it is safe to re-run.
import { execFileSync, spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { parseArgs } from "node:util";
import type { Deployment } from "../packages/shared/src/index.ts";

const root = join(import.meta.dirname, "..");
process.env.PATH = `${process.env.HOME}/.foundry/bin:${process.env.PATH}`;
const { values } = parseArgs({
  options: {
    rpc: {
      type: "string",
      default: "https://api.avax-test.network/ext/bc/C/rpc",
    },
  },
});
const rpc = values.rpc;
const VERIFIER_URL =
  "https://api.routescan.io/v2/network/testnet/evm/43113/etherscan";

const d: Deployment = JSON.parse(
  readFileSync(join(root, "deployments", "fuji.json"), "utf8"),
);
const cast = (...args: string[]) =>
  execFileSync("cast", args, { encoding: "utf8" }).trim();
const admin = cast("call", d.registry, "owner()(address)", "--rpc-url", rpc);
const treasury = cast(
  "call",
  d.registry,
  "treasury()(address)",
  "--rpc-url",
  rpc,
);

// [address, source:Name, ABI-encoded constructor args]. Arguments mirror contracts/script/Deploy.s.sol.
const targets: [string, string, string][] = [
  [
    d.usdc,
    "src/MockUSDC.sol:MockUSDC",
    cast("abi-encode", "f(address)", admin),
  ],
  [
    d.aaveVault,
    "src/MockAaveVault.sol:MockAaveVault",
    cast(
      "abi-encode",
      "f(address,string,string,address)",
      d.usdc,
      "Mock Aave mUSDC",
      "maUSDC",
      admin,
    ),
  ],
  [
    d.lpVault,
    "src/MockLPVault.sol:MockLPVault",
    cast(
      "abi-encode",
      "f(address,string,string,address)",
      d.usdc,
      "Mock LP mUSDC",
      "mlpUSDC",
      admin,
    ),
  ],
  [
    d.registry,
    "src/KuberRegistry.sol:KuberRegistry",
    cast("abi-encode", "f(address,address)", admin, treasury),
  ],
  [d.circleImpl, "src/KuberCircle.sol:KuberCircle", ""],
  [
    d.factory,
    "src/KuberFactory.sol:KuberFactory",
    cast(
      "abi-encode",
      "f(address,address,address,address,address)",
      d.registry,
      d.usdc,
      d.aaveVault,
      d.lpVault,
      d.circleImpl,
    ),
  ],
  ...Object.entries(d.libraries).map(
    ([name, address]): [string, string, string] => [
      address,
      `src/lib/${name}.sol:${name}`,
      "",
    ],
  ),
];

// The libraries a contract's bytecode links, as forge's "path:Name:address", read from its build artifact.
const links = (id: string) => {
  const [path, name] = id.split(":");
  const artifact = JSON.parse(
    readFileSync(
      join(
        root,
        "contracts",
        "out",
        path.split("/").at(-1) as string,
        `${name}.json`,
      ),
      "utf8",
    ),
  );
  const refs: Record<string, Record<string, unknown>> = artifact.bytecode
    .linkReferences;
  return Object.entries(refs).flatMap(([source, libs]) =>
    Object.keys(libs).flatMap((lib) => [
      "--libraries",
      `${source}:${lib}:${d.libraries[lib]}`,
    ]),
  );
};

const forge = (args: string[]) =>
  spawnSync("forge", args, { cwd: join(root, "contracts"), stdio: "inherit" })
    .status === 0;

const failed: string[] = [];
for (const [address, id, args] of targets) {
  console.log(`\n== ${id} at ${address}`);
  const base = [
    "verify-contract",
    address,
    id,
    "--chain",
    "43113",
    "--rpc-url",
    rpc,
    "--watch",
    ...(args ? ["--constructor-args", args] : []),
    ...links(id),
  ];
  // Sourcify and Routescan (the Snowtrace explorer) both, no API key needed. The Builder Hub verifier reported
  // "does not match" for the six main contracts yet exited 0, so it is not used.
  const sourcify = forge([...base, "--verifier", "sourcify"]);
  const routescan = forge([
    ...base,
    "--verifier",
    "custom",
    "--verifier-url",
    VERIFIER_URL,
    "--verifier-api-key",
    "verifyContract",
  ]);
  const ok = sourcify || routescan;
  if (!ok) failed.push(id);
}
if (failed.length) {
  console.error(`\nnot verified: ${failed.join(", ")}`);
  process.exit(1);
}
console.log(`\nverified ${targets.length} contracts`);
