defmodule Singularity.Web.BackupsLive do
  use Singularity.Web, :live_view

  alias Singularity.Runtime.DTO.BackupStatus
  alias Singularity.Runtime.DTO.Session
  alias Singularity.Web.Auth

  @in_progress_statuses [:pending, :waiting_for_backup_key, :copying]
  @terminal_statuses [:sealed, :failed]
  @poll_interval_ms 1_000
  @uuid ~r/\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/

  @impl true
  def mount(params, _live_session, socket) do
    %Session{} = current_session = socket.assigns.current_session

    socket =
      assign(socket,
        page_title: "Backups",
        backup_status: nil,
        backup_status_state: :not_found,
        backup_operation_id: nil,
        backup_poll_generation: make_ref(),
        backup_poll_timer: nil,
        backup_poll_token: nil
      )

    case operation_id(params) do
      {:ok, operation_id} ->
        {:ok, fetch_status(socket, current_session, operation_id)}

      :not_found ->
        {:ok, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.page title="Backups">
      <p :if={error = Phoenix.Flash.get(@flash, :error)} role="alert">{error}</p>

      <section aria-labelledby="create-backup-heading">
        <h2 id="create-backup-heading">Create encrypted backup</h2>
        <form action="/backups" method="post">
          <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
          <label for="backup-passphrase">Backup passphrase</label>
          <input
            id="backup-passphrase"
            name="passphrase"
            type="password"
            autocomplete="new-password"
            required
          />
          <button type="submit">Create encrypted backup</button>
        </form>
      </section>

      <section aria-labelledby="backup-status-heading">
        <h2 id="backup-status-heading">Backup status</h2>
        <p id="backup-status" role="status" aria-live="polite">
          {status_message(@backup_status_state, @backup_status)}
        </p>
      </section>
    </.page>
    """
  end

  @impl true
  def handle_info(
        {:backup_status_poll, generation, token},
        %{
          assigns: %{
            backup_poll_generation: generation,
            backup_poll_token: token
          }
        } = socket
      )
      when is_reference(generation) and is_reference(token) do
    if in_progress?(socket.assigns.backup_status) do
      socket = clear_poll_timer(socket)

      {:noreply,
       fetch_status(
         socket,
         socket.assigns.current_session,
         socket.assigns.backup_operation_id
       )}
    else
      {:noreply, stop_polling(socket)}
    end
  end

  def handle_info({:backup_status_poll, _generation, _token}, socket),
    do: {:noreply, socket}

  defp fetch_status(socket, current_session, operation_id) do
    case safe_runtime(:backup_status, [current_session, operation_id]) do
      {:ok, candidate} ->
        assign_status(socket, candidate, operation_id)

      {:error, :not_found} ->
        terminal_state(socket, :not_found)

      _failure ->
        terminal_state(socket, :unavailable)
    end
  end

  defp assign_status(socket, candidate, operation_id) do
    case canonical_backup_status(candidate, operation_id) do
      {:ok, backup_status} ->
        socket
        |> assign(
          backup_status: backup_status,
          backup_status_state: :available,
          backup_operation_id: operation_id
        )
        |> maybe_schedule_poll()

      :error ->
        terminal_state(socket, :unavailable)
    end
  end

  defp maybe_schedule_poll(socket) do
    if connected?(socket) and in_progress?(socket.assigns.backup_status) do
      schedule_poll(socket)
    else
      stop_polling(socket)
    end
  end

  defp schedule_poll(socket) do
    socket = clear_poll_timer(socket)
    token = make_ref()

    timer =
      Process.send_after(
        self(),
        {:backup_status_poll, socket.assigns.backup_poll_generation, token},
        @poll_interval_ms
      )

    assign(socket, backup_poll_timer: timer, backup_poll_token: token)
  end

  defp clear_poll_timer(socket) do
    case socket.assigns.backup_poll_timer do
      timer when is_reference(timer) -> Process.cancel_timer(timer)
      nil -> :ok
    end

    assign(socket, backup_poll_timer: nil, backup_poll_token: nil)
  end

  defp stop_polling(socket) do
    socket
    |> clear_poll_timer()
    |> assign(:backup_poll_generation, make_ref())
  end

  defp terminal_state(socket, state) when state in [:not_found, :unavailable] do
    socket
    |> stop_polling()
    |> assign(
      backup_status: nil,
      backup_status_state: state,
      backup_operation_id: nil
    )
  end

  defp canonical_backup_status(
         %BackupStatus{
           operation_id: operation_id,
           status: status,
           requested_at: requested_at,
           updated_at: updated_at
         } = candidate,
         operation_id
       )
       when map_size(candidate) == 5 and
              (status in @in_progress_statuses or status in @terminal_statuses) do
    if canonical_utc_datetime?(requested_at) and canonical_utc_datetime?(updated_at) and
         DateTime.compare(requested_at, updated_at) in [:lt, :eq] do
      {:ok,
       %BackupStatus{
         operation_id: operation_id,
         status: status,
         requested_at: requested_at,
         updated_at: updated_at
       }}
    else
      :error
    end
  end

  defp canonical_backup_status(_candidate, _operation_id), do: :error

  defp canonical_utc_datetime?(
         %DateTime{
           calendar: Calendar.ISO,
           time_zone: "Etc/UTC",
           zone_abbr: "UTC",
           utc_offset: 0,
           std_offset: 0
         } = datetime
       ) do
    with encoded when is_binary(encoded) <- DateTime.to_iso8601(datetime),
         {:ok, ^datetime, 0} <- DateTime.from_iso8601(encoded) do
      true
    else
      _invalid -> false
    end
  rescue
    _error -> false
  catch
    _kind, _reason -> false
  end

  defp canonical_utc_datetime?(_datetime), do: false

  defp operation_id(%{"operation_id" => operation_id}) when is_binary(operation_id) do
    if Regex.match?(@uuid, operation_id), do: {:ok, operation_id}, else: :not_found
  end

  defp operation_id(_params), do: :not_found

  defp in_progress?(%BackupStatus{status: status}), do: status in @in_progress_statuses
  defp in_progress?(_status), do: false

  defp safe_runtime(function, arguments) do
    Auth.call_runtime(function, arguments)
  rescue
    _error -> {:error, :unavailable}
  catch
    _kind, _reason -> {:error, :unavailable}
  end

  defp status_message(:available, %BackupStatus{status: :pending}),
    do: "Encrypted backup is pending."

  defp status_message(:available, %BackupStatus{status: :waiting_for_backup_key}),
    do: "Encrypted backup is waiting for its backup key."

  defp status_message(:available, %BackupStatus{status: :copying}),
    do: "Encrypted backup is being copied."

  defp status_message(:available, %BackupStatus{status: :sealed}),
    do: "Encrypted backup sealed."

  defp status_message(:available, %BackupStatus{status: :failed}),
    do: "Encrypted backup could not be completed."

  defp status_message(:not_found, nil), do: "Backup operation was not found."
  defp status_message(:unavailable, nil), do: "Backup status is unavailable."
end
