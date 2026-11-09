defmodule Singularity.Runtime.AssetEvents do
  @moduledoc """
  Local, vault-scoped lifecycle hints for authorized asset readers.

  The duplicate-key Registry fans one durable lifecycle change out to every
  local subscriber without serializing publication through a GenServer.
  """

  alias Singularity.Core.Error

  @registry __MODULE__.Registry

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(options) do
    registry = Keyword.get(options, :name, @registry)

    Supervisor.child_spec(
      {Registry, keys: :duplicate, name: registry},
      id: registry
    )
  end

  @spec subscribe(String.t()) :: :ok | {:error, Error.t()}
  def subscribe(vault_id), do: subscribe(@registry, vault_id)

  @doc false
  @spec subscribe(atom(), String.t()) :: :ok | {:error, Error.t()}
  def subscribe(registry, vault_id) when is_atom(registry) do
    with {:ok, vault_id} <- uuid(vault_id),
         :ok <- register_once(registry, vault_id) do
      :ok
    else
      :error -> {:error, Error.new(:invalid)}
      {:error, _reason} -> unavailable()
    end
  rescue
    _error -> unavailable()
  catch
    _kind, _reason -> unavailable()
  end

  def subscribe(_registry, _vault_id), do: {:error, Error.new(:invalid)}

  @spec publish(String.t(), String.t()) :: :ok
  def publish(vault_id, asset_id), do: publish(@registry, vault_id, asset_id)

  @doc false
  @spec publish(atom(), String.t(), String.t()) :: :ok
  def publish(registry, vault_id, asset_id) when is_atom(registry) do
    with {:ok, vault_id} <- uuid(vault_id),
         {:ok, asset_id} <- uuid(asset_id) do
      Registry.dispatch(registry, vault_id, fn subscribers ->
        signal = {:asset_changed, %{vault_id: vault_id, asset_id: asset_id}}

        Enum.each(subscribers, fn {subscriber, _value} ->
          send(subscriber, signal)
        end)
      end)
    end

    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  def publish(_registry, _vault_id, _asset_id), do: :ok

  defp register_once(registry, vault_id) do
    if vault_id in Registry.keys(registry, self()) do
      :ok
    else
      case Registry.register(registry, vault_id, nil) do
        {:ok, _owner} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> :error
    end
  end

  defp unavailable,
    do: {:error, Error.new(:storage_unavailable, retryable?: true)}
end
