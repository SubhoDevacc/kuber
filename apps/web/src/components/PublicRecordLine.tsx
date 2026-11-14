import { shortHash } from "../lib/wallet";
import type { PublicRecord } from "../types";

/** "Recorded on Avalanche Fuji · 0x1234…abcd · View on Snowtrace": a tutorial step's public copy. */
export function PublicRecordLine({
  record,
  className = "",
}: {
  record: PublicRecord;
  className?: string;
}) {
  return (
    <p className={`text-xs text-ink-2 ${className}`}>
      Recorded on {record.chain} ·{" "}
      <span className="num whitespace-nowrap">{shortHash(record.hash)}</span> ·{" "}
      <a
        href={record.url}
        target="_blank"
        rel="noopener noreferrer"
        className="font-medium whitespace-nowrap text-brand underline decoration-brand/40 underline-offset-4 hover:decoration-brand"
      >
        View on Snowtrace
        <span className="sr-only"> (opens in a new tab)</span>
      </a>
    </p>
  );
}
