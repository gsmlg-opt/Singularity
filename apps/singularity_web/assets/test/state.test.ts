import { describe, expect, it } from "vitest";

import type {
  AssetSnapshotEvent,
  AssetState,
  AssetSummary,
  AssetUpdateEvent,
  InitialProps,
} from "../js/asset_workspace/contracts";
import {
  canRetry,
  defaultLabel,
  stableFailureMessage,
  visibleLabel,
  WorkspaceStore,
} from "../js/asset_workspace/state";

function asset(overrides: Partial<AssetSummary> = {}): AssetSummary {
  return {
    id: "asset-1",
    resourceVersionId: "version-1",
    title: "Annual report",
    originalFilename: "annual-report.pdf",
    detectedMediaType: "application/pdf",
    state: "ready",
    stateRevision: 7,
    label: "server-owned-label",
    progress: { kind: "complete" },
    failure: null,
    updatedAt: "2026-07-31T00:00:00Z",
    ...overrides,
  };
}

function initialProps(): InitialProps {
  return {
    version: 1,
    vault: {
      ref: "vault-1",
      locked: false,
      expiresAt: null,
    },
    assets: {
      items: [asset()],
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
}

describe("asset lifecycle presentation", () => {
  it("owns the exact default label for every domain state", () => {
    const expected: Record<AssetState, string> = {
      staging: "Uploading",
      uploaded: "Verifying",
      verified: "Finalizing",
      available: "Available",
      processing: "Processing",
      ready: "Ready",
      pending_delete: "Deleting",
      deleted: "Deleted",
    };

    expect(defaultLabel).toEqual(expected);

    for (const [state, label] of Object.entries(expected)) {
      expect(visibleLabel(asset({ state: state as AssetState }))).toBe(label);
    }
  });

  it("presents failures orthogonally without exposing arbitrary codes", () => {
    const secretBearingCode = "kms_CANARY_SECRET_material";
    const failed = asset({
      state: "processing",
      failure: {
        code: secretBearingCode,
        retryable: true,
        operation: "extract",
        attempt: 3,
      },
    });

    expect(stableFailureMessage(secretBearingCode)).toBe("The operation could not be completed.");
    expect(visibleLabel(failed)).toBe("Failed: The operation could not be completed.");
    expect(visibleLabel(failed)).not.toContain(secretBearingCode);
    expect(failed.state).toBe("processing");
  });

  it("uses stable public messages and enables retry only when allowed", () => {
    expect(stableFailureMessage("vault_locked")).toBe("Unlock the vault to continue.");
    expect(stableFailureMessage("integrity_failure")).toBe("Integrity verification failed.");
    expect(
      canRetry(
        asset({
          failure: {
            code: "storage_unavailable",
            retryable: true,
            operation: "verify",
            attempt: 1,
          },
        }),
      ),
    ).toBe(true);
    expect(
      canRetry(
        asset({
          failure: {
            code: "integrity_failure",
            retryable: false,
            operation: "verify",
            attempt: 1,
          },
        }),
      ),
    ).toBe(false);
    expect(canRetry(asset())).toBe(false);
  });
});

describe("workspace store sequencing", () => {
  it("resets reconnect metadata and results to the server default before canonical data", () => {
    const store = new WorkspaceStore(initialProps());

    expect(
      store.replaceSearch({
        ok: true,
        sequence: 8,
        filters: {
          q: "report",
          state: "ready",
          mediaType: "application/pdf",
        },
        assets: {
          items: [
            asset({
              id: "filtered-result",
              resourceVersionId: "filtered-version",
              stateRevision: 8,
            }),
          ],
          nextCursor: "filtered-cursor",
        },
      }),
    ).toBe(true);

    store.resetEpoch();

    expect(store.getSnapshot()).toMatchObject({
      sequence: 0,
      filters: { q: "", state: null, mediaType: null },
      assets: { items: [], nextCursor: null },
    });

    expect(
      store.acceptSnapshot({
        version: 1,
        sequence: 1,
        assets: {
          items: [
            asset({
              id: "canonical",
              resourceVersionId: "canonical-version",
              stateRevision: 1,
            }),
          ],
          nextCursor: "default-cursor",
        },
      }),
    ).toBe(true);
    expect(store.getSnapshot()).toMatchObject({
      sequence: 1,
      filters: { q: "", state: null, mediaType: null },
      assets: { nextCursor: "default-cursor" },
    });
    expect(store.getSnapshot().assets.items.map(({ id }) => id)).toEqual(["canonical"]);
  });

  it("accepts version-less search and page success replies", () => {
    const store = new WorkspaceStore(initialProps());

    expect(
      store.replaceSearch({
        ok: true,
        sequence: 1,
        filters: {
          q: "report",
          state: "ready",
          mediaType: "application/pdf",
        },
        assets: {
          items: [
            asset({
              id: "search-result",
              resourceVersionId: "search-version",
              stateRevision: 8,
            }),
          ],
          nextCursor: "cursor-2",
        },
      }),
    ).toBe(true);
    expect(store.getSnapshot()).toMatchObject({
      sequence: 1,
      filters: { q: "report" },
    });

    expect(
      store.appendPage({
        ok: true,
        sequence: 2,
        assets: {
          items: [
            asset({
              id: "page-result",
              resourceVersionId: "page-version",
              stateRevision: 1,
            }),
          ],
          nextCursor: null,
        },
      }),
    ).toBe(true);
    expect(store.getSnapshot().assets.items.map(({ id }) => id)).toEqual([
      "search-result",
      "page-result",
    ]);
  });

  it("requires version 1 for snapshot and update events", () => {
    const store = new WorkspaceStore(initialProps());
    const canonical = asset({
      id: "canonical",
      resourceVersionId: "canonical-version",
      stateRevision: 1,
    });

    expect(
      store.acceptSnapshot({
        version: 2,
        sequence: 1,
        assets: { items: [canonical], nextCursor: null },
      } as unknown as AssetSnapshotEvent),
    ).toBe(false);
    expect(store.getSnapshot().sequence).toBe(0);

    expect(
      store.acceptSnapshot({
        version: 1,
        sequence: 1,
        assets: { items: [canonical], nextCursor: null },
      }),
    ).toBe(true);

    expect(
      store.acceptUpdate({
        version: 2,
        sequence: 2,
        asset: asset({
          ...canonical,
          stateRevision: 2,
          title: "Wrong version",
        }),
      } as unknown as AssetUpdateEvent),
    ).toBe(false);
    expect(store.getSnapshot().sequence).toBe(1);

    expect(
      store.acceptUpdate({
        version: 1,
        sequence: 2,
        asset: asset({
          ...canonical,
          stateRevision: 2,
          title: "Fresh update",
        }),
      }),
    ).toBe(true);
    expect(store.getSnapshot().assets.items[0]).toMatchObject({
      title: "Fresh update",
      stateRevision: 2,
    });
  });
});
