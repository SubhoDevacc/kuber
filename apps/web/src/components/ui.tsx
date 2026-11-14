import { LoaderCircle } from "lucide-react";
import {
  type ButtonHTMLAttributes,
  type ReactNode,
  useEffect,
  useRef,
  useState,
} from "react";
import { formatAmount, isZero } from "../lib/money";

type ButtonProps = ButtonHTMLAttributes<HTMLButtonElement> & {
  variant?: "primary" | "secondary" | "quiet";
  busy?: boolean;
};

export function Button({
  variant = "primary",
  busy,
  className = "",
  children,
  ...rest
}: ButtonProps) {
  const look = {
    primary:
      "bg-brand text-white hover:bg-brand-deep disabled:bg-brand/70 font-bold shadow-[0_6px_16px_var(--color-shadow)]",
    secondary:
      "bg-surface text-brand border border-line hover:border-brand hover:bg-brand-soft font-bold",
    quiet:
      "text-brand underline underline-offset-4 decoration-brand/40 hover:decoration-brand font-semibold",
  }[variant];
  return (
    <button
      type="button"
      className={`inline-flex min-h-12 items-center justify-center gap-2 rounded-2xl px-5 text-base transition-[background-color,border-color,color,box-shadow,transform] duration-200 disabled:cursor-not-allowed ${look} ${className}`}
      aria-busy={busy || undefined}
      {...rest}
    >
      {busy && <LoaderCircle aria-hidden className="spin size-5 shrink-0" />}
      {children}
    </button>
  );
}

/** A money amount that briefly lights up when its value changes. */
export function Amount({
  value,
  unit = false,
  className = "",
}: {
  value: string;
  unit?: boolean;
  className?: string;
}) {
  const prev = useRef(value);
  const [tick, setTick] = useState(0);
  useEffect(() => {
    if (prev.current !== value) {
      prev.current = value;
      setTick((t) => t + 1);
    }
  }, [value]);
  return (
    <span key={tick} className={`num ${tick ? "flash" : ""} ${className}`}>
      {formatAmount(value)}
      {unit && <span className="text-ink-2 font-normal"> mUSDC</span>}
    </span>
  );
}

export type Tone = "ok" | "warn" | "bad" | "idle";

export function statusTone(status: string): Tone {
  if (/paus|default|suspend|removed|cover/i.test(status)) return "bad";
  if (/behind|late|miss/i.test(status)) return "warn";
  if (/not joined|waiting|forming/i.test(status)) return "idle";
  return "ok";
}

export const memberTone = (status: string, lost: string, debt: string): Tone =>
  statusTone(status) === "bad" || !isZero(lost) || !isZero(debt)
    ? "bad"
    : statusTone(status);

const chipLook: Record<Tone, string> = {
  ok: "bg-good-soft text-good",
  warn: "bg-warn-soft text-warn",
  bad: "bg-bad-soft text-bad",
  idle: "bg-paper text-ink-2",
};
const dotLook: Record<Tone, string> = {
  ok: "bg-good",
  warn: "bg-warn",
  bad: "bg-bad",
  idle: "border border-ink-2",
};

export function Chip({ tone, children }: { tone: Tone; children: ReactNode }) {
  return (
    <span
      className={`inline-flex items-center gap-1.5 rounded-full border border-current/10 px-2.5 py-1 text-xs font-bold whitespace-nowrap ${chipLook[tone]}`}
    >
      <span aria-hidden className={`size-1.5 rounded-full ${dotLook[tone]}`} />
      {children}
    </span>
  );
}

export function PracticeTag() {
  return (
    <span className="inline-flex items-center rounded-md border border-brand/30 bg-brand-soft px-2 py-0.5 text-xs font-semibold text-brand">
      Practice
    </span>
  );
}

export function Section({
  title,
  children,
  aside,
}: {
  title: string;
  children: ReactNode;
  aside?: ReactNode;
}) {
  return (
    <section className="app-card rounded-3xl border border-line bg-surface p-5 sm:p-6">
      <div className="mb-3 flex items-baseline justify-between gap-3">
        <h3 className="font-display text-lg font-extrabold tracking-tight text-ink">
          {title}
        </h3>
        {aside}
      </div>
      {children}
    </section>
  );
}

export function Wordmark({ dark = false }: { dark?: boolean }) {
  return (
    <span
      className={`inline-flex items-center gap-2 font-display text-xl font-extrabold tracking-[-0.04em] ${dark ? "text-white" : "text-brand-deep"}`}
    >
      <svg
        aria-hidden
        viewBox="0 0 24 24"
        className={`size-7 ${dark ? "text-white" : "text-brand"}`}
      >
        <circle
          cx="12"
          cy="12"
          r="9"
          fill="none"
          stroke="currentColor"
          strokeWidth="2.4"
        />
        {[0, 60, 120, 180, 240, 300].map((a) => (
          <circle
            key={a}
            cx={12 + 9 * Math.cos(((a - 90) * Math.PI) / 180)}
            cy={12 + 9 * Math.sin(((a - 90) * Math.PI) / 180)}
            r={a === 0 ? 3 : 2}
            fill={a === 0 ? "var(--color-accent)" : "currentColor"}
          />
        ))}
      </svg>
      Kuber
    </span>
  );
}
