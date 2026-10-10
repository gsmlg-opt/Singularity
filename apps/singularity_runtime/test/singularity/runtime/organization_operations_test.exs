defmodule Singularity.Runtime.OrganizationOperationsTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.{Error, OrganizationPageQuery, Relationship, Tag}
  alias Singularity.Runtime.SessionContext

  @operations Singularity.Runtime.Organization.Operations
  @owner "00000000-0000-4000-8000-00000000b001"
  @principal "00000000-0000-4000-8000-00000000b002"
  @source "00000000-0000-4000-8000-00000000b003"
  @target "00000000-0000-4000-8000-00000000b004"
  @tag_id "00000000-0000-4000-8000-00000000b005"
  @edge "00000000-0000-4000-8000-00000000b006"
  @version "00000000-0000-4000-8000-00000000b007"
  @other "00000000-0000-4000-8000-00000000b008"
  @uppercase "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
  @all [
    :attach_tag,
    :detach_tag,
    :list_resource_tags,
    :browse_resources_by_tag,
    :relate_resource,
    :unrelate_resource,
    :list_outgoing_relationships,
    :list_backlinks
  ]
  @pages [
    :list_resource_tags,
    :browse_resources_by_tag,
    :list_outgoing_relationships,
    :list_backlinks
  ]

  # Deterministic units only: Scope/Authorizer/ports do not establish actual
  # SQL locks/RLS, live authorization, cursor authentication, audit or custody.
  # The real Domains.Organization dispatch is used for page validation.
  defmodule Scope do
    import ExUnit.Assertions
    alias Singularity.Runtime.OrganizationOperationsTest, as: Contract

    def with_read_request(runtime, session, requirement, callback),
      do: scoped(:read, runtime, session, requirement, callback)

    def with_shared_request(runtime, session, requirement, callback),
      do: scoped(:write, runtime, session, requirement, callback)

    def with_exclusive_request(_, _, _, _), do: raise("organization must not change scope mode")

    defp scoped(mode, runtime, session, requirement, callback) do
      refute Contract.state(:active_scope)
      assert {Singularity.Runtime.Organization.Authorizer, original} = runtime.authorizer
      assert original == Contract.state(:original_authorizer)
      assert requirement.organization_access == mode
      Contract.record({:scope, mode, session, requirement})
      Contract.put_state(:active_scope, true)

      bound =
        requirement
        |> Map.put(
          :principal_authorization_epoch,
          session.principal_authorization_epoch || session.authorization_epoch
        )
        |> Map.put(:vault_authorization_epoch, session.vault_authorization_epoch)

      try do
        case apply(Singularity.Runtime.Organization.Authorizer, :check, [
               original,
               runtime.authorization,
               :scoped_repo,
               session,
               bound
             ]) do
          :ok -> callback.(:scoped_repo)
          {:error, _} = denial -> denial
        end
      after
        Contract.put_state(:active_scope, false)
        Contract.record({:scope_finished})
      end
    end
  end

  defmodule Authorizer do
    import ExUnit.Assertions
    alias Singularity.Runtime.OrganizationOperationsTest, as: Contract

    def check(dependencies, repo, session, requirement) do
      assert Contract.state(:active_scope)
      assert dependencies == :authorization_dependencies
      assert repo == :scoped_repo

      assert Enum.sort(Map.keys(requirement)) ==
               Enum.sort([
                 :vault_id,
                 :classification,
                 :requires_unlocked?,
                 :principal_authorization_epoch,
                 :vault_authorization_epoch,
                 :required_capability
               ])

      assert requirement.vault_id == session.vault_id
      assert requirement.classification == :private

      assert requirement.principal_authorization_epoch ==
               (session.principal_authorization_epoch || session.authorization_epoch)

      assert requirement.vault_authorization_epoch == session.vault_authorization_epoch

      assert requirement.requires_unlocked? ==
               String.starts_with?(requirement.required_capability, "note.")

      Contract.record({:authorize, requirement.required_capability, repo, session, requirement})

      reply =
        Contract.state(:authorization_replies)
        |> Map.get(requirement.required_capability, :ok)
        |> Contract.reply()

      if reply == :ok,
        do:
          Contract.put_state(:authorized, [
            requirement.required_capability | Contract.state(:authorized)
          ])

      reply
    end
  end

  defmodule Metadata do
    import ExUnit.Assertions
    alias Singularity.Runtime.OrganizationOperationsTest, as: Contract

    def resources_in_scope(context, ids) do
      Contract.assert_context(context)
      assert length(ids) in 1..2
      assert ids == Enum.sort(Enum.uniq(ids))
      Contract.record({:resources, context, ids})

      case Contract.state(:resources_reply) do
        :default -> {:ok, Enum.map(ids, &%{resource_id: &1, kind: Contract.kind(&1)})}
        reply -> Contract.reply(reply)
      end
    end

    def relationship_in_scope(context, id) do
      Contract.assert_context(context)
      Contract.record({:selected_edge, context, id})
      Contract.reply(Contract.state(:selected_edge_reply))
    end
  end

  defmodule Tags do
    import ExUnit.Assertions
    alias Singularity.Runtime.OrganizationOperationsTest, as: Contract

    def resolve_in_scope(context, candidate) do
      Contract.assert_context(context)
      Contract.assert_source_authority(:write)
      assert {:ok, ^candidate} = Singularity.Core.Tag.new(candidate)
      assert candidate.owner_scope_id == context.owner_scope_id
      assert candidate.classification == :private
      Contract.record({:resolve_tag, context, candidate})
      Contract.reply(Contract.state(:tag_reply))
    end

    def attach_in_scope(context, resource, tag), do: mutate(:attach, context, resource, tag)
    def detach_in_scope(context, resource, tag), do: mutate(:detach, context, resource, tag)

    defp mutate(operation, context, resource, tag) do
      Contract.assert_context(context)
      Contract.assert_source_authority(:write)
      Contract.record({operation, context, resource, tag})
      Contract.reply(Contract.state(:mutation_reply))
    end

    def list_page_in_scope(context, resource, query, allowed),
      do: page(:resource_tags, context, resource, query, allowed)

    def browse_in_scope(context, tag, query, allowed),
      do: page(:tag_resources, context, tag, query, allowed)

    defp page(operation, context, id, query, allowed) do
      Contract.assert_context(context)
      if operation == :resource_tags, do: Contract.assert_source_authority(:read)
      Contract.assert_allowed(allowed)
      Contract.record({:page, operation, context, id, query, allowed})
      Contract.reply(Contract.state(:page_reply))
    end

    def resolve(_, _), do: raise("must not use standalone tag transaction")
    def attach(_, _, _), do: raise("must not use standalone tag transaction")
    def detach(_, _, _), do: raise("must not use standalone tag transaction")
    def list(_, _), do: raise("public tags must use bounded pages, not legacy LIMIT 100")
  end

  defmodule Relationships do
    import ExUnit.Assertions
    alias Singularity.Runtime.OrganizationOperationsTest, as: Contract

    def relate_in_scope(context, candidate) do
      Contract.assert_context(context)
      Contract.assert_resource_authority(candidate.source_resource_id, :write)
      Contract.assert_resource_authority(candidate.source_resource_id, :read)

      assert Contract.read_capability(Contract.kind(candidate.target_resource_id)) in Contract.state(
               :authorized
             )

      assert {:ok, ^candidate} = Singularity.Core.Relationship.new(candidate)
      assert candidate.owner_scope_id == context.owner_scope_id
      assert candidate.classification == :private
      Contract.record({:relate, context, candidate})
      Contract.reply(Contract.state(:edge_reply))
    end

    def unrelate_selected_in_scope(context, edge) do
      Contract.assert_context(context)
      Contract.assert_resource_authority(edge.source_resource_id, :write)
      Contract.record({:unrelate_selected, context, edge})
      Contract.reply(Contract.state(:mutation_reply))
    end

    def outgoing_page_in_scope(context, resource, query, allowed),
      do: page(:outgoing, context, resource, query, allowed)

    def incoming_page_in_scope(context, resource, query, allowed),
      do: page(:incoming, context, resource, query, allowed)

    defp page(operation, context, id, query, allowed) do
      Contract.assert_context(context)
      Contract.assert_source_authority(:read)
      Contract.assert_allowed(allowed)
      Contract.record({:page, operation, context, id, query, allowed})
      Contract.reply(Contract.state(:page_reply))
    end

    def unrelate_in_scope(_, _), do: raise("must conditionally delete the exact selected edge")
    def relate(_, _), do: raise("must not use standalone relationship transaction")
    def unrelate(_, _), do: raise("must not use standalone relationship transaction")
    def outgoing(_, _), do: raise("must use bounded scoped edge pages")
    def incoming(_, _), do: raise("must use bounded scoped edge pages")
  end

  setup do
    reset()
    :ok
  end

  for operation <- @all do
    @operation operation

    test "#{@operation} validates canonical IDs and authenticated context before any scope" do
      for invalid <- [nil, "bad", @uppercase, <<0::128>>] do
        reset()
        args = arguments(@operation) |> List.replace_at(2, invalid)
        assert apply(@operations, @operation, args) == {:error, Error.new(:invalid)}
        assert events() == []
      end

      for field <- [:principal_id, :vault_id], invalid <- [nil, "bad", @uppercase] do
        reset()

        assert run(@operation, :default, Map.put(session(), field, invalid)) ==
                 {:error, Error.new(:invalid)}

        assert events() == []
      end
    end

    test "#{@operation} uses one local wrapped scope and returns only its exact owner-free contract" do
      prepare_page(@operation)
      original = runtime()
      assert_success(@operation, run(@operation))
      assert original.authorizer == Authorizer
      assert_one_scope(@operation)
      assert_all_contexts_equal()
      refute Enum.any?(events(), &(elem(&1, 0) in [:body, :title, :bytes, :whole_set]))
    end
  end

  for operation <- [:attach_tag, :detach_tag, :unrelate_resource] do
    @write_operation operation
    test "#{@write_operation} checks exact actual-kind write after selector and before labels or mutation" do
      for kind <- [:note, :asset, :document] do
        reset()
        put_state(:kinds, %{@source => kind, @target => :document})
        assert_success(@write_operation, run(@write_operation))
        metadata_index = event_index(:resources)
        mutation_index = event_index(mutation_event(@write_operation))

        assert Enum.any?(Enum.slice(events(), (metadata_index + 1)..(mutation_index - 1)), fn
                 {:authorize, capability, :scoped_repo, _, _} ->
                   capability == write_capability(kind)

                 _ ->
                   false
               end)

        assert_one_scope(@write_operation)
      end
    end
  end

  test "relate requires exact source write and both endpoint reads for every supported kind pairing" do
    for source_kind <- [:note, :asset, :document], target_kind <- [:note, :asset, :document] do
      reset()
      put_state(:kinds, %{@source => source_kind, @target => target_kind})
      assert_success(:relate_resource, run(:relate_resource))
      assert [{:resources, _, [@source, @target]}] = events_of(:resources)
      metadata_index = event_index(:resources)
      mutation_index = event_index(:relate)

      capabilities =
        Enum.slice(events(), (metadata_index + 1)..(mutation_index - 1))
        |> Enum.map(fn {:authorize, cap, _, _, _} -> cap end)

      for capability <-
            Enum.uniq([
              write_capability(source_kind),
              read_capability(source_kind),
              read_capability(target_kind)
            ]),
          do: assert(capability in capabilities)

      assert_one_scope(:relate_resource)
    end
  end

  test "new tag spelling and edge proposal IDs do not replace stored natural-key replay identity" do
    assert_success(:attach_tag, run(:attach_tag, %{name: "  école  "}))
    [{:resolve_tag, _, proposed}] = events_of(:resolve_tag)
    assert proposed.normalized_key == "école"
    refute proposed.tag_id == @tag_id
    assert [{:attach, _, @source, @tag_id}] = events_of(:attach)

    reset()
    assert_success(:relate_resource, run(:relate_resource))
    [{:relate, _, candidate}] = events_of(:relate)
    refute candidate.relationship_id == @edge
    assert candidate.target_resource_version_id == @version
  end

  test "reversed relation sorts metadata locks without reversing the stored directed endpoints" do
    selected = %{edge_map() | source_resource_id: @target, target_resource_id: @source}

    {:ok, stored} =
      Relationship.new(Map.merge(selected, %{owner_scope_id: @owner, classification: :private}))

    put_state(:edge_reply, {:ok, stored})

    assert {:ok, dto} =
             apply(@operations, :relate_resource, [
               runtime(),
               session(),
               @target,
               %{
                 target_resource_id: @source,
                 target_resource_version_id: @version,
                 type: :related_to
               }
             ])

    assert Map.from_struct(dto) == selected
    assert [{:resources, _, [@source, @target]}] = events_of(:resources)
    [{:relate, _, candidate}] = events_of(:relate)
    assert candidate.source_resource_id == @target
    assert candidate.target_resource_id == @source
  end

  test "strict client mutation fields and bounded query fields fail before scope" do
    for operation <- [:attach_tag, :relate_resource] ++ @pages,
        key <- [
          :owner_scope_id,
          :vault_id,
          :principal_id,
          :classification,
          :correlation_id,
          :allowed_kinds,
          :organization_access,
          :authorize,
          :capabilities,
          :relationship_id,
          :tag_id
        ],
        client_key <- [key, Atom.to_string(key)] do
      reset()
      params = Map.put(default_params(operation), client_key, @owner)
      assert run(operation, params) == {:error, Error.new(:invalid)}
      assert events() == []
    end

    for params <- [
          %{},
          %{target_resource_id: @source, type: :references},
          %{target_resource_id: @uppercase, type: :related_to},
          %{target_resource_id: @target, type: "references"},
          %{target_resource_id: @target, target_resource_version_id: "bad", type: :references}
        ] do
      reset()
      assert run(:relate_resource, params) == {:error, Error.new(:invalid)}
      assert events() == []
    end

    for operation <- @pages,
        params <- [%{limit: 0}, %{limit: 51}, %{cursor: String.duplicate("x", 2049)}] do
      reset()
      assert run(operation, params) == {:error, Error.new(:invalid)}
      assert events() == []
    end

    for tag_id <- [nil, "bad", @uppercase, <<0::128>>] do
      reset()
      assert run(:detach_tag, tag_id) == {:error, Error.new(:invalid)}
      assert events() == []
    end
  end

  test "complete sorted metadata is mandatory and unrequested owner/body/kind fields never reach authorization" do
    for reply <- [
          {:ok, []},
          {:ok, [%{resource_id: @source, kind: :note}]},
          {:ok, [%{resource_id: @target, kind: :document}, %{resource_id: @source, kind: :note}]},
          {:ok, [%{resource_id: @source, kind: :note}, %{resource_id: @source, kind: :note}]},
          {:ok,
           [
             %{resource_id: @source, kind: :note, title: "PRIVATE_TITLE"},
             %{resource_id: @target, kind: :document}
           ]},
          {:ok,
           [%{resource_id: @source, kind: :unknown}, %{resource_id: @target, kind: :document}]},
          {:ok, [%{resource_id: @source, kind: :note}, %{resource_id: @other, kind: :document}]},
          {:ok, [%{resource_id: @source, kind: "note"}, %{resource_id: @target, kind: :document}]}
        ] do
      reset()
      put_state(:resources_reply, reply)
      assert run(:relate_resource) == {:error, Error.new(:integrity_failure)}
      assert length(events_of(:authorize)) == 1
      assert events_of(:relate) == []
    end
  end

  test "missing foreign or tombstoned resource metadata keeps nondisclosing errors and no port mutation" do
    for operation <- @all -- [:browse_resources_by_tag], code <- [:not_found, :forbidden] do
      reset()
      put_state(:resources_reply, {:error, contaminated(code)})
      assert run(operation) == {:error, Error.new(code)}

      refute Enum.any?(
               events(),
               &(elem(&1, 0) in [
                   :resolve_tag,
                   :attach,
                   :detach,
                   :relate,
                   :unrelate_selected,
                   :page
                 ])
             )
    end
  end

  test "successful write entry is not authorization for the actual denied source kind" do
    for operation <- [:attach_tag, :detach_tag, :relate_resource, :unrelate_resource] do
      reset()
      put_state(:authorization_replies, %{"note.write" => {:error, contaminated(:forbidden)}})
      assert run(operation) == {:error, Error.new(:forbidden)}

      assert Enum.take(Enum.map(events_of(:authorize), &elem(&1, 1)), 2) == [
               "note.write",
               "asset.write"
             ]

      refute Enum.any?(
               events(),
               &(elem(&1, 0) in [:resolve_tag, :attach, :detach, :relate, :unrelate_selected])
             )
    end
  end

  test "source or target read denial blocks relate even when source write entry succeeds" do
    for denied <- ["note.read", "asset.read"] do
      reset()
      put_state(:authorization_replies, %{denied => {:error, contaminated(:forbidden)}})
      assert run(:relate_resource) == {:error, Error.new(:forbidden)}
      assert events_of(:relate) == []
    end
  end

  for operation <- @pages do
    @page_operation operation
    test "#{@page_operation} forwards opaque validated query and freshly authorized allowed kinds on the same repo" do
      for kind <- page_source_kinds(@page_operation) do
        reset()
        put_state(:kinds, %{@source => kind, @target => :document})
        params = %{limit: 2, cursor: "opaque-request-token"}
        {:ok, query} = OrganizationPageQuery.new(params)
        prepare_page(@page_operation)
        assert_success(@page_operation, run(@page_operation, params))
        assert [{:page, operation, context, selector, ^query, allowed}] = events_of(:page)
        assert operation == page_operation(@page_operation)
        assert selector == selector(@page_operation)
        assert allowed == [:asset, :document, :note]
        assert context == state(:context)
        assert context.repo == :scoped_repo
        page_index = event_index(:page)
        preceding = Enum.take(events(), page_index)
        assert Enum.any?(preceding, &match?({:authorize, "note.read", :scoped_repo, _, _}, &1))
        assert Enum.any?(preceding, &match?({:authorize, "asset.read", :scoped_repo, _, _}, &1))

        assert Enum.count(preceding, &match?({:authorize, "note.read", :scoped_repo, _, _}, &1)) >=
                 2

        assert_one_scope(@page_operation)
      end
    end
  end

  test "denied or locked Note authority is excluded from trusted page kinds instead of enabling it via Asset fallback" do
    for denial <- [Error.new(:forbidden), Error.new(:vault_locked)] do
      reset()
      put_state(:authorization_replies, %{"note.read" => {:error, denial}})

      put_state(
        :page_reply,
        {:ok, %{items: [%{resource_id: @target, kind: :document}], next_cursor: :done}}
      )

      assert_success(:browse_resources_by_tag, run(:browse_resources_by_tag))
      assert [{:page, :tag_resources, _, @tag_id, _, [:asset, :document]}] = events_of(:page)
      assert events_of(:resources) == []
      assert Enum.count(events_of(:authorize), &(elem(&1, 1) == "note.read")) == 2
      assert Enum.count(events_of(:authorize), &(elem(&1, 1) == "asset.read")) == 2
    end

    reset()
    put_state(:authorization_replies, %{"asset.read" => {:error, Error.new(:forbidden)}})

    put_state(
      :page_reply,
      {:ok, %{items: [%{resource_id: @source, kind: :note}], next_cursor: :done}}
    )

    assert_success(:browse_resources_by_tag, run(:browse_resources_by_tag))
    assert [{:page, :tag_resources, _, @tag_id, _, [:note]}] = events_of(:page)
    assert Enum.count(events_of(:authorize), &(elem(&1, 1) == "note.read")) == 2
    assert Enum.count(events_of(:authorize), &(elem(&1, 1) == "asset.read")) == 1
  end

  test "unauthenticated retryable malformed or escaping allowed-kind checks abort before any page admission" do
    for result <- [
          {:error, contaminated(:unauthenticated)},
          {:error, Error.new(:forbidden, retryable?: true)},
          {:error, Error.new(:storage_unavailable, retryable?: true)},
          {:error, :forbidden},
          nil,
          fn -> raise "PRIVATE_AUTHORITY" end
        ] do
      reset()
      put_state(:authorization_replies, %{"asset.read" => result})

      expected =
        case result do
          {:error, %Error{} = error} ->
            {:error, Error.new(error.code, retryable?: error.retryable?)}

          _invalid ->
            {:error, Error.new(:storage_unavailable, retryable?: true)}
        end

      assert run(:browse_resources_by_tag) == expected
      assert events_of(:page) == []
    end
  end

  test "resource pages recheck their actual selector kind and cannot rely on successful other-kind entry" do
    for operation <- [:list_resource_tags, :list_outgoing_relationships, :list_backlinks] do
      reset()
      prepare_page(operation)
      put_state(:authorization_replies, %{"note.read" => {:error, contaminated(:forbidden)}})
      assert run(operation) == {:error, Error.new(:forbidden)}
      assert events_of(:page) == []
    end
  end

  test "absent or foreign unrelate returns no-op without resource metadata mutation or audit" do
    put_state(:selected_edge_reply, {:ok, nil})
    assert run(:unrelate_resource) == :ok
    assert [{:selected_edge, _, @edge}] = events_of(:selected_edge)
    assert events_of(:resources) == []
    assert events_of(:unrelate_selected) == []
    assert_one_scope(:unrelate_resource)
  end

  test "unrelate binds every exact selected edge field including nullable pin in its conditional deletion" do
    for pin <- [nil, @version] do
      reset()
      selected = %{edge_map() | target_resource_version_id: pin}
      put_state(:selected_edge_reply, {:ok, selected})
      assert run(:unrelate_resource) == :ok
      assert [{:unrelate_selected, _, ^selected}] = events_of(:unrelate_selected)
      assert [{:resources, _, [@source]}] = events_of(:resources)
    end
  end

  test "selected edge identity keys and canonical values are revalidated before source authorization or deletion" do
    valid = edge_map()

    for selected <- [
          Map.put(valid, :relationship_id, @other),
          Map.put(valid, :owner_scope_id, @owner),
          Map.put(valid, :body, "PRIVATE_BODY"),
          Map.delete(valid, :target_resource_version_id),
          Map.put(valid, :type, :unknown),
          Map.put(valid, :target_resource_id, @source),
          Map.put(valid, :target_resource_version_id, @uppercase)
        ] do
      reset()
      put_state(:selected_edge_reply, {:ok, selected})
      assert run(:unrelate_resource) == {:error, Error.new(:integrity_failure)}
      assert events_of(:resources) == []
      assert events_of(:unrelate_selected) == []
    end
  end

  test "foreign forged normalized or mismatched stored mutation results never become public DTOs" do
    for operation <- [:attach_tag, :relate_resource] do
      good = if operation == :attach_tag, do: stored_tag(), else: stored_edge()

      for result <- [
            Map.put(good, :owner_scope_id, @other),
            Map.put(good, :classification, :sensitive),
            Map.put(good, :body, "PRIVATE_BODY")
          ] do
        reset()
        put_state(if(operation == :attach_tag, do: :tag_reply, else: :edge_reply), {:ok, result})
        assert run(operation) == {:error, Error.new(:integrity_failure)}
        if operation == :attach_tag, do: assert(events_of(:attach) == [])
      end
    end

    for {field, value} <- [
          source_resource_id: @other,
          target_resource_id: @other,
          target_resource_version_id: nil,
          type: :references
        ] do
      reset()
      put_state(:edge_reply, {:ok, Map.put(stored_edge(), field, value)})
      assert run(:relate_resource) == {:error, Error.new(:integrity_failure)}
    end

    reset()
    put_state(:tag_reply, {:ok, %{stored_tag() | display_value: " ÉCOLE "}})
    assert run(:attach_tag) == {:error, Error.new(:integrity_failure)}
    assert events_of(:attach) == []
  end

  test "repository errors retain only known code and retryable bit and adapter exceptions are unavailable" do
    for reply <- [
          {:error, contaminated(:conflict)},
          {:error, contaminated(:not_found)},
          {:error,
           Error.new(:storage_unavailable,
             message: "PRIVATE",
             details: %{body: "PRIVATE"},
             retryable?: true
           )}
        ] do
      reset()
      put_state(:edge_reply, reply)
      {:error, error} = reply

      assert run(:relate_resource) ==
               {:error, Error.new(error.code, retryable?: error.retryable?)}
    end

    for failure <- [:raise, :throw, :exit] do
      reset()

      put_state(:resources_reply, fn ->
        case failure do
          :raise -> raise "PRIVATE_SOURCE"
          :throw -> throw("PRIVATE_SOURCE")
          :exit -> exit("PRIVATE_SOURCE")
        end
      end)

      assert run(:attach_tag) == {:error, Error.new(:storage_unavailable, retryable?: true)}
      assert events_of(:resolve_tag) == []
    end
  end

  test "legacy principal epoch is bound for every entry and direct check without changing session" do
    legacy = %{session() | principal_authorization_epoch: nil}
    assert_success(:relate_resource, run(:relate_resource, :default, legacy))

    for {:authorize, _, :scoped_repo, seen_session, requirement} <- events_of(:authorize) do
      assert seen_session == legacy
      assert requirement.principal_authorization_epoch == 3
      assert requirement.vault_authorization_epoch == 5
    end
  end

  test "default list_resource_tags uses the same bounded twenty-item query contract" do
    prepare_page(:list_resource_tags)

    assert_success(
      :list_resource_tags,
      apply(@operations, :list_resource_tags, [runtime(), session(), @source])
    )

    assert [{:page, :resource_tags, _, @source, query, [:asset, :document, :note]}] =
             events_of(:page)

    assert Map.from_struct(query) == %{limit: 20, cursor: nil}
    assert_one_scope(:list_resource_tags)
  end

  test "edge pages reject a canonical row bound to a different directed selector" do
    for operation <- [:list_outgoing_relationships, :list_backlinks] do
      reset()

      selected =
        case operation do
          :list_outgoing_relationships -> %{edge_map() | source_resource_id: @other}
          :list_backlinks -> edge_map()
        end

      put_state(:page_reply, {:ok, %{items: [selected], next_cursor: :done}})
      assert run(operation) == {:error, Error.new(:integrity_failure)}
      assert_one_scope(operation)
    end
  end

  def state(key), do: Process.get({__MODULE__, key})
  def put_state(key, value), do: Process.put({__MODULE__, key}, value)
  def record(event), do: put_state(:events, state(:events) ++ [event])
  def reply(function) when is_function(function, 0), do: function.()
  def reply(value), do: value
  def kind(id), do: Map.fetch!(state(:kinds), id)
  def read_capability(:note), do: "note.read"
  def read_capability(kind) when kind in [:asset, :document], do: "asset.read"
  def write_capability(:note), do: "note.write"
  def write_capability(kind) when kind in [:asset, :document], do: "asset.write"

  def assert_source_authority(access) do
    assert_resource_authority(@source, access)
  end

  def assert_resource_authority(resource, access) do
    capability =
      if access == :read,
        do: read_capability(kind(resource)),
        else: write_capability(kind(resource))

    assert capability in state(:authorized)
  end

  def assert_context(context) do
    assert state(:active_scope)

    assert Enum.sort(Map.keys(context)) ==
             Enum.sort([:repo, :principal_id, :owner_scope_id, :correlation_id])

    assert context.repo == :scoped_repo
    assert context.principal_id == @principal
    assert context.owner_scope_id == @owner
    assert {:ok, correlation} = Ecto.UUID.cast(context.correlation_id)
    assert correlation == context.correlation_id

    case state(:context) do
      nil -> put_state(:context, context)
      same -> assert context == same
    end
  end

  def assert_allowed(allowed) do
    assert allowed == Enum.sort(Enum.uniq(allowed))
    assert Enum.all?(allowed, &(&1 in [:asset, :document, :note]))
    for kind <- allowed, do: assert(read_capability(kind) in state(:authorized))
  end

  defp reset do
    put_state(:events, [])
    put_state(:active_scope, false)
    put_state(:context, nil)
    put_state(:original_authorizer, Authorizer)
    put_state(:authorized, [])
    put_state(:authorization_replies, %{})
    put_state(:kinds, %{@source => :note, @target => :document})
    put_state(:resources_reply, :default)
    put_state(:selected_edge_reply, {:ok, edge_map()})
    put_state(:tag_reply, {:ok, stored_tag()})
    put_state(:edge_reply, {:ok, stored_edge()})
    put_state(:mutation_reply, :ok)
    put_state(:page_reply, {:ok, %{items: [], next_cursor: :done}})
  end

  defp runtime,
    do: %{
      operation_scope: Scope,
      authorizer: Authorizer,
      authorization: :authorization_dependencies,
      organization_repository: Metadata,
      tag_repository: Tags,
      relationship_repository: Relationships,
      organization: Singularity.Domains.Organization
    }

  defp run(operation, params \\ :default, session_value \\ session()) do
    apply(
      @operations,
      operation,
      arguments(operation, params) |> List.replace_at(1, session_value)
    )
  end

  defp arguments(:unrelate_resource, _params), do: [runtime(), session(), @edge]
  defp arguments(:detach_tag, :default), do: [runtime(), session(), @source, @tag_id]
  defp arguments(:detach_tag, params), do: [runtime(), session(), @source, params]

  defp arguments(operation, :default),
    do: [runtime(), session(), selector(operation), default_params(operation)]

  defp arguments(operation, params), do: [runtime(), session(), selector(operation), params]
  defp arguments(operation), do: arguments(operation, :default)
  defp selector(:browse_resources_by_tag), do: @tag_id
  defp selector(_), do: @source
  defp default_params(:attach_tag), do: %{name: "ÉCOLE"}

  defp default_params(:relate_resource),
    do: %{target_resource_id: @target, target_resource_version_id: @version, type: :related_to}

  defp default_params(_), do: %{}

  defp edge_map,
    do: %{
      relationship_id: @edge,
      source_resource_id: @source,
      target_resource_id: @target,
      target_resource_version_id: @version,
      type: :related_to
    }

  defp stored_edge do
    {:ok, edge} =
      Relationship.new(Map.merge(edge_map(), %{owner_scope_id: @owner, classification: :private}))

    edge
  end

  defp stored_tag do
    {:ok, tag} =
      Tag.new(%{
        tag_id: @tag_id,
        owner_scope_id: @owner,
        classification: :private,
        display_value: "ÉCOLE"
      })

    tag
  end

  defp page_operation(:list_resource_tags), do: :resource_tags
  defp page_operation(:browse_resources_by_tag), do: :tag_resources
  defp page_operation(:list_outgoing_relationships), do: :outgoing
  defp page_operation(:list_backlinks), do: :incoming
  defp page_source_kinds(:browse_resources_by_tag), do: [:note]
  defp page_source_kinds(_), do: [:note, :asset, :document]

  defp prepare_page(operation) when operation in @pages do
    item =
      case operation do
        :list_resource_tags ->
          %{tag_id: @tag_id, display_value: "ÉCOLE"}

        :browse_resources_by_tag ->
          %{resource_id: @target, kind: :document}

        :list_backlinks ->
          %{edge_map() | source_resource_id: @target, target_resource_id: @source}

        _ ->
          edge_map()
      end

    put_state(:page_reply, {:ok, %{items: [item], next_cursor: :done}})
  end

  defp prepare_page(_), do: :ok
  defp mutation_event(:attach_tag), do: :resolve_tag
  defp mutation_event(:detach_tag), do: :detach
  defp mutation_event(:unrelate_resource), do: :unrelate_selected
  defp events, do: state(:events)
  defp events_of(kind), do: Enum.filter(events(), &(elem(&1, 0) == kind))
  defp event_index(kind), do: Enum.find_index(events(), &(elem(&1, 0) == kind))

  defp assert_one_scope(operation) do
    mode = if operation in @pages, do: :read, else: :write
    assert [{:scope, ^mode, _, _}] = events_of(:scope)
    assert length(events_of(:scope_finished)) == 1
    assert state(:active_scope) == false
  end

  defp assert_all_contexts_equal do
    context = state(:context)

    for event <- events(),
        elem(event, 0) in [
          :resources,
          :selected_edge,
          :resolve_tag,
          :attach,
          :detach,
          :relate,
          :unrelate_selected,
          :page
        ] do
      position = if elem(event, 0) == :page, do: 2, else: 1
      assert elem(event, position) == context
    end
  end

  defp assert_success(operation, :ok) when operation in [:detach_tag, :unrelate_resource], do: :ok

  defp assert_success(:attach_tag, {:ok, dto}) do
    assert dto.__struct__ == Singularity.Runtime.DTO.OrganizationTag
    assert Map.from_struct(dto) == %{tag_id: @tag_id, display_value: "ÉCOLE"}
  end

  defp assert_success(:relate_resource, {:ok, dto}) do
    assert dto.__struct__ == Singularity.Runtime.DTO.OrganizationRelationship
    assert Map.from_struct(dto) == edge_map()
  end

  defp assert_success(operation, {:ok, dto}) when operation in @pages do
    assert dto.__struct__ == Singularity.Runtime.DTO.OrganizationPage
    assert Enum.sort(Map.keys(Map.from_struct(dto))) == [:items, :next_cursor]
    assert dto.next_cursor == nil
    {:ok, raw} = state(:page_reply)
    assert Enum.map(dto.items, &Map.from_struct/1) == raw.items
  end

  defp assert_success(_operation, result),
    do: flunk("unexpected organization result #{inspect(result)}")

  defp contaminated(code),
    do: Error.new(code, message: "PRIVATE_ERROR", details: %{body: "PRIVATE_BODY"})

  defp session,
    do: %SessionContext{
      session_id: "00000000-0000-4000-8000-00000000b009",
      account_id: "00000000-0000-4000-8000-00000000b00a",
      principal_id: @principal,
      vault_id: @owner,
      expires_at: ~U[2026-10-11 12:30:00Z],
      principal_authorization_epoch: 3,
      vault_authorization_epoch: 5,
      authorization_epoch: 3,
      unlocked?: true
    }
end
