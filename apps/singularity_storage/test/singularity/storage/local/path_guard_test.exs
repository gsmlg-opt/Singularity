defmodule Singularity.Storage.Local.PathGuardTest do
  use ExUnit.Case, async: true

  alias Singularity.Storage.Local.PathGuard

  @stage_id "019f8012-1234-7abc-8def-1234567890ab"
  @vault_id "019f8012-2345-7abc-8def-1234567890ab"
  @domain_id "019f8012-3456-7abc-8def-1234567890ab"
  @lookup_digest String.duplicate("ab", 32)

  describe "segment validation" do
    test "accepts only canonical UUIDs and lowercase SHA-256 digests" do
      assert {:ok, @stage_id} = PathGuard.uuid(@stage_id)
      assert {:ok, @lookup_digest} = PathGuard.digest(@lookup_digest)
      assert {:ok, @stage_id} = PathGuard.segment(@stage_id)
      assert {:ok, @lookup_digest} = PathGuard.segment(@lookup_digest)
    end

    test "rejects path syntax, user filenames, and malformed digests" do
      invalid_segments = [
        "../escape",
        "..",
        "/absolute",
        "a/b",
        "asset.pdf",
        "bad\\path",
        String.upcase(@stage_id),
        String.upcase(@lookup_digest),
        String.duplicate("a", 63),
        String.duplicate("g", 64),
        :binary.copy(<<0>>, 32)
      ]

      for segment <- invalid_segments do
        assert {:error, %{code: :invalid}} = PathGuard.segment(segment)
      end
    end
  end

  describe "guarded path builders" do
    @tag :tmp_dir
    test "builds server-derived staging and object paths", %{tmp_dir: root} do
      assert {:ok, stage_path} = PathGuard.staging_path(root, @stage_id)
      assert stage_path == Path.join([root, "staging", @stage_id])

      assert {:ok, object_path} =
               PathGuard.object_path(root, @vault_id, @domain_id, @lookup_digest)

      assert object_path ==
               Path.join([
                 root,
                 "objects",
                 @vault_id,
                 @domain_id,
                 "hmac-sha256",
                 "ab",
                 @lookup_digest
               ])

      refute object_path =~ "asset.pdf"
      assert object_path =~ @lookup_digest
    end

    @tag :tmp_dir
    test "rejects invalid namespaces and digests", %{tmp_dir: root} do
      assert {:error, %{code: :invalid}} =
               PathGuard.staging_path(root, "../#{@stage_id}")

      assert {:error, %{code: :invalid}} =
               PathGuard.object_path(root, @vault_id, "domain/path", @lookup_digest)

      assert {:error, %{code: :invalid}} =
               PathGuard.object_path(root, @vault_id, @domain_id, "not-a-digest")
    end

    @tag :tmp_dir
    test "rejects paths outside the root", %{tmp_dir: root} do
      outside = Path.join(Path.dirname(root), "outside")

      assert {:error, %{code: :invalid}} = PathGuard.assert_safe_path(root, outside)
    end

    @tag :tmp_dir
    test "rejects a symlink root", %{tmp_dir: tmp_dir} do
      real_root = Path.join(tmp_dir, "real")
      root = Path.join(tmp_dir, "linked")
      File.mkdir_p!(real_root)
      File.ln_s!(real_root, root)

      assert {:error, %{code: :invalid}} = PathGuard.staging_path(root, @stage_id)
    end

    @tag :tmp_dir
    test "rejects an existing symlink parent", %{tmp_dir: root} do
      outside = Path.join(root, "outside")
      linked_vault = Path.join([root, "objects", @vault_id])
      File.mkdir_p!(Path.dirname(linked_vault))
      File.mkdir_p!(outside)
      File.ln_s!(outside, linked_vault)

      assert {:error, %{code: :invalid}} =
               PathGuard.object_path(root, @vault_id, @domain_id, @lookup_digest)
    end

    @tag :tmp_dir
    test "detects a destination replaced with a symlink", %{tmp_dir: root} do
      File.mkdir_p!(Path.join(root, "staging"))
      outside = Path.join(root, "outside")
      File.write!(outside, "not a stage")

      assert {:ok, stage_path} = PathGuard.staging_path(root, @stage_id)
      File.ln_s!(outside, stage_path)

      assert {:error, %{code: :invalid}} =
               PathGuard.assert_safe_path(root, stage_path)
    end
  end
end
