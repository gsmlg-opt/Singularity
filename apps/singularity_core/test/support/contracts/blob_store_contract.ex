defmodule Singularity.Core.TestSupport.Contracts.BlobStoreContract do
  @moduledoc false

  defmacro __using__(options) do
    adapter = options |> Keyword.fetch!(:adapter) |> Macro.expand(__CALLER__)

    {:{}, _, [start_module_ast, start_function, start_arguments]} =
      Keyword.fetch!(options, :start_context)

    start_module = Macro.expand(start_module_ast, __CALLER__)

    quote do
      use ExUnit.Case, async: true

      alias Singularity.Core.BlobRef
      alias Singularity.Core.Error
      alias Singularity.Core.Source

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

      test "stores bytes with copied source metadata and fetches them by reference", %{
        context: context
      } do
        bytes = "abc"
        source = blob_source()

        assert {:ok,
                %BlobRef{
                  blob_id: "fake-blob-1",
                  sha256: "sha256-abc",
                  byte_size: 3,
                  media_type: "text/plain",
                  original_filename: "note.txt"
                } = first_ref} = @adapter.put(context, bytes, source)

        assert {:ok, ^bytes} = @adapter.fetch(context, first_ref)

        second_bytes = "de"
        second_source = blob_source(sha256: "sha256-de", byte_size: 2)

        assert {:ok, %BlobRef{blob_id: "fake-blob-2"} = second_ref} =
                 @adapter.put(context, second_bytes, second_source)

        assert {:ok, ^second_bytes} = @adapter.fetch(context, second_ref)
      end

      test "returns not found for a missing blob identity", %{context: context} do
        missing_ref = %BlobRef{blob_id: "missing", sha256: "missing", byte_size: 0}

        assert {:error, %Error{code: :not_found}} = @adapter.fetch(context, missing_ref)
      end

      test "rejects a source byte size that does not match the bytes", %{context: context} do
        source = blob_source(byte_size: 4)

        assert {:error, %Error{code: :invalid}} = @adapter.put(context, "abc", source)
      end

      test "records callback arguments in chronological order", %{context: context} do
        bytes = "abc"
        source = blob_source()

        assert {:ok, %BlobRef{} = blob_ref} = @adapter.put(context, bytes, source)
        assert {:ok, ^bytes} = @adapter.fetch(context, blob_ref)

        assert [
                 {:put, [^bytes, ^source]},
                 {:fetch, [^blob_ref]}
               ] = @adapter.calls(context)
      end

      test "an injected error affects one recorded call and then normal behavior resumes", %{
        context: context
      } do
        injected = %Error{code: :timeout, message: "injected timeout", retryable?: true}
        missing_ref = %BlobRef{blob_id: "missing", sha256: "missing", byte_size: 0}

        assert :ok = @adapter.fail_next(context, injected)
        assert {:error, ^injected} = @adapter.fetch(context, missing_ref)
        assert {:error, %Error{code: :not_found}} = @adapter.fetch(context, missing_ref)

        assert [
                 {:fetch, [^missing_ref]},
                 {:fetch, [^missing_ref]}
               ] = @adapter.calls(context)
      end

      defp blob_source(overrides \\ []) do
        struct!(
          %Source{
            kind: :file,
            sha256: "sha256-abc",
            byte_size: 3,
            media_type: "text/plain",
            original_filename: "note.txt"
          },
          overrides
        )
      end
    end
  end
end
