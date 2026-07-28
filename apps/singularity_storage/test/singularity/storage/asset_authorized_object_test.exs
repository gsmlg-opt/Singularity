defmodule Singularity.Storage.AssetAuthorizedObjectTest do
  use Singularity.Storage.DataCase, async: false

  @moduletag :integration

  alias Singularity.Core.Error
  alias Singularity.Storage.Fixtures
  alias Singularity.Storage.MigrationRepo
  alias Singularity.Storage.Postgres.AssetRepository
  alias Singularity.Storage.RequestRepo
  alias Singularity.Storage.ScopedRepo

  setup do
    %{one: raw_fixture, two: raw_other} = Fixtures.two_vaults!()
    fixture = load_ids(raw_fixture)
    other = load_ids(raw_other)
    object = insert_available_object!(raw_fixture)

    {:ok, fixture: fixture, object: object, other: other}
  end

  test "returns only the exact available object and active wrapper generation", %{
    fixture: fixture,
    object: object
  } do
    assert {:ok,
            %{
              asset_id: asset_id,
              vault_id: vault_id,
              classification: :private,
              object_id: object_id,
              object_generation: 3
            } = binding} =
             scoped(fixture, fn repo ->
               AssetRepository.authorized_object(repo, fixture.asset_id)
             end)

    assert asset_id == fixture.asset_id
    assert vault_id == fixture.vault_id
    assert object_id == object.object_id

    assert Map.keys(binding) |> Enum.sort() ==
             [:asset_id, :classification, :object_generation, :object_id, :vault_id]
  end

  test "returns a completed download descriptor without custody fields", %{
    fixture: fixture
  } do
    assert {:ok,
            %{
              asset_id: asset_id,
              vault_id: vault_id,
              classification: :private,
              plaintext_byte_size: 12,
              detected_media_type: "application/pdf"
            } = descriptor} =
             scoped(fixture, fn repo ->
               AssetRepository.authorized_download_descriptor(repo, fixture.asset_id)
             end)

    assert asset_id == fixture.asset_id
    assert vault_id == fixture.vault_id

    assert Map.keys(descriptor) |> Enum.sort() ==
             [
               :asset_id,
               :classification,
               :detected_media_type,
               :plaintext_byte_size,
               :vault_id
             ]
  end

  test "uses an application/octet-stream fallback when metadata is absent", %{
    fixture: fixture
  } do
    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "DELETE FROM content.asset_metadata WHERE asset_id = $1",
        [Ecto.UUID.dump!(fixture.asset_id)]
      )
    end)

    assert {:ok, %{asset_id: asset_id}} =
             scoped(fixture, fn repo ->
               AssetRepository.authorized_object(repo, fixture.asset_id)
             end)

    assert asset_id == fixture.asset_id

    assert {:ok,
            %{
              asset_id: descriptor_asset_id,
              vault_id: vault_id,
              classification: :private,
              plaintext_byte_size: 12,
              detected_media_type: "application/octet-stream"
            } = descriptor} =
             scoped(fixture, fn repo ->
               AssetRepository.authorized_download_descriptor(repo, fixture.asset_id)
             end)

    assert descriptor_asset_id == fixture.asset_id
    assert vault_id == fixture.vault_id
    assert map_size(descriptor) == 5
  end

  test "inconsistent metadata receives no download descriptor", %{
    fixture: fixture
  } do
    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        """
        UPDATE content.asset_metadata
        SET plaintext_byte_size = plaintext_byte_size + 1
        WHERE asset_id = $1
        """,
        [Ecto.UUID.dump!(fixture.asset_id)]
      )
    end)

    assert {:error, %Error{code: :not_found}} =
             scoped(fixture, fn repo ->
               AssetRepository.authorized_download_descriptor(repo, fixture.asset_id)
             end)
  end

  test "unsafe detected metadata receives no download descriptor", %{
    fixture: fixture
  } do
    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        """
        UPDATE content.asset_metadata
        SET detected_media_type = E'application/pdf\\nX-Unsafe: yes'
        WHERE asset_id = $1
        """,
        [Ecto.UUID.dump!(fixture.asset_id)]
      )
    end)

    assert {:error, %Error{code: :not_found}} =
             scoped(fixture, fn repo ->
               AssetRepository.authorized_download_descriptor(repo, fixture.asset_id)
             end)
  end

  test "consistently bound pending metadata uses the safe fallback", %{
    fixture: fixture
  } do
    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        """
        UPDATE content.asset_metadata
        SET extraction_state = 'pending', detected_media_type = NULL, completed_at = NULL
        WHERE asset_id = $1
        """,
        [Ecto.UUID.dump!(fixture.asset_id)]
      )
    end)

    assert {:ok,
            %{
              asset_id: asset_id,
              vault_id: vault_id,
              classification: :private,
              plaintext_byte_size: 12,
              detected_media_type: "application/octet-stream"
            } = descriptor} =
             scoped(fixture, fn repo ->
               AssetRepository.authorized_download_descriptor(repo, fixture.asset_id)
             end)

    assert asset_id == fixture.asset_id
    assert vault_id == fixture.vault_id
    assert map_size(descriptor) == 5
  end

  test "other vaults and non-downloadable states receive no object binding", %{
    fixture: fixture,
    other: other
  } do
    assert {:error, %Error{code: :not_found}} =
             scoped(other, fn repo ->
               AssetRepository.authorized_object(repo, fixture.asset_id)
             end)

    assert {:error, %Error{code: :not_found}} =
             scoped(other, fn repo ->
               AssetRepository.authorized_download_descriptor(repo, fixture.asset_id)
             end)

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        """
        UPDATE content.assets
        SET state = 'pending_delete', state_revision = 4
        WHERE id = $1
        """,
        [Ecto.UUID.dump!(fixture.asset_id)]
      )
    end)

    assert {:error, %Error{code: :not_found}} =
             scoped(fixture, fn repo ->
               AssetRepository.authorized_object(repo, fixture.asset_id)
             end)

    assert {:error, %Error{code: :not_found}} =
             scoped(fixture, fn repo ->
               AssetRepository.authorized_download_descriptor(repo, fixture.asset_id)
             end)
  end

  test "download descriptors accept existing canonical object states", %{
    fixture: fixture
  } do
    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        """
        UPDATE content.asset_metadata
        SET extraction_state = 'pending', detected_media_type = NULL, completed_at = NULL
        WHERE asset_id = $1
        """,
        [Ecto.UUID.dump!(fixture.asset_id)]
      )
    end)

    for {state, revision} <- [{"processing", 4}, {"ready", 5}] do
      Fixtures.with_owner(fn ->
        query!(
          MigrationRepo,
          """
          UPDATE content.assets
          SET state = $2, state_revision = $3
          WHERE id = $1
          """,
          [Ecto.UUID.dump!(fixture.asset_id), state, revision]
        )
      end)

      assert {:ok, %{asset_id: asset_id}} =
               scoped(fixture, fn repo ->
                 AssetRepository.authorized_object(repo, fixture.asset_id)
               end)

      assert asset_id == fixture.asset_id

      assert {:ok,
              %{
                asset_id: ^asset_id,
                detected_media_type: "application/octet-stream",
                plaintext_byte_size: 12
              }} =
               scoped(fixture, fn repo ->
                 AssetRepository.authorized_download_descriptor(repo, fixture.asset_id)
               end)
    end
  end

  defp insert_available_object!(raw_fixture) do
    vault_key_version_id = Ecto.UUID.generate()
    key_domain_id = Ecto.UUID.generate()
    domain_key_version_id = Ecto.UUID.generate()
    object_id = Ecto.UUID.generate()

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        """
        INSERT INTO core.vault_key_versions (
          id, vault_id, generation, state, algorithm, activated_at
        ) VALUES ($1, $2, 1, 'active', 'aes_256_gcm', CURRENT_TIMESTAMP)
        """,
        [Ecto.UUID.dump!(vault_key_version_id), raw_fixture.vault_id]
      )

      query!(
        MigrationRepo,
        """
        INSERT INTO core.key_domains (
          id, vault_id, classification, kind, state
        ) VALUES ($1, $2, 'private', 'content', 'active')
        """,
        [Ecto.UUID.dump!(key_domain_id), raw_fixture.vault_id]
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
          $1, $2, $3, $4, 3, 'active', 'aes_256_gcm', $5
        )
        """,
        [
          Ecto.UUID.dump!(domain_key_version_id),
          raw_fixture.vault_id,
          Ecto.UUID.dump!(key_domain_id),
          Ecto.UUID.dump!(vault_key_version_id),
          :crypto.strong_rand_bytes(60)
        ]
      )

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
          lifecycle_revision
        ) VALUES (
          $1, $2, $3, 'private', $4, $5, 12, 170, $6, 1,
          'available', 1
        )
        """,
        [
          Ecto.UUID.dump!(object_id),
          raw_fixture.vault_id,
          Ecto.UUID.dump!(key_domain_id),
          :binary.copy(<<0xA1>>, 32),
          :binary.copy(<<0xB2>>, 32),
          object_id
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
        ) VALUES (
          $1, $2, $3, $4, $5, 'private', 'aes_256_gcm', 3, $6
        )
        """,
        [
          Ecto.UUID.dump!(Ecto.UUID.generate()),
          raw_fixture.vault_id,
          Ecto.UUID.dump!(object_id),
          Ecto.UUID.dump!(domain_key_version_id),
          Ecto.UUID.dump!(key_domain_id),
          :crypto.strong_rand_bytes(60)
        ]
      )

      query!(
        MigrationRepo,
        """
        UPDATE content.assets
        SET
          state = 'available',
          state_revision = 3,
          asset_object_id = $2
        WHERE id = $1
        """,
        [raw_fixture.asset_id, Ecto.UUID.dump!(object_id)]
      )

      query!(
        MigrationRepo,
        """
        INSERT INTO content.asset_metadata (
          id,
          asset_id,
          resource_version_id,
          vault_id,
          classification,
          projection_version,
          original_filename,
          declared_media_type,
          detected_media_type,
          plaintext_byte_size,
          extraction_state,
          completed_at
        ) VALUES (
          $1, $2, $3, $4, 'private', 1, 'evidence.pdf',
          'application/octet-stream', 'application/pdf', 12, 'completed',
          CURRENT_TIMESTAMP
        )
        """,
        [
          Ecto.UUID.dump!(Ecto.UUID.generate()),
          raw_fixture.asset_id,
          raw_fixture.resource_version_id,
          raw_fixture.vault_id
        ]
      )
    end)

    %{
      domain_key_version_id: domain_key_version_id,
      key_domain_id: key_domain_id,
      object_id: object_id
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
