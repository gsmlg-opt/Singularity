defmodule Singularity.Storage.Schema.Jobs.JobProgress do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @schema_prefix "jobs"
  @states [
    :pending,
    :running,
    :waiting_for_unlock,
    :waiting_for_backup_key,
    :completed,
    :failed
  ]

  schema "job_progress" do
    field :vault_id, Ecto.UUID
    field :submission_id, Ecto.UUID
    field :classification, Ecto.Enum, values: [:private, :sensitive, :restricted]
    field :state, Ecto.Enum, values: @states
    field :processing_revision, :integer, default: 0
    field :checkpoint_version, :integer
    field :checkpoint, :map, default: %{}
    timestamps(type: :utc_datetime_usec)
  end

  def create_changeset(progress, attrs) do
    progress
    |> cast(attrs, [
      :id,
      :vault_id,
      :submission_id,
      :classification,
      :state,
      :processing_revision,
      :checkpoint_version,
      :checkpoint
    ])
    |> validate_required([
      :id,
      :vault_id,
      :submission_id,
      :classification,
      :state,
      :processing_revision,
      :checkpoint_version,
      :checkpoint
    ])
    |> validate_number(:processing_revision, greater_than_or_equal_to: 0)
    |> validate_number(:checkpoint_version, greater_than: 0)
    |> validate_change(:checkpoint, &string_keyed_json/2)
    |> apply_constraints()
  end

  def checkpoint_changeset(progress, attrs) do
    progress
    |> cast(attrs, [:state, :processing_revision, :checkpoint_version, :checkpoint])
    |> validate_required([
      :state,
      :processing_revision,
      :checkpoint_version,
      :checkpoint
    ])
    |> validate_number(:processing_revision, greater_than_or_equal_to: 0)
    |> validate_number(:checkpoint_version, greater_than: 0)
    |> validate_change(:checkpoint, &string_keyed_json/2)
    |> apply_constraints()
  end

  defp apply_constraints(changeset) do
    changeset
    |> foreign_key_constraint(:submission_id,
      name: :job_progress_submission_vault_fkey
    )
    |> unique_constraint(:submission_id, name: :job_progress_submission_id_key)
    |> unique_constraint([:id, :vault_id], name: :job_progress_id_vault_id_key)
    |> check_constraint(:classification, name: :job_progress_classification_check)
    |> check_constraint(:state, name: :job_progress_state_check)
    |> check_constraint(:processing_revision, name: :job_progress_revision_check)
    |> check_constraint(:checkpoint_version,
      name: :job_progress_checkpoint_version_check
    )
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
