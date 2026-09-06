defmodule Singularity.Domains.KnowledgeLinks.Repository do
  @moduledoc """
  Internal owner-authenticated Note source-set persistence boundary.

  Reads return the complete exact-version set, including attachments, citations,
  targets and fragments, in deterministic ordinal/UUID order. Each internal list
  is capped at 100; an oversized set is rejected, never silently truncated.
  """
  alias Singularity.Core.{Error, NoteSourceSet, Types}
  @type context :: term()
  @callback insert_set(context(), NoteSourceSet.t()) ::
              {:ok, NoteSourceSet.t()} | {:error, Error.t()}
  @callback list_set(context(), Types.id(), Types.id()) ::
              {:ok, NoteSourceSet.t()} | {:error, Error.t()}
end
