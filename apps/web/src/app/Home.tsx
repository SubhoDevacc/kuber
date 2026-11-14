import { Plus, RefreshCw, Wallet } from "lucide-react";
import { useCallback, useEffect, useState } from "react";
import { Button, Chip, statusTone } from "../components/ui";
import { formatAmount } from "../lib/money";
import { type AppCircle, appApi } from "./appApi";
import { useApp } from "./ctx";
import { AppBar, type Go, Page } from "./Screens";

function circleLine(c: AppCircle) {
  if (c.status === "Completed") return `Ended after ${c.totalRounds} rounds`;
  if (c.status === "Cancelled") return "Called off";
  if (c.status === "Forming")
    return `Waiting to start · ${c.members} of ${c.maxMembers} joined`;
  return `Round ${c.round} of ${c.totalRounds} · ${c.members} members`;
}

function CircleRow({ c, go, cta }: { c: AppCircle; go: Go; cta?: string }) {
  return (
    <li>
      <button
        type="button"
        onClick={() => go({ name: "circle", address: c.address })}
        className="flex w-full items-center justify-between gap-3 rounded-2xl border border-line bg-surface p-4 text-left hover:border-brand"
      >
        <span className="min-w-0">
          <span className="block truncate font-display text-lg font-bold text-ink">
            {c.name}
          </span>
          <span className="mt-0.5 block text-sm text-ink-2">
            {formatAmount(c.contribution)} mUSDC a round · {circleLine(c)}
          </span>
        </span>
        {cta ? (
          <span className="shrink-0 rounded-xl bg-brand px-3 py-2 text-sm font-semibold text-white">
            {cta}
          </span>
        ) : (
          <Chip
            tone={
              c.status === "Completed" || c.status === "Cancelled"
                ? "idle"
                : statusTone(c.status)
            }
          >
            {c.status === "Forming" ? "Starting soon" : c.status}
          </Chip>
        )}
      </button>
    </li>
  );
}

export function HomePage({ go }: { go: Go }) {
  const { me, refreshMe } = useApp();
  const [circles, setCircles] = useState<AppCircle[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [faucet, setFaucet] = useState<{ busy: boolean; note: string | null }>({
    busy: false,
    note: null,
  });

  const load = useCallback(async () => {
    setError(null);
    try {
      const [list] = await Promise.all([appApi.circles(), refreshMe()]);
      setCircles(list);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Couldn't load circles.");
    }
  }, [refreshMe]);

  useEffect(() => {
    load();
    const id = setInterval(load, 15_000);
    return () => clearInterval(id);
  }, [load]);

  async function addMoney() {
    setFaucet({ busy: true, note: null });
    try {
      await appApi.faucet();
      await refreshMe();
      setFaucet({
        busy: false,
        note: "10,000 test mUSDC added to your wallet.",
      });
    } catch (err) {
      setFaucet({
        busy: false,
        note: err instanceof Error ? err.message : "Couldn't add test money.",
      });
    }
  }

  const mine = circles?.filter((c) => c.mine) ?? [];
  const invited = circles?.filter((c) => !c.mine && c.invited) ?? [];
  const open = circles?.filter((c) => !c.mine && !c.invited && c.canJoin) ?? [];

  return (
    <div className="min-h-dvh">
      <AppBar go={go} />
      <Page>
        <h1 className="font-display text-3xl font-bold tracking-tight text-ink">
          Hi, {me.name}
        </h1>
        <section className="mt-4 rounded-2xl border border-line bg-surface p-4">
          <p className="flex items-center gap-2 text-sm text-ink-2">
            <Wallet aria-hidden className="size-4" /> Your wallet
          </p>
          <p className="num mt-1 font-display text-3xl font-bold text-ink">
            {formatAmount(me.musdc)}
            <span className="text-base font-normal text-ink-2">
              {" "}
              test mUSDC
            </span>
          </p>
          <p className="num text-sm text-ink-2">
            {formatAvax(me.avax)} AVAX for network fees
          </p>
          <div className="mt-4 grid gap-2 sm:grid-cols-2">
            <Button onClick={() => go({ name: "create" })}>
              <Plus aria-hidden className="size-5" /> Create a circle
            </Button>
            <Button
              variant="secondary"
              busy={faucet.busy}
              disabled={faucet.busy}
              onClick={addMoney}
            >
              Add test money
            </Button>
          </div>
          {faucet.note && (
            <p role="status" className="mt-3 text-sm font-semibold text-ink">
              {faucet.note}
            </p>
          )}
        </section>

        {error && (
          <div role="alert" className="mt-4 rounded-2xl bg-bad-soft p-4">
            <p className="font-semibold text-ink">{error}</p>
            <Button variant="secondary" onClick={load} className="mt-3">
              <RefreshCw aria-hidden className="size-4" /> Try again
            </Button>
          </div>
        )}

        {invited.length > 0 && (
          <>
            <h2 className="mt-8 font-display text-xl font-bold text-ink">
              Invited
            </h2>
            <ul className="mt-3 grid gap-3">
              {invited.map((c) => (
                <CircleRow key={c.address} c={c} go={go} cta="Join" />
              ))}
            </ul>
          </>
        )}

        <h2 className="mt-8 font-display text-xl font-bold text-ink">
          Your circles
        </h2>
        {circles === null && !error ? (
          <div
            className="mt-3 h-20 animate-pulse rounded-2xl bg-line/60 motion-reduce:animate-none"
            role="status"
          >
            <span className="sr-only">Loading your circles</span>
          </div>
        ) : mine.length === 0 ? (
          <p className="mt-3 rounded-2xl border border-line bg-surface p-4 text-ink-2">
            You're not in a circle yet. Create one — pick 2-minute rounds to try
            it quickly — or join an open one below.
          </p>
        ) : (
          <ul className="mt-3 grid gap-3">
            {mine.map((c) => (
              <CircleRow key={c.address} c={c} go={go} />
            ))}
          </ul>
        )}

        {open.length > 0 && (
          <>
            <h2 className="mt-8 font-display text-xl font-bold text-ink">
              Open circles
            </h2>
            <ul className="mt-3 grid gap-3">
              {open.map((c) => (
                <CircleRow key={c.address} c={c} go={go} cta="View" />
              ))}
            </ul>
          </>
        )}
      </Page>
    </div>
  );
}

/** AVAX amounts from the server: wei strings (18 decimals) → "0.0500". */
export function formatAvax(wei: string): string {
  try {
    const v = BigInt(wei || "0");
    const whole = v / 10n ** 18n;
    const frac = ((v % 10n ** 18n) / 10n ** 14n).toString().padStart(4, "0");
    return `${whole}.${frac}`;
  } catch {
    return wei;
  }
}
