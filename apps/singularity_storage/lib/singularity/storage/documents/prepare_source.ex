defmodule Singularity.Storage.Documents.PrepareSource do
  @moduledoc "Internal preparation contract; no live custody dependency is configured."
  alias Singularity.Core.{DocumentSource, Error}
  alias Singularity.Storage.Documents.PreparedSource
  alias Singularity.Storage.Postgres.DocumentSourceRepository

  @spec prepare(map(), map()) :: {:ok, PreparedSource.t()} | {:error, Error.t()}
  def prepare(%{digest_operation: digest, repo: repo}, %{context: context, asset_id: asset_id})
      when is_function(digest, 2) and is_atom(repo) do
    with {:ok, binding} <- DocumentSourceRepository.load(repo, context, asset_id),
         :ok <- supported(binding),
         {:ok, result} <- digest.(context, binding),
         {:ok, source} <- source(binding, result) do
      {:ok, %PreparedSource{source: source, binding: binding, principal_id: context.principal_id}}
    else
      {:error, %Error{code: code, retryable?: retryable?}} ->
        {:error, Error.new(code, retryable?: retryable?)}

      _ ->
        {:error, Error.new(:integrity_failure)}
    end
  rescue
    _ -> {:error, Error.new(:storage_unavailable, retryable?: true)}
  catch
    _, _ -> {:error, Error.new(:storage_unavailable, retryable?: true)}
  end

  def prepare(%{digest_operation: digest}, _args) when is_function(digest, 2),
    do: {:error, Error.new(:invalid)}

  def prepare(_dependencies, _args), do: {:error, Error.new(:storage_unavailable)}

  defp supported(%{byte_size: size}) when size > 67_108_864,
    do: {:error, Error.new(:upload_too_large)}

  defp supported(%{media_type: media})
       when media not in ["application/pdf", "text/markdown", "text/plain"],
       do: {:error, Error.new(:unsupported_media_type)}

  defp supported(_), do: :ok

  defp source(binding, %{sha256: digest, byte_size: size})
       when is_binary(digest) and byte_size(digest) == 32 and size == binding.byte_size do
    binding
    |> Map.take([
      :asset_id,
      :resource_id,
      :resource_version_id,
      :object_id,
      :owner_scope_id,
      :classification,
      :byte_size,
      :media_type
    ])
    |> Map.put(:digest, digest)
    |> DocumentSource.new()
  end

  defp source(_, _), do: {:error, Error.new(:integrity_failure)}
end
