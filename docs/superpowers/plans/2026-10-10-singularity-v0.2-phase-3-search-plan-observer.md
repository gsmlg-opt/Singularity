# Phase 3 Nested Search-Plan Observer Prerequisite Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove that an isolated real-web-login connection can capture executed nested definer plans in memory and leave no observation configuration behind.

**Architecture:** A test-only helper temporarily installs fixed database-role startup defaults through the existing external administrator transport, starts one fixed named real Ecto.Repo with the validated web connection configuration, immediately removes those defaults, and parses the existing authorization definer's Postgrex notices privately. The helper passes that Repo module explicitly and returns closed proof counters, never raw results, plans, connection options, or credentials. Shared RequestRepo and its dynamic selection stay unchanged; no production query or privilege boundary changes in this prerequisite.

**Tech Stack:** PostgreSQL 17.10 bundled auto_explain, locked Postgrex/Ecto, SafeSQL, ScopedRepo, ExUnit, external administrator Unix-socket connection.

---

## Authority, baseline, and boundary

Read the [reviewed index-repair design](../specs/2026-10-10-singularity-v0.2-phase-3-search-index-repair-design.md), particularly its observation section. Design SHA-256 at review was `9ddbe4f8effd1ad20a216dcb3e3528d9115a39cdbbe48a37d623638c28f7486a`; it is committed at `eeccdd9`. Governance is `799e36308660f9b6b9fc8ade7d4261b264d995a7`. Use the existing `.trees/v0.2-phase-3-search-design` worktree and `codex/v0.2-phase-3-search-design` branch; verify the current source before execution.

The accepted subsequent correction has design SHA-256 `abf390ced68bd2d3a5604a139da8c58d1ef05d6aaec5b22abd5ecb067cfb9d06`. This revision follows that named-Repo design, not the superseded dynamic-observer proposal.

The coordinator owns all Mix, formatting, PostgreSQL lifecycle, Git, and evidence updates, serially. Workers preserve others' changes. Use existing locked dependencies at `/home/gao/Workspace/gsmlg-opt/Singularity/deps`, a worktree-local build, seed `215378`, and the existing private `.devenv/phase3-integration.sh` harness. No worker starts/stops a service or borrows another cluster.

This plan creates only:

- `apps/singularity_storage/test/support/knowledge_search_plan_observer.ex`: fixed target validation, administrator/default ownership, dedicated observer lifecycle, and private notice parser.
- `apps/singularity_storage/test/singularity/storage/postgres/knowledge_search_plan_observer_test.exs`: one pure boundary contract and five owning integration contracts.

No wrapper is needed. Use the established test-local `with_admin` raw-Postgrex pattern from `apps/singularity_storage/test/singularity/storage/search_extension_bootstrap_test.exs:661`, narrowed to the harness's exact Unix socket and port. Credentials remain in process memory; do not use shell arguments, service files, administrator Repos, application-environment changes, or a generic connection/settings API. The existing production FD bootstrap is not modified or invoked to run observation SQL.

Do not edit shared fixtures, RequestRepo, SafeSQL, runtime authorization/custody, migrations, bootstrap, privacy tests, or the frozen failing query-plan test. Bundled module presence was checked separately. Initial live run `8635` failed all five integration cases before proof: the web role cannot read the two hidden preload GUCs (`42501`, independently confirmed by parent probe `19744`). The Astra architecture correction below replaces those impossible reads with split verification without grants; at that checkpoint actual nested notice proof remained unqualified. A passing prerequisite is not a selective-index repair or phase acceptance. Candidate migration/Store implementation receives a separate concrete plan only after this prerequisite passes. E2E remains NOT RUN; no publication, deployment, production data, activation, or backfill.

The subsequent corrected attempt `96674` still had three integration failures (one pure case excluded); early-fault cleanup and independent observation-conflict cases passed. It exposed a distinct test-helper diagnostic defect: raw Postgrex/DBConnection `log: false` is not Ecto's disable-logging option and caused a logger-callback failure that printed a synthetic administrator LogEntry. No user content, authorization plan, or credentials were reported in that output, but this is still a failed privacy prerequisite, not GREEN. Use `log: nil` or omitted logging options on **raw Postgrex** only; existing Ecto SafeSQL `log: false` stays correct and unchanged. Subsequent repair and qualification are recorded below and in the dated evidence report.

Probe `87856` subsequently exposed missing/unregistered observation settings on the actual web query connection. Locked Ecto SQL resolves a Repo atom through the registry directly, while generated transaction methods honor dynamic selection. Consequently a dynamic RequestRepo binding did not keep ScopedRepo and SafeSQL on one observer pool. The fixed named real Repo below repairs this test-only composition; it does not modify SafeSQL, copy Store SQL, replace authorization, or claim proof passed.

## Fixed interface and ownership

Define `Singularity.Storage.KnowledgeSearchPlanObserver` with these test-only functions:

```elixir
# All database arguments must equal the currently allocated RequestRepo database.
with_observer(database, callback, fault \\ :none)
# callback has arity one and receives only KnowledgeSearchPlanObserver.Repo.
# It receives no credentials or raw plans.
# Returns {:ok, callback_result} or {:error, closed_atom}.

authorization_summary(observer_repo, scope)
# Returns {:ok, %{backend: integer, nested_statements: integer,
#   executed_nodes: integer, actual_rows: integer, actual_loops: integer,
#   buffer_nodes: integer, indexes: []}} or {:error, closed_atom}.

clean?(database)
# Checks owned-default absence AND a fresh ordinary web connection's disabled observer.

with_conflicting_default(database, callback)
# Fixed negative fixtures run independently: log_min_duration=-1, then log_wal=on.
# Invokes callback once per fixture; removes each owned setting before the next.

with_inherited_logging(database, callback)
# Fixed allocated-database-only logging defaults: notice/warning.
# Preserves the exact pre-existing catalog footprint; no arbitrary settings API.

startup_safe?(config)
# Pure boolean validator only. Cannot connect or select observer configuration.
# with_observer always applies it to actual RequestRepo.config().
```

The only fault selector is `:none | :after_install`; it is a deterministic cleanup probe, not an injected authorizer, connection, role, SQL, or settings map. `:after_install` raises a constant internal exception after the committed install and before starting the observer Repo. Callback exceptions are sanitized to `{:error, :observer_callback_failed}` after teardown; cleanup failure takes precedence as `{:error, :observer_cleanup_failed}`. Public errors use only `:observer_invalid_target`, `:observer_admin_failed`, `:observer_configuration_conflict`, `:observer_setup_failed`, `:observer_callback_failed`, `:observer_cleanup_failed`, and `:observer_evidence_missing`.

Use exactly these defaults, with fixed role `singularity_web` and no grants:

```elixir
@defaults [
  {"session_preload_libraries", "auto_explain"},
  {"auto_explain.log_min_duration", "0"},
  {"auto_explain.log_analyze", "on"},
  {"auto_explain.log_nested_statements", "on"},
  {"auto_explain.log_format", "json"},
  {"auto_explain.log_level", "notice"},
  {"auto_explain.log_parameter_max_length", "0"},
  {"auto_explain.log_timing", "off"},
  {"auto_explain.log_buffers", "on"},
  {"auto_explain.log_verbose", "off"},
  {"auto_explain.sample_rate", "1"},
  {"client_min_messages", "notice"},
  {"log_min_messages", "warning"}
]
```

The administrative install is one transaction; removal is a second transaction immediately after the observer connection is verified, before running the proof/callback. Transactionally reject conflicts before issuing any ALTER ROLE. Keep an explicit list of installed keys; reset only those keys, never RESET ALL. If removal fails, stop the observer and report cleanup failure; do not start another test until the coordinator recovers the owned state.

## Task 1: Closed target validation and intended RED

**Files:** Create the owning test, then the helper.

- [x] Write the pure test without requiring a missing module at compile time:

```elixir
defmodule Singularity.Storage.Postgres.KnowledgeSearchPlanObserverTest do
  use Singularity.Storage.DataCase, async: false
  alias Singularity.Storage.{Fixtures, KnowledgeSearchPlanObserver, RequestRepo}

  test "missing, malformed, non-test and mismatched targets fail before callback" do
    assert Code.ensure_loaded?(KnowledgeSearchPlanObserver)
    assert function_exported?(KnowledgeSearchPlanObserver, :with_observer, 2)
    for database <- [nil, "postgres", "singularity_test_bad", "singularity_test_000000000000000000000000"] do
      assert {:error, :observer_invalid_target} =
        apply(KnowledgeSearchPlanObserver, :with_observer,
          [database, fn _observer_repo -> flunk("invalid target reached callback") end])
    end
  end
end
```

- [x] Parent runs the exact owning file:

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix test apps/singularity_storage/test/singularity/storage/postgres/knowledge_search_plan_observer_test.exs --seed 215378
```

Expected RED: the explicit missing helper assertion, not a compile/database failure. This command never enters integration fixtures.

- [x] Implement closed target validation before opening any administrator connection. Require `Mix.env() == :test`, canonical `singularity_test_[0-9a-f]{24}`, exact equality to `RequestRepo.config()[:database]`, username `singularity_web`, and config socket/port equal to the harness's `PGHOST`/`PGPORT`. Require `PGHOST` to be an absolute Unix-socket directory and the configured storage root to equal `Path.join([System.tmp_dir!(), "singularity", "integration", suffix])` with that allocated suffix and existing directory. Missing environment/config fails closed. The all-zero fake target in the pure test must remain different from the actual random allocation.

The parent-owned private harness exports `SINGULARITY_TEST_OBSERVER_PGDATA` for this prerequisite, or may use its existing `PGDATA`. This is only an expected test-cluster identity, not a SQL/settings/connection override. Require an absolute already-normalized directory strictly beneath this checkout's `.devenv/`, with `PG_VERSION` equal to `17`; the administrator verifies the running server against it before changing defaults. Do not commit any allocated directory basename. The helper never starts or stops PostgreSQL.

```elixir
defp target(database) do
  config = RequestRepo.config()
  socket = System.get_env("PGHOST")
  port = System.get_env("PGPORT")
  root = Application.get_env(:singularity_storage, :storage_root)
  pgdata = System.get_env("SINGULARITY_TEST_OBSERVER_PGDATA") || System.get_env("PGDATA")
  checkout_devenv = Path.expand("../../../../.devenv", __DIR__)
  valid_pgdata = is_binary(pgdata) and Path.type(pgdata) == :absolute and
    Path.expand(pgdata) == pgdata and String.starts_with?(pgdata, checkout_devenv <> "/") and
    File.dir?(pgdata) and
    case File.read(Path.join(pgdata, "PG_VERSION")) do
      {:ok, version} -> String.trim(version) == "17"
      _ -> false
    end
  valid_name = is_binary(database) and Regex.match?(~r/\Asingularity_test_[0-9a-f]{24}\z/, database)
  suffix = if valid_name, do: String.replace_prefix(database, "singularity_test_", ""), else: ""
  expected_root = Path.join([System.tmp_dir!(), "singularity", "integration", suffix])

  if Mix.env() == :test and startup_safe?(config) and valid_name and database == config[:database] and
       config[:username] == "singularity_web" and is_binary(socket) and
       String.starts_with?(socket, "/") and config[:socket_dir] == socket and
       is_binary(port) and Integer.to_string(config[:port] || 0) == port and
       root == expected_root and File.dir?(root) and valid_pgdata do
    {:ok, %{database: database, socket: socket, port: config[:port], pgdata: pgdata}}
  else
    {:error, :observer_invalid_target}
  end
rescue
  _ -> {:error, :observer_invalid_target}
end
```

- [x] Parent reruns the pure command: one executed case passes. Keep integration cases tagged individually so default exclusions do not hide this boundary test.

- [x] Extend that same pure case with startup-override rejection. The parent observed extension RED `13430` (one failed case, five excluded); retain the existing invalid-target assertions. No application environment is changed:

```elixir
baseline = [url: nil, parameters: [], options: nil, configure: nil, after_connect: nil]
assert KnowledgeSearchPlanObserver.startup_safe?(baseline)
for override <- [
  [options: "-c session_preload_libraries=auto_explain"],
  [parameters: [{"auto_explain.log_min_duration", "0"}]],
  [session_preload_libraries: "auto_explain"],
  [local_preload_libraries: "auto_explain"],
  [shared_preload_libraries: "auto_explain"],
  [{:"auto_explain.log_wal", "on"}],
  [configure: fn config -> config end],
  [after_connect: fn _connection -> :ok end],
  [url: "postgresql:///synthetic?options=-c%20session_preload_libraries%3Dauto_explain"]
] do
  refute KnowledgeSearchPlanObserver.startup_safe?(Keyword.merge(baseline, override))
end
```

Implement `startup_safe?/1` as a pure closed predicate: require a keyword list, reject nonempty `:parameters`, nonnil `:options`, `:configure`, or `:after_connect`, any preload override key, any `auto_explain.*` key, and any nonempty URL query. Nil URL is allowed; a nonnil URL must be a valid binary URI without a query. Malformed input returns false without inspection. The observer accepts no caller-supplied config; apply this predicate inside target validation to the actual Repo config before opening an administrator or ordinary connection.

```elixir
def startup_safe?(config) when is_list(config) do
  Keyword.keyword?(config) and Enum.all?(config, fn {key, value} ->
    cond do
      key in [:options, :configure, :after_connect] -> is_nil(value)
      key == :parameters -> value in [nil, []]
      key in [:session_preload_libraries, :shared_preload_libraries, :local_preload_libraries] -> false
      String.starts_with?(Atom.to_string(key), "auto_explain.") -> false
      key == :url and is_nil(value) -> true
      key == :url and is_binary(value) ->
        uri = URI.parse(value)
        uri.scheme in ["postgres", "postgresql"] and uri.query == nil
      key == :url -> false
      true -> true
    end
  end)
rescue
  _ -> false
end
def startup_safe?(_), do: false
```

## Task 2: Real connection, atomic default ownership, and teardown

**Files:** Extend the same helper and owning test only.

- [x] Add an integration success/ownership contract using the real harness allocation:

```elixir
@tag :integration
test "startup defaults are removed before the callback and only the owned repo changes" do
  database = RequestRepo.config()[:database]
  shared = Process.whereis(RequestRepo)
  before = RequestRepo.get_dynamic_repo()
  assert {:ok, :verified} = KnowledgeSearchPlanObserver.with_observer(database, fn observer_repo ->
    assert observer_repo == KnowledgeSearchPlanObserver.Repo
    owned = Process.whereis(observer_repo)
    assert is_pid(owned) and owned != shared
    assert Process.whereis(RequestRepo) == shared
    assert RequestRepo.get_dynamic_repo() == before
    assert KnowledgeSearchPlanObserver.clean?(database)
    :verified
  end)
  assert RequestRepo.get_dynamic_repo() == before
  assert Process.whereis(RequestRepo) == shared
  assert Process.whereis(KnowledgeSearchPlanObserver.Repo) == nil
  assert KnowledgeSearchPlanObserver.clean?(database)
end
```

- [x] Parent runs RED through its harness, then repeats this command at each integration increment:

```sh
devenv shell -- bash .devenv/phase3-integration.sh apps/singularity_storage/test/singularity/storage/postgres/knowledge_search_plan_observer_test.exs --seed 215378
```

Expected RED: missing observer lifecycle, or a closed setup/evidence error if the environment cannot satisfy the prerequisite. Report the latter precisely; it is not a reason to substitute SET ROLE or weaken notice proof.

- [x] Define the single fixed private observer Repo **inside** `Singularity.Storage.KnowledgeSearchPlanObserver`, with the established Ecto adapter and explicit diagnostic suppression:

```elixir
defmodule Repo do
  use Ecto.Repo, otp_app: :singularity_storage, adapter: Ecto.Adapters.Postgres
  @impl true
  def default_options(_operation), do: [telemetry_event: nil]
end
alias __MODULE__.Repo
```

Start `Repo` from the already validated actual `RequestRepo.config()` connection options, replacing only Repo identity/telemetry-prefix metadata and the test pool size. Its registered name must equal this fixed module, so atom lookup and transaction methods resolve the same pool. Use pool size one; do not add configure/after_connect hooks or change application env. A pre-existing name or startup race returns the closed setup failure and never adopts/stops that PID; defaults installed by this attempt follow pre-reset cleanup. Only a successful `{:ok, owned_pid}` is owned. The nested-collision contract proves the original observer remains alive and its catalog footprint is preserved. Pass `Repo` explicitly to every observer verification, scoped query, summary call, and later unchanged `KnowledgeSearchStore.search/2` invocation. SafeSQL supplies `log: false` for Ecto queries; raw Postgrex logging remains `nil`. No callable administrator Repo is added.

- [x] Implement the administrator transport locally. Parse the existing provisioner URI into only `host`, `port`, `user`, `password`, and `dbname`; reject unsupported URI query keys rather than silently discarding TLS/service options. Require PostgreSQL scheme, no fragment/multiple-host authority, decoded socket equal to target socket, and port equal to target port. Derive username as the established test helper does (query `user`, userinfo, `PGUSER`, `USER`). Override database only with the validated current allocation. Do not print the URI/options or inspect exceptions. Wrap raw Postgrex startup/query/transaction failures into the fixed administrator error; always stop only its returned PID.

```elixir
defp admin_options(uri, target) do
  parameters = URI.decode_query(uri.query || "")
  userinfo = String.split(uri.userinfo || "", ":", parts: 2) |> Enum.map(&URI.decode/1)
  uri_user = case List.first(userinfo) do
    nil -> nil
    "" -> nil
    value -> value
  end
  username = parameters["user"] || uri_user ||
    System.get_env("PGUSER") || System.get_env("USER")
  socket = parameters["host"] || uri.host
  port = parameters["port"] || if(uri.port, do: Integer.to_string(uri.port), else: System.get_env("PGPORT"))
  allowed = ~w(host port user password dbname)
  if uri.scheme not in ["postgres", "postgresql"] or uri.fragment != nil or
       String.contains?(uri.authority || "", ",") or
       Enum.any?(Map.keys(parameters), &(&1 not in allowed)) or
       socket != target.socket or port != Integer.to_string(target.port) or
       not is_binary(username) or username == "" do
    throw(:observer_admin_failed)
  end
  [socket_dir: socket, port: target.port, username: username,
   password: parameters["password"] || Enum.at(userinfo, 1),
   database: target.database, log: nil, backoff_type: :stop]
end
```

After connection, privately verify `current_database()` equals target; `SHOW data_directory` equals `target.pgdata` exactly; `SHOW listen_addresses` is empty; and the connecting administrator is an existing superuser. This is the already-owned external permission, not a role grant. Query failure produces a fixed error without raw Postgrex inspection. A clean checkout with its own private harness directory satisfies the same identity checks without changing the helper.

- [x] Implement the Astra no-grant split preflight. Through the already-owned administrator only, verify the **global** preload baseline using private `pg_settings` rows, including `setting`, `source`, `reset_val`, and `pending_restart`:

```sql
SELECT name, setting, source, reset_val, pending_restart
FROM pg_catalog.pg_settings
WHERE name IN ('session_preload_libraries', 'shared_preload_libraries', 'local_preload_libraries')
ORDER BY name;
```

Require exactly those three rows, `setting=''`, `reset_val=''`, and `pending_restart=false`; accept only global sources `default`, `configuration file`, or `command line`. Reject role/database/client/session/other sources even if their effective value is empty, so a masked nonempty baseline cannot satisfy proof. Reject pre-existing applicable preload catalog keys rather than replacing them. Do not query the two hidden preload values through the web role, grant access to them, or weaken role verification.

- [x] Before installing defaults, open and stop one owned **ordinary** `RequestRepo.start_link(name: nil, pool_size: 1)` connection with the validated actual startup config. Pass its **PID directly** to SafeSQL for these fixed non-scoped queries; never pass the RequestRepo atom, set its dynamic selection, or call ScopedRepo on this PID. Verify `session_user = current_user = 'singularity_web'`, database/socket identity, readable `local_preload_libraries=''`, `log_min_messages='warning'`, `client_min_messages='notice'`, `row_security='on'`, and `enable_seqscan='on'`. Retain the readable disabled-auto_explain checks: `log_min_duration` absent/empty/`-1`, and `log_nested_statements` absent/empty/`off`. Require no registered auto_explain settings and a real read-only probe with no plan NOTICE:

```sql
SELECT count(*)::integer FROM pg_catalog.pg_settings WHERE name LIKE 'auto_explain.%';
SELECT 1 AS observer_probe;
```

Privately require the first result to be zero, the second exactly one scalar `1`, and the second result's messages to contain no auto_explain `duration: ... plan:\n` NOTICE. Keep those raw results inside the helper. This same fresh-session proof runs in `clean?/1`; its unnamed PID does not collide with the named observer Repo and can run during the callback. Use a lexical `try/after` to stop only that fresh PID. Together, administrator global/catalog checks, startup-config rejection, and the actual fresh-session negative control replace only the unavailable hidden web GUC reads. Neither path changes shared RequestRepo, its dynamic selection, or application env.

- [x] Read applicable inherited database-role settings before install, including global role/database entries, and reject **every** existing `auto_explain.*` key, not merely keys in `@defaults`. Reject any applicable preload catalog key and every pre-existing owned target default key, even an identical value, so cleanup cannot claim pre-existing state as owned. Fixed logging keys may have compatible inherited values (`client_min_messages=notice`, `log_min_messages=warning`) but the target `(web_oid, database_oid)` row must not already define them. Snapshot complete applicable catalog rows with their database/role identities before install and require the exact same footprint after successful reset. Preserve compatible inherited logging and unrelated keys in all rows; `clean?/1` uses the same compatibility rule and must not falsely reject them.

```sql
SELECT settings.setdatabase, settings.setrole, configuration
FROM pg_catalog.pg_db_role_setting AS settings
CROSS JOIN LATERAL unnest(settings.setconfig) AS configuration
WHERE settings.setdatabase IN (0, (SELECT oid FROM pg_catalog.pg_database WHERE datname=$1))
  AND settings.setrole IN (0, 'singularity_web'::regrole::oid);
```

Use the private administrator transaction below for install and reset. The validated name contains only the fixed prefix and lowercase hex; settings/value strings come exclusively from `@defaults`. No caller string becomes a SQL identifier/value except that validated name.

```elixir
defp change_defaults(connection, database, mode) when mode in [:install, :reset] do
  Postgrex.transaction(connection, fn tx ->
    query_private!(tx, "SELECT pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended($1, 0))",
      ["singularity:test:plan-observer:" <> database])
    # In install mode, check the catalog conflicts described above before any ALTER.
    # In reset mode, require each target-row key still equals the value we installed.
    verify_default_ownership!(tx, database, mode)
    for {setting, value} <- @defaults do
      sql = case mode do
        :install -> "ALTER ROLE singularity_web IN DATABASE \"#{database}\" SET #{setting} TO '#{value}'"
        :reset -> "ALTER ROLE singularity_web IN DATABASE \"#{database}\" RESET #{setting}"
      end
      query_private!(tx, sql, [])
    end
    :ok
  end, log: nil)
end
```

`query_private!/3` uses `Postgrex.query/4` with `log: nil`, returns the raw result only inside the helper, and throws a closed atom on failure. All raw Postgrex startup/query/transaction logging is nil or omitted, never false; no raw DBConnection logger callback is installed. `verify_default_ownership!/3` splits each catalog entry at its first `=`; install rejects existing owned target keys or incompatible inherited observation state; reset verifies all installed target values and aborts atomically if another writer changed them. Do not reset changed/conflicting state. Admin raw values never reach assertions, logs, or the helper's public result.

- [x] Implement the lifecycle in this exact order:

```elixir
# After validated target, administrator identity and ordinary preflight:
# Full database/role/key/value rows are immutable data passed through scopes.
original_catalog = settings(connection, target)
:ok = install_defaults_checked!(connection, target)
case start_after_install(connection, target, fault, original_catalog) do
  {:ok, owned} ->
    try do
      case reset_before_callback(connection, target, original_catalog, Repo) do
        :ready -> invoke_callback(callback, Repo)
        {:error, _} = error -> error
      end
    after
      stop_owned_observer_repo(owned)
    end
  {:error, _} = error -> error
end

defp start_after_install(connection, target, fault, original_catalog) do
  try do
    if fault == :after_install, do: throw(:observer_setup_failed)
    case start_owned_observer_repo() do
      {:ok, owned} -> {:ok, owned}
      _ -> throw(:observer_setup_failed)
    end
  rescue
    _ -> cleanup_before_reset(connection, target, original_catalog)
  catch
    _, _ -> cleanup_before_reset(connection, target, original_catalog)
  end
end

defp reset_before_callback(connection, target, original_catalog, observer_repo) do
  try do
    :ok = verify_observer_connection!(observer_repo)
    :ok = reset_owned_defaults_checked!(connection, target, original_catalog)
    :ready
  rescue
    _ -> cleanup_before_reset(connection, target, original_catalog)
  catch
    _, _ -> cleanup_before_reset(connection, target, original_catalog)
  end
end

defp cleanup_before_reset(connection, target, original_catalog) do
  try do
    case reset_owned_defaults_checked!(connection, target, original_catalog) do
      :ok -> {:error, :observer_setup_failed}
      _ -> {:error, :observer_cleanup_failed}
    end
  rescue
    _ -> {:error, :observer_cleanup_failed}
  catch
    _, _ -> {:error, :observer_cleanup_failed}
  end
end

defp invoke_callback(callback, observer_repo) do
  try do
    {:ok, callback.(observer_repo)}
  rescue
    _ -> {:error, :observer_callback_failed}
  catch
    _, _ -> {:error, :observer_callback_failed}
  end
end
```

`start_owned_observer_repo/0` starts the fixed named real `Repo` with the validated connection options and pool size one, unlinks only its successfully returned PID, and wraps failures without raw inspection. `stop_owned_observer_repo/1` stops that PID, monitors it, and confirms DOWN with a bounded deadline; never stops shared RequestRepo or a colliding existing process. The start/setup cleanup scopes end before `invoke_callback/2`: after successful immediate reset, callback success or failure owns only the Repo, never defaults. No process-dictionary mutable state, dynamic binding, or unconditional reset in an outer `after`. Shared RequestRepo PID and dynamic selection remain unchanged even on connection-verification/reset failure. An outer `after` always stops the owned administrator PID. When install itself fails, its transaction rolls back and no reset is attempted. `reset_owned_defaults_checked!/3` verifies installed ownership, removes only those defaults, and compares the complete catalog to the explicit `original_catalog` snapshot **inside** its transaction before commit. It returns committed success without a fallible post-commit action; uncertain/failed reset cleanup verifies exact ownership and never resets conflicting newly introduced keys.

- [x] `verify_observer_connection!/1` receives the fixed observer Repo module explicitly and checks both real users, database, positive backend PID, all **readable** installed settings (canonical equivalent `0`/`0ms` duration values accepted), `local_preload_libraries=''`, and unchanged `row_security=on`, `enable_seqscan=on`. Remove only `session_preload_libraries` and `shared_preload_libraries` from web reads; the 13-key install allowlist and atomic administrator ownership checks remain intact. Registered auto_explain settings plus the actual analyzed nested proof demonstrate that the intended module is loaded. `clean?/1` checks no owned target defaults or applicable `auto_explain.*`/preload defaults remain, permits unchanged compatible inherited logging, and repeats the ordinary explicit-PID fresh-session zero-registered-settings/no-plan-NOTICE proof. It never changes dynamic selection or replaces/stops the current observer.

- [x] Parent observes GREEN for this increment. No raw result pattern match occurs in ExUnit; helpers return only closed errors/identity predicates. Record exact executed/excluded counts.

## Task 3: Actual nested definer evidence, not copied SQL

**Files:** Extend the same helper and owning test.

- [x] Add the positive proof contract:

```elixir
@tag :integration
test "the real web login observes executed nested authorization SQL privately" do
  scope = Fixtures.two_vaults!().one |> Map.take([:principal_id, :vault_id])
  database = RequestRepo.config()[:database]
  assert {:ok, {:ok, summary}} = KnowledgeSearchPlanObserver.with_observer(database, fn observer_repo ->
    KnowledgeSearchPlanObserver.authorization_summary(observer_repo, scope)
  end)
  assert Map.keys(summary) |> Enum.sort() ==
    Enum.sort([:backend, :nested_statements, :executed_nodes, :actual_rows,
      :actual_loops, :buffer_nodes, :indexes])
  assert summary.backend > 0
  assert summary.nested_statements > 0
  assert summary.executed_nodes > 0
  assert summary.actual_rows == 1
  assert summary.actual_loops > 0
  assert summary.buffer_nodes > 0
  assert summary.indexes == []
  assert KnowledgeSearchPlanObserver.clean?(database)
end
```

- [x] Parent runs the owning harness command. Expected RED: closed `:observer_evidence_missing`, not a raw notice dump.

- [x] `authorization_summary/2` accepts only the fixed `KnowledgeSearchPlanObserver.Repo` module and invokes the **existing** scoped definer through that dedicated real-web connection. Read its deployed `prosrc`, owner, language, STABLE/definer flags, and OID privately from pg_proc through the same explicit module, and verify the existing trusted function identity. Its exact existing owner is `singularity_authorization_definer`: immutable migration `20260718000800_add_task11_authorization_functions.exs` sets that role before creating this function. Do not confuse this owner with the separately proposed candidate function's `singularity_table_owner`. Do not create or replace a function. Use that deployed source to recognize its actual nested Query Text; it is an identity check, never SQL executed separately for proof.

```elixir
ScopedRepo.transact(observer_repo, scope, fn repo ->
  # Actual fixed production definer call, no SET ROLE and no copied inner SQL.
  case SafeSQL.query(repo, "SELECT principal_id FROM core.live_principal_authorization()") do
    {:ok, raw} -> summarize_authorization_result(raw, deployed_source)
    _ -> {:error, :observer_evidence_missing}
  end
end)
```

Keep `raw`, rows, messages, deployed source, and connection metadata private. Privately verify exactly one returned principal equals the supplied synthetic scope principal after UUID normalization and `raw.connection_id` equals the verified observer backend. The actual outer SQL returns one identity as a positive control; the public summary omits it. Never use `assert %{messages: ...} = raw`, inspect raw errors, or return raw notices to the test.

- [x] Parse only fixed auto_explain message forms with atom keys. For each NOTICE containing `plan:\n`, split once, decode the JSON object, and match its `Query Text` to whitespace-normalized deployed SQL-function `prosrc`. Require its `:where` context to identify `SQL function "live_principal_authorization"`; keep that check strict until feasibility proves the actual protocol. Other scope/context-setting/catalog/outer statements cannot satisfy nested proof.

```elixir
defp authorization_plan(message, deployed_source) do
  text = Map.get(message, :message, "")
  context = Map.get(message, :where, "")
  with true <- Map.get(message, :severity) == "NOTICE",
       true <- String.starts_with?(text, "duration: "),
       true <- String.contains?(context, ~s(SQL function "live_principal_authorization")),
       [_prefix, json] <- String.split(text, "plan:\n", parts: 2),
       {:ok, %{"Query Text" => query_text, "Plan" => plan}} <- JSON.decode(json),
       true <- normalized_sql(query_text) == normalized_sql(deployed_source) do
    {:ok, plan}
  else
    _ -> :not_authorization_plan
  end
end

defp normalized_sql(sql), do: sql |> String.trim() |> String.trim_trailing(";") |> String.replace(~r/\s+/, " ")

defp nodes(%{"Plans" => children} = node), do: [node | Enum.flat_map(children, &nodes/1)]
defp nodes(node) when is_map(node), do: [node]
```

Within helper-local parsing, require an analyzed root `Actual Rows == 1`, positive `Actual Loops`, and integer nonnegative `Shared Hit Blocks`/`Shared Read Blocks` (or other known buffer keys) on at least one executed node. Reject missing analysis or nonnumeric values with `:observer_evidence_missing`. Return only the seven named keys: positive backend, number of matched nested statements, executed-node count, root rows/loops, executed buffer-node count, and empty `indexes` (this prerequisite claims no search-index use). Bound every exported integer to `0..1_000_000_000`; reject larger/malformed values. Never export Query Text, expressions, full node maps, unknown node/index names, or Postgrex fields.

- [x] Parent observes GREEN; verify at least one real nested plan and buffers arrived in the **same actual call's** result. Do not substitute a Function Scan or copied SQL if context/analysis is missing. Actual candidate-index proof will be added by the separate repair plan using this demonstrated transport.

## Task 4: Exception and partial-setup cleanup contracts

**Files:** Extend the owning test and complete helper cleanup paths.

- [x] Add both deterministic contracts:

```elixir
@tag :integration
test "callback exceptions preserve shared repo state and remove defaults" do
  database = RequestRepo.config()[:database]
  previous = RequestRepo.get_dynamic_repo()
  shared = Process.whereis(RequestRepo)
  assert {:error, :observer_callback_failed} =
    KnowledgeSearchPlanObserver.with_observer(database, fn _observer_repo -> raise "synthetic observer callback fault" end)
  assert RequestRepo.get_dynamic_repo() == previous
  assert Process.whereis(RequestRepo) == shared
  assert Process.whereis(KnowledgeSearchPlanObserver.Repo) == nil
  assert KnowledgeSearchPlanObserver.clean?(database)
end

@tag :integration
test "failure after committed install removes defaults before any callback" do
  database = RequestRepo.config()[:database]
  previous = RequestRepo.get_dynamic_repo()
  assert {:error, :observer_setup_failed} =
    KnowledgeSearchPlanObserver.with_observer(database,
      fn _observer_repo -> flunk("early setup failure reached callback") end, :after_install)
  assert RequestRepo.get_dynamic_repo() == previous
  assert Process.whereis(KnowledgeSearchPlanObserver.Repo) == nil
  assert KnowledgeSearchPlanObserver.clean?(database)
end
```

- [x] Run RED, implement the cleanup ordering from Task 2, rerun GREEN. Assert monitor-confirmed termination of every owned PID internally, including early connection/identity failure; do not infer cleanup merely from restored defaults. Use the explicit lexical cleanup scopes above, not process-dictionary state or logging PIDs/options/errors. Admin install rollback and successful immediate reset each have positive catalog checks, not timeout-only evidence.

## Task 5: Conflicting state is untouched; diagnostics do not escape

**Files:** Extend the same two files.

- [x] Add the final integration contract with a fixed conflict fixture:

```elixir
@tag :integration
test "pre-existing observation state is rejected without mutation or diagnostic leakage" do
  database = RequestRepo.config()[:database]
  owner = self()
  log = ExUnit.CaptureLog.capture_log(fn ->
    assert :ok = KnowledgeSearchPlanObserver.with_conflicting_default(database, fn ->
      assert {:error, :observer_configuration_conflict} =
        KnowledgeSearchPlanObserver.with_observer(database, fn _observer_repo -> flunk("conflict reached callback") end)
      send(owner, :conflict_rejected)
      :ok
    end)
    assert :ok = KnowledgeSearchPlanObserver.with_inherited_logging(database, fn ->
      assert {:ok, :inherited_verified} = KnowledgeSearchPlanObserver.with_observer(database, fn _observer_repo ->
        assert KnowledgeSearchPlanObserver.clean?(database)
        :inherited_verified
      end)
      assert KnowledgeSearchPlanObserver.clean?(database)
      :ok
    end)
  end)
  assert_receive :conflict_rejected
  assert_receive :conflict_rejected
  refute_receive :conflict_rejected
  diagnostics_empty = log == ""
  assert diagnostics_empty, "observer emitted diagnostic output"
  assert KnowledgeSearchPlanObserver.clean?(database)
end
```

- [x] Implement `with_conflicting_default/2` with fixed internal iteration over two **independent** mutations on the validated allocation: first `auto_explain.log_min_duration='-1'`, then `auto_explain.log_wal='on'`. The second intentionally is not in the observer's install allowlist. Before each fixture, require no existing applicable observation defaults; atomically install only its one fixed setting; invoke callback exactly once; verify the complete catalog footprint is unchanged by rejection; finally remove exactly the fixture-owned key before the next fixture. Use the same private transport/ownership lock. Keep `/2`; do not expose a selector, settings map, role, SQL, or connection override. The test's two bounded controls prove both branches ran. Equality stays inside the helper so raw settings never enter failing ExUnit inspection.

- [x] Implement `with_inherited_logging/2` as a second fixed fixture, at **database-only** defaults for the validated allocation (not the target web/database row): `ALTER DATABASE <validated allocation> SET client_min_messages TO 'notice'` and `SET log_min_messages TO 'warning'`. Snapshot the complete applicable catalog footprint. As a minimal fixed-fixture precondition, reject **any** existing key at either same database-only target, including an identical compatible value, before mutation; never overwrite or adopt it. The regular observer still permits compatible inherited logging. Within the callback the observer must succeed and `clean?/1` must remain true while the two fixture-owned inherited keys still exist. Verify the observer returned the exact pre-observer fixture footprint, remove only these fixture-owned logging keys, and verify the exact original footprint afterward, including exception paths. No global role defaults or other database changes; no RESET ALL or arbitrary-settings fixture API.

- [x] Wrap the real success, callback-exception, and early-setup integration operations in `CaptureLog.capture_log/1` too; require the entire captured log to be empty using the computed boolean above and a constant failure message. Never place raw `log`, raw results, SQL, or messages directly in an ExUnit assertion whose failure would inspect them. This stronger empty-log assertion retains all previous no-plan/no-Query-Text/no-callback-error checks and also catches administrator SQL logging. Attach one uniquely named temporary telemetry handler to the actual RequestRepo, MigrationRepo, and **observer Repo** query-event surfaces in the successful proof test. Count any query event containing raw SQL/params/results and assert zero; detach in `on_exit`. Do not publish captured messages through telemetry, even for this synthetic fixture. The helper itself never calls Logger/IO/telemetry. Existing privacy assertions remain unchanged and uninstrumented.

```elixir
id = "observer-prerequisite-#{System.unique_integer([:positive])}"
owner = self()
events = Enum.map([RequestRepo, Singularity.Storage.MigrationRepo, KnowledgeSearchPlanObserver.Repo],
  &(&1.config()[:telemetry_prefix] ++ [:query]))
:ok = :telemetry.attach_many(id,
  events,
  fn _event, _measurements, _metadata, pid -> send(pid, :unexpected_observer_query_event) end, owner)
on_exit(fn -> :telemetry.detach(id) end)
# Execute only the observer operation while attached, not Fixtures.two_vaults!().
refute_receive :unexpected_observer_query_event
```

- [x] Parent runs GREEN. Expected final totals: default run **one executed pure case, five excluded**; owning integration run **five executed cases, one excluded**, all passing. ExUnit aliases/helper calls must compile before the intended RED assertions. No test uses sleeps for success, cleanup, or conflict ownership.

## Task 6: Independent review, local commit, and evidence handoff

**Files:** The two created test files; coordinator-owned evidence record only.

- [x] Parent runs the complete owning unit/integration commands above and records exact source hash, seed, executed/excluded counts, actual nested-call proof counters, and cleanup. Parent verifies temporary pg_db_role_setting keys absent before disposing of the allocation, checks a fresh ordinary web connection, then uses the harness EXIT cleanup for its owned server. Never print raw plans or credentials to establish proof.

- [x] Parent runs bounded static checks:

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix do format --check-formatted apps/singularity_storage/test/support/knowledge_search_plan_observer.ex apps/singularity_storage/test/singularity/storage/postgres/knowledge_search_plan_observer_test.exs, compile --warnings-as-errors, xref graph --format cycles --fail-above 0
git diff --check
devenv shell -- bash .devenv/phase3-cleanup-inventory.sh
```

- [x] Obtain independent SPEC review first, then QUALITY review. Resolve important findings and retain failed prerequisite evidence. Ordinary repair follows the documented cumulative Sol/Astra policy; missing module/permission or uncontrollable notice leakage is an environment/evidence blocker, never a reason to broaden privilege or weaken proof.

- [ ] After owning/static checks and independent reviews pass, parent stages only the prerequisite implementation, this plan, and its dated evidence update and makes a small local commit:

```sh
git add apps/singularity_storage/test/support/knowledge_search_plan_observer.ex apps/singularity_storage/test/singularity/storage/postgres/knowledge_search_plan_observer_test.exs docs/superpowers/specs/2026-10-10-singularity-v0.2-phase-3-search-index-repair-design.md docs/superpowers/plans/2026-10-10-singularity-v0.2-phase-3-search-plan-observer.md docs/verification/2026-10-09-phase-3-acceptance.md
git commit -m "test(storage): prove isolated nested search-plan observation"
```

Keep the existing privacy/failed plan tests untracked and unchanged unless the coordinator separately owns their later staging. No migration or production repair is included in this commit. Return actual prerequisite evidence to the coordinator, who writes the separate candidate-function/Store repair plan. Phase 3 index qualification remains FAIL until that repair is implemented and its actual nested selective-index contracts pass; E2E stays NOT RUN and phase acceptance stays incomplete.

## Self-review before handoff

- [x] Verify role, target, default list, admin URI restrictions, immediate atomic removal, fixed named real observer Repo, explicit Repo/PID routing, unchanged shared/dynamic RequestRepo state, owned-PID termination, conflict preservation, and fresh ordinary-session controls match the reviewed design.
- [x] Verify no code/assertion returns, inspects, logs, artifacts, or telemetry-emits raw messages/SQL/credentials. All evidence counts come from the real scoped call on the real web login and its nested deployed definer source/context.
- [x] Verify one pure/five integration cases cover invalid target and startup override rejection, successful observation/lifecycle, callback fault, committed-install fault, both independent fixed observation conflicts, and compatible inherited logging preservation without shared fixture/config changes.
- [x] Verify every named helper function above has the specified implementation behavior before claiming GREEN; code blocks are task-local implementation anchors, not proof of execution. Check all command paths/links and absence of unresolved implementation choices.

Planning self-review performed against accepted corrected design `abf390ced68bd2d3a5604a139da8c58d1ef05d6aaec5b22abd5ecb067cfb9d06`: all observation prerequisites have owning tasks; interfaces/settings/errors are closed; diagnostics remain private; existing production code and index assertions remain untouched. The two hidden web reads are replaced, not granted; the fixed real Repo is passed explicitly through unchanged production methods, and actual source/context/backend/analyzed nested proof is unchanged. Shared RequestRepo and dynamic selection stay untouched throughout; fresh ordinary probes use an explicit unnamed PID without scoped calls. No tests, formatting, databases, services, or Git mutations were run by the plan author. Parent-run qualification and independent reviews are recorded below.

## Prerequisite qualification, 2026-10-10

Implementation and owning verification PASS; independent Sol SPEC followed by
QUALITY review PASS with no outstanding important findings. Both reviews used
helper `87213eef3a4a8017004951781a04160b06e01a3e3ed199c73e5ccc5505c3e8f3`
and test `d36687ebe9b079ee6f87da51bbec358c385b5466216858a24b81364fe6963b16`.
SPEC also reviewed plan behavior at `a14b17361032cf9d79bf618cbfc0976cd2c6d8e5d30d67e062dac0f152efb1b3`;
subsequent plan edits record outcomes and completed checklist items only.

Parent sessions `17116` (five integration cases), `62549` (one pure case,
format, compile with warnings as errors, compile-connected xref), and `30119`
(full xref and cleanup inventory) all exited 0. The actual analyzed nested
authorization call yielded one statement, 12 executed nodes, one row/loop,
and 12 buffer-bearing nodes. No search-index claim follows from this result.
The owned server is stopped, all generated databases are absent, and all
recorded storage roots are absent. Local link check `a4e72d` found nine valid
links across three documents. Exact commands, failed attempts, closed proof
summary, and cumulative repair counters remain in the
[acceptance record](../../verification/2026-10-09-phase-3-acceptance.md).

The prerequisite is ready for its local commit and the separate concrete
candidate-function/Store repair plan. Existing privacy, failed query-plan, and
legacy concurrency tests remain byte-identical. No production, migration,
Vault, E2E, publication, deployment, activation, or backfill change occurred.
