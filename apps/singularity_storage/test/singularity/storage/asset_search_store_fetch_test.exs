defmodule Singularity.Storage.AssetSearchStoreFetchTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.Error
  alias Singularity.Storage.Postgres.AssetSearchStore

  @vault_id "00000000-0000-4000-8000-000000000801"
  @asset_id "00000000-0000-4000-8000-000000000802"
  @resource_version_id "00000000-0000-4000-8000-000000000803"

  defmodule Repo do
    def one(query) do
      send(Process.get(:asset_fetch_owner), {:one, query})
      Process.get(:asset_fetch_row)
    end
  end

  setup do
    Process.put(:asset_fetch_owner, self())
    Process.put(:asset_fetch_row, row())

    on_exit(fn ->
      Process.delete(:asset_fetch_owner)
      Process.delete(:asset_fetch_row)
    end)
  end

  test "fetch returns the canonical projection and maps its SQL classification rank" do
    assert {:ok, result} =
             AssetSearchStore.fetch(Repo, %{
               vault_id: @vault_id,
               asset_id: @asset_id
             })

    assert result == %{
             asset_id: @asset_id,
             resource_version_id: @resource_version_id,
             vault_id: @vault_id,
             classification: :private,
             state: :processing,
             state_revision: 4,
             detected_media_type: "application/pdf",
             resource_title: "Annual report",
             original_filename: "annual.pdf",
             failure: %{
               code: "storage_unavailable",
               retryable: true,
               operation: "asset_metadata",
               attempt: 2
             },
             updated_at: ~U[2026-07-21 00:00:00.000000Z]
           }

    assert_receive {:one, %Ecto.Query{}}
  end

  test "fetch returns the same not-found result for an absent exact projection" do
    Process.put(:asset_fetch_row, nil)

    assert {:error, %Error{code: :not_found}} =
             AssetSearchStore.fetch(Repo, %{
               vault_id: @vault_id,
               asset_id: @asset_id
             })
  end

  defp row do
    %{
      asset_id: @asset_id,
      resource_version_id: @resource_version_id,
      vault_id: @vault_id,
      canonical_classification_rank: 0,
      state: :processing,
      state_revision: 4,
      failure_code: "storage_unavailable",
      failure_retryable: true,
      failed_operation: "asset_metadata",
      failure_attempt: 2,
      detected_media_type: "application/pdf",
      resource_title: "Annual report",
      original_filename: "annual.pdf",
      updated_at: ~U[2026-07-21 00:00:00.000000Z]
    }
  end
end
