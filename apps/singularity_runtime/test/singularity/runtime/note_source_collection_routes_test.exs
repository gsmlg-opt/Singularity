defmodule Singularity.Runtime.NoteSourceCollectionRoutesTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.{
    DocumentFragment,
    Error,
    NoteAttachmentReference,
    NoteCitationReference
  }

  alias Singularity.Core.NoteSaveResult, as: ReferenceResult
  alias Singularity.Runtime.Notes.{Create, Export, Get, Merge, Restore, Save}
  alias Singularity.Runtime.Notes.DTO, as: NotesDTO
  alias Singularity.Runtime.SessionContext

  @principal "00000000-0000-4000-8000-000000006001"
  @owner "00000000-0000-4000-8000-000000006002"
  @note "00000000-0000-4000-8000-000000006003"
  @version "00000000-0000-4000-8000-000000006004"
  @pinned "00000000-0000-4000-8000-000000006005"
  @competing "00000000-0000-4000-8000-000000006006"
  @later "00000000-0000-4000-8000-000000006007"
  @conflict "00000000-0000-4000-8000-000000006008"
  @mutation "00000000-0000-4000-8000-000000006009"
  @time ~U[2026-10-11 08:00:00.000000Z]
  @routes [:get, :version, :conflict, :create, :save, :merge, :restore, :export]

  # Unit-only adapters observe route composition and call order. They do not
  # establish canonical SQL membership, GUC enforcement, source proof or custody.
  defmodule Scope do
    alias Singularity.Runtime.NoteSourceCollectionRoutesTest, as: Contract

    def with_read_request(_runtime, session, requirement, callback),
      do: enter(:read, session, requirement, callback)

    def with_shared_request(_runtime, session, requirement, callback),
      do: enter(:shared, session, requirement, callback)

    defp enter(kind, session, requirement, callback) do
      Contract.record({:scope, kind, session, requirement})

      case Contract.state(:scope_result) do
        nil -> callback.(:scoped_repo)
        result -> result
      end
    end
  end

  defmodule Repository do
    import ExUnit.Assertions
    alias Singularity.Runtime.NoteSourceCollectionRoutesTest, as: Contract

    def get(repo, owner, note) do
      Contract.record({:note_read, :get, repo, owner, note})
      Contract.state(:current_result)
    end

    def get_version(repo, owner, note, version) do
      Contract.record({:note_read, :version, repo, owner, note, version})
      Contract.state(:version_result)
    end

    def get_conflict(repo, owner, note, conflict) do
      Contract.record({:note_read, :conflict, repo, owner, note, conflict})
      Contract.state(:conflict_result)
    end

    def tombstone(_, _), do: raise("unit collection route must not tombstone a Note")

    for operation <- [:create, :save, :merge, :restore] do
      def unquote(operation)(context, intent) do
        if unquote(operation) == :restore do
          assert context == :scoped_repo
        else
          assert %{repo: :scoped_repo, authorize_new_sources: callback} = context
          assert is_function(callback, 2)
          assert Enum.sort(Map.keys(context)) == [:authorize_new_sources, :repo]
        end

        Contract.record({:note_write, unquote(operation), context, intent})
        Contract.state({:write_result, unquote(operation)})
      end
    end
  end

  defmodule Reader do
    import ExUnit.Assertions
    alias Singularity.Runtime.NoteSourceCollectionRoutesTest, as: Contract

    def read_membership(context, note, version) do
      Contract.record({:membership, context, note, version})
      Contract.put_state(:membership_completed, true)
      Map.fetch!(Contract.state(:membership_results), version)
    end

    # Only export may hydrate, and only after fresh source authorization. The
    # other routes still fail deterministically on any accidental target read.
    def list_set(_, _, _), do: raise("unit route must not hydrate a whole source set")

    for kind <- [:attachment, :citation] do
      selector = String.to_atom("select_#{kind}_in_scope")
      resolver = String.to_atom("resolve_#{kind}_in_scope")

      def unquote(selector)(context, note, version, id) do
        require_export(context)
        assert Contract.state(:source_selected) != true
        Contract.put_state(:source_selected, true)
        Contract.record({:source_selection, unquote(kind), id, context})
        {:ok, Contract.member(unquote(kind), note, version, id)}
      end

      def unquote(resolver)(context, reference) do
        require_export(context)
        assert Contract.state(:source_selected) == true
        Contract.record({:source_hydration, unquote(kind), reference, context})
        {:ok, Contract.resolution(unquote(kind), reference)}
      end
    end

    defp require_export(context) do
      assert Contract.state(:exporting) == true
      assert Contract.state(:source_authorized) == true
      assert context == Contract.source_context()
    end
  end

  defmodule Authorizer do
    import ExUnit.Assertions
    alias Singularity.Runtime.NoteSourceCollectionRoutesTest, as: Contract

    def check(:original_dependencies, :scoped_repo, session, requirement) do
      assert Contract.state(:exporting) == true
      assert Contract.state(:membership_completed) == true

      assert requirement == %{
               vault_id: session.vault_id,
               classification: :private,
               requires_unlocked?: true,
               required_capability: "asset.read",
               principal_authorization_epoch: session.principal_authorization_epoch,
               vault_authorization_epoch: session.vault_authorization_epoch
             }

      Contract.put_state(:source_authorized, true)
      Contract.record({:source_authorize, :scoped_repo, requirement.required_capability})
      :ok
    end
  end

  defmodule Fingerprint do
    alias Singularity.Runtime.NoteSourceCollectionRoutesTest, as: Contract

    def compute(_secret, command) do
      Contract.record({:fingerprint, command})
      {:ok, :binary.copy(<<0xB6>>, 32)}
    end
  end

  defmodule Audit do
    import ExUnit.Assertions
    alias Singularity.Runtime.NoteSourceCollectionRoutesTest, as: Contract

    def append(repo, event) do
      assert Contract.state(:membership_completed) == true
      Contract.record({:audit, repo, event})
      :ok
    end
  end

  setup do
    put_state(:events, [])
    put_state(:current_result, {:ok, canonical_row()})
    put_state(:version_result, {:ok, version_row(@pinned, 0, false, nil)})

    put_state(:conflict_result, {
      :ok,
      %{
        conflict: conflict_row(),
        current: version_row(@version, 2, true, nil),
        competing: version_row(@competing, 1, false, :open)
      }
    })

    put_state(:membership_results, %{
      @version => {:ok, membership(2, 20)},
      @pinned => {:ok, membership(0, 40)},
      @competing => {:ok, membership(1, 60)},
      @later => {:ok, membership(4, 80)}
    })

    for operation <- [:create, :save, :merge] do
      put_state({:write_result, operation}, {:ok, saved_reference(@version)})
    end

    put_state({:write_result, :restore}, {
      :ok,
      %{resource_id: @note, canonical_version_id: @version, state: :restored}
    })

    :ok
  end

  for route <- @routes do
    @route route

    test "#{route} composes exact returned membership with only authorized export hydration" do
      assert {:ok, result} = run_route(@route)
      assert_route_collections(@route, result)
      assert_membership_calls(route_versions(@route))
      assert_scope(@route)
      assert_primary_read(@route)

      events = events()
      first_read = Enum.find_index(events, &(elem(&1, 0) == :note_read))
      first_membership = Enum.find_index(events, &(elem(&1, 0) == :membership))
      assert is_integer(first_read) and first_read < first_membership

      if @route == :export do
        assert String.starts_with?(result.markdown, "PRIVATE_NOTE_BODY\n\n## Sources\n")
        {:ok, membership} = Map.fetch!(state(:membership_results), @version)

        positions =
          for reference <- membership.attachments do
            assert result.markdown =~ reference.target_resource_id
            assert result.markdown =~ reference.target_resource_version_id
            {position, _length} = :binary.match(result.markdown, reference.attachment_id)
            position
          end

        assert positions == Enum.sort(positions)

        for reference <- membership.citations do
          assert result.markdown =~ reference.citation_id
          assert result.markdown =~ reference.source_resource_version_id
          assert result.markdown =~ reference.fragment_id
        end

        refute result.markdown =~ "PRIVATE_FRAGMENT_TEXT"
        assert_received {:source_authorize, :scoped_repo, "asset.read"}
        refute_received {:source_authorize, _, _}
        assert_received {:source_selection, :attachment, _, _}
        refute_received {:source_selection, _, _, _}
        assert length(Enum.filter(events, &(elem(&1, 0) == :source_hydration))) == 4
        first_authorization = Enum.find_index(events, &(elem(&1, 0) == :source_authorize))
        first_selection = Enum.find_index(events, &(elem(&1, 0) == :source_selection))
        first_hydration = Enum.find_index(events, &(elem(&1, 0) == :source_hydration))
        assert first_membership < first_authorization
        assert first_authorization < first_selection and first_selection < first_hydration
        assert result.resource_version_id == @version
        assert_received {:audit, :scoped_repo, event}
        assert event.metadata == %{"resource_version_id" => @version}
        refute inspect(event) =~ "PRIVATE_NOTE_BODY"
        assert first_membership < Enum.find_index(events, &(elem(&1, 0) == :audit))
      else
        refute_received {:audit, _, _}
        refute_received {:source_authorize, _, _}
        refute_received {:source_selection, _, _, _}
        refute_received {:source_hydration, _, _, _}
      end
    end

    test "#{route} reads mandatory sealed membership even when both collections are empty" do
      put_state(
        :membership_results,
        Map.new(state(:membership_results), fn {version, {:ok, member}} ->
          {version, {:ok, %{member | attachments: [], citations: []}}}
        end)
      )

      assert {:ok, result} = run_route(@route)
      assert_route_collections(@route, result)
      assert_membership_calls(route_versions(@route))
      refute_received {:source_authorize, _, _}
      refute_received {:source_selection, _, _, _}
      refute_received {:source_hydration, _, _, _}
      if @route == :export, do: assert(result.markdown == "PRIVATE_NOTE_BODY")
    end

    test "#{route} propagates sanitized membership failures and rejects revision mismatch" do
      [first_version | _] = route_versions(@route)

      for code <- [:not_found, :forbidden, :storage_unavailable] do
        contaminated = %{
          Error.new(code, retryable?: true)
          | message: "PRIVATE_SOURCE_TITLE",
            details: %{text: "PRIVATE_FRAGMENT_TEXT"}
        }

        set_membership(first_version, {:error, contaminated})
        assert {:error, clean} = run_route(@route)
        assert clean == Error.new(code, retryable?: true)
        assert_membership_calls([first_version])
        refute_received {:audit, _, _}
      end

      set_membership(first_version, {:ok, %{revision: 99, attachments: [], citations: []}})
      assert {:error, %Error{code: :integrity_failure}} = run_route(@route)
      assert_membership_calls([first_version])
      refute_received {:audit, _, _}
    end

    test "#{route} performs no Note or membership work before primary authorization succeeds" do
      put_state(:scope_result, {:error, Error.new(:forbidden)})
      assert {:error, %Error{code: :forbidden}} = run_route(@route)
      assert_scope(@route)
      assert length(events()) == 1
      refute_received {:membership, _, _, _}
      refute_received {:audit, _, _}
    end
  end

  for route <- [:create, :save, :merge, :restore] do
    @replay_route route

    test "#{route} receipt replay composes the later reloaded head, never the stale receipt pin" do
      put_state(:current_result, {:ok, canonical_row(@later, 4)})
      assert {:ok, result} = run_route(@replay_route)
      note = canonical_result(@replay_route, result)
      assert note.resource_version_id == @later
      assert note.revision == 4
      assert_collections(note, @later)
      assert_membership_calls([@later])
      assert_received {:note_read, :get, :scoped_repo, @owner, @note}
      refute_received {:membership, _, _, @version}

      assert_replayed_submission(@replay_route, result)
    end
  end

  test "a replayed conflict hydrates current head membership but preserves competing submission ID" do
    assert {:ok, references} =
             ReferenceResult.conflict(%{
               resource_id: @note,
               canonical_version_id: @version,
               submitted_version_id: @competing,
               conflict_id: @conflict
             })

    put_state({:write_result, :save}, {:ok, references})
    put_state(:current_result, {:ok, canonical_row(@later, 4)})
    assert {:ok, result} = run_route(:save)
    assert result.outcome == :conflict
    assert result.submitted_version_id == @competing
    assert result.conflict_id == @conflict
    assert result.canonical.resource_version_id == @later
    assert_collections(result.canonical, @later)
    assert_membership_calls([@later])
  end

  for branch <- [:current, :competing] do
    @failed_branch branch

    test "conflict #{@failed_branch} membership failure prevents partial conflict detail" do
      failed_version = if @failed_branch == :current, do: @version, else: @competing
      set_membership(failed_version, {:error, Error.new(:not_found)})
      assert {:error, %Error{code: :not_found}} = run_route(:conflict)

      expected = if @failed_branch == :current, do: [@version], else: [@version, @competing]
      assert_membership_calls(expected)
      refute_received {:audit, _, _}
    end
  end

  test "failed canonical lookups do not substitute empty collections or read membership" do
    failure = {:error, Error.new(:not_found)}
    put_state(:current_result, failure)
    put_state(:version_result, failure)
    put_state(:conflict_result, failure)

    for route <- @routes do
      assert ^failure = run_route(route)
      refute_received {:membership, _, _, _}
      refute_received {:audit, _, _}
    end
  end

  test "missing or malformed membership cannot produce Note detail or exported Markdown" do
    for route <- @routes, reply <- [nil, {:ok, %{}}, {:ok, %{revision: 2, attachments: []}}] do
      [version | _] = route_versions(route)
      set_membership(version, reply)
      assert {:error, %Error{code: :integrity_failure}} = run_route(route)
      assert_membership_calls([version])
      refute_received {:audit, _, _}
    end
  end

  # Public only for the nested unit adapters; state remains in this test process.
  def state(key), do: Process.get({__MODULE__, key})
  def put_state(key, value), do: Process.put({__MODULE__, key}, value)

  def record(event) do
    put_state(:events, [event | state(:events)])
    send(self(), event)
  end

  def source_context,
    do: %{repo: :scoped_repo, principal_id: @principal, owner_scope_id: @owner}

  def member(kind, @note, version, id) do
    {:ok, membership} = Map.fetch!(state(:membership_results), version)
    field = if kind == :attachment, do: :attachments, else: :citations
    id_field = if kind == :attachment, do: :attachment_id, else: :citation_id
    Enum.find(Map.fetch!(membership, field), &(Map.fetch!(&1, id_field) == id))
  end

  def resolution(:attachment, reference) do
    %{
      reference: reference,
      source: source(:asset, reference.target_resource_id, reference.target_resource_version_id)
    }
  end

  def resolution(:citation, reference) do
    fragment =
      source_fragment(
        reference.source_resource_id,
        reference.source_resource_version_id,
        reference.locator.fields.ordinal
      )

    %{
      reference: reference,
      source:
        source(:document, reference.source_resource_id, reference.source_resource_version_id),
      fragment: Map.take(fragment, [:fragment_id, :ordinal, :text, :locator])
    }
  end

  defp source(kind, resource, version),
    do: %{
      kind: kind,
      resource_id: resource,
      resource_version_id: version,
      title: "Unit source title",
      deleted?: false
    }

  def source_fragment(resource, version, ordinal) do
    {:ok, fragment} =
      DocumentFragment.new(%{
        resource_id: resource,
        resource_version_id: version,
        owner_scope_id: @owner,
        classification: :private,
        ordinal: ordinal,
        text: "PRIVATE_FRAGMENT_TEXT",
        locator: %{version: 1, kind: "fragment", ordinal: ordinal}
      })

    fragment
  end

  defp events, do: state(:events) |> Enum.reverse()

  defp runtime do
    %{
      operation_scope: Scope,
      authorization: :original_dependencies,
      authorizer: Authorizer,
      note_repository: Repository,
      knowledge_link_repository: Reader,
      mutation_fingerprint: Fingerprint,
      fingerprint_secret: :binary.copy(<<0xA5>>, 32),
      notes: Singularity.Domains.Notes,
      audit: Audit
    }
  end

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

  defp run_route(route) do
    put_state(:exporting, route == :export)
    put_state(:source_authorized, false)
    put_state(:source_selected, false)
    do_run_route(route)
  end

  defp do_run_route(:get), do: Get.run(runtime(), session(), @note)
  defp do_run_route(:version), do: Get.version(runtime(), session(), @note, @pinned)
  defp do_run_route(:conflict), do: Get.conflict(runtime(), session(), @note, @conflict)
  defp do_run_route(:export), do: Export.run(runtime(), session(), @note)
  defp do_run_route(:create), do: Create.run(runtime(), session(), snapshot())

  defp do_run_route(:restore),
    do: Restore.run(runtime(), session(), @note, %{mutation_id: @mutation})

  defp do_run_route(:save),
    do: Save.run(runtime(), session(), @note, Map.put(snapshot(), :base_version_id, @pinned))

  defp do_run_route(:merge),
    do:
      Merge.run(
        runtime(),
        session(),
        @note,
        Map.merge(snapshot(), %{
          conflict_id: @conflict,
          expected_current_version_id: @version,
          competing_version_id: @competing
        })
      )

  defp snapshot,
    do: %{mutation_id: @mutation, title: "Unit mutation", markdown: "Unit mutation body"}

  defp route_versions(:version), do: [@pinned]
  defp route_versions(:conflict), do: [@version, @competing]
  defp route_versions(_), do: [@version]

  defp assert_membership_calls(versions) do
    for version <- versions do
      assert_received {:membership, context, @note, ^version}
      assert context == %{repo: :scoped_repo, principal_id: @principal, owner_scope_id: @owner}
    end

    refute_received {:membership, _, _, _}
  end

  defp assert_primary_read(:version),
    do: assert_received({:note_read, :version, :scoped_repo, @owner, @note, @pinned})

  defp assert_primary_read(:conflict),
    do: assert_received({:note_read, :conflict, :scoped_repo, @owner, @note, @conflict})

  defp assert_primary_read(_),
    do: assert_received({:note_read, :get, :scoped_repo, @owner, @note})

  defp assert_scope(route) do
    assert_received {:scope, kind, authorized_session, requirement}
    assert authorized_session == session()
    assert kind == if(route in [:get, :version, :conflict], do: :read, else: :shared)

    capabilities =
      case route do
        :export -> %{required_capabilities: ["note.export", "note.read"]}
        read when read in [:get, :version, :conflict] -> %{required_capability: "note.read"}
        _ -> %{required_capability: "note.write"}
      end

    assert requirement ==
             Map.merge(capabilities, %{
               vault_id: @owner,
               classification: :private,
               requires_unlocked?: true
             })

    refute_received {:scope, _, _, _}
  end

  defp assert_route_collections(:get, raw) do
    assert_collections(raw, @version)
    assert {:ok, note} = NotesDTO.note(raw)
    assert_collections(note, @version)
  end

  defp assert_route_collections(:version, raw) do
    assert_collections(raw, @pinned)
    assert {:ok, version} = NotesDTO.version(raw)
    assert_collections(version, @pinned)
  end

  defp assert_route_collections(:conflict, raw) do
    assert_collections(raw.current, @version)
    assert_collections(raw.competing, @competing)
    assert {:ok, detail} = NotesDTO.conflict_detail(raw)
    assert_collections(detail.current, @version)
    assert_collections(detail.competing, @competing)
  end

  defp assert_route_collections(:export, _), do: :ok

  defp assert_route_collections(route, result),
    do: assert_collections(canonical_result(route, result), @version)

  defp canonical_result(route, result) when route in [:save, :merge], do: result.canonical
  defp canonical_result(_, result), do: result

  defp assert_replayed_submission(route, result) when route in [:save, :merge],
    do: assert(result.submitted_version_id == @later)

  defp assert_replayed_submission(_, _), do: :ok

  defp assert_collections(note, version) do
    {:ok, expected} = Map.fetch!(state(:membership_results), version)
    assert note.resource_id == @note
    assert note.resource_version_id == version
    assert note.revision == expected.revision

    assert Enum.map(note.attachments, &Map.from_struct/1) ==
             Enum.map(expected.attachments, &Map.from_struct/1)

    assert Enum.map(note.citations, &Map.from_struct/1) ==
             Enum.map(expected.citations, &Map.from_struct/1)

    for {values, dto, fields} <- [
          {note.attachments, Singularity.Runtime.DTO.NoteAttachment,
           [
             :attachment_id,
             :target_resource_id,
             :target_resource_version_id,
             :target_kind,
             :role,
             :label
           ]},
          {note.citations, Singularity.Runtime.DTO.NoteCitation,
           [
             :citation_id,
             :source_resource_id,
             :source_resource_version_id,
             :fragment_id,
             :locator
           ]}
        ],
        value <- values do
      assert value.__struct__ == dto
      assert Enum.sort(Map.keys(Map.from_struct(value))) == Enum.sort(fields)
    end
  end

  defp set_membership(version, reply),
    do: put_state(:membership_results, Map.put(state(:membership_results), version, reply))

  defp membership(revision, offset) do
    attachments =
      Enum.map([2, 1], fn ordinal ->
        {:ok, reference} =
          NoteAttachmentReference.new(%{
            attachment_id: uuid(offset + ordinal),
            target_resource_id: uuid(offset + ordinal + 200),
            target_resource_version_id: uuid(offset + ordinal + 400),
            target_kind: :asset,
            role: :source,
            label: "Unit pinned reference"
          })

        reference
      end)

    citations =
      Enum.map([2, 1], fn ordinal ->
        fragment = source_fragment(uuid(offset + 800), uuid(offset + 900), ordinal)

        {:ok, reference} =
          NoteCitationReference.new(%{
            citation_id: uuid(offset + ordinal + 600),
            source_resource_id: uuid(offset + 800),
            source_resource_version_id: uuid(offset + 900),
            fragment_id: fragment.fragment_id,
            locator: fragment.locator
          })

        reference
      end)

    %{revision: revision, attachments: attachments, citations: citations}
  end

  defp uuid(number),
    do: "00000000-0000-4000-8000-" <> String.pad_leading(Integer.to_string(number), 12, "0")

  defp saved_reference(version) do
    {:ok, references} =
      ReferenceResult.saved(%{
        resource_id: @note,
        canonical_version_id: version,
        submitted_version_id: version
      })

    references
  end

  defp canonical_row(version \\ @version, revision \\ 2) do
    %{
      resource_id: @note,
      resource_version_id: version,
      vault_id: @owner,
      classification: :private,
      title: "Unit canonical Note",
      markdown: "PRIVATE_NOTE_BODY",
      revision: revision,
      updated_at: @time,
      deleted_at: nil,
      deleted?: false,
      created_by_principal_id: @principal,
      inserted_at: @time,
      parent_version_id: @pinned,
      merge_parent_version_id: nil,
      canonical?: true,
      open_conflict_count: 1
    }
  end

  defp version_row(version, revision, canonical?, conflict_state) do
    %{
      resource_id: @note,
      resource_version_id: version,
      vault_id: @owner,
      classification: :private,
      title: "Unit pinned version",
      markdown: "PRIVATE_PINNED_BODY",
      revision: revision,
      created_by_principal_id: @principal,
      inserted_at: @time,
      parent_version_id: if(revision > 0, do: @pinned, else: nil),
      merge_parent_version_id: nil,
      canonical?: canonical?,
      conflict_state: conflict_state
    }
  end

  defp conflict_row do
    %{
      conflict_id: @conflict,
      resource_id: @note,
      vault_id: @owner,
      classification: :private,
      base_version_id: @pinned,
      observed_canonical_version_id: @version,
      competing_version_id: @competing,
      state: :open,
      resolution_version_id: nil,
      created_at: @time,
      resolved_at: nil
    }
  end
end
