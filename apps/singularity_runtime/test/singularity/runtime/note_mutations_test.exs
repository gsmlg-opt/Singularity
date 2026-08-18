defmodule Singularity.Runtime.NoteMutationsTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.Error
  alias Singularity.Core.NoteSaveResult, as: ReferenceResult
  alias Singularity.Domains.Notes.Command
  alias Singularity.Runtime.Api
  alias Singularity.Runtime.DTO.Note
  alias Singularity.Runtime.DTO.NoteSaveResult
  alias Singularity.Runtime.DTO.Session
  alias Singularity.Runtime.Notes.Create
  alias Singularity.Runtime.Notes.Delete
  alias Singularity.Runtime.Notes.Merge
  alias Singularity.Runtime.Notes.Restore
  alias Singularity.Runtime.Notes.Save
  alias Singularity.Runtime.SessionContext

  @session_id "00000000-0000-4000-8000-000000002201"
  @account_id "00000000-0000-4000-8000-000000002202"
  @principal_id "00000000-0000-4000-8000-000000002203"
  @vault_id "00000000-0000-4000-8000-000000002204"
  @resource_id "00000000-0000-4000-8000-000000002205"
  @base_id "00000000-0000-4000-8000-000000002206"
  @version_id "00000000-0000-4000-8000-000000002207"
  @newer_version_id "00000000-0000-4000-8000-000000002208"
  @competing_id "00000000-0000-4000-8000-000000002209"
  @conflict_id "00000000-0000-4000-8000-000000002210"
  @mutation_id "00000000-0000-4000-8000-000000002211"
  @secret :binary.copy(<<0xA5>>, 32)
  @fingerprint :binary.copy(<<0xB6>>, 32)

  defmodule Scope do
    def with_shared_request(owner, runtime, session, requirement, callback) do
      send(owner, {:scope, runtime, session, requirement})

      case Process.get(:note_mutation_scope_result) do
        nil -> callback.(:scoped_repo)
        result -> result
      end
    end
  end

  defmodule Fingerprint do
    def compute(owner, secret, %Command{} = command) do
      send(owner, {:fingerprint, secret, command})
      Process.get(:note_mutation_fingerprint_result, {:ok, :binary.copy(<<0xB6>>, 32)})
    end
  end

  defmodule Repository do
    @behaviour Singularity.Domains.Notes.Repository

    for operation <- [:create, :save, :merge, :tombstone, :restore] do
      @impl true
      def unquote(operation)(repo, intent) do
        owner = Process.get(:note_mutation_owner)
        send(owner, {:repository, unquote(operation), repo, intent})
        Process.get({:note_mutation_repository_result, unquote(operation)})
      end
    end

    def get(repo, vault_id, resource_id) do
      owner = Process.get(:note_mutation_owner)
      send(owner, {:reload, repo, vault_id, resource_id})
      Process.get(:note_mutation_reload_result)
    end
  end

  setup do
    Process.put(:note_mutation_owner, self())
    Process.put(:note_mutation_reload_result, {:ok, canonical_row()})
    set_saved(:create)
    set_saved(:save)
    set_saved(:merge)

    Process.put(
      {:note_mutation_repository_result, :tombstone},
      {:ok, %{resource_id: @resource_id, canonical_version_id: @version_id, state: :tombstoned}}
    )

    Process.put(
      {:note_mutation_repository_result, :restore},
      {:ok, %{resource_id: @resource_id, canonical_version_id: @version_id, state: :restored}}
    )

    on_exit(fn ->
      for key <- [
            :note_mutation_owner,
            :note_mutation_reload_result,
            :note_mutation_scope_result,
            :note_mutation_fingerprint_result,
            {:note_mutation_repository_result, :create},
            {:note_mutation_repository_result, :save},
            {:note_mutation_repository_result, :merge},
            {:note_mutation_repository_result, :tombstone},
            {:note_mutation_repository_result, :restore}
          ] do
        Process.delete(key)
      end
    end)
  end

  test "Create canonicalizes server authority before fingerprinting and reloads current Note" do
    runtime = runtime()
    session = session()

    assert {:ok, canonical} =
             Create.run(runtime, session, %{
               mutation_id: @mutation_id,
               title: "Created",
               markdown: "# Created"
             })

    assert canonical.resource_id == @resource_id
    assert canonical.resource_version_id == @version_id
    assert_write_scope(runtime, session)

    assert_receive {:fingerprint, @secret,
                    %Command{
                      operation: :create,
                      mutation_id: @mutation_id,
                      principal_id: @principal_id,
                      vault_id: @vault_id,
                      classification: :private,
                      snapshot: %{title: "Created", markdown: "# Created"},
                      correlation_id: correlation_id
                    }}

    assert {:ok, ^correlation_id} = Ecto.UUID.cast(correlation_id)

    assert_receive {:repository, :create, :scoped_repo,
                    %{request_fingerprint: @fingerprint, principal_id: @principal_id}}

    assert_receive {:reload, :scoped_repo, @vault_id, @resource_id}
  end

  test "Save preserves saved and conflict outcomes and hydrates the current canonical Note" do
    assert {:ok,
            %{
              outcome: :saved,
              canonical: %{resource_version_id: @version_id},
              submitted_version_id: @version_id,
              conflict_id: nil
            }} = Save.run(runtime(), session(), @resource_id, save_attrs())

    assert_receive {:repository, :save, :scoped_repo,
                    %{resource_id: @resource_id, base_version_id: @base_id}}

    assert {:ok, conflict} =
             ReferenceResult.conflict(%{
               resource_id: @resource_id,
               canonical_version_id: @version_id,
               submitted_version_id: @competing_id,
               conflict_id: @conflict_id
             })

    Process.put({:note_mutation_repository_result, :save}, {:ok, conflict})

    assert {:ok,
            %{
              outcome: :conflict,
              canonical: %{resource_version_id: @version_id},
              submitted_version_id: @competing_id,
              conflict_id: @conflict_id
            }} = Save.run(runtime(), session(), @resource_id, save_attrs())
  end

  test "replayed saved and conflict references reload later canonical state without stale plaintext" do
    Process.put(
      :note_mutation_reload_result,
      {:ok,
       canonical_row(
         resource_version_id: @newer_version_id,
         revision: 4,
         title: "Later canonical",
         markdown: "# Later canonical"
       )}
    )

    for {module, attrs, operation} <- [
          {Create, create_attrs(), :create},
          {Save, save_attrs(), :save},
          {Merge, merge_attrs(), :merge}
        ] do
      set_saved(operation)

      result =
        case module do
          Create -> module.run(runtime(), session(), attrs)
          _ -> module.run(runtime(), session(), @resource_id, attrs)
        end

      case {operation, result} do
        {:create, {:ok, canonical}} ->
          assert canonical.resource_version_id == @newer_version_id
          assert canonical.markdown == "# Later canonical"

        {operation, {:ok, hydrated}} when operation in [:save, :merge] ->
          assert hydrated.outcome == :saved
          assert hydrated.canonical.resource_version_id == @newer_version_id
          assert hydrated.submitted_version_id == @newer_version_id
      end
    end

    assert {:ok, conflict} =
             ReferenceResult.conflict(%{
               resource_id: @resource_id,
               canonical_version_id: @version_id,
               submitted_version_id: @competing_id,
               conflict_id: @conflict_id
             })

    Process.put({:note_mutation_repository_result, :save}, {:ok, conflict})

    assert {:ok, hydrated} = Save.run(runtime(), session(), @resource_id, save_attrs())
    assert hydrated.canonical.resource_version_id == @newer_version_id
    assert hydrated.submitted_version_id == @competing_id
    assert hydrated.conflict_id == @conflict_id

    assert {:ok, restored} =
             Restore.run(runtime(), session(), @resource_id, %{mutation_id: @mutation_id})

    assert restored.resource_version_id == @newer_version_id
    assert restored.markdown == "# Later canonical"
  end

  test "Merge builds exact two-parent command and returns a hydrated saved result" do
    assert {:ok, %{outcome: :saved, canonical: %{resource_id: @resource_id}}} =
             Merge.run(runtime(), session(), @resource_id, merge_attrs())

    assert_receive {:fingerprint, @secret,
                    %Command{
                      operation: :merge,
                      resource_id: @resource_id,
                      conflict_id: @conflict_id,
                      expected_current_version_id: @version_id,
                      competing_version_id: @competing_id,
                      snapshot: %{
                        parent_version_id: @version_id,
                        merge_parent_version_id: @competing_id
                      }
                    }}
  end

  test "Delete validates lifecycle references and returns true for accepted replay without content" do
    assert {:ok, true} =
             Delete.run(runtime(), session(), @resource_id, %{
               mutation_id: @mutation_id,
               expected_current_version_id: @version_id
             })

    assert_receive {:repository, :tombstone, :scoped_repo, intent}
    refute Map.has_key?(intent, :title)
    refute Map.has_key?(intent, :markdown)
    refute_received {:reload, _repo, _vault_id, _resource_id}

    assert {:ok, true} =
             Delete.run(runtime(), session(), @resource_id, %{
               mutation_id: @mutation_id,
               expected_current_version_id: @version_id
             })

    Process.put(
      {:note_mutation_repository_result, :tombstone},
      {:ok, %{resource_id: @resource_id, canonical_version_id: "bad", state: :tombstoned}}
    )

    assert {:error, %Error{code: :invalid}} =
             Delete.run(runtime(), session(), @resource_id, %{
               mutation_id: Ecto.UUID.generate(),
               expected_current_version_id: @version_id
             })
  end

  test "Restore validates references and reloads the now-live canonical Note" do
    Process.put(
      :note_mutation_reload_result,
      {:ok, canonical_row(title: "Restored", markdown: "# Restored")}
    )

    assert {:ok, %{title: "Restored", markdown: "# Restored"}} =
             Restore.run(runtime(), session(), @resource_id, %{mutation_id: @mutation_id})

    assert_receive {:repository, :restore, :scoped_repo, %{resource_id: @resource_id}}
    assert_receive {:reload, :scoped_repo, @vault_id, @resource_id}
  end

  test "mutations reject caller authority, mismatched resources and locked scope before persistence" do
    for call <- [
          fn ->
            Create.run(runtime(), session(), Map.put(create_attrs(), :vault_id, @vault_id))
          end,
          fn ->
            Save.run(
              runtime(),
              session(),
              @resource_id,
              Map.put(save_attrs(), :resource_id, Ecto.UUID.generate())
            )
          end,
          fn ->
            Merge.run(
              runtime(),
              session(),
              @resource_id,
              Map.put(merge_attrs(), :classification, :private)
            )
          end,
          fn ->
            Delete.run(runtime(), session(), @resource_id, %{
              mutation_id: @mutation_id,
              expected_current_version_id: "bad"
            })
          end,
          fn -> Restore.run(runtime(), session(), @resource_id, %{mutation_id: "bad"}) end
        ] do
      assert {:error, %Error{code: :invalid}} = call.()
    end

    Process.put(:note_mutation_scope_result, {:error, Error.new(:vault_locked)})

    assert {:error, %Error{code: :vault_locked}} =
             Create.run(runtime(), session(), create_attrs())
  end

  test "repository and reload failures remain stable and malformed successes fail closed" do
    Process.put(
      {:note_mutation_repository_result, :save},
      {:error, Error.new(:conflict)}
    )

    assert {:error, %Error{code: :conflict}} =
             Save.run(runtime(), session(), @resource_id, save_attrs())

    Process.put({:note_mutation_repository_result, :save}, {:ok, %{unexpected: true}})

    assert {:error, %Error{code: :invalid}} =
             Save.run(runtime(), session(), @resource_id, save_attrs())

    set_saved(:save)
    Process.put(:note_mutation_reload_result, {:ok, %{unexpected: true}})

    assert {:error, %Error{code: :integrity_failure}} =
             Save.run(runtime(), session(), @resource_id, save_attrs())

    {:ok, mismatched} =
      ReferenceResult.saved(%{
        resource_id: Ecto.UUID.generate(),
        canonical_version_id: @version_id,
        submitted_version_id: @version_id
      })

    Process.put({:note_mutation_repository_result, :save}, {:ok, mismatched})

    assert {:error, %Error{code: :integrity_failure}} =
             Save.run(runtime(), session(), @resource_id, save_attrs())
  end

  test "stale merge and Delete remain conflicts while cross-vault resource lookups stay not_found" do
    Process.put({:note_mutation_repository_result, :merge}, {:error, Error.new(:conflict)})

    assert {:error, %Error{code: :conflict}} =
             Merge.run(runtime(), session(), @resource_id, merge_attrs())

    Process.put({:note_mutation_repository_result, :tombstone}, {:error, Error.new(:conflict)})

    assert {:error, %Error{code: :conflict}} =
             Delete.run(runtime(), session(), @resource_id, %{
               mutation_id: @mutation_id,
               expected_current_version_id: @version_id
             })

    other_vault_resource_id = Ecto.UUID.generate()
    Process.put({:note_mutation_repository_result, :save}, {:error, Error.new(:not_found)})

    assert {:error, %Error{code: :not_found}} =
             Save.run(
               runtime(),
               session(),
               other_vault_resource_id,
               %{save_attrs() | resource_id: other_vault_resource_id}
             )
  end

  test "Runtime.Api exposes exact mutation arities and maps only strict hydrated DTOs" do
    Code.ensure_loaded!(Api)

    for {function, arities} <- [
          create_note: [2, 3],
          save_note: [3, 4],
          merge_note: [3, 4],
          delete_note: [3, 4],
          restore_note: [3, 4]
        ],
        arity <- arities do
      assert function_exported?(Api, function, arity)
    end

    config = %{
      create_note: fn _session, _attrs -> {:ok, canonical_row()} end,
      save_note: fn _session, @resource_id, _attrs -> {:ok, hydrated_saved()} end,
      merge_note: fn _session, @resource_id, _attrs -> {:ok, hydrated_saved()} end,
      delete_note: fn _session, @resource_id, _attrs -> {:ok, true} end,
      restore_note: fn _session, @resource_id, _attrs -> {:ok, canonical_row()} end
    }

    assert {:ok, %Note{resource_id: @resource_id}} =
             Api.create_note(config, session_dto(), create_attrs())

    assert {:ok, %NoteSaveResult{outcome: :saved}} =
             Api.save_note(config, session_dto(), @resource_id, save_attrs())

    assert {:ok, %NoteSaveResult{outcome: :saved}} =
             Api.merge_note(config, session_dto(), @resource_id, merge_attrs())

    assert {:ok, true} =
             Api.delete_note(
               config,
               session_dto(),
               @resource_id,
               %{mutation_id: @mutation_id, expected_current_version_id: @version_id}
             )

    assert {:ok, %Note{resource_id: @resource_id}} =
             Api.restore_note(config, session_dto(), @resource_id, %{mutation_id: @mutation_id})

    assert {:error, :integrity_failure} =
             Api.save_note(
               %{save_note: fn _, _, _ -> :ok end},
               session_dto(),
               @resource_id,
               save_attrs()
             )
  end

  defp set_saved(operation) do
    {:ok, result} =
      ReferenceResult.saved(%{
        resource_id: @resource_id,
        canonical_version_id: @version_id,
        submitted_version_id: @version_id
      })

    Process.put({:note_mutation_repository_result, operation}, {:ok, result})
  end

  defp assert_write_scope(runtime, session) do
    assert_receive {:scope, ^runtime, ^session,
                    %{
                      vault_id: @vault_id,
                      required_capability: "note.write",
                      classification: :private,
                      requires_unlocked?: true
                    }}
  end

  defp runtime do
    %{
      fingerprint_secret: @secret,
      mutation_fingerprint: {Fingerprint, self()},
      note_repository: Repository,
      notes: Singularity.Domains.Notes,
      operation_scope: {Scope, self()}
    }
  end

  defp session do
    %SessionContext{
      session_id: @session_id,
      account_id: @account_id,
      principal_id: @principal_id,
      vault_id: @vault_id,
      expires_at: ~U[2026-08-18 12:00:00.000000Z],
      principal_authorization_epoch: 7,
      vault_authorization_epoch: 11,
      authorization_epoch: 7,
      unlocked?: true
    }
  end

  defp session_dto do
    session()
    |> Map.from_struct()
    |> then(&struct!(Session, &1))
  end

  defp create_attrs do
    %{mutation_id: @mutation_id, title: "Created", markdown: "# Created"}
  end

  defp save_attrs do
    %{
      mutation_id: @mutation_id,
      resource_id: @resource_id,
      base_version_id: @base_id,
      title: "Saved",
      markdown: "# Saved"
    }
  end

  defp merge_attrs do
    %{
      mutation_id: @mutation_id,
      resource_id: @resource_id,
      conflict_id: @conflict_id,
      expected_current_version_id: @version_id,
      competing_version_id: @competing_id,
      title: "Merged",
      markdown: "# Merged"
    }
  end

  defp hydrated_saved do
    %{
      outcome: :saved,
      canonical: canonical_row(),
      submitted_version_id: @version_id,
      conflict_id: nil
    }
  end

  defp canonical_row(overrides \\ []) do
    Map.merge(
      %{
        resource_id: @resource_id,
        resource_version_id: @version_id,
        vault_id: @vault_id,
        classification: :private,
        title: "Current",
        markdown: "# Current",
        revision: 1,
        updated_at: ~U[2026-08-18 09:00:00.000000Z],
        deleted_at: nil,
        deleted?: false,
        created_by_principal_id: @principal_id,
        inserted_at: ~U[2026-08-18 08:00:00.000000Z],
        parent_version_id: @base_id,
        merge_parent_version_id: nil,
        canonical?: true,
        open_conflict_count: 0
      },
      Map.new(overrides)
    )
  end
end
