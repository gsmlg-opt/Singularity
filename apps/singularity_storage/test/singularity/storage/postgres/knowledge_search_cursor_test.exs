defmodule Singularity.Storage.Postgres.KnowledgeSearchCursorTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.Error

  @cursor Singularity.Storage.Postgres.KnowledgeSearchCursor
  @secret "0123456789abcdef0123456789abcdef"
  @owner "00000000-0000-4000-8000-000000000a03"
  @tag_a "00000000-0000-4000-8000-000000000a04"
  @tag_b "00000000-0000-4000-8000-000000000a05"
  @resource "00000000-0000-4000-8000-000000000a06"
  @version "00000000-0000-4000-8000-000000000a07"
  @fragment String.duplicate("a", 64)
  @filter "PofTx3MRI3jfifpYOP6yyhRTd31QsGhCV1SoiP8cY28"
  @mac "4QJe4uWEetM3NXKTeKbW5G-uOuPbhhy6_X9Aa-cSAgc"

  test "matches an independently calculated framed HMAC vector" do
    # Calculated independently with Perl pack("Q>", length(field)) and OpenSSL HMAC-SHA256.
    assert {:ok, token} = encode(key(), query())
    assert {:ok, json} = Base.url_decode64(token, padding: false)
    assert {:ok, data} = JSON.decode(json)
    assert data == Map.merge(payload(), %{"f" => @filter, "h" => @mac})
    assert byte_size(token) <= 2_048
    assert {:ok, decoded} = decode(token, query())
    assert decoded === key()
  end

  test "document ordinal and deterministic entry identity survive the complete tuple" do
    document = %{key() | ordinal: 9_223_372_036_854_775_807, entry_id: "document:" <> @fragment}
    document_query = %{query() | kind: :document}
    assert {:ok, token} = encode(document, document_query)
    assert {:ok, ^document} = decode(token, document_query)
    assert {:ok, nil} = decode(nil, document_query)
  end

  test "limit is independent while every owner and filter field is bound" do
    assert {:ok, token} = encode(key(), query())
    assert {:ok, decoded} = decode(token, %{query() | limit: 1, cursor: token})
    assert decoded === key()
    assert {:ok, ^token} = encode(key(), %{query() | limit: 50})

    for changed <- [
          %{query() | owner_scope_id: @resource},
          %{query() | q: "other"},
          %{query() | kind: :note},
          %{query() | tag_ids: [@tag_a]},
          %{query() | tag_ids: []}
        ] do
      assert_invalid(decode(token, changed))
    end
  end

  test "filter fingerprint is keyed and plaintext filters never enter the token" do
    q = %{query() | q: "confidential query needle"}
    assert {:ok, token} = encode(key(), q)
    assert {:ok, encoded} = Base.url_decode64(token, padding: false)

    for private <- [q.q, @owner, @tag_a, @tag_b, "private", "title", "body", "locator"] do
      refute String.contains?(encoded, private)
    end

    assert_invalid(decode(token, q, String.duplicate("x", 32)))
    assert {:ok, other} = encode(key(), q, String.duplicate("x", 32))
    assert token != other
  end

  test "legacy cursor and filter domains are rejected even with valid signatures" do
    assert_invalid(decode(signed(payload(), "note-search-cursor"), query()))
    assert_invalid(decode(signed(payload(), "asset-search-cursor"), query()))

    old_filter = fingerprint(query(), "note-search-filter")
    assert_invalid(decode(signed(Map.put(payload(), "f", old_filter)), query()))
  end

  test "properly signed malformed envelope fields return sanitized invalid" do
    for malformed <- [
          Map.put(payload(), "v", 2),
          Map.put(payload(), "v", 1.0),
          Map.put(payload(), "unknown", "private content"),
          Map.delete(payload(), "e"),
          Map.put(payload(), "f", "wrong fingerprint"),
          Map.put(payload(), "r", -1),
          Map.put(payload(), "r", 7_000_001),
          Map.put(payload(), "r", 1.0),
          Map.put(payload(), "r", nil),
          Map.put(payload(), "o", -1),
          Map.put(payload(), "o", 9_223_372_036_854_775_808),
          Map.put(payload(), "o", 0.0),
          Map.put(payload(), "i", String.upcase(@resource)),
          Map.put(payload(), "j", "invalid"),
          Map.put(payload(), "t", "2026-02-30T01:02:03Z"),
          Map.put(payload(), "t", "2026-10-09T01:02:03+08:00"),
          Map.put(payload(), "t", "2026-10-09T01:02:03"),
          Map.put(payload(), "e", "note:" <> @resource),
          Map.put(payload(), "e", "document:" <> String.duplicate("A", 64)),
          Map.put(payload(), "e", "document:short"),
          Map.put(payload(), "e", "note:" <> @version <> <<0>>)
        ] do
      assert_invalid(decode(signed(malformed), query()))
    end

    assert_invalid(decode(signed(%{payload() | "o" => 1}), query()))
    assert_invalid(decode(signed(payload()), %{query() | kind: :document}))
    assert_invalid(decode(signed(payload()), %{query() | q: ""}))
  end

  test "rejects tampering, malformed JSON, duplicate keys, and oversized tokens" do
    assert {:ok, token} = encode(key(), query())
    assert_invalid(decode(String.slice(token, 0..-2//1) <> "!", query()))
    assert_invalid(decode(signed(Map.put(payload(), "r", 1)) <> "=", query()))

    for value <- ["", " ", "!", <<255>>, "a" <> <<0>>, 12, %{}, String.duplicate("a", 2_049)] do
      assert_invalid(decode(value, query()))
    end

    for json <- ["null", "[]", "{", JSON.encode!(%{"private" => String.duplicate("x", 2_049)})] do
      assert_invalid(decode(Base.url_encode64(json, padding: false), query()))
    end

    assert {:ok, json} = Base.url_decode64(token, padding: false)
    duplicated = String.replace_prefix(json, "{", "{\"v\":1,")
    assert_invalid(decode(Base.url_encode64(duplicated, padding: false), query()))

    tampered = payload() |> Map.put("r", 0) |> Map.put("h", @mac) |> JSON.encode!()
    assert_invalid(decode(Base.url_encode64(tampered, padding: false), query()))
  end

  test "normalized queries are revalidated before encode or decode including nil start" do
    for malformed <- [
          nil,
          [],
          Map.put(query(), :title, "private content"),
          Map.delete(query(), :limit),
          Map.put(query(), "q", "needle"),
          Map.put(query(), :__struct__, DateTime),
          %{query() | owner_scope_id: String.upcase(@owner)},
          %{query() | classification: :public},
          %{query() | policy_version: 2},
          %{query() | policy_version: 1.0},
          %{query() | q: " needle "},
          %{query() | q: String.duplicate(" ", 1_025)},
          %{query() | q: <<255>>},
          %{query() | q: "a" <> <<0>>},
          %{query() | kind: "all"},
          %{query() | kind: :unknown},
          %{query() | tag_ids: [@tag_b, @tag_a]},
          %{query() | tag_ids: [@tag_a, @tag_a]},
          %{query() | tag_ids: List.duplicate(@tag_a, 21)},
          %{query() | tag_ids: ["invalid"]},
          %{query() | tag_ids: [String.upcase(@tag_a)]},
          %{query() | tag_ids: @tag_a},
          %{query() | limit: 0},
          %{query() | limit: 51},
          %{query() | limit: 20.0},
          %{query() | cursor: ""},
          %{query() | cursor: String.duplicate("a", 2_049)},
          %{query() | cursor: <<255>>},
          %{query() | cursor: "a" <> <<0>>}
        ] do
      assert_invalid(encode(key(), malformed))
      assert_invalid(decode(nil, malformed))
    end
  end

  test "query and token boundary values remain supported" do
    q = %{query() | q: String.duplicate("界", 341) <> "a", tag_ids: [], limit: 50}
    assert byte_size(q.q) == 1_024
    assert {:ok, token} = encode(key(), q)
    assert {:ok, decoded} = decode(token, q)
    assert decoded === key()
    assert {:ok, nil} = decode(nil, %{q | cursor: String.duplicate("a", 2_048)})
  end

  test "invalid boundary maps and forged datetime structs never enter tokens" do
    for malformed <- [
          nil,
          [],
          Map.put(key(), :fragment_id, @fragment),
          Map.put(key(), :__struct__, DateTime),
          Map.delete(key(), :rank),
          %{key() | rank: 7_000_001},
          %{key() | rank: -1},
          %{key() | rank: 1.0},
          %{key() | resource_id: "invalid"},
          %{key() | resource_version_id: String.upcase(@version)},
          %{key() | ordinal: 1},
          %{key() | ordinal: 9_223_372_036_854_775_808},
          %{key() | entry_id: "note:" <> @resource},
          %{key() | entry_id: "document:invalid"},
          %{key() | source_inserted_at: ~N[2026-10-09 01:02:03]},
          %{key() | source_inserted_at: %{key().source_inserted_at | day: 32}},
          %{key() | source_inserted_at: %{key().source_inserted_at | utc_offset: 1}},
          %{
            key()
            | source_inserted_at: %{key().source_inserted_at | zone_abbr: "private content"}
          },
          %{
            key()
            | source_inserted_at: Map.put(key().source_inserted_at, :body, "private content")
          },
          %{key() | source_inserted_at: %{key().source_inserted_at | microsecond: {1, 0}}}
        ] do
      assert_invalid(encode(malformed, query()))
    end

    assert_invalid(encode(key(), %{query() | q: ""}))
    assert_invalid(encode(key(), %{query() | kind: :document}))
    empty = %{query() | q: ""}
    boundary = %{key() | rank: 0}
    assert {:ok, token} = encode(boundary, empty)
    assert {:ok, ^boundary} = decode(token, empty)
  end

  test "invalid secrets return sanitized invalid without exceptions or logs" do
    for secret <- [nil, 32, %{}, [], "", String.duplicate("x", 31)] do
      assert_invalid(encode(key(), query(), secret))
      assert_invalid(decode(nil, query(), secret))
      assert_invalid(decode(signed(payload()), query(), secret))
    end
  end

  defp query do
    %{
      owner_scope_id: @owner,
      classification: :private,
      q: "needle",
      kind: :all,
      tag_ids: [@tag_a, @tag_b],
      limit: 20,
      cursor: nil,
      policy_version: 1
    }
  end

  defp key do
    %{
      rank: 7_000_000,
      source_inserted_at: ~U[2026-10-09 01:02:03.123456Z],
      resource_id: @resource,
      resource_version_id: @version,
      ordinal: 0,
      entry_id: "note:" <> @version
    }
  end

  defp payload do
    %{
      "v" => 1,
      "f" => @filter,
      "r" => 7_000_000,
      "t" => "2026-10-09T01:02:03.123456Z",
      "i" => @resource,
      "j" => @version,
      "o" => 0,
      "e" => "note:" <> @version
    }
  end

  defp signed(data, domain \\ "knowledge-search-cursor:v1") do
    fields = Enum.map(~w[v f r t i j o e], &reference_text(data[&1]))
    mac = reference_mac(domain, fields)
    data |> Map.put("h", mac) |> JSON.encode!() |> Base.url_encode64(padding: false)
  end

  defp fingerprint(q, domain) do
    reference_mac(domain, [
      q.owner_scope_id,
      "private",
      q.q,
      Atom.to_string(q.kind),
      "1",
      Integer.to_string(length(q.tag_ids)) | q.tag_ids
    ])
  end

  defp reference_mac(domain, fields) do
    framed =
      Enum.map(fields, fn field -> <<byte_size(field)::unsigned-big-64, field::binary>> end)

    :crypto.mac(:hmac, :sha256, @secret, [domain, <<0>>, framed])
    |> Base.url_encode64(padding: false)
  end

  defp reference_text(value) when is_binary(value), do: value
  defp reference_text(value), do: JSON.encode!(value)

  defp encode(key, q, secret \\ @secret), do: call(:encode, [key, q, secret])
  defp decode(token, q, secret \\ @secret), do: call(:decode, [token, q, secret])

  defp call(function, args) do
    assert Code.ensure_loaded?(@cursor), "knowledge search cursor module must exist"
    apply(@cursor, function, args)
  end

  defp assert_invalid(result), do: assert(result == {:error, %Error{code: :invalid}})
end
