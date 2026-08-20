import type { ComponentType, ReactElement, ReactNode } from "react";
import { describe, expect, it, vi } from "vitest";

import type { InitialProps, NotesBridge } from "../js/notes_workspace/contracts";
import type { NotesWorkspaceProps } from "../js/clips/mount_notes_workspace";
import {
  createMountNotesWorkspace,
  type HookContext,
  type NotesWorkspaceModule,
} from "../js/clips/mount_notes_workspace";

const id = (suffix: string) => `019f9f65-acde-7a31-bf09-${suffix.padStart(12, "0")}`;

const initial: InitialProps = {
  version: 1,
  vault: { ref: id("1") },
  filters: { q: "" },
  summaries: [
    {
      resourceId: id("2"),
      resourceVersionId: id("3"),
      title: "Fixture",
      revision: 0,
      displayVersion: 1,
      updatedAt: "2026-08-20T12:00:00.000000Z",
      deleted: false,
      openConflictCount: 0,
    },
  ],
};

type Handler = (payload: unknown) => void;
type Push = {
  event: string;
  payload: unknown;
  resolve(value: unknown): void;
  reject(error: Error): void;
};

function FakeWorkspace(_props: NotesWorkspaceProps) {
  return null;
}

function harness(
  props = JSON.stringify(initial),
  loader: () => Promise<NotesWorkspaceModule> = async () => ({ NotesWorkspace: FakeWorkspace }),
) {
  const el = document.createElement("div");
  el.dataset.props = props;
  const root = { render: vi.fn<(node: ReactNode) => void>(), unmount: vi.fn() };
  const order: string[] = [];
  const pushes: Push[] = [];
  const handlers = new Map<string, Handler>();
  const hook = createMountNotesWorkspace({
    createRoot: (node) => {
      order.push("root");
      expect(node).toBe(el);
      return root;
    },
    loadWorkspace: () => {
      order.push("load");
      return loader();
    },
  });
  const context: HookContext = {
    el,
    handleEvent: vi.fn((name, handler) => {
      handlers.set(name, handler);
      return 1;
    }),
    pushEvent: vi.fn(
      (event, payload) =>
        new Promise((resolve, reject) => pushes.push({ event, payload, resolve, reject })),
    ),
  };
  hook.mounted.call(context);
  return { context, handlers, hook, order, pushes, root };
}

async function mountedProps(
  root: ReturnType<typeof harness>["root"],
): Promise<NotesWorkspaceProps> {
  await Promise.resolve();
  await Promise.resolve();
  const node = root.render.mock.calls.at(-1)?.[0] as ReactElement<NotesWorkspaceProps>;
  return node.props;
}

describe("MountNotesWorkspace", () => {
  it("creates the root synchronously, parses exact props, and loads one component", async () => {
    const test = harness();
    expect(test.order).toEqual(["root", "load"]);
    const props = await mountedProps(test.root);
    expect(test.root.render).toHaveBeenCalledTimes(1);
    expect(props.store.getSnapshot().summaries).toEqual(initial.summaries);
    expect(Object.keys(props.bridge).sort()).toEqual([
      "conflict",
      "create",
      "delete",
      "history",
      "merge",
      "navigate",
      "open",
      "restore",
      "save",
      "search",
      "trash",
    ]);
  });

  it("exposes typed methods that push exact Task13 event names and decode replies", async () => {
    const test = harness();
    const { bridge } = await mountedProps(test.root);
    const request = { version: 1 as const, q: "", cursor: null, limit: 20 };
    const pending = bridge.search(request);
    expect(test.pushes.at(-1)).toMatchObject({ event: "note:search", payload: request });
    test.pushes.at(-1)?.resolve({ ok: true, result: { items: [], nextCursor: null } });
    await expect(pending).resolves.toEqual({ ok: true, result: { items: [], nextCursor: null } });

    const navigate = bridge.navigate("/notes");
    expect(test.pushes.at(-1)).toMatchObject({
      event: "navigate",
      payload: { version: 1, to: "/notes" },
    });
    test.pushes.at(-1)?.resolve({ ok: true });
    await expect(navigate).resolves.toEqual({ ok: true });
    expect((bridge as NotesBridge & { push?: unknown }).push).toBeUndefined();
  });

  it("coerces malformed replies and rejected pushes without leaking partial values", async () => {
    const test = harness();
    const { bridge } = await mountedProps(test.root);
    const malformed = bridge.trash({ version: 1, cursor: null, limit: 20 });
    test.pushes.at(-1)?.resolve({ ok: true, result: { items: [], nextCursor: null }, canary: "x" });
    await expect(malformed).resolves.toEqual({ ok: false, error: { code: "invalid" } });

    const rejected = bridge.open({ version: 1, resourceId: id("2"), resourceVersionId: null });
    test.pushes.at(-1)?.reject(new Error("secret-canary"));
    await expect(rejected).resolves.toEqual({ ok: false, error: { code: "storage_unavailable" } });
  });

  it("renders one accessible generic alert for malformed props or loader failure", async () => {
    const invalid = harness('{"version":1,"markdown":"secret"}');
    expect(invalid.order).toEqual(["root"]);
    const first = invalid.root.render.mock.calls[0][0] as ReactElement;
    expect(first.props).toEqual({ role: "alert", children: "Notes workspace is unavailable." });
    expect(JSON.stringify(first)).not.toContain("secret");

    const failed = harness(JSON.stringify(initial), async () => {
      throw new Error("loader-secret");
    });
    await Promise.resolve();
    await Promise.resolve();
    const alert = failed.root.render.mock.calls.at(-1)?.[0] as ReactElement;
    expect(alert.props).toEqual({ role: "alert", children: "Notes workspace is unavailable." });
    expect(JSON.stringify(alert)).not.toContain("loader-secret");
  });

  it("unmounts exactly once and ignores a late loader completion", async () => {
    let resolve!: (module: NotesWorkspaceModule) => void;
    const loading = new Promise<NotesWorkspaceModule>((done) => {
      resolve = done;
    });
    const test = harness(JSON.stringify(initial), () => loading);
    test.hook.destroyed.call(test.context);
    test.hook.destroyed.call(test.context);
    resolve({ NotesWorkspace: FakeWorkspace as ComponentType<NotesWorkspaceProps> });
    await Promise.resolve();
    await Promise.resolve();
    expect(test.root.unmount).toHaveBeenCalledTimes(1);
    expect(test.root.render).not.toHaveBeenCalled();
  });
});
