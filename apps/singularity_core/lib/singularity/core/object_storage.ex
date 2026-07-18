defmodule Singularity.Core.ObjectStorage do
  @moduledoc "Port for staged and immutable encrypted object storage."

  alias Singularity.Core.Error
  alias Singularity.Core.ObjectRef
  alias Singularity.Core.StageRef

  @type context :: term()

  @callback stage(context(), map()) :: {:ok, StageRef.t()} | {:error, Error.t()}
  @callback append_encrypted_chunk(context(), StageRef.t(), iodata()) ::
              :ok | {:error, Error.t()}
  @callback seal_stage(context(), StageRef.t(), map()) ::
              {:ok, map()} | {:error, Error.t()}
  @callback stat_stage(context(), StageRef.t()) :: {:ok, map()} | {:error, Error.t()}
  @callback finalize(context(), StageRef.t(), ObjectRef.t()) ::
              {:ok, ObjectRef.t()} | {:error, Error.t()}
  @callback abort_stage(context(), StageRef.t()) :: :ok | {:error, Error.t()}
  @callback stat(context(), ObjectRef.t()) :: {:ok, map()} | {:error, Error.t()}
  @callback open(context(), ObjectRef.t()) :: {:ok, term()} | {:error, Error.t()}
  @callback read_range(context(), term(), Range.t()) ::
              {:ok, binary()} | {:error, Error.t()}
  @callback verify(context(), ObjectRef.t()) :: :ok | {:error, Error.t()}
  @callback delete(context(), ObjectRef.t()) :: :ok | {:error, Error.t()}
  @callback list_staged(context()) :: {:ok, [StageRef.t()]} | {:error, Error.t()}
end
