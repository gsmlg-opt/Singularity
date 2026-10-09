defmodule Singularity.Core.SearchPolicyTest do
  use ExUnit.Case, async: true

  test "v1 is a fixed shared ranking and resource-bound policy" do
    assert Code.ensure_loaded?(Singularity.Core.SearchPolicy)

    assert apply(Singularity.Core.SearchPolicy, :current, []) == %{
             version: 1,
             rank_scale: 1_000_000,
             fts_weight: 4,
             title_weight: 2,
             literal_weight: 1,
             title_threshold: 0.3,
             max_rank: 7_000_000,
             query_bytes: 1_024,
             cursor_bytes: 2_048,
             tag_count: 20,
             page_limit: 50,
             snippet_codepoints: 160,
             snippet_bytes: 640,
             statement_timeout_ms: 5_000,
             rebuild_batch_size: 100
           }
  end
end
