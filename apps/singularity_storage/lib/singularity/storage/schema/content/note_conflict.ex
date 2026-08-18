defmodule Singularity.Storage.Schema.Content.NoteConflict do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @schema_prefix "content"
  @create_fields [
    :id,
    :resource_id,
    :vault_id,
    :classification,
    :base_version_id,
    :canonical_version_id,
    :competing_version_id,
    :created_at
  ]

  schema "note_conflicts" do
    field :resource_id, Ecto.UUID
    field :vault_id, Ecto.UUID
    field :classification, Ecto.Enum, values: [:private]
    field :base_version_id, Ecto.UUID
    field :canonical_version_id, Ecto.UUID
    field :competing_version_id, Ecto.UUID
    field :state, Ecto.Enum, values: [:open, :resolved]
    field :resolution_version_id, Ecto.UUID
    field :created_at, :utc_datetime_usec
    field :resolved_at, :utc_datetime_usec
  end

  def create_changeset(conflict, attrs) do
    conflict
    |> cast(attrs, @create_fields)
    |> put_change(:state, :open)
    |> validate_required(@create_fields ++ [:state])
    |> validate_inclusion(:classification, [:private])
    |> map_constraints()
  end

  def resolve_changeset(conflict, attrs) do
    conflict
    |> cast(attrs, [:resolution_version_id, :resolved_at])
    |> put_change(:state, :resolved)
    |> validate_required([:state, :resolution_version_id, :resolved_at])
    |> validate_inclusion(:state, [:resolved])
    |> map_constraints()
  end

  defp map_constraints(changeset) do
    changeset
    |> unique_constraint(:id, name: :note_conflicts_pkey)
    |> foreign_key_constraint(:base_version_id, name: :note_conflicts_base_version_fkey)
    |> foreign_key_constraint(:canonical_version_id,
      name: :note_conflicts_canonical_version_fkey
    )
    |> foreign_key_constraint(:competing_version_id,
      name: :note_conflicts_competing_version_fkey
    )
    |> foreign_key_constraint(:resolution_version_id,
      name: :note_conflicts_resolution_version_fkey
    )
    |> check_constraint(:classification, name: :note_conflicts_private_check)
    |> check_constraint(:state, name: :note_conflicts_state_check)
    |> check_constraint(:base_version_id, name: :note_conflicts_lineage_distinct_check)
    |> check_constraint(:state, name: :note_conflicts_resolution_shape_check)
    |> check_constraint(:resolution_version_id,
      name: :note_conflicts_resolution_distinct_check
    )
  end
end
