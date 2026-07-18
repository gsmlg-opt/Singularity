defmodule Singularity.Storage.Schema.Audit.BackupManifestObject do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @schema_prefix "audit"

  schema "backup_manifest_objects" do
    field :manifest_id, Ecto.UUID
    field :asset_object_id, Ecto.UUID
    field :vault_id, Ecto.UUID
    field :classification, Ecto.Enum, values: [:private, :sensitive, :restricted]
    field :inventory_position, :integer
    field :storage_ref, :string
    field :ciphertext_byte_size, :integer
    field :ciphertext_hash, :binary
    timestamps(updated_at: false, type: :utc_datetime_usec)
  end

  def create_changeset(entry, attrs) do
    entry
    |> cast(attrs, [
      :id,
      :manifest_id,
      :asset_object_id,
      :vault_id,
      :classification,
      :inventory_position,
      :storage_ref,
      :ciphertext_byte_size,
      :ciphertext_hash
    ])
    |> validate_required([
      :id,
      :manifest_id,
      :asset_object_id,
      :vault_id,
      :classification,
      :inventory_position,
      :storage_ref,
      :ciphertext_byte_size,
      :ciphertext_hash
    ])
    |> validate_number(:inventory_position, greater_than_or_equal_to: 0)
    |> validate_number(:ciphertext_byte_size, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:manifest_id,
      name: :backup_manifest_objects_manifest_vault_fkey
    )
    |> foreign_key_constraint(:asset_object_id,
      name: :backup_manifest_objects_object_vault_fkey
    )
    |> unique_constraint([:manifest_id, :asset_object_id],
      name: :backup_manifest_objects_manifest_id_asset_object_id_key
    )
    |> check_constraint(:classification,
      name: :backup_manifest_objects_classification_check
    )
    |> check_constraint(:inventory_position,
      name: :backup_manifest_objects_position_check
    )
    |> check_constraint(:ciphertext_byte_size,
      name: :backup_manifest_objects_size_check
    )
    |> check_constraint(:ciphertext_hash, name: :backup_manifest_objects_hash_check)
  end
end
