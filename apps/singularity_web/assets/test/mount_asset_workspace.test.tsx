import type { ComponentType, ReactElement, ReactNode } from "react";
import { describe, expect, it, vi } from "vitest";

import type { AssetSummary, Bridge, InitialProps } from "../js/asset_workspace/contracts";
import type { AssetWorkspaceProps } from "../js/asset_workspace/AssetWorkspace";
import {
  createMountAssetWorkspace,
  type HookContext,
  type WorkspaceModule,
} from "../js/clips/mount_asset_workspace";

function asset(id: string, stateRevision = 1, overrides: Partial<AssetSummary> = {}): AssetSummary {
  return {
    id,
    resourceVersionId: `${id}-version`,
    title: `Asset ${id}`,
    originalFilename: `${id}.pdf`,
    detectedMediaType: "application/pdf",
    state: "uploaded",
    stateRevision,
    label: "Verifying",
    progress: { kind: "indeterminate" },
    failure: null,
    updatedAt: "2026-07-31T00:00:00Z",
    ...overrides,
  };
}

const initialProps: InitialProps = {
  version: 1,
  vault: {
    ref: "vault-1",
    locked: false,
    expiresAt: null,
  },
  assets: {
    items: [asset("one", 3)],
    nextCursor: "cursor-1",
  },
  filters: {
    q: "",
    state: null,
    mediaType: null,
  },
  upload: {
    maxBytes: 1024,
    acceptedTypes: ["application/pdf"],
  },
};

type EventHandler = (payload: unknown) => void;
type PushCall = {
  event: string;
  payload: unknown;
  resolve: (payload: unknown) => void;
  reject: (reason?: unknown) => void;
};

function FakeWorkspace(_props: AssetWorkspaceProps) {
  return null;
}

function harness(
  loadWorkspace: () => Promise<WorkspaceModule> = async () => ({
    AssetWorkspace: FakeWorkspace,
  }),
  order: string[] = [],
  props = JSON.stringify(initialProps),
  autoMount = true,
) {
  const element = document.createElement("div");
  element.dataset.props = props;
  const handlers = new Map<string, EventHandler>();
  const pushes: PushCall[] = [];
  const root = {
    render: vi.fn<(node: ReactNode) => void>(),
    unmount: vi.fn<() => void>(),
  };
  const createRoot = vi.fn(() => {
    order.push("root");
    return root;
  });
  const hook = createMountAssetWorkspace({
    createRoot,
    loadWorkspace: () => {
      order.push("load");
      return loadWorkspace();
    },
  });
  const context: HookContext = {
    el: element,
    handleEvent: vi.fn((name: string, handler: EventHandler) => {
      handlers.set(name, handler);
      return 1;
    }),
    pushEvent: vi.fn(
      (event: string, payload: unknown) =>
        new Promise((resolve, reject) => {
          pushes.push({ event, payload, resolve, reject });
        }),
    ),
  };

  if (autoMount) {
    hook.mounted.call(context);
  }

  return {
    context,
    createRoot,
    handlers,
    hook,
    pushes,
    root,
    mount: () => hook.mounted.call(context),
  };
}

async function loadedProps(root: ReturnType<typeof harness>["root"]): Promise<AssetWorkspaceProps> {
  await Promise.resolve();
  await Promise.resolve();
  const element = root.render.mock.calls.at(-1)?.[0] as ReactElement<AssetWorkspaceProps>;
  return element.props;
}

describe("MountAssetWorkspace", () => {
  it("renders one stable alert and skips loading for malformed initial props", () => {
    const loadWorkspace = vi.fn(async () => ({ AssetWorkspace: FakeWorkspace }));

    for (const props of [
      '{"canary":"bad-json"',
      JSON.stringify({ version: 1, canary: "incomplete-v1" }),
    ]) {
      const order: string[] = [];
      const test = harness(loadWorkspace, order, props, false);

      expect(test.mount).not.toThrow();
      expect(order).toEqual(["root"]);
      expect(test.handlers.size).toBe(0);
      expect(test.root.render).toHaveBeenCalledTimes(1);

      const alert = test.root.render.mock.calls[0][0] as ReactElement<{
        role: string;
        children: string;
      }>;
      expect(alert.type).toBe("div");
      expect(alert.props).toEqual({
        role: "alert",
        children: "Asset workspace is unavailable.",
      });
      expect(JSON.stringify(alert)).not.toContain("canary");
    }

    expect(loadWorkspace).not.toHaveBeenCalled();
  });

  it("creates one root synchronously before async loading and preserves exact v1 props", async () => {
    const order: string[] = [];
    const test = harness(undefined, order);

    expect(order).toEqual(["root", "load"]);
    expect(test.createRoot).toHaveBeenCalledTimes(1);
    expect(test.createRoot).toHaveBeenCalledWith(test.context.el);

    const props = await loadedProps(test.root);
    expect(test.root.render).toHaveBeenCalledTimes(1);
    expect(props.store.getSnapshot()).toEqual({
      ...initialProps,
      sequence: 0,
    });
    expect([...test.handlers.keys()]).toEqual(["asset:snapshot", "asset:update"]);
  });

  it("unmounts exactly once and never renders after a late async load", async () => {
    let resolveLoad!: (module: WorkspaceModule) => void;
    const load = new Promise<WorkspaceModule>((resolve) => {
      resolveLoad = resolve;
    });
    const test = harness(() => load);

    test.hook.destroyed.call(test.context);
    test.hook.destroyed.call(test.context);
    resolveLoad({ AssetWorkspace: FakeWorkspace as ComponentType<AssetWorkspaceProps> });
    await Promise.resolve();
    await Promise.resolve();

    expect(test.root.unmount).toHaveBeenCalledTimes(1);
    expect(test.root.render).not.toHaveBeenCalled();
    expect(test.createRoot).toHaveBeenCalledTimes(1);
  });

  it("replaces snapshots, merges only newer revisions, and rejects stale events", async () => {
    const test = harness();
    const props = await loadedProps(test.root);
    const snapshot = test.handlers.get("asset:snapshot");
    const update = test.handlers.get("asset:update");

    snapshot?.({
      version: 1,
      sequence: 1,
      assets: {
        items: [asset("canonical", 4, { state: "ready" })],
        nextCursor: null,
      },
    });
    expect(props.store.getSnapshot().assets.items.map(({ id }) => id)).toEqual(["canonical"]);

    update?.({
      version: 1,
      sequence: 2,
      asset: asset("canonical", 5, {
        state: "pending_delete",
        title: "Fresh update",
      }),
    });
    expect(props.store.getSnapshot().assets.items[0]).toMatchObject({
      title: "Fresh update",
      stateRevision: 5,
    });

    update?.({
      version: 1,
      sequence: 3,
      asset: asset("canonical", 4, { title: "Stale revision" }),
    });
    update?.({
      version: 1,
      sequence: 2,
      asset: asset("canonical", 6, { title: "Stale sequence" }),
    });
    update?.({
      version: 2,
      sequence: 4,
      asset: asset("canonical", 7, { title: "Wrong version" }),
    });

    expect(props.store.getSnapshot()).toMatchObject({ sequence: 3 });
    expect(props.store.getSnapshot().assets.items[0]).toMatchObject({
      title: "Fresh update",
      stateRevision: 5,
    });
  });

  it("ignores malformed events and coerces every malformed reply family", async () => {
    const test = harness();
    const { bridge, store } = await loadedProps(test.root);
    const before = store.getSnapshot();
    const snapshot = test.handlers.get("asset:snapshot");
    const update = test.handlers.get("asset:update");

    for (const invoke of [
      () => snapshot?.(null),
      () =>
        snapshot?.({
          version: 1,
          sequence: 1,
          assets: {
            items: [
              asset("canary", 1, {
                progress: { kind: "bytes", sent: 1, total: "bad" } as never,
              }),
            ],
            nextCursor: null,
          },
        }),
      () =>
        update?.({
          version: 1,
          sequence: 1,
          asset: asset("canary", 1, {
            failure: {
              code: "job_failed",
              retryable: true,
              operation: "canary",
            } as never,
          }),
        }),
    ]) {
      expect(invoke).not.toThrow();
    }
    expect(store.getSnapshot()).toEqual(before);

    const operations = [
      () =>
        bridge.search({
          version: 1,
          q: "canary",
          state: null,
          mediaType: null,
        }),
      () =>
        bridge.page({
          version: 1,
          cursor: "cursor-1",
          q: "",
          state: null,
          mediaType: null,
        }),
      () =>
        bridge.grant({
          version: 1,
          filename: "canary.pdf",
          size: 1,
          mediaType: "application/pdf",
          idempotencyKey: "canary",
        }),
      () => bridge.retry({ version: 1, assetId: "one", stateRevision: 3 }),
      () => bridge.delete({ version: 1, assetId: "one", stateRevision: 3 }),
      () => bridge.navigate("/assets"),
    ];

    for (const operation of operations) {
      const pending = operation();
      test.pushes.at(-1)?.resolve({ ok: true, canary: "reply-canary" });
      const reply = await pending;

      expect(reply).toEqual({ ok: false, error: { code: "invalid" } });
      expect(JSON.stringify(reply)).not.toContain("canary");
    }
    expect(store.getSnapshot()).toEqual(before);
  });

  it("renders the stable alert on load rejection only while still mounted", async () => {
    const live = harness(async () => {
      throw new Error("live-load-canary");
    });
    await Promise.resolve();
    await Promise.resolve();

    const alert = live.root.render.mock.calls[0][0] as ReactElement<{
      role: string;
      children: string;
    }>;
    expect(alert.props).toEqual({
      role: "alert",
      children: "Asset workspace is unavailable.",
    });
    expect(JSON.stringify(alert)).not.toContain("canary");

    let rejectLoad!: (reason: Error) => void;
    const load = new Promise<WorkspaceModule>((_resolve, reject) => {
      rejectLoad = reject;
    });
    const destroyed = harness(() => load);
    destroyed.hook.destroyed.call(destroyed.context);
    rejectLoad(new Error("late-load-canary"));
    await Promise.resolve();
    await Promise.resolve();

    expect(destroyed.root.unmount).toHaveBeenCalledTimes(1);
    expect(destroyed.root.render).not.toHaveBeenCalled();
  });

  it("applies current search replacement and fresh page append without duplicate ids", async () => {
    const test = harness();
    const { bridge, store } = await loadedProps(test.root);
    const searchRequest = {
      version: 1 as const,
      q: "report",
      state: "ready" as const,
      mediaType: "application/pdf",
    };
    const search = bridge.search(searchRequest);

    expect(test.pushes[0]).toMatchObject({
      event: "asset:search",
      payload: searchRequest,
    });
    test.pushes[0].resolve({
      ok: true,
      sequence: 1,
      filters: {
        q: "report",
        state: "ready",
        mediaType: "application/pdf",
      },
      assets: {
        items: [asset("report", 7, { state: "ready" })],
        nextCursor: "page-2",
      },
    });
    await search;

    expect(store.getSnapshot()).toMatchObject({
      sequence: 1,
      filters: {
        q: "report",
        state: "ready",
        mediaType: "application/pdf",
      },
    });
    expect(store.getSnapshot().assets.items.map(({ id }) => id)).toEqual(["report"]);

    const pageRequest = {
      version: 1 as const,
      cursor: "page-2",
      q: "report",
      state: "ready" as const,
      mediaType: "application/pdf",
    };
    const page = bridge.page(pageRequest);
    expect(test.pushes[1]).toMatchObject({
      event: "asset:page",
      payload: pageRequest,
    });
    test.pushes[1].resolve({
      ok: true,
      sequence: 2,
      assets: {
        items: [asset("report", 6, { title: "Older duplicate" }), asset("appendix", 1)],
        nextCursor: null,
      },
    });
    await page;

    expect(store.getSnapshot().assets.items.map(({ id }) => id)).toEqual(["report", "appendix"]);
    expect(store.getSnapshot().assets.items[0].title).not.toBe("Older duplicate");
  });

  it("ignores replies for superseded filters even when their sequence is higher", async () => {
    const test = harness();
    const { bridge, store } = await loadedProps(test.root);
    const alpha = bridge.search({
      version: 1,
      q: "alpha",
      state: null,
      mediaType: null,
    });
    const beta = bridge.search({
      version: 1,
      q: "beta",
      state: null,
      mediaType: null,
    });

    test.pushes[1].resolve({
      ok: true,
      sequence: 1,
      filters: { q: "beta", state: null, mediaType: null },
      assets: { items: [asset("beta")], nextCursor: null },
    });
    await beta;
    test.pushes[0].resolve({
      ok: true,
      sequence: 2,
      filters: { q: "alpha", state: null, mediaType: null },
      assets: { items: [asset("alpha")], nextCursor: null },
    });
    await alpha;

    expect(store.getSnapshot().filters.q).toBe("beta");
    expect(store.getSnapshot().assets.items[0].id).toBe("beta");
  });

  it("resets reconnect filters and results before accepting the default canonical page", async () => {
    const test = harness();
    const props = await loadedProps(test.root);
    const snapshot = test.handlers.get("asset:snapshot");
    const update = test.handlers.get("asset:update");

    props.store.replaceSearch({
      ok: true,
      sequence: 8,
      filters: {
        q: "report",
        state: "ready",
        mediaType: "application/pdf",
      },
      assets: {
        items: [asset("before-reconnect", 8, { state: "ready" })],
        nextCursor: "filtered-cursor",
      },
    });
    test.hook.disconnected.call(test.context);
    test.hook.disconnected.call(test.context);
    update?.({
      version: 1,
      sequence: 99,
      asset: asset("before-reconnect", 99, {
        title: "Must wait for canonical snapshot",
      }),
    });

    expect(props.store.getSnapshot()).toMatchObject({
      sequence: 0,
      filters: { q: "", state: null, mediaType: null },
      assets: { items: [], nextCursor: null },
    });

    snapshot?.({
      version: 1,
      sequence: 1,
      assets: { items: [asset("canonical", 1)], nextCursor: "default-cursor" },
    });
    test.hook.reconnected.call(test.context);
    test.hook.reconnected.call(test.context);

    expect(props.store.getSnapshot()).toMatchObject({
      sequence: 1,
      filters: { q: "", state: null, mediaType: null },
      assets: { nextCursor: "default-cursor" },
    });
    expect(props.store.getSnapshot().assets.items.map(({ id }) => id)).toEqual(["canonical"]);

    const page = props.bridge.page({
      version: 1,
      cursor: "default-cursor",
      q: "",
      state: null,
      mediaType: null,
    });
    expect(test.pushes[0]).toMatchObject({
      event: "asset:page",
      payload: {
        version: 1,
        cursor: "default-cursor",
        q: "",
        state: null,
        mediaType: null,
      },
    });
    test.pushes[0].resolve({
      ok: true,
      sequence: 2,
      assets: { items: [asset("appendix", 1)], nextCursor: null },
    });
    await page;

    update?.({
      version: 1,
      sequence: 3,
      asset: asset("canonical", 2, { title: "After reconnect" }),
    });

    expect(props.store.getSnapshot()).toMatchObject({
      sequence: 3,
      filters: { q: "", state: null, mediaType: null },
    });
    expect(props.store.getSnapshot().assets.items).toHaveLength(2);
    expect(props.store.getSnapshot().assets.items[0]).toMatchObject({
      id: "canonical",
      title: "After reconnect",
    });
    expect(props.store.getSnapshot().assets.items[1]).toMatchObject({ id: "appendix" });
  });

  it("never resets a delivered rejoin snapshot from reconnected callbacks", async () => {
    const test = harness();
    const props = await loadedProps(test.root);
    const snapshot = test.handlers.get("asset:snapshot");

    props.store.resetEpoch();
    snapshot?.({
      version: 1,
      sequence: 1,
      assets: { items: [asset("rejoined", 1)], nextCursor: "rejoin-cursor" },
    });

    test.hook.reconnected.call(test.context);
    test.hook.reconnected.call(test.context);

    expect(props.store.getSnapshot()).toMatchObject({
      sequence: 1,
      filters: { q: "", state: null, mediaType: null },
      assets: { nextCursor: "rejoin-cursor" },
    });
    expect(props.store.getSnapshot().assets.items.map(({ id }) => id)).toEqual(["rejoined"]);
  });

  it("uses the exact grant, mutation, and allow-listed navigation events", async () => {
    const test = harness();
    const { bridge } = await loadedProps(test.root);

    const grantRequest = {
      version: 1 as const,
      filename: "report.pdf",
      size: 42,
      mediaType: "application/pdf",
      idempotencyKey: "attempt-1",
    };
    const grant = bridge.grant(grantRequest);
    test.pushes[0].resolve({
      ok: true,
      grantId: "grant-1",
      uploadToken: "one-use-token",
      uploadUrl: "/api/v1/uploads/grant-1",
      expiresAt: "2026-08-01T00:00:00Z",
    });
    await grant;

    const cancel = bridge.cancel({ version: 1, grantId: "grant-1" });
    test.pushes[1].resolve({ ok: true, accepted: true });
    await cancel;

    const retry = bridge.retry({
      version: 1,
      assetId: "one",
      stateRevision: 3,
    });
    test.pushes[2].resolve({ ok: true, accepted: true });
    await retry;

    const remove = bridge.delete({
      version: 1,
      assetId: "one",
      stateRevision: 3,
    });
    test.pushes[3].resolve({ ok: true, accepted: true });
    await remove;

    const navigate = bridge.navigate("/audit");
    test.pushes[4].resolve({ ok: true });
    await navigate;

    expect(test.pushes.map(({ event, payload }) => ({ event, payload }))).toEqual([
      { event: "upload:grant", payload: grantRequest },
      {
        event: "upload:cancel",
        payload: { version: 1, grantId: "grant-1" },
      },
      {
        event: "asset:retry",
        payload: { version: 1, assetId: "one", stateRevision: 3 },
      },
      {
        event: "asset:delete",
        payload: { version: 1, assetId: "one", stateRevision: 3 },
      },
      {
        event: "navigate",
        payload: { version: 1, to: "/audit" },
      },
    ]);

    await expect(bridge.navigate("/admin" as Parameters<Bridge["navigate"]>[0])).rejects.toThrow(
      "Navigation target is not allowed.",
    );
    expect(test.pushes).toHaveLength(5);
  });

  it("settles every rejected Phoenix push with one stable public failure", async () => {
    const test = harness();
    const { bridge } = await loadedProps(test.root);
    const secretDetail = "disconnect_SECRET_transport_detail";
    const requests: Array<() => Promise<unknown>> = [
      () => bridge.search({ version: 1, q: "", state: null, mediaType: null }),
      () =>
        bridge.page({
          version: 1,
          cursor: "cursor-1",
          q: "",
          state: null,
          mediaType: null,
        }),
      () =>
        bridge.grant({
          version: 1,
          filename: "report.pdf",
          size: 42,
          mediaType: "application/pdf",
          idempotencyKey: "attempt-1",
        }),
      () => bridge.cancel({ version: 1, grantId: "grant-1" }),
      () => bridge.retry({ version: 1, assetId: "one", stateRevision: 3 }),
      () => bridge.delete({ version: 1, assetId: "one", stateRevision: 3 }),
      () => bridge.navigate("/audit"),
    ];

    const results: unknown[] = [];
    for (const request of requests) {
      const result = request();
      test.pushes.at(-1)?.reject(new Error(secretDetail));
      results.push(await result);
    }

    expect(results).toEqual(requests.map(() => ({ ok: false, error: { code: "invalid" } })));
    expect(JSON.stringify(results)).not.toContain(secretDetail);
    expect(test.pushes.map(({ event }) => event)).toEqual([
      "asset:search",
      "asset:page",
      "upload:grant",
      "upload:cancel",
      "asset:retry",
      "asset:delete",
      "navigate",
    ]);
  });
});
