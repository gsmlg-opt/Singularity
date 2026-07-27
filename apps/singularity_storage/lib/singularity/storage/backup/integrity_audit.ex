defmodule Singularity.Storage.Backup.IntegrityAudit do
  @moduledoc """
  Locked-ciphertext verification and restore-only integrity persistence.

  Ciphertext verification is deliberately independent of vault custody. The
  plaintext material loader returns only authenticated wrappers and public
  object metadata; raw hierarchy keys remain in the runtime integrity lease.
  """

  alias Ecto.Adapters.SQL
  alias Singularity.Core.Error
  alias Singularity.Core.ObjectRef
  alias Singularity.Storage.Postgres.AssetRepository

  @classifications [:private, :sensitive, :restricted]
  @entry_keys ~w[
    asset_object_id ciphertext_byte_size ciphertext_hash classification
    inventory_position key_domain_id lookup_digest storage_ref vault_id
  ]a
  @material_binding_keys ~w[
    manifest_id vault_id vault_key_generation vault_key_version_id
  ]a
  @completion_keys ~w[
    ciphertext_inventory_sha256 correlation_id integrity_principal_id manifest_id
    object_count operation plaintext_inventory_sha256 search_rebuild_sha256
    vault_id
  ]a
  @search_binding_keys ~w[manifest_id vault_id]a

  defmodule CiphertextSummary do
    @moduledoc "Safe evidence produced after hashing every finalized ciphertext."

    @enforce_keys [:vault_id, :object_count, :inventory_sha256, :ciphertext_hashes]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            vault_id: Ecto.UUID.t(),
            object_count: non_neg_integer(),
            inventory_sha256: <<_::256>>,
            ciphertext_hashes: [
              %{asset_object_id: Ecto.UUID.t(), sha256: <<_::256>>}
            ]
          }
  end

  defmodule SearchSummary do
    @moduledoc "Safe evidence for the current PostgreSQL metadata projection rebuild."

    @enforce_keys [:projection, :document_count, :result_sha256]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            projection: String.t(),
            document_count: non_neg_integer(),
            result_sha256: <<_::256>>
          }
  end

  @spec verify_ciphertext(term(), Ecto.UUID.t(), [map()]) ::
          {:ok, CiphertextSummary.t()} | {:error, Error.t()}
  def verify_ciphertext(storage, vault_id, inventory) do
    with {:ok, configured} <- configured_storage(storage),
         {:ok, inventory} <- validate_inventory(vault_id, inventory),
         :ok <- verify_inventory(configured, inventory),
         {:ok, inventory_sha256} <- inventory_sha256(vault_id, inventory) do
      {:ok,
       %CiphertextSummary{
         vault_id: vault_id,
         object_count: length(inventory),
         inventory_sha256: inventory_sha256,
         ciphertext_hashes:
           Enum.map(inventory, fn entry ->
             %{asset_object_id: entry.asset_object_id, sha256: entry.ciphertext_hash}
           end)
       }}
    end
  rescue
    _exception -> unavailable()
  catch
    _kind, _reason -> unavailable()
  end

  @spec inventory_sha256(Ecto.UUID.t(), [map()]) ::
          {:ok, <<_::256>>} | {:error, Error.t()}
  def inventory_sha256(vault_id, inventory) do
    with {:ok, inventory} <- validate_inventory(vault_id, inventory),
         {:ok, vault_uuid} <- dump_uuid(vault_id) do
      encoded = [
        "SINGULARITY-INTEGRITY-INVENTORY-V1\0",
        vault_uuid,
        <<length(inventory)::unsigned-big-64>>,
        Enum.map(inventory, &encode_entry/1)
      ]

      {:ok, :crypto.hash(:sha256, encoded)}
    end
  end

  @doc """
  Loads the exact active wrapper chain for one restored inventory entry.

  The result contains ciphertext wrappers only. It is intended to be invoked
  by `Singularity.Runtime.RestoreIntegrityLease`, which alone owns the raw
  restored vault key.
  """
  @spec load_plaintext_material(module(), map(), map()) ::
          {:ok, map()} | {:error, Error.t()}
  def load_plaintext_material(repo, binding, entry)
      when is_atom(repo) and is_map(binding) and is_map(entry) do
    with :ok <- validate_material_binding(binding),
         {:ok, [entry]} <- validate_inventory(binding.vault_id, [entry], entry.inventory_position) do
      owner_transaction(repo, fn ->
        load_material_row(repo, binding, entry)
      end)
    end
  rescue
    _exception -> unavailable()
  catch
    _kind, _reason -> unavailable()
  end

  def load_plaintext_material(_repo, _binding, _entry), do: invalid()

  @doc """
  Rebuilds the present-milestone PostgreSQL metadata projection.

  This is an injected search-rebuilder implementation, not a vector-search
  implementation. The Qdrant vector adapter remains a separate required
  Milestone 8 projection behind the same runtime port.
  """
  @spec rebuild(module(), map()) :: {:ok, SearchSummary.t()} | {:error, Error.t()}
  def rebuild(repo, binding) when is_atom(repo) and is_map(binding) do
    with :ok <- validate_search_binding(binding) do
      owner_transaction(repo, fn -> rebuild_locked(repo, binding.vault_id) end)
    end
  rescue
    _exception -> unavailable()
  catch
    _kind, _reason -> unavailable()
  end

  def rebuild(_repo, _binding), do: invalid()

  @doc "Persists the one completion event after every integrity phase succeeds."
  @spec complete(module(), map()) :: :ok | {:error, Error.t()}
  def complete(repo, command) when is_atom(repo) and is_map(command) do
    with :ok <- validate_completion(command) do
      owner_transaction(repo, fn -> insert_completion(repo, command) end)
    end
  rescue
    _exception -> unavailable()
  catch
    _kind, _reason -> unavailable()
  end

  def complete(_repo, _command), do: invalid()

  defp configured_storage({adapter, context}) when is_atom(adapter) and is_map(context),
    do: validate_storage(adapter, context)

  defp configured_storage(%{adapter: adapter, context: context})
       when is_atom(adapter) and is_map(context),
       do: validate_storage(adapter, context)

  defp configured_storage(_storage), do: invalid()

  defp validate_storage(adapter, context) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :stat, 2),
      do: {:ok, %{adapter: adapter, context: context}},
      else: invalid()
  end

  defp validate_inventory(vault_id, inventory),
    do: validate_inventory(vault_id, inventory, 0)

  defp validate_inventory(vault_id, inventory, first_position)
       when is_list(inventory) and is_integer(first_position) and first_position >= 0 do
    with {:ok, ^vault_id} <- canonical_uuid(vault_id),
         {:ok, validated} <- validate_entries(inventory, vault_id, first_position, []),
         true <- unique_inventory?(validated) do
      {:ok, validated}
    else
      _invalid -> backup_invalid()
    end
  end

  defp validate_inventory(_vault_id, _inventory, _first_position), do: backup_invalid()

  defp validate_entries([], _vault_id, _position, validated),
    do: {:ok, Enum.reverse(validated)}

  defp validate_entries([entry | entries], vault_id, position, validated) do
    case validate_entry(entry, vault_id, position) do
      {:ok, entry} -> validate_entries(entries, vault_id, position + 1, [entry | validated])
      {:error, %Error{}} = error -> error
    end
  end

  defp validate_entry(
         %{
           asset_object_id: asset_object_id,
           ciphertext_byte_size: ciphertext_byte_size,
           ciphertext_hash: <<_::binary-size(32)>>,
           classification: classification,
           inventory_position: inventory_position,
           key_domain_id: key_domain_id,
           lookup_digest: <<_::binary-size(32)>>,
           storage_ref: storage_ref,
           vault_id: entry_vault_id
         } = entry,
         vault_id,
         position
       )
       when classification in @classifications and
              is_integer(ciphertext_byte_size) and ciphertext_byte_size >= 0 and
              inventory_position == position and map_size(entry) == length(@entry_keys) do
    with true <- Enum.sort(Map.keys(entry)) == Enum.sort(@entry_keys),
         {:ok, ^asset_object_id} <- canonical_uuid(asset_object_id),
         {:ok, ^key_domain_id} <- canonical_uuid(key_domain_id),
         {:ok, ^storage_ref} <- canonical_uuid(storage_ref),
         {:ok, ^vault_id} <- canonical_uuid(entry_vault_id) do
      {:ok, entry}
    else
      _invalid -> backup_invalid()
    end
  end

  defp validate_entry(_entry, _vault_id, _position), do: backup_invalid()

  defp unique_inventory?(inventory) do
    unique?(inventory, & &1.asset_object_id) and unique?(inventory, & &1.storage_ref)
  end

  defp unique?(entries, mapper) do
    entries |> Enum.map(mapper) |> MapSet.new() |> MapSet.size() == length(entries)
  end

  defp verify_inventory(storage, inventory) do
    Enum.reduce_while(inventory, :ok, fn entry, :ok ->
      case verify_entry(storage, entry) do
        :ok -> {:cont, :ok}
        {:error, %Error{}} = error -> {:halt, error}
      end
    end)
  end

  defp verify_entry(%{adapter: adapter, context: base_context}, entry) do
    context = object_context(base_context, entry)
    object_ref = %ObjectRef{object_id: entry.storage_ref}

    case safe_apply(adapter, :stat, [context, object_ref]) do
      {:ok,
       %{
         byte_size: byte_size,
         ciphertext_hash: <<_::binary-size(32)>> = ciphertext_hash
       }} ->
        if byte_size == entry.ciphertext_byte_size and
             secure_compare(ciphertext_hash, entry.ciphertext_hash),
           do: :ok,
           else: integrity_failure()

      {:error, %Error{code: :storage_unavailable} = error} ->
        {:error, public_error(error)}

      {:error, %Error{}} ->
        integrity_failure()

      _malformed ->
        unavailable()
    end
  end

  defp object_context(base_context, entry) do
    Map.merge(base_context, %{
      ciphertext_hash: entry.ciphertext_hash,
      domain_namespace: entry.key_domain_id,
      lookup_digest: Base.encode16(entry.lookup_digest, case: :lower),
      vault_namespace: entry.vault_id
    })
  end

  defp encode_entry(entry) do
    {:ok, object_id} = dump_uuid(entry.asset_object_id)
    {:ok, domain_id} = dump_uuid(entry.key_domain_id)
    {:ok, storage_id} = dump_uuid(entry.storage_ref)
    classification = classification_id(entry.classification)

    [
      <<entry.inventory_position::unsigned-big-64>>,
      object_id,
      domain_id,
      storage_id,
      <<classification, entry.ciphertext_byte_size::unsigned-big-64>>,
      entry.lookup_digest,
      entry.ciphertext_hash
    ]
  end

  defp classification_id(:private), do: 1
  defp classification_id(:sensitive), do: 2
  defp classification_id(:restricted), do: 3

  defp validate_material_binding(binding) do
    with true <- Enum.sort(Map.keys(binding)) == Enum.sort(@material_binding_keys),
         {:ok, _manifest_id} <- canonical_uuid(binding.manifest_id),
         {:ok, _vault_id} <- canonical_uuid(binding.vault_id),
         {:ok, _version_id} <- canonical_uuid(binding.vault_key_version_id),
         generation when is_integer(generation) and generation > 0 <-
           binding.vault_key_generation do
      :ok
    else
      _invalid -> backup_invalid()
    end
  end

  defp load_material_row(repo, binding, entry) do
    sql = """
    SELECT
      object.id,
      object.vault_id,
      object.key_domain_id,
      object.classification,
      object.lookup_digest,
      object.ciphertext_hash,
      object.plaintext_byte_size,
      object.ciphertext_byte_size,
      object.format_version,
      object.lifecycle,
      envelope.key_generation,
      envelope.classification,
      envelope.algorithm,
      envelope.wrapped_dek,
      domain.id,
      domain.classification,
      domain.kind,
      domain.state,
      domain_version.id,
      domain_version.vault_key_version_id,
      domain_version.generation,
      domain_version.state,
      domain_version.algorithm,
      domain_version.wrapped_key,
      vault_version.generation,
      vault_version.state
    FROM content.asset_objects AS object
    JOIN content.asset_key_envelopes AS envelope
      ON envelope.asset_object_id = object.id
     AND envelope.vault_id = object.vault_id
     AND envelope.key_domain_id = object.key_domain_id
    JOIN core.key_domains AS domain
      ON domain.id = object.key_domain_id
     AND domain.vault_id = object.vault_id
    JOIN core.domain_key_versions AS domain_version
      ON domain_version.id = envelope.domain_key_version_id
     AND domain_version.vault_id = envelope.vault_id
     AND domain_version.key_domain_id = envelope.key_domain_id
    JOIN core.vault_key_versions AS vault_version
      ON vault_version.id = domain_version.vault_key_version_id
     AND vault_version.vault_id = domain_version.vault_id
    WHERE object.id = $1
      AND object.vault_id = $2
      AND object.key_domain_id = $3
      AND domain_version.vault_key_version_id = $4
    ORDER BY envelope.id
    LIMIT 2
    """

    params = [
      Ecto.UUID.dump!(entry.asset_object_id),
      Ecto.UUID.dump!(binding.vault_id),
      Ecto.UUID.dump!(entry.key_domain_id),
      Ecto.UUID.dump!(binding.vault_key_version_id)
    ]

    case SQL.query(repo, sql, params) do
      {:ok, %{rows: [row]}} -> normalize_material(row, binding, entry)
      {:ok, %{rows: []}} -> integrity_failure()
      {:ok, %{rows: [_first, _second]}} -> integrity_failure()
      {:ok, _malformed} -> unavailable()
      {:error, _reason} -> unavailable()
    end
  end

  defp normalize_material(
         [
           object_id,
           vault_id,
           key_domain_id,
           classification,
           lookup_digest,
           ciphertext_hash,
           plaintext_byte_size,
           ciphertext_byte_size,
           format_version,
           lifecycle,
           object_generation,
           envelope_classification,
           envelope_algorithm,
           wrapped_dek,
           domain_id,
           domain_classification,
           domain_kind,
           domain_state,
           domain_key_version_id,
           vault_key_version_id,
           domain_key_generation,
           domain_version_state,
           domain_algorithm,
           wrapped_domain_key,
           vault_key_generation,
           vault_version_state
         ],
         binding,
         entry
       ) do
    material = %{
      object_id: load_uuid(object_id),
      vault_id: load_uuid(vault_id),
      key_domain_id: load_uuid(key_domain_id),
      classification: enum_atom(classification),
      lookup_digest: lookup_digest,
      ciphertext_hash: ciphertext_hash,
      plaintext_byte_size: plaintext_byte_size,
      ciphertext_byte_size: ciphertext_byte_size,
      format_version: format_version,
      lifecycle: enum_atom(lifecycle),
      object_generation: object_generation,
      envelope_classification: enum_atom(envelope_classification),
      envelope_algorithm: envelope_algorithm,
      wrapped_dek: wrapped_dek,
      domain_id: load_uuid(domain_id),
      domain_classification: enum_atom(domain_classification),
      domain_kind: domain_kind,
      domain_state: enum_atom(domain_state),
      domain_key_version_id: load_uuid(domain_key_version_id),
      vault_key_version_id: load_uuid(vault_key_version_id),
      domain_key_generation: domain_key_generation,
      domain_version_state: enum_atom(domain_version_state),
      domain_algorithm: domain_algorithm,
      wrapped_domain_key: wrapped_domain_key,
      vault_key_generation: vault_key_generation,
      vault_version_state: enum_atom(vault_version_state)
    }

    if valid_material?(material, binding, entry),
      do: {:ok, material},
      else: integrity_failure()
  rescue
    _exception -> integrity_failure()
  end

  defp normalize_material(_row, _binding, _entry), do: unavailable()

  defp valid_material?(material, binding, entry) do
    material.object_id == entry.asset_object_id and
      material.vault_id == binding.vault_id and
      material.key_domain_id == entry.key_domain_id and
      material.domain_id == entry.key_domain_id and
      material.vault_key_version_id == binding.vault_key_version_id and
      material.vault_key_generation == binding.vault_key_generation and
      material.classification == entry.classification and
      material.envelope_classification == entry.classification and
      material.domain_classification == entry.classification and
      material.lookup_digest == entry.lookup_digest and
      material.ciphertext_hash == entry.ciphertext_hash and
      material.ciphertext_byte_size == entry.ciphertext_byte_size and
      is_integer(material.plaintext_byte_size) and material.plaintext_byte_size >= 0 and
      is_integer(material.format_version) and material.format_version > 0 and
      material.lifecycle == :available and
      material.domain_kind == "content" and material.domain_state == :active and
      material.domain_version_state == :active and material.vault_version_state == :active and
      material.envelope_algorithm == "aes_256_gcm" and
      material.domain_algorithm == "aes_256_gcm" and
      is_integer(material.object_generation) and material.object_generation > 0 and
      is_integer(material.domain_key_generation) and material.domain_key_generation > 0 and
      is_binary(material.wrapped_dek) and material.wrapped_dek != "" and
      is_binary(material.wrapped_domain_key) and material.wrapped_domain_key != ""
  end

  defp validate_search_binding(binding) do
    with true <- Enum.sort(Map.keys(binding)) == Enum.sort(@search_binding_keys),
         {:ok, _manifest_id} <- canonical_uuid(binding.manifest_id),
         {:ok, _vault_id} <- canonical_uuid(binding.vault_id) do
      :ok
    else
      _invalid -> invalid()
    end
  end

  defp rebuild_locked(repo, vault_id) do
    with {:ok, %{rows: rows}} <-
           SQL.query(
             repo,
             "SELECT id FROM content.assets WHERE vault_id = $1 ORDER BY id",
             [Ecto.UUID.dump!(vault_id)]
           ),
         {:ok, asset_ids} <- load_uuid_rows(rows),
         {_, nil} <-
           repo.delete_all(from_document_in_vault(vault_id)),
         :ok <- rebuild_assets(repo, asset_ids),
         {:ok, result_rows} <- search_result_rows(repo, vault_id) do
      {:ok,
       %SearchSummary{
         projection: "postgres_metadata_v1",
         document_count: length(result_rows),
         result_sha256:
           :crypto.hash(:sha256, :erlang.term_to_binary(result_rows, [:deterministic]))
       }}
    else
      {:error, %Error{}} = error -> error
      {:error, _reason} -> unavailable()
      _malformed -> unavailable()
    end
  end

  defp from_document_in_vault(vault_id) do
    import Ecto.Query

    from document in Singularity.Storage.Schema.Content.AssetSearchDocument,
      where: document.vault_id == ^vault_id
  end

  defp rebuild_assets(repo, asset_ids) do
    Enum.reduce_while(asset_ids, :ok, fn asset_id, :ok ->
      case AssetRepository.rebuild_search_document(repo, asset_id) do
        :ok -> {:cont, :ok}
        {:error, %Error{}} = error -> {:halt, error}
        _malformed -> {:halt, unavailable()}
      end
    end)
  end

  defp search_result_rows(repo, vault_id) do
    case SQL.query(
           repo,
           """
           SELECT
             asset_id::text,
             resource_version_id::text,
             classification,
             state,
             detected_media_type,
             search_vector::text
           FROM content.asset_search_documents
           WHERE vault_id = $1
           ORDER BY asset_id
           """,
           [Ecto.UUID.dump!(vault_id)]
         ) do
      {:ok, %{rows: rows}} when is_list(rows) -> {:ok, rows}
      {:ok, _malformed} -> unavailable()
      {:error, _reason} -> unavailable()
    end
  end

  defp validate_completion(command) do
    with true <- Enum.sort(Map.keys(command)) == Enum.sort(@completion_keys),
         {:ok, _vault_id} <- canonical_uuid(command.vault_id),
         {:ok, _manifest_id} <- canonical_uuid(command.manifest_id),
         {:ok, _principal_id} <- canonical_uuid(command.integrity_principal_id),
         {:ok, _correlation_id} <- canonical_uuid(command.correlation_id),
         true <-
           command.correlation_id ==
             restore_identity(command, "integrity.audit_completed:correlation"),
         true <- is_integer(command.object_count) and command.object_count >= 0,
         true <- command.operation == "integrity.audit_completed",
         true <- digest?(command.ciphertext_inventory_sha256),
         true <- digest?(command.plaintext_inventory_sha256),
         true <- digest?(command.search_rebuild_sha256) do
      :ok
    else
      _invalid -> invalid()
    end
  end

  defp insert_completion(repo, command) do
    event_id = restore_identity(command, "integrity.audit_completed:event")
    metadata = completion_metadata(command)

    params = [
      Ecto.UUID.dump!(event_id),
      Ecto.UUID.dump!(command.vault_id),
      Ecto.UUID.dump!(command.integrity_principal_id),
      Ecto.UUID.dump!(command.correlation_id),
      Ecto.UUID.dump!(command.manifest_id),
      metadata,
      DateTime.utc_now()
    ]

    case SQL.query(
           repo,
           """
           INSERT INTO audit.events (
             id, vault_id, actor_kind, principal_id, operation, result,
             classification, correlation_id, target_type, target_id, metadata,
             occurred_at, inserted_at
           )
           VALUES (
             $1, $2, 'system', $3, 'integrity.audit_completed', 'completed',
             'restricted', $4, 'backup_manifest', $5, $6, $7, $7
           )
           ON CONFLICT (id) DO NOTHING
           RETURNING id
           """,
           params
         ) do
      {:ok, %{rows: [[returned_id]]}} ->
        if load_uuid(returned_id) == event_id, do: :ok, else: unavailable()

      {:ok, %{rows: []}} ->
        verify_completion(repo, command, event_id, metadata)

      {:ok, _malformed} ->
        unavailable()

      {:error, _reason} ->
        unavailable()
    end
  end

  defp verify_completion(repo, command, event_id, expected_metadata) do
    case SQL.query(
           repo,
           """
           SELECT
             vault_id, actor_kind, principal_id, operation, result, classification,
             correlation_id, target_type, target_id, metadata
           FROM audit.events
           WHERE id = $1
           """,
           [Ecto.UUID.dump!(event_id)]
         ) do
      {:ok,
       %{
         rows: [
           [
             vault_id,
             "system",
             principal_id,
             "integrity.audit_completed",
             "completed",
             "restricted",
             correlation_id,
             "backup_manifest",
             manifest_id,
             metadata
           ]
         ]
       }} ->
        if load_uuid(vault_id) == command.vault_id and
             load_uuid(principal_id) == command.integrity_principal_id and
             load_uuid(correlation_id) == command.correlation_id and
             load_uuid(manifest_id) == command.manifest_id and
             metadata == expected_metadata do
          :ok
        else
          conflict()
        end

      {:ok, _mismatch} ->
        conflict()

      {:error, _reason} ->
        unavailable()
    end
  end

  defp completion_metadata(command) do
    %{
      "ciphertext_inventory_sha256" => hex(command.ciphertext_inventory_sha256),
      "object_count" => command.object_count,
      "plaintext_inventory_sha256" => hex(command.plaintext_inventory_sha256),
      "search_rebuild_sha256" => hex(command.search_rebuild_sha256)
    }
  end

  defp restore_identity(command, label) do
    digest =
      :crypto.hash(:sha256, [
        "singularity:restore:audit:v1\0",
        label,
        0,
        Ecto.UUID.dump!(command.manifest_id),
        Ecto.UUID.dump!(command.vault_id)
      ])

    <<prefix::binary-size(6), version_byte, middle_byte, variant_byte, suffix::binary-size(7),
      _rest::binary>> = digest

    version_byte = Bitwise.bor(Bitwise.band(version_byte, 0x0F), 0x50)
    variant_byte = Bitwise.bor(Bitwise.band(variant_byte, 0x3F), 0x80)

    Ecto.UUID.load!(<<prefix::binary, version_byte, middle_byte, variant_byte, suffix::binary>>)
  end

  defp owner_transaction(repo, callback) do
    case repo.transaction(fn ->
           with {:ok, _result} <- SQL.query(repo, "SET LOCAL ROLE singularity_table_owner", []),
                result <- callback.() do
             result
           else
             _failure -> unavailable()
           end
         end) do
      {:ok, result} -> result
      {:error, %Error{}} = error -> error
      {:error, _reason} -> unavailable()
      _malformed -> unavailable()
    end
  end

  defp load_uuid_rows(rows) when is_list(rows) do
    Enum.reduce_while(rows, {:ok, []}, fn
      [raw_id], {:ok, ids} ->
        case load_uuid(raw_id) do
          id when is_binary(id) -> {:cont, {:ok, [id | ids]}}
          _invalid -> {:halt, unavailable()}
        end

      _row, _ids ->
        {:halt, unavailable()}
    end)
    |> case do
      {:ok, ids} -> {:ok, Enum.reverse(ids)}
      {:error, %Error{}} = error -> error
    end
  end

  defp safe_apply(module, function, arguments) do
    apply(module, function, arguments)
  rescue
    _exception -> unavailable()
  catch
    _kind, _reason -> unavailable()
  end

  defp canonical_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, ^value} -> {:ok, value}
      _invalid -> backup_invalid()
    end
  end

  defp canonical_uuid(_value), do: backup_invalid()

  defp dump_uuid(value) do
    case Ecto.UUID.dump(value) do
      {:ok, <<_::binary-size(16)>> = uuid} -> {:ok, uuid}
      _invalid -> backup_invalid()
    end
  end

  defp load_uuid(<<_::binary-size(16)>> = value), do: Ecto.UUID.load!(value)
  defp load_uuid(value) when is_binary(value), do: Ecto.UUID.cast!(value)

  defp enum_atom(value) when is_atom(value), do: value
  defp enum_atom(value) when is_binary(value), do: String.to_existing_atom(value)

  defp digest?(value), do: is_binary(value) and byte_size(value) == 32
  defp hex(value), do: Base.encode16(value, case: :lower)

  defp secure_compare(<<_::binary-size(32)>> = left, <<_::binary-size(32)>> = right),
    do: :crypto.hash_equals(left, right)

  defp public_error(%Error{code: code, retryable?: retryable?}) do
    Error.new(code, retryable?: retryable?)
  end

  defp invalid, do: {:error, Error.new(:invalid)}
  defp backup_invalid, do: {:error, Error.new(:backup_invalid)}
  defp conflict, do: {:error, Error.new(:conflict)}
  defp integrity_failure, do: {:error, Error.new(:integrity_failure)}
  defp unavailable, do: {:error, Error.new(:storage_unavailable, retryable?: true)}
end
