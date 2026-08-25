import { spawnSync } from "node:child_process";
import {
  closeSync,
  constants,
  lstatSync,
  openSync,
  readFileSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { isAbsolute, join, resolve } from "node:path";

import { expect, test as base, type BrowserContext, type Page } from "@playwright/test";

const ownerLogins = {
  primary: "owner@singularity.local",
  secondary: "secondary-owner@singularity.local",
} as const;
const passwordDomain = "singularity-browser-test-owner-password:v1:";
const passwordPrefix = "singularity-test-";
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const anyUuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

export type BrowserOwnerRole = keyof typeof ownerLogins;

type BrowserOwner = {
  accountId: string;
  login: string;
  principalId: string;
  vaultId: string;
};

export type BrowserState = {
  backupRoot: string;
  owners: Record<BrowserOwnerRole, BrowserOwner>;
  runId: string;
  stateFile: string;
  version: 1;
};

type RestoreInput = {
  expectedSnapshot: unknown;
  passphrase: string;
  source: string;
};

type RestoreResult = { marker: "notes_browser_restore_ok=true" };

export type BrowserRestoreInvocation = {
  args: string[];
  environment: NodeJS.ProcessEnv;
  input: string;
};

type BrowserActions = {
  browserState: BrowserState;
  loginAsOwner: () => Promise<void>;
  loginAsPrimary: () => Promise<void>;
  loginAsSecondary: () => Promise<void>;
  restoreBrowserBackup: (input: RestoreInput) => RestoreResult;
  unlockVault: () => Promise<void>;
  unlockPrimary: () => Promise<void>;
  unlockSecondary: () => Promise<void>;
};

export async function deriveBrowserTestOwnerPassword(
  runId: string,
  role: BrowserOwnerRole = "primary",
): Promise<string> {
  const digest = new Uint8Array(
    await crypto.subtle.digest(
      "SHA-256",
      new TextEncoder().encode(`${passwordDomain}${role}:${runId}`),
    ),
  );
  const base64 = btoa(Array.from(digest, (byte) => String.fromCharCode(byte)).join(""));
  const base64Url = base64.replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");

  return passwordPrefix + base64Url;
}

export async function loginAsOwner(
  page: Page,
  password: string,
  role: BrowserOwnerRole = "primary",
): Promise<void> {
  await page.goto("/login");
  await expect(page.getByRole("heading", { name: "Sign in", level: 1 })).toBeVisible();
  await page.getByLabel("Login", { exact: true }).fill(ownerLogins[role]);
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

function exactRecord(value: unknown, keys: readonly string[]): value is Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) return false;
  const actual = Object.keys(value);
  return actual.length === keys.length && keys.every((key) => actual.includes(key));
}

function decodeOwner(value: unknown, role: BrowserOwnerRole): BrowserOwner | null {
  if (
    !exactRecord(value, ["login", "account_id", "principal_id", "vault_id"]) ||
    value.login !== ownerLogins[role] ||
    typeof value.account_id !== "string" ||
    !anyUuid.test(value.account_id) ||
    typeof value.principal_id !== "string" ||
    !anyUuid.test(value.principal_id) ||
    typeof value.vault_id !== "string" ||
    !anyUuid.test(value.vault_id)
  ) {
    return null;
  }

  return {
    accountId: value.account_id,
    login: ownerLogins[role],
    principalId: value.principal_id,
    vaultId: value.vault_id,
  };
}

export function loadBrowserState(): BrowserState {
  const stateFile = process.env.SINGULARITY_BROWSER_STATE_FILE;
  if (!stateFile || !isAbsolute(stateFile) || resolve(stateFile) !== stateFile) {
    throw new Error("Browser state path was not initialized canonically");
  }

  const stat = lstatSync(stateFile);
  if (!stat.isFile() || stat.isSymbolicLink() || (stat.mode & 0o777) !== 0o600) {
    throw new Error("Browser state file ownership mode is invalid");
  }

  let decoded: unknown;
  try {
    decoded = JSON.parse(readFileSync(stateFile, "utf8"));
  } catch {
    throw new Error("Browser state file is invalid");
  }

  if (
    !exactRecord(decoded, ["version", "run_id", "backup_root", "owners"]) ||
    decoded.version !== 1 ||
    typeof decoded.run_id !== "string" ||
    !uuid.test(decoded.run_id) ||
    decoded.run_id !== playwrightRunId() ||
    typeof decoded.backup_root !== "string" ||
    !isAbsolute(decoded.backup_root) ||
    resolve(decoded.backup_root) !== decoded.backup_root ||
    !exactRecord(decoded.owners, ["primary", "secondary"])
  ) {
    throw new Error("Browser state file is invalid");
  }

  const primary = decodeOwner(decoded.owners.primary, "primary");
  const secondary = decodeOwner(decoded.owners.secondary, "secondary");
  if (!primary || !secondary) throw new Error("Browser state owner coordinates are invalid");
  if (
    primary.accountId === secondary.accountId ||
    primary.principalId === secondary.principalId ||
    primary.vaultId === secondary.vaultId
  ) {
    throw new Error("Browser state owners are not isolated");
  }

  return {
    backupRoot: decoded.backup_root,
    owners: { primary, secondary },
    runId: decoded.run_id,
    stateFile: realpathSync(stateFile),
    version: 1,
  };
}

export async function loginAndUnlock(page: Page, role: BrowserOwnerRole): Promise<void> {
  const password = await deriveBrowserTestOwnerPassword(playwrightRunId(), role);
  await loginAsOwner(page, password, role);
  await expect(page).toHaveURL("/vault/unlock");
  await unlockVault(page, password);
  await expect(page).toHaveURL("/assets");
}

export async function newAuthenticatedPage(
  context: BrowserContext,
  role: BrowserOwnerRole,
): Promise<Page> {
  const page = await context.newPage();
  await loginAndUnlock(page, role);
  return page;
}

function writeExpectedSnapshot(snapshot: unknown): string {
  const expectedPath = join(
    tmpdir(),
    `singularity-notes-browser-expected-${playwrightRunId()}-${crypto.randomUUID()}.json`,
  );
  const descriptor = openSync(
    expectedPath,
    constants.O_CREAT | constants.O_EXCL | constants.O_WRONLY,
    0o600,
  );

  try {
    writeFileSync(descriptor, JSON.stringify(snapshot), { encoding: "utf8" });
  } finally {
    closeSync(descriptor);
  }

  return expectedPath;
}

export function browserRestoreInvocation(
  source: string,
  expected: string,
  passphrase: string,
): BrowserRestoreInvocation {
  const args = [
    "singularity.test.browser_restore",
    "--source",
    source,
    "--expected",
    expected,
    "--passphrase-fd",
    "0",
  ];
  const environment = { ...process.env, MIX_ENV: "test" };

  if (args.includes(passphrase) || Object.values(environment).includes(passphrase)) {
    throw new Error("Restore secret transport is invalid");
  }

  return { args, environment, input: passphrase };
}

function runBrowserRestore(input: RestoreInput): RestoreResult {
  const state = loadBrowserState();
  const source = realpathSync(input.source);
  const backupRoot = realpathSync(state.backupRoot);
  if (!source.startsWith(`${backupRoot}/`))
    throw new Error("Restore source is outside backup root");

  const expected = writeExpectedSnapshot(input.expectedSnapshot);

  try {
    const invocation = browserRestoreInvocation(source, expected, input.passphrase);
    const child = spawnSync("mix", invocation.args, {
      cwd: process.cwd(),
      encoding: "utf8",
      env: invocation.environment,
      input: invocation.input,
      killSignal: "SIGKILL",
      timeout: 120_000,
    });

    if (child.error || child.signal || child.status !== 0) {
      throw new Error("Notes browser restore failed");
    }
    if (child.stderr !== "" || child.stdout.trim() !== "notes_browser_restore_ok=true") {
      throw new Error("Notes browser restore emitted unexpected output");
    }

    return { marker: "notes_browser_restore_ok=true" };
  } finally {
    rmSync(expected, { force: true });
  }
}

export const test = base.extend<BrowserActions>({
  browserState: async ({}, use) => {
    await use(loadBrowserState());
  },
  loginAsOwner: async ({ page }, use) => {
    const password = await deriveBrowserTestOwnerPassword(playwrightRunId(), "primary");
    await use(() => loginAsOwner(page, password));
  },
  loginAsPrimary: async ({ page }, use) => {
    const password = await deriveBrowserTestOwnerPassword(playwrightRunId(), "primary");
    await use(() => loginAsOwner(page, password, "primary"));
  },
  loginAsSecondary: async ({ page }, use) => {
    const password = await deriveBrowserTestOwnerPassword(playwrightRunId(), "secondary");
    await use(() => loginAsOwner(page, password, "secondary"));
  },
  restoreBrowserBackup: async ({}, use) => {
    await use(runBrowserRestore);
  },
  unlockVault: async ({ page }, use) => {
    const password = await deriveBrowserTestOwnerPassword(playwrightRunId(), "primary");
    await use(() => unlockVault(page, password));
  },
  unlockPrimary: async ({ page }, use) => {
    const password = await deriveBrowserTestOwnerPassword(playwrightRunId(), "primary");
    await use(() => unlockVault(page, password));
  },
  unlockSecondary: async ({ page }, use) => {
    const password = await deriveBrowserTestOwnerPassword(playwrightRunId(), "secondary");
    await use(() => unlockVault(page, password));
  },
});

export { expect };
