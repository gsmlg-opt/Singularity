defmodule Singularity.Web.AssetsLive do
  use Singularity.Web, :live_view

  alias Singularity.Runtime.DTO.AssetSummary
  alias Singularity.Runtime.DTO.SearchPage
  alias Singularity.Runtime.DTO.Session
  alias Singularity.Runtime.DTO.UploadGrant
  alias Singularity.Web.Auth

  @version 1
  @default_max_upload_bytes 512 * 1024 * 1024
  @accepted_upload_types ["application/pdf", "image/jpeg", "image/png"]
  @navigation_paths ["/assets", "/activity", "/audit", "/backups", "/settings"]
  @classification_labels ["private", "sensitive", "restricted"]
  @max_query_bytes 1_024
  @max_cursor_bytes 2_048
  @max_filter_bytes 255
  @max_opaque_bytes 1_024
  @max_snapshot_attempts 3
  @snapshot_retry_delay_ms 250
  @snapshot_rearm_delay_ms 5_000
  @pending_upload_grant_max_ttl_ms 300_000
  @pending_upload_grant_lead_ms 1_000
  @pending_upload_grant_retry_ms 1_000
  @pending_upload_grant_max_attempts 3
  @workspace_error_message "Asset workspace is unavailable."
  @uuid ~r/\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/
  @public_errors [
    :unauthenticated,
    :vault_locked,
    :forbidden,
    :not_found,
    :conflict,
    :invalid,
    :upload_expired,
    :upload_too_large,
    :unsupported_media_type,
    :integrity_failure,
    :storage_unavailable
  ]

  @impl true
  def mount(_params, _live_session, %Phoenix.LiveView.Socket{} = socket) do
    %Session{} = session = socket.assigns.current_session
    filters = empty_filters()

    if connected?(socket) do
      mount_connected(socket, session, filters)
    else
      {page, workspace_error} = fetch_initial_page(session, filters)

      {:ok,
       assign_workspace(socket, session, page, filters,
         sequence: 0,
         upload_csrf: nil,
         snapshot_ready: false,
         snapshot_attempt: 0,
         snapshot_generation: make_ref(),
         snapshot_recovery_enabled: false,
         refresh_attempt: 0,
         refresh_generation: make_ref(),
         refresh_retry_enabled: false,
         pending_upload_grant: nil,
         workspace_error: workspace_error
       )}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.page title="Assets">
      <section
        :if={@workspace_error}
        id="asset-workspace-error"
        role="alert"
        aria-live="assertive"
      >
        <h2>Asset workspace unavailable</h2>
        <p>{@workspace_error}</p>
      </section>
      <div
        :if={is_nil(@workspace_error)}
        id="asset-workspace"
        phx-hook="MountAssetWorkspace"
        phx-update="ignore"
        data-props={JSON.encode!(@initial_props)}
      >
      </div>
    </.page>
    """
  end

  @impl true
  def handle_event(event, _params, %{assigns: %{snapshot_ready: false}} = socket)
      when event in ["asset:search", "asset:page"] do
    error_reply(socket, {:error, :storage_unavailable})
  end

  def handle_event("asset:search", params, socket) do
    with {:ok, filters, runtime_params} <- search_request(params),
         {:ok, assets} <- fetch_page(socket.assigns.current_session, runtime_params) do
      socket = socket |> clear_refresh_retry() |> assign(:filters, filters)
      {sequence, socket} = next_sequence(socket)

      reply = %{
        ok: true,
        sequence: sequence,
        filters: filters,
        assets: assets
      }

      {:reply, reply, socket}
    else
      result -> error_reply(socket, result)
    end
  end

  def handle_event("asset:page", params, socket) do
    with {:ok, filters, runtime_params} <- page_request(params),
         true <- filters == socket.assigns.filters,
         {:ok, assets} <- fetch_page(socket.assigns.current_session, runtime_params) do
      {sequence, socket} = next_sequence(socket)
      {:reply, %{ok: true, sequence: sequence, assets: assets}, socket}
    else
      result -> error_reply(socket, result)
    end
  end

  def handle_event("upload:grant", params, socket) do
    case upload_grant_request(params) do
      {:ok, attrs} ->
        with {:ok, socket} <- retire_pending_upload_grant(socket) do
          issue_upload_grant(socket, attrs)
        else
          result -> error_reply(socket, result)
        end

      result ->
        error_reply(socket, result)
    end
  end

  def handle_event("upload:cancel", params, socket) do
    with {:ok, grant_id} <- upload_cancel_request(params),
         true <- socket.assigns.pending_upload_grant == grant_id,
         {:ok, accepted} when is_boolean(accepted) <-
           safe_runtime(:cancel_upload_grant, [
             socket.assigns.current_session,
             grant_id
           ]) do
      {:reply, %{ok: true, accepted: accepted}, clear_pending_upload_grant(socket)}
    else
      result -> error_reply(socket, result)
    end
  end

  def handle_event("asset:retry", params, socket) do
    handle_mutation(:retry_asset, params, socket)
  end

  def handle_event("asset:delete", params, socket) do
    handle_mutation(:delete_asset, params, socket)
  end

  def handle_event("navigate", params, socket) do
    case navigation_request(params) do
      {:ok, path} ->
        send(self(), {:asset_workspace_navigate, path})
        {:reply, %{ok: true}, socket}

      error ->
        error_reply(socket, error)
    end
  end

  def handle_event(_event, _params, socket), do: error_reply(socket, {:error, :invalid})

  @impl true
  def handle_info({:asset_workspace_navigate, path}, socket)
      when path in @navigation_paths do
    {:noreply, push_navigate(socket, to: path)}
  end

  def handle_info({:asset_workspace_recover_snapshot, generation, attempt}, socket)
      when is_reference(generation) and is_integer(attempt) do
    expected_attempt = socket.assigns.snapshot_attempt + 1

    if socket.assigns.snapshot_recovery_enabled and
         not socket.assigns.snapshot_ready and
         generation == socket.assigns.snapshot_generation and
         attempt == expected_attempt and attempt <= @max_snapshot_attempts do
      {:noreply, recover_snapshot(socket, attempt)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:asset_workspace_recover_snapshot, _generation, _attempt}, socket),
    do: {:noreply, socket}

  def handle_info({:asset_workspace_recover_snapshot, _legacy_attempt}, socket),
    do: {:noreply, socket}

  def handle_info({:asset_workspace_rearm_snapshot, generation}, socket)
      when is_reference(generation) do
    if socket.assigns.snapshot_recovery_enabled and
         not socket.assigns.snapshot_ready and
         generation == socket.assigns.snapshot_generation and
         socket.assigns.snapshot_attempt == @max_snapshot_attempts do
      socket =
        assign(socket,
          snapshot_generation: make_ref(),
          snapshot_attempt: 0
        )

      {:noreply, recover_snapshot(socket, 1)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:asset_workspace_rearm_snapshot, _generation}, socket),
    do: {:noreply, socket}

  def handle_info({:asset_workspace_refresh_snapshot, generation, attempt}, socket)
      when is_reference(generation) and is_integer(attempt) do
    expected_attempt = socket.assigns.refresh_attempt + 1

    if socket.assigns.refresh_retry_enabled and
         is_nil(socket.assigns.workspace_error) and
         generation == socket.assigns.refresh_generation and
         attempt == expected_attempt and attempt <= @max_snapshot_attempts do
      {:noreply, refresh_canonical_snapshot(socket, generation, attempt)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:asset_workspace_refresh_snapshot, _generation, _attempt}, socket),
    do: {:noreply, socket}

  def handle_info(
        {:asset_workspace_expire_upload_grant, grant_id, attempt},
        socket
      )
      when is_integer(attempt) and attempt >= 1 and
             attempt <= @pending_upload_grant_max_attempts do
    if socket.assigns.pending_upload_grant == grant_id do
      case safe_runtime(:cancel_upload_grant, [
             socket.assigns.current_session,
             grant_id
           ]) do
        {:ok, accepted} when is_boolean(accepted) ->
          {:noreply, clear_pending_upload_grant(socket)}

        {:error, :storage_unavailable}
        when attempt < @pending_upload_grant_max_attempts ->
          schedule_pending_upload_grant(
            grant_id,
            attempt + 1,
            @pending_upload_grant_retry_ms
          )

          {:noreply, socket}

        {:error, :storage_unavailable} ->
          {:noreply, socket}

        _terminal_failure ->
          {:noreply, clear_pending_upload_grant(socket)}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_info({:asset_workspace_expire_upload_grant, _grant_id, _attempt}, socket),
    do: {:noreply, socket}

  def handle_info(
        {:asset_changed, %{vault_id: vault_id, asset_id: asset_id} = hint},
        socket
      )
      when map_size(hint) == 2 do
    session = socket.assigns.current_session

    if socket.assigns.snapshot_ready and is_nil(socket.assigns.workspace_error) and
         vault_id == session.vault_id and valid_uuid?(asset_id) do
      generation = make_ref()

      socket =
        assign(socket,
          refresh_attempt: 0,
          refresh_generation: generation,
          refresh_retry_enabled: true
        )

      {:noreply, refresh_canonical_snapshot(socket, generation, 1)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:asset_changed, _malformed_hint}, socket),
    do: {:noreply, socket}

  @impl true
  def terminate(
        _reason,
        %Phoenix.LiveView.Socket{
          assigns: %{
            current_session: %Session{} = session,
            pending_upload_grant: grant_id
          }
        }
      )
      when is_binary(grant_id) do
    _best_effort = safe_runtime(:cancel_upload_grant, [session, grant_id])
    :ok
  end

  def terminate(_reason, _socket), do: :ok

  defp refresh_canonical_snapshot(socket, generation, attempt) do
    session = socket.assigns.current_session
    socket = assign(socket, :refresh_attempt, attempt)

    case fetch_page(session, runtime_params(socket.assigns.filters)) do
      {:ok, page} ->
        {sequence, socket} = next_sequence(socket)

        socket
        |> clear_refresh_retry()
        |> push_event("asset:snapshot", %{
          version: @version,
          sequence: sequence,
          assets: page
        })

      {:error, :storage_unavailable} when attempt < @max_snapshot_attempts ->
        schedule_refresh_retry(generation, attempt + 1)
        socket

      terminal_error ->
        terminal_workspace(socket, terminal_error)
    end
  end

  defp issue_upload_grant(socket, attrs) do
    with csrf when is_binary(csrf) <- socket.assigns.upload_csrf,
         {:ok, token, %UploadGrant{} = grant} <-
           safe_runtime(:create_upload_grant, [
             socket.assigns.current_session,
             attrs,
             csrf
           ]),
         {:ok, expires_at} <- validate_grant(grant, token, attrs) do
      socket = track_pending_upload_grant(socket, grant)

      {:reply,
       %{
         ok: true,
         grantId: grant.grant_id,
         uploadToken: token,
         uploadUrl: "/api/v1/uploads/#{grant.grant_id}",
         expiresAt: expires_at
       }, socket}
    else
      result -> error_reply(socket, result)
    end
  end

  defp retire_pending_upload_grant(%{assigns: %{pending_upload_grant: nil}} = socket),
    do: {:ok, socket}

  defp retire_pending_upload_grant(socket) do
    case safe_runtime(:cancel_upload_grant, [
           socket.assigns.current_session,
           socket.assigns.pending_upload_grant
         ]) do
      {:ok, accepted} when is_boolean(accepted) ->
        {:ok, clear_pending_upload_grant(socket)}

      result ->
        result
    end
  end

  defp track_pending_upload_grant(socket, %UploadGrant{} = grant) do
    delay =
      grant.expires_at
      |> DateTime.diff(DateTime.utc_now(), :millisecond)
      |> Kernel.-(@pending_upload_grant_lead_ms)
      |> max(0)
      |> min(@pending_upload_grant_max_ttl_ms)

    schedule_pending_upload_grant(grant.grant_id, 1, delay)

    assign(socket, :pending_upload_grant, grant.grant_id)
  end

  defp schedule_pending_upload_grant(grant_id, attempt, delay) do
    Process.send_after(
      self(),
      {:asset_workspace_expire_upload_grant, grant_id, attempt},
      delay
    )
  end

  defp clear_pending_upload_grant(socket),
    do: assign(socket, :pending_upload_grant, nil)

  defp mount_connected(socket, session, filters) do
    socket =
      assign_workspace(socket, session, empty_page(), filters,
        sequence: 0,
        upload_csrf: connect_csrf(socket),
        snapshot_ready: false,
        snapshot_attempt: 0,
        snapshot_generation: make_ref(),
        snapshot_recovery_enabled: true,
        refresh_attempt: 0,
        refresh_generation: make_ref(),
        refresh_retry_enabled: false,
        pending_upload_grant: nil,
        workspace_error: nil
      )

    {:ok, recover_snapshot(socket, 1)}
  end

  defp recover_snapshot(socket, attempt) do
    session = socket.assigns.current_session
    filters = socket.assigns.filters
    socket = assign(socket, :snapshot_attempt, attempt)

    with :ok <- safe_runtime(:subscribe_assets, [session]),
         {:ok, page} <- fetch_page(session, runtime_params(filters)) do
      socket =
        assign_workspace(socket, session, page, filters,
          snapshot_ready: true,
          snapshot_attempt: attempt,
          snapshot_recovery_enabled: false,
          refresh_attempt: 0,
          refresh_generation: make_ref(),
          refresh_retry_enabled: false,
          workspace_error: nil
        )

      {sequence, socket} = next_sequence(socket)

      push_event(socket, "asset:snapshot", %{
        version: @version,
        sequence: sequence,
        assets: page
      })
    else
      {:error, :storage_unavailable} ->
        schedule_snapshot_recovery(socket, attempt)
        socket

      terminal_error ->
        terminal_workspace(socket, terminal_error)
    end
  end

  defp schedule_snapshot_recovery(socket, attempt)
       when attempt < @max_snapshot_attempts do
    Process.send_after(
      self(),
      {:asset_workspace_recover_snapshot, socket.assigns.snapshot_generation, attempt + 1},
      @snapshot_retry_delay_ms
    )
  end

  defp schedule_snapshot_recovery(socket, @max_snapshot_attempts) do
    Process.send_after(
      self(),
      {:asset_workspace_rearm_snapshot, socket.assigns.snapshot_generation},
      @snapshot_rearm_delay_ms
    )
  end

  defp schedule_snapshot_recovery(_socket, _attempt), do: :ok

  defp schedule_refresh_retry(generation, attempt) do
    Process.send_after(
      self(),
      {:asset_workspace_refresh_snapshot, generation, attempt},
      @snapshot_retry_delay_ms
    )
  end

  defp handle_mutation(function, params, socket)
       when function in [:retry_asset, :delete_asset] do
    with {:ok, asset_id, state_revision} <- mutation_request(params),
         {:ok, accepted} when is_boolean(accepted) <-
           safe_runtime(function, [
             socket.assigns.current_session,
             asset_id,
             state_revision
           ]) do
      {:reply, %{ok: true, accepted: accepted}, socket}
    else
      result -> error_reply(socket, result)
    end
  end

  defp search_request(
         %{
           "version" => @version,
           "q" => q,
           "state" => state,
           "mediaType" => media_type
         } = params
       ) do
    with true <- exact_keys?(params, ~w[version q state mediaType]),
         {:ok, q} <- query(q),
         {:ok, normalized_state, state_atom} <- state(state),
         {:ok, media_type} <- search_media_type(media_type) do
      filters = %{q: q, state: normalized_state, mediaType: media_type}
      {:ok, filters, runtime_params(filters, state_atom)}
    else
      _invalid -> {:error, :invalid}
    end
  end

  defp search_request(_params), do: {:error, :invalid}

  defp page_request(
         %{
           "version" => @version,
           "cursor" => cursor,
           "q" => q,
           "state" => state,
           "mediaType" => media_type
         } = params
       ) do
    with true <- exact_keys?(params, ~w[version cursor q state mediaType]),
         {:ok, cursor} <- cursor(cursor),
         {:ok, q} <- query(q),
         {:ok, normalized_state, state_atom} <- state(state),
         {:ok, media_type} <- search_media_type(media_type) do
      filters = %{q: q, state: normalized_state, mediaType: media_type}
      runtime_params = filters |> runtime_params(state_atom) |> Map.put(:cursor, cursor)
      {:ok, filters, runtime_params}
    else
      _invalid -> {:error, :invalid}
    end
  end

  defp page_request(_params), do: {:error, :invalid}

  defp upload_grant_request(
         %{
           "version" => @version,
           "filename" => filename,
           "size" => size,
           "mediaType" => media_type,
           "idempotencyKey" => idempotency_key
         } = params
       ) do
    with true <-
           exact_keys?(
             params,
             ~w[version filename size mediaType idempotencyKey]
           ),
         true <- safe_nonblank?(filename, @max_opaque_bytes),
         true <- is_integer(size) and size >= 0,
         true <- media_type in @accepted_upload_types,
         true <- safe_nonblank?(idempotency_key, @max_opaque_bytes) do
      {:ok,
       %{
         filename: filename,
         size: size,
         declared_media_type: media_type,
         idempotency_key: idempotency_key
       }}
    else
      _invalid -> {:error, :invalid}
    end
  end

  defp upload_grant_request(_params), do: {:error, :invalid}

  defp upload_cancel_request(%{"version" => @version, "grantId" => grant_id} = params) do
    if exact_keys?(params, ~w[version grantId]) and valid_uuid?(grant_id),
      do: {:ok, grant_id},
      else: {:error, :invalid}
  end

  defp upload_cancel_request(_params), do: {:error, :invalid}

  defp mutation_request(
         %{
           "version" => @version,
           "assetId" => asset_id,
           "stateRevision" => state_revision
         } = params
       ) do
    if exact_keys?(params, ~w[version assetId stateRevision]) and
         valid_uuid?(asset_id) and is_integer(state_revision) and
         state_revision >= 0 do
      {:ok, asset_id, state_revision}
    else
      {:error, :invalid}
    end
  end

  defp mutation_request(_params), do: {:error, :invalid}

  defp navigation_request(%{"version" => @version, "to" => path} = params) do
    if exact_keys?(params, ~w[version to]) and path in @navigation_paths,
      do: {:ok, path},
      else: {:error, :invalid}
  end

  defp navigation_request(_params), do: {:error, :invalid}

  defp fetch_page(session, runtime_params) do
    case safe_runtime(:list_assets, [session, runtime_params]) do
      {:ok, %SearchPage{} = page} ->
        browser_page(page)

      {:error, reason} when reason in @public_errors ->
        {:error, reason}

      _invalid ->
        {:error, :invalid}
    end
  end

  defp fetch_initial_page(session, filters) do
    case fetch_page(session, runtime_params(filters)) do
      {:ok, page} -> {page, nil}
      {:error, reason} -> {empty_page(), workspace_error_message(reason)}
    end
  end

  defp browser_page(%SearchPage{items: items, next_cursor: next_cursor})
       when is_list(items) do
    with true <- valid_next_cursor?(next_cursor),
         {:ok, summaries} <- browser_summaries(items) do
      {:ok, %{items: summaries, nextCursor: next_cursor}}
    else
      _invalid -> {:error, :invalid}
    end
  end

  defp browser_page(_page), do: {:error, :invalid}

  defp browser_summaries(items) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, summaries} ->
      case browser_summary(item) do
        {:ok, summary} -> {:cont, {:ok, [summary | summaries]}}
        {:error, :invalid} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, summaries} -> {:ok, Enum.reverse(summaries)}
      error -> error
    end
  end

  defp browser_summary(%AssetSummary{} = summary) do
    with true <- valid_uuid?(summary.id),
         true <- valid_uuid?(summary.resource_version_id),
         true <- safe_nonblank?(summary.title, @max_opaque_bytes),
         true <- safe_nonblank?(summary.original_filename, @max_opaque_bytes),
         true <- valid_optional_text?(summary.detected_media_type, @max_filter_bytes),
         {:ok, state} <- state_name(summary.state),
         true <- is_integer(summary.state_revision) and summary.state_revision >= 0,
         true <- summary.label in @classification_labels,
         {:ok, progress} <- progress(summary.progress),
         {:ok, failure} <- failure(summary.failure),
         {:ok, updated_at} <- iso8601(summary.updated_at) do
      {:ok,
       %{
         id: summary.id,
         resourceVersionId: summary.resource_version_id,
         title: summary.title,
         originalFilename: summary.original_filename,
         detectedMediaType: summary.detected_media_type,
         state: state,
         stateRevision: summary.state_revision,
         label: summary.label,
         progress: progress,
         failure: failure,
         updatedAt: updated_at
       }}
    else
      _invalid -> {:error, :invalid}
    end
  end

  defp browser_summary(_summary), do: {:error, :invalid}

  defp progress(nil), do: {:ok, nil}

  defp progress(%{kind: :bytes, sent: sent, total: total} = progress)
       when map_size(progress) == 3 and is_integer(sent) and sent >= 0 and
              is_integer(total) and total >= sent,
       do: {:ok, %{kind: "bytes", sent: sent, total: total}}

  defp progress(%{kind: kind} = progress)
       when map_size(progress) == 1 and
              kind in [:indeterminate, :complete, :waiting_for_unlock],
       do: {:ok, %{kind: Atom.to_string(kind)}}

  defp progress(_progress), do: {:error, :invalid}

  defp failure(nil), do: {:ok, nil}

  defp failure(
         %{
           code: code,
           retryable: retryable,
           operation: operation,
           attempt: attempt
         } = failure
       )
       when map_size(failure) == 4 and is_boolean(retryable) and
              is_integer(attempt) and attempt >= 0 do
    if safe_nonblank?(code, @max_filter_bytes) and
         safe_nonblank?(operation, @max_filter_bytes) do
      {:ok,
       %{
         code: code,
         retryable: retryable,
         operation: operation,
         attempt: attempt
       }}
    else
      {:error, :invalid}
    end
  end

  defp failure(_failure), do: {:error, :invalid}

  defp validate_grant(%UploadGrant{} = grant, token, attrs) do
    valid? =
      valid_uuid?(grant.grant_id) and valid_uuid?(grant.asset_id) and
        grant.filename == attrs.filename and grant.byte_size == attrs.size and
        grant.declared_media_type == attrs.declared_media_type and
        grant.classification in [:private, :sensitive, :restricted] and
        safe_nonblank?(token, 4_096)

    with true <- valid?,
         {:ok, expires_at} <- iso8601(grant.expires_at) do
      {:ok, expires_at}
    else
      _invalid -> {:error, :invalid}
    end
  end

  defp empty_filters, do: %{q: "", state: nil, mediaType: nil}
  defp empty_page, do: %{items: [], nextCursor: nil}

  defp runtime_params(filters) do
    {:ok, _normalized_state, state_atom} = state(filters.state)
    runtime_params(filters, state_atom)
  end

  defp runtime_params(filters, state_atom) do
    %{
      q: filters.q,
      state: state_atom,
      media_type: filters.mediaType,
      limit: page_limit()
    }
  end

  defp page_limit do
    case Application.get_env(:singularity_web, :asset_page_limit, 50) do
      value when is_integer(value) and value <= 0 -> 1
      value when is_integer(value) and value > 50 -> 50
      value when is_integer(value) -> value
      _malformed -> 50
    end
  end

  defp assign_workspace(socket, session, page, filters, options) do
    socket
    |> assign(:page_title, "Assets")
    |> assign(:filters, filters)
    |> assign(:sequence, Keyword.get(options, :sequence, socket.assigns[:sequence]))
    |> assign(
      :upload_csrf,
      Keyword.get(options, :upload_csrf, socket.assigns[:upload_csrf])
    )
    |> assign(
      :snapshot_ready,
      Keyword.get(
        options,
        :snapshot_ready,
        socket.assigns[:snapshot_ready]
      )
    )
    |> assign(
      :snapshot_attempt,
      Keyword.get(
        options,
        :snapshot_attempt,
        socket.assigns[:snapshot_attempt]
      )
    )
    |> assign(
      :snapshot_generation,
      Keyword.get(
        options,
        :snapshot_generation,
        socket.assigns[:snapshot_generation]
      )
    )
    |> assign(
      :snapshot_recovery_enabled,
      Keyword.get(
        options,
        :snapshot_recovery_enabled,
        socket.assigns[:snapshot_recovery_enabled]
      )
    )
    |> assign(
      :refresh_attempt,
      Keyword.get(options, :refresh_attempt, socket.assigns[:refresh_attempt])
    )
    |> assign(
      :refresh_generation,
      Keyword.get(options, :refresh_generation, socket.assigns[:refresh_generation])
    )
    |> assign(
      :refresh_retry_enabled,
      Keyword.get(
        options,
        :refresh_retry_enabled,
        socket.assigns[:refresh_retry_enabled]
      )
    )
    |> assign(
      :pending_upload_grant,
      Keyword.get(
        options,
        :pending_upload_grant,
        socket.assigns[:pending_upload_grant]
      )
    )
    |> assign(
      :workspace_error,
      Keyword.get(options, :workspace_error, socket.assigns[:workspace_error])
    )
    |> assign(:initial_props, initial_props(session, page, filters))
  end

  defp initial_props(session, page, filters) do
    %{
      version: @version,
      vault: %{
        ref: session.vault_id,
        locked: not session.unlocked?,
        expiresAt: session_expiry(session.expires_at)
      },
      assets: page,
      filters: filters,
      upload: %{
        maxBytes: max_upload_bytes(),
        acceptedTypes: @accepted_upload_types
      }
    }
  end

  defp session_expiry(expires_at) do
    case iso8601(expires_at) do
      {:ok, value} -> value
      {:error, :invalid} -> nil
    end
  end

  defp iso8601(
         %DateTime{
           calendar: Calendar.ISO,
           time_zone: "Etc/UTC",
           zone_abbr: "UTC",
           utc_offset: 0,
           std_offset: 0
         } = datetime
       ) do
    try do
      value = DateTime.to_iso8601(datetime)

      case DateTime.from_iso8601(value) do
        {:ok, ^datetime, 0} -> {:ok, value}
        _invalid -> {:error, :invalid}
      end
    rescue
      _error -> {:error, :invalid}
    catch
      _kind, _reason -> {:error, :invalid}
    end
  end

  defp iso8601(_datetime), do: {:error, :invalid}

  defp max_upload_bytes do
    case Application.get_env(
           :singularity_runtime,
           :max_upload_bytes,
           @default_max_upload_bytes
         ) do
      value when is_integer(value) and value >= 0 -> value
      _invalid -> @default_max_upload_bytes
    end
  end

  defp next_sequence(socket) do
    sequence = socket.assigns.sequence + 1
    {sequence, assign(socket, :sequence, sequence)}
  end

  defp clear_refresh_retry(socket) do
    assign(socket,
      refresh_attempt: 0,
      refresh_generation: make_ref(),
      refresh_retry_enabled: false
    )
  end

  defp terminal_workspace(socket, reason) do
    assign(socket,
      snapshot_ready: false,
      snapshot_generation: make_ref(),
      snapshot_recovery_enabled: false,
      refresh_attempt: 0,
      refresh_generation: make_ref(),
      refresh_retry_enabled: false,
      workspace_error: workspace_error_message(reason)
    )
  end

  defp workspace_error_message(reason) when reason in @public_errors,
    do: @workspace_error_message

  defp workspace_error_message(_reason), do: @workspace_error_message

  defp connect_csrf(socket) do
    case get_connect_params(socket) do
      %{"_csrf_token" => token} when is_binary(token) ->
        if safe_nonblank?(token, @max_opaque_bytes), do: token

      _params ->
        nil
    end
  end

  defp query(value) when is_binary(value) do
    if byte_size(value) <= @max_query_bytes and safe_text?(value),
      do: {:ok, String.trim(value)},
      else: {:error, :invalid}
  end

  defp query(_value), do: {:error, :invalid}

  defp cursor(value) when is_binary(value) do
    if safe_nonblank?(value, @max_cursor_bytes),
      do: {:ok, value},
      else: {:error, :invalid}
  end

  defp cursor(_value), do: {:error, :invalid}

  defp search_media_type(nil), do: {:ok, nil}

  defp search_media_type(value) when is_binary(value) do
    if safe_nonblank?(value, @max_filter_bytes),
      do: {:ok, value},
      else: {:error, :invalid}
  end

  defp search_media_type(_value), do: {:error, :invalid}

  defp state(nil), do: {:ok, nil, nil}
  defp state("staging"), do: {:ok, "staging", :staging}
  defp state("uploaded"), do: {:ok, "uploaded", :uploaded}
  defp state("verified"), do: {:ok, "verified", :verified}
  defp state("available"), do: {:ok, "available", :available}
  defp state("processing"), do: {:ok, "processing", :processing}
  defp state("ready"), do: {:ok, "ready", :ready}
  defp state("pending_delete"), do: {:ok, "pending_delete", :pending_delete}
  defp state("deleted"), do: {:ok, "deleted", :deleted}
  defp state(_state), do: {:error, :invalid}

  defp state_name(:staging), do: {:ok, "staging"}
  defp state_name(:uploaded), do: {:ok, "uploaded"}
  defp state_name(:verified), do: {:ok, "verified"}
  defp state_name(:available), do: {:ok, "available"}
  defp state_name(:processing), do: {:ok, "processing"}
  defp state_name(:ready), do: {:ok, "ready"}
  defp state_name(:pending_delete), do: {:ok, "pending_delete"}
  defp state_name(:deleted), do: {:ok, "deleted"}
  defp state_name(_state), do: {:error, :invalid}

  defp valid_next_cursor?(nil), do: true
  defp valid_next_cursor?(value), do: safe_nonblank?(value, @max_cursor_bytes)

  defp valid_optional_text?(nil, _maximum), do: true
  defp valid_optional_text?(value, maximum), do: safe_nonblank?(value, maximum)

  defp safe_nonblank?(value, maximum)
       when is_binary(value) and byte_size(value) <= maximum do
    safe_text?(value) and String.trim(value) != ""
  end

  defp safe_nonblank?(_value, _maximum), do: false

  defp safe_text?(value) when is_binary(value),
    do: String.valid?(value) and :binary.match(value, <<0>>) == :nomatch

  defp exact_keys?(params, keys) when is_map(params),
    do: Enum.sort(Map.keys(params)) == Enum.sort(keys)

  defp valid_uuid?(value) when is_binary(value), do: Regex.match?(@uuid, value)
  defp valid_uuid?(_value), do: false

  defp safe_runtime(function, arguments) do
    Auth.call_runtime(function, arguments)
  rescue
    _error -> {:error, :storage_unavailable}
  catch
    _kind, _reason -> {:error, :storage_unavailable}
  end

  defp error_reply(socket, result) do
    {:reply,
     %{
       ok: false,
       error: %{code: result |> public_error() |> Atom.to_string()}
     }, socket}
  end

  defp public_error({:error, reason}) when reason in @public_errors, do: reason
  defp public_error(reason) when reason in @public_errors, do: reason
  defp public_error(_result), do: :invalid
end
