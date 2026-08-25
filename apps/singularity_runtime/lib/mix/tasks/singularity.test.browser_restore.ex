defmodule Mix.Tasks.Singularity.Test.BrowserRestore do
  use Mix.Task

  import Bitwise

  alias Singularity.Core.Error
  alias Singularity.Runtime.BackupKeyLease
  alias Singularity.Runtime.IntegrityAudit
  alias Singularity.Runtime.RestoreAuthenticator
  alias Singularity.Runtime.RestoreIntegrityLease
  alias Singularity.Runtime.RestoreVault
  alias Singularity.Storage.Backup.BundleReader
  alias Singularity.Storage.Backup.IntegrityAudit, as: StorageIntegrityAudit
  alias Singularity.Storage.Backup.LocalDestination
  alias Singularity.Storage.Backup.LogicalBundleVerifier
  alias Singularity.Storage.Backup.Reconciler
  alias Singularity.Storage.Backup.Restorer
  alias Singularity.Storage.Crypto.Argon2KeyDeriver
  alias Singularity.Storage.Crypto.Argon2PasswordHasher
  alias Singularity.Storage.Crypto.BackupKeyDeriver
  alias Singularity.Storage.Crypto.ChunkedAEAD
  alias Singularity.Storage.Crypto.KeyWrapper
  alias Singularity.Storage.Crypto.RecoveredVaultKey
  alias Singularity.Storage.MigrationRepo
  alias Singularity.Storage.SafeSQL
  alias Singularity.Storage.TestEnvironment

  @failure_message "notes browser restore failed"
  @web_endpoint :"Elixir.Singularity.Web.Endpoint"
  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  @playwright_run_id ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
  @storage_keys [
    Singularity.Storage.MigrationRepo,
    Singularity.Storage.RequestRepo,
    Singularity.Storage.PreAuthRepo,
    Singularity.Storage.DispatcherRepo,
    Singularity.Storage.WorkerRepo,
    :backup_root,
    :storage_root
  ]
  @runtime_keys [:start_infrastructure, :maintenance_mode]
  @repositories [
    Singularity.Storage.MigrationRepo,
    Singularity.Storage.RequestRepo,
    Singularity.Storage.PreAuthRepo,
    Singularity.Storage.DispatcherRepo,
    Singularity.Storage.WorkerRepo
  ]

  defmodule MaintenanceMode do
    @moduledoc false

    alias Singularity.Core.Error

    def require_maintenance(true), do: :ok
    def require_maintenance(_mode), do: {:error, Error.new(:conflict)}
  end

  defmodule Destination do
    @moduledoc false

    alias Singularity.Core.Error
    alias Singularity.Storage.Backup.LocalDestination
    alias Singularity.Storage.SafeSQL

    def normalize(context, operator_path), do: LocalDestination.normalize(context, operator_path)
    def reader_source(context, reference), do: LocalDestination.reader_source(context, reference)

    def require_empty(%{storage_root: storage_root}, repo) do
      with {:ok, []} <- File.ls(storage_root),
           {:ok, %{rows: [[false]]}} <- empty_database(repo) do
        :ok
      else
        {:ok, _nonempty} -> {:error, Error.new(:conflict)}
        {:error, _reason} -> {:error, Error.new(:storage_unavailable, retryable?: true)}
        _failure -> {:error, Error.new(:conflict)}
      end
    end

    defp empty_database(repo) do
      repo.transaction(fn ->
        SafeSQL.query!(repo, "SET LOCAL ROLE singularity_table_owner", [], log: false)

        SafeSQL.query!(
          repo,
          """
          SELECT EXISTS (
            SELECT 1 FROM identity.people
            UNION ALL SELECT 1 FROM core.vaults
            UNION ALL SELECT 1 FROM content.resources
            UNION ALL SELECT 1 FROM content.resource_versions
            UNION ALL SELECT 1 FROM content.note_versions
            UNION ALL SELECT 1 FROM content.note_conflicts
            UNION ALL SELECT 1 FROM content.note_search_documents
            UNION ALL SELECT 1 FROM audit.events
          )
          """,
          [],
          log: false
        )
      end)
    rescue
      _exception -> {:error, :unavailable}
    end
  end

  @impl Mix.Task
  def run(arguments), do: __run__(arguments, default_run_dependencies())

  @doc false
  def __run__(arguments, dependencies) when is_list(arguments) and is_map(dependencies) do
    result =
      try do
        with :ok <- require_test_environment(),
             :ok <- dependencies.load_application_config.(),
             {:ok, state} <- dependencies.load_state.(),
             {:ok, request} <- parse(arguments, state),
             {:ok, expected} <- dependencies.load_expected.(request.expected_snapshot),
             :ok <- dependencies.execute.(request, expected) do
          :ok
        else
          _failure -> :error
        end
      rescue
        _exception -> :error
      catch
        _kind, _reason -> :error
      end

    case result do
      :ok ->
        Mix.shell().info("notes_browser_restore_ok=true")

      :error ->
        Mix.raise(@failure_message)
    end
  end

  def __run__(_arguments, _dependencies), do: Mix.raise(@failure_message)

  @doc false
  def parse(arguments, state) when is_list(arguments) and is_map(state) do
    if forbidden_secret_argument?(arguments) do
      invalid()
    else
      {options, positional, invalid_options} =
        OptionParser.parse(arguments,
          strict: [source: :string, expected: :string, passphrase_fd: :integer]
        )

      with [] <- positional,
           [] <- invalid_options,
           [:source, :expected, :passphrase_fd] <- Keyword.keys(options),
           [source] <- Keyword.get_values(options, :source),
           [expected] <- Keyword.get_values(options, :expected),
           [passphrase_fd] when is_integer(passphrase_fd) and passphrase_fd >= 0 <-
             Keyword.get_values(options, :passphrase_fd),
           {:ok, public} <- public_state(state),
           :ok <- canonical_regular(source, 0o777),
           :ok <- canonical_regular(expected, 0o600),
           true <- contained?(public.backup_root, source) do
        {:ok,
         %{
           source: source,
           expected_snapshot: expected,
           passphrase_fd: passphrase_fd,
           backup_root: public.backup_root,
           run_id: public.run_id,
           primary_vault_id: public.primary_vault_id
         }}
      else
        _invalid -> invalid()
      end
    end
  rescue
    _exception -> invalid()
  end

  def parse(_arguments, _state), do: invalid()

  @doc false
  def load_expected(path) when is_binary(path) do
    with :ok <- canonical_regular(path, 0o600),
         {:ok, decoded} <- JSON.decode(File.read!(path)),
         {:ok, expected} <- decode_expected(decoded) do
      {:ok, expected}
    else
      _invalid -> invalid()
    end
  rescue
    _exception -> invalid()
  end

  def load_expected(_path), do: invalid()

  @doc false
  def __execute__(request, expected, adapters)
      when is_map(request) and is_map(expected) and is_map(adapters) do
    with {:ok, passphrase} <- adapters.read_descriptor_once.(request.passphrase_fd),
         {:ok, passphrase} <- required_secret(passphrase) do
      destination = adapters.allocate.()

      try do
        :ok = validate_expected_vault(request, expected)
        :ok = adapters.assert_no_listener.()
        :ok = adapters.create.(destination)
        :ok = adapters.assert_no_listener.()
        {:ok, restored} = adapters.restore.(destination, request, passphrase)
        :ok = adapters.assert_no_listener.()
        :ok = adapters.compare.(destination, restored, expected)
        :ok = adapters.assert_no_listener.()
        :ok
      after
        adapters.drop.(destination)
      end
    else
      _invalid -> raise @failure_message
    end
  end

  def __execute__(_request, _expected, _adapters), do: raise(@failure_message)

  defp default_run_dependencies do
    %{
      execute: fn request, expected ->
        previous_environment = snapshot_environment()
        execute_with_environment(request, expected, previous_environment)
      end,
      load_application_config: &load_application_config/0,
      load_expected: &load_expected/1,
      load_state: &load_state/0
    }
  end

  defp execute_with_environment(request, expected, previous_environment) do
    try do
      __execute__(request, expected, default_adapters())
    after
      stop_runtime_and_repositories()
      restore_environment(previous_environment)
    end
  end

  defp default_adapters do
    %{
      allocate: &TestEnvironment.allocate!/0,
      assert_no_listener: &assert_no_listener/0,
      create: &create_destination/1,
      drop: &drop_destination/1,
      read_descriptor_once: &read_descriptor_once/1,
      restore: &restore_destination/3,
      compare: &compare_destination/3
    }
  end

  defp create_destination(destination) do
    stop_runtime_and_repositories()
    Application.put_env(:singularity_runtime, :maintenance_mode, true)
    Application.put_env(:singularity_runtime, :start_infrastructure, false)
    TestEnvironment.create!(destination)
    stop_repositories()
    {:ok, _repo} = MigrationRepo.start_link(pool_size: 2)
    :ok
  end

  @doc false
  def __assert_no_listener__, do: assert_no_listener()

  defp assert_no_listener do
    endpoint = Process.whereis(@web_endpoint)

    web_started? =
      Enum.any?(Application.started_applications(), fn {application, _description, _version} ->
        application == :singularity_web
      end)

    if is_nil(endpoint) and not web_started?, do: :ok, else: Mix.raise(@failure_message)
  end

  defp validate_expected_vault(
         %{primary_vault_id: vault_id},
         %{vault_id: vault_id}
       )
       when is_binary(vault_id) do
    case Ecto.UUID.cast(vault_id) do
      {:ok, ^vault_id} -> :ok
      _invalid -> Mix.raise(@failure_message)
    end
  end

  defp validate_expected_vault(_request, _expected), do: Mix.raise(@failure_message)

  defp drop_destination(destination) do
    stop_runtime_and_repositories()
    TestEnvironment.force_drop!(destination)
  end

  defp restore_destination(destination, request, passphrase) do
    Application.put_env(:singularity_storage, :backup_root, request.backup_root)
    source = Path.relative_to(request.source, request.backup_root)
    password = Mix.Tasks.Singularity.Test.Browser.derive_owner_password(request.run_id, :primary)

    RestoreVault.run(restore_context(destination, request.backup_root), %{
      source: source,
      passphrase: passphrase,
      new_password: password
    })
  end

  defp restore_context(destination, backup_root) do
    bootstrap = Application.fetch_env!(:singularity_runtime, :bootstrap_owner)
    object_storage = Singularity.Runtime.StorageAdapter.configured()
    destination_context = %{backup_root: backup_root, storage_root: destination.storage_root}

    authenticator = %{
      backup_cipher: ChunkedAEAD,
      backup_key_deriver: BackupKeyDeriver,
      backup_key_lease: BackupKeyLease,
      bundle_reader: BundleReader,
      destination: {LocalDestination, %{backup_root: backup_root}},
      logical_verifier: LogicalBundleVerifier,
      recovered_vault_key: RecoveredVaultKey,
      restore_crypto_adapter: BackupKeyLease.StorageAdapter,
      restore_key_ttl_ms: :timer.minutes(5)
    }

    restorer = %{
      integrity_issuer: RestoreIntegrityLease,
      integrity_ttl_ms: :timer.minutes(5),
      key_deriver: Argon2KeyDeriver,
      key_wrapper: KeyWrapper,
      migration_repo: MigrationRepo,
      object_storage: object_storage,
      password_hasher: Argon2PasswordHasher,
      password_hasher_context: Map.fetch!(bootstrap, :password_hasher_context),
      random_bytes: &:crypto.strong_rand_bytes/1,
      recovered_vault_key: RecoveredVaultKey,
      vault_kdf_params: Map.fetch!(bootstrap, :vault_kdf_params)
    }

    integrity = %{
      audit: {StorageIntegrityAudit, MigrationRepo},
      ciphertext_auditor: StorageIntegrityAudit,
      object_storage: object_storage,
      restore_integrity_lease: RestoreIntegrityLease,
      search_rebuilder: {StorageIntegrityAudit, MigrationRepo}
    }

    %{
      authenticator: {RestoreAuthenticator, authenticator},
      destination: {Destination, destination_context},
      integrity: {IntegrityAudit, integrity},
      maintenance_mode: {MaintenanceMode, true},
      migration_repo: MigrationRepo,
      reconciler: {Reconciler, MigrationRepo},
      restorer: {Restorer, restorer}
    }
  end

  defp compare_destination(_destination, %{manifest_id: manifest_id}, expected)
       when is_binary(manifest_id) do
    case MigrationRepo.transaction(fn ->
           SafeSQL.query!(MigrationRepo, "SET LOCAL ROLE singularity_table_owner", [], log: false)
           actual = snapshot_notes(expected.vault_id)

           if actual == expected.notes and
                exact_exports?(actual, expected.notes, expected.vault_id) do
             :ok
           else
             MigrationRepo.rollback(:mismatch)
           end
         end) do
      {:ok, :ok} -> :ok
      _failure -> raise @failure_message
    end
  end

  defp compare_destination(_destination, _restored, _expected), do: raise(@failure_message)

  defp snapshot_notes(vault_id) do
    vault = Ecto.UUID.dump!(vault_id)

    %{rows: resources} =
      SafeSQL.query!(
        MigrationRepo,
        """
        SELECT id::text, current_version_id::text, title, deleted_at IS NOT NULL
        FROM content.resources
        WHERE vault_id = $1 AND kind = 'note'
        ORDER BY id
        """,
        [vault],
        log: false
      )

    Enum.map(resources, fn [resource_id, current_version_id, title, deleted] ->
      versions = note_versions(vault, resource_id)
      current = Enum.find(versions, &(&1.resource_version_id == current_version_id))

      %{
        resource_id: resource_id,
        current_version_id: current_version_id,
        title: title,
        markdown: Map.fetch!(current, :markdown),
        deleted: deleted,
        versions: versions,
        conflicts: note_conflicts(vault, resource_id),
        export: export_expectation(title, Map.fetch!(current, :markdown))
      }
    end)
  end

  defp note_versions(vault, resource_id) do
    %{rows: rows} =
      SafeSQL.query!(
        MigrationRepo,
        """
        SELECT
          note.resource_version_id::text,
          version.revision,
          note.parent_version_id::text,
          note.merge_parent_version_id::text,
          note.title,
          note.markdown
        FROM content.note_versions AS note
        JOIN content.resource_versions AS version
          ON version.id = note.resource_version_id
         AND version.resource_id = note.resource_id
         AND version.vault_id = note.vault_id
        WHERE note.vault_id = $1 AND note.resource_id = $2
        ORDER BY note.resource_version_id
        """,
        [vault, Ecto.UUID.dump!(resource_id)],
        log: false
      )

    Enum.map(rows, fn [id, revision, parent, merge_parent, title, markdown] ->
      %{
        resource_version_id: id,
        revision: revision,
        parent_version_id: parent,
        merge_parent_version_id: merge_parent,
        title: title,
        markdown: markdown
      }
    end)
  end

  defp note_conflicts(vault, resource_id) do
    %{rows: rows} =
      SafeSQL.query!(
        MigrationRepo,
        """
        SELECT
          id::text,
          base_version_id::text,
          canonical_version_id::text,
          competing_version_id::text,
          state,
          resolution_version_id::text
        FROM content.note_conflicts
        WHERE vault_id = $1 AND resource_id = $2
        ORDER BY id
        """,
        [vault, Ecto.UUID.dump!(resource_id)],
        log: false
      )

    Enum.map(rows, fn [id, base, canonical, competing, state, resolution] ->
      %{
        conflict_id: id,
        base_version_id: base,
        canonical_version_id: canonical,
        competing_version_id: competing,
        state: state,
        resolution_version_id: resolution
      }
    end)
  end

  defp exact_exports?(actual, expected, vault_id) do
    actual == expected and
      Enum.all?(actual, fn note ->
        %{rows: rows} =
          SafeSQL.query!(
            MigrationRepo,
            """
            SELECT resource_id::text, resource_version_id::text, title, markdown
            FROM content.note_search_documents
            WHERE vault_id = $1 AND resource_id = $2
            """,
            [Ecto.UUID.dump!(vault_id), Ecto.UUID.dump!(note.resource_id)],
            log: false
          )

        rows == [[note.resource_id, note.current_version_id, note.title, note.markdown]]
      end)
  end

  defp export_expectation(title, markdown) do
    filename = title <> ".md"

    %{
      bytes: markdown,
      content_type: "text/markdown; charset=utf-8",
      content_disposition:
        ~s(attachment; filename="#{filename}"; filename*=UTF-8''#{URI.encode(filename, &URI.char_unreserved?/1)}),
      x_content_type_options: "nosniff"
    }
  end

  defp decode_expected(decoded) do
    with true <- exact?(decoded, ~w[version vault_id notes]),
         1 <- decoded["version"],
         true <- uuid?(decoded["vault_id"]),
         notes when is_list(notes) and notes != [] <- decoded["notes"],
         {:ok, notes} <- map_all(notes, &decode_note/1),
         true <- unique?(notes, :resource_id) do
      {:ok,
       %{version: 1, vault_id: decoded["vault_id"], notes: Enum.sort_by(notes, & &1.resource_id)}}
    else
      _invalid -> invalid()
    end
  end

  defp decode_note(value) do
    keys = ~w[resource_id current_version_id title markdown deleted versions conflicts export]

    with true <- exact?(value, keys),
         true <- uuid?(value["resource_id"]),
         true <- uuid?(value["current_version_id"]),
         true <- safe_text?(value["title"], 255, false),
         true <- safe_text?(value["markdown"], 1_048_576, true),
         true <- is_boolean(value["deleted"]),
         versions when is_list(versions) and versions != [] <- value["versions"],
         conflicts when is_list(conflicts) <- value["conflicts"],
         {:ok, versions} <- map_all(versions, &decode_version/1),
         {:ok, conflicts} <- map_all(conflicts, &decode_conflict/1),
         true <- unique?(versions, :resource_version_id),
         true <- unique?(conflicts, :conflict_id),
         true <- Enum.any?(versions, &(&1.resource_version_id == value["current_version_id"])),
         {:ok, export} <- decode_export(value["export"], value["markdown"]) do
      {:ok,
       %{
         resource_id: value["resource_id"],
         current_version_id: value["current_version_id"],
         title: value["title"],
         markdown: value["markdown"],
         deleted: value["deleted"],
         versions: Enum.sort_by(versions, & &1.resource_version_id),
         conflicts: Enum.sort_by(conflicts, & &1.conflict_id),
         export: export
       }}
    else
      _invalid -> invalid()
    end
  end

  defp decode_version(value) do
    keys =
      ~w[resource_version_id revision parent_version_id merge_parent_version_id title markdown]

    with true <- exact?(value, keys),
         true <- uuid?(value["resource_version_id"]),
         revision when is_integer(revision) and revision >= 0 <- value["revision"],
         true <- optional_uuid?(value["parent_version_id"]),
         true <- optional_uuid?(value["merge_parent_version_id"]),
         true <- safe_text?(value["title"], 255, false),
         true <- safe_text?(value["markdown"], 1_048_576, true),
         true <- valid_parents?(revision, value) do
      {:ok,
       %{
         resource_version_id: value["resource_version_id"],
         revision: revision,
         parent_version_id: value["parent_version_id"],
         merge_parent_version_id: value["merge_parent_version_id"],
         title: value["title"],
         markdown: value["markdown"]
       }}
    else
      _invalid -> invalid()
    end
  end

  defp decode_conflict(value) do
    keys =
      ~w[conflict_id base_version_id canonical_version_id competing_version_id state resolution_version_id]

    with true <- exact?(value, keys),
         true <- uuid?(value["conflict_id"]),
         true <- uuid?(value["base_version_id"]),
         true <- uuid?(value["canonical_version_id"]),
         true <- uuid?(value["competing_version_id"]),
         true <- value["state"] in ["open", "resolved"],
         true <- optional_uuid?(value["resolution_version_id"]),
         true <-
           (value["state"] == "resolved" and is_binary(value["resolution_version_id"])) or
             (value["state"] == "open" and is_nil(value["resolution_version_id"])) do
      {:ok,
       %{
         conflict_id: value["conflict_id"],
         base_version_id: value["base_version_id"],
         canonical_version_id: value["canonical_version_id"],
         competing_version_id: value["competing_version_id"],
         state: value["state"],
         resolution_version_id: value["resolution_version_id"]
       }}
    else
      _invalid -> invalid()
    end
  end

  defp decode_export(value, markdown) do
    keys = ~w[bytes content_type content_disposition x_content_type_options]

    with true <- exact?(value, keys),
         ^markdown <- value["bytes"],
         "text/markdown; charset=utf-8" <- value["content_type"],
         disposition when is_binary(disposition) and byte_size(disposition) <= 1024 <-
           value["content_disposition"],
         "nosniff" <- value["x_content_type_options"] do
      {:ok,
       %{
         bytes: markdown,
         content_type: "text/markdown; charset=utf-8",
         content_disposition: disposition,
         x_content_type_options: "nosniff"
       }}
    else
      _invalid -> invalid()
    end
  end

  defp public_state(state) do
    with true <- exact?(state, ~w[version run_id backup_root owners]),
         1 <- state["version"],
         run_id when is_binary(run_id) <- state["run_id"],
         true <- Regex.match?(@playwright_run_id, run_id),
         backup_root when is_binary(backup_root) <- state["backup_root"],
         true <- canonical_directory?(backup_root),
         owners when is_map(owners) <- state["owners"],
         true <- exact?(owners, ~w[primary secondary]),
         primary when is_map(primary) <- owners["primary"],
         secondary when is_map(secondary) <- owners["secondary"],
         :ok <- valid_owner(primary, "owner@singularity.local"),
         :ok <- valid_owner(secondary, "secondary-owner@singularity.local"),
         true <- primary["vault_id"] != secondary["vault_id"] do
      {:ok, %{run_id: run_id, backup_root: backup_root, primary_vault_id: primary["vault_id"]}}
    else
      _invalid -> invalid()
    end
  end

  defp valid_owner(owner, login) do
    if exact?(owner, ~w[login account_id principal_id vault_id]) and owner["login"] == login and
         Enum.all?(~w[account_id principal_id vault_id], &uuid?(owner[&1])) do
      :ok
    else
      invalid()
    end
  end

  defp load_state do
    with {:ok, path} <- System.fetch_env("SINGULARITY_BROWSER_STATE_FILE"),
         :ok <- canonical_regular(path, 0o600),
         {:ok, state} <- JSON.decode(File.read!(path)),
         {:ok, _public} <- public_state(state) do
      {:ok, state}
    else
      _invalid -> invalid()
    end
  rescue
    _exception -> invalid()
  end

  defp canonical_regular(path, mode) when is_binary(path) and path != "" do
    with true <- Path.type(path) == :absolute and Path.expand(path) == path,
         {:ok, %File.Stat{type: :regular, mode: actual_mode}} <- File.lstat(path),
         true <- mode == 0o777 or (actual_mode &&& 0o777) == mode do
      :ok
    else
      _invalid -> invalid()
    end
  end

  defp canonical_regular(_path, _mode), do: invalid()

  defp canonical_directory?(path) when is_binary(path) do
    Path.type(path) == :absolute and Path.expand(path) == path and
      match?({:ok, %File.Stat{type: :directory}}, File.lstat(path))
  end

  defp canonical_directory?(_path), do: false

  defp contained?(root, path) do
    relative = Path.relative_to(path, root)
    Path.type(relative) == :relative and relative != "." and ".." not in Path.split(relative)
  end

  defp read_descriptor_once(0) do
    case IO.binread(:stdio, :eof) do
      secret when is_binary(secret) -> required_secret(secret)
      _unavailable -> invalid()
    end
  end

  defp read_descriptor_once(descriptor) when is_integer(descriptor) and descriptor > 0 do
    case File.read("/proc/self/fd/#{descriptor}") do
      {:ok, secret} -> required_secret(secret)
      {:error, _reason} -> invalid()
    end
  end

  defp required_secret(secret) when is_binary(secret) do
    secret = strip_terminator(secret)
    if secret == "", do: invalid(), else: {:ok, secret}
  end

  defp required_secret(_secret), do: invalid()

  defp strip_terminator(secret) do
    cond do
      String.ends_with?(secret, "\r\n") -> binary_part(secret, 0, byte_size(secret) - 2)
      String.ends_with?(secret, "\n") -> binary_part(secret, 0, byte_size(secret) - 1)
      true -> secret
    end
  end

  defp forbidden_secret_argument?(arguments) do
    Enum.any?(arguments, fn
      "--passphrase" -> true
      "--password" -> true
      "--passphrase=" <> _secret -> true
      "--password=" <> _secret -> true
      _argument -> false
    end)
  end

  defp valid_parents?(0, %{
         "parent_version_id" => nil,
         "merge_parent_version_id" => nil
       }),
       do: true

  defp valid_parents?(revision, %{
         "parent_version_id" => parent,
         "merge_parent_version_id" => merge_parent
       })
       when revision > 0 and is_binary(parent),
       do: is_nil(merge_parent) or merge_parent != parent

  defp valid_parents?(_revision, _value), do: false

  defp map_all(values, decoder) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, decoded} ->
      case decoder.(value) do
        {:ok, item} -> {:cont, {:ok, [item | decoded]}}
        _invalid -> {:halt, invalid()}
      end
    end)
    |> case do
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      error -> error
    end
  end

  defp unique?(values, key),
    do:
      values |> Enum.map(&Map.fetch!(&1, key)) |> Enum.uniq() ==
        Enum.map(values, &Map.fetch!(&1, key))

  defp exact?(value, keys) when is_map(value),
    do: Map.keys(value) |> Enum.sort() == Enum.sort(keys)

  defp exact?(_value, _keys), do: false
  defp uuid?(value) when is_binary(value), do: Regex.match?(@uuid, value)
  defp uuid?(_value), do: false
  defp optional_uuid?(nil), do: true
  defp optional_uuid?(value), do: uuid?(value)

  defp safe_text?(value, maximum, blank?) when is_binary(value) do
    String.valid?(value) and byte_size(value) <= maximum and not String.contains?(value, <<0>>) and
      (blank? or String.trim(value) != "")
  end

  defp safe_text?(_value, _maximum, _blank?), do: false

  defp require_test_environment, do: if(Mix.env() == :test, do: :ok, else: invalid())

  defp load_application_config do
    Mix.Task.run("app.config")
    Singularity.Storage.RoleVerifier.verify!()
    :ok
  end

  defp stop_runtime_and_repositories do
    if Enum.any?(Application.started_applications(), fn {app, _description, _version} ->
         app == :singularity_runtime
       end) do
      Application.stop(:singularity_runtime)
    end

    stop_repositories()
  end

  defp stop_repositories do
    Enum.each(@repositories, fn repository ->
      case Process.whereis(repository) do
        nil -> :ok
        pid -> Supervisor.stop(pid)
      end
    end)
  end

  defp snapshot_environment do
    runtime = Enum.map(@runtime_keys, &{:singularity_runtime, &1})
    storage = Enum.map(@storage_keys, &{:singularity_storage, &1})

    Enum.map(runtime ++ storage, fn {application, key} ->
      {application, key, Application.fetch_env(application, key)}
    end)
  end

  defp restore_environment(snapshot) do
    Enum.each(snapshot, fn
      {application, key, {:ok, value}} -> Application.put_env(application, key, value)
      {application, key, :error} -> Application.delete_env(application, key)
    end)
  end

  defp invalid, do: {:error, :invalid}
end
