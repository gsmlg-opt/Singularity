defmodule Singularity.Storage.Crypto.BackupRecoveryWrapper do
  @moduledoc """
  Adapts the generic key wrapper to the binary backup-recovery contract.

  Recovery wrappers use their own purpose and a deterministic, versioned AAD
  that binds the encrypted vault key to one manifest and one vault.
  """

  alias Singularity.Core.Error
  alias Singularity.Storage.Crypto.KeyWrapper

  @aad_tag "singularity.backup.recovery"
  @aad_version 1
  @generation 1
  @binding_keys [:label, :manifest_id, :vault_id]

  @spec wrap(<<_::256>>, <<_::256>>, map()) ::
          {:ok, binary()} | {:error, Error.t()}
  def wrap(
        <<_::binary-size(32)>> = backup_key,
        <<_::binary-size(32)>> = vault_key,
        binding
      ) do
    with {:ok, metadata} <- wrapper_metadata(binding),
         {:ok,
          %{
            algorithm: :aes_256_gcm,
            encoded: encoded,
            generation: @generation,
            purpose: :backup_recovery,
            version: 1
          }} <- KeyWrapper.wrap(backup_key, vault_key, metadata),
         true <- is_binary(encoded) and encoded != "" do
      {:ok, encoded}
    else
      _invalid -> backup_invalid()
    end
  rescue
    _exception -> backup_invalid()
  catch
    _kind, _reason -> backup_invalid()
  end

  def wrap(_backup_key, _vault_key, _binding), do: backup_invalid()

  @spec unwrap(<<_::256>>, binary(), map()) ::
          {:ok, <<_::256>>} | {:error, Error.t()}
  def unwrap(<<_::binary-size(32)>> = backup_key, encoded, binding)
      when is_binary(encoded) and encoded != "" do
    with {:ok, metadata} <- wrapper_metadata(binding),
         {:ok, <<_::binary-size(32)>> = vault_key} <-
           KeyWrapper.unwrap(backup_key, encoded, metadata) do
      {:ok, vault_key}
    else
      _invalid -> backup_invalid()
    end
  rescue
    _exception -> backup_invalid()
  catch
    _kind, _reason -> backup_invalid()
  end

  def unwrap(_backup_key, _encoded, _binding), do: backup_invalid()

  defp wrapper_metadata(
         %{
           label: :backup_recovery,
           manifest_id: manifest_id,
           vault_id: vault_id
         } = binding
       )
       when map_size(binding) == length(@binding_keys) do
    with true <- canonical_uuid?(manifest_id),
         true <- canonical_uuid?(vault_id) do
      aad =
        :erlang.term_to_binary(
          {@aad_tag, @aad_version, manifest_id, vault_id},
          [:deterministic]
        )

      {:ok,
       %{
         purpose: :backup_recovery,
         generation: @generation,
         aad: aad
       }}
    else
      false -> backup_invalid()
    end
  end

  defp wrapper_metadata(_binding), do: backup_invalid()

  defp canonical_uuid?(value) when is_binary(value),
    do: Ecto.UUID.cast(value) == {:ok, value}

  defp canonical_uuid?(_value), do: false

  defp backup_invalid, do: {:error, Error.new(:backup_invalid)}
end
