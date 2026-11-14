import { formatAmount, isZero, percent } from "../lib/money";
import type { CircleSnapshot } from "../types";
import { Ring } from "./Ring";
import {
  Amount,
  Chip,
  memberTone,
  PracticeTag,
  Section,
  statusTone,
} from "./ui";

const emptySeat = {
  name: "You",
  you: true,
  status: "Not joined yet",
  lost: "0",
  debt: "0",
};

function roundLine(c: CircleSnapshot) {
  if (c.status === "Forming") return "Waiting for everyone to join";
  if (c.status === "Completed") return `All ${c.totalRounds} rounds done`;
  if (c.status === "Cancelled") return "This circle was called off";
  return `Round ${c.round} of ${c.totalRounds}`;
}

function Stat({
  label,
  value,
  strong = false,
}: {
  label: string;
  value: string;
  strong?: boolean;
}) {
  const zero = isZero(value);
  return (
    <div className="min-w-0">
      <dt className="text-xs text-ink-2">{label}</dt>
      <dd
        className={`mt-0.5 text-base ${strong ? "font-bold" : "font-semibold"} ${zero ? "text-ink-2" : "text-ink"}`}
      >
        <Amount value={value} />
      </dd>
    </div>
  );
}

function PotBreakdown({ c }: { c: CircleSnapshot }) {
  const parts = [
    {
      label: "Kept as cash",
      value: c.pot.cash,
      swatch: "bg-brand-soft border border-brand/40",
    },
    { label: "Invested", value: c.pot.invested, swatch: "bg-brand" },
    { label: "Lent to members", value: c.pot.lent, swatch: "bg-accent" },
  ];
  return (
    <div className="w-full">
      <div
        className="flex h-3 w-full overflow-hidden rounded-full bg-paper"
        aria-hidden
      >
        {parts.map((p) => (
          <div
            key={p.label}
            className={`h-full transition-[width] duration-700 motion-reduce:transition-none ${p.swatch}`}
            style={{ width: `${percent(p.value, c.pot.total)}%` }}
          />
        ))}
      </div>
      <dl className="mt-3 grid gap-2">
        {parts.map((p) => (
          <div
            key={p.label}
            className="flex items-center justify-between gap-3 text-sm"
          >
            <dt className="flex items-center gap-2 text-ink-2">
              <span aria-hidden className={`size-3 rounded-sm ${p.swatch}`} />
              {p.label}
            </dt>
            <dd className="font-semibold">
              <Amount value={p.value} />
            </dd>
          </div>
        ))}
        <div className="flex items-center justify-between gap-3 border-t border-line pt-2 text-sm">
          <dt className="text-ink-2">Earned so far</dt>
          <dd className="font-semibold text-good">
            <Amount value={c.pot.earned} />
          </dd>
        </div>
      </dl>
    </div>
  );
}

export function CircleView({ c }: { c: CircleSnapshot }) {
  const you = c.you;
  return (
    <div className="grid gap-4">
      <header className="flex flex-wrap items-center gap-x-3 gap-y-1">
        <h2 className="font-display text-2xl font-bold tracking-tight text-ink sm:text-3xl">
          {c.name}
        </h2>
        {c.practice && <PracticeTag />}
        <p className="w-full text-sm text-ink-2">
          {roundLine(c)}. Everyone saves {formatAmount(c.contribution)} mUSDC
          per round.
        </p>
      </header>

      <Section title="The pot">
        <div className="grid items-center gap-5 md:grid-cols-[minmax(0,340px)_1fr]">
          <div className="flex justify-center">
            <Ring
              seats={
                // Before you join, keep your seat visible and empty.
                c.status === "Forming" && !c.members.some((m) => m.you)
                  ? [emptySeat, ...c.members]
                  : [...c.members].sort((a, b) => Number(b.you) - Number(a.you))
              }
              round={c.round}
              totalRounds={c.totalRounds}
              status={c.status}
              centerTop="In the pot"
              centerMain={formatAmount(c.pot.total)}
              centerBottom={
                c.status === "Forming"
                  ? "Not started yet"
                  : c.status === "Completed"
                    ? "Circle ended"
                    : `Round ${c.round} of ${c.totalRounds}`
              }
            />
          </div>
          <PotBreakdown c={c} />
        </div>
      </Section>

      {you && (
        <Section
          title="Your numbers"
          aside={<Chip tone={statusTone(you.status)}>{you.status}</Chip>}
        >
          <dl className="grid grid-cols-2 gap-x-4 gap-y-3 sm:grid-cols-3">
            <Stat label="Your savings" value={you.savings} strong />
            <Stat label="Your wallet" value={you.wallet} />
            <Stat label="Loan to repay" value={you.loanOwed} />
            <Stat label="Your backing" value={you.pledged} />
            <Stat label="Earned from backing" value={you.rewards} />
            <Stat label="Ready to collect" value={you.claimable} />
          </dl>
        </Section>
      )}

      <Section
        title="Members"
        aside={
          <span className="text-sm text-ink-2">{c.members.length} people</span>
        }
      >
        <ul className="-mx-1 divide-y divide-line">
          {c.members.map((m) => {
            const tone = memberTone(m.status, m.lost, m.debt);
            return (
              <li
                key={m.address}
                className={`px-1 py-3 ${m.you ? "rounded-lg bg-accent-soft/60" : ""} ${tone === "bad" ? "border-l-4 border-l-bad pl-3" : ""}`}
              >
                <div className="flex items-center justify-between gap-3">
                  <div className="min-w-0">
                    <p className="truncate font-semibold text-ink">
                      {m.name}
                      {m.you && m.name.toLowerCase() !== "you" && (
                        <span className="font-normal text-ink-2"> (you)</span>
                      )}
                    </p>
                    {m.role && <p className="text-xs text-ink-2">{m.role}</p>}
                  </div>
                  <Chip tone={statusTone(m.status)}>{m.status}</Chip>
                </div>
                <dl className="mt-2 grid grid-cols-4 gap-2 text-sm">
                  <MemberStat label="Savings" value={m.savings} />
                  <MemberStat label="Loan" value={m.loanOwed} />
                  <MemberStat label="Backing" value={m.pledged} />
                  <MemberStat label="Lost" value={m.lost} bad />
                </dl>
                {!isZero(m.debt) && (
                  <p className="mt-2 text-sm font-semibold text-bad">
                    Still owes {formatAmount(m.debt)} mUSDC
                  </p>
                )}
              </li>
            );
          })}
        </ul>
      </Section>

      <Section title="Loans">
        {c.loans.length === 0 ? (
          <p className="text-sm text-ink-2">
            No loans yet. Members can borrow after saving for 3 rounds.
          </p>
        ) : (
          <ul className="grid gap-3">
            {c.loans.map((l) => (
              <li key={l.id} className="rounded-xl border border-line p-3">
                <div className="flex items-center justify-between gap-3">
                  <p className="font-semibold">
                    {l.borrower} borrowed{" "}
                    <span className="num">{formatAmount(l.amount)}</span>
                  </p>
                  <Chip tone={loanTone(l.status)}>{l.status}</Chip>
                </div>
                {l.backers.length > 0 ? (
                  <table className="mt-2 w-full text-sm">
                    <caption className="sr-only">
                      Backers of {l.borrower}'s loan
                    </caption>
                    <thead>
                      <tr className="text-left text-xs text-ink-2">
                        <th scope="col" className="py-1 font-normal">
                          Backed by
                        </th>
                        <th scope="col" className="py-1 text-right font-normal">
                          Backing
                        </th>
                        <th scope="col" className="py-1 text-right font-normal">
                          Earned
                        </th>
                        <th scope="col" className="py-1 text-right font-normal">
                          Lost
                        </th>
                      </tr>
                    </thead>
                    <tbody>
                      {l.backers.map((b) => (
                        <tr key={b.name}>
                          <th
                            scope="row"
                            className="py-1 text-left font-medium"
                          >
                            {b.name}
                          </th>
                          <td className="py-1 text-right">
                            <Amount value={b.amount} />
                          </td>
                          <td
                            className={`py-1 text-right ${isZero(b.earned) ? "text-ink-2" : "text-good font-semibold"}`}
                          >
                            <Amount value={b.earned} />
                          </td>
                          <td
                            className={`py-1 text-right ${isZero(b.lost) ? "text-ink-2" : "text-bad font-semibold"}`}
                          >
                            <Amount value={b.lost} />
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                ) : (
                  <p className="mt-1 text-sm text-ink-2">No backers yet.</p>
                )}
              </li>
            ))}
          </ul>
        )}
      </Section>

      {c.proposals.length > 0 && (
        <Section title="Votes">
          <ul className="grid gap-3">
            {c.proposals.map((p) => {
              const total = p.yes + p.no;
              return (
                <li key={p.id} className="rounded-xl border border-line p-3">
                  <div className="flex items-start justify-between gap-3">
                    <p className="font-semibold">{p.title}</p>
                    <Chip
                      tone={
                        /pass|done|appl/i.test(p.status)
                          ? "ok"
                          : /fail|reject/i.test(p.status)
                            ? "bad"
                            : "idle"
                      }
                    >
                      {p.status}
                    </Chip>
                  </div>
                  <div
                    className="mt-2 flex h-2 overflow-hidden rounded-full bg-paper"
                    aria-hidden
                  >
                    <div
                      className="h-full bg-good"
                      style={{
                        width: `${total ? (p.yes / c.members.length) * 100 : 0}%`,
                      }}
                    />
                    <div
                      className="h-full bg-bad"
                      style={{
                        width: `${total ? (p.no / c.members.length) * 100 : 0}%`,
                      }}
                    />
                  </div>
                  <p className="mt-1.5 text-sm text-ink-2">
                    {p.yes} yes, {p.no} no
                    {p.youVoted ? ". You voted." : ". You haven't voted."}
                  </p>
                </li>
              );
            })}
          </ul>
        </Section>
      )}
    </div>
  );
}

function MemberStat({
  label,
  value,
  bad = false,
}: {
  label: string;
  value: string;
  bad?: boolean;
}) {
  const zero = isZero(value);
  return (
    <div className="min-w-0">
      <dt className="text-xs text-ink-2">{label}</dt>
      <dd
        className={`truncate ${zero ? "text-ink-2" : bad ? "font-bold text-bad" : "font-semibold text-ink"}`}
      >
        <Amount value={value} />
      </dd>
    </div>
  );
}

const loanTone = (status: string) =>
  /not repaid|unpaid|cover|default|paus|lost/i.test(status)
    ? "bad"
    : /behind|late/i.test(status)
      ? "warn"
      : /need|wait|queue|request/i.test(status)
        ? "idle"
        : "ok";
