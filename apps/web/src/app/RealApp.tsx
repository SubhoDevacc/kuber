import { PrivyProvider, usePrivy, useWallets } from "@privy-io/react-auth";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { createWalletClient, custom, getAddress, http } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { avalancheFuji } from "viem/chains";
import { Button, Wordmark } from "../components/ui";
import { ApiError } from "../lib/errors";
import type { Hex } from "../types";
import {
  type AppHealth,
  type AppMe,
  appApi,
  forgetSession,
  startSession,
} from "./appApi";
import { plainReason, readClient, type Signer } from "./chain";
import { type AppChain, appChain, DEV_KEY, PRIVY_APP_ID } from "./config";
import { type AppCtx, Ctx } from "./ctx";
import { Screens } from "./Screens";

function accent(): `#${string}` | undefined {
  try {
    const v = getComputedStyle(document.documentElement)
      .getPropertyValue("--color-brand")
      .trim();
    return /^#[0-9a-fA-F]{3,8}$/.test(v) ? (v as `#${string}`) : undefined;
  } catch {
    return undefined;
  }
}

/** The real app on Fuji. Mounted only when the server says it is set up, so the tutorial never loads Privy. */
export default function RealApp({
  health,
  onExit,
}: {
  health: AppHealth;
  onExit: () => void;
}) {
  const chain = useMemo(() => appChain(health), [health]);
  if (DEV_KEY) return <DevWallet chain={chain} onExit={onExit} />;
  return (
    <PrivyProvider
      appId={PRIVY_APP_ID}
      config={{
        embeddedWallets: {
          ethereum: { createOnLogin: "all-users" },
          showWalletUIs: false,
        },
        defaultChain: avalancheFuji,
        supportedChains: [avalancheFuji],
        appearance: { theme: "light", accentColor: accent() },
      }}
    >
      <PrivyWallet chain={chain} onExit={onExit} />
    </PrivyProvider>
  );
}

function DevWallet({ chain, onExit }: { chain: AppChain; onExit: () => void }) {
  const signer = useMemo<Signer>(() => {
    const account = privateKeyToAccount(DEV_KEY as Hex);
    const wallet = createWalletClient({
      account,
      chain: chain.chain,
      transport: http(chain.rpc),
    });
    return {
      address: account.address,
      wallet,
      signMessage: (message) => account.signMessage({ message }),
    };
  }, [chain]);
  return (
    <Session
      chain={chain}
      signer={signer}
      privyToken={async () => null}
      onSignOut={() => {
        forgetSession();
        onExit();
      }}
    />
  );
}

function Centered({ children }: { children: React.ReactNode }) {
  return (
    <div className="mx-auto flex min-h-dvh max-w-md flex-col justify-center gap-4 px-4">
      <Wordmark />
      {children}
    </div>
  );
}

function PrivyWallet({
  chain,
  onExit,
}: {
  chain: AppChain;
  onExit: () => void;
}) {
  const { ready, authenticated, login, logout, getAccessToken } = usePrivy();
  const { wallets } = useWallets();
  const embedded = wallets.find((w) => w.walletClientType === "privy");
  const [signer, setSigner] = useState<Signer | null>(null);
  const [error, setError] = useState<string | null>(null);
  const asked = useRef(false);

  // Arriving from "Sign in": open Privy's login straight away, once.
  useEffect(() => {
    if (ready && !authenticated && !asked.current) {
      asked.current = true;
      login();
    }
  }, [ready, authenticated, login]);

  // biome-ignore lint/correctness/useExhaustiveDependencies: rebuild only when the wallet changes
  useEffect(() => {
    if (!embedded) return setSigner(null);
    let live = true;
    (async () => {
      await embedded.switchChain(chain.chain.id);
      const provider = await embedded.getEthereumProvider();
      const address = getAddress(embedded.address);
      const wallet = createWalletClient({
        account: address,
        chain: chain.chain,
        transport: custom(provider),
      });
      if (live)
        setSigner({
          address,
          wallet,
          signMessage: (message) =>
            wallet.signMessage({ account: address, message }),
        });
    })().catch((err) => {
      console.error(err);
      if (live) setError("Couldn't open your wallet. Try again.");
    });
    return () => {
      live = false;
    };
  }, [embedded?.address, chain]);

  const signOut = useCallback(async () => {
    forgetSession();
    await logout().catch(() => {});
    onExit();
  }, [logout, onExit]);

  if (!ready)
    return (
      <Centered>
        <p role="status" className="text-ink-2">
          Loading…
        </p>
      </Centered>
    );
  if (!authenticated)
    return (
      <Centered>
        <div className="arrive mt-4 rounded-3xl border border-line bg-surface p-5 shadow-[0_10px_30px_var(--color-shadow)] sm:p-7">
          <h1 className="font-display text-3xl font-bold tracking-tight text-ink">
            Sign in to Kuber
          </h1>
          <p className="mt-3 text-base leading-relaxed text-ink-2">
            Sign in with your email to get your own wallet. It holds test money
            only.
          </p>
          <div className="mt-6 grid gap-3">
            <Button onClick={() => login()}>Sign in</Button>
            <Button variant="secondary" onClick={onExit}>
              Back
            </Button>
          </div>
        </div>
      </Centered>
    );
  if (error)
    return (
      <Centered>
        <p role="alert" className="text-lg font-semibold text-ink">
          {error}
        </p>
        <Button onClick={() => location.reload()}>Try again</Button>
        <Button variant="secondary" onClick={signOut}>
          Sign out
        </Button>
      </Centered>
    );
  if (!signer)
    return (
      <Centered>
        <p role="status" className="text-ink-2">
          Setting up your wallet…
        </p>
      </Centered>
    );
  return (
    <Session
      chain={chain}
      signer={signer}
      privyToken={getAccessToken}
      onSignOut={signOut}
    />
  );
}

function Session({
  chain,
  signer,
  privyToken,
  onSignOut,
}: {
  chain: AppChain;
  signer: Signer;
  privyToken: () => Promise<string | null>;
  onSignOut: () => void;
}) {
  const [me, setMe] = useState<AppMe | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [tries, setTries] = useState(0);
  const reader = useMemo(() => readClient(chain), [chain]);

  // biome-ignore lint/correctness/useExhaustiveDependencies: retry re-runs it
  useEffect(() => {
    let live = true;
    setError(null);
    (async () => {
      await startSession(
        signer.address,
        signer.signMessage,
        await privyToken().catch(() => null),
      );
      const m = await appApi.me();
      if (live) setMe(m);
    })().catch((err) => {
      console.error(err);
      if (live)
        setError(err instanceof ApiError ? err.message : plainReason(err));
    });
    return () => {
      live = false;
    };
  }, [signer, tries]);

  const refreshMe = useCallback(async () => {
    setMe(await appApi.me());
  }, []);

  const ctx = useMemo<AppCtx | null>(
    () =>
      me && {
        chain,
        reader,
        signer,
        me,
        refreshMe,
        txChain: (extra = {}, circle) => {
          const labels: Record<string, string> = {
            [chain.usdc.toLowerCase()]: "Test money (mUSDC)",
            [chain.factory.toLowerCase()]: "Circle factory",
            [chain.registry.toLowerCase()]: "Kuber member list",
            [signer.address.toLowerCase()]: me.name
              ? `${me.name} (you)`
              : "You",
          };
          for (const [a, n] of Object.entries(extra))
            labels[a.toLowerCase()] ??= n;
          if (circle) labels[circle.toLowerCase()] = "This circle";
          return { client: reader, explorer: chain.explorer, labels };
        },
      },
    [chain, reader, signer, me, refreshMe],
  );

  if (error)
    return (
      <Centered>
        <p role="alert" className="text-lg font-semibold text-ink">
          {error}
        </p>
        <Button onClick={() => setTries((n) => n + 1)}>Try again</Button>
        <Button variant="secondary" onClick={onSignOut}>
          Sign out
        </Button>
      </Centered>
    );
  if (!ctx)
    return (
      <Centered>
        <p role="status" className="text-ink-2">
          Signing you in…
        </p>
      </Centered>
    );
  return (
    <Ctx.Provider value={ctx}>
      <Screens onSignOut={onSignOut} />
    </Ctx.Provider>
  );
}
