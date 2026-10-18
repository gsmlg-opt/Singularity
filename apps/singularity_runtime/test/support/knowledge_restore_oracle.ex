defmodule Singularity.Runtime.KnowledgeRestoreOracle do
  @moduledoc false

  alias Singularity.Core.{Error, SourceLocator}
  alias Singularity.Runtime.{Api, DownloadLease, KeyCustodian, KeyLeaseSupervisor}
  alias Singularity.Runtime.DTO.{KnowledgeSearchPage, KnowledgeSearchResult, KnowledgeSource}

  @selector_fields [:kind, :resource_id, :resource_version_id, :fragment_id]

  # Literal SQL-row mapping, independent of Exporter/project/prepare.
  def original_inventory!(rows) do
    rows
    |> Enum.sort_by(& &1["id"])
    |> Enum.with_index()
    |> Enum.map(fn {row, position} ->
      %{
        asset_object_id: row["id"],
        vault_id: row["vault_id"],
        key_domain_id: row["key_domain_id"],
        classification: String.to_existing_atom(row["classification"]),
        lookup_digest: row["lookup_digest"],
        ciphertext_hash: row["ciphertext_hash"],
        ciphertext_byte_size: row["ciphertext_byte_size"],
        storage_ref: row["storage_ref"],
        inventory_position: position
      }
    end)
  end

  def projected_inventory!(source) do
    Enum.map(source.original_inventory, &Map.replace!(&1, :storage_ref, &1.asset_object_id))
  end

  # Both opaque spellings use the actual adapter and full native lookup context.
  # The returned private witness deliberately excludes access-time metadata.
  def reference_witness!(root, entry) do
    alias Singularity.Storage.{LocalFilesystemAdapter, Local.PathGuard}

    {:ok, path} =
      PathGuard.object_path(
        root,
        entry.vault_id,
        entry.key_domain_id,
        Base.encode16(entry.lookup_digest, case: :lower)
      )

    canonical_ref = Path.relative_to(path, root)

    context = %{
      root: root,
      vault_namespace: entry.vault_id,
      domain_namespace: entry.key_domain_id,
      lookup_digest: Base.encode16(entry.lookup_digest, case: :lower),
      ciphertext_hash: entry.ciphertext_hash
    }

    witnesses =
      for spelling <- [entry.asset_object_id, canonical_ref] do
        ref = %Singularity.Core.ObjectRef{object_id: spelling}
        stat = expect_ok!(LocalFilesystemAdapter.stat(context, ref), "alias ciphertext stat")
        handle = expect_ok!(LocalFilesystemAdapter.open(context, ref), "alias ciphertext open")

        bytes =
          expect_ok!(
            LocalFilesystemAdapter.read_range(context, handle, 0..(stat.byte_size - 1)),
            "alias ciphertext read"
          )

        require!(
          stat.byte_size == entry.ciphertext_byte_size and
            stat.ciphertext_hash == entry.ciphertext_hash and
            byte_size(bytes) == entry.ciphertext_byte_size and
            :crypto.hash(:sha256, bytes) == entry.ciphertext_hash,
          "actual alias ciphertext differs from persisted native evidence"
        )

        %{stat: stat, ciphertext: bytes}
      end

    [uuid, canonical] = witnesses
    require!(uuid == canonical, "UUID and canonical adapter reads differ")
    physical = File.lstat!(path)
    require!(physical.type == :regular, "native alias does not resolve a regular file")

    Map.merge(uuid, %{
      canonical_ref: canonical_ref,
      physical: {physical.major_device, physical.minor_device, physical.inode}
    })
  end

  # Fault only the existing owned physical ciphertext selected by original I.
  def mutate_ciphertext!(root, entry) do
    alias Singularity.Storage.{LocalFilesystemAdapter, Local.PathGuard}

    lookup_digest = Base.encode16(entry.lookup_digest, case: :lower)

    {:ok, path} =
      PathGuard.object_path(root, entry.vault_id, entry.key_domain_id, lookup_digest)

    context = %{
      root: root,
      vault_namespace: entry.vault_id,
      domain_namespace: entry.key_domain_id,
      lookup_digest: lookup_digest,
      ciphertext_hash: entry.ciphertext_hash
    }

    ref = %Singularity.Core.ObjectRef{object_id: entry.storage_ref}
    before_stat = expect_ok!(LocalFilesystemAdapter.stat(context, ref), "fault ciphertext stat")
    before_physical = File.lstat!(path)
    before_bytes = File.read!(path)
    before_sha256 = :crypto.hash(:sha256, before_bytes)
    before_size = byte_size(before_bytes)

    require!(
      before_physical.type == :regular and before_size > 0 and
        before_physical.size == before_size and before_size == entry.ciphertext_byte_size and
        before_sha256 == entry.ciphertext_hash and
        before_stat == %{byte_size: before_size, ciphertext_hash: before_sha256},
      "ciphertext fault did not begin with the original inventory's genuine physical file"
    )

    <<first, _rest::binary>> = before_bytes
    original_mode = Bitwise.band(before_physical.mode, 0o7777)
    :ok = PathGuard.assert_safe_path(root, path)

    try do
      File.chmod!(path, Bitwise.bor(original_mode, 0o200))

      File.open!(path, [:read, :write, :binary], fn io ->
        :ok = :file.pwrite(io, 0, <<Bitwise.bxor(first, 1)>>)
        :ok = :file.sync(io)
      end)
    after
      :ok = PathGuard.assert_safe_path(root, path)
      File.chmod!(path, original_mode)
    end

    after_bytes = File.read!(path)
    after_sha256 = :crypto.hash(:sha256, after_bytes)
    after_size = byte_size(after_bytes)
    after_physical = File.lstat!(path)
    after_stat = expect_ok!(LocalFilesystemAdapter.stat(context, ref), "mutated ciphertext stat")
    <<_before_first, unchanged::binary>> = before_bytes

    require!(
      after_bytes == <<Bitwise.bxor(first, 1), unchanged::binary>> and
        after_size == before_size and after_sha256 != before_sha256 and
        after_physical.type == :regular and after_physical.size == before_size and
        after_physical.mode == before_physical.mode and
        {after_physical.major_device, after_physical.minor_device, after_physical.inode} ==
          {before_physical.major_device, before_physical.minor_device, before_physical.inode} and
        after_stat == %{byte_size: after_size, ciphertext_hash: after_sha256},
      "ciphertext fault did not change exactly one byte of the same owned physical file"
    )

    %{
      before_sha256: before_sha256,
      before_size: before_size,
      after_sha256: after_sha256,
      after_size: after_size
    }
  end

  def inventory_handoff(value) do
    %{
      cut: value.cut,
      inventory: value.object_inventory,
      manifest_id: value.manifest.manifest_id,
      manifest_hash: value.manifest_hash,
      manifest_tag: value.manifest_tag,
      owner: Map.take(value.owner, [:vault_key_version_id, :vault_key_generation])
    }
  end

  # BEGIN Task9 equal-length foreign ciphertext composition on owned storage.
  def replace_ciphertext!(root, entry, replacement) when is_binary(replacement) do
    alias Singularity.Storage.Local.PathGuard

    before = reference_witness!(root, entry)

    {:ok, path} =
      PathGuard.object_path(
        root,
        entry.vault_id,
        entry.key_domain_id,
        Base.encode16(entry.lookup_digest, case: :lower)
      )

    physical = File.lstat!(path)
    original_mode = Bitwise.band(physical.mode, 0o7777)
    replacement_hash = :crypto.hash(:sha256, replacement)

    require!(
      physical.type == :regular and original_mode == 0o400 and
        byte_size(replacement) == entry.ciphertext_byte_size and
        replacement_hash != entry.ciphertext_hash,
      "foreign composition requires one genuine read-only equal-length owned ciphertext"
    )

    :ok = PathGuard.assert_safe_path(root, path)

    try do
      File.chmod!(path, Bitwise.bor(original_mode, 0o200))

      File.open!(path, [:read, :write, :binary], fn io ->
        :ok = :file.pwrite(io, 0, replacement)
        :ok = :file.sync(io)
      end)
    after
      :ok = PathGuard.assert_safe_path(root, path)
      File.chmod!(path, original_mode)
    end

    after_physical = File.lstat!(path)
    after_bytes = File.read!(path)

    same_physical =
      after_physical.type == :regular and after_physical.mode == physical.mode and
        after_physical.size == physical.size and after_bytes == replacement and
        {after_physical.major_device, after_physical.minor_device, after_physical.inode} ==
          before.physical

    require!(same_physical, "foreign composition changed owned file identity, mode or length")

    %{
      before: %{
        physical: before.physical,
        mode: physical.mode,
        sha256: entry.ciphertext_hash,
        byte_size: entry.ciphertext_byte_size
      },
      after: %{
        physical: before.physical,
        mode: after_physical.mode,
        sha256: replacement_hash,
        byte_size: byte_size(after_bytes)
      }
    }
  end

  # END Task9 equal-length foreign ciphertext composition on owned storage.

  def assert_inventory_observations!(source, root, events) do
    alias Singularity.Storage.Backup.IntegrityAudit
    alias Singularity.Storage.Backup.IntegrityAudit.CiphertextSummary

    original = source.original_inventory
    projected = projected_inventory!(source)
    require!(length(original) == 5, "source SQL inventory does not contain five objects")

    require!(
      source.observation.cut.object_inventory == original,
      "worker inventory differs from source SQL"
    )

    require!(
      Enum.map(events, &elem(&1, 0)) ==
        [
          :authenticated,
          :imported,
          :issue,
          :issued,
          :rewrapped,
          :saga_ciphertext,
          :ciphertext,
          :saga_plaintext,
          :ciphertext,
          :material,
          :material,
          :material,
          :material,
          :material
        ],
      "native inventory observation order or multiplicity differs"
    )

    [
      {:authenticated, authenticated},
      {:imported, imported},
      {:issue, issue},
      {:issued, issued},
      {:rewrapped, rewrapped} | _rest
    ] = events

    require!(
      authenticated.cut.object_inventory == original and
        authenticated.verified_cut == authenticated.cut and
        authenticated.binding == %{
          manifest_id: source.operation_id,
          vault_id: source.owner.vault_id
        },
      "authenticated inventory or owner binding differs from source SQL"
    )

    require!(
      byte_size(authenticated.manifest_hash) == 32 and
        byte_size(authenticated.manifest_tag) == 16,
      "authenticated native manifest commitments have invalid shape"
    )

    for {stage, handoff} <- events,
        stage in [:imported, :rewrapped, :saga_ciphertext, :saga_plaintext] do
      require!(
        handoff.inventory == original and handoff.cut == authenticated.cut and
          handoff.manifest_id == source.operation_id and
          handoff.manifest_hash == authenticated.manifest_hash and
          handoff.manifest_tag == authenticated.manifest_tag and handoff.owner == imported.owner,
        "actual native handoff lost original inventory or manifest binding"
      )
    end

    binding = Map.merge(imported.owner, authenticated.binding)
    inventory_hash = :crypto.hash(:sha256, :erlang.term_to_binary(original, [:deterministic]))
    root_hash = :crypto.hash(:sha256, Path.expand(root))

    require!(
      issue.inventory == projected and issue.binding == binding and issue.owner_is_caller? and
        issue.options_preserved? and issue.key_shape? and issue.ttl_ms == :timer.minutes(5) and
        issue.key_wrapper == Singularity.Storage.Crypto.KeyWrapper and
        issue.storage == {Singularity.Storage.LocalFilesystemAdapter, %{root: root}} and
        issue.loader == Singularity.Storage.Backup.KnowledgeIntegrityInventory and
        issue.prepared.original == List.to_tuple(original) and
        issue.prepared.projected == List.to_tuple(projected) and
        issue.prepared.binding == binding and issue.prepared.storage == issue.storage and
        issue.prepared.repo == Singularity.Storage.MigrationRepo and
        issue.prepared.manifest_hash == authenticated.manifest_hash and
        issue.prepared.manifest_tag == authenticated.manifest_tag and
        issue.prepared.inventory_hash == inventory_hash and issue.prepared.root_hash == root_hash and
        issued and rewrapped.owner == imported.owner,
      "actual native issue options or prepared original/projected binding differ"
    )

    {:ok, projected_hash} = IntegrityAudit.inventory_sha256(source.owner.vault_id, projected)

    for {:ciphertext, observation} <- events do
      require!(
        observation.storage == issue.storage and observation.vault_id == source.owner.vault_id and
          observation.inventory == projected and
          match?(%CiphertextSummary{}, observation.summary) and
          observation.summary.vault_id == source.owner.vault_id and
          observation.summary.object_count == 5 and
          observation.summary.inventory_sha256 == projected_hash and
          observation.summary.ciphertext_hashes ==
            Enum.map(
              projected,
              &%{asset_object_id: &1.asset_object_id, sha256: &1.ciphertext_hash}
            ),
        "actual typed ciphertext result lost projected inventory binding"
      )
    end

    material = for {:material, observation} <- events, do: observation

    require!(
      Enum.map(material, & &1.entry) == projected and
        Enum.all?(material, fn observation ->
          entry = observation.entry

          observation.binding == binding and
            observation.material == %{
              object_id: entry.asset_object_id,
              vault_id: entry.vault_id,
              key_domain_id: entry.key_domain_id,
              classification: entry.classification,
              lookup_digest: entry.lookup_digest,
              ciphertext_hash: entry.ciphertext_hash,
              ciphertext_byte_size: entry.ciphertext_byte_size,
              vault_key_version_id: binding.vault_key_version_id,
              vault_key_generation: binding.vault_key_generation
            }
        end),
      "actual positioned native material calls or returned identities differ"
    )

    :ok
  end

  def assert_saga_commitment!(source, root, handoff) do
    result =
      Singularity.Runtime.NativeAssetFixture.observe!("""
      SELECT manifest_id::text,vault_id::text,manifest_hash,manifest_tag,
        inventory_hash,destination_root_hash,object_count,state
      FROM audit.restore_import_sagas WHERE singleton
      """)

    expected = [
      source.operation_id,
      source.owner.vault_id,
      handoff.manifest_hash,
      handoff.manifest_tag,
      :crypto.hash(:sha256, :erlang.term_to_binary(source.original_inventory, [:deterministic])),
      :crypto.hash(:sha256, Path.expand(root)),
      5,
      "imported"
    ]

    require!(result.rows == [expected], "persisted saga lost original inventory commitment")
    :ok
  end

  # Expected bytes are retained upload inputs, not a digest or a fixture reader.
  # A tombstoned Asset still supplies its real identity to object-bound custody.
  def assert_originals!(session, descriptors) when is_list(descriptors) do
    groups = Enum.group_by(descriptors, & &1.object_id)
    require!(map_size(groups) == 5, "retained original inventory is not five objects")

    Enum.each(groups, fn {_object_id, [original | duplicates]} ->
      require!(
        Enum.all?(duplicates, fn duplicate ->
          duplicate.bytes == original.bytes and
            duplicate.object_generation == original.object_generation
        end),
        "deduplicated original descriptors disagree"
      )

      command = %{
        purpose: :download,
        job_id: original.asset_id,
        session_id: session.session_id,
        principal_id: session.principal_id,
        vault_id: session.vault_id,
        required_capability: "asset.read",
        principal_authorization_epoch: session.principal_authorization_epoch,
        vault_authorization_epoch: session.vault_authorization_epoch,
        object_id: original.object_id,
        object_generation: original.object_generation
      }

      with_original_lease!(command, fn lease ->
        monitor = Process.monitor(lease)

        try do
          observed = expect_ok!(DownloadLease.read(lease, :all), "original native read")
          require!(observed == original.bytes, "restored original bytes differ")
          await_original_down!(lease, monitor, :normal)

          require!(
            match?(
              {:error, %Error{code: :storage_unavailable, retryable?: true}},
              DownloadLease.read(lease, :all)
            ),
            "consumed original lease retained read authority"
          )
        after
          Process.demonitor(monitor, [:flush])
        end
      end)

      with_original_lease!(command, fn lease ->
        require!(DownloadLease.revoke(lease) == :ok, "original lease revocation failed")

        require!(
          DownloadLease.read(lease, :all) == {:error, :waiting_for_unlock},
          "revoked original lease retained read authority"
        )
      end)
    end)

    :ok
  end

  # Only the source worker's independently captured canonical rows supply
  # expectations. Search results never choose their own expected identities.
  def assert_search!(session, source) do
    rows = source.observation.rows
    ids = source.ids
    note = note_source!(rows, ids.live_note_id, ids.merge_note_version_id)

    require!(
      note.title == "Fixture Note" and note.body == "# Merged fixture\n",
      "source current Note differs from the designed graph"
    )

    fragments =
      rows
      |> Map.fetch!("content.document_fragments")
      |> Enum.filter(fn row ->
        row["resource_id"] == ids.ready_document_id and
          row["resource_version_id"] == ids.ready_current_version_id
      end)
      |> Enum.sort_by(& &1["ordinal"])

    require!(
      Enum.map(fragments, & &1["ordinal"]) == [0, 1],
      "source current Document does not contain both designed fragments"
    )

    documents =
      Enum.map(fragments, fn fragment ->
        document_source!(rows, ids.ready_document_id, ids.ready_current_version_id, fragment)
      end)

    require!(
      Enum.map(documents, &{&1.title, &1.body, &1.locator}) ==
        [
          {"Fixture Document", "first\n", %{"version" => 1, "kind" => "pdf", "page" => 1}},
          {"Fixture Document", "界🙂", %{"version" => 1, "kind" => "pdf", "page" => 2}}
        ],
      "source current Document differs from the designed graph"
    )

    expected = [note | documents]

    page =
      expect_ok!(
        Api.search_knowledge(session, %{q: "fixture", kind: :all, limit: 50}),
        "restored public knowledge search"
      )

    require!(
      match?(%KnowledgeSearchPage{next_cursor: nil}, page),
      "restored public search did not return a complete page"
    )

    actual = Enum.map(page.items, &search_result!/1)
    summaries = Enum.map(expected, &search_summary/1)

    require!(
      Enum.sort_by(actual, &identity/1) == Enum.sort_by(summaries, &identity/1),
      "restored current search identities or source fields differ"
    )

    Enum.each(expected, &assert_resolved!(session, &1))

    citation =
      row!(rows, "content.note_citations", fn row ->
        row["id"] == ids.citation_id and
          row["note_resource_id"] == ids.live_note_id and
          row["note_resource_version_id"] == ids.merge_note_version_id
      end)

    require!(
      citation["source_resource_id"] == ids.ready_document_id and
        citation["source_resource_version_id"] == ids.ready_old_version_id and
        citation["ordinal"] == 0,
      "live Note citation lost its historical Document pin"
    )

    historical_fragment =
      row!(rows, "content.document_fragments", fn row ->
        row["id"] == citation["fragment_id"] and
          row["resource_id"] == ids.ready_document_id and
          row["resource_version_id"] == ids.ready_old_version_id and row["ordinal"] == 0
      end)

    historical =
      document_source!(rows, ids.ready_document_id, ids.ready_old_version_id, historical_fragment)

    require!(
      historical.locator == citation["locator"] and
        historical.body == "first\n" and
        historical.locator == %{"version" => 1, "kind" => "pdf", "page" => 1},
      "historical citation source or locator differs"
    )

    assert_resolved!(session, historical)
    :ok
  end

  defp note_source!(rows, resource, version) do
    note =
      row!(rows, "content.note_versions", fn row ->
        row["resource_id"] == resource and row["resource_version_id"] == version
      end)

    %{
      kind: :note,
      resource_id: resource,
      resource_version_id: version,
      fragment_id: nil,
      ordinal: 0,
      title: note["title"],
      body: note["markdown"],
      locator: %{"version" => 1, "kind" => "markdown", "heading_path" => []},
      source_inserted_at: note["inserted_at"]
    }
  end

  defp document_source!(rows, resource, version, fragment) do
    document =
      row!(rows, "content.document_versions", fn row ->
        row["resource_id"] == resource and row["resource_version_id"] == version
      end)

    resource_version =
      row!(rows, "content.resource_versions", fn row ->
        row["resource_id"] == resource and row["id"] == version
      end)

    require!(document["state"] == "ready", "expected source Document is not ready")

    %{
      kind: :document,
      resource_id: resource,
      resource_version_id: version,
      fragment_id: fragment["id"],
      ordinal: fragment["ordinal"],
      title: document["title"],
      body: fragment["text"],
      locator: fragment["locator"],
      source_inserted_at: resource_version["inserted_at"],
      digest: fragment["digest"]
    }
  end

  defp search_summary(source) do
    source
    |> Map.drop([:ordinal, :body, :digest])
    |> Map.put(:snippet, String.slice(source.body, 0, 160))
  end

  defp search_result!(%KnowledgeSearchResult{} = result) do
    result
    |> Map.from_struct()
    |> Map.delete(:rank)
    |> normalize_source()
  end

  defp search_result!(_), do: raise(ArgumentError, "unexpected public search DTO")

  defp assert_resolved!(session, expected) do
    selector = Map.take(expected, @selector_fields)

    resolved =
      expect_ok!(Api.resolve_search_source(session, selector), "immutable source resolution")

    require!(match?(%KnowledgeSource{}, resolved), "unexpected public source DTO")
    actual = resolved |> Map.from_struct() |> normalize_source()

    require!(
      actual == Map.delete(expected, :digest),
      "restored immutable source identity or complete body differs"
    )

    if expected.kind == :document do
      require!(
        :crypto.hash(:sha256, resolved.body) == expected.digest,
        "restored immutable fragment digest differs"
      )
    end

    :ok
  end

  defp normalize_source(source) do
    source
    |> Map.update!(:locator, &SourceLocator.to_map/1)
    |> Map.update!(:source_inserted_at, &DateTime.to_iso8601/1)
  end

  defp identity(source),
    do: {source.kind, source.resource_id, source.resource_version_id, source.fragment_id}

  defp with_original_lease!(command, callback) do
    lease = expect_ok!(KeyCustodian.lease(KeyCustodian, command), "original custody admission")
    monitor = Process.monitor(lease)

    try do
      callback.(lease)
    catch
      kind, reason ->
        stacktrace = __STACKTRACE__

        # Preserve the primary failure, including its kind and stack, even if
        # cleanup also fails. Neither failure is turned into a successful result.
        try do
          close_original_lease!(lease, monitor)
        catch
          _cleanup_kind, _cleanup_reason ->
            IO.puts(:stderr, "original lease cleanup failed after primary failure")
        end

        :erlang.raise(kind, reason, stacktrace)
    else
      result ->
        close_original_lease!(lease, monitor)
        result
    after
      Process.demonitor(monitor, [:flush])
    end
  end

  defp close_original_lease!(lease, monitor) do
    receive do
      {:DOWN, ^monitor, :process, ^lease, :normal} ->
        :ok

      {:DOWN, ^monitor, :process, ^lease, _abnormal} ->
        raise ArgumentError, "original lease did not close normally"
    after
      0 ->
        case revoke_original_lease!(lease) do
          :consumed ->
            await_original_down!(lease, monitor, :normal)

          :ok ->
            require!(
              DownloadLease.read(lease, :all) == {:error, :waiting_for_unlock},
              "original lease cleanup retained read authority"
            )

            require!(
              DynamicSupervisor.terminate_child(KeyLeaseSupervisor, lease) == :ok,
              "original lease fixture teardown failed"
            )

            await_original_down!(lease, monitor, :shutdown)
        end
    end
  end

  defp revoke_original_lease!(lease) do
    require!(DownloadLease.revoke(lease) == :ok, "original lease cleanup revocation failed")
    :ok
  catch
    :exit, {reason, {GenServer, :call, [^lease, :revoke, :infinity]}}
    when reason in [:noproc, :normal] ->
      :consumed
  end

  defp await_original_down!(lease, monitor, expected_reason) do
    receive do
      {:DOWN, ^monitor, :process, ^lease, ^expected_reason} ->
        :ok

      {:DOWN, ^monitor, :process, ^lease, _unexpected} ->
        raise ArgumentError, "original lease termination reason differs"
    after
      1_000 -> raise ArgumentError, "original lease did not close"
    end
  end

  defp row!(rows, table, predicate) do
    case Enum.filter(Map.fetch!(rows, table), predicate) do
      [row] -> row
      _ -> raise ArgumentError, "expected canonical source row is not unique"
    end
  end

  defp expect_ok!({:ok, value}, _operation), do: value
  defp expect_ok!(_, operation), do: raise(ArgumentError, operation <> " failed")
  defp require!(true, _message), do: :ok
  defp require!(false, message), do: raise(ArgumentError, message)

  # BEGIN Task11 complete private parked-installation snapshot.
  # These fixed auxiliary tables complement the independent canonical projection.
  # Released note_mutation_receipts is required; only the later knowledge receipt
  # table has established optional absence. No row, column or physical path is
  # filtered by owner, backup cut, publication state or object inventory.
  @installation_auxiliary_tables ~w(
    identity.sessions identity.auth_attempts content.asset_stages content.upload_grants
    content.asset_search_documents content.note_search_documents content.search_entries
    content.note_mutation_receipts audit.backup_manifests audit.backup_manifest_objects
    jobs.oban_jobs jobs.oban_peers content.note_source_set_seals
    audit.knowledge_restore_admissions audit.restore_import_sagas
  )

  # Return private evidence only. Callers must never inspect or print this term:
  # it deliberately retains complete raw rows, including credentials and content.
  def installation_snapshot!(repo, root) do
    require!(is_atom(repo) and is_binary(root), "invalid installation snapshot context")
    repo_pid = Process.whereis(repo)
    require!(is_pid(repo_pid), "installation snapshot repository is not registered")
    database = Keyword.fetch!(repo.config(), :database)

    {:ok, rows} =
      repo.transaction(
        fn -> installation_rows!(repo, database) end,
        log: false
      )

    root = Path.expand(root)

    root
    |> Path.split()
    |> Enum.reduce("/", fn component, parent ->
      path = Path.join(parent, component)
      require!(File.lstat!(path).type == :directory, "installation root ancestry is unsafe")
      path
    end)

    files = root |> installation_tree!(".") |> Enum.sort_by(&elem(&1, 0))

    require!(
      Process.whereis(repo) == repo_pid,
      "installation snapshot repository identity changed"
    )

    %{repository: {repo, repo_pid}, database: rows, root: root, files: files}
  catch
    _kind, _reason -> raise ArgumentError, "installation snapshot failed"
  end

  def assert_installation_unchanged!(expected, repo, root) do
    unchanged? = expected === installation_snapshot!(repo, root)
    require!(unchanged?, "retained installation changed")
  end

  defp installation_rows!(repo, expected_database) do
    alias Singularity.Storage.{Backup.KnowledgeCanonicalOracle, SafeSQL}

    SafeSQL.query!(repo, "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY", [])
    SafeSQL.query!(repo, "SET LOCAL ROLE singularity_table_owner", [])

    %{rows: [[database, database_oid, role]]} =
      SafeSQL.query!(
        repo,
        """
        SELECT current_database(),
          (SELECT oid FROM pg_catalog.pg_database WHERE datname=current_database()),
          current_user
        """,
        []
      )

    require!(
      database == expected_database and is_integer(database_oid) and
        role == "singularity_table_owner",
      "installation snapshot database identity differs"
    )

    projection = KnowledgeCanonicalOracle.projection()

    require!(
      length(projection) == 38 and
        Enum.reduce(projection, 0, fn {_table, columns, _pk}, count ->
          count + length(columns)
        end) == 367,
      "installation canonical projection differs"
    )

    canonical =
      Map.new(projection, fn {table, columns, primary_key} ->
        select = Enum.map_join(columns, ",", &installation_identifier/1)
        order = Enum.map_join(primary_key, ",", &installation_identifier/1)

        result =
          SafeSQL.query!(
            repo,
            "SELECT #{select} FROM #{installation_identifier(table)} ORDER BY #{order}",
            []
          )

        require!(result.columns == columns, "installation canonical columns differ")
        {table, {:present, result.columns, result.rows}}
      end)

    auxiliary =
      Map.new(@installation_auxiliary_tables, fn table ->
        {table, installation_auxiliary_rows!(repo, table)}
      end)

    optional = "content.knowledge_mutation_receipts"

    optional_rows =
      case SafeSQL.query!(repo, "SELECT to_regclass($1)::text", [optional]).rows do
        [[nil]] -> :absent
        [[_relation]] -> installation_auxiliary_rows!(repo, optional)
      end

    %{
      identity: {database, database_oid, role},
      canonical: canonical,
      auxiliary: Map.put(auxiliary, optional, optional_rows)
    }
  end

  defp installation_auxiliary_rows!(repo, table) do
    # JSON is an ordering expression only. SELECT source.* retains every actual
    # column and its raw Postgrex value, rather than normalized JSON evidence.
    result =
      Singularity.Storage.SafeSQL.query!(
        repo,
        "SELECT source.* FROM #{installation_identifier(table)} source " <>
          "ORDER BY to_jsonb(source)::text COLLATE \"C\"",
        []
      )

    {:present, result.columns, result.rows}
  end

  defp installation_identifier(name) do
    name |> String.split(".") |> Enum.map_join(".", &("\"" <> &1 <> "\""))
  end

  defp installation_tree!(root, relative) do
    path = if relative == ".", do: root, else: Path.join(root, relative)
    stat = File.lstat!(path)

    evidence =
      case stat.type do
        :regular ->
          bytes = File.read!(path)
          require!(byte_size(bytes) == stat.size, "installation file length changed during read")
          {:sha256, :crypto.hash(:sha256, bytes)}

        :symlink ->
          {:symlink_target, File.read_link!(path)}

        _special_or_directory ->
          :no_file_bytes
      end

    metadata =
      Map.take(stat, [
        :type,
        :major_device,
        :minor_device,
        :inode,
        :mode,
        :size,
        :links,
        :uid,
        :gid,
        :mtime,
        :ctime
      ])

    descendants =
      if stat.type == :directory do
        path
        |> File.ls!()
        |> Enum.sort()
        |> Enum.flat_map(fn name ->
          child = if relative == ".", do: name, else: Path.join(relative, name)
          installation_tree!(root, child)
        end)
      else
        []
      end

    [{relative, metadata, evidence} | descendants]
  end

  # END Task11 complete private parked-installation snapshot.
  # BEGIN internal saga12 independent task oracle.
  alias Singularity.Runtime.{
    KnowledgeBackupRestoreFixture,
    OutboxDispatcher,
    RestoreIntegrityLease
  }

  alias Singularity.Runtime.RestoreVault
  alias Singularity.Runtime.RestoreIntegrityLease.PlaintextSummary
  alias Singularity.Runtime.Documents.ExtractionReconciler
  alias Singularity.Storage.{MigrationRepo, SafeSQL, WorkerRepo}
  alias Singularity.Storage.Backup.KnowledgeCanonicalOracle, as: Canonical
  alias Singularity.Storage.Backup.IntegrityAudit.CiphertextSummary
  alias Singularity.Storage.Postgres.DocumentRepository

  @saga12_transport_repo_roles [
    {MigrationRepo, "singularity_migration"},
    {Singularity.Storage.RequestRepo, "singularity_web"},
    {Singularity.Storage.PreAuthRepo, "singularity_pre_auth"},
    {Singularity.Storage.DispatcherRepo, "singularity_dispatcher"},
    {WorkerRepo, "singularity_worker"}
  ]

  @saga12_graph_counts [
    {"content.resources", 14},
    {"content.resource_versions", 19},
    {"content.assets", 6},
    {"content.asset_objects", 5},
    {"content.source_references", 6},
    {"content.document_versions", 7},
    {"content.document_fragments", 6},
    {"content.document_import_receipts", 7},
    {"content.note_versions", 6},
    {"content.note_conflicts", 2},
    {"content.note_attachments", 4},
    {"content.note_citations", 3},
    {"content.tags", 1},
    {"content.resource_tags", 1},
    {"content.relationships", 1},
    {"content.tombstones", 2}
  ]

  def run! do
    with_postgres_transport!(fn ->
      for mode <- [:uuid, :canonical_compatibility, :mixed_compatibility] do
        IO.puts("knowledge_restore stage=positive variant=#{mode} status=begin")
        saga12_run_case!(mode, false)
        IO.puts("knowledge_restore stage=positive variant=#{mode} status=pass")
      end

      IO.puts("knowledge_restore stage=late_native_corruption status=begin")
      saga12_run_case!(:uuid, true)
      IO.puts("knowledge_restore stage=late_native_corruption status=pass")
      IO.puts("knowledge_restore positive_count=3 negative_count=1 status=pass")
      :ok
    end)
  catch
    _kind, _reason ->
      raise ArgumentError, "independent knowledge restore oracle failed after owned cleanup"
  end

  @doc false
  def with_postgres_transport!(callback) when is_function(callback, 0) do
    socket = System.fetch_env!("PGHOST")

    port =
      case Integer.parse(System.fetch_env!("PGPORT")) do
        {port, ""} when port in 1..65_535 -> port
        _other -> raise ArgumentError, "PGPORT must be a valid PostgreSQL port"
      end

    saved =
      Enum.map(@saga12_transport_repo_roles, fn {repo, _role} ->
        {repo, Application.fetch_env(:singularity_storage, repo)}
      end)

    try do
      for {repo, role} <- @saga12_transport_repo_roles do
        options =
          :singularity_storage
          |> Application.get_env(repo, [])
          |> Keyword.drop([:url, :hostname])
          |> Keyword.merge(url: nil, socket_dir: socket, port: port, username: role)

        Application.put_env(:singularity_storage, repo, options)
      end

      callback.()
    after
      Enum.each(saved, fn
        {repo, {:ok, options}} -> Application.put_env(:singularity_storage, repo, options)
        {repo, :error} -> Application.delete_env(:singularity_storage, repo)
      end)
    end
  end

  defp saga12_run_case!(mode, corrupt?) do
    root = Path.join(System.tmp_dir!(), "singularity-knowledge-oracle-#{Ecto.UUID.generate()}")
    File.mkdir!(root)
    identity = saga12_directory_identity!(root)
    saved = saga12_settings()

    saga12_cleanly!(
      fn ->
        File.chmod!(root, 0o700)
        source = KnowledgeBackupRestoreFixture.backup_source!(root, mode)
        saga12_source!(source, root, mode)
        saga12_closed!(source.lifecycle)
        require!(saga12_settings() == saved, "source did not restore exact oracle settings")

        lifecycle =
          KnowledgeBackupRestoreFixture.with_destination(source.lifecycle, fn fixture ->
            saga12_destination!(source, root, fixture, corrupt?)
          end)

        saga12_closed!(lifecycle)
        require!(saga12_settings() == saved, "destination did not restore exact oracle settings")
        require!(File.ls!(root) == [source.destination_ref], "portable bundle inventory changed")
        :ok
      end,
      fn ->
        saga12_remove_portable!(root, identity)
        require!(saga12_settings() == saved, "oracle cleanup did not restore exact settings")
      end
    )
  end

  defp saga12_destination!(source, root, fixture, corrupt?) do
    reference = make_ref()
    caller = self()
    counter = :counters.new(1, [])
    new_password = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    object_root = fixture.destination.object_root

    record = fn event ->
      send(caller, {reference, :oracle_event, event})
      :ok
    end

    hooks = %{
      after_import: fn imported ->
        saga12_import!(source, object_root, imported)
        send(caller, {reference, :oracle_handoff, inventory_handoff(imported)})
        record.(:import)
      end,
      after_rewrap: fn rewrapped ->
        saga12_password!(source, new_password)
        saga12_handoff!(source, rewrapped)
        saga12_saga!(source, object_root, rewrapped)
        send(caller, {reference, :oracle_handoff, inventory_handoff(rewrapped)})
        capability = rewrapped.integrity_capability
        monitor = Process.monitor(capability.lease)
        send(caller, {reference, :oracle_capability, capability, monitor})
        send(caller, {reference, :oracle_cleanup_capability, capability, monitor})
        record.(:rewrap)
      end,
      after_complete: fn :ok -> record.(:complete) end,
      before_documents: fn binding, inventory, hashes ->
        require!(
          binding == %{manifest_id: source.operation_id, vault_id: source.owner.vault_id} and
            inventory == source.original_inventory and hashes == saga12_plaintext_hashes(source),
          "Document verification lost independent original source evidence"
        )

        record.(:documents)
      end,
      before_rebuild: fn _binding -> record.(:before_rebuild) end,
      after_rebuild: fn _summary -> record.(:after_rebuild) end,
      native_lease_observer: fn stage, payload -> record.({:lease, stage, payload}) end,
      ciphertext_result_observer: fn result ->
        require!(
          match?({:ok, %CiphertextSummary{}}, result),
          "native ciphertext verification did not succeed before late admission"
        )

        record.(:ciphertext_success)
      end,
      inventory_observer: fn stage, payload ->
        case stage do
          :authenticated ->
            require!(
              payload.binding == %{
                manifest_id: source.operation_id,
                vault_id: source.owner.vault_id
              } and payload.cut == payload.verified_cut and
                payload.cut.object_inventory == source.original_inventory,
              "authenticated cut differs from source worker inventory"
            )

            send(caller, {reference, :oracle_authenticated, payload})
            record.(:authenticated)

          :saga_ciphertext ->
            saga12_handoff!(source, payload)
            send(caller, {reference, :oracle_handoff, payload})
            record.(:early_cipher_enter)

          :saga_plaintext ->
            saga12_handoff!(source, payload)
            send(caller, {reference, :oracle_handoff, payload})
            record.(:final_cipher_enter)

          :issue ->
            saga12_issue!(source, object_root, payload)
            send(caller, {reference, :oracle_issue, payload})

          :issued ->
            require!(payload == true, "native integrity capability was not genuinely issued")

          :ciphertext ->
            saga12_ciphertext!(source, object_root, payload)
            :counters.add(counter, 1, 1)
            ordinal = :counters.get(counter, 1)
            record.({:ciphertext, ordinal})

            if corrupt? and ordinal == 2 do
              entry =
                Enum.find(
                  source.original_inventory,
                  &(&1.asset_object_id == source.sources.pdf.object_id)
                )

              witness = mutate_ciphertext!(object_root, entry)

              require!(
                witness.before_sha256 == entry.ciphertext_hash and
                  witness.before_size == entry.ciphertext_byte_size and
                  witness.after_size == witness.before_size and
                  witness.after_sha256 != witness.before_sha256,
                "late native corruption lacks genuine physical ciphertext evidence"
              )

              record.(:mutated)
            end

          :material ->
            send(caller, {reference, :oracle_material, payload})

          _stage ->
            :ok
        end

        :ok
      end
    }

    Application.put_env(:singularity_runtime, :knowledge_v3_plaintext_observer, fn summary ->
      saga12_summary!(source, summary)
      record.(:plaintext)
    end)

    saga12_cleanly!(
      fn ->
        context =
          KnowledgeBackupRestoreFixture.restore_context(fixture.destination, root, hooks, %{})

        result =
          RestoreVault.run(context, %{
            source: source.destination_ref,
            passphrase: source.passphrase,
            new_password: new_password
          })

        {capability, monitor} = saga12_capability!(reference)
        saga12_capability_closed!(capability, monitor)
        saga12_authenticated!(source, reference)

        if corrupt? do
          require!(
            result == {:error, Error.new(:integrity_failure, retryable?: false)},
            "late native corruption changed exact sanitized denial"
          )

          require!(
            saga12_events(reference) == [
              :authenticated,
              :import,
              :rewrap,
              :early_cipher_enter,
              {:ciphertext, 1},
              :ciphertext_success,
              :final_cipher_enter,
              {:ciphertext, 2},
              :mutated,
              :ciphertext_success,
              {:lease, :entered, :ok},
              {:lease, :returned, {:error, :integrity_failure, false}}
            ],
            "late corruption did not reach exactly the genuine native denial boundary"
          )

          saga12_unpublished!(source, new_password)
          rows = Canonical.read_committed!(MigrationRepo, source.owner, source.observation.cut)

          for table <-
                ~w(content.asset_objects content.asset_key_envelopes content.document_versions) do
            require!(
              rows[table] == source.observation.rows[table],
              "late native denial changed retained immutable metadata"
            )
          end

          fixture.lifecycle
        else
          require!(
            result == {:ok, %{manifest_id: source.operation_id}},
            "native knowledge restore did not complete"
          )

          require!(
            saga12_events(reference) == [
              :authenticated,
              :import,
              :rewrap,
              :early_cipher_enter,
              {:ciphertext, 1},
              :ciphertext_success,
              :final_cipher_enter,
              {:ciphertext, 2},
              :ciphertext_success,
              {:lease, :entered, :ok},
              :plaintext,
              {:lease, :returned, :ok},
              :documents,
              :before_rebuild,
              :after_rebuild,
              :complete
            ],
            "native positive restore stage order or multiplicity differs"
          )

          saga12_materials!(source, reference)
          saga12_completed!(source)
          saga12_retired!(source)

          runtime =
            KnowledgeBackupRestoreFixture.start_controlled_runtime!(
              fixture.owner,
              fixture.destination
            )

          session = saga12_login!(source, new_password)
          assert_originals!(session, KnowledgeBackupRestoreFixture.retained_originals!(source))
          saga12_public_originals!(source, session)
          assert_search!(session, source)
          saga12_recovery!(source, session, runtime)
          %{fixture.lifecycle | infrastructure: runtime.infrastructure}
        end
      end,
      fn -> saga12_cleanup_capabilities!(reference) end
    )
  end

  defp saga12_source!(source, root, mode) do
    observation = source.observation
    projection = Canonical.projection()

    require!(
      length(projection) == 38 and
        Enum.reduce(projection, 0, fn {_table, columns, _pk}, n -> n + length(columns) end) == 367 and
        MapSet.new(Map.keys(observation.rows)) == MapSet.new(projection, &elem(&1, 0)),
      "independent canonical projection is not exactly thirty-eight tables and 367 columns"
    )

    for {table, columns, _pk} <- projection, row <- Map.fetch!(observation.rows, table) do
      require!(
        MapSet.new(Map.keys(row)) == MapSet.new(columns),
        "actual worker snapshot has an incomplete independent canonical projection"
      )
    end

    require!(
      source.reference_mode == mode and source.default_backup_error == :backup_unsupported and
        observation.worker_role == "singularity_worker" and
        observation.worker_backend != observation.observer_backend and
        observation.database == source.lifecycle.database and
        observation.snapshot == observation.cut.database_snapshot and
        observation.cut.vault_id == source.owner.vault_id and
        source.manifest.snapshot_id == observation.cut.snapshot_id and
        source.manifest.high_water == observation.cut.outbox_high_water_mark and
        source.manifest.id == source.operation_id and source.manifest.status == "sealed",
      "genuine source worker, role, database, manifest or cut binding differs"
    )

    %{type: :regular, mode: bundle_mode, size: size} = File.lstat!(source.bundle_path)

    require!(
      Bitwise.band(bundle_mode, 0o777) == 0o600 and size > 0 and
        File.ls!(root) == [source.destination_ref] and
        source.destination_ref == source.operation_id <> ".bundle" and
        Bitwise.band(File.lstat!(root).mode, 0o777) == 0o700,
      "native source did not retain exactly one private portable bundle"
    )

    rows = observation.rows

    for {table, count} <- @saga12_graph_counts do
      require!(length(Map.fetch!(rows, table)) == count, "native graph cardinality differs")
    end

    originals = %{
      pdf: "%PDF-1.7\n" <> <<0, 1, 255>> <> "\n%%EOF\n",
      pdf_duplicate: "%PDF-1.7\n" <> <<0, 1, 255>> <> "\n%%EOF\n",
      empty: "",
      plain: "plain original\r\nsecond line\n",
      unicode: <<0xEF, 0xBB, 0xBF, 0xE4, 0xB8, 0xAD>> <> "é\r\n",
      markdown: "# Original Markdown\r\n[source](https://example.test/)\n"
    }

    require!(
      source.originals == originals and map_size(source.sources) == 6 and
        map_size(source.native_inventory) == 5 and
        MapSet.new(Map.keys(source.native_inventory)) ==
          MapSet.new(source.sources, fn {_name, item} -> item.object_id end) and
        source.sources.pdf.object_id == source.sources.pdf_duplicate.object_id,
      "native publications differ from literal original upload bytes or deduplication"
    )

    for field <- [:asset_id, :resource_id, :resource_version_id] do
      require!(
        length(Enum.uniq(Enum.map(source.sources, fn {_name, item} -> item[field] end))) == 6,
        "genuine publication identities are not distinct"
      )
    end

    for {name, descriptor} <- source.sources do
      bytes = Map.fetch!(originals, name)
      object = Map.fetch!(source.native_inventory, descriptor.object_id)

      require!(
        descriptor.bytes == bytes and descriptor.digest == :crypto.hash(:sha256, bytes) and
          descriptor.byte_size == byte_size(bytes) and object["lifecycle"] == "available" and
          object["format_version"] == 1 and object["plaintext_byte_size"] == byte_size(bytes),
        "genuine publication lost actual original byte evidence"
      )
    end

    saga12_graph!(source)
    saga12_references!(source, rows["content.asset_objects"])

    require!(
      Enum.frequencies_by(rows["jobs.job_submissions"], & &1["job_type"]) == %{
        "asset_verify" => 6,
        "asset_finalize" => 6,
        "asset_metadata" => 2,
        "asset_cleanup" => 2,
        "document_extract" => 1,
        "backup" => 1
      },
      "knowledge graph does not own exactly eighteen expected source submissions"
    )

    :ok
  end

  defp saga12_graph!(source) do
    rows = source.observation.rows
    ids = source.ids
    sources = source.sources
    documents = Map.new(rows["content.document_versions"], &{&1["resource_version_id"], &1})

    expected_documents = [
      {ids.ready_old_version_id, ids.ready_document_id, :pdf, "ready"},
      {ids.ready_current_version_id, ids.ready_document_id, :pdf_duplicate, "ready"},
      {ids.deleted_document_version_id, ids.deleted_document_id, :pdf, "ready"},
      {ids.pending_version_id, ids.pending_document_id, :empty, "pending"},
      {ids.extracting_version_id, ids.extracting_document_id, :plain, "extracting"},
      {ids.failed_version_id, ids.failed_document_id, :unicode, "failed"},
      {ids.unsupported_version_id, ids.unsupported_document_id, :markdown, "unsupported"}
    ]

    require!(
      MapSet.new(Map.keys(documents)) == MapSet.new(expected_documents, &elem(&1, 0)),
      "source Document history identities differ"
    )

    for {version, resource, name, state} <- expected_documents do
      document = Map.fetch!(documents, version)
      original = Map.fetch!(sources, name)

      require!(
        document["resource_id"] == resource and document["state"] == state and
          document["source_asset_id"] == original.asset_id and
          document["source_resource_id"] == original.resource_id and
          document["source_resource_version_id"] == original.resource_version_id and
          document["source_object_id"] == original.object_id and
          document["source_digest"] == original.digest and
          document["source_byte_size"] == original.byte_size,
        "immutable Document history lost original-byte provenance"
      )
    end

    resources = Map.new(rows["content.resources"], &{&1["id"], &1})

    require!(
      resources[ids.live_note_id]["current_version_id"] == ids.merge_note_version_id and
        resources[ids.ready_document_id]["current_version_id"] == ids.ready_current_version_id and
        MapSet.new(Map.keys(resources)) ==
          MapSet.new(
            Enum.map(sources, fn {_name, item} ->
              item.resource_id
            end) ++
              [
                ids.live_note_id,
                ids.deleted_note_id,
                ids.ready_document_id,
                ids.deleted_document_id,
                ids.pending_document_id,
                ids.extracting_document_id,
                ids.failed_document_id,
                ids.unsupported_document_id
              ]
          ),
      "source resource membership or current heads differ"
    )

    notes = Map.new(rows["content.note_versions"], &{&1["resource_version_id"], &1})

    require!(
      MapSet.new(Map.keys(notes)) ==
        MapSet.new([
          ids.initial_note_version_id,
          ids.canonical_note_version_id,
          ids.competing_note_version_id,
          ids.merge_note_version_id,
          ids.open_competing_note_version_id,
          ids.deleted_note_version_id
        ]) and
        notes[ids.merge_note_version_id]["parent_version_id"] == ids.canonical_note_version_id and
        notes[ids.merge_note_version_id]["merge_parent_version_id"] ==
          ids.competing_note_version_id and
        notes[ids.open_competing_note_version_id]["parent_version_id"] ==
          ids.canonical_note_version_id,
      "source Note history or merge ancestry differs"
    )

    require!(
      MapSet.new(rows["content.note_conflicts"], fn row ->
        {row["id"], row["state"], row["canonical_version_id"], row["competing_version_id"],
         row["resolution_version_id"]}
      end) ==
        MapSet.new([
          {ids.resolved_conflict_id, "resolved", ids.canonical_note_version_id,
           ids.competing_note_version_id, ids.merge_note_version_id},
          {ids.open_conflict_id, "open", ids.merge_note_version_id,
           ids.open_competing_note_version_id, nil}
        ]),
      "source conflict history differs"
    )

    require!(
      MapSet.new(
        rows["content.note_attachments"],
        &{&1["note_resource_version_id"], &1["id"]}
      ) ==
        MapSet.new([
          {ids.canonical_note_version_id, ids.attachment_id},
          {ids.merge_note_version_id, ids.attachment_id},
          {ids.open_competing_note_version_id, ids.attachment_id},
          {ids.deleted_note_version_id, ids.deleted_attachment_id}
        ]) and
        MapSet.new(rows["content.note_citations"], &{&1["note_resource_version_id"], &1["id"]}) ==
          MapSet.new([
            {ids.competing_note_version_id, ids.citation_id},
            {ids.merge_note_version_id, ids.citation_id},
            {ids.deleted_note_version_id, ids.deleted_citation_id}
          ]),
      "source sealed attachment or citation membership differs"
    )

    fragments = Map.new(rows["content.document_fragments"], &{&1["id"], &1})

    for citation <- rows["content.note_citations"] do
      fragment = Map.fetch!(fragments, citation["fragment_id"])

      require!(
        citation["source_resource_id"] == fragment["resource_id"] and
          citation["source_resource_version_id"] == fragment["resource_version_id"] and
          citation["locator"] == fragment["locator"] and
          fragment["digest"] == :crypto.hash(:sha256, fragment["text"]),
        "immutable citation fragment locator or digest differs"
      )
    end

    require!(
      MapSet.new(rows["content.document_import_receipts"], & &1["version_id"]) ==
        MapSet.new(Map.keys(documents)) and
        Enum.all?(rows["content.document_import_receipts"], &(&1["state"] == "completed")),
      "source Document import receipts differ"
    )

    require!(
      match?(
        [%{"id" => tag, "display_value" => "Straße", "normalized_key" => "strasse"}]
        when tag == ids.tag_id,
        rows["content.tags"]
      ) and
        match?(
          [%{"resource_id" => note, "tag_id" => tag}]
          when note == ids.live_note_id and tag == ids.tag_id,
          rows["content.resource_tags"]
        ) and
        match?(
          [
            %{
              "id" => edge,
              "source_resource_id" => note,
              "target_resource_id" => document,
              "target_resource_version_id" => pin,
              "type" => "references"
            }
          ]
          when edge == ids.relationship_id and note == ids.live_note_id and
                 document == ids.ready_document_id and pin == ids.ready_old_version_id,
          rows["content.relationships"]
        ),
      "source organization or historical relationship pin differs"
    )

    require!(
      Map.new(source.source_set_seals, fn [version, attached, cited] ->
        {version, {attached, cited}}
      end) == %{
        ids.initial_note_version_id => {0, 0},
        ids.canonical_note_version_id => {1, 0},
        ids.competing_note_version_id => {0, 1},
        ids.merge_note_version_id => {1, 1},
        ids.open_competing_note_version_id => {1, 0},
        ids.deleted_note_version_id => {1, 1}
      },
      "source Note seal counts differ"
    )

    require!(
      source.pdf_pin_count == 3 and source.live_pdf_asset_references == 0 and
        source.orphan_cleanup_events == 0 and source.bootstrap_hierarchy_unchanged? and
        source.pdf_retention_unchanged? and
        MapSet.new(rows["content.tombstones"], & &1["asset_id"]) ==
          MapSet.new([sources.pdf.asset_id, sources.pdf_duplicate.asset_id]),
      "Document-only PDF retention, original hierarchy or tombstones differ"
    )

    for resource <- [
          sources.pdf.resource_id,
          sources.pdf_duplicate.resource_id,
          ids.deleted_note_id,
          ids.deleted_document_id
        ] do
      require!(not is_nil(resources[resource]["deleted_at"]), "source deletion marker is missing")
    end

    require!(
      Enum.all?(source.deletions, fn deletion ->
        deletion.pending_revision == deletion.before_revision + 1 and
          deletion.deleted_revision == deletion.before_revision + 2 and
          deletion.worker_effect_revision == deletion.deleted_revision and
          deletion.cleanup_success == 1
      end) and
        Enum.all?(rows["content.assets"], fn asset ->
          if asset["id"] in [sources.pdf.asset_id, sources.pdf_duplicate.asset_id],
            do: asset["state"] == "deleted" and is_nil(asset["asset_object_id"]),
            else: asset["state"] == "ready" and asset["state_revision"] == 5
        end),
      "source genuine deletion or finalized Asset state differs"
    )

    extracting = documents[ids.extracting_version_id]
    event = row!(rows, "core.outbox_events", &(&1["id"] == source.work.submission_id))
    submission = row!(rows, "jobs.job_submissions", &(&1["id"] == source.work.submission_id))

    require!(
      extracting["attempt_job_id"] == source.work.submission_id and
        submission["outbox_event_id"] == source.work.submission_id and
        event["principal_authorization_epoch"] == source.work.principal_authorization_epoch and
        event["vault_authorization_epoch"] == source.work.vault_authorization_epoch,
      "source abandoned extraction work binding differs"
    )
  end

  defp saga12_references!(source, persisted_objects) do
    selected =
      case source.reference_mode do
        :uuid -> []
        :canonical_compatibility -> Map.keys(source.native_inventory)
        :mixed_compatibility -> [source.sources.pdf.object_id, source.sources.empty.object_id]
      end

    expected =
      source.native_inventory
      |> Map.values()
      |> Enum.map(fn row ->
        Enum.reduce(~w(id vault_id key_domain_id), row, fn field, normalized ->
          Map.update!(normalized, field, &Ecto.UUID.load!/1)
        end)
      end)
      |> original_inventory!()
      |> Enum.map(fn entry ->
        if entry.asset_object_id in selected do
          {:ok, path} =
            Singularity.Storage.Local.PathGuard.object_path(
              source.lifecycle.object_root,
              entry.vault_id,
              entry.key_domain_id,
              Base.encode16(entry.lookup_digest, case: :lower)
            )

          Map.put(entry, :storage_ref, Path.relative_to(path, source.lifecycle.object_root))
        else
          Map.put(entry, :storage_ref, entry.asset_object_id)
        end
      end)

    require!(
      length(expected) == 5 and source.original_inventory == expected and
        source.observation.cut.object_inventory == expected and
        original_inventory!(persisted_objects) == expected,
      "worker or persisted nine-field original inventory differs from explicit alias selection"
    )
  end

  defp saga12_import!(source, root, imported) do
    expected =
      Map.update!(source.observation.rows, "core.vaults", fn rows ->
        Enum.map(rows, &Map.put(&1, "locked", true))
      end)

    observed = Canonical.read_committed!(MigrationRepo, source.owner, imported.cut)
    require!(observed == expected, "pre-rewrap complete independent canonical cut differs")
    saga12_handoff!(source, imported)
    saga12_saga!(source, root, imported)
    saga12_references!(source, observed["content.asset_objects"])

    if source.reference_mode != :uuid do
      for entry <- source.original_inventory do
        witness = reference_witness!(root, entry)

        require!(
          Map.take(witness, [:stat, :ciphertext]) ==
            Map.take(Map.fetch!(source.reference_witnesses, entry.asset_object_id), [
              :stat,
              :ciphertext
            ]),
          "historical reference restore changed genuine original ciphertext"
        )
      end
    end

    %{rows: [[credentials, wrappers]]} =
      saga12_query!(
        """
        SELECT
          (SELECT count(*) FROM identity.credentials c CROSS JOIN identity.security_settings s
            WHERE c.account_id=$1 AND c.verifier=s.dummy_verifier AND c.verifier_version=1
              AND c.updated_at=c.inserted_at AND s.singleton),
          (SELECT count(*) FROM core.vault_key_wrappers w WHERE w.vault_id=$2 AND w.account_id=$1
            AND w.kdf_version=1 AND w.kdf_salt=$3
            AND w.kdf_parameters='{"state":"restore_pending","version":1}'::jsonb
            AND w.wrapper_algorithm='restore_pending' AND w.wrapped_key=$3)
        """,
        [
          Ecto.UUID.dump!(source.owner.account_id),
          Ecto.UUID.dump!(source.owner.vault_id),
          "restore-pending"
        ]
      )

    require!(
      credentials == length(source.observation.rows["identity.credentials"]) and
        wrappers == length(source.observation.rows["core.vault_key_wrappers"]),
      "import did not install exact pending credential and wrapper placeholders"
    )

    %{rows: seals} =
      saga12_query!(
        """
        SELECT note_resource_version_id::text,attachment_count,citation_count
        FROM content.note_source_set_seals WHERE vault_id=$1 ORDER BY note_resource_version_id
        """,
        [Ecto.UUID.dump!(source.owner.vault_id)]
      )

    require!(
      seals == source.source_set_seals,
      "import did not regenerate all six exact Note seals"
    )

    saga12_withheld!()
  end

  defp saga12_handoff!(source, value) do
    inventory =
      if Map.has_key?(value, :object_inventory),
        do: value.object_inventory,
        else: value.inventory

    manifest_id =
      if Map.has_key?(value, :manifest),
        do: value.manifest.manifest_id,
        else: value.manifest_id

    require!(
      inventory == source.original_inventory and
        value.cut ==
          Map.merge(
            source.observation.cut,
            %{manifest_id: source.operation_id, logical_version: 3}
          ) and
        manifest_id == source.operation_id,
      "native handoff lost original inventory or exact cut"
    )
  end

  defp saga12_saga!(source, root, handoff) do
    %{rows: rows} =
      saga12_query!(
        """
        SELECT manifest_id::text,vault_id::text,manifest_hash,manifest_tag,
          inventory_hash,destination_root_hash,object_count,state
        FROM audit.restore_import_sagas WHERE singleton
        """,
        []
      )

    require!(
      rows == [
        [
          source.operation_id,
          source.owner.vault_id,
          handoff.manifest_hash,
          handoff.manifest_tag,
          :crypto.hash(
            :sha256,
            :erlang.term_to_binary(source.original_inventory, [:deterministic])
          ),
          :crypto.hash(:sha256, Path.expand(root)),
          5,
          "imported"
        ]
      ],
      "persisted saga differs from original inventory and destination commitment"
    )
  end

  defp saga12_password!(source, password) do
    result =
      saga12_query!(
        """
        SELECT c.verifier, NOT EXISTS(SELECT 1 FROM core.vault_key_wrappers w
          WHERE w.account_id=c.account_id AND w.wrapper_algorithm='restore_pending')
        FROM identity.credentials c WHERE c.account_id=$1 AND c.revoked_at IS NULL
        """,
        [Ecto.UUID.dump!(source.owner.account_id)]
      )

    bootstrap = Application.fetch_env!(:singularity_runtime, :bootstrap_owner)

    changed? =
      case result.rows do
        [[verifier, true]] ->
          bootstrap.password_hasher.verify(bootstrap.password_hasher_context, password, verifier) ==
            {:ok, true} and
            bootstrap.password_hasher.verify(
              bootstrap.password_hasher_context,
              source.credentials.password,
              verifier
            ) == {:ok, false}

        _ ->
          false
      end

    require!(changed?, "native rewrap did not replace pending credentials and old password")
  end

  # This literal encoder intentionally calls no production inventory codec/digest.
  defp saga12_inventory_digest(source) do
    entries =
      Enum.map(projected_inventory!(source), fn entry ->
        classification =
          case entry.classification do
            :private -> 1
            :sensitive -> 2
            :restricted -> 3
          end

        [
          <<entry.inventory_position::unsigned-big-64>>,
          Ecto.UUID.dump!(entry.asset_object_id),
          Ecto.UUID.dump!(entry.key_domain_id),
          Ecto.UUID.dump!(entry.asset_object_id),
          <<classification, entry.ciphertext_byte_size::unsigned-big-64>>,
          entry.lookup_digest,
          entry.ciphertext_hash
        ]
      end)

    :crypto.hash(:sha256, [
      "SINGULARITY-INTEGRITY-INVENTORY-V1\0",
      Ecto.UUID.dump!(source.owner.vault_id),
      <<5::unsigned-big-64>>,
      entries
    ])
  end

  defp saga12_plaintext_hashes(source) do
    originals =
      Map.new(source.sources, fn {_name, original} ->
        {original.object_id, original.bytes}
      end)

    Enum.map(source.original_inventory, fn entry ->
      %{
        asset_object_id: entry.asset_object_id,
        sha256: :crypto.hash(:sha256, Map.fetch!(originals, entry.asset_object_id))
      }
    end)
  end

  defp saga12_summary!(source, %PlaintextSummary{} = summary) do
    require!(
      summary.vault_id == source.owner.vault_id and summary.object_count == 5 and
        summary.inventory_sha256 == saga12_inventory_digest(source) and
        summary.plaintext_hashes == saga12_plaintext_hashes(source),
      "real typed plaintext summary differs from independent literal originals and inventory"
    )
  end

  defp saga12_summary!(_source, _summary),
    do:
      raise(ArgumentError, "native plaintext verification did not return its real typed summary")

  defp saga12_ciphertext!(source, root, observation) do
    inventory = projected_inventory!(source)

    require!(
      observation.storage == {Singularity.Storage.LocalFilesystemAdapter, %{root: root}} and
        observation.vault_id == source.owner.vault_id and observation.inventory == inventory and
        match?(%CiphertextSummary{}, observation.summary) and
        observation.summary.vault_id == source.owner.vault_id and
        observation.summary.object_count == 5 and
        observation.summary.inventory_sha256 == saga12_inventory_digest(source) and
        observation.summary.ciphertext_hashes ==
          Enum.map(
            inventory,
            &%{asset_object_id: &1.asset_object_id, sha256: &1.ciphertext_hash}
          ),
      "native ciphertext result lost independent projected inventory commitment"
    )
  end

  defp saga12_issue!(source, root, issue) do
    binding =
      Map.merge(
        issue.prepared.binding,
        %{manifest_id: source.operation_id, vault_id: source.owner.vault_id}
      )

    require!(
      issue.inventory == projected_inventory!(source) and issue.binding == binding and
        issue.owner_is_caller? and issue.options_preserved? and issue.key_shape? and
        issue.ttl_ms == :timer.minutes(5) and
        issue.key_wrapper == Singularity.Storage.Crypto.KeyWrapper and
        issue.storage == {Singularity.Storage.LocalFilesystemAdapter, %{root: root}} and
        issue.loader == Singularity.Storage.Backup.KnowledgeIntegrityInventory and
        issue.prepared.original == List.to_tuple(source.original_inventory) and
        issue.prepared.projected == List.to_tuple(projected_inventory!(source)) and
        issue.prepared.repo == MigrationRepo and issue.prepared.storage == issue.storage and
        issue.prepared.inventory_hash ==
          :crypto.hash(
            :sha256,
            :erlang.term_to_binary(source.original_inventory, [:deterministic])
          ) and
        issue.prepared.root_hash == :crypto.hash(:sha256, Path.expand(root)),
      "actual native integrity issuance lost original and projected authority binding"
    )
  end

  defp saga12_authenticated!(source, reference) do
    authenticated =
      receive do
        {^reference, :oracle_authenticated, payload} -> payload
      after
        0 -> raise ArgumentError, "restore did not authenticate its original source cut"
      end

    issue =
      receive do
        {^reference, :oracle_issue, payload} -> payload
      after
        0 -> raise ArgumentError, "restore did not enter genuine native integrity issuance"
      end

    handoffs = saga12_messages(reference, :oracle_handoff)
    require!(length(handoffs) == 4, "restore did not preserve all four native inventory handoffs")
    [imported | _] = handoffs

    for handoff <- handoffs do
      require!(
        handoff.manifest_hash == authenticated.manifest_hash and
          handoff.manifest_tag == authenticated.manifest_tag and handoff.owner == imported.owner,
        "native inventory handoff changed authenticated manifest or owner key binding"
      )
    end

    require!(
      byte_size(authenticated.manifest_hash) == 32 and
        byte_size(authenticated.manifest_tag) == 16 and
        issue.prepared.manifest_hash == authenticated.manifest_hash and
        issue.prepared.manifest_tag == authenticated.manifest_tag and
        issue.binding ==
          Map.merge(
            imported.owner,
            %{manifest_id: source.operation_id, vault_id: source.owner.vault_id}
          ) and
        authenticated.cut ==
          Map.merge(
            source.observation.cut,
            %{manifest_id: source.operation_id, logical_version: 3}
          ),
      "native issue lost authenticated exact source cut or manifest commitments"
    )
  end

  defp saga12_materials!(source, reference) do
    observations = saga12_messages(reference, :oracle_material)
    inventory = projected_inventory!(source)

    require!(
      Enum.map(observations, & &1.entry) == inventory,
      "native material calls are not exactly the five ordered projected objects"
    )

    for observation <- observations do
      entry = observation.entry

      require!(
        observation.binding.manifest_id == source.operation_id and
          observation.binding.vault_id == source.owner.vault_id and
          observation.material == %{
            object_id: entry.asset_object_id,
            vault_id: entry.vault_id,
            key_domain_id: entry.key_domain_id,
            classification: entry.classification,
            lookup_digest: entry.lookup_digest,
            ciphertext_hash: entry.ciphertext_hash,
            ciphertext_byte_size: entry.ciphertext_byte_size,
            vault_key_version_id: observation.binding.vault_key_version_id,
            vault_key_generation: observation.binding.vault_key_generation
          },
        "native object material differs from its exact source identity"
      )
    end
  end

  defp saga12_completed!(source) do
    %{rows: rows} =
      saga12_query!(
        """
        SELECT
          (SELECT count(*) FROM audit.events WHERE vault_id=$1 AND target_id=$2
            AND operation='integrity.audit_completed'),
          (SELECT count(*) FROM audit.events WHERE vault_id=$1 AND target_id=$2
            AND operation='backup.restore_completed')
        """,
        [Ecto.UUID.dump!(source.owner.vault_id), Ecto.UUID.dump!(source.operation_id)]
      )

    require!(
      rows == [[1, 1]],
      "restore did not persist exactly one integrity and completion event"
    )
  end

  defp saga12_retired!(source) do
    rows = Canonical.read_committed!(MigrationRepo, source.owner, source.observation.cut)

    for table <- ~w(content.document_versions content.document_fragments
      content.document_import_receipts jobs.job_progress jobs.effect_receipts) do
      require!(
        rows[table] == source.observation.rows[table],
        "native reconciliation changed immutable or retained history"
      )
    end

    before_event =
      row!(
        source.observation.rows,
        "core.outbox_events",
        &(&1["id"] == source.work.submission_id)
      )

    event = row!(rows, "core.outbox_events", &(&1["id"] == source.work.submission_id))

    mutable =
      ~w(claim_token claimed_until runner_job_id delivered_at retired_at retirement_reason updated_at)

    require!(
      event["retirement_reason"] == "restore_effect_already_reflected" and
        not is_nil(event["retired_at"]) and
        Enum.all?(~w(claim_token claimed_until runner_job_id delivered_at), &is_nil(event[&1])) and
        Map.drop(before_event, mutable) == Map.drop(event, mutable),
      "native reconciliation did not retire exactly the reflected original extraction event"
    )

    before_submission =
      row!(
        source.observation.rows,
        "jobs.job_submissions",
        &(&1["id"] == source.work.submission_id)
      )

    submission = row!(rows, "jobs.job_submissions", &(&1["id"] == source.work.submission_id))

    require!(
      is_nil(submission["runner_job_id"]) and
        Map.drop(before_submission, ~w(runner_job_id updated_at)) ==
          Map.drop(submission, ~w(runner_job_id updated_at)),
      "native reconciliation changed the original durable submission envelope"
    )
  end

  defp saga12_login!(source, password) do
    {token, logged_in} =
      case Api.login(%{login: source.credentials.login, password: password, source: "127.0.0.1"}) do
        {:ok, token, logged_in} -> {token, logged_in}
        _ -> raise ArgumentError, "restored public login failed"
      end

    require!(not logged_in.unlocked?, "restored public login bypassed unlock")
    resolved = expect_ok!(Api.resolve_session(token), "restored public session resolution")

    require!(
      resolved.session_id == logged_in.session_id,
      "restored public session resolution changed identity"
    )

    session = expect_ok!(Api.unlock(resolved, password), "restored public unlock")

    require!(
      session.unlocked? and session.session_id != source.owner.session_id and
        session.principal_id == source.owner.principal_id and
        session.vault_id == source.owner.vault_id,
      "restored public unlocked session belongs to the wrong owner"
    )

    session
  end

  defp saga12_public_originals!(source, session) do
    for name <- [:empty, :plain, :unicode, :markdown] do
      original = Map.fetch!(source.sources, name)
      result = Api.download(session, original.asset_id, nil)

      exact? =
        case result do
          {:ok, %{body: bytes, content_length: size, status: 200}} ->
            bytes == original.bytes and size == byte_size(original.bytes)

          _ ->
            false
        end

      require!(exact?, "public restored Asset binary differs from literal upload input")
    end

    original =
      expect_ok!(
        Api.download_document_original(session, source.ids.ready_document_id),
        "public retained Document original"
      )

    require!(
      original.byte_size == byte_size(source.sources.pdf.bytes) and original.chunk_count == 1,
      "public retained PDF descriptor differs from original bytes"
    )

    bytes = expect_ok!(original.read_chunk.(0), "public retained Document original chunk")

    require!(
      bytes == source.sources.pdf.bytes,
      "public retained PDF binary differs from upload input"
    )
  end

  defp saga12_recovery!(source, session, runtime) do
    context = %{repo: WorkerRepo}

    require!(
      ExtractionReconciler.run(context) == {:ok, 1},
      "abandoned extraction recovery did not recover exactly one attempt"
    )

    rows = Canonical.read_committed!(MigrationRepo, source.owner, source.observation.cut)

    expected =
      Enum.map(source.observation.rows["content.document_versions"], fn row ->
        if row["resource_version_id"] == source.ids.extracting_version_id do
          Map.merge(row, %{
            "state" => "pending",
            "attempt_generation" => 2,
            "attempt_job_id" => nil,
            "attempt_started_at" => nil,
            "attempt_deadline_at" => nil,
            "extraction_adapter" => nil,
            "extraction_format" => nil,
            "extracted_text_digest" => nil,
            "detected_language" => nil,
            "failure_code" => nil,
            "attempt_finished_at" => nil
          })
        else
          row
        end
      end)

    require!(
      rows["content.document_versions"] == expected,
      "recovery changed unexpected immutable Document history"
    )

    key = "document-extraction:#{source.ids.extracting_version_id}:2"
    work = saga12_successor!(source, key)
    require!(length(work.event) == 1, "recovery did not persist exactly one successor event")
    [raw_event] = work.event

    [event] =
      Canonical.normalize_rows("core.outbox_events", %{
        columns: Map.keys(raw_event),
        rows: [Map.values(raw_event)]
      })

    require!(
      event["event_type"] == "document.extraction_requested" and
        event["causation_id"] == source.work.submission_id and
        event["correlation_id"] == source.ids.extracting_version_id and
        event["principal_id"] == session.principal_id and event["vault_id"] == session.vault_id and
        event["classification"] == "private" and event["required_capability"] == "asset.read" and
        event["envelope_version"] == 1 and event["expected_entity_revision"] == 2 and
        event["principal_authorization_epoch"] == session.principal_authorization_epoch and
        event["vault_authorization_epoch"] == session.vault_authorization_epoch and
        event["payload"] == %{
          "resource_id" => source.ids.extracting_document_id,
          "resource_version_id" => source.ids.extracting_version_id
        } and
        is_nil(event["retired_at"]) and is_nil(event["retirement_reason"]),
      "recovered successor lost exact authorized immutable Document envelope"
    )

    saga12_no_recovery!(source, context)

    require!(
      saga12_successor!(source, key) == work and
        Canonical.read_committed!(MigrationRepo, source.owner, source.observation.cut)[
          "content.document_versions"
        ] == expected,
      "repeated recovery changed successor work or retained Document state"
    )

    saga12_dispatch!()
    dispatched = saga12_successor!(source, key)
    saga12_runner!(dispatched, event)
    saga12_dispatch!()

    require!(
      saga12_successor!(source, key) == dispatched,
      "repeated dispatch changed actual successor work"
    )

    reconciler =
      expect_ok!(
        Supervisor.start_child(runtime.infrastructure, runtime.deferred_extraction),
        "deferred extraction recovery start"
      )

    require!(Process.alive?(reconciler), "deferred extraction reconciler did not start")
    saga12_no_recovery!(source, context)

    require!(
      saga12_successor!(source, key) == dispatched and
        Canonical.read_committed!(MigrationRepo, source.owner, source.observation.cut)[
          "content.document_versions"
        ] == expected,
      "enabled extraction recovery duplicated work or changed retained history"
    )

    :ok
  end

  defp saga12_no_recovery!(source, context) do
    require!(
      ExtractionReconciler.run(context) == {:ok, 0} and
        DocumentRepository.recover_expired_with_event(
          context,
          source.ids.extracting_version_id,
          source.owner.vault_id
        ) == {:ok, false},
      "repeated recovery was not idempotent"
    )
  end

  defp saga12_dispatch! do
    result = OutboxDispatcher.dispatch_once(%{})
    require!(match?({:ok, %{failed: 0}}, result), "actual successor dispatch failed")
  end

  defp saga12_successor!(source, key) do
    queries = [
      event:
        "SELECT e.* FROM core.outbox_events e WHERE e.vault_id=$1 AND e.idempotency_key=$2 ORDER BY e.id",
      submissions:
        "SELECT s.* FROM jobs.job_submissions s JOIN core.outbox_events e ON e.id=s.outbox_event_id AND e.vault_id=s.vault_id WHERE e.vault_id=$1 AND e.idempotency_key=$2 ORDER BY s.id",
      progress:
        "SELECT p.* FROM jobs.job_progress p JOIN jobs.job_submissions s ON s.id=p.submission_id AND s.vault_id=p.vault_id JOIN core.outbox_events e ON e.id=s.outbox_event_id AND e.vault_id=s.vault_id WHERE e.vault_id=$1 AND e.idempotency_key=$2 ORDER BY p.id",
      effects:
        "SELECT f.* FROM jobs.effect_receipts f JOIN jobs.job_submissions s ON s.id=f.submission_id AND s.vault_id=f.vault_id JOIN core.outbox_events e ON e.id=s.outbox_event_id AND e.vault_id=s.vault_id WHERE e.vault_id=$1 AND e.idempotency_key=$2 ORDER BY f.id",
      runners: """
      SELECT j.* FROM jobs.oban_jobs j WHERE j.args->>'vault_id'=$1::uuid::text AND
        (j.args->>'idempotency_key'=$2 OR j.args->>'job_id' IN
          (SELECT e.id::text FROM core.outbox_events e WHERE e.vault_id=$1 AND e.idempotency_key=$2))
      ORDER BY j.id
      """
    ]

    Map.new(queries, fn {name, sql} ->
      result = saga12_query!(sql, [Ecto.UUID.dump!(source.owner.vault_id), key])
      {name, Enum.map(result.rows, &Map.new(Enum.zip(result.columns, &1)))}
    end)
  end

  defp saga12_runner!(work, expected) do
    require!(
      length(work.event) == 1 and length(work.submissions) == 1 and length(work.runners) == 1,
      "successor does not own exactly one actual event, submission and runner"
    )

    [event] = work.event
    [submission] = work.submissions
    [job] = work.runners
    job_id = Integer.to_string(job["id"])

    require!(
      Ecto.UUID.load!(event["id"]) == expected["id"] and
        submission["id"] == event["id"] and submission["outbox_event_id"] == event["id"] and
        submission["vault_id"] == event["vault_id"] and submission["classification"] == "private" and
        submission["job_type"] == "document_extract" and
        submission["idempotency_key"] == event["idempotency_key"] and
        submission["runner_job_id"] == job_id and event["runner_job_id"] == job_id and
        job["queue"] == "document_extract" and
        job["worker"] == "Singularity.Storage.Jobs.GenericWorker",
      "actual successor runner is not bound to its event and submission"
    )

    args = %{
      "version" => 1,
      "job_id" => expected["id"],
      "job_type" => "document_extract",
      "idempotency_key" => expected["idempotency_key"],
      "vault_id" => expected["vault_id"],
      "principal_id" => expected["principal_id"],
      "required_capability" => expected["required_capability"],
      "principal_authorization_epoch" => expected["principal_authorization_epoch"],
      "vault_authorization_epoch" => expected["vault_authorization_epoch"],
      "classification" => "private",
      "correlation_id" => expected["correlation_id"],
      "causation_id" => expected["causation_id"],
      "expected_entity_revision" => 2,
      "attempt" => 0,
      "payload" => expected["payload"]
    }

    require!(job["args"] == args, "actual successor runner changed the exact authorized envelope")
  end

  defp saga12_unpublished!(source, password) do
    saga12_withheld!()

    %{rows: rows} =
      saga12_query!(
        """
        SELECT
          (SELECT count(*) FROM audit.events WHERE vault_id=$1 AND target_id=$2 AND operation='integrity.audit_completed'),
          (SELECT count(*) FROM audit.events WHERE vault_id=$1 AND target_id=$2 AND operation='backup.restore_completed'),
          (SELECT state FROM audit.restore_import_sagas WHERE singleton),
          (SELECT state FROM audit.knowledge_restore_admissions WHERE singleton),
          (SELECT locked FROM core.vaults WHERE id=$1),
          (SELECT count(*) FROM content.search_entries WHERE vault_id=$1),
          (SELECT count(*) FROM content.asset_search_documents WHERE vault_id=$1),
          (SELECT count(*) FROM content.note_search_documents WHERE vault_id=$1)
        """,
        [Ecto.UUID.dump!(source.owner.vault_id), Ecto.UUID.dump!(source.operation_id)]
      )

    require!(
      rows == [[0, 0, "imported", "validated", true, 0, 0, 0]],
      "late denial published completion, unlocked the owner or rebuilt a search projection"
    )

    # Snapshot before probing login: authentication itself can append audit rows.
    require!(
      Api.login(%{login: source.credentials.login, password: password, source: "127.0.0.1"}) ==
        {:error, :storage_unavailable},
      "late denial exposed ordinary authenticated runtime"
    )
  end

  defp saga12_withheld! do
    require!(
      Application.fetch_env!(:singularity_runtime, :maintenance_mode) == true and
        Application.fetch_env!(:singularity_runtime, :start_infrastructure) == false and
        is_nil(Process.whereis(KeyCustodian)) and is_nil(Process.whereis(OutboxDispatcher)) and
        is_nil(Process.whereis(ExtractionReconciler)) and is_nil(Oban.whereis(Singularity.Oban)),
      "restore activated ordinary runtime before verified publication"
    )
  end

  defp saga12_capability!(reference) do
    receive do
      {^reference, :oracle_capability, capability, monitor} -> {capability, monitor}
    after
      0 -> raise ArgumentError, "restore did not acquire genuine native integrity authority"
    end
  end

  defp saga12_capability_closed!(capability, monitor) do
    closed? =
      receive do
        {:DOWN, ^monitor, :process, lease, :normal} when lease == capability.lease -> true
        {:DOWN, ^monitor, :process, _lease, _reason} -> false
      after
        1_000 -> false
      end

    require!(
      closed? and not Process.alive?(capability.lease),
      "native integrity authority did not close normally"
    )

    require!(
      RestoreIntegrityLease.verify_all(capability) ==
        {:error, Error.new(:backup_invalid, retryable?: false)} and
        RestoreIntegrityLease.revoke(capability) == :ok and
        RestoreIntegrityLease.revoke(capability) == :ok,
      "closed native integrity authority retained access or lost idempotent revocation"
    )
  end

  defp saga12_cleanup_capabilities!(reference) do
    receive do
      {^reference, :oracle_cleanup_capability, capability, monitor} ->
        try do
          if Process.alive?(capability.lease) do
            require!(
              RestoreIntegrityLease.revoke(capability) == :ok,
              "owned native integrity capability cleanup failed"
            )

            saga12_capability_closed!(capability, monitor)
          end
        after
          Process.demonitor(monitor, [:flush])
        end

        saga12_cleanup_capabilities!(reference)
    after
      0 -> :ok
    end
  end

  defp saga12_query!(sql, parameters) do
    expect_ok!(
      MigrationRepo.transaction(
        fn ->
          SafeSQL.query!(
            MigrationRepo,
            "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY",
            []
          )

          SafeSQL.query!(MigrationRepo, "SET LOCAL ROLE singularity_table_owner", [])
          SafeSQL.query!(MigrationRepo, sql, parameters)
        end,
        log: false
      ),
      "independent owned read-only observation"
    )
  end

  defp saga12_events(reference), do: saga12_messages(reference, :oracle_event)

  defp saga12_messages(reference, kind, collected \\ []) do
    receive do
      {^reference, ^kind, value} -> saga12_messages(reference, kind, [value | collected])
    after
      0 -> Enum.reverse(collected)
    end
  end

  defp saga12_settings do
    Map.new([:singularity_runtime, :singularity_storage], fn app ->
      {app, Map.new(Application.get_all_env(app))}
    end)
  end

  defp saga12_closed!(lifecycle) do
    require!(
      (is_nil(lifecycle.infrastructure) or not Process.alive?(lifecycle.infrastructure)) and
        (is_nil(lifecycle.observer) or not Process.alive?(lifecycle.observer)) and
        Enum.all?(lifecycle.repositories, fn {_repo, {pid, _database}} ->
          not Process.alive?(pid)
        end) and
        not File.exists?(lifecycle.object_root),
      "owned native oracle lifecycle did not fully close"
    )
  end

  defp saga12_directory_identity!(root) do
    stat = File.lstat!(root)
    require!(stat.type == :directory, "oracle portability root is not a real owned directory")
    {stat.major_device, stat.minor_device, stat.inode}
  end

  defp saga12_remove_portable!(root, identity) do
    require!(
      saga12_directory_identity!(root) == identity,
      "oracle portability cleanup directory identity changed"
    )

    for name <- File.ls!(root) do
      require!(
        Regex.match?(
          ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.bundle\z/,
          name
        ),
        "oracle portability cleanup encountered an unowned entry"
      )

      path = Path.join(root, name)
      require!(File.lstat!(path).type == :regular, "oracle bundle cleanup encountered a non-file")
      File.rm!(path)
    end

    File.rmdir!(root)
    :ok
  end

  defp saga12_cleanly!(operation, cleanup) do
    try do
      operation.()
    catch
      _kind, _reason ->
        IO.puts(:stderr, "knowledge_restore stage=owned_operation status=fail")
        raise ArgumentError, "independent knowledge operation failed after owned cleanup"
    after
      try do
        cleanup.()
      catch
        _cleanup_kind, _cleanup_reason ->
          IO.puts(:stderr, "knowledge_restore stage=owned_cleanup status=fail")
          raise ArgumentError, "independent knowledge owned cleanup failed"
      end
    end
  end

  # END internal saga12 independent task oracle.
end
