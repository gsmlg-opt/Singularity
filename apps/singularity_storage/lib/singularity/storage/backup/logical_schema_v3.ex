defmodule Singularity.Storage.Backup.LogicalSchemaV3 do
  @moduledoc """
  Exact version-three logical backup row schemas with appended knowledge history.

  The complete V2 prefix keeps its ordinals, columns and primary keys. Only its
  logical version changes. Column order is wire order; nullable columns alone
  may carry `{"null"}`. Ordinals and primary-key positions are zero-based.
  """

  alias Singularity.Storage.Backup.LogicalSchemaV2

  @version 3
  @table_count 38
  @column_count 367

  @definitions [
    {
      "content.document_versions",
      [
        {"resource_version_id", "uuid", false},
        {"resource_id", "uuid", false},
        {"vault_id", "uuid", false},
        {"classification", "text", false},
        {"source_asset_id", "uuid", false},
        {"source_resource_id", "uuid", false},
        {"source_resource_version_id", "uuid", false},
        {"source_object_id", "uuid", false},
        {"source_digest", "bytes", false},
        {"source_byte_size", "integer", false},
        {"media_type", "text", false},
        {"title", "text", false},
        {"created_by_principal_id", "uuid", false},
        {"state", "text", false},
        {"attempt_generation", "integer", false},
        {"extraction_adapter", "text", true},
        {"extraction_format", "integer", true},
        {"extracted_text_digest", "bytes", true},
        {"detected_language", "text", true},
        {"failure_code", "text", true},
        {"attempt_finished_at", "timestamp", true},
        {"inserted_at", "timestamp", false},
        {"attempt_job_id", "uuid", true},
        {"attempt_started_at", "timestamp", true},
        {"attempt_deadline_at", "timestamp", true}
      ],
      [{0, "uuid"}]
    },
    {
      "content.document_fragments",
      [
        {"id", "text", false},
        {"resource_id", "uuid", false},
        {"resource_version_id", "uuid", false},
        {"vault_id", "uuid", false},
        {"classification", "text", false},
        {"ordinal", "integer", false},
        {"text", "text", false},
        {"digest", "bytes", false},
        {"locator", "json", false},
        {"inserted_at", "timestamp", false}
      ],
      [{0, "text"}]
    },
    {
      "content.document_import_receipts",
      [
        {"vault_id", "uuid", false},
        {"principal_id", "uuid", false},
        {"mutation_id", "uuid", false},
        {"request_fingerprint", "bytes", false},
        {"state", "text", false},
        {"resource_id", "uuid", true},
        {"version_id", "uuid", true},
        {"inserted_at", "timestamp", false}
      ],
      [{0, "uuid"}, {1, "uuid"}, {2, "uuid"}]
    },
    {
      "content.note_attachments",
      [
        {"note_resource_version_id", "uuid", false},
        {"id", "uuid", false},
        {"note_resource_id", "uuid", false},
        {"vault_id", "uuid", false},
        {"classification", "text", false},
        {"target_resource_id", "uuid", false},
        {"target_resource_version_id", "uuid", false},
        {"target_kind", "text", false},
        {"ordinal", "integer", false},
        {"role", "text", false},
        {"label", "text", true},
        {"inserted_at", "timestamp", false}
      ],
      [{0, "uuid"}, {1, "uuid"}]
    },
    {
      "content.note_citations",
      [
        {"note_resource_version_id", "uuid", false},
        {"id", "uuid", false},
        {"note_resource_id", "uuid", false},
        {"vault_id", "uuid", false},
        {"classification", "text", false},
        {"source_resource_id", "uuid", false},
        {"source_resource_version_id", "uuid", false},
        {"fragment_id", "text", false},
        {"locator", "json", false},
        {"ordinal", "integer", false},
        {"inserted_at", "timestamp", false}
      ],
      [{0, "uuid"}, {1, "uuid"}]
    },
    {
      "content.tags",
      [
        {"id", "uuid", false},
        {"vault_id", "uuid", false},
        {"classification", "text", false},
        {"display_value", "text", false},
        {"normalized_key", "text", false},
        {"created_by_principal_id", "uuid", false},
        {"inserted_at", "timestamp", false}
      ],
      [{0, "uuid"}]
    },
    {
      "content.resource_tags",
      [
        {"resource_id", "uuid", false},
        {"tag_id", "uuid", false},
        {"vault_id", "uuid", false},
        {"classification", "text", false},
        {"inserted_at", "timestamp", false}
      ],
      [{0, "uuid"}, {1, "uuid"}, {2, "uuid"}]
    },
    {
      "content.relationships",
      [
        {"id", "uuid", false},
        {"vault_id", "uuid", false},
        {"classification", "text", false},
        {"source_resource_id", "uuid", false},
        {"target_resource_id", "uuid", false},
        {"target_resource_version_id", "uuid", true},
        {"type", "text", false},
        {"created_by_principal_id", "uuid", false},
        {"inserted_at", "timestamp", false}
      ],
      [{0, "uuid"}]
    }
  ]

  @appended_schemas @definitions
                    |> Enum.with_index(30)
                    |> Enum.map(fn {{table, columns, primary_key}, ordinal} ->
                      %{
                        version: @version,
                        ordinal: ordinal,
                        table: table,
                        columns:
                          Enum.map(columns, fn {name, tag, nullable?} ->
                            %{name: name, tag: tag, nullable?: nullable?}
                          end),
                        primary_key:
                          Enum.map(primary_key, fn {position, tag} ->
                            %{position: position, tag: tag}
                          end)
                      }
                    end)

  @schemas Enum.map(LogicalSchemaV2.all(), &Map.put(&1, :version, @version)) ++ @appended_schemas
  @by_table Map.new(@schemas, &{&1.table, &1})
  @by_ordinal Map.new(@schemas, &{&1.ordinal, &1})

  @spec version() :: 3
  def version, do: @version

  @spec all() :: [map()]
  def all, do: @schemas

  @spec tables() :: [binary()]
  def tables, do: Enum.map(@schemas, & &1.table)

  @spec count() :: pos_integer()
  def count, do: @table_count

  @spec column_count() :: pos_integer()
  def column_count, do: @column_count

  @spec fetch_table(term()) :: {:ok, map()} | :error
  def fetch_table(table) when is_binary(table), do: Map.fetch(@by_table, table)
  def fetch_table(_table), do: :error

  @spec fetch_ordinal(term()) :: {:ok, map()} | :error
  def fetch_ordinal(ordinal) when is_integer(ordinal), do: Map.fetch(@by_ordinal, ordinal)
  def fetch_ordinal(_ordinal), do: :error
end
