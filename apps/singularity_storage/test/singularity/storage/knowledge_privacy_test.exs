defmodule Singularity.Storage.KnowledgePrivacyTest do
  use Singularity.Storage.DataCase, async: false
  import ExUnit.CaptureLog
  @moduletag :integration

  alias Singularity.Core.{
    DocumentCompletion,
    DocumentFragment,
    Error,
    NoteAttachment,
    NoteCitation,
    NoteSourceSet,
    Relationship,
    Tag
  }

  alias Singularity.Storage.{
    Fixtures,
    KnowledgeFixtures,
    KnowledgeTestGrants,
    MigrationRepo,
    ScopedRepo
  }

  alias Singularity.Storage.Postgres.{
    DocumentRepository,
    KnowledgeLinkRepository,
    RelationshipRepository,
    TagRepository
  }

  @canaries %{
    title: "CANARY_DOCUMENT_TITLE_7021",
    body: "CANARY_FRAGMENT_BODY_7022",
    filename: "CANARY_SOURCE_FILENAME_7023.txt",
    tag: "CANARY_TAG_DISPLAY_7024",
    label: "CANARY_ATTACHMENT_LABEL_7025",
    heading: "CANARY_LOCATOR_HEADING_7026"
  }
  @denial [:singularity, :authorization, :rls_denial]

  setup do
    source = KnowledgeFixtures.prepared_source!()

    binary_source =
      Map.new(source, fn {key, value} ->
        {key,
         if(String.ends_with?(Atom.to_string(key), "_id"),
           do: Ecto.UUID.dump!(value),
           else: value
         )}
      end)

    note = KnowledgeFixtures.note!(binary_source)

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "UPDATE content.asset_metadata SET original_filename=$1, declared_media_type='text/markdown', detected_media_type='text/markdown' WHERE asset_id=$2",
        [@canaries.filename, binary_source.asset_id]
      )

      filename = @canaries.filename

      assert %{rows: [[^filename]]} =
               query!(
                 MigrationRepo,
                 "SELECT original_filename FROM content.asset_metadata WHERE asset_id=$1",
                 [binary_source.asset_id]
               )
    end)

    # Digest injection is an isolated source fixture, not live custody verification.
    context =
      KnowledgeFixtures.document_context(source)
      |> Map.put(:correlation_id, Ecto.UUID.generate())

    command = KnowledgeFixtures.document_command(source, %{title: @canaries.title})
    command = %{command | source: %{command.source | media_type: "text/markdown"}}
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach_many(
        handler,
        [@denial, RequestRepo.config()[:telemetry_prefix] ++ [:query]],
        &__MODULE__.handle_event/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    %{source: source, context: context, command: command, note: note}
  end

  test "Document and Link success and failure keep source content out of diagnostic surfaces",
       c do
    logs =
      capture_log(fn ->
        grants(fn ->
          {document, fragment, completion} = complete_document(c)

          assert_private_error(
            DocumentRepository.create_pending(
              c.context,
              %{c.command | title: @canaries.title <> " changed"}
            ),
            :conflict
          )

          assert_private_error(
            DocumentRepository.complete(
              c.context,
              %{completion | adapter_name: "other"}
            ),
            :conflict
          )

          identity = %{
            note_resource_id: Ecto.UUID.load!(c.note.resource_id),
            note_resource_version_id: Ecto.UUID.load!(c.note.resource_version_id),
            owner_scope_id: c.context.owner_scope_id,
            classification: :private
          }

          {:ok, attachment} =
            NoteAttachment.new(
              Map.merge(identity, %{
                attachment_id: Ecto.UUID.generate(),
                target_resource_id: c.source.resource_id,
                target_resource_version_id: c.source.resource_version_id,
                target_kind: :asset,
                role: :source,
                ordinal: 0,
                label: @canaries.label
              })
            )

          {:ok, citation} =
            NoteCitation.new(
              Map.merge(identity, %{
                citation_id: Ecto.UUID.generate(),
                source_resource_id: document.resource_id,
                source_resource_version_id: document.resource_version_id,
                fragment_id: fragment.fragment_id,
                locator: fragment.locator,
                ordinal: 0
              })
            )

          targets =
            [
              target(c.source.resource_id, c.source.resource_version_id, c, :asset),
              target(document.resource_id, document.resource_version_id, c, :document)
            ]
            |> Enum.sort_by(&{&1.resource_id, &1.resource_version_id})

          {:ok, set} =
            NoteSourceSet.new(
              Map.merge(identity, %{
                attachments: [attachment],
                citations: [citation],
                fragments: [fragment],
                targets: targets
              })
            )

          assert {:ok, ^set} =
                   transact(c, fn ->
                     KnowledgeLinkRepository.insert_set(c.context, set)
                   end)

          assert {:ok, ^set} =
                   KnowledgeLinkRepository.list_set(
                     c.context,
                     set.note_resource_id,
                     set.note_resource_version_id
                   )

          assert hd(set.attachments).label == @canaries.label
          assert hd(set.fragments).text == @canaries.body
          assert hd(set.citations).locator.fields.heading_path == [@canaries.heading]
          changed = %{set | attachments: [%{attachment | label: @canaries.label <> " changed"}]}

          assert_private_error(
            transact(c, fn ->
              KnowledgeLinkRepository.insert_set(c.context, changed)
            end),
            :conflict
          )
        end)

        # A real denied adapter call exercises the bounded application event.
        assert_private_error(DocumentRepository.create_pending(c.context, c.command), :forbidden)
      end)

    assert_receive {:knowledge_telemetry, @denial, %{count: 1}, %{repo: :request}}
    assert_clean(logs)
    assert_clean(drain_events())
    assert_clean(effects(c))
  end

  test "Tag and Relationship success and failure audit identifiers without canonical content",
       c do
    logs =
      capture_log(fn ->
        grants(fn ->
          {document, _, _} = complete_document(c)

          {:ok, tag} =
            Tag.new(%{
              tag_id: Ecto.UUID.generate(),
              owner_scope_id: c.context.owner_scope_id,
              classification: :private,
              display_value: @canaries.tag
            })

          assert {:ok, ^tag} = TagRepository.resolve(c.context, tag)
          assert :ok = TagRepository.attach(c.context, document.resource_id, tag.tag_id)
          assert {:ok, [^tag]} = TagRepository.list(c.context, document.resource_id)
          assert tag.display_value == @canaries.tag

          assert_private_error(
            TagRepository.resolve(
              c.context,
              %{tag | normalized_key: "invalid"}
            ),
            :invalid
          )

          {:ok, edge} =
            Relationship.new(%{
              relationship_id: Ecto.UUID.generate(),
              source_resource_id: Ecto.UUID.load!(c.note.resource_id),
              target_resource_id: document.resource_id,
              owner_scope_id: c.context.owner_scope_id,
              classification: :private,
              type: :references
            })

          assert {:ok, ^edge} = RelationshipRepository.relate(c.context, edge)

          assert {:ok, [^edge]} =
                   RelationshipRepository.outgoing(c.context, edge.source_resource_id)

          assert_private_error(
            RelationshipRepository.relate(
              c.context,
              %{edge | target_resource_version_id: document.resource_version_id}
            ),
            :conflict
          )
        end)
      end)

    assert_clean(logs)
    assert_clean(drain_events())
    rows = effects(c)

    assert Enum.any?(rows["audit.events"], fn [row] ->
             row["operation"] == "knowledge.tag_created"
           end)

    assert Enum.any?(rows["audit.events"], fn [row] ->
             row["operation"] == "knowledge.related"
           end)

    assert_clean(rows)
  end

  defp complete_document(c) do
    assert {:ok, document} = DocumentRepository.create_pending(c.context, c.command)
    assert document.title == @canaries.title

    assert {:ok, _} =
             DocumentRepository.claim(c.context, document.resource_version_id, 0, "plain", 1)

    identity =
      Map.take(document, [:resource_id, :resource_version_id, :owner_scope_id, :classification])

    {:ok, fragment} =
      DocumentFragment.new(
        Map.merge(identity, %{
          ordinal: 0,
          text: @canaries.body,
          locator: %{
            "version" => 1,
            "kind" => "markdown",
            "heading_path" => [@canaries.heading],
            "start_line" => 1,
            "end_line" => 1
          }
        })
      )

    {:ok, completion} =
      DocumentCompletion.new(
        Map.merge(identity, %{
          generation: 1,
          outcome: :ready,
          adapter_name: "plain",
          format_version: 1,
          finished_at: DateTime.utc_now(:microsecond),
          media_type: "text/markdown",
          fragments: [fragment],
          extracted_text_digest: :crypto.hash(:sha256, @canaries.body)
        })
      )

    assert {:ok, ready} = DocumentRepository.complete(c.context, completion)

    assert {:ok, ^ready} =
             DocumentRepository.get_version(
               c.context,
               document.resource_id,
               document.resource_version_id
             )

    assert ready.fragments == [fragment]
    assert fragment.text == @canaries.body
    {ready, fragment, completion}
  end

  defp target(resource, version, c, kind) do
    value = %{
      resource_id: resource,
      resource_version_id: version,
      owner_scope_id: c.context.owner_scope_id,
      classification: :private,
      kind: kind
    }

    if kind == :document, do: Map.put(value, :state, :ready), else: value
  end

  defp grants(fun) do
    KnowledgeTestGrants.with_grants(
      ~w(document_versions note_attachments note_citations tags resource_tags relationships),
      fn ->
        KnowledgeTestGrants.with_receipt_grants(fn ->
          KnowledgeTestGrants.with_lifecycle_grants(fn ->
            KnowledgeTestGrants.with_fragment_read_grants(fun)
          end)
        end)
      end
    )
  end

  defp transact(c, fun),
    do:
      ScopedRepo.transact(
        RequestRepo,
        %{principal_id: c.context.principal_id, vault_id: c.context.owner_scope_id},
        fn _ -> fun.() end
      )

  defp assert_private_error(result, code) do
    assert {:error, %Error{code: ^code, message: nil, details: details, retryable?: false}} =
             result

    assert details == %{}
    assert_clean(result)
  end

  defp effects(c),
    do:
      Fixtures.with_owner(fn ->
        Map.new(~w(audit.events core.outbox_events jobs.job_submissions), fn table ->
          {table,
           query!(MigrationRepo, "SELECT to_jsonb(row) FROM #{table} row WHERE vault_id=$1", [
             Ecto.UUID.dump!(c.context.owner_scope_id)
           ]).rows}
        end)
      end)

  def handle_event(event, measurements, metadata, owner),
    do: send(owner, {:knowledge_telemetry, event, measurements, metadata})

  defp drain_events do
    receive do
      {:knowledge_telemetry, event, measurements, metadata} ->
        [{event, measurements, metadata} | drain_events()]
    after
      0 -> []
    end
  end

  defp assert_clean(value) do
    rendered = inspect(value, limit: :infinity, printable_limit: :infinity)
    for canary <- Map.values(@canaries), do: refute(rendered =~ canary)
  end
end
