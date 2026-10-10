defmodule Singularity.Storage.Postgres.TagRepositoryTest do
  use Singularity.Storage.DataCase, async: false
  @moduletag :integration
  alias Singularity.Core.{Error, OrganizationPage, OrganizationPageQuery, Tag}

  alias Singularity.Storage.{
    Fixtures,
    KnowledgeFixtures,
    KnowledgeTestGrants,
    MigrationRepo,
    ScopedRepo
  }

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

  test "scoped tag resolution retains canonical identity and audits only creation", c do
    grants(fn ->
      first = tag(c.context, "  Straße  ")

      assert {:ok, ^first} =
               scoped(c, fn context ->
                 assert {:error, %Error{code: :invalid}} = TagRepository.resolve(context, first)

                 for forged <- [
                       %{first | normalized_key: "forged"},
                       %{first | owner_scope_id: Ecto.UUID.load!(c.two.vault_id)}
                     ] do
                   assert_private_error(
                     scoped_call(:resolve_in_scope, [context, forged]),
                     :invalid
                   )
                 end

                 assert {:ok, ^first} = scoped_call(:resolve_in_scope, [context, first])
                 scoped_call(:resolve_in_scope, [context, tag(context, "STRASSE")])
               end)

      assert audits(c) == ["knowledge.tag_created"]
    end)
  end

  test "scoped attach is idempotent and shares the existing transaction", c do
    grants(fn ->
      {:ok, stored} = TagRepository.resolve(c.context, tag(c.context))

      assert :ok =
               scoped(c, fn context ->
                 assert {:error, %Error{code: :invalid}} =
                          TagRepository.attach(context, c.resource_id, stored.tag_id)

                 assert :ok =
                          scoped_call(:attach_in_scope, [context, c.resource_id, stored.tag_id])

                 scoped_call(:attach_in_scope, [context, c.resource_id, stored.tag_id])
               end)

      assert {:ok, [^stored]} = TagRepository.list(c.context, c.resource_id)
      assert Enum.sort(audits(c)) == ~w(knowledge.tag_attached knowledge.tag_created)
    end)
  end

  test "scoped detach is idempotent and audits the actual removal", c do
    grants(fn ->
      {:ok, stored} = TagRepository.resolve(c.context, tag(c.context))
      assert :ok = TagRepository.attach(c.context, c.resource_id, stored.tag_id)

      assert :ok =
               scoped(c, fn context ->
                 assert {:error, %Error{code: :invalid}} =
                          TagRepository.detach(context, c.resource_id, stored.tag_id)

                 assert :ok =
                          scoped_call(:detach_in_scope, [context, c.resource_id, stored.tag_id])

                 scoped_call(:detach_in_scope, [context, c.resource_id, stored.tag_id])
               end)

      assert {:ok, []} = TagRepository.list(c.context, c.resource_id)

      assert Enum.sort(audits(c)) ==
               ~w(knowledge.tag_attached knowledge.tag_created knowledge.tag_detached)
    end)
  end

  test "outer scoped rollback removes tag assignment and audit effects", c do
    grants(fn ->
      candidate = tag(c.context, "CANARY_SCOPED_ROLLBACK")

      assert {:error, :organization_rollback} =
               scoped(c, fn context ->
                 assert {:ok, ^candidate} = scoped_call(:resolve_in_scope, [context, candidate])

                 assert :ok =
                          scoped_call(:attach_in_scope, [context, c.resource_id, candidate.tag_id])

                 {:error, :organization_rollback}
               end)

      Fixtures.with_owner(fn ->
        assert %{rows: [[0, 0]]} =
                 query!(
                   MigrationRepo,
                   "SELECT (SELECT count(*) FROM content.tags WHERE id=$1), (SELECT count(*) FROM content.resource_tags WHERE tag_id=$1)",
                   [Ecto.UUID.dump!(candidate.tag_id)]
                 )
      end)

      assert audits(c) == []
    end)
  end

  test "new scoped seams require matching principal and owner GUCs", c do
    grants(fn ->
      {:ok, stored} = TagRepository.resolve(c.context, tag(c.context))
      query = organization_query(%{limit: 1})

      calls = [
        {:resolve_in_scope, [tag(c.context, "CANARY_SCOPE_MISMATCH")]},
        {:attach_in_scope, [c.resource_id, stored.tag_id]},
        {:detach_in_scope, [c.resource_id, stored.tag_id]},
        {:list_page_in_scope, [c.resource_id, query, [:asset]]},
        {:browse_in_scope, [stored.tag_id, query, [:asset]]}
      ]

      for {method, arguments} <- calls do
        assert_private_error(scoped_call(method, [c.context | arguments]), :invalid)

        assert {:ok, :ok} =
                 RequestRepo.transaction(fn ->
                   assert_private_error(scoped_call(method, [c.context | arguments]), :invalid)
                   :ok
                 end)

        for malformed <- [
              %{c.context | principal_id: Ecto.UUID.load!(c.two.principal_id)},
              %{c.context | owner_scope_id: Ecto.UUID.load!(c.two.vault_id)}
            ] do
          assert :ok =
                   scoped(c, fn _context ->
                     assert_private_error(scoped_call(method, [malformed | arguments]), :invalid)
                     :ok
                   end)
        end
      end

      assert audits(c) == ["knowledge.tag_created"]
    end)
  end

  test "resource tag pages traverse all 101 tags using the last returned UUID", c do
    grants(fn ->
      expected = seed_organization_tags(c, 101)
      selector = c.resource_id

      assert {:ok, %OrganizationPage{items: first, next_cursor: cursor}} =
               organization_page(c, :list_page_in_scope, selector, %{limit: 20}, [:asset])

      assert first == Enum.take(expected, 20)
      assert is_binary(cursor)
      assert {:ok, last} = decode_organization_cursor(cursor, c.context, selector, :resource_tags)
      assert last == List.last(first).tag_id

      assert {:ok, %OrganizationPage{items: changed_limit}} =
               organization_page(c, :list_page_in_scope, selector, %{limit: 1, cursor: cursor}, [
                 :asset
               ])

      assert changed_limit == [Enum.at(expected, 20)]
      assert collect_organization_tags(c, selector, 20) == expected

      assert_private_error(
        organization_page(c, :list_page_in_scope, selector, %{limit: 20, cursor: cursor}, [:note]),
        :not_found
      )

      for limit <- [1, 50] do
        assert {:ok, %OrganizationPage{items: items}} =
                 organization_page(c, :list_page_in_scope, selector, %{limit: limit}, [:asset])

        assert items == Enum.take(expected, limit)
      end
    end)
  end

  test "tag browse filters disallowed kinds before SQL limit and continuation", c do
    source = KnowledgeFixtures.source!()

    c = %{
      c
      | one: source,
        context: context(source),
        resource_id: Ecto.UUID.load!(source.resource_id)
    }

    {excluded, permitted} = organization_documents_and_notes(source, 4, 3)

    grants(fn ->
      {:ok, stored} = TagRepository.resolve(c.context, tag(c.context, "CANARY_BROWSE"))

      for row <- excluded ++ permitted,
          do:
            assert(
              :ok ==
                TagRepository.attach(c.context, Ecto.UUID.load!(row.resource_id), stored.tag_id)
            )

      expected =
        Enum.map(permitted, &%{resource_id: Ecto.UUID.load!(&1.resource_id), kind: :note})

      assert {:ok, %OrganizationPage{items: first, next_cursor: cursor}} =
               organization_page(c, :browse_in_scope, stored.tag_id, %{limit: 2}, [:note])

      assert first == Enum.take(expected, 2)

      assert {:ok, last} =
               decode_organization_cursor(cursor, c.context, stored.tag_id, :tag_resources)

      assert last == List.last(first).resource_id

      assert {:ok, %OrganizationPage{items: [last_item], next_cursor: :done}} =
               organization_page(
                 c,
                 :browse_in_scope,
                 stored.tag_id,
                 %{limit: 2, cursor: cursor},
                 [:note]
               )

      assert last_item == List.last(expected)

      assert {:ok, %OrganizationPage{items: [], next_cursor: :done}} =
               organization_page(c, :browse_in_scope, stored.tag_id, %{limit: 2}, [])

      assert {:ok, %OrganizationPage{items: [], next_cursor: :done}} =
               organization_page(
                 c,
                 :browse_in_scope,
                 stored.tag_id,
                 %{limit: 2, cursor: cursor},
                 [:document]
               )
    end)
  end

  test "tag browse traverses all 101 resources without a hidden legacy limit", c do
    source = KnowledgeFixtures.source!()

    c = %{
      c
      | one: source,
        context: context(source),
        resource_id: Ecto.UUID.load!(source.resource_id)
    }

    {_excluded, notes} = organization_documents_and_notes(source, 0, 101)

    grants(fn ->
      {:ok, stored} = TagRepository.resolve(c.context, tag(c.context, "CANARY_BROWSE_ALL"))

      for row <- notes,
          do:
            assert(
              :ok ==
                TagRepository.attach(c.context, Ecto.UUID.load!(row.resource_id), stored.tag_id)
            )

      expected = Enum.map(notes, &%{resource_id: Ecto.UUID.load!(&1.resource_id), kind: :note})
      assert collect_organization_resources(c, stored.tag_id, 20) == expected

      for limit <- [1, 50] do
        assert {:ok, %OrganizationPage{items: items, next_cursor: cursor}} =
                 organization_page(c, :browse_in_scope, stored.tag_id, %{limit: limit}, [:note])

        assert items == Enum.take(expected, limit)

        assert {:ok, last} =
                 decode_organization_cursor(cursor, c.context, stored.tag_id, :tag_resources)

        assert last == List.last(items).resource_id
      end

      assert {:ok, %OrganizationPage{next_cursor: cursor}} =
               organization_page(c, :browse_in_scope, stored.tag_id, %{limit: 20}, [:note])

      assert {:ok, %OrganizationPage{items: [next_item]}} =
               organization_page(
                 c,
                 :browse_in_scope,
                 stored.tag_id,
                 %{limit: 1, cursor: cursor},
                 [:note]
               )

      assert next_item == Enum.at(expected, 20)
    end)
  end

  test "browse pages omit tombstones and expose restored endpoints without changing tags", c do
    source = KnowledgeFixtures.source!()

    c = %{
      c
      | one: source,
        context: context(source),
        resource_id: Ecto.UUID.load!(source.resource_id)
    }

    {_excluded, [note]} = organization_documents_and_notes(source, 0, 1)

    grants(fn ->
      {:ok, stored} = TagRepository.resolve(c.context, tag(c.context))

      assert :ok =
               TagRepository.attach(c.context, Ecto.UUID.load!(note.resource_id), stored.tag_id)

      expected = [%{resource_id: Ecto.UUID.load!(note.resource_id), kind: :note}]

      assert {:ok, %OrganizationPage{items: ^expected, next_cursor: :done}} =
               organization_page(c, :browse_in_scope, stored.tag_id, %{}, [:note])

      set_organization_deleted(note.resource_id, true)

      assert {:ok, %OrganizationPage{items: [], next_cursor: :done}} =
               organization_page(c, :browse_in_scope, stored.tag_id, %{}, [:note])

      assert_private_error(
        organization_page(c, :list_page_in_scope, Ecto.UUID.load!(note.resource_id), %{}, [:note]),
        :not_found
      )

      set_organization_deleted(note.resource_id, false)

      assert {:ok, %OrganizationPage{items: ^expected, next_cursor: :done}} =
               organization_page(c, :browse_in_scope, stored.tag_id, %{}, [:note])
    end)
  end

  test "paged selectors and cursors do not disclose foreign or wrong-context rows", c do
    grants(fn ->
      tags = seed_organization_tags(c, 3)

      assert {:ok, %OrganizationPage{next_cursor: cursor}} =
               organization_page(c, :list_page_in_scope, c.resource_id, %{limit: 1}, [:asset])

      for selector <- [Ecto.UUID.generate(), Ecto.UUID.load!(c.two.resource_id)] do
        assert_private_error(
          organization_page(c, :list_page_in_scope, selector, %{}, [:asset]),
          :not_found
        )
      end

      foreign_context = context(c.two)

      {:ok, foreign_tag} =
        TagRepository.resolve(foreign_context, tag(foreign_context, "CANARY_FOREIGN_TAG"))

      for selector <- [Ecto.UUID.generate(), foreign_tag.tag_id] do
        assert_private_error(
          organization_page(c, :browse_in_scope, selector, %{}, [:asset]),
          :not_found
        )
      end

      assert_private_error(
        organization_page(c, :browse_in_scope, hd(tags).tag_id, %{limit: 1, cursor: cursor}, [
          :asset
        ]),
        :invalid
      )

      same_owner_note = KnowledgeFixtures.note!(c.one)

      assert_private_error(
        organization_page(
          c,
          :list_page_in_scope,
          Ecto.UUID.load!(same_owner_note.resource_id),
          %{limit: 1, cursor: cursor},
          [:note]
        ),
        :invalid
      )

      other = %{c | context: foreign_context, resource_id: Ecto.UUID.load!(c.two.resource_id)}

      assert_private_error(
        organization_page(
          other,
          :list_page_in_scope,
          other.resource_id,
          %{limit: 1, cursor: cursor},
          [:asset]
        ),
        :invalid
      )

      assert_private_error(
        organization_page(
          c,
          :list_page_in_scope,
          c.resource_id,
          %{limit: 1, cursor: cursor <> "x"},
          [:asset]
        ),
        :invalid
      )
    end)
  end

  test "paged inputs reject forged queries and kind filters without returning content", c do
    grants(fn ->
      {:ok, stored} = TagRepository.resolve(c.context, tag(c.context))

      for {method, selector} <- [
            {:list_page_in_scope, c.resource_id},
            {:browse_in_scope, stored.tag_id}
          ] do
        for query <- [
              %{limit: 1, cursor: nil},
              %{organization_query(%{}) | limit: 51},
              Map.put(organization_query(%{}), :owner_scope_id, c.context.owner_scope_id)
            ] do
          assert_private_error(
            scoped(c, &scoped_call(method, [&1, selector, query, [:asset]])),
            :invalid
          )
        end

        for kinds <- [nil, [:unknown], [:asset, :asset], [:asset | :tail]] do
          assert_private_error(
            scoped(c, &scoped_call(method, [&1, selector, organization_query(%{}), kinds])),
            :invalid
          )
        end
      end
    end)
  end

  defp scoped(c, fun) do
    ScopedRepo.transact(
      c.context.repo,
      %{principal_id: c.context.principal_id, vault_id: c.context.owner_scope_id},
      fn repo -> fun.(%{c.context | repo: repo}) end
    )
  end

  defp scoped_call(method, arguments), do: apply(TagRepository, method, arguments)

  defp organization_query(params) do
    assert {:ok, query} = OrganizationPageQuery.new(params)
    query
  end

  defp organization_page(c, method, selector, params, kinds),
    do: scoped(c, &scoped_call(method, [&1, selector, organization_query(params), kinds]))

  defp decode_organization_cursor(cursor, context, selector, operation) do
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

  defp seed_organization_tags(c, count) do
    prefix = Ecto.UUID.generate() |> String.slice(0, 24)

    for index <- 1..count do
      candidate = %{tag(c.context, "tag #{index}") | tag_id: organization_id(prefix, index)}
      assert {:ok, stored} = TagRepository.resolve(c.context, candidate)
      assert :ok = TagRepository.attach(c.context, c.resource_id, stored.tag_id)
      %{tag_id: stored.tag_id, display_value: stored.display_value}
    end
  end

  defp collect_organization_tags(c, selector, limit, cursor \\ nil, acc \\ [], pages \\ 0) do
    assert pages < 10

    assert {:ok, %OrganizationPage{items: items, next_cursor: next}} =
             organization_page(
               c,
               :list_page_in_scope,
               selector,
               %{limit: limit, cursor: cursor},
               [:asset]
             )

    assert length(items) <= limit

    if next == :done,
      do: acc ++ items,
      else: collect_organization_tags(c, selector, limit, next, acc ++ items, pages + 1)
  end

  defp collect_organization_resources(c, selector, limit, cursor \\ nil, acc \\ [], pages \\ 0) do
    assert pages < 10

    assert {:ok, %OrganizationPage{items: items, next_cursor: next}} =
             organization_page(c, :browse_in_scope, selector, %{limit: limit, cursor: cursor}, [
               :note
             ])

    assert length(items) <= limit

    if next == :done,
      do: acc ++ items,
      else: collect_organization_resources(c, selector, limit, next, acc ++ items, pages + 1)
  end

  defp organization_documents_and_notes(source, document_count, note_count) do
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

  defp set_organization_deleted(resource_id, deleted?) do
    Fixtures.with_owner(fn ->
      statement = if deleted?, do: "CURRENT_TIMESTAMP", else: "NULL"

      query!(MigrationRepo, "UPDATE content.resources SET deleted_at=#{statement} WHERE id=$1", [
        resource_id
      ])
    end)
  end

  defp assert_private_error(result, code) do
    assert {:error, %Error{code: ^code, message: nil, details: %{}} = error} = result
    assert error.details == %{}
    refute inspect(error) =~ "CANARY"
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
