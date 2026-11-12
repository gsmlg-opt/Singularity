# IETF RFC source

Date: 2026-11-12. Builds on v2 (`2026-11-11-singularity-knowledge-v2-design.md`), manual projects, GitHub Stars, fetch rate limits and document extraction (`2026-11-12-singularity-document-extraction-design.md`). It lifts v2's "no knowledge kinds other than software projects" for IETF RFCs only.

## 1. Goal

IETF RFCs become their own category of knowledge item, with full metadata and full text stored as Markdown. They are synced from the RFC Editor's official rsync service and checked once a month. Every sync is recorded, along with what it changed.

Success criteria:

1. After adding an "IETF RFCs" source, the first run turns every RFC (about 10,000) into a `ietf_rfc` item with metadata and Markdown content.
2. Later runs happen monthly. rsync only transfers changed files, and only items whose content actually changed get new `content` and `content_updated_at`.
3. Every run is recorded with counts of added, updated and removed items. A run's detail page lists each changed item with field-level before/after and a diff of its content.
4. Knowledge has an "IETF RFCs" entry. The list can be searched and filtered by label. The detail page shows metadata, related RFCs (linked), labels, Markdown content and the item's change history.
5. Synced files live under one configured data directory, which later sync features share.
6. The Overview section (stats, recently added, label cloud, activity) still counts software projects only.

## 2. Data directory

Every feature that keeps synced files on disk shares one root.

- Config `config :singularity, :data_dir`:
  - dev: `<project root>/tmp/data` (already ignored through `/tmp/`).
  - test: `<project root>/tmp/test-data`.
  - prod: `runtime.exs` reads `DATA_DIR`, default `/var/lib/singularity`.
- `Singularity.DataDir.path!(name)` returns `<data_dir>/<name>` and creates it (`File.mkdir_p!`). `name` is a fixed subdirectory per feature.
- This version uses one: `ietf-rfcs`.
- Deployments mount `DATA_DIR` as a persistent volume.

## 3. Data model

One migration.

### 3.1 Generic columns on `items`

| Column | Meaning |
|---|---|
| `content` | text, nullable. The item's full text as Markdown. Not RFC-specific; imported documents will use it too |
| `content_updated_at` | utc_datetime, nullable. When `content` last actually changed. Not touched when the content is unchanged |

### 3.2 `ietf_rfc` items

- `kind` = `"ietf_rfc"`.
- `external_id` = `rfc<number>`, e.g. `rfc8446`.
- `title` = the JSON `title`.
- `url` = `https://www.rfc-editor.org/rfc/rfc<number>`.
- `summary` = the JSON `abstract`, or `nil` when it is empty.
- `published_at` = midnight UTC on the first day of the publication month. `pub_date` looks like `"August 2018"`; when it cannot be parsed, `nil`.
- `attributes` (string keys):

| Key | From |
|---|---|
| `number` | integer, from `doc_id` |
| `authors` | list |
| `status` | `status` |
| `stream_source` | `source` (working group or origin, e.g. `"Transport Layer Security"`, `"Legacy"`) |
| `keywords` | list |
| `obsoletes`, `obsoleted_by`, `updates`, `updated_by`, `see_also` | lists, entries normalized to lowercase `rfc<number>` |
| `doi` | `doi` |
| `errata_url` | `errata_url` |
| `page_count` | integer, `nil` when it cannot be parsed |
| `draft` | `draft` |
| `formats` | the `format` list |
| `content_source` | `"html"` or `"text"`: which file the Markdown was made from |

- Automatic labels:
  - `status:<slug>`: `status` lowercased, spaces replaced with `-`, e.g. `status:proposed-standard`.
  - `obsoleted`: when `obsoleted_by` is not empty.
  - Keywords do not become labels.
- Observation `period` = the publication month `YYYY-MM` (`"unknown"` when it cannot be parsed). With the unique key `(source_id, item_id, period)`, each RFC has exactly one observation per source, and monthly runs add no observation rows.

### 3.3 `item_changes` (new table)

One row per item that a run changed.

| Column | Meaning |
|---|---|
| `fetch_run_id` | FK to `fetch_runs`, `on_delete: :delete_all` |
| `item_id` | FK to `items`, nullable, `on_delete: :nilify_all` |
| `kind`, `external_id`, `title` | snapshots, so the record reads well after the item is deleted |
| `change` | `"added"`, `"updated"` or `"removed"` |
| `fields` | map, field-level changes for `"updated"`: `%{"title" => %{"old" => ..., "new" => ...}, "attributes.obsoleted_by" => %{"old" => [...], "new" => [...]}}`. Empty for the other changes |
| `content_diff` | text, nullable. Unified line diff of `content` (3 lines of context) when it changed |
| `inserted_at` | utc_datetime |

Indexes on `fetch_run_id` and `(item_id, inserted_at)`.

Meaning of `change`:

- `added`: the source starts keeping the item, either by creating its `item_sources` row or by reopening a removed one. A new item, or one this source did not list before.
- `updated`: an item the source already kept, whose authoritative fields or content differ from the stored values (see 4.2).
- `removed`: the item left the source (`leave!`) in this run.

### 3.4 Counters on `fetch_runs`

`added_count`, `updated_count`, `removed_count`: integers, default 0. They are written when the run finishes.

## 4. Changes to the collection framework

### 4.1 `Singularity.Collector.Entry`

Two new fields, both `nil` by default, so existing collectors are unaffected:

- `content_path`: a file whose text is this item's Markdown content.
- `labels`: a list of strings. When it is not `nil`, it is the item's complete set of automatic labels:
  - Labels with `origin = "auto"` that are not in the list are deleted.
  - Manual labels are untouched.
  - A name that is already a manual label stays manual.

### 4.2 `Singularity.Knowledge.record/4`

The signature becomes `record(source, result, now, fetch_run_id)`. It returns `{:ok, %{count: n, added: a, updated: u, removed: r}}`. `Collection.run/2` passes the run id and stores the counters on the run.

- **Authoritative values.**
  - `software_project` keeps today's behavior: its title, description and attributes come from GitHub details, so a conflict only updates `last_seen_at` and `updated_at`.
  - For every other kind, the collected values are authoritative. A conflict also overwrites `title`, `url`, `summary`, `published_at` and `attributes`.
- **Content.**
  - At the start, one query loads `md5(content)` for the existing items of the result's kinds.
  - For each entry with a `content_path`, the file is read and its md5 is compared with the stored one.
  - Only when they differ, `content` is written and `content_updated_at` is set to `now`.
  - Files are read one at a time. Files that are not valid UTF-8 are converted from Latin-1, so stored text is always valid.
  - When a file cannot be read, the entry keeps its old content, the error is logged, and the transaction continues.
- **Labels.** When `entry.labels` is not `nil`, automatic labels are synced as in 4.1.
- **Change tracking.**
  - Before upserting an authoritative item, its current authoritative fields are loaded. After the upsert they are compared:
    - `title`, `url`, `summary` and `published_at` are compared as whole values.
    - `attributes` are compared key by key, giving names like `attributes.<key>`.
  - When content changes on an existing item, the old content is loaded for that item only. Then `Singularity.Knowledge.TextDiff.unified(old, new)` is stored as `content_diff`.
  - An existing item with field or content differences gets one `updated` row.
  - `added` rows come from `keep!`: open `item_sources` rows are loaded before inserting, so new and reopened rows can be told apart.
  - `removed` rows come from `leave!`.
  - An `added` item gets no `updated` row in the same run.
  - Fields that change on every run (`last_seen_at`, `updated_at`) are never recorded.
  - `software_project` items only get `added` and `removed` rows. Their metadata changes come from the details task, not from runs, and are out of scope.
- Everything else (observations, project detail fetching, removal grace period) is unchanged.
- **First-run size.** The first RFC run writes about 10,000 items and about 10,000 `added` rows. The transaction timeout is 10 minutes today, and Styx Lifeline rescues jobs after 30 minutes. The implementation runs one real first sync in dev and records how long rsync, conversion and `record/4` each take. If any limit is exceeded, raise that timeout and write the measurements back into this section.

### 4.3 `Singularity.Knowledge.TextDiff`

Pure functions.

- `unified(old, new, context \\ 3)`: splits both texts into lines, diffs them with `List.myers_difference/2`, and returns unified-diff hunks (`@@ -a,b +c,d @@`, lines prefixed with ` `, `-`, `+`).
- No hunks means no difference, and the result is `""`.
- Diffs longer than 1 MB are cut at a line boundary and end with the line `… diff truncated`.

## 5. Collector: `Singularity.Collectors.IetfRfc`

### 5.1 Callbacks

| Callback | Value |
|---|---|
| `kind/0` | `"ietf_rfc"` |
| `label/0` | `"IETF RFCs"` |
| `config_fields/0` | `[]` |
| `validate_config/1` | `{:ok, %{}}` |
| `default_interval_minutes/0` | `43_200` (30 days) |
| `queue/0` | `:rfc_editor` |

New queue: `rfc_editor: [limit: 1, rate_limit: [allowed: 1, period: 60]]`.

### 5.2 Fetching

The mirror is `Singularity.DataDir.path!("ietf-rfcs")`. `fetch/2` makes two rsync calls and waits between them; the wait matches the queue's rate limit. It is configurable as `request_interval`: 60 seconds by default, 0 in tests.

1. Metadata and plain text:

       rsync -rt --delete --timeout=600 \
         --include='rfc*.json' --include='rfc*.txt' --exclude='*' \
         rsync.rfc-editor.org::rfcs/ <mirror>/

2. HTML for v3 RFCs only:
   - v3 RFCs are those whose JSON `format` contains `"XML"`. Their names are written as `rfc<number>.html`, one per line, to `<mirror>/html-files.txt`.
   - Then:

         rsync -rt --timeout=600 --files-from=<mirror>/html-files.txt \
           rsync.rfc-editor.org::rfcs/ <mirror>/

   - This call has no `--delete`. HTML for RFCs that are no longer listed is removed locally, by comparing against the list.

The runner is read from config: `config :singularity, Singularity.Collectors.IetfRfc, rsync: module`.

- The default is `Singularity.Collectors.IetfRfc.Rsync`, which calls `rsync` with `System.cmd/3`.
- It returns `:ok` or `{:error, {:rsync, exit_status, output_tail}}`.
- It returns `{:error, :rsync_not_found}` when there is no `rsync` executable.

When either rsync call fails, `fetch/2` returns `{:error, reason}` and Styx retries. The mirror is kept, so the next attempt resumes.

### 5.3 Markdown conversion

Converted Markdown is cached at `<mirror>/markdown/rfc<number>.md`.

- `<mirror>/markdown/VERSION` holds the converter version, an integer constant in the collector. When it differs from the constant, every cached file is regenerated.
- Otherwise a file is regenerated only when it is missing or older than its source file.
- Bumping the version is a deliberate change. The next run records every RFC whose Markdown changed as `updated`, with a diff. That is expected, and it shows what the new converter changed.

Source and conversion:

- **v3 RFCs with an HTML file:**
  - Run `Singularity.Documents.extract/2` on the HTML, then `Markdown.clean_html/1` (pure):
    - Drop everything before the first line starting with `# RFC ` (xberg's front matter and the header table, which duplicate the metadata).
    - Remove pilcrow links `[¶](#…)`.
    - Turn in-page links `[text](#…)` into `text`.
    - Rewrite `](./rfc<number>)` to `](https://www.rfc-editor.org/rfc/rfc<number>)`.
  - `content_source = "html"`.
  - When extraction fails, fall back to the plain-text conversion below, log a warning, and set `content_source = "text"`.
- **Every other RFC:**
  - `Markdown.from_text/1` (pure) wraps the original `.txt` in a ```` ```text ```` fence and keeps it byte for byte. When the text itself contains three backticks, the fence uses more backticks than the longest run.
  - xberg is not used on plain text: it reflows lines and destroys ASCII diagrams.
  - `content_source = "text"`.
- **No `.txt` and no usable HTML:** `content_path` is `nil` and the item has no content.

### 5.4 Parsing (pure)

- `parse_dir(mirror)` walks the `rfc<digits>.json` files. Other names such as `rfcThis.json` and `-n.json` are ignored and not counted as skipped.
- `parse_rfc(json_map, markdown_path_or_nil)` builds an `Entry` with attributes, `labels` (3.2), `period` and `content_path`.
- JSON that cannot be decoded, or that lacks `doc_id` or `title`, counts toward `skipped` and does not stop the run.
- The result is `%Result{period: "<YYYY-MM of the run>", entries: entries, skipped: n, complete: true}`.
- With `skipped == 0`, RFCs the RFC Editor no longer lists leave the source, and the existing 30-day removal applies.

### 5.5 Registration

- Add `Singularity.Collectors.IetfRfc` to `config :singularity, :collectors`.
- In test config, the rsync runner is a test double and `request_interval` is 0.

## 6. Service functions

`Singularity.Knowledge`:

- `list_rfcs(opts)`:
  - `:q`: an exact number match when it is numeric, otherwise ILIKE on `title`.
  - `:label`.
  - `:page` and `:per_page` (default 50).
  - Ordered by number, descending.
- `count_rfcs(opts)`: same filters, for pagination.
- `get_rfc!(number)`: labels preloaded.
- `get_rfcs_by_external_ids(ids)`: `%{external_id => item}` for the related-RFC links. Missing ones are left out.
- `list_item_changes(item_id)`: newest first, with the run preloaded.
- The existing `add_label/2` and `remove_label/2` work for RFC items unchanged.

`Singularity.Collection`:

- `get_run!(id)`: source preloaded.
- `list_run_changes(run_id, opts)`:
  - `:change` filter.
  - `:page` and `:per_page` (default 50).
  - Ordered by change type, then `external_id`.

## 7. Interface

Follows `DESIGN.md`. Text uses the gettext domains `knowledge` and `source`.

### 7.1 Knowledge

- Add "IETF RFCs" to the Knowledge left menu, after "Software projects".
- `/knowledge/ietf-rfcs` list:
  - Toolbar: search box (number or title), and the current label filter, which can be cleared.
  - Table columns: number (`RFC 8446`, linking to the detail page), title, status badge, publication month.
  - Paginated.
- `/knowledge/ietf-rfcs/:number` detail:
  - Header:
    - `RFC 8446`, the title and a status badge.
    - External links (original, DOI, errata), routed through `/out`.
  - Metadata card: authors, working group (`stream_source`), publication month, pages, draft, keywords.
  - Related RFCs card:
    - Groups: Obsoletes, Obsoleted by, Updates, Updated by, See also. Empty groups are hidden.
    - Each RFC links to its detail page. RFCs not in the knowledge base show only their number.
  - Labels card: automatic and manual labels. Manual labels can be added and removed.
  - Content card:
    - Markdown rendered like the project README, height-limited with scrolling.
    - Without content: "Full text not synced yet."
  - History card: the item's changes, newest first. Each shows the run time and the change type, links to the run detail page, and lists changed field names.
- Subscribes to `"knowledge"`, so the list refreshes after a run.
- The Overview section is unchanged and still counts software projects only.

### 7.2 Source runs

- Rows on the existing `/source/runs` page also show `+added ~updated −removed`, and each row links to the run.
- New `/source/runs/:id` run detail:
  - Header: source, status, start and finish times, item and skipped counts, and the three change counters.
  - Tabs or filter buttons: All, Added, Updated, Removed. Paginated.
  - Each change shows:
    - The kind and title, linking to the item when it still exists.
    - For `updated`: a table of field, old value and new value.
    - When there is a `content_diff`: a collapsible diff in a monospace block, with added lines highlighted as success and removed lines as error, using DuskMoon colors.

## 8. Vector search integration point (not built)

Vector search will use Qdrant and gets its own spec. This version only guarantees these conventions:

- Every kind's full text is in `items.content`, as Markdown.
- `content_updated_at` only moves when content actually changes, so it can serve as an incremental indexing watermark. An indexer remembers the last time it processed, and only handles items with a later `content_updated_at`. A full rebuild resets the watermark.
- Qdrant point ids are `items.id`. Deleted items are reconciled by the indexer later.

No Qdrant dependency, service or indexing code is added now.

## 9. Environment and deployment

- `devenv.nix`: add `pkgs.rsync` to packages.
- Dockerfile: add `rsync` to the runtime stage's `apt-get install`.
- Production sets `DATA_DIR` and mounts a persistent volume there. The mirror and Markdown cache take about 650 MB.

## 10. Testing

- **`DataDir`**: `path!/1` returns a subdirectory of the root and creates it.
- **`TextDiff`**:
  - Identical texts give `""`.
  - A single changed line gives one hunk with 3 lines of context.
  - Lines added at the start and end.
  - Truncation past the limit.
- **`IetfRfc.Markdown`**:
  - `clean_html/1`, on xberg output saved from a real v3 RFC (fixture): front matter removed, pilcrows removed, in-page links flattened, relative RFC links rewritten.
  - `from_text/1` keeps text byte for byte and handles text that contains backtick fences.
- **`IetfRfc` parsing**, with real fixtures:
  - `rfc8446.json` (full fields, obsoletes and obsoleted_by).
  - `rfc791.json` (empty abstract).
  - `rfc9999.json` (v3, `"XML"` in `format`).
  - A broken JSON and an `rfcThis.json`.
  - Covers normal, empty directory and one broken file. Asserts attributes, labels, `period`, `content_path` and `skipped`.
- **`IetfRfc.fetch/2`**:
  - A test-double runner copies fixtures into the mirror.
  - Covers success, failure of the first or second rsync call, the `html-files.txt` list, the Markdown cache being reused, and regeneration when `VERSION` changes.
  - The real xberg runs on one small v3 HTML fixture.
- **`Knowledge.record/4`**:
  - RFC metadata is overwritten on the second run, and an `updated` row records the `attributes.obsoleted_by` change.
  - Unchanged content leaves `content_updated_at` alone and records no row.
  - Changed content updates it and stores a `content_diff`.
  - Latin-1 bytes are stored as valid text.
  - Manual labels are kept, and stale automatic labels are removed.
  - `added` rows for new items and for items rejoining a source; `removed` rows for items that left.
  - Counters are returned and stored on the run.
  - Existing software project tests keep passing unchanged, apart from the `record/4` call signature.
- **LiveView**:
  - RFC list: search by number and by title, label filter.
  - RFC detail:
    - Metadata.
    - Related RFC links, present and missing.
    - Content, or the not-synced message.
    - Adding and removing manual labels.
    - The history card.
  - Run detail: counters, filters, field table and diff rendering.

## 11. Out of scope

- Vector search, Qdrant, full-text search (tsvector).
- PDF and XML formats. HTML for RFCs before 8650.
- Internet-Drafts, errata content, the BCP/STD/FYI subseries.
- Full version history of content (only diffs are kept).
- Change tracking for software project metadata from the details task.
- Mixing RFCs into "All knowledge" or the Overview stats.
- Per-source sync directories.
