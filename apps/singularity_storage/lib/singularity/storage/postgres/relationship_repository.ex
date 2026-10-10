defmodule Singularity.Storage.Postgres.RelationshipRepository do
  @moduledoc "Internal authenticated persistence for explicit directed knowledge relationships."
  @behaviour Singularity.Domains.Relationships.Repository
  import Ecto.Query
  alias Singularity.Core.{Error, OrganizationPage, OrganizationPageQuery, Relationship, Types}
  alias Singularity.Storage.{SafeSQL, ScopedRepo}
  alias Singularity.Storage.Postgres.{KnowledgeError, OrganizationCursor, UUID}
  alias Singularity.Storage.Schema.Content.{Resource, ResourceVersion}
  alias Singularity.Storage.Schema.Content.Relationship, as: StoredRelationship
  alias Singularity.Storage.Schema.Audit.Event

  @impl true
  def relate(context, input) do
    with {:ok, repo} <- context_repo(context),
         {:ok, edge} <- Relationship.new(input),
         true <- edge.owner_scope_id == context.owner_scope_id do
      scoped(repo, context, &do_relate(&1, context, edge))
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
      scoped(repo, context, &do_unrelate(&1, context, id))
    end
  rescue
    exception -> {:error, KnowledgeError.from(exception)}
  end

  @impl true
  def outgoing(context, id), do: list(context, id, :source_resource_id)
  @impl true
  def incoming(context, id), do: list(context, id, :target_resource_id)

  @impl true
  def relate_in_scope(context, input) do
    with {:ok, repo} <- in_scope_repo(context),
         {:ok, edge} <- Relationship.new(input),
         true <- edge.owner_scope_id == context.owner_scope_id do
      do_relate(repo, context, edge)
    else
      false -> error(:invalid)
      {:error, reason} -> {:error, KnowledgeError.from(reason)}
    end
  rescue
    exception -> {:error, KnowledgeError.from(exception)}
  end

  @impl true
  def unrelate_in_scope(context, id) do
    with {:ok, repo} <- in_scope_repo(context),
         {:ok, _id} <- Types.canonical_uuid(%{id: id}, :id) do
      do_unrelate(repo, context, id)
    end
  rescue
    exception -> {:error, KnowledgeError.from(exception)}
  end

  @impl true
  def outgoing_page_in_scope(context, id, query, allowed_kinds),
    do: page(context, id, query, allowed_kinds, :source_resource_id, :outgoing)

  @impl true
  def incoming_page_in_scope(context, id, query, allowed_kinds),
    do: page(context, id, query, allowed_kinds, :target_resource_id, :incoming)

  defp do_relate(repo, context, edge) do
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
  end

  defp do_unrelate(repo, context, id) do
    query =
      from r in StoredRelationship,
        where: r.vault_id == ^context.owner_scope_id and r.id == ^id,
        select: r

    case repo.delete_all(query) do
      {0, _} -> :ok
      {1, [row]} -> maybe_audit(repo, context, row, 1, "knowledge.unrelated")
    end
  end

  defp page(context, id, query, allowed_kinds, direction, operation) do
    with {:ok, repo} <- in_scope_repo(context),
         {:ok, _id} <- Types.canonical_uuid(%{id: id}, :id),
         {:ok, query} <- OrganizationPageQuery.validate(query),
         true <- valid_kinds?(allowed_kinds, []) do
      secret = Application.fetch_env!(:singularity_runtime, :audit_fingerprint_secret)

      binding = %{
        owner_scope_id: context.owner_scope_id,
        selector_id: id,
        operation: operation,
        ordering_version: 1
      }

      with {:ok, last_uuid} <- OrganizationCursor.decode(query.cursor, binding, secret),
           :ok <- visible_selector(repo, context, id, allowed_kinds) do
        rows = page_rows(repo, context, id, query.limit, allowed_kinds, direction, last_uuid)
        {returned, remaining} = Enum.split(rows, query.limit)

        with {:ok, next_cursor} <- next_cursor(returned, remaining, binding, secret) do
          OrganizationPage.new(
            operation,
            %{items: Enum.map(returned, &page_item/1), next_cursor: next_cursor},
            query
          )
        end
      end
    else
      false -> error(:invalid)
      {:error, reason} -> {:error, KnowledgeError.from(reason)}
    end
  rescue
    exception -> {:error, KnowledgeError.from(exception)}
  end

  defp page_rows(repo, context, id, limit, allowed_kinds, direction, last_uuid) do
    query =
      from r in StoredRelationship,
        join: source in Resource,
        on: source.id == r.source_resource_id and source.vault_id == r.vault_id,
        join: target in Resource,
        on: target.id == r.target_resource_id and target.vault_id == r.vault_id,
        where:
          r.vault_id == ^context.owner_scope_id and r.classification == :private and
            field(r, ^direction) == ^id and
            source.classification == :private and target.classification == :private and
            is_nil(source.deleted_at) and is_nil(target.deleted_at) and
            source.kind in ^allowed_kinds and target.kind in ^allowed_kinds,
        order_by: [asc: r.id],
        limit: ^(limit + 1),
        select: r

    query = if is_nil(last_uuid), do: query, else: from(r in query, where: r.id > ^last_uuid)
    repo.all(query)
  end

  defp visible_selector(repo, context, id, allowed_kinds) do
    if repo.exists?(
         from r in Resource,
           where:
             r.id == ^id and r.vault_id == ^context.owner_scope_id and
               r.classification == :private and is_nil(r.deleted_at) and r.kind in ^allowed_kinds
       ) do
      :ok
    else
      error(:not_found)
    end
  end

  defp next_cursor(_returned, [], _binding, _secret), do: {:ok, :done}

  defp next_cursor(returned, [_extra], binding, secret),
    do: OrganizationCursor.encode(List.last(returned).id, binding, secret)

  defp page_item(row) do
    %{
      relationship_id: row.id,
      source_resource_id: row.source_resource_id,
      target_resource_id: row.target_resource_id,
      target_resource_version_id: row.target_resource_version_id,
      type: row.type
    }
  end

  defp valid_kinds?([], _seen), do: true

  defp valid_kinds?([kind | rest], seen) when kind in [:asset, :note, :document] do
    kind not in seen and valid_kinds?(rest, [kind | seen])
  end

  defp valid_kinds?(_kinds, _seen), do: false

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

  defp validated_context_repo(%{
         repo: repo,
         principal_id: principal,
         owner_scope_id: owner,
         correlation_id: correlation
       })
       when is_atom(repo) do
    with {:ok, _} <- Types.canonical_uuid(%{id: principal}, :id),
         {:ok, _} <- Types.canonical_uuid(%{id: owner}, :id),
         {:ok, _} <- Types.canonical_uuid(%{id: correlation}, :id) do
      {:ok, repo}
    else
      _ -> error(:invalid)
    end
  end

  defp validated_context_repo(_), do: error(:invalid)

  defp context_repo(context) do
    with {:ok, repo} <- validated_context_repo(context), false <- repo.in_transaction?() do
      {:ok, repo}
    else
      _ -> error(:invalid)
    end
  end

  defp in_scope_repo(context) do
    with {:ok, repo} <- validated_context_repo(context),
         true <- repo.in_transaction?(),
         %{rows: [[principal, owner]]} <-
           SafeSQL.query!(
             repo,
             "SELECT current_setting('singularity.principal_id',true), current_setting('singularity.vault_id',true)",
             []
           ),
         true <- principal == context.principal_id and owner == context.owner_scope_id do
      {:ok, repo}
    else
      _ -> error(:invalid)
    end
  end

  defp scoped(repo, context, fun),
    do:
      ScopedRepo.transact(
        repo,
        %{principal_id: context.principal_id, vault_id: context.owner_scope_id},
        fun
      )

  defp error(code), do: {:error, Error.new(code)}
end
