import { expect, test } from "vitest";
import { kuberContracts, kuberFoundry } from "../wagmi.config.ts";

test("codegen exports only Kuber contract ABIs", async () => {
  const names = (await kuberFoundry.contracts()).map((c) => c.name);
  // All six exist in contracts/out today, so a too-wide include fails here.
  for (const leaked of [
    "IMulticall3",
    "Errors",
    "Create2",
    "TransientProbe",
    "ToolchainTest",
    "Deploy",
  ]) {
    expect(names).not.toContain(leaked);
  }
  const allowed: readonly string[] = kuberContracts;
  for (const name of names) expect(allowed).toContain(name);
});
