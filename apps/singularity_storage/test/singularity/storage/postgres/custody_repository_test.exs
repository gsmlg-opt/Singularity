defmodule Singularity.Storage.Postgres.CustodyRepositoryTest do
  use Singularity.Storage.DataCase, async: false

  @moduletag :integration

  alias Singularity.Core.Error
  alias Singularity.Storage.Crypto.Format
  alias Singularity.Storage.Fixtures
  alias Singularity.Storage.MigrationRepo
  alias Singularity.Storage.Postgres.CustodyRepository
  alias Singularity.Storage.ScopedRepo

  setup do
    %{one: one, two: two} = Fixtures.two_vaults!()
    outbox = Fixtures.outbox_event!(one)

    {:ok, fixture: insert_reader_fixture!(one, outbox), other: load_identity(two)}
  end

  test "loads only the exact same-vault live envelope and immutable object metadata", %{
    fixture: fixture,
    other: other
  } do
    assert {:ok, material} =
             scoped(fixture, fn repo ->
               CustodyRepository.load_reader_material(repo, fixture.binding)
             end)

    assert material == fixture.material
    refute Map.has_key?(material, :object_dek)
    refute Map.has_key?(material, :domain_key)

    assert {:error, %Error{code: :invalid}} =
             scoped(fixture, fn repo ->
               CustodyRepository.load_reader_material(
                 repo,
                 Map.delete(fixture.binding, :session_id)
               )
             end)

    for changed <- [
          %{fixture.binding | object_id: Ecto.UUID.generate()},
          %{fixture.binding | object_generation: fixture.binding.object_generation + 1}
        ] do
      assert {:error, %Error{code: :forbidden}} =
               scoped(fixture, fn repo ->
                 CustodyRepository.load_reader_material(repo, changed)
               end)
    end

    assert {:error, %Error{code: :forbidden}} =
             scoped(other, fn repo ->
               CustodyRepository.load_reader_material(repo, fixture.binding)
             end)
  end

  test "v2 checkpoint load and CAS preserve baseline binding and query semantics", %{
    fixture: fixture
  } do
    large_integer = 9_223_372_036_854_775_808

    binding = %{
      fixture.binding
      | required_capability: String.duplicate("c", 129),
        principal_authorization_epoch: large_integer,
        vault_authorization_epoch: large_integer + 1,
        object_generation: large_integer + 2
    }

    binding = Map.put(binding, :legacy_context, :preserved)
    checkpoint = checkpoint(binding, 0)
    next = checkpoint(binding, 1)

    update_owner!(
      """
      UPDATE jobs.job_progress
      SET checkpoint_version = 2,
          checkpoint = $2::text::jsonb
      WHERE submission_id = $1
      """,
      [Ecto.UUID.dump!(binding.job_id), JSON.encode!(checkpoint)]
    )

    assert {:ok, ^checkpoint} =
             scoped(fixture, fn repo ->
               CustodyRepository.load_checkpoint(repo, binding, :private)
             end)

    assert :ok =
             scoped(fixture, fn repo ->
               CustodyRepository.persist_checkpoint(
                 repo,
                 binding,
                 :private,
                 checkpoint,
                 next
               )
             end)

    legacy_opaque = %{"legacy" => ["opaque", 1]}

    update_owner!(
      "UPDATE jobs.job_progress SET checkpoint = $2::text::jsonb WHERE submission_id = $1",
      [Ecto.UUID.dump!(binding.job_id), JSON.encode!(legacy_opaque)]
    )

    assert {:ok, ^legacy_opaque} =
             scoped(fixture, fn repo ->
               CustodyRepository.load_checkpoint(repo, binding, :private)
             end)

    update_owner!(
      "UPDATE jobs.job_progress SET checkpoint_version = 3 WHERE submission_id = $1",
      [Ecto.UUID.dump!(binding.job_id)]
    )

    assert {:error, %Error{code: :conflict}} =
             scoped(fixture, fn repo ->
               CustodyRepository.load_checkpoint(repo, binding, :private)
             end)

    assert {:error, %Error{code: :invalid}} =
             scoped(fixture, fn repo ->
               CustodyRepository.load_checkpoint(
                 repo,
                 Map.delete(binding, :session_id),
                 :private
               )
             end)
  end

  test "session-bound checkpoint bindings remain v2 with incidental metadata fields", %{
    fixture: fixture
  } do
    binding =
      fixture.binding
      |> Map.put(:processing_revision, 1)
      |> Map.put(:declared_media_type, "image/png")
      |> Map.put(:plaintext_byte_size, 31)
      |> Map.put(:legacy_context, :preserved)

    checkpoint = checkpoint(binding, 0)
    next = checkpoint(binding, 1)

    assert {:ok, ^checkpoint} =
             scoped(fixture, fn repo ->
               CustodyRepository.load_checkpoint(repo, binding, :private)
             end)

    assert :ok =
             scoped(fixture, fn repo ->
               CustodyRepository.persist_checkpoint(
                 repo,
                 binding,
                 :private,
                 checkpoint,
                 next
               )
             end)

    assert {:ok, ^next} =
             scoped(fixture, fn repo ->
               CustodyRepository.load_checkpoint(repo, binding, :private)
             end)
  end

  test "fails closed for a retired domain version or inconsistent classification", %{
    fixture: fixture
  } do
    update_owner!(
      "UPDATE core.domain_key_versions SET state = 'retired' WHERE id = $1",
      [Ecto.UUID.dump!(fixture.material.domain_key_version_id)]
    )

    assert {:error, %Error{code: :forbidden}} =
             scoped(fixture, fn repo ->
               CustodyRepository.load_reader_material(repo, fixture.binding)
             end)

    update_owner!(
      "UPDATE core.domain_key_versions SET state = 'active' WHERE id = $1",
      [Ecto.UUID.dump!(fixture.material.domain_key_version_id)]
    )

    update_owner!(
      """
      UPDATE content.asset_key_envelopes
      SET classification = 'sensitive'
      WHERE asset_object_id = $1
      """,
      [Ecto.UUID.dump!(fixture.binding.object_id)]
    )

    assert {:error, %Error{code: :integrity_failure}} =
             scoped(fixture, fn repo ->
               CustodyRepository.load_reader_material(repo, fixture.binding)
             end)
  end

  test "revalidates the live principal and exact object binding", %{fixture: fixture} do
    assert :ok =
             scoped(fixture, fn repo ->
               CustodyRepository.revalidate_reader(
                 repo,
                 fixture.binding,
                 fixture.reader_binding
               )
             end)

    update_owner!(
      """
      UPDATE core.principal_capabilities
      SET revoked_at = CURRENT_TIMESTAMP
      WHERE principal_id = $1 AND vault_id = $2
      """,
      [
        Ecto.UUID.dump!(fixture.binding.principal_id),
        Ecto.UUID.dump!(fixture.binding.vault_id)
      ]
    )

    assert {:error, %Error{code: :forbidden}} =
             scoped(fixture, fn repo ->
               CustodyRepository.revalidate_reader(
                 repo,
                 fixture.binding,
                 fixture.reader_binding
               )
             end)
  end

  test "loads and compare-and-swaps the durable lease checkpoint", %{fixture: fixture} do
    assert {:ok, checkpoint} =
             scoped(fixture, fn repo ->
               CustodyRepository.load_checkpoint(
                 repo,
                 fixture.binding,
                 :private
               )
             end)

    assert checkpoint == fixture.checkpoint
    next = Map.put(checkpoint, "next_chunk_index", 1)

    assert :ok =
             scoped(fixture, fn repo ->
               CustodyRepository.persist_checkpoint(
                 repo,
                 fixture.binding,
                 :private,
                 checkpoint,
                 next
               )
             end)

    assert {:error, %Error{code: :conflict}} =
             scoped(fixture, fn repo ->
               CustodyRepository.persist_checkpoint(
                 repo,
                 fixture.binding,
                 :private,
                 checkpoint,
                 next
               )
             end)

    assert {:ok, ^next} =
             scoped(fixture, fn repo ->
               CustodyRepository.load_checkpoint(
                 repo,
                 fixture.binding,
                 :private
               )
             end)
  end

  test "metadata checkpoints bind parser state and processing revision in one strict CAS", %{
    fixture: fixture
  } do
    binding = metadata_binding(fixture.binding, 5)

    initial_state = %{
      "phase" => "start",
      "declared_media_type" => "image/png",
      "plaintext_bytes" => 31
    }

    checkpoint = metadata_checkpoint(binding, 0, initial_state)

    update_owner!(
      """
      UPDATE jobs.job_progress
      SET processing_revision = 5,
          checkpoint_version = 3,
          checkpoint = $2::text::jsonb
      WHERE submission_id = $1
      """,
      [Ecto.UUID.dump!(binding.job_id), JSON.encode!(checkpoint)]
    )

    assert {:ok, ^checkpoint} =
             scoped(fixture, fn repo ->
               CustodyRepository.load_checkpoint(repo, binding, :private)
             end)

    assert {:error, %Error{code: :conflict}} =
             scoped(fixture, fn repo ->
               CustodyRepository.load_checkpoint(
                 repo,
                 Map.put(binding, :session_id, fixture.binding.session_id),
                 :private
               )
             end)

    update_owner!(
      "UPDATE jobs.job_progress SET checkpoint_version = 2 WHERE submission_id = $1",
      [Ecto.UUID.dump!(binding.job_id)]
    )

    assert {:error, %Error{code: :integrity_failure}} =
             scoped(fixture, fn repo ->
               CustodyRepository.load_checkpoint(repo, binding, :private)
             end)

    update_owner!(
      "UPDATE jobs.job_progress SET checkpoint_version = 3 WHERE submission_id = $1",
      [Ecto.UUID.dump!(binding.job_id)]
    )

    done_state = %{
      "phase" => "done",
      "result" => %{
        "detected_media_type" => "image/png",
        "plaintext_bytes" => 31,
        "width" => 1,
        "height" => 1,
        "pdf_version" => nil,
        "extractor_version" => 1
      }
    }

    next = metadata_checkpoint(binding, 1, done_state)

    assert :ok =
             scoped(fixture, fn repo ->
               CustodyRepository.persist_checkpoint(
                 repo,
                 binding,
                 :private,
                 checkpoint,
                 next
               )
             end)

    assert {:error, :checkpoint_advanced} =
             scoped(fixture, fn repo ->
               CustodyRepository.persist_checkpoint(
                 repo,
                 binding,
                 :private,
                 checkpoint,
                 next
               )
             end)

    assert {:error, %Error{code: :conflict}} =
             scoped(fixture, fn repo ->
               CustodyRepository.load_checkpoint(
                 repo,
                 %{binding | processing_revision: 6},
                 :private
               )
             end)

    extra_result_key = put_in(next, ["extractor_state", "result", "extra"], true)

    update_owner!(
      "UPDATE jobs.job_progress SET checkpoint = $2::text::jsonb WHERE submission_id = $1",
      [Ecto.UUID.dump!(binding.job_id), JSON.encode!(extra_result_key)]
    )

    assert {:error, %Error{code: :integrity_failure}} =
             scoped(fixture, fn repo ->
               CustodyRepository.load_checkpoint(repo, binding, :private)
             end)

    malformed =
      next
      |> put_in(["extractor_state", "prefix"], "%PDF-")

    update_owner!(
      "UPDATE jobs.job_progress SET checkpoint = $2::text::jsonb WHERE submission_id = $1",
      [Ecto.UUID.dump!(binding.job_id), JSON.encode!(malformed)]
    )

    assert {:error, %Error{code: :integrity_failure}} =
             scoped(fixture, fn repo ->
               CustodyRepository.load_checkpoint(repo, binding, :private)
             end)
  end

  test "metadata checkpoint validation enforces phase indexes and distinguishes stale bindings",
       %{
         fixture: fixture
       } do
    binding = metadata_binding(fixture.binding, 5)

    start =
      metadata_checkpoint(binding, 0, %{
        "phase" => "start",
        "declared_media_type" => "image/png",
        "plaintext_bytes" => 31
      })

    assert :ok = CustodyRepository.validate_metadata_checkpoint(start, binding)

    assert {:error, %Error{code: :integrity_failure}} =
             CustodyRepository.validate_metadata_checkpoint(
               %{start | "next_chunk_index" => 1},
               binding
             )

    done =
      metadata_checkpoint(binding, 1, %{
        "phase" => "done",
        "result" => %{
          "detected_media_type" => "image/png",
          "plaintext_bytes" => 31,
          "width" => 1,
          "height" => 1,
          "pdf_version" => nil,
          "extractor_version" => 1
        }
      })

    assert :ok = CustodyRepository.validate_metadata_checkpoint(done, binding)

    for invalid_index <- [0, 2] do
      assert {:error, %Error{code: :integrity_failure}} =
               CustodyRepository.validate_metadata_checkpoint(
                 %{done | "next_chunk_index" => invalid_index},
                 binding
               )
    end

    assert {:error, %Error{code: :conflict}} =
             CustodyRepository.validate_metadata_checkpoint(
               %{done | "object_generation" => done["object_generation"] + 1},
               binding
             )

    assert {:error, %Error{code: :integrity_failure}} =
             CustodyRepository.validate_metadata_checkpoint(
               Map.put(done, "session_id", Ecto.UUID.generate()),
               binding
             )

    jpeg_binding =
      metadata_binding(fixture.binding, 5, %{
        declared_media_type: "image/jpeg",
        plaintext_byte_size: Format.chunk_size() + 1
      })

    jpeg_scan =
      metadata_checkpoint(jpeg_binding, 1, %{
        "phase" => "jpeg_scan",
        "declared_media_type" => "image/jpeg",
        "plaintext_bytes" => Format.chunk_size() + 1,
        "cursor" => Format.chunk_size(),
        "segments_seen" => 0,
        "mode" => "length_low",
        "segment_kind" => "sof",
        "segment_length_acc" => 0
      })

    assert :ok = CustodyRepository.validate_metadata_checkpoint(jpeg_scan, jpeg_binding)

    for malformed <- [
          put_in(jpeg_scan, ["extractor_state", "segment_kind"], "unknown"),
          put_in(jpeg_scan, ["extractor_state", "segment_length_acc"], 1),
          put_in(jpeg_scan, ["extractor_state", "segment_length_acc"], 65_536),
          put_in(jpeg_scan, ["extractor_state", "marker"], 0xC0),
          put_in(jpeg_scan, ["extractor_state", "length_high"], 0)
        ] do
      assert {:error, %Error{code: :integrity_failure}} =
               CustodyRepository.validate_metadata_checkpoint(malformed, jpeg_binding)
    end

    assert {:error, %Error{code: :integrity_failure}} =
             CustodyRepository.validate_metadata_checkpoint(
               put_in(done, ["extractor_state", "result", "extractor_version"], 2),
               binding
             )
  end

  test "metadata checkpoint CAS rejects a well-shaped target change", %{fixture: fixture} do
    binding =
      metadata_binding(fixture.binding, 5, %{
        declared_media_type: "application/pdf",
        plaintext_byte_size: 10
      })

    checkpoint =
      metadata_checkpoint(binding, 0, %{
        "phase" => "start",
        "declared_media_type" => "application/pdf",
        "plaintext_bytes" => 10
      })

    changed_target =
      metadata_checkpoint(binding, 1, %{
        "phase" => "done",
        "result" => %{
          "detected_media_type" => "image/png",
          "plaintext_bytes" => 20,
          "width" => 1,
          "height" => 1,
          "pdf_version" => nil,
          "extractor_version" => 1
        }
      })

    update_owner!(
      """
      UPDATE jobs.job_progress
      SET state = 'running',
          processing_revision = 5,
          checkpoint_version = 3,
          checkpoint = $2::text::jsonb
      WHERE submission_id = $1
      """,
      [Ecto.UUID.dump!(binding.job_id), JSON.encode!(checkpoint)]
    )

    assert {:error, %Error{code: :conflict}} =
             scoped(fixture, fn repo ->
               CustodyRepository.persist_checkpoint(
                 repo,
                 binding,
                 :private,
                 checkpoint,
                 changed_target
               )
             end)
  end

  test "v3 checkpoint load and CAS classify non-map storage as integrity failure", %{
    fixture: fixture
  } do
    binding = metadata_binding(fixture.binding, 5)

    checkpoint =
      metadata_checkpoint(binding, 0, %{
        "phase" => "start",
        "declared_media_type" => "image/png",
        "plaintext_bytes" => 31
      })

    next =
      metadata_checkpoint(binding, 1, %{
        "phase" => "done",
        "result" => %{
          "detected_media_type" => "image/png",
          "plaintext_bytes" => 31,
          "width" => 1,
          "height" => 1,
          "pdf_version" => nil,
          "extractor_version" => 1
        }
      })

    for malformed <- ["scalar", ["list"], nil] do
      update_owner!(
        """
        UPDATE jobs.job_progress
        SET state = 'running',
            processing_revision = 5,
            checkpoint_version = 3,
            checkpoint = $2::text::jsonb
        WHERE submission_id = $1
        """,
        [Ecto.UUID.dump!(binding.job_id), JSON.encode!(malformed)]
      )

      assert {:error, %Error{code: :integrity_failure}} =
               scoped(fixture, fn repo ->
                 CustodyRepository.load_checkpoint(repo, binding, :private)
               end)

      assert {:error, %Error{code: :integrity_failure}} =
               scoped(fixture, fn repo ->
                 CustodyRepository.persist_checkpoint(
                   repo,
                   binding,
                   :private,
                   checkpoint,
                   next
                 )
               end)
    end

    malformed_and_stale = Map.put(checkpoint, "unexpected", true)

    update_owner!(
      """
      UPDATE jobs.job_progress
      SET state = 'running',
          processing_revision = 5,
          checkpoint_version = 3,
          checkpoint = $2::text::jsonb
      WHERE submission_id = $1
      """,
      [Ecto.UUID.dump!(binding.job_id), JSON.encode!(malformed_and_stale)]
    )

    stale_binding = %{binding | processing_revision: binding.processing_revision + 1}

    stale_checkpoint =
      metadata_checkpoint(stale_binding, 0, checkpoint["extractor_state"])

    stale_next = metadata_checkpoint(stale_binding, 1, next["extractor_state"])

    assert {:error, %Error{code: :integrity_failure}} =
             scoped(fixture, fn repo ->
               CustodyRepository.load_checkpoint(repo, stale_binding, :private)
             end)

    assert {:error, %Error{code: :integrity_failure}} =
             scoped(fixture, fn repo ->
               CustodyRepository.persist_checkpoint(
                 repo,
                 stale_binding,
                 :private,
                 stale_checkpoint,
                 stale_next
               )
             end)
  end

  for progress_state <- [:waiting_for_unlock, :completed, :failed] do
    test "metadata checkpoint load rejects and CAS retries #{progress_state} progress", %{
      fixture: fixture
    } do
      binding = metadata_binding(fixture.binding, 5)

      checkpoint =
        metadata_checkpoint(binding, 0, %{
          "phase" => "start",
          "declared_media_type" => "image/png",
          "plaintext_bytes" => 31
        })

      next =
        metadata_checkpoint(binding, 1, %{
          "phase" => "done",
          "result" => %{
            "detected_media_type" => "image/png",
            "plaintext_bytes" => 31,
            "width" => 1,
            "height" => 1,
            "pdf_version" => nil,
            "extractor_version" => 1
          }
        })

      update_owner!(
        """
        UPDATE jobs.job_progress
        SET state = $2,
            processing_revision = 5,
            checkpoint_version = 3,
            checkpoint = $3::text::jsonb
        WHERE submission_id = $1
        """,
        [
          Ecto.UUID.dump!(binding.job_id),
          unquote(Atom.to_string(progress_state)),
          JSON.encode!(checkpoint)
        ]
      )

      assert {:error, %Error{code: :conflict}} =
               scoped(fixture, fn repo ->
                 CustodyRepository.load_checkpoint(repo, binding, :private)
               end)

      assert {:error, :checkpoint_advanced} =
               scoped(fixture, fn repo ->
                 CustodyRepository.persist_checkpoint(
                   repo,
                   binding,
                   :private,
                   checkpoint,
                   next
                 )
               end)

      stale_binding = %{binding | processing_revision: binding.processing_revision + 1}

      stale_checkpoint =
        metadata_checkpoint(stale_binding, 0, checkpoint["extractor_state"])

      stale_next = metadata_checkpoint(stale_binding, 1, next["extractor_state"])

      assert {:error, %Error{code: :conflict}} =
               scoped(fixture, fn repo ->
                 CustodyRepository.persist_checkpoint(
                   repo,
                   stale_binding,
                   :private,
                   stale_checkpoint,
                   stale_next
                 )
               end)

      malformed = Map.put(checkpoint, "unexpected", true)

      update_owner!(
        "UPDATE jobs.job_progress SET checkpoint = $2::text::jsonb WHERE submission_id = $1",
        [Ecto.UUID.dump!(binding.job_id), JSON.encode!(malformed)]
      )

      assert {:error, %Error{code: :integrity_failure}} =
               scoped(fixture, fn repo ->
                 CustodyRepository.persist_checkpoint(
                   repo,
                   binding,
                   :private,
                   checkpoint,
                   next
                 )
               end)

      assert [[^malformed]] =
               Fixtures.with_owner(fn ->
                 query!(
                   MigrationRepo,
                   "SELECT checkpoint FROM jobs.job_progress WHERE submission_id = $1",
                   [Ecto.UUID.dump!(binding.job_id)]
                 ).rows
               end)
    end
  end

  defp insert_reader_fixture!(raw, outbox) do
    ids = %{
      capability_id: Ecto.UUID.generate(),
      domain_key_version_id: Ecto.UUID.generate(),
      job_id: Ecto.UUID.generate(),
      job_progress_id: Ecto.UUID.generate(),
      key_domain_id: Ecto.UUID.generate(),
      object_id: Ecto.UUID.generate(),
      vault_key_version_id: Ecto.UUID.generate()
    }

    identity = load_identity(raw)

    binding = %{
      job_id: ids.job_id,
      vault_id: identity.vault_id,
      principal_id: identity.principal_id,
      required_capability: "asset.read",
      principal_authorization_epoch: 0,
      vault_authorization_epoch: 0,
      object_id: ids.object_id,
      object_generation: 3,
      session_id: identity.session_id
    }

    checkpoint = checkpoint(binding, 0)
    lookup_digest = :crypto.strong_rand_bytes(32)
    ciphertext_hash = :crypto.strong_rand_bytes(32)
    wrapped_dek = :crypto.strong_rand_bytes(60)

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "UPDATE core.vaults SET locked = false WHERE id = $1",
        [raw.vault_id]
      )

      query!(
        MigrationRepo,
        """
        INSERT INTO core.capabilities (id, name)
        VALUES ($1, 'asset.read')
        ON CONFLICT (name) DO NOTHING
        """,
        [Ecto.UUID.dump!(ids.capability_id)]
      )

      %{rows: [[capability_id]]} =
        query!(
          MigrationRepo,
          "SELECT id FROM core.capabilities WHERE name = 'asset.read'"
        )

      query!(
        MigrationRepo,
        """
        INSERT INTO core.principal_capabilities (
          principal_id, vault_id, capability_id
        ) VALUES ($1, $2, $3)
        """,
        [
          raw.principal_id,
          raw.vault_id,
          capability_id
        ]
      )

      query!(
        MigrationRepo,
        """
        INSERT INTO core.vault_key_versions (
          id, vault_id, generation, state, algorithm, activated_at
        ) VALUES ($1, $2, 1, 'active', 'aes_256_gcm', CURRENT_TIMESTAMP)
        """,
        [Ecto.UUID.dump!(ids.vault_key_version_id), raw.vault_id]
      )

      query!(
        MigrationRepo,
        """
        INSERT INTO core.key_domains (
          id, vault_id, classification, kind, state
        ) VALUES ($1, $2, 'private', 'content', 'active')
        """,
        [Ecto.UUID.dump!(ids.key_domain_id), raw.vault_id]
      )

      query!(
        MigrationRepo,
        """
        INSERT INTO core.domain_key_versions (
          id,
          vault_id,
          key_domain_id,
          vault_key_version_id,
          generation,
          state,
          algorithm,
          wrapped_key
        ) VALUES ($1, $2, $3, $4, 5, 'active', 'aes_256_gcm', $5)
        """,
        [
          Ecto.UUID.dump!(ids.domain_key_version_id),
          raw.vault_id,
          Ecto.UUID.dump!(ids.key_domain_id),
          Ecto.UUID.dump!(ids.vault_key_version_id),
          :crypto.strong_rand_bytes(60)
        ]
      )

      query!(
        MigrationRepo,
        """
        INSERT INTO content.asset_objects (
          id,
          vault_id,
          key_domain_id,
          classification,
          lookup_digest,
          ciphertext_hash,
          plaintext_byte_size,
          ciphertext_byte_size,
          storage_ref,
          format_version,
          lifecycle
        ) VALUES (
          $1, $2, $3, 'private', $4, $5, 31, 189, $6, 1, 'available'
        )
        """,
        [
          Ecto.UUID.dump!(ids.object_id),
          raw.vault_id,
          Ecto.UUID.dump!(ids.key_domain_id),
          lookup_digest,
          ciphertext_hash,
          ids.object_id
        ]
      )

      query!(
        MigrationRepo,
        """
        INSERT INTO content.asset_key_envelopes (
          id,
          vault_id,
          asset_object_id,
          domain_key_version_id,
          key_domain_id,
          classification,
          algorithm,
          key_generation,
          wrapped_dek
        ) VALUES (
          $1, $2, $3, $4, $5, 'private', 'aes_256_gcm', 3, $6
        )
        """,
        [
          Ecto.UUID.dump!(Ecto.UUID.generate()),
          raw.vault_id,
          Ecto.UUID.dump!(ids.object_id),
          Ecto.UUID.dump!(ids.domain_key_version_id),
          Ecto.UUID.dump!(ids.key_domain_id),
          wrapped_dek
        ]
      )

      query!(
        MigrationRepo,
        """
        INSERT INTO jobs.job_submissions (
          id,
          vault_id,
          outbox_event_id,
          classification,
          idempotency_key,
          job_type
        ) VALUES ($1, $2, $3, 'private', $4, 'asset_metadata')
        """,
        [
          Ecto.UUID.dump!(ids.job_id),
          raw.vault_id,
          outbox.id,
          "custody-#{ids.job_id}"
        ]
      )

      query!(
        MigrationRepo,
        """
        INSERT INTO jobs.job_progress (
          id,
          vault_id,
          submission_id,
          classification,
          state,
          processing_revision,
          checkpoint_version,
          checkpoint
        ) VALUES (
          $1, $2, $3, 'private', 'running', 0, 2, $4::text::jsonb
        )
        """,
        [
          Ecto.UUID.dump!(ids.job_progress_id),
          raw.vault_id,
          Ecto.UUID.dump!(ids.job_id),
          JSON.encode!(checkpoint)
        ]
      )
    end)

    material = %{
      object_id: ids.object_id,
      object_generation: 3,
      vault_id: identity.vault_id,
      key_domain_id: ids.key_domain_id,
      domain_key_version_id: ids.domain_key_version_id,
      domain_key_generation: 5,
      domain_classification: :private,
      classification: :private,
      envelope_classification: :private,
      lifecycle: :available,
      wrapper_algorithm: "aes_256_gcm",
      wrapped_dek: wrapped_dek,
      lookup_digest: lookup_digest,
      ciphertext_hash: ciphertext_hash,
      plaintext_byte_size: 31,
      ciphertext_byte_size: 189,
      format_version: 1
    }

    Map.merge(identity, %{
      binding: binding,
      checkpoint: checkpoint,
      material: material,
      reader_binding:
        Map.take(material, [
          :object_id,
          :object_generation,
          :vault_id,
          :key_domain_id,
          :classification,
          :lookup_digest,
          :ciphertext_hash,
          :plaintext_byte_size,
          :ciphertext_byte_size,
          :format_version
        ])
    })
  end

  defp scoped(fixture, callback) do
    ScopedRepo.transact(
      WorkerRepo,
      %{
        principal_id: fixture.principal_id,
        vault_id: fixture.vault_id
      },
      callback
    )
  end

  defp load_identity(raw) do
    %{
      principal_id: Ecto.UUID.load!(raw.principal_id),
      session_id: Ecto.UUID.load!(raw.session_id),
      vault_id: Ecto.UUID.load!(raw.vault_id)
    }
  end

  defp checkpoint(binding, next_chunk_index) do
    %{
      "version" => 2,
      "next_chunk_index" => next_chunk_index,
      "job_id" => binding.job_id,
      "vault_id" => binding.vault_id,
      "principal_id" => binding.principal_id,
      "required_capability" => binding.required_capability,
      "principal_authorization_epoch" => binding.principal_authorization_epoch,
      "vault_authorization_epoch" => binding.vault_authorization_epoch,
      "object_id" => binding.object_id,
      "object_generation" => binding.object_generation
    }
  end

  defp metadata_checkpoint(binding, next_chunk_index, extractor_state) do
    %{
      "version" => 3,
      "protocol" => "asset_metadata_v1",
      "next_chunk_index" => next_chunk_index,
      "processing_revision" => binding.processing_revision,
      "extractor_state" => extractor_state,
      "job_id" => binding.job_id,
      "vault_id" => binding.vault_id,
      "principal_id" => binding.principal_id,
      "required_capability" => binding.required_capability,
      "principal_authorization_epoch" => binding.principal_authorization_epoch,
      "vault_authorization_epoch" => binding.vault_authorization_epoch,
      "object_id" => binding.object_id,
      "object_generation" => binding.object_generation
    }
  end

  defp metadata_binding(
         binding,
         processing_revision,
         target \\ %{declared_media_type: "image/png", plaintext_byte_size: 31}
       ) do
    binding
    |> Map.delete(:session_id)
    |> Map.put(:processing_revision, processing_revision)
    |> Map.merge(target)
  end

  defp update_owner!(statement, parameters) do
    Fixtures.with_owner(fn ->
      query!(MigrationRepo, statement, parameters)
      :ok
    end)
  end
end
