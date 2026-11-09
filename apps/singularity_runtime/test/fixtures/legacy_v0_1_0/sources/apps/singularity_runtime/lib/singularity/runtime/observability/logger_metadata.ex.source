defmodule Singularity.Runtime.Observability.LoggerMetadata do
  @moduledoc """
  Defines the default-deny metadata contract for structured operational logs.

  Only opaque identifiers and bounded operation/result fields are admitted.
  """

  require Logger

  alias Singularity.Runtime.Observability.Redactor

  @allowed_keys [
    :correlation_id,
    :principal_id,
    :vault_id,
    :resource_id,
    :asset_id,
    :outbox_id,
    :job_id,
    :operation,
    :result
  ]
  @id_keys [
    :correlation_id,
    :principal_id,
    :vault_id,
    :resource_id,
    :asset_id,
    :outbox_id,
    :job_id
  ]
  @results [
    :ok,
    :error,
    :allowed,
    :denied,
    :completed,
    :failed,
    :cancelled,
    :retry,
    :snoozed
  ]

  @spec allowed_keys() :: [atom()]
  def allowed_keys, do: @allowed_keys

  @spec sanitize(map() | keyword()) :: map()
  def sanitize(metadata) when is_list(metadata) do
    metadata
    |> Map.new()
    |> sanitize()
  end

  def sanitize(metadata) when is_map(metadata) do
    metadata
    |> Enum.reduce(%{}, fn {key, value}, safe ->
      if key in @allowed_keys and safe_value?(key, value) do
        Map.put(safe, key, value)
      else
        safe
      end
    end)
    |> Redactor.redact()
  end

  @spec log(Logger.level(), map() | keyword(), map() | keyword()) :: :ok
  def log(level, message, metadata \\ [])
      when (is_map(message) or is_list(message)) and
             (is_map(metadata) or is_list(metadata)) do
    process_metadata = Logger.metadata()

    Logger.reset_metadata(
      process_metadata
      |> sanitize()
      |> Map.to_list()
    )

    try do
      Logger.log(
        level,
        sanitize(message),
        metadata
        |> sanitize()
        |> Map.to_list()
      )
    after
      Logger.reset_metadata(process_metadata)
    end
  end

  defp safe_value?(key, value) when key in @id_keys do
    match?({:ok, ^value}, Ecto.UUID.cast(value))
  end

  defp safe_value?(:operation, value), do: is_atom(value) and not is_nil(value)
  defp safe_value?(:result, value), do: value in @results
  defp safe_value?(_key, _value), do: false
end
