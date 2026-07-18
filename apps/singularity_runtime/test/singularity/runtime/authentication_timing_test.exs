defmodule Singularity.Runtime.AuthenticationTimingTest do
  use ExUnit.Case, async: false

  alias Singularity.Core.Error
  alias Singularity.Runtime.Login
  alias Singularity.Storage.Crypto.Argon2PasswordHasher

  @params %{version: 1, t_cost: 3, m_cost: 16, parallelism: 1}
  @fingerprint_secret :binary.copy(<<0xA7>>, 32)
  @sample_count 7
  @runtime_config Path.expand("../../../../../config/runtime.exs", __DIR__)

  defmodule PreAuth do
    def reserve_attempt(_context, _command),
      do: {:ok, %{id: Ecto.UUID.generate(), accepted?: true}}

    def authentication_candidate(context, normalized_login) do
      case normalized_login do
        "owner@example.test" ->
          {:ok,
           %{
             verifier: context.known_verifier,
             scoped_context: %{
               account_id: "account-1",
               principal_id: "principal-1",
               vault_id: "vault-1"
             }
           }}

        _unknown ->
          {:ok, %{verifier: context.dummy_verifier, scoped_context: nil}}
      end
    end

    def record_attempt(_context, _command), do: :ok
  end

  setup_all do
    assert {:ok, known_verifier} =
             Argon2PasswordHasher.hash(@params, "correct-password")

    assert {:ok, dummy_verifier} =
             Argon2PasswordHasher.hash(@params, "dummy-password")

    adapters = %{
      pre_auth: PreAuth,
      pre_auth_context: %{
        known_verifier: known_verifier,
        dummy_verifier: dummy_verifier
      },
      identity: :unused,
      identity_context: :unused,
      password_hasher: Argon2PasswordHasher,
      password_hasher_context: @params,
      audit_fingerprint_secret: @fingerprint_secret,
      random_bytes: &:crypto.strong_rand_bytes/1
    }

    {:ok, adapters: adapters}
  end

  test "unknown and known-invalid login paths perform comparable Argon2 work", %{
    adapters: adapters
  } do
    unknown_request = request("missing@example.test")
    known_request = request("owner@example.test")

    assert Login.run(adapters, unknown_request) ==
             {:error, Error.new(:unauthenticated)}

    assert Login.run(adapters, known_request) ==
             {:error, Error.new(:unauthenticated)}

    unknown_median = median_duration(adapters, unknown_request)
    known_median = median_duration(adapters, known_request)
    slower = max(unknown_median, known_median)
    faster = min(unknown_median, known_median)

    assert faster > 0
    assert slower / faster < 2.5
  end

  test "test configuration injects a fixed non-production fingerprint secret" do
    assert Application.fetch_env!(
             :singularity_runtime,
             :audit_fingerprint_secret
           ) == @fingerprint_secret
  end

  test "production rejects absent, malformed, and short fingerprint secrets" do
    assert_raise System.EnvError,
                 ~r/SINGULARITY_AUDIT_FINGERPRINT_SECRET/,
                 fn ->
                   with_production_environment(nil, fn ->
                     Config.Reader.read!(@runtime_config, env: :prod)
                   end)
                 end

    for encoded <- ["not base64!", Base.encode64(:binary.copy(<<0xA7>>, 31))] do
      assert_raise ArgumentError,
                   ~r/must decode to at least 32 bytes/,
                   fn ->
                     with_production_environment(encoded, fn ->
                       Config.Reader.read!(@runtime_config, env: :prod)
                     end)
                   end
    end
  end

  test "production accepts and decodes a 32-byte fingerprint secret" do
    encoded = Base.encode64(@fingerprint_secret)

    config =
      with_production_environment(encoded, fn ->
        Config.Reader.read!(@runtime_config, env: :prod)
      end)

    assert config
           |> Keyword.fetch!(:singularity_runtime)
           |> Keyword.fetch!(:audit_fingerprint_secret) ==
             @fingerprint_secret
  end

  defp median_duration(adapters, request) do
    durations =
      for _sample <- 1..@sample_count do
        {duration, {:error, %Error{code: :unauthenticated}}} =
          :timer.tc(Login, :run, [adapters, request])

        duration
      end

    Enum.at(Enum.sort(durations), div(@sample_count, 2))
  end

  defp request(login) do
    %{
      login: login,
      password: "wrong-password",
      source: "127.0.0.1",
      correlation_id: Ecto.UUID.generate()
    }
  end

  defp with_production_environment(encoded_secret, callback) do
    environment = %{
      "SINGULARITY_AUDIT_FINGERPRINT_SECRET" => encoded_secret,
      "SINGULARITY_STORAGE_ROOT" => Path.join(System.tmp_dir!(), "singularity-auth-config"),
      "SINGULARITY_MIGRATION_DATABASE_URL" =>
        "postgresql://singularity_migration@localhost/singularity_prod",
      "SINGULARITY_DATABASE_URL" => "postgresql://singularity_web@localhost/singularity_prod",
      "SINGULARITY_PRE_AUTH_DATABASE_URL" =>
        "postgresql://singularity_pre_auth@localhost/singularity_prod",
      "SINGULARITY_DISPATCHER_DATABASE_URL" =>
        "postgresql://singularity_dispatcher@localhost/singularity_prod",
      "SINGULARITY_WORKER_DATABASE_URL" =>
        "postgresql://singularity_worker@localhost/singularity_prod",
      "SINGULARITY_MAX_CONCURRENT_UPLOADS" => nil
    }

    previous = Map.new(environment, fn {key, _value} -> {key, System.get_env(key)} end)

    try do
      Enum.each(environment, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      callback.()
    after
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end
  end
end
