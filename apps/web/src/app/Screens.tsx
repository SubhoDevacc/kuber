import { ChevronLeft, CircleCheck, Menu as MenuIcon } from "lucide-react";
import { type ReactNode, useEffect, useState } from "react";
import { isAddress } from "viem";
import { Button, Wordmark } from "../components/ui";
import { api, setApiAddress } from "../lib/api";
import { ApiError } from "../lib/errors";
import { formatAmount } from "../lib/money";
import { addressOf, createKey } from "../lib/wallet";
import { Finish } from "../pages/Finish";
import { Tutorial } from "../pages/Tutorial";
import type { Hex, TutorialState } from "../types";
import { appApi } from "./appApi";
import { CirclePage } from "./Circle";
import { CreatePage } from "./Create";
import { useApp } from "./ctx";
import { HomePage } from "./Home";
import { MenuPage } from "./Menu";

export type Go = (v: View) => void;
export type View =
  | { name: "home" }
  | { name: "create" }
  | { name: "circle"; address: Hex }
  | { name: "menu" }
  | { name: "tutorial" };

/** Shared top bar: back (or the wordmark) on the left, Menu on the right. */
export function AppBar({
  back,
  go,
  title,
}: {
  back?: () => void;
  go: Go;
  title?: string;
}) {
  return (
    <header className="sticky top-0 z-30 border-b border-line bg-surface/95 backdrop-blur">
      <div className="mx-auto flex max-w-3xl items-center justify-between gap-2 px-2 py-2 sm:px-4">
        {back ? (
          <button
            type="button"
            onClick={back}
            className="inline-flex min-h-11 items-center gap-1 rounded-xl px-2 font-semibold text-brand"
          >
            <ChevronLeft aria-hidden className="size-5" />
            {title ?? "Home"}
          </button>
        ) : (
          <span className="px-2">
            <Wordmark />
          </span>
        )}
        <button
          type="button"
          onClick={() => go({ name: "menu" })}
          className="inline-flex min-h-11 items-center gap-2 rounded-xl border border-line px-3 font-semibold text-ink"
        >
          <MenuIcon aria-hidden className="size-5" />
          Menu
        </button>
      </div>
    </header>
  );
}

export function Page({ children }: { children: ReactNode }) {
  return (
    <main className="mx-auto max-w-3xl px-4 pt-5 pb-[max(2rem,env(safe-area-inset-bottom))]">
      {children}
    </main>
  );
}

function startView(): View {
  try {
    const c = new URLSearchParams(location.search).get("circle");
    if (c && isAddress(c)) return { name: "circle", address: c };
  } catch {
    // no URL
  }
  return { name: "home" };
}

export function Screens({ onSignOut }: { onSignOut: () => void }) {
  const { me } = useApp();
  const [onboarding, setOnboarding] = useState(!me.name || !me.verified);
  const [view, setView] = useState<View>(startView);

  // biome-ignore lint/correctness/useExhaustiveDependencies: scroll to top on each new screen
  useEffect(() => {
    window.scrollTo({ top: 0 });
  }, [view.name, onboarding]);

  const home = () => setView({ name: "home" });
  if (onboarding)
    return (
      <Onboard
        onTutorial={() => {
          setOnboarding(false);
          setView({ name: "tutorial" });
        }}
        onHome={() => {
          setOnboarding(false);
          home();
        }}
      />
    );
  switch (view.name) {
    case "tutorial":
      return <PracticeTutorial name={me.name ?? "Saver"} onHome={home} />;
    case "create":
      return <CreatePage go={setView} />;
    case "circle":
      return (
        <CirclePage key={view.address} address={view.address} go={setView} />
      );
    case "menu":
      return <MenuPage go={setView} onSignOut={onSignOut} />;
    default:
      return <HomePage go={setView} />;
  }
}

const NAME = /^[A-Za-z0-9 -]{3,24}$/;

/** First visit: a display name, "Verify me (test only)", then test money and gas arrive in the wallet. */
function Onboard({
  onTutorial,
  onHome,
}: {
  onTutorial: () => void;
  onHome: () => void;
}) {
  const { refreshMe } = useApp();
  const [step, setStep] = useState<1 | 2 | 3>(1);
  const [name, setName] = useState("");
  const [nameError, setNameError] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [result, setResult] = useState<{ musdc: string; avax: string } | null>(
    null,
  );

  function next(e: React.FormEvent) {
    e.preventDefault();
    const clean = name.trim();
    if (!NAME.test(clean)) {
      setNameError("Use 3 to 24 letters, numbers, spaces or dashes.");
      return;
    }
    setName(clean);
    setNameError(null);
    setStep(2);
  }

  async function verify() {
    setBusy(true);
    setError(null);
    try {
      const me = await appApi.onboard(name);
      setResult({ musdc: me.musdc, avax: me.avax });
      setStep(3);
      await refreshMe();
    } catch (err) {
      setError(
        err instanceof ApiError
          ? err.message
          : "Something went wrong. Try again.",
      );
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="mx-auto flex min-h-dvh max-w-xl flex-col px-4 py-5 sm:px-6">
      <Wordmark />
      <main className="flex flex-1 flex-col justify-center py-8">
        <p className="text-sm font-semibold text-brand">
          {step < 3 ? `Step ${step} of 2` : "All set"}
        </p>
        {step === 1 && (
          <form onSubmit={next} noValidate>
            <h1 className="mt-1 font-display text-3xl font-bold tracking-tight text-ink">
              Choose a display name
            </h1>
            <p className="mt-2 text-base text-ink-2">
              Other members of your circles see this name.
            </p>
            <label
              htmlFor="app-name"
              className="mt-6 block font-semibold text-ink"
            >
              Display name
            </label>
            <input
              id="app-name"
              value={name}
              onChange={(e) => setName(e.target.value)}
              autoComplete="nickname"
              maxLength={24}
              aria-invalid={nameError ? true : undefined}
              aria-describedby="app-name-hint"
              className="mt-2 block min-h-12 w-full rounded-xl border border-line bg-surface px-4 text-base text-ink outline-none focus:border-brand focus:ring-2 focus:ring-brand/30 aria-invalid:border-bad"
            />
            <p
              id="app-name-hint"
              className={`mt-2 text-sm ${nameError ? "font-semibold text-bad" : "text-ink-2"}`}
            >
              {nameError ?? "3 to 24 letters, numbers, spaces or dashes."}
            </p>
            <Button type="submit" className="mt-6 w-full">
              Continue
            </Button>
          </form>
        )}
        {step === 2 && (
          <div>
            <h1 className="mt-1 font-display text-3xl font-bold tracking-tight text-ink">
              Verify it's you
            </h1>
            <p className="mt-2 text-base leading-relaxed text-ink">
              Real circles check each member's ID so every person has one
              account. On this test network you only press the button. You get
              20,000 test mUSDC and a little AVAX for network fees.
            </p>
            <div className="mt-5 rounded-xl border border-line bg-surface p-4 text-sm">
              <p className="text-ink-2">Your display name</p>
              <p className="mt-0.5 flex items-center justify-between gap-3 text-base font-semibold text-ink">
                {name}
                <button
                  type="button"
                  onClick={() => {
                    setError(null);
                    setStep(1);
                  }}
                  className="min-h-11 px-1 text-sm font-semibold text-brand underline underline-offset-4"
                >
                  Change
                </button>
              </p>
            </div>
            {error && (
              <p
                role="alert"
                className="mt-4 rounded-xl bg-bad-soft p-3 text-sm font-semibold text-bad"
              >
                {error}
              </p>
            )}
            <Button
              onClick={verify}
              busy={busy}
              disabled={busy}
              className="mt-6 w-full"
            >
              {busy
                ? "Verifying and sending your test money…"
                : "Verify me (test only — no real ID needed)"}
            </Button>
          </div>
        )}
        {step === 3 && result && (
          <div>
            <CircleCheck aria-hidden className="mt-2 size-12 text-good" />
            <h1
              className="mt-3 font-display text-3xl font-bold tracking-tight text-ink"
              aria-live="polite"
            >
              {formatAmount(result.musdc, 0)} test mUSDC in your wallet
            </h1>
            <p className="mt-2 text-base leading-relaxed text-ink">
              You're verified, {name}. Your wallet also has a little AVAX to pay
              network fees. Next, a short tutorial on a practice circle — or
              skip it and start using Kuber.
            </p>
            <div className="mt-6 grid gap-3">
              <Button onClick={onTutorial}>Start the tutorial</Button>
              <Button variant="secondary" onClick={onHome}>
                Skip tutorial
              </Button>
            </div>
          </div>
        )}
      </main>
    </div>
  );
}

/**
 * The tutorial as it is today, on the practice chain, with a practice wallet made silently and the same name
 * (the tutorial's own sign-up step is skipped). Skip and finish both lead to the real app's Home.
 */
function PracticeTutorial({
  name,
  onHome,
}: {
  name: string;
  onHome: () => void;
}) {
  const [key] = useState<Hex>(createKey);
  const [t, setT] = useState<TutorialState | null>(null);
  const [finished, setFinished] = useState<TutorialState | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [tries, setTries] = useState(0);

  // biome-ignore lint/correctness/useExhaustiveDependencies: retry re-runs it
  useEffect(() => {
    let live = true;
    setError(null);
    setApiAddress(addressOf(key));
    (async () => {
      let me = await api.me();
      if (!me.name || !me.verified) {
        try {
          me = await api.onboard(name);
        } catch (err) {
          // Names are unique on the practice server; add a short tag if this one is taken there.
          if (!(err instanceof ApiError) || err.status !== 409) throw err;
          const tag = String(Math.floor(1000 + Math.random() * 9000));
          me = await api.onboard(`${name.slice(0, 19)}-${tag}`);
        }
      }
      const state = me.tutorial ?? (await api.start());
      if (live) setT(state);
    })().catch((err) => {
      if (live)
        setError(
          err instanceof Error ? err.message : "Couldn't open the tutorial.",
        );
    });
    return () => {
      live = false;
    };
  }, [tries]);

  if (finished) return <Finish t={finished} onEnter={onHome} />;
  if (error)
    return (
      <div className="mx-auto flex min-h-dvh max-w-md flex-col justify-center gap-4 px-4">
        <Wordmark />
        <p role="alert" className="text-lg font-semibold text-ink">
          {error}
        </p>
        <Button onClick={() => setTries((n) => n + 1)}>Try again</Button>
        <Button variant="secondary" onClick={onHome}>
          Skip tutorial
        </Button>
      </div>
    );
  if (!t)
    return (
      <div className="grid min-h-dvh place-items-center" role="status">
        <p className="text-ink-2">Setting up your practice circle…</p>
      </div>
    );
  if (t.done) return <Finish t={t} onEnter={onHome} />;
  return (
    <Tutorial
      key={t.circle}
      initial={t}
      privateKey={key}
      onSkip={onHome}
      onDone={setFinished}
    />
  );
}
