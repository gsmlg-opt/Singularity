import { defineConfig } from "@playwright/test";

declare const process: {
  env: Record<string, string | undefined>;
};

const runId = process.env.SINGULARITY_TEST_RUN_ID ?? crypto.randomUUID();
process.env.SINGULARITY_TEST_RUN_ID = runId;

const chromiumExecutablePath = process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH;

if (!chromiumExecutablePath) {
  throw new Error("PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH must point to system Chromium");
}

export default defineConfig({
  testDir: "./test/e2e",
  testMatch: "**/*.spec.ts",
  workers: 1,
  projects: [
    {
      name: "chromium",
      use: { browserName: "chromium" },
    },
  ],
  use: {
    baseURL: "http://127.0.0.1:4002",
    launchOptions: {
      executablePath: chromiumExecutablePath,
    },
  },
  webServer: {
    command: "MIX_ENV=test mix singularity.test.browser serve",
    url: "http://127.0.0.1:4002/login",
    env: {
      ...process.env,
      SINGULARITY_TEST_RUN_ID: runId,
      SINGULARITY_START_INFRASTRUCTURE: "true",
    },
    reuseExistingServer: false,
    gracefulShutdown: {
      signal: "SIGTERM",
      timeout: 15_000,
    },
  },
});
