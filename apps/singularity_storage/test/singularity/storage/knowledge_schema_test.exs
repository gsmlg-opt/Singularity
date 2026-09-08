defmodule Singularity.Storage.KnowledgeSchemaTest do
  use Singularity.Storage.DataCase, async: false
  @moduletag :integration
  alias Singularity.Storage.{Fixtures, KnowledgeFixtures, MigrationRepo}

  test "creation changesets expose composite identities and reject invalid link values" do
    alias Singularity.Storage.Schema.Content.{
      NoteAttachment,
      NoteCitation,
      Tag,
      ResourceTag,
      Relationship
    }

    uuid = fn -> Ecto.UUID.generate() end
    note_id = uuid.()
    note_version = uuid.()
    common = %{vault_id: uuid.(), classification: :private, inserted_at: DateTime.utc_now()}

    attachment =
      Map.merge(common, %{
        id: uuid.(),
        note_resource_id: note_id,
        note_resource_version_id: note_version,
        target_resource_id: uuid.(),
        target_resource_version_id: uuid.(),
        target_kind: :asset,
        ordinal: 0,
        role: :source
      })

    citation =
      Map.merge(common, %{
        id: uuid.(),
        note_resource_id: note_id,
        note_resource_version_id: note_version,
        source_resource_id: uuid.(),
        source_resource_version_id: uuid.(),
        fragment_id: String.duplicate("a", 64),
        locator: %{"version" => 1, "kind" => "fragment", "ordinal" => 0},
        ordinal: 0
      })

    tag =
      Map.merge(common, %{
        id: uuid.(),
        display_value: "Tag",
        normalized_key: "tag",
        created_by_principal_id: uuid.()
      })

    resource_tag = Map.merge(common, %{resource_id: note_id, tag_id: tag.id})

    relationship =
      Map.merge(common, %{
        id: uuid.(),
        source_resource_id: note_id,
        target_resource_id: uuid.(),
        type: :references,
        created_by_principal_id: uuid.()
      })

    for {module, attrs} <- [
          {NoteAttachment, attachment},
          {NoteCitation, citation},
          {Tag, tag},
          {ResourceTag, resource_tag},
          {Relationship, relationship}
        ] do
      assert module.create_changeset(struct(module), attrs).valid?
      refute module.create_changeset(struct(module), %{attrs | classification: :public}).valid?
      refute module.create_changeset(struct(module), Map.delete(attrs, :vault_id)).valid?
    end

    assert NoteAttachment.__schema__(:primary_key) == [:note_resource_version_id, :id]
    assert NoteCitation.__schema__(:primary_key) == [:note_resource_version_id, :id]

    for attrs <- [
          %{ordinal: -1},
          %{ordinal: 9_223_372_036_854_775_808},
          %{label: "bad\0label"},
          %{label: String.duplicate("é", 128)},
          %{target_resource_id: note_id},
          %{target_kind: :unknown},
          %{role: :unknown}
        ] do
      refute NoteAttachment.create_changeset(%NoteAttachment{}, Map.merge(attachment, attrs)).valid?
    end

    refute NoteCitation.create_changeset(%NoteCitation{}, %{citation | fragment_id: "invalid"}).valid?

    for attrs <- [
          %{display_value: ""},
          %{display_value: "bad\0tag"},
          %{display_value: "bad\nvalue"},
          %{normalized_key: String.duplicate("a", 1025)}
        ] do
      refute Tag.create_changeset(%Tag{}, Map.merge(tag, attrs)).valid?
    end

    refute Relationship.create_changeset(%Relationship{}, %{
             relationship
             | target_resource_id: note_id
           }).valid?
  end

  test "versioned attachments accept complete private tuples and preserve immutable source rows" do
    source = KnowledgeFixtures.source!()
    note = note!(source)
    row = attachment(note, source)
    owner(fn -> insert!("note_attachments", row) end)

    for operation <- [
          "UPDATE content.note_attachments SET label = 'changed'",
          "DELETE FROM content.note_attachments"
        ] do
      rejects(
        fn -> query!(MigrationRepo, operation <> " WHERE id = $1", [row.id]) end,
        :check_violation
      )
    end
  end

  test "attachments reject wrong Note identity, target tuple, kind, self reference, ordinal and owner" do
    source = KnowledgeFixtures.source!()
    other = KnowledgeFixtures.source!()
    note = note!(source)
    base = attachment(note, source)

    for attrs <- [
          %{note_resource_version_id: source.resource_version_id},
          %{note_resource_id: source.resource_id},
          %{target_resource_id: note.resource_id},
          %{target_kind: "note"},
          %{
            target_resource_id: note.resource_id,
            target_resource_version_id: note.resource_version_id,
            target_kind: "note"
          },
          %{ordinal: 1},
          %{ordinal: -1},
          %{vault_id: other.vault_id},
          %{
            target_resource_id: other.resource_id,
            target_resource_version_id: other.resource_version_id
          },
          %{classification: "public"},
          %{label: String.duplicate("é", 128)}
        ] do
      rejects(fn -> insert!("note_attachments", Map.merge(base, attrs)) end)
    end

    owner(fn -> insert!("note_attachments", base) end)

    rejects(
      fn -> insert!("note_attachments", %{base | id: KnowledgeFixtures.uuid()}) end,
      :unique_violation
    )

    rejects(
      fn -> insert!("note_attachments", %{base | id: KnowledgeFixtures.uuid(), ordinal: 1}) end,
      :unique_violation
    )
  end

  test "pending Documents and unavailable Assets cannot become attachment sources" do
    source = KnowledgeFixtures.source!()
    note = note!(source)
    document = KnowledgeFixtures.document!(source)
    row = attachment(note, source)

    rejects(fn ->
      insert!("note_attachments", %{
        row
        | target_resource_id: document.resource_id,
          target_resource_version_id: document.resource_version_id,
          target_kind: "document"
      })
    end)

    owner(fn ->
      query!(MigrationRepo, "UPDATE content.assets SET state = 'uploaded' WHERE id = $1", [
        source.asset_id
      ])
    end)

    rejects(fn -> insert!("note_attachments", row) end)
  end

  test "citations pin exact ready fragments with version-local citation identity" do
    source = KnowledgeFixtures.source!()
    note = note!(source)
    {document, fragment} = ready_document!(source)
    row = citation(note, document, fragment)
    owner(fn -> insert!("note_citations", row) end)
    rejects(fn -> insert!("note_citations", %{row | ordinal: 1}) end, :unique_violation)
    owner(fn -> insert!("note_citations", %{row | id: KnowledgeFixtures.uuid(), ordinal: 1}) end)
    second = next_note_version!(note, source)

    owner(fn ->
      insert!("note_citations", %{
        row
        | note_resource_id: second.resource_id,
          note_resource_version_id: second.resource_version_id
      })
    end)

    for operation <- [
          "UPDATE content.note_citations SET ordinal = ordinal",
          "DELETE FROM content.note_citations"
        ] do
      rejects(
        fn -> query!(MigrationRepo, operation <> " WHERE id = $1", [row.id]) end,
        :check_violation
      )
    end
  end

  test "citations reject mismatched source tuples, locators, Note versions and ordinal gaps" do
    source = KnowledgeFixtures.source!()
    note = note!(source)
    {document, fragment} = ready_document!(source)
    row = citation(note, document, fragment)

    for attrs <- [
          %{note_resource_version_id: document.resource_version_id},
          %{source_resource_id: source.resource_id},
          %{source_resource_version_id: source.resource_version_id},
          %{fragment_id: String.duplicate("a", 64)},
          %{locator: %{"version" => 1, "kind" => "text", "start_line" => 2, "end_line" => 2}},
          %{ordinal: 1},
          %{vault_id: KnowledgeFixtures.uuid()}
        ] do
      rejects(fn -> insert!("note_citations", Map.merge(row, attrs)) end)
    end
  end

  test "complete source ordering is checked at commit and accepts reverse insertion order" do
    source = KnowledgeFixtures.source!()
    note = note!(source)
    {document, fragment} = ready_document!(source)
    first = attachment(note, source)

    second = %{
      first
      | id: KnowledgeFixtures.uuid(),
        ordinal: 1,
        target_resource_id: document.resource_id,
        target_resource_version_id: document.resource_version_id,
        target_kind: "document"
    }

    cite = citation(note, document, fragment)

    owner(fn ->
      insert!("note_attachments", second)
      insert!("note_attachments", first)
      insert!("note_citations", %{cite | id: KnowledgeFixtures.uuid(), ordinal: 1})
      insert!("note_citations", cite)
    end)

    for table <- ~w(note_attachments note_citations) do
      owner(fn ->
        assert %{rows: [[0], [1]]} =
                 query!(
                   MigrationRepo,
                   "SELECT ordinal FROM content.#{table} WHERE note_resource_version_id=$1 ORDER BY ordinal",
                   [note.resource_version_id]
                 )
      end)
    end
  end

  test "tombstoning keeps source links and organization rows and no new foreign key cascades" do
    source = KnowledgeFixtures.source!()
    note = note!(source)
    {document, fragment} = ready_document!(source)
    tag = tag(source)

    owner(fn ->
      insert!("tags", tag)
      insert!("note_attachments", attachment(note, source))
      insert!("note_citations", citation(note, document, fragment))

      insert!("resource_tags", %{
        resource_id: note.resource_id,
        tag_id: tag.id,
        vault_id: source.vault_id,
        classification: "private"
      })

      insert!("relationships", %{
        id: KnowledgeFixtures.uuid(),
        vault_id: source.vault_id,
        classification: "private",
        source_resource_id: note.resource_id,
        target_resource_id: source.resource_id,
        type: "references",
        created_by_principal_id: source.principal_id
      })
    end)

    owner(fn ->
      query!(
        MigrationRepo,
        "UPDATE content.resources SET deleted_at=CURRENT_TIMESTAMP WHERE id IN ($1,$2,$3)",
        [note.resource_id, source.resource_id, document.resource_id]
      )
    end)

    owner(fn ->
      for table <- ~w(note_attachments note_citations tags resource_tags relationships) do
        assert %{rows: [[1]]} =
                 query!(
                   MigrationRepo,
                   "SELECT count(*) FROM content.#{table} WHERE vault_id=$1",
                   [source.vault_id]
                 )

        assert %{rows: [[0]]} =
                 query!(
                   MigrationRepo,
                   "SELECT count(*) FROM pg_constraint WHERE conrelid=to_regclass($1) AND contype='f' AND confdeltype='c'",
                   ["content.#{table}"]
                 )
      end
    end)

    rejects(fn ->
      insert!("note_attachments", %{
        attachment(note, source)
        | ordinal: 1,
          target_resource_id: document.resource_id,
          target_resource_version_id: document.resource_version_id,
          target_kind: "document"
      })
    end)
  end

  test "tags use exact owner keys and reject empty, control, oversized or public values" do
    source = KnowledgeFixtures.source!()
    tag = tag(source)
    owner(fn -> insert!("tags", tag) end)
    rejects(fn -> insert!("tags", %{tag | id: KnowledgeFixtures.uuid()}) end, :unique_violation)

    for attrs <- [
          %{display_value: ""},
          %{display_value: "bad\nvalue"},
          %{display_value: String.duplicate("é", 128)},
          %{normalized_key: ""},
          %{normalized_key: String.duplicate("a", 1025)},
          %{classification: "public"}
        ] do
      rejects(fn -> insert!("tags", Map.merge(%{tag | id: KnowledgeFixtures.uuid()}, attrs)) end)
    end

    other = KnowledgeFixtures.source!()
    owner(fn -> insert!("tags", %{tag(other) | normalized_key: tag.normalized_key}) end)
  end

  test "resource tags and relationships retain same-owner typed resource identity" do
    source = KnowledgeFixtures.source!()
    other = KnowledgeFixtures.source!()
    note = note!(source)
    tag = tag(source)
    owner(fn -> insert!("tags", tag) end)

    edge = %{
      resource_id: note.resource_id,
      tag_id: tag.id,
      vault_id: source.vault_id,
      classification: "private"
    }

    owner(fn -> insert!("resource_tags", edge) end)
    rejects(fn -> insert!("resource_tags", %{edge | resource_id: other.resource_id}) end)

    rel = %{
      id: KnowledgeFixtures.uuid(),
      vault_id: source.vault_id,
      classification: "private",
      source_resource_id: note.resource_id,
      target_resource_id: source.resource_id,
      target_resource_version_id: source.resource_version_id,
      type: "references",
      created_by_principal_id: source.principal_id
    }

    owner(fn -> insert!("relationships", rel) end)

    rejects(
      fn -> insert!("relationships", %{rel | id: KnowledgeFixtures.uuid()}) end,
      :unique_violation
    )

    for attrs <- [
          %{target_resource_id: note.resource_id},
          %{target_resource_version_id: note.resource_version_id},
          %{target_resource_id: other.resource_id, target_resource_version_id: nil},
          %{type: "unknown"},
          %{classification: "public"}
        ] do
      rejects(fn ->
        insert!("relationships", Map.merge(%{rel | id: KnowledgeFixtures.uuid()}, attrs))
      end)
    end

    owner(fn ->
      insert!("relationships", %{
        rel
        | id: KnowledgeFixtures.uuid(),
          type: "related_to",
          target_resource_version_id: nil
      })
    end)
  end

  defp owner(fun), do: Fixtures.with_owner(fun)

  defp rejects(fun, code \\ nil) do
    error = assert_raise Postgrex.Error, fn -> owner(fun) end
    assert error.postgres.code in [:check_violation, :foreign_key_violation, :unique_violation]
    if code, do: assert(error.postgres.code == code)
  end

  defp insert!(table, attrs) do
    {fields, values} = attrs |> Enum.sort() |> Enum.unzip()

    query!(
      MigrationRepo,
      "INSERT INTO content.#{table} (#{Enum.join(fields, ",")},inserted_at) VALUES (#{Enum.map_join(1..length(fields), ",", &"$#{&1}")},CURRENT_TIMESTAMP)",
      values
    )
  end

  defp note!(source) do
    row = %{
      resource_id: KnowledgeFixtures.uuid(),
      resource_version_id: KnowledgeFixtures.uuid(),
      vault_id: source.vault_id
    }

    owner(fn ->
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

  defp next_note_version!(note, source) do
    row = %{note | resource_version_id: KnowledgeFixtures.uuid()}

    owner(fn ->
      query!(
        MigrationRepo,
        "INSERT INTO content.resource_versions(id,resource_id,vault_id,classification,revision) VALUES($1,$2,$3,'private',1)",
        [row.resource_version_id, row.resource_id, row.vault_id]
      )

      query!(
        MigrationRepo,
        "INSERT INTO content.note_versions(resource_version_id,resource_id,vault_id,classification,title,markdown,created_by_principal_id,parent_version_id,inserted_at) VALUES($1,$2,$3,'private','Note','body',$4,$5,CURRENT_TIMESTAMP)",
        [
          row.resource_version_id,
          row.resource_id,
          row.vault_id,
          source.principal_id,
          note.resource_version_id
        ]
      )
    end)

    row
  end

  defp attachment(note, source),
    do: %{
      id: KnowledgeFixtures.uuid(),
      note_resource_id: note.resource_id,
      note_resource_version_id: note.resource_version_id,
      vault_id: note.vault_id,
      classification: "private",
      target_resource_id: source.resource_id,
      target_resource_version_id: source.resource_version_id,
      target_kind: "asset",
      ordinal: 0,
      role: "source",
      label: nil
    }

  defp citation(note, document, fragment),
    do: %{
      id: KnowledgeFixtures.uuid(),
      note_resource_id: note.resource_id,
      note_resource_version_id: note.resource_version_id,
      vault_id: note.vault_id,
      classification: "private",
      source_resource_id: document.resource_id,
      source_resource_version_id: document.resource_version_id,
      fragment_id: fragment["id"],
      locator: fragment["locator"],
      ordinal: 0
    }

  defp tag(source),
    do: %{
      id: KnowledgeFixtures.uuid(),
      vault_id: source.vault_id,
      classification: "private",
      display_value: "Tag",
      normalized_key: "tag",
      created_by_principal_id: source.principal_id
    }

  defp ready_document!(source) do
    document = KnowledgeFixtures.document!(source)
    locator = %{"version" => 1, "kind" => "text", "start_line" => 1, "end_line" => 1}
    digest = :crypto.hash(:sha256, "text")

    fragment = %{
      "id" =>
        Singularity.Core.DocumentFragment.id(
          Ecto.UUID.load!(document.resource_version_id),
          locator,
          0,
          digest
        ),
      "ordinal" => 0,
      "text" => "text",
      "digest" => Base.encode16(digest, case: :lower),
      "locator" => locator
    }

    owner(fn ->
      query!(
        MigrationRepo,
        "SELECT set_config('singularity.principal_id',$1,true),set_config('singularity.vault_id',$2,true)",
        [Ecto.UUID.load!(source.principal_id), Ecto.UUID.load!(source.vault_id)]
      )

      query!(MigrationRepo, "SELECT content.claim_document_extraction($1,0,'plain',1)", [
        document.resource_version_id
      ])

      query!(MigrationRepo, "SELECT content.complete_document_extraction($1,1,$2,$3,'en')", [
        document.resource_version_id,
        [fragment],
        digest
      ])
    end)

    {document, fragment}
  end
end
