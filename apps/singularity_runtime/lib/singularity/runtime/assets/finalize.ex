defmodule Singularity.Runtime.Assets.Finalize do
  @moduledoc """
  Publishes verified ciphertext and durably attaches the canonical object.

  Database reservation happens before the filesystem mutation. The reservation,
  object advisory lock, and finalization receipt make a retry converge when the
  stage has already been renamed but the acknowledgement did not commit.
  """

  alias Singularity.Core.Error
  alias Singularity.Core.JobEnvelope
  alias Singularity.Core.ObjectRef
  alias Singularity.Runtime.Authorize

  @max_lock_redirects 4

  @spec run(map(), JobEnvelope.t()) :: {:ok, map()} | {:error, Error.t()}
  def run(context, %JobEnvelope{job_type: "asset_finalize"} = envelope)
      when is_map(context) do
    with {:ok, adapters} <- adapters(context),
         {:ok, target} <-
           transact_authorized(adapters, envelope, fn repo ->
             call_adapter(adapters.assets, :resolve_finalization, [
               repo,
               envelope
             ])
           end) do
      finalize_target(adapters, envelope, target)
    end
  rescue
    _error -> {:error, Error.new(:storage_unavailable, retryable?: true)}
  end

  def run(_context, _envelope), do: {:error, Error.new(:invalid)}

  defp finalize_target(_adapters, _envelope, %{
         status: :complete,
         asset: asset
       }),
       do: {:ok, asset}

  defp finalize_target(
         adapters,
         envelope,
         %{status: :lock, object_id: object_id}
       ) do
    finalize_under_lock(
      adapters,
      envelope,
      object_id,
      @max_lock_redirects
    )
  end

  defp finalize_target(_adapters, _envelope, _target),
    do: {:error, Error.new(:conflict)}

  defp finalize_under_lock(
         _adapters,
         _envelope,
         _object_id,
         redirects_left
       )
       when redirects_left <= 0,
       do: {:error, Error.new(:conflict)}

  defp finalize_under_lock(
         adapters,
         envelope,
         object_id,
         redirects_left
       ) do
    result =
      call_adapter(adapters.object_lock, :with_exclusive, [
        adapters.repo_handle,
        object_id,
        fn ->
          with {:ok, reservation} <-
                 transact_authorized(adapters, envelope, fn repo ->
                   call_adapter(adapters.assets, :reserve_finalization, [
                     repo,
                     %{
                       envelope: envelope,
                       object_id: object_id
                     }
                   ])
                 end) do
            finalize_reservation(adapters, envelope, reservation)
          end
        end
      ])

    case result do
      {:retry_lock, redirected_object_id} ->
        finalize_under_lock(
          adapters,
          envelope,
          redirected_object_id,
          redirects_left - 1
        )

      other ->
        other
    end
  end

  defp finalize_reservation(_adapters, _envelope, %{
         status: :complete,
         asset: asset
       }),
       do: {:ok, asset}

  defp finalize_reservation(
         _adapters,
         _envelope,
         %{status: :retry_lock, object_id: object_id}
       ),
       do: {:retry_lock, object_id}

  defp finalize_reservation(
         adapters,
         envelope,
         %{status: :reserved, action: action} = reservation
       )
       when action in [:publish, :reuse] do
    with {:ok, storage} <- storage_for(adapters.storage, reservation),
         :ok <- apply_storage_action(storage, reservation),
         {:ok, stat} <-
           call_adapter(storage, :stat, [reservation.object_ref]),
         :ok <- validate_stat(stat, reservation),
         {:ok, %{asset: asset}} <-
           transact_authorized(adapters, envelope, fn repo ->
             call_adapter(adapters.assets, :acknowledge_finalization, [
               repo,
               %{
                 envelope: envelope,
                 object_id: reservation.object_id,
                 stage_id: reservation.stage_id,
                 action: action,
                 observed_ciphertext_byte_size: stat.byte_size,
                 observed_ciphertext_hash: stat.ciphertext_hash
               }
             ])
           end) do
      {:ok, asset}
    end
  end

  defp finalize_reservation(_adapters, _envelope, _reservation),
    do: {:error, Error.new(:conflict)}

  defp apply_storage_action(storage, %{
         action: :publish,
         stage_ref: stage_ref,
         object_ref: %ObjectRef{object_id: object_id} = object_ref
       }) do
    case call_adapter(storage, :finalize, [stage_ref, object_ref]) do
      {:ok, %ObjectRef{object_id: ^object_id}} -> :ok
      {:ok, _other} -> {:error, Error.new(:conflict)}
      {:error, %Error{}} = error -> error
      _invalid -> {:error, Error.new(:storage_unavailable, retryable?: true)}
    end
  end

  defp apply_storage_action(storage, %{
         action: :reuse,
         stage_ref: stage_ref,
         object_ref: %ObjectRef{} = object_ref
       }) do
    with :ok <- call_adapter(storage, :verify, [object_ref]),
         :ok <- call_adapter(storage, :abort_stage, [stage_ref]) do
      :ok
    end
  end

  defp validate_stat(
         %{
           byte_size: observed_size,
           ciphertext_hash: <<_::binary-size(32)>> = observed_hash
         },
         %{
           ciphertext_byte_size: expected_size,
           ciphertext_hash: <<_::binary-size(32)>> = expected_hash
         }
       )
       when is_integer(observed_size) and observed_size >= 0 and
              is_integer(expected_size) and expected_size >= 0 do
    if observed_size == expected_size and
         secure_compare(observed_hash, expected_hash),
       do: :ok,
       else: {:error, Error.new(:integrity_failure)}
  end

  defp validate_stat(_stat, _reservation),
    do: {:error, Error.new(:integrity_failure)}

  defp storage_for(
         {module, context},
         %{
           vault_id: vault_id,
           key_domain_id: key_domain_id,
           lookup_digest: <<_::binary-size(32)>> = lookup_digest,
           ciphertext_hash: <<_::binary-size(32)>> = ciphertext_hash
         }
       )
       when is_atom(module) and not is_nil(module) and is_map(context) do
    {:ok,
     {module,
      Map.merge(context, %{
        vault_namespace: vault_id,
        domain_namespace: key_domain_id,
        lookup_digest: Base.encode16(lookup_digest, case: :lower),
        ciphertext_hash: ciphertext_hash
      })}}
  end

  defp storage_for({_module, context}, _reservation) when is_map(context),
    do: {:error, Error.new(:integrity_failure)}

  defp storage_for(storage, _reservation), do: {:ok, storage}

  defp transact_authorized(adapters, envelope, callback) do
    adapters.transact.([], fn repo ->
      with :ok <-
             call_adapter(adapters.authorize, :check_job, [
               adapters.authorization,
               repo,
               envelope
             ]) do
        callback.(repo)
      end
    end)
  end

  defp adapters(context) do
    assets = Map.get(context, :assets)
    authorization = Map.get(context, :authorization)
    authorize = Map.get(context, :authorize, Authorize)
    object_lock = Map.get(context, :object_lock)
    repo_handle = Map.get(context, :repo_handle)
    storage = Map.get(context, :storage)
    transact = Map.get(context, :transact)

    if assets not in [nil, false] and
         authorization not in [nil, false] and
         authorize not in [nil, false] and
         object_lock not in [nil, false] and
         repo_handle not in [nil, false] and
         storage not in [nil, false] and
         is_function(transact, 2) do
      {:ok,
       %{
         assets: assets,
         authorization: authorization,
         authorize: authorize,
         object_lock: object_lock,
         repo_handle: repo_handle,
         storage: storage,
         transact: transact
       }}
    else
      {:error, Error.new(:invalid)}
    end
  end

  defp call_adapter(module, function, arguments)
       when is_atom(module) and not is_nil(module) do
    apply(module, function, arguments)
  end

  defp call_adapter({module, context}, function, arguments)
       when is_atom(module) and not is_nil(module) do
    apply(module, function, [context | arguments])
  end

  defp secure_compare(left, right)
       when is_binary(left) and is_binary(right) and
              byte_size(left) == byte_size(right),
       do: :crypto.hash_equals(left, right)

  defp secure_compare(_left, _right), do: false
end
