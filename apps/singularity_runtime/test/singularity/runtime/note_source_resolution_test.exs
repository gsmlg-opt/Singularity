defmodule Singularity.Runtime.NoteSourceResolutionTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.{
    DocumentFragment,
    Error,
    NoteAttachmentReference,
    NoteCitationReference,
    SourceLocator
  }

  alias Singularity.Runtime.SessionContext

  @resolver Singularity.Runtime.Notes.ResolveSource
  @principal "00000000-0000-4000-8000-000000007001"
  @owner "00000000-0000-4000-8000-000000007002"
  @note "00000000-0000-4000-8000-000000007003"
  @version "00000000-0000-4000-8000-000000007004"
  @member "00000000-0000-4000-8000-000000007005"
  @target "00000000-0000-4000-8000-000000007006"
  @target_version "00000000-0000-4000-8000-000000007007"
  @other "00000000-0000-4000-8000-000000007008"
  @uppercase "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"

  # These unit adapters prove ordering/shape only, not live SQL, current custody,
  # persisted provenance or the real OperationScope authorization lock.
  defmodule Scope do
    import ExUnit.Assertions
    alias Singularity.Runtime.NoteSourceResolutionTest, as: Contract

    def with_read_request(_runtime, session, requirement, callback) do
      refute Contract.state(:active_scope)
      Contract.record({:scope, session, requirement})

      case Contract.state(:scope_result) do
        nil ->
          Contract.put_state(:active_scope, true)

          try do
            callback.(:scoped_repo)
          after
            Contract.put_state(:active_scope, false)
            Contract.record({:scope_finished})
          end

        result ->
          Contract.reply(result)
      end
    end

    def with_shared_request(_, _, _, _), do: raise("resolution must not open another scope")
  end

  defmodule Reader do
    import ExUnit.Assertions
    alias Singularity.Runtime.NoteSourceResolutionTest, as: Contract

    def select_attachment_in_scope(context, note, version, member),
      do: select(:attachment, context, note, version, member)

    def select_citation_in_scope(context, note, version, member),
      do: select(:citation, context, note, version, member)

    defp select(operation, context, note, version, member) do
      assert Contract.state(:active_scope)
      Contract.record({:select, operation, context, note, version, member})
      Contract.reply(Contract.state(:selected_result))
    end

    def resolve_attachment_in_scope(context, reference),
      do: resolve(:attachment, context, reference)

    def resolve_citation_in_scope(context, reference), do: resolve(:citation, context, reference)

    defp resolve(operation, context, reference) do
      assert Contract.state(:active_scope)
      assert Contract.state(:target_authorized)
      Contract.record({:resolve, operation, context, reference})
      Contract.reply(Contract.state(:resolved_result))
    end

    def read_membership(_, _, _), do: raise("resolution must select only the requested member")
    def list_set(_, _, _), do: raise("resolution must not hydrate a whole source set")
  end

  defmodule Authorizer do
    import ExUnit.Assertions
    alias Singularity.Runtime.NoteSourceResolutionTest, as: Contract

    def check(authorization, repo, session, requirement) do
      assert Contract.state(:active_scope)
      Contract.record({:authorize, authorization, repo, session, requirement})
      result = Contract.reply(Contract.state(:authorization_result))
      Contract.put_state(:target_authorized, result == :ok)
      result
    end
  end

  setup do
    put_state(:authorization_result, :ok)
    configure(:asset)
    :ok
  end

  for kind <- [:asset, :note, :document, :citation] do
    @kind kind

    test "#{kind} selects one Core reference then checks current target authority before hydration" do
      operation = configure(@kind)
      assert {:ok, result} = resolve(operation)
      assert_exact_result(operation, result)
      assert_order_and_bindings(operation, session())
    end
  end

  for operation <- [:attachment, :citation] do
    @operation operation

    test "#{operation} validates canonical selectors and authenticated owner/principal before scope" do
      configure(@operation)

      for field <- [:note, :version, :member], invalid <- [nil, "bad", @uppercase] do
        reset_trace()
        ids = Map.put(%{note: @note, version: @version, member: @member}, field, invalid)
        assert_clean_error(resolve(@operation, session(), ids), :invalid)
        assert events() == []
      end

      for field <- [:principal_id, :vault_id], invalid <- [nil, "bad", @uppercase] do
        reset_trace()
        assert_clean_error(resolve(@operation, Map.put(session(), field, invalid)), :invalid)
        assert events() == []
      end
    end

    test "#{operation} initial containing Note denial performs no selection or target hydration" do
      configure(@operation)
      put_state(:scope_result, {:error, contaminated(:forbidden)})
      assert_clean_error(resolve(@operation), :forbidden, true)
      assert Enum.map(events(), &elem(&1, 0)) == [:scope]
    end

    test "#{operation} missing or foreign member errors are sanitized before target authorization" do
      configure(@operation)

      for code <- [:not_found, :forbidden, :storage_unavailable] do
        reset_trace()
        put_state(:selected_result, {:error, contaminated(code)})
        assert_clean_error(resolve(@operation), code, true)
        assert Enum.map(events(), &elem(&1, 0)) == [:scope, :select, :scope_finished]
      end
    end

    test "#{operation} malformed selector replies fail closed before target authorization" do
      configure(@operation)

      for reply <- [
            nil,
            :ok,
            {:ok, %{}},
            {:error, :not_found},
            {:error, %{Error.new(:not_found) | code: :unknown}},
            {:error, %{Error.new(:not_found) | retryable?: :yes}}
          ] do
        reset_trace()
        put_state(:selected_result, reply)
        assert_integrity(resolve(@operation))
        refute_event(:authorize)
        refute_event(:resolve)
      end
    end

    test "#{operation} rejects forged, private, mismatched and noncanonical selected references" do
      configure(@operation)
      {:ok, reference} = state(:selected_result)

      malformed =
        [
          nil,
          :ok,
          Map.from_struct(reference),
          Map.put(reference, :owner_scope_id, @owner),
          Map.put(reference, :source_metadata, %{title: "PRIVATE_SOURCE_TITLE"}),
          Map.put(reference, :retained?, true),
          wrong_member(reference),
          opposite_reference(reference)
        ] ++
          noncanonical_references(reference)

      for invalid <- malformed do
        reset_trace()
        put_state(:selected_result, {:ok, invalid})
        assert_integrity(resolve(@operation))
        refute_event(:authorize)
        refute_event(:resolve)
      end
    end

    test "#{operation} binds both current epochs and uses legacy principal epoch only as fallback" do
      configure(@operation)
      fallback = %{session() | principal_authorization_epoch: nil}
      assert {:ok, result} = resolve(@operation, fallback)
      assert_exact_result(@operation, result)
      assert_order_and_bindings(@operation, fallback)
    end

    test "#{operation} target denial and stale authority cannot hydrate retained or deleted evidence" do
      configure(@operation)
      {:ok, resolved} = state(:resolved_result)
      put_state(:resolved_result, {:ok, put_in(resolved.source.deleted?, true)})

      for code <- [:forbidden, :unauthenticated, :vault_locked] do
        reset_trace()
        put_state(:authorization_result, {:error, contaminated(code)})
        assert_clean_error(resolve(@operation), code, true)
        assert Enum.map(events(), &elem(&1, 0)) == [:scope, :select, :authorize, :scope_finished]
        refute_event(:resolve)
      end

      for changed <- [%{principal_authorization_epoch: -1}, %{vault_authorization_epoch: -1}] do
        reset_trace()
        put_state(:authorization_result, {:error, Error.new(:forbidden)})
        assert_clean_error(resolve(@operation, Map.merge(session(), changed)), :forbidden)
        refute_event(:resolve)
      end
    end

    test "#{operation} malformed authorizer replies fail closed without hydration" do
      configure(@operation)

      for reply <- [
            nil,
            true,
            {:ok, true},
            {:error, :forbidden},
            {:error, %{Error.new(:forbidden) | code: :unknown}},
            {:error, %{Error.new(:forbidden) | retryable?: :yes}},
            {:error, {:authorization_denial, Error.new(:forbidden)}}
          ] do
        reset_trace()
        put_state(:authorization_result, reply)
        assert_integrity(resolve(@operation))
        refute_event(:resolve)
      end
    end

    test "#{operation} historical tombstone and restore preserve the selected immutable pins" do
      configure(@operation)
      {:ok, resolved} = state(:resolved_result)

      for deleted? <- [true, false] do
        reset_trace()
        expected = put_in(resolved.source.deleted?, deleted?)
        put_state(:resolved_result, {:ok, expected})
        assert {:ok, result} = resolve(@operation)
        assert result.source == expected.source
        assert result.source.resource_version_id == @target_version
        assert_exact_result(@operation, result)
        assert_order_and_bindings(@operation, session())
      end
    end

    test "#{operation} rejects unknown outer source and fragment fields instead of dropping them" do
      configure(@operation)
      {:ok, resolved} = state(:resolved_result)

      for field <- [
            :owner_scope_id,
            :vault_id,
            :classification,
            :head_version_id,
            :markdown,
            :bytes,
            :storage_ref,
            :digest,
            :fragments
          ] do
        reset_trace()
        put_state(:resolved_result, {:ok, Map.put(resolved, field, "PRIVATE_CONTENT")})
        assert_integrity(resolve(@operation))
        reset_trace()

        put_state(
          :resolved_result,
          {:ok, %{resolved | source: Map.put(resolved.source, field, "PRIVATE_CONTENT")}}
        )

        assert_integrity(resolve(@operation))
      end

      for field <- Map.keys(resolved) do
        reset_trace()
        put_state(:resolved_result, {:ok, Map.delete(resolved, field)})
        assert_integrity(resolve(@operation))
      end
    end

    test "#{operation} requires exact canonical source kind pins and boolean deleted status" do
      configure(@operation)
      {:ok, resolved} = state(:resolved_result)

      for changed <- [
            %{kind: "asset"},
            %{kind: :unknown},
            %{kind: :note},
            %{resource_id: @other},
            %{resource_version_id: @other},
            %{resource_id: @uppercase},
            %{resource_version_id: "bad"},
            %{deleted?: nil},
            %{deleted?: "false"}
          ] do
        reset_trace()

        put_state(
          :resolved_result,
          {:ok, %{resolved | source: Map.merge(resolved.source, changed)}}
        )

        assert_integrity(resolve(@operation))
      end

      for field <- Map.keys(resolved.source) do
        reset_trace()

        put_state(
          :resolved_result,
          {:ok, %{resolved | source: Map.delete(resolved.source, field)}}
        )

        assert_integrity(resolve(@operation))
      end
    end

    test "#{operation} preserves valid UTF-8 titles and rejects blank malformed or NUL titles" do
      configure(@operation)
      {:ok, resolved} = state(:resolved_result)
      title = if @operation == :attachment, do: String.duplicate("文", 300) <> ".txt", else: "历史文档"
      put_state(:resolved_result, {:ok, put_in(resolved.source.title, title)})
      assert {:ok, result} = resolve(@operation)
      assert result.source.title == title

      for title <- [nil, "", " \t\n", <<255>>, "name" <> <<0>> <> ".txt"] do
        reset_trace()
        put_state(:resolved_result, {:ok, put_in(resolved.source.title, title)})
        assert_integrity(resolve(@operation))
      end
    end

    test "#{operation} must return the unchanged selected reference without private additions" do
      configure(@operation)
      {:ok, resolved} = state(:resolved_result)

      for reference <-
            [
              wrong_member(resolved.reference),
              changed_pin(resolved.reference),
              Map.from_struct(resolved.reference),
              Map.put(resolved.reference, :owner_scope_id, @owner)
            ] ++
              noncanonical_references(resolved.reference) do
        reset_trace()
        put_state(:resolved_result, {:ok, %{resolved | reference: reference}})
        assert_integrity(resolve(@operation))
      end
    end

    test "#{operation} resolver errors preserve known codes and strip content and details" do
      configure(@operation)

      for code <- [:not_found, :forbidden, :storage_unavailable] do
        reset_trace()
        put_state(:resolved_result, {:error, contaminated(code)})
        assert_clean_error(resolve(@operation), code, true)
      end

      for reply <- [
            nil,
            :ok,
            {:ok, nil},
            {:error, :not_found},
            {:error, %{Error.new(:not_found) | code: :unknown}},
            {:error, %{Error.new(:not_found) | retryable?: :yes}}
          ] do
        reset_trace()
        put_state(:resolved_result, reply)
        assert_integrity(resolve(@operation))
      end
    end

    test "#{operation} thrown adapter failures return sanitized unavailable errors" do
      for stage <- [:scope_result, :selected_result, :authorization_result, :resolved_result],
          failure <- [:raise, :throw, :exit] do
        configure(@operation)
        put_state(:scope_result, nil)
        put_state(:authorization_result, :ok)
        put_state(stage, {failure, "PRIVATE_ADAPTER_CONTENT"})
        assert_clean_error(resolve(@operation), :storage_unavailable, true)
      end
    end
  end

  test "citation rebuilds one canonical fragment identity and preserves only its exact locator" do
    configure(:citation)
    {:ok, result} = resolve(:citation)
    {:ok, expected} = state(:resolved_result)
    assert result.fragment == expected.fragment
    assert result.fragment.fragment_id == state(:fragment).fragment_id
    assert result.fragment.locator == state(:fragment).locator
    assert Map.keys(result.fragment) |> Enum.sort() == [:fragment_id, :locator, :ordinal, :text]
    assert_order_and_bindings(:citation, session())
  end

  test "citation rejects altered text digest identity ordinal locator and fragment private fields" do
    configure(:citation)
    {:ok, resolved} = state(:resolved_result)
    fragment = resolved.fragment
    {:ok, another_locator} = SourceLocator.new(%{version: 1, kind: "fragment", ordinal: 3})

    for changed <- [
          %{text: "Different immutable text"},
          %{text: "bad\rline"},
          %{text: <<255>>},
          %{text: ""},
          %{text: " "},
          %{text: "nul" <> <<0>>},
          %{fragment_id: String.duplicate("a", 64)},
          %{fragment_id: String.duplicate("A", 64)},
          %{ordinal: 3},
          %{ordinal: -1},
          %{ordinal: "2"},
          %{locator: another_locator},
          %{locator: SourceLocator.to_map(fragment.locator)},
          %{locator: Map.put(fragment.locator, :owner_scope_id, @owner)},
          %{digest: :binary.copy(<<0>>, 32)},
          %{owner_scope_id: @owner},
          %{resource_id: @target},
          %{resource_version_id: @target_version},
          %{classification: :private},
          %{fragments: [fragment]},
          %{markdown: "PRIVATE_BODY"}
        ] do
      reset_trace()
      put_state(:resolved_result, {:ok, %{resolved | fragment: Map.merge(fragment, changed)}})
      assert_integrity(resolve(:citation))
    end

    for field <- Map.keys(fragment) do
      reset_trace()
      put_state(:resolved_result, {:ok, %{resolved | fragment: Map.delete(fragment, field)}})
      assert_integrity(resolve(:citation))
    end
  end

  test "citation accepts a canonical 65536-byte selected fragment but rejects 65537 bytes" do
    configure(:citation, String.duplicate("x", 65_536))
    assert {:ok, result} = resolve(:citation)
    assert byte_size(result.fragment.text) == 65_536
    assert_exact_result(:citation, result)

    {:ok, resolved} = state(:resolved_result)
    text = String.duplicate("x", 65_537)
    digest = :crypto.hash(:sha256, text)
    fragment_id = DocumentFragment.id(@target_version, resolved.fragment.locator, 2, digest)
    {:ok, selected} = state(:selected_result)
    selected = %{selected | fragment_id: fragment_id}

    oversized = %{
      resolved
      | reference: selected,
        fragment: %{resolved.fragment | fragment_id: fragment_id, text: text}
    }

    reset_trace()
    put_state(:selected_result, {:ok, selected})
    put_state(:resolved_result, {:ok, oversized})
    assert_integrity(resolve(:citation))
  end

  # Public only for the local adapters; all state is isolated in the test process.
  def state(key), do: Process.get({__MODULE__, key})
  def put_state(key, value), do: Process.put({__MODULE__, key}, value)
  def record(event), do: put_state(:events, [event | state(:events)])
  def reply({:raise, content}), do: raise(content)
  def reply({:throw, content}), do: throw(content)
  def reply({:exit, content}), do: exit(content)
  def reply(result), do: result

  defp reset_trace do
    put_state(:events, [])
    put_state(:active_scope, false)
    put_state(:target_authorized, false)
  end

  defp events, do: state(:events) |> Enum.reverse()
  defp refute_event(kind), do: refute(Enum.any?(events(), &(elem(&1, 0) == kind)))

  defp configure(kind, text \\ "Selected immutable fragment") do
    reset_trace()
    operation = if kind == :citation, do: :citation, else: :attachment

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
            target_kind: if(kind == :attachment, do: :asset, else: kind),
            role: :source,
            label: "Pinned evidence"
          })

        {reference, nil}
      end

    source_kind = if operation == :citation, do: :document, else: reference.target_kind

    source = %{
      kind: source_kind,
      resource_id: @target,
      resource_version_id: @target_version,
      title: "Pinned source title",
      deleted?: false
    }

    resolved = %{reference: reference, source: source}

    resolved =
      if operation == :citation, do: Map.put(resolved, :fragment, fragment), else: resolved

    put_state(:selected_result, {:ok, reference})
    put_state(:resolved_result, {:ok, resolved})
    put_state(:fragment, fragment)
    operation
  end

  defp runtime do
    %{
      operation_scope: Scope,
      knowledge_link_repository: Reader,
      authorizer: Authorizer,
      authorization: %{unit_authorization: :dependency}
    }
  end

  defp session do
    %SessionContext{
      session_id: @principal,
      principal_id: @principal,
      vault_id: @owner,
      expires_at: ~U[2026-12-31 00:00:00.000000Z],
      principal_authorization_epoch: 7,
      vault_authorization_epoch: 11,
      authorization_epoch: 3,
      unlocked?: true
    }
  end

  defp resolve(
         operation,
         session \\ session(),
         ids \\ %{note: @note, version: @version, member: @member}
       ),
       do: apply(@resolver, operation, [runtime(), session, ids.note, ids.version, ids.member])

  defp assert_order_and_bindings(operation, session) do
    assert [
             {:scope, ^session, initial},
             {:select, ^operation, context, @note, @version, @member},
             {:authorize, authorization, :scoped_repo, ^session, requirement},
             {:resolve, ^operation, resolved_context, reference},
             {:scope_finished}
           ] = events()

    assert initial == %{
             vault_id: @owner,
             required_capability: "note.read",
             classification: :private,
             requires_unlocked?: true
           }

    assert context == %{repo: :scoped_repo, principal_id: @principal, owner_scope_id: @owner}
    assert resolved_context == context
    assert authorization == runtime().authorization
    assert {:ok, ^reference} = state(:selected_result)

    capability =
      if operation == :attachment and reference.target_kind == :note,
        do: "note.read",
        else: "asset.read"

    assert requirement == %{
             vault_id: @owner,
             classification: :private,
             requires_unlocked?: true,
             required_capability: capability,
             principal_authorization_epoch:
               session.principal_authorization_epoch || session.authorization_epoch,
             vault_authorization_epoch: session.vault_authorization_epoch
           }
  end

  defp assert_exact_result(operation, result) do
    {:ok, expected} = state(:resolved_result)

    assert Map.keys(result) |> Enum.sort() ==
             if(operation == :citation,
               do: [:fragment, :reference, :source],
               else: [:reference, :source]
             )

    dto =
      if operation == :citation,
        do: Singularity.Runtime.DTO.NoteCitation,
        else: Singularity.Runtime.DTO.NoteAttachment

    assert {:ok, reference} = apply(dto, :new, [expected.reference])
    assert result.reference == reference
    assert result.reference.__struct__ == dto
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

  defp wrong_member(%NoteAttachmentReference{} = reference),
    do: %{reference | attachment_id: @other}

  defp wrong_member(%NoteCitationReference{} = reference), do: %{reference | citation_id: @other}

  defp changed_pin(%NoteAttachmentReference{} = reference),
    do: %{reference | target_resource_version_id: @other, label: "Changed canonical label"}

  defp changed_pin(%NoteCitationReference{} = reference),
    do: %{reference | source_resource_version_id: @other}

  defp opposite_reference(%NoteAttachmentReference{}) do
    {:ok, reference} =
      NoteCitationReference.new(%{
        citation_id: @member,
        source_resource_id: @target,
        source_resource_version_id: @target_version,
        fragment_id: String.duplicate("a", 64),
        locator: %{version: 1, kind: "fragment", ordinal: 0}
      })

    reference
  end

  defp opposite_reference(%NoteCitationReference{}) do
    {:ok, reference} =
      NoteAttachmentReference.new(%{
        attachment_id: @member,
        target_resource_id: @target,
        target_resource_version_id: @target_version,
        target_kind: :asset
      })

    reference
  end

  defp noncanonical_references(%NoteAttachmentReference{} = reference),
    do: [
      %{reference | target_kind: "asset"},
      %{reference | label: "e\u0301"},
      %{reference | target_resource_id: @uppercase}
    ]

  defp noncanonical_references(%NoteCitationReference{} = reference),
    do: [
      %{reference | locator: SourceLocator.to_map(reference.locator)},
      %{reference | fragment_id: String.duplicate("A", 64)},
      %{reference | source_resource_id: @uppercase}
    ]

  defp contaminated(code),
    do: %{
      Error.new(code, retryable?: true)
      | message: "PRIVATE_SOURCE_TITLE",
        details: %{text: "PRIVATE_FRAGMENT_TEXT"}
    }

  defp assert_clean_error(result, code, retryable? \\ false),
    do: assert(result == {:error, Error.new(code, retryable?: retryable?)})

  defp assert_integrity(result), do: assert_clean_error(result, :integrity_failure)
end
