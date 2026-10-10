defmodule Singularity.Core.OrganizationPageQueryTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.Error

  @query Singularity.Core.OrganizationPageQuery

  test "defaults contain only limit and optional cursor" do
    assert {:ok, query} = new(%{})
    assert query.__struct__ == @query
    assert Map.from_struct(query) == %{limit: 20, cursor: nil}
    assert {:ok, ^query} = validate(query)
  end

  test "fixed atom and string keys preserve equivalent aliases" do
    assert {:ok, expected} = new(%{limit: 1, cursor: "opaque-token"})
    assert {:ok, ^expected} = new(%{"limit" => 1, "cursor" => "opaque-token"})

    assert {:ok, ^expected} =
             new(%{
               :limit => 1,
               "limit" => 1,
               :cursor => "opaque-token",
               "cursor" => "opaque-token"
             })

    assert_invalid(new(%{:limit => 1, "limit" => 2}))
    assert_invalid(new(%{:cursor => nil, "cursor" => "opaque-token"}))
  end

  test "limit accepts integer endpoints and rejects noninteger or out of range values" do
    for limit <- [1, 20, 50] do
      assert {:ok, %{limit: ^limit, cursor: nil}} = new(%{limit: limit})
    end

    for limit <- [0, -1, 51, 20.0, "20", nil, true, :all] do
      assert_invalid(new(%{limit: limit}))
    end
  end

  test "cursor is optional and bounded by bytes without rewriting its content" do
    for cursor <- [nil, "opaque-token", String.duplicate("a", 2048), String.duplicate("界", 682)] do
      assert {:ok, %{cursor: ^cursor}} = new(%{cursor: cursor})
    end

    for cursor <- [
          "",
          " \t\n",
          String.duplicate("a", 2049),
          String.duplicate("界", 683),
          <<255>>,
          "token" <> <<0>>,
          7,
          :done,
          []
        ] do
      assert_invalid(new(%{cursor: cursor}))
    end
  end

  test "owner selector direction capability and content fields are never client query keys" do
    for key <- [
          :owner_scope_id,
          :vault_id,
          :principal_id,
          :resource_id,
          :tag_id,
          :operation,
          :direction,
          :allowed_kinds,
          :capabilities,
          :classification,
          :title,
          :q
        ] do
      assert_invalid(new(%{key => "CANARY_QUERY_PRIVATE"}))
      assert_invalid(new(%{Atom.to_string(key) => "CANARY_QUERY_PRIVATE"}))
    end
  end

  test "unknown string keys do not become atoms" do
    key = "organization_unknown_#{System.unique_integer([:positive])}"
    assert_raise ArgumentError, fn -> :erlang.binary_to_existing_atom(key, :utf8) end
    assert_invalid(new(%{key => "CANARY_QUERY_PRIVATE"}))
    assert_raise ArgumentError, fn -> :erlang.binary_to_existing_atom(key, :utf8) end
  end

  test "malformed containers and unrelated structs return sanitized invalid" do
    for input <- [
          nil,
          7,
          "limit",
          [1],
          [%{limit: 20}],
          [%{limit: 20} | :tail],
          Error.new(:invalid)
        ] do
      assert_invalid(new(input))
    end
  end

  test "internal query revalidation rejects missing extra and forged fields" do
    assert {:ok, query} = new(%{limit: 20, cursor: "opaque-token"})
    assert {:ok, ^query} = new(query)

    for input <- [
          Map.delete(query, :limit),
          Map.put(query, :limit, 51),
          Map.put(query, :cursor, <<255>>),
          Map.put(query, :owner_scope_id, "CANARY_QUERY_PRIVATE"),
          Map.put(query, "limit", 20),
          Map.put(query, :__struct__, Error),
          Map.from_struct(query)
        ] do
      assert_invalid(validate(input))
    end

    assert_invalid(new(Map.put(query, :allowed_kinds, [:note])))
  end

  defp new(input), do: apply(@query, :new, [input])
  defp validate(input), do: apply(@query, :validate, [input])

  defp assert_invalid(result) do
    assert {:error, %Error{code: :invalid, message: nil, details: %{}, retryable?: false} = error} =
             result

    assert error.details == %{}
  end
end
