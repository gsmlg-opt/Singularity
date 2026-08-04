export type AssetState =
  | "staging"
  | "uploaded"
  | "verified"
  | "available"
  | "processing"
  | "ready"
  | "pending_delete"
  | "deleted";

export type AssetFailure = null | {
  code: string;
  retryable: boolean;
  operation: string;
  attempt: number;
};

export type AssetProgress =
  | { kind: "bytes"; sent: number; total: number }
  | { kind: "indeterminate" }
  | { kind: "complete" }
  | { kind: "waiting_for_unlock" }
  | null;

export type AssetSummary = {
  id: string;
  resourceVersionId: string;
  title: string;
  originalFilename: string;
  detectedMediaType: string | null;
  state: AssetState;
  stateRevision: number;
  label: string;
  progress: AssetProgress;
  failure: AssetFailure;
  updatedAt: string;
};

export type AssetPage = {
  items: AssetSummary[];
  nextCursor: string | null;
};

export type AssetFilters = {
  q: string;
  state: AssetState | null;
  mediaType: string | null;
};

export type InitialProps = {
  version: 1;
  vault: {
    ref: string;
    locked: boolean;
    expiresAt: string | null;
  };
  assets: AssetPage;
  filters: AssetFilters;
  upload: {
    maxBytes: number;
    acceptedTypes: string[];
  };
};

export type WorkspaceSnapshot = InitialProps & {
  sequence: number;
};

export type UploadGrant = {
  ok: true;
  grantId: string;
  uploadToken: string;
  uploadUrl: string;
  expiresAt: string;
};

export type FailureReply = {
  ok: false;
  error: {
    code: string;
  };
};

export type SearchRequest = {
  version: 1;
  q: string;
  state: AssetState | null;
  mediaType: string | null;
};

export type SearchSuccessReply = {
  ok: true;
  sequence: number;
  filters: AssetFilters;
  assets: AssetPage;
};

export type SearchReply = SearchSuccessReply | FailureReply;

export type PageRequest = SearchRequest & {
  cursor: string;
};

export type PageSuccessReply = {
  ok: true;
  sequence: number;
  assets: AssetPage;
};

export type PageReply = PageSuccessReply | FailureReply;

export type UploadGrantRequest = {
  version: 1;
  filename: string;
  size: number;
  mediaType: string;
  idempotencyKey: string;
};

export type UploadGrantReply = UploadGrant | FailureReply;

export type UploadCancelRequest = {
  version: 1;
  grantId: string;
};

export type AssetMutationRequest = {
  version: 1;
  assetId: string;
  stateRevision: number;
};

export type AssetMutationSuccessReply = {
  ok: true;
  accepted: boolean;
};

export type AssetMutationReply = AssetMutationSuccessReply | FailureReply;

export type NavigationTarget = "/assets" | "/activity" | "/audit" | "/backups" | "/settings";

export type NavigationSuccessReply = {
  ok: true;
};

export type NavigationReply = NavigationSuccessReply | FailureReply;

export type AssetSnapshotEvent = {
  version: 1;
  sequence: number;
  assets: AssetPage;
};

export type AssetUpdateEvent = {
  version: 1;
  sequence: number;
  asset: AssetSummary;
};

export type Bridge = {
  search(request: SearchRequest): Promise<SearchReply>;
  page(request: PageRequest): Promise<PageReply>;
  grant(request: UploadGrantRequest): Promise<UploadGrantReply>;
  cancel(request: UploadCancelRequest): Promise<AssetMutationReply>;
  retry(request: AssetMutationRequest): Promise<AssetMutationReply>;
  delete(request: AssetMutationRequest): Promise<AssetMutationReply>;
  navigate(to: NavigationTarget): Promise<NavigationReply>;
};
