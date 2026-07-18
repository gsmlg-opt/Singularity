defmodule Singularity.Core.AssetState do
  @moduledoc "The authoritative asset lifecycle transition table."

  alias Singularity.Core.Asset
  alias Singularity.Core.Error

  @transitions %{
    staging: [:uploaded, :pending_delete],
    uploaded: [:verified, :pending_delete],
    verified: [:available, :pending_delete],
    available: [:processing, :pending_delete],
    processing: [:ready, :pending_delete],
    ready: [:pending_delete],
    pending_delete: [:deleted],
    deleted: []
  }

  @spec transition(Asset.t(), Asset.state(), non_neg_integer()) ::
          {:ok, Asset.t()} | {:error, Error.t()}
  def transition(%Asset{state_revision: actual}, _to, expected) when actual != expected,
    do: {:error, Error.new(:conflict)}

  def transition(%Asset{state: from} = asset, to, expected) do
    if to in Map.fetch!(@transitions, from),
      do: {:ok, %{asset | state: to, state_revision: expected + 1}},
      else: {:error, Error.new(:invalid)}
  end
end
