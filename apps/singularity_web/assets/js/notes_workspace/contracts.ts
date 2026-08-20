export type FailureReply = {
  ok: false;
  error: {
    code:
      | "invalid"
      | "storage_unavailable"
      | "unauthenticated"
      | "vault_locked"
      | "forbidden"
      | "not_found"
      | "conflict";
  };
};

export type NoteSummary = {
  resourceId: string;
  resourceVersionId: string;
  title: string;
  revision: number;
  displayVersion: number;
  updatedAt: string;
  deleted: boolean;
  openConflictCount: number;
};
export type Note = NoteSummary & { markdown: string };
export type NoteVersionSummary = {
  resourceVersionId: string;
  revision: number;
  displayVersion: number;
  createdByPrincipalId: string;
  insertedAt: string;
  parentVersionId: string | null;
  mergeParentVersionId: string | null;
  canonical: boolean;
  conflictState: "open" | "resolved" | null;
};
export type NoteVersion = NoteVersionSummary & {
  resourceId: string;
  title: string;
  markdown: string;
};
export type NoteConflictDetail = {
  conflictId: string;
  baseVersionId: string;
  observedCanonicalVersionId: string;
  current: NoteVersion;
  competing: NoteVersion;
};
export type NoteSaveResult = {
  outcome: "saved" | "conflict";
  canonical: Note;
  submittedVersionId: string;
  conflictId: string | null;
};
export type NotePage = { items: NoteSummary[]; nextCursor: string | null };
export type NoteTrashPage = {
  items: { summary: NoteSummary; deletedAt: string }[];
  nextCursor: string | null;
};
export type NoteHistoryPage = { items: NoteVersionSummary[]; nextCursor: string | null };
export type InitialProps = {
  version: 1;
  vault: { ref: string; expiresAt: string | null };
  filters: { q: string };
  summaries: NoteSummary[];
};

export type SearchRequest = { version: 1; q: string; cursor: string | null; limit: number };
export type TrashRequest = { version: 1; cursor: string | null; limit: number };
export type OpenRequest = { version: 1; resourceId: string; resourceVersionId: string | null };
export type CreateRequest = { version: 1; mutationId: string; title: string; markdown: string };
export type SaveRequest = {
  version: 1;
  mutationId: string;
  resourceId: string;
  baseVersionId: string;
  title: string;
  markdown: string;
};
export type HistoryRequest = {
  version: 1;
  resourceId: string;
  cursor: string | null;
  limit: number;
};
export type ConflictRequest = { version: 1; resourceId: string; conflictId: string };
export type MergeRequest = {
  version: 1;
  mutationId: string;
  resourceId: string;
  conflictId: string;
  expectedCurrentVersionId: string;
  competingVersionId: string;
  title: string;
  markdown: string;
};
export type DeleteRequest = {
  version: 1;
  mutationId: string;
  resourceId: string;
  expectedCurrentVersionId: string;
};
export type RestoreRequest = { version: 1; mutationId: string; resourceId: string };
export type NavigationTarget =
  | "/assets"
  | "/notes"
  | "/activity"
  | "/audit"
  | "/backups"
  | "/settings";
export type NavigationRequest = { version: 1; to: NavigationTarget };

export type ResultReply<T> = { ok: true; result: T } | FailureReply;
export type DeleteReply = { ok: true; accepted: boolean } | FailureReply;
export type NavigationReply = { ok: true } | FailureReply;

export type NotesBridge = {
  search(request: SearchRequest): Promise<ResultReply<NotePage>>;
  trash(request: TrashRequest): Promise<ResultReply<NoteTrashPage>>;
  open(request: OpenRequest): Promise<ResultReply<Note | NoteVersion>>;
  create(request: CreateRequest): Promise<ResultReply<Note>>;
  save(request: SaveRequest): Promise<ResultReply<NoteSaveResult>>;
  history(request: HistoryRequest): Promise<ResultReply<NoteHistoryPage>>;
  conflict(request: ConflictRequest): Promise<ResultReply<NoteConflictDetail>>;
  merge(request: MergeRequest): Promise<ResultReply<NoteSaveResult>>;
  delete(request: DeleteRequest): Promise<DeleteReply>;
  restore(request: RestoreRequest): Promise<ResultReply<Note>>;
  navigate(to: NavigationTarget): Promise<NavigationReply>;
};

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const navigation = new Set<NavigationTarget>([
  "/assets",
  "/notes",
  "/activity",
  "/audit",
  "/backups",
  "/settings",
]);
const failures = new Set([
  "invalid",
  "storage_unavailable",
  "unauthenticated",
  "vault_locked",
  "forbidden",
  "not_found",
  "conflict",
]);
const invalid = (): FailureReply => ({ ok: false, error: { code: "invalid" } });
export const unavailable = (): FailureReply => ({
  ok: false,
  error: { code: "storage_unavailable" },
});

function record(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
function exact(value: Record<string, unknown>, keys: readonly string[]): boolean {
  const actual = Object.keys(value);
  return (
    actual.length === keys.length &&
    keys.every((key) => Object.prototype.hasOwnProperty.call(value, key))
  );
}
function id(value: unknown): value is string {
  return typeof value === "string" && uuid.test(value);
}
function integer(value: unknown, minimum = 0): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= minimum;
}
function safeText(value: unknown, max: number, blank = true): value is string {
  return (
    typeof value === "string" &&
    new TextEncoder().encode(value).length <= max &&
    !value.includes("\0") &&
    (blank || value.trim() !== "")
  );
}
function cursor(value: unknown): value is string | null {
  return value === null || safeText(value, 2048, false);
}
function utc(value: unknown): value is string {
  if (typeof value !== "string") return false;
  const match = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d{1,6})?Z$/.exec(value);
  if (!match) return false;
  const parsed = new Date(value);
  return (
    !Number.isNaN(parsed.valueOf()) &&
    parsed.getUTCFullYear() === Number(match[1]) &&
    parsed.getUTCMonth() + 1 === Number(match[2]) &&
    parsed.getUTCDate() === Number(match[3]) &&
    parsed.getUTCHours() === Number(match[4]) &&
    parsed.getUTCMinutes() === Number(match[5]) &&
    parsed.getUTCSeconds() === Number(match[6])
  );
}
function nullableId(value: unknown): value is string | null {
  return value === null || id(value);
}

function failure(value: unknown): FailureReply | null {
  if (
    !record(value) ||
    !exact(value, ["ok", "error"]) ||
    value.ok !== false ||
    !record(value.error) ||
    !exact(value.error, ["code"]) ||
    typeof value.error.code !== "string"
  )
    return null;
  return failures.has(value.error.code) ? (value as FailureReply) : unavailable();
}

function summary(value: unknown): value is NoteSummary {
  return (
    record(value) &&
    exact(value, [
      "resourceId",
      "resourceVersionId",
      "title",
      "revision",
      "displayVersion",
      "updatedAt",
      "deleted",
      "openConflictCount",
    ]) &&
    id(value.resourceId) &&
    id(value.resourceVersionId) &&
    safeText(value.title, 255, false) &&
    integer(value.revision) &&
    value.displayVersion === value.revision + 1 &&
    utc(value.updatedAt) &&
    typeof value.deleted === "boolean" &&
    integer(value.openConflictCount)
  );
}

function liveSummary(value: unknown): value is NoteSummary {
  return summary(value) && value.deleted === false;
}

function note(value: unknown): value is Note {
  return (
    record(value) &&
    exact(value, [
      "resourceId",
      "resourceVersionId",
      "title",
      "revision",
      "displayVersion",
      "updatedAt",
      "deleted",
      "openConflictCount",
      "markdown",
    ]) &&
    summary(Object.fromEntries(Object.entries(value).filter(([key]) => key !== "markdown"))) &&
    value.deleted === false &&
    safeText(value.markdown, 1_048_576)
  );
}
function versionSummary(value: unknown): value is NoteVersionSummary {
  return (
    record(value) &&
    exact(value, [
      "resourceVersionId",
      "revision",
      "displayVersion",
      "createdByPrincipalId",
      "insertedAt",
      "parentVersionId",
      "mergeParentVersionId",
      "canonical",
      "conflictState",
    ]) &&
    id(value.resourceVersionId) &&
    integer(value.revision) &&
    value.displayVersion === value.revision + 1 &&
    id(value.createdByPrincipalId) &&
    utc(value.insertedAt) &&
    nullableId(value.parentVersionId) &&
    nullableId(value.mergeParentVersionId) &&
    typeof value.canonical === "boolean" &&
    (value.conflictState === null ||
      value.conflictState === "open" ||
      value.conflictState === "resolved") &&
    !(value.canonical && value.conflictState !== null) &&
    (value.revision === 0
      ? value.parentVersionId === null && value.mergeParentVersionId === null
      : value.parentVersionId !== null) &&
    (value.mergeParentVersionId === null || value.mergeParentVersionId !== value.parentVersionId)
  );
}
function version(value: unknown): value is NoteVersion {
  return (
    record(value) &&
    exact(value, [
      "resourceVersionId",
      "revision",
      "displayVersion",
      "createdByPrincipalId",
      "insertedAt",
      "parentVersionId",
      "mergeParentVersionId",
      "canonical",
      "conflictState",
      "resourceId",
      "title",
      "markdown",
    ]) &&
    versionSummary(
      Object.fromEntries(
        Object.entries(value).filter(([key]) => !["resourceId", "title", "markdown"].includes(key)),
      ),
    ) &&
    id(value.resourceId) &&
    safeText(value.title, 255, false) &&
    safeText(value.markdown, 1_048_576)
  );
}
function page(value: unknown): value is NotePage {
  return (
    record(value) &&
    exact(value, ["items", "nextCursor"]) &&
    Array.isArray(value.items) &&
    value.items.length <= 50 &&
    value.items.every(liveSummary) &&
    cursor(value.nextCursor)
  );
}
function trashPage(value: unknown): value is NoteTrashPage {
  return (
    record(value) &&
    exact(value, ["items", "nextCursor"]) &&
    Array.isArray(value.items) &&
    value.items.length <= 50 &&
    value.items.every(
      (item) =>
        record(item) &&
        exact(item, ["summary", "deletedAt"]) &&
        summary(item.summary) &&
        item.summary.deleted === true &&
        utc(item.deletedAt),
    ) &&
    cursor(value.nextCursor)
  );
}
function historyPage(value: unknown): value is NoteHistoryPage {
  return (
    record(value) &&
    exact(value, ["items", "nextCursor"]) &&
    Array.isArray(value.items) &&
    value.items.length <= 50 &&
    value.items.every(versionSummary) &&
    cursor(value.nextCursor)
  );
}
function saveResult(value: unknown): value is NoteSaveResult {
  if (
    !record(value) ||
    !exact(value, ["outcome", "canonical", "submittedVersionId", "conflictId"]) ||
    !note(value.canonical) ||
    !id(value.submittedVersionId) ||
    !nullableId(value.conflictId)
  )
    return false;
  return value.outcome === "saved"
    ? value.conflictId === null && value.submittedVersionId === value.canonical.resourceVersionId
    : value.outcome === "conflict" &&
        value.conflictId !== null &&
        value.submittedVersionId !== value.canonical.resourceVersionId;
}
function conflictDetail(value: unknown): value is NoteConflictDetail {
  return (
    record(value) &&
    exact(value, [
      "conflictId",
      "baseVersionId",
      "observedCanonicalVersionId",
      "current",
      "competing",
    ]) &&
    id(value.conflictId) &&
    id(value.baseVersionId) &&
    id(value.observedCanonicalVersionId) &&
    version(value.current) &&
    version(value.competing) &&
    value.current.resourceId === value.competing.resourceId &&
    value.current.canonical &&
    !value.competing.canonical &&
    value.competing.conflictState !== null &&
    value.current.resourceVersionId !== value.competing.resourceVersionId &&
    value.baseVersionId !== value.observedCanonicalVersionId &&
    value.baseVersionId !== value.competing.resourceVersionId &&
    value.observedCanonicalVersionId !== value.competing.resourceVersionId
  );
}

export function decodeInitialProps(value: unknown): InitialProps | null {
  return record(value) &&
    exact(value, ["version", "vault", "filters", "summaries"]) &&
    value.version === 1 &&
    record(value.vault) &&
    exact(value.vault, ["ref", "expiresAt"]) &&
    id(value.vault.ref) &&
    (value.vault.expiresAt === null || utc(value.vault.expiresAt)) &&
    record(value.filters) &&
    exact(value.filters, ["q"]) &&
    safeText(value.filters.q, 1024) &&
    Array.isArray(value.summaries) &&
    value.summaries.length <= 50 &&
    value.summaries.every(liveSummary)
    ? (value as InitialProps)
    : null;
}

type Decoder<T> = (value: unknown) => T | null;
function request<T>(
  value: unknown,
  keys: string[],
  validate: (value: Record<string, unknown>) => boolean,
): T | null {
  return record(value) && exact(value, keys) && value.version === 1 && validate(value)
    ? (value as T)
    : null;
}
export const decodeSearchRequest: Decoder<SearchRequest> = (v) =>
  request(
    v,
    ["version", "q", "cursor", "limit"],
    (x) =>
      safeText(x.q, 1024) && cursor(x.cursor) && integer(x.limit, 1) && (x.limit as number) <= 50,
  );
export const decodeTrashRequest: Decoder<TrashRequest> = (v) =>
  request(
    v,
    ["version", "cursor", "limit"],
    (x) => cursor(x.cursor) && integer(x.limit, 1) && (x.limit as number) <= 50,
  );
export const decodeOpenRequest: Decoder<OpenRequest> = (v) =>
  request(
    v,
    ["version", "resourceId", "resourceVersionId"],
    (x) => id(x.resourceId) && nullableId(x.resourceVersionId),
  );
export const decodeCreateRequest: Decoder<CreateRequest> = (v) =>
  request(
    v,
    ["version", "mutationId", "title", "markdown"],
    (x) => id(x.mutationId) && safeText(x.title, 255, false) && safeText(x.markdown, 1_048_576),
  );
export const decodeSaveRequest: Decoder<SaveRequest> = (v) =>
  request(
    v,
    ["version", "mutationId", "resourceId", "baseVersionId", "title", "markdown"],
    (x) =>
      id(x.mutationId) &&
      id(x.resourceId) &&
      id(x.baseVersionId) &&
      safeText(x.title, 255, false) &&
      safeText(x.markdown, 1_048_576),
  );
export const decodeHistoryRequest: Decoder<HistoryRequest> = (v) =>
  request(
    v,
    ["version", "resourceId", "cursor", "limit"],
    (x) => id(x.resourceId) && cursor(x.cursor) && integer(x.limit, 1) && (x.limit as number) <= 50,
  );
export const decodeConflictRequest: Decoder<ConflictRequest> = (v) =>
  request(v, ["version", "resourceId", "conflictId"], (x) => id(x.resourceId) && id(x.conflictId));
export const decodeMergeRequest: Decoder<MergeRequest> = (v) =>
  request(
    v,
    [
      "version",
      "mutationId",
      "resourceId",
      "conflictId",
      "expectedCurrentVersionId",
      "competingVersionId",
      "title",
      "markdown",
    ],
    (x) =>
      id(x.mutationId) &&
      id(x.resourceId) &&
      id(x.conflictId) &&
      id(x.expectedCurrentVersionId) &&
      id(x.competingVersionId) &&
      x.expectedCurrentVersionId !== x.competingVersionId &&
      safeText(x.title, 255, false) &&
      safeText(x.markdown, 1_048_576),
  );
export const decodeDeleteRequest: Decoder<DeleteRequest> = (v) =>
  request(
    v,
    ["version", "mutationId", "resourceId", "expectedCurrentVersionId"],
    (x) => id(x.mutationId) && id(x.resourceId) && id(x.expectedCurrentVersionId),
  );
export const decodeRestoreRequest: Decoder<RestoreRequest> = (v) =>
  request(v, ["version", "mutationId", "resourceId"], (x) => id(x.mutationId) && id(x.resourceId));
export const decodeNavigationRequest: Decoder<NavigationRequest> = (v) =>
  request(
    v,
    ["version", "to"],
    (x) => typeof x.to === "string" && navigation.has(x.to as NavigationTarget),
  );

function result<T>(value: unknown, decoder: (value: unknown) => value is T): ResultReply<T> {
  const failed = failure(value);
  if (failed) return failed;
  return record(value) &&
    exact(value, ["ok", "result"]) &&
    value.ok === true &&
    decoder(value.result)
    ? (value as ResultReply<T>)
    : invalid();
}
export const decodeSearchReply = (v: unknown): ResultReply<NotePage> => result(v, page);
export const decodeTrashReply = (v: unknown): ResultReply<NoteTrashPage> => result(v, trashPage);
export const decodeOpenReply = (v: unknown): ResultReply<Note | NoteVersion> =>
  result(v, (x): x is Note | NoteVersion => note(x) || version(x));
export const decodeCreateReply = (v: unknown): ResultReply<Note> => result(v, note);
export const decodeSaveReply = (v: unknown): ResultReply<NoteSaveResult> => result(v, saveResult);
export const decodeHistoryReply = (v: unknown): ResultReply<NoteHistoryPage> =>
  result(v, historyPage);
export const decodeConflictReply = (v: unknown): ResultReply<NoteConflictDetail> =>
  result(v, conflictDetail);
export const decodeMergeReply = decodeSaveReply;
export const decodeRestoreReply = decodeCreateReply;
export function decodeDeleteReply(v: unknown): DeleteReply {
  const failed = failure(v);
  if (failed) return failed;
  return record(v) &&
    exact(v, ["ok", "accepted"]) &&
    v.ok === true &&
    typeof v.accepted === "boolean"
    ? (v as DeleteReply)
    : invalid();
}
export function decodeNavigationReply(v: unknown): NavigationReply {
  const failed = failure(v);
  if (failed) return failed;
  return record(v) && exact(v, ["ok"]) && v.ok === true ? { ok: true } : invalid();
}
