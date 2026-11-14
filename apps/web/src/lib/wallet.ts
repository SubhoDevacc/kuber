import { kuberCircleAbi, kuberFactoryAbi, mockUsdcAbi } from "@kuber/shared";
import {
  type Abi,
  BaseError,
  ContractFunctionRevertedError,
  createPublicClient,
  createWalletClient,
  defineChain,
  http,
  type PublicClient,
} from "viem";
import { generatePrivateKey, privateKeyToAccount } from "viem/accounts";
import type { Action, Hex } from "../types";
import { toArgs } from "./args";
import { MOCK, mockNoteTx } from "./mock";

const KEY = "kuber.practiceKey";

export function getKey(): Hex | null {
  try {
    return (localStorage.getItem(KEY) as Hex | null) ?? null;
  } catch {
    return null;
  }
}

export function createKey(): Hex {
  const key = getKey() ?? generatePrivateKey();
  localStorage.setItem(KEY, key);
  return key;
}

export const addressOf = (key: Hex) => privateKeyToAccount(key).address;

const practiceChain = (id = 31337) =>
  defineChain({
    id,
    name: "Kuber practice chain",
    nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
    rpcUrls: { default: { http: ["/rpc"] } },
  });
const chain = practiceChain();

type Health = { usdc?: Hex; factory?: Hex; chainId?: number };
let health: Health | null = null;
/** The practice chain's contract addresses, from the tutorial server's `/health`. */
export async function practiceContracts(): Promise<Health> {
  if (health?.usdc) return health;
  const res = await fetch("/api/health").catch(() => null);
  health = ((await res?.json().catch(() => null)) as Health | null) ?? {};
  return health;
}
async function contract(target: Action["target"]): Promise<Hex> {
  const h = await practiceContracts();
  const a = target === "factory" ? h.factory : h.usdc;
  if (!a)
    throw new PlainError(
      "Can't find that contract. Check the Kuber server is running.",
    );
  return a;
}

/** Reads the practice chain through /rpc (the hosted server routes it by this wallet's header). */
export function practiceReader(address: Hex): PublicClient {
  return createPublicClient({
    chain,
    transport: http(new URL("/rpc", location.origin).toString(), {
      fetchOptions: { headers: { authorization: `Bearer dev:${address}` } },
    }),
  });
}

/** An error whose message is already fit to show. */
export class PlainError extends Error {}

/**
 * Sends the step's transaction from the practice wallet and waits for it to land. `onSent` fires with the hash
 * as soon as it is broadcast; the result carries the block it was confirmed in.
 */
export async function sendAction(
  key: Hex,
  circle: Hex,
  action: Action,
  onSent?: (hash: Hex) => void,
): Promise<{ hash: Hex; block: bigint }> {
  if (MOCK) {
    await new Promise((r) => setTimeout(r, 900));
    mockNoteTx();
    const rand = crypto.getRandomValues(new Uint8Array(32));
    const hash: Hex = `0x${[...rand].map((b) => b.toString(16).padStart(2, "0")).join("")}`;
    return { hash, block: 0n };
  }
  const abi = (
    action.target === "usdc"
      ? mockUsdcAbi
      : action.target === "factory"
        ? kuberFactoryAbi
        : kuberCircleAbi
  ) as Abi;
  const address =
    action.target === "circle" ? circle : await contract(action.target);
  const account = privateKeyToAccount(key);
  // The hosted server routes /rpc to this wallet's own chain by this header; the Vite proxy ignores it.
  const transport = http(new URL("/rpc", location.origin).toString(), {
    fetchOptions: {
      headers: { authorization: `Bearer dev:${account.address}` },
    },
  });
  // 31337 everywhere today; a test server on another chain id says so in /health.
  const chain = practiceChain((await practiceContracts()).chainId);
  const wallet = createWalletClient({ account, chain, transport });
  const reader = createPublicClient({ chain, transport });
  try {
    const hash = await wallet.writeContract({
      address,
      abi,
      functionName: action.functionName,
      args: toArgs(abi, action.functionName, action.args),
      chain,
      account,
    });
    onSent?.(hash);
    const receipt = await reader.waitForTransactionReceipt({ hash });
    if (receipt.status !== "success") {
      throw new PlainError(
        "That didn't go through. Nothing was taken from your wallet.",
      );
    }
    return { hash, block: receipt.blockNumber };
  } catch (err) {
    console.error(err);
    if (err instanceof PlainError) throw err;
    if (err instanceof BaseError) {
      const revert = err.walk(
        (e) => e instanceof ContractFunctionRevertedError,
      );
      if (revert) {
        throw new PlainError(
          "The circle turned this down right now, so nothing changed. Try again in a moment.",
        );
      }
      if (/fetch|network|HTTP request failed/i.test(err.message)) {
        throw new PlainError(
          "Can't reach the practice chain. Check it's running, then try again.",
        );
      }
    }
    throw new PlainError("That didn't go through. Nothing changed. Try again.");
  }
}

export const shortHash = (hash: string) =>
  `${hash.slice(0, 6)}…${hash.slice(-4)}`;
