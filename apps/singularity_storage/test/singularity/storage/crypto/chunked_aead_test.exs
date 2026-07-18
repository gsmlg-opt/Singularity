defmodule Singularity.Storage.Crypto.ChunkedAEADTest do
  use ExUnit.Case, async: true

  alias Singularity.Storage.Crypto.ChunkedAEAD
  alias Singularity.Storage.Crypto.Format

  @header_size 66
  @tag_size 16

  test "uses a 64-bit nonce prefix and reserves the final 32-bit counter" do
    assert Format.chunk_size() == 4_194_304
    assert Format.max_data_counter() == 0xFFFFFFFE
    assert Format.final_counter() == 0xFFFFFFFF

    assert Format.nonce(<<0, 1, 2, 3, 4, 5, 6, 7>>, 0x01020304) ==
             <<0, 1, 2, 3, 4, 5, 6, 7, 1, 2, 3, 4>>
  end

  test "ordinary encoding owns its 8-byte nonce prefix" do
    plaintext = "codec-owned nonce"
    context = vector(plaintext)

    assert {:ok, encoded} = ChunkedAEAD.encode(context)

    assert {:ok, _header, _records, %{nonce_prefix: <<_::binary-size(8)>> = nonce_prefix}} =
             Format.split_header(encoded)

    refute nonce_prefix == context.nonce_prefix
    assert {:ok, ^plaintext} = ChunkedAEAD.decode(encoded, context)
  end

  test "ordinary encodes with the same DEK use fresh prefixes and ciphertext" do
    plaintext = "fresh nonce per encode"
    context = plaintext |> vector() |> Map.delete(:nonce_prefix)

    assert {:ok, first} = ChunkedAEAD.encode(context)
    assert {:ok, second} = ChunkedAEAD.encode(context)

    assert {:ok, _header, _records, %{nonce_prefix: first_prefix}} =
             Format.split_header(first)

    assert {:ok, _header, _records, %{nonce_prefix: second_prefix}} =
             Format.split_header(second)

    refute first_prefix == second_prefix
    refute first == second
    assert {:ok, ^plaintext} = ChunkedAEAD.decode(first, context)
    assert {:ok, ^plaintext} = ChunkedAEAD.decode(second, context)
  end

  test "streaming encryption owns a fresh prefix and returns a canonical header" do
    context = vector("not buffered by init")

    assert {:ok, first_header, first_state} = ChunkedAEAD.init_encrypt(context)
    assert {:ok, second_header, _second_state} = ChunkedAEAD.init_encrypt(context)

    assert {:ok, ^first_header, "", %{nonce_prefix: first_prefix}} =
             Format.split_header(first_header)

    assert {:ok, ^second_header, "", %{nonce_prefix: second_prefix}} =
             Format.split_header(second_header)

    refute first_prefix == context.nonce_prefix
    refute first_prefix == second_prefix
    assert {:error, :invalid_chunk} = ChunkedAEAD.encrypt_chunk(first_state, "")
  end

  test "streaming rechunks arbitrary transport fragments into canonical records" do
    chunk_size = Format.chunk_size()

    fragments = [
      "first short fragment",
      "second short fragment",
      :binary.copy(<<1>>, chunk_size - 3),
      :binary.copy(<<2>>, chunk_size + 7),
      :binary.copy(<<3>>, chunk_size * 2 + 11),
      "final short fragment"
    ]

    plaintext = IO.iodata_to_binary(fragments)
    context = vector(plaintext)
    nonce_prefix = <<8, 7, 6, 5, 4, 3, 2, 1>>

    assert {:ok, expected} = ChunkedAEAD.encode_vector(context, nonce_prefix)
    assert {:ok, header, state} = ChunkedAEAD.init_encrypt_vector(context, nonce_prefix)

    {results, state} =
      Enum.map_reduce(fragments, state, fn fragment, state ->
        assert {:ok, output, state} = ChunkedAEAD.encrypt_chunk(state, fragment)
        assert is_binary(output)
        {{output, state}, state}
      end)

    emitted = Enum.map(results, &elem(&1, 0))

    Enum.each(results, fn {_output, state} ->
      assert byte_size(Map.fetch!(state, :pending_plaintext)) < chunk_size
    end)

    assert ["", "" | _outputs] = emitted
    assert {:ok, final_tail, summary, _finalized_state} = ChunkedAEAD.finalize(state)

    encoded =
      [header | Enum.reject(emitted, &(&1 == ""))]
      |> then(&[&1, final_tail])
      |> IO.iodata_to_binary()

    assert encoded == expected
    assert {:ok, ^plaintext} = ChunkedAEAD.decode(encoded, context)

    assert summary == %{
             plaintext_bytes: byte_size(plaintext),
             chunk_count: div(byte_size(plaintext) + chunk_size - 1, chunk_size),
             plaintext_sha256: :crypto.hash(:sha256, plaintext)
           }
  end

  test "stream encryption state inspection exposes only nonsecret progress" do
    key = "0123456789abcdef0123456789ABCDEF"
    pending_plaintext = "PRINTABLE-PENDING-PLAINTEXT"
    context = pending_plaintext |> vector() |> Map.put(:key, key)

    assert {:ok, _header, state} =
             ChunkedAEAD.init_encrypt_vector(context, context.nonce_prefix)

    assert {:ok, "", state} =
             ChunkedAEAD.encrypt_chunk(state, pending_plaintext)

    plaintext_hash = state |> Map.fetch!(:plaintext_hash) |> inspect()
    generation_token = state |> Map.fetch!(:generation_token) |> inspect()

    rendered = inspect(state)
    exception_message = state |> then(&MatchError.exception(term: &1)) |> Exception.message()

    for output <- [rendered, exception_message] do
      assert output =~ "phase: :open"
      assert output =~ "plaintext_bytes: #{byte_size(pending_plaintext)}"
      assert output =~ "pending_bytes: #{byte_size(pending_plaintext)}"
      refute output =~ key
      refute output =~ pending_plaintext
      refute output =~ plaintext_hash
      refute output =~ generation_token
      refute output =~ "key:"
      refute output =~ "pending_plaintext:"
      refute output =~ "plaintext_hash:"
      refute output =~ "generation_token:"
    end
  end

  test "malformed stream state inspection remains total and secret-safe" do
    key = "0123456789abcdef0123456789ABCDEF"
    pending_plaintext = "PRINTABLE-PENDING-PLAINTEXT"
    plaintext_hash = make_ref()
    generation_token = make_ref()

    secret_fields = %{
      __struct__: ChunkedAEAD.EncryptState,
      key: key,
      pending_plaintext: pending_plaintext,
      plaintext_hash: plaintext_hash,
      generation_token: generation_token
    }

    malformed_states = [
      secret_fields,
      Map.merge(secret_fields, %{
        phase: {:secret, key},
        counter: key,
        chunk_count: plaintext_hash,
        plaintext_bytes: generation_token
      })
    ]

    for state <- malformed_states,
        output <- [
          inspect(state),
          state |> then(&MatchError.exception(term: &1)) |> Exception.message()
        ] do
      assert output =~ "phase: :invalid"
      assert output =~ "counter: :invalid"
      assert output =~ "chunk_count: :invalid"
      assert output =~ "plaintext_bytes: :invalid"
      assert output =~ "pending_bytes: #{byte_size(pending_plaintext)}"
      refute output =~ "#Inspect.Error"
      refute output =~ key
      refute output =~ pending_plaintext
      refute output =~ inspect(plaintext_hash)
      refute output =~ inspect(generation_token)
      refute output =~ "key:"
      refute output =~ "pending_plaintext:"
      refute output =~ "plaintext_hash:"
      refute output =~ "generation_token:"
    end
  end

  test "streamed records and final metadata equal the pinned whole-buffer encoding" do
    plaintext = "authenticated test vector"
    context = vector(plaintext)
    nonce_prefix = <<32, 33, 34, 35, 36, 37, 38, 39>>

    assert {:ok, expected} = ChunkedAEAD.encode_vector(context, nonce_prefix)
    assert {:ok, header, state} = ChunkedAEAD.init_encrypt_vector(context, nonce_prefix)
    assert {:ok, record, state} = ChunkedAEAD.encrypt_chunk(state, plaintext)

    assert {:ok, final, summary, finalized_state} =
             ChunkedAEAD.finalize(state)

    assert header <> record <> final == expected

    assert summary == %{
             plaintext_bytes: byte_size(plaintext),
             chunk_count: 1,
             plaintext_sha256: :crypto.hash(:sha256, plaintext)
           }

    assert {:error, :already_finalized} = ChunkedAEAD.finalize(finalized_state)
  end

  test "the same open state cannot sequentially encrypt two different chunks" do
    context = vector("linear state")
    assert {:ok, _header, state} = ChunkedAEAD.init_encrypt(context)

    assert {:ok, _first_record, next_state} =
             ChunkedAEAD.encrypt_chunk(state, "first")

    assert {:error, :state_consumed} =
             ChunkedAEAD.encrypt_chunk(state, "second")

    assert {:error, :state_consumed} = ChunkedAEAD.finalize(state)
    assert {:ok, _final, _summary, _finalized_state} = ChunkedAEAD.finalize(next_state)
  end

  test "concurrent branches of the same open state permit exactly one encryption" do
    context = vector("concurrent linear state")
    assert {:ok, _header, state} = ChunkedAEAD.init_encrypt(context)

    tasks =
      for plaintext <- ["first", "second"] do
        Task.async(fn ->
          receive do
            :go -> ChunkedAEAD.encrypt_chunk(state, plaintext)
          end
        end)
      end

    Enum.each(tasks, &send(&1.pid, :go))
    results = Task.await_many(tasks)

    assert Enum.count(results, &match?({:ok, _record, _next_state}, &1)) == 1
    assert Enum.count(results, &match?({:error, :state_consumed}, &1)) == 1
    assert {:error, :state_consumed} = ChunkedAEAD.finalize(state)
  end

  test "the same open state can be finalized only once" do
    context = vector("")
    assert {:ok, _header, state} = ChunkedAEAD.init_encrypt(context)

    assert {:ok, _final, _summary, finalized_state} = ChunkedAEAD.finalize(state)
    assert {:error, :state_consumed} = ChunkedAEAD.finalize(state)
    assert {:error, :state_consumed} = ChunkedAEAD.encrypt_chunk(state, "too late")
    assert {:error, :already_finalized} = ChunkedAEAD.finalize(finalized_state)

    assert {:error, :already_finalized} =
             ChunkedAEAD.encrypt_chunk(finalized_state, "too late")
  end

  test "finalize racing encryption on the same open state permits exactly one operation" do
    context = vector("race")
    assert {:ok, _header, state} = ChunkedAEAD.init_encrypt(context)

    operations = [
      fn -> ChunkedAEAD.finalize(state) end,
      fn -> ChunkedAEAD.encrypt_chunk(state, "race") end
    ]

    tasks =
      for operation <- operations do
        Task.async(fn ->
          receive do
            :go -> operation.()
          end
        end)
      end

    Enum.each(tasks, &send(&1.pid, :go))
    results = Task.await_many(tasks)

    assert Enum.count(results, &match?({:ok, _, _, _}, &1)) +
             Enum.count(results, &match?({:ok, _, _}, &1)) == 1

    assert Enum.count(results, &match?({:error, :state_consumed}, &1)) == 1
    assert {:error, :state_consumed} = ChunkedAEAD.finalize(state)
    assert {:error, :state_consumed} = ChunkedAEAD.encrypt_chunk(state, "too late")
  end

  test "streaming supports full chunks, one short final chunk, and empty objects" do
    full_chunk = :binary.copy(<<7>>, Format.chunk_size())
    tail = "tail"
    plaintext = full_chunk <> tail
    context = vector(plaintext)
    nonce_prefix = <<1, 3, 5, 7, 9, 11, 13, 15>>

    assert {:ok, expected} = ChunkedAEAD.encode_vector(context, nonce_prefix)
    assert {:ok, header, state} = ChunkedAEAD.init_encrypt_vector(context, nonce_prefix)
    assert {:ok, first, state} = ChunkedAEAD.encrypt_chunk(state, full_chunk)
    assert {:ok, second, state} = ChunkedAEAD.encrypt_chunk(state, tail)
    assert {:ok, final, summary, _finalized_state} = ChunkedAEAD.finalize(state)

    assert second == ""
    assert IO.iodata_to_binary([header, first, second, final]) == expected
    assert summary.plaintext_bytes == byte_size(plaintext)
    assert summary.chunk_count == 2
    assert summary.plaintext_sha256 == :crypto.hash(:sha256, plaintext)

    empty_context = vector("")

    assert {:ok, empty_expected} =
             ChunkedAEAD.encode_vector(empty_context, nonce_prefix)

    assert {:ok, empty_header, empty_state} =
             ChunkedAEAD.init_encrypt_vector(empty_context, nonce_prefix)

    assert {:ok, empty_final, empty_summary, _finalized_state} =
             ChunkedAEAD.finalize(empty_state)

    assert empty_header <> empty_final == empty_expected

    assert empty_summary == %{
             plaintext_bytes: 0,
             chunk_count: 0,
             plaintext_sha256: :crypto.hash(:sha256, "")
           }
  end

  test "streaming rejects reserved counters and malformed state" do
    context = vector("bounds")
    assert {:ok, _header, state} = ChunkedAEAD.init_encrypt(context)

    exhausted =
      state
      |> Map.put(:counter, Format.final_counter())
      |> Map.put(:chunk_count, Format.final_counter())
      |> Map.put(
        :plaintext_bytes,
        Format.final_counter() * Format.chunk_size()
      )

    assert {:error, :chunk_count_overflow} =
             ChunkedAEAD.encrypt_chunk(exhausted, "reserved")

    overflowed =
      exhausted
      |> Map.put(:counter, Format.final_counter() + 1)
      |> Map.put(:chunk_count, Format.final_counter() + 1)
      |> Map.put(
        :plaintext_bytes,
        (Format.final_counter() + 1) * Format.chunk_size()
      )

    assert {:error, :invalid_format} =
             ChunkedAEAD.encrypt_chunk(overflowed, "overflow")

    size_overflow = Map.put(state, :plaintext_bytes, 0xFFFFFFFFFFFFFFFF)

    assert {:error, :plaintext_size_overflow} =
             ChunkedAEAD.encrypt_chunk(size_overflow, "overflow")

    invalid_hash = Map.put(state, :plaintext_hash, make_ref())

    assert {:error, :invalid_format} = ChunkedAEAD.finalize(invalid_hash)
    assert {:error, :invalid_format} = ChunkedAEAD.encrypt_chunk(%{}, "malformed")
    assert {:error, :invalid_format} = ChunkedAEAD.finalize(%{})
  end

  test "rejects a stream whose chunk count would enter the reserved counter" do
    assert :ok = ChunkedAEAD.validate_chunk_count(0xFFFFFFFF)

    assert {:error, :chunk_count_overflow} =
             ChunkedAEAD.validate_chunk_count(0x1_00000000)
  end

  test "authenticates the canonical clear header in every record" do
    context = vector("header authentication")
    encoded = encode!(context)
    tampered = flip_byte(encoded, 10)
    expected = %{context | nonce_prefix: flip_byte(context.nonce_prefix, 0)}

    assert {:error, :integrity_failure} = ChunkedAEAD.decode(tampered, expected)
  end

  test "binds vault, domain, object, chunk index, and plaintext length" do
    context = vector("associated data")
    encoded = encode!(context)

    for field <- [:vault_id, :encryption_domain_id, :object_id] do
      assert {:error, :integrity_failure} =
               ChunkedAEAD.decode(encoded, Map.put(context, field, Ecto.UUID.generate()))
    end

    assert {:error, :integrity_failure} =
             encoded
             |> put_u32(@header_size, 1)
             |> ChunkedAEAD.decode(context)

    assert {:error, :integrity_failure} =
             encoded
             |> put_u32(@header_size + 4, byte_size(context.plaintext) - 1)
             |> ChunkedAEAD.decode(context)
  end

  test "rejects truncation and altered data or final tags without returning plaintext" do
    context = vector("authenticated records")
    encoded = encode!(context)

    for tampered <- [
          binary_part(encoded, 0, byte_size(encoded) - 1),
          flip_byte(encoded, @header_size + 8 + byte_size(context.plaintext)),
          flip_byte(encoded, byte_size(encoded) - 1)
        ] do
      assert {:error, :integrity_failure} = ChunkedAEAD.decode(tampered, context)
      refute_receive {:plaintext_chunk, _, _}
    end
  end

  test "rejects reordered chunks and a non-final use of the reserved counter" do
    context = vector(:binary.copy(<<7>>, Format.chunk_size()) <> "tail")
    encoded = encode!(context)
    first_size = Format.chunk_size()
    first_record_size = 8 + first_size + @tag_size
    second_record_size = 8 + 4 + @tag_size

    <<header::binary-size(@header_size), first::binary-size(first_record_size),
      second::binary-size(second_record_size), final::binary>> = encoded

    assert {:error, :integrity_failure} =
             ChunkedAEAD.decode(header <> second <> first <> final, context)

    assert {:error, :integrity_failure} =
             encoded
             |> put_u32(@header_size, Format.final_counter())
             |> ChunkedAEAD.decode(context)
  end

  test "requires the requested single-record vector index to be zero" do
    assert {:error, :invalid_format} =
             "index"
             |> vector()
             |> Map.put(:chunk_index, 1)
             |> ChunkedAEAD.encode()
  end

  test "rejects an authenticated short chunk before the final data chunk" do
    context = vector("firstsecond")
    {:ok, header} = Format.canonical_header(context)

    encoded =
      IO.iodata_to_binary([
        header,
        encrypted_data_record(context, header, 0, "first"),
        encrypted_data_record(context, header, 1, "second"),
        encrypted_final_record(context, header, "firstsecond", 2)
      ])

    assert {:error, :integrity_failure} = ChunkedAEAD.decode(encoded, context)
  end

  defp vector(plaintext) do
    %{
      format_version: 1,
      algorithm: :aes_256_gcm,
      chunk_size: Format.chunk_size(),
      key: :binary.copy(<<42>>, 32),
      nonce_prefix: <<1, 2, 3, 4, 5, 6, 7, 8>>,
      vault_id: "00000000-0000-0000-0000-000000000010",
      encryption_domain_id: "00000000-0000-0000-0000-000000000020",
      object_id: "00000000-0000-0000-0000-000000000001",
      chunk_index: 0,
      plaintext: plaintext
    }
  end

  defp encode!(context) do
    assert {:ok, encoded} = ChunkedAEAD.encode(context)
    encoded
  end

  defp put_u32(binary, offset, value) do
    <<prefix::binary-size(offset), _old::unsigned-big-32, suffix::binary>> = binary
    <<prefix::binary, value::unsigned-big-32, suffix::binary>>
  end

  defp flip_byte(binary, offset) do
    <<prefix::binary-size(offset), byte, suffix::binary>> = binary
    <<prefix::binary, Bitwise.bxor(byte, 1), suffix::binary>>
  end

  defp encrypted_data_record(context, header, counter, plaintext) do
    size = byte_size(plaintext)
    nonce = Format.nonce(context.nonce_prefix, counter)
    aad = Format.data_aad(header, counter, size)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(
        :aes_256_gcm,
        context.key,
        nonce,
        plaintext,
        aad,
        @tag_size,
        true
      )

    <<counter::unsigned-big-32, size::unsigned-big-32, ciphertext::binary, tag::binary>>
  end

  defp encrypted_final_record(context, header, plaintext, chunk_count) do
    metadata =
      <<byte_size(plaintext)::unsigned-big-64, chunk_count::unsigned-big-32,
        :crypto.hash(:sha256, plaintext)::binary>>

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(
        :aes_256_gcm,
        context.key,
        Format.nonce(context.nonce_prefix, Format.final_counter()),
        metadata,
        Format.final_aad(header),
        @tag_size,
        true
      )

    <<Format.final_counter()::unsigned-big-32, byte_size(metadata)::unsigned-big-32,
      ciphertext::binary, tag::binary>>
  end
end
