import { defineConfig } from "@wagmi/cli";
import { foundry } from "@wagmi/cli/plugins";

// SPEC §1 contracts/src list. forge-std, OZ, test, and script artifacts in contracts/out must not reach the app.
export const kuberContracts = [
  "MockUSDC",
  "MockAaveVault",
  "MockLPVault",
  "KuberRegistry",
  "KuberFactory",
  "KuberCircle",
] as const;

export const kuberFoundry = foundry({
  project: "../../contracts",
  // @kuber/contracts builds first (workspace dependency), so only read contracts/out.
  forge: { build: false },
  include: kuberContracts.map((name) => `${name}.sol/**`),
});

export default defineConfig({
  out: "src/generated.ts",
  plugins: [kuberFoundry],
});
