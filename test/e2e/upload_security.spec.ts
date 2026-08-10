import type { Page } from "@playwright/test";

import {
  deriveBrowserTestOwnerPassword,
  expect,
  test,
  unlockVault,
} from "./support/fixtures";

declare const process: {
  env: Record<string, string | undefined>;
};

test.use({ screenshot: "off", trace: "off", video: "off" });

type SecretCategory = "owner-password" | "backup-passphrase" | "upload-token" | "csrf-token";
type SecretCanaries = Partial<Record<SecretCategory, string>>;
type CsrfOccurrenceKind =
  | "meta-tag"
  | "live-socket-param"
  | "controller-form-field"
  | "xhr-header";

type CapturedFrame = {
  direction: "received" | "sent";
  payload: unknown;
};

type CapturedResponse = {
  kind: "application-json" | "html" | "no-consumed-body";
  status: number;
  path: string;
  url: string;
  headers: Record<string, string>;
  body?: string;
};

type CapturedXhrResponseBody = {
  method: string;
  status: number;
  url: string;
  body: string;
};

type PendingXhrApplicationResponse = {
  captureIndex: number;
  kind: "application-json" | "html";
  method: string;
  status: number;
  path: string;
  url: string;
  headers: Record<string, string>;
};

type CapturedRequest = {
  method: string;
  origin: string;
  path: string;
  search: string;
  headers: Record<string, string>;
};

type DocumentSnapshot = {
  label: string;
  sanitizedHtml: string;
  dataProps: string[];
};

type LiveSecretFinding = {
  kind: string;
  path: string;
};

type RenderedControllerLeaf = {
  html: string;
  marker: string;
};

type NormalizedErrorSurface = {
  complete: boolean;
  surface: unknown;
};

const expectedCsrfOccurrenceKinds: CsrfOccurrenceKind[] = [
  "meta-tag",
  "live-socket-param",
  "controller-form-field",
  "xhr-header",
];

function occurrencePaths(value: unknown, canary: string, path: string[] = []): string[][] {
  if (typeof value === "string") {
    return value.includes(canary) ? [path] : [];
  }

  if (Array.isArray(value)) {
    return value.flatMap((entry, index) => occurrencePaths(entry, canary, [...path, `${index}`]));
  }

  if (value !== null && typeof value === "object") {
    return Object.entries(value).flatMap(([key, entry], index) => {
      const secretBearingKey = key.includes(canary);
      const keySegment = `<object-key:${index}>`;
      const keyOccurrences = secretBearingKey ? [[...path, keySegment]] : [];

      return [...keyOccurrences, ...occurrencePaths(entry, canary, [...path, key])];
    });
  }

  return [];
}

function valueAtPath(value: unknown, path: string[]): unknown {
  return path.reduce<unknown>((current, segment) => {
    if (Array.isArray(current)) {
      const index = Number.parseInt(segment, 10);
      return Number.isInteger(index) ? current[index] : undefined;
    }

    if (current !== null && typeof current === "object") {
      return (current as Record<string, unknown>)[segment];
    }

    return undefined;
  }, value);
}

function assertSecretFree(value: unknown, label: string, canaries: SecretCanaries): void {
  const leakedCategories = Object.entries(canaries)
    .filter((entry): entry is [SecretCategory, string] => typeof entry[1] === "string")
    .filter(([, canary]) => occurrencePaths(value, canary).length > 0)
    .map(([category]) => category);

  if (leakedCategories.length > 0) {
    throw new Error(`${label} retained secret categories: ${leakedCategories.join(", ")}`);
  }
}

function assertCanaryAbsent(value: unknown, label: string, canary: string): void {
  const occurrenceCount = occurrencePaths(value, canary).length;

  if (occurrenceCount > 0) {
    throw new Error(`${label} retained secret occurrence count: ${occurrenceCount}`);
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function normalizeErrorSurface(
  value: unknown,
  depth = 0,
  seen: Set<object> = new Set(),
): NormalizedErrorSurface {
  if (
    value === undefined ||
    value === null ||
    typeof value === "string" ||
    typeof value === "number" ||
    typeof value === "boolean"
  ) {
    return { complete: true, surface: value ?? null };
  }

  if (!(value instanceof Error)) {
    return { complete: false, surface: { kind: "unsupported-error-cause" } };
  }

  if (seen.has(value)) {
    return { complete: false, surface: { kind: "cyclic-error-cause" } };
  }

  seen.add(value);

  try {
    const base = {
      name: value.name,
      message: value.message,
      stack: value.stack,
    };

    if (value.cause === undefined) {
      return { complete: true, surface: { ...base, cause: null } };
    }

    if (depth >= 4) {
      return {
        complete: false,
        surface: { ...base, cause: { kind: "error-cause-depth-exceeded" } },
      };
    }

    const nested = normalizeErrorSurface(value.cause, depth + 1, seen);
    return {
      complete: nested.complete,
      surface: { ...base, cause: nested.surface },
    };
  } catch {
    return { complete: false, surface: { kind: "unreadable-error-surface" } };
  }
}

function correlateXhrResponseBodies(
  pendingResponses: PendingXhrApplicationResponse[],
  capturedBodies: CapturedXhrResponseBody[],
): CapturedResponse[] {
  const usedBodyIndexes = new Set<number>();

  const correlated = pendingResponses.map((pending) => {
    const matchingBodyIndexes = capturedBodies
      .map((captured, bodyIndex) => ({ captured, bodyIndex }))
      .filter(
        ({ captured, bodyIndex }) =>
          !usedBodyIndexes.has(bodyIndex) &&
          captured.method === pending.method &&
          captured.status === pending.status &&
          captured.url === pending.url,
      )
      .map(({ bodyIndex }) => bodyIndex);

    if (matchingBodyIndexes.length !== 1) {
      throw new Error(`XHR response body correlation mismatch at response:${pending.captureIndex}`);
    }

    const bodyIndex = matchingBodyIndexes[0]!;
    const captured = capturedBodies[bodyIndex]!;
    usedBodyIndexes.add(bodyIndex);

    return {
      kind: pending.kind,
      status: pending.status,
      path: pending.path,
      url: pending.url,
      headers: pending.headers,
      body: captured.body,
    };
  });

  const unmatchedBodyIndexes = capturedBodies
    .map((_captured, bodyIndex) => bodyIndex)
    .filter((bodyIndex) => !usedBodyIndexes.has(bodyIndex));

  if (unmatchedBodyIndexes.length > 0) {
    throw new Error(
      `unmatched XHR response body captures at: ${unmatchedBodyIndexes
        .map((bodyIndex) => `xhr-response:${bodyIndex}`)
        .join(", ")}`,
    );
  }

  return correlated;
}

function parseFrame(payload: string): unknown {
  try {
    return JSON.parse(payload) as unknown;
  } catch {
    return payload;
  }
}

function browserRunId(): string {
  const runId = process.env.SINGULARITY_TEST_RUN_ID;

  if (!runId) {
    throw new Error("Playwright did not initialize its non-secret run identifier");
  }

  return runId;
}

async function waitForSecretFreeBrowserState(
  page: Page,
  label: string,
  read: () => Promise<string | null>,
  matches: (surface: string) => boolean,
  observed: Array<{ kind: string; value: string }>,
  canaries: SecretCanaries,
  timeoutMs = 30_000,
): Promise<void> {
  const deadline = Date.now() + timeoutMs;

  while (Date.now() < deadline) {
    let surface: string | null = null;

    try {
      surface = await read();
    } catch {
      surface = null;
    }

    if (surface !== null) {
      observed.push({ kind: label, value: surface });
      assertSecretFree(surface, label, canaries);

      try {
        if (matches(surface)) {
          return;
        }
      } catch {
        // Keep polling without exposing the malformed surface.
      }
    }

    await page.waitForTimeout(25);
  }

  throw new Error(`${label} did not reach the expected state`);
}

async function waitForNonEchoingCondition(
  page: Page,
  label: string,
  condition: () => Promise<boolean>,
  timeoutMs = 30_000,
): Promise<void> {
  const deadline = Date.now() + timeoutMs;

  while (Date.now() < deadline) {
    try {
      if (await condition()) {
        return;
      }
    } catch {
      // Keep polling and use only the fixed label on timeout.
    }

    await page.waitForTimeout(25);
  }

  throw new Error(`${label} did not reach the expected state`);
}

async function drainCapturePromises(
  page: Page,
  groups: Array<Array<Promise<void>>>,
  synchronousLengths: Array<() => number>,
  label: string,
): Promise<void> {
  const deadline = Date.now() + 5_000;
  let stableLengths: number[] | null = null;
  const captureLengths = (): number[] => [
    ...groups.map((group) => group.length),
    ...synchronousLengths.map((length) => length()),
  ];

  while (Date.now() < deadline) {
    const before = captureLengths();
    await Promise.all(groups.flatMap((group) => group.slice()));
    await page.evaluate(() => new Promise<void>((resolve) => window.setTimeout(resolve, 0)));
    await page.waitForTimeout(25);
    const after = captureLengths();
    const unchanged = after.every((length, index) => length === before[index]);
    const stableAgain =
      stableLengths !== null &&
      after.every((length, index) => length === stableLengths?.[index]);

    if (unchanged && stableAgain) {
      return;
    }

    stableLengths = unchanged ? after : null;
  }

  throw new Error(`${label} capture streams did not become quiescent`);
}

async function captureDocument(
  page: Page,
  label: string,
  csrfTokens: Set<string>,
  controllerCsrfTokens: Set<string>,
  csrfKinds: Set<CsrfOccurrenceKind>,
): Promise<DocumentSnapshot> {
  const snapshot = await page.evaluate(() => {
    const metaTags = Array.from(
      document.querySelectorAll<HTMLMetaElement>('meta[name="csrf-token"]'),
    );
    const metaToken = metaTags.length === 1 ? (metaTags[0]?.getAttribute("content") ?? null) : null;
    const csrfInputs = Array.from(
      document.querySelectorAll<HTMLInputElement>('input[name="_csrf_token"]'),
    );
    const approvedControllerInputs = csrfInputs.filter((input) => {
      const form = input.form;

      if (!form || input.type !== "hidden") {
        return false;
      }

      try {
        const action = new URL(form.action, window.location.href);
        return form.method.toUpperCase() === "POST" && action.origin === window.location.origin;
      } catch {
        return false;
      }
    });
    const controllerTokens = approvedControllerInputs
      .map((input) => input.value)
      .filter((token) => token.length > 0);

    const clone = document.documentElement.cloneNode(true) as HTMLElement;
    clone.querySelector<HTMLMetaElement>('meta[name="csrf-token"]')?.removeAttribute("content");

    const cloneInputs = Array.from(
      clone.querySelectorAll<HTMLInputElement>('input[name="_csrf_token"]'),
    );

    for (const [index, input] of csrfInputs.entries()) {
      if (approvedControllerInputs.includes(input)) {
        cloneInputs[index]?.removeAttribute("value");
      }
    }

    return {
      metaToken,
      validMetaLocation: metaTags.length === 1 && typeof metaToken === "string" && metaToken !== "",
      invalidControllerLocations: csrfInputs
        .map((input, index) => ({ input, index }))
        .filter(({ input }) => !approvedControllerInputs.includes(input) || input.value === "")
        .map(({ index }) => `input:${index}`),
      controllerTokens,
      sanitizedHtml: clone.outerHTML,
      dataProps: Array.from(document.querySelectorAll<HTMLElement>("[data-props]"), (element) =>
        element.getAttribute("data-props") ?? "",
      ),
    };
  });

  if (!snapshot.validMetaLocation) {
    throw new Error(`${label} has an invalid dedicated CSRF meta-tag location`);
  }

  if (snapshot.invalidControllerLocations.length > 0) {
    throw new Error(
      `${label} has invalid controller CSRF locations: ${snapshot.invalidControllerLocations.join(", ")}`,
    );
  }

  if (snapshot.metaToken) {
    csrfTokens.add(snapshot.metaToken);
    csrfKinds.add("meta-tag");
  }

  for (const token of snapshot.controllerTokens) {
    csrfTokens.add(token);
    controllerCsrfTokens.add(token);
    csrfKinds.add("controller-form-field");
  }

  return {
    label,
    sanitizedHtml: snapshot.sanitizedHtml,
    dataProps: snapshot.dataProps,
  };
}

async function auditLiveBackupPassphrase(
  page: Page,
  backupPassphrase: string,
  allowDedicatedInput: boolean,
): Promise<{ dedicatedInputExact: boolean; findings: LiveSecretFinding[] }> {
  return page.evaluate(({ canary, allowInput }) => {
    const findings: LiveSecretFinding[] = [];
    const contains = (value: unknown): boolean =>
      typeof value === "string" && value.includes(canary);
    const controls = Array.from(
      document.querySelectorAll<HTMLInputElement | HTMLTextAreaElement | HTMLSelectElement>(
        "input, textarea, select",
      ),
    );
    const dedicatedInput = document.querySelector<HTMLInputElement>("#backup-passphrase");
    const allowedInput = allowInput ? dedicatedInput : null;

    controls.forEach((control, index) => {
      if (contains(control.value) && control !== allowedInput) {
        findings.push({ kind: "form-control-value", path: `control:${index}` });
      }

      if (contains(control.value) && control === allowedInput && control.value !== canary) {
        findings.push({ kind: "form-control-value-shape", path: "#backup-passphrase" });
      }

      if ("defaultValue" in control && contains(control.defaultValue)) {
        findings.push({ kind: "form-control-default-value", path: `control:${index}` });
      }
    });

    Array.from(document.querySelectorAll<HTMLElement>("*")).forEach((element, elementIndex) => {
      Array.from(element.attributes).forEach((attribute, attributeIndex) => {
        if (contains(attribute.name) || contains(attribute.value)) {
          findings.push({
            kind: "dom-attribute",
            path: `element:${elementIndex}:attribute:${attributeIndex}`,
          });
        }
      });

      if (element.hasAttribute("data-props") && contains(element.getAttribute("data-props"))) {
        findings.push({ kind: "data-props", path: `element:${elementIndex}` });
      }
    });

    if (contains(document.documentElement.outerHTML)) {
      findings.push({ kind: "serialized-html", path: "document" });
    }

    if (contains(document.documentElement.textContent) || contains(document.body.innerText)) {
      findings.push({ kind: "document-text", path: "document" });
    }

    const urlSurfaces = [
      window.location.href,
      window.location.search,
      window.location.hash,
      document.URL,
      document.referrer,
    ];

    urlSurfaces.forEach((value, index) => {
      if (contains(value)) {
        findings.push({ kind: "url", path: `surface:${index}` });
      }
    });

    try {
      if (contains(JSON.stringify(window.history.state))) {
        findings.push({ kind: "history-state", path: "current" });
      }
    } catch {
      findings.push({ kind: "history-state-uninspectable", path: "current" });
    }

    [window.localStorage, window.sessionStorage].forEach((storage, storageIndex) => {
      try {
        for (let index = 0; index < storage.length; index += 1) {
          const key = storage.key(index);

          if (contains(key) || contains(key === null ? null : storage.getItem(key))) {
            findings.push({ kind: "web-storage", path: `storage:${storageIndex}:entry:${index}` });
          }
        }
      } catch {
        findings.push({ kind: "web-storage-uninspectable", path: `storage:${storageIndex}` });
      }
    });

    return {
      dedicatedInputExact: dedicatedInput?.value === canary,
      findings,
    };
  }, { canary: backupPassphrase, allowInput: allowDedicatedInput });
}

function exactPath(path: string[], expected: string[]): boolean {
  return path.length === expected.length && path.every((segment, index) => segment === expected[index]);
}

function isLiveViewJoin(payload: unknown): payload is unknown[] {
  if (!Array.isArray(payload) || payload.length !== 5) {
    return false;
  }

  const ref = payload[1];
  const topic = payload[2];
  const joinPayload = payload[4];

  return (
    typeof ref === "string" &&
    ref !== "" &&
    typeof topic === "string" &&
    topic.startsWith("lv:") &&
    payload[3] === "phx_join" &&
    isRecord(joinPayload) &&
    isRecord(joinPayload.params)
  );
}

function uploadGrantFromFrames(
  frames: CapturedFrame[],
): { grantId: string; uploadToken: string } {
  const outgoingGrants = frames
    .map((frame, frameIndex) => ({ frame, frameIndex }))
    .filter(({ frame }) => {
      if (
        frame.direction !== "sent" ||
        !Array.isArray(frame.payload) ||
        frame.payload.length !== 5
      ) {
        return false;
      }

      const eventPayload = frame.payload[4];

      return (
        frame.payload[3] === "event" &&
        isRecord(eventPayload) &&
        eventPayload.type === "hook" &&
        eventPayload.event === "upload:grant"
      );
    });

  if (outgoingGrants.length !== 1) {
    throw new Error(
      `upload grant event frame count mismatch at frames: ${outgoingGrants
        .map(({ frameIndex }) => frameIndex)
        .join(", ") || "none"}`,
    );
  }

  const outgoing = outgoingGrants[0]!;
  const outgoingPayload = outgoing.frame.payload as unknown[];
  const phoenixJoinRef = outgoingPayload[0];
  const phoenixRef = outgoingPayload[1];
  const phoenixTopic = outgoingPayload[2];

  if (
    typeof phoenixRef !== "string" ||
    phoenixRef === "" ||
    typeof phoenixTopic !== "string" ||
    !phoenixTopic.startsWith("lv:")
  ) {
    throw new Error(
      `upload grant event has an invalid Phoenix ref or topic at frame: ${outgoing.frameIndex}`,
    );
  }

  const replies = frames
    .map((frame, frameIndex) => ({ frame, frameIndex }))
    .filter(
      ({ frame }) =>
        frame.direction === "received" &&
        Array.isArray(frame.payload) &&
        frame.payload.length === 5 &&
        frame.payload[0] === phoenixJoinRef &&
        frame.payload[1] === phoenixRef &&
        frame.payload[2] === phoenixTopic &&
        frame.payload[3] === "phx_reply",
    );

  if (replies.length !== 1) {
    throw new Error(
      `upload grant reply count mismatch for frame: ${outgoing.frameIndex}; replies: ${replies
        .map(({ frameIndex }) => frameIndex)
        .join(", ") || "none"}`,
    );
  }

  const reply = replies[0]!;
  const replyPayload = reply.frame.payload as unknown[];
  const replyEnvelope = replyPayload[4];
  const response = isRecord(replyEnvelope) ? replyEnvelope.response : null;
  const diff = isRecord(response) ? response.diff : null;
  const hookReply = isRecord(diff) ? diff.r : null;
  const uploadToken = isRecord(hookReply) ? hookReply.uploadToken : null;
  const grantId = isRecord(hookReply) ? hookReply.grantId : null;

  if (
    !isRecord(replyEnvelope) ||
    replyEnvelope.status !== "ok" ||
    typeof uploadToken !== "string" ||
    uploadToken === "" ||
    typeof grantId !== "string" ||
    grantId === ""
  ) {
    throw new Error(`upload grant reply has an invalid response shape at frame: ${reply.frameIndex}`);
  }

  const frameOccurrences = frames.flatMap((frame, frameIndex) =>
    occurrencePaths(frame.payload, uploadToken).map((path) => ({
      direction: frame.direction,
      frameIndex,
      path,
      payload: frame.payload,
    })),
  );

  const allowedGrantCallbacks = frameOccurrences.filter(
    ({ direction, frameIndex, path, payload }) =>
      direction === "received" &&
      frameIndex === reply.frameIndex &&
      Array.isArray(payload) &&
      payload[0] === phoenixJoinRef &&
      payload[1] === phoenixRef &&
      payload[2] === phoenixTopic &&
      payload[3] === "phx_reply" &&
      exactPath(path, ["4", "response", "diff", "r", "uploadToken"]) &&
      valueAtPath(payload, path) === uploadToken,
  );

  if (frameOccurrences.length !== 1 || allowedGrantCallbacks.length !== 1) {
    throw new Error(
      `upload token frame allowance mismatch: occurrences:${frameOccurrences.length}:allowed:${allowedGrantCallbacks.length}`,
    );
  }

  return { grantId, uploadToken };
}

function assertRequestHeaderAllowances(
  requests: CapturedRequest[],
  uploadOrigin: string,
  grantId: string,
  uploadToken: string,
  csrfTokens: Set<string>,
  csrfKinds: Set<CsrfOccurrenceKind>,
): void {
  const expectedPath = `/api/v1/uploads/${encodeURIComponent(grantId)}`;
  const uploadHeaderLocations: string[] = [];
  const csrfHeaderLocations: string[] = [];
  const forbiddenLocations: string[] = [];

  requests.forEach((request, requestIndex) => {
    const exactUploadRequest =
      request.method === "PUT" &&
      request.origin === uploadOrigin &&
      request.path === expectedPath &&
      request.search === "";

    if (
      request.origin.includes(uploadToken) ||
      request.path.includes(uploadToken) ||
      request.search.includes(uploadToken)
    ) {
      forbiddenLocations.push(`upload-token:request:${requestIndex}:url`);
    }

    if (
      [...csrfTokens].some(
        (token) =>
          request.origin.includes(token) ||
          request.path.includes(token) ||
          request.search.includes(token),
      )
    ) {
      forbiddenLocations.push(`csrf-token:request:${requestIndex}:url`);
    }

    Object.entries(request.headers).forEach(([name, value], headerIndex) => {
      const normalizedName = name.toLowerCase();
      const uploadOccurrence = name.includes(uploadToken) || value.includes(uploadToken);
      const csrfOccurrences = [...csrfTokens].filter(
        (token) => name.includes(token) || value.includes(token),
      );

      if (normalizedName === "x-upload-token" || uploadOccurrence) {
        if (
          exactUploadRequest &&
          normalizedName === "x-upload-token" &&
          name === "x-upload-token" &&
          value === uploadToken
        ) {
          uploadHeaderLocations.push(`request:${requestIndex}:header:${headerIndex}`);
        } else {
          forbiddenLocations.push(`upload-token:request:${requestIndex}:header:${headerIndex}`);
        }
      }

      if (normalizedName === "x-csrf-token" || csrfOccurrences.length > 0) {
        if (
          exactUploadRequest &&
          normalizedName === "x-csrf-token" &&
          name === "x-csrf-token" &&
          csrfOccurrences.length === 1 &&
          value === csrfOccurrences[0]
        ) {
          csrfHeaderLocations.push(`request:${requestIndex}:header:${headerIndex}`);
          csrfKinds.add("xhr-header");
        } else {
          forbiddenLocations.push(`csrf-token:request:${requestIndex}:header:${headerIndex}`);
        }
      }
    });
  });

  if (forbiddenLocations.length > 0) {
    throw new Error(`browser request header allowance mismatch at: ${forbiddenLocations.join(", ")}`);
  }

  if (uploadHeaderLocations.length !== 1) {
    throw new Error(
      `upload token header allowance mismatch at: ${uploadHeaderLocations.join(", ") || "none"}`,
    );
  }

  if (csrfHeaderLocations.length !== 1) {
    throw new Error(
      `CSRF XHR header allowance mismatch at: ${csrfHeaderLocations.join(", ") || "none"}`,
    );
  }
}

function sanitizedIodataAtOccurrence(
  value: unknown,
  occurrencePath: string[],
  token: string,
  marker: string,
  path: string[] = [],
): string | null {
  if (typeof value === "string") {
    const isOccurrence = exactPath(path, occurrencePath);
    const pieces = value.split(token);
    const occurrenceCount = pieces.length - 1;

    if (isOccurrence) {
      return occurrenceCount === 1 ? pieces.join(marker) : null;
    }

    return occurrenceCount === 0 ? value : null;
  }

  if (Number.isInteger(value) && (value as number) >= 0 && (value as number) <= 255) {
    return String.fromCharCode(value as number);
  }

  if (!Array.isArray(value)) {
    return null;
  }

  const flattened: string[] = [];

  for (const [index, entry] of value.entries()) {
    const part = sanitizedIodataAtOccurrence(
      entry,
      occurrencePath,
      token,
      marker,
      [...path, `${index}`],
    );

    if (part === null) {
      return null;
    }

    flattened.push(part);
  }

  return flattened.join("");
}

function resolvedStaticsAtPath(
  payload: unknown[],
  path: string[],
  ancestorLength: number,
): string[] | null {
  let templates: Record<string, unknown> | null = null;

  for (let prefixLength = 3; prefixLength <= ancestorLength; prefixLength += 1) {
    const renderedNode = valueAtPath(payload, path.slice(0, prefixLength));

    if (isRecord(renderedNode) && Object.hasOwn(renderedNode, "k")) {
      return null;
    }

    if (isRecord(renderedNode) && Object.hasOwn(renderedNode, "p")) {
      if (!isRecord(renderedNode.p)) {
        return null;
      }

      templates = renderedNode.p;
    }
  }

  const renderedAncestor = valueAtPath(payload, path.slice(0, ancestorLength));

  if (!isRecord(renderedAncestor) || !Object.hasOwn(renderedAncestor, "s")) {
    return null;
  }

  if (
    Array.isArray(renderedAncestor.s) &&
    renderedAncestor.s.every((entry) => typeof entry === "string")
  ) {
    return renderedAncestor.s as string[];
  }

  if (!Number.isInteger(renderedAncestor.s) || templates === null) {
    return null;
  }

  const referencedStatics = templates[`${renderedAncestor.s}`];

  return Array.isArray(referencedStatics) &&
    referencedStatics.every((entry) => typeof entry === "string")
    ? (referencedStatics as string[])
    : null;
}

function renderedControllerLeaf(
  payload: unknown[],
  path: string[],
  token: string,
): RenderedControllerLeaf | null {
  if (
    path.length < 5 ||
    !exactPath(path.slice(0, 3), ["4", "response", "rendered"])
  ) {
    return null;
  }

  for (let ancestorLength = path.length - 1; ancestorLength >= 3; ancestorLength -= 1) {
    const renderedAncestor = valueAtPath(payload, path.slice(0, ancestorLength));

    if (!isRecord(renderedAncestor) || !Object.hasOwn(renderedAncestor, "s")) {
      continue;
    }

    const statics = resolvedStaticsAtPath(payload, path, ancestorLength);

    if (statics === null) {
      return null;
    }

    const dynamicSegment = path[ancestorLength];
    const dynamicIndex =
      dynamicSegment === undefined ? Number.NaN : Number.parseInt(dynamicSegment, 10);

    if (
      !Number.isInteger(dynamicIndex) ||
      dynamicIndex < 0 ||
      `${dynamicIndex}` !== dynamicSegment ||
      typeof statics[dynamicIndex] !== "string" ||
      typeof statics[dynamicIndex + 1] !== "string"
    ) {
      return null;
    }

    const dynamicValue = renderedAncestor[dynamicSegment];
    const occurrencePath = path.slice(ancestorLength + 1);
    const dynamicOccurrences = occurrencePaths(dynamicValue, token);

    if (
      dynamicOccurrences.length !== 1 ||
      !exactPath(dynamicOccurrences[0]!, occurrencePath)
    ) {
      return null;
    }

    const marker = Array.from(
      { length: 32 },
      (_unused, index) => `singularity-csrf-controller-marker-${index}`,
    ).find(
      (candidate) =>
        occurrencePaths(statics, candidate).length === 0 &&
        occurrencePaths(dynamicValue, candidate).length === 0,
    );

    if (marker === undefined) {
      return null;
    }

    const sanitizedDynamic = sanitizedIodataAtOccurrence(
      dynamicValue,
      occurrencePath,
      token,
      marker,
    );

    if (sanitizedDynamic === null) {
      return null;
    }

    const html = statics.reduce((renderedHtml, staticPart, index) => {
      if (index === 0) {
        return staticPart;
      }

      const dynamicPart = index - 1 === dynamicIndex ? sanitizedDynamic : "";
      return renderedHtml + dynamicPart + staticPart;
    }, "");

    return html.split(marker).length === 2 ? { html, marker } : null;
  }

  return null;
}

async function isSameOriginControllerMarker(
  page: Page,
  renderedLeaf: RenderedControllerLeaf,
  expectedOrigin: string,
): Promise<boolean> {
  if (renderedLeaf.html.split(renderedLeaf.marker).length !== 2) {
    return false;
  }

  return page.evaluate(
    ({ html, marker, origin }) => {
      const template = document.createElement("template");
      template.innerHTML = html;
      const inputs = Array.from(
        template.content.querySelectorAll<HTMLInputElement>(
          'input[type="hidden"][name="_csrf_token"]',
        ),
      ).filter((input) => input.getAttribute("value") === marker);

      if (inputs.length !== 1) {
        return false;
      }

      const input = inputs[0]!;
      const form = input.closest("form");

      if (!form || input.form !== form || form.getAttribute("method")?.toUpperCase() !== "POST") {
        return false;
      }

      const action = form.getAttribute("action");

      if (!action) {
        return false;
      }

      try {
        return new URL(action, origin).origin === origin;
      } catch {
        return false;
      }
    },
    { html: renderedLeaf.html, marker: renderedLeaf.marker, origin: expectedOrigin },
  );
}

async function assertCsrfFrameAllowance(
  page: Page,
  frames: CapturedFrame[],
  csrfTokens: Set<string>,
  controllerCsrfTokens: Set<string>,
  csrfKinds: Set<CsrfOccurrenceKind>,
  expectedOrigin: string,
): Promise<void> {
  const forbiddenLocations: string[] = [];

  for (const token of csrfTokens) {
    for (const [frameIndex, frame] of frames.entries()) {
      for (const [occurrenceIndex, path] of occurrencePaths(frame.payload, token).entries()) {
        const liveSocketParam =
          frame.direction === "sent" &&
          isLiveViewJoin(frame.payload) &&
          exactPath(path, ["4", "params", "_csrf_token"]) &&
          valueAtPath(frame.payload, path) === token;
        const receivedPayload =
          frame.direction === "received" && Array.isArray(frame.payload) ? frame.payload : null;
        const replyEnvelope = receivedPayload?.[4] ?? null;
        const matchingJoins =
          receivedPayload !== null
            ? frames.filter(
                (candidate) =>
                  candidate.direction === "sent" &&
                  isLiveViewJoin(candidate.payload) &&
                  candidate.payload[0] === receivedPayload[0] &&
                  candidate.payload[1] === receivedPayload[1] &&
                  candidate.payload[2] === receivedPayload[2],
              )
            : [];
        const renderedLeaf =
          frame.direction === "received" &&
          controllerCsrfTokens.has(token) &&
          receivedPayload !== null &&
          receivedPayload[3] === "phx_reply" &&
          isRecord(replyEnvelope) &&
          replyEnvelope.status === "ok" &&
          matchingJoins.length === 1
            ? renderedControllerLeaf(receivedPayload, path, token)
            : null;
        const renderedControllerField =
          renderedLeaf !== null &&
          (await isSameOriginControllerMarker(page, renderedLeaf, expectedOrigin));

        if (liveSocketParam) {
          csrfKinds.add("live-socket-param");
        } else if (renderedControllerField) {
          csrfKinds.add("controller-form-field");
        } else {
          forbiddenLocations.push(
            `${frame.direction}:${frameIndex}:occurrence:${occurrenceIndex}`,
          );
        }
      }
    }
  }

  if (forbiddenLocations.length > 0) {
    throw new Error(`CSRF token escaped framework transport at: ${forbiddenLocations.join(", ")}`);
  }
}

test("ephemeral browser secrets stay on their exact transport surfaces", async ({ page }) => {
  test.setTimeout(120_000);

  const ownerPassword = await deriveBrowserTestOwnerPassword(browserRunId());
  const backupPassphrase = crypto.randomUUID();
  const csrfTokens = new Set<string>();
  const controllerCsrfTokens = new Set<string>();
  const csrfOccurrenceKinds = new Set<CsrfOccurrenceKind>();
  const frames: CapturedFrame[] = [];
  const responses: CapturedResponse[] = [];
  const responseCaptures: Promise<void>[] = [];
  const responseCaptureFailures: string[] = [];
  const pendingXhrApplicationResponses: PendingXhrApplicationResponse[] = [];
  const capturedXhrResponseBodies: CapturedXhrResponseBody[] = [];
  const xhrResponseCaptureFailures: string[] = [];
  const requests: CapturedRequest[] = [];
  const requestCaptures: Promise<void>[] = [];
  const consoleSurfaces: unknown[] = [];
  const consoleCaptures: Promise<void>[] = [];
  const consoleCaptureFailures: string[] = [];
  const exceptionSurfaces: unknown[] = [];
  const exceptionCaptureFailures: string[] = [];
  const documents: DocumentSnapshot[] = [];
  const observedBrowserSurfaces: Array<{ kind: string; value: string }> = [];
  const synchronousCaptureLengths: Array<() => number> = [
    () => frames.length,
    () => responses.length,
    () => responseCaptureFailures.length,
    () => pendingXhrApplicationResponses.length,
    () => capturedXhrResponseBodies.length,
    () => xhrResponseCaptureFailures.length,
    () => requests.length,
    () => consoleSurfaces.length,
    () => consoleCaptureFailures.length,
    () => exceptionSurfaces.length,
    () => exceptionCaptureFailures.length,
  ];
  const earlyBrowserCanaries: SecretCanaries = {
    "owner-password": ownerPassword,
    "backup-passphrase": backupPassphrase,
  };

  await page.exposeFunction("__singularityCaptureXhrResponseBody", (surface: unknown) => {
    const captureIndex = capturedXhrResponseBodies.length + xhrResponseCaptureFailures.length;

    if (
      !isRecord(surface) ||
      surface.ok !== true ||
      !Number.isInteger(surface.status) ||
      surface.status !== 201 ||
      surface.method !== "PUT" ||
      typeof surface.url !== "string" ||
      surface.url === "" ||
      typeof surface.body !== "string"
    ) {
      xhrResponseCaptureFailures.push(`xhr-response:${captureIndex}`);
      return;
    }

    capturedXhrResponseBodies.push({
      method: surface.method,
      status: surface.status as number,
      url: surface.url,
      body: surface.body,
    });
  });
  await page.addInitScript(() => {
    type CaptureWindow = Window & {
      __singularityCaptureXhrResponseBody: (surface: unknown) => Promise<void>;
      __singularityXhrResponseCaptureInstalled?: boolean;
      __singularityXhrResponseCaptureBridgeFailed?: boolean;
    };

    const captureWindow = window as unknown as CaptureWindow;

    if (window !== window.top || captureWindow.__singularityXhrResponseCaptureInstalled) {
      return;
    }

    captureWindow.__singularityXhrResponseCaptureInstalled = true;
    captureWindow.__singularityXhrResponseCaptureBridgeFailed = false;
    const originalOpen = XMLHttpRequest.prototype.open;
    const requestMetadata = new WeakMap<XMLHttpRequest, { method: string; url: string }>();

    XMLHttpRequest.prototype.open = function (this: XMLHttpRequest, ...args: unknown[]): void {
      const method = args[0];
      const requestUrl = args[1];

      try {
        if (
          typeof method === "string" &&
          (typeof requestUrl === "string" || requestUrl instanceof URL)
        ) {
          requestMetadata.set(this, {
            method: method.toUpperCase(),
            url: new URL(requestUrl.toString(), window.location.href).href,
          });
        }
      } catch {
        requestMetadata.delete(this);
      }

      this.addEventListener(
        "loadend",
        () => {
          const contentType = (this.getResponseHeader("content-type") ?? "")
            .trim()
            .toLowerCase();
          const metadata = requestMetadata.get(this);
          let responseUrl: URL;

          try {
            responseUrl = new URL(this.responseURL);
          } catch {
            return;
          }

          if (
            metadata?.method !== "PUT" ||
            this.status !== 201 ||
            !/^application\/json(?:;|$)/.test(contentType) ||
            responseUrl.origin !== window.location.origin ||
            responseUrl.search !== "" ||
            responseUrl.hash !== "" ||
            !/^\/api\/v1\/uploads\/[^/]+$/.test(responseUrl.pathname) ||
            metadata.url !== responseUrl.href
          ) {
            return;
          }

          let surface: unknown;

          try {
            surface =
              this.responseType === "" || this.responseType === "text"
                ? {
                    ok: true,
                    method: metadata.method,
                    status: this.status,
                    url: responseUrl.href,
                    body: this.responseText,
                  }
                : { ok: false, method: metadata.method, status: this.status, url: responseUrl.href };
          } catch {
            surface = { ok: false, method: metadata.method, status: this.status, url: responseUrl.href };
          }

          void captureWindow.__singularityCaptureXhrResponseBody(surface).catch(() => {
            captureWindow.__singularityXhrResponseCaptureBridgeFailed = true;
          });
        },
        { once: true },
      );

      Reflect.apply(originalOpen, this, args);
    } as typeof XMLHttpRequest.prototype.open;
  });

  page.on("console", (message) => {
    const captureIndex = consoleCaptures.length;
    consoleCaptures.push(
      Promise.all(message.args().map((argument) => argument.jsonValue()))
        .then((arguments_) => {
          consoleSurfaces.push({ text: message.text(), arguments: arguments_ });
        })
        .catch(() => {
          consoleCaptureFailures.push(`console:${captureIndex}`);
        }),
    );
  });
  page.on("pageerror", (error) => {
    const captureIndex = exceptionSurfaces.length + exceptionCaptureFailures.length;
    const normalized = normalizeErrorSurface(error);
    exceptionSurfaces.push(normalized.surface);

    if (!normalized.complete) {
      exceptionCaptureFailures.push(`pageerror:${captureIndex}`);
    }
  });

  page.on("websocket", (socket) => {
    socket.on("framesent", (event) =>
      frames.push({ direction: "sent", payload: parseFrame(String(event.payload)) }),
    );
    socket.on("framereceived", (event) =>
      frames.push({ direction: "received", payload: parseFrame(String(event.payload)) }),
    );
  });

  page.on("response", (response) => {
    const status = response.status();
    const contentType = (response.headers()["content-type"] ?? "").trim().toLowerCase();
    const exactApplicationJson = /^application\/json(?:;|$)/.test(contentType);
    const kind = contentType.includes("application/json")
      ? "application-json"
      : contentType.includes("text/html")
        ? "html"
        : null;
    const hasNoConsumedBody =
      (status >= 300 && status < 400) || status === 204 || status === 304;

    if (!kind && !hasNoConsumedBody) {
      return;
    }

    const captureIndex = responseCaptures.length;
    const responseUrl = new URL(response.url());
    const pageOrigin = new URL(page.url()).origin;
    const requestMethod = response.request().method();
    const usesXhrResponseBodyCapture =
      kind === "application-json" &&
      exactApplicationJson &&
      requestMethod === "PUT" &&
      status === 201 &&
      response.request().resourceType() === "xhr" &&
      response.frame() === page.mainFrame() &&
      responseUrl.origin === pageOrigin &&
      responseUrl.search === "" &&
      responseUrl.hash === "" &&
      /^\/api\/v1\/uploads\/[^/]+$/.test(responseUrl.pathname);
    const headersPromise = response
      .allHeaders()
      .then((headers) => ({ ok: true as const, headers }))
      .catch(() => ({ ok: false as const }));
    const bodyPromise = hasNoConsumedBody || usesXhrResponseBodyCapture
      ? null
      : response
          .text()
          .then((body) => ({ ok: true as const, body }))
          .catch(() => ({ ok: false as const }));
    responseCaptures.push(
      (async () => {
        const path = new URL(response.url()).pathname;
        const headerCapture = await headersPromise;

        if (!headerCapture.ok) {
          responseCaptureFailures.push(`response:${captureIndex}:status:${status}:headers`);
          return;
        }

        const headers = headerCapture.headers;

        if (hasNoConsumedBody) {
          responses.push({
            kind: "no-consumed-body",
            status,
            path,
            url: response.url(),
            headers,
          });
          return;
        }

        if (usesXhrResponseBodyCapture) {
          pendingXhrApplicationResponses.push({
            captureIndex,
            kind: kind!,
            method: requestMethod,
            status,
            path,
            url: response.url(),
            headers,
          });
          return;
        }

        const bodyCapture = await bodyPromise;

        if (bodyCapture === null || !bodyCapture.ok) {
          responseCaptureFailures.push(`response:${captureIndex}:status:${status}:body`);
          return;
        }

        responses.push({
          kind: kind!,
          status,
          path,
          url: response.url(),
          headers,
          body: bodyCapture.body,
        });
      })(),
    );
  });

  page.on("request", (request) => {
    const url = new URL(request.url());
    const method = request.method();
    const origin = url.origin;
    const path = url.pathname;
    const search = url.search;
    const captureIndex = requestCaptures.length;
    requestCaptures.push(
      request
        .allHeaders()
        .then((headers) => {
          requests.push({
            method,
            origin,
            path,
            search,
            headers,
          });
        })
        .catch(() => {
          throw new Error(`browser request headers were uninspectable at request:${captureIndex}`);
        }),
    );
  });

  await page.goto("/login");
  const browserOrigin = new URL(page.url()).origin;
  documents.push(
    await captureDocument(
      page,
      "initial-login",
      csrfTokens,
      controllerCsrfTokens,
      csrfOccurrenceKinds,
    ),
  );

  await page.getByLabel("Login", { exact: true }).fill("owner@singularity.local");
  await page.getByLabel("Password", { exact: true }).fill(ownerPassword);
  await page.getByRole("button", { name: "Sign in", exact: true }).click();
  await waitForSecretFreeBrowserState(
    page,
    "login navigation URL",
    async () => page.url(),
    (surface) => {
      const url = new URL(surface);
      return url.origin === browserOrigin && url.pathname === "/vault/unlock" && url.search === "";
    },
    observedBrowserSurfaces,
    earlyBrowserCanaries,
  );
  documents.push(
    await captureDocument(
      page,
      "returned-unlock",
      csrfTokens,
      controllerCsrfTokens,
      csrfOccurrenceKinds,
    ),
  );

  await unlockVault(page, ownerPassword);
  await waitForSecretFreeBrowserState(
    page,
    "unlock navigation URL",
    async () => page.url(),
    (surface) => {
      const url = new URL(surface);
      return url.origin === browserOrigin && url.pathname === "/assets" && url.search === "";
    },
    observedBrowserSurfaces,
    earlyBrowserCanaries,
  );
  documents.push(
    await captureDocument(
      page,
      "returned-assets",
      csrfTokens,
      controllerCsrfTokens,
      csrfOccurrenceKinds,
    ),
  );

  await page
    .getByLabel("Choose a file to upload", { exact: true })
    .setInputFiles("test/fixtures/assets/sample.pdf");
  await page.getByRole("button", { name: "Upload asset", exact: true }).click();
  await waitForSecretFreeBrowserState(
    page,
    "upload result text",
    () => page.locator(".upload-result").textContent(),
    (surface) => surface.trim() === "Upload complete",
    observedBrowserSurfaces,
    earlyBrowserCanaries,
  );
  await drainCapturePromises(
    page,
    [responseCaptures, requestCaptures, consoleCaptures],
    synchronousCaptureLengths,
    "post-upload",
  );

  const xhrCaptureDeadline = Date.now() + 5_000;

  while (
    capturedXhrResponseBodies.length + xhrResponseCaptureFailures.length <
      pendingXhrApplicationResponses.length &&
    Date.now() < xhrCaptureDeadline
  ) {
    await page.waitForTimeout(25);
  }

  const xhrResponseCaptureBridgeFailed = await page.evaluate(
    () =>
      (window as Window & { __singularityXhrResponseCaptureBridgeFailed?: boolean })
        .__singularityXhrResponseCaptureBridgeFailed === true,
  );

  if (xhrResponseCaptureBridgeFailed) {
    throw new Error("XHR response body capture failed at: xhr-response:bridge");
  }

  if (xhrResponseCaptureFailures.length > 0) {
    throw new Error(
      `XHR response bodies were uninspectable at: ${xhrResponseCaptureFailures.join(", ")}`,
    );
  }

  if (capturedXhrResponseBodies.length !== pendingXhrApplicationResponses.length) {
    throw new Error(
      `XHR response body capture count mismatch at: ${pendingXhrApplicationResponses
        .map(({ captureIndex }) => `response:${captureIndex}`)
        .join(", ") || "none"}`,
    );
  }

  const { grantId, uploadToken } = uploadGrantFromFrames(frames);
  const uploadOrigin = new URL(page.url()).origin;
  const activeBrowserCanaries: SecretCanaries = {
    ...earlyBrowserCanaries,
    "upload-token": uploadToken,
  };
  const expectedUploadPath = `/api/v1/uploads/${encodeURIComponent(grantId)}`;
  const expectedUploadUrl = `${uploadOrigin}${expectedUploadPath}`;

  if (
    pendingXhrApplicationResponses.length !== 1 ||
    capturedXhrResponseBodies.length !== 1
  ) {
    throw new Error("upload XHR response body proof did not have exactly one correlated pair");
  }

  const pendingUploadResponse = pendingXhrApplicationResponses[0]!;
  const capturedUploadBody = capturedXhrResponseBodies[0]!;

  if (
    pendingUploadResponse.method !== "PUT" ||
    pendingUploadResponse.kind !== "application-json" ||
    pendingUploadResponse.status !== 201 ||
    pendingUploadResponse.path !== expectedUploadPath ||
    pendingUploadResponse.url !== expectedUploadUrl ||
    capturedUploadBody.method !== "PUT" ||
    capturedUploadBody.status !== 201 ||
    capturedUploadBody.url !== expectedUploadUrl
  ) {
    throw new Error("upload XHR response body proof did not match the exact grant response");
  }

  responses.push(
    ...correlateXhrResponseBodies(
      pendingXhrApplicationResponses,
      capturedXhrResponseBodies,
    ),
  );
  pendingXhrApplicationResponses.splice(0);
  capturedXhrResponseBodies.splice(0);
  assertRequestHeaderAllowances(
    requests,
    uploadOrigin,
    grantId,
    uploadToken,
    csrfTokens,
    csrfOccurrenceKinds,
  );
  documents.push(
    await captureDocument(
      page,
      "post-upload-assets",
      csrfTokens,
      controllerCsrfTokens,
      csrfOccurrenceKinds,
    ),
  );

  const uploadedRow = page
    .getByRole("listitem")
    .filter({ has: page.getByRole("button", { name: "Inspect sample.pdf", exact: true }) });
  await waitForSecretFreeBrowserState(
    page,
    "uploaded asset row text",
    () => uploadedRow.textContent(),
    (surface) => surface.includes("Ready"),
    observedBrowserSurfaces,
    activeBrowserCanaries,
  );
  await page.getByRole("button", { name: "Inspect sample.pdf", exact: true }).click();
  await page.getByRole("button", { name: "Delete", exact: true }).click();
  await waitForSecretFreeBrowserState(
    page,
    "asset action status text",
    () => page.getByLabel("Asset action status", { exact: true }).textContent(),
    (surface) => surface.trim() === "Delete requested.",
    observedBrowserSurfaces,
    activeBrowserCanaries,
  );
  await waitForNonEchoingCondition(
    page,
    "uploaded asset row removal",
    async () => (await uploadedRow.count()) === 0,
  );
  await page.getByRole("button", { name: "Search", exact: true }).click();
  await waitForNonEchoingCondition(page, "empty catalogue state", () =>
    page
      .getByText("No assets match the current catalogue filters.", { exact: true })
      .isVisible(),
  );

  await page.getByRole("link", { name: "Backups", exact: true }).click();
  await waitForSecretFreeBrowserState(
    page,
    "backups navigation URL",
    async () => page.url(),
    (surface) => {
      const url = new URL(surface);
      return url.origin === browserOrigin && url.pathname === "/backups" && url.search === "";
    },
    observedBrowserSurfaces,
    activeBrowserCanaries,
  );
  documents.push(
    await captureDocument(
      page,
      "initial-backups",
      csrfTokens,
      controllerCsrfTokens,
      csrfOccurrenceKinds,
    ),
  );

  const backupInput = page.locator("#backup-passphrase");
  await backupInput.fill(backupPassphrase);

  const livePassphraseAudit = await auditLiveBackupPassphrase(page, backupPassphrase, true);
  await drainCapturePromises(
    page,
    [responseCaptures, requestCaptures, consoleCaptures],
    synchronousCaptureLengths,
    "populated backup passphrase",
  );

  if (consoleCaptureFailures.length > 0) {
    throw new Error(
      `backup-passphrase console surfaces were uninspectable at: ${consoleCaptureFailures.join(", ")}`,
    );
  }

  if (!livePassphraseAudit.dedicatedInputExact) {
    throw new Error("backup-passphrase:allowed-input:#backup-passphrase was not exact");
  }

  if (livePassphraseAudit.findings.length > 0) {
    throw new Error(
      `backup-passphrase live surface findings: ${livePassphraseAudit.findings
        .map(({ kind, path }) => `${kind}:${path}`)
        .join(", ")}`,
    );
  }

  assertCanaryAbsent(consoleSurfaces, "backup-passphrase:browser-console", backupPassphrase);
  assertCanaryAbsent(exceptionSurfaces, "backup-passphrase:browser-errors", backupPassphrase);

  const backupOrigin = new URL(page.url()).origin;
  const backupRequestPromise = page.waitForRequest((request) => {
    const url = new URL(request.url());
    return request.method() === "POST" && url.pathname === "/backups";
  });

  await page.getByRole("button", { name: "Create encrypted backup", exact: true }).click();
  const backupRequest = await backupRequestPromise;
  await waitForSecretFreeBrowserState(
    page,
    "backup redirect URL",
    async () => page.url(),
    (surface) => {
      const url = new URL(surface);
      const operationId = url.searchParams.get("operation_id");

      return (
        url.origin === backupOrigin &&
        url.pathname === "/backups" &&
        url.hash === "" &&
        operationId !== null &&
        url.searchParams.size === 1 &&
        /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(
          operationId,
        )
      );
    },
    observedBrowserSurfaces,
    activeBrowserCanaries,
  );

  const backupContentType = await backupRequest.headerValue("content-type");

  if (
    new URL(backupRequest.url()).origin !== backupOrigin ||
    !backupContentType?.match(/^application\/x-www-form-urlencoded(?:;|$)/i)
  ) {
    throw new Error("backup submission did not use the same-origin URL-encoded controller form");
  }

  const returnedFieldState = await page.locator("#backup-passphrase").evaluate((input) => {
    const passwordInput = input as HTMLInputElement;

    return {
      valueEmpty: passwordInput.value === "",
      defaultValueEmpty: passwordInput.defaultValue === "",
      valueAttributeAbsent: !passwordInput.hasAttribute("value"),
    };
  });
  const retainedFieldPaths = Object.entries(returnedFieldState)
    .map(([_path, clean], index) => ({ clean, index }))
    .filter(({ clean }) => !clean)
    .map(({ index }) => `field:${index}`);

  if (retainedFieldPaths.length > 0) {
    throw new Error(
      `backup-passphrase returned field retained paths: ${retainedFieldPaths.join(", ")}`,
    );
  }

  const returnedPassphraseAudit = await auditLiveBackupPassphrase(
    page,
    backupPassphrase,
    false,
  );

  if (returnedPassphraseAudit.dedicatedInputExact) {
    throw new Error("backup-passphrase returned surface retained the dedicated input value");
  }

  if (returnedPassphraseAudit.findings.length > 0) {
    throw new Error(
      `backup-passphrase returned surface findings: ${returnedPassphraseAudit.findings
        .map(({ kind, path }) => `${kind}:${path}`)
        .join(", ")}`,
    );
  }

  documents.push(
    await captureDocument(
      page,
      "returned-backups",
      csrfTokens,
      controllerCsrfTokens,
      csrfOccurrenceKinds,
    ),
  );
  await waitForSecretFreeBrowserState(
    page,
    "backup terminal status text",
    () => page.locator("#backup-status").textContent(),
    (surface) => surface.trim() === "Encrypted backup sealed.",
    observedBrowserSurfaces,
    activeBrowserCanaries,
    45_000,
  );

  await drainCapturePromises(
    page,
    [responseCaptures, requestCaptures, consoleCaptures],
    synchronousCaptureLengths,
    "terminal backup",
  );

  const terminalReturnedPassphraseAudit = await auditLiveBackupPassphrase(
    page,
    backupPassphrase,
    false,
  );

  if (terminalReturnedPassphraseAudit.dedicatedInputExact) {
    throw new Error("backup-passphrase terminal surface retained the dedicated input value");
  }

  if (terminalReturnedPassphraseAudit.findings.length > 0) {
    throw new Error(
      `backup-passphrase terminal surface findings: ${terminalReturnedPassphraseAudit.findings
        .map(({ kind, path }) => `${kind}:${path}`)
        .join(", ")}`,
    );
  }

  if (responseCaptureFailures.length > 0) {
    throw new Error(
      `application response bodies were uninspectable at: ${responseCaptureFailures.join(", ")}`,
    );
  }

  if (xhrResponseCaptureFailures.length > 0) {
    throw new Error(
      `XHR response bodies were uninspectable at: ${xhrResponseCaptureFailures.join(", ")}`,
    );
  }

  if (
    pendingXhrApplicationResponses.length > 0 ||
    capturedXhrResponseBodies.length > 0
  ) {
    throw new Error("unexpected additional upload XHR response body capture");
  }

  if (consoleCaptureFailures.length > 0) {
    throw new Error(`browser console surfaces were uninspectable at: ${consoleCaptureFailures.join(", ")}`);
  }

  if (exceptionCaptureFailures.length > 0) {
    throw new Error(
      `browser exception surfaces were uninspectable at: ${exceptionCaptureFailures.join(", ")}`,
    );
  }

  const canaries: SecretCanaries = {
    "owner-password": ownerPassword,
    "backup-passphrase": backupPassphrase,
    "upload-token": uploadToken,
  };

  assertSecretFree(observedBrowserSurfaces, "observed browser URL and text states", canaries);

  for (const csrfToken of csrfTokens) {
    assertCanaryAbsent(
      observedBrowserSurfaces,
      "observed browser URL and text states:csrf-token",
      csrfToken,
    );
  }

  for (const document of documents) {
    assertSecretFree(document.sanitizedHtml, `${document.label} sanitized HTML`, {
      ...canaries,
      "csrf-token": [...csrfTokens].find((token) =>
        occurrencePaths(document.sanitizedHtml, token).length > 0,
      ),
    });
    assertSecretFree(document.dataProps, `${document.label} data-props`, {
      ...canaries,
      "csrf-token": [...csrfTokens].find((token) =>
        occurrencePaths(document.dataProps, token).length > 0,
      ),
    });
  }

  for (const [responseIndex, response] of responses.entries()) {
    const csrfInResponseSurface = [...csrfTokens].find((token) =>
      occurrencePaths({ url: response.url, headers: response.headers }, token).length > 0,
    );
    assertSecretFree(
      { url: response.url, headers: response.headers },
      `${response.kind} response surface at response:${responseIndex}`,
      { ...canaries, "csrf-token": csrfInResponseSurface },
    );

    if (response.kind === "no-consumed-body") {
      continue;
    }

    if (response.body === undefined) {
      throw new Error(`application response body was missing at response:${responseIndex}`);
    }

    assertSecretFree(response.body, `${response.kind} response body at response:${responseIndex}`, canaries);

    if (response.kind === "application-json") {
      const applicationJson = parseFrame(response.body);
      const csrfOccurrenceCount = [...csrfTokens].reduce(
        (count, token) => count + occurrencePaths(applicationJson, token).length,
        0,
      );

      if (csrfOccurrenceCount > 0) {
        throw new Error(
          `application-json response:${responseIndex} retained CSRF occurrence count:${csrfOccurrenceCount}`,
        );
      }
    }
  }

  assertSecretFree(consoleSurfaces, "browser console", {
    ...canaries,
    "csrf-token": [...csrfTokens].find((token) =>
      occurrencePaths(consoleSurfaces, token).length > 0,
    ),
  });
  assertSecretFree(exceptionSurfaces, "browser exception inspection", {
    ...canaries,
    "csrf-token": [...csrfTokens].find((token) =>
      occurrencePaths(exceptionSurfaces, token).length > 0,
    ),
  });
  assertSecretFree(frames, "LiveView application and server-pushed payloads", {
    "owner-password": ownerPassword,
    "backup-passphrase": backupPassphrase,
  });
  assertSecretFree(requests, "browser request URL and header surfaces", {
    "owner-password": ownerPassword,
    "backup-passphrase": backupPassphrase,
  });

  assertRequestHeaderAllowances(
    requests,
    uploadOrigin,
    grantId,
    uploadToken,
    csrfTokens,
    csrfOccurrenceKinds,
  );
  await assertCsrfFrameAllowance(
    page,
    frames,
    csrfTokens,
    controllerCsrfTokens,
    csrfOccurrenceKinds,
    uploadOrigin,
  );

  const collapsedCsrfKinds = expectedCsrfOccurrenceKinds.filter((kind) =>
    csrfOccurrenceKinds.has(kind),
  );
  expect(collapsedCsrfKinds).toEqual(expectedCsrfOccurrenceKinds);
});
