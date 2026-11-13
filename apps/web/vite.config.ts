import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

// Keep Vite's loopback-only default bind (T-00-04). strictPort: fail if 5173 (Privy's allowed origin later) is busy.
export default defineConfig({
  plugins: [react()],
  server: { strictPort: true },
});
