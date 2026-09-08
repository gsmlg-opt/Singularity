defmodule Singularity.Storage.Schema.Content.ResourceTag do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @schema_prefix "content"
  @fields ~w(resource_id tag_id vault_id classification inserted_at)a

  schema "resource_tags" do
    field :resource_id, Ecto.UUID, primary_key: true
    field :tag_id, Ecto.UUID, primary_key: true
    field :vault_id, Ecto.UUID, primary_key: true
    field :classification, Ecto.Enum, values: [:private]
    field :inserted_at, :utc_datetime_usec
  end

  def create_changeset(record, attrs) do
    record
    |> cast(attrs, @fields, empty_values: [])
    |> validate_required(@fields)
    |> validate_inclusion(:classification, [:private])
    |> unique_constraint([:resource_id, :tag_id, :vault_id], name: :resource_tags_pkey)
    |> foreign_key_constraint(:resource_id, name: :resource_tags_resource_fkey)
    |> foreign_key_constraint(:tag_id, name: :resource_tags_tag_fkey)
    |> check_constraint(:classification, name: :resource_tags_private_check)
    |> check_constraint(:resource_id, name: :resource_tags_resource_check)
  end
end
