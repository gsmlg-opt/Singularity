defmodule Singularity.Core.TestSupport.Fake.KnowledgeStore do
  @moduledoc false

  @behaviour Singularity.Core.KnowledgeStore

  alias Singularity.Core.Error
  alias Singularity.Core.Stored
  alias Singularity.Core.TestSupport.Fake.Control

  def start_link(options) when is_list(options) do
    Control.start_link(%{
      items: Keyword.get(options, :items, %{}),
      revisions: Keyword.get(options, :revisions, %{}),
      chunks: Keyword.get(options, :chunks, %{}),
      projection_states: Keyword.get(options, :projection_states, %{}),
      answer_runs: Keyword.get(options, :answer_runs, %{})
    })
  end

  def calls(context), do: Control.calls(context)
  def fail_next(context, %Error{} = error), do: Control.fail_next(context, error)

  @impl true
  def create_item(context, item) do
    Control.run(context, :create_item, [item], fn data ->
      cond do
        not valid_heads?(item.head_revision_ids, data.revisions) ->
          {{:error, %Error{code: :invalid}}, data}

        Map.has_key?(data.items, item.item_id) ->
          {{:error, %Error{code: :already_exists}}, data}

        true ->
          stored = %Stored{value: item, version: "1"}
          {{:ok, stored}, put_in(data, [:items, item.item_id], stored)}
      end
    end)
  end

  @impl true
  def fetch_item(context, item_id) do
    Control.run(context, :fetch_item, [item_id], fn data ->
      {fetch(data.items, item_id), data}
    end)
  end

  @impl true
  def replace_item(context, %Stored{value: item, version: version}) do
    Control.run(context, :replace_item, [%Stored{value: item, version: version}], fn data ->
      case Map.fetch(data.items, item.item_id) do
        :error ->
          {{:error, %Error{code: :not_found}}, data}

        {:ok, current} ->
          cond do
            not valid_heads?(item.head_revision_ids, data.revisions) ->
              {{:error, %Error{code: :invalid}}, data}

            current.version != version ->
              {{:error, %Error{code: :conflict}}, data}

            true ->
              next_version =
                current.version |> String.to_integer() |> Kernel.+(1) |> Integer.to_string()

              stored = %Stored{value: item, version: next_version}
              {{:ok, stored}, put_in(data, [:items, item.item_id], stored)}
          end
      end
    end)
  end

  @impl true
  def create_revision(context, revision) do
    Control.run(context, :create_revision, [revision], fn data ->
      case Map.fetch(data.revisions, revision.revision_id) do
        :error ->
          {{:ok, revision}, put_in(data, [:revisions, revision.revision_id], revision)}

        {:ok, ^revision} ->
          {{:ok, revision}, data}

        {:ok, _different_revision} ->
          {{:error, %Error{code: :already_exists}}, data}
      end
    end)
  end

  @impl true
  def fetch_revision(context, revision_id) do
    Control.run(context, :fetch_revision, [revision_id], fn data ->
      {fetch(data.revisions, revision_id), data}
    end)
  end

  @impl true
  def list_revisions(context, item_id) do
    Control.run(context, :list_revisions, [item_id], fn data ->
      revisions =
        data.revisions
        |> Map.values()
        |> Enum.filter(&(&1.item_id == item_id))
        |> Enum.sort_by(& &1.revision_id)

      {{:ok, revisions}, data}
    end)
  end

  @impl true
  def put_chunks(context, revision_id, chunks) do
    Control.run(context, :put_chunks, [revision_id, chunks], fn data ->
      if Enum.all?(chunks, &(&1.revision_id == revision_id)) do
        case put_immutable_chunks(data.chunks, chunks) do
          {:ok, stored_chunks} ->
            result = chunks |> Enum.uniq_by(& &1.chunk_id) |> sort_chunks()
            {{:ok, result}, %{data | chunks: stored_chunks}}

          {:error, error} ->
            {{:error, error}, data}
        end
      else
        {{:error, %Error{code: :invalid}}, data}
      end
    end)
  end

  @impl true
  def fetch_chunk(context, chunk_id) do
    Control.run(context, :fetch_chunk, [chunk_id], fn data ->
      {fetch(data.chunks, chunk_id), data}
    end)
  end

  @impl true
  def list_chunks(context, revision_id) do
    Control.run(context, :list_chunks, [revision_id], fn data ->
      chunks =
        data.chunks
        |> Map.values()
        |> Enum.filter(&(&1.revision_id == revision_id))
        |> sort_chunks()

      {{:ok, chunks}, data}
    end)
  end

  @impl true
  def put_projection_state(context, projection_state) do
    Control.run(context, :put_projection_state, [projection_state], fn data ->
      new_data =
        put_in(data, [:projection_states, projection_state.revision_id], projection_state)

      {{:ok, projection_state}, new_data}
    end)
  end

  @impl true
  def fetch_projection_state(context, revision_id) do
    Control.run(context, :fetch_projection_state, [revision_id], fn data ->
      {fetch(data.projection_states, revision_id), data}
    end)
  end

  @impl true
  def append_answer_run(context, answer_run) do
    Control.run(context, :append_answer_run, [answer_run], fn data ->
      if Map.has_key?(data.answer_runs, answer_run.run_id) do
        {{:error, %Error{code: :already_exists}}, data}
      else
        {{:ok, answer_run}, put_in(data, [:answer_runs, answer_run.run_id], answer_run)}
      end
    end)
  end

  @impl true
  def fetch_answer_run(context, run_id) do
    Control.run(context, :fetch_answer_run, [run_id], fn data ->
      {fetch(data.answer_runs, run_id), data}
    end)
  end

  @impl true
  def scan_current_revisions(context, cursor) do
    Control.run(context, :scan_current_revisions, [cursor], fn data ->
      revisions =
        data.items
        |> Map.values()
        |> Enum.map(& &1.value)
        |> Enum.reject(&(&1.status == :deleted))
        |> Enum.flat_map(& &1.head_revision_ids)
        |> Enum.uniq()
        |> Enum.map(&Map.fetch!(data.revisions, &1))
        |> Enum.sort_by(& &1.revision_id)

      {{:ok, {revisions, :done}}, data}
    end)
  end

  defp fetch(values, id) do
    case Map.fetch(values, id) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, %Error{code: :not_found}}
    end
  end

  defp valid_heads?(head_revision_ids, revisions) do
    Enum.all?(head_revision_ids, &Map.has_key?(revisions, &1))
  end

  defp put_immutable_chunks(stored_chunks, chunks) do
    Enum.reduce_while(chunks, {:ok, stored_chunks}, fn chunk, {:ok, accumulator} ->
      case Map.fetch(accumulator, chunk.chunk_id) do
        :error -> {:cont, {:ok, Map.put(accumulator, chunk.chunk_id, chunk)}}
        {:ok, ^chunk} -> {:cont, {:ok, accumulator}}
        {:ok, _different_chunk} -> {:halt, {:error, %Error{code: :already_exists}}}
      end
    end)
  end

  defp sort_chunks(chunks), do: Enum.sort_by(chunks, &{&1.position, &1.chunk_id})
end
