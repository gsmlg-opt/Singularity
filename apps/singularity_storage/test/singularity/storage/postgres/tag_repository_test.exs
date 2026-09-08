defmodule Singularity.Storage.Postgres.TagRepositoryTest do
  use Singularity.Storage.DataCase, async: false
  @moduletag :integration
  alias Singularity.Core.{Error, Tag}
  alias Singularity.Storage.{Fixtures, KnowledgeTestGrants, MigrationRepo}
  alias Singularity.Storage.Postgres.TagRepository
  alias Singularity.Storage.Schema.Audit.Event

  defmodule AuditFailureRepo do
    alias Singularity.Storage.RequestRepo
    alias Singularity.Storage.Schema.Audit.Event
    defdelegate __adapter__(), to: RequestRepo
    defdelegate get_dynamic_repo(), to: RequestRepo
    defdelegate in_transaction?(), to: RequestRepo
    defdelegate transaction(fun, options), to: RequestRepo
    defdelegate rollback(reason), to: RequestRepo
    defdelegate one(query), to: RequestRepo
    defdelegate all(query), to: RequestRepo
    defdelegate exists?(query), to: RequestRepo
    defdelegate insert_all(schema, entries, options), to: RequestRepo
    defdelegate delete_all(query), to: RequestRepo

    def insert(%Ecto.Changeset{data: %Event{}} = changeset) do
      true = RequestRepo.in_transaction?()
      tag_id = Ecto.Changeset.get_field(changeset, :target_id)

      %{rows: [[1]]} =
        Ecto.Adapters.SQL.query!(
          RequestRepo,
          "SELECT count(*) FROM content.tags WHERE id=$1",
          [Ecto.UUID.dump!(tag_id)],
          log: false
        )

      send(self(), {:audit_rejected_after_tag_insert, tag_id})
      {:error, Ecto.Changeset.add_error(changeset, :metadata, "CANARY_AUDIT_REJECTION")}
    end

    def insert(changeset), do: RequestRepo.insert(changeset)
    def insert(%Ecto.Changeset{data: %Event{}} = changeset, _options), do: insert(changeset)
    def insert(changeset, options), do: RequestRepo.insert(changeset, options)
  end

  setup do
    %{one: one, two: two} = Fixtures.two_vaults!()
    %{one: one, two: two, context: context(one), resource_id: Ecto.UUID.load!(one.resource_id)}
  end

  test "real audit changeset accepts tag operations and string keyed UUID metadata", c do
    for operation <- ~w(knowledge.tag_created knowledge.tag_attached knowledge.tag_detached) do
      changeset =
        Event.append_changeset(%Event{}, %{
          id: Ecto.UUID.generate(),
          vault_id: c.context.owner_scope_id,
          actor_kind: :principal,
          principal_id: c.context.principal_id,
          operation: operation,
          result: :completed,
          classification: :private,
          correlation_id: c.context.correlation_id,
          target_type: "tag",
          target_id: Ecto.UUID.generate(),
          metadata: %{"resource_id" => c.resource_id},
          occurred_at: DateTime.utc_now(:microsecond)
        })

      assert changeset.valid?, inspect(changeset.errors)
    end
  end

  test "normalized replay retains the first UUID and spelling with one audit per identity", c do
    grants(fn ->
      first = tag(c.context, "  Straße  ")
      assert {:ok, ^first} = TagRepository.resolve(c.context, first)
      assert {:ok, ^first} = TagRepository.resolve(c.context, tag(c.context, "STRASSE"))
      assert audits(c) == ["knowledge.tag_created"]

      accented = tag(c.context, "  École  ")
      assert {:ok, ^accented} = TagRepository.resolve(c.context, accented)
      assert {:ok, ^accented} = TagRepository.resolve(c.context, tag(c.context, "E\u0301COLE"))
      assert accented.display_value == "École"
      assert audits(c) == ["knowledge.tag_created", "knowledge.tag_created"]
    end)
  end

  test "assignment replay and missing detach do not produce duplicate audit", c do
    grants(fn ->
      {:ok, tag} = TagRepository.resolve(c.context, tag(c.context))
      assert :ok = TagRepository.detach(c.context, c.resource_id, tag.tag_id)
      assert :ok = TagRepository.attach(c.context, c.resource_id, tag.tag_id)
      assert :ok = TagRepository.attach(c.context, c.resource_id, tag.tag_id)
      assert {:ok, [^tag]} = TagRepository.list(c.context, c.resource_id)
      assert :ok = TagRepository.detach(c.context, c.resource_id, tag.tag_id)
      assert :ok = TagRepository.detach(c.context, c.resource_id, tag.tag_id)
      assert {:ok, []} = TagRepository.list(c.context, c.resource_id)

      assert Enum.sort(audits(c)) ==
               ~w(knowledge.tag_attached knowledge.tag_created knowledge.tag_detached)
    end)
  end

  test "forged keys owners and identifiers fail closed with private errors", c do
    grants(fn ->
      candidate = tag(c.context, "CANARY_TAG_SECRET")

      for forged <- [
            %{candidate | normalized_key: "forged"},
            %{candidate | display_value: ""},
            %{candidate | owner_scope_id: Ecto.UUID.load!(c.two.vault_id)}
          ] do
        assert {:error, %Error{message: nil, details: %{}}} =
                 TagRepository.resolve(c.context, forged)
      end

      assert {:error, %Error{}} = TagRepository.attach(c.context, "bad", candidate.tag_id)
      assert audits(c) == []
    end)
  end

  test "uppercase authenticated context identifiers are rejected before persistence", c do
    grants(fn ->
      for field <- [:principal_id, :owner_scope_id, :correlation_id] do
        malformed = Map.update!(c.context, field, &String.upcase/1)

        assert {:error, %Error{code: :invalid, message: nil, details: %{}}} =
                 TagRepository.list(malformed, c.resource_id)
      end

      assert audits(c) == []
    end)
  end

  test "assignments hide another owner and deleted resources", c do
    grants(fn ->
      {:ok, tag} = TagRepository.resolve(c.context, tag(c.context))
      other = Ecto.UUID.load!(c.two.resource_id)

      assert {:error, %Error{code: :not_found}} =
               TagRepository.attach(c.context, other, tag.tag_id)

      assert {:error, %Error{code: :not_found}} = TagRepository.list(c.context, other)
      assert :ok = TagRepository.attach(c.context, c.resource_id, tag.tag_id)

      Fixtures.with_owner(fn ->
        query!(
          MigrationRepo,
          "UPDATE content.resources SET deleted_at=CURRENT_TIMESTAMP WHERE id=$1",
          [c.one.resource_id]
        )
      end)

      assert {:error, %Error{code: :not_found}} = TagRepository.list(c.context, c.resource_id)

      assert {:error, %Error{code: :not_found}} =
               TagRepository.attach(c.context, c.resource_id, tag.tag_id)
    end)
  end

  test "lists are bounded to 100 tags in stable UUID order", c do
    grants(fn ->
      tags =
        for index <- 1..101 do
          {:ok, tag} = TagRepository.resolve(c.context, tag(c.context, "tag #{index}"))
          assert :ok = TagRepository.attach(c.context, c.resource_id, tag.tag_id)
          tag
        end

      expected = tags |> Enum.sort_by(& &1.tag_id) |> Enum.take(100)
      assert {:ok, ^expected} = TagRepository.list(c.context, c.resource_id)
    end)
  end

  test "audit rejection rolls back tag creation without exposing spelling", c do
    # Ecto SQL resolves registry metadata directly; this alias shares RequestRepo's transaction.
    {:ok, bridge} = Agent.start_link(fn -> nil end, name: AuditFailureRepo)

    :ok =
      Ecto.Repo.Registry.associate(
        bridge,
        AuditFailureRepo,
        Ecto.Adapter.lookup_meta(RequestRepo)
      )

    on_exit(fn -> if Process.alive?(bridge), do: Agent.stop(bridge) end)

    grants(fn ->
      candidate = tag(c.context, "CANARY_TAG_SECRET")

      assert {:error, %Error{message: nil, details: %{}}} =
               TagRepository.resolve(%{c.context | repo: AuditFailureRepo}, candidate)

      candidate_id = candidate.tag_id
      assert_received {:audit_rejected_after_tag_insert, ^candidate_id}

      Fixtures.with_owner(fn ->
        assert %{rows: [[0]]} =
                 query!(MigrationRepo, "SELECT count(*) FROM content.tags WHERE id=$1", [
                   Ecto.UUID.dump!(candidate.tag_id)
                 ])
      end)

      assert audits(c) == []
    end)
  end

  defp context(source),
    do: %{
      repo: RequestRepo,
      principal_id: Ecto.UUID.load!(source.principal_id),
      owner_scope_id: Ecto.UUID.load!(source.vault_id),
      correlation_id: Ecto.UUID.generate()
    }

  defp tag(context, display \\ "CANARY_TAG_SECRET") do
    {:ok, tag} =
      Tag.new(%{
        tag_id: Ecto.UUID.generate(),
        owner_scope_id: context.owner_scope_id,
        classification: :private,
        display_value: display
      })

    tag
  end

  defp grants(fun),
    do:
      KnowledgeTestGrants.with_grants(~w(tags resource_tags), fn ->
        KnowledgeTestGrants.with_organization_delete_grants(fun)
      end)

  defp audits(c) do
    Fixtures.with_owner(fn ->
      %{rows: rows} =
        query!(
          MigrationRepo,
          "SELECT operation, metadata FROM audit.events WHERE correlation_id=$1 ORDER BY operation",
          [Ecto.UUID.dump!(c.context.correlation_id)]
        )

      for [operation, metadata] <- rows do
        refute inspect(metadata) =~ "CANARY"
        refute Map.has_key?(metadata, "display_value")
        refute Map.has_key?(metadata, "normalized_key")
        operation
      end
    end)
  end
end
