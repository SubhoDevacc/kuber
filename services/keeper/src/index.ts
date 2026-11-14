// Minimal keeper: activates due circles and settles ended rounds. Practice circles (dev-api's tutorial) are skipped:
// the tutorial engine drives its own clock and settlements.
import { existsSync, readFileSync } from "node:fs";
import { kuberCircleAbi, kuberFactoryAbi } from "@kuber/shared";
import {
  type Address,
  createPublicClient,
  createWalletClient,
  defineChain,
  http,
  maxUint256,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";

// Anvil account #1's well-known key; used only when the chain id is 31337.
const ANVIL_KEEPER_KEY =
  "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d";
const PRACTICE_PREFIX = "Practice circle";
// settle and activate revert with the bare gas estimate; a fixed limit leaves room (see dev-api chain.ts).
const GAS = 12_000_000n;

const shared = new URL("../../.env", import.meta.url);
if (existsSync(shared)) process.loadEnvFile(shared);
const RPC_URL = process.env.RPC_URL ?? "http://127.0.0.1:8545";
const INTERVAL_MS = Number(process.env.KEEPER_INTERVAL_MS ?? 5_000);
const DEPLOYMENT_PATH =
  process.env.DEPLOYMENT_PATH ??
  new URL("../../../deployments/local.json", import.meta.url).pathname;

const firstLine = (e: unknown) =>
  String((e as Error)?.message ?? e).split("\n")[0];

const main = async () => {
  const { factory } = JSON.parse(readFileSync(DEPLOYMENT_PATH, "utf8")) as {
    factory: Address;
  };
  const chainId = await createPublicClient({
    transport: http(RPC_URL),
  }).getChainId();
  const key =
    process.env.KEEPER_PRIVATE_KEY ??
    (chainId === 31337 ? ANVIL_KEEPER_KEY : undefined);
  if (!key) throw new Error("KEEPER_PRIVATE_KEY is required off chain 31337");
  const chain = defineChain({
    id: chainId,
    name: "local",
    nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
    rpcUrls: { default: { http: [RPC_URL] } },
  });
  const pub = createPublicClient({
    chain,
    transport: http(RPC_URL),
    pollingInterval: 100,
  });
  const wallet = createWalletClient({
    account: privateKeyToAccount(key as `0x${string}`),
    chain,
    transport: http(RPC_URL),
  });
  const call = async (circle: Address, functionName: "activate" | "settle") => {
    const hash = await wallet.writeContract({
      address: circle,
      abi: kuberCircleAbi,
      functionName,
      args: functionName === "settle" ? [maxUint256] : [],
      gas: GAS,
    } as never);
    const r = await pub.waitForTransactionReceipt({ hash });
    console.log(`keeper: ${functionName} ${circle} ${r.status}`);
  };

  console.log(
    `keeper: watching circles from ${factory} every ${INTERVAL_MS} ms`,
  );
  for (;;) {
    try {
      const now = (await pub.getBlock()).timestamp;
      const circles = await pub.readContract({
        address: factory,
        abi: kuberFactoryAbi,
        functionName: "allCircles",
      });
      for (const circle of circles) {
        const s = await pub.readContract({
          address: circle,
          abi: kuberCircleAbi,
          functionName: "getCircleState",
        });
        if (s.name.startsWith(PRACTICE_PREFIX)) continue;
        if (s.status === 0 && now >= s.fixedParams.startTime)
          await call(circle, "activate");
        else if (s.status === 1 && s.settledEpoch < s.currentEpoch - 1n)
          await call(circle, "settle");
      }
    } catch (e) {
      console.error(`keeper: ${firstLine(e)}`);
    }
    await new Promise((r) => setTimeout(r, INTERVAL_MS));
  }
};

main().catch((e) => {
  console.error(`keeper: ${firstLine(e)}`);
  process.exit(1);
});
