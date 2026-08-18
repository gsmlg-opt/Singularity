defmodule Singularity.Runtime.DTO.NoteValidation do
  @moduledoc false

  alias Singularity.Core.Error
  alias Singularity.Core.Types

  def exact_attrs(value, fields) when is_map(value) and is_list(fields) do
    value = if is_struct(value), do: Map.from_struct(value), else: value

    if MapSet.new(Map.keys(value)) == MapSet.new(fields),
      do: {:ok, value},
      else: integrity_failure()
  end

  def exact_attrs(_value, _fields), do: integrity_failure()

  def uuid(attrs, key) do
    case Types.canonical_uuid(attrs, key) do
      {:ok, value} -> {:ok, value}
      _invalid -> integrity_failure()
    end
  end

  def optional_uuid(attrs, key) do
    case Map.get(attrs, key) do
      nil -> {:ok, nil}
      _value -> uuid(attrs, key)
    end
  end

  def utc_datetime(attrs, key) do
    case Types.utc_datetime(attrs, key) do
      {:ok, value} -> {:ok, value}
      _invalid -> integrity_failure()
    end
  end

  def title?(value),
    do:
      is_binary(value) and String.valid?(value) and String.trim(value) != "" and
        byte_size(value) <= 255

  def markdown?(value),
    do:
      is_binary(value) and String.valid?(value) and byte_size(value) <= 1_048_576 and
        :binary.match(value, <<0>>) == :nomatch

  def cursor?(nil), do: true

  def cursor?(value) when is_binary(value),
    do:
      byte_size(value) <= 2_048 and String.valid?(value) and String.trim(value) != "" and
        :binary.match(value, <<0>>) == :nomatch

  def cursor?(_value), do: false

  def integrity_failure, do: {:error, Error.new(:integrity_failure)}
end

defmodule Singularity.Runtime.DTO.NoteSummary do
  @moduledoc "Web-safe summary of one authorized private note."

  alias Singularity.Runtime.DTO.NoteValidation

  @fields ~w(
    resource_id resource_version_id title revision display_version updated_at
    deleted? open_conflict_count
  )a
  @enforce_keys @fields
  defstruct @fields

  @type t :: %__MODULE__{
          resource_id: String.t(),
          resource_version_id: String.t(),
          title: String.t(),
          revision: non_neg_integer(),
          display_version: pos_integer(),
          updated_at: DateTime.t(),
          deleted?: boolean(),
          open_conflict_count: non_neg_integer()
        }

  @spec new(map()) :: {:ok, t()} | {:error, Singularity.Core.Error.t()}
  def new(attrs) do
    with {:ok, attrs} <- NoteValidation.exact_attrs(attrs, @fields),
         {:ok, _resource_id} <- NoteValidation.uuid(attrs, :resource_id),
         {:ok, _version_id} <- NoteValidation.uuid(attrs, :resource_version_id),
         true <- NoteValidation.title?(attrs.title),
         true <- is_integer(attrs.revision) and attrs.revision >= 0,
         true <- attrs.display_version == attrs.revision + 1,
         {:ok, _updated_at} <- NoteValidation.utc_datetime(attrs, :updated_at),
         true <- is_boolean(attrs.deleted?),
         true <- is_integer(attrs.open_conflict_count) and attrs.open_conflict_count >= 0 do
      {:ok, struct!(__MODULE__, attrs)}
    else
      _invalid -> NoteValidation.integrity_failure()
    end
  end
end
