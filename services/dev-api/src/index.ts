import { serve } from "@hono/node-server";
import { Hono } from "hono";

const app = new Hono();
app.get("/health", (c) => c.json({ ok: true }));

// Without hostname the server binds every interface; dev-api stays on loopback.
serve({ fetch: app.fetch, hostname: "127.0.0.1", port: 8787 }, (info) => {
  console.log(`dev-api listening on http://127.0.0.1:${info.port}`);
});
