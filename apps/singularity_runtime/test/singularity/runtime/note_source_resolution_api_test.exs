defmodule Singularity.Runtime.NoteSourceResolutionApiTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.{
    DocumentFragment,
    Error,
    NoteAttachmentReference,
    NoteCitationReference,
    SourceLocator
  }

  alias Singularity.Runtime.Api
  alias Singularity.Runtime.DTO.Session
  alias Singularity.Runtime.SessionContext

  @session "00000000-0000-4000-8000-000000008001"
  @account "00000000-0000-4000-8000-000000008002"
  @principal "00000000-0000-4000-8000-000000008003"
  @owner "00000000-0000-4000-8000-000000008004"
  @note "00000000-0000-4000-8000-000000008005"
  @version "00000000-0000-4000-8000-000000008006"
  @member "00000000-0000-4000-8000-000000008007"
  @target "00000000-0000-4000-8000-000000008008"
  @target_version "00000000-0000-4000-8000-000000008009"
  @other "00000000-0000-4000-8000-000000008010"
  @uppercase "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"

  # Injectable facade callbacks are unit-only. They do not establish live
  # containing/target authorization, canonical persistence, locks or custody.
  for operation <- [:attachment, :citation] do
    @operation operation

    test "public #{@operation} /4 rejects bad selectors without touching production readers" do
      for invalid <- [nil, "bad", @uppercase] do
        assert {:error, :invalid} =
                 apply(Api, function(@operation), [session(), invalid, @version, @member])
      end
    end

    test "configured #{@operation} /5 dispatches exact authenticated context and canonical references" do
      raw = resolved(@operation)

      for format <- [:core, :dto] do
        input =
          if format == :dto,
            do: %{raw | reference: dto_reference(@operation, raw.reference)},
            else: raw

        assert {:ok, result} = call(@operation, {:ok, input})
        assert_exact_result(@operation, result, raw)
        assert_callback(@operation)
      end
    end

    test "#{@operation} validates every canonical selector before callback invocation" do
      for field <- [:note, :version, :member], invalid <- [nil, "bad", @uppercase, <<0::128>>] do
        ids = Map.put(%{note: @note, version: @version, member: @member}, field, invalid)
        assert {:error, :invalid} = call(@operation, {:ok, resolved(@operation)}, session(), ids)
        refute_received {:api_resolution_call, _, _, _, _, _}
      end
    end

    test "#{@operation} rejects malformed session DTO context before callback invocation" do
      for {field, values} <- [
            {:session_id, [nil, "bad", @uppercase]},
            {:account_id, ["bad", @uppercase]},
            {:principal_id, [nil, "bad", @uppercase]},
            {:vault_id, [nil, "bad", @uppercase]},
            {:expires_at, [nil, "not-a-date"]},
            {:principal_authorization_epoch, [nil, -1, "3"]},
            {:vault_authorization_epoch, [nil, -1, "5"]},
            {:authorization_epoch, [nil, -1, "3"]},
            {:unlocked?, [nil, :yes]}
          ],
          value <- values do
        assert {:error, :integrity_failure} =
                 call(@operation, {:ok, resolved(@operation)}, Map.put(session(), field, value))

        refute_received {:api_resolution_call, _, _, _, _, _}
      end

      for value <- [nil, %{}, Map.from_struct(session())] do
        assert {:error, :invalid} = call(@operation, {:ok, resolved(@operation)}, value)
        refute_received {:api_resolution_call, _, _, _, _, _}
      end

      malformed_structs =
        [Map.put(session(), :owner_scope_id, @other)] ++
          Enum.map(Map.keys(Map.from_struct(session())), &Map.delete(session(), &1))

      for value <- malformed_structs do
        assert {:error, :integrity_failure} = call(@operation, {:ok, resolved(@operation)}, value)
        refute_received {:api_resolution_call, _, _, _, _, _}
      end
    end

    test "#{@operation} binds the returned reference member identity to the request" do
      raw = resolved(@operation)

      changed =
        if @operation == :attachment,
          do: %{raw.reference | attachment_id: @other},
          else: %{raw.reference | citation_id: @other}

      assert_integrity(call(@operation, {:ok, %{raw | reference: changed}}))
      assert_callback(@operation)
    end

    test "#{@operation} does not drop unknown outer source or reference fields" do
      raw = resolved(@operation)

      for field <- [
            :owner_scope_id,
            :vault_id,
            :classification,
            :note_resource_id,
            :note_resource_version_id,
            :ordinal,
            :head_version_id,
            :source_metadata,
            :text,
            :markdown,
            :bytes,
            :storage_ref,
            :digest
          ] do
        for changed <- [
              Map.put(raw, field, "PRIVATE_SOURCE_CANARY"),
              %{raw | source: Map.put(raw.source, field, "PRIVATE_SOURCE_CANARY")},
              %{raw | reference: Map.put(raw.reference, field, "PRIVATE_SOURCE_CANARY")}
            ] do
          assert_integrity(call(@operation, {:ok, changed}))
          assert_callback(@operation)
        end
      end

      for field <- Map.keys(raw) do
        assert_integrity(call(@operation, {:ok, Map.delete(raw, field)}))
        assert_callback(@operation)
      end
    end

    test "#{@operation} never normalizes or defaults noncanonical server reference fields" do
      raw = resolved(@operation)
      fields = Map.from_struct(raw.reference)

      for changed <-
            noncanonical_references(@operation, raw.reference) ++
              Enum.map(Map.keys(fields), &Map.delete(fields, &1)) do
        assert_integrity(call(@operation, {:ok, %{raw | reference: changed}}))
        assert_callback(@operation)
      end
    end

    test "#{@operation} preserves exact historical target pins and boolean tombstone status" do
      raw = resolved(@operation)

      for deleted? <- [true, false] do
        expected = put_in(raw.source.deleted?, deleted?)
        assert {:ok, result} = call(@operation, {:ok, expected})
        assert_exact_result(@operation, result, expected)
        assert result.source.resource_version_id == @target_version
        assert_callback(@operation)
      end
    end

    test "#{@operation} rejects noncanonical or mismatched source metadata instead of following head" do
      raw = resolved(@operation)

      for changed <- [
            %{kind: "asset"},
            %{kind: :note},
            %{kind: :unknown},
            %{resource_id: @other},
            %{resource_version_id: @other},
            %{resource_id: @uppercase},
            %{resource_version_id: "bad"},
            %{deleted?: nil},
            %{deleted?: "false"},
            %{title: nil},
            %{title: ""},
            %{title: " \t"},
            %{title: <<255>>},
            %{title: "nul" <> <<0>>}
          ] do
        assert_integrity(call(@operation, {:ok, %{raw | source: Map.merge(raw.source, changed)}}))
        assert_callback(@operation)
      end

      for field <- Map.keys(raw.source) do
        assert_integrity(call(@operation, {:ok, %{raw | source: Map.delete(raw.source, field)}}))
        assert_callback(@operation)
      end
    end

    test "#{@operation} sanitizes stable errors and hides unknown error payloads" do
      for code <- [
            :not_found,
            :forbidden,
            :unauthenticated,
            :vault_locked,
            :integrity_failure,
            :invalid,
            :storage_unavailable
          ],
          retryable? <- [true, false] do
        error = %{
          Error.new(code, retryable?: retryable?)
          | message: "PRIVATE_SOURCE_TITLE",
            details: %{text: "PRIVATE_FRAGMENT_TEXT"}
        }

        assert {:error, ^code} = call(@operation, {:error, error})
        assert_callback(@operation)
        assert {:error, ^code} = call(@operation, {:error, code})
        assert_callback(@operation)
      end

      for reason <- [
            :unknown,
            "PRIVATE_EXCEPTION",
            %{code: :not_found, title: "PRIVATE_SOURCE"},
            %{Error.new(:not_found) | code: :unknown},
            {:authorization_denial, Error.new(:forbidden)}
          ] do
        assert {:error, :storage_unavailable} = call(@operation, {:error, reason})
        assert_callback(@operation)
      end
    end

    test "#{@operation} malformed successes never become empty or partial resolution" do
      for reply <- [
            nil,
            :ok,
            true,
            {:ok, nil},
            {:ok, %{}},
            {:ok, []},
            {:ok, %{reference: nil, source: nil}}
          ] do
        assert_integrity(call(@operation, reply))
        assert_callback(@operation)
      end
    end

    test "#{@operation} absent malformed or exception callbacks fail closed" do
      for config <- [
            %{},
            %{function(@operation) => nil},
            %{function(@operation) => false},
            %{function(@operation) => :not_a_callback},
            nil,
            []
          ] do
        assert {:error, :invalid} = configured_call(@operation, config)
        refute_received {:api_resolution_call, _, _, _, _, _}
      end

      assert {:error, :storage_unavailable} =
               configured_call(@operation, %{function(@operation) => fn _ -> :ok end})

      for failure <- [:raise, :throw, :exit] do
        assert {:error, :storage_unavailable} =
                 configured_call(@operation, %{
                   function(@operation) => fn _, _, _, _ ->
                     case failure do
                       :raise -> raise "PRIVATE_ADAPTER_MESSAGE"
                       :throw -> throw("PRIVATE_ADAPTER_MESSAGE")
                       :exit -> exit("PRIVATE_ADAPTER_MESSAGE")
                     end
                   end
                 })
      end
    end
  end

  test "attachment API preserves all three supported typed source kinds without changing pins" do
    raw = resolved(:attachment)

    for kind <- [:asset, :note, :document] do
      expected = %{
        raw
        | reference: %{raw.reference | target_kind: kind},
          source: %{raw.source | kind: kind}
      }

      assert {:ok, result} = call(:attachment, {:ok, expected})
      assert_exact_result(:attachment, result, expected)
      assert_callback(:attachment)
    end
  end

  test "attachment API preserves an original UTF-8 filename longer than Note title limits" do
    raw = resolved(:attachment)
    title = String.duplicate("文", 300) <> ".txt"
    expected = put_in(raw.source.title, title)
    assert {:ok, result} = call(:attachment, {:ok, expected})
    assert result.source.title == title
    assert byte_size(result.source.title) > 255
    assert_exact_result(:attachment, result, expected)
    assert_callback(:attachment)
  end

  test "citation API rebuilds only the selected canonical LF fragment with the exact locator" do
    raw = resolved(:citation, "First line\nSecond line\n")
    {:ok, other_locator} = SourceLocator.new(%{version: 1, kind: "fragment", ordinal: 3})
    assert {:ok, result} = call(:citation, {:ok, raw})
    assert_exact_result(:citation, result, raw)
    assert result.fragment.locator == raw.reference.locator
    assert Map.keys(result.fragment) |> Enum.sort() == [:fragment_id, :locator, :ordinal, :text]
    assert_callback(:citation)

    for changed <- [
          %{text: "Changed"},
          %{text: "First line\r\nSecond line\r\n"},
          %{text: "nul" <> <<0>>},
          %{text: <<255>>},
          %{fragment_id: String.duplicate("a", 64)},
          %{fragment_id: String.duplicate("A", 64)},
          %{ordinal: -1},
          %{ordinal: 3},
          %{ordinal: "2"},
          %{locator: other_locator},
          %{locator: SourceLocator.to_map(raw.fragment.locator)},
          %{locator: Map.put(raw.fragment.locator, :owner_scope_id, @owner)},
          %{digest: :binary.copy(<<0>>, 32)},
          %{owner_scope_id: @owner},
          %{classification: :private},
          %{resource_id: @target},
          %{resource_version_id: @target_version},
          %{fragments: [raw.fragment]},
          %{markdown: "PRIVATE_BODY"}
        ] do
      assert_integrity(
        call(:citation, {:ok, %{raw | fragment: Map.merge(raw.fragment, changed)}})
      )

      assert_callback(:citation)
    end

    for field <- Map.keys(raw.fragment) do
      assert_integrity(call(:citation, {:ok, %{raw | fragment: Map.delete(raw.fragment, field)}}))
      assert_callback(:citation)
    end
  end

  test "citation API enforces fragment byte bound even when a larger fragment has a matching identity" do
    raw = resolved(:citation, String.duplicate("x", 65_536))
    assert {:ok, result} = call(:citation, {:ok, raw})
    assert byte_size(result.fragment.text) == 65_536
    assert_callback(:citation)

    text = String.duplicate("x", 65_537)

    id =
      DocumentFragment.id(@target_version, raw.fragment.locator, 2, :crypto.hash(:sha256, text))

    oversized = %{
      raw
      | reference: %{raw.reference | fragment_id: id},
        fragment: %{raw.fragment | fragment_id: id, text: text}
    }

    assert_integrity(call(:citation, {:ok, oversized}))
    assert_callback(:citation)
  end

  defp function(:attachment), do: :resolve_note_attachment
  defp function(:citation), do: :resolve_note_citation

  defp call(
         operation,
         reply,
         session \\ session(),
         ids \\ %{note: @note, version: @version, member: @member}
       ) do
    parent = self()

    config = %{
      function(operation) => fn context, note, version, member ->
        send(parent, {:api_resolution_call, operation, context, note, version, member})
        reply
      end
    }

    configured_call(operation, config, session, ids)
  end

  defp configured_call(
         operation,
         config,
         session \\ session(),
         ids \\ %{note: @note, version: @version, member: @member}
       ),
       do: apply(Api, function(operation), [config, session, ids.note, ids.version, ids.member])

  defp assert_callback(operation) do
    assert_received {:api_resolution_call, ^operation, context, @note, @version, @member}
    assert context.__struct__ == SessionContext
    assert Map.from_struct(context) == Map.from_struct(session())
    refute_received {:api_resolution_call, _, _, _, _, _}
  end

  defp assert_exact_result(operation, result, expected) do
    keys =
      if operation == :citation, do: [:fragment, :reference, :source], else: [:reference, :source]

    assert Map.keys(result) |> Enum.sort() == keys
    assert result.reference == dto_reference(operation, expected.reference)
    assert Map.from_struct(result.reference) == Map.from_struct(expected.reference)
    assert result.source == expected.source

    assert Map.keys(result.source) |> Enum.sort() == [
             :deleted?,
             :kind,
             :resource_id,
             :resource_version_id,
             :title
           ]

    if operation == :citation, do: assert(result.fragment == expected.fragment)
  end

  defp dto_reference(operation, reference) do
    module =
      if operation == :attachment,
        do: Singularity.Runtime.DTO.NoteAttachment,
        else: Singularity.Runtime.DTO.NoteCitation

    {:ok, dto} = apply(module, :new, [reference])
    dto
  end

  defp noncanonical_references(:attachment, reference),
    do: [
      %{reference | target_kind: "asset"},
      %{reference | role: "source"},
      %{reference | label: "e\u0301"},
      %{reference | target_resource_id: @uppercase},
      Map.put(Map.from_struct(reference), :target_kind, "asset"),
      Map.put(Map.from_struct(reference), :role, "source")
    ]

  defp noncanonical_references(:citation, reference),
    do: [
      %{reference | locator: SourceLocator.to_map(reference.locator)},
      %{reference | fragment_id: String.duplicate("A", 64)},
      %{reference | source_resource_id: @uppercase},
      Map.put(Map.from_struct(reference), :locator, SourceLocator.to_map(reference.locator))
    ]

  defp resolved(operation, text \\ "Selected LF fragment\n") do
    {reference, fragment} =
      if operation == :citation do
        {:ok, locator} = SourceLocator.new(%{version: 1, kind: "fragment", ordinal: 2})

        {:ok, fragment} =
          DocumentFragment.new(%{
            resource_id: @target,
            resource_version_id: @target_version,
            owner_scope_id: @owner,
            classification: :private,
            ordinal: 2,
            text: text,
            locator: locator
          })

        {:ok, reference} =
          NoteCitationReference.new(%{
            citation_id: @member,
            source_resource_id: @target,
            source_resource_version_id: @target_version,
            fragment_id: fragment.fragment_id,
            locator: locator
          })

        {reference, Map.take(fragment, [:fragment_id, :ordinal, :text, :locator])}
      else
        {:ok, reference} =
          NoteAttachmentReference.new(%{
            attachment_id: @member,
            target_resource_id: @target,
            target_resource_version_id: @target_version,
            target_kind: :asset,
            role: :source,
            label: nil
          })

        {reference, nil}
      end

    source = %{
      kind: if(operation == :citation, do: :document, else: :asset),
      resource_id: @target,
      resource_version_id: @target_version,
      title: "Pinned source title",
      deleted?: false
    }

    result = %{reference: reference, source: source}
    if operation == :citation, do: Map.put(result, :fragment, fragment), else: result
  end

  defp session do
    %Session{
      session_id: @session,
      account_id: @account,
      principal_id: @principal,
      vault_id: @owner,
      expires_at: ~U[2026-12-31 00:00:00.000000Z],
      principal_authorization_epoch: 3,
      vault_authorization_epoch: 5,
      authorization_epoch: 3,
      unlocked?: true
    }
  end

  defp assert_integrity(result), do: assert(result == {:error, :integrity_failure})
end
