defmodule Singularity.Core.Types do
  @moduledoc "Shared primitive domain types and constructor validation helpers."

  alias Singularity.Core.Error

  @canonical_uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/

  @type id :: String.t()
  @type hash :: String.t()
  @type version :: pos_integer()
  @type cursor :: String.t()
  @type revision :: non_neg_integer()
  @type timestamp :: DateTime.t()
  @type metadata :: %{optional(String.t()) => term()}

  @spec attrs(term()) :: {:ok, map()} | {:error, Error.t()}
  def attrs(attrs) when is_map(attrs), do: {:ok, attrs}

  def attrs(attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs), do: {:ok, Map.new(attrs)}, else: invalid()
  end

  def attrs(_attrs), do: invalid()

  @spec opaque_string(map(), atom()) :: {:ok, String.t()} | {:error, Error.t()}
  def opaque_string(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_binary(value) ->
        if String.trim(value) == "", do: invalid(), else: {:ok, value}

      _other ->
        invalid()
    end
  end

  @spec canonical_uuid(map(), atom()) :: {:ok, String.t()} | {:error, Error.t()}
  def canonical_uuid(attrs, key) when is_map(attrs) and is_atom(key) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_binary(value) ->
        if Regex.match?(@canonical_uuid, value), do: {:ok, value}, else: invalid()

      _other ->
        invalid()
    end
  end

  @spec optional_opaque_string(map(), atom()) ::
          {:ok, String.t() | nil} | {:error, Error.t()}
  def optional_opaque_string(attrs, key) do
    case Map.get(attrs, key) do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        if(String.trim(value) == "", do: invalid(), else: {:ok, value})

      _other ->
        invalid()
    end
  end

  @spec normalized_string(map(), atom()) :: {:ok, String.t()} | {:error, Error.t()}
  def normalized_string(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_binary(value) ->
        normalize_string(value)

      _other ->
        invalid()
    end
  end

  @spec normalize_string(term()) :: {:ok, String.t()} | {:error, Error.t()}
  def normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> invalid()
      normalized -> {:ok, normalized}
    end
  end

  def normalize_string(_value), do: invalid()

  @spec non_neg_integer(map(), atom(), non_neg_integer() | :required) ::
          {:ok, non_neg_integer()} | {:error, Error.t()}
  def non_neg_integer(attrs, key, default \\ :required) do
    value =
      case {Map.fetch(attrs, key), default} do
        {{:ok, value}, _default} -> value
        {:error, :required} -> :missing
        {:error, default} -> default
      end

    if is_integer(value) and value >= 0, do: {:ok, value}, else: invalid()
  end

  @spec pos_integer(map(), atom()) :: {:ok, pos_integer()} | {:error, Error.t()}
  def pos_integer(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_integer(value) and value > 0 -> {:ok, value}
      _other -> invalid()
    end
  end

  @spec atom_value(map(), atom()) :: {:ok, atom()} | {:error, Error.t()}
  def atom_value(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_atom(value) and not is_nil(value) -> {:ok, value}
      _other -> invalid()
    end
  end

  @spec boolean(map(), atom(), boolean()) :: {:ok, boolean()} | {:error, Error.t()}
  def boolean(attrs, key, default) do
    case Map.get(attrs, key, default) do
      value when is_boolean(value) -> {:ok, value}
      _other -> invalid()
    end
  end

  @spec utc_datetime(map(), atom()) :: {:ok, DateTime.t()} | {:error, Error.t()}
  def utc_datetime(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, %DateTime{time_zone: "Etc/UTC", utc_offset: 0, std_offset: 0} = value} ->
        {:ok, value}

      _other ->
        invalid()
    end
  end

  @spec metadata(map()) :: {:ok, metadata()} | {:error, Error.t()}
  def metadata(attrs), do: string_map(Map.get(attrs, :metadata, %{}))

  @spec string_map(term()) :: {:ok, map()} | {:error, Error.t()}
  def string_map(value) when is_map(value) do
    if Enum.all?(Map.keys(value), &is_binary/1), do: {:ok, value}, else: invalid()
  end

  def string_map(_value), do: invalid()

  @spec invalid() :: {:error, Error.t()}
  def invalid, do: {:error, Error.new(:invalid)}
end
