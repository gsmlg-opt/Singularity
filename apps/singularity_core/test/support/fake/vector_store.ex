defmodule Singularity.Core.TestSupport.Fake.VectorStore do
  @moduledoc false

  @behaviour Singularity.Core.VectorStore

  alias Singularity.Core.Error
  alias Singularity.Core.TestSupport.Fake.Control
  alias Singularity.Core.VectorMatch

  def start_link(options) when is_list(options) do
    Control.start_link(%{
      collections: Keyword.get(options, :collections, %{}),
      points: Keyword.get(options, :points, %{}),
      search_results: Keyword.get(options, :search_results, default_search_results())
    })
  end

  def calls(context), do: Control.calls(context)
  def fail_next(context, %Error{} = error), do: Control.fail_next(context, error)

  @impl true
  def ensure_collection(context, collection_spec) do
    Control.run(context, :ensure_collection, [collection_spec], fn data ->
      case Map.fetch(data.collections, collection_spec.name) do
        :error ->
          new_data = put_in(data, [:collections, collection_spec.name], collection_spec)
          {{:ok, collection_spec}, new_data}

        {:ok, ^collection_spec} ->
          {{:ok, collection_spec}, data}

        {:ok, _incompatible_spec} ->
          {{:error, %Error{code: :conflict}}, data}
      end
    end)
  end

  @impl true
  def fetch_collection(context, collection_name) do
    Control.run(context, :fetch_collection, [collection_name], fn data ->
      {fetch(data.collections, collection_name), data}
    end)
  end

  @impl true
  def upsert_points(context, collection_name, points) do
    Control.run(context, :upsert_points, [collection_name, points], fn data ->
      if Map.has_key?(data.collections, collection_name) do
        collection_points = Map.get(data.points, collection_name, %{})

        new_points =
          Enum.reduce(points, collection_points, fn point, accumulator ->
            Map.put(accumulator, point.point_id, point)
          end)

        point_ids = Enum.map(points, & &1.point_id)
        {{:ok, point_ids}, put_in(data, [:points, collection_name], new_points)}
      else
        {{:error, %Error{code: :not_found}}, data}
      end
    end)
  end

  @impl true
  def fetch_points(context, collection_name, point_ids) do
    Control.run(context, :fetch_points, [collection_name, point_ids], fn data ->
      if Map.has_key?(data.collections, collection_name) do
        collection_points = Map.get(data.points, collection_name, %{})

        points =
          Enum.flat_map(point_ids, fn point_id ->
            case Map.fetch(collection_points, point_id) do
              {:ok, point} -> [point]
              :error -> []
            end
          end)

        {{:ok, points}, data}
      else
        {{:error, %Error{code: :not_found}}, data}
      end
    end)
  end

  @impl true
  def delete_points(context, collection_name, point_ids) do
    Control.run(context, :delete_points, [collection_name, point_ids], fn data ->
      if Map.has_key?(data.collections, collection_name) do
        collection_points = Map.get(data.points, collection_name, %{})
        new_points = Map.drop(collection_points, point_ids)
        {{:ok, :ok}, put_in(data, [:points, collection_name], new_points)}
      else
        {{:error, %Error{code: :not_found}}, data}
      end
    end)
  end

  @impl true
  def search(context, collection_name, query_vector, filters, limit, options) do
    arguments = [collection_name, query_vector, filters, limit, options]

    Control.run(context, :search, arguments, fn data ->
      if Map.has_key?(data.collections, collection_name) do
        matches =
          data.search_results
          |> Map.get(collection_name, [])
          |> Enum.sort_by(&{-&1.score, &1.point_id})
          |> Enum.take(limit)

        {{:ok, matches}, data}
      else
        {{:error, %Error{code: :not_found}}, data}
      end
    end)
  end

  @impl true
  def scroll(context, collection_name, cursor) do
    Control.run(context, :scroll, [collection_name, cursor], fn data ->
      if Map.has_key?(data.collections, collection_name) do
        points =
          data.points
          |> Map.get(collection_name, %{})
          |> Map.values()
          |> Enum.sort_by(& &1.point_id)

        {{:ok, {points, :done}}, data}
      else
        {{:error, %Error{code: :not_found}}, data}
      end
    end)
  end

  defp fetch(values, id) do
    case Map.fetch(values, id) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, %Error{code: :not_found}}
    end
  end

  defp default_search_results do
    %{
      "knowledge-v1" => [
        %VectorMatch{point_id: "point-b", score: 0.8, payload: %{"rank" => 3}},
        %VectorMatch{point_id: "point-c", score: 0.9, payload: %{"rank" => 2}},
        %VectorMatch{point_id: "point-a", score: 0.9, payload: %{"rank" => 1}}
      ],
      "archive-v1" => [
        %VectorMatch{point_id: "archive-point", score: 0.7, payload: %{"archive" => true}}
      ]
    }
  end
end
