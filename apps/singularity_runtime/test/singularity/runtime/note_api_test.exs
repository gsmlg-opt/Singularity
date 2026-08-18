defmodule Singularity.Runtime.NoteApiTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.Error
  alias Singularity.Runtime.Api
  alias Singularity.Runtime.DTO.Note
  alias Singularity.Runtime.DTO.NoteConflictDetail
  alias Singularity.Runtime.DTO.NoteExport
  alias Singularity.Runtime.DTO.NoteHistoryPage
  alias Singularity.Runtime.DTO.NoteSearchPage
  alias Singularity.Runtime.DTO.NoteTrashPage
  alias Singularity.Runtime.DTO.NoteVersion
  alias Singularity.Runtime.DTO.Session
  alias Singularity.Runtime.SessionContext

  @session_id "00000000-0000-4000-8000-000000000951"
  @account_id "00000000-0000-4000-8000-000000000952"
  @principal_id "00000000-0000-4000-8000-000000000953"
  @vault_id "00000000-0000-4000-8000-000000000954"
  @resource_id "00000000-0000-4000-8000-000000000955"
  @version_id "00000000-0000-4000-8000-000000000956"
  @base_id "00000000-0000-4000-8000-000000000957"
  @competing_id "00000000-0000-4000-8000-000000000958"
  @conflict_id "00000000-0000-4000-8000-000000000959"
  @updated_at ~U[2026-08-18 09:00:00.000000Z]
  @inserted_at ~U[2026-08-18 08:00:00.000000Z]
  @deleted_at ~U[2026-08-18 10:00:00.000000Z]

  test "facade exposes exact public and leading-config note read arities" do
    Code.ensure_loaded!(Api)

    for {function, arities} <- [
          search_notes: [2, 3],
          trash_notes: [2, 3],
          get_note: [2, 3],
          get_note_version: [3, 4],
          get_note_conflict: [3, 4],
          note_history: [3, 4],
          export_note: [2, 3]
        ],
        arity <- arities do
      assert function_exported?(Api, function, arity)
    end
  end

  test "facade converts search and Trash successes into exact summary DTO pages" do
    parent = self()

    config = %{
      search_notes: fn context, %{q: "note"} ->
        send(parent, {:search_context, context})
        {:ok, %{items: [search_row()], next_cursor: :done}}
      end,
      trash_notes: fn context, %{limit: 20} ->
        send(parent, {:trash_context, context})

        {:ok,
         %{
           items: [search_row() |> Map.put(:deleted?, true) |> Map.put(:deleted_at, @deleted_at)],
           next_cursor: :done
         }}
      end
    }

    assert {:ok, %NoteSearchPage{items: [summary], next_cursor: nil}} =
             Api.search_notes(config, session(), %{q: "note"})

    assert Map.keys(Map.from_struct(summary)) |> Enum.sort() ==
             ~w(deleted? display_version open_conflict_count resource_id resource_version_id revision title updated_at)a
             |> Enum.sort()

    refute Map.has_key?(Map.from_struct(summary), :markdown)

    assert {:ok,
            %NoteTrashPage{
              items: [%{summary: %{deleted?: true}, deleted_at: @deleted_at}],
              next_cursor: nil
            }} = Api.trash_notes(config, session(), %{limit: 20})

    assert_receive {:search_context, %SessionContext{vault_id: @vault_id, unlocked?: true}}
    assert_receive {:trash_context, %SessionContext{principal_id: @principal_id}}
  end

  test "facade converts canonical, exact-version, conflict, and history reads" do
    config = %{
      get_note: fn _context, @resource_id -> {:ok, canonical_row()} end,
      get_note_version: fn _context, @resource_id, @base_id -> {:ok, version_row()} end,
      get_note_conflict: fn _context, @resource_id, @conflict_id ->
        {:ok,
         %{
           conflict: conflict_row(),
           current: canonical_row(),
           competing:
             version_row(%{
               resource_version_id: @competing_id,
               revision: 2,
               parent_version_id: @base_id,
               conflict_state: :open
             })
         }}
      end,
      note_history: fn _context, @resource_id, %{cursor: nil} ->
        {:ok, %{items: [version_summary_row()], next_cursor: :done}}
      end
    }

    assert {:ok, %Note{resource_id: @resource_id, markdown: "# Current"}} =
             Api.get_note(config, session(), @resource_id)

    assert {:ok,
            %NoteVersion{
              resource_version_id: @base_id,
              display_version: 1,
              canonical?: false,
              markdown: "# Initial"
            }} = Api.get_note_version(config, session(), @resource_id, @base_id)

    assert {:ok,
            %NoteConflictDetail{
              conflict_id: @conflict_id,
              base_version_id: @base_id,
              observed_canonical_version_id: @version_id,
              current: %{resource_version_id: @version_id, canonical?: true},
              competing: %{resource_version_id: @competing_id, canonical?: false}
            }} = Api.get_note_conflict(config, session(), @resource_id, @conflict_id)

    assert {:ok, %NoteHistoryPage{items: [history], next_cursor: nil}} =
             Api.note_history(config, session(), @resource_id, %{cursor: nil})

    assert history.resource_version_id == @base_id
    assert history.display_version == 1
    refute Map.has_key?(Map.from_struct(history), :markdown)
  end

  test "export facade preserves exact bytes and the sanitized runtime descriptor" do
    markdown = <<"# Exact\n", 0xE6, 0xBC, 0xA2, "\n">>

    config = %{
      export_note: fn %SessionContext{vault_id: @vault_id}, @resource_id ->
        {:ok,
         %{
           resource_id: @resource_id,
           resource_version_id: @version_id,
           filename: "Current note.md",
           media_type: "text/markdown; charset=utf-8",
           markdown: markdown
         }}
      end
    }

    assert {:ok,
            %NoteExport{
              resource_id: @resource_id,
              resource_version_id: @version_id,
              filename: "Current note.md",
              media_type: "text/markdown; charset=utf-8",
              markdown: ^markdown
            }} = Api.export_note(config, session(), @resource_id)
  end

  test "malformed lower successes fail as integrity_failure and stable errors remain stable" do
    calls = [
      fn -> Api.search_notes(%{search_notes: fn _, _ -> {:ok, %{}} end}, session(), %{}) end,
      fn -> Api.trash_notes(%{trash_notes: fn _, _ -> {:ok, %{}} end}, session(), %{}) end,
      fn -> Api.get_note(%{get_note: fn _, _ -> {:ok, %{}} end}, session(), @resource_id) end,
      fn ->
        Api.get_note_version(
          %{get_note_version: fn _, _, _ -> {:ok, %{}} end},
          session(),
          @resource_id,
          @version_id
        )
      end,
      fn ->
        Api.get_note_conflict(
          %{get_note_conflict: fn _, _, _ -> {:ok, %{}} end},
          session(),
          @resource_id,
          @conflict_id
        )
      end,
      fn ->
        Api.note_history(
          %{note_history: fn _, _, _ -> {:ok, %{}} end},
          session(),
          @resource_id,
          %{}
        )
      end,
      fn ->
        Api.export_note(%{export_note: fn _, _ -> {:ok, %{}} end}, session(), @resource_id)
      end
    ]

    for call <- calls do
      assert {:error, :integrity_failure} = call.()
    end

    assert {:error, :integrity_failure} =
             Api.get_note(%{get_note: fn _, _ -> :ok end}, session(), @resource_id)

    assert {:error, :integrity_failure} =
             Api.search_notes(
               %{
                 search_notes: fn _, _ ->
                   {:ok,
                    %{
                      items: [Map.put(search_row(), :markdown, "must not be silently stripped")],
                      next_cursor: :done
                    }}
                 end
               },
               session(),
               %{}
             )

    assert {:error, :integrity_failure} =
             Api.search_notes(
               %{
                 search_notes: fn _, _ ->
                   {:ok,
                    %{
                      items: [%{search_row() | vault_id: Ecto.UUID.generate()}],
                      next_cursor: :done
                    }}
                 end
               },
               session(),
               %{}
             )

    assert {:error, :integrity_failure} =
             Api.trash_notes(
               %{
                 trash_notes: fn _, _ ->
                   {:ok,
                    %{
                      items: [
                        search_row()
                        |> Map.put(:vault_id, Ecto.UUID.generate())
                        |> Map.put(:deleted?, true)
                        |> Map.put(:deleted_at, @deleted_at)
                      ],
                      next_cursor: :done
                    }}
                 end
               },
               session(),
               %{}
             )

    assert {:error, :integrity_failure} =
             Api.get_note(
               %{get_note: fn _, _ -> {:ok, Map.put(canonical_row(), :unknown, true)} end},
               session(),
               @resource_id
             )

    for malformed <- [
          %{canonical_row() | canonical?: false},
          %{canonical_row() | deleted?: true, deleted_at: @deleted_at},
          %{canonical_row() | classification: :sensitive},
          %{canonical_row() | vault_id: Ecto.UUID.generate()}
        ] do
      assert {:error, :integrity_failure} =
               Api.get_note(
                 %{get_note: fn _, _ -> {:ok, malformed} end},
                 session(),
                 @resource_id
               )
    end

    assert {:error, :integrity_failure} =
             Api.get_note_version(
               %{
                 get_note_version: fn _, _, _ ->
                   {:ok, %{version_row() | vault_id: Ecto.UUID.generate()}}
                 end
               },
               session(),
               @resource_id,
               @base_id
             )

    assert {:error, :integrity_failure} =
             Api.get_note_conflict(
               %{
                 get_note_conflict: fn _, _, _ ->
                   {:ok,
                    %{
                      conflict: %{conflict_row() | resource_id: Ecto.UUID.generate()},
                      current: canonical_row(),
                      competing:
                        version_row(%{
                          resource_version_id: @competing_id,
                          revision: 2,
                          parent_version_id: @base_id,
                          conflict_state: :open
                        })
                    }}
                 end
               },
               session(),
               @resource_id,
               @conflict_id
             )

    assert {:error, :integrity_failure} =
             Api.get_note_conflict(
               %{
                 get_note_conflict: fn _, _, _ ->
                   {:ok,
                    %{
                      conflict: conflict_row(),
                      current: canonical_row(),
                      competing:
                        version_row(%{
                          resource_version_id: @competing_id,
                          revision: 2,
                          parent_version_id: @base_id,
                          conflict_state: :resolved
                        })
                    }}
                 end
               },
               session(),
               @resource_id,
               @conflict_id
             )

    assert {:error, :vault_locked} =
             Api.get_note(
               %{get_note: fn _, _ -> {:error, Error.new(:vault_locked)} end},
               session(),
               @resource_id
             )

    assert {:error, :not_found} =
             Api.get_note(
               %{get_note: fn _, _ -> {:error, Error.new(:not_found)} end},
               session(),
               @resource_id
             )
  end

  test "identifier arguments and session context fail closed before invocation" do
    parent = self()

    called = fn _args ->
      send(parent, :called)
      {:ok, %{}}
    end

    assert {:error, :invalid} =
             Api.get_note(%{get_note: fn a, b -> called.([a, b]) end}, session(), "bad")

    assert {:error, :invalid} =
             Api.get_note_version(
               %{get_note_version: fn a, b, c -> called.([a, b, c]) end},
               session(),
               @resource_id,
               "bad"
             )

    assert {:error, :invalid} =
             Api.get_note_conflict(
               %{get_note_conflict: fn a, b, c -> called.([a, b, c]) end},
               session(),
               @resource_id,
               "bad"
             )

    assert {:error, :integrity_failure} =
             Api.search_notes(
               %{search_notes: fn a, b -> called.([a, b]) end},
               %{session() | vault_id: "bad"},
               %{}
             )

    refute_received :called
  end

  defp session do
    %Session{
      session_id: @session_id,
      account_id: @account_id,
      principal_id: @principal_id,
      vault_id: @vault_id,
      expires_at: ~U[2026-08-18 12:00:00.000000Z],
      principal_authorization_epoch: 3,
      vault_authorization_epoch: 5,
      authorization_epoch: 3,
      unlocked?: true
    }
  end

  defp search_row do
    %{
      resource_id: @resource_id,
      resource_version_id: @version_id,
      vault_id: @vault_id,
      classification: :private,
      title: "Current note",
      revision: 1,
      updated_at: @updated_at,
      deleted?: false,
      open_conflict_count: 1
    }
  end

  defp canonical_row do
    %{
      resource_id: @resource_id,
      resource_version_id: @version_id,
      vault_id: @vault_id,
      classification: :private,
      title: "Current note",
      markdown: "# Current",
      revision: 1,
      updated_at: @updated_at,
      deleted_at: nil,
      deleted?: false,
      created_by_principal_id: @principal_id,
      inserted_at: @inserted_at,
      parent_version_id: @base_id,
      merge_parent_version_id: nil,
      canonical?: true,
      open_conflict_count: 1
    }
  end

  defp version_row(overrides \\ %{}) do
    Map.merge(
      %{
        resource_id: @resource_id,
        resource_version_id: @base_id,
        vault_id: @vault_id,
        classification: :private,
        title: "Initial",
        markdown: "# Initial",
        revision: 0,
        created_by_principal_id: @principal_id,
        inserted_at: @inserted_at,
        parent_version_id: nil,
        merge_parent_version_id: nil,
        canonical?: false,
        conflict_state: nil
      },
      overrides
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
    %{
      conflict_id: @conflict_id,
      resource_id: @resource_id,
      vault_id: @vault_id,
      classification: :private,
      base_version_id: @base_id,
      observed_canonical_version_id: @version_id,
      competing_version_id: @competing_id,
      state: :open,
      resolution_version_id: nil,
      created_at: @updated_at,
      resolved_at: nil
    }
  end
end
