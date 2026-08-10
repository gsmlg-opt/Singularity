defmodule Singularity.Web.BackupController do
  use Singularity.Web, :controller

  alias Singularity.Runtime.DTO.BackupStatus
  alias Singularity.Web.Auth

  @failure_message "Encrypted backup could not be requested."
  @uuid ~r/\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/

  def create(
        %{assigns: %{current_session: current_session}, body_params: body_params} = conn,
        _params
      ) do
    passphrase = extract_passphrase(body_params)
    conn = Auth.scrub_sensitive_request(conn)

    case passphrase do
      {:ok, passphrase} ->
        with {:ok, %BackupStatus{operation_id: operation_id}} <-
               request_backup(current_session, passphrase),
             true <- valid_uuid?(operation_id) do
          redirect(conn, to: "/backups?operation_id=" <> URI.encode_www_form(operation_id))
        else
          _failure -> failure(conn)
        end

      :error ->
        failure(conn)
    end
  end

  defp extract_passphrase(%{"passphrase" => passphrase})
       when is_binary(passphrase) and byte_size(passphrase) > 0,
       do: {:ok, passphrase}

  defp extract_passphrase(_body_params), do: :error

  defp request_backup(current_session, passphrase) do
    Auth.call_runtime(:request_backup, [current_session, passphrase])
  rescue
    _error -> {:error, :unavailable}
  catch
    _kind, _reason -> {:error, :unavailable}
  end

  defp failure(conn) do
    conn
    |> put_flash(:error, @failure_message)
    |> redirect(to: "/backups")
  end

  defp valid_uuid?(value) when is_binary(value), do: Regex.match?(@uuid, value)
  defp valid_uuid?(_value), do: false
end
