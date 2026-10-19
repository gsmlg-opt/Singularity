defmodule Singularity.Runtime.Knowledge.Export do
  @moduledoc "Portable-export input and public-result boundaries."

  alias Singularity.Core.{Error, KnowledgeExport}
  alias Singularity.Runtime.Knowledge.ExportArtifact.Handle

  @handle_keys [:__struct__, :binding, :deadline, :operation_ref, :owner]
  @cursor_keys [:after, :operation_id, :proof]
  @descriptor_keys ["byte_size", "media_type", "path", "sha256"]

  def validate(:export_knowledge, [options]) when is_map(options) and not is_struct(options) do
    case KnowledgeExport.options(options) do
      {:ok, _options} -> :ok
      {:error, %Error{}} -> invalid()
    end
  end

  def validate(:knowledge_export_entries, [handle, cursor]),
    do: valid_input(handle?(handle) and cursor?(cursor))

  def validate(:read_knowledge_export_chunk, [handle, path, ordinal]),
    do:
      valid_input(
        handle?(handle) and relative_path?(path) and is_integer(ordinal) and ordinal >= 0
      )

  def validate(:close_knowledge_export, [handle]), do: valid_input(handle?(handle))
  def validate(_operation, _arguments), do: invalid()

  def public_result({:ok, handle} = result, :export_knowledge),
    do: valid_result(handle?(handle), result)

  def public_result({:ok, page} = result, :knowledge_export_entries),
    do: valid_result(page?(page), result)

  def public_result({:ok, bytes} = result, :read_knowledge_export_chunk),
    do: valid_result(is_binary(bytes) and byte_size(bytes) <= 65_536, result)

  def public_result(:ok, :close_knowledge_export), do: :ok

  def public_result({:error, %Error{code: code, retryable?: retryable?}}, _operation)
      when is_boolean(retryable?) do
    if code in Error.codes(),
      do: {:error, Error.new(code, retryable?: retryable?)},
      else: integrity_failure()
  end

  def public_result({:error, %Error{}}, _operation), do: integrity_failure()

  def public_result({:error, code}, _operation) when is_atom(code) do
    if code in Error.codes(),
      do: {:error, Error.new(code)},
      else: storage_unavailable()
  end

  def public_result({:error, _reason}, _operation), do: storage_unavailable()
  def public_result(_result, _operation), do: integrity_failure()

  # These fields are identity hints and local routing only. Current authority,
  # stored operation reference and cursor membership require the live owner.
  defp handle?(
         %Handle{owner: owner, operation_ref: reference, binding: binding, deadline: deadline} =
           handle
       ) do
    Enum.sort(Map.keys(handle)) == @handle_keys and is_pid(owner) and node(owner) == node() and
      is_reference(reference) and binding?(binding) and is_integer(deadline)
  end

  defp handle?(_handle), do: false

  defp binding?({session, principal, owner, principal_epoch, owner_epoch}) do
    Enum.all?([session, principal, owner], &uuid?/1) and
      is_integer(principal_epoch) and principal_epoch >= 0 and
      is_integer(owner_epoch) and owner_epoch >= 0
  end

  defp binding?(_binding), do: false

  defp cursor?(nil), do: true

  defp cursor?(cursor) when is_map(cursor) and not is_struct(cursor) do
    Enum.sort(Map.keys(cursor)) == @cursor_keys and uuid?(cursor.operation_id) and
      relative_path?(cursor.after) and digest?(cursor.proof)
  end

  defp cursor?(_cursor), do: false

  defp page?(page) when is_map(page) and not is_struct(page) do
    Enum.sort(Map.keys(page)) == [:entries, :next_cursor] and
      descriptors?(page.entries) and cursor?(page.next_cursor)
  end

  defp page?(_page), do: false

  defp descriptors?(entries) when is_list(entries), do: descriptors?(entries, 0)
  defp descriptors?(_entries), do: false

  defp descriptors?([], _count), do: true

  defp descriptors?([entry | rest], count) when count < 500,
    do: descriptor?(entry) and descriptors?(rest, count + 1)

  defp descriptors?(_entries, _count), do: false

  defp descriptor?(entry) when is_map(entry) and not is_struct(entry) do
    Enum.sort(Map.keys(entry)) == @descriptor_keys and relative_path?(entry["path"]) and
      is_binary(entry["media_type"]) and entry["media_type"] != "" and
      is_integer(entry["byte_size"]) and entry["byte_size"] >= 0 and digest?(entry["sha256"])
  end

  defp descriptor?(_entry), do: false

  defp relative_path?(path) when is_binary(path) do
    String.valid?(path) and path != "" and Path.type(path) == :relative and
      not String.contains?(path, ["\\", <<0>>]) and
      Enum.all?(String.split(path, "/"), &(&1 not in ["", ".", ".."]))
  end

  defp relative_path?(_path), do: false

  defp uuid?(value) when is_binary(value), do: Ecto.UUID.cast(value) == {:ok, value}
  defp uuid?(_value), do: false

  defp digest?(value) when is_binary(value) and byte_size(value) == 64,
    do: value |> :binary.bin_to_list() |> Enum.all?(&(&1 in ?0..?9 or &1 in ?a..?f))

  defp digest?(_value), do: false

  defp valid_input(true), do: :ok
  defp valid_input(false), do: invalid()
  defp valid_result(true, result), do: result
  defp valid_result(false, _result), do: integrity_failure()
  defp invalid, do: {:error, Error.new(:invalid)}
  defp integrity_failure, do: {:error, Error.new(:integrity_failure)}
  defp storage_unavailable, do: {:error, Error.new(:storage_unavailable, retryable?: true)}
end
