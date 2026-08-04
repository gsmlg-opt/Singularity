import { beforeEach, describe, expect, it, vi } from "vitest";

import type { Bridge, UploadGrant } from "../js/asset_workspace/contracts";
import {
  createUploadAttempt,
  readCsrfToken,
  type UploadAttemptOptions,
} from "../js/asset_workspace/upload";

const grant: UploadGrant = {
  ok: true,
  grantId: "grant-1",
  uploadToken: "UPLOAD_TOKEN_CANARY",
  uploadUrl: "/api/v1/uploads/grant-1",
  expiresAt: "2026-08-01T00:00:00Z",
};

class FakeXMLHttpRequest {
  readonly headers = new Map<string, string>();
  readonly upload: {
    onprogress: ((event: ProgressEvent<EventTarget>) => void) | null;
  } = { onprogress: null };

  method: string | null = null;
  url: string | null = null;
  async: boolean | null = null;
  body: Document | XMLHttpRequestBodyInit | null = null;
  status = 0;
  onabort: ((event: ProgressEvent<EventTarget>) => void) | null = null;
  onerror: ((event: ProgressEvent<EventTarget>) => void) | null = null;
  onload: ((event: ProgressEvent<EventTarget>) => void) | null = null;

  open(method: string, url: string | URL, async = true) {
    this.method = method;
    this.url = String(url);
    this.async = async;
  }

  setRequestHeader(name: string, value: string) {
    this.headers.set(name.toLowerCase(), value);
  }

  send(body: Document | XMLHttpRequestBodyInit | null = null) {
    this.body = body;
  }

  abort() {
    this.onabort?.(new ProgressEvent("abort"));
  }

  progress(loaded: number, total: number) {
    this.upload.onprogress?.({
      lengthComputable: true,
      loaded,
      total,
    } as ProgressEvent<EventTarget>);
  }

  finish(status: number) {
    this.status = status;
    this.onload?.(new ProgressEvent("load"));
  }

  fail() {
    this.onerror?.(new ProgressEvent("error"));
  }
}

function options(
  xhr: FakeXMLHttpRequest,
  overrides: Partial<UploadAttemptOptions> = {},
): UploadAttemptOptions {
  const bridge = {
    grant: vi.fn(async () => grant),
    cancel: vi.fn(async () => ({ ok: true as const, accepted: true })),
  } as unknown as UploadAttemptOptions["bridge"];

  return {
    bridge,
    file: new File(["archive"], "archive.pdf", {
      type: "application/pdf",
    }),
    csrfToken: "CSRF_TOKEN_CANARY",
    idempotencyKey: "attempt-1",
    xhrFactory: () => xhr as unknown as XMLHttpRequest,
    now: () => Date.parse("2026-07-31T00:00:00Z"),
    location: {
      href: "https://vault.test/assets",
      origin: "https://vault.test",
    },
    ...overrides,
  };
}

async function startTransport() {
  await Promise.resolve();
  await Promise.resolve();
}

describe("same-origin granted upload", () => {
  beforeEach(() => {
    document.head.replaceChildren();
  });

  it("reads the dedicated CSRF meta tag without moving it into workspace state", () => {
    const meta = document.createElement("meta");
    meta.name = "csrf-token";
    meta.content = "CSRF_TOKEN_CANARY";
    document.head.append(meta);

    expect(readCsrfToken(document)).toBe("CSRF_TOKEN_CANARY");
    expect(readCsrfToken(document.implementation.createHTMLDocument())).toBe("");
  });

  it("requests one grant, sends exact headers, reports bytes, and completes", async () => {
    const xhr = new FakeXMLHttpRequest();
    const progress = vi.fn();
    const uploadOptions = options(xhr, { onProgress: progress });
    const attempt = createUploadAttempt(uploadOptions);

    const completed = attempt.start();
    await startTransport();

    expect(uploadOptions.bridge.grant).toHaveBeenCalledWith({
      version: 1,
      filename: "archive.pdf",
      size: 7,
      mediaType: "application/pdf",
      idempotencyKey: "attempt-1",
    });
    expect(xhr.method).toBe("PUT");
    expect(xhr.url).toBe("https://vault.test/api/v1/uploads/grant-1");
    expect(xhr.async).toBe(true);
    expect(xhr.headers.get("x-upload-token")).toBe("UPLOAD_TOKEN_CANARY");
    expect(xhr.headers.get("x-csrf-token")).toBe("CSRF_TOKEN_CANARY");
    expect(xhr.body).toBe(uploadOptions.file);

    xhr.progress(3, 7);
    expect(progress).toHaveBeenLastCalledWith({
      kind: "bytes",
      sent: 3,
      total: 7,
    });

    xhr.finish(201);
    await expect(completed).resolves.toEqual({ ok: true });
    expect(progress).toHaveBeenLastCalledWith({ kind: "complete" });
  });

  it("opens the validated URL instead of resolving against a hostile document base", async () => {
    const base = document.createElement("base");
    base.href = "https://hostile.test/";
    document.head.append(base);
    const xhr = new FakeXMLHttpRequest();
    const attempt = createUploadAttempt(options(xhr));
    const completed = attempt.start();
    await startTransport();

    expect(xhr.url).toBe("https://vault.test/api/v1/uploads/grant-1");

    xhr.finish(201);
    await expect(completed).resolves.toEqual({ ok: true });
  });

  it("returns a stable server error without exposing tokens", async () => {
    const xhr = new FakeXMLHttpRequest();
    const cancel = vi.fn(async () => ({ ok: true as const, accepted: false }));
    const bridge = {
      grant: vi.fn(async () => grant),
      cancel,
    } as unknown as UploadAttemptOptions["bridge"];
    const attempt = createUploadAttempt(options(xhr, { bridge }));
    const completed = attempt.start();
    await startTransport();

    xhr.finish(503);

    const result = await completed;
    expect(result).toEqual({ ok: false, reason: "server", status: 503 });
    expect(cancel).toHaveBeenCalledWith({ version: 1, grantId: "grant-1" });
    expect(JSON.stringify(result)).not.toContain("UPLOAD_TOKEN_CANARY");
    expect(JSON.stringify(result)).not.toContain("CSRF_TOKEN_CANARY");
  });

  it.each([200, 204])("treats HTTP %i as a stable server failure", async (status) => {
    const xhr = new FakeXMLHttpRequest();
    const attempt = createUploadAttempt(options(xhr));
    const completed = attempt.start();
    await startTransport();

    xhr.finish(status);

    await expect(completed).resolves.toEqual({
      ok: false,
      reason: "server",
      status,
    });
  });

  it("aborts an active request and reports deterministic cancellation", async () => {
    const xhr = new FakeXMLHttpRequest();
    const cancel = vi.fn(async () => ({ ok: true as const, accepted: false }));
    const bridge = {
      grant: vi.fn(async () => grant),
      cancel,
    } as unknown as UploadAttemptOptions["bridge"];
    const attempt = createUploadAttempt(options(xhr, { bridge }));
    const completed = attempt.start();
    await startTransport();

    attempt.abort();

    await expect(completed).resolves.toEqual({
      ok: false,
      reason: "cancelled",
    });
    expect(cancel).toHaveBeenCalledWith({ version: 1, grantId: "grant-1" });
  });

  it("retires a grant that arrives after cancellation before transport starts", async () => {
    let resolveGrant: ((value: UploadGrant) => void) | undefined;
    const pendingGrant = new Promise<UploadGrant>((resolve) => {
      resolveGrant = resolve;
    });
    let resolveCancel: ((value: { ok: true; accepted: true }) => void) | undefined;
    const pendingCancel = new Promise<{ ok: true; accepted: true }>((resolve) => {
      resolveCancel = resolve;
    });
    const cancel = vi.fn(() => pendingCancel);
    const bridge = {
      grant: vi.fn(() => pendingGrant),
      cancel,
    } as unknown as UploadAttemptOptions["bridge"];
    const xhrFactory = vi.fn(() => new FakeXMLHttpRequest() as unknown as XMLHttpRequest);
    const xhr = new FakeXMLHttpRequest();
    const attempt = createUploadAttempt(options(xhr, { bridge, xhrFactory }));

    const completed = attempt.start();
    attempt.abort();
    resolveGrant?.(grant);

    let settled = false;
    void completed.then(() => {
      settled = true;
    });
    await startTransport();

    expect(cancel).toHaveBeenCalledWith({ version: 1, grantId: "grant-1" });
    expect(settled).toBe(false);

    resolveCancel?.({ ok: true, accepted: true });

    await expect(completed).resolves.toEqual({
      ok: false,
      reason: "cancelled",
    });
    expect(xhrFactory).not.toHaveBeenCalled();
    expect(JSON.stringify(cancel.mock.calls)).not.toContain("UPLOAD_TOKEN_CANARY");
  });

  it("rejects an expired grant before creating or sending a request", async () => {
    const cancel = vi.fn(async () => ({ ok: true as const, accepted: true }));
    const bridge = {
      grant: vi.fn(async () => grant),
      cancel,
    } as unknown as UploadAttemptOptions["bridge"];
    const xhrFactory = vi.fn(() => new FakeXMLHttpRequest() as unknown as XMLHttpRequest);
    const xhr = new FakeXMLHttpRequest();
    const attempt = createUploadAttempt(
      options(xhr, {
        bridge,
        xhrFactory,
        now: () => Date.parse("2026-08-01T00:00:00Z"),
      }),
    );

    await expect(attempt.start()).resolves.toEqual({
      ok: false,
      reason: "expired",
    });
    expect(cancel).toHaveBeenCalledWith({ version: 1, grantId: "grant-1" });
    expect(xhrFactory).not.toHaveBeenCalled();
  });

  it("prevents reuse of one attempt and never requests a second token", async () => {
    const xhr = new FakeXMLHttpRequest();
    const uploadOptions = options(xhr);
    const attempt = createUploadAttempt(uploadOptions);
    const first = attempt.start();
    await startTransport();

    await expect(attempt.start()).resolves.toEqual({
      ok: false,
      reason: "reused",
    });
    expect(uploadOptions.bridge.grant).toHaveBeenCalledTimes(1);

    xhr.finish(201);
    await expect(first).resolves.toEqual({ ok: true });
  });

  it("refuses a cross-origin grant URL before sending bytes", async () => {
    const xhrFactory = vi.fn(() => new FakeXMLHttpRequest() as unknown as XMLHttpRequest);
    const xhr = new FakeXMLHttpRequest();
    const bridge = {
      grant: vi.fn(async () => ({
        ...grant,
        uploadUrl: "https://other.test/api/v1/uploads/grant-1",
      })),
    } as unknown as Pick<Bridge, "grant">;
    const attempt = createUploadAttempt(options(xhr, { bridge, xhrFactory }));

    await expect(attempt.start()).resolves.toEqual({
      ok: false,
      reason: "unsafe_target",
    });
    expect(xhrFactory).not.toHaveBeenCalled();
  });
});
