// Real-app server entry: `node services/dev-api/src/fuji-server.ts` (root script `pnpm start:app`).
// Without FUJI_ADMIN_PRIVATE_KEY the real app is off: every /api/app route answers 503.
import { existsSync } from "node:fs";
import { serve } from "@hono/node-server";
import { Hono } from "hono";
import { createFujiApp, parseFujiEnv } from "./fuji.ts";

// services/dev-api/.env (Privy app id/secret, gitignored) when present; the shell environment wins.
const local = new URL("../.env", import.meta.url);
if (existsSync(local)) process.loadEnvFile(local);

const PORT = Number(process.env.APP_PORT ?? 8788);
const HOST = process.env.APP_HOST ?? "127.0.0.1";
const OFF = "The real app is not set up on this server";

let fetcher: (req: Request) => Response | Promise<Response>;
if (!process.env.FUJI_ADMIN_PRIVATE_KEY) {
  const off = new Hono();
  off.all("*", (c) => c.json({ error: OFF }, 503));
  fetcher = off.fetch;
  console.log("app: FUJI_ADMIN_PRIVATE_KEY not set; the real app is off (503)");
} else {
  const { app, chain } = await createFujiApp(parseFujiEnv(process.env));
  fetcher = app.fetch;
  console.log(`app: chain ${chain.chainId}, admin ${chain.admin.address}`);
}
serve({ fetch: fetcher, hostname: HOST, port: PORT }, (info) => {
  console.log(`app listening on http://${HOST}:${info.port}/api/app`);
});
