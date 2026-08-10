import { readFile } from "node:fs/promises";

import type { Page } from "@playwright/test";

import { expect, test } from "./support/fixtures";

test.use({ screenshot: "off", trace: "off", video: "off" });

const assetFixtures = [
  { filename: "sample.pdf", path: "test/fixtures/assets/sample.pdf" },
  { filename: "sample.jpg", path: "test/fixtures/assets/sample.jpg" },
  { filename: "sample.png", path: "test/fixtures/assets/sample.png" },
] as const;

function assetRow(page: Page, filename: string) {
  return page
    .getByRole("listitem")
    .filter({ has: page.getByRole("button", { name: `Inspect ${filename}`, exact: true }) });
}

async function uploadAsset(page: Page, fixture: (typeof assetFixtures)[number]) {
  await page.getByLabel("Choose a file to upload", { exact: true }).setInputFiles(fixture.path);
  await expect(page.getByText(fixture.filename, { exact: true })).toBeVisible();
  await page.getByRole("button", { name: "Upload asset", exact: true }).click();
  await expect(page.locator(".upload-result")).toHaveText("Upload complete");
  await expect(assetRow(page, fixture.filename)).toContainText("Ready", { timeout: 30_000 });
}

test("owner completes the visible asset and backup workflow", async ({
  page,
  loginAsOwner,
  unlockVault,
}) => {
  test.setTimeout(120_000);

  await test.step("login and unlock the empty vault", async () => {
    await loginAsOwner();

    await expect(page).toHaveURL("/vault/unlock");
    await expect(page.getByRole("heading", { name: "Unlock vault", level: 1 })).toBeVisible();

    await unlockVault();

    await expect(page).toHaveURL("/assets");
    await expect(page.getByRole("heading", { name: "Vault assets", level: 1 })).toBeVisible();
    await expect(
      page.getByText("No assets match the current catalogue filters.", { exact: true }),
    ).toBeVisible();
  });

  await test.step("upload PDF, JPEG, and PNG assets through Ready", async () => {
    for (const fixture of assetFixtures) {
      await uploadAsset(page, fixture);
    }
  });

  await test.step("search, filter, and follow the real next cursor", async () => {
    const query = page.getByLabel("Search vault assets", { exact: true });
    const lifecycle = page.getByLabel("Filter by lifecycle state", { exact: true });
    const mediaType = page.getByLabel("Filter by media type", { exact: true });
    const search = page.getByRole("button", { name: "Search", exact: true });
    const loadMore = page.getByRole("button", { name: "Load more assets", exact: true });

    await query.fill("sample.pdf");
    await search.click();
    await expect(page.getByText("1 shown", { exact: true })).toBeVisible();
    await expect(assetRow(page, "sample.pdf")).toHaveCount(1);
    await expect(page.getByRole("listitem")).toHaveCount(1);
    await expect(loadMore).toHaveCount(0);

    await query.fill("");
    await lifecycle.selectOption("ready");
    await mediaType.selectOption("application/pdf");
    await search.click();
    await expect(page.getByText("1 shown", { exact: true })).toBeVisible();
    await expect(assetRow(page, "sample.pdf")).toContainText("Ready");
    await expect(page.getByRole("listitem")).toHaveCount(1);

    await mediaType.selectOption("");
    await search.click();
    await expect(page.getByText("2 shown", { exact: true })).toBeVisible();
    await expect(page.getByRole("listitem")).toHaveCount(2);

    await expect(loadMore).toBeVisible();
    await loadMore.click();
    await expect(page.getByLabel("Asset list status", { exact: true })).toHaveText(
      "Additional assets loaded.",
    );
    await expect(page.getByText("3 shown", { exact: true })).toBeVisible();
    await expect(page.getByRole("listitem")).toHaveCount(3);
    for (const fixture of assetFixtures) {
      await expect(assetRow(page, fixture.filename)).toHaveCount(1);
    }
    await expect(loadMore).toHaveCount(0);
  });

  await test.step("download identical original bytes and delete the asset", async () => {
    const fixture = assetFixtures[0];
    await page.getByRole("button", { name: `Inspect ${fixture.filename}`, exact: true }).click();
    await expect(page.getByLabel("Asset inspector", { exact: true })).toContainText("Ready");

    const downloadPromise = page.waitForEvent("download");
    await page.getByRole("link", { name: `Download ${fixture.filename}`, exact: true }).click();
    const download = await downloadPromise;

    expect(download.suggestedFilename()).toBe(fixture.filename);
    expect(await readFile(await download.path())).toEqual(await readFile(fixture.path));

    await page.getByRole("button", { name: "Close asset inspector", exact: true }).click();
    await page.getByLabel("Filter by lifecycle state", { exact: true }).selectOption("");
    await page.getByRole("button", { name: "Search", exact: true }).click();
    await expect(page.getByText("2 shown", { exact: true })).toBeVisible();
    const loadMore = page.getByRole("button", { name: "Load more assets", exact: true });
    await loadMore.click();
    await expect(page.getByText("3 shown", { exact: true })).toBeVisible();

    await page.getByRole("button", { name: `Inspect ${fixture.filename}`, exact: true }).click();
    await page.getByRole("button", { name: "Delete", exact: true }).click();
    await expect(page.getByLabel("Asset action status", { exact: true })).toHaveText(
      "Delete requested.",
    );
    await expect(assetRow(page, fixture.filename)).toHaveCount(0, { timeout: 30_000 });
    await expect(page.getByLabel("Asset inspector", { exact: true })).toHaveCount(0);
  });

  await test.step("create a sealed backup without persisting its passphrase", async () => {
    await page.getByRole("link", { name: "Backups", exact: true }).click();
    await expect(page).toHaveURL("/backups");
    await expect(
      page.getByRole("heading", { name: "Create encrypted backup", level: 2 }),
    ).toBeVisible();

    const backupOrigin = new URL(page.url()).origin;
    const backupRequestPromise = page.waitForRequest((request) => {
      const url = new URL(request.url());
      return request.method() === "POST" && url.pathname === "/backups";
    });
    const backupRedirectPromise = page.waitForURL((url) => {
      const operationId = url.searchParams.get("operation_id");
      return (
        url.origin === backupOrigin &&
        url.pathname === "/backups" &&
        operationId !== null &&
        /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(operationId)
      );
    });

    await page.getByLabel("Backup passphrase", { exact: true }).fill(crypto.randomUUID());
    await page.getByRole("button", { name: "Create encrypted backup", exact: true }).click();

    const backupRequest = await backupRequestPromise;
    await backupRedirectPromise;
    const backupUrl = new URL(backupRequest.url());
    expect(backupRequest.method()).toBe("POST");
    expect(backupUrl.origin).toBe(backupOrigin);
    expect(backupUrl.pathname).toBe("/backups");
    expect(await backupRequest.headerValue("content-type")).toMatch(
      /^application\/x-www-form-urlencoded(?:;|$)/i,
    );
    await expect(page.locator("#backup-status")).toHaveText("Encrypted backup sealed.", {
      timeout: 45_000,
    });
  });

  await test.step("show restore-only integrity acceptance in Audit", async () => {
    let sawIntegrityRequest = false;
    page.on("request", (request) => {
      if (new URL(request.url()).pathname.toLowerCase().includes("integrity")) {
        sawIntegrityRequest = true;
      }
    });

    await page.getByRole("link", { name: "Audit", exact: true }).click();
    await expect(page).toHaveURL("/audit");
    await expect(
      page.getByRole("heading", { name: "Restore integrity acceptance", level: 2 }),
    ).toBeVisible();
    await expect(page.getByText("mix singularity.test.restore", { exact: true })).toBeVisible();
    await expect(
      page.getByText("This page does not perform an integrity audit against the live vault.", {
        exact: true,
      }),
    ).toBeVisible();
    await expect(page.getByRole("button", { name: /integrity/i })).toHaveCount(0);
    await expect(page.getByText("Integrity audit passed", { exact: true })).toHaveCount(0);
    expect(sawIntegrityRequest).toBe(false);
  });
});
