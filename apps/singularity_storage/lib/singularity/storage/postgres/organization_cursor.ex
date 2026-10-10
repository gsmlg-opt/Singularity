defmodule Singularity.Storage.Postgres.OrganizationCursor do
  @moduledoc false

  alias Singularity.Core.{Error, KnowledgeEncoding, KnowledgeValidation, Types}

  @binding_domain "knowledge-organization-binding:v1"
  @cursor_domain "knowledge-organization-cursor:v1"
  @binding_fields [:owner_scope_id, :selector_id, :operation, :ordering_version]
  @payload_fields ~w[f h i v]
  @operations [:resource_tags, :tag_resources, :outgoing, :incoming]
  @cursor_bytes 2048

  @spec encode(term(), term(), term()) :: {:ok, binary()} | {:error, Error.t()}
  def encode(last_uuid, binding, secret) do
    with true <- valid_secret?(secret),
         true <- valid_binding?(binding),
         {:ok, _last_uuid} <- Types.canonical_uuid(%{id: last_uuid}, :id) do
      data = %{"v" => 1, "f" => fingerprint(binding, secret), "i" => last_uuid}

      token =
        data
        |> Map.put("h", integrity(data, secret))
        |> JSON.encode!()
        |> Base.url_encode64(padding: false)

      if valid_cursor?(token), do: {:ok, token}, else: invalid()
    else
      _ -> invalid()
    end
  rescue
    _ -> invalid()
  end

  @spec decode(term(), term(), term()) :: {:ok, binary() | nil} | {:error, Error.t()}
  def decode(token, binding, secret) do
    with true <- valid_secret?(secret),
         true <- valid_binding?(binding),
         true <- valid_cursor?(token) do
      decode_validated(token, binding, secret)
    else
      _ -> invalid()
    end
  rescue
    _ -> invalid()
  end

  defp decode_validated(nil, _binding, _secret), do: {:ok, nil}

  defp decode_validated(token, binding, secret) do
    with {:ok, encoded} <- Base.url_decode64(token, padding: false),
         true <- Base.url_encode64(encoded, padding: false) == token,
         {:ok, data} <- JSON.decode(encoded),
         true <- exact_fields?(data, @payload_fields),
         # Producer canonical bytes also reject JSON with duplicate keys.
         true <- JSON.encode!(data) == encoded,
         1 <- data["v"],
         true <- is_integer(data["v"]),
         {:ok, last_uuid} <- Types.canonical_uuid(%{id: data["i"]}, :id),
         true <- secure_compare(data["f"], fingerprint(binding, secret)),
         true <- secure_compare(data["h"], integrity(data, secret)) do
      {:ok, last_uuid}
    else
      _ -> invalid()
    end
  end

  defp valid_binding?(binding) do
    with true <- exact_fields?(binding, @binding_fields),
         {:ok, _owner} <- Types.canonical_uuid(binding, :owner_scope_id),
         {:ok, _selector} <- Types.canonical_uuid(binding, :selector_id),
         true <- binding.operation in @operations,
         1 <- binding.ordering_version,
         true <- is_integer(binding.ordering_version) do
      true
    else
      _ -> false
    end
  end

  defp fingerprint(binding, secret) do
    mac(
      @binding_domain,
      [binding.owner_scope_id, binding.selector_id, Atom.to_string(binding.operation), "1"],
      secret
    )
  end

  defp integrity(data, secret),
    do: mac(@cursor_domain, ["1", data["f"], data["i"]], secret)

  defp mac(domain, fields, secret) do
    :crypto.mac(:hmac, :sha256, secret, [
      domain,
      <<0>>,
      Enum.map(fields, &KnowledgeEncoding.frame/1)
    ])
    |> Base.url_encode64(padding: false)
  end

  defp secure_compare(left, right)
       when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right),
       do: :crypto.hash_equals(left, right)

  defp secure_compare(_, _), do: false

  defp exact_fields?(map, fields) when is_map(map) and not is_struct(map),
    do: map_size(map) == length(fields) and Enum.all?(fields, &Map.has_key?(map, &1))

  defp exact_fields?(_, _), do: false

  defp valid_cursor?(nil), do: true

  defp valid_cursor?(cursor) do
    with {:ok, value} <- KnowledgeValidation.string(cursor, @cursor_bytes),
         true <- String.trim(value) != "" do
      true
    else
      _ -> false
    end
  end

  defp valid_secret?(secret), do: is_binary(secret) and byte_size(secret) >= 32
  defp invalid, do: {:error, Error.new(:invalid)}
end
