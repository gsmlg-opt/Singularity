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
  @callback consume_upload_grant(context(), intent()) ::
              {:ok, map()} | {:error, Error.t()}
  @callback record_sealed_stage(context(), sealed_stage_intent()) ::
              {:ok, sealed_stage_intent()} | {:error, Error.t()}
  @callback transition(context(), intent()) ::
              {:ok, :applied | :stale, Asset.t()} | {:error, Error.t()}
  @callback tombstone_and_release(context(), intent()) ::
              {:ok, map()} | {:error, Error.t()}
end
