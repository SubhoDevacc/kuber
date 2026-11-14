import { resolve } from "node:path";
import tailwindcss from "@tailwindcss/vite";
import react from "@vitejs/plugin-react";
import { defineConfig, loadEnv } from "vite";

const here = import.meta.dirname;

// Keep Vite's loopback-only default bind (T-00-04). strictPort: fail if the port is busy.
export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, here, "");
  const api = env.KUBER_API_TARGET || "http://127.0.0.1:8787";
  const rpc = env.KUBER_RPC_TARGET || "http://127.0.0.1:8545";
  return {
    plugins: [react(), tailwindcss()],
    resolve: {
      alias: {
        "@kuber/shared": resolve(here, "../../packages/shared/src/index.ts"),
      },
    },
    server: {
      strictPort: true,
      proxy: {
        "/api": {
          target: api,
          changeOrigin: true,
          rewrite: (path) => path.replace(/^\/api/, ""),
        },
        "/rpc": {
          target: rpc,
          changeOrigin: true,
          rewrite: (path) => path.replace(/^\/rpc/, ""),
        },
      },
    },
  };
});
