import { kuberFactoryAbi, mockUsdcAbi } from "@kuber/shared";
import { ChevronDown } from "lucide-react";
import { useState } from "react";
import { type Abi, parseEventLogs } from "viem";
import { Button, Section } from "../components/ui";
import { ApiError } from "../lib/errors";
import { formatAmount } from "../lib/money";
import type { Hex } from "../types";
import { appApi } from "./appApi";
import { useApp } from "./ctx";
import { InvitePeople } from "./Invite";
import { AppBar, type Go, Page } from "./Screens";
import { TxSteps, useTx } from "./TxStatus";

const USDC = 1_000_000n;

const ROUND_LENGTHS = [
  { seconds: 120, label: "2 minutes" },
  { seconds: 600, label: "10 minutes" },
  { seconds: 3600, label: "1 hour" },
  { seconds: 86400, label: "1 day" },
];
const STARTS = [
  { seconds: 120, label: "2 minutes" },
  { seconds: 600, label: "10 minutes" },
  { seconds: 3600, label: "1 hour" },
];

/** Sensible defaults (the tutorial's circle). Shown read-only under "Rules". */
export const RULES = {
  ownLtvBps: 9_000,
  ownRateBps: 300,
  perLoanMaxBps: 5_000,
  fastLaneBps: 3_000,
  penaltyBps: 1_000,
  contribFineBps: 100,
  installFineBps: 300,
  exitFeeBps: 300,
  managerFeeBps: 0,
  alloc: { loan: 4_000, aave: 3_000, lp: 2_000, cash: 1_000 },
};
const RULE_LINES = [
  "Borrow up to 90% of your own savings, more with backers",
  "Interest on loans from your own savings: 3%",
  "One loan can be up to 50% of the money kept for loans",
  "Fine for a late saving: 1%; for a late repayment: 3%",
  "Fee for leaving early: 3%",
  "You can borrow after saving for 3 rounds; repay over up to 3 rounds",
  "Money plan: 40% kept for loans, 30% + 20% invested, 10% cash",
];

const field =
  "mt-2 block min-h-12 w-full rounded-xl border border-line bg-surface px-4 text-base text-ink outline-none focus:border-brand focus:ring-2 focus:ring-brand/30 aria-invalid:border-bad";

function Choice<T extends number>({
  legend,
  options,
  value,
  onChange,
  hint,
}: {
  legend: string;
  options: { seconds: T; label: string }[];
  value: T;
  onChange: (v: T) => void;
  hint?: string;
}) {
  return (
    <fieldset className="mt-5">
      <legend className="font-semibold text-ink">{legend}</legend>
      {hint && <p className="text-sm text-ink-2">{hint}</p>}
      <div className="mt-2 grid grid-cols-2 gap-2 sm:grid-cols-4">
        {options.map((o) => (
          <label
            key={o.seconds}
            className={`flex min-h-12 cursor-pointer items-center justify-center rounded-xl border px-3 text-center text-sm font-semibold has-[:focus-visible]:ring-2 has-[:focus-visible]:ring-brand ${value === o.seconds ? "border-brand bg-brand-soft text-brand" : "border-line bg-surface text-ink"}`}
          >
            <input
              type="radio"
              name={legend}
              className="sr-only"
              checked={value === o.seconds}
              onChange={() => onChange(o.seconds)}
            />
            {o.label}
          </label>
        ))}
      </div>
    </fieldset>
  );
}

export function CreatePage({ go }: { go: Go }) {
  const { chain, reader, refreshMe } = useApp();
  const [name, setName] = useState("");
  const [saving, setSaving] = useState("100");
  const [rounds, setRounds] = useState("6");
  const [roundLength, setRoundLength] = useState(120);
  const [startsIn, setStartsIn] = useState(120);
  const [members, setMembers] = useState("5");
  const [errors, setErrors] = useState<Record<string, string>>({});
  const [created, setCreated] = useState<Hex | null>(null);
  const tx = useTx();

  function validate() {
    const e: Record<string, string> = {};
    const n = name.trim();
    if (n.length < 3 || n.length > 40) e.name = "Use 3 to 40 characters.";
    if (
      !/^\d+(\.\d{1,2})?$/.test(saving) ||
      Number(saving) < 1 ||
      Number(saving) > 100_000
    )
      e.saving = "Enter an amount from 1 to 100,000 (up to 2 decimals).";
    const r = Number(rounds);
    if (!Number.isInteger(r) || r < 6 || r > 60)
      e.rounds = "Pick 6 to 60 rounds (you can borrow after saving for 3).";
    const m = Number(members);
    if (!Number.isInteger(m) || m < 5 || m > 50)
      e.members = "Pick 5 to 50 members.";
    setErrors(e);
    return Object.keys(e).length === 0;
  }

  async function create(ev: React.FormEvent) {
    ev.preventDefault();
    if (!validate()) return;
    const [whole, frac = ""] = saving.split(".");
    const contribution = BigInt(whole) * USDC + BigInt(frac.padEnd(6, "0"));
    await tx.run(async (send) => {
      let invites: Hex[];
      try {
        invites = (await appApi.practiceInvites()).invites;
      } catch (err) {
        throw new ApiError(
          err instanceof ApiError ? err.status : 0,
          "Couldn't get the practice members to invite. Try again.",
        );
      }
      const now = (await reader.getBlock()).timestamp;
      const fixed = {
        contribution,
        epochDuration: roundLength,
        lockBps: 2_000,
        startTime: now + BigInt(startsIn),
        minSaveEpochs: 3,
        totalEpochs: Number(rounds),
        minMembers: 5,
        maxMembers: Number(members),
        maxRepayEpochs: 3,
        cooldownEpochs: 1,
      };
      const hash = await send(`Create "${name.trim()}"`, {
        address: chain.factory,
        abi: kuberFactoryAbi as Abi,
        functionName: "createCircle",
        args: [name.trim(), fixed, RULES, invites],
      });
      const receipt = await reader.getTransactionReceipt({ hash });
      const [ev] = parseEventLogs({
        abi: kuberFactoryAbi,
        logs: receipt.logs,
        eventName: "CircleCreated",
      });
      setCreated(ev.args.circle);
      // The creator is a member from the start: allow the circle to collect each round's savings.
      const allow = (contribution * BigInt(rounds) * 11n) / 10n;
      await send(
        `Allow the circle to collect up to ${formatAmount(allow)} mUSDC`,
        {
          address: chain.usdc,
          abi: mockUsdcAbi as Abi,
          functionName: "approve",
          args: [ev.args.circle, allow],
        },
      );
      refreshMe().catch(() => {});
      return "Your circle is ready. Invite people, or add practice members from the circle page.";
    });
  }

  return (
    <div className="min-h-dvh">
      <AppBar go={go} back={() => go({ name: "home" })} />
      <Page>
        <h1 className="font-display text-3xl font-bold tracking-tight text-ink">
          Create a circle
        </h1>
        {!created ? (
          <form onSubmit={create} noValidate className="mt-2">
            <p className="text-base text-ink-2">
              Everyone saves the same amount each round. One transaction from
              your wallet sets it up.
            </p>
            <label
              htmlFor="c-name"
              className="mt-5 block font-semibold text-ink"
            >
              Circle name
            </label>
            <input
              id="c-name"
              value={name}
              onChange={(e) => setName(e.target.value)}
              placeholder="Family savings"
              maxLength={40}
              aria-invalid={errors.name ? true : undefined}
              aria-describedby="c-name-e"
              className={field}
            />
            <Err id="c-name-e" text={errors.name} />

            <label
              htmlFor="c-saving"
              className="mt-5 block font-semibold text-ink"
            >
              Saving per round (test mUSDC)
            </label>
            <input
              id="c-saving"
              inputMode="decimal"
              value={saving}
              onChange={(e) => setSaving(e.target.value.trim())}
              aria-invalid={errors.saving ? true : undefined}
              aria-describedby="c-saving-e"
              className={`num ${field}`}
            />
            <Err id="c-saving-e" text={errors.saving} />

            <div className="grid grid-cols-2 gap-3">
              <div>
                <label
                  htmlFor="c-rounds"
                  className="mt-5 block font-semibold text-ink"
                >
                  Rounds
                </label>
                <input
                  id="c-rounds"
                  inputMode="numeric"
                  value={rounds}
                  onChange={(e) => setRounds(e.target.value.trim())}
                  aria-invalid={errors.rounds ? true : undefined}
                  aria-describedby="c-rounds-e"
                  className={`num ${field}`}
                />
              </div>
              <div>
                <label
                  htmlFor="c-members"
                  className="mt-5 block font-semibold text-ink"
                >
                  Members (5–50)
                </label>
                <input
                  id="c-members"
                  inputMode="numeric"
                  value={members}
                  onChange={(e) => setMembers(e.target.value.trim())}
                  aria-invalid={errors.members ? true : undefined}
                  aria-describedby="c-members-e"
                  className={`num ${field}`}
                />
              </div>
            </div>
            <Err id="c-rounds-e" text={errors.rounds} />
            <Err id="c-members-e" text={errors.members} />

            <Choice
              legend="Round length"
              hint="Pick 2 minutes to try it quickly."
              options={ROUND_LENGTHS}
              value={roundLength}
              onChange={setRoundLength}
            />
            <Choice
              legend="Starts in"
              options={STARTS}
              value={startsIn}
              onChange={setStartsIn}
            />

            <details className="group mt-5 rounded-xl border border-line bg-surface">
              <summary className="flex min-h-12 cursor-pointer list-none items-center justify-between px-4 font-semibold text-ink">
                Rules (standard)
                <ChevronDown
                  aria-hidden
                  className="size-5 text-ink-2 transition-transform group-open:rotate-180"
                />
              </summary>
              <ul className="grid gap-1.5 px-4 pb-4 text-sm text-ink-2">
                {RULE_LINES.map((l) => (
                  <li key={l}>{l}</li>
                ))}
                <li>
                  Four practice members are invited so you can fill the circle
                  on your own. They only join if you add them.
                </li>
              </ul>
            </details>

            <div className="mt-5">
              <TxSteps steps={tx.steps} note={tx.note} />
            </div>
            <Button
              type="submit"
              busy={tx.busy}
              disabled={tx.busy}
              className="mt-5 w-full"
            >
              {tx.busy ? "Creating…" : "Create the circle"}
            </Button>
          </form>
        ) : (
          <div className="mt-4 grid gap-4">
            <TxSteps steps={tx.steps} note={tx.note} circle={created} />
            <Section title="Invite people">
              <InvitePeople circle={created} />
            </Section>
            <Button onClick={() => go({ name: "circle", address: created })}>
              Open the circle
            </Button>
          </div>
        )}
      </Page>
    </div>
  );
}

function Err({ id, text }: { id: string; text?: string }) {
  return text ? (
    <p id={id} className="mt-2 text-sm font-semibold text-bad">
      {text}
    </p>
  ) : null;
}
