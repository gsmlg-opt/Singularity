defmodule Singularity.Ingest.UploadCheckpoint do
  @moduledoc "Pure state machine for durable upload-session checkpoints."

  alias Singularity.Core.Error

  @enforce_keys [:grant_id, :state, :revision]
  defstruct [:grant_id, :state, :revision, :failure_code]

  @type state :: :granted | :consumed | :open | :sealed | :uploaded | :abandoned
  @type t :: %__MODULE__{
          grant_id: String.t(),
          state: state(),
          revision: non_neg_integer(),
          failure_code: atom() | String.t() | nil
        }

  @transitions %{
    granted: :consumed,
    consumed: :open,
    open: :sealed,
    sealed: :uploaded
  }
  @states [:granted, :consumed, :open, :sealed, :uploaded, :abandoned]

  @spec new(String.t()) :: t()
  def new(grant_id) when is_binary(grant_id) and byte_size(grant_id) > 0 do
    %__MODULE__{grant_id: grant_id, state: :granted, revision: 0}
  end

  @spec advance(t(), state()) :: {:ok, t()} | {:error, Error.t()}
  def advance(%__MODULE__{state: current, revision: revision} = checkpoint, next)
      when next in @states do
    if Map.get(@transitions, current) == next do
      {:ok, %{checkpoint | state: next, revision: revision + 1}}
    else
      {:error, Error.new(:conflict)}
    end
  end

  def advance(%__MODULE__{}, _next), do: {:error, Error.new(:invalid)}

  @spec abandon(t(), atom() | String.t()) :: {:ok, t()} | {:error, Error.t()}
  def abandon(%__MODULE__{state: :abandoned} = checkpoint, _reason),
    do: {:ok, checkpoint}

  def abandon(%__MODULE__{state: :uploaded}, _reason),
    do: {:error, Error.new(:conflict)}

  def abandon(%__MODULE__{revision: revision} = checkpoint, reason)
      when is_atom(reason) or is_binary(reason) do
    {:ok,
     %{
       checkpoint
       | state: :abandoned,
         revision: revision + 1,
         failure_code: reason
     }}
  end

  def abandon(%__MODULE__{}, _reason), do: {:error, Error.new(:invalid)}

  @spec terminal?(t()) :: boolean()
  def terminal?(%__MODULE__{state: state}), do: state in [:uploaded, :abandoned]
end
