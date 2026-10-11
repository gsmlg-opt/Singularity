defmodule Singularity.Storage.Postgres.KnowledgeLinkRepository do
  @moduledoc """
  Internal immutable Note source-set adapter. Writes require the caller's scoped
  transaction; runtime grants remain disabled until Phase 4 seals membership.
  """
  @behaviour Singularity.Domains.KnowledgeLinks.Repository
  import Ecto.Query

  alias Singularity.Core.{
    DocumentFragment,
    Error,
    NoteAttachment,
    NoteAttachmentReference,
    NoteCitation,
    NoteCitationReference,
    NoteSourceSet,
    SourceLocator
  }

  alias Singularity.Storage.{SafeSQL, ScopedRepo}
  alias Singularity.Storage.Postgres.{KnowledgeError, UUID}
  alias Singularity.Storage.Schema.Content.NoteAttachment, as: StoredAttachment
  alias Singularity.Storage.Schema.Content.NoteCitation, as: StoredCitation
  alias Singularity.Storage.Schema.Content.DocumentFragment, as: StoredFragment

  @constraints "content.note_attachments_note_fkey, content.note_attachments_target_fkey, content.note_attachments_source_set_check, content.note_citations_note_fkey, content.note_citations_fragment_fkey, content.note_citations_source_set_check, content.note_versions_source_set_seal_check, content.note_attachments_source_set_seal_check, content.note_citations_source_set_seal_check"
  @attachment_semantics [
    :attachment_id,
    :target_resource_id,
    :target_resource_version_id,
    :target_kind,
    :role,
    :label
  ]
  @citation_semantics [
    :citation_id,
    :source_resource_id,
    :source_resource_version_id,
    :fragment_id,
    :locator
  ]

  @impl true
  def insert_set(context, input) do
    with {:ok, repo} <- context_repo(context), :ok <- existing_scope(repo, context) do
      insert_in_scope(repo, context, input)
    end
  rescue
    exception -> {:error, KnowledgeError.from(exception)}
  end

  defp insert_in_scope(repo, context, input) do
    result =
      with {:ok, set} <- NoteSourceSet.new(input),
           true <- set.owner_scope_id == context.owner_scope_id,
           :ok <- bounded(set),
           :ok <- lock_sources(repo, set),
           :ok <-
             note_exists(repo, context, set.note_resource_id, set.note_resource_version_id, true),
           :ok <- validate_evidence(repo, set),
           {:ok, old} <-
             read_set(repo, context, set.note_resource_id, set.note_resource_version_id) do
        persist(repo, context, set, old)
      else
        false -> error(:invalid)
        {:error, _} = failure -> failure
      end

    case result do
      {:error, reason} ->
        repo.rollback(KnowledgeError.from(reason))

      success ->
        SafeSQL.query!(repo, "SET CONSTRAINTS " <> @constraints <> " IMMEDIATE", [])
        SafeSQL.query!(repo, "SET CONSTRAINTS " <> @constraints <> " DEFERRED", [])
        success
    end
  rescue
    exception -> repo.rollback(KnowledgeError.from(exception))
  end

  @impl true
  def list_set(context, resource_id, version_id) do
    with {:ok, repo} <- context_repo(context), :ok <- UUID.validate([resource_id, version_id]) do
      if repo.in_transaction?() do
        with :ok <- existing_scope(repo, context),
             do: read_set(repo, context, resource_id, version_id)
      else
        ScopedRepo.transact(
          repo,
          %{principal_id: context.principal_id, vault_id: context.owner_scope_id},
          fn transaction_repo -> read_set(transaction_repo, context, resource_id, version_id) end
        )
      end
    end
  rescue
    exception -> {:error, KnowledgeError.from(exception)}
  end

  @impl true
  def select_attachment_in_scope(context, resource, version, member) do
    select_reference(context, resource, version, member, :attachments)
  end

  @impl true
  def select_citation_in_scope(context, resource, version, member) do
    select_reference(context, resource, version, member, :citations)
  end

  defp select_reference(context, resource, version, member_id, kind) do
    with {:ok, repo} <- context_repo(context),
         :ok <- existing_scope(repo, context),
         :ok <- canonical_ids([resource, version, member_id]),
         :ok <- selected_note_exists(repo, context, resource, version) do
      {schema, constructor, reference_module} =
        case kind do
          :attachments -> {StoredAttachment, &attachment_value/1, NoteAttachmentReference}
          :citations -> {StoredCitation, &citation_value/1, NoteCitationReference}
        end

      row =
        repo.one(
          from(member in schema,
            where:
              member.id == ^member_id and member.note_resource_id == ^resource and
                member.note_resource_version_id == ^version and
                member.vault_id == ^context.owner_scope_id and member.classification == :private
          ),
          log: false,
          telemetry_event: nil
        )

      if is_nil(row) do
        error(:not_found)
      else
        with {:ok, member} <- constructor.(row),
             true <- kind != :attachments or member.label == row.label,
             attrs = member |> Map.from_struct() |> Map.take(reference_keys(kind)),
             {:ok, reference} <- reference_module.new(attrs),
             true <- Map.from_struct(reference) == attrs do
          {:ok, reference}
        else
          false -> error(:invalid)
          {:error, _} = failure -> failure
        end
      end
    end
  rescue
    exception -> {:error, KnowledgeError.from(exception)}
  end

  @impl true
  def resolve_attachment_in_scope(context, %NoteAttachmentReference{} = reference) do
    with {:ok, repo} <- context_repo(context),
         :ok <- existing_scope(repo, context),
         {:ok, ^reference} <- NoteAttachmentReference.new(reference),
         {:ok, source} <-
           source_metadata(
             repo,
             context.owner_scope_id,
             reference.target_resource_id,
             reference.target_resource_version_id,
             reference.target_kind
           ) do
      {:ok, %{reference: reference, source: source}}
    end
  rescue
    exception -> {:error, KnowledgeError.from(exception)}
  end

  def resolve_attachment_in_scope(_, _), do: error(:invalid)

  @impl true
  def resolve_citation_in_scope(context, %NoteCitationReference{} = reference) do
    with {:ok, repo} <- context_repo(context),
         :ok <- existing_scope(repo, context),
         {:ok, ^reference} <- NoteCitationReference.new(reference),
         {:ok, source} <-
           source_metadata(
             repo,
             context.owner_scope_id,
             reference.source_resource_id,
             reference.source_resource_version_id,
             :document
           ),
         {:ok, fragment} <- selected_fragment(repo, context, reference) do
      {:ok, %{reference: reference, source: source, fragment: fragment}}
    end
  rescue
    exception -> {:error, KnowledgeError.from(exception)}
  end

  def resolve_citation_in_scope(_, _), do: error(:invalid)

  defp selected_note_exists(repo, context, resource, version) do
    %{rows: rows} =
      SafeSQL.query!(
        repo,
        """
        SELECT n.resource_version_id
        FROM content.note_versions n
        JOIN content.resources r ON (r.id,r.vault_id,r.classification)=(n.resource_id,n.vault_id,n.classification)
        JOIN content.resource_versions v ON (v.id,v.resource_id,v.vault_id,v.classification)=(n.resource_version_id,n.resource_id,n.vault_id,n.classification)
        JOIN content.note_source_set_seals s ON (s.note_resource_version_id,s.note_resource_id,s.vault_id,s.classification)=(n.resource_version_id,n.resource_id,n.vault_id,n.classification)
        WHERE (n.resource_id,n.resource_version_id,n.vault_id,n.classification)=($1,$2,$3,'private')
          AND r.kind='note' AND r.deleted_at IS NULL
        FOR SHARE OF r
        """,
        [
          Ecto.UUID.dump!(resource),
          Ecto.UUID.dump!(version),
          Ecto.UUID.dump!(context.owner_scope_id)
        ]
      )

    case rows do
      [[_version]] -> :ok
      [] -> error(:not_found)
      _ -> error(:invalid)
    end
  end

  defp source_metadata(repo, owner, resource, version, kind) do
    {title, deleted, typed_join} =
      case kind do
        :asset ->
          {"""
           CASE WHEN (
             SELECT count(*) FROM (
               SELECT exact_asset.id FROM content.assets exact_asset
               WHERE (exact_asset.resource_version_id,exact_asset.vault_id)=(v.id,r.vault_id)
               UNION
               SELECT exact_metadata.asset_id FROM content.asset_metadata exact_metadata
               WHERE (exact_metadata.resource_version_id,exact_metadata.vault_id)=(v.id,r.vault_id)
               UNION
               SELECT exact_association.asset_id FROM content.resource_assets exact_association
               WHERE (exact_association.resource_version_id,exact_association.vault_id)=(v.id,r.vault_id)
             ) candidate_assets
           )=1 THEN m.original_filename END
           """,
           """
           (r.deleted_at IS NOT NULL OR a.state IN ('pending_delete','deleted')
            OR ra.released_at IS NOT NULL OR EXISTS (
              SELECT 1 FROM content.tombstones t
              WHERE (t.asset_id,t.vault_id,t.classification)=(a.id,a.vault_id,a.classification)
            ))
           """,
           """
           JOIN content.assets a ON (a.resource_version_id,a.vault_id,a.classification)=(v.id,r.vault_id,r.classification)
           JOIN content.asset_metadata m ON (m.asset_id,m.resource_version_id,m.vault_id,m.classification)=(a.id,v.id,r.vault_id,r.classification)
           JOIN content.resource_assets ra ON (ra.resource_version_id,ra.asset_id,ra.vault_id,ra.classification)=(v.id,a.id,r.vault_id,r.classification)
           """}

        :note ->
          {"n.title", "r.deleted_at IS NOT NULL",
           "JOIN content.note_versions n ON (n.resource_version_id,n.resource_id,n.vault_id,n.classification)=(v.id,r.id,r.vault_id,r.classification)"}

        :document ->
          {"d.title", "r.deleted_at IS NOT NULL",
           "JOIN content.document_versions d ON (d.resource_version_id,d.resource_id,d.vault_id,d.classification)=(v.id,r.id,r.vault_id,r.classification) AND d.state='ready'"}
      end

    %{rows: rows} =
      SafeSQL.query!(
        repo,
        """
        SELECT #{title},#{deleted}
        FROM content.resources r
        JOIN content.resource_versions v ON (v.resource_id,v.vault_id,v.classification)=(r.id,r.vault_id,r.classification)
        #{typed_join}
        WHERE (r.id,v.id,r.vault_id,r.classification)=($1,$2,$3,'private') AND r.kind=$4
        LIMIT 2
        """,
        [
          Ecto.UUID.dump!(resource),
          Ecto.UUID.dump!(version),
          Ecto.UUID.dump!(owner),
          Atom.to_string(kind)
        ]
      )

    case rows do
      [[title, deleted?]] when is_boolean(deleted?) ->
        if is_binary(title) and String.valid?(title) and String.trim(title) != "" and
             not String.contains?(title, <<0>>) do
          {:ok,
           %{
             kind: kind,
             resource_id: resource,
             resource_version_id: version,
             title: title,
             deleted?: deleted?
           }}
        else
          error(:invalid)
        end

      [] ->
        error(:not_found)

      _ ->
        error(:invalid)
    end
  end

  defp selected_fragment(repo, context, reference) do
    row =
      repo.one(
        from(fragment in StoredFragment,
          where:
            fragment.id == ^reference.fragment_id and
              fragment.resource_id == ^reference.source_resource_id and
              fragment.resource_version_id == ^reference.source_resource_version_id and
              fragment.vault_id == ^context.owner_scope_id and fragment.classification == :private
        ),
        log: false,
        telemetry_event: nil
      )

    if is_nil(row) do
      error(:not_found)
    else
      with {:ok, fragment} <- fragment_value(row),
           true <- fragment.locator == reference.locator do
        {:ok, Map.take(fragment, [:fragment_id, :ordinal, :text, :locator])}
      else
        false -> error(:invalid)
        {:error, _} = failure -> failure
      end
    end
  end

  defp canonical_ids(ids) do
    if Enum.all?(ids, fn id ->
         match?({:ok, ^id}, Singularity.Core.Types.canonical_uuid(%{id: id}, :id))
       end),
       do: :ok,
       else: error(:invalid)
  end

  @doc false
  def read_membership(context, resource_id, version_id) do
    with {:ok, repo} <- context_repo(context),
         :ok <- existing_scope(repo, context),
         :ok <- UUID.validate([resource_id, version_id]) do
      %{rows: rows} =
        SafeSQL.query!(
          repo,
          """
          SELECT v.revision,s.attachment_count,s.citation_count
          FROM content.note_versions n
          JOIN content.resources r ON (r.id,r.vault_id,r.classification)=(n.resource_id,n.vault_id,n.classification) AND r.kind='note'
          JOIN content.resource_versions v ON (v.id,v.resource_id,v.vault_id,v.classification)=(n.resource_version_id,n.resource_id,n.vault_id,n.classification)
          JOIN content.note_source_set_seals s ON (s.note_resource_version_id,s.note_resource_id,s.vault_id,s.classification)=(n.resource_version_id,n.resource_id,n.vault_id,n.classification)
          WHERE (n.resource_version_id,n.resource_id,n.vault_id,n.classification)=($1,$2,$3,'private')
          """,
          [
            Ecto.UUID.dump!(version_id),
            Ecto.UUID.dump!(resource_id),
            Ecto.UUID.dump!(context.owner_scope_id)
          ]
        )

      case rows do
        [[revision, attachments, citations]] ->
          with {:ok, attachments} <-
                 membership_rows(
                   repo,
                   context,
                   resource_id,
                   version_id,
                   :attachments,
                   attachments
                 ),
               {:ok, citations} <-
                 membership_rows(repo, context, resource_id, version_id, :citations, citations) do
            {:ok, %{revision: revision, attachments: attachments, citations: citations}}
          end

        [] ->
          error(:not_found)
      end
    end
  rescue
    exception -> {:error, KnowledgeError.from(exception)}
  end

  # A sealed empty collection needs no child-table privilege. This preserves
  # legacy empty Note mutations before Phase 4's explicit runtime grants.
  defp membership_rows(_repo, _context, _resource, _version, _kind, 0), do: {:ok, []}

  defp membership_rows(repo, context, resource, version, kind, count) when count in 1..100 do
    {schema, constructor, reference_module} =
      case kind do
        :attachments -> {StoredAttachment, &attachment_value/1, NoteAttachmentReference}
        :citations -> {StoredCitation, &citation_value/1, NoteCitationReference}
      end

    rows =
      repo.all(
        from(member in schema,
          where:
            member.note_resource_id == ^resource and member.note_resource_version_id == ^version and
              member.vault_id == ^context.owner_scope_id,
          order_by: [member.ordinal, member.id],
          limit: 101
        ),
        log: false,
        telemetry_event: nil
      )

    if length(rows) == count and
         Enum.all?(Enum.with_index(rows), fn {row, ordinal} -> row.ordinal == ordinal end) do
      collect(rows, fn row ->
        with {:ok, member} <- constructor.(row),
             true <- kind != :attachments or member.label == row.label,
             attrs = member |> Map.from_struct() |> Map.take(reference_keys(kind)),
             {:ok, reference} <- reference_module.new(attrs),
             true <- Map.from_struct(reference) == attrs do
          {:ok, reference}
        else
          false -> error(:invalid)
          {:error, _} = failure -> failure
        end
      end)
    else
      error(:invalid)
    end
  end

  defp membership_rows(_, _, _, _, _, _), do: error(:invalid)

  defp reference_keys(:attachments), do: @attachment_semantics
  defp reference_keys(:citations), do: @citation_semantics

  @doc false
  def revalidate_target(context, resource, version, live?) do
    with {:ok, repo} <- context_repo(context),
         :ok <- existing_scope(repo, context),
         :ok <- UUID.validate([resource, version]),
         true <- is_boolean(live?) do
      target_value(repo, context.owner_scope_id, resource, version, live?)
    else
      false -> error(:invalid)
      {:error, _} = failure -> failure
    end
  rescue
    exception -> {:error, KnowledgeError.from(exception)}
  end

  @doc false
  def insert_composed_members(context, resource, version, attachments, citations) do
    with {:ok, repo} <- context_repo(context),
         :ok <- existing_scope(repo, context),
         :ok <- UUID.validate([resource, version]),
         :ok <- note_exists(repo, context, resource, version, true),
         {:ok, attachments} <-
           composed_members(attachments, NoteAttachment, context, resource, version),
         {:ok, citations} <-
           composed_members(citations, NoteCitation, context, resource, version),
         :ok <-
           bounded(%{attachments: attachments, citations: citations, targets: [], fragments: []}) do
      insert_rows(repo, %{attachments: attachments, citations: citations})
      SafeSQL.query!(repo, "SET CONSTRAINTS " <> @constraints <> " IMMEDIATE", [])
      SafeSQL.query!(repo, "SET CONSTRAINTS " <> @constraints <> " DEFERRED", [])
      :ok
    end
  rescue
    exception -> {:error, KnowledgeError.from(exception)}
  end

  defp composed_members(references, module, context, resource, version) do
    references
    |> Enum.with_index()
    |> collect(fn {reference, ordinal} ->
      reference
      |> Map.from_struct()
      |> Map.merge(%{
        note_resource_id: resource,
        note_resource_version_id: version,
        owner_scope_id: context.owner_scope_id,
        classification: :private,
        ordinal: ordinal
      })
      |> module.new()
    end)
  end

  defp persist(repo, context, set, old) do
    with {:ok, sealed?} <- sealed?(repo, set, old) do
      if sealed? or old.attachments != [] or old.citations != [] do
        if set.attachments == old.attachments and set.citations == old.citations,
          do: {:ok, old},
          else: error(:conflict)
      else
        insert_members(repo, context, set)
      end
    end
  end

  defp sealed?(repo, set, old) do
    %{rows: rows} =
      SafeSQL.query!(
        repo,
        "SELECT note_resource_id::text,vault_id::text,classification,attachment_count,citation_count FROM content.note_source_set_seals WHERE note_resource_version_id=$1",
        [Ecto.UUID.dump!(set.note_resource_version_id)]
      )

    expected = [
      set.note_resource_id,
      set.owner_scope_id,
      "private",
      length(old.attachments),
      length(old.citations)
    ]

    case rows do
      [] -> {:ok, false}
      [^expected] -> {:ok, true}
      _ -> error(:invalid)
    end
  end

  defp insert_members(repo, context, set) do
    insert_rows(repo, set)
    read_set(repo, context, set.note_resource_id, set.note_resource_version_id)
  end

  defp insert_rows(repo, set) do
    now = DateTime.utc_now(:microsecond)

    Enum.each(set.attachments, fn attachment ->
      attrs =
        attachment
        |> Map.from_struct()
        |> Map.drop([:attachment_id, :owner_scope_id])
        |> Map.merge(%{
          id: attachment.attachment_id,
          vault_id: attachment.owner_scope_id,
          inserted_at: now
        })

      insert!(repo, StoredAttachment.create_changeset(%StoredAttachment{}, attrs))
    end)

    Enum.each(set.citations, fn citation ->
      attrs =
        citation
        |> Map.from_struct()
        |> Map.drop([:citation_id, :owner_scope_id])
        |> Map.merge(%{
          id: citation.citation_id,
          vault_id: citation.owner_scope_id,
          locator: SourceLocator.to_map(citation.locator),
          inserted_at: now
        })

      insert!(repo, StoredCitation.create_changeset(%StoredCitation{}, attrs))
    end)

    :ok
  end

  defp insert!(repo, changeset) do
    case repo.insert(changeset, log: false, telemetry_event: nil) do
      {:ok, row} -> row
      {:error, reason} -> repo.rollback(KnowledgeError.from(reason))
    end
  end

  defp read_set(repo, context, resource_id, version_id) do
    with :ok <- note_exists(repo, context, resource_id, version_id, false) do
      attachments =
        repo.all(
          from(a in StoredAttachment,
            where:
              a.note_resource_id == ^resource_id and a.note_resource_version_id == ^version_id and
                a.vault_id == ^context.owner_scope_id,
            order_by: [a.ordinal, a.id],
            limit: 101
          ),
          log: false,
          telemetry_event: nil
        )

      citations =
        repo.all(
          from(c in StoredCitation,
            where:
              c.note_resource_id == ^resource_id and c.note_resource_version_id == ^version_id and
                c.vault_id == ^context.owner_scope_id,
            order_by: [c.ordinal, c.id],
            limit: 101
          ),
          log: false,
          telemetry_event: nil
        )

      with true <- length(attachments) <= 100 and length(citations) <= 100,
           {:ok, attachments} <- collect(attachments, &attachment_value/1),
           {:ok, citations} <- collect(citations, &citation_value/1),
           identities =
             Enum.map(attachments, &{&1.target_resource_id, &1.target_resource_version_id}) ++
               Enum.map(citations, &{&1.source_resource_id, &1.source_resource_version_id}),
           identities = identities |> Enum.uniq() |> Enum.sort(),
           true <- length(identities) <= 100,
           {:ok, targets} <-
             collect(identities, fn {resource, version} ->
               target_value(repo, context.owner_scope_id, resource, version, false)
             end),
           fragment_ids = citations |> Enum.map(& &1.fragment_id) |> Enum.uniq(),
           rows =
             repo.all(
               from(f in StoredFragment,
                 where: f.id in ^fragment_ids and f.vault_id == ^context.owner_scope_id,
                 order_by: [f.resource_id, f.resource_version_id, f.ordinal, f.id],
                 limit: 101
               ),
               log: false,
               telemetry_event: nil
             ),
           true <- length(rows) == length(fragment_ids) and length(rows) <= 100,
           {:ok, fragments} <- collect(rows, &fragment_value/1) do
        NoteSourceSet.new(%{
          note_resource_id: resource_id,
          note_resource_version_id: version_id,
          owner_scope_id: context.owner_scope_id,
          classification: :private,
          attachments: attachments,
          citations: citations,
          targets: targets,
          fragments: fragments
        })
      else
        false -> error(:invalid)
        {:error, _} = failure -> failure
      end
    end
  end

  defp attachment_value(row) do
    row
    |> Map.from_struct()
    |> Map.take([
      :note_resource_id,
      :note_resource_version_id,
      :classification,
      :target_resource_id,
      :target_resource_version_id,
      :target_kind,
      :ordinal,
      :role,
      :label
    ])
    |> Map.merge(%{attachment_id: row.id, owner_scope_id: row.vault_id})
    |> NoteAttachment.new()
  end

  defp citation_value(row) do
    row
    |> Map.from_struct()
    |> Map.take([
      :note_resource_id,
      :note_resource_version_id,
      :classification,
      :source_resource_id,
      :source_resource_version_id,
      :fragment_id,
      :locator,
      :ordinal
    ])
    |> Map.merge(%{citation_id: row.id, owner_scope_id: row.vault_id})
    |> NoteCitation.new()
  end

  defp fragment_value(row) do
    row
    |> Map.from_struct()
    |> Map.take([
      :resource_id,
      :resource_version_id,
      :classification,
      :ordinal,
      :text,
      :digest,
      :locator
    ])
    |> Map.merge(%{fragment_id: row.id, owner_scope_id: row.vault_id})
    |> DocumentFragment.new()
  end

  defp validate_evidence(repo, set) do
    with {:ok, parents} <- retained_parent_members(repo, set),
         new_identities = new_source_identities(set, parents),
         referenced = source_identities(set),
         {:ok, _} <-
           collect(witness_targets(set), fn target ->
             with {:ok, actual} <-
                    target_value(
                      repo,
                      set.owner_scope_id,
                      target.resource_id,
                      target.resource_version_id,
                      MapSet.member?(
                        new_identities,
                        {target.resource_id, target.resource_version_id}
                      ) or
                        not MapSet.member?(
                          referenced,
                          {target.resource_id, target.resource_version_id}
                        )
                    ),
                  true <- actual == target do
               {:ok, actual}
             else
               false -> error(:invalid)
               {:error, _} = failure -> failure
             end
           end),
         {:ok, _} <-
           collect(Enum.uniq(set.fragments), fn fragment ->
             row =
               repo.one(
                 from(f in StoredFragment,
                   where: f.id == ^fragment.fragment_id and f.vault_id == ^set.owner_scope_id
                 ),
                 log: false,
                 telemetry_event: nil
               )

             with %StoredFragment{} <- row,
                  {:ok, actual} <- fragment_value(row),
                  true <- actual == fragment do
               {:ok, actual}
             else
               _ -> error(:invalid)
             end
           end),
         do: :ok
  end

  defp retained_parent_members(repo, set) do
    %{rows: rows} =
      SafeSQL.query!(
        repo,
        """
        SELECT parent_id::text,COALESCE((p.resource_id,p.vault_id,p.classification)=(n.resource_id,n.vault_id,n.classification)
          AND p.classification='private' AND pv.revision<nv.revision,false)
        FROM content.note_versions n
        JOIN content.resource_versions nv ON (nv.id,nv.resource_id,nv.vault_id,nv.classification)=(n.resource_version_id,n.resource_id,n.vault_id,n.classification)
        CROSS JOIN LATERAL unnest(ARRAY[n.parent_version_id,n.merge_parent_version_id]) parents(parent_id)
        LEFT JOIN content.note_versions p ON p.resource_version_id=parent_id
        LEFT JOIN content.resource_versions pv ON (pv.id,pv.resource_id,pv.vault_id,pv.classification)=(p.resource_version_id,p.resource_id,p.vault_id,p.classification)
        WHERE (n.resource_version_id,n.resource_id,n.vault_id,n.classification)=($1,$2,$3,'private') AND parent_id IS NOT NULL
        """,
        [
          Ecto.UUID.dump!(set.note_resource_version_id),
          Ecto.UUID.dump!(set.note_resource_id),
          Ecto.UUID.dump!(set.owner_scope_id)
        ]
      )

    if Enum.all?(rows, fn [_, valid?] -> valid? end) do
      parents = Enum.map(rows, fn [id, true] -> id end)

      attachments =
        repo.all(
          from(a in StoredAttachment,
            where:
              a.note_resource_version_id in ^parents and
                a.note_resource_id == ^set.note_resource_id and a.vault_id == ^set.owner_scope_id,
            limit: 201
          ),
          log: false,
          telemetry_event: nil
        )

      citations =
        repo.all(
          from(c in StoredCitation,
            where:
              c.note_resource_version_id in ^parents and
                c.note_resource_id == ^set.note_resource_id and c.vault_id == ^set.owner_scope_id,
            limit: 201
          ),
          log: false,
          telemetry_event: nil
        )

      with true <- length(attachments) <= 200 and length(citations) <= 200,
           {:ok, attachments} <- collect(attachments, &attachment_value/1),
           {:ok, citations} <- collect(citations, &citation_value/1) do
        {:ok, %{attachments: attachments, citations: citations}}
      else
        false -> error(:invalid)
        {:error, _} = failure -> failure
      end
    else
      error(:invalid)
    end
  end

  defp new_source_identities(set, parents) do
    attachments =
      Enum.reject(
        set.attachments,
        &retained_member?(&1, parents.attachments, @attachment_semantics)
      )

    citations =
      Enum.reject(set.citations, &retained_member?(&1, parents.citations, @citation_semantics))

    source_identities(%{attachments: attachments, citations: citations})
  end

  defp retained_member?(member, parents, semantics) do
    Enum.any?(parents, &(Map.take(&1, semantics) == Map.take(member, semantics)))
  end

  defp source_identities(set) do
    (Enum.map(set.attachments, &{&1.target_resource_id, &1.target_resource_version_id}) ++
       Enum.map(set.citations, &{&1.source_resource_id, &1.source_resource_version_id}))
    |> MapSet.new()
  end

  defp witness_targets(set) do
    fragments =
      Enum.map(set.fragments, fn fragment ->
        fragment
        |> Map.take([:resource_id, :resource_version_id, :owner_scope_id, :classification])
        |> Map.merge(%{kind: :document, state: :ready})
      end)

    Enum.uniq(set.targets ++ fragments)
  end

  defp target_value(repo, owner, resource, version, live?) do
    %{rows: rows} =
      SafeSQL.query!(
        repo,
        """
        SELECT r.kind, d.state FROM content.resources r
        JOIN content.resource_versions v ON (v.resource_id,v.vault_id,v.classification)=(r.id,r.vault_id,r.classification)
        LEFT JOIN content.document_versions d ON (d.resource_version_id,d.resource_id,d.vault_id,d.classification)=(v.id,r.id,r.vault_id,r.classification)
        WHERE r.id=$1 AND v.id=$2 AND r.vault_id=$3 AND r.classification='private'
          AND (NOT $4 OR r.deleted_at IS NULL)
          AND ((r.kind='document' AND d.state='ready') OR
            (r.kind='note' AND EXISTS(SELECT 1 FROM content.note_versions n WHERE (n.resource_version_id,n.resource_id,n.vault_id,n.classification)=(v.id,r.id,r.vault_id,r.classification))) OR
            (r.kind='asset' AND EXISTS(SELECT 1 FROM content.assets a WHERE a.resource_version_id=v.id AND a.vault_id=r.vault_id AND a.classification='private'
              AND (NOT $4 OR (a.state IN ('available','processing','ready') AND EXISTS(
                SELECT 1 FROM content.asset_objects o JOIN content.resource_assets ra ON ra.asset_id=a.id AND ra.resource_version_id=v.id AND ra.vault_id=r.vault_id
                WHERE o.id=a.asset_object_id AND o.vault_id=r.vault_id AND o.classification='private'
                  AND o.lifecycle='available' AND o.deleted_at IS NULL AND ra.classification='private' AND ra.released_at IS NULL))))))
        """,
        [Ecto.UUID.dump!(resource), Ecto.UUID.dump!(version), Ecto.UUID.dump!(owner), live?]
      )

    base = %{
      resource_id: resource,
      resource_version_id: version,
      owner_scope_id: owner,
      classification: :private
    }

    case rows do
      [["document", "ready"]] -> {:ok, Map.merge(base, %{kind: :document, state: :ready})}
      [["note", _]] -> {:ok, Map.put(base, :kind, :note)}
      [["asset", _]] -> {:ok, Map.put(base, :kind, :asset)}
      [] -> error(:not_found)
    end
  end

  defp note_exists(repo, context, resource, version, live?) do
    %{rows: rows} =
      SafeSQL.query!(
        repo,
        """
        SELECT n.resource_version_id FROM content.note_versions n JOIN content.resources r
          ON (r.id,r.vault_id,r.classification)=(n.resource_id,n.vault_id,n.classification)
        WHERE n.resource_id=$1 AND n.resource_version_id=$2 AND n.vault_id=$3
          AND n.classification='private' AND r.kind='note' AND (NOT $4 OR r.deleted_at IS NULL)
        FOR SHARE OF r
        """,
        [
          Ecto.UUID.dump!(resource),
          Ecto.UUID.dump!(version),
          Ecto.UUID.dump!(context.owner_scope_id),
          live?
        ]
      )

    if rows == [], do: error(:not_found), else: :ok
  end

  defp lock_sources(repo, set) do
    targets = witness_targets(set)

    asset_versions =
      targets
      |> Enum.filter(&(&1.kind == :asset))
      |> Enum.map(&Ecto.UUID.dump!(&1.resource_version_id))
      |> Enum.sort()

    owner = Ecto.UUID.dump!(set.owner_scope_id)

    %{rows: assets} =
      SafeSQL.query!(
        repo,
        "SELECT id,asset_object_id FROM content.assets WHERE resource_version_id=ANY($1::uuid[]) AND vault_id=$2 ORDER BY id FOR SHARE",
        [asset_versions, owner]
      )

    object_ids =
      assets
      |> Enum.map(fn [_, object] -> object end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort()

    SafeSQL.query!(
      repo,
      "SELECT id FROM content.asset_objects WHERE id=ANY($1::uuid[]) AND vault_id=$2 ORDER BY id FOR SHARE",
      [object_ids, owner]
    )

    resources =
      [set.note_resource_id | Enum.map(targets, & &1.resource_id)]
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map(&Ecto.UUID.dump!/1)

    %{rows: rows} =
      SafeSQL.query!(
        repo,
        "SELECT id FROM content.resources WHERE id=ANY($1::uuid[]) AND vault_id=$2 ORDER BY id FOR UPDATE",
        [resources, owner]
      )

    Enum.each(rows, fn [resource] ->
      SafeSQL.query!(
        repo,
        "SELECT pg_advisory_xact_lock(hashtextextended('singularity.note.aggregate:' || $1::text,0))",
        [Ecto.UUID.load!(resource)]
      )
    end)

    versions =
      [set.note_resource_version_id | Enum.map(targets, & &1.resource_version_id)]
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map(&Ecto.UUID.dump!/1)

    SafeSQL.query!(
      repo,
      "SELECT id FROM content.resource_versions WHERE id=ANY($1::uuid[]) AND vault_id=$2 ORDER BY id FOR SHARE",
      [versions, owner]
    )

    SafeSQL.query!(
      repo,
      "SELECT asset_id FROM content.resource_assets WHERE resource_version_id=ANY($1::uuid[]) AND vault_id=$2 ORDER BY resource_version_id,asset_id FOR SHARE",
      [asset_versions, owner]
    )

    :ok
  end

  defp existing_scope(repo, context) do
    if repo.in_transaction?() do
      %{rows: rows} =
        SafeSQL.query!(
          repo,
          "SELECT current_setting('singularity.principal_id',true),current_setting('singularity.vault_id',true)",
          []
        )

      if rows == [[context.principal_id, context.owner_scope_id]], do: :ok, else: error(:invalid)
    else
      error(:invalid)
    end
  end

  defp context_repo(%{repo: repo, principal_id: principal, owner_scope_id: owner})
       when is_atom(repo) do
    with {:ok, _} <- Singularity.Core.Types.canonical_uuid(%{principal: principal}, :principal),
         {:ok, _} <- Singularity.Core.Types.canonical_uuid(%{owner: owner}, :owner),
         do: {:ok, repo}
  end

  defp context_repo(_), do: error(:invalid)

  defp bounded(set) do
    if Enum.all?(
         [set.attachments, set.citations, set.targets, set.fragments],
         &(length(&1) <= 100)
       ),
       do: :ok,
       else: error(:invalid)
  end

  defp collect(values, constructor) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case constructor.(value) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, _} = failure -> {:halt, failure}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, _} = failure -> failure
    end
  end

  defp error(code), do: {:error, Error.new(code)}
end
