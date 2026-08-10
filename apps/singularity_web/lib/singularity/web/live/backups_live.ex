defmodule Singularity.Web.BackupsLive do
  use Singularity.Web, :live_view

  alias Singularity.Runtime.DTO.BackupStatus
  alias Singularity.Runtime.DTO.Session
  alias Singularity.Web.Auth

  @in_progress_statuses [:pending, :waiting_for_backup_key, :copying]
  @terminal_statuses [:sealed, :failed]
  @max_poll_attempts 3
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
        backup_poll_attempt: 0,
        backup_polling: false
      )

    case operation_id(params) do
      {:ok, operation_id} ->
        {:ok, fetch_status(socket, current_session, operation_id, 0)}

      :not_found ->
        {:ok, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.page title="Backups">
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
  def handle_info({:backup_status_poll, generation, attempt}, socket)
      when is_reference(generation) and is_integer(attempt) do
    expected_attempt = socket.assigns.backup_poll_attempt + 1

    if socket.assigns.backup_polling and
         generation == socket.assigns.backup_poll_generation and
         attempt == expected_attempt and attempt <= @max_poll_attempts and
         in_progress?(socket.assigns.backup_status) do
      socket =
        fetch_status(
          socket,
          socket.assigns.current_session,
          socket.assigns.backup_operation_id,
          attempt
        )

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:backup_status_poll, _generation, _attempt}, socket),
    do: {:noreply, socket}

  defp fetch_status(socket, current_session, operation_id, attempt) do
    case safe_runtime(:backup_status, [current_session, operation_id]) do
      {:ok, %BackupStatus{operation_id: ^operation_id, status: status} = backup_status}
      when status in @in_progress_statuses or status in @terminal_statuses ->
        socket
        |> assign(
          backup_status: backup_status,
          backup_status_state: :available,
          backup_operation_id: operation_id,
          backup_poll_attempt: attempt
        )
        |> maybe_schedule_poll()

      {:error, :not_found} ->
        terminal_state(socket, :not_found)

      _failure ->
        terminal_state(socket, :unavailable)
    end
  end

  defp maybe_schedule_poll(socket) do
    if connected?(socket) and in_progress?(socket.assigns.backup_status) and
         socket.assigns.backup_poll_attempt < @max_poll_attempts do
      Process.send_after(
        self(),
        {
          :backup_status_poll,
          socket.assigns.backup_poll_generation,
          socket.assigns.backup_poll_attempt + 1
        },
        @poll_interval_ms
      )

      assign(socket, :backup_polling, true)
    else
      assign(socket, :backup_polling, false)
    end
  end

  defp terminal_state(socket, state) when state in [:not_found, :unavailable] do
    assign(socket,
      backup_status: nil,
      backup_status_state: state,
      backup_operation_id: nil,
      backup_poll_generation: make_ref(),
      backup_polling: false
    )
  end

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
