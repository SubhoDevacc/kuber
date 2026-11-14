import { useCallback, useEffect, useState } from "react";
import { Button, Wordmark } from "./components/ui";
import { api, setApiAddress } from "./lib/api";
import { markTutorialDone, tutorialDone } from "./lib/tutorialDone";
import { addressOf, createKey, getKey } from "./lib/wallet";
import { Finish } from "./pages/Finish";
import { CirclePage, Home } from "./pages/Home";
import { SignUp } from "./pages/SignUp";
import { Tutorial } from "./pages/Tutorial";
import { Welcome } from "./pages/Welcome";
import type { Hex, TutorialState } from "./types";

type View =
  | { name: "loading" }
  | { name: "failed"; message: string }
  | { name: "welcome" }
  | { name: "signup" }
  | { name: "tutorial"; t: TutorialState }
  | { name: "finish"; t: TutorialState }
  | { name: "home" }
  | { name: "circle"; address: string };

export function App({ onSignIn }: { onSignIn?: () => void } = {}) {
  const [key, setKey] = useState<Hex | null>(getKey);
  const [view, setView] = useState<View>({ name: "loading" });
  const [homeNote, setHomeNote] = useState<string | null>(null);

  // Where the person lands is decided by the server's view of them (GET /me).
  const route = useCallback(async () => {
    const me = await api.me();
    if (!me.name || !me.verified) return setView({ name: "signup" });
    // No skipping on the first run: Home opens only after the tutorial was finished once on this wallet.
    if (me.tutorial?.done) markTutorialDone(me.address);
    if (tutorialDone(me.address)) return setView({ name: "home" });
    setView({ name: "tutorial", t: me.tutorial ?? (await api.start()) });
  }, []);

  const boot = useCallback(async () => {
    setView({ name: "loading" });
    const k = getKey();
    if (!k) return setView({ name: "welcome" });
    setApiAddress(addressOf(k));
    try {
      await route();
    } catch (err) {
      setView({
        name: "failed",
        message: err instanceof Error ? err.message : "Something went wrong.",
      });
    }
  }, [route]);

  useEffect(() => {
    boot();
  }, [boot]);

  // biome-ignore lint/correctness/useExhaustiveDependencies: scroll to top on each new screen
  useEffect(() => {
    window.scrollTo({ top: 0 });
  }, [view.name]);

  async function tutorialMode() {
    setHomeNote("Opening the tutorial…");
    try {
      const me = await api.me();
      const t = me.tutorial ?? (await api.start());
      setView(t.done ? { name: "finish", t } : { name: "tutorial", t });
    } catch (err) {
      setHomeNote(
        err instanceof Error
          ? err.message
          : "Couldn't open the tutorial. Try again.",
      );
      return;
    }
    setHomeNote(null);
  }

  async function restart() {
    setHomeNote(
      "Setting up a fresh practice circle. This can take a few seconds…",
    );
    try {
      const t = await api.reset();
      setView({ name: "tutorial", t });
    } catch (err) {
      setHomeNote(
        err instanceof Error
          ? err.message
          : "Couldn't restart the tutorial. Try again.",
      );
      return;
    }
    setHomeNote(null);
  }

  switch (view.name) {
    case "loading":
      return (
        <div className="grid min-h-dvh place-items-center" role="status">
          <Wordmark />
          <span className="sr-only">Loading</span>
        </div>
      );
    case "failed":
      return (
        <div className="mx-auto flex min-h-dvh max-w-md flex-col justify-center gap-4 px-4">
          <Wordmark />
          <p role="alert" className="text-lg font-semibold text-ink">
            {view.message}
          </p>
          <Button onClick={boot}>Try again</Button>
        </div>
      );
    case "welcome":
      return (
        <Welcome
          onSignIn={onSignIn}
          onStart={async () => {
            const k = createKey();
            setKey(k);
            setApiAddress(addressOf(k));
            await route();
          }}
        />
      );
    case "signup":
      return <SignUp onReady={(t) => setView({ name: "tutorial", t })} />;
    case "tutorial":
      return key ? (
        <Tutorial
          key={view.t.circle}
          initial={view.t}
          privateKey={key}
          onLeave={
            tutorialDone(addressOf(key))
              ? () => setView({ name: "home" })
              : undefined
          }
          onDone={(t) => {
            markTutorialDone(addressOf(key));
            setView({ name: "finish", t });
          }}
        />
      ) : null;
    case "finish":
      return <Finish t={view.t} onEnter={() => setView({ name: "home" })} />;
    case "home":
      return (
        <Home
          busyNote={homeNote}
          onOpen={(address) => setView({ name: "circle", address })}
          onTutorial={tutorialMode}
          onRestart={restart}
          onSignIn={onSignIn}
        />
      );
    case "circle":
      return (
        <CirclePage
          address={view.address}
          onBack={() => setView({ name: "home" })}
        />
      );
  }
}
