defmodule Singularity.Domains.Vaults do
  @moduledoc "Pure orchestration for vault authorization."

  alias Singularity.Core.Capability
  alias Singularity.Core.Error
  alias Singularity.Core.Types

  @spec authorize(%{repository: module(), context: term()}, map()) ::
          :ok | {:error, Error.t()}
  def authorize(%{repository: repository, context: context}, command)
      when is_atom(repository) and is_map(command) do
    case authorization_request(command) do
      {:ok, request} ->
        authorize_request(repository, context, request)

      {:error, %Error{}} ->
        {:error, Error.new(:forbidden)}
    end
  end

  def authorize(_adapters, _command), do: {:error, Error.new(:invalid)}

  defp authorize_request(repository, context, request) do
    with {:ok, authorization} <-
           repository.resolve_authorization(
             context,
             Map.take(request, [:principal_id, :vault_id])
           ),
         :ok <- authorize_membership(authorization, request) do
      require_unlocked(authorization, request)
    end
  end

  defp authorization_request(command) do
    with {:ok, principal_id} <- Types.opaque_string(command, :principal_id),
         {:ok, vault_id} <- Types.opaque_string(command, :vault_id),
         {:ok, required_capability} <-
           Capability.new(%{name: Map.get(command, :required_capability)}),
         {:ok, authorization_epoch} <-
           Types.non_neg_integer(command, :authorization_epoch),
         {:ok, requires_unlocked?} <-
           Types.boolean(command, :requires_unlocked?, false) do
      {:ok,
       %{
         principal_id: principal_id,
         vault_id: vault_id,
         required_capability: required_capability,
         authorization_epoch: authorization_epoch,
         requires_unlocked?: requires_unlocked?
       }}
    end
  end

  defp authorize_membership(%{} = authorization, request) do
    with true <- authorization[:principal_id] == request.principal_id,
         true <- authorization[:vault_id] == request.vault_id,
         true <- authorization[:status] == :active,
         {:ok, capabilities} <- capabilities(authorization[:capabilities]),
         true <- Capability.contains?(capabilities, request.required_capability),
         true <-
           is_integer(authorization[:authorization_epoch]) and
             authorization[:authorization_epoch] >= 0,
         true <- authorization[:authorization_epoch] == request.authorization_epoch,
         true <- is_boolean(authorization[:locked?]) do
      :ok
    else
      _denial -> {:error, Error.new(:forbidden)}
    end
  end

  defp authorize_membership(_authorization, _request),
    do: {:error, Error.new(:forbidden)}

  defp capabilities(capabilities) when is_list(capabilities) do
    Enum.reduce_while(capabilities, {:ok, []}, fn capability, {:ok, acc} ->
      case Capability.new(%{name: capability}) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, %Error{}} = error -> {:halt, error}
      end
    end)
  end

  defp capabilities(_capabilities), do: {:error, Error.new(:invalid)}

  defp require_unlocked(%{locked?: true}, %{requires_unlocked?: true}),
    do: {:error, Error.new(:vault_locked)}

  defp require_unlocked(_authorization, _request), do: :ok
end
