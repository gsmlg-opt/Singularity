defmodule Singularity.Ingest.Idempotency do
  @moduledoc "Canonical digest and conflict check for an upload binding."

  alias Singularity.Core.Error
  alias Singularity.Ingest.UploadRequest

  @spec digest(UploadRequest.t()) :: <<_::256>>
  def digest(%UploadRequest{} = request) do
    [
      request.idempotency_key,
      request.filename,
      Integer.to_string(request.size),
      request.declared_media_type,
      request.resource_version_id,
      Atom.to_string(request.classification)
    ]
    |> Enum.map(&length_prefix/1)
    |> then(&:crypto.hash(:sha256, &1))
  end

  @spec compare(UploadRequest.t(), UploadRequest.t()) ::
          :ok | {:error, Error.t()}
  def compare(%UploadRequest{} = expected, %UploadRequest{} = candidate) do
    if :crypto.hash_equals(digest(expected), digest(candidate)) do
      :ok
    else
      {:error, Error.new(:conflict)}
    end
  end

  def compare(_expected, _candidate), do: {:error, Error.new(:invalid)}

  defp length_prefix(value), do: <<byte_size(value)::unsigned-big-32, value::binary>>
end
