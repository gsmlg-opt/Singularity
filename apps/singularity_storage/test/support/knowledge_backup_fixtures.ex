defmodule Singularity.Storage.Backup.KnowledgeBackupFixtures do
  @moduledoc false

  alias __MODULE__.FixtureCrypto
  alias Singularity.Core.DocumentFragment
  alias Singularity.Storage.MigrationRepo
  alias Singularity.Storage.Backup.KnowledgeFixtureResourceOwner

  alias Singularity.Storage.Backup.{
    BundleReader,
    LocalDestination,
    LogicalBundleVerifier,
    LogicalRecordCodec,
    LogicalSchemaV2,
    LogicalSchemaV3,
    Manifest
  }

  alias Singularity.Storage.Crypto.{ChunkedAEAD, Format, KeyWrapper, ObjectIdentity}
  alias Singularity.Storage.Local.PathGuard

  @time ~U[2026-10-11 00:00:00.000000Z]
  @replays {__MODULE__, :replays}
  # This projection is intentionally independent of the new V3 registry.
  @appended [
    {"content.document_versions",
     ~w(resource_version_id resource_id vault_id classification source_asset_id source_resource_id source_resource_version_id source_object_id source_digest source_byte_size media_type title created_by_principal_id state attempt_generation extraction_adapter extraction_format extracted_text_digest detected_language failure_code attempt_finished_at inserted_at attempt_job_id attempt_started_at attempt_deadline_at),
     ~w(resource_version_id)},
    {"content.document_fragments",
     ~w(id resource_id resource_version_id vault_id classification ordinal text digest locator inserted_at),
     ~w(id)},
    {"content.document_import_receipts",
     ~w(vault_id principal_id mutation_id request_fingerprint state resource_id version_id inserted_at),
     ~w(vault_id principal_id mutation_id)},
    {"content.note_attachments",
     ~w(note_resource_version_id id note_resource_id vault_id classification target_resource_id target_resource_version_id target_kind ordinal role label inserted_at),
     ~w(note_resource_version_id id)},
    {"content.note_citations",
     ~w(note_resource_version_id id note_resource_id vault_id classification source_resource_id source_resource_version_id fragment_id locator ordinal inserted_at),
     ~w(note_resource_version_id id)},
    {"content.tags",
     ~w(id vault_id classification display_value normalized_key created_by_principal_id inserted_at),
     ~w(id)},
    {"content.resource_tags", ~w(resource_id tag_id vault_id classification inserted_at),
     ~w(resource_id tag_id vault_id)},
    {"content.relationships",
     ~w(id vault_id classification source_resource_id target_resource_id target_resource_version_id type created_by_principal_id inserted_at),
     ~w(id)}
  ]

  def with_destination(:current, fun) when is_function(fun, 1) do
    previous_replays = Process.get(@replays)
    Process.put(@replays, [])

    try do
      {owner, destination} = KnowledgeFixtureResourceOwner.open()

      try do
        fun.(destination)
      after
        try do
          Enum.each(Process.get(@replays, []), &BundleReader.discard_verified/1)
        after
          KnowledgeFixtureResourceOwner.close(owner)
        end
      end
    after
      if is_nil(previous_replays),
        do: Process.delete(@replays),
        else: Process.put(@replays, previous_replays)
    end
  end

  def seed!(
        %{repo: MigrationRepo, database: _, object_root: _, ids: ids, originals: originals} =
          input
      ) do
    destination = Map.drop(input, [:ids, :originals])
    owner = Map.take(ids, [:account_id, :principal_id, :vault_id, :session_id])

    keys =
      ObjectIdentity.generate_hierarchy() |> Map.put(:password_key, :crypto.strong_rand_bytes(32))

    sources =
      owner_query(fn ->
        seed_owner(owner, keys)
        sources = seed_sources(destination, owner, ids, originals, keys)
        fragments = seed_documents(owner, ids, sources)
        seed_notes(owner, ids, sources, fragments)
        seed_organization(owner, ids)
        seed_work(owner, ids)
        sources
      end)

    # Source validation and sealing have committed while all targets were live.
    owner_query(fn ->
      for name <- [:pdf, :pdf_duplicate] do
        source = Map.fetch!(sources, name)

        query(
          "UPDATE content.resource_assets SET released_at=$1 WHERE resource_version_id=$2 AND asset_id=$3",
          [@time, dump(source.resource_version_id), dump(source.asset_id)]
        )

        query("UPDATE content.assets SET state='deleted',asset_object_id=NULL WHERE id=$1", [
          dump(source.asset_id)
        ])

        query("UPDATE content.resources SET deleted_at=$1 WHERE id=$2", [
          @time,
          dump(source.resource_id)
        ])
      end

      for resource <- [ids.deleted_note_id, ids.deleted_document_id] do
        query("UPDATE content.resources SET deleted_at=$1 WHERE id=$2", [@time, dump(resource)])
      end

      for resource <- [ids.live_note_id, ids.ready_document_id] do
        query("SELECT content.reconcile_search_resource_internal($1,$2)", [
          dump(owner.vault_id),
          dump(resource)
        ])
      end
    end)

    %{
      destination: destination,
      ids: ids,
      owner: owner,
      sources: sources,
      originals: originals,
      keys: keys
    }
  end

  def seed_graph!(%{owner: owner, ids: ids, sources: sources, work: work} = input) do
    true =
      Enum.sort(Map.keys(sources)) ==
        Enum.sort([:pdf, :pdf_duplicate, :empty, :plain, :unicode, :markdown])

    true =
      Enum.all?(sources, fn {_name, source} ->
        Enum.all?(
          [:resource_id, :resource_version_id, :asset_id, :object_id, :digest, :byte_size],
          &Map.has_key?(source, &1)
        )
      end)

    owner_query(fn ->
      fragments = seed_documents(owner, ids, sources)
      seed_notes(owner, ids, sources, fragments)
      seed_organization(owner, ids)
      seed_work(owner, ids, work)
    end)

    Map.take(input, [:owner, :ids, :sources, :work])
  end

  def canonical_rows(fixture), do: select_rows(fixture.owner, prefix_projection() ++ @appended)

  def source_bytes(fixture) do
    Map.new(fixture.sources, fn {name, source} ->
      {source.object_id, Map.fetch!(fixture.originals, name)}
    end)
  end

  # Transform only disposable wire input. Capture ciphertext using the unmodified
  # canonical metadata before a test changes an owner, digest or storage path.
  def transformed_bundle(fixture, options) when is_list(options) do
    original_rows = canonical_rows(fixture)
    originals = object_payloads(fixture, original_rows["content.asset_objects"])
    rows = Keyword.get(options, :rows, &Function.identity/1).(original_rows)
    build_bundle(fixture, rows, 3, Keyword.get(options, :mode, :replay), options, originals)
  end

  def search_rows(fixture) do
    owner_query(fn ->
      %{
        "content.search_entries" =>
          query(
            "SELECT entry_id,resource_id::text,resource_version_id::text,kind,fragment_id,ordinal,title,body,locator FROM content.search_entries WHERE vault_id=$1 ORDER BY entry_id",
            [dump(fixture.owner.vault_id)]
          )
          |> row_maps()
      }
    end)
  end

  def verified_bundle(:legacy_v2, logical_version: 2, mode: :records) do
    with_destination(:current, fn destination ->
      owner = %{account_id: id(1), principal_id: id(2), vault_id: id(3), session_id: id(4)}

      keys =
        ObjectIdentity.generate_hierarchy()
        |> Map.put(:password_key, :crypto.strong_rand_bytes(32))

      owner_query(fn ->
        seed_owner(owner, keys)
        resource(owner, id(10), "note", id(11), "Legacy Note")
        note_version(owner, id(10), id(11), 0, nil, nil, "Legacy Note", "# Legacy V2\n")
        query("SELECT content.finalize_note_source_set($1)", [dump(id(11))])
      end)

      fixture = %{destination: destination, owner: owner}
      bundle(fixture, select_rows(owner, prefix_projection()), 2, :records)
    end)
  end

  def verified_bundle(fixture, logical_version: 3, mode: mode) when mode in [:records, :replay],
    do: bundle(fixture, canonical_rows(fixture), 3, mode)

  def malformed_bundle(fixture, %{
        table: table,
        primary_key: key,
        field: field,
        value: value,
        mode: mode
      }) do
    rows = canonical_rows(fixture)
    {:ok, schema} = LogicalSchemaV3.fetch_table(table)
    [%{position: position}] = schema.primary_key
    key_name = Enum.fetch!(schema.columns, position).name
    true = Enum.any?(schema.columns, &(&1.name == field))
    true = Enum.count(Map.fetch!(rows, table), &(&1[key_name] == key)) == 1

    changed =
      Map.update!(
        rows,
        table,
        &Enum.map(&1, fn row ->
          if row[key_name] == key, do: Map.replace!(row, field, value), else: row
        end)
      )

    bundle(fixture, changed, 3, mode)
  end

  defp seed_owner(owner, keys) do
    insert("identity.people", id: id(101), display_name: "Knowledge backup fixture")
    insert("identity.accounts", id: owner.account_id, person_id: id(101))

    insert("identity.credentials",
      id: id(102),
      account_id: owner.account_id,
      normalized_login: "knowledge-fixture@example.test",
      verifier: "fixture-verifier"
    )

    insert("identity.principals",
      id: owner.principal_id,
      account_id: owner.account_id,
      kind: "owner"
    )

    insert("identity.principals",
      id: id(103),
      account_id: owner.account_id,
      kind: "system",
      metadata: %{"name" => "object_cleanup"}
    )

    insert("core.vaults", id: owner.vault_id)

    for principal <- [owner.principal_id, id(103)],
        do:
          insert("core.vault_members",
            principal_id: principal,
            vault_id: owner.vault_id,
            clearance: "restricted"
          )

    query("UPDATE core.vaults SET object_cleanup_principal_id=$1 WHERE id=$2", [
      dump(id(103)),
      dump(owner.vault_id)
    ])

    for {name, principal, capability} <- [
          {"object.cleanup", id(103), id(104)},
          {"asset.read", owner.principal_id, id(105)}
        ] do
      query("INSERT INTO core.capabilities(id,name) VALUES($1,$2) ON CONFLICT(name) DO NOTHING", [
        dump(capability),
        name
      ])

      query(
        "INSERT INTO core.principal_capabilities(principal_id,vault_id,capability_id) SELECT $1,$2,id FROM core.capabilities WHERE name=$3",
        [dump(principal), dump(owner.vault_id), name]
      )
    end

    insert("core.key_domains", id: id(106), vault_id: owner.vault_id, classification: "private")

    insert("core.vault_key_versions",
      id: id(107),
      vault_id: owner.vault_id,
      generation: 1,
      state: "active",
      algorithm: "aes_256_gcm",
      activated_at: @time
    )

    insert("core.vault_key_wrappers",
      id: id(108),
      vault_id: owner.vault_id,
      vault_key_version_id: id(107),
      account_id: owner.account_id,
      generation: 1,
      kdf_version: 1,
      kdf_salt: <<1::128>>,
      kdf_parameters: %{"t_cost" => 1, "m_cost" => 8192, "parallelism" => 1},
      wrapper_algorithm: "aes_256_gcm",
      wrapped_key: wrap(keys.password_key, keys.vault_key, :vault_key, owner.vault_id)
    )

    insert("core.domain_key_versions",
      id: id(109),
      vault_id: owner.vault_id,
      key_domain_id: id(106),
      vault_key_version_id: id(107),
      generation: 1,
      state: "active",
      algorithm: "aes_256_gcm",
      wrapped_key:
        wrap(keys.vault_key, keys.domain_key, :domain_key, owner.vault_id <> ":" <> id(106))
    )

    insert("core.domain_dedup_key_wrappers",
      id: id(110),
      vault_id: owner.vault_id,
      key_domain_id: id(106),
      domain_key_version_id: id(109),
      algorithm: "aes_256_gcm",
      wrapped_key: wrap(keys.domain_key, keys.domain_dedup_key, :domain_dedup_key, id(106))
    )

    insert("identity.sessions",
      id: owner.session_id,
      account_id: owner.account_id,
      credential_id: id(102),
      principal_id: owner.principal_id,
      vault_id: owner.vault_id,
      token_digest: :crypto.hash(:sha256, "fixture-session"),
      expires_at: DateTime.add(@time, 86_400)
    )
  end

  defp seed_sources(destination, owner, ids, originals, keys) do
    bindings = [
      pdf: ids.pdf_object_id,
      pdf_duplicate: ids.pdf_object_id,
      empty: ids.empty_object_id,
      plain: ids.plain_object_id,
      unicode: ids.unicode_object_id,
      markdown: ids.markdown_object_id
    ]

    Enum.reduce(Enum.with_index(bindings), %{}, fn {{name, object}, index}, sources ->
      bytes = Map.fetch!(originals, name)
      digest = :crypto.hash(:sha256, bytes)
      {:ok, lookup} = ObjectIdentity.lookup_digest(keys.domain_dedup_key, digest)

      {:ok, object_path} =
        PathGuard.object_path(
          destination.object_root,
          owner.vault_id,
          id(106),
          Base.encode16(lookup, case: :lower)
        )

      unless Enum.any?(sources, fn {_name, source} -> source.object_id == object end) do
        {:ok, ciphertext} =
          ChunkedAEAD.encode(
            crypto_context(owner.vault_id, id(106), object, keys.object_dek)
            |> Map.put(:plaintext, bytes)
          )

        File.mkdir_p!(Path.dirname(object_path))
        File.write!(object_path, ciphertext, [:binary, :exclusive])
        File.chmod!(object_path, 0o600)

        insert("content.asset_objects",
          id: object,
          vault_id: owner.vault_id,
          key_domain_id: id(106),
          classification: "private",
          lookup_digest: lookup,
          ciphertext_hash: :crypto.hash(:sha256, ciphertext),
          plaintext_byte_size: byte_size(bytes),
          ciphertext_byte_size: byte_size(ciphertext),
          storage_ref: Path.relative_to(object_path, destination.object_root),
          format_version: 1,
          lifecycle: "available"
        )

        insert("content.asset_key_envelopes",
          id: id(200 + index),
          vault_id: owner.vault_id,
          asset_object_id: object,
          domain_key_version_id: id(109),
          key_domain_id: id(106),
          classification: "private",
          algorithm: "aes_256_gcm",
          key_generation: 1,
          wrapped_dek: wrap(keys.domain_key, keys.object_dek, :object_dek, "object:" <> object)
        )
      end

      source = %{
        resource_id: id(300 + index),
        resource_version_id: id(400 + index),
        asset_id: id(500 + index),
        object_id: object,
        digest: digest,
        byte_size: byte_size(bytes)
      }

      resource(owner, source.resource_id, "asset", nil, "Original #{name}")
      version(owner, source.resource_id, source.resource_version_id, 0)

      insert("content.assets",
        id: source.asset_id,
        vault_id: owner.vault_id,
        resource_version_id: source.resource_version_id,
        asset_object_id: object,
        classification: "private",
        state: "available"
      )

      insert("content.resource_assets",
        resource_version_id: source.resource_version_id,
        asset_id: source.asset_id,
        vault_id: owner.vault_id,
        classification: "private"
      )

      Map.put(sources, name, source)
    end)
  end

  defp seed_documents(owner, ids, sources) do
    specs = [
      {ids.ready_document_id, ids.ready_old_version_id, 0, :pdf, "ready"},
      {ids.ready_document_id, ids.ready_current_version_id, 1, :pdf_duplicate, "ready"},
      {ids.deleted_document_id, ids.deleted_document_version_id, 0, :pdf, "ready"},
      {ids.pending_document_id, ids.pending_version_id, 0, :empty, "pending"},
      {ids.extracting_document_id, ids.extracting_version_id, 0, :plain, "extracting"},
      {ids.failed_document_id, ids.failed_version_id, 0, :unicode, "failed"},
      {ids.unsupported_document_id, ids.unsupported_version_id, 0, :markdown, "unsupported"}
    ]

    Map.new(specs, fn {resource_id, version_id, revision, source_name, state} ->
      source = Map.fetch!(sources, source_name)

      if revision == 0,
        do: resource(owner, resource_id, "document", version_id, "Fixture Document"),
        else:
          query("UPDATE content.resources SET current_version_id=$1 WHERE id=$2", [
            dump(version_id),
            dump(resource_id)
          ])

      version(owner, resource_id, version_id, revision)

      media =
        cond do
          source_name in [:pdf, :pdf_duplicate] -> "application/pdf"
          source_name == :markdown -> "text/markdown"
          true -> "text/plain"
        end

      insert("content.document_versions",
        resource_version_id: version_id,
        resource_id: resource_id,
        vault_id: owner.vault_id,
        classification: "private",
        source_asset_id: source.asset_id,
        source_resource_id: source.resource_id,
        source_resource_version_id: source.resource_version_id,
        source_object_id: source.object_id,
        source_digest: source.digest,
        source_byte_size: source.byte_size,
        media_type: media,
        title: "Fixture Document",
        created_by_principal_id: owner.principal_id,
        inserted_at: @time
      )

      job = if state == "extracting", do: id(700), else: version_id

      if state != "pending" do
        adapter =
          %{
            "application/pdf" => "poppler_text",
            "text/plain" => "plain_text",
            "text/markdown" => "markdown"
          }[media]

        query(
          "UPDATE content.document_versions SET state='extracting',attempt_generation=1,attempt_job_id=$2,attempt_started_at=$3::timestamptz,attempt_deadline_at=$3::timestamptz+interval '180 seconds',extraction_adapter=$4,extraction_format=1 WHERE resource_version_id=$1",
          [dump(version_id), dump(job), @time, adapter]
        )
      end

      fragments =
        if state == "ready" do
          fragments =
            Enum.map(Enum.with_index(["first\n", "界🙂"]), fn {text, ordinal} ->
              locator = %{"version" => 1, "kind" => "pdf", "page" => ordinal + 1}

              {:ok, fragment} =
                DocumentFragment.new(%{
                  resource_id: resource_id,
                  resource_version_id: version_id,
                  owner_scope_id: owner.vault_id,
                  classification: :private,
                  ordinal: ordinal,
                  text: text,
                  locator: locator
                })

              insert("content.document_fragments",
                id: fragment.fragment_id,
                resource_id: resource_id,
                resource_version_id: version_id,
                vault_id: owner.vault_id,
                classification: "private",
                ordinal: ordinal,
                text: text,
                digest: fragment.digest,
                locator: locator,
                inserted_at: @time
              )

              %{
                id: fragment.fragment_id,
                locator: locator,
                resource_id: resource_id,
                version_id: version_id
              }
            end)

          query(
            "UPDATE content.document_versions SET state='ready',extracted_text_digest=$2,attempt_finished_at=$3 WHERE resource_version_id=$1",
            [dump(version_id), :crypto.hash(:sha256, "first\n界🙂"), @time]
          )

          fragments
        else
          if state in ["failed", "unsupported"] do
            query(
              "UPDATE content.document_versions SET state=$2,failure_code=$3,attempt_finished_at=$4 WHERE resource_version_id=$1",
              [
                dump(version_id),
                state,
                if(state == "failed", do: "extractor_failed", else: "no_extractable_text"),
                @time
              ]
            )
          end

          []
        end

      insert("content.document_import_receipts",
        vault_id: owner.vault_id,
        principal_id: owner.principal_id,
        mutation_id: version_id,
        request_fingerprint: :crypto.hash(:sha256, "document-import:" <> version_id),
        state: "completed",
        resource_id: resource_id,
        version_id: version_id,
        inserted_at: @time
      )

      {version_id, fragments}
    end)
  end

  defp seed_notes(owner, ids, sources, fragments) do
    resource(owner, ids.live_note_id, "note", ids.merge_note_version_id, "Fixture Note")
    resource(owner, ids.deleted_note_id, "note", ids.deleted_note_version_id, "Fixture Note")

    specs = [
      {ids.initial_note_version_id, 0, nil, nil, "# Initial fixture\n", false, false},
      {ids.canonical_note_version_id, 1, ids.initial_note_version_id, nil,
       "# Canonical fixture\n", true, false},
      {ids.competing_note_version_id, 2, ids.initial_note_version_id, nil,
       "# Competing fixture\n", false, true},
      {ids.merge_note_version_id, 3, ids.canonical_note_version_id, ids.competing_note_version_id,
       "# Merged fixture\n", true, true},
      {ids.open_competing_note_version_id, 4, ids.canonical_note_version_id, nil,
       "# Open competing fixture\n", true, false},
      {ids.deleted_note_version_id, 0, nil, nil, "# Deleted fixture\n", true, true}
    ]

    for {version_id, revision, parent, merge_parent, body, attachment?, citation?} <- specs do
      deleted? = version_id == ids.deleted_note_version_id
      note = if deleted?, do: ids.deleted_note_id, else: ids.live_note_id
      note_version(owner, note, version_id, revision, parent, merge_parent, "Fixture Note", body)

      if attachment? do
        {target, target_version, kind, member} =
          if deleted?,
            do:
              {ids.deleted_document_id, ids.deleted_document_version_id, "document",
               ids.deleted_attachment_id},
            else:
              {sources.pdf.resource_id, sources.pdf.resource_version_id, "asset",
               ids.attachment_id}

        insert("content.note_attachments",
          note_resource_version_id: version_id,
          id: member,
          note_resource_id: note,
          vault_id: owner.vault_id,
          classification: "private",
          target_resource_id: target,
          target_resource_version_id: target_version,
          target_kind: kind,
          ordinal: 0,
          role: "source",
          inserted_at: @time
        )
      end

      if citation? do
        fragment =
          fragments
          |> Map.fetch!(
            if(deleted?, do: ids.deleted_document_version_id, else: ids.ready_old_version_id)
          )
          |> hd()

        insert("content.note_citations",
          note_resource_version_id: version_id,
          id: if(deleted?, do: ids.deleted_citation_id, else: ids.citation_id),
          note_resource_id: note,
          vault_id: owner.vault_id,
          classification: "private",
          source_resource_id: fragment.resource_id,
          source_resource_version_id: fragment.version_id,
          fragment_id: fragment.id,
          locator: fragment.locator,
          ordinal: 0,
          inserted_at: @time
        )
      end

      query("SELECT content.finalize_note_source_set($1)", [dump(version_id)])
    end

    insert("content.note_conflicts",
      id: ids.resolved_conflict_id,
      resource_id: ids.live_note_id,
      vault_id: owner.vault_id,
      classification: "private",
      base_version_id: ids.initial_note_version_id,
      canonical_version_id: ids.canonical_note_version_id,
      competing_version_id: ids.competing_note_version_id,
      state: "resolved",
      resolution_version_id: ids.merge_note_version_id,
      resolved_at: @time
    )

    insert("content.note_conflicts",
      id: ids.open_conflict_id,
      resource_id: ids.live_note_id,
      vault_id: owner.vault_id,
      classification: "private",
      base_version_id: ids.canonical_note_version_id,
      canonical_version_id: ids.merge_note_version_id,
      competing_version_id: ids.open_competing_note_version_id,
      state: "open"
    )
  end

  defp seed_organization(owner, ids) do
    insert("content.tags",
      id: ids.tag_id,
      vault_id: owner.vault_id,
      classification: "private",
      display_value: "Straße",
      normalized_key: "strasse",
      created_by_principal_id: owner.principal_id,
      inserted_at: @time
    )

    insert("content.resource_tags",
      resource_id: ids.live_note_id,
      tag_id: ids.tag_id,
      vault_id: owner.vault_id,
      classification: "private",
      inserted_at: @time
    )

    insert("content.relationships",
      id: ids.relationship_id,
      vault_id: owner.vault_id,
      classification: "private",
      source_resource_id: ids.live_note_id,
      target_resource_id: ids.ready_document_id,
      target_resource_version_id: ids.ready_old_version_id,
      type: "references",
      created_by_principal_id: owner.principal_id,
      inserted_at: @time
    )
  end

  defp seed_work(owner, ids) do
    seed_work(owner, ids, %{
      submission_id: id(702),
      principal_authorization_epoch: 0,
      vault_authorization_epoch: 0
    })
  end

  defp seed_work(owner, ids, work) do
    insert("core.outbox_events",
      id: id(700),
      event_type: "document.extraction_requested",
      idempotency_key: "document-extraction:#{ids.extracting_version_id}",
      vault_id: owner.vault_id,
      principal_id: owner.principal_id,
      required_capability: "asset.read",
      principal_authorization_epoch: work.principal_authorization_epoch,
      vault_authorization_epoch: work.vault_authorization_epoch,
      classification: "private",
      correlation_id: id(701),
      expected_entity_revision: 0,
      envelope_version: 1,
      payload: %{
        "resource_id" => ids.extracting_document_id,
        "resource_version_id" => ids.extracting_version_id
      },
      occurred_at: @time
    )

    insert("jobs.job_submissions",
      id: work.submission_id,
      vault_id: owner.vault_id,
      outbox_event_id: id(700),
      classification: "private",
      idempotency_key: "document-extraction:#{ids.extracting_version_id}",
      job_type: "document_extract"
    )

    insert("jobs.job_progress",
      id: id(703),
      vault_id: owner.vault_id,
      submission_id: work.submission_id,
      classification: "private",
      state: "waiting_for_unlock",
      checkpoint_version: 1
    )

    insert("jobs.effect_receipts",
      id: id(704),
      vault_id: owner.vault_id,
      submission_id: work.submission_id,
      classification: "private",
      effect_key: "fixture-extraction-claimed",
      result: "applied",
      entity_revision: 0
    )
  end

  defp resource(owner, resource, kind, head, title),
    do:
      insert("content.resources",
        id: resource,
        vault_id: owner.vault_id,
        classification: "private",
        kind: kind,
        current_version_id: head,
        title: title
      )

  defp version(owner, resource, version, revision),
    do:
      insert("content.resource_versions",
        id: version,
        resource_id: resource,
        vault_id: owner.vault_id,
        classification: "private",
        revision: revision
      )

  defp note_version(owner, resource, version_id, revision, parent, merge, title, body) do
    version(owner, resource, version_id, revision)

    insert("content.note_versions",
      resource_version_id: version_id,
      resource_id: resource,
      vault_id: owner.vault_id,
      classification: "private",
      title: title,
      markdown: body,
      created_by_principal_id: owner.principal_id,
      parent_version_id: parent,
      merge_parent_version_id: merge
    )
  end

  defp prefix_projection do
    Enum.map(LogicalSchemaV2.all(), fn schema ->
      {schema.table, Enum.map(schema.columns, & &1.name),
       Enum.map(schema.primary_key, &Enum.fetch!(schema.columns, &1.position).name)}
    end)
  end

  defp select_rows(owner, projection) do
    owner_query(fn ->
      Map.new(projection, fn {table, columns, primary_key} ->
        {where, value} = owner_filter(table, owner)

        rows =
          query(
            "SELECT #{Enum.join(columns, ",")} FROM #{table} WHERE #{where} ORDER BY #{Enum.join(primary_key, ",")}",
            [dump(value)]
          )
          |> row_maps()

        {table, rows}
      end)
    end)
  end

  defp owner_filter("identity.people", owner),
    do: {"id IN (SELECT person_id FROM identity.accounts WHERE id=$1)", owner.account_id}

  defp owner_filter("identity.accounts", owner), do: {"id=$1", owner.account_id}

  defp owner_filter(table, owner) when table in ["identity.credentials", "identity.principals"],
    do: {"account_id=$1", owner.account_id}

  defp owner_filter("core.capabilities", owner),
    do:
      {"id IN (SELECT capability_id FROM core.principal_capabilities WHERE vault_id=$1)",
       owner.vault_id}

  defp owner_filter("core.vaults", owner), do: {"id=$1", owner.vault_id}
  defp owner_filter(_table, owner), do: {"vault_id=$1", owner.vault_id}

  defp row_maps(%{columns: columns, rows: rows}) do
    Enum.map(rows, fn row ->
      Map.new(Enum.zip(columns, row), fn {key, value} -> {key, canonical_value(key, value)} end)
    end)
  end

  defp canonical_value(_key, %DateTime{} = value), do: DateTime.to_iso8601(value)

  defp canonical_value(key, <<_::128>> = value),
    do: if(key == "id" or String.ends_with?(key, "_id"), do: Ecto.UUID.load!(value), else: value)

  defp canonical_value(_key, value), do: value

  defp bundle(fixture, rows, logical_version, mode) do
    asset_projection =
      Enum.filter(prefix_projection(), fn {table, _columns, _primary_key} ->
        table == "content.asset_objects"
      end)

    canonical_assets = select_rows(fixture.owner, asset_projection)["content.asset_objects"]
    originals = object_payloads(fixture, canonical_assets)
    {:ok, result} = build_bundle(fixture, rows, logical_version, mode, [], originals)
    result
  end

  defp object_payloads(fixture, objects) do
    Map.new(objects, fn object ->
      {:ok, path} =
        PathGuard.object_path(
          fixture.destination.object_root,
          object["vault_id"],
          object["key_domain_id"],
          Base.encode16(object["lookup_digest"], case: :lower)
        )

      {object["id"], File.read!(path)}
    end)
  end

  defp build_bundle(fixture, rows, logical_version, mode, options, originals) do
    schemas = if logical_version == 2, do: LogicalSchemaV2.all(), else: LogicalSchemaV3.all()
    manifest_id = id(900)
    snapshot_id = id(901)
    high_water = rows["core.outbox_events"] |> Enum.map(& &1["sequence"]) |> Enum.max(fn -> 0 end)
    objects = Enum.sort_by(rows["content.asset_objects"], & &1["id"])
    counts = Enum.map(schemas, &length(Map.fetch!(rows, &1.table)))

    cut_input =
      %{
        database_snapshot: "1:2:",
        manifest_id: manifest_id,
        snapshot_id: snapshot_id,
        vault_id: fixture.owner.vault_id,
        outbox_high_water_mark: high_water,
        table_count_vector: counts,
        object_count: length(objects)
      }
      |> transform(options, :cut)

    {:ok, cut_record} = LogicalRecordCodec.encode_cut(cut_input, logical_version)

    row_records =
      Enum.flat_map(schemas, fn schema ->
        Enum.map(Map.fetch!(rows, schema.table), fn row ->
          values =
            Enum.map(schema.columns, fn column ->
              case Map.fetch!(row, column.name) do
                nil -> {"null"}
                value -> {column.tag, value}
              end
            end)

          primary_key = Enum.map(schema.primary_key, &Enum.fetch!(values, &1.position))

          {:ok, record} =
            LogicalRecordCodec.encode_row(schema.table, primary_key, values, logical_version)

          record
        end)
      end)

    evidence =
      Enum.map(Enum.with_index(objects), fn {object, index} ->
        %{
          asset_object_id: object["id"],
          object_index: index,
          vault_id: object["vault_id"],
          key_domain_id: object["key_domain_id"],
          classification: object["classification"],
          lookup_digest: object["lookup_digest"],
          ciphertext_hash: object["ciphertext_hash"],
          ciphertext_byte_size: object["ciphertext_byte_size"],
          storage_ref: object["storage_ref"]
        }
      end)
      |> transform(options, :evidence)

    object_records =
      Enum.map(evidence, fn object ->
        {:ok, record} = LogicalRecordCodec.encode_object(object, logical_version)
        record
      end)

    raw_records =
      objects
      |> Enum.map(&Map.fetch!(originals, &1["id"]))
      |> transform(options, :raw)
      |> Enum.map(&%{type: 0x8000, payload: &1})

    records =
      ([cut_record | row_records] ++ object_records ++ raw_records)
      |> transform(options, :records)

    recovery = %{
      "binding" => %{"manifest_id" => manifest_id, "vault_id" => fixture.owner.vault_id},
      "label" => "backup_recovery",
      "wrapper" => "fixture-recovery-wrapper"
    }

    inventory =
      Enum.map(Enum.with_index(records), fn {record, index} ->
        %{
          position: index,
          record_type: record.type,
          payload_length: byte_size(record.payload),
          sha256: :crypto.hash(:sha256, record.payload)
        }
      end)

    {:ok, manifest} =
      Manifest.new(%{
        version: 1,
        manifest_id: manifest_id,
        snapshot_id: snapshot_id,
        vault_ids: [fixture.owner.vault_id],
        outbox_high_water_mark: high_water,
        recovery: recovery,
        inventory: inventory
      })

    {:ok, encoded_manifest} = Manifest.encode(manifest)

    plaintext =
      Enum.map(records ++ [%{type: 0xFFFF, payload: encoded_manifest}], fn record ->
        <<record.type::16, byte_size(record.payload)::64, record.payload::binary>>
      end)
      |> IO.iodata_to_binary()

    context =
      crypto_context(
        fixture.owner.vault_id,
        id(902),
        manifest_id,
        :crypto.hash(:sha256, "knowledge-fixture-backup-key")
      )

    {:ok, encrypted} = ChunkedAEAD.encode(Map.put(context, :plaintext, plaintext))
    header = :erlang.term_to_binary(%{version: 1, manifest_id: manifest_id}, [:deterministic])

    encoded =
      <<"SINGULARITY-BACKUP", 1::16, byte_size(header)::32, header::binary, encrypted::binary>>

    filename = "fixture-#{Ecto.UUID.generate()}.backup"

    File.write!(Path.join(fixture.destination.object_root, filename), encoded, [
      :binary,
      :exclusive
    ])

    File.chmod!(Path.join(fixture.destination.object_root, filename), 0o600)

    {:ok, source} =
      LocalDestination.reader_source(%{backup_root: fixture.destination.object_root}, filename)

    source = Keyword.get(options, :source, &Function.identity/1).(source)

    binding = %{
      manifest_id: manifest_id,
      vault_id: fixture.owner.vault_id,
      recovery: recovery,
      destination_ref: filename
    }

    options = [crypto: {FixtureCrypto, context}]

    options =
      if mode == :replay,
        do: options ++ [verifier: {LogicalBundleVerifier, binding}],
        else: options

    with {:ok, verified} <- BundleReader.authenticate_all(source, options) do
      if mode == :replay do
        Process.put(@replays, [verified | Process.get(@replays, [])])
        {:ok, %{verified: verified, cut: verified.cut, binding: binding}}
      else
        with {:ok, cut} <- LogicalBundleVerifier.verify(verified, binding),
             do: {:ok, %{verified: verified, cut: cut, binding: binding}}
      end
    end
  end

  defp transform(value, options, key), do: Keyword.get(options, key, &Function.identity/1).(value)

  defmodule FixtureCrypto do
    @moduledoc false
    alias Singularity.Storage.Crypto.{ChunkedAEAD, Format}
    def header_size, do: Format.header_size()

    def init_decrypt(context, public_header, header) when is_map(context),
      do: initialize_decrypt(context, :authenticate, public_header, header)

    def init_decrypt({:replay, context, authenticated}, public_header, header)
        when is_map(context) and is_map(authenticated),
        do: initialize_decrypt(context, {:replay, authenticated}, public_header, header)

    defp initialize_decrypt(context, phase, public_header, header) do
      with true <- context.object_id == public_header.manifest_id,
           {:ok, ^header, "", parsed} <- Format.split_header(header),
           true <-
             Format.context_matches?(parsed, Map.put(context, :nonce_prefix, parsed.nonce_prefix)) do
        {:ok,
         %{
           context: context,
           phase: phase,
           header: header,
           nonce_prefix: parsed.nonce_prefix,
           counter: 0,
           bytes: 0,
           hash: :crypto.hash_init(:sha256)
         }}
      else
        _ -> {:error, :integrity_failure}
      end
    end

    def decrypt_record(state, <<_counter::32, size::32, _rest::binary>> = record) do
      context = %{
        key: state.context.key,
        header: state.header,
        nonce_prefix: state.nonce_prefix,
        counter: state.counter,
        plaintext_size: size
      }

      with {:ok, plaintext} <- ChunkedAEAD.decrypt_data_record(record, context) do
        {:ok, plaintext,
         %{
           state
           | counter: state.counter + 1,
             bytes: state.bytes + byte_size(plaintext),
             hash: :crypto.hash_update(state.hash, plaintext)
         }}
      end
    end

    def finalize_decrypt(state, record, evidence) do
      context = %{key: state.context.key, header: state.header, nonce_prefix: state.nonce_prefix}

      with {:ok, summary} <- ChunkedAEAD.decrypt_final_record(record, context),
           true <-
             summary.chunk_count == state.counter and summary.plaintext_bytes == state.bytes,
           true <- summary.plaintext_sha256 == :crypto.hash_final(state.hash) do
        authenticated = Map.merge(evidence, summary)

        case state.phase do
          :authenticate ->
            {:ok, authenticated, {:replay, state.context, authenticated}}

          {:replay, ^authenticated} ->
            {:ok, authenticated, :replayed}

          _ ->
            {:error, :integrity_failure}
        end
      else
        _ -> {:error, :integrity_failure}
      end
    end

    def decrypt_all(context, public_header, encrypted) do
      with true <- context.object_id == public_header.manifest_id,
           {:ok, plaintext} <- ChunkedAEAD.decode(encrypted, context),
           {:ok, manifest} <- final_manifest(plaintext),
           {:ok, tag} <-
             ChunkedAEAD.final_tag(binary_part(encrypted, byte_size(encrypted) - 68, 68)) do
        {:ok, plaintext, %{manifest_hash: :crypto.hash(:sha256, manifest), manifest_tag: tag}}
      else
        _ -> {:error, :integrity_failure}
      end
    end

    defp final_manifest(<<0xFFFF::16, size::64, manifest::binary-size(size)>>),
      do: {:ok, manifest}

    defp final_manifest(<<_type::16, size::64, _payload::binary-size(size), rest::binary>>),
      do: final_manifest(rest)

    defp final_manifest(_), do: {:error, :integrity_failure}
  end

  defp crypto_context(owner, domain, object, key),
    do: %{
      key: key,
      vault_id: owner,
      encryption_domain_id: domain,
      object_id: object,
      chunk_index: 0,
      algorithm: Format.algorithm(),
      format_version: Format.format_version(),
      chunk_size: Format.chunk_size()
    }

  defp wrap(wrapping_key, raw_key, purpose, aad) do
    {:ok, wrapped} =
      KeyWrapper.wrap(wrapping_key, raw_key, %{
        purpose: purpose,
        generation: 1,
        aad: aad
      })

    wrapped.encoded
  end

  defp insert(table, fields) do
    timestamp = if table == "content.note_conflicts", do: :created_at, else: :inserted_at
    fields = Keyword.put_new(fields, timestamp, @time)
    columns = Enum.map(fields, fn {key, _} -> Atom.to_string(key) end)

    parameters =
      Enum.map(fields, fn {key, value} -> sql_value(table, Atom.to_string(key), value) end)

    query(
      "INSERT INTO #{table}(#{Enum.join(columns, ",")}) VALUES(#{Enum.map_join(1..length(fields), ",", &"$#{&1}")})",
      parameters
    )
  end

  defp sql_value(_table, _key, nil), do: nil
  defp sql_value("content.document_fragments", "id", value), do: value
  defp sql_value(_table, "fragment_id", value), do: value

  defp sql_value(_table, key, value) do
    if key == "id" or String.ends_with?(key, "_id"), do: dump(value), else: value
  end

  defp owner_query(fun) do
    {:ok, result} =
      MigrationRepo.transaction(fn ->
        query("SET LOCAL ROLE singularity_table_owner")
        fun.()
      end)

    result
  end

  defp query(sql, parameters \\ []),
    do: Ecto.Adapters.SQL.query!(MigrationRepo, sql, parameters, log: false)

  defp dump(id), do: Ecto.UUID.dump!(id)

  defp id(number),
    do: "60000000-0000-4000-8000-" <> String.pad_leading(Integer.to_string(number), 12, "0")
end
