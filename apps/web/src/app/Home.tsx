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
    <li className="arrive">
      <button
        type="button"
        onClick={() => go({ name: "circle", address: c.address })}
        className="w-full rounded-2xl border border-line bg-surface p-4 text-left shadow-[0_10px_30px_var(--color-shadow)] transition-colors hover:border-brand active:scale-[0.98] motion-reduce:transform-none"
      >
        <span className="flex items-start justify-between gap-3">
          <span className="min-w-0 truncate font-display text-lg font-bold text-ink">
            {c.name}
          </span>
          <Chip
            tone={
              c.status === "Completed" || c.status === "Cancelled"
                ? "idle"
                : statusTone(c.status)
            }
          >
            {c.status === "Forming" ? "Starting soon" : c.status}
          </Chip>
        </span>
        <span className="num mt-2 block text-sm font-semibold text-ink">
          {formatAmount(c.contribution)} mUSDC{" "}
          <span className="font-normal text-ink-2">per round</span>
        </span>
        <span className="mt-1 block text-sm text-ink-2">{circleLine(c)}</span>
        {c.status === "Active" && c.totalRounds > 0 && (
          <span
            className="mt-3 block h-1.5 overflow-hidden rounded-full bg-brand-soft"
            aria-hidden="true"
          >
            <span
              className="block h-full rounded-full bg-brand"
              style={{
                width: `${Math.min(100, (c.round / c.totalRounds) * 100)}%`,
              }}
            />
          </span>
        )}
        {cta && (
          <span
            className={`mt-3 inline-flex min-h-11 items-center rounded-xl px-4 text-sm font-semibold ${cta === "Join" ? "bg-brand text-white" : "bg-brand-soft text-brand"}`}
          >
            {cta}
          </span>
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
        <section className="on-dark arrive mt-5 rounded-3xl border border-brand bg-brand-deep p-5 text-white shadow-[0_10px_30px_var(--color-shadow)] sm:p-7">
          <p className="flex items-center gap-2 text-sm font-semibold text-white/80">
            <Wallet aria-hidden className="size-4" /> Your wallet
          </p>
          <p className="num mt-3 font-display text-4xl font-bold tracking-tight sm:text-5xl">
            {formatAmount(me.musdc)}
            <span className="ml-1 text-base font-medium text-accent">
              {" "}
              mUSDC
            </span>
          </p>
          <p className="num mt-1 text-sm text-white/75">
            {formatAvax(me.avax)} AVAX for network fees
          </p>
          <div className="mt-6 grid gap-2 sm:grid-cols-2">
            <Button
              className="w-full !bg-accent !text-brand-deep hover:!bg-accent-soft active:scale-[0.98] motion-reduce:transform-none"
              onClick={() => go({ name: "create" })}
            >
              <Plus aria-hidden className="size-5" /> Create a circle
            </Button>
            <Button
              variant="secondary"
              className="w-full !border-white/60 !bg-transparent !text-white hover:!border-white hover:!bg-white/10 active:scale-[0.98] motion-reduce:transform-none"
              busy={faucet.busy}
              disabled={faucet.busy}
              onClick={addMoney}
            >
              Add test money
            </Button>
          </div>
          {faucet.note && (
            <p role="status" className="mt-3 text-sm font-semibold text-white">
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
          {mine.length > 0 && (
            <span className="num text-base font-medium text-ink-2">
              {" "}
              · {mine.length}
            </span>
          )}
        </h2>
        {circles === null && !error ? (
          <div
            className="mt-3 rounded-2xl border border-line bg-surface p-4 shadow-[0_10px_30px_var(--color-shadow)]"
            role="status"
          >
            <span className="sr-only">Loading your circles</span>
            <span className="block h-5 w-2/3 animate-pulse rounded bg-line/60 motion-reduce:animate-none" />
            <span className="mt-3 block h-4 w-1/2 animate-pulse rounded bg-line/60 motion-reduce:animate-none" />
            <span className="mt-2 block h-4 w-3/4 animate-pulse rounded bg-line/60 motion-reduce:animate-none" />
          </div>
        ) : mine.length === 0 ? (
          <div className="arrive mt-3 rounded-2xl border border-line bg-surface p-5 text-center shadow-[0_10px_30px_var(--color-shadow)]">
            <img
              src="/empty-circles.webp"
              width={720}
              height={480}
              alt=""
              aria-hidden="true"
              className="mx-auto h-40 w-auto rounded-xl object-contain"
            />
            <h3 className="mt-3 font-display text-lg font-bold text-ink">
              A circle starts with you
            </h3>
            <p className="mx-auto mt-1 max-w-md text-sm text-ink-2">
              You're not in a circle yet. Create one — pick{" "}
              <span className="whitespace-nowrap">2-minute rounds</span> to try
              it quickly — or join an open one below.
            </p>
          </div>
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
