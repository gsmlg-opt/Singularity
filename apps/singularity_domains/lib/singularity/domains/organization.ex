defmodule Singularity.Domains.Organization do
  @moduledoc """
  Pure dispatch for bounded organization queries on an existing authenticated scope.

  Allowed kinds are trusted Runtime input, not a substitute for current authorization.
  """

  alias Singularity.Core.{Error, OrganizationPage, OrganizationPageQuery, Types}

  @ports %{
    resource_tags: {:tags, :list_page_in_scope},
    tag_resources: {:tags, :browse_in_scope},
    outgoing: {:relationships, :outgoing_page_in_scope},
    incoming: {:relationships, :incoming_page_in_scope}
  }

  @spec page(term(), term(), term(), term(), term()) ::
          {:ok, OrganizationPage.t()} | {:error, Error.t()}
  def page(adapters, operation, selector_id, query, allowed_kinds)
      when is_map(adapters) and not is_struct(adapters) do
    with {:ok, {port, callback}} <- Map.fetch(@ports, operation),
         {:ok, selector_id} <- Types.canonical_uuid(%{selector_id: selector_id}, :selector_id),
         {:ok, query} <- OrganizationPageQuery.validate(query),
         :ok <- allowed_kinds(allowed_kinds, []),
         {:ok, module, context} <- adapter(Map.get(adapters, port), callback) do
      module
      |> apply(callback, [context, selector_id, query, allowed_kinds])
      |> result(operation, query)
    else
      _invalid -> Types.invalid()
    end
  rescue
    _exception -> unavailable()
  catch
    _, _ -> unavailable()
  end

  def page(_adapters, _operation, _selector_id, _query, _allowed_kinds), do: Types.invalid()

  defp adapter({module, context}, callback) when is_atom(module) and not is_nil(module) do
    with {:module, _} <- Code.ensure_loaded(module),
         true <- function_exported?(module, callback, 4) do
      {:ok, module, context}
    else
      _invalid -> Types.invalid()
    end
  end

  defp adapter(_adapter, _callback), do: Types.invalid()

  defp allowed_kinds([], _seen), do: :ok

  defp allowed_kinds([kind | rest], seen) when kind in [:asset, :document, :note] do
    if kind in seen,
      do: Types.invalid(),
      else: allowed_kinds(rest, [kind | seen])
  end

  defp allowed_kinds(_kinds, _seen), do: Types.invalid()

  defp result({:ok, page}, operation, query), do: OrganizationPage.new(operation, page, query)

  defp result({:error, %Error{code: code, retryable?: retryable?}}, _operation, _query)
       when is_boolean(retryable?) do
    if code in Error.codes(),
      do: {:error, Error.new(code, retryable?: retryable?)},
      else: unavailable()
  end

  defp result(_result, _operation, _query), do: unavailable()

  defp unavailable, do: {:error, Error.new(:storage_unavailable, retryable?: true)}
end
