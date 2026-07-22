defmodule Singularity.Runtime.MetadataUnlockResumeTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.Error
  alias Singularity.Ingest.MetadataExtractor
  alias Singularity.Runtime.KeyCustodian
  alias Singularity.Runtime.KeyLease
  alias Singularity.Runtime.KeyLeaseSupervisor

  defmodule IdleLock do
    def idle_lock(_owner, _session), do: :ok
  end

  defmodule WakeRecorder do
    def wake_waiting(owner, command) do
      send(owner, {:wake_waiting, command})
      :ok
    end
  end

  @now ~U[2026-07-22 08:00:00Z]
  @chunk_size 4_194_304
  @principal_id "principal-1"
  @vault_id "vault-1"
  @object_id "object-1"

  test "combined metadata checkpoint is durable before result and resumes under a fresh session" do
    jpeg = jpeg_with_sof_after_first_chunk()
    request = metadata_request("image/jpeg", byte_size(jpeg))
    {:ok, extractor_state} = MetadataExtractor.initial_state("image/jpeg", byte_size(jpeg))
    checkpoint = KeyLease.metadata_checkpoint(request, 0, extractor_state)

    clock = start_supervised!({Fake.Clock, now: @now})
    authorization = start_supervised!({Fake.Authorization, state: authorization_state()})

    key_reader =
      start_supervised!(
        {Fake.KeyReader,
         owner: self(),
         checkpoints: %{{request.job_id, request.vault_id, request.object_id} => checkpoint},
         chunks: %{
           0 => binary_part(jpeg, 0, @chunk_size),
           1 => binary_part(jpeg, @chunk_size, byte_size(jpeg) - @chunk_size)
         }}
      )

    context = %{authorization: authorization, clock: clock, key_reader: key_reader}
    lease_supervisor = start_supervised!({KeyLeaseSupervisor, []})

    custodian =
      start_supervised!(
        {KeyCustodian,
         %{
           authorization: Fake.Authorization,
           clock: Fake.Clock,
           context: context,
           idle_lock: {IdleLock, self()},
           key_reader: Fake.KeyReader,
           lease_supervisor: lease_supervisor,
           object_key_loader: Fake.KeyReader,
           wake_waiting: {WakeRecorder, self()}
         }}
      )

    assert :ok =
             activate!(
               custodian,
               unlocked_session("session-0", DateTime.add(@now, -1, :second))
             )

    assert :ok = activate!(custodian, unlocked_session("session-1"))
    assert :ok = activate!(custodian, unlocked_session("session-2"))

    for _session <- 1..3 do
      assert_receive {:wake_waiting, command}
      assert command == %{vault_id: @vault_id, limit: 25}
    end

    assert {:ok, first_lease} = KeyCustodian.lease(custodian, request)
    assert :ok = Fake.KeyReader.block_after_next_persist(context)

    first_step = Task.async(fn -> KeyLease.metadata_step(first_lease) end)

    assert_receive {
                     :checkpoint_persisted_blocked,
                     persister,
                     token,
                     first_binding,
                     ^checkpoint,
                     next_checkpoint
                   },
                   1_000

    refute Map.has_key?(first_binding, :session_id)
    assert next_checkpoint["version"] == 3
    assert next_checkpoint["protocol"] == "asset_metadata_v1"
    assert next_checkpoint["processing_revision"] == 5
    assert next_checkpoint["next_chunk_index"] == 1
    assert next_checkpoint["extractor_state"]["phase"] == "jpeg_scan"
    refute Map.has_key?(next_checkpoint, "session_id")
    refute Map.has_key?(next_checkpoint, "plaintext")
    assert Task.yield(first_step, 50) == nil

    assert :ok = Fake.KeyReader.release_persist(persister, token)
    assert {:continue, ^next_checkpoint} = Task.await(first_step)

    assert {:ok, revocation} =
             KeyCustodian.begin_revoke(custodian, %{session_id: "session-1"})

    assert :ok = KeyCustodian.finish_revoke(custodian, revocation)
    assert {:error, :waiting_for_unlock} = KeyLease.metadata_step(first_lease)

    assert {:ok, resumed_lease} = KeyCustodian.lease(custodian, request)

    assert {:done, metadata, final_checkpoint} =
             KeyLease.metadata_step(resumed_lease)

    assert metadata.width == 3
    assert metadata.height == 2
    assert final_checkpoint["next_chunk_index"] == 2
    assert final_checkpoint["extractor_state"]["phase"] == "done"
    refute Map.has_key?(final_checkpoint, "session_id")

    protocol_binding = Map.delete(request, :purpose)

    assert [{first_read_binding, 0}, {resumed_read_binding, 1}] =
             Fake.KeyReader.calls(context)

    assert first_read_binding.session_id == "session-1"
    assert resumed_read_binding.session_id == "session-2"
    assert Map.delete(first_read_binding, :session_id) == protocol_binding
    assert Map.delete(resumed_read_binding, :session_id) == protocol_binding

    assert [first_load, resumed_load] = Fake.KeyReader.load_calls(context)
    assert first_load.binding == protocol_binding
    assert resumed_load.binding == protocol_binding
    assert first_load.context == %{key_reader: key_reader}
    assert resumed_load.context == %{key_reader: key_reader}

    assert [first_persist, resumed_persist] = Fake.KeyReader.persist_calls(context)

    for persist <- [first_persist, resumed_persist] do
      assert persist.binding == protocol_binding
      assert persist.context == %{key_reader: key_reader}
      refute forbidden_checkpoint_term?(persist)
    end
  end

  test "revocation after checkpoint CAS but before reply resumes from the committed checkpoint" do
    jpeg = jpeg_with_sof_after_first_chunk()
    request = metadata_request("image/jpeg", byte_size(jpeg))
    {:ok, extractor_state} = MetadataExtractor.initial_state("image/jpeg", byte_size(jpeg))
    checkpoint = KeyLease.metadata_checkpoint(request, 0, extractor_state)

    clock = start_supervised!({Fake.Clock, now: @now})
    authorization = start_supervised!({Fake.Authorization, state: authorization_state()})

    key_reader =
      start_supervised!(
        {Fake.KeyReader,
         owner: self(),
         checkpoints: %{{request.job_id, request.vault_id, request.object_id} => checkpoint},
         chunks: %{
           0 => binary_part(jpeg, 0, @chunk_size),
           1 => binary_part(jpeg, @chunk_size, byte_size(jpeg) - @chunk_size)
         }}
      )

    context = %{authorization: authorization, clock: clock, key_reader: key_reader}
    lease_supervisor = start_supervised!({KeyLeaseSupervisor, []})

    custodian =
      start_supervised!(
        {KeyCustodian,
         %{
           authorization: Fake.Authorization,
           clock: Fake.Clock,
           context: context,
           idle_lock: {IdleLock, self()},
           key_reader: Fake.KeyReader,
           lease_supervisor: lease_supervisor,
           object_key_loader: Fake.KeyReader
         }}
      )

    assert :ok = activate!(custodian, unlocked_session("session-1"))
    assert {:ok, lease} = KeyCustodian.lease(custodian, request)
    assert :ok = Fake.KeyReader.block_after_next_persist(context)

    step = Task.async(fn -> KeyLease.metadata_step(lease) end)

    assert_receive {
                     :checkpoint_persisted_blocked,
                     persister,
                     token,
                     _binding,
                     ^checkpoint,
                     committed_checkpoint
                   },
                   1_000

    assert committed_checkpoint["next_chunk_index"] == 1

    assert {:ok, revocation} =
             KeyCustodian.begin_revoke(custodian, %{session_id: "session-1"})

    assert :ok = KeyCustodian.finish_revoke(custodian, revocation)
    assert {:error, :waiting_for_unlock} = Task.await(step)
    assert Fake.KeyReader.checkpoint(context, request) == committed_checkpoint

    assert :ok = Fake.KeyReader.release_persist(persister, token)
    assert :ok = activate!(custodian, unlocked_session("session-2"))
    assert {:ok, resumed} = KeyCustodian.lease(custodian, request)

    assert {:done, metadata, final_checkpoint} = KeyLease.metadata_step(resumed)
    assert metadata.width == 3
    assert metadata.height == 2
    assert final_checkpoint["next_chunk_index"] == 2
    assert [{_first_binding, 0}, {_fresh_binding, 1}] = Fake.KeyReader.calls(context)
  end

  test "metadata lease cannot outlive the selected unlocked session" do
    pdf = "%PDF-1.7\n"
    request = metadata_request("application/pdf", byte_size(pdf))
    {:ok, extractor_state} = MetadataExtractor.initial_state("application/pdf", byte_size(pdf))
    checkpoint = KeyLease.metadata_checkpoint(request, 0, extractor_state)

    clock = start_supervised!({Fake.Clock, now: @now})
    authorization = start_supervised!({Fake.Authorization, state: authorization_state()})

    key_reader =
      start_supervised!(
        {Fake.KeyReader,
         owner: self(),
         checkpoints: %{{request.job_id, request.vault_id, request.object_id} => checkpoint},
         chunks: %{0 => pdf}}
      )

    context = %{authorization: authorization, clock: clock, key_reader: key_reader}
    lease_supervisor = start_supervised!({KeyLeaseSupervisor, []})

    custodian =
      start_supervised!(
        {KeyCustodian,
         %{
           authorization: Fake.Authorization,
           clock: Fake.Clock,
           context: context,
           idle_lock: {IdleLock, self()},
           key_reader: Fake.KeyReader,
           lease_supervisor: lease_supervisor,
           object_key_loader: Fake.KeyReader
         }}
      )

    assert :ok =
             activate!(
               custodian,
               unlocked_session("session-short", DateTime.add(@now, 1, :second))
             )

    assert {:ok, lease} = KeyCustodian.lease(custodian, request)
    assert :ok = Fake.Clock.advance(context, 2)
    assert {:error, :waiting_for_unlock} = KeyLease.metadata_step(lease)
    assert Fake.KeyReader.calls(context) == []
  end

  test "zero-length metadata becomes a replayable terminal checkpoint without a chunk read" do
    request = metadata_request("application/pdf", 0)
    {:ok, extractor_state} = MetadataExtractor.initial_state("application/pdf", 0)
    checkpoint = KeyLease.metadata_checkpoint(request, 0, extractor_state)

    clock = start_supervised!({Fake.Clock, now: @now})
    authorization = start_supervised!({Fake.Authorization, state: authorization_state()})

    key_reader =
      start_supervised!(
        {Fake.KeyReader,
         owner: self(),
         checkpoints: %{{request.job_id, request.vault_id, request.object_id} => checkpoint},
         chunks: %{}}
      )

    context = %{authorization: authorization, clock: clock, key_reader: key_reader}
    lease_supervisor = start_supervised!({KeyLeaseSupervisor, []})

    custodian =
      start_supervised!(
        {KeyCustodian,
         %{
           authorization: Fake.Authorization,
           clock: Fake.Clock,
           context: context,
           idle_lock: {IdleLock, self()},
           key_reader: Fake.KeyReader,
           lease_supervisor: lease_supervisor,
           object_key_loader: Fake.KeyReader
         }}
      )

    assert :ok = activate!(custodian, unlocked_session("session-1"))
    assert {:ok, lease} = KeyCustodian.lease(custodian, request)

    assert {:error, %Error{code: :unsupported_media_type}, terminal_checkpoint} =
             KeyLease.metadata_step(lease)

    assert terminal_checkpoint["next_chunk_index"] == 1
    assert terminal_checkpoint["extractor_state"]["phase"] == "failed"

    assert {:error, %Error{code: :unsupported_media_type}, ^terminal_checkpoint} =
             KeyLease.metadata_step(lease)

    assert Fake.KeyReader.calls(context) == []
    assert length(Fake.KeyReader.persist_calls(context)) == 1
  end

  test "a fresh lease replays a strictly validated done checkpoint without plaintext reads" do
    request = metadata_request("application/pdf", 22)

    done_state = %{
      "phase" => "done",
      "result" => %{
        "detected_media_type" => "application/pdf",
        "plaintext_bytes" => 22,
        "width" => nil,
        "height" => nil,
        "pdf_version" => "1.7",
        "extractor_version" => 1
      }
    }

    checkpoint = KeyLease.metadata_checkpoint(request, 1, done_state)
    clock = start_supervised!({Fake.Clock, now: @now})
    authorization = start_supervised!({Fake.Authorization, state: authorization_state()})

    key_reader =
      start_supervised!(
        {Fake.KeyReader,
         owner: self(),
         checkpoints: %{{request.job_id, request.vault_id, request.object_id} => checkpoint},
         chunks: %{}}
      )

    context = %{authorization: authorization, clock: clock, key_reader: key_reader}
    lease_supervisor = start_supervised!({KeyLeaseSupervisor, []})

    custodian =
      start_supervised!(
        {KeyCustodian,
         %{
           authorization: Fake.Authorization,
           clock: Fake.Clock,
           context: context,
           idle_lock: {IdleLock, self()},
           key_reader: Fake.KeyReader,
           lease_supervisor: lease_supervisor,
           object_key_loader: Fake.KeyReader
         }}
      )

    assert :ok = activate!(custodian, unlocked_session("session-1"))
    assert {:ok, lease} = KeyCustodian.lease(custodian, request)

    assert {:done, metadata, ^checkpoint} = KeyLease.metadata_step(lease)
    assert metadata.pdf_version == "1.7"
    assert metadata.extractor_version == 1
    assert Fake.KeyReader.calls(context) == []
    assert Fake.KeyReader.persist_calls(context) == []
  end

  test "two metadata leases racing the same checkpoint expose only the CAS winner" do
    pdf = "%PDF-1.7\n"
    request = metadata_request("application/pdf", byte_size(pdf))
    {:ok, extractor_state} = MetadataExtractor.initial_state("application/pdf", byte_size(pdf))
    checkpoint = KeyLease.metadata_checkpoint(request, 0, extractor_state)

    clock = start_supervised!({Fake.Clock, now: @now})
    authorization = start_supervised!({Fake.Authorization, state: authorization_state()})

    key_reader =
      start_supervised!(
        {Fake.KeyReader,
         owner: self(),
         checkpoints: %{{request.job_id, request.vault_id, request.object_id} => checkpoint},
         chunks: %{0 => pdf}}
      )

    context = %{authorization: authorization, clock: clock, key_reader: key_reader}
    lease_supervisor = start_supervised!({KeyLeaseSupervisor, []})

    custodian =
      start_supervised!(
        {KeyCustodian,
         %{
           authorization: Fake.Authorization,
           clock: Fake.Clock,
           context: context,
           idle_lock: {IdleLock, self()},
           key_reader: Fake.KeyReader,
           lease_supervisor: lease_supervisor,
           object_key_loader: Fake.KeyReader
         }}
      )

    assert :ok = activate!(custodian, unlocked_session("session-1"))
    assert {:ok, delayed} = KeyCustodian.lease(custodian, request)
    assert {:ok, winner} = KeyCustodian.lease(custodian, request)
    assert :ok = Fake.KeyReader.block_next_read(context)

    delayed_step = Task.async(fn -> KeyLease.metadata_step(delayed) end)

    assert_receive {:key_reader_blocked, reader, token, _binding, 0}, 1_000

    assert {:done, metadata, final_checkpoint} = KeyLease.metadata_step(winner)
    assert metadata.pdf_version == "1.7"
    assert final_checkpoint["next_chunk_index"] == 1

    assert :ok = Fake.KeyReader.release_read(reader, token)
    assert {:retry, :checkpoint_advanced} = Task.await(delayed_step)

    assert Fake.KeyReader.checkpoint(context, request) == final_checkpoint
    assert_receive {:plaintext_chunk, 0, ^pdf}
    refute_receive {:plaintext_chunk, 0, ^pdf}
  end

  defp metadata_request(declared_media_type, plaintext_byte_size) do
    %{
      purpose: :metadata,
      job_id: "job-1",
      vault_id: @vault_id,
      principal_id: @principal_id,
      required_capability: "asset.read",
      principal_authorization_epoch: 7,
      vault_authorization_epoch: 23,
      object_id: @object_id,
      object_generation: 3,
      processing_revision: 5,
      declared_media_type: declared_media_type,
      plaintext_byte_size: plaintext_byte_size
    }
  end

  defp unlocked_session(session_id, expires_at \\ DateTime.add(@now, 300, :second)) do
    %{
      session_id: session_id,
      expires_at: expires_at,
      principal_id: @principal_id,
      vault_id: @vault_id,
      principal_authorization_epoch: 7,
      vault_authorization_epoch: 23,
      vault_key: :binary.copy(<<0xA1>>, 32),
      domain_key: :binary.copy(<<0xB2>>, 32),
      domain_dedup_key: :binary.copy(<<0xD4>>, 32),
      key_domain_id: "domain-1",
      domain_key_version_id: "domain-version-1",
      domain_key_generation: 5,
      domain_classification: :private,
      object_keys: %{{@object_id, 3} => :binary.copy(<<0xC3>>, 32)}
    }
  end

  defp activate!(custodian, session) do
    with {:ok, pending} <- KeyCustodian.prepare_unlock(custodian, session) do
      KeyCustodian.activate_unlock(custodian, pending)
    end
  end

  defp authorization_state do
    %{
      sessions: %{
        "session-0" => %{status: :active, principal_id: @principal_id, vault_id: @vault_id},
        "session-1" => %{status: :active, principal_id: @principal_id, vault_id: @vault_id},
        "session-2" => %{status: :active, principal_id: @principal_id, vault_id: @vault_id}
      },
      principals: %{@principal_id => :active},
      authorizations: %{
        {@principal_id, @vault_id} => %{
          principal_authorization_epoch: 7,
          vault_authorization_epoch: 23,
          capabilities: MapSet.new(["asset.read"])
        }
      },
      object_generations: %{{@vault_id, @object_id} => 3}
    }
  end

  defp jpeg_with_sof_after_first_chunk do
    segment =
      <<0xFF, 0xE0, 65_535::unsigned-big-16>> <>
        :binary.copy(<<0>>, 65_533)

    sof =
      <<0xFF, 0xC0, 11::unsigned-big-16, 8, 2::unsigned-big-16, 3::unsigned-big-16, 1, 1, 0x11,
        0>>

    <<0xFF, 0xD8>> <> :binary.copy(segment, 64) <> sof
  end

  defp forbidden_checkpoint_term?(term) when is_map(term) do
    Enum.any?(term, fn {key, value} ->
      key in [
        :session_id,
        "session_id",
        :key_material,
        "key_material",
        :object_binding,
        "object_binding",
        :lookup_digest,
        "lookup_digest",
        :ciphertext_hash,
        "ciphertext_hash",
        :wrapped_dek,
        "wrapped_dek",
        :storage_ref,
        "storage_ref"
      ] or forbidden_checkpoint_term?(value)
    end)
  end

  defp forbidden_checkpoint_term?(term) when is_list(term),
    do: Enum.any?(term, &forbidden_checkpoint_term?/1)

  defp forbidden_checkpoint_term?(_term), do: false
end
