defmodule Singularity.Knowledge.BookImportSSH do
  @moduledoc "Read-only SSH transport for SCP-style directory addresses."

  @options ~w(-T -oBatchMode=yes -oStrictHostKeyChecking=yes -oConnectTimeout=10
              -oServerAliveInterval=15 -oServerAliveCountMax=4 -oClearAllForwardings=yes
              -oForwardAgent=no)

  @callback list(String.t(), String.t()) :: {:ok, [String.t()]} | {:error, term()}
  @callback fetch(String.t(), String.t(), Path.t()) :: :ok | {:error, term()}

  @behaviour __MODULE__

  def parse(location) when is_binary(location) and byte_size(location) <= 4096 do
    with [host, "/" <> _ = directory] <- String.split(String.trim(location), ":", parts: 2),
         true <-
           Regex.match?(~r/\A(?:[A-Za-z0-9_][A-Za-z0-9_.-]*@)?[A-Za-z0-9][A-Za-z0-9_.-]*\z/, host),
         false <- Regex.match?(~r/\p{Cc}/u, directory) do
      if host in Application.get_env(:singularity, :book_import_ssh_hosts, []) do
        {:ok, host, Path.expand(directory)}
      else
        {:error, :ssh_host_not_allowed}
      end
    else
      _invalid -> {:error, :invalid_location}
    end
  end

  def parse(_location), do: {:error, :invalid_location}

  @impl true
  def list(host, directory) do
    case run(host, "find #{quote_path(directory)} -type f -iname '*.epub' -print0", nil) do
      {:ok, listing} ->
        prefix = String.trim_trailing(directory, "/")
        paths = :binary.split(listing, <<0>>, [:global, :trim_all])

        if Enum.all?(paths, &(String.valid?(&1) and String.starts_with?(&1, prefix <> "/"))) do
          {:ok, Enum.sort(paths)}
        else
          {:error, :invalid_ssh_listing}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def fetch(host, path, destination) do
    case run(host, "exec cat -- #{quote_path(path)}", destination) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp run(host, command, destination) do
    if ssh = System.find_executable("ssh") do
      case run_command(ssh, @options ++ ["--", host, command], destination) do
        {data, 0} -> {:ok, data}
        {_data, code} -> {:error, {:ssh_exit, code}}
      end
    else
      {:error, :ssh_not_found}
    end
  end

  defp run_command(ssh, args, nil), do: System.cmd(ssh, args)

  # Redirect SSH's stdout at the OS level, so file bytes never enter the VM.
  defp run_command(ssh, args, destination) do
    System.cmd("sh", [
      "-c",
      ~s(umask 077; destination=$1; shift; exec "$@" > "$destination"),
      "book-import",
      destination,
      ssh | args
    ])
  end

  defp quote_path(path), do: "'" <> String.replace(path, "'", "'\\''") <> "'"
end
