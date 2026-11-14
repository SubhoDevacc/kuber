import { kuberCircleAbi } from "@kuber/shared";
import { Check, Share2, UserPlus } from "lucide-react";
import { useEffect, useId, useState } from "react";
import type { Abi } from "viem";
import { Button } from "../components/ui";
import { ApiError } from "../lib/errors";
import type { Hex } from "../types";
import { appApi, type Person } from "./appApi";
import { TxSteps, useTx } from "./TxStatus";

type Row =
  | {
      kind: "member";
      name: string;
      address: Hex;
      state: "to-send" | "invited" | "joined";
    }
  | { kind: "outside"; name: string; state: "not-on-kuber" | "link" };

export const shareLink = (circle: Hex) =>
  `${location.origin}/?circle=${circle}`;

/** Share the app link: the native share sheet where there is one, otherwise copy it. */
export async function shareCircle(circle: Hex, name?: string): Promise<string> {
  const url = shareLink(circle);
  const text = `Join my savings circle${name ? ` "${name}"` : ""} on Kuber (test money only).`;
  try {
    if (navigator.share) {
      await navigator.share({ title: "Kuber", text, url });
      return "Shared.";
    }
  } catch {
    // cancelled or not allowed: fall back to copying
  }
  try {
    await navigator.clipboard.writeText(url);
    return "Link copied. Paste it to them in any chat app.";
  } catch {
    return `Copy this link: ${url}`;
  }
}

/**
 * The creator invites people by display name. Registered names get a real `invite(address)` transaction;
 * names not on Kuber get a share link (nothing is sent by the server — the row says so).
 */
export function InvitePeople({
  circle,
  existing = [],
  onChanged,
}: {
  circle: Hex;
  existing?: { address: Hex; name: string; joined: boolean }[];
  onChanged?: () => void;
}) {
  const [rows, setRows] = useState<Row[]>([]);
  const [name, setName] = useState("");
  const [hints, setHints] = useState<Person[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [adding, setAdding] = useState(false);
  const [shareNote, setShareNote] = useState<string | null>(null);
  const tx = useTx(onChanged);
  const listId = useId();

  // Suggestions as the name is typed (registered people only).
  useEffect(() => {
    const q = name.trim();
    if (q.length < 1) return setHints([]);
    const id = setTimeout(() => {
      appApi
        .people(q)
        .then(setHints)
        .catch(() => setHints([]));
    }, 200);
    return () => clearTimeout(id);
  }, [name]);

  const known = new Map(existing.map((e) => [e.address.toLowerCase(), e]));
  const all: Row[] = [
    ...existing.map(
      (e): Row => ({
        kind: "member",
        name: e.name,
        address: e.address,
        state: e.joined ? "joined" : "invited",
      }),
    ),
    ...rows.filter(
      (r) => r.kind === "outside" || !known.has(r.address.toLowerCase()),
    ),
  ];

  async function add(e: React.FormEvent) {
    e.preventDefault();
    const n = name.trim();
    if (!n) return;
    setError(null);
    setAdding(true);
    try {
      const p = await appApi.lookup(n);
      if (
        all.some(
          (r) =>
            r.kind === "member" &&
            r.address.toLowerCase() === p.address.toLowerCase(),
        )
      )
        setError(`${p.name} is already on the list.`);
      else
        setRows((r) => [
          ...r,
          {
            kind: "member",
            name: p.name,
            address: p.address,
            state: "to-send",
          },
        ]);
      setName("");
    } catch (err) {
      if (err instanceof ApiError && err.status === 404) {
        setRows((r) => [
          ...r,
          { kind: "outside", name: n, state: "not-on-kuber" },
        ]);
        setName("");
      } else
        setError(
          err instanceof Error ? err.message : "Couldn't look that name up.",
        );
    } finally {
      setAdding(false);
    }
  }

  const toSend = rows.filter(
    (r): r is Extract<Row, { kind: "member" }> =>
      r.kind === "member" && r.state === "to-send",
  );

  async function sendInvites() {
    await tx.run(async (send) => {
      for (const r of toSend) {
        await send(`Invite ${r.name}`, {
          address: circle,
          abi: kuberCircleAbi as Abi,
          functionName: "invite",
          args: [r.address],
        });
        setRows((rs) =>
          rs.map((x) =>
            x.kind === "member" && x.address === r.address
              ? { ...x, state: "invited" }
              : x,
          ),
        );
      }
      return toSend.length > 1
        ? "Everyone on the list is invited. They see this circle under Invited on their Home."
        : "Invited. They see this circle under Invited on their Home.";
    });
  }

  async function inviteOutside(n: string) {
    setShareNote(await shareCircle(circle));
    setRows((rs) =>
      rs.map((x) =>
        x.kind === "outside" && x.name === n ? { ...x, state: "link" } : x,
      ),
    );
  }

  return (
    <div className="grid gap-3">
      <form onSubmit={add} className="flex gap-2">
        <label htmlFor={`${listId}-name`} className="sr-only">
          Display name to invite
        </label>
        <input
          id={`${listId}-name`}
          list={`${listId}-hints`}
          value={name}
          onChange={(e) => setName(e.target.value)}
          placeholder="Their display name"
          autoComplete="off"
          className="block min-h-12 w-full min-w-0 rounded-xl border border-line bg-surface px-4 text-base text-ink outline-none focus:border-brand focus:ring-2 focus:ring-brand/30"
        />
        <datalist id={`${listId}-hints`}>
          {hints.map((h) => (
            <option key={h.address} value={h.name} />
          ))}
        </datalist>
        <Button
          type="submit"
          variant="secondary"
          busy={adding}
          disabled={adding || !name.trim()}
        >
          <UserPlus aria-hidden className="size-5" /> Add
        </Button>
      </form>
      {error && (
        <p role="alert" className="text-sm font-semibold text-bad">
          {error}
        </p>
      )}

      {all.length > 0 && (
        <ul className="divide-y divide-line rounded-xl border border-line">
          {all.map((r) => (
            <li
              key={r.kind === "member" ? r.address : `out-${r.name}`}
              className="flex flex-wrap items-center justify-between gap-2 px-3 py-2.5"
            >
              <span className="min-w-0">
                <span className="block truncate font-semibold text-ink">
                  {r.name}
                </span>
                <span className="block text-sm text-ink-2">
                  {r.kind === "member"
                    ? r.state === "joined"
                      ? "Joined"
                      : r.state === "invited"
                        ? "Invited — waiting for them to join"
                        : "On Kuber — ready to invite"
                    : r.state === "link"
                      ? "Link sent — share this link with them (Kuber doesn't message anyone)"
                      : `${r.name} is not on Kuber yet`}
                </span>
              </span>
              {r.kind === "member" && r.state !== "to-send" && (
                <Check aria-hidden className="size-5 text-good" />
              )}
              {r.kind === "outside" && (
                <Button
                  variant="secondary"
                  className="min-h-11 px-3 text-sm"
                  onClick={() => inviteOutside(r.name)}
                >
                  <Share2 aria-hidden className="size-4" />
                  {r.state === "link" ? "Share again" : "Invite them"}
                </Button>
              )}
            </li>
          ))}
        </ul>
      )}
      {shareNote && (
        <p
          role="status"
          className="text-sm text-ink-2 [overflow-wrap:anywhere]"
        >
          {shareNote}
        </p>
      )}

      <TxSteps steps={tx.steps} note={tx.note} circle={circle} />
      {toSend.length > 0 && (
        <Button onClick={sendInvites} busy={tx.busy} disabled={tx.busy}>
          {toSend.length > 1
            ? `Invite all (${toSend.length})`
            : `Send invite to ${toSend[0].name}`}
        </Button>
      )}
      <Button
        variant="quiet"
        onClick={async () => setShareNote(await shareCircle(circle))}
      >
        <Share2 aria-hidden className="size-4" /> Share the circle link
      </Button>
    </div>
  );
}
