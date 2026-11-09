defmodule Singularity.Runtime.LegacyUpgradeRuntimeFixture do
  @moduledoc false

  @root Path.expand("../fixtures/legacy_v0_1_0", __DIR__)
  @commit "c49dc0aeda1d0115b20ff291f0da658f7e558b43"
  @tree "f68e1ed5507780db1e3c024e7f387557ac75f23b"
  @fingerprint "d7506f511de599dfb92cd2313f843abb27ca26eafd3bf89939ecbf07e2a22924"
  @bytes 2_135_469
  @top_keys ~w(schema release commit tree fingerprint bytes files)
  @file_keys ~w(original fixture blob sha256 bytes)
  @lock_sha256 "ae235b7777083e3ac9912aa73ee13d9fc0fc2eb2bef34d3685d61b7260b60dae"
  @external_roots ~w(ecto_sql postgrex oban argon2_elixir logger_json telemetry_metrics telemetry_poller)a
  @ex_cmd_lock {:hex, :ex_cmd, "0.18.0",
                "791b42b864c099b67254ca909243e2f60a6e091c802f608d4ae2e3da27b0ade9", [:mix], [],
                "hexpm", "fd4ec30607a7c789cd53b5fb09189bd0a4922eae5b4fadf70176c19bcd19fb76"}
  @prefix_counts %{
    "apps/singularity_core/lib/singularity/" => 38,
    "apps/singularity_domains/lib/singularity/" => 10,
    "apps/singularity_storage/lib/singularity/" => 105,
    "apps/singularity_ingest/lib/singularity/" => 8,
    "apps/singularity_retrieval/lib/singularity/" => 7,
    "apps/singularity_runtime/lib/singularity/" => 83
  }

  def source_identity! do
    identity_boundary(fn ->
      Enum.each(ancestors(@root), &require_directory!/1)
      names = File.ls!(@root)
      require!(Enum.sort(names -- ["runner.exs"]) == ["source.json", "sources"])
      require_regular!(Path.join(@root, "source.json"))
      if "runner.exs" in names, do: require_regular!(Path.join(@root, "runner.exs"))
      require_directory!(Path.join(@root, "sources"))

      manifest =
        @root
        |> Path.join("source.json")
        |> File.read!()
        |> Jason.decode!(objects: :ordered_objects)

      {inventory, directories} = read_sources!("sources")
      identity = validate_source_identity!(manifest, inventory)
      require!(MapSet.new(directories) == source_directories(identity.files))
      identity
    end)
  end

  def validate_source_identity!(manifest, inventory) do
    identity_boundary(fn ->
      manifest = plain_json!(manifest)
      require!(is_map(manifest) and not is_struct(manifest))
      require!(Enum.sort(Map.keys(manifest)) == Enum.sort(@top_keys))
      require!(manifest["schema"] === 1 and manifest["release"] == "v0.1.0")
      require!(manifest["commit"] == @commit and manifest["tree"] == @tree)
      require!(manifest["fingerprint"] == @fingerprint and manifest["bytes"] === @bytes)
      files = manifest["files"]
      require!(is_list(files) and length(files) == 253)
      Enum.each(files, &validate_entry!/1)

      originals = Enum.map(files, & &1["original"])
      require!(originals == Enum.sort(originals))
      require!(length(Enum.uniq(originals)) == 253)

      require!(
        Enum.filter(originals, &(&1 in ["config/config.exs", "mix.lock"])) ==
          ["config/config.exs", "mix.lock"]
      )

      Enum.each(@prefix_counts, fn {prefix, count} ->
        require!(Enum.count(originals, &String.starts_with?(&1, prefix)) == count)
      end)

      fingerprint =
        files
        |> Enum.map(fn file ->
          [file["original"], "\t", file["blob"], "\t", file["sha256"], "\n"]
        end)
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)

      require!(fingerprint == @fingerprint)
      require!(is_map(inventory) and not is_struct(inventory))
      require!(Enum.sort(Map.keys(inventory)) == Enum.sort(Enum.map(files, & &1["fixture"])))

      Enum.each(files, fn file ->
        case Map.fetch!(inventory, file["fixture"]) do
          {:regular, bytes} when is_binary(bytes) ->
            require!(byte_size(bytes) == file["bytes"])
            require!(digest(:sha256, bytes) == file["sha256"])

            require!(
              digest(:sha, ["blob ", Integer.to_string(byte_size(bytes)), <<0>>, bytes]) ==
                file["blob"]
            )

          _ ->
            invalid!()
        end
      end)

      require!(Enum.sum(Enum.map(files, & &1["bytes"])) == @bytes)

      %{
        commit: @commit,
        tree: @tree,
        fingerprint: @fingerprint,
        bytes: @bytes,
        files:
          Enum.map(files, fn file ->
            %{
              original: file["original"],
              fixture: file["fixture"],
              blob: file["blob"],
              sha256: file["sha256"],
              bytes: file["bytes"]
            }
          end)
      }
    end)
  end

  # These are pure observations, not proof that a child loaded these applications.
  # The historical child must acquire and verify the actual paths before use.
  def validate_dependencies!(old_lock, current_lock, application_observations) do
    try do
      require!(is_binary(old_lock) and digest(:sha256, old_lock) == @lock_sha256)
      old = literal_lock!(old_lock)
      current = literal_lock!(current_lock)
      require!(Map.delete(current, :ex_cmd) == old)
      require!(Map.fetch!(current, :ex_cmd) == @ex_cmd_lock)
      applications = dependency_closure(@external_roots, old, MapSet.new()) |> Enum.sort()
      require!(is_map(application_observations) and not is_struct(application_observations))
      require!(Enum.sort(Map.keys(application_observations)) == applications)

      roots =
        Enum.map(applications, fn app ->
          observation = Map.fetch!(application_observations, app)
          require!(is_map(observation) and not is_struct(observation))
          require!(Enum.sort(Map.keys(observation)) == [:ebin, :source, :version])
          {:hex, ^app, version, _, _, _, _, _} = Map.fetch!(old, app)
          require!(observation.version == version)

          require!(
            absolute_canonical?(observation.ebin) and absolute_canonical?(observation.source)
          )

          require!(Path.basename(observation.ebin) == "ebin")
          require!(Path.basename(Path.dirname(observation.ebin)) == Atom.to_string(app))
          require!(Path.basename(observation.source) == Atom.to_string(app))
          library_root = observation.ebin |> Path.dirname() |> Path.dirname()
          dependency_root = Path.dirname(observation.source)
          require!(Path.basename(library_root) == "lib")
          require!(Path.basename(dependency_root) == "deps")
          {library_root, dependency_root}
        end)

      [{library_root, dependency_root}] = Enum.uniq(roots)

      %{
        applications: applications,
        library_root: library_root,
        dependency_root: dependency_root,
        ebins: Enum.map(applications, &Map.fetch!(application_observations, &1).ebin)
      }
    rescue
      _ -> raise ArgumentError, "legacy_dependency_identity"
    end
  end

  # Pure framing/schema checks only. They do not establish native child custody,
  # EOF/exit, filesystem origin, database provenance or actual population.
  def encode_configuration!(configuration) do
    try do
      configuration = protocol_value!(configuration)

      exact_keys!(
        configuration,
        ~w(protocol source_fingerprint database database_oid object_root build_root repositories credentials originals)
      )

      require!(configuration["protocol"] === 1)
      require!(configuration["source_fingerprint"] == @fingerprint)
      database = configuration["database"]

      require!(
        is_binary(database) and Regex.match?(~r/\Asingularity_test_[0-9a-f]{24}\z/, database)
      )

      require!(
        is_integer(configuration["database_oid"]) and
          configuration["database_oid"] in 1..4_294_967_295
      )

      object_root = configuration["object_root"]
      build_root = configuration["build_root"]
      protocol_path!(object_root)
      protocol_path!(build_root)
      require!(object_root != build_root)
      require!(not String.starts_with?(build_root, object_root <> "/"))
      require!(not String.starts_with?(object_root, build_root <> "/"))

      roles = %{
        "migration" => "singularity_migration",
        "request" => "singularity_web",
        "pre_auth" => "singularity_pre_auth",
        "dispatcher" => "singularity_dispatcher",
        "worker" => "singularity_worker"
      }

      repositories = configuration["repositories"]
      exact_keys!(repositories, Map.keys(roles))

      Enum.each(roles, fn {name, role} ->
        connection = repositories[name]
        exact_keys!(connection, ~w(database username socket_dir port))
        require!(connection["database"] == database and connection["username"] == role)
        protocol_path!(connection["socket_dir"])
        require!(is_integer(connection["port"]) and connection["port"] in 1..65_535)
      end)

      credentials = configuration["credentials"]
      exact_keys!(credentials, ~w(login password))
      Enum.each(Map.values(credentials), &protocol_text!/1)
      originals = configuration["originals"]
      exact_keys!(originals, ~w(text_pdf_base64 binary_png_base64 deleted_png_base64))

      [pdf, png, deleted] =
        Enum.map(~w(text_pdf_base64 binary_png_base64 deleted_png_base64), fn name ->
          encoded = originals[name]
          require!(is_binary(encoded))
          {:ok, bytes} = Base.decode64(encoded)
          require!(Base.encode64(bytes) == encoded and byte_size(bytes) in 1..1_024)
          bytes
        end)

      require!(String.starts_with?(pdf, "%PDF-") and byte_size(pdf) >= 9)
      require!(Enum.all?(:binary.bin_to_list(pdf), &(&1 < 128)))
      png_magic = <<137, 80, 78, 71, 13, 10, 26, 10>>
      require!(String.starts_with?(png, png_magic) and byte_size(png) >= 33)
      require!(String.starts_with?(deleted, png_magic) and byte_size(deleted) >= 33)
      require!(length(Enum.uniq([pdf, png, deleted])) == 3)
      payload = Jason.encode!(configuration)
      require!(byte_size(payload) <= 16_384)
      <<byte_size(payload)::unsigned-big-integer-size(32), payload::binary>>
    rescue
      _ -> raise ArgumentError, "legacy_configuration"
    catch
      _, _ -> raise ArgumentError, "legacy_configuration"
    end
  end

  def decode_receipt!(bytes) do
    cond do
      not is_binary(bytes) -> {:error, :legacy_protocol}
      byte_size(bytes) > 65_540 -> {:error, :legacy_output_limit}
      true -> decode_receipt_frame(bytes)
    end
  end

  defp decode_receipt_frame(<<length::unsigned-big-integer-size(32), _body::binary>>)
       when length > 65_536,
       do: {:error, :legacy_output_limit}

  defp decode_receipt_frame(<<length::unsigned-big-integer-size(32), body::binary>>)
       when byte_size(body) == length do
    try do
      require!(String.valid?(body))
      receipt = body |> Jason.decode!(objects: :ordered_objects) |> protocol_value!()
      validate_receipt!(receipt)
      {:ok, receipt}
    rescue
      _ -> {:error, :legacy_protocol}
    catch
      _, _ -> {:error, :legacy_protocol}
    end
  end

  defp decode_receipt_frame(_), do: {:error, :legacy_protocol}

  defp validate_receipt!(receipt) do
    exact_keys!(receipt, ~w(protocol source_fingerprint owner notes assets work))
    require!(receipt["protocol"] === 1 and receipt["source_fingerprint"] == @fingerprint)
    owner = receipt["owner"]
    uuid_fields!(owner, ~w(account_id credential_id principal_id vault_id))

    require!(
      owner["account_id"] == owner["principal_id"] and owner["account_id"] == owner["vault_id"]
    )

    require!(owner["credential_id"] != owner["account_id"])
    notes = receipt["notes"]
    exact_keys!(notes, ~w(open_conflict resolved_conflict tombstoned))
    open = notes["open_conflict"]
    resolved = notes["resolved_conflict"]
    tombstoned = notes["tombstoned"]

    conflict_ids =
      ~w(resource_id initial_version_id accepted_version_id competing_version_id conflict_id)

    uuid_fields!(open, conflict_ids, ~w(conflict_state))
    uuid_fields!(resolved, conflict_ids ++ ~w(merge_version_id), ~w(conflict_state))
    uuid_fields!(tombstoned, ~w(resource_id initial_version_id accepted_version_id), ~w(state))
    require!(open["conflict_state"] == "open" and resolved["conflict_state"] == "resolved")
    require!(tombstoned["state"] == "tombstoned")
    unique_values!(Map.values(notes), "resource_id")
    distinct_fields!(open, ~w(initial_version_id accepted_version_id competing_version_id))

    distinct_fields!(
      resolved,
      ~w(initial_version_id accepted_version_id competing_version_id merge_version_id)
    )

    distinct_fields!(tombstoned, ~w(initial_version_id accepted_version_id))

    assets = receipt["assets"]
    exact_keys!(assets, ~w(text_pdf binary_png deleted_png))

    Enum.each(assets, fn {name, asset} ->
      uuid_fields!(
        asset,
        ~w(asset_id resource_id resource_version_id object_id),
        ~w(sha256 bytes state object_lifecycle)
      )

      require!(is_binary(asset["sha256"]) and Regex.match?(~r/\A[0-9a-f]{64}\z/, asset["sha256"]))
      require!(is_integer(asset["bytes"]) and asset["bytes"] in 1..1_024)

      if name == "deleted_png" do
        require!(asset["state"] == "deleted" and asset["object_lifecycle"] == "orphan_pending")
      else
        require!(asset["state"] == "ready" and asset["object_lifecycle"] == "available")
      end
    end)

    Enum.each(
      ~w(asset_id resource_id resource_version_id object_id sha256),
      &unique_values!(Map.values(assets), &1)
    )

    work = receipt["work"]
    exact_keys!(work, ~w(native_name_encoding completed pending_object_cleanup))
    require!(work["native_name_encoding"] == "utf8")
    completed = work["completed"]
    require!(is_list(completed) and completed != [])

    Enum.each(completed, fn entry ->
      uuid_fields!(
        entry,
        ~w(event_id submission_id progress_id effect_id),
        ~w(runner_job_id job_type)
      )

      require!(entry["job_type"] == "asset_metadata")
      require!(entry["event_id"] == entry["submission_id"])
      runner_id!(entry["runner_job_id"])
    end)

    pending = work["pending_object_cleanup"]
    uuid_fields!(pending, ~w(event_id submission_id), ~w(runner_job_id))
    require!(pending["event_id"] == pending["submission_id"])
    runner_id!(pending["runner_job_id"])

    Enum.each(
      ~w(event_id submission_id runner_job_id),
      &unique_values!([pending | completed], &1)
    )

    Enum.each(~w(progress_id effect_id), &unique_values!(completed, &1))
  end

  defp exact_keys!(map, keys) do
    require!(is_map(map) and not is_struct(map))
    require!(Enum.sort(Map.keys(map)) == Enum.sort(keys))
  end

  defp uuid_fields!(map, ids, other_keys \\ []) do
    exact_keys!(map, ids ++ other_keys)

    Enum.each(ids, fn key ->
      value = map[key]

      require!(
        is_binary(value) and
          Regex.match?(
            ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/,
            value
          )
      )

      require!(value != "00000000-0000-0000-0000-000000000000")
    end)
  end

  defp distinct_fields!(map, fields) do
    values = Enum.map(fields, &Map.fetch!(map, &1))
    require!(length(Enum.uniq(values)) == length(values))
  end

  defp unique_values!(maps, key) do
    values = Enum.map(maps, &Map.fetch!(&1, key))
    require!(length(Enum.uniq(values)) == length(values))
  end

  defp runner_id!(value) do
    require!(is_binary(value) and Regex.match?(~r/\A[1-9][0-9]{0,18}\z/, value))
    require!(String.to_integer(value) <= 9_223_372_036_854_775_807)
  end

  defp protocol_text!(value),
    do:
      require!(
        is_binary(value) and value != "" and String.valid?(value) and
          not String.contains?(value, <<0>>)
      )

  defp protocol_path!(value) do
    protocol_text!(value)
    require!(absolute_canonical?(value) and value != "/")
  end

  defp protocol_value!(%Jason.OrderedObject{values: fields}) do
    keys = Enum.map(fields, &elem(&1, 0))
    require!(length(Enum.uniq(keys)) == length(keys))
    Map.new(fields, fn {key, value} -> {key, protocol_value!(value)} end)
  end

  defp protocol_value!(value) when is_map(value) do
    require!(not is_struct(value))
    Map.new(value, fn {key, nested} -> {key, protocol_value!(nested)} end)
  end

  defp protocol_value!(value) when is_list(value), do: Enum.map(value, &protocol_value!/1)
  defp protocol_value!(value), do: value

  defp literal_lock!(bytes) when is_binary(bytes) do
    {:%{}, _, fields} = Code.string_to_quoted!(bytes)
    keys = Enum.map(fields, &elem(&1, 0))
    require!(Enum.all?(keys, &is_atom/1) and length(Enum.uniq(keys)) == length(keys))
    Map.new(fields, fn {key, value} -> {key, literal!(value)} end)
  end

  defp literal!({:{}, _, values}), do: values |> Enum.map(&literal!/1) |> List.to_tuple()
  defp literal!({key, value}), do: {literal!(key), literal!(value)}
  defp literal!(values) when is_list(values), do: Enum.map(values, &literal!/1)
  defp literal!(value) when is_atom(value) or is_binary(value) or is_number(value), do: value
  defp literal!(_), do: invalid!()

  defp dependency_closure([], _lock, visited), do: visited

  defp dependency_closure([app | remaining], lock, visited) do
    if MapSet.member?(visited, app) do
      dependency_closure(remaining, lock, visited)
    else
      {:hex, ^app, _, _, _, dependencies, _, _} = Map.fetch!(lock, app)

      selected =
        for {dependency, _, _} <- dependencies,
            Map.has_key?(lock, dependency),
            do: dependency

      dependency_closure(selected ++ remaining, lock, MapSet.put(visited, app))
    end
  end

  defp absolute_canonical?(path) do
    is_binary(path) and not String.contains?(path, <<0>>) and
      Path.type(path) == :absolute and Path.expand(path) == path
  end

  defp digest(algorithm, bytes),
    do: algorithm |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

  defp validate_entry!(file) do
    require!(is_map(file) and not is_struct(file))
    require!(Enum.sort(Map.keys(file)) == Enum.sort(@file_keys))
    original = file["original"]
    require!(is_binary(original) and Regex.match?(~r/\A[a-z0-9_\/.]+\z/, original))
    require!(Enum.all?(String.split(original, "/"), &(&1 not in ["", ".", ".."])))

    require!(
      original in ["config/config.exs", "mix.lock"] or
        (String.ends_with?(original, ".ex") and
           Enum.any?(Map.keys(@prefix_counts), &String.starts_with?(original, &1)))
    )

    require!(file["fixture"] == "sources/" <> original <> ".source")
    require!(is_binary(file["blob"]) and Regex.match?(~r/\A[0-9a-f]{40}\z/, file["blob"]))
    require!(is_binary(file["sha256"]) and Regex.match?(~r/\A[0-9a-f]{64}\z/, file["sha256"]))
    require!(is_integer(file["bytes"]) and file["bytes"] >= 0)
  end

  defp plain_json!(%Jason.OrderedObject{values: fields}) do
    keys = Enum.map(fields, &elem(&1, 0))
    require!(length(Enum.uniq(keys)) == length(keys))
    Map.new(fields, fn {key, value} -> {key, plain_json!(value)} end)
  end

  defp plain_json!(values) when is_list(values), do: Enum.map(values, &plain_json!/1)
  defp plain_json!(value), do: value

  defp read_sources!(relative) do
    require_directory!(Path.join(@root, relative))

    Enum.reduce(File.ls!(Path.join(@root, relative)), {%{}, [relative]}, fn name,
                                                                            {files, directories} ->
      child = relative <> "/" <> name
      path = Path.join(@root, child)

      case File.lstat!(path).type do
        :directory ->
          {nested_files, nested_directories} = read_sources!(child)
          {Map.merge(files, nested_files), directories ++ nested_directories}

        :regular ->
          {Map.put(files, child, {:regular, File.read!(path)}), directories}

        :symlink ->
          {Map.put(files, child, {:symlink, File.read_link!(path)}), directories}

        _ ->
          invalid!()
      end
    end)
  end

  defp source_directories(files) do
    files
    |> Enum.flat_map(fn file ->
      file.fixture |> Path.dirname() |> ancestors() |> Enum.reject(&(&1 == "."))
    end)
    |> MapSet.new()
  end

  defp ancestors(path) when path in ["/", "."], do: [path]
  defp ancestors(path), do: ancestors(Path.dirname(path)) ++ [path]

  defp require_directory!(path), do: require!(File.lstat!(path).type == :directory)
  defp require_regular!(path), do: require!(File.lstat!(path).type == :regular)

  defp identity_boundary(fun) do
    fun.()
  rescue
    _ -> invalid!()
  end

  defp require!(true), do: :ok
  defp require!(_), do: invalid!()
  defp invalid!, do: raise(ArgumentError, "legacy_source_identity")

  # TASK18_FIXED_TRANSPORT_BEGIN
  @transport_project Path.expand("../../../..", __DIR__)
  @transport_deps "/home/gao/Workspace/gsmlg-opt/Singularity/deps"
  @transport_elixir "/nix/store/dyb5994y17px2n5x1marvyd29js9q9fn-elixir-1.18.4/bin/elixir"
  @transport_versions %{
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
  @transport_sql "SELECT pid FROM pg_catalog.pg_stat_activity WHERE datname=$1 AND application_name=$2 ORDER BY pid"
  @transport_tag "singularity_task18_probe"
  @transport_pdf "JVBERi0xLjQKMSAwIG9iago8PCAvVHlwZSAvQ2F0YWxvZyAvUGFnZXMgMiAwIFIgPj4KZW5kb2JqCjIgMCBvYmoKPDwgL1R5cGUgL1BhZ2VzIC9LaWRzIFszIDAgUl0gL0NvdW50IDEgPj4KZW5kb2JqCjMgMCBvYmoKPDwgL1R5cGUgL1BhZ2UgL1BhcmVudCAyIDAgUiAvTWVkaWFCb3ggWzAgMCAyMDAgMTAwXSAvUmVzb3VyY2VzIDw8IC9Gb250IDw8IC9GMSA1IDAgUiA+PiA+PiAvQ29udGVudHMgNCAwIFIgPj4KZW5kb2JqCjQgMCBvYmoKPDwgL0xlbmd0aCA1NCA+PgpzdHJlYW0KQlQgL0YxIDEwIFRmIDEwIDEwIFRkIChMZWdhY3kgY29udHJhY3Qgd2l0bmVzcykgVGogRVQKZW5kc3RyZWFtCmVuZG9iago1IDAgb2JqCjw8IC9UeXBlIC9Gb250IC9TdWJ0eXBlIC9UeXBlMSAvQmFzZUZvbnQgL0hlbHZldGljYSA+PgplbmRvYmoKeHJlZgowIDYKMDAwMDAwMDAwMCA2NTUzNSBmIAowMDAwMDAwMDA5IDAwMDAwIG4gCjAwMDAwMDAwNTggMDAwMDAgbiAKMDAwMDAwMDExNSAwMDAwMCBuIAowMDAwMDAwMjQxIDAwMDAwIG4gCjAwMDAwMDAzNDQgMDAwMDAgbiAKdHJhaWxlcgo8PCAvU2l6ZSA2IC9Sb290IDEgMCBSID4+CnN0YXJ0eHJlZgo0MTQKJSVFT0YK"
  @transport_png "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=="
  @transport_deleted "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYPj/HwADAgH/5ncLrgAAAABJRU5ErkJggg=="

  # TASK18_PARENT_PROTOCOL_IDENTITY_BEGIN
  @transport_parent_protocols %{
    DBConnection.Query => %{
      app: :db_connection,
      source: "lib/db_connection/query.ex",
      source_pin: {1468, "9f287ddb5c376b36916307b3544e0134593aca361afada2aa266043668b32553"},
      original_pin: {6904, "87d57b325e36b72a80b0ba0b363db13f6aac8f7a164c5acf33295cd1b37e8525"},
      consolidated_pin: {6084, "109308365bd76e4d5d14abf76b0162ad9196f281e41429d347e83b61df2a9c0d"}
    },
    Ecto.Queryable => %{
      app: :ecto,
      source: "lib/ecto/queryable.ex",
      source_pin: {4923, "7a3ae5652ec5926f97743cf37c527fae8652e212a87f6fe152e387d31bc12e5f"},
      original_pin: {6704, "026b280519aa8f41da136e4f1708de973a4be6e4432ea81b78611aa2b7c326d5"},
      consolidated_pin: {5904, "c5fc6ffa43c8e3fe30da61b9a28925f427e6cb6e09cd423395d4b487d2c27047"}
    },
    Jason.Encoder => %{
      app: :jason,
      source: "lib/encoder.ex",
      source_pin: {6642, "8398c2e091bcd1853348221208eee145f2840552a9cf51f11183b36e0192bb39"},
      original_pin: {5720, "5f3c8b0c5d2c4c04fa98105fba605e95bcfea2d55266a67172f1cb1e74a6e961"},
      consolidated_pin: {7800, "63a4cb6f14e8524730454e7cce2d790ecc8c6b537e8179dd19ef941c254d6579"}
    },
    Plug.Exception => %{
      app: :plug,
      source: "lib/plug/exceptions.ex",
      source_pin: {2014, "2f3f4be836ec60c5e0fe84b41effb7da13171087c89c6774deaabb4ac9b51ae8"},
      original_pin: {5944, "665e3d6bd15e9a680cc380e2795fd92f5e4f1ea481a5c651a736e39ad85c4e6d"},
      consolidated_pin: {4808, "cf0923bdecda6ce67dfdc772f95b99eb3b1a9602da6f250d7f9856099f707449"}
    }
  }
  @transport_parent_protocol_fields [
    :app,
    :source_path,
    :original_path,
    :consolidated_path,
    :source_bytes,
    :original_bytes,
    :consolidated_bytes,
    :located_path,
    :loaded_md5
  ]

  # Pure fixed-file observations only, not proof that the historical child ran.
  def validate_parent_protocols!(observations, child_paths) do
    try do
      require!(is_map(observations) and not is_struct(observations))

      require!(
        Enum.sort(Map.keys(observations)) == Enum.sort(Map.keys(@transport_parent_protocols))
      )

      require!(child_paths == transport_child_paths())

      Map.new(@transport_parent_protocols, fn {module, pin} ->
        row = Map.fetch!(observations, module)
        require!(is_map(row) and not is_struct(row))
        require!(Enum.sort(Map.keys(row)) == Enum.sort(@transport_parent_protocol_fields))
        require!(row.app == pin.app)
        {source, original, consolidated} = transport_protocol_paths(module, pin)
        require!(row.source_path == source)
        require!(row.original_path == original)
        require!(row.consolidated_path == consolidated)
        transport_protocol_bytes!(row.source_bytes, pin.source_pin)
        transport_protocol_bytes!(row.original_bytes, pin.original_pin)
        transport_protocol_bytes!(row.consolidated_bytes, pin.consolidated_pin)

        {:ok, {^module, [{:compile_info, original_information}]}} =
          :beam_lib.chunks(row.original_bytes, [:compile_info])

        {:ok, {^module, [{:compile_info, consolidated_information}]}} =
          :beam_lib.chunks(row.consolidated_bytes, [:compile_info])

        require!(List.to_string(Keyword.fetch!(original_information, :source)) == source)
        require!(consolidated_information == original_information)
        require!(row.located_path in [original, consolidated])

        selected =
          if row.located_path == original, do: row.original_bytes, else: row.consolidated_bytes

        {:ok, {^module, md5}} = :beam_lib.md5(selected)
        require!(is_binary(md5) and byte_size(md5) == 16)
        require!(row.loaded_md5 == :unloaded or row.loaded_md5 == md5)
        {module, {row.located_path, md5}}
      end)
    rescue
      _ -> raise ArgumentError, "legacy_dependency_identity"
    catch
      _, _ -> raise ArgumentError, "legacy_dependency_identity"
    end
  end

  defp transport_protocol_bytes!(bytes, {size, sha256}) do
    require!(is_binary(bytes) and byte_size(bytes) == size)
    require!(digest(:sha256, bytes) == sha256)
  end

  defp transport_child_paths do
    Enum.map(Enum.sort(@transport_versions), fn {app, _version} ->
      Path.join([@transport_project, "_build", "test", "lib", Atom.to_string(app), "ebin"])
    end)
  end

  defp transport_protocol_paths(module, pin) do
    app = Atom.to_string(pin.app)
    filename = Atom.to_string(module) <> ".beam"

    {
      Path.join([@transport_deps, app, pin.source]),
      Path.join([@transport_project, "_build", "test", "lib", app, "ebin", filename]),
      Path.join([@transport_project, "_build", "test", "consolidated", filename])
    }
  end

  defp transport_parent_protocol_identity!(child_paths) do
    observations =
      Map.new(@transport_parent_protocols, fn {module, pin} ->
        {source, original, consolidated} = transport_protocol_paths(module, pin)
        {source_size, _} = pin.source_pin
        {original_size, _} = pin.original_pin
        {consolidated_size, _} = pin.consolidated_pin

        located =
          case :code.which(module) do
            path when is_list(path) -> List.to_string(path)
            _ -> nil
          end

        loaded_md5 =
          if :code.is_loaded(module) == false,
            do: :unloaded,
            else: :erlang.get_module_info(module, :md5)

        {module,
         %{
           app: pin.app,
           source_path: source,
           original_path: original,
           consolidated_path: consolidated,
           source_bytes: transport_protocol_file!(source, source_size),
           original_bytes: transport_protocol_file!(original, original_size),
           consolidated_bytes: transport_protocol_file!(consolidated, consolidated_size),
           located_path: located,
           loaded_md5: loaded_md5
         }}
      end)

    identity = validate_parent_protocols!(observations, child_paths)

    loaded =
      MapSet.new(for {module, row} <- observations, row.loaded_md5 != :unloaded, do: module)

    %{identity: identity, loaded: loaded}
  end

  defp transport_protocol_file!(path, size) do
    Enum.each(ancestors(Path.dirname(path)), &require_directory!/1)
    stat = File.lstat!(path)
    require!(stat.type == :regular and stat.size == size and :erlang.band(stat.mode, 0o111) == 0)
    {:ok, file} = :file.open(String.to_charlist(path), [:read, :binary, :raw])

    try do
      {:ok, bytes} = :file.read(file, size + 1)
      require!(byte_size(bytes) == size)
      :eof = :file.read(file, 1)
      bytes
    after
      :ok = :file.close(file)
    end
  end

  defp transport_parent_protocols_unchanged?(snapshot, child_paths) do
    try do
      current = transport_parent_protocol_identity!(child_paths)
      current.identity == snapshot.identity and MapSet.subset?(snapshot.loaded, current.loaded)
    rescue
      _ -> false
    catch
      _, _ -> false
    end
  end

  # TASK18_PARENT_PROTOCOL_IDENTITY_END

  def probe_transport!(destination, context, scenario) do
    probe_transport(destination, context, scenario, nil)
  end

  def probe_transport!(destination, context, scenario, observer) when is_pid(observer) do
    probe_transport(destination, context, scenario, observer)
  end

  defp probe_transport(destination, context, scenario, observer)
       when scenario in [
              :clean_frame,
              :start_failure,
              :stderr_prefix,
              :malformed_payload,
              :short_frame_trailer,
              :ascii_stderr_flood,
              :declared_oversize,
              :full_frame_eof,
              :full_frame_overrun
            ] or scenario in [:clean_frame_exit17, :empty_eof, :partial_header_eof, :partial_body_eof] do
    binding =
      try do
        require!(is_map(context) and Enum.sort(Map.keys(context)) == [:caller, :report_cleanup])
        require!(is_pid(context.caller) and is_function(context.report_cleanup, 1))
        require!(Process.info(self(), :trap_exit) == {:trap_exit, true})
        require!(not Application.get_env(:ex_cmd, :enable_debug_logs, false))
        source_identity!()

        {paths, parent_protocols} =
          try do
            transport_dependencies!()
          rescue
            _ -> throw({:legacy_preparation_failed, :legacy_dependency_identity})
          catch
            _, _ -> throw({:legacy_preparation_failed, :legacy_dependency_identity})
          end

        transport_destination!(destination)

        %{rows: [[oid]]} =
          Singularity.Storage.SafeSQL.query!(
            Singularity.Storage.MigrationRepo,
            "SELECT oid::bigint FROM pg_catalog.pg_database WHERE datname=$1",
            [destination.database],
            timeout: 1_000
          )

        allocation = Path.dirname(destination.object_root)
        workspace = Path.join(allocation, "historical-build")

        configuration = %{
          "protocol" => 1,
          "source_fingerprint" => @fingerprint,
          "database" => destination.database,
          "database_oid" => oid,
          "object_root" => destination.object_root,
          "build_root" => workspace,
          "repositories" => transport_repositories(destination.database),
          "credentials" => %{
            "login" => "legacy-contract@example.invalid",
            "password" => "synthetic-contract-password"
          },
          "originals" => %{
            "text_pdf_base64" => @transport_pdf,
            "binary_png_base64" => @transport_png,
            "deleted_png_base64" => @transport_deleted
          }
        }

        frame = encode_configuration!(configuration)
        %{frame: frame, workspace: workspace, paths: paths, parent_protocols: parent_protocols}
      rescue
        _ -> throw({:legacy_preparation_failed, :legacy_identity})
      catch
        :throw, {:legacy_preparation_failed, :legacy_dependency_identity} ->
          throw({:legacy_preparation_failed, :legacy_dependency_identity})

        _, _ ->
          throw({:legacy_preparation_failed, :legacy_identity})
      end

    transport_run(destination, context, binding, scenario, observer)
  end

  defp transport_run(destination, context, binding, scenario, observer) do
    context.report_cleanup.(:running)
    run = make_ref()
    caller_monitor = Process.monitor(context.caller)
    deadline = System.monotonic_time(:millisecond) + 45_000

    workspace =
      try do
        :ok = File.mkdir(binding.workspace)
        :ok = File.chmod(binding.workspace, 0o700)
        transport_directory_identity!(binding.workspace)
      rescue
        _ -> nil
      catch
        _, _ -> nil
      end

    if is_nil(workspace) do
      transport_parent_protocols_unchanged?(binding.parent_protocols, binding.paths)
      Process.demonitor(caller_monitor, [:flush])
      context.report_cleanup.(:unconfirmed)
      throw({:legacy_preparation_failed, :legacy_preparation})
    end

    argv =
      [@transport_elixir, "--erl", "+fnu"] ++
        Enum.flat_map(binding.paths, &["-pa", &1]) ++ [Path.join(@root, "runner.exs")]

    environment =
      Enum.map(
        ~w(ERL_AFLAGS ERL_FLAGS ERL_ZFLAGS ERL_LIBS ELIXIR_ERL_OPTIONS ELIXIR_CLI_DRY_RUN RUN_ERL_PIPE RUN_ERL_LOG BASH_ENV ENV),
        &{&1, ""}
      ) ++ [{"SINGULARITY_TASK18_PROBE", Atom.to_string(if(scenario == :start_failure, do: :clean_frame, else: scenario))}]

    launched =
      try do
        ExCmd.Process.start_link(argv,
          cd: if(scenario == :start_failure, do: Path.join(@root, "runner.exs"), else: binding.workspace),
          env: environment,
          stderr: :redirect_to_stdout,
          log: nil
        )
      rescue
        _ -> :failed
      catch
        _, _ -> :failed
      end

    case launched do
      {:ok, handle} ->
        owner = self()
        command_monitor = Process.monitor(handle.pid)
        {reader, reader_monitor} = spawn_monitor(fn -> transport_reader(owner, run, handle) end)

        {writer, writer_monitor} =
          spawn_monitor(fn -> transport_writer(owner, run, handle, binding.frame) end)

        state = %{
          handle: handle,
          run: run,
          reader: reader,
          writer: writer,
          monitors: %{
            command_monitor => handle.pid,
            reader_monitor => reader,
            writer_monitor => writer
          },
          down: MapSet.new(),
          caller_monitor: caller_monitor,
          caller: context.caller,
          pending_observer: observer,
          deadline: deadline,
          primary: nil,
          receipt: nil,
          stdin_closed: false,
          workspace: binding.workspace,
          workspace_identity: workspace,
          database: destination.database,
          parent_protocols: binding.parent_protocols,
          dependency_paths: binding.paths
        }

        transport_event(
          context.caller,
          {:legacy_upgrade_transport, run, self(), {:started, handle.pid, reader, writer}}
        )

        if is_nil(observer) do
          send(reader, {run, :start})
          send(writer, {run, :start})
        end

        state =
          try do
            transport_receive(state)
          rescue
            _ -> %{state | primary: :legacy_preparation}
          catch
            _, _ -> %{state | primary: :legacy_preparation}
          end

        transport_finish(state, context)

      {:error, "`:cd` must be valid directory path"} ->
        closed? =
          try do
            require!(transport_parent_protocols_unchanged?(binding.parent_protocols, binding.paths))
            require!(
              transport_connections_absent(destination.database, System.monotonic_time(:millisecond) + 5_000)
            )
            require!(absolute_canonical?(binding.workspace))
            Enum.each(ancestors(Path.dirname(binding.workspace)), &require_directory!/1)
            %File.Stat{type: :directory, uid: 1000, mode: mode} =
              File.lstat!(binding.workspace)
            require!(:erlang.band(mode, 0o7777) == 0o700)
            require!(File.ls!(binding.workspace) == [])
            require!(transport_directory_identity!(binding.workspace) == workspace)
            :ok = File.rmdir(binding.workspace)
            {:error, :enoent} = File.lstat(binding.workspace)
            true
          rescue
            _ -> false
          catch
            _, _ -> false
          end

        Process.demonitor(caller_monitor, [:flush])
        cleanup = if closed?, do: :closed, else: :unconfirmed
        context.report_cleanup.(cleanup)
        transport_event(
          context.caller,
          {:legacy_upgrade_transport, run, self(), {:cleanup, cleanup}}
        )

        throw({:legacy_preparation_failed, :legacy_start})

      _ ->
        transport_parent_protocols_unchanged?(binding.parent_protocols, binding.paths)
        Process.demonitor(caller_monitor, [:flush])
        context.report_cleanup.(:unconfirmed)
        throw({:legacy_preparation_failed, :legacy_start})
    end
  end

  defp transport_destination!(destination) do
    require!(Enum.sort(Map.keys(destination)) == [:database, :object_root, :repo])
    require!(destination.repo == Singularity.Storage.MigrationRepo)
    require!(Regex.match?(~r/\Asingularity_test_[0-9a-f]{24}\z/, destination.database))
    suffix = String.replace_prefix(destination.database, "singularity_test_", "")

    require!(
      destination.object_root ==
        Path.join([System.tmp_dir!(), "singularity", "integration", suffix, "objects"])
    )

    require!(
      Application.fetch_env!(:singularity_storage, :storage_root) == destination.object_root
    )

    require_directory!(destination.object_root)
    require_directory!(Path.dirname(destination.object_root))

    Enum.each(transport_repositories(destination.database), fn {_name, connection} ->
      require!(connection["database"] == destination.database)
    end)
  end

  defp transport_repositories(database) do
    Map.new(
      [
        {"migration", Singularity.Storage.MigrationRepo, "singularity_migration"},
        {"request", Singularity.Storage.RequestRepo, "singularity_web"},
        {"pre_auth", Singularity.Storage.PreAuthRepo, "singularity_pre_auth"},
        {"dispatcher", Singularity.Storage.DispatcherRepo, "singularity_dispatcher"},
        {"worker", Singularity.Storage.WorkerRepo, "singularity_worker"}
      ],
      fn {name, repo, role} ->
        config = repo.config()
        require!(config[:database] == database and config[:username] == role)
        require!(is_pid(Process.whereis(repo)))

        {name,
         %{
           "database" => database,
           "username" => role,
           "socket_dir" => config[:socket_dir],
           "port" => config[:port]
         }}
      end
    )
  end

  defp transport_dependencies! do
    require!(System.version() == "1.18.4")
    require!(List.to_string(:erlang.system_info(:otp_release)) == "28")

    require!(
      File.read!(Path.join([List.to_string(:code.root_dir()), "releases", "28", "OTP_VERSION"]))
      |> String.trim() == "28.5.0.3"
    )

    require_regular!(@transport_elixir)
    require_regular!(Path.join(@root, "runner.exs"))
    old = File.read!(Path.join(@root, "sources/mix.lock.source"))
    current = File.read!(Path.join(@transport_project, "mix.lock"))
    require!(digest(:sha256, old) == @lock_sha256)

    require!(
      digest(:sha256, current) ==
        "86d603cb14397f156cc74f2c94df6f71f9b8ab718bdda78691ae8bac55decf23"
    )

    paths =
      Enum.map(Enum.sort(@transport_versions), fn {app, version} ->
        ebin =
          Path.join([@transport_project, "_build", "test", "lib", Atom.to_string(app), "ebin"])

        source = Path.join(@transport_deps, Atom.to_string(app))
        Enum.each(ancestors(ebin) ++ ancestors(source), &require_directory!/1)

        {:ok, [{:application, ^app, metadata}]} =
          :file.consult(String.to_charlist(Path.join(ebin, Atom.to_string(app) <> ".app")))

        require!(List.to_string(Keyword.fetch!(metadata, :vsn)) == version)

        Enum.each(Keyword.fetch!(metadata, :modules), fn module ->
          beam = Path.join(ebin, Atom.to_string(module) <> ".beam")
          require_regular!(beam)

          {:ok, {^module, [{:compile_info, information}]}} =
            :beam_lib.chunks(String.to_charlist(beam), [:compile_info])

          origin = information |> Keyword.fetch!(:source) |> List.to_string()
          require!(absolute_canonical?(origin) and String.starts_with?(origin, source <> "/"))

          if :code.is_loaded(module) != false and
               not is_map_key(@transport_parent_protocols, module),
             do: require!(List.to_string(:code.which(module)) == beam)
        end)

        ebin
      end)

    {paths, transport_parent_protocol_identity!(paths)}
  end

  defp transport_reader(owner, run, handle) do
    receive do
      {^run, :start} ->
        try do
          :ok = ExCmd.Process.change_pipe_owner(handle, :stdout, self())

          with {:ok, <<size::unsigned-big-integer-size(32)>>} <-
                 transport_read_exact(handle, 4, <<>>),
               true <- size <= 65_536,
               {:ok, body} <- transport_read_exact(handle, size, <<>>),
               :ok <- transport_full_probe(owner, run, handle, size),
               {:ok, receipt} <-
                 decode_receipt!(<<size::unsigned-big-integer-size(32), body::binary>>) do
            send(owner, {run, :frame, self(), receipt})

            if size == 65_536 do
              send(owner, {run, :eof, self()})
            else
              receive do
                {^run, :probe} ->
                  case transport_read_result(handle, 1, ExCmd.Process.read(handle, 1)) do
                    :eof ->
                      send(owner, {run, :eof, self()})

                    {:ok, _} ->
                      category =
                        if size == 65_536, do: :legacy_output_limit, else: :legacy_protocol

                      send(owner, {run, :rejected, self(), category})

                    _ ->
                      send(owner, {run, :pipe_error, self()})
                  end
              end
            end
          else
            false ->
              send(owner, {run, :rejected, self(), :legacy_output_limit})

            {:error, category} when category in [:legacy_protocol, :legacy_output_limit] ->
              send(owner, {run, :rejected, self(), category})

            :eof ->
              send(owner, {run, :rejected, self(), :legacy_protocol})

            _ ->
              send(owner, {run, :pipe_error, self()})
          end
        rescue
          _ -> send(owner, {run, :pipe_error, self()})
        catch
          _, _ -> send(owner, {run, :pipe_error, self()})
        end
    end
  end

  defp transport_full_probe(owner, run, handle, 65_536) do
    send(owner, {run, :body_acquired, self()})

    receive do
      {^run, :probe} ->
        case transport_read_result(handle, 1, ExCmd.Process.read(handle, 1)) do
          :eof -> :ok
          {:ok, _} -> {:error, :legacy_output_limit}
          _ -> {:error, :legacy_pipe}
        end
    end
  end

  defp transport_full_probe(_owner, _run, _handle, _size), do: :ok

  defp transport_read_exact(_handle, 0, bytes), do: {:ok, bytes}

  defp transport_read_exact(handle, remaining, bytes) do
    case transport_read_result(handle, min(4_096, remaining), ExCmd.Process.read(handle, min(4_096, remaining))) do
      {:ok, chunk} ->
        chunk = IO.iodata_to_binary(chunk)

        if byte_size(chunk) in 1..remaining,
          do: transport_read_exact(handle, remaining - byte_size(chunk), bytes <> chunk),
          else: {:error, :legacy_protocol}

      :eof ->
        :eof

      _ ->
        {:error, :legacy_pipe}
    end
  end

  # Observe only the actual read result; preserve its value and prior exception order.
  defp transport_read_result(_handle, _requested, result), do: result

  defp transport_writer(owner, run, handle, frame) do
    receive do
      {^run, :start} ->
        try do
          :ok = ExCmd.Process.change_pipe_owner(handle, :stdin, self())
          :ok = ExCmd.Process.write(handle, frame)

          receive do
            {^run, :close} ->
              :ok = ExCmd.Process.close_stdin(handle)
              send(owner, {run, :stdin_closed, self()})
          end
        rescue
          _ -> send(owner, {run, :pipe_error, self()})
        catch
          _, _ -> send(owner, {run, :pipe_error, self()})
        end
    end
  end

  defp transport_receive(state) do
    run = state.run
    reader = state.reader
    writer = state.writer
    caller_monitor = state.caller_monitor
    pending_observer = state.pending_observer
    timeout = max(0, state.deadline - System.monotonic_time(:millisecond))

    receive do
      {^run, :observer_ready, ^pending_observer} when is_pid(pending_observer) ->
        if System.monotonic_time(:millisecond) < state.deadline do
          send(reader, {run, :start})
          send(writer, {run, :start})
          transport_receive(%{state | pending_observer: nil})
        else
          %{state | primary: state.primary || :legacy_deadline}
        end

      {^run, :body_acquired, ^reader} ->
        send(writer, {run, :close})
        transport_receive(state)

      {^run, :frame, ^reader, receipt} ->
        if not state.stdin_closed, do: send(writer, {run, :close})
        transport_receive(%{state | receipt: receipt})

      {^run, :stdin_closed, ^writer} ->
        transport_emit(state, {:stdin_closed, writer})
        state = %{state | stdin_closed: true}

        if is_nil(state.primary) do
          send(reader, {run, :probe})
          transport_receive(state)
        else
          state
        end

      {^run, :eof, ^reader} ->
        transport_emit(state, {:reader_eof, reader})
        state

      {^run, :rejected, ^reader, category}
      when category in [:legacy_protocol, :legacy_output_limit] ->
        transport_emit(state, {:reader_rejected, category})

        if state.stdin_closed do
          %{state | primary: state.primary || category}
        else
          send(writer, {run, :close})
          transport_receive(%{state | primary: state.primary || category})
        end

      {^run, :pipe_error, pid} when pid == reader or pid == writer ->
        %{state | primary: state.primary || :legacy_pipe}

      {:DOWN, ^caller_monitor, :process, _, _} ->
        %{state | primary: state.primary || :legacy_caller_down}

      {:DOWN, monitor, :process, pid, _} when is_map_key(state.monitors, monitor) ->
        state = %{state | down: MapSet.put(state.down, pid)}

        if (pid == writer and not state.stdin_closed) or
             (pid == reader and is_nil(state.primary)),
           do: %{state | primary: state.primary || :legacy_pipe},
           else: transport_receive(state)
    after
      timeout -> %{state | primary: state.primary || :legacy_deadline}
    end
  end

  defp transport_finish(state, context) do
    deadline = System.monotonic_time(:millisecond) + 5_000

    if not is_nil(state.primary) do
      Enum.each([state.reader, state.writer], fn pid ->
        if Process.alive?(pid), do: Process.exit(pid, :kill)
      end)
    end

    transport_emit(state, {:await_started, state.handle.pid})

    result =
      try do
        ExCmd.Process.await_exit(
          state.handle,
          min(4_000, max(51, deadline - System.monotonic_time(:millisecond) - 750))
        )
      rescue
        _ -> :unconfirmed
      catch
        _, _ -> :unconfirmed
      end

    status =
      case result do
        {:ok, 0} -> :zero
        {:ok, code} when is_integer(code) and code > 0 -> :nonzero
        {:error, :killed} -> :nonzero
        _ -> :unconfirmed
      end

    transport_emit(state, {:await_complete, status})
    state = transport_workers_down(state, deadline)
    workers? = MapSet.size(state.down) == 3
    if workers?, do: transport_emit(state, :workers_down)

    absent? =
      status != :unconfirmed and workers? and
        transport_connections_absent(state.database, deadline)

    if absent?, do: transport_emit(state, :child_connections_absent)
    workspace? = absent? and transport_remove_workspace(state)
    Process.demonitor(state.caller_monitor, [:flush])
    Enum.each(state.monitors, fn {ref, _} -> Process.demonitor(ref, [:flush]) end)
    transport_exit_tail(state.handle.pid)
    closed? = status != :unconfirmed and workers? and absent? and workspace?
    cleanup = if closed?, do: :closed, else: :unconfirmed

    parent_unchanged? =
      transport_parent_protocols_unchanged?(state.parent_protocols, state.dependency_paths)

    primary =
      state.primary || if(status == :zero, do: nil, else: :legacy_exit) ||
        if(parent_unchanged?, do: nil, else: :legacy_dependency_identity)

    context.report_cleanup.(cleanup)
    transport_emit(state, {:cleanup, cleanup})

    cond do
      not closed? -> throw({:legacy_preparation_failed, primary || :legacy_preparation})
      not is_nil(primary) -> throw({:legacy_preparation_failed, primary})
      is_map(state.receipt) -> state.receipt
      true -> throw({:legacy_preparation_failed, :legacy_protocol})
    end
  end

  defp transport_workers_down(state, deadline) do
    if MapSet.size(state.down) == 3 do
      state
    else
      receive do
        {:DOWN, ref, :process, pid, _} when is_map_key(state.monitors, ref) ->
          transport_workers_down(%{state | down: MapSet.put(state.down, pid)}, deadline)
      after
        max(0, deadline - System.monotonic_time(:millisecond)) -> state
      end
    end
  end

  defp transport_connections_absent(database, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining > 0 do
      try do
        case Singularity.Storage.SafeSQL.query!(
               Singularity.Storage.MigrationRepo,
               @transport_sql,
               [database, @transport_tag],
               timeout: min(1_000, remaining)
             ) do
          %Postgrex.Result{command: :select, columns: ["pid"], rows: [], num_rows: 0} ->
            true

          %Postgrex.Result{command: :select, columns: ["pid"], rows: rows} ->
            Enum.all?(rows, fn
              [pid] -> is_integer(pid) and pid > 0
              _ -> false
            end) and
              transport_connections_absent(database, deadline)

          _ ->
            false
        end
      rescue
        _ -> false
      catch
        _, _ -> false
      end
    else
      false
    end
  end

  defp transport_remove_workspace(state) do
    try do
      require!(transport_directory_identity!(state.workspace) == state.workspace_identity)
      File.rm_rf!(state.workspace)
      not File.exists?(state.workspace)
    rescue
      _ -> false
    catch
      _, _ -> false
    end
  end

  defp transport_directory_identity!(path) do
    %File.Stat{type: :directory, major_device: major, minor_device: minor, inode: inode} =
      File.lstat!(path)

    {major, minor, inode}
  end

  defp transport_exit_tail(pid) do
    receive do
      {:EXIT, ^pid, _} -> transport_exit_tail(pid)
    after
      0 -> :ok
    end
  end

  defp transport_emit(state, stage),
    do: transport_event(state.caller, {:legacy_upgrade_transport, state.run, self(), stage})

  defp transport_event(caller, event), do: send(caller, event)
  # TASK18_FIXED_TRANSPORT_END
end
