import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    environment: "jsdom",
    include: ["apps/singularity_web/assets/test/**/*.test.{ts,tsx}"],
  },
});
