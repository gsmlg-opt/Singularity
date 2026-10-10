defmodule Singularity.Storage.Postgres.NoteSources do
  @moduledoc false

  alias Singularity.Core.{Error, NoteAttachmentReference, NoteCitationReference, SourceLocator}
  alias Singularity.Storage.SafeSQL
  alias Singularity.Storage.Postgres.{KnowledgeError, KnowledgeLinkRepository, UUID}

  # Only the winning Note receipt callback prepares this metadata. Immutable
  # parent membership is authenticated against its containing typed Note/seal;
  # no target content or caller-provided retention flag is read.
  def prepare(repo, intent, resource_id) do
    context = context(repo, intent)

    with :ok <- scope(repo, intent),
         :ok <- UUID.validate(resource_id),
         {:ok, parents} <- parents(context, intent, resource_id),
         {:ok, attachments} <-
           resolve(intent.snapshot.attachments, parents, :attachments, NoteAttachmentReference),
         {:ok, citations} <-
           resolve(intent.snapshot.citations, parents, :citations, NoteCitationReference),
         :ok <- bounds(attachments, citations),
         false <-
           Enum.any?(identities(attachments, citations), fn {id, _} -> id == resource_id end),
         {:ok, targets} <- targets(repo, intent.vault_id, attachments, citations),
         assets <- assets(repo, intent.vault_id, targets) do
      new_attachments = Enum.reject(attachments, &retained?(&1, parents, :attachments))
      new_citations = Enum.reject(citations, &retained?(&1, parents, :citations))

      {:ok,
       %{
         resource_id: resource_id,
         owner_scope_id: intent.vault_id,
         attachments: attachments,
         citations: citations,
         parents: parents,
         targets: targets,
         assets: assets,
         new_attachments: new_attachments,
         new_citations: new_citations
       }}
    else
      true -> invalid()
      {:error, _} = error -> error
    end
  rescue
    exception -> {:error, KnowledgeError.from(exception)}
  end

  def lock(repo, intent, prepared) do
    with :ok <- scope(repo, intent), true <- prepared.owner_scope_id == intent.vault_id do
      owner = uuid(intent.vault_id)
      asset_ids = Enum.map(prepared.assets, fn [id, _] -> id end)

      %{rows: locked_assets} =
        SafeSQL.query!(
          repo,
          "SELECT id,asset_object_id FROM content.assets WHERE id=ANY($1::uuid[]) AND vault_id=$2 ORDER BY id FOR SHARE",
          [asset_ids, owner]
        )

      if locked_assets != prepared.assets do
        {:error, Error.new(:conflict)}
      else
        object_ids =
          prepared.assets
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
          [prepared.resource_id | Enum.map(prepared.targets, & &1.resource_id)]
          |> Enum.uniq()
          |> Enum.sort()
          |> Enum.map(&uuid/1)

        %{rows: locked_resources} =
          SafeSQL.query!(
            repo,
            "SELECT id FROM content.resources WHERE id=ANY($1::uuid[]) AND vault_id=$2 ORDER BY id FOR UPDATE",
            [resources, owner]
          )

        Enum.each(locked_resources, fn [id] ->
          SafeSQL.query!(
            repo,
            "SELECT pg_advisory_xact_lock(hashtextextended('singularity.note.aggregate:' || $1::text,0))",
            [Ecto.UUID.load!(id)]
          )
        end)

        versions =
          (Enum.map(prepared.targets, & &1.resource_version_id) ++
             Enum.map(prepared.parents, & &1.version_id))
          |> Enum.uniq()
          |> Enum.sort()
          |> Enum.map(&uuid/1)

        SafeSQL.query!(
          repo,
          "SELECT id FROM content.resource_versions WHERE id=ANY($1::uuid[]) AND vault_id=$2 ORDER BY id FOR SHARE",
          [versions, owner]
        )

        asset_versions =
          prepared.targets
          |> Enum.filter(&(&1.kind == :asset))
          |> Enum.map(&uuid(&1.resource_version_id))
          |> Enum.sort()

        SafeSQL.query!(
          repo,
          "SELECT asset_id FROM content.resource_assets WHERE resource_version_id=ANY($1::uuid[]) AND vault_id=$2 ORDER BY resource_version_id,asset_id FOR SHARE",
          [asset_versions, owner]
        )

        :ok
      end
    else
      false -> invalid()
      {:error, _} = error -> error
    end
  rescue
    exception -> {:error, KnowledgeError.from(exception)}
  end

  def revalidate(repo, intent, prepared) do
    context = context(repo, intent)
    new_ids = identities(prepared.new_attachments, prepared.new_citations) |> MapSet.new()

    with :ok <- scope(repo, intent),
         {:ok, _} <-
           collect(prepared.targets, fn target ->
             live? = MapSet.member?(new_ids, {target.resource_id, target.resource_version_id})

             with {:ok, actual} <-
                    KnowledgeLinkRepository.revalidate_target(
                      context,
                      target.resource_id,
                      target.resource_version_id,
                      live?
                    ),
                  true <- actual.kind == target.kind do
               {:ok, actual}
             else
               false -> invalid()
               {:error, _} = error -> error
             end
           end),
         {:ok, _} <- collect(prepared.citations, &citation_witness(repo, intent.vault_id, &1)) do
      :ok
    end
  rescue
    exception -> {:error, KnowledgeError.from(exception)}
  end

  def insert(repo, intent, prepared, resource_id, version) do
    if Enum.all?(prepared.parents, &(&1.revision < version.revision)) and
         version.resource_id == resource_id and version.vault_id == intent.vault_id and
         version.classification == :private do
      KnowledgeLinkRepository.insert_composed_members(
        context(repo, intent),
        resource_id,
        version.id,
        prepared.attachments,
        prepared.citations
      )
    else
      invalid()
    end
  end

  # Task 4 can authorize these per-member-new references inside the same
  # winning receipt callback. Historical copies need no new source read grant.
  def new_members(prepared),
    do: %{attachments: prepared.new_attachments, citations: prepared.new_citations}

  defp parents(context, intent, resource_id) do
    ids =
      [intent.snapshot.parent_version_id, intent.snapshot.merge_parent_version_id]
      |> Enum.reject(&is_nil/1)

    collect(ids, fn version_id ->
      with {:ok, parent} <-
             KnowledgeLinkRepository.read_membership(context, resource_id, version_id) do
        {:ok, Map.put(parent, :version_id, version_id)}
      end
    end)
  end

  defp resolve(:inherit, [parent | _], field, _module), do: {:ok, Map.fetch!(parent, field)}
  defp resolve(:inherit, [], _field, _module), do: invalid()

  defp resolve(references, _parents, _field, module) when is_list(references),
    do: collect(references, &module.new/1)

  defp resolve(_, _, _, _), do: invalid()

  defp retained?(reference, parents, field),
    do:
      Enum.any?(parents, fn parent -> Enum.any?(Map.fetch!(parent, field), &(&1 == reference)) end)

  defp bounds(attachments, citations) do
    valid? =
      length(attachments) <= 100 and length(citations) <= 100 and
        length(Enum.uniq_by(attachments, & &1.attachment_id)) == length(attachments) and
        length(Enum.uniq_by(attachments, &{&1.target_resource_version_id, &1.role})) ==
          length(attachments) and
        length(Enum.uniq_by(citations, & &1.citation_id)) == length(citations) and
        length(identities(attachments, citations)) <= 100 and
        length(Enum.uniq_by(citations, & &1.fragment_id)) <= 100

    if valid?, do: :ok, else: invalid()
  end

  defp identities(attachments, citations) do
    (Enum.map(attachments, &{&1.target_resource_id, &1.target_resource_version_id}) ++
       Enum.map(citations, &{&1.source_resource_id, &1.source_resource_version_id}))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp targets(repo, owner, attachments, citations) do
    expected =
      Enum.map(
        attachments,
        &{&1.target_resource_id, &1.target_resource_version_id, &1.target_kind}
      ) ++
        Enum.map(citations, &{&1.source_resource_id, &1.source_resource_version_id, :document})

    collect(Enum.uniq(expected) |> Enum.sort(), fn {resource, version, kind} ->
      %{rows: rows} =
        SafeSQL.query!(
          repo,
          """
          SELECT r.kind FROM content.resources r
          JOIN content.resource_versions v ON (v.resource_id,v.vault_id,v.classification)=(r.id,r.vault_id,r.classification)
          WHERE (r.id,v.id,r.vault_id,r.classification)=($1,$2,$3,'private') AND
            ((r.kind='note' AND EXISTS(SELECT 1 FROM content.note_versions n WHERE (n.resource_version_id,n.resource_id,n.vault_id,n.classification)=(v.id,r.id,r.vault_id,r.classification))) OR
             (r.kind='document' AND EXISTS(SELECT 1 FROM content.document_versions d WHERE (d.resource_version_id,d.resource_id,d.vault_id,d.classification)=(v.id,r.id,r.vault_id,r.classification))) OR
             (r.kind='asset' AND EXISTS(SELECT 1 FROM content.assets a WHERE a.resource_version_id=v.id AND a.vault_id=r.vault_id AND a.classification='private')))
          """,
          [uuid(resource), uuid(version), uuid(owner)]
        )

      case rows do
        [[actual]] ->
          if actual == Atom.to_string(kind),
            do: {:ok, %{resource_id: resource, resource_version_id: version, kind: kind}},
            else: invalid()

        [] ->
          {:error, Error.new(:not_found)}
      end
    end)
  end

  defp assets(repo, owner, targets) do
    versions =
      targets
      |> Enum.filter(&(&1.kind == :asset))
      |> Enum.map(&uuid(&1.resource_version_id))
      |> Enum.sort()

    SafeSQL.query!(
      repo,
      "SELECT id,asset_object_id FROM content.assets WHERE resource_version_id=ANY($1::uuid[]) AND vault_id=$2 ORDER BY id",
      [versions, uuid(owner)]
    ).rows
  end

  defp citation_witness(repo, owner, reference) do
    %{rows: rows} =
      SafeSQL.query!(
        repo,
        "SELECT locator FROM content.document_fragments WHERE (id,resource_id,resource_version_id,vault_id,classification)=($1,$2,$3,$4,'private')",
        [
          reference.fragment_id,
          uuid(reference.source_resource_id),
          uuid(reference.source_resource_version_id),
          uuid(owner)
        ]
      )

    if rows == [[SourceLocator.to_map(reference.locator)]], do: {:ok, reference}, else: invalid()
  end

  defp scope(repo, intent) do
    if repo.in_transaction?() do
      %{rows: rows} =
        SafeSQL.query!(
          repo,
          "SELECT current_setting('singularity.principal_id',true),current_setting('singularity.vault_id',true)",
          []
        )

      if rows == [[intent.principal_id, intent.vault_id]], do: :ok, else: invalid()
    else
      invalid()
    end
  end

  defp context(repo, intent),
    do: %{repo: repo, principal_id: intent.principal_id, owner_scope_id: intent.vault_id}

  defp uuid(value), do: Ecto.UUID.dump!(value)
  defp invalid, do: {:error, Error.new(:invalid)}

  defp collect(values, callback) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case callback.(value) do
        {:ok, converted} -> {:cont, {:ok, [converted | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end
end
