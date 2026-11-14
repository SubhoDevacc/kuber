import { Check, CircleCheck, TriangleAlert } from "lucide-react";
import { ChangeCard } from "../components/ChangeCard";
import { Button, Wordmark } from "../components/ui";
import { formatAmount, isZero } from "../lib/money";
import type { TutorialState } from "../types";

export function Finish({
  t,
  onEnter,
}: {
  t: TutorialState;
  onEnter: () => void;
}) {
  const c = t.snapshot;
  const putIn = BigInt(c.contribution) * BigInt(c.totalRounds);
  // The server's last change card carries the share-out ("Your share-out: Not paid → 712.04 mUSDC").
  const got = t.lastChange?.rows.find((r) =>
    /^your share-out/i.test(r.label),
  )?.after;
  const hit = c.members
    .filter((m) => !isZero(m.lost) || !isZero(m.debt))
    .sort((a, b) => Number(isZero(a.debt)) - Number(isZero(b.debt)));
  const safe = c.members.filter((m) => isZero(m.lost) && isZero(m.debt));
  const names = (list: typeof safe) =>
    list
      .map((m) => (m.you ? "you" : m.name))
      .join(", ")
      .replace(/, ([^,]*)$/, " and $1");

  return (
    <div className="mx-auto min-h-dvh max-w-3xl px-4 py-5 sm:px-6">
      <Wordmark />
      <main className="py-8">
        <CircleCheck aria-hidden className="size-12 text-good" />
        <h1 className="mt-3 font-display text-3xl font-bold tracking-tight text-ink sm:text-4xl">
          You finished the tutorial
        </h1>
        <p className="mt-2 max-w-[38rem] text-lg leading-relaxed text-ink">
          You saved for {c.totalRounds} rounds, borrowed with a backer, repaid,
          voted, saw a member stop paying, and took your share-out. All with
          test money on a real practice chain.
        </p>

        <dl className="mt-8 grid gap-3 sm:grid-cols-2">
          <div className="rounded-2xl border border-line bg-surface p-4">
            <dt className="text-sm text-ink-2">What you put in</dt>
            <dd className="num mt-1 font-display text-3xl font-bold text-ink">
              {formatAmount(putIn)}
            </dd>
            <dd className="text-sm text-ink-2">
              {c.totalRounds} rounds of {formatAmount(c.contribution)} mUSDC
            </dd>
          </div>
          {got && (
            <div className="rounded-2xl border border-good/40 bg-good-soft p-4">
              <dt className="text-sm text-ink-2">What you got back</dt>
              <dd className="num mt-1 font-display text-3xl font-bold text-good">
                {got.replace(/ mUSDC$/, "")}
              </dd>
              <dd className="text-sm text-ink-2">
                Your share-out, after paying interest on your loan
              </dd>
            </div>
          )}
        </dl>

        <section className="mt-6 grid gap-3">
          <h2 className="font-display text-xl font-bold text-ink">
            When Dev stopped paying
          </h2>
          <ul className="grid gap-2">
            {hit.map((m) => (
              <li
                key={m.address}
                className="flex flex-wrap items-baseline justify-between gap-x-3 rounded-xl border border-bad/30 bg-bad-soft px-4 py-3"
              >
                <span className="flex items-center gap-1.5 self-center font-semibold">
                  <TriangleAlert
                    aria-hidden
                    className="size-4 shrink-0 text-bad"
                  />
                  {m.name}
                </span>
                <span className="num text-bad">
                  {!isZero(m.lost) && `lost ${formatAmount(m.lost)} mUSDC`}
                  {!isZero(m.lost) && !isZero(m.debt) && ", "}
                  {!isZero(m.debt) &&
                    `still owes ${formatAmount(m.debt)} mUSDC`}
                </span>
              </li>
            ))}
            <li className="flex items-start gap-1.5 rounded-xl border border-good/30 bg-good-soft px-4 py-3">
              <Check aria-hidden className="mt-1 size-4 shrink-0 text-good" />
              <span>
                <span className="font-semibold">
                  Everyone else lost nothing:{" "}
                </span>
                {names(safe)}.
              </span>
            </li>
          </ul>
          <p className="text-sm text-ink-2">
            Only the person who stopped paying and the people who chose to back
            him carried the loss.
          </p>
        </section>

        {t.lastChange && (
          <div className="mt-6">
            <ChangeCard change={t.lastChange} />
          </div>
        )}

        <Button onClick={onEnter} className="mt-8 w-full sm:w-auto sm:px-10">
          Enter the app
        </Button>
      </main>
    </div>
  );
}
