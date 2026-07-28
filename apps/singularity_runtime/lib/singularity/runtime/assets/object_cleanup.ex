defmodule Singularity.Runtime.Assets.ObjectCleanup do
  @moduledoc "Physically removes an orphan under the canonical object lock."

  alias Singularity.Core.Error
  alias Singularity.Core.JobEnvelope
  alias Singularity.Runtime.Authorize
  alias Singularity.Runtime.Observability.Telemetry
  alias Singularity.Storage.ObjectLock

  @spec run(map(), JobEnvelope.t()) ::
          {:ok, map() | :noop} | {:error, Error.t()}
  def run(
        context,
        %JobEnvelope{
          job_type: "object_cleanup",
          required_capability: "object.cleanup",
          payload: %{"object_id" => object_id}
        } = envelope
      )
      when is_map(context) and is_binary(object_id) do
    with {:ok, adapters} <- adapters(context),
         {:ok, _object_id} <- Ecto.UUID.cast(object_id) do
      call_adapter(adapters.object_lock, :with_exclusive, [
        adapters.repo_handle,
        object_id,
        fn -> delete_under_lock(adapters, envelope) end
      ])
    else
      {:error, %Error{}} = error -> error
      _invalid -> {:error, Error.new(:invalid)}
    end
  rescue
    _error -> {:error, Error.new(:storage_unavailable, retryable?: true)}
  end

  def run(_context, _envelope), do: {:error, Error.new(:invalid)}

  defp delete_under_lock(adapters, envelope) do
    case transact_authorized(adapters, envelope, fn repo ->
           call_adapter(adapters.deletions, :claim_orphan_delete, [
             repo,
             envelope
           ])
         end) do
      {:ok, :retained} ->
        {:ok, :noop}

      {:ok, %{status: :retained}} ->
        {:ok, :noop}

      {:ok, %{status: :complete, object: object}} ->
        {:ok, object}

      {:ok, %{object_ref: object_ref} = deletion} ->
        with {:ok, storage} <- storage_for(adapters.storage, deletion),
             :ok <- call_adapter(storage, :delete, [object_ref]),
             {:ok, object} <-
               acknowledge_claim(adapters, envelope, deletion) do
          Telemetry.execute(
            [:orphan, :cleanup],
            %{count: 1},
            %{outcome: :deleted}
          )

          {:ok, object}
        end

      {:error, %Error{}} = error ->
        error

      _invalid ->
        {:error, Error.new(:storage_unavailable, retryable?: true)}
    end
  end

  defp acknowledge_claim(adapters, envelope, deletion) do
    deletion = Map.put(deletion, :envelope, envelope)

    adapters.transact.([], fn repo ->
      call_adapter(
        adapters.deletions,
        :acknowledge_object_deleted,
        [repo, deletion]
      )
    end)
  end

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
    with {:ok, _vault_id} <- Ecto.UUID.cast(vault_id),
         {:ok, _key_domain_id} <- Ecto.UUID.cast(key_domain_id) do
      {:ok,
       {module,
        Map.merge(context, %{
          vault_namespace: vault_id,
          domain_namespace: key_domain_id,
          lookup_digest: Base.encode16(lookup_digest, case: :lower),
          ciphertext_hash: ciphertext_hash
        })}}
    else
      :error -> {:error, Error.new(:integrity_failure)}
    end
  end

  defp storage_for({_module, context}, _deletion)
       when is_map(context),
       do: {:error, Error.new(:integrity_failure)}

  defp storage_for(storage, _deletion), do: {:ok, storage}

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
    deletions =
      Map.get(context, :asset_deletions) ||
        Map.get(context, :assets)

    authorization = Map.get(context, :authorization)
    authorize = Map.get(context, :authorize, Authorize)
    object_lock = Map.get(context, :object_lock, ObjectLock)
    repo_handle = Map.get(context, :repo_handle)
    storage = Map.get(context, :storage)
    transact = Map.get(context, :transact)

    if deletions not in [nil, false] and
         authorization not in [nil, false] and
         authorize not in [nil, false] and
         object_lock not in [nil, false] and
         repo_handle not in [nil, false] and
         storage not in [nil, false] and
         is_function(transact, 2) do
      {:ok,
       %{
         deletions: deletions,
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
end
