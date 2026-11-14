// Circle history from event logs: an incremental, per-circle log cache (public Fuji RPC allows 100 blocks per
// getLogs, so ranges are chunked) and plain-words lines for the web app. Used by the tutorial and the real app.
import {
  type Abi,
  type Address,
  createPublicClient,
  decodeAbiParameters,
  http,
  parseEventLogs,
} from "viem";
import type { Chain } from "./chain.ts";

type Log = {
  eventName: string;
  args: Record<string, unknown>;
  blockNumber: bigint;
  logIndex: number;
  transactionHash: `0x${string}`;
  blockTimestamp?: bigint | string | null;
};
type Cache = {
  scanned: bigint;
  logs: Log[];
  busy: Promise<void> | null;
  at: number;
};

export type ActivityEntry = {
  time: number;
  who: string;
  what: string;
  amount: string | null;
  txHash: `0x${string}`;
  block: number;
  /** Lowercase address of the member the line is about (null for circle-wide lines); not for display. */
  actor?: string | null;
};

const KEEP = 2_000;
const LOOKBACK = 4_000n;
const SHOW = 200;
const RULES = [
  "Share of savings you can borrow",
  "Interest on borrowing your own savings",
  "Largest single loan",
  "Fast-lane share",
  "Penalty for not repaying",
  "Fine for a late round",
  "Fine for a late repayment",
  "Fee for leaving early",
  "Manager fee",
];

const poss = (name: string, start = false) =>
  name === "You" ? (start ? "Your" : "your") : `${name}'s`;

/** "1,234.56" from 6-decimal base units. */
export const plain = (v: bigint) => {
  const c = (v + 5_000n) / 10_000n;
  return `${(c / 100n).toLocaleString("en-US")}.${(c % 100n).toString().padStart(2, "0")}`;
};

export const activity = (c: Chain, chunk: bigint, minGapMs = 0) => {
  const circleAbi = c.abis.circle as Abi;
  const created = new Map<string, bigint>(); // lowercase circle -> creation block
  const creators = new Map<string, Address>();
  const order: Address[] = [];
  let factoryBusy: Promise<void> | null = null;
  const caches = new Map<string, Cache>();
  const times = new Map<bigint, number>();
  // Not batched: the public Fuji RPC adds up the block ranges of every getLogs in one JSON-RPC batch (max 100).
  const logsClient = createPublicClient({
    chain: c.chain,
    transport: http(c.chain.rpcUrls.default.http[0], { retryCount: 1 }),
  });

  const scan = async (
    address: Address,
    abi: Abi,
    from: bigint,
    to: bigint,
  ): Promise<Log[]> => {
    const ranges: [bigint, bigint][] = [];
    for (let a = from; a <= to; a += chunk)
      ranges.push([a, a + chunk - 1n > to ? to : a + chunk - 1n]);
    const out: Log[] = [];
    // A few ranges at a time: fast catch-up without flooding a public RPC.
    for (let i = 0; i < ranges.length; i += 2) {
      const parts = await Promise.all(
        ranges
          .slice(i, i + 2)
          .map(([a, b]) =>
            logsClient.getLogs({ address, fromBlock: a, toBlock: b }),
          ),
      );
      for (const logs of parts)
        out.push(
          ...(parseEventLogs({ abi, logs, strict: false }) as unknown as Log[])
            .filter((l) => l.eventName)
            .map((l) => ({ ...l, args: l.args ?? {} })),
        );
    }
    return out;
  };

  /** Finds new circles (factory.allCircles), their creator, and their creation block (no log scan: on a public
   * RPC a binary search over eth_getCode is ~15 calls per circle, once, instead of one getLogs per 100 blocks). */
  let lastHead: bigint | null = null;
  const born = async (circle: Address, head: bigint) => {
    // Seen appear since the last sync: it was created after that sync's head.
    if (lastHead !== null) return lastHead;
    if (head - c.deployBlock < chunk) return c.deployBlock;
    let lo = c.deployBlock;
    let hi = head;
    try {
      while (lo < hi) {
        const mid = (lo + hi) / 2n;
        const code = await c.pub.getCode({ address: circle, blockNumber: mid });
        if (code && code !== "0x") hi = mid;
        else lo = mid + 1n;
      }
      return lo;
    } catch {
      // A non-archive node has no old state: look back a fixed window (older history of circles made before
      // this server started may be missing; anything still forming is inside the window).
      return [head - LOOKBACK, c.deployBlock].sort((x, y) =>
        x > y ? -1 : 1,
      )[0];
    }
  };
  const syncFactory = () => {
    factoryBusy ??= (async () => {
      const [list, head] = await Promise.all([
        c.read<readonly Address[]>(c.factory, c.abis.factory, "allCircles"),
        c.pub.getBlockNumber({ cacheTime: 0 }),
      ]);
      const fresh = list.filter((a) => !created.has(a.toLowerCase()));
      const found = await Promise.all(
        fresh.map(async (a) => {
          const [s, block] = await Promise.all([
            c.read<{ creator: Address }>(a, circleAbi, "getCircleState"),
            born(a, head),
          ]);
          return { a, creator: s.creator, block };
        }),
      );
      for (const { a, creator, block } of found) {
        created.set(a.toLowerCase(), block);
        creators.set(a.toLowerCase(), creator);
      }
      order.splice(0, order.length, ...list);
      lastHead = head;
    })().finally(() => {
      factoryBusy = null;
    });
    return factoryBusy;
  };

  const syncCircle = async (circle: Address) => {
    const key = circle.toLowerCase();
    if (!created.has(key)) await syncFactory();
    const start = created.get(key);
    if (start === undefined) return null;
    let cache = caches.get(key);
    if (!cache) {
      cache = { scanned: start - 1n, logs: [], busy: null, at: 0 };
      caches.set(key, cache);
    }
    const k = cache;
    // Polling pages ask often; a public RPC is rate limited. Serve the cache if it is fresh enough.
    if (Date.now() - k.at < minGapMs && !k.busy) return k.logs;
    k.busy ??= (async () => {
      const head = await c.pub.getBlockNumber({ cacheTime: 0 });
      if (head > k.scanned) {
        const logs = await scan(circle, circleAbi, k.scanned + 1n, head);
        k.logs.push(...logs);
        if (k.logs.length > KEEP) k.logs.splice(0, k.logs.length - KEEP);
        k.scanned = head;
      }
      k.at = Date.now();
    })().finally(() => {
      k.busy = null;
    });
    await k.busy;
    return k.logs;
  };

  const timeOf = async (l: Log) => {
    if (l.blockTimestamp != null) return Number(BigInt(l.blockTimestamp));
    const hit = times.get(l.blockNumber);
    if (hit !== undefined) return hit;
    const b = await c.pub.getBlock({ blockNumber: l.blockNumber });
    times.set(l.blockNumber, Number(b.timestamp));
    return Number(b.timestamp);
  };

  /** Newest first, at most 200 lines. `nameOf` turns an address into a display name. */
  const forCircle = async (
    circle: Address,
    nameOf: (a: Address) => string,
  ): Promise<ActivityEntry[]> => {
    const logs = (await syncCircle(circle)) ?? [];
    const borrowers = new Map<string, Address>();
    const titles = new Map<string, string>();
    const kinds = new Map<string, number>();
    for (const l of logs) {
      if (l.eventName === "LoanRequested")
        borrowers.set(String(l.args.id), l.args.borrower as Address);
      if (l.eventName === "ProposalCreated") {
        let title = "a change to the circle";
        const kind = Number(l.args.kind);
        const data = l.args.data as `0x${string}`;
        try {
          if (kind === 0) {
            const [f, v] = decodeAbiParameters(
              [{ type: "uint8" }, { type: "uint256" }],
              data,
            );
            title = `${RULES[f] ?? "a rule"} to ${Number(v) / 100}%`;
          } else if (kind === 1) {
            const [a, b, c2, d] = decodeAbiParameters(
              [
                { type: "uint16" },
                { type: "uint16" },
                { type: "uint16" },
                { type: "uint16" },
              ],
              data,
            );
            title = `a new money plan (ready to lend ${a / 100}%, Aave ${b / 100}%, LP pool ${c2 / 100}%, cash ${d / 100}%)`;
          } else if (kind === 2) {
            const [t] = decodeAbiParameters([{ type: "address" }], data);
            title = /^0x0+$/.test(t)
              ? "remove the fund manager"
              : `make ${nameOf(t)} the fund manager`;
          }
        } catch {
          // keep the generic title
        }
        titles.set(String(l.args.id), title);
        kinds.set(String(l.args.id), kind);
      }
    }
    const claimTx = new Set(
      logs
        .filter((l) => l.eventName === "LoanClaimed")
        .map((l) => l.transactionHash),
    );
    const lines: (Omit<ActivityEntry, "time"> & { log: Log })[] = [];
    const add = (
      l: Log,
      actor: Address | null,
      what: (who: string) => string,
      amount: bigint | null = null,
    ) => {
      const who = actor ? nameOf(actor) : "Circle";
      lines.push({
        log: l,
        who,
        what: what(who),
        amount: amount === null ? null : amount.toString(),
        txHash: l.transactionHash,
        block: Number(l.blockNumber),
        actor: actor ? actor.toLowerCase() : null,
      });
    };
    for (const l of logs) {
      const a = l.args;
      // MemberSuspended names its loan `loanId`; every other loan event `id`.
      const id =
        a.id !== undefined
          ? String(a.id)
          : a.loanId !== undefined
            ? String(a.loanId)
            : "";
      const borrower = borrowers.get(id) ?? null;
      const amt = (k: string) => BigInt(a[k] as bigint);
      switch (l.eventName) {
        case "Invited":
          add(l, a.who as Address, (w) => `${w} was invited`);
          break;
        case "JoinRequested":
          add(l, a.who as Address, (w) => `${w} asked to join`);
          break;
        case "Joined":
          add(l, a.who as Address, (w) => `${w} joined`);
          break;
        case "Activated":
          add(l, null, () => "The circle started");
          break;
        case "Cancelled":
          add(l, null, () => "The circle was cancelled");
          break;
        case "EpochSettled":
          add(l, null, () => `Round ${a.epoch} closed`);
          break;
        case "ContributionPaid":
          add(
            l,
            a.member as Address,
            (w) => `${w} saved ${plain(amt("amount"))}`,
            amt("amount"),
          );
          break;
        case "ContributionMissed":
          add(l, a.member as Address, (w) => `${w} missed a payment`);
          break;
        case "CaughtUp":
          add(
            l,
            a.member as Address,
            (w) => `${w} caught up on round ${a.epoch}`,
          );
          break;
        case "LoanRequested":
          add(
            l,
            a.borrower as Address,
            (w) => `${w} asked to borrow ${plain(amt("amount"))}`,
            amt("amount"),
          );
          break;
        case "Backed":
          add(
            l,
            a.backer as Address,
            (w) =>
              `${w} backed ${borrower ? poss(nameOf(borrower)) : "a"} loan with ${plain(amt("amount"))}`,
            amt("amount"),
          );
          break;
        case "Unbacked":
          add(
            l,
            a.backer as Address,
            (w) => `${w} stopped backing a loan`,
            amt("amount"),
          );
          break;
        case "LoanFunded":
          add(
            l,
            borrower,
            (w) => `${borrower ? poss(w, true) : "A"} loan was paid out`,
          );
          break;
        case "RequestExpired":
          add(
            l,
            borrower,
            (w) =>
              `${borrower ? poss(w, true) : "A"} loan request ran out of time`,
          );
          break;
        case "LoanClaimed":
          add(
            l,
            a.borrower as Address,
            (w) =>
              `${w} took ${w === "You" ? "your" : "their"} loan of ${plain(amt("amount"))}`,
            amt("amount"),
          );
          break;
        case "InstallmentPaid":
          add(
            l,
            borrower,
            (w) => `${w} repaid ${plain(amt("amount"))}`,
            amt("amount"),
          );
          break;
        case "InstallmentMissed":
          add(l, borrower, (w) => `${w} missed a repayment`);
          break;
        case "FineCharged":
          add(
            l,
            a.member as Address,
            (w) => `${w} was charged a late fine of ${plain(amt("amount"))}`,
            amt("amount"),
          );
          break;
        case "LoanRepaid":
          add(
            l,
            borrower,
            (w) =>
              `${w} finished repaying ${w === "You" ? "your" : "their"} loan`,
          );
          break;
        case "MemberSuspended":
          add(
            l,
            borrower,
            (w) =>
              `${w} did not repay; the loan was covered and ${w === "You" ? "you are" : `${w} is`} paused`,
          );
          break;
        case "DebtRepaid":
          add(
            l,
            a.member as Address,
            (w) => `${w} paid back ${plain(amt("amount"))} of debt`,
            amt("amount"),
          );
          break;
        case "ProposalCreated":
          add(
            l,
            a.proposer as Address,
            (w) => `${w} proposed: ${titles.get(id) ?? "a change"}`,
          );
          break;
        case "Voted":
          add(
            l,
            a.voter as Address,
            (w) => `${w} voted ${a.yes ? "yes" : "no"}`,
          );
          break;
        case "ProposalPassed":
          add(l, null, () => "A proposal passed");
          break;
        case "ProposalApplied":
          add(l, null, () =>
            kinds.get(id) === 1
              ? `The money plan changed: ${titles.get(id) ?? "a new plan"}`
              : kinds.get(id) === 2
                ? `Applied: ${titles.get(id) ?? "the fund manager change"}`
                : `The rule changed: ${titles.get(id) ?? "a proposal"}`,
          );
          break;
        case "ManagerChanged":
          add(l, null, () =>
            /^0x0+$/.test(String(a.manager))
              ? "The circle has no fund manager now"
              : `${nameOf(a.manager as Address)} is now the fund manager`,
          );
          break;
        case "LeaveRequested":
          add(l, a.member as Address, (w) => `${w} asked to leave`);
          break;
        case "MemberLeft":
          add(
            l,
            a.member as Address,
            (w) => `${w} left the circle`,
            amt("payout") || null,
          );
          break;
        case "MemberKicked":
          add(l, a.member as Address, (w) => `${w} was removed`);
          break;
        case "Claimed":
          // A loan claim emits LoanClaimed too: one line per transaction is enough.
          if (claimTx.has(l.transactionHash)) break;
          add(
            l,
            a.member as Address,
            (w) => `${w} took ${plain(amt("amount"))} from the circle`,
            amt("amount"),
          );
          break;
        case "Withdrawn":
          add(
            l,
            a.member as Address,
            (w) => `${w} collected a share-out of ${plain(amt("amount"))}`,
            amt("amount"),
          );
          break;
        default:
          break;
      }
    }
    const last = lines
      .sort((x, y) =>
        x.log.blockNumber === y.log.blockNumber
          ? y.log.logIndex - x.log.logIndex
          : Number(y.log.blockNumber - x.log.blockNumber),
      )
      .slice(0, SHOW);
    return Promise.all(
      last.map(async ({ log, ...rest }) => ({
        time: await timeOf(log),
        ...rest,
      })),
    );
  };

  return {
    syncFactory,
    forCircle,
    /** Circles made by `creator`, oldest first (after a factory sync). */
    circlesBy: (creator: Address) =>
      order.filter(
        (a) =>
          creators.get(a.toLowerCase())?.toLowerCase() ===
          creator.toLowerCase(),
      ),
    /** Raw cached logs of one circle (synced). */
    logs: syncCircle,
  };
};
