defmodule Singularity.Storage.Backup.KnowledgeIntegrityAudit do
  @moduledoc "V3 knowledge integrity composition; legacy rebuilding remains unchanged."

  alias Singularity.Core.Error
  alias Singularity.Storage.Backup.{IntegrityAudit, KnowledgeIntegrityInventory}
  alias Singularity.Storage.SafeSQL, as: SQL

  @binding_keys ~w[manifest_id vault_id]a
  @max_bigint 9_223_372_036_854_775_807
  @utc_timestamp ~r/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z\z/

  @spec verify_document_sources(module(), map(), [map()], [map()]) ::
          :ok | {:error, Error.t()}
  defdelegate verify_document_sources(repo, binding, original_inventory, plaintext_hashes),
    to: KnowledgeIntegrityInventory

  @spec rebuild(module(), map()) :: {:ok, IntegrityAudit.SearchSummary.t()} | {:error, Error.t()}
  def rebuild(repo, binding) when is_atom(repo) and is_map(binding) do
    if valid_binding?(binding) and not repo.in_transaction?() do
      rebuild_transaction(repo, binding)
    else
      invalid()
    end
  rescue
    _exception -> unavailable()
  catch
    _kind, _reason -> unavailable()
  end

  def rebuild(_repo, _binding), do: invalid()

  defp rebuild_transaction(repo, binding) do
    case repo.transaction(
           fn ->
             with {:ok, _} <- query(repo, "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ", []),
                  {:ok, _} <- query(repo, "SET LOCAL ROLE singularity_table_owner", []),
                  {:ok, %{rows: [["singularity_table_owner", "singularity_migration", true]]}} <-
                    query(
                      repo,
                      "SELECT current_user,session_user,pg_has_role(session_user,'singularity_table_owner','SET')",
                      []
                    ),
                  {:ok, _} <-
                    query(repo, "SELECT set_config('singularity.vault_id',$1,true)", [
                      binding.vault_id
                    ]),
                  {:ok, summary} <- rebuild_locked(repo, binding) do
               summary
             else
               {:error, %Error{} = error} -> repo.rollback(public_error(error))
               _malformed -> repo.rollback(Error.new(:integrity_failure))
             end
           end,
           isolation: :repeatable_read,
           log: false,
           telemetry_event: nil
         ) do
      {:ok, %IntegrityAudit.SearchSummary{} = summary} -> {:ok, summary}
      {:error, %Error{} = error} -> {:error, public_error(error)}
      _failure -> unavailable()
    end
  end

  defp rebuild_locked(repo, binding) do
    owner = Ecto.UUID.dump!(binding.vault_id)

    with :ok <- validate_base_summary(IntegrityAudit.rebuild(repo, binding)),
         {:ok, resources} <- resource_ids(repo, owner),
         {:ok, %{num_rows: deleted}} when is_integer(deleted) and deleted >= 0 <-
           query(repo, "DELETE FROM content.search_entries WHERE vault_id=$1", [owner]),
         :ok <- reconcile_resources(repo, owner, resources),
         {:ok, assets} <- asset_rows(repo, owner),
         {:ok, knowledge} <- knowledge_rows(repo, owner) do
      evidence = %{assets: assets, knowledge: knowledge}

      {:ok,
       %IntegrityAudit.SearchSummary{
         projection: "postgres_metadata_v1",
         document_count: length(assets) + length(knowledge),
         result_sha256:
           :crypto.hash(
             :sha256,
             :erlang.term_to_binary(evidence, [:deterministic, {:minor_version, 2}])
           )
       }}
    else
      {:error, %Error{}} = error -> error
      _malformed -> integrity_failure()
    end
  end

  defp validate_base_summary(
         {:ok,
          %IntegrityAudit.SearchSummary{
            projection: "postgres_metadata_v1",
            document_count: count,
            result_sha256: <<_::binary-size(32)>>
          } = summary}
       )
       when is_integer(count) and count >= 0 and map_size(summary) == 4,
       do: :ok

  defp validate_base_summary({:error, %Error{}} = error), do: error
  defp validate_base_summary(_malformed), do: integrity_failure()

  defp resource_ids(repo, owner) do
    case query(
           repo,
           "SELECT id::text FROM content.resources WHERE vault_id=$1 AND kind IN ('note','document') ORDER BY id",
           [owner]
         ) do
      {:ok, %{rows: rows}} when is_list(rows) ->
        if Enum.all?(rows, fn
             [id] -> canonical_uuid?(id)
             _row -> false
           end),
           do: {:ok, Enum.map(rows, fn [id] -> id end)},
           else: integrity_failure()

      {:error, %Error{}} = error ->
        error

      _malformed ->
        integrity_failure()
    end
  end

  defp reconcile_resources(repo, owner, resources) do
    Enum.reduce_while(resources, :ok, fn resource, :ok ->
      case query(repo, "SELECT content.reconcile_search_resource_internal($1,$2)", [
             owner,
             Ecto.UUID.dump!(resource)
           ]) do
        {:ok, %{rows: [[count]]}}
        when is_integer(count) and count >= 0 and count <= @max_bigint ->
          {:cont, :ok}

        {:error, %Error{}} = error ->
          {:halt, error}

        _malformed ->
          {:halt, integrity_failure()}
      end
    end)
  end

  defp asset_rows(repo, owner) do
    rows(
      repo,
      """
      SELECT asset_id::text, resource_version_id::text, classification, state,
             detected_media_type, search_vector::text
      FROM content.asset_search_documents
      WHERE vault_id = $1
      ORDER BY asset_id
      """,
      owner,
      &asset_row?/1
    )
  end

  defp knowledge_rows(repo, owner) do
    rows(
      repo,
      """
      SELECT entry_id, kind, resource_id::text, resource_version_id::text,
             fragment_id, ordinal, title, body, locator,
             to_char(source_inserted_at AT TIME ZONE 'UTC',
                     'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'), search_vector::text
      FROM content.search_entries
      WHERE vault_id = $1
      ORDER BY kind COLLATE "C", resource_id, resource_version_id, ordinal,
               entry_id COLLATE "C"
      """,
      owner,
      &knowledge_row?/1
    )
  end

  defp rows(repo, statement, owner, validator) do
    case query(repo, statement, [owner]) do
      {:ok, %{rows: rows}} when is_list(rows) ->
        if Enum.all?(rows, validator), do: {:ok, rows}, else: integrity_failure()

      {:error, %Error{}} = error ->
        error

      _malformed ->
        integrity_failure()
    end
  end

  defp asset_row?([asset, version, classification, state, media_type, vector]) do
    canonical_uuid?(asset) and canonical_uuid?(version) and
      classification in ~w[private sensitive restricted] and is_binary(state) and
      (is_nil(media_type) or is_binary(media_type)) and is_binary(vector)
  end

  defp asset_row?(_row), do: false

  defp knowledge_row?([
         entry,
         kind,
         resource,
         version,
         fragment,
         ordinal,
         title,
         body,
         locator,
         time,
         vector
       ])
       when is_binary(entry) and is_integer(ordinal) and ordinal >= 0 and ordinal <= @max_bigint and
              is_binary(title) and is_binary(body) and is_map(locator) and is_binary(time) and
              is_binary(vector) do
    canonical_uuid?(resource) and canonical_uuid?(version) and
      Regex.match?(@utc_timestamp, time) and match?({:ok, _, 0}, DateTime.from_iso8601(time)) and
      case kind do
        "note" -> fragment == nil and ordinal == 0 and entry == "note:" <> version
        "document" -> is_binary(fragment) and entry == "document:" <> fragment
        _kind -> false
      end
  end

  defp knowledge_row?(_row), do: false

  defp valid_binding?(binding) do
    Enum.sort(Map.keys(binding)) == Enum.sort(@binding_keys) and
      canonical_uuid?(binding.manifest_id) and canonical_uuid?(binding.vault_id)
  end

  defp canonical_uuid?(value) when is_binary(value), do: Ecto.UUID.cast(value) == {:ok, value}
  defp canonical_uuid?(_value), do: false

  defp query(repo, statement, parameters) do
    case SQL.query(repo, statement, parameters) do
      {:ok, result} -> {:ok, result}
      _failure -> unavailable()
    end
  end

  defp public_error(%Error{code: code, retryable?: retryable?}),
    do: Error.new(code, retryable?: retryable?)

  defp invalid, do: {:error, Error.new(:invalid)}
  defp integrity_failure, do: {:error, Error.new(:integrity_failure)}
  defp unavailable, do: {:error, Error.new(:storage_unavailable, retryable?: true)}
end
