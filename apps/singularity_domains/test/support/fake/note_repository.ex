defmodule Fake.NoteRepository do
  @behaviour Singularity.Domains.Notes.Repository

  @intent_keys %{
    create: [
      :classification,
      :correlation_id,
      :mutation_id,
      :principal_id,
      :request_fingerprint,
      :snapshot,
      :vault_id
    ],
    save: [
      :base_version_id,
      :classification,
      :correlation_id,
      :mutation_id,
      :principal_id,
      :request_fingerprint,
      :resource_id,
      :snapshot,
      :vault_id
    ],
    merge: [
      :classification,
      :competing_version_id,
      :conflict_id,
      :correlation_id,
      :expected_current_version_id,
      :mutation_id,
      :principal_id,
      :request_fingerprint,
      :resource_id,
      :snapshot,
      :vault_id
    ],
    tombstone: [
      :classification,
      :correlation_id,
      :expected_current_version_id,
      :mutation_id,
      :principal_id,
      :request_fingerprint,
      :resource_id,
      :vault_id
    ],
    restore: [
      :classification,
      :correlation_id,
      :mutation_id,
      :principal_id,
      :request_fingerprint,
      :resource_id,
      :vault_id
    ]
  }

  def start_link(owner, results) when is_pid(owner) and is_map(results) do
    Agent.start_link(fn -> %{owner: owner, results: results} end)
  end

  @impl true
  def create(context, intent), do: record(context, :create, intent)

  @impl true
  def save(context, intent), do: record(context, :save, intent)

  @impl true
  def merge(context, intent), do: record(context, :merge, intent)

  @impl true
  def tombstone(context, intent), do: record(context, :tombstone, intent)

  @impl true
  def restore(context, intent), do: record(context, :restore, intent)

  defp record(context, operation, intent) when is_map(intent) do
    if Map.keys(intent) |> Enum.sort() == Map.fetch!(@intent_keys, operation) do
      Agent.get(context, fn %{owner: owner, results: results} ->
        send(owner, {operation, intent})
        Map.fetch!(results, operation)
      end)
    else
      raise ArgumentError, "unexpected #{operation} intent"
    end
  end
end
