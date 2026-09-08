defmodule Singularity.Storage.Schema.Content.DocumentFragment do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @schema_prefix "content"
  @fields ~w(id resource_id resource_version_id vault_id classification ordinal text digest locator inserted_at)a

  schema "document_fragments" do
    field :resource_id, Ecto.UUID
    field :resource_version_id, Ecto.UUID
    field :vault_id, Ecto.UUID
    field :classification, Ecto.Enum, values: [:private]
    field :ordinal, :integer
    field :text, :string
    field :digest, :binary
    field :locator, :map
    field :inserted_at, :utc_datetime_usec
  end

  def create_changeset(fragment, attrs) do
    fragment
    |> cast(attrs, @fields, empty_values: [])
    |> validate_required(@fields -- [:text])
    |> require_text()
    |> validate_format(:id, ~r/\A[0-9a-f]{64}\z/)
    |> validate_inclusion(:classification, [:private])
    |> validate_number(:ordinal,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 9_223_372_036_854_775_807
    )
    |> validate_length(:text, max: 65_536, count: :bytes)
    |> validate_length(:digest, is: 32, count: :bytes)
    |> unique_constraint(:id, name: :document_fragments_pkey)
    |> unique_constraint([:resource_version_id, :ordinal],
      name: :document_fragments_version_ordinal_key
    )
    |> unique_constraint([:id, :resource_id, :resource_version_id, :vault_id, :classification],
      name: :document_fragments_identity_aggregate_key
    )
    |> foreign_key_constraint(:resource_version_id,
      name: :document_fragments_document_version_fkey
    )
    |> check_constraint(:id, name: :document_fragments_id_check)
    |> check_constraint(:classification, name: :document_fragments_private_check)
    |> check_constraint(:ordinal, name: :document_fragments_ordinal_check)
    |> check_constraint(:text, name: :document_fragments_text_check)
    |> check_constraint(:digest, name: :document_fragments_digest_check)
    |> check_constraint(:locator, name: :document_fragments_locator_check)
    |> check_constraint(:locator, name: :document_fragments_locator_ordinal_check)
    |> check_constraint(:id, name: :document_fragments_identity_check)
    |> check_constraint(:locator, name: :document_extraction_input_check)
    |> check_constraint(:resource_version_id, name: :document_fragments_insert_state_check)
    |> check_constraint(:resource_version_id, name: :document_versions_completion_check)
  end

  defp require_text(changeset) do
    if is_nil(get_field(changeset, :text)),
      do: add_error(changeset, :text, "can't be blank"),
      else: changeset
  end
end
