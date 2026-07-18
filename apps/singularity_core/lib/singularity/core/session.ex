defmodule Singularity.Core.Session do
  @moduledoc "An opaque authentication session with a UTC expiry."

  alias Singularity.Core.Error
  alias Singularity.Core.Types

  @enforce_keys [:session_id, :account_id, :principal_id, :expires_at]
  defstruct [:session_id, :account_id, :principal_id, :expires_at, metadata: %{}]

  @type t :: %__MODULE__{
          session_id: Types.id(),
          account_id: Types.id(),
          principal_id: Types.id(),
          expires_at: Types.timestamp(),
          metadata: Types.metadata()
        }

  @spec new(map() | keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(attrs) do
    with {:ok, attrs} <- Types.attrs(attrs),
         {:ok, session_id} <- Types.opaque_string(attrs, :session_id),
         {:ok, account_id} <- Types.opaque_string(attrs, :account_id),
         {:ok, principal_id} <- Types.opaque_string(attrs, :principal_id),
         {:ok, expires_at} <- Types.utc_datetime(attrs, :expires_at),
         {:ok, metadata} <- Types.metadata(attrs) do
      {:ok,
       %__MODULE__{
         session_id: session_id,
         account_id: account_id,
         principal_id: principal_id,
         expires_at: expires_at,
         metadata: metadata
       }}
    end
  end
end
