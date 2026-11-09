defmodule Singularity.Storage.Schema.Content.NoteMutationReceipt do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false
  @schema_prefix "content"
  @claim_fields [
    :vault_id,
    :principal_id,
    :mutation_id,
    :operation,
    :request_fingerprint,
    :resource_id
  ]

  schema "note_mutation_receipts" do
    field :vault_id, Ecto.UUID, primary_key: true
    field :principal_id, Ecto.UUID, primary_key: true
    field :mutation_id, Ecto.UUID, primary_key: true
    field :operation, Ecto.Enum, values: [:create, :save, :merge, :tombstone, :restore]
    field :request_fingerprint, :binary
    field :state, Ecto.Enum, values: [:pending, :completed]
    field :outcome, Ecto.Enum, values: [:saved, :conflict, :tombstoned, :restored]
    field :resource_id, Ecto.UUID
    field :version_id, Ecto.UUID
    field :conflict_id, Ecto.UUID
    timestamps(updated_at: false, type: :utc_datetime_usec)
  end

  def create_changeset(receipt, attrs) do
    receipt
    |> cast(attrs, @claim_fields)
    |> put_change(:state, :pending)
    |> validate_required(@claim_fields ++ [:state])
    |> validate_length(:request_fingerprint, is: 32, count: :bytes)
    |> map_constraints()
  end

  def complete_changeset(receipt, attrs) do
    receipt
    |> cast(attrs, [:outcome, :version_id, :conflict_id])
    |> put_change(:state, :completed)
    |> validate_required([:state, :outcome, :resource_id])
    |> validate_inclusion(:state, [:completed])
    |> map_constraints()
  end

  defp map_constraints(changeset) do
    changeset
    |> unique_constraint([:vault_id, :principal_id, :mutation_id],
      name: :note_mutation_receipts_pkey
    )
    |> foreign_key_constraint(:principal_id,
      name: :note_mutation_receipts_membership_fkey
    )
    |> foreign_key_constraint(:resource_id, name: :note_mutation_receipts_resource_fkey)
    |> foreign_key_constraint(:version_id, name: :note_mutation_receipts_version_fkey)
    |> foreign_key_constraint(:conflict_id, name: :note_mutation_receipts_conflict_fkey)
    |> check_constraint(:operation, name: :note_mutation_receipts_operation_check)
    |> check_constraint(:request_fingerprint,
      name: :note_mutation_receipts_fingerprint_check
    )
    |> check_constraint(:state, name: :note_mutation_receipts_state_check)
    |> check_constraint(:outcome, name: :note_mutation_receipts_result_shape_check)
    |> check_constraint(:resource_id, name: :note_mutation_receipts_private_note_check)
  end
end
