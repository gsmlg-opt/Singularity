defmodule Singularity.Runtime.NativeTextBackupCutLiveTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias Singularity.Core.Error
  alias Singularity.Runtime.{Api, NativeAssetFixture}
  alias Singularity.Storage.Backup.Exporter
  alias Singularity.Storage.{SafeSQL, ScopedRepo, WorkerRepo}

  test "real seal and finalization commits respect both sides of the same repeatable-read cut" do
    NativeAssetFixture.with_fixture(fn fixture ->
      pending = NativeAssetFixture.begin_upload!(fixture, "text/plain", ["cut original\r\n"])

      # The reader pins its actual snapshot before the native session seals.
      # Both entrypoints must keep observing staging on that SAME connection.
      with_pinned_cut(fixture, fn ->
        NativeAssetFixture.finish_upload!(pending)
      end)
      |> assert_admitted()

      # The next real snapshot is after seal, so uploaded text is unsupported.
      fresh_cut(fixture) |> assert_unsupported()

      NativeAssetFixture.verify!()

      assert %{rows: [["verified", 2, "sealed"]]} =
               NativeAssetFixture.observe!(
                 """
                 SELECT asset.state, asset.state_revision, stage.state
                 FROM content.assets asset
                 JOIN content.asset_stages stage ON stage.asset_id = asset.id
                 WHERE asset.id = $1
                 """,
                 [Ecto.UUID.dump!(pending.asset_id)]
               )

      # Genuine finalization commits on a different worker connection while
      # this reader still sees verified text. Never refresh this old snapshot.
      with_pinned_cut(fixture, &NativeAssetFixture.finalize!/0)
      |> assert_unsupported()

      assert {:ok, %{state: :ready, state_revision: 5, detected_media_type: "text/plain"}} =
               Api.asset_summary(fixture.session, pending.asset_id)

      # A newly pinned snapshot after finalization admits the completed Asset.
      fresh_cut(fixture) |> assert_admitted()
      assert NativeAssetFixture.repo_identities() == fixture.repositories
    end)
  end

  defp with_pinned_cut(fixture, writer) do
    parent = self()
    reference = make_ref()

    {reader, monitor} =
      spawn_monitor(fn ->
        parent_monitor = Process.monitor(parent)

        result =
          try do
            value =
              in_snapshot(fixture, fn repo ->
                cut = actual_cut!(repo, fixture.session.vault_id)
                %{rows: [[backend]]} = SafeSQL.query!(repo, "SELECT pg_backend_pid()", [])
                send(parent, {reference, :pinned, backend})

                receive do
                  {^reference, :inspect} -> {:ok, outcomes(repo, cut)}
                  {^reference, :abort} -> {:ok, :aborted}
                  {:DOWN, ^parent_monitor, :process, ^parent, _reason} -> {:ok, :aborted}
                after
                  15_000 -> flunk("native snapshot reader did not receive its barrier release")
                end
              end)

            {:returned, value}
          catch
            kind, reason -> {:raised, kind, reason, __STACKTRACE__}
          end

        send(parent, {reference, :result, result})
      end)

    try do
      receive do
        {^reference, :pinned, backend} ->
          assert %{rows: [[other_backend]]} =
                   SafeSQL.query!(WorkerRepo, "SELECT pg_backend_pid()", [])

          assert backend != other_backend

        {^reference, :result, {:raised, kind, reason, stacktrace}} ->
          :erlang.raise(kind, reason, stacktrace)
      after
        15_000 -> flunk("native snapshot reader did not pin its snapshot")
      end

      writer.()
      send(reader, {reference, :inspect})

      receive do
        {^reference, :result, {:returned, {:ok, result}}} ->
          result

        {^reference, :result, {:raised, kind, reason, stacktrace}} ->
          :erlang.raise(kind, reason, stacktrace)

        {^reference, :result, other} ->
          flunk("native snapshot transaction failed: #{inspect(other)}")
      after
        15_000 -> flunk("native snapshot reader did not finish inspection")
      end
    after
      send(reader, {reference, :abort})
      assert_receive {:DOWN, ^monitor, :process, ^reader, :normal}, 15_000
    end
  end

  defp fresh_cut(fixture) do
    assert {:ok, results} =
             in_snapshot(fixture, fn repo ->
               cut = actual_cut!(repo, fixture.session.vault_id)
               {:ok, outcomes(repo, cut)}
             end)

    results
  end

  defp in_snapshot(fixture, fun) do
    ScopedRepo.transact(
      WorkerRepo,
      Map.take(fixture.session, [:principal_id, :vault_id]),
      [isolation: :repeatable_read],
      fun
    )
  end

  defp outcomes(repo, cut) do
    for version <- [:default, 2, 3], entrypoint <- [:snapshot_cut, :records] do
      result =
        case {entrypoint, version} do
          {:snapshot_cut, :default} -> Exporter.snapshot_cut(repo, cut.vault_id)
          {:snapshot_cut, version} -> Exporter.snapshot_cut(repo, cut.vault_id, version)
          {:records, :default} -> Exporter.records(repo, cut)
          {:records, version} -> Exporter.records(repo, cut, version)
        end

      # Consume logical records inside their original connection/transaction;
      # observing only creation of a lazy stream would not prove it is usable.
      observed =
        case {entrypoint, result} do
          {:records, {:ok, export}} -> {:ok, Enum.count(export.records)}
          {:snapshot_cut, {:ok, captured}} -> {:ok, captured.database_snapshot}
          {_entrypoint, error} -> error
        end

      {version, entrypoint, observed}
    end
  end

  # This fixture contains only genuinely uploaded Assets. Build a truthful
  # records-only cut even when snapshot_cut is correctly blocked by in-flight
  # text. Snapshot, high-water and complete inventory come from THIS reader.
  defp actual_cut!(repo, vault_id) do
    owner = Ecto.UUID.dump!(vault_id)

    %{rows: [[snapshot, high_water]]} =
      SafeSQL.query!(
        repo,
        """
        SELECT txid_current_snapshot()::text,
          (SELECT COALESCE(max(sequence), 0) FROM core.outbox_events WHERE vault_id = $1)
        """,
        [owner]
      )

    %{rows: rows} =
      SafeSQL.query!(
        repo,
        """
        SELECT object.id, object.vault_id, object.key_domain_id, object.classification,
          object.lookup_digest, object.storage_ref, object.ciphertext_byte_size,
          object.ciphertext_hash
        FROM content.asset_objects object
        WHERE object.vault_id = $1 AND object.lifecycle = 'available'
          AND EXISTS (SELECT 1 FROM content.assets asset
            WHERE asset.asset_object_id = object.id AND asset.vault_id = object.vault_id
              AND asset.state NOT IN ('pending_delete', 'deleted'))
        ORDER BY object.id
        """,
        [owner]
      )

    inventory =
      rows
      |> Enum.with_index()
      |> Enum.map(fn {[
                        object_id,
                        owner_id,
                        key_domain,
                        classification,
                        digest,
                        storage_ref,
                        size,
                        hash
                      ], position} ->
        %{
          asset_object_id: Ecto.UUID.load!(object_id),
          vault_id: Ecto.UUID.load!(owner_id),
          key_domain_id: Ecto.UUID.load!(key_domain),
          classification: String.to_existing_atom(classification),
          lookup_digest: digest,
          storage_ref: storage_ref,
          ciphertext_byte_size: size,
          ciphertext_hash: hash,
          inventory_position: position
        }
      end)

    %{
      database_snapshot: snapshot,
      outbox_high_water_mark: high_water,
      object_inventory: inventory,
      manifest_id: Ecto.UUID.generate(),
      snapshot_id: Ecto.UUID.generate(),
      vault_id: vault_id
    }
  end

  defp assert_admitted(results) do
    assert length(results) == 6

    for {_version, entrypoint, result} <- results do
      assert {:ok, observation} = result
      if entrypoint == :records, do: assert(is_integer(observation) and observation > 0)
    end
  end

  defp assert_unsupported(results) do
    assert length(results) == 6

    for {_version, _entrypoint, result} <- results do
      assert {:error, %Error{code: :backup_unsupported, message: nil, details: %{}}} = result
    end
  end
end
