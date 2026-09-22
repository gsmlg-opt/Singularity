defmodule Singularity.Domains.Documents.Repository do
  @moduledoc """
  Internal authenticated persistence boundary for immutable Document versions.

  Context carries opaque repository, principal, owner and preparation dependencies.
  Storage independently checks scoped principal/owner, source proof and binding,
  and receipt identity. Live runtime custody composition is deferred to Phase 2.
  Claim and reset compare the expected generation; complete atomically checks
  the claimed generation.
  """
  alias Singularity.Core.{DocumentCompletion, DocumentVersion, Error, Types}
  alias Singularity.Domains.Documents.Command
  @type context :: term()
  @callback create_pending(context(), Command.t()) ::
              {:ok, DocumentVersion.t()} | {:error, Error.t()}
  @callback get_version(context(), Types.id(), Types.id()) ::
              {:ok, DocumentVersion.t()} | {:error, Error.t()}
  @callback claim(context(), Types.id(), non_neg_integer(), Types.id(), String.t(), pos_integer()) ::
              {:ok, DocumentVersion.t()} | {:error, Error.t()}
  @callback complete(context(), Types.id(), DocumentCompletion.t()) ::
              {:ok, DocumentVersion.t()} | {:error, Error.t()}
  @callback recover_expired(context(), Types.id(), non_neg_integer()) ::
              {:ok, DocumentVersion.t()} | {:error, Error.t()}
  @callback reset_failed(context(), Types.id(), non_neg_integer(), String.t(), pos_integer()) ::
              {:ok, DocumentVersion.t()} | {:error, Error.t()}
  @callback get_live_scoped(module(), map(), Types.id()) ::
              {:ok, DocumentVersion.t()} | {:error, Error.t()}
  @callback list_live_scoped(module(), map(), map()) ::
              {:ok, %{items: [DocumentVersion.t()], next_cursor: String.t() | nil}}
              | {:error, Error.t()}
  @callback fragments_live_scoped(module(), map(), Types.id()) ::
              {:ok, [Singularity.Core.DocumentFragment.t()]} | {:error, Error.t()}
  @callback source_live_scoped(module(), map(), Types.id()) ::
              {:ok, map()} | {:error, Error.t()}
end
