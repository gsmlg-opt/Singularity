defmodule Singularity.Runtime.RestoreVaultTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Singularity.Core.Error
  alias Singularity.Storage.Crypto.RecoveredVaultKey

  @manifest_id "00000000-0000-4000-8000-000000000721"
  @other_manifest_id "00000000-0000-4000-8000-000000000729"
  @restore_vault Singularity.Runtime.RestoreVault
  @passphrase "CANARY_RESTORE_PASSPHRASE_721"
  @new_password "CANARY_RESTORE_PASSWORD_721"

  defmodule Recorder do
    use Agent

    def start_link(options) do
      Agent.start_link(fn ->
        %{
          events: [],
          failure: Keyword.get(options, :failure),
          imported?: false,
          mutation_count: 0
        }
      end)
    end

    def record(recorder, event),
      do: Agent.update(recorder, &update_in(&1.events, fn events -> events ++ [event] end))

    def get(recorder), do: Agent.get(recorder, & &1)
    def failure(recorder), do: Agent.get(recorder, & &1.failure)

    def imported(recorder) do
      Agent.update(recorder, fn state ->
        %{state | imported?: true, mutation_count: state.mutation_count + 1}
      end)
    end
  end

  defmodule Mode do
    def require_maintenance(recorder) do
      Recorder.record(recorder, :require_maintenance)

      if Recorder.failure(recorder) == :not_maintenance,
        do: {:error, Error.new(:forbidden)},
        else: :ok
    end
  end

  defmodule Destination do
    def require_empty(recorder, _migration_repo) do
      Recorder.record(recorder, :require_empty_destination)

      if Recorder.failure(recorder) == :not_empty,
        do: {:error, Error.new(:conflict)},
        else: :ok
    end
  end

  defmodule BundleReader do
    alias Singularity.Storage.Crypto.RecoveredVaultKey

    def authenticate_all(recorder, source, passphrase) do
      Recorder.record(recorder, {:authenticate_all, source})

      case Recorder.failure(recorder) do
        :secret_auth_error ->
          {:error,
           Error.new(:backup_invalid,
             details: %{passphrase: passphrase},
             message: "authentication failed for #{passphrase}"
           )}

        :malformed_auth ->
          {:authenticated, passphrase}

        :malformed_authenticated ->
          {:ok,
           %{
             lease: self(),
             verified: %{
               manifest: %{manifest_id: "00000000-0000-4000-8000-000000000721"}
             }
           }}

        failure
        when failure in [:wrong_passphrase, :truncated, :reordered, :altered_inventory] ->
          {:error, Error.new(:backup_invalid)}

        _other when passphrase == "CANARY_RESTORE_PASSPHRASE_721" ->
          {:ok,
           %{
             binding: %{
               destination_ref: "backups/bundle-1",
               manifest_id: "00000000-0000-4000-8000-000000000721",
               recovery: %{
                 "binding" => %{
                   "manifest_id" => "00000000-0000-4000-8000-000000000721",
                   "vault_id" => "00000000-0000-4000-8000-000000000723"
                 },
                 "label" => "backup_recovery",
                 "wrapper" => "authenticated-recovery-wrapper"
               },
               vault_id: "00000000-0000-4000-8000-000000000723"
             },
             cut: %{
               manifest_id: "00000000-0000-4000-8000-000000000721",
               object_inventory: [],
               outbox_high_water_mark: 42,
               vault_id: "00000000-0000-4000-8000-000000000723"
             },
             lease: self(),
             verified: %{
               manifest: %{
                 inventory: [
                   %{
                     position: 0,
                     record_type: 0xBEEF,
                     payload_length: 24,
                     sha256: :binary.copy(<<0x72>>, 32)
                   }
                 ],
                 manifest_id: "00000000-0000-4000-8000-000000000721",
                 outbox_high_water_mark: 42,
                 recovery: %{
                   "binding" => %{
                     "manifest_id" => "00000000-0000-4000-8000-000000000721",
                     "vault_id" => "00000000-0000-4000-8000-000000000723"
                   },
                   "label" => "backup_recovery",
                   "wrapper" => "authenticated-recovery-wrapper"
                 },
                 snapshot_id: "00000000-0000-4000-8000-000000000722",
                 vault_ids: ["00000000-0000-4000-8000-000000000723"],
                 version: 1
               },
               source: source
             }
           }}

        _other ->
          {:error, Error.new(:backup_invalid)}
      end
    end

    def claim_recovered_vault_key(recorder, authenticated) do
      Recorder.record(
        recorder,
        {:claim_recovered_vault_key, authenticated.verified.manifest.manifest_id}
      )

      {:ok, recovered_vault_key(recorder)}
    end

    def revoke(recorder, authenticated) do
      Recorder.record(recorder, {:revoke_authenticated, authenticated.lease})

      :ok
    end

    defp recovered_vault_key(recorder) do
      if Recorder.failure(recorder) == :raw_capability,
        do: :binary.copy(<<0x7A>>, 32),
        else: RecoveredVaultKey.issue(self(), make_ref())
    end
  end

  defmodule Restorer do
    def import(
          recorder,
          migration_repo,
          %{binding: binding, cut: cut, verified: verified} = package
        )
        when map_size(package) == 3 do
      Recorder.record(
        recorder,
        {:import, migration_repo, verified.manifest.manifest_id, binding.manifest_id,
         cut.manifest_id}
      )

      Recorder.imported(recorder)

      if Recorder.failure(recorder) == :import_error do
        {:error, Error.new(:integrity_failure)}
      else
        manifest =
          if Recorder.failure(recorder) == :import_manifest_mismatch,
            do: %{verified.manifest | manifest_id: "00000000-0000-4000-8000-000000000729"},
            else: verified.manifest

        {:ok, %{cut: cut, manifest: manifest}}
      end
    end

    def rewrap_owner(recorder, imported, new_password, recovered_vault_key) do
      Recorder.record(
        recorder,
        {:rewrap_owner, imported.manifest.manifest_id, recovered_vault_key}
      )

      case Recorder.failure(recorder) do
        :secret_rewrap_error ->
          {:error,
           Error.new(:integrity_failure,
             details: %{new_password: new_password},
             message: "rewrap failed for #{new_password}"
           )}

        :rewrap_manifest_mismatch ->
          {:ok,
           put_in(
             imported,
             [:manifest, :manifest_id],
             "00000000-0000-4000-8000-000000000729"
           )}

        _other when new_password == "CANARY_RESTORE_PASSWORD_721" ->
          {:ok, imported}

        _other ->
          {:error, Error.new(:invalid)}
      end
    end

    def complete_restore(recorder, restored) do
      Recorder.record(recorder, {:complete_restore, restored.manifest.manifest_id})

      if Recorder.failure(recorder) == :complete_error,
        do: {:error, Error.new(:storage_unavailable, retryable?: true)},
        else: :ok
    end
  end

  defmodule Integrity do
    def verify_ciphertext(recorder, restored) do
      Recorder.record(recorder, {:verify_ciphertext, restored.manifest.manifest_id})

      if Recorder.failure(recorder) == :ciphertext_error,
        do: {:error, Error.new(:integrity_failure)},
        else: :ok
    end

    def verify_plaintext_and_search(recorder, restored) do
      Recorder.record(recorder, {:verify_plaintext_and_search, restored.manifest.manifest_id})

      if Recorder.failure(recorder) == :plaintext_error,
        do: {:error, Error.new(:integrity_failure)},
        else: :ok
    end

    def revoke(recorder, restored) do
      Recorder.record(recorder, {:revoke_integrity, restored.manifest.manifest_id})
      :ok
    end
  end

  defmodule Reconciler do
    def reconcile(
          recorder,
          %{
            manifest_id: manifest_id,
            outbox_high_water_mark: outbox_high_water_mark,
            vault_id: vault_id
          } = cut
        )
        when map_size(cut) == 3 and is_integer(outbox_high_water_mark) and
               is_binary(vault_id) do
      Recorder.record(recorder, {:reconcile, manifest_id})

      if Recorder.failure(recorder) == :reconcile_error,
        do: {:error, Error.new(:integrity_failure)},
        else: :ok
    end
  end

  setup do
    recorder = start_supervised!({Recorder, []})
    {:ok, context: context(recorder), recorder: recorder}
  end

  test "authenticates the complete bundle and inventory before the importer can mutate",
       context do
    result_ref = make_ref()
    enriched_context = Map.put(context.context, :unused_adapter, :ignored)
    log = capture_log(fn -> send(self(), {result_ref, run(enriched_context)}) end)
    assert_receive {^result_ref, {:ok, %{manifest_id: @manifest_id} = result}}

    assert [
             :require_maintenance,
             :require_empty_destination,
             {:authenticate_all, "backup://bundle-1"},
             {:import, :migration_repo, @manifest_id, @manifest_id, @manifest_id},
             {:claim_recovered_vault_key, @manifest_id},
             {:rewrap_owner, @manifest_id, %RecoveredVaultKey{} = recovered_vault_key},
             {:verify_ciphertext, @manifest_id},
             {:reconcile, @manifest_id},
             {:verify_plaintext_and_search, @manifest_id},
             {:complete_restore, @manifest_id},
             {:revoke_integrity, @manifest_id},
             {:revoke_authenticated, authenticated_lease}
           ] = Recorder.get(context.recorder).events

    assert is_pid(authenticated_lease)
    assert %RecoveredVaultKey{} = recovered_vault_key

    state = Recorder.get(context.recorder)
    assert state.mutation_count == 1

    refute secret_leaked?([result, log, state], [@passphrase, @new_password])
  end

  test "wrong passphrase, truncation, reordering, and altered inventory fail before import" do
    for failure <- [:wrong_passphrase, :truncated, :reordered, :altered_inventory] do
      recorder = start_supervised!({Recorder, failure: failure}, id: make_ref())

      assert {:error, %Error{code: :backup_invalid}} = run(context(recorder))

      state = Recorder.get(recorder)

      assert [
               :require_maintenance,
               :require_empty_destination,
               {:authenticate_all, "backup://bundle-1"}
             ] = state.events

      refute state.imported?
      assert state.mutation_count == 0
    end
  end

  test "maintenance mode and an empty destination are checked before bundle authentication" do
    for failure <- [:not_maintenance, :not_empty] do
      recorder = start_supervised!({Recorder, failure: failure}, id: make_ref())
      assert {:error, %Error{}} = run(context(recorder))

      events = Recorder.get(recorder).events
      refute Enum.any?(events, &match?({:authenticate_all, _source}, &1))
      refute Enum.any?(events, &match?({:import, _repo, _manifest_id}, &1))
      refute Recorder.get(recorder).imported?
    end
  end

  test "restore logs, adapter calls, and inspected errors never expose either secret" do
    for failure <- [:secret_auth_error, :secret_rewrap_error] do
      recorder = start_supervised!({Recorder, failure: failure}, id: make_ref())

      log =
        capture_log(fn ->
          send(self(), {:restore_result, run(context(recorder))})
        end)

      assert_receive {:restore_result, {:error, %Error{} = error}}
      assert error.message == nil
      assert error.details == %{}

      for value <- [log, error, Recorder.get(recorder).events] do
        refute secret_leaked?(value, [@passphrase, @new_password])
      end
    end
  end

  test "malformed adapter replies become retryable internal failures" do
    recorder = start_supervised!({Recorder, failure: :malformed_auth}, id: make_ref())

    assert {:error, %Error{code: :storage_unavailable, retryable?: true}} =
             run(context(recorder))

    refute Recorder.get(recorder).imported?
  end

  test "every mutating phase remains bound to the authenticated manifest identity" do
    for failure <- [:import_manifest_mismatch, :rewrap_manifest_mismatch] do
      recorder = start_supervised!({Recorder, failure: failure}, id: make_ref())

      assert {:error, %Error{code: :backup_invalid}} = run(context(recorder))

      events = Recorder.get(recorder).events
      assert {:import, :migration_repo, @manifest_id, @manifest_id, @manifest_id} in events
      refute Enum.any?(events, &match?({:verify_ciphertext, _manifest_id}, &1))
      refute Enum.any?(events, &match?({:reconcile, _manifest_id}, &1))
      refute Enum.any?(events, &match?({:verify_plaintext_and_search, _manifest_id}, &1))
      refute Enum.any?(events, &match?({:complete_restore, _manifest_id}, &1))

      if failure == :import_manifest_mismatch do
        refute Enum.any?(events, &match?({:rewrap_owner, @other_manifest_id, _capability}, &1))
      else
        assert Enum.any?(events, &match?({:rewrap_owner, @manifest_id, %RecoveredVaultKey{}}, &1))
        assert {:revoke_integrity, @other_manifest_id} in events
      end

      assert {:revoke_authenticated, lease} = List.last(events)
      assert is_pid(lease)
    end
  end

  test "the authenticated restore lease is revoked on every post-authentication exit" do
    for failure <- [
          :import_error,
          :secret_rewrap_error,
          :ciphertext_error,
          :reconcile_error,
          :plaintext_error,
          :complete_error
        ] do
      recorder = start_supervised!({Recorder, failure: failure}, id: make_ref())

      assert {:error, %Error{}} = run(context(recorder))

      assert {:revoke_authenticated, lease} = List.last(Recorder.get(recorder).events)
      assert is_pid(lease)
    end
  end

  test "the integrity capability is synchronously revoked on every post-rewrap exit" do
    for failure <- [
          :ciphertext_error,
          :reconcile_error,
          :plaintext_error,
          :complete_error
        ] do
      recorder = start_supervised!({Recorder, failure: failure}, id: make_ref())

      assert {:error, %Error{}} = run(context(recorder))

      assert [
               {:revoke_integrity, @manifest_id},
               {:revoke_authenticated, lease}
             ] = Enum.take(Recorder.get(recorder).events, -2)

      assert is_pid(lease)
    end
  end

  test "an incomplete authenticated import package is rejected and its key is revoked" do
    recorder = start_supervised!({Recorder, failure: :malformed_authenticated}, id: make_ref())

    assert {:error, %Error{code: :backup_invalid}} = run(context(recorder))

    assert [
             :require_maintenance,
             :require_empty_destination,
             {:authenticate_all, "backup://bundle-1"},
             {:revoke_authenticated, lease}
           ] = Recorder.get(recorder).events

    assert is_pid(lease)
  end

  test "raw recovered vault keys are rejected after replay import and cleanup still runs" do
    recorder = start_supervised!({Recorder, failure: :raw_capability}, id: make_ref())

    assert {:error, %Error{code: :backup_invalid}} = run(context(recorder))

    state = Recorder.get(recorder)
    assert state.imported?
    refute Enum.any?(state.events, &match?({:rewrap_owner, _, _}, &1))

    assert {:claim_recovered_vault_key, @manifest_id} in state.events
    assert {:revoke_authenticated, lease} = List.last(state.events)
    assert is_pid(lease)
  end

  defp run(context) do
    apply(@restore_vault, :run, [context, request()])
  end

  defp context(recorder) do
    %{
      authenticator: {BundleReader, recorder},
      destination: {Destination, recorder},
      integrity: {Integrity, recorder},
      maintenance_mode: {Mode, recorder},
      migration_repo: :migration_repo,
      reconciler: {Reconciler, recorder},
      restorer: {Restorer, recorder}
    }
  end

  defp request do
    %{
      new_password: @new_password,
      passphrase: @passphrase,
      source: "backup://bundle-1"
    }
  end

  defp secret_leaked?(value, secrets) do
    binaries = collect_binaries(value) ++ rendered_forms(value)

    Enum.any?(secrets, fn secret ->
      Enum.any?(secret_forms(secret), fn form ->
        Enum.any?(binaries, &binary_contains?(&1, form))
      end)
    end)
  end

  defp collect_binaries(value) when is_binary(value), do: [value]

  defp collect_binaries(value) when is_map(value) do
    value
    |> Map.to_list()
    |> Enum.flat_map(fn {key, nested} ->
      collect_binaries(key) ++ collect_binaries(nested)
    end)
  end

  defp collect_binaries(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.flat_map(&collect_binaries/1)

  defp collect_binaries(value) when is_list(value),
    do: Enum.flat_map(value, &collect_binaries/1)

  defp collect_binaries(_value), do: []

  defp rendered_forms(value) do
    [
      inspect(value, limit: :infinity, printable_limit: :infinity),
      inspect(value,
        base: :hex,
        binaries: :as_binaries,
        charlists: :as_lists,
        limit: :infinity,
        printable_limit: :infinity
      )
    ]
  end

  defp secret_forms(secret) when is_binary(secret) do
    [
      secret,
      Base.encode16(secret, case: :lower),
      Base.encode16(secret, case: :upper),
      inspect(secret, limit: :infinity, printable_limit: :infinity),
      inspect(secret,
        base: :hex,
        binaries: :as_binaries,
        limit: :infinity,
        printable_limit: :infinity
      ),
      inspect(:binary.bin_to_list(secret), limit: :infinity)
    ]
    |> Enum.uniq()
  end

  defp binary_contains?(binary, form) when is_binary(binary) and is_binary(form),
    do: :binary.match(binary, form) != :nomatch
end
