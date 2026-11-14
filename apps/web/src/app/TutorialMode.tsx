// Tutorial mode inside the real app: the first run (no way out but to finish), the "What next?" screen after it,
// the "Tutorial mode" switch in the top bar, and "What do you want to try?" (one chapter at a time, fast-forwarded).
import { CirclePlus, GraduationCap, Users } from "lucide-react";
import { createContext, useContext, useEffect, useState } from "react";
import { Button, Wordmark } from "../components/ui";
import { api, setApiAddress } from "../lib/api";
import { ApiError } from "../lib/errors";
import { addressOf, createKey, sendAction } from "../lib/wallet";
import { Finish } from "../pages/Finish";
import { Tutorial } from "../pages/Tutorial";
import type { Hex, TutorialState } from "../types";

// ---------- the switch in the top bar ----------

export type TutorialSwitch = {
  /** Turn tutorial mode on (opens "What do you want to try?"). */
  enter: () => void;
  /** Show the one-time tip under the switch. */
  tip: boolean;
  dismissTip: () => void;
};

export const TutorialSwitchCtx = createContext<TutorialSwitch | null>(null);

/** "Tutorial mode" as a real switch. Off in the app; on inside the tutorial (where turning it off leaves). */
export function TutorialToggle({
  on = false,
  onChange,
  dark = false,
}: {
  on?: boolean;
  onChange?: () => void;
  dark?: boolean;
}) {
  const ctx = useContext(TutorialSwitchCtx);
  const change = onChange ?? ctx?.enter;
  if (!change) return null;
  const tip = !on && ctx?.tip;
  return (
    <div className="relative">
      <button
        type="button"
        role="switch"
        aria-checked={on}
        aria-describedby={tip ? "tutorial-tip" : undefined}
        onClick={change}
        className={`inline-flex min-h-11 items-center gap-2 rounded-xl px-2 text-sm font-semibold ${dark ? "text-white" : "text-ink"} ${tip ? "ring-2 ring-accent ring-offset-2 ring-offset-surface motion-safe:animate-pulse" : ""}`}
      >
        <span
          aria-hidden
          className={`relative inline-flex h-6 w-10 shrink-0 items-center rounded-full transition-colors motion-reduce:transition-none ${on ? "bg-accent" : dark ? "bg-white/30" : "bg-line"}`}
        >
          <span
            className={`absolute size-5 rounded-full bg-surface shadow-[0_1px_3px_var(--color-shadow)] transition-transform motion-reduce:transition-none ${on ? "translate-x-[1.1rem]" : "translate-x-0.5"}`}
          />
        </span>
        Tutorial mode
      </button>
    </div>
  );
}

/**
 * The one-time tip, as a slim row under the top bar (it pushes the page down instead of covering it).
 * Shown once, the first time the app opens after the tutorial; "Got it" hides it for good.
 */
export function TutorialTip() {
  const ctx = useContext(TutorialSwitchCtx);
  if (!ctx?.tip) return null;
  return (
    <div
      id="tutorial-tip"
      role="status"
      className="border-t border-line bg-accent-soft"
    >
      <div className="mx-auto flex max-w-3xl items-center gap-3 px-4 py-2">
        <p className="flex-1 text-sm text-ink">
          Want to try a feature again with test money? Turn on Tutorial mode any
          time.
        </p>
        <Button
          variant="secondary"
          className="min-h-11 shrink-0 px-3 text-sm"
          onClick={ctx.dismissTip}
        >
          Got it
        </Button>
      </div>
    </div>
  );
}

const tipKey = (a: string) => `kuber:tutorialTipShown:${a.toLowerCase()}`;
export function tipShown(address: string): boolean {
  try {
    return localStorage.getItem(tipKey(address)) === "1";
  } catch {
    return true;
  }
}
export function markTipShown(address: string) {
  try {
    localStorage.setItem(tipKey(address), "1");
  } catch {
    // private mode: the tip may show again
  }
}

// ---------- "What next?" after the first run ----------

export function WhatNext({
  onCreate,
  onJoin,
  onHome,
}: {
  onCreate: () => void;
  onJoin: () => void;
  onHome: () => void;
}) {
  return (
    <div className="mx-auto flex min-h-dvh max-w-xl flex-col px-4 py-5 sm:px-6">
      <Wordmark />
      <main className="flex flex-1 flex-col justify-center gap-4 py-8">
        <h1 className="font-display text-3xl font-bold tracking-tight text-ink">
          What next?
        </h1>
        <p className="text-base text-ink-2">
          You're ready for a real circle, with test money on Avalanche Fuji.
        </p>
        <button
          type="button"
          onClick={onCreate}
          className="flex min-h-20 items-center gap-4 rounded-2xl bg-brand p-4 text-left text-white shadow-[0_10px_30px_var(--color-shadow)]"
        >
          <CirclePlus aria-hidden className="size-8 shrink-0 text-accent" />
          <span>
            <span className="block text-lg font-bold">Create your circle</span>
            <span className="block text-sm text-white/85">
              Pick the saving per round and invite people. Practice members can
              fill the empty seats.
            </span>
          </span>
        </button>
        <button
          type="button"
          onClick={onJoin}
          className="flex min-h-20 items-center gap-4 rounded-2xl border border-line bg-surface p-4 text-left text-ink"
        >
          <Users aria-hidden className="size-8 shrink-0 text-brand" />
          <span>
            <span className="block text-lg font-bold">Join a circle</span>
            <span className="block text-sm text-ink-2">
              See circles you're invited to and open ones you can ask to join.
            </span>
          </span>
        </button>
        <Button variant="quiet" onClick={onHome} className="self-center">
          Go to Home
        </Button>
      </main>
    </div>
  );
}

// ---------- the practice tutorial ----------

const keyFor = (a: string) => `kuber:practiceKeyFor:${a.toLowerCase()}`;
/** One practice wallet per signed-in wallet, so "Continue where I left off" can find the run. */
function practiceKey(owner: string): Hex {
  try {
    const kept = localStorage.getItem(keyFor(owner));
    if (kept && /^0x[0-9a-fA-F]{64}$/.test(kept)) return kept as Hex;
  } catch {
    // private mode
  }
  const k = createKey();
  try {
    localStorage.setItem(keyFor(owner), k);
  } catch {
    // private mode: a new practice wallet next time
  }
  return k;
}

const LINES = [
  "Join a circle and save each round.",
  "Ask for a loan with a friend backing you.",
  "Pay the loan back, a part each round.",
  "Pick a fund manager and vote on a rule.",
  "See who pays when a member stops paying.",
  "The circle ends and everyone collects.",
];

/** The step a chapter starts at on the "join" path, from the server's step list (`tutorial.ts`). */
const STEP_CHAPTER: Record<string, number> = {
  start: 1,
  create: 1,
  approve: 1,
  join: 1,
  begin: 1,
  round1: 1,
  round2: 1,
  prepay: 2,
  request: 2,
  approve2: 2,
  claim: 2,
  repay1: 3,
  repay2: 3,
  manager: 4,
  vote: 4,
  default: 5,
  withdraw: 6,
  finished: 6,
};
const JOIN_PATH = [
  "start",
  "approve",
  "join",
  "round1",
  "round2",
  "prepay",
  "request",
  "approve2",
  "claim",
  "repay1",
  "repay2",
  "manager",
  "vote",
  "default",
  "withdraw",
  "finished",
];
const stepsBefore = (chapter: number) =>
  JOIN_PATH.filter((id) => STEP_CHAPTER[id] < chapter).length;

type Mode =
  | { name: "loading" }
  | { name: "error"; message: string }
  | { name: "pick"; t: TutorialState }
  | { name: "forward"; done: number; total: number; chapter: string }
  | { name: "run"; t: TutorialState; note?: string };

/**
 * The tutorial on the practice chain with a practice wallet made silently and the same name (the tutorial's own
 * sign-up step is skipped). First run: straight in, no way out but to finish. Later: "What do you want to try?".
 */
export function PracticeTutorial({
  owner,
  name,
  firstRun,
  onLeave,
  onFinish,
}: {
  owner: Hex;
  name: string;
  firstRun: boolean;
  onLeave?: () => void;
  onFinish: () => void;
}) {
  const [key] = useState<Hex>(() => practiceKey(owner));
  const [mode, setMode] = useState<Mode>({ name: "loading" });
  const [finished, setFinished] = useState<TutorialState | null>(null);
  const [tries, setTries] = useState(0);

  // biome-ignore lint/correctness/useExhaustiveDependencies: retry re-runs it
  useEffect(() => {
    let live = true;
    setMode({ name: "loading" });
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
      const t = me.tutorial ?? (await api.start());
      if (!live) return;
      setMode(firstRun ? { name: "run", t } : { name: "pick", t });
    })().catch((err) => {
      if (live)
        setMode({
          name: "error",
          message:
            err instanceof Error ? err.message : "Couldn't open the tutorial.",
        });
    });
    return () => {
      live = false;
    };
  }, [tries]);

  /** A fresh practice circle, then the steps before `chapter` played with the practice wallet. */
  async function fastForward(chapter: number) {
    const title = mode.name === "pick" ? mode.t.chapters[chapter - 1] : "";
    const total = stepsBefore(chapter);
    setMode({ name: "forward", done: 0, total, chapter: title });
    let t: TutorialState;
    try {
      t = await api.reset();
    } catch (err) {
      setMode({
        name: "error",
        message:
          err instanceof Error
            ? err.message
            : "Couldn't set up a fresh practice circle.",
      });
      return;
    }
    let done = 0;
    while (!t.done && t.chapter < chapter) {
      const step = t.step;
      try {
        if (step.options?.length) t = await api.next(step.id, "join");
        else {
          if (step.action) await sendAction(key, t.circle, step.action);
          t = await api.next(step.id);
        }
      } catch (err) {
        setMode({
          name: "run",
          t,
          note: `We stopped at "${step.title}": ${err instanceof Error ? err.message : "something went wrong"}. Carry on from here by hand.`,
        });
        return;
      }
      done += 1;
      setMode({
        name: "forward",
        done,
        total: Math.max(total, done),
        chapter: title,
      });
    }
    setMode({ name: "run", t });
  }

  if (finished) return <Finish t={finished} onEnter={onFinish} />;
  if (mode.name === "error")
    return (
      <div className="mx-auto flex min-h-dvh max-w-md flex-col justify-center gap-4 px-4">
        <Wordmark />
        <p role="alert" className="text-lg font-semibold text-ink">
          {mode.message}
        </p>
        <Button onClick={() => setTries((n) => n + 1)}>Try again</Button>
        {onLeave && (
          <Button variant="secondary" onClick={onLeave}>
            Leave tutorial
          </Button>
        )}
      </div>
    );
  if (mode.name === "loading")
    return (
      <div className="grid min-h-dvh place-items-center" role="status">
        <p className="text-ink-2">Setting up your practice circle…</p>
      </div>
    );
  if (mode.name === "forward")
    return (
      <div className="mx-auto flex min-h-dvh max-w-md flex-col justify-center gap-4 px-4">
        <Wordmark />
        <h1 className="font-display text-2xl font-bold text-ink">
          {mode.chapter}
        </h1>
        <p className="text-base text-ink" role="status" aria-live="polite">
          Getting the practice circle ready… step {mode.done + 1} of{" "}
          {Math.max(mode.total, mode.done + 1)}
        </p>
        <div
          className="h-2 overflow-hidden rounded-full bg-line"
          role="progressbar"
          aria-label="Getting the practice circle ready"
          aria-valuemin={0}
          aria-valuemax={mode.total}
          aria-valuenow={mode.done}
        >
          <div
            className="h-full bg-brand transition-[width] duration-500 motion-reduce:transition-none"
            style={{
              width: `${mode.total ? (mode.done / mode.total) * 100 : 100}%`,
            }}
          />
        </div>
        <p className="text-sm text-ink-2">
          The earlier steps are played for you with your practice wallet: real
          transactions on the practice chain.
        </p>
      </div>
    );
  if (mode.name === "pick") {
    const t = mode.t;
    const inProgress = !t.done && t.stepIndex > 0;
    return (
      <div className="min-h-dvh">
        <div className="on-dark sticky top-0 z-30 bg-brand-deep text-white">
          <div className="mx-auto flex max-w-3xl items-center justify-between gap-3 px-4">
            <p className="py-2 text-sm text-white/85">
              Practice with test money
            </p>
            {onLeave && <TutorialToggle on dark onChange={onLeave} />}
          </div>
        </div>
        <main className="mx-auto grid max-w-xl gap-3 px-4 py-6">
          <h1 className="font-display text-3xl font-bold tracking-tight text-ink">
            What do you want to try?
          </h1>
          <p className="text-base text-ink-2">
            Each choice starts a fresh practice circle with test money. Earlier
            steps are played for you.
          </p>
          {inProgress && (
            <Button onClick={() => setMode({ name: "run", t })}>
              Continue where I left off
            </Button>
          )}
          <ul className="grid gap-2">
            {t.chapters.map((title, i) => (
              <li key={title}>
                <button
                  type="button"
                  onClick={() =>
                    i === 0
                      ? api
                          .reset()
                          .then((fresh) => setMode({ name: "run", t: fresh }))
                          .catch((err) =>
                            setMode({
                              name: "error",
                              message:
                                err instanceof Error
                                  ? err.message
                                  : "Couldn't start the tutorial.",
                            }),
                          )
                      : fastForward(i + 1)
                  }
                  className="flex min-h-16 w-full items-center gap-3 rounded-xl border border-line bg-surface p-3 text-left hover:border-brand"
                >
                  <span className="grid size-9 shrink-0 place-items-center rounded-full bg-brand-soft font-display font-bold text-brand">
                    {i + 1}
                  </span>
                  <span>
                    <span className="block font-semibold text-ink">
                      {title}
                    </span>
                    <span className="block text-sm text-ink-2">
                      {LINES[i] ?? ""}
                    </span>
                  </span>
                </button>
              </li>
            ))}
          </ul>
          <Button
            variant="secondary"
            onClick={() =>
              (t.stepIndex === 0 && !t.done ? Promise.resolve(t) : api.reset())
                .then((fresh) => setMode({ name: "run", t: fresh }))
                .catch((err) =>
                  setMode({
                    name: "error",
                    message:
                      err instanceof Error
                        ? err.message
                        : "Couldn't start the tutorial.",
                  }),
                )
            }
          >
            <GraduationCap aria-hidden className="size-5" /> Start from the
            beginning
          </Button>
        </main>
      </div>
    );
  }
  const t = mode.t;
  if (t.done) return <Finish t={t} onEnter={onFinish} />;
  return (
    <>
      {mode.note && (
        <p
          role="alert"
          className="bg-warn-soft px-4 py-2 text-sm font-semibold text-ink"
        >
          {mode.note}
        </p>
      )}
      <Tutorial
        key={t.circle}
        initial={t}
        privateKey={key}
        onLeave={onLeave}
        onDone={setFinished}
      />
    </>
  );
}
