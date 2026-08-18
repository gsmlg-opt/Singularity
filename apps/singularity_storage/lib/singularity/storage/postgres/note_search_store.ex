defmodule Singularity.Storage.Postgres.NoteSearchStore do
  @moduledoc false

  @behaviour Singularity.Core.NoteSearchStore

  import Ecto.Query

  alias Singularity.Core.Error
  alias Singularity.Storage.Postgres.UUID
  alias Singularity.Storage.Schema.Content.NoteSearchDocument

  @upsert_fields [
    :resource_id,
    :resource_version_id,
    :vault_id,
    :classification,
    :title,
    :markdown,
    :head_inserted_at
  ]
  @replace_fields [
    :resource_version_id,
    :vault_id,
    :classification,
    :title,
    :markdown,
    :head_inserted_at,
    :updated_at
  ]

  @impl true
  def upsert(repo, attrs) when is_map(attrs) do
    with :ok <- exact_fields(attrs, @upsert_fields),
         :ok <- UUID.validate([attrs.resource_id, attrs.resource_version_id, attrs.vault_id]),
         true <- attrs.classification == :private do
      changeset = NoteSearchDocument.upsert_changeset(%NoteSearchDocument{}, attrs)

      case repo.insert(changeset,
             on_conflict: {:replace, @replace_fields},
             conflict_target: [:resource_id]
           ) do
        {:ok, _document} -> :ok
        {:error, %Ecto.Changeset{}} -> {:error, Error.new(:invalid)}
      end
    else
      false -> invalid()
      {:error, %Error{}} = error -> error
    end
  rescue
    _error in [Ecto.Query.CastError, Ecto.CastError] ->
      invalid()

    error in [Ecto.ConstraintError, DBConnection.ConnectionError, Postgrex.Error] ->
      {:error, database_error(error)}
  end

  def upsert(_repo, _attrs), do: invalid()

  @impl true
  def delete(repo, %{resource_id: resource_id, vault_id: vault_id} = selector)
      when map_size(selector) == 2 do
    with :ok <- UUID.validate([resource_id, vault_id]) do
      case repo.delete_all(
             from(document in NoteSearchDocument,
               where: document.resource_id == ^resource_id and document.vault_id == ^vault_id
             )
           ) do
        {count, _rows} when count in [0, 1] -> :ok
        {_count, _rows} -> {:error, Error.new(:integrity_failure)}
      end
    end
  rescue
    _error in [Ecto.Query.CastError, Ecto.CastError] ->
      invalid()

    error in [Ecto.ConstraintError, DBConnection.ConnectionError, Postgrex.Error] ->
      {:error, database_error(error)}
  end

  def delete(_repo, _selector), do: invalid()

  @impl true
  def search(_repo, _query), do: invalid()

  defp exact_fields(attrs, fields) do
    if MapSet.new(Map.keys(attrs)) == MapSet.new(fields), do: :ok, else: invalid()
  end

  defp database_error(%Ecto.ConstraintError{}), do: Error.new(:invalid)

  defp database_error(%Postgrex.Error{postgres: %{code: code}})
       when code in [
              :integrity_constraint_violation,
              :restrict_violation,
              :not_null_violation,
              :foreign_key_violation,
              :unique_violation,
              :check_violation,
              :exclusion_violation
            ],
       do: Error.new(:invalid)

  defp database_error(_error), do: Error.new(:storage_unavailable, retryable?: true)
  defp invalid, do: {:error, Error.new(:invalid)}
end
