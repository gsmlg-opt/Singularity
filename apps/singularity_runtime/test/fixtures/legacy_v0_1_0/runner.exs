# Fixed synthetic transport probes only; never historical/native evidence.
defmodule SingularityLegacyUpgradeRunner do
  @root __DIR__
  @project Path.expand("../../../../..", __DIR__)
  @deps "/home/gao/Workspace/gsmlg-opt/Singularity/deps"
  @versions %{
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
  @fingerprint "d7506f511de599dfb92cd2313f843abb27ca26eafd3bf89939ecbf07e2a22924"
  @receipt ~S|{"protocol":1,"source_fingerprint":"d7506f511de599dfb92cd2313f843abb27ca26eafd3bf89939ecbf07e2a22924","owner":{"account_id":"11111111-1111-4111-8111-111111111111","credential_id":"11111111-1111-4111-8111-111111111112","principal_id":"11111111-1111-4111-8111-111111111111","vault_id":"11111111-1111-4111-8111-111111111111"},"notes":{"open_conflict":{"resource_id":"22222222-2222-4222-8222-222222222221","initial_version_id":"22222222-2222-4222-8222-222222222222","accepted_version_id":"22222222-2222-4222-8222-222222222223","competing_version_id":"22222222-2222-4222-8222-222222222224","conflict_id":"22222222-2222-4222-8222-222222222225","conflict_state":"open"},"resolved_conflict":{"resource_id":"33333333-3333-4333-8333-333333333331","initial_version_id":"33333333-3333-4333-8333-333333333332","accepted_version_id":"33333333-3333-4333-8333-333333333333","competing_version_id":"33333333-3333-4333-8333-333333333334","conflict_id":"33333333-3333-4333-8333-333333333335","merge_version_id":"33333333-3333-4333-8333-333333333336","conflict_state":"resolved"},"tombstoned":{"resource_id":"44444444-4444-4444-8444-444444444441","initial_version_id":"44444444-4444-4444-8444-444444444442","accepted_version_id":"44444444-4444-4444-8444-444444444443","state":"tombstoned"}},"assets":{"text_pdf":{"asset_id":"55555555-5555-4555-8555-555555555551","resource_id":"55555555-5555-4555-8555-555555555552","resource_version_id":"55555555-5555-4555-8555-555555555553","object_id":"55555555-5555-4555-8555-555555555554","sha256":"84d026370041347e57de1024eb1bdf95a01432b75413d06c7daae04165dfaf65","bytes":597,"state":"ready","object_lifecycle":"available"},"binary_png":{"asset_id":"66666666-6666-4666-8666-666666666661","resource_id":"66666666-6666-4666-8666-666666666662","resource_version_id":"66666666-6666-4666-8666-666666666663","object_id":"66666666-6666-4666-8666-666666666664","sha256":"4ff6ab670a58c14270e034e2090d9a432caa263a14e0a25785386b0c12f880b5","bytes":70,"state":"ready","object_lifecycle":"available"},"deleted_png":{"asset_id":"77777777-7777-4777-8777-777777777771","resource_id":"77777777-7777-4777-8777-777777777772","resource_version_id":"77777777-7777-4777-8777-777777777773","object_id":"77777777-7777-4777-8777-777777777774","sha256":"6a34118ba2e0bf5da5ab14cb63b121e2e8b2987a876668a9b2f9c30e1357470b","bytes":70,"state":"deleted","object_lifecycle":"orphan_pending"}},"work":{"native_name_encoding":"utf8","completed":[{"event_id":"88888888-8888-4888-8888-888888888881","submission_id":"88888888-8888-4888-8888-888888888881","runner_job_id":"1","progress_id":"88888888-8888-4888-8888-888888888882","effect_id":"88888888-8888-4888-8888-888888888883","job_type":"asset_metadata"}],"pending_object_cleanup":{"event_id":"99999999-9999-4999-8999-999999999991","submission_id":"99999999-9999-4999-8999-999999999991","runner_job_id":"2"}}}|
  @canary "TASK18_TRANSPORT_PREFIX_CANARY"

  def run do
    Process.flag(:trap_exit, true)

    try do
      identity!()
      scenario = System.get_env("SINGULARITY_TASK18_PROBE")

      check!(
        scenario in [
          "clean_frame",
          "stderr_prefix",
          "malformed_payload",
          "short_frame_trailer",
          "ascii_stderr_flood",
          "declared_oversize",
          "full_frame_eof",
          "full_frame_overrun"
        ] or scenario in ["clean_frame_exit17", "empty_eof", "partial_header_eof", "partial_body_eof"]
      )

      <<length::unsigned-big-integer-size(32)>> = read!(4)
      check!(length in 1..16_384)
      body = read!(length)
      check!(String.valid?(body))
      configuration = body |> Jason.decode!(objects: :ordered_objects) |> plain!()
      configuration!(configuration)
      {:ok, _} = Application.ensure_all_started(:postgrex)
      migration = configuration["repositories"]["migration"]

      {:ok, connection} =
        Postgrex.start_link(
          database: migration["database"],
          username: migration["username"],
          socket_dir: migration["socket_dir"],
          port: migration["port"],
          parameters: [application_name: "singularity_task18_probe"],
          backoff_type: :stop
        )

      try do
        %{rows: [[database_oid]]} =
          Postgrex.query!(
            connection,
            "SELECT oid::bigint FROM pg_catalog.pg_database WHERE datname=current_database()",
            [],
            timeout: 1_000
          )

        check!(database_oid == configuration["database_oid"])

        %{rows: [[role, database]]} =
          Postgrex.query!(
            connection,
            "SELECT current_user,current_database()",
            [],
            timeout: 1_000
          )

        check!(role == "singularity_migration" and database == configuration["database"])

        %Postgrex.Result{rows: [[_]]} =
          Postgrex.query!(
            connection,
            "SELECT pg_advisory_lock($1::integer,$2::integer)",
            [1_413_567_307, 18],
            timeout: 45_000
          )

        %Postgrex.Result{rows: [[true]]} =
          Postgrex.query!(
            connection,
            "SELECT pg_advisory_unlock($1::integer,$2::integer)",
            [1_413_567_307, 18],
            timeout: 1_000
          )

        case scenario do
          "clean_frame" ->
            write_receipt!()
            check!(IO.binread(:stdio, 1) == :eof)

          "stderr_prefix" ->
            :ok = IO.binwrite(:stderr, <<0, 0, 0, 1, "!", @canary::binary>>)
            check!(IO.binread(:stdio, 1) == :eof)
            write_receipt!()

          "malformed_payload" ->
            payload = "{" <> @canary <> binary_part(@receipt, 1, byte_size(@receipt) - 1)

            :ok =
              IO.binwrite(
                :stdio,
                <<byte_size(payload)::unsigned-big-integer-size(32), payload::binary>>
              )

            check!(IO.binread(:stdio, 1) == :eof)
            System.halt(17)

          "short_frame_trailer" ->
            write_receipt!()
            check!(IO.binread(:stdio, 1) == :eof)
            :ok = IO.binwrite(:stderr, @canary)
            System.halt(17)

          "ascii_stderr_flood" ->
            :ok = IO.binwrite(:stderr, @canary <> :binary.copy("A", 65_541 - byte_size(@canary)))
            check!(IO.binread(:stdio, 1) == :eof)
            System.halt(17)

          "declared_oversize" ->
            :ok = IO.binwrite(:stdio, <<65_537::unsigned-big-integer-size(32)>>)
            check!(IO.binread(:stdio, 1) == :eof)
            System.halt(17)

          "full_frame_eof" ->
            write_full_receipt!()
            check!(IO.binread(:stdio, 1) == :eof)

          "full_frame_overrun" ->
            write_full_receipt!()
            check!(IO.binread(:stdio, 1) == :eof)
            :ok = IO.binwrite(:stdio, "T")
            System.halt(17)

          "clean_frame_exit17" ->
            write_receipt!()
            check!(IO.binread(:stdio, 1) == :eof)

          "empty_eof" ->
            :ok

          "partial_header_eof" ->
            :ok = IO.binwrite(:stdio, <<0, 0, 0>>)

          "partial_body_eof" ->
            :ok = IO.binwrite(:stdio, <<0, 0, 0, 8, 123, 34, 112>>)
        end
      after
        if Process.alive?(connection), do: GenServer.stop(connection, :normal, 1_000)
      end

      identity!()
      System.halt(if(scenario == "clean_frame_exit17", do: 17, else: 0))
    rescue
      _ -> System.halt(1)
    catch
      _, _ -> System.halt(1)
    end
  end

  defp identity! do
    check!(:file.native_name_encoding() == :utf8)
    check!(System.version() == "1.18.4")
    check!(List.to_string(:erlang.system_info(:otp_release)) == "28")

    check!(
      File.read!(Path.join([List.to_string(:code.root_dir()), "releases", "28", "OTP_VERSION"]))
      |> String.trim() == "28.5.0.3"
    )

    expected =
      Enum.map(Enum.sort(@versions), fn {app, version} ->
        ebin = Path.join([@project, "_build", "test", "lib", Atom.to_string(app), "ebin"])
        source = Path.join(@deps, Atom.to_string(app))

        Enum.each(ancestors(ebin) ++ ancestors(source), fn path ->
          check!(File.lstat!(path).type == :directory)
        end)

        {:ok, [{:application, ^app, metadata}]} =
          :file.consult(String.to_charlist(Path.join(ebin, Atom.to_string(app) <> ".app")))

        check!(List.to_string(Keyword.fetch!(metadata, :vsn)) == version)

        Enum.each(Keyword.fetch!(metadata, :modules), fn module ->
          beam = Path.join(ebin, Atom.to_string(module) <> ".beam")
          check!(File.lstat!(beam).type == :regular)

          {:ok, {^module, [{:compile_info, information}]}} =
            :beam_lib.chunks(String.to_charlist(beam), [:compile_info])

          origin = information |> Keyword.fetch!(:source) |> List.to_string()
          check!(Path.expand(origin) == origin and String.starts_with?(origin, source <> "/"))

          if :code.is_loaded(module) != false,
            do: check!(List.to_string(:code.which(module)) == beam)
        end)

        ebin
      end)

    standard = [
      List.to_string(:code.root_dir()),
      Path.expand("..", List.to_string(:code.lib_dir(:elixir)))
    ]

    Enum.each(:code.get_path(), fn path ->
      absolute = path |> List.to_string() |> Path.expand()

      check!(
        absolute in expected or absolute == File.cwd!() or
          Enum.any?(standard, &String.starts_with?(absolute, &1 <> "/"))
      )

      check!(not String.contains?(absolute, "/lib/singularity_"))
    end)

    old = Path.join(@root, "sources/mix.lock.source") |> File.read!()

    check!(
      digest(:sha256, old) == "ae235b7777083e3ac9912aa73ee13d9fc0fc2eb2bef34d3685d61b7260b60dae"
    )

    current = Path.join(@project, "mix.lock") |> File.read!()

    check!(
      digest(:sha256, current) ==
        "86d603cb14397f156cc74f2c94df6f71f9b8ab718bdda78691ae8bac55decf23"
    )

    manifest_path = Path.join(@root, "source.json")
    check!(File.lstat!(manifest_path).type == :regular)
    manifest_bytes = File.read!(manifest_path)

    check!(
      digest(:sha256, manifest_bytes) ==
        "861a597660b57f43e5e4b64353f3f59868c008ef9f1b6a0b1ca4bdaa7db4433a"
    )

    manifest = Jason.decode!(manifest_bytes)
    check!(manifest["fingerprint"] == @fingerprint and length(manifest["files"]) == 253)

    Enum.each(manifest["files"], fn file ->
      path = Path.join(@root, file["fixture"])

      Enum.each(ancestors(Path.dirname(path)), fn parent ->
        check!(File.lstat!(parent).type == :directory)
      end)

      check!(File.lstat!(path).type == :regular)
      bytes = File.read!(path)
      check!(byte_size(bytes) == file["bytes"])
      check!(digest(:sha256, bytes) == file["sha256"])

      check!(
        digest(:sha, ["blob ", Integer.to_string(byte_size(bytes)), <<0>>, bytes]) == file["blob"]
      )
    end)
  end

  defp configuration!(configuration) do
    exact!(
      configuration,
      ~w(protocol source_fingerprint database database_oid object_root build_root repositories credentials originals)
    )

    check!(
      configuration["protocol"] === 1 and configuration["source_fingerprint"] == @fingerprint
    )

    database = configuration["database"]
    check!(is_binary(database) and Regex.match?(~r/\Asingularity_test_[0-9a-f]{24}\z/, database))

    check!(
      is_integer(configuration["database_oid"]) and
        configuration["database_oid"] in 1..4_294_967_295
    )

    suffix = String.replace_prefix(database, "singularity_test_", "")
    allocation = Path.join([System.tmp_dir!(), "singularity", "integration", suffix])
    check!(configuration["object_root"] == Path.join(allocation, "objects"))
    check!(configuration["build_root"] == Path.join(allocation, "historical-build"))
    check!(File.cwd!() == configuration["build_root"])

    Enum.each([allocation, configuration["object_root"], configuration["build_root"]], fn path ->
      check!(File.lstat!(path).type == :directory)
    end)

    repositories = configuration["repositories"]

    roles = %{
      "migration" => "singularity_migration",
      "request" => "singularity_web",
      "pre_auth" => "singularity_pre_auth",
      "dispatcher" => "singularity_dispatcher",
      "worker" => "singularity_worker"
    }

    exact!(repositories, Map.keys(roles))

    Enum.each(roles, fn {name, role} ->
      connection = repositories[name]
      exact!(connection, ~w(database username socket_dir port))
      check!(connection["database"] == database and connection["username"] == role)
      path!(connection["socket_dir"])
      check!(is_integer(connection["port"]) and connection["port"] in 1..65_535)
    end)

    credentials = configuration["credentials"]
    exact!(credentials, ~w(login password))
    Enum.each(Map.values(credentials), &text!/1)
    originals = configuration["originals"]
    exact!(originals, ~w(text_pdf_base64 binary_png_base64 deleted_png_base64))

    bytes =
      Enum.map(~w(text_pdf_base64 binary_png_base64 deleted_png_base64), fn key ->
        encoded = originals[key]
        {:ok, bytes} = Base.decode64(encoded)
        check!(Base.encode64(bytes) == encoded and byte_size(bytes) in 1..1_024)
        bytes
      end)

    [pdf, png, deleted] = bytes
    check!(String.starts_with?(pdf, "%PDF-") and byte_size(pdf) >= 9)
    check!(Enum.all?(:binary.bin_to_list(pdf), &(&1 < 128)))
    magic = <<137, 80, 78, 71, 13, 10, 26, 10>>
    check!(String.starts_with?(png, magic) and byte_size(png) >= 33)
    check!(String.starts_with?(deleted, magic) and byte_size(deleted) >= 33)
    check!(length(Enum.uniq(bytes)) == 3)
  end

  defp exact!(map, keys) do
    check!(is_map(map) and not is_struct(map))
    check!(Enum.sort(Map.keys(map)) == Enum.sort(keys))
  end

  defp plain!(%Jason.OrderedObject{values: fields}) do
    keys = Enum.map(fields, &elem(&1, 0))
    check!(length(keys) == length(Enum.uniq(keys)))
    Map.new(fields, fn {key, value} -> {key, plain!(value)} end)
  end

  defp plain!(list) when is_list(list), do: Enum.map(list, &plain!/1)
  defp plain!(value), do: value

  defp text!(value),
    do:
      check!(
        is_binary(value) and value != "" and String.valid?(value) and
          not String.contains?(value, <<0>>)
      )

  defp path!(value) do
    text!(value)
    check!(Path.type(value) == :absolute and Path.expand(value) == value and value != "/")
  end

  defp read!(length) do
    bytes = IO.binread(:stdio, length)
    check!(is_binary(bytes) and byte_size(bytes) == length)
    bytes
  end

  defp write_receipt! do
    :ok =
      IO.binwrite(
        :stdio,
        <<byte_size(@receipt)::unsigned-big-integer-size(32), @receipt::binary>>
      )
  end

  defp write_full_receipt! do
    payload = @receipt <> :binary.copy(" ", 65_536 - byte_size(@receipt))
    :ok = IO.binwrite(:stdio, <<65_536::unsigned-big-integer-size(32), payload::binary>>)
  end

  defp digest(algorithm, bytes),
    do: algorithm |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

  defp ancestors("/"), do: ["/"]
  defp ancestors(path), do: ancestors(Path.dirname(path)) ++ [path]
  defp check!(true), do: :ok
  defp check!(_), do: throw(:legacy_protocol)
end

SingularityLegacyUpgradeRunner.run()
