defmodule Singularity.Domains.Notes.Repository do
  @moduledoc "Persistence boundary for canonical private note mutation intents."

  alias Singularity.Core.Error

  @type context :: term()
  @type intent :: map()

  @callback create(context(), intent()) :: {:ok, term()} | {:error, Error.t()}
  @callback save(context(), intent()) :: {:ok, term()} | {:error, Error.t()}
  @callback merge(context(), intent()) :: {:ok, term()} | {:error, Error.t()}
  @callback tombstone(context(), intent()) :: {:ok, term()} | {:error, Error.t()}
  @callback restore(context(), intent()) :: {:ok, term()} | {:error, Error.t()}
end
