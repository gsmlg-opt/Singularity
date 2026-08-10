import {
  type ChangeEvent,
  type FormEvent,
  useEffect,
  useRef,
  useState,
  useSyncExternalStore,
} from "react";

import type { AssetProgress, AssetState, AssetSummary, Bridge } from "./contracts";
import { canRetry, stableFailureMessage, visibleLabel, type WorkspaceStore } from "./state";
import { applyTheme, readTheme, type Theme } from "./theme";
import {
  createUploadAttempt,
  readCsrfToken,
  type UploadAttempt,
  type UploadAttemptFactory,
  type UploadAttemptResult,
} from "./upload";

export type AssetWorkspaceProps = {
  bridge: Bridge;
  store: WorkspaceStore;
  uploadAttemptFactory?: UploadAttemptFactory;
};

const assetStates: Array<{ value: AssetState; label: string }> = [
  { value: "staging", label: "Uploading" },
  { value: "uploaded", label: "Verifying" },
  { value: "verified", label: "Finalizing" },
  { value: "available", label: "Available" },
  { value: "processing", label: "Processing" },
  { value: "ready", label: "Ready" },
  { value: "pending_delete", label: "Deleting" },
];

const mediaTypes = [
  { value: "application/pdf", label: "PDF" },
  { value: "image/jpeg", label: "JPEG image" },
  { value: "image/png", label: "PNG image" },
];

type Notice = {
  tone: "error" | "info";
  text: string;
};

function uniqueIdempotencyKey(): string {
  try {
    if (typeof crypto.randomUUID === "function") {
      return crypto.randomUUID();
    }

    const bytes = crypto.getRandomValues(new Uint8Array(16));
    return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
  } catch {
    return `${Date.now()}-${Math.random().toString(36).slice(2)}`;
  }
}

function formatBytes(bytes: number): string {
  if (bytes < 1024) {
    return `${bytes} B`;
  }
  if (bytes < 1024 * 1024) {
    return `${(bytes / 1024).toFixed(1)} KiB`;
  }
  return `${(bytes / (1024 * 1024)).toFixed(1)} MiB`;
}

function formatTimestamp(value: string): string {
  const parsed = new Date(value);
  return Number.isNaN(parsed.valueOf())
    ? "Unknown"
    : parsed.toLocaleString(undefined, {
        dateStyle: "medium",
        timeStyle: "short",
      });
}

function remainingAccessTime(expiresAt: string | null, now: number): string {
  if (!expiresAt) {
    return "Expiry unavailable";
  }

  const remainingMilliseconds = Date.parse(expiresAt) - now;
  if (!Number.isFinite(remainingMilliseconds) || remainingMilliseconds <= 0) {
    return "Access expired";
  }

  const totalMinutes = Math.ceil(remainingMilliseconds / 60_000);
  const hours = Math.floor(totalMinutes / 60);
  const minutes = totalMinutes % 60;

  if (hours === 0) {
    return `${minutes} ${minutes === 1 ? "minute" : "minutes"} remaining`;
  }
  if (minutes === 0) {
    return `${hours} ${hours === 1 ? "hour" : "hours"} remaining`;
  }
  return `${hours} ${hours === 1 ? "hour" : "hours"} ${minutes} ${
    minutes === 1 ? "minute" : "minutes"
  } remaining`;
}

function progressText(progress: AssetProgress): string | null {
  if (!progress) {
    return null;
  }

  switch (progress.kind) {
    case "bytes":
      return `${progress.sent} of ${progress.total} bytes`;
    case "waiting_for_unlock":
      return "Waiting for vault unlock";
    case "indeterminate":
      return "In progress";
    case "complete":
      return "Complete";
  }
}

function uploadResultText(result: UploadAttemptResult): string {
  if (result.ok) {
    return "Upload complete";
  }

  switch (result.reason) {
    case "cancelled":
      return "Upload cancelled";
    case "expired":
      return "Upload grant expired. Try again.";
    case "grant":
      return "Upload could not be authorized.";
    case "network":
      return "Upload interrupted by a network error.";
    case "reused":
      return "This upload attempt has already finished.";
    case "server":
      return "The server could not accept the upload.";
    case "unsafe_target":
      return "The upload destination was rejected.";
  }
}

function validateFile(file: File, maxBytes: number, acceptedTypes: string[]): string | null {
  if (file.size > maxBytes) {
    return `File exceeds the ${formatBytes(maxBytes)} upload limit.`;
  }
  if (!acceptedTypes.includes(file.type)) {
    return "Choose a PDF, JPEG, or PNG file.";
  }
  return null;
}

function AssetProgressLine({ asset }: { asset: AssetSummary }) {
  const text = progressText(asset.progress);
  if (!text) {
    return null;
  }

  if (asset.progress?.kind === "bytes") {
    return (
      <div className="asset-progress">
        <progress
          aria-label={`${asset.title} upload progress`}
          max={asset.progress.total}
          value={asset.progress.sent}
        />
        <span>{text}</span>
      </div>
    );
  }

  return <p className="asset-progress-note">{text}</p>;
}

export function AssetWorkspace({
  bridge,
  store,
  uploadAttemptFactory = createUploadAttempt,
}: AssetWorkspaceProps) {
  const snapshot = useSyncExternalStore(store.subscribe, store.getSnapshot, store.getSnapshot);
  const [query, setQuery] = useState(snapshot.filters.q);
  const [stateFilter, setStateFilter] = useState<AssetState | "">(
    snapshot.filters.state === "deleted" ? "" : (snapshot.filters.state ?? ""),
  );
  const [mediaType, setMediaType] = useState(snapshot.filters.mediaType ?? "");
  const [selectedAssetId, setSelectedAssetId] = useState<string | null>(null);
  const [selectedFile, setSelectedFile] = useState<File | null>(null);
  const [uploadProgress, setUploadProgress] = useState<AssetProgress>(null);
  const [uploadMessage, setUploadMessage] = useState("");
  const [uploading, setUploading] = useState(false);
  const [listOperation, setListOperation] = useState<"search" | "page" | null>(null);
  const [mutationOperation, setMutationOperation] = useState<"retry" | "delete" | null>(null);
  const [listNotice, setListNotice] = useState<Notice | null>(null);
  const [resultsStale, setResultsStale] = useState(false);
  const [actionNotice, setActionNotice] = useState<Notice | null>(null);
  const [theme, setTheme] = useState<Theme>(() => readTheme());
  const [currentTime, setCurrentTime] = useState(() => Date.now());
  const workbenchRef = useRef<HTMLElement>(null);
  const assetListHeadingRef = useRef<HTMLHeadingElement>(null);
  const queryInputRef = useRef<HTMLInputElement>(null);
  const inspectorTriggerRef = useRef<HTMLButtonElement | null>(null);
  const inspectorWasOpenRef = useRef(false);
  const listOperationRef = useRef<"search" | "page" | null>(null);
  const mutationOperationRef = useRef<"retry" | "delete" | null>(null);
  const uploadInputRef = useRef<HTMLInputElement>(null);
  const uploadAttemptRef = useRef<UploadAttempt | null>(null);
  const uploadIdempotencyKeyRef = useRef<string | null>(null);

  const visibleAssets = snapshot.assets.items;
  const selectedAsset = visibleAssets.find(({ id }) => id === selectedAssetId) ?? null;
  const selectedAssetDeletionStarted =
    selectedAsset?.state === "pending_delete" || selectedAsset?.state === "deleted";
  const expiresAt = snapshot.vault.expiresAt ? Date.parse(snapshot.vault.expiresAt) : null;
  const accessExpired =
    expiresAt !== null && Number.isFinite(expiresAt) && expiresAt <= currentTime;
  const locallyLocked = snapshot.vault.locked || accessExpired;
  const selectedAssetDownloadable =
    selectedAsset !== null &&
    !locallyLocked &&
    (selectedAsset.state === "available" ||
      selectedAsset.state === "processing" ||
      selectedAsset.state === "ready");

  useEffect(() => {
    applyTheme(theme);
  }, [theme]);

  useEffect(() => {
    setQuery(snapshot.filters.q);
    setStateFilter(snapshot.filters.state === "deleted" ? "" : (snapshot.filters.state ?? ""));
    setMediaType(snapshot.filters.mediaType ?? "");
    setResultsStale(false);
  }, [snapshot.filters]);

  useEffect(() => {
    if (selectedAsset) {
      inspectorWasOpenRef.current = true;
      return;
    }

    if (inspectorWasOpenRef.current) {
      inspectorWasOpenRef.current = false;
      setSelectedAssetId(null);
      queueMicrotask(() => {
        const trigger = inspectorTriggerRef.current;
        if (trigger?.isConnected) {
          trigger.focus();
          return;
        }

        const nextAsset = workbenchRef.current?.querySelector<HTMLButtonElement>(".asset-inspect");
        (nextAsset ?? assetListHeadingRef.current)?.focus();
      });
    }
  }, [selectedAsset?.id]);

  useEffect(() => {
    setCurrentTime(Date.now());
    if (!snapshot.vault.expiresAt) {
      return;
    }

    const interval = window.setInterval(() => setCurrentTime(Date.now()), 30_000);
    return () => window.clearInterval(interval);
  }, [snapshot.vault.expiresAt]);

  useEffect(() => {
    if (locallyLocked) {
      uploadAttemptRef.current?.abort();
    }
  }, [locallyLocked]);

  useEffect(
    () => () => {
      uploadAttemptRef.current?.abort();
    },
    [],
  );

  function closeInspector(): void {
    setSelectedAssetId(null);
  }

  async function search(event: FormEvent<HTMLFormElement>): Promise<void> {
    event.preventDefault();
    if (listOperationRef.current) {
      return;
    }

    listOperationRef.current = "search";
    setListOperation("search");
    setListNotice(null);

    try {
      const reply = await bridge.search({
        version: 1,
        q: (queryInputRef.current?.value ?? query).trim(),
        state: stateFilter || null,
        mediaType: mediaType || null,
      });

      if (reply.ok) {
        setResultsStale(false);
        setListNotice({ tone: "info", text: "Search results updated." });
      } else {
        setResultsStale(true);
        setListNotice({
          tone: "error",
          text: `Search failed. Showing previous results; they may not match the requested filters. ${stableFailureMessage(
            reply.error.code,
          )}`,
        });
      }
    } catch {
      setResultsStale(true);
      setListNotice({
        tone: "error",
        text: `Search failed. Showing previous results; they may not match the requested filters. ${stableFailureMessage(
          "invalid",
        )}`,
      });
    } finally {
      listOperationRef.current = null;
      setListOperation(null);
    }
  }

  async function loadMore(): Promise<void> {
    const { nextCursor } = snapshot.assets;
    if (!nextCursor || resultsStale || listOperationRef.current) {
      return;
    }

    listOperationRef.current = "page";
    setListOperation("page");
    setListNotice(null);

    try {
      const reply = await bridge.page({
        version: 1,
        cursor: nextCursor,
        q: snapshot.filters.q,
        state: snapshot.filters.state === "deleted" ? null : snapshot.filters.state,
        mediaType: snapshot.filters.mediaType,
      });

      setListNotice(
        reply.ok
          ? { tone: "info", text: "Additional assets loaded." }
          : {
              tone: "error",
              text: `Could not load more assets. ${stableFailureMessage(reply.error.code)}`,
            },
      );
    } catch {
      setListNotice({
        tone: "error",
        text: `Could not load more assets. ${stableFailureMessage("invalid")}`,
      });
    } finally {
      listOperationRef.current = null;
      setListOperation(null);
    }
  }

  function chooseFile(event: ChangeEvent<HTMLInputElement>): void {
    const file = event.currentTarget.files?.[0] ?? null;
    uploadIdempotencyKeyRef.current = file ? uniqueIdempotencyKey() : null;
    setSelectedFile(file);
    setUploadProgress(null);
    setUploadMessage(
      file
        ? (validateFile(file, snapshot.upload.maxBytes, snapshot.upload.acceptedTypes) ?? "")
        : "",
    );
  }

  async function startUpload(): Promise<void> {
    if (!selectedFile || locallyLocked || uploading) {
      return;
    }

    const validation = validateFile(
      selectedFile,
      snapshot.upload.maxBytes,
      snapshot.upload.acceptedTypes,
    );
    if (validation) {
      setUploadMessage(validation);
      return;
    }

    const attempt = uploadAttemptFactory({
      bridge,
      file: selectedFile,
      csrfToken: readCsrfToken(),
      idempotencyKey:
        uploadIdempotencyKeyRef.current ??
        (uploadIdempotencyKeyRef.current = uniqueIdempotencyKey()),
      onProgress: setUploadProgress,
    });
    uploadAttemptRef.current = attempt;
    setUploading(true);
    setUploadProgress(null);
    setUploadMessage("Upload in progress");

    const result = await attempt.start();
    if (uploadAttemptRef.current === attempt) {
      uploadAttemptRef.current = null;
      setUploading(false);
      setUploadMessage(uploadResultText(result));
      if (result.ok) {
        uploadIdempotencyKeyRef.current = null;
        setSelectedFile(null);
        if (uploadInputRef.current) {
          uploadInputRef.current.value = "";
        }
      }
    }
  }

  function cancelUpload(): void {
    uploadAttemptRef.current?.abort();
  }

  async function retrySelected(): Promise<void> {
    if (
      !selectedAsset ||
      selectedAssetDeletionStarted ||
      locallyLocked ||
      !canRetry(selectedAsset) ||
      mutationOperationRef.current
    ) {
      return;
    }

    mutationOperationRef.current = "retry";
    setMutationOperation("retry");
    setActionNotice(null);

    try {
      const reply = await bridge.retry({
        version: 1,
        assetId: selectedAsset.id,
        stateRevision: selectedAsset.stateRevision,
      });

      setActionNotice(
        !reply.ok
          ? {
              tone: "error",
              text: `Retry failed. ${stableFailureMessage(reply.error.code)}`,
            }
          : reply.accepted
            ? { tone: "info", text: "Retry requested." }
            : {
                tone: "error",
                text: "Retry was not accepted. The asset may have changed.",
              },
      );
    } catch {
      setActionNotice({
        tone: "error",
        text: `Retry failed. ${stableFailureMessage("invalid")}`,
      });
    } finally {
      mutationOperationRef.current = null;
      setMutationOperation(null);
    }
  }

  async function deleteSelected(): Promise<void> {
    if (
      !selectedAsset ||
      selectedAssetDeletionStarted ||
      locallyLocked ||
      mutationOperationRef.current
    ) {
      return;
    }

    mutationOperationRef.current = "delete";
    setMutationOperation("delete");
    setActionNotice(null);

    try {
      const reply = await bridge.delete({
        version: 1,
        assetId: selectedAsset.id,
        stateRevision: selectedAsset.stateRevision,
      });

      setActionNotice(
        !reply.ok
          ? {
              tone: "error",
              text: `Delete failed. ${stableFailureMessage(reply.error.code)}`,
            }
          : reply.accepted
            ? { tone: "info", text: "Delete requested." }
            : {
                tone: "error",
                text: "Delete was not accepted. The asset may have changed.",
              },
      );
    } catch {
      setActionNotice({
        tone: "error",
        text: `Delete failed. ${stableFailureMessage("invalid")}`,
      });
    } finally {
      mutationOperationRef.current = null;
      setMutationOperation(null);
    }
  }

  return (
    <section
      ref={workbenchRef}
      className="workbench"
      aria-labelledby="asset-workspace-title"
      onKeyDown={(event) => {
        if (selectedAsset && event.key === "Escape") {
          event.preventDefault();
          closeInspector();
        }
      }}
    >
      <header className="workbench-header">
        <div>
          <p className="eyebrow">Encrypted archive · {snapshot.vault.ref}</p>
          <h1 id="asset-workspace-title">Vault assets</h1>
          <p className="workbench-intro">
            Search, inspect, and move durable records through their archival lifecycle.
          </p>
        </div>
        <div className="workbench-status">
          <div className="vault-session">
            <span className={`vault-state ${locallyLocked ? "is-locked" : ""}`}>
              <span aria-hidden="true" className="status-dot" />
              {locallyLocked ? "Vault locked" : "Vault unlocked"}
            </span>
            <span
              className="vault-expiry"
              role="timer"
              aria-label="Vault access time remaining"
              aria-live="polite"
            >
              {remainingAccessTime(snapshot.vault.expiresAt, currentTime)}
            </span>
          </div>
          <button
            className="button button-quiet theme-toggle"
            type="button"
            aria-label={`Switch to ${theme === "light" ? "dark" : "light"} theme`}
            onClick={() => setTheme(theme === "light" ? "dark" : "light")}
          >
            {theme === "light" ? "Dark" : "Light"} mode
          </button>
        </div>
      </header>

      <section className="control-deck" aria-labelledby="find-assets-title">
        <div className="section-heading">
          <div>
            <p className="section-index">01 · Catalogue</p>
            <h2 id="find-assets-title">Find assets</h2>
          </div>
          <span className="result-count">{visibleAssets.length} shown</span>
        </div>

        <form className="search-rack" role="search" onSubmit={(event) => void search(event)}>
          <label className="field field-query">
            <span>Title or original filename</span>
            <input
              ref={queryInputRef}
              type="search"
              aria-label="Search vault assets"
              value={query}
              onInput={(event) => setQuery(event.currentTarget.value)}
              placeholder="Find a record"
            />
          </label>
          <label className="field">
            <span>Lifecycle</span>
            <select
              aria-label="Filter by lifecycle state"
              value={stateFilter}
              onChange={(event) => setStateFilter(event.currentTarget.value as AssetState | "")}
            >
              <option value="">All states</option>
              {assetStates.map((option) => (
                <option key={option.value} value={option.value}>
                  {option.label}
                </option>
              ))}
            </select>
          </label>
          <label className="field">
            <span>Media</span>
            <select
              aria-label="Filter by media type"
              value={mediaType}
              onChange={(event) => setMediaType(event.currentTarget.value)}
            >
              <option value="">All media</option>
              {mediaTypes.map((option) => (
                <option key={option.value} value={option.value}>
                  {option.label}
                </option>
              ))}
            </select>
          </label>
          <button
            className="button button-primary search-submit"
            type="submit"
            disabled={listOperation !== null}
          >
            {listOperation === "search" ? "Searching" : "Search"}
          </button>
        </form>
        {listNotice ? (
          <p
            className={`operation-notice ${listNotice.tone === "error" ? "is-error" : ""}`}
            aria-label="Asset list status"
            role={listNotice.tone === "error" ? "alert" : "status"}
          >
            {listNotice.text}
          </p>
        ) : null}
      </section>

      <div className="workspace-grid">
        <section className="asset-catalogue" aria-labelledby="asset-list-title">
          <div className="section-heading">
            <div>
              <p className="section-index">02 · Inventory</p>
              <h2 ref={assetListHeadingRef} id="asset-list-title" tabIndex={-1}>
                Asset register
              </h2>
            </div>
          </div>

          {visibleAssets.length === 0 ? (
            <p className="empty-state">No assets match the current catalogue filters.</p>
          ) : (
            <ul className="asset-list">
              {visibleAssets.map((item) => {
                const label = visibleLabel(item);
                const failed = item.failure !== null;

                return (
                  <li className="asset-row" key={item.id}>
                    <button
                      type="button"
                      className="asset-inspect"
                      aria-label={`Inspect ${item.title}`}
                      onClick={(event) => {
                        inspectorTriggerRef.current = event.currentTarget;
                        setSelectedAssetId(item.id);
                      }}
                    >
                      <span className="asset-title">{item.title}</span>
                      <span className="asset-file">{item.originalFilename}</span>
                    </button>
                    <div className="asset-meta">
                      <span className={`lifecycle ${failed ? "is-failed" : ""}`}>{label}</span>
                      <span>{item.detectedMediaType ?? "Type pending"}</span>
                      <span>r{item.stateRevision}</span>
                    </div>
                    <AssetProgressLine asset={item} />
                  </li>
                );
              })}
            </ul>
          )}

          {snapshot.assets.nextCursor ? (
            <button
              className="button button-secondary load-more"
              type="button"
              disabled={resultsStale || listOperation !== null}
              onClick={loadMore}
            >
              {listOperation === "page" ? "Loading assets" : "Load more assets"}
            </button>
          ) : null}
        </section>

        <section className="upload-station" aria-labelledby="upload-title">
          <div className="section-heading">
            <div>
              <p className="section-index">03 · Intake</p>
              <h2 id="upload-title">Upload asset</h2>
            </div>
          </div>
          <p className="upload-guidance">
            PDF, JPEG, or PNG · up to {formatBytes(snapshot.upload.maxBytes)}
          </p>
          <label className="file-picker">
            <span>Choose archive file</span>
            <input
              ref={uploadInputRef}
              type="file"
              aria-label="Choose a file to upload"
              accept={snapshot.upload.acceptedTypes.join(",")}
              disabled={locallyLocked || uploading}
              onChange={chooseFile}
            />
          </label>
          {selectedFile ? (
            <p className="selected-file">
              <span>{selectedFile.name}</span>
              <span>{formatBytes(selectedFile.size)}</span>
            </p>
          ) : null}
          {uploadProgress?.kind === "bytes" ? (
            <div className="upload-progress">
              <progress
                aria-label="Upload progress"
                max={uploadProgress.total}
                value={uploadProgress.sent}
              />
              <span>
                {uploadProgress.sent} of {uploadProgress.total} bytes
              </span>
            </div>
          ) : null}
          <div className="upload-actions">
            <button
              className="button button-primary"
              type="button"
              disabled={!selectedFile || locallyLocked || uploading}
              onClick={() => void startUpload()}
            >
              Upload asset
            </button>
            {uploading ? (
              <button className="button button-danger" type="button" onClick={cancelUpload}>
                Cancel upload
              </button>
            ) : null}
          </div>
          <p className="upload-result" aria-live="polite">
            {locallyLocked ? "Unlock the vault before uploading." : uploadMessage}
          </p>
        </section>
      </div>

      {actionNotice ? (
        <p
          className={`operation-notice action-notice ${
            actionNotice.tone === "error" ? "is-error" : ""
          }`}
          aria-label="Asset action status"
          role={actionNotice.tone === "error" ? "alert" : "status"}
        >
          {actionNotice.text}
        </p>
      ) : null}

      {selectedAsset ? (
        <aside className="asset-inspector" aria-label="Asset inspector">
          <div className="inspector-heading">
            <div>
              <p className="section-index">Asset detail</p>
              <h2>{selectedAsset.title}</h2>
            </div>
            <button
              className="button button-quiet"
              type="button"
              aria-label="Close asset inspector"
              onClick={closeInspector}
            >
              Close
            </button>
          </div>
          <p className={`inspector-state ${selectedAsset.failure ? "is-failed" : ""}`}>
            {visibleLabel(selectedAsset)}
          </p>
          <dl className="asset-details">
            <div>
              <dt>Original file</dt>
              <dd>{selectedAsset.originalFilename}</dd>
            </div>
            <div>
              <dt>Media type</dt>
              <dd>{selectedAsset.detectedMediaType ?? "Detection pending"}</dd>
            </div>
            <div>
              <dt>Updated</dt>
              <dd>{formatTimestamp(selectedAsset.updatedAt)}</dd>
            </div>
            <div>
              <dt>State revision</dt>
              <dd>{selectedAsset.stateRevision}</dd>
            </div>
          </dl>
          {selectedAsset.failure ? (
            <p className="inspector-note">
              {stableFailureMessage(selectedAsset.failure.code)} Attempt{" "}
              {selectedAsset.failure.attempt}.
            </p>
          ) : null}
          <div className="inspector-actions">
            {selectedAssetDownloadable ? (
              <a
                className="button button-secondary"
                aria-label={`Download ${selectedAsset.title}`}
                href={`/api/v1/assets/${encodeURIComponent(selectedAsset.id)}/content`}
                download={selectedAsset.originalFilename}
              >
                Download
              </a>
            ) : null}
            <button
              className="button button-secondary"
              type="button"
              disabled={
                selectedAssetDeletionStarted ||
                locallyLocked ||
                !canRetry(selectedAsset) ||
                mutationOperation !== null
              }
              onClick={() => void retrySelected()}
            >
              Retry
            </button>
            <button
              className="button button-danger"
              type="button"
              disabled={selectedAssetDeletionStarted || locallyLocked || mutationOperation !== null}
              onClick={() => void deleteSelected()}
            >
              Delete
            </button>
          </div>
        </aside>
      ) : null}
    </section>
  );
}
