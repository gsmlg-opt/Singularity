defmodule Singularity.Runtime.KnowledgeExportPrivacyTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Singularity.Runtime.Api
  alias Singularity.Runtime.KnowledgeExportLiveFixture, as: Live

  alias Singularity.Storage.{
    DispatcherRepo,
    MigrationRepo,
    PreAuthRepo,
    RequestRepo,
    SafeSQL,
    WorkerRepo
  }

  @moduletag :integration
  @moduletag timeout: 180_000
  @authorization_event [:singularity, :authorization, :rls_denial]
  @job_events [
    [:oban, :job, :start],
    [:oban, :job, :stop],
    [:oban, :job, :exception],
    [:singularity, :job, :retry],
    [:singularity, :outbox, :dispatch],
    [:singularity, :integrity, :failure]
  ]

  test "real export diagnostics and opaque handles omit private data while public bytes remain usable" do
    rich_fixture(fn f, canaries, note ->
      {requester, monitor, token} = captured_export_requester(f)
      observer_token = f.observer.token

      try do
        assert_receive {:knowledge_export_barrier, ^observer_token, :native_piece, reader}, 60_000
        # This observation happens outside the requester's diagnostic callback.
        # No fixture SQL, content rendering or oracle runs during that callback.
        generating_modes = operation_modes(f.roots.artifact)
        send(reader, {:knowledge_export_continue, observer_token, :native_piece})

        assert_receive {^token, :export_capture, ^requester, result, surface}, 60_000
        assert {:ok, handle} = result
        owner = handle.owner
        owner_monitor = Process.monitor(owner)
        path = "notes/#{note.resource_id}--#{note.resource_version_id}.md"

        try do
          assert_diagnostics!(surface)
          assert_operation!(surface, :export, owner)
          assert_operation_controls!(surface, :export, owner)
          assert_private!(canaries, surface)
          assert_private_modes!(generating_modes)
          assert_private_modes!(operation_modes(f.roots.artifact))
          assert inspect(handle) == "#KnowledgeExport<opaque>"
          assert_private!(canaries, inspect(handle, limit: :infinity, printable_limit: :infinity))

          {page_result, page_surface} =
            capture_api(f, :page, %{}, fn config ->
              Api.knowledge_export_entries(config, f.session, handle, nil)
            end)

          assert {:ok, %{entries: entries}} = page_result
          assert entries != []
          assert_diagnostics!(page_surface)
          assert_operation!(page_surface, :page, owner, length(entries))
          assert_operation_controls!(page_surface, :page, owner, length(entries))
          assert_private!(canaries, page_surface)
          assert Enum.any?(entries, &(&1["path"] == path))

          {chunk_result, chunk_surface} =
            capture_api(f, :chunk, %{}, fn config ->
              Api.read_knowledge_export_chunk(config, f.session, handle, path, 0)
            end)

          assert {:ok, bytes} = chunk_result
          assert byte_size(bytes) > 0 and byte_size(bytes) <= 65_536
          assert String.contains?(bytes, canaries.body)
          assert_diagnostics!(chunk_surface)
          assert_operation!(chunk_surface, :chunk, owner, byte_size(bytes))
          assert_operation_controls!(chunk_surface, :chunk, owner, byte_size(bytes))
          assert_private!(canaries, chunk_surface)

          # Session DTOs intentionally expose caller identity. Only diagnostic
          # surfaces and the actual export Handle Inspect are secret boundaries.
          stale = %{
            f.session
            | principal_authorization_epoch: f.session.principal_authorization_epoch + 1
          }

          {denial, denial_surface} =
            capture_api(f, :stale, %{}, fn config ->
              Api.read_knowledge_export_chunk(config, stale, handle, path, 0)
            end)

          assert denial == {:error, :forbidden}
          assert_diagnostics!(denial_surface)
          assert_private!(canaries, denial)
          assert_private!(canaries, denial_surface)

          # These are real rejected request-field markers, not injected native
          # key bytes or invented persisted job payloads. The public API accepts
          # only include_tombstones and must not echo extra caller fields.
          for options <- [
                %{key_material: %{object_key: canaries.key_marker}},
                %{job_payload: %{job_id: canaries.job_marker, request_id: canaries.request}},
                %{include_tombstones: canaries.body}
              ] do
            {invalid, invalid_surface} =
              capture_api(f, :invalid, %{}, fn config ->
                Api.export_knowledge(config, f.session, options)
              end)

            assert invalid == {:error, :invalid}
            assert_diagnostics!(invalid_surface)
            assert_private!(canaries, invalid)
            assert_private!(canaries, invalid_surface)
          end

          {closed, close_surface} =
            capture_api(f, :close, %{}, fn config ->
              Api.close_knowledge_export(config, f.session, handle)
            end)

          assert closed == :ok
          assert_diagnostics!(close_surface)
          assert_operation!(close_surface, :close, owner)
          assert_operation_controls!(close_surface, :close, owner)
          assert_private!(canaries, close_surface)
          assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :normal}, 5_000
        after
          # This is emergency test teardown, never credited as the close witness.
          if Process.alive?(handle.owner),
            do: Api.close_knowledge_export(Live.export_config(f, %{}), f.session, handle)

          Process.demonitor(owner_monitor, [:flush])
        end

        stop_requester!(requester, monitor, token)
        Live.assert_quiescent!(f)

        # The complete offline copy is deliberately outside diagnostic capture:
        # its public byte results legitimately contain the content canaries.
        {offline_result, offline_surface} =
          capture_api(f, :offline_export, %{}, fn config ->
            Api.export_knowledge(config, f.session, %{})
          end)

        assert {:ok, offline_handle} = offline_result
        offline_config = Live.export_config(f, %{})

        try do
          assert_diagnostics!(offline_surface)
          assert_operation!(offline_surface, :export, offline_handle.owner)
          assert_private!(canaries, offline_surface)
          materialized = Live.materialize!(f, offline_config, offline_handle)
          assert_private_modes!([{materialized.root, mode_tree(materialized.root)}])
          assert File.read!(Path.join(materialized.root, path)) =~ canaries.body
        after
          if Process.alive?(offline_handle.owner),
            do: Api.close_knowledge_export(offline_config, f.session, offline_handle)
        end

        Live.assert_quiescent!(f)
        assert_denial_control!(f, canaries)
      after
        finish_requester!(requester, monitor, token, f.privacy_activity)
      end
    end)
  end

  test "genuine late Writer fault and native-generation expiry have sanitized diagnostic surfaces" do
    rich_fixture(fn f, canaries, _note ->
      {:ok, fault} = Agent.start_link(fn -> %{armed: false, successful: 0, injected: 0} end)
      {:ok, now} = Agent.start_link(fn -> 10_000 end)

      try do
        write = fn device, bytes ->
          inject? =
            Agent.get_and_update(fault, fn state ->
              if state.armed,
                do: {true, %{state | injected: state.injected + 1}},
                else: {false, state}
            end)

          if inject? do
            {:error, :enospc}
          else
            result = IO.binwrite(device, bytes)
            if result == :ok, do: Agent.update(fault, &%{&1 | successful: &1.successful + 1})
            result
          end
        end

        on_event = fn point, values ->
          if point == :native_piece and values.byte_size > 0,
            do: Agent.update(fault, &%{&1 | armed: true})
        end

        fault_controls = %{write: write, on_event: on_event}
        fault_config = Live.export_config(f, fault_controls)

        {fault_result, fault_surface} =
          capture_api(f, :fault, fault_controls, fn config ->
            Api.export_knowledge(config, f.session, %{})
          end)

        try do
          assert fault_result == {:error, :storage_unavailable}
          assert %{armed: true, successful: successful, injected: 1} = Agent.get(fault, & &1)
          assert successful > 0
          assert_diagnostics!(fault_surface)
          assert_operation!(fault_surface, :failure)
          assert_operation_controls!(fault_surface, :failure)
          assert_private!(canaries, fault_result)
          assert_private!(canaries, fault_surface)
        after
          close_unexpected!(f, fault_config, fault_result)
        end

        Live.assert_quiescent!(f)

        clock = fn -> Agent.get(now, & &1) end

        expire_after_native_piece = fn point, values ->
          if point == :native_piece and values.byte_size > 0,
            do: Agent.update(now, fn _ -> 910_001 end)
        end

        expiry_controls = %{clock: clock, on_event: expire_after_native_piece}
        expiry_config = Live.export_config(f, expiry_controls)

        {expiry_result, expiry_surface} =
          capture_api(f, :expiry, expiry_controls, fn config ->
            Api.export_knowledge(config, f.session, %{})
          end)

        try do
          assert expiry_result == {:error, :storage_unavailable}
          assert Agent.get(now, & &1) == 910_001
          assert_diagnostics!(expiry_surface)
          assert_operation!(expiry_surface, :failure)
          assert_operation_controls!(expiry_surface, :failure)
          assert_private!(canaries, expiry_result)
          assert_private!(canaries, expiry_surface)
        after
          close_unexpected!(f, expiry_config, expiry_result)
        end

        Live.assert_quiescent!(f)
        assert_denial_control!(f, canaries)
      after
        Agent.stop(now)
        Agent.stop(fault)
      end
    end)
  end

  defp rich_fixture(callback) do
    Live.with_fixture(fn fixture ->
      fixture = fixture |> Live.publish_sources!() |> Live.build_graph!()
      suffix = Ecto.UUID.generate()

      canaries = %{
        body: "EXPORT_PRIVATE_BODY_#{suffix}_资料🌍",
        title: "EXPORT_PRIVATE_TITLE_#{suffix}",
        label: "EXPORT_PRIVATE_LABEL_#{suffix}",
        key_marker: "REJECTED_REQUEST_KEY_MARKER_#{Ecto.UUID.generate()}",
        job_marker: "REJECTED_REQUEST_JOB_MARKER_#{Ecto.UUID.generate()}",
        request: Ecto.UUID.generate()
      }

      note =
        fixture.permission_scope.(%{purpose: :graph}, fn ->
          assert {:ok, note} =
                   Api.create_note(fixture.session, %{
                     mutation_id: canaries.request,
                     title: canaries.title,
                     markdown: canaries.body,
                     attachments: [
                       %{
                         attachment_id: Ecto.UUID.generate(),
                         target_resource_id: fixture.sources.markdown.document.resource_id,
                         target_resource_version_id:
                           fixture.sources.markdown.document.resource_version_id,
                         target_kind: :document,
                         role: :source,
                         label: canaries.label
                       }
                     ],
                     citations: []
                   })

          assert {:ok, _tag} =
                   Api.attach_tag(fixture.session, note.resource_id, %{name: canaries.label})

          note
        end)

      private_ids = [
        fixture.session.session_id,
        fixture.session.principal_id,
        fixture.session.vault_id,
        fixture.sources.plain.document.source.object_id,
        canaries.request
      ]

      private_values =
        private_ids ++
          Enum.map(private_ids, &Ecto.UUID.dump!/1) ++
          [
            fixture.credentials.password,
            fixture.roots.storage,
            fixture.roots.artifact,
            fixture.roots.backup
          ] ++
          Enum.flat_map(fixture.inputs, fn {_kind, input} ->
            if input.bytes == "", do: [], else: [input.bytes | input.fragments]
          end) ++ storage_references(fixture.roots.storage)

      {:ok, activity} = Agent.start_link(fn -> %{active: nil, events: []} end)

      try do
        callback.(
          Map.put(fixture, :privacy_activity, activity),
          Map.put(canaries, :private_values, private_values),
          note
        )
      after
        Agent.stop(activity)
      end
    end)
  end

  # Owner tasks retain their generation runtime. Its hook reads the fresh
  # context at actual invocation, including later authenticated close commits.
  # Old fixture-global observations are never relabelled or credited.
  defp capture_api(f, phase, controls, callback, token \\ make_ref()) do
    context = %{token: token, phase: phase, caller: self()}
    chained = Map.get(controls, :on_event, fn _, _ -> :ok end)

    observe = fn point, values ->
      emitter = self()

      Agent.update(f.privacy_activity, fn state ->
        case state.active do
          nil ->
            state

          active ->
            event =
              values
              |> Map.take([
                :count,
                :byte_size,
                :ordinal,
                :kind,
                :lease,
                :owner,
                :task,
                :companion
              ])
              |> Map.merge(active)
              |> Map.merge(%{point: point, pid: emitter})

            %{state | events: [event | state.events]}
        end
      end)

      chained.(point, values)
    end

    config = Live.export_config(f, Map.put(controls, :on_event, observe))

    Agent.update(f.privacy_activity, fn state ->
      assert state.active == nil
      %{state | active: context, events: []}
    end)

    try do
      {result, surface} = capture_runtime_call(context, fn -> callback.(config) end)
      events = Agent.get(f.privacy_activity, &Enum.reverse(&1.events))
      {result, Map.put(surface, :activity, events)}
    after
      Agent.update(f.privacy_activity, &%{&1 | active: nil, events: []})
    end
  end

  # All registered diagnostic events remain raw and unfiltered. Emitter/token
  # envelopes are separate private evidence, never added to production metadata.
  defp capture_runtime_call(context, callback) do
    owner = self()
    token = context.token
    handler = {__MODULE__, token}

    query_events =
      [RequestRepo, WorkerRepo, DispatcherRepo, PreAuthRepo, MigrationRepo]
      |> Enum.map(&(&1.config()[:telemetry_prefix] ++ [:query]))
      |> Enum.uniq()

    events = Enum.uniq(query_events ++ [@authorization_event | @job_events])
    registration = %{handler: handler, owner: owner, token: token, events: events}

    :ok =
      :telemetry.attach_many(
        handler,
        events,
        &__MODULE__.capture_telemetry/4,
        {owner, token}
      )

    try do
      before = registered_rows(handler)
      assert_registration!(before, registration)
      logs = capture_log(fn -> send(owner, {token, :api_result, callback.()}) end)
      after_call = registered_rows(handler)
      assert_registration!(after_call, registration)
      :telemetry.detach(handler)
      deliveries = drain_telemetry(token)

      receive do
        {^token, :api_result, result} ->
          {result,
           %{
             logs: logs,
             events: Enum.map(deliveries, & &1.raw),
             deliveries: deliveries,
             query_events: query_events,
             context: context,
             registration: registration,
             before: before,
             after: after_call
           }}
      after
        5_000 -> raise "export diagnostic callback did not return its result"
      end
    after
      :telemetry.detach(handler)
    end
  end

  def capture_telemetry(event, measurements, metadata, {owner, token}),
    do: send(owner, {token, :telemetry, self(), {event, measurements, metadata}})

  defp drain_telemetry(token, events \\ []) do
    receive do
      {^token, :telemetry, emitter, raw} ->
        drain_telemetry(token, [%{token: token, emitter: emitter, raw: raw} | events])
    after
      0 -> Enum.reverse(events)
    end
  end

  defp assert_diagnostics!(surface) do
    assert_registration!(surface.before, surface.registration)
    assert_registration!(surface.after, surface.registration)
    count = Enum.count(surface.events, fn {event, _, _} -> event in surface.query_events end)
    assert count == 0

    IO.puts(
      "live_export_privacy_capture query_events=#{count} total_events=#{length(surface.events)}"
    )
  end

  defp registered_rows(handler) do
    Enum.filter(:telemetry.list_handlers([]), &(&1.id == handler))
  end

  defp assert_registration!(rows, expected) do
    required =
      Enum.map(expected.events, fn event ->
        %{
          id: expected.handler,
          event_name: event,
          function: &__MODULE__.capture_telemetry/4,
          config: {expected.owner, expected.token}
        }
      end)

    assert Enum.sort_by(rows, & &1.event_name) == Enum.sort_by(required, & &1.event_name),
           "diagnostic capture registration differs from its exact owned event set"

    :ok
  end

  defp assert_registration_controls!(surface) do
    positive = surface.before
    expected = surface.registration
    assert_registration!(positive, expected)
    [first | rest] = positive

    for mutant <- [
          rest,
          [first | positive],
          [%{first | event_name: [:wrong_event]} | rest],
          [%{first | function: &:erlang.send/2} | rest],
          [%{first | config: {self(), make_ref()}} | rest]
        ] do
      assert_registration!(positive, expected)
      assert_raise ExUnit.AssertionError, fn -> assert_registration!(mutant, expected) end
    end

    token = make_ref()
    handler = {__MODULE__, token}
    sacrificial = %{expected | handler: handler, owner: self(), token: token}

    :ok =
      :telemetry.attach_many(
        handler,
        expected.events,
        &__MODULE__.capture_telemetry/4,
        {self(), token}
      )

    try do
      assert_registration!(registered_rows(handler), sacrificial)
      :ok = :telemetry.detach(handler)
      actual_detached = registered_rows(handler)
      assert actual_detached == []

      assert_raise ExUnit.AssertionError, fn ->
        assert_registration!(actual_detached, sacrificial)
      end
    after
      :telemetry.detach(handler)
    end
  end

  defp assert_denial_control!(f, canaries) do
    assert_permission_baseline!(f)

    try do
      context = %{token: make_ref(), phase: :denial_control, caller: self()}

      {result, surface} =
        capture_runtime_call(context, fn ->
          SafeSQL.query(
            WorkerRepo,
            "SELECT state FROM content.document_import_receipts WHERE state=$1",
            [canaries.title]
          )
        end)

      assert_private!(canaries, surface)
      assert_private!(canaries, result)
      # ExUnit sees only this boolean, never inspected Postgrex arguments.
      real_denial? =
        match?({:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}}, result)

      assert real_denial?,
             "separate real worker denial control did not return PostgreSQL 42501"

      assert_diagnostics!(surface)
      assert_denial_delivery!(surface.deliveries, context)
      assert_registration_controls!(surface)

      [delivery] =
        Enum.filter(surface.deliveries, fn row ->
          elem(row.raw, 0) == @authorization_event
        end)

      for mutant <- [
            [],
            [delivery, delivery],
            [%{delivery | token: make_ref()}],
            [%{delivery | emitter: f.owner}],
            [%{delivery | raw: {[:wrong_event], %{count: 1}, %{repo: :worker}}}],
            [%{delivery | raw: {@authorization_event, %{count: 0}, %{repo: :worker}}}],
            [%{delivery | raw: {@authorization_event, %{count: 1}, %{repo: :request}}}]
          ] do
        assert_denial_delivery!(surface.deliveries, context)
        assert_raise ExUnit.AssertionError, fn -> assert_denial_delivery!(mutant, context) end
      end

      assert_raise ExUnit.AssertionError, fn ->
        assert_denial_delivery!(surface.deliveries, %{context | phase: :export})
      end

      :ok
    after
      assert_permission_baseline!(f)
    end
  end

  defp assert_permission_baseline!(f) do
    assert f.permission_snapshot.() == f.permission_baseline
    {repo, database} = Map.fetch!(f.repositories, MigrationRepo)
    assert Process.whereis(MigrationRepo) == repo
    assert f.permission_baseline.migration_repo == repo
    assert f.permission_baseline.database == database
    assert f.destination.database == database

    receipt_acl =
      Map.fetch!(f.permission_baseline.acls, {"TABLE", "content.document_import_receipts"})

    # Use the exact catalog relation's OID: the baseline migration login has
    # no content schema USAGE for resolving the relation through a text name.
    result =
      SafeSQL.query(
        MigrationRepo,
        """
        SELECT current_database(), c.relacl::text,
               pg_catalog.has_table_privilege('singularity_worker', c.oid, 'SELECT')
        FROM pg_catalog.pg_class AS c
        JOIN pg_catalog.pg_namespace AS n ON n.oid = c.relnamespace
        WHERE n.nspname = 'content'
          AND c.relname = 'document_import_receipts'
          AND c.relkind = 'r'
        """,
        []
      )

    baseline_denied? = match?({:ok, %{rows: [[^database, ^receipt_acl, false]]}}, result)

    assert baseline_denied?,
           "owned receipt relation lacks its exact baseline ACL and denied worker SELECT"
  end

  defp assert_denial_delivery!(deliveries, context) do
    assert context.phase == :denial_control
    actual = Enum.filter(deliveries, fn row -> elem(row.raw, 0) == @authorization_event end)

    exact_delivery? =
      actual == [
        %{
          token: context.token,
          emitter: context.caller,
          raw: {@authorization_event, %{count: 1}, %{repo: :worker}}
        }
      ]

    assert exact_delivery?,
           "separate denial control lacks its exact real emitter/token/count delivery"

    :ok
  end

  defp assert_operation!(surface, kind, owner \\ nil, expected_size \\ nil) do
    phases =
      case kind do
        :export -> [:export, :offline_export]
        :failure -> [:fault, :expiry]
        other -> [other]
      end

    assert surface.context.phase in phases
    assert surface.activity != []
    context = surface.context

    assert Enum.all?(surface.activity, fn row ->
             row.token == context.token and row.phase == context.phase and
               row.caller == context.caller and is_pid(row.pid)
           end),
           "private operation witness has another token/phase/caller"

    case kind do
      kind when kind in [:export, :failure] ->
        captures = Enum.filter(surface.activity, &(&1.point == :capture_committed))
        assert [capture] = captures
        assert capture.pid != context.caller

        assert Enum.any?(surface.activity, fn row ->
                 row.point == :task_first_clock and row.pid == capture.pid and
                   row.task == capture.pid
               end),
               "capture emitter lacks its actual owned task clock witness"

        if kind == :export, do: assert(capture.pid == owner)
        leases = Enum.filter(surface.activity, &(&1.point == :native_lease))
        admissions = Enum.filter(surface.activity, &(&1.point == :before_native_lease))
        clocks = Enum.filter(surface.activity, &(&1.point == :task_first_clock))
        pieces = Enum.filter(surface.activity, &(&1.point == :native_piece))
        assert Enum.any?(pieces, &(&1.byte_size > 0))

        # Acquisition executes in the companion; native reads execute in the
        # capture owner. Associate their real roles by exact lease and kind.
        assert Enum.all?(pieces, fn piece ->
                 maximum = if piece.kind == :document, do: 4_194_304, else: 65_536

                 piece.kind in [:asset, :document] and piece.byte_size >= 0 and
                   piece.byte_size <= maximum and piece.pid == capture.pid and
                   Enum.any?(leases, fn lease ->
                     lease.lease == piece.lease and lease.kind == piece.kind and
                       lease.pid == lease.companion and lease.pid != capture.pid and
                       Enum.any?(admissions, fn admission ->
                         admission.pid == lease.pid and admission.companion == lease.pid and
                           admission.kind == lease.kind
                       end) and
                       Enum.any?(clocks, fn clock ->
                         clock.pid == lease.pid and clock.task == lease.pid
                       end)
                   end)
               end),
               "native activity lacks real positive bounded bytes and its actual issued lease"

        if kind == :export do
          assert_owner_commit!(surface.activity, owner)
          completed = Enum.filter(surface.activity, &(&1.point == :completed))
          assert [%{pid: caller, owner: ^owner}] = completed
          assert caller == context.caller
        end

      kind when kind in [:page, :chunk] ->
        point = if kind == :page, do: :public_page, else: :public_chunk
        field = if kind == :page, do: :count, else: :byte_size
        maximum = if kind == :page, do: 500, else: 65_536
        public = Enum.filter(surface.activity, &(&1.point == point))
        assert [observation] = public
        assert observation.pid == context.caller
        actual_size = Map.fetch!(observation, field)
        assert actual_size > 0 and actual_size <= maximum
        assert actual_size == expected_size
        assert_owner_commit!(surface.activity, owner)

      :close ->
        assert_owner_commit!(surface.activity, owner)
    end

    :ok
  end

  defp assert_owner_commit!(activity, owner) do
    commits = Enum.filter(activity, &(&1.point == :completion_committed and &1.pid == owner))
    assert [_] = commits
    :ok
  end

  defp assert_operation_controls!(surface, kind, owner \\ nil, expected_size \\ nil) do
    assert_operation!(surface, kind, owner, expected_size)
    [first | rest] = surface.activity
    wrong_caller = Process.whereis(MigrationRepo)
    assert is_pid(wrong_caller) and wrong_caller != surface.context.caller

    mutations = [
      [],
      [%{first | token: make_ref()} | rest],
      [%{first | phase: :denial_control} | rest],
      [%{first | caller: wrong_caller} | rest]
    ]

    required =
      case kind do
        kind when kind in [:export, :failure] -> :capture_committed
        :page -> :public_page
        :chunk -> :public_chunk
        :close -> :completion_committed
      end

    required_row = Enum.find(surface.activity, &(&1.point == required))

    wrong_point =
      Enum.map(surface.activity, fn row ->
        if row.point == required, do: %{row | point: :wrong_point}, else: row
      end)

    wrong_emitter =
      Enum.map(surface.activity, fn row ->
        if row.point == required, do: %{row | pid: wrong_caller}, else: row
      end)

    mutations = [
      Enum.reject(surface.activity, &(&1.point == required)),
      [required_row | surface.activity],
      wrong_point,
      wrong_emitter | mutations
    ]

    mutations =
      if kind in [:export, :failure, :page, :chunk] do
        field = if kind == :page, do: :count, else: :byte_size

        positive =
          if kind == :page,
            do: :public_page,
            else: if(kind == :chunk, do: :public_chunk, else: :native_piece)

        zero =
          Enum.map(surface.activity, fn row ->
            if row.point == positive, do: Map.put(row, field, 0), else: row
          end)

        [zero | mutations]
      else
        mutations
      end

    mutations =
      if kind in [:export, :failure] do
        native_mutations =
          for {point, field, value} <- [
                {:native_lease, :lease, wrong_caller},
                {:native_lease, :kind, :wrong_kind},
                {:native_piece, :pid, wrong_caller},
                {:native_lease, :companion, wrong_caller}
              ] do
            Enum.map(surface.activity, fn row ->
              if row.point == point, do: Map.put(row, field, value), else: row
            end)
          end

        [Enum.reject(surface.activity, &(&1.point == :native_lease)) | native_mutations] ++
          mutations
      else
        mutations
      end

    for activity <- mutations do
      assert_operation!(surface, kind, owner, expected_size)

      assert_raise ExUnit.AssertionError, fn ->
        assert_operation!(%{surface | activity: activity}, kind, owner, expected_size)
      end
    end
  end

  defp assert_private!(canaries, surface) do
    rendered = inspect(surface, limit: :infinity, printable_limit: :infinity)
    values = Map.values(Map.delete(canaries, :private_values)) ++ canaries.private_values

    for value <- values,
        encoded <- [
          value,
          inspect(value, limit: :infinity, printable_limit: :infinity),
          Base.encode16(value),
          Base.encode16(value, case: :lower),
          Base.encode64(value)
        ] do
      # Keep failure output free of the very canary being protected.
      refute String.contains?(rendered, encoded),
             "private canary appeared on an export diagnostic surface"

      if is_binary(surface) do
        refute String.contains?(surface, encoded),
               "private canary appeared in raw export diagnostics"
      end
    end
  end

  defp captured_export_requester(f) do
    parent = self()
    token = make_ref()

    {requester, monitor} =
      spawn_monitor(fn ->
        receive do
          {^token, :begin} -> :ok
        end

        {result, surface} =
          capture_api(
            f,
            :export,
            %{barriers: [:native_piece]},
            fn config ->
              Api.export_knowledge(config, f.session, %{})
            end,
            token
          )

        send(parent, {token, :export_capture, self(), result, surface})

        receive do
          {^token, :finish} -> :ok
        after
          60_000 -> exit(:privacy_requester_not_released)
        end
      end)

    # The test parent knows the exact handler before the requester may attach it.
    # Its cleanup also runs when :kill bypasses the requester's try/after.
    on_exit(fn -> finish_requester!(requester, monitor, token, f.privacy_activity) end)
    send(requester, {token, :begin})
    {requester, monitor, token}
  end

  defp stop_requester!(requester, monitor, token) do
    send(requester, {token, :finish})
    assert_receive {:DOWN, ^monitor, :process, ^requester, :normal}, 5_000
  end

  defp finish_requester!(requester, monitor, token, activity) do
    try do
      if Process.alive?(requester) do
        send(requester, {token, :finish})

        receive do
          {:DOWN, ^monitor, :process, ^requester, _} -> :ok
        after
          5_000 ->
            # Only this test's exact requester may be stopped in emergency teardown.
            cleanup_monitor = Process.monitor(requester)
            Process.exit(requester, :kill)
            assert_receive {:DOWN, ^cleanup_monitor, :process, ^requester, _}, 5_000
        end
      end
    after
      :telemetry.detach({__MODULE__, token})

      if Process.alive?(activity) do
        Agent.update(activity, fn state ->
          case state.active do
            %{token: ^token} -> %{state | active: nil, events: []}
            _ -> state
          end
        end)
      end
    end
  end

  defp close_unexpected!(f, config, {:ok, handle}),
    do: assert(:ok = Api.close_knowledge_export(config, f.session, handle))

  defp close_unexpected!(_f, _config, _result), do: :ok

  defp operation_modes(root) do
    root
    |> File.ls!()
    |> Enum.reject(&(&1 in ["foreign-neighbor", "malformed-neighbor"]))
    |> Enum.map(fn name -> {name, mode_tree(Path.join(root, name))} end)
  end

  defp mode_tree(root), do: mode_tree(root, "")

  defp mode_tree(root, relative) do
    path = Path.join(root, relative)
    stat = File.lstat!(path)
    row = {relative, stat.type, Bitwise.band(stat.mode, 0o7777)}

    if stat.type == :directory do
      [row | Enum.flat_map(File.ls!(path), &mode_tree(root, Path.join(relative, &1)))]
    else
      [row]
    end
  end

  defp assert_private_modes!(operations) do
    assert [{_operation, rows}] = operations
    assert Enum.any?(rows, fn {_, type, _} -> type == :regular end)

    for {_path, type, mode} <- rows do
      case type do
        :directory -> assert mode == 0o700
        :regular -> assert mode == 0o600
        _ -> flunk("export contains a non-regular private filesystem entry")
      end
    end
  end

  defp storage_references(root), do: storage_references(root, "")

  defp storage_references(root, relative) do
    root
    |> Path.join(relative)
    |> File.ls!()
    |> Enum.flat_map(fn name ->
      path = Path.join(relative, name)

      case File.lstat!(Path.join(root, path)).type do
        :directory -> storage_references(root, path)
        :regular -> [path, Path.join(root, path)]
        _ -> flunk("native storage reference is not a regular file")
      end
    end)
  end
end
