// Env, clients, the admin signer, chain writes (serialized), and time control.
import { existsSync, readFileSync } from "node:fs";
import {
  kuberCircleAbi,
  kuberFactoryAbi,
  kuberRegistryAbi,
  mockUsdcAbi,
} from "@kuber/shared";
import {
  type Abi,
  type Account,
  type Address,
  createPublicClient,
  createTestClient,
  createWalletClient,
  defineChain,
  http,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { z } from "zod";

// Anvil account #0's well-known key; used only when the chain id is 31337.
const ANVIL_ADMIN_KEY =
  "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";
const hex64 = z.string().regex(/^0x[0-9a-fA-F]{64}$/, "must be a 0x key");
const address = z.string().regex(/^0x[0-9a-fA-F]{40}$/);

const EnvSchema = z.object({
  RPC_URL: z.url().default("http://127.0.0.1:8545"),
  PORT: z.coerce.number().int().min(1).max(65535).default(8787),
  DEV_MODE: z.enum(["true", "false"]).default("false"),
  NODE_ENV: z.string().optional(),
  ADMIN_PRIVATE_KEY: hex64.optional(),
  WELCOME_GRANT_MUSDC: z.coerce.number().int().positive().default(20000),
  DEPLOYMENT_PATH: z.string().optional(),
});
export type Env = z.infer<typeof EnvSchema>;

export const parseEnv = (raw: NodeJS.ProcessEnv): Env => {
  const r = EnvSchema.safeParse(raw);
  if (!r.success)
    throw new Error(
      `bad environment: ${r.error.issues.map((i) => `${i.path.join(".")} ${i.message}`).join("; ")}`,
    );
  if (r.data.NODE_ENV === "production" && r.data.DEV_MODE === "true")
    throw new Error(
      "refusing to start: DEV_MODE=true with NODE_ENV=production",
    );
  return r.data;
};

const DeploymentSchema = z.object({
  chainId: z.number(),
  block: z.number().optional(),
  usdc: address,
  registry: address,
  factory: address,
});

export type Chain = Awaited<ReturnType<typeof connect>>;

/** Connects, checks the deployment matches the chain, freezes Anvil time, and returns the helpers. */
export const connect = async (
  env: Pick<Env, "RPC_URL" | "ADMIN_PRIVATE_KEY" | "DEPLOYMENT_PATH">,
  opts: { freezeTime?: boolean; pollingInterval?: number } = {},
) => {
  const path =
    env.DEPLOYMENT_PATH ??
    new URL("../../../deployments/local.json", import.meta.url).pathname;
  if (!existsSync(path))
    throw new Error(`no deployment at ${path}; run the deploy first`);
  const dep = DeploymentSchema.parse(JSON.parse(readFileSync(path, "utf8")));
  const probe = createPublicClient({ transport: http(env.RPC_URL) });
  const chainId = await probe.getChainId();
  if (chainId !== dep.chainId)
    throw new Error(
      `deployment is for chain ${dep.chainId} but ${env.RPC_URL} is chain ${chainId}`,
    );
  const key =
    env.ADMIN_PRIVATE_KEY ?? (chainId === 31337 ? ANVIL_ADMIN_KEY : undefined);
  if (!key) throw new Error("ADMIN_PRIVATE_KEY is required off chain 31337");
  const chain = defineChain({
    id: chainId,
    name: "local",
    nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
    rpcUrls: { default: { http: [env.RPC_URL] } },
  });
  const transport = http(env.RPC_URL, { batch: true });
  const pub = createPublicClient({
    chain,
    transport,
    pollingInterval: opts.pollingInterval ?? 50,
  });
  const test = createTestClient({ chain, transport, mode: "anvil" });
  const admin = privateKeyToAccount(key as `0x${string}`);
  const usdc = dep.usdc as Address;
  const registry = dep.registry as Address;
  const factory = dep.factory as Address;

  // R-T: chain time moves only when the server moves it, so a slow user never misses a window.
  // The real-app server (fuji.ts) runs on real time and passes freezeTime: false.
  if (chainId === 31337 && opts.freezeTime !== false)
    await test.setBlockTimestampInterval({ interval: 0 });

  // One chain writer at a time: no nonce races, and a double click cannot interleave with itself.
  let tail: Promise<unknown> = Promise.resolve();
  const locked = <T>(fn: () => Promise<T>): Promise<T> => {
    const run = tail.then(fn, fn);
    tail = run.catch(() => {});
    return run;
  };

  const send = async (
    account: Account,
    to: Address,
    abi: Abi,
    functionName: string,
    args: readonly unknown[] = [],
    gas?: bigint,
  ) => {
    const wallet = createWalletClient({ account, chain, transport });
    const hash = await wallet.writeContract({
      address: to,
      abi,
      functionName,
      args,
      gas,
    } as never);
    const r = await pub.waitForTransactionReceipt({ hash });
    if (r.status !== "success") throw new Error(`${functionName} reverted`);
    return r;
  };
  const read = <T>(
    to: Address,
    abi: Abi,
    functionName: string,
    args: readonly unknown[] = [],
  ) =>
    pub.readContract({
      address: to,
      abi,
      functionName,
      args,
    } as never) as Promise<T>;

  const now = async () => (await pub.getBlock()).timestamp;
  /** Moves chain time forward to `t`; never backwards. */
  const warpTo = async (t: bigint) => {
    if ((await now()) >= t) return;
    await test.setNextBlockTimestamp({ timestamp: t });
    await test.mine({ blocks: 1 });
  };
  const setGas = (who: Address) =>
    test.setBalance({ address: who, value: 100n * 10n ** 18n });

  return {
    chainId,
    chain,
    transport,
    deployBlock: BigInt(dep.block ?? 0),
    pub,
    admin,
    usdc,
    registry,
    factory,
    locked,
    send,
    read,
    now,
    warpTo,
    setGas,
    abis: {
      circle: kuberCircleAbi as Abi,
      factory: kuberFactoryAbi as Abi,
      registry: kuberRegistryAbi as Abi,
      usdc: mockUsdcAbi as Abi,
    },
  };
};

// settle and activate revert with viem's bare estimate (inner try/catch needs headroom); send a fixed limit.
export const BIG_GAS = 12_000_000n;
