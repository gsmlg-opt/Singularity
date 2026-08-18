defmodule Singularity.Domains.Notes do
  @moduledoc "Pure orchestration for canonical private note mutations."

  alias Singularity.Core.Error
  alias Singularity.Core.NoteSnapshot
  alias Singularity.Domains.Notes.Command

  @spec execute(map(), Command.t(), binary()) :: {:ok, term()} | {:error, Error.t()}
  def execute(adapters, %Command{} = command, <<_::binary-size(32)>> = fingerprint) do
    with {:ok, repository, repository_context} <- repository(adapters),
         {:ok, canonical_command} <- canonical_command(command),
         {:ok, intent} <- intent(canonical_command, fingerprint),
         result <- apply(repository, canonical_command.operation, [repository_context, intent]) do
      repository_result(result)
    end
  end

  def execute(_adapters, _command, _fingerprint), do: invalid()

  defp repository(%{repository: repository} = adapters) when is_atom(repository) do
    with true <- Map.has_key?(adapters, :repository_context),
         {:module, _module} <- Code.ensure_loaded(repository),
         true <- function_exported?(repository, :create, 2),
         true <- function_exported?(repository, :save, 2),
         true <- function_exported?(repository, :merge, 2),
         true <- function_exported?(repository, :tombstone, 2),
         true <- function_exported?(repository, :restore, 2) do
      {:ok, repository, Map.fetch!(adapters, :repository_context)}
    else
      _invalid -> invalid()
    end
  end

  defp repository(_adapters), do: invalid()

  defp canonical_command(%Command{} = command) do
    with {:ok, raw_map} <- command_attrs(command),
         {:ok, ^command} <- Command.new(command.operation, raw_map) do
      {:ok, command}
    else
      _invalid -> invalid()
    end
  end

  defp command_attrs(
         %Command{operation: operation, snapshot: %NoteSnapshot{} = snapshot} = command
       )
       when operation in [:create, :save, :merge] do
    {:ok,
     command
     |> common_attrs()
     |> Map.merge(Map.take(command, operation_fields(operation)))
     |> Map.merge(%{title: snapshot.title, markdown: snapshot.markdown})}
  end

  defp command_attrs(%Command{operation: operation} = command)
       when operation in [:tombstone, :restore] do
    {:ok,
     command
     |> common_attrs()
     |> Map.merge(Map.take(command, operation_fields(operation)))}
  end

  defp command_attrs(_command), do: invalid()

  defp common_attrs(command) do
    Map.take(command, [:mutation_id, :principal_id, :vault_id, :classification, :correlation_id])
  end

  defp operation_fields(:create), do: []
  defp operation_fields(:save), do: [:resource_id, :base_version_id]

  defp operation_fields(:merge),
    do: [:resource_id, :conflict_id, :expected_current_version_id, :competing_version_id]

  defp operation_fields(:tombstone), do: [:resource_id, :expected_current_version_id]
  defp operation_fields(:restore), do: [:resource_id]

  defp intent(%Command{operation: :create} = command, fingerprint) do
    {:ok,
     Map.merge(common_attrs(command), %{
       mutation_id: command.mutation_id,
       snapshot: command.snapshot,
       request_fingerprint: fingerprint
     })}
  end

  defp intent(%Command{operation: :save} = command, fingerprint) do
    {:ok,
     Map.merge(common_attrs(command), %{
       mutation_id: command.mutation_id,
       resource_id: command.resource_id,
       base_version_id: command.base_version_id,
       snapshot: command.snapshot,
       request_fingerprint: fingerprint
     })}
  end

  defp intent(%Command{operation: :merge} = command, fingerprint) do
    {:ok,
     Map.merge(common_attrs(command), %{
       mutation_id: command.mutation_id,
       resource_id: command.resource_id,
       conflict_id: command.conflict_id,
       expected_current_version_id: command.expected_current_version_id,
       competing_version_id: command.competing_version_id,
       snapshot: command.snapshot,
       request_fingerprint: fingerprint
     })}
  end

  defp intent(%Command{operation: :tombstone} = command, fingerprint) do
    {:ok,
     Map.merge(common_attrs(command), %{
       mutation_id: command.mutation_id,
       resource_id: command.resource_id,
       expected_current_version_id: command.expected_current_version_id,
       request_fingerprint: fingerprint
     })}
  end

  defp intent(%Command{operation: :restore} = command, fingerprint) do
    {:ok,
     Map.merge(common_attrs(command), %{
       mutation_id: command.mutation_id,
       resource_id: command.resource_id,
       request_fingerprint: fingerprint
     })}
  end

  defp repository_result({:ok, result}), do: {:ok, result}

  defp repository_result({:error, %Error{} = error}) do
    if valid_error?(error), do: {:error, error}, else: invalid()
  end

  defp repository_result(_result), do: invalid()

  defp valid_error?(%Error{
         code: code,
         message: message,
         details: details,
         retryable?: retryable?
       }) do
    code in Error.codes() and (is_nil(message) or is_binary(message)) and is_map(details) and
      is_boolean(retryable?)
  end

  defp invalid, do: {:error, Error.new(:invalid)}
end
