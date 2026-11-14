// HTTP API (SPRINT.md): dev auth, onboarding with the welcome grant, the tutorial, and circle views.
import { Hono } from "hono";
import { type Address, getAddress, isAddress } from "viem";
import { z } from "zod";
import { connect, type Env } from "./chain.ts";
import { readFacts, toSnapshot } from "./snapshot.ts";
import { HttpError, type Tutorial, tutorials } from "./tutorial.ts";

type User = {
  address: Address;
  name: string | null;
  granted: boolean;
  tutorial: Tutorial | null;
  starting: Promise<unknown> | null;
};

const NameBody = z.object({
  name: z
    .string()
    .trim()
    .regex(
      /^[A-Za-z0-9 -]{3,24}$/,
      "A name is 3 to 24 letters, digits, spaces or dashes.",
    ),
});
const NextBody = z.object({ stepId: z.string().max(40).optional() });
const CIRCLE_STATUS = ["Forming", "Active", "Completed", "Cancelled"];

export const createApp = async (env: Env) => {
  const c = await connect(env);
  const { abis } = c;
  const facts = (circle: Address, u: Address | null) => readFacts(c, circle, u);
  const tut = tutorials(c, facts);
  const users = new Map<string, User>();
  const grant = BigInt(env.WELCOME_GRANT_MUSDC) * 1_000_000n;

  const app = new Hono<{ Variables: { user: User } }>();

  app.onError((err, ctx) => {
    if (err instanceof HttpError)
      return ctx.json({ error: err.message }, err.status);
    // First line only: viem errors can carry long call data; never anything secret.
    console.error(
      `dev-api error on ${ctx.req.method} ${ctx.req.path}: ${String(err.message).split("\n")[0]}`,
    );
    return ctx.json(
      { error: "Something went wrong on our side. Please try again." },
      500,
    );
  });
  app.notFound((ctx) => ctx.json({ error: "There is nothing here." }, 404));

  app.get("/health", (ctx) =>
    ctx.json({ ok: true, chainId: c.chainId, usdc: c.usdc }),
  );

  app.use("*", async (ctx, next) => {
    const m = /^Bearer dev:(0x[0-9a-fA-F]{40})$/.exec(
      ctx.req.header("authorization") ?? "",
    );
    if (env.DEV_MODE !== "true" || !m || !isAddress(m[1], { strict: false }))
      return ctx.json({ error: "Please sign in first." }, 401);
    const address = getAddress(m[1]);
    let u = users.get(address);
    if (!u) {
      u = {
        address,
        name: null,
        granted: false,
        tutorial: null,
        starting: null,
      };
      users.set(address, u);
    }
    ctx.set("user", u);
    await next();
  });

  const body = async <T>(
    ctx: { req: { json: () => Promise<unknown> } },
    schema: z.ZodType<T>,
  ): Promise<T> => {
    const raw = await ctx.req.json().catch(() => ({}));
    const r = schema.safeParse(raw ?? {});
    if (!r.success)
      throw new HttpError(
        400,
        r.error.issues[0]?.message ?? "That request doesn't look right.",
      );
    return r.data;
  };

  const me = async (u: User) => {
    const [verified, musdc] = await Promise.all([
      c.read<boolean>(c.registry, abis.registry, "verified", [u.address]),
      c.read<bigint>(c.usdc, abis.usdc, "balanceOf", [u.address]),
    ]);
    return {
      address: u.address,
      name: u.name,
      verified,
      musdc: musdc.toString(),
      tutorial: u.tutorial ? await tut.view(u.tutorial) : null,
    };
  };
  const needTutorial = (u: User) => {
    if (!u.tutorial)
      throw new HttpError(
        404,
        "You have no practice circle yet. Start the tutorial first.",
      );
    return u.tutorial;
  };
  const start = async (u: User) => {
    const verified = await c.read<boolean>(
      c.registry,
      abis.registry,
      "verified",
      [u.address],
    );
    if (!verified || !u.name)
      throw new HttpError(409, "Please finish signing up first.");
    // Registry cap: an abandoned practice circle (reset mid-way) still counts as one of the 5.
    const active = await c.read<bigint>(
      c.registry,
      abis.registry,
      "activeMemberships",
      [u.address],
    );
    if (active >= 5n)
      throw new HttpError(
        409,
        "You are already in 5 unfinished circles, the most anyone can be in. Restart the app for a fresh test chain.",
      );
    u.tutorial = await tut.create(u.address, u.name);
    return tut.view(u.tutorial);
  };

  app.get("/me", async (ctx) => ctx.json(await me(ctx.get("user"))));

  app.post("/onboard", async (ctx) => {
    const u = ctx.get("user");
    const { name } = await body(ctx, NameBody);
    const taken = [...users.values()].some(
      (o) => o !== u && o.name?.toLowerCase() === name.toLowerCase(),
    );
    if (taken)
      throw new HttpError(409, "That name is taken. Please pick another one.");
    u.name = name;
    // Under the chain lock, so two calls at once cannot both mint.
    const sent = await c.locked(async () => {
      if (
        !(await c.read<boolean>(c.registry, abis.registry, "verified", [
          u.address,
        ]))
      )
        await c.send(c.admin, c.registry, abis.registry, "setVerified", [
          u.address,
          true,
        ]);
      if ((await c.pub.getBalance({ address: u.address })) < 10n ** 18n)
        await c.setGas(u.address);
      if (u.granted) return false;
      u.granted = true;
      try {
        await c.send(c.admin, c.usdc, abis.usdc, "mint", [u.address, grant]);
      } catch (err) {
        u.granted = false;
        throw err;
      }
      return true;
    });
    return ctx.json({
      ...(await me(u)),
      grant: { musdc: grant.toString(), sent },
    });
  });

  app.post("/tutorial/start", async (ctx) => {
    const u = ctx.get("user");
    if (u.tutorial) return ctx.json(await tut.view(u.tutorial));
    // Two starts at once share one circle.
    u.starting ??= start(u).finally(() => {
      u.starting = null;
    });
    return ctx.json(await u.starting);
  });
  app.get("/tutorial", async (ctx) =>
    ctx.json(await tut.view(needTutorial(ctx.get("user")))),
  );
  app.post("/tutorial/next", async (ctx) => {
    const t = needTutorial(ctx.get("user"));
    const { stepId } = await body(ctx, NextBody);
    return ctx.json(await tut.next(t, stepId));
  });
  app.post("/tutorial/reset", async (ctx) =>
    ctx.json(await start(ctx.get("user"))),
  );

  app.get("/circles", async (ctx) => {
    const me = ctx.get("user").address.toLowerCase();
    const list = await c.read<readonly Address[]>(
      c.factory,
      abis.factory,
      "allCircles",
    );
    // Practice circles: only the caller's own (its names list includes them). Every other circle is listed.
    const mine = list.filter((a) => {
      const names = tut.practice.get(a.toLowerCase());
      return !names || names.has(me);
    });
    const rows = await Promise.all(
      mine.map(async (address) => {
        const s = await c.read<{
          name: string;
          status: number;
          memberCount: bigint;
          currentEpoch: bigint;
          fixedParams: { totalEpochs: number };
        }>(address, abis.circle, "getCircleState");
        const total = s.fixedParams.totalEpochs;
        return {
          address,
          name: s.name,
          status: CIRCLE_STATUS[s.status] ?? "Forming",
          members: Number(s.memberCount),
          round: Math.min(Number(s.currentEpoch), total),
          totalRounds: total,
          practice: tut.practice.has(address.toLowerCase()),
        };
      }),
    );
    return ctx.json(rows);
  });

  app.get("/circles/:address", async (ctx) => {
    const raw = ctx.req.param("address");
    if (!isAddress(raw, { strict: false }))
      throw new HttpError(400, "That is not a circle address.");
    const address = getAddress(raw);
    if (
      !(await c.read<boolean>(c.registry, abis.registry, "isCircle", [address]))
    )
      throw new HttpError(404, "There is no circle at that address.");
    const names = new Map(tut.practice.get(address.toLowerCase()) ?? []);
    for (const o of users.values())
      if (o.name) names.set(o.address.toLowerCase(), o.name);
    const f = await facts(address, ctx.get("user").address);
    return ctx.json(
      toSnapshot(f, names, tut.practice.has(address.toLowerCase())),
    );
  });

  return { app, chain: c };
};
