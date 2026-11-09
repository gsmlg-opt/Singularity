defmodule Singularity.Storage.AuthenticatedReader do
  @moduledoc """
  Authenticated plaintext reads over immutable encrypted object storage.

  Ciphertext is read through the object-storage port in complete canonical
  records. A requested plaintext range is returned only after every
  intersecting record authenticates successfully.
  """

  alias Singularity.Core.Error
  alias Singularity.Core.ObjectRef
  alias Singularity.Storage.Crypto.ChunkedAEAD
  alias Singularity.Storage.Crypto.Format

  @record_overhead 24
  @final_record_size 68

  @type binding :: %{
          required(:object_ref) => ObjectRef.t(),
          required(:object_id) => String.t(),
          required(:vault_id) => String.t(),
          required(:encryption_domain_id) => String.t(),
          required(:plaintext_byte_size) => non_neg_integer(),
          required(:ciphertext_byte_size) => non_neg_integer(),
          required(:format_version) => pos_integer()
        }

  @spec read(
          %{required(:adapter) => module(), required(:context) => term()},
          binding(),
          <<_::256>>,
          :all | Range.t()
        ) :: {:ok, binary()} | {:error, Error.t()}
  def read(storage, binding, object_dek, range) do
    with :ok <- validate_inputs(storage, binding, object_dek, range),
         {:ok, layout} <- canonical_layout(binding),
         :ok <- stat_matches(storage, binding.object_ref, layout.ciphertext_byte_size),
         {:ok, handle} <- open(storage, binding.object_ref),
         {:ok, header, parsed} <- read_header(storage, handle),
         :ok <- header_matches(parsed, binding),
         {:ok, plaintext} <-
           read_plaintext(storage, handle, header, parsed, object_dek, range, layout) do
      {:ok, plaintext}
    end
  end

  defp validate_inputs(
         %{adapter: adapter, context: _context},
         %{
           object_ref: %ObjectRef{object_id: object_ref_id},
           object_id: object_id,
           vault_id: vault_id,
           encryption_domain_id: encryption_domain_id,
           plaintext_byte_size: plaintext_byte_size,
           ciphertext_byte_size: ciphertext_byte_size,
           format_version: format_version
         },
         <<_::binary-size(32)>>,
         range
       ) do
    valid? =
      valid_adapter?(adapter) and
        is_binary(object_ref_id) and
        object_ref_id == object_id and
        valid_uuid?(object_id) and
        valid_uuid?(vault_id) and
        valid_uuid?(encryption_domain_id) and
        is_integer(plaintext_byte_size) and
        plaintext_byte_size >= 0 and
        is_integer(ciphertext_byte_size) and
        ciphertext_byte_size >= 0 and
        is_integer(format_version) and
        format_version > 0 and
        valid_range?(range, plaintext_byte_size)

    if valid?, do: :ok, else: invalid()
  end

  defp validate_inputs(_storage, _binding, _object_dek, _range), do: invalid()

  defp valid_adapter?(adapter) when is_atom(adapter) do
    Code.ensure_loaded?(adapter) and
      function_exported?(adapter, :stat, 2) and
      function_exported?(adapter, :open, 2) and
      function_exported?(adapter, :read_range, 3)
  end

  defp valid_adapter?(_adapter), do: false

  defp valid_uuid?(value) when is_binary(value) do
    match?({:ok, <<_::binary-size(16)>>}, Ecto.UUID.dump(value))
  end

  defp valid_uuid?(_value), do: false

  defp valid_range?(:all, _plaintext_byte_size), do: true

  defp valid_range?(
         %Range{first: first, last: last, step: 1},
         plaintext_byte_size
       )
       when is_integer(first) and first >= 0 and is_integer(last) and
              last >= first and last < plaintext_byte_size,
       do: true

  defp valid_range?(_range, _plaintext_byte_size), do: false

  defp canonical_layout(%{
         format_version: format_version,
         plaintext_byte_size: plaintext_byte_size,
         ciphertext_byte_size: ciphertext_byte_size
       }) do
    chunk_count =
      div(plaintext_byte_size + Format.chunk_size() - 1, Format.chunk_size())

    expected_ciphertext_byte_size =
      Format.header_size() +
        plaintext_byte_size +
        chunk_count * @record_overhead +
        @final_record_size

    if format_version == Format.format_version() and
         ChunkedAEAD.validate_chunk_count(chunk_count) == :ok and
         ciphertext_byte_size == expected_ciphertext_byte_size do
      {:ok,
       %{
         chunk_count: chunk_count,
         plaintext_byte_size: plaintext_byte_size,
         ciphertext_byte_size: ciphertext_byte_size
       }}
    else
      integrity_failure()
    end
  end

  defp stat_matches(%{adapter: adapter, context: context}, object_ref, expected_size) do
    case adapter.stat(context, object_ref) do
      {:ok, %{byte_size: ^expected_size}} -> :ok
      {:error, %Error{} = error} -> {:error, error}
      _mismatch -> integrity_failure()
    end
  end

  defp open(%{adapter: adapter, context: context}, object_ref) do
    case adapter.open(context, object_ref) do
      {:ok, handle} -> {:ok, handle}
      {:error, %Error{} = error} -> {:error, error}
      _invalid -> integrity_failure()
    end
  end

  defp read_header(storage, handle) do
    header_range = 0..(Format.header_size() - 1)

    with {:ok, header} <- exact_read(storage, handle, header_range),
         {:ok, ^header, "", parsed} <- Format.split_header(header) do
      {:ok, header, parsed}
    else
      {:error, %Error{} = error} -> {:error, error}
      _invalid -> integrity_failure()
    end
  end

  defp header_matches(parsed, binding) do
    expected = %{
      format_version: Format.format_version(),
      algorithm: Format.algorithm(),
      chunk_size: Format.chunk_size(),
      nonce_prefix: parsed.nonce_prefix,
      vault_id: binding.vault_id,
      encryption_domain_id: binding.encryption_domain_id,
      object_id: binding.object_id
    }

    if Format.context_matches?(parsed, expected),
      do: :ok,
      else: integrity_failure()
  end

  defp read_plaintext(
         storage,
         handle,
         header,
         parsed,
         object_dek,
         :all,
         layout
       ) do
    with {:ok, plaintext} <-
           read_all_data(storage, handle, header, parsed, object_dek, layout),
         {:ok, metadata} <-
           read_final_record(storage, handle, header, parsed, object_dek, layout),
         :ok <- verify_final(plaintext, metadata, layout) do
      {:ok, plaintext}
    end
  end

  defp read_plaintext(
         storage,
         handle,
         header,
         parsed,
         object_dek,
         %Range{first: first, last: last},
         layout
       ) do
    first_chunk = div(first, Format.chunk_size())
    last_chunk = div(last, Format.chunk_size())

    with {:ok, aligned_plaintext} <-
           read_data_span(
             storage,
             handle,
             header,
             parsed,
             object_dek,
             layout,
             first_chunk,
             last_chunk
           ) do
      trim_offset = first - first_chunk * Format.chunk_size()
      {:ok, binary_part(aligned_plaintext, trim_offset, last - first + 1)}
    end
  end

  defp read_all_data(
         _storage,
         _handle,
         _header,
         _parsed,
         _object_dek,
         %{chunk_count: 0}
       ),
       do: {:ok, ""}

  defp read_all_data(storage, handle, header, parsed, object_dek, layout) do
    read_data_span(
      storage,
      handle,
      header,
      parsed,
      object_dek,
      layout,
      0,
      layout.chunk_count - 1
    )
  end

  defp read_data_span(
         storage,
         handle,
         header,
         parsed,
         object_dek,
         layout,
         first_chunk,
         last_chunk
       ) do
    first_chunk..last_chunk
    |> Enum.reduce_while({:ok, []}, fn counter, {:ok, plaintext} ->
      plaintext_size = data_plaintext_size(layout, counter)
      offset = Format.header_size() + counter * (Format.chunk_size() + @record_overhead)
      record_range = offset..(offset + plaintext_size + @record_overhead - 1)

      with {:ok, record} <- exact_read(storage, handle, record_range),
           {:ok, chunk} <-
             ChunkedAEAD.decrypt_data_record(record, %{
               key: object_dek,
               header: header,
               nonce_prefix: parsed.nonce_prefix,
               counter: counter,
               plaintext_size: plaintext_size
             }) do
        {:cont, {:ok, [chunk | plaintext]}}
      else
        {:error, %Error{} = error} -> {:halt, {:error, error}}
        {:error, :integrity_failure} -> {:halt, integrity_failure()}
        _invalid -> {:halt, integrity_failure()}
      end
    end)
    |> case do
      {:ok, plaintext} -> {:ok, plaintext |> Enum.reverse() |> IO.iodata_to_binary()}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp data_plaintext_size(layout, counter)
       when counter == layout.chunk_count - 1 do
    layout.plaintext_byte_size - counter * Format.chunk_size()
  end

  defp data_plaintext_size(_layout, _counter), do: Format.chunk_size()

  defp read_final_record(storage, handle, header, parsed, object_dek, layout) do
    offset = layout.ciphertext_byte_size - @final_record_size
    record_range = offset..(layout.ciphertext_byte_size - 1)

    with {:ok, record} <- exact_read(storage, handle, record_range),
         {:ok, metadata} <-
           ChunkedAEAD.decrypt_final_record(record, %{
             key: object_dek,
             header: header,
             nonce_prefix: parsed.nonce_prefix
           }) do
      {:ok, metadata}
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, :integrity_failure} -> integrity_failure()
      _invalid -> integrity_failure()
    end
  end

  defp verify_final(plaintext, metadata, layout) do
    actual_sha256 = :crypto.hash(:sha256, plaintext)

    valid? =
      metadata.plaintext_bytes == layout.plaintext_byte_size and
        metadata.chunk_count == layout.chunk_count and
        :crypto.hash_equals(metadata.plaintext_sha256, actual_sha256)

    if valid?, do: :ok, else: integrity_failure()
  end

  defp exact_read(%{adapter: adapter, context: context}, handle, %Range{} = range) do
    expected_size = range.last - range.first + 1

    case adapter.read_range(context, handle, range) do
      {:ok, bytes} when is_binary(bytes) and byte_size(bytes) == expected_size ->
        {:ok, bytes}

      {:ok, _short_or_invalid} ->
        integrity_failure()

      {:error, %Error{} = error} ->
        {:error, error}

      _invalid ->
        integrity_failure()
    end
  end

  defp invalid, do: {:error, Error.new(:invalid)}
  defp integrity_failure, do: {:error, Error.new(:integrity_failure)}
end
