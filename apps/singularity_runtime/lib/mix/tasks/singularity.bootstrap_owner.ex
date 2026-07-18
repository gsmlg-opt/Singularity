defmodule Mix.Tasks.Singularity.BootstrapOwner do
  use Mix.Task

  alias Ecto.Adapters.SQL
  alias Singularity.Runtime.BootstrapOwner
  alias Singularity.Storage.MigrationRepo

  @shortdoc "Bootstraps the first owner without accepting a password argument"

  @impl Mix.Task
  def run(args) do
    {options, positional, invalid} =
      OptionParser.parse(args, strict: [password_fd: :integer])

    if positional != [] or invalid != [] do
      Mix.raise("password arguments are forbidden; use the no-echo prompt or --password-fd")
    end

    password =
      case Keyword.fetch(options, :password_fd) do
        {:ok, descriptor} -> read_secret_descriptor!(descriptor)
        :error -> prompt_password!()
      end

    adapters = Application.fetch_env!(:singularity_runtime, :bootstrap_owner)

    attrs = %{
      display_name: Map.get(adapters, :display_name, "Owner"),
      login: Map.get(adapters, :login, "owner@singularity.local"),
      password: password
    }

    result =
      with_migration_repo(fn ->
        bootstrap_in_owner_transaction(adapters, attrs)
      end)

    case result do
      {:ok, owner} ->
        Mix.shell().info("owner account=#{owner.account_id} vault=#{owner.vault_id}")

      {:error, error} ->
        Mix.raise("owner bootstrap failed: #{error.code}")
    end
  after
    password = nil
    _ = password
  end

  defp prompt_password! do
    case :io.get_password(~c"Owner password: ") do
      password when is_list(password) -> password |> List.to_string() |> require_secret!()
      password when is_binary(password) -> require_secret!(password)
      _other -> Mix.raise("could not read owner password")
    end
  end

  defp read_secret_descriptor!(descriptor)
       when is_integer(descriptor) and descriptor >= 0 do
    path = "/proc/self/fd/#{descriptor}"

    case File.read(path) do
      {:ok, password} -> password |> strip_transport_terminator() |> require_secret!()
      {:error, _reason} -> Mix.raise("could not read inherited password descriptor")
    end
  end

  defp require_secret!(""), do: Mix.raise("owner password cannot be empty")
  defp require_secret!(password), do: password

  defp strip_transport_terminator(password) do
    size = byte_size(password)

    cond do
      size >= 2 and binary_part(password, size - 2, 2) == "\r\n" ->
        binary_part(password, 0, size - 2)

      size >= 1 and binary_part(password, size - 1, 1) == "\n" ->
        binary_part(password, 0, size - 1)

      true ->
        password
    end
  end

  defp with_migration_repo(callback) do
    {:ok, _started} = Application.ensure_all_started(:ecto_sql)
    {:ok, _started} = Application.ensure_all_started(:postgrex)
    {:ok, pid} = MigrationRepo.start_link()

    try do
      callback.()
    after
      if Process.alive?(pid), do: Supervisor.stop(pid)
    end
  end

  defp bootstrap_in_owner_transaction(adapters, attrs) do
    MigrationRepo.transaction(fn ->
      SQL.query!(
        MigrationRepo,
        "SET LOCAL ROLE singularity_table_owner",
        [],
        log: false
      )

      case BootstrapOwner.run(adapters, attrs) do
        {:ok, owner} -> owner
        {:error, error} -> MigrationRepo.rollback(error)
      end
    end)
  end
end
