defmodule Singularity.Storage.Postgres.NoteProjectionReconciler do
  @moduledoc false

  import Ecto.Query

  alias Singularity.Core.Error
  alias Singularity.Storage.Postgres.NoteSearchStore
  alias Singularity.Storage.Postgres.UUID
  alias Singularity.Storage.Schema.Content.NoteVersion
  alias Singularity.Storage.Schema.Content.Resource
  alias Singularity.Storage.Schema.Content.ResourceVersion

  @spec reconcile(Ecto.Repo.t(), map()) :: :ok | {:error, Error.t()}
  def reconcile(repo, %{vault_id: vault_id, resource_id: resource_id} = selector)
      when map_size(selector) == 2 do
    with :ok <- UUID.validate([vault_id, resource_id]) do
      case load_canonical(repo, vault_id, resource_id) do
        {:ok, %{deleted_at: nil} = canonical} ->
          canonical
          |> Map.delete(:deleted_at)
          |> then(&NoteSearchStore.upsert(repo, &1))

        {:ok, %{deleted_at: %DateTime{}}} ->
          NoteSearchStore.delete(repo, %{vault_id: vault_id, resource_id: resource_id})

        {:error, %Error{}} = error ->
          error
      end
    end
  rescue
    _error in [Ecto.Query.CastError, Ecto.CastError] ->
      {:error, Error.new(:invalid)}

    _error in [DBConnection.ConnectionError, Postgrex.Error] ->
      {:error, Error.new(:storage_unavailable, retryable?: true)}
  end

  def reconcile(_repo, _selector), do: {:error, Error.new(:invalid)}

  defp load_canonical(repo, vault_id, resource_id) do
    resource_query =
      from resource in Resource,
        where:
          resource.id == ^resource_id and
            resource.vault_id == ^vault_id and
            resource.kind == :note,
        select: %{
          resource_id: resource.id,
          resource_version_id: resource.current_version_id,
          vault_id: resource.vault_id,
          classification: resource.classification,
          deleted_at: resource.deleted_at
        },
        lock: "FOR SHARE"

    with %{resource_version_id: head_id} = resource <- repo.one(resource_query),
         %{title: title, markdown: markdown, head_inserted_at: head_inserted_at} <-
           load_head(repo, resource, head_id) do
      {:ok,
       Map.merge(resource, %{
         title: title,
         markdown: markdown,
         head_inserted_at: head_inserted_at
       })}
    else
      nil -> {:error, Error.new(:not_found)}
    end
  end

  defp load_head(repo, resource, head_id) do
    query =
      from version in ResourceVersion,
        join: note in NoteVersion,
        on:
          note.resource_version_id == version.id and
            note.resource_id == version.resource_id and
            note.vault_id == version.vault_id and
            note.classification == version.classification,
        where:
          version.id == ^head_id and
            version.resource_id == ^resource.resource_id and
            version.vault_id == ^resource.vault_id and
            version.classification == ^resource.classification,
        select: %{
          title: note.title,
          markdown: note.markdown,
          head_inserted_at: version.inserted_at
        }

    repo.one(query)
  end
end
