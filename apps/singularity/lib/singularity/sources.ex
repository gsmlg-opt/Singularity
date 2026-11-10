defmodule Singularity.Sources do
  @moduledoc "Source configuration and scheduling."

  import Ecto.Query

  alias Singularity.{Collector, Repo, Settings}
  alias Singularity.Sources.Source

  # Default daily GitHub Trending sources: all languages plus common ones, as
  # {GitHub trending slug, display name}. Appending a language here seeds it on
  # the next deploy; defaults the user deleted are not recreated.
  @trending_daily_defaults [
    {"", "All languages"},
    {"elixir", "Elixir"},
    {"erlang", "Erlang"},
    {"rust", "Rust"},
    {"go", "Go"},
    {"zig", "Zig"},
    {"c", "C"},
    {"c++", "C++"},
    {"c#", "C#"},
    {"java", "Java"},
    {"kotlin", "Kotlin"},
    {"swift", "Swift"},
    {"python", "Python"},
    {"javascript", "JavaScript"},
    {"typescript", "TypeScript"},
    {"ruby", "Ruby"},
    {"php", "PHP"},
    {"dart", "Dart"},
    {"haskell", "Haskell"},
    {"lua", "Lua"},
    {"shell", "Shell"},
    {"nix", "Nix"}
  ]
  @seeded_defaults_key "seeded_trending_daily_languages"

  def list_sources, do: Source |> order_by(asc: :inserted_at, asc: :id) |> Repo.all()

  def get_source!(id), do: Repo.get!(Source, id)
  def get_source(id), do: Repo.get(Source, id)

  def change_source(%Source{} = source, attrs \\ %{}), do: Source.changeset(source, attrs)

  def create_source(attrs, now \\ DateTime.utc_now()) do
    %Source{}
    |> Source.changeset(attrs)
    |> Ecto.Changeset.put_change(:next_run_at, DateTime.truncate(now, :second))
    |> Repo.insert()
  end

  def update_source(%Source{} = source, attrs),
    do: source |> Source.changeset(attrs) |> Repo.update()

  def set_enabled(%Source{} = source, enabled) when is_boolean(enabled),
    do: source |> Ecto.Changeset.change(enabled: enabled) |> Repo.update()

  def delete_source(%Source{} = source), do: Repo.delete(source)

  @typedoc "What a form needs to know about a source type."
  @type source_type :: %{kind: String.t(), label: String.t(), fields: [Collector.field()]}

  @spec list_source_types() :: [source_type()]
  def list_source_types, do: Enum.map(Collector.all(), &describe_type/1)

  @spec fetch_source_type(String.t()) :: {:ok, source_type()} | :error
  def fetch_source_type(kind) when is_binary(kind) do
    with {:ok, collector} <- Collector.fetch_module(kind), do: {:ok, describe_type(collector)}
  end

  def new_source(kind) when is_binary(kind), do: %Source{kind: kind, config: %{}}

  defp describe_type(collector),
    do: %{kind: collector.kind(), label: collector.label(), fields: collector.config_fields()}

  @doc "Locks due sources, advances their next_run_at, and returns them."
  def claim_due_sources(%DateTime{} = now) do
    now = DateTime.truncate(now, :second)
    kinds = Enum.map(Collector.all(), & &1.kind())

    {:ok, claimed} =
      Repo.transaction(fn ->
        Source
        |> where([s], s.enabled and s.next_run_at <= ^now and s.kind in ^kinds)
        |> lock("FOR UPDATE SKIP LOCKED")
        |> Repo.all()
        |> Enum.map(fn source ->
          source
          |> Ecto.Changeset.change(
            next_run_at: DateTime.add(now, source.interval_minutes * 60, :second)
          )
          |> Repo.update!()
        end)
      end)

    claimed
  end

  @doc """
  Creates the default daily GitHub Trending sources that were never seeded
  before and do not already exist. Returns `{:ok, created_count}`.
  """
  @spec ensure_default_sources(DateTime.t()) :: {:ok, non_neg_integer()}
  def ensure_default_sources(now \\ DateTime.utc_now()) do
    Repo.transaction(fn ->
      seeded = seeded_default_languages()

      pending =
        Enum.reject(@trending_daily_defaults, fn {language, _name} -> language in seeded end)

      existing = existing_trending_daily_languages()

      created =
        for {language, name} <- pending, language not in existing do
          {:ok, _source} =
            create_source(
              %{
                "kind" => "github_trending",
                "name" => "GitHub Trending · #{name} · daily",
                "config" => %{"language" => language, "since" => "daily"}
              },
              now
            )
        end

      {:ok, _setting} =
        Settings.put(
          @seeded_defaults_key,
          JSON.encode!(seeded ++ Enum.map(pending, &elem(&1, 0)))
        )

      length(created)
    end)
  end

  defp seeded_default_languages do
    case Settings.get(@seeded_defaults_key) do
      nil -> []
      json -> JSON.decode!(json)
    end
  end

  defp existing_trending_daily_languages do
    Source
    |> where(kind: "github_trending")
    |> select([s], s.config)
    |> Repo.all()
    |> Enum.filter(&(&1["since"] == "daily"))
    |> Enum.map(&(&1["language"] || ""))
  end
end
