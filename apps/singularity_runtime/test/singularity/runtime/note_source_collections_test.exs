defmodule Singularity.Runtime.NoteSourceCollectionsTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.{Error, NoteAttachmentReference, NoteCitationReference, SourceLocator}
  alias Singularity.Runtime.DTO.{Note, NoteAttachment, NoteCitation, NoteVersion}
  alias Singularity.Runtime.Notes.SourceCollections
  alias Singularity.Runtime.SessionContext

  @owner "00000000-0000-4000-8000-000000005001"
  @principal "00000000-0000-4000-8000-000000005002"
  @note "00000000-0000-4000-8000-000000005003"
  @version "00000000-0000-4000-8000-000000005004"
  @target "00000000-0000-4000-8000-000000005005"
  @target_version "00000000-0000-4000-8000-000000005006"
  @attachment "00000000-0000-4000-8000-000000005007"
  @citation "00000000-0000-4000-8000-000000005008"
  @time ~U[2026-10-11 08:00:00.000000Z]

  # Explicit unit reader: observes composition only, not canonical SQL, source
  # authority, session custody or real scoped-GUC enforcement.
  defmodule Reader do
    def read_membership(owner, context, note_id, version_id) do
      send(owner, {:membership_call, context, note_id, version_id})
      Process.get(:collection_membership_result)
    end
  end

  defmodule Membership do
    defstruct [:revision, :attachments, :citations]
  end

  test "attachment DTO normalizes exactly the existing owner-free reference fields" do
    input = attachment()
    aliases = Map.new(input, fn {key, value} -> {Atom.to_string(key), value} end)
    aliases = %{aliases | "target_kind" => "asset", "role" => "source", "label" => "e\u0301"}
    assert {:ok, dto} = construct(NoteAttachment, aliases)
    assert dto.__struct__ == NoteAttachment
    assert Map.from_struct(dto) == %{input | label: "é"}
    assert {:ok, ^dto} = construct(NoteAttachment, dto)
  end

  test "citation DTO exposes a canonical locator and no containing or evidence fields" do
    input = citation()
    assert {:ok, dto} = construct(NoteCitation, input)
    assert dto.__struct__ == NoteCitation
    assert Enum.sort(Map.keys(Map.from_struct(dto))) == Enum.sort(Map.keys(input))
    assert SourceLocator.to_map(dto.locator) == input.locator
    assert {:ok, ^dto} = construct(NoteCitation, dto)
  end

  for {module, reference} <- [{NoteAttachment, :attachment}, {NoteCitation, :citation}] do
    @reference_module module
    @reference_kind reference

    test "#{inspect(module)} rejects extra private fields, missing IDs and forged structs" do
      input = apply(__MODULE__, @reference_kind, [])

      for field <- [
            :owner_scope_id,
            :vault_id,
            :classification,
            :note_resource_id,
            :note_resource_version_id,
            :ordinal,
            :inserted_at,
            :source_metadata,
            :digest,
            :storage_ref,
            :bytes
          ] do
        assert_integrity(
          construct(@reference_module, Map.put(input, field, "PRIVATE_SOURCE_CANARY"))
        )
      end

      id_key = if @reference_kind == :attachment, do: :attachment_id, else: :citation_id
      assert_integrity(construct(@reference_module, Map.delete(input, id_key)))

      assert_integrity(
        construct(
          @reference_module,
          Map.put(input, id_key, String.upcase("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"))
        )
      )

      core =
        if @reference_kind == :attachment,
          do: NoteAttachmentReference,
          else: NoteCitationReference

      assert {:ok, valid} = construct(core, input)
      assert_integrity(construct(@reference_module, Map.put(valid, :owner_scope_id, @owner)))

      forged =
        if @reference_kind == :attachment,
          do: %{valid | target_kind: "asset"},
          else: %{valid | fragment_id: String.duplicate("A", 64)}

      assert_integrity(construct(@reference_module, forged))
    end
  end

  for module <- [Note, NoteVersion] do
    @note_module module

    test "#{inspect(module)} requires both arrays and preserves ordered owner-free nested DTOs" do
      attrs = dto_attrs(@note_module)
      refs = references()
      assert {:ok, dto} = construct(@note_module, Map.merge(attrs, refs))

      assert Enum.map(dto.attachments, & &1.attachment_id) ==
               Enum.map(refs.attachments, & &1.attachment_id)

      assert Enum.all?(dto.attachments, &(&1.__struct__ == NoteAttachment))
      assert Enum.all?(dto.citations, &(&1.__struct__ == NoteCitation))

      for missing <- [[:attachments], [:citations], [:attachments, :citations]] do
        assert_integrity(construct(@note_module, Map.drop(Map.merge(attrs, refs), missing)))
      end

      assert {:ok, empty} =
               construct(@note_module, Map.merge(attrs, %{attachments: [], citations: []}))

      assert empty.attachments == []
      assert empty.citations == []
    end

    test "#{inspect(module)} rejects oversized, duplicate, malformed and private reference collections" do
      attrs = Map.merge(dto_attrs(@note_module), %{attachments: [], citations: []})
      a = attachment()
      c = citation()
      same_pin = %{a | attachment_id: generated_uuid(90)}

      for changed <- [
            %{attachments: nil},
            %{citations: :inherit},
            %{attachments: [a, a]},
            %{attachments: [a, same_pin]},
            %{citations: [c, c]},
            %{attachments: [Map.put(a, :owner_scope_id, @owner)]},
            %{citations: [Map.put(c, :text, "PRIVATE_FRAGMENT_CANARY")]},
            %{attachments: Enum.map(1..101, &unique_attachment/1)},
            %{citations: Enum.map(1..101, &%{c | citation_id: generated_uuid(&1)})},
            %{attachments: [a | :improper]},
            %{citations: [c | :improper]}
          ] do
        assert_integrity(construct(@note_module, Map.merge(attrs, changed)))
      end

      full = %{
        attachments: Enum.map(1..100, &unique_attachment/1),
        citations: Enum.map(1..100, &%{c | citation_id: generated_uuid(&1)})
      }

      assert {:ok, bounded} = construct(@note_module, Map.merge(attrs, full))
      assert length(bounded.attachments) == 100
      assert length(bounded.citations) == 100
    end
  end

  for mode <- [:empty, :attachments, :citations, :both] do
    @mode mode

    test "source composer binds exact row revision/session identity and returns #{@mode} in canonical order" do
      refs = references(@mode)

      Process.put(
        :collection_membership_result,
        {:ok, Map.put(core_references(refs), :revision, 2)}
      )

      raw = raw_note()
      assert {:ok, composed} = compose(raw)
      assert Map.drop(composed, [:attachments, :citations]) == raw
      assert Enum.map(composed.attachments, &Map.from_struct/1) == refs.attachments

      assert Enum.map(composed.citations, &SourceLocator.to_map(&1.locator)) ==
               Enum.map(refs.citations, & &1.locator)

      assert Enum.all?(composed.attachments, &(&1.__struct__ == NoteAttachment))
      assert Enum.all?(composed.citations, &(&1.__struct__ == NoteCitation))

      assert_received {:membership_call, context, @note, @version}
      assert context == %{repo: :scoped_repo, principal_id: @principal, owner_scope_id: @owner}
      refute_received {:membership_call, _, _, _}
    end
  end

  test "composer rejects malformed row identity or owner scope before membership work" do
    Process.put(
      :collection_membership_result,
      {:ok, %{revision: 2, attachments: [], citations: []}}
    )

    for changed <- [
          %{resource_id: "not-a-uuid"},
          %{resource_version_id: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"},
          %{vault_id: @target},
          %{classification: :sensitive},
          %{revision: -1},
          %{revision: "2"}
        ] do
      assert_integrity(compose(Map.merge(raw_note(), changed)))
      refute_received {:membership_call, _, _, _}
    end
  end

  test "composer never defaults missing, mismatched or invalid membership to empty" do
    refs = core_references(references())

    for reply <- [
          nil,
          :ok,
          {:ok, nil},
          {:ok, %{}},
          {:ok, Map.put(refs, :revision, 1)},
          {:ok, Map.put(refs, :revision, "2")},
          {:ok, %{revision: 2, attachments: [], citations: [], owner_scope_id: @owner}},
          {:ok, %{revision: 2, attachments: nil, citations: []}},
          {:ok, %{revision: 2, attachments: [], citations: :inherit}},
          {:error, :not_found}
        ] do
      Process.put(:collection_membership_result, reply)
      assert_integrity(compose(raw_note()))
      assert_received {:membership_call, _, @note, @version}
    end
  end

  test "composer sanitizes known repository errors without publishing caller content" do
    for code <- [:not_found, :forbidden, :storage_unavailable] do
      error = %{
        Error.new(code, retryable?: true)
        | message: "PRIVATE_SOURCE_CANARY",
          details: %{title: "PRIVATE_TITLE"}
      }

      Process.put(:collection_membership_result, {:error, error})
      assert {:error, clean} = compose(raw_note())
      assert clean == Error.new(code, retryable?: true)
      assert_received {:membership_call, _, @note, @version}
    end
  end

  test "composer rejects incomplete or normalization-changing server reference output" do
    refs = core_references(references())
    [first | rest] = refs.attachments
    attachment = Map.from_struct(first)
    [citation] = refs.citations
    citation = Map.from_struct(citation)

    for changed <- [
          %{attachments: [Map.delete(attachment, :role) | rest]},
          %{attachments: [Map.delete(attachment, :label) | rest]},
          %{attachments: [Map.put(attachment, :target_kind, "asset") | rest]},
          %{attachments: [Map.put(attachment, :role, "source") | rest]},
          %{attachments: [Map.put(attachment, :label, "e\u0301") | rest]},
          %{
            attachments: [
              Map.new(attachment, fn {key, value} -> {Atom.to_string(key), value} end) | rest
            ]
          },
          %{citations: [Map.put(citation, :locator, SourceLocator.to_map(citation.locator))]},
          %{citations: [Map.new(citation, fn {key, value} -> {Atom.to_string(key), value} end)]}
        ] do
      Process.put(
        :collection_membership_result,
        {:ok, refs |> Map.put(:revision, 2) |> Map.merge(changed)}
      )

      assert_integrity(compose(raw_note()))
      assert_received {:membership_call, _, @note, @version}
    end

    Process.put(
      :collection_membership_result,
      {:ok, struct!(Membership, Map.put(refs, :revision, 2))}
    )

    assert_integrity(compose(raw_note()))
    assert_received {:membership_call, _, @note, @version}
  end

  test "composer preserves exact canonical Core, DTO and complete map references" do
    refs = core_references(references())

    for representation <- [:core, :dto, :map] do
      converted = %{
        attachments:
          Enum.map(refs.attachments, &representation(&1, representation, NoteAttachment)),
        citations: Enum.map(refs.citations, &representation(&1, representation, NoteCitation))
      }

      Process.put(:collection_membership_result, {:ok, Map.put(converted, :revision, 2)})
      assert {:ok, composed} = compose(raw_note())

      assert Enum.map(composed.attachments, &Map.from_struct/1) ==
               Enum.map(refs.attachments, &Map.from_struct/1)

      assert Enum.map(composed.citations, &Map.from_struct/1) ==
               Enum.map(refs.citations, &Map.from_struct/1)

      assert_received {:membership_call, _, @note, @version}
    end
  end

  defp representation(value, :core, _module), do: value
  defp representation(value, :map, _module), do: Map.from_struct(value)

  defp representation(value, :dto, module) do
    {:ok, dto} = construct(module, value)
    dto
  end

  # Public only for the generated constructor tests; never Runtime adapters.
  def attachment do
    %{
      attachment_id: @attachment,
      target_resource_id: @target,
      target_resource_version_id: @target_version,
      target_kind: :asset,
      role: :source,
      label: "Pinned"
    }
  end

  def citation do
    %{
      citation_id: @citation,
      source_resource_id: @target,
      source_resource_version_id: @target_version,
      fragment_id: String.duplicate("a", 64),
      locator: %{"version" => 1, "kind" => "text", "start_line" => 1, "end_line" => 1}
    }
  end

  defp references do
    %{
      attachments: [unique_attachment(2), unique_attachment(1)],
      citations: [citation()]
    }
  end

  defp references(:empty), do: %{attachments: [], citations: []}
  defp references(:attachments), do: %{references() | citations: []}
  defp references(:citations), do: %{references() | attachments: []}
  defp references(:both), do: references()

  defp unique_attachment(number),
    do: %{
      attachment()
      | attachment_id: generated_uuid(number),
        target_resource_id: generated_uuid(number + 200),
        target_resource_version_id: generated_uuid(number + 400)
    }

  defp generated_uuid(number),
    do: "00000000-0000-4000-8000-" <> String.pad_leading(Integer.to_string(number), 12, "0")

  defp core_references(refs) do
    %{
      attachments:
        Enum.map(refs.attachments, fn ref ->
          {:ok, result} = construct(NoteAttachmentReference, ref)
          result
        end),
      citations:
        Enum.map(refs.citations, fn ref ->
          {:ok, result} = construct(NoteCitationReference, ref)
          result
        end)
    }
  end

  defp compose(raw),
    do: apply(SourceCollections, :compose, [{Reader, self()}, :scoped_repo, session(), raw])

  defp construct(module, attrs), do: apply(module, :new, [attrs])

  defp assert_integrity(result),
    do: assert(match?({:error, %Error{code: :integrity_failure}}, result))

  defp session,
    do: %SessionContext{
      session_id: @principal,
      account_id: @principal,
      principal_id: @principal,
      vault_id: @owner,
      expires_at: DateTime.add(@time, 3600, :second),
      principal_authorization_epoch: 0,
      vault_authorization_epoch: 0,
      authorization_epoch: 0,
      unlocked?: true
    }

  defp dto_attrs(Note) do
    %{
      resource_id: @note,
      resource_version_id: @version,
      title: "Note",
      revision: 2,
      display_version: 3,
      updated_at: @time,
      deleted?: false,
      open_conflict_count: 0,
      markdown: "Body"
    }
  end

  defp dto_attrs(NoteVersion) do
    %{
      resource_id: @note,
      resource_version_id: @version,
      title: "Note",
      markdown: "Body",
      revision: 2,
      display_version: 3,
      created_by_principal_id: @principal,
      inserted_at: @time,
      parent_version_id: generated_uuid(999),
      merge_parent_version_id: nil,
      canonical?: true,
      conflict_state: nil
    }
  end

  defp raw_note do
    dto_attrs(Note)
    |> Map.delete(:display_version)
    |> Map.merge(%{
      vault_id: @owner,
      classification: :private,
      deleted_at: nil,
      created_by_principal_id: @principal,
      inserted_at: @time,
      parent_version_id: nil,
      merge_parent_version_id: nil,
      canonical?: true
    })
  end
end
