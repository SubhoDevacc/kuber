import { Handshake, PiggyBank, ShieldCheck } from "lucide-react";
import { useState } from "react";
import { Button, Wordmark } from "../components/ui";

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

/** Neighbours adding coins to one clay pot. Generated with Codex; phone gets a square crop, laptop a wide one. */
function Hero() {
  return (
    <picture className="block">
      <source
        media="(min-width: 768px)"
        srcSet="/hero-wide.webp"
        width={1200}
        height={800}
      />
      <img
        src="/hero-phone.webp"
        width={780}
        height={780}
        alt="Five neighbours sitting around a small table, each dropping a gold coin into one clay pot."
        className="aspect-[5/4] w-full object-cover object-[center_15%] [mask-image:linear-gradient(to_bottom,transparent,black_6%,black_82%,transparent)] md:aspect-[3/2] md:object-center md:[mask-image:radial-gradient(ellipse_at_center,black_72%,transparent_100%)]"
      />
    </picture>
  );
}

export function Welcome({
  onStart,
  onSignIn,
}: {
  onStart: () => Promise<void>;
  /** Set when the real app is on: "Sign in" becomes the first choice and the tutorial the second. */
  onSignIn?: () => void;
}) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  return (
    <div className="mx-auto flex min-h-dvh max-w-6xl flex-col px-4 py-5 sm:px-6">
      <Wordmark />
      <main className="flex-1 py-3 md:py-8">
        <div className="grid items-center gap-2 md:grid-cols-[1.05fr_1fr] md:gap-10">
          <div className="-mx-4 sm:mx-0 md:order-2">
            <Hero />
          </div>
          <div className="md:order-1">
            <h1 className="font-display text-[2.625rem] leading-[1.02] font-bold tracking-tight text-brand-deep sm:text-6xl">
              Save your money together.
            </h1>
            <p className="mt-4 max-w-[32rem] text-lg leading-relaxed text-ink">
              Kuber is a savings circle: a small group saves the same amount
              each round, and members can borrow from the pot with friends
              backing them.
            </p>
            <div className="mt-6 grid gap-3 sm:max-w-sm">
              {onSignIn && <Button onClick={onSignIn}>Sign in</Button>}
              <Button
                variant={onSignIn ? "secondary" : "primary"}
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
                {onSignIn ? "Try the tutorial" : "Start"}
              </Button>
              {error && (
                <p role="alert" className="text-sm font-semibold text-bad">
                  {error}
                </p>
              )}
              <p className="text-sm text-ink-2">
                {onSignIn
                  ? "Sign in with your email to get your own wallet on the Avalanche test network. Everything uses test money, and no real ID is needed."
                  : "This is a practice wallet with test money. Nothing here is real money, and no real ID is needed."}
              </p>
            </div>
          </div>
        </div>

        <ul className="mt-10 grid gap-5 border-t border-line pt-8 md:mt-14 md:grid-cols-3 md:gap-8">
          {points.map(({ icon: Icon, title, text }) => (
            <li key={title} className="flex gap-3 md:block">
              <span className="grid size-11 shrink-0 place-items-center rounded-full bg-accent-soft text-brand ring-1 ring-accent/60 md:mb-3">
                <Icon aria-hidden className="size-5" />
              </span>
              <div>
                <p className="font-display text-lg font-bold text-ink">
                  {title}
                </p>
                <p className="mt-0.5 text-sm leading-relaxed text-ink-2">
                  {text}
                </p>
              </div>
            </li>
          ))}
        </ul>
      </main>
    </div>
  );
}
