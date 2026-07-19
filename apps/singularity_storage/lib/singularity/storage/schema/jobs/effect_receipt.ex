defmodule Singularity.Storage.Schema.Jobs.EffectReceipt do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @schema_prefix "jobs"

  schema "effect_receipts" do
    field :vault_id, Ecto.UUID
    field :submission_id, Ecto.UUID
    field :classification, Ecto.Enum, values: [:private, :sensitive, :restricted]
    field :effect_key, :string
    field :result, Ecto.Enum, values: [:applied, :stale, :failed]
    field :entity_revision, :integer
    timestamps(updated_at: false, type: :utc_datetime_usec)
  end

  def create_changeset(receipt, attrs) do
    receipt
    |> cast(attrs, [
      :id,
      :vault_id,
      :submission_id,
      :classification,
      :effect_key,
      :result,
      :entity_revision
    ])
    |> validate_required([
      :id,
      :vault_id,
      :submission_id,
      :classification,
      :effect_key,
      :result,
      :entity_revision
    ])
    |> validate_number(:entity_revision, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:submission_id,
      name: :effect_receipts_submission_vault_fkey
    )
    |> unique_constraint([:vault_id, :effect_key],
      name: :effect_receipts_vault_id_effect_key_key
    )
    |> check_constraint(:classification, name: :effect_receipts_classification_check)
    |> check_constraint(:result, name: :effect_receipts_result_check)
    |> check_constraint(:entity_revision, name: :effect_receipts_entity_revision_check)
  end
end
