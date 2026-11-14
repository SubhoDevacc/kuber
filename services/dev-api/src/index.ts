import { existsSync } from "node:fs";
import { serve } from "@hono/node-server";
import { createApp } from "./app.ts";
import { parseEnv } from "./chain.ts";

// services/.env (local Anvil keys only) when present; the shell environment wins.
const shared = new URL("../../.env", import.meta.url);
if (existsSync(shared)) process.loadEnvFile(shared);

const env = parseEnv(process.env);
const { app, chain } = await createApp(env);

// Without hostname the server binds every interface; dev-api stays on loopback.
serve({ fetch: app.fetch, hostname: "127.0.0.1", port: env.PORT }, (info) => {
  console.log(
    `dev-api listening on http://127.0.0.1:${info.port} (chain ${chain.chainId}, dev mode ${env.DEV_MODE})`,
  );
});
