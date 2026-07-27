defmodule Singularity.Storage.Backup.Restorer do
  @moduledoc "Imports an authenticated logical backup into a disposable empty destination."

  alias Ecto.Adapters.SQL
  alias Singularity.Core.Error
  alias Singularity.Core.ObjectRef
  alias Singularity.Core.StageRef
  alias Singularity.Storage.Backup.BundleReader
  alias Singularity.Storage.Backup.LogicalBundleVerifier
  alias Singularity.Storage.Backup.LogicalRecordCodec
  alias Singularity.Storage.Backup.LogicalSchema
  alias Singularity.Storage.Local.PathGuard

  defmodule Imported do
    @moduledoc "Least-privilege handoff from logical import to owner-key rewrap."

    @enforce_keys [
      :manifest,
      :manifest_hash,
      :manifest_tag,
      :cut,
      :object_inventory,
      :owner
    ]
    @derive {Inspect,
             only: [
               :manifest,
               :manifest_hash,
               :manifest_tag,
               :cut,
               :object_inventory,
               :owner
             ]}
    defstruct @enforce_keys

    @type owner_handoff :: %{
            account_id: Ecto.UUID.t(),
            active_credential_ids: [Ecto.UUID.t(), ...],
            all_credential_ids: [Ecto.UUID.t(), ...],
            owner_principal_ids: [Ecto.UUID.t(), ...],
            vault_key_generation: pos_integer(),
            vault_key_version_id: Ecto.UUID.t(),
            vault_key_wrapper_id: Ecto.UUID.t(),
            wrapper_generation: pos_integer()
          }

    @type t :: %__MODULE__{
            manifest: map(),
            manifest_hash: <<_::256>>,
            manifest_tag: <<_::128>>,
            cut: map(),
            object_inventory: [map()],
            owner: owner_handoff()
          }
  end

  defmodule Rewrapped do
    @moduledoc "Redacted handoff from owner rewrap to restore integrity verification."

    @enforce_keys [
      :manifest,
      :manifest_hash,
      :manifest_tag,
      :cut,
      :object_inventory,
      :owner,
      :integrity_capability,
      :integrity_principal_id
    ]
    @derive {Inspect,
             only: [
               :manifest,
               :manifest_hash,
               :manifest_tag,
               :cut,
               :object_inventory,
               :owner,
               :integrity_principal_id
             ]}
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            manifest: map(),
            manifest_hash: <<_::256>>,
            manifest_tag: <<_::128>>,
            cut: map(),
            object_inventory: [map()],
            owner: Imported.owner_handoff(),
            integrity_capability: term(),
            integrity_principal_id: Ecto.UUID.t()
          }
  end

  @input_keys ~w[binding cut verified]a
  @cut_record_type 0x0001
  @row_record_type 0x0002
  @object_evidence_record_type 0x0003
  @raw_object_record_type 0x8000
  @append_chunk_bytes 65_536
  @restore_lock_key "singularity:restore-import:v1"
  @restore_lock_timeout_ms :timer.seconds(60)
  @restore_checkout_timeout_ms :timer.seconds(70)
  @default_integrity_ttl_ms :timer.minutes(15)
  @integrity_capability "integrity.audit"
  @integrity_principal_name "integrity_audit"
  @restore_pending "restore-pending"
  @relation_tables MapSet.new(~w[
    identity.people
    identity.accounts
    identity.credentials
    identity.principals
    core.vaults
    core.vault_members
    core.vault_key_versions
    core.vault_key_wrappers
    content.asset_objects
    content.assets
  ])
  @excluded_tables ~w[
    identity.sessions
    identity.auth_attempts
    content.asset_stages
    content.upload_grants
    content.asset_search_documents
    audit.backup_manifests
    audit.backup_manifest_objects
    jobs.oban_jobs
    jobs.oban_peers
  ]

  @spec import(map(), module(), map()) :: {:ok, Imported.t()} | {:error, Error.t()}
  def import(context, migration_repo, input)
      when is_map(context) and is_atom(migration_repo) and is_map(input) do
    with true <- exact_keys?(input, @input_keys),
         %BundleReader.Verified{} = verified <- input.verified,
         {:ok, authenticated_cut} <- authenticated_cut(verified, input.binding),
         true <- authenticated_cut == input.cut or backup_invalid() do
      import_verified(context, migration_repo, verified, authenticated_cut)
    else
      {:error, %Error{}} = error -> error
      _invalid -> backup_invalid()
    end
  end

  def import(_context, _migration_repo, _input), do: backup_invalid()

  defp authenticated_cut(
         %BundleReader.Verified{
           cut: %{manifest_id: manifest_id, vault_id: vault_id} = cut,
           manifest: %{manifest_id: manifest_id, recovery: recovery, vault_ids: [vault_id]},
           replay: %BundleReader.Replay{}
         },
         binding
       )
       when is_map(binding) do
    recovery_matches? =
      not Map.has_key?(binding, :recovery) or
        Map.get(binding, :recovery) == recovery

    if Map.get(binding, :manifest_id) == manifest_id and Map.get(binding, :vault_id) == vault_id and
         is_binary(Map.get(binding, :destination_ref)) and
         Map.get(binding, :destination_ref) != "" and recovery_matches? do
      {:ok, cut}
    else
      backup_invalid()
    end
  end

  defp authenticated_cut(%BundleReader.Verified{} = verified, binding),
    do: LogicalBundleVerifier.verify(verified, binding)

  @spec rewrap_owner(map(), Imported.t(), binary(), term()) ::
          {:ok, Rewrapped.t()} | {:error, Error.t()}
  def rewrap_owner(context, %Imported{} = imported, password, recovered_capability)
      when is_map(context) and is_binary(password) and byte_size(password) > 0 do
    with {:ok, adapters} <- rewrap_adapters(context) do
      try do
        with :ok <- validate_imported(imported) do
          rewrap_owner_with_adapters(adapters, imported, password, recovered_capability)
        end
      after
        revoke_capability(adapters.recovered_vault_key, recovered_capability)
      end
    end
  rescue
    _exception -> storage_unavailable()
  catch
    _kind, _reason -> storage_unavailable()
  end

  def rewrap_owner(_context, _imported, _password, _recovered_capability), do: invalid()

  @spec complete_restore(map(), Rewrapped.t()) :: :ok | {:error, Error.t()}
  def complete_restore(context, %Rewrapped{} = rewrapped) when is_map(context) do
    with :ok <- validate_rewrapped(rewrapped),
         migration_repo when is_atom(migration_repo) and not is_nil(migration_repo) <-
           Map.get(context, :migration_repo),
         {:ok, :completed} <- complete_restore_transaction(migration_repo, rewrapped) do
      :ok
    else
      {:error, %Error{}} = error -> error
      _invalid -> invalid()
    end
  rescue
    _exception -> storage_unavailable()
  catch
    _kind, _reason -> storage_unavailable()
  end

  def complete_restore(_context, _rewrapped), do: invalid()

  defp rewrap_owner_with_adapters(adapters, imported, password, recovered_capability) do
    with {:ok, verifier} <-
           adapter_value(adapters.password_hasher, :hash, [password], :invalid),
         true <- (is_binary(verifier) and verifier != "") or invalid(),
         {:ok, kdf_params} <- kdf_parameters(adapters.vault_kdf_params),
         {:ok, salt} <- random_salt(adapters.random_bytes),
         {:ok, <<_::binary-size(32)>> = kek} <-
           adapter_value(
             adapters.key_deriver,
             :derive,
             [password, salt, kdf_params],
             :invalid
           ) do
      rewrap_with_kek(
        adapters,
        imported,
        recovered_capability,
        verifier,
        salt,
        kdf_params,
        kek
      )
    else
      {:error, %Error{}} = error -> error
      _invalid -> invalid()
    end
  end

  defp rewrap_with_kek(
         adapters,
         imported,
         recovered_capability,
         verifier,
         salt,
         kdf_params,
         kek
       ) do
    generation = imported.owner.wrapper_generation + 1
    metadata = %{purpose: :vault_key, generation: generation, aad: imported.cut.vault_id}

    try do
      with {:ok, wrapper} <-
             adapter_value(
               adapters.recovered_vault_key,
               :rewrap,
               [
                 recovered_capability,
                 kek,
                 %{vault_id: imported.cut.vault_id, generation: generation}
               ],
               :backup_invalid
             ),
           {:ok, encoded_wrapper, wrapper_algorithm} <-
             validate_recovered_wrapper(wrapper, generation),
           {:ok, <<_::binary-size(32)>> = vault_key} <-
             adapter_value(
               adapters.key_wrapper,
               :unwrap,
               [kek, encoded_wrapper, metadata],
               :integrity_failure
             ) do
        issue_integrity_and_commit(
          adapters,
          imported,
          verifier,
          salt,
          kdf_params,
          generation,
          wrapper_algorithm,
          encoded_wrapper,
          vault_key
        )
      else
        {:error, %Error{}} = error -> error
        _invalid -> integrity_failure()
      end
    after
      _overwritten = overwrite(kek)
    end
  end

  defp issue_integrity_and_commit(
         adapters,
         imported,
         verifier,
         salt,
         kdf_params,
         generation,
         wrapper_algorithm,
         encoded_wrapper,
         vault_key
       ) do
    try do
      with {:ok, integrity_capability} <-
             adapter_value(
               adapters.integrity_issuer,
               :issue,
               [integrity_options(adapters, imported, vault_key)],
               :storage_unavailable
             ),
           true <- not is_nil(integrity_capability) or storage_unavailable() do
        commit_with_integrity_capability(
          adapters,
          imported,
          verifier,
          salt,
          kdf_params,
          generation,
          wrapper_algorithm,
          encoded_wrapper,
          integrity_capability
        )
      else
        {:error, %Error{}} = error -> error
        _invalid -> storage_unavailable()
      end
    after
      _overwritten = overwrite(vault_key)
    end
  end

  defp commit_with_integrity_capability(
         adapters,
         imported,
         verifier,
         salt,
         kdf_params,
         generation,
         wrapper_algorithm,
         encoded_wrapper,
         integrity_capability
       ) do
    case rewrap_transaction(
           adapters.migration_repo,
           imported,
           verifier,
           salt,
           kdf_params,
           generation,
           wrapper_algorithm,
           encoded_wrapper
         ) do
      {:ok, integrity_principal_id} ->
        {:ok,
         %Rewrapped{
           manifest: imported.manifest,
           manifest_hash: imported.manifest_hash,
           manifest_tag: imported.manifest_tag,
           cut: imported.cut,
           object_inventory: imported.object_inventory,
           owner: %{imported.owner | wrapper_generation: generation},
           integrity_capability: integrity_capability,
           integrity_principal_id: integrity_principal_id
         }}

      {:error, %Error{}} = error ->
        revoke_capability(adapters.integrity_issuer, integrity_capability)
        error
    end
  rescue
    _exception ->
      revoke_capability(adapters.integrity_issuer, integrity_capability)
      storage_unavailable()
  catch
    _kind, _reason ->
      revoke_capability(adapters.integrity_issuer, integrity_capability)
      storage_unavailable()
  end

  defp integrity_options(adapters, imported, vault_key) do
    %{
      owner: self(),
      vault_key: vault_key,
      binding: %{
        manifest_id: imported.manifest.manifest_id,
        vault_id: imported.cut.vault_id,
        vault_key_version_id: imported.owner.vault_key_version_id,
        vault_key_generation: imported.owner.vault_key_generation
      },
      inventory: imported.object_inventory,
      material_loader: {Singularity.Storage.Backup.IntegrityAudit, adapters.migration_repo},
      object_storage: adapters.object_storage,
      key_wrapper: adapter_module(adapters.key_wrapper),
      ttl_ms: adapters.integrity_ttl_ms
    }
  end

  defp import_verified(
         context,
         migration_repo,
         %BundleReader.Verified{replay: %BundleReader.Replay{}} = verified,
         cut
       ) do
    import_verified_streaming(context, migration_repo, verified, cut)
  end

  defp import_verified(context, migration_repo, verified, cut) do
    with {:ok, storage} <- object_storage(context),
         {:ok, decoded} <- decode_bundle(verified, cut),
         {:ok, owner} <- validate_relations(decoded.groups, cut),
         :ok <- validate_object_inventory(decoded.groups, cut.object_inventory),
         {:ok, marker} <- import_marker(storage, verified, cut) do
      with_restore_advisory_lock(migration_repo, fn ->
        with {:ok, state} <- prepare_import_marker(migration_repo, storage, marker) do
          continue_import(state, migration_repo, storage, verified, decoded, cut, owner, marker)
        end
      end)
    else
      {:error, %Error{}} = error -> error
      _invalid -> backup_invalid()
    end
  rescue
    _exception -> storage_unavailable()
  catch
    _kind, _reason -> storage_unavailable()
  end

  defp import_verified_streaming(context, migration_repo, verified, cut) do
    with {:ok, storage} <- object_storage(context),
         {:ok, marker} <- import_marker(storage, verified, cut) do
      try do
        with_restore_advisory_lock(migration_repo, fn ->
          with {:ok, state} <- prepare_import_marker(migration_repo, storage, marker) do
            continue_stream_import(
              state,
              migration_repo,
              storage,
              verified,
              cut,
              marker
            )
          end
        end)
      after
        _ = BundleReader.discard_verified(verified)
      end
    else
      {:error, %Error{}} = error -> error
      _invalid -> backup_invalid()
    end
  rescue
    _exception -> storage_unavailable()
  catch
    _kind, _reason -> storage_unavailable()
  end

  defp continue_stream_import(:pending, repo, storage, verified, cut, marker) do
    with :ok <- require_pending_database(repo, marker),
         :ok <- rollback_inventory(storage, cut.object_inventory),
         :ok <- require_empty_storage(storage) do
      stream_pending_import(repo, storage, verified, cut, marker)
    end
  end

  defp continue_stream_import(:imported, repo, storage, verified, cut, marker) do
    stream_verify_imported(repo, storage, verified, cut, marker)
  end

  defp continue_stream_import(_state, _repo, _storage, _verified, _cut, _marker),
    do: conflict()

  defp stream_pending_import(repo, storage, verified, cut, marker) do
    result =
      transact(
        repo,
        fn ->
          with :ok <- assume_table_owner(repo),
               :ok <- verify_migration_authority(repo),
               :ok <- lock_restore_import_sagas(repo),
               :ok <- lock_destination_tables(repo),
               {:ok, state} <- load_import_marker(repo),
               :pending <- require_marker(state, marker),
               :ok <- require_empty_tables(repo),
               :ok <- verify_seed_rows(repo),
               {:ok, dummy_verifier} <- dummy_verifier(repo),
               accumulator <- stream_accumulator(:import, repo, storage, cut, dummy_verifier),
               {:ok, accumulator} <-
                 BundleReader.reduce_verified(verified, accumulator, &reduce_stream_event/2),
               {:ok, accumulator} <- finish_stream_accumulator(accumulator),
               :ok <- restore_cleanup_principal(repo, accumulator.groups, cut.vault_id),
               :ok <- verify_stream_counts(repo, accumulator.row_counts),
               :ok <- verify_owner_handoff(repo, accumulator.owner, cut.vault_id),
               :ok <- repair_outbox_sequence(repo, cut.outbox_high_water_mark),
               :ok <- require_excluded_tables_empty(repo),
               :ok <- publish_objects(storage, accumulator.staged),
               :ok <- mark_imported(repo, marker) do
            Process.put({__MODULE__, :stream_import_result}, accumulator)
            :imported
          else
            {:error, %Error{}} = error -> error
            _mismatch -> conflict()
          end
        end,
        isolation: :serializable
      )

    accumulator = Process.delete({__MODULE__, :stream_import_result})

    case result do
      {:ok, :imported} when is_map(accumulator) ->
        imported(verified, cut, accumulator.owner)

      {:error, %Error{}} = error ->
        finish_failed_stream_import(error, repo, storage, verified, cut, marker, accumulator)

      _invalid ->
        finish_failed_stream_import(
          storage_unavailable(),
          repo,
          storage,
          verified,
          cut,
          marker,
          accumulator
        )
    end
  end

  defp finish_failed_stream_import(error, repo, storage, verified, cut, marker, accumulator) do
    case current_marker_state(repo, marker) do
      {:ok, :imported} when is_map(accumulator) ->
        with :ok <- verify_stream_database_digest(repo, accumulator),
             :ok <- verify_no_staged_objects(storage),
             :ok <- verify_exact_published_inventory(storage, cut.object_inventory) do
          imported(verified, cut, accumulator.owner)
        end

      {:ok, :pending} ->
        with :ok <- require_pending_database(repo, marker),
             :ok <- rollback_inventory(storage, cut.object_inventory) do
          error
        end

      {:ok, :imported} ->
        storage_unavailable()

      {:error, %Error{}} = marker_error ->
        marker_error
    end
  end

  defp stream_verify_imported(repo, storage, verified, cut, marker) do
    case transact(
           repo,
           fn ->
             with :ok <- assume_table_owner(repo),
                  :ok <- verify_migration_authority(repo),
                  :ok <- lock_restore_import_sagas(repo),
                  :ok <- lock_destination_tables(repo),
                  {:ok, state} <- load_import_marker(repo),
                  :imported <- require_marker(state, marker),
                  {:ok, dummy_verifier} <- dummy_verifier(repo),
                  accumulator <- stream_accumulator(:verify, repo, storage, cut, dummy_verifier),
                  {:ok, accumulator} <-
                    BundleReader.reduce_verified(verified, accumulator, &reduce_stream_event/2),
                  {:ok, accumulator} <- finish_stream_accumulator(accumulator),
                  :ok <- verify_seed_rows(repo),
                  :ok <- verify_stream_database_digest(repo, accumulator),
                  :ok <- verify_owner_handoff(repo, accumulator.owner, cut.vault_id),
                  :ok <- require_excluded_tables_empty(repo) do
               accumulator
             else
               {:error, %Error{}} = error -> error
               _mismatch -> conflict()
             end
           end,
           isolation: :serializable
         ) do
      {:ok, accumulator} ->
        with :ok <- verify_no_staged_objects(storage),
             :ok <- verify_exact_published_inventory(storage, cut.object_inventory) do
          imported(verified, cut, accumulator.owner)
        end

      {:error, %Error{}} = error ->
        error

      _invalid ->
        storage_unavailable()
    end
  end

  defp stream_accumulator(mode, repo, storage, cut, dummy_verifier)
       when mode in [:import, :verify] do
    %{
      current: nil,
      cut: cut,
      cut_seen?: false,
      dummy_verifier: dummy_verifier,
      evidence_count: 0,
      groups: %{},
      mode: mode,
      raw_index: 0,
      repo: repo,
      row_counts: Map.new(LogicalSchema.all(), &{&1.table, 0}),
      staged: [],
      storage: storage,
      table_count_vector: nil
    }
  end

  defp reduce_stream_event(
         {:record_start, type, payload_length},
         %{current: nil} = accumulator
       )
       when type in [@cut_record_type, @row_record_type, @object_evidence_record_type] and
              is_integer(payload_length) and payload_length >= 0 do
    buffering? = type in [@cut_record_type, @row_record_type]

    {:ok,
     %{
       accumulator
       | current: %{
           buffering?: buffering?,
           chunks: [],
           payload_length: payload_length,
           remaining: payload_length,
           type: type
         }
     }}
  end

  defp reduce_stream_event(
         {:record_start, @raw_object_record_type, payload_length},
         %{current: nil, cut: %{object_inventory: inventory}, raw_index: raw_index} = accumulator
       )
       when is_integer(payload_length) and payload_length >= 0 do
    with entry when is_map(entry) <- Enum.at(inventory, raw_index),
         true <- payload_length == entry.ciphertext_byte_size,
         {:ok, artifact} <- maybe_begin_stream_stage(accumulator, entry) do
      {:ok,
       %{
         accumulator
         | current: %{
             artifact: artifact,
             buffering?: false,
             chunks: [],
             entry: entry,
             payload_length: payload_length,
             remaining: payload_length,
             type: @raw_object_record_type
           }
       }}
    else
      {:error, %Error{}} = error -> error
      _invalid -> backup_invalid()
    end
  end

  defp reduce_stream_event(
         {:record_chunk, chunk},
         %{current: %{remaining: remaining} = current} = accumulator
       )
       when is_binary(chunk) and chunk != "" and byte_size(chunk) <= remaining do
    with :ok <- maybe_append_stream_chunk(accumulator, current, chunk) do
      chunks = if current.buffering?, do: [chunk | current.chunks], else: current.chunks

      {:ok,
       %{
         accumulator
         | current: %{
             current
             | chunks: chunks,
               remaining: remaining - byte_size(chunk)
           }
       }}
    end
  end

  defp reduce_stream_event(:record_end, %{current: %{remaining: 0} = current} = accumulator) do
    payload =
      if current.buffering?,
        do: current.chunks |> Enum.reverse() |> IO.iodata_to_binary(),
        else: nil

    with {:ok, accumulator} <- finish_stream_record(accumulator, current, payload) do
      {:ok, %{accumulator | current: nil}}
    end
  end

  defp reduce_stream_event(_event, _accumulator), do: backup_invalid()

  defp finish_stream_record(
         %{cut_seen?: false, cut: cut} = accumulator,
         %{type: @cut_record_type},
         payload
       ) do
    with {:ok, %{kind: :cut} = wire_cut} <-
           LogicalRecordCodec.decode(@cut_record_type, payload),
         true <- cut_matches?(wire_cut, cut) do
      {:ok,
       %{
         accumulator
         | cut_seen?: true,
           table_count_vector: wire_cut.table_count_vector
       }}
    else
      _invalid -> backup_invalid()
    end
  end

  defp finish_stream_record(
         %{cut_seen?: true} = accumulator,
         %{type: @row_record_type},
         payload
       ) do
    with {:ok, %{kind: :row, table: table, table_ordinal: ordinal} = wire_row} <-
           LogicalRecordCodec.decode(@row_record_type, payload),
         %{table: ^table, ordinal: ^ordinal} = schema <- Enum.at(LogicalSchema.all(), ordinal),
         row = %{schema: schema, values: wire_row.ordered_column_values},
         :ok <- apply_stream_row(accumulator, schema, row),
         {:ok, groups} <- add_relation_row(accumulator.groups, table, row) do
      {:ok,
       %{
         accumulator
         | groups: groups,
           row_counts: Map.update!(accumulator.row_counts, table, &(&1 + 1))
       }}
    else
      {:error, %Error{}} = error -> error
      _invalid -> backup_invalid()
    end
  end

  defp finish_stream_record(
         %{cut_seen?: true} = accumulator,
         %{type: @object_evidence_record_type},
         _payload
       ) do
    {:ok, %{accumulator | evidence_count: accumulator.evidence_count + 1}}
  end

  defp finish_stream_record(
         %{cut_seen?: true} = accumulator,
         %{artifact: artifact, entry: entry, type: @raw_object_record_type},
         _payload
       ) do
    with {:ok, artifact} <- maybe_finish_stream_stage(accumulator, artifact, entry) do
      staged = if accumulator.mode == :import, do: [artifact | accumulator.staged], else: []
      {:ok, %{accumulator | raw_index: accumulator.raw_index + 1, staged: staged}}
    end
  end

  defp finish_stream_record(_accumulator, _current, _payload), do: backup_invalid()

  defp apply_stream_row(%{mode: :import, repo: repo, dummy_verifier: verifier}, schema, row),
    do: insert_row(repo, schema, row, verifier)

  defp apply_stream_row(%{mode: :verify} = accumulator, schema, row),
    do: verify_stream_row(accumulator.repo, schema, row, accumulator.dummy_verifier)

  defp add_relation_row(groups, table, row) do
    if MapSet.member?(@relation_tables, table) do
      {:ok, Map.update(groups, table, [row], &[row | &1])}
    else
      {:ok, groups}
    end
  end

  defp maybe_begin_stream_stage(%{mode: :verify}, _entry), do: {:ok, nil}

  defp maybe_begin_stream_stage(%{mode: :import, storage: storage}, entry) do
    context = object_context(storage.context, entry)

    with {:ok, %StageRef{} = stage_ref} <-
           safe_adapter_call(storage.module, :stage, [context, %{stage_id: entry.asset_object_id}]),
         {:ok, %ObjectRef{} = object_ref} <- ObjectRef.new(object_id: entry.storage_ref) do
      {:ok,
       %{
         context: context,
         entry: entry,
         object_ref: object_ref,
         stage_ref: stage_ref
       }}
    else
      {:error, %Error{}} = error -> error
      _invalid -> storage_unavailable()
    end
  end

  defp maybe_append_stream_chunk(%{mode: :verify}, _current, _chunk), do: :ok

  defp maybe_append_stream_chunk(
         %{mode: :import, storage: %{module: module}},
         %{artifact: %{context: context, stage_ref: stage_ref}, type: @raw_object_record_type},
         chunk
       ),
       do: append_payload(module, context, stage_ref, chunk)

  defp maybe_append_stream_chunk(_accumulator, _current, _chunk), do: :ok

  defp maybe_finish_stream_stage(%{mode: :verify}, _artifact, _entry), do: {:ok, nil}

  defp maybe_finish_stream_stage(
         %{mode: :import, storage: %{module: module}},
         artifact,
         entry
       ) do
    with {:ok, sealed} <-
           safe_adapter_call(module, :seal_stage, [artifact.context, artifact.stage_ref, %{}]),
         :ok <- sealed_matches?(sealed, entry) do
      {:ok, artifact}
    end
  end

  defp finish_stream_accumulator(
         %{
           current: nil,
           cut: %{object_inventory: inventory} = cut,
           cut_seen?: true,
           evidence_count: evidence_count,
           groups: groups,
           raw_index: raw_count,
           row_counts: row_counts,
           table_count_vector: counts
         } = accumulator
       )
       when is_list(counts) do
    expected_counts =
      LogicalSchema.all()
      |> Enum.zip(counts)
      |> Map.new(fn {schema, count} -> {schema.table, count} end)

    with true <- length(counts) == length(LogicalSchema.all()),
         true <- row_counts == expected_counts,
         true <- evidence_count == length(inventory),
         true <- raw_count == length(inventory),
         {:ok, owner} <- validate_relations(groups, cut),
         :ok <- validate_object_inventory(groups, inventory) do
      {:ok, Map.put(accumulator, :owner, owner) |> Map.update!(:staged, &Enum.reverse/1)}
    else
      {:error, %Error{}} = error -> error
      _invalid -> backup_invalid()
    end
  end

  defp finish_stream_accumulator(_accumulator), do: backup_invalid()

  defp verify_stream_counts(repo, row_counts) do
    LogicalSchema.all()
    |> Enum.reduce_while(:ok, fn schema, :ok ->
      expected_count = Map.fetch!(row_counts, schema.table)

      case query(repo, "SELECT count(*) FROM #{quote_table(schema.table)}", []) do
        {:ok, %{rows: [[^expected_count]]}} -> {:cont, :ok}
        {:ok, _other} -> {:halt, conflict()}
        {:error, %Error{}} = error -> {:halt, error}
      end
    end)
  end

  defp verify_stream_database_digest(repo, accumulator),
    do: verify_stream_counts(repo, accumulator.row_counts)

  defp verify_stream_row(repo, schema, row, dummy_verifier) do
    {columns, tagged_values} = destination_row(schema, row, dummy_verifier)
    primary_key_columns = Enum.map(schema.primary_key, &Enum.at(schema.columns, &1.position).name)
    primary_key_values = Enum.map(schema.primary_key, &Enum.at(row.values, &1.position))

    where =
      primary_key_columns
      |> Enum.with_index(1)
      |> Enum.map_join(" AND ", fn {column, position} ->
        "#{quote_identifier(column)} = $#{position}"
      end)

    statement =
      "SELECT #{Enum.map_join(columns, ", ", &quote_identifier/1)} " <>
        "FROM #{quote_table(schema.table)} WHERE #{where}"

    expected = Enum.map(tagged_values, &sql_value/1)
    parameters = Enum.map(primary_key_values, &sql_value/1)

    case query(repo, statement, parameters) do
      {:ok, %{rows: [actual]}} ->
        if canonical_row_hash(actual) == canonical_row_hash(expected),
          do: :ok,
          else: conflict()

      {:ok, _other} ->
        conflict()

      {:error, %Error{}} = error ->
        error
    end
  end

  defp destination_row(%{table: "identity.credentials"} = schema, row, dummy_verifier) do
    inserted_at = tagged_field(row, "inserted_at")

    {
      Enum.map(schema.columns, & &1.name) ++ ["verifier", "verifier_version", "updated_at"],
      row.values ++ [{"text", dummy_verifier}, {"integer", 1}, inserted_at]
    }
  end

  defp destination_row(%{table: "core.vaults"} = schema, row, _dummy_verifier) do
    values = replace_tagged_field(row.values, schema, "locked", {"boolean", true})
    {Enum.map(schema.columns, & &1.name), values}
  end

  defp destination_row(%{table: "core.vault_key_wrappers"} = schema, row, _dummy_verifier) do
    {
      Enum.map(schema.columns, & &1.name) ++
        ["kdf_version", "kdf_salt", "kdf_parameters", "wrapper_algorithm", "wrapped_key"],
      row.values ++
        [
          {"integer", 1},
          {"bytes", @restore_pending},
          {"json", %{"state" => "restore_pending", "version" => 1}},
          {"text", "restore_pending"},
          {"bytes", @restore_pending}
        ]
    }
  end

  defp destination_row(schema, row, _dummy_verifier),
    do: {Enum.map(schema.columns, & &1.name), row.values}

  defp canonical_row_hash(values),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(values, [:deterministic]))

  defp verify_exact_published_inventory(storage, inventory) do
    with :ok <- verify_published_inventory(storage, inventory),
         {:ok, expected_paths} <- expected_inventory_paths(storage.root, inventory),
         {:ok, actual_paths} <- regular_file_paths(storage.root),
         true <- MapSet.new(actual_paths) == MapSet.new(expected_paths) do
      :ok
    else
      {:error, %Error{}} = error -> error
      _mismatch -> conflict()
    end
  end

  defp expected_inventory_paths(root, inventory) do
    inventory
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, paths} ->
      lookup_digest = Base.encode16(entry.lookup_digest, case: :lower)

      with {:ok, object_path} <-
             PathGuard.object_path(root, entry.vault_id, entry.key_domain_id, lookup_digest),
           {:ok, %StageRef{} = stage_ref} <- StageRef.new(stage_id: entry.asset_object_id),
           {:ok, receipt_path} <- PathGuard.finalization_receipt_path(root, stage_ref.stage_id) do
        {:cont, {:ok, [Path.expand(receipt_path), Path.expand(object_path) | paths]}}
      else
        _invalid -> {:halt, backup_invalid()}
      end
    end)
  end

  defp regular_file_paths(root) do
    case File.lstat(root) do
      {:error, :enoent} -> {:ok, []}
      {:ok, %File.Stat{type: :directory}} -> regular_file_paths_in(root)
      {:ok, _other} -> conflict()
      {:error, _reason} -> storage_unavailable()
    end
  end

  defp regular_file_paths_in(directory) do
    case File.ls(directory) do
      {:ok, entries} ->
        entries
        |> Enum.sort()
        |> Enum.reduce_while({:ok, []}, fn entry, {:ok, paths} ->
          path = Path.join(directory, entry)

          case File.lstat(path) do
            {:ok, %File.Stat{type: :regular}} ->
              {:cont, {:ok, [Path.expand(path) | paths]}}

            {:ok, %File.Stat{type: :directory}} ->
              case regular_file_paths_in(path) do
                {:ok, nested} -> {:cont, {:ok, nested ++ paths}}
                {:error, %Error{}} = error -> {:halt, error}
              end

            {:ok, _other} ->
              {:halt, conflict()}

            {:error, _reason} ->
              {:halt, storage_unavailable()}
          end
        end)

      {:error, _reason} ->
        storage_unavailable()
    end
  end

  defp continue_import(
         :imported,
         repo,
         storage,
         verified,
         decoded,
         cut,
         owner,
         marker
       ) do
    verify_imported_destination(repo, storage, verified, decoded, cut, owner, marker)
  end

  defp continue_import(:pending, repo, storage, verified, decoded, cut, owner, marker) do
    with :ok <- require_pending_database(repo, marker),
         :ok <- rollback_inventory(storage, cut.object_inventory),
         :ok <- require_empty_storage(storage),
         {:ok, staged} <- stage_objects(storage, cut.object_inventory, decoded.raw_payloads),
         result <- import_transaction(repo, storage, staged, decoded, owner, cut, marker) do
      finish_import(result, repo, storage, staged, verified, decoded, cut, owner, marker)
    end
  end

  defp finish_import(
         {:ok, :imported},
         _repo,
         _storage,
         _staged,
         verified,
         _decoded,
         cut,
         owner,
         _marker
       ) do
    imported(verified, cut, owner)
  end

  defp finish_import(
         {:error, %Error{}} = error,
         repo,
         storage,
         staged,
         verified,
         decoded,
         cut,
         owner,
         marker
       ) do
    case current_marker_state(repo, marker) do
      {:ok, :imported} ->
        verify_imported_destination(repo, storage, verified, decoded, cut, owner, marker)

      {:ok, :pending} ->
        with :ok <- require_pending_database(repo, marker),
             :ok <- rollback_staged(storage, staged) do
          error
        end

      {:error, %Error{}} = marker_error ->
        marker_error
    end
  end

  defp finish_import(
         _invalid,
         repo,
         storage,
         staged,
         _verified,
         _decoded,
         _cut,
         _owner,
         marker
       ) do
    case current_marker_state(repo, marker) do
      {:ok, :pending} ->
        with :ok <- require_pending_database(repo, marker),
             :ok <- rollback_staged(storage, staged) do
          storage_unavailable()
        end

      {:ok, :imported} ->
        storage_unavailable()

      {:error, %Error{}} = error ->
        error
    end
  end

  defp imported(verified, cut, owner) do
    {:ok,
     %Imported{
       manifest: verified.manifest,
       manifest_hash: verified.manifest_hash,
       manifest_tag: verified.manifest_tag,
       cut: cut,
       object_inventory: cut.object_inventory,
       owner: owner
     }}
  end

  defp object_storage(%{object_storage: {module, %{root: root} = context}})
       when is_atom(module) and is_binary(root) and root != "" do
    callbacks = [
      stage: 2,
      append_encrypted_chunk: 3,
      seal_stage: 3,
      finalize: 3,
      abort_stage: 2,
      stat: 2,
      list_staged: 1
    ]

    if Code.ensure_loaded?(module) and
         Enum.all?(callbacks, fn {function, arity} ->
           function_exported?(module, function, arity)
         end) and
         (function_exported?(module, :rollback_finalize, 3) or
            function_exported?(module, :delete, 2)) do
      {:ok, %{context: context, module: module, root: root}}
    else
      invalid()
    end
  end

  defp object_storage(_context), do: invalid()

  defp import_marker(storage, verified, cut) do
    with %{manifest_id: manifest_id} <- verified.manifest,
         true <- canonical_uuid?(manifest_id),
         true <- manifest_id == cut.manifest_id,
         true <- canonical_uuid?(cut.vault_id),
         <<_::binary-size(32)>> = manifest_hash <- verified.manifest_hash,
         <<_::binary-size(16)>> = manifest_tag <- verified.manifest_tag,
         inventory when is_list(inventory) <- cut.object_inventory do
      {:ok,
       %{
         destination_root_hash: :crypto.hash(:sha256, Path.expand(storage.root)),
         inventory_hash: inventory_hash(inventory),
         manifest_hash: manifest_hash,
         manifest_id: manifest_id,
         manifest_tag: manifest_tag,
         object_count: length(inventory),
         vault_id: cut.vault_id
       }}
    else
      _invalid -> backup_invalid()
    end
  end

  defp inventory_hash(inventory) do
    inventory
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
  end

  defp prepare_import_marker(repo, storage, marker) do
    transact(
      repo,
      fn ->
        with :ok <- assume_table_owner(repo),
             :ok <- verify_migration_authority(repo),
             :ok <- lock_restore_import_sagas(repo) do
          case load_import_marker(repo) do
            {:ok, nil} -> create_pending_marker(repo, storage, marker)
            {:ok, state} -> require_marker(state, marker)
            {:error, %Error{}} = error -> error
          end
        end
      end,
      isolation: :serializable
    )
  end

  defp create_pending_marker(repo, storage, marker) do
    with :ok <- lock_destination_tables(repo),
         :ok <- require_empty_tables(repo),
         :ok <- verify_seed_rows(repo),
         :ok <- require_empty_storage(storage),
         {:ok, %{rows: [["pending"]]}} <-
           query(
             repo,
             """
             INSERT INTO audit.restore_import_sagas (
               singleton,
               manifest_id,
               vault_id,
               manifest_hash,
               manifest_tag,
               inventory_hash,
               destination_root_hash,
               object_count,
               state
             )
             VALUES (TRUE, $1, $2, $3, $4, $5, $6, $7, 'pending')
             RETURNING state
             """,
             marker_parameters(marker)
           ) do
      :pending
    else
      {:ok, _malformed} -> storage_unavailable()
      {:error, %Error{}} = error -> error
    end
  end

  defp current_marker_state(repo, marker) do
    case transact(
           repo,
           fn ->
             with :ok <- assume_table_owner(repo),
                  :ok <- verify_migration_authority(repo),
                  :ok <- lock_restore_import_sagas(repo),
                  {:ok, state} <- load_import_marker(repo) do
               require_marker(state, marker)
             end
           end,
           isolation: :serializable
         ) do
      {:ok, state} when state in [:pending, :imported] -> {:ok, state}
      {:error, %Error{}} = error -> error
      _invalid -> storage_unavailable()
    end
  end

  defp require_pending_database(repo, marker) do
    case transact(
           repo,
           fn ->
             with :ok <- assume_table_owner(repo),
                  :ok <- verify_migration_authority(repo),
                  :ok <- lock_restore_import_sagas(repo),
                  :ok <- lock_destination_tables(repo),
                  {:ok, state} <- load_import_marker(repo),
                  :pending <- require_marker(state, marker),
                  :ok <- require_empty_tables(repo),
                  :ok <- verify_seed_rows(repo) do
               :pending
             else
               {:error, %Error{}} = error -> error
               _mismatch -> conflict()
             end
           end,
           isolation: :serializable
         ) do
      {:ok, :pending} -> :ok
      {:error, %Error{}} = error -> error
      _invalid -> storage_unavailable()
    end
  end

  defp load_import_marker(repo) do
    case query(
           repo,
           """
           SELECT
             manifest_id,
             vault_id,
             manifest_hash,
             manifest_tag,
             inventory_hash,
             destination_root_hash,
             object_count,
             state
           FROM audit.restore_import_sagas
           WHERE singleton
           FOR UPDATE
           """,
           []
         ) do
      {:ok, %{rows: []}} ->
        {:ok, nil}

      {:ok,
       %{
         rows: [
           [
             manifest_id,
             vault_id,
             manifest_hash,
             manifest_tag,
             inventory_hash,
             destination_root_hash,
             object_count,
             state
           ]
         ]
       }}
      when state in ["pending", "imported"] ->
        {:ok,
         %{
           destination_root_hash: destination_root_hash,
           inventory_hash: inventory_hash,
           manifest_hash: manifest_hash,
           manifest_id: load_uuid(manifest_id),
           manifest_tag: manifest_tag,
           object_count: object_count,
           state: String.to_existing_atom(state),
           vault_id: load_uuid(vault_id)
         }}

      {:ok, _malformed} ->
        storage_unavailable()

      {:error, %Error{}} = error ->
        error
    end
  rescue
    _exception -> storage_unavailable()
  end

  defp require_marker(%{state: state} = stored, marker)
       when state in [:pending, :imported] do
    if stored.manifest_id == marker.manifest_id and
         stored.vault_id == marker.vault_id and
         stored.object_count == marker.object_count and
         secure_compare(stored.manifest_hash, marker.manifest_hash) and
         secure_compare(stored.manifest_tag, marker.manifest_tag) and
         secure_compare(stored.inventory_hash, marker.inventory_hash) and
         secure_compare(stored.destination_root_hash, marker.destination_root_hash) do
      state
    else
      conflict()
    end
  end

  defp require_marker(_stored, _marker), do: conflict()

  defp marker_parameters(marker) do
    [
      dump_uuid(marker.manifest_id),
      dump_uuid(marker.vault_id),
      marker.manifest_hash,
      marker.manifest_tag,
      marker.inventory_hash,
      marker.destination_root_hash,
      marker.object_count
    ]
  end

  defp lock_restore_import_sagas(repo) do
    query_ok(repo, "LOCK TABLE audit.restore_import_sagas IN ACCESS EXCLUSIVE MODE", [])
  end

  defp decode_bundle(
         %BundleReader.Verified{records: [cut_record | remaining]},
         cut
       ) do
    with %{type: @cut_record_type, payload: cut_payload} <- cut_record,
         {:ok, %{kind: :cut} = wire_cut} <-
           LogicalRecordCodec.decode(@cut_record_type, cut_payload),
         true <- cut_matches?(wire_cut, cut),
         {:ok, groups, remaining} <-
           decode_row_groups(remaining, wire_cut.table_count_vector),
         {:ok, remaining} <- drop_object_evidence(remaining, length(cut.object_inventory)),
         {:ok, raw_payloads} <- raw_payloads(remaining, length(cut.object_inventory)) do
      {:ok, %{groups: groups, raw_payloads: raw_payloads}}
    else
      _invalid -> backup_invalid()
    end
  end

  defp decode_bundle(_verified, _cut), do: backup_invalid()

  defp cut_matches?(wire_cut, cut) do
    wire_cut.database_snapshot == cut.database_snapshot and
      wire_cut.manifest_id == cut.manifest_id and
      wire_cut.outbox_high_water_mark == cut.outbox_high_water_mark and
      wire_cut.snapshot_id == cut.snapshot_id and
      wire_cut.vault_id == cut.vault_id and
      wire_cut.object_count == length(cut.object_inventory)
  end

  defp decode_row_groups(records, counts) do
    LogicalSchema.all()
    |> Enum.zip(counts)
    |> Enum.reduce_while({:ok, %{}, records}, fn {schema, count}, {:ok, groups, remaining} ->
      {table_records, tail} = Enum.split(remaining, count)

      result =
        with true <- length(table_records) == count,
             {:ok, rows} <- decode_table_rows(table_records, schema) do
          {:ok, Map.put(groups, schema.table, rows), tail}
        end

      case result do
        {:ok, next_groups, next_remaining} ->
          {:cont, {:ok, next_groups, next_remaining}}

        _invalid ->
          {:halt, backup_invalid()}
      end
    end)
  end

  defp decode_table_rows(records, schema) do
    records
    |> Enum.reduce_while({:ok, []}, fn
      %{type: @row_record_type, payload: payload}, {:ok, rows} ->
        case LogicalRecordCodec.decode(@row_record_type, payload) do
          {:ok, %{kind: :row, table: table, table_ordinal: ordinal} = row}
          when table == schema.table and ordinal == schema.ordinal ->
            {:cont, {:ok, [%{schema: schema, values: row.ordered_column_values} | rows]}}

          _invalid ->
            {:halt, backup_invalid()}
        end

      _record, _rows ->
        {:halt, backup_invalid()}
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      {:error, %Error{}} = error -> error
    end
  end

  defp drop_object_evidence(records, count) do
    {evidence, remaining} = Enum.split(records, count)

    if length(evidence) == count and
         Enum.all?(
           evidence,
           &match?(%{type: 0x0003, payload: payload} when is_binary(payload), &1)
         ) do
      {:ok, remaining}
    else
      backup_invalid()
    end
  end

  defp raw_payloads(records, count) when length(records) == count do
    records
    |> Enum.reduce_while({:ok, []}, fn
      %{type: @raw_object_record_type, payload: payload}, {:ok, payloads}
      when is_binary(payload) ->
        {:cont, {:ok, [payload | payloads]}}

      _record, _payloads ->
        {:halt, backup_invalid()}
    end)
    |> case do
      {:ok, payloads} -> {:ok, Enum.reverse(payloads)}
      {:error, %Error{}} = error -> error
    end
  end

  defp raw_payloads(_records, _count), do: backup_invalid()

  defp validate_relations(groups, cut) do
    with {:ok, person} <- exactly_one(groups, "identity.people"),
         {:ok, account} <- exactly_one(groups, "identity.accounts"),
         {:ok, vault} <- exactly_one(groups, "core.vaults"),
         {:ok, wrapper} <- exactly_one(groups, "core.vault_key_wrappers"),
         credentials when credentials != [] <- rows(groups, "identity.credentials"),
         principals when principals != [] <- rows(groups, "identity.principals"),
         memberships <- rows(groups, "core.vault_members"),
         versions <- rows(groups, "core.vault_key_versions"),
         person_id <- field(person, "id"),
         account_id <- field(account, "id"),
         true <- field(account, "person_id") == person_id,
         true <- field(vault, "id") == cut.vault_id,
         true <- Enum.all?(credentials, &(field(&1, "account_id") == account_id)),
         true <- Enum.all?(principals, &(field(&1, "account_id") == account_id)),
         active_credentials when active_credentials != [] <-
           Enum.filter(credentials, &is_nil(field(&1, "revoked_at"))),
         owner_principals when owner_principals != [] <-
           Enum.filter(principals, fn principal ->
             field(principal, "kind") == "owner" and is_nil(field(principal, "revoked_at"))
           end),
         true <- owner_members?(owner_principals, memberships, cut.vault_id),
         true <- cleanup_member?(vault, memberships, cut.vault_id),
         [active_version] <-
           Enum.filter(versions, fn version ->
             field(version, "vault_id") == cut.vault_id and field(version, "state") == "active"
           end),
         true <- field(wrapper, "vault_id") == cut.vault_id,
         true <- field(wrapper, "account_id") == account_id,
         true <- field(wrapper, "vault_key_version_id") == field(active_version, "id") do
      {:ok,
       %{
         account_id: account_id,
         active_credential_ids: sorted_ids(active_credentials),
         all_credential_ids: sorted_ids(credentials),
         owner_principal_ids: sorted_ids(owner_principals),
         vault_key_generation: field(active_version, "generation"),
         vault_key_version_id: field(active_version, "id"),
         vault_key_wrapper_id: field(wrapper, "id"),
         wrapper_generation: field(wrapper, "generation")
       }}
    else
      _invalid -> backup_invalid()
    end
  end

  defp exactly_one(groups, table) do
    case rows(groups, table) do
      [row] -> {:ok, row}
      _rows -> backup_invalid()
    end
  end

  defp rows(groups, table), do: Map.get(groups, table, [])

  defp owner_members?(owners, memberships, vault_id) do
    member_ids =
      memberships
      |> Enum.filter(&(field(&1, "vault_id") == vault_id and is_nil(field(&1, "revoked_at"))))
      |> MapSet.new(&field(&1, "principal_id"))

    Enum.all?(owners, &MapSet.member?(member_ids, field(&1, "id")))
  end

  defp cleanup_member?(vault, memberships, vault_id) do
    case field(vault, "object_cleanup_principal_id") do
      nil ->
        true

      cleanup_principal_id ->
        Enum.any?(memberships, fn membership ->
          field(membership, "principal_id") == cleanup_principal_id and
            field(membership, "vault_id") == vault_id and
            is_nil(field(membership, "revoked_at"))
        end)
    end
  end

  defp sorted_ids(rows), do: rows |> Enum.map(&field(&1, "id")) |> Enum.sort()

  defp validate_object_inventory(groups, inventory) do
    object_rows = rows(groups, "content.asset_objects")
    asset_rows = rows(groups, "content.assets")
    objects_by_id = Map.new(object_rows, &{field(&1, "id"), &1})

    expected_ids =
      asset_rows
      |> Enum.reject(&(field(&1, "state") in ["pending_delete", "deleted"]))
      |> Enum.map(&field(&1, "asset_object_id"))
      |> Enum.reject(&is_nil/1)
      |> Enum.filter(fn id ->
        case Map.fetch(objects_by_id, id) do
          {:ok, object} -> field(object, "lifecycle") == "available"
          :error -> false
        end
      end)
      |> MapSet.new()

    inventory_ids = MapSet.new(inventory, & &1.asset_object_id)

    with true <- MapSet.size(inventory_ids) == length(inventory),
         true <- inventory_ids == expected_ids,
         true <- Enum.all?(inventory, &inventory_matches_row?(&1, objects_by_id)) do
      :ok
    else
      _invalid -> backup_invalid()
    end
  end

  defp inventory_matches_row?(entry, objects_by_id) do
    case Map.fetch(objects_by_id, entry.asset_object_id) do
      {:ok, row} ->
        field(row, "id") == entry.asset_object_id and
          field(row, "vault_id") == entry.vault_id and
          field(row, "key_domain_id") == entry.key_domain_id and
          field(row, "classification") == Atom.to_string(entry.classification) and
          field(row, "lookup_digest") == entry.lookup_digest and
          field(row, "storage_ref") == entry.storage_ref and
          field(row, "ciphertext_byte_size") == entry.ciphertext_byte_size and
          field(row, "ciphertext_hash") == entry.ciphertext_hash and
          field(row, "lifecycle") == "available"

      :error ->
        false
    end
  end

  defp field(%{schema: schema, values: values}, name) do
    position = Enum.find_index(schema.columns, &(&1.name == name))
    values |> Enum.at(position) |> wire_value()
  end

  defp wire_value({"null"}), do: nil
  defp wire_value({_tag, value}), do: value

  defp require_empty_storage(%{module: module, context: context, root: root}) do
    with {:ok, []} <- safe_adapter_call(module, :list_staged, [context]),
         :ok <- empty_directory_tree(root) do
      :ok
    else
      {:ok, _stages} -> conflict()
      {:error, %Error{code: :not_found}} -> empty_directory_tree(root)
      {:error, %Error{}} = error -> error
      _invalid -> storage_unavailable()
    end
  end

  defp empty_directory_tree(root) do
    case File.lstat(root) do
      {:error, :enoent} -> :ok
      {:ok, %File.Stat{type: :directory}} -> empty_directory_entries(root)
      {:ok, _other} -> conflict()
      {:error, _reason} -> storage_unavailable()
    end
  end

  defp empty_directory_entries(directory) do
    case File.ls(directory) do
      {:ok, []} ->
        :ok

      {:ok, entries} ->
        Enum.reduce_while(entries, :ok, fn entry, :ok ->
          case empty_directory_tree(Path.join(directory, entry)) do
            :ok -> {:cont, :ok}
            {:error, %Error{}} = error -> {:halt, error}
          end
        end)

      {:error, _reason} ->
        storage_unavailable()
    end
  end

  defp import_transaction(repo, storage, staged, decoded, owner, cut, marker) do
    transact(
      repo,
      fn ->
        with :ok <- assume_table_owner(repo),
             :ok <- verify_migration_authority(repo),
             :ok <- lock_restore_import_sagas(repo),
             :ok <- lock_destination_tables(repo),
             {:ok, state} <- load_import_marker(repo),
             :pending <- require_marker(state, marker),
             :ok <- require_empty_tables(repo),
             :ok <- verify_seed_rows(repo),
             {:ok, dummy_verifier} <- dummy_verifier(repo),
             :ok <- insert_groups(repo, decoded.groups, dummy_verifier),
             :ok <- restore_cleanup_principal(repo, decoded.groups, cut.vault_id),
             :ok <- verify_inserted_counts(repo, decoded.groups),
             :ok <- verify_owner_handoff(repo, owner, cut.vault_id),
             :ok <- repair_outbox_sequence(repo, cut.outbox_high_water_mark),
             :ok <- require_excluded_tables_empty(repo),
             :ok <- publish_objects(storage, staged),
             :ok <- mark_imported(repo, marker) do
          :imported
        else
          {:error, %Error{}} = error -> error
          _mismatch -> conflict()
        end
      end,
      isolation: :serializable
    )
  end

  defp mark_imported(repo, marker) do
    case query(
           repo,
           """
           UPDATE audit.restore_import_sagas
           SET state = 'imported',
               imported_at = CURRENT_TIMESTAMP,
               updated_at = CURRENT_TIMESTAMP
           WHERE singleton
             AND state = 'pending'
             AND manifest_id = $1
             AND vault_id = $2
             AND manifest_hash = $3
             AND manifest_tag = $4
             AND inventory_hash = $5
             AND destination_root_hash = $6
             AND object_count = $7
           RETURNING state
           """,
           marker_parameters(marker)
         ) do
      {:ok, %{rows: [["imported"]]}} -> :ok
      {:ok, %{rows: []}} -> conflict()
      {:ok, _malformed} -> storage_unavailable()
      {:error, %Error{}} = error -> error
    end
  end

  defp rewrap_transaction(
         repo,
         imported,
         verifier,
         salt,
         kdf_params,
         generation,
         wrapper_algorithm,
         encoded_wrapper
       ) do
    case transact(
           repo,
           fn ->
             with :ok <- assume_table_owner(repo),
                  :ok <- verify_migration_authority(repo),
                  :ok <- lock_rewrap_tables(repo),
                  :ok <- verify_restore_pending_owner(repo, imported),
                  :ok <- update_active_credentials(repo, imported.owner, verifier),
                  :ok <-
                    replace_restore_pending_wrapper(
                      repo,
                      imported,
                      salt,
                      kdf_params,
                      generation,
                      wrapper_algorithm,
                      encoded_wrapper
                    ),
                  {:ok, integrity_principal_id} <-
                    ensure_integrity_principal(repo, imported),
                  :ok <-
                    insert_rewrap_audit(
                      repo,
                      imported,
                      integrity_principal_id,
                      generation
                    ) do
               integrity_principal_id
             end
           end,
           isolation: :serializable
         ) do
      {:ok, integrity_principal_id} when is_binary(integrity_principal_id) ->
        {:ok, integrity_principal_id}

      {:error, %Error{}} = error ->
        error
    end
  end

  defp complete_restore_transaction(repo, rewrapped) do
    transact(
      repo,
      fn ->
        with :ok <- assume_table_owner(repo),
             :ok <- verify_migration_authority(repo),
             :ok <- lock_completion_tables(repo),
             :ok <- verify_integrity_principal(repo, rewrapped),
             :ok <- insert_restore_completion(repo, rewrapped) do
          :completed
        end
      end,
      isolation: :serializable
    )
  end

  defp lock_rewrap_tables(repo) do
    query_ok(
      repo,
      """
      LOCK TABLE
        audit.events,
        core.capabilities,
        core.principal_capabilities,
        core.vault_key_versions,
        core.vault_key_wrappers,
        core.vault_members,
        core.vaults,
        identity.credentials,
        identity.principals
      IN SHARE ROW EXCLUSIVE MODE
      """,
      []
    )
  end

  defp lock_completion_tables(repo) do
    query_ok(
      repo,
      """
      LOCK TABLE
        audit.events,
        core.capabilities,
        core.principal_capabilities,
        core.vault_members,
        identity.principals
      IN SHARE ROW EXCLUSIVE MODE
      """,
      []
    )
  end

  defp verify_restore_pending_owner(repo, imported) do
    with :ok <- verify_pending_credentials(repo, imported.owner),
         :ok <- verify_owner_principals(repo, imported.owner),
         :ok <- verify_pending_wrapper(repo, imported) do
      :ok
    end
  end

  defp verify_pending_credentials(repo, owner) do
    case query(
           repo,
           """
           SELECT
             credential.id,
             credential.revoked_at IS NULL,
             credential.verifier = setting.dummy_verifier
           FROM identity.credentials AS credential
           CROSS JOIN identity.security_settings AS setting
           WHERE credential.account_id = $1
             AND setting.singleton
           ORDER BY credential.id
           """,
           [dump_uuid(owner.account_id)]
         ) do
      {:ok, %{rows: rows}} when is_list(rows) ->
        with {:ok, all_ids} <- load_uuid_column(rows, 0),
             true <- all_ids == owner.all_credential_ids,
             {:ok, active_ids} <-
               rows
               |> Enum.filter(fn [_id, active?, _dummy?] -> active? end)
               |> load_uuid_column(0),
             true <- active_ids == owner.active_credential_ids,
             true <- Enum.all?(rows, fn [_id, _active?, dummy?] -> dummy? end) do
          :ok
        else
          _invalid -> conflict()
        end

      {:ok, _malformed} ->
        storage_unavailable()

      {:error, %Error{}} = error ->
        error
    end
  end

  defp verify_owner_principals(repo, owner) do
    case query(
           repo,
           """
           SELECT id
           FROM identity.principals
           WHERE account_id = $1
             AND kind = 'owner'
             AND revoked_at IS NULL
           ORDER BY id
           """,
           [dump_uuid(owner.account_id)]
         ) do
      {:ok, %{rows: rows}} ->
        case load_uuid_column(rows, 0) do
          {:ok, ids} when ids == owner.owner_principal_ids -> :ok
          _mismatch -> conflict()
        end

      {:ok, _malformed} ->
        storage_unavailable()

      {:error, %Error{}} = error ->
        error
    end
  end

  defp verify_pending_wrapper(repo, imported) do
    owner = imported.owner

    case query(
           repo,
           """
           SELECT
             vault.locked,
             wrapper.id,
             wrapper.generation,
             wrapper.kdf_version,
             wrapper.kdf_salt,
             wrapper.kdf_parameters,
             wrapper.wrapper_algorithm,
             wrapper.wrapped_key,
             version.id,
             version.generation,
             version.state
           FROM core.vaults AS vault
           JOIN core.vault_key_wrappers AS wrapper
             ON wrapper.vault_id = vault.id
           JOIN core.vault_key_versions AS version
             ON version.id = wrapper.vault_key_version_id
            AND version.vault_id = wrapper.vault_id
           WHERE vault.id = $1
             AND wrapper.id = $2
             AND wrapper.account_id = $3
           """,
           [
             dump_uuid(imported.cut.vault_id),
             dump_uuid(owner.vault_key_wrapper_id),
             dump_uuid(owner.account_id)
           ]
         ) do
      {:ok,
       %{
         rows: [
           [
             true,
             wrapper_id,
             wrapper_generation,
             1,
             @restore_pending,
             %{"state" => "restore_pending", "version" => 1},
             "restore_pending",
             @restore_pending,
             version_id,
             vault_key_generation,
             "active"
           ]
         ]
       }} ->
        if load_uuid(wrapper_id) == owner.vault_key_wrapper_id and
             wrapper_generation == owner.wrapper_generation and
             load_uuid(version_id) == owner.vault_key_version_id and
             vault_key_generation == owner.vault_key_generation do
          :ok
        else
          conflict()
        end

      {:ok, _mismatch} ->
        conflict()

      {:error, %Error{}} = error ->
        error
    end
  end

  defp update_active_credentials(repo, owner, verifier) do
    case query(
           repo,
           """
           UPDATE identity.credentials
           SET verifier = $1,
               verifier_version = 1,
               updated_at = CURRENT_TIMESTAMP
           WHERE account_id = $2
             AND revoked_at IS NULL
           RETURNING id
           """,
           [verifier, dump_uuid(owner.account_id)]
         ) do
      {:ok, %{rows: rows}} ->
        case load_uuid_column(rows, 0) do
          {:ok, ids} ->
            if Enum.sort(ids) == owner.active_credential_ids, do: :ok, else: conflict()

          _malformed ->
            storage_unavailable()
        end

      {:ok, _malformed} ->
        storage_unavailable()

      {:error, %Error{}} = error ->
        error
    end
  end

  defp replace_restore_pending_wrapper(
         repo,
         imported,
         salt,
         kdf_params,
         generation,
         wrapper_algorithm,
         encoded_wrapper
       ) do
    owner = imported.owner

    case query(
           repo,
           """
           UPDATE core.vault_key_wrappers
           SET generation = $1,
               kdf_version = $2,
               kdf_salt = $3,
               kdf_parameters = $4,
               wrapper_algorithm = $5,
               wrapped_key = $6
           WHERE id = $7
             AND vault_id = $8
             AND vault_key_version_id = $9
             AND account_id = $10
             AND generation = $11
             AND kdf_version = 1
             AND kdf_salt = $12
             AND kdf_parameters = '{"state":"restore_pending","version":1}'::jsonb
             AND wrapper_algorithm = 'restore_pending'
             AND wrapped_key = $12
           RETURNING id
           """,
           [
             generation,
             kdf_params.version,
             salt,
             stringify_keys(kdf_params),
             wrapper_algorithm,
             encoded_wrapper,
             dump_uuid(owner.vault_key_wrapper_id),
             dump_uuid(imported.cut.vault_id),
             dump_uuid(owner.vault_key_version_id),
             dump_uuid(owner.account_id),
             owner.wrapper_generation,
             @restore_pending
           ]
         ) do
      {:ok, %{rows: [[wrapper_id]]}} ->
        if load_uuid(wrapper_id) == owner.vault_key_wrapper_id, do: :ok, else: conflict()

      {:ok, %{rows: []}} ->
        conflict()

      {:ok, _malformed} ->
        storage_unavailable()

      {:error, %Error{}} = error ->
        error
    end
  end

  defp ensure_integrity_principal(repo, imported) do
    with {:ok, principal_id} <-
           find_or_insert_integrity_principal(repo, imported.owner.account_id),
         :ok <- ensure_integrity_membership(repo, principal_id, imported.cut.vault_id),
         {:ok, capability_id} <- ensure_integrity_capability(repo),
         :ok <-
           ensure_integrity_assignment(
             repo,
             principal_id,
             imported.cut.vault_id,
             capability_id
           ) do
      {:ok, principal_id}
    end
  end

  defp find_or_insert_integrity_principal(repo, account_id) do
    case query(
           repo,
           """
           SELECT id
           FROM identity.principals
           WHERE account_id = $1
             AND kind = 'system'
             AND revoked_at IS NULL
             AND metadata ->> 'name' = $2
           ORDER BY id
           """,
           [dump_uuid(account_id), @integrity_principal_name]
         ) do
      {:ok, %{rows: []}} ->
        insert_integrity_principal(repo, account_id)

      {:ok, %{rows: [[principal_id]]}} ->
        {:ok, load_uuid(principal_id)}

      {:ok, %{rows: _duplicates}} ->
        conflict()

      {:error, %Error{}} = error ->
        error
    end
  end

  defp insert_integrity_principal(repo, account_id) do
    principal_id = Ecto.UUID.generate()

    case query(
           repo,
           """
           INSERT INTO identity.principals (
             id, account_id, kind, authorization_epoch, metadata
           )
           VALUES ($1, $2, 'system', 0, $3)
           RETURNING id
           """,
           [
             dump_uuid(principal_id),
             dump_uuid(account_id),
             %{"name" => @integrity_principal_name}
           ]
         ) do
      {:ok, %{rows: [[inserted_id]]}} -> {:ok, load_uuid(inserted_id)}
      {:ok, _malformed} -> storage_unavailable()
      {:error, %Error{}} = error -> error
    end
  end

  defp ensure_integrity_membership(repo, principal_id, vault_id) do
    case query(
           repo,
           """
           INSERT INTO core.vault_members (
             principal_id, vault_id, clearance, revoked_at, updated_at
           )
           VALUES ($1, $2, 'restricted', NULL, CURRENT_TIMESTAMP)
           ON CONFLICT (principal_id, vault_id)
           DO UPDATE SET
             clearance = 'restricted',
             revoked_at = NULL,
             updated_at = CURRENT_TIMESTAMP
           RETURNING principal_id
           """,
           [dump_uuid(principal_id), dump_uuid(vault_id)]
         ) do
      {:ok, %{rows: [[returned_id]]}} ->
        if load_uuid(returned_id) == principal_id do
          verify_integrity_membership_scope(repo, principal_id, vault_id)
        else
          storage_unavailable()
        end

      {:ok, _malformed} ->
        storage_unavailable()

      {:error, %Error{}} = error ->
        error
    end
  end

  defp verify_integrity_membership_scope(repo, principal_id, vault_id) do
    case query(
           repo,
           """
           SELECT vault_id
           FROM core.vault_members
           WHERE principal_id = $1
             AND revoked_at IS NULL
           ORDER BY vault_id
           """,
           [dump_uuid(principal_id)]
         ) do
      {:ok, %{rows: [[stored_vault_id]]}} ->
        if load_uuid(stored_vault_id) == vault_id, do: :ok, else: conflict()

      {:ok, _mismatch} ->
        conflict()

      {:error, %Error{}} = error ->
        error
    end
  end

  defp ensure_integrity_capability(repo) do
    capability_id = Ecto.UUID.generate()

    with {:ok, _result} <-
           query(
             repo,
             """
             INSERT INTO core.capabilities (id, name)
             VALUES ($1, $2)
             ON CONFLICT (name) DO NOTHING
             """,
             [dump_uuid(capability_id), @integrity_capability]
           ),
         {:ok, %{rows: [[stored_id]]}} <-
           query(repo, "SELECT id FROM core.capabilities WHERE name = $1", [
             @integrity_capability
           ]) do
      {:ok, load_uuid(stored_id)}
    else
      {:error, %Error{}} = error -> error
      _malformed -> storage_unavailable()
    end
  end

  defp ensure_integrity_assignment(repo, principal_id, vault_id, capability_id) do
    with {:ok, _result} <-
           query(
             repo,
             """
             INSERT INTO core.principal_capabilities (
               principal_id, vault_id, capability_id, revoked_at
             )
             VALUES ($1, $2, $3, NULL)
             ON CONFLICT (principal_id, vault_id, capability_id)
             DO UPDATE SET revoked_at = NULL
             """,
             [dump_uuid(principal_id), dump_uuid(vault_id), dump_uuid(capability_id)]
           ),
         {:ok, %{rows: rows}} <-
           query(
             repo,
             """
             SELECT capability.name
             FROM core.principal_capabilities AS assignment
             JOIN core.capabilities AS capability
               ON capability.id = assignment.capability_id
             WHERE assignment.principal_id = $1
               AND assignment.vault_id = $2
               AND assignment.revoked_at IS NULL
             ORDER BY capability.name
             """,
             [dump_uuid(principal_id), dump_uuid(vault_id)]
           ) do
      if rows == [[@integrity_capability]], do: :ok, else: conflict()
    else
      {:error, %Error{}} = error -> error
      _malformed -> storage_unavailable()
    end
  end

  defp insert_rewrap_audit(repo, imported, principal_id, generation) do
    event_id = Ecto.UUID.generate()
    correlation_id = Ecto.UUID.generate()
    now = DateTime.utc_now()

    case query(
           repo,
           """
           INSERT INTO audit.events (
             id, vault_id, actor_kind, principal_id, operation, result,
             classification, correlation_id, target_type, target_id, metadata,
             occurred_at, inserted_at
           )
           VALUES (
             $1, $2, 'system', $3, 'credential.rewrapped_after_restore', 'completed',
             'restricted', $4, 'backup_manifest', $5, $6, $7, $7
           )
           RETURNING id
           """,
           [
             dump_uuid(event_id),
             dump_uuid(imported.cut.vault_id),
             dump_uuid(principal_id),
             dump_uuid(correlation_id),
             dump_uuid(imported.manifest.manifest_id),
             %{
               "vault_key_generation" => imported.owner.vault_key_generation,
               "wrapper_generation" => generation
             },
             now
           ]
         ) do
      {:ok, %{rows: [[returned_id]]}} ->
        if load_uuid(returned_id) == event_id, do: :ok, else: storage_unavailable()

      {:ok, _malformed} ->
        storage_unavailable()

      {:error, %Error{}} = error ->
        error
    end
  end

  defp verify_integrity_principal(repo, rewrapped) do
    case query(
           repo,
           """
           SELECT principal.id, capability.name
           FROM identity.principals AS principal
           JOIN core.vault_members AS member
             ON member.principal_id = principal.id
            AND member.vault_id = $1
            AND member.revoked_at IS NULL
            AND member.clearance = 'restricted'
           JOIN core.principal_capabilities AS assignment
             ON assignment.principal_id = member.principal_id
            AND assignment.vault_id = member.vault_id
            AND assignment.revoked_at IS NULL
           JOIN core.capabilities AS capability
             ON capability.id = assignment.capability_id
           WHERE principal.id = $2
             AND principal.account_id = $3
             AND principal.kind = 'system'
             AND principal.revoked_at IS NULL
             AND principal.metadata ->> 'name' = $4
           ORDER BY capability.name
           """,
           [
             dump_uuid(rewrapped.cut.vault_id),
             dump_uuid(rewrapped.integrity_principal_id),
             dump_uuid(rewrapped.owner.account_id),
             @integrity_principal_name
           ]
         ) do
      {:ok, %{rows: [[principal_id, @integrity_capability]]}} ->
        if load_uuid(principal_id) == rewrapped.integrity_principal_id do
          verify_integrity_membership_scope(
            repo,
            rewrapped.integrity_principal_id,
            rewrapped.cut.vault_id
          )
        else
          conflict()
        end

      {:ok, _mismatch} ->
        conflict()

      {:error, %Error{}} = error ->
        error
    end
  end

  defp insert_restore_completion(repo, rewrapped) do
    event_id = restore_identity(rewrapped, "backup.restore_completed:event")
    correlation_id = restore_identity(rewrapped, "backup.restore_completed:correlation")
    now = DateTime.utc_now()

    params = [
      dump_uuid(event_id),
      dump_uuid(rewrapped.cut.vault_id),
      dump_uuid(rewrapped.integrity_principal_id),
      dump_uuid(correlation_id),
      dump_uuid(rewrapped.manifest.manifest_id),
      %{
        "idempotency_id" => event_id,
        "vault_key_generation" => rewrapped.owner.vault_key_generation,
        "wrapper_generation" => rewrapped.owner.wrapper_generation
      },
      now
    ]

    case query(
           repo,
           """
           INSERT INTO audit.events (
             id, vault_id, actor_kind, principal_id, operation, result,
             classification, correlation_id, target_type, target_id, metadata,
             occurred_at, inserted_at
           )
           VALUES (
             $1, $2, 'system', $3, 'backup.restore_completed', 'completed',
             'restricted', $4, 'backup_manifest', $5, $6, $7, $7
           )
           ON CONFLICT (id) DO NOTHING
           RETURNING id
           """,
           params
         ) do
      {:ok, %{rows: [[returned_id]]}} ->
        if load_uuid(returned_id) == event_id, do: :ok, else: storage_unavailable()

      {:ok, %{rows: []}} ->
        verify_restore_completion(repo, rewrapped, event_id, correlation_id)

      {:ok, _malformed} ->
        storage_unavailable()

      {:error, %Error{}} = error ->
        error
    end
  end

  defp verify_restore_completion(repo, rewrapped, event_id, correlation_id) do
    case query(
           repo,
           """
           SELECT
             vault_id, actor_kind, principal_id, operation, result, classification,
             correlation_id, target_type, target_id, metadata
           FROM audit.events
           WHERE id = $1
           """,
           [dump_uuid(event_id)]
         ) do
      {:ok,
       %{
         rows: [
           [
             vault_id,
             "system",
             principal_id,
             "backup.restore_completed",
             "completed",
             "restricted",
             stored_correlation_id,
             "backup_manifest",
             manifest_id,
             %{
               "idempotency_id" => ^event_id,
               "vault_key_generation" => vault_key_generation,
               "wrapper_generation" => wrapper_generation
             }
           ]
         ]
       }} ->
        if load_uuid(vault_id) == rewrapped.cut.vault_id and
             load_uuid(principal_id) == rewrapped.integrity_principal_id and
             load_uuid(stored_correlation_id) == correlation_id and
             load_uuid(manifest_id) == rewrapped.manifest.manifest_id and
             vault_key_generation == rewrapped.owner.vault_key_generation and
             wrapper_generation == rewrapped.owner.wrapper_generation do
          :ok
        else
          conflict()
        end

      {:ok, _mismatch} ->
        conflict()

      {:error, %Error{}} = error ->
        error
    end
  end

  defp transact(repo, operation, options) do
    case repo.transact(
           fn ->
             case operation.() do
               {:error, %Error{} = error} -> {:error, sanitize(error)}
               result -> {:ok, result}
             end
           end,
           options
         ) do
      {:ok, result} -> {:ok, result}
      {:error, %Error{} = error} -> {:error, sanitize(error)}
      {:error, _reason} -> storage_unavailable()
    end
  rescue
    _exception -> storage_unavailable()
  catch
    _kind, _reason -> storage_unavailable()
  end

  defp with_restore_advisory_lock(repo, operation)
       when is_atom(repo) and is_function(operation, 0) do
    repo.checkout(
      fn ->
        case SQL.query(
               repo,
               "SELECT pg_advisory_lock(hashtextextended($1::text, 0))",
               [@restore_lock_key],
               log: false,
               timeout: @restore_lock_timeout_ms
             ) do
          {:ok, %{rows: [[_void]]}} ->
            try do
              operation.()
            after
              release_restore_advisory_lock!(repo)
            end

          _failure ->
            storage_unavailable()
        end
      end,
      timeout: @restore_checkout_timeout_ms
    )
  rescue
    _exception -> storage_unavailable()
  catch
    _kind, _reason -> storage_unavailable()
  end

  defp release_restore_advisory_lock!(repo) do
    case SQL.query(
           repo,
           "SELECT pg_advisory_unlock(hashtextextended($1::text, 0))",
           [@restore_lock_key],
           log: false,
           timeout: @restore_lock_timeout_ms
         ) do
      {:ok, %{rows: [[true]]}} ->
        :ok

      _failure ->
        _ = SQL.disconnect_all(repo, 0)
        raise "restore advisory lock release failed; connection pool disconnected"
    end
  end

  defp assume_table_owner(repo) do
    query_ok(repo, "SET LOCAL ROLE singularity_table_owner", [])
  end

  defp verify_migration_authority(repo) do
    case query(
           repo,
           """
           SELECT
             current_user,
             session_user,
             pg_has_role(session_user, 'singularity_table_owner', 'SET')
           """,
           []
         ) do
      {:ok, %{rows: [["singularity_table_owner", "singularity_migration", true]]}} -> :ok
      {:ok, _other} -> storage_unavailable()
      {:error, %Error{}} = error -> error
    end
  end

  defp destination_tables, do: LogicalSchema.tables() ++ @excluded_tables

  defp lock_destination_tables(repo) do
    tables = destination_tables() |> Enum.sort() |> Enum.map_join(", ", &quote_table/1)
    query_ok(repo, "LOCK TABLE #{tables} IN ACCESS EXCLUSIVE MODE", [])
  end

  defp require_empty_tables(repo) do
    destination_tables()
    |> Enum.reduce_while(:ok, fn table, :ok ->
      case query(repo, "SELECT EXISTS (SELECT 1 FROM #{quote_table(table)} LIMIT 1)", []) do
        {:ok, %{rows: [[false]]}} -> {:cont, :ok}
        {:ok, %{rows: [[true]]}} -> {:halt, conflict()}
        {:ok, _other} -> {:halt, storage_unavailable()}
        {:error, %Error{}} = error -> {:halt, error}
      end
    end)
  end

  defp require_excluded_tables_empty(repo) do
    @excluded_tables
    |> Enum.reduce_while(:ok, fn table, :ok ->
      case query(repo, "SELECT EXISTS (SELECT 1 FROM #{quote_table(table)} LIMIT 1)", []) do
        {:ok, %{rows: [[false]]}} -> {:cont, :ok}
        {:ok, %{rows: [[true]]}} -> {:halt, conflict()}
        {:ok, _other} -> {:halt, storage_unavailable()}
        {:error, %Error{}} = error -> {:halt, error}
      end
    end)
  end

  defp verify_seed_rows(repo) do
    with {:ok, %{rows: [[1]]}} <-
           query(repo, "SELECT count(*) FROM identity.security_settings WHERE singleton", []),
         {:ok, %{rows: [[3]]}} <-
           query(
             repo,
             """
             SELECT count(*)
             FROM core.data_classifications
             WHERE (name, rank) IN (('private', 0), ('sensitive', 1), ('restricted', 2))
             """,
             []
           ),
         {:ok, %{rows: [[3]]}} <-
           query(repo, "SELECT count(*) FROM core.data_classifications", []) do
      :ok
    else
      {:error, %Error{}} = error -> error
      _other -> conflict()
    end
  end

  defp dummy_verifier(repo) do
    case query(
           repo,
           "SELECT dummy_verifier FROM identity.security_settings WHERE singleton",
           []
         ) do
      {:ok, %{rows: [[verifier]]}} when is_binary(verifier) and verifier != "" ->
        {:ok, verifier}

      {:ok, _other} ->
        conflict()

      {:error, %Error{}} = error ->
        error
    end
  end

  defp insert_groups(repo, groups, dummy_verifier) do
    LogicalSchema.all()
    |> Enum.reduce_while(:ok, fn schema, :ok ->
      groups
      |> Map.fetch!(schema.table)
      |> Enum.reduce_while(:ok, fn row, :ok ->
        case insert_row(repo, schema, row, dummy_verifier) do
          :ok -> {:cont, :ok}
          {:error, %Error{}} = error -> {:halt, error}
        end
      end)
      |> case do
        :ok -> {:cont, :ok}
        {:error, %Error{}} = error -> {:halt, error}
      end
    end)
  end

  defp insert_row(repo, %{table: "identity.credentials"} = schema, row, dummy_verifier) do
    inserted_at = tagged_field(row, "inserted_at")

    insert_values(
      repo,
      schema.table,
      Enum.map(schema.columns, & &1.name) ++ ["verifier", "verifier_version", "updated_at"],
      row.values ++
        [{"text", dummy_verifier}, {"integer", 1}, inserted_at]
    )
  end

  defp insert_row(repo, %{table: "core.vaults"} = schema, row, _dummy_verifier) do
    values =
      row.values
      |> replace_tagged_field(schema, "locked", {"boolean", true})
      |> replace_tagged_field(schema, "object_cleanup_principal_id", {"null"})

    insert_values(repo, schema.table, Enum.map(schema.columns, & &1.name), values)
  end

  defp insert_row(repo, %{table: "core.vault_key_wrappers"} = schema, row, _dummy_verifier) do
    insert_values(
      repo,
      schema.table,
      Enum.map(schema.columns, & &1.name) ++
        ["kdf_version", "kdf_salt", "kdf_parameters", "wrapper_algorithm", "wrapped_key"],
      row.values ++
        [
          {"integer", 1},
          {"bytes", @restore_pending},
          {"json", %{"state" => "restore_pending", "version" => 1}},
          {"text", "restore_pending"},
          {"bytes", @restore_pending}
        ]
    )
  end

  defp insert_row(repo, schema, row, _dummy_verifier) do
    insert_values(
      repo,
      schema.table,
      Enum.map(schema.columns, & &1.name),
      row.values,
      override_system_value?: schema.table == "core.outbox_events"
    )
  end

  defp insert_values(repo, table, columns, tagged_values, options \\ []) do
    column_list = Enum.map_join(columns, ", ", &quote_identifier/1)

    placeholders =
      tagged_values
      |> Enum.with_index(1)
      |> Enum.map_join(", ", fn {_value, position} -> "$#{position}" end)

    overriding =
      if Keyword.get(options, :override_system_value?, false),
        do: " OVERRIDING SYSTEM VALUE",
        else: ""

    statement =
      "INSERT INTO #{quote_table(table)} (#{column_list})#{overriding} VALUES (#{placeholders})"

    parameters = Enum.map(tagged_values, &sql_value/1)

    case query(repo, statement, parameters) do
      {:ok, %{num_rows: 1}} -> :ok
      {:ok, _other} -> storage_unavailable()
      {:error, %Error{}} = error -> error
    end
  end

  defp sql_value({"null"}), do: nil
  defp sql_value({"uuid", value}), do: Ecto.UUID.dump!(value)

  defp sql_value({"timestamp", value}) do
    {:ok, datetime, 0} = DateTime.from_iso8601(value)
    datetime
  end

  defp sql_value({"json", value}), do: value
  defp sql_value({_tag, value}), do: value

  defp tagged_field(%{schema: schema, values: values}, name) do
    Enum.at(values, Enum.find_index(schema.columns, &(&1.name == name)))
  end

  defp replace_tagged_field(values, schema, name, replacement) do
    List.replace_at(values, Enum.find_index(schema.columns, &(&1.name == name)), replacement)
  end

  defp restore_cleanup_principal(repo, groups, vault_id) do
    [vault] = rows(groups, "core.vaults")

    case field(vault, "object_cleanup_principal_id") do
      nil ->
        :ok

      cleanup_principal_id ->
        case query(
               repo,
               """
               UPDATE core.vaults
               SET object_cleanup_principal_id = $1
               WHERE id = $2
               """,
               [Ecto.UUID.dump!(cleanup_principal_id), Ecto.UUID.dump!(vault_id)]
             ) do
          {:ok, %{num_rows: 1}} -> :ok
          {:ok, _other} -> storage_unavailable()
          {:error, %Error{}} = error -> error
        end
    end
  end

  defp verify_inserted_counts(repo, groups) do
    LogicalSchema.all()
    |> Enum.reduce_while(:ok, fn schema, :ok ->
      expected_count = length(Map.fetch!(groups, schema.table))

      case query(repo, "SELECT count(*) FROM #{quote_table(schema.table)}", []) do
        {:ok, %{rows: [[^expected_count]]}} -> {:cont, :ok}
        {:ok, _other} -> {:halt, storage_unavailable()}
        {:error, %Error{}} = error -> {:halt, error}
      end
    end)
  end

  defp verify_owner_handoff(repo, owner, vault_id) do
    case query(
           repo,
           """
           SELECT
             wrapper.id,
             wrapper.generation,
             version.id,
             version.generation
           FROM core.vault_key_wrappers AS wrapper
           JOIN core.vault_key_versions AS version
             ON version.id = wrapper.vault_key_version_id
            AND version.vault_id = wrapper.vault_id
           WHERE wrapper.id = $1
             AND wrapper.vault_id = $2
             AND wrapper.account_id = $3
             AND version.state = 'active'
           """,
           [
             Ecto.UUID.dump!(owner.vault_key_wrapper_id),
             Ecto.UUID.dump!(vault_id),
             Ecto.UUID.dump!(owner.account_id)
           ]
         ) do
      {:ok,
       %{
         rows: [
           [wrapper_id, wrapper_generation, version_id, vault_key_generation]
         ]
       }} ->
        if Ecto.UUID.load!(wrapper_id) == owner.vault_key_wrapper_id and
             wrapper_generation == owner.wrapper_generation and
             Ecto.UUID.load!(version_id) == owner.vault_key_version_id and
             vault_key_generation == owner.vault_key_generation do
          :ok
        else
          backup_invalid()
        end

      {:ok, _other} ->
        backup_invalid()

      {:error, %Error{}} = error ->
        error
    end
  end

  defp repair_outbox_sequence(repo, 0) do
    repair_outbox_sequence(repo, 1, false)
  end

  defp repair_outbox_sequence(repo, mark) when is_integer(mark) and mark > 0 do
    repair_outbox_sequence(repo, mark, true)
  end

  defp repair_outbox_sequence(repo, value, called?) do
    case query(
           repo,
           "SELECT setval('core.outbox_events_sequence_seq'::regclass, $1, $2)",
           [value, called?]
         ) do
      {:ok, %{rows: [[^value]]}} -> :ok
      {:ok, _other} -> storage_unavailable()
      {:error, %Error{}} = error -> error
    end
  end

  defp verify_imported_destination(repo, storage, verified, decoded, cut, owner, marker) do
    with :ok <- verify_imported_database(repo, decoded, cut, owner, marker),
         :ok <- verify_no_staged_objects(storage),
         :ok <- verify_published_inventory(storage, cut.object_inventory) do
      imported(verified, cut, owner)
    end
  end

  defp verify_imported_database(repo, decoded, cut, owner, marker) do
    case transact(
           repo,
           fn ->
             with :ok <- assume_table_owner(repo),
                  :ok <- verify_migration_authority(repo),
                  :ok <- lock_restore_import_sagas(repo),
                  :ok <- lock_destination_tables(repo),
                  {:ok, state} <- load_import_marker(repo),
                  :imported <- require_marker(state, marker),
                  :ok <- verify_seed_rows(repo),
                  :ok <- verify_inserted_counts(repo, decoded.groups),
                  :ok <- verify_owner_handoff(repo, owner, cut.vault_id),
                  :ok <- require_excluded_tables_empty(repo) do
               :imported
             else
               {:error, %Error{}} = error -> error
               _mismatch -> conflict()
             end
           end,
           isolation: :serializable
         ) do
      {:ok, :imported} -> :ok
      {:error, %Error{}} = error -> error
      _invalid -> storage_unavailable()
    end
  end

  defp verify_no_staged_objects(%{module: module, context: context}) do
    case safe_adapter_call(module, :list_staged, [context]) do
      {:ok, []} -> :ok
      {:ok, _staged} -> conflict()
      {:error, %Error{code: :not_found}} -> :ok
      {:error, %Error{}} = error -> error
      _invalid -> storage_unavailable()
    end
  end

  defp verify_published_inventory(storage, inventory) do
    with {:ok, artifacts} <- inventory_artifacts(storage, inventory) do
      Enum.reduce_while(artifacts, :ok, fn artifact, :ok ->
        case safe_adapter_call(storage.module, :stat, [artifact.context, artifact.object_ref]) do
          {:ok, stat} ->
            case stat_matches?(stat, artifact.entry) do
              :ok -> {:cont, :ok}
              {:error, %Error{}} = error -> {:halt, error}
            end

          {:error, %Error{}} = error ->
            {:halt, error}
        end
      end)
    end
  end

  defp rollback_inventory(storage, inventory) do
    with {:ok, artifacts} <- inventory_artifacts(storage, inventory) do
      rollback_staged(storage, artifacts)
    end
  end

  defp inventory_artifacts(storage, inventory) do
    inventory
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, artifacts} ->
      with {:ok, %StageRef{} = stage_ref} <- StageRef.new(stage_id: entry.asset_object_id),
           {:ok, %ObjectRef{} = object_ref} <- ObjectRef.new(object_id: entry.storage_ref) do
        artifact = %{
          context: object_context(storage.context, entry),
          entry: entry,
          object_ref: object_ref,
          stage_ref: stage_ref
        }

        {:cont, {:ok, [artifact | artifacts]}}
      else
        _invalid -> {:halt, backup_invalid()}
      end
    end)
    |> case do
      {:ok, artifacts} -> {:ok, Enum.reverse(artifacts)}
      {:error, %Error{}} = error -> error
    end
  end

  defp rollback_staged(%{module: module}, staged) do
    Enum.reduce(staged, :ok, fn artifact, result ->
      case rollback_artifact(module, artifact) do
        :ok -> result
        {:error, %Error{}} = error when result == :ok -> error
        {:error, %Error{}} -> result
      end
    end)
  end

  defp rollback_artifact(module, artifact) do
    if function_exported?(module, :rollback_finalize, 3) do
      safe_adapter_call(module, :rollback_finalize, [
        artifact.context,
        artifact.stage_ref,
        artifact.object_ref
      ])
    else
      rollback_with_delete(module, artifact)
    end
  end

  defp rollback_with_delete(module, artifact) do
    case safe_adapter_call(module, :stat, [artifact.context, artifact.object_ref]) do
      {:ok, stat} ->
        with :ok <- stat_matches?(stat, artifact.entry),
             :ok <- safe_adapter_call(module, :delete, [artifact.context, artifact.object_ref]),
             :ok <-
               safe_adapter_call(module, :abort_stage, [artifact.context, artifact.stage_ref]) do
          :ok
        end

      {:error, %Error{code: :not_found}} ->
        safe_adapter_call(module, :abort_stage, [artifact.context, artifact.stage_ref])

      {:error, %Error{}} = error ->
        error
    end
  end

  defp stage_objects(storage, inventory, raw_payloads) do
    inventory
    |> Enum.zip(raw_payloads)
    |> Enum.reduce_while({:ok, []}, fn {entry, payload}, {:ok, staged} ->
      case stage_object(storage, entry, payload) do
        {:ok, staged_object} ->
          {:cont, {:ok, [staged_object | staged]}}

        {:error, %Error{}} = error ->
          abort_stages(storage, staged)
          {:halt, error}
      end
    end)
    |> case do
      {:ok, staged} -> {:ok, Enum.reverse(staged)}
      {:error, %Error{}} = error -> error
    end
  end

  defp stage_object(%{module: module, context: base_context}, entry, payload) do
    context = object_context(base_context, entry)

    with {:ok, %StageRef{} = stage_ref} <-
           safe_adapter_call(module, :stage, [context, %{stage_id: entry.asset_object_id}]),
         result <- append_and_seal(module, context, stage_ref, entry, payload) do
      case result do
        {:ok, %ObjectRef{} = object_ref} ->
          {:ok,
           %{
             context: context,
             entry: entry,
             object_ref: object_ref,
             stage_ref: stage_ref
           }}

        {:error, %Error{}} = error ->
          _ = safe_adapter_call(module, :abort_stage, [context, stage_ref])
          error
      end
    else
      {:error, %Error{}} = error -> error
      _invalid -> storage_unavailable()
    end
  end

  defp append_and_seal(module, context, stage_ref, entry, payload) do
    with :ok <- append_payload(module, context, stage_ref, payload),
         {:ok, sealed} <- safe_adapter_call(module, :seal_stage, [context, stage_ref, %{}]),
         :ok <- sealed_matches?(sealed, entry),
         {:ok, object_ref} <- ObjectRef.new(object_id: entry.storage_ref) do
      {:ok, object_ref}
    else
      {:error, %Error{}} = error -> error
      _invalid -> storage_unavailable()
    end
  end

  defp append_payload(_module, _context, _stage_ref, ""), do: :ok

  defp append_payload(module, context, stage_ref, payload) do
    chunk_size = min(byte_size(payload), @append_chunk_bytes)
    <<chunk::binary-size(chunk_size), remaining::binary>> = payload

    with :ok <- safe_adapter_call(module, :append_encrypted_chunk, [context, stage_ref, chunk]) do
      append_payload(module, context, stage_ref, remaining)
    end
  end

  defp sealed_matches?(
         %{byte_size: byte_size, ciphertext_hash: ciphertext_hash, sealed?: true},
         entry
       ) do
    if byte_size == entry.ciphertext_byte_size and
         secure_compare(ciphertext_hash, entry.ciphertext_hash),
       do: :ok,
       else: integrity_failure()
  end

  defp sealed_matches?(_sealed, _entry), do: integrity_failure()

  defp object_context(base_context, entry) do
    Map.merge(base_context, %{
      ciphertext_hash: entry.ciphertext_hash,
      domain_namespace: entry.key_domain_id,
      lookup_digest: Base.encode16(entry.lookup_digest, case: :lower),
      vault_namespace: entry.vault_id
    })
  end

  defp publish_objects(%{module: module}, staged) do
    Enum.reduce_while(staged, :ok, fn staged_object, :ok ->
      case publish_object(module, staged_object) do
        :ok -> {:cont, :ok}
        {:error, %Error{}} = error -> {:halt, error}
      end
    end)
  end

  defp publish_object(module, staged_object) do
    with {:ok, %ObjectRef{} = object_ref} <-
           safe_adapter_call(module, :finalize, [
             staged_object.context,
             staged_object.stage_ref,
             staged_object.object_ref
           ]),
         true <- object_ref == staged_object.object_ref or storage_unavailable(),
         {:ok, stat} <-
           safe_adapter_call(module, :stat, [staged_object.context, staged_object.object_ref]),
         :ok <- stat_matches?(stat, staged_object.entry) do
      :ok
    else
      {:error, %Error{}} = error -> error
      _invalid -> storage_unavailable()
    end
  end

  defp stat_matches?(%{byte_size: byte_size, ciphertext_hash: ciphertext_hash}, entry) do
    if byte_size == entry.ciphertext_byte_size and
         secure_compare(ciphertext_hash, entry.ciphertext_hash),
       do: :ok,
       else: integrity_failure()
  end

  defp stat_matches?(_stat, _entry), do: integrity_failure()

  defp abort_stages(%{module: module}, staged) do
    Enum.each(staged, fn staged_object ->
      _ =
        safe_adapter_call(module, :abort_stage, [
          staged_object.context,
          staged_object.stage_ref
        ])
    end)

    :ok
  end

  defp validate_imported(%Imported{
         manifest: %{manifest_id: manifest_id},
         manifest_hash: <<_::binary-size(32)>>,
         manifest_tag: <<_::binary-size(16)>>,
         cut: %{manifest_id: manifest_id, vault_id: vault_id, object_inventory: inventory},
         object_inventory: inventory,
         owner: %{
           account_id: account_id,
           active_credential_ids: active_credential_ids,
           all_credential_ids: all_credential_ids,
           owner_principal_ids: owner_principal_ids,
           vault_key_generation: vault_key_generation,
           vault_key_version_id: vault_key_version_id,
           vault_key_wrapper_id: vault_key_wrapper_id,
           wrapper_generation: wrapper_generation
         }
       })
       when is_list(inventory) and is_integer(vault_key_generation) and
              vault_key_generation > 0 and is_integer(wrapper_generation) and
              wrapper_generation > 0 and wrapper_generation < 0xFFFFFFFF do
    with true <- canonical_uuid?(manifest_id),
         true <- canonical_uuid?(vault_id),
         true <- canonical_uuid?(account_id),
         true <- canonical_uuid?(vault_key_version_id),
         true <- canonical_uuid?(vault_key_wrapper_id),
         true <- valid_uuid_list?(active_credential_ids),
         true <- valid_uuid_list?(all_credential_ids),
         true <- valid_uuid_list?(owner_principal_ids),
         true <- active_credential_ids != [],
         true <- owner_principal_ids != [],
         true <- Enum.sort(active_credential_ids) == active_credential_ids,
         true <- Enum.sort(all_credential_ids) == all_credential_ids,
         true <- Enum.sort(owner_principal_ids) == owner_principal_ids,
         true <- Enum.all?(active_credential_ids, &(&1 in all_credential_ids)) do
      :ok
    else
      _invalid -> backup_invalid()
    end
  end

  defp validate_imported(_imported), do: backup_invalid()

  defp validate_rewrapped(%Rewrapped{} = rewrapped) do
    imported = %Imported{
      manifest: rewrapped.manifest,
      manifest_hash: rewrapped.manifest_hash,
      manifest_tag: rewrapped.manifest_tag,
      cut: rewrapped.cut,
      object_inventory: rewrapped.object_inventory,
      owner: rewrapped.owner
    }

    with :ok <- validate_imported(imported),
         true <- canonical_uuid?(rewrapped.integrity_principal_id),
         true <- not is_nil(rewrapped.integrity_capability) do
      :ok
    else
      {:error, %Error{}} = error -> error
      _invalid -> backup_invalid()
    end
  end

  defp rewrap_adapters(context) do
    with migration_repo when is_atom(migration_repo) and not is_nil(migration_repo) <-
           Map.get(context, :migration_repo),
         {:ok, password_hasher} <- configured_password_hasher(context),
         {:ok, key_deriver} <- configured_adapter(Map.get(context, :key_deriver), :derive, 3),
         {:ok, key_wrapper} <-
           configured_module_adapter(Map.get(context, :key_wrapper), :unwrap, 3),
         {:ok, recovered_vault_key} <-
           configured_adapter(Map.get(context, :recovered_vault_key), :rewrap, 3),
         :ok <- require_adapter_callback(recovered_vault_key, :revoke, 1),
         {:ok, integrity_issuer} <-
           configured_adapter(Map.get(context, :integrity_issuer), :issue, 1),
         :ok <- require_adapter_callback(integrity_issuer, :revoke, 1),
         random_bytes when is_function(random_bytes, 1) <- Map.get(context, :random_bytes),
         {:ok, vault_kdf_params} <- kdf_parameters(Map.get(context, :vault_kdf_params)),
         {:ok, object_storage} <- configured_integrity_storage(Map.get(context, :object_storage)),
         ttl_ms when is_integer(ttl_ms) and ttl_ms > 0 <-
           Map.get(context, :integrity_ttl_ms, @default_integrity_ttl_ms) do
      {:ok,
       %{
         migration_repo: migration_repo,
         password_hasher: password_hasher,
         key_deriver: key_deriver,
         key_wrapper: key_wrapper,
         recovered_vault_key: recovered_vault_key,
         integrity_issuer: integrity_issuer,
         random_bytes: random_bytes,
         vault_kdf_params: vault_kdf_params,
         object_storage: object_storage,
         integrity_ttl_ms: ttl_ms
       }}
    else
      {:error, %Error{}} = error -> error
      _invalid -> invalid()
    end
  end

  defp configured_password_hasher(context) do
    case {Map.get(context, :password_hasher), Map.fetch(context, :password_hasher_context)} do
      {{_module, _adapter_context}, {:ok, _separate_context}} ->
        invalid()

      {module, {:ok, adapter_context}} when is_atom(module) and not is_nil(module) ->
        configured_adapter({module, adapter_context}, :hash, 1)

      {adapter, :error} ->
        configured_adapter(adapter, :hash, 1)

      _invalid ->
        invalid()
    end
  end

  defp configured_adapter(module, function, arity)
       when is_atom(module) and not is_nil(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, function, arity),
      do: {:ok, module},
      else: invalid()
  end

  defp configured_adapter({module, adapter_context}, function, arity)
       when is_atom(module) and not is_nil(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, function, arity + 1),
      do: {:ok, {module, adapter_context}},
      else: invalid()
  end

  defp configured_adapter(_adapter, _function, _arity), do: invalid()

  defp configured_module_adapter(module, function, arity)
       when is_atom(module) and not is_nil(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, function, arity),
      do: {:ok, module},
      else: invalid()
  end

  defp configured_module_adapter(_module, _function, _arity), do: invalid()

  defp require_adapter_callback(module, function, arity)
       when is_atom(module) and not is_nil(module) do
    if function_exported?(module, function, arity), do: :ok, else: invalid()
  end

  defp require_adapter_callback({module, _context}, function, arity)
       when is_atom(module) and not is_nil(module) do
    if function_exported?(module, function, arity + 1), do: :ok, else: invalid()
  end

  defp configured_integrity_storage({module, context} = storage)
       when is_atom(module) and not is_nil(module) and is_map(context) do
    callbacks = [stat: 2, open: 2, read_range: 3]

    if Code.ensure_loaded?(module) and
         Enum.all?(callbacks, fn {function, arity} ->
           function_exported?(module, function, arity)
         end),
       do: {:ok, storage},
       else: invalid()
  end

  defp configured_integrity_storage(_storage), do: invalid()

  defp kdf_parameters(
         %{
           "version" => version,
           "t_cost" => t_cost,
           "m_cost" => m_cost,
           "parallelism" => parallelism
         } = params
       )
       when map_size(params) == 4 do
    kdf_parameters(%{
      version: version,
      t_cost: t_cost,
      m_cost: m_cost,
      parallelism: parallelism
    })
  end

  defp kdf_parameters(
         %{
           version: version,
           t_cost: t_cost,
           m_cost: m_cost,
           parallelism: parallelism
         } = params
       )
       when map_size(params) == 4 and is_integer(version) and version > 0 and
              is_integer(t_cost) and t_cost > 0 and is_integer(m_cost) and m_cost >= 8 and
              is_integer(parallelism) and parallelism > 0,
       do: {:ok, params}

  defp kdf_parameters(_params), do: invalid()

  defp random_salt(random_bytes) do
    case random_bytes.(16) do
      <<_::binary-size(16)>> = salt -> {:ok, salt}
      _invalid -> invalid()
    end
  rescue
    _exception -> invalid()
  catch
    _kind, _reason -> invalid()
  end

  defp validate_recovered_wrapper(
         %{
           algorithm: algorithm,
           encoded: encoded,
           generation: generation,
           purpose: :vault_key,
           version: 1
         } = wrapper,
         generation
       )
       when map_size(wrapper) == 5 and algorithm in [:aes_256_gcm, "aes_256_gcm"] and
              is_binary(encoded) and encoded != "",
       do: {:ok, encoded, "aes_256_gcm"}

  defp validate_recovered_wrapper(_wrapper, _generation), do: integrity_failure()

  defp adapter_value(adapter, function, arguments, fallback_code) do
    result =
      case adapter do
        module when is_atom(module) -> apply(module, function, arguments)
        {module, adapter_context} -> apply(module, function, [adapter_context | arguments])
      end

    case result do
      {:ok, value} -> {:ok, value}
      {:error, %Error{} = error} -> {:error, sanitize(error)}
      {:error, :lease_unavailable} -> error_result(fallback_code)
      _unexpected -> error_result(fallback_code)
    end
  rescue
    _exception -> error_result(fallback_code)
  catch
    _kind, _reason -> error_result(fallback_code)
  end

  defp revoke_capability(adapter, capability) do
    case adapter do
      module when is_atom(module) -> apply(module, :revoke, [capability])
      {module, adapter_context} -> apply(module, :revoke, [adapter_context, capability])
    end

    :ok
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp adapter_module(module) when is_atom(module), do: module
  defp adapter_module({module, _context}), do: module

  defp stringify_keys(parameters) do
    Map.new(parameters, fn {key, value} -> {Atom.to_string(key), value} end)
  end

  defp load_uuid_column(rows, position) when is_list(rows) do
    rows
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, ids} ->
      case Enum.fetch(row, position) do
        {:ok, value} ->
          case load_uuid(value) do
            id when is_binary(id) -> {:cont, {:ok, [id | ids]}}
            _invalid -> {:halt, storage_unavailable()}
          end

        :error ->
          {:halt, storage_unavailable()}
      end
    end)
    |> case do
      {:ok, ids} -> {:ok, Enum.reverse(ids)}
      {:error, %Error{}} = error -> error
    end
  end

  defp dump_uuid(value), do: Ecto.UUID.dump!(value)
  defp load_uuid(<<_::binary-size(16)>> = value), do: Ecto.UUID.load!(value)
  defp load_uuid(value) when is_binary(value), do: Ecto.UUID.cast!(value)

  defp canonical_uuid?(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, ^value} -> true
      _invalid -> false
    end
  end

  defp canonical_uuid?(_value), do: false

  defp valid_uuid_list?(values) when is_list(values) do
    values != [] and Enum.all?(values, &canonical_uuid?/1) and
      MapSet.size(MapSet.new(values)) == length(values)
  end

  defp valid_uuid_list?(_values), do: false

  defp restore_identity(rewrapped, label) do
    digest =
      :crypto.hash(:sha256, [
        "singularity:restore:audit:v1\0",
        label,
        0,
        dump_uuid(rewrapped.manifest.manifest_id),
        dump_uuid(rewrapped.cut.vault_id)
      ])

    <<prefix::binary-size(6), version_byte, middle_byte, variant_byte, suffix::binary-size(7),
      _rest::binary>> = digest

    version_byte = Bitwise.bor(Bitwise.band(version_byte, 0x0F), 0x50)
    variant_byte = Bitwise.bor(Bitwise.band(variant_byte, 0x3F), 0x80)

    Ecto.UUID.load!(<<prefix::binary, version_byte, middle_byte, variant_byte, suffix::binary>>)
  end

  defp overwrite(value) when is_binary(value), do: :crypto.strong_rand_bytes(byte_size(value))
  defp overwrite(_value), do: :ok

  defp error_result(:invalid), do: invalid()
  defp error_result(:backup_invalid), do: backup_invalid()
  defp error_result(:integrity_failure), do: integrity_failure()
  defp error_result(:storage_unavailable), do: storage_unavailable()

  defp safe_adapter_call(module, function, arguments) do
    case apply(module, function, arguments) do
      :ok -> :ok
      {:ok, _value} = ok -> ok
      {:error, %Error{} = error} -> {:error, sanitize(error)}
      _unexpected -> storage_unavailable()
    end
  rescue
    _exception -> storage_unavailable()
  catch
    _kind, _reason -> storage_unavailable()
  end

  defp query(repo, statement, parameters) do
    case SQL.query(repo, statement, parameters, log: false) do
      {:ok, result} -> {:ok, result}
      {:error, _reason} -> storage_unavailable()
    end
  rescue
    _exception -> storage_unavailable()
  catch
    _kind, _reason -> storage_unavailable()
  end

  defp query_ok(repo, statement, parameters) do
    case query(repo, statement, parameters) do
      {:ok, _result} -> :ok
      {:error, %Error{}} = error -> error
    end
  end

  defp quote_table(table) do
    table |> String.split(".") |> Enum.map_join(".", &quote_identifier/1)
  end

  defp quote_identifier(identifier), do: ~s("#{String.replace(identifier, "\"", "\"\"")}")

  defp secure_compare(left, right)
       when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right),
       do: :crypto.hash_equals(left, right)

  defp secure_compare(_left, _right), do: false

  defp sanitize(%Error{} = error), do: %{error | message: nil, details: %{}}

  defp exact_keys?(map, keys), do: Map.keys(map) |> Enum.sort() == Enum.sort(keys)

  defp backup_invalid, do: {:error, Error.new(:backup_invalid)}
  defp conflict, do: {:error, Error.new(:conflict)}
  defp integrity_failure, do: {:error, Error.new(:integrity_failure)}
  defp invalid, do: {:error, Error.new(:invalid)}
  defp storage_unavailable, do: {:error, Error.new(:storage_unavailable)}
end
