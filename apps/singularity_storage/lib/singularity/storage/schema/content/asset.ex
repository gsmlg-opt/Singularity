defmodule Singularity.Storage.Schema.Content.Asset do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @schema_prefix "content"
  @states [
    :staging,
    :uploaded,
    :verified,
    :available,
    :processing,
    :ready,
    :pending_delete,
    :deleted
  ]

  schema "assets" do
    field :vault_id, Ecto.UUID
    field :resource_version_id, Ecto.UUID
    field :asset_object_id, Ecto.UUID
    field :classification, Ecto.Enum, values: [:private, :sensitive, :restricted]
    field :state, Ecto.Enum, values: @states
    field :state_revision, :integer, default: 0
    field :failure_code, :string
    field :retryable?, :boolean, source: :retryable
    field :failed_operation, :string
    field :attempt, :integer, default: 0
    timestamps(type: :utc_datetime_usec)
  end

  def create_changeset(asset, attrs) do
    asset
    |> cast(attrs, [
      :id,
      :vault_id,
      :resource_version_id,
      :asset_object_id,
      :classification,
      :state,
      :state_revision,
      :attempt
    ])
    |> validate_required([
      :id,
      :vault_id,
      :resource_version_id,
      :classification,
      :state,
      :state_revision,
      :attempt
    ])
    |> validate_number(:state_revision, greater_than_or_equal_to: 0)
    |> validate_number(:attempt, greater_than_or_equal_to: 0)
    |> apply_constraints()
  end

  def transition_changeset(asset, attrs) do
    asset
    |> cast(attrs, [:state, :state_revision])
    |> validate_required([:state, :state_revision])
    |> validate_number(:state_revision, greater_than_or_equal_to: 0)
    |> check_constraint(:state, name: :assets_state_check)
    |> check_constraint(:state_revision, name: :assets_state_revision_check)
  end

  def attach_object_changeset(asset, attrs) do
    asset
    |> cast(attrs, [:asset_object_id])
    |> validate_required([:asset_object_id])
    |> foreign_key_constraint(:asset_object_id, name: :assets_object_vault_fkey)
  end

  def record_failure_changeset(asset, attrs) do
    asset
    |> cast(attrs, [:failure_code, :retryable?, :failed_operation, :attempt])
    |> validate_required([:failure_code, :retryable?, :failed_operation, :attempt])
    |> validate_number(:attempt, greater_than_or_equal_to: 0)
    |> check_constraint(:attempt, name: :assets_attempt_check)
    |> check_constraint(:failure_code, name: :assets_failure_shape_check)
  end

  def retry_changeset(asset, attrs) do
    asset
    |> cast(attrs, [:failure_code, :retryable?, :failed_operation, :attempt])
    |> validate_required([:attempt])
    |> validate_number(:attempt, greater_than_or_equal_to: 0)
    |> check_constraint(:attempt, name: :assets_attempt_check)
    |> check_constraint(:failure_code, name: :assets_failure_shape_check)
  end

  defp apply_constraints(changeset) do
    changeset
    |> foreign_key_constraint(:resource_version_id,
      name: :assets_resource_version_vault_fkey
    )
    |> foreign_key_constraint(:asset_object_id, name: :assets_object_vault_fkey)
    |> unique_constraint([:id, :vault_id], name: :assets_id_vault_id_key)
    |> check_constraint(:classification, name: :assets_classification_check)
    |> check_constraint(:state, name: :assets_state_check)
    |> check_constraint(:state_revision, name: :assets_state_revision_check)
    |> check_constraint(:attempt, name: :assets_attempt_check)
    |> check_constraint(:failure_code, name: :assets_failure_shape_check)
  end
end
