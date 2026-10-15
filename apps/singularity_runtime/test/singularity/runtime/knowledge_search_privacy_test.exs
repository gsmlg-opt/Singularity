defmodule Singularity.Runtime.KnowledgeSearchPrivacyTest do
  use Singularity.Storage.DataCase, async: false
  import ExUnit.CaptureLog
  @moduletag :integration

  alias Singularity.Core.{DocumentFragment, Error, JobEnvelope, SourceLocator}

  alias Singularity.Runtime.{
    Api,
    Authorize,
    AuthorizationDependencies,
    CustodyReader,
    JobDispatcher,
    KeyCustodian,
    KeyLeaseSupervisor,
    OperationScope,
    ResolveSession,
    SessionContext
  }

  alias Singularity.Runtime.Search.{Rebuild, Resolve, Search}

  alias Singularity.Storage.{
    AuthorizationLock,
    Fixtures,
    KnowledgeFixtures,
    MigrationRepo,
    SafeSQL,
    ScopedRepo,
    VaultLock
  }

  alias Singularity.Storage.Jobs.ObanAdapter
  alias Singularity.Storage.Postgres.{IdentityRepository, PreAuth, SearchProjectionReconciler}

  @canaries %{
    q: "privacyquerycanary8101",
    title: "privacytitlecanary8102",
    body: "privacybodycanary8103",
    snippet: "privacysnippetcanary8104",
    heading: "privacyheadingcanary8105",
    tag: "privacytagcanary8106"
  }
  @denial [:singularity, :authorization, :rls_denial]
  @retry [:singularity, :job, :retry]

  # Faults are synthetic adapter diagnostics, never substitutes for live authorization.
  defmodule FaultSearch do
    def search(context, _store, repo, _query) do
      notify(context, repo, :search)
      Singularity.Runtime.KnowledgeSearchPrivacyTest.fault(context.mode)
    end

    def notify(context, repo, operation) do
      %{rows: [["singularity_web", true]]} =
        SafeSQL.query!(repo, "SELECT current_user, current_setting('singularity.vault_id') <> ''")

      send(context.observer, {:privacy_adapter, context.tag, operation})
    end
  end

  defmodule FaultSource do
    def resolve(context, repo, _selector) do
      FaultSearch.notify(context, repo, :resolve)
      Singularity.Runtime.KnowledgeSearchPrivacyTest.fault(context.mode)
    end
  end

  defmodule FaultRebuild do
    def resource_kind(_context, repo, id),
      do: SearchProjectionReconciler.resource_kind(repo, id)

    def reconcile(context, repo, id) do
      {:ok, 1} = SearchProjectionReconciler.reconcile(repo, id)
      FaultSearch.notify(context, repo, :rebuild)
      Singularity.Runtime.KnowledgeSearchPrivacyTest.fault(context.mode)
    end
  end

  defmodule ObservedSearch do
    def search({observer, tag}, store, repo, query) do
      %{rows: [[backend, "singularity_web"]]} =
        SafeSQL.query!(repo, "SELECT pg_backend_pid(), current_user")

      send(observer, {:privacy_search_backend, tag, backend})
      Singularity.Retrieval.KnowledgeSearch.search(store, repo, query)
    end
  end

  defmodule ObservedSource do
    def resolve({observer, tag}, repo, selector) do
      send(observer, {:privacy_source_content, tag})
      Singularity.Storage.Postgres.KnowledgeSearchStore.resolve(repo, selector)
    end
  end

  defmodule RetryProjection do
    def reconcile_document({state, observer}, repo, envelope) do
      %{rows: [["singularity_worker"]]} = SafeSQL.query!(repo, "SELECT current_user")
      result = SearchProjectionReconciler.reconcile_document(repo, envelope)
      send(observer, {:privacy_projection, envelope.job_id, result})

      case Agent.get(state, & &1) do
        :delegate -> result
        mode -> Singularity.Runtime.KnowledgeSearchPrivacyTest.fault(mode)
      end
    end
  end

  defmodule RetryHandler do
    def dependencies,
      do: Application.fetch_env!(:singularity_storage, :knowledge_search_privacy_dependencies)

    def handle(context, envelope), do: JobDispatcher.handle(context, envelope)

    def handle_failure(context, envelope, failure, attempt),
      do: JobDispatcher.handle_failure(context, envelope, failure, attempt)
  end

  setup do
    source = KnowledgeFixtures.source!()
    {runtime, session} = live_runtime!(source)
    note = note!(source)
    {document, fragment} = document!(source)
    tag = tag!(source, [note, document])
    project!(source, [note, document])

    handler = {__MODULE__, make_ref()}
    repos = [RequestRepo, PreAuthRepo, WorkerRepo, DispatcherRepo, MigrationRepo]
    query_events = Enum.uniq(Enum.map(repos, &(&1.config()[:telemetry_prefix] ++ [:query])))

    events =
      query_events ++
        [
          @denial,
          @retry,
          [:singularity, :job, :failure],
          [:oban, :job, :start],
          [:oban, :job, :stop],
          [:oban, :job, :exception]
        ]

    assert :ok = :telemetry.attach_many(handler, events, &__MODULE__.handle_event/4, self())
    on_exit(fn -> :telemetry.detach(handler) end)

    %{
      source: source,
      note: note,
      document: document,
      fragment: fragment,
      tag: tag,
      runtime: runtime,
      session: session,
      query_events: query_events
    }
  end

  test "real search and exact source return authorized canaries only through content DTOs", c do
    diagnostics(c, fn ->
      for q <- [@canaries.q, @canaries.title, @canaries.body, @canaries.snippet] do
        assert {:ok, %{items: items, next_cursor: nil}} =
                 Api.search_knowledge(config(c.runtime), c.session, %{q: q, tag_ids: [c.tag]})

        assert Enum.sort(Enum.map(items, & &1.kind)) == [:document, :note]
        assert Enum.all?(items, &(&1.title == @canaries.title))
        assert Enum.all?(items, &String.contains?(&1.snippet, @canaries.snippet))
        assert Enum.all?(items, &(not String.contains?(&1.snippet, @canaries.body)))
        refute inspect(items, limit: :infinity, printable_limit: :infinity) =~ @canaries.tag

        document = Enum.find(items, &(&1.kind == :document))
        assert SourceLocator.to_map(document.locator)["heading_path"] == [@canaries.heading]
      end

      assert {:ok, %{items: [_], next_cursor: cursor}} =
               Api.search_knowledge(config(c.runtime), c.session, %{
                 q: @canaries.q,
                 tag_ids: [c.tag],
                 limit: 1
               })

      assert is_binary(cursor)
      assert {:ok, cursor_payload} = Base.url_decode64(cursor, padding: false)
      assert_clean(cursor)
      assert_clean(cursor_payload)

      for selector <- [selector(c.note, :note, nil), document_selector(c)] do
        assert {:ok, source} = Api.resolve_search_source(config(c.runtime), c.session, selector)
        assert source.title == @canaries.title
        assert source.body == body()
      end

      # Positive control: the real worker cannot read import receipt state directly.
      assert {:error,
              %Postgrex.Error{
                postgres: %{code: :insufficient_privilege, pg_code: "42501"}
              } = error} =
               SafeSQL.query(
                 WorkerRepo,
                 "SELECT state FROM content.document_import_receipts WHERE state=$1",
                 [@canaries.title]
               )

      assert_clean(error)

      assert_receive {:privacy_event, @denial, %{count: 1}, %{repo: :worker}} = denial_event
      assert elem(denial_event, 2) == %{count: 1}
      assert elem(denial_event, 3) == %{repo: :worker}
      assert_clean(denial_event)
    end)
  end

  test "malformed public inputs discard every content-bearing diagnostic before callbacks", c do
    forbidden_callback = fn _, _ -> flunk("malformed input reached content callback") end

    config = %{
      search_knowledge: forbidden_callback,
      resolve_search_source: forbidden_callback,
      rebuild_search: forbidden_callback
    }

    diagnostics(c, fn ->
      for canary <- Map.values(@canaries),
          params <- [
            %{q: String.duplicate(canary, 100)},
            %{q: @canaries.q, cursor: canary <> "\0"},
            %{q: @canaries.q, owner_scope_id: canary},
            %{q: @canaries.q, tag_ids: [canary]}
          ] do
        assert_clean(Api.search_knowledge(config, c.session, params))
        assert Api.search_knowledge(config, c.session, params) == {:error, :invalid}

        assert Api.resolve_search_source(
                 config,
                 c.session,
                 Map.put(document_selector(c), :body, canary)
               ) == {:error, :invalid}

        assert Api.rebuild_search(config, c.session, %{resource_id: canary}) == {:error, :invalid}
      end

      for canary <- Map.values(@canaries) do
        assert Api.search_knowledge(config(c.runtime), c.session, %{
                 q: @canaries.q,
                 cursor: canary
               }) == {:error, :invalid}
      end
    end)
  end

  test "synthetic search adapter errors and exceptions are sanitized after live authority", c do
    diagnostics(c, fn ->
      for mode <- [:error, :raise, :throw, :malformed] do
        tag = make_ref()

        runtime =
          Map.put(
            c.runtime,
            :knowledge_search,
            {FaultSearch, %{observer: self(), tag: tag, mode: mode}}
          )

        assert_unavailable(Search.run(runtime, context(c), %{q: @canaries.q}))

        assert Api.search_knowledge(config(runtime), c.session, %{q: @canaries.q}) ==
                 {:error, :storage_unavailable}

        for _ <- 1..2, do: assert_receive({:privacy_adapter, ^tag, :search})
      end
    end)
  end

  test "synthetic exact-source adapter errors and exceptions never return private messages", c do
    diagnostics(c, fn ->
      for mode <- [:error, :raise, :throw, :malformed] do
        tag = make_ref()

        runtime =
          Map.put(
            c.runtime,
            :knowledge_search_store,
            {FaultSource, %{observer: self(), tag: tag, mode: mode}}
          )

        assert_unavailable(Resolve.run(runtime, context(c), document_selector(c)))

        assert Api.resolve_search_source(config(runtime), c.session, document_selector(c)) ==
                 {:error, :storage_unavailable}

        for _ <- 1..2, do: assert_receive({:privacy_adapter, ^tag, :resolve})
      end
    end)
  end

  test "rebuild faults after real reconciliation roll back and expose only retryable codes", c do
    owner_query("DELETE FROM content.search_entries WHERE vault_id=$1", [c.source.vault_id])

    diagnostics(c, fn ->
      for mode <- [:error, :raise, :throw, :malformed_error] do
        tag = make_ref()

        runtime =
          Map.put(
            c.runtime,
            :search_projection_reconciler,
            {FaultRebuild, %{observer: self(), tag: tag, mode: mode}}
          )

        id = uuid(c.document.resource_id)
        assert_unavailable(Rebuild.run(runtime, context(c), id))

        assert Api.rebuild_search(config(runtime), c.session, id) ==
                 {:error, :storage_unavailable}

        for _ <- 1..2, do: assert_receive({:privacy_adapter, ^tag, :rebuild})
        assert projection_count(c) == 0
      end

      assert {:ok, %{resources: 1, entries: 1}} =
               Api.rebuild_search(config(c.runtime), c.session, uuid(c.document.resource_id))

      assert projection_count(c) == 1
    end)
  end

  @tag timeout: 25_000
  test "observed PostgreSQL lock wait reaches the real fixed deadline and a clean retry", c do
    diagnostics(c, fn ->
      {:ok, migration} = MigrationRepo.start_link(pool_size: 2)
      parent = self()
      tag = make_ref()

      blocker =
        Task.async(fn ->
          MigrationRepo.transaction(fn ->
            SafeSQL.query!(MigrationRepo, "SET LOCAL ROLE singularity_table_owner")

            SafeSQL.query!(
              MigrationRepo,
              "LOCK TABLE content.search_entries IN ACCESS EXCLUSIVE MODE"
            )

            %{rows: [[oid]]} =
              SafeSQL.query!(
                MigrationRepo,
                "SELECT 'content.search_entries'::regclass::oid"
              )

            send(parent, {:privacy_locked, tag, oid})

            receive do
              {^tag, :release} -> :ok
            after
              15_000 -> raise "privacy search deadline barrier expired"
            end
          end)
        end)

      try do
        assert_receive {:privacy_locked, ^tag, oid}, 5_000
        runtime = Map.put(c.runtime, :knowledge_search, {ObservedSearch, {self(), tag}})

        observed_config =
          Map.put(config(runtime), :search_knowledge, fn session, params ->
            result = Search.run(runtime, session, params)
            send(parent, {:privacy_timeout_result, tag, result})
            result
          end)

        reader =
          Task.async(fn ->
            Api.search_knowledge(observed_config, c.session, %{q: @canaries.q})
          end)

        try do
          assert_receive {:privacy_search_backend, ^tag, backend}, 5_000
          assert await_relation_wait(backend, oid, System.monotonic_time(:millisecond) + 4_000)
          assert Task.await(reader, 7_000) == {:error, :storage_unavailable}
          assert_receive {:privacy_timeout_result, ^tag, result}
          assert_unavailable(result)
        after
          send(blocker.pid, {tag, :release})
          drain_task(blocker)
          drain_task(reader)
        end
      after
        send(blocker.pid, {tag, :release})
        drain_task(blocker)
        Supervisor.stop(migration)
      end

      assert {:ok, %{items: items}} =
               Api.search_knowledge(config(c.runtime), c.session, %{q: @canaries.q})

      assert length(items) == 2
    end)
  end

  test "real exact-source not-found and revoked authority reveal neither source nor diagnostics",
       c do
    diagnostics(c, fn ->
      unknown = Map.put(document_selector(c), :resource_version_id, Ecto.UUID.generate())

      assert Api.resolve_search_source(config(c.runtime), c.session, unknown) ==
               {:error, :not_found}

      before = effects(c)["audit.events"]
      tag = make_ref()
      runtime = Map.put(c.runtime, :knowledge_search_store, {ObservedSource, {self(), tag}})
      selectors = [selector(c.note, :note, nil), document_selector(c)]

      for selected <- selectors do
        assert {:ok, _source} = Api.resolve_search_source(config(runtime), c.session, selected)
        assert_receive {:privacy_source_content, ^tag}
      end

      # Capability denial leaves membership active, so its denial audit can persist.
      owner_query(
        "UPDATE core.principal_capabilities SET revoked_at=CURRENT_TIMESTAMP WHERE principal_id=$1 AND vault_id=$2",
        [c.source.principal_id, c.source.vault_id]
      )

      for selected <- selectors do
        assert {:error, %Error{code: :forbidden, message: nil, details: %{}, retryable?: false}} =
                 error = Resolve.run(runtime, context(c), selected)

        assert_clean(error)

        assert Api.resolve_search_source(config(runtime), c.session, selected) ==
                 {:error, :forbidden}
      end

      refute_received {:privacy_source_content, ^tag}
      after_capability_denial = effects(c)["audit.events"]
      assert length(after_capability_denial) == length(before) + 4

      assert Enum.all?(after_capability_denial -- before, fn [row] ->
               row["operation"] == "authorization.denied" and row["result"] == "denied" and
                 row["metadata"] == %{}
             end)

      assert_clean(after_capability_denial)

      owner_query(
        "UPDATE core.principal_capabilities SET revoked_at=NULL WHERE principal_id=$1 AND vault_id=$2",
        [c.source.principal_id, c.source.vault_id]
      )

      assert %{num_rows: 1} =
               owner_query(
                 "UPDATE core.vault_members SET revoked_at=CURRENT_TIMESTAMP WHERE principal_id=$1 AND vault_id=$2",
                 [c.source.principal_id, c.source.vault_id]
               )

      # Existing audit RLS also rejects revoked membership. Preserve the legacy
      # fail-closed precedence: sanitized retryable storage failure, no audit row.
      for selected <- selectors do
        assert_unavailable(Resolve.run(runtime, context(c), selected))

        assert Api.resolve_search_source(config(runtime), c.session, selected) ==
                 {:error, :storage_unavailable}
      end

      refute_received {:privacy_source_content, ^tag}
      assert Enum.sort(effects(c)["audit.events"]) == Enum.sort(after_capability_denial)
    end)
  end

  test "durable Document projection retry records sanitized errors then executes the real worker",
       c do
    envelope = projection_envelope!(c)
    owner_query("DELETE FROM content.search_entries WHERE vault_id=$1", [c.source.vault_id])
    state = start_supervised!({Agent, fn -> :error end})
    install_env(:job_handler, RetryHandler)

    install_env(:knowledge_search_privacy_dependencies, %{
      authorization: c.runtime.authorization,
      authorize: Authorize,
      document_projection: {RetryProjection, {state, self()}}
    })

    assert Oban.whereis(Singularity.Oban)

    assert Enum.any?(
             :telemetry.list_handlers([:oban, :job, :exception]),
             &(&1.id == Singularity.Runtime.Observability.Telemetry)
           )

    diagnostics(c, fn ->
      assert {:ok, id} = ObanAdapter.submit(%{}, envelope)
      id = String.to_integer(id)
      # Isolate only this retained-event job; do not drain unrelated test jobs.
      queue = "knowledge_privacy_" <> Integer.to_string(id)

      assert %{rows: [["document_projection"]]} =
               owner_query("SELECT queue FROM jobs.oban_jobs WHERE id=$1", [id])

      assert %{num_rows: 1} =
               owner_query("UPDATE jobs.oban_jobs SET queue=$2 WHERE id=$1", [id, queue])

      failed = execute_job!(id, queue)
      assert failed.state == :failure
      assert_clean(Map.take(failed, [:result, :error, :stacktrace, :job]))
      assert_receive {:privacy_projection, job_id, {:ok, 1}}
      assert job_id == envelope.job_id

      assert %{rows: [["retryable", 1, errors]]} =
               owner_query("SELECT state,attempt,errors FROM jobs.oban_jobs WHERE id=$1", [id])

      assert length(errors) == 1
      assert_clean(errors)
      assert projection_count(c) == 0
      assert_receive {:privacy_event, @retry, %{count: 1}, metadata} = retry_event
      assert elem(retry_event, 2) == %{count: 1}
      assert_clean(retry_event)

      assert metadata == %{
               attempt: 1,
               max_attempts: failed.job.max_attempts,
               queue: :unknown,
               worker: :generic_worker
             }

      assert_receive {:privacy_event, [:oban, :job, :exception], _, failure_metadata} =
                       failure_event

      assert_clean(failure_event)
      assert_clean(failure_metadata)

      Agent.update(state, fn _ -> :delegate end)
      assert :ok = Oban.retry_job(Singularity.Oban, id)
      succeeded = execute_job!(id, queue)
      assert succeeded.state == :success
      assert_receive {:privacy_projection, ^job_id, {:ok, 1}}
      assert_receive {:privacy_event, [:oban, :job, :stop], _, success_metadata} = success_event
      assert_clean(success_event)
      assert_clean(success_metadata)

      assert %{rows: [["completed", 2]]} =
               owner_query("SELECT state,attempt FROM jobs.oban_jobs WHERE id=$1", [id])

      assert projection_count(c) == 1

      assert {:ok, %{items: [item]}} =
               Api.search_knowledge(config(c.runtime), c.session, %{
                 q: @canaries.q,
                 kind: :document
               })

      assert item.title == @canaries.title
      assert SourceLocator.to_map(item.locator)["heading_path"] == [@canaries.heading]
    end)
  end

  @doc false
  def fault(mode) do
    payload = Enum.join(Map.values(@canaries), " ")

    case mode do
      :error ->
        {:error,
         Error.new(:storage_unavailable, message: payload, details: @canaries, retryable?: true)}

      :raise ->
        raise payload

      :throw ->
        throw(payload)

      :malformed ->
        {:ok, @canaries}

      :malformed_error ->
        {:error, @canaries}
    end
  end

  @doc false
  def handle_event(event, measurements, metadata, owner),
    do: send(owner, {:privacy_event, event, measurements, metadata})

  defp diagnostics(c, callback) do
    log = capture_log([level: :debug], callback)
    assert_clean(log)
    events = drain_events()
    assert_clean(events)

    refute Enum.any?(events, fn {event, _, metadata} ->
             event in c.query_events and not harmless_control_query?(event, metadata)
           end)

    assert_clean(effects(c))
  end

  # Only the two exact, observed content-free control statements are exempt.
  # All their metadata still passes the complete six-canary assertion above.
  defp harmless_control_query?(event, %{
         repo: MigrationRepo,
         query: "SET LOCAL ROLE singularity_table_owner",
         params: []
       }),
       do: event == MigrationRepo.config()[:telemetry_prefix] ++ [:query]

  defp harmless_control_query?(event, %{
         repo: WorkerRepo,
         query:
           "SELECT pg_notify($1, payload) FROM json_array_elements_text($2::json) AS payload",
         params: ["jobs.oban_insert", ["{\"queue\":\"document_projection\"}"]]
       }),
       do: event == WorkerRepo.config()[:telemetry_prefix] ++ [:query]

  defp harmless_control_query?(_event, _metadata), do: false

  defp drain_events do
    receive do
      {:privacy_event, event, measurements, metadata} ->
        [{event, measurements, metadata} | drain_events()]
    after
      0 -> []
    end
  end

  defp assert_clean(value) do
    rendered = inspect(value, limit: :infinity, printable_limit: :infinity)
    for canary <- Map.values(@canaries), do: refute(rendered =~ canary)
  end

  defp assert_unavailable(result) do
    assert result == {:error, Error.new(:storage_unavailable, retryable?: true)}
    assert_clean(result)
  end

  defp effects(c) do
    Fixtures.with_owner(fn ->
      tables =
        Map.new(~w(audit.events core.outbox_events jobs.job_submissions), fn table ->
          {table,
           SafeSQL.query!(
             MigrationRepo,
             "SELECT to_jsonb(row) FROM #{table} row WHERE vault_id=$1",
             [c.source.vault_id]
           ).rows}
        end)

      Map.put(
        tables,
        "jobs.oban_jobs",
        SafeSQL.query!(
          MigrationRepo,
          "SELECT to_jsonb(job) FROM jobs.oban_jobs job WHERE args->>'vault_id'=$1",
          [uuid(c.source.vault_id)]
        ).rows
      )
    end)
  end

  defp body,
    do:
      @canaries.snippet <>
        " " <>
        @canaries.q <>
        " " <>
        String.duplicate("padding ", 30) <> @canaries.body

  defp note!(source) do
    row = %{resource_id: KnowledgeFixtures.uuid(), resource_version_id: KnowledgeFixtures.uuid()}

    Fixtures.with_owner(fn ->
      SafeSQL.query!(
        MigrationRepo,
        "INSERT INTO content.resources(id,vault_id,classification,kind,current_version_id,title) VALUES($1,$2,'private','note',$3,$4)",
        [row.resource_id, source.vault_id, row.resource_version_id, @canaries.title]
      )

      SafeSQL.query!(
        MigrationRepo,
        "INSERT INTO content.resource_versions(id,resource_id,vault_id,classification,revision) VALUES($1,$2,$3,'private',0)",
        [row.resource_version_id, row.resource_id, source.vault_id]
      )

      SafeSQL.query!(
        MigrationRepo,
        "INSERT INTO content.note_versions(resource_version_id,resource_id,vault_id,classification,title,markdown,created_by_principal_id,inserted_at) VALUES($1,$2,$3,'private',$4,$5,$6,CURRENT_TIMESTAMP)",
        [
          row.resource_version_id,
          row.resource_id,
          source.vault_id,
          @canaries.title,
          body(),
          source.principal_id
        ]
      )
    end)

    row
  end

  defp document!(source) do
    document =
      KnowledgeFixtures.document!(source, %{title: @canaries.title, media_type: "text/markdown"})

    locator = %{
      "version" => 1,
      "kind" => "markdown",
      "heading_path" => [@canaries.heading],
      "start_line" => 1,
      "end_line" => 1
    }

    assert {:ok, fragment} =
             DocumentFragment.new(%{
               resource_id: uuid(document.resource_id),
               resource_version_id: uuid(document.resource_version_id),
               owner_scope_id: uuid(source.vault_id),
               classification: :private,
               ordinal: 0,
               text: body(),
               locator: locator
             })

    Fixtures.with_owner(fn ->
      SafeSQL.query!(
        MigrationRepo,
        "SELECT set_config('singularity.principal_id',$1,true),set_config('singularity.vault_id',$2,true)",
        [uuid(source.principal_id), uuid(source.vault_id)]
      )

      SafeSQL.query!(
        MigrationRepo,
        "SELECT content.claim_document_extraction($1,0,$1,'plain',1)",
        [document.resource_version_id]
      )

      SafeSQL.query!(
        MigrationRepo,
        "SELECT content.complete_document_extraction($1,$1,1,$2,$3,'en')",
        [
          document.resource_version_id,
          [
            %{
              "id" => fragment.fragment_id,
              "ordinal" => 0,
              "text" => fragment.text,
              "digest" => Base.encode16(fragment.digest, case: :lower),
              "locator" => locator
            }
          ],
          fragment.digest
        ]
      )
    end)

    {document, fragment}
  end

  defp tag!(source, resources) do
    id = KnowledgeFixtures.uuid()

    Fixtures.with_owner(fn ->
      SafeSQL.query!(
        MigrationRepo,
        "INSERT INTO content.tags(id,vault_id,classification,display_value,normalized_key,created_by_principal_id,inserted_at) VALUES($1,$2,'private',$3,$3,$4,CURRENT_TIMESTAMP)",
        [id, source.vault_id, @canaries.tag, source.principal_id]
      )

      for resource <- resources do
        SafeSQL.query!(
          MigrationRepo,
          "INSERT INTO content.resource_tags(resource_id,tag_id,vault_id,classification,inserted_at) VALUES($1,$2,$3,'private',CURRENT_TIMESTAMP)",
          [resource.resource_id, id, source.vault_id]
        )
      end
    end)

    uuid(id)
  end

  defp project!(source, resources) do
    Fixtures.with_owner(fn ->
      for resource <- resources do
        SafeSQL.query!(
          MigrationRepo,
          "SELECT content.reconcile_search_resource_internal($1,$2)",
          [source.vault_id, resource.resource_id]
        )
      end
    end)
  end

  defp live_runtime!(source) do
    token = :crypto.strong_rand_bytes(32)

    Fixtures.with_owner(fn ->
      SafeSQL.query!(MigrationRepo, "UPDATE identity.sessions SET token_digest=$2 WHERE id=$1", [
        source.session_id,
        :crypto.hash(:sha256, token)
      ])

      SafeSQL.query!(MigrationRepo, "UPDATE core.vaults SET locked=false WHERE id=$1", [
        source.vault_id
      ])

      for name <- ["asset.read", "note.read"] do
        SafeSQL.query!(
          MigrationRepo,
          "INSERT INTO core.capabilities(id,name) VALUES($1,$2) ON CONFLICT(name) DO NOTHING",
          [KnowledgeFixtures.uuid(), name]
        )

        SafeSQL.query!(
          MigrationRepo,
          "INSERT INTO core.principal_capabilities(principal_id,vault_id,capability_id) SELECT $1,$2,id FROM core.capabilities WHERE name=$3 ON CONFLICT DO NOTHING",
          [source.principal_id, source.vault_id, name]
        )
      end
    end)

    supervisor = start_supervised!({KeyLeaseSupervisor, name: nil}, id: make_ref())

    custodian =
      start_supervised!(
        {KeyCustodian,
         %{
           authorization: CustodyReader,
           clock: CustodyReader,
           context: %{},
           idle_lock: fn _ -> :ok end,
           key_reader: CustodyReader,
           object_key_loader: CustodyReader,
           lease_supervisor: supervisor
         }},
        id: make_ref()
      )

    adapters = %{
      pre_auth: PreAuth,
      pre_auth_context: PreAuthRepo,
      custodian: KeyCustodian,
      custodian_context: custodian
    }

    resolver = %{resolve_session: fn token -> ResolveSession.run(adapters, token) end}
    opaque_id = Base.url_encode64(token, padding: false)
    assert {:ok, session} = Api.resolve_session(resolver, opaque_id)

    assert {:ok, pending} =
             KeyCustodian.prepare_unlock(
               custodian,
               session |> Map.from_struct() |> Map.put(:vault_key, :crypto.strong_rand_bytes(32))
             )

    assert :ok = KeyCustodian.activate_unlock(custodian, pending)
    assert {:ok, session} = Api.resolve_session(resolver, opaque_id)
    assert session.unlocked?
    assert session.principal_id == uuid(source.principal_id)
    assert session.vault_id == uuid(source.vault_id)

    assert {:ok, authorization} =
             AuthorizationDependencies.new(%{
               store: IdentityRepository,
               custodian: {KeyCustodian, custodian}
             })

    {%{
       authorization: authorization,
       authorization_lock: AuthorizationLock,
       operation_scope: OperationScope,
       request_repo: RequestRepo,
       scoped_repo: ScopedRepo,
       vault_lock: VaultLock
     }, session}
  end

  defp projection_envelope!(c) do
    %{rows: [[id, revision, principal_epoch, owner_epoch, correlation]]} =
      owner_query(
        """
        SELECT id,expected_entity_revision,principal_authorization_epoch,vault_authorization_epoch,correlation_id
        FROM core.outbox_events WHERE event_type='document.ready' AND vault_id=$1
          AND payload->>'resource_id'=$2
        """,
        [c.source.vault_id, uuid(c.document.resource_id)]
      )

    assert {:ok, envelope} =
             JobEnvelope.new(%{
               version: 1,
               job_id: uuid(id),
               job_type: "document_projection",
               idempotency_key: "document-projection:#{uuid(id)}",
               vault_id: uuid(c.source.vault_id),
               principal_id: uuid(c.source.principal_id),
               required_capability: "asset.read",
               principal_authorization_epoch: principal_epoch,
               vault_authorization_epoch: owner_epoch,
               classification: :private,
               correlation_id: uuid(correlation),
               causation_id: uuid(id),
               expected_entity_revision: revision,
               attempt: 0,
               payload: %{
                 "resource_id" => uuid(c.document.resource_id),
                 "resource_version_id" => uuid(c.document.resource_version_id)
               }
             })

    envelope
  end

  defp execute_job!(id, queue) do
    conf = Oban.config(Singularity.Oban)
    assert {:ok, meta} = Oban.Engines.Basic.init(conf, queue: queue, limit: 1)

    assert {:ok, {_meta, [%Oban.Job{id: ^id, queue: ^queue} = fetched]}} =
             Oban.Engines.Basic.fetch_jobs(conf, meta, %{})

    conf
    |> Oban.Queues.Executor.new(%{fetched | conf: conf}, ack: true)
    |> Oban.Queues.Executor.call()
  end

  defp install_env(key, value) do
    previous = Application.fetch_env(:singularity_storage, key)

    on_exit(fn ->
      case previous do
        {:ok, old} -> Application.put_env(:singularity_storage, key, old)
        :error -> Application.delete_env(:singularity_storage, key)
      end
    end)

    Application.put_env(:singularity_storage, key, value)
  end

  defp projection_count(c) do
    %{rows: [[count]]} =
      owner_query(
        "SELECT count(*) FROM content.search_entries WHERE vault_id=$1",
        [c.source.vault_id]
      )

    count
  end

  defp owner_query(statement, params),
    do: Fixtures.with_owner(fn -> SafeSQL.query!(MigrationRepo, statement, params) end)

  defp await_relation_wait(backend, oid, deadline) do
    %{rows: [[waiting]]} =
      SafeSQL.query!(
        MigrationRepo,
        "SELECT EXISTS(SELECT FROM pg_locks WHERE pid=$1 AND relation=$2::oid AND NOT granted)",
        [backend, oid]
      )

    cond do
      waiting -> true
      System.monotonic_time(:millisecond) >= deadline -> false
      true -> await_relation_wait(backend, oid, deadline)
    end
  end

  defp drain_task(task) do
    if Process.alive?(task.pid),
      do: Task.yield(task, 5_000) || Task.shutdown(task, :brutal_kill),
      else: Task.shutdown(task, :brutal_kill)
  end

  defp config(runtime),
    do: %{
      search_knowledge: fn session, params -> Search.run(runtime, session, params) end,
      resolve_search_source: fn session, selector -> Resolve.run(runtime, session, selector) end,
      rebuild_search: fn session, selector -> Rebuild.run(runtime, session, selector) end
    }

  defp context(c), do: struct!(SessionContext, Map.from_struct(c.session))
  defp document_selector(c), do: selector(c.document, :document, c.fragment.fragment_id)

  defp selector(row, kind, fragment),
    do: %{
      kind: kind,
      resource_id: uuid(row.resource_id),
      resource_version_id: uuid(row.resource_version_id),
      fragment_id: fragment
    }

  defp uuid(id), do: Ecto.UUID.load!(id)
end
