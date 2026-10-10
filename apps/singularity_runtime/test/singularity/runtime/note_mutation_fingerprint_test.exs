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

  test "explicit empty create source sets retain the exact v1 receipt" do
    expected =
      expected_hmac(@secret, {:note_mutation_v1, :create, @mutation_id, "Title", "Markdown"})

    for fields <- [%{}, %{attachments: []}, %{citations: []}, %{attachments: [], citations: []}] do
      assert {:ok, prepared} = Command.new(:create, Map.merge(raw_command(:create), fields))
      assert {:ok, ^expected} = MutationFingerprint.compute(@secret, prepared)
    end
  end

  test "v2 receipts use independently literal ordered reference tuples for every source mode" do
    attachment = source_attachment(label: "e\u0301")
    citation = source_citation()
    attachment_term = {@other_id, @resource_id, @base_version_id, :asset, :source, "é"}

    citation_term =
      {@conflict_id, @resource_id, @base_version_id, String.duplicate("a", 64),
       fragment_locator_bytes(0)}

    for operation <- [:create, :save, :merge] do
      default = if operation == :create, do: {:replace, []}, else: :inherit

      cases = [
        {%{attachments: [attachment]}, {:replace, [attachment_term]}, default},
        {%{citations: [citation]}, default, {:replace, [citation_term]}},
        {%{attachments: [attachment], citations: [citation]}, {:replace, [attachment_term]},
         {:replace, [citation_term]}},
        {%{attachments: [], citations: [citation]}, {:replace, []}, {:replace, [citation_term]}},
        {%{attachments: [attachment], citations: []}, {:replace, [attachment_term]},
         {:replace, []}}
      ]

      cases =
        if operation == :create,
          do: cases,
          else:
            cases ++
              [
                {%{attachments: []}, {:replace, []}, :inherit},
                {%{citations: []}, :inherit, {:replace, []}},
                {%{attachments: [], citations: []}, {:replace, []}, {:replace, []}}
              ]

      for {fields, attachments_mode, citations_mode} <- cases do
        assert {:ok, prepared} = Command.new(operation, Map.merge(raw_command(operation), fields))
        expected_term = literal_v2_term(operation, attachments_mode, citations_mode)
        assert Command.fingerprint_term(prepared) == expected_term
        expected = expected_hmac(@secret, expected_term)
        assert {:ok, ^expected} = MutationFingerprint.compute(@secret, prepared)
      end
    end
  end

  test "each variable attachment and citation semantic field changes the receipt" do
    attachment_changes = [
      attachment_id: @mutation_id,
      target_resource_id: @other_id,
      target_resource_version_id: @other_id,
      target_kind: :note,
      label: "Changed",
      label: "",
      label: nil
    ]

    citation_changes = [
      citation_id: @mutation_id,
      source_resource_id: @other_id,
      source_resource_version_id: @other_id,
      fragment_id: String.duplicate("b", 64),
      locator: %{version: 1, kind: "fragment", ordinal: 1},
      locator: %{version: 1, kind: "text", start_line: 1, end_line: 1}
    ]

    for operation <- [:create, :save, :merge] do
      fields = %{
        attachments: [source_attachment(label: "Original")],
        citations: [source_citation()]
      }

      assert {:ok, original} = Command.new(operation, Map.merge(raw_command(operation), fields))
      assert {:ok, digest} = MutationFingerprint.compute(@secret, original)

      for {field, changes} <- [attachments: attachment_changes, citations: citation_changes],
          {key, value} <- changes do
        [reference] = Map.fetch!(fields, field)
        changed_fields = Map.put(fields, field, [Map.put(reference, key, value)])

        assert {:ok, changed} =
                 Command.new(operation, Map.merge(raw_command(operation), changed_fields))

        assert {:ok, changed_digest} = MutationFingerprint.compute(@secret, changed)
        refute changed_digest == digest, "#{operation}.#{field}.#{key} did not affect the receipt"
      end

      # The source role is fixed: the literal oracle includes it, and alternative values are invalid.
      assert Command.new(
               operation,
               Map.merge(raw_command(operation), %{
                 attachments: [source_attachment(role: :citation)]
               })
             ) == {:error, Error.new(:invalid)}
    end
  end

  test "ordered source lists and independent inherit-clear modes have distinct receipts" do
    attachment1 = source_attachment()
    attachment2 = source_attachment(attachment_id: @mutation_id, target_resource_id: @other_id)
    citation1 = source_citation()
    citation2 = source_citation(citation_id: @mutation_id, fragment_id: String.duplicate("b", 64))

    for operation <- [:create, :save, :merge] do
      cases = [
        %{attachments: [attachment1, attachment2], citations: [citation1, citation2]},
        %{attachments: [attachment2, attachment1], citations: [citation1, citation2]},
        %{attachments: [attachment1, attachment2], citations: [citation2, citation1]},
        %{attachments: [attachment1], citations: []},
        %{attachments: [], citations: [citation1]}
      ]

      cases =
        if operation == :create,
          do: cases,
          else:
            cases ++
              [
                %{},
                %{attachments: []},
                %{citations: []},
                %{attachments: [], citations: []},
                %{attachments: [attachment1]},
                %{citations: [citation1]}
              ]

      digests =
        for fields <- cases do
          assert {:ok, prepared} =
                   Command.new(operation, Map.merge(raw_command(operation), fields))

          assert {:ok, digest} = MutationFingerprint.compute(@secret, prepared)
          digest
        end

      assert Enum.uniq(digests) == digests
    end
  end

  test "v2 normalization is equivalent and excludes composed context just like v1" do
    raw =
      Map.merge(raw_command(:save), %{
        attachments: [source_attachment(label: "é")],
        citations: [
          source_citation(locator: %{version: 1, kind: "markdown", heading_path: ["é"]})
        ]
      })

    normalized_input =
      Map.merge(raw_command(:save), %{
        attachments: [source_attachment(target_kind: "asset", role: "source", label: "e\u0301")],
        citations: [
          source_citation(locator: %{version: 1, kind: "markdown", heading_path: ["e\u0301"]})
        ]
      })

    assert {:ok, prepared} = Command.new(:save, raw)
    assert {:ok, ^prepared} = Command.new(:save, normalized_input)
    assert {:ok, digest} = MutationFingerprint.compute(@secret, prepared)

    for field <- [:principal_id, :vault_id, :correlation_id] do
      assert {:ok, changed} = Command.new(:save, Map.put(raw, field, @other_id))
      assert {:ok, ^digest} = MutationFingerprint.compute(@secret, changed)
    end

    for field <- [:version_id, :created_at, :current_head, :source_proof, :witness] do
      assert Command.new(:save, Map.put(raw, field, "private-canary")) ==
               {:error, Error.new(:invalid)}
    end
  end

  test "fingerprinting rejects forged modes and noncanonical nested references with sanitized errors" do
    assert {:ok, prepared} =
             Command.new(
               :save,
               Map.merge(raw_command(:save), %{
                 attachments: [source_attachment()],
                 citations: [source_citation()]
               })
             )

    [attachment] = Map.fetch!(prepared.snapshot, :attachments)
    [citation] = Map.fetch!(prepared.snapshot, :citations)

    assert {:ok, heading_locator} =
             Singularity.Core.SourceLocator.new(%{
               version: 1,
               kind: "markdown",
               heading_path: ["é"]
             })

    snapshots = [
      Map.put(prepared.snapshot, :attachments, "inherit"),
      Map.put(prepared.snapshot, :attachments, [Map.put(attachment, :target_kind, "asset")]),
      Map.put(prepared.snapshot, :attachments, [Map.put(attachment, :role, "source")]),
      Map.put(prepared.snapshot, :attachments, [Map.put(attachment, :label, "e\u0301")]),
      Map.put(prepared.snapshot, :attachments, [Map.put(attachment, :ordinal, 0)]),
      Map.put(prepared.snapshot, :attachments, [Map.from_struct(attachment)]),
      Map.put(prepared.snapshot, :citations, [Map.put(citation, :fragment_id, "private-canary")]),
      Map.put(prepared.snapshot, :citations, [
        Map.put(citation, :locator, %{heading_locator | fields: %{heading_path: ["e\u0301"]}})
      ]),
      Map.put(prepared.snapshot, :citations, [
        Map.put(citation, :locator, Map.put(citation.locator, :text, "private-canary"))
      ]),
      Map.put(prepared.snapshot, :citations, [Map.from_struct(citation)]),
      Map.put(prepared.snapshot, :citations, [attachment]),
      Map.delete(prepared.snapshot, :citations),
      Map.put(prepared.snapshot, :witness, "private-canary"),
      Map.from_struct(prepared.snapshot)
    ]

    for forged <- [
          Map.put(prepared, :witness, "private-canary")
          | Enum.map(snapshots, &Map.put(prepared, :snapshot, &1))
        ] do
      assert MutationFingerprint.compute(@secret, forged) == {:error, Error.new(:invalid)}
    end

    create = command!(:create)

    assert MutationFingerprint.compute(@secret, %{
             create
             | snapshot: Map.put(create.snapshot, :attachments, :inherit)
           }) == {:error, Error.new(:invalid)}
  end

  defp literal_v2_term(:create, attachments, citations),
    do: {:note_mutation_v2, :create, @mutation_id, "Title", "Markdown", attachments, citations}

  defp literal_v2_term(:save, attachments, citations),
    do:
      {:note_mutation_v2, :save, @mutation_id, @resource_id, @base_version_id, "Title",
       "Markdown", attachments, citations}

  defp literal_v2_term(:merge, attachments, citations),
    do:
      {:note_mutation_v2, :merge, @mutation_id, @resource_id, @conflict_id,
       @expected_current_version_id, @competing_version_id, "Title", "Markdown", attachments,
       citations}

  defp source_attachment(overrides \\ []),
    do:
      Map.merge(
        %{
          attachment_id: @other_id,
          target_resource_id: @resource_id,
          target_resource_version_id: @base_version_id,
          target_kind: :asset
        },
        Map.new(overrides)
      )

  defp source_citation(overrides \\ []),
    do:
      Map.merge(
        %{
          citation_id: @conflict_id,
          source_resource_id: @resource_id,
          source_resource_version_id: @base_version_id,
          fragment_id: String.duplicate("a", 64),
          locator: %{version: 1, kind: "fragment", ordinal: 0}
        },
        Map.new(overrides)
      )

  defp fragment_locator_bytes(ordinal) do
    decimal = Integer.to_string(ordinal)

    <<1::unsigned-big-64, "1", 8::unsigned-big-64, "fragment",
      byte_size(decimal)::unsigned-big-64, decimal::binary>>
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
