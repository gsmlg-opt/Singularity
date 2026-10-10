defmodule Singularity.Storage.Postgres.RelationshipRepositoryTest do
  use Singularity.Storage.DataCase, async: false
  @moduletag :integration

  alias Singularity.Core.{Error, OrganizationPage, OrganizationPageQuery, Relationship}

  alias Singularity.Storage.{
    Fixtures,
    KnowledgeFixtures,
    KnowledgeTestGrants,
    MigrationRepo,
    ScopedRepo
  }

  alias Singularity.Storage.Postgres.RelationshipRepository
  alias Singularity.Storage.Schema.Audit.Event

  defmodule AuditFailureRepo do
    alias Singularity.Storage.RequestRepo
    defdelegate get_dynamic_repo(), to: RequestRepo
    defdelegate __adapter__(), to: RequestRepo
    defdelegate in_transaction?(), to: RequestRepo
    defdelegate transaction(fun, opts), to: RequestRepo
    defdelegate rollback(reason), to: RequestRepo
    defdelegate one(query), to: RequestRepo
    defdelegate all(query), to: RequestRepo
    defdelegate insert_all(schema, entries, opts), to: RequestRepo
    defdelegate delete_all(query), to: RequestRepo

    def insert(
          %Ecto.Changeset{data: %Singularity.Storage.Schema.Audit.Event{}} = changeset,
          _opts
        ) do
      target = Ecto.Changeset.get_field(changeset, :target_id)

      %{rows: [[1]]} =
        Singularity.Storage.SafeSQL.query!(
          RequestRepo,
          "SELECT count(*) FROM content.relationships WHERE id=$1",
          [Ecto.UUID.dump!(target)]
        )

      send(self(), {:audit_saw_relationship, target})
      {:error, Ecto.Changeset.add_error(changeset, :operation, "injected failure")}
    end

    def insert(changeset, opts), do: RequestRepo.insert(changeset, opts)
  end

  setup do
    source = KnowledgeFixtures.source!()
    first = KnowledgeFixtures.note!(source)
    second = KnowledgeFixtures.note!(source)

    context = %{
      repo: RequestRepo,
      principal_id: id(source.principal_id),
      owner_scope_id: id(source.vault_id),
      correlation_id: Ecto.UUID.generate()
    }

    %{source: source, first: first, second: second, context: context}
  end

  defmodule PausedDeleteRepo do
    alias Singularity.Storage.RequestRepo
    defdelegate in_transaction?(), to: RequestRepo
    defdelegate transaction(fun, options), to: RequestRepo
    defdelegate rollback(reason), to: RequestRepo
    defdelegate one(query), to: RequestRepo
    defdelegate insert(changeset, options), to: RequestRepo

    def delete_all(query), do: delete_all(query, [])

    def delete_all(query, options) do
      send(Process.get(:relationship_delete_parent), {:before_relationship_delete, self()})

      receive do
        :continue_relationship_delete -> RequestRepo.delete_all(query, options)
      after
        10_000 -> raise "relationship delete handshake timed out"
      end
    end
  end

  test "existing audit shape accepts knowledge relationship operations", %{context: context} do
    for operation <- ["knowledge.related", "knowledge.unrelated"] do
      changeset =
        Event.append_changeset(%Event{}, %{
          id: Ecto.UUID.generate(),
          vault_id: context.owner_scope_id,
          actor_kind: :principal,
          principal_id: context.principal_id,
          operation: operation,
          result: :completed,
          classification: :private,
          correlation_id: context.correlation_id,
          target_type: "relationship",
          target_id: Ecto.UUID.generate(),
          metadata: %{"type" => "references"},
          occurred_at: DateTime.utc_now(:microsecond)
        })

      assert changeset.valid?, inspect(changeset.errors)
    end
  end

  test "rejects noncanonical uppercase authenticated context UUIDs", data do
    with_grants(fn ->
      for field <- [:principal_id, :owner_scope_id, :correlation_id] do
        context = Map.update!(data.context, field, &String.upcase/1)

        assert {:error, %Error{code: :invalid}} =
                 RelationshipRepository.outgoing(context, id(data.first.resource_id))
      end

      assert audits(data.context) == []
    end)
  end

  test "natural edge replay preserves first UUID and conflicts on changed pin", data do
    with_grants(fn ->
      edge = edge(data)
      assert {:ok, ^edge} = RelationshipRepository.relate(data.context, edge)
      replay = %{edge | relationship_id: Ecto.UUID.generate()}
      assert {:ok, ^edge} = RelationshipRepository.relate(data.context, replay)

      assert {:error, %Error{code: :conflict}} =
               RelationshipRepository.relate(
                 data.context,
                 %{replay | target_resource_version_id: id(data.second.resource_version_id)}
               )

      assert [["knowledge.related", metadata]] = audits(data.context)

      assert MapSet.new(Map.keys(metadata)) ==
               MapSet.new([
                 "source_resource_id",
                 "target_resource_id",
                 "type"
               ])

      assert metadata == %{
               "source_resource_id" => edge.source_resource_id,
               "target_resource_id" => edge.target_resource_id,
               "type" => "references"
             }
    end)
  end

  test "incoming queries stored directed edges and both lists are deterministic", data do
    with_grants(fn ->
      a = edge(data)
      b = %{a | relationship_id: Ecto.UUID.generate(), type: :related_to}

      for edge <- [b, a],
          do: assert({:ok, ^edge} = RelationshipRepository.relate(data.context, edge))

      assert {:ok, outgoing} = RelationshipRepository.outgoing(data.context, a.source_resource_id)

      assert {:ok, ^outgoing} =
               RelationshipRepository.incoming(data.context, a.target_resource_id)

      assert Enum.sort_by(
               outgoing,
               &{&1.source_resource_id, &1.target_resource_id, &1.relationship_id}
             ) == outgoing

      assert MapSet.new(outgoing) == MapSet.new([a, b])
      assert {:ok, []} = RelationshipRepository.outgoing(data.context, a.target_resource_id)
      assert {:ok, []} = RelationshipRepository.incoming(data.context, a.source_resource_id)
    end)
  end

  test "incoming and outgoing lists cap 101 stored edges at 100 in stable UUID order", data do
    intermediates = for _ <- 1..101, do: KnowledgeFixtures.note!(data.source)

    with_grants(fn ->
      {outgoing, incoming} =
        Enum.map(intermediates, fn note ->
          outward = edge(%{data | second: note})
          inward = edge(%{data | first: note})
          assert {:ok, ^outward} = RelationshipRepository.relate(data.context, outward)
          assert {:ok, ^inward} = RelationshipRepository.relate(data.context, inward)
          {outward, inward}
        end)
        |> Enum.unzip()

      order = &{&1.source_resource_id, &1.target_resource_id, &1.relationship_id}
      expected_outgoing = outgoing |> Enum.sort_by(order) |> Enum.take(100)
      expected_incoming = incoming |> Enum.sort_by(order) |> Enum.take(100)

      assert {:ok, ^expected_outgoing} =
               RelationshipRepository.outgoing(data.context, id(data.first.resource_id))

      assert {:ok, ^expected_incoming} =
               RelationshipRepository.incoming(data.context, id(data.second.resource_id))
    end)
  end

  test "unrelate is idempotent and emits one audit for the actual deletion", data do
    with_grants(fn ->
      edge = edge(data)
      assert {:ok, ^edge} = RelationshipRepository.relate(data.context, edge)
      assert :ok = RelationshipRepository.unrelate(data.context, edge.relationship_id)
      assert :ok = RelationshipRepository.unrelate(data.context, edge.relationship_id)
      assert {:ok, []} = RelationshipRepository.outgoing(data.context, edge.source_resource_id)
      assert ["knowledge.related", "knowledge.unrelated"] == Enum.map(audits(data.context), &hd/1)
    end)
  end

  test "deleted endpoints disappear from both live lists", data do
    with_grants(fn ->
      edge = edge(data)
      assert {:ok, ^edge} = RelationshipRepository.relate(data.context, edge)

      Fixtures.with_owner(fn ->
        query!(
          MigrationRepo,
          "UPDATE content.resources SET deleted_at=CURRENT_TIMESTAMP WHERE id=$1",
          [data.second.resource_id]
        )
      end)

      assert {:ok, []} = RelationshipRepository.outgoing(data.context, edge.source_resource_id)
      assert {:ok, []} = RelationshipRepository.incoming(data.context, edge.target_resource_id)
      assert {:error, %Error{code: code}} = RelationshipRepository.relate(data.context, edge)
      assert code in [:not_found, :invalid]
    end)
  end

  test "unrelate audits the actual row deleted after concurrent same-UUID replacement", data do
    # Raw SQL in ScopedRepo resolves registered metadata; this alias preserves
    # RequestRepo's transaction while pausing immediately before DELETE.
    {:ok, bridge} = Agent.start_link(fn -> nil end, name: PausedDeleteRepo)

    :ok =
      Ecto.Repo.Registry.associate(
        bridge,
        PausedDeleteRepo,
        Ecto.Adapter.lookup_meta(RequestRepo)
      )

    on_exit(fn -> if Process.alive?(bridge), do: Agent.stop(bridge) end)

    with_grants(fn ->
      original = edge(data)
      assert {:ok, ^original} = RelationshipRepository.relate(data.context, original)
      parent = self()

      deletion =
        Task.async(fn ->
          Process.put(:relationship_delete_parent, parent)

          RelationshipRepository.unrelate(
            %{data.context | repo: PausedDeleteRepo},
            original.relationship_id
          )
        end)

      assert_receive {:before_relationship_delete, deleter}, 5_000

      try do
        Fixtures.with_owner(fn ->
          query!(MigrationRepo, "DELETE FROM content.relationships WHERE id=$1", [
            Ecto.UUID.dump!(original.relationship_id)
          ])

          query!(
            MigrationRepo,
            "INSERT INTO content.relationships(id,vault_id,classification,source_resource_id,target_resource_id,target_resource_version_id,type,created_by_principal_id,inserted_at) VALUES($1,$2,'private',$3,$4,$5,'derived_from',$6,CURRENT_TIMESTAMP)",
            [
              Ecto.UUID.dump!(original.relationship_id),
              data.source.vault_id,
              data.second.resource_id,
              data.first.resource_id,
              data.first.resource_version_id,
              data.source.principal_id
            ]
          )
        end)
      after
        send(deleter, :continue_relationship_delete)
      end

      assert :ok = Task.await(deletion, 10_000)

      assert {:ok, []} =
               RelationshipRepository.outgoing(data.context, id(data.second.resource_id))

      assert [["knowledge.unrelated", metadata]] =
               Enum.filter(audits(data.context), fn [operation, _] ->
                 operation == "knowledge.unrelated"
               end)

      assert metadata == %{
               "source_resource_id" => id(data.second.resource_id),
               "target_resource_id" => id(data.first.resource_id),
               "target_resource_version_id" => id(data.first.resource_version_id),
               "type" => "derived_from"
             }
    end)
  end

  test "revalidates forged structs and hides foreign owner endpoints", data do
    with_grants(fn ->
      edge = edge(data)

      assert {:error, %Error{code: :invalid}} =
               RelationshipRepository.relate(data.context, %{edge | type: :secret_canary})

      other = KnowledgeFixtures.source!()
      foreign = KnowledgeFixtures.note!(other)

      assert {:error, %Error{code: code}} =
               RelationshipRepository.relate(data.context, %{
                 edge
                 | target_resource_id: id(foreign.resource_id)
               })

      assert code in [:not_found, :invalid]
      assert audits(data.context) == []
    end)
  end

  test "audit insertion failure rolls back canonical edge", data do
    # Raw SQL resolves repositories by registered process, independently of
    # delegated Ecto functions. Reuse the real connection metadata only here.
    {:ok, bridge} = Agent.start_link(fn -> nil end, name: AuditFailureRepo)

    :ok =
      Ecto.Repo.Registry.associate(
        bridge,
        AuditFailureRepo,
        Ecto.Adapter.lookup_meta(RequestRepo)
      )

    on_exit(fn -> if Process.alive?(bridge), do: Agent.stop(bridge) end)

    with_grants(fn ->
      edge = edge(data)

      assert {:error, %Error{}} =
               RelationshipRepository.relate(%{data.context | repo: AuditFailureRepo}, edge)

      assert_received {:audit_saw_relationship, target}
      assert target == edge.relationship_id
      assert {:ok, []} = RelationshipRepository.outgoing(data.context, edge.source_resource_id)
      assert audits(data.context) == []
    end)
  end

  test "scoped relate preserves natural replay and pin conflicts without nesting scope", data do
    with_grants(fn ->
      candidate = edge(data)
      replay = %{candidate | relationship_id: Ecto.UUID.generate()}

      assert {:ok, ^candidate} =
               organization_scope(data, fn context ->
                 assert {:error, %Error{code: :invalid}} =
                          RelationshipRepository.relate(context, candidate)

                 for forged <- [
                       %{candidate | type: :unknown},
                       %{candidate | target_resource_id: candidate.source_resource_id},
                       %{candidate | owner_scope_id: candidate.target_resource_id}
                     ] do
                   assert_organization_error(
                     organization_call(:relate_in_scope, [context, forged]),
                     :invalid
                   )
                 end

                 assert {:ok, ^candidate} =
                          organization_call(:relate_in_scope, [context, candidate])

                 assert {:error, %Error{code: :conflict}} =
                          organization_call(
                            :relate_in_scope,
                            [
                              context,
                              %{
                                replay
                                | target_resource_version_id: id(data.second.resource_version_id)
                              }
                            ]
                          )

                 organization_call(:relate_in_scope, [context, replay])
               end)

      assert [["knowledge.related", metadata]] = audits(data.context)

      assert metadata == %{
               "source_resource_id" => candidate.source_resource_id,
               "target_resource_id" => candidate.target_resource_id,
               "type" => "references"
             }
    end)
  end

  test "scoped unrelate removes once and audits only its actual deletion", data do
    with_grants(fn ->
      candidate = edge(data)
      assert {:ok, ^candidate} = RelationshipRepository.relate(data.context, candidate)

      assert :ok =
               organization_scope(data, fn context ->
                 assert {:error, %Error{code: :invalid}} =
                          RelationshipRepository.unrelate(context, candidate.relationship_id)

                 assert :ok =
                          organization_call(:unrelate_in_scope, [
                            context,
                            candidate.relationship_id
                          ])

                 organization_call(:unrelate_in_scope, [context, candidate.relationship_id])
               end)

      assert {:ok, []} =
               RelationshipRepository.outgoing(data.context, candidate.source_resource_id)

      assert ["knowledge.related", "knowledge.unrelated"] == Enum.map(audits(data.context), &hd/1)
    end)
  end

  test "outer rollback removes scoped edge and audit effects", data do
    with_grants(fn ->
      candidate = edge(data)

      assert {:error, :organization_rollback} =
               organization_scope(data, fn context ->
                 assert {:ok, ^candidate} =
                          organization_call(:relate_in_scope, [context, candidate])

                 {:error, :organization_rollback}
               end)

      assert {:ok, []} =
               RelationshipRepository.outgoing(data.context, candidate.source_resource_id)

      Fixtures.with_owner(fn ->
        assert %{rows: [[0]]} =
                 query!(MigrationRepo, "SELECT count(*) FROM content.relationships WHERE id=$1", [
                   Ecto.UUID.dump!(candidate.relationship_id)
                 ])
      end)

      assert audits(data.context) == []
    end)
  end

  test "new scoped edge seams require matching principal and owner GUCs", data do
    other = KnowledgeFixtures.source!()

    with_grants(fn ->
      candidate = edge(data)
      query = organization_query(%{})

      calls = [
        {:relate_in_scope, [candidate]},
        {:unrelate_in_scope, [candidate.relationship_id]},
        {:outgoing_page_in_scope, [candidate.source_resource_id, query, [:note]]},
        {:incoming_page_in_scope, [candidate.target_resource_id, query, [:note]]}
      ]

      for {method, arguments} <- calls do
        assert_organization_error(organization_call(method, [data.context | arguments]), :invalid)

        assert {:ok, :ok} =
                 RequestRepo.transaction(fn ->
                   assert_organization_error(
                     organization_call(method, [data.context | arguments]),
                     :invalid
                   )

                   :ok
                 end)

        for malformed <- [
              %{data.context | principal_id: id(other.principal_id)},
              %{data.context | owner_scope_id: id(other.vault_id)}
            ] do
          assert :ok =
                   organization_scope(data, fn _context ->
                     assert_organization_error(
                       organization_call(method, [malformed | arguments]),
                       :invalid
                     )

                     :ok
                   end)
        end
      end

      assert audits(data.context) == []
    end)
  end

  test "both edge page directions traverse beyond 100 using relationship UUID keysets", data do
    {_documents, notes} = organization_endpoints(data.source, 0, 101)

    with_grants(fn ->
      for {method, operation} <- organization_directions() do
        expected = seed_organization_edges(data, operation, notes)
        selector = id(data.first.resource_id)
        assert collect_organization_edges(data, method, selector, 20) == expected

        for limit <- [1, 50] do
          assert {:ok, %OrganizationPage{items: items, next_cursor: cursor}} =
                   organization_edge_page(data, method, selector, %{limit: limit}, [:note])

          assert items == Enum.take(expected, limit)
          assert {:ok, last} = organization_decode(cursor, data.context, selector, operation)
          assert last == List.last(items).relationship_id
        end
      end
    end)
  end

  test "both endpoint kind filters precede SQL limit and continuation in each direction", data do
    {excluded, permitted} = organization_endpoints(data.source, 4, 3)

    with_grants(fn ->
      for {method, operation} <- organization_directions() do
        seeded = seed_organization_edges(data, operation, excluded ++ permitted)
        expected = Enum.drop(seeded, 4)
        selector = id(data.first.resource_id)

        assert {:ok, %OrganizationPage{items: first, next_cursor: cursor}} =
                 organization_edge_page(data, method, selector, %{limit: 2}, [:note])

        assert first == Enum.take(expected, 2)
        assert {:ok, last} = organization_decode(cursor, data.context, selector, operation)
        assert last == List.last(first).relationship_id

        assert {:ok, %OrganizationPage{items: [last_item], next_cursor: :done}} =
                 organization_edge_page(data, method, selector, %{limit: 2, cursor: cursor}, [
                   :note
                 ])

        assert last_item == List.last(expected)

        assert_organization_error(
          organization_edge_page(data, method, selector, %{limit: 2}, [:asset, :document]),
          :not_found
        )
      end
    end)
  end

  test "edge pages omit tombstoned endpoints and restore exact pins and direction", data do
    with_grants(fn ->
      outgoing = %{edge(data) | target_resource_version_id: id(data.second.resource_version_id)}

      incoming = %{
        edge(data)
        | source_resource_id: id(data.second.resource_id),
          target_resource_id: id(data.first.resource_id),
          target_resource_version_id: id(data.first.resource_version_id)
      }

      assert {:ok, ^outgoing} = RelationshipRepository.relate(data.context, outgoing)
      assert {:ok, ^incoming} = RelationshipRepository.relate(data.context, incoming)
      selector = id(data.first.resource_id)

      for {method, expected} <- [
            {:outgoing_page_in_scope, organization_item(outgoing)},
            {:incoming_page_in_scope, organization_item(incoming)}
          ] do
        assert {:ok, %OrganizationPage{items: [^expected], next_cursor: :done}} =
                 organization_edge_page(data, method, selector, %{}, [:note])
      end

      organization_tombstone(data.second.resource_id, true)

      for {method, _operation} <- organization_directions() do
        assert {:ok, %OrganizationPage{items: [], next_cursor: :done}} =
                 organization_edge_page(data, method, selector, %{}, [:note])

        assert_organization_error(
          organization_edge_page(data, method, id(data.second.resource_id), %{}, [:note]),
          :not_found
        )
      end

      organization_tombstone(data.second.resource_id, false)

      for {method, expected} <- [
            {:outgoing_page_in_scope, organization_item(outgoing)},
            {:incoming_page_in_scope, organization_item(incoming)}
          ] do
        assert {:ok, %OrganizationPage{items: [^expected], next_cursor: :done}} =
                 organization_edge_page(data, method, selector, %{}, [:note])
      end
    end)
  end

  test "paged edge selectors hide unknown and foreign resources", data do
    other = KnowledgeFixtures.source!()
    foreign = KnowledgeFixtures.note!(other)

    with_grants(fn ->
      for {method, _operation} <- organization_directions(),
          selector <- [Ecto.UUID.generate(), id(foreign.resource_id)] do
        assert_organization_error(
          organization_edge_page(data, method, selector, %{}, [:note]),
          :not_found
        )
      end
    end)
  end

  test "edge cursors reject wrong contexts but allow a new limit on the same live page", data do
    {_documents, notes} = organization_endpoints(data.source, 0, 3)

    with_grants(fn ->
      outgoing = seed_organization_edges(data, :outgoing, notes)
      incoming = seed_organization_edges(data, :incoming, notes)
      selector = id(data.first.resource_id)

      for {method, operation, expected, other_method} <- [
            {:outgoing_page_in_scope, :outgoing, outgoing, :incoming_page_in_scope},
            {:incoming_page_in_scope, :incoming, incoming, :outgoing_page_in_scope}
          ] do
        assert {:ok, %OrganizationPage{items: [first], next_cursor: cursor}} =
                 organization_edge_page(data, method, selector, %{limit: 1}, [:note])

        assert first == hd(expected)
        assert {:ok, first_id} = organization_decode(cursor, data.context, selector, operation)
        assert first_id == first.relationship_id

        assert {:ok, %OrganizationPage{items: remaining, next_cursor: :done}} =
                 organization_edge_page(data, method, selector, %{limit: 2, cursor: cursor}, [
                   :note
                 ])

        assert remaining == Enum.drop(expected, 1)

        assert_organization_error(
          organization_edge_page(data, method, selector, %{limit: 1, cursor: cursor}, [
            :asset,
            :document
          ]),
          :not_found
        )

        assert_organization_error(
          organization_edge_page(data, other_method, selector, %{limit: 1, cursor: cursor}, [
            :note
          ]),
          :invalid
        )

        assert_organization_error(
          organization_edge_page(
            data,
            method,
            id(data.second.resource_id),
            %{limit: 1, cursor: cursor},
            [:note]
          ),
          :invalid
        )

        assert_organization_error(
          organization_edge_page(data, method, selector, %{limit: 1, cursor: cursor <> "x"}, [
            :note
          ]),
          :invalid
        )
      end
    end)
  end

  test "edge pages reject forged queries and noncanonical kind filters", data do
    with_grants(fn ->
      for {method, _operation} <- organization_directions() do
        selector = id(data.first.resource_id)

        for query <- [
              %{limit: 1, cursor: nil},
              %{organization_query(%{}) | limit: 51},
              Map.put(organization_query(%{}), :capabilities, ["note.read"])
            ] do
          assert_organization_error(
            organization_scope(
              data,
              &organization_call(method, [&1, selector, query, [:note]])
            ),
            :invalid
          )
        end

        for kinds <- [nil, [:unknown], [:note, :note], [:note | :tail]] do
          assert_organization_error(
            organization_scope(
              data,
              &organization_call(method, [&1, selector, organization_query(%{}), kinds])
            ),
            :invalid
          )
        end
      end
    end)
  end

  defp organization_scope(data, fun) do
    ScopedRepo.transact(
      data.context.repo,
      %{principal_id: data.context.principal_id, vault_id: data.context.owner_scope_id},
      fn repo -> fun.(%{data.context | repo: repo}) end
    )
  end

  defp organization_call(method, arguments), do: apply(RelationshipRepository, method, arguments)

  defp organization_query(params) do
    assert {:ok, query} = OrganizationPageQuery.new(params)
    query
  end

  defp organization_edge_page(data, method, selector, params, kinds),
    do:
      organization_scope(
        data,
        &organization_call(method, [&1, selector, organization_query(params), kinds])
      )

  defp organization_decode(cursor, context, selector, operation) do
    binding = %{
      owner_scope_id: context.owner_scope_id,
      selector_id: selector,
      operation: operation,
      ordering_version: 1
    }

    apply(Singularity.Storage.Postgres.OrganizationCursor, :decode, [
      cursor,
      binding,
      Application.fetch_env!(:singularity_runtime, :audit_fingerprint_secret)
    ])
  end

  defp organization_directions,
    do: [{:outgoing_page_in_scope, :outgoing}, {:incoming_page_in_scope, :incoming}]

  defp organization_item(edge),
    do:
      Map.take(
        edge,
        [
          :relationship_id,
          :source_resource_id,
          :target_resource_id,
          :target_resource_version_id,
          :type
        ]
      )

  defp seed_organization_edges(data, direction, rows) do
    prefix = Ecto.UUID.generate() |> String.slice(0, 24)

    for {row, index} <- Enum.with_index(rows, 1) do
      {source, target} =
        if direction == :outgoing,
          do: {id(data.first.resource_id), id(row.resource_id)},
          else: {id(row.resource_id), id(data.first.resource_id)}

      candidate = %{
        edge(data)
        | relationship_id: organization_id(prefix, index),
          source_resource_id: source,
          target_resource_id: target
      }

      assert {:ok, ^candidate} = RelationshipRepository.relate(data.context, candidate)
      organization_item(candidate)
    end
  end

  defp collect_organization_edges(
         data,
         method,
         selector,
         limit,
         cursor \\ nil,
         acc \\ [],
         pages \\ 0
       ) do
    assert pages < 10

    assert {:ok, %OrganizationPage{items: items, next_cursor: next}} =
             organization_edge_page(data, method, selector, %{limit: limit, cursor: cursor}, [
               :note
             ])

    assert length(items) <= limit

    if next == :done,
      do: acc ++ items,
      else:
        collect_organization_edges(data, method, selector, limit, next, acc ++ items, pages + 1)
  end

  defp organization_endpoints(source, document_count, note_count) do
    resources = Ecto.UUID.generate() |> String.slice(0, 24)
    versions = Ecto.UUID.generate() |> String.slice(0, 24)

    Fixtures.with_owner(fn ->
      documents =
        for index <- organization_indices(document_count) do
          KnowledgeFixtures.insert_document!(source, %{
            resource_id: Ecto.UUID.dump!(organization_id(resources, index)),
            resource_version_id: Ecto.UUID.dump!(organization_id(versions, index))
          })
        end

      notes =
        for index <- organization_indices(note_count) do
          position = document_count + index

          row = %{
            resource_id: Ecto.UUID.dump!(organization_id(resources, position)),
            resource_version_id: Ecto.UUID.dump!(organization_id(versions, position)),
            vault_id: source.vault_id
          }

          KnowledgeFixtures.insert_note!(MigrationRepo, source, row)
        end

      {documents, notes}
    end)
  end

  defp organization_indices(0), do: []
  defp organization_indices(count), do: 1..count

  defp organization_id(prefix, index),
    do:
      prefix <>
        (index |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(12, "0"))

  defp organization_tombstone(resource_id, deleted?) do
    Fixtures.with_owner(fn ->
      statement = if deleted?, do: "CURRENT_TIMESTAMP", else: "NULL"

      query!(MigrationRepo, "UPDATE content.resources SET deleted_at=#{statement} WHERE id=$1", [
        resource_id
      ])
    end)
  end

  defp assert_organization_error(result, code) do
    assert {:error, %Error{code: ^code, message: nil, details: %{}} = error} = result
    assert error.details == %{}
    refute inspect(error) =~ "CANARY"
  end

  defp edge(data) do
    {:ok, edge} =
      Relationship.new(%{
        relationship_id: Ecto.UUID.generate(),
        source_resource_id: id(data.first.resource_id),
        target_resource_id: id(data.second.resource_id),
        owner_scope_id: data.context.owner_scope_id,
        classification: :private,
        type: :references
      })

    edge
  end

  defp with_grants(fun),
    do:
      KnowledgeTestGrants.with_grants(["relationships"], fn ->
        KnowledgeTestGrants.with_organization_delete_grants(fun)
      end)

  defp audits(context),
    do:
      Fixtures.with_owner(fn ->
        query!(
          MigrationRepo,
          "SELECT operation,metadata FROM audit.events WHERE correlation_id=$1 ORDER BY occurred_at,id",
          [Ecto.UUID.dump!(context.correlation_id)]
        ).rows
      end)

  defp id(value), do: Ecto.UUID.load!(value)
end
