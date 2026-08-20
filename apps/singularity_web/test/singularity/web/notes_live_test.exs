defmodule Singularity.Web.NotesLiveTest do
  use Singularity.Web.ConnCase, async: false

  import Phoenix.LiveViewTest

  @resource_id "019f9f0f-f384-78ef-8934-2d798944bd01"
  @version_id "019f9f0f-f384-78ef-8934-2d798944bd02"
  @base_id "019f9f0f-f384-78ef-8934-2d798944bd03"
  @competing_id "019f9f0f-f384-78ef-8934-2d798944bd04"
  @conflict_id "019f9f0f-f384-78ef-8934-2d798944bd05"
  @mutation_id "019f9f0f-f384-78ef-8934-2d798944bd06"
  @now ~U[2026-08-20 12:00:00.000000Z]

  setup %{conn: conn, runtime_api: runtime_api} do
    current_session = session(true)
    TestRuntimeApi.put(runtime_api, :sessions, %{"opaque-session" => {:ok, current_session}})
    TestRuntimeApi.put(runtime_api, :search_notes, {:ok, search_page()})

    {:ok, conn: put_session_id(conn, "opaque-session"), current_session: current_session}
  end

  test "mount is no-store and exposes only versioned summaries", %{conn: conn} do
    conn = get(conn, "/notes")
    assert conn.status == 200
    assert get_resp_header(conn, "cache-control") == ["no-store"]

    {:ok, view, html} = live(conn, "/notes")

    assert has_element?(
             view,
             "#notes-workspace[phx-hook='MountNotesWorkspace'][phx-update='ignore']"
           )

    assert html =~ "Fixture note"
    refute html =~ "# canonical markdown"

    [{"div", attributes, []}] = html |> Floki.parse_document!() |> Floki.find("#notes-workspace")
    props = attributes |> Map.new() |> Map.fetch!("data-props") |> JSON.decode!()

    assert Map.keys(props) |> Enum.sort() == ["filters", "summaries", "vault", "version"]
    assert props["version"] == 1
    assert props["vault"] == %{"ref" => session(true).vault_id}
    assert props["filters"] == %{"q" => ""}
    refute inspect(props) =~ "markdown"
  end

  test "anonymous and locked requests redirect before rendering workspace props", %{
    conn: conn,
    runtime_api: runtime_api
  } do
    anonymous = get(build_conn(), "/notes")
    assert redirected_to(anonymous) == "/login"
    refute anonymous.resp_body =~ "notes-workspace"

    TestRuntimeApi.put(runtime_api, :sessions, %{"opaque-session" => {:ok, session(false)}})
    locked = get(conn, "/notes")
    assert redirected_to(locked) == "/vault/unlock"
    refute locked.resp_body =~ "notes-workspace"
  end

  test "all note workspace events decode exactly and call only their runtime function", %{
    conn: conn,
    runtime_api: runtime_api,
    current_session: current_session
  } do
    {:ok, view, _html} = live(conn, "/notes")
    TestRuntimeApi.put(runtime_api, :search_notes, {:ok, search_page()})

    TestRuntimeApi.put(
      runtime_api,
      :trash_notes,
      {:ok, %NoteTrashPage{items: [], next_cursor: nil}}
    )

    TestRuntimeApi.put(runtime_api, :get_note, {:ok, note()})
    TestRuntimeApi.put(runtime_api, :get_note_version, {:ok, version()})
    TestRuntimeApi.put(runtime_api, :create_note, {:ok, note()})
    TestRuntimeApi.put(runtime_api, :save_note, {:ok, save_result()})
    TestRuntimeApi.put(runtime_api, :note_history, {:ok, history_page()})
    TestRuntimeApi.put(runtime_api, :get_note_conflict, {:ok, conflict_detail()})
    TestRuntimeApi.put(runtime_api, :merge_note, {:ok, save_result()})
    TestRuntimeApi.put(runtime_api, :delete_note, {:ok, true})
    TestRuntimeApi.put(runtime_api, :restore_note, {:ok, note()})
    baseline = length(TestRuntimeApi.calls(runtime_api))

    hook_reply(view, "note:search", %{
      "version" => 1,
      "q" => "fixture",
      "cursor" => nil,
      "limit" => 20
    })

    hook_reply(view, "note:trash", %{"version" => 1, "cursor" => nil, "limit" => 20})

    hook_reply(view, "note:open", %{
      "version" => 1,
      "resourceId" => @resource_id,
      "resourceVersionId" => nil
    })

    hook_reply(view, "note:open", %{
      "version" => 1,
      "resourceId" => @resource_id,
      "resourceVersionId" => @version_id
    })

    hook_reply(view, "note:create", %{
      "version" => 1,
      "mutationId" => @mutation_id,
      "title" => "Created",
      "markdown" => "# Created"
    })

    hook_reply(view, "note:save", %{
      "version" => 1,
      "mutationId" => @mutation_id,
      "resourceId" => @resource_id,
      "baseVersionId" => @base_id,
      "title" => "Saved",
      "markdown" => "# Saved"
    })

    hook_reply(view, "note:history", %{
      "version" => 1,
      "resourceId" => @resource_id,
      "cursor" => nil,
      "limit" => 20
    })

    hook_reply(view, "note:conflict", %{
      "version" => 1,
      "resourceId" => @resource_id,
      "conflictId" => @conflict_id
    })

    hook_reply(view, "note:merge", %{
      "version" => 1,
      "mutationId" => @mutation_id,
      "resourceId" => @resource_id,
      "conflictId" => @conflict_id,
      "expectedCurrentVersionId" => @version_id,
      "competingVersionId" => @competing_id,
      "title" => "Merged",
      "markdown" => "# Merged"
    })

    hook_reply(view, "note:delete", %{
      "version" => 1,
      "mutationId" => @mutation_id,
      "resourceId" => @resource_id,
      "expectedCurrentVersionId" => @version_id
    })

    hook_reply(view, "note:restore", %{
      "version" => 1,
      "mutationId" => @mutation_id,
      "resourceId" => @resource_id
    })

    hook_reply(view, "navigate", %{"version" => 1, "to" => "/assets"})

    calls = TestRuntimeApi.calls(runtime_api)
    assert length(calls) == baseline + 11
    assert {:search_notes, current_session, %{q: "fixture", cursor: nil, limit: 20}} in calls
    assert {:trash_notes, current_session, %{cursor: nil, limit: 20}} in calls
    assert {:get_note, current_session, @resource_id} in calls
    assert {:get_note_version, current_session, @resource_id, @version_id} in calls

    assert {:create_note, current_session,
            %{mutation_id: @mutation_id, title: "Created", markdown: "# Created"}} in calls

    assert {:save_note, current_session, @resource_id,
            %{
              mutation_id: @mutation_id,
              base_version_id: @base_id,
              title: "Saved",
              markdown: "# Saved"
            }} in calls

    assert {:note_history, current_session, @resource_id, %{cursor: nil, limit: 20}} in calls
    assert {:get_note_conflict, current_session, @resource_id, @conflict_id} in calls

    assert {:merge_note, current_session, @resource_id,
            %{
              mutation_id: @mutation_id,
              conflict_id: @conflict_id,
              expected_current_version_id: @version_id,
              competing_version_id: @competing_id,
              title: "Merged",
              markdown: "# Merged"
            }} in calls

    assert {:delete_note, current_session, @resource_id,
            %{mutation_id: @mutation_id, expected_current_version_id: @version_id}} in calls

    assert {:restore_note, current_session, @resource_id, %{mutation_id: @mutation_id}} in calls
  end

  test "malformed, oversized, classified, and unknown events fail without runtime calls", %{
    conn: conn,
    runtime_api: runtime_api
  } do
    {:ok, view, _html} = live(conn, "/notes")
    baseline = length(TestRuntimeApi.calls(runtime_api))

    shape_invalid =
      Enum.flat_map(valid_event_payloads(), fn {event, payload} ->
        [first_key | _rest] = Map.keys(payload)
        [{event, Map.delete(payload, first_key)}, {event, Map.put(payload, "unexpected", true)}]
      end)

    invalid =
      shape_invalid ++
        [
          {"note:search", %{"version" => 1, "q" => "", "cursor" => nil}},
          {"note:search", %{"version" => 1, "q" => "", "cursor" => nil, "limit" => 51}},
          {"note:open", %{"version" => 1, "resourceId" => "bad", "resourceVersionId" => nil}},
          {"note:create",
           %{
             "version" => 1,
             "mutationId" => @mutation_id,
             "title" => "x",
             "markdown" => String.duplicate("x", 1_048_577)
           }},
          {"note:search",
           %{
             "version" => 1,
             "q" => "",
             "cursor" => nil,
             "limit" => 20,
             "classification" => "private"
           }},
          {"unknown", %{}}
        ]

    Enum.each(invalid, fn {event, payload} ->
      assert hook_reply(view, event, payload) == %{ok: false, error: %{code: "invalid"}}
    end)

    assert length(TestRuntimeApi.calls(runtime_api)) == baseline
  end

  defp hook_reply(view, event, payload) do
    _html = render_hook(view, event, payload)
    %{proxy: {ref, _topic, _target}} = view
    assert_receive {^ref, {:reply, reply}}
    assert exact_reply?(event, reply)
    reply
  end

  defp exact_reply?(_event, %{ok: false, error: %{code: code}} = reply),
    do: map_size(reply) == 2 and is_binary(code)

  defp exact_reply?("navigate", %{ok: true} = reply), do: map_size(reply) == 1

  defp exact_reply?("note:delete", %{ok: true, accepted: accepted} = reply),
    do: map_size(reply) == 2 and is_boolean(accepted)

  defp exact_reply?(event, %{ok: true, result: result} = reply) when is_map(result) do
    expected =
      case event do
        name when name in ["note:search", "note:trash", "note:history"] ->
          ~w[items nextCursor]a

        name when name in ["note:save", "note:merge"] ->
          ~w[outcome canonical submittedVersionId conflictId]a

        "note:conflict" ->
          ~w[conflictId baseVersionId observedCanonicalVersionId current competing]a

        "note:open" ->
          note_keys =
            ~w[resourceId resourceVersionId title revision displayVersion updatedAt deleted openConflictCount markdown]a

          version_keys =
            ~w[resourceVersionId revision displayVersion createdByPrincipalId insertedAt parentVersionId mergeParentVersionId canonical conflictState resourceId title markdown]a

          if MapSet.new(Map.keys(result)) in [MapSet.new(note_keys), MapSet.new(version_keys)],
            do: Map.keys(result),
            else: []

        name when name in ["note:create", "note:restore"] ->
          ~w[resourceId resourceVersionId title revision displayVersion updatedAt deleted openConflictCount markdown]a
      end

    map_size(reply) == 2 and Enum.sort(Map.keys(result)) == Enum.sort(expected)
  end

  defp exact_reply?(_event, _reply), do: false

  defp valid_event_payloads do
    [
      {"note:search", %{"version" => 1, "q" => "", "cursor" => nil, "limit" => 20}},
      {"note:trash", %{"version" => 1, "cursor" => nil, "limit" => 20}},
      {"note:open", %{"version" => 1, "resourceId" => @resource_id, "resourceVersionId" => nil}},
      {"note:create",
       %{
         "version" => 1,
         "mutationId" => @mutation_id,
         "title" => "Title",
         "markdown" => "# body"
       }},
      {"note:save",
       %{
         "version" => 1,
         "mutationId" => @mutation_id,
         "resourceId" => @resource_id,
         "baseVersionId" => @base_id,
         "title" => "Title",
         "markdown" => "# body"
       }},
      {"note:history",
       %{"version" => 1, "resourceId" => @resource_id, "cursor" => nil, "limit" => 20}},
      {"note:conflict",
       %{"version" => 1, "resourceId" => @resource_id, "conflictId" => @conflict_id}},
      {"note:merge",
       %{
         "version" => 1,
         "mutationId" => @mutation_id,
         "resourceId" => @resource_id,
         "conflictId" => @conflict_id,
         "expectedCurrentVersionId" => @version_id,
         "competingVersionId" => @competing_id,
         "title" => "Title",
         "markdown" => "# body"
       }},
      {"note:delete",
       %{
         "version" => 1,
         "mutationId" => @mutation_id,
         "resourceId" => @resource_id,
         "expectedCurrentVersionId" => @version_id
       }},
      {"note:restore",
       %{"version" => 1, "mutationId" => @mutation_id, "resourceId" => @resource_id}},
      {"navigate", %{"version" => 1, "to" => "/notes"}}
    ]
  end

  defp summary do
    %NoteSummary{
      resource_id: @resource_id,
      resource_version_id: @version_id,
      title: "Fixture note",
      revision: 1,
      display_version: 2,
      updated_at: @now,
      deleted?: false,
      open_conflict_count: 1
    }
  end

  defp note,
    do: struct!(Note, Map.put(Map.from_struct(summary()), :markdown, "# canonical markdown"))

  defp search_page, do: %NoteSearchPage{items: [summary()], next_cursor: nil}

  defp version do
    %NoteVersion{
      resource_version_id: @version_id,
      revision: 1,
      display_version: 2,
      created_by_principal_id: session(true).principal_id,
      inserted_at: @now,
      parent_version_id: @base_id,
      merge_parent_version_id: nil,
      canonical?: true,
      conflict_state: nil,
      resource_id: @resource_id,
      title: "Fixture note",
      markdown: "# canonical markdown"
    }
  end

  defp history_page do
    item =
      struct!(
        NoteVersionSummary,
        Map.take(
          Map.from_struct(version()),
          Map.keys(NoteVersionSummary.__struct__()) -- [:__struct__]
        )
      )

    %NoteHistoryPage{items: [item], next_cursor: nil}
  end

  defp conflict_detail do
    competing = %{
      version()
      | resource_version_id: @competing_id,
        canonical?: false,
        conflict_state: :open
    }

    %NoteConflictDetail{
      conflict_id: @conflict_id,
      base_version_id: @base_id,
      observed_canonical_version_id: @version_id,
      current: version(),
      competing: competing
    }
  end

  defp save_result,
    do: %NoteSaveResult{
      outcome: :saved,
      canonical: note(),
      submitted_version_id: @version_id,
      conflict_id: nil
    }
end
