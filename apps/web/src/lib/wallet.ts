import { kuberCircleAbi, mockUsdcAbi } from "@kuber/shared";
import {
  type Abi,
  BaseError,
  ContractFunctionRevertedError,
  createPublicClient,
  createWalletClient,
  defineChain,
  http,
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

const chain = defineChain({
  id: 31337,
  name: "Kuber practice chain",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: ["/rpc"] } },
});

let usdcAddress: Hex | null = null;
async function usdc(): Promise<Hex> {
  if (usdcAddress) return usdcAddress;
  const res = await fetch("/api/health").catch(() => null);
  const body = (await res?.json().catch(() => null)) as { usdc?: Hex } | null;
  if (!body?.usdc)
    throw new PlainError(
      "Can't find the test money contract. Check the Kuber server is running.",
    );
  usdcAddress = body.usdc;
  return usdcAddress;
}

/** An error whose message is already fit to show. */
export class PlainError extends Error {}

/** Sends the step's transaction from the practice wallet and waits for it to land. Returns the hash. */
export async function sendAction(
  key: Hex,
  circle: Hex,
  action: Action,
): Promise<Hex> {
  if (MOCK) {
    await new Promise((r) => setTimeout(r, 900));
    mockNoteTx();
    const rand = crypto.getRandomValues(new Uint8Array(32));
    return `0x${[...rand].map((b) => b.toString(16).padStart(2, "0")).join("")}`;
  }
  const abi = (action.target === "usdc" ? mockUsdcAbi : kuberCircleAbi) as Abi;
  const address = action.target === "usdc" ? await usdc() : circle;
  const account = privateKeyToAccount(key);
  // The hosted server routes /rpc to this wallet's own chain by this header; the Vite proxy ignores it.
  const transport = http(new URL("/rpc", location.origin).toString(), {
    fetchOptions: {
      headers: { authorization: `Bearer dev:${account.address}` },
    },
  });
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
    const receipt = await reader.waitForTransactionReceipt({ hash });
    if (receipt.status !== "success") {
      throw new PlainError(
        "That didn't go through. Nothing was taken from your wallet.",
      );
    }
    return hash;
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
