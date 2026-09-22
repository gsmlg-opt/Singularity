defmodule Singularity.Core.DocumentValuesTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.{
    DocumentFragment,
    DocumentSource,
    DocumentVersion,
    DocumentCompletion,
    Error,
    SourceLocator
  }

  @uuid "00000000-0000-4000-8000-000000000001"
  @id "a5e06997d69433d9a127780ef4d01c4e7147691745f5fcac15b230d3c3e48a48"

  test "fragment identity matches the independent vector" do
    assert {:ok, locator} = SourceLocator.new(attrs().locator)
    digest = :crypto.hash(:sha256, "hello\n")

    assert Base.encode16(digest, case: :lower) ==
             "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03"

    assert DocumentFragment.id(@uuid, locator, 0, digest) == @id
    assert {:ok, fragment} = DocumentFragment.new(attrs())
    assert fragment.digest == digest
    assert fragment.fragment_id == @id
    assert {:ok, ^fragment} = DocumentFragment.new(fragment)
    assert {:ok, ^fragment} = DocumentFragment.new(Map.from_struct(fragment))
  end

  test "constructor verifies supplied digest and identity and rejects unnormalized body" do
    for {key, values} <- [
          resource_id: [nil, "uuid", String.upcase("abcdef00-0000-4000-8000-000000000001")],
          resource_version_id: [nil, "uuid"],
          owner_scope_id: [nil, "uuid"],
          classification: [:public, nil],
          ordinal: [-1, 9_223_372_036_854_775_808, 1.0],
          text: [nil, <<255>>, "a\0", "a\rb", "a\r\nb", String.duplicate("a", 65_537)],
          digest: [nil, "digest", :crypto.hash(:sha256, "different")],
          fragment_id: [nil, "wrong"],
          locator: [nil, %{}],
          heading_path: [[]],
          vault_id: [@uuid],
          unexpected: [true]
        ],
        value <- values do
      assert {:error, %Error{code: :invalid}} = DocumentFragment.new(Map.put(attrs(), key, value))
    end

    assert {:error, %Error{code: :invalid}} = DocumentFragment.new(Map.put(attrs(), "ordinal", 1))

    assert {:ok, fragment} =
             DocumentFragment.new(Map.put(attrs(), :text, String.duplicate("a", 65_536)))

    assert byte_size(fragment.text) == 65_536
    assert {:ok, empty} = DocumentFragment.new(Map.put(attrs(), :text, ""))
    assert empty.digest == :crypto.hash(:sha256, "")
    assert {:ok, fragment} = DocumentFragment.new(attrs())
    assert {:error, %Error{code: :invalid}} = DocumentFragment.new(%{fragment | text: "changed"})
  end

  test "body Unicode remains byte-exact and identity inputs are validated" do
    assert {:ok, decomposed} = DocumentFragment.new(Map.put(attrs(), :text, "e\u0301"))
    assert {:ok, composed} = DocumentFragment.new(Map.put(attrs(), :text, "é"))
    refute decomposed.fragment_id == composed.fragment_id
    assert decomposed.text == "e\u0301"

    for {version, locator, ordinal, digest} <- [
          {"bad", attrs().locator, 0, composed.digest},
          {@uuid, %{}, 0, composed.digest},
          {@uuid, attrs().locator, -1, composed.digest},
          {@uuid, attrs().locator, 0, "not a digest"}
        ] do
      assert {:error, %Error{code: :invalid}} =
               DocumentFragment.id(version, locator, ordinal, digest)
    end
  end

  test "fallback locator ordinal agrees with its fragment ordinal" do
    fallback = %{version: 1, kind: "fragment", ordinal: 0}
    assert {:ok, _} = DocumentFragment.new(Map.put(attrs(), :locator, fallback))

    assert {:error, %Error{code: :invalid}} =
             DocumentFragment.new(Map.put(attrs(), :locator, %{fallback | ordinal: 1}))
  end

  test "unrelated structs are invalid constructor input" do
    assert {:error, %Error{code: :invalid}} = DocumentFragment.new(%URI{})
    assert {:error, %Error{code: :invalid}} = SourceLocator.new(%URI{})
  end

  test "source pins bounded private original bytes and rejects forged values" do
    assert {:ok, source} = DocumentSource.new(source_attrs())
    assert {:ok, ^source} = DocumentSource.new(source)

    for {key, value} <- [
          asset_id: "bad",
          resource_version_id: nil,
          object_id: "bad",
          owner_scope_id: nil,
          classification: :public,
          digest: "bad",
          byte_size: -1,
          byte_size: 67_108_865,
          media_type: "image/png",
          vault_id: @uuid
        ] do
      assert {:error, %Error{code: :invalid}} =
               DocumentSource.new(Map.put(source_attrs(), key, value))
    end

    assert {:error, %Error{code: :invalid}} = DocumentSource.new(%URI{})

    assert {:error, %Error{code: :invalid}} =
             DocumentSource.new(Map.put(source_attrs(), "asset_id", "bad"))
  end

  test "document lifecycle shapes are revalidated with source ownership" do
    assert {:ok, pending} = DocumentVersion.new(version_attrs())
    assert {:ok, ^pending} = DocumentVersion.new(pending)

    for changes <- [
          %{title: " "},
          %{title: <<255>>},
          %{title: "a\0"},
          %{title: String.duplicate("a", 256)},
          %{revision: -1},
          %{generation: -1},
          %{adapter_name: "text"},
          %{source: %{source_attrs() | owner_scope_id: other_uuid()}},
          %{source: %URI{}},
          %{inserted_at: nil},
          %{state: :extracting},
          %{fragments: []}
        ] do
      assert {:error, %Error{code: :invalid}} =
               DocumentVersion.new(Map.merge(version_attrs(), changes))
    end

    assert {:ok, extracting} =
             DocumentVersion.new(
               Map.merge(version_attrs(), %{
                 state: :extracting,
                 generation: 1,
                 attempt_job_id: @uuid,
                 attempt_started_at: ~U[2026-09-07 00:00:00.000000Z],
                 attempt_deadline_at: ~U[2026-09-07 00:03:00.000000Z],
                 adapter_name: "text",
                 format_version: 1
               })
             )

    assert {:ok, ^extracting} = DocumentVersion.new(extracting)

    assert {:ok, ready} =
             DocumentVersion.new(
               Map.merge(
                 version_attrs(),
                 Map.drop(completion_attrs(), [:outcome, :media_type])
                 |> Map.merge(%{
                   state: :ready,
                   attempt_job_id: @uuid,
                   attempt_started_at: ~U[2026-09-07 00:00:00.000000Z],
                   attempt_deadline_at: ~U[2026-09-07 00:03:00.000000Z]
                 })
               )
             )

    assert {:ok, ^ready} = DocumentVersion.new(ready)
  end

  test "completion atomically validates identity, media, ordinals and digest" do
    assert {:ok, completion} = DocumentCompletion.new(completion_attrs())
    assert {:ok, ^completion} = DocumentCompletion.new(completion)

    for changes <- [
          %{generation: 0},
          %{outcome: :pending},
          %{adapter_name: " "},
          %{format_version: 0},
          %{format_version: 2_147_483_648},
          %{finished_at: nil},
          %{extracted_text_digest: <<0::256>>},
          %{failure_code: "timeout"},
          %{detected_language: " "},
          %{fragments: []},
          %{fragments: [Map.put(attrs(), :text, "")]},
          %{fragments: [Map.put(attrs(), :ordinal, 1)]},
          %{fragments: [Map.put(attrs(), :owner_scope_id, other_uuid())]},
          %{fragments: [Map.put(attrs(), :resource_id, other_uuid())]},
          %{fragments: [Map.put(attrs(), :resource_version_id, other_uuid())]},
          %{fragments: [%URI{}]},
          %{media_type: "application/pdf"}
        ] do
      assert {:error, %Error{code: :invalid}} =
               DocumentCompletion.new(Map.merge(completion_attrs(), changes))
    end

    for outcome <- [:failed, :unsupported] do
      failure =
        completion_attrs()
        |> Map.drop([:fragments, :extracted_text_digest])
        |> Map.merge(%{outcome: outcome, failure_code: "timeout"})

      assert {:ok, value} = DocumentCompletion.new(failure)
      assert {:ok, ^value} = DocumentCompletion.new(value)

      assert {:error, %Error{code: :invalid}} =
               DocumentCompletion.new(%{failure | failure_code: "private message"})
    end
  end

  test "completion enforces aggregate fragment count and byte limits" do
    fragments = for ordinal <- 0..4096, do: %{attrs() | ordinal: ordinal}
    digest = :crypto.hash(:sha256, Enum.map(fragments, & &1.text))

    assert {:error, %Error{code: :invalid}} =
             DocumentCompletion.new(%{
               completion_attrs()
               | fragments: fragments,
                 extracted_text_digest: digest
             })

    fragments =
      for ordinal <- 0..256,
          do: %{attrs() | ordinal: ordinal, text: String.duplicate("a", 65_536)}

    digest = :crypto.hash(:sha256, Enum.map(fragments, & &1.text))

    assert {:error, %Error{code: :invalid}} =
             DocumentCompletion.new(%{
               completion_attrs()
               | fragments: fragments,
                 extracted_text_digest: digest
             })
  end

  test "source cannot be the same resource or version as its Document" do
    for key <- [:resource_id, :resource_version_id] do
      source = Map.put(source_attrs(), key, @uuid)

      assert {:error, %Error{code: :invalid}} =
               DocumentVersion.new(%{version_attrs() | source: source})
    end

    extracting =
      Map.merge(version_attrs(), %{
        state: :extracting,
        generation: 1,
        adapter_name: "text",
        format_version: 2_147_483_648
      })

    assert {:error, %Error{code: :invalid}} = DocumentVersion.new(extracting)
  end

  test "names are bounded after trimming and invalid dates never raise" do
    padded = String.duplicate(" ", 256) <> "Document "
    assert {:ok, %{title: "Document"}} = DocumentVersion.new(%{version_attrs() | title: padded})

    assert {:ok, %{adapter_name: "Document"}} =
             DocumentCompletion.new(%{completion_attrs() | adapter_name: padded})

    for timestamp <- [
          %{~U[2026-09-07 00:00:00Z] | month: 99},
          %{~U[2026-09-07 00:00:00Z] | hour: "private"},
          %{__struct__: DateTime},
          %URI{}
        ] do
      assert {:error, %Error{code: :invalid}} =
               DocumentCompletion.new(%{completion_attrs() | finished_at: timestamp})

      assert {:error, %Error{code: :invalid}} =
               DocumentVersion.new(%{version_attrs() | inserted_at: timestamp})
    end
  end

  test "nested forged values and unknown or conflicting fields are rejected" do
    assert {:ok, fragment} = DocumentFragment.new(attrs())
    assert {:ok, source} = DocumentSource.new(source_attrs())

    assert {:error, %Error{code: :invalid}} =
             DocumentCompletion.new(%{
               completion_attrs()
               | fragments: [%{fragment | text: "changed"}]
             })

    assert {:error, %Error{code: :invalid}} =
             DocumentVersion.new(%{version_attrs() | source: %{source | digest: nil}})

    for {module, input} <- [
          {DocumentVersion, version_attrs()},
          {DocumentCompletion, completion_attrs()},
          {DocumentSource, source_attrs()}
        ] do
      for forged <- [
            %URI{},
            %{__struct__: module},
            Map.put(input, :vault_id, @uuid),
            Map.put(input, "owner_scope_id", other_uuid()),
            Map.put(input, :unknown, "private")
          ] do
        assert {:error, %Error{code: :invalid}} = module.new(forged)
      end

      strings = Map.new(input, fn {key, value} -> {Atom.to_string(key), value} end)
      assert {:ok, _} = module.new(strings)
    end
  end

  test "ready extraction accepts exact total limits and all media fallback locators" do
    for media <- ["application/pdf", "text/markdown", "text/plain"] do
      fragment = %{attrs() | locator: %{version: 1, kind: "fragment", ordinal: 0}}

      assert {:ok, _} =
               DocumentCompletion.new(%{
                 completion_attrs()
                 | media_type: media,
                   fragments: [fragment]
               })
    end

    text = String.duplicate("a", 65_536)
    fragments = for ordinal <- 0..255, do: %{attrs() | ordinal: ordinal, text: text}
    digest = :crypto.hash(:sha256, Enum.map(fragments, & &1.text))

    assert {:ok, _} =
             DocumentCompletion.new(%{
               completion_attrs()
               | fragments: fragments,
                 extracted_text_digest: digest
             })

    assert {:ok, _} = DocumentSource.new(%{source_attrs() | byte_size: 67_108_864})
  end

  test "optional language is bounded text and outcomes reject content diagnostics" do
    for value <- [
          "",
          " ",
          <<255>>,
          "en\0",
          String.duplicate("a", 256),
          String.duplicate(" ", 256) <> "en"
        ] do
      assert {:error, %Error{code: :invalid}} =
               DocumentCompletion.new(Map.put(completion_attrs(), :detected_language, value))
    end

    assert {:ok, %{detected_language: "custom language"}} =
             DocumentCompletion.new(
               Map.put(completion_attrs(), :detected_language, "custom language")
             )

    for key <- [:adapter_name, :extracted_text_digest],
        value <- [<<255>>, "private\0", String.duplicate("x", 256)] do
      assert {:error, %Error{code: :invalid}} =
               DocumentCompletion.new(Map.put(completion_attrs(), key, value))
    end
  end

  defp other_uuid, do: "00000000-0000-4000-8000-000000000002"

  defp source_attrs,
    do: %{
      asset_id: @uuid,
      resource_id: other_uuid(),
      resource_version_id: other_uuid(),
      object_id: @uuid,
      owner_scope_id: @uuid,
      classification: :private,
      digest: <<0::256>>,
      byte_size: 0,
      media_type: "text/plain"
    }

  defp version_attrs,
    do: %{
      resource_id: @uuid,
      resource_version_id: @uuid,
      owner_scope_id: @uuid,
      classification: :private,
      revision: 0,
      source: source_attrs(),
      title: "Document",
      created_by_principal_id: @uuid,
      inserted_at: ~U[2026-09-07 00:00:00Z],
      state: :pending,
      generation: 0
    }

  defp completion_attrs,
    do: %{
      resource_id: @uuid,
      resource_version_id: @uuid,
      owner_scope_id: @uuid,
      classification: :private,
      generation: 1,
      outcome: :ready,
      adapter_name: "text",
      format_version: 1,
      finished_at: ~U[2026-09-07 00:00:00Z],
      media_type: "text/plain",
      fragments: [attrs()],
      extracted_text_digest: :crypto.hash(:sha256, "hello\n")
    }

  defp attrs do
    %{
      resource_id: @uuid,
      resource_version_id: @uuid,
      owner_scope_id: @uuid,
      classification: :private,
      ordinal: 0,
      text: "hello\n",
      locator: %{"version" => 1, "kind" => "text", "start_line" => 1, "end_line" => 1}
    }
  end
end
