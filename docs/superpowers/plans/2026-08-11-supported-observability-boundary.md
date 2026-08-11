# Supported Observability Boundary Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enforce and document Singularity's supported, application-owned observability boundary so Steps 13 and 15 and final Task 19 can finish without claiming that raw dependency telemetry is secret-free.

**Architecture:** Keep `Singularity.Runtime.Observability.Telemetry` and the bounded `Singularity.Storage.SafeSQL` RLS emitter as the only direct `[:singularity, ...]` emission boundaries. Add a static ExUnit architecture contract that inventories production subscriptions, dependency-event literals, direct emitters, and dependency sources; strengthen canaries over supported telemetry and final JSON logs; and state that raw framework telemetry is unsupported. Do not fork, vendor, patch, or replace Thousand Island, Bandit, Plug, Phoenix, Phoenix LiveView, or `:telemetry`.

**Tech Stack:** Elixir 1.19, OTP Logger, `:telemetry`, Telemetry.Metrics, LoggerJSON, ExUnit, Phoenix 1.8, Git, devenv

---

### Task 1: Close the supported telemetry and final-log canary gaps

**Files:**

- Modify: `apps/singularity_runtime/test/singularity/runtime/observability_redaction_test.exs:121-175`
- Modify: `apps/singularity_runtime/test/singularity/runtime/telemetry_test.exs:171-199`
- Modify: `apps/singularity_runtime/test/singularity/runtime/secret_canary_test.exs:340-363,617-663`

- [ ] **Step 1: Reproduce the configured-level logger-test failure**

Run:

```bash
devenv shell -- mix test \
  apps/singularity_runtime/test/singularity/runtime/observability_redaction_test.exs
```

Expected: FAIL at `assert_receive {:raw_logger_event, event}` because
`config/test.exs` sets Logger to `:warning` while the test emits `:notice`.

- [ ] **Step 2: Make the logger-handler test exercise an enabled level**

In `observability_redaction_test.exs`, change only the level passed to
`LoggerMetadata.log/3`:

```elixir
assert :ok =
         LoggerMetadata.log(
           :warning,
           %{
             operation: :asset_download,
             result: :completed,
             payload: %{
               domain_dedup_key: @secret,
               arbitrary: @secret
             }
           },
           %{
             arbitrary: @secret,
             correlation_id: @correlation_id,
             password: @secret
           }
         )
```

- [ ] **Step 3: Add a supported-event exception canary**

Immediately after the existing `Telemetry.span/3` success test in
`telemetry_test.exs`, add:

```elixir
test "span exception telemetry omits the exception and scans the complete payload" do
  exception_event = [:singularity, :contract, :exception]
  attach(exception_event)

  assert_raise RuntimeError, @secret, fn ->
    Telemetry.span([:contract], %{token: @secret}, fn ->
      raise @secret
    end)
  end

  assert_receive {:telemetry, ^exception_event, measurements, metadata} = payload
  assert Enum.all?(measurements, fn {_key, value} -> is_number(value) end)
  assert metadata.kind == :error
  assert metadata.result == :exception
  refute inspect(payload, limit: :infinity, printable_limit: :infinity) =~ @secret
end
```

- [ ] **Step 4: Scan full supported telemetry tuples and final JSON output**

In the existing audit/telemetry canary test, retain the full tuple and scan it:

```elixir
assert_receive {:telemetry_surface, ^telemetry_event, measurements,
                telemetry_metadata} = telemetry

assert Map.values(audit_event.metadata) ==
         List.duplicate("[REDACTED]", map_size(@canaries))

assert Map.values(telemetry_metadata) ==
         List.duplicate("[REDACTED]", map_size(@canaries))

assert match?({:telemetry_surface, [:singularity | _], _, _}, telemetry)
assert Enum.all?(measurements, fn {_key, value} -> is_number(value) end)

for canary <- Map.values(@canaries) do
  assert Canary.leaks([audit_event, telemetry], canary) == []
end
```

After the detector test, add a test using the application's real configured
LoggerJSON formatter:

```elixir
test "the configured final structured log output removes every server canary" do
  assert [formatter: {LoggerJSON.Formatters.Basic, formatter_options}] =
           Application.fetch_env!(:logger, :default_handler)

  assert {LoggerJSON.Formatters.Basic, formatter} =
           LoggerJSON.Formatters.Basic.new(formatter_options)

  encoded =
    %{
      level: :warning,
      meta: %{time: System.system_time(:microsecond)},
      msg: {:report, %{operation: :secret_canary, nested: @canaries}}
    }
    |> LoggerJSON.Formatters.Basic.format(formatter)
    |> IO.iodata_to_binary()
    |> JSON.decode!()

  for canary <- Map.values(@canaries) do
    assert Canary.leaks(encoded, canary) == []
  end
end
```

- [ ] **Step 5: Run the focused runtime gate**

Run:

```bash
devenv shell -- mix format \
  apps/singularity_runtime/test/singularity/runtime/observability_redaction_test.exs \
  apps/singularity_runtime/test/singularity/runtime/telemetry_test.exs \
  apps/singularity_runtime/test/singularity/runtime/secret_canary_test.exs
devenv shell -- mix test \
  apps/singularity_runtime/test/singularity/runtime/observability_redaction_test.exs \
  apps/singularity_runtime/test/singularity/runtime/telemetry_test.exs \
  apps/singularity_runtime/test/singularity/runtime/secret_canary_test.exs
git diff --check
```

Expected: all three runtime test files pass and the diff has no whitespace
errors.

- [ ] **Step 6: Commit the supported-surface canaries**

```bash
git add \
  apps/singularity_runtime/test/singularity/runtime/observability_redaction_test.exs \
  apps/singularity_runtime/test/singularity/runtime/telemetry_test.exs \
  apps/singularity_runtime/test/singularity/runtime/secret_canary_test.exs
git diff --cached --check
git commit -m "test(observability): tighten supported secret canaries"
```

### Task 2: Add the observability architecture contract

**Files:**

- Create: `apps/singularity_web/test/singularity/architecture/observability_contract_test.exs`
- Test: `apps/singularity_web/test/singularity/architecture/observability_contract_test.exs`

- [ ] **Step 1: Write the contract assertions before their scanner helpers**

Create `observability_contract_test.exs` with the module attributes and tests
below, but do not add the private helper functions from Step 3 yet:

```elixir
defmodule Singularity.Architecture.ObservabilityContractTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../../../..", __DIR__)
  @runtime_telemetry "apps/singularity_runtime/lib/singularity/runtime/observability/telemetry.ex"
  @safe_sql "apps/singularity_storage/lib/singularity/storage/safe_sql.ex"
  @endpoint "apps/singularity_web/lib/singularity/web/endpoint.ex"
  @protected_dependencies ~w[
    thousand_island bandit plug phoenix phoenix_live_view telemetry
  ]a
  @unsupported_event_roots ~w[
    thousand_island bandit plug phoenix phoenix_live_view oban ecto
  ]a

  test "production telemetry subscriptions are limited to the bounded Oban adapter" do
    assert [{@runtime_telemetry, :attach_many}] ==
             telemetry_calls([:attach, :attach_many])
             |> Enum.map(fn {path, function, _arguments} -> {path, function} end)

    assert [
             [:oban, :job, :exception],
             [:oban, :job, :stop]
           ] == module_attribute(@runtime_telemetry, :oban_events)

    assert [Singularity.Runtime.Observability.Telemetry] ==
             Singularity.Runtime.Application.application_children(%{
               start_infrastructure: false
             })
  end

  test "unsupported dependency event literals are confined to instrumentation and the Oban adapter" do
    assert [
             {@runtime_telemetry, [:oban, :job, :exception]},
             {@runtime_telemetry, [:oban, :job, :stop]},
             {@endpoint, [:phoenix, :endpoint]}
           ] == dependency_event_literals()
  end

  test "direct Singularity event emission is allowlisted" do
    assert [
             {@runtime_telemetry, "[:singularity | event]"},
             {@safe_sql, "[:singularity, :authorization, :rls_denial]"}
           ] ==
             telemetry_calls([:execute])
             |> Enum.map(fn {path, :execute, [event | _arguments]} ->
               {path, Macro.to_string(event)}
             end)
             |> Enum.sort()
  end

  test "protected telemetry dependencies resolve only from Hex" do
    assert [] == non_hex_dependency_declarations()

    {lock, _binding} = Code.eval_file(Path.join(@repo_root, "mix.lock"))

    for dependency <- @protected_dependencies do
      assert {:hex, ^dependency, _version, _checksum, _managers, _dependencies,
              "hexpm", _outer_checksum} =
               Map.fetch!(lock, Atom.to_string(dependency))
    end
  end

  test "the scanners reject raw handlers and source overrides" do
    source = """
    :telemetry.attach(:raw, [:phoenix, :endpoint, :stop], &handle/4, nil)
    :telemetry.attach_many(:many, events, &handle/4, nil)
    deps = [
      {:phoenix, github: "fork/phoenix"},
      {:plug, git: "https://example.test/plug.git"},
      {:bandit, path: "vendor/bandit"}
    ]
    """

    assert [:attach, :attach_many] ==
             source
             |> calls_in_source([:attach, :attach_many])
             |> Enum.map(fn {function, _arguments} -> function end)

    assert [
             {:bandit, :path},
             {:phoenix, :github},
             {:plug, :git}
           ] == non_hex_declarations_in_source(source)
  end
end
```

- [ ] **Step 2: Run the new test to verify the scanner is missing**

Run:

```bash
devenv shell -- mix test \
  apps/singularity_web/test/singularity/architecture/observability_contract_test.exs
```

Expected: compilation fails because `telemetry_calls/1`,
`module_attribute/2`, `dependency_event_literals/0`,
`non_hex_dependency_declarations/0`, `calls_in_source/2`, and
`non_hex_declarations_in_source/1` are undefined.

- [ ] **Step 3: Implement the minimal AST scanners**

Before the final `end` of the test module, add:

```elixir
defp production_sources do
  ["apps/*/lib/**/*.{ex,exs}", "config/*.{ex,exs}"]
  |> Enum.flat_map(fn pattern ->
    @repo_root |> Path.join(pattern) |> Path.wildcard()
  end)
  |> Enum.sort()
end

defp relative(path), do: Path.relative_to(path, @repo_root)

defp telemetry_calls(functions) do
  production_sources()
  |> Enum.flat_map(fn path ->
    path
    |> File.read!()
    |> calls_in_source(functions)
    |> Enum.map(fn {function, arguments} ->
      {relative(path), function, arguments}
    end)
  end)
  |> Enum.sort()
end

defp calls_in_source(source, functions) do
  ast = Code.string_to_quoted!(source)

  {_ast, calls} =
    Macro.prewalk(ast, [], fn
      {{:., _dot_meta, [:telemetry, function]}, _call_meta, arguments} = node,
      calls
      when function in functions ->
        {node, [{function, arguments} | calls]}

      node, calls ->
        {node, calls}
    end)

  Enum.reverse(calls)
end

defp module_attribute(path, name) do
  ast = @repo_root |> Path.join(path) |> File.read!() |> Code.string_to_quoted!()

  {_ast, values} =
    Macro.prewalk(ast, [], fn
      {:@, _meta, [{^name, _attribute_meta, [value]}]} = node, values ->
        {node, [value | values]}

      node, values ->
        {node, values}
    end)

  assert [value] = values
  assert Macro.quoted_literal?(value)
  {evaluated, []} = Code.eval_quoted(value)
  evaluated
end

defp dependency_event_literals do
  production_sources()
  |> Enum.flat_map(fn path ->
    ast = path |> File.read!() |> Code.string_to_quoted!()

    {_ast, events} =
      Macro.prewalk(ast, [], fn
        event, events when is_list(event) ->
          case event do
            [root | _rest] when root in @unsupported_event_roots ->
              {event, [{relative(path), event} | events]}

            _other ->
              {event, events}
          end

        node, events ->
          {node, events}
      end)

    events
  end)
  |> Enum.uniq()
  |> Enum.sort()
end

defp non_hex_dependency_declarations do
  [Path.join(@repo_root, "mix.exs") | Path.wildcard(Path.join(@repo_root, "apps/*/mix.exs"))]
  |> Enum.flat_map(fn path ->
    path
    |> File.read!()
    |> non_hex_declarations_in_source()
    |> Enum.map(fn {dependency, source} -> {relative(path), dependency, source} end)
  end)
  |> Enum.sort()
end

defp non_hex_declarations_in_source(source) do
  ast = Code.string_to_quoted!(source)

  {_ast, declarations} =
    Macro.prewalk(ast, [], fn
      {dependency, options} = node, declarations
      when dependency in @protected_dependencies and is_list(options) ->
        {node, dependency_sources(dependency, options, declarations)}

      {dependency, _requirement, options} = node, declarations
      when dependency in @protected_dependencies and is_list(options) ->
        {node, dependency_sources(dependency, options, declarations)}

      node, declarations ->
        {node, declarations}
    end)

  declarations |> Enum.uniq() |> Enum.sort()
end

defp dependency_sources(dependency, options, declarations) do
  for source <- [:github, :git, :path],
      Keyword.has_key?(options, source),
      reduce: declarations do
    declarations -> [{dependency, source} | declarations]
  end
end
```

- [ ] **Step 4: Run the focused architecture gate**

Run:

```bash
devenv shell -- mix format \
  apps/singularity_web/test/singularity/architecture/observability_contract_test.exs
devenv shell -- mix test \
  apps/singularity_web/test/singularity/architecture/dependency_graph_test.exs \
  apps/singularity_web/test/singularity/architecture/observability_contract_test.exs
git diff --check
```

Expected: the existing dependency graph and all five new observability-contract
tests pass.

- [ ] **Step 5: Commit the architecture contract**

```bash
git add apps/singularity_web/test/singularity/architecture/observability_contract_test.exs
git diff --cached --check
git commit -m "test(architecture): enforce observability boundary"
```

### Task 3: Align the approved design, guide, and executable parent plan

**Files:**

- Modify: `docs/superpowers/specs/2026-07-18-foundation-asset-vertical-design.md:1227-1234,1368-1381`
- Modify: `docs/superpowers/specs/2026-08-08-task-18-browser-acceptance-amendment.md:59-107`
- Modify: `docs/guide.md:1869-1917`
- Modify: `docs/superpowers/plans/2026-07-18-foundation-asset-vertical.md:3889-4009,5506-5543,5574-5629,5631-5746`

- [ ] **Step 1: State the supported boundary in the foundation design**

After the operational telemetry inventory in the foundation design, add:

```markdown
The supported telemetry contract consists only of events beginning with
`[:singularity]` and emitted through an approved Singularity-owned boundary.
Measurements are numeric and metadata is bounded and redacted before emission.
The runtime telemetry module is the public emission API; the storage RLS-denial
event is the one approved lower-layer direct emitter.

Raw Thousand Island, Bandit, Plug, Phoenix, Phoenix LiveView, Oban, Ecto, and
other dependency telemetry is not a supported Singularity integration surface
and carries no secret-absence guarantee. Supported deployments must not attach
reporters, exporters, or persistence handlers to those raw events. The bounded
runtime Oban adapter may consume only its allow-listed job events to derive safe
`[:singularity, ...]` events.
```

Replace the security-test telemetry statement with:

```markdown
Password/key/passphrase/server-secret canaries must be absent from supported
`[:singularity, ...]` event measurements and metadata, final structured log
output, audit metadata, persistence-adapter arguments, rendered HTML,
`data-props`, LiveView application payloads, controller JSON, and browser console
output. Focused Phoenix stop/error scrubber tests remain defense in depth and do
not make raw dependency telemetry a supported or secret-free surface.
```

Keep the existing upload-token and CSRF browser allow-list paragraphs.

- [ ] **Step 2: Qualify the Task 18 browser amendment**

In section 3, replace each unqualified `telemetry` prohibition with
`supported [:singularity, ...] telemetry`, preserving all other passphrase and
CSRF locations. After the CSRF paragraph, add:

```markdown
These canary rules cover Singularity application responses and supported
observability surfaces. Raw Thousand Island, Bandit, Plug, Phoenix, and Phoenix
LiveView telemetry is unsupported: the browser gate does not attach to it or
claim it is secret-free, and supported deployments must not persist or export
it. Existing selected Phoenix stop/error scrubbers remain defense in depth.
```

- [ ] **Step 3: Make the operational guide safe by construction**

Immediately below `# 19. Observability`, add:

```markdown
Singularity supports only application-owned telemetry events beginning with
`[:singularity]`, final structured output from the configured JSON
formatter/redactor, and immutable audit records. Reporters and exporters must
consume the Singularity metric definitions and events only. Do not subscribe a
supported deployment to raw Thousand Island, Bandit, Plug, Phoenix, Phoenix
LiveView, Oban, Ecto, or other dependency events; those payloads are outside the
secret-absence guarantee and must be treated as sensitive.

The runtime telemetry boundary accepts numeric measurements and bounded,
redacted metadata. Its explicitly allow-listed Oban adapter derives safe job
events without promoting the raw Oban source event into the supported contract.
```

Change `Operational telemetry should include:` to
`Supported Singularity telemetry should include:`. Keep the existing metric
inventory and logging/audit separation.

- [ ] **Step 4: Amend Steps 13 and 15 in the parent plan**

Make these exact contract changes:

1. Step 13 says canaries are absent from supported `[:singularity, ...]`
   measurements and metadata and final JSON logs; raw dependency telemetry is
   unsupported and no longer a blocker.
2. Step 13's ExUnit command includes runtime `telemetry_test.exs`, runtime
   `observability_redaction_test.exs`, and the new web architecture
   `observability_contract_test.exs`.
3. Task 15 identifies Runtime Telemetry and Storage SafeSQL as the only approved
   direct emitters, calls raw Oban source events adapter-only, and forbids
   production reporters/exporters/persistence handlers on dependency events.
4. Task 15's gate includes the new architecture contract.
5. Step 15's focused test list includes both runtime observability tests and the
   new architecture contract, and its expected result states that raw framework
   telemetry is outside the gate.

- [ ] **Step 5: Amend Task 19 and the completion checklist**

Add these Task 19 scope checks:

```bash
devenv shell -- mix test \
  apps/singularity_web/test/singularity/architecture/dependency_graph_test.exs \
  apps/singularity_web/test/singularity/architecture/observability_contract_test.exs
```

Change the branch-history expectation from `codex/foundation-asset-vertical` to
`codex/vault-workbench-app-clip`. Replace the unqualified checklist item with:

```markdown
- [ ] Audit, final structured logs, supported `[:singularity, ...]` telemetry,
      HTML, LiveView application payloads, JSON, and browser console satisfy the
      secret-canary rules; production code subscribes to no unsupported raw
      dependency telemetry.
```

Keep the final no-later-milestone dependency item unchanged.

- [ ] **Step 6: Verify documentation consistency**

Run:

```bash
rg -n "supported.*telemetry|raw.*telemetry|\[:singularity" \
  docs/superpowers/specs/2026-07-18-foundation-asset-vertical-design.md \
  docs/superpowers/specs/2026-08-08-task-18-browser-acceptance-amendment.md \
  docs/guide.md \
  docs/superpowers/plans/2026-07-18-foundation-asset-vertical.md
! rg -n "fork|github:|git:|path:" \
  apps/singularity_web/mix.exs \
  apps/singularity_runtime/mix.exs \
  apps/singularity_storage/mix.exs
git diff --check -- \
  docs/superpowers/specs/2026-07-18-foundation-asset-vertical-design.md \
  docs/superpowers/specs/2026-08-08-task-18-browser-acceptance-amendment.md \
  docs/guide.md \
  docs/superpowers/plans/2026-07-18-foundation-asset-vertical.md
```

Expected: all four documents state the same supported boundary, no protected
dependency source override appears, and the documentation diff has no whitespace
errors. `README.md` is unchanged because it makes no telemetry secrecy claim.

- [ ] **Step 7: Stage only the observability documentation hunks and commit**

The parent plan already has two unstaged user edits near Task 19. Use
interactive staging for that file and reject those pre-existing hunks:

```bash
git add \
  docs/superpowers/specs/2026-07-18-foundation-asset-vertical-design.md \
  docs/superpowers/specs/2026-08-08-task-18-browser-acceptance-amendment.md \
  docs/guide.md
git add -p docs/superpowers/plans/2026-07-18-foundation-asset-vertical.md
git diff --cached --check
git diff --cached -- docs/superpowers/plans/2026-07-18-foundation-asset-vertical.md
git commit -m "docs(observability): align supported telemetry contract"
```

Expected: the cached parent-plan diff contains only observability-boundary
changes. The existing process-teardown and npm link-strategy edits remain
unstaged after the commit.

### Task 4: Run Step 15 and final Task 19 verification

**Files:**

- Verify only: no planned changes

- [ ] **Step 1: Run the Task 15 scoped observability and browser tests**

Run:

```bash
devenv shell -- mix test \
  apps/singularity_runtime/test/singularity/runtime/audit_acceptance_test.exs \
  apps/singularity_runtime/test/singularity/runtime/telemetry_test.exs \
  apps/singularity_runtime/test/singularity/runtime/observability_redaction_test.exs \
  apps/singularity_runtime/test/singularity/runtime/secret_canary_test.exs \
  apps/singularity_web/test/singularity/web/authentication_test.exs \
  apps/singularity_web/test/singularity/web/backup_controller_test.exs \
  apps/singularity_web/test/singularity/web/secret_canary_test.exs \
  apps/singularity_web/test/singularity/architecture/dependency_graph_test.exs \
  apps/singularity_web/test/singularity/architecture/observability_contract_test.exs
```

Expected: every supported observability, selected Phoenix defense-in-depth,
web canary, and architecture contract test passes.

- [ ] **Step 2: Run the service-backed Step 15 gates in one cleanup shell**

Run:

```bash
(
set -euo pipefail
trap 'devenv processes down' EXIT
devenv up -d
devenv processes wait --timeout 120
devenv shell -- bash apps/singularity_storage/priv/repo/bootstrap_roles.sh
devenv shell -- mix deps.get
devenv shell -- mix deps.unlock --check-unused
devenv shell -- mix format --check-formatted
devenv shell -- mix compile --warnings-as-errors
devenv shell -- mix singularity.test.integration
devenv shell -- mix singularity.test.restore
devenv shell -- env NPM_EX_LINK_STRATEGY=copy mix npm.install --frozen
devenv shell -- mix npm.verify
devenv shell -- mix duskmoon_bundler.js.check
devenv shell -- mix npm.run test:js
devenv shell -- mix duskmoon_bundler.build singularity_web --tailwind
devenv shell -- mix npm.run test:e2e
devenv shell -- mix xref graph --format cycles --fail-above 0
)
git diff --check
```

Expected: integration, independent restore, JavaScript, bundle, Chromium,
compile, formatting, xref, and whitespace gates pass. If an out-of-scope test
fails, report it and stop without changing unrelated code.

- [ ] **Step 3: Run the final full Elixir suite**

Run only after Step 2 is green:

```bash
devenv shell -- mix test
```

Expected: the full ExUnit suite passes. Do not repair unrelated failures.

- [ ] **Step 4: Audit scope, dependency sources, history, and worktree state**

Run:

```bash
set -euo pipefail

assert_no_matches() {
  local output status
  set +e
  output="$("$@" 2>&1)"
  status=$?
  set -e

  case "$status" in
    1) return 0 ;;
    0) printf '%s\n' "$output" >&2; return 1 ;;
    *) printf '%s\n' "$output" >&2; return "$status" ;;
  esac
}

test ! -d apps/singularity_store
assert_no_matches rg -n \
  '(?i:couchdb|backplane|embeddedess)|S3[A-Z][[:alnum:]]*|(^|[^[:alnum:]])[sS]3[[:alnum:]_]*' \
  apps config mix.exs package.json
assert_no_matches rg -n -i 'qdrant' \
  config mix.exs mix.lock apps/*/mix.exs package.json package-lock.json
assert_no_matches rg --files -g '*[Qq][Dd][Rr][Aa][Nn][Tt]*' apps

set +e
qdrant_references="$(rg --no-line-number --with-filename --no-heading \
  --color=never -i 'qdrant' apps 2>&1)"
qdrant_status=$?
set -e
if [ "$qdrant_status" -ge 2 ]; then
  printf '%s\n' "$qdrant_references" >&2
  exit "$qdrant_status"
fi

qdrant_references="$(printf '%s\n' "$qdrant_references" | LC_ALL=C sort)"
expected_qdrant_references="$(printf '%s\n' \
  'apps/singularity_retrieval/lib/singularity/retrieval.ex:  @moduledoc "Knowledge retrieval boundary; Qdrant integration begins in Milestone 8."' \
  'apps/singularity_storage/lib/singularity/storage/backup/integrity_audit.ex:  implementation. The Qdrant vector adapter remains a separate required')"
if [ "$qdrant_references" != "$expected_qdrant_references" ]; then
  printf '%s\n' "$qdrant_references" >&2
  exit 1
fi

test "$(rg -cF 'WORKAROUND(upstream): gsmlg-opt/ex_storage_service#5' \
  apps/singularity_runtime/lib/singularity/runtime/storage_adapter.ex)" = 1
devenv shell -- mix test \
  apps/singularity_web/test/singularity/architecture/dependency_graph_test.exs \
  apps/singularity_web/test/singularity/architecture/observability_contract_test.exs
git status --short --branch
git log --oneline --decorate main..HEAD
git diff --stat main...HEAD
git diff --check main...HEAD
```

Expected: the seven-app foundation has no CouchDB, Backplane, EmbeddedESS, or
S3 reference in application/configuration/dependency scope. Qdrant is absent
from configuration, dependency manifests/locks, and implementation filenames;
its complete `apps` reference set equals the two approved Milestone 8
documentation strings exactly. Architecture tests pass, branch history contains
only approved work, and the only remaining worktree changes are the two
pre-existing unstaged parent-plan edits. Do not merge, push, or open a pull
request without a separate user request.
