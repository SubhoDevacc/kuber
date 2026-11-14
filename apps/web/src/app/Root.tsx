import { lazy, Suspense, useEffect, useState } from "react";
import { App } from "../App";
import { Wordmark } from "../components/ui";
import { type AppHealth, appHealth } from "./appApi";
import { DEV_KEY, PRIVY_APP_ID } from "./config";

// The real app (and Privy) load only when someone signs in, so the tutorial stays as light as it was.
const RealApp = lazy(() => import("./RealApp"));

const KEY = "kuber.realApp";
const remembered = () => {
  try {
    return localStorage.getItem(KEY) === "1";
  } catch {
    return false;
  }
};
const remember = (on: boolean) => {
  try {
    if (on) localStorage.setItem(KEY, "1");
    else localStorage.removeItem(KEY);
  } catch {
    // private mode: sign in again next visit
  }
};
// A shared circle link (?circle=0x…) or ?app opens the real app.
const linked = () => /[?&](app|circle)(=|&|$)/.test(location.search);

function Loading() {
  return (
    <div className="grid min-h-dvh place-items-center" role="status">
      <Wordmark />
      <span className="sr-only">Loading</span>
    </div>
  );
}

/** Tutorial (as today) unless the real app is set up on the server and the person signs in. */
export function Root() {
  const wanted = PRIVY_APP_ID !== "" || DEV_KEY !== null;
  const [health, setHealth] = useState<AppHealth | null | undefined>(
    wanted ? undefined : null,
  );
  const [real, setReal] = useState(() => wanted && (remembered() || linked()));

  useEffect(() => {
    if (wanted) appHealth().then(setHealth);
  }, [wanted]);

  if (real && health === undefined) return <Loading />;
  if (real && health)
    return (
      <Suspense fallback={<Loading />}>
        <RealApp
          health={health}
          onExit={() => {
            remember(false);
            setReal(false);
          }}
        />
      </Suspense>
    );
  return (
    <App
      onSignIn={
        health
          ? () => {
              remember(true);
              setReal(true);
            }
          : undefined
      }
    />
  );
}
