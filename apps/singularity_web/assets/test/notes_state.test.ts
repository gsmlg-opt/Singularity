import { describe, expect, it } from "vitest";

import type {
  InitialProps,
  Note,
  NoteConflictDetail,
  NoteSaveResult,
  NoteVersion,
  NoteVersionSummary,
} from "../js/notes_workspace/contracts";
import {
  decodeConflictReply,
  decodeConflictRequest,
  decodeCreateReply,
  decodeCreateRequest,
  decodeDeleteReply,
  decodeDeleteRequest,
  decodeHistoryReply,
  decodeHistoryRequest,
  decodeInitialProps,
  decodeMergeReply,
  decodeMergeRequest,
  decodeNavigationReply,
  decodeNavigationRequest,
  decodeOpenReply,
  decodeOpenRequest,
  decodeRestoreReply,
  decodeRestoreRequest,
  decodeSaveReply,
  decodeSaveRequest,
  decodeSearchReply,
  decodeSearchRequest,
  decodeTrashReply,
  decodeTrashRequest,
} from "../js/notes_workspace/contracts";
import { WorkspaceStore } from "../js/notes_workspace/state";

const uuid = (suffix: string) => `019f9f65-acde-7a31-bf09-${suffix.padStart(12, "0")}`;

const resourceId = uuid("1");
const canonicalVersionId = uuid("2");
const competingVersionId = uuid("3");
const baseVersionId = uuid("4");
const principalId = uuid("5");
const conflictId = uuid("6");
const mutationId = uuid("7");
const vaultId = uuid("8");
const now = "2026-08-20T12:00:00.000000Z";

const invalidReply = { ok: false, error: { code: "invalid" } } as const;
const unavailableReply = { ok: false, error: { code: "storage_unavailable" } } as const;

function summary(
  overrides: Partial<InitialProps["summaries"][number]> = {},
): InitialProps["summaries"][number] {
  return {
    resourceId,
    resourceVersionId: canonicalVersionId,
    title: "Fixture note",
    revision: 2,
    displayVersion: 3,
    updatedAt: now,
    deleted: false,
    openConflictCount: 1,
    ...overrides,
  };
}

function note(overrides: Partial<Note> = {}): Note {
  return {
    ...summary(),
    markdown: "# canonical markdown",
    ...overrides,
  };
}

function versionSummary(overrides: Partial<NoteVersionSummary> = {}): NoteVersionSummary {
  return {
    resourceVersionId: canonicalVersionId,
    revision: 2,
    displayVersion: 3,
    createdByPrincipalId: principalId,
    insertedAt: now,
    parentVersionId: baseVersionId,
    mergeParentVersionId: null,
    canonical: true,
    conflictState: null,
    ...overrides,
  };
}

function version(overrides: Partial<NoteVersion> = {}): NoteVersion {
  return {
    ...versionSummary(),
    resourceId,
    title: "Fixture note",
    markdown: "# canonical markdown",
    ...overrides,
  };
}

function competingVersion(overrides: Partial<NoteVersion> = {}): NoteVersion {
  return version({
    resourceVersionId: competingVersionId,
    canonical: false,
    conflictState: "open",
    title: "Competing note",
    markdown: "# competing markdown",
    ...overrides,
  });
}

function conflictDetail(overrides: Partial<NoteConflictDetail> = {}): NoteConflictDetail {
  return {
    conflictId,
    baseVersionId,
    observedCanonicalVersionId: canonicalVersionId,
    current: version(),
    competing: competingVersion(),
    ...overrides,
  };
}

function savedResult(overrides: Partial<NoteSaveResult> = {}): NoteSaveResult {
  return {
    outcome: "saved",
    canonical: note(),
    submittedVersionId: canonicalVersionId,
    conflictId: null,
    ...overrides,
  };
}

function preservedConflict(overrides: Partial<NoteSaveResult> = {}): NoteSaveResult {
  return {
    outcome: "conflict",
    canonical: note(),
    submittedVersionId: competingVersionId,
    conflictId,
    ...overrides,
  };
}

function initialProps(overrides: Partial<InitialProps> = {}): InitialProps {
  return {
    version: 1,
    vault: { ref: vaultId },
    filters: { q: "" },
    summaries: [summary()],
    ...overrides,
  };
}

function searchPage(title = "Fixture note", nextCursor: string | null = "search-cursor") {
  return { items: [summary({ title })], nextCursor };
}

function historyPage(
  item: NoteVersionSummary = versionSummary(),
  nextCursor: string | null = "history-cursor",
) {
  return { items: [item], nextCursor };
}

function clone<T>(value: T): T {
  return JSON.parse(JSON.stringify(value)) as T;
}

function withoutFirstKey(value: unknown): unknown {
  const copy = clone(value as Record<string, unknown>);
  const [first] = Object.keys(copy);
  delete copy[first];
  return copy;
}

function withExtraKey(value: unknown): unknown {
  return { ...(clone(value) as Record<string, unknown>), unexpected: "secret-canary" };
}

type Decoder = (value: unknown) => unknown;

const requestCases: Array<{ name: string; decode: Decoder; valid: Record<string, unknown> }> = [
  {
    name: "search",
    decode: decodeSearchRequest,
    valid: { version: 1, q: "fixture", cursor: null, limit: 20 },
  },
  {
    name: "trash",
    decode: decodeTrashRequest,
    valid: { version: 1, cursor: null, limit: 20 },
  },
  {
    name: "open",
    decode: decodeOpenRequest,
    valid: { version: 1, resourceId, resourceVersionId: null },
  },
  {
    name: "create",
    decode: decodeCreateRequest,
    valid: { version: 1, mutationId, title: "Created", markdown: "# Created" },
  },
  {
    name: "save",
    decode: decodeSaveRequest,
    valid: {
      version: 1,
      mutationId,
      resourceId,
      baseVersionId,
      title: "Saved",
      markdown: "# Saved",
    },
  },
  {
    name: "history",
    decode: decodeHistoryRequest,
    valid: { version: 1, resourceId, cursor: null, limit: 20 },
  },
  {
    name: "conflict",
    decode: decodeConflictRequest,
    valid: { version: 1, resourceId, conflictId },
  },
  {
    name: "merge",
    decode: decodeMergeRequest,
    valid: {
      version: 1,
      mutationId,
      resourceId,
      conflictId,
      expectedCurrentVersionId: canonicalVersionId,
      competingVersionId,
      title: "Merged",
      markdown: "# Merged",
    },
  },
  {
    name: "delete",
    decode: decodeDeleteRequest,
    valid: {
      version: 1,
      mutationId,
      resourceId,
      expectedCurrentVersionId: canonicalVersionId,
    },
  },
  {
    name: "restore",
    decode: decodeRestoreRequest,
    valid: { version: 1, mutationId, resourceId },
  },
  {
    name: "navigate",
    decode: decodeNavigationRequest,
    valid: { version: 1, to: "/notes" },
  },
];

const replyCases: Array<{ name: string; decode: Decoder; valid: Record<string, unknown> }> = [
  {
    name: "search",
    decode: decodeSearchReply,
    valid: { ok: true, result: searchPage() },
  },
  {
    name: "trash",
    decode: decodeTrashReply,
    valid: {
      ok: true,
      result: {
        items: [
          {
            summary: summary({ deleted: true }),
            deletedAt: now,
          },
        ],
        nextCursor: null,
      },
    },
  },
  { name: "open", decode: decodeOpenReply, valid: { ok: true, result: note() } },
  { name: "create", decode: decodeCreateReply, valid: { ok: true, result: note() } },
  { name: "save", decode: decodeSaveReply, valid: { ok: true, result: savedResult() } },
  {
    name: "history",
    decode: decodeHistoryReply,
    valid: { ok: true, result: historyPage() },
  },
  {
    name: "conflict",
    decode: decodeConflictReply,
    valid: { ok: true, result: conflictDetail() },
  },
  {
    name: "merge",
    decode: decodeMergeReply,
    valid: { ok: true, result: savedResult() },
  },
  { name: "delete", decode: decodeDeleteReply, valid: { ok: true, accepted: true } },
  { name: "restore", decode: decodeRestoreReply, valid: { ok: true, result: note() } },
  { name: "navigate", decode: decodeNavigationReply, valid: { ok: true } },
];

describe("Notes App-Clip contracts", () => {
  it("decodes the exact Task 13 initial props and every request/reply shape", () => {
    const initial = initialProps();
    expect(decodeInitialProps(initial)).toEqual(initial);

    for (const { decode, valid } of requestCases) {
      expect(decode(valid)).toEqual(valid);
    }

    for (const { decode, valid } of replyCases) {
      expect(decode(valid)).toEqual(valid);
    }

    const exactVersionReply = { ok: true, result: version() };
    expect(decodeOpenReply(exactVersionReply)).toEqual(exactVersionReply);
  });

  it("requires exact top-level keys and version 1 without inventing reply versions", () => {
    expect(decodeInitialProps(withoutFirstKey(initialProps()))).toBeNull();
    expect(decodeInitialProps(withExtraKey(initialProps()))).toBeNull();
    expect(decodeInitialProps({ ...initialProps(), version: 2 })).toBeNull();

    for (const { decode, valid } of requestCases) {
      expect(decode(withoutFirstKey(valid))).toBeNull();
      expect(decode(withExtraKey(valid))).toBeNull();
      expect(decode({ ...valid, version: 2 })).toBeNull();
    }

    for (const { decode, valid } of replyCases) {
      expect(decode(withoutFirstKey(valid))).toEqual(invalidReply);
      expect(decode(withExtraKey(valid))).toEqual(invalidReply);
      expect(decode({ ...valid, version: 1 })).toEqual(invalidReply);
    }
  });

  it("requires exact nested DTO keys and never permits Markdown in summaries", () => {
    expect(
      decodeInitialProps({
        ...initialProps(),
        vault: { ref: vaultId, locked: false },
      }),
    ).toBeNull();
    expect(
      decodeInitialProps({
        ...initialProps(),
        filters: { q: "", classification: "private" },
      }),
    ).toBeNull();
    expect(
      decodeInitialProps({
        ...initialProps(),
        summaries: [{ ...summary(), markdown: "# must not cross summary boundary" }],
      }),
    ).toBeNull();

    expect(
      decodeSearchReply({
        ok: true,
        result: {
          items: [{ ...summary(), markdown: "# must not cross search boundary" }],
          nextCursor: null,
        },
      }),
    ).toEqual(invalidReply);
    expect(
      decodeTrashReply({
        ok: true,
        result: {
          items: [
            {
              summary: { ...summary({ deleted: true }), markdown: "# leak" },
              deletedAt: now,
            },
          ],
          nextCursor: null,
        },
      }),
    ).toEqual(invalidReply);
    expect(
      decodeHistoryReply({
        ok: true,
        result: {
          items: [{ ...versionSummary(), title: "not a history-summary key" }],
          nextCursor: null,
        },
      }),
    ).toEqual(invalidReply);
    expect(decodeCreateReply({ ok: true, result: withoutFirstKey(note()) })).toEqual(invalidReply);
    expect(
      decodeOpenReply({
        ok: true,
        result: { ...version(), unexpected: "secret-canary" },
      }),
    ).toEqual(invalidReply);
    expect(
      decodeConflictReply({
        ok: true,
        result: { ...conflictDetail(), current: { ...version(), classification: "private" } },
      }),
    ).toEqual(invalidReply);
  });

  it("bounds initial, search, Trash, and History pages at 50 exact-state items", () => {
    const liveSummaries = Array.from({ length: 50 }, () => summary());
    const trashItems = Array.from({ length: 50 }, () => ({
      summary: summary({ deleted: true }),
      deletedAt: now,
    }));
    const historyItems = Array.from({ length: 50 }, () => versionSummary());

    expect(decodeInitialProps(initialProps({ summaries: liveSummaries }))).not.toBeNull();
    expect(
      decodeSearchReply({ ok: true, result: { items: liveSummaries, nextCursor: null } }),
    ).not.toEqual(invalidReply);
    expect(
      decodeTrashReply({ ok: true, result: { items: trashItems, nextCursor: null } }),
    ).not.toEqual(invalidReply);
    expect(
      decodeHistoryReply({ ok: true, result: { items: historyItems, nextCursor: null } }),
    ).not.toEqual(invalidReply);

    expect(
      decodeInitialProps(initialProps({ summaries: [...liveSummaries, summary()] })),
    ).toBeNull();
    expect(
      decodeSearchReply({
        ok: true,
        result: { items: [...liveSummaries, summary()], nextCursor: null },
      }),
    ).toEqual(invalidReply);
    expect(
      decodeTrashReply({
        ok: true,
        result: {
          items: [...trashItems, { summary: summary({ deleted: true }), deletedAt: now }],
          nextCursor: null,
        },
      }),
    ).toEqual(invalidReply);
    expect(
      decodeHistoryReply({
        ok: true,
        result: { items: [...historyItems, versionSummary()], nextCursor: null },
      }),
    ).toEqual(invalidReply);
  });

  it("rejects tombstoned initial/search summaries and live Trash summaries", () => {
    expect(
      decodeInitialProps(initialProps({ summaries: [summary({ deleted: true })] })),
    ).toBeNull();
    expect(
      decodeSearchReply({
        ok: true,
        result: { items: [summary({ deleted: true })], nextCursor: null },
      }),
    ).toEqual(invalidReply);
    expect(
      decodeTrashReply({
        ok: true,
        result: {
          items: [{ summary: summary({ deleted: false }), deletedAt: now }],
          nextCursor: null,
        },
      }),
    ).toEqual(invalidReply);
  });

  it("accepts only canonical lowercase UUIDs throughout props, requests, and DTOs", () => {
    expect(
      decodeInitialProps({ ...initialProps(), vault: { ref: vaultId.toUpperCase() } }),
    ).toBeNull();
    expect(
      decodeInitialProps({
        ...initialProps(),
        summaries: [summary({ resourceId: resourceId.toUpperCase() })],
      }),
    ).toBeNull();

    const invalidIdRequests: Array<[Decoder, Record<string, unknown>]> = [
      [decodeOpenRequest, { version: 1, resourceId: "not-a-uuid", resourceVersionId: null }],
      [
        decodeOpenRequest,
        { version: 1, resourceId, resourceVersionId: canonicalVersionId.toUpperCase() },
      ],
      [
        decodeCreateRequest,
        { version: 1, mutationId: mutationId.toUpperCase(), title: "Title", markdown: "" },
      ],
      [
        decodeSaveRequest,
        {
          version: 1,
          mutationId,
          resourceId,
          baseVersionId: "bad",
          title: "Title",
          markdown: "",
        },
      ],
      [decodeHistoryRequest, { version: 1, resourceId: "bad", cursor: null, limit: 20 }],
      [decodeConflictRequest, { version: 1, resourceId, conflictId: "bad" }],
      [
        decodeMergeRequest,
        {
          ...requestCases.find(({ name }) => name === "merge")!.valid,
          competingVersionId: "BAD",
        },
      ],
      [
        decodeDeleteRequest,
        {
          ...requestCases.find(({ name }) => name === "delete")!.valid,
          expectedCurrentVersionId: "bad",
        },
      ],
      [decodeRestoreRequest, { version: 1, mutationId, resourceId: "bad" }],
    ];

    for (const [decode, value] of invalidIdRequests) {
      expect(decode(value)).toBeNull();
    }

    expect(
      decodeSearchReply({
        ok: true,
        result: { items: [summary({ resourceVersionId: "bad" })], nextCursor: null },
      }),
    ).toEqual(invalidReply);
    expect(
      decodeHistoryReply({
        ok: true,
        result: {
          items: [versionSummary({ createdByPrincipalId: principalId.toUpperCase() })],
          nextCursor: null,
        },
      }),
    ).toEqual(invalidReply);
    expect(
      decodeSaveReply({
        ok: true,
        result: savedResult({ submittedVersionId: "bad" }),
      }),
    ).toEqual(invalidReply);
    expect(
      decodeConflictReply({
        ok: true,
        result: conflictDetail({ conflictId: "bad" }),
      }),
    ).toEqual(invalidReply);
  });

  it("enforces byte bounds, safe integer relationships, and canonical UTC timestamps", () => {
    const invalidRequests: Array<[Decoder, Record<string, unknown>]> = [
      [decodeSearchRequest, { version: 1, q: "e".repeat(1_025), cursor: null, limit: 20 }],
      [decodeSearchRequest, { version: 1, q: "", cursor: null, limit: 51 }],
      [decodeSearchRequest, { version: 1, q: "", cursor: null, limit: 1.5 }],
      [
        decodeSearchRequest,
        { version: 1, q: "", cursor: null, limit: Number.MAX_SAFE_INTEGER + 1 },
      ],
      [decodeCreateRequest, { version: 1, mutationId, title: "e".repeat(256), markdown: "" }],
      [decodeCreateRequest, { version: 1, mutationId, title: "   ", markdown: "" }],
      [decodeCreateRequest, { version: 1, mutationId, title: "Title", markdown: "x\0y" }],
      [
        decodeCreateRequest,
        { version: 1, mutationId, title: "Title", markdown: "x".repeat(1_048_577) },
      ],
    ];

    for (const [decode, value] of invalidRequests) {
      expect(decode(value)).toBeNull();
    }

    const invalidSummaries = [
      summary({ revision: Number.MAX_SAFE_INTEGER + 1, displayVersion: 1 }),
      summary({ revision: -1, displayVersion: 0 }),
      summary({ revision: 2, displayVersion: 2 }),
      summary({ openConflictCount: -1 }),
      summary({ openConflictCount: Number.MAX_SAFE_INTEGER + 1 }),
      summary({ updatedAt: "2026-02-30T12:00:00.000000Z" }),
      summary({ updatedAt: "2026-08-20T13:00:00.000000+01:00" }),
    ];

    for (const malformed of invalidSummaries) {
      expect(
        decodeSearchReply({ ok: true, result: { items: [malformed], nextCursor: null } }),
      ).toEqual(invalidReply);
    }

    expect(
      decodeTrashReply({
        ok: true,
        result: {
          items: [{ summary: summary({ deleted: true }), deletedAt: "not-a-time" }],
          nextCursor: null,
        },
      }),
    ).toEqual(invalidReply);
    expect(
      decodeHistoryReply({
        ok: true,
        result: {
          items: [versionSummary({ insertedAt: "2026-08-20T12:00:00+02:00" })],
          nextCursor: null,
        },
      }),
    ).toEqual(invalidReply);
    expect(
      decodeHistoryReply({
        ok: true,
        result: {
          items: [
            versionSummary({ revision: 0, displayVersion: 1, parentVersionId: baseVersionId }),
          ],
          nextCursor: null,
        },
      }),
    ).toEqual(invalidReply);
    expect(
      decodeHistoryReply({
        ok: true,
        result: {
          items: [
            versionSummary({
              canonical: true,
              conflictState: "open",
            }),
          ],
          nextCursor: null,
        },
      }),
    ).toEqual(invalidReply);
  });

  it("accepts null or bounded opaque cursors and rejects blank, NUL, or oversized cursors", () => {
    const opaque = "opaque/+cursor==";
    expect(decodeSearchRequest({ version: 1, q: "", cursor: opaque, limit: 20 })).toEqual({
      version: 1,
      q: "",
      cursor: opaque,
      limit: 20,
    });
    expect(decodeSearchReply({ ok: true, result: { items: [], nextCursor: opaque } })).toEqual({
      ok: true,
      result: { items: [], nextCursor: opaque },
    });

    for (const cursor of ["", "   ", "bad\0cursor", "x".repeat(2_049)]) {
      expect(decodeSearchRequest({ version: 1, q: "", cursor, limit: 20 })).toBeNull();
      expect(decodeTrashRequest({ version: 1, cursor, limit: 20 })).toBeNull();
      expect(decodeHistoryRequest({ version: 1, resourceId, cursor, limit: 20 })).toBeNull();
      expect(decodeSearchReply({ ok: true, result: { items: [], nextCursor: cursor } })).toEqual(
        invalidReply,
      );
      expect(decodeHistoryReply({ ok: true, result: { items: [], nextCursor: cursor } })).toEqual(
        invalidReply,
      );
    }
  });

  it("enforces saved/conflict result invariants and conflict-detail relationships", () => {
    const validConflict = { ok: true, result: preservedConflict() };
    expect(decodeSaveReply(validConflict)).toEqual(validConflict);
    expect(decodeMergeReply(validConflict)).toEqual(validConflict);

    const invalidSaveResults = [
      savedResult({ outcome: "unknown" as NoteSaveResult["outcome"] }),
      savedResult({ submittedVersionId: competingVersionId }),
      savedResult({ conflictId }),
      preservedConflict({ conflictId: null }),
      preservedConflict({ submittedVersionId: canonicalVersionId }),
      preservedConflict({ canonical: note({ deleted: true }) }),
    ];

    for (const result of invalidSaveResults) {
      expect(decodeSaveReply({ ok: true, result })).toEqual(invalidReply);
      expect(decodeMergeReply({ ok: true, result })).toEqual(invalidReply);
    }

    const mismatches = [
      conflictDetail({
        current: version({ resourceId: uuid("20") }),
      }),
      conflictDetail({
        current: version({ canonical: false, conflictState: "open" }),
      }),
      conflictDetail({
        competing: competingVersion({ canonical: true, conflictState: null }),
      }),
      conflictDetail({
        competing: competingVersion({ resourceVersionId: canonicalVersionId }),
      }),
      conflictDetail({ baseVersionId: competingVersionId }),
      conflictDetail({ observedCanonicalVersionId: competingVersionId }),
    ];

    for (const result of mismatches) {
      expect(decodeConflictReply({ ok: true, result })).toEqual(invalidReply);
    }
  });

  it("preserves only exact stable failures and coerces every malformed reply to invalid", () => {
    const stableCodes = [
      "unauthenticated",
      "vault_locked",
      "forbidden",
      "not_found",
      "conflict",
      "invalid",
      "storage_unavailable",
    ];

    for (const { decode } of replyCases) {
      for (const code of stableCodes) {
        const failure = { ok: false, error: { code } };
        expect(decode(failure)).toEqual(failure);
      }

      expect(decode({ ok: false, error: { code: "secret-internal-code" } })).toEqual(
        unavailableReply,
      );
      expect(decode({ ok: false, error: { code: "invalid", detail: "secret-canary" } })).toEqual(
        invalidReply,
      );
      expect(decode({ ok: false, error: {} })).toEqual(invalidReply);
      expect(decode(null)).toEqual(invalidReply);
    }
  });

  it("rejects classification input and restricts navigation to the existing shell paths", () => {
    expect(
      decodeSearchRequest({
        version: 1,
        q: "",
        cursor: null,
        limit: 20,
        classification: "private",
      }),
    ).toBeNull();

    for (const to of ["/assets", "/notes", "/activity", "/audit", "/backups", "/settings"]) {
      expect(decodeNavigationRequest({ version: 1, to })).toEqual({ version: 1, to });
    }

    for (const to of ["/login", "/vault/unlock", "https://example.com", "javascript:alert(1)"]) {
      expect(decodeNavigationRequest({ version: 1, to })).toBeNull();
    }
  });
});

describe("Notes workspace state", () => {
  it("keeps the immutable canonical selection separate from the mutable local draft", () => {
    const store = new WorkspaceStore(initialProps());
    const open = store.beginLane("open");

    expect(store.acceptOpen(open, note())).toBe(true);
    const canonical = clone(store.getSnapshot().selection);

    expect(store.updateDraft({ title: "Locally edited", markdown: "# local draft" })).toBe(true);
    expect(store.getSnapshot().selection).toEqual(canonical);
    expect(store.getSnapshot().draft).toEqual({
      title: "Locally edited",
      markdown: "# local draft",
    });
    expect(store.getSnapshot().draft).not.toBe(store.getSnapshot().selection);
    expect(store.getSnapshot().dirty).toBe(true);
  });

  it("increments only the requested generation lane", () => {
    const store = new WorkspaceStore(initialProps());

    expect(store.getSnapshot().lanes).toEqual({
      search: 0,
      open: 0,
      history: 0,
      conflict: 0,
      mutation: 0,
    });
    expect(store.beginLane("search")).toEqual({ generation: 1, terminalEpoch: 0 });
    expect(store.getSnapshot().lanes).toEqual({
      search: 1,
      open: 0,
      history: 0,
      conflict: 0,
      mutation: 0,
    });
    expect(store.beginLane("history")).toEqual({ generation: 1, terminalEpoch: 0 });
    expect(store.getSnapshot().lanes).toEqual({
      search: 1,
      open: 0,
      history: 1,
      conflict: 0,
      mutation: 0,
    });
  });

  it("rejects stale search, open, history, conflict, and mutation generations", () => {
    const searchStore = new WorkspaceStore(initialProps());
    const oldSearch = searchStore.beginLane("search");
    const freshSearch = searchStore.beginLane("search");
    expect(searchStore.acceptSearch(freshSearch, searchPage("fresh search"))).toBe(true);
    expect(searchStore.acceptSearch(oldSearch, searchPage("stale search"))).toBe(false);
    expect(searchStore.getSnapshot().summaries[0].title).toBe("fresh search");

    const openStore = new WorkspaceStore(initialProps());
    const oldOpen = openStore.beginLane("open");
    const freshOpen = openStore.beginLane("open");
    expect(openStore.acceptOpen(freshOpen, note({ title: "fresh open" }))).toBe(true);
    expect(openStore.acceptOpen(oldOpen, note({ title: "stale open" }))).toBe(false);
    expect(openStore.getSnapshot().selection?.title).toBe("fresh open");

    const historyStore = new WorkspaceStore(initialProps());
    const oldHistory = historyStore.beginLane("history");
    const freshHistory = historyStore.beginLane("history");
    expect(
      historyStore.acceptHistory(
        freshHistory,
        historyPage(versionSummary({ resourceVersionId: uuid("11") })),
      ),
    ).toBe(true);
    expect(
      historyStore.acceptHistory(
        oldHistory,
        historyPage(versionSummary({ resourceVersionId: uuid("12") })),
      ),
    ).toBe(false);
    expect(historyStore.getSnapshot().history[0].resourceVersionId).toBe(uuid("11"));

    const conflictStore = new WorkspaceStore(initialProps());
    const oldConflict = conflictStore.beginLane("conflict");
    const freshConflict = conflictStore.beginLane("conflict");
    expect(
      conflictStore.acceptConflict(
        freshConflict,
        conflictDetail({ current: version({ title: "fresh conflict" }) }),
      ),
    ).toBe(true);
    expect(
      conflictStore.acceptConflict(
        oldConflict,
        conflictDetail({ current: version({ title: "stale conflict" }) }),
      ),
    ).toBe(false);
    expect(conflictStore.getSnapshot().conflict?.detail?.current.title).toBe("fresh conflict");

    const mutationStore = new WorkspaceStore(initialProps());
    const oldMutation = mutationStore.beginLane("mutation");
    const freshMutation = mutationStore.beginLane("mutation");
    expect(
      mutationStore.acceptMutation(
        freshMutation,
        savedResult({ canonical: note({ title: "fresh mutation" }) }),
      ),
    ).toBe(true);
    expect(
      mutationStore.acceptMutation(
        oldMutation,
        preservedConflict({ canonical: note({ title: "stale mutation" }) }),
      ),
    ).toBe(false);
    expect(mutationStore.getSnapshot().selection?.title).toBe("fresh mutation");
    expect(mutationStore.getSnapshot().conflict).toBeNull();
  });

  it("retains canonical and competing IDs after a preserved conflict Save", () => {
    const store = new WorkspaceStore(initialProps());
    const open = store.beginLane("open");
    expect(store.acceptOpen(open, note())).toBe(true);
    expect(
      store.updateDraft({ title: "My competing title", markdown: "# my competing body" }),
    ).toBe(true);
    const localDraft = clone(store.getSnapshot().draft);

    const mutation = store.beginLane("mutation");
    expect(
      store.acceptMutation(
        mutation,
        preservedConflict({ canonical: note({ title: "Accepted canonical" }) }),
      ),
    ).toBe(true);

    expect(store.getSnapshot().selection?.title).toBe("Accepted canonical");
    expect(store.getSnapshot().draft).toEqual(localDraft);
    expect(store.getSnapshot().dirty).toBe(true);
    expect(store.getSnapshot().conflict).toEqual({
      conflictId,
      canonicalVersionId,
      competingVersionId,
      detail: null,
    });

    const conflict = store.beginLane("conflict");
    expect(store.acceptConflict(conflict, conflictDetail())).toBe(true);
    expect(store.getSnapshot().conflict).toMatchObject({
      conflictId,
      canonicalVersionId,
      competingVersionId,
      detail: conflictDetail(),
    });
  });

  it.each(["vault_locked", "unauthenticated", "expiry"] as const)(
    "purges every private field and invalidates all lanes on %s",
    (reason) => {
      const store = new WorkspaceStore(initialProps());

      const search = store.beginLane("search");
      expect(
        store.acceptSearch(search, searchPage("private summary", "private-search-cursor")),
      ).toBe(true);
      const open = store.beginLane("open");
      expect(store.acceptOpen(open, note({ markdown: "# private canonical" }))).toBe(true);
      expect(store.updateDraft({ title: "Private draft", markdown: "# private draft" })).toBe(true);
      const history = store.beginLane("history");
      expect(
        store.acceptHistory(history, historyPage(versionSummary(), "private-history-cursor")),
      ).toBe(true);
      const conflict = store.beginLane("conflict");
      expect(store.acceptConflict(conflict, conflictDetail())).toBe(true);

      const old = {
        search: store.beginLane("search"),
        open: store.beginLane("open"),
        history: store.beginLane("history"),
        conflict: store.beginLane("conflict"),
        mutation: store.beginLane("mutation"),
      };
      const before = clone(store.getSnapshot());

      store.purge(reason);

      expect(store.getSnapshot()).toMatchObject({
        summaries: [],
        selection: null,
        draft: null,
        history: [],
        conflict: null,
        dirty: false,
        searchNextCursor: null,
        historyNextCursor: null,
        terminalEpoch: before.terminalEpoch + 1,
        lanes: {
          search: before.lanes.search + 1,
          open: before.lanes.open + 1,
          history: before.lanes.history + 1,
          conflict: before.lanes.conflict + 1,
          mutation: before.lanes.mutation + 1,
        },
      });

      expect(store.acceptSearch(old.search, searchPage("late search"))).toBe(false);
      expect(store.acceptOpen(old.open, note({ title: "late open" }))).toBe(false);
      expect(store.acceptHistory(old.history, historyPage())).toBe(false);
      expect(store.acceptConflict(old.conflict, conflictDetail())).toBe(false);
      expect(store.acceptMutation(old.mutation, preservedConflict())).toBe(false);
      expect(store.getSnapshot()).toMatchObject({
        summaries: [],
        selection: null,
        draft: null,
        history: [],
        conflict: null,
        dirty: false,
      });
    },
  );
});
