defmodule Singularity.Core.NoteConflict do
  @moduledoc "A private note conflict with explicit resolution state."

  alias Singularity.Core.Classification
  alias Singularity.Core.Error
  alias Singularity.Core.Types

  @enforce_keys [
    :conflict_id,
    :resource_id,
    :vault_id,
    :classification,
    :base_version_id,
    :canonical_version_id,
    :competing_version_id,
    :state,
    :created_at
  ]
  defstruct @enforce_keys ++ [:resolution_version_id, :resolved_at]

  @type state :: :open | :resolved

  @type t :: %__MODULE__{
          conflict_id: Types.id(),
          resource_id: Types.id(),
          vault_id: Types.id(),
          classification: :private,
          base_version_id: Types.id(),
          canonical_version_id: Types.id(),
          competing_version_id: Types.id(),
          state: state(),
          resolution_version_id: Types.id() | nil,
          created_at: Types.timestamp(),
          resolved_at: Types.timestamp() | nil
        }

  @spec open(map() | keyword()) :: {:ok, t()} | {:error, Error.t()}
  def open(attrs), do: build(attrs, :open)

  @spec resolved(map() | keyword()) :: {:ok, t()} | {:error, Error.t()}
  def resolved(attrs), do: build(attrs, :resolved)

  defp build(attrs, state) do
    with {:ok, attrs} <- Types.attrs(attrs),
         {:ok, conflict_id} <- Types.canonical_uuid(attrs, :conflict_id),
         {:ok, resource_id} <- Types.canonical_uuid(attrs, :resource_id),
         {:ok, vault_id} <- Types.canonical_uuid(attrs, :vault_id),
         {:ok, classification} <- Classification.new(Map.get(attrs, :classification)),
         :ok <- require_private(classification),
         {:ok, base_version_id} <- Types.canonical_uuid(attrs, :base_version_id),
         {:ok, canonical_version_id} <- Types.canonical_uuid(attrs, :canonical_version_id),
         {:ok, competing_version_id} <- Types.canonical_uuid(attrs, :competing_version_id),
         {:ok, created_at} <- Types.utc_datetime(attrs, :created_at),
         {:ok, resolution_version_id, resolved_at} <- resolution(attrs, state),
         :ok <-
           require_distinct([
             base_version_id,
             canonical_version_id,
             competing_version_id,
             resolution_version_id
           ]) do
      {:ok,
       %__MODULE__{
         conflict_id: conflict_id,
         resource_id: resource_id,
         vault_id: vault_id,
         classification: classification,
         base_version_id: base_version_id,
         canonical_version_id: canonical_version_id,
         competing_version_id: competing_version_id,
         state: state,
         resolution_version_id: resolution_version_id,
         created_at: created_at,
         resolved_at: resolved_at
       }}
    end
  end

  defp resolution(attrs, :open) do
    if is_nil(Map.get(attrs, :resolution_version_id)) and is_nil(Map.get(attrs, :resolved_at)),
      do: {:ok, nil, nil},
      else: invalid()
  end

  defp resolution(attrs, :resolved) do
    with {:ok, resolution_version_id} <- Types.canonical_uuid(attrs, :resolution_version_id),
         {:ok, resolved_at} <- Types.utc_datetime(attrs, :resolved_at) do
      {:ok, resolution_version_id, resolved_at}
    end
  end

  defp require_distinct(ids) do
    if length(ids) == length(Enum.uniq(ids)), do: :ok, else: invalid()
  end

  defp require_private(:private), do: :ok
  defp require_private(_classification), do: invalid()

  defp invalid, do: {:error, Error.new(:invalid)}
end
