defmodule Singularity.Storage.Postgres.KeyRotationRepository do
  @moduledoc """
  Scoped persistence for opaque vault and domain key-rotation plans.

  The repository never receives plaintext keys. Callers prepare and verify
  encrypted wrappers before entering these compare-and-swap transitions.
  Every mutation must run inside the caller's `ScopedRepo`
  transaction so a returned error also rolls back the audit append.
  """

  import Ecto.Query

  alias Singularity.Core.AuditEvent
  alias Singularity.Core.Error
  alias Singularity.Storage.Postgres.AuditSink
  alias Singularity.Storage.Postgres.IdentityRepository
  alias Singularity.Storage.Postgres.UUID
  alias Singularity.Storage.Schema.Content.AssetKeyEnvelope
  alias Singularity.Storage.Schema.Content.AssetObject
  alias Singularity.Storage.Schema.Core.DomainDedupKeyWrapper
  alias Singularity.Storage.Schema.Core.DomainKeyVersion
  alias Singularity.Storage.Schema.Core.KeyDomain
  alias Singularity.Storage.Schema.Core.Vault
  alias Singularity.Storage.Schema.Core.VaultKeyVersion
  alias Singularity.Storage.Schema.Core.VaultKeyWrapper

  @algorithm "aes_256_gcm"
  @classifications [:private, :sensitive, :restricted]
  @max_generation 2_147_483_647
  @max_rotation_items 10_000
  @max_wrapper_bytes 1_024
  @postgres_constraint_codes [
    :integrity_constraint_violation,
    :restrict_violation,
    :not_null_violation,
    :foreign_key_violation,
    :unique_violation,
    :check_violation,
    :exclusion_violation
  ]

  @spec load_vault_rotation_material(module(), map()) ::
          {:ok, map()} | {:error, Error.t()}
  def load_vault_rotation_material(
        repo,
        %{session_id: session_id, principal_id: principal_id, vault_id: vault_id} = command
      )
      when is_atom(repo) do
    repository_operation(fn ->
      with :ok <- validate_command_keys(command, [:session_id, :principal_id, :vault_id]),
           :ok <- UUID.validate([session_id, principal_id, vault_id]),
           {:ok, session} <- scoped_session(repo, session_id, principal_id, vault_id),
           {:ok, material} <- vault_material(repo, session, false) do
        {:ok, material}
      end
    end)
  end

  def load_vault_rotation_material(_repo, _command), do: invalid()

  @spec rotate_vault_key_and_audit(module(), map()) ::
          {:ok, map()} | {:error, Error.t()}
  def rotate_vault_key_and_audit(
        repo,
        %{
          session_id: session_id,
          principal_id: principal_id,
          vault_id: vault_id,
          plan: plan,
          audit: %AuditEvent{} = audit
        } = command
      )
      when is_atom(repo) and is_map(plan) do
    repository_operation(fn ->
      with :ok <- require_transaction(repo),
           :ok <-
             validate_command_keys(command, [
               :session_id,
               :principal_id,
               :vault_id,
               :plan,
               :audit
             ]),
           :ok <- UUID.validate([session_id, principal_id, vault_id]),
           :ok <- validate_rotation_audit(audit, principal_id, vault_id, "vault", vault_id),
           {:ok, session} <- scoped_session(repo, session_id, principal_id, vault_id),
           {:ok, material} <- vault_material(repo, session, true),
           :ok <- validate_vault_plan(plan, material),
           {:ok, pending} <-
             insert_pending_vault_version(
               repo,
               vault_id,
               material.vault_key_version.algorithm,
               plan
             ),
           {:ok, wrapper} <-
             insert_vault_wrapper(
               repo,
               vault_id,
               session.account_id,
               material.vault_wrapper,
               plan
             ),
           :ok <- replace_domain_wrappers(repo, vault_id, material, plan),
           :ok <- retire_active_vault_version(repo, vault_id, material.vault_key_version),
           :ok <- activate_pending_vault_version(repo, vault_id, pending),
           :ok <- lock_vault(repo, vault_id),
           :ok <- AuditSink.append(repo, audit) do
        {:ok,
         %{
           id: pending.id,
           generation: pending.generation,
           state: :active,
           vault_key_wrapper_id: wrapper.id
         }}
      end
    end)
  end

  def rotate_vault_key_and_audit(_repo, _command), do: invalid()

  @spec load_domain_rotation_material(module(), map()) ::
          {:ok, map()} | {:error, Error.t()}
  def load_domain_rotation_material(
        repo,
        %{
          session_id: session_id,
          principal_id: principal_id,
          vault_id: vault_id,
          key_domain_id: key_domain_id
        } = command
      )
      when is_atom(repo) do
    repository_operation(fn ->
      with :ok <-
             validate_command_keys(command, [
               :session_id,
               :principal_id,
               :vault_id,
               :key_domain_id
             ]),
           :ok <- UUID.validate([session_id, principal_id, vault_id, key_domain_id]),
           {:ok, _session} <- scoped_session(repo, session_id, principal_id, vault_id),
           {:ok, material} <- domain_material(repo, vault_id, key_domain_id, false) do
        {:ok, material}
      end
    end)
  end

  def load_domain_rotation_material(_repo, _command), do: invalid()

  @spec rotate_domain_key_and_audit(module(), map()) ::
          {:ok, map()} | {:error, Error.t()}
  def rotate_domain_key_and_audit(
        repo,
        %{
          session_id: session_id,
          principal_id: principal_id,
          vault_id: vault_id,
          key_domain_id: key_domain_id,
          plan: plan,
          audit: %AuditEvent{} = audit
        } = command
      )
      when is_atom(repo) and is_map(plan) do
    repository_operation(fn ->
      with :ok <- require_transaction(repo),
           :ok <-
             validate_command_keys(command, [
               :session_id,
               :principal_id,
               :vault_id,
               :key_domain_id,
               :plan,
               :audit
             ]),
           :ok <- UUID.validate([session_id, principal_id, vault_id, key_domain_id]),
           :ok <-
             validate_rotation_audit(
               audit,
               principal_id,
               vault_id,
               "domain",
               key_domain_id
             ),
           {:ok, _session} <- scoped_session(repo, session_id, principal_id, vault_id),
           {:ok, material} <- domain_material(repo, vault_id, key_domain_id, true),
           :ok <- validate_domain_plan(plan, material),
           {:ok, pending} <-
             insert_pending_domain_version(repo, vault_id, key_domain_id, plan),
           {:ok, dedup_wrapper} <-
             insert_domain_dedup_wrapper(repo, vault_id, key_domain_id, pending.id, plan),
           :ok <-
             retire_active_domain_version(
               repo,
               vault_id,
               key_domain_id,
               material.domain_key_version
             ),
           :ok <-
             activate_pending_domain_version(
               repo,
               vault_id,
               key_domain_id,
               pending
             ),
           {:ok, envelope_ids} <-
             insert_domain_asset_envelopes(
               repo,
               vault_id,
               key_domain_id,
               pending.id,
               material,
               plan
             ),
           :ok <- lock_vault(repo, vault_id),
           :ok <- AuditSink.append(repo, audit) do
        {:ok,
         %{
           id: pending.id,
           generation: pending.generation,
           state: :active,
           dedup_key_wrapper_id: dedup_wrapper.id,
           asset_envelope_ids: envelope_ids
         }}
      end
    end)
  end

  def rotate_domain_key_and_audit(_repo, _command), do: invalid()

  defp scoped_session(repo, session_id, principal_id, vault_id) do
    case IdentityRepository.load_live_session(repo, session_id) do
      {:ok,
       %{
         session_id: ^session_id,
         principal_id: ^principal_id,
         vault_id: ^vault_id,
         account_id: account_id
       } = session}
      when is_binary(account_id) ->
        {:ok, session}

      {:ok, _missing_or_mismatched} ->
        not_found()

      {:error, %Error{}} = error ->
        error

      _invalid ->
        unavailable()
    end
  end

  defp vault_material(repo, %{account_id: account_id, vault_id: vault_id}, lock?) do
    with {:ok, vault_key_version} <- active_vault_version(repo, vault_id, lock?),
         {:ok, vault_wrapper} <-
           active_vault_wrapper(
             repo,
             vault_id,
             account_id,
             vault_key_version.id,
             lock?
           ),
         {:ok, domain_key_versions} <-
           active_domain_versions(repo, vault_id, vault_key_version.id, lock?) do
      {:ok,
       %{
         vault_key_version: vault_key_version,
         vault_wrapper: vault_wrapper,
         domain_key_versions: domain_key_versions
       }}
    end
  end

  defp active_vault_version(repo, vault_id, lock?) do
    VaultKeyVersion
    |> where([version], version.vault_id == ^vault_id)
    |> where([version], version.state == :active)
    |> order_by([version], asc: version.id)
    |> limit(2)
    |> select([version], %{
      id: version.id,
      generation: version.generation,
      algorithm: version.algorithm
    })
    |> maybe_lock(lock?)
    |> repo.all()
    |> one_material()
  end

  defp active_vault_wrapper(repo, vault_id, account_id, version_id, lock?) do
    VaultKeyWrapper
    |> where([wrapper], wrapper.vault_id == ^vault_id)
    |> where([wrapper], wrapper.account_id == ^account_id)
    |> where([wrapper], wrapper.vault_key_version_id == ^version_id)
    |> order_by([wrapper], asc: wrapper.id)
    |> limit(2)
    |> select([wrapper], %{
      id: wrapper.id,
      vault_key_version_id: wrapper.vault_key_version_id,
      account_id: wrapper.account_id,
      generation: wrapper.generation,
      kdf_version: wrapper.kdf_version,
      kdf_salt: wrapper.kdf_salt,
      kdf_parameters: wrapper.kdf_parameters,
      wrapper_algorithm: wrapper.wrapper_algorithm,
      wrapped_key: wrapper.wrapped_key
    })
    |> maybe_lock(lock?)
    |> repo.all()
    |> one_material()
  end

  defp active_domain_versions(repo, vault_id, vault_version_id, lock?) do
    DomainKeyVersion
    |> join(:inner, [version], domain in KeyDomain,
      on:
        domain.id == version.key_domain_id and
          domain.vault_id == version.vault_id
    )
    |> where([version, _domain], version.vault_id == ^vault_id)
    |> where([version, _domain], version.state == :active)
    |> order_by([version, _domain], asc: version.id)
    |> limit(^(@max_rotation_items + 1))
    |> select([version, domain], %{
      id: version.id,
      vault_id: version.vault_id,
      key_domain_id: version.key_domain_id,
      vault_key_version_id: version.vault_key_version_id,
      generation: version.generation,
      algorithm: version.algorithm,
      wrapped_key: version.wrapped_key,
      classification: domain.classification
    })
    |> maybe_lock(lock?)
    |> repo.all()
    |> complete_domain_versions(vault_version_id)
  end

  defp complete_domain_versions(versions, vault_version_id)
       when length(versions) <= @max_rotation_items do
    if unique_field?(versions, :id) and
         unique_field?(versions, :key_domain_id) and
         Enum.all?(
           versions,
           &(&1.vault_key_version_id == vault_version_id)
         ),
       do: {:ok, versions},
       else: conflict()
  end

  defp complete_domain_versions(_too_many, _vault_version_id), do: conflict()

  defp domain_material(repo, vault_id, key_domain_id, lock?) do
    with {:ok, vault_key_version} <- active_vault_version(repo, vault_id, lock?),
         {:ok, domain_key_version} <-
           active_domain_version(
             repo,
             vault_id,
             key_domain_id,
             vault_key_version.id,
             lock?
           ),
         {:ok, dedup_key_wrapper} <-
           active_dedup_wrapper(repo, vault_id, key_domain_id, domain_key_version.id, lock?),
         {:ok, asset_envelopes} <-
           active_asset_envelopes(
             repo,
             vault_id,
             key_domain_id,
             domain_key_version.id,
             lock?
           ) do
      {:ok,
       %{
         domain_key_version: domain_key_version,
         dedup_key_wrapper: dedup_key_wrapper,
         asset_envelopes: asset_envelopes
       }}
    end
  end

  defp active_domain_version(
         repo,
         vault_id,
         key_domain_id,
         vault_key_version_id,
         lock?
       ) do
    DomainKeyVersion
    |> join(:inner, [version], domain in KeyDomain,
      on:
        domain.id == version.key_domain_id and
          domain.vault_id == version.vault_id
    )
    |> where([version, domain], version.vault_id == ^vault_id)
    |> where([version, domain], version.key_domain_id == ^key_domain_id)
    |> where([version, domain], version.state == :active)
    |> where([_version, domain], domain.state == :active)
    |> order_by([version, _domain], asc: version.id)
    |> limit(2)
    |> select([version, domain], %{
      id: version.id,
      vault_id: version.vault_id,
      key_domain_id: version.key_domain_id,
      vault_key_version_id: version.vault_key_version_id,
      generation: version.generation,
      algorithm: version.algorithm,
      wrapped_key: version.wrapped_key,
      classification: domain.classification
    })
    |> maybe_lock(lock?)
    |> repo.all()
    |> one_material()
    |> active_domain_for_vault_version(vault_key_version_id)
  end

  defp active_domain_for_vault_version(
         {:ok, %{vault_key_version_id: vault_key_version_id} = version},
         vault_key_version_id
       ),
       do: {:ok, version}

  defp active_domain_for_vault_version({:ok, _mismatched_version}, _vault_key_version_id),
    do: conflict()

  defp active_domain_for_vault_version({:error, %Error{}} = error, _vault_key_version_id),
    do: error

  defp active_dedup_wrapper(repo, vault_id, key_domain_id, domain_version_id, lock?) do
    DomainDedupKeyWrapper
    |> where([wrapper], wrapper.vault_id == ^vault_id)
    |> where([wrapper], wrapper.key_domain_id == ^key_domain_id)
    |> where([wrapper], wrapper.domain_key_version_id == ^domain_version_id)
    |> order_by([wrapper], asc: wrapper.id)
    |> limit(2)
    |> select([wrapper], %{
      id: wrapper.id,
      domain_key_version_id: wrapper.domain_key_version_id,
      algorithm: wrapper.algorithm,
      wrapped_key: wrapper.wrapped_key
    })
    |> maybe_lock(lock?)
    |> repo.all()
    |> one_material()
  end

  defp active_asset_envelopes(
         repo,
         vault_id,
         key_domain_id,
         domain_version_id,
         lock?
       ) do
    object_ids =
      AssetObject
      |> where([object], object.vault_id == ^vault_id)
      |> where([object], object.key_domain_id == ^key_domain_id)
      |> where([object], object.lifecycle != :deleted)
      |> order_by([object], asc: object.id)
      |> limit(^(@max_rotation_items + 1))
      |> select([object], object.id)
      |> maybe_lock(lock?)
      |> repo.all()

    envelopes =
      AssetKeyEnvelope
      |> join(:inner, [envelope], object in AssetObject,
        on:
          object.id == envelope.asset_object_id and
            object.vault_id == envelope.vault_id and
            object.key_domain_id == envelope.key_domain_id
      )
      |> where([envelope, object], envelope.vault_id == ^vault_id)
      |> where([envelope, object], envelope.key_domain_id == ^key_domain_id)
      |> where([envelope, _object], envelope.domain_key_version_id == ^domain_version_id)
      |> where([_envelope, object], object.lifecycle != :deleted)
      |> order_by([envelope, _object], asc: envelope.id)
      |> limit(^(@max_rotation_items + 1))
      |> select([envelope, _object], %{
        id: envelope.id,
        asset_object_id: envelope.asset_object_id,
        domain_key_version_id: envelope.domain_key_version_id,
        key_domain_id: envelope.key_domain_id,
        classification: envelope.classification,
        algorithm: envelope.algorithm,
        key_generation: envelope.key_generation,
        wrapped_dek: envelope.wrapped_dek
      })
      |> maybe_lock(lock?)
      |> repo.all()

    validate_complete_envelopes(object_ids, envelopes)
  end

  defp validate_complete_envelopes(object_ids, envelopes)
       when length(object_ids) <= @max_rotation_items and
              length(envelopes) <= @max_rotation_items do
    envelope_object_ids = Enum.map(envelopes, & &1.asset_object_id)

    if object_ids == Enum.sort(envelope_object_ids) and
         unique_field?(envelopes, :id) and
         unique_field?(envelopes, :asset_object_id) do
      {:ok, envelopes}
    else
      conflict()
    end
  end

  defp validate_complete_envelopes(_object_ids, _envelopes), do: conflict()

  defp validate_vault_plan(
         %{
           next_vault_key_version_id: next_version_id,
           next_vault_key_version_generation: next_version_generation,
           next_vault_wrapper_generation: next_wrapper_generation,
           vault_wrapper: wrapper,
           domain_versions: prepared_domains
         } = plan,
         %{
           vault_key_version: current_version,
           vault_wrapper: current_wrapper,
           domain_key_versions: current_domains
         }
       ) do
    with true <-
           exact_keys?(
             plan,
             [
               :next_vault_key_version_id,
               :next_vault_key_version_generation,
               :next_vault_wrapper_generation,
               :vault_wrapper,
               :domain_versions
             ]
           ),
         :ok <- UUID.validate(next_version_id),
         true <- next_version_id != current_version.id,
         true <-
           next_generation?(
             current_version.generation,
             next_version_generation
           ),
         true <-
           next_generation?(
             current_wrapper.generation,
             next_wrapper_generation
           ),
         true <-
           valid_vault_wrapper_plan?(
             wrapper,
             next_wrapper_generation,
             current_wrapper
           ),
         true <- valid_domain_wrapper_plans?(prepared_domains),
         true <- same_domain_set?(current_domains, prepared_domains) do
      :ok
    else
      {:error, %Error{}} = error -> error
      _invalid -> conflict()
    end
  end

  defp validate_vault_plan(_plan, _material), do: invalid()

  defp valid_vault_wrapper_plan?(wrapper, generation, current) when is_map(wrapper) do
    exact_keys?(wrapper, [:generation, :algorithm, :wrapped_key]) and
      wrapper.generation == generation and
      wrapper.algorithm == current.wrapper_algorithm and
      wrapper.algorithm == @algorithm and
      valid_wrapper?(wrapper.wrapped_key)
  end

  defp valid_vault_wrapper_plan?(_wrapper, _generation, _current), do: false

  defp valid_domain_wrapper_plans?(prepared)
       when is_list(prepared) and length(prepared) <= @max_rotation_items do
    Enum.all?(prepared, fn version ->
      is_map(version) and
        exact_keys?(
          version,
          [
            :id,
            :key_domain_id,
            :generation,
            :algorithm,
            :expected_wrapped_key,
            :wrapped_key
          ]
        ) and
        match?(:ok, UUID.validate([version.id, version.key_domain_id])) and
        valid_generation?(version.generation) and
        version.algorithm == @algorithm and
        valid_wrapper?(version.expected_wrapped_key) and
        valid_wrapper?(version.wrapped_key)
    end) and
      unique_field?(prepared, :id) and unique_field?(prepared, :key_domain_id)
  end

  defp valid_domain_wrapper_plans?(_prepared), do: false

  defp same_domain_set?(current, prepared) when length(current) == length(prepared) do
    current
    |> Enum.sort_by(& &1.id)
    |> Enum.zip(Enum.sort_by(prepared, & &1.id))
    |> Enum.all?(fn {stored, next} ->
      next.id == stored.id and
        next.key_domain_id == stored.key_domain_id and
        next.generation == stored.generation and
        next.algorithm == stored.algorithm and
        next.expected_wrapped_key == stored.wrapped_key
    end)
  end

  defp same_domain_set?(_current, _prepared), do: false

  defp validate_domain_plan(
         %{
           next_domain_key_version_id: next_version_id,
           next_domain_key_generation: next_generation,
           domain_wrapper: domain_wrapper,
           dedup_wrapper: dedup_wrapper,
           asset_envelopes: prepared_envelopes
         } = plan,
         %{
           domain_key_version: current_version,
           dedup_key_wrapper: current_dedup,
           asset_envelopes: current_envelopes
         }
       ) do
    with true <-
           exact_keys?(
             plan,
             [
               :next_domain_key_version_id,
               :next_domain_key_generation,
               :domain_wrapper,
               :dedup_wrapper,
               :asset_envelopes
             ]
           ),
         :ok <- UUID.validate(next_version_id),
         true <- next_version_id != current_version.id,
         true <- next_generation?(current_version.generation, next_generation),
         true <- valid_domain_version_plan?(domain_wrapper, current_version),
         true <- valid_dedup_wrapper_plan?(dedup_wrapper, current_dedup),
         true <- valid_asset_envelope_plans?(prepared_envelopes, next_generation),
         true <- same_envelope_set?(current_envelopes, prepared_envelopes) do
      :ok
    else
      {:error, %Error{}} = error -> error
      _invalid -> conflict()
    end
  end

  defp validate_domain_plan(_plan, _material), do: invalid()

  defp valid_domain_version_plan?(wrapper, current) when is_map(wrapper) do
    exact_keys?(wrapper, [:vault_key_version_id, :algorithm, :wrapped_key]) and
      wrapper.vault_key_version_id == current.vault_key_version_id and
      wrapper.algorithm == @algorithm and
      valid_wrapper?(wrapper.wrapped_key)
  end

  defp valid_domain_version_plan?(_wrapper, _current), do: false

  defp valid_dedup_wrapper_plan?(wrapper, current) when is_map(wrapper) do
    exact_keys?(wrapper, [:algorithm, :wrapped_key]) and
      wrapper.algorithm == current.algorithm and
      wrapper.algorithm == @algorithm and
      valid_wrapper?(wrapper.wrapped_key)
  end

  defp valid_dedup_wrapper_plan?(_wrapper, _current), do: false

  defp valid_asset_envelope_plans?(prepared, generation)
       when is_list(prepared) and length(prepared) <= @max_rotation_items do
    Enum.all?(prepared, fn envelope ->
      is_map(envelope) and
        exact_keys?(
          envelope,
          [
            :expected_envelope_id,
            :asset_object_id,
            :expected_key_generation,
            :classification,
            :algorithm,
            :key_generation,
            :wrapped_dek
          ]
        ) and
        match?(:ok, UUID.validate([envelope.expected_envelope_id, envelope.asset_object_id])) and
        valid_generation?(envelope.expected_key_generation) and
        envelope.classification in @classifications and
        envelope.algorithm == @algorithm and
        envelope.key_generation == generation and
        valid_wrapper?(envelope.wrapped_dek)
    end) and
      unique_field?(prepared, :expected_envelope_id) and
      unique_field?(prepared, :asset_object_id)
  end

  defp valid_asset_envelope_plans?(_prepared, _generation), do: false

  defp same_envelope_set?(current, prepared) when length(current) == length(prepared) do
    current
    |> Enum.sort_by(& &1.id)
    |> Enum.zip(Enum.sort_by(prepared, & &1.expected_envelope_id))
    |> Enum.all?(fn {stored, next} ->
      next.expected_envelope_id == stored.id and
        next.asset_object_id == stored.asset_object_id and
        next.expected_key_generation == stored.key_generation and
        next.classification == stored.classification and
        next.algorithm == stored.algorithm
    end)
  end

  defp same_envelope_set?(_current, _prepared), do: false

  defp insert_pending_vault_version(repo, vault_id, algorithm, plan) do
    %VaultKeyVersion{}
    |> VaultKeyVersion.create_changeset(%{
      id: plan.next_vault_key_version_id,
      vault_id: vault_id,
      generation: plan.next_vault_key_version_generation,
      state: :pending,
      algorithm: algorithm
    })
    |> repo.insert()
    |> normalize_insert()
  end

  defp insert_vault_wrapper(repo, vault_id, account_id, current_wrapper, plan) do
    %VaultKeyWrapper{}
    |> VaultKeyWrapper.create_changeset(%{
      id: Ecto.UUID.generate(),
      vault_id: vault_id,
      vault_key_version_id: plan.next_vault_key_version_id,
      account_id: account_id,
      generation: plan.next_vault_wrapper_generation,
      kdf_version: current_wrapper.kdf_version,
      kdf_salt: current_wrapper.kdf_salt,
      kdf_parameters: current_wrapper.kdf_parameters,
      wrapper_algorithm: current_wrapper.wrapper_algorithm,
      wrapped_key: plan.vault_wrapper.wrapped_key
    })
    |> repo.insert()
    |> normalize_insert()
  end

  defp replace_domain_wrappers(repo, vault_id, material, plan) do
    prepared = Map.new(plan.domain_versions, &{&1.id, &1})

    Enum.reduce_while(material.domain_key_versions, :ok, fn current, :ok ->
      next = Map.fetch!(prepared, current.id)

      query =
        from version in DomainKeyVersion,
          where: version.id == ^current.id,
          where: version.vault_id == ^vault_id,
          where: version.key_domain_id == ^current.key_domain_id,
          where: version.vault_key_version_id == ^material.vault_key_version.id,
          where: version.generation == ^current.generation,
          where: version.state == :active,
          where: version.algorithm == ^current.algorithm,
          where: version.wrapped_key == ^current.wrapped_key

      case repo.update_all(query,
             set: [
               vault_key_version_id: plan.next_vault_key_version_id,
               algorithm: next.algorithm,
               wrapped_key: next.wrapped_key
             ]
           ) do
        {1, _rows} -> {:cont, :ok}
        {0, _rows} -> {:halt, conflict()}
      end
    end)
  end

  defp retire_active_vault_version(repo, vault_id, current) do
    query =
      from version in VaultKeyVersion,
        where: version.id == ^current.id,
        where: version.vault_id == ^vault_id,
        where: version.generation == ^current.generation,
        where: version.state == :active

    case repo.update_all(query,
           set: [state: :retired, retired_at: DateTime.utc_now(:microsecond)]
         ) do
      {1, _rows} -> :ok
      {0, _rows} -> conflict()
    end
  end

  defp activate_pending_vault_version(repo, vault_id, pending) do
    query =
      from version in VaultKeyVersion,
        where: version.id == ^pending.id,
        where: version.vault_id == ^vault_id,
        where: version.generation == ^pending.generation,
        where: version.state == :pending

    case repo.update_all(query,
           set: [state: :active, activated_at: DateTime.utc_now(:microsecond)]
         ) do
      {1, _rows} -> :ok
      {0, _rows} -> conflict()
    end
  end

  defp insert_pending_domain_version(repo, vault_id, key_domain_id, plan) do
    %DomainKeyVersion{}
    |> DomainKeyVersion.create_changeset(%{
      id: plan.next_domain_key_version_id,
      vault_id: vault_id,
      key_domain_id: key_domain_id,
      vault_key_version_id: plan.domain_wrapper.vault_key_version_id,
      generation: plan.next_domain_key_generation,
      state: :pending,
      algorithm: plan.domain_wrapper.algorithm,
      wrapped_key: plan.domain_wrapper.wrapped_key
    })
    |> repo.insert()
    |> normalize_insert()
  end

  defp insert_domain_dedup_wrapper(repo, vault_id, key_domain_id, version_id, plan) do
    %DomainDedupKeyWrapper{}
    |> DomainDedupKeyWrapper.create_changeset(%{
      id: Ecto.UUID.generate(),
      vault_id: vault_id,
      key_domain_id: key_domain_id,
      domain_key_version_id: version_id,
      algorithm: plan.dedup_wrapper.algorithm,
      wrapped_key: plan.dedup_wrapper.wrapped_key
    })
    |> repo.insert()
    |> normalize_insert()
  end

  defp insert_domain_asset_envelopes(
         repo,
         vault_id,
         key_domain_id,
         version_id,
         material,
         plan
       ) do
    current = Map.new(material.asset_envelopes, &{&1.id, &1})

    plan.asset_envelopes
    |> Enum.sort_by(& &1.expected_envelope_id)
    |> Enum.reduce_while({:ok, []}, fn prepared, {:ok, ids} ->
      stored = Map.fetch!(current, prepared.expected_envelope_id)

      changeset =
        AssetKeyEnvelope.create_changeset(%AssetKeyEnvelope{}, %{
          id: Ecto.UUID.generate(),
          vault_id: vault_id,
          asset_object_id: stored.asset_object_id,
          domain_key_version_id: version_id,
          key_domain_id: key_domain_id,
          classification: stored.classification,
          algorithm: prepared.algorithm,
          key_generation: prepared.key_generation,
          wrapped_dek: prepared.wrapped_dek
        })

      case repo.insert(changeset) do
        {:ok, envelope} -> {:cont, {:ok, [envelope.id | ids]}}
        {:error, %Ecto.Changeset{} = failed} -> {:halt, {:error, changeset_error(failed)}}
      end
    end)
    |> reverse_ids()
  end

  defp reverse_ids({:ok, ids}), do: {:ok, Enum.reverse(ids)}
  defp reverse_ids({:error, %Error{}} = error), do: error

  defp retire_active_domain_version(repo, vault_id, key_domain_id, current) do
    query =
      from version in DomainKeyVersion,
        where: version.id == ^current.id,
        where: version.vault_id == ^vault_id,
        where: version.key_domain_id == ^key_domain_id,
        where: version.vault_key_version_id == ^current.vault_key_version_id,
        where: version.generation == ^current.generation,
        where: version.state == :active,
        where: version.wrapped_key == ^current.wrapped_key

    case repo.update_all(query, set: [state: :retired]) do
      {1, _rows} -> :ok
      {0, _rows} -> conflict()
    end
  end

  defp activate_pending_domain_version(repo, vault_id, key_domain_id, pending) do
    query =
      from version in DomainKeyVersion,
        where: version.id == ^pending.id,
        where: version.vault_id == ^vault_id,
        where: version.key_domain_id == ^key_domain_id,
        where: version.generation == ^pending.generation,
        where: version.state == :pending

    case repo.update_all(query, set: [state: :active]) do
      {1, _rows} -> :ok
      {0, _rows} -> conflict()
    end
  end

  defp lock_vault(repo, vault_id) do
    case repo.update_all(
           from(vault in Vault,
             where: vault.id == ^vault_id,
             where: vault.locked == false
           ),
           set: [locked: true, updated_at: DateTime.utc_now()]
         ) do
      {1, _rows} -> :ok
      {0, _rows} -> conflict()
    end
  end

  defp validate_rotation_audit(
         %AuditEvent{
           actor_kind: :principal,
           principal_id: principal_id,
           vault_id: vault_id,
           anonymous_fingerprint: nil,
           system_principal_name: nil,
           action: action,
           result: :completed,
           classification: :restricted,
           target_type: target_type,
           target_id: target_id
         } = audit,
         principal_id,
         vault_id,
         target_type,
         target_id
       )
       when action in ["vault.key_rotated", "domain.key_rotated"] do
    expected_action =
      case target_type do
        "vault" -> "vault.key_rotated"
        "domain" -> "domain.key_rotated"
      end

    if action == expected_action,
      do:
        UUID.validate([
          audit.audit_event_id,
          audit.correlation_id,
          audit.principal_id,
          audit.vault_id,
          audit.target_id
        ]),
      else: invalid()
  end

  defp validate_rotation_audit(_audit, _principal_id, _vault_id, _target_type, _target_id),
    do: invalid()

  defp normalize_insert({:ok, record}), do: {:ok, record}

  defp normalize_insert({:error, %Ecto.Changeset{} = changeset}),
    do: {:error, changeset_error(changeset)}

  defp one_material([material]), do: {:ok, material}
  defp one_material([]), do: not_found()
  defp one_material([_first, _second]), do: conflict()

  defp maybe_lock(query, true), do: from(row in query, lock: "FOR UPDATE")
  defp maybe_lock(query, false), do: query

  defp exact_keys?(map, expected) when is_map(map),
    do: MapSet.new(Map.keys(map)) == MapSet.new(expected)

  defp exact_keys?(_map, _expected), do: false

  defp validate_command_keys(command, expected) do
    if exact_keys?(command, expected), do: :ok, else: invalid()
  end

  defp require_transaction(repo) do
    if repo.in_transaction?(), do: :ok, else: invalid()
  end

  defp unique_field?(values, field) do
    values
    |> Enum.map(&Map.fetch!(&1, field))
    |> then(&(MapSet.size(MapSet.new(&1)) == length(&1)))
  end

  defp valid_wrapper?(value),
    do: is_binary(value) and byte_size(value) > 0 and byte_size(value) <= @max_wrapper_bytes

  defp valid_generation?(value),
    do: is_integer(value) and value > 0 and value <= @max_generation

  defp next_generation?(current, next),
    do:
      valid_generation?(current) and current < @max_generation and
        next == current + 1

  defp repository_operation(fun) when is_function(fun, 0) do
    fun.()
  rescue
    _error in [ArgumentError, Ecto.Query.CastError, KeyError] ->
      invalid()

    error in [
      Ecto.ConstraintError,
      DBConnection.ConnectionError,
      Postgrex.Error
    ] ->
      {:error, database_error(error)}
  end

  defp changeset_error(changeset) do
    if Enum.any?(changeset.errors, fn {_field, {_message, metadata}} ->
         metadata[:constraint] == :unique
       end),
       do: Error.new(:conflict),
       else: Error.new(:invalid)
  end

  defp database_error(%Ecto.ConstraintError{type: :unique}), do: Error.new(:conflict)
  defp database_error(%Ecto.ConstraintError{}), do: Error.new(:invalid)

  defp database_error(%Postgrex.Error{postgres: %{code: :unique_violation}}),
    do: Error.new(:conflict)

  defp database_error(%Postgrex.Error{postgres: %{code: code}})
       when code in @postgres_constraint_codes,
       do: Error.new(:invalid)

  defp database_error(_error),
    do: Error.new(:storage_unavailable, retryable?: true)

  defp invalid, do: {:error, Error.new(:invalid)}
  defp conflict, do: {:error, Error.new(:conflict)}
  defp not_found, do: {:error, Error.new(:not_found)}
  defp unavailable, do: {:error, Error.new(:storage_unavailable, retryable?: true)}
end
