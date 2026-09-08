defmodule Singularity.Storage.Postgres.DocumentMutationReceiptsTest do
  use Singularity.Storage.DataCase, async: false
  @moduletag :integration
  alias Singularity.Core.Error
  alias Singularity.Storage.{KnowledgeFixtures, KnowledgeTestGrants, ScopedRepo}
  alias Singularity.Storage.Postgres.{DocumentMutationReceipts, KnowledgeError}

  test "receipt cannot commit dangling result, and callback errors roll back ownership" do
    source = KnowledgeFixtures.prepared_source!()
    context = KnowledgeFixtures.document_context(source)
    command = KnowledgeFixtures.document_command(source)

    claim = %{
      owner_scope_id: source.vault_id,
      principal_id: source.principal_id,
      mutation_id: command.mutation_id,
      fingerprint: :binary.copy(<<8>>, 32),
      inserted_at: command.inserted_at
    }

    KnowledgeTestGrants.with_receipt_grants(fn ->
      for result <- [
            {:ok,
             %{resource_id: command.resource_id, resource_version_id: command.resource_version_id}},
            {:error, Error.new(:conflict)}
          ] do
        assert {:error, %Error{message: nil, details: %{}}} =
                 ScopedRepo.transact(
                   RequestRepo,
                   %{principal_id: context.principal_id, vault_id: context.owner_scope_id},
                   fn repo ->
                     DocumentMutationReceipts.with_claim(repo, claim, fn -> result end)
                   end
                 )
      end
    end)

    assert %{rows: [[false]]} =
             query!(
               RequestRepo,
               "SELECT has_table_privilege(current_user,'content.document_import_receipts','UPDATE')"
             )
  end

  test "central errors retain only stable code and retryability" do
    assert %Error{code: :storage_unavailable, retryable?: true, message: nil, details: %{}} =
             KnowledgeError.from(%DBConnection.ConnectionError{message: "secret connection data"})

    assert %Error{code: :conflict, message: nil, details: %{}} =
             KnowledgeError.from(%Postgrex.Error{
               postgres: %{
                 code: :check_violation,
                 constraint: "document_extraction_conflict_check",
                 detail: "secret title"
               }
             })

    assert %Error{code: :invalid, message: nil, details: %{}} =
             KnowledgeError.from(
               Error.new(:invalid, message: "secret", details: %{content: "secret"})
             )
  end
end
