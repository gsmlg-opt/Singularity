defmodule Singularity.Storage.Schema.Content.AssetObject do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @schema_prefix "content"

  schema "asset_objects" do
    field :vault_id, Ecto.UUID
    field :key_domain_id, Ecto.UUID
    field :classification, Ecto.Enum, values: [:private, :sensitive, :restricted]
    field :lookup_digest, :binary
    field :ciphertext_hash, :binary
    field :plaintext_byte_size, :integer
    field :ciphertext_byte_size, :integer
    field :storage_ref, :string
    field :format_version, :integer
    field :lifecycle, Ecto.Enum, values: [:staged, :available, :pending_delete, :deleted]
    field :retained_until, :utc_datetime_usec
    field :deleted_at, :utc_datetime_usec
    field :deletion_evidence, :map
    timestamps(type: :utc_datetime_usec)
  end

  def create_changeset(object, attrs) do
    object
    |> cast(attrs, [
      :id,
      :vault_id,
      :key_domain_id,
      :classification,
      :lookup_digest,
      :ciphertext_hash,
      :plaintext_byte_size,
      :ciphertext_byte_size,
      :storage_ref,
      :format_version,
      :lifecycle,
      :retained_until
    ])
    |> validate_required([
      :id,
      :vault_id,
      :key_domain_id,
      :classification,
      :lookup_digest,
      :ciphertext_hash,
      :plaintext_byte_size,
      :ciphertext_byte_size,
      :storage_ref,
      :format_version,
      :lifecycle
    ])
    |> validate_number(:plaintext_byte_size, greater_than_or_equal_to: 0)
    |> validate_number(:ciphertext_byte_size, greater_than_or_equal_to: 0)
    |> validate_number(:format_version, greater_than: 0)
    |> apply_constraints()
  end

  def lifecycle_changeset(object, attrs) do
    object
    |> cast(attrs, [:lifecycle, :retained_until, :deleted_at, :deletion_evidence])
    |> validate_required([:lifecycle])
    |> validate_change(:deletion_evidence, &string_keyed_json/2)
    |> check_constraint(:lifecycle, name: :asset_objects_lifecycle_check)
  end

  defp apply_constraints(changeset) do
    changeset
    |> foreign_key_constraint(:key_domain_id, name: :asset_objects_key_domain_vault_fkey)
    |> unique_constraint([:id, :vault_id], name: :asset_objects_id_vault_id_key)
    |> unique_constraint([:id, :vault_id, :key_domain_id],
      name: :asset_objects_id_vault_id_key_domain_id_key
    )
    |> unique_constraint([:vault_id, :key_domain_id, :lookup_digest],
      name: :asset_objects_vault_id_key_domain_id_lookup_digest_key
    )
    |> check_constraint(:classification, name: :asset_objects_classification_check)
    |> check_constraint(:lookup_digest, name: :asset_objects_lookup_digest_check)
    |> check_constraint(:ciphertext_hash, name: :asset_objects_ciphertext_hash_check)
    |> check_constraint(:plaintext_byte_size, name: :asset_objects_sizes_check)
    |> check_constraint(:format_version, name: :asset_objects_format_version_check)
    |> check_constraint(:lifecycle, name: :asset_objects_lifecycle_check)
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
