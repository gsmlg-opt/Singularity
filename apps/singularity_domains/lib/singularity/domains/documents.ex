defmodule Singularity.Domains.Documents do
  @moduledoc "Pure internal orchestration for private Document creation."
  alias Singularity.Core.{DocumentVersion, Error, Types}
  alias Singularity.Domains.Documents.Command

  @spec create(map(), Command.t()) :: {:ok, DocumentVersion.t()} | {:error, Error.t()}
  def create(adapters, %Command{} = command) do
    with {:ok, ^command} <- Command.new(command),
         {:ok, repository, context} <- repository(adapters) do
      repository_result(repository.create_pending(context, command), command)
    else
      _ -> Types.invalid()
    end
  end

  def create(_, _), do: Types.invalid()

  @spec get(map(), Types.id()) :: {:ok, DocumentVersion.t()} | {:error, Error.t()}
  def get(%{repository: repository, repository_context: {repo, context}}, resource_id)
      when is_atom(repository) and is_atom(repo),
      do: repository.get_live_scoped(repo, context, resource_id)

  def get(_, _), do: Types.invalid()

  defp repository(%{repository: repository, repository_context: context})
       when is_atom(repository) do
    if Code.ensure_loaded?(repository) and function_exported?(repository, :create_pending, 2),
      do: {:ok, repository, context},
      else: Types.invalid()
  end

  defp repository(_), do: Types.invalid()

  defp repository_result({:ok, %DocumentVersion{} = version}, command) do
    with {:ok, ^version} <- DocumentVersion.new(version),
         true <- version.owner_scope_id == command.owner_scope_id,
         true <- version.classification == command.classification,
         true <- version.created_by_principal_id == command.principal_id,
         true <- version.source == command.source and version.title == command.title do
      {:ok, version}
    else
      _ -> Types.invalid()
    end
  end

  defp repository_result({:error, %Error{} = error}, _) do
    if Map.keys(error) |> Enum.sort() == Enum.sort(Map.keys(%Error{code: :invalid})) and
         error.code in Error.codes() and is_boolean(error.retryable?) and
         (is_nil(error.message) or is_binary(error.message)) and is_map(error.details) do
      {:error, Error.new(error.code, retryable?: error.retryable?)}
    else
      Types.invalid()
    end
  end

  defp repository_result(_, _), do: Types.invalid()
end
