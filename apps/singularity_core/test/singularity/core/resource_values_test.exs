defmodule Singularity.Core.ResourceValuesTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.Asset
  alias Singularity.Core.ObjectRef
  alias Singularity.Core.Resource
  alias Singularity.Core.ResourceVersion
  alias Singularity.Core.SourceReference
  alias Singularity.Core.StageRef

  test "resources and immutable versions retain vault and classification context" do
    assert {:ok,
            %Resource{
              resource_id: "resource-1",
              vault_id: "vault-1",
              classification: :private
            }} =
             Resource.new(%{
               resource_id: "resource-1",
               vault_id: "vault-1",
               classification: :private
             })

    assert {:ok,
            %ResourceVersion{
              resource_version_id: "version-1",
              resource_id: "resource-1",
              vault_id: "vault-1",
              classification: :sensitive,
              revision: 7
            }} =
             ResourceVersion.new(%{
               resource_version_id: "version-1",
               resource_id: "resource-1",
               vault_id: "vault-1",
               classification: :sensitive,
               revision: 7
             })
  end

  test "resource values reject invalid classifications, revisions, and metadata keys" do
    assert {:error, %{code: :invalid}} =
             Resource.new(%{
               resource_id: "resource-1",
               vault_id: "vault-1",
               classification: :public
             })

    assert {:error, %{code: :invalid}} =
             ResourceVersion.new(%{
               resource_version_id: "version-1",
               resource_id: "resource-1",
               vault_id: "vault-1",
               classification: :private,
               revision: -1
             })

    assert {:error, %{code: :invalid}} =
             Resource.new(%{
               resource_id: "resource-1",
               vault_id: "vault-1",
               classification: :private,
               metadata: %{source: "upload"}
             })
  end

  test "assets carry lifecycle revision and failure metadata without a failed state" do
    assert {:ok,
            %Asset{
              asset_id: "asset-1",
              vault_id: "vault-1",
              resource_version_id: "version-1",
              classification: :restricted,
              state: :ready,
              state_revision: 4,
              failure_code: :job_failed,
              retryable?: true,
              failed_operation: "metadata",
              attempt: 2
            }} =
             Asset.new(%{
               asset_id: "asset-1",
               vault_id: "vault-1",
               resource_version_id: "version-1",
               classification: :restricted,
               state: :ready,
               state_revision: 4,
               failure_code: :job_failed,
               retryable?: true,
               failed_operation: "metadata",
               attempt: 2
             })
  end

  test "source references preserve minimal provenance and require UTC observation time" do
    assert {:ok,
            %SourceReference{
              source_reference_id: "source-1",
              vault_id: "vault-1",
              resource_version_id: "version-1",
              principal_id: "principal-1",
              kind: :browser_upload,
              observed_at: ~U[2026-07-18 08:00:00Z]
            }} =
             SourceReference.new(%{
               source_reference_id: "source-1",
               vault_id: "vault-1",
               resource_version_id: "version-1",
               principal_id: "principal-1",
               kind: :browser_upload,
               observed_at: ~U[2026-07-18 08:00:00Z]
             })

    assert {:error, %{code: :invalid}} =
             SourceReference.new(%{
               source_reference_id: "source-1",
               vault_id: "vault-1",
               resource_version_id: "version-1",
               principal_id: "principal-1",
               kind: :browser_upload,
               observed_at: ~N[2026-07-18 08:00:00]
             })
  end

  test "storage references are opaque strings" do
    assert {:ok, %StageRef{stage_id: "stage/arbitrary"}} =
             StageRef.new(%{stage_id: "stage/arbitrary"})

    assert {:ok, %ObjectRef{object_id: "object/arbitrary"}} =
             ObjectRef.new(%{object_id: "object/arbitrary"})
  end
end
