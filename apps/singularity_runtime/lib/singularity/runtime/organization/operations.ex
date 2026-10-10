defmodule Singularity.Runtime.Organization.Operations do
  @moduledoc "Authenticated, current-kind organization operations on one existing request scope."

  alias Singularity.Core.{Error, KnowledgeValidation, OrganizationPageQuery, Relationship, Tag}
  alias Singularity.Domains.Organization
  alias Singularity.Runtime.{Authorize, OperationScope, SessionContext}
  alias Singularity.Runtime.Organization.{Authorizer, DTO}

  alias Singularity.Storage.Postgres.{
    OrganizationRepository,
    RelationshipRepository,
    TagRepository
  }

  @pages %{
    list_resource_tags: :resource_tags,
    browse_resources_by_tag: :tag_resources,
    list_outgoing_relationships: :outgoing,
    list_backlinks: :incoming
  }
  @edge_keys [
    :relationship_id,
    :source_resource_id,
    :target_resource_id,
    :target_resource_version_id,
    :type
  ]

  for operation <- [:attach_tag, :detach_tag, :relate_resource] ++ Map.keys(@pages) do
    def unquote(operation)(runtime, session, selector, params),
      do: run(unquote(operation), runtime, session, selector, params)
  end

  def list_resource_tags(runtime, session, resource),
    do: list_resource_tags(runtime, session, resource, %{})

  def unrelate_resource(runtime, session, relationship),
    do: run(:unrelate_resource, runtime, session, relationship, nil)

  @doc false
  def validate(operation, selector, params) do
    if canonical_uuid?(selector),
      do: validate_params(operation, selector, params),
      else: invalid()
  end

  defp validate_params(:attach_tag, selector, params) do
    with {:ok, attrs} <- KnowledgeValidation.attrs(params, [:name]),
         {:ok, tag} <-
           Tag.new(%{
             tag_id: selector,
             owner_scope_id: selector,
             classification: :private,
             display_value: attrs[:name]
           }) do
      {:ok, %{name: tag.display_value}}
    end
  end

  defp validate_params(:detach_tag, _selector, tag) do
    if canonical_uuid?(tag), do: {:ok, tag}, else: invalid()
  end

  defp validate_params(:relate_resource, selector, params) do
    with {:ok, attrs} <-
           KnowledgeValidation.attrs(
             params,
             [:target_resource_id, :target_resource_version_id, :type]
           ),
         {:ok, _edge} <-
           Relationship.new(
             Map.merge(attrs, %{
               relationship_id: selector,
               source_resource_id: selector,
               owner_scope_id: selector,
               classification: :private
             })
           ) do
      {:ok, attrs}
    end
  end

  defp validate_params(:unrelate_resource, _selector, nil), do: {:ok, nil}

  defp validate_params(operation, _selector, params) when is_map_key(@pages, operation),
    do: OrganizationPageQuery.new(params)

  defp validate_params(_operation, _selector, _params), do: invalid()

  defp run(operation, runtime, %SessionContext{} = session, selector, params)
       when is_map(runtime) and not is_struct(runtime) do
    with :ok <- valid_session(session),
         {:ok, input} <- validate(operation, selector, params),
         {:ok, adapters} <- adapters(runtime) do
      mode = if is_map_key(@pages, operation), do: :read, else: :write
      scoped_runtime = Map.put(runtime, :authorizer, {Authorizer, adapters.authorizer})
      scope_function = if mode == :read, do: :with_read_request, else: :with_shared_request

      call(adapters.operation_scope, scope_function, [
        scoped_runtime,
        session,
        entry_requirement(session, mode),
        fn repo ->
          context = %{
            repo: repo,
            principal_id: session.principal_id,
            owner_scope_id: session.vault_id,
            correlation_id: Ecto.UUID.generate()
          }

          execute(operation, adapters, context, session, selector, input, params)
        end
      ])
      |> result(operation, session.vault_id, selector, params)
    end
  rescue
    _exception -> unavailable()
  catch
    _, _ -> unavailable()
  end

  defp run(_operation, _runtime, _session, _selector, _params), do: invalid()

  defp execute(:attach_tag, adapters, context, session, selector, input, params) do
    with {:ok, kinds} <- resources(adapters, context, [selector]),
         :ok <- authorize(adapters, context.repo, session, kinds[selector], :write),
         {:ok, candidate} <-
           Tag.new(%{
             tag_id: Ecto.UUID.generate(),
             owner_scope_id: context.owner_scope_id,
             classification: :private,
             display_value: input.name
           }),
         {:ok, stored} <- call(adapters.tags, :resolve_in_scope, [context, candidate]) |> reply(),
         {:ok, dto} <-
           DTO.convert(:attach_tag, {:ok, stored}, context.owner_scope_id, selector, params),
         :ok <- call(adapters.tags, :attach_in_scope, [context, selector, dto.tag_id]) |> unit() do
      {:ok, dto}
    end
  end

  defp execute(:detach_tag, adapters, context, session, selector, tag, _params) do
    with {:ok, kinds} <- resources(adapters, context, [selector]),
         :ok <- authorize(adapters, context.repo, session, kinds[selector], :write) do
      call(adapters.tags, :detach_in_scope, [context, selector, tag]) |> unit()
    end
  end

  defp execute(:relate_resource, adapters, context, session, selector, attrs, params) do
    target = attrs.target_resource_id

    with {:ok, kinds} <- resources(adapters, context, Enum.sort([selector, target])),
         :ok <- authorize(adapters, context.repo, session, kinds[selector], :write),
         :ok <- authorize(adapters, context.repo, session, kinds[selector], :read),
         :ok <- authorize(adapters, context.repo, session, kinds[target], :read),
         {:ok, candidate} <-
           Relationship.new(
             Map.merge(attrs, %{
               relationship_id: Ecto.UUID.generate(),
               source_resource_id: selector,
               owner_scope_id: context.owner_scope_id,
               classification: :private
             })
           ) do
      call(adapters.relationships, :relate_in_scope, [context, candidate])
      |> result(:relate_resource, context.owner_scope_id, selector, params)
    end
  end

  defp execute(:unrelate_resource, adapters, context, session, selector, _input, _params) do
    with {:ok, selected} <-
           call(adapters.metadata, :relationship_in_scope, [context, selector])
           |> reply() do
      unrelate(adapters, context, session, selector, selected)
    end
  end

  defp execute(operation, adapters, context, session, selector, query, params)
       when is_map_key(@pages, operation) do
    with :ok <- page_selector(operation, adapters, context, session, selector),
         {:ok, kinds} <- allowed_kinds(adapters, context.repo, session) do
      call(adapters.organization, :page, [
        %{tags: {adapters.tags, context}, relationships: {adapters.relationships, context}},
        Map.fetch!(@pages, operation),
        selector,
        query,
        kinds
      ])
      |> result(operation, context.owner_scope_id, selector, params)
    end
  end

  defp unrelate(_adapters, _context, _session, _selector, nil), do: :ok

  defp unrelate(adapters, context, session, selector, selected) do
    with :ok <- selected_edge(selected, context.owner_scope_id, selector),
         {:ok, kinds} <- resources(adapters, context, [selected.source_resource_id]),
         :ok <-
           authorize(adapters, context.repo, session, kinds[selected.source_resource_id], :write) do
      call(adapters.relationships, :unrelate_selected_in_scope, [context, selected]) |> unit()
    end
  end

  defp selected_edge(selected, owner, selector)
       when is_map(selected) and not is_struct(selected) do
    with true <- Enum.sort(Map.keys(selected)) == Enum.sort(@edge_keys),
         true <- selected.relationship_id === selector,
         {:ok, _edge} <-
           Relationship.new(
             Map.merge(
               selected,
               %{owner_scope_id: owner, classification: :private}
             )
           ) do
      :ok
    else
      _invalid -> integrity_failure()
    end
  end

  defp selected_edge(_selected, _owner, _selector), do: integrity_failure()

  defp page_selector(:browse_resources_by_tag, _adapters, _context, _session, _selector), do: :ok

  defp page_selector(_operation, adapters, context, session, selector) do
    with {:ok, kinds} <- resources(adapters, context, [selector]) do
      authorize(adapters, context.repo, session, kinds[selector], :read)
    end
  end

  defp resources(adapters, context, ids) do
    with {:ok, rows} <- call(adapters.metadata, :resources_in_scope, [context, ids]) |> reply(),
         true <- is_list(rows),
         true <- valid_resource_rows?(rows, ids) do
      {:ok, Map.new(rows, &{&1.resource_id, &1.kind})}
    else
      {:error, _} = error -> error
      _invalid -> integrity_failure()
    end
  end

  defp valid_resource_rows?([], []), do: true

  defp valid_resource_rows?([row | rows], [id | ids])
       when is_map(row) and not is_struct(row) and map_size(row) == 2 do
    row[:resource_id] === id and row[:kind] in [:asset, :document, :note] and
      valid_resource_rows?(rows, ids)
  end

  defp valid_resource_rows?(_rows, _ids), do: false

  defp allowed_kinds(adapters, repo, session) do
    with {:ok, assets?} <- allowed(adapters, repo, session, :asset),
         {:ok, notes?} <- allowed(adapters, repo, session, :note) do
      {:ok,
       if(assets?, do: [:asset, :document], else: []) ++
         if(notes?, do: [:note], else: [])}
    end
  end

  defp allowed(adapters, repo, session, kind) do
    case authorize(adapters, repo, session, kind, :read) do
      :ok ->
        {:ok, true}

      {:error, %Error{code: code, retryable?: false}} when code in [:forbidden, :vault_locked] ->
        {:ok, false}

      error ->
        error
    end
  end

  defp authorize(adapters, repo, session, kind, access) do
    prefix = if kind == :note, do: "note", else: "asset"

    required =
      requirement(session, kind == :note)
      |> Map.put(:required_capability, prefix <> "." <> Atom.to_string(access))

    call(adapters.authorizer, :check, [adapters.authorization, repo, session, required])
    |> authorization_result()
  end

  defp entry_requirement(session, mode),
    do: Map.put(requirement(session, true), :organization_access, mode)

  defp requirement(session, unlocked?) do
    %{
      vault_id: session.vault_id,
      classification: :private,
      requires_unlocked?: unlocked?,
      principal_authorization_epoch:
        session.principal_authorization_epoch || session.authorization_epoch,
      vault_authorization_epoch: session.vault_authorization_epoch
    }
  end

  defp adapters(runtime) do
    values = %{
      operation_scope: Map.get(runtime, :operation_scope, OperationScope),
      authorizer: Map.get(runtime, :authorizer, Authorize),
      authorization: Map.get(runtime, :authorization),
      metadata: Map.get(runtime, :organization_repository, OrganizationRepository),
      tags: Map.get(runtime, :tag_repository, TagRepository),
      relationships: Map.get(runtime, :relationship_repository, RelationshipRepository),
      organization: Map.get(runtime, :organization, Organization)
    }

    if Enum.all?(Map.delete(values, :authorization), fn {_key, value} -> adapter?(value) end),
      do: {:ok, values},
      else: invalid()
  end

  defp adapter?(module) when is_atom(module), do: module not in [nil, false, true, Authorizer]
  defp adapter?({module, _context}), do: adapter?(module)
  defp adapter?(_adapter), do: false

  defp valid_session(session) do
    if Enum.sort(Map.keys(session)) == Enum.sort(Map.keys(SessionContext.__struct__())) and
         canonical_uuid?(session.principal_id) and canonical_uuid?(session.vault_id),
       do: :ok,
       else: invalid()
  end

  defp result({:error, _} = error, _operation, _owner, _selector, _params),
    do: error_result(error)

  defp result(reply, operation, owner, selector, params),
    do: DTO.convert(operation, reply, owner, selector, params)

  defp reply({:ok, _} = value), do: value
  defp reply({:error, _} = error), do: error_result(error)
  defp reply(_invalid), do: integrity_failure()

  defp unit(:ok), do: :ok
  defp unit({:error, _} = error), do: error_result(error)
  defp unit(_invalid), do: integrity_failure()

  defp authorization_result(:ok), do: :ok
  defp authorization_result(result), do: error_result(result)

  defp error_result({:error, %Error{} = error}) do
    if Enum.sort(Map.keys(error)) == Enum.sort(Map.keys(Error.__struct__())) and
         error.code in Error.codes() and is_boolean(error.retryable?),
       do: {:error, Error.new(error.code, retryable?: error.retryable?)},
       else: unavailable()
  end

  defp error_result(_invalid), do: unavailable()

  defp canonical_uuid?(value), do: Ecto.UUID.cast(value) == {:ok, value}
  defp call(module, function, args) when is_atom(module), do: apply(module, function, args)
  defp call({module, context}, function, args), do: apply(module, function, [context | args])
  defp invalid, do: {:error, Error.new(:invalid)}
  defp integrity_failure, do: {:error, Error.new(:integrity_failure)}
  defp unavailable, do: {:error, Error.new(:storage_unavailable, retryable?: true)}
end
