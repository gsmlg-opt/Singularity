defmodule Singularity.Runtime.Notes.MutationFingerprint do
  @moduledoc false

  alias Singularity.Core.Error
  alias Singularity.Domains.Notes.Command

  @spec compute(binary(), Command.t()) :: {:ok, binary()} | {:error, Error.t()}
  def compute(<<_::binary-size(32)>> = secret, %Command{} = command) do
    with :ok <- exact_struct(command),
         {:ok, raw} <- raw_command(command),
         {:ok, rebuilt} <- Command.new(command.operation, raw),
         true <- rebuilt == command do
      encoded =
        command
        |> Command.fingerprint_term()
        |> :erlang.term_to_binary([:deterministic])

      {:ok, :crypto.mac(:hmac, :sha256, secret, encoded)}
    else
      _invalid -> invalid()
    end
  rescue
    _error -> invalid()
  end

  def compute(_secret, _command), do: invalid()

  defp exact_struct(command) do
    if Map.keys(command) |> Enum.sort() == Command.__struct__() |> Map.keys() |> Enum.sort(),
      do: :ok,
      else: invalid()
  end

  defp raw_command(command) do
    common = %{
      mutation_id: command.mutation_id,
      principal_id: command.principal_id,
      vault_id: command.vault_id,
      classification: command.classification,
      correlation_id: command.correlation_id
    }

    case command do
      %Command{operation: :create, snapshot: snapshot} ->
        snapshot_fields(common, snapshot)

      %Command{
        operation: :save,
        resource_id: resource_id,
        base_version_id: base_version_id,
        snapshot: snapshot
      } ->
        with {:ok, attrs} <- snapshot_fields(common, snapshot) do
          {:ok,
           Map.merge(attrs, %{
             resource_id: resource_id,
             base_version_id: base_version_id
           })}
        end

      %Command{
        operation: :merge,
        resource_id: resource_id,
        conflict_id: conflict_id,
        expected_current_version_id: expected_current_version_id,
        competing_version_id: competing_version_id,
        snapshot: snapshot
      } ->
        with {:ok, attrs} <- snapshot_fields(common, snapshot) do
          {:ok,
           Map.merge(attrs, %{
             resource_id: resource_id,
             conflict_id: conflict_id,
             expected_current_version_id: expected_current_version_id,
             competing_version_id: competing_version_id
           })}
        end

      %Command{
        operation: :tombstone,
        resource_id: resource_id,
        expected_current_version_id: expected_current_version_id,
        snapshot: nil
      } ->
        {:ok,
         Map.merge(common, %{
           resource_id: resource_id,
           expected_current_version_id: expected_current_version_id
         })}

      %Command{operation: :restore, resource_id: resource_id, snapshot: nil} ->
        {:ok, Map.put(common, :resource_id, resource_id)}

      _invalid ->
        invalid()
    end
  end

  defp snapshot_fields(common, %{title: title, markdown: markdown}) do
    {:ok, Map.merge(common, %{title: title, markdown: markdown})}
  end

  defp snapshot_fields(_common, _snapshot), do: invalid()

  defp invalid, do: {:error, Error.new(:invalid)}
end
