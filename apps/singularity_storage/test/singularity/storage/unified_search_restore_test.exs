defmodule Singularity.Storage.UnifiedSearchRestoreTest do
  use Singularity.Storage.DataCase, async: false

  @moduletag :integration

  alias Singularity.Core.Error
  alias Singularity.Storage.Backup.{Exporter, IntegrityAudit}
  alias Singularity.Storage.{Fixtures, KnowledgeFixtures, MigrationRepo, NoteFixtures, ScopedRepo}

  test "restore-owned rebuild reconstructs exact current Note entries without live session authority" do
    %{one: owner, two: other_owner} = Fixtures.two_vaults!()
    live = NoteFixtures.note_with_conflict_in_context!(owner)
    tombstoned = NoteFixtures.note_with_conflict_in_context!(owner)
    foreign = NoteFixtures.note_with_conflict_in_context!(other_owner)

    {canonical_before, foreign_before} =
      Fixtures.with_owner(fn ->
        for note <- [tombstoned, foreign] do
          assert %{rows: [[1]]} =
                   query!(
                     MigrationRepo,
                     "SELECT content.reconcile_search_resource_internal($1,$2)",
                     [uuid(note.vault_id), uuid(note.resource_id)]
                   )
        end

        query!(MigrationRepo, "UPDATE content.resources SET deleted_at=now() WHERE id=$1", [
          uuid(tombstoned.resource_id)
        ])

        {canonical_rows(live.vault_id), search_rows(foreign.vault_id)}
      end)

    binding = %{manifest_id: Ecto.UUID.generate(), vault_id: live.vault_id}

    assert {:ok, first} =
             Fixtures.with_owner(fn ->
               assert_no_session_context!()
               IntegrityAudit.rebuild(MigrationRepo, binding)
             end)

    assert first.projection == "postgres_metadata_v1"
    assert first.document_count == 1
    assert <<_::binary-size(32)>> = first.result_sha256

    rebuilt =
      Fixtures.with_owner(fn ->
        assert canonical_rows(live.vault_id) == canonical_before
        assert search_rows(foreign.vault_id) == foreign_before

        assert [
                 [
                   entry_id,
                   "note",
                   resource_id,
                   version_id,
                   nil,
                   0,
                   "Accepted fixture note",
                   "# Accepted fixture note",
                   %{"kind" => "markdown", "version" => 1, "heading_path" => []},
                   inserted_at
                 ]
               ] = rows = search_rows(live.vault_id)

        assert entry_id == "note:" <> live.canonical_version_id
        assert resource_id == live.resource_id
        assert version_id == live.canonical_version_id

        assert %{rows: [[^inserted_at]]} =
                 query!(
                   MigrationRepo,
                   "SELECT inserted_at FROM content.resource_versions WHERE id=$1",
                   [
                     uuid(live.canonical_version_id)
                   ]
                 )

        rows
      end)

    assert {:ok, ^first} =
             Fixtures.with_owner(fn ->
               assert_no_session_context!()
               IntegrityAudit.rebuild(MigrationRepo, binding)
             end)

    Fixtures.with_owner(fn ->
      assert search_rows(live.vault_id) == rebuilt
      assert canonical_rows(live.vault_id) == canonical_before
      assert search_rows(foreign.vault_id) == foreign_before
    end)
  end

  for kind <- [:document, :tagged_note] do
    @kind kind

    test "legacy backup rejects live and tombstoned #{@kind} canonical rows" do
      source = KnowledgeFixtures.source!()

      Fixtures.with_owner(fn ->
        query!(
          MigrationRepo,
          "INSERT INTO core.capabilities (id,name) VALUES ($1,'backup.create') ON CONFLICT (name) DO NOTHING",
          [KnowledgeFixtures.uuid()]
        )

        query!(
          MigrationRepo,
          "INSERT INTO core.principal_capabilities (principal_id,vault_id,capability_id) SELECT $1,$2,id FROM core.capabilities WHERE name='backup.create'",
          [source.principal_id, source.vault_id]
        )
      end)

      assert {:ok, _supported_cut} = backup_cut(source)
      resource = unsupported_resource!(@kind, source)

      assert {:error, %Error{code: :backup_unsupported, message: nil, details: %{}}} =
               backup_cut(source)

      Fixtures.with_owner(fn ->
        query!(MigrationRepo, "UPDATE content.resources SET deleted_at=now() WHERE id=$1", [
          resource.resource_id
        ])
      end)

      assert {:error, %Error{code: :backup_unsupported, message: nil, details: %{}}} =
               backup_cut(source)
    end
  end

  defp backup_cut(source) do
    owner = Ecto.UUID.load!(source.vault_id)

    ScopedRepo.transact(
      WorkerRepo,
      %{principal_id: Ecto.UUID.load!(source.principal_id), vault_id: owner},
      [isolation: :repeatable_read],
      fn repo -> Exporter.snapshot_cut(repo, owner, 2) end
    )
  end

  defp unsupported_resource!(:document, source), do: KnowledgeFixtures.document!(source)

  defp unsupported_resource!(:tagged_note, source) do
    note = KnowledgeFixtures.note!(source)
    tag_id = KnowledgeFixtures.uuid()

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "INSERT INTO content.tags (id,vault_id,classification,display_value,normalized_key,created_by_principal_id,inserted_at) VALUES ($1,$2,'private','restore guard tag','restore guard tag',$3,CURRENT_TIMESTAMP)",
        [tag_id, source.vault_id, source.principal_id]
      )

      query!(
        MigrationRepo,
        "INSERT INTO content.resource_tags (resource_id,tag_id,vault_id,classification,inserted_at) VALUES ($1,$2,$3,'private',CURRENT_TIMESTAMP)",
        [note.resource_id, tag_id, source.vault_id]
      )
    end)

    note
  end

  defp assert_no_session_context! do
    assert %{rows: [[nil, nil]]} =
             query!(
               MigrationRepo,
               "SELECT NULLIF(current_setting('singularity.principal_id',true),''), NULLIF(current_setting('singularity.vault_id',true),'')",
               []
             )
  end

  defp search_rows(owner) do
    %{rows: rows} =
      query!(
        MigrationRepo,
        """
        SELECT entry_id,kind,resource_id::text,resource_version_id::text,
               fragment_id,ordinal,title,body,locator,source_inserted_at
        FROM content.search_entries WHERE vault_id=$1 ORDER BY entry_id
        """,
        [uuid(owner)]
      )

    rows
  end

  defp canonical_rows(owner) do
    for {table, order} <- [
          {"resources", "id"},
          {"resource_versions", "id"},
          {"note_versions", "resource_version_id"},
          {"note_conflicts", "id"}
        ] do
      %{rows: rows} =
        query!(
          MigrationRepo,
          "SELECT row_to_json(canonical)::text FROM content.#{table} AS canonical WHERE vault_id=$1 ORDER BY #{order}",
          [uuid(owner)]
        )

      {table, rows}
    end
  end

  defp uuid(value), do: Ecto.UUID.dump!(value)
end

defmodule Singularity.Storage.UnifiedSearchRestoreV3Test do
  use ExUnit.Case, async: false

  @moduletag :integration
  alias Singularity.Core.Error
  alias Singularity.Storage.{MigrationRepo, SafeSQL}

  alias Singularity.Storage.Backup.{
    IntegrityAudit,
    KnowledgeBackupFixtures,
    KnowledgeIntegrityAudit
  }

  @time ~U[2026-10-11 00:00:00.000000Z]
  @ids ~w(account_id principal_id vault_id session_id live_note_id deleted_note_id
    initial_note_version_id canonical_note_version_id competing_note_version_id
    merge_note_version_id open_competing_note_version_id deleted_note_version_id
    resolved_conflict_id open_conflict_id ready_document_id ready_old_version_id
    ready_current_version_id deleted_document_id deleted_document_version_id
    pending_document_id pending_version_id extracting_document_id extracting_version_id
    failed_document_id failed_version_id unsupported_document_id unsupported_version_id
    attachment_id citation_id deleted_attachment_id deleted_citation_id tag_id
    relationship_id pdf_object_id empty_object_id plain_object_id unicode_object_id
    markdown_object_id)a
       |> Enum.with_index(1)
       |> Map.new(fn {key, n} ->
         {key, "76000000-0000-4000-8000-" <> String.pad_leading(Integer.to_string(n), 12, "0")}
       end)
  @originals %{
    pdf: "%PDF-1.7\n" <> <<0, 1, 255>> <> "\n%%EOF\n",
    pdf_duplicate: "%PDF-1.7\n" <> <<0, 1, 255>> <> "\n%%EOF\n",
    empty: "",
    plain: "plain original\r\nsecond line\n",
    unicode: "界🙂 café\n",
    markdown: "# Original Markdown\n"
  }

  # Independent framed identity oracle: no fragment/projection implementation call.
  frame = fn value -> <<byte_size(value)::unsigned-big-64, value::binary>> end

  @fragments Enum.with_index(["first\n", "界🙂"])
             |> Enum.map(fn {text, ordinal} ->
               locator =
                 Enum.map(["1", "pdf", Integer.to_string(ordinal + 1), "", ""], frame)
                 |> IO.iodata_to_binary()

               :crypto.hash(:sha256, [
                 "singularity:document-fragment:v1",
                 <<0>>,
                 Enum.map(
                   [
                     @ids.ready_current_version_id,
                     locator,
                     Integer.to_string(ordinal),
                     :crypto.hash(:sha256, text)
                   ],
                   frame
                 )
               ])
               |> Base.encode16(case: :lower)
             end)

  defmodule TraceSQL do
    alias Ecto.Adapters.Postgres.Connection, as: Native
    alias Singularity.Storage.UnifiedSearchRestoreV3Test, as: Owner

    for {name, arity} <- Native.__info__(:functions), {name, arity} != {:query, 4} do
      args = Macro.generate_arguments(arity, __MODULE__)

      def unquote(name)(unquote_splicing(args)),
        do: apply(Native, unquote(name), [unquote_splicing(args)])
    end

    def query(connection, statement, params, options) do
      config = Process.get({Owner, :trace_config})

      selected? =
        config != nil and
          String.replace(IO.iodata_to_binary(statement), ~r/\s+/, "") ==
            "SELECTcontent.reconcile_search_resource_internal($1,$2)" and
          params == [Ecto.UUID.dump!(config.owner), Ecto.UUID.dump!(config.resource)]

      if selected? do
        before = Owner.native_witness(config)
        result = Native.query(connection, statement, params, options)
        after_query = if match?({:ok, _}, result), do: Owner.native_witness(config), else: nil

        Process.put({Owner, :trace_events}, [
          %{before: before, native_result: result, after: after_query}
          | Process.get({Owner, :trace_events}, [])
        ])

        case {config.fault, result} do
          {{:injected_contract_fault, rows}, {:ok, native}} -> {:ok, %{native | rows: rows}}
          _ -> result
        end
      else
        Native.query(connection, statement, params, options)
      end
    end
  end

  defmodule NativeRepo do
    alias Singularity.Storage.MigrationRepo
    alias Singularity.Storage.UnifiedSearchRestoreV3Test, as: Owner
    alias Owner.TraceSQL

    @special [
      :__adapter__,
      :get_dynamic_repo,
      :transaction,
      :checkout,
      :rollback,
      :in_transaction?
    ]
    for {name, arity} <- MigrationRepo.__info__(:functions), name not in @special do
      args = Macro.generate_arguments(arity, __MODULE__)

      def unquote(name)(unquote_splicing(args)),
        do: apply(MigrationRepo, unquote(name), [unquote_splicing(args)])
    end

    def __adapter__, do: MigrationRepo.__adapter__()
    def get_dynamic_repo, do: MigrationRepo.get_dynamic_repo()
    def in_transaction?, do: MigrationRepo.in_transaction?()
    def rollback(reason), do: MigrationRepo.rollback(reason)
    def checkout(callback, options \\ []), do: MigrationRepo.checkout(callback, options)

    def transaction(callback, options \\ []) do
      if MigrationRepo.in_transaction?() do
        MigrationRepo.transaction(callback, options)
      else
        {:ok, address} = Agent.start_link(fn -> nil end, name: __MODULE__)

        try do
          native = Ecto.Adapter.lookup_meta(MigrationRepo.get_dynamic_repo())
          true = native.sql == Ecto.Adapters.Postgres.Connection
          aliased = %{native | sql: TraceSQL}
          :ok = Ecto.Repo.Registry.associate(address, __MODULE__, aliased)

          true =
            Map.delete(Ecto.Adapter.lookup_meta(__MODULE__), :sql) == Map.delete(native, :sql)

          MigrationRepo.checkout(fn ->
            result = MigrationRepo.transaction(callback, options)
            Process.put({Owner, :exit_witness}, Owner.connection_witness())
            result
          end)
        after
          Agent.stop(address)
          Owner.await_registry_cleanup(address)
        end
      end
    end
  end

  test "V3 rebuild retains two Asset rows and all eleven columns of both current fragments" do
    with_fixture(fn fixture ->
      before = snapshot(fixture)
      expected = expected_evidence(fixture)
      binding = restore_binding(fixture)

      assert {:ok, %IntegrityAudit.SearchSummary{} = first} =
               KnowledgeIntegrityAudit.rebuild(MigrationRepo, binding)

      assert first.projection == "postgres_metadata_v1"
      assert first.document_count == 5
      assert first.result_sha256 == evidence_digest(expected)
      assert evidence(fixture.owner.vault_id) == expected
      assert snapshot(fixture).canonical == before.canonical
      assert snapshot(fixture).foreign == before.foreign

      assert {:ok, ^first} = KnowledgeIntegrityAudit.rebuild(MigrationRepo, binding)
      assert evidence(fixture.owner.vault_id) == expected
      assert snapshot(fixture).canonical == before.canonical
      assert snapshot(fixture).foreign == before.foreign

      [left, right, note] = expected.knowledge
      assert Enum.at(left, 4) == Enum.at(@fragments, 0)
      assert Enum.at(right, 4) == Enum.at(@fragments, 1)
      assert Enum.at(note, 4) == nil
      assert [_, _] = expected.assets

      assert %{rows: [[1]]} =
               owner(fn ->
                 q(
                   "SELECT count(*) FROM content.note_search_documents WHERE vault_id=$1",
                   [dump(fixture.owner.vault_id)]
                 )
               end)

      # Every serialized field is covered by the actual returned native digest.
      for key <- [:assets, :knowledge],
          {row, row_index} <- Enum.with_index(expected[key]),
          {_cell, column} <- Enum.with_index(row) do
        changed =
          update_in(expected, [key], fn rows ->
            List.update_at(rows, row_index, &List.replace_at(&1, column, {:changed, column}))
          end)

        refute evidence_digest(changed) == first.result_sha256
      end

      extra = %{expected | knowledge: expected.knowledge ++ [note]}
      refute evidence_digest(extra) == first.result_sha256
      refute first.document_count == length(extra.assets) + length(extra.knowledge)
    end)
  end

  test "V3 native empty and single Note summaries match independent literal ETF vectors" do
    KnowledgeBackupFixtures.with_destination(:current, fn _destination ->
      empty_owner = foreign_id(101)
      seed_owner(empty_owner, foreign_id(102))
      empty_binding = %{manifest_id: Ecto.UUID.generate(), vault_id: empty_owner}
      assert {:ok, empty} = KnowledgeIntegrityAudit.rebuild(MigrationRepo, empty_binding)
      assert empty.document_count == 0

      assert Base.encode16(empty.result_sha256, case: :lower) ==
               "4a29cf8e8bc7cc6ed0f147e2b94bcdee7a1dd0eadf55971d702f0f00e92331c6"

      assert Base.encode16(
               :erlang.term_to_binary(
                 %{assets: [], knowledge: []},
                 [:deterministic, {:minor_version, 2}]
               ),
               case: :lower
             ) ==
               "83740000000277066173736574736a77096b6e6f776c656467656a"

      resource = "00000000-0000-4000-8000-000000000001"
      version = "00000000-0000-4000-8000-000000000002"

      seed_note(
        empty_owner,
        foreign_id(102),
        resource,
        version,
        "Alpha",
        "Beta",
        ~U[2026-01-01 00:00:00.000000Z]
      )

      assert {:ok, single} = KnowledgeIntegrityAudit.rebuild(MigrationRepo, empty_binding)

      expected = %{
        assets: [],
        knowledge: [
          [
            "note:" <> version,
            "note",
            resource,
            version,
            nil,
            0,
            "Alpha",
            "Beta",
            %{"version" => 1, "kind" => "markdown", "heading_path" => []},
            "2026-01-01T00:00:00.000000Z",
            "'alpha':1A 'beta':2"
          ]
        ]
      }

      assert evidence(empty_owner) == expected
      assert single.document_count == 1

      assert Base.encode16(single.result_sha256, case: :lower) ==
               "83571fc40de7553cbf9504066d3a05bb1d73de1543d06f37fdd6ee2d19f2d0b0"

      assert {:ok, ^single} = KnowledgeIntegrityAudit.rebuild(MigrationRepo, empty_binding)
    end)
  end

  test "V3 uses one native repeatable-read owner connection and cleans role and GUCs" do
    with_fixture(fn fixture ->
      {result, events, exit} =
        traced(fixture, nil, fn ->
          KnowledgeIntegrityAudit.rebuild(NativeRepo, restore_binding(fixture))
        end)

      assert {:ok, summary} = result
      assert summary.result_sha256 == evidence_digest(expected_evidence(fixture))

      assert [%{before: before, native_result: {:ok, %{rows: [[2]]}}, after: after_query}] =
               events

      assert_inflight(fixture, before, after_query)
      assert_exit(before.connection, exit)
      assert Process.whereis(NativeRepo) == nil
    end)
  end

  test "nested V3 rebuilding rejects before touching any projection" do
    with_fixture(fn fixture ->
      before = snapshot(fixture)

      assert {:ok, {:error, %Error{code: :invalid, message: nil, details: %{}}}} =
               MigrationRepo.transaction(fn ->
                 KnowledgeIntegrityAudit.rebuild(MigrationRepo, restore_binding(fixture))
               end)

      assert snapshot(fixture) == before
    end)
  end

  for fault <- [:native_negative_one, :native_late_sql_error] do
    @fault fault
    test "#{@fault} reaches real facade work and rolls back every projection" do
      with_fixture(fn fixture ->
        before = snapshot(fixture)
        original = function_metadata()
        original_definition = original.definition

        body =
          case @fault do
            :native_negative_one ->
              "RETURN -1;"

            :native_late_sql_error ->
              "RAISE EXCEPTION 'restore-test-late-query-fault' USING ERRCODE='P0001';"
          end

        needle = "RETURN projected_count;"
        assert [_, _] = String.split(original_definition, needle)

        changed =
          String.replace(
            original_definition,
            needle,
            "IF requested_resource = '#{fixture.ids.ready_document_id}'::uuid THEN #{body} END IF;\n#{needle}"
          )

        try do
          owner(fn -> q(changed) end)
          assert Map.delete(function_metadata(), :definition) == Map.delete(original, :definition)

          {result, events, exit} =
            traced(fixture, nil, fn ->
              KnowledgeIntegrityAudit.rebuild(NativeRepo, restore_binding(fixture))
            end)

          expected_code =
            if @fault == :native_late_sql_error,
              do: :storage_unavailable,
              else: :integrity_failure

          assert {:error, %Error{code: ^expected_code, message: nil, details: %{}}} = result
          assert [event] = events
          assert_base_and_delete_witness(fixture, event.before)

          if @fault == :native_negative_one do
            assert {:ok, %{rows: [[-1]]}} = event.native_result
            assert_inflight(fixture, event.before, event.after)
          else
            assert {:error, %Postgrex.Error{postgres: %{pg_code: "P0001"}}} = event.native_result
            assert event.after == nil
          end

          assert_exit(event.before.connection, exit)
          assert snapshot(fixture) == before
        after
          owner(fn -> q(original_definition) end)
          assert function_metadata() == original
          assert Process.whereis(NativeRepo) == nil
        end
      end)
    end
  end

  for rows <- [
        [],
        [[0, 1]],
        [[0], [1]],
        [[nil]],
        [["2"]],
        [[2.0]],
        [[-1]],
        [[9_223_372_036_854_775_808]]
      ] do
    @rows rows
    test "INJECTED_CONTRACT_FAULT #{inspect(@rows)} preserves native SQL and outer rollback" do
      with_fixture(fn fixture ->
        before = snapshot(fixture)
        original = function_metadata()

        {result, events, exit} =
          traced(fixture, {:injected_contract_fault, @rows}, fn ->
            KnowledgeIntegrityAudit.rebuild(NativeRepo, restore_binding(fixture))
          end)

        assert {:error, %Error{code: :integrity_failure, message: nil, details: %{}}} = result

        assert [%{before: before_query, native_result: {:ok, %{rows: [[2]]}}, after: after_query}] =
                 events

        assert_inflight(fixture, before_query, after_query)
        assert_exit(before_query.connection, exit)
        assert snapshot(fixture) == before
        assert function_metadata() == original
        assert Process.whereis(NativeRepo) == nil
      end)
    end
  end

  def native_witness(config) do
    %{
      connection: connection_witness(),
      assets: asset_rows(config.owner),
      legacy_notes:
        q(
          "SELECT title,markdown FROM content.note_search_documents WHERE vault_id=$1 ORDER BY resource_id",
          [dump(config.owner)]
        ).rows,
      documents:
        q(
          "SELECT entry_id FROM content.search_entries WHERE vault_id=$1 AND kind='document' ORDER BY entry_id",
          [dump(config.owner)]
        ).rows
    }
  end

  def connection_witness do
    [[backend, login, role, isolation, principal, scope]] =
      q("""
      SELECT pg_backend_pid(),session_user::text,current_user::text,
        current_setting('transaction_isolation'),
        nullif(current_setting('singularity.principal_id',true),''),
        nullif(current_setting('singularity.vault_id',true),'')
      """).rows

    %{
      backend: backend,
      login: login,
      role: role,
      isolation: isolation,
      principal: principal,
      owner: scope,
      transaction?: MigrationRepo.in_transaction?()
    }
  end

  def await_registry_cleanup(address) do
    await_registry_cleanup(address, System.monotonic_time(:millisecond) + 5_000)
  end

  defp await_registry_cleanup(address, deadline) do
    if :ets.lookup(Ecto.Repo.Registry, address) != [] do
      if System.monotonic_time(:millisecond) >= deadline,
        do: raise("repo alias cleanup timed out")

      receive do
      after
        1 -> await_registry_cleanup(address, deadline)
      end
    end

    :ok
  end

  defp traced(fixture, fault, callback) do
    keys = [:trace_config, :trace_events, :exit_witness]
    assert Enum.all?(keys, &(Process.get({__MODULE__, &1}) == nil))

    Process.put({__MODULE__, :trace_config}, %{
      owner: fixture.owner.vault_id,
      resource: fixture.ids.ready_document_id,
      fault: fault
    })

    try do
      result = callback.()

      {result, Enum.reverse(Process.get({__MODULE__, :trace_events}, [])),
       Process.get({__MODULE__, :exit_witness})}
    after
      Enum.each(keys, &Process.delete({__MODULE__, &1}))
      assert Process.whereis(NativeRepo) == nil
    end
  end

  defp assert_inflight(fixture, before, after_query) do
    assert_base_and_delete_witness(fixture, before)
    assert after_query.connection == before.connection
    assert after_query.assets == expected_evidence(fixture).assets
    assert after_query.documents == Enum.sort(Enum.map(@fragments, &["document:" <> &1]))
  end

  defp assert_base_and_delete_witness(fixture, witness) do
    assert witness.connection.transaction?
    assert witness.connection.isolation == "repeatable read"
    assert witness.connection.role == "singularity_table_owner"
    assert witness.connection.login == MigrationRepo.config()[:username]
    assert witness.connection.owner == fixture.owner.vault_id
    assert witness.connection.principal == nil
    assert witness.assets == expected_evidence(fixture).assets
    assert witness.legacy_notes == [["Fixture Note", "# Merged fixture\n"]]
    assert witness.documents == []
  end

  defp assert_exit(inside, outside) do
    assert outside.backend == inside.backend
    assert outside.login == inside.login
    assert outside.role == outside.login
    assert outside.principal == nil
    assert outside.owner == nil
    refute outside.transaction?
  end

  defp with_fixture(callback) do
    KnowledgeBackupFixtures.with_destination(:current, fn destination ->
      fixture =
        KnowledgeBackupFixtures.seed!(Map.merge(destination, %{ids: @ids, originals: @originals}))

      owner(fn ->
        for {name, label, n} <- [{:plain, "alpha", 201}, {:unicode, "beta", 202}] do
          source = fixture.sources[name]

          q(
            """
            INSERT INTO content.source_references(id,vault_id,resource_version_id,principal_id,
              classification,kind,observed_at,original_filename,declared_media_type,byte_size,
              idempotency_key_digest,inserted_at)
            VALUES($1,$2,$3,$4,'private','browser_upload',$5,$6,'text/plain',$7,$8,$5)
            """,
            [
              dump(foreign_id(n)),
              dump(fixture.owner.vault_id),
              dump(source.resource_version_id),
              dump(fixture.owner.principal_id),
              @time,
              label,
              source.byte_size,
              :crypto.hash(:sha256, label)
            ]
          )
        end
      end)

      seed_owner(foreign_id(1), foreign_id(2))

      seed_note(
        foreign_id(1),
        foreign_id(2),
        foreign_id(3),
        foreign_id(4),
        "Foreign Note",
        "# Foreign Note\n",
        @time
      )

      owner(fn ->
        q(
          "SELECT content.reconcile_search_resource_internal($1,$2)",
          [dump(foreign_id(1)), dump(foreign_id(3))]
        )
      end)

      fixture = Map.put(fixture, :foreign_owner, foreign_id(1))
      source_cut = KnowledgeBackupFixtures.canonical_rows(fixture)
      fixture = Map.put(fixture, :source_cut, source_cut)

      # Qualify unchanged Base with this fixture before the new facade contract.
      assert {:ok, %IntegrityAudit.SearchSummary{document_count: 3}} =
               IntegrityAudit.rebuild(MigrationRepo, restore_binding(fixture))

      assert evidence(fixture.owner.vault_id).assets === expected_evidence(fixture).assets
      assert KnowledgeBackupFixtures.canonical_rows(fixture) === source_cut

      seed_stale_projections(fixture)
      callback.(fixture)
    end)
  end

  defp seed_owner(owner_id, principal) do
    owner(fn ->
      q("INSERT INTO identity.people(id,display_name) VALUES($1,'Search restore owner')", [
        dump(owner_id)
      ])

      q("INSERT INTO identity.accounts(id,person_id) VALUES($1,$1)", [dump(owner_id)])

      q(
        "INSERT INTO identity.principals(id,account_id,kind) VALUES($1,$2,'owner')",
        [dump(principal), dump(owner_id)]
      )

      q("INSERT INTO core.vaults(id) VALUES($1)", [dump(owner_id)])

      q(
        "INSERT INTO core.vault_members(principal_id,vault_id) VALUES($1,$2)",
        [dump(principal), dump(owner_id)]
      )
    end)
  end

  defp seed_note(owner_id, principal, resource, version, title, body, time) do
    owner(fn ->
      q(
        """
        INSERT INTO content.resources(id,vault_id,classification,kind,current_version_id,title)
        VALUES($1,$2,'private','note',$3,$4)
        """,
        [dump(resource), dump(owner_id), dump(version), title]
      )

      q(
        """
        INSERT INTO content.resource_versions(id,resource_id,vault_id,classification,revision,inserted_at)
        VALUES($1,$2,$3,'private',0,$4)
        """,
        [dump(version), dump(resource), dump(owner_id), time]
      )

      q(
        """
        INSERT INTO content.note_versions(resource_version_id,resource_id,vault_id,classification,
          title,markdown,created_by_principal_id,inserted_at)
        VALUES($1,$2,$3,'private',$4,$5,$6,$7)
        """,
        [dump(version), dump(resource), dump(owner_id), title, body, dump(principal), time]
      )

      q("SELECT content.finalize_note_source_set($1)", [dump(version)])
    end)
  end

  defp seed_stale_projections(fixture) do
    owner(fn ->
      # Replace the current Note rebuilt by Base before seeding its stale version.
      assert %{num_rows: 1} =
               q(
                 """
                 DELETE FROM content.search_entries
                 WHERE vault_id=$1 AND resource_id=$2 AND kind='note' AND resource_version_id=$3
                 """,
                 [
                   dump(fixture.owner.vault_id),
                   dump(fixture.ids.live_note_id),
                   dump(fixture.ids.merge_note_version_id)
                 ]
               )

      q(
        """
        INSERT INTO content.search_entries(entry_id,vault_id,classification,resource_id,
          resource_version_id,kind,note_resource_version_id,fragment_id,ordinal,title,body,
          locator,source_inserted_at,projection_version)
        SELECT 'document:'||f.id,f.vault_id,'private',f.resource_id,f.resource_version_id,
          'document',NULL,f.id,f.ordinal,'Stale Document',f.text,f.locator,v.inserted_at,1
        FROM content.document_fragments f JOIN content.resource_versions v ON v.id=f.resource_version_id
        WHERE f.vault_id=$1
        ON CONFLICT(entry_id) DO UPDATE SET title=EXCLUDED.title
        """,
        [dump(fixture.owner.vault_id)]
      )

      q(
        """
        INSERT INTO content.search_entries(entry_id,vault_id,classification,resource_id,
          resource_version_id,kind,note_resource_version_id,fragment_id,ordinal,title,body,
          locator,source_inserted_at,projection_version)
        SELECT 'note:'||n.resource_version_id,n.vault_id,'private',n.resource_id,n.resource_version_id,
          'note',n.resource_version_id,NULL,0,'Stale Note',n.markdown,
          '{"version":1,"kind":"markdown","heading_path":[]}'::jsonb,v.inserted_at,1
        FROM content.note_versions n JOIN content.resource_versions v ON v.id=n.resource_version_id
        WHERE n.vault_id=$1 AND n.resource_version_id=ANY($2::uuid[])
        ON CONFLICT(entry_id) DO UPDATE SET title=EXCLUDED.title
        """,
        [
          dump(fixture.owner.vault_id),
          Enum.map(
            [fixture.ids.initial_note_version_id, fixture.ids.deleted_note_version_id],
            &dump/1
          )
        ]
      )

      q(
        """
        INSERT INTO content.asset_search_documents(asset_id,resource_version_id,vault_id,
          classification,state,resource_title,original_filename)
        SELECT id,resource_version_id,vault_id,'private',state,'Stale Asset','stale'
        FROM content.assets WHERE vault_id=$1 AND id=ANY($2::uuid[])
        ON CONFLICT(asset_id) DO UPDATE SET resource_title=EXCLUDED.resource_title,
          original_filename=EXCLUDED.original_filename
        """,
        [
          dump(fixture.owner.vault_id),
          Enum.map([fixture.sources.plain.asset_id, fixture.sources.unicode.asset_id], &dump/1)
        ]
      )

      q(
        "UPDATE content.note_search_documents SET title='Stale Note' WHERE vault_id=$1",
        [dump(fixture.owner.vault_id)]
      )
    end)
  end

  defp expected_evidence(fixture) do
    [first, second] = @fragments
    doc_time = source_time(fixture, fixture.ids.ready_current_version_id)
    note_time = source_time(fixture, fixture.ids.merge_note_version_id)

    %{
      assets: [
        [
          fixture.sources.plain.asset_id,
          fixture.sources.plain.resource_version_id,
          "private",
          "available",
          nil,
          "'alpha':3 'original':1 'plain':2"
        ],
        [
          fixture.sources.unicode.asset_id,
          fixture.sources.unicode.resource_version_id,
          "private",
          "available",
          nil,
          "'beta':3 'original':1 'unicode':2"
        ]
      ],
      knowledge: [
        [
          "document:" <> first,
          "document",
          fixture.ids.ready_document_id,
          fixture.ids.ready_current_version_id,
          first,
          0,
          "Fixture Document",
          "first\n",
          %{"version" => 1, "kind" => "pdf", "page" => 1},
          doc_time,
          "'document':2A 'first':3 'fixture':1A"
        ],
        [
          "document:" <> second,
          "document",
          fixture.ids.ready_document_id,
          fixture.ids.ready_current_version_id,
          second,
          1,
          "Fixture Document",
          "界🙂",
          %{"version" => 1, "kind" => "pdf", "page" => 2},
          doc_time,
          "'document':2A 'fixture':1A '界🙂':3"
        ],
        [
          "note:" <> fixture.ids.merge_note_version_id,
          "note",
          fixture.ids.live_note_id,
          fixture.ids.merge_note_version_id,
          nil,
          0,
          "Fixture Note",
          "# Merged fixture\n",
          %{"version" => 1, "kind" => "markdown", "heading_path" => []},
          note_time,
          "'fixture':1A,4 'merged':3 'note':2A"
        ]
      ]
    }
  end

  defp source_time(fixture, version) do
    # Captured canonical input before projection writes, not the production evidence query.
    [%{"inserted_at" => time}] =
      fixture.source_cut["content.resource_versions"] |> Enum.filter(&(&1["id"] == version))

    time
  end

  defp restore_binding(fixture),
    do: %{manifest_id: Ecto.UUID.generate(), vault_id: fixture.owner.vault_id}

  defp snapshot(fixture) do
    %{
      canonical: KnowledgeBackupFixtures.canonical_rows(fixture),
      projections:
        owner(fn ->
          Map.new(
            ~w(content.asset_search_documents content.note_search_documents content.search_entries),
            fn table ->
              {table, q("SELECT to_jsonb(t) FROM #{table} t ORDER BY to_jsonb(t)::text").rows}
            end
          )
        end),
      foreign:
        owner(fn ->
          Map.new(
            ~w(content.resources content.resource_versions content.note_versions content.note_source_set_seals content.asset_search_documents content.note_search_documents content.search_entries),
            fn table ->
              {table,
               q(
                 "SELECT to_jsonb(t) FROM #{table} t WHERE vault_id=$1 ORDER BY to_jsonb(t)::text",
                 [dump(fixture.foreign_owner)]
               ).rows}
            end
          )
        end)
    }
  end

  defp evidence(owner_id),
    do: owner(fn -> %{assets: asset_rows(owner_id), knowledge: unified_rows(owner_id)} end)

  defp asset_rows(owner_id) do
    q(
      """
      SELECT asset_id::text,resource_version_id::text,classification,state,
        detected_media_type,search_vector::text
      FROM content.asset_search_documents WHERE vault_id=$1 ORDER BY asset_id
      """,
      [dump(owner_id)]
    ).rows
  end

  defp unified_rows(owner_id) do
    q(
      """
      SELECT entry_id,kind,resource_id::text,resource_version_id::text,fragment_id,
        ordinal,title,body,locator,
        to_char(source_inserted_at AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
        search_vector::text
      FROM content.search_entries WHERE vault_id=$1
      ORDER BY kind COLLATE "C",resource_id,resource_version_id,ordinal,entry_id COLLATE "C"
      """,
      [dump(owner_id)]
    ).rows
  end

  defp function_metadata do
    owner(fn ->
      [[definition, owner_name, result, security, settings, acl]] =
        q("""
        SELECT pg_get_functiondef(p.oid),pg_get_userbyid(p.proowner),pg_get_function_result(p.oid),
          p.prosecdef,p.proconfig,to_jsonb(p.proacl)
        FROM pg_proc p
        WHERE p.oid='content.reconcile_search_resource_internal(uuid,uuid)'::regprocedure
        """).rows

      %{
        definition: definition,
        owner: owner_name,
        result: result,
        security: security,
        settings: settings,
        acl: acl
      }
    end)
  end

  defp evidence_digest(rows),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(rows, [:deterministic, {:minor_version, 2}]))

  defp owner(callback) do
    {:ok, result} =
      MigrationRepo.transaction(fn ->
        q("SET LOCAL ROLE singularity_table_owner")
        callback.()
      end)

    result
  end

  defp q(statement, params \\ []), do: SafeSQL.query!(MigrationRepo, statement, params)
  defp dump(id), do: Ecto.UUID.dump!(id)

  defp foreign_id(n),
    do: "76f00000-0000-4000-8000-" <> String.pad_leading(Integer.to_string(n), 12, "0")
end
