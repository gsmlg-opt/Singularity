defmodule Singularity.Sources do
  @moduledoc "Source configuration and scheduling."

  import Ecto.Query

  alias Singularity.{Collector, Repo}
  alias Singularity.Sources.Source

  @default_source %{
    "kind" => "github_trending",
    "name" => "GitHub Trending · All languages · daily",
    "config" => %{"language" => "", "since" => "daily"}
  }

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

  def type_label(%Source{kind: kind}) do
    case Collector.fetch_module(kind) do
      {:ok, collector} -> collector.label()
      :error -> "不可用（#{kind}）"
    end
  end

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

  def ensure_default_source(now \\ DateTime.utc_now()) do
    if Repo.exists?(Source), do: {:ok, :exists}, else: create_source(@default_source, now)
  end
end
