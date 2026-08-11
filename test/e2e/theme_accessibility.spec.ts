import AxeBuilder from "@axe-core/playwright";
import type { Page } from "@playwright/test";

import { expect, test } from "./support/fixtures";

test.use({ screenshot: "off", trace: "off", video: "off" });

type Theme = "light" | "dark";

type ContrastSample = {
  additionalText?: Array<{
    background: string;
    label: string;
    text: string;
  }>;
  control?: string;
  controlBackground?: string;
  controlColor?: "border" | "foreground";
  focus: string;
  focusBackground: string;
  text: string;
  textBackground: string;
};

async function expectAxeClean(page: Page, surface: string): Promise<void> {
  const results = await new AxeBuilder({ page }).analyze();
  expect(results.violations, `${surface} axe violations`).toEqual([]);
}

async function tabTo(page: Page, selector: string, attempts = 30): Promise<void> {
  const target = page.locator(selector);

  for (let attempt = 0; attempt < attempts; attempt += 1) {
    await page.keyboard.press("Tab");
    if (await target.evaluate((element) => element === document.activeElement)) {
      return;
    }
  }

  throw new Error(`Target was not keyboard reachable after ${attempts} Tab presses: ${selector}`);
}

async function expectSurfaceContrast(
  page: Page,
  surface: string,
  sample: ContrastSample,
): Promise<void> {
  await tabTo(page, sample.focus);
  await expect(page.locator(sample.focus)).toBeFocused();

  const ratios = await page.evaluate((selectors) => {
    type AxeColor = {
      parseString: (value: string) => AxeColor;
    };
    type AxeColorApi = {
      Color: new () => AxeColor;
      getContrast: (background: AxeColor, foreground: AxeColor) => number | null;
    };

    const axe = (
      window as unknown as {
        axe: { commons: { color: AxeColorApi } };
      }
    ).axe;
    const parse = (value: string) => new axe.commons.color.Color().parseString(value);
    const contrast = (background: string, foreground: string) =>
      axe.commons.color.getContrast(parse(background), parse(foreground));
    const element = (selector: string) => {
      const match = document.querySelector<HTMLElement>(selector);
      if (!match) {
        throw new Error(`Missing contrast sample: ${selector}`);
      }
      return match;
    };

    const text = getComputedStyle(element(selectors.text));
    const textBackground = getComputedStyle(element(selectors.textBackground));
    const focus = getComputedStyle(element(selectors.focus));
    const focusBackground = getComputedStyle(element(selectors.focusBackground));
    const control = selectors.control ? getComputedStyle(element(selectors.control)) : null;
    const controlBackground = selectors.controlBackground
      ? getComputedStyle(element(selectors.controlBackground))
      : null;
    const controlColor =
      selectors.controlColor === "foreground" ? control?.color : control?.borderTopColor;

    return {
      additionalText: (selectors.additionalText ?? []).map((sample) => {
        const sampleText = getComputedStyle(element(sample.text));
        const sampleBackground = getComputedStyle(element(sample.background));

        return {
          label: sample.label,
          ratio: contrast(sampleBackground.backgroundColor, sampleText.color),
        };
      }),
      control:
        controlColor && controlBackground
          ? contrast(controlBackground.backgroundColor, controlColor)
          : null,
      focus: contrast(focusBackground.backgroundColor, focus.outlineColor),
      focusStyle: focus.outlineStyle,
      focusWidth: Number.parseFloat(focus.outlineWidth),
      text: contrast(textBackground.backgroundColor, text.color),
    };
  }, sample);

  expect(ratios.focusStyle, `${surface} focus outline style`).toBe("solid");
  expect(ratios.focusWidth, `${surface} focus outline width`).toBeGreaterThanOrEqual(3);
  expect(ratios.text).not.toBeNull();
  expect(ratios.text ?? 0, `${surface} representative text contrast`).toBeGreaterThanOrEqual(4.5);
  for (const additional of ratios.additionalText) {
    expect(additional.ratio).not.toBeNull();
    expect(
      additional.ratio ?? 0,
      `${surface} ${additional.label} text contrast`,
    ).toBeGreaterThanOrEqual(4.5);
  }
  expect(ratios.focus).not.toBeNull();
  expect(ratios.focus ?? 0, `${surface} focus contrast`).toBeGreaterThanOrEqual(3);

  if (sample.control) {
    expect(ratios.control).not.toBeNull();
    if (sample.controlColor === "foreground") {
      expect(
        ratios.control ?? 0,
        `${surface} text-control affordance contrast`,
      ).toBeGreaterThanOrEqual(4.5);
    } else {
      expect(ratios.control ?? 0, `${surface} control-boundary contrast`).toBeGreaterThanOrEqual(3);
    }
  }
}

async function expectTheme(page: Page, theme: Theme): Promise<void> {
  await expect(page.locator("html")).toHaveAttribute("data-theme", theme);
  expect(await page.evaluate(() => localStorage.getItem("singularity.asset-theme"))).toBe(theme);
}

async function auditThemeSurfaces(page: Page, theme: Theme): Promise<void> {
  await expectTheme(page, theme);
  await expectAxeClean(page, `${theme} workbench`);
  await expectSurfaceContrast(page, `${theme} workbench`, {
    control: '[aria-label="Search vault assets"]',
    controlBackground: ".control-deck",
    focus: '[aria-label="Search vault assets"]',
    focusBackground: ".control-deck",
    text: ".workbench-intro",
    textBackground: ".workbench",
  });

  await page.getByRole("link", { name: "Backups", exact: true }).click();
  await expect(page).toHaveURL("/backups");
  await expect(
    page.getByRole("heading", { name: "Create encrypted backup", level: 2 }),
  ).toBeVisible();
  await expect(page.getByLabel("Backup passphrase", { exact: true })).toBeVisible();
  await expect(page.locator("#backup-status")).toBeVisible();
  await expectTheme(page, theme);
  await expectAxeClean(page, `${theme} backup form and status`);
  await expectSurfaceContrast(page, `${theme} backup form and status`, {
    additionalText: [
      {
        background: ".vault-shell-main",
        label: "status",
        text: "#backup-status",
      },
    ],
    control: "#backup-passphrase",
    controlBackground: ".vault-shell-main",
    focus: "#backup-passphrase",
    focusBackground: ".vault-shell-main",
    text: "#create-backup-heading",
    textBackground: ".vault-shell-main",
  });

  await page.getByRole("link", { name: "Audit", exact: true }).click();
  await expect(page).toHaveURL("/audit");
  await expect(
    page.getByRole("heading", { name: "Restore integrity acceptance", level: 2 }),
  ).toBeVisible();
  await expect(
    page.getByText("This page does not perform an integrity audit against the live vault.", {
      exact: true,
    }),
  ).toBeVisible();
  await expectTheme(page, theme);
  await expectAxeClean(page, `${theme} restore-only Audit`);
  await expectSurfaceContrast(page, `${theme} restore-only Audit`, {
    control: '.vault-shell-nav a[href="/audit"]',
    controlBackground: ".vault-shell-header",
    controlColor: "foreground",
    focus: '.vault-shell-nav a[href="/audit"]',
    focusBackground: ".vault-shell-header",
    text: "#restore-integrity-heading",
    textBackground: ".vault-shell-main",
  });

  await page.getByRole("link", { name: "Assets", exact: true }).click();
  await expect(page).toHaveURL("/assets");
  await expect(page.getByRole("heading", { name: "Vault assets", level: 1 })).toBeVisible();
  await expectTheme(page, theme);
}

test("theme persists across navigation with accessible contrast and reduced motion", async ({
  page,
  loginAsOwner,
  unlockVault,
}) => {
  test.setTimeout(120_000);
  await page.addInitScript(() => {
    localStorage.setItem("singularity.asset-theme", "light");
  });

  await loginAsOwner();
  await unlockVault();
  await expect(page).toHaveURL("/assets");

  const themeToggle = page.getByRole("button", { name: "Switch to dark theme", exact: true });
  await auditThemeSurfaces(page, "light");

  await expect(themeToggle).toBeVisible();
  await tabTo(page, '.theme-toggle[aria-label="Switch to dark theme"]');
  await expect(themeToggle).toBeFocused();
  const toggleFocus = await themeToggle.evaluate((element) => {
    const style = getComputedStyle(element);
    return { style: style.outlineStyle, width: Number.parseFloat(style.outlineWidth) };
  });
  expect(toggleFocus.style).toBe("solid");
  expect(toggleFocus.width).toBeGreaterThanOrEqual(3);
  await page.keyboard.press("Space");
  await expect(
    page.getByRole("button", { name: "Switch to light theme", exact: true }),
  ).toBeVisible();
  await auditThemeSurfaces(page, "dark");

  await page.emulateMedia({ reducedMotion: "no-preference" });
  expect(await page.evaluate(() => matchMedia("(prefers-reduced-motion: reduce)").matches)).toBe(
    false,
  );

  await page.evaluate(() => {
    const keyframes = document.createElement("style");
    keyframes.dataset.step12MotionProbe = "";
    keyframes.textContent =
      "@keyframes step12-motion-probe { from { opacity: 0.9; } to { opacity: 1; } }";
    document.head.append(keyframes);

    const probe = document.createElement("div");
    probe.dataset.step12MotionProbe = "";
    probe.setAttribute("aria-hidden", "true");
    probe.style.animation = "step12-motion-probe 2s linear infinite";
    probe.style.scrollBehavior = "smooth";
    probe.style.transition = "transform 2s linear";
    document.body.append(probe);
  });

  const motion = () =>
    page
      .locator("[data-step12-motion-probe]")
      .last()
      .evaluate((element) => {
        const milliseconds = (value: string) =>
          Math.max(
            ...value.split(",").map((entry) => {
              const time = entry.trim();
              return time.endsWith("ms")
                ? Number.parseFloat(time)
                : Number.parseFloat(time) * 1_000;
            }),
          );
        const styles = [
          getComputedStyle(element),
          getComputedStyle(element, "::before"),
          getComputedStyle(element, "::after"),
        ];

        return {
          animationDuration: Math.max(
            ...styles.map((style) => milliseconds(style.animationDuration)),
          ),
          animationIterations: Math.max(
            ...styles.map((style) => Number.parseFloat(style.animationIterationCount)),
          ),
          scrollBehavior: styles[0].scrollBehavior,
          transitionDuration: Math.max(
            ...styles.map((style) => milliseconds(style.transitionDuration)),
          ),
        };
      });

  try {
    const baselineMotion = await motion();
    expect(baselineMotion.animationDuration).toBeGreaterThan(0);
    expect(baselineMotion.transitionDuration).toBeGreaterThan(0);
    expect(baselineMotion.scrollBehavior).toBe("smooth");

    await page.emulateMedia({ reducedMotion: "reduce" });
    expect(await page.evaluate(() => matchMedia("(prefers-reduced-motion: reduce)").matches)).toBe(
      true,
    );

    const reducedMotion = await motion();
    expect(reducedMotion.animationDuration).toBeLessThanOrEqual(0.01);
    expect(reducedMotion.animationIterations).toBeLessThanOrEqual(1);
    expect(reducedMotion.transitionDuration).toBeLessThanOrEqual(0.01);
    expect(reducedMotion.scrollBehavior).toBe("auto");
  } finally {
    await page.evaluate(() => {
      document
        .querySelectorAll("[data-step12-motion-probe]")
        .forEach((element) => element.remove());
    });
  }
});
