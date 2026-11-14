import { kuberCircleAbi } from "@kuber/shared";
import { ChevronLeft } from "lucide-react";
import { useState } from "react";
import type { Abi } from "viem";
import { Button, Section } from "../components/ui";
import type { Hex, MoneyPlan } from "../types";
import {
  encodePlan,
  KIND,
  PLAN_PARTS,
  pctText,
  pctToBps,
  planLine,
  planProblem,
} from "./plan";
import { TxSteps, useTx } from "./TxStatus";

const circleAbi = kuberCircleAbi as Abi;

/** A plan as a bar: one segment per part, in the same colours as the pot card. */
export function PlanBar({ plan }: { plan: MoneyPlan }) {
  const look: Record<keyof MoneyPlan, string> = {
    loan: "bg-accent",
    aave: "bg-brand",
    lp: "bg-brand-deep",
    cash: "bg-brand-soft border border-brand/40",
  };
  return (
    <div
      aria-hidden
      className="flex h-3 w-full overflow-hidden rounded-full bg-paper"
    >
      {PLAN_PARTS.map((p) => (
        <div
          key={p.key}
          className={`h-full ${look[p.key]}`}
          style={{ width: `${plan[p.key] / 100}%` }}
        />
      ))}
    </div>
  );
}

/**
 * "Change the money plan": four parts that must add up to 100%, checked against the contract's bounds before
 * anything is sent. Sends `propose(Allocation, abi.encode(loan, aave, lp, cash))`; the group votes and the plan
 * changes when the round closes.
 */
export function MoneyPlanScreen({
  circle,
  current,
  names,
  onBack,
  onSent,
}: {
  circle: Hex;
  current: MoneyPlan;
  names: Record<string, string>;
  onBack: () => void;
  onSent: () => void;
}) {
  const tx = useTx(onSent);
  const [values, setValues] = useState<Record<keyof MoneyPlan, string>>(
    () =>
      Object.fromEntries(
        PLAN_PARTS.map((p) => [p.key, pctText(current[p.key]).slice(0, -1)]),
      ) as Record<keyof MoneyPlan, string>,
  );
  const [error, setError] = useState<string | null>(null);
  const [sent, setSent] = useState(false);

  const bps = Object.fromEntries(
    PLAN_PARTS.map((p) => [p.key, pctToBps(values[p.key] || "0")]),
  ) as Record<keyof MoneyPlan, number | null>;
  const valid = PLAN_PARTS.every((p) => bps[p.key] !== null);
  const plan: MoneyPlan | null = valid
    ? {
        loan: bps.loan ?? 0,
        aave: bps.aave ?? 0,
        lp: bps.lp ?? 0,
        cash: bps.cash ?? 0,
      }
    : null;
  const total = plan ? plan.loan + plan.aave + plan.lp + plan.cash : null;
  const same =
    plan !== null && PLAN_PARTS.every((p) => plan[p.key] === current[p.key]);

  function submit(e: React.FormEvent) {
    e.preventDefault();
    if (!plan) return setError("Enter each part as a percent from 0 to 100.");
    const problem = planProblem(plan);
    if (problem) return setError(problem);
    if (same)
      return setError("That's the plan the circle already has. Change a part.");
    setError(null);
    tx.run(async (send) => {
      await send(`Suggest a new money plan: ${planLine(plan)}`, {
        address: circle,
        abi: circleAbi,
        functionName: "propose",
        args: [KIND.Allocation, encodePlan(plan)],
      });
      setSent(true);
      return "Suggested. Everyone votes this round; if more than half say yes, the new plan applies when the round closes.";
    });
  }

  return (
    <div className="grid gap-4">
      <button
        type="button"
        onClick={onBack}
        className="inline-flex min-h-11 w-fit items-center gap-1 rounded-xl font-semibold text-brand"
      >
        <ChevronLeft aria-hidden className="size-5" /> Back to the circle
      </button>
      <header>
        <h2 className="font-display text-2xl font-bold tracking-tight text-ink">
          Change the money plan
        </h2>
        <p className="mt-1 text-sm text-ink-2">
          How the circle's money is split. The group votes on your plan, and it
          applies when the round closes.
        </p>
      </header>
      <Section title="The plan now">
        <PlanBar plan={current} />
        <p className="mt-2 text-sm text-ink">{planLine(current)}</p>
      </Section>
      <Section title="Your new plan">
        <form noValidate onSubmit={submit} className="grid gap-4">
          {PLAN_PARTS.map((p) => (
            <div key={p.key} className="grid gap-1">
              <div className="flex items-center justify-between gap-3">
                <label
                  htmlFor={`plan-${p.key}`}
                  className="font-semibold text-ink"
                >
                  {p.label}
                </label>
                <div className="flex items-center gap-1.5">
                  <input
                    id={`plan-${p.key}`}
                    inputMode="decimal"
                    value={values[p.key]}
                    onChange={(e) =>
                      setValues((v) => ({ ...v, [p.key]: e.target.value }))
                    }
                    aria-describedby={`plan-${p.key}-line`}
                    className="num block min-h-11 w-20 rounded-xl border border-line bg-surface px-3 text-right text-base text-ink outline-none focus:border-brand focus:ring-2 focus:ring-brand/30"
                  />
                  <span className="text-ink-2">%</span>
                </div>
              </div>
              <p id={`plan-${p.key}-line`} className="text-sm text-ink-2">
                {p.line} Now {pctText(current[p.key])}.
              </p>
            </div>
          ))}
          {plan && <PlanBar plan={plan} />}
          <p
            className={`text-sm font-semibold ${total === 10_000 ? "text-good" : "text-warn"}`}
            aria-live="polite"
          >
            {total === null
              ? "Enter each part as a percent."
              : total === 10_000
                ? "Adds up to 100%."
                : `Adds up to ${pctText(total)}. It must be exactly 100%.`}
          </p>
          {error && (
            <p role="alert" className="text-sm font-semibold text-bad">
              {error}
            </p>
          )}
          <TxSteps
            steps={tx.steps}
            note={tx.note}
            circle={circle}
            names={names}
          />
          {sent ? (
            <Button variant="secondary" onClick={onBack}>
              Back to the circle to vote
            </Button>
          ) : (
            <Button type="submit" busy={tx.busy} disabled={tx.busy}>
              Suggest this money plan
            </Button>
          )}
        </form>
      </Section>
    </div>
  );
}
