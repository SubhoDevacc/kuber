import { ChevronLeft, Menu } from "lucide-react";
import { DropdownMenu } from "radix-ui";
import { useEffect, useState } from "react";
import { CircleView } from "../components/CircleView";
import {
  Button,
  Chip,
  PracticeTag,
  statusTone,
  Wordmark,
} from "../components/ui";
import { api } from "../lib/api";
import { formatAmount } from "../lib/money";
import type { CircleSnapshot, CircleSummary, Me } from "../types";

function AppHeader({
  onTutorial,
  onRestart,
  onSignIn,
}: {
  onTutorial: () => void;
  onRestart: () => void;
  onSignIn?: () => void;
}) {
  const item =
    "flex min-h-11 cursor-pointer items-center rounded-lg px-3 text-base text-ink outline-none data-[highlighted]:bg-brand-soft";
  return (
    <header className="border-b border-line bg-surface">
      <div className="mx-auto flex max-w-4xl items-center justify-between px-4 py-2">
        <Wordmark />
        <DropdownMenu.Root>
          <DropdownMenu.Trigger asChild>
            <button
              type="button"
              className="inline-flex min-h-11 items-center gap-2 rounded-xl border border-line px-3 font-semibold text-ink"
            >
              <Menu aria-hidden className="size-5" />
              Menu
            </button>
          </DropdownMenu.Trigger>
          <DropdownMenu.Portal>
            <DropdownMenu.Content
              align="end"
              sideOffset={6}
              className="z-50 min-w-56 rounded-xl border border-line bg-surface p-1.5 shadow-[0_10px_30px_var(--color-shadow)]"
            >
              <DropdownMenu.Item className={item} onSelect={onTutorial}>
                Tutorial mode
              </DropdownMenu.Item>
              <DropdownMenu.Item className={item} onSelect={onRestart}>
                Restart tutorial
              </DropdownMenu.Item>
              {onSignIn && (
                <DropdownMenu.Item className={item} onSelect={onSignIn}>
                  Sign in to the real app
                </DropdownMenu.Item>
              )}
            </DropdownMenu.Content>
          </DropdownMenu.Portal>
        </DropdownMenu.Root>
      </div>
    </header>
  );
}

function Failed({ message, retry }: { message: string; retry: () => void }) {
  return (
    <div role="alert" className="rounded-2xl bg-bad-soft p-4">
      <p className="font-semibold text-ink">{message}</p>
      <Button variant="secondary" onClick={retry} className="mt-3">
        Try again
      </Button>
    </div>
  );
}

export function Home({
  onOpen,
  onTutorial,
  onRestart,
  onSignIn,
  busyNote,
}: {
  onOpen: (address: string) => void;
  onTutorial: () => void;
  onRestart: () => void;
  onSignIn?: () => void;
  busyNote: string | null;
}) {
  const [circles, setCircles] = useState<CircleSummary[] | null>(null);
  const [me, setMe] = useState<Me | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [tries, setTries] = useState(0);

  // biome-ignore lint/correctness/useExhaustiveDependencies: refetch on retry
  useEffect(() => {
    setError(null);
    Promise.all([api.circles(), api.me()])
      .then(([list, who]) => {
        setCircles(list);
        setMe(who);
      })
      .catch((err: Error) => setError(err.message));
  }, [tries]);

  return (
    <div className="min-h-dvh">
      <AppHeader
        onTutorial={onTutorial}
        onRestart={onRestart}
        onSignIn={onSignIn}
      />
      <main className="mx-auto max-w-4xl px-4 py-6">
        {busyNote && (
          <p
            role="status"
            className="mb-4 rounded-xl bg-brand-soft p-3 text-sm font-semibold text-ink"
          >
            {busyNote}
          </p>
        )}
        <h1 className="font-display text-3xl font-bold tracking-tight text-ink">
          {me?.name ? `Hi, ${me.name}` : "Welcome back"}
        </h1>
        {me && (
          <p className="mt-1 text-base text-ink-2">
            Practice wallet:{" "}
            <span className="num font-semibold text-ink">
              {formatAmount(me.musdc)}
            </span>{" "}
            test mUSDC
          </p>
        )}
        <h2 className="mt-8 font-display text-xl font-bold text-ink">
          Circles
        </h2>
        <div className="mt-3">
          {error ? (
            <Failed message={error} retry={() => setTries((n) => n + 1)} />
          ) : circles === null ? (
            <div
              className="h-24 animate-pulse rounded-2xl bg-line/60 motion-reduce:animate-none"
              role="status"
            >
              <span className="sr-only">Loading your circles</span>
            </div>
          ) : circles.length === 0 ? (
            <p className="rounded-2xl border border-line bg-surface p-4 text-ink-2">
              You're not in any circles yet. Open the menu and choose Tutorial
              mode to try a practice circle.
            </p>
          ) : (
            <ul className="grid gap-3">
              {circles.map((c) => (
                <li key={c.address}>
                  <button
                    type="button"
                    onClick={() => onOpen(c.address)}
                    className="flex w-full items-center justify-between gap-3 rounded-2xl border border-line bg-surface p-4 text-left hover:border-brand"
                  >
                    <span className="min-w-0">
                      <span className="flex flex-wrap items-center gap-2">
                        <span className="font-display text-lg font-bold text-ink">
                          {c.name}
                        </span>
                        {c.practice && <PracticeTag />}
                      </span>
                      <span className="mt-0.5 block text-sm text-ink-2">
                        {c.status === "Completed"
                          ? `Ended after ${c.totalRounds} rounds`
                          : c.status === "Forming"
                            ? "Waiting to start"
                            : `Round ${c.round} of ${c.totalRounds}`}
                        , {c.members} members
                      </span>
                    </span>
                    <Chip
                      tone={
                        c.status === "Completed" ? "idle" : statusTone(c.status)
                      }
                    >
                      {c.status}
                    </Chip>
                  </button>
                </li>
              ))}
            </ul>
          )}
        </div>
        <p className="mt-8 text-sm text-ink-2">
          Creating circles is coming next.
        </p>
      </main>
    </div>
  );
}

export function CirclePage({
  address,
  onBack,
}: {
  address: string;
  onBack: () => void;
}) {
  const [c, setC] = useState<CircleSnapshot | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [tries, setTries] = useState(0);

  // biome-ignore lint/correctness/useExhaustiveDependencies: refetch on retry
  useEffect(() => {
    setError(null);
    api
      .circle(address)
      .then(setC)
      .catch((err: Error) => setError(err.message));
  }, [address, tries]);

  return (
    <div className="min-h-dvh">
      <header className="border-b border-line bg-surface">
        <div className="mx-auto flex max-w-4xl items-center px-2 py-2">
          <button
            type="button"
            onClick={onBack}
            className="inline-flex min-h-11 items-center gap-1 rounded-xl px-2 font-semibold text-brand"
          >
            <ChevronLeft aria-hidden className="size-5" />
            Circles
          </button>
        </div>
      </header>
      <main className="mx-auto max-w-4xl px-4 py-6">
        {error ? (
          <Failed message={error} retry={() => setTries((n) => n + 1)} />
        ) : c ? (
          <CircleView c={c} />
        ) : (
          <div
            className="h-64 animate-pulse rounded-2xl bg-line/60 motion-reduce:animate-none"
            role="status"
          >
            <span className="sr-only">Loading the circle</span>
          </div>
        )}
      </main>
    </div>
  );
}
