Code.require_file("../../support/fake/document_repository.ex", __DIR__)

defmodule Singularity.Domains.DocumentsTest do
  use ExUnit.Case, async: true
  alias Singularity.Core.{DocumentSource, DocumentVersion, Error}
  alias Singularity.Domains.Documents
  alias Singularity.Domains.Documents.Command

  defp id(n), do: "00000000-0000-4000-8000-" <> String.pad_leading(Integer.to_string(n), 12, "0")

  defp attrs do
    {:ok, source} =
      DocumentSource.new(%{
        asset_id: id(1),
        resource_id: id(2),
        resource_version_id: id(3),
        object_id: id(4),
        owner_scope_id: id(5),
        classification: :private,
        digest: :binary.copy(<<1>>, 32),
        byte_size: 12,
        media_type: "text/plain"
      })

    %{
      mutation_id: id(6),
      resource_id: id(7),
      resource_version_id: id(8),
      title: " Title ",
      source: source,
      principal_id: id(9),
      owner_scope_id: id(5),
      classification: :private,
      correlation_id: id(10),
      inserted_at: ~U[2026-09-01 00:00:00Z]
    }
  end

  defp version(command) do
    {:ok, result} =
      DocumentVersion.new(%{
        resource_id: command.resource_id,
        resource_version_id: command.resource_version_id,
        owner_scope_id: command.owner_scope_id,
        classification: :private,
        revision: 0,
        source: command.source,
        title: command.title,
        created_by_principal_id: command.principal_id,
        inserted_at: command.inserted_at,
        state: :pending,
        generation: 0
      })

    result
  end

  test "canonical command and exact versioned fingerprint omit replay candidate metadata" do
    assert {:ok, command} = Command.new(attrs())
    assert command.title == "Title"
    source = command.source

    expected =
      {:document_import_v1, command.mutation_id, source.asset_id, source.resource_id,
       source.resource_version_id, source.object_id, source.digest, source.byte_size,
       source.media_type, "Title", :private}

    assert Command.fingerprint_term(command) == expected

    for {key, value} <- [
          resource_id: id(20),
          resource_version_id: id(21),
          inserted_at: ~U[2026-09-02 00:00:00Z],
          correlation_id: id(22),
          principal_id: id(23)
        ] do
      assert {:ok, changed} = Command.new(Map.put(attrs(), key, value))
      assert Command.fingerprint_term(changed) == expected
    end

    for {key, value} <- [
          asset_id: id(20),
          resource_id: id(21),
          resource_version_id: id(22),
          object_id: id(23),
          digest: :binary.copy(<<2>>, 32),
          byte_size: 13,
          media_type: "text/markdown"
        ] do
      assert {:ok, changed} = Command.new(Map.put(attrs(), :source, Map.put(source, key, value)))
      refute Command.fingerprint_term(changed) == expected
    end

    for {key, value} <- [title: "Different", mutation_id: id(24)] do
      assert {:ok, changed} = Command.new(Map.put(attrs(), key, value))
      refute Command.fingerprint_term(changed) == expected
    end
  end

  test "rejects invalid input, aliases, forged source and caller fingerprints" do
    input = attrs()

    for invalid <-
          [
            nil,
            ~U[2026-09-01 00:00:00Z],
            Map.put(input, :secret, "secret"),
            Map.put(input, :request_fingerprint, <<0::256>>),
            Map.put(input, "title", "conflict"),
            Map.delete(input, :mutation_id)
          ] ++
            Enum.map(
              ["", "  ", <<255>>, "a" <> <<0>>, String.duplicate("x", 256)],
              &Map.put(input, :title, &1)
            ) ++
            Enum.map([:public, "private"], &Map.put(input, :classification, &1)) ++
            Enum.map(
              [
                %{input.source | owner_scope_id: id(20)},
                %{input.source | digest: "bad"},
                ~U[2026-09-01 00:00:00Z]
              ],
              &Map.put(input, :source, &1)
            ) ++
            [
              Map.put(input, :resource_id, input.source.resource_id),
              Map.put(input, :resource_version_id, input.source.resource_version_id)
            ] do
      assert {:error, %Error{code: :invalid, message: nil, details: %{}}} = Command.new(invalid)
    end

    assert {:ok, _} = Command.new(Map.new(input, fn {k, v} -> {Atom.to_string(k), v} end))

    for key <- [
          :mutation_id,
          :resource_id,
          :resource_version_id,
          :principal_id,
          :owner_scope_id,
          :correlation_id
        ],
        value <- [nil, "not-a-uuid", String.upcase("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")] do
      assert {:error, %Error{code: :invalid}} = Command.new(Map.put(input, key, value))
    end

    assert {:error, %Error{code: :invalid}} =
             Command.new(Map.put(input, :inserted_at, "2026-09-01"))
  end

  test "replay accepts advanced lifecycle and original insertion timestamp" do
    {:ok, command} = Command.new(attrs())

    result = %{
      version(command)
      | state: :extracting,
        generation: 1,
        adapter_name: "plain-text",
        format_version: 1,
        inserted_at: ~U[2026-08-31 00:00:00Z]
    }

    assert {:ok, ^result} =
             Documents.create(
               %{
                 repository: Fake.DocumentRepository,
                 repository_context: {self(), {:ok, result}}
               },
               command
             )
  end

  test "revalidates command before repository I/O and returns canonical typed replay result" do
    {:ok, command} = Command.new(attrs())
    result = %{version(command) | resource_id: id(30), resource_version_id: id(31)}
    context = {self(), {:ok, result}}
    adapters = %{repository: Fake.DocumentRepository, repository_context: context}
    assert {:ok, ^result} = Documents.create(adapters, command)
    assert_receive {:create_pending, ^context, ^command}

    for bad <- [
          %{command | title: " "},
          %{command | title: " Title "},
          %{command | source: %{command.source | digest: "bad"}},
          Map.put(command, :secret, "hidden"),
          attrs(),
          nil
        ] do
      assert {:error, %Error{code: :invalid}} = Documents.create(adapters, bad)
      refute_receive {:create_pending, _, _}
    end
  end

  test "rejects malformed or mismatched adapter output and strips error content" do
    {:ok, command} = Command.new(attrs())
    result = version(command)

    for output <- [
          {:ok, Map.from_struct(result)},
          {:ok, %{result | title: "other"}},
          {:ok, %{result | owner_scope_id: id(30)}},
          {:ok, %{result | source: %{result.source | byte_size: 99}}},
          {:ok, %{result | generation: -1}},
          {:ok, Map.put(result, :secret, "hidden")},
          {:error, "secret"},
          {:error, %Error{code: :invalid, retryable?: :bad}}
        ] do
      assert {:error, %Error{code: :invalid, message: nil, details: %{}}} =
               Documents.create(
                 %{repository: Fake.DocumentRepository, repository_context: {self(), output}},
                 command
               )
    end

    error =
      Error.new(:storage_unavailable,
        message: "secret",
        details: %{secret: "value"},
        retryable?: true
      )

    assert {:error,
            %Error{code: :storage_unavailable, message: nil, details: %{}, retryable?: true}} =
             Documents.create(
               %{
                 repository: Fake.DocumentRepository,
                 repository_context: {self(), {:error, error}}
               },
               command
             )
  end
end
