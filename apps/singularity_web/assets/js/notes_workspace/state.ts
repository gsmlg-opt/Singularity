import type {
  InitialProps,
  Note,
  NoteConflictDetail,
  NoteHistoryPage,
  NotePage,
  NoteSaveResult,
  NoteVersion,
} from "./contracts";

export type Lane = "search" | "open" | "history" | "conflict" | "mutation";
export type LaneToken = { generation: number; terminalEpoch: number };
export type PurgeReason = "vault_locked" | "unauthenticated" | "expiry";
type Draft = { title: string; markdown: string };
type ConflictState = {
  conflictId: string;
  canonicalVersionId: string;
  competingVersionId: string;
  detail: NoteConflictDetail | null;
};

export type WorkspaceSnapshot = InitialProps & {
  selection: Note | NoteVersion | null;
  draft: Draft | null;
  history: NoteHistoryPage["items"];
  conflict: ConflictState | null;
  dirty: boolean;
  searchNextCursor: string | null;
  historyNextCursor: string | null;
  lanes: Record<Lane, number>;
  terminalEpoch: number;
};

type Listener = () => void;
const laneNames: Lane[] = ["search", "open", "history", "conflict", "mutation"];

export class WorkspaceStore {
  private snapshot: WorkspaceSnapshot;
  private listeners = new Set<Listener>();
  private terminal = false;

  constructor(initial: InitialProps) {
    this.snapshot = {
      ...initial,
      vault: { ...initial.vault },
      filters: { ...initial.filters },
      summaries: [...initial.summaries],
      selection: null,
      draft: null,
      history: [],
      conflict: null,
      dirty: false,
      searchNextCursor: null,
      historyNextCursor: null,
      lanes: { search: 0, open: 0, history: 0, conflict: 0, mutation: 0 },
      terminalEpoch: 0,
    };
  }

  getSnapshot = (): WorkspaceSnapshot => this.snapshot;
  subscribe = (listener: Listener): (() => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };

  beginLane(lane: Lane): LaneToken {
    const lanes = { ...this.snapshot.lanes, [lane]: this.snapshot.lanes[lane] + 1 };
    this.commit({ ...this.snapshot, lanes });
    return { generation: lanes[lane], terminalEpoch: this.snapshot.terminalEpoch };
  }

  acceptSearch(token: LaneToken, page: NotePage): boolean {
    return this.accept("search", token, {
      ...this.snapshot,
      summaries: [...page.items],
      searchNextCursor: page.nextCursor,
    });
  }

  acceptOpen(token: LaneToken, note: Note | NoteVersion): boolean {
    const editable = "updatedAt" in note;
    return this.accept("open", token, {
      ...this.snapshot,
      selection: note,
      draft: editable ? { title: note.title, markdown: note.markdown } : null,
      history: [],
      historyNextCursor: null,
      conflict: null,
      dirty: false,
    });
  }

  acceptHistory(token: LaneToken, page: NoteHistoryPage): boolean {
    return this.accept("history", token, {
      ...this.snapshot,
      history: [...page.items],
      historyNextCursor: page.nextCursor,
    });
  }

  acceptConflict(token: LaneToken, detail: NoteConflictDetail): boolean {
    return this.accept("conflict", token, {
      ...this.snapshot,
      conflict: {
        conflictId: detail.conflictId,
        canonicalVersionId: detail.current.resourceVersionId,
        competingVersionId: detail.competing.resourceVersionId,
        detail,
      },
    });
  }

  acceptMutation(token: LaneToken, result: Note | NoteSaveResult | boolean): boolean {
    if (!this.accepts("mutation", token)) return false;

    if (typeof result === "boolean") {
      this.commit({
        ...this.snapshot,
        summaries: [],
        selection: null,
        draft: null,
        history: [],
        conflict: null,
        dirty: false,
        searchNextCursor: null,
        historyNextCursor: null,
      });
      return true;
    }

    if ("outcome" in result) {
      const conflict =
        result.outcome === "conflict" && result.conflictId
          ? {
              conflictId: result.conflictId,
              canonicalVersionId: result.canonical.resourceVersionId,
              competingVersionId: result.submittedVersionId,
              detail: null,
            }
          : null;
      this.commit({
        ...this.snapshot,
        selection: result.canonical,
        draft:
          result.outcome === "conflict"
            ? this.snapshot.draft
            : { title: result.canonical.title, markdown: result.canonical.markdown },
        conflict,
        dirty: result.outcome === "conflict",
      });
      return true;
    }

    this.commit({
      ...this.snapshot,
      selection: result,
      draft: { title: result.title, markdown: result.markdown },
      conflict: null,
      dirty: false,
    });
    return true;
  }

  updateDraft(draft: Draft): boolean {
    if (this.terminal) return false;
    this.commit({ ...this.snapshot, draft: { ...draft }, dirty: true });
    return true;
  }

  purgePrivateState(_reason: PurgeReason): void {
    const lanes = Object.fromEntries(
      laneNames.map((lane) => [lane, this.snapshot.lanes[lane] + 1]),
    ) as Record<Lane, number>;
    this.terminal = true;
    this.commit({
      ...this.snapshot,
      filters: { ...this.snapshot.filters, q: "" },
      summaries: [],
      selection: null,
      draft: null,
      history: [],
      conflict: null,
      dirty: false,
      searchNextCursor: null,
      historyNextCursor: null,
      lanes,
      terminalEpoch: this.snapshot.terminalEpoch + 1,
    });
  }

  private accept(lane: Lane, token: LaneToken, snapshot: WorkspaceSnapshot): boolean {
    if (!this.accepts(lane, token)) return false;
    this.commit(snapshot);
    return true;
  }

  private accepts(lane: Lane, token: LaneToken): boolean {
    return (
      !this.terminal &&
      token.terminalEpoch === this.snapshot.terminalEpoch &&
      token.generation === this.snapshot.lanes[lane]
    );
  }

  private commit(snapshot: WorkspaceSnapshot): void {
    this.snapshot = snapshot;
    for (const listener of this.listeners) listener();
  }
}
