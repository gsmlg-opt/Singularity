defmodule Singularity.Collectors.IetfRfc.Rsync do
  @moduledoc """
  Runs `rsync` for the IETF RFC collector. The runner is read from
  `config :singularity, Singularity.Collectors.IetfRfc, rsync: module`, so
  tests never touch the network.
  """

  @callback sync([String.t()]) :: :ok | {:error, term()}

  @behaviour __MODULE__

  @output_tail 500

  @impl true
  def sync(args) do
    case System.find_executable("rsync") do
      nil ->
        {:error, :rsync_not_found}

      rsync ->
        case System.cmd(rsync, args, stderr_to_stdout: true) do
          {_output, 0} -> :ok
          {output, status} -> {:error, {:rsync, status, tail(output)}}
        end
    end
  end

  defp tail(output) when byte_size(output) <= @output_tail, do: String.trim(output)

  defp tail(output),
    do: output |> binary_part(byte_size(output) - @output_tail, @output_tail) |> String.trim()
end
