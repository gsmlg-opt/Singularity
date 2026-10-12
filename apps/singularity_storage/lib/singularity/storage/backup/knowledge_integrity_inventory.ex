defmodule Singularity.Storage.Backup.KnowledgeIntegrityInventory do
  @moduledoc """
  V3-only bridge between original authenticated inventory and UUID lease inventory.

  Original references and saga commitments are never rewritten. Material is
  returned unchanged by the established loader after original evidence is
  revalidated on the same migration connection and repeatable-read snapshot.
  """

  alias Singularity.Core.{DocumentFragment, DocumentSource, Error, SourceLocator}
  alias Singularity.Storage.Backup.{IntegrityAudit, Restorer}
  alias Singularity.Storage.Crypto.Format
  alias Singularity.Storage.Local.PathGuard
  alias Singularity.Storage.LocalFilesystemAdapter
  alias Singularity.Storage.SafeSQL, as: SQL

  defmodule Context do
    @moduledoc false
    @enforce_keys [
      :repo,
      :storage,
      :original,
      :projected,
      :binding,
      :manifest_hash,
      :manifest_tag,
      :inventory_hash,
      :root_hash
    ]
    @derive {Inspect, only: []}
    defstruct @enforce_keys
  end

  @binding_keys ~w(manifest_id vault_id vault_key_version_id vault_key_generation)a
  @document_binding_keys ~w(manifest_id vault_id)a
  @required_objects """
  SELECT a.asset_object_id AS id
  FROM content.assets a
  JOIN content.asset_objects o ON o.id=a.asset_object_id AND o.vault_id=a.vault_id
  WHERE a.vault_id=$1 AND a.state NOT IN ('pending_delete','deleted')
    AND o.lifecycle='available'
  UNION
  SELECT d.source_object_id AS id FROM content.document_versions d WHERE d.vault_id=$1
  """

  @spec project(term(), map()) :: {:ok, [map()]} | {:error, Error.t()}
  def project(storage, %{logical_version: 3, vault_id: owner, object_inventory: original} = cut)
      when is_list(original) do
    with true <- canonical_uuid?(owner),
         true <- valid_storage?(storage),
         true <- not Map.has_key?(cut, :object_count) or cut.object_count === length(original),
         projected = Enum.map(original, &Map.replace!(&1, :storage_ref, &1.asset_object_id)),
         {:ok, _digest} <- IntegrityAudit.inventory_sha256(owner, projected),
         true <- unique_physical_objects?(projected),
         :ok <- validate_references(storage, original) do
      {:ok, projected}
    else
      _invalid -> invalid()
    end
  rescue
    _exception -> invalid()
  catch
    _kind, _reason -> invalid()
  end

  def project(_storage, _cut), do: invalid()

  @spec prepare(module(), term(), map()) :: {:ok, map()} | {:error, Error.t()}
  def prepare(repo, storage, %{__struct__: Restorer.Imported} = imported) do
    with {:ok, inventory} <- project(storage, imported.cut),
         true <- imported.cut.object_inventory === imported.object_inventory,
         {:ok, context} <- context(repo, storage, imported, inventory) do
      consistent_transaction(repo, context.binding.vault_id, fn ->
        with :ok <- verify_saga(context),
             :ok <- verify_closure(context) do
          {:ok, %{inventory: inventory, material_loader: {__MODULE__, context}}}
        end
      end)
    else
      {:error, %Error{}} = error -> error
      _invalid -> invalid()
    end
  rescue
    _exception -> unavailable()
  catch
    _kind, _reason -> unavailable()
  end

  def prepare(_repo, _storage, _imported), do: invalid()

  @spec load_plaintext_material(term(), map(), map()) :: {:ok, map()} | {:error, Error.t()}
  def load_plaintext_material(%Context{} = context, binding, entry)
      when is_map(binding) and is_map(entry) do
    with true <- valid_binding?(binding) and binding === context.binding,
         position when is_integer(position) and position >= 0 <-
           Map.get(entry, :inventory_position),
         true <- is_tuple(context.original) and is_tuple(context.projected),
         true <- tuple_size(context.original) == tuple_size(context.projected),
         true <- position < tuple_size(context.projected),
         true <- entry === elem(context.projected, position),
         original = elem(context.original, position),
         {:ok, root_hash} <- destination_root_hash(context.storage),
         true <- root_hash === context.root_hash do
      consistent_transaction(context.repo, binding.vault_id, fn ->
        with :ok <- verify_saga(context),
             :ok <- verify_original_entry(context, original) do
          IntegrityAudit.load_plaintext_material(context.repo, binding, entry)
        end
      end)
    else
      {:error, %Error{}} = error -> error
      _invalid -> invalid()
    end
  rescue
    _exception -> invalid()
  catch
    _kind, _reason -> invalid()
  end

  def load_plaintext_material(_context, _binding, _entry), do: invalid()

  @doc "Validates retained Document sources against already authenticated original evidence."
  @spec verify_document_sources(module(), map(), [map()], [map()]) ::
          :ok | {:error, Error.t()}
  def verify_document_sources(repo, binding, original, plaintext_hashes)
      when is_atom(repo) and repo not in [nil, false, true] and is_map(binding) and
             is_list(original) and is_list(plaintext_hashes) do
    with true <- valid_document_binding?(binding),
         :ok <- validate_document_inventory(binding.vault_id, original),
         true <- valid_plaintext_hashes?(original, plaintext_hashes) do
      # This is only the metadata available to /4, not a fabricated material
      # Context claiming independently expected manifest hash, tag or root.
      closure = %{repo: repo, binding: binding, original: List.to_tuple(original)}
      entries = Map.new(original, &{&1.asset_object_id, &1})
      hashes = Map.new(plaintext_hashes, &{&1.asset_object_id, &1.sha256})

      case consistent_transaction(repo, binding.vault_id, fn ->
             with :ok <- verify_document_saga(repo, binding, original),
                  :ok <- verify_closure(closure),
                  :ok <- verify_document_pins(repo, binding.vault_id, entries, hashes),
                  :ok <- verify_ready_fragments(repo, binding.vault_id) do
               {:ok, :ok}
             end
           end) do
        {:ok, :ok} -> :ok
        {:error, %Error{}} = error -> error
      end
    else
      {:error, %Error{}} = error -> error
      _invalid -> invalid()
    end
  rescue
    _exception -> unavailable()
  catch
    _kind, _reason -> unavailable()
  end

  def verify_document_sources(_repo, _binding, _original, _plaintext_hashes), do: invalid()

  @doc false
  @spec validate_plaintext_size(term(), term()) :: :ok | {:error, Error.t()}
  def validate_plaintext_size(plaintext, ciphertext)
      when is_integer(plaintext) and plaintext >= 0 and is_integer(ciphertext) and
             ciphertext >= 0 do
    chunks = div(plaintext + Format.chunk_size() - 1, Format.chunk_size())
    expected = Format.header_size() + plaintext + 24 * chunks + 68

    if chunks <= Format.max_data_counter() + 1 and ciphertext == expected,
      do: :ok,
      else: invalid()
  end

  def validate_plaintext_size(_plaintext, _ciphertext), do: invalid()

  defp valid_document_binding?(binding) do
    Enum.sort(Map.keys(binding)) == Enum.sort(@document_binding_keys) and
      canonical_uuid?(binding.manifest_id) and canonical_uuid?(binding.vault_id)
  end

  defp validate_document_inventory(owner, original) do
    projected = Enum.map(original, &Map.replace!(&1, :storage_ref, &1.asset_object_id))

    with {:ok, _digest} <- IntegrityAudit.inventory_sha256(owner, projected),
         true <- unique_physical_objects?(projected),
         ids = Enum.map(original, & &1.asset_object_id),
         true <- ids === Enum.sort(ids),
         true <-
           Enum.all?(original, fn entry ->
             is_integer(entry.inventory_position) and document_reference?(entry)
           end) do
      :ok
    else
      _invalid -> invalid()
    end
  rescue
    _exception -> invalid()
  catch
    _kind, _reason -> invalid()
  end

  defp document_reference?(%{asset_object_id: id, storage_ref: id}), do: true

  defp document_reference?(entry) do
    hex = Base.encode16(entry.lookup_digest, case: :lower)

    entry.storage_ref ===
      "objects/#{entry.vault_id}/#{entry.key_domain_id}/hmac-sha256/#{binary_part(hex, 0, 2)}/#{hex}"
  end

  defp valid_plaintext_hashes?(original, hashes) do
    length(original) == length(hashes) and
      Enum.all?(Enum.zip(original, hashes), fn
        {entry, %{asset_object_id: id, sha256: hash} = pair} when map_size(pair) == 2 ->
          id === entry.asset_object_id and digest?(hash)

        _invalid ->
          false
      end)
  end

  defp verify_document_saga(repo, binding, original) do
    expected = [
      binding.manifest_id,
      binding.vault_id,
      length(original),
      :crypto.hash(:sha256, :erlang.term_to_binary(original, [:deterministic])),
      "imported"
    ]

    case query(
           repo,
           """
           SELECT manifest_id::text,vault_id::text,object_count,inventory_hash,state
           FROM audit.restore_import_sagas WHERE singleton
           """,
           []
         ) do
      {:ok, %{rows: [^expected]}} -> :ok
      {:ok, _mismatch} -> conflict()
      {:error, %Error{}} = error -> error
    end
  end

  defp verify_document_pins(repo, owner, entries, hashes) do
    statement = """
    SELECT d.source_asset_id::text,d.source_resource_id::text,d.source_resource_version_id::text,
      d.source_object_id::text,d.vault_id::text,d.source_digest,d.source_byte_size,d.media_type,
      o.plaintext_byte_size,o.format_version,
      (d.classification='private' AND r.id IS NOT NULL AND v.id IS NOT NULL
        AND sr.id IS NOT NULL AND sv.id IS NOT NULL AND a.id IS NOT NULL
        AND ra.asset_id IS NOT NULL AND o.id IS NOT NULL
        AND d.resource_id<>d.source_resource_id
        AND d.resource_version_id<>d.source_resource_version_id
        AND (a.asset_object_id IS NULL OR a.asset_object_id=d.source_object_id)
        AND (SELECT count(*) FROM content.assets x
          WHERE x.resource_version_id=d.source_resource_version_id AND x.vault_id=d.vault_id)=1)
    FROM content.document_versions d
    LEFT JOIN content.resources r ON r.id=d.resource_id AND r.vault_id=d.vault_id
      AND r.classification=d.classification AND r.kind='document'
    LEFT JOIN content.resource_versions v ON v.id=d.resource_version_id
      AND v.resource_id=d.resource_id AND v.vault_id=d.vault_id AND v.classification=d.classification
    LEFT JOIN content.resources sr ON sr.id=d.source_resource_id AND sr.vault_id=d.vault_id
      AND sr.classification=d.classification AND sr.kind='asset'
    LEFT JOIN content.resource_versions sv ON sv.id=d.source_resource_version_id
      AND sv.resource_id=d.source_resource_id AND sv.vault_id=d.vault_id AND sv.classification=d.classification
    LEFT JOIN content.assets a ON a.id=d.source_asset_id AND a.resource_version_id=d.source_resource_version_id
      AND a.vault_id=d.vault_id AND a.classification=d.classification
    LEFT JOIN content.resource_assets ra ON ra.resource_version_id=d.source_resource_version_id
      AND ra.asset_id=d.source_asset_id AND ra.vault_id=d.vault_id AND ra.classification=d.classification
    LEFT JOIN content.asset_objects o ON o.id=d.source_object_id AND o.vault_id=d.vault_id
      AND o.classification=d.classification AND o.lifecycle='available' AND o.deleted_at IS NULL
    WHERE d.vault_id=$1 ORDER BY d.resource_version_id
    """

    SQL.stream(repo, statement, [Ecto.UUID.dump!(owner)], max_rows: 1)
    |> Enum.reduce_while(:ok, fn %{rows: rows}, :ok ->
      case verify_document_rows(rows, entries, hashes) do
        :ok -> {:cont, :ok}
        {:error, %Error{}} = error -> {:halt, error}
      end
    end)
  end

  defp verify_document_rows(rows, entries, hashes) do
    Enum.reduce_while(rows, :ok, fn row, :ok ->
      case verify_document_row(row, entries, hashes) do
        :ok -> {:cont, :ok}
        {:error, %Error{}} = error -> {:halt, error}
      end
    end)
  end

  defp verify_document_row(
         [
           asset,
           resource,
           version,
           object,
           owner,
           digest,
           size,
           media,
           object_size,
           format,
           true
         ],
         entries,
         hashes
       ) do
    with {:ok, _source} <-
           DocumentSource.new(%{
             asset_id: asset,
             resource_id: resource,
             resource_version_id: version,
             object_id: object,
             owner_scope_id: owner,
             classification: :private,
             digest: digest,
             byte_size: size,
             media_type: media
           }),
         {:ok, entry} <- Map.fetch(entries, object),
         true <- entry.vault_id === owner and entry.classification === :private,
         {:ok, ^digest} <- Map.fetch(hashes, object),
         true <- object_size === size and format === Format.format_version(),
         :ok <- validate_plaintext_size(size, entry.ciphertext_byte_size) do
      :ok
    else
      _mismatch -> invalid()
    end
  end

  defp verify_document_row(_row, _entries, _hashes), do: invalid()

  defp verify_ready_fragments(repo, owner) do
    # LEFT JOIN from independently selected ready versions keeps an absent
    # fragment set visible. Only one version's incremental hash is retained.
    statement = """
    SELECT d.resource_version_id::text,d.resource_id::text,d.vault_id::text,
      d.classification,d.media_type,d.extracted_text_digest,
      f.id,f.resource_id::text,f.resource_version_id::text,f.vault_id::text,
      f.classification,f.ordinal,f.text,f.digest,f.locator
    FROM content.document_versions d LEFT JOIN content.document_fragments f
      ON f.resource_version_id=d.resource_version_id
    WHERE d.vault_id=$1 AND d.state='ready'
    ORDER BY d.resource_version_id,f.ordinal
    """

    SQL.stream(repo, statement, [Ecto.UUID.dump!(owner)], max_rows: 1)
    |> Enum.reduce_while({:ok, nil}, fn %{rows: rows}, {:ok, state} ->
      case verify_fragment_rows(rows, state) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, %Error{}} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, state} -> finish_document_digest(state)
      {:error, %Error{}} = error -> error
    end
  end

  defp verify_fragment_rows(rows, state) do
    Enum.reduce_while(rows, {:ok, state}, fn row, {:ok, state} ->
      case verify_fragment_row(row, state) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, %Error{}} = error -> {:halt, error}
      end
    end)
  end

  defp verify_fragment_row(
         [
           version,
           resource,
           owner,
           "private",
           media,
           expected,
           id,
           resource,
           version,
           owner,
           "private",
           ordinal,
           text,
           digest,
           locator
         ],
         previous
       ) do
    with {:ok, state} <- document_digest_state(previous, version, expected),
         {:ok, fragment} <-
           DocumentFragment.new(%{
             resource_id: resource,
             resource_version_id: version,
             owner_scope_id: owner,
             classification: :private,
             ordinal: ordinal,
             text: text,
             digest: digest,
             locator: locator,
             fragment_id: id
           }),
         true <- SourceLocator.to_map(fragment.locator) === locator,
         true <- fragment.locator.kind in ["fragment", locator_kind(media)],
         true <- ordinal === state.count and state.count < 4096,
         bytes = state.bytes + byte_size(fragment.text),
         true <- bytes <= 16_777_216 do
      {:ok,
       %{
         state
         | hash: :crypto.hash_update(state.hash, fragment.text),
           count: state.count + 1,
           bytes: bytes
       }}
    else
      _mismatch -> invalid()
    end
  end

  defp verify_fragment_row(_row, _state), do: invalid()

  defp document_digest_state(%{version: version, expected: expected} = state, version, expected),
    do: {:ok, state}

  defp document_digest_state(previous, version, expected) do
    with :ok <- finish_document_digest(previous),
         true <- canonical_uuid?(version) and digest?(expected) do
      {:ok,
       %{
         version: version,
         expected: expected,
         hash: :crypto.hash_init(:sha256),
         count: 0,
         bytes: 0
       }}
    else
      _mismatch -> invalid()
    end
  end

  defp finish_document_digest(nil), do: :ok

  defp finish_document_digest(state) do
    if state.count in 1..4096 and state.bytes in 1..16_777_216 and
         :crypto.hash_final(state.hash) === state.expected,
       do: :ok,
       else: invalid()
  end

  defp locator_kind("application/pdf"), do: "pdf"
  defp locator_kind("text/markdown"), do: "markdown"
  defp locator_kind("text/plain"), do: "text"
  defp locator_kind(_media), do: nil

  defp context(repo, storage, imported, inventory) do
    binding = %{
      manifest_id: imported.manifest.manifest_id,
      vault_id: imported.cut.vault_id,
      vault_key_version_id: imported.owner.vault_key_version_id,
      vault_key_generation: imported.owner.vault_key_generation
    }

    with true <- is_atom(repo) and repo not in [nil, false, true],
         true <- valid_binding?(binding),
         true <- binding.manifest_id === imported.cut.manifest_id,
         true <- digest?(imported.manifest_hash),
         true <- is_binary(imported.manifest_tag) and byte_size(imported.manifest_tag) == 16,
         {:ok, root_hash} <- destination_root_hash(storage) do
      {:ok,
       %Context{
         repo: repo,
         storage: storage,
         original: List.to_tuple(imported.object_inventory),
         projected: List.to_tuple(inventory),
         binding: binding,
         manifest_hash: imported.manifest_hash,
         manifest_tag: imported.manifest_tag,
         inventory_hash:
           :crypto.hash(
             :sha256,
             :erlang.term_to_binary(imported.object_inventory, [:deterministic])
           ),
         root_hash: root_hash
       }}
    else
      _invalid -> invalid()
    end
  rescue
    _exception -> invalid()
  end

  defp validate_references(storage, original) do
    Enum.reduce_while(original, :ok, fn entry, :ok ->
      case validate_reference(storage, entry) do
        :ok -> {:cont, :ok}
        {:error, %Error{}} = error -> {:halt, error}
      end
    end)
  end

  defp validate_reference(_storage, %{asset_object_id: id, storage_ref: id}), do: :ok

  defp validate_reference(storage, entry) do
    with {:ok, context} <- local_context(storage),
         {:ok, path} <-
           PathGuard.object_path(
             Map.get(context, :root),
             entry.vault_id,
             entry.key_domain_id,
             Base.encode16(entry.lookup_digest, case: :lower)
           ),
         true <- entry.storage_ref === Path.relative_to(path, Path.expand(context.root)) do
      :ok
    else
      _invalid -> invalid()
    end
  end

  defp unique_physical_objects?(inventory) do
    length(Enum.uniq_by(inventory, &{&1.vault_id, &1.key_domain_id, &1.lookup_digest})) ==
      length(inventory)
  end

  defp valid_storage?({adapter, context}) when is_atom(adapter) and is_map(context),
    do: Code.ensure_loaded?(adapter) and function_exported?(adapter, :stat, 2)

  defp valid_storage?(%{adapter: adapter, context: context}),
    do: valid_storage?({adapter, context})

  defp valid_storage?(_storage), do: false

  defp local_context({LocalFilesystemAdapter, context}) when is_map(context),
    do: {:ok, context}

  defp local_context(%{adapter: LocalFilesystemAdapter, context: context}) when is_map(context),
    do: {:ok, context}

  defp local_context(_storage), do: invalid()

  defp storage_context({adapter, context}) when is_atom(adapter) and is_map(context) do
    if valid_storage?({adapter, context}), do: {:ok, context}, else: invalid()
  end

  defp storage_context(%{adapter: adapter, context: context}),
    do: storage_context({adapter, context})

  defp storage_context(_storage), do: invalid()

  defp destination_root_hash(storage) do
    with {:ok, context} <- storage_context(storage),
         root when is_binary(root) and byte_size(root) > 0 <- Map.get(context, :root),
         false <- String.contains?(root, <<0>>),
         expanded = Path.expand(root),
         :ok <- PathGuard.assert_safe_path(expanded, expanded) do
      {:ok, :crypto.hash(:sha256, expanded)}
    else
      _invalid -> invalid()
    end
  end

  defp verify_saga(context) do
    expected = [
      context.binding.manifest_id,
      context.binding.vault_id,
      context.manifest_hash,
      context.manifest_tag,
      context.inventory_hash,
      context.root_hash,
      tuple_size(context.original),
      "imported"
    ]

    case query(
           context.repo,
           """
           SELECT manifest_id::text,vault_id::text,manifest_hash,manifest_tag,
             inventory_hash,destination_root_hash,object_count,state
           FROM audit.restore_import_sagas WHERE singleton
           """,
           []
         ) do
      {:ok, %{rows: [^expected]}} -> :ok
      {:ok, _mismatch} -> conflict()
      {:error, %Error{}} = error -> error
    end
  end

  defp verify_closure(context) do
    expected_count = tuple_size(context.original)

    with {:ok, %{rows: [[^expected_count]]}} <-
           query(context.repo, "SELECT count(*) FROM (#{@required_objects}) required", [
             Ecto.UUID.dump!(context.binding.vault_id)
           ]) do
      context.original
      |> Tuple.to_list()
      |> Enum.reduce_while(:ok, fn entry, :ok ->
        case verify_original_entry(context, entry) do
          :ok -> {:cont, :ok}
          {:error, %Error{}} = error -> {:halt, error}
        end
      end)
    else
      {:error, %Error{}} = error -> error
      _mismatch -> conflict()
    end
  end

  defp verify_original_entry(context, entry) do
    expected = [
      entry.asset_object_id,
      entry.vault_id,
      entry.key_domain_id,
      Atom.to_string(entry.classification),
      entry.lookup_digest,
      entry.ciphertext_hash,
      entry.ciphertext_byte_size,
      entry.storage_ref
    ]

    case query(
           context.repo,
           """
           SELECT o.id::text,o.vault_id::text,o.key_domain_id::text,o.classification,
             o.lookup_digest,o.ciphertext_hash,o.ciphertext_byte_size,o.storage_ref
           FROM content.asset_objects o
           WHERE o.vault_id=$1 AND o.id=$2 AND o.lifecycle='available' AND o.deleted_at IS NULL
             AND o.id IN (#{@required_objects})
           """,
           [Ecto.UUID.dump!(context.binding.vault_id), Ecto.UUID.dump!(entry.asset_object_id)]
         ) do
      {:ok, %{rows: [^expected]}} -> :ok
      {:ok, _mismatch} -> conflict()
      {:error, %Error{}} = error -> error
    end
  end

  defp consistent_transaction(repo, owner, callback) do
    if repo.in_transaction?() do
      invalid()
    else
      case repo.transaction(
             fn ->
               with {:ok, _} <-
                      query(repo, "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ", []),
                    {:ok, _} <- query(repo, "SET LOCAL ROLE singularity_table_owner", []),
                    {:ok, %{rows: [["singularity_table_owner", "singularity_migration", true]]}} <-
                      query(
                        repo,
                        "SELECT current_user,session_user,pg_has_role(session_user,'singularity_table_owner','SET')",
                        []
                      ),
                    {:ok, _} <-
                      query(repo, "SELECT set_config('singularity.vault_id',$1,true)", [owner]),
                    {:ok, result} <- callback.() do
                 {:ok, result}
               else
                 {:error, %Error{} = error} -> repo.rollback(error)
                 _invalid -> repo.rollback(Error.new(:backup_invalid))
               end
             end,
             isolation: :repeatable_read,
             log: false,
             telemetry_event: nil
           ) do
        {:ok, {:ok, result}} ->
          {:ok, result}

        {:error, %Error{} = error} ->
          {:error, Error.new(error.code, retryable?: error.retryable?)}

        _failure ->
          unavailable()
      end
    end
  rescue
    _exception -> unavailable()
  catch
    _kind, _reason -> unavailable()
  end

  defp query(repo, statement, parameters) do
    case SQL.query(repo, statement, parameters) do
      {:ok, result} -> {:ok, result}
      _failure -> unavailable()
    end
  end

  defp valid_binding?(binding) do
    is_map(binding) and Enum.sort(Map.keys(binding)) == Enum.sort(@binding_keys) and
      canonical_uuid?(binding.manifest_id) and canonical_uuid?(binding.vault_id) and
      canonical_uuid?(binding.vault_key_version_id) and is_integer(binding.vault_key_generation) and
      binding.vault_key_generation > 0
  end

  defp canonical_uuid?(value) when is_binary(value), do: Ecto.UUID.cast(value) == {:ok, value}
  defp canonical_uuid?(_value), do: false
  defp digest?(value), do: is_binary(value) and byte_size(value) == 32
  defp invalid, do: {:error, Error.new(:backup_invalid)}
  defp conflict, do: {:error, Error.new(:conflict)}
  defp unavailable, do: {:error, Error.new(:storage_unavailable, retryable?: true)}
end
