defmodule Singularity.Domains.Documents.Repository do
  @moduledoc """
  Internal authenticated persistence boundary for immutable Document versions.

  Context carries opaque repository, principal, owner and preparation dependencies.
  Storage independently checks custody and receipt identity. Claim and reset compare
  the expected generation; complete atomically checks the claimed generation.
  """
  alias Singularity.Core.{DocumentCompletion, DocumentVersion, Error, Types}
  alias Singularity.Domains.Documents.Command
  @type context :: term()
  @callback create_pending(context(), Command.t()) ::
              {:ok, DocumentVersion.t()} | {:error, Error.t()}
  @callback get_version(context(), Types.id(), Types.id()) ::
              {:ok, DocumentVersion.t()} | {:error, Error.t()}
  @callback claim(context(), Types.id(), non_neg_integer(), String.t(), pos_integer()) ::
              {:ok, DocumentVersion.t()} | {:error, Error.t()}
  @callback complete(context(), DocumentCompletion.t()) ::
              {:ok, DocumentVersion.t()} | {:error, Error.t()}
  @callback reset_failed(context(), Types.id(), non_neg_integer()) ::
              {:ok, DocumentVersion.t()} | {:error, Error.t()}
end
