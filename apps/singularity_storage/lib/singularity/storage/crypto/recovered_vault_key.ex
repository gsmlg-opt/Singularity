defmodule Singularity.Storage.Crypto.RecoveredVaultKey do
  @moduledoc """
  Opaque, owner-bound authority to rewrap one authenticated recovered vault key.

  The capability contains no key material. Its owning process performs the
  unwrap and rewrap operation and consumes the authority after one use.
  """

  alias Singularity.Core.Error

  @enforce_keys [:lease, :token]
  defstruct @enforce_keys

  @opaque t :: %__MODULE__{lease: pid(), token: reference()}

  defimpl Inspect, for: __MODULE__ do
    import Inspect.Algebra

    def inspect(_capability, _options), do: concat(["#RecoveredVaultKey<REDACTED>"])
  end

  @doc false
  @spec issue(pid(), reference()) :: t()
  def issue(lease, token) when is_pid(lease) and is_reference(token),
    do: %__MODULE__{lease: lease, token: token}

  @spec rewrap(t(), <<_::256>>, map()) ::
          {:ok, map()} | {:error, Error.t() | :lease_unavailable}
  def rewrap(
        %__MODULE__{lease: lease, token: token},
        <<_::binary-size(32)>> = new_kek,
        binding
      )
      when is_pid(lease) and is_reference(token) and is_map(binding) do
    case safe_call(lease, {:rewrap_recovered_vault_key, token, new_kek, binding}) do
      {:ok,
       %{
         algorithm: :aes_256_gcm,
         encoded: encoded,
         generation: generation,
         purpose: :vault_key,
         version: 1
       } = wrapper}
      when map_size(wrapper) == 5 and is_binary(encoded) and encoded != "" and
             is_integer(generation) and generation > 0 ->
        {:ok, wrapper}

      {:error, :lease_unavailable} = error ->
        error

      {:error, %Error{code: :backup_invalid}} ->
        backup_invalid()

      _invalid ->
        backup_invalid()
    end
  end

  def rewrap(_capability, _new_kek, _binding), do: backup_invalid()

  @spec revoke(t()) :: :ok | {:error, Error.t()}
  def revoke(%__MODULE__{lease: lease, token: token})
      when is_pid(lease) and is_reference(token) do
    case safe_call(lease, {:revoke_recovered_vault_key, token}) do
      :ok -> :ok
      {:error, :lease_unavailable} -> :ok
      {:error, %Error{code: :backup_invalid}} -> backup_invalid()
      _invalid -> backup_invalid()
    end
  end

  def revoke(_capability), do: backup_invalid()

  defp safe_call(lease, request) do
    GenServer.call(lease, request, :infinity)
  catch
    :exit, _reason -> {:error, :lease_unavailable}
  end

  defp backup_invalid, do: {:error, Error.new(:backup_invalid)}
end
