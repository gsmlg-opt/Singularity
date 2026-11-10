defmodule Singularity.Knowledge do
  @moduledoc "Knowledge items (v2: software projects), their labels and source records."

  import Ecto.Query

  alias Singularity.Collector.{Entry, Result}
  alias Singularity.Knowledge.{Item, Label, Observation}
  alias Singularity.Repo
  alias Singularity.Sources.Source

  @topic "knowledge"
  @project "software_project"

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

  @doc "Subscribes the caller to `{:project_updated, item_id}` messages."
  def subscribe, do: Phoenix.PubSub.subscribe(Singularity.PubSub, @topic)

  defp broadcast_project(item_id),
    do: Phoenix.PubSub.broadcast(Singularity.PubSub, @topic, {:project_updated, item_id})

  @doc """
  Software projects with labels preloaded. Options: `:label`, `:q` (ILIKE on
  owner/repo and description), `:sort` (`:recent` or `:stars`), `:page`
  (default 1) and `:per_page` (default 30).
  """
  @spec list_projects(keyword()) :: [Item.t()]
  def list_projects(opts \\ []) do
    page = max(Keyword.get(opts, :page, 1), 1)
    per_page = Keyword.get(opts, :per_page, 30)

    projects_query()
    |> filter_label(opts[:label])
    |> search(opts[:q])
    |> sort_projects(Keyword.get(opts, :sort, :recent))
    |> limit(^per_page)
    |> offset(^((page - 1) * per_page))
    |> preload(labels: ^labels_query())
    |> Repo.all()
  end

  defp projects_query, do: where(Item, [i], i.kind == ^@project)
  defp labels_query, do: order_by(Label, asc: :name)

  defp filter_label(query, label) when label in [nil, ""], do: query

  defp filter_label(query, label) do
    tagged = from(l in Label, where: l.name == ^label, select: l.item_id)
    where(query, [i], i.id in subquery(tagged))
  end

  defp search(query, q) when q in [nil, ""], do: query

  defp search(query, q) do
    pattern = "%" <> escape_like(String.trim(q)) <> "%"
    where(query, [i], ilike(i.title, ^pattern) or ilike(i.summary, ^pattern))
  end

  defp escape_like(text), do: String.replace(text, ~r/[\\%_]/, "\\\\\\0")

  defp sort_projects(query, :stars) do
    order_by(query, [i],
      desc_nulls_last: fragment("(?->>'stars')::bigint", i.attributes),
      desc: i.id
    )
  end

  defp sort_projects(query, _recent), do: order_by(query, [i], desc: i.first_seen_at, desc: i.id)

  @spec count_projects() :: non_neg_integer()
  def count_projects, do: Repo.aggregate(projects_query(), :count)

  @doc "Projects added at or after `since` (the Overview's \"added this week\")."
  @spec count_projects_since(DateTime.t()) :: non_neg_integer()
  def count_projects_since(%DateTime{} = since),
    do: projects_query() |> where([i], i.first_seen_at >= ^since) |> Repo.aggregate(:count)

  @spec recent_projects(pos_integer()) :: [Item.t()]
  def recent_projects(limit) do
    projects_query()
    |> order_by([i], desc: i.first_seen_at, desc: i.id)
    |> limit(^limit)
    |> preload(labels: ^labels_query())
    |> Repo.all()
  end

  def get_project!(id), do: projects_query() |> preload(labels: ^labels_query()) |> Repo.get!(id)
  def get_project(id), do: Repo.get(projects_query(), id)

  @doc "`{name, project_count}` for the most used labels."
  @spec top_labels(pos_integer()) :: [{String.t(), pos_integer()}]
  def top_labels(limit) do
    Label
    |> join(:inner, [l], i in Item, on: i.id == l.item_id and i.kind == ^@project)
    |> group_by([l], l.name)
    |> order_by([l], desc: count(l.id), asc: l.name)
    |> limit(^limit)
    |> select([l], {l.name, count(l.id)})
    |> Repo.all()
  end

  @doc "Project additions, newest first, with the source of the first record (nil = manual)."
  @spec list_additions(pos_integer()) :: [
          %{at: DateTime.t(), item: Item.t(), source: Source.t() | nil}
        ]
  def list_additions(limit) do
    first_records =
      Observation
      |> distinct([o], o.item_id)
      |> order_by([o], asc: o.item_id, asc: o.observed_at, asc: o.id)
      |> select([o], %{item_id: o.item_id, source_id: o.source_id})

    projects_query()
    |> join(:left, [i], f in subquery(first_records), on: f.item_id == i.id)
    |> join(:left, [i, f], s in Source, on: s.id == f.source_id)
    |> order_by([i], desc: i.first_seen_at, desc: i.id)
    |> limit(^limit)
    |> select([i, f, s], %{at: i.first_seen_at, item: i, source: s})
    |> Repo.all()
  end

  @doc "Adds a manual label; an automatic label with the same name becomes manual."
  @spec add_label(Item.t(), String.t()) :: {:ok, Label.t()} | {:error, Ecto.Changeset.t()}
  def add_label(%Item{} = item, name) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %Label{}
    |> Label.changeset(%{item_id: item.id, name: name, origin: "manual"})
    |> Repo.insert(
      on_conflict: [set: [origin: "manual", updated_at: now]],
      conflict_target: [:item_id, :name],
      returning: true
    )
    |> case do
      {:ok, label} ->
        broadcast_project(item.id)
        {:ok, label}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc "Removes a manual label. Automatic labels belong to the system."
  @spec remove_label(Item.t(), String.t()) :: :ok | {:error, :auto_label | :not_found}
  def remove_label(%Item{} = item, name) do
    case Repo.get_by(Label, item_id: item.id, name: Label.normalize_name(name)) do
      nil ->
        {:error, :not_found}

      %Label{origin: "auto"} ->
        {:error, :auto_label}

      %Label{} = label ->
        Repo.delete!(label)
        broadcast_project(item.id)
        :ok
    end
  end
end
