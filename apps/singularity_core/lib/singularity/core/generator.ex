defmodule Singularity.Core.Generator do
  @moduledoc "Provider-independent streaming answer-generation contract."

  alias Singularity.Core.GenerationEvent
  alias Singularity.Core.GenerationRequest
  alias Singularity.Core.GenerationResult

  @type context :: term()
  @type error :: Singularity.Core.Error.t()
  @type result(value) :: {:ok, value} | {:error, error()}

  @doc """
  Delivers ordered events synchronously to the sink before returning the final result.

  Citation labels in the returned result map to labels in the request's supplied evidence.
  """
  @callback generate_answer_stream(
              context(),
              GenerationRequest.t(),
              (GenerationEvent.t() -> :ok)
            ) :: result(GenerationResult.t())
end
