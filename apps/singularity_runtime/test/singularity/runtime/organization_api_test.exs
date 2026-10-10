defmodule Singularity.Runtime.OrganizationApiTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.{Error, OrganizationPage, OrganizationPageQuery, Relationship, Tag}
  alias Singularity.Runtime.{Api, SessionContext}
  alias Singularity.Runtime.DTO.Session

  @session "00000000-0000-4000-8000-000000009001"
  @account "00000000-0000-4000-8000-000000009002"
  @principal "00000000-0000-4000-8000-000000009003"
  @owner "00000000-0000-4000-8000-000000009004"
  @resource "00000000-0000-4000-8000-000000009005"
  @target "00000000-0000-4000-8000-000000009006"
  @version "00000000-0000-4000-8000-000000009007"
  @tag_id "00000000-0000-4000-8000-000000009008"
  @edge "00000000-0000-4000-8000-000000009009"
  @other "00000000-0000-4000-8000-00000000900a"
  @uppercase "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
  @operations [
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
  @page_dto Singularity.Runtime.DTO.OrganizationPage
  @tag_dto Singularity.Runtime.DTO.OrganizationTag
  @resource_dto Singularity.Runtime.DTO.OrganizationResource
  @edge_dto Singularity.Runtime.DTO.OrganizationRelationship

  # Configured facade callbacks are unit-only. These contracts do not establish
  # current capabilities, selector visibility, transaction/lock behavior, SQL
  # paging, cursor MAC/owner binding, canonical mutation audit or live custody.
  for operation <- @operations do
    @operation operation

    test "public #{@operation} rejects a noncanonical selector before production dispatch" do
      args = public_args(@operation)

      for invalid <- [nil, "invalid", @uppercase, <<0::128>>] do
        assert {:error, :invalid} = apply(Api, @operation, List.replace_at(args, 1, invalid))
      end
    end

    test "configured #{@operation} dispatches exact authenticated context and returns owner-free values" do
      assert_success(@operation, call(@operation, success(@operation)))
      assert_callback(@operation)
    end

    test "#{@operation} exposes stable sanitized errors and fails closed on callback faults" do
      for code <- [
            :invalid,
            :not_found,
            :forbidden,
            :conflict,
            :unauthenticated,
            :vault_locked,
            :integrity_failure,
            :storage_unavailable
          ] do
        error =
          Error.new(code,
            message: "PRIVATE_TAG_EDGE",
            details: %{body: "PRIVATE_CONTENT"},
            retryable?: true
          )

        assert {:error, ^code} = call(@operation, {:error, error})
        assert_callback(@operation)
        assert {:error, ^code} = call(@operation, {:error, code})
        assert_callback(@operation)
      end

      for reason <- [
            :unknown,
            "PRIVATE_EXCEPTION",
            %{code: :forbidden, owner: @owner},
            %{Error.new(:not_found) | code: :unknown},
            {:authorization_denial, Error.new(:forbidden)}
          ] do
        assert {:error, :storage_unavailable} = call(@operation, {:error, reason})
        assert_callback(@operation)
      end

      for config <- [%{}, %{@operation => nil}, %{@operation => :missing}, nil, []] do
        assert {:error, :invalid} = configured(@operation, config)
        refute_received {:organization_api_call, _, _}
      end

      assert {:error, :storage_unavailable} =
               configured(@operation, %{@operation => fn -> :ok end})

      for failure <- [:raise, :throw, :exit] do
        assert {:error, :storage_unavailable} =
                 call(@operation, fn ->
                   case failure do
                     :raise -> raise "PRIVATE_TAG_EDGE"
                     :throw -> throw("PRIVATE_TAG_EDGE")
                     :exit -> exit("PRIVATE_TAG_EDGE")
                   end
                 end)

        assert_callback(@operation)
      end
    end
  end

  test "every configured operation rejects malformed Session before callback" do
    for operation <- @operations,
        {field, value} <- [
          session_id: nil,
          session_id: @uppercase,
          account_id: "bad",
          principal_id: @uppercase,
          vault_id: "bad",
          expires_at: nil,
          principal_authorization_epoch: -1,
          vault_authorization_epoch: nil,
          authorization_epoch: "3",
          unlocked?: :yes
        ] do
      assert {:error, :integrity_failure} =
               call(operation, success(operation), :default, Map.put(session(), field, value))

      refute_received {:organization_api_call, _, _}
    end

    for operation <- @operations, value <- [nil, %{}, Map.from_struct(session())] do
      assert {:error, :invalid} = call(operation, success(operation), :default, value)
      refute_received {:organization_api_call, _, _}
    end
  end

  test "all configured selectors are canonical and detach validates both resource and tag IDs" do
    for operation <- @operations, invalid <- [nil, "bad", @uppercase, <<0::128>>] do
      args = public_args(operation)
      config = config(operation, success(operation))

      assert {:error, :invalid} =
               apply(Api, operation, [config | List.replace_at(args, 1, invalid)])

      refute_received {:organization_api_call, _, _}
    end

    for invalid <- [nil, "bad", @uppercase, <<0::128>>] do
      assert {:error, :invalid} = call(:detach_tag, :ok, invalid)
      refute_received {:organization_api_call, _, _}
    end
  end

  test "list_resource_tags default /2 and explicit /3 public overloads do not confuse Session with config" do
    assert {:error, :invalid} = apply(Api, :list_resource_tags, [session(), "bad"])
    assert {:error, :invalid} = apply(Api, :list_resource_tags, [session(), "bad", %{}])

    assert_success(
      :list_resource_tags,
      call(:list_resource_tags, success(:list_resource_tags), %{})
    )

    assert_callback(:list_resource_tags, %{})
  end

  for operation <- @pages do
    @page_operation operation

    test "#{@page_operation} revalidates canonical typed public Page DTOs with nil terminals" do
      items = [item(@page_operation, 1), item(@page_operation, 2)]
      assert {:ok, public_page} = call(@page_operation, {:ok, terminal(items)}, %{limit: 2})
      assert public_page.__struct__ == @page_dto
      assert public_page.next_cursor == nil
      assert_callback(@page_operation, %{limit: 2})

      assert {:ok, ^public_page} = call(@page_operation, {:ok, public_page}, %{limit: 2})
      assert_callback(@page_operation, %{limit: 2})
    end

    test "#{@page_operation} uses exact fixed query keys and bounded limits/cursors before callback" do
      for params <- [
            %{},
            [],
            [limit: 2, cursor: nil],
            %{limit: 1, cursor: nil},
            %{limit: 50, cursor: String.duplicate("c", 2048)},
            %{"limit" => 2, "cursor" => "opaque-cursor"}
          ] do
        assert {:ok, result} = call(@page_operation, {:ok, terminal([])}, params)
        assert result.__struct__ == @page_dto
        assert Map.from_struct(result) == %{items: [], next_cursor: nil}
        assert_callback(@page_operation, params)
      end

      for params <- [
            %{limit: 0},
            %{limit: 51},
            %{limit: "20"},
            %{limit: 20.0},
            %{cursor: ""},
            %{cursor: " \t"},
            %{cursor: String.duplicate("c", 2049)},
            %{cursor: <<255>>},
            %{cursor: "token" <> <<0>>},
            %{cursor: :done},
            %{:limit => 1, "limit" => 2},
            nil,
            [1],
            %{__struct__: OrganizationPageQuery}
          ] do
        assert {:error, :invalid} = call(@page_operation, success(@page_operation), params)
        refute_received {:organization_api_call, _, _}
      end

      for key <- [
            :owner_scope_id,
            :vault_id,
            :principal_id,
            :selector_id,
            :operation,
            :direction,
            :allowed_kinds,
            :capabilities,
            :classification,
            :q,
            :title
          ],
          client_key <- [key, Atom.to_string(key)] do
        assert {:error, :invalid} =
                 call(@page_operation, success(@page_operation), %{client_key => @owner})

        refute_received {:organization_api_call, _, _}
      end
    end

    test "#{@page_operation} maps Core pages into exact typed items with full continuations and nil terminal" do
      items = [item(@page_operation, 1), item(@page_operation, 2)]
      {:ok, query} = OrganizationPageQuery.new(%{limit: 2})

      {:ok, page} =
        OrganizationPage.new(
          page_operation(@page_operation),
          %{items: items, next_cursor: "next-page"},
          query
        )

      for input <- [page, Map.from_struct(page)] do
        assert {:ok, result} = call(@page_operation, {:ok, input}, %{limit: 2})
        assert result.__struct__ == @page_dto
        assert exact_keys(result) == Enum.sort([:items, :next_cursor])
        assert result.next_cursor == "next-page"
        assert Enum.map(result.items, &Map.from_struct/1) == items
        assert Enum.all?(result.items, &(&1.__struct__ == item_dto(@page_operation)))
        assert_callback(@page_operation, %{limit: 2})
      end

      assert {:ok, terminal_result} = call(@page_operation, {:ok, terminal(items)}, %{limit: 2})
      assert terminal_result.next_cursor == nil
      assert Enum.map(terminal_result.items, &Map.from_struct/1) == items
      assert_callback(@page_operation, %{limit: 2})
    end

    test "#{@page_operation} rejects partial unordered oversized forged and wrong-operation server pages" do
      items = [item(@page_operation, 1), item(@page_operation, 2)]
      valid = terminal(items)
      {:ok, query} = OrganizationPageQuery.new(%{limit: 2})
      {:ok, core_page} = OrganizationPage.new(page_operation(@page_operation), valid, query)
      wrong_operation = different_operation(@page_operation)

      malformed = [
        nil,
        [],
        %{},
        Map.delete(valid, :items),
        Map.delete(valid, :next_cursor),
        Map.put(valid, :owner_scope_id, @owner),
        Map.put(valid, :count, 9),
        Map.put(core_page, :body, "PRIVATE_BODY"),
        %{__struct__: OrganizationPage},
        terminal(Enum.reverse(items)),
        terminal([hd(items), hd(items)]),
        terminal(items ++ [item(@page_operation, 3)]),
        terminal([hd(items) | :tail]),
        terminal([item(wrong_operation, 1)]),
        %{items: [], next_cursor: "next-page"},
        %{items: [hd(items)], next_cursor: "next-page"},
        %{items: items, next_cursor: nil},
        %{items: items, next_cursor: ""},
        %{items: items, next_cursor: String.duplicate("c", 2049)}
      ]

      malformed =
        malformed ++
          Enum.map(
            [
              :owner_scope_id,
              :vault_id,
              :classification,
              :capabilities,
              :title,
              :body,
              :original_bytes,
              :ordinal
            ],
            fn field ->
              terminal([Map.put(hd(items), field, "PRIVATE_VALUE")])
            end
          )

      malformed =
        malformed ++
          Enum.map(Map.keys(hd(items)), fn key -> terminal([Map.delete(hd(items), key)]) end)

      malformed = malformed ++ noncanonical_items(@page_operation)

      for input <- malformed do
        assert {:error, :integrity_failure} = call(@page_operation, {:ok, input}, %{limit: 2})
        assert_callback(@page_operation, %{limit: 2})
      end
    end
  end

  test "attach accepts only name while relate accepts only target type and optional exact pin" do
    assert_success(:attach_tag, call(:attach_tag, success(:attach_tag), %{name: "  éCOLE  "}))
    assert_callback(:attach_tag, %{name: "  éCOLE  "})

    for attrs <- [
          %{target_resource_id: @target, type: :related_to},
          %{target_resource_id: @target, target_resource_version_id: nil, type: :related_to}
        ] do
      input = %{core_value(:relate_resource) | target_resource_version_id: nil}
      assert {:ok, result} = call(:relate_resource, {:ok, input}, attrs)
      assert result.__struct__ == @edge_dto
      assert Map.from_struct(result) == %{edge_item(@edge) | target_resource_version_id: nil}
      assert_callback(:relate_resource, attrs)
    end

    for operation <- [:attach_tag, :relate_resource],
        field <- [
          :owner_scope_id,
          :vault_id,
          :principal_id,
          :classification,
          :correlation_id,
          :tag_id,
          :relationship_id,
          :source_resource_id,
          :capabilities,
          :authorize,
          :normalized_key
        ],
        key <- [field, Atom.to_string(field)] do
      attrs = Map.put(default_params(operation), key, @owner)
      assert {:error, :invalid} = call(operation, success(operation), attrs)
      refute_received {:organization_api_call, _, _}
    end

    for attrs <- [
          %{},
          %{name: nil},
          %{name: ""},
          %{name: " \t"},
          %{name: <<255>>},
          %{name: "x" <> <<0>>},
          %{name: String.duplicate("a", 256)}
        ] do
      assert {:error, :invalid} = call(:attach_tag, success(:attach_tag), attrs)
      refute_received {:organization_api_call, _, _}
    end

    for attrs <- [
          %{},
          %{target_resource_id: @resource, type: :related_to},
          %{target_resource_id: @uppercase, type: :related_to},
          %{target_resource_id: @target, type: :unknown},
          %{target_resource_id: @target, type: "related_to"},
          %{target_resource_id: @target, target_resource_version_id: "bad", type: :references}
        ] do
      assert {:error, :invalid} = call(:relate_resource, success(:relate_resource), attrs)
      refute_received {:organization_api_call, _, _}
    end
  end

  test "attach and relate convert only canonical matching owner/private Core values or owner-free values" do
    for operation <- [:attach_tag, :relate_resource] do
      {:ok, result} = call(operation, success(operation))
      assert_callback(operation)
      public = Map.from_struct(result)

      for input <- [result, public] do
        assert_success(operation, call(operation, {:ok, input}))
        assert_callback(operation)
      end

      core = core_value(operation)

      for input <- [
            Map.put(core, :owner_scope_id, @other),
            Map.put(core, :classification, :sensitive),
            Map.put(core, :body, "PRIVATE_BODY"),
            Map.delete(core, :owner_scope_id),
            Map.put(public, :owner_scope_id, @owner),
            Map.put(public, :classification, :private),
            Map.put(public, "tag_id", @tag_id),
            Map.put(result, :secret, "PRIVATE_SECRET")
          ] do
        assert {:error, :integrity_failure} = call(operation, {:ok, input})
        assert_callback(operation)
      end

      for key <- Map.keys(public) do
        assert {:error, :integrity_failure} = call(operation, {:ok, Map.delete(public, key)})
        assert_callback(operation)
      end
    end

    for input <- [
          Map.put(core_value(:attach_tag), :display_value, " École "),
          Map.put(core_value(:attach_tag), :display_value, "E\u0301cole"),
          Map.put(core_value(:attach_tag), :normalized_key, "forged-key"),
          %{tag_id: @uppercase, display_value: "École"}
        ] do
      assert {:error, :integrity_failure} = call(:attach_tag, {:ok, input})
      assert_callback(:attach_tag)
    end

    for input <- [
          Map.put(core_value(:relate_resource), :source_resource_id, @other),
          Map.put(core_value(:relate_resource), :target_resource_id, @other),
          Map.put(core_value(:relate_resource), :target_resource_version_id, @other),
          Map.put(core_value(:relate_resource), :type, :derived_from),
          Map.put(core_value(:relate_resource), :relationship_id, @uppercase)
        ] do
      assert {:error, :integrity_failure} = call(:relate_resource, {:ok, input})
      assert_callback(:relate_resource)
    end
  end

  test "relationship pages preserve directed endpoints all fixed types and nullable pins" do
    for operation <- [:list_outgoing_relationships, :list_backlinks],
        type <- [:related_to, :references, :derived_from],
        pin <- [nil, @version] do
      edge = %{item(operation, 1) | type: type, target_resource_version_id: pin}
      assert {:ok, result} = call(operation, {:ok, terminal([edge])})
      assert [public] = result.items
      assert public.__struct__ == @edge_dto
      assert Map.from_struct(public) == edge
      assert_callback(operation)
    end
  end

  test "detach and unrelate require exact unit success and never leak partial mutation values" do
    for operation <- [:detach_tag, :unrelate_resource],
        malformed <- [
          nil,
          true,
          {:ok, nil},
          {:ok, %{}},
          {:ok, :ok},
          {:ok, core_value(:relate_resource)}
        ] do
      assert {:error, :integrity_failure} = call(operation, malformed)
      assert_callback(operation)
    end
  end

  defp call(operation, result, params \\ :default, session_value \\ session()),
    do: configured(operation, config(operation, result), params, session_value)

  defp configured(operation, config, params \\ :default, session_value \\ session()) do
    args = public_args(operation, params)
    apply(Api, operation, [config | List.replace_at(args, 0, session_value)])
  end

  defp config(operation, result) do
    callback =
      if operation == :unrelate_resource do
        fn context, id -> reply(operation, [context, id], result) end
      else
        fn context, id, params -> reply(operation, [context, id, params], result) end
      end

    %{operation => callback}
  end

  defp reply(operation, args, result) do
    send(self(), {:organization_api_call, operation, args})
    if is_function(result, 0), do: result.(), else: result
  end

  defp public_args(:unrelate_resource, _params), do: [session(), @edge]
  defp public_args(:detach_tag, :default), do: [session(), @resource, @tag_id]
  defp public_args(:detach_tag, params), do: [session(), @resource, params]

  defp public_args(operation, :default),
    do: [session(), selector(operation), default_params(operation)]

  defp public_args(operation, params), do: [session(), selector(operation), params]
  defp public_args(operation), do: public_args(operation, :default)
  defp selector(:browse_resources_by_tag), do: @tag_id
  defp selector(_operation), do: @resource
  defp default_params(:attach_tag), do: %{name: "École"}

  defp default_params(:relate_resource),
    do: %{target_resource_id: @target, target_resource_version_id: @version, type: :related_to}

  defp default_params(_operation), do: %{}

  defp assert_callback(operation, params \\ :default) do
    expected =
      public_args(operation, params)
      |> List.replace_at(0, struct!(SessionContext, Map.from_struct(session())))

    assert_received {:organization_api_call, ^operation, ^expected}
    refute_received {:organization_api_call, _, _}
  end

  defp success(:detach_tag), do: :ok
  defp success(:unrelate_resource), do: :ok

  defp success(operation) when operation in [:attach_tag, :relate_resource],
    do: {:ok, core_value(operation)}

  defp success(operation), do: {:ok, terminal([item(operation, 1)])}
  defp assert_success(operation, :ok) when operation in [:detach_tag, :unrelate_resource], do: :ok

  defp assert_success(operation, {:ok, result})
       when operation in [:attach_tag, :relate_resource] do
    expected =
      if operation == :attach_tag,
        do: %{tag_id: @tag_id, display_value: "École"},
        else: edge_item(@edge)

    dto = if operation == :attach_tag, do: @tag_dto, else: @edge_dto
    assert result.__struct__ == dto
    assert Map.from_struct(result) == expected
  end

  defp assert_success(operation, {:ok, result}) do
    assert result.__struct__ == @page_dto
    assert exact_keys(result) == Enum.sort([:items, :next_cursor])
    assert result.next_cursor == nil
    assert [public] = result.items
    assert public.__struct__ == item_dto(operation)
    assert Map.from_struct(public) == item(operation, 1)
  end

  defp assert_success(_operation, result),
    do: flunk("unexpected organization result: #{inspect(result)}")

  defp core_value(:attach_tag) do
    {:ok, tag} =
      Tag.new(%{
        tag_id: @tag_id,
        owner_scope_id: @owner,
        classification: :private,
        display_value: "École"
      })

    tag
  end

  defp core_value(:relate_resource) do
    {:ok, edge} =
      Relationship.new(
        Map.merge(edge_item(@edge), %{owner_scope_id: @owner, classification: :private})
      )

    edge
  end

  defp page_operation(:list_resource_tags), do: :resource_tags
  defp page_operation(:browse_resources_by_tag), do: :tag_resources
  defp page_operation(:list_outgoing_relationships), do: :outgoing
  defp page_operation(:list_backlinks), do: :incoming
  defp different_operation(:list_resource_tags), do: :browse_resources_by_tag
  defp different_operation(_operation), do: :list_resource_tags
  defp item_dto(:list_resource_tags), do: @tag_dto
  defp item_dto(:browse_resources_by_tag), do: @resource_dto
  defp item_dto(_operation), do: @edge_dto

  defp item(:list_resource_tags, index),
    do: %{tag_id: ordered_id(index), display_value: "École #{index}"}

  defp item(:browse_resources_by_tag, index),
    do: %{
      resource_id: ordered_id(index),
      kind: Enum.at([:asset, :document, :note], rem(index - 1, 3))
    }

  defp item(:list_outgoing_relationships, index), do: edge_item(ordered_id(index))

  defp item(:list_backlinks, index),
    do: %{
      edge_item(ordered_id(index))
      | source_resource_id: @target,
        target_resource_id: @resource
    }

  defp edge_item(id),
    do: %{
      relationship_id: id,
      source_resource_id: @resource,
      target_resource_id: @target,
      target_resource_version_id: @version,
      type: :related_to
    }

  defp terminal(items), do: %{items: items, next_cursor: :done}

  defp ordered_id(index),
    do: "00000000-0000-4000-8000-" <> String.pad_leading(Integer.to_string(index, 16), 12, "0")

  defp exact_keys(value), do: value |> Map.from_struct() |> Map.keys() |> Enum.sort()

  defp noncanonical_items(operation) do
    row = item(operation, 1)

    id_key =
      case operation do
        :list_resource_tags -> :tag_id
        :browse_resources_by_tag -> :resource_id
        _ -> :relationship_id
      end

    rows = [Map.put(row, id_key, @uppercase), Map.put(row, id_key, <<0::128>>)]

    rows =
      case operation do
        :list_resource_tags ->
          rows ++
            Enum.map(
              [" École ", "E\u0301cole", "", "x" <> <<0>>, <<255>>],
              &Map.put(row, :display_value, &1)
            )

        :browse_resources_by_tag ->
          rows ++ [Map.put(row, :kind, "note"), Map.put(row, :kind, :unknown)]

        _ ->
          rows ++
            [
              Map.put(row, :type, :unknown),
              Map.put(row, :type, "references"),
              Map.put(row, :target_resource_id, row.source_resource_id),
              Map.put(row, :target_resource_version_id, @uppercase)
            ]
      end

    Enum.map(rows, &terminal([&1]))
  end

  defp session do
    %Session{
      session_id: @session,
      account_id: @account,
      principal_id: @principal,
      vault_id: @owner,
      expires_at: ~U[2026-10-11 12:30:00Z],
      principal_authorization_epoch: 3,
      vault_authorization_epoch: 5,
      authorization_epoch: 3,
      unlocked?: true
    }
  end
end
