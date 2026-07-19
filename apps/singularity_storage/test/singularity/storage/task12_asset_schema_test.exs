defmodule Singularity.Storage.Task12AssetSchemaTest do
  use Singularity.Storage.DataCase, async: false

  @moduletag :integration

  test "open stages defer sealed crypto evidence and objects persist cleanup claims" do
    assert %{rows: stage_columns} =
             query!(
               RequestRepo,
               """
               SELECT column_name, is_nullable
               FROM information_schema.columns
               WHERE table_schema = 'content'
                 AND table_name = 'asset_stages'
                 AND column_name = ANY($1)
               ORDER BY column_name
               """,
               [
                 ~w[
                   candidate_object_id
                   ciphertext_byte_size
                   ciphertext_hash
                   dek_wrapper
                   domain_key_version_id
                   format_version
                   key_generation
                   lookup_digest
                   plaintext_byte_size
                   upload_grant_id
                   wrapper_algorithm
                 ]
               ]
             )

    assert stage_columns == [
             ["candidate_object_id", "NO"],
             ["ciphertext_byte_size", "YES"],
             ["ciphertext_hash", "YES"],
             ["dek_wrapper", "NO"],
             ["domain_key_version_id", "NO"],
             ["format_version", "YES"],
             ["key_generation", "NO"],
             ["lookup_digest", "YES"],
             ["plaintext_byte_size", "YES"],
             ["upload_grant_id", "NO"],
             ["wrapper_algorithm", "NO"]
           ]

    assert %{rows: grant_columns} =
             query!(
               RequestRepo,
               """
               SELECT column_name, is_nullable
               FROM information_schema.columns
               WHERE table_schema = 'content'
                 AND table_name = 'upload_grants'
                 AND column_name = ANY($1)
               ORDER BY column_name
               """,
               [
                 ~w[
                   principal_authorization_epoch
                   source_reference_id
                   vault_authorization_epoch
                 ]
               ]
             )

    assert grant_columns == [
             ["principal_authorization_epoch", "NO"],
             ["source_reference_id", "YES"],
             ["vault_authorization_epoch", "NO"]
           ]

    assert %{rows: object_columns} =
             query!(
               RequestRepo,
               """
               SELECT column_name, is_nullable
               FROM information_schema.columns
               WHERE table_schema = 'content'
                 AND table_name = 'asset_objects'
                 AND column_name = ANY($1)
               ORDER BY column_name
               """,
               [
                 ~w[
                   delete_claim_token
                   delete_claimed_at
                   deletion_evidence
                   lifecycle_revision
                 ]
               ]
             )

    assert object_columns == [
             ["delete_claim_token", "YES"],
             ["delete_claimed_at", "YES"],
             ["deletion_evidence", "YES"],
             ["lifecycle_revision", "NO"]
           ]

    assert %{rows: constraint_rows} =
             query!(
               RequestRepo,
               """
               SELECT conname
               FROM pg_catalog.pg_constraint
               WHERE conname = ANY($1)
               ORDER BY conname
               """,
               [
                 ~w[
                   asset_objects_cleanup_claim_check
                   asset_objects_lifecycle_revision_check
                   asset_stages_crypto_state_check
                   asset_stages_domain_version_vault_fkey
                   asset_stages_upload_grant_vault_fkey
                 ]
               ]
             )

    assert constraint_rows ==
             ~w[
               asset_objects_cleanup_claim_check
               asset_objects_lifecycle_revision_check
               asset_stages_crypto_state_check
               asset_stages_domain_version_vault_fkey
               asset_stages_upload_grant_vault_fkey
             ]
             |> Enum.map(&[&1])
  end
end
