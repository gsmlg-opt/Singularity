defmodule Singularity.Domains.Assets do
  @moduledoc "Pure orchestration for asset workflows."

  alias Singularity.Core.Asset
  alias Singularity.Core.Classification
  alias Singularity.Core.Error
  alias Singularity.Core.SourceReference
  alias Singularity.Core.Types

  @spec create_upload_intent(
          %{repository: module(), context: term()},
          map()
        ) :: {:ok, map()} | {:error, Error.t()}
  def create_upload_intent(%{repository: repository, context: context}, command)
      when is_atom(repository) and is_map(command) do
    with {:ok, intent} <- upload_intent(command) do
      repository.create_upload_intent(context, intent)
    end
  end

  def create_upload_intent(_adapters, _command), do: {:error, Error.new(:invalid)}

  @spec transition(
          %{repository: module(), context: term(), audit: module(), outbox: module()},
          map()
        ) ::
          {:ok, :applied | :stale, Asset.t()} | {:error, Error.t()}
  def transition(
        %{
          repository: repository,
          context: context,
          audit: audit,
          outbox: outbox
        },
        command
      )
      when is_atom(repository) and is_atom(audit) and is_atom(outbox) and is_map(command) do
    with {:ok, intent} <- transition_intent(command) do
      repository.transition(context, intent)
    end
  end

  def transition(_adapters, _command), do: {:error, Error.new(:invalid)}

  @spec tombstone_and_release(
          %{repository: module(), context: term(), audit: module(), outbox: module()},
          map()
        ) :: {:ok, map()} | {:error, Error.t()}
  def tombstone_and_release(
        %{
          repository: repository,
          context: context,
          audit: audit,
          outbox: outbox
        },
        command
      )
      when is_atom(repository) and is_atom(audit) and is_atom(outbox) and is_map(command) do
    with {:ok, intent} <- deletion_intent(command) do
      repository.tombstone_and_release(context, intent)
    end
  end

  def tombstone_and_release(_adapters, _command),
    do: {:error, Error.new(:invalid)}

  @spec record_sealed_upload(
          %{repository: module(), context: term(), audit: module(), outbox: module()},
          map()
        ) ::
          {:ok, map()} | {:error, Error.t()}
  def record_sealed_upload(
        %{
          repository: repository,
          context: context,
          audit: audit,
          outbox: outbox
        },
        command
      )
      when is_atom(repository) and is_atom(audit) and is_atom(outbox) and is_map(command) do
    with {:ok, intent} <- sealed_stage_intent(command) do
      repository.record_sealed_stage(context, intent)
    end
  end

  def record_sealed_upload(_adapters, _command), do: {:error, Error.new(:invalid)}

  defp upload_intent(command) do
    with {:ok, idempotency_key} <- Types.opaque_string(command, :idempotency_key),
         {:ok, asset_id} <- Types.opaque_string(command, :asset_id),
         {:ok, vault_id} <- Types.opaque_string(command, :vault_id),
         {:ok, resource_version_id} <- Types.opaque_string(command, :resource_version_id),
         {:ok, source_reference_id} <-
           Types.opaque_string(command, :source_reference_id),
         {:ok, resource_version_classification} <-
           Classification.new(Map.get(command, :resource_version_classification)),
         {:ok, classification} <- Classification.new(Map.get(command, :classification)),
         :ok <-
           Classification.assert_not_downgraded(
             resource_version_classification,
             classification
           ),
         {:ok, principal_id} <- Types.opaque_string(command, :principal_id),
         {:ok, filename} <- Types.opaque_string(command, :filename),
         {:ok, declared_media_type} <-
           Types.normalized_string(command, :declared_media_type),
         {:ok, byte_size} <- Types.non_neg_integer(command, :byte_size),
         {:ok, digest} <- Types.opaque_string(command, :digest),
         {:ok, observed_at} <- Types.utc_datetime(command, :server_observed_at),
         {:ok, asset} <-
           Asset.new(%{
             asset_id: asset_id,
             vault_id: vault_id,
             resource_version_id: resource_version_id,
             classification: classification,
             state: :staging,
             state_revision: 0
           }),
         {:ok, provenance} <-
           SourceReference.new(%{
             source_reference_id: source_reference_id,
             vault_id: vault_id,
             resource_version_id: resource_version_id,
             principal_id: principal_id,
             kind: :browser_upload,
             observed_at: observed_at,
             metadata: %{
               "filename" => filename,
               "declared_media_type" => declared_media_type,
               "byte_size" => byte_size,
               "digest" => digest
             }
           }) do
      {:ok,
       %{
         idempotency_key: idempotency_key,
         asset: asset,
         provenance: provenance
       }}
    end
  end

  defp transition_intent(command) do
    with {:ok, asset_id} <- Types.opaque_string(command, :asset_id),
         {:ok, principal_id} <- Types.opaque_string(command, :principal_id),
         {:ok, classification} <- Classification.new(Map.get(command, :classification)),
         {:ok, expected_state_revision} <-
           Types.non_neg_integer(command, :expected_state_revision),
         {:ok, to} <- Types.atom_value(command, :to) do
      {:ok,
       %{
         asset_id: asset_id,
         principal_id: principal_id,
         classification: classification,
         expected_state_revision: expected_state_revision,
         to: to,
         audit: %{
           operation: "asset.transitioned",
           asset_id: asset_id,
           principal_id: principal_id,
           classification: classification,
           to: to
         },
         outbox: %{
           event_type: "asset.transitioned",
           asset_id: asset_id,
           principal_id: principal_id,
           classification: classification,
           to: to
         }
       }}
    end
  end

  defp deletion_intent(command) do
    with {:ok, asset_id} <- Types.opaque_string(command, :asset_id),
         {:ok, principal_id} <- Types.opaque_string(command, :principal_id),
         {:ok, classification} <- Classification.new(Map.get(command, :classification)),
         {:ok, expected_state_revision} <-
           Types.non_neg_integer(command, :expected_state_revision) do
      {:ok,
       %{
         asset_id: asset_id,
         principal_id: principal_id,
         classification: classification,
         expected_state_revision: expected_state_revision,
         tombstone: %{
           asset_id: asset_id,
           state: :pending_delete,
           classification: classification
         },
         audit: %{
           operation: "asset.tombstoned",
           asset_id: asset_id,
           principal_id: principal_id,
           classification: classification
         },
         outbox: %{
           event_type: "asset.release_requested",
           asset_id: asset_id,
           principal_id: principal_id,
           classification: classification
         }
       }}
    end
  end

  defp sealed_stage_intent(command) do
    with {:ok, asset_id} <- Types.opaque_string(command, :asset_id),
         {:ok, vault_id} <- Types.opaque_string(command, :vault_id),
         {:ok, resource_version_id} <-
           Types.optional_opaque_string(command, :resource_version_id),
         {:ok, principal_id} <- principal_id(command),
         {:ok, sealed_ref} <- Types.opaque_string(command, :sealed_ref),
         {:ok, filename} <- Types.opaque_string(command, :filename),
         {:ok, content_type} <- Types.normalized_string(command, :content_type),
         {:ok, byte_size} <- Types.non_neg_integer(command, :byte_size),
         {:ok, checksum} <- Types.opaque_string(command, :checksum),
         {:ok, classification} <- Classification.new(Map.get(command, :classification)),
         {:ok, resource_version_classification} <-
           Classification.new(Map.get(command, :resource_version_classification, classification)),
         {:ok, outbox_classification} <-
           Classification.new(Map.get(command, :outbox_classification, classification)),
         {:ok, audit_classification} <-
           Classification.new(Map.get(command, :audit_classification, outbox_classification)),
         :ok <-
           Classification.assert_not_downgraded(
             resource_version_classification,
             classification
           ),
         :ok <-
           Classification.assert_not_downgraded(
             classification,
             outbox_classification
           ),
         :ok <-
           Classification.assert_not_downgraded(
             outbox_classification,
             audit_classification
           ) do
      {:ok,
       %{
         asset: %{
           asset_id: asset_id,
           vault_id: vault_id,
           resource_version_id: resource_version_id,
           principal_id: principal_id,
           sealed_ref: sealed_ref,
           filename: filename,
           content_type: content_type,
           byte_size: byte_size,
           checksum: checksum,
           classification: classification,
           state: :uploaded
         },
         audit: %{
           operation: "asset.uploaded",
           asset_id: asset_id,
           vault_id: vault_id,
           principal_id: principal_id,
           classification: audit_classification
         },
         outbox: %{
           event_type: "asset.verify_requested",
           asset_id: asset_id,
           vault_id: vault_id,
           principal_id: principal_id,
           classification: outbox_classification
         }
       }}
    end
  end

  defp principal_id(%{principal_id: principal_id}),
    do: Types.opaque_string(%{principal_id: principal_id}, :principal_id)

  defp principal_id(%{identity_id: identity_id}),
    do: Types.opaque_string(%{principal_id: identity_id}, :principal_id)

  defp principal_id(_command), do: {:error, Error.new(:invalid)}
end
