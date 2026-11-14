// A new person must finish the tutorial once before the app opens (owner's rule). Remembered per wallet address.
// Dev-only escape for the headless walks: `?skipTutorial=1` (dev builds only), or set the localStorage flag before load.

const key = (address: string) => `kuber:tutorialDone:${address.toLowerCase()}`;

const devSkip = (): boolean => {
  if (!import.meta.env.DEV) return false;
  try {
    return new URLSearchParams(location.search).get("skipTutorial") === "1";
  } catch {
    return false;
  }
};

export function tutorialDone(address: string | null | undefined): boolean {
  if (devSkip()) return true;
  if (!address) return false;
  try {
    return localStorage.getItem(key(address)) === "1";
  } catch {
    return false;
  }
}

export function markTutorialDone(address: string | null | undefined) {
  if (!address) return;
  try {
    localStorage.setItem(key(address), "1");
  } catch {
    // private mode: asked again next visit
  }
}
