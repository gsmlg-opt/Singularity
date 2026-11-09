defmodule Singularity.Domains.Identity do
  @moduledoc "Pure orchestration for identity bootstrap workflows."

  alias Singularity.Core.Error
  alias Singularity.Core.Types

  @spec bootstrap_owner(
          %{repository: module(), context: term()},
          map()
        ) :: {:ok, map()} | {:error, Error.t()}
  def bootstrap_owner(%{repository: repository, context: context}, command)
      when is_atom(repository) and is_map(command) do
    with {:ok, idempotency_key} <- Types.opaque_string(command, :idempotency_key),
         {:ok, owner} <- owner(Map.get(command, :owner)),
         {:ok, credential} <- credential(Map.get(command, :credential)) do
      repository.bootstrap_owner(context, %{
        idempotency_key: idempotency_key,
        owner: owner,
        credential: credential
      })
    end
  end

  def bootstrap_owner(_adapters, _command), do: {:error, Error.new(:invalid)}

  defp owner(%{} = attrs) do
    with {:ok, id} <- Types.opaque_string(attrs, :id),
         :ok <- require_owner_kind(Map.get(attrs, :kind)) do
      {:ok, %{id: id, kind: :owner}}
    end
  end

  defp owner(_attrs), do: {:error, Error.new(:invalid)}

  defp credential(%{} = attrs) do
    with {:ok, id} <- Types.opaque_string(attrs, :id),
         {:ok, secret_hash} <- Types.opaque_string(attrs, :secret_hash) do
      {:ok, %{id: id, secret_hash: secret_hash}}
    end
  end

  defp credential(_attrs), do: {:error, Error.new(:invalid)}

  defp require_owner_kind(:owner), do: :ok
  defp require_owner_kind(_kind), do: {:error, Error.new(:invalid)}
end
