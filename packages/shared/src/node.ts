// Node-only entry, kept apart so the browser bundle never pulls node:fs.
import { readFileSync } from "node:fs";
import type { Deployment } from "./index.ts";

export type { Deployment };

/** "local", "fuji", or "local-<chainId>" (a test chain's deploy, see scripts/deploy.ts). */
export const loadDeployment = (
  network: "local" | "fuji" | `local-${number}`,
): Deployment =>
  JSON.parse(
    readFileSync(
      new URL(`../../../deployments/${network}.json`, import.meta.url),
      "utf8",
    ),
  );
