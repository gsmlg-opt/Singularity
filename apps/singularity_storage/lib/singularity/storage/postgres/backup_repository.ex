defmodule Singularity.Storage.Postgres.BackupRepository do
  @moduledoc false

  import Ecto.Query

  alias Ecto.Adapters.SQL
  alias Singularity.Core.Error
  alias Singularity.Storage.Postgres.UUID
  alias Singularity.Storage.Schema.Audit.BackupManifest
  alias Singularity.Storage.Schema.Audit.BackupManifestObject

  @kdf_domain "singularity.backup.bundle.v1"
  @classifications [:private, :sensitive, :restricted]
  @request_keys ~w[
    audit_event_id causation_id classification correlation_id custody_ref
    destination_ref manifest_id occurred_at outbox_event_id
    principal_authorization_epoch principal_id public_metadata
    vault_authorization_epoch vault_id
  ]a
  @reentry_keys ~w[
    audit_event_id correlation_id expected_custody_ref manifest_id occurred_at
    principal_id replacement_custody_ref vault_id
  ]a
  @cas_keys ~w[custody_ref manifest_id vault_id]a
  @load_keys ~w[manifest_id vault_id]a
  @seal_keys ~w[cut expected_custody_ref manifest_id sealed vault_id]a

  @postgres_constraint_codes [
    :integrity_constraint_violation,
    :restrict_violation,
    :not_null_violation,
    :foreign_key_violation,
    :unique_violation,
    :check_violation,
    :exclusion_violation
  ]

  @spec insert_pending_and_enqueue(module(), map()) ::
          {:ok, map()} | {:error, Error.t()}
  def insert_pending_and_enqueue(repo, command) when is_atom(repo) and is_map(command) do
    with {:ok, values} <- request_values(command),
         :ok <- scope_authority(repo, values.principal_id, values.vault_id),
         :ok <- exact_authorization_epochs(repo, values),
         :ok <- create_backup_request(repo, values),
         %BackupManifest{} = manifest <- manifest(repo, values) do
      public_manifest(manifest)
    else
      nil -> not_found()
      {:error, %Error{}} = error -> error
      _invalid -> storage_unavailable()
    end
  rescue
    error in [
      Ecto.Query.CastError,
      Ecto.ConstraintError,
      DBConnection.ConnectionError,
      Postgrex.Error
    ] ->
      {:error, database_error(error)}
  end

  def insert_pending_and_enqueue(_repo, _command), do: invalid()

  @spec load_waiting(module(), map()) :: {:ok, map()} | {:error, Error.t()}
  def load_waiting(repo, command) when is_atom(repo) and is_map(command) do
    with {:ok, lookup} <- lookup_values(command),
         {:ok, status} <- lock_status(repo, lookup) do
      case {status, manifest(repo, lookup)} do
        {"waiting_for_backup_key", %BackupManifest{} = manifest} -> public_manifest(manifest)
        {_other_status, %BackupManifest{}} -> conflict()
        {_status, nil} -> not_found()
      end
    else
      nil -> not_found()
      {:error, %Error{}} = error -> error
    end
  rescue
    error in [Ecto.Query.CastError, DBConnection.ConnectionError, Postgrex.Error] ->
      {:error, database_error(error)}
  end

  def load_waiting(_repo, _command), do: invalid()

  @spec replace_key_and_audit(module(), map()) :: {:ok, map()} | {:error, Error.t()}
  def replace_key_and_audit(repo, command) when is_atom(repo) and is_map(command) do
    with {:ok, values} <- reentry_values(command),
         :ok <- scope_authority(repo, values.principal_id, values.vault_id),
         {:ok, "waiting_for_backup_key"} <-
           transition(
             repo,
             "audit.replace_backup_custody($1, $2, $3, $4, $5, $6, $7, $8)",
             [
               uuid_param(values.manifest_id),
               uuid_param(values.vault_id),
               values.expected_custody_ref,
               values.replacement_custody_ref,
               uuid_param(values.audit_event_id),
               uuid_param(values.correlation_id),
               uuid_param(values.principal_id),
               values.occurred_at
             ]
           ),
         %BackupManifest{} = manifest <- manifest(repo, values) do
      public_manifest(manifest)
    else
      nil -> not_found()
      {:error, %Error{}} = error -> error
      _invalid -> storage_unavailable()
    end
  rescue
    error in [
      Ecto.Query.CastError,
      Ecto.ConstraintError,
      DBConnection.ConnectionError,
      Postgrex.Error
    ] ->
      {:error, database_error(error)}
  end

  def replace_key_and_audit(_repo, _command), do: invalid()

  @spec mark_pending(module(), map()) :: {:ok, map()} | {:error, Error.t()}
  def mark_pending(repo, command) when is_atom(repo) and is_map(command) do
    with {:ok, values} <- cas_values(command),
         {:ok, "pending"} <-
           transition(repo, "audit.activate_backup_manifest($1, $2, $3)", [
             uuid_param(values.manifest_id),
             uuid_param(values.vault_id),
             values.custody_ref
           ]),
         %BackupManifest{} = manifest <- manifest(repo, values) do
      public_manifest(manifest)
    else
      nil -> not_found()
      {:error, %Error{}} = error -> error
      _invalid -> storage_unavailable()
    end
  rescue
    error in [Ecto.Query.CastError, DBConnection.ConnectionError, Postgrex.Error] ->
      {:error, database_error(error)}
  end

  def mark_pending(_repo, _command), do: invalid()

  @spec load_pending(module(), map()) :: {:ok, map()} | {:error, Error.t()}
  def load_pending(repo, command) when is_atom(repo) and is_map(command) do
    with {:ok, values} <- lookup_values(command),
         {:ok, status} <-
           transition(repo, "audit.claim_backup_manifest($1, $2)", [
             uuid_param(values.manifest_id),
             uuid_param(values.vault_id)
           ]),
         true <- status in ~w[waiting_for_backup_key copying sealed],
         %BackupManifest{} = manifest <- manifest(repo, values) do
      public_manifest(manifest)
    else
      nil -> not_found()
      false -> conflict()
      {:error, %Error{}} = error -> error
      _invalid -> storage_unavailable()
    end
  rescue
    error in [Ecto.Query.CastError, DBConnection.ConnectionError, Postgrex.Error] ->
      {:error, database_error(error)}
  end

  def load_pending(_repo, _command), do: invalid()

  @spec mark_waiting_for_backup_key(module(), map()) ::
          {:ok, map()} | {:error, Error.t()}
  def mark_waiting_for_backup_key(repo, command) when is_atom(repo) and is_map(command) do
    with {:ok, values} <- cas_values(command),
         {:ok, "waiting_for_backup_key"} <-
           transition(repo, "audit.mark_backup_waiting($1, $2, $3)", [
             uuid_param(values.manifest_id),
             uuid_param(values.vault_id),
             values.custody_ref
           ]),
         %BackupManifest{} = manifest <- manifest(repo, values) do
      public_manifest(manifest)
    else
      nil -> not_found()
      {:error, %Error{}} = error -> error
      _invalid -> storage_unavailable()
    end
  rescue
    error in [Ecto.Query.CastError, DBConnection.ConnectionError, Postgrex.Error] ->
      {:error, database_error(error)}
  end

  def mark_waiting_for_backup_key(_repo, _command), do: invalid()

  @spec acknowledge_sealed(module(), map()) :: {:ok, map()} | {:error, Error.t()}
  def acknowledge_sealed(repo, command) when is_atom(repo) and is_map(command) do
    with {:ok, values} <- seal_values(command) do
      repo.transaction(fn -> acknowledge_in_transaction(repo, values) end)
      |> transaction_result()
    end
  rescue
    error in [
      Ecto.Query.CastError,
      Ecto.ConstraintError,
      DBConnection.ConnectionError,
      Postgrex.Error
    ] ->
      {:error, database_error(error, :backup_invalid)}
  end

  def acknowledge_sealed(_repo, _command), do: invalid()

  defp acknowledge_in_transaction(repo, values) do
    case lock_status(repo, values) do
      nil ->
        repo.rollback(Error.new(:not_found))

      {:error, %Error{} = error} ->
        repo.rollback(error)

      {:ok, _status} ->
        acknowledge_locked_manifest(repo, manifest(repo, values), values)
    end
  end

  defp acknowledge_locked_manifest(repo, nil, _values),
    do: repo.rollback(Error.new(:not_found))

  defp acknowledge_locked_manifest(repo, %BackupManifest{status: :sealed} = manifest, values) do
    if sealed_replay?(repo, manifest, values) do
      unwrap_or_rollback(repo, public_manifest(manifest))
    else
      repo.rollback(Error.new(:conflict))
    end
  end

  defp acknowledge_locked_manifest(
         repo,
         %BackupManifest{status: :copying, custody_ref: custody_ref} = manifest,
         values
       )
       when custody_ref == values.expected_custody_ref do
    with true <- manifest.destination_ref == values.destination_ref,
         {:ok, "sealed"} <-
           transition(repo, "audit.seal_backup_manifest($1, $2, $3, $4, $5, $6, $7, $8)", [
             uuid_param(values.manifest_id),
             uuid_param(values.vault_id),
             values.expected_custody_ref,
             uuid_param(values.snapshot_id),
             values.outbox_high_water_mark,
             values.manifest_hash,
             values.manifest_tag,
             inventory_json(values.inventory)
           ]),
         %BackupManifest{} = sealed <- manifest(repo, values) do
      unwrap_or_rollback(repo, public_manifest(sealed))
    else
      false -> repo.rollback(Error.new(:backup_invalid))
      {:error, %Error{} = error} -> repo.rollback(error)
      _invalid -> repo.rollback(Error.new(:backup_invalid))
    end
  end

  defp acknowledge_locked_manifest(repo, %BackupManifest{}, _values),
    do: repo.rollback(Error.new(:conflict))

  defp inventory_json(inventory) do
    Enum.map(inventory, fn entry ->
      %{
        "asset_object_id" => entry.asset_object_id,
        "ciphertext_byte_size" => entry.ciphertext_byte_size,
        "ciphertext_hash" => Base.encode64(entry.ciphertext_hash),
        "classification" => Atom.to_string(entry.classification),
        "id" => Ecto.UUID.generate(),
        "inventory_position" => entry.inventory_position,
        "storage_ref" => entry.storage_ref,
        "vault_id" => entry.vault_id
      }
    end)
  end

  defp sealed_replay?(repo, manifest, values) do
    manifest.custody_ref == values.expected_custody_ref and
      manifest.destination_ref == values.destination_ref and
      manifest.snapshot_id == values.snapshot_id and
      manifest.outbox_high_water == values.outbox_high_water_mark and
      manifest.manifest_hash == values.manifest_hash and
      manifest.manifest_tag == values.manifest_tag and
      stored_inventory(repo, values.manifest_id) == values.inventory
  end

  defp stored_inventory(repo, manifest_id) do
    repo.all(
      from entry in BackupManifestObject,
        where: entry.manifest_id == ^manifest_id,
        order_by: [asc: entry.inventory_position]
    )
    |> Enum.map(fn entry ->
      %{
        asset_object_id: entry.asset_object_id,
        ciphertext_byte_size: entry.ciphertext_byte_size,
        ciphertext_hash: entry.ciphertext_hash,
        classification: entry.classification,
        inventory_position: entry.inventory_position,
        storage_ref: entry.storage_ref,
        vault_id: entry.vault_id
      }
    end)
  end

  defp request_values(command) do
    with true <- exact_keys?(command, @request_keys),
         :ok <-
           UUID.validate([
             command.audit_event_id,
             command.causation_id,
             command.correlation_id,
             command.manifest_id,
             command.outbox_event_id,
             command.principal_id,
             command.vault_id
           ]),
         true <- command.classification in @classifications,
         true <- command.causation_id == command.manifest_id,
         true <-
           Enum.uniq([
             command.audit_event_id,
             command.correlation_id,
             command.manifest_id,
             command.outbox_event_id
           ])
           |> length() == 4,
         true <- nonempty?(command.custody_ref) and nonempty?(command.destination_ref),
         true <- non_neg_integer?(command.principal_authorization_epoch),
         true <- non_neg_integer?(command.vault_authorization_epoch),
         true <- match?(%DateTime{}, command.occurred_at),
         {:ok, crypto} <- public_crypto(command.public_metadata, command) do
      {:ok, Map.merge(command, crypto)}
    else
      _invalid -> invalid()
    end
  end

  defp public_crypto(
         %{
           "kdf" => %{
             "domain" => @kdf_domain,
             "parameters" => parameters,
             "salt" => encoded_salt
           },
           "recovery" => %{
             "binding" => %{
               "manifest_id" => manifest_id,
               "vault_id" => vault_id
             },
             "label" => "backup_recovery",
             "wrapper" => wrapper
           }
         } = metadata,
         command
       )
       when is_map(parameters) and is_binary(encoded_salt) and is_binary(wrapper) and
              wrapper != "" do
    with true <- Map.keys(metadata) |> Enum.sort() == ~w[kdf recovery],
         true <- Map.keys(metadata["kdf"]) |> Enum.sort() == ~w[domain parameters salt],
         true <- Map.keys(metadata["recovery"]) |> Enum.sort() == ~w[binding label wrapper],
         true <-
           Map.keys(metadata["recovery"]["binding"]) |> Enum.sort() == ~w[manifest_id vault_id],
         true <- manifest_id == command.manifest_id and vault_id == command.vault_id,
         true <- json_value?(parameters),
         {:ok, salt} <- Base.decode64(encoded_salt),
         true <- byte_size(salt) == 16,
         true <- Base.encode64(salt) == encoded_salt,
         version when is_integer(version) and version > 0 <- Map.get(parameters, "version") do
      {:ok,
       %{
         kdf_parameters: parameters,
         kdf_salt: salt,
         kdf_version: version,
         recovery_wrapper: wrapper
       }}
    else
      _invalid -> invalid()
    end
  end

  defp public_crypto(_metadata, _command), do: invalid()

  defp reentry_values(command) do
    with true <- exact_keys?(command, @reentry_keys),
         :ok <-
           UUID.validate([
             command.audit_event_id,
             command.correlation_id,
             command.manifest_id,
             command.principal_id,
             command.vault_id
           ]),
         true <-
           Enum.uniq([
             command.audit_event_id,
             command.correlation_id,
             command.manifest_id
           ])
           |> length() == 3,
         true <- nonempty?(command.expected_custody_ref),
         true <- nonempty?(command.replacement_custody_ref),
         true <- command.expected_custody_ref != command.replacement_custody_ref,
         true <- match?(%DateTime{}, command.occurred_at) do
      {:ok, command}
    else
      _invalid -> invalid()
    end
  end

  defp lookup_values(command) do
    with true <- exact_keys?(command, @load_keys),
         :ok <- UUID.validate([command.manifest_id, command.vault_id]) do
      {:ok, command}
    else
      _invalid -> invalid()
    end
  end

  defp cas_values(command) do
    with true <- exact_keys?(command, @cas_keys),
         :ok <- UUID.validate([command.manifest_id, command.vault_id]),
         true <- nonempty?(command.custody_ref) do
      {:ok, command}
    else
      _invalid -> invalid()
    end
  end

  defp seal_values(command) do
    with true <- exact_keys?(command, @seal_keys),
         :ok <- UUID.validate([command.manifest_id, command.vault_id]),
         true <- nonempty?(command.expected_custody_ref),
         {:ok, cut} <- cut_values(command.cut, command.vault_id),
         {:ok, sealed} <- sealed_values(command.sealed, command),
         {:ok, inventory} <- inventory_values(cut.object_inventory, command.vault_id) do
      {:ok,
       %{
         expected_custody_ref: command.expected_custody_ref,
         destination_ref: sealed.destination_ref,
         inventory: inventory,
         manifest_hash: sealed.manifest_hash,
         manifest_id: command.manifest_id,
         manifest_tag: sealed.manifest_tag,
         outbox_high_water_mark: cut.outbox_high_water_mark,
         path: sealed.path,
         snapshot_id: cut.snapshot_id,
         vault_id: command.vault_id
       }}
    else
      _invalid -> backup_invalid()
    end
  end

  defp cut_values(
         %{
           object_inventory: inventory,
           outbox_high_water_mark: high_water,
           snapshot_id: snapshot_id,
           vault_id: vault_id
         } = cut,
         expected_vault_id
       )
       when is_list(inventory) and is_integer(high_water) and high_water >= 0 do
    with true <-
           Map.keys(cut) |> Enum.sort() ==
             ~w[object_inventory outbox_high_water_mark snapshot_id vault_id]a,
         true <- vault_id == expected_vault_id,
         :ok <- UUID.validate([snapshot_id, vault_id]) do
      {:ok, cut}
    else
      _invalid -> backup_invalid()
    end
  end

  defp cut_values(_cut, _vault_id), do: backup_invalid()

  defp sealed_values(
         %{
           destination_ref: destination_ref,
           manifest_hash: <<_::binary-size(32)>>,
           manifest_id: manifest_id,
           manifest_tag: <<_::binary-size(16)>>,
           path: path
         } = sealed,
         command
       )
       when is_binary(destination_ref) and is_binary(path) do
    allowed_keys = ~w[destination_ref inventory manifest_hash manifest_id manifest_tag path]a

    with true <- Map.keys(sealed) |> Enum.sort() == allowed_keys,
         true <- manifest_id == command.manifest_id,
         true <- destination_ref != "" and path != "" do
      {:ok, sealed}
    else
      _invalid -> backup_invalid()
    end
  end

  defp sealed_values(_sealed, _command), do: backup_invalid()

  defp inventory_values(inventory, vault_id) do
    inventory
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, [], MapSet.new()}, fn {entry, expected_position},
                                                     {:ok, entries, object_ids} ->
      case inventory_entry(entry, vault_id, expected_position) do
        {:ok, normalized} ->
          if MapSet.member?(object_ids, normalized.asset_object_id) do
            {:halt, backup_invalid()}
          else
            {:cont,
             {:ok, [normalized | entries], MapSet.put(object_ids, normalized.asset_object_id)}}
          end

        {:error, %Error{}} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, entries, _object_ids} -> {:ok, Enum.reverse(entries)}
      {:error, %Error{}} = error -> error
    end
  end

  defp inventory_entry(
         %{
           asset_object_id: object_id,
           ciphertext_byte_size: byte_size,
           ciphertext_hash: <<_::binary-size(32)>> = hash,
           classification: classification,
           inventory_position: position,
           storage_ref: storage_ref,
           vault_id: vault_id
         },
         expected_vault_id,
         expected_position
       )
       when classification in @classifications and is_integer(byte_size) and byte_size >= 0 and
              is_binary(storage_ref) and storage_ref != "" and position == expected_position and
              vault_id == expected_vault_id do
    with :ok <- UUID.validate([object_id, vault_id]) do
      {:ok,
       %{
         asset_object_id: object_id,
         ciphertext_byte_size: byte_size,
         ciphertext_hash: hash,
         classification: classification,
         inventory_position: position,
         storage_ref: storage_ref,
         vault_id: vault_id
       }}
    end
  end

  defp inventory_entry(_entry, _vault_id, _position), do: backup_invalid()

  defp transition(repo, function, parameters) do
    dumped = Enum.map(parameters, &dump_transition_parameter/1)

    case SQL.query(repo, "SELECT #{function}", dumped, log: false) do
      {:ok, %{rows: [[nil]]}} -> nil
      {:ok, %{rows: [[status]]}} when is_binary(status) -> {:ok, status}
      {:error, %Postgrex.Error{postgres: %{code: :serialization_failure}}} -> conflict()
      {:error, %Postgrex.Error{} = error} -> {:error, database_error(error)}
      {:error, _reason} -> storage_unavailable()
    end
  end

  defp create_backup_request(repo, values) do
    parameters = [
      uuid_param(values.manifest_id),
      uuid_param(values.vault_id),
      Atom.to_string(values.classification),
      values.destination_ref,
      values.kdf_version,
      values.kdf_salt,
      values.kdf_parameters,
      values.recovery_wrapper,
      values.custody_ref,
      uuid_param(values.audit_event_id),
      uuid_param(values.outbox_event_id),
      uuid_param(values.principal_id),
      values.principal_authorization_epoch,
      values.vault_authorization_epoch,
      uuid_param(values.correlation_id),
      uuid_param(values.causation_id),
      values.occurred_at
    ]

    case SQL.query(
           repo,
           """
           SELECT audit.create_backup_request(
             $1, $2, $3, $4, $5, $6, $7, $8, $9,
             $10, $11, $12, $13, $14, $15, $16, $17
           )
           """,
           Enum.map(parameters, &dump_transition_parameter/1),
           log: false
         ) do
      {:ok, %{rows: [["waiting_for_backup_key"]]}} -> :ok
      {:ok, %{rows: [[nil]]}} -> {:error, Error.new(:forbidden)}
      {:error, %Postgrex.Error{} = error} -> {:error, database_error(error)}
      {:error, _reason} -> storage_unavailable()
      _invalid -> storage_unavailable()
    end
  end

  defp uuid_param(value), do: {:uuid, value}
  defp dump_transition_parameter({:uuid, value}), do: Ecto.UUID.dump!(value)
  defp dump_transition_parameter(value), do: value

  defp lock_status(repo, values) do
    transition(repo, "audit.lock_backup_manifest($1, $2)", [
      uuid_param(values.manifest_id),
      uuid_param(values.vault_id)
    ])
  end

  defp manifest(repo, values) do
    repo.one(
      from manifest in BackupManifest,
        where: manifest.id == ^values.manifest_id and manifest.vault_id == ^values.vault_id
    )
  end

  defp public_manifest(%BackupManifest{} = manifest) do
    with true <-
           manifest.status in [:pending, :waiting_for_backup_key, :copying, :sealed, :failed],
         true <- is_integer(manifest.kdf_version) and manifest.kdf_version > 0,
         true <- is_binary(manifest.kdf_salt) and byte_size(manifest.kdf_salt) == 16,
         true <- is_map(manifest.kdf_parameters),
         true <- Map.get(manifest.kdf_parameters, "version") == manifest.kdf_version,
         true <- is_binary(manifest.recovery_wrapper) and manifest.recovery_wrapper != "",
         true <- is_binary(manifest.custody_ref) and manifest.custody_ref != "" do
      {:ok,
       %{
         backup_key_lease_id: manifest.custody_ref,
         classification: manifest.classification,
         destination_ref: manifest.destination_ref,
         id: manifest.id,
         kdf: %{
           "domain" => @kdf_domain,
           "parameters" => manifest.kdf_parameters,
           "salt" => Base.encode64(manifest.kdf_salt)
         },
         outbox_high_water_mark: manifest.outbox_high_water,
         recovery: %{
           "binding" => %{
             "manifest_id" => manifest.id,
             "vault_id" => manifest.vault_id
           },
           "label" => "backup_recovery",
           "wrapper" => manifest.recovery_wrapper
         },
         sealed_at: manifest.sealed_at,
         snapshot_id: manifest.snapshot_id,
         status: manifest.status,
         vault_id: manifest.vault_id
       }}
    else
      _invalid -> backup_invalid()
    end
  end

  defp public_manifest(_manifest), do: backup_invalid()

  defp unwrap_or_rollback(_repo, {:ok, value}), do: value
  defp unwrap_or_rollback(repo, {:error, %Error{} = error}), do: repo.rollback(error)

  defp transaction_result({:ok, value}), do: {:ok, value}
  defp transaction_result({:error, %Error{} = error}), do: {:error, error}

  defp transaction_result({:error, %Ecto.Changeset{} = changeset}),
    do: {:error, changeset_error(changeset)}

  defp transaction_result(_result), do: storage_unavailable()

  defp exact_keys?(map, keys), do: Map.keys(map) |> Enum.sort() == Enum.sort(keys)
  defp nonempty?(value), do: is_binary(value) and value != ""
  defp non_neg_integer?(value), do: is_integer(value) and value >= 0

  defp json_value?(value) when is_map(value),
    do: Enum.all?(value, fn {key, nested} -> is_binary(key) and json_value?(nested) end)

  defp json_value?(value) when is_list(value), do: Enum.all?(value, &json_value?/1)
  defp json_value?(value) when is_binary(value) or is_number(value), do: true
  defp json_value?(value) when is_boolean(value) or is_nil(value), do: true
  defp json_value?(_value), do: false

  defp scope_authority(repo, principal_id, vault_id) do
    case SQL.query(
           repo,
           """
           SELECT
             current_setting('singularity.principal_id', true),
             current_setting('singularity.vault_id', true)
           """,
           [],
           log: false
         ) do
      {:ok, %{rows: [[^principal_id, ^vault_id]]}} -> :ok
      {:ok, %{rows: [[_other_principal, _other_vault]]}} -> {:error, Error.new(:forbidden)}
      {:error, _reason} -> storage_unavailable()
    end
  end

  defp exact_authorization_epochs(repo, values) do
    with {:ok, principal_id} <- UUID.dump(values.principal_id),
         {:ok, vault_id} <- UUID.dump(values.vault_id) do
      case SQL.query(
             repo,
             """
             SELECT
               principal_authorization_epoch,
               vault_authorization_epoch
             FROM core.live_principal_authorization()
             WHERE principal_id = $1 AND vault_id = $2
             """,
             [principal_id, vault_id],
             log: false
           ) do
        {:ok,
         %{
           rows: [
             [
               principal_authorization_epoch,
               vault_authorization_epoch
             ]
           ]
         }}
        when principal_authorization_epoch == values.principal_authorization_epoch and
               vault_authorization_epoch == values.vault_authorization_epoch ->
          :ok

        {:ok, %{rows: [_stale_or_malformed]}} ->
          {:error, Error.new(:forbidden)}

        {:ok, %{rows: []}} ->
          {:error, Error.new(:forbidden)}

        _unavailable ->
          storage_unavailable()
      end
    else
      :error -> invalid()
    end
  end

  defp changeset_error(changeset) do
    if Enum.any?(changeset.errors, fn {_field, {_message, metadata}} ->
         metadata[:constraint] == :unique
       end) do
      Error.new(:conflict)
    else
      Error.new(:invalid)
    end
  end

  defp database_error(error, constraint_code \\ :invalid)
  defp database_error(%Ecto.ConstraintError{type: :unique}, _code), do: Error.new(:conflict)
  defp database_error(%Ecto.ConstraintError{}, code), do: Error.new(code)

  defp database_error(%Postgrex.Error{postgres: %{code: :unique_violation}}, :backup_invalid),
    do: Error.new(:backup_invalid)

  defp database_error(%Postgrex.Error{postgres: %{code: :unique_violation}}, _code),
    do: Error.new(:conflict)

  defp database_error(%Postgrex.Error{postgres: %{code: code}}, constraint_code)
       when code in @postgres_constraint_codes,
       do: Error.new(constraint_code)

  defp database_error(_error, _constraint_code),
    do: Error.new(:storage_unavailable, retryable?: true)

  defp invalid, do: {:error, Error.new(:invalid)}
  defp not_found, do: {:error, Error.new(:not_found)}
  defp conflict, do: {:error, Error.new(:conflict)}
  defp backup_invalid, do: {:error, Error.new(:backup_invalid)}
  defp storage_unavailable, do: {:error, Error.new(:storage_unavailable, retryable?: true)}
end
