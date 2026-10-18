defmodule Singularity.Storage.Backup.KnowledgePreflight do
  @moduledoc """
  Transaction-local, authenticated V3 restore preflight. This module neither
  imports canonical rows nor publishes objects. Its temporary relations and
  unpublished ciphertext stages remain provisional until replay authenticates.
  """

  alias Singularity.Core.{DocumentFragment, Error, NoteAttachment, SourceLocator, Tag}

  alias Singularity.Storage.Backup.{
    BundleReader,
    KnowledgeRestoreDigest,
    LogicalRecordCodec,
    LogicalSchemaV3
  }

  alias Singularity.Storage.Backup.BundleReader.{Replay, Verified}
  alias Singularity.Storage.SafeSQL
  alias Singularity.Storage.Jobs.EnvelopeCodec

  @schemas LogicalSchemaV3.all()
  @by_table Map.new(@schemas, &{&1.table, &1})
  @bytes 16_777_216
  @savepoint "knowledge_preflight"
  # Immutable dependency order, deliberately separate from wire table order.
  @native_tables ~w[
    identity.people identity.accounts identity.credentials identity.principals
    core.capabilities core.vaults core.vault_members core.principal_capabilities
    identity.devices core.key_domains core.vault_key_versions core.vault_key_wrappers
    core.domain_key_versions core.domain_dedup_key_wrappers content.resources
    content.resource_versions content.asset_objects content.assets content.asset_key_envelopes
    content.asset_metadata content.resource_assets content.source_references content.tombstones
    audit.events core.outbox_events jobs.job_submissions jobs.job_progress jobs.effect_receipts
    content.note_versions content.note_conflicts content.document_versions
    content.document_fragments content.document_import_receipts content.tags
    content.resource_tags content.relationships content.note_attachments content.note_citations
  ]
  @types %{
    "uuid" => "uuid",
    "integer" => "bigint",
    "text" => "text COLLATE \"C\"",
    "bytes" => "bytea",
    "boolean" => "boolean",
    "timestamp" => "timestamptz(6)",
    "json" => "jsonb"
  }

  # These are immutable logical constraints, not destination-selected catalog
  # metadata. Foreign-key closure is checked only against the staged graph.
  @unique %{
    "identity.credentials" => [["normalized_login"]],
    "core.capabilities" => [["name"]],
    "core.vault_key_versions" => [["vault_id", "generation"]],
    "core.domain_key_versions" => [["key_domain_id", "generation"]],
    "content.resource_versions" => [["resource_id", "revision"]],
    "content.asset_key_envelopes" => [["asset_object_id", "domain_key_version_id"]],
    "content.asset_metadata" => [["asset_id"]],
    "core.outbox_events" => [["sequence"], ["vault_id", "idempotency_key"]],
    "jobs.job_submissions" => [["outbox_event_id"], ["vault_id", "idempotency_key"]],
    "jobs.job_progress" => [["submission_id"]],
    "jobs.effect_receipts" => [["vault_id", "effect_key"]],
    "content.document_fragments" => [["resource_version_id", "ordinal"]],
    "content.note_attachments" => [
      ["note_resource_version_id", "ordinal"],
      ["note_resource_version_id", "target_resource_version_id", "role"]
    ],
    "content.note_citations" => [["note_resource_version_id", "ordinal"]],
    "content.tags" => [["vault_id", "normalized_key"]],
    "content.relationships" => [["vault_id", "source_resource_id", "target_resource_id", "type"]]
  }

  defmodule Staged do
    @moduledoc false
    @enforce_keys [
      :repo,
      :caller,
      :connection,
      :cut,
      :storage,
      :artifacts,
      :summary,
      :binding,
      :purpose
    ]
    defstruct @enforce_keys
  end

  defimpl Inspect, for: Staged do
    def inspect(_value, _options), do: "#KnowledgePreflight.Staged<REDACTED>"
  end

  @doc false
  def stage(repo, verified, cut, storage),
    do: stage_authenticated(repo, verified, cut, storage, :restore)

  @doc false
  def stage_for_verification(repo, verified, cut, storage),
    do: stage_authenticated(repo, verified, cut, storage, :verification)

  defp stage_authenticated(
         repo,
         %Verified{replay: %Replay{}, cut: cut} = verified,
         cut,
         storage,
         purpose
       )
       when is_map(cut) and is_map(storage) do
    ledger = {__MODULE__, make_ref()}

    try do
      connection = connection!(repo)
      require!(cut.logical_version == 3 and is_list(cut.object_inventory))
      require!(verified.manifest.manifest_id == cut.manifest_id)
      require!(verified.manifest.vault_ids == [cut.vault_id])

      require!(
        is_map(verified.authentication) and byte_size(verified.manifest_hash) == 32 and
          byte_size(verified.manifest_tag) == 16
      )

      require!(is_atom(storage.module) and is_map(storage.context))
      require!(is_nil(Map.get(storage, :observer)) or is_function(storage.observer, 2))
      require!(adapter!(storage, :list_staged, [storage.context]) == [])

      [[0]] =
        query!(
          repo,
          "SELECT count(*) FROM pg_class WHERE relnamespace=pg_my_temp_schema() AND relname LIKE 'knowledge_restore_%'"
        ).rows

      query!(repo, "SAVEPOINT " <> @savepoint)
      Process.put(ledger, [])

      try do
        create_tables!(repo)

        accumulator = %{
          repo: repo,
          storage: storage,
          purpose: purpose,
          ledger: ledger,
          cut: cut,
          current: nil,
          frames: 0,
          expected: nil,
          evidence: 0,
          objects: 0,
          batch: [],
          batch_table: nil,
          batch_bytes: 0,
          counts: Map.new(@schemas, &{&1.table, 0})
        }

        {:ok, replayed} = BundleReader.reduce_verified(verified, accumulator, &reduce_event/2)
        replayed = flush!(replayed)
        require!(replayed.current == nil and replayed.expected != nil)

        require!(
          replayed.objects == length(cut.object_inventory) and
            replayed.evidence == replayed.objects
        )

        require!(Enum.map(@schemas, &replayed.counts[&1.table]) == replayed.expected)
        semantics!(repo, cut)
        summary = digest!(repo)
        require!(summary.counts == replayed.counts)

        {:ok,
         %Staged{
           repo: repo,
           caller: self(),
           connection: connection,
           cut: cut,
           storage: storage,
           artifacts: Process.get(ledger),
           summary: summary,
           purpose: purpose,
           binding: authenticated_binding!(verified, storage, purpose)
         }}
      rescue
        _exception -> rollback!(repo, storage, Process.get(ledger, []))
      catch
        :throw, :knowledge_restore_missing_document_attempt_provenance ->
          rollback!(
            repo,
            storage,
            Process.get(ledger, []),
            {:error, Error.new(:integrity_failure)}
          )

        _kind, _reason ->
          rollback!(repo, storage, Process.get(ledger, []))
      after
        Process.delete(ledger)
      end
    rescue
      _exception -> invalid()
    catch
      _kind, _reason -> invalid()
    end
  end

  defp stage_authenticated(_repo, _verified, _cut, _storage, _purpose), do: invalid()

  @doc false
  def validate(repo, %Staged{} = staged, cut) do
    if staged.repo == repo and staged.caller == self() and
         safely(fn -> connection!(repo) end) == staged.connection do
      # Check the binding before entering the protected section. An SQL error
      # inside it aborts the transaction, so cleanup must not first issue another
      # identity query that would prevent rollback of that error.
      try do
        require_binding!(staged)
        require!(cut === staged.cut)
        semantics!(repo, cut)
        summary = digest!(repo)
        require!(summary == staged.summary)
        query!(repo, "RELEASE SAVEPOINT " <> @savepoint)
        {:ok, summary}
      rescue
        _exception -> rollback!(repo, staged.storage, staged.artifacts)
      catch
        :throw, :knowledge_restore_missing_document_attempt_provenance ->
          rollback!(
            repo,
            staged.storage,
            staged.artifacts,
            {:error, Error.new(:integrity_failure)}
          )

        _kind, _reason ->
          rollback!(repo, staged.storage, staged.artifacts)
      end
    else
      invalid()
    end
  end

  def validate(_repo, _staged, _cut), do: invalid()

  @doc false
  def begin_restore(repo, %Staged{} = staged) do
    if staged.purpose == :restore and same_connection?(repo, staged) do
      admission_savepoint(repo, "knowledge_restore_begin", fn ->
        require_binding!(staged)
        require_pending_marker!(repo, staged.binding)
        semantics!(repo, staged.cut)
        require!(digest!(repo) == staged.summary)

        expected =
          Enum.reduce(@schemas, %{counts: %{}, digests: %{}}, fn schema, acc ->
            {:ok, %{count: count, digest: digest}} =
              KnowledgeRestoreDigest.destination_table_digest(repo, schema.table)

            %{
              counts: Map.put(acc.counts, schema.table, count),
              digests: Map.put(acc.digests, schema.table, digest)
            }
          end)

        query!(
          repo,
          "SELECT audit.begin_knowledge_restore($1,$2,$3,$4::bigint[],$5::bytea[])",
          binding_parameters(staged.binding) ++
            [
              Enum.map(@schemas, &Map.fetch!(expected.counts, &1.table)),
              Enum.map(@schemas, &Map.fetch!(expected.digests, &1.table))
            ]
        )

        {:ok, expected}
      end)
    else
      invalid()
    end
  end

  def begin_restore(_repo, _staged), do: invalid()

  @doc false
  def validate_destination(repo, %Staged{} = staged) do
    if staged.purpose == :restore and same_connection?(repo, staged) do
      admission_savepoint(repo, "knowledge_restore_validate", fn ->
        require_binding!(staged)
        require_pending_marker!(repo, staged.binding)
        # Expected values are already immutable in the admission. The owned SQL
        # validator rechecks canonical rows independently, without installing or
        # consulting a caller-replaceable temporary JSON encoder.
        query!(
          repo,
          "SELECT audit.validate_knowledge_restore($1,$2,$3)",
          binding_parameters(staged.binding)
        )

        :ok
      end)
    else
      invalid()
    end
  end

  def validate_destination(_repo, _staged), do: invalid()

  @doc false
  def reduce_native_rows(repo, %Staged{} = staged, accumulator, callback)
      when is_function(callback, 3) do
    if same_connection?(repo, staged) do
      # validate/3 has already released the staging savepoint. This eager
      # iterator owns a different savepoint; no cursor can escape its binding.
      admission_savepoint(repo, "knowledge_restore_native_rows", fn ->
        require_binding!(staged)
        require!(digest!(repo) == staged.summary)

        result =
          Enum.reduce(@native_tables, accumulator, fn table, acc ->
            require!(same_connection?(repo, staged))
            schema = Map.fetch!(@by_table, table)

            projection =
              Enum.map_join(schema.columns, ",", fn column ->
                quote_name(column.name) <> if(column.tag == "json", do: "::text", else: "")
              end)

            ordering =
              names(Enum.map(schema.primary_key, &Enum.fetch!(schema.columns, &1.position).name))

            SafeSQL.stream(
              repo,
              "SELECT " <> projection <> " FROM " <> relation(table) <> " ORDER BY " <> ordering,
              [],
              max_rows: 1
            )
            |> Enum.reduce(acc, fn %{rows: rows}, state ->
              Enum.reduce(rows, state, fn values, current ->
                case callback.(schema, values, current) do
                  {:ok, next} -> next
                  {:error, %Error{} = error} -> throw({:native_callback_error, error})
                  _invalid -> throw(:invalid)
                end
              end)
            end)
          end)

        require!(same_connection?(repo, staged))
        require!(digest!(repo) == staged.summary)
        {:ok, result}
      end)
    else
      invalid()
    end
  end

  def reduce_native_rows(_repo, _staged, _accumulator, _callback), do: invalid()

  defp same_connection?(repo, staged),
    do:
      staged.repo == repo and staged.caller == self() and
        safely(fn -> connection!(repo) end) == staged.connection

  defp authenticated_binding!(verified, storage, purpose) do
    %{
      purpose: purpose,
      manifest_id: verified.manifest.manifest_id,
      vault_id: verified.cut.vault_id,
      manifest_hash: verified.manifest_hash,
      manifest_tag: verified.manifest_tag,
      inventory_hash: inventory_hash(verified.cut),
      destination_root_hash: destination_root_hash!(storage),
      object_count: length(verified.cut.object_inventory)
    }
  end

  defp require_binding!(staged) do
    require!(staged.purpose in [:restore, :verification])
    require!(staged.binding.purpose == staged.purpose)
    require!(staged.cut.logical_version == 3)
    require!(staged.binding.manifest_id == staged.cut.manifest_id)
    require!(staged.binding.vault_id == staged.cut.vault_id)
    require!(byte_size(staged.binding.manifest_hash) == 32)
    require!(byte_size(staged.binding.manifest_tag) == 16)
    require!(staged.binding.inventory_hash == inventory_hash(staged.cut))
    require!(staged.binding.destination_root_hash == destination_root_hash!(staged.storage))
    require!(staged.binding.object_count == length(staged.cut.object_inventory))
  end

  defp inventory_hash(cut),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(cut.object_inventory, [:deterministic]))

  defp destination_root_hash!(storage) do
    root = Map.fetch!(storage.context, :root)
    require!(is_binary(root) and root != "")
    :crypto.hash(:sha256, Path.expand(root))
  end

  defp binding_parameters(binding),
    do: [
      Ecto.UUID.dump!(binding.manifest_id),
      Ecto.UUID.dump!(binding.vault_id),
      binding.manifest_hash
    ]

  defp require_pending_marker!(repo, binding) do
    [[true]] =
      query!(
        repo,
        """
        SELECT EXISTS (
          SELECT 1 FROM audit.restore_import_sagas
          WHERE singleton AND state='pending'
            AND manifest_id=$1 AND vault_id=$2 AND manifest_hash=$3
            AND manifest_tag=$4 AND inventory_hash=$5 AND destination_root_hash=$6
            AND object_count=$7
          FOR UPDATE
        )
        """,
        binding_parameters(binding) ++
          [
            binding.manifest_tag,
            binding.inventory_hash,
            binding.destination_root_hash,
            binding.object_count
          ]
      ).rows
  end

  defp admission_savepoint(repo, name, fun) do
    try do
      query!(repo, "SAVEPOINT " <> name)

      try do
        result = fun.()
        query!(repo, "RELEASE SAVEPOINT " <> name)
        result
      rescue
        _exception -> rollback_admission!(repo, name)
      catch
        :throw, :knowledge_restore_missing_document_attempt_provenance ->
          rollback_admission!(repo, name, {:error, Error.new(:integrity_failure)})

        :throw, {:native_callback_error, %Error{} = error} ->
          rollback_admission!(repo, name, {:error, error})

        _kind, _reason ->
          rollback_admission!(repo, name)
      end
    rescue
      _exception -> invalid()
    catch
      _kind, _reason -> invalid()
    end
  end

  defp rollback_admission!(repo, name, error \\ invalid()) do
    rolled_back = safely(fn -> SafeSQL.query(repo, "ROLLBACK TO SAVEPOINT " <> name) end)
    released = safely(fn -> SafeSQL.query(repo, "RELEASE SAVEPOINT " <> name) end)

    if match?({:ok, _}, rolled_back) and match?({:ok, _}, released),
      do: error,
      else: {:error, Error.new(:storage_unavailable)}
  end

  defp connection!(repo) do
    require!(
      is_atom(repo) and function_exported?(repo, :in_transaction?, 0) and repo.in_transaction?()
    )

    [["singularity_migration", "singularity_table_owner", backend, transaction]] =
      query!(
        repo,
        "SELECT session_user::text,current_user::text,pg_backend_pid(),pg_current_xact_id()::text"
      ).rows

    {backend, transaction}
  end

  defp rollback!(repo, storage, artifacts, error \\ invalid()) do
    # The separate ledger survives a reader error that discards its accumulator.
    # Roll back first, including an aborted SQL statement, so the caller remains
    # queryable. Only handles created by this invocation may be aborted.
    rolled_back = safely(fn -> SafeSQL.query(repo, "ROLLBACK TO SAVEPOINT " <> @savepoint) end)
    released = safely(fn -> SafeSQL.query(repo, "RELEASE SAVEPOINT " <> @savepoint) end)

    aborted =
      Enum.map(artifacts, fn artifact ->
        safely(fn -> storage.module.abort_stage(artifact.context, artifact.stage_ref) end)
      end)

    if match?({:ok, _}, rolled_back) and match?({:ok, _}, released) and
         Enum.all?(aborted, &(&1 == :ok)),
       do: error,
       else: {:error, Error.new(:storage_unavailable)}
  end

  defp create_tables!(repo) do
    Enum.each(@schemas, fn schema ->
      columns =
        Enum.map(schema.columns, fn column ->
          quote_name(column.name) <>
            " " <>
            @types[column.tag] <>
            if(column.nullable?, do: "", else: " NOT NULL")
        end)

      primary = Enum.map(schema.primary_key, &Enum.fetch!(schema.columns, &1.position).name)

      constraints =
        ["PRIMARY KEY (" <> names(primary) <> ")"] ++
          Enum.map(Map.get(@unique, schema.table, []), &("UNIQUE (" <> names(&1) <> ")"))

      query!(
        repo,
        "CREATE TEMP TABLE " <>
          relation(schema.table) <>
          " (" <>
          Enum.join(columns ++ constraints, ",") <> ") ON COMMIT DROP"
      )
    end)

    query!(
      repo,
      "CREATE UNIQUE INDEX knowledge_restore_live_lookup ON " <>
        relation("content.asset_objects") <>
        " (vault_id,key_domain_id,lookup_digest) WHERE lifecycle<>'deleted'"
    )

    query!(
      repo,
      "CREATE UNIQUE INDEX knowledge_restore_active_vault_key ON " <>
        relation("core.vault_key_versions") <> " (vault_id) WHERE state='active'"
    )
  end

  defp reduce_event(event, accumulator) do
    {:ok, event!(event, accumulator)}
  rescue
    _exception -> invalid()
  catch
    _kind, _reason -> invalid()
  end

  defp event!({:record_start, type, size}, %{current: nil} = acc)
       when type in [1, 2, 3] and is_integer(size) and size >= 0 do
    require!(size <= if(type == 1, do: 65_536, else: @bytes))
    require!(acc.frames < 999_999)

    %{
      acc
      | frames: acc.frames + 1,
        current: %{type: type, size: size, remaining: size, chunks: []}
    }
  end

  defp event!({:record_start, 0x8000, size}, %{current: nil} = acc) do
    acc = flush!(acc)
    entry = Enum.fetch!(acc.cut.object_inventory, acc.objects)
    require!(size == entry.ciphertext_byte_size)
    require!(acc.frames < 999_999)

    current =
      if acc.purpose == :verification do
        %{type: 0x8000, remaining: size, entry: entry, hash: :crypto.hash_init(:sha256)}
      else
        context =
          Map.merge(acc.storage.context, %{
            ciphertext_hash: entry.ciphertext_hash,
            domain_namespace: entry.key_domain_id,
            vault_namespace: entry.vault_id,
            lookup_digest: Base.encode16(entry.lookup_digest, case: :lower)
          })

        stage_ref = adapter!(acc.storage, :stage, [context, %{stage_id: entry.asset_object_id}])
        artifact = %{context: context, stage_ref: stage_ref, entry: entry}
        Process.put(acc.ledger, [artifact | Process.get(acc.ledger)])
        %{type: 0x8000, remaining: size, artifact: artifact}
      end

    %{acc | frames: acc.frames + 1, current: current}
  end

  defp event!({:record_chunk, chunk}, %{current: current} = acc)
       when is_binary(chunk) and byte_size(chunk) > 0 do
    require!(byte_size(chunk) <= current.remaining)

    current =
      if current.type == 0x8000 do
        if acc.purpose == :verification do
          %{current | hash: :crypto.hash_update(current.hash, chunk)}
        else
          append!(acc.storage, current.artifact, chunk)
          current
        end
      else
        %{current | chunks: [chunk | current.chunks]}
      end

    %{acc | current: %{current | remaining: current.remaining - byte_size(chunk)}}
  end

  defp event!(
         :record_end,
         %{purpose: :verification, current: %{remaining: 0, type: 0x8000} = current} = acc
       ) do
    require!(:crypto.hash_final(current.hash) == current.entry.ciphertext_hash)
    %{acc | current: nil, objects: acc.objects + 1}
  end

  defp event!(:record_end, %{current: %{remaining: 0, type: 0x8000, artifact: artifact}} = acc) do
    sealed = adapter!(acc.storage, :seal_stage, [artifact.context, artifact.stage_ref, %{}])

    require!(
      sealed.sealed? and sealed.byte_size == artifact.entry.ciphertext_byte_size and
        sealed.ciphertext_hash == artifact.entry.ciphertext_hash
    )

    %{acc | current: nil, objects: acc.objects + 1}
  end

  defp event!(:record_end, %{current: %{remaining: 0} = current} = acc) do
    payload = current.chunks |> Enum.reverse() |> IO.iodata_to_binary()
    {:ok, %{logical_version: 3} = decoded} = LogicalRecordCodec.decode(current.type, payload)
    observe!(acc.storage, :metadata, %{bytes: current.size})
    acc = %{acc | current: nil}

    case current.type do
      1 ->
        require!(acc.expected == nil and decoded.object_count == length(acc.cut.object_inventory))

        Enum.each(
          [:manifest_id, :vault_id, :snapshot_id, :database_snapshot, :outbox_high_water_mark],
          fn key ->
            require!(Map.fetch!(decoded, key) == Map.fetch!(acc.cut, key))
          end
        )

        %{acc | expected: decoded.table_count_vector}

      2 ->
        require!(acc.expected != nil)
        batch!(acc, decoded, current.size)

      3 ->
        entry = Enum.fetch!(acc.cut.object_inventory, acc.evidence)
        require!(decoded.object_index == acc.evidence)
        require!(entry.inventory_position == decoded.object_index)
        require!(Atom.to_string(entry.classification) == decoded.classification)

        Enum.each(
          [
            :asset_object_id,
            :vault_id,
            :key_domain_id,
            :lookup_digest,
            :storage_ref,
            :ciphertext_byte_size,
            :ciphertext_hash
          ],
          fn key ->
            require!(Map.fetch!(decoded, key) == Map.fetch!(entry, key))
          end
        )

        %{flush!(acc) | evidence: acc.evidence + 1}
    end
  end

  defp event!(_event, _acc), do: throw(:invalid)

  defp append!(_storage, _artifact, <<>>), do: :ok

  defp append!(storage, artifact, bytes) do
    size = min(byte_size(bytes), 65_536)
    <<chunk::binary-size(size), rest::binary>> = bytes
    :ok = storage.module.append_encrypted_chunk(artifact.context, artifact.stage_ref, chunk)
    observe!(storage, :object_chunk, %{bytes: size})
    append!(storage, artifact, rest)
  end

  defp batch!(acc, decoded, bytes) do
    acc =
      if acc.batch_table != decoded.table or length(acc.batch) == 500 or
           acc.batch_bytes + bytes > @bytes,
         do: flush!(acc),
         else: acc

    values = Enum.map(decoded.ordered_column_values, &parameter/1)

    %{
      acc
      | batch_table: decoded.table,
        batch: [values | acc.batch],
        batch_bytes: acc.batch_bytes + bytes,
        counts: Map.update!(acc.counts, decoded.table, &(&1 + 1))
    }
  end

  defp flush!(%{batch: []} = acc), do: acc

  defp flush!(acc) do
    schema = Map.fetch!(@by_table, acc.batch_table)
    rows = Enum.reverse(acc.batch)
    width = length(schema.columns)

    placeholders =
      rows
      |> Enum.with_index()
      |> Enum.map_join(",", fn {_row, index} ->
        fields =
          schema.columns
          |> Enum.with_index(1)
          |> Enum.map_join(",", fn {column, position} ->
            placeholder = "$" <> Integer.to_string(index * width + position)
            if column.tag == "json", do: "(" <> placeholder <> "::text)::jsonb", else: placeholder
          end)

        "(" <> fields <> ")"
      end)

    query!(
      acc.repo,
      "INSERT INTO " <>
        relation(acc.batch_table) <>
        " (" <>
        names(Enum.map(schema.columns, & &1.name)) <> ") VALUES " <> placeholders,
      Enum.flat_map(rows, & &1)
    )

    observe!(acc.storage, :batch, %{rows: length(rows), bytes: acc.batch_bytes})
    %{acc | batch: [], batch_table: nil, batch_bytes: 0}
  end

  defp parameter({"null"}), do: nil
  defp parameter({"uuid", value}), do: Ecto.UUID.dump!(value)
  # The text cast preserves JSON null independently of SQL NULL, including
  # top-level arrays/scalars, and avoids flattening JSON array parameters.
  defp parameter({"json", value}), do: Jason.encode!(value)

  defp parameter({"timestamp", value}) do
    {:ok, datetime, 0} = DateTime.from_iso8601(value)
    datetime
  end

  defp parameter({_tag, value}), do: value

  defp observe!(storage, event, metrics) do
    if observer = Map.get(storage, :observer), do: observer.(event, metrics)
    :ok
  end

  defp adapter!(storage, function, arguments) do
    {:ok, value} = apply(storage.module, function, arguments)
    value
  end

  defp semantics!(repo, cut) do
    scope!(repo, cut)
    document_attempt_provenance!(repo)
    references!(repo)
    scalar_checks!(repo)
    ownership!(repo)
    notes!(repo)
    documents!(repo)
    sources!(repo)
    objects!(repo, cut.object_inventory)
    jobs!(repo, cut)
    streamed_values!(repo)
    :ok
  end

  defp document_attempt_provenance!(repo) do
    [[missing?]] =
      query!(
        repo,
        """
        SELECT EXISTS (
          SELECT 1 FROM #{relation("content.document_versions")} d
          WHERE d.state='extracting' AND d.attempt_job_id IS NOT NULL
            AND (NOT EXISTS (SELECT 1 FROM #{relation("core.outbox_events")} e
                  WHERE e.id=d.attempt_job_id)
              OR NOT EXISTS (SELECT 1 FROM #{relation("jobs.job_submissions")} s
                  WHERE s.outbox_event_id=d.attempt_job_id))
        )
        """
      ).rows

    case missing? do
      true -> throw(:knowledge_restore_missing_document_attempt_provenance)
      false -> :ok
    end
  end

  defp scope!(repo, cut) do
    Enum.each(@schemas, fn schema ->
      if Enum.any?(schema.columns, &(&1.name == "vault_id")) do
        absent!(
          repo,
          "SELECT 1 FROM " <>
            relation(schema.table) <>
            " WHERE vault_id IS NOT NULL AND vault_id <> $1",
          [Ecto.UUID.dump!(cut.vault_id)]
        )
      end

      if Enum.any?(schema.columns, &(&1.name == "classification")) do
        check!(repo, schema.table, "classification IN ('private','sensitive','restricted')")
      end
    end)

    [[1]] =
      query!(repo, "SELECT count(*) FROM " <> relation("core.vaults") <> " WHERE id=$1", [
        Ecto.UUID.dump!(cut.vault_id)
      ]).rows
  end

  # A nullable reference is absent only when its identifying column is NULL.
  # Every present reference checks its whole scope/classification identity.
  defp reference!(repo, from, keys, to, target_keys) do
    pairs = Enum.zip(keys, target_keys)

    joined =
      Enum.map_join(pairs, " AND ", fn {a, b} ->
        "s." <> quote_name(a) <> "=t." <> quote_name(b)
      end)

    absent!(
      repo,
      "SELECT 1 FROM " <>
        relation(from) <>
        " s WHERE s." <>
        quote_name(hd(keys)) <>
        " IS NOT NULL AND NOT EXISTS (SELECT 1 FROM " <>
        relation(to) <> " t WHERE " <> joined <> ")"
    )
  end

  defp references!(repo) do
    Enum.each(
      [
        {"identity.accounts", "person_id", "identity.people", "id"},
        {"identity.credentials", "account_id", "identity.accounts", "id"},
        {"identity.principals", "account_id", "identity.accounts", "id"},
        {"core.vaults", "object_cleanup_principal_id", "identity.principals", "id"},
        {"core.principal_capabilities", "capability_id", "core.capabilities", "id"},
        {"core.vault_key_wrappers", "account_id", "identity.accounts", "id"},
        {"audit.events", "principal_id", "identity.principals", "id"}
      ],
      fn {from, key, to, target} -> reference!(repo, from, [key], to, [target]) end
    )

    Enum.each(
      ["core.vault_members", "core.principal_capabilities", "identity.devices"],
      fn table ->
        reference!(repo, table, ["principal_id"], "identity.principals", ["id"])
      end
    )

    Enum.each(@schemas, fn schema ->
      if Enum.any?(schema.columns, &(&1.name == "vault_id")),
        do: reference!(repo, schema.table, ["vault_id"], "core.vaults", ["id"])
    end)

    for table <- [
          "core.principal_capabilities",
          "identity.devices",
          "content.source_references",
          "content.tombstones",
          "core.outbox_events",
          "content.document_import_receipts"
        ] do
      reference!(repo, table, ["principal_id", "vault_id"], "core.vault_members", [
        "principal_id",
        "vault_id"
      ])
    end

    for table <- [
          "content.note_versions",
          "content.document_versions",
          "content.tags",
          "content.relationships"
        ] do
      reference!(repo, table, ["created_by_principal_id", "vault_id"], "core.vault_members", [
        "principal_id",
        "vault_id"
      ])
    end

    for {from, key, to} <- [
          {"core.vault_key_wrappers", "vault_key_version_id", "core.vault_key_versions"},
          {"core.domain_key_versions", "vault_key_version_id", "core.vault_key_versions"},
          {"core.domain_key_versions", "key_domain_id", "core.key_domains"},
          {"core.domain_dedup_key_wrappers", "key_domain_id", "core.key_domains"},
          {"core.domain_dedup_key_wrappers", "domain_key_version_id", "core.domain_key_versions"},
          {"content.asset_key_envelopes", "domain_key_version_id", "core.domain_key_versions"},
          {"jobs.job_submissions", "outbox_event_id", "core.outbox_events"},
          {"jobs.job_progress", "submission_id", "jobs.job_submissions"},
          {"jobs.effect_receipts", "submission_id", "jobs.job_submissions"}
        ],
        do: reference!(repo, from, [key, "vault_id"], to, ["id", "vault_id"])

    for table <- ["jobs.job_progress", "jobs.effect_receipts"] do
      reference!(
        repo,
        table,
        ["submission_id", "vault_id", "classification"],
        "jobs.job_submissions",
        ["id", "vault_id", "classification"]
      )
    end

    for {from, key, to} <- [
          {"content.resource_versions", "resource_id", "content.resources"},
          {"content.asset_objects", "key_domain_id", "core.key_domains"},
          {"content.assets", "resource_version_id", "content.resource_versions"},
          {"content.assets", "asset_object_id", "content.asset_objects"},
          {"content.asset_key_envelopes", "asset_object_id", "content.asset_objects"},
          {"content.asset_key_envelopes", "key_domain_id", "core.key_domains"},
          {"content.asset_metadata", "asset_id", "content.assets"},
          {"content.asset_metadata", "resource_version_id", "content.resource_versions"},
          {"content.resource_assets", "asset_id", "content.assets"},
          {"content.resource_assets", "resource_version_id", "content.resource_versions"},
          {"content.source_references", "resource_version_id", "content.resource_versions"},
          {"content.tombstones", "asset_id", "content.assets"},
          {"content.document_versions", "source_asset_id", "content.assets"},
          {"content.document_versions", "source_resource_id", "content.resources"},
          {"content.document_versions", "source_resource_version_id",
           "content.resource_versions"},
          {"content.document_versions", "source_object_id", "content.asset_objects"},
          {"content.resource_tags", "resource_id", "content.resources"},
          {"content.resource_tags", "tag_id", "content.tags"},
          {"content.relationships", "source_resource_id", "content.resources"},
          {"content.relationships", "target_resource_id", "content.resources"}
        ],
        do:
          reference!(repo, from, [key, "vault_id", "classification"], to, [
            "id",
            "vault_id",
            "classification"
          ])

    for table <- ["content.note_versions", "content.document_versions"] do
      reference!(
        repo,
        table,
        ["resource_version_id", "resource_id", "vault_id", "classification"],
        "content.resource_versions",
        ["id", "resource_id", "vault_id", "classification"]
      )
    end

    for key <- ["parent_version_id", "merge_parent_version_id"] do
      reference!(
        repo,
        "content.note_versions",
        [key, "resource_id", "vault_id", "classification"],
        "content.note_versions",
        ["resource_version_id", "resource_id", "vault_id", "classification"]
      )
    end

    for key <- [
          "base_version_id",
          "canonical_version_id",
          "competing_version_id",
          "resolution_version_id"
        ] do
      reference!(
        repo,
        "content.note_conflicts",
        [key, "resource_id", "vault_id", "classification"],
        "content.note_versions",
        ["resource_version_id", "resource_id", "vault_id", "classification"]
      )
    end

    reference!(
      repo,
      "content.document_fragments",
      ["resource_version_id", "resource_id", "vault_id", "classification"],
      "content.document_versions",
      ["resource_version_id", "resource_id", "vault_id", "classification"]
    )

    reference!(
      repo,
      "content.document_import_receipts",
      ["version_id", "resource_id", "vault_id"],
      "content.document_versions",
      ["resource_version_id", "resource_id", "vault_id"]
    )

    for table <- ["content.note_attachments", "content.note_citations"] do
      reference!(
        repo,
        table,
        ["note_resource_version_id", "note_resource_id", "vault_id", "classification"],
        "content.note_versions",
        ["resource_version_id", "resource_id", "vault_id", "classification"]
      )
    end

    reference!(
      repo,
      "content.note_attachments",
      ["target_resource_version_id", "target_resource_id", "vault_id", "classification"],
      "content.resource_versions",
      ["id", "resource_id", "vault_id", "classification"]
    )

    reference!(
      repo,
      "content.note_citations",
      [
        "fragment_id",
        "source_resource_version_id",
        "source_resource_id",
        "vault_id",
        "classification"
      ],
      "content.document_fragments",
      ["id", "resource_version_id", "resource_id", "vault_id", "classification"]
    )

    reference!(
      repo,
      "content.relationships",
      ["target_resource_version_id", "target_resource_id", "vault_id", "classification"],
      "content.resource_versions",
      ["id", "resource_id", "vault_id", "classification"]
    )
  end

  defp scalar_checks!(repo) do
    for {table, predicate} <- [
          {"identity.accounts", "status IN ('active','disabled')"},
          {"identity.credentials",
           "normalized_login=lower(btrim(normalized_login)) AND normalized_login<>''"},
          {"identity.principals", "kind IN ('owner','system') AND authorization_epoch>=0"},
          {"core.vaults", "kind IN ('personal','system') AND authorization_epoch>=0"},
          {"core.capabilities", "btrim(name)<>''"},
          {"core.vault_members", "clearance IN ('private','sensitive','restricted')"},
          {"core.key_domains", "state IN ('active','retired')"},
          {"core.vault_key_versions",
           "generation>0 AND state IN ('pending','active','retired') AND algorithm IN ('aes_256_gcm','aes-256-gcm')"},
          {"core.vault_key_wrappers", "generation>0"},
          {"core.domain_key_versions",
           "generation>0 AND state IN ('pending','active','retired') AND algorithm='aes_256_gcm' AND octet_length(wrapped_key)>0"},
          {"core.domain_dedup_key_wrappers",
           "algorithm='aes_256_gcm' AND octet_length(wrapped_key)>0"},
          {"content.resources",
           "kind IN ('asset','note','document') AND btrim(title)<>'' AND (kind='asset' OR (classification='private' AND current_version_id IS NOT NULL))"},
          {"content.resource_versions", "revision>=0"},
          {"content.assets",
           "state IN ('staging','uploaded','verified','available','processing','ready','pending_delete','deleted') AND state_revision>=0 AND attempt>=0 AND ((failure_code IS NULL AND retryable IS NULL AND failed_operation IS NULL) OR (failure_code IS NOT NULL AND retryable IS NOT NULL AND failed_operation IS NOT NULL))"},
          {"content.asset_objects",
           "octet_length(lookup_digest)=32 AND octet_length(ciphertext_hash)=32 AND plaintext_byte_size>=0 AND ciphertext_byte_size>=0 AND format_version=1 AND lifecycle_revision>=0 AND lifecycle IN ('staged','available','pending_delete','orphan_pending','deleting','deleted')"},
          {"content.asset_objects",
           "((lifecycle='deleting' AND delete_claim_token IS NOT NULL AND delete_claimed_at IS NOT NULL) OR (lifecycle<>'deleting' AND delete_claim_token IS NULL AND delete_claimed_at IS NULL)) AND ((lifecycle IN ('orphan_pending','deleting') AND retained_until IS NOT NULL AND deleted_at IS NULL AND deletion_evidence IS NULL) OR (lifecycle='deleted' AND deleted_at IS NOT NULL AND jsonb_typeof(deletion_evidence)='object') OR (lifecycle NOT IN ('orphan_pending','deleting','deleted') AND deleted_at IS NULL AND deletion_evidence IS NULL))"},
          {"content.asset_key_envelopes",
           "algorithm='aes_256_gcm' AND key_generation>0 AND octet_length(wrapped_dek)>0"},
          {"content.asset_metadata",
           "projection_version>0 AND plaintext_byte_size>=0 AND extraction_state IN ('pending','completed','failed') AND ((image_width IS NULL AND image_height IS NULL) OR (image_width>0 AND image_height>0))"},
          {"content.source_references",
           "kind='browser_upload' AND byte_size>=0 AND octet_length(idempotency_key_digest)=32"},
          {"content.note_versions",
           "classification='private' AND btrim(title)<>'' AND octet_length(title)<=255 AND octet_length(markdown)<=1048576 AND (parent_version_id IS NOT NULL OR merge_parent_version_id IS NULL) AND (merge_parent_version_id IS NULL OR merge_parent_version_id<>parent_version_id)"},
          {"content.note_conflicts",
           "classification='private' AND base_version_id<>canonical_version_id AND base_version_id<>competing_version_id AND canonical_version_id<>competing_version_id AND ((state='open' AND resolution_version_id IS NULL AND resolved_at IS NULL) OR (state='resolved' AND resolution_version_id IS NOT NULL AND resolved_at IS NOT NULL AND resolution_version_id NOT IN (base_version_id,canonical_version_id,competing_version_id)))"},
          {"content.document_versions",
           "classification='private' AND octet_length(source_digest)=32 AND source_byte_size BETWEEN 0 AND 67108864 AND media_type IN ('application/pdf','text/plain','text/markdown') AND btrim(title)<>'' AND octet_length(title)<=255 AND attempt_generation>=0 AND (extraction_format IS NULL OR extraction_format>0) AND (extracted_text_digest IS NULL OR octet_length(extracted_text_digest)=32)"},
          {"content.document_versions",
           "(extraction_format IS NULL OR extraction_format=1) AND (extraction_adapter IS NULL OR (octet_length(extraction_adapter) BETWEEN 1 AND 255 AND content.document_trim_name(extraction_adapter)=extraction_adapter)) AND (detected_language IS NULL OR (octet_length(detected_language)<=255 AND content.document_trim_name(detected_language)<>'')) AND (failure_code IS NULL OR failure_code IN ('invalid_utf8','malformed_document','encrypted_document','no_extractable_text','input_too_large','output_too_large','page_limit','timeout','extractor_failed'))"},
          {"content.document_fragments",
           "classification='private' AND ordinal>=0 AND octet_length(text)<=65536 AND position(chr(13) in text)=0 AND octet_length(digest)=32"},
          {"content.document_import_receipts",
           "state='completed' AND resource_id IS NOT NULL AND version_id IS NOT NULL AND octet_length(request_fingerprint)=32"},
          {"content.note_attachments",
           "classification='private' AND ordinal>=0 AND role='source' AND target_kind IN ('asset','document','note') AND note_resource_id<>target_resource_id AND (label IS NULL OR octet_length(label)<=255)"},
          {"content.note_citations",
           "classification='private' AND ordinal>=0 AND note_resource_id<>source_resource_id"},
          {"content.tags", "classification='private'"},
          {"content.resource_tags", "classification='private'"},
          {"content.relationships",
           "classification='private' AND source_resource_id<>target_resource_id AND type IN ('related_to','references','derived_from')"},
          {"core.outbox_events",
           "sequence>=0 AND principal_authorization_epoch>=0 AND vault_authorization_epoch>=0 AND expected_entity_revision>=0 AND envelope_version=1 AND jsonb_typeof(payload)='object'"},
          {"jobs.job_submissions",
           "job_type IN ('asset_finalize','asset_verify','asset_metadata','asset_cleanup','object_cleanup','note_projection','document_extract','document_projection','backup')"},
          {"jobs.job_progress",
           "state IN ('pending','running','waiting_for_unlock','waiting_for_backup_key','completed','failed') AND processing_revision>=0 AND checkpoint_version>0 AND jsonb_typeof(checkpoint)='object'"},
          {"jobs.effect_receipts",
           "result IN ('applied','stale','failed') AND entity_revision>=0"}
        ],
        do: check!(repo, table, predicate)
  end

  defp ownership!(repo) do
    [[1, 1, 1, 1]] =
      query!(
        repo,
        "SELECT (SELECT count(*) FROM #{relation("identity.accounts")}), (SELECT count(*) FROM #{relation("identity.people")}), (SELECT count(*) FROM #{relation("core.vaults")}), (SELECT count(*) FROM #{relation("core.vault_key_wrappers")})"
      ).rows

    absent!(
      repo,
      "SELECT 1 FROM #{relation("identity.accounts")} a WHERE a.status<>'active' OR NOT EXISTS (SELECT 1 FROM #{relation("identity.credentials")} c WHERE c.account_id=a.id AND c.revoked_at IS NULL) OR NOT EXISTS (SELECT 1 FROM #{relation("identity.principals")} p JOIN #{relation("core.vault_members")} m ON m.principal_id=p.id WHERE p.account_id=a.id AND p.kind='owner' AND p.revoked_at IS NULL AND m.revoked_at IS NULL)"
    )

    absent!(
      repo,
      "SELECT 1 FROM #{relation("identity.principals")} p WHERE p.kind='owner' AND p.revoked_at IS NULL AND NOT EXISTS (SELECT 1 FROM #{relation("core.vault_members")} m WHERE m.principal_id=p.id AND m.revoked_at IS NULL)"
    )

    absent!(
      repo,
      "SELECT 1 FROM #{relation("core.vaults")} v WHERE NOT EXISTS (SELECT 1 FROM #{relation("core.vault_key_versions")} k JOIN #{relation("core.vault_key_wrappers")} w ON w.vault_key_version_id=k.id AND w.vault_id=k.vault_id AND w.generation=k.generation WHERE k.vault_id=v.id AND k.state='active')"
    )

    absent!(
      repo,
      "SELECT 1 FROM #{relation("core.vaults")} v WHERE v.object_cleanup_principal_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM #{relation("identity.principals")} p JOIN #{relation("core.vault_members")} m ON m.principal_id=p.id JOIN #{relation("core.principal_capabilities")} g ON g.principal_id=p.id AND g.vault_id=m.vault_id JOIN #{relation("core.capabilities")} c ON c.id=g.capability_id WHERE p.id=v.object_cleanup_principal_id AND p.kind='system' AND p.revoked_at IS NULL AND m.vault_id=v.id AND m.revoked_at IS NULL AND g.revoked_at IS NULL AND c.name='object.cleanup')"
    )

    absent!(
      repo,
      "SELECT 1 FROM #{relation("core.domain_dedup_key_wrappers")} w JOIN #{relation("core.domain_key_versions")} k ON k.id=w.domain_key_version_id WHERE k.key_domain_id<>w.key_domain_id"
    )

    absent!(
      repo,
      "SELECT 1 FROM #{relation("content.asset_key_envelopes")} e JOIN #{relation("core.domain_key_versions")} k ON k.id=e.domain_key_version_id JOIN #{relation("content.asset_objects")} o ON o.id=e.asset_object_id WHERE k.key_domain_id<>e.key_domain_id OR k.generation<>e.key_generation OR o.key_domain_id<>e.key_domain_id"
    )

    absent!(
      repo,
      "SELECT 1 FROM #{relation("core.vault_key_wrappers")} w JOIN #{relation("core.vault_key_versions")} k ON k.id=w.vault_key_version_id WHERE w.generation<>k.generation"
    )
  end

  defp notes!(repo) do
    for {kind, table} <- [
          {"note", "content.note_versions"},
          {"document", "content.document_versions"}
        ] do
      absent!(
        repo,
        "SELECT 1 FROM #{relation(table)} n JOIN #{relation("content.resources")} r ON r.id=n.resource_id WHERE r.kind<>'#{kind}'"
      )

      absent!(
        repo,
        "SELECT 1 FROM #{relation("content.resources")} r WHERE r.kind='#{kind}' AND NOT EXISTS (SELECT 1 FROM #{relation(table)} n WHERE n.resource_version_id=r.current_version_id AND n.resource_id=r.id AND n.vault_id=r.vault_id AND n.classification=r.classification)"
      )

      absent!(
        repo,
        "SELECT 1 FROM #{relation("content.resource_versions")} v JOIN #{relation("content.resources")} r ON r.id=v.resource_id WHERE r.kind='#{kind}' AND NOT EXISTS (SELECT 1 FROM #{relation(table)} n WHERE n.resource_version_id=v.id)"
      )
    end

    reference!(
      repo,
      "content.resources",
      ["current_version_id", "id", "vault_id", "classification"],
      "content.resource_versions",
      ["id", "resource_id", "vault_id", "classification"]
    )

    absent!(
      repo,
      "SELECT 1 FROM #{relation("content.note_versions")} n JOIN #{relation("content.resource_versions")} v ON v.id=n.resource_version_id WHERE (n.parent_version_id IS NULL) <> (v.revision=0)"
    )

    for key <- ["parent_version_id", "merge_parent_version_id"] do
      absent!(
        repo,
        "SELECT 1 FROM #{relation("content.note_versions")} n JOIN #{relation("content.resource_versions")} v ON v.id=n.resource_version_id JOIN #{relation("content.resource_versions")} p ON p.id=n.#{key} WHERE p.revision>=v.revision"
      )
    end

    absent!(
      repo,
      "SELECT 1 FROM #{relation("content.note_conflicts")} c JOIN #{relation("content.note_versions")} r ON r.resource_version_id=c.resolution_version_id WHERE r.parent_version_id IS DISTINCT FROM c.canonical_version_id OR r.merge_parent_version_id IS DISTINCT FROM c.competing_version_id"
    )

    absent!(
      repo,
      "SELECT 1 FROM #{relation("content.note_conflicts")} c JOIN #{relation("content.resource_versions")} b ON b.id=c.base_version_id JOIN #{relation("content.resource_versions")} a ON a.id=c.canonical_version_id JOIN #{relation("content.resource_versions")} p ON p.id=c.competing_version_id WHERE b.revision>=a.revision OR b.revision>=p.revision"
    )
  end

  defp documents!(repo) do
    check!(repo, "content.document_versions", """
    (state='pending' AND attempt_job_id IS NULL AND attempt_started_at IS NULL AND attempt_deadline_at IS NULL
      AND extraction_adapter IS NULL AND extraction_format IS NULL AND extracted_text_digest IS NULL
      AND detected_language IS NULL AND failure_code IS NULL AND attempt_finished_at IS NULL)
    OR (state IN ('extracting','ready','failed','unsupported') AND attempt_generation>0 AND attempt_job_id IS NOT NULL
      AND attempt_started_at IS NOT NULL AND attempt_deadline_at=attempt_started_at+interval '180 seconds'
      AND extraction_adapter IS NOT NULL AND extraction_format IS NOT NULL AND
      ((state='extracting' AND extracted_text_digest IS NULL AND detected_language IS NULL AND failure_code IS NULL AND attempt_finished_at IS NULL)
       OR (state='ready' AND extracted_text_digest IS NOT NULL AND failure_code IS NULL AND attempt_finished_at IS NOT NULL)
       OR (state IN ('failed','unsupported') AND extracted_text_digest IS NULL AND detected_language IS NULL AND failure_code IS NOT NULL AND attempt_finished_at IS NOT NULL)))
    """)

    absent!(
      repo,
      "SELECT 1 FROM #{relation("content.document_versions")} d JOIN #{relation("content.resource_versions")} v ON v.id=d.source_resource_version_id JOIN #{relation("content.resources")} r ON r.id=d.source_resource_id JOIN #{relation("content.assets")} a ON a.id=d.source_asset_id JOIN #{relation("content.asset_objects")} o ON o.id=d.source_object_id WHERE v.resource_id<>d.source_resource_id OR r.kind<>'asset' OR a.resource_version_id<>d.source_resource_version_id OR (a.asset_object_id IS NOT NULL AND a.asset_object_id<>o.id) OR d.source_byte_size<>o.plaintext_byte_size OR o.lifecycle<>'available' OR o.deleted_at IS NOT NULL OR NOT EXISTS (SELECT 1 FROM #{relation("content.resource_assets")} ra WHERE ra.resource_version_id=d.source_resource_version_id AND ra.asset_id=d.source_asset_id AND ra.vault_id=d.vault_id AND ra.classification=d.classification)"
    )

    absent!(
      repo,
      "SELECT 1 FROM #{relation("content.document_versions")} d WHERE (SELECT count(*) FROM #{relation("content.assets")} a WHERE a.resource_version_id=d.source_resource_version_id)<>1"
    )

    absent!(
      repo,
      "SELECT 1 FROM #{relation("content.document_versions")} GROUP BY source_object_id HAVING count(DISTINCT encode(source_digest,'hex'))<>1 OR count(DISTINCT source_byte_size)<>1"
    )

    absent!(
      repo,
      "SELECT 1 FROM #{relation("content.document_fragments")} f JOIN #{relation("content.document_versions")} d ON d.resource_version_id=f.resource_version_id WHERE d.state<>'ready'"
    )

    absent!(
      repo,
      "SELECT 1 FROM #{relation("content.document_versions")} d LEFT JOIN LATERAL (SELECT count(*) n,min(ordinal) lo,max(ordinal) hi,sum(octet_length(text)) bytes FROM #{relation("content.document_fragments")} f WHERE f.resource_version_id=d.resource_version_id) f ON true WHERE d.state='ready' AND (f.n NOT BETWEEN 1 AND 4096 OR f.lo<>0 OR f.hi<>f.n-1 OR f.bytes NOT BETWEEN 1 AND 16777216)"
    )
  end

  defp sources!(repo) do
    for table <- ["content.note_attachments", "content.note_citations"] do
      absent!(
        repo,
        "SELECT 1 FROM #{relation(table)} GROUP BY note_resource_version_id HAVING count(*)>100 OR min(ordinal)<>0 OR max(ordinal)<>count(*)-1"
      )
    end

    absent!(
      repo,
      "SELECT 1 FROM #{relation("content.note_attachments")} a JOIN #{relation("content.resources")} r ON r.id=a.target_resource_id WHERE r.kind<>a.target_kind"
    )

    absent!(
      repo,
      "SELECT 1 FROM #{relation("content.note_attachments")} a WHERE (a.target_kind='note' AND NOT EXISTS (SELECT 1 FROM #{relation("content.note_versions")} n WHERE n.resource_version_id=a.target_resource_version_id)) OR (a.target_kind='document' AND NOT EXISTS (SELECT 1 FROM #{relation("content.document_versions")} d WHERE d.resource_version_id=a.target_resource_version_id AND d.state='ready')) OR (a.target_kind='asset' AND (SELECT count(*) FROM #{relation("content.assets")} x JOIN #{relation("content.resource_assets")} ra ON ra.asset_id=x.id AND ra.resource_version_id=x.resource_version_id WHERE x.resource_version_id=a.target_resource_version_id)<>1)"
    )

    absent!(
      repo,
      "SELECT 1 FROM #{relation("content.note_citations")} c JOIN #{relation("content.document_fragments")} f ON f.id=c.fragment_id WHERE c.locator<>f.locator"
    )

    absent!(
      repo,
      "SELECT 1 FROM #{relation("content.relationships")} e JOIN #{relation("content.resources")} r ON r.id=e.target_resource_id WHERE r.kind='asset' AND e.target_resource_version_id IS NOT NULL AND (SELECT count(*) FROM #{relation("content.assets")} a JOIN #{relation("content.resource_assets")} ra ON ra.asset_id=a.id AND ra.resource_version_id=a.resource_version_id WHERE a.resource_version_id=e.target_resource_version_id)<>1"
    )

    # Asset-only historical endpoints may have lost their physical object, but
    # their immutable version/association identity must still be unambiguous.
    for table <- ["content.resource_tags", "content.relationships"],
        key <-
          if(table == "content.resource_tags",
            do: ["resource_id"],
            else: ["source_resource_id", "target_resource_id"]
          ) do
      absent!(
        repo,
        "SELECT 1 FROM #{relation(table)} x JOIN #{relation("content.resources")} r ON r.id=x.#{key} WHERE r.kind='asset' AND NOT EXISTS (SELECT 1 FROM #{relation("content.resource_versions")} v JOIN #{relation("content.assets")} a ON a.resource_version_id=v.id JOIN #{relation("content.resource_assets")} ra ON ra.asset_id=a.id AND ra.resource_version_id=v.id WHERE v.resource_id=r.id)"
      )
    end
  end

  defp objects!(repo, inventory) do
    required =
      "SELECT a.asset_object_id id FROM #{relation("content.assets")} a JOIN #{relation("content.asset_objects")} o ON o.id=a.asset_object_id WHERE a.state NOT IN ('pending_delete','deleted') AND o.lifecycle='available' UNION SELECT source_object_id FROM #{relation("content.document_versions")}"

    ids = Enum.map(inventory, &Ecto.UUID.dump!(&1.asset_object_id))
    [[count]] = query!(repo, "SELECT count(*) FROM (#{required}) required").rows
    require!(count == length(ids) and length(Enum.uniq(ids)) == count)

    for entry <- inventory do
      [[1]] =
        query!(repo, "SELECT count(*) FROM (#{required}) required WHERE id=$1", [
          Ecto.UUID.dump!(entry.asset_object_id)
        ]).rows

      [[1]] =
        query!(
          repo,
          "SELECT count(*) FROM #{relation("content.asset_objects")} WHERE id=$1 AND vault_id=$2 AND key_domain_id=$3 AND classification=$4 AND lookup_digest=$5 AND storage_ref=$6 AND ciphertext_byte_size=$7 AND ciphertext_hash=$8 AND lifecycle='available' AND deleted_at IS NULL",
          [
            Ecto.UUID.dump!(entry.asset_object_id),
            Ecto.UUID.dump!(entry.vault_id),
            Ecto.UUID.dump!(entry.key_domain_id),
            Atom.to_string(entry.classification),
            entry.lookup_digest,
            entry.storage_ref,
            entry.ciphertext_byte_size,
            entry.ciphertext_hash
          ]
        ).rows
    end

    absent!(
      repo,
      "SELECT 1 FROM #{relation("content.asset_objects")} o WHERE o.lifecycle='available' AND ((o.storage_ref<>o.id::text AND o.storage_ref<>'objects/'||o.vault_id::text||'/'||o.key_domain_id::text||'/hmac-sha256/'||substr(encode(o.lookup_digest,'hex'),1,2)||'/'||encode(o.lookup_digest,'hex')) OR NOT EXISTS (SELECT 1 FROM #{relation("content.asset_key_envelopes")} e WHERE e.asset_object_id=o.id))"
    )
  end

  defp jobs!(repo, cut) do
    absent!(repo, "SELECT 1 FROM #{relation("core.outbox_events")} WHERE sequence>$1", [
      cut.outbox_high_water_mark
    ])

    absent!(
      repo,
      "SELECT 1 FROM #{relation("jobs.job_submissions")} s JOIN #{relation("core.outbox_events")} e ON e.id=s.outbox_event_id WHERE s.idempotency_key<>e.idempotency_key OR s.classification<>e.classification OR (s.job_type='document_extract' AND e.event_type<>'document.extraction_requested') OR (e.event_type='document.extraction_requested' AND s.job_type<>'document_extract')"
    )

    absent!(
      repo,
      "SELECT 1 FROM #{relation("core.outbox_events")} e WHERE e.event_type='document.extraction_requested' AND (e.required_capability<>'asset.read' OR NOT EXISTS (SELECT 1 FROM #{relation("content.document_versions")} d WHERE e.payload=jsonb_build_object('resource_id',d.resource_id::text,'resource_version_id',d.resource_version_id::text) AND d.vault_id=e.vault_id AND d.classification=e.classification AND e.expected_entity_revision <= d.attempt_generation))"
    )

    absent!(
      repo,
      "SELECT 1 FROM #{relation("content.document_versions")} d WHERE d.state='extracting' AND NOT EXISTS (SELECT 1 FROM #{relation("core.outbox_events")} e JOIN #{relation("jobs.job_submissions")} s ON s.outbox_event_id=e.id WHERE e.id=d.attempt_job_id AND e.event_type='document.extraction_requested' AND e.vault_id=d.vault_id AND e.expected_entity_revision=d.attempt_generation-1 AND e.payload=jsonb_build_object('resource_id',d.resource_id::text,'resource_version_id',d.resource_version_id::text) AND s.job_type='document_extract')"
    )

    stream_rows!(repo, "core.outbox_events", fn row -> job!(repo, row) end)
  end

  defp job!(repo, row) do
    type = job_type!(row["event_type"])
    payload = row["payload"]

    envelope_payload =
      if type == "note_projection", do: Map.take(payload, ["resource_id"]), else: payload

    {:ok, _envelope} =
      EnvelopeCodec.decode(%{
        "version" => row["envelope_version"],
        "job_id" => uuid(row["id"]),
        "job_type" => type,
        "idempotency_key" => row["idempotency_key"],
        "vault_id" => uuid(row["vault_id"]),
        "principal_id" => uuid(row["principal_id"]),
        "required_capability" => row["required_capability"],
        "principal_authorization_epoch" => row["principal_authorization_epoch"],
        "vault_authorization_epoch" => row["vault_authorization_epoch"],
        "classification" => row["classification"],
        "correlation_id" => uuid(row["correlation_id"]),
        "causation_id" => uuid(row["causation_id"] || row["id"]),
        "expected_entity_revision" => row["expected_entity_revision"],
        "attempt" => 0,
        "payload" => envelope_payload
      })

    absent!(
      repo,
      "SELECT 1 FROM #{relation("jobs.job_submissions")} WHERE outbox_event_id=$1 AND job_type<>$2",
      [row["id"], type]
    )

    case type do
      "note_projection" ->
        conflict? = row["event_type"] in ["note.conflict_created", "note.conflict_resolved"]

        require!(
          Enum.sort(Map.keys(payload)) ==
            if(conflict?, do: ["conflict_id", "resource_id"], else: ["resource_id"])
        )

        [[1]] =
          query!(
            repo,
            "SELECT count(*) FROM #{relation("content.resources")} WHERE id=$1 AND vault_id=$2 AND classification=$3 AND kind='note'",
            [Ecto.UUID.dump!(payload["resource_id"]), row["vault_id"], row["classification"]]
          ).rows

        if conflict? do
          [[1]] =
            query!(
              repo,
              "SELECT count(*) FROM #{relation("content.note_conflicts")} WHERE id=$1 AND resource_id=$2 AND vault_id=$3",
              [
                Ecto.UUID.dump!(payload["conflict_id"]),
                Ecto.UUID.dump!(payload["resource_id"]),
                row["vault_id"]
              ]
            ).rows
        end

      type when type in ["document_extract", "document_projection"] ->
        [[1]] =
          query!(
            repo,
            "SELECT count(*) FROM #{relation("content.document_versions")} WHERE resource_version_id=$1 AND resource_id=$2 AND vault_id=$3 AND classification=$4",
            [
              Ecto.UUID.dump!(payload["resource_version_id"]),
              Ecto.UUID.dump!(payload["resource_id"]),
              row["vault_id"],
              row["classification"]
            ]
          ).rows

      type
      when type in [
             "asset_finalize",
             "asset_verify",
             "asset_metadata",
             "asset_cleanup",
             "object_cleanup"
           ] ->
        [[1]] =
          query!(
            repo,
            "SELECT count(*) FROM #{relation("content.assets")} WHERE id=$1 AND vault_id=$2 AND classification=$3",
            [Ecto.UUID.dump!(payload["asset_id"]), row["vault_id"], row["classification"]]
          ).rows

        if type == "object_cleanup" do
          [[1]] =
            query!(
              repo,
              "SELECT count(*) FROM #{relation("content.asset_objects")} WHERE id=$1 AND vault_id=$2 AND classification=$3",
              [Ecto.UUID.dump!(payload["object_id"]), row["vault_id"], row["classification"]]
            ).rows
        end

      "backup" ->
        :ok
    end
  end

  defp job_type!("asset.finalize_requested"), do: "asset_finalize"
  defp job_type!("asset.verify_requested"), do: "asset_verify"
  defp job_type!("asset.metadata_requested"), do: "asset_metadata"
  defp job_type!("asset.cleanup_requested"), do: "asset_cleanup"
  defp job_type!("object.cleanup_requested"), do: "object_cleanup"
  defp job_type!("backup.requested"), do: "backup"
  defp job_type!("document.extraction_requested"), do: "document_extract"

  defp job_type!(type) when type in ["document.ready", "document.deleted", "document.restored"],
    do: "document_projection"

  defp job_type!(type)
       when type in [
              "note.current_changed",
              "note.conflict_created",
              "note.conflict_resolved",
              "note.deleted",
              "note.restored"
            ],
       do: "note_projection"

  defp job_type!(_type), do: throw(:invalid)

  defp streamed_values!(repo) do
    stream_rows!(repo, "content.note_attachments", fn row ->
      kind =
        case row["target_kind"] do
          "asset" -> :asset
          "note" -> :note
          "document" -> :document
        end

      {:ok, attachment} =
        NoteAttachment.new(%{
          note_resource_id: uuid(row["note_resource_id"]),
          note_resource_version_id: uuid(row["note_resource_version_id"]),
          owner_scope_id: uuid(row["vault_id"]),
          attachment_id: uuid(row["id"]),
          target_resource_id: uuid(row["target_resource_id"]),
          target_resource_version_id: uuid(row["target_resource_version_id"]),
          classification: :private,
          target_kind: kind,
          ordinal: row["ordinal"],
          role: :source,
          label: row["label"]
        })

      require!(attachment.label == row["label"])
    end)

    stream_rows!(repo, "content.tags", fn row ->
      {:ok, tag} =
        Tag.new(%{
          tag_id: uuid(row["id"]),
          owner_scope_id: uuid(row["vault_id"]),
          classification: :private,
          display_value: row["display_value"],
          normalized_key: row["normalized_key"]
        })

      require!(tag.display_value == row["display_value"])
    end)

    stream_rows!(repo, "content.document_fragments", fn row ->
      {:ok, fragment} =
        DocumentFragment.new(%{
          resource_id: uuid(row["resource_id"]),
          resource_version_id: uuid(row["resource_version_id"]),
          owner_scope_id: uuid(row["vault_id"]),
          classification: :private,
          ordinal: row["ordinal"],
          text: row["text"],
          digest: row["digest"],
          locator: row["locator"],
          fragment_id: row["id"]
        })

      require!(SourceLocator.to_map(fragment.locator) == row["locator"])
    end)

    # One fragment at a time: never collect a whole Document or its text.
    statement =
      "SELECT d.resource_version_id,d.extracted_text_digest,d.media_type,f.ordinal,f.text,f.locator FROM #{relation("content.document_versions")} d JOIN #{relation("content.document_fragments")} f ON f.resource_version_id=d.resource_version_id ORDER BY d.resource_version_id,f.ordinal"

    state =
      SafeSQL.stream(repo, statement, [], max_rows: 1)
      |> Enum.reduce(nil, fn %{rows: rows}, state ->
        Enum.reduce(rows, state, fn [version, expected, media, ordinal, text, locator], state ->
          require!(locator["kind"] in ["fragment", locator_kind(media)])

          state =
            case state do
              %{version: ^version} ->
                state

              other ->
                finish_digest!(other)

                %{
                  version: version,
                  expected: expected,
                  hash: :crypto.hash_init(:sha256),
                  ordinal: 0
                }
            end

          require!(ordinal == state.ordinal)
          %{state | hash: :crypto.hash_update(state.hash, text), ordinal: ordinal + 1}
        end)
      end)

    finish_digest!(state)
  end

  defp finish_digest!(nil), do: :ok
  defp finish_digest!(state), do: require!(:crypto.hash_final(state.hash) == state.expected)
  defp locator_kind("application/pdf"), do: "pdf"
  defp locator_kind("text/plain"), do: "text"
  defp locator_kind("text/markdown"), do: "markdown"

  defp stream_rows!(repo, table, fun) do
    schema = Map.fetch!(@by_table, table)
    columns = Enum.map(schema.columns, & &1.name)

    SafeSQL.stream(repo, "SELECT " <> names(columns) <> " FROM " <> relation(table), [],
      max_rows: 1
    )
    |> Enum.each(fn %{rows: rows} -> Enum.each(rows, &fun.(Map.new(Enum.zip(columns, &1)))) end)
  end

  defp digest!(repo) do
    Enum.reduce(@schemas, %{counts: %{}, digests: %{}}, fn schema, acc ->
      {:ok, %{count: count, digest: digest}} =
        KnowledgeRestoreDigest.table_digest(repo, schema.table, :staged)

      %{
        counts: Map.put(acc.counts, schema.table, count),
        digests: Map.put(acc.digests, schema.table, digest)
      }
    end)
  end

  defp check!(repo, table, predicate),
    do:
      absent!(
        repo,
        "SELECT 1 FROM " <> relation(table) <> " WHERE (" <> predicate <> ") IS NOT TRUE"
      )

  defp absent!(repo, query, params \\ []) do
    [[false]] = query!(repo, "SELECT EXISTS (" <> query <> ")", params).rows
    :ok
  end

  defp query!(repo, sql, params \\ []) do
    {:ok, result} = SafeSQL.query(repo, sql, params)
    result
  end

  defp relation(table),
    do: "pg_temp.knowledge_restore_" <> Integer.to_string(Map.fetch!(@by_table, table).ordinal)

  defp names(columns), do: Enum.map_join(columns, ",", &quote_name/1)
  defp quote_name(name), do: "\"" <> name <> "\""
  defp uuid(value), do: Ecto.UUID.load!(value)

  defp safely(fun) do
    fun.()
  rescue
    _exception -> :error
  catch
    _kind, _reason -> :error
  end

  defp require!(true), do: :ok
  defp require!(_value), do: throw(:invalid)
  defp invalid, do: {:error, Error.new(:backup_invalid)}
end
