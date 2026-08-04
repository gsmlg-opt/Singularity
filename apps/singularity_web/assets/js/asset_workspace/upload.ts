import type { AssetProgress, Bridge, UploadGrant, UploadGrantReply } from "./contracts";

type LocationLike = {
  href: string;
  origin: string;
};

export type UploadAttemptResult =
  | { ok: true }
  | { ok: false; reason: "cancelled" }
  | { ok: false; reason: "expired" }
  | { ok: false; reason: "grant" }
  | { ok: false; reason: "network" }
  | { ok: false; reason: "reused" }
  | { ok: false; reason: "server"; status: number }
  | { ok: false; reason: "unsafe_target" };

export type UploadAttemptOptions = {
  bridge: Pick<Bridge, "grant" | "cancel">;
  file: File;
  csrfToken: string;
  idempotencyKey: string;
  onProgress?: (progress: AssetProgress) => void;
  xhrFactory?: () => XMLHttpRequest;
  now?: () => number;
  location?: LocationLike;
};

export type UploadAttempt = {
  start(): Promise<UploadAttemptResult>;
  abort(): void;
};

export type UploadAttemptFactory = (options: UploadAttemptOptions) => UploadAttempt;

function defaultLocation(): LocationLike | null {
  try {
    return typeof window === "undefined"
      ? null
      : { href: window.location.href, origin: window.location.origin };
  } catch {
    return null;
  }
}

function isUploadGrant(reply: UploadGrantReply): reply is UploadGrant {
  return (
    reply.ok === true &&
    typeof reply.grantId === "string" &&
    typeof reply.uploadToken === "string" &&
    typeof reply.uploadUrl === "string" &&
    typeof reply.expiresAt === "string"
  );
}

function safeProgress(
  callback: UploadAttemptOptions["onProgress"],
  progress: Exclude<AssetProgress, null>,
): void {
  try {
    callback?.(progress);
  } catch {
    // Progress rendering must not alter transport completion.
  }
}

export function readCsrfToken(documentLike?: Document): string {
  try {
    const source = documentLike ?? (typeof document === "undefined" ? undefined : document);
    return (
      source?.querySelector<HTMLMetaElement>('meta[name="csrf-token"]')?.getAttribute("content") ??
      ""
    );
  } catch {
    return "";
  }
}

export const createUploadAttempt: UploadAttemptFactory = (options) => {
  let activeXhr: XMLHttpRequest | null = null;
  let cancelled = false;
  let cancellation: Promise<void> | null = null;
  let issuedGrantId: string | null = null;
  let settled = false;
  let started = false;

  const cancelGrant = (grantId: string): Promise<void> => {
    cancellation ??= (async () => {
      try {
        await options.bridge.cancel({ version: 1, grantId });
      } catch {
        // Cancellation is best-effort; the server-side grant expiry remains authoritative.
      }
    })();

    return cancellation;
  };

  const start = async (): Promise<UploadAttemptResult> => {
    if (started) {
      return { ok: false, reason: "reused" };
    }
    started = true;

    let reply: UploadGrantReply;

    try {
      reply = await options.bridge.grant({
        version: 1,
        filename: options.file.name,
        size: options.file.size,
        mediaType: options.file.type,
        idempotencyKey: options.idempotencyKey,
      });
    } catch {
      return cancelled ? { ok: false, reason: "cancelled" } : { ok: false, reason: "grant" };
    }

    if (!isUploadGrant(reply)) {
      return cancelled ? { ok: false, reason: "cancelled" } : { ok: false, reason: "grant" };
    }

    issuedGrantId = reply.grantId;

    if (cancelled) {
      await cancelGrant(reply.grantId);
      return { ok: false, reason: "cancelled" };
    }

    let expiresAt: number;
    let currentTime: number;

    try {
      expiresAt = Date.parse(reply.expiresAt);
      currentTime = (options.now ?? Date.now)();
    } catch {
      await cancelGrant(reply.grantId);
      return { ok: false, reason: "expired" };
    }

    if (!Number.isFinite(expiresAt) || expiresAt <= currentTime) {
      await cancelGrant(reply.grantId);
      return { ok: false, reason: "expired" };
    }

    const location = options.location ?? defaultLocation();

    if (!location) {
      await cancelGrant(reply.grantId);
      return { ok: false, reason: "unsafe_target" };
    }

    let uploadUrl: URL;

    try {
      uploadUrl = new URL(reply.uploadUrl, location.href);
    } catch {
      await cancelGrant(reply.grantId);
      return { ok: false, reason: "unsafe_target" };
    }

    if (uploadUrl.origin !== location.origin) {
      await cancelGrant(reply.grantId);
      return { ok: false, reason: "unsafe_target" };
    }

    if (cancelled) {
      await cancelGrant(reply.grantId);
      return { ok: false, reason: "cancelled" };
    }

    let xhr: XMLHttpRequest;

    try {
      xhr = (options.xhrFactory ?? (() => new XMLHttpRequest()))();
      activeXhr = xhr;
      xhr.open("PUT", uploadUrl.href, true);
      xhr.setRequestHeader("x-upload-token", reply.uploadToken);
      xhr.setRequestHeader("x-csrf-token", options.csrfToken);
    } catch {
      activeXhr = null;
      await cancelGrant(reply.grantId);
      return { ok: false, reason: "network" };
    }

    return new Promise<UploadAttemptResult>((resolve) => {
      const complete = (result: UploadAttemptResult, retireGrant = true): void => {
        if (settled) {
          return;
        }

        settled = true;
        activeXhr = null;

        void (async () => {
          if (retireGrant) {
            await cancelGrant(reply.grantId);
          }
          resolve(result);
        })();
      };

      xhr.upload.onprogress = (event) => {
        safeProgress(options.onProgress, {
          kind: "bytes",
          sent: event.loaded,
          total: event.total,
        });
      };
      xhr.onabort = () => complete({ ok: false, reason: "cancelled" });
      xhr.onerror = () => complete({ ok: false, reason: "network" });
      xhr.onload = () => {
        if (xhr.status === 201) {
          safeProgress(options.onProgress, { kind: "complete" });
          complete({ ok: true }, false);
        } else {
          complete({ ok: false, reason: "server", status: xhr.status });
        }
      };

      try {
        xhr.send(options.file);
      } catch {
        complete({ ok: false, reason: "network" });
      }
    });
  };

  return {
    start,
    abort: () => {
      if (!started || settled) {
        return;
      }

      cancelled = true;

      if (issuedGrantId) {
        void cancelGrant(issuedGrantId);
      }

      try {
        activeXhr?.abort();
      } catch {
        // The pending start observes the cancellation flag.
      }
    },
  };
};
