defmodule Singularity.Storage.Schema.Content.NoteSearchDocument do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:resource_id, Ecto.UUID, autogenerate: false}
  @schema_prefix "content"
  @fields [
    :resource_id,
    :resource_version_id,
    :vault_id,
    :classification,
    :title,
    :markdown,
    :head_inserted_at
  ]

  schema "note_search_documents" do
    field :resource_version_id, Ecto.UUID
    field :vault_id, Ecto.UUID
    field :classification, Ecto.Enum, values: [:private]
    field :title, :string
    field :markdown, :string
    field :head_inserted_at, :utc_datetime_usec
    timestamps(inserted_at: false, type: :utc_datetime_usec)
  end

  def upsert_changeset(document, attrs) do
    document
    |> cast(attrs, @fields)
    |> validate_required(@fields)
    |> validate_inclusion(:classification, [:private])
    |> validate_length(:title, max: 255, count: :bytes)
    |> validate_length(:markdown, max: 1_048_576, count: :bytes)
    |> unique_constraint(:resource_id, name: :note_search_documents_pkey)
    |> foreign_key_constraint(:resource_id,
      name: :note_search_documents_resource_head_fkey
    )
    |> foreign_key_constraint(:resource_version_id,
      name: :note_search_documents_note_version_fkey
    )
    |> check_constraint(:classification, name: :note_search_documents_private_check)
    |> check_constraint(:title, name: :note_search_documents_title_check)
    |> check_constraint(:markdown, name: :note_search_documents_markdown_check)
  end
end
