defmodule Singularity.Storage.Postgres.BackupStatusStoreTest do
  use Singularity.Storage.DataCase, async: false

  @moduletag :integration

  alias Singularity.Core.Error
  alias Singularity.Storage.Fixtures
  alias Singularity.Storage.MigrationRepo
  alias Singularity.Storage.Postgres.BackupStatusStore
  alias Singularity.Storage.ScopedRepo

  @statuses [:pending, :waiting_for_backup_key, :copying, :sealed, :failed]
  @requested_at ~U[2026-08-10 09:00:00.000000Z]
  @updated_at ~U[2026-08-10 10:00:00.000000Z]

  setup do
    %{one: raw_fixture, two: raw_other} = Fixtures.two_vaults!()

    {:ok,
     fixture: load_ids(raw_fixture),
     other: load_ids(raw_other),
     raw_fixture: raw_fixture,
     raw_other: raw_other}
  end

  test "fetch returns only the redacted status fields for every persisted stable state", %{
    fixture: fixture,
    raw_fixture: raw_fixture
  } do
    for status <- @statuses do
      operation_id = Ecto.UUID.generate()
      insert_manifest!(raw_fixture, operation_id, status)

      assert {:ok, result} = fetch(fixture, operation_id)

      assert result == %{
               operation_id: operation_id,
               vault_id: fixture.vault_id,
               status: status,
               requested_at: @requested_at,
               updated_at: @updated_at
             }

      for field <- [
            :destination_ref,
            :kdf,
            :kdf_version,
            :kdf_salt,
            :kdf_parameters,
            :recovery_wrapper,
            :custody_ref,
            :manifest_hash,
            :manifest_tag,
            :snapshot_id,
            :object_inventory,
            :outbox_high_water
          ] do
        refute Map.has_key?(result, field)
      end
    end
  end

  test "fetch hides a missing operation and an operation from another vault identically", %{
    fixture: fixture,
    raw_other: raw_other
  } do
    other_operation_id = Ecto.UUID.generate()
    insert_manifest!(raw_other, other_operation_id, :sealed)

    missing = fetch(fixture, Ecto.UUID.generate())
    cross_vault = fetch(fixture, other_operation_id)

    assert missing == {:error, Error.new(:not_found)}
    assert cross_vault == missing
  end

  defp fetch(fixture, operation_id) do
    ScopedRepo.transact(
      RequestRepo,
      %{principal_id: fixture.principal_id, vault_id: fixture.vault_id},
      fn repo ->
        BackupStatusStore.fetch(repo, %{operation_id: operation_id, vault_id: fixture.vault_id})
      end
    )
  end

  defp insert_manifest!(raw_fixture, operation_id, status) do
    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        """
        INSERT INTO audit.backup_manifests (
          id, vault_id, classification, status, destination_ref,
          kdf_version, kdf_salt, kdf_parameters, recovery_wrapper, custody_ref,
          snapshot_id, outbox_high_water, manifest_hash, manifest_tag, sealed_at,
          inserted_at, updated_at
        ) VALUES (
          $1, $2, 'private', $3, $4,
          4, $5, $6::jsonb, $7, $8,
          $9, 41, $10, $11, $12,
          $13, $14
        )
        """,
        [
          dump!(operation_id),
          raw_fixture.vault_id,
          Atom.to_string(status),
          "backups/#{operation_id}",
          :binary.copy(<<0xA1>>, 16),
          ~s({"m_cost":65536,"parallelism":2,"t_cost":5,"version":4}),
          :binary.copy(<<0xA2>>, 48),
          "custody/#{operation_id}",
          dump!(Ecto.UUID.generate()),
          :binary.copy(<<0xA3>>, 32),
          :binary.copy(<<0xA4>>, 16),
          @updated_at,
          @requested_at,
          @updated_at
        ]
      )
    end)
  end

  defp load_ids(fixture) do
    Map.new(fixture, fn
      {key, value} when key in [:principal_id, :vault_id] -> {key, Ecto.UUID.load!(value)}
      pair -> pair
    end)
  end

  defp dump!(uuid), do: Ecto.UUID.dump!(uuid)
end
