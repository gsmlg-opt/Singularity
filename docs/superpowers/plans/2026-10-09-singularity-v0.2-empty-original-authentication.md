# Empty Document Original Authentication Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Parent coordinates all review and Mix execution; no concurrent Mix runs.

**Goal:** Require real ciphertext authentication before an empty Document original can return a successful public download reader.

**Architecture:** Add a request-only empty-original operation to the existing DownloadLease, using its established storage/authorization path. Compose it into the zero-byte Document preflight, preserve immutable digest comparison, and immediately revoke the fresh zero-chunk delivery lease.

**Tech Stack:** Elixir/OTP, ExUnit, PostgreSQL scoped repositories, existing ChunkedAEAD and LocalFilesystemAdapter.

---

## Authority and file ownership

Parent and independent Astra review accepted this bounded plan after correcting
the environment commands and restoring the original Task 14 repository gate.
TEST GO permits test edits only. Observe
the actual missing/corrupt regression RED before production edits. Parent owns
Mix, environment, service, and database commands; the worker must receive a
specific execution grant before running any. Workers make no Git writes. After
the scoped gates and independent reviews pass, parent may create a bounded local
commit under standing user approval. No merge, E2E, release, push, deployment,
or complete-phase acceptance.

Design: `docs/superpowers/specs/2026-10-09-singularity-v0.2-empty-original-authentication-design.md`.
Baseline: `26e16a5716dec8c3df835a7ff8e1d258249cde58`.
All paths below are relative to `.trees/v0.2-phase-2-import-extraction`.
Parent commands use `MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps`.

| File | Responsibility |
| --- | --- |
| `apps/singularity_runtime/lib/singularity/runtime/download_lease.ex` | New request-only operation, marker dispatch, completion |
| `apps/singularity_runtime/lib/singularity/runtime/documents/read.ex` | Zero-byte preflight and immediate zero-delivery revoke |
| `apps/singularity_runtime/test/singularity/runtime/download_lease_test.exs` | Append independent request-empty contract module |
| `apps/singularity_runtime/test/singularity/runtime/document_api_test.exs` | Add zero-byte facade integration and narrow read-composition contracts |

Append a narrow request test module in the existing lease test file rather than
alter worker tests or introduce a separate fixture abstraction. Reuse private
integration helpers in DocumentApiIntegrationTest. Existing test bodies remain
unchanged; additive optional fake result fields are allowed only where needed.
Do not modify shared KnowledgeFixtures, custody/storage code, migrations, or Vault.

## Task 1: Add actual empty-original regression and observe RED

**Modify:** `apps/singularity_runtime/test/singularity/runtime/document_api_test.exs`.

- [x] Add a local fixture helper `empty_original_fixture!/1` taking ExUnit's
  temporary directory. Copy only the existing real custody setup into this helper
  for the new tests; do not move the existing nonempty test. Prepare its source
  before Document insertion:

```elixir
source = %{KnowledgeFixtures.prepared_source!() |
  byte_size: 0, digest: :crypto.hash(:sha256, "")}
object_dek = :crypto.strong_rand_bytes(32)
domain_key = :crypto.strong_rand_bytes(32)
material = install_live_object!(source, "", object_dek, domain_key, storage_root)
document_source = Map.new(source, fn {key, value} ->
  {key, if(String.ends_with?(Atom.to_string(key), "_id"),
    do: Ecto.UUID.dump!(value), else: value)}
end)
document = KnowledgeFixtures.document!(document_source)
grant_runtime!(document_source)
```

  `install_live_object!/5` updates the trusted object size, encrypted byte size,
  ciphertext hash, and wrapped DEK before `document!/1`. No immutable Document
  update is needed. Set only this fixture's matching `asset_metadata`
  `plaintext_byte_size` to zero before insertion as well, keeping its projection
  coherent without editing shared fixtures. Use the existing test's KeyLeaseSupervisor and KeyCustodian
  options with CustodyReader for authorization, clock, key reader, and object key
  loader. Use its prepare/activate unlock fields with `material.domain_id` and
  `material.domain_version_id`, and `live_session(source)`. Return source,
  document, runtime, custodian, session, and exact storage object path.

- [x] Resolve only the fixture's ciphertext path using the established path
  builder. Add the API config/DTO helper so each regression crosses the facade:

```elixir
{:ok, object_path} = Singularity.Storage.Local.PathGuard.object_path(
  storage_root, source.vault_id, material.domain_id,
  Base.encode16(material.lookup_digest, case: :lower))
config = %{download_document_original: &Read.download_original(runtime, &1, &2)}
session_dto = struct(Singularity.Runtime.DTO.Session, Map.from_struct(session))
result = Singularity.Runtime.Api.download_document_original(
  config, session_dto, uuid(document.resource_id))
```

- [x] Add three `@tag :tmp_dir` cases under the existing integration module:
  valid empty object, missing ciphertext, corrupt ciphertext. Use
  `File.rm!(fixture.object_path)` only for the allocated fixture object. Corrupt
  the last ciphertext byte without changing length:

```elixir
ciphertext = File.read!(fixture.object_path)
prefix_size = byte_size(ciphertext) - 1
<<prefix::binary-size(prefix_size), last>> = ciphertext
File.write!(fixture.object_path, <<prefix::binary, Bitwise.bxor(last, 1)>>)
```

  Valid case expects `{:ok, %{byte_size: 0, chunk_count: 0, read_chunk: read}}`
  and invalid errors for `[-1, 0, 1, :all, nil]`. Missing expects
  `{:error, :not_found}` and corrupt expects `{:error, :integrity_failure}`
  through Api's normalized public error. Assert no successful reader is returned.
  LocalFilesystemAdapter's missing-file `:not_found` passes unchanged through
  AuthenticatedReader.stat_matches/3; the expected missing code is exact.

- [x] Parent runs the isolated PostgreSQL integration command:

```sh
devenv shell -- mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/document_api_test.exs --seed 1208
```

  Expected RED: missing and corrupt cases receive a successful zero-chunk reader.
  The valid control and existing nonempty cases must still pass. Record the exact
  command, assertion failures, database/root identities and teardown evidence.
  Setup, migration, or undefined-function failures do not establish this RED.
  Stop for parent review of RED before production edits.

## Task 2: Add request-empty lease and composition contracts

**Modify:** both owned runtime test files, after TEST GO.

- [x] Append `Singularity.Runtime.DocumentEmptyOriginalLeaseTest`, `async: true`.
  Define its own controllable `Clock`, `Authorization`, and `Reader` modules.
  Clock reads an Agent DateTime; authorization sends `:original_revalidated` and
  reads an Agent containing `:ok` or `{:error, Error.t()}`. Reader sends
  `{:original_reader, self(), range}`, optionally waits for `:release`, then
  returns the configured result. Use `read_chunk/3` to report `{:chunk, index}`
  and `read_range/3` to report the range. Start DownloadLease with these defaults:

```elixir
%{
  authorization: Authorization, clock: Clock, key_reader: Reader,
  custodian: context.custodian, key_material: :binary.copy(<<1>>, 32),
  binding: %{access: :request, resource_version_id: "version", session_id: "session"},
  mode: nil,
  context: %{owner: self(), clock: context.clock, authority: context.authority,
    block?: false, result: {:ok, ""}, object_binding: %{plaintext_byte_size: 0}}
}
```

  Helper options override mode, binding, trusted object binding, result, and
  blocking. A worker-mode control supplies `consumer_pid: self()`. A separate
  test custodian process is stopped in `on_exit`; leases use `start_supervised!`.
  Invoke the new function with `apply(DownloadLease,
  :authenticate_empty_document_original, [lease])` until it exists.

- [x] Add the success contract: generic `read(:all)` and `read(0..0)` stay invalid;
  empty authentication reads exactly `:all`, revalidates twice, returns `:ok`,
  leaves the process alive but revoked with no reader-context key, rejects replay
  with `:waiting_for_unlock`, and permits the existing final `revoke/1` call.

```elixir
assert :ok = empty_original(lease)
assert_received {:original_reader, _reader, :all}
assert_receive :original_revalidated
assert_receive :original_revalidated
assert %{revoked?: true, pending: nil, reader_context: reader_context} = :sys.get_state(lease)
refute Map.has_key?(reader_context, :key_material)
assert {:error, :waiting_for_unlock} = empty_original(lease)
assert :ok = DownloadLease.revoke(lease)
```

- [x] Add table-driven guard cases: worker mode, nonnil unknown mode, Asset
  binding, worker-access binding in nil mode, missing resource version, absent
  trusted size, nonzero trusted size, and size only in caller binding all return
  `:invalid` with no storage start. Consume chunk zero on a zero-size test-double
  lease, then assert empty authentication is `:invalid`. Preserve the existing
  worker API's request-mode rejection and worker-consumer tests unchanged.
  Include `0.0`, `nil`, and `"0"` as invalid trusted sizes.

- [x] Add pending conflict using `:gen_server.send_request(lease,
  :authenticate_empty_document_original)`, wait for reader-start, assert a second
  empty call and a chunk call conflict, then release the reader. Add nonempty,
  nonbinary, malformed result, sanitized `%Error{}`, and waiting-for-unlock
  result cases. Assert every completed eligible request consumes its key.

- [x] Add deterministic fences. Before reading, change authority or advance the
  clock 61 seconds and assert no reader start. During blocked storage, change
  authority or advance the clock, release, and assert no success. In a separate
  blocked case, explicitly revoke and assert waiting-for-unlock plus worker DOWN.
  Use the existing request lifecycle only; do not assert abrupt lease-kill or
  consumer-death cleanup. Error canary message/details must be absent from the
  returned Error and captured logs. `:sys.get_status/1` must not expose the DEK.
  Exercise a reader exception containing canaries: expect a sanitized retryable
  `:storage_unavailable`, empty error details, consumed key, and clean captured logs.

- [x] Add zero-byte Read composition contracts with a configurable binding,
  authentication outcome and lease messages. The fake empty operation reports
  `{:document_empty_authenticate, lease}` and returns the configured `:ok` or
  sanitized error. Assert ordering: lease 1, empty authentication, revoke 1,
  lease 2, revoke 2. No chunk calls occur. Authentication errors and a nonempty
  immutable digest produce no lease 2. Preserve nonempty test bodies.

- [x] Parent runs focused unit tests and records expected new-operation RED:

```sh
devenv shell -- mix test apps/singularity_runtime/test/singularity/runtime/download_lease_test.exs apps/singularity_runtime/test/singularity/runtime/document_api_test.exs --seed 1208
```

## Task 3: Implement the bounded request operation

**Modify:** `apps/singularity_runtime/lib/singularity/runtime/download_lease.ex`.

- [x] Add the public function with the same call/exit normalization pattern as
  the worker API, under the distinct name `authenticate_empty_document_original`.
  Add a request-mode pending clause, an eligible trusted-zero/index-zero clause,
  and an invalid fallback. The accepted state pattern is:

```elixir
%{mode: nil, binding: %{access: :request, resource_version_id: _},
  next_index: 0, reader_context: %{object_binding: %{plaintext_byte_size: 0}}} = state
```

  Active state calls `start_read(state, from, :empty_document_original)`;
  inactive state replies waiting-for-unlock with `revoke_state(state)` and retains
  the process. Do not edit the worker-only clauses or generic read guards.

- [x] Dispatch the distinct marker to the existing authenticated range reader:

```elixir
defp read_operation(%{range: :empty_document_original} = operation),
  do: operation.key_reader.read_range(operation.reader_context, operation.binding, :all)
```

- [x] Add a completion clause before generic completion. Finish/demonitor the
  request reader and clear pending. Match `{lease_status(state), result}`:
  active exact empty -> authorized activity and `:ok`; active waiting -> waiting;
  active Error -> `public_error/1`; active other -> integrity failure; inactive ->
  waiting. Compute `state = revoke_state(state)` before replying, then return
  `{:noreply, state}`. Do not change generic revoke, worker finish/termination,
  reader spawning, KeyCustodian, CustodyReader, or storage.

## Task 4: Compose zero-byte preflight and release delivery key

**Modify:** `apps/singularity_runtime/lib/singularity/runtime/documents/read.ex`.

- [x] Replace only the count-zero reduce clause with the new call, keeping the
  hash accumulator and final digest comparison:

```elixir
_index, {:ok, hash, size} when count == 0 ->
  case call(reader, :authenticate_empty_document_original, [lease]) do
    :ok -> {:halt, {:ok, hash, size}}
    {:error, reason} -> {:halt, {:error, reason}}
    _ -> {:halt, {:error, Error.new(:integrity_failure)}}
  end
```

- [x] Immediately after computing the successful delivery's chunk count, revoke
  zero-count delivery custody before returning the existing reader DTO:

```elixir
if count == 0 do
  reader = Map.get(runtime, :authenticated_reader, DownloadLease)
  :ok = call(reader, :revoke, [delivery])
end
```

  All chunk indices remain invalid through the existing `read_delivery/4` guard.
  No alternative reader format or global error/revoke behavior is introduced.

- [x] Parent reruns the focused unit and actual PostgreSQL regression commands.
  Expected GREEN: missing and corrupt zero-byte originals no longer return a
  reader; valid empty originals do, with both lease keys revoked; existing tests
  retain their outcomes.

## Task 5: Add integration controls, review, and stop

**Modify:** additive tests in `document_api_test.exs` only.

- [x] Use the same zero-byte fixture and API facade for the following controls:
  delete the source Asset and still succeed; tombstone the Document resource and
  receive `:not_found`; call with a session from another prepared source and
  receive `:not_found`; revoke the fixture's session through existing
  `KeyCustodian.begin_revoke/2` and `finish_revoke/2`, then receive
  `{:error, :vault_locked}`. Add a digest-mismatch fixture by supplying the
  wrong 32-byte source digest before inserting its immutable Document; expect
  `:integrity_failure`. Do not mutate an inserted source tuple.

- [x] Parent runs the changed files plus the established adjacent guard scope,
  one command at a time. Preserve the original Task 14 integration scope and add
  Document custody because the shared lease module changes:

```sh
devenv shell -- mix test apps/singularity_runtime/test/singularity/runtime/document_api_test.exs apps/singularity_runtime/test/singularity/runtime/download_lease_test.exs apps/singularity_runtime/test/singularity/runtime/document_custody_test.exs apps/singularity_runtime/test/singularity/runtime/asset_download_test.exs apps/singularity_runtime/test/singularity/runtime/note_reads_test.exs --seed 1208
devenv shell -- mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/document_api_test.exs apps/singularity_storage/test/singularity/storage/postgres/document_repository_test.exs apps/singularity_runtime/test/singularity/runtime/note_reads_test.exs apps/singularity_runtime/test/singularity/runtime/asset_download_test.exs apps/singularity_runtime/test/singularity/runtime/document_custody_test.exs --seed 1208
devenv shell -- mix format --check-formatted apps/singularity_runtime/lib/singularity/runtime/documents/read.ex apps/singularity_runtime/lib/singularity/runtime/download_lease.ex apps/singularity_runtime/test/singularity/runtime/document_api_test.exs apps/singularity_runtime/test/singularity/runtime/download_lease_test.exs
devenv shell -- mix compile --warnings-as-errors
devenv shell -- mix xref graph --format cycles --fail-above 0
git diff --check
sha256sum docs/superpowers/plans/2026-10-09-singularity-v0.2-document-extraction-runtime-outcomes-integration.md
```

  The untracked plan's required hash is
  `350a655703264603c4af8cea7fbbdba96126b22e2ee52f4e23bef6c561234281`.
  Verify file names against the checkout before execution. Stop on any required
  failure and report it; do not expand scope. No E2E or broad README gate.

- [x] Parent reviews the exact diff for request-only guard correctness, untouched
  worker behavior, immutable fixture construction, privacy, zero-byte custody
  consumption, nonempty regression preservation, and no Vault feature work.
  Record exact checks/counts, RED/GREEN evidence, database/root teardown, changed
  files, no migrations, no worker Git writes, and limits. This concludes the
  bounded repair only; Phase 2 remains pending. The original runtime-outcomes
  plan remains untracked and unchanged.

## Local acceptance evidence

All bounded steps above are complete on the final reviewed production/test
hashes in `docs/verification/2026-10-09-empty-original-authentication.md`.
Final scoped checks executed 63 unit and 41 integration tests, all passing.
Warnings-as-errors compilation, changed-file formatting, and zero-cycle xref
passed. Independent Astra SPEC and QUALITY reviews are clear. No E2E or
complete Phase 2 acceptance is inferred from this scoped result.
