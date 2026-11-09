defmodule Singularity.Domains.Notes.Repository do
  @moduledoc "Persistence boundary for canonical private note mutation intents."

  alias Singularity.Core.Error
  alias Singularity.Core.NoteSaveResult
  alias Singularity.Core.Types

  @type context :: term()
  @type intent :: map()
  @type saved_note_result :: %NoteSaveResult{outcome: :saved}
  @type tombstone_result :: %{
          required(:resource_id) => Types.id(),
          required(:canonical_version_id) => Types.id(),
          required(:state) => :tombstoned
        }
  @type restore_result :: %{
          required(:resource_id) => Types.id(),
          required(:canonical_version_id) => Types.id(),
          required(:state) => :restored
        }

  @callback create(context(), intent()) :: {:ok, saved_note_result()} | {:error, Error.t()}
  @callback save(context(), intent()) :: {:ok, NoteSaveResult.t()} | {:error, Error.t()}
  @callback merge(context(), intent()) :: {:ok, saved_note_result()} | {:error, Error.t()}
  @callback tombstone(context(), intent()) ::
              {:ok, tombstone_result()} | {:error, Error.t()}
  @callback restore(context(), intent()) ::
              {:ok, restore_result()} | {:error, Error.t()}
end
