defmodule Singularity.Storage.Postgres.TagRepository do
  @moduledoc "Internal authenticated tag persistence with mutation-only audit events."
  @behaviour Singularity.Domains.Tags.Repository
  alias Singularity.Core.{Error, Tag, Types}
  alias Singularity.Storage.{SafeSQL, ScopedRepo}
  alias Singularity.Storage.Postgres.{KnowledgeError, UUID}
  alias Singularity.Storage.Schema.Audit.Event

  @impl true
  def resolve(context, input) do
    with {:ok, repo} <- context_repo(context),
         {:ok, tag} <- Tag.new(input),
         true <- tag.owner_scope_id == context.owner_scope_id do
      scoped(repo, context, fn repo ->
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
  def attach(context, resource, tag), do: mutate(context, resource, tag, :attach)
  @impl true
  def detach(context, resource, tag), do: mutate(context, resource, tag, :detach)

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

  defp mutate(context, resource, tag, operation) do
    with {:ok, repo} <- context_repo(context), :ok <- UUID.validate([resource, tag]) do
      scoped(repo, context, fn repo ->
        with :ok <- live_resource(repo, context, resource),
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

  defp live_resource(repo, context, resource) do
    case SafeSQL.query!(
           repo,
           "SELECT id FROM content.resources WHERE id=$1 AND vault_id=$2 AND classification='private' AND kind IN ('asset','note','document') AND deleted_at IS NULL FOR SHARE",
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

  defp scoped(repo, context, fun),
    do:
      ScopedRepo.transact(
        repo,
        %{principal_id: context.principal_id, vault_id: context.owner_scope_id},
        fun
      )

  defp dump(id), do: Ecto.UUID.dump!(id)
  defp error(code), do: {:error, Error.new(code)}
end
