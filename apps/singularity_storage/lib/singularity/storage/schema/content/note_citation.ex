defmodule Singularity.Storage.Schema.Content.NoteCitation do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @schema_prefix "content"
  @fields ~w(note_resource_version_id id note_resource_id vault_id classification source_resource_id source_resource_version_id fragment_id locator ordinal inserted_at)a

  schema "note_citations" do
    field :note_resource_version_id, Ecto.UUID, primary_key: true
    field :id, Ecto.UUID, primary_key: true
    field :note_resource_id, Ecto.UUID
    field :vault_id, Ecto.UUID
    field :classification, Ecto.Enum, values: [:private]
    field :source_resource_id, Ecto.UUID
    field :source_resource_version_id, Ecto.UUID
    field :fragment_id, :string
    field :locator, :map
    field :ordinal, :integer
    field :inserted_at, :utc_datetime_usec
  end

  def create_changeset(record, attrs) do
    record
    |> cast(attrs, @fields, empty_values: [])
    |> validate_required(@fields)
    |> validate_inclusion(:classification, [:private])
    |> validate_number(:ordinal,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 9_223_372_036_854_775_807
    )
    |> validate_format(:fragment_id, ~r/\A[0-9a-f]{64}\z/)
    |> validate_distinct(:note_resource_id, :source_resource_id)
    |> validate_distinct(:note_resource_version_id, :source_resource_version_id)
    |> unique_constraint([:note_resource_version_id, :id], name: :note_citations_pkey)
    |> unique_constraint([:note_resource_version_id, :ordinal],
      name: :note_citations_note_ordinal_key
    )
    |> foreign_key_constraint(:note_resource_version_id, name: :note_citations_note_fkey)
    |> foreign_key_constraint(:fragment_id, name: :note_citations_fragment_fkey)
    |> check_constraint(:classification, name: :note_citations_private_check)
    |> check_constraint(:ordinal, name: :note_citations_ordinal_check)
    |> check_constraint(:source_resource_id, name: :note_citations_self_check)
    |> check_constraint(:locator, name: :note_citations_locator_check)
    |> check_constraint(:source_resource_id, name: :note_citations_source_check)
    |> check_constraint(:note_resource_version_id, name: :note_citations_source_set_check)
    |> check_constraint(:id, name: :note_citations_immutable_check)
  end

  defp validate_distinct(changeset, source, target) do
    if not is_nil(get_field(changeset, source)) and
         get_field(changeset, source) == get_field(changeset, target) do
      add_error(changeset, target, "must differ from source")
    else
      changeset
    end
  end
end
