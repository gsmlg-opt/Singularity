defmodule Singularity.Storage.Crypto.Format do
  @moduledoc """
  Canonical byte encoding for encrypted object format version 1.

  The clear header is authenticated as associated data for every encrypted
  record. It intentionally excludes the independently authenticated
  domain-key generation so a DEK can be rewrapped without rewriting an object.
  """

  @magic "SGKC"
  @format_version 1
  @algorithm :aes_256_gcm
  @algorithm_id 1
  @chunk_size 4_194_304
  @max_data_counter 0xFFFFFFFE
  @final_counter 0xFFFFFFFF
  @header_size 66

  @type header_context :: %{
          required(:format_version) => pos_integer(),
          required(:algorithm) => atom(),
          required(:chunk_size) => pos_integer(),
          required(:nonce_prefix) => binary(),
          required(:vault_id) => String.t(),
          required(:encryption_domain_id) => String.t(),
          required(:object_id) => String.t()
        }

  @spec format_version() :: 1
  def format_version, do: @format_version

  @spec algorithm() :: :aes_256_gcm
  def algorithm, do: @algorithm

  @spec chunk_size() :: 4_194_304
  def chunk_size, do: @chunk_size

  @spec max_data_counter() :: 0xFFFFFFFE
  def max_data_counter, do: @max_data_counter

  @spec final_counter() :: 0xFFFFFFFF
  def final_counter, do: @final_counter

  @spec header_size() :: 66
  def header_size, do: @header_size

  @spec nonce(binary(), non_neg_integer()) :: binary()
  def nonce(<<_::binary-size(8)>> = prefix, counter)
      when is_integer(counter) and counter in 0..@final_counter do
    <<prefix::binary, counter::unsigned-big-32>>
  end

  @spec canonical_header(map()) :: {:ok, binary()} | {:error, :invalid_format}
  def canonical_header(context) when is_map(context) do
    with @format_version <- Map.get(context, :format_version),
         @algorithm <- Map.get(context, :algorithm),
         @chunk_size <- Map.get(context, :chunk_size),
         <<_::binary-size(8)>> = nonce_prefix <- Map.get(context, :nonce_prefix),
         {:ok, vault_id} <- dump_uuid(Map.get(context, :vault_id)),
         {:ok, domain_id} <- dump_uuid(Map.get(context, :encryption_domain_id)),
         {:ok, object_id} <- dump_uuid(Map.get(context, :object_id)) do
      {:ok,
       <<@magic::binary, @format_version, @algorithm_id, @chunk_size::unsigned-big-32,
         nonce_prefix::binary, vault_id::binary, domain_id::binary, object_id::binary>>}
    else
      _invalid -> {:error, :invalid_format}
    end
  end

  def canonical_header(_context), do: {:error, :invalid_format}

  @spec split_header(binary()) ::
          {:ok, binary(), binary(), map()} | {:error, :integrity_failure}
  def split_header(
        <<@magic::binary, @format_version, @algorithm_id, @chunk_size::unsigned-big-32,
          nonce_prefix::binary-size(8), vault_id::binary-size(16), domain_id::binary-size(16),
          object_id::binary-size(16), records::binary>> = encoded
      ) do
    <<header::binary-size(@header_size), _records::binary>> = encoded

    {:ok, header, records,
     %{
       format_version: @format_version,
       algorithm: @algorithm,
       chunk_size: @chunk_size,
       nonce_prefix: nonce_prefix,
       vault_id: vault_id,
       encryption_domain_id: domain_id,
       object_id: object_id
     }}
  end

  def split_header(_encoded), do: {:error, :integrity_failure}

  @spec data_aad(binary(), non_neg_integer(), non_neg_integer()) :: binary()
  def data_aad(header, counter, plaintext_size)
      when is_binary(header) and counter in 0..@max_data_counter and
             is_integer(plaintext_size) and plaintext_size >= 0 do
    <<"SGKC-DATA-V1", header::binary, counter::unsigned-big-32, plaintext_size::unsigned-big-32>>
  end

  @spec final_aad(binary()) :: binary()
  def final_aad(header) when is_binary(header) do
    <<"SGKC-FINAL-V1", header::binary, @final_counter::unsigned-big-32, 44::unsigned-big-32>>
  end

  @spec context_matches?(map(), map()) :: boolean()
  def context_matches?(parsed, expected) when is_map(parsed) and is_map(expected) do
    parsed.format_version == Map.get(expected, :format_version) and
      parsed.algorithm == Map.get(expected, :algorithm) and
      parsed.chunk_size == Map.get(expected, :chunk_size) and
      parsed.nonce_prefix == Map.get(expected, :nonce_prefix) and
      parsed.vault_id == dump_uuid_value(Map.get(expected, :vault_id)) and
      parsed.encryption_domain_id ==
        dump_uuid_value(Map.get(expected, :encryption_domain_id)) and
      parsed.object_id == dump_uuid_value(Map.get(expected, :object_id))
  end

  def context_matches?(_parsed, _expected), do: false

  defp dump_uuid(value) when is_binary(value) do
    case Ecto.UUID.dump(value) do
      {:ok, <<_::binary-size(16)>> = uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_format}
    end
  end

  defp dump_uuid(_value), do: {:error, :invalid_format}

  defp dump_uuid_value(value) do
    case dump_uuid(value) do
      {:ok, uuid} -> uuid
      {:error, :invalid_format} -> nil
    end
  end
end
