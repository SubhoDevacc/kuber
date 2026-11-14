import { Handshake, PiggyBank, ShieldCheck } from "lucide-react";
import { useState } from "react";
import { Ring } from "../components/Ring";
import { Button, Wordmark } from "../components/ui";

const seats = ["You", "Bob", "Cara", "Dave", "Erin", "Frank"].map(
  (name, i) => ({
    name,
    you: i === 0,
    status: "On track",
    lost: "0",
    debt: "0",
  }),
);

const points = [
  {
    icon: PiggyBank,
    title: "Save together",
    text: "Everyone puts in the same amount each round. The pot is invested and earns for the group.",
  },
  {
    icon: Handshake,
    title: "Borrow with backing",
    text: "Borrow up to 90% of your own savings, and more when friends back you.",
  },
  {
    icon: ShieldCheck,
    title: "Only backers carry the risk",
    text: "If someone stops paying, their savings and their backers cover it. Nobody else loses a thing.",
  },
];

export function Welcome({ onStart }: { onStart: () => Promise<void> }) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  return (
    <div className="mx-auto flex min-h-dvh max-w-5xl flex-col px-4 py-5 sm:px-6">
      <Wordmark />
      <main className="grid flex-1 items-center gap-6 py-4 md:gap-8 md:py-6 md:grid-cols-[1.1fr_1fr] md:gap-12">
        <div className="order-2 md:order-1">
          <h1 className="font-display text-[2.125rem] leading-[1.1] font-bold tracking-tight text-ink sm:text-5xl">
            Save with people you trust.
          </h1>
          <p className="mt-4 max-w-[34rem] text-lg leading-relaxed text-ink">
            Kuber is a savings circle: a small group saves the same amount each
            round, and members can borrow from the pot with friends backing
            them.
          </p>
          <ul className="mt-6 grid gap-4">
            {points.map(({ icon: Icon, title, text }) => (
              <li key={title} className="flex gap-3">
                <span className="mt-0.5 grid size-10 shrink-0 place-items-center rounded-full bg-brand-soft text-brand">
                  <Icon aria-hidden className="size-5" />
                </span>
                <div>
                  <p className="font-semibold text-ink">{title}</p>
                  <p className="text-sm leading-relaxed text-ink-2">{text}</p>
                </div>
              </li>
            ))}
          </ul>
          <div className="mt-8 grid gap-3 sm:max-w-sm">
            <Button
              busy={busy}
              disabled={busy}
              onClick={async () => {
                setBusy(true);
                setError(null);
                try {
                  await onStart();
                } catch (err) {
                  setError(
                    err instanceof Error
                      ? err.message
                      : "Something went wrong. Try again.",
                  );
                  setBusy(false);
                }
              }}
            >
              Start
            </Button>
            <p className="text-sm text-ink-2">
              This is a practice wallet with test money. Nothing here is real
              money, and no real ID is needed.
            </p>
            {error && (
              <p role="alert" className="text-sm font-semibold text-bad">
                {error}
              </p>
            )}
          </div>
        </div>
        <div className="order-1 flex justify-center md:order-2">
          <div className="w-full max-w-[250px] md:max-w-[400px]">
            <Ring
              seats={seats}
              round={3}
              totalRounds={7}
              status="Active"
              centerTop="Six friends"
              centerMain="100 each"
              centerBottom="every round"
            />
          </div>
        </div>
      </main>
    </div>
  );
}
