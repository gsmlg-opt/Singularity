import {
  existsSync,
  readFileSync,
  readdirSync,
  realpathSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import type { Browser, Page, Response, WebSocket } from "@playwright/test";

import {
  browserRestoreInvocation,
  expect,
  loginAndUnlock,
  runBrowserRestoreWithDependencies,
  test,
  type BrowserRestoreProcessDependencies,
  type BrowserState,
} from "./support/fixtures";

test.use({ screenshot: "off", trace: "off", video: "off" });

test.afterEach(async ({ page }, testInfo) => {
  if (testInfo.status === testInfo.expectedStatus) return;
  await page
    .evaluate(() => document.body.replaceChildren("Private state redacted"))
    .catch(() => {});
});

type Reply = Record<string, unknown>;
type CapturedReply = { event: string; reply: Reply };

function record(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function liveViewHookReply(value: Record<string, unknown>): Record<string, unknown> {
  let current = value;

  for (let depth = 0; depth < 6; depth += 1) {
    if (typeof current.ok === "boolean") return current;
    if (record(current.reply)) {
      current = current.reply;
    } else if (record(current.diff)) {
      current = current.diff;
    } else if (record(current.r)) {
      current = current.r;
    } else if (record(current.response)) {
      current = current.response;
    } else {
      break;
    }
  }

  return current;
}

function textPayload(payload: string | Buffer): string {
  return typeof payload === "string" ? payload : payload.toString("utf8");
}

function bridgeCapture(page: Page) {
  const references = new Map<string, string>();
  const replies: CapturedReply[] = [];
  const rawFrames: string[] = [];
  const receivedFrames: string[] = [];

  const attach = (socket: WebSocket) => {
    socket.on("framesent", ({ payload }) => {
      const frame = textPayload(payload);
      rawFrames.push(frame);
      try {
        const parsed = JSON.parse(frame);
        if (
          Array.isArray(parsed) &&
          typeof parsed[1] === "string" &&
          parsed[3] === "event" &&
          record(parsed[4]) &&
          parsed[4].type === "hook" &&
          typeof parsed[4].event === "string"
        ) {
          references.set(parsed[1], parsed[4].event);
        }
      } catch {
        // Binary and non-Phoenix frames are irrelevant to the hook reply oracle.
      }
    });

    socket.on("framereceived", ({ payload }) => {
      const frame = textPayload(payload);
      rawFrames.push(frame);
      receivedFrames.push(frame);
      try {
        const parsed = JSON.parse(frame);
        if (!Array.isArray(parsed) || typeof parsed[1] !== "string" || parsed[3] !== "phx_reply") {
          return;
        }
        const event = references.get(parsed[1]);
        const payload = parsed[4];
        if (!event || !record(payload) || !record(payload.response)) return;
        replies.push({ event, reply: liveViewHookReply(payload.response) });
      } catch {
        // Keep the raw frame only for the post-logout absence check.
      }
    });
  };

  page.on("websocket", attach);

  return {
    clear: () => {
      references.clear();
      replies.length = 0;
      rawFrames.length = 0;
      receivedFrames.length = 0;
    },
    rawFrames,
    receivedFrames,
    async reply(event: string, occurrence = 0): Promise<Reply> {
      await expect
        .poll(() => replies.filter((candidate) => candidate.event === event).length, {
          message: `Expected a ${event} bridge reply`,
          timeout: 15_000,
        })
        .toBeGreaterThan(occurrence);
      return replies.filter((candidate) => candidate.event === event)[occurrence].reply;
    },
  };
}

function successfulResult(reply: Reply, shape: string): Record<string, unknown> {
  if (reply.ok !== true || !record(reply.result)) {
    throw new Error(`Notes bridge returned an invalid ${shape} result`);
  }
  return reply.result;
}

function noteResult(reply: Reply, shape: string): Record<string, unknown> {
  const result = successfulResult(reply, shape);
  if (
    typeof result.resourceId !== "string" ||
    typeof result.resourceVersionId !== "string" ||
    typeof result.revision !== "number" ||
    typeof result.title !== "string" ||
    typeof result.markdown !== "string"
  ) {
    throw new Error(`Notes bridge returned incomplete ${shape} coordinates`);
  }
  return result;
}

function saveResult(reply: Reply, shape: string): Record<string, unknown> {
  const result = successfulResult(reply, shape);
  if (
    typeof result.outcome !== "string" ||
    typeof result.submittedVersionId !== "string" ||
    !record(result.canonical)
  ) {
    throw new Error(`Notes bridge returned incomplete ${shape} coordinates`);
  }
  return result;
}

function exactPrivateValue(page: Page, selector: string, expected: string): Promise<boolean> {
  return page
    .locator(selector)
    .evaluate(
      (element, privateValue) =>
        (element instanceof HTMLInputElement || element instanceof HTMLTextAreaElement) &&
        element.value === privateValue,
      expected,
    );
}

function privateSurfaceAbsent(surface: string, privateValues: readonly string[]): boolean {
  return privateValues.every((value) => !surface.includes(value));
}

async function domSurface(page: Page): Promise<string> {
  return page.evaluate(() =>
    JSON.stringify({
      controls: [
        ...document.querySelectorAll<HTMLInputElement | HTMLTextAreaElement>("input,textarea"),
      ].map((control) => control.value),
      html: document.body.innerHTML,
      text: document.body.innerText,
    }),
  );
}

function requiredPrivateCoordinate(value: unknown): string {
  if (typeof value !== "string" || value === "") {
    throw new Error("Private workflow coordinate is unavailable");
  }
  return value;
}

async function openNotes(page: Page): Promise<void> {
  await page.getByRole("link", { name: "Notes", exact: true }).click();
  await expect(page).toHaveURL("/notes");
  await expect(page.getByRole("region", { name: "Private notes workspace" })).toBeVisible();
}

async function newPrimaryPage(browser: Browser): Promise<{
  capture: ReturnType<typeof bridgeCapture>;
  context: Awaited<ReturnType<Browser["newContext"]>>;
  page: Page;
}> {
  const context = await browser.newContext({ baseURL: "http://127.0.0.1:4002" });
  const page = await context.newPage();
  const capture = bridgeCapture(page);
  await loginAndUnlock(page, "primary");
  await openNotes(page);
  return { capture, context, page };
}

function singleBundle(state: BrowserState): string {
  const webRoot = join(state.backupRoot, "web");
  const bundles = readdirSync(webRoot)
    .map((entry) => join(webRoot, entry))
    .filter((path) => statSync(path).isFile() && path.endsWith(".bundle"));
  if (bundles.length !== 1) throw new Error("Expected exactly one sealed browser backup bundle");
  return realpathSync(bundles[0]);
}

test("restore wrapper transports its secret only through stdin fd 0", async () => {
  const passphrase = `transport-${crypto.randomUUID()}`;
  const destinationRunId = crypto.randomUUID();
  const invocation = browserRestoreInvocation(
    "/public/source.bundle",
    "/private/expected.json",
    passphrase,
    destinationRunId,
  );

  expect(invocation.args).toEqual([
    "singularity.test.browser_restore",
    "--source",
    "/public/source.bundle",
    "--expected",
    "/private/expected.json",
    "--passphrase-fd",
    "0",
    "--destination-run-id",
    destinationRunId,
  ]);
  expect(invocation.args.includes(passphrase)).toBe(false);
  expect(Object.values(invocation.environment).includes(passphrase)).toBe(false);
  expect(invocation.input === passphrase).toBe(true);
});

test("restore SIGKILL invokes secret-free deterministic cleanup and removes expected snapshot", async () => {
  const destinationRunId = "323e4567-e89b-42d3-a456-426614174000";
  const passphrase = `timeout-${crypto.randomUUID()}`;
  const expectedPath = join(tmpdir(), `restore-timeout-${crypto.randomUUID()}.json`);
  const requests: Parameters<BrowserRestoreProcessDependencies["spawn"]>[0][] = [];

  const dependencies: BrowserRestoreProcessDependencies = {
    destinationRunId: () => destinationRunId,
    removeExpected: (path) => rmSync(path, { force: true }),
    spawn: (request) => {
      requests.push(request);
      return requests.length === 1
        ? { error: null, signal: "SIGKILL", status: null, stderr: "", stdout: "" }
        : { error: null, signal: null, status: 0, stderr: "", stdout: "" };
    },
    writeExpected: (snapshot) => {
      writeFileSync(expectedPath, JSON.stringify(snapshot), { flag: "wx", mode: 0o600 });
      return expectedPath;
    },
  };

  let failure = "";
  try {
    runBrowserRestoreWithDependencies(
      { expectedSnapshot: { private: true }, passphrase, source: "/public/source.bundle" },
      dependencies,
    );
  } catch (error) {
    failure = error instanceof Error ? error.message : "unknown";
  }

  expect(failure).toBe("Notes browser restore failed");
  expect(requests).toHaveLength(2);
  expect(requests[1].args).toEqual([
    "singularity.test.browser_restore",
    "--cleanup-destination-run-id",
    destinationRunId,
  ]);
  expect(requests[1].input).toBeUndefined();
  expect(requests[1].args.includes(passphrase)).toBe(false);
  expect(requests[1].args.includes(expectedPath)).toBe(false);
  expect(Object.values(requests[1].environment).includes(passphrase)).toBe(false);
  expect(Object.values(requests[1].environment).includes(expectedPath)).toBe(false);
  expect(existsSync(expectedPath)).toBe(false);
});

test("restore cleanup failure remains generic and removes expected snapshot after normal success", async () => {
  const destinationRunId = "423e4567-e89b-42d3-a456-426614174000";
  const expectedPath = join(tmpdir(), `restore-cleanup-${crypto.randomUUID()}.json`);
  const requests: Parameters<BrowserRestoreProcessDependencies["spawn"]>[0][] = [];

  const dependencies: BrowserRestoreProcessDependencies = {
    destinationRunId: () => destinationRunId,
    removeExpected: (path) => rmSync(path, { force: true }),
    spawn: (request) => {
      requests.push(request);
      return requests.length === 1
        ? {
            error: null,
            signal: null,
            status: 0,
            stderr: "",
            stdout: "notes_browser_restore_ok=true\n",
          }
        : { error: null, signal: null, status: 1, stderr: "", stdout: "" };
    },
    writeExpected: (snapshot) => {
      writeFileSync(expectedPath, JSON.stringify(snapshot), { flag: "wx", mode: 0o600 });
      return expectedPath;
    },
  };

  let failure = "";
  try {
    runBrowserRestoreWithDependencies(
      {
        expectedSnapshot: { private: true },
        passphrase: `cleanup-${crypto.randomUUID()}`,
        source: "/public/source.bundle",
      },
      dependencies,
    );
  } catch (error) {
    failure = error instanceof Error ? error.message : "unknown";
  }

  expect(failure).toBe("Notes browser restore cleanup failed");
  expect(requests).toHaveLength(2);
  expect(existsSync(expectedPath)).toBe(false);
});

test("private Notes survives conflict, backup restore, isolation, and terminal purge", async ({
  browser,
  browserState,
  page,
  loginAsPrimary,
  restoreBrowserBackup,
  unlockPrimary,
}) => {
  test.setTimeout(180_000);

  const title = `Acceptance ${browserState.runId.slice(0, 8)}`;
  const canonicalTitle = `${title} canonical`;
  const mergedTitle = `${title} merged`;
  const initialMarkdown = `# Initial private ${crypto.randomUUID()}\n\nCANARY_PRIVATE_INITIAL`;
  const canonicalMarkdown = `# Canonical private ${crypto.randomUUID()}\n\nCANARY_PRIVATE_CANONICAL`;
  const competingMarkdown = `# Competing private ${crypto.randomUUID()}\n\nCANARY_PRIVATE_COMPETING`;
  const mergedMarkdown = `# Merged private ${crypto.randomUUID()}\n\nCANARY_PRIVATE_MERGED`;
  const privateValues = [
    title,
    canonicalTitle,
    mergedTitle,
    initialMarkdown,
    canonicalMarkdown,
    competingMarkdown,
    mergedMarkdown,
    "CANARY_PRIVATE_INITIAL",
    "CANARY_PRIVATE_CANONICAL",
    "CANARY_PRIVATE_COMPETING",
    "CANARY_PRIVATE_MERGED",
  ];
  const capture = bridgeCapture(page);
  let secondPrimaryContext: Awaited<ReturnType<Browser["newContext"]>> | undefined;
  let secondPrimaryPage: Page;
  let secondCapture: ReturnType<typeof bridgeCapture>;
  let created: Record<string, unknown>;
  let canonical: Record<string, unknown>;
  let competingSave: Record<string, unknown>;
  let conflictDetail: Record<string, unknown>;
  let merged: Record<string, unknown>;
  let exportHeaders: Record<string, string>;
  let exportBytes: string;
  let targetPrivateReferences: string[] = privateValues;

  await loginAsPrimary();
  await unlockPrimary();
  await openNotes(page);

  await test.step("create revision zero and open the same old base in a second primary context", async () => {
    await page.getByRole("button", { name: "New note", exact: true }).click();
    await page.getByLabel("Note title", { exact: true }).fill(title);
    await page.getByLabel("Markdown source", { exact: true }).fill(initialMarkdown);
    await page.getByRole("button", { name: "Save", exact: true }).click();
    await expect(page.getByText("Version 1 · Saved", { exact: true })).toBeVisible();
    const created = noteResult(await capture.reply("note:create"), "create");
    expect(created.revision).toBe(0);

    const second = await newPrimaryPage(browser);
    secondPrimaryContext = second.context;
    secondPrimaryPage = second.page;
    secondCapture = second.capture;
    await second.page.getByRole("button", { name: `Open ${title}`, exact: true }).click();
    await expect(second.page.getByLabel("Notes workspace status", { exact: true })).toHaveText(
      "Pinned version opened read-only.",
    );
    await second.page.getByRole("button", { name: "Open current", exact: true }).click();
    await expect(second.page.getByLabel("Notes workspace status", { exact: true })).toHaveText(
      "Current note opened.",
    );
    await expect(second.page.getByText("Version 1 · Saved", { exact: true })).toBeVisible();
    await expect
      .poll(() => exactPrivateValue(second.page, '[aria-label="Markdown source"]', initialMarkdown))
      .toBe(true);
  });

  try {
    created = noteResult(await capture.reply("note:create"), "create");

    await test.step("save and search the exact canonical version", async () => {
      await page.getByLabel("Note title", { exact: true }).fill(canonicalTitle);
      await page.getByLabel("Markdown source", { exact: true }).fill(canonicalMarkdown);
      await page.getByRole("button", { name: "Save", exact: true }).click();
      await expect(page.getByText("Version 2 · Saved", { exact: true })).toBeVisible();
      canonical = saveResult(await capture.reply("note:save"), "canonical save");
      expect(canonical.outcome).toBe("saved");

      await page.getByLabel("Search notes", { exact: true }).fill(canonicalTitle);
      await page.getByRole("button", { name: "Search", exact: true }).click();
      await expect(
        page.getByRole("button", { name: `Open ${canonicalTitle}`, exact: true }),
      ).toBeVisible();
      const search = successfulResult(await capture.reply("note:search"), "search");
      const canonicalNote = canonical.canonical;
      const items = search.items;

      if (
        !record(canonicalNote) ||
        !Array.isArray(items) ||
        items.length !== 1 ||
        !record(items[0])
      ) {
        throw new Error("Canonical search result is incomplete");
      }

      expect(canonicalNote.revision).toBe(1);
      expect(canonicalNote.displayVersion).toBe(2);
      expect(items[0].resourceId === canonicalNote.resourceId).toBe(true);
      expect(items[0].resourceVersionId === canonicalNote.resourceVersionId).toBe(true);
      expect(items[0].revision === canonicalNote.revision).toBe(true);
      expect(items[0].displayVersion === canonicalNote.displayVersion).toBe(true);
    });

    await test.step("preserve a competing old-base save and merge its exact two parents", async () => {
      await secondPrimaryPage
        .getByLabel("Markdown source", { exact: true })
        .fill(competingMarkdown);
      await secondPrimaryPage.getByRole("button", { name: "Save", exact: true }).click();
      competingSave = saveResult(await secondCapture.reply("note:save"), "competing save");
      expect(competingSave.outcome).toBe("conflict");
      expect(typeof competingSave.conflictId).toBe("string");

      await secondPrimaryPage.getByRole("button", { name: "Conflict", exact: true }).click();
      conflictDetail = successfulResult(
        await secondCapture.reply("note:conflict"),
        "conflict detail",
      );
      const conflictCurrent = conflictDetail.current as Record<string, unknown>;
      const conflictCompeting = conflictDetail.competing as Record<string, unknown>;
      expect(conflictCurrent.revision).toBe(1);
      expect(conflictCompeting.revision).toBe(2);
      await expect
        .poll(() =>
          exactPrivateValue(secondPrimaryPage, '[aria-label="Current"]', canonicalMarkdown),
        )
        .toBe(true);
      await expect
        .poll(() =>
          exactPrivateValue(secondPrimaryPage, '[aria-label="Competing"]', competingMarkdown),
        )
        .toBe(true);

      await secondPrimaryPage
        .getByRole("button", { name: "Merge these versions", exact: true })
        .click();
      await secondPrimaryPage.getByLabel("Note title", { exact: true }).fill(mergedTitle);
      await secondPrimaryPage.getByLabel("Markdown source", { exact: true }).fill(mergedMarkdown);
      await secondPrimaryPage.getByRole("button", { name: "Save merge", exact: true }).click();
      merged = saveResult(await secondCapture.reply("note:merge"), "merge");
      expect(merged.outcome).toBe("saved");
      expect(merged.conflictId).toBeNull();
      const mergeCanonical = merged.canonical as Record<string, unknown>;
      expect(mergeCanonical.revision).toBe(3);
      await expect(secondPrimaryPage.getByText("Version 4 · Saved", { exact: true })).toBeVisible();

      const canonicalNote = canonical.canonical as Record<string, unknown>;
      const current = conflictDetail.current as Record<string, unknown>;
      const competing = conflictDetail.competing as Record<string, unknown>;

      targetPrivateReferences = [
        ...privateValues,
        requiredPrivateCoordinate(created.resourceId),
        requiredPrivateCoordinate(created.resourceVersionId),
        requiredPrivateCoordinate(canonicalNote.resourceVersionId),
        requiredPrivateCoordinate(competingSave.submittedVersionId),
        requiredPrivateCoordinate(mergeCanonical.resourceVersionId),
        requiredPrivateCoordinate(conflictDetail.conflictId),
        requiredPrivateCoordinate(conflictDetail.baseVersionId),
        requiredPrivateCoordinate(conflictDetail.observedCanonicalVersionId),
        requiredPrivateCoordinate(current.resourceVersionId),
        requiredPrivateCoordinate(current.parentVersionId),
        requiredPrivateCoordinate(competing.resourceVersionId),
        requiredPrivateCoordinate(competing.parentVersionId),
        "Version 1 · Saved",
        "Version 2 · Saved",
        "Version 3 · Saved",
        "Version 4 · Saved",
      ].filter((value, index, values) => values.indexOf(value) === index);
    });

    await test.step("export exact bytes and headers, tombstone, prove absence, and restore", async () => {
      const responsePromise = secondPrimaryPage.waitForResponse((response) => {
        const url = new URL(response.url());
        return response.request().method() === "GET" && url.pathname.endsWith("/export");
      });
      const downloadPromise = secondPrimaryPage.waitForEvent("download");
      await secondPrimaryPage
        .getByRole("link", { name: `Export ${mergedTitle}`, exact: true })
        .click();
      const [response, download] = await Promise.all([responsePromise, downloadPromise]);
      exportBytes = readFileSync(await download.path(), "utf8");
      exportHeaders = {
        content_disposition: response.headers()["content-disposition"],
        content_type: response.headers()["content-type"],
        x_content_type_options: response.headers()["x-content-type-options"],
      };
      expect(exportBytes === mergedMarkdown).toBe(true);
      expect(exportHeaders.content_type).toBe("text/markdown; charset=utf-8");
      expect(exportHeaders.x_content_type_options).toBe("nosniff");

      await secondPrimaryPage.getByRole("button", { name: "Delete", exact: true }).click();
      await expect(
        secondPrimaryPage.getByLabel("Notes workspace status", { exact: true }),
      ).toHaveText("Note moved to Trash.");
      await secondPrimaryPage.getByLabel("Search notes", { exact: true }).fill(mergedTitle);
      await secondPrimaryPage.getByRole("button", { name: "Search", exact: true }).click();
      await expect(
        secondPrimaryPage.getByRole("button", { name: `Open ${mergedTitle}` }),
      ).toHaveCount(0);
      const tombstonedRead = await secondPrimaryPage.request.get(
        `/api/v1/notes/${created.resourceId}/export`,
      );
      expect(tombstonedRead.status()).toBe(404);
      expect(privateSurfaceAbsent(await tombstonedRead.text(), privateValues)).toBe(true);

      await secondPrimaryPage.getByRole("button", { name: "Trash", exact: true }).click();
      await expect(
        secondPrimaryPage.getByRole("button", { name: `Restore ${mergedTitle}`, exact: true }),
      ).toBeVisible();
      await secondPrimaryPage
        .getByRole("button", { name: `Restore ${mergedTitle}`, exact: true })
        .click();
      await expect(
        secondPrimaryPage.getByLabel("Notes workspace status", { exact: true }),
      ).toHaveText("Note restored.");
    });

    await test.step("secondary owner cannot observe any target coordinate or private value", async () => {
      const secondaryContext = await browser.newContext({ baseURL: "http://127.0.0.1:4002" });
      try {
        const secondaryPage = await secondaryContext.newPage();
        const secondaryFrames = bridgeCapture(secondaryPage);
        await loginAndUnlock(secondaryPage, "secondary");
        await openNotes(secondaryPage);
        const secondaryQuery = secondaryPage.getByLabel("Search notes", { exact: true });
        await secondaryQuery.fill(mergedTitle);
        await secondaryPage.getByRole("button", { name: "Search", exact: true }).click();
        const search = successfulResult(
          await secondaryFrames.reply("note:search"),
          "secondary search",
        );
        expect(Array.isArray(search.items) && search.items.length === 0).toBe(true);
        await secondaryQuery.fill("");

        expect((await secondaryPage.locator(".notes-count").textContent()) === "0").toBe(true);
        expect(privateSurfaceAbsent(await domSurface(secondaryPage), targetPrivateReferences)).toBe(
          true,
        );
        expect(
          privateSurfaceAbsent(
            JSON.stringify(secondaryFrames.receivedFrames),
            targetPrivateReferences,
          ),
        ).toBe(true);

        const directNotes = await secondaryPage.request.get("/notes");
        const directNotesSurface = JSON.stringify({
          body: await directNotes.text(),
          headers: directNotes.headers(),
          status: directNotes.status(),
        });
        expect(directNotes.status()).toBe(200);
        expect(privateSurfaceAbsent(directNotesSurface, targetPrivateReferences)).toBe(true);

        const forbiddenExport = await secondaryPage.request.get(
          `/api/v1/notes/${created.resourceId}/export`,
        );
        expect([403, 404]).toContain(forbiddenExport.status());
        const forbiddenSurface = JSON.stringify({
          body: await forbiddenExport.text(),
          headers: forbiddenExport.headers(),
          frames: secondaryFrames.receivedFrames,
        });
        expect(privateSurfaceAbsent(forbiddenSurface, targetPrivateReferences)).toBe(true);
      } finally {
        await secondaryContext.close();
      }
    });

    await test.step("seal one bundle and verify it through the isolated restore task", async () => {
      const backupPassphrase = `backup-${crypto.randomUUID()}`;
      await secondPrimaryPage.getByRole("link", { name: "Backups", exact: true }).click();
      await secondPrimaryPage
        .getByLabel("Backup passphrase", { exact: true })
        .fill(backupPassphrase);
      await secondPrimaryPage
        .getByRole("button", { name: "Create encrypted backup", exact: true })
        .click();
      await expect(secondPrimaryPage.locator("#backup-status")).toHaveText(
        "Encrypted backup sealed.",
        { timeout: 45_000 },
      );

      const canonicalNote = canonical.canonical as Record<string, unknown>;
      const competingCanonical = competingSave.canonical as Record<string, unknown>;
      const mergeCanonical = merged.canonical as Record<string, unknown>;
      const current = conflictDetail.current as Record<string, unknown>;
      const competing = conflictDetail.competing as Record<string, unknown>;

      const expectedSnapshot = {
        version: 1,
        vault_id: browserState.owners.primary.vaultId,
        notes: [
          {
            resource_id: created.resourceId,
            current_version_id: mergeCanonical.resourceVersionId,
            title: mergedTitle,
            markdown: mergedMarkdown,
            deleted: false,
            versions: [
              {
                resource_version_id: created.resourceVersionId,
                revision: 0,
                parent_version_id: null,
                merge_parent_version_id: null,
                title,
                markdown: initialMarkdown,
              },
              {
                resource_version_id: canonicalNote.resourceVersionId,
                revision: 1,
                parent_version_id: created.resourceVersionId,
                merge_parent_version_id: null,
                title: canonicalTitle,
                markdown: canonicalMarkdown,
              },
              {
                resource_version_id: competingSave.submittedVersionId,
                revision: 2,
                parent_version_id: created.resourceVersionId,
                merge_parent_version_id: null,
                title,
                markdown: competingMarkdown,
              },
              {
                resource_version_id: mergeCanonical.resourceVersionId,
                revision: 3,
                parent_version_id: current.resourceVersionId,
                merge_parent_version_id: competing.resourceVersionId,
                title: mergedTitle,
                markdown: mergedMarkdown,
              },
            ],
            conflicts: [
              {
                conflict_id: conflictDetail.conflictId,
                base_version_id: conflictDetail.baseVersionId,
                canonical_version_id: conflictDetail.observedCanonicalVersionId,
                competing_version_id: competingSave.submittedVersionId,
                state: "resolved",
                resolution_version_id: mergeCanonical.resourceVersionId,
              },
            ],
            export: {
              bytes: exportBytes,
              content_type: exportHeaders.content_type,
              content_disposition: exportHeaders.content_disposition,
              x_content_type_options: exportHeaders.x_content_type_options,
            },
          },
        ],
      };

      expect(canonicalNote.resourceVersionId).toBe(competingCanonical.resourceVersionId);
      const result = restoreBrowserBackup({
        expectedSnapshot,
        passphrase: backupPassphrase,
        source: singleBundle(browserState),
      });
      expect(result.marker).toBe("notes_browser_restore_ok=true");
    });

    await test.step("logout purges React synchronously and all direct surfaces stay private", async () => {
      await secondPrimaryPage.getByRole("link", { name: "Notes", exact: true }).click();
      await secondPrimaryPage
        .getByRole("button", { name: `Open ${mergedTitle}`, exact: true })
        .click();
      await secondPrimaryPage.getByRole("button", { name: "Open current", exact: true }).click();
      await expect
        .poll(() =>
          exactPrivateValue(secondPrimaryPage, '[aria-label="Markdown source"]', mergedMarkdown),
        )
        .toBe(true);

      secondCapture.clear();
      const responseSurfaces: string[] = [];
      const responseCaptures: Promise<void>[] = [];
      const captureResponse = (response: Response) => {
        const capture = (async () => {
          try {
            responseSurfaces.push(
              JSON.stringify({
                headers: response.headers(),
                status: response.status(),
                body: await response.text(),
              }),
            );
          } catch {
            responseSurfaces.push(
              JSON.stringify({ headers: response.headers(), status: response.status() }),
            );
          }
        })();
        responseCaptures.push(capture);
      };
      secondPrimaryPage.on("response", captureResponse);

      await secondPrimaryPage.evaluate(async () => {
        const csrf = document
          .querySelector<HTMLMetaElement>('meta[name="csrf-token"]')
          ?.getAttribute("content");
        if (!csrf) throw new Error("Missing CSRF token");
        await fetch("/logout", {
          method: "DELETE",
          headers: { "x-csrf-token": csrf },
          redirect: "manual",
        });
      });

      await secondPrimaryPage.getByRole("button", { name: "Search", exact: true }).click();
      await expect(
        secondPrimaryPage.getByRole("heading", { name: "Vault access ended", level: 1 }),
      ).toBeVisible();
      expect(
        privateSurfaceAbsent(await domSurface(secondPrimaryPage), targetPrivateReferences),
      ).toBe(true);
      expect(await secondPrimaryPage.locator(".notes-count").count()).toBe(0);

      const exportAfterLogout = await secondPrimaryPage.request.get(
        `/api/v1/notes/${created.resourceId}/export`,
      );
      const exportAfterLogoutSurface = JSON.stringify({
        body: await exportAfterLogout.text(),
        headers: exportAfterLogout.headers(),
        status: exportAfterLogout.status(),
      });
      expect(exportAfterLogout.status()).toBe(401);
      expect(privateSurfaceAbsent(exportAfterLogoutSurface, targetPrivateReferences)).toBe(true);

      const notesResponse = await secondPrimaryPage.goto("/notes");
      expect(notesResponse).not.toBeNull();
      await expect(secondPrimaryPage).toHaveURL(/\/(login|vault\/unlock)$/);
      await secondPrimaryPage.waitForLoadState("networkidle");
      secondPrimaryPage.off("response", captureResponse);
      await Promise.all(responseCaptures);

      const directNotesSurface = JSON.stringify({
        body: notesResponse === null ? "" : await notesResponse.text(),
        headers: notesResponse?.headers() ?? {},
        status: notesResponse?.status() ?? 0,
      });
      const finalSurface = JSON.stringify({
        directNotes: directNotesSurface,
        dom: await domSurface(secondPrimaryPage),
        frames: secondCapture.receivedFrames,
        responses: responseSurfaces,
      });
      expect(privateSurfaceAbsent(finalSurface, targetPrivateReferences)).toBe(true);
    });
  } finally {
    await secondPrimaryContext?.close();
  }
});
