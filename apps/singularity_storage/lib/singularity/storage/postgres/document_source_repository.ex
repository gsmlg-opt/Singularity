defmodule Singularity.Storage.Postgres.DocumentSourceRepository do
  @moduledoc false
  import Ecto.Query
  alias Singularity.Core.{DocumentSource, Error}
  alias Singularity.Storage.{SafeSQL, ScopedRepo}
  alias Singularity.Storage.Documents.PreparedSource
  alias Singularity.Storage.Postgres.{AssetRepository, UUID}

  alias Singularity.Storage.Schema.Content.{
    Asset,
    AssetMetadata,
    AssetObject,
    Resource,
    ResourceAsset,
    ResourceVersion,
    Tombstone
  }

  @spec load(module(), map(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def load(repo, %{principal_id: principal, owner_scope_id: owner} = context, asset_id) do
    with :ok <- UUID.validate([principal, owner, asset_id]),
         false <- repo.in_transaction?() do
      ScopedRepo.transact(
        repo,
        %{principal_id: principal, vault_id: owner},
        [isolation: :repeatable_read],
        fn transaction_repo ->
          load_binding(transaction_repo, context, asset_id)
        end
      )
    else
      true -> error(:invalid)
      {:error, %Error{}} = result -> result
    end
  rescue
    _ -> error(:storage_unavailable, true)
  end

  def load(_, _, _), do: error(:invalid)

  @spec revalidate(module(), map(), PreparedSource.t()) ::
          {:ok, DocumentSource.t()} | {:error, Error.t()}
  def revalidate(
        repo,
        %{principal_id: principal, owner_scope_id: owner} = context,
        %PreparedSource{} = prepared
      ) do
    with :ok <- UUID.validate([principal, owner]),
         true <- repo.in_transaction?(),
         :ok <- matching_context(repo, context),
         true <- prepared.principal_id == principal,
         {:ok, source} <- DocumentSource.new(prepared.source),
         :ok <- lock_source(repo, source.asset_id, owner),
         {:ok, binding} <- load_binding(repo, context, source.asset_id),
         true <- binding == prepared.binding,
         true <-
           Map.take(binding, Map.keys(Map.from_struct(source)) -- [:digest]) ==
             Map.delete(Map.from_struct(source), :digest) do
      {:ok, source}
    else
      false -> error(if(repo.in_transaction?(), do: :conflict, else: :invalid))
      {:error, %Error{}} = result -> result
      _ -> error(:invalid)
    end
  rescue
    _ -> error(:storage_unavailable, true)
  end

  def revalidate(_, _, _), do: error(:invalid)

  defp matching_context(repo, %{principal_id: principal, owner_scope_id: owner}) do
    case SafeSQL.query!(
           repo,
           "SELECT current_setting('singularity.principal_id',true), current_setting('singularity.vault_id',true)",
           []
         ) do
      %{rows: [[^principal, ^owner]]} -> :ok
      _ -> error(:forbidden)
    end
  end

  # Preserve the established Asset-then-object row lock order. No nested scope.
  defp lock_source(repo, asset_id, owner) do
    case repo.one(
           from a in Asset,
             where: a.id == ^asset_id and a.vault_id == ^owner,
             select: a.asset_object_id,
             lock: "FOR UPDATE"
         ) do
      nil ->
        error(:not_found)

      object_id ->
        case repo.one(
               from o in AssetObject,
                 where: o.id == ^object_id and o.vault_id == ^owner,
                 select: o.id,
                 lock: "FOR UPDATE"
             ) do
          nil -> error(:not_found)
          _ -> :ok
        end
    end
  end

  defp load_binding(repo, context, asset_id) do
    with :ok <- matching_context(repo, context),
         {:ok, object} <- AssetRepository.authorized_object(repo, asset_id),
         %{classification: :private, vault_id: owner} when owner == context.owner_scope_id <-
           object,
         binding when not is_nil(binding) <-
           repo.one(source_query(asset_id, context.owner_scope_id)),
         true <- binding.object_id == object.object_id do
      {:ok, Map.put(binding, :object_generation, object.object_generation)}
    else
      {:error, %Error{}} = result -> result
      _ -> error(:not_found)
    end
  end

  defp source_query(asset_id, owner) do
    from a in Asset,
      join: v in ResourceVersion,
      on:
        v.id == a.resource_version_id and v.vault_id == a.vault_id and
          v.classification == a.classification,
      join: r in Resource,
      on:
        r.id == v.resource_id and r.vault_id == v.vault_id and
          r.classification == v.classification,
      join: link in ResourceAsset,
      on:
        link.asset_id == a.id and link.resource_version_id == v.id and link.vault_id == a.vault_id and
          link.classification == a.classification,
      join: o in AssetObject,
      on:
        o.id == a.asset_object_id and o.vault_id == a.vault_id and
          o.classification == a.classification,
      join: m in AssetMetadata,
      on:
        m.asset_id == a.id and m.resource_version_id == v.id and m.vault_id == a.vault_id and
          m.classification == a.classification and m.plaintext_byte_size == o.plaintext_byte_size,
      left_join: t in Tombstone,
      on: t.asset_id == a.id and t.vault_id == a.vault_id,
      where: a.id == ^asset_id and a.vault_id == ^owner and a.classification == :private,
      where: a.state in [:available, :processing, :ready] and o.lifecycle == :available,
      where:
        is_nil(link.released_at) and is_nil(r.deleted_at) and r.kind == :asset and is_nil(t.id),
      where: m.extraction_state == :completed and not is_nil(m.detected_media_type),
      select: %{
        asset_id: a.id,
        resource_id: r.id,
        resource_version_id: v.id,
        object_id: o.id,
        owner_scope_id: a.vault_id,
        classification: a.classification,
        byte_size: o.plaintext_byte_size,
        media_type: m.detected_media_type,
        asset_state_revision: a.state_revision,
        object_lifecycle_revision: o.lifecycle_revision,
        association_inserted_at: link.inserted_at
      }
  end

  defp error(code, retryable? \\ false), do: {:error, Error.new(code, retryable?: retryable?)}
end
