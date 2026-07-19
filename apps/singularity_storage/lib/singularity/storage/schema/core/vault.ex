defmodule Singularity.Storage.Schema.Core.Vault do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @schema_prefix "core"

  schema "vaults" do
    field :kind, Ecto.Enum, values: [:personal, :system], default: :personal
    field :authorization_epoch, :integer, default: 0
    field :object_cleanup_principal_id, Ecto.UUID
    field :locked, :boolean, default: true
    field :metadata, :map, default: %{}
    timestamps(type: :utc_datetime_usec)
  end

  def create_changeset(vault, attrs) do
    vault
    |> cast(attrs, [:id, :kind, :authorization_epoch, :locked, :metadata])
    |> validate_required([:id, :kind, :authorization_epoch, :locked, :metadata])
    |> validate_number(:authorization_epoch, greater_than_or_equal_to: 0)
    |> validate_change(:metadata, &string_keyed_json/2)
    |> check_constraint(:kind, name: :vaults_kind_check)
    |> check_constraint(:authorization_epoch,
      name: :vaults_authorization_epoch_check
    )
  end

  def security_changeset(vault, attrs) do
    vault
    |> cast(attrs, [:authorization_epoch, :locked])
    |> validate_required([:authorization_epoch, :locked])
    |> validate_number(:authorization_epoch, greater_than_or_equal_to: 0)
    |> check_constraint(:authorization_epoch,
      name: :vaults_authorization_epoch_check
    )
  end

  def cleanup_principal_changeset(vault, attrs) do
    vault
    |> cast(attrs, [:object_cleanup_principal_id])
    |> validate_required([:object_cleanup_principal_id])
    |> foreign_key_constraint(:object_cleanup_principal_id,
      name: :vaults_object_cleanup_membership_fkey
    )
  end

  defp string_keyed_json(field, value) do
    if json_value?(value),
      do: [],
      else: [{field, "must use string keys and JSON values"}]
  end

  defp json_value?(value) when is_map(value) do
    Enum.all?(value, fn {key, nested} ->
      is_binary(key) and json_value?(nested)
    end)
  end

  defp json_value?(value) when is_list(value), do: Enum.all?(value, &json_value?/1)
  defp json_value?(value) when is_binary(value) or is_number(value), do: true
  defp json_value?(value) when is_boolean(value) or is_nil(value), do: true
  defp json_value?(_value), do: false
end
