import { createElement, type ComponentType, type ReactNode } from "react";
import { createRoot } from "react-dom/client";

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
  unavailable,
  type ConflictRequest,
  type CreateRequest,
  type DeleteRequest,
  type HistoryRequest,
  type MergeRequest,
  type NavigationTarget,
  type NotesBridge,
  type OpenRequest,
  type RestoreRequest,
  type SaveRequest,
  type SearchRequest,
  type TrashRequest,
} from "../notes_workspace/contracts";
import { WorkspaceStore } from "../notes_workspace/state";

export type HookContext = {
  el: HTMLElement;
  handleEvent(name: string, handler: (payload: unknown) => void): unknown;
  pushEvent(event: string, payload: unknown): Promise<unknown>;
};

type Root = { render(node: ReactNode): void; unmount(): void };
export type NotesWorkspaceProps = { bridge: NotesBridge; store: WorkspaceStore };
export type NotesWorkspaceModule = { NotesWorkspace: ComponentType<NotesWorkspaceProps> };
type Dependencies = {
  createRoot(element: HTMLElement): Root;
  loadWorkspace(): Promise<NotesWorkspaceModule>;
};
type Mounted = {
  destroyed: boolean;
  unmounted: boolean;
  root: Root;
  store?: WorkspaceStore;
  expiryTimer?: ReturnType<typeof setTimeout>;
};

const unavailableMessage = "Notes workspace is unavailable.";
const maxTimerDelay = 2_147_483_647;
const alert = (): ReactNode => createElement("div", { role: "alert" }, unavailableMessage);
const workspaceModules = import.meta.glob<NotesWorkspaceModule>(
  "../notes_workspace/NotesWorkspace.tsx",
);

function defaultLoader(): Promise<NotesWorkspaceModule> {
  const load = workspaceModules["../notes_workspace/NotesWorkspace.tsx"];
  return load ? load() : Promise.reject(new Error(unavailableMessage));
}

function parseProps(element: HTMLElement) {
  try {
    return decodeInitialProps(JSON.parse(element.dataset.props ?? ""));
  } catch {
    return null;
  }
}

function scheduleExpiry(state: Mounted, expiresAt: string | null): void {
  if (expiresAt === null) return;
  const expiry = Date.parse(expiresAt);

  const schedule = () => {
    if (state.destroyed) return;
    const remaining = expiry - Date.now();
    if (remaining <= 0) {
      state.expiryTimer = undefined;
      state.store?.purgePrivateState("expiry");
      return;
    }
    state.expiryTimer = setTimeout(schedule, Math.min(remaining, maxTimerDelay));
  };

  schedule();
}

export function createMountNotesWorkspace(
  dependencies: Dependencies = { createRoot, loadWorkspace: defaultLoader },
) {
  const mounted = new WeakMap<HookContext, Mounted>();

  return {
    mounted(this: HookContext) {
      const root = dependencies.createRoot(this.el);
      const state: Mounted = { destroyed: false, unmounted: false, root };
      mounted.set(this, state);
      const initial = parseProps(this.el);
      if (!initial) {
        root.render(alert());
        return;
      }

      const store = new WorkspaceStore(initial);
      state.store = store;
      scheduleExpiry(state, initial.vault.expiresAt);
      const bridge = bridgeFor(this, store);
      let loading: Promise<NotesWorkspaceModule>;
      try {
        loading = dependencies.loadWorkspace();
      } catch {
        root.render(alert());
        return;
      }

      void loading
        .then(({ NotesWorkspace }) => {
          if (!state.destroyed) root.render(createElement(NotesWorkspace, { bridge, store }));
        })
        .catch(() => {
          if (!state.destroyed) root.render(alert());
        });
    },

    destroyed(this: HookContext) {
      const state = mounted.get(this);
      if (!state || state.unmounted) return;
      state.destroyed = true;
      state.unmounted = true;
      if (state.expiryTimer !== undefined) clearTimeout(state.expiryTimer);
      state.expiryTimer = undefined;
      state.root.unmount();
    },
  };
}

function bridgeFor(context: HookContext, store: WorkspaceStore): NotesBridge {
  const push = async <T,>(
    event: string,
    payload: unknown,
    decode: (value: unknown) => T,
  ): Promise<T> => {
    try {
      const reply = decode(await context.pushEvent(event, payload));
      if (typeof reply === "object" && reply !== null && "ok" in reply && reply.ok === false) {
        const code = (reply as { error: { code: string } }).error.code;
        if (code === "unauthenticated" || code === "vault_locked") {
          store.purgePrivateState(code);
        }
      }
      return reply;
    } catch {
      return unavailable() as T;
    }
  };
  const invalid = async <T,>() => ({ ok: false, error: { code: "invalid" } }) as T;

  return {
    search: (value: SearchRequest) => {
      const request = decodeSearchRequest(value);
      return request ? push("note:search", request, decodeSearchReply) : invalid();
    },
    trash: (value: TrashRequest) => {
      const request = decodeTrashRequest(value);
      return request ? push("note:trash", request, decodeTrashReply) : invalid();
    },
    open: (value: OpenRequest) => {
      const request = decodeOpenRequest(value);
      return request ? push("note:open", request, decodeOpenReply) : invalid();
    },
    create: (value: CreateRequest) => {
      const request = decodeCreateRequest(value);
      return request ? push("note:create", request, decodeCreateReply) : invalid();
    },
    save: (value: SaveRequest) => {
      const request = decodeSaveRequest(value);
      return request ? push("note:save", request, decodeSaveReply) : invalid();
    },
    history: (value: HistoryRequest) => {
      const request = decodeHistoryRequest(value);
      return request ? push("note:history", request, decodeHistoryReply) : invalid();
    },
    conflict: (value: ConflictRequest) => {
      const request = decodeConflictRequest(value);
      return request ? push("note:conflict", request, decodeConflictReply) : invalid();
    },
    merge: (value: MergeRequest) => {
      const request = decodeMergeRequest(value);
      return request ? push("note:merge", request, decodeMergeReply) : invalid();
    },
    delete: (value: DeleteRequest) => {
      const request = decodeDeleteRequest(value);
      return request ? push("note:delete", request, decodeDeleteReply) : invalid();
    },
    restore: (value: RestoreRequest) => {
      const request = decodeRestoreRequest(value);
      return request ? push("note:restore", request, decodeRestoreReply) : invalid();
    },
    navigate: (to: NavigationTarget) => {
      const request = decodeNavigationRequest({ version: 1, to });
      return request ? push("navigate", request, decodeNavigationReply) : invalid();
    },
  };
}

export const MountNotesWorkspace = createMountNotesWorkspace();
