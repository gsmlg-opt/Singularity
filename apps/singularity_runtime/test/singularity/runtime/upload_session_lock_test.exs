defmodule Singularity.Runtime.UploadSessionLockTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.Error
  alias Singularity.Core.StageRef
  alias Singularity.Runtime.Assets.UploadSession
  alias Singularity.Runtime.SessionContext
  alias Singularity.Storage.EncryptedStageWriter
  alias Singularity.Storage.LocalFilesystemAdapter

  @principal_id "00000000-0000-4000-8000-000000000101"
  @vault_id "00000000-0000-4000-8000-000000000102"
  @session_id "00000000-0000-4000-8000-000000000103"
  @grant_id "00000000-0000-4000-8000-000000000104"
  @asset_id "00000000-0000-4000-8000-000000000105"
  @stage_id "00000000-0000-4000-8000-000000000106"
  @object_id "00000000-0000-4000-8000-000000000107"
  @key_domain_id "00000000-0000-4000-8000-000000000108"
  @domain_key_version_id "00000000-0000-4000-8000-000000000109"
  @resource_version_id "00000000-0000-4000-8000-000000000110"
  @storage_ref "00000000-0000-4000-8000-000000000111"
  @raw_token "CANARY_UPLOAD_TOKEN_6b21_1234567"

  defmodule RequestRepo do
    def checkout(test, callback) do
      send(test, {:checkout_acquired, self()})

      try do
        callback.()
      after
        send(test, {:checkout_released, self()})
      end
    end
  end

  defmodule VaultLock do
    def with_shared_checked_out(test, repo, vault_id, callback) do
      send(test, {:vault_lock_acquired, self(), repo, vault_id})

      try do
        callback.(repo)
      after
        send(test, {:vault_lock_released, self(), vault_id})
      end
    end
  end

  defmodule AuthorizationLock do
    def with_shared(test, repo, principal_id, vault_id, callback) do
      send(
        test,
        {:authorization_lock_acquired, self(), repo, principal_id, vault_id}
      )

      try do
        callback.(repo)
      after
        send(
          test,
          {:authorization_lock_released, self(), principal_id, vault_id}
        )
      end
    end
  end

  defmodule ScopedRepo do
    def transact(test, repo, context, callback) do
      send(test, {:transaction_started, self(), context})

      case callback.(repo) do
        {:error, %Error{}} = error ->
          send(test, {:transaction_rolled_back, self(), error})
          error

        result ->
          send(test, {:transaction_committed, self(), result})
          result
      end
    end
  end

  defmodule Authorizer do
    def check(test, :authorization, _repo, session, requirement) do
      send(test, {:authorized, self(), session, requirement})
      :ok
    end
  end

  defmodule Assets do
    def consume_grant_and_create_stage(test, _repo, command) do
      send(test, {:grant_consumption_requested, self(), command})

      receive do
        {:allow_grant_consumption, ^test} ->
          {:ok,
           %{
             id: command.stage_id,
             asset_id: command.asset_id,
             upload_grant_id: command.grant_id,
             vault_id: command.vault_id,
             classification: command.classification,
             storage_ref: command.storage_ref,
             state: :open,
             state_revision: 0
           }}
      end
    end

    def record_sealed_stage(test, _repo, command) do
      send(test, {:sealed_checkpoint_requested, self(), command})

      receive do
        {:allow_sealed_checkpoint, ^test} ->
          {:ok,
           %{
             asset: %{
               asset_id: command.asset_id,
               state: :uploaded,
               state_revision: 1
             },
             stage: %{
               id: command.stage_ref.stage_id,
               state: :sealed,
               state_revision: 1
             }
           }}
      end
    end

    def mark_stage_abandoned(test, _repo, command) do
      send(test, {:stage_abandoned, self(), command})

      {:ok,
       %{
         id: command.stage_id,
         state: :abandoned,
         state_revision: command.expected_stage_revision + 1
       }}
    end
  end

  defmodule Writer do
    def stream_and_seal_stage(test, _storage, upload, stream) do
      send(test, {:writer_started, self(), upload})

      Enum.each(stream, fn chunk ->
        send(test, {:writer_chunk, self(), chunk})

        receive do
          {:continue_writer, ^test} -> :ok
        end
      end)

      send(test, {:stage_synced, self()})

      {:ok,
       %{
         stage_ref: upload.stage_ref,
         object_ref: %{object_id: upload.object_id},
         plaintext_byte_size: upload.expected_bytes,
         ciphertext_byte_size: upload.expected_bytes + 134,
         lookup_digest: :binary.copy(<<0xA1>>, 32),
         ciphertext_hash: :binary.copy(<<0xB2>>, 32),
         format_version: 1,
         dek_wrapper: upload.dek_wrapper
       }}
    end
  end

  defmodule Storage do
    def abort_stage(test, %StageRef{} = stage_ref) do
      send(test, {:physical_stage_aborted, self(), stage_ref})
      :ok
    end
  end

  defmodule AttachFailureCustodian do
    def claim_upload(test, _material_ref, binding) do
      custody_ref = make_ref()
      send(test, {:upload_material_claimed, self(), custody_ref, binding})

      {:ok,
       %{
         object_dek: :binary.copy(<<0xE9>>, 32),
         domain_dedup_key: :binary.copy(<<0xFA>>, 32),
         custody_ref: custody_ref
       }}
    end

    def attach_upload_worker(test, custody_ref, writer) do
      send(test, {:custody_attach_failed, self(), custody_ref, writer})

      {:error,
       Singularity.Core.Error.new(
         :storage_unavailable,
         retryable?: true
       )}
    end
  end

  defmodule RetriedAbandonmentAssets do
    def consume_grant_and_create_stage(test, repo, command),
      do:
        Singularity.Runtime.UploadSessionLockTest.Assets.consume_grant_and_create_stage(
          test,
          repo,
          command
        )

    def record_sealed_stage(test, repo, command),
      do:
        Singularity.Runtime.UploadSessionLockTest.Assets.record_sealed_stage(
          test,
          repo,
          command
        )

    def mark_stage_abandoned(test, _repo, command) do
      send(test, {:stage_abandoned, self(), command})

      receive do
        {:complete_stage_abandonment, result} -> result
      end
    end
  end

  test "initialized upload state retains neither raw nor encoded grant tokens" do
    encoded_token = Base.url_encode64(@raw_token, padding: false)

    raw_state = initial_state(@raw_token)
    encoded_state = initial_state(encoded_token)

    for state <- [raw_state, encoded_state],
        secret <- [@raw_token, encoded_token] do
      refute retained_binary?(state, secret)
    end
  end

  test "pins both locks across streaming and acknowledges finish only after the second commit" do
    {:ok, session} = start_session(self())

    append =
      Task.async(fn ->
        UploadSession.append(session, "%PDF-pinned")
      end)

    assert_receive {:checkout_acquired, ^session}
    assert_receive {:vault_lock_acquired, ^session, RequestRepo, @vault_id}

    assert_receive {:authorization_lock_acquired, ^session, RequestRepo, @principal_id, @vault_id}

    assert_receive {:transaction_started, ^session, transaction_context}
    assert transaction_context == %{principal_id: @principal_id, vault_id: @vault_id}

    assert_receive {:authorized, ^session, %SessionContext{}, requirement}
    assert requirement.required_capability == "asset.write"
    assert requirement.classification == :private
    assert requirement.requires_unlocked?

    assert_receive {:grant_consumption_requested, ^session, consume_command}
    refute Map.has_key?(consume_command, :token)
    refute inspect(consume_command, limit: :infinity) =~ @raw_token
    assert consume_command.token_digest == :crypto.hash(:sha256, @raw_token)
    assert consume_command.stage_id == @stage_id
    assert consume_command.candidate_object_id == @object_id
    refute Map.has_key?(consume_command, :object_dek)
    refute Map.has_key?(consume_command, :domain_dedup_key)

    refute_receive {:writer_started, _, _}, 30
    refute_receive {:writer_chunk, _, _}, 30

    send(session, {:allow_grant_consumption, self()})

    assert_receive {:transaction_committed, ^session, {:ok, %{state: :open}}}
    assert {:ok, ^session} = UploadSession.await_ready(session)
    assert_receive {:writer_started, writer, upload}
    assert upload.stage_ref == %StageRef{stage_id: @stage_id}
    assert upload.object_id == consume_command.candidate_object_id
    assert upload.encryption_domain_id == consume_command.key_domain_id
    assert upload.max_bytes == 512 * 1024 * 1024

    assert_receive {:writer_chunk, ^writer, "%PDF-pinned"}
    assert Task.yield(append, 30) == nil
    refute_receive {:vault_lock_released, ^session, _}, 30
    refute_receive {:authorization_lock_released, ^session, _, _}, 30
    refute_receive {:checkout_released, ^session}, 30

    send(writer, {:continue_writer, self()})
    assert :ok = Task.await(append)

    finish = Task.async(fn -> UploadSession.finish(session) end)

    assert_receive {:stage_synced, ^writer}
    assert_receive {:transaction_started, ^session, ^transaction_context}
    assert_receive {:authorized, ^session, %SessionContext{}, ^requirement}
    assert_receive {:sealed_checkpoint_requested, ^session, checkpoint}
    assert checkpoint.stage_ref == %StageRef{stage_id: @stage_id}
    assert checkpoint.expected_stage_revision == 0
    assert checkpoint.expected_asset_revision == 0
    assert checkpoint.plaintext_byte_size == byte_size("%PDF-pinned")
    refute Map.has_key?(checkpoint, :object_dek)

    assert Task.yield(finish, 30) == nil
    refute_receive {:vault_lock_released, ^session, _}, 30
    refute_receive {:checkout_released, ^session}, 30

    send(session, {:allow_sealed_checkpoint, self()})

    assert {:ok, %{asset: %{state: :uploaded}, stage: %{state: :sealed}}} =
             Task.await(finish)

    assert_receive {:transaction_committed, ^session, {:ok, %{asset: _, stage: _}}}
    assert_receive {:authorization_lock_released, ^session, @principal_id, @vault_id}
    assert_receive {:vault_lock_released, ^session, @vault_id}
    assert_receive {:checkout_released, ^session}
  end

  test "controller exit abandons the durable stage once and releases locks and checkout" do
    controller = spawn(fn -> Process.sleep(:infinity) end)
    {:ok, session} = start_session(controller)

    assert_receive {:grant_consumption_requested, ^session, _command}
    send(session, {:allow_grant_consumption, self()})
    assert {:ok, ^session} = UploadSession.await_ready(session)
    assert_receive {:writer_started, writer, _upload}

    Process.exit(controller, :kill)

    assert_receive {:transaction_started, ^session, _context}
    assert_receive {:stage_abandoned, ^session, abandonment}
    assert abandonment.stage_id == @stage_id
    assert abandonment.grant_id == @grant_id
    assert abandonment.failure_code == "controller_disconnected"
    assert abandonment.expected_stage_revision == 0

    assert_receive {:transaction_committed, ^session, {:ok, %{state: :abandoned}}}
    assert_receive {:authorization_lock_released, ^session, @principal_id, @vault_id}
    assert_receive {:vault_lock_released, ^session, @vault_id}
    assert_receive {:checkout_released, ^session}
    refute_receive {:stage_abandoned, ^session, _}, 50
    refute Process.alive?(writer)
  end

  test "controller exit removes a real partially written stage before abandonment" do
    storage_root =
      Path.join(
        System.tmp_dir!(),
        "singularity-upload-abort-#{Ecto.UUID.generate()}"
      )

    File.mkdir_p!(storage_root)
    on_exit(fn -> File.rm_rf!(storage_root) end)

    controller = spawn(fn -> Process.sleep(:infinity) end)

    storage = %{
      adapter: LocalFilesystemAdapter,
      context: %{root: storage_root},
      dedup_lookup: fn _vault_id, _key_domain_id, _lookup_digest ->
        :miss
      end,
      destroy_dek_wrapper: fn _wrapped_dek -> :ok end
    }

    runtime =
      runtime()
      |> Map.put(:stage_writer, EncryptedStageWriter)

    {:ok, session} =
      start_supervised(
        {UploadSession,
         runtime: runtime,
         session: session_context(),
         grant: grant(),
         owner: controller,
         storage: storage,
         upload: upload_material()}
      )

    assert_receive {:grant_consumption_requested, ^session, _command}
    send(session, {:allow_grant_consumption, self()})
    assert {:ok, ^session} = UploadSession.await_ready(session)
    assert :ok = UploadSession.append(session, "%PDF-partial")

    assert {:ok, [%StageRef{stage_id: @stage_id}]} =
             LocalFilesystemAdapter.list_staged(storage.context)

    session_monitor = Process.monitor(session)
    Process.exit(controller, :kill)

    assert_receive {:stage_abandoned, ^session, _abandonment}
    assert_receive {:DOWN, ^session_monitor, :process, ^session, :normal}

    assert {:ok, []} =
             LocalFilesystemAdapter.list_staged(storage.context)
  end

  test "rejects invalid magic before plaintext reaches the encrypted writer" do
    {:ok, session} = start_session(self())

    assert_receive {:grant_consumption_requested, ^session, _command}
    send(session, {:allow_grant_consumption, self()})
    assert {:ok, ^session} = UploadSession.await_ready(session)
    assert_receive {:writer_started, _writer, _upload}

    append = Task.async(fn -> UploadSession.append(session, "not-a-pdf") end)

    assert {:ok, {:error, %Error{code: :unsupported_media_type}}} =
             Task.yield(append, 500)

    refute_receive {:writer_chunk, _writer, _chunk}
    assert_receive {:stage_abandoned, ^session, abandonment}
    assert abandonment.failure_code == "unsupported_media_type"
  end

  test "validates a fragmented magic prefix before flushing buffered chunks" do
    {:ok, session} = start_session(self())

    assert_receive {:grant_consumption_requested, ^session, _command}
    send(session, {:allow_grant_consumption, self()})
    assert {:ok, ^session} = UploadSession.await_ready(session)
    assert_receive {:writer_started, writer, _upload}

    assert :ok = UploadSession.append(session, "%P")
    refute_receive {:writer_chunk, ^writer, _chunk}, 30

    append = Task.async(fn -> UploadSession.append(session, "DF-pinned") end)

    assert_receive {:writer_chunk, ^writer, "%P"}
    send(writer, {:continue_writer, self()})
    assert_receive {:writer_chunk, ^writer, "DF-pinned"}
    send(writer, {:continue_writer, self()})
    assert :ok = Task.await(append)

    finish = Task.async(fn -> UploadSession.finish(session) end)
    assert_receive {:stage_synced, ^writer}
    assert_receive {:sealed_checkpoint_requested, ^session, _checkpoint}
    send(session, {:allow_sealed_checkpoint, self()})
    assert {:ok, %{asset: %{state: :uploaded}}} = Task.await(finish)
  end

  test "a killed upload session cannot leave its key-bearing writer alive" do
    {:ok, session} = start_session(self())

    assert_receive {:grant_consumption_requested, ^session, _command}
    send(session, {:allow_grant_consumption, self()})
    assert {:ok, ^session} = UploadSession.await_ready(session)
    assert_receive {:writer_started, writer, _upload}

    writer_monitor = Process.monitor(writer)
    session_monitor = Process.monitor(session)
    Process.exit(session, :kill)

    assert_receive {:DOWN, ^session_monitor, :process, ^session, :killed}
    assert_receive {:DOWN, ^writer_monitor, :process, ^writer, _reason}
  end

  test "failed setup loop accepts only its authenticated custody revocation" do
    runtime =
      runtime()
      |> Map.put(:assets, {RetriedAbandonmentAssets, self()})
      |> Map.put(:custodian, {AttachFailureCustodian, self()})

    upload =
      upload_material()
      |> Map.drop([:object_dek, :domain_dedup_key])
      |> Map.put(:material_ref, make_ref())

    {:ok, session} =
      start_supervised(
        {UploadSession,
         runtime: runtime,
         session: session_context(),
         grant: grant(),
         owner: self(),
         storage: storage(self()),
         upload: upload}
      )

    session_monitor = Process.monitor(session)

    assert_receive {:grant_consumption_requested, ^session, _command}
    send(session, {:allow_grant_consumption, self()})

    assert_receive {:upload_material_claimed, ^session, custody_ref, binding}
    assert binding.stage_id == @stage_id
    assert binding.storage_ref == @storage_ref

    assert_receive {:custody_attach_failed, ^session, ^custody_ref, writer}
    writer_monitor = Process.monitor(writer)
    assert_receive {:DOWN, ^writer_monitor, :process, ^writer, _reason}

    assert_receive {:stage_abandoned, ^session, first_abandonment}
    assert first_abandonment.failure_code == "storage_unavailable"

    send(
      session,
      {:complete_stage_abandonment, {:error, Error.new(:storage_unavailable, retryable?: true)}}
    )

    spoofed_ref = make_ref()
    send(session, {:custody_revoke, spoofed_ref, make_ref(), self()})
    refute_receive {:physical_stage_aborted, ^session, _stage_ref}, 50

    revocation_ref = make_ref()

    send(
      session,
      {:custody_revoke, custody_ref, revocation_ref, self()}
    )

    assert_receive {:physical_stage_aborted, ^session, %StageRef{stage_id: @stage_id}}

    assert_receive {:stage_abandoned, ^session, second_abandonment}
    assert second_abandonment.failure_code == "custody_revoked"

    send(
      session,
      {:complete_stage_abandonment,
       {:ok,
        %{
          id: @stage_id,
          state: :abandoned,
          state_revision: 1
        }}}
    )

    assert_receive {:custody_revoke_result, ^session, ^custody_ref, ^revocation_ref,
                    {:ok, %{state: :abandoned}}}

    assert_receive {:DOWN, ^session_monitor, :process, ^session, :normal}
  end

  defp start_session(controller) do
    start_supervised(
      {UploadSession,
       runtime: runtime(),
       session: session_context(),
       grant: grant(),
       owner: controller,
       storage: storage(self()),
       upload: upload_material()}
    )
  end

  defp initial_state(token) do
    assert {:ok, state} =
             UploadSession.initial_state(
               runtime: runtime(),
               session: session_context(),
               grant: Map.put(grant(), :token, token),
               owner: self(),
               storage: storage(self()),
               upload: upload_material()
             )

    refute Map.has_key?(state.consume_command, :token)
    assert state.consume_command.token_digest == :crypto.hash(:sha256, @raw_token)

    state
  end

  defp retained_binary?(binary, secret) when is_binary(binary),
    do: :binary.match(binary, secret) != :nomatch

  defp retained_binary?(map, secret) when is_map(map) do
    map
    |> Map.to_list()
    |> Enum.any?(fn {key, value} ->
      retained_binary?(key, secret) or retained_binary?(value, secret)
    end)
  end

  defp retained_binary?(tuple, secret) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> retained_binary?(secret)

  defp retained_binary?(list, secret) when is_list(list),
    do: Enum.any?(list, &retained_binary?(&1, secret))

  defp retained_binary?(_term, _secret), do: false

  def storage(test) do
    %{adapter: Storage, context: test}
  end

  defp runtime do
    test = self()

    %{
      request_repo: {RequestRepo, test},
      vault_lock: {VaultLock, test},
      authorization_lock: {AuthorizationLock, test},
      scoped_repo: {ScopedRepo, test},
      authorizer: {Authorizer, test},
      authorization: :authorization,
      assets: {Assets, test},
      stage_writer: {Writer, test},
      clock: fn -> DateTime.utc_now(:microsecond) end
    }
  end

  defp session_context do
    %SessionContext{
      session_id: @session_id,
      principal_id: @principal_id,
      vault_id: @vault_id,
      expires_at: DateTime.add(DateTime.utc_now(:microsecond), 600, :second),
      principal_authorization_epoch: 7,
      vault_authorization_epoch: 11,
      authorization_epoch: 7,
      unlocked?: true
    }
  end

  defp grant do
    %{
      id: @grant_id,
      grant_id: @grant_id,
      token: @raw_token,
      session_id: @session_id,
      principal_id: @principal_id,
      vault_id: @vault_id,
      asset_id: @asset_id,
      resource_version_id: @resource_version_id,
      filename: "pinned.pdf",
      byte_size: byte_size("%PDF-pinned"),
      declared_media_type: "application/pdf",
      idempotency_key: "upload-session-pinned",
      classification: :private,
      principal_authorization_epoch: 7,
      vault_authorization_epoch: 11,
      expires_at: DateTime.add(DateTime.utc_now(:microsecond), 300, :second)
    }
  end

  defp upload_material do
    %{
      stage_id: @stage_id,
      candidate_object_id: @object_id,
      object_id: @object_id,
      key_domain_id: @key_domain_id,
      encryption_domain_id: @key_domain_id,
      domain_key_version_id: @domain_key_version_id,
      storage_ref: @storage_ref,
      wrapper_algorithm: "aes_256_gcm",
      key_generation: 1,
      dek_wrapper: :binary.copy(<<0xD8>>, 60),
      object_dek: :binary.copy(<<0xE9>>, 32),
      domain_dedup_key: :binary.copy(<<0xFA>>, 32),
      max_bytes: 512 * 1024 * 1024
    }
  end
end

defmodule Singularity.Runtime.UploadSessionRealLockTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias Singularity.Core.StageRef
  alias Singularity.Runtime.Assets.UploadSession
  alias Singularity.Runtime.SessionContext
  alias Singularity.Runtime.UploadSessionLockTest
  alias Singularity.Runtime.UploadSessionSupervisor
  alias Singularity.Storage.RequestRepo
  alias Singularity.Storage.VaultLock

  test "a real backup-exclusive vault lock waits through stream and sealed acknowledgement" do
    ids = ids()

    {:ok, upload_session} =
      UploadSession.start_link(
        runtime: runtime(),
        session: session(ids),
        grant: grant(ids),
        owner: self(),
        storage: UploadSessionLockTest.storage(self()),
        upload: upload_material(ids)
      )

    assert_receive {:grant_consumption_requested, ^upload_session, _command}
    send(upload_session, {:allow_grant_consumption, self()})
    assert {:ok, ^upload_session} = UploadSession.await_ready(upload_session)
    assert_receive {:writer_started, writer, _upload}

    append =
      Task.async(fn ->
        UploadSession.append(upload_session, "%PDF-real-lock")
      end)

    assert_receive {:writer_chunk, ^writer, "%PDF-real-lock"}

    observer = self()

    exclusive =
      Task.async(fn ->
        VaultLock.with_exclusive(RequestRepo, ids.vault_id, fn _repo ->
          send(observer, :backup_exclusive_acquired)
          :ok
        end)
      end)

    refute_receive :backup_exclusive_acquired, 100
    send(writer, {:continue_writer, self()})
    assert :ok = Task.await(append)
    refute_receive :backup_exclusive_acquired, 100

    finish = Task.async(fn -> UploadSession.finish(upload_session) end)
    assert_receive {:stage_synced, ^writer}
    assert_receive {:sealed_checkpoint_requested, ^upload_session, checkpoint}
    assert checkpoint.stage_ref == %StageRef{stage_id: ids.stage_id}
    refute_receive :backup_exclusive_acquired, 100

    send(upload_session, {:allow_sealed_checkpoint, self()})

    assert {:ok, %{asset: %{state: :uploaded}, stage: %{state: :sealed}}} =
             Task.await(finish)

    assert_receive :backup_exclusive_acquired
    assert :ok = Task.await(exclusive)
  end

  test "maximum real pinned uploads leave RequestRepo capacity for normal work" do
    supervisor =
      start_supervised!({UploadSessionSupervisor, name: nil, max_children: 2})

    runtime =
      runtime()
      |> Map.put(:upload_session_supervisor, supervisor)

    controller = self()
    first = ids()
    second = ids()
    third = ids()

    first_start =
      Task.async(fn ->
        UploadSessionSupervisor.begin_upload(
          runtime,
          session(first),
          grant(first) |> Map.put(:upload, upload_material(first)),
          controller
        )
      end)

    assert_receive {:grant_consumption_requested, first_session, _command}
    send(first_session, {:allow_grant_consumption, self()})
    assert {:ok, ^first_session} = Task.await(first_start)

    second_start =
      Task.async(fn ->
        UploadSessionSupervisor.begin_upload(
          runtime,
          session(second),
          grant(second) |> Map.put(:upload, upload_material(second)),
          controller
        )
      end)

    assert_receive {:grant_consumption_requested, second_session, _command}
    send(second_session, {:allow_grant_consumption, self()})
    assert {:ok, ^second_session} = Task.await(second_start)

    assert {:error, %{code: :storage_unavailable, retryable?: true}} =
             UploadSessionSupervisor.begin_upload(
               runtime,
               session(third),
               grant(third) |> Map.put(:upload, upload_material(third)),
               controller
             )

    assert 1 ==
             RequestRepo.checkout(fn ->
               %{rows: [[value]]} =
                 Ecto.Adapters.SQL.query!(
                   RequestRepo,
                   "SELECT 1",
                   [],
                   log: false
                 )

               value
             end)

    assert :ok = UploadSession.abandon(first_session)
    assert :ok = UploadSession.abandon(second_session)
  end

  defp runtime do
    test = self()

    %{
      request_repo: RequestRepo,
      vault_lock: VaultLock,
      authorization_lock: {UploadSessionLockTest.AuthorizationLock, test},
      scoped_repo: {UploadSessionLockTest.ScopedRepo, test},
      authorizer: {UploadSessionLockTest.Authorizer, test},
      authorization: :authorization,
      assets: {UploadSessionLockTest.Assets, test},
      stage_writer: {UploadSessionLockTest.Writer, test},
      storage: UploadSessionLockTest.storage(test),
      clock: fn -> DateTime.utc_now(:microsecond) end
    }
  end

  defp session(ids) do
    %SessionContext{
      session_id: ids.session_id,
      principal_id: ids.principal_id,
      vault_id: ids.vault_id,
      expires_at: DateTime.add(DateTime.utc_now(:microsecond), 600, :second),
      principal_authorization_epoch: 7,
      vault_authorization_epoch: 11,
      authorization_epoch: 7,
      unlocked?: true
    }
  end

  defp grant(ids) do
    %{
      id: ids.grant_id,
      grant_id: ids.grant_id,
      token: :binary.copy(<<0xC7>>, 32),
      session_id: ids.session_id,
      principal_id: ids.principal_id,
      vault_id: ids.vault_id,
      asset_id: ids.asset_id,
      resource_version_id: ids.resource_version_id,
      filename: "real-lock.pdf",
      byte_size: byte_size("%PDF-real-lock"),
      declared_media_type: "application/pdf",
      idempotency_key: "upload-session-real-lock",
      classification: :private,
      principal_authorization_epoch: 7,
      vault_authorization_epoch: 11,
      expires_at: DateTime.add(DateTime.utc_now(:microsecond), 300, :second)
    }
  end

  defp upload_material(ids) do
    %{
      stage_id: ids.stage_id,
      candidate_object_id: ids.object_id,
      object_id: ids.object_id,
      key_domain_id: ids.key_domain_id,
      encryption_domain_id: ids.key_domain_id,
      domain_key_version_id: ids.domain_key_version_id,
      storage_ref: ids.storage_ref,
      wrapper_algorithm: "aes_256_gcm",
      key_generation: 1,
      dek_wrapper: :binary.copy(<<0xD8>>, 60),
      object_dek: :binary.copy(<<0xE9>>, 32),
      domain_dedup_key: :binary.copy(<<0xFA>>, 32),
      max_bytes: 512 * 1024 * 1024
    }
  end

  defp ids do
    %{
      principal_id: Ecto.UUID.generate(),
      vault_id: Ecto.UUID.generate(),
      session_id: Ecto.UUID.generate(),
      grant_id: Ecto.UUID.generate(),
      asset_id: Ecto.UUID.generate(),
      stage_id: Ecto.UUID.generate(),
      object_id: Ecto.UUID.generate(),
      key_domain_id: Ecto.UUID.generate(),
      domain_key_version_id: Ecto.UUID.generate(),
      resource_version_id: Ecto.UUID.generate(),
      storage_ref: Ecto.UUID.generate()
    }
  end
end
