defmodule Singularity.Storage.DedupIsolationTest do
  use Singularity.Storage.DataCase, async: false

  @moduletag :integration

  import Ecto.Query

  alias Singularity.Storage.Fixtures
  alias Singularity.Storage.MigrationRepo
  alias Singularity.Storage.Schema.Content.AssetObject
  alias Singularity.Storage.ScopedRepo

  setup do
    %{one: raw_one, two: raw_two} = Fixtures.two_vaults!()

    one =
      raw_one
      |> load_ids()
      |> Map.merge(insert_key_domain!(raw_one.vault_id))

    two =
      raw_two
      |> load_ids()
      |> Map.merge(insert_key_domain!(raw_two.vault_id))

    {:ok, one: one, two: two}
  end

  test "live canonical identity remains domain scoped across rotation and vault scoped under RLS",
       %{one: one, two: two} do
    lookup_digest = :crypto.hash(:sha256, "deliberate cross-vault digest collision")

    one_object = insert_available_object!(one, lookup_digest)
    rotate_domain_key!(one)

    assert {:error, %Ecto.Changeset{} = duplicate_changeset} =
             insert_available_object(one, lookup_digest)

    assert {"has already been taken", constraint_metadata} =
             Keyword.fetch!(duplicate_changeset.errors, :vault_id)

    assert constraint_metadata[:constraint_name] == "asset_objects_live_lookup_key"

    two_object = insert_available_object!(two, lookup_digest)

    assert one_object.id != two_object.id

    scoped(one, fn repo ->
      assert [%AssetObject{id: object_id, vault_id: vault_id}] =
               repo.all(
                 from object in AssetObject,
                   where: object.lookup_digest == ^lookup_digest
               )

      assert object_id == one_object.id
      assert vault_id == one.vault_id
      assert repo.get(AssetObject, two_object.id) == nil
      :ok
    end)

    scoped(two, fn repo ->
      assert [%AssetObject{id: object_id, vault_id: vault_id}] =
               repo.all(
                 from object in AssetObject,
                   where: object.lookup_digest == ^lookup_digest
               )

      assert object_id == two_object.id
      assert vault_id == two.vault_id
      assert repo.get(AssetObject, one_object.id) == nil
      :ok
    end)

    assert RequestRepo.all(
             from object in AssetObject,
               where: object.lookup_digest == ^lookup_digest
           ) == []

    Fixtures.with_owner(fn ->
      assert %{rows: [[2, 2, 2, 2]]} =
               query!(
                 MigrationRepo,
                 """
                 SELECT
                   count(*),
                   count(DISTINCT vault_id),
                   count(DISTINCT key_domain_id),
                   (
                     SELECT count(*)
                     FROM core.domain_dedup_key_wrappers
                     WHERE vault_id = $2
                       AND key_domain_id = $3
                   )
                 FROM content.asset_objects
                 WHERE lookup_digest = $1
                   AND lifecycle = 'available'
                 """,
                 [
                   lookup_digest,
                   Ecto.UUID.dump!(one.vault_id),
                   Ecto.UUID.dump!(one.key_domain_id)
                 ]
               )
    end)
  end

  defp insert_available_object!(fixture, lookup_digest) do
    assert {:ok, %AssetObject{} = object} =
             insert_available_object(fixture, lookup_digest)

    object
  end

  defp insert_available_object(fixture, lookup_digest) do
    scoped(fixture, fn repo ->
      %AssetObject{}
      |> AssetObject.create_changeset(%{
        id: Ecto.UUID.generate(),
        vault_id: fixture.vault_id,
        key_domain_id: fixture.key_domain_id,
        classification: :private,
        lookup_digest: lookup_digest,
        ciphertext_hash: :crypto.strong_rand_bytes(32),
        plaintext_byte_size: 37,
        ciphertext_byte_size: 101,
        storage_ref: Ecto.UUID.generate(),
        format_version: 1,
        lifecycle: :available,
        lifecycle_revision: 1
      })
      |> repo.insert()
    end)
  end

  defp rotate_domain_key!(fixture) do
    next_version_id = Ecto.UUID.generate()

    Fixtures.with_owner(fn ->
      assert %{num_rows: 1} =
               query!(
                 MigrationRepo,
                 """
                 UPDATE core.domain_key_versions
                 SET state = 'retired'
                 WHERE id = $1
                   AND vault_id = $2
                   AND key_domain_id = $3
                   AND generation = 1
                   AND state = 'active'
                 """,
                 [
                   Ecto.UUID.dump!(fixture.domain_key_version_id),
                   Ecto.UUID.dump!(fixture.vault_id),
                   Ecto.UUID.dump!(fixture.key_domain_id)
                 ]
               )

      assert %{num_rows: 1} =
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
                   $1, $2, $3, $4, 2, 'active', 'aes_256_gcm', $5
                 )
                 """,
                 [
                   Ecto.UUID.dump!(next_version_id),
                   Ecto.UUID.dump!(fixture.vault_id),
                   Ecto.UUID.dump!(fixture.key_domain_id),
                   Ecto.UUID.dump!(fixture.vault_key_version_id),
                   :crypto.strong_rand_bytes(60)
                 ]
               )

      assert %{num_rows: 1} =
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
                   Ecto.UUID.dump!(Ecto.UUID.generate()),
                   Ecto.UUID.dump!(fixture.vault_id),
                   Ecto.UUID.dump!(fixture.key_domain_id),
                   Ecto.UUID.dump!(next_version_id),
                   :crypto.strong_rand_bytes(60)
                 ]
               )
    end)
  end

  defp insert_key_domain!(raw_vault_id) do
    key_domain_id = Ecto.UUID.generate()
    vault_key_version_id = Ecto.UUID.generate()
    domain_key_version_id = Ecto.UUID.generate()

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        """
        INSERT INTO core.vault_key_versions (
          id, vault_id, generation, state, algorithm, activated_at
        ) VALUES ($1, $2, 1, 'active', 'aes_256_gcm', CURRENT_TIMESTAMP)
        """,
        [Ecto.UUID.dump!(vault_key_version_id), raw_vault_id]
      )

      query!(
        MigrationRepo,
        """
        INSERT INTO core.key_domains (
          id, vault_id, classification, kind, state
        ) VALUES ($1, $2, 'private', 'content', 'active')
        """,
        [Ecto.UUID.dump!(key_domain_id), raw_vault_id]
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
        ) VALUES (
          $1, $2, $3, $4, 1, 'active', 'aes_256_gcm', $5
        )
        """,
        [
          Ecto.UUID.dump!(domain_key_version_id),
          raw_vault_id,
          Ecto.UUID.dump!(key_domain_id),
          Ecto.UUID.dump!(vault_key_version_id),
          :crypto.strong_rand_bytes(60)
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
          Ecto.UUID.dump!(Ecto.UUID.generate()),
          raw_vault_id,
          Ecto.UUID.dump!(key_domain_id),
          Ecto.UUID.dump!(domain_key_version_id),
          :crypto.strong_rand_bytes(60)
        ]
      )
    end)

    %{
      key_domain_id: key_domain_id,
      vault_key_version_id: vault_key_version_id,
      domain_key_version_id: domain_key_version_id
    }
  end

  defp scoped(fixture, callback) do
    ScopedRepo.transact(
      RequestRepo,
      %{principal_id: fixture.principal_id, vault_id: fixture.vault_id},
      callback
    )
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
        {key, Ecto.UUID.load!(value)}

      pair ->
        pair
    end)
  end
end
