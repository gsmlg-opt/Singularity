defmodule Singularity.Runtime.Notes.DTO do
  @moduledoc "Strict conversion from authorized internal note values to runtime DTOs."

  alias Singularity.Core.Error
  alias Singularity.Core.Types
  alias Singularity.Runtime.DTO.Note
  alias Singularity.Runtime.DTO.NoteConflict
  alias Singularity.Runtime.DTO.NoteConflictDetail
  alias Singularity.Runtime.DTO.NoteExport
  alias Singularity.Runtime.DTO.NoteHistoryPage
  alias Singularity.Runtime.DTO.NoteSaveResult
  alias Singularity.Runtime.DTO.NoteSearchPage
  alias Singularity.Runtime.DTO.NoteSummary
  alias Singularity.Runtime.DTO.NoteTrashPage
  alias Singularity.Runtime.DTO.NoteVersion
  alias Singularity.Runtime.DTO.NoteVersionSummary

  @summary_fields ~w(
    resource_id resource_version_id title revision display_version updated_at
    deleted? open_conflict_count
  )a
  @raw_summary_fields ~w(
    resource_id resource_version_id vault_id classification title revision updated_at
    deleted? open_conflict_count
  )a
  @note_fields @summary_fields ++ [:markdown]
  @raw_note_fields ~w(
    resource_id resource_version_id vault_id classification title markdown revision updated_at
    deleted_at deleted? created_by_principal_id inserted_at parent_version_id
    merge_parent_version_id canonical? open_conflict_count
  )a
  @version_summary_fields ~w(
    resource_version_id revision display_version created_by_principal_id inserted_at
    parent_version_id merge_parent_version_id canonical? conflict_state
  )a
  @raw_version_summary_fields @version_summary_fields -- [:display_version]
  @version_fields @version_summary_fields ++ [:resource_id, :title, :markdown]
  @raw_version_fields @raw_version_summary_fields ++
                        [:resource_id, :vault_id, :classification, :title, :markdown]
  @raw_conflict_fields ~w(
    conflict_id resource_id vault_id classification base_version_id
    observed_canonical_version_id competing_version_id state resolution_version_id
    created_at resolved_at
  )a

  def summary(%NoteSummary{} = value), do: NoteSummary.new(Map.from_struct(value))

  def summary(value) when is_map(value) do
    value = plain_map(value)

    with :ok <- accepted_shape(value, @summary_fields, @raw_summary_fields) do
      value
      |> Map.take(@summary_fields)
      |> Map.put_new(:display_version, display_version(value))
      |> NoteSummary.new()
    end
  end

  def summary(_value), do: integrity_failure()

  def note(%Note{} = value), do: Note.new(Map.from_struct(value))

  def note(value) when is_map(value) do
    value = plain_map(value)

    with :ok <- accepted_shape(value, @note_fields, @raw_note_fields),
         :ok <- validate_raw_note(value) do
      value
      |> Map.take(@note_fields)
      |> Map.put_new(:display_version, display_version(value))
      |> Note.new()
    end
  end

  def note(_value), do: integrity_failure()

  def version_summary(%NoteVersionSummary{} = value),
    do: NoteVersionSummary.new(Map.from_struct(value))

  def version_summary(value) when is_map(value) do
    value = plain_map(value)

    with :ok <- accepted_shape(value, @version_summary_fields, @raw_version_summary_fields) do
      value
      |> Map.take(@version_summary_fields)
      |> Map.put_new(:display_version, display_version(value))
      |> Map.put_new(:conflict_state, nil)
      |> NoteVersionSummary.new()
    end
  end

  def version_summary(_value), do: integrity_failure()

  def version(%NoteVersion{} = value), do: NoteVersion.new(Map.from_struct(value))

  def version(value) when is_map(value) do
    value = plain_map(value)

    with :ok <- accepted_version_shape(value),
         :ok <- validate_raw_note(value) do
      value
      |> Map.take(@version_fields)
      |> Map.put_new(:display_version, display_version(value))
      |> Map.put_new(:conflict_state, nil)
      |> NoteVersion.new()
    end
  end

  def version(_value), do: integrity_failure()

  def conflict(%NoteConflict{} = value), do: NoteConflict.new(Map.from_struct(value))

  def conflict(value) when is_map(value) do
    value = plain_map(value)

    with :ok <- accepted_shape(value, NoteConflict.fields(), @raw_conflict_fields),
         :ok <- validate_raw_conflict(value) do
      value
      |> Map.take(NoteConflict.fields())
      |> NoteConflict.new()
    end
  end

  def conflict(_value), do: integrity_failure()

  def conflict_detail(%NoteConflictDetail{} = value),
    do: NoteConflictDetail.new(Map.from_struct(value))

  def conflict_detail(
        %{conflict: raw_conflict, current: raw_current, competing: raw_competing} =
          value
      ) do
    with {:ok, _attrs} <- exact_attrs(value, [:conflict, :current, :competing]),
         {:ok, conflict} <- conflict(raw_conflict),
         {:ok, current} <- version(raw_current),
         {:ok, competing} <- version(raw_competing),
         :ok <- conflict_resource(raw_conflict, current.resource_id),
         :ok <- conflict_state(raw_conflict, competing.conflict_state),
         true <- competing.resource_version_id == conflict.competing_version_id do
      NoteConflictDetail.new(%{
        conflict_id: conflict.conflict_id,
        base_version_id: conflict.base_version_id,
        observed_canonical_version_id: conflict.observed_canonical_version_id,
        current: current,
        competing: competing
      })
    end
  end

  def conflict_detail(_value), do: integrity_failure()

  def search_page(%NoteSearchPage{} = value), do: NoteSearchPage.new(Map.from_struct(value))

  def search_page(value) when is_map(value) do
    with {:ok, page} <- exact_attrs(value, [:items, :next_cursor]),
         {:ok, items} <- map_list(page.items, &summary/1) do
      NoteSearchPage.new(%{items: items, next_cursor: normalize_cursor(page.next_cursor)})
    end
  end

  def search_page(_value), do: integrity_failure()

  def trash_page(%NoteTrashPage{} = value), do: NoteTrashPage.new(Map.from_struct(value))

  def trash_page(value) when is_map(value) do
    with {:ok, page} <- exact_attrs(value, [:items, :next_cursor]),
         {:ok, items} <- map_list(page.items, &trash_item/1) do
      NoteTrashPage.new(%{items: items, next_cursor: normalize_cursor(page.next_cursor)})
    end
  end

  def trash_page(_value), do: integrity_failure()

  def history_page(%NoteHistoryPage{} = value), do: NoteHistoryPage.new(Map.from_struct(value))

  def history_page(value) when is_map(value) do
    with {:ok, page} <- exact_attrs(value, [:items, :next_cursor]),
         {:ok, items} <- map_list(page.items, &version_summary/1) do
      NoteHistoryPage.new(%{items: items, next_cursor: normalize_cursor(page.next_cursor)})
    end
  end

  def history_page(_value), do: integrity_failure()

  def save_result(%NoteSaveResult{} = value), do: NoteSaveResult.new(Map.from_struct(value))

  def save_result(%{canonical: raw_canonical} = value) do
    with {:ok, canonical} <- note(raw_canonical) do
      value
      |> plain_map()
      |> Map.put(:canonical, canonical)
      |> NoteSaveResult.new()
    end
  end

  def save_result(_value), do: integrity_failure()

  def export(%NoteExport{} = value), do: NoteExport.new(Map.from_struct(value))
  def export(value) when is_map(value), do: NoteExport.new(plain_map(value))
  def export(_value), do: integrity_failure()

  @doc false
  def exact_attrs(value, fields) when is_map(value) and is_list(fields) do
    value = plain_map(value)

    if MapSet.new(Map.keys(value)) == MapSet.new(fields),
      do: {:ok, value},
      else: integrity_failure()
  end

  def exact_attrs(_value, _fields), do: integrity_failure()

  @doc false
  def uuid(attrs, key) do
    case Types.canonical_uuid(attrs, key) do
      {:ok, value} -> {:ok, value}
      _invalid -> integrity_failure()
    end
  end

  @doc false
  def optional_uuid(attrs, key) do
    case Map.get(attrs, key) do
      nil -> {:ok, nil}
      _value -> uuid(attrs, key)
    end
  end

  @doc false
  def utc_datetime(attrs, key) do
    case Types.utc_datetime(attrs, key) do
      {:ok, value} -> {:ok, value}
      _invalid -> integrity_failure()
    end
  end

  @doc false
  def optional_utc_datetime(attrs, key) do
    case Map.get(attrs, key) do
      nil -> {:ok, nil}
      _value -> utc_datetime(attrs, key)
    end
  end

  @doc false
  def title?(value),
    do:
      is_binary(value) and String.valid?(value) and String.trim(value) != "" and
        byte_size(value) <= 255

  @doc false
  def markdown?(value),
    do:
      is_binary(value) and String.valid?(value) and byte_size(value) <= 1_048_576 and
        :binary.match(value, <<0>>) == :nomatch

  @doc false
  def cursor?(nil), do: true

  def cursor?(value) when is_binary(value),
    do:
      byte_size(value) <= 2_048 and String.valid?(value) and String.trim(value) != "" and
        :binary.match(value, <<0>>) == :nomatch

  def cursor?(_value), do: false

  @doc false
  def integrity_failure, do: {:error, Error.new(:integrity_failure)}

  defp display_version(%{revision: revision}) when is_integer(revision), do: revision + 1
  defp display_version(_value), do: nil

  defp normalize_cursor(:done), do: nil
  defp normalize_cursor(cursor), do: cursor

  defp trash_item(%{summary: raw_summary, deleted_at: deleted_at} = item)
       when map_size(item) == 2 do
    with {:ok, summary} <- summary(raw_summary) do
      {:ok, %{summary: summary, deleted_at: deleted_at}}
    end
  end

  defp trash_item(value) when is_map(value) do
    with {:ok, _item} <- exact_attrs(value, @raw_summary_fields ++ [:deleted_at]),
         {:ok, summary} <- value |> Map.delete(:deleted_at) |> summary() do
      {:ok, %{summary: summary, deleted_at: Map.get(value, :deleted_at)}}
    else
      _invalid -> integrity_failure()
    end
  end

  defp trash_item(_value), do: integrity_failure()

  defp map_list(values, mapper) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, converted} ->
      case mapper.(value) do
        {:ok, item} -> {:cont, {:ok, [item | converted]}}
        {:error, %Error{}} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, converted} -> {:ok, Enum.reverse(converted)}
      error -> error
    end
  end

  defp map_list(_values, _mapper), do: integrity_failure()

  defp plain_map(%_{} = value), do: Map.from_struct(value)
  defp plain_map(value), do: value

  defp accepted_version_shape(value) do
    cond do
      exact_keys?(value, @version_fields) -> :ok
      exact_keys?(value, @raw_version_fields) -> internal_scope(value)
      exact_keys?(value, @raw_note_fields) -> internal_scope(value)
      true -> integrity_failure()
    end
  end

  defp accepted_shape(value, dto_fields, internal_fields) do
    cond do
      exact_keys?(value, dto_fields) ->
        :ok

      exact_keys?(value, internal_fields) and :vault_id in internal_fields ->
        internal_scope(value)

      exact_keys?(value, internal_fields) ->
        :ok

      true ->
        integrity_failure()
    end
  end

  defp internal_scope(%{vault_id: vault_id, classification: :private}) do
    case uuid(%{vault_id: vault_id}, :vault_id) do
      {:ok, _vault_id} -> :ok
      _invalid -> integrity_failure()
    end
  end

  defp internal_scope(_value), do: integrity_failure()

  defp validate_raw_note(value) do
    cond do
      exact_keys?(value, @note_fields) ->
        :ok

      exact_keys?(value, @version_fields) ->
        :ok

      exact_keys?(value, @raw_version_fields) ->
        :ok

      exact_keys?(value, @raw_note_fields) and value.canonical? and
        value.deleted? == false and is_nil(value.deleted_at) ->
        :ok

      true ->
        integrity_failure()
    end
  end

  defp validate_raw_conflict(value) do
    if exact_keys?(value, NoteConflict.fields()) do
      :ok
    else
      with {:ok, _resource_id} <- uuid(value, :resource_id),
           {:ok, _created_at} <- utc_datetime(value, :created_at),
           :ok <- validate_raw_conflict_state(value) do
        :ok
      else
        _invalid -> integrity_failure()
      end
    end
  end

  defp validate_raw_conflict_state(%{
         state: :open,
         resolution_version_id: nil,
         resolved_at: nil
       }),
       do: :ok

  defp validate_raw_conflict_state(%{state: :resolved} = value) do
    with {:ok, resolution_id} <- uuid(value, :resolution_version_id),
         {:ok, _resolved_at} <- utc_datetime(value, :resolved_at),
         true <-
           resolution_id not in [
             value.base_version_id,
             value.observed_canonical_version_id,
             value.competing_version_id
           ] do
      :ok
    else
      _invalid -> integrity_failure()
    end
  end

  defp validate_raw_conflict_state(_value), do: integrity_failure()

  defp conflict_resource(%{resource_id: resource_id}, resource_id), do: :ok
  defp conflict_resource(%NoteConflict{}, _resource_id), do: :ok
  defp conflict_resource(_conflict, _resource_id), do: integrity_failure()

  defp conflict_state(%{state: state}, state) when state in [:open, :resolved], do: :ok
  defp conflict_state(%NoteConflict{}, state) when state in [:open, :resolved], do: :ok
  defp conflict_state(_conflict, _state), do: integrity_failure()

  defp exact_keys?(value, fields),
    do: MapSet.new(Map.keys(value)) == MapSet.new(fields)
end
