defmodule Singularity.Runtime.LegacyUpgradeSourceTest do
  use ExUnit.Case, async: false
  alias Singularity.Runtime.LegacyUpgradeRuntimeFixture

  @root Path.expand("../../fixtures/legacy_v0_1_0", __DIR__)
  @project Path.expand("../../../../..", __DIR__)
  @contract_versions %{
    argon2_elixir: "4.1.3",
    comeonin: "5.5.1",
    db_connection: "2.10.2",
    decimal: "3.1.1",
    ecto: "3.14.2",
    ecto_sql: "3.14.0",
    elixir_make: "0.10.0",
    jason: "1.4.5",
    logger_json: "7.0.4",
    mime: "2.0.7",
    oban: "2.24.0",
    plug: "1.20.3",
    plug_crypto: "2.2.0",
    postgrex: "0.22.4",
    telemetry: "1.4.2",
    telemetry_metrics: "1.2.0",
    telemetry_poller: "1.3.0"
  }

  test "the inert historical corpus has its independent fixed identity" do
    identity = apply(LegacyUpgradeRuntimeFixture, :source_identity!, [])
    assert identity.commit == "c49dc0aeda1d0115b20ff291f0da658f7e558b43"
    assert identity.tree == "f68e1ed5507780db1e3c024e7f387557ac75f23b"

    assert identity.fingerprint ==
             "d7506f511de599dfb92cd2313f843abb27ca26eafd3bf89939ecbf07e2a22924"

    assert length(identity.files) == 253
    assert identity.bytes == 2_135_469
  end

  test "a same-size byte mutation fails the shared source validator" do
    root = Path.expand("../../fixtures/legacy_v0_1_0", __DIR__)
    manifest = root |> Path.join("source.json") |> File.read!() |> Jason.decode!()

    inventory =
      Map.new(manifest["files"], fn file ->
        {file["fixture"], {:regular, File.read!(Path.join(root, file["fixture"]))}}
      end)

    assert LegacyUpgradeRuntimeFixture.validate_source_identity!(manifest, inventory) ==
             LegacyUpgradeRuntimeFixture.source_identity!()

    [file | _] = manifest["files"]
    {:regular, <<first, rest::binary>>} = Map.fetch!(inventory, file["fixture"])
    mutated = <<Bitwise.bxor(first, 1), rest::binary>>
    assert byte_size(mutated) == file["bytes"]
    mutated_inventory = Map.put(inventory, file["fixture"], {:regular, mutated})

    assert_raise ArgumentError, "legacy_source_identity", fn ->
      LegacyUpgradeRuntimeFixture.validate_source_identity!(manifest, mutated_inventory)
    end
  end

  for corruption <-
        ~w(filename path blob sha256 commit tree fingerprint order duplicate omission extra current_replacement symlink missing_file size total schema top_keys entry_keys)a do
    test "#{corruption} corruption fails after a valid source control" do
      {manifest, inventory} = corpus!()
      assert_source_control!(manifest, inventory)

      {changed_manifest, changed_inventory} =
        corrupt_source(unquote(corruption), manifest, inventory)

      assert_raise ArgumentError, "legacy_source_identity", fn ->
        LegacyUpgradeRuntimeFixture.validate_source_identity!(changed_manifest, changed_inventory)
      end

      assert_source_control!(manifest, inventory)
    end
  end

  for location <- [:manifest, :entry] do
    test "duplicate JSON keys in #{location} fail the shared validator" do
      {manifest, inventory} = corpus!()
      assert_source_control!(manifest, inventory)
      json = Jason.encode!(manifest)
      duplicate_json = duplicate_json(json, manifest, unquote(location))
      ordered = Jason.decode!(duplicate_json, objects: :ordered_objects)

      assert_raise ArgumentError, "legacy_source_identity", fn ->
        LegacyUpgradeRuntimeFixture.validate_source_identity!(ordered, inventory)
      end
    end
  end

  test "the fixed external dependency closure accepts synthetic contract observations" do
    {old, current, observations} = dependency_inputs!()
    assert_dependency_control!(old, current, observations)
  end

  for corruption <-
        ~w(old_lock current_pin current_extra missing_pin duplicate_pin executable_lock application_path application_root application_source application_version missing_application extra_application)a do
    test "#{corruption} fails after a valid synthetic dependency control" do
      {old, current, observations} = dependency_inputs!()
      assert_dependency_control!(old, current, observations)

      {changed_old, changed_current, changed_observations} =
        corrupt_dependency(unquote(corruption), old, current, observations)

      assert_raise ArgumentError, "legacy_dependency_identity", fn ->
        LegacyUpgradeRuntimeFixture.validate_dependencies!(
          changed_old,
          changed_current,
          changed_observations
        )
      end

      assert_dependency_control!(old, current, observations)
    end
  end

  defp corpus! do
    manifest = @root |> Path.join("source.json") |> File.read!() |> Jason.decode!()

    inventory =
      Map.new(manifest["files"], fn file ->
        {file["fixture"], {:regular, File.read!(Path.join(@root, file["fixture"]))}}
      end)

    {manifest, inventory}
  end

  defp assert_source_control!(manifest, inventory) do
    assert %{
             commit: "c49dc0aeda1d0115b20ff291f0da658f7e558b43",
             tree: "f68e1ed5507780db1e3c024e7f387557ac75f23b",
             fingerprint: "d7506f511de599dfb92cd2313f843abb27ca26eafd3bf89939ecbf07e2a22924",
             bytes: 2_135_469
           } = LegacyUpgradeRuntimeFixture.validate_source_identity!(manifest, inventory)
  end

  defp corrupt_source(:filename, manifest, inventory) do
    [first | rest] = manifest["files"]
    original = Path.rootname(first["original"]) <> "_renamed.ex"
    fixture = "sources/" <> original <> ".source"
    renamed = %{first | "original" => original, "fixture" => fixture}
    {bytes, remaining} = Map.pop!(inventory, first["fixture"])
    {%{manifest | "files" => [renamed | rest]}, Map.put(remaining, fixture, bytes)}
  end

  defp corrupt_source(:path, manifest, inventory),
    do: {change_first(manifest, "fixture", "sources/../outside.source"), inventory}

  defp corrupt_source(kind, manifest, inventory) when kind in [:blob, :sha256] do
    [first | _] = manifest["files"]
    key = Atom.to_string(kind)
    <<head, rest::binary>> = first[key]
    replacement = if head == ?0, do: ?1, else: ?0
    {change_first(manifest, key, <<replacement, rest::binary>>), inventory}
  end

  defp corrupt_source(kind, manifest, inventory) when kind in [:commit, :tree, :fingerprint] do
    key = Atom.to_string(kind)
    <<head, rest::binary>> = manifest[key]
    replacement = if head == ?0, do: ?1, else: ?0
    {Map.put(manifest, key, <<replacement, rest::binary>>), inventory}
  end

  defp corrupt_source(:order, manifest, inventory) do
    [first, second | rest] = manifest["files"]
    {%{manifest | "files" => [second, first | rest]}, inventory}
  end

  defp corrupt_source(:duplicate, manifest, inventory) do
    [first, _second | rest] = manifest["files"]
    {%{manifest | "files" => [first, first | rest]}, inventory}
  end

  defp corrupt_source(:omission, manifest, inventory) do
    [_first | rest] = manifest["files"]
    {%{manifest | "files" => rest}, inventory}
  end

  defp corrupt_source(:extra, manifest, inventory),
    do: {manifest, Map.put(inventory, "sources/extra.ex.source", {:regular, <<>>})}

  defp corrupt_source(:current_replacement, manifest, inventory) do
    file = Enum.find(manifest["files"], &(&1["original"] == "config/config.exs"))
    current = File.read!(Path.join(@project, file["original"]))
    assert Base.encode16(:crypto.hash(:sha256, current), case: :lower) != file["sha256"]
    {manifest, Map.put(inventory, file["fixture"], {:regular, current})}
  end

  defp corrupt_source(:symlink, manifest, inventory) do
    [first | _] = manifest["files"]
    {manifest, Map.put(inventory, first["fixture"], {:symlink, "/outside/historical.source"})}
  end

  defp corrupt_source(:missing_file, manifest, inventory) do
    [first | _] = manifest["files"]
    {manifest, Map.delete(inventory, first["fixture"])}
  end

  defp corrupt_source(:size, manifest, inventory) do
    [first | _] = manifest["files"]
    {change_first(manifest, "bytes", first["bytes"] + 1), inventory}
  end

  defp corrupt_source(:total, manifest, inventory),
    do: {Map.update!(manifest, "bytes", &(&1 + 1)), inventory}

  defp corrupt_source(:schema, manifest, inventory),
    do: {Map.put(manifest, "schema", 1.0), inventory}

  defp corrupt_source(:top_keys, manifest, inventory),
    do: {Map.put(manifest, "unexpected", true), inventory}

  defp corrupt_source(:entry_keys, manifest, inventory),
    do: {change_first(manifest, "unexpected", true), inventory}

  defp change_first(manifest, key, value) do
    [first | rest] = manifest["files"]
    %{manifest | "files" => [Map.put(first, key, value) | rest]}
  end

  defp duplicate_json(json, _manifest, :manifest),
    do: "{\"schema\":1," <> binary_part(json, 1, byte_size(json) - 1)

  defp duplicate_json(json, manifest, :entry) do
    [first | _] = manifest["files"]
    entry = Jason.encode!(first)

    duplicate =
      "{\"original\":" <>
        Jason.encode!(first["original"]) <>
        "," <>
        binary_part(entry, 1, byte_size(entry) - 1)

    String.replace(json, entry, duplicate, global: false)
  end

  defp dependency_inputs! do
    old = File.read!(Path.join(@root, "sources/mix.lock.source"))
    current = File.read!(Path.join(@project, "mix.lock"))

    # Deliberately synthetic: these observations qualify only the pure validator.
    observations =
      Map.new(@contract_versions, fn {app, version} ->
        {app,
         %{
           version: version,
           source: "/contract/deps/#{app}",
           ebin: "/contract/_build/test/lib/#{app}/ebin"
         }}
      end)

    {old, current, observations}
  end

  defp assert_dependency_control!(old, current, observations) do
    result = LegacyUpgradeRuntimeFixture.validate_dependencies!(old, current, observations)
    assert result.applications == Enum.sort(Map.keys(@contract_versions))
    assert result.library_root == "/contract/_build/test/lib"
    assert result.dependency_root == "/contract/deps"
    assert length(result.ebins) == 17
  end

  defp corrupt_dependency(:old_lock, old, current, observations),
    do: {String.replace(old, "\"2.24.0\"", "\"2.24.1\"", global: false), current, observations}

  defp corrupt_dependency(:current_pin, old, current, observations),
    do: {old, String.replace(current, "\"2.24.0\"", "\"2.24.1\"", global: false), observations}

  defp corrupt_dependency(:current_extra, old, current, observations),
    do: {old, String.replace(current, "\"0.18.0\"", "\"0.18.1\"", global: false), observations}

  defp corrupt_dependency(:missing_pin, old, current, observations),
    do: {old, String.replace(current, ~r/^  "oban":.*\n/m, ""), observations}

  defp corrupt_dependency(:duplicate_pin, old, current, observations) do
    line = current |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "  \"oban\":"))
    {old, String.replace(current, "%{", "%{\n" <> line, global: false), observations}
  end

  defp corrupt_dependency(:executable_lock, old, _current, observations),
    do: {old, "%{ex_cmd: System.get_env(\"PATH\")}", observations}

  defp corrupt_dependency(:application_path, old, current, observations),
    do:
      {old, current,
       put_in(
         observations,
         [:ecto_sql, :ebin],
         "/contract/_build/test/lib/singularity_storage/ebin"
       )}

  defp corrupt_dependency(:application_root, old, current, observations),
    do:
      {old, current,
       put_in(observations, [:ecto_sql, :ebin], "/other/_build/test/lib/ecto_sql/ebin")}

  defp corrupt_dependency(:application_source, old, current, observations),
    do: {old, current, put_in(observations, [:ecto_sql, :source], "/contract/apps/ecto_sql")}

  defp corrupt_dependency(:application_version, old, current, observations),
    do: {old, current, put_in(observations, [:ecto_sql, :version], "0.0.0")}

  defp corrupt_dependency(:missing_application, old, current, observations),
    do: {old, current, Map.delete(observations, :ecto_sql)}

  defp corrupt_dependency(:extra_application, old, current, observations),
    do: {old, current, Map.put(observations, :ex_cmd, observations.ecto_sql)}
end
