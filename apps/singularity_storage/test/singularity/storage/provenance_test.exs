defmodule Singularity.Storage.ProvenanceTest do
  use ExUnit.Case, async: true

  alias Singularity.Storage.Schema.Content.SourceReference

  test "browser provenance has no field capable of storing a client path" do
    assert SourceReference.__schema__(:fields) == [
             :id,
             :vault_id,
             :resource_version_id,
             :principal_id,
             :classification,
             :kind,
             :observed_at,
             :original_filename,
             :declared_media_type,
             :byte_size,
             :idempotency_key_digest,
             :inserted_at
           ]

    refute :client_path in SourceReference.__schema__(:fields)
  end
end
