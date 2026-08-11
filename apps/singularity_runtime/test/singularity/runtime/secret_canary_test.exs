defmodule Singularity.Runtime.SecretCanaryTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Singularity.Core.Error
  alias Singularity.Runtime.Api
  alias Singularity.Runtime.Assets.CreateUploadGrant
  alias Singularity.Runtime.Audit
  alias Singularity.Runtime.BackupKeyLease
  alias Singularity.Runtime.BackupVault
  alias Singularity.Runtime.DownloadLease
  alias Singularity.Runtime.DTO.Session, as: SessionDTO
  alias Singularity.Runtime.KeyCustodian
  alias Singularity.Runtime.KeyLease
  alias Singularity.Runtime.KeyLeaseSupervisor
  alias Singularity.Runtime.Login
  alias Singularity.Runtime.Observability.Redactor
  alias Singularity.Runtime.Observability.Telemetry
  alias Singularity.Runtime.RestoreVault
  alias Singularity.Runtime.RestoreIntegrityLease
  alias Singularity.Runtime.SessionContext
  alias Singularity.Storage.Crypto.ChunkedAEAD

  @password "CANARY_PASSWORD_8e4a"
  @audit_fingerprint_secret "CANARY_AUDIT_FINGERPRINT_SECRET_32B"
  @upload_token "CANARY_UPLOAD_TOKEN_6b21_1234567"
  @csrf_token "CANARY_CSRF_c091"
  @backup_passphrase "CANARY_BACKUP_1d0c"
  @vault_key "CANARY_VAULT_KEY_d112_1234567890"
  @domain_key "CANARY_DOMAIN_KEY_a477_123456789"
  @domain_dedup_key "CANARY_DOMAIN_DEDUP_KEY_b579_123"
  @object_key "CANARY_OBJECT_KEY_f862_123456789"
  @canaries %{
    password: @password,
    audit_fingerprint_secret: @audit_fingerprint_secret,
    upload_token: @upload_token,
    csrf_token: @csrf_token,
    vault_key: @vault_key,
    domain_key: @domain_key,
    dek: "CANARY_DEK_f862",
    backup_passphrase: @backup_passphrase
  }

  defmodule Canary do
    def leaks(term, canary, allowed_paths \\ []) do
      term
      |> walk([], canary, MapSet.new(allowed_paths))
      |> Enum.reverse()
    end

    def forms(canary) do
      [
        canary,
        Base.encode16(canary, case: :lower),
        Base.encode16(canary, case: :upper),
        Base.encode64(canary),
        Base.url_encode64(canary),
        Base.url_encode64(canary, padding: false),
        inspect(canary),
        inspect(:binary.bin_to_list(canary), limit: :infinity)
      ]
      |> Enum.uniq()
    end

    defp walk(value, path, canary, allowed_paths) when is_binary(value) do
      if MapSet.member?(allowed_paths, path) do
        []
      else
        for form <- forms(canary), String.contains?(value, form), do: {path, form}
      end
    end

    defp walk(value, path, canary, allowed_paths) when is_list(value) do
      if Enum.all?(value, &is_integer/1) do
        walk(inspect(value, limit: :infinity), path, canary, allowed_paths)
      else
        value
        |> Enum.with_index()
        |> Enum.flat_map(fn {entry, index} ->
          walk(entry, path ++ [index], canary, allowed_paths)
        end)
      end
    end

    defp walk(value, path, canary, allowed_paths) when is_tuple(value) do
      value
      |> Tuple.to_list()
      |> Enum.with_index()
      |> Enum.flat_map(fn {entry, index} ->
        walk(entry, path ++ [index], canary, allowed_paths)
      end)
    end

    defp walk(%_{} = value, path, canary, allowed_paths) do
      value
      |> Map.from_struct()
      |> walk(path, canary, allowed_paths)
    end

    defp walk(value, path, canary, allowed_paths) when is_map(value) do
      Enum.flat_map(value, fn {key, entry} ->
        walk(entry, path ++ [key], canary, allowed_paths)
      end)
    end

    defp walk(value, path, canary, allowed_paths) do
      walk(inspect(value, limit: :infinity), path, canary, allowed_paths)
    end
  end

  defmodule Clock do
    def utc_now(_context), do: DateTime.utc_now()
  end

  defmodule Authorization do
    def revalidate(_context, _binding), do: :ok
  end

  defmodule SecretErrorReader do
    def read_chunk(%{secret: secret}, _binding, _index) do
      {:error,
       Error.new(:storage_unavailable,
         message: secret,
         details: %{token: secret},
         retryable?: true
       )}
    end

    def read_range(%{secret: secret}, _binding, _range) do
      {:error,
       Error.new(:storage_unavailable,
         message: secret,
         details: %{token: secret},
         retryable?: true
       )}
    end
  end

  defmodule RaisingReader do
    def read_chunk(%{secret: secret}, _binding, _index), do: raise(secret)
    def read_range(%{secret: secret}, _binding, _range), do: raise(secret)
  end

  defmodule RawErrorReader do
    def read_chunk(%{secret: secret}, _binding, _index), do: {:error, secret}
  end

  defmodule LoginPreAuth do
    def reserve_attempt(owner, command) do
      send(owner, {:login_surface, :pre_auth_reserve, command})
      {:ok, %{id: "attempt-canary", accepted?: true}}
    end

    def authentication_candidate(owner, normalized_login) do
      send(owner, {:login_surface, :authentication_candidate, normalized_login})

      {:ok,
       %{
         credential_id: "credential-canary",
         verifier: "verifier-canary",
         scoped_context: %{
           account_id: "account-canary",
           principal_id: "principal-canary",
           vault_id: "vault-canary"
         }
       }}
    end
  end

  defmodule LoginPasswordHasher do
    def verify(owner, password, verifier) do
      send(owner, {:login_surface, :password_hasher, password, verifier})
      {:ok, true}
    end
  end

  defmodule LoginIdentity do
    alias Singularity.Core.Error

    def create_session_and_audit(
          %{audit_secret: audit_secret, owner: owner},
          scoped_context,
          command,
          options
        ) do
      send(
        owner,
        {:login_surface, :identity_persistence, scoped_context, command, options}
      )

      {:error,
       Error.new(:storage_unavailable,
         details: %{audit_fingerprint_secret: audit_secret},
         message: audit_secret,
         retryable?: true
       )}
    end
  end

  defmodule BoundaryTelemetryHandler do
    def handle(event, measurements, metadata, owner) do
      send(owner, {:telemetry_surface, event, measurements, metadata})
    end
  end

  defmodule UploadScope do
    def with_shared_request(owner, _runtime, _session, requirement, callback) do
      send(owner, {:upload_surface, :scope, requirement})
      callback.(:request_repo)
    end
  end

  defmodule UploadAssets do
    def create_upload_grant(owner, :request_repo, command) do
      send(owner, {:upload_surface, :persistence, command})
      {:ok, Map.put(command, :state, :granted)}
    end
  end

  defmodule AuditSink do
    def append(owner, repo, event) do
      send(owner, {:audit_surface, repo, event})
      :ok
    end
  end

  defmodule BackupIds do
    def generate(_owner), do: "00000000-0000-4000-8000-000000001101"
  end

  defmodule BackupKeyBoundary do
    def prepare(owner, _runtime, _session, manifest_id, passphrase) do
      send(owner, {:backup_surface, :key_preparation, passphrase})

      {:ok,
       %{
         opaque_ref: "opaque-backup-key-ref",
         public_metadata: %{
           "kdf" => %{"algorithm" => "argon2id", "salt" => "public-salt"},
           "recovery" => %{
             "label" => "backup_recovery",
             "manifest_id" => manifest_id,
             "wrapper" => "public-wrapper"
           }
         }
       }}
    end
  end

  defmodule BackupScope do
    def with_shared_request(owner, _runtime, _session, requirement, callback) do
      send(owner, {:backup_surface, :scope, requirement})

      case callback.(:request_repo) do
        {:after_commit_scoped, after_commit} ->
          after_commit.(fn scoped_callback -> scoped_callback.(:request_repo) end)

        result ->
          result
      end
    end
  end

  defmodule BackupRepository do
    def insert_pending_and_enqueue(owner, :request_repo, command) do
      send(owner, {:backup_surface, :persistence, command})

      {:ok,
       %{
         backup_key_lease_id: command.custody_ref,
         destination_ref: command.destination_ref,
         id: command.manifest_id,
         public_metadata: command.public_metadata,
         status: :waiting_for_backup_key,
         vault_id: command.vault_id
       }}
    end
  end

  defmodule BackupCustodian do
    alias Singularity.Core.Error

    def activate_backup_key(owner, opaque_ref) do
      send(owner, {:backup_surface, :activate, opaque_ref})
      {:error, Error.new(:storage_unavailable, retryable?: true)}
    end

    def discard_pending(owner, opaque_ref) do
      send(owner, {:backup_surface, :discard, opaque_ref})
      :ok
    end
  end

  defmodule BackupJobs do
    def wake_backup(owner, manifest_id) do
      send(owner, {:backup_surface, :wake, manifest_id})
      :ok
    end
  end

  defmodule BackupPartialBundles do
    def cleanup(owner, destination_ref, manifest_id) do
      send(owner, {:backup_surface, :cleanup, destination_ref, manifest_id})
      :ok
    end
  end

  defmodule RestoreMode do
    def require_maintenance(owner) do
      send(owner, {:restore_surface, :maintenance})
      :ok
    end
  end

  defmodule RestoreDestination do
    def require_empty(owner, migration_repo) do
      send(owner, {:restore_surface, :destination, migration_repo})
      :ok
    end
  end

  defmodule RestoreAuthenticator do
    alias Singularity.Core.Error

    def authenticate_all(owner, source, passphrase) do
      send(owner, {:restore_surface, :authenticate_all, source, passphrase})

      {:error,
       Error.new(:backup_invalid,
         details: %{backup_passphrase: passphrase},
         message: passphrase
       )}
    end
  end

  defmodule RestoreUnused do
  end

  test "all eight server-side canary categories are removed by keyed redaction" do
    redacted = Redactor.redact(@canaries)

    assert Map.values(redacted) == List.duplicate("[REDACTED]", map_size(@canaries))

    for canary <- Map.values(@canaries) do
      assert Canary.leaks(redacted, canary) == []
    end
  end

  test "the detector covers encoded and inspected forms and allows only the grant token path" do
    for form <- Canary.forms(@password) do
      assert Canary.leaks(%{surface: form}, @password) != []
    end

    runtime_result = %{grant: %{token: @upload_token}, echoed_token: @upload_token}

    assert [{[:echoed_token], @upload_token}] =
             Canary.leaks(runtime_result, @upload_token, [[:grant, :token]])

    assert Canary.leaks(%{grant: %{token: @upload_token}}, @upload_token, [
             [:grant, :token]
           ]) == []
  end

  test "the configured final structured log output removes every server canary" do
    [formatter: {LoggerJSON.Formatters.Basic, formatter_options}] =
      Application.fetch_env!(:logger, :default_handler)

    {LoggerJSON.Formatters.Basic, formatter} =
      LoggerJSON.Formatters.Basic.new(formatter_options)

    encoded =
      %{
        level: :warning,
        meta: %{time: System.system_time(:microsecond)},
        msg: {:report, %{operation: :secret_canary, nested: @canaries}}
      }
      |> LoggerJSON.Formatters.Basic.format(formatter)
      |> IO.iodata_to_binary()
      |> JSON.decode!()

    for canary <- Map.values(@canaries) do
      assert Canary.leaks(encoded, canary) == []
    end
  end

  test "secret-bearing lease status is redacted across key, download, backup, and restore custody" do
    key_lease = start_key_lease(SecretErrorReader, @vault_key)
    download_lease = start_download_lease(SecretErrorReader, @vault_key)
    backup_lease = start_backup_key_lease()

    {:ok, restore_lease} =
      RestoreIntegrityLease.start_link(%{
        owner: self(),
        ttl_ms: 5_000,
        vault_key: @vault_key
      })

    on_exit(fn ->
      for lease <- [key_lease, download_lease, backup_lease, restore_lease],
          Process.alive?(lease) do
        GenServer.stop(lease)
      end
    end)

    for lease <- [key_lease, download_lease, backup_lease, restore_lease] do
      rendered = lease |> :sys.get_status() |> inspect(limit: :infinity)
      assert Canary.leaks(rendered, @vault_key) == []
      assert rendered =~ "REDACTED"
    end

    formatted =
      BackupKeyLease.format_status(%{
        log: [%{plaintext: @vault_key}],
        message: {:storage_encrypt_chunk, 0, @vault_key},
        reason: %{new_kek: @vault_key},
        state: :sys.get_state(backup_lease)
      })

    assert Canary.leaks(formatted, @vault_key) == []
    assert formatted.log == "[REDACTED]"
    assert formatted.message == "[REDACTED]"
    assert formatted.reason == "[REDACTED]"
  end

  test "key custodian status and callback redact retained keys and messages" do
    custodian = start_key_custodian()

    assert {:ok, pending} =
             KeyCustodian.prepare_unlock(custodian, custodian_session())

    assert :ok = KeyCustodian.activate_unlock(custodian, pending)

    status =
      custodian
      |> :sys.get_status()
      |> inspect(limit: :infinity, printable_limit: :infinity)

    state = :sys.get_state(custodian)

    formatted =
      KeyCustodian.format_status(%{
        log: [%{object_dek: @object_key}],
        message: %{domain_dedup_key: @domain_dedup_key},
        reason: %{vault_key: @vault_key},
        state: state
      })

    for canary <- [@vault_key, @domain_key, @domain_dedup_key, @object_key] do
      assert Canary.leaks(status, canary) == []
      assert Canary.leaks(formatted, canary) == []
    end

    assert status =~ "REDACTED"
    assert formatted.log == "[REDACTED]"
    assert formatted.message == "[REDACTED]"
    assert formatted.reason == "[REDACTED]"
  end

  test "secret-bearing adapter errors return only stable public errors" do
    key_lease = start_key_lease(SecretErrorReader, @password)
    download_lease = start_download_lease(SecretErrorReader, @password)

    assert {:error,
            %Error{
              code: :storage_unavailable,
              message: nil,
              details: %{},
              retryable?: true
            } = key_error} = KeyLease.read_chunk(key_lease, 0)

    assert {:error,
            %Error{
              code: :storage_unavailable,
              message: nil,
              details: %{},
              retryable?: true
            } = download_error} = DownloadLease.read(download_lease, :all)

    assert Canary.leaks([key_error, download_error], @password) == []
  end

  test "unstructured adapter reasons cannot cross the key lease boundary" do
    key_lease = start_key_lease(RawErrorReader, @password)

    assert {:error,
            %Error{
              code: :storage_unavailable,
              message: nil,
              details: %{},
              retryable?: true
            } = error} = KeyLease.read_chunk(key_lease, 0)

    assert Canary.leaks(error, @password) == []
  end

  test "secret-bearing adapter exceptions are contained before Logger sees them" do
    logs =
      capture_log(fn ->
        key_lease = start_key_lease(RaisingReader, @password)
        download_lease = start_download_lease(RaisingReader, @password)

        assert {:error, %Error{code: :storage_unavailable}} =
                 KeyLease.read_chunk(key_lease, 0)

        assert {:error, %Error{code: :storage_unavailable}} =
                 DownloadLease.read(download_lease, :all)

        Process.sleep(25)
      end)

    assert Canary.leaks(logs, @password) == []
  end

  test "login sends raw password only to the hasher and keeps persistence and public surfaces clean" do
    event = [:singularity, :authentication, :audit_write_failure]
    attach_telemetry([event])

    adapters = %{
      audit_fingerprint_secret: @audit_fingerprint_secret,
      identity: LoginIdentity,
      identity_context: %{audit_secret: @audit_fingerprint_secret, owner: self()},
      password_hasher: LoginPasswordHasher,
      password_hasher_context: self(),
      pre_auth: LoginPreAuth,
      pre_auth_context: self(),
      random_bytes: fn 32 -> :binary.copy(<<0xA7>>, 32) end
    }

    logs =
      capture_log(fn ->
        send(
          self(),
          {:login_result,
           Login.run(adapters, %{
             correlation_id: "correlation-canary",
             login: "owner@example.test",
             password: @password,
             source: "127.0.0.1"
           })}
        )
      end)

    assert_receive {:login_surface, :pre_auth_reserve, _command} = reserve

    assert_receive {:login_surface, :authentication_candidate, "owner@example.test"} =
                     candidate

    assert_receive {:login_surface, :password_hasher, @password, "verifier-canary"} =
                     password_hasher

    assert_receive {:login_surface, :identity_persistence, _scope, _command, _audit_options} =
                     identity

    assert_receive {:telemetry_surface, ^event, %{count: 1}, _metadata} = telemetry
    assert_receive {:login_result, {:error, %Error{code: :unauthenticated}} = result}
    refute_receive {:login_surface, _, _}

    assert Canary.leaks(password_hasher, @password) == [{[2], @password}]

    for surface <- [reserve, candidate, identity, telemetry, logs, result],
        canary <- [@password, @audit_fingerprint_secret] do
      assert Canary.leaks(surface, canary) == []
    end
  end

  test "upload grant exposes the token only at entropy and grant-result paths" do
    now = ~U[2026-07-27 09:00:00.000000Z]

    runtime = %{
      assets: {UploadAssets, self()},
      clock: fn -> now end,
      id_generator: &Ecto.UUID.generate/0,
      operation_scope: {UploadScope, self()},
      random_bytes: fn 32 ->
        send(self(), {:upload_surface, :entropy, @upload_token})
        @upload_token
      end
    }

    session = %SessionContext{
      session_id: Ecto.UUID.generate(),
      account_id: Ecto.UUID.generate(),
      principal_id: Ecto.UUID.generate(),
      vault_id: Ecto.UUID.generate(),
      expires_at: DateTime.add(now, 600, :second),
      principal_authorization_epoch: 1,
      vault_authorization_epoch: 1,
      authorization_epoch: 1,
      unlocked?: true
    }

    attrs = %{
      declared_media_type: "application/pdf",
      filename: "canary.pdf",
      idempotency_key: "canary-upload",
      size: 12
    }

    logs =
      capture_log(fn ->
        send(
          self(),
          {:upload_result,
           CreateUploadGrant.run(
             runtime,
             session,
             attrs,
             @csrf_token
           )}
        )
      end)

    assert_receive {:upload_surface, :entropy, @upload_token} = entropy
    assert_receive {:upload_surface, :scope, _requirement} = scope
    assert_receive {:upload_surface, :persistence, command} = persistence
    assert_receive {:upload_result, {:ok, %{token: encoded_token}} = result}

    assert encoded_token == Base.url_encode64(@upload_token, padding: false)
    assert command.token_digest == :crypto.hash(:sha256, @upload_token)

    assert command.csrf_token_digest ==
             :crypto.hash(:sha256, @csrf_token)

    refute Map.has_key?(command, :token)
    refute Map.has_key?(command, :csrf_token)

    assert Canary.leaks(entropy, @upload_token) == [{[2], @upload_token}]
    assert Canary.leaks(result, @upload_token) != []
    assert Canary.leaks(result, @upload_token, [[1, :token]]) == []
    assert Canary.leaks(result, @csrf_token) == []

    for surface <- [scope, persistence, logs] do
      assert Canary.leaks(surface, @upload_token) == []
      assert Canary.leaks(surface, @csrf_token) == []
    end
  end

  test "audit append and telemetry execute redact all eight server-side canaries" do
    audit_metadata =
      Map.new(@canaries, fn {key, value} ->
        {Atom.to_string(key), value}
      end)

    assert :ok =
             Audit.append_principal(
               {AuditSink, self()},
               :request_repo,
               %{principal_id: "principal-canary", vault_id: "vault-canary"},
               %{
                 action: "secret.canary",
                 classification: :private,
                 correlation_id: "correlation-canary",
                 metadata: audit_metadata,
                 occurred_at: ~U[2026-07-27 09:00:00.000000Z],
                 result: :completed,
                 target_id: "target-canary",
                 target_type: "canary"
               }
             )

    assert_receive {:audit_surface, :request_repo, audit_event}

    telemetry_event = [:singularity, :secret_canary, :executed]
    attach_telemetry([telemetry_event])

    assert :ok =
             Telemetry.execute(
               [:secret_canary, :executed],
               %{count: 1},
               @canaries
             )

    assert_receive {:telemetry_surface, ^telemetry_event, %{count: 1} = measurements,
                    telemetry_metadata} = telemetry

    assert Enum.all?(Map.values(measurements), &is_number/1)

    assert Map.values(audit_event.metadata) ==
             List.duplicate("[REDACTED]", map_size(@canaries))

    assert Map.values(telemetry_metadata) ==
             List.duplicate("[REDACTED]", map_size(@canaries))

    for canary <- Map.values(@canaries) do
      assert Canary.leaks([audit_event, telemetry], canary) == []
    end
  end

  test "backup request keeps passphrase at key preparation and out of durable and public surfaces" do
    runtime = %{
      backup_key_lease: {BackupKeyBoundary, self()},
      backups: {BackupRepository, self()},
      custodian: {BackupCustodian, self()},
      ids: {BackupIds, self()},
      jobs: {BackupJobs, self()},
      operation_scope: {BackupScope, self()},
      partial_bundles: {BackupPartialBundles, self()}
    }

    session = %{
      principal_authorization_epoch: 1,
      principal_id: "principal-canary",
      session_id: "session-canary",
      vault_authorization_epoch: 1,
      vault_id: "vault-canary"
    }

    logs =
      capture_log(fn ->
        send(
          self(),
          {:backup_result,
           BackupVault.request(runtime, session, @backup_passphrase, "backup://canary")}
        )
      end)

    assert_receive {:backup_surface, :key_preparation, @backup_passphrase} = key_preparation
    assert_receive {:backup_surface, :scope, _requirement} = scope
    assert_receive {:backup_surface, :persistence, _command} = persistence
    assert_receive {:backup_surface, :activate, "opaque-backup-key-ref"} = activation
    assert_receive {:backup_surface, :discard, "opaque-backup-key-ref"} = discard
    assert_receive {:backup_result, {:ok, %{status: :waiting_for_backup_key}} = result}

    assert Canary.leaks(key_preparation, @backup_passphrase) == [
             {[2], @backup_passphrase}
           ]

    for surface <- [scope, persistence, activation, discard, logs, result] do
      assert Canary.leaks(surface, @backup_passphrase) == []
    end
  end

  test "backup facade returns and inspects only safe DTOs and stable errors" do
    operation_id = "00000000-0000-4000-8000-000000001801"
    vault_id = "00000000-0000-4000-8000-000000001802"
    requested_at = ~U[2026-08-10 08:00:00.000000Z]
    updated_at = ~U[2026-08-10 08:01:00.000000Z]

    status = %{
      operation_id: operation_id,
      vault_id: vault_id,
      status: :pending,
      requested_at: requested_at,
      updated_at: updated_at
    }

    preflight = fn %SessionContext{} = context ->
      send(self(), {:backup_facade_preflight, context})
      :ok
    end

    config = %{
      authorize_backup_request: preflight,
      request_backup: fn _session, _passphrase ->
        {:ok, %{operation_id: operation_id}}
      end,
      backup_status: fn _session, ^operation_id -> {:ok, status} end
    }

    secret_error_config = %{
      authorize_backup_request: preflight,
      request_backup: fn _session, passphrase ->
        {:error,
         Error.new(:backup_invalid,
           message: passphrase,
           details: %{passphrase: passphrase}
         )}
      end,
      backup_status: fn _session, _operation_id -> {:ok, status} end
    }

    raising_config = %{
      authorize_backup_request: preflight,
      request_backup: fn _session, passphrase -> raise passphrase end,
      backup_status: fn _session, _operation_id -> {:ok, status} end
    }

    logs =
      capture_log(fn ->
        send(
          self(),
          {:backup_facade_success,
           Api.request_backup(config, backup_session_dto(vault_id), @backup_passphrase)}
        )

        send(
          self(),
          {:backup_facade_error,
           Api.request_backup(
             secret_error_config,
             backup_session_dto(vault_id),
             @backup_passphrase
           )}
        )

        send(
          self(),
          {:backup_facade_exception,
           Api.request_backup(
             raising_config,
             backup_session_dto(vault_id),
             @backup_passphrase
           )}
        )
      end)

    assert_receive {:backup_facade_success,
                    {:ok,
                     %Singularity.Runtime.DTO.BackupStatus{
                       operation_id: ^operation_id,
                       status: :pending,
                       requested_at: ^requested_at,
                       updated_at: ^updated_at
                     }} = success}

    assert_receive {:backup_facade_error, {:error, :backup_invalid} = stable_error}

    assert_receive {:backup_facade_exception,
                    {:error, :storage_unavailable} = contained_exception}

    assert_receive {:backup_facade_preflight, %SessionContext{} = success_preflight}
    assert_receive {:backup_facade_preflight, %SessionContext{} = error_preflight}
    assert_receive {:backup_facade_preflight, %SessionContext{} = exception_preflight}

    {:messages, pending_messages} = Process.info(self(), :messages)

    for surface <- [
          success,
          inspect(success, limit: :infinity),
          stable_error,
          inspect(stable_error, limit: :infinity),
          contained_exception,
          inspect(contained_exception, limit: :infinity),
          success_preflight,
          error_preflight,
          exception_preflight,
          pending_messages,
          logs
        ] do
      assert Canary.leaks(surface, @backup_passphrase) == []
    end
  end

  test "restore keeps passphrase at authentication and sanitizes errors logs and telemetry" do
    start_event = [:singularity, :restore, :start]
    stop_event = [:singularity, :restore, :stop]
    attach_telemetry([start_event, stop_event])

    context = %{
      authenticator: {RestoreAuthenticator, self()},
      destination: {RestoreDestination, self()},
      integrity: RestoreUnused,
      maintenance_mode: {RestoreMode, self()},
      migration_repo: :migration_repo,
      reconciler: RestoreUnused,
      restorer: RestoreUnused
    }

    logs =
      capture_log(fn ->
        send(
          self(),
          {:restore_result,
           RestoreVault.run(context, %{
             new_password: @password,
             passphrase: @backup_passphrase,
             source: "backup://canary"
           })}
        )
      end)

    assert_receive {:restore_surface, :maintenance} = maintenance
    assert_receive {:restore_surface, :destination, :migration_repo} = destination

    assert_receive {:restore_surface, :authenticate_all, "backup://canary", @backup_passphrase} =
                     authentication

    assert_receive {:telemetry_surface, ^start_event, _measurements, _metadata} =
                     telemetry_start

    assert_receive {:telemetry_surface, ^stop_event, _measurements, _metadata} =
                     telemetry_stop

    assert_receive {:restore_result,
                    {:error,
                     %Error{
                       code: :backup_invalid,
                       details: %{},
                       message: nil
                     }} = result}

    assert Canary.leaks(authentication, @backup_passphrase) == [
             {[3], @backup_passphrase}
           ]

    for surface <- [
          maintenance,
          destination,
          telemetry_start,
          telemetry_stop,
          logs,
          result
        ],
        canary <- [@backup_passphrase, @password] do
      assert Canary.leaks(surface, canary) == []
    end
  end

  defp start_key_lease(reader, secret) do
    binding = lease_binding()

    {:ok, lease} =
      KeyLease.start_link(%{
        authorization: Authorization,
        binding: binding,
        checkpoint: KeyLease.checkpoint(binding, 0),
        clock: Clock,
        context: %{secret: secret},
        custodian: self(),
        key_material: @vault_key,
        key_reader: reader
      })

    lease
  end

  defp start_download_lease(reader, secret) do
    {:ok, lease} =
      DownloadLease.start_link(%{
        authorization: Authorization,
        binding: lease_binding(),
        clock: Clock,
        context: %{secret: secret},
        custodian: self(),
        key_material: @vault_key,
        key_reader: reader
      })

    lease
  end

  defp start_backup_key_lease do
    binding = %{
      manifest_id: "00000000-0000-4000-8000-000000001701",
      vault_id: "00000000-0000-4000-8000-000000001702"
    }

    {:ok, lease} =
      BackupKeyLease.start_link(%{
        binding: binding,
        cipher: ChunkedAEAD,
        custodian: self(),
        key_material: @vault_key,
        public_header: %{
          version: 1,
          manifest_id: binding.manifest_id,
          vault_id: binding.vault_id,
          kdf: %{}
        },
        recovery_wrapper: "opaque-recovery-wrapper"
      })

    lease
  end

  defp start_key_custodian do
    lease_supervisor =
      start_supervised!({KeyLeaseSupervisor, []}, id: make_ref())

    start_supervised!(
      {KeyCustodian,
       %{
         authorization: Authorization,
         clock: Clock,
         context: %{},
         idle_lock: fn _session -> :ok end,
         key_reader: SecretErrorReader,
         lease_supervisor: lease_supervisor,
         object_key_loader: SecretErrorReader
       }},
      id: make_ref()
    )
  end

  defp custodian_session do
    %{
      session_id: "session-canary",
      principal_id: "principal-canary",
      vault_id: "vault-canary",
      principal_authorization_epoch: 1,
      vault_authorization_epoch: 1,
      vault_key: @vault_key,
      domain_key: @domain_key,
      domain_dedup_key: @domain_dedup_key,
      key_domain_id: "domain-canary",
      domain_key_version_id: "domain-version-canary",
      domain_key_generation: 1,
      domain_classification: :private,
      object_keys: %{{"object-canary", 1} => @object_key}
    }
  end

  defp lease_binding do
    %{
      job_id: "job-1",
      vault_id: "vault-1",
      principal_id: "principal-1",
      required_capability: "asset.read",
      principal_authorization_epoch: 1,
      vault_authorization_epoch: 1,
      object_id: "object-1",
      object_generation: 1,
      session_id: "session-1"
    }
  end

  defp backup_session_dto(vault_id) do
    %SessionDTO{
      session_id: "00000000-0000-4000-8000-000000001803",
      account_id: "00000000-0000-4000-8000-000000001804",
      principal_id: "00000000-0000-4000-8000-000000001805",
      vault_id: vault_id,
      expires_at: ~U[2026-08-10 09:00:00.000000Z],
      principal_authorization_epoch: 7,
      vault_authorization_epoch: 11,
      authorization_epoch: 7,
      unlocked?: true
    }
  end

  defp attach_telemetry(events) do
    handler_id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach_many(
        handler_id,
        events,
        &BoundaryTelemetryHandler.handle/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end
end
