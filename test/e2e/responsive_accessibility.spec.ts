import type { Locator, Page } from "@playwright/test";

import { expect, test } from "./support/fixtures";

test.use({ screenshot: "off", trace: "off", video: "off" });

const samplePdf = "test/fixtures/assets/sample.pdf";

async function tabTo(page: Page, target: Locator, attempts = 30): Promise<void> {
  for (let attempt = 0; attempt < attempts; attempt += 1) {
    await page.keyboard.press("Tab");
    if (await target.evaluate((element) => element === document.activeElement)) {
      return;
    }
  }

  throw new Error(`Target was not keyboard reachable after ${attempts} Tab presses`);
}

async function expectHorizontallyInViewport(
  locator: Locator,
  viewportWidth: number,
): Promise<void> {
  const box = await locator.boundingBox();

  expect(box).not.toBeNull();
  expect(box?.width).toBeGreaterThanOrEqual(24);
  expect(box?.height).toBeGreaterThanOrEqual(24);
  expect(box?.x).toBeGreaterThanOrEqual(0);
  expect((box?.x ?? 0) + (box?.width ?? 0)).toBeLessThanOrEqual(viewportWidth);
}

test("workbench stays usable responsively and supports its workflow by keyboard", async ({
  page,
  loginAsOwner,
  unlockVault,
}) => {
  test.setTimeout(120_000);
  await page.setViewportSize({ width: 1280, height: 900 });

  await loginAsOwner();
  await unlockVault();
  await expect(page).toHaveURL("/assets");

  const uploadInput = page.getByLabel("Choose a file to upload", { exact: true });
  const uploadButton = page.getByRole("button", { name: "Upload asset", exact: true });
  await uploadInput.setInputFiles(samplePdf);
  await uploadInput.focus();
  await tabTo(page, uploadButton);
  await page.keyboard.press("Enter");

  await expect(page.locator(".upload-result")).toHaveText("Upload complete");
  const inspect = page.getByRole("button", { name: "Inspect sample.pdf", exact: true });
  await expect(inspect).toContainText("sample.pdf");
  await expect(
    page.getByRole("listitem").filter({ has: inspect }),
  ).toContainText("Ready", { timeout: 30_000 });

  await tabTo(page, inspect);
  await expect(inspect).toBeFocused();
  const focusStyle = await inspect.evaluate((element) => {
    const style = getComputedStyle(element);
    return {
      color: style.outlineColor,
      style: style.outlineStyle,
      width: Number.parseFloat(style.outlineWidth),
    };
  });
  expect(focusStyle.style).toBe("solid");
  expect(focusStyle.width).toBeGreaterThanOrEqual(3);
  expect(focusStyle.color).not.toBe("rgba(0, 0, 0, 0)");

  await page.keyboard.press("Enter");
  const inspector = page.getByLabel("Asset inspector", { exact: true });
  await expect(inspector).toBeVisible();
  await expect(inspector).not.toHaveAttribute("aria-modal", "true");
  await expect(inspect).toBeFocused();

  const closeInspector = page.getByRole("button", {
    name: "Close asset inspector",
    exact: true,
  });
  await tabTo(page, closeInspector);
  await expect(closeInspector).toBeFocused();
  await page.keyboard.press("Escape");
  await expect(inspector).toHaveCount(0);
  await expect(inspect).toBeFocused();

  await page.keyboard.press("Enter");
  await expect(inspector).toBeVisible();

  for (const width of [767, 1280]) {
    await page.setViewportSize({ width, height: 900 });

    const documentWidth = await page.evaluate(() => document.documentElement.scrollWidth);
    expect(documentWidth).toBeLessThanOrEqual(width);

    const nav = page.getByRole("navigation", { name: "Vault", exact: true });
    await expectHorizontallyInViewport(nav, width);
    for (const link of await nav.getByRole("link").all()) {
      await expectHorizontallyInViewport(link, width);
    }
    await expectHorizontallyInViewport(inspector, width);
    await expectHorizontallyInViewport(closeInspector, width);

    if (width === 767) {
      expect(await nav.evaluate((element) => getComputedStyle(element).display)).toBe("grid");
    }
  }

  await page.keyboard.press("Escape");
  await expect(inspector).toHaveCount(0);
  await expect(inspect).toBeFocused();

  await page.keyboard.press("Enter");
  await expect(inspector).toBeVisible();
  await page.getByRole("button", { name: "Delete", exact: true }).click();
  await expect(page.getByLabel("Asset action status", { exact: true })).toHaveText(
    "Delete requested.",
  );
  await expect(inspect).toHaveCount(0, { timeout: 30_000 });
  await expect(inspector).toHaveCount(0);

  const backupsLink = page.getByRole("link", { name: "Backups", exact: true });
  await tabTo(page, backupsLink);
  await page.keyboard.press("Enter");
  await expect(page).toHaveURL("/backups");
  await expect(
    page.getByRole("heading", { name: "Create encrypted backup", level: 2 }),
  ).toBeVisible();
});
