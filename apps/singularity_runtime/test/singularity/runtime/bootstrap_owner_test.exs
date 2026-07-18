defmodule Singularity.Runtime.BootstrapOwnerTest.Repository do
  use Agent

  def start_link(owner) do
    Agent.start_link(fn -> %{owner: owner, aggregate: nil, calls: []} end)
  end

  def bootstrap_owner(repository, command) do
    Agent.get_and_update(repository, fn state ->
      send(state.owner, {:bootstrap_command, command})

      case state.aggregate do
        nil ->
          aggregate = %{
            account_id: command.account.id,
            credential_id: command.credential.id,
            credential_hash: command.credential.secret_hash,
            principal_id: command.principal.id,
            vault_id: command.vault.id
          }

          {{:ok, aggregate}, %{state | aggregate: aggregate, calls: [command]}}

        aggregate ->
          {{:ok, aggregate}, %{state | calls: [command | state.calls]}}
      end
    end)
  end

  def state(repository), do: Agent.get(repository, & &1)
end

defmodule Singularity.Runtime.BootstrapOwnerTest.PasswordHasher do
  def hash(owner, password) do
    send(owner, {:password_hash, password})
    {:ok, "hash:" <> password}
  end
end

defmodule Singularity.Runtime.BootstrapOwnerTest.KeyDeriver do
  def derive(owner, password, %{salt: salt, params: params}) do
    send(owner, {:derive_kek, password, salt, params})
    {:ok, :binary.copy(<<0x31>>, 32)}
  end
end

defmodule Singularity.Runtime.BootstrapOwnerTest.KeyWrapper do
  def wrap(owner, wrapping_key, raw_key, metadata) do
    send(owner, {:wrap_key, wrapping_key, raw_key, metadata})
    {:ok, %{algorithm: :aes_256_gcm, encoded: :erlang.term_to_binary(metadata)}}
  end
end

defmodule Singularity.Runtime.BootstrapOwnerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Singularity.Runtime.BootstrapOwner

  @tag :integration
  test "PostgreSQL persists one complete owner aggregate in one transaction" do
    login = "owner-#{Ecto.UUID.generate()}@example.test"
    adapters = postgres_adapters()

    assert {:ok, first} =
             Singularity.Storage.Fixtures.with_owner(fn ->
               BootstrapOwner.run(adapters, %{
                 display_name: "Database Owner",
                 login: login,
                 password: "first-database-password"
               })
             end)

    first_verifier = credential_verifier(first.account_id)

    assert {:ok, second} =
             Singularity.Storage.Fixtures.with_owner(fn ->
               BootstrapOwner.run(adapters, %{
                 display_name: "Database Owner",
                 login: login,
                 password: "replacement-database-password"
               })
             end)

    assert first.account_id == second.account_id
    assert first.credential_id == second.credential_id
    assert first.vault_id == second.vault_id
    assert credential_verifier(first.account_id) == first_verifier

    assert %{
             owner_principals: 1,
             personal_vaults: 1,
             memberships: 1,
             key_domains: 1,
             vault_key_versions: 1,
             vault_key_wrappers: 1,
             domain_key_versions: 1,
             dedup_wrappers: 1
           } = aggregate_counts(first)
  end

  @tag :integration
  @tag :tmp_dir
  test "bootstrap task owns its migration repo and preserves descriptor password bytes", %{
    tmp_dir: tmp_dir
  } do
    password = "descriptor-password\t \r\n"
    password_file = Path.join(tmp_dir, "owner-password")

    File.write!(password_file, password <> "\r\n")
    File.chmod!(password_file, 0o600)

    {output, status} = run_bootstrap_task(password_file)

    assert status == 0, output
    assert output =~ "owner account="
    refute output =~ password

    verifier = credential_verifier_for_login("owner@singularity.local")

    password_params =
      :singularity_runtime
      |> Application.fetch_env!(:bootstrap_owner)
      |> Map.fetch!(:password_hasher_context)

    assert {:ok, true} =
             Singularity.Storage.Crypto.Argon2PasswordHasher.verify(
               password_params,
               password,
               verifier
             )

    assert {:ok, false} =
             Singularity.Storage.Crypto.Argon2PasswordHasher.verify(
               password_params,
               String.trim_trailing(password),
               verifier
             )

    File.write!(password_file, "\t \n")

    {output, status} = run_bootstrap_task(password_file)

    assert status == 0, output
    assert output =~ "owner account="
    assert credential_verifier_for_login("owner@singularity.local") == verifier
  end

  test "bootstraps the complete owner aggregate once and preserves the first credential" do
    {:ok, repository} =
      start_supervised({Singularity.Runtime.BootstrapOwnerTest.Repository, self()})

    ids =
      for suffix <- 1..18 do
        "00000000-0000-0000-0000-#{String.pad_leading(Integer.to_string(suffix), 12, "0")}"
      end

    id_source = start_supervised!({Agent, fn -> ids end})

    adapters = %{
      repository: Singularity.Runtime.BootstrapOwnerTest.Repository,
      repository_context: repository,
      password_hasher: Singularity.Runtime.BootstrapOwnerTest.PasswordHasher,
      password_hasher_context: self(),
      key_deriver: Singularity.Runtime.BootstrapOwnerTest.KeyDeriver,
      key_deriver_context: self(),
      key_wrapper: Singularity.Runtime.BootstrapOwnerTest.KeyWrapper,
      key_wrapper_context: self(),
      id_generator: fn -> Agent.get_and_update(id_source, &{hd(&1), tl(&1)}) end,
      random_bytes: fn
        16 -> :binary.copy(<<0x16>>, 16)
        32 -> :binary.copy(<<0x32>>, 32)
      end,
      password_hash_params: %{version: 1},
      vault_kdf_params: %{version: 1, t_cost: 3, m_cost: 16, parallelism: 1},
      initial_capabilities: ["asset.read", "asset.write", "vault.unlock"]
    }

    first_password = " \tfirst-password\r\n"
    second_password = " \t "

    attrs = %{
      display_name: "Primary Owner",
      login: " Owner@Example.Test ",
      password: first_password
    }

    assert {:ok, first} = BootstrapOwner.run(adapters, attrs)

    assert {:ok, second} =
             BootstrapOwner.run(adapters, %{attrs | password: second_password})

    assert first.account_id == second.account_id
    assert first.credential_hash == second.credential_hash

    state = Singularity.Runtime.BootstrapOwnerTest.Repository.state(repository)
    assert state.aggregate.credential_hash == "hash:" <> first_password

    assert_receive {:bootstrap_command, first_command}
    assert_receive {:bootstrap_command, second_command}

    assert first_command.idempotency_key == second_command.idempotency_key
    assert first_command.credential.normalized_login == "owner@example.test"
    assert first_command.person.display_name == "Primary Owner"
    assert first_command.principal.kind == :owner
    assert first_command.vault.kind == :personal
    assert first_command.membership.clearance == :restricted
    assert first_command.capabilities == ["asset.read", "asset.write", "vault.unlock"]
    assert first_command.key_domain.classification == :private
    assert first_command.vault_key_version.generation == 1
    assert first_command.domain_key_version.generation == 1
    assert byte_size(first_command.vault_key_wrapper.kdf_salt) == 16
    assert is_binary(first_command.vault_key_wrapper.wrapped_key)
    assert is_binary(first_command.domain_key_version.wrapped_key)
    assert is_binary(first_command.domain_dedup_key_wrapper.wrapped_key)

    assert first_command.account.id == first_command.person.id
    assert first_command.principal.account_id == first_command.account.id
    assert first_command.vault.id == first_command.account.id
    assert first_command.membership.principal_id == first_command.principal.id
    assert first_command.membership.vault_id == first_command.vault.id
    assert first_command.key_domain.vault_id == first_command.vault.id

    assert first_command.credential.secret_hash == "hash:" <> first_password
    assert second_command.credential.secret_hash == "hash:" <> second_password
    assert_receive {:password_hash, ^first_password}
    assert_receive {:derive_kek, ^first_password, _salt, _params}
    assert_receive {:password_hash, ^second_password}
    assert_receive {:derive_kek, ^second_password, _salt, _params}
  end

  test "bootstrap task rejects positional password arguments without echoing them" do
    password = "CANARY_BOOTSTRAP_PASSWORD"
    Mix.Task.reenable("singularity.bootstrap_owner")

    output =
      capture_io(:stderr, fn ->
        assert_raise Mix.Error, ~r/password arguments are forbidden/, fn ->
          Mix.Tasks.Singularity.BootstrapOwner.run([password])
        end
      end)

    refute output =~ password
    refute inspect(Process.info(self(), :dictionary)) =~ password
  end

  test "bootstrap task source accepts secrets only through prompt or an inherited descriptor" do
    path =
      Path.expand(
        "../../../lib/mix/tasks/singularity.bootstrap_owner.ex",
        __DIR__
      )

    source = File.read!(path)

    assert source =~ ":io.get_password"
    assert source =~ "--password-fd"
    refute source =~ "--password "
  end

  defp postgres_adapters do
    %{
      repository: Singularity.Storage.Postgres.IdentityRepository,
      repository_context: Singularity.Storage.MigrationRepo,
      password_hasher: Singularity.Storage.Crypto.Argon2PasswordHasher,
      password_hasher_context: %{
        version: 1,
        t_cost: 1,
        m_cost: 8,
        parallelism: 1
      },
      key_deriver: Singularity.Storage.Crypto.Argon2KeyDeriver,
      key_wrapper: Singularity.Storage.Crypto.KeyWrapper,
      id_generator: &Ecto.UUID.generate/0,
      random_bytes: &:crypto.strong_rand_bytes/1,
      vault_kdf_params: %{
        version: 1,
        t_cost: 1,
        m_cost: 8,
        parallelism: 1
      },
      initial_capabilities: ["asset.read", "asset.write", "vault.unlock"]
    }
  end

  defp credential_verifier(account_id) do
    Singularity.Storage.Fixtures.with_owner(fn ->
      %{rows: [[verifier]]} =
        Ecto.Adapters.SQL.query!(
          Singularity.Storage.MigrationRepo,
          "SELECT verifier FROM identity.credentials WHERE account_id = $1",
          [Ecto.UUID.dump!(account_id)],
          log: false
        )

      verifier
    end)
  end

  defp credential_verifier_for_login(normalized_login) do
    Singularity.Storage.Fixtures.with_owner(fn ->
      %{rows: [[verifier]]} =
        Ecto.Adapters.SQL.query!(
          Singularity.Storage.MigrationRepo,
          "SELECT verifier FROM identity.credentials WHERE normalized_login = $1",
          [normalized_login],
          log: false
        )

      verifier
    end)
  end

  defp migration_database_url do
    config =
      Application.fetch_env!(
        :singularity_storage,
        Singularity.Storage.MigrationRepo
      )

    query =
      URI.encode_query(%{
        "port" => Keyword.fetch!(config, :port),
        "socket_dir" => Keyword.fetch!(config, :socket_dir)
      })

    username = config |> Keyword.fetch!(:username) |> URI.encode_www_form()
    database = config |> Keyword.fetch!(:database) |> URI.encode_www_form()

    "postgresql://#{username}@localhost/#{database}?#{query}"
  end

  defp umbrella_root do
    Path.expand("../../../../..", __DIR__)
  end

  defp run_bootstrap_task(password_file) do
    script = """
    exec 3<"$SINGULARITY_PASSWORD_FILE"
    exec mix singularity.bootstrap_owner --password-fd 3
    """

    System.cmd("bash", ["-c", script],
      cd: umbrella_root(),
      env: [
        {"MIX_ENV", "test"},
        {"SINGULARITY_MIGRATION_DATABASE_URL", migration_database_url()},
        {"SINGULARITY_PASSWORD_FILE", password_file}
      ],
      stderr_to_stdout: true
    )
  end

  defp aggregate_counts(owner) do
    Singularity.Storage.Fixtures.with_owner(fn ->
      %{rows: [row]} =
        Ecto.Adapters.SQL.query!(
          Singularity.Storage.MigrationRepo,
          """
          SELECT
            (SELECT count(*) FROM identity.principals
             WHERE id = $1 AND account_id = $2 AND kind = 'owner'),
            (SELECT count(*) FROM core.vaults
             WHERE id = $3 AND kind = 'personal'),
            (SELECT count(*) FROM core.vault_members
             WHERE principal_id = $1 AND vault_id = $3),
            (SELECT count(*) FROM core.key_domains WHERE vault_id = $3),
            (SELECT count(*) FROM core.vault_key_versions WHERE vault_id = $3),
            (SELECT count(*) FROM core.vault_key_wrappers WHERE vault_id = $3),
            (SELECT count(*) FROM core.domain_key_versions WHERE vault_id = $3),
            (SELECT count(*) FROM core.domain_dedup_key_wrappers WHERE vault_id = $3)
          """,
          [
            Ecto.UUID.dump!(owner.principal_id),
            Ecto.UUID.dump!(owner.account_id),
            Ecto.UUID.dump!(owner.vault_id)
          ],
          log: false
        )

      [
        owner_principals,
        personal_vaults,
        memberships,
        key_domains,
        vault_key_versions,
        vault_key_wrappers,
        domain_key_versions,
        dedup_wrappers
      ] = row

      %{
        owner_principals: owner_principals,
        personal_vaults: personal_vaults,
        memberships: memberships,
        key_domains: key_domains,
        vault_key_versions: vault_key_versions,
        vault_key_wrappers: vault_key_wrappers,
        domain_key_versions: domain_key_versions,
        dedup_wrappers: dedup_wrappers
      }
    end)
  end
end
