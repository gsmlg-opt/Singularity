import { expect, test as base, type Page } from "@playwright/test";

declare const process: {
  env: Record<string, string | undefined>;
};

const ownerLogin = "owner@singularity.local";
const passwordDomain = "singularity-browser-test-owner-password:v1:";
const passwordPrefix = "singularity-test-";

type BrowserActions = {
  loginAsOwner: () => Promise<void>;
  unlockVault: () => Promise<void>;
};

export async function deriveBrowserTestOwnerPassword(runId: string): Promise<string> {
  const digest = new Uint8Array(
    await crypto.subtle.digest("SHA-256", new TextEncoder().encode(passwordDomain + runId)),
  );
  const base64 = btoa(Array.from(digest, (byte) => String.fromCharCode(byte)).join(""));
  const base64Url = base64.replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");

  return passwordPrefix + base64Url;
}

export async function loginAsOwner(page: Page, password: string): Promise<void> {
  await page.goto("/login");
  await expect(page.getByRole("heading", { name: "Sign in", level: 1 })).toBeVisible();
  await page.getByLabel("Login", { exact: true }).fill(ownerLogin);
  await page.getByLabel("Password", { exact: true }).fill(password);
  await page.getByRole("button", { name: "Sign in", exact: true }).click();
}

export async function unlockVault(page: Page, password: string): Promise<void> {
  await expect(page.getByRole("heading", { name: "Unlock vault", level: 1 })).toBeVisible();
  await page.getByLabel("Password", { exact: true }).fill(password);
  await page.getByRole("button", { name: "Unlock", exact: true }).click();
}

function playwrightRunId(): string {
  const runId = process.env.SINGULARITY_TEST_RUN_ID;

  if (!runId) {
    throw new Error("SINGULARITY_TEST_RUN_ID was not initialized by Playwright config");
  }

  return runId;
}

export const test = base.extend<BrowserActions>({
  loginAsOwner: async ({ page }, use) => {
    const password = await deriveBrowserTestOwnerPassword(playwrightRunId());
    await use(() => loginAsOwner(page, password));
  },
  unlockVault: async ({ page }, use) => {
    const password = await deriveBrowserTestOwnerPassword(playwrightRunId());
    await use(() => unlockVault(page, password));
  },
});

export { expect };
