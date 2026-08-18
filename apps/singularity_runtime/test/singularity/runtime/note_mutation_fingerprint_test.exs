defmodule Singularity.Runtime.NoteMutationFingerprintTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.Error
  alias Singularity.Domains.Notes.Command
  alias Singularity.Runtime.Notes.MutationFingerprint

  @secret :binary.copy(<<0xB8>>, 32)
  @other_secret :binary.copy(<<0xC9>>, 32)
  @mutation_id "00000000-0000-4000-8000-000000000801"
  @principal_id "00000000-0000-4000-8000-000000000802"
  @vault_id "00000000-0000-4000-8000-000000000803"
  @correlation_id "00000000-0000-4000-8000-000000000804"
  @resource_id "00000000-0000-4000-8000-000000000805"
  @base_version_id "00000000-0000-4000-8000-000000000806"
  @conflict_id "00000000-0000-4000-8000-000000000807"
  @expected_current_version_id "00000000-0000-4000-8000-000000000808"
  @competing_version_id "00000000-0000-4000-8000-000000000809"
  @other_id "00000000-0000-4000-8000-00000000080a"

  test "all five operations use their literal deterministic HMAC terms" do
    for {operation, expected_term} <- expected_terms() do
      command = command!(operation)
      expected = expected_hmac(@secret, expected_term)

      assert {:ok, ^expected} = MutationFingerprint.compute(@secret, command)
      assert {:ok, ^expected} = MutationFingerprint.compute(@secret, command)
      assert byte_size(expected) == 32
    end

    digests =
      for operation <- operations() do
        assert {:ok, digest} = MutationFingerprint.compute(@secret, command!(operation))
        digest
      end

    assert Enum.uniq(digests) == digests
  end

  test "changing any fingerprinted caller field changes the digest" do
    for operation <- operations() do
      raw = raw_command(operation)
      command = command!(operation)
      assert {:ok, original} = MutationFingerprint.compute(@secret, command)

      for {field, changed_value} <- caller_field_changes(operation) do
        assert {:ok, changed} = Command.new(operation, Map.put(raw, field, changed_value))
        assert {:ok, changed_digest} = MutationFingerprint.compute(@secret, changed)
        refute changed_digest == original, "#{operation}.#{field} did not affect the digest"
      end
    end
  end

  test "server-composed identity fields are excluded and unknown result fields are rejected" do
    for operation <- operations() do
      original = command!(operation)
      assert {:ok, original_digest} = MutationFingerprint.compute(@secret, original)

      for field <- [:principal_id, :vault_id, :correlation_id] do
        assert {:ok, changed} =
                 Command.new(operation, Map.put(raw_command(operation), field, @other_id))

        assert {:ok, ^original_digest} = MutationFingerprint.compute(@secret, changed)
      end

      for result_field <- [:version_id, :resource_version_id, :result, :conflict_result_id] do
        assert {:error, %Error{code: :invalid, retryable?: false}} =
                 Command.new(operation, Map.put(raw_command(operation), result_field, @other_id))
      end
    end

    assert {:error, %Error{code: :invalid, retryable?: false}} =
             Command.new(:create, Map.put(raw_command(:create), :classification, :sensitive))
  end

  test "the HMAC key is exact, secret, and size bounded" do
    command = command!(:create)
    assert {:ok, digest} = MutationFingerprint.compute(@secret, command)
    assert {:ok, other_digest} = MutationFingerprint.compute(@other_secret, command)
    refute other_digest == digest

    for invalid_secret <- [
          :binary.copy(<<0xB8>>, 31),
          :binary.copy(<<0xB8>>, 33),
          <<>>,
          Base.encode64(@secret),
          nil,
          :not_a_secret,
          List.duplicate(0xB8, 32)
        ] do
      assert {:error, %Error{code: :invalid, retryable?: false}} =
               MutationFingerprint.compute(invalid_secret, command)
    end
  end

  test "non-commands and forged Command structs are rejected without hashing" do
    create = command!(:create)
    save = command!(:save)
    merge = command!(:merge)
    restore = command!(:restore)

    forged = [
      %{create | resource_id: @other_id},
      Map.put(create, :version_id, @other_id),
      %{save | snapshot: %{save.snapshot | parent_version_id: @other_id}},
      %{merge | operation: :restore},
      %{restore | mutation_id: "not-a-uuid"},
      %{create | snapshot: nil}
    ]

    for invalid <- [%{}, raw_command(:create), nil, :not_a_command | forged] do
      assert {:error, %Error{code: :invalid, retryable?: false}} =
               MutationFingerprint.compute(@secret, invalid)
    end
  end

  defp operations, do: [:create, :save, :merge, :tombstone, :restore]

  defp expected_terms do
    [
      create: {:note_mutation_v1, :create, @mutation_id, "Title", "Markdown"},
      save:
        {:note_mutation_v1, :save, @mutation_id, @resource_id, @base_version_id, "Title",
         "Markdown"},
      merge:
        {:note_mutation_v1, :merge, @mutation_id, @resource_id, @conflict_id,
         @expected_current_version_id, @competing_version_id, "Title", "Markdown"},
      tombstone:
        {:note_mutation_v1, :tombstone, @mutation_id, @resource_id, @expected_current_version_id},
      restore: {:note_mutation_v1, :restore, @mutation_id, @resource_id}
    ]
  end

  defp caller_field_changes(:create),
    do: [mutation_id: @other_id, title: "Other title", markdown: "Other markdown"]

  defp caller_field_changes(:save),
    do: [
      mutation_id: @other_id,
      resource_id: @other_id,
      base_version_id: @other_id,
      title: "Other title",
      markdown: "Other markdown"
    ]

  defp caller_field_changes(:merge),
    do: [
      mutation_id: @other_id,
      resource_id: @other_id,
      conflict_id: @other_id,
      expected_current_version_id: @other_id,
      competing_version_id: @other_id,
      title: "Other title",
      markdown: "Other markdown"
    ]

  defp caller_field_changes(:tombstone),
    do: [
      mutation_id: @other_id,
      resource_id: @other_id,
      expected_current_version_id: @other_id
    ]

  defp caller_field_changes(:restore), do: [mutation_id: @other_id, resource_id: @other_id]

  defp command!(operation) do
    assert {:ok, command} = Command.new(operation, raw_command(operation))
    command
  end

  defp raw_command(operation) do
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

  defp expected_hmac(secret, term) do
    encoded = :erlang.term_to_binary(term, [:deterministic])
    :crypto.mac(:hmac, :sha256, secret, encoded)
  end
end
