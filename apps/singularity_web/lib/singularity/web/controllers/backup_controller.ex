defmodule Singularity.Web.BackupController do
  use Singularity.Web, :controller

  alias Singularity.Runtime.DTO.BackupStatus
  alias Singularity.Web.Auth

  @failure_message "Encrypted backup could not be requested."
  @sensitive_parameter_keys ["passphrase", :passphrase, "_csrf_token", :_csrf_token]
  @uuid ~r/\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/

  def create(
        %{assigns: %{current_session: current_session}, body_params: body_params} = conn,
        _params
      ) do
    passphrase = extract_passphrase(body_params)
    conn = scrub_sensitive_request(conn)

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

  defp scrub_sensitive_request(conn) do
    conn
    |> Map.update!(:body_params, &scrub_parameter_map/1)
    |> Map.update!(:params, &scrub_parameter_map/1)
    |> Map.update!(:query_params, &scrub_parameter_map/1)
    |> Map.update!(:path_params, &scrub_parameter_map/1)
    |> Map.update!(:adapter, &scrub_test_adapter/1)
    |> Map.put(:query_string, "")
  end

  defp scrub_parameter_map(%Plug.Conn.Unfetched{} = params), do: params

  defp scrub_parameter_map(params) when is_map(params),
    do: Map.drop(params, @sensitive_parameter_keys)

  defp scrub_test_adapter({Plug.Adapters.Test.Conn, %{params: params} = state}) do
    state =
      state
      |> Map.put(:params, scrub_parameter_map(params))
      |> Map.put(:req_body, "")

    {Plug.Adapters.Test.Conn, state}
  end

  defp scrub_test_adapter(adapter), do: adapter

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
