defmodule Singularity.Storage.Schema.Content.ResourceVersion do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @schema_prefix "content"

  schema "resource_versions" do
    field :resource_id, Ecto.UUID
    field :vault_id, Ecto.UUID
    field :classification, Ecto.Enum, values: [:private, :sensitive, :restricted]
    field :revision, :integer
    timestamps(type: :utc_datetime_usec)
  end

  def create_changeset(resource_version, attrs) do
    resource_version
    |> cast(attrs, [:id, :resource_id, :vault_id, :classification, :revision])
    |> validate_required([:id, :resource_id, :vault_id, :classification, :revision])
    |> validate_number(:revision, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:resource_id, name: :resource_versions_resource_vault_fkey)
    |> unique_constraint([:id, :vault_id], name: :resource_versions_id_vault_id_key)
    |> unique_constraint([:resource_id, :vault_id, :revision],
      name: :resource_versions_resource_id_vault_id_revision_key
    )
    |> check_constraint(:classification, name: :resource_versions_classification_check)
    |> check_constraint(:revision, name: :resource_versions_revision_check)
  end
end
