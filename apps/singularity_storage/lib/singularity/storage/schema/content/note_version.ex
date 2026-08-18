defmodule Singularity.Storage.Schema.Content.NoteVersion do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:resource_version_id, Ecto.UUID, autogenerate: false}
  @schema_prefix "content"
  @fields [
    :resource_version_id,
    :resource_id,
    :vault_id,
    :classification,
    :title,
    :markdown,
    :created_by_principal_id,
    :parent_version_id,
    :merge_parent_version_id,
    :inserted_at
  ]

  schema "note_versions" do
    field :resource_id, Ecto.UUID
    field :vault_id, Ecto.UUID
    field :classification, Ecto.Enum, values: [:private]
    field :title, :string
    field :markdown, :string
    field :created_by_principal_id, Ecto.UUID
    field :parent_version_id, Ecto.UUID
    field :merge_parent_version_id, Ecto.UUID
    field :inserted_at, :utc_datetime_usec
  end

  def create_changeset(note_version, attrs) do
    note_version
    |> cast(attrs, @fields)
    |> validate_required(@fields -- [:parent_version_id, :merge_parent_version_id])
    |> validate_inclusion(:classification, [:private])
    |> validate_length(:title, max: 255, count: :bytes)
    |> validate_length(:markdown, max: 1_048_576, count: :bytes)
    |> unique_constraint(:resource_version_id, name: :note_versions_pkey)
    |> unique_constraint([:resource_version_id, :resource_id, :vault_id, :classification],
      name: :note_versions_identity_aggregate_key
    )
    |> unique_constraint([:resource_version_id, :resource_id, :vault_id],
      name: :note_versions_receipt_identity_key
    )
    |> foreign_key_constraint(:resource_version_id,
      name: :note_versions_resource_version_fkey
    )
    |> foreign_key_constraint(:parent_version_id, name: :note_versions_parent_fkey)
    |> foreign_key_constraint(:merge_parent_version_id,
      name: :note_versions_merge_parent_fkey
    )
    |> foreign_key_constraint(:created_by_principal_id,
      name: :note_versions_created_by_principal_fkey
    )
    |> check_constraint(:classification, name: :note_versions_private_check)
    |> check_constraint(:resource_id, name: :note_versions_resource_kind_check)
    |> check_constraint(:parent_version_id, name: :note_versions_initial_parent_check)
    |> check_constraint(:title, name: :note_versions_title_check)
    |> check_constraint(:markdown, name: :note_versions_markdown_check)
    |> check_constraint(:parent_version_id, name: :note_versions_parent_shape_check)
    |> check_constraint(:merge_parent_version_id,
      name: :note_versions_merge_parents_distinct_check
    )
  end
end
