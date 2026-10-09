defmodule Singularity.Storage.SearchExtensionBootstrap do
  @moduledoc "Task-side provisioning of constrained search extensions in one application database."

  @database_name ~r/\A[a-z_][a-z0-9_]{0,62}\z/
  @protected_databases ~w(postgres template0 template1)
  @failure "search extension bootstrap failed"

  @spec run!(String.t()) :: :ok
  def run!(database) do
    unless is_binary(database) and Regex.match?(@database_name, database) and
             database not in @protected_databases do
      raise ArgumentError, "search extension bootstrap requires an application database name"
    end

    provision!(database)
  end

  defp provision!(database) do
    wrapper =
      :singularity_storage
      |> :code.priv_dir()
      |> to_string()
      |> Path.join("repo/bootstrap_search_extensions.sh")

    case System.cmd("bash", [wrapper, database], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      _ -> raise @failure
    end
  rescue
    _ -> raise @failure
  end
end
