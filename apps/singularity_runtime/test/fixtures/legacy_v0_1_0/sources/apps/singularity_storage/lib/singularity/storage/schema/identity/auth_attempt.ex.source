defmodule Singularity.Storage.Schema.Identity.AuthAttempt do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @schema_prefix "identity"

  schema "auth_attempts" do
    field :login_fingerprint, :binary
    field :source_fingerprint, :binary
    field :result, Ecto.Enum, values: [:started, :failed, :succeeded]
    field :correlation_id, Ecto.UUID
    field :attempted_at, :utc_datetime_usec
  end

  def create_changeset(auth_attempt, attrs) do
    auth_attempt
    |> cast(attrs, [
      :id,
      :login_fingerprint,
      :source_fingerprint,
      :result,
      :correlation_id,
      :attempted_at
    ])
    |> validate_required([
      :id,
      :login_fingerprint,
      :source_fingerprint,
      :result,
      :correlation_id,
      :attempted_at
    ])
    |> validate_change(:login_fingerprint, &validate_fingerprint/2)
    |> validate_change(:source_fingerprint, &validate_fingerprint/2)
    |> check_constraint(:login_fingerprint,
      name: :auth_attempts_login_fingerprint_check
    )
    |> check_constraint(:source_fingerprint,
      name: :auth_attempts_source_fingerprint_check
    )
    |> check_constraint(:result, name: :auth_attempts_result_check)
  end

  defp validate_fingerprint(field, fingerprint) do
    if is_binary(fingerprint) and byte_size(fingerprint) == 32,
      do: [],
      else: [{field, "must be exactly 32 bytes"}]
  end
end
