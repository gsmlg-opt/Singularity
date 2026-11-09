defmodule Singularity.Storage.Schema.Identity.SecuritySetting do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false
  @schema_prefix "identity"

  schema "security_settings" do
    field :singleton, :boolean, primary_key: true, default: true
    field :dummy_verifier, :string
    field :login_window_seconds, :integer
    field :login_max_attempts, :integer
    field :source_window_seconds, :integer
    field :source_max_attempts, :integer
    timestamps(inserted_at: false, type: :utc_datetime_usec)
  end

  def update_limits_changeset(security_setting, attrs) do
    security_setting
    |> cast(attrs, [
      :dummy_verifier,
      :login_window_seconds,
      :login_max_attempts,
      :source_window_seconds,
      :source_max_attempts
    ])
    |> validate_required([
      :dummy_verifier,
      :login_window_seconds,
      :login_max_attempts,
      :source_window_seconds,
      :source_max_attempts
    ])
    |> validate_number(:login_window_seconds, greater_than: 0)
    |> validate_number(:login_max_attempts, greater_than: 0)
    |> validate_number(:source_window_seconds, greater_than: 0)
    |> validate_number(:source_max_attempts, greater_than: 0)
    |> check_constraint(:singleton, name: :security_settings_singleton_check)
    |> check_constraint(:login_window_seconds,
      name: :security_settings_limits_check
    )
  end
end
