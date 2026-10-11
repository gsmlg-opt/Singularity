defmodule Singularity.Storage.Postgres.TagRepository do
  @moduledoc "Internal authenticated tag persistence with mutation-only audit events."
  @behaviour Singularity.Domains.Tags.Repository
  alias Singularity.Core.{Error, OrganizationPage, OrganizationPageQuery, Tag, Types}
  alias Singularity.Storage.{SafeSQL, ScopedRepo}
  alias Singularity.Storage.Postgres.{KnowledgeError, OrganizationCursor, UUID}
  alias Singularity.Storage.Schema.Audit.Event

  @impl true
  def resolve(context, input), do: resolve(context, input, :standalone)

  @impl true
  def resolve_in_scope(context, input), do: resolve(context, input, :existing)

  defp resolve(context, input, mode) do
    with {:ok, repo} <- context_repo(context, mode),
         {:ok, tag} <- Tag.new(input),
         true <- tag.owner_scope_id == context.owner_scope_id do
      within(repo, context, mode, fn repo ->
        %{num_rows: count} =
          SafeSQL.query!(
            repo,
            """
            INSERT INTO content.tags (id,vault_id,classification,display_value,normalized_key,created_by_principal_id,inserted_at)
            VALUES ($1,$2,'private',$3,$4,$5,CURRENT_TIMESTAMP)
            ON CONFLICT (vault_id,normalized_key COLLATE "C") DO NOTHING
            """,
            [
              dump(tag.tag_id),
              dump(tag.owner_scope_id),
              tag.display_value,
              tag.normalized_key,
              dump(context.principal_id)
            ]
          )

        with :ok <- audit(repo, context, count, "knowledge.tag_created", tag.tag_id, %{}) do
          %{rows: [[id, display, key]]} =
            SafeSQL.query!(
              repo,
              "SELECT id::text,display_value,normalized_key FROM content.tags WHERE vault_id=$1 AND normalized_key=$2",
              [dump(context.owner_scope_id), tag.normalized_key]
            )

          {:ok, %Tag{tag | tag_id: id, display_value: display, normalized_key: key}}
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
  def attach(context, resource, tag), do: mutate(context, resource, tag, :attach, :standalone)
  @impl true
  def detach(context, resource, tag), do: mutate(context, resource, tag, :detach, :standalone)

  @impl true
  def attach_in_scope(context, resource, tag),
    do: mutate(context, resource, tag, :attach, :existing)

  @impl true
  def detach_in_scope(context, resource, tag),
    do: mutate(context, resource, tag, :detach, :existing)

  @impl true
  def list_page_in_scope(context, resource, query, allowed_kinds),
    do: page(context, resource, query, allowed_kinds, :resource_tags)

  @impl true
  def browse_in_scope(context, tag, query, allowed_kinds),
    do: page(context, tag, query, allowed_kinds, :tag_resources)

  @impl true
  def list(context, resource) do
    with {:ok, repo} <- context_repo(context), :ok <- UUID.validate([resource]) do
      scoped(repo, context, fn repo ->
        with :ok <- live_resource(repo, context, resource) do
          %{rows: rows} =
            SafeSQL.query!(
              repo,
              """
              SELECT t.id::text,t.display_value,t.normalized_key
              FROM content.tags t JOIN content.resource_tags rt ON rt.tag_id=t.id AND rt.vault_id=t.vault_id
              WHERE rt.resource_id=$1 AND rt.vault_id=$2 ORDER BY t.id LIMIT 100
              """,
              [dump(resource), dump(context.owner_scope_id)]
            )

          {:ok,
           Enum.map(rows, fn [id, display, key] ->
             %Tag{
               tag_id: id,
               owner_scope_id: context.owner_scope_id,
               classification: :private,
               display_value: display,
               normalized_key: key
             }
           end)}
        end
      end)
    end
  rescue
    exception -> {:error, KnowledgeError.from(exception)}
  end

  defp mutate(context, resource, tag, operation, mode) do
    with {:ok, repo} <- context_repo(context, mode), :ok <- UUID.validate([resource, tag]) do
      within(repo, context, mode, fn repo ->
        with :ok <- mutation_resource(repo, context, resource, operation),
             :ok <- visible_tag(repo, context, tag) do
          statement =
            case operation do
              :attach ->
                "INSERT INTO content.resource_tags (resource_id,tag_id,vault_id,classification,inserted_at) VALUES ($1,$2,$3,'private',CURRENT_TIMESTAMP) ON CONFLICT (resource_id,tag_id,vault_id) DO NOTHING"

              :detach ->
                "DELETE FROM content.resource_tags WHERE resource_id=$1 AND tag_id=$2 AND vault_id=$3"
            end

          %{num_rows: count} =
            SafeSQL.query!(repo, statement, [
              dump(resource),
              dump(tag),
              dump(context.owner_scope_id)
            ])

          event =
            if operation == :attach, do: "knowledge.tag_attached", else: "knowledge.tag_detached"

          audit(repo, context, count, event, tag, %{"resource_id" => resource})
        end
      end)
    end
  rescue
    exception -> {:error, KnowledgeError.from(exception)}
  end

  defp page(context, selector, query, allowed_kinds, operation) do
    with {:ok, repo} <- context_repo(context, :existing),
         :ok <- UUID.validate(selector),
         {:ok, query} <- OrganizationPageQuery.validate(query),
         :ok <- allowed_kinds(allowed_kinds, []),
         {:ok, secret} <- cursor_secret(),
         binding = %{
           owner_scope_id: context.owner_scope_id,
           selector_id: selector,
           operation: operation,
           ordering_version: 1
         },
         {:ok, last} <- OrganizationCursor.decode(query.cursor, binding, secret),
         :ok <- page_selector(repo, context, selector, operation, allowed_kinds) do
      rows = page_rows(repo, context, selector, query.limit + 1, last, operation, allowed_kinds)
      items = rows |> Enum.take(query.limit) |> Enum.map(&page_item(operation, &1))

      with {:ok, next_cursor} <- continuation(rows, items, query, binding, secret),
           do: OrganizationPage.new(operation, %{items: items, next_cursor: next_cursor}, query)
    end
  rescue
    exception -> {:error, KnowledgeError.from(exception)}
  end

  defp page_selector(repo, context, resource, :resource_tags, kinds) do
    case SafeSQL.query!(
           repo,
           """
           SELECT id FROM content.resources
           WHERE id=$1 AND vault_id=$2 AND classification='private'
             AND kind=ANY($3::text[]) AND content.knowledge_resource_is_live(vault_id,id)
           """,
           [dump(resource), dump(context.owner_scope_id), Enum.map(kinds, &Atom.to_string/1)]
         ) do
      %{rows: [[_]]} -> :ok
      %{rows: []} -> error(:not_found)
    end
  end

  defp page_selector(repo, context, tag, :tag_resources, _kinds),
    do: visible_tag(repo, context, tag)

  defp page_rows(repo, context, resource, limit, last, :resource_tags, kinds) do
    %{rows: rows} =
      SafeSQL.query!(
        repo,
        """
        SELECT t.id::text,t.display_value
        FROM content.tags t
        JOIN content.resource_tags rt ON rt.tag_id=t.id AND rt.vault_id=t.vault_id
        JOIN content.resources r ON r.id=rt.resource_id AND r.vault_id=rt.vault_id
        WHERE rt.resource_id=$1 AND rt.vault_id=$2
          AND t.classification='private' AND rt.classification='private'
          AND r.classification='private' AND content.knowledge_resource_is_live(r.vault_id,r.id)
          AND r.kind=ANY($3::text[]) AND ($4::uuid IS NULL OR t.id>$4)
        ORDER BY t.id LIMIT $5
        """,
        [
          dump(resource),
          dump(context.owner_scope_id),
          Enum.map(kinds, &Atom.to_string/1),
          optional_dump(last),
          limit
        ]
      )

    rows
  end

  defp page_rows(repo, context, tag, limit, last, :tag_resources, kinds) do
    %{rows: rows} =
      SafeSQL.query!(
        repo,
        """
        SELECT r.id::text,r.kind
        FROM content.resource_tags rt
        JOIN content.tags t ON t.id=rt.tag_id AND t.vault_id=rt.vault_id
        JOIN content.resources r ON r.id=rt.resource_id AND r.vault_id=rt.vault_id
        WHERE rt.tag_id=$1 AND rt.vault_id=$2
          AND t.classification='private' AND rt.classification='private'
          AND r.classification='private' AND content.knowledge_resource_is_live(r.vault_id,r.id)
          AND r.kind=ANY($3::text[]) AND ($4::uuid IS NULL OR r.id>$4)
        ORDER BY r.id LIMIT $5
        """,
        [
          dump(tag),
          dump(context.owner_scope_id),
          Enum.map(kinds, &Atom.to_string/1),
          optional_dump(last),
          limit
        ]
      )

    rows
  end

  defp page_item(:resource_tags, [id, display]), do: %{tag_id: id, display_value: display}

  defp page_item(:tag_resources, [id, kind]) do
    kind =
      case kind do
        "asset" -> :asset
        "document" -> :document
        "note" -> :note
      end

    %{resource_id: id, kind: kind}
  end

  defp continuation(rows, items, query, binding, secret) do
    if length(rows) > query.limit do
      last = List.last(items)

      id =
        case binding.operation do
          :resource_tags -> last.tag_id
          :tag_resources -> last.resource_id
        end

      OrganizationCursor.encode(id, binding, secret)
    else
      {:ok, :done}
    end
  end

  defp allowed_kinds([], _seen), do: :ok

  defp allowed_kinds([kind | rest], seen) when kind in [:asset, :document, :note] do
    if kind in seen, do: error(:invalid), else: allowed_kinds(rest, [kind | seen])
  end

  defp allowed_kinds(_kinds, _seen), do: error(:invalid)

  defp cursor_secret do
    case Application.fetch_env(:singularity_runtime, :audit_fingerprint_secret) do
      {:ok, secret} when is_binary(secret) and byte_size(secret) >= 32 -> {:ok, secret}
      _ -> error(:invalid)
    end
  end

  defp live_resource(repo, context, resource) do
    case SafeSQL.query!(
           repo,
           "SELECT id FROM content.resources WHERE id=$1 AND vault_id=$2 AND content.knowledge_resource_is_live(vault_id,id)",
           [dump(resource), dump(context.owner_scope_id)]
         ) do
      %{rows: [[_]]} -> :ok
      %{rows: []} -> error(:not_found)
    end
  end

  defp visible_tag(repo, context, tag) do
    case SafeSQL.query!(repo, "SELECT id FROM content.tags WHERE id=$1 AND vault_id=$2", [
           dump(tag),
           dump(context.owner_scope_id)
         ]) do
      %{rows: [[_]]} -> :ok
      %{rows: []} -> error(:not_found)
    end
  end

  defp mutation_resource(repo, context, resource, :attach),
    do: live_resource(repo, context, resource)

  defp mutation_resource(repo, context, resource, :detach) do
    case SafeSQL.query!(
           repo,
           "SELECT content.lock_knowledge_organization_resources($1,ARRAY[$2]::uuid[])",
           [dump(context.owner_scope_id), dump(resource)]
         ) do
      %{rows: [[true]]} -> :ok
      %{rows: [[false]]} -> error(:not_found)
    end
  end

  defp audit(_repo, _context, 0, _operation, _tag, _metadata), do: :ok

  defp audit(repo, context, 1, operation, tag, metadata) do
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
        target_type: "tag",
        target_id: tag,
        metadata: metadata,
        occurred_at: DateTime.utc_now(:microsecond)
      })

    case repo.insert(changeset, log: false, telemetry_event: nil) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, KnowledgeError.from(reason)}
    end
  end

  defp context_repo(%{repo: repo} = context) when is_atom(repo) do
    with {:ok, _} <- Types.canonical_uuid(context, :principal_id),
         {:ok, _} <- Types.canonical_uuid(context, :owner_scope_id),
         {:ok, _} <- Types.canonical_uuid(context, :correlation_id),
         false <- repo.in_transaction?() do
      {:ok, repo}
    else
      true -> error(:invalid)
      {:error, _} = result -> result
    end
  end

  defp context_repo(_), do: error(:invalid)

  defp context_repo(context, :standalone), do: context_repo(context)

  defp context_repo(%{repo: repo} = context, :existing) when is_atom(repo) and not is_nil(repo) do
    with {:ok, _} <- Types.canonical_uuid(context, :principal_id),
         {:ok, _} <- Types.canonical_uuid(context, :owner_scope_id),
         {:ok, _} <- Types.canonical_uuid(context, :correlation_id),
         true <- repo.in_transaction?(),
         %{rows: [[principal, owner]]} <-
           SafeSQL.query!(
             repo,
             "SELECT current_setting('singularity.principal_id',true),current_setting('singularity.vault_id',true)",
             []
           ),
         true <- principal == context.principal_id and owner == context.owner_scope_id do
      {:ok, repo}
    else
      _ -> error(:invalid)
    end
  end

  defp context_repo(_context, :existing), do: error(:invalid)

  defp within(repo, context, :standalone, fun), do: scoped(repo, context, fun)
  defp within(repo, _context, :existing, fun), do: fun.(repo)

  defp scoped(repo, context, fun),
    do:
      ScopedRepo.transact(
        repo,
        %{principal_id: context.principal_id, vault_id: context.owner_scope_id},
        fun
      )

  defp optional_dump(nil), do: nil
  defp optional_dump(id), do: dump(id)
  defp dump(id), do: Ecto.UUID.dump!(id)
  defp error(code), do: {:error, Error.new(code)}
end
