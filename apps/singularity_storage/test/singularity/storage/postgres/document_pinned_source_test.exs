defmodule Singularity.Storage.Postgres.DocumentPinnedSourceTest do
  use Singularity.Storage.DataCase, async: false
  @moduletag :integration

  alias Singularity.Core.Error
  alias Singularity.Storage.{Fixtures, KnowledgeFixtures, KnowledgeTestGrants, MigrationRepo}
  alias Singularity.Storage.Postgres.DocumentPinnedSource

  setup do
    source = KnowledgeFixtures.prepared_source!()

    document =
      KnowledgeFixtures.document!(%{
        source
        | vault_id: Ecto.UUID.dump!(source.vault_id),
          principal_id: Ecto.UUID.dump!(source.principal_id),
          asset_id: Ecto.UUID.dump!(source.asset_id),
          resource_id: Ecto.UUID.dump!(source.resource_id),
          resource_version_id: Ecto.UUID.dump!(source.resource_version_id),
          object_id: Ecto.UUID.dump!(source.object_id)
      })

    context = KnowledgeFixtures.document_context(source)
    %{source: source, document: document, context: context}
  end

  test "live Document retains its pinned source after source Asset deletion", c do
    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "UPDATE content.resource_assets SET released_at=CURRENT_TIMESTAMP WHERE asset_id=$1",
        [Ecto.UUID.dump!(c.source.asset_id)]
      )

      query!(
        MigrationRepo,
        "UPDATE content.resources SET deleted_at=CURRENT_TIMESTAMP WHERE id=$1",
        [Ecto.UUID.dump!(c.source.resource_id)]
      )
    end)

    KnowledgeTestGrants.with_grants(["document_versions"], fn ->
      assert {:ok, binding} =
               DocumentPinnedSource.load_live(
                 RequestRepo,
                 c.context,
                 Ecto.UUID.load!(c.document.resource_id)
               )

      assert binding.object_id == c.source.object_id
      assert binding.object_generation == 1
      assert binding.source_byte_size == c.source.byte_size
      assert binding.source_digest == c.source.digest
      assert binding.media_type == "text/plain"
      assert binding.owner_scope_id == c.source.vault_id
      refute Map.has_key?(binding, :wrapped_dek)

      assert {:error, %Error{code: :not_found}} =
               DocumentPinnedSource.load_live(
                 RequestRepo,
                 %{c.context | owner_scope_id: Ecto.UUID.generate()},
                 Ecto.UUID.load!(c.document.resource_id)
               )

      assert {:error, %Error{code: :not_found}} =
               DocumentPinnedSource.load_live(
                 RequestRepo,
                 Map.delete(c.context, :owner_scope_id),
                 Ecto.UUID.load!(c.document.resource_id)
               )
    end)
  end

  test "tombstoned Document is not publicly readable", c do
    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "UPDATE content.resources SET deleted_at=CURRENT_TIMESTAMP WHERE id=$1",
        [c.document.resource_id]
      )
    end)

    KnowledgeTestGrants.with_grants(["document_versions"], fn ->
      assert {:error, %Error{code: :not_found}} =
               DocumentPinnedSource.load_live(
                 RequestRepo,
                 c.context,
                 Ecto.UUID.load!(c.document.resource_id)
               )
    end)
  end

  test "job lookup requires its extraction event and permits only its active tombstone claim",
       c do
    job_id = Ecto.UUID.generate()
    event!(c, job_id)

    KnowledgeTestGrants.with_grants(["document_versions"], fn ->
      version = Ecto.UUID.load!(c.document.resource_version_id)

      assert {:ok, %{object_id: object_id}} =
               DocumentPinnedSource.load_for_job(RequestRepo, c.context, version, job_id)

      assert object_id == c.source.object_id

      assert {:error, %Error{code: :not_found}} =
               DocumentPinnedSource.load_for_job(
                 RequestRepo,
                 c.context,
                 version,
                 Ecto.UUID.generate()
               )

      KnowledgeTestGrants.with_lifecycle_grants(fn ->
        assert {:ok, _} =
                 Singularity.Storage.Postgres.DocumentRepository.claim(
                   c.context,
                   version,
                   0,
                   job_id,
                   "plain",
                   1
                 )
      end)

      Fixtures.with_owner(fn ->
        query!(
          MigrationRepo,
          "UPDATE content.resources SET deleted_at=CURRENT_TIMESTAMP WHERE id=$1",
          [c.document.resource_id]
        )
      end)

      assert {:ok, %{object_id: ^object_id}} =
               DocumentPinnedSource.load_for_job(RequestRepo, c.context, version, job_id)

      assert {:error, %Error{code: :not_found}} =
               DocumentPinnedSource.load_for_job(
                 RequestRepo,
                 c.context,
                 version,
                 Ecto.UUID.generate()
               )
    end)
  end

  test "mismatched pinned object size is an integrity failure", c do
    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "UPDATE content.asset_objects SET plaintext_byte_size=13 WHERE id=$1",
        [Ecto.UUID.dump!(c.source.object_id)]
      )
    end)

    KnowledgeTestGrants.with_grants(["document_versions"], fn ->
      assert {:error, %Error{code: :integrity_failure}} =
               DocumentPinnedSource.load_live(
                 RequestRepo,
                 c.context,
                 Ecto.UUID.load!(c.document.resource_id)
               )
    end)
  end

  test "pending tombstone and wrong event binding are not job-readable", c do
    job_id = Ecto.UUID.generate()
    event!(c, job_id)
    version = Ecto.UUID.load!(c.document.resource_version_id)

    KnowledgeTestGrants.with_grants(["document_versions"], fn ->
      Fixtures.with_owner(fn ->
        query!(MigrationRepo, "UPDATE core.outbox_events SET payload='{}'::jsonb WHERE id=$1", [
          Ecto.UUID.dump!(job_id)
        ])
      end)

      assert {:error, %Error{code: :not_found}} =
               DocumentPinnedSource.load_for_job(RequestRepo, c.context, version, job_id)

      Fixtures.with_owner(fn ->
        query!(
          MigrationRepo,
          "UPDATE core.outbox_events SET payload=$2::text::jsonb WHERE id=$1",
          [
            Ecto.UUID.dump!(job_id),
            JSON.encode!(%{
              "resource_id" => Ecto.UUID.load!(c.document.resource_id),
              "resource_version_id" => version
            })
          ]
        )

        query!(
          MigrationRepo,
          "UPDATE content.resources SET deleted_at=CURRENT_TIMESTAMP WHERE id=$1",
          [c.document.resource_id]
        )
      end)

      assert {:error, %Error{code: :not_found}} =
               DocumentPinnedSource.load_for_job(RequestRepo, c.context, version, job_id)
    end)
  end

  test "pending generation rejects a stale extraction event after recovery", c do
    stale_job = Ecto.UUID.generate()
    next_job = Ecto.UUID.generate()
    version = Ecto.UUID.load!(c.document.resource_version_id)
    event!(c, stale_job)

    KnowledgeTestGrants.with_grants(["document_versions"], fn ->
      assert {:ok, _} =
               DocumentPinnedSource.load_for_job(RequestRepo, c.context, version, stale_job)

      KnowledgeTestGrants.with_lifecycle_grants(fn ->
        assert {:ok, _} =
                 Singularity.Storage.Postgres.DocumentRepository.claim(
                   c.context,
                   version,
                   0,
                   stale_job,
                   "plain",
                   1
                 )
      end)

      # Model the guarded recovery transition without waiting for its 180-second deadline.
      Fixtures.with_owner(fn ->
        query!(
          MigrationRepo,
          """
          UPDATE content.document_versions SET state='pending', attempt_generation=2,
            attempt_job_id=NULL, attempt_started_at=NULL, attempt_deadline_at=NULL,
            extraction_adapter=NULL, extraction_format=NULL
          WHERE resource_version_id=$1
          """,
          [c.document.resource_version_id]
        )
      end)

      assert {:error, %Error{code: :not_found}} =
               DocumentPinnedSource.load_for_job(RequestRepo, c.context, version, stale_job)

      event!(c, next_job, 2)

      assert {:ok, _} =
               DocumentPinnedSource.load_for_job(RequestRepo, c.context, version, next_job)
    end)
  end

  defp event!(c, job_id, revision \\ 0) do
    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        """
        INSERT INTO core.outbox_events
          (id,event_type,idempotency_key,vault_id,principal_id,required_capability,
           principal_authorization_epoch,vault_authorization_epoch,classification,
           correlation_id,expected_entity_revision,envelope_version,payload,occurred_at)
        VALUES ($1,'document.extraction_requested',$2,$3,$4,'asset.read',0,0,'private',
                $1,$6,1,$5::text::jsonb,CURRENT_TIMESTAMP)
        """,
        [
          Ecto.UUID.dump!(job_id),
          job_id,
          c.document.vault_id,
          c.document.created_by_principal_id,
          JSON.encode!(%{
            "resource_id" => Ecto.UUID.load!(c.document.resource_id),
            "resource_version_id" => Ecto.UUID.load!(c.document.resource_version_id)
          }),
          revision
        ]
      )
    end)
  end
end
