import {
  kuberCircleAbi,
  kuberFactoryAbi,
  kuberRegistryAbi,
  mockUsdcAbi,
} from "@kuber/shared";
import { Check, Copy, ExternalLink, LoaderCircle, X } from "lucide-react";
import { Dialog } from "radix-ui";
import { type ReactNode, useEffect, useRef, useState } from "react";
import {
  type Abi,
  type AbiFunction,
  decodeFunctionData,
  formatEther,
  type PublicClient,
  parseEventLogs,
  type Transaction,
  type TransactionReceipt,
} from "viem";
import { PublicRecordLine } from "../components/PublicRecordLine";
import { Button, Chip } from "../components/ui";
import { shortHash } from "../lib/wallet";
import type { PublicRecord } from "../types";
import { type Args, describeCall, describeEvent, who } from "./txDescribe";

export type TxChain = {
  client: PublicClient;
  explorer: string | null;
  labels: Record<string, string>;
};

const ABIS = [
  kuberCircleAbi,
  kuberFactoryAbi,
  mockUsdcAbi,
  kuberRegistryAbi,
] as readonly Abi[];
const ALL_ABI = ABIS.flat() as Abi;

type Loaded = {
  tx: Transaction;
  receipt: TransactionReceipt;
  timestamp: bigint;
};
type State =
  | { kind: "loading" }
  | { kind: "error"; message: string }
  | { kind: "ready"; data: Loaded };

/** Decodes the call against the Kuber ABIs; null when none match. */
function decodeCall(input: `0x${string}`): { name: string; args: Args } | null {
  for (const abi of ABIS) {
    try {
      const { functionName, args = [] } = decodeFunctionData({
        abi,
        data: input,
      });
      const values = args as readonly unknown[];
      const item = abi.find(
        (x): x is AbiFunction =>
          x.type === "function" &&
          x.name === functionName &&
          x.inputs.length === values.length,
      );
      const named: Args = {};
      values.forEach((v, i) => {
        named[item?.inputs[i]?.name || `value${i + 1}`] = v;
      });
      return { name: functionName, args: named };
    } catch {
      // Not this contract; try the next one.
    }
  }
  return null;
}

/** A small inline button showing the short hash. Opens the details dialog. */
export function TxHash({
  hash,
  chain,
  record,
  className = "",
}: {
  hash: `0x${string}`;
  chain: TxChain;
  /** Tutorial: the step's copy on Avalanche Fuji, when there is one. */
  record?: PublicRecord | null;
  className?: string;
}) {
  const [open, setOpen] = useState(false);
  return (
    <>
      <button
        type="button"
        onClick={() => setOpen(true)}
        aria-label={`Transaction ${shortHash(hash)}: show details`}
        className={`num relative inline-flex items-center rounded font-medium text-brand underline decoration-brand/40 underline-offset-4 hover:decoration-brand after:absolute after:-inset-x-1 after:-inset-y-3 after:content-[''] ${className}`}
      >
        {shortHash(hash)}
      </button>
      <TxDialog
        hash={hash}
        chain={chain}
        record={record}
        open={open}
        onOpenChange={setOpen}
      />
    </>
  );
}

/** Controlled dialog with a transaction's details. Reads the chain only while open. */
export function TxDialog({
  hash,
  chain,
  record,
  open,
  onOpenChange,
}: {
  hash: `0x${string}`;
  chain: TxChain;
  record?: PublicRecord | null;
  open: boolean;
  onOpenChange: (open: boolean) => void;
}) {
  const [state, setState] = useState<State>({ kind: "loading" });
  const [attempt, setAttempt] = useState(0);
  const loadedHash = useRef<string | null>(null);
  const { client } = chain;

  // biome-ignore lint/correctness/useExhaustiveDependencies: `attempt` re-runs the read when "Try again" is pressed
  useEffect(() => {
    if (!open || loadedHash.current === hash) return;
    let live = true;
    setState({ kind: "loading" });
    (async () => {
      try {
        const [tx, receipt] = await Promise.all([
          client.getTransaction({ hash }),
          client.getTransactionReceipt({ hash }),
        ]);
        const block = await client.getBlock({
          blockNumber: receipt.blockNumber,
        });
        if (!live) return;
        loadedHash.current = hash;
        setState({
          kind: "ready",
          data: { tx, receipt, timestamp: block.timestamp },
        });
      } catch (e) {
        if (!live) return;
        const pending =
          e instanceof Error && e.name === "TransactionReceiptNotFoundError";
        setState({
          kind: "error",
          message: pending
            ? "This transaction isn't confirmed yet. Try again in a moment."
            : "Couldn't read this transaction. Try again in a moment.",
        });
      }
    })();
    return () => {
      live = false;
    };
  }, [open, hash, client, attempt]);

  return (
    <Dialog.Root open={open} onOpenChange={onOpenChange}>
      <Dialog.Portal>
        <Dialog.Overlay className="fixed inset-0 z-50 bg-ink/50" />
        <Dialog.Content className="arrive fixed inset-x-0 bottom-0 z-50 flex max-h-[90dvh] flex-col rounded-t-2xl border border-line bg-surface text-ink shadow-xl focus:outline-none sm:inset-x-auto sm:bottom-auto sm:left-1/2 sm:top-1/2 sm:w-[calc(100%-2rem)] sm:max-w-lg sm:-translate-x-1/2 sm:-translate-y-1/2 sm:rounded-2xl">
          <div className="flex items-center justify-between gap-3 border-b border-line py-1 pr-1 pl-4 sm:pl-5">
            <Dialog.Title className="text-sm font-semibold text-ink-2">
              Transaction details
            </Dialog.Title>
            <Dialog.Close
              aria-label="Close"
              className="inline-flex min-h-11 min-w-11 items-center justify-center rounded-xl text-ink-2 hover:bg-paper hover:text-ink"
            >
              <X aria-hidden className="size-5" />
            </Dialog.Close>
          </div>
          <div className="overflow-y-auto overscroll-contain px-4 pt-4 pb-[max(1.25rem,env(safe-area-inset-bottom))] sm:px-5">
            {state.kind === "loading" && (
              <>
                <Dialog.Description className="flex min-h-24 items-center gap-2 text-ink-2">
                  <LoaderCircle aria-hidden className="spin size-5 shrink-0" />
                  Reading this transaction…
                </Dialog.Description>
                <HashRow hash={hash} />
              </>
            )}
            {state.kind === "error" && (
              <>
                <Dialog.Description className="rounded-xl bg-bad-soft px-4 py-3 text-bad">
                  {state.message}
                </Dialog.Description>
                <Button
                  variant="secondary"
                  className="mt-3 w-full sm:w-auto"
                  onClick={() => setAttempt((n) => n + 1)}
                >
                  Try again
                </Button>
                <HashRow hash={hash} />
              </>
            )}
            {state.kind === "ready" && (
              <Details data={state.data} hash={hash} chain={chain} />
            )}
            {!chain.explorer && record ? (
              <div className="mt-5">
                <h3 className="font-display text-base font-bold text-ink">
                  Public record
                </h3>
                <p className="mt-1 text-sm text-ink-2">
                  The practice circle runs on an Avalanche L1. This step is also
                  recorded on Avalanche Fuji, where anyone can check it.
                </p>
                <CopyHash hash={record.hash} />
                <PublicRecordLine record={record} className="mt-2" />
              </div>
            ) : (
              <p className="mt-4 text-sm text-ink-2">
                {chain.explorer ? (
                  <a
                    href={`${chain.explorer}/tx/${hash}`}
                    target="_blank"
                    rel="noreferrer"
                    className="inline-flex min-h-11 items-center gap-1.5 font-medium text-brand underline decoration-brand/40 underline-offset-4 hover:decoration-brand"
                  >
                    View on Snowtrace
                    <ExternalLink aria-hidden className="size-4" />
                    <span className="sr-only">(opens in a new tab)</span>
                  </a>
                ) : (
                  "Practice chain — not on a public explorer"
                )}
              </p>
            )}
          </div>
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  );
}

function Details({
  data,
  hash,
  chain,
}: {
  data: Loaded;
  hash: `0x${string}`;
  chain: TxChain;
}) {
  const { tx, receipt, timestamp } = data;
  const { labels } = chain;
  const call = tx.input && tx.input !== "0x" ? decodeCall(tx.input) : null;
  const described = call ? describeCall(call.name, call.args, labels) : null;
  const headline =
    described?.headline ??
    (!tx.to
      ? "Set up a new contract"
      : tx.input === "0x"
        ? `Sent ${formatEther(tx.value)} AVAX`
        : "Called a contract Kuber doesn't know");
  let events: string[] = [];
  try {
    events = parseEventLogs({ abi: ALL_ABI, logs: receipt.logs }).map((log) =>
      describeEvent(log.eventName, (log.args ?? {}) as Args, labels),
    );
  } catch {
    events = [];
  }
  const ok = receipt.status === "success";
  const other = receipt.logs.length - events.length;

  return (
    <>
      <Dialog.Description className="font-display text-xl leading-snug font-bold text-ink">
        {headline}
      </Dialog.Description>
      <div className="mt-2">
        <Chip tone={ok ? "ok" : "bad"}>{ok ? "Succeeded" : "Failed"}</Chip>
      </div>

      <dl className="mt-4 divide-y divide-line border-y border-line text-sm">
        <Row label="When">
          {new Date(Number(timestamp) * 1000).toLocaleString()}
        </Row>
        <Row label="Block">
          <span className="num">{receipt.blockNumber.toLocaleString()}</span>
        </Row>
        <Row label="From">
          <Party addr={tx.from} labels={labels} />
        </Row>
        <Row label="To">
          {tx.to ? <Party addr={tx.to} labels={labels} /> : "A new contract"}
        </Row>
        <Row label="Gas used">
          <span className="num">{receipt.gasUsed.toLocaleString()}</span>
        </Row>
      </dl>

      <h3 className="mt-5 font-display text-base font-bold text-ink">
        What was called
      </h3>
      {call && described ? (
        <>
          <p className="mt-1 font-mono text-sm break-all text-ink-2">
            {call.name}
          </p>
          {described.rows.length > 0 && (
            <dl className="mt-2 divide-y divide-line border-y border-line text-sm">
              {described.rows.map((r) => (
                <Row key={r.label} label={r.label}>
                  {r.value}
                </Row>
              ))}
            </dl>
          )}
        </>
      ) : (
        <p className="mt-1 text-sm text-ink-2">
          {tx.input === "0x"
            ? "Nothing — a plain payment."
            : "Something Kuber can't read."}
        </p>
      )}

      <h3 className="mt-5 font-display text-base font-bold text-ink">
        What it did
      </h3>
      {events.length > 0 ? (
        <ul className="mt-2 space-y-1.5 text-sm">
          {events.map((line, i) => (
            <li
              // biome-ignore lint/suspicious/noArrayIndexKey: log order is fixed for a mined transaction
              key={i}
              className="num flex gap-2 rounded-lg bg-paper px-3 py-2 break-words text-ink"
            >
              <Check aria-hidden className="mt-0.5 size-4 shrink-0 text-good" />
              <span className="min-w-0">{line}</span>
            </li>
          ))}
        </ul>
      ) : (
        <p className="mt-1 text-sm text-ink-2">
          {ok
            ? "Nothing was recorded."
            : "Nothing changed: the transaction failed."}
        </p>
      )}
      {other > 0 && (
        <p className="mt-1.5 text-xs text-ink-2">
          Plus {other} other record{other === 1 ? "" : "s"} Kuber can't read.
        </p>
      )}

      <HashRow hash={hash} />
    </>
  );
}

function Row({ label, children }: { label: string; children: ReactNode }) {
  return (
    <div className="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-0.5 py-2">
      <dt className="text-ink-2">{label}</dt>
      <dd className="min-w-0 text-right font-medium break-words text-ink">
        {children}
      </dd>
    </div>
  );
}

function Party({
  addr,
  labels,
}: {
  addr: string;
  labels: Record<string, string>;
}) {
  const named = labels[addr.toLowerCase()];
  return (
    <span className="inline-flex flex-col items-end">
      <span>{who(addr, labels)}</span>
      {named && (
        <span className="num text-xs font-normal text-ink-2">
          {shortHash(addr)}
        </span>
      )}
    </span>
  );
}

function HashRow({ hash }: { hash: `0x${string}` }) {
  return (
    <div className="mt-5">
      <h3 className="font-display text-base font-bold text-ink">
        Transaction ID
      </h3>
      <CopyHash hash={hash} />
    </div>
  );
}

/** The full hash with a Copy button. */
function CopyHash({ hash }: { hash: `0x${string}` }) {
  const [copied, setCopied] = useState(false);
  useEffect(() => {
    if (!copied) return;
    const t = setTimeout(() => setCopied(false), 1500);
    return () => clearTimeout(t);
  }, [copied]);
  const copy = async () => {
    try {
      await navigator.clipboard.writeText(hash);
      setCopied(true);
    } catch {
      setCopied(false);
    }
  };
  return (
    <div className="mt-2 flex flex-col gap-2 sm:flex-row sm:items-center">
      <code className="num min-w-0 flex-1 rounded-lg bg-paper px-3 py-2 font-mono text-xs break-all text-ink">
        {hash}
      </code>
      <Button variant="secondary" onClick={copy} className="shrink-0">
        {copied ? (
          <Check aria-hidden className="size-4" />
        ) : (
          <Copy aria-hidden className="size-4" />
        )}
        <span aria-live="polite">{copied ? "Copied" : "Copy"}</span>
      </Button>
    </div>
  );
}
