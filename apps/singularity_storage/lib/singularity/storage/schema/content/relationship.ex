defmodule Singularity.Storage.Schema.Content.Relationship do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @schema_prefix "content"
  @fields ~w(id vault_id classification source_resource_id target_resource_id target_resource_version_id type created_by_principal_id inserted_at)a

  schema "relationships" do
    field :id, Ecto.UUID, primary_key: true
    field :vault_id, Ecto.UUID
    field :classification, Ecto.Enum, values: [:private]
    field :source_resource_id, Ecto.UUID
    field :target_resource_id, Ecto.UUID
    field :target_resource_version_id, Ecto.UUID
    field :type, Ecto.Enum, values: [:related_to, :references, :derived_from]
    field :created_by_principal_id, Ecto.UUID
    field :inserted_at, :utc_datetime_usec
  end

  def create_changeset(record, attrs) do
    record
    |> cast(attrs, @fields, empty_values: [])
    |> validate_required(@fields -- [:target_resource_version_id])
    |> validate_inclusion(:classification, [:private])
    |> validate_distinct(:source_resource_id, :target_resource_id)
    |> unique_constraint([:id], name: :relationships_pkey)
    |> unique_constraint([:vault_id, :source_resource_id, :target_resource_id, :type],
      name: :relationships_owner_source_target_type_key
    )
    |> foreign_key_constraint(:source_resource_id, name: :relationships_source_fkey)
    |> foreign_key_constraint(:target_resource_id, name: :relationships_target_fkey)
    |> foreign_key_constraint(:target_resource_version_id,
      name: :relationships_target_version_fkey
    )
    |> foreign_key_constraint(:created_by_principal_id,
      name: :relationships_created_by_principal_fkey
    )
    |> check_constraint(:classification, name: :relationships_private_check)
    |> check_constraint(:type, name: :relationships_type_check)
    |> check_constraint(:target_resource_id, name: :relationships_self_check)
    |> check_constraint(:source_resource_id, name: :relationships_resource_check)
  end

  defp validate_distinct(changeset, source, target) do
    if not is_nil(get_field(changeset, source)) and
         get_field(changeset, source) == get_field(changeset, target) do
      add_error(changeset, target, "must differ from source")
    else
      changeset
    end
  end
end
