defmodule Singularity.Web.UploadController do
  use Singularity.Web, :controller

  alias Singularity.Web.Auth

  @read_length 1_048_576

  @status_by_error %{
    invalid: 400,
    invalid_content_length: 400,
    unauthenticated: 401,
    forbidden: 403,
    not_found: 403,
    vault_locked: 403,
    csrf_failed: 403,
    conflict: 409,
    upload_expired: 410,
    upload_too_large: 413,
    unsupported_media_type: 415,
    integrity_failure: 422,
    storage_unavailable: 503
  }

  def update(conn, %{"grant_id" => grant_id}) do
    conn = Auth.verify_api_csrf(conn, [])

    if conn.halted do
      conn
    else
      with {:ok, request_meta} <- request_meta(conn),
           {:ok, upload} <-
             Auth.call_runtime(:begin_upload, [
               conn.assigns.current_session,
               grant_id,
               Map.put(request_meta, :csrf_token, conn.assigns.csrf_token),
               self()
             ]) do
        result =
          try do
            stream(conn, upload)
          after
            _end_result = Auth.call_runtime(:end_upload, [upload])
          end

        upload_response(result)
      else
        {:error, code} when is_atom(code) -> error(conn, code)
        _invalid -> error(conn, :storage_unavailable)
      end
    end
  end

  defp request_meta(conn) do
    with {:ok, upload_token} <- exactly_one(conn, "x-upload-token"),
         true <- byte_size(upload_token) > 0,
         {:ok, content_length} <- content_length(conn),
         {:ok, content_type} <- exactly_one(conn, "content-type"),
         declared_media_type when declared_media_type != "" <-
           content_type
           |> String.split(";", parts: 2)
           |> hd()
           |> String.trim()
           |> String.downcase() do
      {:ok,
       %{
         upload_token: upload_token,
         content_length: content_length,
         declared_media_type: declared_media_type
       }}
    else
      {:error, code} -> {:error, code}
      _invalid -> {:error, :invalid}
    end
  end

  defp content_length(conn) do
    with {:ok, value} <- exactly_one(conn, "content-length"),
         {content_length, ""} when content_length >= 0 <- Integer.parse(value) do
      {:ok, content_length}
    else
      _invalid -> {:error, :invalid_content_length}
    end
  end

  defp exactly_one(conn, header) do
    case get_req_header(conn, header) do
      [value] when is_binary(value) -> {:ok, value}
      _missing_or_ambiguous -> {:error, :invalid}
    end
  end

  defp stream(conn, upload) do
    case read_body(conn,
           length: @read_length,
           read_length: @read_length,
           read_timeout: 15_000
         ) do
      {:more, chunk, next_conn} ->
        case Auth.call_runtime(:append_upload, [upload, chunk]) do
          :ok -> stream(next_conn, upload)
          {:error, code} -> abandon(next_conn, upload, :stream_interrupted, code)
          _invalid -> abandon(next_conn, upload, :stream_interrupted, :storage_unavailable)
        end

      {:ok, final_chunk, next_conn} ->
        case Auth.call_runtime(:finish_upload, [upload, final_chunk]) do
          {:ok, result} -> {:ok, result, next_conn}
          {:error, code} -> abandon(next_conn, upload, :stream_interrupted, code)
          _invalid -> abandon(next_conn, upload, :stream_interrupted, :storage_unavailable)
        end

      {:error, _reason} ->
        abandon(conn, upload, :stream_interrupted, :storage_unavailable)
    end
  end

  defp abandon(conn, upload, reason, error) do
    _abandon_result = Auth.call_runtime(:abandon_upload, [upload, reason])
    {:error, error, conn}
  end

  defp upload_response({:ok, result, conn}) do
    body = %{
      ok: true,
      assetId: Map.fetch!(result, :asset_id),
      state: Map.fetch!(result, :state),
      stateRevision: Map.fetch!(result, :state_revision)
    }

    json(conn, body, 201)
  end

  defp upload_response({:error, code, conn}), do: error(conn, code)

  defp error(conn, code) do
    status = Map.get(@status_by_error, code, 503)
    json(conn, %{error: %{code: Atom.to_string(code)}}, status)
  end

  defp json(conn, body, status) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode!(body))
  end
end
