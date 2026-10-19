defmodule Singularity.Web.Architecture.KnowledgeExportCompositionContractTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../../../..", __DIR__)
  @export_path "apps/singularity_runtime/lib/singularity/runtime/knowledge/export.ex"
  @artifact_path "apps/singularity_runtime/lib/singularity/runtime/knowledge/export_artifact.ex"
  @artifact_module [:Singularity, :Runtime, :Knowledge, :ExportArtifact]
  @selection_keys [:materializer, :work, :callback, :module, :function, :args, :mfa]
  @recovery_mutations [
    :spawn_before_companion_down,
    :accept_exit_without_matching_down,
    :ready_before_owner_monitor,
    :accept_wrong_operation_ref,
    :accept_wrong_recovery_ref,
    :accept_wrong_replacement_pid,
    :delete_before_owner_down,
    :monitor_different_owner,
    :cleanup_reconstructed_path,
    :pass_work_or_runtime,
    :link_replacement_to_owner,
    :restart_replacement,
    :retry_replacement_on_failure,
    :return_to_delivery_after_recovery,
    :ignore_supervisor_shutdown,
    :report_cleanup_error_as_success
  ]

  # Source-direction evidence only: these checks do not establish real Writer
  # ownership, SQL COMMIT, native authority, lease cleanup or compiled xref.
  # Each mutant first requires the SAME validator to accept actual production
  # source. There is no missing-source fallback or synthetic positive baseline.
  test "actual export composition constructs fixed work and invokes it only in the owner" do
    {export, artifact} = sources()
    contract!(export, artifact)
  end

  for lookup <- [:runtime, :config] do
    @lookup lookup
    test "#{lookup} lookup cannot replace the literal run-local work" do
      {export, artifact} = baseline!()

      changed =
        Macro.prewalk(export, fn
          {:=, meta, [{:work, _, _} = work, {:fn, _, _}]} ->
            {:=, meta, [work, quote(do: Map.fetch!(unquote(Macro.var(@lookup, nil)), :work))]}

          node ->
            node
        end)

      assert_rejected!(changed, artifact, "literal run-local work/2")
    end
  end

  test "a reverse qualified orchestration call is rejected" do
    {export, artifact} = baseline!()

    changed =
      append_to_module(
        artifact,
        @artifact_module,
        quote do
          defp reverse(runtime, session, options, operation),
            do:
              Singularity.Runtime.Knowledge.Export.materialize(
                runtime,
                session,
                options,
                operation
              )
        end
      )

    assert_rejected!(export, changed, "no reverse Export dependency")
  end

  test "a reverse orchestration alias is rejected even without a call" do
    {export, artifact} = baseline!()

    changed =
      append_to_module(
        artifact,
        @artifact_module,
        quote(do: alias(Singularity.Runtime.Knowledge.Export, as: Orchestrator))
      )

    assert_rejected!(export, changed, "no reverse Export dependency")
  end

  test "materialize cannot become an exported entry point" do
    {export, artifact} = baseline!()

    changed =
      Macro.prewalk(export, fn
        {:defp, meta, [head, body]} = node ->
          if function_name(head) == :materialize, do: {:def, meta, [head, body]}, else: node

        node ->
          node
      end)

    assert_rejected!(changed, artifact, "private materialize/4 only")
  end

  test "an options-taking generate compatibility clause is rejected" do
    {export, artifact} = baseline!()

    changed =
      append_to_module(
        artifact,
        @artifact_module,
        quote do
          def generate(runtime, session, options) when is_map(options),
            do: {:legacy_generation, runtime, session, options}
        end
      )

    assert_rejected!(export, changed, "sole guarded generate(runtime, session, work)/3")
  end

  test "work cannot execute in a companion function" do
    {export, artifact} = baseline!()

    changed =
      append_to_module(
        artifact,
        @artifact_module,
        quote do
          defp companion_work(work, operation_runtime, operation),
            do: work.(operation_runtime, operation)
        end
      )

    assert_rejected!(export, changed, "work executes exactly once only in owner_generate/4")
  end

  test "work cannot be retained in delivered state" do
    {export, artifact} = baseline!()

    changed =
      Macro.prewalk(artifact, fn
        {:defp, meta, [head, body]} = node ->
          if function_name(head) == :owner_generate do
            retained = quote(do: %{phase: :delivered, work: work})
            {:defp, meta, [head, Keyword.update!(body, :do, &block([retained, &1]))]}
          else
            node
          end

        node ->
          node
      end)

    assert_rejected!(export, changed, "work is not retained in delivery or closed state")
  end

  test "native lease recording cannot move after the pre-forward clock fence" do
    {export, artifact} = baseline!()

    changed =
      change_forward_body(artifact, fn [record, clock | rest] ->
        [clock, record | rest]
      end)

    assert_rejected!(export, changed, "record before clock before forward")
  end

  test "native lease forwarding cannot precede the recorded-state clock fence" do
    {export, artifact} = baseline!()
    early_forward = quote(do: send(request.owner, {:export_lease, lease}))

    changed =
      change_forward_body(artifact, fn [record, clock | rest] ->
        [record, early_forward, clock | rest]
      end)

    assert_rejected!(export, changed, "record before clock before forward")
  end

  # BEGIN terminal-close contracts
  @terminal_mutations [
    :early_ok,
    :down_as_success,
    :inflight_dead_noop,
    :omit_native_cleanup_result,
    :wrong_owner_monitor,
    :wrong_operation_ref,
    :wrong_reply_ref,
    :wrong_companion_pid,
    :retained_owner_receipt,
    :cleanup_from_handle,
    :dead_owner_filesystem_access,
    :expired_wait_success,
    :refresh_deadline,
    :third_operation_task
  ]

  test "actual terminal close acknowledges cleanup and both exact task terminations" do
    {_export, artifact} = baseline!()
    terminal_contract!(artifact)
  end

  for mutation <- @terminal_mutations do
    @terminal_mutation mutation
    test "terminal close rejects #{@terminal_mutation}" do
      {_export, artifact} = baseline!()
      terminal_contract!(artifact)
      {changed, intended_failure} = terminal_mutation!(artifact, @terminal_mutation)
      refute strip(changed) == strip(artifact), "mutation must change actual source"
      error = assert_raise ExUnit.AssertionError, fn -> terminal_contract!(changed) end
      assert Exception.message(error) =~ intended_failure
    end
  end

  # END terminal-close contracts

  test "actual recovery is one-shot identity-only cleanup after exact owner DOWN" do
    {_export, artifact} = baseline!()
    recovery_contract!(artifact)
  end

  for mutation <- @recovery_mutations do
    @recovery_mutation mutation
    test "recovery rejects #{@recovery_mutation}" do
      {_export, artifact} = baseline!()
      recovery_contract!(artifact)
      {changed, intended_failure} = recovery_mutation!(artifact, @recovery_mutation)
      refute strip(changed) == strip(artifact), "mutation must change actual source"
      error = assert_raise ExUnit.AssertionError, fn -> recovery_contract!(changed) end
      assert Exception.message(error) =~ intended_failure
    end
  end

  # BEGIN Task16 transfer-read routing contracts
  # Source/attribution evidence only, not native SQL or custody qualification.
  test "Task16 originals use exactly two fixed committed transfer routes" do
    {export, _artifact} = sources()
    transfer_routes!(export)
  end

  for {current, old} <- [
        {:asset_for_export, :asset},
        {:document_for_export, :document}
      ] do
    test "Task16 cannot restore old #{old} original primitive" do
      {export, _artifact} = sources()
      transfer_routes!(export)

      changed =
        replace_once!(
          export,
          fn
            {{:., _, [{:__aliases__, _, [:ExportRead]}, function]}, _, args} ->
              function == unquote(current) and length(args) == 3

            _ ->
              false
          end,
          fn {{:., dot, [module, _function]}, meta, args} ->
            {{:., dot, [module, unquote(old)]}, meta, args}
          end
        )

      error = assert_raise ExUnit.AssertionError, fn -> transfer_routes!(changed) end
      assert Exception.message(error) =~ "exact fixed original transfer routes"
    end
  end

  test "a third transfer route outside original_descriptor is rejected" do
    {export, _artifact} = sources()
    transfer_routes!(export)

    changed =
      append_to_module(
        export,
        [:Singularity, :Runtime, :Knowledge, :Export],
        quote do
          defp foreign_transfer(runtime, session, source),
            do: ExportRead.asset_for_export(runtime, session, source)
        end
      )

    error = assert_raise ExUnit.AssertionError, fn -> transfer_routes!(changed) end
    assert Exception.message(error) =~ "only original_descriptor owns transfer calls"
  end

  test "Artifact cannot acquire a reverse Read dependency" do
    {_export, artifact} = sources()
    transfer_no_reverse_read!(artifact)

    changed =
      append_to_module(
        artifact,
        @artifact_module,
        quote do
          alias Singularity.Runtime.Knowledge.ExportRead, as: ReverseRead
        end
      )

    error = assert_raise ExUnit.AssertionError, fn -> transfer_no_reverse_read!(changed) end
    assert Exception.message(error) =~ "no reverse ExportRead dependency"
  end

  test "transfer addition uniquely inverts to the entire accepted Read primitive" do
    transfer_old_read!(transfer_read_source())
  end

  test "an unrelated old Read byte cannot be hidden by the transfer inverse" do
    source = transfer_read_source()
    transfer_old_read!(source)
    old = ~s(@moduledoc "Internal exact-source, authenticated portable export reads.")
    assert length(String.split(source, old)) == 2
    changed = String.replace(source, old, old <> " # unrelated old-byte mutation", global: false)
    error = assert_raise ExUnit.AssertionError, fn -> transfer_old_read!(changed) end
    assert Exception.message(error) =~ "entire accepted Read primitive"
  end

  defp transfer_routes!(export) do
    export = executable(export)
    definitions = definitions(export)
    originals = Enum.filter(definitions, &named?(&1, :original_descriptor, 4))
    assert length(originals) == 2, "exact fixed original transfer routes"

    expected = [
      quote do
        defp original_descriptor(runtime, session, %{"kind" => "asset"}, source),
          do: ExportRead.asset_for_export(runtime, session, source)
      end,
      quote do
        defp original_descriptor(runtime, session, %{"kind" => "document"} = version, source),
          do:
            ExportRead.document_for_export(runtime, session, %{version: version, source: source})
      end
    ]

    actual = Enum.map(originals, fn {kind, head, body} -> {kind, [], [head, body]} end)

    assert Enum.map(actual, &strip/1) == Enum.map(expected, &strip/1),
           "exact fixed original transfer routes"

    assert transfer_route_nodes(export) == transfer_route_nodes(originals),
           "only original_descriptor owns transfer calls"
  end

  defp transfer_route_nodes(ast) do
    nodes(ast, fn
      {{:., _, [{:__aliases__, _, parts}, name]}, _, args}
      when name in [:asset_for_export, :document_for_export] and is_list(args) ->
        parts in [[:ExportRead], [:Singularity, :Runtime, :Knowledge, :ExportRead]]

      _ ->
        false
    end)
    |> Enum.map(&strip/1)
  end

  defp transfer_no_reverse_read!(artifact) do
    assert nodes(executable(artifact), fn
             {:__aliases__, _, [:ExportRead | _]} -> true
             {:__aliases__, _, [:Singularity, :Runtime, :Knowledge, :ExportRead | _]} -> true
             value when is_atom(value) -> value == Singularity.Runtime.Knowledge.ExportRead
             _ -> false
           end) == [],
           "no reverse ExportRead dependency"
  end

  defp transfer_read_source do
    File.read!(
      Path.join(
        @repo_root,
        "apps/singularity_runtime/lib/singularity/runtime/knowledge/export_read.ex"
      )
    )
  end

  defp transfer_old_read!(source) do
    first = "  # BEGIN Task16 committed transfer reads\n"
    last = "  # END Task16 committed transfer reads\n\n"
    assert length(String.split(source, first)) == 2, "one contiguous transfer addition"
    assert length(String.split(source, last)) == 2, "one contiguous transfer addition"
    [before, block] = String.split(source, first)
    [addition, after_block] = String.split(block, last)

    assert String.ends_with?(
             before,
             "  def fragment(runtime, session, binding), do: text(runtime, session, binding, :fragment)\n\n"
           ),
           "fixed transfer addition before text/4"

    assert String.starts_with?(after_block, "  defp text(runtime, session, binding, kind) do\n"),
           "fixed transfer addition before text/4"

    assert addition != ""
    inverse = before <> after_block

    assert Base.encode16(:crypto.hash(:sha256, inverse), case: :lower) ==
             "9e7e20f235345627eee93a824b0b652a2b8cd582e657f9f92cc2a4716c00a091",
           "entire accepted Read primitive"
  end

  # END Task16 transfer-read routing contracts

  # BEGIN Task16 committed transfer ordering contracts
  # Executable source/ordering evidence only. PostgreSQL COMMIT, native custody,
  # immutable binding races and complete cleanup require the separate live owner.
  @transfer_order_mutations [
    :asset_first_guard,
    :asset_second_guard,
    :asset_acquisition,
    :asset_commit_boundary,
    :asset_fresh_authority,
    :asset_audit_order,
    :asset_runner_return,
    :asset_consumer_scope,
    :document_fresh_authority,
    :document_prechunk_guard,
    :document_postread_guard,
    :document_piece_guard,
    :document_final_guard,
    :context_fallback,
    :context_extra_key,
    :owner_check,
    :dynamic_reader,
    :asset_revoke,
    :document_revoke,
    :nonempty_all
  ]

  test "committed transfer helpers preserve fixed ownership and executable COMMIT ordering" do
    transfer_order_contract!(transfer_read_source() |> Code.string_to_quoted!())
  end

  for mutation <- @transfer_order_mutations do
    test "committed transfer rejects #{mutation}" do
      read = transfer_read_source() |> Code.string_to_quoted!()
      transfer_order_contract!(read)
      {changed, reason} = transfer_order_mutation!(read, unquote(mutation))
      refute strip(changed) == strip(read), "mutation changes executable transfer source"
      error = assert_raise ExUnit.AssertionError, fn -> transfer_order_contract!(changed) end
      assert Exception.message(error) =~ reason
    end
  end

  defp transfer_order_contract!(read) do
    read = executable(read)

    for {name, kind, binding} <- [
          {:asset_for_export, :asset, quote(do: binding)},
          {:document_for_export, :document, quote(do: captured)}
        ] do
      body = transfer_order_body!(read, name, 3)
      transfer_order_exact!(body, quote(do: owner = self()), "lexically captured transfer owner")
      pass = if kind == :asset, do: :transfer_asset_pass, else: :transfer_document_pass

      transfer_order_exact!(
        body,
        quote do
          pass = fn acc, consumer ->
            unquote(pass)(runtime, session, unquote(binding), context, owner, acc, consumer)
          end
        end,
        "lexically captured transfer owner"
      )
    end

    context = transfer_order_body!(read, :transfer_context!, 1)

    transfer_order_exact!(
      context,
      quote do
        case {Map.get(runtime, :custodian), Map.get(runtime, :authenticated_reader)} do
          {{Singularity.Runtime.Knowledge.ExportArtifact.Leases, context},
           {Singularity.Runtime.Knowledge.ExportArtifact.Leases, context}}
          when is_map(context) ->
            exact_keys!(context, [:companion, :operation_ref, :reader])

            unless is_pid(context.companion) and node(context.companion) == node() and
                     context.companion != self() and Process.alive?(context.companion) and
                     is_reference(context.operation_ref) and transfer_reader?(context.reader),
                   do: fail(:invalid)

            context

          _ ->
            fail(:invalid)
        end
      end,
      "fixed matching three-key context without fallback"
    )

    validate = transfer_order_body!(read, :transfer_validate!, 4)

    transfer_order_exact!(
      validate,
      quote(do: unless(self() == owner, do: fail(:invalid))),
      "same lexical owner before any transfer effects"
    )

    transfer_order_before!(
      validate,
      quote(do: unless(self() == owner, do: fail(:invalid))),
      quote(do: validate_request!(runtime, session)),
      "same lexical owner before any transfer effects"
    )

    transfer_order_exact!(
      validate,
      quote(do: unless(transfer_context!(runtime) === context, do: fail(:invalid))),
      "fixed context rechecked on every pass"
    )

    for name <- [:transfer_asset_pass, :transfer_document_pass] do
      body = transfer_order_body!(read, name, 7)

      transfer_order_exact!(
        body,
        quote(do: transfer_validate!(runtime, session, context, owner)),
        "fixed context rechecked on every pass"
      )
    end

    asset = transfer_order_body!(read, :transfer_asset_read!, 5)
    asset_callback = transfer_order_scope_callback!(asset)

    asset_guard =
      quote(do: :ok <- call(repository(runtime), :lock_asset_source, [repo, binding, mode]))

    asset_acquire =
      quote do
        {:ok, lease} <-
          Singularity.Runtime.Knowledge.ExportArtifact.Leases.lease(
            context,
            transfer_asset_request(session, binding)
          )
      end

    transfer_order_with!(
      asset_callback,
      [asset_guard, asset_acquire, asset_guard],
      "Asset source-acquire-source before committed transfer"
    )

    asset_after = transfer_order_after!(asset_callback)
    transfer_order_revoke!(asset_after)

    native =
      quote do
        Singularity.Runtime.Knowledge.ExportArtifact.Leases.read(
          context,
          lease,
          if(mode == :zero, do: :all, else: mode)
        )
      end

    transfer_order_before!(
      asset_after,
      quote(do: validate_request!(runtime, session)),
      native,
      "fixed bounded native read after COMMIT outside SQL"
    )

    transfer_order_before!(
      asset_after,
      native,
      quote(do: transfer_asset_post!(run_scoped, runtime, session, binding, mode, requirement)),
      "native read before fresh committed Asset guard"
    )

    post = transfer_order_body!(read, :transfer_asset_post!, 6)
    post_runner = transfer_order_runner!(post)

    transfer_order_with!(
      post_runner,
      [
        quote(
          do:
            :ok <-
              Singularity.Runtime.Authorize.check(
                runtime.authorization,
                repo,
                session,
                requirement
              )
        ),
        asset_guard,
        quote do
          :ok <-
            Singularity.Runtime.Audit.append_principal(audit, repo, session, %{
              action: "asset.downloaded",
              result: :completed,
              classification: :private,
              correlation_id: correlation_id,
              target_type: "asset",
              target_id: binding["asset_id"],
              metadata: %{}
            })
        end
      ],
      "explicit Asset authorization-source-audit inside runner"
    )

    transfer_order_return!(post)

    transfer_order_exact!(
      post,
      quote(do: correlation_id = Ecto.UUID.generate()),
      "fresh private audit identity per read"
    )

    transfer_order_exact!(
      post,
      quote(do: audit = Map.get(runtime, :audit, Singularity.Storage.Postgres.AuditSink)),
      "actual configured/default audit sink"
    )

    asset_pass = transfer_order_body!(read, :transfer_asset_pass, 7)

    transfer_order_before!(
      asset_pass,
      quote(do: transfer_asset_read!(runtime, session, binding, range, context)),
      quote(do: consume!(bytes, state, consumer)),
      "Asset read returns and revokes before consumer"
    )

    transfer_order_before!(
      asset_pass,
      quote(do: validate_request!(runtime, session)),
      quote(do: consume!(bytes, state, consumer)),
      "consumer outside SQL after returned scope"
    )

    document = transfer_order_body!(read, :transfer_document_pass, 7)
    document_callback = transfer_order_scope_callback!(document)
    document_source = quote(do: call(repository(runtime), :document_source, [repo, captured]))

    transfer_order_with!(
      document_callback,
      [
        quote(do: {:ok, binding} <- unquote(document_source)),
        quote(do: :ok <- transfer_document_binding!(captured, binding)),
        quote do
          {:ok, lease} <-
            Singularity.Runtime.Knowledge.ExportArtifact.Leases.lease(
              context,
              transfer_document_request(session, binding)
            )
        end,
        quote(do: {:ok, ^binding} <- unquote(document_source))
      ],
      "Document exact-source-acquire-source before committed transfer"
    )

    document_after = transfer_order_after!(document_callback)
    transfer_order_revoke!(document_after)
    guard = transfer_order_body!(read, :transfer_document_guard!, 6)
    guard_runner = transfer_order_runner!(guard)

    transfer_order_with!(
      guard_runner,
      [
        quote(
          do:
            :ok <-
              Singularity.Runtime.Authorize.check(
                runtime.authorization,
                repo,
                session,
                requirement
              )
        ),
        quote(do: {:ok, ^binding} <- unquote(document_source))
      ],
      "explicit Document authorization-exact-source inside runner"
    )

    transfer_order_return!(guard)

    transfer_order_exact!(
      document_after,
      quote do
        guard = fn ->
          transfer_document_guard!(run_scoped, runtime, session, captured, binding, requirement)
        end
      end,
      "Document piece guard uses fresh committed authority"
    )

    loop =
      transfer_order_exact!(
        document_after,
        fn
          {:fn, _, [{:->, _, [[{:ordinal, _, _}, {:state, _, _}], _]}]} -> true
          _ -> false
        end,
        "one bounded Document native loop"
      )

    {:fn, _, [{:->, _, [_arguments, loop_body]}]} = loop

    transfer_order_exact!(
      loop_body,
      quote(do: if(ordinal > 0, do: guard.())),
      "fresh guard before subsequent native chunk"
    )

    document_native =
      quote(
        do:
          Singularity.Runtime.Knowledge.ExportArtifact.Leases.read_document_chunk(
            context,
            lease,
            ordinal
          )
      )

    transfer_order_before!(
      loop_body,
      quote(do: if(ordinal > 0, do: guard.())),
      document_native,
      "fresh guard before subsequent native chunk"
    )

    transfer_order_before!(
      loop_body,
      document_native,
      quote(do: guard.()),
      "fresh guard after native Document read"
    )

    transfer_order_exact!(
      loop_body,
      quote(do: split_document!(bytes, state, consumer, guard)),
      "fresh committed guard before each consumer piece"
    )

    transfer_order_before!(
      loop_body,
      quote(do: guard.()),
      quote(do: split_document!(bytes, state, consumer, guard)),
      "fresh guard after native Document read"
    )

    transfer_order_exact!(
      document_after,
      quote(
        do:
          Singularity.Runtime.Knowledge.ExportArtifact.Leases.authenticate_empty_document_original(
            context,
            lease
          )
      ),
      "genuine Document-only empty authentication"
    )

    {:try, _, [options]} =
      transfer_order_exact!(
        document_after,
        &match?({:try, _, _}, &1),
        "one strict native cleanup boundary"
      )

    expressions = options |> Keyword.fetch!(:do) |> expressions()

    assert Enum.map(Enum.take(expressions, -2), &strip/1) ==
             Enum.map([quote(do: guard.()), quote(do: {:ok, result})], &strip/1),
           "final fresh Document guard before pass success"
  end

  defp transfer_order_body!(read, name, arity) do
    matches = Enum.filter(definitions(read), &named?(&1, name, arity))
    assert length(matches) == 1, "one concrete transfer helper #{name}/#{arity}"
    [{_kind, _head, body}] = matches
    Keyword.fetch!(body, :do)
  end

  defp transfer_order_exact!(ast, expected, reason) do
    predicate = if is_function(expected, 1), do: expected, else: &(strip(&1) == strip(expected))
    matches = nodes(ast, predicate)
    assert length(matches) == 1, reason
    hd(matches)
  end

  defp transfer_order_before!(ast, first, last, reason) do
    all = nodes(ast, fn _ -> true end)

    first_matches =
      Enum.with_index(all) |> Enum.filter(fn {node, _} -> strip(node) == strip(first) end)

    last_matches =
      Enum.with_index(all) |> Enum.filter(fn {node, _} -> strip(node) == strip(last) end)

    assert first_matches != [] and last_matches != [], reason

    assert Enum.any?(first_matches, fn {_, first_index} ->
             Enum.any?(last_matches, fn {_, last_index} -> first_index < last_index end)
           end),
           reason
  end

  defp transfer_order_scope_callback!(body) do
    {{:., _, [{:__aliases__, _, [:OperationScope]}, :with_read_request]}, _,
     [_runtime, _session, _requirement, {:fn, _, [{:->, _, [[{:repo, _, _}], callback]}]}]} =
      transfer_order_exact!(
        body,
        fn
          {{:., _, [{:__aliases__, _, [:OperationScope]}, :with_read_request]}, _, args} ->
            length(args) == 4

          _ ->
            false
        end,
        "one real OperationScope acquisition transaction"
      )

    callback
  end

  defp transfer_order_with!(body, expected, reason) do
    {:with, _, clauses} = transfer_order_exact!(body, &match?({:with, _, _}, &1), reason)
    assert Enum.map(Enum.drop(clauses, -1), &strip/1) == Enum.map(expected, &strip/1), reason
  end

  defp transfer_order_after!(callback) do
    {:after_commit_scoped, {:fn, _, [{:->, _, [[{:run_scoped, _, _}], body]}]}} =
      transfer_order_exact!(
        callback,
        fn
          {:after_commit_scoped, _} -> true
          _ -> false
        end,
        "native work only after actual initial COMMIT"
      )

    body
  end

  defp transfer_order_runner!(body) do
    {{:., _, [{:run_scoped, _, _}]}, _, [{:fn, _, [{:->, _, [[{:repo, _, _}], callback]}]}]} =
      transfer_order_exact!(
        body,
        fn
          {{:., _, [{:run_scoped, _, _}]}, _, [_callback]} -> true
          _ -> false
        end,
        "one real post-read scoped runner"
      )

    callback
  end

  defp transfer_order_return!(body) do
    transfer_order_exact!(
      body,
      quote do
        case run_scoped.(fn repo -> unquote(transfer_order_runner!(body)) end) do
          :ok -> validate_request!(runtime, session)
          {:error, reason} -> raise_error!(reason)
          _ -> fail(:integrity_failure)
        end
      end,
      "actual runner success required before outside-SQL return"
    )
  end

  defp transfer_order_revoke!(body) do
    {:try, _, [options]} =
      transfer_order_exact!(body, &match?({:try, _, _}, &1), "one strict native cleanup boundary")

    assert strip(Keyword.fetch!(options, :after)) ==
             strip(
               quote(
                 do: revoke({Singularity.Runtime.Knowledge.ExportArtifact.Leases, context}, lease)
               )
             ),
           "strict companion revoke in after"
  end

  defp transfer_order_mutation!(read, mutation) do
    {name, arity, target, replacement, reason} =
      case mutation do
        key when key in [:asset_first_guard, :asset_second_guard, :asset_acquisition] ->
          index = %{asset_first_guard: 0, asset_acquisition: 1, asset_second_guard: 2}[key]

          target = fn
            {:with, _, _} -> true
            _ -> false
          end

          replacement = fn {:with, meta, clauses} ->
            {:with, meta, List.delete_at(clauses, index)}
          end

          {:transfer_asset_read!, 5, target, replacement, "Asset source-acquire-source"}

        :asset_commit_boundary ->
          {:transfer_asset_read!, 5,
           fn
             {:after_commit_scoped, _} -> true
             _ -> false
           end, fn {_tag, callback} -> {:after_commit, callback} end,
           "native work only after actual initial COMMIT"}

        key when key in [:asset_fresh_authority, :document_fresh_authority] ->
          name =
            if key == :asset_fresh_authority,
              do: :transfer_asset_post!,
              else: :transfer_document_guard!

          reason =
            if key == :asset_fresh_authority, do: "explicit Asset", else: "explicit Document"

          {name, 6,
           quote(
             do:
               Singularity.Runtime.Authorize.check(
                 runtime.authorization,
                 repo,
                 session,
                 requirement
               )
           ), fn _ -> :ok end, reason}

        :asset_audit_order ->
          {:transfer_asset_post!, 6,
           fn
             {:with, _, _} -> true
             _ -> false
           end,
           fn {:with, meta, [authority, guard, audit, options]} ->
             {:with, meta, [authority, audit, guard, options]}
           end, "explicit Asset authorization-source-audit"}

        :asset_runner_return ->
          {:transfer_asset_post!, 6,
           fn
             {:case, _, _} -> true
             _ -> false
           end,
           fn {:case, _, [callback, _options]} ->
             block([callback, quote(do: validate_request!(runtime, session))])
           end, "actual runner success required"}

        :asset_consumer_scope ->
          {:transfer_asset_pass, 7, quote(do: validate_request!(runtime, session)),
           fn _ -> :ok end, "consumer outside SQL after returned scope"}

        :document_prechunk_guard ->
          {:transfer_document_pass, 7, quote(do: if(ordinal > 0, do: guard.())), fn _ -> :ok end,
           "fresh guard before subsequent native chunk"}

        :document_postread_guard ->
          {:transfer_document_pass, 7,
           fn
             {:fn, _, [{:->, _, [[{:ordinal, _, _}, {:state, _, _}], _]}]} -> true
             _ -> false
           end,
           fn {:fn, meta, [{:->, arrow, [args, body]}]} ->
             statements = expressions(body)
             changed = Enum.reject(statements, &(strip(&1) == strip(quote(do: guard.()))))
             assert length(changed) == length(statements) - 1, "unique post-read Document guard"
             {:fn, meta, [{:->, arrow, [args, block(changed)]}]}
           end, "fresh guard after native Document read"}

        :document_piece_guard ->
          {:transfer_document_pass, 7, quote(do: split_document!(bytes, state, consumer, guard)),
           fn _ -> quote(do: split_document!(bytes, state, consumer, fn -> :ok end)) end,
           "fresh committed guard before each consumer piece"}

        :document_final_guard ->
          {:transfer_document_pass, 7,
           fn
             {:try, _, _} -> true
             _ -> false
           end,
           fn {:try, meta, [options]} ->
             statements = options |> Keyword.fetch!(:do) |> expressions()
             assert strip(Enum.at(statements, -2)) == strip(quote(do: guard.()))
             {:try, meta, [Keyword.put(options, :do, block(List.delete_at(statements, -2)))]}
           end, "final fresh Document guard"}

        :context_fallback ->
          {:transfer_context!, 1, quote(do: Map.get(runtime, :custodian)),
           fn _ -> quote(do: Map.get(runtime, :custodian, Singularity.Runtime.KeyCustodian)) end,
           "fixed matching three-key context"}

        :context_extra_key ->
          {:transfer_context!, 1,
           quote(do: exact_keys!(context, [:companion, :operation_ref, :reader])),
           fn _ ->
             quote(do: exact_keys!(context, [:companion, :operation_ref, :reader, :clock]))
           end, "fixed matching three-key context"}

        :owner_check ->
          {:transfer_validate!, 4, quote(do: unless(self() == owner, do: fail(:invalid))),
           fn _ -> :ok end, "same lexical owner before any transfer effects"}

        :dynamic_reader ->
          {:transfer_asset_read!, 5,
           fn
             {{:., _,
               [
                 {:__aliases__, _,
                  [:Singularity, :Runtime, :Knowledge, :ExportArtifact, :Leases]},
                 :read
               ]}, _, _} ->
               true

             _ ->
               false
           end,
           fn _ ->
             quote(do: call(Map.fetch!(runtime, :authenticated_reader), :read, [lease, mode]))
           end, "fixed bounded native read after COMMIT outside SQL"}

        key when key in [:asset_revoke, :document_revoke] ->
          name = if key == :asset_revoke, do: :transfer_asset_read!, else: :transfer_document_pass
          arity = if key == :asset_revoke, do: 5, else: 7

          {name, arity,
           quote(
             do: revoke({Singularity.Runtime.Knowledge.ExportArtifact.Leases, context}, lease)
           ), fn _ -> :ok end, "strict companion revoke in after"}

        :nonempty_all ->
          {:transfer_asset_read!, 5, quote(do: if(mode == :zero, do: :all, else: mode)),
           fn _ -> :all end, "fixed bounded native read after COMMIT outside SQL"}
      end

    changed =
      replace_once!(
        read,
        fn
          {kind, _, [head, body]} when kind in [:def, :defp] ->
            named?({kind, head, body}, name, arity)

          _ ->
            false
        end,
        fn {kind, meta, [head, body]} ->
          original = Keyword.fetch!(body, :do)
          predicate = if is_function(target, 1), do: target, else: &(strip(&1) == strip(target))
          updated = replace_once!(original, predicate, replacement)
          {kind, meta, [head, Keyword.put(body, :do, updated)]}
        end
      )

    {changed, reason}
  end

  # END Task16 committed transfer ordering contracts

  # BEGIN Task16 mandatory bootstrap checkpoint contract
  test "bootstrap records its real envelope and checks the existing clock before starting any owner" do
    {_export, artifact} = sources()
    bootstrap_checkpoint!(artifact)
  end

  for mutation <- [:clock, :create] do
    test "bootstrap checkpoint rejects #{mutation} removal at its intended boundary" do
      {_export, artifact} = sources()

      changed =
        change_recovery_body!(artifact, :companion_start, fn body ->
          case unquote(mutation) do
            :clock ->
              replace_once!(
                body,
                &(strip(&1) == strip(quote(do: companion_admission(state, state.clock.())))),
                fn _ -> quote(do: companion_admission(state, 5_000)) end
              )

            :create ->
              replace_once!(body, &match?({:with, _, _}, &1), fn {:with, meta, clauses} ->
                {:with, meta, List.delete_at(clauses, 1)}
              end)
          end
        end)

      error = assert_raise ExUnit.AssertionError, fn -> bootstrap_checkpoint!(changed) end
      assert Exception.message(error) =~ "bootstrap"
    end
  end

  defp bootstrap_checkpoint!(artifact) do
    {_head, body} = private_body!(artifact, :companion_start, 6)
    withs = nodes(body, &match?({:with, _, _}, &1))
    assert match?([{:with, _, [_, _, _]}], withs), "bootstrap requires prepare then actual create"
    [{:with, _, [_prepare, create, with_options]}] = withs

    assert strip(create) == strip(quote(do: {:ok, envelope} <- ArtifactDirectory.create(root))),
           "bootstrap requires prepare then actual create"

    steps = expressions(Keyword.fetch!(with_options, :do))
    assert match?([_, {:case, _, [_, _]}], steps), "bootstrap records envelope before admission"
    [record, {:case, _, [admission, case_options]}] = steps

    assert strip(record) == strip(quote(do: state = %{state | envelope: envelope})),
           "bootstrap records the original envelope"

    assert strip(admission) == strip(quote(do: companion_admission(state, state.clock.()))),
           "bootstrap checks the existing mandatory operation clock"

    [{:->, _, [[success], accepted]} | _] = Keyword.fetch!(case_options, :do)
    assert strip(success) == strip(quote(do: {:ok, state})), "bootstrap admission precedes owner"
    accepted_steps = expressions(accepted)

    assert match?([_, {:case, _, [{:start_task, _, [_, {:fn, _, _}]}, _]}], accepted_steps),
           "bootstrap admits before starting its owner task"

    assert nodes(accepted, &local_call?(&1, :owner_start, 4)) != [],
           "bootstrap starts the actual owner only after the existing clock"
  end

  # END Task16 mandatory bootstrap checkpoint contract

  defp sources do
    {
      @repo_root |> Path.join(@export_path) |> File.read!() |> Code.string_to_quoted!(),
      @repo_root |> Path.join(@artifact_path) |> File.read!() |> Code.string_to_quoted!()
    }
  end

  defp baseline! do
    {export, artifact} = sources()
    contract!(export, artifact)
    {export, artifact}
  end

  defp assert_rejected!(export, artifact, message) do
    error = assert_raise ExUnit.AssertionError, fn -> contract!(export, artifact) end
    assert Exception.message(error) =~ message
  end

  defp contract!(export, artifact) do
    export = executable(export)
    artifact = executable(artifact)
    export_definitions = definitions(export)
    artifact_definitions = definitions(artifact)

    runs = Enum.filter(export_definitions, &named?(&1, :run, 3))
    assert match?([{:def, _, _}], runs), "exactly one public run/3"
    [{:def, run_head, run_body}] = runs

    assert strip(unguarded(run_head)) == strip(quote(do: run(runtime, session, options))),
           "fixed run/3 arguments"

    expected_work =
      quote do
        work = fn operation_runtime, operation ->
          materialize(operation_runtime, session, normalized_options, operation)
        end
      end

    assignments = nodes(run_body, &match?({:=, _, [{:work, _, _}, _]}, &1))

    assert Enum.map(assignments, &strip/1) == [strip(expected_work)],
           "literal run-local work/2"

    assert nodes(export, &match?({:fn, _, _}, &1))
           |> Enum.count(fn node ->
             contains_variable?(node, :operation_runtime) and
               contains_call?(node, :materialize, 4)
           end) == 1,
           "sole literal materializer closure"

    generates = nodes(run_body, &generate_call?/1)
    expected_generate = quote(do: ExportArtifact.generate(runtime, session, work))

    assert Enum.map(generates, &strip/1) == [strip(expected_generate)],
           "one fixed generate/3 call in run/3"

    assert length(nodes(export, &generate_call?/1)) == 1, "no other generation call site"

    materializers =
      Enum.filter(export_definitions, fn {_, head, _} ->
        function_name(head) == :materialize
      end)

    expected_materialize = quote(do: materialize(runtime, session, normalized_options, operation))
    assert match?([{:defp, _, _}], materializers), "private materialize/4 only"
    [{:defp, materialize_head, _}] = materializers

    assert strip(unguarded(materialize_head)) == strip(expected_materialize),
           "private materialize/4 only"

    assert nodes(artifact, &reverse_export?/1) == [], "no reverse Export dependency"

    assert nodes(artifact, &materializer_dispatch?/1) == [],
           "no reverse materialize or work-selection dispatch"

    generators =
      Enum.filter(artifact_definitions, fn {_, head, _} ->
        function_name(head) == :generate
      end)

    assert match?([{:def, {:when, _, [_, _]}, _}], generators),
           "sole guarded generate(runtime, session, work)/3"

    [{:def, {:when, _, [generate_head, guard]}, _}] = generators

    assert strip(generate_head) == strip(quote(do: generate(runtime, session, work))) and
             strip(quote(do: is_function(work, 2))) in Enum.map(
               nodes(guard, fn _ -> true end),
               &strip/1
             ),
           "sole guarded generate(runtime, session, work)/3"

    owners = Enum.filter(artifact_definitions, &named?(&1, :owner_generate, 4))
    assert match?([{:defp, _, _}], owners), "private owner_generate/4 exists"
    [{:defp, owner_head, owner_body}] = owners

    assert strip(unguarded(owner_head)) ==
             strip(quote(do: owner_generate(runtime, session, work, operation))),
           "fixed owner_generate/4 arguments"

    assert nodes(artifact, &retains_work?/1) == [],
           "work is not retained in delivery or closed state"

    invocations = nodes(artifact, &work_call?/1)
    owner_invocations = nodes(owner_body, &work_call?/1)
    expected_invocation = quote(do: work.(operation_runtime, operation))

    assert Enum.map(invocations, &strip/1) == [strip(expected_invocation)] and
             Enum.map(owner_invocations, &strip/1) == [strip(expected_invocation)],
           "work executes exactly once only in owner_generate/4"

    assert length(nodes(owner_body, &variable?(&1, :work))) == 1,
           "owner drops work after generation before delivery"

    assert contains_call?(owner_body, :owner_loop, 1), "generation enters owner_loop/1"

    forwards = Enum.filter(artifact_definitions, &named?(&1, :record_and_forward, 3))

    assert match?([{:defp, _, _}], forwards), "private record_and_forward/3 exists"
    [{:defp, forward_head, forward_body}] = forwards

    assert strip(unguarded(forward_head)) ==
             strip(quote(do: record_and_forward(state, request, lease))),
           "fixed record_and_forward/3 arguments"

    expected_record = quote(do: state = record_lease(state, lease))
    expected_clock = quote(do: now = state.clock.())

    forward_expressions = expressions(Keyword.fetch!(forward_body, :do))
    assert match?([_, _ | _], forward_expressions), "record before clock before forward"
    [record, clock | _decision_and_forward] = forward_expressions

    assert strip(record) == strip(expected_record) and strip(clock) == strip(expected_clock),
           "record before clock before forward"
  end

  defp definitions(ast) do
    for {kind, _, [head, body]} <- nodes(ast, &definition?/1), do: {kind, head, body}
  end

  # BEGIN terminal-close validator
  defp terminal_contract!(artifact) do
    artifact = executable(artifact)

    for {tag, size} <- [export_close_route: 5, export_close_waiting: 4, export_closed: 5] do
      assert nodes(artifact, &terminal_tuple?(&1, tag, size)) != [],
             "terminal protocol requires executable #{tag}"
    end

    {_route_head, route} = private_body!(artifact, :route, 5)
    {_stop_head, stop} = private_body!(artifact, :owner_stop, 4)
    {_register_head, register} = private_body!(artifact, :register_terminal, 4)
    {_wait_head, wait} = private_body!(artifact, :await_terminal, 1)
    {reply_head, reply} = private_body!(artifact, :terminal_reply, 3)
    {_cancel_head, cancel} = private_body!(artifact, :cancel, 2)
    {_revoke_head, revoke} = private_body!(artifact, :revoke_leases, 1)

    stop_owner =
      for {:defp, head, body} <- definitions(artifact),
          named?({:defp, head, body}, :stop_owner, 1),
          do: body

    {_request_head, request} = private_body!(artifact, :owner_request, 6)
    {_loop_head, loop} = private_body!(artifact, :owner_loop, 1)

    assert nodes([stop, register, wait, reply, cancel], &terminal_task?/1) == [],
           "terminal close creates no third operation task"

    assert nodes([stop, register, wait, reply], &terminal_deadline_refresh?/1) == [],
           "terminal close retains the original deadline"

    assert nodes(wait, fn node -> local_call?(node, :authorize, 3) end) == [],
           "in-flight loss never becomes an authenticated dead-owner no-op"

    assert contains_call?(route, :valid_handle, 1) and
             contains_call?(route, :valid_session, 1) and
             nodes(route, &terminal_equal?(&1, quote(do: binding(session) == handle.binding))) !=
               [],
           "dead-owner close still validates and compares every binding hint"

    [alive] = nodes(route, &terminal_equal?(&1, quote(do: Process.alive?(handle.owner))))

    dead_branches =
      for {:if, _, [condition, options]} <- nodes(route, &match?({:if, _, _}, &1)),
          strip(condition) == strip(alive),
          do: Keyword.fetch!(options, :else)

    assert match?([_], dead_branches), "dead-owner no-op is selected only before sending"
    [dead] = dead_branches

    assert contains_call?(dead, :authorize, 3) and
             nodes(dead, &terminal_forbidden_dead_call?/1) == [] and
             not contains_call?(dead, :await_terminal, 1),
           "initially dead close freshly authenticates without filesystem or restart"

    assert nodes(stop, &local_call?(&1, :owner_loop, 1)) == [] and
             nodes(stop, &local_call?(&1, :owner_generate, 4)) == [] and
             exact_exit?(stop, :normal),
           "terminal owner cannot retain a live receipt or resume delivery"

    register_steps = expressions(Keyword.fetch!(register, :do))
    caller_monitors = monitor_bindings(register)
    assert match?([{_, :caller}], caller_monitors), "register exact caller monitor before ACK"
    [{caller_monitor, :caller}] = caller_monitors

    ack_sends = terminal_sends(register, :export_close_registered, 4)
    assert match?([_], ack_sends), "register exact caller monitor before ACK"
    [ack_send] = ack_sends

    assert terminal_before?(
             register_steps,
             fn step ->
               {caller_monitor, :caller} in monitor_bindings(step)
             end,
             &(&1 == ack_send)
           ) and
             terminal_equal?(
               ack_send,
               quote do
                 send(
                   state.owner,
                   {:export_close_registered, state.operation_ref, reply_ref, self()}
                 )
               end
             ),
           "register exact caller monitor before ACK"

    waiters =
      for {:=, _, [{:waiter, _, _}, {:%{}, _, fields}]} <-
            nodes(register, &match?({:=, _, _}, &1)),
          do: fields

    assert match?([_], waiters), "registration stores one bounded content-free waiter"
    [waiter_fields] = waiters

    assert Enum.sort(Keyword.keys(waiter_fields)) == [
             :caller,
             :monitor,
             :ready,
             :reply_ref,
             :result
           ] and
             terminal_equal?(Keyword.fetch!(waiter_fields, :caller), quote(do: caller)) and
             variable?(Keyword.fetch!(waiter_fields, :monitor), caller_monitor) and
             terminal_equal?(Keyword.fetch!(waiter_fields, :reply_ref), quote(do: reply_ref)) and
             terminal_equal?(Keyword.fetch!(waiter_fields, :result), quote(do: result)) and
             Keyword.fetch!(waiter_fields, :ready) == false,
           "registration stores one bounded content-free waiter"

    assert terminal_sends(stop, :export_close_route, 5) != [] and
             Enum.any?(clauses(stop), fn {patterns, body} ->
               terminal_pinned_message?(patterns, :export_close_registered, [
                 :operation_ref,
                 :reply_ref,
                 :companion
               ]) and
                 terminal_sends(body, :export_close_route, 5) != []
             end),
           "owner route follows matching companion registration ACK"

    assert Enum.any?(clauses(artifact), fn {patterns, body} ->
             contains_call?(body, :register_terminal, 4) and
               nodes(patterns, fn
                 {:{}, _, [_tag, operation, owner, _caller, _reply_ref, _result]} ->
                   pinned_from?(operation, [:operation_ref]) and pinned_from?(owner, [:owner])

                 _ ->
                   false
               end) != []
           end),
           "companion registration admits only stored operation and owner"

    route_receivers =
      Enum.filter(clauses(artifact), fn {patterns, _body} ->
        nodes(patterns, &terminal_tuple?(&1, :export_close_route, 5)) != []
      end)

    assert match?([{_, _}], route_receivers), "one caller accepts the exact owner route"
    [{route_pattern, route_body}] = route_receivers

    assert terminal_pinned_message?(route_pattern, :export_close_route, [
             :operation_ref,
             :reply_ref,
             :owner,
             nil
           ]),
           "route matches exact operation call reference and owner"

    assert {:companion_monitor, :companion} in monitor_bindings(route_body) and
             terminal_before?(
               expressions(route_body),
               fn step ->
                 {:companion_monitor, :companion} in monitor_bindings(step)
               end,
               fn step -> terminal_sends(step, :export_close_waiting, 4) != [] end
             ),
           "caller monitors exact companion before readiness"

    assert terminal_sends(route_body, :export_close_waiting, 4)
           |> Enum.any?(
             &terminal_equal?(
               &1,
               quote do
                 send(companion, {:export_close_waiting, operation_ref, reply_ref, self()})
               end
             )
           ),
           "readiness binds operation call reference and actual caller"

    assert contains_call?(route_body, :await_terminal, 1),
           "admitted route enters the terminal result and DOWN wait"

    assert Enum.any?(nodes(route_body, &match?({:%{}, _, _}, &1)), fn
             {:%{}, _, fields} ->
               fields = Enum.filter(fields, &match?({key, _} when is_atom(key), &1))

               Keyword.get(fields, :owner_down?, :missing) == false and
                 Keyword.get(fields, :companion_down?, :missing) == false and
                 Keyword.get(fields, :result, :missing) == nil
           end),
           "terminal handoff starts with neither DOWN nor cleanup result observed"

    for field <- [
          :operation_ref,
          :reply_ref,
          :owner,
          :owner_monitor,
          :companion,
          :companion_monitor
        ] do
      assert field in field_aliases(wait, :state, field),
             "terminal wait pins the stored #{field} identity"
    end

    assert terminal_success_gate?(wait),
           "public success requires known cleanup result and both DOWN observations"

    assert Enum.any?(nodes(wait, &match?({:if, _, _}, &1)), fn
             {:if, _, [condition, options]} ->
               terminal_equal?(condition, quote(do: before_deadline?(state))) and
                 terminal_success_gate?(Keyword.fetch!(options, :do)) and
                 terminal_equal?(Keyword.get(options, :else), quote(do: unavailable()))
           end),
           "terminal wait expires against original deadline before public success"

    receives = nodes(wait, &match?({:receive, _, _}, &1))
    assert match?([_], receives), "one bounded terminal receive"
    [{:receive, _, [wait_options]}] = receives

    assert match?([{:->, _, [[_], _]}], Keyword.get(wait_options, :after)),
           "terminal receive is bounded by original remaining lifetime"

    [{:->, _, [[timeout], timeout_body]}] = Keyword.fetch!(wait_options, :after)

    assert terminal_equal?(timeout, quote(do: remaining(state))) and
             (terminal_equal?(timeout_body, quote(do: await_terminal(state))) or
                terminal_equal?(timeout_body, quote(do: unavailable()))),
           "terminal receive is bounded by original remaining lifetime"

    for {monitor, process, flag, reason} <- [
          {:owner_monitor, :owner, :owner_down?, :any},
          {:companion_monitor, :companion, :companion_down?, :normal}
        ] do
      assert Enum.any?(clauses(wait), fn {patterns, body} ->
               terminal_exact_down?(patterns, monitor, process, reason) and
                 terminal_equal?(
                   body,
                   quote do
                     await_terminal(%{state | unquote(flag) => true})
                   end
                 )
             end),
             "exact #{process} DOWN only records completion, never success"
    end

    assert Enum.any?(clauses(wait), fn {patterns, body} ->
             terminal_pinned_message?(patterns, :export_closed, [
               :operation_ref,
               :reply_ref,
               :companion,
               nil
             ]) and
               terminal_equal?(body, quote(do: await_terminal(%{state | result: result})))
           end),
           "cleanup result matches exact operation call reference and companion"

    assert terminal_equal?(
             Keyword.fetch!(cancel, :do) |> expressions() |> hd(),
             quote(do: state = %{state | phase: :closed})
           ),
           "seal delivery before cleanup"

    cancel_steps = expressions(Keyword.fetch!(cancel, :do))

    assert terminal_before?(cancel_steps, &contains_call?(&1, :stop_owner, 1), fn step ->
             nodes(step, &directory_cleanup?/1) != []
           end) and
             terminal_exact_down?(stop_owner, :monitor, :owner, :any),
           "exact owner DOWN precedes envelope cleanup"

    assert nodes(
             cancel,
             &terminal_equal?(
               &1,
               quote(do: cleaned? = leases_closed? and cleanup == :ok)
             )
           ) != [],
           "success checks genuine native result and envelope cleanup result"

    assert nodes(
             cancel,
             &terminal_equal?(
               &1,
               quote(do: leases_closed? = revoke_leases(state))
             )
           ) != [] and
             Enum.any?(nodes(revoke, &match?({:if, _, _}, &1)), fn
               {:if, _, [condition, options]} ->
                 terminal_equal?(condition, quote(do: result == :ok)) and
                   terminal_exact_down?(Keyword.fetch!(options, :do), :monitor, :lease, :any) and
                   Keyword.get(options, :else) == false
             end),
           "native cleanup requires actual revoke acknowledgement and exact lease DOWN"

    cleanups = nodes(cancel, &directory_cleanup?/1)
    assert match?([_], cleanups), "cleanup uses original trusted envelope"
    [cleanup] = cleanups

    assert terminal_equal?(cleanup, quote(do: ArtifactDirectory.cleanup(state.envelope))),
           "cleanup uses original trusted envelope, never Handle"

    assert nodes(reply_head, &variable?(&1, :state)) == [] and
             nodes(reply, &terminal_forbidden_reply_state?/1) == [],
           "readiness retains only content-free cleanup context"

    {:terminal_reply, _, [context, _waiter, _cleaned]} = unguarded(reply_head)
    context_name = variable_name(context)

    assert not is_nil(context_name) and
             :operation_ref in field_aliases(reply, context_name, :operation_ref),
           "terminal reply uses its recorded operation identity"

    terminal_calls = nodes(cancel, &local_call?(&1, :terminal_reply, 3))

    assert match?([{:terminal_reply, _, [{:%{}, _, _}, _, _]}], terminal_calls),
           "cleanup hands only reduced operation identity deadline and clock to readiness"

    [{:terminal_reply, _, [{:%{}, _, reply_context}, _, _]}] = terminal_calls

    assert Enum.sort(Keyword.keys(reply_context)) == [:clock, :deadline, :operation_ref] and
             Enum.all?(reply_context, fn {key, value} ->
               terminal_equal?(value, {{:., [], [Macro.var(:state, nil), key]}, [], []})
             end),
           "cleanup hands only reduced operation identity deadline and clock to readiness"

    assert terminal_before?(
             cancel_steps,
             fn step -> nodes(step, &directory_cleanup?/1) != [] end,
             &contains_call?(&1, :terminal_reply, 3)
           ),
           "cleanup precedes terminal result"

    assert nodes(
             reply,
             &terminal_equal?(
               &1,
               quote(do: result = if(cleaned?, do: waiter.result, else: unavailable()))
             )
           ) != [],
           "failed cleanup cannot acknowledge successful close or an original error"

    assert :caller in field_aliases(reply, :waiter, :caller) and
             :reply_ref in field_aliases(reply, :waiter, :reply_ref) and
             :caller_monitor in field_aliases(reply, :waiter, :monitor) and
             Enum.any?(clauses(reply), fn {patterns, body} ->
               terminal_exact_down?(patterns, :caller_monitor, :caller, :any) and body == :ok
             end),
           "caller loss retires its terminal waiter without sending a receipt"

    assert Enum.any?(clauses(reply), fn {patterns, body} ->
             terminal_pinned_message?(patterns, :export_close_waiting, [
               :operation_ref,
               :reply_ref,
               :caller
             ]) and
               terminal_sends(body, :export_closed, 5) != []
           end),
           "only registered ready caller receives terminal cleanup result"

    assert terminal_sends(reply, :export_closed, 5)
           |> Enum.any?(
             &terminal_equal?(
               &1,
               quote do
                 send(caller, {:export_closed, operation_ref, reply_ref, self(), result})
               end
             )
           ),
           "companion sends fixed original result after cleanup"

    assert nodes(
             request,
             &terminal_equal?(
               &1,
               quote(do: operation == :close or match?({:error, _}, result))
             )
           ) != [] and
             contains_call?(request, :owner_stop, 4),
           "admitted owning errors use the same terminal cleanup protocol"

    assert Enum.any?(clauses(loop), fn {_patterns, body} ->
             nodes(body, &local_call?(&1, :owner_request, 6)) != [] and
               Enum.any?(nodes(body, &match?({:if, _, _}, &1)), fn
                 {:if, _, [_condition, options]} ->
                   foreign = Keyword.get(options, :else)

                   contains_call?(foreign, :forbidden, 0) and
                     contains_call?(foreign, :owner_loop, 1) and
                     not contains_call?(foreign, :owner_stop, 4)
               end)
           end),
           "foreign requests do not acquire terminal cleanup authority"

    assert nodes(loop, &terminal_equal?(&1, quote(do: deadline == state.deadline))) != [],
           "live owner compares the original Handle deadline before admission"
  end

  defp terminal_success_gate?(wait) do
    Enum.any?(nodes(wait, &match?({:if, _, _}, &1)), fn
      {:if, _, [condition, options]} ->
        terminal_equal?(
          condition,
          quote(do: state.owner_down? and state.companion_down? and not is_nil(state.result))
        ) and
          terminal_equal?(Keyword.fetch!(options, :do), quote(do: sanitize(state.result)))
    end)
  end

  defp terminal_equal?(left, right), do: strip(left) == strip(right)

  defp terminal_tuple?({:{}, _, [tag | rest]}, tag, size), do: length(rest) + 1 == size
  defp terminal_tuple?(_, _, _), do: false

  defp terminal_sends(ast, tag, size) do
    nodes(ast, fn
      {:send, _, [_destination, message]} -> terminal_tuple?(message, tag, size)
      _ -> false
    end)
  end

  defp terminal_pinned_message?(ast, tag, names) do
    nodes(ast, fn
      {:{}, _, [^tag | fields]} when length(fields) == length(names) ->
        Enum.zip(fields, names)
        |> Enum.all?(fn
          {field, nil} -> not match?({:^, _, _}, field)
          {field, name} -> pinned_from?(field, [name])
        end)

      _ ->
        false
    end) != []
  end

  defp terminal_exact_down?(ast, monitor, process, reason) do
    nodes(ast, fn
      {:{}, _, [:DOWN, ref, :process, pid, actual_reason]} ->
        pinned_from?(ref, [monitor]) and pinned_from?(pid, [process]) and
          (reason == :any or actual_reason == reason)

      _ ->
        false
    end) != []
  end

  defp terminal_before?(steps, first, second) do
    left = Enum.find_index(steps, first)
    right = Enum.find_index(steps, second)
    is_integer(left) and is_integer(right) and left < right
  end

  defp terminal_task?(node) do
    task_start?(node) or local_call?(node, :start_task, 2) or
      match?({name, _, _} when name in [:spawn, :spawn_link, :spawn_monitor], node)
  end

  defp terminal_deadline_refresh?({:%{}, _, fields}) do
    nodes(fields, fn
      {:deadline, value} -> not terminal_equal?(value, quote(do: state.deadline))
      _ -> false
    end) != []
  end

  defp terminal_deadline_refresh?(_), do: false

  defp terminal_forbidden_dead_call?({:__aliases__, _, parts}),
    do: List.last(parts) in [:ArtifactDirectory, :Writer, :Spool, :File, :Task, :Supervisor]

  defp terminal_forbidden_dead_call?({name, _, args}) when is_atom(name) and is_list(args),
    do: name not in [:if, :==, :authorize, :invalid, :fn, :->, :__block__]

  defp terminal_forbidden_dead_call?({{:., _, [_base, _field]}, _, []}), do: true

  defp terminal_forbidden_dead_call?(_), do: false

  defp terminal_forbidden_reply_state?({:%{}, _, fields}),
    do:
      nodes(fields, fn
        {key, _value} ->
          key in [:artifact, :writer, :envelope, :leases, :runtime, :work, :custodian, :reader]

        _ ->
          false
      end) != []

  defp terminal_forbidden_reply_state?({{:., _, [_base, field]}, _, []}),
    do: field in [:artifact, :writer, :envelope, :leases, :runtime, :work, :custodian, :reader]

  defp terminal_forbidden_reply_state?(_), do: false

  defp terminal_mutation!(artifact, mutation) do
    case mutation do
      :early_ok ->
        {change_recovery_body!(artifact, :await_terminal, fn body ->
           replace_once!(
             body,
             fn
               {:if, _, [condition, _]} ->
                 terminal_equal?(
                   condition,
                   quote do
                     state.owner_down? and state.companion_down? and not is_nil(state.result)
                   end
                 )

               _ ->
                 false
             end,
             fn {:if, meta, [_condition, options]} ->
               {:if, meta, [true, Keyword.put(options, :do, :ok)]}
             end
           )
         end), "public success requires known cleanup result and both DOWN observations"}

      :down_as_success ->
        {terminal_change_owner_down!(artifact, fn _ -> :ok end),
         "exact owner DOWN only records completion, never success"}

      :inflight_dead_noop ->
        {terminal_change_owner_down!(artifact, fn _ ->
           quote(do: authorize(runtime, session, fn -> :ok end))
         end), "in-flight loss never becomes an authenticated dead-owner no-op"}

      :omit_native_cleanup_result ->
        {change_recovery_body!(artifact, :cancel, fn body ->
           replace_once!(
             body,
             &terminal_equal?(&1, quote(do: leases_closed? and cleanup == :ok)),
             fn _ -> quote(do: cleanup == :ok) end
           )
         end), "success checks genuine native result and envelope cleanup result"}

      :wrong_owner_monitor ->
        {change_recovery_body!(artifact, :await_terminal, fn body ->
           replace_once!(
             body,
             fn node ->
               terminal_exact_down?(node, :owner_monitor, :owner, :any) and
                 terminal_tuple?(node, :DOWN, 5)
             end,
             fn {:{}, meta, [tag, _monitor | fields]} ->
               {:{}, meta, [tag, quote(do: ^wrong_monitor) | fields]}
             end
           )
         end), "exact owner DOWN only records completion, never success"}

      key when key in [:wrong_operation_ref, :wrong_reply_ref, :wrong_companion_pid] ->
        index = %{wrong_operation_ref: 1, wrong_reply_ref: 2, wrong_companion_pid: 3}[key]

        {change_recovery_body!(artifact, :await_terminal, fn body ->
           replace_once!(body, &terminal_tuple?(&1, :export_closed, 5), fn {:{}, meta, fields} ->
             {:{}, meta, List.replace_at(fields, index, quote(do: ^wrong_identity))}
           end)
         end), "cleanup result matches exact operation call reference and companion"}

      :retained_owner_receipt ->
        {change_recovery_body!(artifact, :owner_stop, fn body ->
           replace_once!(body, &match?({:exit, _, [:normal]}, &1), fn _ ->
             quote(do: owner_loop(state))
           end)
         end), "terminal owner cannot retain a live receipt or resume delivery"}

      :cleanup_from_handle ->
        {change_recovery_body!(artifact, :cancel, fn body ->
           replace_once!(body, &directory_cleanup?/1, fn {target, meta, _arguments} ->
             {target, meta, [quote(do: handle.envelope)]}
           end)
         end), "cleanup uses original trusted envelope, never Handle"}

      :dead_owner_filesystem_access ->
        {change_recovery_body!(artifact, :route, fn body ->
           replace_once!(
             body,
             fn
               {:if, _, [condition, _]} ->
                 terminal_equal?(condition, quote(do: Process.alive?(handle.owner)))

               _ ->
                 false
             end,
             fn {:if, meta, [condition, options]} ->
               changed =
                 Keyword.update!(options, :else, fn dead ->
                   block([quote(do: File.lstat(handle.owner)), dead])
                 end)

               {:if, meta, [condition, changed]}
             end
           )
         end), "initially dead close freshly authenticates without filesystem or restart"}

      :expired_wait_success ->
        {change_recovery_body!(artifact, :await_terminal, fn body ->
           replace_once!(
             body,
             fn
               {:if, _, [condition, _]} ->
                 terminal_equal?(condition, quote(do: before_deadline?(state)))

               _ ->
                 false
             end,
             fn {:if, meta, [condition, options]} ->
               {:if, meta, [condition, Keyword.put(options, :else, :ok)]}
             end
           )
         end), "terminal wait expires against original deadline before public success"}

      :refresh_deadline ->
        {change_recovery_body!(artifact, :owner_stop, fn body ->
           Keyword.update!(
             body,
             :do,
             &block([
               quote(do: state = %{state | deadline: state.clock.() + @lifetime}),
               &1
             ])
           )
         end), "terminal close retains the original deadline"}

      :third_operation_task ->
        {change_recovery_body!(artifact, :owner_stop, fn body ->
           Keyword.update!(
             body,
             :do,
             &block([
               quote(do: start_task(state.task_supervisor, fn -> :ok end)),
               &1
             ])
           )
         end), "terminal close creates no third operation task"}
    end
  end

  defp terminal_change_owner_down!(artifact, change) do
    change_recovery_body!(artifact, :await_terminal, fn body ->
      replace_once!(
        body,
        fn
          {:->, _, [patterns, _branch]} ->
            terminal_exact_down?(patterns, :owner_monitor, :owner, :any)

          _ ->
            false
        end,
        fn {:->, meta, [patterns, branch]} ->
          {:->, meta, [patterns, change.(branch)]}
        end
      )
    end)
  end

  # END terminal-close validator

  defp recovery_contract!(artifact) do
    artifact = executable(artifact)
    {recover_head, recover} = private_body!(artifact, :recover_companion_loss, 2)
    {_launch_head, launch} = private_body!(artifact, :start_cleanup_replacement, 2)
    {cleanup_head, cleanup} = private_body!(artifact, :cleanup_replacement, 1)

    contexts =
      for {:=, _, [{:cleanup_context, _, _}, {:%{}, _, _} = context]} <-
            nodes(recover, &match?({:=, _, _}, &1)),
          do: context

    assert match?([{:%{}, _, _}], contexts), "one exact identity-only cleanup context"
    [{:%{}, _, fields}] = contexts

    assert Enum.sort(Keyword.keys(fields)) == [:envelope, :operation_ref, :owner, :recovery_ref],
           "one exact identity-only cleanup context"

    assert strip(Keyword.fetch!(fields, :owner)) == strip(quote(do: self())) and
             strip(Keyword.fetch!(fields, :operation_ref)) ==
               strip(quote(do: state.operation_ref)) and
             strip(Keyword.fetch!(fields, :recovery_ref)) == strip(quote(do: make_ref())) and
             strip(Keyword.fetch!(fields, :envelope)) == strip(quote(do: state.envelope)),
           "cleanup retains the exact trusted envelope and private references"

    launches = nodes(recover, &local_call?(&1, :start_cleanup_replacement, 2))
    assert length(launches) == 1, "one cleanup launch without retry"
    companion_monitors = field_aliases([recover_head, recover], :state, :companion_monitor)
    companions = field_aliases([recover_head, recover], :state, :companion)

    old_down =
      clauses(recover)
      |> Enum.filter(fn {patterns, body} ->
        contains_call?(body, :start_cleanup_replacement, 2) and
          down_pattern?(patterns, companion_monitors, companions)
      end)

    assert length(old_down) == 1, "launch only after exact companion DOWN, never EXIT alone"

    forbidden_recovery =
      nodes([recover, launch, cleanup], fn
        {:owner_loop, _, _} -> true
        {:recover_companion_loss, _, _} -> true
        {{:., _, [{:__aliases__, _, [:Process]}, :link]}, _, _} -> true
        _ -> false
      end)

    assert forbidden_recovery == [],
           "terminal recovery has no owner link, retry or delivery return"

    expected_launch =
      quote do
        Task.Supervisor.start_child(task_supervisor, fn ->
          cleanup_replacement(cleanup_context)
        end)
      end

    task_starts = nodes(launch, &task_start?/1)

    assert Enum.map(task_starts, &strip/1) == [strip(expected_launch)],
           "one default-temporary supervised function task, never linked or restarting"

    # Local variable names need not be prescribed: resolve pins from the actual
    # state/context fields and exact Process.monitor arguments in executable AST.
    operation_refs = field_aliases(recover, :cleanup_context, :operation_ref)
    recovery_refs = field_aliases(recover, :cleanup_context, :recovery_ref)
    replacement_monitors = monitor_bindings(recover)

    ready_clauses =
      clauses(recover)
      |> Enum.filter(fn {patterns, _body} ->
        ready_pattern?(
          patterns,
          operation_refs,
          recovery_refs,
          Enum.map(replacement_monitors, &elem(&1, 1))
        )
      end)

    assert length(ready_clauses) == 1,
           "readiness matches operation_ref recovery_ref and exact replacement PID"

    [{_ready_pattern, ready_body}] = ready_clauses

    assert exact_exit?(ready_body, {:shutdown, :export_companion_lost}),
           "matching readiness exits the owner terminally"

    assert Enum.any?(clauses(recover), fn {patterns, body} ->
             Enum.any?(replacement_monitors, fn {monitor, replacement} ->
               down_pattern?(patterns, [monitor], [replacement])
             end) and exact_exit?(body, {:shutdown, :export_cleanup_unavailable})
           end),
           "replacement DOWN cannot count as readiness or cleanup success"

    assert shutdown_terminal?(recover), "supervisor shutdown remains terminal during recovery"

    assert match?({:cleanup_replacement, _, [{:%{}, _, _}]}, unguarded(cleanup_head)),
           "private cleanup takes exactly the four-key context"

    {:cleanup_replacement, _, [{:%{}, _, cleanup_fields}]} = unguarded(cleanup_head)

    assert Enum.sort(Keyword.keys(cleanup_fields)) == [
             :envelope,
             :operation_ref,
             :owner,
             :recovery_ref
           ],
           "private cleanup takes exactly the four-key context"

    owner = variable_name(Keyword.fetch!(cleanup_fields, :owner))
    envelope = variable_name(Keyword.fetch!(cleanup_fields, :envelope))
    operation_ref = variable_name(Keyword.fetch!(cleanup_fields, :operation_ref))
    recovery_ref = variable_name(Keyword.fetch!(cleanup_fields, :recovery_ref))
    cleanup_steps = expressions(Keyword.fetch!(cleanup, :do))
    assert match?([_, _ | _], cleanup_steps), "monitor owner before readiness"
    [monitor_step, readiness_step | _] = cleanup_steps
    monitors = monitor_bindings(monitor_step)
    assert match?([{_, ^owner}], monitors), "monitor exact context owner before readiness"
    [{owner_monitor, ^owner}] = monitors

    assert readiness_send?(readiness_step, owner, operation_ref, recovery_ref),
           "monitor owner before readiness"

    cleanups = nodes(cleanup, &directory_cleanup?/1)

    assert length(cleanups) == 1 and
             Enum.all?(cleanups, fn {{:., _, [_module, :cleanup]}, _, [argument]} ->
               variable?(argument, envelope)
             end),
           "cleanup uses unchanged envelope, never a reconstructed path"

    assert Enum.any?(clauses(cleanup), fn {patterns, body} ->
             down_pattern?(patterns, [owner_monitor], [owner]) and
               nodes(body, &directory_cleanup?/1) == cleanups
           end),
           "delete only after replacement's exact owner monitor DOWN"

    assert nodes(cleanup, fn
             {:receive, _, [options]} -> Keyword.has_key?(options, :after)
             _ -> false
           end) == [],
           "no timeout substitutes for owner DOWN"

    assert Enum.any?(clauses(cleanup), fn {patterns, body} ->
             nodes(patterns, fn
               {:error, _} -> true
               _ -> false
             end) != [] and
               exact_exit?(body, {:shutdown, :export_cleanup_failed})
           end),
           "cleanup error cannot be reported as normal success"

    assert nodes([recover, launch, cleanup], &recovery_authority?/1) == [],
           "recovery has no work runtime authority leases Writer or root scanning"
  end

  defp private_body!(artifact, name, arity) do
    matches = Enum.filter(definitions(artifact), &named?(&1, name, arity))
    assert match?([{:defp, _, _}], matches), "private #{name}/#{arity} exists once"
    [{:defp, head, body}] = matches
    {head, body}
  end

  defp field_aliases(ast, base, key) do
    assignments =
      nodes(ast, fn
        {:=, _, [_left, _right]} -> true
        _ -> false
      end)

    direct =
      for {:=, _, [left, {{:., _, [receiver, ^key]}, _, []}]} <- assignments,
          variable?(receiver, base),
          do: variable_name(left)

    destructured =
      for {:=, _, [{:%{}, _, fields}, right]} <- assignments,
          variable?(right, base),
          Keyword.has_key?(fields, key),
          do: variable_name(Keyword.fetch!(fields, key))

    (direct ++ destructured) |> Enum.reject(&is_nil/1) |> Enum.uniq()
  end

  defp clauses(ast),
    do:
      for(
        {:->, _, [patterns, body]} <- nodes(ast, &match?({:->, _, _}, &1)),
        do: {patterns, body}
      )

  defp down_pattern?(patterns, monitors, owners) do
    nodes(patterns, fn
      {:{}, _, [:DOWN, monitor, :process, owner, _reason]} ->
        pinned_from?(monitor, monitors) and pinned_from?(owner, owners)

      _ ->
        false
    end) != []
  end

  defp ready_pattern?(patterns, operations, recoveries, replacements) do
    nodes(patterns, fn
      {:{}, _, [:export_cleanup_ready, operation, recovery, replacement]} ->
        pinned_from?(operation, operations) and pinned_from?(recovery, recoveries) and
          pinned_from?(replacement, replacements)

      _ ->
        false
    end) != []
  end

  defp pinned_from?({:^, _, [variable]}, names), do: variable_name(variable) in names
  defp pinned_from?(_, _), do: false
  defp variable_name({name, _, context}) when is_atom(name) and is_atom(context), do: name
  defp variable_name(_), do: nil

  defp monitor_bindings(ast) do
    for {:=, _, [monitor, {{:., _, [{:__aliases__, _, [:Process]}, :monitor]}, _, [owner]}]} <-
          nodes(ast, &match?({:=, _, _}, &1)),
        not is_nil(variable_name(monitor)),
        not is_nil(variable_name(owner)),
        do: {variable_name(monitor), variable_name(owner)}
  end

  defp readiness_send?(ast, owner, operation_ref, recovery_ref) do
    nodes(ast, fn
      {:send, _,
       [destination, {:{}, _, [:export_cleanup_ready, operation, recovery, {:self, _, []}]}]} ->
        variable?(destination, owner) and variable?(operation, operation_ref) and
          variable?(recovery, recovery_ref)

      _ ->
        false
    end) != []
  end

  defp exact_exit?(ast, reason),
    do:
      nodes(ast, fn
        {:exit, _, [^reason]} -> true
        _ -> false
      end) != []

  defp shutdown_terminal?(ast),
    do:
      Enum.any?(clauses(ast), fn {patterns, body} ->
        nodes(patterns, fn
          {:{}, _, [:EXIT, _, :shutdown]} -> true
          _ -> false
        end) != [] and
          (exact_exit?(body, :shutdown) or
             exact_exit?(body, {:shutdown, :export_cleanup_unavailable}))
      end)

  defp local_call?({name, _, args}, name, arity) when is_list(args), do: length(args) == arity
  defp local_call?(_, _, _), do: false

  defp task_start?({{:., _, [{:__aliases__, _, [:Task, :Supervisor]}, :start_child]}, _, _}),
    do: true

  defp task_start?(_), do: false

  defp directory_cleanup?({{:., _, [{:__aliases__, _, parts}, :cleanup]}, _, _}),
    do: List.last(parts) == :ArtifactDirectory

  defp directory_cleanup?(_), do: false

  defp recovery_authority?({:__aliases__, _, parts}),
    do:
      List.last(parts) in [
        :Writer,
        :Leases,
        :Export,
        :File,
        :Spool,
        :KeyCustodian,
        :OperationScope,
        :Authorize,
        :DownloadLease
      ]

  defp recovery_authority?({name, _, _}) when name in [:work, :materialize, :scavenge], do: true
  defp recovery_authority?({:runtime, _, context}) when is_atom(context), do: true
  defp recovery_authority?(_), do: false

  defp recovery_mutation!(artifact, mutation) do
    case mutation do
      :spawn_before_companion_down ->
        {change_recovery_body!(artifact, :recover_companion_loss, fn body ->
           [call] = nodes(body, &local_call?(&1, :start_cleanup_replacement, 2))

           changed =
             replace_once!(body, &(&1 == call), fn _ -> quote(do: {:error, :unavailable}) end)

           block([call, Keyword.fetch!(changed, :do)]) |> then(&[do: &1])
         end), "launch only after exact companion DOWN"}

      :accept_exit_without_matching_down ->
        {change_recovery_body!(artifact, :recover_companion_loss, fn body ->
           replace_once!(
             body,
             fn
               {:->, _, [patterns, branch]} ->
                 contains_call?(branch, :start_cleanup_replacement, 2) and
                   nodes(patterns, fn
                     {:{}, _, [:DOWN, _, :process, _, _]} -> true
                     _ -> false
                   end) != []

               _ ->
                 false
             end,
             fn {:->, meta, [patterns, branch]} ->
               changed =
                 replace_once!(
                   patterns,
                   fn
                     {:{}, _, [:DOWN, _, :process, _, _]} -> true
                     _ -> false
                   end,
                   fn {:{}, pattern_meta, [_tag | rest]} ->
                     {:{}, pattern_meta, [:EXIT | rest]}
                   end
                 )

               {:->, meta, [changed, branch]}
             end
           )
         end), "launch only after exact companion DOWN"}

      :ready_before_owner_monitor ->
        {change_recovery_body!(artifact, :cleanup_replacement, fn body ->
           [monitor, ready | rest] = expressions(Keyword.fetch!(body, :do))
           Keyword.put(body, :do, block([ready, monitor | rest]))
         end), "monitor exact context owner before readiness"}

      key
      when key in [
             :accept_wrong_operation_ref,
             :accept_wrong_recovery_ref,
             :accept_wrong_replacement_pid
           ] ->
        index =
          %{
            accept_wrong_operation_ref: 1,
            accept_wrong_recovery_ref: 2,
            accept_wrong_replacement_pid: 3
          }[key]

        {change_recovery_body!(artifact, :recover_companion_loss, fn body ->
           replace_once!(
             body,
             fn
               {:{}, _, [:export_cleanup_ready, _, _, _]} -> true
               _ -> false
             end,
             fn {:{}, meta, fields} ->
               {:{}, meta, List.replace_at(fields, index, Macro.var(:_wrong, nil))}
             end
           )
         end), "readiness matches operation_ref recovery_ref and exact replacement PID"}

      :delete_before_owner_down ->
        {change_recovery_body!(artifact, :cleanup_replacement, fn body ->
           [call] = nodes(body, &directory_cleanup?/1)
           changed = replace_once!(body, &(&1 == call), fn _ -> :ok end)
           [monitor, ready | rest] = expressions(Keyword.fetch!(changed, :do))
           Keyword.put(changed, :do, block([monitor, ready, call | rest]))
         end), "delete only after replacement's exact owner monitor DOWN"}

      :monitor_different_owner ->
        {change_recovery_body!(artifact, :cleanup_replacement, fn body ->
           replace_once!(
             body,
             fn
               {{:., _, [{:__aliases__, _, [:Process]}, :monitor]}, _, [_]} -> true
               _ -> false
             end,
             fn {{:., dot_meta, target}, meta, _args} ->
               {{:., dot_meta, target}, meta, [quote(do: self())]}
             end
           )
         end), "monitor exact context owner before readiness"}

      :cleanup_reconstructed_path ->
        {change_recovery_body!(artifact, :cleanup_replacement, fn body ->
           replace_once!(body, &directory_cleanup?/1, fn {target, meta, [envelope]} ->
             {target, meta, [quote(do: %{path: unquote(envelope).path})]}
           end)
         end), "cleanup uses unchanged envelope"}

      :pass_work_or_runtime ->
        {change_recovery_body!(artifact, :recover_companion_loss, fn body ->
           replace_once!(
             body,
             fn
               {:=, _, [{:cleanup_context, _, _}, {:%{}, _, _}]} -> true
               _ -> false
             end,
             fn {:=, meta, [variable, {:%{}, map_meta, fields}]} ->
               {:=, meta,
                [variable, {:%{}, map_meta, fields ++ [work: Macro.var(:runtime, nil)]}]}
             end
           )
         end), "one exact identity-only cleanup context"}

      :link_replacement_to_owner ->
        {change_recovery_body!(artifact, :cleanup_replacement, fn body ->
           Keyword.put(
             body,
             :do,
             block([quote(do: Process.link(owner)), Keyword.fetch!(body, :do)])
           )
         end), "terminal recovery has no owner link"}

      :restart_replacement ->
        {change_recovery_body!(artifact, :start_cleanup_replacement, fn body ->
           replace_once!(body, &task_start?/1, fn {target, meta, args} ->
             {target, meta, args ++ [[restart: :permanent]]}
           end)
         end), "one default-temporary supervised function task"}

      :retry_replacement_on_failure ->
        {change_recovery_body!(artifact, :recover_companion_loss, fn body ->
           [call] = nodes(body, &local_call?(&1, :start_cleanup_replacement, 2))
           Keyword.put(body, :do, block([Keyword.fetch!(body, :do), call]))
         end), "one cleanup launch without retry"}

      :return_to_delivery_after_recovery ->
        {change_recovery_body!(artifact, :recover_companion_loss, fn body ->
           Keyword.put(
             body,
             :do,
             block([Keyword.fetch!(body, :do), quote(do: owner_loop(state))])
           )
         end), "terminal recovery has no owner link, retry or delivery return"}

      :ignore_supervisor_shutdown ->
        {change_recovery_body!(artifact, :recover_companion_loss, fn body ->
           replace_once!(
             body,
             fn
               {:->, _, [patterns, _]} ->
                 nodes(patterns, fn
                   {:{}, _, [:EXIT, _, :shutdown]} -> true
                   _ -> false
                 end) != []

               _ ->
                 false
             end,
             fn {:->, meta, [patterns, _]} -> {:->, meta, [patterns, :ok]} end
           )
         end), "supervisor shutdown remains terminal"}

      :report_cleanup_error_as_success ->
        {change_recovery_body!(artifact, :cleanup_replacement, fn body ->
           replace_once!(
             body,
             fn
               {:exit, _, [{:shutdown, :export_cleanup_failed}]} -> true
               _ -> false
             end,
             fn _ -> :ok end
           )
         end), "cleanup error cannot be reported as normal success"}
    end
  end

  defp change_recovery_body!(artifact, name, change) do
    replace_once!(
      artifact,
      fn
        {:defp, _, [head, _]} -> function_name(head) == name
        _ -> false
      end,
      fn {:defp, meta, [head, body]} -> {:defp, meta, [head, change.(body)]} end
    )
  end

  defp replace_once!(ast, predicate, replacement) do
    {changed, count} =
      Macro.prewalk(ast, 0, fn node, count ->
        if predicate.(node), do: {replacement.(node), count + 1}, else: {node, count}
      end)

    assert count == 1, "mutation must find exactly one intended executable node"
    changed
  end

  defp definition?({kind, _, [_head, body]}) when kind in [:def, :defp], do: is_list(body)
  defp definition?(_), do: false

  defp named?({_kind, head, _body}, name, arity),
    do:
      function_name(head) == name and
        match?({^name, _, args} when is_list(args) and length(args) == arity, unguarded(head))

  defp function_name(head), do: head |> unguarded() |> elem(0)
  defp unguarded({:when, _, [head | _]}), do: head
  defp unguarded(head), do: head

  defp generate_call?({{:., _, [{:__aliases__, _, parts}, :generate]}, _, _args}),
    do: parts in [[:ExportArtifact], @artifact_module]

  defp generate_call?(_), do: false

  defp work_call?({{:., _, [{:work, _, _}]}, _, _arguments}), do: true
  defp work_call?(_), do: false

  defp reverse_export?({:__aliases__, _, [:Export | _]}), do: true

  defp reverse_export?({:__aliases__, _, [:Singularity, :Runtime, :Knowledge, :Export | _]}),
    do: true

  defp reverse_export?(value) when is_atom(value),
    do: value == Singularity.Runtime.Knowledge.Export

  defp reverse_export?(_), do: false

  # Native adapter delegation may legitimately use apply(module, function, args).
  # Reject work/materializer selection, not every fixed native adapter apply.
  defp materializer_dispatch?({:materialize, _, _}), do: true
  defp materializer_dispatch?(:materialize), do: true

  defp materializer_dispatch?({{:., _, [_module, function]}, _, arguments})
       when function in [:get, :fetch!, :fetch, :get_env, :fetch_env!, :put] and
              is_list(arguments),
       do: Enum.any?(arguments, &(&1 in @selection_keys))

  defp materializer_dispatch?({:apply, _, arguments}),
    do: contains_variable?(arguments, :work)

  defp materializer_dispatch?({{:., _, [_module, :apply]}, _, arguments}),
    do: contains_variable?(arguments, :work)

  defp materializer_dispatch?(_), do: false

  defp retains_work?({:%{}, _, fields}), do: contains_variable?(fields, :work)

  defp retains_work?({{:., _, [{:__aliases__, _, [:Map]}, function]}, _, args})
       when function in [:put, :merge, :update, :update!],
       do: contains_variable?(args, :work)

  defp retains_work?({:owner_loop, _, args}), do: contains_variable?(args, :work)
  defp retains_work?({:send, _, args}), do: contains_variable?(args, :work)
  defp retains_work?({:receive, _, _} = node), do: contains_variable?(node, :work)
  defp retains_work?(_), do: false

  defp contains_variable?(ast, name), do: nodes(ast, &variable?(&1, name)) != []
  defp variable?({name, _, context}, name) when is_atom(context), do: true
  defp variable?(_, _), do: false

  defp contains_call?(ast, name, arity),
    do:
      nodes(ast, fn
        {^name, _, args} when is_list(args) -> length(args) == arity
        _ -> false
      end) != []

  defp nodes(ast, predicate) do
    {_ast, reversed} =
      Macro.prewalk(ast, [], fn node, acc ->
        {node, if(predicate.(node), do: [node | acc], else: acc)}
      end)

    Enum.reverse(reversed)
  end

  defp executable(ast) do
    Macro.prewalk(ast, fn
      {:@, _, [{name, _, _}]} when name in [:moduledoc, :doc, :typedoc] -> nil
      node -> node
    end)
  end

  defp strip(ast),
    do:
      Macro.prewalk(ast, fn
        {name, meta, context} when is_atom(name) and is_list(meta) and is_atom(context) ->
          {name, [], nil}

        {name, meta, arguments} when is_list(meta) ->
          {name, [], arguments}

        node ->
          node
      end)

  defp change_forward_body(ast, change) do
    Macro.prewalk(ast, fn
      {:defp, meta, [head, body]} = node ->
        if function_name(head) == :record_and_forward do
          changed = body |> Keyword.fetch!(:do) |> expressions() |> change.() |> block()
          {:defp, meta, [head, Keyword.put(body, :do, changed)]}
        else
          node
        end

      node ->
        node
    end)
  end

  defp expressions({:__block__, _, expressions}), do: expressions
  defp expressions(expression), do: [expression]

  defp append_to_module(ast, parts, addition) do
    Macro.prewalk(ast, fn
      {:defmodule, meta, [{:__aliases__, _, ^parts} = name, body]} ->
        {:defmodule, meta, [name, Keyword.update!(body, :do, &block([&1, addition]))]}

      node ->
        node
    end)
  end

  defp block(expressions), do: {:__block__, [], expressions}

  # TASK17_INTERNAL_WRITE_FORWARDING_BEGIN
  @task17_write_entry "                     write: Map.get(runtime, :knowledge_export_write, &IO.binwrite/2),\n"
  @task17_export_preimage "dab8881c7685bc967bb214736f167b6f37808040eb8adeaf48a2da9567ca8009"

  # Exact source attribution only; actual Api/native/Writer RED/GREEN and
  # lifetime cleanup remain separate compiled-runtime requirements.
  test "Task17 forwards only the existing internal Writer callback with the production IO default" do
    source = File.read!(Path.join(@repo_root, @export_path))
    assert :ok = task17_write_forwarding_contract!(source)
  end

  test "Task17 forwarding validator rejects missing duplicate changed-default and unrelated amendments" do
    source = File.read!(Path.join(@repo_root, @export_path))
    assert :ok = task17_write_forwarding_contract!(source)

    mutants = [
      String.replace(source, @task17_write_entry, "", global: false),
      source <> @task17_write_entry,
      String.replace(source, "&IO.binwrite/2", "&File.write/2", global: false),
      source <> "\n# unrelated source amendment\n"
    ]

    for mutant <- mutants do
      assert :ok = task17_write_forwarding_contract!(source)
      assert_raise ExUnit.AssertionError, fn -> task17_write_forwarding_contract!(mutant) end
    end
  end

  defp task17_write_forwarding_contract!(source) do
    assert length(:binary.matches(source, @task17_write_entry)) == 1,
           "exactly one trusted Writer write entry with IO.binwrite default"

    assert length(:binary.matches(source, ":knowledge_export_write")) == 1,
           "the internal key has only the trusted forwarding callsite"

    inverse = String.replace(source, @task17_write_entry, "", global: false)

    assert Base.encode16(:crypto.hash(:sha256, inverse), case: :lower) == @task17_export_preimage,
           "all other accepted Export source bytes remain unchanged"

    :ok
  end

  # TASK17_INTERNAL_WRITE_FORWARDING_END
end
