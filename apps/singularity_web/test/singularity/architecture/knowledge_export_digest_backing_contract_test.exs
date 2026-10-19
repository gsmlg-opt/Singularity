defmodule Singularity.Web.Architecture.KnowledgeExportDigestBackingContractTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../../../..", __DIR__)
  @old_helper "  defp hex(bytes), do: Base.encode16(bytes, case: :lower)\n"
  @detached_helper "  defp hex(bytes), do: bytes |> Base.encode16(case: :lower) |> :binary.copy()\n"
  @preimages [
    {"apps/singularity_storage/lib/singularity/storage/knowledge_export/spool.ex",
     "2d6dfb4e10b78a4ac27e0e868a6f33326e746c96a309a4d5a833511f63f18556"},
    {"apps/singularity_storage/lib/singularity/storage/knowledge_export/writer.ex",
     "841f3e6b7333e7e94296c8b961353c732cbfddef1cebc8cce15041720e5e80e1"}
  ]

  # These are source-attribution controls, not measurements of binary backing.
  # Actual compiled Spool/Writer family checks, strict64, known-byte hashes and
  # independent portable bytes remain separate required runtime evidence.
  for {file, preimage} <- @preimages do
    @source_path file
    @preimage preimage

    test "#{Path.basename(file)} detaches only its existing generated digest helper" do
      source = File.read!(Path.join(@repo_root, @source_path))
      assert :ok = digest_producer_contract!(source, @preimage)
    end

    test "#{Path.basename(file)} rejects missing duplicate and unrelated changes with the same validator" do
      source = File.read!(Path.join(@repo_root, @source_path))
      assert :ok = digest_producer_contract!(source, @preimage)

      mutants = [
        String.replace(source, @detached_helper, @old_helper, global: false),
        source <> @detached_helper,
        source <> "\n# unrelated source amendment\n"
      ]

      for mutant <- mutants do
        assert :ok = digest_producer_contract!(source, @preimage)
        assert_raise ExUnit.AssertionError, fn -> digest_producer_contract!(mutant, @preimage) end
      end
    end
  end

  defp digest_producer_contract!(source, preimage) do
    assert length(:binary.matches(source, @detached_helper)) == 1,
           "exactly one detached existing digest helper"

    assert :binary.matches(source, @old_helper) == [], "no old helper remains"
    inverse = String.replace(source, @detached_helper, @old_helper, global: false)

    assert Base.encode16(:crypto.hash(:sha256, inverse), case: :lower) == preimage,
           "every other accepted producer source byte remains unchanged"

    :ok
  end
end
