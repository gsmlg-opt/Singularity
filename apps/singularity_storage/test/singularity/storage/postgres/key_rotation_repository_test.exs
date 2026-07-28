defmodule Singularity.Storage.Postgres.KeyRotationRepositoryTest do
  use Singularity.Storage.DataCase, async: false

  @moduletag :integration

  alias Ecto.Adapters.SQL
  alias Singularity.Core.AuditEvent
  alias Singularity.Core.Error
  alias Singularity.Storage.Fixtures
  alias Singularity.Storage.MigrationRepo
  alias Singularity.Storage.Postgres.AuditSink
  alias Singularity.Storage.Postgres.KeyRotationRepository
  alias Singularity.Storage.ScopedRepo

  setup do
    %{one: one, two: two} = Fixtures.two_vaults!()

    one = one |> load_ids() |> add_key_material(insert_key_material!(one, 0x11, 2))
    two = two |> load_ids() |> add_key_material(insert_key_material!(two, 0x51, 1))

    set_vault_locked!(one, false)
    set_vault_locked!(two, false)

    {:ok, one: one, two: two}
  end

  test "loads complete scoped material and atomically rotates a vault key with one audit",
       %{one: one, two: two} do
    assert {:ok, material} =
             scoped(one, &KeyRotationRepository.load_vault_rotation_material(&1, identity(one)))

    expected_kdf_salt = :binary.copy(<<0x11>>, 16)
    expected_wrapped_vault_key = :binary.copy(<<0x31>>, 48)

    assert %{
             vault_key_version: %{
               id: old_vault_version_id,
               generation: 3,
               algorithm: "aes-256-gcm"
             },
             vault_wrapper: %{
               id: old_wrapper_id,
               vault_key_version_id: old_vault_version_id,
               account_id: account_id,
               generation: 7,
               kdf_version: 1,
               kdf_salt: ^expected_kdf_salt,
               kdf_parameters: %{
                 "m_cost" => 16,
                 "parallelism" => 1,
                 "t_cost" => 3,
                 "version" => 1
               },
               wrapper_algorithm: "aes_256_gcm",
               wrapped_key: ^expected_wrapped_vault_key
             },
             domain_key_versions: domain_versions
           } = material

    assert old_wrapper_id == one.key_material.vault_key_wrapper_id
    assert account_id == one.account_id
    assert Enum.map(domain_versions, & &1.id) == Enum.sort(Enum.map(domain_versions, & &1.id))
    assert length(domain_versions) == 2
    refute Enum.any?(domain_versions, &(&1.vault_id == two.vault_id))

    audit = audit(one, "vault.key_rotated", "vault", one.vault_id)
    command = vault_rotation_command(one, material, audit)
    refute vault_locked?(one)

    assert {:error, :injected_rollback} =
             scoped(one, fn repo ->
               assert {:ok,
                       %{
                         id: new_id,
                         generation: 4,
                         state: :active,
                         vault_key_wrapper_id: new_wrapper_id
                       }} =
                        KeyRotationRepository.rotate_vault_key_and_audit(repo, command)

               assert new_id == command.plan.next_vault_key_version_id
               assert is_binary(new_wrapper_id)
               repo.rollback(:injected_rollback)
             end)

    assert vault_state(one) == %{
             active_id: old_vault_version_id,
             active_generation: 3,
             active_wrapper_id: old_wrapper_id,
             active_wrapper_generation: 7,
             audit_operations: []
           }

    refute vault_locked?(one)

    assert {:ok,
            %{
              id: new_id,
              generation: 4,
              state: :active,
              vault_key_wrapper_id: new_wrapper_id
            }} =
             scoped(
               one,
               &KeyRotationRepository.rotate_vault_key_and_audit(&1, command)
             )

    assert new_id == command.plan.next_vault_key_version_id
    assert active_vault_algorithm(one) == "aes-256-gcm"

    assert active_vault_wrapper_metadata(one) == %{
             generation: 8,
             kdf_version: 1,
             kdf_salt: expected_kdf_salt,
             kdf_parameters: %{
               "m_cost" => 16,
               "parallelism" => 1,
               "t_cost" => 3,
               "version" => 1
             },
             wrapper_algorithm: "aes_256_gcm"
           }

    assert vault_state(one) == %{
             active_id: new_id,
             active_generation: 4,
             active_wrapper_id: new_wrapper_id,
             active_wrapper_generation: 8,
             audit_operations: ["vault.key_rotated"]
           }

    assert vault_locked?(one)
    refute vault_locked?(two)
    assert retired_generation(one, :vault) == 3

    assert Enum.all?(command.plan.domain_versions, fn prepared ->
             active_domain_wrapper(one, prepared.key_domain_id) == %{
               vault_key_version_id: new_id,
               generation: prepared.generation,
               wrapped_key: prepared.wrapped_key
             }
           end)
  end

  test "vault rotation rejects incomplete plans and rolls every write back on audit failure", %{
    one: one
  } do
    assert {:ok, material} =
             scoped(one, &KeyRotationRepository.load_vault_rotation_material(&1, identity(one)))

    command =
      vault_rotation_command(
        one,
        material,
        audit(one, "vault.key_rotated", "vault", one.vault_id)
      )

    assert {:error, %Error{code: :invalid}} =
             KeyRotationRepository.rotate_vault_key_and_audit(RequestRepo, command)

    assert vault_version_count(one) == 1

    set_vault_locked!(one, true)

    assert {:error, %Error{code: :conflict}} =
             scoped(
               one,
               &KeyRotationRepository.rotate_vault_key_and_audit(&1, command)
             )

    assert vault_locked?(one)
    assert vault_version_count(one) == 1
    assert audit_operations(one) == []
    set_vault_locked!(one, false)

    [first_domain, _second_domain] = command.plan.domain_versions

    rejected_commands = [
      put_in(command, [:plan, :domain_versions], tl(command.plan.domain_versions)),
      put_in(command, [:plan, :domain_versions], [first_domain, first_domain]),
      put_in(
        command,
        [:plan, :domain_versions],
        [
          %{first_domain | expected_wrapped_key: :binary.copy(<<0xFF>>, 48)}
          | tl(command.plan.domain_versions)
        ]
      )
    ]

    for rejected <- rejected_commands do
      assert {:error, %Error{code: :conflict}} =
               scoped(
                 one,
                 &KeyRotationRepository.rotate_vault_key_and_audit(&1, rejected)
               )
    end

    assert {:error, %Error{code: :invalid}} =
             scoped(
               one,
               &KeyRotationRepository.rotate_vault_key_and_audit(
                 &1,
                 Map.put(command, :vault_key, :binary.copy(<<0xEE>>, 32))
               )
             )

    assert vault_state(one).active_generation == 3
    assert vault_state(one).audit_operations == []
    refute vault_locked?(one)

    duplicate_audit = audit(one, "vault.key_rotated", "vault", one.vault_id)
    assert :ok = scoped(one, &AuditSink.append(&1, duplicate_audit))
    command = vault_rotation_command(one, material, duplicate_audit)

    assert {:error, %Error{code: :conflict}} =
             scoped(
               one,
               &KeyRotationRepository.rotate_vault_key_and_audit(&1, command)
             )

    assert vault_state(one).active_generation == 3
    assert vault_state(one).audit_operations == ["vault.key_rotated"]
    assert vault_version_count(one) == 1
    refute vault_locked?(one)

    set_active_generations!(one, 2_147_483_647, 2_147_483_647)

    assert {:ok, boundary_material} =
             scoped(one, &KeyRotationRepository.load_vault_rotation_material(&1, identity(one)))

    overflow =
      vault_rotation_command(
        one,
        boundary_material,
        audit(one, "vault.key_rotated", "vault", one.vault_id)
      )

    assert {:error, %Error{code: :conflict}} =
             scoped(
               one,
               &KeyRotationRepository.rotate_vault_key_and_audit(&1, overflow)
             )

    insert_inconsistent_active_domain!(one)

    assert {:error, %Error{code: :conflict}} =
             scoped(
               one,
               &KeyRotationRepository.load_vault_rotation_material(&1, identity(one))
             )

    inconsistent_domain_lookup =
      Map.put(identity(one), :key_domain_id, one.key_material.rotation_domain_id)

    assert {:error, %Error{code: :conflict}} =
             scoped(
               one,
               &KeyRotationRepository.load_domain_rotation_material(
                 &1,
                 inconsistent_domain_lookup
               )
             )
  end

  test "loads every live envelope and rotates a domain without changing canonical ciphertext",
       %{one: one, two: two} do
    key_domain_id = one.key_material.rotation_domain_id

    lookup = Map.put(identity(one), :key_domain_id, key_domain_id)

    assert {:ok, material} =
             scoped(one, &KeyRotationRepository.load_domain_rotation_material(&1, lookup))

    assert %{
             domain_key_version: %{
               id: old_domain_version_id,
               vault_id: vault_id,
               key_domain_id: ^key_domain_id,
               vault_key_version_id: old_vault_version_id,
               generation: 5,
               algorithm: "aes_256_gcm",
               wrapped_key: old_wrapped_domain_key,
               classification: :private
             },
             dedup_key_wrapper: %{
               id: old_dedup_id,
               domain_key_version_id: old_domain_version_id,
               algorithm: "aes_256_gcm",
               wrapped_key: old_wrapped_dedup_key
             },
             asset_envelopes: envelopes
           } = material

    assert vault_id == one.vault_id
    assert old_vault_version_id == one.key_material.vault_key_version_id
    expected_domain_key = :binary.copy(<<0x41>>, 48)
    expected_dedup_key = :binary.copy(<<0x51>>, 48)
    rotation_domain = Enum.find(one.key_material.domains, &(&1.key_domain_id == key_domain_id))

    assert old_wrapped_domain_key == expected_domain_key
    assert old_dedup_id == rotation_domain.dedup_wrapper_id
    assert old_wrapped_dedup_key == expected_dedup_key
    assert Enum.map(envelopes, & &1.id) == Enum.sort(Enum.map(envelopes, & &1.id))
    assert length(envelopes) == 2

    cross_vault_lookup = %{lookup | session_id: two.session_id, principal_id: two.principal_id}

    assert {:error, %Error{code: :not_found}} =
             scoped(
               two,
               &KeyRotationRepository.load_domain_rotation_material(&1, cross_vault_lookup)
             )

    object_snapshot = object_snapshot(one, key_domain_id)
    audit = audit(one, "domain.key_rotated", "domain", key_domain_id)
    command = domain_rotation_command(one, material, audit)

    assert {:ok,
            %{
              id: new_id,
              generation: 6,
              state: :active,
              dedup_key_wrapper_id: new_dedup_id,
              asset_envelope_ids: new_envelope_ids
            }} =
             scoped(
               one,
               &KeyRotationRepository.rotate_domain_key_and_audit(&1, command)
             )

    assert new_id == command.plan.next_domain_key_version_id
    assert length(new_envelope_ids) == 2
    assert retired_generation(one, {:domain, key_domain_id}) == 5
    assert object_snapshot(one, key_domain_id) == object_snapshot
    assert audit_operations(one) == ["domain.key_rotated"]

    assert active_domain_state(one, key_domain_id) == %{
             id: new_id,
             generation: 6,
             dedup_wrapper_id: new_dedup_id,
             envelope_count: 2
           }

    assert vault_locked?(one)
    refute vault_locked?(two)
  end

  test "domain rotation rejects incomplete envelopes and audit failure leaves the old key active",
       %{one: one} do
    key_domain_id = one.key_material.rotation_domain_id
    lookup = Map.put(identity(one), :key_domain_id, key_domain_id)

    assert {:ok, material} =
             scoped(one, &KeyRotationRepository.load_domain_rotation_material(&1, lookup))

    command =
      domain_rotation_command(
        one,
        material,
        audit(one, "domain.key_rotated", "domain", key_domain_id)
      )

    assert {:error, %Error{code: :invalid}} =
             KeyRotationRepository.rotate_domain_key_and_audit(RequestRepo, command)

    assert domain_version_count(one, key_domain_id) == 1

    set_vault_locked!(one, true)

    assert {:error, %Error{code: :conflict}} =
             scoped(
               one,
               &KeyRotationRepository.rotate_domain_key_and_audit(&1, command)
             )

    assert vault_locked?(one)
    assert domain_version_count(one, key_domain_id) == 1
    assert audit_operations(one) == []
    set_vault_locked!(one, false)

    [first_envelope, _second_envelope] = command.plan.asset_envelopes

    rejected_commands = [
      put_in(command, [:plan, :asset_envelopes], tl(command.plan.asset_envelopes)),
      put_in(command, [:plan, :asset_envelopes], [first_envelope, first_envelope]),
      put_in(
        command,
        [:plan, :asset_envelopes],
        [
          %{first_envelope | expected_key_generation: first_envelope.expected_key_generation + 1}
          | tl(command.plan.asset_envelopes)
        ]
      )
    ]

    for rejected <- rejected_commands do
      assert {:error, %Error{code: :conflict}} =
               scoped(
                 one,
                 &KeyRotationRepository.rotate_domain_key_and_audit(&1, rejected)
               )
    end

    assert {:error, %Error{code: :invalid}} =
             scoped(
               one,
               &KeyRotationRepository.rotate_domain_key_and_audit(
                 &1,
                 Map.put(command, :domain_key, :binary.copy(<<0xDD>>, 32))
               )
             )

    assert active_domain_state(one, key_domain_id).generation == 5
    assert audit_operations(one) == []

    duplicate_audit = audit(one, "domain.key_rotated", "domain", key_domain_id)
    assert :ok = scoped(one, &AuditSink.append(&1, duplicate_audit))
    command = domain_rotation_command(one, material, duplicate_audit)

    assert {:error, %Error{code: :conflict}} =
             scoped(
               one,
               &KeyRotationRepository.rotate_domain_key_and_audit(&1, command)
             )

    assert active_domain_state(one, key_domain_id) == %{
             id: material.domain_key_version.id,
             generation: 5,
             dedup_wrapper_id: material.dedup_key_wrapper.id,
             envelope_count: 2
           }

    assert audit_operations(one) == ["domain.key_rotated"]
    assert domain_version_count(one, key_domain_id) == 1
    assert object_snapshot(one, key_domain_id) == one.key_material.object_snapshot
    refute vault_locked?(one)
  end

  test "active envelope guard accepts current custody and rejects retired custody", %{one: one} do
    key_domain_id = one.key_material.rotation_domain_id
    active_version_id = one.key_material.vault_key_version_id

    active_domain_version =
      Enum.find(one.key_material.domains, &(&1.key_domain_id == key_domain_id))

    active_object_id = Ecto.UUID.generate()

    assert {:ok, %Postgrex.Result{num_rows: 1}} =
             scoped(one, fn repo ->
               insert_runtime_object!(repo, one, key_domain_id, active_object_id)

               insert_runtime_envelope(
                 repo,
                 one,
                 active_object_id,
                 key_domain_id,
                 active_domain_version.domain_key_version_id,
                 5
               )
             end)

    assert object_envelope_counts(one, active_object_id) == [1, 1]

    independent_generation_object_id = Ecto.UUID.generate()

    assert {:ok, %Postgrex.Result{num_rows: 1}} =
             scoped(one, fn repo ->
               insert_runtime_object!(
                 repo,
                 one,
                 key_domain_id,
                 independent_generation_object_id
               )

               insert_runtime_envelope(
                 repo,
                 one,
                 independent_generation_object_id,
                 key_domain_id,
                 active_domain_version.domain_key_version_id,
                 4
               )
             end)

    assert object_envelope_counts(one, independent_generation_object_id) == [1, 1]

    retired =
      insert_retired_domain_version!(
        one,
        key_domain_id,
        active_version_id
      )

    rejected_object_id = Ecto.UUID.generate()

    assert {:error, %Postgrex.Error{} = error} =
             scoped(one, fn repo ->
               insert_runtime_object!(repo, one, key_domain_id, rejected_object_id)

               insert_runtime_envelope(
                 repo,
                 one,
                 rejected_object_id,
                 key_domain_id,
                 retired.id,
                 retired.generation
               )
             end)

    assert_active_domain_guard(error)
    assert object_envelope_counts(one, rejected_object_id) == [0, 0]

    historical_object_id = Ecto.UUID.generate()

    Fixtures.with_owner(fn ->
      insert_runtime_object!(MigrationRepo, one, key_domain_id, historical_object_id)

      assert {:ok, %Postgrex.Result{num_rows: 1}} =
               insert_runtime_envelope(
                 MigrationRepo,
                 one,
                 historical_object_id,
                 key_domain_id,
                 retired.id,
                 retired.generation
               )
    end)

    assert object_envelope_counts(one, historical_object_id) == [1, 1]

    assert {:error, %Postgrex.Error{} = update_error} =
             scoped(one, fn repo ->
               touch_envelope_generation(repo, historical_object_id)
             end)

    assert_active_domain_guard(update_error)

    assert {:ok, %Postgrex.Result{num_rows: 1}} =
             Fixtures.with_owner(fn ->
               touch_envelope_generation(MigrationRepo, historical_object_id)
             end)
  end

  test "a stale envelope insert waits for domain rotation and fails after commit", %{one: one} do
    key_domain_id = one.key_material.rotation_domain_id
    lookup = Map.put(identity(one), :key_domain_id, key_domain_id)

    assert {:ok, material} =
             scoped(one, &KeyRotationRepository.load_domain_rotation_material(&1, lookup))

    command =
      domain_rotation_command(
        one,
        material,
        audit(one, "domain.key_rotated", "domain", key_domain_id)
      )

    coordinator = self()
    stale_object_id = Ecto.UUID.generate()
    insert_deleted_object!(one, key_domain_id, stale_object_id)

    stale_insert =
      Task.async(fn ->
        scoped(one, fn repo ->
          %{rows: [[backend_pid]]} = query!(repo, "SELECT pg_backend_pid()")

          assert %{rows: [[1]]} =
                   query!(
                     repo,
                     """
                     SELECT 1
                     FROM core.domain_key_versions
                     WHERE id = $1
                       AND vault_id = $2
                       AND key_domain_id = $3
                       AND state = 'active'
                     """,
                     [
                       dump(material.domain_key_version.id),
                       dump(one.vault_id),
                       dump(key_domain_id)
                     ]
                   )

          send(coordinator, {:stale_finalization_ready, self(), backend_pid})

          receive do
            :attempt_stale_insert -> :ok
          end

          send(coordinator, {:stale_insert_started, self()})

          result =
            insert_runtime_envelope(
              repo,
              one,
              stale_object_id,
              key_domain_id,
              material.domain_key_version.id,
              material.domain_key_version.generation
            )

          send(coordinator, {:stale_insert_result, self(), result})
          result
        end)
      end)

    assert_receive {:stale_finalization_ready, stale_pid, stale_backend_pid}, 5_000
    assert stale_pid == stale_insert.pid

    rotation =
      Task.async(fn ->
        scoped(one, fn repo ->
          result = KeyRotationRepository.rotate_domain_key_and_audit(repo, command)
          send(coordinator, {:rotation_staged, self(), result})

          receive do
            :commit_rotation -> result
          end
        end)
      end)

    try do
      assert_receive {:rotation_staged, rotation_pid, {:ok, rotated}}, 5_000
      assert rotation_pid == rotation.pid
      assert rotated.id == command.plan.next_domain_key_version_id

      send(stale_insert.pid, :attempt_stale_insert)
      assert_receive {:stale_insert_started, ^stale_pid}, 5_000
      await_backend_blocked!(stale_backend_pid)
      refute_receive {:stale_insert_result, ^stale_pid, _result}, 200

      send(rotation.pid, :commit_rotation)
      assert {:ok, %{id: rotated_id}} = Task.await(rotation, 5_000)
      assert rotated_id == command.plan.next_domain_key_version_id

      assert_receive {:stale_insert_result, ^stale_pid, {:error, %Postgrex.Error{} = error}},
                     5_000

      assert_active_domain_guard(error)
      assert {:error, %Postgrex.Error{}} = Task.await(stale_insert, 5_000)
    after
      send(stale_insert.pid, :attempt_stale_insert)
      send(rotation.pid, :commit_rotation)
    end

    assert object_envelope_counts(one, stale_object_id) == [1, 0]
    assert vault_locked?(one)
  end

  defp vault_rotation_command(fixture, material, audit) do
    new_version_generation = material.vault_key_version.generation + 1
    new_wrapper_generation = material.vault_wrapper.generation + 1

    Map.merge(identity(fixture), %{
      plan: %{
        next_vault_key_version_id: Ecto.UUID.generate(),
        next_vault_key_version_generation: new_version_generation,
        next_vault_wrapper_generation: new_wrapper_generation,
        vault_wrapper: %{
          generation: new_wrapper_generation,
          algorithm: material.vault_wrapper.wrapper_algorithm,
          wrapped_key: :binary.copy(<<0x71>>, 48)
        },
        domain_versions:
          Enum.map(material.domain_key_versions, fn version ->
            %{
              id: version.id,
              key_domain_id: version.key_domain_id,
              generation: version.generation,
              algorithm: version.algorithm,
              expected_wrapped_key: version.wrapped_key,
              wrapped_key: :binary.copy(<<0x80 + rem(version.generation, 16)>>, 48)
            }
          end)
      },
      audit: audit
    })
  end

  defp domain_rotation_command(fixture, material, audit) do
    new_generation = material.domain_key_version.generation + 1

    Map.merge(identity(fixture), %{
      key_domain_id: material.domain_key_version.key_domain_id,
      plan: %{
        next_domain_key_version_id: Ecto.UUID.generate(),
        next_domain_key_generation: new_generation,
        domain_wrapper: %{
          vault_key_version_id: material.domain_key_version.vault_key_version_id,
          algorithm: material.domain_key_version.algorithm,
          wrapped_key: :binary.copy(<<0x91>>, 48)
        },
        dedup_wrapper: %{
          algorithm: material.dedup_key_wrapper.algorithm,
          wrapped_key: :binary.copy(<<0xA1>>, 48)
        },
        asset_envelopes:
          Enum.map(material.asset_envelopes, fn envelope ->
            %{
              expected_envelope_id: envelope.id,
              asset_object_id: envelope.asset_object_id,
              expected_key_generation: envelope.key_generation,
              classification: envelope.classification,
              algorithm: envelope.algorithm,
              key_generation: new_generation,
              wrapped_dek: :binary.copy(<<0xB1>>, 48)
            }
          end)
      },
      audit: audit
    })
  end

  defp audit(fixture, action, target_type, target_id) do
    {:ok, event} =
      AuditEvent.new(%{
        audit_event_id: Ecto.UUID.generate(),
        actor_kind: :principal,
        principal_id: fixture.principal_id,
        vault_id: fixture.vault_id,
        action: action,
        result: :completed,
        classification: :restricted,
        correlation_id: Ecto.UUID.generate(),
        target_type: target_type,
        target_id: target_id,
        occurred_at: DateTime.utc_now(:microsecond),
        metadata: %{}
      })

    event
  end

  defp insert_key_material!(fixture, marker, domain_count) do
    Fixtures.with_owner(fn ->
      vault_key_version_id = Ecto.UUID.generate()
      vault_key_wrapper_id = Ecto.UUID.generate()

      query!(
        MigrationRepo,
        """
        INSERT INTO core.vault_key_versions (
          id, vault_id, generation, state, algorithm, activated_at
        ) VALUES ($1, $2, 3, 'active', 'aes-256-gcm', CURRENT_TIMESTAMP)
        """,
        [dump(vault_key_version_id), fixture.vault_id]
      )

      query!(
        MigrationRepo,
        """
        INSERT INTO core.vault_key_wrappers (
          id,
          vault_id,
          vault_key_version_id,
          account_id,
          generation,
          kdf_version,
          kdf_salt,
          kdf_parameters,
          wrapper_algorithm,
          wrapped_key
        ) VALUES ($1, $2, $3, $4, 7, 1, $5, $6::text::jsonb, 'aes_256_gcm', $7)
        """,
        [
          dump(vault_key_wrapper_id),
          fixture.vault_id,
          dump(vault_key_version_id),
          fixture.account_id,
          :binary.copy(<<marker>>, 16),
          JSON.encode!(%{
            "version" => 1,
            "t_cost" => 3,
            "m_cost" => 16,
            "parallelism" => 1
          }),
          :binary.copy(<<marker + 0x20>>, 48)
        ]
      )

      domains =
        for index <- 0..(domain_count - 1) do
          insert_domain!(fixture, vault_key_version_id, marker + index)
        end

      %{
        vault_key_version_id: vault_key_version_id,
        vault_key_wrapper_id: vault_key_wrapper_id,
        domains: Enum.sort_by(domains, & &1.key_domain_id),
        rotation_domain_id: domains |> hd() |> Map.fetch!(:key_domain_id),
        object_snapshot:
          domains
          |> hd()
          |> then(&object_snapshot_owner(fixture, &1.key_domain_id))
      }
    end)
  end

  defp insert_domain!(fixture, vault_key_version_id, marker) do
    key_domain_id = Ecto.UUID.generate()
    domain_key_version_id = Ecto.UUID.generate()
    dedup_wrapper_id = Ecto.UUID.generate()

    query!(
      MigrationRepo,
      """
      INSERT INTO core.key_domains (
        id, vault_id, classification, kind, state
      ) VALUES ($1, $2, 'private', 'content', 'active')
      """,
      [dump(key_domain_id), fixture.vault_id]
    )

    query!(
      MigrationRepo,
      """
      INSERT INTO core.domain_key_versions (
        id,
        vault_id,
        key_domain_id,
        vault_key_version_id,
        generation,
        state,
        algorithm,
        wrapped_key
      ) VALUES ($1, $2, $3, $4, 5, 'active', 'aes_256_gcm', $5)
      """,
      [
        dump(domain_key_version_id),
        fixture.vault_id,
        dump(key_domain_id),
        dump(vault_key_version_id),
        :binary.copy(<<marker + 0x30>>, 48)
      ]
    )

    query!(
      MigrationRepo,
      """
      INSERT INTO core.domain_dedup_key_wrappers (
        id,
        vault_id,
        key_domain_id,
        domain_key_version_id,
        algorithm,
        wrapped_key
      ) VALUES ($1, $2, $3, $4, 'aes_256_gcm', $5)
      """,
      [
        dump(dedup_wrapper_id),
        fixture.vault_id,
        dump(key_domain_id),
        dump(domain_key_version_id),
        :binary.copy(<<marker + 0x40>>, 48)
      ]
    )

    object_ids =
      if marker == 0x11 do
        for object_marker <- [marker, marker + 1] do
          insert_object_and_envelope!(
            fixture,
            key_domain_id,
            domain_key_version_id,
            object_marker
          )
        end
      else
        []
      end

    %{
      key_domain_id: key_domain_id,
      domain_key_version_id: domain_key_version_id,
      dedup_wrapper_id: dedup_wrapper_id,
      object_ids: Enum.sort(object_ids)
    }
  end

  defp insert_object_and_envelope!(
         fixture,
         key_domain_id,
         domain_key_version_id,
         marker
       ) do
    object_id = Ecto.UUID.generate()
    envelope_id = Ecto.UUID.generate()

    query!(
      MigrationRepo,
      """
      INSERT INTO content.asset_objects (
        id,
        vault_id,
        key_domain_id,
        classification,
        lookup_digest,
        ciphertext_hash,
        plaintext_byte_size,
        ciphertext_byte_size,
        storage_ref,
        format_version,
        lifecycle
      ) VALUES ($1, $2, $3, 'private', $4, $5, 31, 79, $6, 1, 'available')
      """,
      [
        dump(object_id),
        fixture.vault_id,
        dump(key_domain_id),
        :binary.copy(<<marker>>, 32),
        :binary.copy(<<marker + 0x10>>, 32),
        "rotation/#{object_id}"
      ]
    )

    query!(
      MigrationRepo,
      """
      INSERT INTO content.asset_key_envelopes (
        id,
        vault_id,
        asset_object_id,
        domain_key_version_id,
        key_domain_id,
        classification,
        algorithm,
        key_generation,
        wrapped_dek
      ) VALUES ($1, $2, $3, $4, $5, 'private', 'aes_256_gcm', 5, $6)
      """,
      [
        dump(envelope_id),
        fixture.vault_id,
        dump(object_id),
        dump(domain_key_version_id),
        dump(key_domain_id),
        :binary.copy(<<marker + 0x20>>, 48)
      ]
    )

    object_id
  end

  defp insert_inconsistent_active_domain!(fixture) do
    Fixtures.with_owner(fn ->
      retired_vault_version_id = Ecto.UUID.generate()
      domain_key_version_id = Ecto.UUID.generate()

      query!(
        MigrationRepo,
        """
        INSERT INTO core.vault_key_versions (
          id, vault_id, generation, state, algorithm, activated_at, retired_at
        ) VALUES (
          $1, $2, 2, 'retired', 'aes-256-gcm', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
        )
        """,
        [dump(retired_vault_version_id), dump(fixture.vault_id)]
      )

      query!(
        MigrationRepo,
        """
        INSERT INTO core.domain_key_versions (
          id,
          vault_id,
          key_domain_id,
          vault_key_version_id,
          generation,
          state,
          algorithm,
          wrapped_key
        ) VALUES ($1, $2, $3, $4, 4, 'active', 'aes_256_gcm', $5)
        """,
        [
          dump(domain_key_version_id),
          dump(fixture.vault_id),
          dump(fixture.key_material.rotation_domain_id),
          dump(retired_vault_version_id),
          :binary.copy(<<0xCC>>, 48)
        ]
      )
    end)
  end

  defp insert_retired_domain_version!(fixture, key_domain_id, vault_key_version_id) do
    id = Ecto.UUID.generate()
    generation = 4

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        """
        INSERT INTO core.domain_key_versions (
          id,
          vault_id,
          key_domain_id,
          vault_key_version_id,
        generation,
        state,
        algorithm,
        wrapped_key
        ) VALUES (
        $1, $2, $3, $4, $5, 'retired', 'aes_256_gcm', $6
        )
        """,
        [
          dump(id),
          dump(fixture.vault_id),
          dump(key_domain_id),
          dump(vault_key_version_id),
          generation,
          :binary.copy(<<0xCD>>, 48)
        ]
      )
    end)

    %{id: id, generation: generation}
  end

  defp insert_deleted_object!(fixture, key_domain_id, object_id) do
    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        """
        INSERT INTO content.asset_objects (
          id,
          vault_id,
          key_domain_id,
          classification,
          lookup_digest,
          ciphertext_hash,
          plaintext_byte_size,
          ciphertext_byte_size,
          storage_ref,
          format_version,
          lifecycle,
          deleted_at,
          deletion_evidence
        ) VALUES (
          $1, $2, $3, 'private', $4, $5, 31, 79, $6, 1, 'deleted',
          CURRENT_TIMESTAMP, '{}'::jsonb
        )
        """,
        [
          dump(object_id),
          dump(fixture.vault_id),
          dump(key_domain_id),
          :crypto.hash(:sha256, "guard-lookup:#{object_id}"),
          :crypto.hash(:sha256, "guard-ciphertext:#{object_id}"),
          "rotation-guard/#{object_id}"
        ]
      )
    end)
  end

  defp insert_runtime_object!(repo, fixture, key_domain_id, object_id) do
    query!(
      repo,
      """
      INSERT INTO content.asset_objects (
        id,
        vault_id,
        key_domain_id,
        classification,
        lookup_digest,
        ciphertext_hash,
        plaintext_byte_size,
        ciphertext_byte_size,
        storage_ref,
        format_version,
        lifecycle
      ) VALUES (
        $1, $2, $3, 'private', $4, $5, 31, 79, $6, 1, 'available'
      )
      """,
      [
        dump(object_id),
        dump(fixture.vault_id),
        dump(key_domain_id),
        :crypto.hash(:sha256, "guard-lookup:#{object_id}"),
        :crypto.hash(:sha256, "guard-ciphertext:#{object_id}"),
        "rotation-guard/#{object_id}"
      ]
    )

    :ok
  end

  defp insert_runtime_envelope(
         repo,
         fixture,
         object_id,
         key_domain_id,
         domain_key_version_id,
         generation
       ) do
    SQL.query(
      repo,
      """
      INSERT INTO content.asset_key_envelopes (
        id,
        vault_id,
        asset_object_id,
        domain_key_version_id,
        key_domain_id,
        classification,
        algorithm,
        key_generation,
        wrapped_dek
      ) VALUES (
        $1, $2, $3, $4, $5, 'private', 'aes_256_gcm', $6, $7
      )
      """,
      [
        dump(Ecto.UUID.generate()),
        dump(fixture.vault_id),
        dump(object_id),
        dump(domain_key_version_id),
        dump(key_domain_id),
        generation,
        :binary.copy(<<0xCE>>, 48)
      ],
      log: false
    )
  end

  defp touch_envelope_generation(repo, object_id) do
    SQL.query(
      repo,
      """
      UPDATE content.asset_key_envelopes
      SET key_generation = key_generation
      WHERE asset_object_id = $1
      """,
      [dump(object_id)],
      log: false
    )
  end

  defp assert_active_domain_guard(%Postgrex.Error{
         postgres: %{
           code: :check_violation,
           constraint: "asset_key_envelopes_active_domain_key_check"
         }
       }),
       do: :ok

  defp object_envelope_counts(_fixture, object_id) do
    Fixtures.with_owner(fn ->
      %{rows: [[object_count, envelope_count]]} =
        query!(
          MigrationRepo,
          """
          SELECT
            (SELECT count(*) FROM content.asset_objects WHERE id = $1),
            (SELECT count(*) FROM content.asset_key_envelopes WHERE asset_object_id = $1)
          """,
          [dump(object_id)]
        )

      [object_count, envelope_count]
    end)
  end

  defp vault_locked?(fixture) do
    Fixtures.with_owner(fn ->
      %{rows: [[locked?]]} =
        query!(
          MigrationRepo,
          "SELECT locked FROM core.vaults WHERE id = $1",
          [dump(fixture.vault_id)]
        )

      locked?
    end)
  end

  defp set_vault_locked!(fixture, locked?) do
    Fixtures.with_owner(fn ->
      %{num_rows: 1} =
        query!(
          MigrationRepo,
          "UPDATE core.vaults SET locked = $1 WHERE id = $2",
          [locked?, dump(fixture.vault_id)]
        )
    end)
  end

  defp await_backend_blocked!(backend_pid, attempts \\ 250)

  defp await_backend_blocked!(_backend_pid, 0) do
    flunk("stale asset envelope insert did not block behind domain rotation")
  end

  defp await_backend_blocked!(backend_pid, attempts) do
    %{rows: [[blocked?]]} =
      query!(
        RequestRepo,
        "SELECT cardinality(pg_blocking_pids($1)) > 0",
        [backend_pid]
      )

    if blocked? do
      :ok
    else
      Process.sleep(20)
      await_backend_blocked!(backend_pid, attempts - 1)
    end
  end

  defp identity(fixture) do
    %{
      session_id: fixture.session_id,
      principal_id: fixture.principal_id,
      vault_id: fixture.vault_id
    }
  end

  defp scoped(fixture, fun) do
    RequestRepo.checkout(fn ->
      ScopedRepo.transact(
        RequestRepo,
        %{principal_id: fixture.principal_id, vault_id: fixture.vault_id},
        fun
      )
    end)
  end

  defp vault_state(fixture) do
    Fixtures.with_owner(fn ->
      %{rows: [[active_id, active_generation, active_wrapper_id, wrapper_generation]]} =
        query!(
          MigrationRepo,
          """
          SELECT version.id, version.generation, wrapper.id, wrapper.generation
          FROM core.vault_key_versions AS version
          JOIN core.vault_key_wrappers AS wrapper
            ON wrapper.vault_key_version_id = version.id
           AND wrapper.vault_id = version.vault_id
          WHERE version.vault_id = $1
            AND version.state = 'active'
            AND wrapper.account_id = $2
          """,
          [dump(fixture.vault_id), dump(fixture.account_id)]
        )

      %{
        active_id: Ecto.UUID.load!(active_id),
        active_generation: active_generation,
        active_wrapper_id: Ecto.UUID.load!(active_wrapper_id),
        active_wrapper_generation: wrapper_generation,
        audit_operations: audit_operations_owner(fixture)
      }
    end)
  end

  defp active_domain_wrapper(fixture, key_domain_id) do
    Fixtures.with_owner(fn ->
      %{rows: [[vault_version_id, generation, wrapped_key]]} =
        query!(
          MigrationRepo,
          """
          SELECT vault_key_version_id, generation, wrapped_key
          FROM core.domain_key_versions
          WHERE vault_id = $1 AND key_domain_id = $2 AND state = 'active'
          """,
          [dump(fixture.vault_id), dump(key_domain_id)]
        )

      %{
        vault_key_version_id: Ecto.UUID.load!(vault_version_id),
        generation: generation,
        wrapped_key: wrapped_key
      }
    end)
  end

  defp active_domain_state(fixture, key_domain_id) do
    Fixtures.with_owner(fn ->
      %{rows: [[id, generation, dedup_id, envelope_count]]} =
        query!(
          MigrationRepo,
          """
          SELECT
            version.id,
            version.generation,
            dedup.id,
            count(envelope.id)
          FROM core.domain_key_versions AS version
          JOIN core.domain_dedup_key_wrappers AS dedup
            ON dedup.domain_key_version_id = version.id
           AND dedup.vault_id = version.vault_id
           AND dedup.key_domain_id = version.key_domain_id
          LEFT JOIN content.asset_key_envelopes AS envelope
            ON envelope.domain_key_version_id = version.id
           AND envelope.vault_id = version.vault_id
           AND envelope.key_domain_id = version.key_domain_id
          WHERE version.vault_id = $1
            AND version.key_domain_id = $2
            AND version.state = 'active'
          GROUP BY version.id, version.generation, dedup.id
          """,
          [dump(fixture.vault_id), dump(key_domain_id)]
        )

      %{
        id: Ecto.UUID.load!(id),
        generation: generation,
        dedup_wrapper_id: Ecto.UUID.load!(dedup_id),
        envelope_count: envelope_count
      }
    end)
  end

  defp retired_generation(fixture, :vault) do
    owner_value(
      "SELECT generation FROM core.vault_key_versions WHERE vault_id = $1 AND state = 'retired'",
      [dump(fixture.vault_id)]
    )
  end

  defp retired_generation(fixture, {:domain, key_domain_id}) do
    owner_value(
      """
      SELECT generation
      FROM core.domain_key_versions
      WHERE vault_id = $1 AND key_domain_id = $2 AND state = 'retired'
      """,
      [dump(fixture.vault_id), dump(key_domain_id)]
    )
  end

  defp vault_version_count(fixture) do
    owner_value(
      "SELECT count(*) FROM core.vault_key_versions WHERE vault_id = $1",
      [dump(fixture.vault_id)]
    )
  end

  defp active_vault_algorithm(fixture) do
    owner_value(
      "SELECT algorithm FROM core.vault_key_versions WHERE vault_id = $1 AND state = 'active'",
      [dump(fixture.vault_id)]
    )
  end

  defp active_vault_wrapper_metadata(fixture) do
    Fixtures.with_owner(fn ->
      %{rows: [[generation, kdf_version, kdf_salt, kdf_parameters, wrapper_algorithm]]} =
        query!(
          MigrationRepo,
          """
          SELECT
            wrapper.generation,
            wrapper.kdf_version,
            wrapper.kdf_salt,
            wrapper.kdf_parameters,
            wrapper.wrapper_algorithm
          FROM core.vault_key_wrappers AS wrapper
          JOIN core.vault_key_versions AS version
            ON version.id = wrapper.vault_key_version_id
           AND version.vault_id = wrapper.vault_id
          WHERE version.vault_id = $1
            AND version.state = 'active'
            AND wrapper.account_id = $2
          """,
          [dump(fixture.vault_id), dump(fixture.account_id)]
        )

      %{
        generation: generation,
        kdf_version: kdf_version,
        kdf_salt: kdf_salt,
        kdf_parameters: kdf_parameters,
        wrapper_algorithm: wrapper_algorithm
      }
    end)
  end

  defp set_active_generations!(fixture, vault_generation, wrapper_generation) do
    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        """
        UPDATE core.vault_key_versions
        SET generation = $1
        WHERE vault_id = $2 AND state = 'active'
        """,
        [vault_generation, dump(fixture.vault_id)]
      )

      query!(
        MigrationRepo,
        """
        UPDATE core.vault_key_wrappers AS wrapper
        SET generation = $1
        FROM core.vault_key_versions AS version
        WHERE version.id = wrapper.vault_key_version_id
          AND version.vault_id = wrapper.vault_id
          AND version.vault_id = $2
          AND version.state = 'active'
          AND wrapper.account_id = $3
        """,
        [
          wrapper_generation,
          dump(fixture.vault_id),
          dump(fixture.account_id)
        ]
      )
    end)
  end

  defp domain_version_count(fixture, key_domain_id) do
    owner_value(
      "SELECT count(*) FROM core.domain_key_versions WHERE vault_id = $1 AND key_domain_id = $2",
      [dump(fixture.vault_id), dump(key_domain_id)]
    )
  end

  defp object_snapshot(fixture, key_domain_id) do
    Fixtures.with_owner(fn -> object_snapshot_owner(fixture, key_domain_id) end)
  end

  defp object_snapshot_owner(fixture, key_domain_id) do
    %{rows: rows} =
      query!(
        MigrationRepo,
        """
        SELECT id, lookup_digest, ciphertext_hash, storage_ref, lifecycle
        FROM content.asset_objects
        WHERE vault_id = $1 AND key_domain_id = $2
        ORDER BY id
        """,
        [dump(fixture.vault_id), dump(key_domain_id)]
      )

    rows
  end

  defp audit_operations(fixture) do
    Fixtures.with_owner(fn -> audit_operations_owner(fixture) end)
  end

  defp audit_operations_owner(fixture) do
    %{rows: rows} =
      query!(
        MigrationRepo,
        """
        SELECT operation
        FROM audit.events
        WHERE vault_id = $1
        ORDER BY inserted_at, id
        """,
        [dump(fixture.vault_id)]
      )

    Enum.map(rows, fn [operation] -> operation end)
  end

  defp owner_value(statement, parameters) do
    Fixtures.with_owner(fn ->
      %{rows: [[value]]} = query!(MigrationRepo, statement, parameters)
      value
    end)
  end

  defp add_key_material(fixture, material), do: Map.put(fixture, :key_material, material)

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
        {key, Ecto.UUID.load!(value)}

      pair ->
        pair
    end)
  end

  defp dump(<<_uuid::binary-size(16)>> = value), do: value
  defp dump(value), do: Ecto.UUID.dump!(value)
end
