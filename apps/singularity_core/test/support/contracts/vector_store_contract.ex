defmodule Singularity.Core.TestSupport.Contracts.VectorStoreContract do
  @moduledoc false

  defmacro __using__(options) do
    adapter = options |> Keyword.fetch!(:adapter) |> Macro.expand(__CALLER__)

    {:{}, _, [start_module_ast, start_function, start_arguments]} =
      Keyword.fetch!(options, :start_context)

    start_module = Macro.expand(start_module_ast, __CALLER__)

    quote do
      use ExUnit.Case, async: true

      alias Singularity.Core.CollectionSpec
      alias Singularity.Core.Error
      alias Singularity.Core.Retrieval.Filters
      alias Singularity.Core.VectorMatch
      alias Singularity.Core.VectorPoint

      @adapter unquote(adapter)
      @start_context {
        unquote(start_module),
        unquote(start_function),
        unquote(start_arguments)
      }

      setup do
        {module, function, arguments} = @start_context
        {:ok, context} = apply(module, function, arguments)

        on_exit(fn ->
          if Process.alive?(context), do: Agent.stop(context)
        end)

        {:ok, context: context}
      end

      test "creates, fetches, and idempotently ensures an identical collection", %{
        context: context
      } do
        spec = collection_spec()

        assert {:ok, ^spec} = @adapter.ensure_collection(context, spec)
        assert {:ok, ^spec} = @adapter.fetch_collection(context, spec.name)
        assert {:ok, ^spec} = @adapter.ensure_collection(context, spec)
      end

      test "rejects an incompatible collection with the same name", %{context: context} do
        spec = collection_spec()
        incompatible = %{spec | dimensions: spec.dimensions + 1}

        assert {:ok, ^spec} = @adapter.ensure_collection(context, spec)

        assert {:error, %Error{code: :conflict}} =
                 @adapter.ensure_collection(context, incompatible)
      end

      test "upsert replaces a point by identity without growing the collection", %{
        context: context
      } do
        spec = collection_spec()
        original = vector_point(point_id: "point-a", payload: %{"version" => 1})
        replacement = %{original | vector: [0.9, 0.1], payload: %{"version" => 2}}

        assert {:ok, ^spec} = @adapter.ensure_collection(context, spec)
        assert {:ok, ["point-a"]} = @adapter.upsert_points(context, spec.name, [original])
        assert {:ok, ["point-a"]} = @adapter.upsert_points(context, spec.name, [replacement])
        assert {:ok, [^replacement]} = @adapter.fetch_points(context, spec.name, ["point-a"])
        assert {:ok, {[^replacement], :done}} = @adapter.scroll(context, spec.name, nil)
      end

      test "fetch preserves requested identity order and omits missing points", %{
        context: context
      } do
        spec = collection_spec()
        point_a = vector_point(point_id: "point-a")
        point_b = vector_point(point_id: "point-b", vector: [0.75, 0.25])

        assert {:ok, ^spec} = @adapter.ensure_collection(context, spec)

        assert {:ok, ["point-a", "point-b"]} =
                 @adapter.upsert_points(context, spec.name, [point_a, point_b])

        assert {:ok, [^point_b, ^point_a]} =
                 @adapter.fetch_points(context, spec.name, ["point-b", "missing", "point-a"])

        assert {:ok, []} = @adapter.upsert_points(context, spec.name, [])
        assert {:ok, []} = @adapter.fetch_points(context, spec.name, [])
      end

      test "deletes point identities from a collection", %{context: context} do
        spec = collection_spec()
        point_a = vector_point(point_id: "point-a")
        point_b = vector_point(point_id: "point-b")

        assert {:ok, ^spec} = @adapter.ensure_collection(context, spec)

        assert {:ok, ["point-a", "point-b"]} =
                 @adapter.upsert_points(context, spec.name, [point_a, point_b])

        assert {:ok, :ok} = @adapter.delete_points(context, spec.name, ["point-a", "missing"])

        assert {:ok, [^point_b]} =
                 @adapter.fetch_points(context, spec.name, ["point-a", "point-b"])

        assert {:ok, :ok} = @adapter.delete_points(context, spec.name, [])
      end

      test "returns scripted search matches by score and point identity", %{context: context} do
        spec = collection_spec()

        assert {:ok, ^spec} = @adapter.ensure_collection(context, spec)

        assert {:ok,
                [
                  %VectorMatch{point_id: "point-a", score: 0.9},
                  %VectorMatch{point_id: "point-c", score: 0.9},
                  %VectorMatch{point_id: "point-b", score: 0.8}
                ]} = @adapter.search(context, spec.name, [0.5, 0.5], %Filters{}, 3, [])

        assert {:ok,
                [
                  %VectorMatch{point_id: "point-a", score: 0.9},
                  %VectorMatch{point_id: "point-c", score: 0.9}
                ]} = @adapter.search(context, spec.name, [0.5, 0.5], %Filters{}, 2, [])
      end

      test "scrolls points in ascending point identity order with a done cursor", %{
        context: context
      } do
        spec = collection_spec()
        point_c = vector_point(point_id: "point-c")
        point_a = vector_point(point_id: "point-a")
        point_b = vector_point(point_id: "point-b")

        assert {:ok, ^spec} = @adapter.ensure_collection(context, spec)

        assert {:ok, ["point-c", "point-a", "point-b"]} =
                 @adapter.upsert_points(context, spec.name, [point_c, point_a, point_b])

        assert {:ok, {[^point_a, ^point_b, ^point_c], :done}} =
                 @adapter.scroll(context, spec.name, nil)
      end

      test "collection namespaces isolate points and scripted results", %{context: context} do
        primary = collection_spec()
        archive = collection_spec(name: "archive-v1", collection_version: "archive-1")
        primary_point = vector_point(point_id: "shared", payload: %{"collection" => "primary"})
        archive_point = vector_point(point_id: "shared", payload: %{"collection" => "archive"})

        assert {:ok, ^primary} = @adapter.ensure_collection(context, primary)
        assert {:ok, ^archive} = @adapter.ensure_collection(context, archive)

        assert {:ok, ["shared"]} =
                 @adapter.upsert_points(context, primary.name, [primary_point])

        assert {:ok, ["shared"]} =
                 @adapter.upsert_points(context, archive.name, [archive_point])

        assert {:ok, [^primary_point]} =
                 @adapter.fetch_points(context, primary.name, ["shared"])

        assert {:ok, [^archive_point]} =
                 @adapter.fetch_points(context, archive.name, ["shared"])

        assert {:ok, [%VectorMatch{point_id: "point-a"} | _]} =
                 @adapter.search(context, primary.name, [0.5, 0.5], %Filters{}, 3, [])

        assert {:ok, [%VectorMatch{point_id: "archive-point"}]} =
                 @adapter.search(context, archive.name, [0.5, 0.5], %Filters{}, 3, [])
      end

      test "missing collection operations return not found", %{context: context} do
        point = vector_point()

        assert {:error, %Error{code: :not_found}} =
                 @adapter.fetch_collection(context, "missing")

        assert {:error, %Error{code: :not_found}} =
                 @adapter.upsert_points(context, "missing", [point])

        assert {:error, %Error{code: :not_found}} =
                 @adapter.fetch_points(context, "missing", [point.point_id])

        assert {:error, %Error{code: :not_found}} =
                 @adapter.delete_points(context, "missing", [point.point_id])

        assert {:error, %Error{code: :not_found}} =
                 @adapter.search(context, "missing", [0.5, 0.5], %Filters{}, 1, [])

        assert {:error, %Error{code: :not_found}} = @adapter.scroll(context, "missing", nil)
      end

      test "one-shot failure records the attempted call before normal behavior resumes", %{
        context: context
      } do
        spec = collection_spec()
        injected = %Error{code: :unavailable, message: "injected failure", retryable?: true}

        assert {:ok, ^spec} = @adapter.ensure_collection(context, spec)
        assert :ok = @adapter.fail_next(context, injected)
        assert {:error, ^injected} = @adapter.fetch_collection(context, spec.name)
        assert {:ok, ^spec} = @adapter.fetch_collection(context, spec.name)

        assert [
                 {:ensure_collection, [^spec]},
                 {:fetch_collection, [name]},
                 {:fetch_collection, [name]}
               ] = @adapter.calls(context)

        assert name == spec.name
      end

      defp collection_spec(overrides \\ []) do
        struct!(
          %CollectionSpec{
            name: "knowledge-v1",
            dimensions: 2,
            distance: :cosine,
            embedding_model: "embedding-model-1",
            collection_version: "collection-1"
          },
          overrides
        )
      end

      defp vector_point(overrides \\ []) do
        struct!(
          %VectorPoint{
            point_id: "point-1",
            vector: [0.25, 0.75],
            payload: %{"chunk_id" => "chunk-1"}
          },
          overrides
        )
      end
    end
  end
end
