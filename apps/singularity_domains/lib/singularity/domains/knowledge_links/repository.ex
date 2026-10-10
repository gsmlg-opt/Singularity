defmodule Singularity.Domains.KnowledgeLinks.Repository do
  @moduledoc """
  Internal owner-authenticated Note source-set persistence boundary.

  Legacy reads return the complete exact-version set, including attachments, citations,
  targets and fragments, in deterministic ordinal/UUID order. Each internal list
  is capped at 100; an oversized set is rejected, never silently truncated.

  Selected reads require an existing authenticated scope. Selection loads only
  the requested reference; resolution hydrates its exact historical source after
  Runtime checks current target read authority.
  """
  alias Singularity.Core.{
    Error,
    NoteAttachmentReference,
    NoteCitationReference,
    NoteSourceSet,
    SourceLocator,
    Types
  }

  @type context :: term()
  @type source_metadata :: %{
          kind: :asset | :note | :document,
          resource_id: Types.id(),
          resource_version_id: Types.id(),
          title: String.t(),
          deleted?: boolean()
        }
  @type selected_fragment :: %{
          fragment_id: String.t(),
          ordinal: non_neg_integer(),
          text: String.t(),
          locator: SourceLocator.t()
        }
  @type resolved_attachment :: %{
          reference: NoteAttachmentReference.t(),
          source: source_metadata()
        }
  @type resolved_citation :: %{
          reference: NoteCitationReference.t(),
          source: source_metadata(),
          fragment: selected_fragment()
        }

  @callback insert_set(context(), NoteSourceSet.t()) ::
              {:ok, NoteSourceSet.t()} | {:error, Error.t()}
  @callback list_set(context(), Types.id(), Types.id()) ::
              {:ok, NoteSourceSet.t()} | {:error, Error.t()}
  @callback select_attachment_in_scope(context(), Types.id(), Types.id(), Types.id()) ::
              {:ok, NoteAttachmentReference.t()} | {:error, Error.t()}
  @callback select_citation_in_scope(context(), Types.id(), Types.id(), Types.id()) ::
              {:ok, NoteCitationReference.t()} | {:error, Error.t()}
  @callback resolve_attachment_in_scope(context(), NoteAttachmentReference.t()) ::
              {:ok, resolved_attachment()} | {:error, Error.t()}
  @callback resolve_citation_in_scope(context(), NoteCitationReference.t()) ::
              {:ok, resolved_citation()} | {:error, Error.t()}
end
