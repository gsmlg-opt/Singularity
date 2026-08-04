defmodule Singularity.Runtime.Assets.CreateUploadGrant do
  @moduledoc "Creates an exact, short-lived, single-use browser upload grant."

  alias Singularity.Core.Error
  alias Singularity.Ingest.UploadRequest
  alias Singularity.Runtime.OperationScope
  alias Singularity.Runtime.SessionContext

  @grant_ttl_seconds 300
  @request_fields [:declared_media_type, :filename, :idempotency_key, :size]

  @spec run(map(), SessionContext.t(), map(), binary()) ::
          {:ok, map()} | {:error, Error.t()}
  def run(runtime, %SessionContext{} = session, attrs, csrf_token)
      when is_map(runtime) and is_map(attrs) and is_binary(csrf_token) do
    with {:ok, adapters} <- adapters(runtime),
         {:ok, csrf_token_digest} <- csrf_token_digest(csrf_token),
         {:ok, request} <- request(attrs),
         {:ok, token} <- token(adapters.random_bytes),
         {:ok, ids} <- ids(adapters.id_generator),
         now when is_struct(now, DateTime) <- adapters.clock.(),
         {:ok, expires_at} <- expires_at(now, session.expires_at),
         requirement = requirement(request),
         result <-
           call_adapter(adapters.operation_scope, :with_shared_request, [
             runtime,
             session,
             requirement,
             fn repo ->
               call_adapter(adapters.assets, :create_upload_grant, [
                 repo,
                 %{
                   grant_id: ids.grant_id,
                   asset_id: ids.asset_id,
                   source_reference_id: ids.source_reference_id,
                   resource_id: ids.resource_id,
                   resource_version_id: ids.resource_version_id,
                   server_owned_resource?: true,
                   session_id: session.session_id,
                   principal_id: session.principal_id,
                   vault_id: session.vault_id,
                   filename: request.filename,
                   byte_size: request.size,
                   declared_media_type: request.declared_media_type,
                   idempotency_key: request.idempotency_key,
                   classification: :private,
                   token_digest: :crypto.hash(:sha256, token),
                   csrf_token_digest: csrf_token_digest,
                   expires_at: expires_at,
                   observed_at: now
                 }
               ])
             end
           ]) do
      attach_token(result, token)
    else
      {:error, %Error{}} = error -> error
      _invalid -> {:error, Error.new(:invalid)}
    end
  rescue
    _error -> {:error, Error.new(:storage_unavailable, retryable?: true)}
  end

  def run(_runtime, _session, _attrs, _csrf_token),
    do: {:error, Error.new(:invalid)}

  @spec run(map(), SessionContext.t(), map()) ::
          {:error, Error.t()}
  def run(_runtime, _session, _attrs), do: {:error, Error.new(:invalid)}

  defp requirement(_request) do
    %{
      required_capability: "asset.write",
      classification: :private,
      requires_unlocked?: true
    }
  end

  defp attach_token({:ok, grant}, token) when is_map(grant) do
    {:ok,
     grant
     |> Map.drop([
       :token_digest,
       :csrf_token_digest,
       "token_digest",
       "csrf_token_digest"
     ])
     |> Map.put(:token, Base.url_encode64(token, padding: false))}
  end

  defp attach_token({:error, %Error{}} = error, _token), do: error
  defp attach_token(_result, _token), do: {:error, Error.new(:storage_unavailable)}

  defp token(random_bytes) do
    case random_bytes.(32) do
      <<_::binary-size(32)>> = token -> {:ok, token}
      _invalid -> {:error, Error.new(:storage_unavailable)}
    end
  end

  defp csrf_token_digest(csrf_token)
       when byte_size(csrf_token) > 0 and byte_size(csrf_token) <= 1_024,
       do: {:ok, :crypto.hash(:sha256, csrf_token)}

  defp csrf_token_digest(_csrf_token),
    do: {:error, Error.new(:invalid)}

  defp ids(id_generator) do
    ids = %{
      grant_id: id_generator.(),
      asset_id: id_generator.(),
      source_reference_id: id_generator.(),
      resource_id: id_generator.(),
      resource_version_id: id_generator.()
    }

    if Enum.all?(Map.values(ids), &match?({:ok, _}, Ecto.UUID.cast(&1))) do
      {:ok, ids}
    else
      {:error, Error.new(:invalid)}
    end
  end

  defp expires_at(now, %DateTime{} = session_expires_at) do
    grant_expires_at = DateTime.add(now, @grant_ttl_seconds, :second)

    case DateTime.compare(session_expires_at, now) do
      :gt ->
        expires_at =
          if DateTime.compare(grant_expires_at, session_expires_at) == :gt,
            do: session_expires_at,
            else: grant_expires_at

        {:ok, expires_at}

      _expired ->
        {:error, Error.new(:invalid)}
    end
  end

  defp expires_at(_now, _session_expires_at),
    do: {:error, Error.new(:invalid)}

  defp adapters(runtime) do
    assets = Map.get(runtime, :assets)

    if assets not in [nil, false] do
      {:ok,
       %{
         assets: assets,
         clock: Map.get(runtime, :clock, fn -> DateTime.utc_now(:microsecond) end),
         id_generator: Map.get(runtime, :id_generator, &Ecto.UUID.generate/0),
         operation_scope: Map.get(runtime, :operation_scope, OperationScope),
         random_bytes: Map.get(runtime, :random_bytes, &:crypto.strong_rand_bytes/1)
       }}
    else
      {:error, Error.new(:invalid)}
    end
  end

  defp max_upload_bytes do
    Application.get_env(:singularity_runtime, :max_upload_bytes, 512 * 1024 * 1024)
  end

  defp request(attrs) do
    if Enum.sort(Map.keys(attrs)) == Enum.sort(@request_fields) do
      attrs
      |> Map.put(:max_bytes, max_upload_bytes())
      |> UploadRequest.new()
    else
      {:error, Error.new(:invalid)}
    end
  end

  defp call_adapter(module, function, arguments)
       when is_atom(module) and not is_nil(module) do
    apply(module, function, arguments)
  end

  defp call_adapter({module, context}, function, arguments)
       when is_atom(module) and not is_nil(module) do
    apply(module, function, [context | arguments])
  end
end
