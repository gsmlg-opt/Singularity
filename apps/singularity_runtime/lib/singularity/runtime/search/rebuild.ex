defmodule Singularity.Runtime.Search.Rebuild do
  @moduledoc "Rebuilds search projections from canonical identities under existing read authority."

  alias Singularity.Core.{Error, Types}
  alias Singularity.Runtime.{OperationScope, SessionContext}
  alias Singularity.Storage.{RequestRepo, ScopedRepo}
  alias Singularity.Storage.Postgres.SearchProjectionReconciler

  @batch_size 100
  @max_count 9_223_372_036_854_775_807

  @spec run(map(), SessionContext.t(), term()) ::
          {:ok, %{resources: non_neg_integer(), entries: non_neg_integer()}} | {:error, Error.t()}
  def run(runtime, %SessionContext{} = session, input) when is_map(runtime) do
    with {:ok, selector} <- validate_selector(input),
         {:ok, _owner} <- Types.canonical_uuid(%{owner: session.vault_id}, :owner) do
      case selector do
        :all -> sweep(runtime, session, nil, %{resources: 0, entries: 0})
        resource_id -> rebuild_one(runtime, session, resource_id)
      end
    end
  rescue
    _ -> unavailable()
  catch
    _, _ -> unavailable()
  end

  def run(_, _, _), do: {:error, Error.new(:invalid)}

  @doc false
  def validate_selector(:all), do: {:ok, :all}
  def validate_selector(value), do: Types.canonical_uuid(%{resource_id: value}, :resource_id)

  @doc false
  def validate_counts(%{resources: resources, entries: entries} = counts)
      when map_size(counts) == 2 and is_integer(resources) and resources >= 0 and
             resources <= @max_count and is_integer(entries) and entries >= 0 and
             entries <= @max_count,
      do: {:ok, counts}

  def validate_counts(_), do: unavailable()

  defp rebuild_one(runtime, session, resource_id) do
    with {:ok, kind} <- canonical_kind(runtime, session, resource_id),
         true <- kind in [:note, :document],
         {:ok, entries} <- reconcile(runtime, session, resource_id, kind) do
      validate_counts(%{resources: 1, entries: entries})
    else
      {:error, %Error{}} = error -> error
      _ -> unavailable()
    end
  end

  defp canonical_kind(runtime, session, resource_id) do
    request_repo = Map.get(runtime, :request_repo, RequestRepo)
    scoped_repo = Map.get(runtime, :scoped_repo, ScopedRepo)
    scope = %{principal_id: session.principal_id, vault_id: session.vault_id}

    # This preliminary scope reads only identity. The selected kind is freshly
    # authorized below before canonical content or reconciliation is accessed.
    request_repo
    |> call_adapter(:checkout, [
      fn ->
        call_adapter(scoped_repo, :transact, [
          adapter_module(request_repo),
          scope,
          fn repo -> call_adapter(reconciler(runtime), :resource_kind, [repo, resource_id]) end
        ])
      end
    ])
    |> sanitize()
  end

  defp sweep(runtime, session, after_id, counts) do
    with {:ok, ids} <-
           authorized(runtime, session, :all, fn repo ->
             call_adapter(reconciler(runtime), :list_resource_ids, [repo, after_id, @batch_size])
           end),
         :ok <- validate_page(ids, after_id),
         {:ok, counts} <- reconcile_page(runtime, session, ids, counts) do
      if length(ids) == @batch_size,
        do: sweep(runtime, session, List.last(ids), counts),
        else: validate_counts(counts)
    end
  end

  defp validate_page(ids, after_id) when is_list(ids) do
    valid? =
      length(ids) <= @batch_size and ids == Enum.sort(Enum.uniq(ids)) and
        Enum.all?(ids, fn id ->
          match?({:ok, ^id}, Types.canonical_uuid(%{id: id}, :id)) and
            (is_nil(after_id) or id > after_id)
        end)

    if valid?, do: :ok, else: unavailable()
  end

  defp validate_page(_, _), do: unavailable()

  defp reconcile_page(runtime, session, ids, counts) do
    Enum.reduce_while(ids, {:ok, counts}, fn id, {:ok, counts} ->
      with {:ok, entries} <- reconcile(runtime, session, id, :all),
           {:ok, next} <-
             validate_counts(%{
               resources: counts.resources + 1,
               entries: counts.entries + entries
             }) do
        {:cont, {:ok, next}}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp reconcile(runtime, session, resource_id, kind) do
    with {:ok, entries} <-
           authorized(runtime, session, kind, fn repo ->
             call_adapter(reconciler(runtime), :reconcile, [repo, resource_id])
           end),
         {:ok, _} <- validate_counts(%{resources: 1, entries: entries}) do
      {:ok, entries}
    end
  end

  defp authorized(runtime, session, kind, callback) do
    runtime
    |> Map.get(:operation_scope, OperationScope)
    |> call_adapter(:with_read_request, [runtime, session, requirement(session, kind), callback])
    |> sanitize()
  end

  defp requirement(session, kind) do
    base = %{
      vault_id: session.vault_id,
      classification: :private,
      requires_unlocked?: kind != :document
    }

    case kind do
      :note -> Map.put(base, :required_capability, "note.read")
      :document -> Map.put(base, :required_capability, "asset.read")
      :all -> Map.put(base, :required_capabilities, ["asset.read", "note.read"])
    end
  end

  defp reconciler(runtime),
    do: Map.get(runtime, :search_projection_reconciler, SearchProjectionReconciler)

  defp adapter_module(module) when is_atom(module), do: module
  defp adapter_module({module, _context}) when is_atom(module), do: module

  defp call_adapter(module, function, arguments) when is_atom(module) and not is_nil(module),
    do: apply(module, function, arguments)

  defp call_adapter({module, context}, function, arguments)
       when is_atom(module) and not is_nil(module),
       do: apply(module, function, [context | arguments])

  defp sanitize({:ok, _} = result), do: result

  defp sanitize({:error, %Error{code: code, retryable?: retryable?}})
       when is_boolean(retryable?) do
    if code in Error.codes(),
      do: {:error, Error.new(code, retryable?: retryable?)},
      else: unavailable()
  end

  defp sanitize(_), do: unavailable()
  defp unavailable, do: {:error, Error.new(:storage_unavailable, retryable?: true)}
end
