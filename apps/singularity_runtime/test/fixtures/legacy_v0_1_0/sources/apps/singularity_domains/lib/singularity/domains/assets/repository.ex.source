defmodule Singularity.Domains.Assets.Repository do
  @moduledoc "Persistence boundary for atomic asset workflow intents."

  alias Singularity.Core.Asset
  alias Singularity.Core.Error

  @type context :: term()
  @type intent :: map()
  @type sealed_stage_intent :: %{
          required(:asset) => map(),
          required(:audit) => map(),
          required(:outbox) => map()
        }

  @callback create_upload_intent(context(), intent()) ::
              {:ok, map()} | {:error, Error.t()}
  @callback create_upload_grant(context(), intent()) ::
              {:ok, map()} | {:error, Error.t()}
  @callback cancel_upload_grant(context(), intent()) ::
              {:ok, map()} | {:error, Error.t()}
  @callback load_upload_grant_descriptor(context(), intent()) ::
              {:ok, map()} | {:error, Error.t()}
  @callback authorized_download_descriptor(context(), String.t()) ::
              {:ok, map()} | {:error, Error.t()}
  @callback consume_upload_grant(context(), intent()) ::
              {:ok, map()} | {:error, Error.t()}
  @callback consume_grant_and_create_stage(context(), intent()) ::
              {:ok, map()} | {:error, Error.t()}
  @callback mark_stage_abandoned(context(), intent()) ::
              {:ok, map()} | {:error, Error.t()}
  @callback record_sealed_stage(context(), sealed_stage_intent()) ::
              {:ok, sealed_stage_intent()} | {:error, Error.t()}
  @callback prepare_verification(context(), intent()) ::
              {:ok, map()} | {:error, Error.t()}
  @callback record_verified_stage(context(), intent()) ::
              {:ok, map()} | {:error, Error.t()}
  @callback resolve_finalization(context(), intent()) ::
              {:ok, map()} | {:error, Error.t()}
  @callback reserve_finalization(context(), intent()) ::
              {:ok, map()} | {:error, Error.t()}
  @callback acknowledge_finalization(context(), intent()) ::
              {:ok, map()} | {:error, Error.t()}
  @callback record_job_failure(context(), intent(), Error.t()) ::
              {:ok, map()} | {:error, Error.t()}
  @callback transition(context(), intent()) ::
              {:ok, :applied | :stale, Asset.t()} | {:error, Error.t()}
  @callback tombstone_and_release(context(), intent()) ::
              {:ok, map()} | {:error, Error.t()}
end
