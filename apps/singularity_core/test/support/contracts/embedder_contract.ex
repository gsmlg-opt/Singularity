defmodule Singularity.Core.TestSupport.Contracts.EmbedderContract do
  @moduledoc false

  defmacro __using__(options) do
    adapter = options |> Keyword.fetch!(:adapter) |> Macro.expand(__CALLER__)

    {:{}, _, [start_module_ast, start_function, start_arguments]} =
      Keyword.fetch!(options, :start_context)

    start_module = Macro.expand(start_module_ast, __CALLER__)

    quote do
      use ExUnit.Case, async: true

      alias Singularity.Core.Embedding
      alias Singularity.Core.EmbeddingInput
      alias Singularity.Core.Error

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

      test "document embeddings follow input order", %{context: context} do
        input_a = embedding_input(input_id: "doc-a", text: "Document A")
        input_b = embedding_input(input_id: "doc-b", text: "Document B")

        assert {:ok,
                [
                  %Embedding{input_id: "doc-b", vector: [0.3, 0.7]},
                  %Embedding{input_id: "doc-a", vector: [0.1, 0.9]}
                ]} = @adapter.embed_documents(context, [input_b, input_a])

        assert {:ok, []} = @adapter.embed_documents(context, [])
      end

      test "query output keeps the input identity and records all input metadata", %{
        context: context
      } do
        input =
          embedding_input(
            input_id: "query-42",
            text: "What is Singularity?",
            metadata: %{"tenant" => "alpha", "request_id" => "request-7"}
          )

        assert {:ok,
                %Embedding{
                  input_id: "query-42",
                  vector: [0.5, 0.5],
                  model: "embedding-model-1",
                  usage: %{"input_tokens" => 3}
                }} = @adapter.embed_query(context, input)

        assert [{:embed_query, [^input]}] = @adapter.calls(context)
      end

      test "a missing scripted document input returns not found", %{context: context} do
        known = embedding_input(input_id: "doc-a", text: "Document A")
        missing = embedding_input(input_id: "missing", text: "Missing document")

        assert {:error, %Error{code: :not_found}} =
                 @adapter.embed_documents(context, [known, missing])
      end

      test "one-shot failure records the call and then document embedding resumes", %{
        context: context
      } do
        input = embedding_input(input_id: "doc-a", text: "Document A")
        injected = %Error{code: :timeout, message: "injected timeout", retryable?: true}

        assert :ok = @adapter.fail_next(context, injected)
        assert {:error, ^injected} = @adapter.embed_documents(context, [input])

        assert {:ok, [%Embedding{input_id: "doc-a"}]} =
                 @adapter.embed_documents(context, [input])

        assert [
                 {:embed_documents, [[^input]]},
                 {:embed_documents, [[^input]]}
               ] = @adapter.calls(context)
      end

      defp embedding_input(overrides) do
        struct!(
          %EmbeddingInput{input_id: "input-1", text: "Input text"},
          overrides
        )
      end
    end
  end
end
