import { useState } from "react";
import { Button, Wordmark } from "../components/ui";

const points = [
  {
    image: "/spot-save.webp",
    title: "Save together",
    text: "Everyone puts in the same amount each round. The pot is invested and earns for the group.",
  },
  {
    image: "/spot-borrow.webp",
    title: "Borrow with backing",
    text: "Borrow up to 90% of your own savings, and more when friends back you.",
  },
  {
    image: "/spot-safe.webp",
    title: "Only backers carry the risk",
    text: "If someone stops paying, their savings and their backers cover it. Nobody else loses a thing.",
  },
];

/** Young friends saving together, generated for the refreshed welcome screen. */
function Hero() {
  return (
    <picture className="block overflow-hidden rounded-[2rem] border border-brand/15 bg-accent-soft shadow-[0_20px_50px_var(--color-shadow)]">
      <img
        src="/hero-genz.webp"
        width={1536}
        height={1024}
        alt="Five young friends adding gold coins to one shared savings pot."
        className="aspect-[4/3] w-full object-cover object-center md:aspect-[3/2]"
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
    <div className="mx-auto flex min-h-dvh max-w-6xl flex-col px-4 sm:px-6">
      <header className="flex min-h-18 items-center border-b border-line py-4">
        <Wordmark />
      </header>
      <main className="flex-1 pb-10 pt-7 md:py-12">
        <div className="grid items-center gap-7 md:grid-cols-[1fr_1.05fr] md:gap-12">
          <div className="md:order-2">
            <Hero />
          </div>
          <div className="md:order-1">
            <h1 className="max-w-[11ch] font-display text-[clamp(2.8rem,6vw,5rem)] leading-[0.98] font-extrabold tracking-[-0.055em] text-brand-deep">
              Save your money together.
            </h1>
            <p className="mt-5 max-w-[32rem] text-base leading-relaxed text-ink-2 sm:text-lg">
              Kuber is a savings circle: a small group saves the same amount
              each round, and members can borrow from the pot with friends
              backing them.
            </p>
            <div className="mt-7 grid gap-3 sm:max-w-sm">
              {onSignIn && (
                <Button className="w-full" onClick={onSignIn}>
                  Sign in
                </Button>
              )}
              <Button
                variant={onSignIn ? "secondary" : "primary"}
                className="w-full"
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
              <p className="text-sm leading-relaxed text-ink-2">
                {onSignIn
                  ? "Sign in with your email to get your own wallet on the Avalanche test network. Everything uses test money, and no real ID is needed."
                  : "This is a practice wallet with test money. Nothing here is real money, and no real ID is needed."}
              </p>
            </div>
          </div>
        </div>

        <ul className="mt-10 grid gap-3 border-t border-line pt-7 md:mt-16 md:grid-cols-3 md:gap-5">
          {points.map(({ image, title, text }) => (
            <li
              key={title}
              className="app-card arrive flex items-center gap-4 rounded-3xl border border-line bg-surface p-4 transition-[transform,box-shadow] duration-200 md:block md:p-6"
            >
              <img
                src={image}
                width={320}
                height={320}
                alt=""
                aria-hidden="true"
                loading="lazy"
                className="size-20 shrink-0 rounded-2xl bg-brand-soft object-cover md:mb-4 md:size-24"
              />
              <div>
                <p className="font-display text-lg font-extrabold tracking-tight text-ink">
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
