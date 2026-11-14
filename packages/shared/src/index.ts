// Browser-safe entry: ABIs from contracts/out (`pnpm --filter @kuber/shared build`) and the deployment shape.
export * from "./generated.ts";

type Address = `0x${string}`;

/** `deployments/<network>.json`, written by `scripts/deploy.ts`. */
export type Deployment = {
  chainId: number;
  block: number;
  usdc: Address;
  aaveVault: Address;
  lpVault: Address;
  registry: Address;
  factory: Address;
  circleImpl: Address;
  libraries: Record<string, Address>;
};
