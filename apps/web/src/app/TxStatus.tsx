import { CircleAlert, CircleCheck, LoaderCircle } from "lucide-react";
import { useCallback, useRef, useState } from "react";
import { ApiError } from "../lib/errors";
import type { Hex } from "../types";
import { type Call, PlainError, plainReason, sendTx } from "./chain";
import { useApp } from "./ctx";
import { TxHash } from "./TxDetails";

export type TxStep = {
  label: string;
  phase: "sending" | "confirming" | "done" | "failed";
  hash?: Hex;
  block?: bigint;
  message?: string;
};

export type Send = (label: string, call: Call) => Promise<Hex>;

/**
 * Runs one user action (one or more transactions in order) and records each step's real state:
 * "Sending…" → "Waiting for confirmation" → "Confirmed in block N". Nothing says done before the receipt.
 */
export function useTx(onDone?: () => void) {
  const { chain, signer } = useApp();
  const [steps, setSteps] = useState<TxStep[]>([]);
  const [busy, setBusy] = useState(false);
  const [note, setNote] = useState<string | null>(null);
  const running = useRef(false);

  const run = useCallback(
    async (
      work: (send: Send) => Promise<string | undefined>,
    ): Promise<boolean> => {
      if (running.current) return false;
      running.current = true;
      setBusy(true);
      setNote(null);
      setSteps([]);
      const patch = (i: number, p: Partial<TxStep>) =>
        setSteps((s) => s.map((x, j) => (j === i ? { ...x, ...p } : x)));
      let n = 0;
      let inSend = false;
      const send: Send = async (label, call) => {
        const i = n++;
        setSteps((s) => [...s, { label, phase: "sending" }]);
        try {
          const { hash, block } = await sendTx(chain, signer, call, (h) =>
            patch(i, { phase: "confirming", hash: h }),
          );
          patch(i, { phase: "done", hash, block });
          return hash;
        } catch (err) {
          patch(i, { phase: "failed", message: plainReason(err) });
          inSend = true;
          throw err;
        }
      };
      try {
        const done = await work(send);
        if (typeof done === "string") setNote(done);
        onDone?.();
        return true;
      } catch (err) {
        // Failures inside `send` are already on their step; anything else (a server call) gets a note.
        if (!inSend)
          setNote(
            err instanceof ApiError || err instanceof PlainError
              ? err.message
              : plainReason(err),
          );
        onDone?.();
        return false;
      } finally {
        running.current = false;
        setBusy(false);
      }
    },
    [chain, signer, onDone],
  );

  const clear = useCallback(() => {
    setSteps([]);
    setNote(null);
  }, []);

  return { steps, busy, note, run, clear, setNote };
}

export function TxSteps({
  steps,
  note,
  circle,
  names,
}: {
  steps: TxStep[];
  note?: string | null;
  circle?: Hex;
  names?: Record<string, string>;
}) {
  const { txChain } = useApp();
  if (steps.length === 0 && !note) return null;
  const tc = txChain(names, circle);
  return (
    <div className="grid gap-2" aria-live="polite">
      {steps.map((s, i) => (
        <div
          // biome-ignore lint/suspicious/noArrayIndexKey: steps only ever append
          key={i}
          role={s.phase === "failed" ? "alert" : undefined}
          className={`flex items-start gap-3 rounded-xl p-3 text-sm text-ink ${s.phase === "failed" ? "bg-bad-soft" : s.phase === "done" ? "bg-good-soft" : "bg-brand-soft"}`}
        >
          {s.phase === "done" ? (
            <CircleCheck
              aria-hidden
              className="mt-0.5 size-5 shrink-0 text-good"
            />
          ) : s.phase === "failed" ? (
            <CircleAlert
              aria-hidden
              className="mt-0.5 size-5 shrink-0 text-bad"
            />
          ) : (
            <LoaderCircle
              aria-hidden
              className="spin mt-0.5 size-5 shrink-0 text-brand"
            />
          )}
          <div className="min-w-0">
            <p className="font-semibold">{s.label}</p>
            <p className="text-ink-2">
              {s.phase === "sending" && "Sending from your wallet…"}
              {s.phase === "confirming" &&
                "Sent. Waiting for the network to confirm it…"}
              {s.phase === "done" &&
                `Confirmed in block ${s.block?.toString()}`}
              {s.phase === "failed" && s.message}
            </p>
            {s.hash && (
              <p className="mt-0.5 text-ink-2">
                Transaction <TxHash hash={s.hash} chain={tc} />
              </p>
            )}
          </div>
        </div>
      ))}
      {note && (
        <p className="rounded-xl bg-paper p-3 text-sm font-semibold text-ink [overflow-wrap:anywhere]">
          {note}
        </p>
      )}
    </div>
  );
}
