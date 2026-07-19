defmodule Singularity.Storage.Schema.Content.AssetStage do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @schema_prefix "content"

  schema "asset_stages" do
    field :upload_grant_id, Ecto.UUID
    field :asset_id, Ecto.UUID
    field :vault_id, Ecto.UUID
    field :key_domain_id, Ecto.UUID
    field :candidate_object_id, Ecto.UUID
    field :domain_key_version_id, Ecto.UUID
    field :classification, Ecto.Enum, values: [:private, :sensitive, :restricted]
    field :storage_ref, :string
    field :state, Ecto.Enum, values: [:open, :sealed, :finalized, :abandoned]
    field :state_revision, :integer, default: 0
    field :format_version, :integer
    field :plaintext_byte_size, :integer
    field :ciphertext_byte_size, :integer
    field :lookup_digest, :binary
    field :ciphertext_hash, :binary
    field :wrapper_algorithm, :string
    field :key_generation, :integer
    field :dek_wrapper, :binary
    field :sealed_at, :utc_datetime_usec
    field :abandoned_at, :utc_datetime_usec
    field :failure_code, :string
    timestamps(type: :utc_datetime_usec)
  end

  def open_changeset(stage, attrs) do
    stage
    |> cast(attrs, [
      :id,
      :upload_grant_id,
      :asset_id,
      :vault_id,
      :key_domain_id,
      :candidate_object_id,
      :domain_key_version_id,
      :classification,
      :storage_ref,
      :wrapper_algorithm,
      :key_generation,
      :dek_wrapper,
      :state_revision
    ])
    |> put_change(:state, :open)
    |> validate_required([
      :id,
      :upload_grant_id,
      :asset_id,
      :vault_id,
      :key_domain_id,
      :candidate_object_id,
      :domain_key_version_id,
      :classification,
      :storage_ref,
      :state,
      :wrapper_algorithm,
      :key_generation,
      :dek_wrapper,
      :state_revision
    ])
    |> validate_number(:state_revision, greater_than_or_equal_to: 0)
    |> validate_number(:key_generation, greater_than: 0)
    |> apply_constraints()
  end

  def seal_changeset(stage, attrs) do
    stage
    |> cast(attrs, [
      :format_version,
      :sealed_at,
      :plaintext_byte_size,
      :ciphertext_byte_size,
      :lookup_digest,
      :ciphertext_hash
    ])
    |> put_change(:state, :sealed)
    |> validate_required([
      :state,
      :format_version,
      :sealed_at,
      :plaintext_byte_size,
      :ciphertext_byte_size,
      :lookup_digest,
      :ciphertext_hash
    ])
    |> validate_number(:format_version, greater_than: 0)
    |> validate_number(:plaintext_byte_size, greater_than_or_equal_to: 0)
    |> validate_number(:ciphertext_byte_size, greater_than_or_equal_to: 0)
    |> validate_digest_size(:lookup_digest)
    |> validate_digest_size(:ciphertext_hash)
    |> optimistic_lock(:state_revision)
    |> apply_constraints()
  end

  def finalize_changeset(stage) do
    stage
    |> change(state: :finalized)
    |> optimistic_lock(:state_revision)
    |> apply_constraints()
  end

  def abandon_changeset(stage, attrs) do
    stage
    |> cast(attrs, [:abandoned_at, :failure_code])
    |> put_change(:state, :abandoned)
    |> validate_required([:state, :abandoned_at, :failure_code])
    |> optimistic_lock(:state_revision)
    |> apply_constraints()
  end

  defp apply_constraints(changeset) do
    changeset
    |> foreign_key_constraint(:asset_id, name: :asset_stages_asset_vault_fkey)
    |> foreign_key_constraint(:upload_grant_id,
      name: :asset_stages_upload_grant_vault_fkey
    )
    |> foreign_key_constraint(:key_domain_id, name: :asset_stages_key_domain_vault_fkey)
    |> foreign_key_constraint(:domain_key_version_id,
      name: :asset_stages_domain_version_vault_fkey
    )
    |> unique_constraint([:id, :vault_id], name: :asset_stages_id_vault_id_key)
    |> unique_constraint(:upload_grant_id, name: :asset_stages_upload_grant_id_key)
    |> unique_constraint([:candidate_object_id, :vault_id],
      name: :asset_stages_candidate_object_vault_key
    )
    |> check_constraint(:classification, name: :asset_stages_classification_check)
    |> check_constraint(:state, name: :asset_stages_state_check)
    |> check_constraint(:format_version, name: :asset_stages_format_version_check)
    |> check_constraint(:plaintext_byte_size, name: :asset_stages_sizes_check)
    |> check_constraint(:lookup_digest, name: :asset_stages_lookup_digest_check)
    |> check_constraint(:ciphertext_hash, name: :asset_stages_ciphertext_hash_check)
    |> check_constraint(:key_generation, name: :asset_stages_key_generation_check)
    |> check_constraint(:state_revision, name: :asset_stages_state_revision_check)
    |> check_constraint(:state, name: :asset_stages_abandonment_shape_check)
    |> check_constraint(:state, name: :asset_stages_crypto_state_check)
    |> check_constraint(:wrapper_algorithm, name: :asset_stages_wrapper_shape_check)
  end

  defp validate_digest_size(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      if is_binary(value) and byte_size(value) == 32,
        do: [],
        else: [{field, "must be exactly 32 bytes"}]
    end)
  end
end
