defmodule Singularity.Knowledge do
  @moduledoc "Knowledge items (v2: software projects), their labels and source records."

  import Ecto.Query

  alias Singularity.Collector.{Entry, Result}

  alias Singularity.Knowledge.{
    Address,
    FetchDetailsWorker,
    Item,
    ItemSource,
    Label,
    Labels,
    Observation
  }

  alias Singularity.Repo
  alias Singularity.Sources.Source

  @topic "knowledge"
  @project "software_project"

  # title, summary and attributes come from GitHub details; collected values only seed new items.
  @replace_on_conflict [:last_seen_at, :updated_at]
  @details_ttl_seconds 24 * 60 * 60
  # A project no source keeps any more is deleted this long after it left the last one.
  @removal_grace_days 30
  # A complete list (thousands of stars) is written in one transaction.
  @record_timeout :timer.minutes(10)

  @doc """
  Upserts items and inserts one observation per entry (for the entry's period,
  else the result's), atomically. Every item is kept by the source. Trending
  entries add a `trending:<since>` label. Entries carrying `details` store them;
  other software projects without fresh details get a fetch queued.

  For a complete result (with nothing skipped), items the source kept but no
  longer lists leave it; one that no source keeps any more is due for removal
  #{@removal_grace_days} days later.
  """
  @spec record(Source.t(), Result.t(), DateTime.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def record(%Source{} = source, %Result{} = result, %DateTime{} = now) do
    now = DateTime.truncate(now, :second)

    Repo.transaction(
      fn ->
        item_ids =
          Enum.map(result.entries, fn entry ->
            item = upsert_item!(entry, now)
            insert_observation!(item, source, entry.period || result.period, entry, now)
            add_trending_label!(item, entry, now)
            keep_details!(item, entry, now)
            item.id
          end)

        keep!(item_ids, source.id, now)
        if result.complete and result.skipped == 0, do: leave!(source.id, item_ids, now)
        length(result.entries)
      end,
      timeout: @record_timeout
    )
  end

  defp keep_details!(item, %Entry{details: nil}, now), do: maybe_enqueue_details!(item, now)
  defp keep_details!(item, %Entry{details: details}, now), do: apply_details!(item, details, now)

  # The source (nil = by hand) keeps these items: rows are created or reopened,
  # and a pending removal is called off.
  defp keep!(item_ids, source_id, now) do
    item_ids = Enum.uniq(item_ids)

    item_ids
    |> Enum.map(
      &%{item_id: &1, source_id: source_id, added_at: now, inserted_at: now, updated_at: now}
    )
    |> Enum.chunk_every(1000)
    |> Enum.each(
      &Repo.insert_all(ItemSource, &1,
        on_conflict: [set: [removed_at: nil, updated_at: now]],
        conflict_target: [:item_id, :source_id]
      )
    )

    Item
    |> where([i], i.id in ^item_ids and not is_nil(i.removal_due_at))
    |> Repo.update_all(set: [removal_due_at: nil, updated_at: now])

    :ok
  end

  defp leave!(source_id, listed_ids, now) do
    {_count, left_ids} =
      ItemSource
      |> where([s], s.source_id == ^source_id and is_nil(s.removed_at))
      |> where([s], s.item_id not in ^listed_ids)
      |> select([s], s.item_id)
      |> Repo.update_all(set: [removed_at: now, updated_at: now])

    kept = from(s in ItemSource, where: is_nil(s.removed_at), select: s.item_id)

    Item
    |> where([i], i.id in ^left_ids and i.id not in subquery(kept))
    |> Repo.update_all(
      set: [removal_due_at: DateTime.add(now, @removal_grace_days, :day), updated_at: now]
    )

    :ok
  end

  @doc "The sources that added the item (`source` nil = by hand), oldest first."
  @spec list_item_sources(integer()) :: [ItemSource.t()]
  def list_item_sources(item_id) do
    ItemSource
    |> where(item_id: ^item_id)
    |> order_by(asc: :added_at, asc: :id)
    |> preload(:source)
    |> Repo.all()
  end

  @doc "Deletes the projects whose removal is due. Returns how many were deleted."
  @spec purge_removed(DateTime.t()) :: non_neg_integer()
  def purge_removed(%DateTime{} = now \\ DateTime.utc_now()) do
    {count, _rows} =
      Item
      |> where([i], not is_nil(i.removal_due_at) and i.removal_due_at <= ^now)
      |> Repo.delete_all()

    count
  end

  defp add_trending_label!(
         %Item{} = item,
         %Entry{observation_attributes: %{"since" => since}},
         now
       )
       when is_binary(since) and since != "" do
    Repo.insert_all(Label, [auto_label_row(item.id, "trending:" <> since, now)],
      on_conflict: :nothing,
      conflict_target: [:item_id, :name]
    )

    :ok
  end

  defp add_trending_label!(_item, _entry, _now), do: :ok

  defp maybe_enqueue_details!(%Item{kind: @project} = item, now) do
    if details_stale?(item, now) do
      {:ok, _job} = enqueue_details(item.id)
    end

    :ok
  end

  defp maybe_enqueue_details!(_item, _now), do: :ok

  defp details_stale?(%Item{details_fetched_at: nil}, _now), do: true

  defp details_stale?(%Item{details_fetched_at: fetched_at}, now),
    do: DateTime.diff(now, fetched_at) >= @details_ttl_seconds

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

  @manual_project_types %{name: :string, address: :string}

  @doc "A changeset for the manual \"Add project\" form: a name and a repository address."
  @spec change_manual_project(map()) :: Ecto.Changeset.t()
  def change_manual_project(attrs \\ %{}) do
    {%{}, @manual_project_types}
    |> Ecto.Changeset.cast(attrs, Map.keys(@manual_project_types))
    |> Ecto.Changeset.validate_required([:name, :address])
    |> Ecto.Changeset.validate_length(:name, max: 200)
    |> Ecto.Changeset.validate_change(:address, fn :address, address ->
      case Address.normalize(address) do
        {:ok, _address} -> []
        {:error, :unsupported_address} -> [address: "is not a repository address"]
      end
    end)
  end

  @doc """
  Adds a software project by hand from a name and any git repository address.
  The name becomes the title and is kept when details are fetched. A new project
  gets a manual source record; a GitHub project also gets a queued details
  fetch, another host gets a `host:<host>` label. A known project is returned
  unchanged as `{:existing, item}`; its manual source record is still written
  (once per day).
  """
  @spec add_project(map(), DateTime.t()) ::
          {:ok, Item.t()} | {:existing, Item.t()} | {:error, Ecto.Changeset.t()}
  def add_project(attrs, now \\ DateTime.utc_now()) do
    now = DateTime.truncate(now, :second)
    changeset = change_manual_project(attrs)

    with {:ok, %{name: name, address: address}} <-
           Ecto.Changeset.apply_action(changeset, :insert),
         {:ok, normalized} = Address.normalize(address),
         {:ok, outcome} <-
           Repo.transaction(fn -> find_or_create_project(normalized, String.trim(name), now) end) do
      case outcome do
        {:created, item} ->
          broadcast_project(item.id)
          {:ok, item}

        {:existing, item} ->
          {:existing, item}
      end
    else
      {:error, %Ecto.Changeset{data: %Item{}}} ->
        {:error,
         Ecto.Changeset.add_error(
           %{changeset | action: :insert},
           :address,
           "could not be added"
         )}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc "Whether the project's details can be fetched automatically (GitHub only)."
  @spec details_supported?(Item.t()) :: boolean()
  def details_supported?(%Item{external_id: external_id}),
    do: String.starts_with?(external_id, "github.com/")

  @doc """
  Projects added by hand, most recently added first, with `manual_added_at`
  (the latest manual record) and their labels.
  """
  @spec list_manual_projects(pos_integer()) :: [%{item: Item.t(), manual_added_at: DateTime.t()}]
  def list_manual_projects(limit) do
    latest_manual =
      Observation
      |> where([o], is_nil(o.source_id))
      |> group_by([o], o.item_id)
      |> select([o], %{item_id: o.item_id, at: max(o.observed_at)})

    projects_query()
    |> join(:inner, [i], m in subquery(latest_manual), on: m.item_id == i.id)
    |> order_by([i, m], desc: m.at, desc: i.id)
    |> limit(^limit)
    |> preload(labels: ^labels_query())
    |> select([i, m], %{item: i, manual_added_at: m.at})
    |> Repo.all()
  end

  defp find_or_create_project(%{external_id: external_id} = address, name, now) do
    case Repo.get_by(Item, kind: @project, external_id: external_id) do
      %Item{} = item ->
        insert_manual_observation!(item, now)
        keep!([item.id], nil, now)
        {:existing, item}

      nil ->
        case insert_project(address, name, now) do
          {:ok, item} ->
            insert_manual_observation!(item, now)
            keep!([item.id], nil, now)
            after_manual_insert!(item, address, now)
            {:created, item}

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
    end
  end

  defp after_manual_insert!(item, %{github?: true}, _now) do
    {:ok, _job} = enqueue_details(item.id)
    :ok
  end

  defp after_manual_insert!(item, %{host: host}, now),
    do: sync_auto_labels!(item.id, ["host:" <> String.downcase(host)], now)

  defp insert_project(%{external_id: external_id, url: url}, name, now) do
    %Item{}
    |> Item.changeset(%{
      kind: @project,
      external_id: external_id,
      title: name,
      custom_title: true,
      url: url,
      first_seen_at: now,
      last_seen_at: now
    })
    |> Repo.insert()
  end

  defp insert_manual_observation!(%Item{} = item, now) do
    %Observation{}
    |> Observation.changeset(%{
      item_id: item.id,
      period: now |> DateTime.to_date() |> Date.to_iso8601(),
      observed_at: now,
      attributes: %{"via" => "manual"}
    })
    |> Repo.insert!(on_conflict: :nothing, conflict_target: [:source_id, :item_id, :period])
  end

  @doc """
  Queues a GitHub details fetch; at most one is incomplete per project.
  Projects on other hosts have no automatic details.
  """
  @spec enqueue_details(integer()) ::
          {:ok, Styx.Job.t()} | {:error, :details_unsupported | term()}
  def enqueue_details(item_id) when is_integer(item_id) do
    case get_project(item_id) do
      %Item{} = item ->
        if details_supported?(item),
          do: %{item_id: item_id} |> FetchDetailsWorker.new() |> Styx.insert(),
          else: {:error, :details_unsupported}

      nil ->
        {:error, :not_found}
    end
  end

  @doc "Stores fetched GitHub details, clears the last error and recomputes automatic labels."
  @spec put_details(Item.t(), Singularity.GitHub.details(), DateTime.t()) :: {:ok, Item.t()}
  def put_details(%Item{} = item, details, %DateTime{} = now) do
    now = DateTime.truncate(now, :second)

    {:ok, item} = Repo.transaction(fn -> apply_details!(item, details, now) end)
    broadcast_project(item.id)
    {:ok, item}
  end

  defp apply_details!(%Item{} = item, %{attributes: attributes} = details, now) do
    item =
      item
      |> Ecto.Changeset.change(
        title: if(item.custom_title, do: item.title, else: details.title || item.title),
        summary: details.summary,
        attributes: attributes,
        details_fetched_at: now,
        details_error: nil
      )
      |> Repo.update!()

    names = Labels.auto_labels(attributes, observation_sinces(item.id))
    sync_auto_labels!(item.id, names, now)
    item
  end

  @doc "Records why the last details fetch failed."
  @spec put_details_error(Item.t(), String.t()) :: {:ok, Item.t()}
  def put_details_error(%Item{} = item, message) when is_binary(message) do
    item = item |> Ecto.Changeset.change(details_error: message) |> Repo.update!()
    broadcast_project(item.id)
    {:ok, item}
  end

  defp observation_sinces(item_id) do
    Observation
    |> where([o], o.item_id == ^item_id)
    |> select([o], fragment("?->>'since'", o.attributes))
    |> distinct(true)
    |> Repo.all()
    |> Enum.reject(&is_nil/1)
  end

  # Only automatic rows are added or removed; a manual label with the same name is kept.
  defp sync_auto_labels!(item_id, names, now) do
    existing = Label |> where(item_id: ^item_id) |> Repo.all()

    stale_ids =
      for %Label{origin: "auto", name: name, id: id} <- existing, name not in names, do: id

    Label |> where([l], l.id in ^stale_ids) |> Repo.delete_all()

    taken = MapSet.new(existing, & &1.name)

    rows =
      for name <- names, not MapSet.member?(taken, name), do: auto_label_row(item_id, name, now)

    Repo.insert_all(Label, rows, on_conflict: :nothing, conflict_target: [:item_id, :name])
    :ok
  end

  defp auto_label_row(item_id, name, now),
    do: %{item_id: item_id, name: name, origin: "auto", inserted_at: now, updated_at: now}
end
