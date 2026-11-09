defmodule Singularity.Domains.Notes.Command do
  @moduledoc "Canonical preparation for private note mutation commands."

  alias Singularity.Core.Error
  alias Singularity.Core.NoteSnapshot
  alias Singularity.Core.Types

  @operations [:create, :save, :merge, :tombstone, :restore]
  @common_keys [:mutation_id, :principal_id, :vault_id, :classification, :correlation_id]
  @operation_keys %{
    create: [:title, :markdown],
    save: [:resource_id, :base_version_id, :title, :markdown],
    merge: [
      :resource_id,
      :conflict_id,
      :expected_current_version_id,
      :competing_version_id,
      :title,
      :markdown
    ],
    tombstone: [:resource_id, :expected_current_version_id],
    restore: [:resource_id]
  }

  @enforce_keys [
    :operation,
    :mutation_id,
    :principal_id,
    :vault_id,
    :classification,
    :correlation_id
  ]
  defstruct @enforce_keys ++
              [
                :resource_id,
                :base_version_id,
                :conflict_id,
                :expected_current_version_id,
                :competing_version_id,
                :snapshot
              ]

  @type t :: %__MODULE__{
          operation: :create | :save | :merge | :tombstone | :restore,
          mutation_id: Types.id(),
          principal_id: Types.id(),
          vault_id: Types.id(),
          classification: :private,
          correlation_id: Types.id(),
          resource_id: Types.id() | nil,
          base_version_id: Types.id() | nil,
          conflict_id: Types.id() | nil,
          expected_current_version_id: Types.id() | nil,
          competing_version_id: Types.id() | nil,
          snapshot: NoteSnapshot.t() | nil
        }

  @spec new(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def new(operation, raw_map) when operation in @operations and is_map(raw_map) do
    with {:ok, attrs} <- canonical_attrs(operation, raw_map),
         {:ok, command} <- build(operation, attrs) do
      {:ok, command}
    end
  end

  def new(_operation, _raw_map), do: invalid()

  @spec fingerprint_term(t()) :: tuple()
  def fingerprint_term(%__MODULE__{
        operation: :create,
        mutation_id: mutation_id,
        snapshot: snapshot
      }) do
    {:note_mutation_v1, :create, mutation_id, snapshot.title, snapshot.markdown}
  end

  def fingerprint_term(%__MODULE__{
        operation: :save,
        mutation_id: mutation_id,
        resource_id: resource_id,
        base_version_id: base_version_id,
        snapshot: snapshot
      }) do
    {:note_mutation_v1, :save, mutation_id, resource_id, base_version_id, snapshot.title,
     snapshot.markdown}
  end

  def fingerprint_term(%__MODULE__{
        operation: :merge,
        mutation_id: mutation_id,
        resource_id: resource_id,
        conflict_id: conflict_id,
        expected_current_version_id: expected_current_version_id,
        competing_version_id: competing_version_id,
        snapshot: snapshot
      }) do
    {:note_mutation_v1, :merge, mutation_id, resource_id, conflict_id,
     expected_current_version_id, competing_version_id, snapshot.title, snapshot.markdown}
  end

  def fingerprint_term(%__MODULE__{
        operation: :tombstone,
        mutation_id: mutation_id,
        resource_id: resource_id,
        expected_current_version_id: expected_current_version_id
      }) do
    {:note_mutation_v1, :tombstone, mutation_id, resource_id, expected_current_version_id}
  end

  def fingerprint_term(%__MODULE__{
        operation: :restore,
        mutation_id: mutation_id,
        resource_id: resource_id
      }) do
    {:note_mutation_v1, :restore, mutation_id, resource_id}
  end

  defp canonical_attrs(operation, raw_map) do
    keys = @common_keys ++ Map.fetch!(@operation_keys, operation)

    with true <- Enum.all?(Map.keys(raw_map), &known_key?(&1, keys)),
         {:ok, attrs} <- canonical_values(raw_map, keys),
         :ok <- require_private(attrs.classification) do
      {:ok, attrs}
    else
      _invalid -> invalid()
    end
  end

  defp known_key?(key, keys) when is_atom(key), do: key in keys
  defp known_key?(key, keys) when is_binary(key), do: key in Enum.map(keys, &Atom.to_string/1)
  defp known_key?(_key, _keys), do: false

  defp canonical_values(raw_map, keys) do
    Enum.reduce_while(keys, {:ok, %{}}, fn key, {:ok, attrs} ->
      case canonical_value(raw_map, key) do
        {:ok, value} -> {:cont, {:ok, Map.put(attrs, key, value)}}
        {:error, %Error{}} = error -> {:halt, error}
      end
    end)
  end

  defp canonical_value(raw_map, key) do
    atom_value = Map.fetch(raw_map, key)
    string_value = Map.fetch(raw_map, Atom.to_string(key))

    case {atom_value, string_value} do
      {{:ok, value}, :error} ->
        {:ok, value}

      {:error, {:ok, value}} ->
        {:ok, value}

      {{:ok, atom_value}, {:ok, string_value}} when atom_value === string_value ->
        {:ok, atom_value}

      {{:ok, _atom_value}, {:ok, _string_value}} ->
        invalid()

      {:error, :error} ->
        invalid()
    end
  end

  defp build(operation, attrs) do
    with {:ok, mutation_id} <- Types.canonical_uuid(attrs, :mutation_id),
         {:ok, principal_id} <- Types.canonical_uuid(attrs, :principal_id),
         {:ok, vault_id} <- Types.canonical_uuid(attrs, :vault_id),
         {:ok, correlation_id} <- Types.canonical_uuid(attrs, :correlation_id),
         {:ok, operation_fields} <- operation_fields(operation, attrs) do
      {:ok,
       struct!(
         __MODULE__,
         Map.merge(
           %{
             operation: operation,
             mutation_id: mutation_id,
             principal_id: principal_id,
             vault_id: vault_id,
             classification: :private,
             correlation_id: correlation_id
           },
           operation_fields
         )
       )}
    end
  end

  defp operation_fields(:create, attrs) do
    with {:ok, snapshot} <- NoteSnapshot.initial(note_attrs(attrs)) do
      {:ok, %{snapshot: snapshot}}
    end
  end

  defp operation_fields(:save, attrs) do
    with {:ok, resource_id} <- Types.canonical_uuid(attrs, :resource_id),
         {:ok, base_version_id} <- Types.canonical_uuid(attrs, :base_version_id),
         {:ok, snapshot} <-
           NoteSnapshot.normal(note_attrs(attrs) |> Map.put(:parent_version_id, base_version_id)) do
      {:ok, %{resource_id: resource_id, base_version_id: base_version_id, snapshot: snapshot}}
    end
  end

  defp operation_fields(:merge, attrs) do
    with {:ok, resource_id} <- Types.canonical_uuid(attrs, :resource_id),
         {:ok, conflict_id} <- Types.canonical_uuid(attrs, :conflict_id),
         {:ok, expected_current_version_id} <-
           Types.canonical_uuid(attrs, :expected_current_version_id),
         {:ok, competing_version_id} <- Types.canonical_uuid(attrs, :competing_version_id),
         {:ok, snapshot} <-
           NoteSnapshot.merge(
             note_attrs(attrs)
             |> Map.put(:parent_version_id, expected_current_version_id)
             |> Map.put(:merge_parent_version_id, competing_version_id)
           ) do
      {:ok,
       %{
         resource_id: resource_id,
         conflict_id: conflict_id,
         expected_current_version_id: expected_current_version_id,
         competing_version_id: competing_version_id,
         snapshot: snapshot
       }}
    end
  end

  defp operation_fields(:tombstone, attrs) do
    with {:ok, resource_id} <- Types.canonical_uuid(attrs, :resource_id),
         {:ok, expected_current_version_id} <-
           Types.canonical_uuid(attrs, :expected_current_version_id) do
      {:ok, %{resource_id: resource_id, expected_current_version_id: expected_current_version_id}}
    end
  end

  defp operation_fields(:restore, attrs) do
    with {:ok, resource_id} <- Types.canonical_uuid(attrs, :resource_id) do
      {:ok, %{resource_id: resource_id}}
    end
  end

  defp note_attrs(attrs) do
    Map.take(attrs, [:classification, :title, :markdown])
  end

  defp require_private(:private), do: :ok
  defp require_private(_classification), do: invalid()

  defp invalid, do: {:error, Error.new(:invalid)}
end
