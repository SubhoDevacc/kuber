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
        <h1 className="font-display text-3xl font-bold tracking-tight text-ink">
          {me.name}
        </h1>
        <div className="mt-4 grid gap-4">
          <Section title="Your wallet">
            <p className="text-sm text-ink-2">Address</p>
            <p className="num mt-0.5 break-all font-mono text-sm text-ink">
              {signer.address}
            </p>
            <div className="mt-2 flex flex-wrap gap-2">
              <Button
                variant="secondary"
                className="min-h-11 px-3 text-sm"
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
                  className="inline-flex min-h-11 items-center gap-2 rounded-xl border border-line px-3 text-sm font-semibold text-ink hover:border-brand"
                >
                  <ExternalLink aria-hidden className="size-4" /> View on
                  Snowtrace
                </a>
              )}
            </div>
            <dl className="mt-4 grid grid-cols-2 gap-3">
              <div>
                <dt className="text-xs text-ink-2">Test money</dt>
                <dd className="num font-semibold text-ink">
                  {formatAmount(me.musdc)} mUSDC
                </dd>
              </div>
              <div>
                <dt className="text-xs text-ink-2">For network fees</dt>
                <dd className="num font-semibold text-ink">
                  {formatAvax(me.avax)} AVAX
                </dd>
              </div>
            </dl>
          </Section>

          <Section title="Your activity">
            {error && <p className="mb-2 text-sm text-bad">{error}</p>}
            <ActivityList
              items={items}
              showCircle
              empty="No transactions yet."
            />
          </Section>

          <div className="grid gap-2">
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
