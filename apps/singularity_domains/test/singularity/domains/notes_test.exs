Code.require_file("../../support/fake/note_repository.ex", __DIR__)

defmodule Singularity.Domains.NotesTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.Error
  alias Singularity.Core.NoteSnapshot
  alias Singularity.Core.NoteSaveResult
  alias Singularity.Domains.Notes
  alias Singularity.Domains.Notes.Command

  @principal_id "00000000-0000-4000-8000-000000000001"
  @vault_id "00000000-0000-4000-8000-000000000002"
  @correlation_id "00000000-0000-4000-8000-000000000003"
  @mutation_id "00000000-0000-4000-8000-000000000004"
  @resource_id "00000000-0000-4000-8000-000000000005"
  @base_version_id "00000000-0000-4000-8000-000000000006"
  @conflict_id "00000000-0000-4000-8000-000000000007"
  @expected_current_version_id "00000000-0000-4000-8000-000000000008"
  @competing_version_id "00000000-0000-4000-8000-000000000009"
  @fingerprint :binary.copy(<<7>>, 32)

  setup do
    results = happy_results()
    {:ok, repository_context} = Fake.NoteRepository.start_link(self(), results)

    {:ok,
     adapters: %{
       repository: Fake.NoteRepository,
       repository_context: repository_context
     }}
  end

  test "create forwards an exact canonical private snapshot intent", %{adapters: adapters} do
    assert {:ok, command} =
             Command.new(:create, create_command(title: "  First  ", markdown: "body\n"))

    assert {:ok, %NoteSaveResult{outcome: :saved}} =
             Notes.execute(adapters, command, @fingerprint)

    assert_receive {:create,
                    %{
                      mutation_id: @mutation_id,
                      principal_id: @principal_id,
                      vault_id: @vault_id,
                      classification: :private,
                      correlation_id: @correlation_id,
                      request_fingerprint: @fingerprint,
                      snapshot: %NoteSnapshot{
                        title: "First",
                        markdown: "body\n",
                        parent_version_id: nil,
                        merge_parent_version_id: nil
                      }
                    } = intent}

    assert Map.keys(intent) |> Enum.sort() ==
             [
               :classification,
               :correlation_id,
               :mutation_id,
               :principal_id,
               :request_fingerprint,
               :snapshot,
               :vault_id
             ]
  end

  test "save forwards a one-parent immutable intent", %{adapters: adapters} do
    assert {:ok, command} =
             Command.new(:save, save_command(title: "  Revised  ", markdown: "body\n"))

    assert {:ok, %NoteSaveResult{outcome: :saved}} =
             Notes.execute(adapters, command, @fingerprint)

    assert_receive {:save,
                    %{
                      mutation_id: @mutation_id,
                      resource_id: @resource_id,
                      base_version_id: @base_version_id,
                      principal_id: @principal_id,
                      vault_id: @vault_id,
                      classification: :private,
                      correlation_id: @correlation_id,
                      request_fingerprint: @fingerprint,
                      snapshot: %NoteSnapshot{
                        title: "Revised",
                        markdown: "body\n",
                        parent_version_id: @base_version_id,
                        merge_parent_version_id: nil
                      }
                    } = intent}

    assert Map.keys(intent) |> Enum.sort() ==
             [
               :base_version_id,
               :classification,
               :correlation_id,
               :mutation_id,
               :principal_id,
               :request_fingerprint,
               :resource_id,
               :snapshot,
               :vault_id
             ]
  end

  test "merge forwards a two-parent immutable intent", %{adapters: adapters} do
    assert {:ok, command} = Command.new(:merge, merge_command())

    assert {:ok, %NoteSaveResult{outcome: :saved}} =
             Notes.execute(adapters, command, @fingerprint)

    assert_receive {:merge,
                    %{
                      mutation_id: @mutation_id,
                      resource_id: @resource_id,
                      conflict_id: @conflict_id,
                      expected_current_version_id: @expected_current_version_id,
                      competing_version_id: @competing_version_id,
                      principal_id: @principal_id,
                      vault_id: @vault_id,
                      classification: :private,
                      correlation_id: @correlation_id,
                      request_fingerprint: @fingerprint,
                      snapshot: %NoteSnapshot{
                        parent_version_id: @expected_current_version_id,
                        merge_parent_version_id: @competing_version_id
                      }
                    } = intent}

    assert Map.keys(intent) |> Enum.sort() ==
             [
               :classification,
               :competing_version_id,
               :conflict_id,
               :correlation_id,
               :expected_current_version_id,
               :mutation_id,
               :principal_id,
               :request_fingerprint,
               :resource_id,
               :snapshot,
               :vault_id
             ]
  end

  test "tombstone forwards no snapshot or unneeded nil keys", %{adapters: adapters} do
    assert {:ok, command} = Command.new(:tombstone, tombstone_command())
    assert {:ok, %{state: :tombstoned}} = Notes.execute(adapters, command, @fingerprint)

    assert_receive {:tombstone,
                    %{
                      mutation_id: @mutation_id,
                      resource_id: @resource_id,
                      expected_current_version_id: @expected_current_version_id,
                      principal_id: @principal_id,
                      vault_id: @vault_id,
                      classification: :private,
                      correlation_id: @correlation_id,
                      request_fingerprint: @fingerprint
                    } = intent}

    assert Map.keys(intent) |> Enum.sort() ==
             [
               :classification,
               :correlation_id,
               :expected_current_version_id,
               :mutation_id,
               :principal_id,
               :request_fingerprint,
               :resource_id,
               :vault_id
             ]
  end

  test "restore forwards no snapshot or unneeded nil keys", %{adapters: adapters} do
    assert {:ok, command} = Command.new(:restore, restore_command())
    assert {:ok, %{state: :restored}} = Notes.execute(adapters, command, @fingerprint)

    assert_receive {:restore,
                    %{
                      mutation_id: @mutation_id,
                      resource_id: @resource_id,
                      principal_id: @principal_id,
                      vault_id: @vault_id,
                      classification: :private,
                      correlation_id: @correlation_id,
                      request_fingerprint: @fingerprint
                    } = intent}

    assert Map.keys(intent) |> Enum.sort() ==
             [
               :classification,
               :correlation_id,
               :mutation_id,
               :principal_id,
               :request_fingerprint,
               :resource_id,
               :vault_id
             ]
  end

  test "fingerprint terms include only canonical caller values" do
    assert {:ok, create} =
             Command.new(:create, create_command(title: "  First  ", markdown: "body\n"))

    assert {:ok, save} =
             Command.new(:save, save_command(title: "  Revised  ", markdown: "body\n"))

    assert {:ok, merge} = Command.new(:merge, merge_command())
    assert {:ok, tombstone} = Command.new(:tombstone, tombstone_command())
    assert {:ok, restore} = Command.new(:restore, restore_command())

    assert {:note_mutation_v1, :create, @mutation_id, "First", "body\n"} =
             Command.fingerprint_term(create)

    assert {:note_mutation_v1, :save, @mutation_id, @resource_id, @base_version_id, "Revised",
            "body\n"} = Command.fingerprint_term(save)

    assert {:note_mutation_v1, :merge, @mutation_id, @resource_id, @conflict_id,
            @expected_current_version_id, @competing_version_id, "Title",
            "Markdown"} =
             Command.fingerprint_term(merge)

    assert {:note_mutation_v1, :tombstone, @mutation_id, @resource_id,
            @expected_current_version_id} = Command.fingerprint_term(tombstone)

    assert {:note_mutation_v1, :restore, @mutation_id, @resource_id} =
             Command.fingerprint_term(restore)
  end

  test "command preparation rejects malformed shape, duplicate conflicts, and malformed snapshots" do
    assert {:error, %{code: :invalid}} = Command.new(:unknown, create_command())
    assert {:error, %{code: :invalid}} = Command.new(:create, :not_a_map)

    assert {:error, %{code: :invalid}} =
             Command.new(:create, Map.put(create_command(), :extra, true))

    assert {:error, %{code: :invalid}} =
             Command.new(:create, Map.delete(create_command(), :markdown))

    assert {:error, %{code: :invalid}} =
             Command.new(:create, Map.put(create_command(), "title", "other"))

    assert {:error, %{code: :invalid}} =
             Command.new(:create, Map.put(create_command(), :classification, :sensitive))

    assert {:error, %{code: :invalid}} =
             Command.new(:create, Map.put(create_command(), :correlation_id, "not-a-uuid"))

    assert {:error, %{code: :invalid}} =
             Command.new(:create, Map.put(create_command(), :title, "   "))

    assert {:error, %{code: :invalid}} =
             Command.new(:save, Map.put(save_command(), :markdown, <<0>>))
  end

  test "command preparation rejects every malformed UUID occurrence for every operation" do
    uuid_keys = %{
      create: [:mutation_id, :principal_id, :vault_id, :correlation_id],
      save: [
        :mutation_id,
        :principal_id,
        :vault_id,
        :correlation_id,
        :resource_id,
        :base_version_id
      ],
      merge: [
        :mutation_id,
        :principal_id,
        :vault_id,
        :correlation_id,
        :resource_id,
        :conflict_id,
        :expected_current_version_id,
        :competing_version_id
      ],
      tombstone: [
        :mutation_id,
        :principal_id,
        :vault_id,
        :correlation_id,
        :resource_id,
        :expected_current_version_id
      ],
      restore: [:mutation_id, :principal_id, :vault_id, :correlation_id, :resource_id]
    }

    for {operation, keys} <- uuid_keys,
        key <- keys do
      assert {:error, %{code: :invalid}} =
               Command.new(operation, Map.put(command(operation), key, "INVALID"))
    end
  end

  test "execute rejects malformed inputs, adapters, and repository results", %{adapters: adapters} do
    assert {:ok, command} = Command.new(:create, create_command())

    assert {:error, %{code: :invalid}} = Notes.execute(adapters, command, <<7>>)
    assert {:error, %{code: :invalid}} = Notes.execute(adapters, command, :not_a_binary)
    assert {:error, %{code: :invalid}} = Notes.execute(%{}, command, @fingerprint)

    assert {:error, %{code: :invalid}} =
             Notes.execute(%{repository: Fake.NoteRepository}, command, @fingerprint)

    assert {:error, %{code: :invalid}} = Notes.execute(adapters, %{}, @fingerprint)
  end

  test "execute preserves valid repository errors and rejects malformed repository results" do
    assert {:ok, command} = Command.new(:restore, restore_command())
    error = Error.new(:conflict)

    for {result, expected} <- [
          {{:error, error}, {:error, error}},
          {:ok, {:error, Error.new(:invalid)}},
          {{:ok}, {:error, Error.new(:invalid)}},
          {{:error, :bad}, {:error, Error.new(:invalid)}},
          {{:error, %Error{code: :bogus}}, {:error, Error.new(:invalid)}}
        ] do
      {:ok, repository_context} =
        Fake.NoteRepository.start_link(self(), %{restore: result})

      adapters = %{repository: Fake.NoteRepository, repository_context: repository_context}

      assert ^expected = Notes.execute(adapters, command, @fingerprint)
    end
  end

  test "execute rejects malformed repository successes for every operation" do
    malformed_results = %{
      create:
        {:ok,
         %NoteSaveResult{
           outcome: :saved,
           resource_id: @resource_id,
           canonical_version_id: @expected_current_version_id,
           submitted_version_id: @base_version_id,
           conflict_id: nil
         }},
      save:
        {:ok,
         %NoteSaveResult{
           outcome: :conflict,
           resource_id: @resource_id,
           canonical_version_id: @expected_current_version_id,
           submitted_version_id: @base_version_id,
           conflict_id: nil
         }},
      merge:
        {:ok,
         %NoteSaveResult{
           outcome: :conflict,
           resource_id: @resource_id,
           canonical_version_id: @expected_current_version_id,
           submitted_version_id: @competing_version_id,
           conflict_id: @conflict_id
         }},
      tombstone:
        {:ok,
         %{
           resource_id: @resource_id,
           canonical_version_id: @expected_current_version_id,
           state: :restored
         }},
      restore:
        {:ok,
         %{
           resource_id: @resource_id,
           canonical_version_id: "INVALID",
           state: :restored
         }}
    }

    for {operation, result} <- malformed_results do
      {:ok, repository_context} = Fake.NoteRepository.start_link(self(), %{operation => result})
      adapters = %{repository: Fake.NoteRepository, repository_context: repository_context}

      assert {:error, %{code: :invalid}} =
               Notes.execute(adapters, valid_command(operation), @fingerprint)
    end
  end

  test "command preparation canonicalizes string-only and identical duplicate keys", %{
    adapters: adapters
  } do
    inputs = [
      {:save, string_keys(save_command(title: "  Revised  ", markdown: "body\n")),
       {:note_mutation_v1, :save, @mutation_id, @resource_id, @base_version_id, "Revised",
        "body\n"}},
      {:restore, duplicate_keys(restore_command()),
       {:note_mutation_v1, :restore, @mutation_id, @resource_id}}
    ]

    for {operation, raw, expected_fingerprint_term} <- inputs do
      assert {:ok, command} = Command.new(operation, raw)
      assert ^expected_fingerprint_term = Command.fingerprint_term(command)
      assert {:ok, _result} = Notes.execute(adapters, command, @fingerprint)
      assert_receive {^operation, intent}
      assert intent.request_fingerprint == @fingerprint

      case operation do
        :save ->
          assert %{
                   resource_id: @resource_id,
                   base_version_id: @base_version_id,
                   snapshot: %NoteSnapshot{
                     title: "Revised",
                     markdown: "body\n",
                     parent_version_id: @base_version_id,
                     merge_parent_version_id: nil
                   }
                 } = intent

        :restore ->
          assert %{
                   resource_id: @resource_id,
                   principal_id: @principal_id,
                   vault_id: @vault_id,
                   classification: :private,
                   correlation_id: @correlation_id
                 } = intent
      end
    end
  end

  test "execute rejects handcrafted invalid commands without dispatch", %{adapters: adapters} do
    assert {:ok, save} = Command.new(:save, save_command())
    assert {:ok, merge} = Command.new(:merge, merge_command())
    assert {:ok, create} = Command.new(:create, create_command())
    assert {:ok, restore} = Command.new(:restore, restore_command())

    invalid_commands = [
      %{create | mutation_id: "INVALID"},
      %{save | snapshot: %{save.snapshot | parent_version_id: @expected_current_version_id}},
      %{merge | snapshot: %{merge.snapshot | merge_parent_version_id: @base_version_id}},
      %{restore | classification: :sensitive},
      %{create | resource_id: @resource_id}
    ]

    for command <- invalid_commands do
      assert {:error, %{code: :invalid}} = Notes.execute(adapters, command, @fingerprint)
    end

    refute Enum.any?(elem(Process.info(self(), :messages), 1), fn
             {operation, _intent}
             when operation in [:create, :save, :merge, :tombstone, :restore] ->
               true

             _message ->
               false
           end)
  end

  defp create_command(overrides \\ []) do
    command(:create)
    |> Map.merge(Map.new(overrides))
  end

  defp save_command(overrides \\ []) do
    command(:save)
    |> Map.merge(Map.new(overrides))
  end

  defp merge_command(overrides \\ []) do
    command(:merge)
    |> Map.merge(Map.new(overrides))
  end

  defp tombstone_command(overrides \\ []) do
    command(:tombstone)
    |> Map.merge(Map.new(overrides))
  end

  defp restore_command(overrides \\ []) do
    command(:restore)
    |> Map.merge(Map.new(overrides))
  end

  defp command(operation) do
    %{
      mutation_id: @mutation_id,
      principal_id: @principal_id,
      vault_id: @vault_id,
      classification: :private,
      correlation_id: @correlation_id
    }
    |> add_operation_fields(operation)
  end

  defp add_operation_fields(command, :create),
    do: Map.merge(command, %{title: "Title", markdown: "Markdown"})

  defp add_operation_fields(command, :save) do
    Map.merge(command, %{
      resource_id: @resource_id,
      base_version_id: @base_version_id,
      title: "Title",
      markdown: "Markdown"
    })
  end

  defp add_operation_fields(command, :merge) do
    Map.merge(command, %{
      resource_id: @resource_id,
      conflict_id: @conflict_id,
      expected_current_version_id: @expected_current_version_id,
      competing_version_id: @competing_version_id,
      title: "Title",
      markdown: "Markdown"
    })
  end

  defp add_operation_fields(command, :tombstone) do
    Map.merge(command, %{
      resource_id: @resource_id,
      expected_current_version_id: @expected_current_version_id
    })
  end

  defp add_operation_fields(command, :restore), do: Map.put(command, :resource_id, @resource_id)

  defp happy_results do
    %{
      create: {:ok, saved_result()},
      save: {:ok, saved_result()},
      merge: {:ok, saved_result()},
      tombstone: {:ok, lifecycle_result(:tombstoned)},
      restore: {:ok, lifecycle_result(:restored)}
    }
  end

  defp valid_command(operation) do
    {:ok, command} = Command.new(operation, command(operation))
    command
  end

  defp saved_result do
    {:ok, result} =
      NoteSaveResult.saved(%{
        resource_id: @resource_id,
        canonical_version_id: @expected_current_version_id,
        submitted_version_id: @expected_current_version_id
      })

    result
  end

  defp lifecycle_result(state) do
    %{
      resource_id: @resource_id,
      canonical_version_id: @expected_current_version_id,
      state: state
    }
  end

  defp string_keys(raw) do
    Map.new(raw, fn {key, value} -> {Atom.to_string(key), value} end)
  end

  defp duplicate_keys(raw) do
    Enum.reduce(raw, raw, fn {key, value}, acc -> Map.put(acc, Atom.to_string(key), value) end)
  end
end
