defmodule Singularity.Storage.Postgres.DocumentPinnedSource do
  @moduledoc false
  import Ecto.Query

  alias Singularity.Core.Error
  alias Singularity.Storage.{ScopedRepo, SafeSQL}
  alias Singularity.Storage.Postgres.UUID

  alias Singularity.Storage.Schema.Content.{
    AssetKeyEnvelope,
    AssetObject,
    DocumentVersion,
    Resource
  }

  alias Singularity.Storage.Schema.Core.OutboxEvent

  def load_live(repo, context, resource_id), do: load(repo, context, resource_id, nil)

  def load_for_job(repo, context, version_id, job_id) do
    with :ok <- UUID.validate([version_id, job_id]) do
      load(repo, context, version_id, job_id)
    end
  end

  defp load(repo, %{principal_id: principal, owner_scope_id: owner} = context, id, job_id)
       when is_atom(repo) do
    with :ok <- UUID.validate([principal, owner, id]),
         false <- repo.in_transaction?() do
      ScopedRepo.transact(
        repo,
        %{principal_id: principal, vault_id: owner},
        [isolation: :repeatable_read],
        fn tx ->
          with :ok <- matching_context(tx, context),
               {:ok, row} <- source_row(tx, owner, id, job_id),
               :ok <- authorized(tx, context, row, job_id),
               {:ok, generation} <- generation(tx, owner, row) do
            {:ok,
             %{
               resource_id: row.resource_id,
               resource_version_id: row.resource_version_id,
               object_id: row.source_object_id,
               object_generation: generation,
               source_digest: row.source_digest,
               source_byte_size: row.source_byte_size,
               media_type: row.media_type,
               owner_scope_id: owner,
               vault_id: owner,
               classification: :private
             }}
          end
        end
      )
    else
      true -> error(:invalid)
      {:error, %Error{}} = result -> result
    end
  rescue
    _ -> error(:storage_unavailable)
  end

  defp load(_, _, _, _), do: error(:not_found)

  defp matching_context(repo, %{principal_id: principal, owner_scope_id: owner}) do
    case SafeSQL.query!(
           repo,
           "SELECT current_setting('singularity.principal_id',true), current_setting('singularity.vault_id',true)",
           []
         ) do
      %{rows: [[^principal, ^owner]]} -> :ok
      _ -> error(:not_found)
    end
  end

  defp source_row(repo, owner, id, job_id) do
    query =
      from d in DocumentVersion,
        join: r in Resource,
        on:
          r.id == d.resource_id and r.vault_id == d.vault_id and
            r.classification == d.classification,
        left_join: o in AssetObject,
        on:
          o.id == d.source_object_id and o.vault_id == d.vault_id and
            o.classification == d.classification,
        where: d.vault_id == ^owner and d.classification == :private and r.kind == :document,
        where:
          ^if(job_id == nil,
            do: dynamic([d, r], d.resource_id == ^id and is_nil(r.deleted_at)),
            else: dynamic([d], d.resource_version_id == ^id)
          ),
        select: %{
          resource_id: d.resource_id,
          resource_version_id: d.resource_version_id,
          source_object_id: d.source_object_id,
          source_digest: d.source_digest,
          source_byte_size: d.source_byte_size,
          media_type: d.media_type,
          state: d.state,
          attempt_job_id: d.attempt_job_id,
          attempt_active: fragment("? > clock_timestamp()", d.attempt_deadline_at),
          deleted_at: r.deleted_at,
          object_id: o.id,
          object_size: o.plaintext_byte_size,
          object_lifecycle: o.lifecycle
        }

    case repo.one(query, log: false) do
      nil ->
        error(:not_found)

      %{object_id: nil} ->
        error(:integrity_failure)

      %{object_lifecycle: :available, object_size: size, source_byte_size: size} = row ->
        {:ok, row}

      _ ->
        error(:integrity_failure)
    end
  end

  defp authorized(_repo, _context, _row, nil), do: :ok

  defp authorized(repo, context, row, job_id) do
    event =
      repo.one(
        from e in OutboxEvent,
          where: e.id == ^job_id and e.vault_id == ^context.owner_scope_id,
          select: %{
            event_type: e.event_type,
            principal_id: e.principal_id,
            required_capability: e.required_capability,
            classification: e.classification,
            payload: e.payload
          }
      )

    valid_event? =
      event && event.event_type == "document.extraction_requested" &&
        event.principal_id == context.principal_id && event.required_capability == "asset.read" &&
        event.classification == :private &&
        event.payload == %{
          "resource_id" => row.resource_id,
          "resource_version_id" => row.resource_version_id
        }

    valid_state? =
      (is_nil(row.deleted_at) and row.state == :pending) or
        (row.state == :extracting and row.attempt_job_id == job_id and
           row.attempt_active == true)

    if valid_event? && valid_state?, do: :ok, else: error(:not_found)
  end

  defp generation(repo, owner, row) do
    generation =
      repo.one(
        from e in AssetKeyEnvelope,
          where: e.asset_object_id == ^row.source_object_id and e.vault_id == ^owner,
          where: e.classification == :private,
          select: max(e.key_generation)
      )

    case generation do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _ -> error(:integrity_failure)
    end
  end

  defp error(code), do: {:error, Error.new(code)}
end
