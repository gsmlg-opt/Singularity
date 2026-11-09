defmodule Singularity.Runtime.ResolveSession do
  @moduledoc "Resolves an opaque token through the pre-auth boundary."

  alias Singularity.Core.Error
  alias Singularity.Runtime.SessionContext

  @spec run(map(), binary()) :: {:ok, SessionContext.t()} | {:error, Error.t()}
  def run(adapters, opaque_token)
      when is_map(adapters) and is_binary(opaque_token) and
             byte_size(opaque_token) == 32 do
    digest = :crypto.hash(:sha256, opaque_token)

    with {:ok, resolved} when not is_nil(resolved) <-
           adapters.pre_auth.resolve_session(adapters.pre_auth_context, digest),
         unlocked? <-
           adapters.custodian.unlocked?(
             adapters.custodian_context,
             resolved.session_id
           ) do
      {:ok, SessionContext.from_resolved(resolved, unlocked?: unlocked?)}
    else
      _failure -> unauthenticated()
    end
  rescue
    _error -> unauthenticated()
  end

  def run(_adapters, _opaque_token), do: unauthenticated()

  defp unauthenticated, do: {:error, Error.new(:unauthenticated)}
end
