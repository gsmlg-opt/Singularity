defmodule Singularity.Runtime.IntegrityAuditTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.Error
  alias Singularity.Runtime.IntegrityAudit
  alias Singularity.Runtime.RestoreIntegrityLease.Capability
  alias Singularity.Runtime.RestoreIntegrityLease.PlaintextSummary
  alias Singularity.Storage.Backup.IntegrityAudit.CiphertextSummary
  alias Singularity.Storage.Backup.IntegrityAudit.SearchSummary

  @vault_id "72000000-0000-0000-0000-000000000001"
  @manifest_id "72000000-0000-0000-0000-000000000002"
  @principal_id "72000000-0000-0000-0000-000000000003"
  @object_id "72000000-0000-0000-0000-000000000004"
  @domain_id "72000000-0000-0000-0000-000000000005"

  defmodule CiphertextAuditor do
    def verify_ciphertext(context, storage, vault_id, inventory) do
      send(context.owner, {:ciphertext, storage, vault_id, inventory})
      context.result
    end
  end

  defmodule Lease do
    def verify_all(%Capability{lease: lease}) do
      Agent.get(lease, fn state ->
        send(state.owner, :plaintext_verified)
        state.result
      end)
    end

    def revoke(%Capability{lease: lease}) do
      Agent.update(lease, fn state ->
        send(state.owner, :capability_revoked)
        %{state | revoked?: true}
      end)

      :ok
    catch
      :exit, _reason -> :ok
    end
  end

  defmodule LexicalRebuilder do
    def rebuild(context, binding) do
      send(context.owner, {:lexical_rebuild, binding})
      context.result
    end
  end

  defmodule AuditPersistence do
    def complete(context, command) do
      send(context.owner, {:audit_complete, command})
      context.result
    end
  end

  test "locked and plaintext phases bind ciphertext, metadata search, and audit evidence" do
    fixture = fixture()

    assert :ok = IntegrityAudit.verify_ciphertext(fixture.context, fixture.rewrapped)

    assert_receive {:ciphertext, :restored_object_storage, @vault_id, [entry]}
    assert entry.asset_object_id == @object_id
    refute_receive :plaintext_verified

    assert :ok =
             IntegrityAudit.verify_plaintext_and_search(fixture.context, fixture.rewrapped)

    assert_receive {:ciphertext, :restored_object_storage, @vault_id, [_entry]}
    assert_receive :plaintext_verified
    assert_receive {:lexical_rebuild, binding}
    assert binding == %{manifest_id: @manifest_id, vault_id: @vault_id}

    assert_receive {:audit_complete,
                    %{
                      operation: "integrity.audit_completed",
                      vault_id: @vault_id,
                      manifest_id: @manifest_id,
                      integrity_principal_id: @principal_id,
                      object_count: 1,
                      ciphertext_inventory_sha256: ciphertext_inventory_sha256,
                      plaintext_inventory_sha256: plaintext_inventory_sha256,
                      search_rebuild_sha256: search_rebuild_sha256,
                      correlation_id: correlation_id
                    } = command}

    assert byte_size(ciphertext_inventory_sha256) == 32
    assert byte_size(plaintext_inventory_sha256) == 32
    assert search_rebuild_sha256 == fixture.lexical_hash
    assert {:ok, ^correlation_id} = Ecto.UUID.cast(correlation_id)
    refute inspect(command) =~ fixture.plaintext_canary
    refute inspect(command) =~ fixture.key_canary
    assert_receive :capability_revoked
    assert Agent.get(fixture.lease, & &1.revoked?)
  end

  test "an identical integrity retry uses the same manifest-bound correlation identity" do
    fixture = fixture()

    assert :ok =
             IntegrityAudit.verify_plaintext_and_search(fixture.context, fixture.rewrapped)

    assert_receive {:audit_complete, first_command}

    assert :ok =
             IntegrityAudit.verify_plaintext_and_search(fixture.context, fixture.rewrapped)

    assert_receive {:audit_complete, second_command}

    assert first_command.correlation_id == second_command.correlation_id

    assert <<_::binary-size(6), version::4, _::12, variant::2, _::62>> =
             Ecto.UUID.dump!(first_command.correlation_id)

    assert version == 5
    assert variant == 2
  end

  test "a missing or malformed metadata-search adapter fails closed before audit and revokes custody" do
    fixture = fixture()

    missing_search = Map.delete(fixture.context, :search_rebuilder)

    assert {:error, %Error{code: :invalid}} =
             IntegrityAudit.verify_plaintext_and_search(missing_search, fixture.rewrapped)

    assert_receive :capability_revoked
    refute_receive {:audit_complete, _command}

    malformed = fixture(lexical_result: {:ok, %{projection: "invalid"}})

    assert {:error, %Error{code: :storage_unavailable, retryable?: true}} =
             IntegrityAudit.verify_plaintext_and_search(malformed.context, malformed.rewrapped)

    assert_receive {:lexical_rebuild, _binding}
    assert_receive :capability_revoked
    refute_receive {:audit_complete, _command}
  end

  test "search or audit failure never leaks adapter details and always revokes custody" do
    lexical_failure =
      fixture(
        lexical_result:
          {:error,
           Error.new(:storage_unavailable,
             retryable?: true,
             message: "plaintext and key canary must be redacted",
             details: %{secret: "never-return-this"}
           )}
      )

    assert {:error,
            %Error{
              code: :storage_unavailable,
              retryable?: true,
              message: nil,
              details: %{}
            }} =
             IntegrityAudit.verify_plaintext_and_search(
               lexical_failure.context,
               lexical_failure.rewrapped
             )

    assert_receive :capability_revoked
    refute_receive {:audit_complete, _command}

    audit_failure = fixture(audit_result: {:error, Error.new(:conflict, message: "secret")})

    assert {:error, %Error{code: :conflict, message: nil, details: %{}}} =
             IntegrityAudit.verify_plaintext_and_search(
               audit_failure.context,
               audit_failure.rewrapped
             )

    assert_receive {:audit_complete, _command}
    assert_receive :capability_revoked
  end

  test "mismatched plaintext evidence blocks search rebuild and completion" do
    fixture = fixture(plaintext_inventory_sha256: :binary.copy(<<0xFF>>, 32))

    assert {:error, %Error{code: :integrity_failure}} =
             IntegrityAudit.verify_plaintext_and_search(fixture.context, fixture.rewrapped)

    assert_receive :capability_revoked
    refute_receive {:lexical_rebuild, _binding}
    refute_receive {:audit_complete, _command}
  end

  test "malformed adapter success is unavailable rather than accepted as a no-op" do
    fixture = fixture(ciphertext_result: :ok)

    assert {:error, %Error{code: :storage_unavailable, retryable?: true}} =
             IntegrityAudit.verify_ciphertext(fixture.context, fixture.rewrapped)

    fixture = fixture(plaintext_result: :ok)

    assert {:error, %Error{code: :storage_unavailable, retryable?: true}} =
             IntegrityAudit.verify_plaintext_and_search(fixture.context, fixture.rewrapped)

    assert_receive :capability_revoked
    refute_receive {:lexical_rebuild, _binding}
  end

  test "public cleanup is synchronous, idempotent, and never masks a primary failure" do
    fixture = fixture()

    assert :ok = IntegrityAudit.revoke(fixture.context, fixture.rewrapped)
    assert_receive :capability_revoked
    assert Agent.get(fixture.lease, & &1.revoked?)

    assert :ok = IntegrityAudit.revoke(fixture.context, fixture.rewrapped)
    assert_receive :capability_revoked

    assert :ok = IntegrityAudit.revoke(%{}, fixture.rewrapped)
    assert :ok = IntegrityAudit.revoke(fixture.context, %{})
  end

  test "integrity job loading is an injected port and never accepts envelope authority as a subject" do
    envelope = %{job_type: "integrity_audit", vault_id: @vault_id}

    assert {:error, %Error{code: :invalid}} = IntegrityAudit.run(%{}, envelope)
    assert {:error, %Error{code: :job_failed}} = IntegrityAudit.run(%{}, %{})
  end

  defp fixture(options \\ []) do
    plaintext_canary = "plaintext-canary-never-returned"
    key_canary = "key-canary-never-returned"
    ciphertext_hash = :crypto.hash(:sha256, "ciphertext")
    lookup_digest = :crypto.hash(:sha256, "lookup")

    entry = %{
      asset_object_id: @object_id,
      ciphertext_byte_size: 123,
      ciphertext_hash: ciphertext_hash,
      classification: :restricted,
      inventory_position: 0,
      key_domain_id: @domain_id,
      lookup_digest: lookup_digest,
      storage_ref: @object_id,
      vault_id: @vault_id
    }

    {:ok, inventory_sha256} =
      Singularity.Storage.Backup.IntegrityAudit.inventory_sha256(@vault_id, [entry])

    plaintext_hash = :crypto.hash(:sha256, plaintext_canary)

    expected_plaintext_inventory_sha256 =
      plaintext_inventory_sha256([{@object_id, plaintext_hash}])

    ciphertext_summary = %CiphertextSummary{
      vault_id: @vault_id,
      object_count: 1,
      inventory_sha256: inventory_sha256,
      ciphertext_hashes: [%{asset_object_id: @object_id, sha256: ciphertext_hash}]
    }

    plaintext_summary = %PlaintextSummary{
      vault_id: @vault_id,
      object_count: 1,
      inventory_sha256: Keyword.get(options, :plaintext_inventory_sha256, inventory_sha256),
      plaintext_hashes: [%{asset_object_id: @object_id, sha256: plaintext_hash}]
    }

    lexical_hash = :crypto.hash(:sha256, "lexical")

    lexical_summary = %SearchSummary{
      projection: "postgres_metadata_v1",
      document_count: 1,
      result_sha256: lexical_hash
    }

    owner = self()

    {:ok, lease} =
      Agent.start_link(fn ->
        %{
          owner: owner,
          result: Keyword.get(options, :plaintext_result, {:ok, plaintext_summary}),
          revoked?: false
        }
      end)

    capability = %Capability{lease: lease, token: make_ref()}

    context = %{
      audit:
        {AuditPersistence, %{owner: self(), result: Keyword.get(options, :audit_result, :ok)}},
      ciphertext_auditor:
        {CiphertextAuditor,
         %{
           owner: self(),
           result: Keyword.get(options, :ciphertext_result, {:ok, ciphertext_summary})
         }},
      object_storage: :restored_object_storage,
      restore_integrity_lease: Lease,
      search_rebuilder:
        {LexicalRebuilder,
         %{
           owner: self(),
           result: Keyword.get(options, :lexical_result, {:ok, lexical_summary})
         }}
    }

    rewrapped = %{
      cut: %{vault_id: @vault_id, object_inventory: [entry]},
      integrity_capability: capability,
      integrity_principal_id: @principal_id,
      manifest: %{manifest_id: @manifest_id},
      object_inventory: [entry]
    }

    %{
      context: context,
      expected_plaintext_inventory_sha256: expected_plaintext_inventory_sha256,
      key_canary: key_canary,
      lease: lease,
      lexical_hash: lexical_hash,
      plaintext_canary: plaintext_canary,
      rewrapped: rewrapped
    }
  end

  defp plaintext_inventory_sha256(entries) do
    encoded =
      Enum.map(entries, fn {object_id, hash} ->
        {:ok, uuid} = Ecto.UUID.dump(object_id)
        [uuid, hash]
      end)

    :crypto.hash(:sha256, ["SINGULARITY-PLAINTEXT-INTEGRITY-V1\0", encoded])
  end
end

defmodule Singularity.Runtime.KnowledgeIntegrityAuditTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.Error
  alias Singularity.Runtime.IntegrityAudit

  alias Singularity.Runtime.IntegrityAuditTest.{
    AuditPersistence,
    CiphertextAuditor,
    Lease,
    LexicalRebuilder
  }

  alias Singularity.Runtime.RestoreIntegrityLease.{Capability, PlaintextSummary}
  alias Singularity.Storage.Backup.IntegrityAudit, as: StorageIntegrityAudit
  alias Singularity.Storage.Backup.IntegrityAudit.{CiphertextSummary, SearchSummary}
  alias Singularity.Storage.Local.PathGuard
  alias Singularity.Storage.LocalFilesystemAdapter

  @moduletag :tmp_dir
  @owner "75000000-0000-4000-8000-000000000001"
  @manifest "75000000-0000-4000-8000-000000000002"
  @principal "75000000-0000-4000-8000-000000000003"
  @domain "75000000-0000-4000-8000-000000000005"

  # BEGIN Task9E inverse receipt (baseline SHA256 811774b48d7b740fcc0c6893c4863b22e055733e06ffe5f9b8dcfab9b1d0b929).
  # To recover the exact pre-E file, remove this block and both BEGIN/END Task9E
  # blocks with their following blank line. Remove the Task9E original-I comment
  # and its following assert_next_event block with its following blank line.
  # Remove only the four refute_received lines carrying the Task9E summary-denial
  # marker. In v3_fixture only, replace Task9EDocumentRebuilder with LexicalRebuilder
  # and remove the two lines carrying Task9E fixture markers. Keep all old lines.
  # END Task9E inverse receipt.

  # BEGIN Task9E recording adapters. These prove coordinator wiring, not native custody.
  defmodule Task9EDocumentRebuilder do
    def verify_document_sources(context, binding, original_inventory, plaintext_hashes) do
      send(context.owner, {:document_sources, binding, original_inventory, plaintext_hashes})
      context.document_result
    end

    def rebuild(context, binding) do
      send(context.owner, {:lexical_rebuild, binding})
      context.result
    end
  end

  defmodule Task9EModuleDocumentRebuilder do
    def verify_document_sources(binding, original_inventory, plaintext_hashes) do
      send(self(), {:document_sources, binding, original_inventory, plaintext_hashes})
      :ok
    end

    def rebuild(binding) do
      send(self(), {:lexical_rebuild, binding})

      {:ok,
       %SearchSummary{
         projection: "postgres_metadata_v1",
         document_count: 2,
         result_sha256: :crypto.hash(:sha256, "search")
       }}
    end
  end

  defmodule Task9EModuleLegacyRebuilder do
    def rebuild(binding), do: Task9EModuleDocumentRebuilder.rebuild(binding)
  end

  # END Task9E recording adapters.

  for mode <- [:uuid, :canonical, :mixed],
      entrypoint <- [:verify_ciphertext, :verify_plaintext_and_search] do
    test "V3 #{mode} #{entrypoint} uses exact UUID inventory and preserves the original cut",
         ctx do
      fixture = v3_fixture(ctx.tmp_dir, unquote(mode))
      original = fixture.rewrapped.object_inventory
      original_bytes = :erlang.term_to_binary(fixture.rewrapped, [:deterministic])

      assert :ok =
               apply(IntegrityAudit, unquote(entrypoint), [fixture.context, fixture.rewrapped])

      assert_next_event({:ciphertext, fixture.storage, @owner, fixture.projected})

      if unquote(entrypoint) == :verify_plaintext_and_search do
        assert_next_event(:plaintext_verified)
        # Task9E: original I and actual typed-summary pairs precede rebuilding.
        assert_next_event(
          {:document_sources, %{manifest_id: @manifest, vault_id: @owner}, original,
           fixture.plaintext_summary.plaintext_hashes}
        )

        assert_next_event({:lexical_rebuild, %{manifest_id: @manifest, vault_id: @owner}})
        assert_receive {:audit_complete, command}
        assert command.ciphertext_inventory_sha256 === fixture.inventory_hash
        assert command.plaintext_inventory_sha256 === fixture.plaintext_inventory_hash
        assert command.search_rebuild_sha256 === fixture.search_hash
        assert command.object_count == 2
        assert command.manifest_id == @manifest
        assert command.vault_id == @owner
        assert command.integrity_principal_id == @principal
        assert_next_event(:capability_revoked)
        assert Agent.get(fixture.lease, & &1.revoked?)
      else
        refute_received :plaintext_verified
        # Task9E summary-denial
        refute_received {:document_sources, _binding, _original, _hashes}
        refute_received {:lexical_rebuild, _binding}
        refute_received {:audit_complete, _command}
        refute_received :capability_revoked
      end

      assert fixture.rewrapped.cut.object_inventory === original
      assert fixture.rewrapped.object_inventory === original
      assert :erlang.term_to_binary(fixture.rewrapped, [:deterministic]) === original_bytes

      assert Enum.zip(original, fixture.projected)
             |> Enum.all?(fn {original, projected} ->
               Map.delete(original, :storage_ref) === Map.delete(projected, :storage_ref)
             end)

      # These recording ports prove projection, ordering and summaries, not source authentication.
    end
  end

  for mutation <- [:owner, :count, :digest, :order, :hash, :missing, :extra] do
    test "dishonest V3 ciphertext #{mutation} evidence denies both entrypoints without rebuilding",
         ctx do
      for entrypoint <- [:verify_ciphertext, :verify_plaintext_and_search] do
        fixture =
          v3_fixture(ctx.tmp_dir, :mixed,
            ciphertext_change: &change_ciphertext(&1, unquote(mutation))
          )

        expected_code =
          if unquote(mutation) in [:owner, :count],
            do: :storage_unavailable,
            else: :integrity_failure

        assert {:error,
                %Error{code: ^expected_code, message: nil, details: %{}, retryable?: retryable}} =
                 apply(IntegrityAudit, entrypoint, [fixture.context, fixture.rewrapped])

        assert retryable == (expected_code == :storage_unavailable)
        assert_next_event({:ciphertext, fixture.storage, @owner, fixture.projected})
        refute_received :plaintext_verified
        # Task9E summary-denial
        refute_received {:document_sources, _binding, _original, _hashes}
        refute_received {:lexical_rebuild, _binding}
        refute_received {:audit_complete, _command}

        if entrypoint == :verify_plaintext_and_search do
          assert_next_event(:capability_revoked)
          assert Agent.get(fixture.lease, & &1.revoked?)
        else
          refute_received :capability_revoked
        end
      end
    end
  end

  for mutation <- [:owner, :count, :digest, :order, :hash_shape, :missing, :duplicate, :extra] do
    test "dishonest V3 plaintext #{mutation} evidence denies after projected ciphertext and revokes",
         ctx do
      fixture =
        v3_fixture(ctx.tmp_dir, :canonical,
          plaintext_change: &change_plaintext(&1, unquote(mutation))
        )

      expected_code =
        if unquote(mutation) in [:owner, :count],
          do: :storage_unavailable,
          else: :integrity_failure

      assert {:error,
              %Error{code: ^expected_code, message: nil, details: %{}, retryable?: retryable}} =
               IntegrityAudit.verify_plaintext_and_search(fixture.context, fixture.rewrapped)

      assert retryable == (expected_code == :storage_unavailable)
      assert_next_event({:ciphertext, fixture.storage, @owner, fixture.projected})
      assert_next_event(:plaintext_verified)
      assert_next_event(:capability_revoked)
      # Task9E summary-denial
      refute_received {:document_sources, _binding, _original, _hashes}
      refute_received {:lexical_rebuild, _binding}
      refute_received {:audit_complete, _command}
      assert Agent.get(fixture.lease, & &1.revoked?)
    end
  end

  for entrypoint <- [:verify_ciphertext, :verify_plaintext_and_search] do
    test "V3 original cut disagreement denies #{entrypoint} before any content port", ctx do
      fixture = v3_fixture(ctx.tmp_dir, :mixed)

      rewrapped = %{
        fixture.rewrapped
        | cut: %{fixture.rewrapped.cut | object_inventory: fixture.projected}
      }

      assert rewrapped.object_inventory !== rewrapped.cut.object_inventory

      assert {:error, %Error{code: :backup_invalid, message: nil, details: %{}}} =
               apply(IntegrityAudit, unquote(entrypoint), [fixture.context, rewrapped])

      refute_received {:ciphertext, _storage, _owner, _inventory}
      refute_received :plaintext_verified
      # Task9E summary-denial
      refute_received {:document_sources, _binding, _original, _hashes}
      refute_received {:lexical_rebuild, _binding}
      refute_received {:audit_complete, _command}

      if unquote(entrypoint) == :verify_plaintext_and_search,
        do: assert_next_event(:capability_revoked),
        else: refute_received(:capability_revoked)
    end
  end

  # BEGIN Task9E additional contracts.
  for adapter_form <- [:module, :context] do
    test "Task9E V3 #{adapter_form} callback receives exactly original I and validated hashes",
         ctx do
      fixture = v3_fixture(ctx.tmp_dir, :mixed)

      context =
        if unquote(adapter_form) == :module,
          do: %{fixture.context | search_rebuilder: Task9EModuleDocumentRebuilder},
          else: fixture.context

      original = fixture.rewrapped.object_inventory
      assert original !== fixture.projected

      assert Map.keys(fixture.rewrapped.cut) |> Enum.sort() ==
               [:logical_version, :manifest_id, :object_inventory, :vault_id]

      assert :ok = IntegrityAudit.verify_plaintext_and_search(context, fixture.rewrapped)
      assert_next_event({:ciphertext, fixture.storage, @owner, fixture.projected})
      assert_next_event(:plaintext_verified)

      assert_next_event(
        {:document_sources, %{manifest_id: @manifest, vault_id: @owner}, original,
         fixture.plaintext_summary.plaintext_hashes}
      )

      assert_next_event({:lexical_rebuild, %{manifest_id: @manifest, vault_id: @owner}})
      assert_receive {:audit_complete, command}
      assert command.plaintext_inventory_sha256 === fixture.plaintext_inventory_hash
      assert command.ciphertext_inventory_sha256 === fixture.inventory_hash
      assert command.search_rebuild_sha256 === fixture.search_hash
      assert_next_event(:capability_revoked)
      assert Agent.get(fixture.lease, & &1.revoked?)
      refute_received {:document_sources, _binding, _original, _hashes}
    end
  end

  test "Task9E Document callback consumes the actual validated lease hashes without replacement",
       ctx do
    actual_hash = <<73::256>>

    fixture =
      v3_fixture(ctx.tmp_dir, :canonical,
        plaintext_change: fn summary ->
          [first, second] = summary.plaintext_hashes
          %{summary | plaintext_hashes: [%{first | sha256: actual_hash}, second]}
        end
      )

    assert :ok = IntegrityAudit.verify_plaintext_and_search(fixture.context, fixture.rewrapped)
    assert_next_event({:ciphertext, fixture.storage, @owner, fixture.projected})
    assert_next_event(:plaintext_verified)

    assert_next_event(
      {:document_sources, %{manifest_id: @manifest, vault_id: @owner},
       fixture.rewrapped.object_inventory, fixture.plaintext_summary.plaintext_hashes}
    )

    assert [%{sha256: ^actual_hash}, _second] = fixture.plaintext_summary.plaintext_hashes
    assert_next_event({:lexical_rebuild, %{manifest_id: @manifest, vault_id: @owner}})
    assert_receive {:audit_complete, command}

    expected_hash =
      :crypto.hash(:sha256, [
        "SINGULARITY-PLAINTEXT-INTEGRITY-V1\0",
        Enum.map(fixture.plaintext_summary.plaintext_hashes, fn entry ->
          [Ecto.UUID.dump!(entry.asset_object_id), entry.sha256]
        end)
      ])

    assert command.plaintext_inventory_sha256 === expected_hash
    refute command.plaintext_inventory_sha256 === fixture.plaintext_inventory_hash
    assert_next_event(:capability_revoked)
    assert Agent.get(fixture.lease, & &1.revoked?)
  end

  for version <- [:absent, 1, 2], adapter_form <- [:module, :context] do
    test "Task9E legacy #{version} #{adapter_form} adapter needs no Document callback",
         ctx do
      fixture = v3_fixture(ctx.tmp_dir, :uuid)

      cut =
        if unquote(version) == :absent,
          do: Map.delete(fixture.rewrapped.cut, :logical_version),
          else: Map.put(fixture.rewrapped.cut, :logical_version, unquote(version))

      search_rebuilder =
        if unquote(adapter_form) == :module,
          do: Task9EModuleLegacyRebuilder,
          else: {LexicalRebuilder, elem(fixture.context.search_rebuilder, 1)}

      # Unauthenticated lookalike fields must not select the V3 callback.
      context = fixture.context |> Map.put(:search_rebuilder, search_rebuilder)
      context = Map.put(context, :logical_version, 3)
      rewrapped = fixture.rewrapped |> Map.put(:cut, cut) |> Map.put(:logical_version, 3)

      assert :ok = IntegrityAudit.verify_plaintext_and_search(context, rewrapped)
      assert_next_event({:ciphertext, fixture.storage, @owner, fixture.projected})
      assert_next_event(:plaintext_verified)
      assert_next_event({:lexical_rebuild, %{manifest_id: @manifest, vault_id: @owner}})
      assert_receive {:audit_complete, command}
      assert command.plaintext_inventory_sha256 === fixture.plaintext_inventory_hash
      assert command.ciphertext_inventory_sha256 === fixture.inventory_hash
      assert command.search_rebuild_sha256 === fixture.search_hash
      assert_next_event(:capability_revoked)
      assert Agent.get(fixture.lease, & &1.revoked?)
      refute_received {:document_sources, _binding, _original, _hashes}
    end
  end

  for adapter_form <- [:module, :context] do
    test "Task9E V3 missing #{adapter_form} Document callback denies before rebuild and revokes",
         ctx do
      fixture = v3_fixture(ctx.tmp_dir, :mixed)

      search_rebuilder =
        if unquote(adapter_form) == :module,
          do: Task9EModuleLegacyRebuilder,
          else: {LexicalRebuilder, elem(fixture.context.search_rebuilder, 1)}

      context = %{fixture.context | search_rebuilder: search_rebuilder}

      assert {:error, %Error{code: :invalid, message: nil, details: %{}}} =
               IntegrityAudit.verify_plaintext_and_search(context, fixture.rewrapped)

      assert_receive :capability_revoked
      assert Agent.get(fixture.lease, & &1.revoked?)
      refute_received {:document_sources, _binding, _original, _hashes}
      refute_received {:lexical_rebuild, _binding}
      refute_received {:audit_complete, _command}
    end
  end

  for version <- [nil, 0, 4, "3"],
      entrypoint <- [:verify_ciphertext, :verify_plaintext_and_search] do
    test "Task9E explicit unknown version #{inspect(version)} denies #{entrypoint} without fallback",
         ctx do
      fixture = v3_fixture(ctx.tmp_dir, :uuid)
      cut = Map.put(fixture.rewrapped.cut, :logical_version, unquote(version))
      rewrapped = %{fixture.rewrapped | cut: cut}

      assert {:error, %Error{code: :backup_invalid, message: nil, details: %{}}} =
               apply(IntegrityAudit, unquote(entrypoint), [fixture.context, rewrapped])

      refute_received {:ciphertext, _storage, _owner, _inventory}
      refute_received :plaintext_verified
      refute_received {:document_sources, _binding, _original, _hashes}
      refute_received {:lexical_rebuild, _binding}
      refute_received {:audit_complete, _command}

      if unquote(entrypoint) == :verify_plaintext_and_search do
        assert_next_event(:capability_revoked)
        assert Agent.get(fixture.lease, & &1.revoked?)
      else
        refute_received :capability_revoked
      end
    end
  end

  for mutation <- [:missing_key, :extra_key, :not_map] do
    test "Task9E malformed plaintext entry #{mutation} denies before Document callback", ctx do
      fixture =
        v3_fixture(ctx.tmp_dir, :canonical,
          plaintext_change: fn summary ->
            [first, second] = summary.plaintext_hashes

            changed =
              case unquote(mutation) do
                :missing_key -> Map.delete(first, :sha256)
                :extra_key -> Map.put(first, :untrusted, "plaintext-canary")
                :not_map -> {first.asset_object_id, first.sha256}
              end

            %{summary | plaintext_hashes: [changed, second]}
          end
        )

      assert {:error, %Error{code: :integrity_failure, message: nil, details: %{}}} =
               IntegrityAudit.verify_plaintext_and_search(fixture.context, fixture.rewrapped)

      assert_next_event({:ciphertext, fixture.storage, @owner, fixture.projected})
      assert_next_event(:plaintext_verified)
      assert_next_event(:capability_revoked)
      assert Agent.get(fixture.lease, & &1.revoked?)
      refute_received {:document_sources, _binding, _original, _hashes}
      refute_received {:lexical_rebuild, _binding}
      refute_received {:audit_complete, _command}
    end
  end

  for mutation <- [:untyped, :bad_digest, :bad_hash_list] do
    test "Task9E malformed typed plaintext summary #{mutation} denies before Document callback",
         ctx do
      fixture =
        v3_fixture(ctx.tmp_dir, :mixed,
          plaintext_change: fn summary ->
            case unquote(mutation) do
              :untyped -> Map.from_struct(summary)
              :bad_digest -> %{summary | inventory_sha256: <<1>>}
              :bad_hash_list -> %{summary | plaintext_hashes: :untrusted}
            end
          end
        )

      assert {:error,
              %Error{code: :storage_unavailable, retryable?: true, message: nil, details: %{}}} =
               IntegrityAudit.verify_plaintext_and_search(fixture.context, fixture.rewrapped)

      assert_next_event({:ciphertext, fixture.storage, @owner, fixture.projected})
      assert_next_event(:plaintext_verified)
      assert_next_event(:capability_revoked)
      assert Agent.get(fixture.lease, & &1.revoked?)
      refute_received {:document_sources, _binding, _original, _hashes}
      refute_received {:lexical_rebuild, _binding}
      refute_received {:audit_complete, _command}
    end
  end

  for {code, retryable} <- [{:integrity_failure, false}, {:storage_unavailable, true}] do
    test "Task9E Document helper #{code} errors are sanitized and revoke before completion",
         ctx do
      fixture =
        v3_fixture(ctx.tmp_dir, :mixed,
          document_result:
            {:error,
             Error.new(unquote(code),
               retryable?: unquote(retryable),
               message: "document-plaintext-canary",
               details: %{secret: "document-key-canary"}
             )}
        )

      assert {:error,
              %Error{
                code: unquote(code),
                retryable?: unquote(retryable),
                message: nil,
                details: %{}
              } = error} =
               IntegrityAudit.verify_plaintext_and_search(fixture.context, fixture.rewrapped)

      refute inspect(error) =~ "document-plaintext-canary"
      refute inspect(error) =~ "document-key-canary"
      assert_next_event({:ciphertext, fixture.storage, @owner, fixture.projected})
      assert_next_event(:plaintext_verified)

      assert_next_event(
        {:document_sources, %{manifest_id: @manifest, vault_id: @owner},
         fixture.rewrapped.object_inventory, fixture.plaintext_summary.plaintext_hashes}
      )

      assert_next_event(:capability_revoked)
      assert Agent.get(fixture.lease, & &1.revoked?)
      refute_received {:lexical_rebuild, _binding}
      refute_received {:audit_complete, _command}
    end
  end

  for result <- [:verified, nil, {:ok, :verified}, {:ok, %{}}, {:error, :secret}] do
    test "Task9E malformed Document helper result #{inspect(result)} denies and revokes", ctx do
      fixture = v3_fixture(ctx.tmp_dir, :mixed, document_result: unquote(Macro.escape(result)))

      assert {:error,
              %Error{code: :storage_unavailable, retryable?: true, message: nil, details: %{}}} =
               IntegrityAudit.verify_plaintext_and_search(fixture.context, fixture.rewrapped)

      assert_next_event({:ciphertext, fixture.storage, @owner, fixture.projected})
      assert_next_event(:plaintext_verified)

      assert_next_event(
        {:document_sources, %{manifest_id: @manifest, vault_id: @owner},
         fixture.rewrapped.object_inventory, fixture.plaintext_summary.plaintext_hashes}
      )

      assert_next_event(:capability_revoked)
      assert Agent.get(fixture.lease, & &1.revoked?)
      refute_received {:lexical_rebuild, _binding}
      refute_received {:audit_complete, _command}
    end
  end

  # END Task9E additional contracts.

  defp v3_fixture(root, mode, options \\ []) do
    projected =
      for {id, position} <- [{id(4), 0}, {id(6), 1}] do
        %{
          asset_object_id: id,
          ciphertext_byte_size: 134 + position,
          ciphertext_hash: :crypto.hash(:sha256, "ciphertext-#{position}"),
          classification: :restricted,
          inventory_position: position,
          key_domain_id: @domain,
          lookup_digest: :crypto.hash(:sha256, "lookup-#{position}"),
          storage_ref: id,
          vault_id: @owner
        }
      end

    original =
      Enum.map(projected, fn entry ->
        if mode == :canonical or (mode == :mixed and entry.inventory_position == 1) do
          assert {:ok, path} =
                   PathGuard.object_path(
                     root,
                     entry.vault_id,
                     entry.key_domain_id,
                     Base.encode16(entry.lookup_digest, case: :lower)
                   )

          %{entry | storage_ref: Path.relative_to(path, Path.expand(root))}
        else
          entry
        end
      end)

    assert {:ok, inventory_hash} = StorageIntegrityAudit.inventory_sha256(@owner, projected)

    plaintext_hashes =
      Enum.map(projected, fn entry ->
        %{
          asset_object_id: entry.asset_object_id,
          sha256: :crypto.hash(:sha256, "plaintext-#{entry.inventory_position}")
        }
      end)

    plaintext_inventory_hash =
      :crypto.hash(:sha256, [
        "SINGULARITY-PLAINTEXT-INTEGRITY-V1\0",
        Enum.map(plaintext_hashes, fn entry ->
          [Ecto.UUID.dump!(entry.asset_object_id), entry.sha256]
        end)
      ])

    ciphertext = %CiphertextSummary{
      vault_id: @owner,
      object_count: 2,
      inventory_sha256: inventory_hash,
      ciphertext_hashes:
        Enum.map(projected, fn entry ->
          %{asset_object_id: entry.asset_object_id, sha256: entry.ciphertext_hash}
        end)
    }

    plaintext = %PlaintextSummary{
      vault_id: @owner,
      object_count: 2,
      inventory_sha256: inventory_hash,
      plaintext_hashes: plaintext_hashes
    }

    ciphertext = Keyword.get(options, :ciphertext_change, &Function.identity/1).(ciphertext)
    plaintext = Keyword.get(options, :plaintext_change, &Function.identity/1).(plaintext)
    caller = self()

    lease =
      start_supervised!(
        {Agent, fn -> %{owner: caller, result: {:ok, plaintext}, revoked?: false} end},
        id: make_ref()
      )

    storage = {LocalFilesystemAdapter, %{root: root}}
    search_hash = :crypto.hash(:sha256, "search")

    context = %{
      object_storage: storage,
      restore_integrity_lease: Lease,
      ciphertext_auditor: {CiphertextAuditor, %{owner: self(), result: {:ok, ciphertext}}},
      search_rebuilder:
        {Task9EDocumentRebuilder,
         %{
           owner: self(),
           # Task9E fixture result
           document_result: Keyword.get(options, :document_result, :ok),
           result:
             {:ok,
              %SearchSummary{
                projection: "postgres_metadata_v1",
                document_count: 2,
                result_sha256: search_hash
              }}
         }},
      audit: {AuditPersistence, %{owner: self(), result: :ok}}
    }

    rewrapped = %{
      cut: %{
        logical_version: 3,
        manifest_id: @manifest,
        vault_id: @owner,
        object_inventory: original
      },
      manifest: %{manifest_id: @manifest},
      object_inventory: original,
      integrity_principal_id: @principal,
      integrity_capability: %Capability{lease: lease, token: make_ref()}
    }

    %{
      context: context,
      rewrapped: rewrapped,
      storage: storage,
      projected: projected,
      inventory_hash: inventory_hash,
      # Task9E fixture summary
      plaintext_summary: plaintext,
      plaintext_inventory_hash: plaintext_inventory_hash,
      search_hash: search_hash,
      lease: lease
    }
  end

  defp change_ciphertext(summary, mutation) do
    [first, second] = summary.ciphertext_hashes

    case mutation do
      :owner ->
        %{summary | vault_id: id(99)}

      :count ->
        %{summary | object_count: 1}

      :digest ->
        %{summary | inventory_sha256: <<99::256>>}

      :order ->
        %{summary | ciphertext_hashes: [second, first]}

      :hash ->
        %{summary | ciphertext_hashes: [%{first | sha256: <<98::256>>}, second]}

      :missing ->
        %{summary | ciphertext_hashes: [first]}

      :extra ->
        %{summary | ciphertext_hashes: [first, second, %{first | asset_object_id: id(99)}]}
    end
  end

  defp change_plaintext(summary, mutation) do
    [first, second] = summary.plaintext_hashes

    case mutation do
      :owner -> %{summary | vault_id: id(99)}
      :count -> %{summary | object_count: 1}
      :digest -> %{summary | inventory_sha256: <<99::256>>}
      :order -> %{summary | plaintext_hashes: [second, first]}
      :hash_shape -> %{summary | plaintext_hashes: [%{first | sha256: <<98>>}, second]}
      :missing -> %{summary | plaintext_hashes: [first]}
      :duplicate -> %{summary | plaintext_hashes: [first, first]}
      :extra -> %{summary | plaintext_hashes: [first, second, %{first | asset_object_id: id(99)}]}
    end
  end

  defp assert_next_event(expected) do
    assert_receive event
    assert event === expected
  end

  defp id(n), do: "75000000-0000-4000-8000-" <> String.pad_leading(Integer.to_string(n), 12, "0")
end
