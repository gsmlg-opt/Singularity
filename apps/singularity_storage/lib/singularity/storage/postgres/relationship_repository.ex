defmodule Singularity.Storage.Postgres.RelationshipRepository do
  @moduledoc "Internal authenticated persistence for explicit directed knowledge relationships."
  @behaviour Singularity.Domains.Relationships.Repository
  import Ecto.Query
  alias Singularity.Core.{Error, Relationship, Types}
  alias Singularity.Storage.ScopedRepo
  alias Singularity.Storage.Postgres.{KnowledgeError, UUID}
  alias Singularity.Storage.Schema.Content.{Resource, ResourceVersion}
  alias Singularity.Storage.Schema.Content.Relationship, as: StoredRelationship
  alias Singularity.Storage.Schema.Audit.Event

  @impl true
  def relate(context, input) do
    with {:ok, repo} <- context_repo(context),
         {:ok, edge} <- Relationship.new(input),
         true <- edge.owner_scope_id == context.owner_scope_id do
      scoped(repo, context, fn repo ->
        with :ok <- live_endpoints(repo, context, edge) do
          row = %{
            id: edge.relationship_id,
            vault_id: edge.owner_scope_id,
            classification: :private,
            source_resource_id: edge.source_resource_id,
            target_resource_id: edge.target_resource_id,
            target_resource_version_id: edge.target_resource_version_id,
            type: edge.type,
            created_by_principal_id: context.principal_id,
            inserted_at: DateTime.utc_now(:microsecond)
          }

          {count, _} =
            repo.insert_all(StoredRelationship, [row],
              on_conflict: :nothing,
              conflict_target: [:vault_id, :source_resource_id, :target_resource_id, :type],
              log: false
            )

          stored =
            repo.one(
              from r in StoredRelationship,
                where:
                  r.vault_id == ^context.owner_scope_id and
                    r.source_resource_id == ^edge.source_resource_id and
                    r.target_resource_id == ^edge.target_resource_id and r.type == ^edge.type
            )

          if stored.target_resource_version_id == edge.target_resource_version_id do
            with :ok <- maybe_audit(repo, context, stored, count, "knowledge.related"),
                 do: {:ok, core(stored)}
          else
            error(:conflict)
          end
        end
      end)
    else
      false -> error(:invalid)
      {:error, reason} -> {:error, KnowledgeError.from(reason)}
    end
  rescue
    exception -> {:error, KnowledgeError.from(exception)}
  end

  @impl true
  def unrelate(context, id) do
    with {:ok, repo} <- context_repo(context), :ok <- UUID.validate(id) do
      scoped(repo, context, fn repo ->
        query =
          from r in StoredRelationship,
            where: r.vault_id == ^context.owner_scope_id and r.id == ^id,
            select: r

        case repo.delete_all(query) do
          {0, _} ->
            :ok

          {1, [row]} ->
            maybe_audit(repo, context, row, 1, "knowledge.unrelated")
        end
      end)
    end
  rescue
    exception -> {:error, KnowledgeError.from(exception)}
  end

  @impl true
  def outgoing(context, id), do: list(context, id, :source_resource_id)
  @impl true
  def incoming(context, id), do: list(context, id, :target_resource_id)

  defp list(context, id, direction) do
    with {:ok, repo} <- context_repo(context), :ok <- UUID.validate(id) do
      scoped(repo, context, fn repo ->
        rows =
          repo.all(
            from r in StoredRelationship,
              join: source in Resource,
              on: source.id == r.source_resource_id and source.vault_id == r.vault_id,
              join: target in Resource,
              on: target.id == r.target_resource_id and target.vault_id == r.vault_id,
              where:
                r.vault_id == ^context.owner_scope_id and field(r, ^direction) == ^id and
                  is_nil(source.deleted_at) and is_nil(target.deleted_at) and
                  source.classification == :private and target.classification == :private,
              order_by: [asc: r.source_resource_id, asc: r.target_resource_id, asc: r.id],
              limit: 100,
              select: r
          )

        {:ok, Enum.map(rows, &core/1)}
      end)
    end
  rescue
    exception -> {:error, KnowledgeError.from(exception)}
  end

  defp live_endpoints(repo, context, edge) do
    ids = [edge.source_resource_id, edge.target_resource_id]

    rows =
      repo.all(
        from r in Resource,
          where:
            r.id in ^ids and r.vault_id == ^context.owner_scope_id and
              r.classification == :private and is_nil(r.deleted_at),
          order_by: r.id,
          lock: "FOR SHARE",
          select: r.id
      )

    if length(rows) == 2 do
      valid_pin(repo, context, edge)
    else
      error(:not_found)
    end
  end

  defp valid_pin(_repo, _context, %{target_resource_version_id: nil}), do: :ok

  defp valid_pin(repo, context, edge) do
    case repo.one(
           from v in ResourceVersion,
             where:
               v.id == ^edge.target_resource_version_id and
                 v.resource_id == ^edge.target_resource_id and
                 v.vault_id == ^context.owner_scope_id and v.classification == :private,
             select: v.id
         ) do
      nil -> error(:invalid)
      _id -> :ok
    end
  end

  defp maybe_audit(_repo, _context, _row, 0, _operation), do: :ok

  defp maybe_audit(repo, context, row, 1, operation) do
    metadata = %{
      "source_resource_id" => row.source_resource_id,
      "target_resource_id" => row.target_resource_id,
      "type" => Atom.to_string(row.type)
    }

    metadata =
      if row.target_resource_version_id,
        do: Map.put(metadata, "target_resource_version_id", row.target_resource_version_id),
        else: metadata

    changeset =
      Event.append_changeset(%Event{}, %{
        id: Ecto.UUID.generate(),
        vault_id: context.owner_scope_id,
        actor_kind: :principal,
        principal_id: context.principal_id,
        operation: operation,
        result: :completed,
        classification: :private,
        correlation_id: context.correlation_id,
        target_type: "relationship",
        target_id: row.id,
        metadata: metadata,
        occurred_at: DateTime.utc_now(:microsecond)
      })

    case repo.insert(changeset, log: false) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, KnowledgeError.from(reason)}
    end
  end

  defp core(row) do
    %Relationship{
      relationship_id: row.id,
      owner_scope_id: row.vault_id,
      source_resource_id: row.source_resource_id,
      target_resource_id: row.target_resource_id,
      target_resource_version_id: row.target_resource_version_id,
      classification: :private,
      type: row.type
    }
  end

  defp context_repo(%{
         repo: repo,
         principal_id: principal,
         owner_scope_id: owner,
         correlation_id: correlation
       })
       when is_atom(repo) do
    with {:ok, _} <- Types.canonical_uuid(%{id: principal}, :id),
         {:ok, _} <- Types.canonical_uuid(%{id: owner}, :id),
         {:ok, _} <- Types.canonical_uuid(%{id: correlation}, :id),
         false <- repo.in_transaction?() do
      {:ok, repo}
    else
      _ -> error(:invalid)
    end
  end

  defp context_repo(_), do: error(:invalid)

  defp scoped(repo, context, fun),
    do:
      ScopedRepo.transact(
        repo,
        %{principal_id: context.principal_id, vault_id: context.owner_scope_id},
        fun
      )

  defp error(code), do: {:error, Error.new(code)}
end
