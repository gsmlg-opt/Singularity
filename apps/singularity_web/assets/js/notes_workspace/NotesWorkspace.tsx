import {
  type FormEvent,
  type KeyboardEvent as ReactKeyboardEvent,
  useEffect,
  useRef,
  useState,
  useSyncExternalStore,
} from "react";

import { applyTheme, readTheme } from "../asset_workspace/theme";
import type {
  NavigationTarget,
  Note,
  NoteSummary,
  NoteTrashPage,
  NoteVersion,
  NoteVersionSummary,
  NotesBridge,
} from "./contracts";
import { SafeMarkdown } from "./safe_markdown";
import type { Lane, LaneToken, WorkspaceStore } from "./state";

export type NotesWorkspaceProps = { bridge: NotesBridge; store: WorkspaceStore };

type Drawer = "closed" | "preview" | "history" | "conflict";
type RailMode = "current" | "trash";
type Panel = "editor" | "rail" | "drawer";
type Notice = { tone: "error" | "info"; text: string };
type Draft = { title: string; markdown: string };
type PendingAction =
  | { kind: "navigate"; target: NavigationTarget; trigger: HTMLElement }
  | { kind: "open"; summary: NoteSummary; trigger: HTMLElement }
  | { kind: "new"; trigger: HTMLElement };

const maximumRailItems = 50;

const navigationTargets = new Set<NavigationTarget>([
  "/assets",
  "/notes",
  "/activity",
  "/audit",
  "/backups",
  "/settings",
]);

function canonicalMutationId(): string {
  const randomUUID = crypto.randomUUID?.bind(crypto);
  if (randomUUID) return randomUUID().toLowerCase();

  const bytes = new Uint8Array(16);
  crypto.getRandomValues(bytes);
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(
    16,
    20,
  )}-${hex.slice(20)}`;
}

function isEditable(selection: Note | NoteVersion | null): selection is Note {
  return selection !== null && "updatedAt" in selection;
}

function validDraft(title: string, markdown: string): boolean {
  const encoder = new TextEncoder();
  const trimmedTitle = title.trim();
  return (
    trimmedTitle !== "" &&
    encoder.encode(trimmedTitle).length <= 255 &&
    !trimmedTitle.includes("\0") &&
    encoder.encode(markdown).length <= 1_048_576 &&
    !markdown.includes("\0")
  );
}

function stableFailure(operation: string): Notice {
  return {
    tone: "error",
    text: `${operation} could not be completed. Your local draft is unchanged. Try saving again.`,
  };
}

function shellNavigationTarget(
  anchor: HTMLAnchorElement,
  event: MouseEvent,
): NavigationTarget | null {
  if (
    event.button !== 0 ||
    event.altKey ||
    event.ctrlKey ||
    event.metaKey ||
    event.shiftKey ||
    anchor.hasAttribute("download") ||
    (anchor.target !== "" && anchor.target !== "_self") ||
    !anchor.hasAttribute("data-phx-link")
  ) {
    return null;
  }

  const raw = anchor.getAttribute("href");
  if (!raw) return null;

  try {
    const url = new URL(raw, window.location.href);
    return url.origin === window.location.origin &&
      url.search === "" &&
      url.hash === "" &&
      navigationTargets.has(url.pathname as NavigationTarget)
      ? (url.pathname as NavigationTarget)
      : null;
  } catch {
    return null;
  }
}

function versionLabel(version: NoteVersionSummary): string {
  if (version.canonical) return `Version ${version.displayVersion}, current`;
  if (version.conflictState === "open") return `Version ${version.displayVersion}, competing`;
  return `Version ${version.displayVersion}`;
}

function summaryFromNote(note: Note): NoteSummary {
  return {
    resourceId: note.resourceId,
    resourceVersionId: note.resourceVersionId,
    title: note.title,
    revision: note.revision,
    displayVersion: note.displayVersion,
    updatedAt: note.updatedAt,
    deleted: note.deleted,
    openConflictCount: note.openConflictCount,
  };
}

function createResultMatches(note: Note, submitted: Draft): boolean {
  return (
    note.revision === 0 &&
    note.displayVersion === 1 &&
    !note.deleted &&
    note.openConflictCount === 0 &&
    note.title === submitted.title &&
    note.markdown === submitted.markdown
  );
}

export function NotesWorkspace({ bridge, store }: NotesWorkspaceProps) {
  const snapshot = useSyncExternalStore(store.subscribe, store.getSnapshot, store.getSnapshot);
  const [query, setQuery] = useState(snapshot.filters.q);
  const [railMode, setRailMode] = useState<RailMode>("current");
  const [trashItems, setTrashItems] = useState<NoteTrashPage["items"]>([]);
  const [drawer, setDrawer] = useState<Drawer>("closed");
  const [activePanel, setActivePanel] = useState<Panel>("editor");
  const [notice, setNotice] = useState<Notice | null>(null);
  const [pendingAction, setPendingAction] = useState<PendingAction | null>(null);
  const [dialogBusy, setDialogBusy] = useState(false);
  const [dialogError, setDialogError] = useState<string | null>(null);
  const [editorFocusRequest, setEditorFocusRequest] = useState(0);
  const [mergeMode, setMergeMode] = useState(false);
  const [createDraft, setCreateDraft] = useState<Draft | null>(null);
  const [createDirty, setCreateDirty] = useState(false);
  const [listBusy, setListBusy] = useState(false);
  const [mutationBusy, setMutationBusy] = useState(false);
  const listBusyRef = useRef(false);
  const mutationBusyRef = useRef<LaneToken | null>(null);
  const contextGenerationRef = useRef(0);
  const queryInputRef = useRef<HTMLInputElement>(null);
  const drawerTriggerRef = useRef<HTMLButtonElement | null>(null);
  const drawerCloseRef = useRef<HTMLButtonElement>(null);
  const dialogRef = useRef<HTMLElement>(null);
  const stayButtonRef = useRef<HTMLButtonElement>(null);
  const editorTitleRef = useRef<HTMLInputElement>(null);
  const consumedEditorFocusRequestRef = useRef(0);

  const selection = snapshot.selection;
  const editable = isEditable(selection) ? selection : null;
  const creating = createDraft !== null;
  const draft = creating ? createDraft : snapshot.draft;
  const dirty = creating ? createDirty : snapshot.dirty;
  const terminal = snapshot.terminalEpoch > 0;
  const canSave = Boolean(
    (creating || editable) &&
    draft !== null &&
    dirty &&
    validDraft(draft.title, draft.markdown) &&
    !mutationBusy,
  );

  useEffect(() => {
    applyTheme(readTheme());
  }, []);

  useEffect(() => {
    if (!dirty) return;

    const beforeUnload = (event: BeforeUnloadEvent) => {
      event.preventDefault();
      event.returnValue = "";
    };
    window.addEventListener("beforeunload", beforeUnload);
    return () => window.removeEventListener("beforeunload", beforeUnload);
  }, [dirty]);

  useEffect(() => {
    if (!dirty) return;

    const captureShellNavigation = (event: MouseEvent) => {
      if (!(event.target instanceof Element)) return;
      const anchor = event.target.closest("a[href]");
      if (!(anchor instanceof HTMLAnchorElement)) return;
      const target = shellNavigationTarget(anchor, event);
      if (!target) return;

      event.preventDefault();
      setDialogError(null);
      setPendingAction({ kind: "navigate", target, trigger: anchor });
    };
    document.addEventListener("click", captureShellNavigation, true);
    return () => document.removeEventListener("click", captureShellNavigation, true);
  }, [dirty]);

  useEffect(() => {
    if (!pendingAction) return;
    const dialog = dialogRef.current;
    if (!dialog) return;

    const focusable = () =>
      [
        ...dialog.querySelectorAll<HTMLElement>("button:not(:disabled), [href], input, textarea"),
      ].filter((element) => !element.hasAttribute("hidden"));
    const trapTab = (event: KeyboardEvent) => {
      if (event.key !== "Tab") return;
      const controls = focusable();
      const first = controls[0];
      const last = controls.at(-1);
      if (!first || !last) return;
      if (
        event.shiftKey &&
        (document.activeElement === first || !dialog.contains(document.activeElement))
      ) {
        event.preventDefault();
        last.focus();
      } else if (
        !event.shiftKey &&
        (document.activeElement === last || !dialog.contains(document.activeElement))
      ) {
        event.preventDefault();
        first.focus();
      }
    };
    const containFocus = (event: FocusEvent) => {
      if (!(event.target instanceof Node) || dialog.contains(event.target)) return;
      stayButtonRef.current?.focus();
    };

    document.addEventListener("keydown", trapTab, true);
    document.addEventListener("focusin", containFocus, true);
    queueMicrotask(() => stayButtonRef.current?.focus());
    return () => {
      document.removeEventListener("keydown", trapTab, true);
      document.removeEventListener("focusin", containFocus, true);
    };
  }, [pendingAction]);

  useEffect(() => {
    if (
      pendingAction ||
      (!creating && !editable) ||
      editorFocusRequest === consumedEditorFocusRequestRef.current
    ) {
      return;
    }
    consumedEditorFocusRequestRef.current = editorFocusRequest;
    queueMicrotask(() => editorTitleRef.current?.focus());
  }, [pendingAction, creating, editable, editorFocusRequest]);

  useEffect(() => {
    if (drawer !== "closed") queueMicrotask(() => drawerCloseRef.current?.focus());
  }, [drawer]);

  useEffect(() => {
    if (!terminal) return;
    contextGenerationRef.current += 1;
    consumedEditorFocusRequestRef.current = editorFocusRequest;
    listBusyRef.current = false;
    mutationBusyRef.current = null;
    drawerTriggerRef.current = null;
    setQuery("");
    setRailMode("current");
    setTrashItems([]);
    setDrawer("closed");
    setActivePanel("editor");
    setNotice(null);
    setPendingAction(null);
    setDialogBusy(false);
    setDialogError(null);
    setMergeMode(false);
    setCreateDraft(null);
    setCreateDirty(false);
    setListBusy(false);
    setMutationBusy(false);
  }, [terminal, editorFocusRequest]);

  function showDrawer(next: Exclude<Drawer, "closed">, trigger: HTMLButtonElement): void {
    drawerTriggerRef.current = trigger;
    setDrawer(next);
    setActivePanel("drawer");
  }

  function closeDrawer(): void {
    setDrawer("closed");
    setActivePanel("editor");
    queueMicrotask(() => drawerTriggerRef.current?.focus());
  }

  function laneIsCurrent(lane: Lane, token: LaneToken): boolean {
    const current = store.getSnapshot();
    return (
      current.terminalEpoch === token.terminalEpoch && current.lanes[lane] === token.generation
    );
  }

  function contextIsCurrent(generation: number, resourceId?: string): boolean {
    if (contextGenerationRef.current !== generation) return false;
    return resourceId === undefined || store.getSnapshot().selection?.resourceId === resourceId;
  }

  function clearMutationBusy(): void {
    mutationBusyRef.current = null;
    setMutationBusy(false);
  }

  function invalidateMutation(): void {
    store.beginLane("mutation");
    clearMutationBusy();
  }

  function invalidateDependentReads(): void {
    store.beginLane("history");
    store.beginLane("conflict");
  }

  function beginSelectionTransition(): { contextGeneration: number; token: LaneToken } {
    contextGenerationRef.current += 1;
    store.beginLane("history");
    store.beginLane("conflict");
    invalidateMutation();
    return {
      contextGeneration: contextGenerationRef.current,
      token: store.beginLane("open"),
    };
  }

  function beginMutation(): LaneToken | null {
    if (mutationBusyRef.current || terminal) return null;
    contextGenerationRef.current += 1;
    invalidateDependentReads();
    const token = store.beginLane("mutation");
    mutationBusyRef.current = token;
    setMutationBusy(true);
    return token;
  }

  function completeMutationContext(): void {
    contextGenerationRef.current += 1;
    invalidateDependentReads();
  }

  function finishMutation(token: LaneToken): void {
    if (mutationBusyRef.current !== token) return;
    clearMutationBusy();
  }

  function updateLocalDraft(nextDraft: { title: string; markdown: string }): void {
    if (!store.updateDraft(nextDraft)) return;
    contextGenerationRef.current += 1;
    invalidateMutation();
  }

  function leaveCreateMode(): void {
    setCreateDraft(null);
    setCreateDirty(false);
  }

  function beginFreshCreate(): void {
    contextGenerationRef.current += 1;
    store.beginLane("open");
    invalidateDependentReads();
    invalidateMutation();
    setCreateDraft({ title: "", markdown: "" });
    setCreateDirty(false);
    setRailMode("current");
    setMergeMode(false);
    setDrawer("closed");
    setActivePanel("editor");
    setNotice({ tone: "info", text: "New note. Add a title, then choose Save." });
    setEditorFocusRequest((request) => request + 1);
  }

  function updateDraft(nextDraft: Draft): void {
    if (!creating) {
      updateLocalDraft(nextDraft);
      return;
    }
    setCreateDraft({ ...nextDraft });
    setCreateDirty(true);
    contextGenerationRef.current += 1;
    invalidateMutation();
  }

  async function search(event: FormEvent<HTMLFormElement>): Promise<void> {
    event.preventDefault();
    if (listBusyRef.current || terminal) return;
    listBusyRef.current = true;
    setListBusy(true);
    setNotice(null);
    const token = store.beginLane("search");
    try {
      const reply = await bridge.search({
        version: 1,
        q: (queryInputRef.current?.value ?? query).trim(),
        cursor: null,
        limit: 20,
      });
      if (!laneIsCurrent("search", token)) return;
      if (reply.ok && store.acceptSearch(token, reply.result)) {
        setRailMode("current");
        setNotice({ tone: "info", text: "Current notes updated." });
      } else if (!reply.ok) {
        setNotice({ tone: "error", text: "Search failed. Existing results remain available." });
      }
    } catch {
      if (laneIsCurrent("search", token)) {
        setNotice({ tone: "error", text: "Search failed. Existing results remain available." });
      }
    } finally {
      listBusyRef.current = false;
      setListBusy(false);
    }
  }

  async function loadTrash(): Promise<void> {
    if (listBusyRef.current || terminal) return;
    listBusyRef.current = true;
    setListBusy(true);
    setNotice(null);
    setRailMode("trash");
    const token = store.beginLane("search");
    try {
      const reply = await bridge.trash({ version: 1, cursor: null, limit: 20 });
      const current = store.getSnapshot();
      if (
        current.terminalEpoch !== token.terminalEpoch ||
        current.lanes.search !== token.generation
      ) {
        return;
      }
      if (reply.ok) {
        setTrashItems(reply.result.items);
        setNotice({ tone: "info", text: "Trash updated." });
      } else {
        setNotice({ tone: "error", text: "Trash could not be loaded." });
      }
    } catch {
      setNotice({ tone: "error", text: "Trash could not be loaded." });
    } finally {
      listBusyRef.current = false;
      setListBusy(false);
    }
  }

  async function openVersion(
    resourceId: string,
    resourceVersionId: string | null,
    focusEditorOnSuccess = false,
  ): Promise<boolean> {
    if (terminal) return false;
    const { contextGeneration, token } = beginSelectionTransition();
    setNotice(null);
    try {
      const reply = await bridge.open({ version: 1, resourceId, resourceVersionId });
      if (!laneIsCurrent("open", token) || !contextIsCurrent(contextGeneration)) return false;
      if (!reply.ok) {
        setNotice({ tone: "error", text: "The note could not be opened." });
        return false;
      }
      if (
        reply.result.resourceId !== resourceId ||
        (resourceVersionId !== null && reply.result.resourceVersionId !== resourceVersionId)
      ) {
        setNotice({ tone: "error", text: "The note could not be opened." });
        return false;
      }
      const focusEditor = focusEditorOnSuccess && isEditable(reply.result);
      if (!store.acceptOpen(token, reply.result)) return false;
      if (focusEditor) setEditorFocusRequest((request) => request + 1);

      setRailMode("current");
      setMergeMode(false);
      if (isEditable(reply.result)) {
        setDrawer("closed");
        setActivePanel("editor");
        setNotice({ tone: "info", text: "Current note opened." });
      } else {
        setDrawer("history");
        setActivePanel("drawer");
        setNotice({ tone: "info", text: "Pinned version opened read-only." });
      }
      return true;
    } catch {
      if (laneIsCurrent("open", token) && contextIsCurrent(contextGeneration)) {
        setNotice({ tone: "error", text: "The note could not be opened." });
      }
      return false;
    }
  }

  async function openFromRail(summary: NoteSummary): Promise<void> {
    if (await openVersion(summary.resourceId, summary.resourceVersionId, true)) {
      leaveCreateMode();
    }
  }

  function requestOpen(summary: NoteSummary, trigger: HTMLButtonElement): void {
    if (dirty) {
      setDialogError(null);
      setPendingAction({ kind: "open", summary, trigger });
      return;
    }
    void openFromRail(summary);
  }

  function requestNew(trigger: HTMLButtonElement): void {
    if (dirty) {
      setDialogError(null);
      setPendingAction({ kind: "new", trigger });
      return;
    }
    beginFreshCreate();
  }

  function stay(): void {
    if (dialogBusy) return;
    const trigger = pendingAction?.trigger;
    setPendingAction(null);
    setDialogError(null);
    queueMicrotask(() => trigger?.focus());
  }

  async function discard(): Promise<void> {
    const action = pendingAction;
    if (!action || dialogBusy) return;
    setDialogBusy(true);
    setDialogError(null);
    try {
      if (action.kind === "new") {
        beginFreshCreate();
        setPendingAction(null);
        return;
      }

      if (action.kind === "navigate") {
        const reply = await bridge.navigate(action.target);
        if (reply.ok) {
          setPendingAction(null);
          return;
        }
        setDialogError("Navigation could not be completed.");
        return;
      }

      if (await openVersion(action.summary.resourceId, action.summary.resourceVersionId, true)) {
        leaveCreateMode();
        setPendingAction(null);
        return;
      }
      setDialogError("The selected note could not be opened.");
    } catch {
      setDialogError(
        action.kind === "navigate"
          ? "Navigation could not be completed."
          : "The selected note could not be opened.",
      );
    } finally {
      setDialogBusy(false);
      if (pendingAction) queueMicrotask(() => stayButtonRef.current?.focus());
    }
  }

  async function loadHistory(trigger: HTMLButtonElement): Promise<void> {
    if (!selection || terminal) return;
    const resourceId = selection.resourceId;
    const contextGeneration = contextGenerationRef.current;
    showDrawer("history", trigger);
    const token = store.beginLane("history");
    try {
      const reply = await bridge.history({
        version: 1,
        resourceId,
        cursor: null,
        limit: 20,
      });
      if (!laneIsCurrent("history", token) || !contextIsCurrent(contextGeneration, resourceId)) {
        return;
      }
      if (!reply.ok) {
        setNotice({ tone: "error", text: "History could not be loaded." });
        return;
      }
      if (!store.acceptHistory(token, reply.result)) return;
    } catch {
      if (laneIsCurrent("history", token) && contextIsCurrent(contextGeneration, resourceId)) {
        setNotice({ tone: "error", text: "History could not be loaded." });
      }
    }
  }

  async function loadConflict(trigger: HTMLButtonElement): Promise<void> {
    if (!selection || !snapshot.conflict || terminal) return;
    const resourceId = selection.resourceId;
    const contextGeneration = contextGenerationRef.current;
    showDrawer("conflict", trigger);
    const token = store.beginLane("conflict");
    try {
      const reply = await bridge.conflict({
        version: 1,
        resourceId,
        conflictId: snapshot.conflict.conflictId,
      });
      if (!laneIsCurrent("conflict", token) || !contextIsCurrent(contextGeneration, resourceId)) {
        return;
      }
      if (!reply.ok || reply.result.current.resourceId !== resourceId) {
        setNotice({ tone: "error", text: "Conflict details could not be loaded." });
        return;
      }
      if (!store.acceptConflict(token, reply.result)) return;
    } catch {
      if (laneIsCurrent("conflict", token) && contextIsCurrent(contextGeneration, resourceId)) {
        setNotice({ tone: "error", text: "Conflict details could not be loaded." });
      }
    }
  }

  async function createNote(): Promise<void> {
    if (!creating || !canSave || !createDraft || mutationBusyRef.current) return;
    const token = beginMutation();
    if (!token) return;
    setNotice(null);
    const contextGeneration = contextGenerationRef.current;
    const submittedDraft = { ...createDraft };
    const submitted = {
      title: submittedDraft.title.trim(),
      markdown: submittedDraft.markdown,
    };
    try {
      const reply = await bridge.create({
        version: 1,
        mutationId: canonicalMutationId(),
        ...submitted,
      });
      if (!laneIsCurrent("mutation", token) || !contextIsCurrent(contextGeneration)) return;
      if (!reply.ok || !createResultMatches(reply.result, submitted)) {
        setNotice(stableFailure("Create"));
        return;
      }
      if (!store.acceptMutation(token, reply.result)) return;

      const current = store.getSnapshot();
      const searchToken = store.beginLane("search");
      store.acceptSearch(searchToken, {
        items: [
          summaryFromNote(reply.result),
          ...current.summaries.filter((item) => item.resourceId !== reply.result.resourceId),
        ].slice(0, maximumRailItems),
        nextCursor: current.searchNextCursor,
      });
      completeMutationContext();
      leaveCreateMode();
      setRailMode("current");
      setMergeMode(false);
      setDrawer("closed");
      setActivePanel("editor");
      setNotice({ tone: "info", text: "Note created." });
      setEditorFocusRequest((request) => request + 1);
    } catch {
      if (laneIsCurrent("mutation", token) && contextIsCurrent(contextGeneration)) {
        setNotice(stableFailure("Create"));
      }
    } finally {
      finishMutation(token);
    }
  }

  async function saveDraft(): Promise<void> {
    if (creating) {
      await createNote();
      return;
    }
    if (!canSave || !editable || !draft || mutationBusyRef.current) return;
    const token = beginMutation();
    if (!token) return;
    setNotice(null);
    const contextGeneration = contextGenerationRef.current;
    const resourceId = editable.resourceId;
    try {
      const reply =
        mergeMode && snapshot.conflict?.detail
          ? await bridge.merge({
              version: 1,
              mutationId: canonicalMutationId(),
              resourceId: editable.resourceId,
              conflictId: snapshot.conflict.detail.conflictId,
              expectedCurrentVersionId: snapshot.conflict.detail.current.resourceVersionId,
              competingVersionId: snapshot.conflict.detail.competing.resourceVersionId,
              title: draft.title.trim(),
              markdown: draft.markdown,
            })
          : await bridge.save({
              version: 1,
              mutationId: canonicalMutationId(),
              resourceId: editable.resourceId,
              baseVersionId: editable.resourceVersionId,
              title: draft.title.trim(),
              markdown: draft.markdown,
            });

      if (!laneIsCurrent("mutation", token) || !contextIsCurrent(contextGeneration, resourceId)) {
        return;
      }
      if (!reply.ok || reply.result.canonical.resourceId !== resourceId) {
        setNotice(stableFailure(mergeMode ? "Merge" : "Save"));
        return;
      }
      if (!store.acceptMutation(token, reply.result)) return;
      completeMutationContext();

      if (reply.result.outcome === "conflict") {
        setMergeMode(false);
        setDrawer("conflict");
        setActivePanel("drawer");
        setNotice({
          tone: "error",
          text: "A newer current version exists. Review the preserved conflict before merging.",
        });
      } else {
        setMergeMode(false);
        setDrawer("closed");
        setActivePanel("editor");
        setNotice({ tone: "info", text: "Note saved." });
      }
    } catch {
      if (laneIsCurrent("mutation", token) && contextIsCurrent(contextGeneration, resourceId)) {
        setNotice(stableFailure(mergeMode ? "Merge" : "Save"));
      }
    } finally {
      finishMutation(token);
    }
  }

  async function deleteCurrent(): Promise<void> {
    if (!editable || mutationBusyRef.current || terminal) return;
    const token = beginMutation();
    if (!token) return;
    const contextGeneration = contextGenerationRef.current;
    const resourceId = editable.resourceId;
    try {
      const reply = await bridge.delete({
        version: 1,
        mutationId: canonicalMutationId(),
        resourceId,
        expectedCurrentVersionId: editable.resourceVersionId,
      });
      if (!laneIsCurrent("mutation", token) || !contextIsCurrent(contextGeneration, resourceId)) {
        return;
      }
      if (reply.ok && reply.accepted && store.acceptMutation(token, true)) {
        completeMutationContext();
        setRailMode("trash");
        setDrawer("closed");
        setMergeMode(false);
        setNotice({ tone: "info", text: "Note moved to Trash." });
      } else {
        setNotice({ tone: "error", text: "Delete was not accepted. The note may have changed." });
      }
    } catch {
      if (laneIsCurrent("mutation", token) && contextIsCurrent(contextGeneration, resourceId)) {
        setNotice({ tone: "error", text: "Delete could not be completed." });
      }
    } finally {
      finishMutation(token);
    }
  }

  async function restore(item: NoteTrashPage["items"][number]): Promise<void> {
    if (mutationBusyRef.current || terminal) return;
    const token = beginMutation();
    if (!token) return;
    const contextGeneration = contextGenerationRef.current;
    const resourceId = item.summary.resourceId;
    try {
      const reply = await bridge.restore({
        version: 1,
        mutationId: canonicalMutationId(),
        resourceId,
      });
      if (!laneIsCurrent("mutation", token) || !contextIsCurrent(contextGeneration)) return;
      if (
        reply.ok &&
        reply.result.resourceId === resourceId &&
        store.acceptMutation(token, reply.result)
      ) {
        completeMutationContext();
        setTrashItems((items) => items.filter(({ summary }) => summary.resourceId !== resourceId));
        setRailMode("current");
        setNotice({ tone: "info", text: "Note restored." });
      } else {
        setNotice({ tone: "error", text: "Restore could not be completed." });
      }
    } catch {
      if (laneIsCurrent("mutation", token) && contextIsCurrent(contextGeneration)) {
        setNotice({ tone: "error", text: "Restore could not be completed." });
      }
    } finally {
      finishMutation(token);
    }
  }

  function beginMerge(): void {
    const detail = snapshot.conflict?.detail;
    if (!detail) return;
    updateLocalDraft({ title: detail.competing.title, markdown: detail.competing.markdown });
    setMergeMode(true);
    setActivePanel("editor");
    setNotice({ tone: "info", text: "Merge mode. Edit the result, then choose Save merge." });
  }

  function handleKeyDown(event: ReactKeyboardEvent<HTMLElement>): void {
    const commandSave = (event.ctrlKey || event.metaKey) && event.key.toLowerCase() === "s";
    if (pendingAction) {
      if (commandSave) {
        event.preventDefault();
      } else if (event.key === "Escape") {
        event.preventDefault();
        stay();
      }
      return;
    }
    if (commandSave) {
      event.preventDefault();
      void saveDraft();
      return;
    }
    if (event.key !== "Escape") return;
    if (drawer !== "closed") {
      event.preventDefault();
      closeDrawer();
    }
  }

  if (terminal) {
    return (
      <section
        className="notes-workspace notes-workspace-terminal"
        aria-label="Private notes workspace"
      >
        <section className="notes-empty" role="status" aria-live="polite">
          <p className="notes-kicker">Private notes</p>
          <h1>Vault access ended</h1>
          <p>Unlock the vault to open this workspace again.</p>
        </section>
      </section>
    );
  }

  return (
    <section
      className={`notes-workspace${drawer === "closed" ? "" : " has-drawer"}`}
      data-active-panel={activePanel}
      aria-label="Private notes workspace"
      onKeyDown={handleKeyDown}
    >
      <div
        className="notes-workspace-background"
        inert={pendingAction ? true : undefined}
        aria-hidden={pendingAction ? true : undefined}
      >
        <nav className="notes-panel-switcher" aria-label="Workspace panels">
          <button type="button" onClick={() => setActivePanel("rail")} aria-controls="notes-rail">
            Show notes
          </button>
          <button
            type="button"
            onClick={() => setActivePanel("editor")}
            aria-controls="notes-editor"
          >
            Show editor
          </button>
          <button
            type="button"
            onClick={() => setActivePanel("drawer")}
            aria-controls={drawer === "closed" ? undefined : "notes-drawer"}
            disabled={drawer === "closed"}
          >
            Show details
          </button>
        </nav>

        <aside id="notes-rail" className="notes-rail" aria-label="Notes rail" data-panel="rail">
          <header className="notes-rail-heading">
            <div>
              <p className="notes-kicker">Private notes</p>
              <h1>Workbench</h1>
            </div>
            <span className="notes-count">
              {railMode === "current" ? snapshot.summaries.length : trashItems.length}
            </span>
          </header>

          <button
            type="button"
            className="notes-save notes-new"
            onClick={(event) => requestNew(event.currentTarget)}
          >
            New note
          </button>

          <form role="search" className="notes-search" onSubmit={search}>
            <label htmlFor="notes-query">Search current notes</label>
            <div>
              <input
                id="notes-query"
                ref={queryInputRef}
                aria-label="Search notes"
                value={query}
                onChange={(event) => setQuery(event.currentTarget.value)}
                maxLength={1024}
              />
              <button type="submit" disabled={listBusy}>
                Search
              </button>
            </div>
          </form>

          <div className="notes-rail-tabs" aria-label="Note lists">
            <button
              type="button"
              aria-pressed={railMode === "current"}
              onClick={() => setRailMode("current")}
            >
              Current
            </button>
            <button
              type="button"
              aria-pressed={railMode === "trash"}
              onClick={() => void loadTrash()}
            >
              Trash
            </button>
          </div>

          <ul
            className="notes-list"
            aria-label={railMode === "current" ? "Current notes" : "Trash"}
          >
            {railMode === "current"
              ? snapshot.summaries.map((item) => (
                  <li key={`${item.resourceId}:${item.resourceVersionId}`}>
                    <button
                      type="button"
                      className="notes-list-item"
                      aria-label={`Open ${item.title}`}
                      aria-current={
                        !creating && selection?.resourceId === item.resourceId ? "true" : undefined
                      }
                      onClick={(event) => requestOpen(item, event.currentTarget)}
                    >
                      <span>{item.title}</span>
                      <small>v{item.displayVersion}</small>
                    </button>
                  </li>
                ))
              : trashItems.map((item) => (
                  <li key={item.summary.resourceId} className="notes-trash-item">
                    <span>{item.summary.title}</span>
                    <button
                      type="button"
                      onClick={() => void restore(item)}
                      disabled={mutationBusy}
                    >
                      Restore {item.summary.title}
                    </button>
                  </li>
                ))}
          </ul>
        </aside>

        <section
          id="notes-editor"
          className="notes-editor"
          aria-label="Markdown editor"
          data-panel="editor"
        >
          {(creating || editable) && draft ? (
            <>
              <header className="notes-editor-heading">
                <div>
                  <p className="notes-kicker">
                    {mergeMode ? "Merge mode" : creating ? "New note" : "Current note"}
                  </p>
                  <p className="notes-version">
                    {creating
                      ? "New · Unsaved"
                      : `Version ${editable?.displayVersion} · ${
                          snapshot.dirty ? "Unsaved changes" : "Saved"
                        }`}
                  </p>
                </div>
                <div className="notes-editor-actions" aria-label="Note actions">
                  <button
                    type="button"
                    onClick={(event) => showDrawer("preview", event.currentTarget)}
                  >
                    Preview
                  </button>
                  {!creating && (
                    <>
                      <button
                        type="button"
                        onClick={(event) => void loadHistory(event.currentTarget)}
                      >
                        History
                      </button>
                      <button
                        type="button"
                        onClick={(event) => void loadConflict(event.currentTarget)}
                        disabled={!snapshot.conflict}
                      >
                        Conflict
                      </button>
                    </>
                  )}
                </div>
              </header>

              <label className="notes-title-field">
                <span>Title</span>
                <input
                  ref={editorTitleRef}
                  aria-label="Note title"
                  value={draft.title}
                  maxLength={255}
                  onChange={(event) =>
                    updateDraft({ title: event.currentTarget.value, markdown: draft.markdown })
                  }
                />
              </label>
              <label className="notes-markdown-field">
                <span>Markdown</span>
                <textarea
                  aria-label="Markdown source"
                  value={draft.markdown}
                  onChange={(event) =>
                    updateDraft({ title: draft.title, markdown: event.currentTarget.value })
                  }
                  spellCheck="true"
                />
              </label>

              <footer className="notes-editor-footer">
                <div className="notes-secondary-actions">
                  {!creating && editable && (
                    <>
                      <a
                        href={`/api/v1/notes/${encodeURIComponent(editable.resourceId)}/export`}
                        aria-label={`Export ${editable.title}`}
                      >
                        Export Markdown
                      </a>
                      <button
                        type="button"
                        className="notes-delete"
                        onClick={() => void deleteCurrent()}
                      >
                        Delete
                      </button>
                    </>
                  )}
                </div>
                <button
                  type="button"
                  className="notes-save"
                  disabled={!canSave}
                  onClick={() => void saveDraft()}
                >
                  {mergeMode ? "Save merge" : "Save"}
                </button>
              </footer>
            </>
          ) : selection ? (
            <section className="notes-empty" aria-labelledby="pinned-note-heading">
              <p className="notes-kicker">Pinned history</p>
              <h2 id="pinned-note-heading">Read-only version</h2>
              <p>This pinned version is no longer current. Review it in History or open current.</p>
            </section>
          ) : (
            <section className="notes-empty" aria-labelledby="select-note-heading">
              <p className="notes-kicker">Markdown canvas</p>
              <h2 id="select-note-heading">Select a note</h2>
              <p>Choose a current note from the rail to begin editing.</p>
            </section>
          )}
        </section>

        <div
          aria-label="Workspace details"
          data-panel="drawer-controls"
          className="notes-drawer-slot"
        >
          {drawer !== "closed" && (
            <aside
              id="notes-drawer"
              className="notes-drawer"
              aria-label={`${drawer[0].toUpperCase()}${drawer.slice(1)} drawer`}
            >
              <header className="notes-drawer-heading">
                <div>
                  <p className="notes-kicker">On demand</p>
                  <h2>{drawer}</h2>
                </div>
                <button ref={drawerCloseRef} type="button" onClick={closeDrawer}>
                  Close details
                </button>
              </header>

              {drawer === "preview" && draft && (
                <article className="notes-preview" aria-label="Safe Markdown preview">
                  <SafeMarkdown markdown={draft.markdown} />
                </article>
              )}

              {drawer === "history" && selection && !editable && (
                <section className="notes-pinned-snapshot">
                  <h3>{selection.title}</h3>
                  <textarea
                    aria-label="Pinned Markdown snapshot"
                    value={selection.markdown}
                    readOnly
                  />
                  <button
                    type="button"
                    onClick={() => void openVersion(selection.resourceId, null, true)}
                  >
                    Open current
                  </button>
                </section>
              )}

              {drawer === "history" && editable && (
                <ol className="notes-history">
                  {snapshot.history.map((item) => (
                    <li key={item.resourceVersionId}>
                      <button
                        type="button"
                        onClick={() =>
                          void openVersion(editable.resourceId, item.resourceVersionId, true)
                        }
                      >
                        {versionLabel(item)}
                      </button>
                    </li>
                  ))}
                </ol>
              )}

              {drawer === "conflict" && snapshot.conflict?.detail && (
                <section className="notes-conflict">
                  <div>
                    <h3>Current</h3>
                    <textarea
                      aria-label="Current"
                      value={snapshot.conflict.detail.current.markdown}
                      readOnly
                    />
                  </div>
                  <div>
                    <h3>Competing</h3>
                    <textarea
                      aria-label="Competing"
                      value={snapshot.conflict.detail.competing.markdown}
                      readOnly
                    />
                  </div>
                  <button type="button" onClick={beginMerge}>
                    Merge these versions
                  </button>
                </section>
              )}

              {drawer === "conflict" && snapshot.conflict && !snapshot.conflict.detail && (
                <p className="notes-drawer-loading" role="status">
                  Open Conflict again to load both versions.
                </p>
              )}
            </aside>
          )}
        </div>

        <div
          className={`notes-notice${notice?.tone === "error" ? " is-error" : ""}`}
          role={notice?.tone === "error" ? "alert" : "status"}
          aria-live="polite"
          aria-label="Notes workspace status"
        >
          {notice?.text ?? "Workspace ready."}
        </div>
      </div>

      {pendingAction && (
        <div className="notes-dialog-scrim">
          <section
            ref={dialogRef}
            className="notes-dialog"
            role="dialog"
            aria-modal="true"
            aria-busy={dialogBusy}
            aria-labelledby="dirty-dialog-title"
            aria-describedby="dirty-dialog-description"
          >
            <p className="notes-kicker">Unsaved draft</p>
            <h2 id="dirty-dialog-title">Discard your changes?</h2>
            <p id="dirty-dialog-description">
              Stay here to keep editing, or discard the local draft and continue.
            </p>
            {dialogError && <p role="alert">{dialogError}</p>}
            <div>
              <button ref={stayButtonRef} type="button" aria-disabled={dialogBusy} onClick={stay}>
                Stay
              </button>
              <button
                type="button"
                className="notes-delete"
                aria-disabled={dialogBusy}
                onClick={() => void discard()}
              >
                Discard
              </button>
            </div>
          </section>
        </div>
      )}
    </section>
  );
}
