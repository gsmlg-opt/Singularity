defmodule Singularity.Storage.Backup.KnowledgeCanonicalOracle do
  @moduledoc false

  alias Singularity.Storage.{MigrationRepo, SafeSQL}

  # Independent, complete SQL inventory. No wire registry or restore digest
  # supplies the expected columns, scope predicates, normalization or ordering.
  @projection [
    {"identity.people", ~w(id display_name metadata inserted_at updated_at), ~w(id)},
    {"identity.accounts", ~w(id person_id status metadata inserted_at updated_at), ~w(id)},
    {"identity.credentials", ~w(id account_id normalized_login revoked_at inserted_at), ~w(id)},
    {"identity.principals",
     ~w(id account_id kind authorization_epoch revoked_at metadata inserted_at updated_at),
     ~w(id)},
    {"core.capabilities", ~w(id name inserted_at), ~w(id)},
    {"core.vaults",
     ~w(id kind authorization_epoch locked metadata inserted_at updated_at object_cleanup_principal_id),
     ~w(id)},
    {"core.vault_members", ~w(principal_id vault_id clearance revoked_at inserted_at updated_at),
     ~w(principal_id vault_id)},
    {"core.principal_capabilities",
     ~w(principal_id vault_id capability_id revoked_at inserted_at),
     ~w(principal_id vault_id capability_id)},
    {"identity.devices", ~w(id principal_id vault_id label revoked_at inserted_at updated_at),
     ~w(id)},
    {"core.key_domains", ~w(id vault_id classification kind state inserted_at updated_at),
     ~w(id)},
    {"core.vault_key_versions",
     ~w(id vault_id generation state algorithm activated_at retired_at inserted_at), ~w(id)},
    {"core.vault_key_wrappers",
     ~w(id vault_id vault_key_version_id account_id generation inserted_at), ~w(id)},
    {"core.domain_key_versions",
     ~w(id vault_id key_domain_id vault_key_version_id generation state algorithm wrapped_key inserted_at),
     ~w(id)},
    {"core.domain_dedup_key_wrappers",
     ~w(id vault_id key_domain_id domain_key_version_id algorithm wrapped_key inserted_at),
     ~w(id)},
    {"content.resources",
     ~w(id vault_id classification title deleted_at metadata inserted_at updated_at kind current_version_id),
     ~w(id)},
    {"content.resource_versions",
     ~w(id resource_id vault_id classification revision inserted_at updated_at), ~w(id)},
    {"content.asset_objects",
     ~w(id vault_id key_domain_id classification lookup_digest ciphertext_hash plaintext_byte_size ciphertext_byte_size storage_ref format_version lifecycle retained_until deleted_at deletion_evidence inserted_at updated_at lifecycle_revision delete_claim_token delete_claimed_at),
     ~w(id)},
    {"content.assets",
     ~w(id vault_id resource_version_id asset_object_id classification state state_revision failure_code retryable failed_operation attempt inserted_at updated_at),
     ~w(id)},
    {"content.asset_key_envelopes",
     ~w(id vault_id asset_object_id domain_key_version_id key_domain_id classification algorithm key_generation wrapped_dek inserted_at),
     ~w(id)},
    {"content.asset_metadata",
     ~w(id asset_id resource_version_id vault_id classification projection_version original_filename declared_media_type detected_media_type plaintext_byte_size pdf_header_version image_width image_height extraction_state extractor_version completed_at inserted_at updated_at),
     ~w(id)},
    {"content.resource_assets",
     ~w(resource_version_id asset_id vault_id classification released_at inserted_at),
     ~w(resource_version_id asset_id)},
    {"content.source_references",
     ~w(id vault_id resource_version_id principal_id classification kind observed_at original_filename declared_media_type byte_size idempotency_key_digest inserted_at),
     ~w(id)},
    {"content.tombstones",
     ~w(id vault_id asset_id principal_id classification reason retention_metadata deleted_at),
     ~w(id)},
    {"audit.events",
     ~w(id vault_id actor_kind principal_id anonymous_fingerprint system_principal_name operation result classification correlation_id target_type target_id metadata occurred_at inserted_at),
     ~w(id)},
    {"core.outbox_events",
     ~w(id sequence event_type idempotency_key vault_id principal_id required_capability vault_authorization_epoch classification correlation_id causation_id expected_entity_revision envelope_version payload occurred_at claim_token claimed_until runner_job_id delivered_at inserted_at updated_at principal_authorization_epoch retired_at retirement_reason),
     ~w(id)},
    {"jobs.job_submissions",
     ~w(id vault_id outbox_event_id classification idempotency_key job_type runner_job_id inserted_at updated_at),
     ~w(id)},
    {"jobs.job_progress",
     ~w(id vault_id submission_id classification state processing_revision checkpoint_version checkpoint inserted_at updated_at),
     ~w(id)},
    {"jobs.effect_receipts",
     ~w(id vault_id submission_id classification effect_key result entity_revision inserted_at),
     ~w(id)},
    {"content.note_versions",
     ~w(resource_version_id resource_id vault_id classification title markdown created_by_principal_id parent_version_id merge_parent_version_id inserted_at),
     ~w(resource_version_id)},
    {"content.note_conflicts",
     ~w(id resource_id vault_id classification base_version_id canonical_version_id competing_version_id state resolution_version_id created_at resolved_at),
     ~w(id)},
    {"content.document_versions",
     ~w(resource_version_id resource_id vault_id classification source_asset_id source_resource_id source_resource_version_id source_object_id source_digest source_byte_size media_type title created_by_principal_id state attempt_generation extraction_adapter extraction_format extracted_text_digest detected_language failure_code attempt_finished_at inserted_at attempt_job_id attempt_started_at attempt_deadline_at),
     ~w(resource_version_id)},
    {"content.document_fragments",
     ~w(id resource_id resource_version_id vault_id classification ordinal text digest locator inserted_at),
     ~w(id)},
    {"content.document_import_receipts",
     ~w(vault_id principal_id mutation_id request_fingerprint state resource_id version_id inserted_at),
     ~w(vault_id principal_id mutation_id)},
    {"content.note_attachments",
     ~w(note_resource_version_id id note_resource_id vault_id classification target_resource_id target_resource_version_id target_kind ordinal role label inserted_at),
     ~w(note_resource_version_id id)},
    {"content.note_citations",
     ~w(note_resource_version_id id note_resource_id vault_id classification source_resource_id source_resource_version_id fragment_id locator ordinal inserted_at),
     ~w(note_resource_version_id id)},
    {"content.tags",
     ~w(id vault_id classification display_value normalized_key created_by_principal_id inserted_at),
     ~w(id)},
    {"content.resource_tags", ~w(resource_id tag_id vault_id classification inserted_at),
     ~w(resource_id tag_id vault_id)},
    {"content.relationships",
     ~w(id vault_id classification source_resource_id target_resource_id target_resource_version_id type created_by_principal_id inserted_at),
     ~w(id)}
  ]

  def projection, do: @projection

  def read_committed!(repo, owner, cut) do
    {:ok, result} =
      repo.transaction(fn ->
        SafeSQL.query!(repo, "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY", [])
        SafeSQL.query!(repo, "SET LOCAL ROLE singularity_table_owner", [])
        rows_on_connection(repo, owner, cut)
      end)

    result
  end

  # The worker's real repeatable-read transaction must remain open for this
  # synchronous observation. All owner-level reads use a separate connection.
  def capture_worker_cut!(worker, owner, cut) do
    connection = worker.get_dynamic_repo()

    %{rows: [[token, worker_backend, database, role]]} =
      SafeSQL.query!(
        connection,
        "SELECT pg_export_snapshot()::text,pg_backend_pid(),current_database(),current_user",
        []
      )

    true = is_binary(token) and Regex.match?(~r/\A[0-9A-Fa-f]+-[0-9A-Fa-f]+-[0-9]+\z/, token)

    {:ok, observation} =
      MigrationRepo.transaction(fn ->
        SafeSQL.query!(
          MigrationRepo,
          "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY",
          []
        )

        SafeSQL.query!(MigrationRepo, "SET TRANSACTION SNAPSHOT '#{token}'", [])

        %{rows: [[snapshot, observer_backend, ^database]]} =
          SafeSQL.query!(
            MigrationRepo,
            "SELECT txid_current_snapshot()::text,pg_backend_pid(),current_database()",
            []
          )

        true = snapshot == cut.database_snapshot
        true = observer_backend != worker_backend
        SafeSQL.query!(MigrationRepo, "SET LOCAL ROLE singularity_table_owner", [])

        %{
          rows: rows_on_connection(MigrationRepo, owner, cut),
          snapshot: snapshot,
          worker_backend: worker_backend,
          observer_backend: observer_backend,
          database: database,
          worker_role: role,
          cut: cut
        }
      end)

    %{rows: [[^role, ^worker_backend]]} =
      SafeSQL.query!(connection, "SELECT current_user,pg_backend_pid()", [])

    observation
  end

  # Compare complete normalized rows without exposing bodies, wrapped keys or
  # other user data in ExUnit's assertion rendering. Only table names escape.
  def commitments(rows) do
    Map.new(@projection, fn {table, columns, _pk} ->
      complete_rows =
        case Map.fetch(rows, table) do
          {:ok, complete_rows} -> complete_rows
          :error -> raise ArgumentError, "missing canonical table #{table}"
        end

      commitment =
        :crypto.hash(:sha256, :erlang.term_to_binary({columns, complete_rows}, [:deterministic]))

      {table, commitment}
    end)
  end

  def compare(left, right) do
    left = commitments(left)
    right = commitments(right)

    case for({table, _columns, _pk} <- @projection, left[table] != right[table], do: table) do
      [] -> :ok
      tables -> {:error, {:canonical_mismatch, tables}}
    end
  end

  def normalize_rows(table, %{columns: columns, rows: rows}) do
    Enum.map(rows, fn values ->
      columns
      |> Enum.zip(values)
      |> Map.new(fn {column, value} -> {column, normalize(table, column, value)} end)
    end)
  end

  defp rows_on_connection(repo, owner, cut) do
    Map.new(@projection, fn {table, columns, pk} ->
      {predicate, parameters} = scope(table, owner, cut)
      select = Enum.map_join(columns, ",", &("source." <> identifier(&1)))
      order = Enum.map_join(pk, ",", &("source." <> identifier(&1)))

      result =
        SafeSQL.query!(
          repo,
          "SELECT #{select} FROM #{table_name(table)} source WHERE #{predicate} ORDER BY #{order}",
          parameters
        )

      {table, normalize_rows(table, result)}
    end)
  end

  defp scope("identity.people", owner, _cut),
    do:
      {"source.id IN (SELECT person_id FROM identity.accounts WHERE id=$1)",
       [Ecto.UUID.dump!(owner.account_id)]}

  defp scope("identity.accounts", owner, _cut),
    do: {"source.id=$1", [Ecto.UUID.dump!(owner.account_id)]}

  defp scope("identity.credentials", owner, _cut),
    do: {"source.account_id=$1", [Ecto.UUID.dump!(owner.account_id)]}

  defp scope("identity.principals", owner, _cut),
    do:
      {"source.account_id=$1 AND EXISTS (SELECT 1 FROM core.vault_members m WHERE m.principal_id=source.id AND m.vault_id=$2)",
       [Ecto.UUID.dump!(owner.account_id), Ecto.UUID.dump!(owner.vault_id)]}

  defp scope("core.capabilities", owner, _cut),
    do:
      {"EXISTS (SELECT 1 FROM core.principal_capabilities a WHERE a.capability_id=source.id AND a.vault_id=$1)",
       [Ecto.UUID.dump!(owner.vault_id)]}

  defp scope("core.vaults", owner, _cut),
    do: {"source.id=$1", [Ecto.UUID.dump!(owner.vault_id)]}

  defp scope("core.vault_key_wrappers", owner, _cut),
    do:
      {"source.vault_id=$1 AND source.account_id=$2 AND EXISTS (SELECT 1 FROM core.vault_key_versions v WHERE v.id=source.vault_key_version_id AND v.vault_id=source.vault_id AND v.state='active')",
       [Ecto.UUID.dump!(owner.vault_id), Ecto.UUID.dump!(owner.account_id)]}

  defp scope("core.outbox_events", owner, cut),
    do:
      {"source.vault_id=$1 AND source.sequence<=$2",
       [Ecto.UUID.dump!(owner.vault_id), cut.outbox_high_water_mark]}

  defp scope(_table, owner, _cut),
    do: {"source.vault_id=$1", [Ecto.UUID.dump!(owner.vault_id)]}

  defp identifier(value), do: ~s("#{String.replace(value, "\"", "\"\"")}")
  defp table_name(value), do: value |> String.split(".") |> Enum.map_join(".", &identifier/1)

  defp normalize(_table, _column, %DateTime{} = value), do: DateTime.to_iso8601(value)
  defp normalize(_table, _column, %NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp normalize("content.document_fragments", "id", value), do: value
  defp normalize(_table, "fragment_id", value), do: value

  defp normalize(_table, column, <<_::128>> = value) do
    if column == "id" or String.ends_with?(column, "_id"),
      do: Ecto.UUID.load!(value),
      else: value
  end

  defp normalize(_table, _column, value), do: value
end
