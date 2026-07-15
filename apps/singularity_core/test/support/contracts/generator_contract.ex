defmodule Singularity.Core.TestSupport.Contracts.GeneratorContract do
  @moduledoc false

  defmacro __using__(options) do
    adapter = options |> Keyword.fetch!(:adapter) |> Macro.expand(__CALLER__)

    {:{}, _, [start_module_ast, start_function, start_arguments]} =
      Keyword.fetch!(options, :start_context)

    start_module = Macro.expand(start_module_ast, __CALLER__)

    quote do
      use ExUnit.Case, async: true

      alias Singularity.Core.Citation
      alias Singularity.Core.Error
      alias Singularity.Core.GenerationEvent
      alias Singularity.Core.GenerationEvidence
      alias Singularity.Core.GenerationRequest
      alias Singularity.Core.GenerationResult
      alias Singularity.Core.KnowledgeChunk

      @adapter unquote(adapter)
      @start_context {
        unquote(start_module),
        unquote(start_function),
        unquote(start_arguments)
      }
      @created_at ~U[2026-07-16 08:00:00Z]

      setup do
        {module, function, arguments} = @start_context
        {:ok, context} = apply(module, function, arguments)
        {:ok, timeline} = Agent.start_link(fn -> [] end)

        on_exit(fn ->
          if Process.alive?(context), do: Agent.stop(context)
          if Process.alive?(timeline), do: Agent.stop(timeline)
        end)

        {:ok, context: context, timeline: timeline}
      end

      test "delivers configured events in order before returning the preserved result", %{
        context: context,
        timeline: timeline
      } do
        request = generation_request()

        sink = fn event ->
          Agent.update(timeline, &(&1 ++ [event]))
          :ok
        end

        expected_result = generation_result()

        assert {:ok, ^expected_result} =
                 @adapter.generate_answer_stream(context, request, sink)

        Agent.update(timeline, &(&1 ++ [:returned]))

        assert [
                 %GenerationEvent{kind: :content, data: "Singularity "},
                 %GenerationEvent{kind: :content, data: "answer."},
                 %GenerationEvent{kind: :usage, data: %{"output_tokens" => 2}},
                 :returned
               ] = Agent.get(timeline, & &1)

        assert [{:generate_answer_stream, [^request, ^sink]}] = @adapter.calls(context)
      end

      test "runs the sink in the adapter caller process and permits adapter re-entry", %{
        context: context,
        timeline: timeline
      } do
        request = generation_request()
        caller = self()

        sink = fn _event ->
          sink_pid = self()
          observed_calls = @adapter.calls(context)
          Agent.update(timeline, &(&1 ++ [{sink_pid, observed_calls}]))
          :ok
        end

        assert {:ok, %GenerationResult{}} =
                 @adapter.generate_answer_stream(context, request, sink)

        expected_calls = [{:generate_answer_stream, [request, sink]}]

        assert [
                 {^caller, ^expected_calls},
                 {^caller, ^expected_calls},
                 {^caller, ^expected_calls}
               ] = Agent.get(timeline, & &1)
      end

      test "one-shot failure emits no event and the next generation call is normal", %{
        context: context,
        timeline: timeline
      } do
        request = generation_request()

        sink = fn event ->
          Agent.update(timeline, &(&1 ++ [event]))
          :ok
        end

        injected = %Error{code: :unavailable, message: "injected failure", retryable?: true}

        assert :ok = @adapter.fail_next(context, injected)
        assert {:error, ^injected} = @adapter.generate_answer_stream(context, request, sink)
        Agent.update(timeline, &(&1 ++ [:failed_returned]))
        assert [:failed_returned] = Agent.get(timeline, & &1)
        Agent.update(timeline, fn _timeline -> [] end)

        assert {:ok, %GenerationResult{} = result} =
                 @adapter.generate_answer_stream(context, request, sink)

        Agent.update(timeline, &(&1 ++ [:returned]))

        assert result == generation_result()

        assert [
                 %GenerationEvent{kind: :content, data: "Singularity "},
                 %GenerationEvent{kind: :content, data: "answer."},
                 %GenerationEvent{kind: :usage, data: %{"output_tokens" => 2}},
                 :returned
               ] = Agent.get(timeline, & &1)

        assert [
                 {:generate_answer_stream, [^request, ^sink]},
                 {:generate_answer_stream, [^request, ^sink]}
               ] = @adapter.calls(context)
      end

      defp generation_request do
        %GenerationRequest{
          question: "What is Singularity?",
          evidence: [%GenerationEvidence{label: 1, chunk: generation_chunk()}],
          prompt_program_version: "prompt-1",
          model_route: "model-route-1",
          metadata: %{"request_id" => "request-1"}
        }
      end

      defp generation_result do
        citation = %Citation{
          item_id: "item-1",
          revision_id: "revision-1",
          chunk_id: "chunk-1",
          label: 1
        }

        %GenerationResult{
          answer: "Singularity answer.",
          citations: [citation],
          usage: %{"output_tokens" => 2},
          provider_response_id: "fake-generation-1"
        }
      end

      defp generation_chunk do
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
        }
      end
    end
  end
end
