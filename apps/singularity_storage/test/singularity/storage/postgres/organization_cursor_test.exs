defmodule Singularity.Storage.Postgres.OrganizationCursorTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.Error

  @cursor Singularity.Storage.Postgres.OrganizationCursor
  @secret "0123456789abcdef0123456789abcdef"
  @owner "00000000-0000-4000-8000-000000000a01"
  @selector "00000000-0000-4000-8000-000000000a02"
  @last "00000000-0000-4000-8000-000000000a03"
  @operations [:resource_tags, :tag_resources, :outgoing, :incoming]
  @cursor_domain "knowledge-organization-cursor:v1"
  @fingerprint "_aRrD6Yt1NIipwTOWoNDzafqi999tvwdaCzKSYEAw0g"
  @mac "AVmOzNuhmmTIE2MClpRa58gAg-bIx778Te1HRqIikjk"

  test "matches the independent Perl framing and OpenSSL HMAC vector" do
    # Literal constants were calculated with Perl pack("Q>", length(field)) and OpenSSL HMAC-SHA256.
    assert {:ok, token} = encode(@last, cursor_binding())
    assert {:ok, json} = Base.url_decode64(token, padding: false)
    assert {:ok, data} = JSON.decode(json)
    assert data == Map.put(payload(), "h", @mac)
    assert JSON.encode!(data) == json
    assert byte_size(token) <= 2048
    assert {:ok, @last} = decode(token, cursor_binding())
  end

  test "all four fixed operations round trip and cannot replay in another direction or selector domain" do
    for operation <- @operations do
      context = %{cursor_binding() | operation: operation}
      assert {:ok, token} = encode(@last, context)
      assert {:ok, @last} = decode(token, context)
      assert {:ok, nil} = decode(nil, context)

      for other <- @operations, other != operation do
        assert_invalid(decode(token, %{context | operation: other}))
      end
    end
  end

  test "owner selector ordering version and secret are authenticated" do
    assert {:ok, token} = encode(@last, cursor_binding())

    for context <- [
          %{cursor_binding() | owner_scope_id: @last},
          %{cursor_binding() | selector_id: @last},
          %{cursor_binding() | ordering_version: 2}
        ] do
      assert_invalid(decode(token, context))
    end

    assert_invalid(decode(token, cursor_binding(), String.duplicate("x", 32)))
    assert {:ok, other} = encode(@last, cursor_binding(), String.duplicate("x", 32))
    refute other == token
  end

  test "binding is exact and does not accept client limit cursor owner aliases or capabilities" do
    for context <- [
          Map.delete(cursor_binding(), :owner_scope_id),
          Map.delete(cursor_binding(), :selector_id),
          Map.delete(cursor_binding(), :operation),
          Map.delete(cursor_binding(), :ordering_version),
          Map.put(cursor_binding(), :limit, 1),
          Map.put(cursor_binding(), :limit, 50),
          Map.put(cursor_binding(), :cursor, nil),
          Map.put(cursor_binding(), :allowed_kinds, [:note]),
          Map.put(cursor_binding(), :capabilities, ["note.read"]),
          Map.put(cursor_binding(), "owner_scope_id", @owner),
          Map.put(cursor_binding(), :ordering_version, 1.0),
          Map.put(cursor_binding(), :operation, "resource_tags"),
          Map.put(cursor_binding(), :operation, :unknown),
          Map.put(cursor_binding(), :__struct__, Error),
          nil
        ] do
      assert_invalid(encode(@last, context))
      assert_invalid(decode(nil, context))
    end
  end

  test "last owner and selector identifiers require canonical UUID text" do
    for bad <- [String.upcase(@last), "not-a-uuid", nil, 7, Ecto.UUID.dump!(@last)] do
      assert_invalid(encode(bad, cursor_binding()))

      for field <- [:owner_scope_id, :selector_id] do
        context = Map.put(cursor_binding(), field, bad)
        assert_invalid(encode(@last, context))
        assert_invalid(decode(nil, context))
      end
    end
  end

  test "owner and selector plaintext and content never enter the envelope" do
    assert {:ok, token} = encode(@last, cursor_binding())
    assert {:ok, json} = Base.url_decode64(token, padding: false)
    refute json =~ @owner
    refute json =~ @selector
    refute json =~ "resource_tags"
    assert Map.keys(JSON.decode!(json)) |> Enum.sort() == ~w[f h i v]
  end

  test "properly signed malformed envelopes are rejected rather than partially decoded" do
    for malformed <- [
          Map.delete(payload(), "i"),
          Map.put(payload(), "i", String.upcase(@last)),
          Map.put(payload(), "i", nil),
          Map.put(payload(), "v", 2),
          Map.put(payload(), "v", 1.0),
          Map.put(payload(), "f", "wrong-binding"),
          Map.put(payload(), "owner", "CANARY_CURSOR_PRIVATE")
        ] do
      assert_invalid(decode(signed(malformed), cursor_binding()))
    end

    old_binding =
      reference_mac("knowledge-search-filter:v1", [@owner, @selector, "resource_tags", "1"])

    assert_invalid(decode(signed(Map.put(payload(), "f", old_binding)), cursor_binding()))
    assert_invalid(decode(signed(payload(), "knowledge-search-cursor:v1"), cursor_binding()))
  end

  test "tampering malformed JSON duplicate keys noncanonical base64 and oversized tokens fail sanitized" do
    assert {:ok, token} = encode(@last, cursor_binding())
    duplicate = "{\"v\":1,\"v\":1,\"f\":\"#{@fingerprint}\",\"i\":\"#{@last}\",\"h\":\"#{@mac}\"}"
    tampered = Map.put(Map.put(payload(), "h", @mac), "i", @selector)

    for malformed <- [
          "CANARY_CURSOR_PRIVATE",
          "%%%",
          token <> "=",
          String.duplicate("a", 2049),
          Base.url_encode64("{", padding: false),
          Base.url_encode64(duplicate, padding: false),
          Base.url_encode64(JSON.encode!(tampered), padding: false),
          7,
          :done,
          <<255>>
        ] do
      assert_invalid(decode(malformed, cursor_binding()))
    end
  end

  test "nil start still validates the secret and complete binding" do
    for secret <- [nil, 7, "short", String.duplicate("x", 31)] do
      assert_invalid(encode(@last, cursor_binding(), secret))
      assert_invalid(decode(nil, cursor_binding(), secret))
    end
  end

  defp cursor_binding do
    %{
      owner_scope_id: @owner,
      selector_id: @selector,
      operation: :resource_tags,
      ordering_version: 1
    }
  end

  defp payload, do: %{"v" => 1, "f" => @fingerprint, "i" => @last}

  defp encode(last, context, secret \\ @secret),
    do: apply(@cursor, :encode, [last, context, secret])

  defp decode(token, context, secret \\ @secret),
    do: apply(@cursor, :decode, [token, context, secret])

  defp signed(data, domain \\ @cursor_domain) do
    fields = Enum.map(~w[v f i], fn key -> reference_text(data[key]) end)

    data
    |> Map.put("h", reference_mac(domain, fields))
    |> JSON.encode!()
    |> Base.url_encode64(padding: false)
  end

  defp reference_mac(domain, fields) do
    frames =
      Enum.map(fields, fn field -> <<byte_size(field)::unsigned-big-64, field::binary>> end)

    :crypto.mac(:hmac, :sha256, @secret, [domain, <<0>>, frames])
    |> Base.url_encode64(padding: false)
  end

  defp reference_text(value) when is_binary(value), do: value
  defp reference_text(value), do: JSON.encode!(value)

  defp assert_invalid(result) do
    assert {:error, %Error{code: :invalid, message: nil, details: %{}, retryable?: false} = error} =
             result

    assert error.details == %{}
    refute inspect(error) =~ "CANARY"
  end
end
