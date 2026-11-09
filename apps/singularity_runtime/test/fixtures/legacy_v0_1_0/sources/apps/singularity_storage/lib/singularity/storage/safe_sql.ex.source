defmodule Singularity.Storage.SafeSQL do
  @moduledoc """
  Executes raw SQL without exposing statements or parameters through Logger or
  Ecto's public telemetry bus.

  PostgreSQL privilege failures are translated into a separate bounded event
  containing only the repository role.
  """

  alias Ecto.Adapters.SQL

  defmodule Stream do
    @moduledoc false

    @enforce_keys [:delegate, :repo]
    defstruct [:delegate, :repo]

    @type t :: %__MODULE__{delegate: Enumerable.t(), repo: Ecto.Repo.t()}
  end

  @spec query(Ecto.Repo.t() | pid(), iodata(), list(), keyword()) ::
          {:ok, SQL.query_result()} | {:error, Exception.t()}
  def query(repo, statement, parameters \\ [], options \\ []) do
    repo
    |> SQL.query(statement, parameters, safe_options(options))
    |> observe_rls_denial(repo)
  end

  @spec query!(Ecto.Repo.t() | pid(), iodata(), list(), keyword()) ::
          SQL.query_result()
  def query!(repo, statement, parameters \\ [], options \\ []) do
    SQL.query!(repo, statement, parameters, safe_options(options))
  rescue
    error ->
      emit_rls_denial(repo, error)
      reraise error, __STACKTRACE__
  end

  @spec query_many(Ecto.Repo.t() | pid(), iodata(), list(), keyword()) ::
          {:ok, [SQL.query_result()]} | {:error, Exception.t()}
  def query_many(repo, statement, parameters \\ [], options \\ []) do
    repo
    |> SQL.query_many(statement, parameters, safe_options(options))
    |> observe_rls_denial(repo)
  end

  @spec query_many!(Ecto.Repo.t() | pid(), iodata(), list(), keyword()) ::
          [SQL.query_result()]
  def query_many!(repo, statement, parameters \\ [], options \\ []) do
    SQL.query_many!(repo, statement, parameters, safe_options(options))
  rescue
    error ->
      emit_rls_denial(repo, error)
      reraise error, __STACKTRACE__
  end

  @spec stream(Ecto.Repo.t(), iodata(), list(), keyword()) :: Stream.t()
  def stream(repo, statement, parameters \\ [], options \\ []) do
    %Stream{
      delegate: SQL.stream(repo, statement, parameters, safe_options(options)),
      repo: repo
    }
  end

  @spec disconnect_all(Ecto.Repo.t(), non_neg_integer(), keyword()) :: :ok
  def disconnect_all(repo, interval, options \\ []) do
    SQL.disconnect_all(repo, interval, options)
  end

  defp safe_options(options) do
    options
    |> Keyword.put(:log, false)
    |> Keyword.put(:telemetry_event, nil)
  end

  defp observe_rls_denial({:error, error} = result, repo) do
    emit_rls_denial(repo, error)
    result
  end

  defp observe_rls_denial(result, _repo), do: result

  @doc false
  @spec observe_error(Ecto.Repo.t() | pid(), Exception.t()) :: :ok
  def observe_error(repo, %Postgrex.Error{
        postgres: %{code: code}
      })
      when code in [:insufficient_privilege, "42501"] do
    :telemetry.execute(
      [:singularity, :authorization, :rls_denial],
      %{count: 1},
      %{repo: repo_role(repo)}
    )
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  def observe_error(_repo, _error), do: :ok

  defp emit_rls_denial(repo, error), do: observe_error(repo, error)

  defp repo_role(Singularity.Storage.RequestRepo), do: :request
  defp repo_role(Singularity.Storage.PreAuthRepo), do: :pre_auth
  defp repo_role(Singularity.Storage.DispatcherRepo), do: :dispatcher
  defp repo_role(Singularity.Storage.WorkerRepo), do: :worker
  defp repo_role(Singularity.Storage.MigrationRepo), do: :migration
  defp repo_role(_repo), do: :unknown
end

defimpl Enumerable, for: Singularity.Storage.SafeSQL.Stream do
  alias Singularity.Storage.SafeSQL

  def reduce(%{delegate: delegate, repo: repo}, accumulator, reducer) do
    protect(repo, fn -> Enumerable.reduce(delegate, accumulator, reducer) end)
  end

  def count(%{delegate: delegate, repo: repo}) do
    protect(repo, fn -> Enumerable.count(delegate) end)
  end

  def member?(%{delegate: delegate, repo: repo}, value) do
    protect(repo, fn -> Enumerable.member?(delegate, value) end)
  end

  def slice(%{delegate: delegate, repo: repo}) do
    case protect(repo, fn -> Enumerable.slice(delegate) end) do
      {:ok, count, slicer} ->
        {:ok, count,
         fn start, length ->
           protect(repo, fn -> slicer.(start, length) end)
         end}

      other ->
        other
    end
  end

  defp protect(repo, callback) do
    callback.()
  rescue
    error ->
      SafeSQL.observe_error(repo, error)
      reraise error, __STACKTRACE__
  end
end
