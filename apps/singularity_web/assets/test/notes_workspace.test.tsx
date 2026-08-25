import { readFileSync } from "node:fs";
import { resolve } from "node:path";

import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { applyTheme, type Theme } from "../js/asset_workspace/theme";
import { NotesWorkspace } from "../js/notes_workspace/NotesWorkspace";
import type {
  InitialProps,
  Note,
  NoteConflictDetail,
  NoteSummary,
  NoteVersion,
  NotesBridge,
} from "../js/notes_workspace/contracts";
import { WorkspaceStore } from "../js/notes_workspace/state";

(
  globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean }
).IS_REACT_ACT_ENVIRONMENT = true;

const id = (suffix: string) => `019f9f65-acde-7a31-bf09-${suffix.padStart(12, "0")}`;
const updatedAt = "2026-08-20T12:00:00.000000Z";
const mutationIdPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const signatureCollisionDrafts = [
  { title: "alpha|beta", markdown: 'gamma\n{"json":"left|right"}' },
  { title: "alpha", markdown: 'beta|gamma\n{"json":"left|right"}' },
] as const;

function summary(overrides: Partial<NoteSummary> = {}): NoteSummary {
  return {
    resourceId: id("1"),
    resourceVersionId: id("2"),
    title: "Field notes",
    revision: 0,
    displayVersion: 1,
    updatedAt,
    deleted: false,
    openConflictCount: 0,
    ...overrides,
  };
}

function note(overrides: Partial<Note> = {}): Note {
  return { ...summary(), markdown: "# Canonical\n\nFirst draft.", ...overrides };
}

function secondSummary(overrides: Partial<NoteSummary> = {}): NoteSummary {
  return summary({
    resourceId: id("11"),
    resourceVersionId: id("12"),
    title: "Second note",
    updatedAt: "2026-08-20T12:01:00.000000Z",
    ...overrides,
  });
}

function secondNote(overrides: Partial<Note> = {}): Note {
  return { ...secondSummary(), markdown: "Second canonical Markdown.", ...overrides };
}

function createdNote(overrides: Partial<Note> = {}): Note {
  return {
    ...summary({
      resourceId: id("21"),
      resourceVersionId: id("22"),
      title: "Created note",
      updatedAt: "2026-08-20T12:02:00.000000Z",
    }),
    markdown: "Created Markdown.",
    ...overrides,
  };
}

function railSummaries(count: number): NoteSummary[] {
  return Array.from({ length: count }, (_, index) =>
    summary({
      resourceId: id(String(100 + index)),
      resourceVersionId: id(String(200 + index)),
      title: `Rail note ${index + 1}`,
    }),
  );
}

function version(overrides: Partial<NoteVersion> = {}): NoteVersion {
  return {
    resourceVersionId: id("3"),
    revision: 1,
    displayVersion: 2,
    createdByPrincipalId: id("9"),
    insertedAt: updatedAt,
    parentVersionId: id("2"),
    mergeParentVersionId: null,
    canonical: false,
    conflictState: null,
    resourceId: id("1"),
    title: "Pinned field notes",
    markdown: "Pinned snapshot.",
    ...overrides,
  };
}

function conflictDetailForA(): NoteConflictDetail {
  return {
    conflictId: id("5"),
    baseVersionId: id("2"),
    observedCanonicalVersionId: id("4"),
    current: version({
      resourceVersionId: id("4"),
      revision: 1,
      displayVersion: 2,
      canonical: true,
      conflictState: null,
      title: "Current title",
      markdown: "Current Markdown",
    }),
    competing: version({
      resourceVersionId: id("6"),
      conflictState: "open",
      title: "Competing title",
      markdown: "Competing Markdown",
    }),
  };
}

function initial(): InitialProps {
  return {
    version: 1,
    vault: { ref: id("8"), expiresAt: null },
    filters: { q: "" },
    summaries: [summary()],
  };
}

function bridge(): NotesBridge {
  return {
    search: vi.fn(async () => ({ ok: true, result: { items: [summary()], nextCursor: null } })),
    trash: vi.fn(async () => ({
      ok: true,
      result: {
        items: [
          {
            summary: summary({ deleted: true, title: "Deleted field notes" }),
            deletedAt: updatedAt,
          },
        ],
        nextCursor: null,
      },
    })),
    open: vi.fn(async () => ({ ok: true, result: note() })),
    create: vi.fn(async () => ({ ok: true, result: note() })),
    save: vi.fn(async (request) => ({
      ok: true,
      result: {
        outcome: "saved",
        canonical: note({
          title: request.title,
          markdown: request.markdown,
          resourceVersionId: id("4"),
          revision: 1,
          displayVersion: 2,
        }),
        submittedVersionId: id("4"),
        conflictId: null,
      },
    })),
    history: vi.fn(async () => ({
      ok: true,
      result: {
        items: [
          {
            resourceVersionId: id("2"),
            revision: 0,
            displayVersion: 1,
            createdByPrincipalId: id("9"),
            insertedAt: updatedAt,
            parentVersionId: null,
            mergeParentVersionId: null,
            canonical: true,
            conflictState: null,
          },
        ],
        nextCursor: null,
      },
    })),
    conflict: vi.fn(async () => ({ ok: false, error: { code: "not_found" } })),
    merge: vi.fn(async () => ({ ok: false, error: { code: "conflict" } })),
    delete: vi.fn(async () => ({ ok: true, accepted: true })),
    restore: vi.fn(async () => ({ ok: true, result: note() })),
    navigate: vi.fn(async () => ({ ok: true })),
  };
}

function button(container: ParentNode, name: string): HTMLButtonElement {
  const match = [...container.querySelectorAll("button")].find(
    (candidate) => candidate.textContent?.trim() === name,
  );
  if (!(match instanceof HTMLButtonElement)) throw new Error(`Button not found: ${name}`);
  return match;
}

function expectAriaControlsTargets(container: ParentNode): void {
  for (const control of container.querySelectorAll<HTMLElement>("[aria-controls]")) {
    const targetIds = (control.getAttribute("aria-controls") ?? "")
      .trim()
      .split(/\s+/)
      .filter(Boolean);
    expect(targetIds).not.toHaveLength(0);
    for (const targetId of targetIds) expect(document.getElementById(targetId)).not.toBeNull();
  }
}

function input(container: ParentNode, label: string): HTMLInputElement | HTMLTextAreaElement {
  const match = container.querySelector(`[aria-label="${label}"]`);
  if (!(match instanceof HTMLInputElement) && !(match instanceof HTMLTextAreaElement)) {
    throw new Error(`Input not found: ${label}`);
  }
  return match;
}

function deferred<T>(): {
  promise: Promise<T>;
  resolve(value: T): void;
  reject(error: Error): void;
} {
  let resolve!: (value: T) => void;
  let reject!: (error: Error) => void;
  const promise = new Promise<T>((accept, decline) => {
    resolve = accept;
    reject = decline;
  });
  return { promise, resolve, reject };
}

async function change(field: HTMLInputElement | HTMLTextAreaElement, value: string): Promise<void> {
  await act(async () => {
    const prototype =
      field instanceof HTMLTextAreaElement
        ? HTMLTextAreaElement.prototype
        : HTMLInputElement.prototype;
    const setter = Object.getOwnPropertyDescriptor(prototype, "value")?.set;
    setter?.call(field, value);
    field.dispatchEvent(new Event("input", { bubbles: true }));
  });
}

describe("NotesWorkspace", () => {
  let container: HTMLDivElement;
  let root: Root;
  let store: WorkspaceStore;
  let testBridge: NotesBridge;

  beforeEach(async () => {
    container = document.createElement("div");
    document.body.append(container);
    root = createRoot(container);
    store = new WorkspaceStore(initial());
    testBridge = bridge();
    await act(async () => root.render(<NotesWorkspace bridge={testBridge} store={store} />));
  });

  afterEach(async () => {
    await act(async () => root.unmount());
    container.remove();
    document.body.replaceChildren();
    delete document.documentElement.dataset.theme;
    window.localStorage.clear();
    vi.restoreAllMocks();
  });

  async function openCurrent(): Promise<void> {
    await act(async () => {
      (container.querySelector('[aria-label="Open Field notes"]') as HTMLButtonElement).click();
      await Promise.resolve();
    });
  }

  async function listSecondNote(): Promise<void> {
    await act(async () => {
      const token = store.beginLane("search");
      store.acceptSearch(token, { items: [summary(), secondSummary()], nextCursor: null });
    });
  }

  async function enterMergeMode(detail = conflictDetailForA()): Promise<void> {
    testBridge.save = vi.fn(async () => ({
      ok: true,
      result: {
        outcome: "conflict",
        canonical: note({ resourceVersionId: id("4"), revision: 1, displayVersion: 2 }),
        submittedVersionId: id("6"),
        conflictId: id("5"),
      },
    }));
    testBridge.conflict = vi.fn(async () => ({ ok: true, result: detail }));
    testBridge.merge = vi.fn(async (request) => ({
      ok: true,
      result: {
        outcome: "saved",
        canonical: note({
          resourceVersionId: id("7"),
          revision: 2,
          displayVersion: 3,
          title: request.title,
          markdown: request.markdown,
        }),
        submittedVersionId: id("7"),
        conflictId: null,
      },
    }));
    await openCurrent();
    await change(input(container, "Markdown source"), "Competing Markdown");
    await act(async () => {
      button(container, "Save").click();
      await Promise.resolve();
    });
    await act(async () => {
      button(container, "Conflict").click();
      await Promise.resolve();
    });
    await act(async () => button(container, "Merge these versions").click());
  }

  it.each<Theme>(["dark", "light"])("restores the stored %s theme on mount", async (theme) => {
    await act(async () => root.unmount());
    applyTheme(theme);
    delete document.documentElement.dataset.theme;
    root = createRoot(container);

    await act(async () => root.render(<NotesWorkspace bridge={testBridge} store={store} />));

    expect(document.documentElement.dataset.theme).toBe(theme);
  });

  it("composes as a named region within the shell's sole main landmark", async () => {
    await act(async () => {
      root.render(
        <main className="vault-shell-main">
          <NotesWorkspace bridge={testBridge} store={store} />
        </main>,
      );
    });

    expect.soft(container.querySelectorAll("main")).toHaveLength(1);
    expect
      .soft(
        container.querySelectorAll(
          'section[aria-label="Private notes workspace"], [role="region"][aria-label="Private notes workspace"]',
        ),
      )
      .toHaveLength(1);
    expect(container.textContent).toContain("Field notes");
  });

  it("searches the current rail, switches to Trash, and opens pinned results", async () => {
    await change(input(container, "Search notes"), "  current query  ");
    await act(async () => {
      (container.querySelector('form[role="search"]') as HTMLFormElement).dispatchEvent(
        new Event("submit", { bubbles: true, cancelable: true }),
      );
      await Promise.resolve();
    });
    expect(testBridge.search).toHaveBeenCalledWith({
      version: 1,
      q: "current query",
      cursor: null,
      limit: 20,
    });

    await openCurrent();
    expect(testBridge.open).toHaveBeenCalledWith({
      version: 1,
      resourceId: id("1"),
      resourceVersionId: id("2"),
    });
    expect((input(container, "Markdown source") as HTMLTextAreaElement).value).toContain(
      "Canonical",
    );

    await act(async () => {
      button(container, "Trash").click();
      await Promise.resolve();
    });
    expect(testBridge.trash).toHaveBeenCalledWith({ version: 1, cursor: null, limit: 20 });
    expect(container.textContent).toContain("Deleted field notes");
  });

  it("still reports a failure from the current search lane", async () => {
    testBridge.search = vi.fn(async () => ({
      ok: false as const,
      error: { code: "storage_unavailable" as const },
    }));

    await act(async () => {
      (container.querySelector('form[role="search"]') as HTMLFormElement).dispatchEvent(
        new Event("submit", { bubbles: true, cancelable: true }),
      );
      await Promise.resolve();
    });

    expect(container.querySelector('[role="alert"]')?.textContent).toContain("Search failed");
  });

  it.each(["failure reply", "thrown rejection"])(
    "silently ignores a stale search %s after successful Create",
    async (completion) => {
      const pending = deferred<Awaited<ReturnType<NotesBridge["search"]>>>();
      testBridge.search = vi.fn(() => pending.promise);
      testBridge.create = vi.fn(async (request) => ({
        ok: true,
        result: createdNote({ title: request.title, markdown: request.markdown }),
      }));
      await change(input(container, "Search notes"), "stale search");
      await act(async () => {
        (container.querySelector('form[role="search"]') as HTMLFormElement).dispatchEvent(
          new Event("submit", { bubbles: true, cancelable: true }),
        );
        await Promise.resolve();
      });

      await act(async () => button(container, "New note").click());
      await change(input(container, "Note title"), "Search-safe create");
      await change(input(container, "Markdown source"), "Authoritative Markdown.");
      await act(async () => {
        button(container, "Save").click();
        await Promise.resolve();
        await Promise.resolve();
      });
      const authoritative = store.getSnapshot();
      expect(authoritative.selection?.title).toBe("Search-safe create");
      expect(authoritative.draft?.markdown).toBe("Authoritative Markdown.");
      expect(authoritative.summaries[0]?.title).toBe("Search-safe create");
      expect(container.querySelector('[aria-label="Notes workspace status"]')?.textContent).toBe(
        "Note created.",
      );

      await act(async () => {
        if (completion === "failure reply") {
          pending.resolve({
            ok: false,
            error: { code: "storage_unavailable" },
          });
        } else {
          pending.reject(new Error("stale-search"));
        }
        await Promise.resolve();
        await Promise.resolve();
      });

      expect(store.getSnapshot()).toBe(authoritative);
      expect(container.querySelector('[aria-label="Open Search-safe create"]')).not.toBeNull();
      expect((input(container, "Markdown source") as HTMLTextAreaElement).value).toBe(
        "Authoritative Markdown.",
      );
      expect(container.querySelector('[aria-label="Notes workspace status"]')?.textContent).toBe(
        "Note created.",
      );
      expect(container.querySelector('[role="alert"]')).toBeNull();
    },
  );

  it("rejects a late Trash reply after terminal purge and clears local panel state", async () => {
    const pending = deferred<Awaited<ReturnType<NotesBridge["trash"]>>>();
    testBridge.trash = vi.fn(() => pending.promise);
    await change(input(container, "Search notes"), "session query");

    await act(async () => {
      button(container, "Trash").click();
      await Promise.resolve();
    });
    await act(async () => store.purgePrivateState("vault_locked"));
    expect(container.textContent).toContain("Vault access ended");

    await act(async () => {
      pending.resolve({
        ok: true,
        result: {
          items: [
            {
              summary: summary({ deleted: true, title: "Late deleted note" }),
              deletedAt: updatedAt,
            },
          ],
          nextCursor: null,
        },
      });
      await Promise.resolve();
      await Promise.resolve();
    });

    store = new WorkspaceStore(initial());
    await act(async () => root.render(<NotesWorkspace bridge={testBridge} store={store} />));
    expect((input(container, "Search notes") as HTMLInputElement).value).toBe("");
    expect(container.querySelector('[aria-label="Current notes"]')).not.toBeNull();

    testBridge.trash = vi.fn(async () => ({
      ok: false as const,
      error: { code: "storage_unavailable" as const },
    }));
    await act(async () => {
      button(container, "Trash").click();
      await Promise.resolve();
    });
    expect(container.querySelector('[aria-label="Trash"]')).not.toBeNull();
    expect(container.querySelector('[role="alert"]')?.textContent).toContain(
      "Trash could not be loaded",
    );
    expect(container.textContent).not.toContain("Late deleted note");
  });

  it("exposes a native New note action and enters a focused blank create draft without saving", async () => {
    const create = button(container, "New note");
    expect(create.type).toBe("button");
    create.focus();

    await act(async () => {
      create.click();
      await Promise.resolve();
      await Promise.resolve();
    });

    expect((input(container, "Note title") as HTMLInputElement).value).toBe("");
    expect((input(container, "Markdown source") as HTMLTextAreaElement).value).toBe("");
    expect(document.activeElement).toBe(input(container, "Note title"));
    expect(container.textContent).toContain("New · Unsaved");
    expect(button(container, "Save").disabled).toBe(true);
    expect(testBridge.create).not.toHaveBeenCalled();

    await change(input(container, "Note title"), "Keyboard draft");
    await change(input(container, "Markdown source"), "Fresh Markdown.");
    expect(button(container, "Save").disabled).toBe(false);
    expect(testBridge.create).not.toHaveBeenCalled();
  });

  it("creates only on explicit Save with the exact request and selects the returned Version 1", async () => {
    testBridge.create = vi.fn(async (request) => ({
      ok: true,
      result: createdNote({ title: request.title, markdown: request.markdown }),
    }));
    await act(async () => button(container, "New note").click());
    await change(input(container, "Note title"), "  Created note  ");
    await change(input(container, "Markdown source"), "Created Markdown.");

    await act(async () => {
      button(container, "Save").click();
      await Promise.resolve();
      await Promise.resolve();
    });

    expect(testBridge.create).toHaveBeenCalledTimes(1);
    const request = vi.mocked(testBridge.create).mock.calls[0]?.[0];
    expect(request).toEqual({
      version: 1,
      mutationId: expect.stringMatching(
        /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/,
      ),
      title: "Created note",
      markdown: "Created Markdown.",
    });
    expect(Object.keys(request ?? {}).sort()).toEqual([
      "markdown",
      "mutationId",
      "title",
      "version",
    ]);
    expect(testBridge.save).not.toHaveBeenCalled();
    expect(store.getSnapshot().selection).toEqual(createdNote());
    expect(store.getSnapshot().selection?.revision).toBe(0);
    expect(store.getSnapshot().selection?.displayVersion).toBe(1);
    expect(store.getSnapshot().dirty).toBe(false);
    expect(
      container.querySelector('[aria-label="Open Created note"]')?.getAttribute("aria-current"),
    ).toBe("true");
    expect(container.textContent).toContain("Version 1 · Saved");
    expect(container.textContent).not.toContain("New · Unsaved");
    expect(document.activeElement).toBe(input(container, "Note title"));
  });

  it.each([
    ["nonzero initial revision", { revision: 1, displayVersion: 2 }],
    ["open conflict count", { openConflictCount: 1 }],
    ["different canonical title", { title: "Different title" }],
    ["different canonical Markdown", { markdown: "Different Markdown." }],
  ] satisfies [string, Partial<Note>][])(
    "fails closed on a Create result with %s and permits retry",
    async (_case, mismatch) => {
      const canonical = {
        title: "Correlated title",
        markdown: "Exact submitted Markdown.",
      };
      testBridge.create = vi
        .fn()
        .mockResolvedValueOnce({
          ok: true,
          result: createdNote({ ...canonical, ...mismatch }),
        })
        .mockResolvedValueOnce({
          ok: true,
          result: createdNote(canonical),
        });
      await act(async () => button(container, "New note").click());
      await change(input(container, "Note title"), "  Correlated title  ");
      await change(input(container, "Markdown source"), canonical.markdown);

      await act(async () => {
        button(container, "Save").click();
        await Promise.resolve();
        await Promise.resolve();
      });

      expect(store.getSnapshot().selection).toBeNull();
      expect(store.getSnapshot().summaries.map((item) => item.title)).toEqual(["Field notes"]);
      expect((input(container, "Note title") as HTMLInputElement).value).toBe(
        "  Correlated title  ",
      );
      expect((input(container, "Markdown source") as HTMLTextAreaElement).value).toBe(
        canonical.markdown,
      );
      expect(container.textContent).toContain("New · Unsaved");
      expect(button(container, "Save").disabled).toBe(false);
      expect(container.querySelector('[role="alert"]')?.textContent).toContain("Try saving again");

      await act(async () => {
        button(container, "Save").click();
        await Promise.resolve();
        await Promise.resolve();
      });
      expect(testBridge.create).toHaveBeenCalledTimes(2);
      const firstRequest = vi.mocked(testBridge.create).mock.calls[0]?.[0];
      expect(vi.mocked(testBridge.create).mock.calls[1]?.[0]).toEqual({
        version: 1,
        mutationId: firstRequest?.mutationId,
        title: canonical.title,
        markdown: canonical.markdown,
      });
      expect(firstRequest?.mutationId).toMatch(mutationIdPattern);
      expect(store.getSnapshot().selection).toEqual(createdNote(canonical));
    },
  );

  it("keeps the current rail unique and bounded while prepending successful Creates", async () => {
    const original = railSummaries(50);
    store = new WorkspaceStore({ ...initial(), summaries: original });
    await act(async () => root.render(<NotesWorkspace bridge={testBridge} store={store} />));
    testBridge.create = vi
      .fn()
      .mockImplementationOnce(async (request) => ({
        ok: true,
        result: createdNote({ title: request.title, markdown: request.markdown }),
      }))
      .mockImplementationOnce(async (request) => ({
        ok: true,
        result: createdNote({
          resourceId: original[10]!.resourceId,
          resourceVersionId: id("999"),
          title: request.title,
          markdown: request.markdown,
        }),
      }));

    await act(async () => button(container, "New note").click());
    await change(input(container, "Note title"), "Fifty-first note");
    await change(input(container, "Markdown source"), "First bounded create.");
    await act(async () => {
      button(container, "Save").click();
      await Promise.resolve();
      await Promise.resolve();
    });

    const afterFirst = store.getSnapshot().summaries;
    expect(afterFirst).toHaveLength(50);
    expect(afterFirst.map((item) => item.resourceId)).toEqual([
      id("21"),
      ...original.slice(0, 49).map((item) => item.resourceId),
    ]);
    expect(afterFirst.some((item) => item.resourceId === original[49]!.resourceId)).toBe(false);

    await act(async () => button(container, "New note").click());
    await change(input(container, "Note title"), "Deduplicated note");
    await change(input(container, "Markdown source"), "Second bounded create.");
    await act(async () => {
      button(container, "Save").click();
      await Promise.resolve();
      await Promise.resolve();
    });

    const afterSecond = store.getSnapshot().summaries;
    const resourceIds = afterSecond.map((item) => item.resourceId);
    expect(afterSecond).toHaveLength(50);
    expect(new Set(resourceIds)).toHaveProperty("size", 50);
    expect(resourceIds).toEqual([
      original[10]!.resourceId,
      id("21"),
      ...original.slice(0, 10).map((item) => item.resourceId),
      ...original.slice(11, 49).map((item) => item.resourceId),
    ]);
  });

  it("retains one UUID for the same canonical Create across a retryable failure", async () => {
    testBridge.create = vi
      .fn()
      .mockResolvedValueOnce({
        ok: false as const,
        error: { code: "storage_unavailable" as const },
      })
      .mockResolvedValueOnce({
        ok: true,
        result: createdNote({ title: "Retry note", markdown: "Exact retry Markdown." }),
      });
    await act(async () => button(container, "New note").click());
    await change(input(container, "Note title"), "  Retry note  ");
    await change(input(container, "Markdown source"), "Exact retry Markdown.");

    await act(async () => {
      button(container, "Save").click();
      await Promise.resolve();
    });
    expect((input(container, "Note title") as HTMLInputElement).value).toBe("  Retry note  ");
    expect((input(container, "Markdown source") as HTMLTextAreaElement).value).toBe(
      "Exact retry Markdown.",
    );
    expect(container.querySelector('[role="alert"]')?.textContent).toContain("Try saving again");

    await change(input(container, "Note title"), "Retry note");

    await act(async () => {
      button(container, "Save").click();
      await Promise.resolve();
      await Promise.resolve();
    });
    const firstRequest = vi.mocked(testBridge.create).mock.calls[0]?.[0];
    const secondRequest = vi.mocked(testBridge.create).mock.calls[1]?.[0];
    expect(firstRequest).toEqual({
      version: 1,
      mutationId: expect.stringMatching(mutationIdPattern),
      title: "Retry note",
      markdown: "Exact retry Markdown.",
    });
    expect(secondRequest).toEqual(firstRequest);
    expect(store.getSnapshot().selection).toEqual(
      createdNote({ title: "Retry note", markdown: "Exact retry Markdown." }),
    );
  });

  it("replays an ambiguously committed Create instead of applying a duplicate", async () => {
    const receipts = new Map<string, Note>();
    let applyCount = 0;
    testBridge.create = vi.fn(async (request) => {
      const receipt = receipts.get(request.mutationId);
      if (receipt) return { ok: true as const, result: receipt };

      applyCount += 1;
      const result = createdNote({
        resourceId: id(String(20 + applyCount)),
        resourceVersionId: id(String(30 + applyCount)),
        title: request.title,
        markdown: request.markdown,
      });
      receipts.set(request.mutationId, result);
      return {
        ok: false as const,
        error: { code: "storage_unavailable" as const },
      };
    });
    await act(async () => button(container, "New note").click());
    await change(input(container, "Note title"), "Ambiguous create");
    await change(input(container, "Markdown source"), "Applied before the reply was lost.");

    await act(async () => {
      button(container, "Save").click();
      await Promise.resolve();
      await Promise.resolve();
    });
    await act(async () => {
      button(container, "Save").click();
      await Promise.resolve();
      await Promise.resolve();
    });

    expect(applyCount).toBe(1);
    expect(vi.mocked(testBridge.create).mock.calls[1]?.[0]).toEqual(
      vi.mocked(testBridge.create).mock.calls[0]?.[0],
    );
    expect(store.getSnapshot().selection?.title).toBe("Ambiguous create");
  });

  it("accepts the authoritative current Note returned by a retained Create replay", async () => {
    const current = createdNote({
      resourceVersionId: id("24"),
      revision: 1,
      displayVersion: 2,
      title: "Concurrent current title",
      markdown: "Concurrent current Markdown.",
    });
    let committedMutationId: string | null = null;
    testBridge.create = vi.fn(async (request) => {
      if (committedMutationId === null) {
        committedMutationId = request.mutationId;
        return {
          ok: false as const,
          error: { code: "storage_unavailable" as const },
        };
      }
      return request.mutationId === committedMutationId
        ? { ok: true as const, result: current }
        : {
            ok: false as const,
            error: { code: "storage_unavailable" as const },
          };
    });
    await act(async () => button(container, "New note").click());
    await change(input(container, "Note title"), "Originally submitted title");
    await change(input(container, "Markdown source"), "Originally submitted Markdown.");

    await act(async () => {
      button(container, "Save").click();
      await Promise.resolve();
    });
    await act(async () => {
      button(container, "Save").click();
      await Promise.resolve();
      await Promise.resolve();
    });

    const requests = vi.mocked(testBridge.create).mock.calls.map(([request]) => request);
    expect(requests).toHaveLength(2);
    expect(requests[1]).toEqual(requests[0]);
    expect(store.getSnapshot().selection).toEqual(current);
    expect(store.getSnapshot().draft).toEqual({
      title: "Concurrent current title",
      markdown: "Concurrent current Markdown.",
    });
    expect(container.querySelector('[aria-label="Open Concurrent current title"]')).not.toBeNull();
    expect(container.querySelector('[aria-label="Notes workspace status"]')?.textContent).toBe(
      "Note created.",
    );
    expect(container.querySelector('[role="alert"]')).toBeNull();
  });

  it("accepts the authoritative current Note after a lost Create reply rejects", async () => {
    const current = createdNote({
      resourceVersionId: id("24"),
      revision: 1,
      displayVersion: 2,
      title: "Current after rejected reply",
      markdown: "Current Markdown after rejected reply.",
    });
    testBridge.create = vi
      .fn()
      .mockRejectedValueOnce(new Error("create-reply-lost"))
      .mockResolvedValueOnce({ ok: true, result: current });
    await act(async () => button(container, "New note").click());
    await change(input(container, "Note title"), "Submitted before rejected reply");
    await change(input(container, "Markdown source"), "Submitted Markdown before rejection.");

    await act(async () => {
      button(container, "Save").click();
      await Promise.resolve();
    });
    await act(async () => {
      button(container, "Save").click();
      await Promise.resolve();
      await Promise.resolve();
    });

    const requests = vi.mocked(testBridge.create).mock.calls.map(([request]) => request);
    expect(requests).toHaveLength(2);
    expect(requests[1]).toEqual(requests[0]);
    expect(store.getSnapshot().selection).toEqual(current);
  });

  it("rejects a newer current Note returned on the first Create issuance", async () => {
    const unexpectedCurrent = createdNote({
      resourceVersionId: id("24"),
      revision: 1,
      displayVersion: 2,
      title: "Unexpected current title",
      markdown: "Unexpected current Markdown.",
    });
    testBridge.create = vi.fn(async () => ({ ok: true, result: unexpectedCurrent }));
    await act(async () => button(container, "New note").click());
    await change(input(container, "Note title"), "First issuance title");
    await change(input(container, "Markdown source"), "First issuance Markdown.");

    await act(async () => {
      button(container, "Save").click();
      await Promise.resolve();
      await Promise.resolve();
    });

    expect(store.getSnapshot().selection).toBeNull();
    expect((input(container, "Note title") as HTMLInputElement).value).toBe("First issuance title");
    expect((input(container, "Markdown source") as HTMLTextAreaElement).value).toBe(
      "First issuance Markdown.",
    );
    expect(container.querySelector('[role="alert"]')?.textContent).toContain("Try saving again");
  });

  it("keeps strict Create correlation across repeated definitive current responses", async () => {
    testBridge.create = vi
      .fn()
      .mockResolvedValueOnce({
        ok: true,
        result: createdNote({
          resourceId: id("31"),
          resourceVersionId: id("32"),
          revision: 1,
          displayVersion: 2,
          title: "First unrelated current title",
          markdown: "First unrelated current Markdown.",
        }),
      })
      .mockResolvedValueOnce({
        ok: true,
        result: createdNote({
          resourceId: id("41"),
          resourceVersionId: id("42"),
          revision: 2,
          displayVersion: 3,
          title: "Second unrelated current title",
          markdown: "Second unrelated current Markdown.",
        }),
      });
    await act(async () => button(container, "New note").click());
    await change(input(container, "Note title"), "Strictly correlated title");
    await change(input(container, "Markdown source"), "Strictly correlated Markdown.");

    await act(async () => {
      button(container, "Save").click();
      await Promise.resolve();
      await Promise.resolve();
    });
    await act(async () => {
      button(container, "Save").click();
      await Promise.resolve();
      await Promise.resolve();
    });

    const requests = vi.mocked(testBridge.create).mock.calls.map(([request]) => request);
    expect(requests).toHaveLength(2);
    expect(requests[1]).toEqual(requests[0]);
    expect(store.getSnapshot().selection).toBeNull();
    expect(store.getSnapshot().summaries.map(({ title }) => title)).toEqual(["Field notes"]);
    expect((input(container, "Note title") as HTMLInputElement).value).toBe(
      "Strictly correlated title",
    );
    expect((input(container, "Markdown source") as HTMLTextAreaElement).value).toBe(
      "Strictly correlated Markdown.",
    );
    expect(container.querySelector('[role="alert"]')?.textContent).toContain("Try saving again");
  });

  it.each(["invalid", "forbidden", "not_found", "conflict"] as const)(
    "keeps strict Create correlation after a definitive %s failure",
    async (code) => {
      testBridge.create = vi
        .fn()
        .mockResolvedValueOnce({ ok: false, error: { code } })
        .mockResolvedValueOnce({
          ok: true,
          result: createdNote({
            resourceVersionId: id("24"),
            revision: 1,
            displayVersion: 2,
            title: "Unrelated current after definitive failure",
            markdown: "Unrelated current Markdown.",
          }),
        });
      await act(async () => button(container, "New note").click());
      await change(input(container, "Note title"), "Definitive failure title");
      await change(input(container, "Markdown source"), "Definitive failure Markdown.");

      await act(async () => {
        button(container, "Save").click();
        await Promise.resolve();
      });
      await act(async () => {
        button(container, "Save").click();
        await Promise.resolve();
        await Promise.resolve();
      });

      const requests = vi.mocked(testBridge.create).mock.calls.map(([request]) => request);
      expect(requests).toHaveLength(2);
      expect(requests[1]).toEqual(requests[0]);
      expect(store.getSnapshot().selection).toBeNull();
      expect((input(container, "Note title") as HTMLInputElement).value).toBe(
        "Definitive failure title",
      );
      expect(container.querySelector('[role="alert"]')?.textContent).toContain("Try saving again");
    },
  );

  it.each([
    ["tombstoned", { deleted: true }],
    ["revision-inconsistent", { revision: 1, displayVersion: 3 }],
  ] satisfies [string, Partial<Note>][])(
    "rejects a %s Note returned by a retained Create replay",
    async (_case, invalidCurrent) => {
      testBridge.create = vi
        .fn()
        .mockResolvedValueOnce({
          ok: false as const,
          error: { code: "storage_unavailable" as const },
        })
        .mockResolvedValueOnce({
          ok: true,
          result: createdNote({
            resourceVersionId: id("24"),
            revision: 1,
            displayVersion: 2,
            ...invalidCurrent,
          }),
        });
      await act(async () => button(container, "New note").click());
      await change(input(container, "Note title"), "Replay invariant title");
      await change(input(container, "Markdown source"), "Replay invariant Markdown.");

      await act(async () => {
        button(container, "Save").click();
        await Promise.resolve();
      });
      await act(async () => {
        button(container, "Save").click();
        await Promise.resolve();
        await Promise.resolve();
      });

      expect(store.getSnapshot().selection).toBeNull();
      expect(container.querySelector('[role="alert"]')?.textContent).toContain("Try saving again");
    },
  );

  it("uses a new Create UUID for an intentional command after an earlier success", async () => {
    let creation = 0;
    testBridge.create = vi.fn(async (request) => {
      creation += 1;
      return {
        ok: true as const,
        result: createdNote({
          resourceId: id(String(40 + creation)),
          resourceVersionId: id(String(50 + creation)),
          title: request.title,
          markdown: request.markdown,
        }),
      };
    });
    const issueCreate = async () => {
      await act(async () => button(container, "New note").click());
      await change(input(container, "Note title"), "Repeated intentional create");
      await change(input(container, "Markdown source"), "Identical canonical Markdown.");
      await act(async () => {
        button(container, "Save").click();
        await Promise.resolve();
        await Promise.resolve();
      });
    };

    await issueCreate();
    await issueCreate();

    const requests = vi.mocked(testBridge.create).mock.calls.map(([request]) => request);
    expect(requests).toHaveLength(2);
    expect({ ...requests[1], mutationId: requests[0]?.mutationId }).toEqual(requests[0]);
    expect(requests[1]?.mutationId).not.toBe(requests[0]?.mutationId);
  });

  it.each([
    ["title", "Changed create", "Original Markdown."],
    ["Markdown", "Original create", "Changed Markdown."],
  ])("uses a new Create UUID when the canonical %s changes", async (_field, title, markdown) => {
    testBridge.create = vi.fn(async () => ({
      ok: false as const,
      error: { code: "storage_unavailable" as const },
    }));
    await act(async () => button(container, "New note").click());
    await change(input(container, "Note title"), "Original create");
    await change(input(container, "Markdown source"), "Original Markdown.");
    await act(async () => {
      button(container, "Save").click();
      await Promise.resolve();
    });

    await change(input(container, "Note title"), title);
    await change(input(container, "Markdown source"), markdown);
    await act(async () => {
      button(container, "Save").click();
      await Promise.resolve();
    });

    const requests = vi.mocked(testBridge.create).mock.calls.map(([request]) => request);
    expect(requests).toHaveLength(2);
    expect(requests[0]?.mutationId).toMatch(mutationIdPattern);
    expect(requests[1]?.mutationId).toMatch(mutationIdPattern);
    expect(requests[1]?.mutationId).not.toBe(requests[0]?.mutationId);
  });

  it("does not collide Create signatures containing delimiter-like content", async () => {
    const [first, second] = signatureCollisionDrafts;
    expect([first.title, first.markdown].join("|")).toBe([second.title, second.markdown].join("|"));
    testBridge.create = vi.fn(async () => ({
      ok: false as const,
      error: { code: "storage_unavailable" as const },
    }));
    await act(async () => button(container, "New note").click());
    await change(input(container, "Note title"), first.title);
    await change(input(container, "Markdown source"), first.markdown);
    await act(async () => {
      button(container, "Save").click();
      await Promise.resolve();
    });
    await change(input(container, "Note title"), second.title);
    await change(input(container, "Markdown source"), second.markdown);
    await act(async () => {
      button(container, "Save").click();
      await Promise.resolve();
    });

    const requests = vi.mocked(testBridge.create).mock.calls.map(([request]) => request);
    expect(requests.map(({ title, markdown }) => ({ title, markdown }))).toEqual([first, second]);
    expect(requests[1]?.mutationId).not.toBe(requests[0]?.mutationId);
  });

  it("clears a failed Create UUID when Discard starts a fresh New command", async () => {
    testBridge.create = vi.fn(async () => ({
      ok: false as const,
      error: { code: "storage_unavailable" as const },
    }));
    const enterSameCreate = async () => {
      await change(input(container, "Note title"), "Discarded retry");
      await change(input(container, "Markdown source"), "Same canonical Markdown.");
      await act(async () => {
        button(container, "Save").click();
        await Promise.resolve();
      });
    };
    await act(async () => button(container, "New note").click());
    await enterSameCreate();

    await act(async () => button(container, "New note").click());
    await act(async () => {
      button(container, "Discard").click();
      await Promise.resolve();
    });
    await enterSameCreate();

    const requests = vi.mocked(testBridge.create).mock.calls.map(([request]) => request);
    expect(requests).toHaveLength(2);
    expect(requests[1]).toEqual({
      ...requests[0],
      mutationId: expect.stringMatching(mutationIdPattern),
    });
    expect(requests[1]?.mutationId).not.toBe(requests[0]?.mutationId);
  });

  it("guards New from a dirty existing draft with Stay focus return and Discard", async () => {
    await openCurrent();
    await change(input(container, "Markdown source"), "Exact existing draft.");
    const create = button(container, "New note");
    create.focus();

    await act(async () => create.click());
    expect(container.querySelector('[role="dialog"]')).not.toBeNull();
    await act(async () => button(container, "Stay").click());
    expect((input(container, "Markdown source") as HTMLTextAreaElement).value).toBe(
      "Exact existing draft.",
    );
    expect(document.activeElement).toBe(create);

    await act(async () => create.click());
    await act(async () => {
      button(container, "Discard").click();
      await Promise.resolve();
      await Promise.resolve();
    });
    expect((input(container, "Note title") as HTMLInputElement).value).toBe("");
    expect((input(container, "Markdown source") as HTMLTextAreaElement).value).toBe("");
    expect(document.activeElement).toBe(input(container, "Note title"));
  });

  it("guards repeated New from a dirty create and ignores the discarded create completion", async () => {
    const pending = deferred<Awaited<ReturnType<NotesBridge["create"]>>>();
    testBridge.create = vi.fn(() => pending.promise);
    await act(async () => button(container, "New note").click());
    await change(input(container, "Note title"), "Discarded create");
    await change(input(container, "Markdown source"), "Discarded secret Markdown.");
    await act(async () => {
      button(container, "Save").click();
      await Promise.resolve();
    });

    await act(async () => button(container, "New note").click());
    expect(container.querySelector('[role="dialog"]')).not.toBeNull();
    await act(async () => {
      button(container, "Discard").click();
      await Promise.resolve();
      await Promise.resolve();
    });
    expect((input(container, "Note title") as HTMLInputElement).value).toBe("");
    expect(document.activeElement).toBe(input(container, "Note title"));

    await act(async () => {
      pending.resolve({ ok: true, result: createdNote({ title: "Late create" }) });
      await Promise.resolve();
      await Promise.resolve();
    });
    expect((input(container, "Note title") as HTMLInputElement).value).toBe("");
    expect(container.textContent).not.toContain("Late create");
    expect(store.getSnapshot().selection).toBeNull();
  });

  it.each([
    ["Ctrl+S", { ctrlKey: true }],
    ["Meta+S", { metaKey: true }],
  ])("suppresses %s while a dirty existing-note dialog is open", async (_command, modifier) => {
    await openCurrent();
    await change(input(container, "Markdown source"), "Dialog-protected existing draft.");
    await act(async () => {
      button(container, "New note").click();
      await Promise.resolve();
    });
    const dialog = container.querySelector('[role="dialog"]');
    const focused = document.activeElement;
    const before = store.getSnapshot();
    const keydown = new KeyboardEvent("keydown", {
      key: "s",
      bubbles: true,
      cancelable: true,
      ...modifier,
    });

    await act(async () => focused?.dispatchEvent(keydown));

    expect(keydown.defaultPrevented).toBe(true);
    expect(testBridge.save).not.toHaveBeenCalled();
    expect(testBridge.create).not.toHaveBeenCalled();
    expect(testBridge.merge).not.toHaveBeenCalled();
    expect(store.getSnapshot()).toBe(before);
    expect(container.querySelector('[role="dialog"]')).toBe(dialog);
    expect(document.activeElement).toBe(focused);
    expect((input(container, "Markdown source") as HTMLTextAreaElement).value).toBe(
      "Dialog-protected existing draft.",
    );
  });

  it.each([
    ["Ctrl+S", { ctrlKey: true }],
    ["Meta+S", { metaKey: true }],
  ])("suppresses %s while a dirty create dialog is open", async (_command, modifier) => {
    await act(async () => button(container, "New note").click());
    await change(input(container, "Note title"), "Dialog-protected create");
    await change(input(container, "Markdown source"), "Dialog-protected create Markdown.");
    await act(async () => {
      button(container, "New note").click();
      await Promise.resolve();
    });
    const dialog = container.querySelector('[role="dialog"]');
    const focused = document.activeElement;
    const before = store.getSnapshot();
    const keydown = new KeyboardEvent("keydown", {
      key: "s",
      bubbles: true,
      cancelable: true,
      ...modifier,
    });

    await act(async () => focused?.dispatchEvent(keydown));

    expect(keydown.defaultPrevented).toBe(true);
    expect(testBridge.create).not.toHaveBeenCalled();
    expect(testBridge.save).not.toHaveBeenCalled();
    expect(testBridge.merge).not.toHaveBeenCalled();
    expect(store.getSnapshot()).toBe(before);
    expect(container.querySelector('[role="dialog"]')).toBe(dialog);
    expect(document.activeElement).toBe(focused);
    expect((input(container, "Note title") as HTMLInputElement).value).toBe(
      "Dialog-protected create",
    );
    expect((input(container, "Markdown source") as HTMLTextAreaElement).value).toBe(
      "Dialog-protected create Markdown.",
    );
  });

  it("ignores a create completion after a newer local create edit", async () => {
    const pending = deferred<Awaited<ReturnType<NotesBridge["create"]>>>();
    testBridge.create = vi.fn(() => pending.promise);
    await act(async () => button(container, "New note").click());
    await change(input(container, "Note title"), "Submitted title");
    await change(input(container, "Markdown source"), "Submitted Markdown.");
    await act(async () => {
      button(container, "Save").click();
      await Promise.resolve();
    });
    await change(input(container, "Note title"), "Newer local title");

    await act(async () => {
      pending.resolve({ ok: true, result: createdNote({ title: "Submitted title" }) });
      await Promise.resolve();
      await Promise.resolve();
    });
    expect((input(container, "Note title") as HTMLInputElement).value).toBe("Newer local title");
    expect(store.getSnapshot().selection).toBeNull();
  });

  it("silently ignores a rejected create completion after Discard and Open", async () => {
    const pending = deferred<Awaited<ReturnType<NotesBridge["create"]>>>();
    testBridge.create = vi.fn(() => pending.promise);
    testBridge.open = vi.fn(async () => ({ ok: true, result: note() }));
    await act(async () => button(container, "New note").click());
    await change(input(container, "Note title"), "Abandoned create");
    await act(async () => {
      button(container, "Save").click();
      await Promise.resolve();
    });

    await act(async () => {
      (container.querySelector('[aria-label="Open Field notes"]') as HTMLButtonElement).click();
    });
    await act(async () => {
      button(container, "Discard").click();
      await Promise.resolve();
      await Promise.resolve();
    });
    expect(store.getSnapshot().selection?.resourceId).toBe(id("1"));

    await act(async () => {
      pending.reject(new Error("stale-create"));
      await Promise.resolve();
      await Promise.resolve();
    });
    expect(store.getSnapshot().selection?.resourceId).toBe(id("1"));
    expect(container.querySelector('[aria-label="Notes workspace status"]')?.textContent).toBe(
      "Current note opened.",
    );
    expect(container.querySelector('[role="alert"]')).toBeNull();
  });

  it("purges a create draft on terminal state and never restores it from a late failure", async () => {
    const pending = deferred<Awaited<ReturnType<NotesBridge["create"]>>>();
    testBridge.create = vi.fn(() => pending.promise);
    await act(async () => button(container, "New note").click());
    await change(input(container, "Note title"), "Terminal private title");
    await change(input(container, "Markdown source"), "Terminal private Markdown.");
    await act(async () => {
      button(container, "Save").click();
      await Promise.resolve();
    });

    await act(async () => store.purgePrivateState("vault_locked"));
    expect(container.textContent).toContain("Vault access ended");
    expect(container.textContent).not.toContain("Terminal private title");
    expect(container.textContent).not.toContain("Terminal private Markdown.");

    await act(async () => {
      pending.reject(new Error("late-terminal-create"));
      await Promise.resolve();
      await Promise.resolve();
    });
    expect(container.textContent).toContain("Vault access ended");
    expect(container.textContent).not.toContain("Terminal private title");
    expect(container.querySelector('[role="alert"]')).toBeNull();
  });

  it("terminal purge clears a retained Create UUID before the component receives a new store", async () => {
    testBridge.create = vi.fn(async () => ({
      ok: false as const,
      error: { code: "storage_unavailable" as const },
    }));
    const issueSameCreate = async () => {
      await act(async () => button(container, "New note").click());
      await change(input(container, "Note title"), "Terminal retry");
      await change(input(container, "Markdown source"), "Same command after terminal purge.");
      await act(async () => {
        button(container, "Save").click();
        await Promise.resolve();
      });
    };
    await issueSameCreate();
    const firstMutationId = vi.mocked(testBridge.create).mock.calls[0]?.[0].mutationId;

    await act(async () => store.purgePrivateState("vault_locked"));
    store = new WorkspaceStore(initial());
    await act(async () => root.render(<NotesWorkspace bridge={testBridge} store={store} />));
    await issueSameCreate();

    const secondMutationId = vi.mocked(testBridge.create).mock.calls[1]?.[0].mutationId;
    expect(firstMutationId).toMatch(mutationIdPattern);
    expect(secondMutationId).toMatch(mutationIdPattern);
    expect(secondMutationId).not.toBe(firstMutationId);
  });

  it("does not let a stale older Create success clear the newer retry UUID", async () => {
    const older = deferred<Awaited<ReturnType<NotesBridge["create"]>>>();
    let invocation = 0;
    testBridge.create = vi.fn(async (request) => {
      invocation += 1;
      if (invocation === 1) return older.promise;
      if (invocation === 2) {
        return {
          ok: false as const,
          error: { code: "storage_unavailable" as const },
        };
      }
      return {
        ok: true as const,
        result: createdNote({ title: request.title, markdown: request.markdown }),
      };
    });
    await act(async () => button(container, "New note").click());
    await change(input(container, "Note title"), "Overlapping create");
    await change(input(container, "Markdown source"), "Older command.");
    await act(async () => {
      button(container, "Save").click();
      await Promise.resolve();
    });

    await change(input(container, "Markdown source"), "Newer retryable command.");
    await act(async () => {
      button(container, "Save").click();
      await Promise.resolve();
    });
    const newerMutationId = vi.mocked(testBridge.create).mock.calls[1]?.[0].mutationId;

    await act(async () => {
      older.resolve({
        ok: true,
        result: createdNote({ title: "Overlapping create", markdown: "Older command." }),
      });
      await Promise.resolve();
      await Promise.resolve();
    });
    await act(async () => {
      button(container, "Save").click();
      await Promise.resolve();
      await Promise.resolve();
    });

    expect(vi.mocked(testBridge.create).mock.calls[2]?.[0].mutationId).toBe(newerMutationId);
    expect(store.getSnapshot().selection?.markdown).toBe("Newer retryable command.");
  });

  it("does not let a stale ambiguous Create completion enable replay for a newer command", async () => {
    const older = deferred<Awaited<ReturnType<NotesBridge["create"]>>>();
    let invocation = 0;
    testBridge.create = vi.fn(async () => {
      invocation += 1;
      if (invocation === 1) return older.promise;
      if (invocation === 2) {
        return {
          ok: false as const,
          error: { code: "forbidden" as const },
        };
      }
      return {
        ok: true as const,
        result: createdNote({
          resourceVersionId: id("24"),
          revision: 1,
          displayVersion: 2,
          title: "Unrelated current after stale ambiguity",
          markdown: "Unrelated current Markdown after stale ambiguity.",
        }),
      };
    });
    await act(async () => button(container, "New note").click());
    await change(input(container, "Note title"), "Overlapping eligibility");
    await change(input(container, "Markdown source"), "Older ambiguous command.");
    await act(async () => {
      button(container, "Save").click();
      await Promise.resolve();
    });

    await change(input(container, "Markdown source"), "Newer definitive command.");
    await act(async () => {
      button(container, "Save").click();
      await Promise.resolve();
    });
    const olderMutationId = vi.mocked(testBridge.create).mock.calls[0]?.[0].mutationId;
    const newerMutationId = vi.mocked(testBridge.create).mock.calls[1]?.[0].mutationId;

    await act(async () => {
      older.resolve({
        ok: false,
        error: { code: "storage_unavailable" },
      });
      await Promise.resolve();
      await Promise.resolve();
    });
    await act(async () => {
      button(container, "Save").click();
      await Promise.resolve();
      await Promise.resolve();
    });

    expect(olderMutationId).not.toBe(newerMutationId);
    expect(vi.mocked(testBridge.create).mock.calls[2]?.[0].mutationId).toBe(newerMutationId);
    expect(store.getSnapshot().selection).toBeNull();
    expect((input(container, "Markdown source") as HTMLTextAreaElement).value).toBe(
      "Newer definitive command.",
    );
    expect(container.querySelector('[role="alert"]')?.textContent).toContain("Try saving again");
  });

  it("saves only an explicit valid dirty draft and uses a fresh canonical UUID", async () => {
    await openCurrent();
    expect(button(container, "Save").disabled).toBe(true);

    await change(input(container, "Markdown source"), "# Revised\n\nLocal draft.");
    expect(button(container, "Save").disabled).toBe(false);
    expect(testBridge.save).not.toHaveBeenCalled();

    await act(async () => {
      button(container, "Save").click();
      await Promise.resolve();
    });
    expect(testBridge.save).toHaveBeenCalledTimes(1);
    expect(testBridge.save).toHaveBeenCalledWith(
      expect.objectContaining({
        version: 1,
        resourceId: id("1"),
        baseVersionId: id("2"),
        title: "Field notes",
        markdown: "# Revised\n\nLocal draft.",
        mutationId: expect.stringMatching(
          /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/,
        ),
      }),
    );
    expect(button(container, "Save").disabled).toBe(true);
  });

  it("retains the exact Save DTO and UUID after a lost reply", async () => {
    testBridge.save = vi
      .fn()
      .mockRejectedValueOnce(new Error("reply-lost"))
      .mockImplementationOnce(async (request) => ({
        ok: true as const,
        result: {
          outcome: "saved" as const,
          canonical: note({
            resourceVersionId: id("4"),
            revision: 1,
            displayVersion: 2,
            title: request.title,
            markdown: request.markdown,
          }),
          submittedVersionId: id("4"),
          conflictId: null,
        },
      }));
    await openCurrent();
    await change(input(container, "Note title"), "  Retried save  ");
    await change(input(container, "Markdown source"), "Exact saved Markdown.");

    await act(async () => {
      button(container, "Save").click();
      await Promise.resolve();
    });
    await change(input(container, "Note title"), "Retried save");
    await act(async () => {
      button(container, "Save").click();
      await Promise.resolve();
      await Promise.resolve();
    });

    const requests = vi.mocked(testBridge.save).mock.calls.map(([request]) => request);
    expect(requests).toEqual([
      {
        version: 1,
        mutationId: expect.stringMatching(mutationIdPattern),
        resourceId: id("1"),
        baseVersionId: id("2"),
        title: "Retried save",
        markdown: "Exact saved Markdown.",
      },
      requests[0],
    ]);
    expect(store.getSnapshot().selection?.resourceVersionId).toBe(id("4"));
  });

  it.each([
    ["title", "Changed save", "Original saved Markdown."],
    ["Markdown", "Field notes", "Changed saved Markdown."],
  ])("uses a new Save UUID when the canonical %s changes", async (_field, title, markdown) => {
    testBridge.save = vi.fn(async () => ({
      ok: false as const,
      error: { code: "storage_unavailable" as const },
    }));
    await openCurrent();
    await change(input(container, "Markdown source"), "Original saved Markdown.");
    await act(async () => {
      button(container, "Save").click();
      await Promise.resolve();
    });

    await change(input(container, "Note title"), title);
    await change(input(container, "Markdown source"), markdown);
    await act(async () => {
      button(container, "Save").click();
      await Promise.resolve();
    });

    const requests = vi.mocked(testBridge.save).mock.calls.map(([request]) => request);
    expect(requests).toHaveLength(2);
    expect(requests[0]?.mutationId).toMatch(mutationIdPattern);
    expect(requests[1]?.mutationId).toMatch(mutationIdPattern);
    expect(requests[1]?.mutationId).not.toBe(requests[0]?.mutationId);
  });

  it("does not collide Save signatures containing delimiter-like content", async () => {
    const [first, second] = signatureCollisionDrafts;
    expect([id("1"), id("2"), first.title, first.markdown].join("|")).toBe(
      [id("1"), id("2"), second.title, second.markdown].join("|"),
    );
    testBridge.save = vi.fn(async () => ({
      ok: false as const,
      error: { code: "storage_unavailable" as const },
    }));
    await openCurrent();
    await change(input(container, "Note title"), first.title);
    await change(input(container, "Markdown source"), first.markdown);
    await act(async () => {
      button(container, "Save").click();
      await Promise.resolve();
    });
    await change(input(container, "Note title"), second.title);
    await change(input(container, "Markdown source"), second.markdown);
    await act(async () => {
      button(container, "Save").click();
      await Promise.resolve();
    });

    const requests = vi.mocked(testBridge.save).mock.calls.map(([request]) => request);
    expect(requests.map(({ title, markdown }) => ({ title, markdown }))).toEqual([first, second]);
    expect(requests[1]?.mutationId).not.toBe(requests[0]?.mutationId);
  });

  it("clears a failed Save UUID when Discard explicitly opens the note again", async () => {
    testBridge.save = vi.fn(async () => ({
      ok: false as const,
      error: { code: "storage_unavailable" as const },
    }));
    await openCurrent();
    await change(input(container, "Markdown source"), "Same command after Open.");
    await act(async () => {
      button(container, "Save").click();
      await Promise.resolve();
    });

    await act(async () => {
      (container.querySelector('[aria-label="Open Field notes"]') as HTMLButtonElement).click();
    });
    await act(async () => {
      button(container, "Discard").click();
      await Promise.resolve();
      await Promise.resolve();
    });
    await change(input(container, "Markdown source"), "Same command after Open.");
    await act(async () => {
      button(container, "Save").click();
      await Promise.resolve();
    });

    const requests = vi.mocked(testBridge.save).mock.calls.map(([request]) => request);
    expect(requests).toHaveLength(2);
    expect({ ...requests[1], mutationId: requests[0]?.mutationId }).toEqual(requests[0]);
    expect(requests[1]?.mutationId).not.toBe(requests[0]?.mutationId);
  });

  it("uses a new Save UUID when Discard opens a different selection and base", async () => {
    testBridge.save = vi.fn(async () => ({
      ok: false as const,
      error: { code: "storage_unavailable" as const },
    }));
    await openCurrent();
    await listSecondNote();
    await change(input(container, "Markdown source"), "Selection-scoped save.");
    await act(async () => {
      button(container, "Save").click();
      await Promise.resolve();
    });

    testBridge.open = vi.fn(async () => ({ ok: true, result: secondNote() }));
    await act(async () => {
      (container.querySelector('[aria-label="Open Second note"]') as HTMLButtonElement).click();
    });
    await act(async () => {
      button(container, "Discard").click();
      await Promise.resolve();
      await Promise.resolve();
    });
    await change(input(container, "Markdown source"), "Selection-scoped save.");
    await act(async () => {
      button(container, "Save").click();
      await Promise.resolve();
    });

    const requests = vi.mocked(testBridge.save).mock.calls.map(([request]) => request);
    expect(
      requests.map(({ resourceId, baseVersionId }) => ({ resourceId, baseVersionId })),
    ).toEqual([
      { resourceId: id("1"), baseVersionId: id("2") },
      { resourceId: id("11"), baseVersionId: id("12") },
    ]);
    expect(requests[1]?.mutationId).not.toBe(requests[0]?.mutationId);
  });

  it("uses a new Save UUID and updated base after a successful earlier command", async () => {
    await openCurrent();
    await change(input(container, "Markdown source"), "First successful save.");
    await act(async () => {
      button(container, "Save").click();
      await Promise.resolve();
      await Promise.resolve();
    });
    await change(input(container, "Markdown source"), "Intentional later save.");
    await act(async () => {
      button(container, "Save").click();
      await Promise.resolve();
      await Promise.resolve();
    });

    const requests = vi.mocked(testBridge.save).mock.calls.map(([request]) => request);
    expect(requests).toHaveLength(2);
    expect(requests[0]?.baseVersionId).toBe(id("2"));
    expect(requests[1]?.baseVersionId).toBe(id("4"));
    expect(requests[1]?.mutationId).not.toBe(requests[0]?.mutationId);
  });

  it("does not let a late Save overwrite a newer local draft", async () => {
    const pending = deferred<Awaited<ReturnType<NotesBridge["save"]>>>();
    testBridge.save = vi.fn(() => pending.promise);
    await openCurrent();
    await change(input(container, "Markdown source"), "Submitted draft");

    await act(async () => {
      button(container, "Save").click();
      await Promise.resolve();
    });
    await change(input(container, "Markdown source"), "Newer local draft");

    await act(async () => {
      pending.resolve({
        ok: true,
        result: {
          outcome: "saved",
          canonical: note({
            resourceVersionId: id("4"),
            revision: 1,
            displayVersion: 2,
            markdown: "Submitted draft",
          }),
          submittedVersionId: id("4"),
          conflictId: null,
        },
      });
      await Promise.resolve();
      await Promise.resolve();
    });

    expect((input(container, "Markdown source") as HTMLTextAreaElement).value).toBe(
      "Newer local draft",
    );
    expect(store.getSnapshot().dirty).toBe(true);
    expect(store.getSnapshot().selection?.resourceVersionId).toBe(id("2"));
  });

  it("keeps an edit of A when an earlier Open B reply arrives", async () => {
    await openCurrent();
    await listSecondNote();
    const pending = deferred<Awaited<ReturnType<NotesBridge["open"]>>>();
    testBridge.open = vi.fn(() => pending.promise);

    await act(async () => {
      (container.querySelector('[aria-label="Open Second note"]') as HTMLButtonElement).click();
      await Promise.resolve();
    });
    await change(input(container, "Markdown source"), "Edit made while B opens");

    await act(async () => {
      pending.resolve({ ok: true, result: secondNote() });
      await Promise.resolve();
      await Promise.resolve();
    });

    expect(store.getSnapshot().selection?.resourceId).toBe(id("1"));
    expect((input(container, "Markdown source") as HTMLTextAreaElement).value).toBe(
      "Edit made while B opens",
    );
    expect(container.querySelector('[role="alert"]')).toBeNull();
  });

  it("keeps B selected when a discarded Save A reply arrives late", async () => {
    await openCurrent();
    await listSecondNote();
    const pending = deferred<Awaited<ReturnType<NotesBridge["save"]>>>();
    testBridge.save = vi.fn(() => pending.promise);
    await change(input(container, "Markdown source"), "Submitted A draft");
    await act(async () => {
      button(container, "Save").click();
      await Promise.resolve();
    });

    testBridge.open = vi.fn(async () => ({ ok: true, result: secondNote() }));
    await act(async () => {
      (container.querySelector('[aria-label="Open Second note"]') as HTMLButtonElement).click();
    });
    await act(async () => {
      button(container, "Discard").click();
      await Promise.resolve();
      await Promise.resolve();
    });
    expect(store.getSnapshot().selection?.resourceId).toBe(id("11"));

    await act(async () => {
      pending.resolve({
        ok: true,
        result: {
          outcome: "saved",
          canonical: note({
            resourceVersionId: id("4"),
            revision: 1,
            displayVersion: 2,
            markdown: "Submitted A draft",
          }),
          submittedVersionId: id("4"),
          conflictId: null,
        },
      });
      await Promise.resolve();
      await Promise.resolve();
    });

    expect(store.getSnapshot().selection?.resourceId).toBe(id("11"));
    expect((input(container, "Markdown source") as HTMLTextAreaElement).value).toBe(
      "Second canonical Markdown.",
    );
  });

  it("does not attach late History A results to B", async () => {
    await openCurrent();
    await listSecondNote();
    const pending = deferred<Awaited<ReturnType<NotesBridge["history"]>>>();
    testBridge.history = vi.fn(() => pending.promise);
    await act(async () => button(container, "History").click());

    testBridge.open = vi.fn(async () => ({ ok: true, result: secondNote() }));
    await act(async () => {
      (container.querySelector('[aria-label="Open Second note"]') as HTMLButtonElement).click();
      await Promise.resolve();
      await Promise.resolve();
    });
    await act(async () => {
      pending.resolve({
        ok: true,
        result: {
          items: [
            {
              resourceVersionId: id("13"),
              revision: 8,
              displayVersion: 9,
              createdByPrincipalId: id("9"),
              insertedAt: updatedAt,
              parentVersionId: id("2"),
              mergeParentVersionId: null,
              canonical: false,
              conflictState: null,
            },
          ],
          nextCursor: null,
        },
      });
      await Promise.resolve();
      await Promise.resolve();
    });

    testBridge.history = vi.fn(async () => ({
      ok: false as const,
      error: { code: "storage_unavailable" as const },
    }));
    await act(async () => {
      button(container, "History").click();
      await Promise.resolve();
    });
    expect(container.textContent).not.toContain("Version 9");
    expect(store.getSnapshot().selection?.resourceId).toBe(id("11"));
  });

  it("does not attach late Conflict A details to B", async () => {
    await openCurrent();
    await listSecondNote();
    testBridge.save = vi.fn(async () => ({
      ok: true,
      result: {
        outcome: "conflict",
        canonical: note({ resourceVersionId: id("4"), revision: 1, displayVersion: 2 }),
        submittedVersionId: id("6"),
        conflictId: id("5"),
      },
    }));
    await change(input(container, "Markdown source"), "Competing A draft");
    await act(async () => {
      button(container, "Save").click();
      await Promise.resolve();
    });

    const pending = deferred<Awaited<ReturnType<NotesBridge["conflict"]>>>();
    testBridge.conflict = vi.fn(() => pending.promise);
    await act(async () => button(container, "Conflict").click());
    testBridge.open = vi.fn(async () => ({ ok: true, result: secondNote() }));
    await act(async () => {
      (container.querySelector('[aria-label="Open Second note"]') as HTMLButtonElement).click();
    });
    await act(async () => {
      button(container, "Discard").click();
      await Promise.resolve();
      await Promise.resolve();
    });

    await act(async () => {
      pending.resolve({
        ok: true,
        result: {
          conflictId: id("5"),
          baseVersionId: id("2"),
          observedCanonicalVersionId: id("4"),
          current: version({
            resourceVersionId: id("4"),
            revision: 1,
            displayVersion: 2,
            canonical: true,
            conflictState: null,
            markdown: "Current A Markdown",
          }),
          competing: version({
            resourceVersionId: id("6"),
            conflictState: "open",
            markdown: "Competing A Markdown",
          }),
        },
      });
      await Promise.resolve();
      await Promise.resolve();
    });

    expect(store.getSnapshot().selection?.resourceId).toBe(id("11"));
    expect(button(container, "Conflict").disabled).toBe(true);
    expect(container.textContent).not.toContain("Current A Markdown");
  });

  it("ignores History started before a successful Save mutation", async () => {
    await openCurrent();
    await change(input(container, "Markdown source"), "Saved after History started");
    const pending = deferred<Awaited<ReturnType<NotesBridge["history"]>>>();
    testBridge.history = vi.fn(() => pending.promise);
    await act(async () => button(container, "History").click());

    await act(async () => {
      button(container, "Save").click();
      await Promise.resolve();
      await Promise.resolve();
    });
    expect(store.getSnapshot().selection?.resourceVersionId).toBe(id("4"));

    await act(async () => {
      pending.resolve({
        ok: true,
        result: {
          items: [
            {
              resourceVersionId: id("13"),
              revision: 8,
              displayVersion: 9,
              createdByPrincipalId: id("9"),
              insertedAt: updatedAt,
              parentVersionId: id("2"),
              mergeParentVersionId: null,
              canonical: false,
              conflictState: null,
            },
          ],
          nextCursor: null,
        },
      });
      await Promise.resolve();
      await Promise.resolve();
    });

    expect(store.getSnapshot().history).toEqual([]);
    expect(container.querySelector('[aria-label="Notes workspace status"]')?.textContent).toBe(
      "Note saved.",
    );
  });

  it("silently token-gates a rejected History completion after Save", async () => {
    await openCurrent();
    await change(input(container, "Markdown source"), "Saved after rejected History");
    const pending = deferred<Awaited<ReturnType<NotesBridge["history"]>>>();
    testBridge.history = vi.fn(() => pending.promise);
    await act(async () => button(container, "History").click());
    await act(async () => {
      button(container, "Save").click();
      await Promise.resolve();
      await Promise.resolve();
    });

    await act(async () => {
      pending.reject(new Error("stale-history"));
      await Promise.resolve();
      await Promise.resolve();
    });

    expect(container.querySelector('[aria-label="Notes workspace status"]')?.textContent).toBe(
      "Note saved.",
    );
    expect(container.querySelector('[role="alert"]')).toBeNull();
  });

  it("ignores Conflict started before a successful Merge mutation", async () => {
    const detail = conflictDetailForA();
    await enterMergeMode(detail);
    const pending = deferred<Awaited<ReturnType<NotesBridge["conflict"]>>>();
    testBridge.conflict = vi.fn(() => pending.promise);
    await act(async () => button(container, "Conflict").click());

    await act(async () => {
      button(container, "Save merge").click();
      await Promise.resolve();
      await Promise.resolve();
    });
    expect(store.getSnapshot().conflict).toBeNull();

    await act(async () => {
      pending.resolve({ ok: true, result: detail });
      await Promise.resolve();
      await Promise.resolve();
    });

    expect(store.getSnapshot().conflict).toBeNull();
    expect(container.querySelector('[aria-label="Notes workspace status"]')?.textContent).toBe(
      "Note saved.",
    );
  });

  it("silently token-gates a rejected Conflict completion after Merge", async () => {
    await enterMergeMode();
    const pending = deferred<Awaited<ReturnType<NotesBridge["conflict"]>>>();
    testBridge.conflict = vi.fn(() => pending.promise);
    await act(async () => button(container, "Conflict").click());
    await act(async () => {
      button(container, "Save merge").click();
      await Promise.resolve();
      await Promise.resolve();
    });

    await act(async () => {
      pending.reject(new Error("stale-conflict"));
      await Promise.resolve();
      await Promise.resolve();
    });

    expect(store.getSnapshot().conflict).toBeNull();
    expect(container.querySelector('[aria-label="Notes workspace status"]')?.textContent).toBe(
      "Note saved.",
    );
    expect(container.querySelector('[role="alert"]')).toBeNull();
  });

  it("keeps retryable failed drafts and purges all private UI on a terminal store purge", async () => {
    testBridge.save = vi.fn(async () => ({
      ok: false as const,
      error: { code: "storage_unavailable" as const },
    }));
    await openCurrent();
    await change(input(container, "Markdown source"), "Private unsaved draft");

    await act(async () => {
      button(container, "Save").click();
      await Promise.resolve();
    });
    expect((input(container, "Markdown source") as HTMLTextAreaElement).value).toBe(
      "Private unsaved draft",
    );
    expect(container.querySelector('[role="alert"]')?.textContent).toContain("Try saving again");

    await act(async () => store.purgePrivateState("vault_locked"));
    expect(container.textContent).not.toContain("Private unsaved draft");
    expect(container.textContent).not.toContain("Field notes");
    expect(container.textContent).toContain("Vault access ended");
  });

  it("guards note selection and capture-phase shell navigation with Stay or Discard", async () => {
    await openCurrent();
    await change(input(container, "Markdown source"), "Dirty draft");

    const shellLink = document.createElement("a");
    shellLink.href = "/settings";
    shellLink.dataset.phxLink = "redirect";
    shellLink.textContent = "Settings";
    document.body.append(shellLink);
    shellLink.focus();
    const click = new MouseEvent("click", { bubbles: true, cancelable: true });
    await act(async () => shellLink.dispatchEvent(click));

    expect(click.defaultPrevented).toBe(true);
    const dialog = container.querySelector('[role="dialog"][aria-modal="true"]') as HTMLElement;
    expect(dialog).not.toBeNull();
    expect(testBridge.navigate).not.toHaveBeenCalled();

    await act(async () => button(dialog, "Stay").click());
    expect(container.querySelector('[role="dialog"]')).toBeNull();
    expect(document.activeElement).toBe(shellLink);

    await act(async () =>
      shellLink.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true })),
    );
    await act(async () => {
      button(container, "Discard").click();
      await Promise.resolve();
    });
    expect(testBridge.navigate).toHaveBeenCalledWith("/settings");
  });

  it("traps dialog focus, makes the workspace inert, and cleans up on Stay", async () => {
    await openCurrent();
    await change(input(container, "Markdown source"), "Dirty draft");
    const add = vi.spyOn(document, "addEventListener");
    const remove = vi.spyOn(document, "removeEventListener");
    const shellLink = document.createElement("a");
    shellLink.href = "/settings";
    shellLink.dataset.phxLink = "redirect";
    shellLink.textContent = "Settings";
    document.body.append(shellLink);
    shellLink.focus();

    await act(async () =>
      shellLink.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true })),
    );
    const dialog = container.querySelector('[role="dialog"]') as HTMLElement;
    const stay = button(dialog, "Stay");
    const discard = button(dialog, "Discard");
    const background = container.querySelector(".notes-workspace-background") as HTMLElement;
    expect(background?.hasAttribute("inert")).toBe(true);
    expect(background?.getAttribute("aria-hidden")).toBe("true");
    expect(document.activeElement).toBe(stay);

    discard.focus();
    await act(async () =>
      discard.dispatchEvent(
        new KeyboardEvent("keydown", { key: "Tab", bubbles: true, cancelable: true }),
      ),
    );
    expect(document.activeElement).toBe(stay);

    stay.focus();
    await act(async () =>
      stay.dispatchEvent(
        new KeyboardEvent("keydown", {
          key: "Tab",
          shiftKey: true,
          bubbles: true,
          cancelable: true,
        }),
      ),
    );
    expect(document.activeElement).toBe(discard);

    (background.querySelector('[aria-label="Markdown source"]') as HTMLTextAreaElement).focus();
    expect(document.activeElement).toBe(stay);
    expect(add.mock.calls.some(([name]) => name === "focusin")).toBe(true);
    expect(add.mock.calls.some(([name]) => name === "keydown")).toBe(true);

    await act(async () => stay.click());
    expect(container.querySelector('[role="dialog"]')).toBeNull();
    expect(background.hasAttribute("inert")).toBe(false);
    expect(document.activeElement).toBe(shellLink);
    expect(remove.mock.calls.some(([name]) => name === "focusin")).toBe(true);
    expect(remove.mock.calls.some(([name]) => name === "keydown")).toBe(true);
  });

  it("keeps the dirty dialog open with valid focus when Discard cannot open the target", async () => {
    await openCurrent();
    await listSecondNote();
    await change(input(container, "Markdown source"), "Dirty A draft");
    testBridge.open = vi.fn(async () => ({
      ok: false as const,
      error: { code: "storage_unavailable" as const },
    }));

    await act(async () => {
      (container.querySelector('[aria-label="Open Second note"]') as HTMLButtonElement).click();
    });
    await act(async () => {
      button(container, "Discard").click();
      await Promise.resolve();
      await Promise.resolve();
    });

    const dialog = container.querySelector('[role="dialog"]') as HTMLElement;
    expect(dialog).not.toBeNull();
    expect(dialog.querySelector('[role="alert"]')?.textContent).toContain("could not be opened");
    expect(document.activeElement).toBe(button(dialog, "Stay"));
    expect(store.getSnapshot().selection?.resourceId).toBe(id("1"));
    expect(store.getSnapshot().dirty).toBe(true);
  });

  it("focuses the editor after a successful Discard and Open", async () => {
    await openCurrent();
    await listSecondNote();
    await change(input(container, "Markdown source"), "Dirty A draft");
    testBridge.open = vi.fn(async () => ({ ok: true, result: secondNote() }));

    await act(async () => {
      (container.querySelector('[aria-label="Open Second note"]') as HTMLButtonElement).click();
    });
    await act(async () => {
      button(container, "Discard").click();
      await Promise.resolve();
      await Promise.resolve();
    });

    expect(container.querySelector('[role="dialog"]')).toBeNull();
    expect(store.getSnapshot().selection?.resourceId).toBe(id("11"));
    expect(document.activeElement).toBe(input(container, "Note title"));
  });

  it("registers beforeunload only while dirty", async () => {
    const add = vi.spyOn(window, "addEventListener");
    const remove = vi.spyOn(window, "removeEventListener");
    await openCurrent();
    expect(add.mock.calls.some(([name]) => name === "beforeunload")).toBe(false);

    await change(input(container, "Markdown source"), "Dirty draft");
    expect(add.mock.calls.some(([name]) => name === "beforeunload")).toBe(true);
    const event = new Event("beforeunload", { cancelable: true });
    window.dispatchEvent(event);
    expect(event.defaultPrevented).toBe(true);

    await act(async () => {
      button(container, "Save").click();
      await Promise.resolve();
    });
    expect(remove.mock.calls.some(([name]) => name === "beforeunload")).toBe(true);
  });

  it("keeps Preview, History, and Conflict drawers mutually exclusive and returns focus", async () => {
    await openCurrent();
    const preview = button(container, "Preview");
    preview.focus();
    await act(async () => preview.click());
    expect(container.querySelector('[aria-label="Preview drawer"]')).not.toBeNull();
    expect(container.querySelectorAll(".notes-drawer")).toHaveLength(1);

    await act(async () => button(container, "History").click());
    expect(testBridge.history).toHaveBeenCalledWith({
      version: 1,
      resourceId: id("1"),
      cursor: null,
      limit: 20,
    });
    expect(container.querySelector('[aria-label="History drawer"]')).not.toBeNull();
    expect(container.querySelector('[aria-label="Preview drawer"]')).toBeNull();

    const close = button(container, "Close details");
    await act(async () => close.click());
    expect(container.querySelector(".notes-drawer")).toBeNull();
    expect(document.activeElement).toBe(button(container, "History"));
  });

  it("keeps narrow-panel aria-controls targets present while details are closed and open", async () => {
    const showDetails = button(container, "Show details");
    expect(showDetails.getAttribute("aria-controls")).toBeNull();
    expectAriaControlsTargets(container);

    await openCurrent();
    await act(async () => button(container, "Preview").click());

    expect(document.getElementById("notes-drawer")).not.toBeNull();
    expect(showDetails.getAttribute("aria-controls")).toBe("notes-drawer");
    expectAriaControlsTargets(container);
  });

  it("shows a stale pinned snapshot read-only and opens current only on request", async () => {
    testBridge.open = vi
      .fn()
      .mockResolvedValueOnce({
        ok: true,
        result: version({
          resourceVersionId: id("2"),
          revision: 0,
          displayVersion: 1,
          parentVersionId: null,
        }),
      })
      .mockResolvedValueOnce({ ok: true, result: note() });
    await openCurrent();

    expect(container.querySelector('[aria-label="History drawer"]')?.textContent).toContain(
      "Pinned snapshot.",
    );
    expect(container.querySelector('[aria-label="Pinned Markdown snapshot"]')).toHaveProperty(
      "readOnly",
      true,
    );
    expect(container.querySelector('[aria-label="Markdown source"]')).toBeNull();

    await act(async () => {
      button(container, "Open current").click();
      await Promise.resolve();
    });
    expect(testBridge.open).toHaveBeenLastCalledWith({
      version: 1,
      resourceId: id("1"),
      resourceVersionId: null,
    });
    expect(container.querySelector('[aria-label="Markdown source"]')).toBeInstanceOf(
      HTMLTextAreaElement,
    );
  });

  it("focuses the editor after a direct successful rail Open", async () => {
    const trigger = container.querySelector('[aria-label="Open Field notes"]') as HTMLButtonElement;
    trigger.focus();
    await act(async () => {
      trigger.click();
      await Promise.resolve();
      await Promise.resolve();
    });

    expect(document.activeElement).toBe(input(container, "Note title"));
  });

  it("focuses the editor after reopening the already-selected current note", async () => {
    await openCurrent();
    const trigger = container.querySelector('[aria-label="Open Field notes"]') as HTMLButtonElement;
    trigger.focus();

    await act(async () => {
      trigger.click();
      await Promise.resolve();
      await Promise.resolve();
    });

    expect(store.getSnapshot().selection?.resourceVersionId).toBe(id("2"));
    expect(document.activeElement).toBe(input(container, "Note title"));
  });

  it("focuses the editor when pinned Open current removes its trigger", async () => {
    testBridge.open = vi
      .fn()
      .mockResolvedValueOnce({
        ok: true,
        result: version({
          resourceVersionId: id("2"),
          revision: 0,
          displayVersion: 1,
          parentVersionId: null,
        }),
      })
      .mockResolvedValueOnce({ ok: true, result: note() });
    await openCurrent();
    const trigger = button(container, "Open current");
    trigger.focus();
    await act(async () => {
      trigger.click();
      await Promise.resolve();
      await Promise.resolve();
    });

    expect(container.querySelector('[role="dialog"]')).toBeNull();
    expect(document.activeElement).toBe(input(container, "Note title"));
  });

  it("focuses the editor when a successful History Open removes its trigger", async () => {
    await openCurrent();
    await act(async () => {
      button(container, "History").click();
      await Promise.resolve();
    });
    testBridge.open = vi.fn(async () => ({ ok: true, result: note() }));
    const trigger = button(container, "Version 1, current");
    trigger.focus();
    await act(async () => {
      trigger.click();
      await Promise.resolve();
      await Promise.resolve();
    });

    expect(container.querySelector('[aria-label="History drawer"]')).toBeNull();
    expect(document.activeElement).toBe(input(container, "Note title"));
  });

  it("retains source focus when a direct Open fails", async () => {
    testBridge.open = vi.fn(async () => ({
      ok: false as const,
      error: { code: "storage_unavailable" as const },
    }));
    const trigger = container.querySelector('[aria-label="Open Field notes"]') as HTMLButtonElement;
    trigger.focus();
    await act(async () => {
      trigger.click();
      await Promise.resolve();
      await Promise.resolve();
    });

    expect(document.activeElement).toBe(trigger);
    expect(container.querySelector('[role="alert"]')?.textContent).toContain("could not be opened");
  });

  it("enters conflict merge mode from exact DTOs and submits Save merge", async () => {
    const detail: NoteConflictDetail = {
      conflictId: id("5"),
      baseVersionId: id("2"),
      observedCanonicalVersionId: id("4"),
      current: version({
        resourceVersionId: id("4"),
        revision: 1,
        displayVersion: 2,
        canonical: true,
        conflictState: null,
        title: "Current title",
        markdown: "Current Markdown",
      }),
      competing: version({
        resourceVersionId: id("6"),
        conflictState: "open",
        title: "Competing title",
        markdown: "Competing Markdown",
      }),
    };
    testBridge.save = vi.fn(async () => ({
      ok: true,
      result: {
        outcome: "conflict",
        canonical: note({ resourceVersionId: id("4"), revision: 1, displayVersion: 2 }),
        submittedVersionId: id("6"),
        conflictId: id("5"),
      },
    }));
    testBridge.conflict = vi.fn(async () => ({ ok: true, result: detail }));
    testBridge.merge = vi.fn(async (request) => ({
      ok: true,
      result: {
        outcome: "saved",
        canonical: note({
          resourceVersionId: id("7"),
          revision: 2,
          displayVersion: 3,
          title: request.title,
          markdown: request.markdown,
        }),
        submittedVersionId: id("7"),
        conflictId: null,
      },
    }));

    await openCurrent();
    await change(input(container, "Markdown source"), "Competing Markdown");
    await act(async () => {
      button(container, "Save").click();
      await Promise.resolve();
    });
    await act(async () => {
      button(container, "Conflict").click();
      await Promise.resolve();
    });
    expect(testBridge.conflict).toHaveBeenCalledWith({
      version: 1,
      resourceId: id("1"),
      conflictId: id("5"),
    });
    expect(container.querySelector('textarea[aria-label="Current"]')).toBeInstanceOf(
      HTMLTextAreaElement,
    );
    expect(container.querySelector('textarea[aria-label="Competing"]')).toBeInstanceOf(
      HTMLTextAreaElement,
    );
    await act(async () => button(container, "Merge these versions").click());
    expect(container.textContent).toContain("Merge mode");

    await change(input(container, "Markdown source"), "Resolved Markdown");
    await act(async () => {
      button(container, "Save merge").click();
      await Promise.resolve();
    });
    expect(testBridge.merge).toHaveBeenCalledWith(
      expect.objectContaining({
        version: 1,
        resourceId: id("1"),
        conflictId: id("5"),
        expectedCurrentVersionId: id("4"),
        competingVersionId: id("6"),
        markdown: "Resolved Markdown",
        mutationId: expect.stringMatching(/^[0-9a-f-]{36}$/),
      }),
    );
  });

  it("retains the exact Merge DTO and UUID across a same-command retry", async () => {
    await enterMergeMode();
    testBridge.merge = vi
      .fn()
      .mockResolvedValueOnce({
        ok: false as const,
        error: { code: "storage_unavailable" as const },
      })
      .mockImplementationOnce(async (request) => ({
        ok: true as const,
        result: {
          outcome: "saved" as const,
          canonical: note({
            resourceVersionId: id("7"),
            revision: 2,
            displayVersion: 3,
            title: request.title,
            markdown: request.markdown,
          }),
          submittedVersionId: id("7"),
          conflictId: null,
        },
      }));
    await change(input(container, "Note title"), "  Exact merge  ");
    await change(input(container, "Markdown source"), "Exact merged Markdown.");

    await act(async () => {
      button(container, "Save merge").click();
      await Promise.resolve();
    });
    await change(input(container, "Note title"), "Exact merge");
    await act(async () => {
      button(container, "Save merge").click();
      await Promise.resolve();
      await Promise.resolve();
    });

    const requests = vi.mocked(testBridge.merge).mock.calls.map(([request]) => request);
    expect(requests).toEqual([
      {
        version: 1,
        mutationId: expect.stringMatching(mutationIdPattern),
        resourceId: id("1"),
        conflictId: id("5"),
        expectedCurrentVersionId: id("4"),
        competingVersionId: id("6"),
        title: "Exact merge",
        markdown: "Exact merged Markdown.",
      },
      requests[0],
    ]);
  });

  it("uses a new Merge UUID when an edited command field changes", async () => {
    await enterMergeMode();
    testBridge.merge = vi.fn(async () => ({
      ok: false as const,
      error: { code: "storage_unavailable" as const },
    }));
    await act(async () => {
      button(container, "Save merge").click();
      await Promise.resolve();
    });
    await change(input(container, "Markdown source"), "Changed merged Markdown.");
    await act(async () => {
      button(container, "Save merge").click();
      await Promise.resolve();
    });

    const requests = vi.mocked(testBridge.merge).mock.calls.map(([request]) => request);
    expect(requests).toHaveLength(2);
    expect(requests[1]?.mutationId).toMatch(mutationIdPattern);
    expect(requests[1]?.mutationId).not.toBe(requests[0]?.mutationId);
    expect(requests[1]?.markdown).toBe("Changed merged Markdown.");
  });

  it("does not collide Merge signatures containing delimiter-like content", async () => {
    const [first, second] = signatureCollisionDrafts;
    expect([id("1"), id("5"), id("4"), id("6"), first.title, first.markdown].join("|")).toBe(
      [id("1"), id("5"), id("4"), id("6"), second.title, second.markdown].join("|"),
    );
    await enterMergeMode();
    testBridge.merge = vi.fn(async () => ({
      ok: false as const,
      error: { code: "storage_unavailable" as const },
    }));
    await change(input(container, "Note title"), first.title);
    await change(input(container, "Markdown source"), first.markdown);
    await act(async () => {
      button(container, "Save merge").click();
      await Promise.resolve();
    });
    await change(input(container, "Note title"), second.title);
    await change(input(container, "Markdown source"), second.markdown);
    await act(async () => {
      button(container, "Save merge").click();
      await Promise.resolve();
    });

    const requests = vi.mocked(testBridge.merge).mock.calls.map(([request]) => request);
    expect(requests.map(({ title, markdown }) => ({ title, markdown }))).toEqual([first, second]);
    expect(requests[1]?.mutationId).not.toBe(requests[0]?.mutationId);
  });

  it("uses a new Merge UUID when conflict command identifiers change", async () => {
    await enterMergeMode();
    testBridge.merge = vi.fn(async () => ({
      ok: false as const,
      error: { code: "storage_unavailable" as const },
    }));
    await act(async () => {
      button(container, "Save merge").click();
      await Promise.resolve();
    });
    const firstRequest = vi.mocked(testBridge.merge).mock.calls[0]?.[0];
    const changedDetail = conflictDetailForA();
    changedDetail.conflictId = id("15");
    changedDetail.current.resourceVersionId = id("14");
    changedDetail.competing.resourceVersionId = id("16");
    await act(async () => {
      const mutationToken = store.beginLane("mutation");
      store.acceptMutation(mutationToken, {
        outcome: "conflict",
        canonical: note({ resourceVersionId: id("14"), revision: 1, displayVersion: 2 }),
        submittedVersionId: id("16"),
        conflictId: id("15"),
      });
      const conflictToken = store.beginLane("conflict");
      store.acceptConflict(conflictToken, changedDetail);
    });
    await act(async () => {
      button(container, "Save merge").click();
      await Promise.resolve();
    });

    const secondRequest = vi.mocked(testBridge.merge).mock.calls[1]?.[0];
    expect(secondRequest).toEqual({
      ...firstRequest,
      mutationId: expect.stringMatching(mutationIdPattern),
      conflictId: id("15"),
      expectedCurrentVersionId: id("14"),
      competingVersionId: id("16"),
    });
    expect(secondRequest?.mutationId).not.toBe(firstRequest?.mutationId);
  });

  it("deletes, restores from Trash, and exposes an ordinary same-origin export link", async () => {
    await openCurrent();
    const exportLink = container.querySelector('[aria-label="Export Field notes"]');
    expect(exportLink).toBeInstanceOf(HTMLAnchorElement);
    expect(exportLink?.getAttribute("href")).toBe(`/api/v1/notes/${id("1")}/export`);
    expect(exportLink?.getAttribute("target")).toBeNull();

    await act(async () => {
      button(container, "Delete").click();
      await Promise.resolve();
    });
    expect(testBridge.delete).toHaveBeenCalledWith(
      expect.objectContaining({
        version: 1,
        resourceId: id("1"),
        expectedCurrentVersionId: id("2"),
        mutationId: expect.stringMatching(/^[0-9a-f-]{36}$/),
      }),
    );

    await act(async () => {
      button(container, "Trash").click();
      await Promise.resolve();
    });
    await act(async () => {
      button(container, "Restore Deleted field notes").click();
      await Promise.resolve();
    });
    expect(testBridge.restore).toHaveBeenCalledWith(
      expect.objectContaining({
        version: 1,
        resourceId: id("1"),
        mutationId: expect.stringMatching(/^[0-9a-f-]{36}$/),
      }),
    );
  });

  it("retains the exact Delete DTO and UUID across a same-command retry", async () => {
    testBridge.delete = vi
      .fn()
      .mockResolvedValueOnce({
        ok: false as const,
        error: { code: "storage_unavailable" as const },
      })
      .mockResolvedValueOnce({ ok: true, accepted: true });
    await openCurrent();

    await act(async () => {
      button(container, "Delete").click();
      await Promise.resolve();
    });
    await act(async () => {
      button(container, "Delete").click();
      await Promise.resolve();
      await Promise.resolve();
    });

    const requests = vi.mocked(testBridge.delete).mock.calls.map(([request]) => request);
    expect(requests).toEqual([
      {
        version: 1,
        mutationId: expect.stringMatching(mutationIdPattern),
        resourceId: id("1"),
        expectedCurrentVersionId: id("2"),
      },
      requests[0],
    ]);
    expect(store.getSnapshot().selection).toBeNull();
  });

  it("clears a retained command UUID after an explicit successful Open", async () => {
    testBridge.delete = vi.fn(async () => ({
      ok: false as const,
      error: { code: "storage_unavailable" as const },
    }));
    await openCurrent();
    await act(async () => {
      button(container, "Delete").click();
      await Promise.resolve();
    });

    await act(async () => {
      (container.querySelector('[aria-label="Open Field notes"]') as HTMLButtonElement).click();
      await Promise.resolve();
      await Promise.resolve();
    });
    await act(async () => {
      button(container, "Delete").click();
      await Promise.resolve();
    });

    const requests = vi.mocked(testBridge.delete).mock.calls.map(([request]) => request);
    expect(requests).toHaveLength(2);
    expect({ ...requests[1], mutationId: requests[0]?.mutationId }).toEqual(requests[0]);
    expect(requests[1]?.mutationId).not.toBe(requests[0]?.mutationId);
  });

  it("retains the exact Restore DTO and UUID across a same-command retry", async () => {
    testBridge.restore = vi
      .fn()
      .mockResolvedValueOnce({
        ok: false as const,
        error: { code: "storage_unavailable" as const },
      })
      .mockResolvedValueOnce({ ok: true, result: note() });
    await act(async () => {
      button(container, "Trash").click();
      await Promise.resolve();
    });

    await act(async () => {
      button(container, "Restore Deleted field notes").click();
      await Promise.resolve();
    });
    await act(async () => {
      button(container, "Restore Deleted field notes").click();
      await Promise.resolve();
      await Promise.resolve();
    });

    const requests = vi.mocked(testBridge.restore).mock.calls.map(([request]) => request);
    expect(requests).toEqual([
      {
        version: 1,
        mutationId: expect.stringMatching(mutationIdPattern),
        resourceId: id("1"),
      },
      requests[0],
    ]);
    expect(store.getSnapshot().selection?.resourceId).toBe(id("1"));
  });

  it("uses a new Restore UUID when the selected trash resource changes", async () => {
    testBridge.trash = vi.fn(async () => ({
      ok: true as const,
      result: {
        items: [
          {
            summary: summary({ deleted: true, title: "Deleted field notes" }),
            deletedAt: updatedAt,
          },
          {
            summary: secondSummary({ deleted: true, title: "Deleted second note" }),
            deletedAt: updatedAt,
          },
        ],
        nextCursor: null,
      },
    }));
    testBridge.restore = vi.fn(async () => ({
      ok: false as const,
      error: { code: "storage_unavailable" as const },
    }));
    await act(async () => {
      button(container, "Trash").click();
      await Promise.resolve();
    });
    await act(async () => {
      button(container, "Restore Deleted field notes").click();
      await Promise.resolve();
    });
    await act(async () => {
      button(container, "Restore Deleted second note").click();
      await Promise.resolve();
    });

    const requests = vi.mocked(testBridge.restore).mock.calls.map(([request]) => request);
    expect(requests.map(({ resourceId }) => resourceId)).toEqual([id("1"), id("11")]);
    expect(requests[1]?.mutationId).not.toBe(requests[0]?.mutationId);
  });

  it("never shares a canonical UUID between Delete and Restore for the same resource", async () => {
    testBridge.delete = vi.fn(async () => ({
      ok: false as const,
      error: { code: "storage_unavailable" as const },
    }));
    testBridge.restore = vi.fn(async () => ({
      ok: false as const,
      error: { code: "storage_unavailable" as const },
    }));
    await openCurrent();
    await act(async () => {
      button(container, "Delete").click();
      await Promise.resolve();
    });
    await act(async () => {
      button(container, "Trash").click();
      await Promise.resolve();
    });
    await act(async () => {
      button(container, "Restore Deleted field notes").click();
      await Promise.resolve();
    });

    const deleteMutationId = vi.mocked(testBridge.delete).mock.calls[0]?.[0].mutationId;
    const restoreMutationId = vi.mocked(testBridge.restore).mock.calls[0]?.[0].mutationId;
    expect(deleteMutationId).toMatch(mutationIdPattern);
    expect(restoreMutationId).toMatch(mutationIdPattern);
    expect(restoreMutationId).not.toBe(deleteMutationId);
  });

  it("supports keyboard Save and Escape, live regions, and named narrow panels", async () => {
    await openCurrent();
    await change(input(container, "Markdown source"), "Keyboard draft");
    await act(async () => {
      input(container, "Markdown source").dispatchEvent(
        new KeyboardEvent("keydown", { key: "s", ctrlKey: true, bubbles: true, cancelable: true }),
      );
      await Promise.resolve();
    });
    expect(testBridge.save).toHaveBeenCalledTimes(1);

    await act(async () => button(container, "Preview").click());
    await act(async () =>
      document.activeElement?.dispatchEvent(
        new KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }),
      ),
    );
    expect(container.querySelector(".notes-drawer")).toBeNull();
    expect(container.querySelector('[aria-live="polite"]')).not.toBeNull();
    expect(container.querySelector('[aria-label="Notes rail"]')?.getAttribute("data-panel")).toBe(
      "rail",
    );
    expect(
      container.querySelector('[aria-label="Workspace details"]')?.getAttribute("data-panel"),
    ).toBe("drawer-controls");

    const stylesheet = readFileSync(resolve("apps/singularity_web/assets/css/app.css"), "utf8");
    expect(stylesheet).toMatch(
      /@media \(max-width: 63rem\)[\s\S]*\.notes-panel-switcher\s*\{[^}]*display:\s*grid/s,
    );
    expect(stylesheet).not.toMatch(
      /@media \(max-width: 63rem\)[\s\S]*\.notes-rail\s*\{[^}]*display:\s*none/s,
    );
    expect(stylesheet).toMatch(/\.notes-workspace[^}]*var\(--dm-/s);
    expect(stylesheet).toMatch(/@media \(prefers-reduced-motion: reduce\)/);
  });

  it("switches the three-column drawer to named panels at the tablet breakpoint", () => {
    const stylesheet = readFileSync(resolve("apps/singularity_web/assets/css/app.css"), "utf8");
    expect(stylesheet).toMatch(
      /@media \(max-width: 63rem\)[\s\S]*\.notes-workspace\.has-drawer\s*\{[^}]*grid-template-columns:\s*minmax\(0,\s*1fr\)/s,
    );
    expect(stylesheet).toMatch(
      /@media \(max-width: 63rem\)[\s\S]*\.notes-panel-switcher\s*\{[^}]*display:\s*grid/s,
    );
    expect(stylesheet).toMatch(
      /@media \(max-width: 63rem\)[\s\S]*\.notes-workspace\[data-active-panel="rail"\][\s\S]*\.notes-rail\s*\{[^}]*display:\s*flex/s,
    );
    expect(stylesheet).toMatch(
      /@media \(max-width: 63rem\)[\s\S]*\.notes-workspace\[data-active-panel="drawer"\][\s\S]*\.notes-drawer-slot\s*\{[^}]*display:\s*block/s,
    );
  });
});
