defmodule Singularity.Storage.Schema.Audit.BackupManifest do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @schema_prefix "audit"
  @statuses [:pending, :waiting_for_backup_key, :copying, :sealed, :failed]

  schema "backup_manifests" do
    field :vault_id, Ecto.UUID
    field :classification, Ecto.Enum, values: [:private, :sensitive, :restricted]
    field :status, Ecto.Enum, values: @statuses
    field :destination_ref, :string
    field :kdf_version, :integer
    field :kdf_salt, :binary
    field :kdf_parameters, :map
    field :recovery_wrapper, :binary
    field :custody_ref, :string
    field :snapshot_id, Ecto.UUID
    field :outbox_high_water, :integer
    field :manifest_hash, :binary
    field :manifest_tag, :binary
    field :sealed_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end

  def create_changeset(manifest, attrs) do
    manifest
    |> cast(attrs, [
      :id,
      :vault_id,
      :classification,
      :status,
      :destination_ref,
      :kdf_version,
      :kdf_salt,
      :kdf_parameters,
      :recovery_wrapper,
      :custody_ref
    ])
    |> validate_required([
      :id,
      :vault_id,
      :classification,
      :status,
      :destination_ref,
      :kdf_version,
      :kdf_salt,
      :kdf_parameters,
      :recovery_wrapper
    ])
    |> validate_number(:kdf_version, greater_than: 0)
    |> validate_change(:kdf_parameters, &string_keyed_json/2)
    |> foreign_key_constraint(:vault_id, name: :backup_manifests_vault_id_fkey)
    |> unique_constraint([:id, :vault_id], name: :backup_manifests_id_vault_id_key)
    |> apply_constraints()
  end

  def progress_changeset(manifest, attrs) do
    manifest
    |> cast(attrs, [:status, :snapshot_id, :outbox_high_water])
    |> validate_required([:status])
    |> validate_number(:outbox_high_water, greater_than_or_equal_to: 0)
    |> apply_constraints()
  end

  def seal_changeset(manifest, attrs) do
    manifest
    |> cast(attrs, [
      :snapshot_id,
      :outbox_high_water,
      :manifest_hash,
      :manifest_tag,
      :sealed_at
    ])
    |> put_change(:status, :sealed)
    |> validate_required([
      :status,
      :snapshot_id,
      :outbox_high_water,
      :manifest_hash,
      :manifest_tag,
      :sealed_at
    ])
    |> validate_number(:outbox_high_water, greater_than_or_equal_to: 0)
    |> apply_constraints()
  end

  defp apply_constraints(changeset) do
    changeset
    |> check_constraint(:classification, name: :backup_manifests_classification_check)
    |> check_constraint(:status, name: :backup_manifests_status_check)
    |> check_constraint(:kdf_version, name: :backup_manifests_kdf_version_check)
    |> check_constraint(:outbox_high_water,
      name: :backup_manifests_outbox_high_water_check
    )
    |> check_constraint(:manifest_hash, name: :backup_manifests_hash_check)
    |> check_constraint(:manifest_tag, name: :backup_manifests_tag_check)
  end

  defp string_keyed_json(field, value) do
    if json_value?(value), do: [], else: [{field, "must use string keys and JSON values"}]
  end

  defp json_value?(value) when is_map(value) do
    Enum.all?(value, fn {key, nested} -> is_binary(key) and json_value?(nested) end)
  end

  defp json_value?(value) when is_list(value), do: Enum.all?(value, &json_value?/1)
  defp json_value?(value) when is_binary(value) or is_number(value), do: true
  defp json_value?(value) when is_boolean(value) or is_nil(value), do: true
  defp json_value?(_value), do: false
end
