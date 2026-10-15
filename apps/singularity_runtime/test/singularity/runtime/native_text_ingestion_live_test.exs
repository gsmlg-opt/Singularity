defmodule Singularity.Runtime.NativeTextIngestionLiveTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias Singularity.Core.{Error, StageRef}
  alias Singularity.Runtime.{Api, NativeAssetFixture}

  test "owned native infrastructure authenticates and preserves binary publication" do
    NativeAssetFixture.with_fixture(fn fixture ->
      upload =
        NativeAssetFixture.upload!(fixture, "application/pdf", ["%PDF-1.7\n"], "original.pdf")

      NativeAssetFixture.verify_and_finalize!()

      assert %{rows: [["available", 3, "finalized", "pending", nil]]} =
               NativeAssetFixture.observe!(
                 """
                 SELECT asset.state, asset.state_revision, stage.state,
                   metadata.extraction_state, metadata.extractor_version
                 FROM content.assets asset
                 JOIN content.asset_stages stage ON stage.asset_id = asset.id
                 JOIN content.asset_metadata metadata ON metadata.asset_id = asset.id
                 WHERE asset.id = $1
                 """,
                 [Ecto.UUID.dump!(upload.asset_id)]
               )

      assert NativeAssetFixture.repo_identities() == fixture.repositories
    end)
  end

  for {label, media_type, chunks} <- [
        {"empty", "text/plain", []},
        {"plain", "text/plain", ["native original\r\n"]},
        {"Unicode", "text/plain", [<<0xEF>>, <<0xBB, 0xBF, 0xE4>>, <<0xB8, 0xAD>>, "é\r\n"]},
        {"Markdown", "text/markdown",
         ["# Native original\r\n", "[label](https://example.test)\n"]}
      ] do
    test "genuine #{label} upload publishes ready metadata without binary extraction work" do
      media_type = unquote(media_type)
      chunks = unquote(chunks)
      bytes = IO.iodata_to_binary(chunks)

      NativeAssetFixture.with_fixture(fn fixture ->
        upload = NativeAssetFixture.upload!(fixture, media_type, chunks)
        NativeAssetFixture.verify_and_finalize!()

        # This assertion must first be RED against the old available/pending
        # finalizer, after actual authenticated upload/verify/publish succeeds.
        assert %{
                 rows: [
                   [
                     "ready",
                     5,
                     "finalized",
                     "completed",
                     "upload_text_v1",
                     ^media_type,
                     size,
                     true,
                     nil,
                     nil,
                     nil
                   ]
                 ]
               } =
                 NativeAssetFixture.observe!(
                   """
                   SELECT asset.state, asset.state_revision, stage.state,
                     metadata.extraction_state, metadata.extractor_version,
                     metadata.detected_media_type, metadata.plaintext_byte_size,
                     metadata.completed_at IS NOT NULL, metadata.pdf_header_version,
                     metadata.image_width, metadata.image_height
                   FROM content.assets asset
                   JOIN content.asset_stages stage ON stage.asset_id = asset.id
                   JOIN content.asset_metadata metadata ON metadata.asset_id = asset.id
                   WHERE asset.id = $1
                   """,
                   [Ecto.UUID.dump!(upload.asset_id)]
                 )

        assert size == byte_size(bytes)

        assert {:ok, summary} = Api.asset_summary(fixture.session, upload.asset_id)
        assert summary.id == upload.asset_id
        assert summary.state == :ready
        assert summary.state_revision == 5
        assert summary.detected_media_type == media_type

        assert %{rows: [[true, ^media_type, ^size]]} =
                 NativeAssetFixture.observe!(
                   """
                   SELECT source.vault_id = asset.vault_id,
                     source.declared_media_type, source.byte_size
                   FROM content.source_references source
                   JOIN content.assets asset ON asset.resource_version_id = source.resource_version_id
                   WHERE asset.id = $1 AND source.resource_version_id = $2
                   """,
                   [
                     Ecto.UUID.dump!(upload.asset_id),
                     Ecto.UUID.dump!(summary.resource_version_id)
                   ]
                 )

        # Unfiltered media listing exercises the existing projection contract.
        # Explicit text MIME filters are a separate, unchanged query contract.
        assert {:ok, %{items: [listed], next_cursor: nil}} =
                 Api.list_assets(fixture.session, %{state: :ready})

        assert listed.id == summary.id
        assert listed.resource_version_id == summary.resource_version_id
        assert listed.detected_media_type == media_type

        assert %{rows: [[0, 0]]} =
                 NativeAssetFixture.observe!(
                   """
                   SELECT
                     (SELECT count(*) FROM core.outbox_events WHERE event_type = 'asset.metadata_requested'
                       AND payload->>'asset_id' = $1),
                     (SELECT count(*) FROM jobs.oban_jobs WHERE args->>'job_type' = 'asset_metadata'
                       AND args->'payload'->>'asset_id' = $1)
                   """,
                   [upload.asset_id]
                 )

        assert {:ok,
                %{
                  status: 200,
                  body: ^bytes,
                  content_length: ^size,
                  detected_media_type: ^media_type
                }} = Api.download(fixture.session, upload.asset_id, nil)

        assert NativeAssetFixture.repo_identities() == fixture.repositories
      end)
    end
  end

  test "identical plain and Markdown originals share only their real published object" do
    bytes = "# Same original\r\n" <> "é and 中\n"

    NativeAssetFixture.with_fixture(fn fixture ->
      plain = NativeAssetFixture.upload!(fixture, "text/plain", [bytes], "plain.txt")
      NativeAssetFixture.verify_and_finalize!()
      markdown = NativeAssetFixture.upload!(fixture, "text/markdown", [bytes], "markdown.md")
      NativeAssetFixture.verify_and_finalize!()

      assert plain.asset_id != markdown.asset_id

      assert %{rows: [[true, true, "text/plain", "text/markdown", "completed", "completed"]]} =
               NativeAssetFixture.observe!(
                 """
                 SELECT first.asset_object_id = second.asset_object_id,
                   first.resource_version_id <> second.resource_version_id,
                   plain.declared_media_type, markdown.declared_media_type,
                   plain.extraction_state, markdown.extraction_state
                 FROM content.assets first
                 JOIN content.assets second ON second.id = $2
                 JOIN content.asset_metadata plain ON plain.asset_id = first.id
                 JOIN content.asset_metadata markdown ON markdown.asset_id = second.id
                 WHERE first.id = $1
                 """,
                 [Ecto.UUID.dump!(plain.asset_id), Ecto.UUID.dump!(markdown.asset_id)]
               )

      for {upload, media_type} <- [{plain, "text/plain"}, {markdown, "text/markdown"}] do
        assert {:ok, %{body: ^bytes, detected_media_type: ^media_type}} =
                 Api.download(fixture.session, upload.asset_id, nil)

        assert {:ok, %{state: :ready, state_revision: 5, detected_media_type: ^media_type}} =
                 Api.asset_summary(fixture.session, upload.asset_id)
      end

      assert {:ok, %{items: items, next_cursor: nil}} =
               Api.list_assets(fixture.session, %{state: :ready})

      assert Map.new(items, &{&1.id, &1.detected_media_type}) == %{
               plain.asset_id => "text/plain",
               markdown.asset_id => "text/markdown"
             }
    end)
  end

  test "a disconnected native text producer removes real partial ciphertext before abandonment" do
    NativeAssetFixture.with_fixture(fn fixture ->
      parent = self()
      reference = make_ref()

      {producer, producer_monitor} =
        spawn_monitor(fn ->
          parent_monitor = Process.monitor(parent)

          # One full encryption chunk forces real ciphertext to disk before
          # EOF. Do not replace physical cleanup with an empty-stage witness.
          pending =
            NativeAssetFixture.begin_upload!(
              fixture,
              "text/plain",
              [:binary.copy("a", 4_194_304)]
            )

          send(parent, {reference, :upload_started, pending})

          receive do
            {^reference, :disconnect} -> :ok
            {:DOWN, ^parent_monitor, :process, ^parent, _reason} -> :ok
          after
            15_000 -> flunk("native text producer did not receive its release")
          end
        end)

      try do
        assert_receive {^reference, :upload_started, pending}, 15_000
        upload_session = pending.handle.session
        assert is_pid(upload_session)
        session_monitor = Process.monitor(upload_session)

        assert %{rows: [[stage_id, "open", "staging", true]]} =
                 NativeAssetFixture.observe!(
                   """
                   SELECT stage.id::text, stage.state, asset.state, upload_grant.consumed_at IS NOT NULL
                   FROM content.asset_stages stage
                   JOIN content.assets asset ON asset.id = stage.asset_id
                   JOIN content.upload_grants upload_grant ON upload_grant.id = stage.upload_grant_id
                   WHERE asset.id = $1
                   """,
                   [Ecto.UUID.dump!(pending.asset_id)]
                 )

        {storage, context} = Singularity.Runtime.StorageAdapter.configured()
        stage_ref = %StageRef{stage_id: stage_id}
        assert {:ok, %{sealed?: false, byte_size: size}} = storage.stat_stage(context, stage_ref)
        assert size > 0

        send(producer, {reference, :disconnect})
        assert_receive {:DOWN, ^session_monitor, :process, ^upload_session, :normal}, 15_000

        assert {:error, %Error{code: :not_found}} = storage.stat_stage(context, stage_ref)

        assert %{rows: [["abandoned", "controller_disconnected", "staging", 0, true, 0, 0]]} =
                 NativeAssetFixture.observe!(
                   """
                   SELECT stage.state, stage.failure_code, asset.state, asset.state_revision,
                     upload_grant.consumed_at IS NOT NULL,
                     (SELECT count(*) FROM content.asset_metadata WHERE asset_id = asset.id),
                     (SELECT count(*) FROM core.outbox_events
                       WHERE payload->>'asset_id' = asset.id::text)
                   FROM content.asset_stages stage
                   JOIN content.assets asset ON asset.id = stage.asset_id
                   JOIN content.upload_grants upload_grant ON upload_grant.id = stage.upload_grant_id
                   WHERE asset.id = $1
                   """,
                   [Ecto.UUID.dump!(pending.asset_id)]
                 )

        assert NativeAssetFixture.repo_identities() == fixture.repositories
      after
        send(producer, {reference, :disconnect})
        assert_receive {:DOWN, ^producer_monitor, :process, ^producer, :normal}, 15_000
      end
    end)
  end
end
