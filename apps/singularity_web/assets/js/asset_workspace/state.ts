import type {
  AssetPage,
  AssetSnapshotEvent,
  AssetState,
  AssetSummary,
  AssetUpdateEvent,
  InitialProps,
  PageSuccessReply,
  SearchSuccessReply,
  WorkspaceSnapshot,
} from "./contracts";

export const defaultLabel: Record<AssetState, string> = {
  staging: "Uploading",
  uploaded: "Verifying",
  verified: "Finalizing",
  available: "Available",
  processing: "Processing",
  ready: "Ready",
  pending_delete: "Deleting",
  deleted: "Deleted",
};

const genericFailureMessage = "The operation could not be completed.";

const publicFailureMessages: Record<string, string> = {
  unauthenticated: "Sign in to continue.",
  vault_locked: "Unlock the vault to continue.",
  forbidden: "You do not have permission to perform this operation.",
  not_found: "The asset could not be found.",
  conflict: "The asset changed. Refresh and try again.",
  invalid: genericFailureMessage,
  upload_expired: "The upload grant has expired.",
  upload_too_large: "The file is too large to upload.",
  unsupported_media_type: "This file type is not supported.",
  integrity_failure: "Integrity verification failed.",
  storage_unavailable: "Storage is temporarily unavailable.",
  job_failed: "Processing failed.",
  backup_invalid: "The backup is invalid.",
};

export function stableFailureMessage(code: string): string {
  return Object.prototype.hasOwnProperty.call(publicFailureMessages, code)
    ? publicFailureMessages[code]
    : genericFailureMessage;
}

export function visibleLabel(asset: AssetSummary): string {
  return asset.failure
    ? `Failed: ${stableFailureMessage(asset.failure.code)}`
    : defaultLabel[asset.state];
}

export function canRetry(asset: AssetSummary): boolean {
  return asset.failure?.retryable === true;
}

type Listener = () => void;

function mergeAssets(current: AssetSummary[], incoming: AssetSummary[]): AssetSummary[] {
  const merged = [...current];
  const indexes = new Map(merged.map((asset, index) => [asset.id, index]));

  for (const asset of incoming) {
    const index = indexes.get(asset.id);

    if (index === undefined) {
      indexes.set(asset.id, merged.length);
      merged.push(asset);
    } else if (asset.stateRevision > merged[index].stateRevision) {
      merged[index] = asset;
    }
  }

  return merged;
}

function replaceAssets(
  current: AssetSummary[],
  incoming: AssetSummary[],
  canonical: boolean,
): AssetSummary[] {
  const currentById = canonical
    ? new Map<string, AssetSummary>()
    : new Map(current.map((asset) => [asset.id, asset]));
  const replacement: AssetSummary[] = [];
  const indexes = new Map<string, number>();

  for (const asset of incoming) {
    const existingIndex = indexes.get(asset.id);

    if (existingIndex !== undefined) {
      if (asset.stateRevision > replacement[existingIndex].stateRevision) {
        replacement[existingIndex] = asset;
      }
      continue;
    }

    const currentAsset = currentById.get(asset.id);
    const nextAsset =
      currentAsset && currentAsset.stateRevision >= asset.stateRevision ? currentAsset : asset;

    indexes.set(asset.id, replacement.length);
    replacement.push(nextAsset);
  }

  return replacement;
}

export class WorkspaceStore {
  private snapshot: WorkspaceSnapshot;
  private readonly listeners = new Set<Listener>();
  private awaitingCanonicalSnapshot = false;

  constructor(initialProps: InitialProps) {
    if (initialProps.version !== 1) {
      throw new Error("Unsupported workspace version");
    }

    this.snapshot = {
      ...initialProps,
      assets: {
        items: [...initialProps.assets.items],
        nextCursor: initialProps.assets.nextCursor,
      },
      filters: { ...initialProps.filters },
      upload: {
        maxBytes: initialProps.upload.maxBytes,
        acceptedTypes: [...initialProps.upload.acceptedTypes],
      },
      sequence: 0,
    };
  }

  getSnapshot = (): WorkspaceSnapshot => this.snapshot;

  subscribe = (listener: Listener): (() => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };

  resetEpoch = (): void => {
    this.awaitingCanonicalSnapshot = true;
    this.commit({
      ...this.snapshot,
      sequence: 0,
      filters: {
        q: "",
        state: null,
        mediaType: null,
      },
      assets: {
        items: [],
        nextCursor: null,
      },
    });
  };

  acceptSnapshot = (event: AssetSnapshotEvent): boolean => {
    if (!this.acceptsEvent(event)) {
      return false;
    }

    const canonical = this.awaitingCanonicalSnapshot;
    this.awaitingCanonicalSnapshot = false;
    this.commit({
      ...this.snapshot,
      sequence: event.sequence,
      assets: {
        items: replaceAssets(this.snapshot.assets.items, event.assets.items, canonical),
        nextCursor: event.assets.nextCursor,
      },
    });
    return true;
  };

  acceptUpdate = (event: AssetUpdateEvent): boolean => {
    if (this.awaitingCanonicalSnapshot || !this.acceptsEvent(event)) {
      return false;
    }

    this.commit({
      ...this.snapshot,
      sequence: event.sequence,
      assets: {
        ...this.snapshot.assets,
        items: mergeAssets(this.snapshot.assets.items, [event.asset]),
      },
    });
    return true;
  };

  replaceSearch = (reply: SearchSuccessReply): boolean => {
    if (this.awaitingCanonicalSnapshot || !this.acceptsSequence(reply)) {
      return false;
    }

    this.commit({
      ...this.snapshot,
      sequence: reply.sequence,
      filters: { ...reply.filters },
      assets: {
        items: replaceAssets(this.snapshot.assets.items, reply.assets.items, false),
        nextCursor: reply.assets.nextCursor,
      },
    });
    return true;
  };

  appendPage = (reply: PageSuccessReply): boolean => {
    if (this.awaitingCanonicalSnapshot || !this.acceptsSequence(reply)) {
      return false;
    }

    const assets: AssetPage = {
      items: mergeAssets(this.snapshot.assets.items, reply.assets.items),
      nextCursor: reply.assets.nextCursor,
    };

    this.commit({
      ...this.snapshot,
      sequence: reply.sequence,
      assets,
    });
    return true;
  };

  private acceptsEvent(event: { version: number; sequence: number }): boolean {
    return event.version === 1 && this.acceptsSequence(event);
  }

  private acceptsSequence(reply: { sequence: number }): boolean {
    return Number.isSafeInteger(reply.sequence) && reply.sequence > this.snapshot.sequence;
  }

  private commit(snapshot: WorkspaceSnapshot): void {
    this.snapshot = snapshot;

    for (const listener of this.listeners) {
      listener();
    }
  }
}
