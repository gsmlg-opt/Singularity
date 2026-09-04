import { mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { defineConfig } from "@playwright/test";

const runId = process.env.SINGULARITY_TEST_RUN_ID ?? crypto.randomUUID();
const artifactRunId = crypto.randomUUID();
const stateDirectory = join(tmpdir(), "singularity", "playwright");
const stateFile = join(stateDirectory, `${runId}.json`);

mkdirSync(stateDirectory, { mode: 0o700, recursive: true });
process.env.SINGULARITY_TEST_RUN_ID = runId;
process.env.SINGULARITY_BROWSER_STATE_FILE = stateFile;

const chromiumExecutablePath = process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH;

if (!chromiumExecutablePath) {
  throw new Error("PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH must point to system Chromium");
}

export default defineConfig({
  outputDir: join(stateDirectory, artifactRunId),
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
      SINGULARITY_BROWSER_STATE_FILE: stateFile,
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
