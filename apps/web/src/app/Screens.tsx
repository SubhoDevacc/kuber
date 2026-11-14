import { ChevronLeft, CircleCheck, Menu as MenuIcon } from "lucide-react";
import { type ReactNode, useEffect, useState } from "react";
import { isAddress } from "viem";
import { Button, Wordmark } from "../components/ui";
import { ApiError } from "../lib/errors";
import { formatAmount } from "../lib/money";
import { markTutorialDone, tutorialDone } from "../lib/tutorialDone";
import type { Hex } from "../types";
import { appApi } from "./appApi";
import { CirclePage } from "./Circle";
import { CreatePage } from "./Create";
import { useApp } from "./ctx";
import { HomePage } from "./Home";
import { MenuPage } from "./Menu";
import {
  markTipShown,
  PracticeTutorial,
  TutorialSwitchCtx,
  TutorialTip,
  TutorialToggle,
  tipShown,
  WhatNext,
} from "./TutorialMode";

export type Go = (v: View) => void;
export type View =
  | { name: "home" }
  | { name: "create" }
  | { name: "circle"; address: Hex }
  | { name: "menu" }
  | { name: "tutorial"; from?: View }
  | { name: "whatnext" }
  | { name: "join" };

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
        <div className="flex items-center gap-1">
          <TutorialToggle />
          <button
            type="button"
            onClick={() => go({ name: "menu" })}
            className="inline-flex min-h-11 items-center gap-2 rounded-xl border border-line px-3 font-semibold text-ink"
          >
            <MenuIcon aria-hidden className="size-5" />
            Menu
          </button>
        </div>
      </div>
      <TutorialTip />
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
  // A new person finishes the tutorial once before the app opens; remembered per wallet (or said by the server).
  const [done, setDone] = useState(
    () => tutorialDone(me.address) || me.tutorialDone === true,
  );
  // The "Tutorial mode" switch is highlighted once, the first time the app opens after the tutorial.
  const [tip, setTip] = useState(() => !tipShown(me.address));

  // biome-ignore lint/correctness/useExhaustiveDependencies: scroll to top on each new screen
  useEffect(() => {
    window.scrollTo({ top: 0 });
  }, [view.name, onboarding]);

  // "Join a circle" lands on Home at the Invited / Open circles list (Home renders them as headings).
  useEffect(() => {
    if (view.name !== "join") return;
    let n = 0;
    const id = setInterval(() => {
      const h = [...document.querySelectorAll("main h2")].find((e) =>
        /^(Invited|Open circles)/.test(e.textContent?.trim() ?? ""),
      );
      if (h || ++n > 20) {
        clearInterval(id);
        h?.scrollIntoView({ block: "start" });
      }
    }, 150);
    return () => clearInterval(id);
  }, [view.name]);

  const home = () => setView({ name: "home" });
  if (onboarding)
    return (
      <Onboard
        onTutorial={() => {
          setOnboarding(false);
          setView({ name: "tutorial" });
        }}
        onHome={
          done
            ? () => {
                setOnboarding(false);
                home();
              }
            : undefined
        }
      />
    );
  // Before the first finish every screen is the tutorial (a shared circle link opens after it).
  if (!done || view.name === "tutorial") {
    const back: View =
      view.name === "tutorial" && view.from ? view.from : { name: "home" };
    return (
      <PracticeTutorial
        owner={me.address}
        name={me.name ?? "Saver"}
        firstRun={!done}
        onLeave={done ? () => setView(back) : undefined}
        onFinish={() => {
          markTutorialDone(me.address);
          setDone(true);
          if (!done) setView({ name: "whatnext" });
          else setView(back);
        }}
      />
    );
  }
  const screen = (() => {
    switch (view.name) {
      case "whatnext":
        return (
          <WhatNext
            onCreate={() => setView({ name: "create" })}
            onJoin={() => setView({ name: "join" })}
            onHome={home}
          />
        );
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
  })();
  return (
    <TutorialSwitchCtx.Provider
      value={{
        enter: () => {
          setTip(false);
          markTipShown(me.address);
          setView({ name: "tutorial", from: view });
        },
        tip: tip && view.name !== "whatnext",
        dismissTip: () => {
          setTip(false);
          markTipShown(me.address);
        },
      }}
    >
      {screen}
    </TutorialSwitchCtx.Provider>
  );
}

const NAME = /^[A-Za-z0-9 -]{3,24}$/;

/** First visit: a display name, "Verify me (test only)", then test money and gas arrive in the wallet. */
function Onboard({
  onTutorial,
  onHome,
}: {
  onTutorial: () => void;
  /** Only once the tutorial was finished on this wallet (or the dev-only escape). */
  onHome?: () => void;
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
        <div className="mt-2 flex gap-2" aria-hidden="true">
          <span className="h-1.5 w-12 rounded-full bg-brand" />
          <span
            className={`h-1.5 w-12 rounded-full ${step > 1 ? "bg-brand" : "bg-line"}`}
          />
        </div>
        {step === 1 && (
          <form onSubmit={next} noValidate>
            <h1 className="mt-5 font-display text-3xl font-bold tracking-tight text-ink">
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
              name="nickname"
              value={name}
              onChange={(e) => setName(e.target.value)}
              autoComplete="nickname"
              spellCheck={false}
              placeholder="Asha K…"
              maxLength={24}
              aria-invalid={nameError ? true : undefined}
              aria-describedby="app-name-hint"
              className="mt-2 block min-h-12 w-full rounded-xl border border-line bg-surface px-4 text-base text-ink focus:border-brand focus:ring-2 focus:ring-brand/30 aria-invalid:border-bad"
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
            <h1 className="mt-5 font-display text-3xl font-bold tracking-tight text-ink">
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
            <span className="mt-5 grid size-14 place-items-center rounded-2xl bg-accent text-brand-deep">
              <CircleCheck aria-hidden className="size-8" />
            </span>
            <h1
              className="mt-3 font-display text-3xl font-bold tracking-tight text-ink"
              aria-live="polite"
            >
              {formatAmount(result.musdc, 0)} test mUSDC in your wallet
            </h1>
            <p className="mt-2 text-base leading-relaxed text-ink">
              You're verified, {name}. Your wallet also has a little AVAX to pay
              network fees. Next, a short tutorial on a practice circle.
              {onHome ? "" : " Finish it once to open the app."}
            </p>
            <div className="mt-6 grid gap-3">
              <Button onClick={onTutorial}>Start the tutorial</Button>
              {onHome && (
                <Button variant="secondary" onClick={onHome}>
                  Open the app
                </Button>
              )}
            </div>
          </div>
        )}
      </main>
    </div>
  );
}
