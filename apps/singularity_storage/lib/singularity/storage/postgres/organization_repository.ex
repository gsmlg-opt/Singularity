defmodule Singularity.Storage.Postgres.OrganizationRepository do
  @moduledoc "Scoped owner-authenticated resource and selected relationship metadata."
  @behaviour Singularity.Domains.Organization.Repository

  import Ecto.Query
  alias Singularity.Core.{Error, Types}
  alias Singularity.Storage.SafeSQL
  alias Singularity.Storage.Postgres.KnowledgeError
  alias Singularity.Storage.Schema.Content.{Relationship, Resource}

  @impl true
  def resources_in_scope(context, ids) do
    with :ok <- validate_ids(ids),
         {:ok, repo} <- in_scope_repo(context) do
      rows =
        repo.all(
          from(r in Resource,
            where:
              r.id in ^ids and r.vault_id == ^context.owner_scope_id and
                r.classification == :private and is_nil(r.deleted_at) and
                r.kind in [:asset, :note, :document] and
                fragment("content.knowledge_resource_is_live(?,?)", r.vault_id, r.id),
            order_by: [asc: r.id],
            select: %{resource_id: r.id, kind: r.kind}
          ),
          log: false
        )

      if Enum.map(rows, & &1.resource_id) == ids,
        do: {:ok, rows},
        else: error(:not_found)
    end
  rescue
    exception -> {:error, KnowledgeError.from(exception)}
  end

  @impl true
  def relationship_in_scope(context, id) do
    with {:ok, _} <- Types.canonical_uuid(%{id: id}, :id),
         {:ok, repo} <- in_scope_repo(context) do
      row =
        repo.one(
          from(r in Relationship,
            where:
              r.id == ^id and r.vault_id == ^context.owner_scope_id and
                r.classification == :private,
            select: %{
              relationship_id: r.id,
              source_resource_id: r.source_resource_id,
              target_resource_id: r.target_resource_id,
              target_resource_version_id: r.target_resource_version_id,
              type: r.type
            }
          ),
          log: false
        )

      {:ok, row}
    end
  rescue
    exception -> {:error, KnowledgeError.from(exception)}
  end

  defp validate_ids([id]) do
    with {:ok, _} <- Types.canonical_uuid(%{id: id}, :id), do: :ok
  end

  defp validate_ids([first, second]) when is_binary(first) and is_binary(second) do
    with {:ok, _} <- Types.canonical_uuid(%{id: first}, :id),
         {:ok, _} <- Types.canonical_uuid(%{id: second}, :id),
         true <- first < second do
      :ok
    else
      _ -> error(:invalid)
    end
  end

  defp validate_ids(_), do: error(:invalid)

  defp in_scope_repo(%{
         repo: repo,
         principal_id: principal,
         owner_scope_id: owner,
         correlation_id: correlation
       })
       when is_atom(repo) and not is_nil(repo) do
    with {:ok, _} <- Types.canonical_uuid(%{id: principal}, :id),
         {:ok, _} <- Types.canonical_uuid(%{id: owner}, :id),
         {:ok, _} <- Types.canonical_uuid(%{id: correlation}, :id),
         true <- repo.in_transaction?(),
         %{rows: [[^principal, ^owner]]} <-
           SafeSQL.query!(
             repo,
             "SELECT current_setting('singularity.principal_id',true), current_setting('singularity.vault_id',true)",
             []
           ) do
      {:ok, repo}
    else
      _ -> error(:invalid)
    end
  end

  defp in_scope_repo(_), do: error(:invalid)
  defp error(code), do: {:error, Error.new(code)}
end
