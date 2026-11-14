import { CircleCheck } from "lucide-react";
import { useRef, useState } from "react";
import { Button, Wordmark } from "../components/ui";
import { api } from "../lib/api";
import { formatAmount } from "../lib/money";
import type { Onboarded, TutorialState } from "../types";

const NAME = /^[A-Za-z0-9 -]{3,24}$/;

export function SignUp({ onReady }: { onReady: (t: TutorialState) => void }) {
  const [step, setStep] = useState<1 | 2 | 3>(1);
  const [name, setName] = useState("");
  const [nameError, setNameError] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [grant, setGrant] = useState<Onboarded["grant"] | null>(null);
  const tutorial = useRef<Promise<TutorialState> | null>(null);

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
      const me = await api.onboard(name);
      setGrant(me.grant);
      setStep(3);
      // Set up the practice circle while the person reads the message.
      tutorial.current = api.start();
      tutorial.current.catch(() => {});
    } catch (err) {
      setError(
        err instanceof Error ? err.message : "Something went wrong. Try again.",
      );
    } finally {
      setBusy(false);
    }
  }

  async function begin() {
    setBusy(true);
    setError(null);
    try {
      onReady(await (tutorial.current ?? api.start()));
    } catch (err) {
      tutorial.current = null;
      setError(
        err instanceof Error ? err.message : "Something went wrong. Try again.",
      );
      setBusy(false);
    }
  }

  return (
    <div className="mx-auto flex min-h-dvh max-w-xl flex-col px-4 py-5 sm:px-6">
      <Wordmark />
      <main className="app-card my-auto rounded-[2rem] border border-line bg-surface p-6 sm:p-8">
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
            <label htmlFor="name" className="mt-6 block font-semibold text-ink">
              Display name
            </label>
            <input
              id="name"
              value={name}
              onChange={(e) => setName(e.target.value)}
              autoComplete="nickname"
              maxLength={24}
              aria-invalid={nameError ? true : undefined}
              aria-describedby="name-hint"
              className="mt-2 block min-h-12 w-full rounded-xl border border-line bg-surface px-4 text-base text-ink outline-none focus:border-brand focus:ring-2 focus:ring-brand/30 aria-invalid:border-bad"
            />
            <p
              id="name-hint"
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
              account. In this practice version you only press the button.
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
              Verify me (test only — no real ID needed)
            </Button>
          </div>
        )}
        {step === 3 && grant && (
          <div>
            <CircleCheck aria-hidden className="mt-2 size-12 text-good" />
            <h1
              className="mt-3 font-display text-3xl font-bold tracking-tight text-ink"
              aria-live="polite"
            >
              {grant.sent
                ? `${formatAmount(grant.musdc, 0)} test mUSDC added to your wallet`
                : "Your wallet already has its test mUSDC"}
            </h1>
            <p className="mt-2 text-base leading-relaxed text-ink">
              You're verified, {name}. Next, a short tutorial on a practice
              circle with five practice members. Every step is a real
              transaction with test money.
            </p>
            {error && (
              <p
                role="alert"
                className="mt-4 rounded-xl bg-bad-soft p-3 text-sm font-semibold text-bad"
              >
                {error}
              </p>
            )}
            <Button
              onClick={begin}
              busy={busy}
              disabled={busy}
              className="mt-6 w-full"
            >
              {busy ? "Setting up your practice circle…" : "Start the tutorial"}
            </Button>
          </div>
        )}
      </main>
    </div>
  );
}
