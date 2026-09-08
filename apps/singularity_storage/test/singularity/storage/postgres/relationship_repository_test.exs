defmodule Singularity.Storage.Postgres.RelationshipRepositoryTest do
  use Singularity.Storage.DataCase, async: false
  @moduletag :integration

  alias Singularity.Core.{Error, Relationship}
  alias Singularity.Storage.{Fixtures, KnowledgeFixtures, KnowledgeTestGrants, MigrationRepo}
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
