defmodule Singularity.Core.TestSupport.Contracts.KnowledgeStoreContract do
  @moduledoc false

  defmacro __using__(options) do
    adapter = options |> Keyword.fetch!(:adapter) |> Macro.expand(__CALLER__)

    {:{}, _, [start_module_ast, start_function, start_arguments]} =
      Keyword.fetch!(options, :start_context)

    start_module = Macro.expand(start_module_ast, __CALLER__)

    quote do
      use ExUnit.Case, async: true

      alias Singularity.Core.AnswerRun
      alias Singularity.Core.Error
      alias Singularity.Core.KnowledgeChunk
      alias Singularity.Core.KnowledgeItem
      alias Singularity.Core.KnowledgeRevision
      alias Singularity.Core.ProjectionState
      alias Singularity.Core.Retrieval.Candidate
      alias Singularity.Core.Retrieval.Filters
      alias Singularity.Core.Retrieval.Result
      alias Singularity.Core.Source
      alias Singularity.Core.Stored

      @adapter unquote(adapter)
      @start_context {
        unquote(start_module),
        unquote(start_function),
        unquote(start_arguments)
      }
      @created_at ~U[2026-07-16 08:00:00Z]
      @updated_at ~U[2026-07-16 08:05:00Z]

      setup do
        {module, function, arguments} = @start_context
        {:ok, context} = apply(module, function, arguments)

        on_exit(fn ->
          if Process.alive?(context), do: Agent.stop(context)
        end)

        {:ok, context: context}
      end

      test "creates and fetches an item with storage version one", %{context: context} do
        revision = knowledge_revision()
        item = knowledge_item()

        assert {:ok, ^revision} = @adapter.create_revision(context, revision)
        assert {:ok, %Stored{value: ^item, version: "1"}} = @adapter.create_item(context, item)

        assert {:ok, %Stored{value: ^item, version: "1"}} =
                 @adapter.fetch_item(context, item.item_id)
      end

      test "replaces the current item version and rejects a stale version", %{context: context} do
        revision = knowledge_revision()
        item = knowledge_item()
        replacement = %{item | title: "Replaced title", updated_at: @updated_at}

        assert {:ok, ^revision} = @adapter.create_revision(context, revision)
        assert {:ok, %Stored{version: "1"}} = @adapter.create_item(context, item)

        assert {:ok, %Stored{value: ^replacement, version: "2"}} =
                 @adapter.replace_item(context, %Stored{value: replacement, version: "1"})

        assert {:error, %Error{code: :conflict}} =
                 @adapter.replace_item(context, %Stored{value: replacement, version: "1"})
      end

      test "validates every revision head during item creation and replacement", %{
        context: context
      } do
        revision = knowledge_revision()

        invalid_item =
          knowledge_item(head_revision_ids: [revision.revision_id, "missing-revision"])

        assert {:ok, ^revision} = @adapter.create_revision(context, revision)
        assert {:error, %Error{code: :invalid}} = @adapter.create_item(context, invalid_item)

        item = knowledge_item()
        assert {:ok, %Stored{version: "1"}} = @adapter.create_item(context, item)

        replacement = %{item | head_revision_ids: ["missing-first", revision.revision_id]}

        assert {:error, %Error{code: :invalid}} =
                 @adapter.replace_item(context, %Stored{value: replacement, version: "1"})
      end

      test "immutable revision retries are idempotent and conflicting duplicates fail", %{
        context: context
      } do
        revision = knowledge_revision()
        conflicting = %{revision | canonical_text: "Different text"}

        assert {:ok, ^revision} = @adapter.create_revision(context, revision)
        assert {:ok, ^revision} = @adapter.create_revision(context, revision)

        assert {:error, %Error{code: :already_exists}} =
                 @adapter.create_revision(context, conflicting)
      end

      test "chunks validate revision identity, use chunk identity, and sort by position", %{
        context: context
      } do
        revision = knowledge_revision()
        later = knowledge_chunk(chunk_id: "chunk-later", position: 2)
        earlier = knowledge_chunk(chunk_id: "chunk-earlier", position: 0)

        assert {:ok, ^revision} = @adapter.create_revision(context, revision)

        assert {:ok, [^earlier, ^later]} =
                 @adapter.put_chunks(context, revision.revision_id, [later, earlier])

        assert {:ok, ^earlier} = @adapter.fetch_chunk(context, earlier.chunk_id)

        assert {:ok, [^earlier, ^later]} =
                 @adapter.list_chunks(context, revision.revision_id)

        mismatched = %{earlier | chunk_id: "wrong-revision", revision_id: "revision-other"}

        assert {:error, %Error{code: :invalid}} =
                 @adapter.put_chunks(context, revision.revision_id, [mismatched])
      end

      test "chunk retries are idempotent and conflicting duplicate IDs fail", %{
        context: context
      } do
        revision = knowledge_revision()
        chunk = knowledge_chunk()
        conflicting = %{chunk | text: "Different chunk text"}

        assert {:ok, ^revision} = @adapter.create_revision(context, revision)
        assert {:ok, [^chunk]} = @adapter.put_chunks(context, revision.revision_id, [chunk])
        assert {:ok, [^chunk]} = @adapter.put_chunks(context, revision.revision_id, [chunk])

        assert {:error, %Error{code: :already_exists}} =
                 @adapter.put_chunks(context, revision.revision_id, [conflicting])
      end

      test "projection state can be replaced and fetched as the latest value", %{
        context: context
      } do
        pending = projection_state()

        ready =
          projection_state(
            status: :ready,
            attempts: 1,
            indexed_at: @updated_at,
            updated_at: @updated_at
          )

        assert {:ok, ^pending} = @adapter.put_projection_state(context, pending)
        assert {:ok, ^ready} = @adapter.put_projection_state(context, ready)

        assert {:ok, ^ready} =
                 @adapter.fetch_projection_state(context, ready.revision_id)
      end

      test "answer runs are fetched terminal records and duplicate IDs fail", %{context: context} do
        run = answer_run()
        conflicting = %{run | answer: "A different terminal answer"}

        assert {:ok, ^run} = @adapter.append_answer_run(context, run)
        assert {:ok, ^run} = @adapter.fetch_answer_run(context, run.run_id)

        assert {:error, %Error{code: :already_exists}} =
                 @adapter.append_answer_run(context, conflicting)
      end

      test "current revision scan deduplicates and sorts non-deleted item heads", %{
        context: context
      } do
        revisions = [
          knowledge_revision(revision_id: "revision-c", item_id: "item-conflicted"),
          knowledge_revision(revision_id: "revision-a", item_id: "item-active"),
          knowledge_revision(revision_id: "revision-b", item_id: "item-conflicted"),
          knowledge_revision(revision_id: "revision-deleted", item_id: "item-deleted")
        ]

        for revision <- revisions do
          assert {:ok, ^revision} = @adapter.create_revision(context, revision)
        end

        active =
          knowledge_item(
            item_id: "item-active",
            head_revision_ids: ["revision-a"],
            status: :active
          )

        conflicted =
          knowledge_item(
            item_id: "item-conflicted",
            head_revision_ids: ["revision-c", "revision-b"],
            status: :conflicted
          )

        duplicate_head =
          knowledge_item(
            item_id: "item-duplicate",
            head_revision_ids: ["revision-a"],
            status: :active
          )

        deleted =
          knowledge_item(
            item_id: "item-deleted",
            head_revision_ids: ["revision-deleted"],
            status: :deleted,
            deleted_at: @updated_at
          )

        for item <- [active, conflicted, duplicate_head, deleted] do
          assert {:ok, %Stored{value: ^item, version: "1"}} =
                   @adapter.create_item(context, item)
        end

        assert {:ok,
                {[
                   %KnowledgeRevision{revision_id: "revision-a"},
                   %KnowledgeRevision{revision_id: "revision-b"},
                   %KnowledgeRevision{revision_id: "revision-c"}
                 ], :done}} = @adapter.scan_current_revisions(context, nil)
      end

      test "identity misses and empty list operations return stable results", %{context: context} do
        assert {:error, %Error{code: :not_found}} = @adapter.fetch_item(context, "missing")
        assert {:error, %Error{code: :not_found}} = @adapter.fetch_revision(context, "missing")
        assert {:error, %Error{code: :not_found}} = @adapter.fetch_chunk(context, "missing")

        assert {:error, %Error{code: :not_found}} =
                 @adapter.fetch_projection_state(context, "missing")

        assert {:error, %Error{code: :not_found}} =
                 @adapter.fetch_answer_run(context, "missing")

        assert {:ok, []} = @adapter.list_revisions(context, "missing")
        assert {:ok, []} = @adapter.list_chunks(context, "missing")
        assert {:ok, {[], :done}} = @adapter.scan_current_revisions(context, nil)
      end

      test "one-shot failures record the attempted call and clear for the next call", %{
        context: context
      } do
        injected = %Error{code: :unavailable, message: "injected failure", retryable?: true}

        assert :ok = @adapter.fail_next(context, injected)
        assert {:error, ^injected} = @adapter.fetch_item(context, "missing")
        assert {:error, %Error{code: :not_found}} = @adapter.fetch_item(context, "missing")

        assert [
                 {:fetch_item, ["missing"]},
                 {:fetch_item, ["missing"]}
               ] = @adapter.calls(context)
      end

      defp knowledge_item(overrides \\ []) do
        struct!(
          %KnowledgeItem{
            item_id: "item-1",
            content_type: :note,
            title: "Representative note",
            head_revision_ids: ["revision-1"],
            status: :active,
            schema_version: 1,
            created_at: @created_at,
            updated_at: @created_at
          },
          overrides
        )
      end

      defp knowledge_revision(overrides \\ []) do
        struct!(
          %KnowledgeRevision{
            revision_id: "revision-1",
            item_id: "item-1",
            parent_revision_ids: [],
            content_type: :note,
            canonical_text: "Knowledge text",
            structured_content: [],
            content_hash: "revision-content-hash",
            source: %Source{kind: :note},
            parser_version: "parser-1",
            normalizer_version: "normalizer-1",
            created_by: :human,
            schema_version: 1,
            created_at: @created_at,
            updated_at: @created_at
          },
          overrides
        )
      end

      defp knowledge_chunk(overrides \\ []) do
        struct!(
          %KnowledgeChunk{
            chunk_id: "chunk-1",
            item_id: "item-1",
            revision_id: "revision-1",
            position: 0,
            heading_path: ["Introduction"],
            text: "Knowledge text",
            start_offset: 0,
            end_offset: 14,
            token_count: 2,
            content_hash: "chunk-content-hash",
            chunker_version: "chunker-1",
            schema_version: 1,
            created_at: @created_at,
            updated_at: @created_at
          },
          overrides
        )
      end

      defp projection_state(overrides \\ []) do
        struct!(
          %ProjectionState{
            revision_id: "revision-1",
            pipeline_version: "pipeline-1",
            embedding_model: "embedding-model-1",
            embedding_dimensions: 2,
            collection_version: "collection-1",
            status: :pending,
            attempts: 0,
            schema_version: 1,
            created_at: @created_at,
            updated_at: @created_at
          },
          overrides
        )
      end

      defp answer_run do
        filters = %Filters{content_types: [:note]}

        retrieval_snapshot = %Result{
          query: "What is Singularity?",
          candidates: [
            %Candidate{
              item_id: "item-1",
              revision_id: "revision-1",
              chunk_id: "chunk-1",
              score: 0.98
            }
          ],
          filters: filters
        }

        %AnswerRun{
          run_id: "run-1",
          question: "What is Singularity?",
          filters: filters,
          retrieval_snapshot: retrieval_snapshot,
          selected_chunk_ids: ["chunk-1"],
          prompt_program_version: "prompt-1",
          model_route: "model-route-1",
          status: :complete,
          answer: "A terminal answer",
          schema_version: 1,
          created_at: @created_at,
          updated_at: @updated_at
        }
      end
    end
  end
end
