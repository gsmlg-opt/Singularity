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
