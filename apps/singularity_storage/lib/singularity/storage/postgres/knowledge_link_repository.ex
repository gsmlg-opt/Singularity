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
    NoteCitation,
    NoteSourceSet,
    SourceLocator
  }

  alias Singularity.Storage.{SafeSQL, ScopedRepo}
  alias Singularity.Storage.Postgres.{KnowledgeError, UUID}
  alias Singularity.Storage.Schema.Content.NoteAttachment, as: StoredAttachment
  alias Singularity.Storage.Schema.Content.NoteCitation, as: StoredCitation
  alias Singularity.Storage.Schema.Content.DocumentFragment, as: StoredFragment

  @constraints "content.note_attachments_note_fkey, content.note_attachments_target_fkey, content.note_attachments_source_set_check, content.note_citations_note_fkey, content.note_citations_fragment_fkey, content.note_citations_source_set_check"

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

  defp persist(repo, context, set, %{attachments: [], citations: []}) do
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

    read_set(repo, context, set.note_resource_id, set.note_resource_version_id)
  end

  defp persist(_repo, _context, set, old) do
    if set.attachments == old.attachments and set.citations == old.citations,
      do: {:ok, old},
      else: error(:conflict)
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
    with {:ok, _} <-
           collect(witness_targets(set), fn target ->
             with {:ok, actual} <-
                    target_value(
                      repo,
                      set.owner_scope_id,
                      target.resource_id,
                      target.resource_version_id,
                      true
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
