defmodule Singularity.Core.KnowledgeStore do
  @moduledoc """
  Persistence contract for canonical knowledge, projections, and answer runs.

  List callbacks return `{:ok, []}` when no values match. Identity fetches return
  `{:error, %Singularity.Core.Error{code: :not_found}}` when absent. Scans accept
  a `nil` or string cursor and return `:done` when complete.
  """

  alias Singularity.Core.AnswerRun
  alias Singularity.Core.KnowledgeChunk
  alias Singularity.Core.KnowledgeItem
  alias Singularity.Core.KnowledgeRevision
  alias Singularity.Core.ProjectionState
  alias Singularity.Core.Stored

  @type context :: term()
  @type error :: Singularity.Core.Error.t()
  @type result(value) :: {:ok, value} | {:error, error()}

  @doc "Creates an item and returns it with its opaque storage version."
  @callback create_item(context(), KnowledgeItem.t()) :: result(Stored.t(KnowledgeItem.t()))

  @doc "Fetches an item by identity."
  @callback fetch_item(context(), String.t()) :: result(Stored.t(KnowledgeItem.t()))

  @doc "Replaces an item using its opaque storage version."
  @callback replace_item(context(), Stored.t(KnowledgeItem.t())) ::
              result(Stored.t(KnowledgeItem.t()))

  @doc "Creates an immutable knowledge revision."
  @callback create_revision(context(), KnowledgeRevision.t()) :: result(KnowledgeRevision.t())

  @doc "Fetches a revision by identity."
  @callback fetch_revision(context(), String.t()) :: result(KnowledgeRevision.t())

  @doc "Lists an item's revisions, returning an empty list when none exist."
  @callback list_revisions(context(), String.t()) :: result([KnowledgeRevision.t()])

  @doc "Stores the complete chunk set for a revision identity."
  @callback put_chunks(context(), String.t(), [KnowledgeChunk.t()]) ::
              result([KnowledgeChunk.t()])

  @doc "Fetches a chunk by identity."
  @callback fetch_chunk(context(), String.t()) :: result(KnowledgeChunk.t())

  @doc "Lists a revision's chunks, returning an empty list when none exist."
  @callback list_chunks(context(), String.t()) :: result([KnowledgeChunk.t()])

  @doc "Stores projection state for its revision identity."
  @callback put_projection_state(context(), ProjectionState.t()) :: result(ProjectionState.t())

  @doc "Fetches projection state by revision identity."
  @callback fetch_projection_state(context(), String.t()) :: result(ProjectionState.t())

  @doc "Appends an immutable answer run."
  @callback append_answer_run(context(), AnswerRun.t()) :: result(AnswerRun.t())

  @doc "Fetches an answer run by identity."
  @callback fetch_answer_run(context(), String.t()) :: result(AnswerRun.t())

  @doc "Scans current revisions from a cursor, returning the next cursor or `:done`."
  @callback scan_current_revisions(context(), nil | String.t()) ::
              result({[KnowledgeRevision.t()], :done | String.t()})
end
