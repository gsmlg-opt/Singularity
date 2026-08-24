import AxeBuilder from "@axe-core/playwright";
import type { Browser, Locator, Page } from "@playwright/test";

import { expect, loginAndUnlock, test } from "./support/fixtures";

test.use({ screenshot: "off", trace: "off", video: "off" });

test.afterEach(async ({ page }, testInfo) => {
  if (testInfo.status === testInfo.expectedStatus) return;
  await page
    .evaluate(() => document.body.replaceChildren("Private state redacted"))
    .catch(() => {});
});

async function tabTo(page: Page, target: Locator, attempts = 60): Promise<void> {
  for (let attempt = 0; attempt < attempts; attempt += 1) {
    await page.keyboard.press("Tab");
    if (await target.evaluate((element) => element === document.activeElement)) return;
  }
  throw new Error("Named Notes control was not keyboard reachable");
}

async function activate(page: Page, target: Locator): Promise<void> {
  await tabTo(page, target);
  await expect(target).toBeFocused();
  await page.keyboard.press("Enter");
}

async function axeClean(page: Page, state: string): Promise<void> {
  const results = await new AxeBuilder({ page }).analyze();
  if (results.violations.length > 0) {
    const targets = results.violations
      .flatMap(({ nodes }) => nodes.flatMap(({ target }) => target.map(String)))
      .map((target) => target.replace(/"[^"]*"/g, '"redacted"'));
    throw new Error(
      `${state} accessibility violations: ${results.violations.map(({ id }) => id).join(", ")} at ${targets.join(", ")}`,
    );
  }
}

async function expectNoOverflow(page: Page, state: string): Promise<void> {
  const geometry = await page.evaluate(() => {
    const workspace = document.querySelector<HTMLElement>('[aria-label="Private notes workspace"]');
    if (!workspace) throw new Error("Missing private notes workspace");
    const activePanel = workspace.dataset.activePanel;
    const namedPanels = [...workspace.querySelectorAll<HTMLElement>("[data-panel]")].map(
      (panel) => ({
        name: panel.dataset.panel,
        visible: getComputedStyle(panel).display !== "none",
        width: panel.getBoundingClientRect().width,
      }),
    );
    return {
      activePanel,
      clientWidth: document.documentElement.clientWidth,
      namedPanels,
      scrollWidth: document.documentElement.scrollWidth,
    };
  });

  expect(geometry.scrollWidth, `${state} horizontal document geometry`).toBeLessThanOrEqual(
    geometry.clientWidth,
  );
  expect(["rail", "editor", "drawer"]).toContain(geometry.activePanel);
  expect(
    geometry.namedPanels.some(
      (panel) => panel.name === geometry.activePanel && panel.visible && panel.width > 0,
    ),
    `${state} active named panel geometry`,
  ).toBe(true);
}

async function openNotesByKeyboard(page: Page): Promise<void> {
  await activate(page, page.getByRole("link", { name: "Notes", exact: true }));
  await expect(page).toHaveURL("/notes");
  await expect(page.getByRole("region", { name: "Private notes workspace" })).toBeVisible();
}

async function secondaryNotesPage(
  browser: Browser,
  title: string,
): Promise<{
  context: Awaited<ReturnType<Browser["newContext"]>>;
  page: Page;
}> {
  const context = await browser.newContext({ baseURL: "http://127.0.0.1:4002" });
  const page = await context.newPage();
  await loginAndUnlock(page, "secondary");
  await openNotesByKeyboard(page);
  await activate(page, page.getByRole("button", { name: `Open ${title}`, exact: true }));
  await activate(page, page.getByRole("button", { name: "Open current", exact: true }));
  return { context, page };
}

test("Notes is keyboard complete, responsive, themed, reduced-motion, and axe clean", async ({
  browser,
  browserState,
  page,
  loginAsSecondary,
  unlockSecondary,
}) => {
  test.setTimeout(180_000);
  const title = `Keyboard ${browserState.runId.slice(0, 8)}`;
  const initialMarkdown = "Keyboard-only private draft";
  const canonicalMarkdown = "Keyboard-only canonical edit";
  const competingMarkdown = "Keyboard-only competing edit";
  const mergedMarkdown = "Keyboard-only merged result";

  await page.setViewportSize({ width: 1280, height: 900 });
  await loginAsSecondary();
  await unlockSecondary();
  await openNotesByKeyboard(page);
  await axeClean(page, "empty Notes workspace");

  await test.step("keyboard create, Save, drawer, and dirty dialog focus semantics", async () => {
    await activate(page, page.getByRole("button", { name: "New note", exact: true }));
    const titleInput = page.getByLabel("Note title", { exact: true });
    await expect(titleInput).toBeFocused();
    await page.keyboard.insertText(title);
    await page.keyboard.press("Tab");
    const markdown = page.getByLabel("Markdown source", { exact: true });
    await expect(markdown).toBeFocused();
    await page.keyboard.insertText(initialMarkdown);
    await page.keyboard.press("Control+s");
    await expect(page.getByText("Version 1 · Saved", { exact: true })).toBeVisible();
    await expect(page.getByLabel("Notes workspace status", { exact: true })).toHaveText(
      "Note created.",
    );
    await axeClean(page, "saved note");

    const preview = page.getByRole("button", { name: "Preview", exact: true });
    await activate(page, preview);
    const drawer = page.getByRole("complementary", { name: "Preview drawer", exact: true });
    await expect(drawer).toBeVisible();
    await expect(page.getByRole("button", { name: "Close details", exact: true })).toBeFocused();
    await axeClean(page, "preview drawer");
    await page.keyboard.press("Escape");
    await expect(drawer).toHaveCount(0);
    await expect(preview).toBeFocused();

    await page.getByLabel("Markdown source", { exact: true }).focus();
    await page.keyboard.press("End");
    await page.keyboard.insertText(" dirty");
    await expect(page.getByText("Version 1 · Unsaved changes", { exact: true })).toBeVisible();
    const newNote = page.getByRole("button", { name: "New note", exact: true });
    await activate(page, newNote);
    const dialog = page.getByRole("dialog", { name: "Discard your changes?", exact: true });
    await expect(dialog).toBeVisible();
    const stay = page.getByRole("button", { name: "Stay", exact: true });
    const discard = page.getByRole("button", { name: "Discard", exact: true });
    await expect(stay).toBeFocused();
    await page.keyboard.press("Shift+Tab");
    await expect(discard).toBeFocused();
    await page.keyboard.press("Tab");
    await expect(stay).toBeFocused();
    await axeClean(page, "dirty navigation dialog");
    await page.keyboard.press("Escape");
    await expect(dialog).toHaveCount(0);
    await expect(newNote).toBeFocused();

    await page.keyboard.press("Enter");
    await expect(stay).toBeFocused();
    await page.keyboard.press("Tab");
    await expect(discard).toBeFocused();
    await page.keyboard.press("Enter");
    await expect(page.getByText("New · Unsaved", { exact: true })).toBeVisible();
    await activate(page, page.getByRole("button", { name: `Open ${title}`, exact: true }));
    await activate(page, page.getByRole("button", { name: "Open current", exact: true }));
    await expect(page.getByLabel("Notes workspace status", { exact: true })).toHaveText(
      "Current note opened.",
    );
    await expect(page.getByText("Version 1 · Saved", { exact: true })).toBeVisible();
  });

  const second = await secondaryNotesPage(browser, title);

  try {
    await test.step("keyboard canonical edit, competing conflict, merge, Trash, and restore", async () => {
      const markdown = page.getByLabel("Markdown source", { exact: true });
      await markdown.focus();
      await page.keyboard.press("Control+a");
      await page.keyboard.insertText(canonicalMarkdown);
      await page.keyboard.press("Control+s");
      await expect(page.getByText("Version 2 · Saved", { exact: true })).toBeVisible();

      const competing = second.page.getByLabel("Markdown source", { exact: true });
      await competing.focus();
      await second.page.keyboard.press("Control+a");
      await second.page.keyboard.insertText(competingMarkdown);
      await second.page.keyboard.press("Control+s");
      await expect(second.page.getByLabel("Notes workspace status", { exact: true })).toHaveText(
        "A newer current version exists. Review the preserved conflict before merging.",
      );

      await activate(
        second.page,
        second.page.getByRole("button", { name: "Conflict", exact: true }),
      );
      await expect(second.page.getByLabel("Current", { exact: true })).toBeVisible();
      await expect(second.page.getByLabel("Competing", { exact: true })).toBeVisible();
      await axeClean(second.page, "open conflict drawer");

      await activate(
        second.page,
        second.page.getByRole("button", { name: "Merge these versions", exact: true }),
      );
      const mergeEditor = second.page.getByLabel("Markdown source", { exact: true });
      await mergeEditor.focus();
      await second.page.keyboard.press("Control+a");
      await second.page.keyboard.insertText(mergedMarkdown);
      await second.page.keyboard.press("Control+s");
      await expect(second.page.getByText("Version 4 · Saved", { exact: true })).toBeVisible();
      await axeClean(second.page, "merged note");

      await activate(second.page, second.page.getByRole("button", { name: "Delete", exact: true }));
      await expect(second.page.getByLabel("Notes workspace status", { exact: true })).toHaveText(
        "Note moved to Trash.",
      );
      await activate(second.page, second.page.getByRole("button", { name: "Trash", exact: true }));
      const restore = second.page.getByRole("button", { name: `Restore ${title}`, exact: true });
      await expect(restore).toBeVisible();
      await axeClean(second.page, "Trash list");
      await activate(second.page, restore);
      await expect(second.page.getByLabel("Notes workspace status", { exact: true })).toHaveText(
        "Note restored.",
      );
    });

    await test.step("computed geometry covers phone, tablet, and desktop active panels", async () => {
      for (const width of [390, 900, 1280]) {
        await second.page.setViewportSize({ width, height: 900 });
        if (width < 1008) {
          await second.page.getByRole("button", { name: "Show notes", exact: true }).click();
          await expect(
            second.page.locator('[aria-label="Private notes workspace"]'),
          ).toHaveAttribute("data-active-panel", "rail");
        }
        await expectNoOverflow(second.page, `${width}px Notes workspace`);
        await axeClean(second.page, `${width}px Notes workspace`);
      }
    });

    await test.step("light, dark, and reduced-motion preferences remain accessible", async () => {
      await second.page.setViewportSize({ width: 1280, height: 900 });
      await activate(second.page, second.page.getByRole("link", { name: "Assets", exact: true }));
      await expect(
        second.page.getByRole("button", { name: "Switch to dark theme", exact: true }),
      ).toBeVisible();
      await expect(second.page.locator("html")).toHaveAttribute("data-theme", "light");
      await openNotesByKeyboard(second.page);
      await expect(second.page.locator("html")).toHaveAttribute("data-theme", "light");
      await axeClean(second.page, "light Notes workspace");

      await activate(second.page, second.page.getByRole("link", { name: "Assets", exact: true }));
      await activate(
        second.page,
        second.page.getByRole("button", { name: "Switch to dark theme", exact: true }),
      );
      await openNotesByKeyboard(second.page);
      await expect(second.page.locator("html")).toHaveAttribute("data-theme", "dark");
      await axeClean(second.page, "dark Notes workspace");

      await second.page.emulateMedia({ reducedMotion: "reduce" });
      const motion = await second.page
        .locator('[aria-label="Private notes workspace"]')
        .evaluate((workspace) => {
          const style = getComputedStyle(workspace);
          return {
            animation: Number.parseFloat(style.animationDuration) || 0,
            transition: Number.parseFloat(style.transitionDuration) || 0,
          };
        });
      expect(motion.animation).toBeLessThanOrEqual(0.00001);
      expect(motion.transition).toBeLessThanOrEqual(0.00001);
      await expectNoOverflow(second.page, "reduced-motion Notes workspace");
      await axeClean(second.page, "reduced-motion Notes workspace");
    });
  } finally {
    await second.context.close();
  }
});
