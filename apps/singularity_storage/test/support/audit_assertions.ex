defmodule Singularity.Storage.AuditAssertions do
  @moduledoc false

  import ExUnit.Assertions

  @columns [
    :id,
    :vault_id,
    :actor_kind,
    :principal_id,
    :anonymous_fingerprint,
    :system_principal_name,
    :operation,
    :result,
    :classification,
    :correlation_id,
    :target_type,
    :target_id,
    :metadata,
    :occurred_at
  ]
  @results ~w[allowed denied completed failed]
  @classifications ~w[private sensitive restricted]

  @spec assert_persisted_audit!(
          module(),
          String.t(),
          keyword(String.t()),
          keyword(term())
        ) :: map()
  def assert_persisted_audit!(repo, operation, selector, expectations \\ [])

  def assert_persisted_audit!(
        repo,
        operation,
        [correlation_id: correlation_id],
        expectations
      ) do
    repo
    |> fetch_one!(operation, "correlation_id", correlation_id)
    |> assert_contract!(expectations)
  end

  def assert_persisted_audit!(repo, operation, [target_id: target_id], expectations) do
    repo
    |> fetch_one!(operation, "target_id", target_id)
    |> assert_contract!(expectations)
  end

  def assert_persisted_audit!(_repo, _operation, selector, _expectations) do
    flunk(
      "expected audit selector to be exactly [correlation_id: uuid] or " <>
        "[target_id: uuid], got: #{inspect(selector)}"
    )
  end

  defp fetch_one!(repo, operation, selector_column, selector_value) do
    selector_value = dump_uuid!(selector_value)

    result =
      Ecto.Adapters.SQL.query!(
        repo,
        """
        SELECT
          id::text,
          vault_id::text,
          actor_kind,
          principal_id::text,
          anonymous_fingerprint,
          system_principal_name,
          operation,
          result,
          classification,
          correlation_id::text,
          target_type,
          target_id::text,
          metadata,
          occurred_at
        FROM audit.events
        WHERE operation = $1
          AND #{selector_column} = $2::uuid
        ORDER BY id
        """,
        [operation, selector_value],
        log: false
      )

    assert [values] = result.rows,
           "expected exactly one persisted #{inspect(operation)} audit event selected by " <>
             "#{selector_column}, got #{length(result.rows)}"

    @columns
    |> Enum.zip(values)
    |> Map.new()
  end

  defp assert_contract!(event, expectations) do
    assert_uuid!(event.id, :id)
    assert_uuid!(event.correlation_id, :correlation_id)
    assert_uuid!(event.target_id, :target_id)

    assert is_binary(event.operation) and event.operation != ""
    assert event.result in @results
    assert event.classification in @classifications
    assert is_binary(event.target_type) and String.trim(event.target_type) != ""
    assert is_map(event.metadata)
    assert %DateTime{} = event.occurred_at

    assert_actor!(event)

    refute inspect(event, limit: :infinity, printable_limit: :infinity) =~ "CANARY_",
           "persisted audit event contains a secret canary"

    Enum.each(expectations, fn {field, expected} ->
      assert Map.has_key?(event, field),
             "unknown persisted audit expectation: #{inspect(field)}"

      assert Map.fetch!(event, field) == expected,
             "expected persisted audit #{field} to equal #{inspect(expected)}, " <>
               "got: #{inspect(Map.fetch!(event, field))}"
    end)

    event
  end

  defp assert_actor!(event) do
    actor_shapes = [
      principal_actor?(event),
      system_actor?(event),
      anonymous_actor?(event)
    ]

    assert Enum.count(actor_shapes, & &1) == 1,
           "expected exactly one valid persisted audit actor form, got: #{inspect(event)}"
  end

  defp principal_actor?(event) do
    event.actor_kind == "principal" and
      uuid?(event.principal_id) and
      uuid?(event.vault_id) and
      is_nil(event.anonymous_fingerprint) and
      is_nil(event.system_principal_name)
  end

  defp system_actor?(event) do
    event.actor_kind == "system" and
      is_nil(event.principal_id) and
      uuid?(event.vault_id) and
      is_nil(event.anonymous_fingerprint) and
      is_binary(event.system_principal_name) and
      String.trim(event.system_principal_name) != ""
  end

  defp anonymous_actor?(event) do
    event.actor_kind == "anonymous" and
      is_nil(event.principal_id) and
      is_nil(event.vault_id) and
      is_binary(event.anonymous_fingerprint) and
      byte_size(event.anonymous_fingerprint) == 32 and
      is_nil(event.system_principal_name)
  end

  defp assert_uuid!(value, field) do
    assert uuid?(value), "expected persisted audit #{field} to be a canonical UUID"
  end

  defp uuid?(value) when is_binary(value) do
    match?({:ok, ^value}, Ecto.UUID.cast(value))
  end

  defp uuid?(_value), do: false

  defp dump_uuid!(<<_::128>> = uuid), do: uuid
  defp dump_uuid!(uuid), do: Ecto.UUID.dump!(uuid)
end
