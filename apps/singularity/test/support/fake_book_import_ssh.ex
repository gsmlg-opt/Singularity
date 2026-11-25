defmodule Singularity.Test.FakeBookImportSSH do
  @behaviour Singularity.Knowledge.BookImportSSH

  @impl true
  def list(_host, _directory), do: {:ok, Map.keys(Process.get(__MODULE__, %{})) |> Enum.sort()}

  @impl true
  def fetch(_host, path, destination) do
    case Map.fetch!(Process.get(__MODULE__), path) do
      {:error, reason} -> {:error, reason}
      data -> File.write(destination, data)
    end
  end
end
