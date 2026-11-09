defmodule Singularity.Storage.LegacyUpgradeFixturesTest do
  use ExUnit.Case, async: false
  alias Singularity.Storage.LegacyUpgradeFixtures

  test "fixed release migrations are exact before allocation" do
    identity = apply(LegacyUpgradeFixtures, :identity!, [])
    assert identity.commit == "c49dc0aeda1d0115b20ff291f0da658f7e558b43"
    assert identity.tree == "203135f6e35b72aaab269b75a30dcf2ef080bfe3"

    assert identity.fingerprint ==
             "5e3c5b3ad94f294379a00c80136617910c3537fc8a6288266ecc9a53e5f6eb62"

    assert length(identity.files) == 22

    assert List.last(identity.files).filename ==
             "20260818000100_create_private_markdown_notes.exs"
  end

  test "same-size changed bytes are rejected by the positive identity validator" do
    {manifest, inventory} = identity_inputs()

    assert LegacyUpgradeFixtures.validate_identity!(manifest, inventory) ==
             LegacyUpgradeFixtures.identity!()

    [file | _rest] = manifest["files"]
    {:regular, bytes} = Map.fetch!(inventory, file["fixture"])
    <<first, rest::binary>> = bytes
    changed_first = Bitwise.bxor(first, 1)
    changed = <<changed_first, rest::binary>>
    assert byte_size(changed) == byte_size(bytes)
    mutated = Map.put(inventory, file["fixture"], {:regular, changed})

    assert_raise ArgumentError, "legacy_migration_identity", fn ->
      LegacyUpgradeFixtures.validate_identity!(manifest, mutated)
    end
  end

  for corruption <- [
        :filename,
        :original_path,
        :fixture_path,
        :blob,
        :sha256,
        :commit,
        :tree,
        :fingerprint,
        :order,
        :duplicate,
        :omission,
        :extra_inventory,
        :current_replacement,
        :symlink,
        :manifest_fields,
        :file_fields,
        :schema_type,
        :release,
        :total_bytes,
        :file_bytes,
        :short_bytes,
        :nonregular
      ] do
    test "#{corruption} corruption rejects after a valid fixed positive" do
      {manifest, inventory} = identity_inputs()

      assert LegacyUpgradeFixtures.validate_identity!(manifest, inventory) ==
               LegacyUpgradeFixtures.identity!()

      {mutated_manifest, mutated_inventory} =
        corrupt(unquote(corruption), manifest, inventory)

      assert_raise ArgumentError, "legacy_migration_identity", fn ->
        LegacyUpgradeFixtures.validate_identity!(mutated_manifest, mutated_inventory)
      end
    end
  end

  for scope <- [:manifest, :file] do
    test "duplicate JSON keys at #{scope} reject without last-wins decoding" do
      {manifest, inventory} = identity_inputs()
      json = Jason.encode!(manifest)
      ordered = Jason.decode!(json, objects: :ordered_objects)

      assert LegacyUpgradeFixtures.validate_identity!(ordered, inventory) ==
               LegacyUpgradeFixtures.identity!()

      duplicate =
        case unquote(scope) do
          :manifest ->
            String.replace_prefix(json, "{", "{\"schema\":1,")

          :file ->
            [file | _rest] = manifest["files"]

            String.replace(
              json,
              "\"filename\":",
              "\"filename\":" <> Jason.encode!(file["filename"]) <> ",\"filename\":",
              global: false
            )
        end

      duplicate_object = Jason.decode!(duplicate, objects: :ordered_objects)

      assert_raise ArgumentError, "legacy_migration_identity", fn ->
        LegacyUpgradeFixtures.validate_identity!(duplicate_object, inventory)
      end
    end
  end

  defp corrupt(corruption, manifest, inventory) do
    [first | rest] = manifest["files"]

    case corruption do
      :filename ->
        {put_in(manifest, ["files", Access.at(0), "filename"], "20260718000100_renamed.exs"),
         inventory}

      :original_path ->
        {put_in(manifest, ["files", Access.at(0), "original"], "../" <> first["original"]),
         inventory}

      :fixture_path ->
        {put_in(manifest, ["files", Access.at(0), "fixture"], "../" <> first["fixture"]),
         inventory}

      :blob ->
        {put_in(manifest, ["files", Access.at(0), "blob"], String.duplicate("0", 40)), inventory}

      :sha256 ->
        {put_in(manifest, ["files", Access.at(0), "sha256"], String.duplicate("0", 64)),
         inventory}

      :commit ->
        {Map.put(manifest, "commit", String.duplicate("0", 40)), inventory}

      :tree ->
        {Map.put(manifest, "tree", String.duplicate("0", 40)), inventory}

      :fingerprint ->
        {Map.put(manifest, "fingerprint", String.duplicate("0", 64)), inventory}

      :order ->
        {Map.put(manifest, "files", Enum.reverse(manifest["files"])), inventory}

      :duplicate ->
        {Map.put(manifest, "files", [first, first | tl(rest)]), inventory}

      :omission ->
        {Map.put(manifest, "files", rest), inventory}

      :extra_inventory ->
        {manifest, Map.put(inventory, "migrations/unexpected.exs", {:regular, "unexpected"})}

      :current_replacement ->
        current =
          Path.expand(
            "../../../priv/repo/migrations/20260901000200_move_wake_generations_to_job_submissions.exs",
            __DIR__
          )
          |> File.read!()

        {:regular, original} = Map.fetch!(inventory, first["fixture"])
        refute current == original
        {manifest, Map.put(inventory, first["fixture"], {:regular, current})}

      :symlink ->
        {manifest, Map.put(inventory, first["fixture"], {:symlink, first["original"]})}

      :manifest_fields ->
        {Map.put(manifest, "unexpected", true), inventory}

      :file_fields ->
        {update_in(manifest, ["files", Access.at(0)], &Map.put(&1, "unexpected", true)),
         inventory}

      :schema_type ->
        {Map.put(manifest, "schema", 1.0), inventory}

      :release ->
        {Map.put(manifest, "release", "v0.2.0"), inventory}

      :total_bytes ->
        {Map.update!(manifest, "bytes", &(&1 + 1)), inventory}

      :file_bytes ->
        {update_in(manifest, ["files", Access.at(0), "bytes"], &(&1 + 1)), inventory}

      :short_bytes ->
        {:regular, bytes} = Map.fetch!(inventory, first["fixture"])
        shortened = binary_part(bytes, 0, byte_size(bytes) - 1)
        {manifest, Map.put(inventory, first["fixture"], {:regular, shortened})}

      :nonregular ->
        {manifest, Map.put(inventory, first["fixture"], {:directory, []})}
    end
  end

  defp identity_inputs do
    root = Path.expand("../../fixtures/upgrade/v0.1.0", __DIR__)
    manifest = root |> Path.join("source.json") |> File.read!() |> Jason.decode!()

    inventory =
      Map.new(manifest["files"], fn file ->
        {file["fixture"], {:regular, File.read!(Path.join(root, file["fixture"]))}}
      end)

    {manifest, inventory}
  end
end
