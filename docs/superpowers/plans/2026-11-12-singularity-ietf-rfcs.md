# IETF RFC source: implementation plan

Spec: `docs/superpowers/specs/2026-11-12-singularity-ietf-rfcs-design.md`.

1. **Pure building blocks** (tests first):
   - `Singularity.DataDir`, and the `:data_dir` config for dev, test and prod.
   - `Singularity.Knowledge.TextDiff.unified/3`.
   - `Singularity.Collectors.IetfRfc.Markdown`:
     - `clean_html/1`, tested against xberg output saved from RFC 9999.
     - `from_text/1`.
2. **Migration and schemas**:
   - `items.content` and `items.content_updated_at`.
   - The `item_changes` table and its `Singularity.Knowledge.ItemChange` schema.
   - Counters on `fetch_runs`.
3. **Framework**:
   - `Entry` gains `content_path` and `labels`.
   - `Knowledge.record/4`: authoritative fields for kinds other than projects, content md5 comparison, label sync, and change rows (added, updated, removed) with diffs.
   - `Collection.run/2` passes the run id and stores the counters.
   - Update the existing callers and tests.
4. **Collector** `Singularity.Collectors.IetfRfc`:
   - The `Rsync` runner and its config.
   - `fetch/2` with two rsync calls, `html-files.txt`, and the wait between calls.
   - Markdown cache with `VERSION`.
   - `parse_dir/1` and `parse_rfc/2`.
   - Register the collector. Add the `rfc_editor` queue.
   - Fixtures: real `rfc8446`, `rfc791` and `rfc9999` JSON; small txt and HTML files; a broken JSON.
5. **Service functions**:
   - `list_rfcs`, `count_rfcs`, `get_rfc!`, `get_rfcs_by_external_ids` and `list_item_changes` in `Knowledge`.
   - `get_run!` and `list_run_changes` in `Collection`.
6. **Interface** (read `DESIGN.md` first):
   - RFC list and detail pages, and the left-menu entry.
   - Counters on the runs page and the run detail page with the diff view.
   - LiveView tests. Extract gettext.
7. **Environment**:
   - `pkgs.rsync` in `devenv.nix`, and `rsync` in the Dockerfile runtime stage.
   - AGENTS.md: the data directory and the RFC source.
8. **Verification**:
   - Run format, compile and the full test suite.
   - Run a real first sync in dev and record how long rsync, conversion and `record/4` each take, in spec §4.2. Raise timeouts if needed.
   - Check that both devenv processes are ready, then take screenshots of the RFC list, the RFC detail page and the run detail page.
