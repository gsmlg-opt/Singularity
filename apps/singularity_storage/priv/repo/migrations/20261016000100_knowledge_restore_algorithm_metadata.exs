defmodule Singularity.Storage.Migrations.KnowledgeRestoreAlgorithmMetadata do
  use Ecto.Migration

  def up do
    execute("SET LOCAL ROLE singularity_table_owner")

    execute("""
    DO $migration$
    DECLARE
      definition text := pg_catalog.pg_get_functiondef(
        'audit.assert_knowledge_restore_graph(uuid)'::pg_catalog.regprocedure);
      old_predicate constant text := $predicate$EXISTS(SELECT 1 FROM core.vault_key_versions WHERE (generation>0 AND state IN ('pending','active','retired') AND algorithm='aes_256_gcm') IS NOT TRUE)$predicate$;
      new_predicate constant text := $predicate$EXISTS(SELECT 1 FROM core.vault_key_versions WHERE (generation>0 AND state IN ('pending','active','retired') AND algorithm IN ('aes_256_gcm','aes-256-gcm')) IS NOT TRUE)$predicate$;
    BEGIN
      IF pg_catalog.cardinality(pg_catalog.string_to_array(definition,old_predicate)) IS DISTINCT FROM 2
        OR pg_catalog.strpos(definition,new_predicate)<>0 THEN
        RAISE EXCEPTION 'knowledge restore algorithm metadata predicate mismatch' USING ERRCODE='23514';
      END IF;
      EXECUTE pg_catalog.replace(definition,old_predicate,new_predicate);
    END
    $migration$;
    """)

    execute("SET LOCAL ROLE NONE")
  end

  def down,
    do: raise(Ecto.MigrationError, "knowledge restore algorithm metadata is forward-only")
end
