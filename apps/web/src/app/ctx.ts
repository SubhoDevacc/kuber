import { createContext, useContext } from "react";
import type { PublicClient } from "viem";
import type { Hex } from "../types";
import type { AppMe } from "./appApi";
import type { Signer } from "./chain";
import type { AppChain } from "./config";
import type { TxChain } from "./TxDetails";

export type AppCtx = {
  chain: AppChain;
  reader: PublicClient;
  signer: Signer;
  me: AppMe;
  refreshMe: () => Promise<void>;
  /** Names for the details pop-up: contracts plus whoever the screen knows. */
  txChain: (extra?: Record<string, string>, circle?: Hex) => TxChain;
};

export const Ctx = createContext<AppCtx | null>(null);

export function useApp(): AppCtx {
  const c = useContext(Ctx);
  if (!c) throw new Error("useApp outside the real app");
  return c;
}
