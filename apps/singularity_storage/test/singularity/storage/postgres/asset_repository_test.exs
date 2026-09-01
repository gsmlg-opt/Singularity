defmodule Singularity.Storage.Postgres.AssetRepositoryTest do
  use Singularity.Storage.DataCase, async: false

  @moduletag :integration

  defmodule CoordinatedSearchRepo do
    @moduledoc false

    alias Singularity.Storage.RequestRepo

    def one(query), do: RequestRepo.one(query)
    def get(schema, id), do: RequestRepo.get(schema, id)

    def insert(changeset, options) do
      coordinator = Process.get(:asset_search_coordinator)
      classification = Ecto.Changeset.get_field(changeset, :classification)

      send(coordinator, {:projection_ready, self(), classification})

      receive do
        {:continue_projection, task_pid} when task_pid == self() ->
          RequestRepo.insert(changeset, options)
      after
        5_000 ->
          raise "timed out waiting to continue coordinated search projection"
      end
    end
  end

  alias Singularity.Core.Asset
  alias Singularity.Core.Error
  alias Singularity.Core.SourceReference
  alias Singularity.Domains.Assets
  alias Singularity.Storage.Fixtures
  alias Singularity.Storage.MigrationRepo
  alias Singularity.Storage.Postgres.AssetRepository
  alias Singularity.Storage.Postgres.AssetSearchStore
  alias Singularity.Storage.Schema.Content.UploadGrant
  alias Singularity.Storage.ScopedRepo

  setup do
    %{one: fixture} = Fixtures.two_vaults!()
    {:ok, fixture: load_ids(fixture)}
  end

  test "concurrent upload idempotency stores one intent, provenance, and outbox event", %{
    fixture: fixture
  } do
    asset_id = Ecto.UUID.generate()
    source_reference_id = Ecto.UUID.generate()
    observed_at = DateTime.utc_now(:microsecond)
    idempotency_key = "upload-intent-#{asset_id}"

    command = %{
      idempotency_key: idempotency_key,
      asset_id: asset_id,
      vault_id: fixture.vault_id,
      resource_version_id: fixture.resource_version_id,
      source_reference_id: source_reference_id,
      resource_version_classification: :private,
      classification: :private,
      principal_id: fixture.principal_id,
      filename: "evidence.bin",
      declared_media_type: "application/octet-stream",
      byte_size: 4,
      digest: "sha256:payload",
      server_observed_at: observed_at,
      client_path: "/Users/alice/Documents/evidence.bin"
    }

    results =
      1..2
      |> Task.async_stream(
        fn _attempt ->
          scoped(fixture, fn repo ->
            Assets.create_upload_intent(
              %{repository: AssetRepository, context: repo},
              command
            )
          end)
        end,
        max_concurrency: 2,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, %Error{code: :conflict}}, &1)) == 1

    scoped(fixture, fn repo ->
      assert count_rows(repo, "content.resources", fixture.vault_id) == 1
      assert count_rows(repo, "content.assets", fixture.vault_id) == 2
      assert count_rows(repo, "core.outbox_events", fixture.vault_id) == 1

      %{rows: [[kind, recorded_at, filename, media_type, byte_size, principal_id, digest]]} =
        query!(
          repo,
          """
          SELECT
            kind,
            observed_at,
            original_filename,
            declared_media_type,
            byte_size,
            principal_id,
            idempotency_key_digest
          FROM content.source_references
          WHERE id = $1
          """,
          [Ecto.UUID.dump!(source_reference_id)]
        )

      assert kind == "browser_upload"
      assert DateTime.compare(recorded_at, observed_at) == :eq
      assert filename == command.filename
      assert media_type == command.declared_media_type
      assert byte_size == command.byte_size
      assert Ecto.UUID.load!(principal_id) == fixture.principal_id
      assert digest == :crypto.hash(:sha256, idempotency_key)

      %{rows: [[source_columns]]} =
        query!(
          repo,
          """
          SELECT array_agg(column_name ORDER BY ordinal_position)
          FROM information_schema.columns
          WHERE table_schema = 'content' AND table_name = 'source_references'
          """
        )

      refute "client_path" in source_columns
      :ok
    end)
  end

  test "upload intent rejects a downgrade from the persisted resource version without effects", %{
    fixture: fixture
  } do
    asset_id = Ecto.UUID.generate()
    source_reference_id = Ecto.UUID.generate()

    command =
      upload_intent_command(
        fixture,
        asset_id,
        source_reference_id,
        "persisted-classification-#{asset_id}",
        DateTime.utc_now(:microsecond)
      )

    assert :ok =
             scoped(fixture, fn repo ->
               %{num_rows: 1} =
                 query!(
                   repo,
                   """
                   UPDATE content.resource_versions
                   SET classification = 'restricted'
                   WHERE id = $1 AND vault_id = $2
                   """,
                   [
                     Ecto.UUID.dump!(fixture.resource_version_id),
                     Ecto.UUID.dump!(fixture.vault_id)
                   ]
                 )

               query!(
                 repo,
                 """
                 UPDATE content.resources
                 SET classification = 'restricted'
                 WHERE id = $1 AND vault_id = $2
                 """,
                 [
                   Ecto.UUID.dump!(fixture.resource_id),
                   Ecto.UUID.dump!(fixture.vault_id)
                 ]
               )

               :ok
             end)

    assert {:error, %Error{code: :forbidden}} =
             scoped(fixture, fn repo ->
               Assets.create_upload_intent(
                 %{repository: AssetRepository, context: repo},
                 command
               )
             end)

    scoped(fixture, fn repo ->
      assert %{rows: [[0, 0, 0, 0]]} =
               query!(
                 repo,
                 """
                 SELECT
                   (SELECT count(*) FROM content.assets WHERE id = $1),
                   (SELECT count(*) FROM content.source_references WHERE id = $2),
                   (SELECT count(*) FROM content.resource_assets WHERE asset_id = $1),
                   (
                     SELECT count(*)
                     FROM core.outbox_events
                     WHERE causation_id = $2
                   )
                 """,
                 [
                   Ecto.UUID.dump!(asset_id),
                   Ecto.UUID.dump!(source_reference_id)
                 ]
               )

      :ok
    end)
  end

  test "upload intent maps a malformed vault UUID to invalid", %{fixture: fixture} do
    command =
      upload_intent_command(
        fixture,
        Ecto.UUID.generate(),
        Ecto.UUID.generate(),
        "malformed-upload-vault",
        DateTime.utc_now(:microsecond)
      )
      |> Map.put(:vault_id, "not-a-vault-uuid")

    assert {:error, %Error{code: :invalid}} =
             scoped(fixture, fn repo ->
               Assets.create_upload_intent(
                 %{repository: AssetRepository, context: repo},
                 command
               )
             end)
  end

  test "every asset repository callback rejects malformed structured UUIDs without effects", %{
    fixture: fixture
  } do
    for {callback, intent, path} <- asset_repository_uuid_cases(fixture),
        invalid_uuid <- invalid_uuids() do
      effects_before = asset_effects(fixture)
      malformed = put_path(intent, path, invalid_uuid)

      assert {:error, %Error{code: :invalid}} =
               scoped(fixture, fn repo ->
                 apply(AssetRepository, callback, [repo, malformed])
               end),
             "expected #{callback} #{inspect(path)}=#{inspect(invalid_uuid)} to be rejected"

      assert asset_effects(fixture) == effects_before
    end
  end

  test "every asset search callback rejects malformed UUIDs without effects", %{
    fixture: fixture
  } do
    attrs = %{
      asset_id: fixture.asset_id,
      resource_version_id: fixture.resource_version_id,
      vault_id: fixture.vault_id,
      classification: :private,
      state: :ready,
      detected_media_type: "application/pdf",
      resource_title: "Invalid UUID Evidence",
      original_filename: "invalid-uuid.pdf"
    }

    cases = [
      {:upsert, :asset_id,
       fn repo, invalid ->
         AssetSearchStore.upsert(repo, Map.put(attrs, :asset_id, invalid))
       end},
      {:upsert, :resource_version_id,
       fn repo, invalid ->
         AssetSearchStore.upsert(repo, Map.put(attrs, :resource_version_id, invalid))
       end},
      {:upsert, :vault_id,
       fn repo, invalid ->
         AssetSearchStore.upsert(repo, Map.put(attrs, :vault_id, invalid))
       end},
      {:delete, :asset_id,
       fn repo, invalid ->
         AssetSearchStore.delete(repo, %{
           asset_id: invalid,
           vault_id: fixture.vault_id
         })
       end},
      {:delete, :vault_id,
       fn repo, invalid ->
         AssetSearchStore.delete(repo, %{
           asset_id: fixture.asset_id,
           vault_id: invalid
         })
       end},
      {:search, :vault_id,
       fn repo, invalid ->
         AssetSearchStore.search(repo, %{vault_id: invalid, query: "", limit: 10})
       end}
    ]

    for {callback, field, invoke} <- cases,
        invalid_uuid <- invalid_uuids() do
      effects_before = asset_effects(fixture)

      assert {:error, %Error{code: :invalid}} =
               scoped(fixture, fn repo -> invoke.(repo, invalid_uuid) end),
             "expected search #{callback} #{field}=#{inspect(invalid_uuid)} to be rejected"

      assert asset_effects(fixture) == effects_before
    end
  end

  test "reusing a source reference id returns a non-retryable conflict", %{fixture: fixture} do
    source_reference_id = Ecto.UUID.generate()
    observed_at = DateTime.utc_now(:microsecond)

    first =
      upload_intent_command(
        fixture,
        Ecto.UUID.generate(),
        source_reference_id,
        "source-reference-first",
        observed_at
      )

    second =
      upload_intent_command(
        fixture,
        Ecto.UUID.generate(),
        source_reference_id,
        "source-reference-second",
        observed_at
      )

    assert {:ok, _intent} =
             scoped(fixture, fn repo ->
               Assets.create_upload_intent(
                 %{repository: AssetRepository, context: repo},
                 first
               )
             end)

    assert {:error, %Error{code: :conflict, retryable?: false}} =
             scoped(fixture, fn repo ->
               Assets.create_upload_intent(
                 %{repository: AssetRepository, context: repo},
                 second
               )
             end)

    scoped(fixture, fn repo ->
      assert count_rows(repo, "content.assets", fixture.vault_id) == 2
      assert count_rows(repo, "content.source_references", fixture.vault_id) == 1
      assert count_rows(repo, "core.outbox_events", fixture.vault_id) == 1
      :ok
    end)
  end

  test "concurrent expected revision transition applies once and replays stale without duplicate effects",
       %{
         fixture: fixture
       } do
    command = %{
      asset_id: fixture.asset_id,
      principal_id: fixture.principal_id,
      classification: :private,
      expected_state_revision: 0,
      to: :uploaded
    }

    adapters = %{
      repository: AssetRepository,
      audit: Singularity.Storage.Postgres.AuditSink,
      outbox: Singularity.Storage.Postgres.Outbox
    }

    results =
      1..2
      |> Task.async_stream(
        fn _attempt ->
          scoped(fixture, fn repo ->
            Assets.transition(Map.put(adapters, :context, repo), command)
          end)
        end,
        max_concurrency: 2,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(
             results,
             &match?({:ok, :applied, %Asset{state: :uploaded, state_revision: 1}}, &1)
           ) == 1

    assert Enum.count(
             results,
             &match?({:ok, :stale, %Asset{state: :uploaded, state_revision: 1}}, &1)
           ) == 1

    scoped(fixture, fn repo ->
      assert count_rows(repo, "audit.events", fixture.vault_id) == 1
      assert count_rows(repo, "core.outbox_events", fixture.vault_id) == 1
      :ok
    end)
  end

  test "asset producer persists distinct principal and vault authorization epochs", %{
    fixture: fixture
  } do
    principal_epoch = 11
    vault_epoch = 23
    asset_id = Ecto.UUID.generate()
    source_reference_id = Ecto.UUID.generate()

    Fixtures.with_owner(fn ->
      Ecto.Adapters.SQL.query!(
        MigrationRepo,
        """
        UPDATE identity.principals
        SET authorization_epoch = $2
        WHERE id = $1
        """,
        [Ecto.UUID.dump!(fixture.principal_id), principal_epoch],
        log: false
      )

      Ecto.Adapters.SQL.query!(
        MigrationRepo,
        """
        UPDATE core.vaults
        SET authorization_epoch = $2
        WHERE id = $1
        """,
        [Ecto.UUID.dump!(fixture.vault_id), vault_epoch],
        log: false
      )
    end)

    command =
      upload_intent_command(
        fixture,
        asset_id,
        source_reference_id,
        "two-axis-epochs-#{asset_id}",
        DateTime.utc_now(:microsecond)
      )

    assert {:ok, _intent} =
             scoped(fixture, fn repo ->
               Assets.create_upload_intent(
                 %{repository: AssetRepository, context: repo},
                 command
               )
             end)

    scoped(fixture, fn repo ->
      assert %{rows: [[^principal_epoch, ^vault_epoch]]} =
               query!(
                 repo,
                 """
                 SELECT
                   principal_authorization_epoch,
                   vault_authorization_epoch
                 FROM core.outbox_events
                 WHERE causation_id = $1
                 """,
                 [Ecto.UUID.dump!(source_reference_id)]
               )

      :ok
    end)
  end

  test "sealed acknowledgement advances the existing upload intent without fabricating crypto metadata",
       %{
         fixture: fixture
       } do
    asset_id = Ecto.UUID.generate()
    source_reference_id = Ecto.UUID.generate()
    observed_at = DateTime.utc_now(:microsecond)
    checksum = "sha256:" <> String.duplicate("ab", 32)

    upload_intent = %{
      idempotency_key: "intent-to-seal-#{asset_id}",
      asset_id: asset_id,
      vault_id: fixture.vault_id,
      resource_version_id: fixture.resource_version_id,
      source_reference_id: source_reference_id,
      resource_version_classification: :private,
      classification: :private,
      principal_id: fixture.principal_id,
      filename: "sealed.bin",
      declared_media_type: "application/octet-stream",
      byte_size: 4,
      digest: checksum,
      server_observed_at: observed_at
    }

    assert {:ok, %{asset: %Asset{state: :staging, state_revision: 0}}} =
             scoped(fixture, fn repo ->
               Assets.create_upload_intent(
                 %{repository: AssetRepository, context: repo},
                 upload_intent
               )
             end)

    command = %{
      asset_id: asset_id,
      vault_id: fixture.vault_id,
      resource_version_id: fixture.resource_version_id,
      identity_id: fixture.principal_id,
      sealed_ref: "sealed://#{fixture.vault_id}/#{asset_id}",
      filename: "sealed.bin",
      content_type: "application/octet-stream",
      byte_size: 4,
      checksum: checksum,
      classification: :private
    }

    adapters = %{
      repository: AssetRepository,
      audit: Singularity.Storage.Postgres.AuditSink,
      outbox: Singularity.Storage.Postgres.Outbox
    }

    assert {:ok,
            %{
              asset: %Asset{
                asset_id: ^asset_id,
                state: :uploaded,
                state_revision: 1,
                metadata: %{
                  "filename" => "sealed.bin",
                  "principal_id" => principal_id,
                  "sealed_ref" => sealed_ref
                }
              },
              audit: %{operation: "asset.uploaded"},
              outbox: %{event_type: "asset.verify_requested"}
            }} =
             scoped(fixture, fn repo ->
               Assets.record_sealed_upload(Map.put(adapters, :context, repo), command)
             end)

    assert principal_id == fixture.principal_id
    assert sealed_ref == command.sealed_ref

    scoped(fixture, fn repo ->
      assert count_rows(repo, "audit.events", fixture.vault_id) == 1
      assert count_rows(repo, "core.outbox_events", fixture.vault_id) == 2

      # Task 8 must persist the real protected digests and ciphertext size.
      # Task 7 must not derive an asset_stages row from the plaintext checksum.
      assert %{rows: [[0]]} =
               query!(
                 repo,
                 "SELECT count(*) FROM content.asset_stages WHERE asset_id = $1",
                 [Ecto.UUID.dump!(asset_id)]
               )

      assert %{rows: [["sealed.bin", "application/octet-stream", 4]]} =
               query!(
                 repo,
                 """
                 SELECT original_filename, declared_media_type, plaintext_byte_size
                 FROM content.asset_metadata
                 WHERE asset_id = $1
                 """,
                 [Ecto.UUID.dump!(asset_id)]
               )

      assert %{rows: [["uploaded", 1]]} =
               query!(
                 repo,
                 "SELECT state, state_revision FROM content.assets WHERE id = $1",
                 [Ecto.UUID.dump!(asset_id)]
               )

      assert %{rows: [[1]]} =
               query!(
                 repo,
                 "SELECT count(*) FROM content.resource_assets WHERE asset_id = $1",
                 [Ecto.UUID.dump!(asset_id)]
               )

      :ok
    end)
  end

  test "upload grant consumption is atomic under concurrent consumers", %{fixture: fixture} do
    grant_id = Ecto.UUID.generate()
    consumed_at = DateTime.utc_now(:microsecond)

    assert :ok =
             scoped(fixture, fn repo ->
               {:ok, _grant} =
                 repo.insert(
                   UploadGrant.create_changeset(%UploadGrant{}, %{
                     id: grant_id,
                     vault_id: fixture.vault_id,
                     session_id: fixture.session_id,
                     principal_id: fixture.principal_id,
                     asset_id: fixture.asset_id,
                     classification: :private,
                     token_digest: :crypto.hash(:sha256, "grant-#{grant_id}"),
                     csrf_token_digest: :crypto.hash(:sha256, "csrf-grant-#{grant_id}"),
                     filename: "evidence.bin",
                     byte_size: 4,
                     declared_media_type: "application/octet-stream",
                     idempotency_key: "grant-#{grant_id}",
                     principal_authorization_epoch: 0,
                     vault_authorization_epoch: 0,
                     expires_at: DateTime.add(consumed_at, 300, :second)
                   })
                 )

               :ok
             end)

    results =
      1..2
      |> Task.async_stream(
        fn _attempt ->
          scoped(fixture, fn repo ->
            AssetRepository.consume_upload_grant(repo, %{
              grant_id: grant_id,
              consumed_at: consumed_at
            })
          end)
        end,
        max_concurrency: 2,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, _intent}, &1)) == 1
    assert Enum.count(results, &match?({:error, %Error{code: :conflict}}, &1)) == 1

    server_consumed_at =
      Enum.find_value(results, fn
        {:ok, %{consumed_at: %DateTime{} = value}} -> value
        _result -> nil
      end)

    scoped(fixture, fn repo ->
      assert %{rows: [[1]]} =
               query!(
                 repo,
                 """
                 SELECT count(*)
                 FROM content.upload_grants
                 WHERE id = $1 AND consumed_at = $2
                 """,
                 [Ecto.UUID.dump!(grant_id), server_consumed_at]
               )

      :ok
    end)
  end

  test "upload grant expiry is evaluated against database time", %{fixture: fixture} do
    grant_id = Ecto.UUID.generate()
    now = DateTime.utc_now(:microsecond)

    assert :ok =
             scoped(fixture, fn repo ->
               {:ok, _grant} =
                 repo.insert(
                   UploadGrant.create_changeset(%UploadGrant{}, %{
                     id: grant_id,
                     vault_id: fixture.vault_id,
                     session_id: fixture.session_id,
                     principal_id: fixture.principal_id,
                     asset_id: fixture.asset_id,
                     classification: :private,
                     token_digest: :crypto.hash(:sha256, "expired-grant-#{grant_id}"),
                     csrf_token_digest: :crypto.hash(:sha256, "csrf-expired-grant-#{grant_id}"),
                     filename: "evidence.bin",
                     byte_size: 4,
                     declared_media_type: "application/octet-stream",
                     idempotency_key: "expired-grant-#{grant_id}",
                     principal_authorization_epoch: 0,
                     vault_authorization_epoch: 0,
                     expires_at: DateTime.add(now, -60, :second)
                   })
                 )

               :ok
             end)

    assert {:error, %Error{code: :conflict}} =
             scoped(fixture, fn repo ->
               AssetRepository.consume_upload_grant(repo, %{
                 grant_id: grant_id,
                 consumed_at: DateTime.add(now, -120, :second)
               })
             end)

    scoped(fixture, fn repo ->
      assert %{rows: [[nil]]} =
               query!(
                 repo,
                 "SELECT consumed_at FROM content.upload_grants WHERE id = $1",
                 [Ecto.UUID.dump!(grant_id)]
               )

      :ok
    end)
  end

  test "upload grant cannot be consumed after expiring within its scoped transaction", %{
    fixture: fixture
  } do
    grant_id = Ecto.UUID.generate()

    assert {:error, %Error{code: :conflict}} =
             scoped(fixture, fn repo ->
               %{rows: [[statement_time]]} =
                 query!(repo, "SELECT statement_timestamp()")

               {:ok, _grant} =
                 repo.insert(
                   UploadGrant.create_changeset(%UploadGrant{}, %{
                     id: grant_id,
                     vault_id: fixture.vault_id,
                     session_id: fixture.session_id,
                     principal_id: fixture.principal_id,
                     asset_id: fixture.asset_id,
                     classification: :private,
                     token_digest: :crypto.hash(:sha256, "expiring-grant-#{grant_id}"),
                     csrf_token_digest: :crypto.hash(:sha256, "csrf-expiring-grant-#{grant_id}"),
                     filename: "evidence.bin",
                     byte_size: 4,
                     declared_media_type: "application/octet-stream",
                     idempotency_key: "expiring-grant-#{grant_id}",
                     principal_authorization_epoch: 0,
                     vault_authorization_epoch: 0,
                     expires_at: DateTime.add(statement_time, 500, :millisecond)
                   })
                 )

               Process.sleep(750)

               AssetRepository.consume_upload_grant(repo, %{
                 grant_id: grant_id,
                 consumed_at: DateTime.utc_now(:microsecond)
               })
             end)
  end

  test "upload grant rejects nil consumed_at without reporting a reusable success", %{
    fixture: fixture
  } do
    grant_id = Ecto.UUID.generate()
    now = DateTime.utc_now(:microsecond)

    assert :ok =
             scoped(fixture, fn repo ->
               {:ok, _grant} =
                 repo.insert(
                   UploadGrant.create_changeset(%UploadGrant{}, %{
                     id: grant_id,
                     vault_id: fixture.vault_id,
                     session_id: fixture.session_id,
                     principal_id: fixture.principal_id,
                     asset_id: fixture.asset_id,
                     classification: :private,
                     token_digest: :crypto.hash(:sha256, "nil-consumed-at-#{grant_id}"),
                     csrf_token_digest: :crypto.hash(:sha256, "csrf-nil-consumed-at-#{grant_id}"),
                     filename: "evidence.bin",
                     byte_size: 4,
                     declared_media_type: "application/octet-stream",
                     idempotency_key: "nil-consumed-at-#{grant_id}",
                     principal_authorization_epoch: 0,
                     vault_authorization_epoch: 0,
                     expires_at: DateTime.add(now, 300, :second)
                   })
                 )

               :ok
             end)

    assert {:error, %Error{code: :invalid}} =
             scoped(fixture, fn repo ->
               AssetRepository.consume_upload_grant(repo, %{
                 grant_id: grant_id,
                 consumed_at: nil
               })
             end)

    scoped(fixture, fn repo ->
      assert %{rows: [[nil]]} =
               query!(
                 repo,
                 "SELECT consumed_at FROM content.upload_grants WHERE id = $1",
                 [Ecto.UUID.dump!(grant_id)]
               )

      :ok
    end)
  end

  test "concurrent tombstone creates and releases exactly one durable effect set", %{
    fixture: fixture
  } do
    scoped(fixture, fn repo ->
      query!(
        repo,
        """
        INSERT INTO content.resource_assets (
          resource_version_id, asset_id, vault_id, classification
        ) VALUES ($1, $2, $3, 'private')
        """,
        [
          Ecto.UUID.dump!(fixture.resource_version_id),
          Ecto.UUID.dump!(fixture.asset_id),
          Ecto.UUID.dump!(fixture.vault_id)
        ]
      )

      :ok
    end)

    adapters = %{
      repository: AssetRepository,
      audit: Singularity.Storage.Postgres.AuditSink,
      outbox: Singularity.Storage.Postgres.Outbox
    }

    command = %{
      asset_id: fixture.asset_id,
      principal_id: fixture.principal_id,
      classification: :private,
      expected_state_revision: 0
    }

    results =
      1..2
      |> Task.async_stream(
        fn _attempt ->
          scoped(fixture, fn repo ->
            Assets.tombstone_and_release(
              Map.put(adapters, :context, repo),
              command
            )
          end)
        end,
        max_concurrency: 2,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(
             results,
             &match?(
               {:ok,
                %{
                  asset: %Asset{state: :pending_delete, state_revision: 1},
                  outbox: %{event_type: "asset.release_requested"}
                }},
               &1
             )
           ) == 1

    assert Enum.count(results, &match?({:error, %Error{code: :conflict}}, &1)) == 1

    scoped(fixture, fn repo ->
      assert %{rows: [[deleted_at, released_at]]} =
               query!(
                 repo,
                 """
                 SELECT tombstone.deleted_at, reference.released_at
                 FROM content.tombstones AS tombstone
                 JOIN content.resource_assets AS reference
                   ON reference.asset_id = tombstone.asset_id
                 WHERE tombstone.asset_id = $1
                 """,
                 [Ecto.UUID.dump!(fixture.asset_id)]
               )

      assert DateTime.compare(deleted_at, released_at) in [:lt, :eq]
      assert count_rows(repo, "content.tombstones", fixture.vault_id) == 1
      assert count_rows(repo, "core.outbox_events", fixture.vault_id) == 1
      assert count_rows(repo, "audit.events", fixture.vault_id) == 1

      assert %{rows: [[1]]} =
               query!(
                 repo,
                 """
                 SELECT count(*)
                 FROM content.resource_assets
                 WHERE asset_id = $1 AND released_at IS NOT NULL
                 """,
                 [Ecto.UUID.dump!(fixture.asset_id)]
               )

      :ok
    end)
  end

  test "search projection upserts, searches, and deletes inside the vault scope", %{
    fixture: fixture
  } do
    assert :ok =
             scoped(fixture, fn repo ->
               assert %{num_rows: 1} =
                        query!(
                          repo,
                          """
                          UPDATE content.assets
                          SET
                            state = 'uploaded',
                            state_revision = 1,
                            failure_code = 'storage_unavailable',
                            retryable = true,
                            failed_operation = 'asset_verify',
                            attempt = 2
                          WHERE id = $1 AND vault_id = $2
                          """,
                          [
                            Ecto.UUID.dump!(fixture.asset_id),
                            Ecto.UUID.dump!(fixture.vault_id)
                          ]
                        )

               :ok
             end)

    attrs = %{
      asset_id: fixture.asset_id,
      resource_version_id: fixture.resource_version_id,
      vault_id: fixture.vault_id,
      classification: :private,
      state: :ready,
      detected_media_type: nil,
      resource_title: "Quarterly Evidence",
      original_filename: "evidence.pdf"
    }

    assert :ok = scoped(fixture, &AssetSearchStore.upsert(&1, attrs))

    assert {:ok, {[result], :done}} =
             scoped(fixture, fn repo ->
               AssetSearchStore.search(repo, %{
                 vault_id: fixture.vault_id,
                 query: "quarterly",
                 limit: 10
               })
             end)

    assert %DateTime{} = result.updated_at

    assert Map.delete(result, :updated_at) == %{
             asset_id: fixture.asset_id,
             resource_version_id: fixture.resource_version_id,
             vault_id: fixture.vault_id,
             classification: :private,
             state: :uploaded,
             state_revision: 1,
             detected_media_type: nil,
             resource_title: "Quarterly Evidence",
             original_filename: "evidence.pdf",
             failure: %{
               code: "storage_unavailable",
               retryable: true,
               operation: "asset_verify",
               attempt: 2
             }
           }

    assert :ok =
             scoped(fixture, fn repo ->
               AssetSearchStore.delete(repo, %{
                 asset_id: fixture.asset_id,
                 vault_id: fixture.vault_id
               })
             end)

    assert {:ok, {[], :done}} =
             scoped(fixture, fn repo ->
               AssetSearchStore.search(repo, %{
                 vault_id: fixture.vault_id,
                 query: "quarterly",
                 limit: 10
               })
             end)
  end

  defp scoped(fixture, fun) do
    ScopedRepo.transact(
      RequestRepo,
      %{principal_id: fixture.principal_id, vault_id: fixture.vault_id},
      fun
    )
  end

  defp count_rows(repo, table, vault_id) do
    %{rows: [[count]]} =
      query!(
        repo,
        "SELECT count(*) FROM #{table} WHERE vault_id = $1",
        [Ecto.UUID.dump!(vault_id)]
      )

    count
  end

  defp load_ids(fixture) do
    Map.new(fixture, fn
      {key, value}
      when key in [
             :account_id,
             :asset_id,
             :credential_id,
             :principal_id,
             :resource_id,
             :resource_version_id,
             :session_id,
             :vault_id
           ] ->
        {key, Ecto.UUID.load!(value)}

      pair ->
        pair
    end)
  end

  test "first search projection cannot downgrade the canonical asset classification", %{
    fixture: fixture
  } do
    attrs = %{
      asset_id: fixture.asset_id,
      resource_version_id: fixture.resource_version_id,
      vault_id: fixture.vault_id,
      classification: :private,
      state: :ready,
      detected_media_type: "application/pdf",
      resource_title: "Restricted Evidence",
      original_filename: "restricted.pdf"
    }

    assert :ok =
             scoped(fixture, fn repo ->
               :ok =
                 AssetSearchStore.delete(repo, %{
                   asset_id: fixture.asset_id,
                   vault_id: fixture.vault_id
                 })

               query!(
                 repo,
                 """
                 UPDATE content.resource_versions
                 SET classification = 'restricted'
                 WHERE id = $1 AND vault_id = $2
                 """,
                 [
                   Ecto.UUID.dump!(fixture.resource_version_id),
                   Ecto.UUID.dump!(fixture.vault_id)
                 ]
               )

               query!(
                 repo,
                 """
                 UPDATE content.resources
                 SET classification = 'restricted'
                 WHERE id = $1 AND vault_id = $2
                 """,
                 [
                   Ecto.UUID.dump!(fixture.resource_id),
                   Ecto.UUID.dump!(fixture.vault_id)
                 ]
               )

               query!(
                 repo,
                 """
                 UPDATE content.assets
                 SET classification = 'restricted'
                 WHERE id = $1 AND vault_id = $2
                 """,
                 [
                   Ecto.UUID.dump!(fixture.asset_id),
                   Ecto.UUID.dump!(fixture.vault_id)
                 ]
               )

               :ok
             end)

    assert {:error, %Error{code: :forbidden}} =
             scoped(fixture, fn repo -> AssetSearchStore.upsert(repo, attrs) end)

    scoped(fixture, fn repo ->
      assert %{rows: [[0]]} =
               query!(
                 repo,
                 "SELECT count(*) FROM content.asset_search_documents WHERE asset_id = $1",
                 [Ecto.UUID.dump!(fixture.asset_id)]
               )

      :ok
    end)
  end

  test "concurrent search projections retain the stricter classification", %{fixture: fixture} do
    coordinator = self()

    attrs = %{
      asset_id: fixture.asset_id,
      resource_version_id: fixture.resource_version_id,
      vault_id: fixture.vault_id,
      state: :ready,
      detected_media_type: "application/pdf",
      resource_title: "Concurrent Evidence",
      original_filename: "concurrent.pdf"
    }

    stricter =
      Task.async(fn ->
        coordinated_search_upsert(
          fixture,
          Map.put(attrs, :classification, :restricted),
          coordinator
        )
      end)

    weaker =
      Task.async(fn ->
        coordinated_search_upsert(
          fixture,
          Map.put(attrs, :classification, :private),
          coordinator
        )
      end)

    ready =
      for _index <- 1..2, into: %{} do
        receive do
          {:projection_ready, task_pid, classification} ->
            {classification, task_pid}
        after
          5_000 ->
            flunk("timed out waiting for coordinated search projection")
        end
      end

    send(Map.fetch!(ready, :restricted), {:continue_projection, stricter.pid})
    assert :ok = Task.await(stricter, 5_000)

    send(Map.fetch!(ready, :private), {:continue_projection, weaker.pid})
    assert :ok = Task.await(weaker, 5_000)

    scoped(fixture, fn repo ->
      assert %{classification: :restricted} =
               repo.get!(
                 Singularity.Storage.Schema.Content.AssetSearchDocument,
                 fixture.asset_id
               )

      :ok
    end)
  end

  test "canonical classification cannot change between validation and first projection insert", %{
    fixture: fixture
  } do
    coordinator = self()

    attrs = %{
      asset_id: fixture.asset_id,
      resource_version_id: fixture.resource_version_id,
      vault_id: fixture.vault_id,
      state: :ready,
      detected_media_type: "application/pdf",
      resource_title: "Canonical Race Evidence",
      original_filename: "canonical-race.pdf"
    }

    projection =
      Task.async(fn ->
        coordinated_search_upsert(
          fixture,
          Map.put(attrs, :classification, :private),
          coordinator
        )
      end)

    assert_receive {:projection_ready, projection_pid, :private}, 5_000
    assert projection_pid == projection.pid

    upgrader =
      Task.async(fn ->
        send(coordinator, {:canonical_upgrade_started, self()})

        result =
          scoped(fixture, fn repo ->
            query!(
              repo,
              """
              UPDATE content.resource_versions
              SET classification = 'restricted'
              WHERE id = $1 AND vault_id = $2
              """,
              [
                Ecto.UUID.dump!(fixture.resource_version_id),
                Ecto.UUID.dump!(fixture.vault_id)
              ]
            )

            query!(
              repo,
              """
              UPDATE content.resources
              SET classification = 'restricted'
              WHERE id = $1 AND vault_id = $2
              """,
              [
                Ecto.UUID.dump!(fixture.resource_id),
                Ecto.UUID.dump!(fixture.vault_id)
              ]
            )

            query!(
              repo,
              """
              UPDATE content.assets
              SET classification = 'restricted'
              WHERE id = $1 AND vault_id = $2
              """,
              [
                Ecto.UUID.dump!(fixture.asset_id),
                Ecto.UUID.dump!(fixture.vault_id)
              ]
            )

            AssetSearchStore.upsert(
              repo,
              Map.put(attrs, :classification, :restricted)
            )
          end)

        send(coordinator, {:canonical_upgrade_completed, self(), result})
        result
      end)

    assert_receive {:canonical_upgrade_started, upgrader_pid}, 5_000
    assert upgrader_pid == upgrader.pid
    refute_receive {:canonical_upgrade_completed, ^upgrader_pid, _result}, 100

    send(projection.pid, {:continue_projection, projection.pid})
    assert :ok = Task.await(projection, 5_000)
    assert :ok = Task.await(upgrader, 5_000)

    scoped(fixture, fn repo ->
      assert %{classification: :restricted} =
               repo.get!(
                 Singularity.Storage.Schema.Content.AssetSearchDocument,
                 fixture.asset_id
               )

      :ok
    end)
  end

  defp coordinated_search_upsert(fixture, attrs, coordinator) do
    Process.put(:asset_search_coordinator, coordinator)

    scoped(fixture, fn _repo ->
      AssetSearchStore.upsert(CoordinatedSearchRepo, attrs)
    end)
  end

  defp upload_intent_command(
         fixture,
         asset_id,
         source_reference_id,
         idempotency_key,
         observed_at
       ) do
    %{
      idempotency_key: idempotency_key,
      asset_id: asset_id,
      vault_id: fixture.vault_id,
      resource_version_id: fixture.resource_version_id,
      source_reference_id: source_reference_id,
      resource_version_classification: :private,
      classification: :private,
      principal_id: fixture.principal_id,
      filename: "evidence.bin",
      declared_media_type: "application/octet-stream",
      byte_size: 4,
      digest: "sha256:payload",
      server_observed_at: observed_at
    }
  end

  defp asset_repository_uuid_cases(fixture) do
    asset_id = Ecto.UUID.generate()
    source_reference_id = Ecto.UUID.generate()
    observed_at = DateTime.utc_now(:microsecond)

    {:ok, upload_asset} =
      Asset.new(%{
        asset_id: asset_id,
        vault_id: fixture.vault_id,
        resource_version_id: fixture.resource_version_id,
        classification: :private,
        state: :staging,
        state_revision: 0
      })

    {:ok, provenance} =
      SourceReference.new(%{
        source_reference_id: source_reference_id,
        vault_id: fixture.vault_id,
        resource_version_id: fixture.resource_version_id,
        principal_id: fixture.principal_id,
        kind: :browser_upload,
        observed_at: observed_at,
        metadata: %{
          "filename" => "invalid-uuid.bin",
          "declared_media_type" => "application/octet-stream",
          "byte_size" => 4,
          "digest" => "sha256:invalid-uuid"
        }
      })

    upload_intent = %{
      idempotency_key: "invalid-uuid-upload-#{asset_id}",
      asset: upload_asset,
      provenance: provenance
    }

    sealed_intent = %{
      asset: %{
        asset_id: fixture.asset_id,
        vault_id: fixture.vault_id,
        resource_version_id: fixture.resource_version_id,
        principal_id: fixture.principal_id,
        sealed_ref: "sealed://invalid-uuid",
        filename: "invalid-uuid.bin",
        content_type: "application/octet-stream",
        byte_size: 4,
        checksum: "sha256:" <> String.duplicate("ab", 32),
        classification: :private,
        state: :uploaded
      },
      audit: %{
        operation: "asset.uploaded",
        asset_id: fixture.asset_id,
        vault_id: fixture.vault_id,
        principal_id: fixture.principal_id,
        classification: :private
      },
      outbox: %{
        event_type: "asset.verify_requested",
        asset_id: fixture.asset_id,
        vault_id: fixture.vault_id,
        principal_id: fixture.principal_id,
        classification: :private
      }
    }

    transition_intent = %{
      asset_id: fixture.asset_id,
      principal_id: fixture.principal_id,
      classification: :private,
      expected_state_revision: 0,
      to: :uploaded,
      audit: %{
        operation: "asset.transitioned",
        asset_id: fixture.asset_id,
        principal_id: fixture.principal_id,
        classification: :private,
        to: :uploaded
      },
      outbox: %{
        event_type: "asset.transitioned",
        asset_id: fixture.asset_id,
        principal_id: fixture.principal_id,
        classification: :private,
        to: :uploaded
      }
    }

    tombstone_intent = %{
      asset_id: fixture.asset_id,
      principal_id: fixture.principal_id,
      classification: :private,
      expected_state_revision: 0,
      tombstone: %{
        asset_id: fixture.asset_id,
        state: :pending_delete,
        classification: :private
      },
      audit: %{
        operation: "asset.tombstoned",
        asset_id: fixture.asset_id,
        principal_id: fixture.principal_id,
        classification: :private
      },
      outbox: %{
        event_type: "asset.release_requested",
        asset_id: fixture.asset_id,
        principal_id: fixture.principal_id,
        classification: :private
      }
    }

    callback_paths(:create_upload_intent, upload_intent, [
      [:asset, :asset_id],
      [:asset, :vault_id],
      [:asset, :resource_version_id],
      [:provenance, :source_reference_id],
      [:provenance, :vault_id],
      [:provenance, :resource_version_id],
      [:provenance, :principal_id]
    ]) ++
      callback_paths(
        :consume_upload_grant,
        %{grant_id: Ecto.UUID.generate(), consumed_at: observed_at},
        [[:grant_id]]
      ) ++
      callback_paths(:record_sealed_stage, sealed_intent, [
        [:asset, :asset_id],
        [:asset, :vault_id],
        [:asset, :resource_version_id],
        [:asset, :principal_id],
        [:audit, :asset_id],
        [:audit, :vault_id],
        [:audit, :principal_id],
        [:outbox, :asset_id],
        [:outbox, :vault_id],
        [:outbox, :principal_id]
      ]) ++
      callback_paths(:transition, transition_intent, [
        [:asset_id],
        [:principal_id],
        [:audit, :asset_id],
        [:audit, :principal_id],
        [:outbox, :asset_id],
        [:outbox, :principal_id]
      ]) ++
      callback_paths(:tombstone_and_release, tombstone_intent, [
        [:asset_id],
        [:principal_id],
        [:tombstone, :asset_id],
        [:audit, :asset_id],
        [:audit, :principal_id],
        [:outbox, :asset_id],
        [:outbox, :principal_id]
      ])
  end

  defp callback_paths(callback, intent, paths) do
    Enum.map(paths, &{callback, intent, &1})
  end

  defp asset_effects(fixture) do
    scoped(fixture, fn repo ->
      %{rows: [effects]} =
        query!(
          repo,
          """
          SELECT
            (SELECT count(*) FROM content.assets WHERE vault_id = $1),
            (SELECT count(*) FROM content.source_references WHERE vault_id = $1),
            (SELECT count(*) FROM content.resource_assets WHERE vault_id = $1),
            (SELECT count(*) FROM content.asset_metadata WHERE vault_id = $1),
            (SELECT count(*) FROM content.tombstones WHERE vault_id = $1),
            (SELECT count(*) FROM audit.events WHERE vault_id = $1),
            (SELECT count(*) FROM core.outbox_events WHERE vault_id = $1),
            (SELECT count(*) FROM content.asset_search_documents WHERE vault_id = $1),
            (
              SELECT count(*)
              FROM content.upload_grants
              WHERE vault_id = $1 AND consumed_at IS NOT NULL
            ),
            (
              SELECT count(*)
              FROM content.resource_assets
              WHERE vault_id = $1 AND released_at IS NOT NULL
            ),
            (SELECT state FROM content.assets WHERE id = $2),
            (SELECT state_revision FROM content.assets WHERE id = $2)
          """,
          [
            Ecto.UUID.dump!(fixture.vault_id),
            Ecto.UUID.dump!(fixture.asset_id)
          ]
        )

      effects
    end)
  end

  defp invalid_uuids do
    ["not-a-uuid", <<0, 1>>, "warehouse worker", String.duplicate("x", 36)]
  end

  defp put_path(data, path, value) do
    put_in(data, Enum.map(path, &Access.key/1), value)
  end
end
