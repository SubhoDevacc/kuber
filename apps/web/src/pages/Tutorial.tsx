import { ChevronDown, CircleAlert, LoaderCircle } from "lucide-react";
import { useEffect, useLayoutEffect, useRef, useState } from "react";
import { ChangeCard } from "../components/ChangeCard";
import { CircleView } from "../components/CircleView";
import { Button } from "../components/ui";
import { ApiError, api } from "../lib/api";
import { PlainError, sendAction, shortHash } from "../lib/wallet";
import type { Hex, TutorialState } from "../types";

type Phase = "idle" | "sending" | "server";

const WIDE = "(min-width: 1024px)";
function useWide() {
  const [wide, setWide] = useState(() => matchMedia(WIDE).matches);
  useEffect(() => {
    const mq = matchMedia(WIDE);
    const on = () => setWide(mq.matches);
    mq.addEventListener("change", on);
    return () => mq.removeEventListener("change", on);
  }, []);
  return wide;
}

function ChapterProgress({ t }: { t: TutorialState }) {
  return (
    <nav aria-label="Tutorial chapters">
      <ol className="grid grid-cols-6 gap-1.5">
        {t.chapters.map((title, i) => {
          const n = i + 1;
          const state =
            t.done || n < t.chapter
              ? "done"
              : n === t.chapter
                ? "now"
                : "later";
          return (
            <li
              key={title}
              aria-current={state === "now" ? "step" : undefined}
              className="min-w-0"
            >
              <span
                aria-hidden
                className={`block h-1.5 rounded-full transition-colors duration-500 ${state === "done" ? "bg-brand" : state === "now" ? "bg-accent" : "bg-line"}`}
              />
              <span
                className={`mt-2 hidden text-xs leading-tight lg:block ${state === "now" ? "font-semibold text-ink" : "text-ink-2"}`}
              >
                {title}
              </span>
              <span className="sr-only">
                Chapter {n}: {title},{" "}
                {state === "done"
                  ? "done"
                  : state === "now"
                    ? "current"
                    : "not started"}
              </span>
            </li>
          );
        })}
      </ol>
      <p className="mt-2 text-sm text-ink lg:hidden" aria-hidden>
        <span className="font-semibold">
          Chapter {t.chapter} of {t.chapters.length}:
        </span>{" "}
        {t.chapters[t.chapter - 1]}
      </p>
    </nav>
  );
}

export function Tutorial({
  initial,
  privateKey,
  onSkip,
  onDone,
}: {
  initial: TutorialState;
  privateKey: Hex;
  onSkip: () => void;
  onDone: (t: TutorialState) => void;
}) {
  const [t, setT] = useState(initial);
  const [phase, setPhase] = useState<Phase>("idle");
  const [error, setError] = useState<{
    message: string;
    afterTx: boolean;
  } | null>(null);
  const [sentFor, setSentFor] = useState<string | null>(null);
  const [tx, setTx] = useState<string | null>(null);
  const [lastTx, setLastTx] = useState<string | null>(null);
  const [announce, setAnnounce] = useState("");
  const panel = useRef<HTMLDivElement>(null);
  const [panelHeight, setPanelHeight] = useState(0);
  const firstStep = useRef(true);
  const wide = useWide();
  // On a phone the change card gets the panel to itself first; "Next step" moves on to the step.
  const [seenFor, setSeenFor] = useState<string | null>(null);
  const hasChange = t.lastChange !== null && t.stepIndex > 0;
  const reviewing = hasChange && !wide && seenFor !== t.step.id;

  useLayoutEffect(() => {
    const el = panel.current;
    if (!el) return;
    const ro = new ResizeObserver(() => setPanelHeight(el.offsetHeight));
    ro.observe(el);
    return () => ro.disconnect();
  }, []);

  // A new step (or the step after the change card): move keyboard focus to it, not on first load.
  // biome-ignore lint/correctness/useExhaustiveDependencies: runs per step
  useEffect(() => {
    if (firstStep.current) {
      firstStep.current = false;
      return;
    }
    panel.current
      ?.querySelector<HTMLElement>("[data-focus]")
      ?.focus({ preventScroll: true });
    panel.current?.scrollTo({ top: 0 });
  }, [t.step.id, reviewing]);

  function accept(next: TutorialState, doneTx: string | null) {
    setLastTx(doneTx);
    setTx(null);
    setSentFor(null);
    setT(next);
    setAnnounce(
      `${next.lastChange ? `What just changed: ${next.lastChange.title}. ` : ""}${next.done ? "The tutorial is complete." : `Next: ${next.step.title}`}`,
    );
    if (next.done) onDone(next);
  }

  async function go(resend = false) {
    setError(null);
    const step = t.step;
    let sent = false;
    let doneTx = sentFor === step.id ? tx : null;
    try {
      if (step.action && (resend || sentFor !== step.id)) {
        setPhase("sending");
        setAnnounce("Sending from your practice wallet.");
        try {
          const hash = await sendAction(privateKey, t.circle, step.action);
          doneTx = shortHash(hash);
          setTx(doneTx);
          setSentFor(step.id);
          sent = true;
          setAnnounce(
            `Done. Transaction ${shortHash(hash)}. ${step.waitNote ?? ""}`,
          );
        } catch (err) {
          // The action may already be done (for example after a reload); ask the server before giving up.
          setPhase("server");
          try {
            accept(await api.next(step.id), null);
            return;
          } catch {
            throw err;
          }
        }
      } else if (step.waitNote) {
        setAnnounce(step.waitNote);
      }
      setPhase("server");
      accept(await api.next(step.id), doneTx);
    } catch (err) {
      console.error(err);
      const message =
        err instanceof ApiError || err instanceof PlainError
          ? err.message
          : "Something went wrong. Try again.";
      setError({ message, afterTx: sent || sentFor === step.id });
    } finally {
      setPhase("idle");
    }
  }

  const step = t.step;
  const busy = phase !== "idle";
  const label = error
    ? "Try again"
    : step.action
      ? sentFor === step.id
        ? "Continue"
        : step.action.label
      : "Continue";

  return (
    <div className="min-h-dvh">
      <div className="on-dark sticky top-0 z-30 bg-brand-deep text-white">
        <div className="mx-auto flex max-w-6xl items-center justify-between gap-3 px-4">
          <p className="py-2 text-sm">
            <span className="font-bold">Tutorial mode</span>
            <span className="text-white/85"> with test money</span>
          </p>
          <button
            type="button"
            onClick={onSkip}
            className="min-h-11 px-1 text-sm font-semibold text-white underline underline-offset-4"
          >
            Skip tutorial
          </button>
        </div>
      </div>

      <div className="mx-auto max-w-6xl px-4 pt-4 lg:grid lg:grid-cols-[minmax(0,1fr)_400px] xl:grid-cols-[minmax(0,1fr)_460px] lg:gap-6 lg:pt-6">
        <main>
          <div className="mb-4 rounded-2xl border border-line bg-surface p-4">
            <ChapterProgress t={t} />
          </div>
          <CircleView c={t.snapshot} />
          <div
            aria-hidden
            className="lg:hidden"
            style={{ height: panelHeight + 16 }}
          />
          <div aria-hidden className="hidden h-8 lg:block" />
        </main>

        <aside
          ref={panel}
          aria-label="Guide"
          className="fixed inset-x-0 bottom-0 z-20 max-h-[60dvh] overflow-y-auto rounded-t-3xl border-t border-line bg-surface shadow-[0_-8px_30px_rgba(16,48,42,0.14)] lg:sticky lg:top-[60px] lg:flex lg:max-h-[calc(100dvh-76px)] lg:flex-col lg:self-start lg:overflow-hidden lg:rounded-3xl lg:border lg:shadow-none"
        >
          {/* Wide: only the change card scrolls (fading out at its edge); the step text and button always show in full. */}
          <div className="grid gap-4 p-4 pb-0 sm:p-5 sm:pb-0 lg:flex lg:min-h-0 lg:flex-col">
            {t.lastChange && (reviewing || (hasChange && wide)) && (
              <div
                key={t.step.id}
                className="lg:-mb-4 lg:min-h-0 lg:overflow-y-auto lg:pb-4 lg:[mask-image:linear-gradient(to_bottom,black_calc(100%_-_1rem),transparent)]"
              >
                <ChangeCard change={t.lastChange} tx={lastTx} />
              </div>
            )}
            {t.lastChange && hasChange && !wide && !reviewing && (
              <button
                type="button"
                onClick={() => setSeenFor(null)}
                className="flex min-h-11 items-center justify-between gap-2 rounded-xl border border-accent bg-accent-soft px-3 text-left text-sm"
              >
                <span className="min-w-0 truncate">
                  <span className="font-semibold text-warn">
                    What just changed:{" "}
                  </span>
                  {t.lastChange.title}
                </span>
                <ChevronDown
                  aria-hidden
                  className="size-4 shrink-0 text-ink-2"
                />
              </button>
            )}
            <div hidden={reviewing} className="lg:shrink-0">
              <p className="text-xs font-semibold text-brand">
                Step {t.stepIndex + 1} of {t.stepCount}
              </p>
              <h2
                tabIndex={-1}
                data-focus={reviewing ? undefined : ""}
                className="mt-0.5 font-display text-xl font-bold leading-snug text-ink focus:outline-none"
              >
                {step.title}
              </h2>
              <p className="mt-1 text-[0.9875rem] leading-normal text-ink sm:text-base sm:leading-relaxed">
                {step.body}
              </p>
            </div>
          </div>

          <div className="sticky bottom-0 grid gap-3 bg-surface p-4 pb-[max(1rem,env(safe-area-inset-bottom))] sm:p-5 lg:shrink-0">
            {busy && (
              <div className="flex items-start gap-3 rounded-xl bg-brand-soft p-3 text-sm text-ink">
                <LoaderCircle
                  aria-hidden
                  className="spin mt-0.5 size-5 shrink-0 text-brand"
                />
                <div>
                  {phase === "sending" ? (
                    <p className="font-semibold">
                      Sending from your practice wallet…
                    </p>
                  ) : (
                    <>
                      {tx && (
                        <p className="text-ink-2">Done. Transaction {tx}</p>
                      )}
                      <p className="font-semibold">
                        {step.waitNote ?? "One moment…"}
                      </p>
                      {step.waitNote && (
                        <p className="text-ink-2">
                          This can take a few seconds.
                        </p>
                      )}
                    </>
                  )}
                </div>
              </div>
            )}
            {error && !busy && (
              <div
                role="alert"
                className="flex items-start gap-3 rounded-xl bg-bad-soft p-3 text-sm text-ink"
              >
                <CircleAlert
                  aria-hidden
                  className="mt-0.5 size-5 shrink-0 text-bad"
                />
                <div>
                  <p className="font-semibold">{error.message}</p>
                  {error.afterTx && step.action && (
                    <button
                      type="button"
                      onClick={() => go(true)}
                      className="mt-1 min-h-11 font-semibold text-brand underline underline-offset-4"
                    >
                      Send “{step.action.label}” again
                    </button>
                  )}
                </div>
              </div>
            )}
            {reviewing ? (
              <Button onClick={() => setSeenFor(t.step.id)} className="w-full">
                Next step
              </Button>
            ) : (
              <Button
                onClick={() => go()}
                disabled={busy}
                busy={busy}
                className="w-full"
              >
                {busy ? (phase === "sending" ? "Sending…" : "Working…") : label}
              </Button>
            )}
            {!reviewing &&
              step.action &&
              !busy &&
              sentFor !== step.id &&
              !error && (
                <p className="text-center text-xs text-ink-2">
                  Signed by your practice wallet. Uses test money only.
                </p>
              )}
          </div>
          <p aria-live="polite" className="sr-only">
            {announce}
          </p>
        </aside>
      </div>
    </div>
  );
}
