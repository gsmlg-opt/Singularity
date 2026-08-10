defmodule Singularity.Web.BackupController do
  use Singularity.Web, :controller

  alias Singularity.Runtime.DTO.BackupStatus
  alias Singularity.Web.Auth

  @failure_message "Encrypted backup could not be requested."
  @sensitive_parameter_keys [
    "password",
    :password,
    "passphrase",
    :passphrase,
    "token",
    :token,
    "csrf",
    :csrf,
    "csrf_token",
    :csrf_token,
    "_csrf_token",
    :_csrf_token,
    "upload_token",
    :upload_token,
    "x-csrf-token",
    :"x-csrf-token",
    "x-upload-token",
    :"x-upload-token"
  ]
  @sensitive_request_headers ["x-csrf-token", "x-upload-token"]
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
    |> Map.update!(:body_params, &scrub_parameter_value/1)
    |> Map.update!(:params, &scrub_parameter_value/1)
    |> Map.update!(:query_params, &scrub_parameter_value/1)
    |> Map.update!(:path_params, &scrub_parameter_value/1)
    |> Map.update!(:req_headers, &scrub_request_headers/1)
    |> Map.update!(:adapter, &scrub_test_adapter/1)
    |> Map.put(:query_string, "")
  end

  defp scrub_parameter_value(%Plug.Conn.Unfetched{} = value), do: value
  defp scrub_parameter_value(value) when is_struct(value), do: value

  defp scrub_parameter_value(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, nested_value}, scrubbed ->
      if key in @sensitive_parameter_keys do
        scrubbed
      else
        Map.put(scrubbed, key, scrub_parameter_value(nested_value))
      end
    end)
  end

  defp scrub_parameter_value(value) when is_list(value),
    do: Enum.map(value, &scrub_parameter_value/1)

  defp scrub_parameter_value(value), do: value

  defp scrub_request_headers(headers),
    do: Enum.reject(headers, fn {name, _value} -> name in @sensitive_request_headers end)

  defp scrub_test_adapter({Plug.Adapters.Test.Conn, %{params: params} = state}) do
    state =
      state
      |> Map.put(:params, scrub_parameter_value(params))
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
