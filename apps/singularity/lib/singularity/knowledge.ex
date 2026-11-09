defmodule Singularity.Knowledge do
  @moduledoc "Knowledge items and their observations."

  import Ecto.Query

  alias Singularity.Collector.{Entry, Result}
  alias Singularity.Knowledge.{Item, Observation}
  alias Singularity.Repo
  alias Singularity.Sources.Source

  @replace_on_conflict [
    :title,
    :url,
    :summary,
    :published_at,
    :attributes,
    :last_seen_at,
    :updated_at
  ]

  @doc "Upserts items and inserts one observation per entry for the result's period, atomically."
  @spec record(Source.t(), Result.t(), DateTime.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def record(%Source{} = source, %Result{} = result, %DateTime{} = now) do
    now = DateTime.truncate(now, :second)

    Repo.transaction(fn ->
      Enum.each(result.entries, fn entry ->
        item = upsert_item!(entry, now)
        insert_observation!(item, source, result.period, entry, now)
      end)

      length(result.entries)
    end)
  end

  defp upsert_item!(%Entry{} = entry, now) do
    %Item{}
    |> Item.changeset(%{
      kind: entry.item_kind,
      external_id: entry.external_id,
      title: entry.title,
      url: entry.url,
      summary: entry.summary,
      published_at: entry.published_at,
      attributes: entry.item_attributes,
      first_seen_at: now,
      last_seen_at: now
    })
    |> Repo.insert!(
      on_conflict: {:replace, @replace_on_conflict},
      conflict_target: [:kind, :external_id],
      returning: true
    )
  end

  defp insert_observation!(%Item{} = item, %Source{} = source, period, %Entry{} = entry, now) do
    %Observation{}
    |> Observation.changeset(%{
      item_id: item.id,
      source_id: source.id,
      period: period,
      observed_at: now,
      rank: entry.rank,
      attributes: entry.observation_attributes,
      raw: entry.raw
    })
    |> Repo.insert!(on_conflict: :nothing, conflict_target: [:source_id, :item_id, :period])
  end

  @doc """
  Most recently observed items, one row per item.
  Options: :kind, :from (Date), :to (Date), :page (default 1), :per_page (default 50).
  """
  def list_items(opts \\ []) do
    page = Keyword.get(opts, :page, 1)
    per_page = Keyword.get(opts, :per_page, 50)

    latest =
      Observation
      |> observed_from(opts[:from])
      |> observed_to(opts[:to])
      |> group_by([o], o.item_id)
      |> select([o], %{item_id: o.item_id, observed_at: max(o.observed_at)})

    Item
    |> join(:inner, [i], o in subquery(latest), on: o.item_id == i.id)
    |> item_kind(opts[:kind])
    |> order_by([i, o], desc: o.observed_at, desc: i.id)
    |> limit(^per_page)
    |> offset(^((page - 1) * per_page))
    |> select([i, o], %{
      item: i,
      observed_at: o.observed_at,
      rank: nil,
      observation_attributes: nil
    })
    |> Repo.all()
  end

  defp observed_from(query, nil), do: query

  defp observed_from(query, %Date{} = from),
    do: where(query, [o], o.observed_at >= ^DateTime.new!(from, ~T[00:00:00], "Etc/UTC"))

  defp observed_to(query, nil), do: query

  defp observed_to(query, %Date{} = to),
    do:
      where(query, [o], o.observed_at < ^DateTime.new!(Date.add(to, 1), ~T[00:00:00], "Etc/UTC"))

  defp item_kind(query, nil), do: query
  defp item_kind(query, kind), do: where(query, [i], i.kind == ^kind)

  def list_item_kinds,
    do: Item |> distinct(true) |> order_by(:kind) |> select([i], i.kind) |> Repo.all()

  def latest_period(source_id) do
    Observation
    |> where(source_id: ^source_id)
    |> order_by(desc: :observed_at, desc: :id)
    |> limit(1)
    |> select([o], o.period)
    |> Repo.one()
  end

  def list_period(source_id, period) do
    Observation
    |> where(source_id: ^source_id, period: ^period)
    |> join(:inner, [o], i in assoc(o, :item))
    |> order_by([o], asc_nulls_last: o.rank, asc: o.id)
    |> select([o, i], %{
      item: i,
      observed_at: o.observed_at,
      rank: o.rank,
      observation_attributes: o.attributes
    })
    |> Repo.all()
  end

  def get_item!(id), do: Repo.get!(Item, id)

  def list_observations(item_id) do
    Observation
    |> where(item_id: ^item_id)
    |> order_by(desc: :observed_at, desc: :id)
    |> preload(:source)
    |> Repo.all()
  end
end
