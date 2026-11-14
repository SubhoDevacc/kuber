import type { Deployment } from "@kuber/shared";
import { type Chain, defineChain } from "viem";
import { avalancheFuji } from "viem/chains";
import fuji from "../../../../deployments/fuji.json";
import type { Hex } from "../types";

/** Public by design (Privy App ID). Empty = no sign-in; the app is the tutorial only. */
export const PRIVY_APP_ID: string = import.meta.env.VITE_PRIVY_APP_ID ?? "";

/**
 * Dev-only: a private key that stands in for the Privy wallet so the real app can be walked headless.
 * Ignored in production builds (`import.meta.env.DEV` is false there, so this is dead code).
 */
export const DEV_KEY: Hex | null =
  import.meta.env.DEV &&
  /^0x[0-9a-fA-F]{64}$/.test(import.meta.env.VITE_APP_DEV_KEY ?? "")
    ? (import.meta.env.VITE_APP_DEV_KEY as Hex)
    : null;

/** Where the browser reads and sends real-app transactions. Default: the public Fuji RPC. */
const RPC_URL: string =
  import.meta.env.VITE_APP_RPC_URL || avalancheFuji.rpcUrls.default.http[0];

export type AppChain = {
  chain: Chain;
  rpc: string;
  explorer: string | null;
  usdc: Hex;
  factory: Hex;
  registry: Hex;
};

const FUJI = fuji as Deployment;

/**
 * The real app runs on Fuji with the addresses in `deployments/fuji.json`. A server pointed at another chain
 * (a local Anvil standing in for Fuji) says so in `/api/app/health`, and its addresses win.
 */
export function appChain(health: {
  chainId?: number;
  usdc?: Hex;
  factory?: Hex;
  registry?: Hex;
}): AppChain {
  const id = health.chainId ?? FUJI.chainId;
  const isFuji = id === avalancheFuji.id;
  const chain = isFuji
    ? avalancheFuji
    : defineChain({
        id,
        name: "Kuber test chain",
        nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
        rpcUrls: { default: { http: [RPC_URL] } },
      });
  return {
    chain,
    rpc: RPC_URL,
    explorer: isFuji ? "https://testnet.snowtrace.io" : null,
    usdc: health.usdc ?? FUJI.usdc,
    factory: health.factory ?? FUJI.factory,
    registry: health.registry ?? FUJI.registry,
  };
}
