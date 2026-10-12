defmodule Singularity.Storage.Migrations.KnowledgeRestoreStorageReferences do
  use Ecto.Migration

  def up do
    execute("SET LOCAL ROLE singularity_table_owner")

    execute("""
    DO $migration$
    DECLARE
      definition text := pg_catalog.pg_get_functiondef(
        'audit.assert_knowledge_restore_graph(uuid)'::pg_catalog.regprocedure);
      -- Exact bytes from the accepted graph definition, including continuation indentation.
      old_predicate constant text := $predicate$o.storage_ref<>'objects/'||o.vault_id::text||'/'||o.key_domain_id::text||'/hmac-sha256/'||
              pg_catalog.substr(pg_catalog.encode(o.lookup_digest,'hex'),1,2)||'/'||pg_catalog.encode(o.lookup_digest,'hex')$predicate$;
    BEGIN
      IF pg_catalog.cardinality(pg_catalog.string_to_array(definition,old_predicate)) IS DISTINCT FROM 2 THEN
        RAISE EXCEPTION 'knowledge restore storage reference predicate mismatch' USING ERRCODE='23514';
      END IF;
      EXECUTE pg_catalog.replace(definition,old_predicate,
        '(o.storage_ref<>o.id::text AND '||old_predicate||')');
    END
    $migration$;
    """)

    execute("SET LOCAL ROLE NONE")
  end

  def down,
    do: raise(Ecto.MigrationError, "knowledge restore storage references are forward-only")
end
