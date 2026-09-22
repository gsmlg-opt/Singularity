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

  def note!(source) do
    row = %{resource_id: uuid(), resource_version_id: uuid(), vault_id: source.vault_id}

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "INSERT INTO content.resources(id,vault_id,classification,kind,current_version_id,title) VALUES($1,$2,'private','note',$3,'Note')",
        [row.resource_id, row.vault_id, row.resource_version_id]
      )

      query!(
        MigrationRepo,
        "INSERT INTO content.resource_versions(id,resource_id,vault_id,classification,revision) VALUES($1,$2,$3,'private',0)",
        [row.resource_version_id, row.resource_id, row.vault_id]
      )

      query!(
        MigrationRepo,
        "INSERT INTO content.note_versions(resource_version_id,resource_id,vault_id,classification,title,markdown,created_by_principal_id,inserted_at) VALUES($1,$2,$3,'private','Note','body',$4,CURRENT_TIMESTAMP)",
        [row.resource_version_id, row.resource_id, row.vault_id, source.principal_id]
      )
    end)

    row
  end

  def ready_document!(source) do
    document = document!(source)
    locator = %{"version" => 1, "kind" => "text", "start_line" => 1, "end_line" => 1}

    {:ok, fragment} =
      Singularity.Core.DocumentFragment.new(%{
        resource_id: Ecto.UUID.load!(document.resource_id),
        resource_version_id: Ecto.UUID.load!(document.resource_version_id),
        owner_scope_id: Ecto.UUID.load!(document.vault_id),
        classification: :private,
        ordinal: 0,
        text: "text",
        locator: locator
      })

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "SELECT set_config('singularity.principal_id',$1,true),set_config('singularity.vault_id',$2,true)",
        [Ecto.UUID.load!(source.principal_id), Ecto.UUID.load!(source.vault_id)]
      )

      query!(MigrationRepo, "SELECT content.claim_document_extraction($1,0,$1,'plain',1)", [
        document.resource_version_id
      ])

      query!(MigrationRepo, "SELECT content.complete_document_extraction($1,$1,1,$2,$3,'en')", [
        document.resource_version_id,
        [
          %{
            "id" => fragment.fragment_id,
            "ordinal" => 0,
            "text" => fragment.text,
            "digest" => Base.encode16(fragment.digest, case: :lower),
            "locator" => locator
          }
        ],
        fragment.digest
      ])
    end)

    {document, fragment}
  end

  # Source preparation requires metadata and the established envelope lookup.
  # Keep source!/0 unchanged for the schema-only contracts.
  def prepared_source! do
    source = source!()

    Fixtures.with_owner(fn ->
      %{rows: [[domain_id]]} =
        query!(MigrationRepo, "SELECT key_domain_id FROM content.asset_objects WHERE id=$1", [
          source.object_id
        ])

      vault_version = uuid()
      domain_version = uuid()

      query!(
        MigrationRepo,
        "INSERT INTO core.vault_key_versions (id,vault_id,generation,state,algorithm,activated_at) VALUES ($1,$2,1,'active','aes_256_gcm',CURRENT_TIMESTAMP)",
        [vault_version, source.vault_id]
      )

      query!(
        MigrationRepo,
        "INSERT INTO core.domain_key_versions (id,vault_id,key_domain_id,vault_key_version_id,generation,state,algorithm,wrapped_key) VALUES ($1,$2,$3,$4,1,'active','aes_256_gcm',decode(repeat('01',60),'hex'))",
        [domain_version, source.vault_id, domain_id, vault_version]
      )

      query!(
        MigrationRepo,
        "INSERT INTO content.asset_key_envelopes (id,vault_id,asset_object_id,domain_key_version_id,key_domain_id,classification,algorithm,key_generation,wrapped_dek) VALUES ($1,$2,$3,$4,$5,'private','aes_256_gcm',1,decode(repeat('02',60),'hex'))",
        [uuid(), source.vault_id, source.object_id, domain_version, domain_id]
      )

      query!(
        MigrationRepo,
        "INSERT INTO content.asset_metadata (id,asset_id,resource_version_id,vault_id,classification,projection_version,original_filename,declared_media_type,detected_media_type,plaintext_byte_size,extraction_state,completed_at) VALUES ($1,$2,$3,$4,'private',1,'test.txt','text/plain','text/plain',12,'completed',CURRENT_TIMESTAMP)",
        [uuid(), source.asset_id, source.resource_version_id, source.vault_id]
      )
    end)

    Map.new(source, fn {key, value} ->
      {key,
       if(String.ends_with?(Atom.to_string(key), "_id"), do: Ecto.UUID.load!(value), else: value)}
    end)
  end

  def document_context(source) do
    %{
      repo: Singularity.Storage.RequestRepo,
      principal_id: source.principal_id,
      owner_scope_id: source.vault_id,
      fingerprint_secret: :binary.copy(<<7>>, 32),
      digest_operation: fn _, _ ->
        {:ok, %{sha256: source.digest, byte_size: source.byte_size}}
      end
    }
  end

  def document_command(source, attrs \\ %{}) do
    {:ok, pinned} =
      Singularity.Core.DocumentSource.new(%{
        asset_id: source.asset_id,
        resource_id: source.resource_id,
        resource_version_id: source.resource_version_id,
        object_id: source.object_id,
        owner_scope_id: source.vault_id,
        classification: :private,
        digest: source.digest,
        byte_size: source.byte_size,
        media_type: "text/plain"
      })

    {:ok, command} =
      Singularity.Domains.Documents.Command.new(
        Map.merge(
          %{
            mutation_id: Ecto.UUID.generate(),
            resource_id: Ecto.UUID.generate(),
            resource_version_id: Ecto.UUID.generate(),
            title: "Document",
            source: pinned,
            principal_id: source.principal_id,
            owner_scope_id: source.vault_id,
            classification: :private,
            correlation_id: Ecto.UUID.generate(),
            inserted_at: DateTime.utc_now(:microsecond)
          },
          attrs
        )
      )

    command
  end
end
