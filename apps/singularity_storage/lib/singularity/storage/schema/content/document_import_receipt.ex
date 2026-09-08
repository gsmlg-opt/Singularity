defmodule Singularity.Storage.Schema.Content.DocumentImportReceipt do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false
  @schema_prefix "content"
  @claim_fields [:vault_id, :principal_id, :mutation_id, :request_fingerprint, :inserted_at]

  schema "document_import_receipts" do
    field :vault_id, Ecto.UUID, primary_key: true
    field :principal_id, Ecto.UUID, primary_key: true
    field :mutation_id, Ecto.UUID, primary_key: true
    field :request_fingerprint, :binary
    field :state, Ecto.Enum, values: [:pending, :completed]
    field :resource_id, Ecto.UUID
    field :version_id, Ecto.UUID
    field :inserted_at, :utc_datetime_usec
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
    |> cast(attrs, [:resource_id, :version_id])
    |> put_change(:state, :completed)
    |> validate_required([:resource_id, :version_id, :state])
    |> map_constraints()
  end

  defp map_constraints(changeset) do
    changeset
    |> unique_constraint([:vault_id, :principal_id, :mutation_id],
      name: :document_import_receipts_pkey
    )
    |> foreign_key_constraint(:principal_id, name: :document_import_receipts_membership_fkey)
    |> foreign_key_constraint(:version_id, name: :document_import_receipts_version_fkey)
    |> check_constraint(:request_fingerprint, name: :document_import_receipts_fingerprint_check)
    |> check_constraint(:state, name: :document_import_receipts_state_check)
    |> check_constraint(:state, name: :document_import_receipts_result_shape_check)
    |> check_constraint(:state, name: :document_import_receipts_completed_check)
  end
end
