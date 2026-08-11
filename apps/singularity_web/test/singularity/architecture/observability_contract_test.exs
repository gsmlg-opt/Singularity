defmodule Singularity.Architecture.ObservabilityContractTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../../../..", __DIR__)

  @dependency_event_prefixes MapSet.new([
                               :thousand_island,
                               :bandit,
                               :plug,
                               :phoenix,
                               :phoenix_live_view,
                               :oban,
                               :ecto
                             ])
  @protected_dependencies MapSet.new([
                            :thousand_island,
                            :bandit,
                            :plug,
                            :phoenix,
                            :phoenix_live_view,
                            :telemetry
                          ])

  test "production subscriptions remain bounded to the runtime Oban adapter" do
    assert [
             {"apps/singularity_runtime/lib/singularity/runtime/observability/telemetry.ex",
              :attach_many, _arguments}
           ] =
             production_sources()
             |> Enum.flat_map(&telemetry_calls/1)
             |> Enum.filter(fn {_path, function, _arguments} ->
               function in [:attach, :attach_many]
             end)

    telemetry_source =
      @repo_root
      |> Path.join("apps/singularity_runtime/lib/singularity/runtime/observability/telemetry.ex")
      |> File.read!()

    assert [[:oban, :job, :exception], [:oban, :job, :stop]] ==
             module_attribute(telemetry_source, :oban_events)

    assert [Singularity.Runtime.Observability.Telemetry] ==
             Singularity.Runtime.Application.application_children(%{start_infrastructure: false})

    assert [] ==
             production_sources()
             |> Enum.flat_map(&indirect_telemetry_invocations/1)
  end

  test "raw dependency event literals remain bounded" do
    assert [
             {"apps/singularity_runtime/lib/singularity/runtime/observability/telemetry.ex",
              [:oban, :job, :exception]},
             {"apps/singularity_runtime/lib/singularity/runtime/observability/telemetry.ex",
              [:oban, :job, :stop]},
             {"apps/singularity_web/lib/singularity/web/endpoint.ex", [:phoenix, :endpoint]}
           ] == dependency_event_literals(production_sources())
  end

  test "direct telemetry emissions remain bounded to approved emitters" do
    assert [
             {"apps/singularity_runtime/lib/singularity/runtime/observability/telemetry.ex",
              "[:singularity | event]"},
             {"apps/singularity_storage/lib/singularity/storage/safe_sql.ex",
              "[:singularity, :authorization, :rls_denial]"}
           ] == direct_emission_inventory(production_sources())
  end

  test "protected dependencies are declared and locked only from Hex" do
    assert [] == non_hex_dependency_declarations(dependency_sources())

    locks =
      @repo_root
      |> Path.join("mix.lock")
      |> Mix.Dep.Lock.read()
      |> Map.new(fn {dependency, lock} -> {Atom.to_string(dependency), lock} end)

    assert [] == protected_lock_violations(locks)
  end

  test "scanners reject raw subscriptions and non-Hex protected dependencies" do
    source = """
    :telemetry.attach(:raw_phoenix, [:phoenix, :endpoint, :stop], &__MODULE__.handle/4, nil)
    :telemetry.attach_many(handler_id, source_events, &__MODULE__.handle/4, nil)
    {:phoenix, github: "gsmlg-dev/phoenix"}
    {:plug, git: "https://example.invalid/plug.git"}
    {:bandit, path: "../bandit"}
    """

    assert [:attach, :attach_many] ==
             source
             |> calls_in_source()
             |> Enum.map(&elem(&1, 0))

    assert [{:bandit, :path}, {:phoenix, :github}, {:plug, :git}] ==
             non_hex_declarations_in_source(source)
             |> Enum.sort()

    indirect_source = """
    apply(:telemetry, :attach, arguments)
    apply(:telemetry, function, arguments)
    Kernel.apply(:telemetry, :attach_many, arguments)
    :erlang.apply(:telemetry, :execute, arguments)
    import :telemetry
    """

    assert [:kernel_apply, :kernel_apply, :kernel_apply, :erlang_apply, :import] ==
             {"fixture.ex", indirect_source}
             |> indirect_telemetry_invocations()
             |> Enum.map(&elem(&1, 1))

    alias_source = """
    alias :telemetry, as: Telemetry
    Telemetry.attach(handler_id, event, callback, config)
    alias :telemetry
    """

    assert [:alias, :alias] ==
             {"alias_fixture.ex", alias_source}
             |> indirect_telemetry_invocations()
             |> Enum.map(&elem(&1, 1))

    capture_source = """
    &:telemetry.attach/4
    &:telemetry.attach_many/4
    &:telemetry.execute/3
    """

    assert [:attach, :attach_many, :execute] ==
             capture_source
             |> calls_in_source()
             |> Enum.map(&elem(&1, 0))

    assert [:capture, :capture, :capture] ==
             {"capture_fixture.ex", capture_source}
             |> indirect_telemetry_invocations()
             |> Enum.map(&elem(&1, 1))

    assert [{"capture_fixture.ex", {:invalid_execute_arguments, 0}}] ==
             direct_emission_inventory([{"capture_fixture.ex", capture_source}])

    wrapper_source =
      "def wrapper, do: :telemetry.attach(handler_id, event, callback, config)"

    assert [:attach] ==
             wrapper_source
             |> calls_in_source()
             |> Enum.map(&elem(&1, 0))

    hex_locks =
      Map.new(@protected_dependencies, fn dependency ->
        {Atom.to_string(dependency),
         {:hex, dependency, "1.0.0", "checksum", [:mix], [], "hexpm", "outer_checksum"}}
      end)

    assert [] == protected_lock_violations(hex_locks)

    missing_dependency = @protected_dependencies |> Enum.sort() |> hd()

    assert [{missing_dependency, :missing}] ==
             hex_locks
             |> Map.delete(Atom.to_string(missing_dependency))
             |> protected_lock_violations()

    unrelated_lock = {:git, "https://example.invalid/unrelated.git", "revision", []}

    assert [] ==
             hex_locks
             |> Map.put("unrelated_dependency", unrelated_lock)
             |> protected_lock_violations()

    protected_git_lock = {:git, "https://example.invalid/telemetry.git", "revision", []}

    assert [{:telemetry, {:invalid, protected_git_lock}}] ==
             hex_locks
             |> Map.put("telemetry", protected_git_lock)
             |> protected_lock_violations()
  end

  defp production_sources do
    [
      Path.join(@repo_root, "apps/*/lib/**/*.{ex,exs}"),
      Path.join(@repo_root, "config/*.{ex,exs}")
    ]
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.sort()
    |> Enum.map(fn path -> {relative(path), File.read!(path)} end)
  end

  defp relative(path), do: Path.relative_to(path, @repo_root)

  defp telemetry_calls({path, source}) do
    source
    |> calls_in_source()
    |> Enum.map(fn {function, arguments} -> {path, function, arguments} end)
  end

  defp calls_in_source(source) do
    source
    |> Code.string_to_quoted!()
    |> Macro.prewalk([], fn
      {{:., _dot_metadata, [:telemetry, function]}, _call_metadata, arguments} = node, calls
      when function in [:attach, :attach_many, :execute] and is_list(arguments) ->
        {node, [{function, arguments} | calls]}

      node, calls ->
        {node, calls}
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp indirect_telemetry_invocations({path, source}) do
    source
    |> Code.string_to_quoted!()
    |> Macro.prewalk([], fn
      {:apply, _metadata, [:telemetry, _function, _arguments]} = node, invocations ->
        {node, [{path, :kernel_apply, Macro.to_string(node)} | invocations]}

      {{:., _dot_metadata, [{:__aliases__, _alias_metadata, [:Kernel]}, :apply]}, _call_metadata,
       [:telemetry, _function, _arguments]} = node,
      invocations ->
        {node, [{path, :kernel_apply, Macro.to_string(node)} | invocations]}

      {{:., _dot_metadata, [:erlang, :apply]}, _call_metadata,
       [:telemetry, _function, _arguments]} = node,
      invocations ->
        {node, [{path, :erlang_apply, Macro.to_string(node)} | invocations]}

      {:import, _metadata, [:telemetry | _options]} = node, invocations ->
        {node, [{path, :import, Macro.to_string(node)} | invocations]}

      {:alias, _metadata, [:telemetry | _options]} = node, invocations ->
        {node, [{path, :alias, Macro.to_string(node)} | invocations]}

      {:&, _capture_metadata,
       [
         {:/, _arity_metadata,
          [
            {{:., _dot_metadata, [:telemetry, function]}, _call_metadata, []},
            _arity
          ]}
       ]} = node,
      invocations
      when function in [:attach, :attach_many, :execute] ->
        {node, [{path, :capture, Macro.to_string(node)} | invocations]}

      node, invocations ->
        {node, invocations}
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp direct_emission_inventory(sources) do
    sources
    |> Enum.flat_map(&telemetry_calls/1)
    |> Enum.filter(fn {_path, function, _arguments} -> function == :execute end)
    |> Enum.map(fn
      {path, _function, [event, _measurements, _metadata]} ->
        {path, Macro.to_string(event)}

      {path, _function, arguments} ->
        {path, {:invalid_execute_arguments, length(arguments)}}
    end)
    |> Enum.sort()
  end

  defp module_attribute(source, attribute) do
    source
    |> Code.string_to_quoted!()
    |> Macro.prewalk([], fn
      {:@, _metadata, [{^attribute, _attribute_metadata, [value]}]} = node, values ->
        {node, [value | values]}

      node, values ->
        {node, values}
    end)
    |> elem(1)
    |> Enum.reverse()
    |> then(fn [value] -> value end)
  end

  defp dependency_event_literals(sources) do
    sources
    |> Enum.flat_map(fn {path, source} ->
      source
      |> Code.string_to_quoted!()
      |> Macro.prewalk([], fn
        [prefix | _tail] = event, events when is_atom(prefix) ->
          if MapSet.member?(@dependency_event_prefixes, prefix) do
            {event, [{path, event} | events]}
          else
            {event, events}
          end

        node, events ->
          {node, events}
      end)
      |> elem(1)
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp non_hex_dependency_declarations(sources) do
    sources
    |> Enum.flat_map(fn {path, source} ->
      source
      |> non_hex_declarations_in_source()
      |> Enum.map(fn {dependency, source_type} -> {path, dependency, source_type} end)
    end)
  end

  defp non_hex_declarations_in_source(source) do
    source
    |> Code.string_to_quoted!()
    |> Macro.prewalk([], fn
      {dependency, options} = node, declarations
      when is_atom(dependency) and is_list(options) ->
        protected_non_hex_declarations(node, dependency, options, declarations)

      {dependency, _requirement, options} = node, declarations
      when is_atom(dependency) and is_list(options) ->
        protected_non_hex_declarations(node, dependency, options, declarations)

      {:{}, _metadata, [dependency, options]} = node, declarations
      when is_atom(dependency) and is_list(options) ->
        protected_non_hex_declarations(node, dependency, options, declarations)

      {:{}, _metadata, [dependency, _requirement, options]} = node, declarations
      when is_atom(dependency) and is_list(options) ->
        protected_non_hex_declarations(node, dependency, options, declarations)

      node, declarations ->
        {node, declarations}
    end)
    |> elem(1)
    |> Enum.uniq()
  end

  defp protected_non_hex_declarations(node, dependency, options, declarations) do
    if MapSet.member?(@protected_dependencies, dependency) do
      {node, non_hex_options(dependency, options) ++ declarations}
    else
      {node, declarations}
    end
  end

  defp non_hex_options(dependency, options) do
    for source_type <- [:github, :git, :path], Keyword.has_key?(options, source_type) do
      {dependency, source_type}
    end
  end

  defp protected_lock_violations(locks) do
    @protected_dependencies
    |> Enum.sort()
    |> Enum.flat_map(&protected_lock_violation(locks, &1))
  end

  defp protected_lock_violation(locks, dependency) do
    case Map.fetch!(locks, Atom.to_string(dependency)) do
      {:hex, ^dependency, _, _, _, _, "hexpm", _} -> []
      invalid_lock -> [{dependency, {:invalid, invalid_lock}}]
    end
  rescue
    KeyError -> [{dependency, :missing}]
  end

  defp dependency_sources do
    [Path.join(@repo_root, "mix.exs"), Path.join(@repo_root, "apps/*/mix.exs")]
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.sort()
    |> Enum.map(fn path -> {relative(path), File.read!(path)} end)
  end
end
