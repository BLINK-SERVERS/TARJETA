import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import { readFileSync } from "node:fs";

const pkg = JSON.parse(
  readFileSync(new URL("./package.json", import.meta.url), "utf-8")
) as { version: string };

export default defineConfig({
  base: "/",
  plugins: [react()],
  define: { __APP_VERSION__: JSON.stringify(pkg.version) },
  server: { port: 5175 },
  preview: { port: 4175 },
  build: {
    target: "es2022",
    cssTarget: ["chrome123", "safari17.5", "firefox120", "edge123"],
  },
});
