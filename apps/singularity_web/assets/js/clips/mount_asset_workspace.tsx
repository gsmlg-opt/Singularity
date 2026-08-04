import { createElement, type ComponentType, type ReactNode } from "react";
import { createRoot } from "react-dom/client";

import type { AssetWorkspaceProps } from "../asset_workspace/AssetWorkspace";
import type {
  AssetFilters,
  AssetMutationReply,
  AssetPage,
  AssetSnapshotEvent,
  AssetState,
  AssetSummary,
  AssetUpdateEvent,
  Bridge,
  FailureReply,
  InitialProps,
  NavigationTarget,
  NavigationReply,
  PageReply,
  SearchReply,
  UploadGrantReply,
} from "../asset_workspace/contracts";
import { WorkspaceStore } from "../asset_workspace/state";

type EventHandler = (payload: unknown) => void;

export type HookContext = {
  el: HTMLElement;
  handleEvent(name: string, handler: EventHandler): unknown;
  pushEvent(event: string, payload: unknown): Promise<unknown>;
};

type Root = {
  render(node: ReactNode): void;
  unmount(): void;
};

export type WorkspaceModule = {
  AssetWorkspace: ComponentType<AssetWorkspaceProps>;
};

type MountDependencies = {
  createRoot(element: HTMLElement): Root;
  loadWorkspace(): Promise<WorkspaceModule>;
  uploadAttemptFactory?: AssetWorkspaceProps["uploadAttemptFactory"];
};

type MountedWorkspace = {
  destroyed: boolean;
  filterGeneration: number;
  root: Root;
  store?: WorkspaceStore;
};

const navigationTargets = new Set<NavigationTarget>([
  "/assets",
  "/activity",
  "/audit",
  "/backups",
  "/settings",
]);

const assetStates = new Set<AssetState>([
  "staging",
  "uploaded",
  "verified",
  "available",
  "processing",
  "ready",
  "pending_delete",
  "deleted",
]);

const unavailableMessage = "Asset workspace is unavailable.";

function unavailableAlert(): ReactNode {
  return createElement("div", { role: "alert" }, unavailableMessage);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function hasExactKeys(value: Record<string, unknown>, keys: readonly string[]): boolean {
  const actual = Object.keys(value);
  return (
    actual.length === keys.length &&
    keys.every((key) => Object.prototype.hasOwnProperty.call(value, key))
  );
}

function isNullableString(value: unknown): value is string | null {
  return typeof value === "string" || value === null;
}

function isSafeInteger(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value);
}

function isAssetState(value: unknown): value is AssetState {
  return typeof value === "string" && assetStates.has(value as AssetState);
}

function isProgress(value: unknown): boolean {
  if (value === null) {
    return true;
  }
  if (!isRecord(value) || typeof value.kind !== "string") {
    return false;
  }
  if (
    value.kind === "indeterminate" ||
    value.kind === "complete" ||
    value.kind === "waiting_for_unlock"
  ) {
    return hasExactKeys(value, ["kind"]);
  }
  return (
    value.kind === "bytes" &&
    hasExactKeys(value, ["kind", "sent", "total"]) &&
    typeof value.sent === "number" &&
    Number.isFinite(value.sent) &&
    typeof value.total === "number" &&
    Number.isFinite(value.total)
  );
}

function isFailure(value: unknown): boolean {
  return (
    value === null ||
    (isRecord(value) &&
      hasExactKeys(value, ["code", "retryable", "operation", "attempt"]) &&
      typeof value.code === "string" &&
      typeof value.retryable === "boolean" &&
      typeof value.operation === "string" &&
      isSafeInteger(value.attempt))
  );
}

function isAssetSummary(value: unknown): value is AssetSummary {
  return (
    isRecord(value) &&
    hasExactKeys(value, [
      "id",
      "resourceVersionId",
      "title",
      "originalFilename",
      "detectedMediaType",
      "state",
      "stateRevision",
      "label",
      "progress",
      "failure",
      "updatedAt",
    ]) &&
    typeof value.id === "string" &&
    typeof value.resourceVersionId === "string" &&
    typeof value.title === "string" &&
    typeof value.originalFilename === "string" &&
    isNullableString(value.detectedMediaType) &&
    isAssetState(value.state) &&
    isSafeInteger(value.stateRevision) &&
    typeof value.label === "string" &&
    isProgress(value.progress) &&
    isFailure(value.failure) &&
    typeof value.updatedAt === "string"
  );
}

function isAssetPage(value: unknown): value is AssetPage {
  return (
    isRecord(value) &&
    hasExactKeys(value, ["items", "nextCursor"]) &&
    Array.isArray(value.items) &&
    value.items.every(isAssetSummary) &&
    isNullableString(value.nextCursor)
  );
}

function isFilters(value: unknown): value is AssetFilters {
  return (
    isRecord(value) &&
    hasExactKeys(value, ["q", "state", "mediaType"]) &&
    typeof value.q === "string" &&
    (value.state === null || isAssetState(value.state)) &&
    isNullableString(value.mediaType)
  );
}

function isInitialProps(value: unknown): value is InitialProps {
  if (
    !isRecord(value) ||
    !hasExactKeys(value, ["version", "vault", "assets", "filters", "upload"]) ||
    value.version !== 1 ||
    !isRecord(value.vault) ||
    !hasExactKeys(value.vault, ["ref", "locked", "expiresAt"]) ||
    typeof value.vault.ref !== "string" ||
    typeof value.vault.locked !== "boolean" ||
    !isNullableString(value.vault.expiresAt) ||
    !isAssetPage(value.assets) ||
    !isFilters(value.filters) ||
    !isRecord(value.upload) ||
    !hasExactKeys(value.upload, ["maxBytes", "acceptedTypes"])
  ) {
    return false;
  }

  return (
    isSafeInteger(value.upload.maxBytes) &&
    Array.isArray(value.upload.acceptedTypes) &&
    value.upload.acceptedTypes.every((type) => typeof type === "string")
  );
}

function isSnapshot(value: unknown): value is AssetSnapshotEvent {
  return (
    isRecord(value) &&
    hasExactKeys(value, ["version", "sequence", "assets"]) &&
    value.version === 1 &&
    isSafeInteger(value.sequence) &&
    isAssetPage(value.assets)
  );
}

function isUpdate(value: unknown): value is AssetUpdateEvent {
  return (
    isRecord(value) &&
    hasExactKeys(value, ["version", "sequence", "asset"]) &&
    value.version === 1 &&
    isSafeInteger(value.sequence) &&
    isAssetSummary(value.asset)
  );
}

function invalidReply(): FailureReply {
  return { ok: false, error: { code: "invalid" } };
}

function decodeFailure(value: unknown): FailureReply | null {
  if (
    !isRecord(value) ||
    !hasExactKeys(value, ["ok", "error"]) ||
    value.ok !== false ||
    !isRecord(value.error) ||
    !hasExactKeys(value.error, ["code"]) ||
    typeof value.error.code !== "string"
  ) {
    return null;
  }

  return { ok: false, error: { code: value.error.code } };
}

function decodeSearchReply(value: unknown): SearchReply {
  const failure = decodeFailure(value);
  if (failure) {
    return failure;
  }
  if (
    isRecord(value) &&
    hasExactKeys(value, ["ok", "sequence", "filters", "assets"]) &&
    value.ok === true &&
    isSafeInteger(value.sequence) &&
    isFilters(value.filters) &&
    isAssetPage(value.assets)
  ) {
    return {
      ok: true,
      sequence: value.sequence,
      filters: value.filters,
      assets: value.assets,
    };
  }
  return invalidReply();
}

function decodePageReply(value: unknown): PageReply {
  const failure = decodeFailure(value);
  if (failure) {
    return failure;
  }
  if (
    isRecord(value) &&
    hasExactKeys(value, ["ok", "sequence", "assets"]) &&
    value.ok === true &&
    isSafeInteger(value.sequence) &&
    isAssetPage(value.assets)
  ) {
    return {
      ok: true,
      sequence: value.sequence,
      assets: value.assets,
    };
  }
  return invalidReply();
}

function decodeGrantReply(value: unknown): UploadGrantReply {
  const failure = decodeFailure(value);
  if (failure) {
    return failure;
  }
  if (
    isRecord(value) &&
    hasExactKeys(value, ["ok", "grantId", "uploadToken", "uploadUrl", "expiresAt"]) &&
    value.ok === true &&
    typeof value.grantId === "string" &&
    typeof value.uploadToken === "string" &&
    typeof value.uploadUrl === "string" &&
    typeof value.expiresAt === "string"
  ) {
    return {
      ok: true,
      grantId: value.grantId,
      uploadToken: value.uploadToken,
      uploadUrl: value.uploadUrl,
      expiresAt: value.expiresAt,
    };
  }
  return invalidReply();
}

function decodeMutationReply(value: unknown): AssetMutationReply {
  const failure = decodeFailure(value);
  if (failure) {
    return failure;
  }
  if (
    isRecord(value) &&
    hasExactKeys(value, ["ok", "accepted"]) &&
    value.ok === true &&
    typeof value.accepted === "boolean"
  ) {
    return { ok: true, accepted: value.accepted };
  }
  return invalidReply();
}

function decodeNavigationReply(value: unknown): NavigationReply {
  const failure = decodeFailure(value);
  if (failure) {
    return failure;
  }
  return isRecord(value) && hasExactKeys(value, ["ok"]) && value.ok === true
    ? { ok: true }
    : invalidReply();
}

function sameFilters(
  left: {
    q: string;
    state: string | null;
    mediaType: string | null;
  },
  right: {
    q: string;
    state: string | null;
    mediaType: string | null;
  },
): boolean {
  return left.q === right.q && left.state === right.state && left.mediaType === right.mediaType;
}

async function push<Reply>(
  context: HookContext,
  event: string,
  payload: unknown,
  decode: (reply: unknown) => Reply,
): Promise<Reply> {
  try {
    return decode(await context.pushEvent(event, payload));
  } catch {
    return invalidReply() as Reply;
  }
}

function createBridge(
  context: HookContext,
  mounted: MountedWorkspace & { store: WorkspaceStore },
): Bridge {
  return {
    async search(request) {
      const generation = ++mounted.filterGeneration;
      const reply = await push<Awaited<ReturnType<Bridge["search"]>>>(
        context,
        "asset:search",
        request,
        decodeSearchReply,
      );

      if (reply.ok && generation === mounted.filterGeneration) {
        mounted.store.replaceSearch(reply);
      }

      return reply;
    },

    async page(request) {
      const generation = mounted.filterGeneration;
      const current = mounted.store.getSnapshot();
      const currentRequest =
        sameFilters(current.filters, request) && current.assets.nextCursor === request.cursor;
      const reply = await push<Awaited<ReturnType<Bridge["page"]>>>(
        context,
        "asset:page",
        request,
        decodePageReply,
      );
      const latest = mounted.store.getSnapshot();

      if (
        reply.ok &&
        currentRequest &&
        generation === mounted.filterGeneration &&
        sameFilters(latest.filters, request) &&
        latest.assets.nextCursor === request.cursor
      ) {
        mounted.store.appendPage(reply);
      }

      return reply;
    },

    grant(request) {
      return push<Awaited<ReturnType<Bridge["grant"]>>>(
        context,
        "upload:grant",
        request,
        decodeGrantReply,
      );
    },

    cancel(request) {
      return push<Awaited<ReturnType<Bridge["cancel"]>>>(
        context,
        "upload:cancel",
        request,
        decodeMutationReply,
      );
    },

    retry(request) {
      return push<Awaited<ReturnType<Bridge["retry"]>>>(
        context,
        "asset:retry",
        request,
        decodeMutationReply,
      );
    },

    delete(request) {
      return push<Awaited<ReturnType<Bridge["delete"]>>>(
        context,
        "asset:delete",
        request,
        decodeMutationReply,
      );
    },

    navigate(to) {
      if (!navigationTargets.has(to)) {
        return Promise.reject(new Error("Navigation target is not allowed."));
      }

      return push<Awaited<ReturnType<Bridge["navigate"]>>>(
        context,
        "navigate",
        { version: 1, to },
        decodeNavigationReply,
      );
    },
  };
}

export function createMountAssetWorkspace(dependencies: MountDependencies) {
  const mountedWorkspaces = new WeakMap<HookContext, MountedWorkspace>();

  return {
    mounted(this: HookContext) {
      const root = dependencies.createRoot(this.el);
      const mounted: MountedWorkspace = {
        destroyed: false,
        filterGeneration: 0,
        root,
      };
      mountedWorkspaces.set(this, mounted);

      let initialProps: unknown;
      try {
        initialProps = JSON.parse(this.el.dataset.props ?? "{}");
      } catch {
        root.render(unavailableAlert());
        return;
      }

      if (!isInitialProps(initialProps)) {
        root.render(unavailableAlert());
        return;
      }

      const validMounted = {
        ...mounted,
        store: new WorkspaceStore(initialProps),
      };
      mountedWorkspaces.set(this, validMounted);

      this.handleEvent("asset:snapshot", (payload) => {
        try {
          if (isSnapshot(payload)) {
            validMounted.store.acceptSnapshot(payload);
          }
        } catch {
          // Ignore malformed runtime payloads at the LiveView boundary.
        }
      });
      this.handleEvent("asset:update", (payload) => {
        try {
          if (isUpdate(payload)) {
            validMounted.store.acceptUpdate(payload);
          }
        } catch {
          // Ignore malformed runtime payloads at the LiveView boundary.
        }
      });

      const bridge = createBridge(this, validMounted);
      let loading: Promise<WorkspaceModule>;
      try {
        loading = dependencies.loadWorkspace();
      } catch {
        root.render(unavailableAlert());
        return;
      }

      void loading
        .then(({ AssetWorkspace }) => {
          if (validMounted.destroyed) {
            return;
          }

          root.render(
            createElement(AssetWorkspace, {
              bridge,
              store: validMounted.store,
              uploadAttemptFactory: dependencies.uploadAttemptFactory,
            }),
          );
        })
        .catch(() => {
          if (!validMounted.destroyed) {
            root.render(unavailableAlert());
          }
        });
    },

    disconnected(this: HookContext) {
      const mounted = mountedWorkspaces.get(this);

      if (mounted?.store && !mounted.destroyed) {
        mounted.filterGeneration += 1;
        mounted.store.resetEpoch();
      }
    },

    reconnected(this: HookContext) {},

    destroyed(this: HookContext) {
      const mounted = mountedWorkspaces.get(this);

      if (mounted && !mounted.destroyed) {
        mounted.destroyed = true;
        mounted.root.unmount();
      }
    },
  };
}

export const MountAssetWorkspace = createMountAssetWorkspace({
  createRoot,
  loadWorkspace: () => import("../asset_workspace/AssetWorkspace"),
});
