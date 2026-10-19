defmodule Singularity.Runtime.KnowledgeExportApiTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.Error
  alias Singularity.Runtime.Api
  alias Singularity.Runtime.DTO.Session
  alias Singularity.Runtime.SessionContext

  @export Singularity.Runtime.Knowledge.Export
  @handle Singularity.Runtime.Knowledge.ExportArtifact.Handle
  @session "00000000-0000-4000-8000-000000009101"
  @principal "00000000-0000-4000-8000-000000009102"
  @owner "00000000-0000-4000-8000-000000009103"
  @operation "00000000-0000-4000-8000-000000009104"
  @foreign "00000000-0000-4000-8000-000000009105"
  @canary "PRIVATE_EXPORT_CANARY"
  @digest String.duplicate("a", 64)
  @operations [
    {:export_knowledge, 2, 3},
    {:knowledge_export_entries, 3, 4},
    {:read_knowledge_export_chunk, 4, 5},
    {:close_knowledge_export, 2, 3}
  ]

  # Configured callbacks below prove facade validation, dispatch and output
  # filtering only. A DTO/handle/cursor is not current authority. Real owning
  # session checks and Writer cursor membership belong to Export/Artifact tests.
  defmodule OptionsStruct do
    defstruct include_tombstones: false
  end

  test "only the four specified public operation arity pairs are exported" do
    actual =
      Api.__info__(:functions)
      |> Enum.filter(fn {name, _arity} -> name in Enum.map(@operations, &elem(&1, 0)) end)
      |> Enum.sort()

    expected =
      Enum.flat_map(@operations, fn {name, public, configured} ->
        [{name, public}, {name, configured}]
      end)
      |> Enum.sort()

    assert actual == expected
    refute function_exported?(Api, :export_knowledge, 1)
    refute function_exported?(Api, :knowledge_export, 3)
  end

  for options <- [%{}, %{include_tombstones: false}, %{include_tombstones: true}] do
    @options options
    test "generation accepts exact Core options #{inspect(options)} without adding authority" do
      handle = handle()
      config = recording_config({:ok, handle})
      assert {:ok, ^handle} = call(config, :export_knowledge, [@options])
      assert_received {:called, :export_knowledge, [context, @options]}
      assert_context(context)
      refute_received {:called, _, _}
      assert :ok = validate(:export_knowledge, [@options])
    end
  end

  for key <- [
        :owner_scope_id,
        :owner,
        :vault_id,
        :destination,
        :path,
        :root,
        :storage_root,
        :backup_root,
        :adapter,
        :binding,
        :custody,
        :custodian,
        :clock,
        :deadline,
        :limits,
        :options,
        :task_supervisor
      ] do
    @key key
    test "caller-selected #{@key} is rejected before any configured callback" do
      assert_invalid(:export_knowledge, [%{@key => @canary}])

      assert_invalid(:export_knowledge, [
        %{@key => @canary, :include_tombstones => false}
      ])
    end
  end

  test "generation rejects structs keyword options nonmaps string keys and nonboolean tombstones" do
    for options <- [
          %OptionsStruct{},
          %SessionContext{
            session_id: @session,
            principal_id: @principal,
            vault_id: @owner,
            expires_at: ~U[2099-01-01 00:00:00Z],
            authorization_epoch: 0,
            unlocked?: true
          },
          [],
          [include_tombstones: false],
          nil,
          false,
          0,
          @canary,
          {false},
          %{"include_tombstones" => false},
          %{include_tombstones: nil},
          %{include_tombstones: 0},
          %{include_tombstones: "false"},
          %{include_tombstones: @canary}
        ] do
      assert_invalid(:export_knowledge, [options])
    end
  end

  for key <- [:materializer, :work, :callback, :module, :function, :args, :mfa] do
    @work_key key
    test "caller-selected #{@work_key} cannot select export work" do
      observer = self()
      reference = make_ref()
      canary = fn _, _ -> send(observer, {:unexpected_work, reference}) end

      config = %{
        export_knowledge: fn _, _ -> send(observer, {:unexpected_composition, reference}) end
      }

      for value <- [canary, {__MODULE__, :canary, []}],
          options <- [
            %{@work_key => value},
            %{@work_key => value, :include_tombstones => false}
          ] do
        assert {:error, :invalid} = Api.export_knowledge(config, session_dto(), options)
        refute_received {:unexpected_composition, ^reference}
        refute_received {:unexpected_work, ^reference}
        refute_received :unexpected_mfa_work
      end
    end
  end

  test "strict DTO fields become SessionContext without changing the five-field binding" do
    dto = session_dto()
    config = recording_config({:ok, handle()})
    assert {:ok, _} = call(config, :export_knowledge, [%{}], dto)
    assert_received {:called, :export_knowledge, [context, %{}]}
    assert_context(context)
    assert Map.from_struct(context) == Map.from_struct(dto)
    assert session_binding(context) == {@session, @principal, @owner, 0, 0}
  end

  test "optional canonical account identity is preserved as a hint" do
    dto = %{session_dto() | account_id: @foreign}
    assert {:ok, _} = call(recording_config({:ok, handle()}), :export_knowledge, [%{}], dto)
    assert_received {:called, :export_knowledge, [%SessionContext{account_id: @foreign}, %{}]}
  end

  test "non-DTO sessions never reach callbacks" do
    for session <- [nil, %{}, Map.from_struct(session_dto()), [], @canary] do
      assert {:error, :invalid} =
               call(recording_config(:unexpected), :export_knowledge, [%{}], session)

      refute_received {:called, _, _}
    end
  end

  test "DTO extra or missing fields fail integrity before callbacks" do
    for dto <- [
          Map.put(session_dto(), :host_path, @canary),
          Map.delete(session_dto(), :account_id)
        ] do
      assert_session_integrity(dto)
    end
  end

  test "DTO identity hints must be canonical UUIDs" do
    for field <- [:session_id, :principal_id, :vault_id, :account_id],
        invalid <- [@canary, "00000000-0000-4000-8000-00000000910A", "", 0, false] do
      assert_session_integrity(Map.put(session_dto(), field, invalid))
    end

    for field <- [:session_id, :principal_id, :vault_id] do
      assert_session_integrity(Map.put(session_dto(), field, nil))
    end
  end

  test "DTO epochs datetime and unlock fields retain strict existing types" do
    for field <- [
          :principal_authorization_epoch,
          :vault_authorization_epoch,
          :authorization_epoch
        ],
        invalid <- [nil, -1, 0.0, "0", @canary] do
      assert_session_integrity(Map.put(session_dto(), field, invalid))
    end

    for invalid <- [nil, @canary, ~N[2099-01-01 00:00:00], %{}] do
      assert_session_integrity(%{session_dto() | expires_at: invalid})
    end

    for invalid <- [nil, 1, @canary] do
      assert_session_integrity(%{session_dto() | unlocked?: invalid})
    end
  end

  test "DTO locked state and changed identity epochs remain hints for the configured composition" do
    for dto <- [
          %{session_dto() | unlocked?: false},
          %{session_dto() | principal_id: @foreign},
          %{session_dto() | vault_id: @foreign},
          %{session_dto() | principal_authorization_epoch: 1, authorization_epoch: 1},
          %{session_dto() | vault_authorization_epoch: 1}
        ] do
      assert {:error, :forbidden} =
               call(
                 recording_config({:error, :forbidden}),
                 :close_knowledge_export,
                 [handle()],
                 dto
               )

      assert_received {:called, :close_knowledge_export, [context, _handle]}
      assert Map.from_struct(context) == Map.from_struct(dto)
      refute_received {:called, _, _}
    end
  end

  test "handle has only local routing reference binding and integer deadline fields" do
    handle = handle()
    assert handle.__struct__ == @handle

    assert Enum.sort(Map.keys(Map.from_struct(handle))) == [
             :binding,
             :deadline,
             :operation_ref,
             :owner
           ]

    assert handle.owner == self()
    assert is_reference(handle.operation_ref)
    assert handle.binding == {@session, @principal, @owner, 0, 0}
    assert is_integer(handle.deadline)
    assert :ok = validate(:close_knowledge_export, [handle])
  end

  test "handle Inspect is opaque and JSON encoding is not implemented" do
    handle = handle()
    assert inspect(handle) == "#KnowledgeExport<opaque>"
    assert inspect(handle, structs: true, limit: :infinity) == "#KnowledgeExport<opaque>"
    assert_raise Protocol.UndefinedError, fn -> Jason.encode!(handle) end

    for canary <- [
          @session,
          @principal,
          @owner,
          inspect(handle.owner),
          inspect(handle.operation_ref)
        ] do
      refute inspect(handle) =~ canary
    end
  end

  test "handle enforced fields cannot be omitted by struct construction" do
    for field <- [:owner, :operation_ref, :binding, :deadline] do
      fields = handle() |> Map.from_struct() |> Map.delete(field)
      assert_raise ArgumentError, fn -> struct!(@handle, fields) end
    end
  end

  test "malformed handles fail every delivery operation before callback" do
    handle = handle()

    invalids = [
      nil,
      %{},
      Map.from_struct(handle),
      @canary,
      Map.put(handle, :path, @canary),
      Map.put(handle, :__struct__, OptionsStruct),
      %{handle | owner: @canary},
      %{handle | owner: remote_pid()},
      %{handle | operation_ref: @canary},
      %{handle | deadline: 0.0},
      %{handle | deadline: @canary},
      %{handle | binding: [@session, @principal, @owner, 0, 0]},
      %{handle | binding: {@session, @principal, @owner, 0}},
      %{handle | binding: {@session, @principal, @owner, 0, 0, @canary}},
      %{handle | binding: {@canary, @principal, @owner, 0, 0}},
      %{handle | binding: {@session, @canary, @owner, 0, 0}},
      %{handle | binding: {@session, @principal, @canary, 0, 0}},
      %{handle | binding: {@session, @principal, @owner, -1, 0}},
      %{handle | binding: {@session, @principal, @owner, 0.0, 0}},
      %{handle | binding: {@session, @principal, @owner, 0, -1}},
      %{handle | binding: {@session, @principal, @owner, 0, "0"}}
    ]

    for invalid <- invalids do
      assert_invalid(:knowledge_export_entries, [invalid, nil])
      assert_invalid(:read_knowledge_export_chunk, [invalid, "manifest.json", 0])
      assert_invalid(:close_knowledge_export, [invalid])
    end
  end

  test "entries forwards nil or Writer's exact shaped cursor without inventing membership authority" do
    handle = handle()

    for cursor <- [nil, cursor(), %{cursor() | operation_id: @foreign}] do
      config = recording_config({:ok, page()})

      assert {:ok, %{entries: [], next_cursor: nil}} =
               call(config, :knowledge_export_entries, [handle, cursor])

      assert_received {:called, :knowledge_export_entries, [context, ^handle, ^cursor]}
      assert_context(context)
      refute_received {:called, _, _}
    end
  end

  test "malformed cursor maps structs fields and proofs never reach callbacks" do
    for invalid <- [
          [],
          @canary,
          %OptionsStruct{},
          %{},
          Map.delete(cursor(), :proof),
          Map.put(cursor(), :host_path, @canary),
          %{"operation_id" => @operation, "after" => "manifest.json", "proof" => @digest},
          %{cursor() | operation_id: @canary},
          %{cursor() | after: 0},
          %{cursor() | proof: 0},
          %{cursor() | proof: String.duplicate("A", 64)},
          %{cursor() | proof: String.duplicate("a", 63)}
        ] do
      assert_invalid(:knowledge_export_entries, [handle(), invalid])
    end
  end

  test "chunk dispatch preserves normalized relative path and ordinal including empty-file zero" do
    handle = handle()

    for {path, ordinal, bytes} <- [
          {"manifest.json", 0, ""},
          {"documents/extracted/file.txt", 1, "text"},
          {"assets/file.bin", 42, <<0, 255>>}
        ] do
      assert {:ok, ^bytes} =
               call(recording_config({:ok, bytes}), :read_knowledge_export_chunk, [
                 handle,
                 path,
                 ordinal
               ])

      assert_received {:called, :read_knowledge_export_chunk, [context, ^handle, ^path, ^ordinal]}
      assert_context(context)
      refute_received {:called, _, _}
    end
  end

  test "chunk rejects nonnormalized paths before callback" do
    for path <- [
          nil,
          0,
          [],
          "",
          "/tmp/" <> @canary,
          ".",
          "..",
          "./manifest.json",
          "../manifest.json",
          "assets/../manifest.json",
          "assets/./file.bin",
          "assets//file.bin",
          "assets/",
          "assets\\file.bin",
          "assets/" <> <<0>> <> @canary
        ] do
      assert_invalid(:read_knowledge_export_chunk, [handle(), path, 0])
    end
  end

  test "chunk rejects byte ranges negative ordinals floats strings and canaries before callback" do
    for ordinal <- [-1, 0.0, "0", nil, @canary, {0, 65_536}, %{offset: 0, length: 65_536}] do
      assert_invalid(:read_knowledge_export_chunk, [handle(), "manifest.json", ordinal])
    end
  end

  test "close forwards only SessionContext and the opaque handle and returns exact ok" do
    handle = handle()
    assert :ok = call(recording_config(:ok), :close_knowledge_export, [handle])
    assert_received {:called, :close_knowledge_export, [context, ^handle]}
    assert_context(context)
    refute_received {:called, _, _}
  end

  test "each operation rejects success values belonging to another operation" do
    for {operation, arguments, successes} <- [
          {:export_knowledge, [%{}], [:ok, {:ok, page()}, {:ok, @canary}]},
          {:knowledge_export_entries, [handle(), nil], [:ok, {:ok, handle()}, {:ok, @canary}]},
          {:read_knowledge_export_chunk, [handle(), "manifest.json", 0],
           [:ok, {:ok, handle()}, {:ok, page()}]},
          {:close_knowledge_export, [handle()], [{:ok, handle()}, {:ok, page()}, {:ok, ""}]}
        ],
        success <- successes do
      assert {:error, :integrity_failure} = call(recording_config(success), operation, arguments)
      assert_received {:called, ^operation, _}
      refute_received {:called, _, _}
    end
  end

  test "generation rejects exposed maps private descriptors or malformed handles as successes" do
    for invalid <- [
          %{},
          Map.from_struct(handle()),
          %{path: "/tmp/" <> @canary},
          %{_ledger: make_ref(), _identity: @canary},
          Map.put(handle(), :lease, @canary),
          %{handle() | binding: {@session, @principal, @canary, 0, 0}}
        ] do
      assert {:error, :integrity_failure} =
               call(recording_config({:ok, invalid}), :export_knowledge, [%{}])

      assert_received {:called, :export_knowledge, _}
    end
  end

  test "malformed nonerror callback replies are integrity failures for every operation" do
    for invalid <- [nil, false, @canary, {:ok}, {:ok, @canary, @canary}, [@canary]],
        {operation, arguments} <- operation_arguments() do
      assert {:error, :integrity_failure} = call(recording_config(invalid), operation, arguments)
      assert_received {:called, ^operation, _}
    end
  end

  test "entries accepts exactly 500 strict string-key descriptors and a Writer-shaped cursor" do
    descriptors = List.duplicate(descriptor(), 500)
    result = %{entries: descriptors, next_cursor: cursor()}

    assert {:ok, ^result} =
             call(recording_config({:ok, result}), :knowledge_export_entries, [handle(), nil])
  end

  test "entries rejects oversized or nonlist pages and extra private page keys" do
    for invalid <- [
          %{entries: List.duplicate(descriptor(), 501), next_cursor: nil},
          %{entries: @canary, next_cursor: nil},
          %{entries: [], next_cursor: nil, host_path: @canary},
          %{entries: []},
          %{entries: [], next_cursor: Map.put(cursor(), :binding, @canary)},
          %{"entries" => [], "next_cursor" => nil},
          %OptionsStruct{}
        ] do
      assert_bad_page(invalid)
    end
  end

  test "entry descriptors reject extra atom-key missing malformed or private fields" do
    for invalid <- [
          nil,
          @canary,
          %{path: "manifest.json", media_type: "application/json", byte_size: 0, sha256: @digest},
          Map.put(descriptor(), "host_path", "/tmp/" <> @canary),
          Map.put(descriptor(), "session", @canary),
          Map.put(descriptor(), "lease", @canary),
          Map.delete(descriptor(), "sha256"),
          %{descriptor() | "path" => "../" <> @canary},
          %{descriptor() | "media_type" => nil},
          %{descriptor() | "byte_size" => -1},
          %{descriptor() | "byte_size" => 0.0},
          %{descriptor() | "sha256" => String.duplicate("A", 64)},
          %{descriptor() | "sha256" => String.duplicate("a", 63)},
          %{descriptor() | "sha256" => @canary}
        ] do
      assert_bad_page(%{entries: [invalid], next_cursor: nil})
    end
  end

  test "chunk returns the exact 65536-byte boundary and rejects larger or nonbinary payloads" do
    bytes = :binary.copy(<<0, 255>>, 32_768)

    assert {:ok, ^bytes} =
             call(recording_config({:ok, bytes}), :read_knowledge_export_chunk, [
               handle(),
               "manifest.json",
               0
             ])

    for invalid <- [bytes <> <<0>>, [@canary], %{body: @canary}, nil, 0] do
      assert {:error, :integrity_failure} =
               call(recording_config({:ok, invalid}), :read_knowledge_export_chunk, [
                 handle(),
                 "manifest.json",
                 0
               ])
    end
  end

  test "native Error and stable atom failures are reduced to stable atoms without canaries" do
    for code <- Error.codes(),
        error <- [
          {:error, code},
          {:error, Error.new(code, message: @canary, details: %{path: @canary})}
        ],
        {operation, arguments} <- operation_arguments() do
      assert {:error, ^code} = call(recording_config(error), operation, arguments)
      assert_received {:called, ^operation, _}
    end
  end

  test "unknown errors and callback exceptions throws or exits never expose canaries" do
    for failure <- [
          {:error, @canary},
          {:error, %{private: @canary}},
          {:raise, @canary},
          {:throw, @canary},
          {:exit, @canary}
        ],
        {operation, arguments} <- operation_arguments() do
      result = call(recording_config(failure), operation, arguments)
      assert result == {:error, :storage_unavailable}
      refute inspect(result) =~ @canary
      assert_received {:called, ^operation, _}
    end
  end

  test "missing wrong-arity and invalid config callbacks fail without arbitrary dispatch" do
    for config <- [%{}, %{export_knowledge: @canary}] do
      assert {:error, :invalid} = call(config, :export_knowledge, [%{}])
    end

    assert {:error, :storage_unavailable} =
             call(%{export_knowledge: fn -> @canary end}, :export_knowledge, [%{}])

    for config <- [nil, [], %OptionsStruct{}] do
      assert {:error, :invalid} = call(config, :export_knowledge, [%{}])
    end
  end

  test "closed validator rejects unknown operation or wrong argument counts" do
    for {operation, arguments} <- [
          {:unknown_export_operation, [%{path: @canary}]},
          {:export_knowledge, []},
          {:export_knowledge, [%{}, @canary]},
          {:knowledge_export_entries, [handle()]},
          {:read_knowledge_export_chunk, [handle(), "manifest.json"]},
          {:close_knowledge_export, [handle(), @canary]}
        ] do
      assert {:error, %Error{code: :invalid, message: nil, details: %{}}} =
               validate(operation, arguments)
    end
  end

  def canary, do: send(self(), :unexpected_mfa_work)

  defp call(config, operation, arguments, session \\ session_dto()),
    do: apply(Api, operation, [config, session | arguments])

  defp validate(operation, arguments), do: apply(@export, :validate, [operation, arguments])

  defp recording_config(reply) do
    parent = self()

    %{
      export_knowledge: fn context, options ->
        send(parent, {:called, :export_knowledge, [context, options]})
        reply(reply)
      end,
      knowledge_export_entries: fn context, handle, cursor ->
        send(parent, {:called, :knowledge_export_entries, [context, handle, cursor]})
        reply(reply)
      end,
      read_knowledge_export_chunk: fn context, handle, path, ordinal ->
        send(parent, {:called, :read_knowledge_export_chunk, [context, handle, path, ordinal]})
        reply(reply)
      end,
      close_knowledge_export: fn context, handle ->
        send(parent, {:called, :close_knowledge_export, [context, handle]})
        reply(reply)
      end
    }
  end

  defp reply({:raise, message}), do: raise(message)
  defp reply({:throw, value}), do: throw(value)
  defp reply({:exit, value}), do: exit(value)
  defp reply(value), do: value

  defp assert_invalid(operation, arguments) do
    result = call(recording_config(:unexpected), operation, arguments)
    assert result == {:error, :invalid}
    refute inspect(result) =~ @canary
    refute_received {:called, _, _}
  end

  defp assert_session_integrity(dto) do
    assert {:error, :integrity_failure} =
             call(recording_config(:unexpected), :export_knowledge, [%{}], dto)

    refute_received {:called, _, _}
  end

  defp assert_bad_page(page) do
    result = call(recording_config({:ok, page}), :knowledge_export_entries, [handle(), nil])
    assert result == {:error, :integrity_failure}
    refute inspect(result) =~ @canary
    assert_received {:called, :knowledge_export_entries, _}
  end

  defp assert_context(context) do
    assert %SessionContext{
             session_id: @session,
             principal_id: @principal,
             vault_id: @owner,
             principal_authorization_epoch: 0,
             vault_authorization_epoch: 0,
             authorization_epoch: 0,
             unlocked?: true
           } = context
  end

  defp handle do
    struct!(@handle,
      owner: self(),
      operation_ref: make_ref(),
      binding: {@session, @principal, @owner, 0, 0},
      deadline: System.monotonic_time(:millisecond) + 900_000
    )
  end

  defp session_dto do
    struct!(Session,
      session_id: @session,
      account_id: nil,
      principal_id: @principal,
      vault_id: @owner,
      expires_at: ~U[2099-01-01 00:00:00Z],
      principal_authorization_epoch: 0,
      vault_authorization_epoch: 0,
      authorization_epoch: 0,
      unlocked?: true
    )
  end

  defp session_binding(session),
    do:
      {session.session_id, session.principal_id, session.vault_id,
       session.principal_authorization_epoch, session.vault_authorization_epoch}

  defp cursor,
    do: %{operation_id: @operation, after: "manifest.json", proof: @digest}

  # Decode an external PID term without connecting to a node or starting any
  # process. The facade must reject nonlocal routing before a callback runs.
  defp remote_pid do
    name = "export-api-remote@invalid"
    :erlang.binary_to_term(<<131, 103, 100, byte_size(name)::16, name::binary, 1::32, 0::32, 0>>)
  end

  defp descriptor,
    do: %{
      "path" => "manifest.json",
      "media_type" => "application/json",
      "byte_size" => 0,
      "sha256" => @digest
    }

  defp page, do: %{entries: [], next_cursor: nil}

  defp operation_arguments,
    do: [
      {:export_knowledge, [%{}]},
      {:knowledge_export_entries, [handle(), nil]},
      {:read_knowledge_export_chunk, [handle(), "manifest.json", 0]},
      {:close_knowledge_export, [handle()]}
    ]
end
