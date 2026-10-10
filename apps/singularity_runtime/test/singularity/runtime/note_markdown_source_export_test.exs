defmodule Singularity.Runtime.NoteMarkdownSourceExportTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.{DocumentFragment, Error, NoteAttachmentReference, NoteCitationReference}
  alias Singularity.Core.{NoteSnapshot, SourceLocator}
  alias Singularity.Runtime.DTO.{NoteExport, NoteValidation}
  alias Singularity.Runtime.Notes.Export
  alias Singularity.Runtime.SessionContext

  @principal "00000000-0000-4000-8000-000000008001"
  @owner "00000000-0000-4000-8000-000000008002"
  @note "00000000-0000-4000-8000-000000008003"
  @version "00000000-0000-4000-8000-000000008004"
  @time ~U[2026-10-11 12:00:00.000000Z]
  @render_limit 16_777_216

  # These adapters prove composition, shapes and ordering only. They do not
  # prove real locks, SQL provenance, current custody or original-byte delivery.
  defmodule Scope do
    alias Singularity.Runtime.NoteMarkdownSourceExportTest, as: Contract

    def with_shared_request(runtime, session, requirement, callback) do
      Contract.record({:scope, runtime, session, requirement})

      case Contract.state(:scope_reply) do
        nil ->
          Contract.put_state(:active, true)

          try do
            callback.(:export_repo)
          after
            Contract.put_state(:active, false)
            Contract.record({:scope_finished})
          end

        reply ->
          Contract.reply(reply)
      end
    end

    def with_read_request(_, _, _, _), do: raise("export must keep its original shared scope")
  end

  defmodule Repository do
    import ExUnit.Assertions
    alias Singularity.Runtime.NoteMarkdownSourceExportTest, as: Contract

    def get(repo, owner, resource) do
      assert Contract.state(:active)
      Contract.record({:get, repo, owner, resource})
      Contract.reply(Contract.state(:note_reply))
    end
  end

  defmodule Reader do
    import ExUnit.Assertions
    alias Singularity.Runtime.NoteMarkdownSourceExportTest, as: Contract

    def read_membership(context, resource, version) do
      assert Contract.state(:active)
      Contract.record({:membership, context, resource, version})
      Contract.reply(Contract.state(:membership_reply))
    end

    def select_attachment_in_scope(context, resource, version, member),
      do: select(:attachment, context, resource, version, member)

    def select_citation_in_scope(context, resource, version, member),
      do: select(:citation, context, resource, version, member)

    defp select(operation, context, resource, version, member) do
      assert Contract.state(:active)
      Contract.assert_all_source_checks()
      Contract.record({:select, operation, context, resource, version, member})

      case Contract.state(:selected_reply) do
        nil -> {:ok, Contract.reference(operation, member)}
        reply -> Contract.reply(reply)
      end
    end

    def resolve_attachment_in_scope(context, reference),
      do: resolve(:attachment, context, reference)

    def resolve_citation_in_scope(context, reference), do: resolve(:citation, context, reference)

    defp resolve(operation, context, reference) do
      assert Contract.state(:active)
      Contract.assert_all_source_checks()
      assert Enum.count(Contract.events(), &(elem(&1, 0) == :select)) == 1
      Contract.record({:hydrate, operation, context, reference})
      index = Contract.state(:hydrate_count) + 1
      Contract.put_state(:hydrate_count, index)

      case Contract.state(:resolve_override) do
        nil -> {:ok, Contract.resolved(operation, reference)}
        override -> Contract.reply(override.(operation, reference, index))
      end
    end

    def list_set(_, _, _), do: raise("export must not use the pre-authorization whole-set reader")
  end

  defmodule Authorizer do
    import ExUnit.Assertions
    alias Singularity.Runtime.NoteMarkdownSourceExportTest, as: Contract

    def check(dependencies, repo, session, requirement) do
      assert Contract.state(:active)
      Contract.record({:authorize, dependencies, repo, session, requirement})
      capability = requirement.required_capability
      reply = Map.get(Contract.state(:authorization_replies), capability, :ok)
      reply = Contract.reply(reply)

      if reply == :ok do
        Contract.put_state(:authorized, MapSet.put(Contract.state(:authorized), capability))
      end

      reply
    end
  end

  defmodule Audit do
    import ExUnit.Assertions
    alias Singularity.Runtime.NoteMarkdownSourceExportTest, as: Contract

    def append(repo, event) do
      assert Contract.state(:active)
      Contract.record({:audit, repo, event})
      Contract.reply(Contract.state(:audit_reply))
    end
  end

  setup do
    put_state(:events, [])
    put_state(:active, false)
    put_state(:hydrate_count, 0)
    put_state(:authorized, MapSet.new())
    put_state(:authorization_replies, %{})
    put_state(:audit_reply, :ok)
    put_state(:note_reply, {:ok, row()})

    configure([attachment(30, :asset), attachment(20, :note), attachment(10, :document)], [
      citation(40)
    ])

    :ok
  end

  test "mixed sources all pass current authority before selection and every exact historical hydration" do
    assert {:ok, result} = export()
    assert result.__struct__ == NoteExport
    assert String.starts_with?(result.markdown, "PRIVATE_NOTE_BODY\n\n## Sources")
    assert result.resource_version_id == @version
    assert_original_scope()
    assert_current_checks(["asset.read", "note.read"], session())
    assert_complete_members()
    assert_id_only_audit()
    refute result.markdown =~ "PRIVATE_FRAGMENT_TEXT"
    assert result.markdown =~ "Pinned"
    assert result.markdown =~ "[^singularity-source-"
  end

  test "descending UUIDs and retained-member reorder preserve membership order without sorting" do
    {:ok, membership} = state(:membership_reply)

    for attachments <- [membership.attachments, Enum.reverse(membership.attachments)] do
      reset_trace()
      configure(attachments, membership.citations)
      assert {:ok, result} = export()
      ids = Enum.map(attachments, & &1.attachment_id)
      positions = Enum.map(ids, &position(result.markdown, &1))
      assert positions == Enum.sort(positions)
      assert_complete_members()
    end
  end

  test "citation-only membership selects its first canonical citation once" do
    configure([], [citation(49), citation(41)])
    assert {:ok, result} = export()
    assert position(result.markdown, uuid(49)) < position(result.markdown, uuid(41))
    assert_current_checks(["asset.read"], session())
    assert_complete_members()
  end

  test "Note-only attachment checks note.read but never asks for asset.read" do
    configure([attachment(20, :note)], [])
    assert {:ok, _result} = export()
    assert_current_checks(["note.read"], session())
    assert_complete_members()
  end

  test "empty membership preserves all body bytes without extra source checks selectors or hydration" do
    configure([], [])

    for body <- ["", "\uFEFF# Note\r\n", "<!-- unfinished", "```text\ncode", "a < b", "    ```"] do
      reset_trace()
      put_state(:note_reply, {:ok, row(body)})
      assert {:ok, result} = export()
      assert result.markdown === body

      assert Enum.map(events(), &elem(&1, 0)) == [
               :scope,
               :get,
               :membership,
               :audit,
               :scope_finished
             ]

      assert_id_only_audit()
    end
  end

  test "legacy principal epoch fallback remains bound to the original scoped authorizer" do
    fallback = %{session() | principal_authorization_epoch: nil}
    assert {:ok, _result} = export(fallback)
    assert_current_checks(["asset.read", "note.read"], fallback)
  end

  for capability <- ["asset.read", "note.read"] do
    @capability capability
    test "denied #{@capability} aborts all referenced hydration and success audit" do
      put_state(:authorization_replies, %{@capability => {:error, contaminated(:forbidden)}})
      assert_clean(export(), :forbidden, true)
      refute_kind(:select)
      refute_kind(:hydrate)
      refute_kind(:audit)
    end
  end

  test "malformed authorizer replies and adapter escapes fail closed before any referenced read" do
    for {reply, expected, retryable?} <- [
          {nil, :integrity_failure, false},
          {{:ok, true}, :integrity_failure, false},
          {{:error, :forbidden}, :integrity_failure, false},
          {{:error, %{Error.new(:forbidden) | code: :unknown}}, :integrity_failure, false},
          {{:error, %{Error.new(:forbidden) | retryable?: :yes}}, :integrity_failure, false},
          {{:raise, "PRIVATE_SOURCE_TITLE"}, :storage_unavailable, true},
          {{:throw, "PRIVATE_SOURCE_TITLE"}, :storage_unavailable, true},
          {{:exit, "PRIVATE_SOURCE_TITLE"}, :storage_unavailable, true}
        ] do
      reset_trace()
      put_state(:authorization_replies, %{"asset.read" => reply})
      assert_clean(export(), expected, retryable?)
      refute_kind(:select)
      refute_kind(:hydrate)
      refute_kind(:audit)
    end
  end

  test "one selected Core reference must equal the complete original canonical member" do
    {:ok, membership} = state(:membership_reply)
    reference = hd(membership.attachments)

    for invalid <- [
          nil,
          Map.from_struct(reference),
          %{reference | target_resource_version_id: uuid(999)},
          %{reference | attachment_id: uuid(998)},
          %{reference | label: "Changed label"},
          Map.put(reference, :owner_scope_id, @owner)
        ] do
      reset_trace()
      put_state(:selected_reply, {:ok, invalid})
      assert_clean(export(), :integrity_failure)
      refute_kind(:hydrate)
      refute_kind(:audit)
    end
  end

  for stage <- [:note, :membership, :selected] do
    @stage stage
    test "#{stage} faults are sanitized and never append a success audit" do
      for code <- [:not_found, :forbidden, :storage_unavailable] do
        reset_trace()

        put_state(
          (Atom.to_string(@stage) <> "_reply") |> String.to_atom(),
          {:error, contaminated(code)}
        )

        assert_clean(export(), code, true)
        refute_kind(:hydrate)
        refute_kind(:audit)
      end
    end
  end

  test "a later source failure prevents partial export and audit rather than omitting the member" do
    put_state(:resolve_override, fn operation, reference, index ->
      if index == 2,
        do: {:error, contaminated(:not_found)},
        else: {:ok, resolved(operation, reference)}
    end)

    assert_clean(export(), :not_found, true)
    assert Enum.count(events(), &(elem(&1, 0) == :hydrate)) == 2
    refute_kind(:audit)
  end

  test "resolved attachment metadata and references reject every private extra and mismatched pin" do
    for mutate <- [
          &Map.put(&1, :body, "PRIVATE_SOURCE_BODY"),
          &Map.put(&1, :owner_scope_id, @owner),
          &put_in(&1.source.resource_version_id, uuid(999)),
          &put_in(&1.source.kind, :note),
          &put_in(&1.source.deleted?, :yes),
          &put_in(&1.source.title, ""),
          &put_in(&1.source.title, "title\0"),
          &put_in(&1.reference.label, "Unexpected canonical label")
        ] do
      reset_trace()

      put_state(:resolve_override, fn operation, reference, _index ->
        {:ok, mutate.(resolved(operation, reference))}
      end)

      assert_clean(export(), :integrity_failure)
      refute_kind(:audit)
    end
  end

  test "citation fragment content identity locator and closed shape stay enforced internally" do
    configure([], [citation(40)])

    for mutate <- [
          &put_in(&1.fragment.text, "Forged fragment text"),
          &put_in(&1.fragment.ordinal, 99),
          &put_in(&1.fragment.fragment_id, String.duplicate("a", 64)),
          &put_in(&1.fragment.locator.fields.ordinal, 99),
          &Map.update!(&1, :fragment, fn fragment ->
            Map.put(fragment, :owner_scope_id, @owner)
          end)
        ] do
      reset_trace()

      put_state(:resolve_override, fn operation, reference, _index ->
        {:ok, mutate.(resolved(operation, reference))}
      end)

      assert_clean(export(), :integrity_failure)
      refute_kind(:audit)
    end
  end

  test "target tombstones retain exact historical title and pins without fragment body export" do
    put_state(:resolve_override, fn operation, reference, _index ->
      {:ok, put_in(resolved(operation, reference).source.deleted?, true)}
    end)

    assert {:ok, result} = export()
    assert result.markdown =~ "historical"
    assert_complete_members()
    refute result.markdown =~ "PRIVATE_FRAGMENT_TEXT"
  end

  test "duplicate attachment natural keys fail before source authority or hydration" do
    first = attachment(30, :asset)
    second = %{first | attachment_id: uuid(31), label: "Different label"}
    configure([first, second], [])
    assert_clean(export(), :integrity_failure)
    refute_kind(:authorize)
    refute_kind(:select)
    refute_kind(:hydrate)
    refute_kind(:audit)
  end

  test "source title Markdown HTML and controls are escaped rather than injected" do
    configure([attachment(30, :asset)], [])

    put_state(:resolve_override, fn operation, reference, _index ->
      {:ok,
       put_in(
         resolved(operation, reference).source.title,
         "来源[evil](javascript:alert) <script>\n\t&"
       )}
    end)

    assert {:ok, result} = export()
    assert result.markdown =~ "来源"
    refute result.markdown =~ "[evil](javascript:alert)"
    refute result.markdown =~ "<script>"
    refute result.markdown =~ "<script>\n\t"
    assert result.markdown =~ "sources/asset-"
    assert_id_only_audit()
  end

  test "legal one MiB canonical body can grow under the distinct rendered ceiling" do
    body = String.duplicate("b", 1_048_576)
    put_state(:note_reply, {:ok, row(body)})
    assert {:ok, result} = export()
    assert String.starts_with?(result.markdown, body)
    assert byte_size(result.markdown) > byte_size(body)
    assert byte_size(result.markdown) < @render_limit
    assert {:ok, _export} = NoteExport.new(Map.from_struct(result))
  end

  test "only rendered NoteExport gains a 16 MiB ceiling; canonical writes retain one MiB" do
    body = String.duplicate("b", @render_limit)
    assert {:ok, _export} = NoteExport.new(export_attrs(body))
    assert NoteExport.new(export_attrs(body <> "b")) == {:error, Error.new(:integrity_failure)}
    assert NoteExport.new(export_attrs(<<255>>)) == {:error, Error.new(:integrity_failure)}
    assert NoteExport.new(export_attrs("bad\0")) == {:error, Error.new(:integrity_failure)}

    canonical_overflow = String.duplicate("b", 1_048_577)
    refute NoteValidation.markdown?(canonical_overflow)

    assert NoteSnapshot.initial(%{
             classification: :private,
             title: "Note",
             markdown: canonical_overflow
           }) ==
             {:error, Error.new(:invalid)}
  end

  test "raw title aggregate overflow prevents retaining later metadata and never audits" do
    configure([attachment(30, :asset), attachment(20, :asset), attachment(10, :asset)], [])
    title = String.duplicate("t", div(@render_limit, 2) + 1)

    put_state(:resolve_override, fn operation, reference, _index ->
      {:ok, put_in(resolved(operation, reference).source.title, title)}
    end)

    assert_clean(export(), :integrity_failure)
    assert Enum.count(events(), &(elem(&1, 0) == :hydrate)) == 2
    refute_kind(:audit)
  end

  test "escape expansion overflow fails before success audit without truncating metadata" do
    configure([attachment(30, :asset)], [])
    title = String.duplicate("<", div(@render_limit, 2))

    put_state(:resolve_override, fn operation, reference, _index ->
      {:ok, put_in(resolved(operation, reference).source.title, title)}
    end)

    assert_clean(export(), :integrity_failure)
    refute_kind(:audit)
  end

  test "ambiguous raw HTML and container syntax aborts nonempty export without success audit" do
    for body <- [
          "<!-- open",
          "<script>open",
          "<?processing",
          "<![CDATA[open",
          "<https://example.com>",
          "> ```",
          "\uFEFF```text",
          "a < b"
        ] do
      reset_trace()
      put_state(:note_reply, {:ok, row(body)})
      assert_clean(export(), :integrity_failure)
      refute_kind(:audit)
    end
  end

  test "proven open top-level fences gain one closing line while retaining original bytes" do
    for {body, boundary} <- [{"```text\ncode", "\n```"}, {"~~~text\r\ncode\r\n", "~~~"}] do
      reset_trace()
      put_state(:note_reply, {:ok, row(body)})
      assert {:ok, result} = export()
      assert String.starts_with?(result.markdown, body <> boundary <> "\n\n## Sources")
      assert_id_only_audit()
    end
  end

  test "success audit failures remain sanitized and do not return a partial rendered DTO" do
    put_state(:audit_reply, {:error, contaminated(:storage_unavailable)})
    assert_clean(export(), :storage_unavailable, true)
    assert_complete_members()
    assert Enum.count(events(), &(elem(&1, 0) == :audit)) == 1
  end

  def state(key), do: Process.get({__MODULE__, key})
  def put_state(key, value), do: Process.put({__MODULE__, key}, value)
  def record(event), do: put_state(:events, [event | state(:events)])
  def events, do: Enum.reverse(state(:events))
  def reply({:raise, value}), do: raise(ArgumentError, value)
  def reply({:throw, value}), do: throw(value)
  def reply({:exit, value}), do: exit(value)
  def reply(value), do: value

  def reference(:attachment, member) do
    {:ok, membership} = state(:membership_reply)
    Enum.find(membership.attachments, &(&1.attachment_id == member))
  end

  def reference(:citation, member) do
    {:ok, membership} = state(:membership_reply)
    Enum.find(membership.citations, &(&1.citation_id == member))
  end

  def resolved(:attachment, reference) do
    %{
      reference: reference,
      source:
        source(
          reference.target_kind,
          reference.target_resource_id,
          reference.target_resource_version_id
        )
    }
  end

  def resolved(:citation, reference) do
    fragment = state({:fragment, reference.citation_id})

    %{
      reference: reference,
      source:
        source(:document, reference.source_resource_id, reference.source_resource_version_id),
      fragment: Map.take(fragment, [:fragment_id, :ordinal, :text, :locator])
    }
  end

  def assert_all_source_checks do
    for capability <- required_capabilities() do
      assert MapSet.member?(state(:authorized), capability)
    end
  end

  defp required_capabilities do
    {:ok, membership} = state(:membership_reply)

    (Enum.map(membership.attachments, fn reference ->
       if reference.target_kind == :note, do: "note.read", else: "asset.read"
     end) ++ if(membership.citations == [], do: [], else: ["asset.read"]))
    |> Enum.uniq()
  end

  defp assert_current_checks(capabilities, bound_session) do
    checks =
      for {:authorize, dependencies, repo, session, required} <- events(),
          do: {dependencies, repo, session, required}

    assert Enum.map(checks, fn {_, _, _, required} -> required.required_capability end) ==
             capabilities

    for {dependencies, repo, authorized_session, required} <- checks do
      assert dependencies === runtime().authorization
      assert repo === :export_repo
      assert authorized_session === bound_session

      assert required === %{
               vault_id: @owner,
               classification: :private,
               requires_unlocked?: true,
               required_capability: required.required_capability,
               principal_authorization_epoch:
                 bound_session.principal_authorization_epoch || bound_session.authorization_epoch,
               vault_authorization_epoch: bound_session.vault_authorization_epoch
             }
    end

    last_check =
      events()
      |> Enum.with_index()
      |> Enum.filter(fn {event, _} -> elem(event, 0) == :authorize end)
      |> List.last()
      |> elem(1)

    assert last_check < Enum.find_index(events(), &(elem(&1, 0) == :select))
    assert last_check < Enum.find_index(events(), &(elem(&1, 0) == :hydrate))
  end

  defp assert_original_scope do
    assert [{:scope, original_runtime, bound_session, required}] =
             for({:scope, _, _, _} = event <- events(), do: event)

    assert original_runtime === runtime()
    assert bound_session === session()

    assert required === %{
             vault_id: @owner,
             classification: :private,
             requires_unlocked?: true,
             required_capabilities: ["note.export", "note.read"]
           }
  end

  defp assert_complete_members do
    {:ok, membership} = state(:membership_reply)

    expected =
      Enum.map(membership.attachments, &{:attachment, &1}) ++
        Enum.map(membership.citations, &{:citation, &1})

    assert [{:select, operation, context, @note, @version, member}] =
             for({:select, _, _, _, _, _} = event <- events(), do: event)

    {first_operation, first} = hd(expected)
    assert operation == first_operation
    assert member == member_id(first)
    assert context === %{repo: :export_repo, principal_id: @principal, owner_scope_id: @owner}

    hydrated =
      for {:hydrate, operation, ^context, reference} <- events(), do: {operation, reference}

    assert hydrated === expected
    assert Enum.count(events(), &(elem(&1, 0) == :hydrate)) == length(expected)
  end

  defp assert_id_only_audit do
    assert [{:audit, :export_repo, audit}] = for({:audit, _, _} = event <- events(), do: event)
    assert audit.action == "note.export"
    assert audit.result == :completed
    assert audit.target_id == @note
    assert audit.metadata === %{"resource_version_id" => @version}
    refute inspect(audit) =~ "PRIVATE_NOTE_BODY"
    refute inspect(audit) =~ "PRIVATE_FRAGMENT_TEXT"
    refute inspect(audit) =~ "Pinned"
  end

  defp assert_clean(result, code, retryable? \\ false),
    do: assert(result === {:error, Error.new(code, retryable?: retryable?)})

  defp refute_kind(kind), do: refute(Enum.any?(events(), &(elem(&1, 0) == kind)))
  defp position(binary, term), do: :binary.match(binary, term) |> elem(0)

  defp reset_trace do
    put_state(:events, [])
    put_state(:hydrate_count, 0)
    put_state(:authorized, MapSet.new())
    put_state(:active, false)
  end

  defp configure(attachments, citations),
    do:
      put_state(
        :membership_reply,
        {:ok, %{revision: 2, attachments: attachments, citations: citations}}
      )

  defp source(kind, resource, version),
    do: %{
      kind: kind,
      resource_id: resource,
      resource_version_id: version,
      title: "Pinned #{kind} source",
      deleted?: false
    }

  defp attachment(number, kind) do
    {:ok, reference} =
      NoteAttachmentReference.new(%{
        attachment_id: uuid(number),
        target_resource_id: uuid(number + 100),
        target_resource_version_id: uuid(number + 200),
        target_kind: kind,
        role: :source,
        label: "Pinned label"
      })

    reference
  end

  defp citation(number) do
    {:ok, locator} = SourceLocator.new(%{version: 1, kind: "fragment", ordinal: number})

    {:ok, fragment} =
      DocumentFragment.new(%{
        resource_id: uuid(number + 100),
        resource_version_id: uuid(number + 200),
        owner_scope_id: @owner,
        classification: :private,
        ordinal: number,
        text: "PRIVATE_FRAGMENT_TEXT",
        locator: locator
      })

    {:ok, reference} =
      NoteCitationReference.new(%{
        citation_id: uuid(number),
        source_resource_id: fragment.resource_id,
        source_resource_version_id: fragment.resource_version_id,
        fragment_id: fragment.fragment_id,
        locator: locator
      })

    put_state({:fragment, reference.citation_id}, fragment)
    reference
  end

  defp row(body \\ "PRIVATE_NOTE_BODY") do
    %{
      resource_id: @note,
      resource_version_id: @version,
      vault_id: @owner,
      classification: :private,
      title: "Export Note",
      markdown: body,
      revision: 2,
      updated_at: @time,
      deleted_at: nil,
      deleted?: false,
      created_by_principal_id: @principal,
      inserted_at: @time,
      parent_version_id: nil,
      merge_parent_version_id: nil,
      canonical?: true,
      open_conflict_count: 0
    }
  end

  defp export_attrs(body),
    do: %{
      resource_id: @note,
      resource_version_id: @version,
      filename: "note.md",
      media_type: "text/markdown; charset=utf-8",
      markdown: body
    }

  defp contaminated(code),
    do: %{
      Error.new(code, retryable?: true)
      | message: "PRIVATE_SOURCE_TITLE",
        details: %{body: "PRIVATE_FRAGMENT_TEXT"}
    }

  defp uuid(number),
    do: "00000000-0000-4000-8000-" <> String.pad_leading(Integer.to_string(number), 12, "0")

  defp session do
    %SessionContext{
      session_id: @principal,
      account_id: @principal,
      principal_id: @principal,
      vault_id: @owner,
      expires_at: DateTime.add(@time, 3600, :second),
      principal_authorization_epoch: 7,
      vault_authorization_epoch: 11,
      authorization_epoch: 7,
      unlocked?: true
    }
  end

  defp runtime do
    %{
      operation_scope: Scope,
      note_repository: Repository,
      knowledge_link_repository: Reader,
      authorizer: Authorizer,
      authorization: %{export_authorization: :original},
      audit: Audit
    }
  end

  defp export(bound_session \\ session()), do: Export.run(runtime(), bound_session, @note)
  defp member_id(%NoteAttachmentReference{attachment_id: id}), do: id
  defp member_id(%NoteCitationReference{citation_id: id}), do: id
end
