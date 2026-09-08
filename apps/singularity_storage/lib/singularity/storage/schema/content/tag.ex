defmodule Singularity.Storage.Schema.Content.Tag do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @schema_prefix "content"
  @fields ~w(id vault_id classification display_value normalized_key created_by_principal_id inserted_at)a

  schema "tags" do
    field :id, Ecto.UUID, primary_key: true
    field :vault_id, Ecto.UUID
    field :classification, Ecto.Enum, values: [:private]
    field :display_value, :string
    field :normalized_key, :string
    field :created_by_principal_id, Ecto.UUID
    field :inserted_at, :utc_datetime_usec
  end

  def create_changeset(record, attrs) do
    record
    |> cast(attrs, @fields, empty_values: [])
    |> validate_required(@fields)
    |> validate_inclusion(:classification, [:private])
    |> validate_length(:display_value, min: 1, max: 255, count: :bytes)
    |> validate_length(:normalized_key, min: 1, max: 1024, count: :bytes)
    |> validate_format(:display_value, ~r/\A[^\p{Cc}]+\z/u)
    |> validate_format(:normalized_key, ~r/\A[^\p{Cc}]+\z/u)
    |> unique_constraint([:id], name: :tags_pkey)
    |> unique_constraint([:id, :vault_id], name: :tags_id_vault_key)
    |> unique_constraint([:vault_id, :normalized_key], name: :tags_owner_normalized_key)
    |> foreign_key_constraint(:created_by_principal_id, name: :tags_created_by_principal_fkey)
    |> foreign_key_constraint(:vault_id, name: :tags_vault_fkey)
    |> check_constraint(:classification, name: :tags_private_check)
    |> check_constraint(:display_value, name: :tags_display_value_check)
    |> check_constraint(:normalized_key, name: :tags_normalized_key_check)
  end
end
