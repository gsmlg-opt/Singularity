defmodule Singularity.Storage.KnowledgeFixtures do
  @moduledoc false
  import Singularity.Storage.DataCase, only: [query!: 3]
  alias Singularity.Storage.{Fixtures, MigrationRepo}

  def source! do
    %{one: source} = Fixtures.two_vaults!()
    object_id = uuid()
    domain_id = uuid()

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "INSERT INTO core.key_domains (id, vault_id, classification) VALUES ($1, $2, 'private')",
        [domain_id, source.vault_id]
      )

      query!(
        MigrationRepo,
        """
        INSERT INTO content.asset_objects (id, vault_id, key_domain_id, classification,
          lookup_digest, ciphertext_hash, plaintext_byte_size, ciphertext_byte_size,
          storage_ref, format_version, lifecycle)
        VALUES ($1, $2, $3, 'private', $4, $4, 12, 100, $5, 1, 'available')
        """,
        [
          object_id,
          source.vault_id,
          domain_id,
          :crypto.hash(:sha256, object_id),
          "knowledge-test/#{Ecto.UUID.load!(object_id)}"
        ]
      )

      query!(
        MigrationRepo,
        "UPDATE content.assets SET state = 'available', asset_object_id = $1 WHERE id = $2",
        [object_id, source.asset_id]
      )

      query!(
        MigrationRepo,
        "INSERT INTO content.resource_assets (resource_version_id, asset_id, vault_id, classification) VALUES ($1, $2, $3, 'private')",
        [source.resource_version_id, source.asset_id, source.vault_id]
      )
    end)

    Map.merge(source, %{
      object_id: object_id,
      digest: :crypto.hash(:sha256, "source bytes"),
      byte_size: 12
    })
  end

  # All IDs are Postgrex binary UUIDs, matching the established SQL fixtures.
  def document!(source, attrs \\ %{}) do
    Fixtures.with_owner(fn -> insert_document!(source, attrs) end)
  end

  def insert_document!(source, attrs \\ %{}) do
    row =
      Map.merge(
        %{
          resource_id: uuid(),
          resource_version_id: uuid(),
          vault_id: source.vault_id,
          classification: "private",
          source_asset_id: source.asset_id,
          source_resource_id: source.resource_id,
          source_resource_version_id: source.resource_version_id,
          source_object_id: source.object_id,
          source_digest: source.digest,
          source_byte_size: source.byte_size,
          media_type: "text/plain",
          title: "Document",
          created_by_principal_id: source.principal_id
        },
        attrs
      )

    query!(
      MigrationRepo,
      """
      INSERT INTO content.resources (id, vault_id, classification, kind, current_version_id, title)
      VALUES ($1, $2, $3, 'document', $4, 'Document')
      """,
      [row.resource_id, row.vault_id, row.classification, row.resource_version_id]
    )

    query!(
      MigrationRepo,
      """
      INSERT INTO content.resource_versions (id, resource_id, vault_id, classification, revision)
      VALUES ($1, $2, $3, $4, 0)
      """,
      [row.resource_version_id, row.resource_id, row.vault_id, row.classification]
    )

    insert_typed!(row)
    row
  end

  def insert_typed!(row) do
    fields =
      ~w(resource_version_id resource_id vault_id classification source_asset_id source_resource_id source_resource_version_id source_object_id source_digest source_byte_size media_type title created_by_principal_id)a

    query!(
      MigrationRepo,
      "INSERT INTO content.document_versions (#{Enum.join(fields, ", ")}, inserted_at) VALUES (#{Enum.map_join(1..length(fields), ", ", &"$#{&1}")}, CURRENT_TIMESTAMP)",
      Enum.map(fields, &Map.fetch!(row, &1))
    )
  end

  def uuid, do: Ecto.UUID.generate() |> Ecto.UUID.dump!()
end
