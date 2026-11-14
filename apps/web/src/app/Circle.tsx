import { kuberCircleAbi, mockUsdcAbi } from "@kuber/shared";
import { ChevronDown, Clock, ExternalLink, Lock, Share2 } from "lucide-react";
import { type ReactNode, useCallback, useEffect, useState } from "react";
import { type Abi, encodeAbiParameters } from "viem";
import { CircleView } from "../components/CircleView";
import { Button, Section } from "../components/ui";
import { formatAmount, isZero } from "../lib/money";
import type { Hex } from "../types";
import { ActivityList } from "./Activity";
import {
  type ActivityItem,
  type AppCircleDetail,
  appApi,
  toMs,
} from "./appApi";
import { useApp } from "./ctx";
import { InvitePeople, shareCircle } from "./Invite";
import { AppBar, type Go, Page } from "./Screens";
import { type Send, TxSteps, useTx } from "./TxStatus";

const circleAbi = kuberCircleAbi as Abi;
const usdcAbi = mockUsdcAbi as Abi;
const USDC = 1_000_000n;

/** "350" or "350.5" → base units; null when not a positive amount with at most 2 decimals. */
function toBase(v: string): bigint | null {
  const m = /^(\d+)(?:\.(\d{1,2}))?$/.exec(v.trim());
  if (!m) return null;
  const b = BigInt(m[1]) * USDC + BigInt((m[2] ?? "").padEnd(6, "0"));
  return b > 0n ? b : null;
}

function useServerClock(serverNow: number | string | undefined) {
  const [offset, setOffset] = useState(0);
  const [, setTick] = useState(0);
  useEffect(() => {
    const ms = toMs(serverNow);
    if (ms !== null) setOffset(Date.now() - ms);
  }, [serverNow]);
  useEffect(() => {
    const id = setInterval(() => setTick((t) => t + 1), 1000);
    return () => clearInterval(id);
  }, []);
  return Date.now() - offset;
}

function left(ms: number | null, now: number): string | null {
  if (ms === null) return null;
  const s = Math.max(0, Math.round((ms - now) / 1000));
  if (s >= 3600)
    return `${Math.floor(s / 3600)} h ${Math.floor((s % 3600) / 60)} min`;
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
}

const RULE_FIELDS = [
  { field: 7, label: "Fee for leaving early" },
  { field: 1, label: "Interest on loans from your own savings" },
  { field: 5, label: "Fine for a late saving" },
  { field: 6, label: "Fine for a late repayment" },
  { field: 0, label: "Share of your savings you can borrow" },
];

export function CirclePage({ address, go }: { address: Hex; go: Go }) {
  const { chain } = useApp();
  const [c, setC] = useState<AppCircleDetail | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [activity, setActivity] = useState<ActivityItem[] | null>(null);

  const load = useCallback(async () => {
    try {
      const [detail, act] = await Promise.all([
        appApi.circle(address),
        appApi.activity(address).catch(() => null),
      ]);
      setC(detail);
      if (act) setActivity(act);
      setError(null);
    } catch (err) {
      setError(
        err instanceof Error ? err.message : "Couldn't load this circle.",
      );
    }
  }, [address]);

  // Rounds close on their own, so keep the page fresh.
  useEffect(() => {
    load();
    const id = setInterval(load, 5000);
    return () => clearInterval(id);
  }, [load]);

  const names = Object.fromEntries(
    (c?.members ?? []).map((m) => [m.address.toLowerCase(), m.name]),
  );

  return (
    <div className="min-h-dvh">
      <AppBar go={go} back={() => go({ name: "home" })} />
      <Page>
        {error && !c && (
          <div role="alert" className="rounded-2xl bg-bad-soft p-4">
            <p className="font-semibold text-ink">{error}</p>
            <Button variant="secondary" onClick={load} className="mt-3">
              Try again
            </Button>
          </div>
        )}
        {!c && !error && (
          <div
            className="h-64 animate-pulse rounded-2xl bg-line/60 motion-reduce:animate-none"
            role="status"
          >
            <span className="sr-only">Loading the circle</span>
          </div>
        )}
        {c && (
          <div className="grid gap-4">
            <CircleView
              c={c}
              top={<Actions c={c} reload={load} names={names} />}
            />
            <Section title="Activity">
              <ActivityList
                items={activity}
                circle={address}
                names={names}
                empty="No transactions in this circle yet."
              />
            </Section>
            <Section title="On the chain">
              <p className="text-sm text-ink-2">This circle's contract</p>
              <p className="num mt-0.5 break-all font-mono text-sm text-ink">
                {address}
              </p>
              {chain.explorer ? (
                <a
                  href={`${chain.explorer}/address/${address}`}
                  target="_blank"
                  rel="noreferrer"
                  className="mt-2 inline-flex min-h-11 items-center gap-2 font-semibold text-brand underline underline-offset-4"
                >
                  <ExternalLink aria-hidden className="size-4" /> View on
                  Snowtrace
                </a>
              ) : (
                <p className="mt-2 text-sm text-ink-2">
                  Local test chain — not on a public explorer.
                </p>
              )}
            </Section>
          </div>
        )}
      </Page>
    </div>
  );
}

function Panel({ title, children }: { title: string; children: ReactNode }) {
  return (
    <div className="rounded-xl border border-line p-3">
      <h3 className="font-semibold text-ink">{title}</h3>
      <div className="mt-2 grid gap-2">{children}</div>
    </div>
  );
}

function Actions({
  c,
  reload,
  names,
}: {
  c: AppCircleDetail;
  reload: () => Promise<void>;
  names: Record<string, string>;
}) {
  const { chain, reader, signer, me, refreshMe } = useApp();
  const live = c.live;
  const you = live.you;
  const after = useCallback(() => {
    reload();
    refreshMe().catch(() => {});
  }, [reload, refreshMe]);
  const tx = useTx(after);
  const now = useServerClock(live.now);
  const circle = c.address;
  const contribution = BigInt(c.contribution);
  const [amount, setAmount] = useState("");
  const [repayIn, setRepayIn] = useState(2);
  const [backAmounts, setBackAmounts] = useState<Record<number, string>>({});
  const [ruleField, setRuleField] = useState(7);
  const [ruleValue, setRuleValue] = useState("2");
  const [formError, setFormError] = useState<string | null>(null);

  const call = (functionName: string, args: unknown[] = []) => ({
    address: circle,
    abi: circleAbi,
    functionName,
    args,
  });

  /** Approve the circle to collect `needed` if it may not already. */
  async function ensureAllowance(send: Send, needed: bigint) {
    const allowed = (await reader.readContract({
      address: chain.usdc,
      abi: usdcAbi,
      functionName: "allowance",
      args: [signer.address, circle],
    })) as bigint;
    if (allowed >= needed) return;
    // Allow enough for the rest of the circle (savings to come + what is owed), so rounds can close smoothly.
    const amount = needed > cover ? needed : cover;
    await send(
      `Allow the circle to collect up to ${formatAmount(amount)} mUSDC`,
      {
        address: chain.usdc,
        abi: usdcAbi,
        functionName: "approve",
        args: [circle, amount],
      },
    );
  }

  const roundsLeft = BigInt(
    Math.max(1, c.totalRounds - Math.max(c.round, 1) + 1),
  );
  const owed = you.activeLoan ? BigInt(you.activeLoan.owed || "0") : 0n;
  // Savings for the rounds still to come plus what is owed, with a 10% cushion.
  const cover = you.suggestedAllowance
    ? BigInt(you.suggestedAllowance)
    : ((contribution * roundsLeft + owed) * 11n) / 10n;
  const saveAmount = you.saveAmount ? BigInt(you.saveAmount) : contribution;
  const nextDue =
    you.activeLoan?.nextDue && typeof you.activeLoan.nextDue === "object"
      ? you.activeLoan.nextDue
      : null;
  const maxRepay = Math.max(1, you.maxRepayRounds ?? 3);

  const startsAt = toMs(live.startsAt);
  const roundEnds = toMs(live.roundEndsAt);
  const myRequests = live.requests.filter((r) => r.mine);
  const others = live.requests.filter(
    (r) => !r.mine && !isZero(r.needsBacking),
  );
  const openVotes = live.proposals.filter((p) => p.open);
  const claimable = c.you ? BigInt(c.you.claimable || "0") : 0n;

  return (
    <section
      aria-label="What you can do"
      className="grid gap-3 rounded-2xl border border-line bg-surface p-4"
    >
      {live.practiceMembers > 0 && (
        <p className="text-xs font-semibold text-brand">
          Includes {live.practiceMembers} practice member
          {live.practiceMembers > 1 ? "s" : ""} run by Kuber
        </p>
      )}
      {c.status === "Forming" && (
        <p className="flex items-center gap-2 text-sm text-ink">
          <Clock aria-hidden className="size-4 text-brand" />
          <span>
            Starts in{" "}
            <span className="num font-semibold">{left(startsAt, now)}</span> ·{" "}
            {c.members.length} joined (needs 5 to start)
          </span>
        </p>
      )}
      {c.status === "Active" && (
        <p className="flex items-center gap-2 text-sm text-ink">
          <Clock aria-hidden className="size-4 text-brand" />
          {roundEnds !== null && c.round <= c.totalRounds ? (
            <span>
              Round {c.round} of {c.totalRounds} ends in{" "}
              <span className="num font-semibold">{left(roundEnds, now)}</span>
            </span>
          ) : (
            <span>The last round has ended. The circle is closing…</span>
          )}
        </p>
      )}
      {c.status === "Active" && live.locked && (
        <p className="flex items-start gap-2 rounded-xl bg-accent-soft p-3 text-sm text-ink">
          <Lock aria-hidden className="mt-0.5 size-4 shrink-0 text-warn" />
          {live.lockedReason ??
            "The round is closing, so borrowing and backing are paused until the next round starts."}
        </p>
      )}

      <TxSteps steps={tx.steps} note={tx.note} circle={circle} names={names} />
      {formError && (
        <p role="alert" className="text-sm font-semibold text-bad">
          {formError}
        </p>
      )}

      {/* Forming */}
      {c.status === "Forming" && !you.isMember && (
        <Panel title={you.invited ? "You're invited" : "Want to join?"}>
          {you.invited ? (
            <>
              <p className="text-sm text-ink-2">
                Everyone saves {formatAmount(c.contribution)} mUSDC each round
                for {c.totalRounds} rounds. Joining allows the circle to collect
                your savings when each round closes.
              </p>
              <Button
                busy={tx.busy}
                disabled={tx.busy}
                onClick={() =>
                  tx.run(async (send) => {
                    await ensureAllowance(
                      send,
                      you.suggestedAllowance
                        ? BigInt(you.suggestedAllowance)
                        : contribution * BigInt(c.totalRounds),
                    );
                    await send("Join the circle", call("join"));
                    return "You're in. Your savings are collected when each round closes.";
                  })
                }
              >
                Join this circle
              </Button>
            </>
          ) : you.requested ? (
            <p className="text-sm text-ink-2">
              You asked to join. The person who created this circle can invite
              you; then a Join button appears here.
            </p>
          ) : (
            <>
              <p className="text-sm text-ink-2">
                Only invited people can join. Ask to join and the person who
                created it can invite you.
              </p>
              <Button
                variant="secondary"
                busy={tx.busy}
                disabled={tx.busy}
                onClick={() =>
                  tx.run(async (send) => {
                    await send("Ask to join", call("requestToJoin"));
                    return "Asked. The creator sees your request and can invite you.";
                  })
                }
              >
                Ask to join
              </Button>
            </>
          )}
        </Panel>
      )}
      {c.status === "Forming" && you.isMember && !live.isCreator && (
        <p className="text-sm text-ink">
          You're in. The circle starts when the countdown ends.
        </p>
      )}
      {c.status === "Forming" && live.isCreator && (
        <>
          <Panel title="Fill your circle">
            <p className="text-sm text-ink-2">
              A circle needs 5 members to start. Practice members are run by
              Kuber: they save every round and vote yes, and one can back your
              loan. They never borrow.
            </p>
            {(live.canAddPractice ?? live.practiceMembers < 4) && (
              <Button
                variant="secondary"
                busy={tx.busy}
                disabled={tx.busy}
                onClick={() =>
                  tx.run(async () => {
                    const count = Math.min(
                      live.practiceInvited ?? 4 - live.practiceMembers,
                      Math.max(1, (live.minMembers ?? 5) - c.members.length),
                    );
                    tx.setNote(
                      `Adding ${count} practice member${count > 1 ? "s" : ""}. Each joins with its own transaction…`,
                    );
                    await appApi.practiceMembers(circle, count);
                    return `${count} practice member${count > 1 ? "s" : ""} joined. Look for them under Members and in Activity.`;
                  })
                }
              >
                Add practice members
              </Button>
            )}
            <Button
              variant="quiet"
              onClick={async () =>
                tx.setNote(await shareCircle(circle, c.name))
              }
            >
              <Share2 aria-hidden className="size-4" /> Share the circle link
            </Button>
          </Panel>
          {(live.joinRequests ?? []).length > 0 && (
            <Panel title="Asked to join">
              {(live.joinRequests ?? []).map((j) => (
                <div
                  key={j.address}
                  className="flex items-center justify-between gap-2"
                >
                  <span className="font-semibold text-ink">{j.name}</span>
                  <Button
                    variant="secondary"
                    className="min-h-11 px-3 text-sm"
                    disabled={tx.busy}
                    onClick={() =>
                      tx.run(async (send) => {
                        await send(
                          `Invite ${j.name}`,
                          call("invite", [j.address]),
                        );
                        return `${j.name} is invited and can join now.`;
                      })
                    }
                  >
                    Invite
                  </Button>
                </div>
              ))}
            </Panel>
          )}
          <Panel title="Invite people">
            <InvitePeople
              circle={circle}
              existing={live.invites ?? []}
              onChanged={reload}
            />
          </Panel>
        </>
      )}

      {/* Active */}
      {c.status === "Active" && you.isMember && (
        <>
          <div className="grid grid-cols-1 gap-2 sm:grid-cols-2">
            {(you.canSave ?? true) ? (
              <Button
                busy={tx.busy}
                disabled={tx.busy}
                onClick={() =>
                  tx.run(async (send) => {
                    await ensureAllowance(send, saveAmount);
                    await send(
                      `Pay ${formatAmount(saveAmount)} mUSDC now`,
                      call("payNow"),
                    );
                    return "Paid for this round. Your savings count it when the round closes.";
                  })
                }
              >
                Save now ({formatAmount(saveAmount)} mUSDC)
              </Button>
            ) : (
              you.paidThisRound && (
                <p className="self-center text-sm text-ink">
                  You've paid for round {c.round}.
                </p>
              )
            )}
            {(you.canClaim ?? claimable > 0n) && claimable > 0n && (
              <Button
                busy={tx.busy}
                disabled={tx.busy}
                onClick={() =>
                  tx.run(async (send) => {
                    await send(
                      `Take your loan: ${formatAmount(claimable)} mUSDC`,
                      call("claim"),
                    );
                    await ensureAllowance(send, cover);
                    return "The loan is in your wallet. Repayments are collected when each round closes.";
                  })
                }
              >
                Take {formatAmount(claimable)} mUSDC
              </Button>
            )}
          </div>

          {you.activeLoan && (
            <Panel title="Your loan">
              <p className="text-sm text-ink">
                You owe{" "}
                <span className="num font-semibold">
                  {formatAmount(you.activeLoan.owed)}
                </span>{" "}
                mUSDC.
                {nextDue &&
                  ` The next payment of ${formatAmount(nextDue.amount)} mUSDC${nextDue.round ? ` is due in round ${nextDue.round}` : ""}; it is collected when that round closes.`}
              </p>
              {(you.canRepayAll ?? true) && (
                <Button
                  variant="secondary"
                  busy={tx.busy}
                  disabled={tx.busy}
                  onClick={() =>
                    tx.run(async (send) => {
                      await ensureAllowance(send, owed);
                      await send(
                        `Repay all ${formatAmount(owed)} mUSDC`,
                        call("repayAll"),
                      );
                      return "Loan repaid.";
                    })
                  }
                >
                  Repay everything now
                </Button>
              )}
            </Panel>
          )}

          {myRequests.map((r) => (
            <Panel
              key={r.id}
              title={`Your loan request: ${formatAmount(r.amount)} mUSDC`}
            >
              <p className="text-sm text-ink">
                {isZero(r.needsBacking)
                  ? "Fully backed. It's paid out when the round closes."
                  : `${formatAmount(r.backedSoFar)} backed so far. It still needs ${formatAmount(r.needsBacking)} mUSDC of backing.`}
              </p>
              {!isZero(r.needsBacking) && live.practiceMembers > 0 && (
                <Button
                  variant="secondary"
                  busy={tx.busy}
                  disabled={tx.busy}
                  onClick={() =>
                    tx.run(async () => {
                      tx.setNote("Asking a practice member to back you…");
                      await appApi.practiceBack(circle, r.id);
                      return "A practice member backed your request. It's paid out when the round closes.";
                    })
                  }
                >
                  Ask a practice member to back me
                </Button>
              )}
            </Panel>
          ))}

          {!you.activeLoan && myRequests.length === 0 && (
            <Panel title="Borrow">
              {you.canBorrow ? (
                <form
                  noValidate
                  className="grid gap-2"
                  onSubmit={(e) => {
                    e.preventDefault();
                    const a = toBase(amount);
                    const limit = BigInt(you.loanLimit || "0");
                    if (a === null)
                      return setFormError(
                        "Enter an amount above zero, up to 2 decimals.",
                      );
                    if (limit > 0n && a > limit)
                      return setFormError(
                        `You can ask for up to ${formatAmount(limit)} mUSDC.`,
                      );
                    setFormError(null);
                    tx.run(async (send) => {
                      await send(
                        `Ask to borrow ${formatAmount(a)} mUSDC over ${repayIn} round${repayIn > 1 ? "s" : ""}`,
                        call("requestLoan", [
                          a,
                          BigInt(Math.min(repayIn, maxRepay)),
                          BigInt(you.offeredRateBps ?? 800),
                          0n,
                        ]),
                      );
                      setAmount("");
                      return "Asked. Any part your own savings can't cover needs backers; the loan is paid out when the round closes.";
                    });
                  }}
                >
                  <p className="text-sm text-ink-2">
                    You can ask for up to{" "}
                    <span className="num font-semibold text-ink">
                      {formatAmount(you.loanLimit)}
                    </span>{" "}
                    mUSDC.
                  </p>
                  <div className="grid grid-cols-[1fr_auto] gap-2">
                    <label className="sr-only" htmlFor="borrow-amount">
                      Amount to borrow
                    </label>
                    <input
                      id="borrow-amount"
                      inputMode="decimal"
                      placeholder="Amount"
                      value={amount}
                      onChange={(e) => setAmount(e.target.value)}
                      className="num block min-h-12 w-full min-w-0 rounded-xl border border-line bg-surface px-4 text-base text-ink outline-none focus:border-brand focus:ring-2 focus:ring-brand/30"
                    />
                    <label className="sr-only" htmlFor="borrow-rounds">
                      Repay over
                    </label>
                    <select
                      id="borrow-rounds"
                      value={repayIn}
                      onChange={(e) => setRepayIn(Number(e.target.value))}
                      className="min-h-12 rounded-xl border border-line bg-surface px-3 text-base text-ink"
                    >
                      {[1, 2, 3]
                        .filter((n) => n <= maxRepay)
                        .map((n) => (
                          <option key={n} value={n}>
                            Repay in {n} round{n > 1 ? "s" : ""}
                          </option>
                        ))}
                    </select>
                  </div>
                  <Button
                    type="submit"
                    variant="secondary"
                    busy={tx.busy}
                    disabled={tx.busy}
                  >
                    Ask to borrow
                  </Button>
                </form>
              ) : (
                <p className="text-sm text-ink-2">
                  {you.reasonNoBorrow ?? "You can't borrow right now."}
                </p>
              )}
            </Panel>
          )}

          {others.length > 0 && (
            <Panel title="Back a loan request">
              <p className="text-sm text-ink-2">
                Backing puts some of your savings on hold for someone's loan.
                You earn interest when they repay; if they stop paying, your
                backing helps cover it.
              </p>
              {others.map((r) => (
                <div key={r.id} className="rounded-lg bg-paper p-2.5">
                  <p className="text-sm text-ink">
                    <span className="font-semibold">{r.borrower}</span> asks for{" "}
                    <span className="num">{formatAmount(r.amount)}</span>; needs{" "}
                    <span className="num font-semibold">
                      {formatAmount(r.needsBacking)}
                    </span>{" "}
                    more backing.
                  </p>
                  {r.canBack !== false && (
                    <div className="mt-2 grid grid-cols-[1fr_auto] gap-2">
                      <label className="sr-only" htmlFor={`back-${r.id}`}>
                        Amount to back
                      </label>
                      <input
                        id={`back-${r.id}`}
                        inputMode="decimal"
                        placeholder={formatAmount(r.needsBacking).replace(
                          /,/g,
                          "",
                        )}
                        value={backAmounts[r.id] ?? ""}
                        onChange={(e) =>
                          setBackAmounts((b) => ({
                            ...b,
                            [r.id]: e.target.value,
                          }))
                        }
                        className="num block min-h-11 w-full min-w-0 rounded-xl border border-line bg-surface px-3 text-base text-ink"
                      />
                      <Button
                        variant="secondary"
                        className="min-h-11"
                        busy={tx.busy}
                        disabled={tx.busy}
                        onClick={() => {
                          const raw =
                            backAmounts[r.id] ||
                            formatAmount(r.needsBacking).replace(/,/g, "");
                          const a = toBase(raw);
                          if (a === null)
                            return setFormError("Enter an amount to back.");
                          const cap = BigInt(r.maxBack ?? r.needsBacking);
                          if (a > cap)
                            return setFormError(
                              `You can back ${r.borrower} with up to ${formatAmount(cap)} mUSDC.`,
                            );
                          setFormError(null);
                          tx.run(async (send) => {
                            await send(
                              `Back ${r.borrower}'s loan with ${formatAmount(a)} mUSDC`,
                              call("vouch", [BigInt(r.id), a]),
                            );
                            return `You backed ${r.borrower}.`;
                          });
                        }}
                      >
                        Back
                      </Button>
                    </div>
                  )}
                </div>
              ))}
            </Panel>
          )}

          {openVotes.length > 0 && (
            <Panel title="Votes">
              {openVotes.map((p) => (
                <div key={p.id} className="rounded-lg bg-paper p-2.5">
                  <p className="text-sm font-semibold text-ink">{p.title}</p>
                  <p className="text-sm text-ink-2">
                    {p.yes} yes, {p.no} no · needs {p.needed} yes to pass
                  </p>
                  {p.youVoted ? (
                    <p className="mt-1 text-sm text-ink">You voted.</p>
                  ) : you.canVote ? (
                    <div className="mt-2 grid grid-cols-2 gap-2">
                      <Button
                        variant="secondary"
                        className="min-h-11"
                        disabled={tx.busy}
                        onClick={() =>
                          tx.run(async (send) => {
                            await send(
                              `Vote yes: ${p.title}`,
                              call("vote", [BigInt(p.id), true]),
                            );
                            return "Vote counted. Votes are tallied when the round closes.";
                          })
                        }
                      >
                        Vote yes
                      </Button>
                      <Button
                        variant="secondary"
                        className="min-h-11"
                        disabled={tx.busy}
                        onClick={() =>
                          tx.run(async (send) => {
                            await send(
                              `Vote no: ${p.title}`,
                              call("vote", [BigInt(p.id), false]),
                            );
                            return "Vote counted. Votes are tallied when the round closes.";
                          })
                        }
                      >
                        Vote no
                      </Button>
                    </div>
                  ) : null}
                </div>
              ))}
            </Panel>
          )}

          {(you.canPropose ?? true) && (
            <details className="group rounded-xl border border-line">
              <summary className="flex min-h-12 cursor-pointer list-none items-center justify-between px-3 font-semibold text-ink">
                Suggest a rule change
                <ChevronDown
                  aria-hidden
                  className="size-5 text-ink-2 transition-transform group-open:rotate-180"
                />
              </summary>
              <form
                noValidate
                className="grid gap-2 px-3 pb-3"
                onSubmit={(e) => {
                  e.preventDefault();
                  const pct = Number(ruleValue);
                  if (!/^\d+(\.\d{1,2})?$/.test(ruleValue) || pct > 100)
                    return setFormError("Enter a percent from 0 to 100.");
                  setFormError(null);
                  const bps = BigInt(Math.round(pct * 100));
                  const label =
                    RULE_FIELDS.find((f) => f.field === ruleField)?.label ??
                    "Rule";
                  tx.run(async (send) => {
                    await send(
                      `Suggest: ${label} → ${pct}%`,
                      call("propose", [
                        0,
                        encodeAbiParameters(
                          [{ type: "uint8" }, { type: "uint256" }],
                          [ruleField, bps],
                        ),
                      ]),
                    );
                    return "Suggested. Members vote this round; it changes when the round closes if more than half say yes.";
                  });
                }}
              >
                <label className="text-sm text-ink-2" htmlFor="rule-field">
                  Rule
                </label>
                <select
                  id="rule-field"
                  value={ruleField}
                  onChange={(e) => setRuleField(Number(e.target.value))}
                  className="min-h-12 rounded-xl border border-line bg-surface px-3 text-base text-ink"
                >
                  {RULE_FIELDS.map((f) => {
                    const now = live.rules?.find((r) => r.field === f.field);
                    return (
                      <option key={f.field} value={f.field}>
                        {f.label}
                        {now ? ` (now ${now.currentText})` : ""}
                      </option>
                    );
                  })}
                </select>
                <label className="text-sm text-ink-2" htmlFor="rule-value">
                  New value (%)
                </label>
                <input
                  id="rule-value"
                  inputMode="decimal"
                  value={ruleValue}
                  onChange={(e) => setRuleValue(e.target.value.trim())}
                  className="num block min-h-12 w-full rounded-xl border border-line bg-surface px-4 text-base text-ink"
                />
                <Button
                  type="submit"
                  variant="secondary"
                  busy={tx.busy}
                  disabled={tx.busy}
                >
                  Suggest this change
                </Button>
              </form>
            </details>
          )}

          {you.pendingLeave ? (
            <p className="text-sm text-ink-2">
              You asked to leave. It happens when the round closes.
            </p>
          ) : (
            (you.canLeave ?? !live.isCreator) && (
              <Button
                variant="quiet"
                disabled={tx.busy}
                onClick={() => {
                  if (
                    !confirm(
                      "Leave this circle? You get your savings back minus the fee for leaving early.",
                    )
                  )
                    return;
                  tx.run(async (send) => {
                    await send("Ask to leave the circle", call("requestLeave"));
                    return "You'll leave when the round closes.";
                  });
                }}
              >
                Leave this circle
              </Button>
            )
          )}
        </>
      )}
      {c.status === "Active" && !you.isMember && (
        <p className="text-sm text-ink-2">
          This circle has started. You're not a member.
        </p>
      )}

      {/* Completed */}
      {c.status === "Completed" &&
        c.you &&
        (c.you.paidOut === undefined && (you.canCollect ?? true) ? (
          <Panel title="The circle has ended">
            <p className="text-sm text-ink-2">
              Your share-out is your savings plus your part of what the circle
              earned.
            </p>
            <Button
              busy={tx.busy}
              disabled={tx.busy}
              onClick={() =>
                tx.run(async (send) => {
                  await send("Collect your share-out", call("withdraw"));
                  return "Your share-out is in your wallet.";
                })
              }
            >
              Collect my share-out
            </Button>
          </Panel>
        ) : (
          c.you.paidOut !== undefined && (
            <p className="rounded-xl bg-good-soft p-3 text-sm font-semibold text-ink">
              You collected {formatAmount(c.you.paidOut)} mUSDC. Your wallet now
              has {formatAmount(me.musdc)} mUSDC.
            </p>
          )
        ))}
      {c.status === "Cancelled" && (
        <p className="text-sm text-ink-2">
          This circle was called off: not enough members had joined when it was
          due to start.
        </p>
      )}
    </section>
  );
}
