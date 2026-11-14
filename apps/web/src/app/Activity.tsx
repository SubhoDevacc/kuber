import { useContext } from "react";
import { PublicRecordLine } from "../components/PublicRecordLine";
import { formatAmount } from "../lib/money";
import type { Hex } from "../types";
import { type ActivityItem, toMs } from "./appApi";
import { Ctx } from "./ctx";
import { type TxChain, TxHash } from "./TxDetails";

function when(t: number | string): string {
  const ms = toMs(t);
  if (ms === null) return "";
  const d = new Date(ms);
  const today = new Date().toDateString() === d.toDateString();
  return today
    ? d.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" })
    : d.toLocaleString([], {
        month: "short",
        day: "numeric",
        hour: "numeric",
        minute: "2-digit",
      });
}

/** A list of real transactions, newest first. Every hash opens the details pop-up. */
export function ActivityList({
  items,
  circle,
  names,
  showCircle = false,
  empty = "Nothing yet.",
  chain,
}: {
  items: ActivityItem[] | null;
  circle?: Hex;
  names?: Record<string, string>;
  showCircle?: boolean;
  empty?: string;
  /** Outside the real app (the tutorial) pass the practice chain. */
  chain?: TxChain;
}) {
  const app = useContext(Ctx);
  if (items === null)
    return (
      <div
        className="h-16 animate-pulse rounded-xl bg-line/60 motion-reduce:animate-none"
        role="status"
      >
        <span className="sr-only">Loading activity</span>
      </div>
    );
  if (items.length === 0) return <p className="text-sm text-ink-2">{empty}</p>;
  const tc = chain ?? app?.txChain(names, circle);
  if (!tc) return null;
  return (
    <ul className="-mx-1 divide-y divide-line">
      {items.map((a, i) => (
        <li
          // biome-ignore lint/suspicious/noArrayIndexKey: one tx can carry several lines
          key={`${a.txHash}-${i}`}
          className="flex items-start justify-between gap-3 px-1 py-2.5"
        >
          <div className="min-w-0">
            <p className="text-sm font-semibold text-ink">{a.what}</p>
            <p className="text-xs text-ink-2">
              {when(a.time)}
              {showCircle && a.circle ? ` · ${a.circle}` : ""}
              {" · "}
              <TxHash hash={a.txHash} chain={tc} record={a.record} />
            </p>
            {a.record && (
              <PublicRecordLine record={a.record} className="mt-0.5" />
            )}
          </div>
          {a.amount !== null && a.amount !== undefined && (
            <p className="num shrink-0 text-sm font-semibold text-ink">
              {formatAmount(a.amount)}
            </p>
          )}
        </li>
      ))}
    </ul>
  );
}
