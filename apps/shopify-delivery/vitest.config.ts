import { defineConfig } from "vitest/config";

// Separate from vite.config.ts so the React Router plugin does not load for unit tests.
export default defineConfig({
  test: { include: ["test/**/*.test.ts"], environment: "node" },
});
