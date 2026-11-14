import { Copy, ExternalLink, GraduationCap, LogOut } from "lucide-react";
import { useEffect, useState } from "react";
import { Button, Section } from "../components/ui";
import { formatAmount } from "../lib/money";
import { ActivityList } from "./Activity";
import { type ActivityItem, appApi } from "./appApi";
import { useApp } from "./ctx";
import { formatAvax } from "./Home";
import { AppBar, type Go, Page } from "./Screens";

export function MenuPage({ go, onSignOut }: { go: Go; onSignOut: () => void }) {
  const { me, signer, chain, refreshMe } = useApp();
  const [copied, setCopied] = useState(false);
  const [items, setItems] = useState<ActivityItem[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    refreshMe().catch(() => {});
    appApi
      .myActivity()
      .then(setItems)
      .catch((err: Error) => {
        setItems([]);
        setError(err.message);
      });
  }, [refreshMe]);

  async function copy() {
    try {
      await navigator.clipboard.writeText(signer.address);
      setCopied(true);
      setTimeout(() => setCopied(false), 1500);
    } catch {
      // clipboard blocked: the address is on screen to copy by hand
    }
  }

  return (
    <div className="min-h-dvh">
      <AppBar go={go} back={() => go({ name: "home" })} />
      <Page>
        <header className="flex items-center gap-4">
          <span
            aria-hidden="true"
            className="grid size-14 shrink-0 place-items-center rounded-2xl bg-accent font-display text-2xl font-bold text-brand-deep"
          >
            {me.name?.charAt(0).toUpperCase() || "K"}
          </span>
          <div className="min-w-0">
            <h1 className="truncate font-display text-3xl font-bold tracking-tight text-ink">
              {me.name}
            </h1>
            <p className="num truncate font-mono text-xs text-ink-2">
              {signer.address.slice(0, 8)}…{signer.address.slice(-6)}
            </p>
          </div>
        </header>
        <div className="mt-6 grid gap-5">
          <section className="on-dark arrive rounded-3xl border border-brand bg-brand-deep p-5 text-white shadow-[0_10px_30px_var(--color-shadow)]">
            <h2 className="text-sm font-semibold text-white/80">Your wallet</h2>
            <p className="num mt-3 font-display text-3xl font-bold tracking-tight">
              {formatAmount(me.musdc)}{" "}
              <span className="text-base font-medium text-accent">mUSDC</span>
            </p>
            <p className="num mt-1 text-sm text-white/75">
              {formatAvax(me.avax)} AVAX for network fees
            </p>
            <p className="mt-5 text-xs text-white/70">Address</p>
            <p className="num mt-1 break-all font-mono text-xs text-white">
              {signer.address}
            </p>
            <div className="mt-4 flex flex-wrap gap-2">
              <Button
                variant="secondary"
                className="min-h-11 !border-white/60 !bg-transparent px-3 text-sm !text-white hover:!border-white hover:!bg-white/10"
                onClick={copy}
              >
                <Copy aria-hidden className="size-4" />{" "}
                {copied ? "Copied" : "Copy address"}
              </Button>
              {chain.explorer && (
                <a
                  href={`${chain.explorer}/address/${signer.address}`}
                  target="_blank"
                  rel="noreferrer"
                  className="inline-flex min-h-11 items-center gap-2 rounded-xl border border-white/60 px-3 text-sm font-semibold text-white transition-colors hover:border-white hover:bg-white/10"
                >
                  <ExternalLink aria-hidden className="size-4" /> View on
                  Snowtrace
                </a>
              )}
            </div>
          </section>

          <Section title="Your activity">
            {error && <p className="mb-2 text-sm text-bad">{error}</p>}
            <ActivityList
              items={items}
              showCircle
              empty="No transactions yet."
            />
          </Section>

          <div className="grid gap-2 border-t border-line pt-5">
            <Button
              variant="secondary"
              onClick={() => go({ name: "tutorial" })}
            >
              <GraduationCap aria-hidden className="size-5" /> Tutorial mode
            </Button>
            <Button variant="secondary" onClick={onSignOut}>
              <LogOut aria-hidden className="size-5" /> Sign out
            </Button>
          </div>
          <p className="text-sm text-ink-2">
            Kuber runs on the Avalanche Fuji test network. Everything here is
            test money with no real value.
          </p>
        </div>
      </Page>
    </div>
  );
}
