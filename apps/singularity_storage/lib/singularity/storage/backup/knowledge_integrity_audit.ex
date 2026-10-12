defmodule Singularity.Storage.Backup.KnowledgeIntegrityAudit do
  @moduledoc "V3 knowledge integrity composition; legacy rebuilding remains unchanged."

  alias Singularity.Core.Error
  alias Singularity.Storage.Backup.{IntegrityAudit, KnowledgeIntegrityInventory}

  @spec verify_document_sources(module(), map(), [map()], [map()]) ::
          :ok | {:error, Error.t()}
  defdelegate verify_document_sources(repo, binding, original_inventory, plaintext_hashes),
    to: KnowledgeIntegrityInventory

  @spec rebuild(module(), map()) :: {:ok, IntegrityAudit.SearchSummary.t()} | {:error, Error.t()}
  defdelegate rebuild(repo, binding), to: IntegrityAudit
end
