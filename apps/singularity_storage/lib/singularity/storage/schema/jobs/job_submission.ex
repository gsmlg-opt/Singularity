defmodule Singularity.Storage.Schema.Jobs.JobSubmission do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @schema_prefix "jobs"

  schema "job_submissions" do
    field :vault_id, Ecto.UUID
    field :outbox_event_id, Ecto.UUID
    field :classification, Ecto.Enum, values: [:private, :sensitive, :restricted]
    field :idempotency_key, :string
    field :job_type, :string
    field :runner_job_id, :string
    field :wake_requested_generation, :integer, default: 0
    field :wake_consumed_generation, :integer, default: 0
    timestamps(type: :utc_datetime_usec)
  end

  def reserve_changeset(submission, attrs) do
    submission
    |> cast(attrs, [
      :id,
      :vault_id,
      :outbox_event_id,
      :classification,
      :idempotency_key,
      :job_type
    ])
    |> validate_required([
      :id,
      :vault_id,
      :outbox_event_id,
      :classification,
      :idempotency_key,
      :job_type
    ])
    |> foreign_key_constraint(:vault_id, name: :job_submissions_vault_id_fkey)
    |> foreign_key_constraint(:outbox_event_id,
      name: :job_submissions_outbox_vault_fkey
    )
    |> unique_constraint(:outbox_event_id, name: :job_submissions_outbox_event_id_key)
    |> unique_constraint([:vault_id, :idempotency_key],
      name: :job_submissions_vault_id_idempotency_key_key
    )
    |> unique_constraint([:id, :vault_id], name: :job_submissions_id_vault_id_key)
    |> check_constraint(:classification, name: :job_submissions_classification_check)
  end

  def record_runner_changeset(submission, attrs) do
    submission
    |> cast(attrs, [:runner_job_id])
    |> validate_required([:runner_job_id])
  end

  def wake_generation_changeset(submission, attrs) do
    submission
    |> cast(attrs, [:wake_requested_generation, :wake_consumed_generation])
    |> validate_number(:wake_requested_generation, greater_than_or_equal_to: 0)
    |> validate_number(:wake_consumed_generation, greater_than_or_equal_to: 0)
    |> check_constraint(:wake_consumed_generation,
      name: :job_submissions_wake_generations_check
    )
  end
end
