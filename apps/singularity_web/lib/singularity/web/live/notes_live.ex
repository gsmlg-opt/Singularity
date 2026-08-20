defmodule Singularity.Web.NotesLive do
  use Singularity.Web, :live_view

  alias Singularity.Runtime.DTO.Note
  alias Singularity.Runtime.DTO.NoteConflictDetail
  alias Singularity.Runtime.DTO.NoteHistoryPage
  alias Singularity.Runtime.DTO.NoteSaveResult
  alias Singularity.Runtime.DTO.NoteSearchPage
  alias Singularity.Runtime.DTO.NoteSummary
  alias Singularity.Runtime.DTO.NoteTrashPage
  alias Singularity.Runtime.DTO.NoteVersion
  alias Singularity.Runtime.DTO.Session
  alias Singularity.Web.Auth

  @version 1
  @max_query 1_024
  @max_cursor 2_048
  @max_title 255
  @max_markdown 1_048_576
  @navigation_paths ~w[/assets /notes /activity /audit /backups /settings]
  @public_errors ~w[unauthenticated vault_locked forbidden not_found conflict invalid storage_unavailable]a
  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/

  @impl true
  def mount(_params, _session, socket) do
    %Session{} = current = socket.assigns.current_session
    params = %{q: "", cursor: nil, limit: 50}

    page =
      case safe_runtime(:search_notes, [current, params]) do
        {:ok, %NoteSearchPage{} = page} -> page
        _failure -> %NoteSearchPage{items: [], next_cursor: nil}
      end

    {:ok,
     socket
     |> assign(:page_title, "Notes")
     |> assign(:initial_props, initial_props(current, page))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.page title="Notes">
      <div
        id="notes-workspace"
        phx-hook="MountNotesWorkspace"
        phx-update="ignore"
        data-props={JSON.encode!(@initial_props)}
      >
      </div>
    </.page>
    """
  end

  @impl true
  def handle_event("note:search", params, socket),
    do: page_event(:search_notes, params, socket, &search_request/1)

  def handle_event("note:trash", params, socket),
    do: page_event(:trash_notes, params, socket, &trash_request/1)

  def handle_event("note:open", params, socket) do
    with {:ok, resource_id, version_id} <- open_request(params),
         result <- open_note(socket.assigns.current_session, resource_id, version_id),
         {:ok, encoded} <- encode_open(result) do
      success(socket, encoded)
    else
      result -> error_reply(socket, result)
    end
  end

  def handle_event("note:create", params, socket),
    do: mutation_event(:create_note, params, socket, &create_request/1)

  def handle_event("note:save", params, socket),
    do: resource_mutation_event(:save_note, params, socket, &save_request/1)

  def handle_event("note:history", params, socket) do
    with {:ok, resource_id, runtime_params} <- history_request(params),
         {:ok, %NoteHistoryPage{} = page} <-
           safe_runtime(:note_history, [
             socket.assigns.current_session,
             resource_id,
             runtime_params
           ]),
         {:ok, encoded} <- encode_history_page(page) do
      success(socket, encoded)
    else
      result -> error_reply(socket, result)
    end
  end

  def handle_event("note:conflict", params, socket) do
    with {:ok, resource_id, conflict_id} <- conflict_request(params),
         {:ok, %NoteConflictDetail{} = detail} <-
           safe_runtime(:get_note_conflict, [
             socket.assigns.current_session,
             resource_id,
             conflict_id
           ]),
         {:ok, encoded} <- encode_conflict_detail(detail) do
      success(socket, encoded)
    else
      result -> error_reply(socket, result)
    end
  end

  def handle_event("note:merge", params, socket),
    do: resource_mutation_event(:merge_note, params, socket, &merge_request/1)

  def handle_event("note:delete", params, socket) do
    with {:ok, resource_id, attrs} <- delete_request(params),
         {:ok, accepted} when is_boolean(accepted) <-
           safe_runtime(:delete_note, [socket.assigns.current_session, resource_id, attrs]) do
      {:reply, %{ok: true, accepted: accepted}, socket}
    else
      result -> error_reply(socket, result)
    end
  end

  def handle_event("note:restore", params, socket),
    do: resource_mutation_event(:restore_note, params, socket, &restore_request/1)

  def handle_event("navigate", params, socket) do
    case navigation_request(params) do
      {:ok, path} ->
        send(self(), {:notes_navigate, path})
        {:reply, %{ok: true}, socket}

      error ->
        error_reply(socket, error)
    end
  end

  def handle_event(_event, _params, socket), do: error_reply(socket, {:error, :invalid})

  @impl true
  def handle_info({:notes_navigate, path}, socket) when path in @navigation_paths,
    do: {:noreply, push_navigate(socket, to: path)}

  defp page_event(function, params, socket, decoder) do
    with {:ok, runtime_params} <- decoder.(params),
         {:ok, page} <- safe_runtime(function, [socket.assigns.current_session, runtime_params]),
         {:ok, encoded} <- encode_page(page) do
      success(socket, encoded)
    else
      result -> error_reply(socket, result)
    end
  end

  defp mutation_event(function, params, socket, decoder) do
    with {:ok, attrs} <- decoder.(params),
         {:ok, result} <- safe_runtime(function, [socket.assigns.current_session, attrs]),
         {:ok, encoded} <- encode_mutation(result) do
      success(socket, encoded)
    else
      result -> error_reply(socket, result)
    end
  end

  defp resource_mutation_event(function, params, socket, decoder) do
    with {:ok, resource_id, attrs} <- decoder.(params),
         {:ok, result} <-
           safe_runtime(function, [socket.assigns.current_session, resource_id, attrs]),
         {:ok, encoded} <- encode_mutation(result) do
      success(socket, encoded)
    else
      result -> error_reply(socket, result)
    end
  end

  defp success(socket, result), do: {:reply, %{ok: true, result: result}, socket}

  defp search_request(
         %{"version" => @version, "q" => q, "cursor" => cursor, "limit" => limit} = params
       ) do
    with true <- exact?(params, ~w[version q cursor limit]),
         {:ok, q} <- query(q),
         {:ok, cursor} <- cursor(cursor),
         :ok <- limit(limit) do
      {:ok, %{q: q, cursor: cursor, limit: limit}}
    else
      _invalid -> {:error, :invalid}
    end
  end

  defp search_request(_params), do: {:error, :invalid}

  defp trash_request(%{"version" => @version, "cursor" => cursor, "limit" => limit} = params) do
    with true <- exact?(params, ~w[version cursor limit]),
         {:ok, cursor} <- cursor(cursor),
         :ok <- limit(limit) do
      {:ok, %{cursor: cursor, limit: limit}}
    else
      _invalid -> {:error, :invalid}
    end
  end

  defp trash_request(_params), do: {:error, :invalid}

  defp open_request(
         %{"version" => @version, "resourceId" => id, "resourceVersionId" => version} = params
       ) do
    with true <- exact?(params, ~w[version resourceId resourceVersionId]),
         true <- uuid?(id),
         true <- is_nil(version) or uuid?(version) do
      {:ok, id, version}
    else
      _invalid -> {:error, :invalid}
    end
  end

  defp open_request(_params), do: {:error, :invalid}

  defp create_request(
         %{
           "version" => @version,
           "mutationId" => mutation,
           "title" => title,
           "markdown" => markdown
         } = params
       ) do
    with true <- exact?(params, ~w[version mutationId title markdown]),
         true <- uuid?(mutation),
         {:ok, title} <- title(title),
         true <- markdown?(markdown) do
      {:ok, %{mutation_id: mutation, title: title, markdown: markdown}}
    else
      _invalid -> {:error, :invalid}
    end
  end

  defp create_request(_params), do: {:error, :invalid}

  defp save_request(
         %{
           "version" => @version,
           "mutationId" => mutation,
           "resourceId" => resource,
           "baseVersionId" => base,
           "title" => title,
           "markdown" => markdown
         } = params
       ) do
    with true <- exact?(params, ~w[version mutationId resourceId baseVersionId title markdown]),
         true <- Enum.all?([mutation, resource, base], &uuid?/1),
         {:ok, title} <- title(title),
         true <- markdown?(markdown) do
      {:ok, resource,
       %{mutation_id: mutation, base_version_id: base, title: title, markdown: markdown}}
    else
      _invalid -> {:error, :invalid}
    end
  end

  defp save_request(_params), do: {:error, :invalid}

  defp history_request(
         %{"version" => @version, "resourceId" => resource, "cursor" => cursor, "limit" => limit} =
           params
       ) do
    with true <- exact?(params, ~w[version resourceId cursor limit]),
         true <- uuid?(resource),
         {:ok, cursor} <- cursor(cursor),
         :ok <- limit(limit) do
      {:ok, resource, %{cursor: cursor, limit: limit}}
    else
      _invalid -> {:error, :invalid}
    end
  end

  defp history_request(_params), do: {:error, :invalid}

  defp conflict_request(
         %{"version" => @version, "resourceId" => resource, "conflictId" => conflict} = params
       ) do
    if exact?(params, ~w[version resourceId conflictId]) and uuid?(resource) and uuid?(conflict),
      do: {:ok, resource, conflict},
      else: {:error, :invalid}
  end

  defp conflict_request(_params), do: {:error, :invalid}

  defp merge_request(
         %{
           "version" => @version,
           "mutationId" => mutation,
           "resourceId" => resource,
           "conflictId" => conflict,
           "expectedCurrentVersionId" => expected,
           "competingVersionId" => competing,
           "title" => title,
           "markdown" => markdown
         } = params
       ) do
    keys =
      ~w[version mutationId resourceId conflictId expectedCurrentVersionId competingVersionId title markdown]

    with true <- exact?(params, keys),
         true <- Enum.all?([mutation, resource, conflict, expected, competing], &uuid?/1),
         {:ok, title} <- title(title),
         true <- markdown?(markdown) do
      {:ok, resource,
       %{
         mutation_id: mutation,
         conflict_id: conflict,
         expected_current_version_id: expected,
         competing_version_id: competing,
         title: title,
         markdown: markdown
       }}
    else
      _invalid -> {:error, :invalid}
    end
  end

  defp merge_request(_params), do: {:error, :invalid}

  defp delete_request(
         %{
           "version" => @version,
           "mutationId" => mutation,
           "resourceId" => resource,
           "expectedCurrentVersionId" => expected
         } = params
       ) do
    if exact?(params, ~w[version mutationId resourceId expectedCurrentVersionId]) and
         Enum.all?([mutation, resource, expected], &uuid?/1),
       do: {:ok, resource, %{mutation_id: mutation, expected_current_version_id: expected}},
       else: {:error, :invalid}
  end

  defp delete_request(_params), do: {:error, :invalid}

  defp restore_request(
         %{"version" => @version, "mutationId" => mutation, "resourceId" => resource} = params
       ) do
    if exact?(params, ~w[version mutationId resourceId]) and uuid?(mutation) and uuid?(resource),
      do: {:ok, resource, %{mutation_id: mutation}},
      else: {:error, :invalid}
  end

  defp restore_request(_params), do: {:error, :invalid}

  defp navigation_request(%{"version" => @version, "to" => path} = params) do
    if exact?(params, ~w[version to]) and path in @navigation_paths,
      do: {:ok, path},
      else: {:error, :invalid}
  end

  defp navigation_request(_params), do: {:error, :invalid}

  defp open_note(session, resource_id, nil), do: safe_runtime(:get_note, [session, resource_id])

  defp open_note(session, resource_id, version_id),
    do: safe_runtime(:get_note_version, [session, resource_id, version_id])

  defp initial_props(session, page) do
    {:ok, encoded} = encode_search_page(page)

    %{
      version: @version,
      vault: %{ref: session.vault_id},
      filters: %{q: ""},
      summaries: encoded.items
    }
  end

  defp encode_page(%NoteSearchPage{} = page), do: encode_search_page(page)
  defp encode_page(%NoteTrashPage{} = page), do: encode_trash_page(page)
  defp encode_page(_page), do: {:error, :storage_unavailable}
  defp encode_open({:ok, result}), do: encode_mutation(result)
  defp encode_open(result), do: result
  defp encode_mutation(%Note{} = note), do: {:ok, encode_note(note)}
  defp encode_mutation(%NoteVersion{} = version), do: {:ok, encode_version(version)}
  defp encode_mutation(%NoteSaveResult{} = result), do: {:ok, encode_save_result(result)}
  defp encode_mutation(_result), do: {:error, :storage_unavailable}

  defp encode_search_page(%NoteSearchPage{items: items, next_cursor: cursor}) do
    with {:ok, items} <- encode_summaries(items), do: {:ok, %{items: items, nextCursor: cursor}}
  end

  defp encode_trash_page(%NoteTrashPage{items: items, next_cursor: cursor}) do
    encoded =
      Enum.map(items, fn %{summary: summary, deleted_at: deleted_at} ->
        %{summary: encode_summary(summary), deletedAt: DateTime.to_iso8601(deleted_at)}
      end)

    {:ok, %{items: encoded, nextCursor: cursor}}
  rescue
    _error -> {:error, :storage_unavailable}
  end

  defp encode_history_page(%NoteHistoryPage{items: items, next_cursor: cursor}) do
    {:ok, %{items: Enum.map(items, &encode_version_summary/1), nextCursor: cursor}}
  rescue
    _error -> {:error, :storage_unavailable}
  end

  defp encode_summaries(items) do
    if Enum.all?(items, &match?(%NoteSummary{}, &1)),
      do: {:ok, Enum.map(items, &encode_summary/1)},
      else: {:error, :storage_unavailable}
  end

  defp encode_summary(summary),
    do: %{
      resourceId: summary.resource_id,
      resourceVersionId: summary.resource_version_id,
      title: summary.title,
      revision: summary.revision,
      displayVersion: summary.display_version,
      updatedAt: DateTime.to_iso8601(summary.updated_at),
      deleted: summary.deleted?,
      openConflictCount: summary.open_conflict_count
    }

  defp encode_note(note), do: Map.put(encode_summary(note), :markdown, note.markdown)

  defp encode_version_summary(version),
    do: %{
      resourceVersionId: version.resource_version_id,
      revision: version.revision,
      displayVersion: version.display_version,
      createdByPrincipalId: version.created_by_principal_id,
      insertedAt: DateTime.to_iso8601(version.inserted_at),
      parentVersionId: version.parent_version_id,
      mergeParentVersionId: version.merge_parent_version_id,
      canonical: version.canonical?,
      conflictState: atom_string(version.conflict_state)
    }

  defp encode_version(version),
    do:
      encode_version_summary(version)
      |> Map.merge(%{
        resourceId: version.resource_id,
        title: version.title,
        markdown: version.markdown
      })

  defp encode_save_result(result),
    do: %{
      outcome: Atom.to_string(result.outcome),
      canonical: encode_note(result.canonical),
      submittedVersionId: result.submitted_version_id,
      conflictId: result.conflict_id
    }

  defp encode_conflict_detail(detail),
    do:
      {:ok,
       %{
         conflictId: detail.conflict_id,
         baseVersionId: detail.base_version_id,
         observedCanonicalVersionId: detail.observed_canonical_version_id,
         current: encode_version(detail.current),
         competing: encode_version(detail.competing)
       }}

  defp atom_string(nil), do: nil
  defp atom_string(value), do: Atom.to_string(value)

  defp safe_runtime(function, arguments) do
    Auth.call_runtime(function, arguments)
  rescue
    _error -> {:error, :storage_unavailable}
  catch
    _kind, _reason -> {:error, :storage_unavailable}
  end

  defp error_reply(socket, result) do
    code =
      case result do
        {:error, reason} when reason in @public_errors -> reason
        reason when reason in @public_errors -> reason
        _failure -> :storage_unavailable
      end

    {:reply, %{ok: false, error: %{code: Atom.to_string(code)}}, socket}
  end

  defp exact?(map, keys), do: is_map(map) and Enum.sort(Map.keys(map)) == Enum.sort(keys)
  defp uuid?(value), do: is_binary(value) and Regex.match?(@uuid, value)
  defp limit(value) when is_integer(value) and value in 1..50, do: :ok
  defp limit(_value), do: {:error, :invalid}
  defp cursor(nil), do: {:ok, nil}

  defp cursor(value) when is_binary(value),
    do: if(safe_nonblank?(value, @max_cursor), do: {:ok, value}, else: {:error, :invalid})

  defp cursor(_value), do: {:error, :invalid}

  defp query(value) when is_binary(value),
    do:
      if(safe_text?(value) and byte_size(value) <= @max_query,
        do: {:ok, String.trim(value)},
        else: {:error, :invalid}
      )

  defp query(_value), do: {:error, :invalid}

  defp title(value) when is_binary(value) do
    value = String.trim(value)
    if safe_nonblank?(value, @max_title), do: {:ok, value}, else: {:error, :invalid}
  end

  defp title(_value), do: {:error, :invalid}

  defp markdown?(value),
    do: is_binary(value) and byte_size(value) <= @max_markdown and safe_text?(value)

  defp safe_nonblank?(value, max),
    do:
      is_binary(value) and byte_size(value) <= max and safe_text?(value) and
        String.trim(value) != ""

  defp safe_text?(value), do: String.valid?(value) and :binary.match(value, <<0>>) == :nomatch
end
