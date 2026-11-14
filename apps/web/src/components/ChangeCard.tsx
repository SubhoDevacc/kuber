import { ArrowRight, Check, TriangleAlert } from "lucide-react";
import type { LastChange } from "../types";

const toneText = {
  good: "text-good",
  bad: "text-bad",
  plain: "text-ink",
} as const;

export function ChangeCard({
  change,
  tx,
}: {
  change: LastChange;
  tx?: string | null;
}) {
  return (
    <section
      aria-labelledby="change-title"
      className="arrive rounded-xl border border-accent bg-accent-soft px-4 py-3"
    >
      <p className="text-xs font-semibold text-warn">What just changed</p>
      <h3
        id="change-title"
        tabIndex={-1}
        data-focus=""
        className="font-display text-lg leading-snug font-bold text-ink focus:outline-none"
      >
        {change.title}
      </h3>
      {tx && <p className="text-xs text-ink-2">Done. Transaction {tx}</p>}
      {change.rows.length > 0 && (
        <ul className="mt-2 divide-y divide-accent/40 border-y border-accent/40">
          {change.rows.map((r) => (
            <li
              key={r.label}
              className="num flex flex-wrap items-center justify-between gap-x-3 gap-y-0.5 py-1.5 text-sm"
            >
              <span className="flex items-center gap-1.5 text-ink">
                {r.tone === "good" && (
                  <Check aria-hidden className="size-4 shrink-0 text-good" />
                )}
                {r.tone === "bad" && (
                  <TriangleAlert
                    aria-hidden
                    className="size-4 shrink-0 text-bad"
                  />
                )}
                {r.label}
                {r.tone !== "plain" && (
                  <span className="sr-only">
                    {r.tone === "good" ? " (good)" : " (a loss)"}
                  </span>
                )}
              </span>
              <span className="ml-auto flex items-center gap-1.5 whitespace-nowrap">
                <span className="text-ink-2">{r.before}</span>
                <ArrowRight
                  aria-label="became"
                  className="size-3.5 shrink-0 text-ink-2"
                />
                <span className={`font-bold ${toneText[r.tone]}`}>
                  {r.after}
                </span>
              </span>
            </li>
          ))}
        </ul>
      )}
      {change.note && (
        <p className="mt-2 text-sm leading-snug text-ink">{change.note}</p>
      )}
    </section>
  );
}
