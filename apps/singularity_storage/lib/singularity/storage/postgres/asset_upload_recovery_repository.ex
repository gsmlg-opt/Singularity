defmodule Singularity.Storage.Postgres.AssetUploadRecoveryRepository do
  @moduledoc """
  Least-privilege access to global restart recovery for consumed upload stages.

  The underlying security-definer functions expose only the stage reference
  needed for physical cleanup and a fixed abandonment transition.
  """

  alias Ecto.Adapters.SQL
  alias Singularity.Core.Error
  alias Singularity.Storage.Postgres.UUID

  @spec list_open_stages(module()) :: {:ok, [map()]} | {:error, Error.t()}
  def list_open_stages(repo) when is_atom(repo) and not is_nil(repo) do
    case SQL.query(
           repo,
           """
           SELECT stage_id, storage_ref
           FROM content.list_open_upload_stages()
           """,
           [],
           log: false
         ) do
      {:ok, %{rows: rows}} ->
        decode_stages(rows, [])

      {:error, _reason} ->
        unavailable()
    end
  rescue
    _error -> unavailable()
  end

  def list_open_stages(_repo), do: {:error, Error.new(:invalid)}

  @spec with_locked_stage(
          module(),
          String.t(),
          String.t(),
          (map() -> {:ok, map()} | {:error, Error.t()})
        ) :: {:ok, map()} | {:error, Error.t()}
  def with_locked_stage(
        repo,
        stage_id,
        storage_ref,
        callback
      )
      when is_atom(repo) and not is_nil(repo) and is_binary(stage_id) and
             is_binary(storage_ref) and byte_size(storage_ref) > 0 and
             is_function(callback, 1) do
    case repo.transaction(fn ->
           result =
             with {:ok, status} <-
                    recovery_status(repo, stage_id, storage_ref) do
               callback.(status)
             end

           case result do
             {:ok, _stage} = success -> success
             {:error, %Error{}} = error -> repo.rollback(error)
             _invalid -> repo.rollback({:error, Error.new(:integrity_failure)})
           end
         end) do
      {:ok, {:ok, _stage} = success} ->
        success

      {:error, {:error, %Error{}} = error} ->
        error

      {:error, %Error{} = error} ->
        {:error, error}

      {:error, _reason} ->
        unavailable()
    end
  rescue
    _error -> unavailable()
  catch
    _kind, _reason -> unavailable()
  end

  def with_locked_stage(
        _repo,
        _stage_id,
        _storage_ref,
        _callback
      ),
      do: {:error, Error.new(:invalid)}

  @spec recovery_status(module(), String.t(), String.t()) ::
          {:ok, map()} | {:error, Error.t()}
  def recovery_status(repo, stage_id, storage_ref)
      when is_atom(repo) and not is_nil(repo) and is_binary(stage_id) and
             is_binary(storage_ref) and byte_size(storage_ref) > 0 do
    with {:ok, dumped_stage_id} <- UUID.dump(stage_id) do
      case SQL.query(
             repo,
             """
             SELECT
               stage_id,
               storage_ref,
               state,
               state_revision,
               failure_code
             FROM content.upload_stage_recovery_status($1, $2)
             """,
             [dumped_stage_id, storage_ref],
             log: false
           ) do
        {:ok,
         %{
           rows: [
             [
               returned_stage_id,
               ^storage_ref,
               state,
               state_revision,
               failure_code
             ]
           ]
         }}
        when state in ["open", "sealed", "finalized", "abandoned"] and
               is_integer(state_revision) and state_revision >= 0 and
               (is_nil(failure_code) or is_binary(failure_code)) ->
          {:ok,
           %{
             stage_id: Ecto.UUID.load!(returned_stage_id),
             storage_ref: storage_ref,
             state: String.to_existing_atom(state),
             state_revision: state_revision,
             failure_code: failure_code
           }}

        {:ok, %{rows: []}} ->
          {:error, Error.new(:not_found)}

        {:ok, %{rows: [_invalid]}} ->
          {:error, Error.new(:integrity_failure)}

        {:error, _reason} ->
          unavailable()
      end
    else
      :error -> {:error, Error.new(:invalid)}
    end
  rescue
    _error in [ArgumentError] -> {:error, Error.new(:invalid)}
    _error -> unavailable()
  end

  def recovery_status(_repo, _stage_id, _storage_ref),
    do: {:error, Error.new(:invalid)}

  @spec mark_abandoned(
          module(),
          String.t(),
          String.t(),
          DateTime.t(),
          :runtime_restarted | :custody_revoked
        ) ::
          {:ok, map()} | {:error, Error.t()}
  def mark_abandoned(
        repo,
        stage_id,
        storage_ref,
        %DateTime{} = abandoned_at,
        reason
      )
      when is_atom(repo) and not is_nil(repo) and is_binary(stage_id) and
             is_binary(storage_ref) and byte_size(storage_ref) > 0 and
             reason in [:runtime_restarted, :custody_revoked] do
    with {:ok, dumped_stage_id} <- UUID.dump(stage_id) do
      case SQL.query(
             repo,
             """
             SELECT
               stage_id,
               state,
               state_revision,
               failure_code,
               applied
             FROM content.reconcile_open_upload_stage($1, $2, $3, $4)
             """,
             [
               dumped_stage_id,
               storage_ref,
               abandoned_at,
               Atom.to_string(reason)
             ],
             log: false
           ) do
        {:ok,
         %{
           rows: [
             [
               returned_stage_id,
               "abandoned",
               state_revision,
               failure_code,
               applied?
             ]
           ]
         }}
        when is_integer(state_revision) and state_revision >= 1 and
               is_binary(failure_code) and
               is_boolean(applied?) ->
          if failure_code == Atom.to_string(reason) do
            {:ok,
             %{
               stage_id: Ecto.UUID.load!(returned_stage_id),
               state: :abandoned,
               state_revision: state_revision,
               failure_code: failure_code,
               applied?: applied?
             }}
          else
            {:error, Error.new(:conflict)}
          end

        {:ok, %{rows: []}} ->
          {:error, Error.new(:not_found)}

        {:ok, %{rows: [_terminal]}} ->
          {:error, Error.new(:conflict)}

        {:error, _reason} ->
          unavailable()
      end
    else
      :error -> {:error, Error.new(:invalid)}
    end
  rescue
    _error in [ArgumentError] -> {:error, Error.new(:invalid)}
    _error -> unavailable()
  end

  def mark_abandoned(
        _repo,
        _stage_id,
        _storage_ref,
        _abandoned_at,
        _reason
      ),
      do: {:error, Error.new(:invalid)}

  defp decode_stages([], decoded), do: {:ok, Enum.reverse(decoded)}

  defp decode_stages([[stage_id, storage_ref] | rows], decoded)
       when is_binary(storage_ref) and byte_size(storage_ref) > 0 do
    decode_stages(
      rows,
      [
        %{
          stage_id: Ecto.UUID.load!(stage_id),
          storage_ref: storage_ref
        }
        | decoded
      ]
    )
  rescue
    _error -> {:error, Error.new(:integrity_failure)}
  end

  defp decode_stages(_rows, _decoded),
    do: {:error, Error.new(:integrity_failure)}

  defp unavailable,
    do: {:error, Error.new(:storage_unavailable, retryable?: true)}
end
