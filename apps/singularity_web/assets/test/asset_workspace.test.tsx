import { readFileSync } from "node:fs";
import { resolve } from "node:path";

import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { AssetWorkspace } from "../js/asset_workspace/AssetWorkspace";
import type { AssetSummary, Bridge, InitialProps } from "../js/asset_workspace/contracts";
import { WorkspaceStore } from "../js/asset_workspace/state";
import type {
  UploadAttempt,
  UploadAttemptFactory,
  UploadAttemptOptions,
  UploadAttemptResult,
} from "../js/asset_workspace/upload";

(
  globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean }
).IS_REACT_ACT_ENVIRONMENT = true;

const stylesheet = readFileSync(resolve("apps/singularity_web/assets/css/app.css"), "utf8");

function asset(overrides: Partial<AssetSummary> = {}): AssetSummary {
  return {
    id: "asset-1",
    resourceVersionId: "version-1",
    title: "Annual report",
    originalFilename: "annual-report.pdf",
    detectedMediaType: "application/pdf",
    state: "processing",
    stateRevision: 7,
    label: "Processing",
    progress: { kind: "indeterminate" },
    failure: {
      code: "storage_unavailable",
      retryable: true,
      operation: "extract",
      attempt: 1,
    },
    updatedAt: "2026-07-31T00:00:00Z",
    ...overrides,
  };
}

function initialProps(overrides: Partial<InitialProps> = {}): InitialProps {
  return {
    version: 1,
    vault: {
      ref: "vault-1",
      locked: false,
      expiresAt: null,
    },
    assets: {
      items: [asset()],
      nextCursor: "cursor-2",
    },
    filters: {
      q: "",
      state: null,
      mediaType: null,
    },
    upload: {
      maxBytes: 1_048_576,
      acceptedTypes: ["application/pdf", "image/png"],
    },
    ...overrides,
  };
}

function bridge(): Bridge {
  return {
    search: vi.fn(async (request) => ({
      ok: true,
      sequence: 1,
      filters: {
        q: request.q,
        state: request.state,
        mediaType: request.mediaType,
      },
      assets: { items: [], nextCursor: null },
    })),
    page: vi.fn(async () => ({
      ok: true,
      sequence: 2,
      assets: { items: [], nextCursor: null },
    })),
    grant: vi.fn(async () => ({
      ok: true,
      grantId: "grant-1",
      uploadToken: "one-use-token",
      uploadUrl: "/api/v1/uploads/grant-1",
      expiresAt: "2026-08-01T00:00:00Z",
    })),
    retry: vi.fn(async () => ({ ok: true, accepted: true })),
    delete: vi.fn(async () => ({ ok: true, accepted: true })),
    navigate: vi.fn(async () => ({ ok: true })),
  };
}

function button(container: HTMLElement, name: string): HTMLButtonElement {
  const match = [...container.querySelectorAll("button")].find(
    (candidate) => candidate.textContent?.trim() === name,
  );
  if (!(match instanceof HTMLButtonElement)) {
    throw new Error(`Button not found: ${name}`);
  }
  return match;
}

function deferred<T>(): {
  promise: Promise<T>;
  resolve: (value: T) => void;
} {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((accept) => {
    resolve = accept;
  });
  return { promise, resolve };
}

function tokenValue(block: string, token: string): string {
  const value = block.match(new RegExp(`--${token}:\\s*(#[0-9a-f]{6})`, "i"))?.[1];
  if (!value) {
    throw new Error(`CSS token not found: ${token}`);
  }
  return value;
}

function relativeLuminance(value: string): number {
  const channels = value
    .slice(1)
    .match(/.{2}/g)
    ?.map((channel) => Number.parseInt(channel, 16) / 255);
  if (!channels || channels.length !== 3) {
    throw new Error(`Unsupported color: ${value}`);
  }

  const [red, green, blue] = channels.map((channel) =>
    channel <= 0.04045 ? channel / 12.92 : ((channel + 0.055) / 1.055) ** 2.4,
  );
  return 0.2126 * red + 0.7152 * green + 0.0722 * blue;
}

function contrastRatio(first: string, second: string): number {
  const lighter = Math.max(relativeLuminance(first), relativeLuminance(second));
  const darker = Math.min(relativeLuminance(first), relativeLuminance(second));
  return (lighter + 0.05) / (darker + 0.05);
}

describe("workspace CSS contract", () => {
  it("keeps control boundaries at 3:1 or better in both themes", () => {
    const light = stylesheet.match(/:root\s*\{([^}]*)\}/)?.[1];
    const dark = stylesheet.match(/\[data-theme="dark"\]\s*\{([^}]*)\}/)?.[1];
    expect(light).toBeDefined();
    expect(dark).toBeDefined();

    for (const theme of [light!, dark!]) {
      const border = tokenValue(theme, "dm-border");
      expect(contrastRatio(border, tokenValue(theme, "dm-control"))).toBeGreaterThanOrEqual(3);
      expect(contrastRatio(border, tokenValue(theme, "dm-surface"))).toBeGreaterThanOrEqual(3);
    }
  });

  it("uses a semantic foreground token for primary controls", () => {
    expect(stylesheet).toContain("--dm-on-accent:");
    expect(stylesheet).toMatch(/\.button-primary\s*\{[^}]*color:\s*var\(--dm-on-accent\)/s);
    expect(stylesheet).not.toContain("color: #10201d");
  });

  it("collapses the persistent shell navigation without hiding its links", () => {
    expect(stylesheet).toMatch(
      /@media \(max-width: 767px\)[\s\S]*\.vault-shell-header\s*\{[^}]*display:\s*grid/s,
    );
    expect(stylesheet).toMatch(
      /@media \(max-width: 767px\)[\s\S]*\.vault-shell-nav\s*\{[^}]*grid-template-columns:\s*repeat\(3,\s*minmax\(0,\s*1fr\)\)/s,
    );
    expect(stylesheet).not.toMatch(
      /@media \(max-width: 767px\)[\s\S]*\.vault-shell-nav\s*\{[^}]*display:\s*none/s,
    );
  });

  it("uses the semantic shadow token for the inspector", () => {
    expect(stylesheet).toMatch(
      /\.asset-inspector\s*\{[^}]*box-shadow:\s*0 1rem 3rem var\(--dm-shadow\)/s,
    );
    expect(stylesheet).not.toContain("box-shadow: 0 1rem 3rem rgb(");
  });
});

describe("AssetWorkspace", () => {
  let container: HTMLDivElement;
  let root: Root;

  beforeEach(() => {
    delete document.documentElement.dataset.theme;
    window.localStorage.clear();
    container = document.createElement("div");
    document.body.append(container);
    root = createRoot(container);
  });

  afterEach(async () => {
    await act(async () => root.unmount());
    container.remove();
    vi.useRealTimers();
  });

  it("renders accessible workspace controls and sends current search filters", async () => {
    const testBridge = bridge();
    const store = new WorkspaceStore(initialProps());

    await act(async () => {
      root.render(<AssetWorkspace bridge={testBridge} store={store} />);
    });

    expect(container.querySelector("section[aria-labelledby]")).not.toBeNull();
    expect(container.querySelector("main")).toBeNull();
    expect(container.querySelector('form[role="search"]')).not.toBeNull();
    expect(container.querySelector('[aria-label="Search vault assets"]')).toBeInstanceOf(
      HTMLInputElement,
    );
    expect(container.querySelector('[aria-label="Filter by lifecycle state"]')).toBeInstanceOf(
      HTMLSelectElement,
    );
    expect(container.querySelector('[aria-label="Filter by media type"]')).toBeInstanceOf(
      HTMLSelectElement,
    );

    const query = container.querySelector('[aria-label="Search vault assets"]') as HTMLInputElement;
    const state = container.querySelector(
      '[aria-label="Filter by lifecycle state"]',
    ) as HTMLSelectElement;
    const mediaType = container.querySelector(
      '[aria-label="Filter by media type"]',
    ) as HTMLSelectElement;
    const form = container.querySelector('form[role="search"]') as HTMLFormElement;

    await act(async () => {
      query.value = "  report  ";
      query.dispatchEvent(new Event("input", { bubbles: true }));
      state.value = "ready";
      state.dispatchEvent(new Event("change", { bubbles: true }));
      mediaType.value = "application/pdf";
      mediaType.dispatchEvent(new Event("change", { bubbles: true }));
      form.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }));
      await Promise.resolve();
    });

    expect(testBridge.search).toHaveBeenCalledWith({
      version: 1,
      q: "report",
      state: "ready",
      mediaType: "application/pdf",
    });
    expect(
      [...container.querySelectorAll<HTMLSelectElement>("select")].some((select) =>
        [...select.options].some((option) => option.value === "deleted"),
      ),
    ).toBe(false);
  });

  it("reports stable bridge failures without implying stale results match", async () => {
    const secretCode = "kms_SECRET_material";
    const failed = async () => ({ ok: false as const, error: { code: secretCode } });
    const testBridge = bridge();
    testBridge.search = vi.fn(failed);
    testBridge.page = vi.fn(failed);
    testBridge.retry = vi.fn(failed);
    testBridge.delete = vi.fn(failed);

    await act(async () => {
      root.render(
        <AssetWorkspace bridge={testBridge} store={new WorkspaceStore(initialProps())} />,
      );
    });

    await act(async () => {
      button(container, "Load more assets").click();
      await Promise.resolve();
    });
    const pageStatus = container.querySelector('[aria-label="Asset list status"]');
    expect(pageStatus?.textContent).toContain("Could not load more assets.");
    expect(pageStatus?.textContent).not.toContain(secretCode);

    const query = container.querySelector('[aria-label="Search vault assets"]') as HTMLInputElement;
    query.value = "different";
    await act(async () => {
      query.dispatchEvent(new Event("input", { bubbles: true }));
      (container.querySelector('form[role="search"]') as HTMLFormElement).dispatchEvent(
        new Event("submit", { bubbles: true, cancelable: true }),
      );
      await Promise.resolve();
    });
    const listStatus = container.querySelector('[aria-label="Asset list status"]');
    expect(listStatus?.getAttribute("role")).toBe("alert");
    expect(listStatus?.textContent).toContain(
      "Search failed. Showing previous results; they may not match the requested filters.",
    );
    expect(container.textContent).toContain("Annual report");
    expect(container.textContent).not.toContain(secretCode);
    expect(button(container, "Load more assets").disabled).toBe(true);

    await act(async () => {
      (
        container.querySelector('[aria-label="Inspect Annual report"]') as HTMLButtonElement
      ).click();
    });
    await act(async () => {
      button(container, "Retry").click();
      await Promise.resolve();
    });
    const actionStatus = container.querySelector('[aria-label="Asset action status"]');
    expect(actionStatus?.textContent).toContain("Retry failed.");
    expect(actionStatus?.textContent).not.toContain(secretCode);

    await act(async () => {
      button(container, "Delete").click();
      await Promise.resolve();
    });
    const deleteStatus = container.querySelector('[aria-label="Asset action status"]');
    expect(deleteStatus?.textContent).toContain("Delete failed.");
    expect(deleteStatus?.textContent).not.toContain(secretCode);
  });

  it("releases search controls after a rejected transport so the user can retry", async () => {
    const secretDetail = "disconnect_SECRET_transport_detail";
    const testBridge = bridge();
    testBridge.search = vi
      .fn()
      .mockRejectedValueOnce(new Error(secretDetail))
      .mockResolvedValueOnce({
        ok: true,
        sequence: 1,
        filters: { q: "", state: null, mediaType: null },
        assets: { items: [], nextCursor: null },
      });

    await act(async () => {
      root.render(
        <AssetWorkspace bridge={testBridge} store={new WorkspaceStore(initialProps())} />,
      );
    });

    const form = container.querySelector('form[role="search"]') as HTMLFormElement;
    await act(async () => {
      form.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }));
      await Promise.resolve();
    });

    expect(button(container, "Search").disabled).toBe(false);
    expect(container.querySelector('[aria-label="Asset list status"]')?.textContent).toContain(
      "Search failed. Showing previous results",
    );
    expect(container.textContent).not.toContain(secretDetail);

    await act(async () => {
      form.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }));
      await Promise.resolve();
    });

    expect(testBridge.search).toHaveBeenCalledTimes(2);
    expect(button(container, "Search").disabled).toBe(false);
    expect(container.querySelector('[aria-label="Asset list status"]')?.textContent).toContain(
      "Search results updated.",
    );
  });

  it("reports mutation requests that the server does not accept", async () => {
    const testBridge = bridge();
    testBridge.retry = vi.fn(async () => ({ ok: true, accepted: false }));
    testBridge.delete = vi.fn(async () => ({ ok: true, accepted: false }));

    await act(async () => {
      root.render(
        <AssetWorkspace bridge={testBridge} store={new WorkspaceStore(initialProps())} />,
      );
    });
    await act(async () => {
      (
        container.querySelector('[aria-label="Inspect Annual report"]') as HTMLButtonElement
      ).click();
    });
    await act(async () => {
      button(container, "Retry").click();
      await Promise.resolve();
    });
    const actionStatus = container.querySelector('[aria-label="Asset action status"]');
    expect(actionStatus?.textContent).toBe("Retry was not accepted. The asset may have changed.");

    await act(async () => {
      button(container, "Delete").click();
      await Promise.resolve();
    });
    expect(container.querySelector('[aria-label="Asset action status"]')?.textContent).toBe(
      "Delete was not accepted. The asset may have changed.",
    );
  });

  it("suppresses duplicate list and mutation operations while requests are in flight", async () => {
    const testBridge = bridge();
    const search = deferred<Awaited<ReturnType<Bridge["search"]>>>();
    const page = deferred<Awaited<ReturnType<Bridge["page"]>>>();
    const retry = deferred<Awaited<ReturnType<Bridge["retry"]>>>();
    const deletion = deferred<Awaited<ReturnType<Bridge["delete"]>>>();
    testBridge.search = vi.fn(() => search.promise);
    testBridge.page = vi.fn(() => page.promise);
    testBridge.retry = vi.fn(() => retry.promise);
    testBridge.delete = vi.fn(() => deletion.promise);

    await act(async () => {
      root.render(
        <AssetWorkspace bridge={testBridge} store={new WorkspaceStore(initialProps())} />,
      );
    });

    const form = container.querySelector('form[role="search"]') as HTMLFormElement;
    await act(async () => {
      form.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }));
      form.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }));
      button(container, "Load more assets").click();
      await Promise.resolve();
    });
    expect(testBridge.search).toHaveBeenCalledTimes(1);
    expect(testBridge.page).not.toHaveBeenCalled();

    await act(async () => {
      search.resolve({
        ok: true,
        sequence: 1,
        filters: { q: "", state: null, mediaType: null },
        assets: initialProps().assets,
      });
      await Promise.resolve();
    });
    await act(async () => {
      button(container, "Load more assets").click();
      button(container, "Load more assets").click();
      await Promise.resolve();
    });
    expect(testBridge.page).toHaveBeenCalledTimes(1);
    await act(async () => {
      page.resolve({
        ok: true,
        sequence: 2,
        assets: { items: [], nextCursor: null },
      });
      await Promise.resolve();
    });

    await act(async () => {
      (
        container.querySelector('[aria-label="Inspect Annual report"]') as HTMLButtonElement
      ).click();
    });
    await act(async () => {
      button(container, "Retry").click();
      button(container, "Retry").click();
      button(container, "Delete").click();
      await Promise.resolve();
    });
    expect(testBridge.retry).toHaveBeenCalledTimes(1);
    expect(testBridge.delete).not.toHaveBeenCalled();

    await act(async () => {
      retry.resolve({ ok: true, accepted: true });
      await Promise.resolve();
    });
    await act(async () => {
      button(container, "Delete").click();
      button(container, "Delete").click();
      await Promise.resolve();
    });
    expect(testBridge.delete).toHaveBeenCalledTimes(1);
    await act(async () => {
      deletion.resolve({ ok: true, accepted: true });
      await Promise.resolve();
    });
  });

  it("subscribes to live workspace store updates", async () => {
    const store = new WorkspaceStore(initialProps());

    await act(async () => {
      root.render(<AssetWorkspace bridge={bridge()} store={store} />);
    });
    expect(container.textContent).toContain("Annual report");

    await act(async () => {
      store.acceptUpdate({
        version: 1,
        sequence: 1,
        asset: asset({
          title: "Revised annual report",
          state: "ready",
          stateRevision: 8,
          failure: null,
        }),
      });
    });

    expect(container.textContent).toContain("Revised annual report");
  });

  it("applies the selected theme to the document root", async () => {
    document.documentElement.dataset.theme = "light";

    await act(async () => {
      root.render(<AssetWorkspace bridge={bridge()} store={new WorkspaceStore(initialProps())} />);
    });

    const themeToggle = container.querySelector(
      '[aria-label="Switch to dark theme"]',
    ) as HTMLButtonElement;
    expect(themeToggle).toBeInstanceOf(HTMLButtonElement);

    await act(async () => themeToggle.click());

    expect(document.documentElement.dataset.theme).toBe("dark");
    expect(themeToggle.getAttribute("aria-label")).toBe("Switch to light theme");
  });

  it("renders and accessibly updates the remaining vault access time", async () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-07-31T10:00:00Z"));
    const store = new WorkspaceStore(
      initialProps({
        vault: {
          ref: "vault-1",
          locked: false,
          expiresAt: "2026-07-31T10:02:30Z",
        },
      }),
    );

    await act(async () => {
      root.render(<AssetWorkspace bridge={bridge()} store={store} />);
    });

    const timer = container.querySelector('[role="timer"]');
    expect(timer?.getAttribute("aria-label")).toBe("Vault access time remaining");
    expect(timer?.textContent).toBe("3 minutes remaining");

    await act(async () => vi.advanceTimersByTime(60_000));
    expect(timer?.textContent).toBe("2 minutes remaining");
  });

  it("locally locks the vault and disables mutations when access expires", async () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-07-31T10:00:00Z"));
    const store = new WorkspaceStore(
      initialProps({
        vault: {
          ref: "vault-1",
          locked: false,
          expiresAt: "2026-07-31T10:01:00Z",
        },
      }),
    );

    await act(async () => {
      root.render(<AssetWorkspace bridge={bridge()} store={store} />);
    });

    const fileInput = container.querySelector(
      '[aria-label="Choose a file to upload"]',
    ) as HTMLInputElement;
    Object.defineProperty(fileInput, "files", {
      configurable: true,
      value: [new File(["archive"], "archive.pdf", { type: "application/pdf" })],
    });
    await act(async () => fileInput.dispatchEvent(new Event("change", { bubbles: true })));
    await act(async () => {
      (
        container.querySelector('[aria-label="Inspect Annual report"]') as HTMLButtonElement
      ).click();
    });

    expect(container.textContent).toContain("Vault unlocked");
    expect(button(container, "Upload asset").disabled).toBe(false);
    expect(button(container, "Retry").disabled).toBe(false);
    expect(button(container, "Delete").disabled).toBe(false);
    expect(container.querySelector('[aria-label="Download Annual report"]')).toBeInstanceOf(
      HTMLAnchorElement,
    );

    await act(async () => vi.advanceTimersByTime(60_000));

    expect(container.textContent).toContain("Vault locked");
    expect(container.textContent).toContain("Access expired");
    expect(fileInput.disabled).toBe(true);
    expect(button(container, "Upload asset").disabled).toBe(true);
    expect(button(container, "Retry").disabled).toBe(true);
    expect(button(container, "Delete").disabled).toBe(true);
    expect(container.querySelector('[aria-label="Download Annual report"]')).toBeNull();
  });

  it("opens the inspector, uses current revisions, and restores trigger focus", async () => {
    const testBridge = bridge();
    const store = new WorkspaceStore(initialProps());

    await act(async () => {
      root.render(<AssetWorkspace bridge={testBridge} store={store} />);
    });

    const inspect = container.querySelector(
      '[aria-label="Inspect Annual report"]',
    ) as HTMLButtonElement;
    inspect.focus();
    await act(async () => inspect.click());

    const inspector = container.querySelector('[aria-label="Asset inspector"]');
    expect(inspector).not.toBeNull();
    const close = container.querySelector(
      '[aria-label="Close asset inspector"]',
    ) as HTMLButtonElement;
    expect(document.activeElement).toBe(inspect);

    await act(async () => {
      button(container, "Retry").click();
      await Promise.resolve();
    });
    await act(async () => {
      button(container, "Delete").click();
      await Promise.resolve();
    });

    expect(testBridge.retry).toHaveBeenCalledWith({
      version: 1,
      assetId: "asset-1",
      stateRevision: 7,
    });
    expect(testBridge.delete).toHaveBeenCalledWith({
      version: 1,
      assetId: "asset-1",
      stateRevision: 7,
    });

    await act(async () => {
      close.click();
      await Promise.resolve();
    });
    expect(document.activeElement).toBe(inspect);
  });

  it.each(["available", "processing", "ready"] satisfies AssetSummary["state"][])(
    "exposes a same-origin download for an unlocked %s asset",
    async (state) => {
      const store = new WorkspaceStore(
        initialProps({
          assets: {
            items: [asset({ state, failure: null })],
            nextCursor: null,
          },
        }),
      );

      await act(async () => {
        root.render(<AssetWorkspace bridge={bridge()} store={store} />);
      });
      await act(async () => {
        (
          container.querySelector('[aria-label="Inspect Annual report"]') as HTMLButtonElement
        ).click();
      });

      const download = container.querySelector(
        '[aria-label="Download Annual report"]',
      ) as HTMLAnchorElement | null;
      expect(download).toBeInstanceOf(HTMLAnchorElement);
      expect(download?.getAttribute("href")).toBe("/api/v1/assets/asset-1/content");
      expect(download?.getAttribute("download")).toBe("annual-report.pdf");
    },
  );

  it.each([
    ["staging", false],
    ["uploaded", false],
    ["verified", false],
    ["pending_delete", false],
    ["deleted", false],
    ["available", true],
    ["processing", true],
    ["ready", true],
  ] satisfies Array<[AssetSummary["state"], boolean]>)(
    "does not expose a download for a %s asset when locked is %s",
    async (state, locked) => {
      const store = new WorkspaceStore(
        initialProps({
          vault: {
            ref: "vault-1",
            locked,
            expiresAt: null,
          },
          assets: {
            items: [asset({ state, failure: null })],
            nextCursor: null,
          },
        }),
      );

      await act(async () => {
        root.render(<AssetWorkspace bridge={bridge()} store={store} />);
      });
      await act(async () => {
        (
          container.querySelector('[aria-label="Inspect Annual report"]') as HTMLButtonElement
        ).click();
      });

      expect(container.querySelector('[aria-label="Download Annual report"]')).toBeNull();
    },
  );

  it("uses a non-modal selection panel and closes it with Escape", async () => {
    const store = new WorkspaceStore(initialProps());

    await act(async () => {
      root.render(<AssetWorkspace bridge={bridge()} store={store} />);
    });

    const inspect = container.querySelector(
      '[aria-label="Inspect Annual report"]',
    ) as HTMLButtonElement;
    inspect.focus();
    await act(async () => inspect.click());

    const inspector = container.querySelector('[aria-label="Asset inspector"]') as HTMLElement;
    expect(inspector.tagName).toBe("ASIDE");
    expect(inspector.getAttribute("role")).toBeNull();
    expect(inspector.getAttribute("aria-modal")).toBeNull();
    expect(document.activeElement).toBe(inspect);

    await act(async () => {
      document.activeElement?.dispatchEvent(
        new KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }),
      );
      await Promise.resolve();
    });

    expect(container.querySelector('[aria-label="Asset inspector"]')).toBeNull();
    expect(document.activeElement).toBe(inspect);
  });

  it("restores focus logically when a live update removes the inspected asset", async () => {
    const store = new WorkspaceStore(initialProps());

    await act(async () => {
      root.render(<AssetWorkspace bridge={bridge()} store={store} />);
    });

    const inspect = container.querySelector(
      '[aria-label="Inspect Annual report"]',
    ) as HTMLButtonElement;
    await act(async () => inspect.click());
    expect(container.querySelector('[aria-label="Asset inspector"]')).not.toBeNull();

    await act(async () => {
      store.acceptSnapshot({
        version: 1,
        sequence: 1,
        assets: {
          items: [
            asset({
              id: "asset-2",
              resourceVersionId: "version-2",
              title: "Quarterly report",
              stateRevision: 1,
            }),
          ],
          nextCursor: null,
        },
      });
      await Promise.resolve();
    });

    const fallback = container.querySelector(
      '[aria-label="Inspect Quarterly report"]',
    ) as HTMLButtonElement;
    expect(container.querySelector('[aria-label="Asset inspector"]')).toBeNull();
    expect(document.activeElement).toBe(fallback);
  });

  it.each([
    ["pending_delete", "Deleting"],
    ["deleted", "Deleted"],
  ] satisfies Array<[AssetSummary["state"], string]>)(
    "presents %s assets with the stable %s label and no mutation actions",
    async (state, expectedLabel) => {
      const testBridge = bridge();
      const store = new WorkspaceStore(
        initialProps({
          assets: {
            items: [asset({ state, failure: null })],
            nextCursor: null,
          },
        }),
      );

      await act(async () => {
        root.render(<AssetWorkspace bridge={testBridge} store={store} />);
      });

      const inspect = container.querySelector(
        '[aria-label="Inspect Annual report"]',
      ) as HTMLButtonElement;
      expect(inspect).toBeInstanceOf(HTMLButtonElement);
      expect(container.querySelector(".asset-row .lifecycle")?.textContent).toBe(expectedLabel);

      await act(async () => inspect.click());

      const inspector = container.querySelector('[aria-label="Asset inspector"]');
      expect(inspector?.querySelector(".inspector-state")?.textContent).toBe(expectedLabel);
      const retry = button(container, "Retry");
      const deletion = button(container, "Delete");
      expect(retry.disabled).toBe(true);
      expect(deletion.disabled).toBe(true);

      await act(async () => {
        retry.click();
        deletion.click();
        await Promise.resolve();
      });
      expect(testBridge.retry).not.toHaveBeenCalled();
      expect(testBridge.delete).not.toHaveBeenCalled();
    },
  );

  it("keeps deleted assets present when snapshots and live updates include them", async () => {
    const store = new WorkspaceStore(
      initialProps({
        assets: {
          items: [
            asset({
              id: "deleted-asset",
              resourceVersionId: "deleted-version",
              title: "Deleted report",
              state: "deleted",
              failure: null,
            }),
            asset({
              id: "visible-asset",
              resourceVersionId: "visible-version",
              title: "Visible report",
              state: "ready",
              failure: null,
            }),
          ],
          nextCursor: null,
        },
      }),
    );

    await act(async () => {
      root.render(<AssetWorkspace bridge={bridge()} store={store} />);
    });

    expect(container.textContent).toContain("Deleted report");
    expect(container.textContent).toContain("Visible report");
    const lifecycle = container.querySelector(
      '[aria-label="Filter by lifecycle state"]',
    ) as HTMLSelectElement;
    expect([...lifecycle.options].map(({ value }) => value)).not.toContain("deleted");

    await act(async () => {
      store.acceptUpdate({
        version: 1,
        sequence: 1,
        asset: asset({
          id: "visible-asset",
          resourceVersionId: "visible-version",
          title: "Visible report",
          state: "deleted",
          stateRevision: 8,
          failure: null,
        }),
      });
    });

    expect(container.textContent).toContain("Visible report");
    expect(
      [...container.querySelectorAll(".asset-row .lifecycle")].map(
        ({ textContent }) => textContent,
      ),
    ).toEqual(["Deleted", "Deleted"]);
  });

  it("disables non-retryable failure actions and requests the current page", async () => {
    const testBridge = bridge();
    const props = initialProps({
      assets: {
        items: [
          asset({
            failure: {
              code: "integrity_failure",
              retryable: false,
              operation: "verify",
              attempt: 1,
            },
          }),
        ],
        nextCursor: "cursor-2",
      },
      filters: {
        q: "report",
        state: "processing",
        mediaType: "application/pdf",
      },
    });
    const store = new WorkspaceStore(props);

    await act(async () => {
      root.render(<AssetWorkspace bridge={testBridge} store={store} />);
    });

    await act(async () => {
      (
        container.querySelector('[aria-label="Inspect Annual report"]') as HTMLButtonElement
      ).click();
    });
    expect(button(container, "Retry").disabled).toBe(true);

    await act(async () => {
      button(container, "Load more assets").click();
      await Promise.resolve();
    });
    expect(testBridge.page).toHaveBeenCalledWith({
      version: 1,
      cursor: "cursor-2",
      q: "report",
      state: "processing",
      mediaType: "application/pdf",
    });
  });

  it("synchronizes form controls and pagination to default filters after reconnect", async () => {
    const testBridge = bridge();
    const store = new WorkspaceStore(
      initialProps({
        filters: {
          q: "report",
          state: "ready",
          mediaType: "application/pdf",
        },
        assets: {
          items: [asset({ state: "ready", failure: null })],
          nextCursor: "filtered-cursor",
        },
      }),
    );

    await act(async () => {
      root.render(<AssetWorkspace bridge={testBridge} store={store} />);
    });

    const query = container.querySelector('[aria-label="Search vault assets"]') as HTMLInputElement;
    const state = container.querySelector(
      '[aria-label="Filter by lifecycle state"]',
    ) as HTMLSelectElement;
    const mediaType = container.querySelector(
      '[aria-label="Filter by media type"]',
    ) as HTMLSelectElement;
    expect([query.value, state.value, mediaType.value]).toEqual([
      "report",
      "ready",
      "application/pdf",
    ]);

    await act(async () => {
      store.resetEpoch();
      store.acceptSnapshot({
        version: 1,
        sequence: 1,
        assets: {
          items: [asset({ id: "canonical", resourceVersionId: "canonical-version" })],
          nextCursor: "default-cursor",
        },
      });
      await Promise.resolve();
    });

    expect([query.value, state.value, mediaType.value]).toEqual(["", "", ""]);

    await act(async () => {
      button(container, "Load more assets").click();
      await Promise.resolve();
    });
    expect(testBridge.page).toHaveBeenCalledWith({
      version: 1,
      cursor: "default-cursor",
      q: "",
      state: null,
      mediaType: null,
    });
  });

  it("shows byte progress and cancels the active upload", async () => {
    const testBridge = bridge();
    const store = new WorkspaceStore(initialProps());
    let attemptOptions!: UploadAttemptOptions;
    let finish!: (result: Awaited<ReturnType<UploadAttempt["start"]>>) => void;
    const abort = vi.fn();
    const start = vi.fn(
      () =>
        new Promise<Awaited<ReturnType<UploadAttempt["start"]>>>((resolve) => {
          finish = resolve;
        }),
    );
    const uploadAttemptFactory: UploadAttemptFactory = vi.fn((options) => {
      attemptOptions = options;
      return { abort, start };
    });

    await act(async () => {
      root.render(
        <AssetWorkspace
          bridge={testBridge}
          store={store}
          uploadAttemptFactory={uploadAttemptFactory}
        />,
      );
    });

    const input = container.querySelector(
      '[aria-label="Choose a file to upload"]',
    ) as HTMLInputElement;
    const file = new File(["archive"], "archive.pdf", {
      type: "application/pdf",
    });
    Object.defineProperty(input, "files", {
      configurable: true,
      value: [file],
    });

    await act(async () => {
      input.dispatchEvent(new Event("change", { bubbles: true }));
    });
    await act(async () => {
      button(container, "Upload asset").click();
      await Promise.resolve();
    });

    expect(uploadAttemptFactory).toHaveBeenCalledTimes(1);
    expect(attemptOptions.file).toBe(file);
    expect(start).toHaveBeenCalledTimes(1);

    await act(async () => {
      attemptOptions.onProgress?.({ kind: "bytes", sent: 3, total: 7 });
    });
    const progress = container.querySelector(
      'progress[aria-label="Upload progress"]',
    ) as HTMLProgressElement;
    expect(progress.value).toBe(3);
    expect(progress.max).toBe(7);
    expect(container.textContent).toContain("3 of 7 bytes");

    await act(async () => button(container, "Cancel upload").click());
    expect(abort).toHaveBeenCalledTimes(1);

    await act(async () => {
      finish({ ok: false, reason: "cancelled" });
      await Promise.resolve();
    });
    expect(container.textContent).toContain("Upload cancelled");
  });

  it("clears a successful upload before allowing another attempt", async () => {
    const attempts: UploadAttemptOptions[] = [];
    const uploadAttemptFactory: UploadAttemptFactory = vi.fn((options) => {
      attempts.push(options);
      return {
        abort: vi.fn(),
        start: vi.fn(async () => ({ ok: true })),
      };
    });

    await act(async () => {
      root.render(
        <AssetWorkspace
          bridge={bridge()}
          store={new WorkspaceStore(initialProps())}
          uploadAttemptFactory={uploadAttemptFactory}
        />,
      );
    });

    const input = container.querySelector(
      '[aria-label="Choose a file to upload"]',
    ) as HTMLInputElement;
    const uploadButton = button(container, "Upload asset");
    const file = new File(["archive"], "archive.pdf", {
      type: "application/pdf",
    });
    Object.defineProperty(input, "files", {
      configurable: true,
      value: [file],
    });
    Object.defineProperty(input, "value", {
      configurable: true,
      writable: true,
      value: "C:\\fakepath\\archive.pdf",
    });

    await act(async () => input.dispatchEvent(new Event("change", { bubbles: true })));
    await act(async () => {
      uploadButton.click();
      await Promise.resolve();
    });

    expect(container.textContent).toContain("Upload complete");
    expect(container.querySelector(".selected-file")).toBeNull();
    expect(uploadButton.disabled).toBe(true);
    expect(input.value).toBe("");

    uploadButton.click();
    expect(attempts).toHaveLength(1);

    input.value = "C:\\fakepath\\archive.pdf";
    await act(async () => input.dispatchEvent(new Event("change", { bubbles: true })));
    await act(async () => {
      uploadButton.click();
      await Promise.resolve();
    });

    expect(attempts).toHaveLength(2);
    expect(attempts[1].idempotencyKey).not.toBe(attempts[0].idempotencyKey);
  });

  it.each([
    ["cancelled", { ok: false, reason: "cancelled" }],
    ["expired", { ok: false, reason: "expired" }],
    ["network failure", { ok: false, reason: "network" }],
  ] satisfies Array<[string, UploadAttemptResult]>)(
    "reuses the selected file idempotency key after %s and rotates it for a new file",
    async (_label, result) => {
      const attempts: UploadAttemptOptions[] = [];
      const uploadAttemptFactory: UploadAttemptFactory = vi.fn((options) => {
        attempts.push(options);
        return {
          abort: vi.fn(),
          start: vi.fn(async () => result),
        };
      });

      await act(async () => {
        root.render(
          <AssetWorkspace
            bridge={bridge()}
            store={new WorkspaceStore(initialProps())}
            uploadAttemptFactory={uploadAttemptFactory}
          />,
        );
      });

      const input = container.querySelector(
        '[aria-label="Choose a file to upload"]',
      ) as HTMLInputElement;
      const firstFile = new File(["archive"], "archive.pdf", {
        type: "application/pdf",
      });
      Object.defineProperty(input, "files", {
        configurable: true,
        value: [firstFile],
      });
      await act(async () => input.dispatchEvent(new Event("change", { bubbles: true })));

      await act(async () => {
        button(container, "Upload asset").click();
        await Promise.resolve();
      });
      await act(async () => {
        button(container, "Upload asset").click();
        await Promise.resolve();
      });

      const secondFile = new File(["new archive"], "replacement.pdf", {
        type: "application/pdf",
      });
      Object.defineProperty(input, "files", {
        configurable: true,
        value: [secondFile],
      });
      await act(async () => input.dispatchEvent(new Event("change", { bubbles: true })));
      await act(async () => {
        button(container, "Upload asset").click();
        await Promise.resolve();
      });

      expect(attempts).toHaveLength(3);
      expect(attempts[1].idempotencyKey).toBe(attempts[0].idempotencyKey);
      expect(attempts[2].idempotencyKey).not.toBe(attempts[0].idempotencyKey);
    },
  );
});
