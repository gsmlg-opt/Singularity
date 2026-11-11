defmodule Singularity.Settings do
  @moduledoc "System configuration in the settings table: the GitHub token, the colour theme and which default sources were seeded."

  import Ecto.Query

  alias Singularity.Repo
  alias Singularity.Settings.Setting

  @github_token "github_token"
  @theme "theme"
  # Theme preferences: "auto" follows the system light/dark setting, the others
  # are the DuskMoon themes the stylesheet imports. The first is the default.
  @themes ["auto", "sunshine", "moonlight"]

  @doc "The stored token, else the GITHUB_TOKEN environment variable, else nil."
  @spec get_github_token() :: String.t() | nil
  def get_github_token, do: stored_token() || env_token()

  @doc "Where the token comes from and its last four characters; never the full token."
  @spec github_token_status() :: :unset | {:env, String.t()} | {:settings, String.t()}
  def github_token_status do
    case {stored_token(), env_token()} do
      {token, _env} when is_binary(token) -> {:settings, last4(token)}
      {nil, token} when is_binary(token) -> {:env, last4(token)}
      {nil, nil} -> :unset
    end
  end

  @spec put_github_token(String.t()) :: {:ok, Setting.t()} | {:error, Ecto.Changeset.t()}
  def put_github_token(token) when is_binary(token) do
    %Setting{}
    |> Setting.changeset(%{key: @github_token, value: String.trim(token)})
    |> Repo.insert(
      on_conflict: {:replace, [:value, :updated_at]},
      conflict_target: :key,
      returning: true
    )
  end

  @spec clear_github_token() :: :ok
  def clear_github_token do
    Setting |> where(key: @github_token) |> Repo.delete_all()
    :ok
  end

  @doc "The theme preferences, default first."
  @spec themes() :: [String.t()]
  def themes, do: @themes

  @doc "The chosen theme preference, or the default when none was chosen."
  @spec theme() :: String.t()
  def theme do
    case get(@theme) do
      theme when theme in @themes -> theme
      _unset -> hd(@themes)
    end
  end

  @spec put_theme(String.t()) :: {:ok, Setting.t()} | {:error, :unknown_theme}
  def put_theme(theme) when theme in @themes, do: put(@theme, theme)
  def put_theme(_theme), do: {:error, :unknown_theme}

  @doc "The stored value for `key`, or nil."
  @spec get(String.t()) :: String.t() | nil
  def get(key) when is_binary(key),
    do: Setting |> where(key: ^key) |> select([s], s.value) |> Repo.one()

  @doc "Stores `value` under `key`, replacing any previous value."
  @spec put(String.t(), String.t()) :: {:ok, Setting.t()} | {:error, Ecto.Changeset.t()}
  def put(key, value) when is_binary(key) and is_binary(value) do
    %Setting{}
    |> Setting.changeset(%{key: key, value: value})
    |> Repo.insert(
      on_conflict: {:replace, [:value, :updated_at]},
      conflict_target: :key,
      returning: true
    )
  end

  defp stored_token,
    do: Setting |> where(key: @github_token) |> select([s], s.value) |> Repo.one()

  defp env_token do
    case System.get_env("GITHUB_TOKEN") do
      token when is_binary(token) and token != "" -> token
      _unset -> nil
    end
  end

  defp last4(token), do: String.slice(token, -4, 4)
end
