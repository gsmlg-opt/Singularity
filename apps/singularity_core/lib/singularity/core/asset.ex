defmodule Singularity.Core.Asset do
  @moduledoc "A vault-scoped asset with revisioned lifecycle and orthogonal failure metadata."

  alias Singularity.Core.Classification
  alias Singularity.Core.Error
  alias Singularity.Core.Types

  @states ~w[staging uploaded verified available processing ready pending_delete deleted]a

  @enforce_keys [
    :asset_id,
    :vault_id,
    :resource_version_id,
    :classification,
    :state,
    :state_revision
  ]
  defstruct [
    :asset_id,
    :vault_id,
    :resource_version_id,
    :classification,
    :state,
    :state_revision,
    failure_code: nil,
    retryable?: false,
    failed_operation: nil,
    attempt: 0,
    metadata: %{}
  ]

  @type state ::
          :staging
          | :uploaded
          | :verified
          | :available
          | :processing
          | :ready
          | :pending_delete
          | :deleted

  @type t :: %__MODULE__{
          asset_id: Types.id(),
          vault_id: Types.id(),
          resource_version_id: Types.id(),
          classification: Classification.t(),
          state: state(),
          state_revision: non_neg_integer(),
          failure_code: Error.code() | nil,
          retryable?: boolean(),
          failed_operation: String.t() | nil,
          attempt: non_neg_integer(),
          metadata: Types.metadata()
        }

  @spec new(map() | keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(attrs) do
    with {:ok, attrs} <- Types.attrs(attrs),
         {:ok, asset_id} <- Types.opaque_string(attrs, :asset_id),
         {:ok, vault_id} <- Types.opaque_string(attrs, :vault_id),
         {:ok, resource_version_id} <- Types.opaque_string(attrs, :resource_version_id),
         {:ok, classification} <- Classification.new(Map.get(attrs, :classification)),
         {:ok, state} <- state(Map.get(attrs, :state)),
         {:ok, state_revision} <- Types.non_neg_integer(attrs, :state_revision, 0),
         {:ok, failure_code} <- failure_code(Map.get(attrs, :failure_code)),
         {:ok, retryable?} <- Types.boolean(attrs, :retryable?, false),
         {:ok, failed_operation} <- Types.optional_opaque_string(attrs, :failed_operation),
         {:ok, attempt} <- Types.non_neg_integer(attrs, :attempt, 0),
         {:ok, metadata} <- Types.metadata(attrs) do
      {:ok,
       %__MODULE__{
         asset_id: asset_id,
         vault_id: vault_id,
         resource_version_id: resource_version_id,
         classification: classification,
         state: state,
         state_revision: state_revision,
         failure_code: failure_code,
         retryable?: retryable?,
         failed_operation: failed_operation,
         attempt: attempt,
         metadata: metadata
       }}
    end
  end

  defp state(value) when value in @states, do: {:ok, value}
  defp state(_value), do: Types.invalid()

  defp failure_code(nil), do: {:ok, nil}

  defp failure_code(value) when is_atom(value) do
    if value in Error.codes(), do: {:ok, value}, else: Types.invalid()
  end

  defp failure_code(_value), do: Types.invalid()
end
