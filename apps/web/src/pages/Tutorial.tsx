import {
  ChevronDown,
  ChevronUp,
  CircleAlert,
  History,
  LoaderCircle,
} from "lucide-react";
import { Dialog } from "radix-ui";
import { useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { ActivityList } from "../app/Activity";
import type { ActivityItem } from "../app/appApi";
import { type TxChain, TxHash } from "../app/TxDetails";
import { ChangeCard } from "../components/ChangeCard";
import { CircleView } from "../components/CircleView";
import { PublicRecordLine } from "../components/PublicRecordLine";
import { Button, Section } from "../components/ui";
import { ApiError, api } from "../lib/api";
import { formatAmount } from "../lib/money";
import {
  addressOf,
  PlainError,
  practiceContracts,
  practiceReader,
  sendAction,
} from "../lib/wallet";
import type { Hex, PublicRecord, TutorialState } from "../types";

type Phase = "idle" | "sending" | "confirming" | "server";
type Sent = { hash: Hex; block: bigint };
type HistoryItem = {
  step: string;
  hash: Hex;
  block: string;
  /** The step's copy on Avalanche Fuji; older saved items have none. */
  record?: PublicRecord | null;
};

const historyKey = (circle: Hex) => `kuber.history.${circle.toLowerCase()}`;
function loadHistory(circle: Hex): HistoryItem[] {
  try {
    return JSON.parse(localStorage.getItem(historyKey(circle)) ?? "[]");
  } catch {
    return [];
  }
}

/** Every transaction you sent in this practice circle (step name + hash), newest first. */
function HistoryButton({
  items,
  chain,
}: {
  items: HistoryItem[];
  chain: TxChain;
}) {
  const recorded = items.some((h) => h.record);
  return (
    <Dialog.Root>
      <Dialog.Trigger asChild>
        <button
          type="button"
          className="inline-flex min-h-11 items-center gap-1.5 self-center px-1 text-sm font-semibold text-brand underline underline-offset-4"
        >
          <History aria-hidden className="size-4" />
          History ({items.length})
        </button>
      </Dialog.Trigger>
      <Dialog.Portal>
        <Dialog.Overlay className="fixed inset-0 z-40 bg-ink/50" />
        <Dialog.Content className="fixed inset-x-0 bottom-0 z-50 max-h-[85dvh] overflow-y-auto rounded-t-3xl bg-surface p-5 pb-[max(1.25rem,env(safe-area-inset-bottom))] shadow-[0_-8px_30px_var(--color-shadow)] sm:inset-x-auto sm:top-1/2 sm:bottom-auto sm:left-1/2 sm:w-full sm:max-w-lg sm:-translate-x-1/2 sm:-translate-y-1/2 sm:rounded-3xl">
          <Dialog.Title className="font-display text-xl font-bold text-ink">
            Your transactions
          </Dialog.Title>
          <Dialog.Description className="mt-1 text-sm text-ink-2">
            Every transaction you sent in this tutorial. Tap a hash to see what
            it did.
            {recorded
              ? " The practice circle runs on a private chain so rounds can be skipped. Every step is also recorded on Avalanche Fuji, where anyone can check it."
              : " Practice chain — not on a public explorer."}
          </Dialog.Description>
          {items.length === 0 ? (
            <p className="mt-4 text-sm text-ink-2">Nothing sent yet.</p>
          ) : (
            <ol className="mt-4 divide-y divide-line">
              {items.map((h) => (
                <li
                  key={h.hash}
                  className="flex flex-wrap items-baseline justify-between gap-x-3 py-2.5"
                >
                  <span className="text-sm font-semibold text-ink">
                    {h.step}
                  </span>
                  <span className="text-sm text-ink-2">
                    {h.block !== "0" && `block ${h.block} · `}
                    <TxHash hash={h.hash} chain={chain} record={h.record} />
                  </span>
                  {h.record && (
                    <PublicRecordLine record={h.record} className="w-full" />
                  )}
                </li>
              ))}
            </ol>
          )}
          <Dialog.Close asChild>
            <Button variant="secondary" className="mt-4 w-full">
              Close
            </Button>
          </Dialog.Close>
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  );
}

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
  onLeave,
  onDone,
}: {
  initial: TutorialState;
  privateKey: Hex;
  /** Only for someone who finished the tutorial once: a first run has no way out but to finish. */
  onLeave?: () => void;
  onDone: (t: TutorialState) => void;
}) {
  const [t, setT] = useState(initial);
  const [phase, setPhase] = useState<Phase>("idle");
  const [error, setError] = useState<{
    message: string;
    afterTx: boolean;
  } | null>(null);
  const [sentFor, setSentFor] = useState<string | null>(null);
  const [tx, setTx] = useState<Sent | null>(null);
  const [pendingHash, setPendingHash] = useState<Hex | null>(null);
  const [lastTx, setLastTx] = useState<Sent | null>(null);
  const [history, setHistory] = useState<HistoryItem[]>(() =>
    loadHistory(initial.circle),
  );
  const [contracts, setContracts] = useState<{ usdc?: Hex; factory?: Hex }>({});
  useEffect(() => {
    practiceContracts()
      .then(setContracts)
      .catch(() => {});
  }, []);
  const me = useMemo(() => addressOf(privateKey), [privateKey]);
  // The circle's own history from the server (every member's transactions); hidden if the server has none.
  const [activity, setActivity] = useState<ActivityItem[] | null>(null);
  // biome-ignore lint/correctness/useExhaustiveDependencies: refetch after every step
  useEffect(() => {
    api
      .activity(t.circle)
      .then(setActivity)
      .catch(() => setActivity(null));
  }, [t.circle, t.stepIndex]);
  const reader = useMemo(() => practiceReader(me), [me]);
  // Names for the details pop-up: the practice circle, its contracts and its members.
  const chain = useMemo<TxChain>(() => {
    const labels: Record<string, string> = {
      [t.circle.toLowerCase()]: "This circle",
      [me.toLowerCase()]: "You",
    };
    if (contracts.usdc)
      labels[contracts.usdc.toLowerCase()] = "Test money (mUSDC)";
    if (contracts.factory)
      labels[contracts.factory.toLowerCase()] = "Circle factory";
    for (const m of t.snapshot.members)
      labels[m.address.toLowerCase()] ??= m.you ? "You" : m.name;
    return { client: reader, explorer: null, labels };
  }, [reader, me, contracts, t.circle, t.snapshot.members]);
  const [announce, setAnnounce] = useState("");
  const panel = useRef<HTMLDivElement>(null);
  const [panelHeight, setPanelHeight] = useState(0);
  const firstStep = useRef(true);
  const wide = useWide();
  // On a phone the change card gets the panel to itself first; "Next step" moves on to the step.
  const [seenFor, setSeenFor] = useState<string | null>(null);
  const hasChange = t.lastChange !== null && t.stepIndex > 0;
  const reviewing = hasChange && !wide && seenFor !== t.step.id;
  // On a phone the guide can fold down to its button so nothing on the page stays covered.
  const [foldedFor, setFoldedFor] = useState<string | null>(null);
  const folded = !wide && foldedFor === `${t.step.id}:${reviewing}`;

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

  function saveHistory(update: (h: HistoryItem[]) => HistoryItem[]) {
    setHistory((h) => {
      const next = update(h);
      try {
        localStorage.setItem(historyKey(t.circle), JSON.stringify(next));
      } catch {
        // private mode: history lasts for this page only
      }
      return next;
    });
  }

  function accept(next: TutorialState, doneTx: Sent | null) {
    // The step's Fuji record comes back with the next state: keep it with your transaction.
    const record = next.lastChange?.record;
    if (doneTx && record)
      saveHistory((h) =>
        h.map((x) => (x.hash === doneTx.hash ? { ...x, record } : x)),
      );
    setLastTx(doneTx);
    setTx(null);
    setSentFor(null);
    setT(next);
    setAnnounce(
      `${next.lastChange ? `What just changed: ${next.lastChange.title}. ` : ""}${next.done ? "The tutorial is complete." : `Next: ${next.step.title}`}`,
    );
    if (next.done) onDone(next);
  }

  async function go(resend = false, choice?: string) {
    setError(null);
    const step = t.step;
    let sent = false;
    let doneTx = sentFor === step.id ? tx : null;
    try {
      if (step.action && (resend || sentFor !== step.id)) {
        setPhase("sending");
        setPendingHash(null);
        setAnnounce("Sending from your practice wallet.");
        try {
          const done = await sendAction(
            privateKey,
            t.circle,
            step.action,
            (hash) => {
              setPendingHash(hash);
              setPhase("confirming");
            },
          );
          doneTx = done;
          setTx(done);
          setSentFor(step.id);
          sent = true;
          const item = {
            step: step.title,
            hash: done.hash,
            block: done.block.toString(),
          };
          saveHistory((h) => [item, ...h.filter((x) => x.hash !== done.hash)]);
          setAnnounce(
            `Confirmed in block ${done.block}. ${step.waitNote ?? ""}`,
          );
        } catch (err) {
          // The action may already be done (for example after a reload); ask the server before giving up.
          setPhase("server");
          try {
            accept(await api.next(step.id, choice), null);
            return;
          } catch {
            throw err;
          }
        }
      } else if (step.waitNote) {
        setAnnounce(step.waitNote);
      }
      setPhase("server");
      accept(await api.next(step.id, choice), doneTx);
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
          {onLeave ? (
            <button
              type="button"
              onClick={onLeave}
              className="min-h-11 px-1 text-sm font-semibold text-white underline underline-offset-4"
            >
              Leave tutorial
            </button>
          ) : (
            <p className="py-2 text-right text-xs text-white/85">
              Finish the tutorial to open the app
            </p>
          )}
        </div>
        {/* Phones: the two numbers you always want in view. */}
        <div className="mx-auto flex max-w-6xl items-baseline justify-between gap-3 border-t border-white/15 px-4 py-2 lg:hidden">
          <p className="text-sm text-white/85">
            {t.snapshot.status === "Active"
              ? `Round ${t.snapshot.round} of ${t.snapshot.totalRounds}`
              : t.snapshot.status === "Forming"
                ? "Not started yet"
                : t.snapshot.status === "Completed"
                  ? "All rounds done"
                  : t.snapshot.status}
          </p>
          <p className="text-sm text-white/85">
            In the pot{" "}
            <span className="num font-display text-lg font-bold text-accent">
              {formatAmount(t.snapshot.pot.total)}
            </span>
          </p>
        </div>
      </div>

      <div className="mx-auto max-w-6xl px-4 pt-4 lg:grid lg:grid-cols-[minmax(0,1fr)_400px] xl:grid-cols-[minmax(0,1fr)_460px] lg:gap-6 lg:pt-6">
        <main>
          <div className="mb-3 lg:mb-4 lg:rounded-2xl lg:border lg:border-line lg:bg-surface lg:p-4">
            <ChapterProgress t={t} />
          </div>
          <CircleView c={t.snapshot} />
          {activity && (
            <div className="mt-4">
              <Section
                title="Activity"
                aside={
                  <span className="text-right text-xs text-ink-2">
                    {activity.some((a) => a.record)
                      ? "Each step is also recorded on Avalanche Fuji"
                      : "Practice chain — not on a public explorer"}
                  </span>
                }
              >
                <ActivityList
                  items={activity}
                  chain={chain}
                  empty="No transactions yet."
                />
              </Section>
            </div>
          )}
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
          className="fixed inset-x-0 bottom-0 z-20 max-h-[55dvh] overflow-y-auto rounded-t-3xl border-t border-line bg-surface shadow-[0_-8px_30px_var(--color-shadow)] lg:sticky lg:top-[60px] lg:flex lg:max-h-[calc(100dvh-76px)] lg:flex-col lg:self-start lg:overflow-hidden lg:rounded-3xl lg:border lg:shadow-none"
        >
          {!wide && (
            <button
              type="button"
              aria-expanded={!folded}
              onClick={() =>
                setFoldedFor(folded ? null : `${t.step.id}:${reviewing}`)
              }
              className="sticky top-0 z-10 flex min-h-11 min-w-full flex-col items-center justify-center gap-1 bg-surface pt-1.5 text-xs font-semibold text-ink-2"
            >
              <span aria-hidden className="h-1 w-10 rounded-full bg-line" />
              <span className="flex items-center gap-1">
                {folded ? (
                  <ChevronUp aria-hidden className="size-3.5" />
                ) : (
                  <ChevronDown aria-hidden className="size-3.5" />
                )}
                {folded ? "Show the guide" : "Hide the guide to see the circle"}
              </span>
            </button>
          )}
          {/* Wide: only the change card scrolls (fading out at its edge); the step text and button always show in full. */}
          <div
            hidden={folded}
            className="grid gap-4 p-4 pt-1 pb-0 sm:px-5 sm:pb-0 lg:flex lg:min-h-0 lg:flex-col lg:p-5 lg:pb-0"
          >
            {t.lastChange && (reviewing || (hasChange && wide)) && (
              <div
                key={t.step.id}
                className="lg:-mb-4 lg:min-h-0 lg:overflow-y-auto lg:pb-4 lg:[mask-image:linear-gradient(to_bottom,black_calc(100%_-_1rem),transparent)]"
              >
                <ChangeCard change={t.lastChange} tx={lastTx} chain={chain} />
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
            {folded && (
              <p className="truncate text-sm text-ink" aria-hidden>
                <span className="font-semibold text-brand">
                  {reviewing
                    ? "What just changed:"
                    : `Step ${t.stepIndex + 1}:`}
                </span>{" "}
                {reviewing ? t.lastChange?.title : step.title}
              </p>
            )}
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
                  ) : phase === "confirming" ? (
                    <>
                      <p className="font-semibold">
                        Sent. Waiting for it to be confirmed…
                      </p>
                      {pendingHash && (
                        <p className="text-ink-2">
                          Transaction{" "}
                          <TxHash hash={pendingHash} chain={chain} />
                        </p>
                      )}
                    </>
                  ) : (
                    <>
                      {tx && (
                        <p className="text-ink-2">
                          Done — confirmed in block {tx.block.toString()}.
                          Transaction <TxHash hash={tx.hash} chain={chain} />
                        </p>
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
            ) : step.options && step.options.length > 0 ? (
              <fieldset
                className="grid gap-2 border-0 p-0"
                aria-label={step.title}
              >
                {step.options.map((o) => (
                  <button
                    key={o.value}
                    type="button"
                    data-option={o.value}
                    disabled={busy}
                    onClick={() => go(false, o.value)}
                    className="min-w-full rounded-xl border border-line bg-surface px-4 py-3 text-left hover:border-brand disabled:cursor-not-allowed disabled:opacity-60"
                  >
                    <span className="block font-semibold text-brand">
                      {o.label}
                    </span>
                    <span className="mt-0.5 block text-sm text-ink-2">
                      {o.description}
                    </span>
                  </button>
                ))}
              </fieldset>
            ) : (
              <Button
                onClick={() => go()}
                disabled={busy}
                busy={busy}
                className="w-full"
              >
                {busy
                  ? phase === "sending"
                    ? "Sending…"
                    : phase === "confirming"
                      ? "Confirming…"
                      : "Working…"
                  : label}
              </Button>
            )}
            {history.length > 0 && !busy && (
              <HistoryButton items={history} chain={chain} />
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
