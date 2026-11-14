import type {
  CircleSnapshot,
  CircleSummary,
  Hex,
  Me,
  Onboarded,
  TutorialState,
} from "../types";
import { ApiError } from "./errors";
import { MOCK, mockApi } from "./mock";

export { ApiError };

let address: Hex | null = null;
export const setApiAddress = (a: Hex | null) => {
  address = a;
};

async function call<T>(
  method: "GET" | "POST",
  path: string,
  body?: unknown,
): Promise<T> {
  if (!address) throw new ApiError(401, "No practice wallet yet.");
  if (MOCK) return mockApi(address, method, path, body) as Promise<T>;
  let res: Response;
  try {
    res = await fetch(`/api${path}`, {
      method,
      headers: {
        authorization: `Bearer dev:${address}`,
        ...(body === undefined ? {} : { "content-type": "application/json" }),
      },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
  } catch {
    throw new ApiError(
      0,
      "Can't reach the Kuber server. Check it's running, then try again.",
    );
  }
  const text = await res.text();
  let json: unknown = null;
  try {
    json = text ? JSON.parse(text) : null;
  } catch {
    // not JSON (for example a proxy error page)
  }
  if (!res.ok) {
    const error = (json as { error?: unknown } | null)?.error;
    throw new ApiError(
      res.status,
      typeof error === "string" && error
        ? error
        : res.status >= 500
          ? "The Kuber server had a problem. Try again in a moment."
          : "Something went wrong. Try again.",
    );
  }
  return json as T;
}

export const api = {
  me: () => call<Me>("GET", "/me"),
  onboard: (name: string) => call<Onboarded>("POST", "/onboard", { name }),
  start: () => call<TutorialState>("POST", "/tutorial/start"),
  tutorial: () => call<TutorialState>("GET", "/tutorial"),
  next: (stepId: string) =>
    call<TutorialState>("POST", "/tutorial/next", { stepId }),
  reset: () => call<TutorialState>("POST", "/tutorial/reset"),
  circles: () => call<CircleSummary[]>("GET", "/circles"),
  circle: (a: string) => call<CircleSnapshot>("GET", `/circles/${a}`),
};
