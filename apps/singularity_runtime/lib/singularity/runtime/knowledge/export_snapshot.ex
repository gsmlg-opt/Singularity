defmodule Singularity.Runtime.Knowledge.ExportSnapshot do
  @moduledoc false

  alias Singularity.Core.{Error, KnowledgeExport}
  alias Singularity.Runtime.{Authorize, OperationScope, SessionContext}
  alias Singularity.Storage.KnowledgeExport.{Repository, Spool}
  alias Singularity.Storage.Postgres.KnowledgeError

  @requirements %{
    required_capabilities: ["asset.read", "note.read"],
    classification: :private,
    requires_unlocked?: true
  }

  def capture(runtime, session, options, spool) do
    case capture_scoped(runtime, session, options, spool) do
      {:ok, sealed} ->
        {:ok, sealed}

      {:error, %Error{}} = error ->
        abort(spool)
        error
    end
  end

  # OperationScope prepends the existing trusted adapter as this callback's
  # context. RR is set by that adapter before context or authorization SQL.
  def transact(adapter, repo, context, callback) when is_function(callback, 1) do
    if repo.in_transaction?(),
      do: invalid(),
      else: call(adapter, :transact, [repo, context, [isolation: :repeatable_read], callback])
  end

  defp capture_scoped(runtime, %SessionContext{} = session, input, spool)
       when is_map(runtime) do
    with {:ok, options} <- KnowledgeExport.options(input),
         false <- repo_module(runtime.request_repo).in_transaction?() do
      requirement =
        Map.merge(@requirements, %{
          vault_id: session.vault_id,
          principal_authorization_epoch:
            session.principal_authorization_epoch || session.authorization_epoch,
          vault_authorization_epoch: session.vault_authorization_epoch
        })

      # Only this private copy changes. Shared scope, policy and custody
      # adapters and the caller's runtime value retain their existing behavior.
      scoped_runtime = Map.put(runtime, :scoped_repo, {__MODULE__, runtime.scoped_repo})

      result =
        OperationScope.with_shared_request(scoped_runtime, session, requirement, fn repo ->
          caller = self()

          authorize_snapshot = fn candidate_repo ->
            if self() == caller and candidate_repo == repo and repo.in_transaction?() do
              with :ok <- Authorize.check(runtime.authorization, repo, session, requirement),
                   do: {:ok, session}
            else
              invalid()
            end
          end

          call(Map.get(runtime, :knowledge_export_repository, Repository), :capture, [
            repo,
            authorize_snapshot,
            options,
            spool
          ])
        end)

      # The unchanged scoped adapter has now returned from the real COMMIT.
      # No SQL stream or uncommitted descriptor escapes this entry.
      case result do
        {:ok, %{capture_id: capture_id} = sealed} ->
          if capture_id == spool.capture_id and
               not repo_module(runtime.request_repo).in_transaction?(),
             do: {:ok, sealed},
             else: invalid()

        {:error, %Error{} = error} ->
          {:error, KnowledgeError.from(error)}

        _invalid ->
          invalid()
      end
    else
      {:error, %Error{} = error} -> {:error, KnowledgeError.from(error)}
      _invalid -> invalid()
    end
  rescue
    error -> {:error, KnowledgeError.from(error)}
  catch
    _kind, _reason -> {:error, Error.new(:storage_unavailable, retryable?: true)}
  end

  defp capture_scoped(_runtime, _session, _input, _spool), do: invalid()

  defp abort(spool) do
    # The original descriptor must also invalidate a spool sealed inside a
    # callback whose transaction subsequently failed to commit.
    Spool.abort(spool)
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp repo_module(module) when is_atom(module) and not is_nil(module), do: module
  defp repo_module({module, _context}) when is_atom(module) and not is_nil(module), do: module

  defp call(module, function, arguments) when is_atom(module) and not is_nil(module),
    do: apply(module, function, arguments)

  defp call({module, context}, function, arguments) when is_atom(module) and not is_nil(module),
    do: apply(module, function, [context | arguments])

  defp invalid, do: {:error, Error.new(:invalid)}
end
