defmodule Singularity.Storage.IntegrityAuditTest do
  use ExUnit.Case, async: false

  import Singularity.Storage.AuditAssertions, only: [assert_persisted_audit!: 4]

  alias Ecto.Adapters.SQL
  alias Singularity.Core.Error
  alias Singularity.Core.ObjectRef
  alias Singularity.Storage.Backup.IntegrityAudit
  alias Singularity.Storage.Backup.IntegrityAudit.CiphertextSummary
  alias Singularity.Storage.Fixtures
  alias Singularity.Storage.Local.PathGuard
  alias Singularity.Storage.LocalFilesystemAdapter
  alias Singularity.Storage.MigrationRepo
  alias Singularity.Storage.NoteFixtures

  @moduletag :tmp_dir

  @vault_id "70000000-0000-0000-0000-000000000001"
  @domain_id "70000000-0000-0000-0000-000000000002"

  defmodule MalformedStorage do
    def stat(_context, _object_ref), do: {:ok, %{byte_size: 1}}
  end

  test "verifies every immutable ciphertext size and digest and returns only safe evidence", %{
    tmp_dir: tmp_dir
  } do
    first = publish!(tmp_dir, 0, "first authenticated ciphertext")
    second = publish!(tmp_dir, 1, "second authenticated ciphertext")
    inventory = [first.entry, second.entry]

    assert {:ok,
            %CiphertextSummary{
              vault_id: @vault_id,
              object_count: 2,
              inventory_sha256: <<_::binary-size(32)>> = inventory_sha256,
              ciphertext_hashes: ciphertext_hashes
            } = summary} =
             IntegrityAudit.verify_ciphertext(
               {LocalFilesystemAdapter, %{root: tmp_dir}},
               @vault_id,
               inventory
             )

    assert ciphertext_hashes == [
             %{asset_object_id: first.entry.asset_object_id, sha256: first.entry.ciphertext_hash},
             %{
               asset_object_id: second.entry.asset_object_id,
               sha256: second.entry.ciphertext_hash
             }
           ]

    assert {:ok, ^inventory_sha256} = IntegrityAudit.inventory_sha256(@vault_id, inventory)
    refute inspect(summary) =~ "first authenticated ciphertext"
    refute inspect(summary) =~ tmp_dir
  end

  test "fails closed when a finalized ciphertext is corrupted", %{tmp_dir: tmp_dir} do
    object = publish!(tmp_dir, 0, "ciphertext whose digest must remain exact")
    corrupt_byte!(object.path, 3)

    assert {:error, %Error{code: :integrity_failure, retryable?: false}} =
             IntegrityAudit.verify_ciphertext(
               {LocalFilesystemAdapter, %{root: tmp_dir}},
               @vault_id,
               [object.entry]
             )
  end

  test "treats a missing expected object as an integrity failure", %{tmp_dir: tmp_dir} do
    object = publish!(tmp_dir, 0, "ciphertext that must not disappear")
    File.rm!(object.path)

    assert {:error, %Error{code: :integrity_failure}} =
             IntegrityAudit.verify_ciphertext(
               {LocalFilesystemAdapter, %{root: tmp_dir}},
               @vault_id,
               [object.entry]
             )
  end

  test "rejects reordered, cross-vault, duplicate, and malformed inventory before storage access",
       %{
         tmp_dir: tmp_dir
       } do
    first = publish!(tmp_dir, 0, "first")
    second = publish!(tmp_dir, 1, "second")

    invalid_inventories = [
      [second.entry, first.entry],
      [first.entry, %{second.entry | vault_id: Ecto.UUID.generate()}],
      [first.entry, %{second.entry | asset_object_id: first.entry.asset_object_id}],
      [%{first.entry | ciphertext_hash: <<0>>}],
      [Map.put(first.entry, :unexpected, true)]
    ]

    for inventory <- invalid_inventories do
      assert {:error, %Error{code: :backup_invalid}} =
               IntegrityAudit.verify_ciphertext(
                 {MalformedStorage, %{}},
                 @vault_id,
                 inventory
               )
    end
  end

  test "requires a concrete stat adapter instead of accepting a no-op", %{tmp_dir: tmp_dir} do
    object = publish!(tmp_dir, 0, "real bytes")

    assert {:error, %Error{code: :invalid}} =
             IntegrityAudit.verify_ciphertext(
               {:not_loaded, %{}},
               @vault_id,
               [object.entry]
             )
  end

  @tag :integration
  test "loads wrapper material when object and domain keys have independent generations" do
    fixture = material_fixture!()

    assert {:ok, material} =
             Fixtures.with_owner(fn ->
               IntegrityAudit.load_plaintext_material(
                 MigrationRepo,
                 fixture.binding,
                 fixture.entry
               )
             end)

    assert material.object_generation == 3
    assert material.domain_key_generation == 5
  end

  @tag :integration
  test "rebuilds exact live note projections, removes tombstones, and returns stable typed evidence" do
    raw_fixture = Fixtures.two_vaults!().one
    live = NoteFixtures.note_with_conflict_in_context!(raw_fixture)
    tombstoned = NoteFixtures.note_with_conflict_in_context!(raw_fixture)

    Fixtures.with_owner(fn ->
      query!(
        "UPDATE content.note_search_documents SET title = 'stale', markdown = 'stale' WHERE resource_id = $1",
        [uuid(live.resource_id)]
      )

      query!(
        "UPDATE content.resources SET deleted_at = CURRENT_TIMESTAMP WHERE id = $1",
        [uuid(tombstoned.resource_id)]
      )
    end)

    binding = %{manifest_id: Ecto.UUID.generate(), vault_id: live.vault_id}

    assert {:ok, first} =
             Fixtures.with_owner(fn -> IntegrityAudit.rebuild(MigrationRepo, binding) end)

    assert first.projection == "postgres_metadata_v1"
    assert first.document_count == 1
    assert <<_::binary-size(32)>> = first.result_sha256

    Fixtures.with_owner(fn ->
      assert %{rows: [[resource_id, head_id, title, markdown]]} =
               query!(
                 """
                 SELECT
                   document.resource_id,
                   document.resource_version_id,
                   document.title,
                   document.markdown
                 FROM content.note_search_documents AS document
                 WHERE document.vault_id = $1
                 ORDER BY document.resource_id
                 """,
                 [uuid(live.vault_id)]
               )

      assert Ecto.UUID.load!(resource_id) == live.resource_id
      assert Ecto.UUID.load!(head_id) == live.canonical_version_id
      assert title == "Accepted fixture note"
      assert markdown == "# Accepted fixture note"
    end)

    assert {:ok, second} =
             Fixtures.with_owner(fn -> IntegrityAudit.rebuild(MigrationRepo, binding) end)

    assert second == first
  end

  @tag :integration
  test "an identical completion retry persists the exact integrity evidence once" do
    fixture = Fixtures.two_vaults!().one
    command = completion_command(fixture)
    expected_event_id = completion_identity(command, "integrity.audit_completed:event")
    expected_metadata = completion_metadata(command)

    assert :ok =
             Fixtures.with_owner(fn ->
               assert :ok = IntegrityAudit.complete(MigrationRepo, command)
               assert :ok = IntegrityAudit.complete(MigrationRepo, command)

               assert_persisted_audit!(
                 MigrationRepo,
                 "integrity.audit_completed",
                 [correlation_id: command.correlation_id],
                 actor_kind: "system",
                 system_principal_name: "integrity_audit",
                 result: "completed",
                 target_type: "backup_manifest",
                 target_id: command.manifest_id
               )

               assert %{rows: [row]} = completion_rows(command)

               assert [
                        event_id,
                        vault_id,
                        "system",
                        "integrity_audit",
                        "integrity.audit_completed",
                        "completed",
                        "restricted",
                        correlation_id,
                        "backup_manifest",
                        manifest_id,
                        ^expected_metadata
                      ] = row

               assert Ecto.UUID.load!(event_id) == expected_event_id
               assert Ecto.UUID.load!(vault_id) == command.vault_id
               assert Ecto.UUID.load!(correlation_id) == command.correlation_id
               assert Ecto.UUID.load!(manifest_id) == command.manifest_id
               :ok
             end)
  end

  @tag :integration
  test "a completion retry with conflicting evidence fails closed without a second event" do
    fixture = Fixtures.two_vaults!().one
    command = completion_command(fixture)

    conflicting = %{
      command
      | search_rebuild_sha256: :crypto.hash(:sha256, "conflicting-search-evidence")
    }

    assert :ok =
             Fixtures.with_owner(fn ->
               assert :ok = IntegrityAudit.complete(MigrationRepo, command)

               assert {:error, %Error{code: :conflict, retryable?: false}} =
                        IntegrityAudit.complete(MigrationRepo, conflicting)

               assert %{
                        rows: [
                          [
                            _event_id,
                            _vault_id,
                            _actor_kind,
                            _system_principal_name,
                            _operation,
                            _result,
                            _classification,
                            _correlation_id,
                            _target_type,
                            _manifest_id,
                            metadata
                          ]
                        ]
                      } = completion_rows(command)

               assert metadata == completion_metadata(command)
               :ok
             end)
  end

  defp publish!(root, position, payload) do
    object_id = Ecto.UUID.generate()
    lookup_digest = :crypto.hash(:sha256, "lookup:#{position}")

    context = %{
      root: root,
      vault_namespace: @vault_id,
      domain_namespace: @domain_id,
      lookup_digest: Base.encode16(lookup_digest, case: :lower)
    }

    object_ref = %ObjectRef{object_id: object_id}
    {:ok, stage_ref} = LocalFilesystemAdapter.stage(context, %{})
    :ok = LocalFilesystemAdapter.append_encrypted_chunk(context, stage_ref, payload)
    {:ok, %{sealed?: true}} = LocalFilesystemAdapter.seal_stage(context, stage_ref, %{})
    {:ok, ^object_ref} = LocalFilesystemAdapter.finalize(context, stage_ref, object_ref)

    {:ok, path} =
      PathGuard.object_path(
        root,
        @vault_id,
        @domain_id,
        Base.encode16(lookup_digest, case: :lower)
      )

    %{
      path: path,
      entry: %{
        asset_object_id: object_id,
        ciphertext_byte_size: byte_size(payload),
        ciphertext_hash: :crypto.hash(:sha256, payload),
        classification: :private,
        inventory_position: position,
        key_domain_id: @domain_id,
        lookup_digest: lookup_digest,
        storage_ref: object_id,
        vault_id: @vault_id
      }
    }
  end

  defp corrupt_byte!(path, offset) do
    File.chmod!(path, 0o600)
    {:ok, io} = :file.open(path, [:read, :write, :binary])

    try do
      {:ok, <<byte>>} = :file.pread(io, offset, 1)
      :ok = :file.pwrite(io, offset, <<Bitwise.bxor(byte, 1)>>)
      :ok = :file.sync(io)
    after
      :ok = :file.close(io)
    end
  end

  defp material_fixture! do
    vault = Fixtures.two_vaults!().one
    vault_id = Ecto.UUID.load!(vault.vault_id)
    vault_key_version_id = Ecto.UUID.generate()
    domain_id = Ecto.UUID.generate()
    domain_key_version_id = Ecto.UUID.generate()
    object_id = Ecto.UUID.generate()
    lookup_digest = :crypto.hash(:sha256, "integrity-lookup:" <> object_id)
    ciphertext_hash = :crypto.hash(:sha256, "integrity-ciphertext:" <> object_id)

    Fixtures.with_owner(fn ->
      query!(
        """
        INSERT INTO core.vault_key_versions (
          id, vault_id, generation, state, algorithm, activated_at
        ) VALUES ($1, $2, 2, 'active', 'aes_256_gcm', CURRENT_TIMESTAMP)
        """,
        [uuid(vault_key_version_id), vault.vault_id]
      )

      query!(
        """
        INSERT INTO core.key_domains (
          id, vault_id, classification, kind, state
        ) VALUES ($1, $2, 'private', 'content', 'active')
        """,
        [uuid(domain_id), vault.vault_id]
      )

      query!(
        """
        INSERT INTO core.domain_key_versions (
          id, vault_id, key_domain_id, vault_key_version_id, generation,
          state, algorithm, wrapped_key
        ) VALUES ($1, $2, $3, $4, 5, 'active', 'aes_256_gcm', $5)
        """,
        [
          uuid(domain_key_version_id),
          vault.vault_id,
          uuid(domain_id),
          uuid(vault_key_version_id),
          :crypto.strong_rand_bytes(60)
        ]
      )

      query!(
        """
        INSERT INTO content.asset_objects (
          id, vault_id, key_domain_id, classification, lookup_digest,
          ciphertext_hash, plaintext_byte_size, ciphertext_byte_size,
          storage_ref, format_version, lifecycle
        ) VALUES ($1, $2, $3, 'private', $4, $5, 31, 189, $6, 1, 'available')
        """,
        [
          uuid(object_id),
          vault.vault_id,
          uuid(domain_id),
          lookup_digest,
          ciphertext_hash,
          object_id
        ]
      )

      query!(
        """
        INSERT INTO content.asset_key_envelopes (
          id, vault_id, asset_object_id, domain_key_version_id, key_domain_id,
          classification, algorithm, key_generation, wrapped_dek
        ) VALUES ($1, $2, $3, $4, $5, 'private', 'aes_256_gcm', 3, $6)
        """,
        [
          uuid(Ecto.UUID.generate()),
          vault.vault_id,
          uuid(object_id),
          uuid(domain_key_version_id),
          uuid(domain_id),
          :crypto.strong_rand_bytes(60)
        ]
      )

      %{
        binding: %{
          manifest_id: Ecto.UUID.generate(),
          vault_id: vault_id,
          vault_key_generation: 2,
          vault_key_version_id: vault_key_version_id
        },
        entry: %{
          asset_object_id: object_id,
          ciphertext_byte_size: 189,
          ciphertext_hash: ciphertext_hash,
          classification: :private,
          inventory_position: 0,
          key_domain_id: domain_id,
          lookup_digest: lookup_digest,
          storage_ref: object_id,
          vault_id: vault_id
        }
      }
    end)
  end

  defp completion_command(fixture) do
    target = %{
      manifest_id: Ecto.UUID.generate(),
      vault_id: Ecto.UUID.load!(fixture.vault_id)
    }

    %{
      ciphertext_inventory_sha256: :crypto.hash(:sha256, "ciphertext-inventory"),
      correlation_id: completion_identity(target, "integrity.audit_completed:correlation"),
      integrity_principal_id: Ecto.UUID.load!(fixture.principal_id),
      manifest_id: target.manifest_id,
      object_count: 3,
      operation: "integrity.audit_completed",
      plaintext_inventory_sha256: :crypto.hash(:sha256, "plaintext-inventory"),
      search_rebuild_sha256: :crypto.hash(:sha256, "postgres-search-evidence"),
      vault_id: target.vault_id
    }
  end

  defp completion_identity(target, label) do
    digest =
      :crypto.hash(:sha256, [
        "singularity:restore:audit:v1\0",
        label,
        0,
        uuid(target.manifest_id),
        uuid(target.vault_id)
      ])

    <<prefix::binary-size(6), version_byte, middle_byte, variant_byte, suffix::binary-size(7),
      _rest::binary>> = digest

    version_byte = Bitwise.bor(Bitwise.band(version_byte, 0x0F), 0x50)
    variant_byte = Bitwise.bor(Bitwise.band(variant_byte, 0x3F), 0x80)

    Ecto.UUID.load!(<<prefix::binary, version_byte, middle_byte, variant_byte, suffix::binary>>)
  end

  defp completion_metadata(command) do
    %{
      "ciphertext_inventory_sha256" => hex(command.ciphertext_inventory_sha256),
      "object_count" => command.object_count,
      "plaintext_inventory_sha256" => hex(command.plaintext_inventory_sha256),
      "search_rebuild_sha256" => hex(command.search_rebuild_sha256)
    }
  end

  defp completion_rows(command) do
    query!(
      """
      SELECT
        id, vault_id, actor_kind, system_principal_name, operation, result, classification,
        correlation_id, target_type, target_id, metadata
      FROM audit.events
      WHERE operation = 'integrity.audit_completed'
        AND vault_id = $1
        AND target_id = $2
      ORDER BY id
      """,
      [uuid(command.vault_id), uuid(command.manifest_id)]
    )
  end

  defp query!(statement, parameters),
    do: SQL.query!(MigrationRepo, statement, parameters, log: false)

  defp uuid(value), do: Ecto.UUID.dump!(value)
  defp hex(value), do: Base.encode16(value, case: :lower)
end
