import { execSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";

const root = join(import.meta.dirname, "..");

// Mirrors docs/TECH_STACK.md §3. Change both together.
const EXPECTED: Record<string, string> = {
  "@axe-core/playwright": "4.14.0",
  "@biomejs/biome": "2.6.7",
  "@hono/node-server": "2.1.8",
  "@lhci/cli": "0.16.1",
  "@playwright/test": "1.65.0",
  "@privy-io/node": "0.39.0",
  "@privy-io/react-auth": "3.51.4",
  "@privy-io/wagmi": "4.0.20",
  "@tailwindcss/vite": "4.3.5",
  "@tanstack/react-query": "5.107.1",
  "@types/react": "19.3.0",
  "@types/react-dom": "19.3.0",
  "@vitejs/plugin-react": "6.3.0",
  "@wagmi/cli": "2.10.1",
  hono: "4.13.18",
  jsdom: "31.0.1",
  "lucide-react": "1.72.0",
  "radix-ui": "1.8.1",
  react: "19.3.1",
  "react-dom": "19.3.1",
  "react-router": "8.5.1",
  solhint: "6.2.5",
  tailwindcss: "4.3.5",
  typescript: "6.0.3",
  viem: "2.57.19",
  vite: "8.3.8",
  "vite-plugin-pwa": "2.0.0",
  vitest: "5.1.0",
  wagmi: "3.7.11",
  "workbox-build": "7.4.1",
  "workbox-window": "7.4.1",
  zod: "4.6.7",
  // D-25: the one package outside TECH_STACK §3; TS 6 loads no Node types without it.
  "@types/node": "26.6.6",
};

const problems: string[] = [];
let checks = 0;
const check = (what: string, actual: string | undefined, expected: string) => {
  checks++;
  if (actual !== expected)
    problems.push(`MISMATCH ${what}: ${actual} (expected ${expected})`);
};
const readJson = (path: string) => JSON.parse(readFileSync(path, "utf8"));
// Through sh, not execFileSync: on macOS pnpm's launcher has no shebang and only a shell runs it. Commands are constants.
const run = (command: string) => {
  try {
    return execSync(command, { encoding: "utf8" }).trim();
  } catch {
    return "not runnable";
  }
};

// Toolchain (D-01, D-02, D-03, D-04, D-07, D-09)
check(".nvmrc", readFileSync(join(root, ".nvmrc"), "utf8").trim(), "26.8.2");
check("node major version", process.versions.node.split(".")[0], "26");
const rootPkg = readJson(join(root, "package.json"));
check("package.json packageManager", rootPkg.packageManager, "pnpm@12.18.0");
check("package.json engines.node", rootPkg.engines?.node, ">=26");
check("pnpm --version", run("pnpm --version"), "12.18.0");
for (const tool of ["forge", "anvil", "cast"]) {
  const firstLine = run(`${tool} --version`).split("\n")[0];
  check(`${tool} --version`, firstLine, `${tool} Version: 1.9.0`);
}
check("slither --version", run("slither --version"), "0.11.6");
const foundry = readFileSync(join(root, "contracts/foundry.toml"), "utf8");
check(
  "contracts/foundry.toml solc",
  foundry.match(/^solc = "(.*)"$/m)?.[1],
  "0.8.38",
);
check(
  "contracts/foundry.toml evm_version",
  foundry.match(/^evm_version = "(.*)"$/m)?.[1],
  "cancun",
);
check(
  "contracts/lib/openzeppelin-contracts",
  readJson(join(root, "contracts/lib/openzeppelin-contracts/package.json"))
    .version,
  "5.6.1",
);
check(
  "contracts/lib/forge-std",
  readJson(join(root, "contracts/lib/forge-std/package.json")).version,
  "1.17.0",
);

// Workspace: every dependency is a workspace link or an exact §3 pin, declared and installed (D-06, D-10)
const projects: { name: string; path: string }[] = JSON.parse(
  run("pnpm ls -r --json --depth -1"),
);
const used = new Set<string>();
for (const { name, path } of projects) {
  const pkg = readJson(join(path, "package.json"));
  for (const deps of [pkg.dependencies, pkg.devDependencies]) {
    for (const [dep, spec] of Object.entries<string>(deps ?? {})) {
      if (spec === "workspace:*") continue;
      used.add(dep);
      if (!Object.hasOwn(EXPECTED, dep)) {
        checks++;
        problems.push(`MISMATCH ${name} ${dep}: not in TECH_STACK §3`);
        continue;
      }
      // Equality with an exact pin also rejects ^, ~, ranges, and tags.
      check(`${name} package.json ${dep}`, spec, EXPECTED[dep]);
      const installed = join(path, "node_modules", dep, "package.json");
      check(
        `${name} installed ${dep}`,
        existsSync(installed) ? readJson(installed).version : "not installed",
        EXPECTED[dep],
      );
    }
  }
}
for (const dep of Object.keys(EXPECTED)) {
  check(`${dep} used by a workspace package`, String(used.has(dep)), "true");
}

if (problems.length) {
  console.error(problems.join("\n"));
  process.exit(1);
}
console.log(`versions match TECH_STACK §3 (${checks} checks)`);
