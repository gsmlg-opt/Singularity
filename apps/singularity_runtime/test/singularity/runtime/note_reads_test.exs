defmodule Singularity.Runtime.NoteReadsTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.Error
  alias Singularity.Retrieval.NoteSearchPage, as: RetrievalPage
  alias Singularity.Retrieval.NoteSearchQuery
  alias Singularity.Runtime.DTO.Note
  alias Singularity.Runtime.DTO.NoteConflict
  alias Singularity.Runtime.DTO.NoteConflictDetail
  alias Singularity.Runtime.DTO.NoteExport
  alias Singularity.Runtime.DTO.NoteHistoryPage
  alias Singularity.Runtime.DTO.NoteSaveResult
  alias Singularity.Runtime.DTO.NoteSearchPage
  alias Singularity.Runtime.DTO.NoteSummary
  alias Singularity.Runtime.DTO.NoteTrashPage
  alias Singularity.Runtime.DTO.NoteVersion
  alias Singularity.Runtime.DTO.NoteVersionSummary
  alias Singularity.Runtime.Notes.Export
  alias Singularity.Runtime.Notes.Get
  alias Singularity.Runtime.Notes.History
  alias Singularity.Runtime.Notes.Search
  alias Singularity.Runtime.Notes.Trash
  alias Singularity.Runtime.SessionContext

  @session_id "00000000-0000-4000-8000-000000000901"
  @principal_id "00000000-0000-4000-8000-000000000902"
  @vault_id "00000000-0000-4000-8000-000000000903"
  @resource_id "00000000-0000-4000-8000-000000000904"
  @version_id "00000000-0000-4000-8000-000000000905"
  @base_version_id "00000000-0000-4000-8000-000000000906"
  @competing_version_id "00000000-0000-4000-8000-000000000907"
  @conflict_id "00000000-0000-4000-8000-000000000908"
  @actor_id "00000000-0000-4000-8000-000000000909"
  @updated_at ~U[2026-08-18 09:00:00.000000Z]
  @inserted_at ~U[2026-08-18 08:00:00.000000Z]
  @created_at ~U[2026-08-18 08:30:00.000000Z]
  @deleted_at ~U[2026-08-18 10:00:00.000000Z]

  @summary_fields ~w(
    resource_id resource_version_id title revision display_version updated_at
    deleted? open_conflict_count
  )a
  @note_fields @summary_fields ++ [:markdown]
  @version_summary_fields ~w(
    resource_version_id revision display_version created_by_principal_id inserted_at
    parent_version_id merge_parent_version_id canonical? conflict_state
  )a
  @version_fields @version_summary_fields ++ [:resource_id, :title, :markdown]
  @conflict_fields ~w(
    conflict_id base_version_id observed_canonical_version_id competing_version_id
  )a

  defmodule Scope do
    def with_read_request(owner, runtime, session, requirement, callback) do
      send(owner, {:read_scope, runtime, session, requirement})

      case Process.get(:note_read_scope_result) do
        nil -> callback.(:read_repo)
        result -> result
      end
    end

    def with_shared_request(owner, runtime, session, requirement, callback) do
      send(owner, {:shared_scope, runtime, session, requirement})

      case Process.get(:note_shared_scope_result) do
        nil -> callback.(:shared_repo)
        result -> result
      end
    end
  end

  defmodule Repository do
    def get(owner, repo, vault_id, resource_id) do
      send(owner, {:get, repo, vault_id, resource_id})
      Process.get(:note_get_result)
    end

    def get_version(owner, repo, vault_id, resource_id, version_id) do
      send(owner, {:get_version, repo, vault_id, resource_id, version_id})
      Process.get(:note_version_result)
    end

    def get_conflict(owner, repo, vault_id, resource_id, conflict_id) do
      send(owner, {:get_conflict, repo, vault_id, resource_id, conflict_id})
      Process.get(:note_conflict_result)
    end

    def history(owner, repo, vault_id, resource_id, params) do
      send(owner, {:history, repo, vault_id, resource_id, params})
      Process.get(:note_history_result)
    end

    def trash(owner, repo, vault_id, params) do
      send(owner, {:trash, repo, vault_id, params})
      Process.get(:note_trash_result)
    end
  end

  defmodule Retrieval do
    def search(owner, store, repo, query) do
      send(owner, {:search, store, repo, query})
      Process.get(:note_search_result)
    end
  end

  defmodule Store do
  end

  defmodule Audit do
    def append(owner, repo, event) do
      send(owner, {:audit, repo, event})
      Process.get(:note_audit_result, :ok)
    end
  end

  setup do
    Process.put(:note_get_result, {:ok, canonical_row()})
    Process.put(:note_version_result, {:ok, version_row()})

    Process.put(:note_conflict_result, {
      :ok,
      %{
        conflict: conflict_row(),
        current: version_row(resource_version_id: @version_id, canonical?: true),
        competing:
          version_row(
            resource_version_id: @competing_version_id,
            canonical?: false,
            conflict_state: :open
          )
      }
    })

    Process.put(:note_history_result, {
      :ok,
      %{items: [version_summary_row()], next_cursor: :done}
    })

    Process.put(:note_trash_result, {
      :ok,
      %{items: [trash_row()], next_cursor: :done}
    })

    Process.put(:note_search_result, {
      :ok,
      %RetrievalPage{items: [search_row()], next_cursor: nil}
    })

    on_exit(fn ->
      for key <- [
            :note_get_result,
            :note_version_result,
            :note_conflict_result,
            :note_history_result,
            :note_trash_result,
            :note_search_result,
            :note_read_scope_result,
            :note_shared_scope_result,
            :note_audit_result
          ] do
        Process.delete(key)
      end
    end)
  end

  test "constructors expose every exact DTO field set" do
    summary = build!(NoteSummary, summary_attrs())
    note = build!(Note, note_attrs())
    version_summary = build!(NoteVersionSummary, version_summary_attrs())
    current = build!(NoteVersion, version_attrs())

    competing =
      build!(
        NoteVersion,
        version_attrs(
          resource_version_id: @competing_version_id,
          canonical?: false,
          conflict_state: :open
        )
      )

    conflict = build!(NoteConflict, conflict_attrs())

    assert_fields(summary, @summary_fields)
    assert_fields(note, @note_fields)
    assert_fields(version_summary, @version_summary_fields)
    assert_fields(current, @version_fields)
    assert_fields(conflict, @conflict_fields)

    detail =
      build!(NoteConflictDetail, %{
        conflict_id: conflict.conflict_id,
        base_version_id: conflict.base_version_id,
        observed_canonical_version_id: conflict.observed_canonical_version_id,
        current: current,
        competing: competing
      })

    assert_fields(detail, [
      :conflict_id,
      :base_version_id,
      :observed_canonical_version_id,
      :current,
      :competing
    ])

    search_page = build!(NoteSearchPage, %{items: [summary], next_cursor: nil})

    trash_page =
      build!(NoteTrashPage, %{
        items: [%{summary: %{summary | deleted?: true}, deleted_at: @deleted_at}],
        next_cursor: nil
      })

    history_page = build!(NoteHistoryPage, %{items: [version_summary], next_cursor: nil})

    assert_fields(search_page, [:items, :next_cursor])
    assert_fields(trash_page, [:items, :next_cursor])
    assert_fields(history_page, [:items, :next_cursor])

    export = build!(NoteExport, export_attrs())
    assert_fields(export, [:resource_id, :resource_version_id, :filename, :media_type, :markdown])
  end

  test "constructors reject malformed internal successes as integrity failures" do
    malformed = [
      {NoteSummary, Map.put(summary_attrs(), :unexpected, true)},
      {NoteSummary, Map.delete(summary_attrs(), :title)},
      {NoteSummary, %{summary_attrs() | display_version: 7}},
      {NoteSummary, %{summary_attrs() | revision: -1}},
      {NoteSummary, %{summary_attrs() | updated_at: offset_datetime()}},
      {Note, %{note_attrs() | deleted?: true}},
      {NoteVersionSummary, %{version_summary_attrs() | canonical?: :yes}},
      {NoteVersionSummary, %{version_summary_attrs() | conflict_state: :unknown}},
      {NoteVersionSummary, %{version_summary_attrs() | conflict_state: :open}},
      {NoteConflict, %{conflict_attrs() | competing_version_id: @base_version_id}},
      {NoteExport, %{export_attrs() | resource_id: "not-a-uuid"}},
      {NoteExport, %{export_attrs() | media_type: "text/plain"}},
      {NoteExport, %{export_attrs() | filename: "unsafe\tname.md"}},
      {NoteExport, %{export_attrs() | filename: "unsafe\u007Fname.md"}}
    ]

    for {module, attrs} <- malformed do
      assert {:error, %Error{code: :integrity_failure, retryable?: false}} =
               construct(module, attrs)
    end

    summary = build!(NoteSummary, summary_attrs())
    version_summary = build!(NoteVersionSummary, version_summary_attrs())
    current = build!(NoteVersion, version_attrs())

    assert {:error, %Error{code: :integrity_failure}} =
             construct(NoteConflictDetail, %{
               conflict_id: @conflict_id,
               base_version_id: @base_version_id,
               observed_canonical_version_id: @version_id,
               current: current,
               competing: %{current | canonical?: false}
             })

    for {module, attrs} <- [
          {NoteSearchPage, %{items: [summary], next_cursor: ""}},
          {NoteSearchPage, %{items: [%{summary | deleted?: true}], next_cursor: nil}},
          {NoteSearchPage,
           %{items: [Map.put(summary_attrs(), :markdown, "private")], next_cursor: nil}},
          {NoteTrashPage,
           %{items: [%{summary: summary, deleted_at: offset_datetime()}], next_cursor: nil}},
          {NoteHistoryPage, %{items: [version_summary], next_cursor: :done}},
          {NoteHistoryPage,
           %{items: [Map.put(version_summary_attrs(), :markdown, "private")], next_cursor: nil}}
        ] do
      assert {:error, %Error{code: :integrity_failure, retryable?: false}} =
               construct(module, attrs)
    end
  end

  test "summary and page DTOs never expose Markdown" do
    summary = build!(NoteSummary, summary_attrs())
    page = build!(NoteSearchPage, %{items: [summary], next_cursor: "next-page"})

    refute Map.has_key?(Map.from_struct(summary), :markdown)
    refute inspect(page) =~ "PRIVATE_MARKDOWN_CANARY"

    assert {:error, %Error{code: :integrity_failure}} =
             construct(
               NoteSummary,
               Map.put(summary_attrs(), :markdown, "PRIVATE_MARKDOWN_CANARY")
             )
  end

  test "save DTO enforces saved and conflict reference invariants" do
    canonical = build!(Note, note_attrs())

    saved =
      build!(NoteSaveResult, %{
        outcome: :saved,
        canonical: canonical,
        submitted_version_id: @version_id
      })

    conflict =
      build!(NoteSaveResult, %{
        outcome: :conflict,
        canonical: canonical,
        submitted_version_id: @competing_version_id,
        conflict_id: @conflict_id
      })

    assert_fields(saved, [:outcome, :canonical, :submitted_version_id, :conflict_id])
    assert saved.conflict_id == nil
    assert conflict.conflict_id == @conflict_id

    for attrs <- [
          %{
            outcome: :saved,
            canonical: canonical,
            submitted_version_id: @competing_version_id
          },
          %{
            outcome: :saved,
            canonical: canonical,
            submitted_version_id: @version_id,
            conflict_id: @conflict_id
          },
          %{
            outcome: :conflict,
            canonical: canonical,
            submitted_version_id: @version_id,
            conflict_id: @conflict_id
          },
          %{
            outcome: :conflict,
            canonical: canonical,
            submitted_version_id: @competing_version_id,
            conflict_id: nil
          }
        ] do
      assert {:error, %Error{code: :integrity_failure}} = construct(NoteSaveResult, attrs)
    end
  end

  test "Search binds the session vault and uses an unlocked note.read scope" do
    runtime = runtime()
    session = session()

    assert {:ok, %RetrievalPage{}} = Search.run(runtime, session, %{q: " plan "})

    assert_receive {:read_scope, ^runtime, ^session, requirement}
    assert_read_requirement(requirement)

    assert_receive {:search, Store, :read_repo, %NoteSearchQuery{vault_id: @vault_id, q: "plan"}}

    assert {:error, %Error{code: :invalid}} =
             Search.run(runtime, session, %{vault_id: Ecto.UUID.generate()})

    refute_received {:search, _store, _repo, _query}
  end

  test "Get, exact version, conflict, History, and Trash use their exact read adapters" do
    runtime = runtime()
    session = session()

    assert {:ok, canonical} = Get.run(runtime, session, @resource_id)
    assert canonical.resource_version_id == @version_id
    assert_receive {:read_scope, ^runtime, ^session, get_requirement}
    assert_read_requirement(get_requirement)
    assert_receive {:get, :read_repo, @vault_id, @resource_id}

    assert {:ok, pinned} = Get.version(runtime, session, @resource_id, @base_version_id)
    assert pinned.resource_version_id == @base_version_id
    assert pinned.canonical? == false
    assert_receive {:get_version, :read_repo, @vault_id, @resource_id, @base_version_id}

    assert {:ok, detail} = Get.conflict(runtime, session, @resource_id, @conflict_id)
    assert detail.conflict.conflict_id == @conflict_id
    assert_receive {:get_conflict, :read_repo, @vault_id, @resource_id, @conflict_id}

    assert {:ok, %{items: [_], next_cursor: :done}} =
             History.run(runtime, session, @resource_id, %{limit: 20, cursor: nil})

    assert_receive {:history, :read_repo, @vault_id, @resource_id, %{limit: 20, cursor: nil}}

    assert {:ok, %{items: [_], next_cursor: :done}} =
             Trash.run(runtime, session, %{limit: 20, cursor: nil})

    assert_receive {:trash, :read_repo, @vault_id, %{limit: 20, cursor: nil}}

    for _operation <- 1..4 do
      assert_receive {:read_scope, ^runtime, ^session, requirement}
      assert_read_requirement(requirement)
    end
  end

  test "read use cases preserve locked and stable repository errors without adapter work" do
    Process.put(:note_read_scope_result, {:error, Error.new(:vault_locked)})

    assert {:error, %Error{code: :vault_locked}} = Search.run(runtime(), session(), %{})
    refute_received {:search, _store, _repo, _query}

    Process.delete(:note_read_scope_result)
    Process.put(:note_get_result, {:error, Error.new(:not_found)})

    assert {:error, %Error{code: :not_found}} = Get.run(runtime(), session(), @resource_id)
  end

  test "Export uses a shared all-of scope, audits identifiers only, and returns exact bytes" do
    markdown = "# Stored\n\nPRIVATE_EXPORT_BYTES_CANARY\n"

    Process.put(
      :note_get_result,
      {:ok, canonical_row(title: "Quarter/Plan", markdown: markdown)}
    )

    runtime = runtime()
    session = session()

    assert {:ok, export} = Export.run(runtime, session, @resource_id)
    assert export.__struct__ == NoteExport
    assert export.resource_id == @resource_id
    assert export.resource_version_id == @version_id
    assert export.filename == "Quarter_Plan.md"
    assert export.media_type == "text/markdown; charset=utf-8"
    assert export.markdown === markdown

    assert_receive {:shared_scope, ^runtime, ^session, requirement}

    assert requirement == %{
             vault_id: @vault_id,
             required_capabilities: ["note.export", "note.read"],
             classification: :private,
             requires_unlocked?: true
           }

    assert_receive {:get, :shared_repo, @vault_id, @resource_id}
    assert_receive {:audit, :shared_repo, audit}
    assert audit.action == "note.export"
    assert audit.result == :completed
    assert audit.classification == :private
    assert audit.target_type == "note"
    assert audit.target_id == @resource_id
    refute inspect(audit) =~ "Quarter/Plan"
    refute inspect(audit) =~ "PRIVATE_EXPORT_BYTES_CANARY"
  end

  test "Export fails closed for tombstones or audit errors and uses the safe fallback filename" do
    Process.put(:note_get_result, {:error, Error.new(:not_found)})

    assert {:error, %Error{code: :not_found}} = Export.run(runtime(), session(), @resource_id)
    refute_received {:audit, _repo, _event}

    Process.put(:note_get_result, {:ok, canonical_row(title: "/\\\r\n\0", markdown: "raw")})
    assert {:ok, fallback} = Export.run(runtime(), session(), @resource_id)
    assert fallback.filename == "note.md"
    assert fallback.markdown == "raw"

    Process.put(:note_get_result, {:ok, canonical_row(title: "/ /", markdown: "raw")})
    assert {:ok, fallback} = Export.run(runtime(), session(), @resource_id)
    assert fallback.filename == "note.md"

    Process.put(:note_get_result, {:ok, canonical_row(title: " _draft_ ", markdown: "raw")})
    assert {:ok, preserved} = Export.run(runtime(), session(), @resource_id)
    assert preserved.filename == "_draft_.md"

    Process.put(:note_audit_result, {:error, Error.new(:storage_unavailable, retryable?: true)})

    assert {:error, %Error{code: :storage_unavailable, retryable?: true}} =
             Export.run(runtime(), session(), @resource_id)
  end

  defp runtime do
    %{
      audit: {Audit, self()},
      note_repository: {Repository, self()},
      note_search: {Retrieval, self()},
      note_search_store: Store,
      operation_scope: {Scope, self()}
    }
  end

  defp session do
    %SessionContext{
      session_id: @session_id,
      principal_id: @principal_id,
      vault_id: @vault_id,
      expires_at: DateTime.add(DateTime.utc_now(), 600, :second),
      principal_authorization_epoch: 7,
      vault_authorization_epoch: 11,
      authorization_epoch: 7,
      unlocked?: true
    }
  end

  defp assert_read_requirement(requirement) do
    assert requirement == %{
             vault_id: @vault_id,
             required_capability: "note.read",
             classification: :private,
             requires_unlocked?: true
           }
  end

  defp build!(module, attrs) do
    assert {:ok, value} = construct(module, attrs)
    assert value.__struct__ == module
    value
  end

  defp construct(module, attrs), do: apply(module, :new, [attrs])

  defp assert_fields(value, fields) do
    assert value |> Map.from_struct() |> Map.keys() |> Enum.sort() == Enum.sort(fields)
  end

  defp summary_attrs(overrides \\ []) do
    Map.merge(
      %{
        resource_id: @resource_id,
        resource_version_id: @version_id,
        title: "Current note",
        revision: 2,
        display_version: 3,
        updated_at: @updated_at,
        deleted?: false,
        open_conflict_count: 1
      },
      Map.new(overrides)
    )
  end

  defp note_attrs(overrides \\ []) do
    summary_attrs()
    |> Map.put(:markdown, "# Current note")
    |> Map.merge(Map.new(overrides))
  end

  defp version_summary_attrs(overrides \\ []) do
    Map.merge(
      %{
        resource_version_id: @version_id,
        revision: 2,
        display_version: 3,
        created_by_principal_id: @actor_id,
        inserted_at: @inserted_at,
        parent_version_id: @base_version_id,
        merge_parent_version_id: nil,
        canonical?: true,
        conflict_state: nil
      },
      Map.new(overrides)
    )
  end

  defp version_attrs(overrides \\ []) do
    version_summary_attrs()
    |> Map.merge(%{
      resource_id: @resource_id,
      title: "Version title",
      markdown: "# Version title"
    })
    |> Map.merge(Map.new(overrides))
  end

  defp conflict_attrs(overrides \\ []) do
    Map.merge(
      %{
        conflict_id: @conflict_id,
        base_version_id: @base_version_id,
        observed_canonical_version_id: @version_id,
        competing_version_id: @competing_version_id
      },
      Map.new(overrides)
    )
  end

  defp export_attrs(overrides \\ []) do
    Map.merge(
      %{
        resource_id: @resource_id,
        resource_version_id: @version_id,
        filename: "Current note.md",
        media_type: "text/markdown; charset=utf-8",
        markdown: "# Current note"
      },
      Map.new(overrides)
    )
  end

  defp search_row do
    %{
      resource_id: @resource_id,
      resource_version_id: @version_id,
      vault_id: @vault_id,
      classification: :private,
      title: "Current note",
      revision: 2,
      updated_at: @updated_at,
      deleted?: false,
      open_conflict_count: 1
    }
  end

  defp canonical_row(overrides \\ []) do
    Map.merge(
      %{
        resource_id: @resource_id,
        resource_version_id: @version_id,
        vault_id: @vault_id,
        classification: :private,
        title: "Current note",
        markdown: "# Current note",
        revision: 2,
        updated_at: @updated_at,
        deleted_at: nil,
        deleted?: false,
        created_by_principal_id: @actor_id,
        inserted_at: @inserted_at,
        parent_version_id: @base_version_id,
        merge_parent_version_id: nil,
        canonical?: true,
        open_conflict_count: 1
      },
      Map.new(overrides)
    )
  end

  defp version_row(overrides \\ []) do
    Map.merge(
      %{
        resource_id: @resource_id,
        resource_version_id: @base_version_id,
        vault_id: @vault_id,
        classification: :private,
        title: "Pinned version",
        markdown: "# Pinned version",
        revision: 0,
        created_by_principal_id: @actor_id,
        inserted_at: @inserted_at,
        parent_version_id: nil,
        merge_parent_version_id: nil,
        canonical?: false,
        conflict_state: nil
      },
      Map.new(overrides)
    )
  end

  defp version_summary_row do
    Map.take(version_row(), [
      :resource_version_id,
      :revision,
      :created_by_principal_id,
      :inserted_at,
      :parent_version_id,
      :merge_parent_version_id,
      :canonical?,
      :conflict_state
    ])
  end

  defp conflict_row do
    conflict_attrs()
    |> Map.merge(%{
      resource_id: @resource_id,
      vault_id: @vault_id,
      classification: :private,
      state: :open,
      resolution_version_id: nil,
      created_at: @created_at,
      resolved_at: nil
    })
  end

  defp trash_row do
    search_row()
    |> Map.put(:deleted?, true)
    |> Map.put(:deleted_at, @deleted_at)
  end

  defp offset_datetime do
    %DateTime{@updated_at | time_zone: "Etc/GMT-8", zone_abbr: "+08", utc_offset: 28_800}
  end
end
