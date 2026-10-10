defmodule Singularity.Storage.Migrations.KnowledgeRuntimeGrants do
  use Ecto.Migration

  def up do
    execute("SET LOCAL ROLE singularity_table_owner")

    execute(
      "GRANT SELECT, INSERT ON content.note_attachments, content.note_citations, content.tags TO singularity_web"
    )

    execute(
      "GRANT SELECT, INSERT, DELETE ON content.resource_tags, content.relationships TO singularity_web"
    )

    execute("SET LOCAL ROLE NONE")
  end

  def down do
    raise "knowledge runtime grants are forward-only"
  end
end
