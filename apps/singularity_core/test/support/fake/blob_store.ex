defmodule Singularity.Core.TestSupport.Fake.BlobStore do
  @moduledoc false

  @behaviour Singularity.Core.BlobStore

  alias Singularity.Core.BlobRef
  alias Singularity.Core.Error
  alias Singularity.Core.TestSupport.Fake.Control

  def start_link(options) when is_list(options) do
    Control.start_link(%{
      blobs: Keyword.get(options, :blobs, %{}),
      next_id: Keyword.get(options, :next_id, 1)
    })
  end

  def calls(context), do: Control.calls(context)
  def fail_next(context, %Error{} = error), do: Control.fail_next(context, error)

  @impl true
  def put(context, bytes, source) do
    Control.run(context, :put, [bytes, source], fn data ->
      if source.byte_size == byte_size(bytes) do
        blob_id = "fake-blob-#{data.next_id}"

        blob_ref = %BlobRef{
          blob_id: blob_id,
          sha256: source.sha256,
          byte_size: source.byte_size,
          media_type: source.media_type,
          original_filename: source.original_filename
        }

        new_data = %{
          data
          | blobs: Map.put(data.blobs, blob_id, bytes),
            next_id: data.next_id + 1
        }

        {{:ok, blob_ref}, new_data}
      else
        {{:error, %Error{code: :invalid}}, data}
      end
    end)
  end

  @impl true
  def fetch(context, %BlobRef{} = blob_ref) do
    Control.run(context, :fetch, [blob_ref], fn data ->
      result =
        case Map.fetch(data.blobs, blob_ref.blob_id) do
          {:ok, bytes} -> {:ok, bytes}
          :error -> {:error, %Error{code: :not_found}}
        end

      {result, data}
    end)
  end
end
