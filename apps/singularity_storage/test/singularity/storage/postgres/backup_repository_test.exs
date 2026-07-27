defmodule Singularity.Storage.Postgres.BackupRepositoryTest do
  use Singularity.Storage.DataCase, async: false

  @moduletag :integration

  alias Singularity.Core.Error
  alias Singularity.Storage.Fixtures
  alias Singularity.Storage.Postgres.BackupRepository
  alias Singularity.Storage.ScopedRepo

  @kdf_domain "singularity.backup.bundle.v1"
  @salt :binary.copy(<<0xB1>>, 16)
  @wrapper :binary.copy(<<0xB2>>, 48)

  setup do
    %{one: one, two: two} = Fixtures.two_vaults!()
    set_authorization_epochs!(one, 7, 23)
    set_authorization_epochs!(two, 7, 23)

    {:ok,
     one: load_ids(one),
     two: load_ids(two),
     one_object: create_object!(one, 0x31),
     second_one_object: create_object!(one, 0x32)}
  end

  test "request atomically persists strict public metadata, audit, and a minimal outbox payload",
       %{one: fixture} do
    command = request_command(fixture)

    assert {:ok, manifest} =
             scoped(fixture, &BackupRepository.insert_pending_and_enqueue(&1, command))

    assert manifest == %{
             backup_key_lease_id: command.custody_ref,
             classification: :private,
             destination_ref: command.destination_ref,
             id: command.manifest_id,
             kdf: public_metadata(command)["kdf"],
             outbox_high_water_mark: nil,
             recovery: public_metadata(command)["recovery"],
             sealed_at: nil,
             snapshot_id: nil,
             status: :waiting_for_backup_key,
             vault_id: fixture.vault_id
           }

    scoped(fixture, fn repo ->
      assert %{rows: [[4]]} =
               query!(
                 repo,
                 "SELECT kdf_version FROM audit.backup_manifests WHERE id = $1",
                 [dump!(command.manifest_id)]
               )

      assert %{rows: [["backup.requested", payload, classification, principal_id]]} =
               query!(
                 repo,
                 """
                 SELECT event_type, payload, classification, principal_id
                 FROM core.outbox_events
                 WHERE id = $1
                 """,
                 [dump!(command.outbox_event_id)]
               )

      assert payload == %{"pending_manifest_id" => command.manifest_id}
      assert classification == "private"
      assert load!(principal_id) == fixture.principal_id

      assert %{rows: [["backup.requested", "completed", metadata, target_id]]} =
               query!(
                 repo,
                 """
                 SELECT operation, result, metadata, target_id
                 FROM audit.events
                 WHERE id = $1
                 """,
                 [dump!(command.audit_event_id)]
               )

      assert metadata == %{}
      assert load!(target_id) == command.manifest_id
      :ok
    end)

    refute contains_any?(payload_and_rows(fixture, command.manifest_id), [
             "passphrase",
             "backup_key",
             @wrapper,
             @salt,
             command.custody_ref,
             command.destination_ref
           ])
  end

  test "an audit conflict rolls back the manifest and outbox with typed errors", %{one: fixture} do
    first = request_command(fixture)

    assert {:ok, _manifest} =
             scoped(fixture, &BackupRepository.insert_pending_and_enqueue(&1, first))

    second =
      request_command(fixture)
      |> Map.put(:audit_event_id, first.audit_event_id)

    assert {:error, %Error{code: :conflict}} =
             scoped(fixture, &BackupRepository.insert_pending_and_enqueue(&1, second))

    scoped(fixture, fn repo ->
      assert %{rows: [[0, 0]]} =
               query!(
                 repo,
                 """
                 SELECT
                   (SELECT count(*) FROM audit.backup_manifests WHERE id = $1),
                   (SELECT count(*) FROM core.outbox_events WHERE id = $2)
                 """,
                 [dump!(second.manifest_id), dump!(second.outbox_event_id)]
               )

      :ok
    end)
  end

  test "waiting loads and every mutation stay bound to the scoped vault", %{one: one, two: two} do
    command = request_command(one)

    assert {:ok, _manifest} =
             scoped(one, &BackupRepository.insert_pending_and_enqueue(&1, command))

    assert {:ok, %{id: manifest_id, status: :waiting_for_backup_key}} =
             scoped(
               one,
               &BackupRepository.load_waiting(&1, %{
                 manifest_id: command.manifest_id,
                 vault_id: one.vault_id
               })
             )

    assert manifest_id == command.manifest_id

    assert {:error, %Error{code: :not_found}} =
             scoped(
               two,
               &BackupRepository.load_waiting(&1, %{
                 manifest_id: command.manifest_id,
                 vault_id: two.vault_id
               })
             )

    assert {:error, %Error{code: :not_found}} =
             scoped(
               two,
               &BackupRepository.mark_pending(&1, %{
                 manifest_id: command.manifest_id,
                 vault_id: two.vault_id,
                 custody_ref: command.custody_ref
               })
             )
  end

  test "request authority must exactly match the scoped principal and vault", %{one: fixture} do
    command = request_command(fixture) |> Map.put(:principal_id, Ecto.UUID.generate())

    assert {:error, %Error{code: :forbidden}} =
             scoped(fixture, &BackupRepository.insert_pending_and_enqueue(&1, command))

    scoped(fixture, fn repo ->
      assert %{rows: [[0]]} =
               query!(repo, "SELECT count(*) FROM audit.backup_manifests WHERE id = $1", [
                 dump!(command.manifest_id)
               ])

      :ok
    end)
  end

  test "request binds live epochs, causation, and distinct persistent identifiers", %{
    one: fixture
  } do
    invalid_commands = [
      request_command(fixture) |> Map.put(:causation_id, Ecto.UUID.generate()),
      request_command(fixture) |> then(&Map.put(&1, :audit_event_id, &1.manifest_id)),
      request_command(fixture) |> then(&Map.put(&1, :outbox_event_id, &1.correlation_id))
    ]

    for command <- invalid_commands do
      assert {:error, %Error{code: :invalid}} =
               scoped(fixture, &BackupRepository.insert_pending_and_enqueue(&1, command))
    end

    for epoch <- [:principal_authorization_epoch, :vault_authorization_epoch] do
      command = request_command(fixture) |> Map.update!(epoch, &(&1 + 1))

      assert {:error, %Error{code: :forbidden}} =
               scoped(fixture, &BackupRepository.insert_pending_and_enqueue(&1, command))
    end
  end

  test "web cannot bypass request creation with a direct arbitrary-status manifest insert", %{
    one: fixture
  } do
    command = request_command(fixture)

    assert_raise Postgrex.Error, ~r/permission denied/i, fn ->
      scoped(fixture, fn repo ->
        query!(
          repo,
          """
          INSERT INTO audit.backup_manifests (
            id, vault_id, classification, status, destination_ref,
            kdf_version, kdf_salt, kdf_parameters, recovery_wrapper, custody_ref
          ) VALUES (
            $1, $2, 'private', 'sealed', $3,
            1, decode('00112233445566778899aabbccddeeff', 'hex'),
            '{"version":1}'::jsonb, decode('aabbccdd', 'hex'), $4
          )
          """,
          [
            dump!(command.manifest_id),
            dump!(fixture.vault_id),
            command.destination_ref,
            command.custody_ref
          ]
        )
      end)
    end
  end

  test "re-entry and activation are exact status plus custody-reference CAS operations", %{
    one: fixture
  } do
    command = request_command(fixture)

    assert {:ok, waiting} =
             scoped(fixture, &BackupRepository.insert_pending_and_enqueue(&1, command))

    replacement_ref = Ecto.UUID.generate()
    replacement = reentry_command(fixture, waiting, replacement_ref)

    assert {:ok, %{status: :waiting_for_backup_key, backup_key_lease_id: ^replacement_ref}} =
             scoped(fixture, &BackupRepository.replace_key_and_audit(&1, replacement))

    assert {:error, %Error{code: :conflict}} =
             scoped(fixture, &BackupRepository.replace_key_and_audit(&1, replacement))

    assert {:error, %Error{code: :conflict}} =
             scoped(
               fixture,
               &BackupRepository.mark_pending(&1, %{
                 manifest_id: waiting.id,
                 vault_id: fixture.vault_id,
                 custody_ref: command.custody_ref
               })
             )

    activate = %{
      manifest_id: waiting.id,
      vault_id: fixture.vault_id,
      custody_ref: replacement_ref
    }

    assert {:ok, %{status: :pending}} =
             scoped(fixture, &BackupRepository.mark_pending(&1, activate))

    assert {:error, %Error{code: :conflict}} =
             scoped(
               fixture,
               &BackupRepository.load_waiting(&1, %{
                 manifest_id: waiting.id,
                 vault_id: fixture.vault_id
               })
             )

    assert {:ok, %{status: :pending}} =
             scoped(fixture, &BackupRepository.mark_pending(&1, activate))

    assert {:error, %Error{code: :conflict}} =
             scoped(
               fixture,
               &BackupRepository.mark_waiting_for_backup_key(&1, %{
                 manifest_id: waiting.id,
                 vault_id: fixture.vault_id,
                 custody_ref: command.custody_ref
               })
             )
  end

  test "re-entry audit preserves the manifest classification", %{one: fixture} do
    command = request_command(fixture) |> Map.put(:classification, :restricted)

    assert {:ok, waiting} =
             scoped(fixture, &BackupRepository.insert_pending_and_enqueue(&1, command))

    replacement = reentry_command(fixture, waiting, Ecto.UUID.generate())

    assert {:ok, %{classification: :restricted}} =
             scoped(fixture, &BackupRepository.replace_key_and_audit(&1, replacement))

    scoped(fixture, fn repo ->
      assert %{rows: [["restricted"]]} =
               query!(repo, "SELECT classification FROM audit.events WHERE id = $1", [
                 dump!(replacement.audit_event_id)
               ])

      :ok
    end)
  end

  test "web cannot bypass re-entry audit with a manifest-only custody replacement", %{
    one: fixture
  } do
    command = request_command(fixture)

    assert {:ok, waiting} =
             scoped(fixture, &BackupRepository.insert_pending_and_enqueue(&1, command))

    replacement_ref = Ecto.UUID.generate()

    assert_raise Postgrex.Error, ~r/replace_backup_custody.*does not exist/i, fn ->
      scoped(fixture, fn repo ->
        query!(
          repo,
          "SELECT audit.replace_backup_custody($1, $2, $3, $4)",
          [
            dump!(waiting.id),
            dump!(fixture.vault_id),
            waiting.backup_key_lease_id,
            replacement_ref
          ]
        )
      end)
    end

    assert {:ok, %{backup_key_lease_id: original_ref}} =
             scoped(
               fixture,
               &BackupRepository.load_waiting(&1, %{
                 manifest_id: waiting.id,
                 vault_id: fixture.vault_id
               })
             )

    assert original_ref == waiting.backup_key_lease_id
  end

  test "re-entry audit conflict rolls back the exact custody replacement", %{one: fixture} do
    command = request_command(fixture)

    assert {:ok, waiting} =
             scoped(fixture, &BackupRepository.insert_pending_and_enqueue(&1, command))

    replacement =
      fixture
      |> reentry_command(waiting, Ecto.UUID.generate())
      |> Map.put(:audit_event_id, command.audit_event_id)

    assert {:error, %Error{code: :conflict}} =
             scoped(fixture, &BackupRepository.replace_key_and_audit(&1, replacement))

    assert {:ok, %{backup_key_lease_id: original_ref}} =
             scoped(
               fixture,
               &BackupRepository.load_waiting(&1, %{
                 manifest_id: waiting.id,
                 vault_id: fixture.vault_id
               })
             )

    assert original_ref == waiting.backup_key_lease_id
  end

  test "worker claim distinguishes waiting, pending, copying recovery, and sealed terminal states",
       %{one: fixture, one_object: object} do
    command = request_command(fixture)

    assert {:ok, _waiting} =
             scoped(fixture, &BackupRepository.insert_pending_and_enqueue(&1, command))

    claim = %{manifest_id: command.manifest_id, vault_id: fixture.vault_id}

    assert {:ok, %{status: :waiting_for_backup_key}} =
             scoped_worker(fixture, &BackupRepository.load_pending(&1, claim))

    assert {:ok, %{status: :pending}} =
             scoped(
               fixture,
               &BackupRepository.mark_pending(
                 &1,
                 Map.put(claim, :custody_ref, command.custody_ref)
               )
             )

    assert {:ok, %{status: :copying}} =
             scoped_worker(fixture, &BackupRepository.load_pending(&1, claim))

    assert {:ok, %{status: :waiting_for_backup_key}} =
             scoped_worker(fixture, &BackupRepository.load_pending(&1, claim))

    assert {:ok, %{status: :pending}} =
             scoped(
               fixture,
               &BackupRepository.mark_pending(
                 &1,
                 Map.put(claim, :custody_ref, command.custody_ref)
               )
             )

    assert {:ok, copying} = scoped_worker(fixture, &BackupRepository.load_pending(&1, claim))

    assert {:ok, sealed} =
             scoped_worker(
               fixture,
               &BackupRepository.acknowledge_sealed(&1, seal_command(copying, fixture, [object]))
             )

    assert sealed.status == :sealed

    assert {:ok, ^sealed} = scoped_worker(fixture, &BackupRepository.load_pending(&1, claim))
  end

  test "definer transitions reject null custody and seal evidence", %{one: fixture} do
    command = request_command(fixture)

    assert {:ok, waiting} =
             scoped(fixture, &BackupRepository.insert_pending_and_enqueue(&1, command))

    assert_raise Postgrex.Error, ~r/backup activation custody invalid/i, fn ->
      scoped(fixture, fn repo ->
        query!(repo, "SELECT audit.activate_backup_manifest($1, $2, NULL)", [
          dump!(waiting.id),
          dump!(fixture.vault_id)
        ])
      end)
    end

    assert {:ok, %{status: :waiting_for_backup_key}} =
             scoped(
               fixture,
               &BackupRepository.load_waiting(&1, %{
                 manifest_id: waiting.id,
                 vault_id: fixture.vault_id
               })
             )

    assert {:ok, %{status: :pending}} =
             scoped(
               fixture,
               &BackupRepository.mark_pending(&1, %{
                 custody_ref: waiting.backup_key_lease_id,
                 manifest_id: waiting.id,
                 vault_id: fixture.vault_id
               })
             )

    assert_raise Postgrex.Error, ~r/backup wait custody invalid/i, fn ->
      scoped(fixture, fn repo ->
        query!(repo, "SELECT audit.mark_backup_waiting($1, $2, NULL)", [
          dump!(waiting.id),
          dump!(fixture.vault_id)
        ])
      end)
    end

    assert {:ok, %{status: :copying}} =
             scoped_worker(
               fixture,
               &BackupRepository.load_pending(&1, %{
                 manifest_id: waiting.id,
                 vault_id: fixture.vault_id
               })
             )

    assert_raise Postgrex.Error, ~r/backup seal evidence invalid/i, fn ->
      scoped_worker(fixture, fn repo ->
        query!(
          repo,
          """
          SELECT audit.seal_backup_manifest(
            $1, $2, NULL, NULL, NULL, NULL, NULL, '[]'::jsonb
          )
          """,
          [dump!(waiting.id), dump!(fixture.vault_id)]
        )
      end)
    end

    scoped_worker(fixture, fn repo ->
      assert %{rows: [["copying", nil, nil, nil, nil, 0]]} =
               query!(
                 repo,
                 """
                 SELECT
                   status,
                   snapshot_id,
                   outbox_high_water,
                   manifest_hash,
                   manifest_tag,
                   (
                     SELECT count(*)
                     FROM audit.backup_manifest_objects
                     WHERE manifest_id = $1
                   )
                 FROM audit.backup_manifests
                 WHERE id = $1 AND vault_id = $2
                 """,
                 [dump!(waiting.id), dump!(fixture.vault_id)]
               )

      :ok
    end)
  end

  test "seal persists the authoritative cut inventory atomically and is evidence-idempotent", %{
    one: fixture,
    one_object: object,
    second_one_object: second_object
  } do
    copying = create_copying!(fixture)
    command = seal_command(copying, fixture, [object, second_object])

    assert {:ok, sealed} =
             scoped_worker(fixture, &BackupRepository.acknowledge_sealed(&1, command))

    assert sealed.status == :sealed
    assert sealed.snapshot_id == command.cut.snapshot_id
    assert sealed.outbox_high_water_mark == command.cut.outbox_high_water_mark
    assert sealed.sealed_at != nil

    assert {:ok, replayed} =
             scoped_worker(fixture, &BackupRepository.acknowledge_sealed(&1, command))

    assert replayed == sealed

    stale_replay = Map.put(command, :expected_custody_ref, "stale-custody-ref")

    assert {:error, %Error{code: :conflict}} =
             scoped_worker(fixture, &BackupRepository.acknowledge_sealed(&1, stale_replay))

    assert {:ok, ^sealed} =
             scoped_worker(fixture, &BackupRepository.acknowledge_sealed(&1, command))

    scoped_worker(fixture, fn repo ->
      assert %{rows: rows} =
               query!(
                 repo,
                 """
                 SELECT asset_object_id, inventory_position, storage_ref, ciphertext_hash
                 FROM audit.backup_manifest_objects
                 WHERE manifest_id = $1
                 ORDER BY inventory_position
                 """,
                 [dump!(copying.id)]
               )

      assert Enum.map(rows, fn [id, position, storage_ref, hash] ->
               {load!(id), position, storage_ref, hash}
             end) == [
               {object.asset_object_id, 0, object.storage_ref, object.ciphertext_hash},
               {second_object.asset_object_id, 1, second_object.storage_ref,
                second_object.ciphertext_hash}
             ]

      :ok
    end)
  end

  test "duplicate positions or objects reject the entire seal and preserve copying state", %{
    one: fixture,
    one_object: object,
    second_one_object: second_object
  } do
    for kind <- [:position, :object] do
      copying = create_copying!(fixture)
      command = seal_command(copying, fixture, [object, second_object])

      command =
        case kind do
          :position ->
            put_in(command, [:cut, :object_inventory, Access.at(1), :inventory_position], 0)

          :object ->
            put_in(
              command,
              [:cut, :object_inventory, Access.at(1), :asset_object_id],
              object.asset_object_id
            )
        end

      assert {:error, %Error{code: :backup_invalid}} =
               scoped_worker(
                 fixture,
                 &BackupRepository.acknowledge_sealed(&1, command)
               )

      scoped_worker(fixture, fn repo ->
        assert %{rows: [["copying", 0]]} =
                 query!(
                   repo,
                   """
                   SELECT manifest.status, count(inventory.id)
                   FROM audit.backup_manifests AS manifest
                   LEFT JOIN audit.backup_manifest_objects AS inventory
                     ON inventory.manifest_id = manifest.id
                   WHERE manifest.id = $1
                   GROUP BY manifest.status
                   """,
                   [dump!(copying.id)]
                 )

        :ok
      end)
    end
  end

  test "seal binds the writer's opaque destination reference, not its absolute IO path", %{
    one: fixture,
    one_object: object
  } do
    copying = create_copying!(fixture)
    command = seal_command(copying, fixture, [object])

    assert command.sealed.path != copying.destination_ref

    assert {:ok, %{status: :sealed}} =
             scoped_worker(fixture, &BackupRepository.acknowledge_sealed(&1, command))
  end

  test "seal rejects a writer destination reference that is not the persisted destination", %{
    one: fixture,
    one_object: object
  } do
    copying = create_copying!(fixture)

    command =
      seal_command(copying, fixture, [object])
      |> put_in([:sealed, :destination_ref], "backup/different.sgkc")

    assert {:error, %Error{code: :backup_invalid}} =
             scoped_worker(fixture, &BackupRepository.acknowledge_sealed(&1, command))

    scoped_worker(fixture, fn repo ->
      assert %{rows: [["copying", 0]]} =
               query!(
                 repo,
                 """
                 SELECT manifest.status, count(inventory.id)
                 FROM audit.backup_manifests AS manifest
                 LEFT JOIN audit.backup_manifest_objects AS inventory
                   ON inventory.manifest_id = manifest.id
                 WHERE manifest.id = $1
                 GROUP BY manifest.status
                 """,
                 [dump!(copying.id)]
               )

      :ok
    end)
  end

  test "mark waiting is ref-safe, idempotent only for the same ref, and never demotes sealed", %{
    one: fixture,
    one_object: object
  } do
    copying = create_copying!(fixture)

    command = %{
      manifest_id: copying.id,
      vault_id: fixture.vault_id,
      custody_ref: copying.backup_key_lease_id
    }

    assert {:ok, %{status: :waiting_for_backup_key}} =
             scoped_worker(fixture, &BackupRepository.mark_waiting_for_backup_key(&1, command))

    assert {:ok, %{status: :waiting_for_backup_key}} =
             scoped_worker(fixture, &BackupRepository.mark_waiting_for_backup_key(&1, command))

    assert {:ok, %{status: :pending}} =
             scoped(fixture, &BackupRepository.mark_pending(&1, command))

    assert {:ok, copying} =
             scoped_worker(
               fixture,
               &BackupRepository.load_pending(&1, Map.take(command, [:manifest_id, :vault_id]))
             )

    assert {:ok, sealed} =
             scoped_worker(
               fixture,
               &BackupRepository.acknowledge_sealed(&1, seal_command(copying, fixture, [object]))
             )

    assert {:error, %Error{code: :conflict}} =
             scoped_worker(fixture, &BackupRepository.mark_waiting_for_backup_key(&1, command))

    assert {:ok, ^sealed} =
             scoped_worker(
               fixture,
               &BackupRepository.load_pending(&1, Map.take(command, [:manifest_id, :vault_id]))
             )
  end

  test "inventory cannot be appended after its parent manifest is sealed", %{
    one: fixture,
    one_object: object,
    second_one_object: second_object
  } do
    copying = create_copying!(fixture)

    assert {:ok, %{status: :sealed}} =
             scoped_worker(
               fixture,
               &BackupRepository.acknowledge_sealed(&1, seal_command(copying, fixture, [object]))
             )

    assert_raise Postgrex.Error, ~r/permission denied/i, fn ->
      scoped_worker(fixture, fn repo ->
        query!(
          repo,
          """
          INSERT INTO audit.backup_manifest_objects (
            id, manifest_id, asset_object_id, vault_id, classification,
            inventory_position, storage_ref, ciphertext_byte_size, ciphertext_hash
          ) VALUES ($1, $2, $3, $4, 'private', 1, $5, $6, $7)
          """,
          [
            dump!(Ecto.UUID.generate()),
            dump!(copying.id),
            dump!(second_object.asset_object_id),
            dump!(fixture.vault_id),
            second_object.storage_ref,
            second_object.ciphertext_byte_size,
            second_object.ciphertext_hash
          ]
        )
      end)
    end
  end

  test "malformed or wrong-domain public metadata is rejected without effects", %{one: fixture} do
    valid = request_command(fixture)

    invalid_metadata = [
      put_in(public_metadata(valid), ["kdf", "domain"], "account-password-domain"),
      put_in(public_metadata(valid), ["kdf", "salt"], Base.encode64(<<1, 2>>)),
      put_in(public_metadata(valid), ["kdf", "salt"], Base.encode64(@salt, padding: false)),
      put_in(public_metadata(valid), ["recovery", "label"], "vault_key"),
      put_in(public_metadata(valid), ["recovery", "binding", "vault_id"], Ecto.UUID.generate()),
      Map.put(public_metadata(valid), "secret", "CANARY_SECRET")
    ]

    for metadata <- invalid_metadata do
      command = request_command(fixture) |> Map.put(:public_metadata, metadata)

      assert {:error, %Error{code: :invalid}} =
               scoped(fixture, &BackupRepository.insert_pending_and_enqueue(&1, command))
    end
  end

  defp create_copying!(fixture) do
    request = request_command(fixture)

    assert {:ok, _waiting} =
             scoped(fixture, &BackupRepository.insert_pending_and_enqueue(&1, request))

    activation = %{
      manifest_id: request.manifest_id,
      vault_id: fixture.vault_id,
      custody_ref: request.custody_ref
    }

    assert {:ok, %{status: :pending}} =
             scoped(fixture, &BackupRepository.mark_pending(&1, activation))

    assert {:ok, copying} =
             scoped_worker(
               fixture,
               &BackupRepository.load_pending(&1, Map.take(activation, [:manifest_id, :vault_id]))
             )

    copying
  end

  defp request_command(fixture) do
    manifest_id = Ecto.UUID.generate()

    %{
      audit_event_id: Ecto.UUID.generate(),
      causation_id: manifest_id,
      classification: :private,
      correlation_id: Ecto.UUID.generate(),
      custody_ref: "custody-#{Ecto.UUID.generate()}",
      destination_ref: "backup/#{manifest_id}.sgkc",
      manifest_id: manifest_id,
      occurred_at: DateTime.utc_now(:microsecond),
      outbox_event_id: Ecto.UUID.generate(),
      principal_authorization_epoch: 7,
      principal_id: fixture.principal_id,
      public_metadata: nil,
      vault_authorization_epoch: 23,
      vault_id: fixture.vault_id
    }
    |> then(&Map.put(&1, :public_metadata, public_metadata(&1)))
  end

  defp public_metadata(command) do
    Map.get(command, :public_metadata) ||
      %{
        "kdf" => %{
          "domain" => @kdf_domain,
          "parameters" => %{
            "m_cost" => 65_536,
            "parallelism" => 2,
            "t_cost" => 5,
            "version" => 4
          },
          "salt" => Base.encode64(@salt)
        },
        "recovery" => %{
          "binding" => %{
            "manifest_id" => command.manifest_id,
            "vault_id" => command.vault_id
          },
          "label" => "backup_recovery",
          "wrapper" => @wrapper
        }
      }
  end

  defp reentry_command(fixture, manifest, replacement_ref) do
    %{
      audit_event_id: Ecto.UUID.generate(),
      correlation_id: Ecto.UUID.generate(),
      expected_custody_ref: manifest.backup_key_lease_id,
      manifest_id: manifest.id,
      occurred_at: DateTime.utc_now(:microsecond),
      principal_id: fixture.principal_id,
      replacement_custody_ref: replacement_ref,
      vault_id: fixture.vault_id
    }
  end

  defp seal_command(copying, fixture, inventory) do
    inventory = Enum.with_index(inventory, &Map.put(&1, :inventory_position, &2))

    %{
      cut: %{
        object_inventory: inventory,
        outbox_high_water_mark: 41,
        snapshot_id: Ecto.UUID.generate(),
        vault_id: fixture.vault_id
      },
      expected_custody_ref: copying.backup_key_lease_id,
      manifest_id: copying.id,
      sealed: %{
        destination_ref: copying.destination_ref,
        inventory: [%{generic: "must-not-be-authoritative"}],
        manifest_hash: :binary.copy(<<0xA1>>, 32),
        manifest_id: copying.id,
        manifest_tag: :binary.copy(<<0xA2>>, 16),
        path: Path.join("/var/lib/singularity/backups", copying.destination_ref)
      },
      vault_id: fixture.vault_id
    }
  end

  defp create_object!(fixture, byte) do
    object_id = Ecto.UUID.generate()
    key_domain_id = Ecto.UUID.generate()
    storage_ref = "objects/#{object_id}"
    ciphertext_hash = :binary.copy(<<byte>>, 32)

    Fixtures.with_owner(fn ->
      query!(
        Singularity.Storage.MigrationRepo,
        """
        INSERT INTO core.key_domains (id, vault_id, classification)
        VALUES ($1, $2, 'private')
        """,
        [dump!(key_domain_id), fixture.vault_id]
      )

      query!(
        Singularity.Storage.MigrationRepo,
        """
        INSERT INTO content.asset_objects (
          id, vault_id, key_domain_id, classification, lookup_digest,
          ciphertext_hash, plaintext_byte_size, ciphertext_byte_size,
          storage_ref, format_version, lifecycle
        ) VALUES ($1, $2, $3, 'private', $4, $5, 17, 33, $6, 1, 'available')
        """,
        [
          dump!(object_id),
          fixture.vault_id,
          dump!(key_domain_id),
          :binary.copy(<<byte + 64>>, 32),
          ciphertext_hash,
          storage_ref
        ]
      )
    end)

    %{
      asset_object_id: object_id,
      ciphertext_byte_size: 33,
      ciphertext_hash: ciphertext_hash,
      classification: :private,
      inventory_position: 0,
      key_domain_id: key_domain_id,
      lookup_digest: :binary.copy(<<byte + 64>>, 32),
      storage_ref: storage_ref,
      vault_id: load!(fixture.vault_id)
    }
  end

  defp scoped(fixture, callback) do
    ScopedRepo.transact(
      RequestRepo,
      %{principal_id: fixture.principal_id, vault_id: fixture.vault_id},
      callback
    )
  end

  defp scoped_worker(fixture, callback) do
    ScopedRepo.transact(
      WorkerRepo,
      %{principal_id: fixture.principal_id, vault_id: fixture.vault_id},
      callback
    )
  end

  defp payload_and_rows(fixture, manifest_id) do
    scoped(fixture, fn repo ->
      query!(
        repo,
        """
        SELECT event.payload::text, audit.metadata::text
        FROM core.outbox_events AS event
        JOIN audit.events AS audit ON audit.target_id = $1
        WHERE event.payload = jsonb_build_object('pending_manifest_id', $2::text)
        """,
        [dump!(manifest_id), manifest_id]
      ).rows
    end)
  end

  defp contains_any?(value, canaries) do
    inspected = inspect(value, limit: :infinity, printable_limit: :infinity)
    binary = :erlang.term_to_binary(value)

    Enum.any?(canaries, fn canary ->
      is_binary(canary) and
        (String.contains?(inspected, canary) or :binary.match(binary, canary) != :nomatch)
    end)
  end

  defp load_ids(fixture) do
    Map.new(fixture, fn
      {key, value}
      when key in [
             :account_id,
             :asset_id,
             :credential_id,
             :principal_id,
             :resource_id,
             :resource_version_id,
             :session_id,
             :vault_id
           ] ->
        {key, load!(value)}

      pair ->
        pair
    end)
  end

  defp set_authorization_epochs!(fixture, principal_epoch, vault_epoch) do
    Fixtures.with_owner(fn ->
      query!(
        Singularity.Storage.MigrationRepo,
        "UPDATE identity.principals SET authorization_epoch = $2 WHERE id = $1",
        [fixture.principal_id, principal_epoch]
      )

      query!(
        Singularity.Storage.MigrationRepo,
        "UPDATE core.vaults SET authorization_epoch = $2 WHERE id = $1",
        [fixture.vault_id, vault_epoch]
      )
    end)
  end

  defp dump!(uuid), do: Ecto.UUID.dump!(uuid)
  defp load!(uuid), do: Ecto.UUID.load!(uuid)
end
